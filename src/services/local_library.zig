//! Persistent, recursively refreshed index of the user's local media folder.
const std = @import("std");
const db = @import("../core/db.zig");
const io = @import("../core/io_global.zig");
const state = @import("../core/state.zig");

pub const MAX_RESULTS: usize = 64;
pub const MAX_ROOTS: usize = 16;
const MAX_FILES: usize = 100_000;
const MAX_DEPTH: u8 = 16;

pub const Item = struct {
    id: i64 = 0,
    path: [2048]u8 = std.mem.zeroes([2048]u8),
    path_len: usize = 0,
    title: [256]u8 = std.mem.zeroes([256]u8),
    title_len: usize = 0,
    kind: [16]u8 = std.mem.zeroes([16]u8),
    kind_len: usize = 0,
    size: u64 = 0,
    duplicate_count: u16 = 1,
};

pub const Root = struct {
    id: i64 = 0,
    path: [1024]u8 = std.mem.zeroes([1024]u8),
    path_len: usize = 0,
};

pub var scanning = std.atomic.Value(bool).init(false);
var indexed_once = std.atomic.Value(bool).init(false);

pub fn isMediaFile(name: []const u8) bool {
    const extensions = [_][]const u8{
        ".mp4", ".m4v",  ".mkv", ".avi", ".mov",  ".webm", ".flv", ".wmv", ".mpg", ".mpeg", ".ts",   ".m2ts", ".mts", ".vob", ".3gp", ".ogv",
        ".mp3", ".flac", ".wav", ".ogg", ".opus", ".oga",  ".aac", ".m4a", ".mka", ".wma",  ".aiff",
    };
    for (extensions) |extension| {
        if (name.len > extension.len and std.ascii.eqlIgnoreCase(name[name.len - extension.len ..], extension)) return true;
    }
    return false;
}

pub fn scanAsync() void {
    if (scanning.load(.acquire) or @import("../core/workers.zig").isQuitting()) return;
    if (@import("../core/workers.zig").spawnLegacy(scanWorker, .{})) |thread|
        @import("../core/workers.zig").release(thread)
    else |_| {}
}

fn scanWorker() void {
    if (scanning.swap(true, .acq_rel)) return;
    defer scanning.store(false, .release);
    var default_buf: [1024]u8 = undefined;
    const root = if (state.app.save_path_len > 0)
        state.app.save_path_buf[0..state.app.save_path_len]
    else
        @import("../core/paths.zig").defaultSavePath(&default_buf);
    if (root.len > 0 and root.len < 1024) _ = addRoot(root);
    var roots: [MAX_ROOTS]Root = undefined;
    const root_count = listRoots(&roots);
    const token = io.monotonicMilliTimestamp();
    for (roots[0..root_count]) |*entry| {
        const root_path = entry.path[0..entry.path_len];
        if (!rootAvailable(root_path)) continue;
        var count: usize = 0;
        scanDir(root_path, root_path, token, 0, &count);
        if (@import("../core/workers.zig").isQuitting()) return;
        const stale = db.prepare("DELETE FROM local_media WHERE root=?1 AND scan_token<>?2") orelse continue;
        db.bindText(stale, 1, root_path);
        db.bindInt64(stale, 2, token);
        _ = db.step(stale);
        db.finalize(stale);
    }
    if (@import("../core/workers.zig").isQuitting()) return;
    indexed_once.store(true, .release);
    state.wakeUi();
}

fn rootAvailable(path: []const u8) bool {
    var dir = if (absolutePath(path))
        io.openDirAbsolute(path, .{ .iterate = true }) catch return false
    else
        io.cwdOpenDir(path, .{ .iterate = true }) catch return false;
    dir.close(io.io());
    return true;
}

