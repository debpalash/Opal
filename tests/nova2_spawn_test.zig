const std = @import("std");
const io_global = @import("io_global");

fn workingPython() ?[]const u8 {
    for ([_][]const u8{ "python3", "python", "py" }) |candidate| {
        const argv = [_][]const u8{ candidate, "-c", "print('NOVA2_PYTHON_OK')" };
        var child = io_global.Child.init(&argv, std.testing.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch continue;

        var buf: [128]u8 = undefined;
        const n = if (child.stdout) |*out|
            io_global.readAll(out, &buf) catch 0
        else
            0;
        const term = child.wait() catch continue;
        const ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (ok and std.mem.indexOf(u8, buf[0..n], "NOVA2_PYTHON_OK") != null)
            return candidate;
    }
    return null;
}

// Regression for the exact failure mode that made every installed torrent
// source return zero rows: nova2 is launched by Zig's std.Io.Threaded runtime,
// then its app-mode dispatcher fans work out inside Python. A process pool at
// that seam crashes Python's resource tracker with BrokenPipeError.
test "nova2 app pool runs when spawned through Zig std.Io" {
    const python = workingPython() orelse return error.SkipZigTest;
    const argv = [_][]const u8{
        python,
        "engines/nova2.py",
        "--timeout=2",
        "--pool-selftest",
    };

    var child = io_global.Child.init(&argv, std.testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_buf: [4096]u8 = undefined;
    const stdout_len = if (child.stdout) |*out|
        try io_global.readAll(out, &stdout_buf)
    else
        0;
    var stderr_buf: [4096]u8 = undefined;
    const stderr_len = if (child.stderr) |*err|
        try io_global.readAll(err, &stderr_buf)
    else
        0;

    const term = try child.wait();
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTermination,
    }
    try std.testing.expectEqual(@as(usize, 0), stderr_len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        stdout_buf[0..stdout_len],
        "NOVA2_APP_POOL_OK",
    ) != null);
}
