//! Internet Radio tab — keyless station discovery via the RadioBrowser API,
//! streamed straight through mpv. Structurally a sibling of podcasts.zig, one
//! level shallower: search → station list → play. All parsing lives in
//! radio_pure.zig (tested); this module owns the async fetch worker,
//! thread-safety, and dvui rendering.
//!
//! Flow:
//!   loadPopularOnce() → reliable fetch …/json/stations/search?order=votes&reverse=true
//!                     (the same host's keyless votes-descending window,
//!                     answering with the same station objects) →
//!                     pure.parseStations → results[]. Fires once per session
//!                     so the page opens populated.
//!   searchRadio(q)  → reliable fetch all.api.radio-browser.info/json/stations/search?name=…
//!                     → pure.parseStations → state.app.radio.results[]
//!   playStation(i)  → browser.loadContentDirect(url_resolved | url) → mpv,
//!                     then a best-effort click-count ping to /json/url/{uuid}.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const logs = @import("../core/logs.zig");
const pure = @import("radio_pure.zig");
/// App-wide stream-health probing (shared with Live TV) — the "radio" kind.
const link_health = @import("link_health.zig");
const RADIO_KIND = "radio";
const reliable_fetch = @import("reliable_fetch.zig");
const poster = @import("../core/poster.zig");
const rate_limit = @import("../core/rate_limit.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;
const LatestRequest = @import("../core/latest_request.zig").Gate;
const tmdb_pure = @import("tmdb_pure.zig");

var loading_fixture_for_test = false;
pub fn setLoadingFixtureForTest(enabled: bool) void {
    if (!@import("builtin").is_test) @compileError("Native loading fixture is test-only");
    loading_fixture_for_test = enabled;
    state.app.radio.result_count = 0;
    state.app.radio.fetch_error = false;
    state.app.radio.is_loading.store(enabled, .release);
}

const alloc = @import("../core/alloc.zig").allocator;

const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

// ── Station artwork ──
// Station favicons reuse the shared poster daemon (poster.zig: async fetch, the
// global in-flight cap, disk cache, texture upload) — the exact path podcast
// covers take. The Station record lives in radio_pure.zig, which must stay free
// of dvui/atomics (std.mem.zeroes), so the GPU texture + pixel state lives HERE
// in a module-static array parallel to state.app.radio.results[] by index. The
// array is never reallocated, so the raw &slot.* pointers handed to
// poster.fetchAsync stay valid for the detached worker. All slot access is
// UI-thread only except that worker, which writes ONLY its own slot's
// pixels/w/h/fetching. A slot's url_hash pins it to the station currently at
// that index: when a re-search puts a different station there, the hash mismatch
// frees the old texture/pixels and refetches, so a logo can never bleed across
// searches. pixels are c_alloc'd inside poster.zig (NOT the tracked global
// allocator) — never free them with `alloc`; deinitPoster/uploadIfReady use the
// matching allocator.
const StationPoster = struct {
    pixels: ?[]u8 = null,
    tex: ?dvui.Texture = null,
    w: u32 = 0,
    h: u32 = 0,
    fetching: bool = false,
    attempted: bool = false,
    failed: bool = false,
    url_hash: u64 = 0,
};
// Sized to match state.app.radio.results[]'s capacity (180) — infinite scroll
// appends past the first 30-station window, and every appended row needs a
// slot here too or renderCard's station_posters[i] indexes out of bounds.
var station_posters: [180]StationPoster = [_]StationPoster{.{}} ** 180;

// ── Thread-safety ──
// The detached search worker publishes into state.app.radio.* under
// `parse_mutex`, and a monotonic `search_request` drops stale results so fast
// re-searches never show out-of-order data (mirrors podcasts.zig / anime.zig).
// The `is_loading` flag is atomic (read by UI + remote threads, written by the
// worker).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_request: LatestRequest = .{};

// Query snapshot handed to the detached search worker (never read the mutable
// UI search_buf from the thread).
var query_buf: [256]u8 = undefined;
var query_len: usize = 0;

const SearchJob = struct {
    generation: u32,
    query: [256]u8 = undefined,
    query_len: usize = 0,
};

// ══════════════════════════════════════════════════════════
// Encrypted on-disk content cache — most-voted stations SWR (mirrors
// podcasts.zig / tmdb_api.zig). Serialize the fresh popular list through the
// tested content_cache_pure Writer/Reader and persist it, so the next cold start
// paints the grid INSTANTLY instead of a blank box + spinner. results[] is a
// FIXED [180]Station array with cover state in the parallel fixed station_posters[]
// (never reallocated) — no *Item pointers to dangle, so seeding just fills rows
// under parse_mutex. Only the first fetched window is ever persisted (infinite
// scroll's appended pages are not written back), so RADIO_BLOB_CAP only needs to
// cover one window's worth of stations. Gated on content_cache_enabled; TTL is
// the shared SWR window.
// ══════════════════════════════════════════════════════════
const content_cache = @import("../core/content_cache.zig");
const ccp = @import("../core/content_cache_pure.zig");
const RADIO_CACHE_TTL_S: i64 = @import("browse_cache.zig").TTL_S;
const RADIO_CACHE_KEY = "radio:popular";
const RADIO_BLOB_CAP: usize = 64 * 1024;

fn serializeStation(w: *ccp.Writer, s: pure.Station) void {
    w.blob(s.stationuuid[0..@min(s.stationuuid_len, s.stationuuid.len)]);
    w.blob(s.name[0..@min(s.name_len, s.name.len)]);
    w.blob(s.url_resolved[0..@min(s.url_resolved_len, s.url_resolved.len)]);
    w.blob(s.url[0..@min(s.url_len, s.url.len)]);
    w.blob(s.favicon[0..@min(s.favicon_len, s.favicon.len)]);
    w.blob(s.tags[0..@min(s.tags_len, s.tags.len)]);
    w.blob(s.country[0..@min(s.country_len, s.country.len)]);
    w.blob(s.codec[0..@min(s.codec_len, s.codec.len)]);
    w.u32v(s.votes);
    w.u32v(s.bitrate);
}

fn copyField(dst: []u8, len: *usize, src: []const u8) void {
    @import("../core/text.zig").setFixedUtf8(dst, len, src);
}

pub fn resultCount() usize {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    return @min(state.app.radio.result_count, state.app.radio.results.len);
}

pub fn resultRow(idx: usize) ?pure.Station {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (idx >= state.app.radio.result_count or idx >= state.app.radio.results.len) return null;
    return state.app.radio.results[idx];
}

pub const RESULT_CAPACITY: usize = @typeInfo(@TypeOf(state.app.radio.results)).array.len;
pub const CatalogSnapshot = struct {
    count: usize,
    loading: bool,
    loading_more: bool,
    has_more: bool,
    fetch_error: bool,
};
/// Caller-owned heap storage, copied once under the publication lock.
pub fn copyCatalogSnapshot(out: []pure.Station) CatalogSnapshot {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    const available = @min(state.app.radio.result_count, RESULT_CAPACITY);
    const count = @min(available, out.len);
    @memcpy(out[0..count], state.app.radio.results[0..count]);
    return .{
        .count = count,
        .loading = state.app.radio.is_loading.load(.acquire),
        .loading_more = loading_more.load(.acquire),
        .has_more = more_available and available < RESULT_CAPACITY,
        .fetch_error = state.app.radio.fetch_error,
    };
}

/// Reads one station from `r`; null when the blob is truncated.
fn deserializeStation(r: *ccp.Reader) ?pure.Station {
    var s = pure.Station{};
    copyField(&s.stationuuid, &s.stationuuid_len, r.blob() orelse return null);
    copyField(&s.name, &s.name_len, r.blob() orelse return null);
    copyField(&s.url_resolved, &s.url_resolved_len, r.blob() orelse return null);
    copyField(&s.url, &s.url_len, r.blob() orelse return null);
    copyField(&s.favicon, &s.favicon_len, r.blob() orelse return null);
    copyField(&s.tags, &s.tags_len, r.blob() orelse return null);
    copyField(&s.country, &s.country_len, r.blob() orelse return null);
    copyField(&s.codec, &s.codec_len, r.blob() orelse return null);
    s.votes = r.u32v() orelse return null;
    s.bitrate = r.u32v() orelse return null;
    return s;
}

/// SWR write — persist the fresh most-voted list. Called from popularWorker
/// Takes a short owned snapshot; writes disk after releasing parse_mutex.
fn putPopularCache(generation: u32) void {
    if (!state.app.content_cache_enabled) return;
    const buffer = alloc.alloc(u8, RADIO_BLOB_CAP) catch return;
    defer alloc.free(buffer);
    var writer = ccp.Writer.init(buffer);
    {
        parse_mutex.lock();
        defer parse_mutex.unlock();
        if (!search_request.isCurrent(generation) or !state.app.radio.showing_popular or state.app.radio.result_count == 0) return;
        const count: u16 = @intCast(@min(state.app.radio.result_count, state.app.radio.results.len));
        writer.u16v(count);
        for (state.app.radio.results[0..count]) |row| serializeStation(&writer, row);
    }
    const blob = writer.done() orelse return;
    content_cache.put(RADIO_CACHE_KEY, blob, RADIO_CACHE_TTL_S);
}

/// SWR read — seed the popular grid from disk so it paints instantly on cold
/// start. Popular worker only (from popularWorker), ONLY when results[] is empty.
/// results[] is a fixed array, so no capacity reservation is needed.
fn seedPopularFromCache(generation: u32) void {
    if (!state.app.content_cache_enabled) return;
    const buf = alloc.alloc(u8, RADIO_BLOB_CAP) catch return;
    defer alloc.free(buf);
    const hit = content_cache.get(RADIO_CACHE_KEY, buf) orelse return;
    var r = ccp.Reader.init(hit.bytes);
    const n = r.u16v() orelse return;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!search_request.isCurrent(generation) or state.app.radio.result_count != 0) return; // a fetch beat us under the lock
    var i: usize = 0;
    while (i < n and i < state.app.radio.results.len) : (i += 1) {
        state.app.radio.results[i] = deserializeStation(&r) orelse break;
    }
    state.app.radio.result_count = i;
    if (i > 0) {
        state.app.radio.showing_popular = true;
        state.wakeUi();
    }
}

