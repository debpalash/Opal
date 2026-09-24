const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const http = @import("../core/http.zig");
const parse = @import("tmdb_parse.zig");
const content_cache = @import("../core/content_cache.zig");
const ccp = @import("../core/content_cache_pure.zig");
const rate_limit = @import("../core/rate_limit.zig");

const alloc = parse.alloc;

// Encrypted-content-cache SWR for the default browse grid: cache page-1 browse
// rows to disk so the Home/Browse grid is not blank on cold start. Serialization
// routes through content_cache_pure.Writer/Reader (tested). Cap the cached set
// so one page's worth of rows stays well under the entry size bound.
const TMDB_BROWSE_TTL_S: i64 = @import("browse_cache.zig").TTL_S;
const TMDB_BLOB_CAP: usize = 128 * 1024;
const TMDB_MAX_CACHED_ITEMS: usize = 100;

// ══════════════════════════════════════════════════════════
// Unified Fetch Logic
// ══════════════════════════════════════════════════════════

// UI-thread-only: coalesce changes while one worker owns the request snapshot.
var refresh_queued: std.atomic.Value(bool) = .init(false);

pub fn fetchCurrentView(append: bool) void {
    if (state.app.tmdb.is_loading.load(.acquire)) {
        if (!append) refresh_queued.store(true, .release);
        return;
    }
    // A worker may have finished between frames. Do not publish its page over
    // the newer selection, or let its append flag contaminate a replacement.
    state.app.tmdb.results_mutex.lock();
    state.app.tmdb.pending_ready = false;
    state.app.tmdb.results_mutex.unlock();
    refresh_queued.store(false, .release);

    // SWR: stamp the cache time on a fresh (non-append) load so revisits within
    // the TTL skip the network (see browse_cache + renderTmdbContent).
    if (!append) state.app.tmdb.last_fetch_s = @import("browse_cache.zig").now();

    // Reserve once to keep scrolling/appending cheap. Poster jobs publish by
    // identity on the UI thread, so reallocating no longer invalidates workers.
    state.app.tmdb.results.ensureTotalCapacity(alloc, 2048) catch {};

    if (state.app.tmdb.view == .Search) {
        const qlen = std.mem.indexOfScalar(u8, &state.app.tmdb.search_buf, 0) orelse 0;
        if (qlen > 0) {
            fetchTmdb(.search, state.app.tmdb.search_buf[0..qlen], append);
        }
    } else {
        fetchTmdb(.browse, "", append);
    }
}

// ══════════════════════════════════════════════════════════
// Encrypted on-disk content cache — browse-grid stale-while-revalidate.
// ══════════════════════════════════════════════════════════

fn browseCacheKey(buf: []u8) []const u8 {
    const t = &state.app.tmdb;
    return std.fmt.bufPrint(buf, "catalog:browse:v2:{d}:{d}:{d}:{d}:{d}:{d}", .{
        @intFromBool(t.api_key_len > 0),
        @intFromEnum(t.category),
        @intFromEnum(t.media_filter),
        @intFromEnum(t.time_window),
        t.genre_idx,
        t.discover_sort,
    }) catch "tmdb:browse:default";
}

fn serializeItem(w: *ccp.Writer, it: state.TmdbItem) void {
    w.i32v(it.id);
    w.blob(it.imdb_id[0..@min(it.imdb_id_len, it.imdb_id.len)]);
    w.blob(it.title[0..@min(it.title_len, it.title.len)]);
    w.blob(it.year[0..@min(it.year_len, it.year.len)]);
    w.blob(it.release_date[0..@min(it.release_date_len, it.release_date.len)]);
    w.f32v(it.rating);
    w.blob(it.overview[0..@min(it.overview_len, it.overview.len)]);
    w.blob(it.media_type[0..@min(it.media_type_len, it.media_type.len)]);
    w.blob(it.genre_text[0..@min(it.genre_text_len, it.genre_text.len)]);
    w.blob(it.poster_path[0..@min(it.poster_path_len, it.poster_path.len)]);
}

