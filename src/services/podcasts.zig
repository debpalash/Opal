//! Podcasts tab — keyless discovery via the iTunes Search API, streamed as
//! audio through mpv. Structurally a sibling of anime.zig: search → show →
//! episode list → play. All parsing lives in podcasts_pure.zig (tested); this
//! module owns the async fetch workers, thread-safety, and dvui rendering.
//!
//! Flow:
//!   loadPopularOnce() → curl the Apple top-shows chart → pure.parseTopChartIds
//!                       → curl itunes.apple.com/lookup?id=… (same result objects
//!                         as /search) → pure.parseItunes → results[]
//!                       Fires once per session so the page opens populated.
//!   searchPodcasts(q) → curl itunes.apple.com/search?media=podcast&term=…
//!                       → pure.parseItunes → state.app.podcasts.results[]
//!   loadEpisodes(idx) → curl the show's feedUrl (RSS)
//!                       → pure.parseRssEpisodes → state.app.podcasts.episodes[]
//!   playEpisode(idx)  → browser.loadContentDirect(audio enclosure url) → mpv

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const pure = @import("podcasts_pure.zig");
const io = @import("../core/io_global.zig");
const poster = @import("../core/poster.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

const alloc = @import("../core/alloc.zig").allocator;

// ── Desktop cover art ──
// Podcast covers reuse the shared poster daemon (poster.zig: async fetch, the
// global in-flight cap, disk cache, texture upload) — the exact path the
// anime/TMDB grid cards use. The Podcast record lives in podcasts_pure.zig,
// which must stay free of dvui/atomics (std.mem.zeroes), so the GPU texture +
// pixel state lives HERE in a module-static array parallel to
// state.app.podcasts.results[] by index. The array is never reallocated, so the
// raw &slot.* pointers handed to poster.fetchAsync stay valid for the detached
// worker. All slot access is UI-thread only except that worker, which writes
// ONLY its own slot's pixels/w/h/fetching. A slot's url_hash pins it to the
// show currently at that index: when a re-search puts a different show there,
// the hash mismatch frees the old texture/pixels and refetches, so a cover can
// never bleed across searches. pixels are c_alloc'd inside poster.zig (not the
// tracked global allocator), so an un-uploaded cover at shutdown is not a
// leak-report; textures free via textureDestroyLater.
const PodPoster = struct {
    pixels: ?[]u8 = null,
    tex: ?dvui.Texture = null,
    w: u32 = 0,
    h: u32 = 0,
    fetching: bool = false,
    url_hash: u64 = 0,
};
var pod_posters: [50]PodPoster = [_]PodPoster{.{}} ** 50;

const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

// ── Thread-safety ──
// Detached workers publish into state.app.podcasts.* under `parse_mutex`, and a
// monotonic `search_gen` drops stale results so fast re-searches never show
// out-of-order data (mirrors anime.zig). The two `*_loading` flags are atomic
// (read by UI + remote threads, written by workers).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Query snapshot handed to the detached search worker (never read the mutable
// UI search_buf from the thread).
var query_buf: [256]u8 = undefined;
var query_len: usize = 0;

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

pub fn loadPopularOnce() void {
    if (popular_fetched.load(.acquire)) return;
    // Same first-start gate as the trending/tv-calendar fetches: don't latch
    // until config has published (the poster daemon's disk cache needs the db
    // open, and a cold launch would otherwise burn the one shot on a no-op).
    if (!state.app.config_loaded.load(.acquire)) return;
    // A search already landed (remote API, or a restored session) — leave it be.
    if (state.app.podcasts.result_count > 0) {
        popular_fetched.store(true, .release);
        return;
    }
    if (state.app.podcasts.is_loading.load(.acquire)) return;

    // SWR seed: paint the last Popular chart from disk NOW (empty grid only) so
    // the tab isn't blank while the revalidating fetch below runs.
    seedPopularFromCache();

    popular_fetched.store(true, .release);
    state.app.podcasts.showing_popular = true;
    state.app.podcasts.fetch_error = false;
    state.app.podcasts.is_loading.store(true, .release);

    // Take a generation like a search does, so a user search fired while the
    // chart is in flight supersedes it instead of racing it into results[].
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    if (std.Thread.spawn(.{}, popularWorker, .{my_gen})) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.podcasts.is_loading.store(false, .release);
    }
}