// ══════════════════════════════════════════════════════════
// Popular — RadioBrowser most-voted stations
//
// So the page opens with content instead of an empty search box. /topvote/N is
// the same keyless host as the search endpoint and answers with the identical
// station objects, so it goes through the SAME curl helper and the SAME
// pure.parseStations — a popular card is byte-for-byte a search card and its
// click handler is the existing playStation(). One fetch per session.
// ══════════════════════════════════════════════════════════

// Per-fetch station window — used for the initial popular/search fetch AND
// every infinite-scroll append (results[]'s real capacity is 180; this is just
// how many rows one request pulls, mirrored by RADIO_PAGE_SIZE below).
const POPULAR_LIMIT: usize = 30;

// ── Infinite-scroll pagination ──
// `current_offset` is the next provider offset, independent of filtered or
// duplicate station rows in the displayed results. `more_available` clears when a window comes
// back shorter than RADIO_PAGE_SIZE or the fixed results[] buffer fills.
// `loading_more` serializes append fetches so a single near-bottom scroll
// can't spawn a burst (mirrors comics/drama/youtube). All three are read on
// the UI thread; the append worker runs under the same `search_request` guard
// searchWorker/popularWorker already use, so a fresh search/popular reload
// drops a stale append instead of racing it into results[].
var current_offset: usize = 0;
var more_available: bool = true;
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Same window size for the initial fetch and every append — radio-browser's
/// `/stations/search` endpoint (used by both buildPopularUrl and
/// buildSearchUrl) answers `limit`+`offset`; a window shorter than this means
/// there's nothing left to page.
const RADIO_PAGE_SIZE: usize = POPULAR_LIMIT;

