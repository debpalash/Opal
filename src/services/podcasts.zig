//! Podcasts tab — keyless discovery via the iTunes Search API, streamed as
//! audio through mpv. Structurally a sibling of anime.zig: search → show →
//! episode list → play. All parsing lives in podcasts_pure.zig (tested); this
//! module owns async commands and race-free snapshot publication. The desktop
//! presentation lives in ui/podcasts_ui.zig.
//!
//! Flow:
//!   loadPopularOnce() → reliable fetch of Apple's top-shows chart → pure.parseTopChartIds
//!                       → reliable fetch itunes.apple.com/lookup?id=… (same result objects
//!                         as /search) → pure.parseItunes → results[]
//!                       Fires once per session so the page opens populated.
//!   searchPodcasts(q) → reliable fetch itunes.apple.com/search?media=podcast&term=…
//!                       → pure.parseItunes → state.app.podcasts.results[]
//!   loadEpisodes(idx) → reliable fetch of the show's feedUrl (RSS)
//!                       → pure.parseRssEpisodes → state.app.podcasts.episodes[]
//!   playEpisode(idx)  → browser.loadContentDirect(audio enclosure url) → mpv

const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const pure = @import("podcasts_pure.zig");
const reliable_fetch = @import("reliable_fetch.zig");
const io = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const LatestRequest = @import("../core/latest_request.zig").Gate;
const route_resilience = @import("../core/route_resilience_pure.zig");

const alloc = @import("../core/alloc.zig").allocator;

const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

// ── Thread-safety ──
// Detached workers publish into state.app.podcasts.* under `parse_mutex`, and a
// monotonic `search_request` drops stale results so fast re-searches never show
// out-of-order data (mirrors anime.zig). The two `*_loading` flags are atomic
// (read by UI + remote threads, written by workers).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_request: LatestRequest = .{};
var publication_gen: u64 = 0;
var episode_gen: std.atomic.Value(u32) = .init(0);
var episode_failed: std.atomic.Value(bool) = .init(false);
var episode_retry_count: std.atomic.Value(u8) = .init(0);
var episode_retry_at_ms: std.atomic.Value(i64) = .init(0);

/// Immutable reader view shared by desktop and remote presentations. Provider
/// records contain only fixed buffers, so copying under the feature lock severs
/// every pointer/slice relationship with worker-owned publication arrays.
pub const Snapshot = struct {
    generation: u64,
    results: [50]pure.Podcast,
    result_count: usize,
    episodes: [200]pure.Episode,
    episode_count: usize,
    selected_idx: ?usize,
    selected_name: [160]u8,
    selected_name_len: usize,
    fetch_error: bool,
    showing_popular: bool,
    loading: bool,
    episodes_loading: bool,
    episodes_failed: bool,
};

pub fn snapshot() Snapshot {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    return .{
        .generation = publication_gen,
        .results = state.app.podcasts.results,
        .result_count = @min(state.app.podcasts.result_count, state.app.podcasts.results.len),
        .episodes = state.app.podcasts.episodes,
        .episode_count = @min(state.app.podcasts.episode_count, state.app.podcasts.episodes.len),
        .selected_idx = state.app.podcasts.selected_idx,
        .selected_name = state.app.podcasts.selected_name,
        .selected_name_len = @min(state.app.podcasts.selected_name_len, state.app.podcasts.selected_name.len),
        .fetch_error = state.app.podcasts.fetch_error,
        .showing_popular = state.app.podcasts.showing_popular,
        .loading = state.app.podcasts.is_loading.load(.acquire),
        .episodes_loading = state.app.podcasts.episodes_loading.load(.acquire),
        .episodes_failed = episode_failed.load(.acquire),
    };
}

pub fn copyArtwork(idx: usize, out: []u8) usize {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (idx >= state.app.podcasts.result_count) return 0;
    const row = state.app.podcasts.results[idx];
    const n = @min(row.artwork_len, out.len);
    @memcpy(out[0..n], row.artwork[0..n]);
    return n;
}

