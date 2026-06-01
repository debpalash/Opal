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
/// Thread-safety: only called from the UI/render thread (player.zig frame
/// callback and importJson user action), so no internal locking is needed.
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

/// Export watch history as JSON to ~/Downloads/zigzag/watch_history.json
pub fn exportJson() void {
    var dir_buf: [512]u8 = undefined;
    const dl_dir = paths.defaultSavePath(&dir_buf);
    @import("../core/io_global.zig").cwdMakePath(dl_dir) catch {};

    var out_buf: [512]u8 = undefined;
    const out_path = std.fmt.bufPrintZ(&out_buf, "{s}/watch_history.json", .{dl_dir}) catch return;

    // Build JSON manually (no JSON library needed for simple format)
    const alloc = @import("../core/alloc.zig").allocator;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(alloc);

    json.appendSlice(alloc, "[") catch return;
    for (0..count) |i| {
        if (i > 0) json.appendSlice(alloc, ",") catch return;
        json.appendSlice(alloc, "{\"name\":\"") catch return;
        // Escape name for JSON
        for (entries[i].name[0..entries[i].name_len]) |ch| {
            if (ch == '"') { json.appendSlice(alloc, "\\\"") catch return; }
            else if (ch == '\\') { json.appendSlice(alloc, "\\\\") catch return; }
            else if (ch == '\n') { json.appendSlice(alloc, "\\n") catch return; }
            else { json.append(alloc, ch) catch return; }
        }
        var pct_buf: [32]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "\",\"percent\":{d:.2},\"link\":\"", .{entries[i].percent}) catch continue;
        json.appendSlice(alloc, pct_str) catch return;
        for (entries[i].link[0..entries[i].link_len]) |ch| {
            if (ch == '"') { json.appendSlice(alloc, "\\\"") catch return; }
            else if (ch == '\\') { json.appendSlice(alloc, "\\\\") catch return; }
            else { json.append(alloc, ch) catch return; }
        }
        json.appendSlice(alloc, "\"}") catch return;
    }
    json.appendSlice(alloc, "]") catch return;

    if (@import("../core/io_global.zig").cwdCreateFile(out_path, .{})) |f| {
        _ = @import("../core/io_global.zig").writeAll(f, json.items) catch {};
        f.close(@import("../core/io_global.zig").io());
        state.showToast("✓ Watch history exported");
    } else |_| {
        state.showToast("Export failed — check permissions");
    }
}

/// Import watch history from a JSON file. Merges with existing data.
pub fn importJson(path: []const u8) void {
    const file = @import("../core/io_global.zig").cwdOpenFile(path, .{}) catch {
        state.showToast("Could not open import file");
        return;
    };
    defer file.close(@import("../core/io_global.zig").io());

    const alloc = @import("../core/alloc.zig").allocator;
    var buf: [256 * 1024]u8 = undefined;
    const n = @import("../core/io_global.zig").readAll(file, &buf) catch return;
    if (n < 3) return;
    _ = alloc;

    // Simple JSON array parser: find each {"name":"...", "percent":N, "link":"..."}
    const data = buf[0..n];
    var pos: usize = 0;
    var imported: usize = 0;
    while (pos < data.len) {
        // Find next "name":"
        const name_key = std.mem.indexOfPos(u8, data, pos, "\"name\":\"") orelse break;
        const name_start = name_key + 8;
        const name_end = findUnescapedQuote(data, name_start) orelse break;
        const name = data[name_start..name_end];

        // Find percent
        const pct_key = std.mem.indexOfPos(u8, data, name_end, "\"percent\":") orelse break;
        const pct_start = pct_key + 10;
        var pct_end = pct_start;
        while (pct_end < data.len and (data[pct_end] == '.' or (data[pct_end] >= '0' and data[pct_end] <= '9'))) pct_end += 1;
        const pct = std.fmt.parseFloat(f64, data[pct_start..pct_end]) catch 0;

        // Find link (optional)
        var link: []const u8 = "";
        if (std.mem.indexOfPos(u8, data, pct_end, "\"link\":\"")) |link_key| {
            const link_start = link_key + 8;
            if (findUnescapedQuote(data, link_start)) |link_end| {
                link = data[link_start..link_end];
            }
        }

        if (name.len > 0 and name.len < MAX_NAME_LEN and pct >= 0.5) {
            savePosition(name, pct, link);
            imported += 1;
        }

        pos = pct_end + 1;
    }

    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "✓ Imported {d} entries", .{imported}) catch "Imported";
    state.showToast(msg);
}

fn findUnescapedQuote(data: []const u8, start: usize) ?usize {
    var i = start;
    while (i < data.len) : (i += 1) {
        if (data[i] == '"' and (i == 0 or data[i - 1] != '\\')) return i;
    }
    return null;
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
