const std = @import("std");
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");

// ══════════════════════════════════════════════════════════
// Search History (SQLite-backed, in-memory cache)
// ══════════════════════════════════════════════════════════

pub fn addSearchHistory(query: []const u8) void {
    if (state.app.incognito_mode) return;
    if (query.len == 0 or query.len >= state.MAX_QUERY_LEN) return;

    // Insert into DB (UNIQUE constraint auto-deduplicates; update timestamp on conflict)
    const sql = "INSERT INTO search_history (query) VALUES (?1) ON CONFLICT(query) DO UPDATE SET searched_at=strftime('%s','now')";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, query);
    _ = db.step(stmt);

    // Refresh in-memory cache
    loadSearchHistory();
}

pub fn removeSearchHistory(idx: usize) void {
    if (idx >= state.app.search_history_count) return;
    const query = state.app.search_history_buf[idx][0..state.app.search_history_len[idx]];

    const sql = "DELETE FROM search_history WHERE query = ?1";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, query);
    _ = db.step(stmt);

    // Refresh cache
    loadSearchHistory();
}

pub fn loadSearchHistory() void {
    state.app.search_history_count = 0;

    const sql = "SELECT query FROM search_history ORDER BY searched_at DESC LIMIT 50";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        if (state.app.search_history_count >= state.MAX_SEARCH_HISTORY) break;
        if (db.columnText(stmt, 0)) |q| {
            if (q.len >= state.MAX_QUERY_LEN) continue;
            const idx = state.app.search_history_count;
            @memcpy(state.app.search_history_buf[idx][0..q.len], q);
            state.app.search_history_len[idx] = q.len;
            state.app.search_history_count += 1;
        }
    }
}

pub fn saveSearchHistory() void {
    // No-op: SQLite is always in sync via addSearchHistory/removeSearchHistory.
}
// ══════════════════════════════════════════════════════════
// Smart Resume (playback position tracking)
// ══════════════════════════════════════════════════════════

/// Save current playback position for a URL/file. Called periodically.
pub fn savePlaybackPosition(url: []const u8, position: f64, duration: f64) void {
    if (state.app.incognito_mode) return;
    if (url.len == 0 or url.len >= 2048 or duration < 5) return;
    
    const percent = if (duration > 0) (position / duration) * 100.0 else 0;
    // Don't save if nearly finished (>95%) — treat as "watched"
    if (percent > 95) return;
    // Don't save very early positions (<2%)
    if (percent < 2 and position < 5) return;

    const sql = "INSERT INTO watch_history (name, percent, position_secs, duration_secs) VALUES (?1, ?2, ?3, ?4) " ++
        "ON CONFLICT(name) DO UPDATE SET percent=?2, position_secs=?3, duration_secs=?4, updated_at=strftime('%s','now')";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, url);
    db.bindDouble(stmt, 2, percent);
    db.bindDouble(stmt, 3, position);
    db.bindDouble(stmt, 4, duration);
    _ = db.step(stmt);
}

/// Get saved playback position for a URL. Returns position in seconds, 0 if not found.
pub fn getPlaybackPosition(url: []const u8) f64 {
    if (state.app.incognito_mode) return 0;
    if (url.len == 0) return 0;

    const sql = "SELECT position_secs FROM watch_history WHERE name = ?1";
    const stmt = db.prepare(sql) orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, url);
    if (db.step(stmt) == db.c.SQLITE_ROW) {
        return db.columnDouble(stmt, 0);
    }
    return 0;
}

/// Clear resume position after a video is fully watched
pub fn clearPlaybackPosition(url: []const u8) void {
    const sql = "DELETE FROM watch_history WHERE name = ?1";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, url);
    _ = db.step(stmt);
}


// ══════════════════════════════════════════════════════════
// Download History (SQLite-backed, in-memory cache)
// ══════════════════════════════════════════════════════════