pub fn closeEpisodes() void {
    _ = episode_gen.fetchAdd(1, .acq_rel);
    episode_failed.store(false, .release);
    episode_retry_count.store(0, .release);
    episode_retry_at_ms.store(0, .release);
    state.app.podcasts.episodes_loading.store(false, .release);
    parse_mutex.lock();
    defer parse_mutex.unlock();
    state.app.podcasts.selected_idx = null;
    state.app.podcasts.episode_count = 0;
    publication_gen +%= 1;
}

const SearchJob = struct {
    generation: u32,
    query: [256]u8,
    query_len: usize,
};

// ══════════════════════════════════════════════════════════
// Encrypted on-disk content cache — Popular-chart stale-while-revalidate.
//
// Mirrors tmdb_api.zig's browse-grid wiring: the fresh popular chart is
// serialized (through the tested content_cache_pure Writer/Reader) and stored to
// disk so the next cold start paints the Popular grid INSTANTLY instead of a
// blank box + spinner. results[] is a FIXED [50]Podcast array and the cover
// pixel/texture state lives in the parallel fixed pod_posters[] (never
// reallocated), so — unlike the TMDB ArrayList — there are no *Item pointers to
// dangle: seeding just fills rows under parse_mutex. Gated on
// content_cache_enabled; TTL reuses the shared browse SWR window.
// ══════════════════════════════════════════════════════════
const content_cache = @import("../core/content_cache.zig");
const ccp = @import("../core/content_cache_pure.zig");
const PODCASTS_CACHE_TTL_S: i64 = @import("browse_cache.zig").TTL_S;
const PODCASTS_CACHE_KEY = "podcasts:popular";
const PODCASTS_BLOB_CAP: usize = 64 * 1024;

fn serializePodcast(w: *ccp.Writer, p: pure.Podcast) void {
    w.blob(p.name[0..@min(p.name_len, p.name.len)]);
    w.blob(p.feed_url[0..@min(p.feed_url_len, p.feed_url.len)]);
    w.blob(p.artwork[0..@min(p.artwork_len, p.artwork.len)]);
    w.blob(p.artist[0..@min(p.artist_len, p.artist.len)]);
}

