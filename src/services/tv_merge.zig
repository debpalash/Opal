//! Executes the duplicate-show merge planned by `tv_merge_pure.zig`.
//!
//! This is a data migration, so it is built to be undone by hand:
//!   * Before a pair is touched, every affected row (loser AND winner) is copied
//!     into `*_bak` side tables stamped with `merged_at` and a role. Nothing in
//!     those tables is ever read or deleted by Opal.
//!   * Each pair runs in one transaction: a failure rolls the pair back whole.
//!   * It is idempotent: once the loser row is gone there is nothing to plan.
//!   * Merge semantics: the TMDB-keyed row's metadata wins, empty fields are
//!     filled from the loser; watched flags are the union; the resume position
//!     comes from the most recently updated episode row; the library status
//!     comes from the more recently set of the two; `tracked` is true when
//!     either row was tracked (a duplicate in Watching means both were).
//!
//! The loser's `tv_external_ids` row is kept so a stale card holding the old
//! hash id can still be resolved to its IMDb id.

const std = @import("std");
const pure = @import("tv_merge_pure.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Report = struct {
    merged: usize = 0,
    failed: usize = 0,
};

const MAX_ROWS = 2048;

const backup_ddl = [_][:0]const u8{
    "CREATE TABLE IF NOT EXISTS tv_merge_log (merged_at INTEGER, winner_id INTEGER, loser_id INTEGER, imdb_id TEXT)",
    "CREATE TABLE IF NOT EXISTS tv_shows_bak (merged_at INTEGER, role TEXT, tmdb_id INTEGER, name TEXT, poster_path TEXT, tracked INTEGER, status TEXT, last_aired_season INTEGER, last_aired_episode INTEGER, next_season INTEGER, next_episode INTEGER, next_air_epoch INTEGER, next_name TEXT, added_at INTEGER, updated_at INTEGER)",
    "CREATE TABLE IF NOT EXISTS tv_watched_bak (merged_at INTEGER, role TEXT, tmdb_id INTEGER, season INTEGER, episode INTEGER, watched INTEGER, updated_at INTEGER, position_secs REAL, duration_secs REAL, played_secs REAL)",
    "CREATE TABLE IF NOT EXISTS tv_seasons_bak (merged_at INTEGER, role TEXT, tmdb_id INTEGER, season INTEGER, episode_count INTEGER)",
    "CREATE TABLE IF NOT EXISTS tv_browse_bak (merged_at INTEGER, role TEXT, tmdb_id INTEGER, season INTEGER)",
    "CREATE TABLE IF NOT EXISTS tv_continue_bak (merged_at INTEGER, role TEXT, tmdb_id INTEGER, name TEXT, poster_path TEXT, season INTEGER, episode INTEGER, updated_at INTEGER)",
    "CREATE TABLE IF NOT EXISTS library_status_bak (merged_at INTEGER, role TEXT, kind TEXT, item_id TEXT, status TEXT, updated_at INTEGER)",
    "CREATE TABLE IF NOT EXISTS wanted_followed_bak (merged_at INTEGER, role TEXT, tmdb_id INTEGER, season INTEGER, episode INTEGER)",
};

/// Find and merge duplicate shows. `handle` is the live `sqlite3*` (opaque so
/// callers with their own C import need no cast). Safe to call repeatedly.
pub fn run(handle: *anyopaque, now_ms: i64) Report {
    const conn: *c.sqlite3 = @ptrCast(@alignCast(handle));
    var report: Report = .{};

    var ids: [MAX_ROWS]i32 = undefined;
    var imdbs: [MAX_ROWS][16]u8 = undefined;
    var imdb_lens: [MAX_ROWS]usize = undefined;
    var n: usize = 0;

    var stmt: ?*c.sqlite3_stmt = null;
    const q = "SELECT s.tmdb_id, e.imdb_id FROM tv_shows s JOIN tv_external_ids e ON e.tmdb_id = s.tmdb_id";
    if (c.sqlite3_prepare_v2(conn, q, -1, &stmt, null) != c.SQLITE_OK) return report;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW and n < MAX_ROWS) {
        const text = c.sqlite3_column_text(stmt, 1);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        if (text == null or len == 0 or len > 16) continue;
        ids[n] = c.sqlite3_column_int(stmt, 0);
        @memcpy(imdbs[n][0..len], @as([*]const u8, @ptrCast(text))[0..len]);
        imdb_lens[n] = len;
        n += 1;
    }
    _ = c.sqlite3_finalize(stmt);
    if (n < 2) return report;

    var cands: [MAX_ROWS]pure.Candidate = undefined;
    for (0..n) |i| cands[i] = .{ .id = ids[i], .imdb = imdbs[i][0..imdb_lens[i]] };

    var plan: [64]pure.Merge = undefined;
    const planned = pure.planMerges(cands[0..n], &plan);
    if (planned == 0) return report;

    for (backup_ddl) |ddl| _ = c.sqlite3_exec(conn, ddl.ptr, null, null, null);

    for (plan[0..planned]) |m| {
        var imdb_text: []const u8 = "";
        for (0..n) |i| if (ids[i] == m.winner) {
            imdb_text = imdbs[i][0..imdb_lens[i]];
        };
        if (mergeOne(conn, m, imdb_text, now_ms)) report.merged += 1 else report.failed += 1;
    }
    return report;
}