fn scanDir(root: []const u8, path: []const u8, token: i64, depth: u8, count: *usize) void {
    if (depth > MAX_DEPTH or count.* >= MAX_FILES or @import("../core/workers.zig").isQuitting()) return;
    var dir = if (absolutePath(path))
        io.openDirAbsolute(path, .{ .iterate = true }) catch return
    else
        io.cwdOpenDir(path, .{ .iterate = true }) catch return;
    defer dir.close(io.io());
    var iterator = dir.iterate();
    while (count.* < MAX_FILES) {
        const entry = (iterator.next(io.io()) catch null) orelse break;
        var child_buf: [2048]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ path, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => scanDir(root, child, token, depth + 1, count),
            .file => {
                if (!isMediaFile(entry.name)) continue;
                indexFile(root, child, entry.name, token);
                count.* += 1;
            },
            else => {}, // never follow symlinks or special files
        }
    }
}

fn indexFile(root: []const u8, path: []const u8, basename: []const u8, token: i64) void {
    const file = if (absolutePath(path)) io.openFileAbsolute(path, .{}) catch return else io.cwdOpenFile(path, .{}) catch return;
    defer file.close(io.io());
    const stat = file.stat(io.io()) catch return;
    var title_buf: [256]u8 = undefined;
    const title = @import("../core/display_name_pure.zig").clean(&title_buf, basename);
    var fingerprint_buf: [32]u8 = undefined;
    const fingerprint = contentFingerprint(file, stat.size, &fingerprint_buf);
    const stmt = db.prepare(
        "INSERT INTO local_media(path,root,title,size,mtime,fingerprint,scan_token) VALUES(?1,?2,?3,?4,?5,?6,?7) " ++
            "ON CONFLICT(path) DO UPDATE SET root=excluded.root,title=excluded.title,size=excluded.size,mtime=excluded.mtime,fingerprint=excluded.fingerprint,scan_token=excluded.scan_token",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, path);
    db.bindText(stmt, 2, root);
    db.bindText(stmt, 3, title);
    db.bindInt64(stmt, 4, @intCast(stat.size));
    db.bindInt64(stmt, 5, @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s)));
    db.bindText(stmt, 6, fingerprint);
    db.bindInt64(stmt, 7, token);
    _ = db.step(stmt);
}

fn absolutePath(path: []const u8) bool {
    return path.len > 0 and (path[0] == '/' or path[0] == '\\' or
        (path.len >= 3 and path[1] == ':' and (path[2] == '/' or path[2] == '\\')));
}

pub fn addRoot(path_raw: []const u8) bool {
    const path = std.mem.trim(u8, path_raw, " \t\r\n");
    if (path.len == 0 or path.len >= 1024) return false;
    var dir = if (absolutePath(path)) io.openDirAbsolute(path, .{ .iterate = true }) catch return false else io.cwdOpenDir(path, .{ .iterate = true }) catch return false;
    dir.close(io.io());
    const stmt = db.prepare("INSERT OR IGNORE INTO local_library_roots(path) VALUES(?1)") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, path);
    return db.step(stmt) == db.c.SQLITE_DONE;
}