fn copyField(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

/// Reads one show from `r`; null when the blob is truncated.
fn deserializePodcast(r: *ccp.Reader) ?pure.Podcast {
    var p = pure.Podcast{};
    copyField(&p.name, &p.name_len, r.blob() orelse return null);
    copyField(&p.feed_url, &p.feed_url_len, r.blob() orelse return null);
    copyField(&p.artwork, &p.artwork_len, r.blob() orelse return null);
    copyField(&p.artist, &p.artist_len, r.blob() orelse return null);
    return p;
}

/// SWR write — persist the fresh Popular chart. Called from popularWorker while
/// it already holds parse_mutex, so results[]/result_count are stable.
fn putPopularCache() void {
    if (!state.app.content_cache_enabled) return;
    const count = state.app.podcasts.result_count;
    if (count == 0) return;
    const buf = alloc.alloc(u8, PODCASTS_BLOB_CAP) catch return;
    defer alloc.free(buf);
    var w = ccp.Writer.init(buf);
    const n: u16 = @intCast(@min(count, state.app.podcasts.results.len));
    w.u16v(n);
    var i: usize = 0;
    while (i < n) : (i += 1) serializePodcast(&w, state.app.podcasts.results[i]);
    const blob = w.done() orelse return;
    content_cache.put(PODCASTS_CACHE_KEY, blob, PODCASTS_CACHE_TTL_S);
}

/// SWR read — seed the Popular grid from disk so it paints instantly on cold
/// start. UI-thread only (from loadPopularOnce), and ONLY when results[] is
/// empty. results[] is a fixed array, so no capacity reservation is needed.
fn seedPopularFromCache() void {
    if (!state.app.content_cache_enabled) return;
    if (state.app.podcasts.result_count != 0) return;
    const buf = alloc.alloc(u8, PODCASTS_BLOB_CAP) catch return;
    defer alloc.free(buf);
    const hit = content_cache.get(PODCASTS_CACHE_KEY, buf) orelse return;
    var r = ccp.Reader.init(hit.bytes);
    const n = r.u16v() orelse return;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (state.app.podcasts.result_count != 0) return; // a fetch beat us under the lock
    var i: usize = 0;
    while (i < n and i < state.app.podcasts.results.len) : (i += 1) {
        state.app.podcasts.results[i] = deserializePodcast(&r) orelse break;
    }
    state.app.podcasts.result_count = i;
    if (i > 0) state.app.podcasts.showing_popular = true;
    publication_gen +%= 1;
}

// ══════════════════════════════════════════════════════════
// Popular — Apple top-shows chart → iTunes lookup
//
// So the page opens with content instead of an empty search box. Both hops are
// keyless and go through the SAME curl helper + the SAME pure.parseItunes the
// search path uses (the /lookup endpoint answers with search's result objects),
// so a popular card is byte-for-byte a search card and its click handler is the
// existing loadEpisodes(). One fetch per session, latched by `popular_fetched`.
// ══════════════════════════════════════════════════════════

const POPULAR_LIMIT: usize = 30; // ≤ results[] capacity (50)

/// One-shot latch. renderContent() calls this every frame, so every call after
/// the first is a single atomic load. Atomic (not a plain bool) because
/// searchPodcasts — which also arms it, to keep the chart from landing on top of
/// a user's results — is reachable from the remote-API thread.
var popular_fetched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var feeds_changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn invalidateSourceFeeds() void {
    feeds_changed.store(true, .release);
}

pub fn loadPopularOnce() void {
    const refresh = feeds_changed.load(.acquire) and state.app.podcasts.showing_popular;
    if (!refresh and popular_fetched.load(.acquire)) return;
    // Same first-start gate as the trending/tv-calendar fetches: don't latch
    // until config has published (the poster daemon's disk cache needs the db
    // open, and a cold launch would otherwise burn the one shot on a no-op).
    if (!state.app.config_loaded.load(.acquire)) return;
    // A search already landed (remote API, or a restored session) — leave it be.
    if (!refresh and state.app.podcasts.result_count > 0) {
        popular_fetched.store(true, .release);
        return;
    }
    if (state.app.podcasts.is_loading.load(.acquire)) return;
    feeds_changed.store(false, .release);

    // SWR seed: paint the last Popular chart from disk NOW (empty grid only) so
    // the tab isn't blank while the revalidating fetch below runs.
    seedPopularFromCache();

    popular_fetched.store(true, .release);
    state.app.podcasts.showing_popular = true;
    state.app.podcasts.fetch_error = false;
    // Take a generation like a search does, so a user search fired while the
    // chart is in flight supersedes it instead of racing it into results[].
    const my_gen = search_request.begin(&state.app.podcasts.is_loading);

    workers.spawn(popularWorker, .{my_gen}) catch {
        search_request.finish(my_gen, &state.app.podcasts.is_loading);
    };
}

fn publishShows(generation: u32, rows: []const pure.Podcast, failed: bool) void {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!search_request.isCurrent(generation)) return;
    if (rows.len > 0 or !failed) {
        const n = @min(rows.len, state.app.podcasts.results.len);
        @memcpy(state.app.podcasts.results[0..n], rows[0..n]);
        state.app.podcasts.result_count = n;
        publication_gen +%= 1;
    }
    state.app.podcasts.fetch_error = failed;
    if (state.app.podcasts.showing_popular and rows.len > 0) putPopularCache();
    state.wakeUi();
}