fn popularWorker(my_gen: u32) void {
    defer state.app.podcasts.is_loading.store(false, .release);

    // 1. Chart → the top shows' numeric ids (no feedUrl in this payload).
    // Same story as the search endpoint: this is a fixed top-N chart snapshot
    // with no offset/page param, so it's a one-shot bounded fetch too.
    var chart_url_buf: [128]u8 = undefined;
    const chart_url = pure.buildTopChartUrl(POPULAR_LIMIT, &chart_url_buf);
    if (chart_url.len == 0) return;

    const chart = curl(chart_url, 128 * 1024) orelse {
        state.app.podcasts.fetch_error = true;
        return;
    };
    defer alloc.free(chart);
    if (search_gen.load(.acquire) != my_gen) return; // superseded by a search

    var ids_buf: [512]u8 = undefined;
    const ids = pure.parseTopChartIds(chart, &ids_buf);
    if (ids.len == 0) {
        state.app.podcasts.fetch_error = true;
        return;
    }

    // 2. Lookup → the full show records (feedUrl + artwork + publisher).
    var lookup_url_buf: [640]u8 = undefined;
    const lookup_url = pure.buildLookupUrl(ids, &lookup_url_buf);
    if (lookup_url.len == 0) return;

    const body = curl(lookup_url, 512 * 1024) orelse {
        state.app.podcasts.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (search_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return; // re-check under lock

    const count = pure.parseItunes(body, &state.app.podcasts.results);
    state.app.podcasts.result_count = count;
    if (count == 0) {
        state.app.podcasts.fetch_error = true;
        logs.pushLog("info", "podcasts", "Top shows returned no rows", false);
    } else {
        // SWR write: persist the fresh chart (still under parse_mutex) so the
        // next cold start seeds instantly.
        putPopularCache();
        logs.pushLog("info", "podcasts", "Popular podcasts loaded (Apple top shows)", false);
    }
}

// ══════════════════════════════════════════════════════════
// Search — iTunes Search API
// ══════════════════════════════════════════════════════════

pub fn searchPodcasts(query: []const u8) void {
    if (query.len == 0) return;

    state.app.podcasts.is_loading.store(true, .release);
    state.app.podcasts.fetch_error = false;
    state.app.podcasts.showing_popular = false;
    // A search satisfies the "page opens with content" job — never let the
    // one-shot chart fetch land on top of the user's results afterwards.
    popular_fetched.store(true, .release);
    state.app.podcasts.selected_idx = null;
    state.app.podcasts.episode_count = 0;

    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    const n = @min(query.len, query_buf.len);
    @memcpy(query_buf[0..n], query[0..n]);
    query_len = n;

    if (std.Thread.spawn(.{}, searchWorker, .{my_gen})) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.podcasts.is_loading.store(false, .release);
    }
}

fn searchWorker(my_gen: u32) void {
    defer state.app.podcasts.is_loading.store(false, .release);

    // Snapshot the query — a newer search may overwrite query_buf mid-flight.
    var local: [256]u8 = undefined;
    const qlen = @min(query_len, local.len);
    @memcpy(local[0..qlen], query_buf[0..qlen]);

    // Percent-encode the term (space, &, =, #, ?, %, + at minimum).
    var enc: [768]u8 = undefined;
    const encoded = percentEncode(local[0..qlen], &enc);

    // No infinite scroll here: the classic iTunes Search API takes a `limit`
    // (max 200) but has no offset/page cursor — it always returns the same
    // single bounded result set, so a "load more" would just refetch page one.
    var url_buf: [900]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://itunes.apple.com/search?media=podcast&limit=40&term={s}",
        .{encoded},
    ) catch return;

    const body = curl(url, 256 * 1024) orelse {
        state.app.podcasts.fetch_error = true;
        return;
    };
    defer alloc.free(body);

    // Bail if superseded while curl was in flight.
    if (search_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return; // re-check under lock

    const count = pure.parseItunes(body, &state.app.podcasts.results);
    state.app.podcasts.result_count = count;
    if (count == 0) logs.pushLog("info", "podcasts", "Search returned no shows", false) else logs.pushLog("info", "podcasts", "Podcast search done (iTunes)", false);
}

// ══════════════════════════════════════════════════════════
// Episodes — a show's RSS feed
// ══════════════════════════════════════════════════════════

pub fn loadEpisodes(idx: usize) void {
    if (idx >= state.app.podcasts.result_count) return;
    if (state.app.podcasts.episodes_loading.load(.acquire)) return;

    state.app.podcasts.selected_idx = idx;
    state.app.podcasts.episode_count = 0;
    state.app.podcasts.fetch_error = false;
    state.app.podcasts.episodes_loading.store(true, .release);

    // Copy the selected show's name (episode-view header) + feed url for the
    // worker so it never reads results[] as it may be reordered by a new search.
    const p = &state.app.podcasts.results[idx];
    const nlen = @min(p.name_len, state.app.podcasts.selected_name.len);
    @memcpy(state.app.podcasts.selected_name[0..nlen], p.name[0..nlen]);
    state.app.podcasts.selected_name_len = nlen;

    const S = struct {
        var feed: [300]u8 = undefined;
        var feed_len: usize = 0;
        fn worker() void {
            defer state.app.podcasts.episodes_loading.store(false, .release);
            const url = @This().feed[0..@This().feed_len];
            if (url.len == 0) return;
            // 4 MB, not 1 MB: episodes[] holds 200, and a long-running show's feed
            // is huge (6.9 MB / 583 items for Raj Shamani). At 1 MB the parser only
            // ever saw the newest 61 — the array was two-thirds empty by design.
            const body = curl(url, 4 * 1024 * 1024) orelse {
                state.app.podcasts.fetch_error = true;
                return;
            };
            defer alloc.free(body);
            parse_mutex.lock();
            defer parse_mutex.unlock();
            const n = pure.parseRssEpisodes(body, &state.app.podcasts.episodes);
            state.app.podcasts.episode_count = n;
            logs.pushLog("info", "podcasts", "Episodes loaded (RSS)", false);
        }
    };
    const flen = @min(p.feed_url_len, S.feed.len);
    @memcpy(S.feed[0..flen], p.feed_url[0..flen]);
    S.feed_len = flen;

    if (std.Thread.spawn(.{}, S.worker, .{})) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.podcasts.episodes_loading.store(false, .release);
    }
}

