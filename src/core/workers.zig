const std = @import("std");
const builtin = @import("builtin");
const io = @import("io_global.zig");

// Process-owned worker supervisor. New work is admitted through `spawn`, which
// keeps every thread handle and joins it before shared application state is
// destroyed. The older enter/leave counter remains while legacy call sites are
// migrated; shutdown waits for both populations and never frees state while a
// worker can still publish into it.

const sync = @import("sync.zig");

const MAX_OWNED_THREADS: usize = 256;
const MAX_LEGACY_TASKS: i64 = 256;

const Slot = struct {
    thread: ?std.Thread = null,
};

var slots: [MAX_OWNED_THREADS]Slot = [_]Slot{.{}} ** MAX_OWNED_THREADS;
var slots_mutex: sync.Mutex = .{};

// Slot indices whose worker finished but whose handle is not joined yet. A
// worker appends here under slots_mutex as its last act, so admission and the
// reap never scan the whole table to find reusable slots.
var finished_slots: [MAX_OWNED_THREADS]u8 = undefined;
var finished_len: usize = 0;

// Slot indices with no live thread (never used, or joined and returned). LIFO,
// so `spawn` admits in O(1) instead of probing 256 entries per submission.
var free_slots: [MAX_OWNED_THREADS]u8 = undefined;
var free_len: usize = 0;

// init() runs before any worker exists and before every test in this file, so
// rebuilding both index stacks there keeps the tables self-consistent.
fn resetSlotIndex() void {
    for (&slots) |*slot| slot.thread = null;
    for (0..MAX_OWNED_THREADS) |i| {
        free_slots[i] = @intCast(MAX_OWNED_THREADS - 1 - i);
    }
    free_len = MAX_OWNED_THREADS;
    finished_len = 0;
}

var active: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var quitting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var shutdown_complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

// Test-only scheduling seam: suspend a legacy caller after its optimistic
// shutdown check, before it reserves an active task. Production builds omit it.
var legacy_admission_hook_for_test: ?*const fn () void = null;
var drain_after_reap_hook_for_test: ?*const fn () void = null;

/// Initialize admission before any service is allowed to start work.
pub fn init() void {
    slots_mutex.lock();
    resetSlotIndex();
    slots_mutex.unlock();
    quitting.store(false, .release);
    shutdown_complete.store(true, .release);
}

/// Arm a process-level ceiling for application teardown. This thread is
/// deliberately outside the supervised worker set: its job is to end the
/// process if a buggy worker or third-party destructor prevents that set from
/// draining. The OS then reclaims memory and handles, which is preferable to a
/// permanently frozen window that the compositor must kill.
pub fn armShutdownDeadline(timeout_ms: i64) void {
    shutdown_complete.store(false, .release);
    const Guard = struct {
        fn run(limit_ms: i64) void {
            const started = io.milliTimestamp();
            while (!shutdown_complete.load(.acquire)) {
                if (shutdownDeadlineReached(started, io.milliTimestamp(), limit_ms)) {
                    std.debug.print("[shutdown] teardown exceeded {d}ms; forcing process exit\n", .{limit_ms});
                    std.process.exit(0);
                }
                io.sleep(10 * std.time.ns_per_ms);
            }
        }
    };
    const guard = std.Thread.spawn(.{}, Guard.run, .{timeout_ms}) catch return;
    guard.detach();
}

pub fn finishShutdown() void {
    shutdown_complete.store(true, .release);
}

pub fn shutdownDeadlineReached(started_ms: i64, now_ms: i64, timeout_ms: i64) bool {
    return now_ms - started_ms >= @max(timeout_ms, 1);
}

fn pushFreeLocked(index: usize) void {
    std.debug.assert(free_len < MAX_OWNED_THREADS);
    free_slots[free_len] = @intCast(index);
    free_len += 1;
}

/// Hand a finished worker's index back to admission. Called by the worker itself
/// as its final act, so the handle is joined by whichever reaper drains the list.
fn publishFinished(index: usize) void {
    slots_mutex.lock();
    std.debug.assert(finished_len < MAX_OWNED_THREADS);
    finished_slots[finished_len] = @intCast(index);
    finished_len += 1;
    slots_mutex.unlock();
}