/// One-shot latch. renderContent() calls this every frame, so every call after
/// the first is a single atomic load. Atomic (not a plain bool) because
/// searchRadio — which also arms it, so the chart can't land on top of a user's
/// results — is reachable from the remote-API thread.
var popular_fetched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn loadPopularOnce() void {
    if (@import("builtin").is_test and loading_fixture_for_test) return;
    if (popular_fetched.load(.acquire)) return;
    // Same first-start gate as the other one-shot loaders: don't latch until
    // config has published (the poster daemon's disk cache needs the db open).
    if (!state.app.config_loaded.load(.acquire)) return;
    // A search already landed (remote API) — leave it be.
    if (state.app.radio.result_count > 0) {
        popular_fetched.store(true, .release);
        return;
    }
    if (state.app.radio.is_loading.load(.acquire)) return;

    // The worker seeds cached rows before its independent directory requests.

    parse_mutex.lock();
    if (state.app.radio.is_loading.load(.acquire) or popular_fetched.load(.acquire)) {
        parse_mutex.unlock();
        return;
    }
    popular_fetched.store(true, .release);
    state.app.radio.showing_popular = true;
    state.app.radio.fetch_error = false;
    // Fresh popular session — infinite scroll starts over (any pagination
    // state left over from a prior search/popular load is stale).
    current_offset = 0;
    more_available = true;

    // Take a generation like a search does, so a user search fired while the
    // popular fetch is in flight supersedes it instead of racing it into
    // results[].
    const my_gen = search_request.begin(&state.app.radio.is_loading);
    parse_mutex.unlock();

    if (@import("../core/workers.zig").spawnLegacy(popularWorker, .{my_gen})) |t| {
        @import("../core/workers.zig").release(t); // never joined — detach to avoid leaking the handle
    } else |_| {
        search_request.finish(my_gen, &state.app.radio.is_loading);
    }
}

fn popularWorker(my_gen: u32) void {
    seedPopularFromCache(my_gen);
    runRadioGroup(.{ .generation = my_gen, .query_len = 0 }, true);
}

const RadioGroup = struct {
    job: SearchJob,
    popular: bool,
    published: bool = false,
    succeeded: bool = false,
    directory_succeeded: bool = false,
};
fn runRadioGroup(job: SearchJob, popular: bool) void {
    var group: RadioGroup = .{ .job = job, .popular = popular };
    const jobs = [_]bool{ false, true };
    @import("browse_fanout.zig").run(bool, &jobs, &group, radioPartWorker, .{
        .limit = 2,
        .cancel_epoch = .{ .epoch32 = .{ .value = &search_request.generation, .expected = job.generation } },
    });
    var cache = false;
    parse_mutex.lock();
    if (search_request.isCurrent(job.generation)) {
        if (!group.published and group.succeeded) state.app.radio.result_count = 0;
        state.app.radio.fetch_error = !group.succeeded;
        if (!group.directory_succeeded) more_available = false;
        search_request.finish(job.generation, &state.app.radio.is_loading);
        cache = popular and group.published;
    }
    parse_mutex.unlock();
    if (cache) putPopularCache(job.generation);
    state.wakeUi();
}
fn radioPartWorker(group: *RadioGroup, soma: bool) void {
    if (soma) {
        appendSoma(group);
        return;
    }
    const generation = group.job.generation;
    var enc: [768]u8 = undefined;
    var url_buf: [1024]u8 = undefined;
    const url = if (group.popular) pure.buildPopularUrl(RADIO_PAGE_SIZE, 0, &url_buf) else pure.buildSearchUrl(percentEncode(group.job.query[0..group.job.query_len], &enc), RADIO_PAGE_SIZE, 0, &url_buf);
    if (url.len == 0) return;
    rate_limit.acquire("radiobrowser", 1.0);
    const body = fetchBodyForGeneration(url, 512 * 1024, generation) orelse return;
    defer alloc.free(body);
    const rows = alloc.alloc(pure.Station, RADIO_PAGE_SIZE) catch return;
    defer alloc.free(rows);
    const page = pure.parsePage(alloc, body, rows) orelse return;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!search_request.isCurrent(generation)) return;
    group.succeeded = true;
    group.directory_succeeded = true;
    more_available = page.consumed >= RADIO_PAGE_SIZE;
    current_offset = page.consumed;
    if (page.count > 0) {
        if (!group.published) state.app.radio.result_count = 0;
        group.published = true;
        state.app.radio.result_count = pure.appendUnique(&state.app.radio.results, state.app.radio.result_count, rows[0..page.count]);
        state.app.radio.fetch_error = false;
        state.wakeUi();
    }
}

