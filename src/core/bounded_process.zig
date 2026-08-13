//! Bounded child-process execution for untrusted helpers.
//!
//! This module owns the complete lifecycle: contained spawn, stdout draining,
//! output/deadline enforcement, process-tree termination, and leader reaping.
//! Callers provide argv plus a fixed output buffer and never receive a process
//! handle that they could accidentally leak.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("io_global.zig");
const sync = @import("sync.zig");
const alloc = @import("alloc.zig").allocator;

pub const Options = struct {
    timeout_ms: i64 = 30_000,
    terminate_grace_ms: i64 = 500,
};

/// Optional generation token for a streaming child.  A caller starts the
/// process with the generation it owns; when another thread advances `value`,
/// the watchdog stops the old process even if its stdout reader is blocked.
/// Keeping the expected value inside this by-value descriptor avoids handing
/// the watchdog a pointer to caller stack data.
pub const CancelEpoch = union(enum) {
    epoch32: struct {
        value: *const std.atomic.Value(u32),
        expected: u32,
    },
    epoch64: struct {
        value: *const std.atomic.Value(u64),
        expected: u64,
    },

    fn fired(self: CancelEpoch) bool {
        return switch (self) {
            .epoch32 => |token| token.value.load(.acquire) != token.expected,
            .epoch64 => |token| token.value.load(.acquire) != token.expected,
        };
    }
};

pub const StreamOptions = struct {
    timeout_ms: i64 = 30_000,
    terminate_grace_ms: i64 = 500,
    max_output_bytes: usize = 16 * 1024 * 1024,
    cwd: ?[]const u8 = null,
    stderr_behavior: io.Child.StdIo = .Ignore,
    cancel_epoch: ?CancelEpoch = null,
    cancel_flag: ?*const std.atomic.Value(bool) = null,
};

pub const StreamStartError = error{
    InvalidInput,
    SpawnFailed,
    ContainmentFailed,
    WatchdogSpawnFailed,
};

pub const StreamResult = struct {
    term: ?io.Child.Term = null,
    timed_out: bool = false,
    cancelled: bool = false,
    stop_requested: bool = false,
    output_limited: bool = false,
    wait_failed: bool = false,
    bytes_seen: usize = 0,

    pub fn ok(self: StreamResult) bool {
        if (self.timed_out or self.cancelled or self.stop_requested or
            self.output_limited or self.wait_failed) return false;
        const term = self.term orelse return false;
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

pub const Failure = enum {
    none,
    invalid_input,
    spawn,
    watchdog_spawn,
    timeout,
    output_limit,
    read,
    nonzero_exit,
    abnormal_exit,
    wait,
};

pub const Result = struct {
    output: []const u8 = "",
    failure: Failure = .none,
    exit_code: ?u8 = null,
    truncated: bool = false,

    pub fn ok(self: Result) bool {
        return self.failure == .none and !self.truncated;
    }
};

/// Serializes process-tree signaling against Job Object close / POSIX process
/// group retirement. This avoids a timeout thread using a recycled OS handle
/// just as the waiter observes a natural exit.
const KillControl = struct {
    mutex: sync.Mutex = .{},
    tree: io.ProcessTree,
    active: bool = true,
    skip_first_group_kill_for_test: bool = false,

    fn signalIfActive(self: *KillControl, force: bool) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.active) return false;
        if (force) {
            if (builtin.is_test and self.skip_first_group_kill_for_test) {
                self.skip_first_group_kill_for_test = false;
            } else {
                io.killProcessTree(self.tree);
            }
            // A POSIX process-group signal is best-effort and io_global
            // intentionally hides its error. Always force the still-waitable
            // leader by PID as a second route. It cannot be PID-reused before
            // its owner reaps it, so this fallback is safe here; finish()
            // deliberately remains group-only
            // because it runs after wait() and must not signal a recycled PID.
            io.killProcess(self.tree.id);
        } else {
            io.terminateProcessTree(self.tree);
        }
        return true;
    }

    /// Linearization point for a caller-initiated stop. The marker and first
    /// signal are committed under the same lock that retires `tree`, so a
    /// concurrent finisher either observes this request before producing its
    /// result or wins the lock and makes the request a safe no-op. In neither
    /// case can a controller signal a closed or recycled OS handle.
    fn requestStopIfActive(
        self: *KillControl,
        stop_requested: *std.atomic.Value(bool),
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.active) return false;
        stop_requested.store(true, .release);
        io.terminateProcessTree(self.tree);
        return true;
    }

    /// No plugin descendant is allowed to outlive a completed invocation.
    /// Force the remaining tree, mark the snapshot unusable, then close the
    /// Windows Job handle while the watchdog is excluded by the same lock.
    fn finish(self: *KillControl, child: *io.Child) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active) io.killProcessTree(self.tree);
        self.active = false;
        child.closeProcessTree();
    }
};