fn copyField(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

/// Reads one item from `r`. Returns null when the blob is truncated.
fn deserializeItem(r: *ccp.Reader) ?state.TmdbItem {
    var it = state.TmdbItem{};
    it.id = r.i32v() orelse return null;
    copyField(&it.imdb_id, &it.imdb_id_len, r.blob() orelse return null);
    copyField(&it.title, &it.title_len, r.blob() orelse return null);
    copyField(&it.year, &it.year_len, r.blob() orelse return null);
    copyField(&it.release_date, &it.release_date_len, r.blob() orelse return null);
    it.rating = r.f32v() orelse return null;
    copyField(&it.overview, &it.overview_len, r.blob() orelse return null);
    copyField(&it.media_type, &it.media_type_len, r.blob() orelse return null);
    copyField(&it.genre_text, &it.genre_text_len, r.blob() orelse return null);
    copyField(&it.poster_path, &it.poster_path_len, r.blob() orelse return null);
    return it;
}

/// SWR write — persist a fresh page-1 browse set (called from the fetch worker).
fn putBrowseCache(items: []const state.TmdbItem, key: []const u8) void {
    if (!state.app.content_cache_enabled) return;
    if (items.len == 0) return;
    const buf = alloc.alloc(u8, TMDB_BLOB_CAP) catch return;
    defer alloc.free(buf);
    var w = ccp.Writer.init(buf);
    const n: u16 = @intCast(@min(items.len, TMDB_MAX_CACHED_ITEMS));
    w.u16v(n);
    var i: usize = 0;
    while (i < n) : (i += 1) serializeItem(&w, items[i]);
    const blob = w.done() orelse return;
    content_cache.put(key, blob, TMDB_BROWSE_TTL_S);
}

/// SWR read — seed the browse grid from disk so it paints INSTANTLY on cold
/// start instead of showing a blank gallery while the first fetch runs. Called
/// on the UI thread from renderTmdbContent before the initial fetch; only seeds
/// the default Trending browse grid when it is currently empty.
pub fn seedBrowseFromCache() void {
    if (!state.app.content_cache_enabled) return;
    const t = &state.app.tmdb;
    if (t.view != .Trending) return;
    if (t.results.items.len != 0) return;
    const buf = alloc.alloc(u8, TMDB_BLOB_CAP) catch return;
    defer alloc.free(buf);
    var key_buf: [96]u8 = undefined;
    const key = browseCacheKey(&key_buf);
    const hit = content_cache.get(key, buf) orelse return;

    var r = ccp.Reader.init(hit.bytes);
    const n = r.u16v() orelse return;
    t.results_mutex.lock();
    defer t.results_mutex.unlock();
    // Match fetchCurrentView's stable reservation so the imminent fetch's
    // ensureTotalCapacity(2048) never reallocates under poster workers.
    t.results.ensureTotalCapacity(alloc, 2048) catch {};
    var i: usize = 0;
    while (i < n and t.results.items.len < TMDB_MAX_CACHED_ITEMS) : (i += 1) {
        const it = deserializeItem(&r) orelse break;
        t.results.append(alloc, it) catch break;
    }
}

const FetchMode = enum { search, browse };

/// Synchronous, side-effect-free catalog lookup for the universal resolver.
/// Results are copied into caller-owned storage; the Browse page's live and
/// pending lists are never touched by this worker.
pub fn searchCatalogInto(query: []const u8, out: []state.TmdbItem) usize {
    if (query.len == 0 or out.len == 0) return 0;
    var staged: std.ArrayListUnmanaged(state.TmdbItem) = .empty;
    defer staged.deinit(alloc);

    const key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];
    if (key.len > 0) {
        var url_buf: [512]u8 = undefined;
        const url = buildApiUrl(&url_buf, .search, query, .trending, .all, .week, 0, 0, 1) orelse return 0;
        rate_limit.acquire("tmdb", 3.0);
        const body = httpGet(url, key) orelse return 0;
        defer alloc.free(body);
        parse.parseTmdbResponse(body, &staged);
    } else {
        fetchCinemetaInto(&staged, .search, query, .trending, .all, 0, 1);
    }

    var written: usize = 0;
    for (staged.items) |item| {
        if (written >= out.len) break;
        const kind = item.media_type[0..@min(item.media_type_len, item.media_type.len)];
        if (!std.mem.eql(u8, kind, "movie") and !std.mem.eql(u8, kind, "tv")) continue;
        out[written] = item;
        written += 1;
    }
    return written;
}

