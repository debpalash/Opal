const std = @import("std");
const builtin = @import("builtin");

// ══════════════════════════════════════════════════════════
// MockIo: test-only backend for core/io_global.zig.
//
// io_global is process-wide, so modules that use it (work_pool, rate_limit,
// scrobble_bus, ...) could not run as `zig build test` tests without real
// sleeps and the user's real CWD. Installing a MockIo swaps, for the duration
// of a test:
//   - timestamp / milliTimestamp / monotonicMilliTimestamp -> a fake clock
//   - sleep -> advances the fake clock and yields (no wall time passes)
//   - every cwd* file wrapper -> a std.testing.tmpDir sandbox
//   - io() -> std.testing.io (the test runner's Io)
//
// The seam is compiled only when builtin.is_test; production builds never
// see it (io_global gates every branch on `comptime builtin.is_test`).
// ══════════════════════════════════════════════════════════

comptime {
    if (!builtin.is_test) @compileError("mock_io.zig is test-only");
}

pub const MockIo = struct {
    /// Fake wall clock (ns since epoch). Default: 2026-01-01T00:00:00Z.
    wall_ns: std.atomic.Value(i64) = .init(1_767_225_600 * std.time.ns_per_s),
    /// Fake monotonic clock (ns). Starts non-zero so "0 = never" sentinels hold.
    mono_ns: std.atomic.Value(i64) = .init(1_000 * std.time.ns_per_s),
    /// Number of io_global.sleep calls routed here.
    sleep_calls: std.atomic.Value(u64) = .init(0),
    /// Sandbox that the cwd* wrappers resolve against.
    tmp: std.testing.TmpDir,

    pub fn init() MockIo {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    /// Install as io_global's backend. Pair with `deinit`.
    pub fn install(self: *MockIo) void {
        @import("io_global.zig").installMock(self);
    }

    pub fn deinit(self: *MockIo) void {
        @import("io_global.zig").uninstallMock(self);
        self.tmp.cleanup();
    }

    pub fn advanceMs(self: *MockIo, ms: i64) void {
        self.advanceNs(ms * std.time.ns_per_ms);
    }

    pub fn advanceNs(self: *MockIo, ns: i64) void {
        _ = self.wall_ns.fetchAdd(ns, .acq_rel);
        _ = self.mono_ns.fetchAdd(ns, .acq_rel);
    }

    pub fn wallMs(self: *const MockIo) i64 {
        return @divTrunc(self.wall_ns.load(.acquire), std.time.ns_per_ms);
    }

    pub fn monoMs(self: *const MockIo) i64 {
        return @divTrunc(self.mono_ns.load(.acquire), std.time.ns_per_ms);
    }

    /// Virtual sleep: time moves, the thread only yields so spinning pollers
    /// still let other threads run.
    pub fn sleep(self: *MockIo, ns: u64) void {
        _ = self.sleep_calls.fetchAdd(1, .acq_rel);
        self.advanceNs(@intCast(@min(ns, std.math.maxInt(i64))));
        std.Thread.yield() catch {};
    }

    pub fn dir(self: *const MockIo) std.Io.Dir {
        return self.tmp.dir;
    }
};