fn popularWorker(my_gen: u32) void {
    defer search_request.finish(my_gen, &state.app.podcasts.is_loading);
    const rows = alloc.alloc(pure.Podcast, 50) catch return;
    defer alloc.free(rows);
    var count: usize = installedFeeds(rows, "", my_gen);
    if (count > 0) publishShows(my_gen, rows[0..count], false);
    const extra = alloc.alloc(pure.Podcast, 30) catch return;
    defer alloc.free(extra);
    // The independent directory paints first; Apple enriches it when available.
    if (fetchBody("https://gpodder.net/toplist/30.json", 512 * 1024)) |body| {
        defer alloc.free(body);
        const found = pure.parseGpodder(alloc, body, extra);
        count = pure.appendUnique(rows, count, extra[0..found]);
        publishShows(my_gen, rows[0..count], false);
    }
    if (!search_request.isCurrent(my_gen)) return;
    const apple_count = fetchApplePopular(extra);
    count = pure.appendUnique(rows, count, extra[0..apple_count]);
    publishShows(my_gen, rows[0..count], count == 0);
}

fn installedFeeds(rows: []pure.Podcast, query: []const u8, gen: u32) usize {
    var count: usize = 0;
    for ([_][]const u8{ "podcast-nasa", "podcast-bbc", "podcast-npr" }) |id| {
        const cfg = @import("../core/source_config.zig");
        if (cfg.get(id, "feed")) |raw| {
            if (!search_request.isCurrent(gen)) return count;
            var url_buf: [512]u8 = undefined;
            if (raw.len > url_buf.len or !pure.isFeedUrl(raw)) continue;
            @memcpy(url_buf[0..raw.len], raw);
            const url = url_buf[0..raw.len];
            const body = fetchBody(url, 3 * 1024 * 1024) orelse continue;
            defer alloc.free(body);
            const show = pure.parseFeedShow(body, url) orelse continue;
            if (query.len > 0) {
                const title = show.name[0..show.name_len];
                var matches = false;
                if (query.len <= title.len) for (0..title.len - query.len + 1) |i| {
                    if (std.ascii.eqlIgnoreCase(title[i..][0..query.len], query)) {
                        matches = true;
                        break;
                    }
                };
                if (!matches) continue;
            }
            count = pure.appendUnique(rows, count, &.{show});
        }
    }
    return count;
}

fn fetchApplePopular(rows: []pure.Podcast) usize {
    var chart_url_buf: [128]u8 = undefined;
    const chart = fetchBody(pure.buildTopChartUrl(POPULAR_LIMIT, &chart_url_buf), 128 * 1024) orelse return 0;
    defer alloc.free(chart);
    var ids_buf: [512]u8 = undefined;
    const ids = pure.parseTopChartIds(chart, &ids_buf);
    if (ids.len == 0) return 0;
    var lookup_url_buf: [640]u8 = undefined;
    const body = fetchBody(pure.buildLookupUrl(ids, &lookup_url_buf), 512 * 1024) orelse return 0;
    defer alloc.free(body);
    return pure.parseItunes(body, rows);
}

// ══════════════════════════════════════════════════════════
// Search — iTunes Search API
// ══════════════════════════════════════════════════════════

pub fn searchPodcasts(query: []const u8) void {
    if (query.len == 0) return;

    state.app.podcasts.fetch_error = false;
    state.app.podcasts.showing_popular = false;
    // A search satisfies the "page opens with content" job — never let the
    // one-shot chart fetch land on top of the user's results afterwards.
    popular_fetched.store(true, .release);
    closeEpisodes();

    const my_gen = search_request.begin(&state.app.podcasts.is_loading);
    var job: SearchJob = .{ .generation = my_gen, .query = undefined, .query_len = @min(query.len, 256) };
    @memcpy(job.query[0..job.query_len], query[0..job.query_len]);

    workers.spawn(searchWorker, .{job}) catch {
        search_request.finish(my_gen, &state.app.podcasts.is_loading);
    };
}