pub fn addDownloadHistory(name: []const u8, link: []const u8) void {
    if (state.app.incognito_mode) return;
    if (name.len == 0 or name.len >= state.MAX_DL_NAME_LEN) return;
    if (link.len >= state.MAX_DL_LINK_LEN) return;

    const sql = "INSERT INTO download_history (name, link) VALUES (?1, ?2)";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, name);
    db.bindText(stmt, 2, link);
    _ = db.step(stmt);

    // Refresh cache
    loadDownloadHistory();
}

pub fn removeDownloadHistory(idx: usize) void {
    if (idx >= state.app.dl_history_count) return;

    // We need the DB row id — query by name+link
    const name = state.app.dl_history_names[idx][0..state.app.dl_history_name_lens[idx]];
    const link = state.app.dl_history_links[idx][0..state.app.dl_history_link_lens[idx]];

    const sql = "DELETE FROM download_history WHERE name = ?1 AND link = ?2";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, name);
    db.bindText(stmt, 2, link);
    _ = db.step(stmt);

    loadDownloadHistory();
}

pub fn loadDownloadHistory() void {
    state.app.dl_history_count = 0;

    const sql = "SELECT name, link FROM download_history ORDER BY downloaded_at DESC LIMIT 100";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        if (state.app.dl_history_count >= state.MAX_DL_HISTORY) break;
        const idx = state.app.dl_history_count;

        if (db.columnText(stmt, 0)) |name| {
            if (name.len >= state.MAX_DL_NAME_LEN) continue;
            @memcpy(state.app.dl_history_names[idx][0..name.len], name);
            state.app.dl_history_name_lens[idx] = name.len;
        } else continue;

        if (db.columnText(stmt, 1)) |link| {
            if (link.len < state.MAX_DL_LINK_LEN) {
                @memcpy(state.app.dl_history_links[idx][0..link.len], link);
                state.app.dl_history_link_lens[idx] = link.len;
            }
        }

        state.app.dl_history_count += 1;
    }
}

pub fn saveDownloadHistory() void {
    // No-op: SQLite is always in sync.
}

// ══════════════════════════════════════════════════════════
// Migration from old flat files
// ══════════════════════════════════════════════════════════

pub fn migrateSearchHistory() void {
    // Old path was /tmp — likely already gone, but try anyway
    const old_paths = [_][]const u8{
        "/tmp/zigzag_search_history.json",
    };

    for (old_paths) |old_path| {
        const file = @import("../core/io_global.zig").cwdOpenFile(old_path, .{}) catch continue;
        defer file.close(@import("../core/io_global.zig").io());

        var buf: [8192]u8 = undefined;
        const n = @import("../core/io_global.zig").readAll(file, &buf) catch continue;

        db.exec("BEGIN");
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line.len >= state.MAX_QUERY_LEN) continue;
            const sql = "INSERT OR IGNORE INTO search_history (query) VALUES (?1)";
            const stmt = db.prepare(sql) orelse continue;
            db.bindText(stmt, 1, line);
            _ = db.step(stmt);
            db.finalize(stmt);
        }
        db.exec("COMMIT");

        @import("../core/io_global.zig").cwdDeleteFile(old_path) catch {};
    }
}

pub fn migrateDownloadHistory() void {
    const old_paths = [_][]const u8{
        "/tmp/zigzag_download_history.json",
    };

    for (old_paths) |old_path| {
        const file = @import("../core/io_global.zig").cwdOpenFile(old_path, .{}) catch continue;
        defer file.close(@import("../core/io_global.zig").io());

        var buf: [65536]u8 = undefined;
        const n = @import("../core/io_global.zig").readAll(file, &buf) catch continue;

        db.exec("BEGIN");
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, '\t');
            const name = parts.next() orelse continue;
            const link = parts.next() orelse "";
            if (name.len >= state.MAX_DL_NAME_LEN) continue;

            const sql = "INSERT INTO download_history (name, link) VALUES (?1, ?2)";
            const stmt = db.prepare(sql) orelse continue;
            db.bindText(stmt, 1, name);
            db.bindText(stmt, 2, link);
            _ = db.step(stmt);
            db.finalize(stmt);
        }
        db.exec("COMMIT");

        @import("../core/io_global.zig").cwdDeleteFile(old_path) catch {};
    }
}