fn fetchTmdb(mode: FetchMode, query: []const u8, append: bool) void {
    if (state.app.tmdb.is_loading.load(.acquire)) return;
    state.app.tmdb.is_loading.store(true, .release);

    const S = struct {
        var fetch_mode: FetchMode = .browse;
        var q: [256]u8 = undefined;
        var q_len: usize = 0;
        var do_append: bool = false;
        var category: state.TmdbCategory = .trending;
        var media_filter: state.TmdbMediaFilter = .all;
        var time_window: state.TmdbTimeWindow = .week;
        var genre_idx: usize = 0;
        var discover_sort: u8 = 0;
        var page: u32 = 1;
        var cache_key: [96]u8 = undefined;
        var cache_key_len: usize = 0;
    };

    S.cache_key_len = browseCacheKey(&S.cache_key).len;
    S.fetch_mode = mode;
    S.do_append = append;
    S.category = state.app.tmdb.category;
    S.media_filter = state.app.tmdb.media_filter;
    S.time_window = state.app.tmdb.time_window;
    S.genre_idx = state.app.tmdb.genre_idx;
    S.discover_sort = state.app.tmdb.discover_sort;
    S.page = state.app.tmdb.page;
    if (query.len > 0) {
        const ql = @min(query.len, 255);
        @memcpy(S.q[0..ql], query[0..ql]);
        S.q_len = ql;
    } else {
        S.q_len = 0;
    }

    state.app.tmdb.thread = @import("../core/workers.zig").spawnLegacy(struct {
        fn worker() void {
            defer {
                state.app.tmdb.is_loading.store(false, .release);
                state.wakeUi();
            }

            const key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];

            // Parse into a LOCAL list and stage it — never mutate the live
            // `results` the UI thread is iterating mid-frame (that race was
            // the renderCatalogRail out-of-bounds crash). The UI thread swaps
            // staged pages in at frame start via applyPendingResults().
            var staged: std.ArrayListUnmanaged(state.TmdbItem) = .empty;
            var total_pages: u32 = 100;
            if (key.len > 0) {
                var url_buf: [512]u8 = undefined;
                const url = buildApiUrl(&url_buf, S.fetch_mode, S.q[0..S.q_len], S.category, S.media_filter, S.time_window, S.genre_idx, S.discover_sort, S.page) orelse return;
                const body = httpGet(url, key) orelse return;
                defer alloc.free(body);
                total_pages = @intCast(@max(1, parse.extractJsonInt(body, "\"total_pages\":")));
                parse.parseTmdbResponse(body, &staged);
            } else {
                fetchCinemetaInto(&staged, S.fetch_mode, S.q[0..S.q_len], S.category, S.media_filter, S.genre_idx, S.page);
            }

            // SWR write: persist the fresh default browse grid (page 1 only) so
            // the next cold start paints instantly. Search + infinite-scroll
            // pages are not cached.
            if (S.fetch_mode == .browse and !S.do_append and S.page == 1)
                putBrowseCache(staged.items, S.cache_key[0..S.cache_key_len]);

            state.app.tmdb.results_mutex.lock();
            defer state.app.tmdb.results_mutex.unlock();
            state.app.tmdb.pending_results.deinit(alloc);
            state.app.tmdb.pending_results = staged;
            state.app.tmdb.pending_append = S.do_append;
            state.app.tmdb.pending_total_pages = total_pages;
            state.app.tmdb.pending_ready = true;
        }
    }.worker, .{}) catch blk: {
        state.app.tmdb.is_loading.store(false, .release);
        break :blk null;
    };
    if (state.app.tmdb.thread) |t| @import("../core/workers.zig").release(t); // never joined — detach to avoid leaking the handle
}

fn buildCinemetaUrl(buf: *[512]u8, content_type: []const u8, mode: FetchMode, query: []const u8, cat: state.TmdbCategory, genre_idx: usize, page: u32) ?[]const u8 {
    const catalog = if (mode == .search or genre_idx != 0) "top" else switch (cat) {
        .top_rated => "imdbRating",
        .now_playing, .upcoming => "year",
        else => "top",
    };
    var value_buf: [256]u8 = undefined;
    const value = if (mode == .search)
        http.urlEncode(query, &value_buf)
    else if (genre_idx < @import("tmdb_pure.zig").GENRE_NAMES.len)
        http.urlEncode(@import("tmdb_pure.zig").GENRE_NAMES[genre_idx], &value_buf)
    else
        "";
    const extra_name: []const u8 = if (mode == .search) "search" else if (genre_idx != 0) "genre" else "";
    const skip = (page -| 1) * 50;
    if (extra_name.len > 0 and skip > 0)
        return std.fmt.bufPrint(buf, "https://v3-cinemeta.strem.io/catalog/{s}/{s}/{s}={s}&skip={d}.json", .{ content_type, catalog, extra_name, value, skip }) catch null;
    if (extra_name.len > 0)
        return std.fmt.bufPrint(buf, "https://v3-cinemeta.strem.io/catalog/{s}/{s}/{s}={s}.json", .{ content_type, catalog, extra_name, value }) catch null;
    if (skip > 0)
        return std.fmt.bufPrint(buf, "https://v3-cinemeta.strem.io/catalog/{s}/{s}/skip={d}.json", .{ content_type, catalog, skip }) catch null;
    return std.fmt.bufPrint(buf, "https://v3-cinemeta.strem.io/catalog/{s}/{s}.json", .{ content_type, catalog }) catch null;
}

