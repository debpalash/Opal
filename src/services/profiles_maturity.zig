//! Maturity gate for kid profiles (ROADMAP 7.3).
//!
//! Hooked where a TMDB title turns into "find sources / open episodes"
//! (tmdb.openOrSearch — browse cards, poster details, Home rails). Adult
//! profiles pass straight through. For a kid profile the title's certification
//! is fetched once from TMDB (`release_dates` / `content_ratings`), mapped to a
//! minimum age (profiles_pure.tmdbAge) and checked against the profile's cap.
//! A title with no known rating (keyless catalog, no certification) follows the
//! profile's unrated policy — deny by default.
//!
//! Adult flags elsewhere (torrent search, anime, Live TV) ride the NSFW filter,
//! which profiles.enforce() pins on for kid profiles.

const std = @import("std");
const pure = @import("profiles_pure.zig");
const profiles = @import("profiles.zig");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig").allocator;

const CACHE_LEN = 64;
const Entry = struct {
    id: i32 = 0,
    tv: bool = false,
    used: bool = false,
    pending: bool = false,
    /// Minimum age, or null for unrated/unknown.
    age: ?u8 = null,
};

var mutex: sync.Mutex = .{};
var cache: [CACHE_LEN]Entry = [_]Entry{.{}} ** CACHE_LEN;
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

/// UI-thread gate for a TMDB item. True = proceed. False = blocked or still
/// checking (a toast says which).
pub fn allowTmdb(item: *const state.TmdbItem) bool {
    if (!profiles.runningIsKid()) return true;
    const mt = item.media_type[0..@min(item.media_type_len, item.media_type.len)];
    const tv = std.mem.eql(u8, mt, "tv");
    const imdb = item.imdb_id[0..@min(item.imdb_id_len, item.imdb_id.len)];
    const keyless = state.app.tmdb.api_key_len == 0 or @import("keyless_tv_pure.zig").isSynthetic(item.id, imdb);
    if (keyless or item.id <= 0) return decide(null);

    mutex.lock();
    if (findLocked(item.id, tv)) |e| {
        const pending = e.pending;
        const age = e.age;
        mutex.unlock();
        if (pending) {
            state.showToast("Checking the age rating...");
            return false;
        }
        return decide(age);
    }
    _ = claimLocked(item.id, tv);
    mutex.unlock();

    const t = &state.app.tmdb;
    var key: [256]u8 = undefined;
    const key_len = @min(t.api_key_len, key.len);
    @memcpy(key[0..key_len], t.api_key[0..key_len]);
    @import("../core/workers.zig").spawn(fetchWorker, .{ item.id, tv, key, key_len }) catch {
        mutex.lock();
        if (findLocked(item.id, tv)) |e| e.used = false;
        mutex.unlock();
        return decide(null);
    };
    state.showToast("Checking the age rating...");
    return false;
}

fn decide(age: ?u8) bool {
    if (profiles.maturityAllows(age)) return true;
    state.showToast(if (age == null) "Not rated - not available on this profile" else "Rated above this profile's age limit");
    return false;
}

fn fetchWorker(id: i32, tv: bool, key: [256]u8, key_len: usize) void {
    var path_buf: [96]u8 = undefined;
    const path = (if (tv)
        std.fmt.bufPrint(&path_buf, "/3/tv/{d}/content_ratings", .{id})
    else
        std.fmt.bufPrint(&path_buf, "/3/movie/{d}/release_dates", .{id})) catch "";
    var age: ?u8 = null;
    if (path.len > 0) {
        if (@import("tmdb_api.zig").tmdbApiOwned(path, key[0..key_len], 256 * 1024)) |body| {
            defer alloc.free(body);
            age = pure.tmdbAge(alloc, body, "US");
        }
    }
    mutex.lock();
    if (findLocked(id, tv)) |e| {
        e.pending = false;
        e.age = age;
    }
    mutex.unlock();
    // showToast is UI-thread state; the next click decides from the cache.
    @import("../core/logs.zig").pushLog("info", "profiles", "Age rating checked", false);
    state.wakeUi();
}
