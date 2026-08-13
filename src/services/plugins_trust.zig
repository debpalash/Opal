//! Content-addressed trust for native/unsafe content plugins.
//!
//! The digest covers a canonical representation of the complete plugin tree,
//! not merely the manifest and known entry points. Symlinks and special files
//! fail closed: following them could hash bytes outside the reviewed bundle or
//! swap the reviewed target before execution.

const std = @import("std");

pub const MAX_TREE_ENTRIES: usize = 4096;
pub const MAX_TREE_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_PATH_BYTES: usize = 1024 * 1024;

pub const DigestError = error{
    EmptyTree,
    MissingManifest,
    MissingExecutable,
    UnsupportedFileType,
    TreeTooLarge,
    PathSetChanged,
} || std.mem.Allocator.Error || std.Io.Dir.Iterator.Error || std.Io.Dir.OpenError || std.Io.File.OpenError || std.Io.File.StatError || std.Io.File.ReadPositionalError;

const EntryKind = enum(u8) {
    directory = 'd',
    file = 'f',
};

const Entry = struct {
    path: []u8,
    kind: EntryKind,
};

const Inventory = struct {
    entries: std.ArrayList(Entry) = .empty,
    path_bytes: usize = 0,
    has_manifest: bool = false,
    has_executable: bool = false,

    fn deinit(self: *Inventory, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.path);
        self.entries.deinit(allocator);
    }
};

/// Digest an already-open plugin root. `root` must have sub-path access and
/// iteration enabled. The directory handle stays owned by the caller.
pub fn digestTree(
    system_io: std.Io,
    root: std.Io.Dir,
    allocator: std.mem.Allocator,
    out: *[32]u8,
) DigestError!void {
    var inventory = Inventory{};
    defer inventory.deinit(allocator);
    try inventoryDir(system_io, root, "", allocator, &inventory);
    if (inventory.entries.items.len == 0) return error.EmptyTree;
    if (!inventory.has_manifest) return error.MissingManifest;
    if (!inventory.has_executable) return error.MissingExecutable;

    sortInventory(&inventory);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("opal-plugin-tree-v1\x00");
    var file_bytes: u64 = 0;
    var read_buf: [16 * 1024]u8 = undefined;
    for (inventory.entries.items) |entry| {
        hash.update(&.{@intFromEnum(entry.kind)});
        hashLength(&hash, entry.path.len);
        hash.update(entry.path);
        if (entry.kind == .directory) continue;

        // Both flags are important. no-follow prevents a file found during
        // inventory from being swapped for a symlink; resolve_beneath rejects
        // a path resolution that escapes the reviewed root when supported.
        var file = try root.openFile(system_io, entry.path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        });
        defer file.close(system_io);
        const before = try file.stat(system_io);
        if (before.kind != .file) return error.PathSetChanged;
        file_bytes = std.math.add(u64, file_bytes, before.size) catch return error.TreeTooLarge;
        if (file_bytes > MAX_TREE_BYTES) return error.TreeTooLarge;
        hashU64(&hash, before.size);

        var read_total: u64 = 0;
        while (true) {
            // Plugin entries are regular files, so use explicit positional
            // reads. Besides avoiding shared cursor state during revalidation,
            // this is portable to Windows where Zig 0.16's streaming read on a
            // no-follow directory-relative handle can return INVALID_PARAMETER.
            const n = try file.readPositionalAll(system_io, &read_buf, read_total);
            if (n == 0) break;
            read_total = std.math.add(u64, read_total, n) catch return error.TreeTooLarge;
            if (read_total > before.size or read_total > MAX_TREE_BYTES)
                return error.PathSetChanged;
            hash.update(read_buf[0..n]);
        }

        // Refuse a digest assembled while a file was being replaced or
        // rewritten. This is not a substitute for OS sandboxing, but it closes
        // the practical approval-vs-spawn race down to the final exec call.
        const after = try file.stat(system_io);
        if (read_total != before.size or
            after.kind != .file or
            after.inode != before.inode or
            after.size != before.size or
            after.mtime.nanoseconds != before.mtime.nanoseconds or
            after.ctime.nanoseconds != before.ctime.nanoseconds)
            return error.PathSetChanged;
    }
    // A second no-follow inventory catches additions, removals, or path-type
    // swaps that raced the hashing pass. File-level before/after stats above
    // cover in-place rewrites during each read.
    var verify = Inventory{};
    defer verify.deinit(allocator);
    try inventoryDir(system_io, root, "", allocator, &verify);
    sortInventory(&verify);
    if (!sameInventory(&inventory, &verify)) return error.PathSetChanged;
    hash.final(out);
}