pub fn listRoots(out: []Root) usize {
    const stmt = db.prepare("SELECT rowid,path FROM local_library_roots ORDER BY added_at,path LIMIT ?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, @intCast(@min(out.len, MAX_ROOTS)));
    var count: usize = 0;
    while (count < out.len and db.step(stmt) == db.c.SQLITE_ROW) : (count += 1) {
        out[count] = .{ .id = db.columnInt64(stmt, 0) };
        db.copyColumn(stmt, 1, &out[count].path, &out[count].path_len);
    }
    return count;
}

pub fn removeRoot(id: i64) bool {
    if (id <= 0) return false;
    const media = db.prepare("DELETE FROM local_media WHERE root=(SELECT path FROM local_library_roots WHERE rowid=?1)") orelse return false;
    db.bindInt64(media, 1, id);
    const cleared = db.step(media) == db.c.SQLITE_DONE;
    db.finalize(media);
    if (!cleared) return false;
    const root = db.prepare("DELETE FROM local_library_roots WHERE rowid=?1") orelse return false;
    defer db.finalize(root);
    db.bindInt64(root, 1, id);
    return db.step(root) == db.c.SQLITE_DONE;
}

fn contentFingerprint(file: std.Io.File, size: u64, out: []u8) []const u8 {
    var hash = std.hash.Wyhash.init(0x6f70_616c_6c69_6272);
    hash.update(std.mem.asBytes(&size));
    var sample: [64 * 1024]u8 = undefined;
    const first = file.readPositionalAll(io.io(), &sample, 0) catch 0;
    hash.update(sample[0..first]);
    if (size > sample.len) {
        const offset = size - sample.len;
        const last = file.readPositionalAll(io.io(), &sample, offset) catch 0;
        hash.update(sample[0..last]);
    }
    return std.fmt.bufPrint(out, "{x:0>16}", .{hash.final()}) catch "";
}

pub fn search(query_raw: []const u8, duplicates_only: bool, out: []Item) usize {
    const query = std.mem.trim(u8, query_raw, " \t\r\n");
    if (query.len > 500 or out.len == 0) return 0;
    var pattern_buf: [520]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "%{s}%", .{query}) catch return 0;
    const stmt = db.prepare(if (duplicates_only)
        "SELECT rowid,path,COALESCE(NULLIF(display_title,''),title),media_kind,size," ++
            "(SELECT COUNT(*) FROM local_media d WHERE d.fingerprint=local_media.fingerprint AND d.fingerprint<>'') " ++
            "FROM local_media WHERE fingerprint<>'' AND (SELECT COUNT(*) FROM local_media d WHERE d.fingerprint=local_media.fingerprint)>1 " ++
            "AND (title LIKE ?1 COLLATE NOCASE OR display_title LIKE ?1 COLLATE NOCASE) ORDER BY fingerprint,mtime DESC LIMIT ?2"
    else
        "SELECT rowid,path,COALESCE(NULLIF(display_title,''),title),media_kind,size," ++
            "(SELECT COUNT(*) FROM local_media d WHERE d.fingerprint=local_media.fingerprint AND d.fingerprint<>'') " ++
            "FROM local_media WHERE title LIKE ?1 COLLATE NOCASE OR display_title LIKE ?1 COLLATE NOCASE " ++
            "ORDER BY mtime DESC LIMIT ?2") orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, pattern);
    db.bindInt64(stmt, 2, @intCast(@min(out.len, MAX_RESULTS)));
    var count: usize = 0;
    while (count < out.len and db.step(stmt) == db.c.SQLITE_ROW) : (count += 1) {
        out[count] = .{};
        out[count].id = db.columnInt64(stmt, 0);
        db.copyColumn(stmt, 1, &out[count].path, &out[count].path_len);
        db.copyColumn(stmt, 2, &out[count].title, &out[count].title_len);
        db.copyColumn(stmt, 3, &out[count].kind, &out[count].kind_len);
        out[count].size = @intCast(@max(db.columnInt64(stmt, 4), 0));
        out[count].duplicate_count = @intCast(@min(@max(db.columnInt64(stmt, 5), 1), std.math.maxInt(u16)));
    }
    if (!indexed_once.load(.acquire)) scanAsync();
    return count;
}

pub fn correct(id: i64, title: []const u8, kind: []const u8) bool {
    if (id <= 0 or title.len >= 256 or kind.len >= 16) return false;
    const valid_kind = kind.len == 0 or std.mem.eql(u8, kind, "movie") or std.mem.eql(u8, kind, "tv") or
        std.mem.eql(u8, kind, "music") or std.mem.eql(u8, kind, "audiobook") or std.mem.eql(u8, kind, "other");
    if (!valid_kind) return false;
    const exists = db.prepare("SELECT 1 FROM local_media WHERE rowid=?1 LIMIT 1") orelse return false;
    db.bindInt64(exists, 1, id);
    const found = db.step(exists) == db.c.SQLITE_ROW;
    db.finalize(exists);
    if (!found) return false;
    const stmt = db.prepare("UPDATE local_media SET display_title=?1,media_kind=?2 WHERE rowid=?3") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, std.mem.trim(u8, title, " \t\r\n"));
    db.bindText(stmt, 2, kind);
    db.bindInt64(stmt, 3, id);
    return db.step(stmt) == db.c.SQLITE_DONE;
}

test "local library recognizes the complete player media set" {
    try std.testing.expect(isMediaFile("movie.MKV"));
    try std.testing.expect(isMediaFile("album.flac"));
    try std.testing.expect(isMediaFile("capture.m2ts"));
    try std.testing.expect(!isMediaFile("subtitle.srt"));
}
