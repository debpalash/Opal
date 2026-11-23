//! Maturity enforcement for kid profiles (ROADMAP 7.3, v2 kids-tvdb).
//!
//! A title's certification is fetched once from TMDB (`release_dates` /
//! `content_ratings`), mapped to a minimum age (profiles_pure.tmdbAge) and
//! cached here. The decisions are maturity_pure.zig's:
//!
//!   * Lists are filtered where they are produced, on the worker that fetched
//!     them, so the native grid, Home rails, the web catalog and search all see
//!     the same filtered rows: tmdb_api (browse + search pages, the resolver's
//!     catalog rows), recommendations (For You), operator picks.
//!     `filterStaged` blocks on rating lookups; it is never called on the UI
//!     thread. UI-thread readers (cache seed) use the cache only.
//!   * Playback: tmdb.openOrSearch (`allowTmdb`, native) and the web API's
//!     movie/TV detail routes (`apiGate`) refuse over-cap titles.
//!
//! Unknown is hidden for kids: a title with no catalog identity, no
//! certification, or a lookup that failed follows the profile's unrated policy
//! (deny by default). Adult profiles pass straight through every call.
//!
//! Adult flags elsewhere (torrent search, anime, Live TV) ride the NSFW filter,
//! which profiles.enforce() pins on for kid profiles.

const std = @import("std");
const pure = @import("profiles_pure.zig");
const mp = @import("maturity_pure.zig");
const profiles = @import("profiles.zig");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig").allocator;

const CACHE_LEN = 512;
const Entry = struct {
    id: i32 = 0,
    tv: bool = false,
    used: bool = false,
    pending: bool = false,
    /// Minimum age, or null for unrated/unknown.
    age: ?u8 = null,
};

var mutex: sync.Mutex = .{};
var cache: [CACHE_LEN]Entry = @as([CACHE_LEN]Entry, @splat(.{}));
var next_slot: usize = 0;

fn findLocked(id: i32, tv: bool) ?*Entry {
    for (&cache) |*e| if (e.used and e.id == id and e.tv == tv) return e;
    return null;
}

fn claimLocked(id: i32, tv: bool) *Entry {
    const e = &cache[next_slot];
    next_slot = (next_slot + 1) % CACHE_LEN;
    e.* = .{ .id = id, .tv = tv, .used = true, .pending = true };
    return e;
}

fn isTv(item: *const state.TmdbItem) bool {
    const mt = item.media_type[0..@min(item.media_type_len, item.media_type.len)];
    return std.mem.eql(u8, mt, "tv");
}

/// No TMDB identity to ask about: keyless catalog, synthetic id, no id.
fn noIdentity(id: i32, imdb: []const u8) bool {
    return state.app.tmdb.api_key_len == 0 or id <= 0 or @import("keyless_tv_pure.zig").isSynthetic(id, imdb);
}

/// Whether the running profile filters at all.
pub fn active() bool {
    return profiles.runningIsKid();
}

fn decideList(r: mp.Rating) bool {
    const c = profiles.runningCap();
    return mp.listVisible(c.cap, c.allow_unrated, r);
}

/// Cache-only rating (any thread). `.pending` when not looked up yet.
pub fn cachedRating(id: i32, tv: bool, imdb: []const u8) mp.Rating {
    if (noIdentity(id, imdb)) return .unrated;
    mutex.lock();
    defer mutex.unlock();
    const e = findLocked(id, tv) orelse return .pending;
    if (e.pending) return .pending;
    return mp.Rating.fromAge(e.age);
}

/// Rating for a title, fetching it now when not cached. Worker / connection
/// threads only (blocks on TMDB).
pub fn ratingBlocking(id: i32, tv: bool, imdb: []const u8) mp.Rating {
    const cached = cachedRating(id, tv, imdb);
    if (cached != .pending) return cached;
    const t = &state.app.tmdb;
    var key: [256]u8 = undefined;
    const key_len = @min(t.api_key_len, key.len);
    @memcpy(key[0..key_len], t.api_key[0..key_len]);
    return mp.Rating.fromAge(fetchAndStore(id, tv, key[0..key_len]) orelse return .unrated);
}

/// Fetch one certification and cache it. Returns null on failure (nothing
/// cached, so the next lookup retries) and ?age wrapped on success.
fn fetchAndStore(id: i32, tv: bool, key: []const u8) ??u8 {
    var path_buf: [96]u8 = undefined;
    const path = (if (tv)
        std.fmt.bufPrint(&path_buf, "/3/tv/{d}/content_ratings", .{id})
    else
        std.fmt.bufPrint(&path_buf, "/3/movie/{d}/release_dates", .{id})) catch return null;
    @import("../core/rate_limit.zig").acquire("tmdb-cert", 20.0);
    const body = @import("tmdb_api.zig").tmdbApiOwned(path, key, 256 * 1024);
    const result: ??u8 = if (body) |b| pure.tmdbAge(alloc, b, "US") else null;
    if (body) |b| alloc.free(b);
    mutex.lock();
    defer mutex.unlock();
    if (result) |age| {
        const e = findLocked(id, tv) orelse claimLocked(id, tv);
        e.pending = false;
        e.age = age;
    } else if (findLocked(id, tv)) |e| {
        if (e.pending) e.used = false;
    }
    return result;
}