/// Join every worker that already returned and return its slot to admission.
///
/// The join deliberately happens with `slots_mutex` released: a worker needs that
/// same lock to publish its completion, so joining under it would deadlock
/// against the very thread being waited on.
fn reapFinished() void {
    var batch: [MAX_OWNED_THREADS]u8 = undefined;
    var count: usize = 0;

    slots_mutex.lock();
    count = finished_len;
    @memcpy(batch[0..count], finished_slots[0..count]);
    finished_len = 0;
    slots_mutex.unlock();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const index: usize = batch[i];
        // Uncontended: only the reaper that claimed this index writes the slot,
        // and the slot is absent from `free_slots` until it is returned below.
        if (slots[index].thread) |thread| thread.join();
        slots_mutex.lock();
        slots[index].thread = null;
        pushFreeLocked(index);
        slots_mutex.unlock();
    }
}

/// Submit one bounded, owned, joinable task. The function's argument tuple is
/// copied into private storage, so callers must still copy any borrowed slices
/// before submission. `isQuitting()` is the cooperative cancellation token.
pub fn spawn(comptime function: anytype, args: anytype) !void {
    if (isQuitting()) return error.ShuttingDown;

    const Args = @TypeOf(args);
    const Context = struct {
        args: Args,
        slot_index: usize,

        fn run(ctx: *@This()) void {
            @call(.auto, function, ctx.args);
            const index = ctx.slot_index;
            std.heap.c_allocator.destroy(ctx);
            publishFinished(index);
        }
    };

    const context = try std.heap.c_allocator.create(Context);
    errdefer std.heap.c_allocator.destroy(context);

    // Reclaim finished workers before admission. This takes slots_mutex itself,
    // so it has to happen outside the critical section below.
    reapFinished();

    slots_mutex.lock();
    defer slots_mutex.unlock();
    if (isQuitting()) return error.ShuttingDown;
    if (free_len == 0) return error.WorkQueueFull;
    free_len -= 1;
    const selected: usize = free_slots[free_len];

    context.* = .{ .args = args, .slot_index = selected };
    // Publish the handle before the worker can run: a concurrent reap only ever
    // visits indices a worker listed as finished, and it must never observe an
    // empty slot there, or the join would be dropped.
    slots[selected].thread = std.Thread.spawn(.{}, Context.run, .{context}) catch |err| {
        pushFreeLocked(selected);
        return err;
    };
}

/// Compatibility admission seam for code that still needs a native Thread
/// handle (for an explicit join, platform API, or staged migration). The task
/// is nevertheless counted from admission through completion, so process
/// shutdown cannot destroy shared state while it is running. New fire-and-
/// forget work should use `spawn`, which additionally retains and joins the
/// handle in the bounded slot table.
pub fn spawnLegacy(comptime function: anytype, args: anytype) !std.Thread {
    if (isQuitting()) return error.ShuttingDown;
    if (builtin.is_test) {
        if (legacy_admission_hook_for_test) |hook| hook();
    }

    try reserveLegacyTask();
    errdefer leave();

    const Args = @TypeOf(args);
    const Context = struct {
        args: Args,

        fn run(ctx: *@This()) void {
            @call(.auto, function, ctx.args);
            std.heap.c_allocator.destroy(ctx);
            leave();
        }
    };

    const context = try std.heap.c_allocator.create(Context);
    errdefer std.heap.c_allocator.destroy(context);
    context.* = .{ .args = args };
    return std.Thread.spawn(.{}, Context.run, .{context}) catch |err| {
        return err;
    };
}

fn reserveLegacyTask() !void {
    // Admission and the drain's empty-worker observation share one lock. A
    // quitting check followed by an unlocked increment allowed this ordering:
    // check(false) -> drain sees zero and returns -> increment -> start worker.
    // That worker could access application state after teardown had freed it.
    // Re-check under the drain lock, then reserve before releasing it. Allocation
    // and OS thread creation stay outside the lock; the reservation protects
    // both until either the worker completes or spawn's errdefer releases it.
    slots_mutex.lock();
    defer slots_mutex.unlock();
    if (isQuitting()) return error.ShuttingDown;
    const previous = active.fetchAdd(1, .acq_rel);
    if (previous >= MAX_LEGACY_TASKS) {
        _ = active.fetchSub(1, .acq_rel);
        return error.WorkQueueFull;
    }
}

/// Relinquish a compatibility handle after `spawnLegacy` has registered its
/// completion with the shutdown barrier. Keeping the raw detach operation here
/// makes unmanaged detaches mechanically rejectable in application modules.
pub fn release(thread: std.Thread) void {
    thread.detach();
}

/// Register entry into a tracked worker. Pair with `leave()` via `defer`.
pub fn enter() void {
    _ = active.fetchAdd(1, .acq_rel);
}

/// Register exit from a tracked worker.
pub fn leave() void {
    _ = active.fetchSub(1, .acq_rel);
}

/// In-flight tracked-worker count.
pub fn activeCount() i64 {
    return active.load(.acquire);
}