const Watchdog = struct {
    control: *KillControl,
    done: *std.atomic.Value(bool),
    timed_out: *std.atomic.Value(bool),
    timeout_ms: i64,
    grace_ms: i64,

    fn run(self: Watchdog) void {
        const start = io.monotonicMilliTimestamp();
        const deadline = start +| @max(self.timeout_ms, 1);
        while (!self.done.load(.acquire)) {
            if (io.monotonicMilliTimestamp() >= deadline) {
                // The lock makes the active check and first signal atomic with
                // natural-exit cleanup. A process that won the race to finish
                // is never mislabeled as timed out.
                if (!self.control.signalIfActive(false)) return;
                self.timed_out.store(true, .release);

                const grace_deadline = io.monotonicMilliTimestamp() +| @max(self.grace_ms, 0);
                while (!self.done.load(.acquire) and io.monotonicMilliTimestamp() < grace_deadline)
                    io.sleep(10 * std.time.ns_per_ms);
                if (!self.done.load(.acquire)) _ = self.control.signalIfActive(true);
                return;
            }
            io.sleep(10 * std.time.ns_per_ms);
        }
    }
};

/// Streaming sibling of Watchdog.  Besides the deadline it observes an
/// explicit stop request and an optional caller generation.  It never reaps:
/// the stdout-owning thread remains the sole waiter and completes cleanup via
/// StreamProcess.finish().
const StreamWatchdog = struct {
    control: *KillControl,
    done: *std.atomic.Value(bool),
    timed_out: *std.atomic.Value(bool),
    cancelled: *std.atomic.Value(bool),
    stop_requested: *std.atomic.Value(bool),
    timeout_ms: i64,
    grace_ms: i64,
    cancel_epoch: ?CancelEpoch,
    cancel_flag: ?*const std.atomic.Value(bool),

    fn run(self: StreamWatchdog) void {
        const deadline = io.monotonicMilliTimestamp() +| @max(self.timeout_ms, 1);
        while (!self.done.load(.acquire)) {
            var should_stop = self.stop_requested.load(.acquire);
            if (!should_stop) {
                if (self.cancel_flag) |flag| {
                    if (flag.load(.acquire)) {
                        self.cancelled.store(true, .release);
                        should_stop = true;
                    }
                }
            }
            if (!should_stop) {
                if (self.cancel_epoch) |token| {
                    if (token.fired()) {
                        self.cancelled.store(true, .release);
                        should_stop = true;
                    }
                }
            }
            if (!should_stop and io.monotonicMilliTimestamp() >= deadline) {
                self.timed_out.store(true, .release);
                should_stop = true;
            }

            if (should_stop) {
                if (!self.control.signalIfActive(false)) return;
                const grace_deadline = io.monotonicMilliTimestamp() +| @max(self.grace_ms, 0);
                while (!self.done.load(.acquire) and io.monotonicMilliTimestamp() < grace_deadline)
                    io.sleep(10 * std.time.ns_per_ms);
                if (!self.done.load(.acquire)) _ = self.control.signalIfActive(true);
                return;
            }
            io.sleep(10 * std.time.ns_per_ms);
        }
    }
};

