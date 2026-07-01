const std = @import("std");
const io = @import("io_global.zig");

// Lightweight barrier for the detached download/decode workers (comic pages,
// comic covers, youtube thumbnails). Each worker brackets its body with
// `enter()`/`leave()`. At shutdown `beginShutdownAndDrain()` flips `quitting`
// and spins until the in-flight count hits zero, so the DebugAllocator leak
// check doesn't race a worker's still-live `tmp_buf`/`p_slice` (which the worker
// would free or publish on completion). Workers also poll `isQuitting()` inside
// their read loops to bail fast, and skip publishing a result once we're
// quitting — otherwise a late completion would store into an array the deinit
// path has already torn down.

var active: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var quitting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

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

/// Mark shutdown, then spin (bounded by `timeout_ms`) until tracked workers
/// drain. Returns early once the count reaches zero. A worker wedged in a
/// single blocking syscall past the deadline is the accepted residual.
pub fn beginShutdownAndDrain(timeout_ms: i64) void {
    markQuitting();
    const deadline = io.milliTimestamp() + timeout_ms;
    while (active.load(.acquire) > 0 and io.milliTimestamp() < deadline) {
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

test "quitting flag flips and drain returns immediately when idle" {
    try std.testing.expect(!isQuitting());
    // No workers in flight → drain must not block for the full timeout.
    const before = io.milliTimestamp();
    beginShutdownAndDrain(5_000);
    const elapsed = io.milliTimestamp() - before;
    try std.testing.expect(isQuitting());
    try std.testing.expect(elapsed < 1_000);
}