/// True once shutdown has begun. Workers should free their scratch/result
/// buffers and return instead of publishing into shared state.
pub fn isQuitting() bool {
    return quitting.load(.acquire);
}

/// Stable cancellation token for process watchdogs that must interrupt a
/// blocked child as soon as application teardown begins.
pub fn quittingSignal() *const std.atomic.Value(bool) {
    return &quitting;
}

/// Set the quitting flag only (no wait). Split out for unit testing.
pub fn markQuitting() void {
    quitting.store(true, .release);
}

/// Stop admission, request cooperative cancellation, and join every owned
/// worker. `diagnostic_ms` controls when a visible slow-shutdown warning is
/// emitted; it is not a use-after-free timeout.
pub fn beginShutdownAndDrain(diagnostic_ms: i64) void {
    markQuitting();
    const started = io.milliTimestamp();
    var warned = false;
    while (true) {
        reapFinished();
        if (builtin.is_test) {
            if (drain_after_reap_hook_for_test) |hook| hook();
        }
        slots_mutex.lock();
        // Finished-but-unjoined workers still own their slot and handle.
        // A completion can arrive after reapFinished took its batch; excluding
        // finished_len here would let teardown return before the next join.
        const owned = MAX_OWNED_THREADS - free_len;
        slots_mutex.unlock();
        if (owned == 0 and active.load(.acquire) == 0) return;
        if (!warned and io.milliTimestamp() - started >= diagnostic_ms) {
            std.debug.print("[workers] waiting for {d} owned + {d} legacy worker(s) during shutdown\n", .{ owned, active.load(.acquire) });
            warned = true;
        }
        io.sleep(5 * std.time.ns_per_ms);
    }
}

test "enter/leave track the in-flight count" {
    try std.testing.expectEqual(@as(i64, 0), activeCount());
    enter();
    enter();
    try std.testing.expectEqual(@as(i64, 2), activeCount());
    leave();
    try std.testing.expectEqual(@as(i64, 1), activeCount());
    leave();
    try std.testing.expectEqual(@as(i64, 0), activeCount());
}

test "owned tasks are accepted and joined before shutdown returns" {
    const T = struct {
        var ran: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        fn run() void {
            ran.store(true, .release);
        }
    };
    init();
    T.ran.store(false, .release);
    try spawn(T.run, .{});
    beginShutdownAndDrain(1_000);
    try std.testing.expect(T.ran.load(.acquire));
}

test "sequential spawns recycle slots instead of exhausting the table" {
    const T = struct {
        fn run() void {}
    };
    init();
    // Far more submissions than MAX_OWNED_THREADS: every finished worker must
    // return its slot to admission, otherwise the table drains after 256
    // submissions and later work is silently dropped with WorkQueueFull.
    var i: usize = 0;
    while (i < MAX_OWNED_THREADS * 4) : (i += 1) {
        // A full table is momentarily legitimate while the previous burst is
        // still unreaped; the invariant under test is that it never stays full.
        var attempts: usize = 0;
        while (true) {
            spawn(T.run, .{}) catch |err| {
                try std.testing.expectEqual(error.WorkQueueFull, err);
                attempts += 1;
                if (attempts > 10_000) return error.TestUnexpectedResult;
                io.sleep(std.time.ns_per_ms);
                continue;
            };
            break;
        }
    }
    beginShutdownAndDrain(10_000);
    slots_mutex.lock();
    defer slots_mutex.unlock();
    try std.testing.expectEqual(MAX_OWNED_THREADS, free_len);
    try std.testing.expectEqual(@as(usize, 0), finished_len);
}

test "a full slot table is reported instead of overwriting a live worker" {
    const T = struct {
        var gate: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        fn run() void {
            while (!gate.load(.acquire)) io.sleep(std.time.ns_per_ms);
        }
    };
    init();
    T.gate.store(false, .release);

    var admitted: usize = 0;
    while (admitted < MAX_OWNED_THREADS) : (admitted += 1) {
        try spawn(T.run, .{});
    }
    try std.testing.expectError(error.WorkQueueFull, spawn(T.run, .{}));
    T.gate.store(true, .release);
    beginShutdownAndDrain(10_000);
    try std.testing.expectEqual(@as(i64, 0), activeCount());
}

test "legacy native handles remain behind the shutdown barrier after detach" {
    const T = struct {
        var ran: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        fn run() void {
            io.sleep(2 * std.time.ns_per_ms);
            ran.store(true, .release);
        }
    };
    init();
    T.ran.store(false, .release);
    const thread = try spawnLegacy(T.run, .{});
    thread.detach();
    beginShutdownAndDrain(1_000);
    try std.testing.expect(T.ran.load(.acquire));
    try std.testing.expectEqual(@as(i64, 0), activeCount());
}