// Both directory searches are bounded snapshots with no offset cursor.
fn searchWorker(job: SearchJob) void {
    defer search_request.finish(job.generation, &state.app.podcasts.is_loading);
    const query = job.query[0..job.query_len];
    if (pure.isFeedUrl(query)) {
        const body = fetchBody(query, PODCAST_FEED_CAP) orelse {
            publishShows(job.generation, &.{}, true);
            return;
        };
        defer alloc.free(body);
        const show = pure.parseFeedShow(body, query) orelse {
            publishShows(job.generation, &.{}, true);
            return;
        };
        publishShows(job.generation, &.{show}, false);
        return;
    }
    var enc: [768]u8 = undefined;
    const encoded = percentEncode(query, &enc);
    var url_buf: [900]u8 = undefined;
    const rows = alloc.alloc(pure.Podcast, 50) catch return;
    defer alloc.free(rows);
    const extra = alloc.alloc(pure.Podcast, 50) catch return;
    defer alloc.free(extra);
    var count: usize = installedFeeds(rows, query, job.generation);
    var succeeded = count > 0;
    const gpodder_url = std.fmt.bufPrint(&url_buf, "https://gpodder.net/search.json?q={s}", .{encoded}) catch return;
    if (fetchBody(gpodder_url, 512 * 1024)) |body| {
        defer alloc.free(body);
        const found = pure.parseGpodder(alloc, body, extra);
        count = pure.appendUnique(rows, count, extra[0..found]);
        succeeded = succeeded or std.mem.startsWith(u8, std.mem.trim(u8, body, " \r\n\t"), "[");
        publishShows(job.generation, rows[0..count], !succeeded);
    }
    if (!search_request.isCurrent(job.generation)) return;
    const url = std.fmt.bufPrint(&url_buf, "https://itunes.apple.com/search?media=podcast&limit=40&term={s}", .{encoded}) catch return;
    if (fetchBody(url, 512 * 1024)) |body| {
        defer alloc.free(body);
        const n = pure.parseItunes(body, extra);
        count = pure.appendUnique(rows, count, extra[0..n]);
        succeeded = succeeded or std.mem.indexOf(u8, body, "\"results\"") != null;
    }
    publishShows(job.generation, rows[0..count], !succeeded);
}

// ══════════════════════════════════════════════════════════
// Episodes — a show's RSS feed
// ══════════════════════════════════════════════════════════

const PODCAST_EPISODE_CACHE_TTL_S: i64 = 6 * 60 * 60;
const PODCAST_FEED_CAP: usize = 4 * 1024 * 1024;

const EpisodeJob = struct {
    generation: u32,
    feed: [300]u8 = undefined,
    feed_len: usize = 0,
};

fn rssBodyValid(body: []const u8) bool {
    return route_resilience.isXmlFeed(body);
}

fn episodeCacheKey(out: []u8, feed: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(out, "podcasts:episodes:v1:{s}", .{feed}) catch null;
}

fn clearEpisodeFailure() void {
    episode_failed.store(false, .release);
    episode_retry_count.store(0, .release);
    episode_retry_at_ms.store(0, .release);
}

fn markEpisodeFailure(generation: u32) void {
    if (episode_gen.load(.acquire) != generation) return;
    const old = episode_retry_count.load(.acquire);
    const attempt = route_resilience.nextAttempt(old);
    episode_retry_count.store(attempt, .release);
    episode_retry_at_ms.store(io.milliTimestamp() + route_resilience.retryDelayMs(attempt), .release);
    episode_failed.store(true, .release);
    state.wakeUi();
}

pub fn loadEpisodes(idx: usize) void {
    startEpisodes(idx, true);
}