fn fetchCinemetaType(out: *std.ArrayListUnmanaged(state.TmdbItem), content_type: []const u8, mode: FetchMode, query: []const u8, cat: state.TmdbCategory, genre_idx: usize, page: u32) void {
    var url_buf: [512]u8 = undefined;
    const url = buildCinemetaUrl(&url_buf, content_type, mode, query, cat, genre_idx, page) orelse return;
    const body = httpGet(url, "") orelse return;
    defer alloc.free(body);
    parse.parseCinemetaResponse(body, out);
}

fn fetchCinemetaInto(out: *std.ArrayListUnmanaged(state.TmdbItem), mode: FetchMode, query: []const u8, cat: state.TmdbCategory, mf: state.TmdbMediaFilter, genre_idx: usize, page: u32) void {
    fetchCinemetaIntoUsing(fetchCinemetaType, out, mode, query, cat, mf, genre_idx, page);
}

fn fetchCinemetaIntoUsing(comptime fetchType: anytype, out: *std.ArrayListUnmanaged(state.TmdbItem), mode: FetchMode, query: []const u8, cat: state.TmdbCategory, mf: state.TmdbMediaFilter, genre_idx: usize, page: u32) void {
    switch (mf) {
        .movie => fetchType(out, "movie", mode, query, cat, genre_idx, page),
        .tv => fetchType(out, "series", mode, query, cat, genre_idx, page),
        .all => {
            // Independent catalogs overlap their network waits. The child is
            // joined before returning, so it never outlives these inputs.
            const Fetch = struct {
                fn run(rows: *std.ArrayListUnmanaged(state.TmdbItem), m: FetchMode, q: []const u8, c: state.TmdbCategory, g: usize, p: u32) void {
                    fetchType(rows, "series", m, q, c, g, p);
                }
            };
            var series: std.ArrayListUnmanaged(state.TmdbItem) = .empty;
            defer series.deinit(alloc);
            const worker = @import("../core/workers.zig").spawnLegacy(Fetch.run, .{ &series, mode, query, cat, genre_idx, page }) catch {
                fetchType(out, "movie", mode, query, cat, genre_idx, page);
                fetchType(out, "series", mode, query, cat, genre_idx, page);
                return;
            };
            fetchType(out, "movie", mode, query, cat, genre_idx, page);
            worker.join();
            out.appendSlice(alloc, series.items) catch {};
        },
    }
}

/// UI-THREAD ONLY — called once per frame (main.appFrame, next to
/// state.applyPendingNav). Swaps worker-staged pages into the live list.
/// Post-init, this is the ONLY place `results` is mutated, so render code can
/// iterate it without locking; non-UI readers (remote, ai_intent) take
/// `results_mutex`, which this holds while mutating.
pub fn applyPendingResults() void {
    drainPosterResults();
    const t = &state.app.tmdb;
    if (refresh_queued.load(.acquire)) {
        if (!t.is_loading.load(.acquire)) fetchCurrentView(false);
        return;
    }
    t.results_mutex.lock();
    defer t.results_mutex.unlock();
    if (!t.pending_ready) return;
    t.pending_ready = false;
    if (!t.pending_append) {
        for (t.results.items) |*item| @import("../core/poster.zig").deinitPoster(&item.poster_pixels, &item.poster_tex);
        t.results.clearRetainingCapacity();
    }
    // Poster publication does not retain pointers into this growable list.
    t.results.appendSlice(alloc, t.pending_results.items) catch {};
    t.pending_results.clearRetainingCapacity();
    t.total_pages = t.pending_total_pages;
    state.wakeUi();
}

