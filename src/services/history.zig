const std = @import("std");
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");

/// Legacy builds wrote history into fixed shared-temp paths. Migration must
/// not follow a planted symlink or ingest a file owned/readable by another
/// account. The descriptor checks happen after the no-follow open, avoiding a
/// check/use race.
fn openPrivateLegacyFile(path: []const u8) ?std.Io.File {
    if (comptime @import("builtin").os.tag == .windows) return null;
    const io = @import("../core/io_global.zig");
    const file = io.cwdOpenFile(path, .{ .follow_symlinks = false }) catch return null;
    const stat = file.stat(io.io()) catch {
        file.close(io.io());
        return null;
    };
    if (stat.kind != .file or (stat.permissions.toMode() & 0o077) != 0) {
        file.close(io.io());
        return null;
    }
    return file;
}

// ══════════════════════════════════════════════════════════
// Search History (SQLite-backed, in-memory cache)
// ══════════════════════════════════════════════════════════

pub fn addSearchHistory(query: []const u8) void {
    if (state.app.incognito_mode) return;
    if (query.len == 0 or query.len >= state.MAX_QUERY_LEN) return;

    var safe_buf: [state.MAX_QUERY_LEN]u8 = undefined;
    const safe_query = @import("../player/watch_history_pure.zig").persistedTarget(query, &safe_buf).identity;
    if (safe_query.len == 0 or safe_query.len >= state.MAX_QUERY_LEN) return;

    // Insert into DB (UNIQUE constraint auto-deduplicates; update timestamp on conflict)
    const sql = "INSERT INTO search_history (query) VALUES (?1) ON CONFLICT(query) DO UPDATE SET searched_at=strftime('%s','now')";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, safe_query);
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
/// Local files are keyed by their absolute path (file identity — survives a
/// relative-path or file:// re-open); streams keep the URL as key.
pub fn savePlaybackPosition(url: []const u8, position: f64, duration: f64) void {
    savePlaybackPositionImpl(url, position, duration, true, 0);
}

/// Ordered player persistence workers already publish taste progress on the
/// caller/UI side. This variant performs only the durable row update, avoiding
/// cross-thread mutation of activity's current-item tracker.
pub fn savePlaybackPositionBackground(url: []const u8, position: f64, duration: f64, catalog_tmdb_id: i32) void {
    savePlaybackPositionImpl(url, position, duration, false, catalog_tmdb_id);
}

fn savePlaybackPositionImpl(url: []const u8, position: f64, duration: f64, publish_activity: bool, catalog_tmdb_id: i32) void {
    if (state.app.incognito_mode) return;
    if (url.len == 0 or url.len >= 2048 or duration < 5) return;

    const wh = @import("../player/watch_history.zig");
    const whp = @import("../player/watch_history_pure.zig");

    var persisted_buf: [2048]u8 = undefined;
    const persisted = whp.persistedTarget(url, &persisted_buf);
    if (persisted.identity.len == 0) return;

    const percent = if (duration > 0) (position / duration) * 100.0 else 0;
    // Local taste engine: feed watch depth (finish/abandon detection). Must
    // run BEFORE the nearly-finished early-return or finishes would never be seen.
    if (publish_activity) @import("activity.zig").onProgress(persisted.identity, percent);
    // Don't save if nearly finished — treat as "watched"
    if (percent > whp.FINISHED_FRACTION * 100.0) return;
    // Don't save very early positions (<2%)
    if (percent < 2 and position < 5) return;

    var key_buf: [2048]u8 = undefined;
    const file_key = wh.resolveFileKey(url, &key_buf);
    // For local files the row is keyed by the absolute path; storing it as
    // `link` too lets the launch resume prompt reopen the file directly.
    const name = if (file_key.len > 0 and file_key.len < 2048) file_key else persisted.identity;
    const reopen = if (file_key.len > 0) name else persisted.reopen;

    const sql = "INSERT INTO watch_history (name, percent, position_secs, duration_secs, file_key, link, catalog_tmdb_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) " ++
        "ON CONFLICT(name) DO UPDATE SET percent=?2, position_secs=?3, duration_secs=?4, file_key=?5, link=?6, " ++
        "catalog_tmdb_id=CASE WHEN ?7 > 0 THEN ?7 ELSE catalog_tmdb_id END, updated_at=strftime('%s','now')";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, name);
    db.bindDouble(stmt, 2, percent);
    db.bindDouble(stmt, 3, position);
    db.bindDouble(stmt, 4, duration);
    db.bindText(stmt, 5, file_key);
    db.bindText(stmt, 6, reopen);
    db.bindInt(stmt, 7, @max(0, catalog_tmdb_id));
    _ = db.step(stmt);
}

