const std = @import("std");
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
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

var slots: [MAX_OWNED_THREADS]Slot = [_]Slot{.{}} ** MAX_OWNED_THREADS;
var slots_mutex: sync.Mutex = .{};

var active: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var quitting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Initialize admission before any service is allowed to start work.
pub fn init() void {
    quitting.store(false, .release);
}

fn reapFinishedLocked() void {
    for (&slots) |*slot| {
        if (slot.thread != null and slot.finished.load(.acquire)) {
            slot.thread.?.join();
            slot.thread = null;
            slot.finished.store(false, .release);
        }
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
            slots[index].finished.store(true, .release);
        }
    };

    const context = try std.heap.c_allocator.create(Context);
    errdefer std.heap.c_allocator.destroy(context);

    slots_mutex.lock();
    defer slots_mutex.unlock();
    if (isQuitting()) return error.ShuttingDown;
    reapFinishedLocked();

    var index: ?usize = null;
    for (&slots, 0..) |*slot, i| {
        if (slot.thread == null) {
            index = i;
            break;
        }
    }
    const selected = index orelse return error.WorkQueueFull;
    context.* = .{ .args = args, .slot_index = selected };
    slots[selected].finished.store(false, .release);
    slots[selected].thread = try std.Thread.spawn(.{}, Context.run, .{context});
}

/// Compatibility admission seam for code that still needs a native Thread
/// handle (for an explicit join, platform API, or staged migration). The task
/// is nevertheless counted from admission through completion, so process
/// shutdown cannot destroy shared state while it is running. New fire-and-
/// forget work should use `spawn`, which additionally retains and joins the
/// handle in the bounded slot table.
pub fn spawnLegacy(comptime function: anytype, args: anytype) !std.Thread {
    if (isQuitting()) return error.ShuttingDown;

    // This compatibility path is bounded too. Reserving before allocation and
    // spawn gives callers immediate backpressure instead of recreating the old
    // unbounded detached-thread storm under a different name.
    const previous = active.fetchAdd(1, .acq_rel);
    if (previous >= MAX_LEGACY_TASKS) {
        _ = active.fetchSub(1, .acq_rel);
        return error.WorkQueueFull;
    }
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
        slots_mutex.lock();
        reapFinishedLocked();
        var owned: usize = 0;
        for (&slots) |*slot| if (slot.thread != null) {
            owned += 1;
        };
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