fn buildApiUrl(buf: *[512]u8, mode: FetchMode, query: []const u8, cat: state.TmdbCategory, mf: state.TmdbMediaFilter, tw: state.TmdbTimeWindow, genre_idx: usize, discover_sort: u8, page: u32) ?[]const u8 {
    const trending_mt = switch (mf) {
        .all => "all",
        .movie => "movie",
        .tv => "tv",
    };
    const list_mt = switch (mf) {
        .all => "movie",
        .movie => "movie",
        .tv => "tv",
    };
    const tw_str = switch (tw) {
        .day => "day",
        .week => "week",
    };

    // Genre browsing goes through /discover (paginated like any category);
    // the genre dropdown overrides the category chips while active, and the
    // sort chips (Popular/Top rated/Newest) pick the discover ordering.
    if (mode == .browse) {
        const gid = @import("tmdb_pure.zig").genreId(genre_idx, mf == .tv);
        if (gid != 0) {
            const sort = @import("tmdb_pure.zig").discoverSortParam(discover_sort, mf == .tv);
            return std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/discover/{s}?with_genres={d}&sort_by={s}&page={d}", .{ list_mt, gid, sort, page }) catch null;
        }
    }

    if (mode == .search) {
        var enc_buf: [256]u8 = undefined;
        const enc = http.urlEncode(query, &enc_buf);
        const search_type = switch (mf) {
            .all => "multi",
            .movie => "movie",
            .tv => "tv",
        };
        return std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/search/{s}?query={s}&page={d}", .{ search_type, enc, page }) catch null;
    }

    if (mf == .tv and (cat == .now_playing or cat == .upcoming)) {
        var day_buf: [16]u8 = undefined;
        const today = @import("tmdb_pure.zig").ymd(@import("../core/io_global.zig").timestamp(), &day_buf) orelse return null;
        return @import("tmdb_pure.zig").tvWindowUrl(buf, cat == .upcoming, today, page);
    }

    return switch (cat) {
        .trending => std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/trending/{s}/{s}?page={d}", .{ trending_mt, tw_str, page }) catch null,
        .popular => std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/{s}/popular?page={d}", .{ list_mt, page }) catch null,
        .top_rated => std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/{s}/top_rated?page={d}", .{ list_mt, page }) catch null,
        .now_playing => std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/movie/now_playing?page={d}", .{page}) catch null,
        // Routed through tmdb_pure so the tested URL is the shipped URL — see
        // upcomingUrl for why /movie/upcoming showed already-released films.
        .upcoming => blk: {
            var day_buf: [16]u8 = undefined;
            const today = @import("tmdb_pure.zig").ymd(@import("../core/io_global.zig").timestamp(), &day_buf) orelse
                break :blk std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/movie/upcoming?page={d}", .{page}) catch null;
            break :blk @import("tmdb_pure.zig").upcomingUrl(buf, today, page);
        },
    };
}

// ══════════════════════════════════════════════════════════
// Genre Discover
// ══════════════════════════════════════════════════════════

/// Fetch movies by TMDB genre ID (e.g. 28 = Action, 878 = Sci-Fi) — used by
/// AI intent ("show me action movies"). Routes through the same genre_idx +
/// fetchCurrentView path as the toolbar dropdown so pagination, the dropdown
/// selection and filter chips stay coherent; the old standalone /discover
/// worker left genre_idx=0, so infinite scroll appended TRENDING pages onto
/// discover results and the UI showed "All genres" over genre results.
pub fn fetchDiscover(genre_id: u32) void {
    const idx = @import("tmdb_pure.zig").genreIndexForMovieId(genre_id) orelse return;
    state.app.tmdb.view = .Trending;
    state.app.tmdb.genre_idx = idx;
    if (state.app.tmdb.media_filter == .all) state.app.tmdb.media_filter = .movie; // discover has no multi endpoint
    state.app.tmdb.page = 1;
    state.app.tmdb.loaded_once = true; // Browse must not immediately refetch over this
    @import("tmdb.zig").resetGalleryScroll();
    fetchCurrentView(false);
}

// ══════════════════════════════════════════════════════════
// Poster Fetching
// ══════════════════════════════════════════════════════════

// Workers own fixed slots, never pointers into replaceable catalog rows.
const PosterJob = struct {
    active: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    fetching: bool = false,
    id: i32 = 0,
    path: [256]u8 = undefined,
    path_len: usize = 0,
    pixels: ?[]u8 = null,
    w: u32 = 0,
    h: u32 = 0,
};
var poster_jobs: [8]PosterJob = .{PosterJob{}} ** 8;

pub fn drainPosterResults() void {
    const lists = [_]*std.ArrayListUnmanaged(state.TmdbItem){
        &state.app.tmdb.results,   &state.app.tmdb.favorites,
        &state.app.tmdb.watchlist, &state.app.tmdb.watching,
    };
    for (&poster_jobs) |*job| {
        if (!job.active or !job.done.load(.acquire)) continue;
        found: for (lists) |list| {
            for (list.items) |*item| {
                if (!item.poster_fetching or item.id != job.id or
                    !std.mem.eql(u8, item.poster_path[0..item.poster_path_len], job.path[0..job.path_len])) continue;
                item.poster_fetching = false;
                if (item.poster_tex == null and item.poster_pixels == null) {
                    item.poster_pixels = job.pixels;
                    item.poster_w = job.w;
                    item.poster_h = job.h;
                    job.pixels = null;
                }
                break :found;
            }
        }
        if (job.pixels) |pixels| std.heap.c_allocator.free(pixels);
        job.pixels = null;
        job.active = false;
    }
}

