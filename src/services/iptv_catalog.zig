//! SQLite-backed Live TV channel catalog — ingest + paged read.
//!
//! Replaces the fixed [300]IptvChannel window as the directory's backing store
//! so the app can hold every channel from many user playlists (100k+) with flat
//! memory: rows live in `iptv_catalog` (core/db.zig), the grid pages them with
//! LIMIT/OFFSET, and search is a LIKE over the lowercased-name index. All SQL
//! text, the LIKE escaping and the adult gate come from iptv_catalog_pure.zig
//! (tested); this module owns the DB calls and thread-safety.
//!
//! Ingest is idempotent per source: clearSource(id) then ingestChannels(id, …),
//! both inside one transaction, so a re-fetch never leaves a half-updated
//! source. The (source_id, url_hash) UNIQUE key dedupes within a playlist.

const std = @import("std");
const db = @import("../core/db.zig");
const pure = @import("iptv_pure.zig");
const cpure = @import("iptv_catalog_pure.zig");
const store = @import("iptv_store.zig");
const sync = @import("../core/sync.zig");
const logs = @import("../core/logs.zig");

// One writer at a time. Ingest runs on a background worker; the paged reads run
// on the UI thread. SQLite itself serializes, but the multi-statement ingest
// transaction must not interleave with another ingest, so guard it.
var write_mutex: sync.Mutex = .{};

/// Filters for a page read. Empty strings mean "no constraint on this facet".
pub const Query = struct {
    text: []const u8 = "",
    country: []const u8 = "",
    category: []const u8 = "",
    source_id: []const u8 = "",
    // Quality filter as inclusive quality_tier bounds (cpure.qualityBounds). Both
    // 0 = no quality constraint; qmax 0 with qmin > 0 = "at least qmin".
    qmin: u32 = 0,
    qmax: u32 = 0,
    // Secondary sort. false → ORDER BY name_lc; true → country then name_lc.
    sort_country: bool = false,
    // Whether adult (nsfw=1) channels are included. false (the default, matching
    // the NSFW-filter-on default) adds `AND nsfw = 0`; true shows everything.
    nsfw_allowed: bool = false,
};

/// Remove every row a source contributed. Called before re-ingesting it so a
/// shrunk playlist doesn't leave orphans. Safe when the source has no rows.
pub fn clearSource(source_id: []const u8) void {
    write_mutex.lock();
    defer write_mutex.unlock();
    const stmt = db.prepare("DELETE FROM iptv_catalog WHERE source_id=?1") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, source_id);
    _ = db.step(stmt);
}

/// Insert a batch of parsed channels for `source_id`. Adult channels are STORED
/// (flagged `nsfw = 1`), not dropped: whether they surface is decided at query
/// time by the NSFW setting (see queryPage / Query.nsfw_allowed). `force_adult`
/// flags EVERY channel from this source as adult regardless of detection — for a
/// user-declared adult playlist whose channel names/groups don't self-identify.
/// Runs in one transaction. Returns rows actually inserted (post-dedupe).
pub fn ingestChannels(source_id: []const u8, channels: []const pure.IptvChannel, force_adult: bool) usize {
    if (channels.len == 0) return 0;
    write_mutex.lock();
    defer write_mutex.unlock();

    db.exec("BEGIN");
    const sql =
        "INSERT OR IGNORE INTO iptv_catalog" ++
        "(source_id,url_hash,name,name_lc,url,logo,category,country,quality,user_agent,referrer,nsfw,quality_tier)" ++
        " VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)";
    const stmt = db.prepare(sql) orelse {
        db.exec("ROLLBACK");
        return 0;
    };
    defer db.finalize(stmt);

    var inserted: usize = 0;
    var lc_buf: [@typeInfo(@FieldType(pure.IptvChannel, "name")).array.len]u8 = undefined;
    for (channels) |*ch| {
        const name = ch.name[0..ch.name_len];
        const url = ch.url[0..ch.url_len];
        const cat = ch.category[0..ch.category_len];
        if (name.len == 0 or url.len == 0) continue;
        // Adult channels are STORED with nsfw=1, not dropped — the NSFW setting
        // decides at query time whether they surface. Flag = a source-wide adult
        // declaration, OR the channel's parsed adult flag, OR the group/name/url
        // gate (catches m3u group-title too).
        const is_adult = force_adult or ch.nsfw or cpure.ingestIsAdult(name, url, cat);

        const lc = lowerInto(name, &lc_buf);
        _ = db.c.sqlite3_reset(stmt);
        db.bindText(stmt, 1, source_id);
        db.bindInt64(stmt, 2, store.urlHash(url));
        db.bindText(stmt, 3, name);
        db.bindText(stmt, 4, lc);
        db.bindText(stmt, 5, url);
        db.bindText(stmt, 6, ch.logo[0..ch.logo_len]);
        db.bindText(stmt, 7, cat);
        db.bindText(stmt, 8, ch.country[0..ch.country_len]);
        db.bindText(stmt, 9, ch.quality[0..ch.quality_len]);
        db.bindText(stmt, 10, ch.user_agent[0..ch.user_agent_len]);
        db.bindText(stmt, 11, ch.referrer[0..ch.referrer_len]);
        db.bindInt(stmt, 12, if (is_adult) 1 else 0);
        db.bindInt(stmt, 13, @intCast(cpure.qualityTier(ch.quality[0..ch.quality_len])));
        if (db.step(stmt) == db.c.SQLITE_DONE) inserted += 1;
    }

    db.exec("COMMIT");
    return inserted;
}

