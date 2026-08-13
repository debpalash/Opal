//! Owner-only persistence for bearer tokens and third-party credentials.
//! One module keeps permission handling consistent across every secret file.

const std = @import("std");
const io = @import("io_global.zig");

pub fn write(path: []const u8, data: []const u8) !void {
    const permissions = if (@import("builtin").os.tag == .windows)
        std.Io.File.Permissions.default_file
    else
        std.Io.File.Permissions.fromMode(0o600);
    const file = try io.cwdCreateFile(path, .{
        .read = false,
        .truncate = true,
        .permissions = permissions,
    });
    defer file.close(io.io());
    try io.writeAll(file, data);
    if (@import("builtin").os.tag != .windows)
        try file.setPermissions(io.io(), std.Io.File.Permissions.fromMode(0o600));
}

pub fn restrictExisting(path: []const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    const file = io.cwdOpenFile(path, .{ .mode = .read_write }) catch return;
    defer file.close(io.io());
    file.setPermissions(io.io(), std.Io.File.Permissions.fromMode(0o600)) catch {};
}