fn startEpisodes(idx: usize, reset_retry: bool) void {
    if (state.app.podcasts.episodes_loading.load(.acquire)) return;

    parse_mutex.lock();
    if (idx >= state.app.podcasts.result_count) {
        parse_mutex.unlock();
        return;
    }
    state.app.podcasts.selected_idx = idx;
    if (reset_retry) {
        state.app.podcasts.episode_count = 0;
        state.app.podcasts.fetch_error = false;
        clearEpisodeFailure();
    }
    state.app.podcasts.episodes_loading.store(true, .release);

    // Copy the selected show's name (episode-view header) + feed url for the
    // worker so it never reads results[] as it may be reordered by a new search.
    const p = &state.app.podcasts.results[idx];
    const nlen = @min(p.name_len, state.app.podcasts.selected_name.len);
    @memcpy(state.app.podcasts.selected_name[0..nlen], p.name[0..nlen]);
    state.app.podcasts.selected_name_len = nlen;

    var job = EpisodeJob{ .generation = episode_gen.fetchAdd(1, .acq_rel) +% 1 };
    const flen = @min(p.feed_url_len, job.feed.len);
    @memcpy(job.feed[0..flen], p.feed_url[0..flen]);
    job.feed_len = flen;
    publication_gen +%= 1;
    parse_mutex.unlock();

    workers.spawn(episodeWorker, .{job}) catch {
        state.app.podcasts.episodes_loading.store(false, .release);
        markEpisodeFailure(job.generation);
    };
}

pub fn retryEpisodesIfDue() bool {
    if (!episode_failed.load(.acquire)) return false;
    if (state.app.podcasts.episodes_loading.load(.acquire)) return true;
    if (io.milliTimestamp() < episode_retry_at_ms.load(.acquire)) return true;
    parse_mutex.lock();
    const selected = state.app.podcasts.selected_idx;
    parse_mutex.unlock();
    if (selected) |idx| startEpisodes(idx, false);
    return true;
}

fn episodeWorker(job: EpisodeJob) void {
    defer if (episode_gen.load(.acquire) == job.generation) {
        state.app.podcasts.episodes_loading.store(false, .release);
        state.wakeUi();
    };
    const url = job.feed[0..job.feed_len];
    if (url.len == 0) {
        markEpisodeFailure(job.generation);
        return;
    }

    const cache_buf = alloc.alloc(u8, PODCAST_FEED_CAP) catch {
        markEpisodeFailure(job.generation);
        return;
    };
    defer alloc.free(cache_buf);
    var key_buf: [340]u8 = undefined;
    const cache_key = episodeCacheKey(&key_buf, url);
    if (cache_key) |key| {
        if (content_cache.get(key, cache_buf)) |hit| {
            if (publishEpisodes(job.generation, hit.bytes)) {
                clearEpisodeFailure();
                if (hit.staleness == .fresh) return;
            }
        }
    }

    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const body = fetchBody(url, PODCAST_FEED_CAP) orelse {
            if (attempt < 2) io.sleep((250 + @as(u64, attempt) * 500) * std.time.ns_per_ms);
            continue;
        };
        defer alloc.free(body);
        if (publishEpisodes(job.generation, body)) {
            if (cache_key) |key| content_cache.put(key, body, PODCAST_EPISODE_CACHE_TTL_S);
            clearEpisodeFailure();
            return;
        }
        if (attempt < 2) io.sleep((250 + @as(u64, attempt) * 500) * std.time.ns_per_ms);
    }
    markEpisodeFailure(job.generation);
}

fn publishEpisodes(generation: u32, body: []const u8) bool {
    if (episode_gen.load(.acquire) != generation or !rssBodyValid(body)) return false;
    const parsed = alloc.alloc(pure.Episode, state.app.podcasts.episodes.len) catch return false;
    defer alloc.free(parsed);
    const n = pure.parseRssEpisodes(body, parsed);
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (episode_gen.load(.acquire) != generation or state.app.podcasts.selected_idx == null) return false;
    @memcpy(state.app.podcasts.episodes[0..n], parsed[0..n]);
    state.app.podcasts.episode_count = n;
    publication_gen +%= 1;
    logs.pushLog("info", "podcasts", "Episodes loaded (RSS)", false);
    state.wakeUi();
    return true;
}