fn lowerInto(s: []const u8, out: []u8) []const u8 {
    const n = @min(s.len, out.len);
    for (0..n) |i| out[i] = std.ascii.toLower(s[i]);
    return out[0..n];
}

/// Total channels matching `q` across the whole catalog — drives the "N
/// channels" heading and the has-more test for infinite scroll.
pub fn count(q: Query) usize {
    var like_buf: [520]u8 = undefined;
    var sql_buf: [512]u8 = undefined;
    const sql = buildWhere("SELECT COUNT(*) FROM iptv_catalog", q, &sql_buf) orelse return 0;
    const stmt = db.prepare(sql) orelse return 0;
    defer db.finalize(stmt);
    bindFilters(stmt, q, &like_buf);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 0;
    return @intCast(@max(0, db.columnInt(stmt, 0)));
}

/// Fill up to `out.len` channels starting at `offset`, ordered name-first.
/// Returns the number written. This is the render path's data source.
pub fn queryPage(out: []pure.IptvChannel, offset: usize, q: Query) usize {
    if (out.len == 0) return 0;
    var like_buf: [520]u8 = undefined;
    var sql_buf: [512]u8 = undefined;
    const base = buildWhere(cpure.SELECT_PAGE, q, &sql_buf) orelse return 0;

    // The ORDER BY / LIMIT / OFFSET tail is fixed text (no user data), appended
    // after the WHERE the filters composed. Sort mode picks the leading key:
    // country-first groups a region together, otherwise plain name order.
    const order = if (q.sort_country) "country, name_lc" else "name_lc";
    var tail_buf: [640]u8 = undefined;
    const full = std.fmt.bufPrint(&tail_buf, "{s} ORDER BY {s} LIMIT {d} OFFSET {d}", .{ base, order, out.len, offset }) catch return 0;

    const stmt = db.prepare(full) orelse return 0;
    defer db.finalize(stmt);
    bindFilters(stmt, q, &like_buf);

    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) {
        out[n] = readRow(stmt);
        n += 1;
    }
    return n;
}

/// How many rows a given source contributed — used by the settings page to show
/// "12,384 channels" beside each installed source.
pub fn sourceCount(source_id: []const u8) usize {
    return count(.{ .source_id = source_id });
}

/// True when the catalog holds no rows at all — the render path uses this to
/// decide between the empty state and the grid.
pub fn isEmpty() bool {
    return count(.{}) == 0;
}

// ── Per-source ingest bookkeeping (iptv_source_meta) ──

/// Record that `source_id` was ingested now with `channels` rows. Stamped from
/// io_global (never std.time — 0.16). Drives both the 24h SWR freshness check
/// and the settings-page count, so it must be written on every successful
/// ingest (including a re-ingest that shrank the source).
pub fn markIngested(source_id: []const u8, channels: usize) void {
    const now = @import("../core/io_global.zig").timestamp();
    const stmt = db.prepare(
        "INSERT INTO iptv_source_meta(source_id,ingested_at,channel_count) VALUES(?1,?2,?3) " ++
            "ON CONFLICT(source_id) DO UPDATE SET ingested_at=?2, channel_count=?3",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, source_id);
    db.bindInt64(stmt, 2, now);
    db.bindInt64(stmt, 3, @intCast(channels));
    _ = db.step(stmt);
}