fn execf(conn: *c.sqlite3, comptime fmt: []const u8, args: anytype) bool {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, fmt, args) catch return false;
    return c.sqlite3_exec(conn, text.ptr, null, null, null) == c.SQLITE_OK;
}

fn tableExists(conn: *c.sqlite3, name: [:0]const u8) bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(conn, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", -1, &stmt, null) != c.SQLITE_OK) return false;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), null);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn mergeOne(conn: *c.sqlite3, m: pure.Merge, imdb: []const u8, now: i64) bool {
    const w = m.winner;
    const l = m.loser;
    if (c.sqlite3_exec(conn, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) return false;
    var ok = true;

    // 1. Backups: loser and winner rows as they are before anything changes.
    inline for (.{ .{ "loser", l }, .{ "winner", w } }) |r| {
        ok = ok and execf(conn, "INSERT INTO tv_shows_bak SELECT {d}, '{s}', tmdb_id, name, poster_path, tracked, status, last_aired_season, last_aired_episode, next_season, next_episode, next_air_epoch, next_name, added_at, updated_at FROM tv_shows WHERE tmdb_id={d}", .{ now, r[0], r[1] });
        ok = ok and execf(conn, "INSERT INTO tv_watched_bak SELECT {d}, '{s}', tmdb_id, season, episode, watched, updated_at, position_secs, duration_secs, played_secs FROM tv_watched WHERE tmdb_id={d}", .{ now, r[0], r[1] });
        ok = ok and execf(conn, "INSERT INTO tv_seasons_bak SELECT {d}, '{s}', tmdb_id, season, episode_count FROM tv_seasons WHERE tmdb_id={d}", .{ now, r[0], r[1] });
        ok = ok and execf(conn, "INSERT INTO tv_browse_bak SELECT {d}, '{s}', tmdb_id, season FROM tv_browse WHERE tmdb_id={d}", .{ now, r[0], r[1] });
        ok = ok and execf(conn, "INSERT INTO tv_continue_bak SELECT {d}, '{s}', tmdb_id, name, poster_path, season, episode, updated_at FROM tv_continue WHERE tmdb_id={d}", .{ now, r[0], r[1] });
        ok = ok and execf(conn, "INSERT INTO library_status_bak SELECT {d}, '{s}', kind, item_id, status, updated_at FROM library_status WHERE kind='tv' AND item_id='{d}'", .{ now, r[0], r[1] });
    }
    const has_wanted = tableExists(conn, "wanted_followed");
    if (has_wanted) {
        ok = ok and execf(conn, "INSERT INTO wanted_followed_bak SELECT {d}, 'loser', tmdb_id, season, episode FROM wanted_followed WHERE tmdb_id={d}", .{ now, l });
    }
    ok = ok and execf(conn, "INSERT INTO tv_merge_log VALUES({d}, {d}, {d}, '{s}')", .{ now, w, l, imdb });

    // 2. Watched episodes: union of the flags, resume position from the more
    //    recently touched row, the most watching time seen.
    ok = ok and execf(conn,
        \\INSERT INTO tv_watched(tmdb_id, season, episode, watched, updated_at, position_secs, duration_secs, played_secs)
        \\SELECT {d}, season, episode, watched, updated_at, position_secs, duration_secs, played_secs FROM tv_watched WHERE tmdb_id={d} AND 1
        \\ON CONFLICT(tmdb_id, season, episode) DO UPDATE SET
        \\  watched = MAX(COALESCE(tv_watched.watched, 0), COALESCE(excluded.watched, 0)),
        \\  position_secs = CASE WHEN COALESCE(excluded.updated_at, 0) > COALESCE(tv_watched.updated_at, 0) THEN excluded.position_secs ELSE tv_watched.position_secs END,
        \\  duration_secs = CASE WHEN COALESCE(excluded.updated_at, 0) > COALESCE(tv_watched.updated_at, 0) THEN excluded.duration_secs ELSE tv_watched.duration_secs END,
        \\  played_secs = MAX(COALESCE(tv_watched.played_secs, 0), COALESCE(excluded.played_secs, 0)),
        \\  updated_at = MAX(COALESCE(tv_watched.updated_at, 0), COALESCE(excluded.updated_at, 0))
    , .{ w, l });
    ok = ok and execf(conn, "DELETE FROM tv_watched WHERE tmdb_id={d}", .{l});

    // 3. Season map: the keyed row's map is authoritative; fill missing seasons.
    ok = ok and execf(conn, "INSERT OR IGNORE INTO tv_seasons(tmdb_id, season, episode_count) SELECT {d}, season, episode_count FROM tv_seasons WHERE tmdb_id={d}", .{ w, l });
    ok = ok and execf(conn, "DELETE FROM tv_seasons WHERE tmdb_id={d}", .{l});

    // 4. The show row itself.
    ok = ok and execf(conn,
        \\UPDATE tv_shows SET
        \\  tracked = MAX(COALESCE(tracked, 0), COALESCE((SELECT tracked FROM tv_shows WHERE tmdb_id={[l]d}), 0)),
        \\  name = CASE WHEN COALESCE(name, '') = '' THEN COALESCE((SELECT name FROM tv_shows WHERE tmdb_id={[l]d}), '') ELSE name END,
        \\  poster_path = CASE WHEN COALESCE(poster_path, '') = '' THEN COALESCE((SELECT poster_path FROM tv_shows WHERE tmdb_id={[l]d}), '') ELSE poster_path END,
        \\  status = CASE WHEN COALESCE(status, '') = '' THEN COALESCE((SELECT status FROM tv_shows WHERE tmdb_id={[l]d}), '') ELSE status END,
        \\  added_at = MIN(COALESCE(added_at, 9223372036854775807), COALESCE((SELECT added_at FROM tv_shows WHERE tmdb_id={[l]d}), 9223372036854775807)),
        \\  updated_at = MAX(COALESCE(updated_at, 0), COALESCE((SELECT updated_at FROM tv_shows WHERE tmdb_id={[l]d}), 0))
        \\WHERE tmdb_id={[w]d}
    , .{ .w = w, .l = l });
    ok = ok and execf(conn, "DELETE FROM tv_shows WHERE tmdb_id={d}", .{l});

    // 5. The user's hand-picked status: the more recently set one wins.
    ok = ok and execf(conn,
        \\INSERT INTO library_status(kind, item_id, status, updated_at)
        \\SELECT 'tv', '{d}', status, updated_at FROM library_status WHERE kind='tv' AND item_id='{d}' AND 1
        \\ON CONFLICT(kind, item_id) DO UPDATE SET
        \\  status = CASE WHEN COALESCE(excluded.updated_at, 0) > COALESCE(library_status.updated_at, 0) THEN excluded.status ELSE library_status.status END,
        \\  updated_at = MAX(COALESCE(library_status.updated_at, 0), COALESCE(excluded.updated_at, 0))
    , .{ w, l });
    ok = ok and execf(conn, "DELETE FROM library_status WHERE kind='tv' AND item_id='{d}'", .{l});

    // 6. Small keyed leftovers. tv_continue is deprecated but the startup
    //    carry-over would resurrect the loser from it, so it goes too (backed up).
    ok = ok and execf(conn, "INSERT OR IGNORE INTO tv_browse(tmdb_id, season) SELECT {d}, season FROM tv_browse WHERE tmdb_id={d}", .{ w, l });
    ok = ok and execf(conn, "DELETE FROM tv_browse WHERE tmdb_id={d}", .{l});
    ok = ok and execf(conn, "DELETE FROM tv_continue WHERE tmdb_id={d}", .{l});
    if (has_wanted) {
        ok = ok and execf(conn, "INSERT OR IGNORE INTO wanted_followed(tmdb_id, season, episode) SELECT {d}, season, episode FROM wanted_followed WHERE tmdb_id={d}", .{ w, l });
        ok = ok and execf(conn, "DELETE FROM wanted_followed WHERE tmdb_id={d}", .{l});
    }

    if (ok and c.sqlite3_exec(conn, "COMMIT", null, null, null) == c.SQLITE_OK) return true;
    _ = c.sqlite3_exec(conn, "ROLLBACK", null, null, null);
    return false;
}

// ══════════════════════════════════════════════════════════
// Tests (in-memory SQLite, same table definitions as db.zig)
// ══════════════════════════════════════════════════════════

const t = std.testing;
const cm = @import("cinemeta_pure.zig");

const schema = [_][:0]const u8{
    "CREATE TABLE tv_shows (tmdb_id INTEGER PRIMARY KEY, name TEXT, poster_path TEXT, tracked INTEGER DEFAULT 1, status TEXT DEFAULT '', last_aired_season INTEGER DEFAULT 0, last_aired_episode INTEGER DEFAULT 0, next_season INTEGER DEFAULT 0, next_episode INTEGER DEFAULT 0, next_air_epoch INTEGER DEFAULT 0, next_name TEXT DEFAULT '', added_at INTEGER, updated_at INTEGER)",
    "CREATE TABLE tv_watched (tmdb_id INTEGER NOT NULL, season INTEGER NOT NULL, episode INTEGER NOT NULL, watched INTEGER DEFAULT 1, updated_at INTEGER, position_secs REAL DEFAULT 0, duration_secs REAL DEFAULT 0, played_secs REAL DEFAULT 0, PRIMARY KEY (tmdb_id, season, episode))",
    "CREATE TABLE tv_seasons (tmdb_id INTEGER NOT NULL, season INTEGER NOT NULL, episode_count INTEGER DEFAULT 0, PRIMARY KEY (tmdb_id, season))",
    "CREATE TABLE tv_browse (tmdb_id INTEGER PRIMARY KEY, season INTEGER NOT NULL)",
    "CREATE TABLE tv_continue (tmdb_id INTEGER PRIMARY KEY, name TEXT, poster_path TEXT, season INTEGER, episode INTEGER, updated_at INTEGER)",
    "CREATE TABLE tv_external_ids (tmdb_id INTEGER PRIMARY KEY, imdb_id TEXT NOT NULL)",
    "CREATE TABLE library_status (kind TEXT NOT NULL, item_id TEXT NOT NULL, status TEXT NOT NULL, updated_at INTEGER, PRIMARY KEY (kind, item_id))",
    "CREATE TABLE wanted_followed (tmdb_id INTEGER NOT NULL, season INTEGER NOT NULL, episode INTEGER NOT NULL, PRIMARY KEY (tmdb_id, season, episode))",
};

fn openMemory() !*c.sqlite3 {
    var conn: ?*c.sqlite3 = null;
    try t.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open(":memory:", &conn));
    for (schema) |ddl| try t.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(conn, ddl.ptr, null, null, null));
    return conn.?;
}