// ══════════════════════════════════════════════════════════
// Play — stream the audio enclosure URL through mpv
// ══════════════════════════════════════════════════════════

/// Load episode `idx`'s audio enclosure URL straight into mpv. The URL is a
/// direct audio stream, so loadContentDirect (no content-type routing) is used
/// — creating a player if none exists and revealing the player page.
pub fn playEpisode(idx: usize) void {
    const view = snapshot();
    if (idx >= view.episode_count) return;
    const e = &view.episodes[idx];
    if (e.audio_url_len == 0) return;

    // Snapshot every field into locals BEFORE the play call — a concurrent
    // re-search can reorder/overwrite results[] and episodes[] mid-frame, and
    // the buffers we hand to loadContentDirectMeta must stay valid + stable.
    var url_buf: [512]u8 = undefined;
    const ulen = @min(e.audio_url_len, url_buf.len);
    @memcpy(url_buf[0..ulen], e.audio_url[0..ulen]);

    // Episode title → now-playing title. Show name (selected_name, already a
    // snapshot) → subtitle. Show artwork from the selected result row.
    var title_buf: [200]u8 = undefined;
    const tlen = @min(e.title_len, title_buf.len);
    @memcpy(title_buf[0..tlen], e.title[0..tlen]);

    var name_buf: [160]u8 = undefined;
    const nlen = @min(view.selected_name_len, name_buf.len);
    @memcpy(name_buf[0..nlen], view.selected_name[0..nlen]);

    var art_buf: [300]u8 = undefined;
    var alen: usize = 0;
    if (view.selected_idx) |si| {
        if (si < view.result_count) {
            const show = &view.results[si];
            alen = @min(show.artwork_len, art_buf.len);
            @memcpy(art_buf[0..alen], show.artwork[0..alen]);
        }
    }

    @import("browser.zig").loadContentDirectMeta(url_buf[0..ulen], art_buf[0..alen], title_buf[0..tlen], name_buf[0..nlen]);
    armNowPlaying(url_buf[0..ulen], art_buf[0..alen], name_buf[0..nlen], title_buf[0..tlen]);
    logs.pushLog("info", "podcasts", "Streaming podcast episode", false);
}

// ══════════════════════════════════════════════════════════
// Listening resume (library_items mirror)
// ══════════════════════════════════════════════════════════
//
// The POSITION is already persisted: mpv's frame callback runs
// player.saveCurrentPosition → history.savePlaybackPosition every ~2s, which
// writes `watch_history` keyed by the enclosure URL, and player.tryResumePosition
// seeks back to it on the next load. So an episode already survives a restart.
//
// What was missing is IDENTITY — nothing wrote a `library_items` row, so an
// episode in progress never reached home's Continue rail, and the generic
// playback entry carries no show/episode/artwork. The tick below reads the
// position back out of the authoritative store and mirrors it into a real
// `podcast` row, rather than duplicating a second position store.

/// How often the now-playing mirror touches sqlite. The position it reads is
/// only refreshed every ~2s by the player, so anything tighter is wasted work.
const NP_INTERVAL_MS: i64 = 5000;

/// Remember the episode just handed to mpv so `tickNowPlaying` can mirror it.
/// UI-THREAD ONLY (playEpisode / openDeepLink).
fn armNowPlaying(url: []const u8, art: []const u8, show: []const u8, title: []const u8) void {
    const p = &state.app.podcasts;
    if (url.len == 0 or url.len > p.np_url.len) {
        p.np_active = false;
        return;
    }
    @memcpy(p.np_url[0..url.len], url);
    p.np_url_len = url.len;
    const al = @min(art.len, p.np_art.len);
    @memcpy(p.np_art[0..al], art[0..al]);
    p.np_art_len = al;
    const sl = @min(show.len, p.np_show.len);
    @memcpy(p.np_show[0..sl], show[0..sl]);
    p.np_show_len = sl;
    const tl = @min(title.len, p.np_title.len);
    @memcpy(p.np_title[0..tl], title[0..tl]);
    p.np_title_len = tl;
    p.np_active = true;
    p.np_last_ms = 0; // mirror on the next tick
}

