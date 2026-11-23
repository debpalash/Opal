//! Test-only root for modules that use core/io_global.zig.
//!
//! It sits at src/ so `../core/...` imports from services/ and player/ stay
//! inside the module root, and each test installs a core/mock_io.zig MockIo
//! (fake clock, virtual sleep, temp-dir CWD) instead of touching real time or
//! the user's working directory. Register new cross-boundary modules here.
const std = @import("std");
const io_global = @import("core/io_global.zig");
const MockIo = @import("core/mock_io.zig").MockIo;

test {
    _ = @import("core/work_pool.zig");
    _ = @import("core/rate_limit.zig");
    _ = @import("core/scrobble_bus.zig");
    _ = @import("services/remote_http.zig");
}

test "MockIo: clock wrappers read the fake clock" {
    var mock = MockIo.init();
    mock.install();
    defer mock.deinit();
    const wall = io_global.milliTimestamp();
    const mono = io_global.monotonicMilliTimestamp();
    try std.testing.expectEqual(mock.wallMs(), wall);
    try std.testing.expectEqual(@divTrunc(wall, 1000), io_global.timestamp());
    io_global.sleep(90 * std.time.ns_per_s);
    try std.testing.expectEqual(wall + 90_000, io_global.milliTimestamp());
    try std.testing.expectEqual(mono + 90_000, io_global.monotonicMilliTimestamp());
    try std.testing.expectEqual(@as(u64, 1), mock.sleep_calls.load(.acquire));
}

test "MockIo: cwd file wrappers stay inside the sandbox" {
    var mock = MockIo.init();
    mock.install();
    defer mock.deinit();
    try io_global.cwdMakePath("cfg/opal");
    try io_global.cwdWriteFile(.{ .sub_path = "cfg/opal/state.json", .data = "{\"ok\":true}" });
    const got = try io_global.cwdReadFileAlloc("cfg/opal/state.json", std.testing.allocator, 1024);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"ok\":true}", got);
    // The file landed in the MockIo temp dir, not the process CWD.
    _ = try mock.dir().statFile(std.testing.io, "cfg/opal/state.json", .{});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, "cfg/opal/state.json", .{}));
    try io_global.cwdDeleteFile("cfg/opal/state.json");
    try std.testing.expectError(error.FileNotFound, io_global.cwdStatFile("cfg/opal/state.json"));
}

test "MockIo: uninstall restores the real clock" {
    {
        var mock = MockIo.init();
        mock.install();
        mock.advanceMs(365 * 24 * 3600 * 1000);
        mock.deinit();
    }
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    try std.testing.expect(@abs(io_global.timestamp() - @as(i64, @intCast(tv.sec))) <= 1);
}