var fail_watchdog_spawn_for_test = false;
var skip_first_group_kill_for_test = false;

fn newKillControl(tree: io.ProcessTree) KillControl {
    return .{
        .tree = tree,
        .skip_first_group_kill_for_test = builtin.is_test and skip_first_group_kill_for_test,
    };
}

fn spawnWatchdog(watchdog: Watchdog) !std.Thread {
    if (builtin.is_test and fail_watchdog_spawn_for_test)
        return error.ThreadQuotaExceeded;
    return std.Thread.spawn(.{}, Watchdog.run, .{watchdog});
}

fn spawnStreamWatchdog(watchdog: StreamWatchdog) !std.Thread {
    if (builtin.is_test and fail_watchdog_spawn_for_test)
        return error.ThreadQuotaExceeded;
    return std.Thread.spawn(.{}, StreamWatchdog.run, .{watchdog});
}

/// Force the entire tree and synchronously reap its leader. Used specifically
/// when no watchdog could be created; returning while the child is alive is
/// not an acceptable recovery path.
fn abortAndReap(child: *io.Child, control: *KillControl, done: *std.atomic.Value(bool)) void {
    _ = control.signalIfActive(true);
    _ = child.wait() catch {
        // A failed wait may leave the child waitable. std's kill() both kills
        // and reaps, so this is the final synchronous fallback.
        _ = child.kill() catch {};
    };
    done.store(true, .release);
    control.finish(child);
}

pub fn run(argv: []const []const u8, output: []u8, options: Options) Result {
    if (argv.len == 0 or argv[0].len == 0 or output.len == 0)
        return .{ .failure = .invalid_input };

    var child = io.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.new_process_group = true;
    child.spawn() catch return .{ .failure = .spawn };
    const tree = child.processTree() orelse {
        // A containment setup failure is fail-closed even if a future Child
        // implementation accidentally reports spawn success without a tree.
        _ = child.kill() catch {};
        child.closeProcessTree();
        return .{ .failure = .spawn };
    };

    var done = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    var control = newKillControl(tree);
    const watchdog = spawnWatchdog(.{
        .control = &control,
        .done = &done,
        .timed_out = &timed_out,
        .timeout_ms = options.timeout_ms,
        .grace_ms = options.terminate_grace_ms,
    }) catch {
        abortAndReap(&child, &control, &done);
        return .{ .failure = .watchdog_spawn };
    };

    var total: usize = 0;
    var truncated = false;
    var read_failed = false;
    if (child.stdout) |*stdout| {
        while (total < output.len) {
            const n = io.read(stdout, output[total..]) catch {
                read_failed = true;
                _ = control.signalIfActive(true);
                break;
            };
            if (n == 0) break;
            total += n;
        }

        // Filling the buffer is ambiguous: distinguish exact-size EOF from an
        // over-limit stream with one byte. On overflow, stop the whole tree
        // immediately instead of draining attacker-controlled output forever.
        if (!read_failed and total == output.len) {
            var extra: [1]u8 = undefined;
            const n = io.read(stdout, &extra) catch blk: {
                read_failed = true;
                _ = control.signalIfActive(true);
                break :blk 0;
            };
            if (n != 0) {
                truncated = true;
                _ = control.signalIfActive(true);
            }
        }
    }

    // A fatal read/output-limit path has already force-signaled the tree. Do
    // not then trust every inherited writer to close before we can reap and
    // issue the final group fence: close both copies of our read handle first.
    // This is also the bounded fallback if the first process-group signal is
    // missed. closeStdout clears std.process.Child's duplicate,
    // avoiding its cleanup double-closing a descriptor that has been reused.
    if (truncated or read_failed) child.closeStdout();

    const term = child.wait() catch null;
    done.store(true, .release);
    control.finish(&child);
    watchdog.join();

    const base = Result{ .output = output[0..total], .truncated = truncated };
    if (timed_out.load(.acquire)) return withFailure(base, .timeout);
    if (truncated) return withFailure(base, .output_limit);
    if (read_failed) return withFailure(base, .read);
    const t = term orelse return withFailure(base, .wait);
    return switch (t) {
        .exited => |code| .{
            .output = base.output,
            .failure = if (code == 0) .none else .nonzero_exit,
            .exit_code = code,
            .truncated = false,
        },
        else => withFailure(base, .abnormal_exit),
    };
}

