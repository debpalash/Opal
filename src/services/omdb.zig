//! OMDb (omdbapi.com) ratings enrichment — the real IMDb / Rotten Tomatoes /
//! Metacritic scores that TMDB can't provide, shown on the movie/TV detail view.
//! Mirrors the keyless TVmaze enrichment worker (tvmaze.zig), but OMDb needs a
//! user-supplied free key (state.app.omdb_api_key): with NO key the module is
//! fully INERT — no fetch, no thread — it ships dark until the user pastes a key
//! in Settings.
//!
//! Opening a detail (tmdb.openTvDetail → onDetailOpen) kicks a single detached
//! worker that resolves the TMDB id → IMDb id via TMDB `/external_ids` (the same
//! lookup the resolver uses) then fetches OMDb by IMDb id. Results live in module
//! vars (NOT state.zig) behind a mutex; the UI thread reads them each frame via
//! ratingsLabel() / detailsLabel().
//!
//! All JSON parsing routes through omdb_pure.zig (unit-tested, no drift).
//! Endpoint: https://www.omdbapi.com/?i=tt{imdbId}&apikey={key}

const std = @import("std");
const io = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const pure = @import("omdb_pure.zig");

const alloc = @import("../core/alloc.zig").allocator;

// ── Module-level cache (protected by data_mutex). Keyed by the TMDB id we were
//    opened for, so re-opening the same title reuses the fetched data. ──
var data_mutex: sync.Mutex = .{};
var cached_tmdb_id: i32 = 0; // ratings belong to this title (0 = none)
var have_ratings: bool = false;
var ratings: pure.Ratings = .{};