pub fn fetchPoster(item: *state.TmdbItem) void {
    if (item.poster_path_len == 0 or item.poster_fetching) return;
    // Route through the shared poster daemon: it carries the global concurrency
    // cap (no fetch storm when the infinite-scroll grid is flung), usize-first
    // pixel math (no i32 w*h*4 overflow), and the torn-publish guard — all of
    // which this provider's hand-rolled worker was missing.
    const path = item.poster_path[0..item.poster_path_len];
    var url_buf: [512]u8 = undefined;
    var compat_buf: [512]u8 = undefined;
    const url = if (std.mem.startsWith(u8, path, "https://") or std.mem.startsWith(u8, path, "http://"))
        (@import("cinemeta_pure.zig").compatiblePosterUrl(path, &compat_buf) orelse return)
    else
        std.fmt.bufPrint(&url_buf, "https://image.tmdb.org/t/p/w185{s}", .{path}) catch return;
    for (&poster_jobs) |*job| {
        if (job.active) continue;
        job.done.store(false, .release);
        job.id = item.id;
        job.path_len = path.len;
        @memcpy(job.path[0..path.len], path);
        job.active = @import("../core/poster.zig").fetchAsyncPublished(url, &job.pixels, &job.w, &job.h, &job.fetching, &job.done);
        item.poster_fetching = job.active;
        return;
    }
}

