//! Live TV favorites + recently-watched persistence (the `iptv_channels` table).
//!
//! Favorites and recents are the same shape — an IptvChannel display snapshot
//! (name/url/logo/quality/category/country + the user_agent/referrer play hints,
//! so a saved channel still plays with the headers its CDN needs). One table,
//! `kind` = 'fav' | 'recent', keyed by (kind, url_hash) so a channel can be
//! both. The Favorites/Recent views load straight from here — no network fetch —
//! into the same state.app.iptv.results[] the grid renders.

const std = @import("std");
const db = @import("../core/db.zig");
const pure = @import("iptv_pure.zig");

pub const Kind = enum {
    fav,
    recent,
    pub fn str(self: Kind) []const u8 {
        return switch (self) {
            .fav => "fav",
            .recent => "recent",
        };
    }
};

/// Cap on retained recents (newest kept; older pruned on each record).
const RECENT_CAP: i64 = 60;

fn hashOf(url: []const u8) i64 {
    return @bitCast(std.hash.Fnv1a_64.hash(url));
}

/// Stable url→hash (the favorites primary key). Exposed so the UI can test a
/// card's favorite state against an in-memory set without a per-card query.
pub fn urlHash(url: []const u8) i64 {
    return hashOf(url);
}

/// Fill `set` with every favorite's url_hash (cleared first). The UI keeps this
/// in memory and refreshes it on toggle, so the star state is an O(1) lookup
/// rather than a DB query per card per frame.
pub fn loadFavHashes(gpa: std.mem.Allocator, set: *std.AutoHashMapUnmanaged(i64, void)) void {
    set.clearRetainingCapacity();
    const stmt = db.prepare("SELECT url_hash FROM iptv_channels WHERE kind='fav'") orelse return;
    defer db.finalize(stmt);
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        set.put(gpa, db.columnInt64(stmt, 0), {}) catch {};
    }
}

// ══════════════════════════════════════════════════════════
// Stream-health cache (iptv_health) — LEGACY
// ══════════════════════════════════════════════════════════
// Superseded by services/link_health.zig + the app-wide `link_health` table,
// which Live TV now writes/reads through (kind = "iptv") and Radio shares. The
// table and these helpers are KEPT (no destructive migration) and `clearHealth`
// is still called by the "Test" button so stale legacy rows are swept too.

/// Health results older than this are re-probed (streams die/revive; the cache
/// stays useful across sessions without going permanently stale).
pub const HEALTH_TTL_S: i64 = 30 * 60;

/// Persist a probe result for `url` (thread-safe via sqlite's own serialization).
pub fn healthPut(url: []const u8, status: u8, latency_ms: u32) void {
    const stmt = db.prepare(
        "INSERT OR REPLACE INTO iptv_health(url_hash,status,latency_ms,checked_at) VALUES(?1,?2,?3,strftime('%s','now'))",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, hashOf(url));
    db.bindInt(stmt, 2, @intCast(status));
    db.bindInt(stmt, 3, @intCast(@min(latency_ms, std.math.maxInt(i32))));
    _ = db.step(stmt);
}

/// Load all NON-STALE health rows into `map` (url_hash → status int). The UI
/// keeps this in memory (refreshed when a probe lands) for O(1) status lookups.
pub fn loadHealthMap(gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(i64, u8)) void {
    map.clearRetainingCapacity();
    const stmt = db.prepare("SELECT url_hash,status FROM iptv_health WHERE checked_at > strftime('%s','now') - ?1") orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, HEALTH_TTL_S);
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        map.put(gpa, db.columnInt64(stmt, 0), @intCast(db.columnInt64(stmt, 1))) catch {};
    }
}

/// Wipe all cached health rows — the "Test" button uses this to force a fresh
/// re-probe (otherwise the still-fresh 30-min rows reload mid-sweep and block it).
pub fn clearHealth() void {
    db.exec("DELETE FROM iptv_health");
}

/// True when `url` has a fresh cached probe (so we don't re-probe within TTL).
pub fn healthFresh(url: []const u8) bool {
    const stmt = db.prepare("SELECT 1 FROM iptv_health WHERE url_hash=?1 AND checked_at > strftime('%s','now') - ?2") orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, hashOf(url));
    db.bindInt64(stmt, 2, HEALTH_TTL_S);
    return db.step(stmt) == db.c.SQLITE_ROW;
}