fn sql(conn: *c.sqlite3, s: [:0]const u8) !void {
    try t.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(conn, s.ptr, null, null, null));
}

fn scalar(conn: *c.sqlite3, s: [:0]const u8) !i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    try t.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_prepare_v2(conn, s.ptr, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try t.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(stmt));
    return c.sqlite3_column_int64(stmt, 0);
}

fn seedDuplicate(conn: *c.sqlite3, synth: i32) !void {
    const stmts = [_][]const u8{
        "INSERT INTO tv_external_ids VALUES(SYN, 'tt0903747'), (1396, 'tt0903747'), (777, 'tt0944947')",
        "INSERT INTO tv_shows VALUES(SYN, 'Breaking Bad', 'https://img/p.jpg', 1, 'Ended', 5, 16, 0, 0, 0, '', 1000, 5000)",
        "INSERT INTO tv_shows VALUES(1396, 'Breaking Bad', '', 1, '', 0, 0, 0, 0, 0, '', 2000, 4000)",
        "INSERT INTO tv_shows VALUES(777, 'Other Show', '', 1, '', 0, 0, 0, 0, 0, '', 3000, 3000)",
        // keyless history: S1E1, S1E2 watched, S1E2 has a resume position, newer than the keyed row's
        "INSERT INTO tv_watched VALUES(SYN, 1, 1, 1, 100, 0, 0, 30)",
        "INSERT INTO tv_watched VALUES(SYN, 1, 2, 1, 300, 600, 3000, 900)",
        // keyed history: S1E2 (older), S1E3
        "INSERT INTO tv_watched VALUES(1396, 1, 2, 0, 200, 50, 3000, 100)",
        "INSERT INTO tv_watched VALUES(1396, 1, 3, 1, 250, 0, 0, 0)",
        "INSERT INTO tv_watched VALUES(777, 1, 1, 1, 100, 0, 0, 0)",
        "INSERT INTO tv_seasons VALUES(SYN, 1, 7), (SYN, 2, 13), (1396, 1, 7)",
        "INSERT INTO library_status VALUES('tv', 'SYN', 'completed', 900), ('tv', '777', 'dropped', 10)",
        "INSERT INTO tv_continue VALUES(SYN, 'Breaking Bad', '', 1, 2, 300)",
        "INSERT INTO wanted_followed VALUES(SYN, 1, 2), (1396, 1, 2)",
        "INSERT INTO tv_browse VALUES(SYN, 2)",
    };
    var num: [16]u8 = undefined;
    const synth_text = try std.fmt.bufPrint(&num, "{d}", .{synth});
    for (stmts) |tmpl| {
        const text = try std.mem.replaceOwned(u8, t.allocator, tmpl, "SYN", synth_text);
        defer t.allocator.free(text);
        const z = try t.allocator.dupeZ(u8, text);
        defer t.allocator.free(z);
        try sql(conn, z);
    }
}