fn inventoryDir(
    system_io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    allocator: std.mem.Allocator,
    inventory: *Inventory,
) DigestError!void {
    var iterator = dir.iterate();
    while (try iterator.next(system_io)) |raw| {
        if (inventory.entries.items.len >= MAX_TREE_ENTRIES)
            return error.TreeTooLarge;
        const path_len = prefix.len + @intFromBool(prefix.len != 0) + raw.name.len;
        inventory.path_bytes = std.math.add(usize, inventory.path_bytes, path_len) catch return error.TreeTooLarge;
        if (inventory.path_bytes > MAX_PATH_BYTES) return error.TreeTooLarge;

        const kind: EntryKind = switch (raw.kind) {
            .directory => .directory,
            .file => .file,
            // Symlinks, devices, pipes, sockets and unknown directory entry
            // kinds are all rejected instead of followed or silently omitted.
            else => return error.UnsupportedFileType,
        };

        const normalized = try allocator.alloc(u8, path_len);
        var at: usize = 0;
        if (prefix.len != 0) {
            @memcpy(normalized[0..prefix.len], prefix);
            at = prefix.len;
            normalized[at] = '/';
            at += 1;
        }
        @memcpy(normalized[at..], raw.name);

        inventory.entries.append(allocator, .{ .path = normalized, .kind = kind }) catch |err| {
            allocator.free(normalized);
            return err;
        };

        if (kind == .file) {
            if (std.mem.eql(u8, normalized, "manifest.json")) inventory.has_manifest = true;
            if (std.mem.eql(u8, normalized, "search") or
                std.mem.eql(u8, normalized, "trending") or
                std.mem.eql(u8, normalized, "resolve"))
                inventory.has_executable = true;
            continue;
        }

        // The no-follow open closes the iterator-entry-to-directory race. The
        // child handle also anchors recursion if its name is renamed later.
        var child = try dir.openDir(system_io, raw.name, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer child.close(system_io);
        try inventoryDir(system_io, child, normalized, allocator, inventory);
    }
}

fn sortInventory(inventory: *Inventory) void {
    std.sort.block(Entry, inventory.entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

fn sameInventory(a: *const Inventory, b: *const Inventory) bool {
    if (a.entries.items.len != b.entries.items.len) return false;
    for (a.entries.items, b.entries.items) |left, right| {
        if (left.kind != right.kind or !std.mem.eql(u8, left.path, right.path))
            return false;
    }
    return true;
}

fn hashLength(hash: *std.crypto.hash.sha2.Sha256, len: usize) void {
    hashU64(hash, @intCast(len));
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .big);
    hash.update(&encoded);
}

fn addFixture(root: std.Io.Dir, system_io: std.Io, reverse: bool) !void {
    try root.createDirPath(system_io, "assets/nested");
    if (reverse) {
        try root.writeFile(system_io, .{ .sub_path = "assets/nested/data.txt", .data = "payload" });
        try root.writeFile(system_io, .{ .sub_path = "search", .data = "#!/bin/sh\n" });
        try root.writeFile(system_io, .{ .sub_path = "manifest.json", .data = "{\"name\":\"fixture\"}" });
    } else {
        try root.writeFile(system_io, .{ .sub_path = "manifest.json", .data = "{\"name\":\"fixture\"}" });
        try root.writeFile(system_io, .{ .sub_path = "search", .data = "#!/bin/sh\n" });
        try root.writeFile(system_io, .{ .sub_path = "assets/nested/data.txt", .data = "payload" });
    }
}

test "full-tree digest is deterministic across filesystem iteration order" {
    const system_io = std.testing.io;
    var a = std.testing.tmpDir(.{ .iterate = true });
    defer a.cleanup();
    var b = std.testing.tmpDir(.{ .iterate = true });
    defer b.cleanup();
    try addFixture(a.dir, system_io, false);
    try addFixture(b.dir, system_io, true);
    var digest_a: [32]u8 = undefined;
    var digest_b: [32]u8 = undefined;
    try digestTree(system_io, a.dir, std.testing.allocator, &digest_a);
    try digestTree(system_io, b.dir, std.testing.allocator, &digest_b);
    try std.testing.expectEqualSlices(u8, &digest_a, &digest_b);
}

test "changing an unlisted nested asset invalidates plugin approval digest" {
    const system_io = std.testing.io;
    var root = std.testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try addFixture(root.dir, system_io, false);
    var before: [32]u8 = undefined;
    var after: [32]u8 = undefined;
    try digestTree(system_io, root.dir, std.testing.allocator, &before);
    try root.dir.writeFile(system_io, .{ .sub_path = "assets/nested/data.txt", .data = "changed" });
    try digestTree(system_io, root.dir, std.testing.allocator, &after);
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "symlinks fail closed instead of hashing an external target" {
    const system_io = std.testing.io;
    var root = std.testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try addFixture(root.dir, system_io, false);
    root.dir.symLink(system_io, "manifest.json", "alias", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => if (@import("builtin").os.tag == .windows) return error.SkipZigTest else return err,
        else => return err,
    };
    var digest: [32]u8 = undefined;
    try std.testing.expectError(
        error.UnsupportedFileType,
        digestTree(system_io, root.dir, std.testing.allocator, &digest),
    );
}

test "manifest and executable are required for a trust identity" {
    const system_io = std.testing.io;
    var root = std.testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    try root.dir.writeFile(system_io, .{ .sub_path = "manifest.json", .data = "{}" });
    var digest: [32]u8 = undefined;
    try std.testing.expectError(
        error.MissingExecutable,
        digestTree(system_io, root.dir, std.testing.allocator, &digest),
    );
}