/// Bumped on every open; a worker only publishes if it is still the latest, so
/// fast title-switching never shows another title's ratings.
var gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
/// Concurrent-spawn guard (a second open before the first worker returns).
var busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// curl `url` into `buf`, returning bytes read (0 on failure). OMDb is a plain
/// keyed HTTPS JSON API — the key rides as a query param, no auth header.
fn curlInto(url: []const u8, buf: []u8) usize {
    var child = io.Child.init(&.{ "curl", "-s", "--max-time", "12", url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

/// Trigger a background OMDb fetch for a freshly-opened movie/TV detail. INERT
/// when no OMDb key is set (ships dark), and a no-op when TMDB is unconfigured
/// (no way to resolve the IMDb id), when we already hold this title's ratings,
/// or when a fetch is in flight. `media_type` is TMDB's "tv" or "movie". Safe to
/// call from the UI thread (openTvDetail).
pub fn onDetailOpen(tmdb_id: i32, media_type: []const u8) void {
    if (state.app.omdb_api_key_len == 0) return; // inert without a user key
    if (state.app.tmdb.api_key_len == 0) return; // need TMDB for external_ids
    if (tmdb_id <= 0 or media_type.len == 0) return;

    // Already cached for this title? Nothing to do (guard read under the lock).
    data_mutex.lock();
    const cached = cached_tmdb_id == tmdb_id and have_ratings;
    data_mutex.unlock();
    if (cached) return;

    if (busy.swap(true, .acq_rel)) return; // a worker is already running

    // New generation; drop any stale published data immediately so the UI
    // doesn't show the previous title's ratings while the fetch runs.
    const my_gen = gen.fetchAdd(1, .acq_rel) + 1;
    data_mutex.lock();
    cached_tmdb_id = tmdb_id;
    have_ratings = false;
    ratings = .{};
    data_mutex.unlock();

    const S = struct {
        var id: i32 = 0;
        var g: u32 = 0;
        var mt_buf: [8]u8 = undefined;
        var mt_len: usize = 0;
    };
    S.id = tmdb_id;
    S.g = my_gen;
    const ml = @min(media_type.len, S.mt_buf.len);
    @memcpy(S.mt_buf[0..ml], media_type[0..ml]);
    S.mt_len = ml;

    if (std.Thread.spawn(.{}, worker, .{ S.id, S.g, S.mt_buf[0..S.mt_len] })) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        busy.store(false, .release);
    }
}

fn worker(tmdb_id: i32, my_gen: u32, media_type: []const u8) void {
    defer busy.store(false, .release);

    // Snapshot the keys once — the UI thread could clear them mid-fetch.
    const key = state.app.omdb_api_key[0..state.app.omdb_api_key_len];
    const tmdb_key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];
    if (key.len == 0 or tmdb_key.len == 0) return;

    const buf = alloc.alloc(u8, 64 * 1024) catch return;
    defer alloc.free(buf);

    // 1) TMDB /external_ids → IMDb id (same endpoint the resolver reuses).
    var url_buf: [256]u8 = undefined;
    const ext_url = std.fmt.bufPrint(&url_buf, "/3/{s}/{d}/external_ids", .{ media_type, tmdb_id }) catch return;
    const n1 = @import("tmdb_api.zig").tmdbApiInto(ext_url, tmdb_key, buf);
    if (n1 == 0) return;
    if (gen.load(.acquire) != my_gen) return; // superseded

    const imdb_raw = pure.extractImdbId(buf[0..n1]) orelse {
        logs.pushLog("info", "omdb", "no IMDb id for this title (external_ids)", false);
        return;
    };
    var imdb_buf: [24]u8 = undefined;
    const imdb_id = pure.normalizeImdbId(imdb_raw, &imdb_buf) orelse return;

    // 2) OMDb by IMDb id. Key is a query param — safe (only tt-digits + the key).
    const omdb_url = std.fmt.bufPrint(&url_buf, "https://www.omdbapi.com/?i={s}&apikey={s}", .{ imdb_id, key }) catch return;
    const n2 = curlInto(omdb_url, buf);
    if (n2 == 0) return;
    if (gen.load(.acquire) != my_gen) return;

    const parsed = pure.parse(buf[0..n2]);
    if (!parsed.hasScores()) {
        logs.pushLog("info", "omdb", "OMDb returned no usable ratings", false);
        return;
    }

    // Publish under the lock, re-checking the generation so a newer open wins.
    data_mutex.lock();
    defer data_mutex.unlock();
    if (gen.load(.acquire) != my_gen) return;
    if (cached_tmdb_id != tmdb_id) return;
    ratings = parsed;
    have_ratings = true;

    var lb: [128]u8 = undefined;
    logs.pushLog("info", "omdb", std.fmt.bufPrint(&lb, "OMDb {s}: IMDb={s} RT={s} MC={s}", .{
        imdb_id,
        ratings.imdb_rating[0..ratings.imdb_rating_len],
        ratings.rt_percent[0..ratings.rt_percent_len],
        ratings.metacritic[0..ratings.metacritic_len],
    }) catch "OMDb ratings loaded", false);
    state.wakeUi();
}

/// UI-thread read: the scores row ("IMDb 9.5 · RT 96% · Metacritic 88") for the
/// currently-open title, or null when there is no data. Snapshots under the lock
/// (cheap copy), releases, then formats — never holds the lock across UI work.
pub fn ratingsLabel(tmdb_id: i32, buf: []u8) ?[]const u8 {
    data_mutex.lock();
    const ok = have_ratings and cached_tmdb_id == tmdb_id;
    const snap = ratings;
    data_mutex.unlock();
    if (!ok) return null;
    return pure.formatScores(&snap, buf);
}

/// UI-thread read: the secondary details line ("Rated TV-MA · Won 2 Emmys…")
/// for the currently-open title, or null. Same snapshot discipline as above.
pub fn detailsLabel(tmdb_id: i32, buf: []u8) ?[]const u8 {
    data_mutex.lock();
    const ok = have_ratings and cached_tmdb_id == tmdb_id;
    const snap = ratings;
    data_mutex.unlock();
    if (!ok) return null;
    return pure.formatDetails(&snap, buf);
}