// ══════════════════════════════════════════════════════════
// Search — RadioBrowser station search
// ══════════════════════════════════════════════════════════

pub fn searchRadio(query: []const u8) void {
    if (@import("builtin").is_test and loading_fixture_for_test) return;
    if (query.len == 0) return;

    parse_mutex.lock();
    state.app.radio.fetch_error = false;
    state.app.radio.showing_popular = false;
    // A search satisfies the "page opens with content" job — never let the
    // one-shot popular fetch land on top of the user's results afterwards.
    popular_fetched.store(true, .release);
    // Fresh search — infinite scroll starts over.
    current_offset = 0;
    more_available = true;

    const my_gen = search_request.begin(&state.app.radio.is_loading);

    // Keep the query for pagination and hand this worker an immutable copy.
    const n = @min(query.len, query_buf.len);
    @memcpy(query_buf[0..n], query[0..n]);
    query_len = n;
    parse_mutex.unlock();
    var job: SearchJob = .{ .generation = my_gen, .query_len = n };
    @memcpy(job.query[0..n], query[0..n]);

    if (@import("../core/workers.zig").spawnLegacy(searchWorker, .{job})) |t| {
        @import("../core/workers.zig").release(t); // never joined — detach to avoid leaking the handle
    } else |_| {
        search_request.finish(my_gen, &state.app.radio.is_loading);
    }
}

/// Installed SomaFM contributes bounded real station playlists independently
/// of RadioBrowser availability; its identities never trigger RadioBrowser pings.
fn appendSoma(group: *RadioGroup) void {
    const generation = group.job.generation;
    const query = group.job.query[0..group.job.query_len];
    if (!search_request.isCurrent(generation)) return;
    var base: [512]u8 = undefined;
    const endpoint = @import("../core/source_config.zig").copyValue("somafm", "base", &base) orelse return;
    const audio = @import("audio_sources.zig");
    const rows = alloc.alloc(audio.Item, 16) catch return;
    defer alloc.free(rows);
    const reply = audio.searchIntoWithCancellation(.somafm, query, rows, endpoint, .{ .epoch32 = .{ .value = &search_request.generation, .expected = generation } });
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!search_request.isCurrent(generation)) return;
    if (reply.status == .done or reply.status == .no_results) group.succeeded = true;
    if (reply.count == 0) return;
    if (!group.published) state.app.radio.result_count = 0;
    group.published = true;
    for (rows[0..reply.count]) |row| {
        if (state.app.radio.result_count == state.app.radio.results.len) break;
        var station: pure.Station = .{};
        const id = std.fmt.bufPrint(&station.stationuuid, "somafm:{s}", .{row.id[0..row.id_len]}) catch continue;
        station.stationuuid_len = id.len;
        if (row.play_url_len > station.url.len) continue;
        audio.pure.copy(&station.name, &station.name_len, row.title[0..row.title_len]);
        audio.pure.copy(&station.url, &station.url_len, row.play_url[0..row.play_url_len]);
        if (row.cover_len <= station.favicon.len) audio.pure.copy(&station.favicon, &station.favicon_len, row.cover[0..row.cover_len]);
        audio.pure.copy(&station.tags, &station.tags_len, row.summary[0..row.summary_len]);
        audio.pure.copy(&station.country, &station.country_len, "SomaFM");
        state.app.radio.result_count = pure.appendUnique(&state.app.radio.results, state.app.radio.result_count, &.{station});
    }
    if (state.app.radio.result_count > 0) state.app.radio.fetch_error = false;
    state.wakeUi();
}

fn searchWorker(job: SearchJob) void {
    runRadioGroup(job, false);
}

// ══════════════════════════════════════════════════════════
// Infinite scroll — fetch + append the NEXT window (same query/popular mode)
// ══════════════════════════════════════════════════════════

/// Fetch the next provider window of stations and append playable unique rows. Guarded by
/// `loading_more` + the main `is_loading` so a near-bottom scroll can't spawn
/// a burst; runs under the current `search_request` so a fresh search/popular
/// reload supersedes it. No-op once `more_available` clears (a short window or
/// the fixed results[] buffer filled). Mirrors drama.zig's loadMore().
pub fn loadMore() void {
    if (@import("builtin").is_test and loading_fixture_for_test) return;
    if (!more_available) return;
    if (state.app.radio.is_loading.load(.acquire)) return;
    if (loading_more.load(.acquire)) return;

    if (state.app.radio.result_count >= state.app.radio.results.len) {
        more_available = false;
        return;
    }
    if (loading_more.swap(true, .acq_rel)) return; // lost the race — another append in flight

    const my_gen = search_request.current(); // stay within the current generation
    const offset = current_offset;
    const popular = state.app.radio.showing_popular;
    var job: SearchJob = .{ .generation = my_gen };
    parse_mutex.lock();
    job.query_len = @min(query_len, job.query.len);
    @memcpy(job.query[0..job.query_len], query_buf[0..job.query_len]);
    parse_mutex.unlock();

    if (@import("../core/workers.zig").spawnLegacy(loadMoreWorker, .{ job, offset, popular })) |t| {
        @import("../core/workers.zig").release(t);
    } else |_| {
        loading_more.store(false, .release);
    }
}