// ══════════════════════════════════════════════════════════
// Play — stream the audio enclosure URL through mpv
// ══════════════════════════════════════════════════════════

/// Load episode `idx`'s audio enclosure URL straight into mpv. The URL is a
/// direct audio stream, so loadContentDirect (no content-type routing) is used
/// — creating a player if none exists and revealing the player page.
pub fn playEpisode(idx: usize) void {
    if (idx >= state.app.podcasts.episode_count) return;
    const e = &state.app.podcasts.episodes[idx];
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
    const nlen = @min(state.app.podcasts.selected_name_len, name_buf.len);
    @memcpy(name_buf[0..nlen], state.app.podcasts.selected_name[0..nlen]);

    var art_buf: [300]u8 = undefined;
    var alen: usize = 0;
    if (state.app.podcasts.selected_idx) |si| {
        if (si < state.app.podcasts.result_count) {
            const show = &state.app.podcasts.results[si];
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

/// Fetch `url` with curl into a fresh heap buffer of `cap` bytes. Returns the
/// filled slice (caller frees) or null on failure/empty. Large buffers stay off
/// the worker stack (macOS 512KB limit).
fn curl(url: []const u8, cap: usize) ?[]u8 {
    const argv = [_][]const u8{ "curl", "-sL", "--connect-timeout", "3", "-A", agent, "--max-time", "10", url };
    var child = io.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return null;

    const buf = alloc.alloc(u8, cap) catch {
        _ = child.wait() catch {};
        return null;
    };
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;

    // Drain whatever curl still has queued, or wait() below never returns.
    //
    // readAll() stops the instant `buf` is full and leaves the rest sitting in the
    // pipe. curl keeps writing, the pipe fills, and curl blocks inside write(2) —
    // where it can no longer reach its own transfer loop, so `--max-time 15` never
    // fires. wait() then blocks forever on a process that can never exit.
    //
    // Raj Shamani's Figuring Out is a 6.9 MB feed against a 1 MB cap: the worker
    // thread hung permanently on "Loading…", and because loadEpisodes() early-
    // returns while episodes_loading is set, EVERY later podcast click was a
    // silent no-op for the rest of the session.
    if (n == buf.len) {
        if (child.stdout) |*so| {
            var sink: [64 * 1024]u8 = undefined;
            while ((io.read(so, &sink) catch 0) > 0) {}
        }
    }

    _ = child.wait() catch {};
    if (n == 0) {
        alloc.free(buf);
        return null;
    }

    // Shrink to what was actually read. The caller frees what we hand back, and
    // the global DebugAllocator checks the free size against the allocation size
    // — returning `buf[0..n]` out of a `cap`-sized allocation is an INVALID FREE
    // and aborts the process (it did: 49584 freed against 524288 allocated).
    return alloc.realloc(buf, n) catch {
        alloc.free(buf);
        return null;
    };
}

// ══════════════════════════════════════════════════════════
// UI (Drawer / Browse › Podcasts)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    // Populate the page on first open (no-op after the first fetch).
    loadPopularOnce();

    renderSearchBar();

    if (state.app.podcasts.fetch_error) {
        _ = dvui.label(@src(), "Failed to fetch — check your connection", .{}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    if (state.app.podcasts.selected_idx == null) {
        renderResults();
    } else {
        renderEpisodes();
    }
}

fn renderSearchBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer row.deinit();

    _ = dvui.icon(@src(), "", icons.tvg.lucide.podcast, .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.podcasts.search_buf },
        .placeholder = "Search podcasts…",
    }, .{
        .expand = .horizontal,
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .gravity_y = 0.5,
    });
    const entered = te.enter_pressed;
    te.deinit();

    const go = dvui.button(@src(), "Go", .{}, .{
        .color_fill = theme.colors.accent,
        .color_text = dvui.Color.white,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
    });

    if (entered or go) {
        const q = std.mem.sliceTo(&state.app.podcasts.search_buf, 0);
        if (q.len > 0) searchPodcasts(q);
    }

    if (state.app.podcasts.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
    }
}

// ── Card grid ──
// Popular shows and search results are the SAME record (parseItunes fills both),
// so they render through one grid: square cover + title + publisher, click →
// loadEpisodes(i), exactly as the old "Episodes" row button did.
const CARD_GAP: f32 = 6;
const CARD_TARGET_W: f32 = 170; // desired card width; columns derive from it
const CARD_FOOTER_H: f32 = 46; // title + publisher lines under the cover

/// Fill the card's cover area with the show's artwork, reusing the shared poster
/// daemon. Falls back to the podcast glyph while loading, when the show has no
/// artwork URL, or when the image can't be decoded. UI-thread only.
fn renderCover(i: usize, p: *const pure.Podcast) void {
    const slot = &pod_posters[i];
    const art = p.artwork[0..p.artwork_len];

    if (art.len > 0) {
        // Pin the slot to whatever show is at index i now — a re-search (or the
        // popular chart landing) can replace results[], so a URL-hash change
        // means "different show here": free the stale texture/pixels and
        // refetch. Only when not mid-fetch, so we never spawn a second worker
        // onto the same slot.
        const h = std.hash.Fnv1a_64.hash(art);
        if (slot.url_hash != h and !slot.fetching) {
            poster.deinitPoster(&slot.pixels, &slot.tex);
            slot.w = 0;
            slot.h = 0;
            slot.url_hash = h;
        }
        _ = poster.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.tex);
        if (slot.tex == null and !slot.fetching and slot.pixels == null)
            poster.fetchAsync(art, &slot.pixels, &slot.w, &slot.h, &slot.fetching);
    }

    if (slot.tex) |*tex| {
        _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
            .id_extra = i + 1000,
            .expand = .both,
            .corner_radius = dvui.Rect.all(8),
        });
    } else {
        _ = dvui.icon(@src(), "", icons.tvg.lucide.podcast, .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });
    }
}

