//! Race-resistant file opens for browser media routes.
//!
//! Security depends on walking from an already-open download-root directory
//! and refusing symlinks for every component.  Joining strings, canonicalizing
//! a pathname, and opening it afterwards would leave a check/open race.

const std = @import("std");
const pure = @import("remote_stream_pure.zig");

pub const OpenError = std.Io.Dir.OpenError || std.Io.File.OpenError || std.Io.File.StatError || error{
    UnsafePath,
    UnsupportedFileType,
};

/// Open `rel` below `root`. `root` remains owned by the caller; the returned
/// file is owned by the caller. Every intermediate directory is opened without
/// following symlinks, so renames after an open cannot redirect the walk.
pub fn openRegularAt(io: std.Io, root: std.Io.Dir, rel: []const u8) OpenError!std.Io.File {
    if (!pure.safeRelPath(rel)) return error.UnsafePath;

    var current = root;
    var owns_current = false;
    defer if (owns_current) current.close(io);

    var components = std.mem.splitScalar(u8, rel, '/');
    var component = components.next() orelse return error.UnsafePath;
    while (components.next()) |next| {
        const child = try current.openDir(io, component, .{
            .follow_symlinks = false,
        });
        if (owns_current) current.close(io);
        current = child;
        owns_current = true;
        component = next;
    }

    const file = try current.openFile(io, component, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsupportedFileType;
    return file;
}

test "opens a regular file below the supplied root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "show/season");
    try tmp.dir.writeFile(io, .{ .sub_path = "show/season/episode.mkv", .data = "media" });

    var file = try openRegularAt(io, tmp.dir, "show/season/episode.mkv");
    defer file.close(io);
    // Zig 0.16's Windows testing backend opens this handle synchronously but
    // readPositionalAll assumes an overlapped handle and panics on PENDING.
    // The confinement contract is already proven by the successful no-follow
    // open; use metadata for the cross-platform assertion on Windows.
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expectEqual(@as(u64, 5), try file.length(io));
        return;
    }
    var bytes: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try file.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings("media", &bytes);
}

test "rejects traversal and platform-specific path syntax" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const attacks = [_][]const u8{
        "../outside",
        "nested/../../outside",
        "/absolute",
        "C:/Windows/win.ini",
        "C:\\Windows\\win.ini",
        "\\\\server\\share\\file",
        "nested\\..\\outside",
        "nested//file",
        "nested/./file",
    };
    for (attacks) |attack|
        try std.testing.expectError(error.UnsafePath, openRegularAt(io, tmp.dir, attack));
}

test "rejects a symlinked intermediate directory and final file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();

    try outside.dir.writeFile(io, .{ .sub_path = "secret", .data = "outside" });
    var file_target_buf: [64]u8 = undefined;
    const file_target = try std.fmt.bufPrint(&file_target_buf, "../{s}/secret", .{outside.sub_path});
    try root.dir.symLink(io, file_target, "final-link", .{});
    if (openRegularAt(io, root.dir, "final-link")) |file| {
        file.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}

    // The target only needs to be a directory: no bytes outside the root may
    // be reachable, regardless of whether the symlink is relative or absolute.
    var dir_target_buf: [64]u8 = undefined;
    const dir_target = try std.fmt.bufPrint(&dir_target_buf, "../{s}", .{outside.sub_path});
    try root.dir.symLink(io, dir_target, "dir-link", .{ .is_directory = true });
    if (openRegularAt(io, root.dir, "dir-link/secret")) |file| {
        file.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "rejects non-regular final objects" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "directory", .default_dir);
    try std.testing.expectError(error.IsDir, openRegularAt(io, tmp.dir, "directory"));
}