/// Keep the in-progress episode's `library_items` row fresh. UI-THREAD ONLY —
/// called once per frame from appFrame; self-throttled to NP_INTERVAL_MS.
///
/// Disarms as soon as the active player is playing something else, so a movie
/// started after an episode can never write into the podcast's row.
pub fn tickNowPlaying() void {
    const p = &state.app.podcasts;
    if (!p.np_active) return;
    const now = io.milliTimestamp();
    if (now - p.np_last_ms < NP_INTERVAL_MS) return;
    p.np_last_ms = now;

    const url = p.np_url[0..p.np_url_len];
    if (state.app.active_player_idx >= state.app.players.items.len) {
        p.np_active = false;
        return;
    }
    const pl = state.app.players.items[state.app.active_player_idx];
    const cur = pl.current_url[0..@min(pl.current_url_len, pl.current_url.len)];
    if (!std.mem.eql(u8, cur, url)) {
        p.np_active = false;
        return;
    }

    var pos: f64 = 0;
    var dur: f64 = 0;
    if (!@import("../core/db.zig").watchGetProgress(url, &pos, &dur)) return;
    if (pos <= 0) return;

    const show = p.np_show[0..p.np_show_len];
    const title = p.np_title[0..p.np_title_len];
    const art = p.np_art[0..p.np_art_len];
    var link_buf: [1200]u8 = undefined;
    const link = pure.formatDeepLink(&link_buf, url, art, show, title);
    if (link.len == 0) return;
    @import("library_store.zig").upsertProgress(
        "podcast",
        url,
        if (title.len > 0) title else show,
        art,
        pos,
        dur,
        show,
        link,
    );
}

/// Reopen a podcast episode from a home library deep link
/// (`podcast|<url>|<artwork>|<show>|<title>`). Ignores links that aren't ours.
/// Playback resumes because mpv seeks to the stored `watch_history` position for
/// this URL (player.tryResumePosition) — the same path a fresh play takes.
pub fn openDeepLink(link: []const u8) void {
    const l = pure.parseDeepLink(link) orelse return;
    @import("browser.zig").loadContentDirectMeta(l.url, l.artwork, l.title, l.show);
    armNowPlaying(l.url, l.artwork, l.show, l.title);
    logs.pushLog("info", "podcasts", "Resuming podcast episode", false);
}

// ══════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════

/// Percent-encode `src` into `dst` (space, &, =, #, ?, %, + at minimum, plus
/// any non-alphanumeric that isn't URL-safe). Returns the encoded slice.
fn percentEncode(src: []const u8, dst: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var out: usize = 0;
    for (src) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (safe) {
            if (out + 1 > dst.len) break;
            dst[out] = ch;
            out += 1;
        } else {
            if (out + 3 > dst.len) break;
            dst[out] = '%';
            dst[out + 1] = hex[ch >> 4];
            dst[out + 2] = hex[ch & 0xF];
            out += 3;
        }
    }
    return dst[0..out];
}

/// Fetch through the shared status-aware transport into a bounded heap buffer.
/// The transport drains oversized responses, so a large RSS feed cannot wedge
/// the worker while its child process is blocked on a full stdout pipe.
fn fetchBody(url: []const u8, cap: usize) ?[]u8 {
    const buf = alloc.alloc(u8, cap) catch return null;
    const body = reliable_fetch.fetch(url, buf, .{
        .user_agent = agent,
        .timeout_secs = 10,
    }) orelse {
        alloc.free(buf);
        return null;
    };

    return alloc.realloc(buf, body.len) catch {
        alloc.free(buf);
        return null;
    };
}

// Desktop presentation lives in ui/podcasts_ui.zig.