/// Unix seconds of the last ingest for `source_id`, or 0 if never ingested.
pub fn lastIngest(source_id: []const u8) i64 {
    const stmt = db.prepare("SELECT ingested_at FROM iptv_source_meta WHERE source_id=?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, source_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 0;
    return db.columnInt64(stmt, 0);
}

/// Channel count recorded at last ingest (fast; no scan). Falls back to a live
/// COUNT(*) when there is no meta row yet.
pub fn recordedCount(source_id: []const u8) usize {
    const stmt = db.prepare("SELECT channel_count FROM iptv_source_meta WHERE source_id=?1") orelse return sourceCount(source_id);
    defer db.finalize(stmt);
    db.bindText(stmt, 1, source_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return sourceCount(source_id);
    return @intCast(@max(0, db.columnInt64(stmt, 0)));
}

/// Drop a source's rows AND its meta row — full uninstall.
pub fn removeSource(source_id: []const u8) void {
    clearSource(source_id);
    const stmt = db.prepare("DELETE FROM iptv_source_meta WHERE source_id=?1") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, source_id);
    _ = db.step(stmt);
}

// ── WHERE composition ──
//
// Clauses are appended in a FIXED order so bindFilters binds the same parameter
// numbers buildWhere emitted. Both walk the SAME predicate list, so they cannot
// drift: ?1 text, ?2 country, ?3 category, ?4 source_id, each present only when
// its filter is non-empty.

fn buildWhere(base: []const u8, q: Query, out: []u8) ?[]const u8 {
    var w: usize = 0;
    appendStr(out, &w, base) orelse return null;
    var first = true;
    var idx: usize = 1;
    // Predicates are appended in a fixed order (text, country, category,
    // source_id); bindFilters binds the same order, so parameter numbers align.
    if (q.text.len > 0) {
        appendClause(out, &w, &first) orelse return null;
        appendStr(out, &w, "name_lc LIKE ?") orelse return null;
        appendNum(out, &w, idx) orelse return null;
        appendStr(out, &w, " ESCAPE '\\'") orelse return null;
        idx += 1;
    }
    if (q.country.len > 0) {
        appendClause(out, &w, &first) orelse return null;
        appendStr(out, &w, "country = ?") orelse return null;
        appendNum(out, &w, idx) orelse return null;
        idx += 1;
    }
    if (q.category.len > 0) {
        appendClause(out, &w, &first) orelse return null;
        appendStr(out, &w, "category = ?") orelse return null;
        appendNum(out, &w, idx) orelse return null;
        idx += 1;
    }
    if (q.source_id.len > 0) {
        appendClause(out, &w, &first) orelse return null;
        appendStr(out, &w, "source_id = ?") orelse return null;
        appendNum(out, &w, idx) orelse return null;
        idx += 1;
    }
    // Quality bounds are integers (no user text), so they're inlined rather than
    // bound — no injection surface, and bindFilters stays a pure text binder.
    if (q.qmin > 0) {
        appendClause(out, &w, &first) orelse return null;
        appendStr(out, &w, "quality_tier >= ") orelse return null;
        appendNum(out, &w, q.qmin) orelse return null;
    }
    if (q.qmax > 0) {
        appendClause(out, &w, &first) orelse return null;
        appendStr(out, &w, "quality_tier <= ") orelse return null;
        appendNum(out, &w, q.qmax) orelse return null;
    }
    // Adult gate — hide nsfw rows unless the setting allows them. Integer literal,
    // no bound param.
    if (!q.nsfw_allowed) {
        appendClause(out, &w, &first) orelse return null;
        appendStr(out, &w, "nsfw = 0") orelse return null;
    }
    return out[0..w];
}

fn bindFilters(stmt: ?*db.Stmt, q: Query, like_buf: []u8) void {
    var idx: c_int = 1;
    if (q.text.len > 0) {
        const pat = cpure.buildLikePattern(q.text, like_buf) orelse "%%";
        db.bindText(stmt, idx, pat);
        idx += 1;
    }
    if (q.country.len > 0) {
        db.bindText(stmt, idx, q.country);
        idx += 1;
    }
    if (q.category.len > 0) {
        db.bindText(stmt, idx, q.category);
        idx += 1;
    }
    if (q.source_id.len > 0) {
        db.bindText(stmt, idx, q.source_id);
        idx += 1;
    }
}

fn readRow(stmt: ?*db.Stmt) pure.IptvChannel {
    var c = pure.IptvChannel{};
    copyCol(stmt, 0, &c.name, &c.name_len);
    copyCol(stmt, 1, &c.url, &c.url_len);
    copyCol(stmt, 2, &c.logo, &c.logo_len);
    copyCol(stmt, 3, &c.category, &c.category_len);
    copyCol(stmt, 4, &c.country, &c.country_len);
    copyCol(stmt, 5, &c.quality, &c.quality_len);
    copyCol(stmt, 6, &c.user_agent, &c.user_agent_len);
    copyCol(stmt, 7, &c.referrer, &c.referrer_len);
    return c;
}

fn copyCol(stmt: ?*db.Stmt, col: c_int, dst: []u8, len: *usize) void {
    const s = db.columnText(stmt, col) orelse "";
    const n = @min(s.len, dst.len);
    @memcpy(dst[0..n], s[0..n]);
    len.* = n;
}

fn appendStr(out: []u8, w: *usize, s: []const u8) ?void {
    if (w.* + s.len > out.len) return null;
    @memcpy(out[w.*..][0..s.len], s);
    w.* += s.len;
    return {};
}

fn appendNum(out: []u8, w: *usize, n: usize) ?void {
    var tmp: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return null;
    return appendStr(out, w, s);
}

fn appendClause(out: []u8, w: *usize, first: *bool) ?void {
    appendStr(out, w, if (first.*) " WHERE " else " AND ") orelse return null;
    first.* = false;
    return {};
}

test {
    std.testing.refAllDecls(cpure);
}