/// Get saved playback position for a URL. Returns position in seconds, 0 if
/// not found. Local files are looked up by file identity (absolute path)
/// first, then by the legacy name key so pre-v2 entries still resume once.
pub fn getPlaybackPosition(url: []const u8) f64 {
    if (state.app.incognito_mode) return 0;
    if (url.len == 0) return 0;

    const wh = @import("../player/watch_history.zig");
    const whp = @import("../player/watch_history_pure.zig");

    var persisted_buf: [2048]u8 = undefined;
    const persisted = whp.persistedTarget(url, &persisted_buf);
    if (persisted.identity.len == 0) return 0;

    var key_buf: [2048]u8 = undefined;
    const file_key = wh.resolveFileKey(url, &key_buf);

    var path_pos: f64 = 0;
    if (file_key.len > 0) {
        const sql = "SELECT position_secs FROM watch_history WHERE file_key = ?1 ORDER BY updated_at DESC LIMIT 1";
        const stmt = db.prepare(sql) orelse return 0;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, file_key);
        if (db.step(stmt) == db.c.SQLITE_ROW) {
            path_pos = db.columnDouble(stmt, 0);
        }
    }

    var legacy_pos: f64 = 0;
    if (path_pos <= 0) {
        const sql = "SELECT position_secs FROM watch_history WHERE name = ?1";
        const stmt = db.prepare(sql) orelse return 0;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, persisted.identity);
        if (db.step(stmt) == db.c.SQLITE_ROW) {
            legacy_pos = db.columnDouble(stmt, 0);
        }
    }

    return whp.pickPosition(path_pos, legacy_pos);
}

/// Clear resume position after a video is fully watched
pub fn clearPlaybackPosition(url: []const u8) void {
    const wh = @import("../player/watch_history.zig");
    const whp = @import("../player/watch_history_pure.zig");
    var key_buf: [2048]u8 = undefined;
    const file_key = wh.resolveFileKey(url, &key_buf);

    var persisted_buf: [2048]u8 = undefined;
    const persisted = whp.persistedTarget(url, &persisted_buf);
    if (persisted.identity.len == 0) return;

    const sql = "DELETE FROM watch_history WHERE name = ?1 OR name = ?2 OR (?3 <> '' AND file_key = ?3)";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, persisted.identity);
    db.bindText(stmt, 2, url); // legacy pre-v3 row
    db.bindText(stmt, 3, file_key);
    _ = db.step(stmt);
}

// ══════════════════════════════════════════════════════════
// Download History (SQLite-backed, in-memory cache)
// ══════════════════════════════════════════════════════════

pub fn addDownloadHistory(name: []const u8, link: []const u8) void {
    if (state.app.incognito_mode) return;
    if (name.len == 0 or name.len >= state.MAX_DL_NAME_LEN) return;
    if (link.len >= state.MAX_DL_LINK_LEN) return;

    const whp = @import("../player/watch_history_pure.zig");
    var name_buf: [state.MAX_DL_LINK_LEN]u8 = undefined;
    const safe_name = whp.persistedTarget(name, &name_buf).identity;
    if (safe_name.len == 0 or safe_name.len >= state.MAX_DL_NAME_LEN) return;
    var link_buf: [state.MAX_DL_LINK_LEN]u8 = undefined;
    const safe_link = whp.persistedTarget(link, &link_buf).reopen;

    const sql = "INSERT INTO download_history (name, link) VALUES (?1, ?2)";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, safe_name);
    db.bindText(stmt, 2, safe_link);
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