fn itemRatingBlocking(_: void, item: *const state.TmdbItem) mp.Rating {
    return ratingBlocking(item.id, isTv(item), item.imdb_id[0..@min(item.imdb_id_len, item.imdb_id.len)]);
}

fn itemRatingCached(_: void, item: *const state.TmdbItem) mp.Rating {
    return cachedRating(item.id, isTv(item), item.imdb_id[0..@min(item.imdb_id_len, item.imdb_id.len)]);
}

/// Worker threads: drop rows the running kid profile may not see from a list
/// that has not been published yet. No-op for adults.
pub fn filterStaged(list: *std.ArrayListUnmanaged(state.TmdbItem)) void {
    if (!active()) return;
    const c = profiles.runningCap();
    list.items.len = mp.filterInPlace(state.TmdbItem, list.items, c.cap, c.allow_unrated, {}, itemRatingBlocking);
}

/// Worker threads: same, over a caller-owned slice. Returns the kept count.
pub fn filterSliceBlocking(items: []state.TmdbItem) usize {
    if (!active()) return items.len;
    const c = profiles.runningCap();
    return mp.filterInPlace(state.TmdbItem, items, c.cap, c.allow_unrated, {}, itemRatingBlocking);
}

/// Any thread, never blocks: whether a row may be listed from the cache alone.
pub fn visibleCached(item: *const state.TmdbItem) bool {
    if (!active()) return true;
    return decideList(itemRatingCached({}, item));
}

/// Whether a row with no rating at all may be listed (operator picks, plain
/// titles without a catalog id).
pub fn unratedVisible() bool {
    if (!active()) return true;
    return decideList(.unrated);
}

/// Worker threads: a catalog id whose media type comes from tmdb_items.
pub fn idVisibleBlocking(id: i32) bool {
    if (!active()) return true;
    if (id <= 0) return decideList(.unrated);
    const db = @import("../core/db.zig");
    var tv = false;
    if (db.prepare("SELECT media_type FROM tmdb_items WHERE id=?1")) |stmt| {
        defer db.finalize(stmt);
        db.bindInt(stmt, 1, id);
        if (db.step(stmt) == db.c.SQLITE_ROW) tv = std.mem.eql(u8, db.columnText(stmt, 0) orelse "", "tv");
    }
    var imdb_buf: [16]u8 = undefined;
    const imdb = if (tv) db.tvImdbId(id, &imdb_buf) else db.movieImdbId(id, &imdb_buf);
    return decideList(ratingBlocking(id, tv, imdb));
}

/// Web API gate for one title (connection thread, may block on TMDB).
pub fn apiDecision(id: i32, tv: bool, imdb: []const u8) mp.Decision {
    if (!active()) return .allow;
    const c = profiles.runningCap();
    return mp.playDecision(c.cap, c.allow_unrated, ratingBlocking(id, tv, imdb));
}

/// UI-thread gate for a TMDB item. True = proceed. False = blocked or still
/// checking (a toast says which).
pub fn allowTmdb(item: *const state.TmdbItem) bool {
    if (!active()) return true;
    const tv = isTv(item);
    const imdb = item.imdb_id[0..@min(item.imdb_id_len, item.imdb_id.len)];
    const r = cachedRating(item.id, tv, imdb);
    if (r == .pending) {
        mutex.lock();
        const in_flight = if (findLocked(item.id, tv)) |e| e.pending else false;
        if (!in_flight) _ = claimLocked(item.id, tv);
        mutex.unlock();
        if (!in_flight) {
            const t = &state.app.tmdb;
            var key: [256]u8 = undefined;
            const key_len = @min(t.api_key_len, key.len);
            @memcpy(key[0..key_len], t.api_key[0..key_len]);
            @import("../core/workers.zig").spawn(fetchWorker, .{ item.id, tv, key, key_len }) catch {
                mutex.lock();
                if (findLocked(item.id, tv)) |e| e.used = false;
                mutex.unlock();
                return decide(.unrated);
            };
        }
    }
    return decide(r);
}

fn decide(r: mp.Rating) bool {
    const c = profiles.runningCap();
    const d = mp.playDecision(c.cap, c.allow_unrated, r);
    if (d == .allow) return true;
    state.showToast(d.message());
    return false;
}

fn fetchWorker(id: i32, tv: bool, key: [256]u8, key_len: usize) void {
    _ = fetchAndStore(id, tv, key[0..key_len]);
    // showToast is UI-thread state; the next click decides from the cache.
    @import("../core/logs.zig").pushLog("info", "profiles", "Age rating checked", false);
    state.wakeUi();
}