/// Worker for one infinite-scroll append. `popular` picks buildPopularUrl vs
/// buildSearchUrl for the SAME mode the visible grid is in; for a search, the
/// worker receives the same immutable query snapshot as the initial search.
fn loadMoreWorker(job: SearchJob, offset: usize, popular: bool) void {
    const my_gen = job.generation;
    defer loading_more.store(false, .release);

    var url_buf: [1024]u8 = undefined;
    const url = if (popular)
        pure.buildPopularUrl(RADIO_PAGE_SIZE, offset, &url_buf)
    else blk: {
        var enc: [768]u8 = undefined;
        const encoded = percentEncode(job.query[0..job.query_len], &enc);
        break :blk pure.buildSearchUrl(encoded, RADIO_PAGE_SIZE, offset, &url_buf);
    };
    if (url.len == 0) return;

    // Shared public directory — be a polite citizen (≤ 1 req/sec), same bucket
    // as the initial fetches.
    rate_limit.acquire("radiobrowser", 1.0);

    // Keep loaded rows on failure and surface it; do not retry every UI frame.
    const body = fetchBody(url, 512 * 1024) orelse {
        if (search_request.isCurrent(my_gen)) {
            state.app.radio.fetch_error = true;
            more_available = false;
        }
        return;
    };
    defer alloc.free(body);

    if (!search_request.isCurrent(my_gen)) return; // superseded by a fresh search/popular reload

    // Parse into a heap staging buffer — never a big stack array on a spawned
    // thread (CLAUDE.md).
    const staged = alloc.alloc(pure.Station, RADIO_PAGE_SIZE) catch return;
    defer alloc.free(staged);
    const page = pure.parsePage(alloc, body, staged) orelse {
        if (search_request.isCurrent(my_gen)) {
            state.app.radio.fetch_error = true;
            more_available = false;
        }
        return;
    };
    const n = page.count;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!search_request.isCurrent(my_gen)) return; // re-check under lock

    current_offset = offset + page.consumed;
    more_available = page.consumed >= RADIO_PAGE_SIZE;
    state.app.radio.fetch_error = false;

    const base = state.app.radio.result_count;
    var appended: usize = 0;
    stations: for (staged[0..n]) |st| {
        if (base + appended >= state.app.radio.results.len) {
            more_available = false;
            break;
        }
        // Dedup by stationuuid (fallback: resolved/raw url) against every row
        // already in the grid, including ones this same window just appended.
        const st_url = if (st.url_resolved_len > 0) st.url_resolved[0..st.url_resolved_len] else st.url[0..st.url_len];
        var i: usize = 0;
        while (i < base + appended) : (i += 1) {
            const ex = &state.app.radio.results[i];
            if (st.stationuuid_len > 0 and ex.stationuuid_len > 0 and
                std.mem.eql(u8, ex.stationuuid[0..ex.stationuuid_len], st.stationuuid[0..st.stationuuid_len]))
                continue :stations;
            const ex_url = if (ex.url_resolved_len > 0) ex.url_resolved[0..ex.url_resolved_len] else ex.url[0..ex.url_len];
            if (st_url.len > 0 and ex_url.len > 0 and std.mem.eql(u8, ex_url, st_url)) continue :stations;
        }
        state.app.radio.results[base + appended] = st;
        appended += 1;
    }
    state.app.radio.result_count = base + appended;

    var lb: [64]u8 = undefined;
    logs.pushLog("info", "radio", std.fmt.bufPrint(&lb, "Loaded {d} more stations (offset {d})", .{ appended, offset }) catch "Loaded more stations", false);
}

// ══════════════════════════════════════════════════════════
// Play — stream url_resolved (fallback url) through mpv
// ══════════════════════════════════════════════════════════

/// Load station `idx`'s stream straight into mpv. `url_resolved` is the
/// CDN-resolved audio stream mpv plays natively, so loadContentDirect (no
/// content-type routing) is used — creating a player if none exists and
/// revealing the player page. Falls back to `url` when unresolved.
pub fn playStation(idx: usize) void {
    parse_mutex.lock();
    if (idx >= state.app.radio.result_count) {
        parse_mutex.unlock();
        return;
    }
    const s = state.app.radio.results[idx];
    parse_mutex.unlock();
    playCopiedStation(s);
}

pub fn stationForAction(uuid: []const u8) ?pure.Station {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    return pure.stationByIdentity(state.app.radio.results[0..@min(state.app.radio.result_count, state.app.radio.results.len)], uuid);
}

pub fn playStationIdentity(uuid: []const u8) bool {
    const station = stationForAction(uuid) orelse return false;
    playCopiedStation(station);
    return true;
}