fn withFailure(base: Result, failure: Failure) Result {
    var result = base;
    result.failure = failure;
    return result;
}

const StreamLifecycle = enum(u8) {
    initialized,
    starting,
    running,
    finishing,
    finished,
};

/// A caller-owned, incremental child-process session.  Construct it in its
/// final stack location, then call start(): the watchdog captures pointers to
/// fields in this value, so moving/copying it after start is invalid. One owner
/// thread exclusively calls start(), stdout(), noteOutput(), and finish(). Any
/// controller thread may call requestStop() after start succeeds, but the owner
/// must keep this storage alive until every such call has returned. The atomic
/// lifecycle publishes `control`; KillControl's mutex then serializes every
/// signal against process-tree retirement and handle close. The public surface
/// deliberately exposes stdout but not the process handle, and every exit path
/// funnels through finish().
pub const StreamProcess = struct {
    child: io.Child,
    options: StreamOptions,
    control: KillControl = undefined,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    timed_out: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    output_limited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    watchdog: ?std.Thread = null,
    bytes_seen: usize = 0,
    lifecycle: std.atomic.Value(StreamLifecycle) = std.atomic.Value(StreamLifecycle).init(.initialized),

    pub fn init(argv: []const []const u8, options: StreamOptions) StreamProcess {
        return .{
            .child = io.Child.init(argv, alloc),
            .options = options,
        };
    }

    pub fn start(self: *StreamProcess) StreamStartError!void {
        if (self.child.argv.len == 0 or self.child.argv[0].len == 0 or
            self.options.max_output_bytes == 0)
            return error.InvalidInput;

        if (self.lifecycle.cmpxchgStrong(
            .initialized,
            .starting,
            .acq_rel,
            .acquire,
        ) != null) return error.InvalidInput;

        self.child.stdin_behavior = .Ignore;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = self.options.stderr_behavior;
        self.child.cwd = self.options.cwd;
        self.child.new_process_group = true;
        self.child.spawn() catch {
            // A spawn failure has not created any process resources, so the
            // owner may correct an environmental problem and retry start().
            self.lifecycle.store(.initialized, .release);
            return error.SpawnFailed;
        };

        const tree = self.child.processTree() orelse {
            _ = self.child.kill() catch {};
            self.child.closeProcessTree();
            self.lifecycle.store(.finished, .release);
            return error.ContainmentFailed;
        };
        self.control = newKillControl(tree);

        const thread = spawnStreamWatchdog(.{
            .control = &self.control,
            .done = &self.done,
            .timed_out = &self.timed_out,
            .cancelled = &self.cancelled,
            .stop_requested = &self.stop_requested,
            .timeout_ms = self.options.timeout_ms,
            .grace_ms = self.options.terminate_grace_ms,
            .cancel_epoch = self.options.cancel_epoch,
            .cancel_flag = self.options.cancel_flag,
        }) catch {
            abortAndReap(&self.child, &self.control, &self.done);
            self.lifecycle.store(.finished, .release);
            return error.WatchdogSpawnFailed;
        };
        self.watchdog = thread;
        // Release-publish the initialized control and watchdog fields before
        // requestStop() is permitted to touch them from another thread.
        self.lifecycle.store(.running, .release);
    }

    /// The sole stdout handle. Call only after a successful start and before
    /// finish. The returned pointer remains owned by this session.
    pub fn stdout(self: *StreamProcess) ?*std.Io.File {
        if (self.lifecycle.load(.acquire) != .running) return null;
        if (self.child.stdout) |*out| return out;
        return null;
    }

    /// Account for every raw byte consumed from stdout.  Crossing the budget
    /// immediately asks the watchdog to stop the tree; finish still drains and
    /// reaps, so a writer cannot wedge cleanup by inheriting the pipe.
    pub fn noteOutput(self: *StreamProcess, count: usize) bool {
        if (self.lifecycle.load(.acquire) != .running) return false;
        self.bytes_seen +|= count;
        if (self.bytes_seen <= self.options.max_output_bytes) return true;
        self.output_limited.store(true, .release);
        self.requestStop();
        return false;
    }

    /// Graceful tree stop with watchdog-owned force escalation. Safe to call
    /// repeatedly and from another thread while the owner is blocked reading
    /// or draining in finish(). A request racing final handle retirement is
    /// linearized by KillControl's mutex and becomes a safe no-op if too late.
    pub fn requestStop(self: *StreamProcess) void {
        const lifecycle = self.lifecycle.load(.acquire);
        if (lifecycle != .running and lifecycle != .finishing) return;
        _ = self.control.requestStopIfActive(&self.stop_requested);
    }

    /// Drain stdout, reap the leader, fence remaining descendants, join the
    /// watchdog, and close the Windows Job handle. This is the only completion
    /// operation; every successfully-started session must call it exactly once.
    pub fn finish(self: *StreamProcess) StreamResult {
        if (self.lifecycle.cmpxchgStrong(
            .running,
            .finishing,
            .acq_rel,
            .acquire,
        ) != null) return .{ .wait_failed = true, .bytes_seen = self.bytes_seen };

        // The parser may have stopped early after cancellation, malformed
        // output, or its own row cap. Drain after the stop request so the child
        // cannot block forever on a full pipe while the owner waits.
        if (self.child.stdout) |*out| {
            var drain_buf: [4096]u8 = undefined;
            while (true) {
                const n = io.read(out, &drain_buf) catch {
                    self.requestStop();
                    break;
                };
                if (n == 0) break;
                self.bytes_seen +|= n;
                if (self.bytes_seen > self.options.max_output_bytes and
                    !self.output_limited.load(.acquire))
                {
                    self.output_limited.store(true, .release);
                    self.requestStop();
                }
            }
        }

        var wait_failed = false;
        const term: ?io.Child.Term = self.child.wait() catch blk: {
            wait_failed = true;
            _ = self.control.signalIfActive(true);
            break :blk self.child.kill() catch null;
        };

        self.done.store(true, .release);
        self.control.finish(&self.child);
        if (self.watchdog) |thread| thread.join();
        self.watchdog = null;
        const result: StreamResult = .{
            .term = term,
            .timed_out = self.timed_out.load(.acquire),
            .cancelled = self.cancelled.load(.acquire),
            .stop_requested = self.stop_requested.load(.acquire),
            .output_limited = self.output_limited.load(.acquire),
            .wait_failed = wait_failed,
            .bytes_seen = self.bytes_seen,
        };
        // Publish completion only after the watchdog has joined and the tree
        // has been marked inactive and closed under KillControl's mutex.
        self.lifecycle.store(.finished, .release);
        return result;
    }
};