/// One show card: square cover (clickable) + title + publisher subtitle.
fn renderCard(i: usize, card_w: f32) void {
    const p = &state.app.podcasts.results[i];

    // Validate STABLE COPIES: a fetch worker can rewrite results[i] mid-frame
    // and dvui panics on invalid UTF-8 it reads after we validated.
    var name_buf: [160]u8 = undefined;
    const name = safeUtf8Buf(p.name[0..@min(p.name_len, p.name.len)], &name_buf);
    var artist_buf: [96]u8 = undefined;
    const artist = safeUtf8Buf(p.artist[0..@min(p.artist_len, p.artist.len)], &artist_buf);

    // min == max height → every card (and thus every row) has a uniform pitch.
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i,
        .min_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .margin = dvui.Rect.all(CARD_GAP),
    });
    defer card.deinit();

    // Cover art hosted INSIDE a single button widget — one clickable rectangle
    // per card (a sibling button + box would draw two).
    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = i + 2000,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(8),
            .min_size_content = .{ .w = card_w, .h = card_w },
            .max_size_content = .{ .w = card_w, .h = card_w },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();

        renderCover(i, p);

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        // Same click target as the old row's "Episodes" button.
        if (clicked) loadEpisodes(i);
    }

    _ = dvui.label(@src(), "{s}", .{name}, .{
        .id_extra = i + 3000,
        .color_text = theme.colors.text_primary,
        .expand = .horizontal,
        .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
    });

    if (artist.len > 0) {
        _ = dvui.label(@src(), "{s}", .{artist}, .{
            .id_extra = i + 4000,
            .color_text = theme.colors.text_tertiary,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
    }
}

fn renderResults() void {
    const count = @min(state.app.podcasts.result_count, state.app.podcasts.results.len);
    if (count == 0) {
        if (!state.app.podcasts.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Search for a show to get started", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        } else {
            _ = dvui.label(@src(), "Loading popular shows…", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        }
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    _ = dvui.label(@src(), "{s}", .{
        if (state.app.podcasts.showing_popular) "Popular now" else "Results",
    }, .{
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 2 },
    });

    // Responsive columns from the LIVE page width (one-frame lag; first paint
    // falls back to a sane default) — same shape as the TMDB gallery. No
    // virtualization: the grid is capped at results[]'s 50 cards.
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / CARD_TARGET_W)));
    const cols_f: f32 = @floatFromInt(cols);
    const card_w: f32 = @max(100, (avail_w - cols_f * 2 * CARD_GAP) / cols_f);

    var r: usize = 0;
    while (r * cols < count) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = r + 50000,
            .expand = .horizontal,
        });
        defer row.deinit();

        var c: usize = 0;
        while (c < cols and r * cols + c < count) : (c += 1) renderCard(r * cols + c, card_w);
    }
}