test "merge: history carried onto the keyed row, loser gone, backup written" {
    const conn = try openMemory();
    defer _ = c.sqlite3_close(conn);
    const synth = cm.stableId("tt0903747");
    try seedDuplicate(conn, synth);

    const r = run(conn, 123456);
    try t.expectEqual(@as(usize, 1), r.merged);
    try t.expectEqual(@as(usize, 0), r.failed);

    // exactly one Breaking Bad row left, under the TMDB id; the other show untouched
    try t.expectEqual(@as(i64, 2), try scalar(conn, "SELECT COUNT(*) FROM tv_shows"));
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM tv_shows WHERE tmdb_id=1396"));
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM tv_shows WHERE tmdb_id=777"));
    // metadata: keyed row's empty fields filled from the loser, earliest added_at, latest update
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM tv_shows WHERE tmdb_id=1396 AND poster_path='https://img/p.jpg' AND status='Ended' AND added_at=1000 AND updated_at=5000 AND tracked=1"));
    // watched union: S1E1 (from loser), S1E2 (watched on one side), S1E3 (keyed)
    try t.expectEqual(@as(i64, 3), try scalar(conn, "SELECT COUNT(*) FROM tv_watched WHERE tmdb_id=1396 AND watched=1"));
    try t.expectEqual(@as(i64, 0), try scalar(conn, "SELECT COUNT(*) FROM tv_watched WHERE tmdb_id<>1396 AND tmdb_id<>777"));
    // resume position from the more recently updated row, played time is the max
    try t.expectEqual(@as(i64, 600), try scalar(conn, "SELECT CAST(position_secs AS INTEGER) FROM tv_watched WHERE tmdb_id=1396 AND episode=2"));
    try t.expectEqual(@as(i64, 900), try scalar(conn, "SELECT CAST(played_secs AS INTEGER) FROM tv_watched WHERE tmdb_id=1396 AND episode=2"));
    // season map: keyed row's season 1 kept, season 2 added from the loser
    try t.expectEqual(@as(i64, 2), try scalar(conn, "SELECT COUNT(*) FROM tv_seasons WHERE tmdb_id=1396"));
    try t.expectEqual(@as(i64, 7), try scalar(conn, "SELECT episode_count FROM tv_seasons WHERE tmdb_id=1396 AND season=1"));
    // user status carried; other show's status untouched
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM library_status WHERE kind='tv' AND item_id='1396' AND status='completed'"));
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM library_status WHERE item_id='777' AND status='dropped'"));
    try t.expectEqual(@as(i64, 2), try scalar(conn, "SELECT COUNT(*) FROM library_status"));
    // deprecated continue row cannot resurrect the loser; follows de-duplicated
    try t.expectEqual(@as(i64, 0), try scalar(conn, "SELECT COUNT(*) FROM tv_continue"));
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM wanted_followed WHERE tmdb_id=1396"));
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM tv_browse WHERE tmdb_id=1396"));
    // the loser's IMDb identity is kept for stale cards
    try t.expectEqual(@as(i64, 3), try scalar(conn, "SELECT COUNT(*) FROM tv_external_ids"));

    // backup: both rows as they were, enough to restore by hand
    try t.expectEqual(@as(i64, 2), try scalar(conn, "SELECT COUNT(*) FROM tv_shows_bak"));
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM tv_shows_bak WHERE role='loser' AND name='Breaking Bad' AND poster_path='https://img/p.jpg'"));
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM tv_shows_bak WHERE role='winner' AND tmdb_id=1396 AND poster_path=''"));
    try t.expectEqual(@as(i64, 4), try scalar(conn, "SELECT COUNT(*) FROM tv_watched_bak"));
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM tv_merge_log WHERE winner_id=1396 AND merged_at=123456"));
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM tv_continue_bak WHERE role='loser'"));
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM library_status_bak WHERE role='loser' AND status='completed'"));

    // idempotent: a second pass finds nothing
    const again = run(conn, 999999);
    try t.expectEqual(@as(usize, 0), again.merged);
    try t.expectEqual(@as(i64, 2), try scalar(conn, "SELECT COUNT(*) FROM tv_shows_bak"));
}