fn playCopiedStation(s: pure.Station) void {
    const src = if (s.url_resolved_len > 0)
        s.url_resolved[0..s.url_resolved_len]
    else
        s.url[0..s.url_len];
    if (src.len == 0) return;

    var url_buf: [512]u8 = undefined;
    const ulen = @min(src.len, url_buf.len);
    @memcpy(url_buf[0..ulen], src[0..ulen]);

    // Snapshot the now-playing fields into locals BEFORE playing — a concurrent
    // re-search can overwrite results[] mid-frame, so nothing handed to
    // loadContentDirectMeta may alias the live row.
    var name_buf: [160]u8 = undefined;
    const nlen = @min(s.name_len, name_buf.len);
    @memcpy(name_buf[0..nlen], s.name[0..nlen]);

    var fav_buf: [300]u8 = undefined;
    const flen = @min(s.favicon_len, fav_buf.len);
    @memcpy(fav_buf[0..flen], s.favicon[0..flen]);

    // Subtitle: "CODEC · N kbps · COUNTRY · tags" — each part appended only when
    // present, joined by " · " (e.g. "MP3 · 128 kbps · United States").
    var sub_buf: [192]u8 = undefined;
    var sw = std.Io.Writer.fixed(&sub_buf);
    var wrote = false;
    if (s.codec_len > 0) {
        // Codec displays upper-cased (the API returns "mp3"/"aac" mixed-case).
        for (s.codec[0..s.codec_len]) |ch| sw.writeByte(std.ascii.toUpper(ch)) catch {};
        wrote = true;
    }
    if (s.bitrate > 0) {
        if (wrote) sw.writeAll(" · ") catch {};
        sw.print("{d} kbps", .{s.bitrate}) catch {};
        wrote = true;
    }
    if (s.country_len > 0) {
        if (wrote) sw.writeAll(" · ") catch {};
        sw.writeAll(s.country[0..s.country_len]) catch {};
        wrote = true;
    }
    if (s.tags_len > 0) {
        if (wrote) sw.writeAll(" · ") catch {};
        sw.writeAll(s.tags[0..@min(s.tags_len, 60)]) catch {};
        wrote = true;
    }
    const sub = sub_buf[0..sw.end];

    @import("browser.zig").loadContentDirectMeta(url_buf[0..ulen], fav_buf[0..flen], name_buf[0..nlen], sub);
    logs.pushLog("info", "radio", "Streaming internet radio station", false);

    // RadioBrowser click-counting politeness — best-effort, ignore the result.
    pingClick(s.stationuuid[0..s.stationuuid_len]);
}

/// Fire-and-forget the RadioBrowser click endpoint for a station uuid so the
/// directory's popularity stats stay honest. Detached + best-effort: the uuid
/// is copied into an owned heap buffer the worker frees, so no shared/mutable
/// state is handed across the thread boundary.
fn pingClick(uuid: []const u8) void {
    if (uuid.len == 0 or std.mem.startsWith(u8, uuid, "somafm:")) return;
    const owned = alloc.dupe(u8, uuid) catch return;
    if (@import("../core/workers.zig").spawnLegacy(clickWorker, .{owned})) |t| {
        @import("../core/workers.zig").release(t);
    } else |_| {
        alloc.free(owned);
    }
}

fn clickWorker(uuid_owned: []u8) void {
    defer alloc.free(uuid_owned);
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://all.api.radio-browser.info/json/url/{s}",
        .{uuid_owned},
    ) catch return;
    if (fetchBody(url, 16 * 1024)) |body| alloc.free(body); // ignore contents
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

/// Fetch through the shared status-aware transport into a fresh heap buffer.
/// Large buffers stay off the worker stack (macOS has a small thread stack).
fn fetchBody(url: []const u8, cap: usize) ?[]u8 {
    return fetchBodyForGeneration(url, cap, search_request.current());
}
fn fetchBodyForGeneration(url: []const u8, cap: usize, generation: u32) ?[]u8 {
    const buf = alloc.alloc(u8, cap) catch return null;
    // Mirrors share the directory schema. Keep the path and query intact,
    // including pagination and station UUIDs, when a host is unavailable.
    for (0..3) |attempt| {
        if (!search_request.isCurrent(generation)) break;
        var ub: [1536]u8 = undefined;
        const endpoint = pure.mirrorUrl(url, attempt, &ub) orelse continue;
        const body = reliable_fetch.fetch(endpoint, buf, .{
            .user_agent = @import("../core/app_meta.zig").user_agent,
            .timeout_secs = 8,
            .impersonate = false,
            .cancel_epoch = .{ .epoch32 = .{ .value = &search_request.generation, .expected = generation } },
        }) orelse continue;
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '[') continue;
        // A mirror returning truncated/malformed JSON is a failed host too.
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch continue;
        const valid = parsed.value == .array;
        parsed.deinit();
        if (!valid) continue;
        return alloc.realloc(buf, body.len) catch {
            alloc.free(buf);
            return null;
        };
    }
    alloc.free(buf);
    return null;
}

pub fn hasMoreResults() bool {
    return more_available and resultCount() < state.app.radio.results.len;
}
pub fn loadingMoreResults() bool {
    return loading_more.load(.acquire);
}