/// Sticky flag: some networks SNI-block api.themoviedb.org over HTTPS (the TLS
/// ClientHello is reset). Once we've seen HTTPS fail and HTTP succeed, prefer
/// HTTP for the rest of the session so we don't pay a failed HTTPS attempt each
/// call. (image.tmdb.org is a different host and is not blocked, so posters stay
/// HTTPS.) Shared with tmdb.zig's TV-detail fetch.
pub var tmdb_https_blocked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn curlIntoOnce(url: []const u8, auth_header: []const u8, buf: []u8) usize {
    const io_g = @import("../core/io_global.zig");
    // --connect-timeout bounds a dead/slow host to 3s on connect instead of
    // burning the full --max-time; --max-time trimmed to 8s for interactive
    // fetches. Without connect-timeout a black-holed host stalled the route
    // for the whole 12s (× retries × http/https fallback).
    // Stage through a temp FILE, not a pipe. A piped child blocks in write()
    // once its output fills the OS pipe buffer (~64KB) and the reader hasn't
    // drained it; that deadlocked fetches on Windows (curl left alive for
    // minutes at ~0 CPU despite --max-time, grid permanently empty). Files have
    // no such bound: curl writes everything, exits, then we read it back.
    const secure_temp = @import("../core/secure_temp.zig");
    var scratch = secure_temp.Workspace.create("tmdb") catch return 0;
    defer scratch.cleanup();
    var path_buf: [secure_temp.max_path_len]u8 = undefined;
    const path = scratch.reserveFile("response.json", &path_buf) catch return 0;

    // -L is required by the public Cinemeta endpoint, which currently answers
    // with a 307 to its catalog shard. Without it we read the redirect text,
    // reject it as non-JSON, and leave the keyless gallery empty.
    var child = if (auth_header.len > 0)
        io_g.Child.init(&.{ "curl", "-L", "-s", "--connect-timeout", "3", "--config", "-", "--max-time", "8", "-o", path, url }, alloc)
    else
        io_g.Child.init(&.{ "curl", "-L", "-s", "--connect-timeout", "3", "--max-time", "8", "-o", path, url }, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (auth_header.len > 0) {
        @import("../core/curl_secret.zig").spawnWithHeaders(&child, &.{auth_header}) catch return 0;
    } else {
        child.stdin_behavior = .Ignore;
        child.spawn() catch return 0;
    }
    _ = child.wait() catch {};

    const body = io_g.cwdReadFileAlloc(path, alloc, buf.len) catch return 0;
    defer alloc.free(body);
    const n = @min(body.len, buf.len);
    @memcpy(buf[0..n], body[0..n]);
    return n;
}

/// curl `url` (HTTPS) into `buf`, with an HTTPS→HTTP fallback for SNI-blocked
/// networks. CRITICAL: a response is only accepted if it looks like JSON — some
/// ISPs hijack plain HTTP to api.themoviedb.org and inject an HTML block page
/// (200 OK). Treating that HTML as success poisoned `tmdb_https_blocked` (sticky)
/// and routed every later call to the block page → all content stopped loading.
/// The flag now self-heals: it clears whenever HTTPS returns JSON again.
fn curlFallbackInto(url: []const u8, auth_header: []const u8, buf: []u8) usize {
    const pure = @import("tmdb_pure.zig");
    var hb: [768]u8 = undefined;
    const http_url = pure.httpsToHttp(url, &hb);

    // Known-blocked: try HTTP first, but only trust valid JSON. If HTTP no longer
    // returns JSON (ISP now hijacks HTTP too), fall through and re-try HTTPS.
    if (tmdb_https_blocked.load(.acquire)) {
        if (http_url) |hu| {
            const n = curlIntoOnce(hu, auth_header, buf);
            if (n > 0 and pure.looksLikeJson(buf[0..n])) return n;
        }
    }

    const n = curlIntoOnce(url, auth_header, buf); // HTTPS
    if (n > 0 and pure.looksLikeJson(buf[0..n])) {
        tmdb_https_blocked.store(false, .release); // HTTPS works — clear any stale block
        return n;
    }

    if (http_url) |hu| {
        const m = curlIntoOnce(hu, auth_header, buf);
        if (m > 0 and pure.looksLikeJson(buf[0..m])) {
            tmdb_https_blocked.store(true, .release); // genuine SNI-block network
            return m;
        }
    }
    return 0;
}

/// Fetch a TMDB API endpoint into `buf`, picking the auth mechanism by key shape:
/// a v4 Read-Access-Token (JWT) goes in `Authorization: Bearer`, a v3 key in the
/// `?api_key=` query param. `path_query` is the part after the host with NO auth,
/// e.g. "/3/search/multi?query=batman&page=1". Returns bytes written (0 on fail).
/// Use this (not http.fetch/std.http) for api.themoviedb.org — std.http
/// SEGV-crashes on the TLS reset that SNI-blocked networks return.
pub fn tmdbApiInto(path_query: []const u8, key: []const u8, buf: []u8) usize {
    const v4 = @import("tmdb_pure.zig").keyIsV4(key);

    var url_buf: [768]u8 = undefined;
    const url = if (v4)
        std.fmt.bufPrint(&url_buf, "https://api.themoviedb.org{s}", .{path_query}) catch return 0
    else blk: {
        const sep: u8 = if (std.mem.indexOfScalar(u8, path_query, '?') != null) '&' else '?';
        break :blk std.fmt.bufPrint(&url_buf, "https://api.themoviedb.org{s}{c}api_key={s}", .{ path_query, sep, key }) catch return 0;
    };

    var auth_buf: [320]u8 = undefined;
    const auth: []const u8 = if (v4)
        (std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{key}) catch return 0)
    else
        "";

    // Bounded retry: curlFallbackInto already tries both HTTPS and HTTP, but a
    // single transient blip (DNS hiccup, dropped connection, curl spawn
    // stumble) still made the whole call fail with zero recourse — every
    // caller (seasons, episodes, search, ...) just silently got nothing back.
    // Only worth retrying on the SAME frame's worth of thread — this is
    // always called from a background worker (curl itself already blocks up
    // to 12s/attempt), never the UI thread.
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        const n = curlFallbackInto(url, auth, buf);
        if (n > 0) return n;
        if (attempt < 1) @import("../core/io_global.zig").sleep(250 * std.time.ns_per_ms);
    }
    return 0;
}

/// Fetch one Cinemeta JSON document through the same bounded curl seam used by
/// the keyless catalog. Only the fixed Cinemeta origin is accepted.
pub fn cinemetaApiInto(path: []const u8, buf: []u8) usize {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOf(u8, path, "..") != null) return 0;
    var url_buf: [768]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://v3-cinemeta.strem.io{s}", .{path}) catch return 0;
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        const n = curlFallbackInto(url, "", buf);
        if (n > 0) return n;
        if (attempt < 1) @import("../core/io_global.zig").sleep(250 * std.time.ns_per_ms);
    }
    return 0;
}