fn renderEpisodes() void {
    // Header: back button + show title.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer hdr.deinit();

        if (dvui.buttonIcon(@src(), "Back", icons.tvg.lucide.@"arrow-left", .{}, .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        })) {
            state.app.podcasts.selected_idx = null;
            state.app.podcasts.episode_count = 0;
            return;
        }

        var title_buf: [160]u8 = undefined;
        const title = safeUtf8Buf(
            state.app.podcasts.selected_name[0..state.app.podcasts.selected_name_len],
            &title_buf,
        );
        _ = dvui.label(@src(), "{s}", .{title}, .{
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        if (state.app.podcasts.episodes_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Loading…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
        }
    }

    if (state.app.podcasts.episode_count == 0) {
        if (!state.app.podcasts.episodes_loading.load(.acquire)) {
            _ = dvui.label(@src(), "No episodes found", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        }
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    for (0..state.app.podcasts.episode_count) |i| {
        const e = &state.app.podcasts.episodes[i];
        var title_buf: [200]u8 = undefined;
        const title = safeUtf8Buf(e.title[0..e.title_len], &title_buf);

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
        });
        defer row.deinit();

        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = i + 3000,
                .expand = .horizontal,
            });
            defer col.deinit();

            _ = dvui.label(@src(), "{s}", .{title}, .{
                .id_extra = i + 4000,
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
            });

            // Meta: date · duration.
            if (e.date_len > 0 or e.duration_len > 0) {
                var meta_buf: [64]u8 = undefined;
                var mw = std.Io.Writer.fixed(&meta_buf);
                if (e.date_len > 0) mw.writeAll(e.date[0..@min(e.date_len, 32)]) catch {};
                if (e.date_len > 0 and e.duration_len > 0) mw.writeAll("  ·  ") catch {};
                if (e.duration_len > 0) mw.writeAll(e.duration[0..e.duration_len]) catch {};
                var safe_meta: [64]u8 = undefined;
                _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(meta_buf[0..mw.end], &safe_meta)}, .{
                    .id_extra = i + 5000,
                    .color_text = theme.colors.text_tertiary,
                    .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                });
            }
        }

        if (dvui.buttonIcon(@src(), "Play", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = i + 6000,
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .gravity_y = 0.5,
        })) {
            playEpisode(i);
        }
    }
}