test "merge: a status set more recently on the keyed row beats the loser's" {
    const conn = try openMemory();
    defer _ = c.sqlite3_close(conn);
    const synth = cm.stableId("tt0903747");
    try seedDuplicate(conn, synth);
    try sql(conn, "INSERT INTO library_status VALUES('tv', '1396', 'watching', 5000)");
    _ = run(conn, 1);
    try t.expectEqual(@as(i64, 1), try scalar(conn, "SELECT COUNT(*) FROM library_status WHERE item_id='1396' AND status='watching'"));
}

test "merge: different IMDb ids and unrelated rows are left alone" {
    const conn = try openMemory();
    defer _ = c.sqlite3_close(conn);
    const synth_a = cm.stableId("tt0903747");
    var b: [256]u8 = undefined;
    const ext = try std.fmt.bufPrintZ(&b, "INSERT INTO tv_external_ids VALUES({d}, 'tt0903747'), (1399, 'tt0944947')", .{synth_a});
    try sql(conn, ext);
    const shows = try std.fmt.bufPrintZ(&b, "INSERT INTO tv_shows(tmdb_id, name, tracked) VALUES({d}, 'A', 1), (1399, 'B', 1)", .{synth_a});
    try sql(conn, shows);
    const r = run(conn, 1);
    try t.expectEqual(@as(usize, 0), r.merged);
    try t.expectEqual(@as(i64, 2), try scalar(conn, "SELECT COUNT(*) FROM tv_shows"));
    // no backup tables are even created when nothing merges
    try t.expectEqual(@as(i64, 0), try scalar(conn, "SELECT COUNT(*) FROM sqlite_master WHERE name='tv_shows_bak'"));
}

test "merge: a failing pair rolls back whole" {
    const conn = try openMemory();
    defer _ = c.sqlite3_close(conn);
    const synth = cm.stableId("tt0903747");
    try seedDuplicate(conn, synth);
    // Break a later step (library_status missing) after earlier steps succeed.
    try sql(conn, "ALTER TABLE tv_continue RENAME TO tv_continue_gone");
    const r = run(conn, 1);
    try t.expectEqual(@as(usize, 0), r.merged);
    try t.expectEqual(@as(usize, 1), r.failed);
    // nothing moved
    try t.expectEqual(@as(i64, 3), try scalar(conn, "SELECT COUNT(*) FROM tv_shows"));
    try t.expectEqual(@as(i64, 5), try scalar(conn, "SELECT COUNT(*) FROM tv_watched"));
}