fn httpGet(url: []const u8, bearer_token: []const u8) ?[]u8 {
    var auth_buf: [320]u8 = undefined;
    const auth: []const u8 = if (bearer_token.len > 0)
        (std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{bearer_token}) catch return null)
    else
        "";
    // Route through the shared HTTPS→HTTP fallback so the browse tab gets the same
    // JSON validation (rejects ISP block pages) + sticky-flag self-heal.
    // Cinemeta series catalogs include episode summaries and can exceed the
    // old 256 KiB TMDB-page ceiling.
    const buf = alloc.alloc(u8, 1024 * 1024) catch return null;
    defer alloc.free(buf);
    // Bounded retry (3x / 400ms) mirroring tmdbApiInto above: a single cold-start
    // DNS/TLS blip used to permanently fail the one-shot browse/trending fetch
    // (and latch it empty). Always on a detached worker thread (curl blocks), so
    // the backoff never touches the UI thread.
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        const n = curlFallbackInto(url, auth, buf);
        if (n > 0) return alloc.dupe(u8, buf[0..n]) catch null;
        if (attempt < 1) @import("../core/io_global.zig").sleep(250 * std.time.ns_per_ms);
    }
    return null;
}

test "Browse regression busy filter changes are queued and obsolete pages stay unpublished" {
    const t = &state.app.tmdb;
    t.is_loading.store(true, .release);
    defer t.is_loading.store(false, .release);
    defer refresh_queued.store(false, .release);
    t.pending_ready = true;
    defer t.pending_ready = false;
    fetchCurrentView(false);
    try std.testing.expect(refresh_queued.load(.acquire));
    applyPendingResults();
    try std.testing.expect(t.pending_ready);
    try std.testing.expectEqual(@as(usize, 0), t.results.items.len);
    // Finish the old load, then replay the newest (empty) search. No network
    // is needed, and the old page must never become the visible result list.
    const old_view = t.view;
    const old_search = t.search_buf;
    defer t.view = old_view;
    defer t.search_buf = old_search;
    defer {
        t.results.deinit(alloc);
        t.results = .empty;
    }
    t.view = .Search;
    t.search_buf[0] = 0;
    t.is_loading.store(false, .release);
    applyPendingResults();
    try std.testing.expect(!refresh_queued.load(.acquire));
    try std.testing.expect(!t.pending_ready);
    try std.testing.expectEqual(@as(usize, 0), t.results.items.len);
}

test "Browse regression poster completion never writes into a replaced row" {
    const t = &state.app.tmdb;
    defer {
        t.results.deinit(alloc);
        t.results = .empty;
    }
    try t.results.append(alloc, .{ .id = 2, .poster_fetching = true });
    const job = &poster_jobs[0];
    job.active = true;
    job.id = 1; // The old card was replaced before its poster finished.
    job.path_len = 0;
    job.pixels = try std.heap.c_allocator.alloc(u8, 4);
    job.done.store(true, .release);
    drainPosterResults();
    try std.testing.expect(!job.active);
    try std.testing.expect(job.pixels == null);
    try std.testing.expect(t.results.items[0].poster_pixels == null);
    try std.testing.expect(t.results.items[0].poster_fetching);
    // A matching completion is transferred exactly once to the live card.
    job.active = true;
    job.id = 2;
    job.pixels = try std.heap.c_allocator.alloc(u8, 4);
    job.w = 1;
    job.h = 1;
    drainPosterResults();
    try std.testing.expect(!t.results.items[0].poster_fetching);
    try std.testing.expectEqual(@as(usize, 4), t.results.items[0].poster_pixels.?.len);
    std.heap.c_allocator.free(t.results.items[0].poster_pixels.?);
}

test "Browse regression movie and series network waits overlap and retain both catalogs" {
    const Fixture = struct {
        var started: std.atomic.Value(u32) = .init(0);
        var overlapped: std.atomic.Value(bool) = .init(true);
        fn fetch(rows: *std.ArrayListUnmanaged(state.TmdbItem), kind: []const u8, _: FetchMode, _: []const u8, _: state.TmdbCategory, _: usize, _: u32) void {
            _ = started.fetchAdd(1, .acq_rel);
            const clock = @import("../core/io_global.zig");
            const deadline = clock.monotonicMilliTimestamp() + 1000;
            while (started.load(.acquire) < 2) {
                if (clock.monotonicMilliTimestamp() >= deadline) {
                    overlapped.store(false, .release);
                    break;
                }
                clock.sleep(std.time.ns_per_ms);
            }
            rows.append(alloc, .{ .id = if (std.mem.eql(u8, kind, "movie")) 1 else 2 }) catch {};
        }
    };
    var rows: std.ArrayListUnmanaged(state.TmdbItem) = .empty;
    defer rows.deinit(alloc);
    fetchCinemetaIntoUsing(Fixture.fetch, &rows, .browse, "", .trending, .all, 0, 1);
    try std.testing.expect(Fixture.overlapped.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqual(@as(i32, 1), rows.items[0].id);
    try std.testing.expectEqual(@as(i32, 2), rows.items[1].id);
}