test "legacy admission resumed after shutdown cannot start an untracked task" {
    const T = struct {
        var at_admission = std.atomic.Value(bool).init(false);
        var resume_admission = std.atomic.Value(bool).init(false);
        var rejected = std.atomic.Value(bool).init(false);
        var ran = std.atomic.Value(bool).init(false);

        fn pauseAdmission() void {
            at_admission.store(true, .release);
            while (!resume_admission.load(.acquire))
                io.sleep(std.time.ns_per_ms);
        }

        fn task() void {
            ran.store(true, .release);
        }

        fn submit() void {
            const thread = spawnLegacy(task, .{}) catch |err| {
                rejected.store(err == error.ShuttingDown, .release);
                return;
            };
            thread.join();
        }
    };

    init();
    T.at_admission.store(false, .release);
    T.resume_admission.store(false, .release);
    T.rejected.store(false, .release);
    T.ran.store(false, .release);
    legacy_admission_hook_for_test = T.pauseAdmission;
    defer legacy_admission_hook_for_test = null;

    const submitter = try std.Thread.spawn(.{}, T.submit, .{});
    var joined = false;
    defer if (!joined) {
        T.resume_admission.store(true, .release);
        submitter.join();
    };

    // The barrier fixes the interleaving: the optimistic check already passed,
    // but shutdown must still be allowed to close admission and finish draining.
    // The deadline only detects a broken test setup; it does not create the race.
    const deadline = io.monotonicMilliTimestamp() + 2_000;
    while (!T.at_admission.load(.acquire) and io.monotonicMilliTimestamp() < deadline)
        io.sleep(std.time.ns_per_ms);
    try std.testing.expect(T.at_admission.load(.acquire));
    beginShutdownAndDrain(1_000);
    try std.testing.expectEqual(@as(i64, 0), activeCount());

    T.resume_admission.store(true, .release);
    submitter.join();
    joined = true;
    try std.testing.expect(T.rejected.load(.acquire));
    try std.testing.expect(!T.ran.load(.acquire));
    try std.testing.expectEqual(@as(i64, 0), activeCount());
}

test "quitting flag flips and drain returns immediately when idle" {
    init();
    try std.testing.expect(!isQuitting());
    // No workers in flight → drain must not block for the full timeout.
    const before = io.milliTimestamp();
    beginShutdownAndDrain(5_000);
    const elapsed = io.milliTimestamp() - before;
    try std.testing.expect(isQuitting());
    try std.testing.expect(elapsed < 1_000);
}

test "shutdown deadline has a one millisecond floor" {
    try std.testing.expect(!shutdownDeadlineReached(100, 100, 0));
    try std.testing.expect(shutdownDeadlineReached(100, 101, 0));
    try std.testing.expect(!shutdownDeadlineReached(100, 5_099, 5_000));
    try std.testing.expect(shutdownDeadlineReached(100, 5_100, 5_000));
}

test "shutdown joins workers that finish between reap and empty observation" {
    const T = struct {
        var gate = std.atomic.Value(bool).init(false);
        var invoked = false;
        var observed = false;
        fn run() void {
            while (!gate.load(.acquire)) io.sleep(std.time.ns_per_ms);
        }
        fn finishAfterReap() void {
            if (invoked) return;
            invoked = true;
            gate.store(true, .release);
            const deadline = io.monotonicMilliTimestamp() + 2_000;
            while (io.monotonicMilliTimestamp() < deadline) {
                slots_mutex.lock();
                const finished = finished_len != 0;
                slots_mutex.unlock();
                if (finished) {
                    observed = true;
                    return;
                }
                io.sleep(std.time.ns_per_ms);
            }
        }
    };
    init();
    T.gate.store(false, .release);
    T.invoked = false;
    T.observed = false;
    try spawn(T.run, .{});
    drain_after_reap_hook_for_test = T.finishAfterReap;
    defer drain_after_reap_hook_for_test = null;
    beginShutdownAndDrain(1_000);
    // Always clean up even when the old drain returns before joining.
    defer reapFinished();
    slots_mutex.lock();
    defer slots_mutex.unlock();
    try std.testing.expect(T.observed);
    try std.testing.expectEqual(MAX_OWNED_THREADS, free_len);
    for (slots) |slot| try std.testing.expect(slot.thread == null);
    try std.testing.expectEqual(@as(usize, 0), finished_len);
}