fn requirePosix() !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi)
        return error.SkipZigTest;
}

test "bounded process returns output and zero exit" {
    try requirePosix();
    var output: [32]u8 = undefined;
    const result = run(&.{ "/bin/sh", "-c", "printf 'opal'" }, &output, .{});
    try std.testing.expect(result.ok());
    try std.testing.expectEqualStrings("opal", result.output);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
}

test "bounded process reports nonzero exit with bounded output" {
    try requirePosix();
    var output: [32]u8 = undefined;
    const result = run(&.{ "/bin/sh", "-c", "printf 'bad'; exit 7" }, &output, .{});
    try std.testing.expectEqual(Failure.nonzero_exit, result.failure);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    try std.testing.expectEqualStrings("bad", result.output);
}

test "bounded process stops tree as soon as output exceeds capacity" {
    try requirePosix();
    var output: [4]u8 = undefined;
    const before = io.monotonicMilliTimestamp();
    const result = run(
        &.{ "/bin/sh", "-c", "printf '12345'; trap '' TERM; sleep 10" },
        &output,
        .{ .timeout_ms = 2_000, .terminate_grace_ms = 20 },
    );
    const elapsed = io.monotonicMilliTimestamp() - before;
    try std.testing.expectEqual(Failure.output_limit, result.failure);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("1234", result.output);
    try std.testing.expect(elapsed < 1_500);
}

