const std = @import("std");
const state = @import("../core/state.zig");
const paths = @import("../core/paths.zig");
const db = @import("../core/db.zig");

/// Watch history: remembers playback position for each torrent.
/// SQLite-backed with in-memory cache for fast lookups during playback.

pub const MAX_WATCH_HISTORY: usize = 200;
pub const MAX_NAME_LEN: usize = 256;
pub const MAX_LINK_LEN: usize = 4096;

pub const WatchEntry = struct {
    name: [MAX_NAME_LEN]u8 = std.mem.zeroes([MAX_NAME_LEN]u8),
    name_len: usize = 0,
    link: [MAX_LINK_LEN]u8 = std.mem.zeroes([MAX_LINK_LEN]u8),
    link_len: usize = 0,
    percent: f64 = 0.0,
};

pub var entries: [MAX_WATCH_HISTORY]WatchEntry = undefined;
pub var count: usize = 0;

pub fn init() void {
    count = 0;
    for (&entries) |*e| {
        e.* = .{};
    }
}

/// Save or update a watch position.
pub fn savePosition(name: []const u8, percent: f64, link: []const u8) void {
    if (state.app.incognito_mode) return;
    if (name.len == 0 or name.len >= MAX_NAME_LEN) return;
    if (percent < 0.5) return;

    // Upsert into SQLite
    const sql = "INSERT INTO watch_history (name, percent, link, updated_at) VALUES (?1, ?2, ?3, strftime('%s','now')) " ++
        "ON CONFLICT(name) DO UPDATE SET percent=excluded.percent, link=excluded.link, updated_at=strftime('%s','now')";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, name);
    db.bindDouble(stmt, 2, percent);
    if (link.len > 0 and link.len < MAX_LINK_LEN) {
        db.bindText(stmt, 3, link);
    } else {
        db.bindText(stmt, 3, "");
    }
    _ = db.step(stmt);

    // Update in-memory cache
    for (0..count) |i| {
        const existing = entries[i].name[0..entries[i].name_len];
        if (std.mem.eql(u8, existing, name)) {
            entries[i].percent = percent;
            if (link.len > 0 and link.len < MAX_LINK_LEN) {
                @memcpy(entries[i].link[0..link.len], link);
                entries[i].link_len = link.len;
            }
            return;
        }
    }

    // Not in cache — add at front
    if (count >= MAX_WATCH_HISTORY) count = MAX_WATCH_HISTORY - 1;
    var i: usize = count;
    while (i > 0) : (i -= 1) {
        entries[i] = entries[i - 1];
    }
    entries[0] = .{};
    @memcpy(entries[0].name[0..name.len], name);
    entries[0].name_len = name.len;
    entries[0].percent = percent;
    if (link.len > 0 and link.len < MAX_LINK_LEN) {
        @memcpy(entries[0].link[0..link.len], link);
        entries[0].link_len = link.len;
    }
    count += 1;
}

/// Look up saved position. O(1) from cache.
pub fn getPosition(name: []const u8) f64 {
    for (0..count) |i| {
        const existing = entries[i].name[0..entries[i].name_len];
        if (std.mem.eql(u8, existing, name)) {
            return entries[i].percent;
        }
    }
    return 0.0;
}

/// Remove an entry.
pub fn remove(idx: usize) void {
    if (idx >= count) return;
    const name = entries[idx].name[0..entries[idx].name_len];

    // Delete from DB
    const sql = "DELETE FROM watch_history WHERE name = ?1";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, name);
    _ = db.step(stmt);

    // Remove from cache
    var i: usize = idx;
    while (i + 1 < count) : (i += 1) {
        entries[i] = entries[i + 1];
    }
    count -= 1;
}

/// No-op — SQLite is always in sync.
pub fn persist() void {}

/// Get total count of watch history entries.
pub fn getCount() usize {
    return count;
}

/// Clear all watch history (both DB and in-memory).
pub fn clearAll() void {
    db.exec("DELETE FROM watch_history");
    init();
}

/// Load from SQLite into in-memory cache.
pub fn load() void {
    init();

    const sql = "SELECT name, percent, link FROM watch_history WHERE percent >= 0.5 ORDER BY updated_at DESC LIMIT 200";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        if (count >= MAX_WATCH_HISTORY) break;
        const idx = count;

        if (db.columnText(stmt, 0)) |name| {
            if (name.len == 0 or name.len >= MAX_NAME_LEN) continue;
            @memcpy(entries[idx].name[0..name.len], name);
            entries[idx].name_len = name.len;
        } else continue;

        entries[idx].percent = db.columnDouble(stmt, 1);
        if (entries[idx].percent < 0.5) continue;

        if (db.columnText(stmt, 2)) |link| {
            if (link.len > 0 and link.len < MAX_LINK_LEN) {
                @memcpy(entries[idx].link[0..link.len], link);
                entries[idx].link_len = link.len;
            }
        }

        count += 1;
    }
}

// ══════════════════════════════════════════════════════════
// Migration from old watch_history.tsv
// ══════════════════════════════════════════════════════════

pub fn migrateFromTsv() void {
    var path_buf: [512]u8 = undefined;
    const tsv_path = paths.watchHistoryFile(&path_buf);

    const file = @import("../core/io_global.zig").openFileAbsolute(tsv_path, .{}) catch
        @import("../core/io_global.zig").cwdOpenFile(tsv_path, .{}) catch return;
    defer file.close(@import("../core/io_global.zig").io());

    var buf: [128 * 1024]u8 = undefined;
    const bytes_read = @import("../core/io_global.zig").readAll(file, &buf) catch return;
    if (bytes_read == 0) return;

    db.exec("BEGIN");

    var lines = std.mem.splitScalar(u8, buf[0..bytes_read], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '\t');
        const name = parts.next() orelse continue;
        const pct_str = parts.next() orelse continue;
        const link = parts.next() orelse "";

        if (name.len == 0 or name.len >= MAX_NAME_LEN) continue;
        const pct = std.fmt.parseFloat(f64, pct_str) catch 0.0;
        if (pct < 0.5) continue;

        const sql = "INSERT OR REPLACE INTO watch_history (name, percent, link) VALUES (?1, ?2, ?3)";
        const stmt = db.prepare(sql) orelse continue;
        db.bindText(stmt, 1, name);
        db.bindDouble(stmt, 2, pct);
        db.bindText(stmt, 3, link);
        _ = db.step(stmt);
        db.finalize(stmt);
    }

    db.exec("COMMIT");

    // Rename old file
    var new_buf: [512]u8 = undefined;
    const new_path = std.fmt.bufPrint(&new_buf, "{s}.migrated", .{tsv_path}) catch return;
    @import("../core/io_global.zig").renameAbsolute(tsv_path, new_path) catch {};
}