pub const DownloadHistoryEntry = struct {
    id: i64 = 0,
    name: [state.MAX_DL_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
};

pub fn snapshotDownloadHistory(out: []DownloadHistoryEntry) usize {
    const stmt = db.prepare("SELECT rowid,name FROM download_history ORDER BY downloaded_at DESC,rowid DESC LIMIT 100") orelse return 0;
    defer db.finalize(stmt);
    var count: usize = 0;
    while (count < out.len and db.step(stmt) == db.c.SQLITE_ROW) {
        const name = db.columnText(stmt, 1) orelse continue;
        if (name.len == 0 or name.len >= state.MAX_DL_NAME_LEN) continue;
        out[count] = .{ .id = db.columnInt64(stmt, 0) };
        @memcpy(out[count].name[0..name.len], name);
        out[count].name_len = name.len;
        count += 1;
    }
    return count;
}

pub const DownloadHistoryAction = enum { remove, clear };
const DownloadHistoryRequest = struct { action: DownloadHistoryAction = .remove, id: i64 = 0, ticket: u64 = 0 };
const download_request_cap = 16;
var download_requests: [download_request_cap]DownloadHistoryRequest = undefined;
var download_request_head: usize = 0;
var download_request_count: usize = 0;
var download_request_mutex: @import("../core/sync.zig").Mutex = .{};
var download_request_ticket = std.atomic.Value(u64).init(0);
var download_request_applied = std.atomic.Value(u64).init(0);

fn applyDownloadHistoryAction(action: DownloadHistoryAction, id: i64) void {
    const sql = if (action == .clear) "DELETE FROM download_history" else "DELETE FROM download_history WHERE rowid=?1";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    if (action == .remove) db.bindInt64(stmt, 1, id);
    _ = db.step(stmt);
    loadDownloadHistory();
}

/// Queue a remote mutation for the UI thread and acknowledge only after the
/// SQLite row and native cache agree. Headless owns no render thread, so it
/// applies synchronously under the same producer lock.
pub fn requestDownloadHistoryAction(action: DownloadHistoryAction, id: i64) bool {
    if (action == .remove and id <= 0) return false;
    download_request_mutex.lock();
    if (state.app.is_headless) {
        applyDownloadHistoryAction(action, id);
        download_request_mutex.unlock();
        return true;
    }
    if (download_request_count >= download_request_cap) {
        download_request_mutex.unlock();
        return false;
    }
    const ticket = download_request_ticket.fetchAdd(1, .acq_rel) + 1;
    const tail = (download_request_head + download_request_count) % download_request_cap;
    download_requests[tail] = .{ .action = action, .id = id, .ticket = ticket };
    download_request_count += 1;
    download_request_mutex.unlock();
    state.wakeUi();
    var waited: usize = 0;
    while (waited < 500 and download_request_applied.load(.acquire) < ticket) : (waited += 1)
        @import("../core/io_global.zig").sleep(10 * std.time.ns_per_ms);
    return download_request_applied.load(.acquire) >= ticket;
}

pub fn drainDownloadHistoryUi() void {
    while (true) {
        download_request_mutex.lock();
        if (download_request_count == 0) {
            download_request_mutex.unlock();
            return;
        }
        const request = download_requests[download_request_head];
        download_request_head = (download_request_head + 1) % download_request_cap;
        download_request_count -= 1;
        download_request_mutex.unlock();
        applyDownloadHistoryAction(request.action, request.id);
        download_request_applied.store(request.ticket, .release);
    }
}

// ══════════════════════════════════════════════════════════
// Migration from old flat files
// ══════════════════════════════════════════════════════════

pub fn migrateSearchHistory() void {
    // Old path was /tmp — likely already gone, but try anyway
    const old_paths = [_][]const u8{
        "/tmp/opal_search_history.json",
    };

    for (old_paths) |old_path| {
        const file = openPrivateLegacyFile(old_path) orelse continue;
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
        "/tmp/opal_download_history.json",
    };

    for (old_paths) |old_path| {
        const file = openPrivateLegacyFile(old_path) orelse continue;
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