test "output limit stays bounded when the first group kill is missed" {
    try requirePosix();
    skip_first_group_kill_for_test = true;
    defer skip_first_group_kill_for_test = false;

    var output: [4]u8 = undefined;
    const before = io.monotonicMilliTimestamp();
    const result = run(
        // The leader and descendant both ignore TERM, and the descendant owns
        // stdout. The injected missed group signal therefore exercises both
        // fallbacks: direct leader kill and closing our pipe before the final
        // process-group fence retires the descendant.
        &.{ "/bin/sh", "-c", "trap '' TERM; (trap '' TERM; sleep 10) & printf '12345'; wait" },
        &output,
        .{ .timeout_ms = 2_000, .terminate_grace_ms = 20 },
    );
    const elapsed = io.monotonicMilliTimestamp() - before;
    try std.testing.expectEqual(Failure.output_limit, result.failure);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("1234", result.output);
    try std.testing.expect(elapsed < 1_500);
}

test "deadline kills descendants that inherited stdout" {
    try requirePosix();
    var output: [32]u8 = undefined;
    const before = io.monotonicMilliTimestamp();
    const result = run(
        &.{ "/bin/sh", "-c", "(trap '' TERM; sleep 10) & exit 0" },
        &output,
        .{ .timeout_ms = 80, .terminate_grace_ms = 20 },
    );
    const elapsed = io.monotonicMilliTimestamp() - before;
    try std.testing.expectEqual(Failure.timeout, result.failure);
    try std.testing.expect(elapsed < 1_500);
}

test "watchdog spawn failure kills tree and reaps synchronously" {
    try requirePosix();
    var output: [32]u8 = undefined;
    fail_watchdog_spawn_for_test = true;
    defer fail_watchdog_spawn_for_test = false;
    const before = io.monotonicMilliTimestamp();
    const result = run(
        &.{ "/bin/sh", "-c", "trap '' TERM; sleep 10" },
        &output,
        .{},
    );
    const elapsed = io.monotonicMilliTimestamp() - before;
    try std.testing.expectEqual(Failure.watchdog_spawn, result.failure);
    try std.testing.expect(elapsed < 1_500);
}

test "empty argv and empty output are rejected before spawn" {
    var output: [1]u8 = undefined;
    try std.testing.expectEqual(Failure.invalid_input, run(&.{}, &output, .{}).failure);
    try std.testing.expectEqual(Failure.invalid_input, run(&.{""}, &output, .{}).failure);
    try std.testing.expectEqual(Failure.invalid_input, run(&.{"noop"}, output[0..0], .{}).failure);
}

test "stream process preserves incremental output and clean exit" {
    try requirePosix();
    var process = StreamProcess.init(&.{ "/bin/sh", "-c", "printf 'one\\ntwo\\n'" }, .{});
    try process.start();
    var read_buf: [32]u8 = undefined;
    const n = try io.readAll(process.stdout().?, &read_buf);
    try std.testing.expect(process.noteOutput(n));
    const result = process.finish();
    try std.testing.expect(result.ok());
    try std.testing.expectEqualStrings("one\ntwo\n", read_buf[0..n]);
}

test "stream deadline kills descendants that inherit stdout" {
    try requirePosix();
    var process = StreamProcess.init(
        &.{ "/bin/sh", "-c", "(trap '' TERM; sleep 10) & exit 0" },
        .{ .timeout_ms = 80, .terminate_grace_ms = 20 },
    );
    try process.start();
    const before = io.monotonicMilliTimestamp();
    const result = process.finish();
    const elapsed = io.monotonicMilliTimestamp() - before;
    try std.testing.expect(result.timed_out);
    try std.testing.expect(elapsed < 1_500);
}