// ══════════════════════════════════════════════════════════
// UI (Drawer / Browse › Radio)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    // Populate the page on first open (no-op after the first fetch).
    loadPopularOnce();

    renderSearchBar();

    if (state.app.radio.fetch_error) {
        _ = dvui.label(@src(), "Failed to fetch — check your connection", .{}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    renderResults();
}

fn renderSearchBar() void {
    if (!@import("../ui/browse_layout_pure.zig").showLocalSearch(state.app.page_shell_enabled)) return;
    var row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = 10, .y = 7, .w = 10, .h = 7 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer row.deinit();

    _ = dvui.icon(@src(), "", icons.tvg.lucide.radio, .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    const layout_w = @import("../core/scale_pure.zig").layoutUnits(dvui.windowRect().w, state.app.ui_scale);
    const search_w = @max(150, @min(280, layout_w - 280));
    const entered = components.toolbarSearch(@src(), &state.app.radio.search_buf, "Search radio stations…", search_w);
    const go = components.toolbarGo(@src(), "Search");

    if (entered or go) {
        const q = std.mem.sliceTo(&state.app.radio.search_buf, 0);
        if (q.len > 0) searchRadio(q);
    }

    if (state.app.radio.is_loading.load(.acquire)) {
        dvui.spinner(@src(), .{
            .color_text = theme.colors.accent,
            .min_size_content = theme.iconSize(.md),
            .gravity_y = 0.5,
            .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
        });
    }
}

// ── Card grid ──
// Popular stations and search results are the SAME record (parseStations fills
// both), so they render through one grid: station logo + name + "codec · kbps ·
// country", click → playStation(i), exactly what the old row's Play button did.
const CARD_GAP: f32 = 6;
const CARD_TARGET_W: f32 = 170; // desired card width; columns derive from it
const CARD_FOOTER_H: f32 = 46; // name + meta lines under the logo

/// Fill the card's logo area with the station's favicon, reusing the shared
/// poster daemon. Falls back to the radio glyph while loading, when the station
/// has no favicon, or when the image can't be decoded (many stations advertise
/// webp/svg logos, which stb_image can't read — the glyph is the norm, not an
/// error). UI-thread only.
fn renderLogo(i: usize, s: *const pure.Station) void {
    const slot = &station_posters[i];
    const fav = s.favicon[0..s.favicon_len];

    const h = std.hash.Fnv1a_64.hash(fav);
    if (slot.url_hash != h and !slot.fetching) {
        poster.deinitPoster(&slot.pixels, &slot.tex);
        slot.w = 0;
        slot.h = 0;
        slot.attempted = false;
        slot.failed = false;
        slot.url_hash = h;
    }
    if (fav.len > 0 and slot.url_hash == h) {
        _ = poster.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.tex);
        if (slot.fetching) slot.attempted = true else if (slot.attempted and slot.pixels == null and slot.tex == null) slot.failed = true;
        if (!slot.failed and slot.tex == null and !slot.fetching and slot.pixels == null) {
            poster.fetchAsync(fav, &slot.pixels, &slot.w, &slot.h, &slot.fetching);
            if (slot.fetching) slot.attempted = true;
        }
    }

    const visible_texture = if (fav.len > 0 and slot.url_hash == h) slot.tex else null;
    if (visible_texture) |tex| {
        _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
            .id_extra = i + 1000,
            .expand = .both,
            .corner_radius = dvui.Rect.all(8),
        });
    } else if (fav.len > 0 and !slot.failed) {
        components.coverSkeleton(@src(), i + 1000, 8);
    } else {
        _ = dvui.icon(@src(), "", icons.tvg.lucide.radio, .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });
    }
}

/// One station card: logo (clickable → play) + name + codec/bitrate/country.
fn renderCard(i: usize, card_w: f32, s: *const pure.Station) void {

    // Validate a STABLE COPY: a fetch worker can rewrite results[i] mid-frame
    // and dvui panics on invalid UTF-8 it reads after we validated.
    var name_buf: [160]u8 = undefined;
    const name = safeUtf8Buf(s.name[0..@min(s.name_len, s.name.len)], &name_buf);

    // min == max height → every card (and thus every row) has a uniform pitch.
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i,
        .min_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .margin = dvui.Rect.all(CARD_GAP),
    });
    defer card.deinit();

    // Logo hosted INSIDE a single button widget — one clickable rectangle per
    // card (a sibling button + box would draw two).
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

        renderLogo(i, s);

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        // Same click target as the old row's Play button.
        if (clicked) playCopiedStation(s.*);
    }

    // Name row: stream-health dot + title. Probing is lazy — rendering a card
    // kicks a bounded probe for its stream on the shared app-wide pool, and the
    // dot uses the same colour mapping as Live TV (green live / yellow slow /
    // red dead; nothing drawn until a probe lands).
    {
        var nrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 6000, .expand = .horizontal });
        defer nrow.deinit();

        const stream_url = if (s.url_resolved_len > 0)
            s.url_resolved[0..@min(s.url_resolved_len, s.url_resolved.len)]
        else
            s.url[0..@min(s.url_len, s.url.len)];
        link_health.probe(RADIO_KIND, stream_url);
        const st = link_health.statusOf(RADIO_KIND, stream_url);
        if (st != .unknown) {
            var dot = dvui.box(@src(), .{}, .{
                .id_extra = i + 8000,
                .min_size_content = .{ .w = 8, .h = 8 },
                .max_size_content = .{ .w = 8, .h = 8 },
                .corner_radius = dvui.Rect.all(4),
                .background = true,
                .color_fill = link_health.statusColor(st),
                .gravity_y = 0.5,
                .margin = .{ .x = 2, .y = 0, .w = 4, .h = 0 },
            });
            dot.deinit();
        }

        _ = dvui.label(@src(), "{s}", .{name}, .{
            .id_extra = i + 3000,
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .gravity_y = 0.5,
            .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
        });
    }

    // Meta: codec · bitrate · country.
    var meta_buf: [120]u8 = undefined;
    var mw = std.Io.Writer.fixed(&meta_buf);
    var wrote = false;
    if (s.codec_len > 0) {
        mw.writeAll(s.codec[0..@min(s.codec_len, s.codec.len)]) catch {};
        wrote = true;
    }
    if (s.bitrate > 0) {
        if (wrote) mw.writeAll(" · ") catch {};
        mw.print("{d} kbps", .{s.bitrate}) catch {};
        wrote = true;
    }
    if (s.country_len > 0) {
        if (wrote) mw.writeAll(" · ") catch {};
        mw.writeAll(s.country[0..@min(s.country_len, s.country.len)]) catch {};
        wrote = true;
    }
    if (wrote) {
        var safe_meta: [120]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(meta_buf[0..mw.end], &safe_meta)}, .{
            .id_extra = i + 4000,
            .color_text = theme.colors.text_tertiary,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
    }
}