pub fn isFavorite(url: []const u8) bool {
    const stmt = db.prepare("SELECT 1 FROM iptv_channels WHERE kind='fav' AND url_hash=?1") orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, hashOf(url));
    return db.step(stmt) == db.c.SQLITE_ROW;
}

fn upsert(kind: Kind, c: *const pure.IptvChannel) void {
    const stmt = db.prepare(
        "INSERT OR REPLACE INTO iptv_channels(kind,url_hash,name,url,logo,quality,category,country,user_agent,referrer,ts) " ++
            "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,strftime('%s','now'))",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind.str());
    db.bindInt64(stmt, 2, hashOf(c.url[0..c.url_len]));
    db.bindText(stmt, 3, c.name[0..c.name_len]);
    db.bindText(stmt, 4, c.url[0..c.url_len]);
    db.bindText(stmt, 5, c.logo[0..c.logo_len]);
    db.bindText(stmt, 6, c.quality[0..c.quality_len]);
    db.bindText(stmt, 7, c.category[0..c.category_len]);
    db.bindText(stmt, 8, c.country[0..c.country_len]);
    db.bindText(stmt, 9, c.user_agent[0..c.user_agent_len]);
    db.bindText(stmt, 10, c.referrer[0..c.referrer_len]);
    _ = db.step(stmt);
}

pub fn addFavorite(c: *const pure.IptvChannel) void {
    upsert(.fav, c);
}

pub fn removeFavorite(url: []const u8) void {
    const stmt = db.prepare("DELETE FROM iptv_channels WHERE kind='fav' AND url_hash=?1") orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, hashOf(url));
    _ = db.step(stmt);
}

/// Toggle favorite for `c`; returns the new state (true = now favorited). Also
/// mirrors into the unified library_items so the home Favorites rail spans
/// verticals (deep_link = the stream url).
pub fn toggleFavorite(c: *const pure.IptvChannel) bool {
    const url = c.url[0..c.url_len];
    const now_fav = !isFavorite(url);
    if (now_fav) addFavorite(c) else removeFavorite(url);
    @import("library_store.zig").setFavorite("iptv", url, now_fav, c.name[0..c.name_len], c.logo[0..c.logo_len], url);
    return now_fav;
}

/// Record a play into recents (upsert bumps ts) and prune to RECENT_CAP.
pub fn recordRecent(c: *const pure.IptvChannel) void {
    upsert(.recent, c);
    const stmt = db.prepare(
        "DELETE FROM iptv_channels WHERE kind='recent' AND url_hash NOT IN " ++
            "(SELECT url_hash FROM iptv_channels WHERE kind='recent' ORDER BY ts DESC LIMIT ?1)",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, RECENT_CAP);
    _ = db.step(stmt);
}

/// Load rows of `kind` (newest first) into `out`; returns the count filled.
pub fn loadInto(kind: Kind, out: []pure.IptvChannel) usize {
    const stmt = db.prepare(
        "SELECT name,url,logo,quality,category,country,user_agent,referrer " ++
            "FROM iptv_channels WHERE kind=?1 ORDER BY ts DESC LIMIT ?2",
    ) orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind.str());
    db.bindInt64(stmt, 2, @intCast(out.len));
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) {
        const c = &out[n];
        c.* = .{};
        db.copyColumn(stmt, 0, c.name[0..], &c.name_len);
        db.copyColumn(stmt, 1, c.url[0..], &c.url_len);
        db.copyColumn(stmt, 2, c.logo[0..], &c.logo_len);
        db.copyColumn(stmt, 3, c.quality[0..], &c.quality_len);
        db.copyColumn(stmt, 4, c.category[0..], &c.category_len);
        db.copyColumn(stmt, 5, c.country[0..], &c.country_len);
        db.copyColumn(stmt, 6, c.user_agent[0..], &c.user_agent_len);
        db.copyColumn(stmt, 7, c.referrer[0..], &c.referrer_len);
        n += 1;
    }
    return n;
}