test "stream generation cancellation interrupts a blocked reader and tree" {
    try requirePosix();
    var epoch = std.atomic.Value(u64).init(7);
    var process = StreamProcess.init(
        &.{ "/bin/sh", "-c", "trap '' TERM; (trap '' TERM; sleep 10) & wait" },
        .{
            .timeout_ms = 5_000,
            .terminate_grace_ms = 20,
            .cancel_epoch = .{ .epoch64 = .{ .value = &epoch, .expected = 7 } },
        },
    );
    try process.start();
    epoch.store(8, .release);
    const before = io.monotonicMilliTimestamp();
    const result = process.finish();
    const elapsed = io.monotonicMilliTimestamp() - before;
    try std.testing.expect(result.cancelled);
    try std.testing.expect(elapsed < 1_500);
}

test "cross-thread stop remains valid after finish starts draining" {
    try requirePosix();
    var process = StreamProcess.init(
        &.{ "/bin/sh", "-c", "trap '' TERM; (trap '' TERM; sleep 10) & wait" },
        .{ .timeout_ms = 5_000, .terminate_grace_ms = 20 },
    );
    try process.start();

    var observed_finishing = std.atomic.Value(bool).init(false);
    const stopper = try std.Thread.spawn(.{}, struct {
        fn run(p: *StreamProcess, observed: *std.atomic.Value(bool)) void {
            // Synchronize on the atomic transition made at the very start of
            // finish(), then stop while its owner is blocked draining stdout.
            while (p.lifecycle.load(.acquire) != .finishing)
                io.sleep(std.time.ns_per_ms);
            observed.store(true, .release);
            p.requestStop();
        }
    }.run, .{ &process, &observed_finishing });

    const before = io.monotonicMilliTimestamp();
    const result = process.finish();
    const elapsed = io.monotonicMilliTimestamp() - before;
    stopper.join();

    try std.testing.expect(observed_finishing.load(.acquire));
    try std.testing.expect(result.stop_requested);
    try std.testing.expectEqual(StreamLifecycle.finished, process.lifecycle.load(.acquire));
    try std.testing.expect(elapsed < 1_500);

    // Once finish has retired the tree, a late request must not touch the
    // closed handle or mutate the completed result.
    process.requestStop();
    try std.testing.expectEqual(StreamLifecycle.finished, process.lifecycle.load(.acquire));
}

test "stream output budget stops and reaps an unbounded writer" {
    try requirePosix();
    var process = StreamProcess.init(
        &.{ "/bin/sh", "-c", "while :; do printf 12345678; done" },
        .{ .timeout_ms = 5_000, .terminate_grace_ms = 20, .max_output_bytes = 16 },
    );
    try process.start();
    var read_buf: [32]u8 = undefined;
    var limited = false;
    while (!limited) {
        const n = try io.read(process.stdout().?, &read_buf);
        try std.testing.expect(n > 0);
        limited = !process.noteOutput(n);
    }
    const before = io.monotonicMilliTimestamp();
    const result = process.finish();
    const elapsed = io.monotonicMilliTimestamp() - before;
    try std.testing.expect(result.output_limited);
    try std.testing.expect(elapsed < 1_500);
}

test "stream watchdog spawn failure synchronously kills and reaps tree" {
    try requirePosix();
    fail_watchdog_spawn_for_test = true;
    defer fail_watchdog_spawn_for_test = false;
    var process = StreamProcess.init(
        &.{ "/bin/sh", "-c", "trap '' TERM; (trap '' TERM; sleep 10) & wait" },
        .{},
    );
    const before = io.monotonicMilliTimestamp();
    try std.testing.expectError(error.WatchdogSpawnFailed, process.start());
    const elapsed = io.monotonicMilliTimestamp() - before;
    try std.testing.expect(elapsed < 1_500);
}