fn renderResults() void {
    parse_mutex.lock();
    const count = @min(state.app.radio.result_count, state.app.radio.results.len);
    const showing_popular = state.app.radio.showing_popular;
    parse_mutex.unlock();
    if (count == 0 and more_available and !state.app.radio.is_loading.load(.acquire)) loadMore();
    if (count == 0 and !state.app.radio.is_loading.load(.acquire) and !loading_more.load(.acquire)) {
        components.emptyState(icons.tvg.lucide.radio, "Find a station", "Search by station, genre, or country.");
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    _ = dvui.label(@src(), "{s} · {d}", .{
        if (showing_popular) "Most popular stations" else "Results", count,
    }, .{
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 2 },
    });

    // Responsive columns from the LIVE page width (one-frame lag; first paint
    // falls back to a sane default) — same shape as the TMDB gallery.
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(1, @as(usize, @intFromFloat(avail_w / CARD_TARGET_W)));
    const cols_f: f32 = @floatFromInt(cols);
    const card_w: f32 = @max(100, (avail_w - cols_f * 2 * CARD_GAP) / cols_f);
    if (count == 0) {
        components.coverSkeletonGrid(@src(), 48000, cols, card_w, card_w, CARD_FOOTER_H, 3);
        return;
    }

    const row_h = card_w + CARD_FOOTER_H + 2 * CARD_GAP;
    const total_rows = (count + cols - 1) / cols;
    const win = tmdb_pure.visibleRows(total_rows, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 2);

    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49998,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) },
        });
        sp.deinit();
    }

    var r: usize = win.first;
    while (r < win.last) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = r + 50000,
            .expand = .horizontal,
        });
        defer row.deinit();

        var c: usize = 0;
        while (c < cols and r * cols + c < count) : (c += 1) {
            const idx = r * cols + c;
            parse_mutex.lock();
            const station = state.app.radio.results[idx];
            parse_mutex.unlock();
            renderCard(idx, card_w, &station);
        }
    }

    if (win.last < total_rows) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(total_rows - win.last)) },
        });
        sp.deinit();
    }

    // Infinite scroll: fetch + append the next window (same query/popular
    // mode) as the user nears the bottom. Bounded by more_available +
    // loading_more so one scroll can't spawn a burst; `underfilled` keeps
    // paging when the first window is shorter than the viewport. Mirrors
    // services/drama.zig.
    if (more_available) {
        const loading = loading_more.load(.acquire);
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        const underfilled = max_y <= 0 and state.app.radio.result_count > 0;
        if ((near_bottom or underfilled) and !loading and !state.app.radio.is_loading.load(.acquire)) loadMore();
        if (loading or underfilled) {
            dvui.spinner(@src(), .{ .color_text = theme.colors.accent, .min_size_content = theme.iconSize(.lg), .gravity_x = 0.5, .margin = dvui.Rect.all(12) });
            state.wakeUi();
        }
    }
}

test "Radio action keeps selected identity across search publication" {
    const r = &state.app.radio;
    const saved_count = r.result_count;
    const saved_a = r.results[0];
    const saved_b = r.results[1];
    defer {
        r.result_count = saved_count;
        r.results[0] = saved_a;
        r.results[1] = saved_b;
    }
    var a = pure.Station{};
    a.stationuuid[0] = 'a';
    a.stationuuid_len = 1;
    a.url[0] = 'A';
    a.url_len = 1;
    var b = pure.Station{};
    b.stationuuid[0] = 'b';
    b.stationuuid_len = 1;
    b.url[0] = 'B';
    b.url_len = 1;
    r.result_count = 2;
    r.results[0] = a;
    r.results[1] = b;
    const rendered = stationForAction("a").?;
    const copied_rows = try std.testing.allocator.alloc(pure.Station, 2);
    defer std.testing.allocator.free(copied_rows);
    const snapshot = copyCatalogSnapshot(copied_rows);
    try std.testing.expectEqual(@as(usize, 2), snapshot.count);

    r.results[0] = b;
    r.results[1] = a;
    const selected = stationForAction("a").?;
    try std.testing.expectEqualStrings("A", selected.url[0..selected.url_len]);
    r.result_count = 1;
    try std.testing.expect(stationForAction("a") == null);
    try std.testing.expectEqual(@as(usize, 2), snapshot.count);
    try std.testing.expectEqualStrings("a", copied_rows[0].stationuuid[0..copied_rows[0].stationuuid_len]);
    try std.testing.expectEqualStrings("b", copied_rows[1].stationuuid[0..copied_rows[1].stationuuid_len]);
    try std.testing.expectEqualStrings("A", rendered.url[0..rendered.url_len]);
}
