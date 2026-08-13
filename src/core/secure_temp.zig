//! Private scratch workspaces for request bodies, transcripts, and media.
//!
//! A workspace is a cryptographically random directory below the platform
//! temp root.  On POSIX the directory is owner-only (0700), every file this
//! module creates is owner-only (0600), and creation is exclusive.  Keeping
//! the policy here prevents callers from accidentally reintroducing fixed
//! names in a shared `/tmp` directory.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("io_global.zig");

pub const max_path_len = 1024;
const random_len = 16;
const max_attempts = 32;

pub const Workspace = struct {
    dir_buf: [max_path_len]u8 = undefined,
    dir_len: usize = 0,
    active: bool = false,

    /// Create a fresh private directory. `purpose` appears in the directory
    /// name for diagnostics and must be a single conservative path component.
    pub fn create(purpose: []const u8) !Workspace {
        if (!safeComponent(purpose)) return error.InvalidPurpose;

        var result: Workspace = .{};
        var tmp_buf: [max_path_len]u8 = undefined;
        const temp_root = io.tmpDir(&tmp_buf);

        var attempt: usize = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            var random: [random_len]u8 = undefined;
            if (!io.randomSecure(&random)) return error.EntropyUnavailable;
            const hex = std.fmt.bytesToHex(random, .lower);
            const dir_path = std.fmt.bufPrint(
                &result.dir_buf,
                "{s}/opal-{s}-{s}",
                .{ temp_root, purpose, &hex },
            ) catch return error.NameTooLong;

            std.Io.Dir.createDirAbsolute(io.io(), dir_path, dirPermissions()) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            result.dir_len = dir_path.len;
            result.active = true;

            // Do not rely on the process umask for the final POSIX mode.
            if (builtin.os.tag != .windows) {
                std.Io.Dir.cwd().setFilePermissions(
                    io.io(),
                    dir_path,
                    dirPermissions(),
                    .{ .follow_symlinks = false },
                ) catch |err| {
                    result.cleanup();
                    return err;
                };
            }
            return result;
        }
        return error.CollisionLimitExceeded;
    }

    pub fn dirPath(self: *const Workspace) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }

    /// Build a path below this workspace. Callers receive no directory handle,
    /// so traversal and nested components are deliberately rejected.
    pub fn path(self: *const Workspace, leaf: []const u8, out: []u8) ![]const u8 {
        if (!self.active) return error.WorkspaceClosed;
        if (!safeComponent(leaf)) return error.InvalidLeafName;
        return std.fmt.bufPrint(out, "{s}/{s}", .{ self.dirPath(), leaf }) catch error.NameTooLong;
    }

    /// Exclusively create and populate a 0600 file, returning its full path.
    pub fn writeFile(self: *const Workspace, leaf: []const u8, data: []const u8, out: []u8) ![]const u8 {
        const file_path = try self.path(leaf, out);
        var file = try io.createFileAbsolute(file_path, .{
            .read = false,
            .truncate = false,
            .exclusive = true,
            .permissions = filePermissions(),
        });
        errdefer io.deleteFileAbsolute(file_path) catch {};
        defer file.close(io.io());
        try io.writeAll(file, data);
        if (builtin.os.tag != .windows)
            try file.setPermissions(io.io(), filePermissions());
        return file_path;
    }

    /// Exclusively reserve a 0600 path for a subprocess that writes its output.
    /// The empty file remains in place so the subprocess truncates a file we
    /// created rather than following an attacker-controlled path.
    pub fn reserveFile(self: *const Workspace, leaf: []const u8, out: []u8) ![]const u8 {
        const file_path = try self.path(leaf, out);
        var file = try io.createFileAbsolute(file_path, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = filePermissions(),
        });
        defer file.close(io.io());
        if (builtin.os.tag != .windows)
            try file.setPermissions(io.io(), filePermissions());
        return file_path;
    }

    /// Best-effort and idempotent so it is safe in every `defer`/`errdefer`.
    pub fn cleanup(self: *Workspace) void {
        if (!self.active) return;
        io.cwdDeleteTree(self.dirPath()) catch {};
        self.active = false;
        self.dir_len = 0;
    }
};

fn safeComponent(value: []const u8) bool {
    if (value.len == 0 or value.len > 80) return false;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.')) return false;
    }
    return true;
}

fn dirPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_dir
    else
        std.Io.File.Permissions.fromMode(0o700);
}

fn filePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_file
    else
        std.Io.File.Permissions.fromMode(0o600);
}

test "workspace is random, private, exclusive, and cleaned" {
    var first = try Workspace.create("unit");
    defer first.cleanup();
    var second = try Workspace.create("unit");
    defer second.cleanup();

    try std.testing.expect(!std.mem.eql(u8, first.dirPath(), second.dirPath()));

    var path_buf: [max_path_len]u8 = undefined;
    const path = try first.writeFile("request.json", "{\"secret\":true}", &path_buf);
    try std.testing.expectError(error.PathAlreadyExists, first.writeFile("request.json", "no", &path_buf));

    var file = try io.openFileAbsolute(path, .{});
    defer file.close(io.io());
    var content: [32]u8 = undefined;
    const n = try io.readAll(file, &content);
    try std.testing.expectEqualStrings("{\"secret\":true}", content[0..n]);

    if (builtin.os.tag != .windows) {
        const file_stat = try file.stat(io.io());
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), file_stat.permissions.toMode() & 0o777);
        var dir = try io.openDirAbsolute(first.dirPath(), .{ .iterate = true });
        defer dir.close(io.io());
        const dir_stat = try dir.stat(io.io());
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);
    }

    var saved_path: [max_path_len]u8 = undefined;
    @memcpy(saved_path[0..path.len], path);
    const saved = saved_path[0..path.len];
    first.cleanup();
    try std.testing.expectError(error.FileNotFound, io.openFileAbsolute(saved, .{}));
}

test "workspace rejects traversal components" {
    var workspace = try Workspace.create("unit");
    defer workspace.cleanup();
    var path_buf: [max_path_len]u8 = undefined;
    try std.testing.expectError(error.InvalidLeafName, workspace.path("../secret", &path_buf));
    try std.testing.expectError(error.InvalidLeafName, workspace.path("nested/file", &path_buf));
}
