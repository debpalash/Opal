const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const anime_pure = @import("anime_pure.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const icons = @import("icons");
const logs = @import("../core/logs.zig");
const player = @import("../player/player.zig");
const safeUtf8 = @import("../core/text.zig").safeUtf8;
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;
const poster = @import("../core/poster.zig");
const anilist = @import("anilist.zig");
const anilist_pure = @import("anilist_pure.zig");
const anime_schedule = @import("anime_schedule.zig");
const anime_schedule_pure = @import("anime_schedule_pure.zig");
const bounded_process = @import("../core/bounded_process.zig");
const LatestRequest = @import("../core/latest_request.zig").Gate;
const workers = @import("../core/workers.zig");
const route_resilience = @import("../core/route_resilience_pure.zig");

const alloc = @import("../core/alloc.zig").allocator;

/// Run a one-shot anime helper with an independent outer deadline and a hard
/// output ceiling. curl's own --max-time remains useful transport policy, but
/// it cannot guarantee that a wedged helper (or a descendant retaining stdout)
/// is reaped. bounded_process owns that complete lifecycle on every platform.
fn boundedCurl(argv: []const []const u8, output: []u8, timeout_ms: i64) ?[]const u8 {
    const result = bounded_process.run(argv, output, .{
        .timeout_ms = timeout_ms,
        .terminate_grace_ms = 250,
    });
    return if (result.ok()) result.output else null;
}

fn boundedSearchCurl(argv: []const []const u8, output: []u8, timeout_ms: i64, generation: u32) ?[]const u8 {
    const result = bounded_process.run(argv, output, .{
        .timeout_ms = timeout_ms,
        .terminate_grace_ms = 100,
        .cancel_epoch = .{ .epoch32 = .{ .value = &search_request.generation, .expected = generation } },
    });
    return if (result.ok()) result.output else null;
}
fn searchEpoch(generation: u32) bounded_process.CancelEpoch {
    return .{ .epoch32 = .{ .value = &search_request.generation, .expected = generation } };
}

// dvui texture ops MUST run on the UI thread (they touch current_window / the
// frame texture-trash list). The Jikan parse WORKER threads overwrite results[]
// and used to call dvui.textureDestroyLater directly on the old poster textures
// → SIGABRT on a mode switch after posters had loaded. Workers now QUEUE the old
// textures here; the UI thread drains them via drainPendingTexFrees() each frame.
var pending_tex: [256]dvui.Texture = undefined;
var pending_tex_count: usize = 0;
var pending_tex_mutex: @import("../core/sync.zig").Mutex = .{};

fn queueTexFree(tex: dvui.Texture) void {
    pending_tex_mutex.lock();
    defer pending_tex_mutex.unlock();
    if (pending_tex_count < pending_tex.len) {
        pending_tex[pending_tex_count] = tex;
        pending_tex_count += 1;
    }
    // Queue full (≥256 pending, extremely rare) → texture leaks. Far better than
    // aborting the app from a worker thread.
}

/// Drain queued poster-texture frees on the UI thread. Call from renderContent.
fn drainPendingTexFrees() void {
    pending_tex_mutex.lock();
    defer pending_tex_mutex.unlock();
    for (pending_tex[0..pending_tex_count]) |t| dvui.textureDestroyLater(t);
    pending_tex_count = 0;
}

// ══════════════════════════════════════════════════════════
// Anime Tab — Jikan/AniList metadata + Trending → Search → Select → Pick Episode.
// Stream resolution runs through resolver.zig (torrents → AllAnime → AnimePahe);
// AllAnime's endpoint now lives in opal-plugins (id "allanime"), inert until
// installed, so no source host is hardcoded here.
// ══════════════════════════════════════════════════════════

const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/121.0";

// Loading flags are atomic; request generations reject late completions.
pub var has_loaded_trending: bool = false;

// ── UI-control state (module-level, NOT in state.zig). ──

/// Trending category chip — maps to Jikan top/anime `filter=` values, plus
/// `.lists`, which is NOT a Jikan filter at all: it swaps the whole fetch for
/// the `lists` source plugin (see the "lists source plugin" section below). Its
/// chip only renders when that plugin is installed.
const TrendFilter = enum {
    airing,
    top,
    bypopularity,
    upcoming,
    lists,

    /// Jikan query value. `.top` is the un-filtered top list (no filter param).
    fn jikan(self: TrendFilter) []const u8 {
        return switch (self) {
            .airing => "airing",
            .top => "", // no filter → overall top
            .bypopularity => "bypopularity",
            .upcoming => "upcoming",
            // Never reaches a Jikan URL: every call site checks usesLists() first
            // (loadTrendingAnime routes to listsThread, buildGridUrl returns null).
            .lists => "",
        };
    }
};
var trend_filter: TrendFilter = .airing;

/// True when the grid should be served by the `lists` plugin instead of Jikan:
/// Trending mode, the Lists chip active, and the plugin actually installed. The
/// last clause means uninstalling mid-session silently falls back to Jikan
/// rather than stranding the grid on a dead source.
fn usesLists() bool {
    return state.app.anime.mode == .trending and trend_filter == .lists and listsBase() != null;
}

/// User-cyclable card width (compact ↔ large), clamped 110–320 in the +/- wires.
var card_w_pref: f32 = 150;

/// Grid card footer height (title + meta rows) below the poster. Referenced
/// by renderCard's uniform min==max sizing AND the grid's virtualization row
/// pitch — keep single-sourced.
const GRID_CARD_EXTRA_H: f32 = 92;

// ── Mode dispatch (Trending | Seasonal | Calendar | Search | My List) ──
// Every grid mode reuses results[]/renderGallery; only the fetch differs. A
// single monotonic generation (`search_request`, already declared below) guards all
// of them so switching modes fast never shows stale results: each fetcher
// captures the gen it was spawned under and parseJikanData drops on mismatch.

/// Latest mode we issued a fetch for. When renderContent sees `anime.mode`
/// differ from this, it resets SWR + fires the matching fetch exactly once.
var fetched_mode: ?state.AnimeMode = null;
/// Sub-selectors we last fetched under, so changing a season/day/filter while
/// already in that mode re-fires (renderContent compares + refetches).
var fetched_season_sel: state.AnimeSeasonSel = .now;
var fetched_season_year: u16 = 0;
var fetched_cal_day: u8 = 255;
var fetched_nsfw_filter: bool = true;
var clear_for_safe_refresh: bool = false;

/// Offline pixel fixture uses the real grid without admitting provider work.
pub fn setNativeFixtureForTest(rows: []const state.AnimeResult) void {
    if (!@import("builtin").is_test) @compileError("Native fixture is test-only");
    const a = &state.app.anime;
    a.result_count = @min(rows.len, a.results.len);
    @memcpy(a.results[0..a.result_count], rows[0..a.result_count]);
    a.mode = .trending;
    a.selected_idx = null;
    a.last_fetch_s = 9_999_999_999;
    a.is_loading.store(false, .release);
    fetched_mode = .trending;
    fetched_nsfw_filter = state.app.nsfw_filter_enabled;
    clear_for_safe_refresh = false;
    results_are_scraper = false;
}

/// Switch the active browse mode. Resets the SWR stamp so the explicit switch
/// always refetches, bumps the generation (drops any in-flight worker), and
/// clears the selection so we land on the grid. The actual fetch is kicked by
/// renderContent's dispatch (keeps a single fire-point).
fn setMode(m: state.AnimeMode) void {
    // Picking any browse mode leaves the "Airing this week" schedule view.
    state.app.anime.sched_view = false;
    if (state.app.anime.mode == m) return;
    state.app.anime.mode = m;
    state.app.anime.selected_idx = null;
    cancelPlayback();
    episode_request.cancel(&state.app.anime.episodes_loading);
    state.app.anime.episode_count = 0;
    state.app.anime.last_fetch_s = 0; // bypass SWR on explicit switch
    fetched_mode = null; // force renderContent to re-dispatch
    grid_page = 1; // restart infinite-scroll pagination for the new mode
    more_available.store(false, .release);
    search_request.cancel(&state.app.anime.is_loading); // drop stale in-flight workers
}

// ── Infinite-scroll pagination (mirrors comics.zig loadMoreResults). ──
// Jikan paginates: the four grid fetchers request page 1, and loadMoreGrid()
// fetches page grid_page+1 and APPENDS into results[] at the current end.
// `more_available` is the parsed `has_next_page` flag from the last fetch;
// `grid_page` is the highest page currently merged into results[].
var more_available: std.atomic.Value(bool) = .init(false);
var grid_page: u32 = 1;

/// True iff the Jikan `pagination.has_next_page` flag is set in `json`. A flat
/// substring scan is enough — the field appears once, at the document root.
fn parsePagination(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"has_next_page\":true") != null;
}

/// Build the page-`page` Jikan URL for the *current* grid mode into `out`,
/// reusing the exact URL strings the four fetch threads emit. Returns the
/// formatted slice, or null on a bufPrint overflow. Search uses the snapshot
/// in search_query_buf (already percent-encoded path is rebuilt here).
fn buildGridUrl(out: []u8, mode: state.AnimeMode, page: u32) ?[]const u8 {
    return switch (mode) {
        .trending => blk: {
            // The lists plugin ships its whole catalogue in one payload — there
            // is no page 2, so infinite-scroll has nothing to append.
            if (trend_filter == .lists) break :blk null;
            const jikan_api = "https://api.jikan.moe/v4/top/anime";
            const fv = trend_filter.jikan();
            break :blk (if (fv.len == 0)
                std.fmt.bufPrint(out, "{s}?limit=25&page={d}{s}", .{ jikan_api, page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) })
            else
                std.fmt.bufPrint(out, "{s}?filter={s}&limit=25&page={d}{s}", .{ jikan_api, fv, page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) })) catch null;
        },
        .search => blk: {
            anime_query_mutex.lock();
            defer anime_query_mutex.unlock();
            var enc_buf: [768]u8 = undefined;
            var enc_len: usize = 0;
            const qlen = @min(search_query_len, search_query_buf.len);
            for (search_query_buf[0..qlen]) |c| {
                if (enc_len + 3 > enc_buf.len) break;
                const pct: ?[2]u8 = switch (c) {
                    '%' => .{ '2', '5' },
                    ' ' => .{ '2', '0' },
                    '&' => .{ '2', '6' },
                    '=' => .{ '3', 'D' },
                    '#' => .{ '2', '3' },
                    '?' => .{ '3', 'F' },
                    '+' => .{ '2', 'B' },
                    else => null,
                };
                if (pct) |hex| {
                    enc_buf[enc_len] = '%';
                    enc_buf[enc_len + 1] = hex[0];
                    enc_buf[enc_len + 2] = hex[1];
                    enc_len += 3;
                } else {
                    enc_buf[enc_len] = c;
                    enc_len += 1;
                }
            }
            break :blk std.fmt.bufPrint(out, "https://api.jikan.moe/v4/anime?q={s}&limit=25&page={d}{s}", .{ enc_buf[0..enc_len], page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) }) catch null;
        },
        .seasonal => switch (state.app.anime.season_sel) {
            .now => std.fmt.bufPrint(out, "https://api.jikan.moe/v4/seasons/now?limit=25&page={d}{s}", .{ page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) }) catch null,
            .upcoming => std.fmt.bufPrint(out, "https://api.jikan.moe/v4/seasons/upcoming?limit=25&page={d}{s}", .{ page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) }) catch null,
            else => std.fmt.bufPrint(out, "https://api.jikan.moe/v4/seasons/{d}/{s}?limit=25&page={d}{s}", .{ state.app.anime.season_year, seasonStr(state.app.anime.season_sel), page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) }) catch null,
        },
        .calendar => blk: {
            const day = calDayStr(state.app.anime.cal_day);
            break :blk (if (day.len == 0)
                std.fmt.bufPrint(out, "https://api.jikan.moe/v4/schedules?limit=25&page={d}{s}", .{ page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) })
            else
                std.fmt.bufPrint(out, "https://api.jikan.moe/v4/schedules?filter={s}&limit=25&page={d}{s}", .{ day, page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) })) catch null;
        },
        .mylist => null,
    };
}

/// Detached worker guard for the infinite-scroll appender.
var grid_loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Fetch the next Jikan page for the current grid mode and APPEND it into
/// results[] (mirrors comics.zig loadMoreResults). No-op unless the last fetch
/// reported has_next_page, we're not already busy/loading, and there's room.
pub fn loadMoreGrid() void {
    if (!more_available.load(.acquire) or grid_loading_more.load(.acquire) or state.app.anime.is_loading.load(.acquire)) return;
    if (state.app.anime.result_count == 0 or state.app.anime.result_count >= state.app.anime.results.len) return;
    if (grid_loading_more.swap(true, .acq_rel)) return;
    const job = gridJob(search_request.current(), state.app.anime.mode, grid_page + 1) orelse {
        grid_loading_more.store(false, .release);
        return;
    };
    workers.spawn(loadMoreGridWorker, .{job}) catch {
        grid_loading_more.store(false, .release);
    };
}

fn loadMoreGridWorker(job: GridJob) void {
    const my_gen = job.generation;
    const mode = job.mode;
    defer if (search_request.isCurrent(my_gen)) grid_loading_more.store(false, .release);

    const next_page = job.page;
    const url = job.url[0..job.url_len];

    const argv = [_][]const u8{ "curl", "-s", "--connect-timeout", "3", "-A", agent, "--max-time", "6", url };

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const body = boundedSearchCurl(&argv, buf, 8_000, my_gen) orelse {
            if (attempt < 2) @import("../core/io_global.zig").sleep((250 + @as(u64, attempt) * 350) * std.time.ns_per_ms);
            continue;
        };
        // Bail if a newer fetch (mode switch / fresh search) superseded us.
        if (search_request.current() != my_gen) return;
        const added = parseJikanDataEx(body, my_gen, mode == .calendar, state.app.anime.result_count);
        if (added > 0) {
            grid_page = next_page;
            more_available.store(parsePagination(body), .release);
            return;
        }
        if (attempt < 2) @import("../core/io_global.zig").sleep((250 + @as(u64, attempt) * 350) * std.time.ns_per_ms);
    }
    if (mode == .trending and search_request.current() == my_gen) {
        const kind: anilist_pure.BrowseKind = switch (job.trend) {
            .airing => .airing,
            .top => .top,
            .bypopularity => .popular,
            .upcoming => .upcoming,
            .lists => return,
        };
        const bytes = anilist.fetchBrowseWithCancellation(next_page, kind, job.sfw, buf, searchEpoch(my_gen));
        if (bytes > 0) {
            const added = appendAniListPage(buf[0..bytes], my_gen, state.app.anime.result_count);
            if (added > 0) {
                grid_page = next_page;
                more_available.store(anilist_pure.hasNextPage(buf[0..bytes]), .release);
                logs.pushLog("info", "anime", "Next page loaded (AniList fallback)", false);
                return;
            }
        }
    }
    // A transient Jikan 5xx must not permanently mark the catalog complete.
    // Keep the page retryable through the button / next viewport intersection.
    logs.pushLog("warn", "anime", "Next anime page unavailable after 3 attempts — retry remains available", false);
}

/// Jikan season path component for the current AnimeSeasonSel (winter/…/fall).
fn seasonStr(sel: state.AnimeSeasonSel) []const u8 {
    return switch (sel) {
        .winter => "winter",
        .spring => "spring",
        .summer => "summer",
        .fall => "fall",
        else => "winter",
    };
}

/// Jikan schedules filter for the current cal_day (0=all → empty → no filter).
fn calDayStr(day: u8) []const u8 {
    return switch (day) {
        1 => "monday",
        2 => "tuesday",
        3 => "wednesday",
        4 => "thursday",
        5 => "friday",
        6 => "saturday",
        7 => "sunday",
        else => "",
    };
}

// ── Live-search debounce + generation (see renderSearchBar). ──
/// Wall-clock ms of the last observed change to the search text buffer.
var last_edit_ms: i64 = 0;
/// Last query we actually fired a fetch for (to suppress duplicate fires).
var last_fired_query: [256]u8 = std.mem.zeroes([256]u8);
var last_fired_len: usize = 0;
/// Previous-frame snapshot of the buffer, to detect edits frame-to-frame.
var last_buf_snapshot: [256]u8 = std.mem.zeroes([256]u8);
var last_buf_snapshot_len: usize = 0;
/// Monotonic search generation. Each fired search captures the value it was
/// spawned under; a worker only publishes if it is still the latest, so fast
/// typing can't show stale / out-of-order results.
var search_request: LatestRequest = .{};

// ══════════════════════════════════════════════════════════
// Encrypted on-disk content cache — Trending-grid stale-while-revalidate.
//
// Mirrors tmdb_api.zig: the fresh page-1 Trending grid (Jikan path only — the
// `lists` chip has its own poster-cache disk blob) is serialized through the
// tested content_cache_pure Writer/Reader and persisted, so the next cold start
// paints the grid INSTANTLY instead of a blank box + spinner. results[] is a
// FIXED [100]AnimeResult array (poster pixels/textures live inline per row);
// unlike the TMDB ArrayList it is never reallocated, so the *AnimeResult
// pointers the poster daemon holds can never dangle — and on a cold start seed
// there are no in-flight poster workers at all (result_count==0). Seeding writes
// rows under anime_parse_mutex — the same lock the Jikan parser publishes under.
// The key carries the trend_filter selector so switching chips can't show the
// wrong cached set. Gated on content_cache_enabled; TTL is the shared SWR window.
// ══════════════════════════════════════════════════════════
const content_cache = @import("../core/content_cache.zig");
const ccp = @import("../core/content_cache_pure.zig");
const ANIME_CACHE_TTL_S: i64 = @import("browse_cache.zig").TTL_S;
const ANIME_BLOB_CAP: usize = 128 * 1024;

fn animeCacheKey(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "anime:trending:v2:{d}:sfw:{d}", .{
        @intFromEnum(trend_filter),
        @intFromBool(state.app.nsfw_filter_enabled),
    }) catch "anime:trending";
}

fn serializeAnime(w: *ccp.Writer, it: state.AnimeResult) void {
    w.blob(it.id[0..@min(it.id_len, it.id.len)]);
    w.blob(it.name[0..@min(it.name_len, it.name.len)]);
    w.blob(it.name_english[0..it.name_english_len]);
    w.u16v(it.episodes);
    w.f32v(it.score);
    w.blob(it.overview[0..@min(it.overview_len, it.overview.len)]);
    w.blob(it.poster_url[0..@min(it.poster_url_len, it.poster_url.len)]);
    // Detail-header metadata — SAME field order in deserializeAnime. Old blobs
    // truncate here and deserialize-miss (→ refetch), which is fine.
    w.blob(it.atype[0..@min(it.atype_len, it.atype.len)]);
    w.u16v(it.year);
    w.boolv(it.airing);
    w.u32v(@intCast(@max(it.anilist_id, 0)));
}

fn animeCopyField(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

/// Reads one card from `r`; null when the blob is truncated. Only the data
/// fields are restored — poster pixels/textures stay null so the grid fetches
/// covers lazily exactly like a fresh row.
fn deserializeAnime(r: *ccp.Reader) ?state.AnimeResult {
    var it = state.AnimeResult{};
    animeCopyField(&it.id, &it.id_len, r.blob() orelse return null);
    animeCopyField(&it.name, &it.name_len, r.blob() orelse return null);
    animeCopyField(&it.name_english, &it.name_english_len, r.blob() orelse return null);
    it.episodes = r.u16v() orelse return null;
    it.score = r.f32v() orelse return null;
    animeCopyField(&it.overview, &it.overview_len, r.blob() orelse return null);
    animeCopyField(&it.poster_url, &it.poster_url_len, r.blob() orelse return null);
    // Detail-header metadata — SAME field order as serializeAnime.
    animeCopyField(&it.atype, &it.atype_len, r.blob() orelse return null);
    it.year = r.u16v() orelse return null;
    it.airing = r.boolv() orelse return null;
    it.anilist_id = r.u32v() orelse return null;
    return it;
}

/// SWR write — persist the fresh Trending grid (page 1). Called from
/// trendingThread; takes anime_parse_mutex to snapshot results[] consistently.
fn putTrendingCache() void {
    if (!state.app.content_cache_enabled) return;
    if (trend_filter == .lists) return; // lists has its own disk cache
    const buf = alloc.alloc(u8, ANIME_BLOB_CAP) catch return;
    defer alloc.free(buf);
    anime_parse_mutex.lock();
    const count = state.app.anime.result_count;
    var w = ccp.Writer.init(buf);
    const n: u16 = @intCast(@min(count, state.app.anime.results.len));
    w.u16v(n);
    var i: usize = 0;
    while (i < n) : (i += 1) serializeAnime(&w, state.app.anime.results[i]);
    anime_parse_mutex.unlock();
    if (n == 0) return;
    const blob = w.done() orelse return;
    var key_buf: [48]u8 = undefined;
    content_cache.put(animeCacheKey(&key_buf), blob, ANIME_CACHE_TTL_S);
}

/// SWR read — seed the Trending grid from disk so it paints instantly on cold
/// start. UI-thread only (from renderContent's dispatch), ONLY in Trending mode
/// on the non-lists Jikan path and ONLY when results[] is empty. results[] is a
/// fixed array, so no capacity reservation is needed.
fn seedTrendingFromCache() void {
    if (!state.app.content_cache_enabled) return;
    if (state.app.anime.mode != .trending or trend_filter == .lists) return;
    if (state.app.anime.result_count != 0) return;
    const buf = alloc.alloc(u8, ANIME_BLOB_CAP) catch return;
    defer alloc.free(buf);
    var key_buf: [48]u8 = undefined;
    const hit = content_cache.get(animeCacheKey(&key_buf), buf) orelse return;
    var r = ccp.Reader.init(hit.bytes);
    const n = r.u16v() orelse return;
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    if (state.app.anime.result_count != 0) return; // a fetch beat us under the lock
    var i: usize = 0;
    while (i < n and i < state.app.anime.results.len) : (i += 1) {
        state.app.anime.results[i] = deserializeAnime(&r) orelse break;
    }
    state.app.anime.result_count = i;
}

const GridJob = struct {
    generation: u32,
    page: u32,
    mode: state.AnimeMode,
    sfw: bool,
    trend: TrendFilter,
    url: [512]u8 = undefined,
    url_len: usize = 0,
    fallback: [256]u8 = undefined,
    fallback_len: usize = 0,
};
fn gridJob(generation: u32, mode: state.AnimeMode, page: u32) ?GridJob {
    var job = GridJob{ .generation = generation, .page = page, .mode = mode, .sfw = state.app.nsfw_filter_enabled, .trend = trend_filter };
    const url = buildGridUrl(&job.url, mode, page) orelse return null;
    job.url_len = url.len;
    if (mode == .trending and trend_filter.jikan().len > 0) {
        const fallback = std.fmt.bufPrint(&job.fallback, "https://api.jikan.moe/v4/top/anime?limit=25&page={d}{s}", .{ page, anime_pure.sfwSuffix(job.sfw) }) catch return null;
        job.fallback_len = fallback.len;
    }
    return job;
}
fn beginCatalogRequest() u32 {
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    const generation = search_request.begin(&state.app.anime.is_loading);
    grid_loading_more.store(false, .release);
    relations_request.cancel(&relations_busy);
    return generation;
}

pub fn loadTrendingAnime() void {

    // Don't clear result_count here — parseJikanData repopulates and sets the
    // count after the fetch, so a stale-refresh keeps old cards on screen.
    state.app.anime.selected_idx = null;
    cancelPlayback();
    episode_request.cancel(&state.app.anime.episodes_loading);
    state.app.anime.episode_count = 0;
    state.app.anime.last_fetch_s = @import("browse_cache.zig").now(); // SWR stamp
    grid_page = 1; // restart infinite-scroll pagination
    more_available.store(false, .release);
    has_loaded_trending = true;
    // Trending owns the global generation too, so a stale in-flight search
    // worker won't overwrite freshly-loaded trending cards.
    const my_gen = beginCatalogRequest();

    // The Lists chip swaps the source: same grid, same results[], different fetch.
    if (usesLists()) {
        workers.spawn(listsThread, .{my_gen}) catch {
            search_request.finish(my_gen, &state.app.anime.is_loading);
            return;
        };
        return;
    }

    const job = gridJob(my_gen, .trending, 1) orelse {
        search_request.finish(my_gen, &state.app.anime.is_loading);
        return;
    };
    workers.spawn(trendingThread, .{job}) catch {
        search_request.finish(my_gen, &state.app.anime.is_loading);
        return;
    };
}

// ══════════════════════════════════════════════════════════
// `lists` source plugin — anime index from debpalash/opal-plugins (lists/)
// ══════════════════════════════════════════════════════════
//
// ENDPOINT: this is a METADATA source, so it ships with a working default and an
// installed `lists` plugin merely OVERRIDES it (mirroring how the plugin contract
// in plugin_repo.zig / source_config.zig works elsewhere).
//
// It was originally gated behind a plugin install like a torrent index, which was
// a misreading of the neutrality rule: that rule exists to keep INFRINGING
// endpoints out of the binary, and the two other anime metadata APIs — Jikan
// (api.jikan.moe, just above) and AniList (anilist.zig) — are both hardcoded for
// exactly that reason. The airing index is the same class of thing: public
// AniList/MAL/AniDB id mappings and cover URLs, nothing infringing. Gating it only
// meant the chip silently rendered nothing, since no plugin ships installed.
//
// The repo serves `anime-airing.json`: ~316 currently-airing shows with AniList/
// MAL/AniDB ids, titles, a cover URL and the next episode's number + air date.
// Parsing lives in anime_lists_pure.zig (tested against the real bytes); this
// file only fetches, caches and publishes into the same state.app.anime.results[]
// the Jikan grid uses — so cards, posters, episode lists and watch tracking all
// work unchanged (rows carry a MAL id, which is the index's primary key).
//
// Cache: the fetched JSON is stored as a blob in the shared poster_cache table
// keyed by its URL (core/poster.zig cacheStoreForUrl — a generic url→bytes disk
// cache), with the fetch time in the `config` kv table. On launch the cached copy
// paints the grid with NO network call; the repo is only re-fetched once the
// stamp is older than LISTS_TTL_S. Same stale-while-revalidate shape as
// browse_cache.zig, just a longer TTL — the upstream repo regenerates daily.

const lists_pure = @import("anime_lists_pure.zig");

/// The airing feed is regenerated upstream about once a day; a 6h TTL keeps the
/// next-episode dates honest without hammering raw.githubusercontent.
const LISTS_TTL_S: i64 = 6 * 60 * 60;
const LISTS_STAMP_KEY = "anime_lists_fetched_at";
/// Hard cap on the download. The live file is ~102 KB; 4 MB is pure headroom and
/// bounds a hostile/mistargeted endpoint. Heap-allocated — never on the worker's
/// stack (CLAUDE.md: >64 KB stack buffers overflow a spawned thread).
const LISTS_MAX_BYTES: usize = 4 * 1024 * 1024;

/// Built-in default. An installed `lists` plugin overrides it (see listsBase).
// The id-mapping data was consolidated from debpalash/lists into the
// opal-plugins repo (lists/ subdir); the old repo is an archived mirror.
const LISTS_DEFAULT_BASE = "https://raw.githubusercontent.com/debpalash/opal-plugins/main/lists";

/// The installed plugin's endpoint if there is one, else the built-in default.
///
/// Never null, so the Lists chip always renders and always has data. It used to
/// return the raw source_config lookup, which is null on any machine without the
/// plugin installed — i.e. every machine — so the chip was permanently hidden.
fn listsBase() ?[]const u8 {
    if (@import("../core/source_config.zig").get("lists", "base")) |b| {
        if (b.len > 0) return b;
    }
    return LISTS_DEFAULT_BASE;
}

/// `<base>/anime-airing.json` for the installed endpoint, or null when inert.
fn listsUrl(out: []u8) ?[]const u8 {
    const base = listsBase() orelse return null;
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.bufPrint(out, "{s}/anime-airing.json", .{trimmed}) catch null;
}

/// db.zig hands out raw sqlite statements; every other caller serializes its own
/// access (see poster.zig's cache_lock). These two touch the `config` kv table
/// from the fetch worker, so they need the same treatment.
var lists_stamp_lock: @import("../core/sync.zig").Mutex = .{};

fn listsStampGet() i64 {
    const db = @import("../core/db.zig");
    lists_stamp_lock.lock();
    defer lists_stamp_lock.unlock();
    const stmt = db.prepare("SELECT value FROM config WHERE key = ?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, LISTS_STAMP_KEY);
    if (db.step(stmt) == db.c.SQLITE_ROW) {
        if (db.columnText(stmt, 0)) |v| return std.fmt.parseInt(i64, v, 10) catch 0;
    }
    return 0;
}

fn listsStampSet(ts: i64) void {
    const db = @import("../core/db.zig");
    lists_stamp_lock.lock();
    defer lists_stamp_lock.unlock();
    const stmt = db.prepare("INSERT OR REPLACE INTO config (key, value) VALUES (?1, ?2)") orelse return;
    defer db.finalize(stmt);
    var vb: [24]u8 = undefined;
    const v = std.fmt.bufPrint(&vb, "{d}", .{ts}) catch return;
    db.bindText(stmt, 1, LISTS_STAMP_KEY);
    db.bindText(stmt, 2, v);
    _ = db.step(stmt);
}

/// Fetch worker for the Lists chip. Cache-first: a cached payload paints the grid
/// before any network work, and the repo is only re-fetched when the stamp is
/// stale (or there's no cache at all). A failed refresh leaves the cached grid up.
fn listsThread(my_gen: u32) void {
    defer search_request.finish(my_gen, &state.app.anime.is_loading);

    var url_buf: [512]u8 = undefined;
    const url = listsUrl(&url_buf) orelse return; // uninstalled mid-flight → inert

    // ── 1. Cached payload → paint immediately, no network. ──
    var have_cached = false;
    if (poster.cacheLoadForUrl(url)) |cb| {
        defer poster.cacheFreeEncoded(cb); // c_allocator-owned — never the global one
        have_cached = true;
        if (publishListsJson(cb, my_gen) > 0) {
            logs.pushLog("info", "anime", "Lists loaded (cached)", false);
        }
    }

    const stamp = listsStampGet();
    const stale = stamp <= 0 or (@import("browse_cache.zig").now() - stamp) >= LISTS_TTL_S;
    if (have_cached and !stale) return; // fresh cache — done, zero requests

    // ── 2. Refresh from the plugin's endpoint. ──
    const buf = alloc.alloc(u8, LISTS_MAX_BYTES) catch {
        if (!have_cached) logs.pushLog("error", "anime", "Lists: response allocation failed", true);
        return;
    };
    defer alloc.free(buf);
    const argv = [_][]const u8{ "curl", "-sL", "-A", agent, "--max-time", "20", url };
    const body = boundedSearchCurl(&argv, buf, 22_000, my_gen) orelse {
        if (!have_cached) logs.pushLog("error", "anime", "Lists: bounded fetch failed", true);
        return;
    };

    // Empty / error page → keep whatever the cache already put on screen.
    if (body.len < 32) {
        if (!have_cached) logs.pushLog("error", "anime", "Lists: empty response", true);
        return;
    }
    // Superseded by a newer fetch (mode switch, chip change) while we were in curl.
    if (search_request.current() != my_gen) return;

    const json = body;
    const n = publishListsJson(json, my_gen);
    if (n == 0) {
        if (!have_cached) logs.pushLog("error", "anime", "Lists: no usable entries", true);
        return;
    }

    // Only cache a payload that actually parsed — never poison the cache with an
    // error page. Store the bytes, then the stamp (a store failure just means the
    // next launch refetches).
    poster.cacheStoreForUrl(url, json, 0, 0);
    listsStampSet(@import("browse_cache.zig").now());

    var lb: [64]u8 = undefined;
    logs.pushLog("info", "anime", std.fmt.bufPrintZ(&lb, "Lists loaded ({d} airing)", .{n}) catch "Lists loaded", false);
}

/// Parse a lists payload and publish it into the anime grid. Returns rows shown.
///
/// Shares state.app.anime.results[] with the Jikan parser, so it takes the SAME
/// anime_parse_mutex and re-checks the generation under it: two workers must never
/// both read-then-null the same poster_tex (double textureDestroyLater → SIGABRT,
/// see parseJikanDataEx's header).
fn publishListsJson(json: []const u8, my_gen: u32) usize {
    if (search_request.current() != my_gen) return 0; // cheap pre-check, before the alloc

    // 100 Items ≈ 34 KB — heap, not the worker's stack.
    const items = alloc.alloc(lists_pure.Item, state.app.anime.results.len) catch return 0;
    defer alloc.free(items);

    const n = lists_pure.parseAiring(alloc, json, state.app.nsfw_filter_enabled, items);
    if (n == 0) return 0;

    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    if (search_request.current() != my_gen) return 0; // re-check under the lock

    // Lists cards are not scraper cards.
    results_are_scraper = false;

    // Fresh load: retire the old cards' poster textures (UI-thread work → queue).
    for (0..state.app.anime.results.len) |i| {
        state.app.anime.results[i].poster_fetching = false;
        state.app.anime.results[i].expanded = false;
        if (state.app.anime.results[i].poster_tex) |tex| {
            queueTexFree(tex);
            state.app.anime.results[i].poster_tex = null;
        }
    }
    for (0..state.app.anime.broadcast_lens.len) |i| state.app.anime.broadcast_lens[i] = 0;

    for (items[0..n], 0..) |src, i| {
        const item = &state.app.anime.results[i];
        @memcpy(item.id[0..src.mal_id_len], src.mal_id[0..src.mal_id_len]);
        item.id_len = src.mal_id_len;
        @memcpy(item.name[0..src.title_len], src.title[0..src.title_len]);
        item.name_len = src.title_len;
        @memcpy(item.poster_url[0..src.poster_url_len], src.poster_url[0..src.poster_url_len]);
        item.poster_url_len = src.poster_url_len;
        item.episodes = src.episodes;
        // The source carries no score or synopsis — left empty on purpose so the
        // AniList enrichment below (which only fills blanks) supplies both.
        item.score = 0;
        item.overview_len = 0;
        item.poster_attempted = false;
        item.poster_failed = false;

        // Next-episode badge → the broadcast[] parallel array the cards already read.
        if (i < state.app.anime.broadcast.len and src.badge_len > 0) {
            const bl = @min(src.badge_len, state.app.anime.broadcast[i].len);
            @memcpy(state.app.anime.broadcast[i][0..bl], src.badge[0..bl]);
            state.app.anime.broadcast_lens[i] = bl;
        }
    }

    state.app.anime.result_count = n;
    more_available.store(false, .release); // single payload — nothing to page
    spawnAniListEnrich(my_gen); // fills score + synopsis (additive; never overwrites)
    return n;
}

/// GET `url` into `buf`; returns bytes read (0 on failure). The bounded process
/// seam drains stdout while curl runs, enforces the caller's output capacity,
/// and terminates/reaps the whole tree if curl or an inheriting descendant
/// wedges. This replaces the former predictable on-disk staging file.
fn jikanGet(url: []const u8, buf: []u8, my_gen: u32) usize {
    const argv = [_][]const u8{
        "curl", "-s", "--connect-timeout", "3", "--max-time", "10", "-A", agent, url,
    };
    const body = boundedSearchCurl(&argv, buf, 12_000, my_gen) orelse return 0;
    return body.len;
}

fn trendingThread(job: GridJob) void {
    const my_gen = job.generation;
    defer search_request.finish(my_gen, &state.app.anime.is_loading);

    const arg1 = job.url[0..job.url_len];
    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);

    var bytes = jikanGet(arg1, buf, my_gen);
    var added = if (bytes > 0) parseJikanData(buf[0..bytes], my_gen) else 0;

    // Jikan's /top/anime?filter=… frequently 504s ("failed to connect to
    // MyAnimeList") while the UNFILTERED /top/anime and /seasons stay up — which
    // left the DEFAULT (airing) trending view permanently blank. When a filtered
    // fetch yields nothing, fall back to the unfiltered top list so the grid is
    // never empty. Only fires when a filter was actually used and we're still current.
    if (added == 0 and job.fallback_len > 0 and search_request.current() == my_gen) {
        const fb = job.fallback[0..job.fallback_len];
        const fb_bytes = jikanGet(fb, buf, my_gen);
        if (fb_bytes > 0) {
            added = parseJikanData(buf[0..fb_bytes], my_gen);
            bytes = fb_bytes;
            logs.pushLog("warn", "anime", "Jikan filtered top unavailable — showing overall top", false);
        }
    }

    if (bytes == 0) return;
    if (search_request.current() == my_gen) {
        more_available.store(parsePagination(buf[0..bytes]), .release);
        // SWR write: persist the fresh page-1 Trending grid so the next cold
        // start seeds instantly. Only the latest generation (still current)
        // persists — a superseded worker never poisons the cache.
        if (job.page == 1 and added > 0) putTrendingCache();
    }
    logs.pushLog("info", "anime", "Trending loaded (Jikan API)", false);
}

pub fn searchAnime(query: []const u8) void {
    if (query.len == 0) return;
    state.app.anime.mode = .search;
    fetched_mode = .search;
    // NOTE: do NOT early-return on is_loading. Live-search supersedes an
    // in-flight fetch: we bump the generation so the older worker's results
    // are dropped, and the search_query_buf is overwritten for the new fetch.
    // (Worst case two curl workers run briefly; the stale one self-discards.)

    // Don't clear result_count — keep prior cards visible until new results
    // arrive (no flicker). The new generation guards against stale publishes.
    state.app.anime.selected_idx = null;
    cancelPlayback();
    episode_request.cancel(&state.app.anime.episodes_loading);
    state.app.anime.episode_count = 0;

    // New generation for this search; the worker captures and re-checks it.
    const my_gen = beginCatalogRequest();
    grid_page = 1; // restart infinite-scroll pagination
    more_available.store(false, .release);

    // Keep the query for pagination and hand this worker an immutable copy.
    const safe_len = @min(query.len, search_query_buf.len);
    anime_query_mutex.lock();
    @memcpy(search_query_buf[0..safe_len], query[0..safe_len]);
    search_query_len = safe_len;
    anime_query_mutex.unlock();
    var job: SearchJob = .{ .generation = my_gen, .query_len = safe_len, .sfw = state.app.nsfw_filter_enabled, .page = grid_page };
    @memcpy(job.query[0..safe_len], query[0..safe_len]);
    @memcpy(state.app.anime.search_buf[0..safe_len], job.query[0..safe_len]);
    @memset(state.app.anime.search_buf[safe_len..], 0);

    // Site-framework source installed → search the site's own catalog instead of
    // Jikan (source_config-gated; INERT by default). See the DooPlay/AnimeStream
    // section below.
    if (activeScraper() != .none) {
        workers.spawn(scraperSearchThread, .{job}) catch {
            search_request.finish(my_gen, &state.app.anime.is_loading);
        };
        return;
    }

    workers.spawn(searchThread, .{job}) catch {
        search_request.finish(my_gen, &state.app.anime.is_loading);
    };
}

var search_query_buf: [256]u8 = undefined;
var search_query_len: usize = 0;
var anime_query_mutex: @import("../core/sync.zig").Mutex = .{};

const SearchJob = struct {
    generation: u32,
    query: [256]u8 = undefined,
    query_len: usize = 0,
    sfw: bool = true,
    page: u32 = 1,
};

fn searchThread(job: SearchJob) void {
    const my_gen = job.generation;
    defer search_request.finish(my_gen, &state.app.anime.is_loading);
    const query = job.query[0..job.query_len];

    const jikan_api = "https://api.jikan.moe/v4/anime";

    var enc_buf: [768]u8 = undefined;
    var enc_len: usize = 0;
    for (query) |c| {
        if (enc_len + 3 > enc_buf.len) break;
        const pct: ?[2]u8 = switch (c) {
            '%' => .{ '2', '5' },
            ' ' => .{ '2', '0' },
            '&' => .{ '2', '6' },
            '=' => .{ '3', 'D' },
            '#' => .{ '2', '3' },
            '?' => .{ '3', 'F' },
            '+' => .{ '2', 'B' },
            else => null,
        };
        if (pct) |hex| {
            enc_buf[enc_len] = '%';
            enc_buf[enc_len + 1] = hex[0];
            enc_buf[enc_len + 2] = hex[1];
            enc_len += 3;
        } else {
            enc_buf[enc_len] = c;
            enc_len += 1;
        }
    }

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}?q={s}&limit=25&page={d}{s}", .{ jikan_api, enc_buf[0..enc_len], job.page, anime_pure.sfwSuffix(job.sfw) }) catch return;

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const argv = [_][]const u8{
        "curl", "-s", "--connect-timeout", "3", "--max-time", "10", "-A", agent, url,
    };
    if (boundedSearchCurl(&argv, buf, 12_000, my_gen)) |body| {
        if (body.len > 0) {
            const added = parseJikanData(body, my_gen);
            if (added > 0) {
                if (search_request.current() == my_gen) more_available.store(parsePagination(body), .release);
                logs.pushLog("info", "anime", "Search done (Jikan API)", false);
                return;
            }
        }
    }

    // Jikan can return an HTTP-success JSON error when its MyAnimeList backend
    // is unavailable. A zero-row response used to clear the visible grid and
    // report success. AniList is independent and provides the same identifiers
    // needed by our existing Jikan episode path, so use it as a bounded fallback.
    if (search_request.current() != my_gen) return;
    const bytes = anilist.fetchSearchWithCancellation(query, job.sfw, buf, searchEpoch(my_gen));
    if (bytes > 0 and publishAniListSearch(buf[0..bytes], my_gen) > 0) {
        more_available.store(false, .release);
        logs.pushLog("info", "anime", "Search done (AniList fallback)", false);
    } else {
        logs.pushLog("warn", "anime", "Anime search returned no results", false);
    }
}

/// Publish a keyless AniList Page.media response into the existing anime grid.
/// Only rows with a MAL id are usable because episode discovery is backed by
/// Jikan. This shares the same lock and generation gate as the primary parser.
fn publishAniListSearch(json: []const u8, my_gen: u32) usize {
    return appendAniListPage(json, my_gen, 0);
}

fn appendAniListPage(json: []const u8, my_gen: u32, start_offset: usize) usize {
    const media = anime_pure.anilistCatalogBody(alloc, json) orelse return 0;
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    if (search_request.current() != my_gen) return 0;

    if (start_offset == 0) {
        for (0..state.app.anime.results.len) |i| {
            const old = &state.app.anime.results[i];
            old.poster_fetching = false;
            old.expanded = false;
            if (old.poster_tex) |tex| {
                queueTexFree(tex);
                old.poster_tex = null;
            }
        }
        for (0..state.app.anime.broadcast_lens.len) |i| state.app.anime.broadcast_lens[i] = 0;
        results_are_scraper = false;
    }

    var iter = anilist_pure.Iter{ .json = media };
    var count: usize = start_offset;
    while (iter.next()) |m| {
        if (count >= state.app.anime.results.len) break;
        if (m.id_mal <= 0) continue;
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{d}", .{m.id_mal}) catch continue;
        var duplicate = false;
        for (state.app.anime.results[0..count]) |existing| {
            if (std.mem.eql(u8, existing.id[0..existing.id_len], id)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const title = if (m.title_english.len > 0) m.title_english else m.title_romaji;
        if (title.len == 0) continue;

        const item = &state.app.anime.results[count];
        @memcpy(item.id[0..id.len], id);
        item.id_len = id.len;
        item.anilist_id = m.id;
        item.name_len = decodeJsonEscapes(title, &item.name);
        item.episodes = m.episodes;
        item.name_english_len = decodeJsonEscapes(m.title_romaji, &item.name_english);
        item.score = m.score10;
        item.overview_len = decodeJsonEscapes(m.description, &item.overview);
        item.poster_url_len = decodeJsonEscapes(m.cover, &item.poster_url);
        item.atype_len = 0;
        item.year = m.year;
        item.airing = false;
        item.expanded = false;
        item.poster_fetching = false;
        item.poster_attempted = false;
        item.poster_failed = false;
        item.poster_tex = null;
        count += 1;
    }

    if (search_request.current() != my_gen) return 0;
    state.app.anime.result_count = count;
    return count - start_offset;
}

// ══════════════════════════════════════════════════════════
// Seasonal mode (/seasons/now, /seasons/{year}/{season}, /seasons/upcoming)
// ══════════════════════════════════════════════════════════

/// Kick a seasonal fetch for the current season_sel / season_year. Reuses the
/// shared results[]/generation machinery (parseJikanData publishes the cards).
pub fn loadSeasonal() void {
    state.app.anime.selected_idx = null;
    cancelPlayback();
    episode_request.cancel(&state.app.anime.episodes_loading);
    state.app.anime.episode_count = 0;
    state.app.anime.last_fetch_s = @import("browse_cache.zig").now();
    grid_page = 1; // restart infinite-scroll pagination
    more_available.store(false, .release);
    const my_gen = beginCatalogRequest();

    const job = gridJob(my_gen, .seasonal, 1) orelse {
        search_request.finish(my_gen, &state.app.anime.is_loading);
        return;
    };
    workers.spawn(seasonalThread, .{job}) catch {
        search_request.finish(my_gen, &state.app.anime.is_loading);
        return;
    };
}

fn seasonalThread(job: GridJob) void {
    const my_gen = job.generation;
    defer search_request.finish(my_gen, &state.app.anime.is_loading);

    const url = job.url[0..job.url_len];
    const argv = [_][]const u8{ "curl", "-s", "--connect-timeout", "3", "-A", agent, "--max-time", "10", url };

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const body = boundedSearchCurl(&argv, buf, 12_000, my_gen) orelse return;
    if (body.len == 0) return;
    _ = parseJikanData(body, my_gen);
    if (search_request.current() == my_gen) more_available.store(parsePagination(body), .release);
    logs.pushLog("info", "anime", "Seasonal loaded (Jikan API)", false);
}

// ══════════════════════════════════════════════════════════
// Calendar mode (/schedules?filter={day}) — same anime shape + broadcast.string
// ══════════════════════════════════════════════════════════

pub fn loadCalendar() void {
    state.app.anime.selected_idx = null;
    cancelPlayback();
    episode_request.cancel(&state.app.anime.episodes_loading);
    state.app.anime.episode_count = 0;
    state.app.anime.last_fetch_s = @import("browse_cache.zig").now();
    grid_page = 1; // restart infinite-scroll pagination
    more_available.store(false, .release);
    const my_gen = beginCatalogRequest();

    const job = gridJob(my_gen, .calendar, 1) orelse {
        search_request.finish(my_gen, &state.app.anime.is_loading);
        return;
    };
    workers.spawn(calendarThread, .{job}) catch {
        search_request.finish(my_gen, &state.app.anime.is_loading);
        return;
    };
}

fn calendarThread(job: GridJob) void {
    const my_gen = job.generation;
    defer search_request.finish(my_gen, &state.app.anime.is_loading);

    const url = job.url[0..job.url_len];
    const argv = [_][]const u8{ "curl", "-s", "--connect-timeout", "3", "-A", agent, "--max-time", "10", url };

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const body = boundedSearchCurl(&argv, buf, 12_000, my_gen) orelse return;
    if (body.len == 0) return;
    // parseJikanData handles the cards; pass with_broadcast so it also extracts
    // each item's broadcast.string into anime.broadcast[] (aligned to index).
    _ = parseJikanDataEx(body, my_gen, true, 0);
    if (search_request.current() == my_gen) more_available.store(parsePagination(body), .release);
    logs.pushLog("info", "anime", "Calendar loaded (Jikan API)", false);
}

/// Decode common JSON string escapes (\" \\ \/ \n \r \t \b \f \uXXXX) from
/// `src` into `dst`, returning the number of bytes written. Bounded by dst.len.
/// Anything that isn't a recognized escape is copied verbatim (the backslash is
/// kept) so we never silently corrupt content.
fn decodeJsonEscapes(src: []const u8, dst: []u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < dst.len) {
        const ch = src[i];
        if (ch != '\\' or i + 1 >= src.len) {
            dst[out] = ch;
            out += 1;
            i += 1;
            continue;
        }
        const esc = src[i + 1];
        switch (esc) {
            '"' => {
                dst[out] = '"';
                out += 1;
                i += 2;
            },
            '\\' => {
                dst[out] = '\\';
                out += 1;
                i += 2;
            },
            '/' => {
                dst[out] = '/';
                out += 1;
                i += 2;
            },
            'n' => {
                dst[out] = '\n';
                out += 1;
                i += 2;
            },
            'r' => {
                dst[out] = '\r';
                out += 1;
                i += 2;
            },
            't' => {
                dst[out] = '\t';
                out += 1;
                i += 2;
            },
            'b' => {
                dst[out] = 0x08;
                out += 1;
                i += 2;
            },
            'f' => {
                dst[out] = 0x0c;
                out += 1;
                i += 2;
            },
            'u' => {
                // \uXXXX — decode 4 hex digits to a codepoint, then UTF-8 encode.
                if (i + 6 <= src.len) {
                    if (std.fmt.parseInt(u21, src[i + 2 .. i + 6], 16)) |cp| {
                        var utf8_buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch 0;
                        if (n > 0 and out + n <= dst.len) {
                            @memcpy(dst[out .. out + n], utf8_buf[0..n]);
                            out += n;
                        }
                        i += 6;
                    } else |_| {
                        // Malformed — keep the backslash and continue.
                        dst[out] = '\\';
                        out += 1;
                        i += 1;
                    }
                } else {
                    dst[out] = '\\';
                    out += 1;
                    i += 1;
                }
            },
            else => {
                // Unknown escape — preserve the backslash verbatim.
                dst[out] = '\\';
                out += 1;
                i += 1;
            },
        }
    }
    return out;
}

fn parseJikanData(json: []const u8, my_gen: u32) usize {
    return parseJikanDataEx(json, my_gen, false, 0);
}

/// `with_broadcast` (Calendar mode): additionally pull each item's
/// broadcast.string into state.app.anime.broadcast[count] (≤39 chars), aligned
/// to the same result index, so the card meta row can show an airtime badge.
///
/// `start` is the index to begin writing at. `start == 0` is a fresh load: we
/// clear ALL old cards (queueing their poster textures for the UI thread to
/// free) and wipe the broadcast badges. `start > 0` is the infinite-scroll
/// APPEND path: we keep the already-shown cards (and their live textures)
/// untouched, write new rows at [start..), DEDUPE each candidate by mal_id
/// against rows [0..count), and return how many rows were actually added.
/// Serializes the whole parse so two concurrent workers (fast typing spawns
/// overlapping search workers; the remote API thread can spawn another) can never
/// both write state.app.anime.results[]/result_count or both read-then-null the
/// same item.poster_tex — the latter would queueTexFree the same GPU texture
/// twice → double dvui.textureDestroyLater → SIGABRT (see file header).
var anime_parse_mutex: @import("../core/sync.zig").Mutex = .{};

pub fn resultCount() usize {
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    return @min(state.app.anime.result_count, state.app.anime.results.len);
}

pub fn hasMoreGrid() bool {
    return more_available.load(.acquire) and resultCount() < state.app.anime.results.len;
}

pub fn isLoadingMoreGrid() bool {
    return grid_loading_more.load(.acquire);
}

pub fn resultRow(idx: usize) ?state.AnimeResult {
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    if (idx >= state.app.anime.result_count or idx >= state.app.anime.results.len) return null;
    return state.app.anime.results[idx];
}

fn parseJikanDataEx(json: []const u8, my_gen: u32, with_broadcast: bool, start_offset: usize) usize {
    // Validate before touching the cached grid. HTTP-success upstream errors
    // and truncated bodies must leave usable rows available for fallback.
    const data = anime_pure.jikanCatalogBody(alloc, json) orelse return 0;
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();

    // Drop stale results: if a newer search/trending load fired while we were
    // in-flight, this generation is no longer the latest — discard silently so
    // fast typing never shows out-of-order results, and we don't clobber the
    // newer fetch's cards/textures. (Re-checked here under the lock so a worker
    // that waited on the mutex sees the latest generation.)
    if (search_request.current() != my_gen) return 0;

    var count: usize = start_offset;
    var pos: usize = 0;

    if (start_offset == 0) {
        // Fresh load — clear old result states including poster textures. On the
        // APPEND path we must NOT touch existing cards' textures (they're still
        // on screen), so this whole reset is gated on start == 0.
        for (0..state.app.anime.results.len) |i| {
            state.app.anime.results[i].poster_fetching = false;
            state.app.anime.results[i].expanded = false;
            if (state.app.anime.results[i].poster_tex) |tex| {
                queueTexFree(tex); // worker thread — defer the dvui destroy to the UI thread
                state.app.anime.results[i].poster_tex = null;
            }
        }
        // Clear broadcast badges (only Calendar repopulates them; other modes
        // leave them zeroed so no stale airtime shows on a Trending card).
        for (0..state.app.anime.broadcast_lens.len) |i| state.app.anime.broadcast_lens[i] = 0;
        // Jikan cards are not scraper cards → route episodes/play to the Jikan path.
        results_are_scraper = false;
    }

    while (pos < data.len and count < state.app.anime.results.len) {
        // Each Jikan row starts with mal_id. Find its enclosing object end with
        // balanced JSON scanning so nested producer/genre mal_ids cannot split
        // a card before its rating or genres.
        const id_idx = std.mem.indexOf(u8, data[pos..], "\"mal_id\":") orelse break;
        pos += id_idx + 9;
        const obj_open = std.mem.lastIndexOfScalar(u8, data[0..pos], '{') orelse break;
        const obj_end = anime_pure.jsonObjectEnd(data, obj_open) orelse break;
        const obj_slice = data[pos..obj_end];
        // Advance before any rejection: producer/genre objects contain their
        // own mal_id fields and must never become cards when a row is skipped.
        pos = obj_end;

        // NSFW filter (Settings › Behavior): drop adult ratings and explicit
        // Ecchi/Erotica/Hentai genres, including cached responses.
        if (state.app.nsfw_filter_enabled and anime_pure.jikanRatingIsAdult(obj_slice)) continue;

        // Extract ID
        var id_str: []const u8 = "0";
        var num_end: usize = 0;
        while (num_end < obj_slice.len and obj_slice[num_end] >= '0' and obj_slice[num_end] <= '9') : (num_end += 1) {}
        // Clamp to the id buffer up front so every downstream use (dedupe compare
        // + the @memcpy below) is bounds-safe. A malformed/oversized digit-run in
        // the raw JSON must never trip a slice-bounds panic on this worker thread
        // (worker panics abort the whole app — see Opal crash 2026-06-26 00:04).
        if (num_end > 0) id_str = obj_slice[0..@min(num_end, state.app.anime.results[0].id.len)];

        // Extract Title
        var name_str: []const u8 = "";
        if (std.mem.indexOf(u8, obj_slice, "\"title\":\"")) |title_idx| {
            const start = title_idx + 9;
            var in_esc = false;
            var end: usize = start;
            while (end < obj_slice.len) : (end += 1) {
                if (in_esc) {
                    in_esc = false;
                } else if (obj_slice[end] == '\\') {
                    in_esc = true;
                } else if (obj_slice[end] == '"') {
                    break;
                }
            }
            if (end < obj_slice.len) name_str = obj_slice[start..end];
        }

        // Extract Title English (optional fallback)
        if (name_str.len == 0) {
            if (std.mem.indexOf(u8, obj_slice, "\"title_english\":\"")) |title_idx| {
                const start = title_idx + 17;
                var in_esc = false;
                var end: usize = start;
                while (end < obj_slice.len) : (end += 1) {
                    if (in_esc) {
                        in_esc = false;
                    } else if (obj_slice[end] == '\\') {
                        in_esc = true;
                    } else if (obj_slice[end] == '"') {
                        break;
                    }
                }
                if (end < obj_slice.len) name_str = obj_slice[start..end];
            }
        }

        // Extract Episodes
        var ep_count: u16 = 0;
        if (std.mem.indexOf(u8, obj_slice, "\"episodes\":")) |ep_idx| {
            const num_st = ep_idx + 11;
            if (num_st < obj_slice.len and obj_slice[num_st] >= '0' and obj_slice[num_st] <= '9') {
                var ne = num_st;
                while (ne < obj_slice.len and obj_slice[ne] >= '0' and obj_slice[ne] <= '9') : (ne += 1) {}
                if (ne > num_st) ep_count = std.fmt.parseInt(u16, obj_slice[num_st..ne], 10) catch 0;
            }
        }

        // Extract Poster URL
        var poster_url: []const u8 = "";
        if (std.mem.indexOf(u8, obj_slice, "\"large_image_url\":\"")) |img_idx| {
            const start = img_idx + 19;
            var end = start;
            while (end < obj_slice.len and obj_slice[end] != '"') : (end += 1) {}
            if (end < obj_slice.len) poster_url = obj_slice[start..end];
        }

        // Extract Synopsis
        var synopsis: []const u8 = "";
        if (std.mem.indexOf(u8, obj_slice, "\"synopsis\":\"")) |syn_idx| {
            const start = syn_idx + 12;
            var in_esc = false;
            var end: usize = start;
            while (end < obj_slice.len) : (end += 1) {
                if (in_esc) {
                    in_esc = false;
                } else if (obj_slice[end] == '\\') {
                    in_esc = true;
                } else if (obj_slice[end] == '"') {
                    break;
                }
            }
            if (end < obj_slice.len) synopsis = obj_slice[start..end];
        }

        // Extract Score
        var score: f32 = 0.0;
        if (std.mem.indexOf(u8, obj_slice, "\"score\":")) |sc_idx| {
            const start = sc_idx + 8;
            if (start < obj_slice.len and ((obj_slice[start] >= '0' and obj_slice[start] <= '9') or obj_slice[start] == '.')) {
                var end = start;
                while (end < obj_slice.len and ((obj_slice[end] >= '0' and obj_slice[end] <= '9') or obj_slice[end] == '.')) : (end += 1) {}
                if (end > start) score = std.fmt.parseFloat(f32, obj_slice[start..end]) catch 0.0;
            }
        }

        // Detail-header metadata (type / year / airing) via the tested pure
        // helper so the shipped extraction IS the tested extraction.
        const meta = anime_pure.parseJikanMeta(obj_slice);

        // Dedupe by mal_id against rows already committed [0..count). Jikan can
        // repeat entries across pages (and the broadcast schedule list groups by
        // day), so without this the same card could appear twice on append.
        var is_dup = false;
        if (num_end > 0) {
            var d: usize = 0;
            while (d < count) : (d += 1) {
                const ex = &state.app.anime.results[d];
                if (ex.id_len == id_str.len and std.mem.eql(u8, ex.id[0..ex.id_len], id_str)) {
                    is_dup = true;
                    break;
                }
            }
        }

        if (!is_dup and name_str.len > 0 and name_str.len <= 128) {
            var item = &state.app.anime.results[count];
            @memcpy(item.id[0..id_str.len], id_str);
            item.id_len = id_str.len;

            // Decode JSON escapes in name (\" \\ \/ \n \t \uXXXX, etc.)
            item.name_len = decodeJsonEscapes(name_str, &item.name);
            item.episodes = ep_count;
            item.name_english_len = 0;
            if (std.json.parseFromSlice(std.json.Value, alloc, data[obj_open..obj_end], .{})) |doc| {
                defer doc.deinit();
                animeCopyField(&item.name_english, &item.name_english_len, catalog.string(catalog.field(doc.value, "title_english")));
            } else |_| {}

            item.score = score;

            // Decode JSON escapes (Jikan escapes the URL slashes as "\/", which
            // makes std.Uri.parse reject it → posters never fetched). Must run
            // through decodeJsonEscapes just like the name/synopsis.
            item.poster_url_len = decodeJsonEscapes(poster_url, &item.poster_url);

            // Decode JSON escapes in synopsis (\" \\ \/ \n \t \uXXXX, etc.)
            item.overview_len = decodeJsonEscapes(synopsis, &item.overview);

            // Detail-header metadata (routed through anime_pure.parseJikanMeta).
            animeCopyField(&item.atype, &item.atype_len, meta.atype);
            item.year = meta.year;
            item.airing = meta.airing;

            item.poster_fetching = false;
            // This row is being repurposed for a different anime, so its poster
            // lifecycle resets with it (as the Lists and scraper parsers already
            // do). Retiring the texture WITHOUT clearing attempted/failed leaves
            // the row reading as "tried and failed" to posterAction, which then
            // blanks the card permanently — that is what emptied the grid on
            // every SWR revalidate: the cache seed's posters loaded, then this
            // reparse retired their textures and latched them dead. See the
            // regression test in anime_pure.zig.
            item.poster_attempted = false;
            item.poster_failed = false;
            if (item.poster_tex) |tx| {
                queueTexFree(tx); // worker thread — defer the dvui destroy to the UI thread
            }
            item.poster_tex = null;
            item.expanded = false;

            // Calendar: extract broadcast.string ("Mondays at 01:00 (JST)").
            if (with_broadcast and count < state.app.anime.broadcast.len) {
                if (std.mem.indexOf(u8, obj_slice, "\"broadcast\":")) |b_idx| {
                    const bscope = obj_slice[b_idx..];
                    if (std.mem.indexOf(u8, bscope, "\"string\":\"")) |s_idx| {
                        const start = s_idx + 10;
                        var end = start;
                        while (end < bscope.len and bscope[end] != '"' and bscope[end] != '\\') : (end += 1) {}
                        if (end > start and end < bscope.len) {
                            const blen = @min(end - start, state.app.anime.broadcast[count].len - 1);
                            @memcpy(state.app.anime.broadcast[count][0..blen], bscope[start .. start + blen]);
                            state.app.anime.broadcast_lens[count] = blen;
                        }
                    }
                }
            }

            count += 1;
        }

        pos = obj_end;
    }

    // Final generation re-check before publishing the count: a newer fetch may
    // have superseded us during parsing. If so, drop our results.
    if (search_request.current() != my_gen) return 0;
    state.app.anime.result_count = count;
    // Fire-and-forget AniList metadata enrichment for a fresh grid load (all
    // modes route through here). Additive only — see spawnAniListEnrich.
    if (start_offset == 0 and count > 0) spawnAniListEnrich(my_gen);
    return count - start_offset; // rows actually added (0 ⇒ no more pages worth fetching)
}

// ══════════════════════════════════════════════════════════
// AniList metadata enrichment (additive, keyless GraphQL)
// ══════════════════════════════════════════════════════════
// After a fresh Jikan grid load we ask AniList — in ONE batched GraphQL query
// keyed by the visible cards' MAL ids — for score / cover / synopsis, and fill
// ONLY the fields Jikan left empty (score == 0, no poster, no synopsis). Existing
// Jikan/AllAnime data is never overwritten, so the base browsing path is
// unchanged; AniList strictly improves coverage where MAL was thin (common for
// seasonal/upcoming titles). SFW-gated to honor the same NSFW toggle Jikan uses.
//
// Thread-safety: the merge shares state.app.anime.results[] with the Jikan
// parse, so it takes the same anime_parse_mutex and re-checks search_request before
// touching anything. Stale generations (superseded by a newer search) exit at
// the snapshot gen-check before any network work, so at most one enrich worker
// per settled query ever reaches curl — no busy flag needed.

fn spawnAniListEnrich(my_gen: u32) void {
    workers.spawn(anilistEnrichThread, .{my_gen}) catch {};
}

fn anilistEnrichThread(my_gen: u32) void {
    // 1) Snapshot the visible MAL ids as a CSV under the parse mutex.
    var csv_buf: [512]u8 = undefined;
    var csv_len: usize = 0;
    var sfw = false;
    {
        anime_parse_mutex.lock();
        defer anime_parse_mutex.unlock();
        if (search_request.current() != my_gen) return; // superseded — bail cheaply
        sfw = state.app.nsfw_filter_enabled;
        const n = @min(state.app.anime.result_count, 50); // AniList Page perPage cap
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r = &state.app.anime.results[i];
            if (r.id_len == 0) continue;
            const need = r.id_len + @as(usize, if (csv_len > 0) 1 else 0);
            if (csv_len + need > csv_buf.len) break;
            if (csv_len > 0) {
                csv_buf[csv_len] = ',';
                csv_len += 1;
            }
            @memcpy(csv_buf[csv_len..][0..r.id_len], r.id[0..r.id_len]);
            csv_len += r.id_len;
        }
    }
    if (csv_len == 0) return;

    // 2) Network fetch OUTSIDE the lock (heap buffer — never a big worker stack).
    const buf = alloc.alloc(u8, 1024 * 1024) catch return;
    defer alloc.free(buf);
    const bytes = anilist.fetchMetaByMalIdsWithCancellation(csv_buf[0..csv_len], sfw, buf, searchEpoch(my_gen));
    if (bytes == 0) return;

    // 3) Merge under the lock, re-checking the generation.
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    if (search_request.current() != my_gen) return;

    var it = anilist_pure.Iter{ .json = buf[0..bytes] };
    var merged: usize = 0;
    while (it.next()) |m| {
        if (m.id_mal <= 0) continue;
        var j: usize = 0;
        while (j < state.app.anime.result_count) : (j += 1) {
            const r = &state.app.anime.results[j];
            if (r.id_len == 0) continue;
            const rid = std.fmt.parseInt(i64, r.id[0..r.id_len], 10) catch continue;
            if (rid != m.id_mal) continue;
            r.anilist_id = m.id;
            // Fill only where Jikan was empty — never clobber live data.
            if (r.score == 0.0 and m.score10 > 0.0) r.score = m.score10;
            if (r.overview_len == 0 and m.description.len > 0)
                r.overview_len = decodeJsonEscapes(m.description, &r.overview);
            if (r.poster_url_len == 0 and m.cover.len > 0)
                r.poster_url_len = decodeJsonEscapes(m.cover, &r.poster_url);
            merged += 1;
            break;
        }
    }
    if (merged > 0) logs.pushLog("info", "anime", "AniList metadata merged", false);
}

const catalog = @import("anime_catalog_pure.zig");
var episode_request: LatestRequest = .{};
var episode_scroll_info: dvui.ScrollInfo = .{};
var episode_failed = std.atomic.Value(bool).init(false);
const EpisodeJob = struct { idx: usize, generation: u32, mal: [16]u8, mal_len: usize };
const EpisodeDocument = struct { job: EpisodeJob, bytes: []u8 };
var episode_documents: std.ArrayListUnmanaged(EpisodeDocument) = .empty;
var episode_document_mutex: @import("../core/sync.zig").Mutex = .{};

fn fillEpisodeSlots(total: usize) void {
    const a = &state.app.anime;
    const end = @min(total, a.episode_list.len);
    for (a.episode_count..@max(a.episode_count, end)) |i| {
        const n = std.fmt.bufPrint(&a.episode_list[i], "{d}", .{i + 1}) catch continue;
        a.episode_list_lens[i] = n.len;
        a.episode_title_lens[i] = 0;
        a.episode_aired_lens[i] = 0;
        a.episode_scores[i] = 0;
        a.episode_filler[i] = false;
        a.episode_watched[i] = false;
    }
    a.episode_count = @max(a.episode_count, end);
}

pub fn loadEpisodes(idx: usize) void {
    const row = resultRow(idx) orelse return;
    episode_request.cancel(&state.app.anime.episodes_loading);
    cancelPlayback();
    episode_failed.store(false, .release);
    if (results_are_scraper) {
        loadEpisodesScraper(idx);
        return;
    }
    state.app.anime.selected_idx = idx;
    state.app.anime.episode_count = 0;
    fillEpisodeSlots(row.episodes);
    if (!@import("build_options").headless) episode_scroll_info.scrollToOffset(.vertical, 0);
    @import("../core/db.zig").animeLoadWatched(row.id[0..row.id_len], state.app.anime.episode_watched[0..state.app.anime.episode_count]);
    loadRelations(idx);
    var job = EpisodeJob{ .idx = idx, .generation = episode_request.begin(&state.app.anime.episodes_loading), .mal = undefined, .mal_len = @min(row.id_len, 16) };
    @memcpy(job.mal[0..job.mal_len], row.id[0..job.mal_len]);
    workers.spawn(fetchEpisodeDataThread, .{job}) catch {
        episode_failed.store(true, .release);
        episode_request.finish(job.generation, &state.app.anime.episodes_loading);
    };
}

/// Transfer response ownership to the UI/headless main loop. Workers never
/// write the episode arrays while a frame is reading them.
pub fn applyPendingEpisodes() void {
    episode_document_mutex.lock();
    var docs = episode_documents;
    episode_documents = .empty;
    episode_document_mutex.unlock();
    defer docs.deinit(alloc);
    for (docs.items) |doc| {
        defer alloc.free(doc.bytes);
        if (!episode_request.isCurrent(doc.job.generation) or state.app.anime.selected_idx != doc.job.idx or results_are_scraper) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, doc.bytes, .{}) catch continue;
        defer parsed.deinit();
        if (catalog.anilistEpisodeCount(parsed.value)) |total| fillEpisodeSlots(total);
        const entries = catalog.data(parsed.value) orelse &.{};
        for (entries) |entry| {
            const ep = catalog.episode(entry) orelse continue;
            fillEpisodeSlots(ep.number);
            const i = ep.number - 1;
            const a = &state.app.anime;
            a.episode_title_lens[i] = @min(ep.title.len, a.episode_titles[i].len);
            @memcpy(a.episode_titles[i][0..a.episode_title_lens[i]], ep.title[0..a.episode_title_lens[i]]);
            a.episode_aired_lens[i] = ep.aired.len;
            @memcpy(a.episode_aired[i][0..ep.aired.len], ep.aired);
            a.episode_scores[i] = ep.score;
            a.episode_filler[i] = ep.filler;
        }
        @import("../core/db.zig").animeLoadWatched(doc.job.mal[0..doc.job.mal_len], state.app.anime.episode_watched[0..state.app.anime.episode_count]);
    }
}

pub fn playbackFailed() bool {
    return playback_failed.load(.acquire);
}

pub fn episodeFetchFailed() bool {
    return episode_failed.load(.acquire);
}

fn fetchEpisodeDataThread(job: EpisodeJob) void {
    defer episode_request.finish(job.generation, &state.app.anime.episodes_loading);
    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    var page: usize = 1;
    // Unknown/airing totals still fetch page one. Follow provider pagination,
    // never use the incomplete series total to decide whether to fetch.
    while (page <= (catalog.capacity + 99) / 100 and episode_request.isCurrent(job.generation) and !workers_isQuitting()) : (page += 1) {
        var ub: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&ub, "https://api.jikan.moe/v4/anime/{s}/episodes?page={d}", .{ job.mal[0..job.mal_len], page }) catch return;
        var body: ?[]const u8 = null;
        // Parse once, reuse for the validation, the publish and the pagination
        // check. This used to build the JSON DOM three times per page: once to
        // validate the fetch, once to publish it, plus a third `catalog.data`
        // call — on multi-hundred-KB jikan pages, and once per page of a long
        // series.
        var parsed_holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (parsed_holder) |*p| p.deinit();

        if (content_cache.get(url, buf)) |hit| {
            // Stale cached pages remain useful if revalidation fails.
            body = hit.bytes;
            if (hit.staleness != .fresh) body = null;
        }
        var attempt: usize = 0;
        while (body == null and attempt < 3 and episode_request.isCurrent(job.generation)) : (attempt += 1) {
            @import("../core/rate_limit.zig").acquire("jikan", 2.0);
            if (@import("../core/http.zig").fetch(url, buf, .{ .timeout_secs = 8 })) |bytes| {
                if (std.json.parseFromSlice(std.json.Value, alloc, bytes, .{})) |parsed| {
                    if (catalog.data(parsed.value) != null) {
                        body = bytes;
                        parsed_holder = parsed;
                        content_cache.put(url, bytes, ANIME_DETAIL_CACHE_TTL_S);
                    } else parsed.deinit();
                } else |_| {}
            }
            if (body == null and attempt < 2) @import("../core/io_global.zig").sleep((500 + attempt * 500) * std.time.ns_per_ms);
        }
        if (body == null) if (content_cache.get(url, buf)) |hit| {
            body = hit.bytes;
        };
        const bytes = body orelse {
            fetchEpisodeCountFallback(job, buf);
            if (episode_request.isCurrent(job.generation)) episode_failed.store(true, .release);
            return;
        };
        if (parsed_holder == null) {
            parsed_holder = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return;
        }
        const parsed = &parsed_holder.?.value;
        _ = catalog.data(parsed.*) orelse return;
        const copy = alloc.dupe(u8, bytes) catch return;
        episode_document_mutex.lock();
        if (episode_request.isCurrent(job.generation)) {
            episode_documents.append(alloc, .{ .job = job, .bytes = copy }) catch alloc.free(copy);
        } else alloc.free(copy);
        episode_document_mutex.unlock();
        state.wakeUi();
        if (!catalog.hasNext(parsed.*)) break;
    }
}

fn fetchEpisodeCountFallback(job: EpisodeJob, buf: []u8) void {
    if (!episode_request.isCurrent(job.generation)) return;
    const id = std.fmt.parseInt(u32, job.mal[0..job.mal_len], 10) catch return;
    var kb: [80]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "anime:episode-count:anilist:{d}", .{id}) catch return;
    var body: ?[]const u8 = null;
    if (content_cache.get(key, buf)) |hit| {
        if (hit.staleness == .fresh) body = hit.bytes;
    }
    if (body == null) {
        var qb: [384]u8 = undefined;
        const query = std.fmt.bufPrint(&qb,
            \\{{"query":"query {{ Media(idMal: {d}, type: ANIME) {{ episodes nextAiringEpisode {{ episode }} }} }}"}}
        , .{id}) catch return;
        body = @import("reliable_fetch.zig").fetch("https://graphql.anilist.co", buf, .{
            .post_body = query,
            .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            .timeout_secs = 8,
        });
        if (body) |bytes| {
            const doc = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return;
            defer doc.deinit();
            if (catalog.anilistEpisodeCount(doc.value) == null) return;
            content_cache.put(key, bytes, ANIME_DETAIL_CACHE_TTL_S);
        } else if (content_cache.get(key, buf)) |hit| {
            body = hit.bytes;
        }
    }
    const bytes = body orelse return;
    const copy = alloc.dupe(u8, bytes) catch return;
    episode_document_mutex.lock();
    defer episode_document_mutex.unlock();
    if (episode_request.isCurrent(job.generation)) {
        episode_documents.append(alloc, .{ .job = job, .bytes = copy }) catch alloc.free(copy);
        state.wakeUi();
    } else alloc.free(copy);
}

// ══════════════════════════════════════════════════════════
// Relations rail (/anime/{mal_id}/relations) — Sequel/Prequel/Side Story/…
// ══════════════════════════════════════════════════════════

var relations_busy: std.atomic.Value(bool) = .init(false);
var relations_request: LatestRequest = .{};
var relations_pending_mutex: @import("../core/sync.zig").Mutex = .{};
var relations_pending: [16]state.AnimeRelation = undefined;
var relations_pending_count: usize = 0;
var relations_pending_generation: u32 = 0;
var relations_pending_ready = false;
const RelationsJob = struct { mal: [16]u8 = undefined, mal_len: usize, generation: u32 };

pub fn loadRelations(idx: usize) void {
    const row = resultRow(idx) orelse return;
    if (row.id_len == 0) return;
    state.app.anime.relations_loading = true;
    state.app.anime.relation_count = 0;
    var job = RelationsJob{ .mal_len = @min(row.id_len, 16), .generation = relations_request.begin(&relations_busy) };
    @memcpy(job.mal[0..job.mal_len], row.id[0..job.mal_len]);
    workers.spawn(relationsWorker, .{job}) catch {
        relations_request.finish(job.generation, &relations_busy);
        state.app.anime.relations_loading = false;
    };
}
fn relationsWorker(job: RelationsJob) void {
    defer {
        relations_request.finish(job.generation, &relations_busy);
        state.wakeUi();
    }
    var url_buf: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/anime/{s}/relations", .{job.mal[0..job.mal_len]}) catch return;
    const argv = [_][]const u8{ "curl", "-s", "--connect-timeout", "3", "-A", agent, "--max-time", "10", url };
    const buf = alloc.alloc(u8, 128 * 1024) catch return;
    defer alloc.free(buf);
    const fetched = bounded_process.run(&argv, buf, .{
        .timeout_ms = 12_000,
        .terminate_grace_ms = 100,
        .cancel_epoch = .{ .epoch32 = .{ .value = &relations_request.generation, .expected = job.generation } },
    });
    if (!fetched.ok() or !relations_request.isCurrent(job.generation)) return;
    var records: [16]state.AnimeRelation = @splat(.{});
    const count = parseRelations(fetched.output, &records);
    relations_pending_mutex.lock();
    defer relations_pending_mutex.unlock();
    if (!relations_request.isCurrent(job.generation)) return;
    relations_pending = records;
    relations_pending_count = count;
    relations_pending_generation = job.generation;
    relations_pending_ready = true;
}
fn applyPendingRelations() void {
    relations_pending_mutex.lock();
    defer relations_pending_mutex.unlock();
    state.app.anime.relations_loading = relations_busy.load(.acquire);
    if (!relations_pending_ready) return;
    relations_pending_ready = false;
    if (!relations_request.isCurrent(relations_pending_generation)) return;
    @memcpy(state.app.anime.relations[0..relations_pending_count], relations_pending[0..relations_pending_count]);
    state.app.anime.relation_count = relations_pending_count;
}

/// Relation types worth surfacing in the rail (skip Character/Adaptation/Summary).
fn relationKept(rel: []const u8) bool {
    const keep = [_][]const u8{ "Sequel", "Prequel", "Side Story", "Spin-Off", "Parent story", "Alternative version", "Alternative setting" };
    for (keep) |k| {
        if (std.ascii.eqlIgnoreCase(rel, k)) return true;
    }
    return false;
}

/// Parse /anime/{id}/relations → data[] of {relation, entry:[{mal_id,type,name}]}.
/// Fills state.app.anime.relations[] with kept (meaningful) anime-type entries.
fn parseRelations(json: []const u8, out: []state.AnimeRelation) usize {
    var count: usize = 0;
    var pos: usize = 0;

    while (pos < json.len and count < out.len) {
        // Each data element starts with "relation":"<type>".
        const rel_idx = std.mem.indexOf(u8, json[pos..], "\"relation\":\"") orelse break;
        const rel_start = pos + rel_idx + 12;
        var rel_end = rel_start;
        while (rel_end < json.len and json[rel_end] != '"') : (rel_end += 1) {}
        if (rel_end >= json.len) break;
        const rel_type = json[rel_start..rel_end];

        // Scope this element up to the next "relation": (or EOF).
        var next_rel = json.len;
        if (std.mem.indexOf(u8, json[rel_end..], "\"relation\":\"")) |nidx| {
            next_rel = rel_end + nidx;
        }
        const scope = json[rel_end..next_rel];
        pos = next_rel;

        if (!relationKept(rel_type)) continue;

        // Walk each entry object in this relation's entry[] array. We accept
        // only type:"anime" entries (skip manga/light-novel relations).
        var epos: usize = 0;
        while (epos < scope.len and count < out.len) {
            const eid = std.mem.indexOf(u8, scope[epos..], "\"mal_id\":") orelse break;
            const num_st = epos + eid + 9;
            var ne = num_st;
            while (ne < scope.len and scope[ne] >= '0' and scope[ne] <= '9') : (ne += 1) {}
            if (ne == num_st) {
                epos = num_st;
                continue;
            }
            const id_str = scope[num_st..ne];

            var ent_end = scope.len;
            if (std.mem.indexOf(u8, scope[ne..], "\"mal_id\":")) |nidx| {
                ent_end = ne + nidx;
            }
            const ent = scope[num_st..ent_end];
            epos = ent_end;

            // type must be anime.
            var is_anime = false;
            if (std.mem.indexOf(u8, ent, "\"type\":\"anime\"")) |_| is_anime = true;
            if (!is_anime) continue;

            // entry name.
            var name_str: []const u8 = "";
            if (std.mem.indexOf(u8, ent, "\"name\":\"")) |ni| {
                const s = ni + 8;
                var e = s;
                var esc = false;
                while (e < ent.len) : (e += 1) {
                    if (esc) {
                        esc = false;
                    } else if (ent[e] == '\\') {
                        esc = true;
                    } else if (ent[e] == '"') break;
                }
                if (e <= ent.len and e > s) name_str = ent[s..e];
            }
            if (name_str.len == 0) continue;

            var r = &out[count];
            const idl = @min(id_str.len, r.mal_id.len);
            @memcpy(r.mal_id[0..idl], id_str[0..idl]);
            r.mal_id_len = idl;
            r.name_len = decodeJsonEscapes(name_str, &r.name);
            const tl = @min(rel_type.len, r.rel_type.len);
            @memcpy(r.rel_type[0..tl], rel_type[0..tl]);
            r.rel_type_len = tl;
            count += 1;
        }
    }

    return count;
}

// ══════════════════════════════════════════════════════════
// Jump to a single anime by mal_id (/anime/{id}) — related & continue rails.
// Parses one anime object into results[0], selects it, loads episodes.
// ══════════════════════════════════════════════════════════

var jump_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn jumpToAnime(mal_id: []const u8) void {
    if (mal_id.len == 0 or mal_id.len > 15) return;
    if (jump_busy.swap(true, .acq_rel)) return;
    state.app.anime.selected_idx = null;
    cancelPlayback();
    episode_request.cancel(&state.app.anime.episodes_loading);
    state.app.anime.episode_count = 0;
    // New generation so any in-flight grid fetch can't clobber results[0].
    const my_gen = beginCatalogRequest();
    grid_page = 1; // single-anime view has no further pages
    more_available.store(false, .release);

    const S = struct {
        var id_buf: [16]u8 = undefined;
        var id_len: usize = 0;
        var gen: u32 = 0;

        fn worker() void {
            defer {
                search_request.finish(@This().gen, &state.app.anime.is_loading);
                jump_busy.store(false, .release);
            }
            const id = @This().id_buf[0..@This().id_len];
            var url_buf: [96]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/anime/{s}", .{id}) catch return;

            const argv = [_][]const u8{ "curl", "-s", "-A", agent, "--max-time", "12", url };
            const buf = @import("../core/alloc.zig").allocator.alloc(u8, 128 * 1024) catch {
                return;
            };
            defer @import("../core/alloc.zig").allocator.free(buf);
            const body = boundedCurl(&argv, buf, 14_000) orelse return;
            if (body.len < 10) return;

            // The single-anime endpoint wraps one object in {"data":{...}} — the
            // same field shape parseJikanData walks, so reuse it (it caps at the
            // first mal_id object → exactly one card in results[0]).
            _ = parseJikanData(body, @This().gen);

            // If still current, select it and load its episodes on this thread.
            if (search_request.current() == @This().gen and state.app.anime.result_count > 0) {
                state.app.anime.selected_idx = 0;
                loadEpisodes(0);
            }
        }
    };

    const n = @min(mal_id.len, S.id_buf.len);
    @memcpy(S.id_buf[0..n], mal_id[0..n]);
    S.id_len = n;
    S.gen = my_gen;

    workers.spawn(S.worker, .{}) catch {
        search_request.finish(my_gen, &state.app.anime.is_loading);
        jump_busy.store(false, .release);
    };
}

// ══════════════════════════════════════════════════════════
// Episode tracking helpers (watched toggle, resume, continue upsert)
// ══════════════════════════════════════════════════════════

/// Toggle episode N's watched flag (UI ↔ DB). ep is 1-based.
fn toggleWatched(idx: usize, ep: usize) void {
    if (ep == 0 or ep > state.app.anime.episode_watched.len) return;
    if (idx >= state.app.anime.result_count) return;
    const flag = !state.app.anime.episode_watched[ep - 1];
    state.app.anime.episode_watched[ep - 1] = flag;
    const mal_id = state.app.anime.results[idx].id[0..state.app.anime.results[idx].id_len];
    if (mal_id.len > 0) {
        @import("../core/db.zig").animeMarkWatched(mal_id, @intCast(ep), flag);
    }
}

/// Count watched episodes among the currently-loaded episode range.
fn watchedCount() usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < state.app.anime.episode_count and i < state.app.anime.episode_watched.len) : (i += 1) {
        if (state.app.anime.episode_watched[i]) n += 1;
    }
    return n;
}

/// Lowest 1-based episode number not yet watched (for the Resume button). Falls
/// back to episode 1 if everything is watched or nothing is loaded.
fn nextUnwatchedEp() usize {
    var i: usize = 0;
    while (i < state.app.anime.episode_count and i < state.app.anime.episode_watched.len) : (i += 1) {
        if (!state.app.anime.episode_watched[i]) return i + 1;
    }
    return 1;
}

var playback_request: LatestRequest = .{};
const PlaybackJob = struct {
    generation: u32,
    idx: usize,
    row: state.AnimeResult,
    episode: u16,
    player_address: usize,
    player_serial: u64,
    scraper: AnimeScraper = .none,
    episode_url: [256]u8 = undefined,
    episode_url_len: usize = 0,
};
const PlaybackReady = struct {
    job: PlaybackJob,
    stream: ?@import("anime_extractors.zig").Resolved = null,
    torrent: [2048]u8 = undefined,
    torrent_len: usize = 0,
};
var playback_mutex: @import("../core/sync.zig").Mutex = .{};
var playback_ready: ?PlaybackReady = null;
var playback_start: ?PlaybackJob = null;
var playback_tracking: ?PlaybackReady = null;
var playback_failed = std.atomic.Value(bool).init(false);
var playback_episode = std.atomic.Value(u16).init(0);

pub fn playbackEpisode() u16 {
    return playback_episode.load(.acquire);
}

pub fn cancelPlayback() void {
    playback_request.cancel(&state.app.anime.stream_loading);
    playback_mutex.lock();
    playback_ready = null;
    playback_start = null;
    playback_mutex.unlock();
    playback_failed.store(false, .release);
    playback_episode.store(0, .release);
    state.wakeUi();
}

fn failPlayback(generation: u32) void {
    if (!playback_request.isCurrent(generation)) return;
    playback_failed.store(true, .release);
    playback_request.finish(generation, &state.app.anime.stream_loading);
    state.wakeUi();
}

fn publishPlayback(ready: PlaybackReady) void {
    playback_mutex.lock();
    defer playback_mutex.unlock();
    if (playback_request.isCurrent(ready.job.generation)) playback_ready = ready;
    state.wakeUi();
}

/// Commit player loads on the owning loop, never from a detached resolver.
pub fn applyPendingPlayback() void {
    playback_mutex.lock();
    const start = playback_start;
    playback_start = null;
    const ready = playback_ready;
    playback_ready = null;
    playback_mutex.unlock();
    if (start) |request| {
        if (playback_request.isCurrent(request.generation)) {
            if (state.app.players.items.len == 0) {
                const p = player.acquire(alloc) catch {
                    failPlayback(request.generation);
                    return;
                };
                state.app.players.append(alloc, p) catch {
                    p.deinit(alloc);
                    failPlayback(request.generation);
                    return;
                };
                state.app.active_player_idx = 0;
            }
            if (state.app.active_player_idx >= state.app.players.items.len) {
                failPlayback(request.generation);
                return;
            }
            const p = state.app.players.items[state.app.active_player_idx];
            if (request.player_address != 0 and (@intFromPtr(p) != request.player_address or p.load_serial != request.player_serial)) {
                failPlayback(request.generation);
                return;
            }
            var job = request;
            job.player_address = @intFromPtr(p);
            job.player_serial = p.load_serial;
            workers.spawn(fetchStreamThread, .{job}) catch failPlayback(job.generation);
        }
    }
    if (ready) |item| {
        if (!playback_request.isCurrent(item.job.generation)) return;
        if (state.app.active_player_idx >= state.app.players.items.len) {
            failPlayback(item.job.generation);
            return;
        }
        const p = state.app.players.items[state.app.active_player_idx];
        if (@intFromPtr(p) != item.job.player_address or p.load_serial != item.job.player_serial) {
            failPlayback(item.job.generation);
            return;
        }
        if (item.stream) |stream| {
            p.loadStreamWithHeaders(stream.streamUrl(), stream.refererStr());
            for (stream.subs[0..stream.sub_count]) |sub| _ = @import("../core/c.zig").mpvSubAdd(p.mpv_ctx, sub.url[0..sub.url_len]);
            state.gotoPlayer();
        } else if (item.torrent_len > 0) {
            @import("search.zig").loadTorrentToPlayer(item.torrent[0..item.torrent_len]);
        }
        var skip_name: [192]u8 = undefined;
        const skip_title = std.fmt.bufPrint(&skip_name, "{s} Episode {d}", .{ item.job.row.name[0..item.job.row.name_len], item.job.episode }) catch "";
        @import("anime_skip.zig").onEpisodeLoad(skip_title);
        playback_tracking = item;
        playback_request.finish(item.job.generation, &state.app.anime.stream_loading);
    }
    if (playback_tracking) |item| {
        if (!playback_request.isCurrent(item.job.generation)) {
            playback_tracking = null;
            return;
        }
        if (state.app.active_player_idx >= state.app.players.items.len) return;
        const p = state.app.players.items[state.app.active_player_idx];
        if (@intFromPtr(p) != item.job.player_address) return;
        const matches = if (item.stream) |stream|
            std.mem.eql(u8, p.current_url[0..p.current_url_len], stream.streamUrl())
        else
            std.mem.eql(u8, p.source_url[0..p.source_url_len], item.torrent[0..item.torrent_len]);
        if (matches and p.last_good_pos_secs >= 1) {
            recordEpisodeStarted(item.job);
            playback_tracking = null;
        }
    }
}

fn recordEpisodeStarted(job: PlaybackJob) void {
    // ── Tracking: mark this episode watched + upsert the Continue entry so it
    //    surfaces in My List with the next episode to resume. ──
    {
        const ep_num = job.episode;
        const r = &job.row;
        const mal_id = r.id[0..r.id_len];
        if (ep_num >= 1 and ep_num <= state.app.anime.episode_watched.len and mal_id.len > 0) {
            if (state.app.anime.selected_idx == job.idx) state.app.anime.episode_watched[ep_num - 1] = true;
            const db = @import("../core/db.zig");
            db.animeMarkWatched(mal_id, ep_num, true);
            db.animeUpsertContinue(mal_id, r.name[0..r.name_len], r.poster_url[0..r.poster_url_len], ep_num, r.episodes);
            if (r.anilist_id > 0) anilist.updateProgress(r.anilist_id, ep_num);
            // Mirror into the unified read-model so the home Continue rail shows
            // anime alongside the other verticals. anime_continue (above) stays
            // authoritative; progress is measured in EPISODES, and the deep link
            // is the MAL id — home routes it back through jumpToAnime().
            {
                var label_buf: [48]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "E{d}", .{ep_num +| 1}) catch "";
                @import("library_store.zig").upsertProgress(
                    "anime",
                    mal_id,
                    r.name[0..r.name_len],
                    r.poster_url[0..r.poster_url_len],
                    @floatFromInt(ep_num),
                    @floatFromInt(r.episodes),
                    label,
                    mal_id,
                );
            }
            // Refresh the cached Continue rail so My List reflects this play.
            state.app.anime.continue_loaded = false;
        }
    }
}

pub fn playEpisode(ep_no: []const u8) void {
    const idx = state.app.anime.selected_idx orelse return;
    const row = resultRow(idx) orelse return;
    const episode = std.fmt.parseInt(u16, ep_no, 10) catch return;
    if (episode == 0 or episode > state.app.anime.episode_count) return;
    if (state.app.anime.stream_loading.load(.acquire) and playback_episode.load(.acquire) == episode) return;
    const p = if (state.app.active_player_idx < state.app.players.items.len) state.app.players.items[state.app.active_player_idx] else null;
    var job = PlaybackJob{ .generation = playback_request.begin(&state.app.anime.stream_loading), .idx = idx, .row = row, .episode = episode, .player_address = if (p) |ptr| @intFromPtr(ptr) else 0, .player_serial = if (p) |ptr| ptr.load_serial else 0 };
    playback_episode.store(episode, .release);
    playback_failed.store(false, .release);
    if (results_are_scraper) {
        const i = episode - 1;
        if (i >= scraper_ep_len.len) {
            cancelPlayback();
            return;
        }
        job.scraper = scraper_kind;
        job.episode_url_len = scraper_ep_len[i];
        @memcpy(job.episode_url[0..job.episode_url_len], scraper_ep_url[i][0..job.episode_url_len]);
    }
    playback_mutex.lock();
    playback_start = job;
    playback_ready = null;
    playback_mutex.unlock();
    state.wakeUi();
}

fn fetchStreamThread(job: PlaybackJob) void {
    var resolved = false;
    defer if (!resolved) failPlayback(job.generation);
    if (job.scraper != .none) {
        resolved = scraperPlayThread(job);
        if (resolved) return;
    } else {
        var release: PlaybackReady = .{ .job = job };
        if (@import("anime_provider.zig").resolveSubsPlease(job.row.name[0..job.row.name_len], job.row.name_english[0..job.row.name_english_len], job.episode, &playback_request, job.generation, &release.torrent)) |magnet| {
            release.torrent_len = magnet.len;
            publishPlayback(release);
            resolved = true;
            return;
        }
        if (!playback_request.isCurrent(job.generation)) return;
        if (@import("anime_provider.zig").resolveAllAnime(job.row.name[0..job.row.name_len], job.row.name_english[0..job.row.name_english_len], job.episode, &playback_request, job.generation)) |stream| {
            publishPlayback(.{ .job = job, .stream = stream });
            resolved = true;
            return;
        }
        if (!playback_request.isCurrent(job.generation)) return;
        // An installed direct source can start without waiting on torrent search.
        if (@import("anime_provider.zig").resolvePahe(job.row.name[0..job.row.name_len], job.row.name_english[0..job.row.name_english_len], job.episode, &playback_request, job.generation)) |stream| {
            publishPlayback(.{ .job = job, .stream = stream });
            resolved = true;
            return;
        }
        if (!playback_request.isCurrent(job.generation)) return;
        if (@import("anime_provider.zig").resolveHiAnime(job.row.name[0..job.row.name_len], job.row.name_english[0..job.row.name_english_len], job.episode, &playback_request, job.generation)) |stream| {
            publishPlayback(.{ .job = job, .stream = stream });
            resolved = true;
            return;
        }
        if (!playback_request.isCurrent(job.generation)) return;
        const resolver = @import("resolver.zig");
        var query_buf: [256]u8 = undefined;
        const query = std.fmt.bufPrint(&query_buf, "{s} {d:0>2}", .{ job.row.name[0..job.row.name_len], job.episode }) catch return;
        const generation = resolver.resolveTracked(query, "anime");
        var waited: usize = 0;
        while (resolver.isResolving() and waited < 150) : (waited += 1) {
            if (!playback_request.isCurrent(job.generation) or !resolver.generationIsCurrent(generation)) return;
            @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        }
        if (!playback_request.isCurrent(job.generation) or !resolver.lockResultsForGeneration(generation)) return;
        defer resolver.unlockResultsForGeneration();
        for (resolver.results[0..resolver.result_count]) |item| {
            if ((item.source != .torrent and item.source != .stremio) or item.url_len == 0 or item.url_len > 2048) continue;
            const rank = @import("resolver_rank.zig");
            if (rank.pickForStartup(&.{.{ .playable = true, .needs_seeds = item.source == .torrent, .match_pct = item.match_pct, .seeds = item.seeds }}, false) == null) continue;
            var ready = PlaybackReady{ .job = job, .torrent_len = item.url_len };
            @memcpy(ready.torrent[0..item.url_len], item.url[0..item.url_len]);
            publishPlayback(ready);
            resolved = true;
            return;
        }
    }
    if (playback_request.isCurrent(job.generation)) {
        playback_failed.store(true, .release);
        logs.pushLog("error", "anime", "No playable source found for this episode. Check installed anime sources or try Search.", true);
    }
}

// ══════════════════════════════════════════════════════════════════════════
// SITE-FRAMEWORK ENGINES — DooPlay (~25 sites) + AnimeStream (~20 sites)
// ══════════════════════════════════════════════════════════════════════════
//
// Two WordPress anime-theme scrapers wired as source_config-gated alternatives to
// the built-in Jikan-metadata + torrent/AnimePahe play path. Both are INERT until
// a plugin writes their base URL (`dooplay`/`animestream` → source_config), so the
// default build is 100% unchanged. When a base IS configured, Search-mode routes
// the search → detail → episode → play flow through the site's own pages:
//
//   1. searchAnime(query)      → scraperSearchThread → grid parse → results[]
//   2. loadEpisodes(idx)       → loadEpisodesScraper → episode-list parse
//   3. playEpisode(ep)         → scraperPlayThread → EMBED URL → queued playback
//
// The EMBED URL each framework produces is fed to the SAME extractor stack
// (anime_extractors.resolveEmbed) already on main:
//   • DooPlay:     episode page → #playeroptionsul (data-post/nume/type) → POST
//                  wp-admin/admin-ajax.php (doo_player_ajax) → {embed_url} JSON.
//   • AnimeStream: episode page → server <option value="base64 iframe"> decode
//                  (or first raw <iframe src>) → embed URL.
//
// ALL HTML/JSON/URL parsing is routed through the tested pure modules
// (anime_dooplay_pure / anime_animestream_pure) so the shipped logic IS the
// tested logic. Fetches use scrapeFetch (anti-block, Cloudflare-fronted sites);
// the DooPlay AJAX POST uses curl with a Referer + X-Requested-With header.

const dooplay = @import("anime_dooplay_pure.zig");
const animestream = @import("anime_animestream_pure.zig");
const mt_pure = @import("manga_themesia_pure.zig");
const source_config = @import("../core/source_config.zig");
const scrape = @import("scrape_fetch.zig");

const AnimeScraper = enum { none, dooplay, animestream };

/// Which site-framework source is installed (dooplay wins if both are). `.none`
/// keeps the entire built-in Jikan path unchanged.
fn activeScraper() AnimeScraper {
    if (source_config.get("dooplay", "base") != null) return .dooplay;
    if (source_config.get("animestream", "base") != null) return .animestream;
    return .none;
}

fn scraperId(src: AnimeScraper) []const u8 {
    return switch (src) {
        .dooplay => "dooplay",
        .animestream => "animestream",
        .none => "",
    };
}

/// Copy the configured base URL for `src` into `out` (the source_config slice
/// points into a table that reload() can move, so snapshot it). Null when inert.
fn scraperBase(src: AnimeScraper, out: []u8) ?[]const u8 {
    const id = scraperId(src);
    if (id.len == 0) return null;
    const b = source_config.get(id, "base") orelse return null;
    if (b.len == 0 or b.len > out.len) return null;
    @memcpy(out[0..b.len], b);
    return out[0..b.len];
}

// Parallel to state.app.anime.results[] / episode_list[] — the scraper detail-page
// URL per card and the episode-page URL per episode. Kept module-level (not in the
// state struct) because the AnimeResult.id field is only [64]u8 and detail URLs
// exceed that. Written under anime_parse_mutex during publish; the UI thread reads
// them when a card / episode is opened.
var scraper_detail_url: [100][256]u8 = undefined;
var scraper_detail_len: [100]usize = std.mem.zeroes([100]usize);
var scraper_ep_url: [catalog.capacity][256]u8 = undefined;
var scraper_ep_len: [catalog.capacity]usize = std.mem.zeroes([catalog.capacity]usize);
/// True when results[] currently holds scraper cards (set at publish, cleared by
/// the Jikan/lists publishers). Routes loadEpisodes/playEpisode to the scraper.
var results_are_scraper: bool = false;
/// Which framework produced the current results[]/episodes.
var scraper_kind: AnimeScraper = .none;
var scraper_episode_gen: std.atomic.Value(u32) = .init(0);
var scraper_episode_failed: std.atomic.Value(bool) = .init(false);
var scraper_episode_retry_count: std.atomic.Value(u8) = .init(0);
var scraper_episode_retry_at_ms: std.atomic.Value(i64) = .init(0);
const ANIME_DETAIL_CACHE_TTL_S: i64 = 6 * 60 * 60;

fn scraperEpisodeCacheKey(out: []u8, src: AnimeScraper, detail_url: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(out, "anime:episodes:v1:{s}:{s}", .{ scraperId(src), detail_url }) catch null;
}

fn markScraperEpisodeFailure(generation: u32) void {
    if (scraper_episode_gen.load(.acquire) != generation) return;
    const old = scraper_episode_retry_count.load(.acquire);
    const attempt = route_resilience.nextAttempt(old);
    scraper_episode_retry_count.store(attempt, .release);
    scraper_episode_retry_at_ms.store(@import("../core/io_global.zig").milliTimestamp() + route_resilience.retryDelayMs(attempt), .release);
    scraper_episode_failed.store(true, .release);
    state.wakeUi();
}

fn clearScraperEpisodeFailure() void {
    scraper_episode_failed.store(false, .release);
    scraper_episode_retry_count.store(0, .release);
    scraper_episode_retry_at_ms.store(0, .release);
}

/// Last path segment of a detail URL (a stable-ish per-title key for watch
/// tracking; AnimeResult.id is only [64]u8 so we can't store the full URL).
fn slugOf(url: []const u8) []const u8 {
    var u = std.mem.trimEnd(u8, url, "/");
    if (std.mem.lastIndexOfScalar(u8, u, '/')) |s| u = u[s + 1 ..];
    if (u.len > 63) u = u[0..63];
    return u;
}

/// Kick a scraper search (query in search_query_buf; empty ⇒ popular/latest grid).
/// Mirrors searchAnime's generation/loading bookkeeping.
pub fn loadScraperPopular() void {
    if (activeScraper() == .none) return;
    state.app.anime.selected_idx = null;
    cancelPlayback();
    episode_request.cancel(&state.app.anime.episodes_loading);
    state.app.anime.episode_count = 0;
    const my_gen = beginCatalogRequest();
    grid_page = 1;
    more_available.store(false, .release);
    anime_query_mutex.lock();
    search_query_len = 0; // empty query → popular
    anime_query_mutex.unlock();
    const job: SearchJob = .{ .generation = my_gen };
    workers.spawn(scraperSearchThread, .{job}) catch {
        search_request.finish(my_gen, &state.app.anime.is_loading);
    };
}

/// GET a page through the anti-block scrape layer into a fresh heap buffer.
/// Returns the body length (0 on failure); caller owns/free via the passed buf.
fn scraperGet(url: []const u8, buf: []u8) usize {
    const body = scrape.scrapeFetch(url, buf) orelse return 0;
    return body.len;
}

/// POST `body` to the DooPlay admin-ajax endpoint with the Referer + AJAX marker
/// the WordPress handler requires. Returns bytes read into `dst` (0 on failure).
fn scraperPost(url: []const u8, referer: []const u8, body: []const u8, dst: []u8) usize {
    var ref_buf: [320]u8 = undefined;
    const ref_hdr = std.fmt.bufPrint(&ref_buf, "Referer: {s}", .{referer}) catch return 0;
    const argv = [_][]const u8{
        "curl",   "-sL",                              "-A",         agent,
        "-H",     "X-Requested-With: XMLHttpRequest", "-H",         ref_hdr,
        "--data", body,                               "--max-time", "15",
        url,
    };
    const response = boundedCurl(&argv, dst, 17_000) orelse return 0;
    return response.len;
}

/// Fetch + parse a scraper search (or popular) grid and publish into results[].
/// Shares results[]/generation with the Jikan parser → takes anime_parse_mutex and
/// re-checks the generation, exactly like publishListsJson.
fn scraperSearchThread(job: SearchJob) void {
    const my_gen = job.generation;
    defer search_request.finish(my_gen, &state.app.anime.is_loading);
    const src = activeScraper();
    if (src == .none) return;

    var base_buf: [256]u8 = undefined;
    const base = scraperBase(src, &base_buf) orelse return;

    const query = job.query[0..job.query_len];

    var url_buf: [640]u8 = undefined;
    const url = blk: {
        if (query.len >= 2) {
            break :blk (switch (src) {
                .dooplay => dooplay.buildSearchUrl(base, query, &url_buf),
                .animestream => animestream.buildSearchUrl(base, query, &url_buf),
                .none => null,
            }) orelse return;
        }
        break :blk (switch (src) {
            .dooplay => dooplay.buildPopularUrl(base, &url_buf),
            .animestream => animestream.buildPopularUrl(base, &url_buf),
            .none => null,
        }) orelse return;
    };

    const html_buf = alloc.alloc(u8, 1024 * 1024) catch return;
    defer alloc.free(html_buf);
    const n = scraperGet(url, html_buf);
    if (n == 0 or workers_isQuitting()) return;
    if (search_request.current() != my_gen) return; // superseded mid-fetch

    const shown = publishScraperGrid(html_buf[0..n], base, src, my_gen);
    var lb: [96]u8 = undefined;
    logs.pushLog("info", "anime", std.fmt.bufPrintZ(&lb, "{s} grid loaded ({d})", .{ scraperId(src), shown }) catch "Scraper grid loaded", false);
}

fn workers_isQuitting() bool {
    return @import("../core/workers.zig").isQuitting();
}

/// Publish parsed scraper grid items into state.app.anime.results[]. Returns rows
/// shown. Retires old poster textures (UI-thread work → queued) under the mutex.
fn publishScraperGrid(html: []const u8, base: []const u8, src: AnimeScraper, my_gen: u32) usize {
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    if (search_request.current() != my_gen) return 0;

    // Fresh load: retire the old cards' poster textures + reset flags.
    for (0..state.app.anime.results.len) |i| {
        state.app.anime.results[i].poster_fetching = false;
        state.app.anime.results[i].expanded = false;
        if (state.app.anime.results[i].poster_tex) |tex| {
            queueTexFree(tex);
            state.app.anime.results[i].poster_tex = null;
        }
    }
    for (0..state.app.anime.broadcast_lens.len) |i| state.app.anime.broadcast_lens[i] = 0;

    var count: usize = 0;
    const max = state.app.anime.results.len;

    const Emit = struct {
        fn one(url_raw: []const u8, title_raw: []const u8, img_tag: []const u8, bse: []const u8, idx: usize) bool {
            const item = &state.app.anime.results[idx];
            var abs_buf: [256]u8 = undefined;
            const detail = mt_pure.resolveUrl(bse, url_raw, &abs_buf);
            if (detail.len == 0 or detail.len >= scraper_detail_url[idx].len) return false;
            const title = std.mem.trim(u8, title_raw, " \t\r\n");
            if (title.len == 0 or title.len > item.name.len) return false;
            if (state.app.nsfw_filter_enabled and anime_pure.titleLooksAdult(title)) return false;

            @memcpy(state.app.anime.results[idx].name[0..title.len], title);
            item.name_len = title.len;

            const slug = slugOf(detail);
            const idl = @min(slug.len, item.id.len);
            @memcpy(item.id[0..idl], slug[0..idl]);
            item.id_len = idl;

            @memcpy(scraper_detail_url[idx][0..detail.len], detail);
            scraper_detail_len[idx] = detail.len;

            // Cover (image-attr rule → absolute) — only if it fits the [128] field.
            item.poster_url_len = 0;
            if (img_tag.len > 0) {
                var cov_buf: [256]u8 = undefined;
                if (mt_pure.pickImageAttr(img_tag, bse, &cov_buf)) |cov| {
                    if (cov.len > 0 and cov.len <= item.poster_url.len) {
                        @memcpy(item.poster_url[0..cov.len], cov);
                        item.poster_url_len = cov.len;
                    }
                }
            }
            item.episodes = 0; // unknown until the detail page is opened
            item.score = 0;
            item.overview_len = 0;
            item.poster_fetching = false;
            item.poster_attempted = false;
            item.poster_failed = false;
            if (item.poster_tex) |tx| {
                queueTexFree(tx);
                item.poster_tex = null;
            }
            item.expanded = false;
            return true;
        }
    };

    switch (src) {
        .dooplay => {
            var it = dooplay.gridIter(html);
            while (it.next()) |g| {
                if (count >= max) break;
                if (Emit.one(g.url, g.title, g.img_tag, base, count)) count += 1;
            }
        },
        .animestream => {
            var it = animestream.searchIter(html);
            while (it.next()) |g| {
                if (count >= max) break;
                if (Emit.one(g.url, g.title, g.img_tag, base, count)) count += 1;
            }
        },
        .none => {},
    }

    if (search_request.current() != my_gen) return 0;
    results_are_scraper = true;
    scraper_kind = src;
    state.app.anime.result_count = count;
    more_available.store(false, .release);
    return count;
}

/// Fetch the selected card's detail page, parse its episode list, and publish the
/// episodes (oldest-first). Routed to from loadEpisodes when results are scraper
/// cards. Sets up the same episode_list/titles/aired arrays the UI already renders.
fn loadEpisodesScraper(idx: usize) void {
    startEpisodesScraper(idx, true);
}

fn startEpisodesScraper(idx: usize, reset_retry: bool) void {
    if (idx >= state.app.anime.result_count) return;
    state.app.anime.selected_idx = idx;
    if (reset_retry) {
        state.app.anime.episode_count = 0;
        clearScraperEpisodeFailure();
    }
    const generation = scraper_episode_gen.fetchAdd(1, .acq_rel) +% 1;
    state.app.anime.is_loading.store(true, .release);
    workers.spawn(episodesScraperThread, .{ idx, generation }) catch {
        state.app.anime.is_loading.store(false, .release);
        markScraperEpisodeFailure(generation);
    };
}

fn episodesScraperThread(idx: usize, generation: u32) void {
    defer if (scraper_episode_gen.load(.acquire) == generation) state.app.anime.is_loading.store(false, .release);
    const src = scraper_kind;
    if (src == .none or idx >= state.app.anime.results.len) {
        markScraperEpisodeFailure(generation);
        return;
    }
    const durl = scraper_detail_url[idx][0..scraper_detail_len[idx]];
    if (durl.len == 0) {
        markScraperEpisodeFailure(generation);
        return;
    }

    var base_buf: [256]u8 = undefined;
    const base = scraperBase(src, &base_buf) orelse durl; // fall back to detail origin

    var detail_copy: [256]u8 = undefined;
    @memcpy(detail_copy[0..durl.len], durl);
    const detail_url = detail_copy[0..durl.len];

    const html_buf = alloc.alloc(u8, 1024 * 1024) catch {
        markScraperEpisodeFailure(generation);
        return;
    };
    defer alloc.free(html_buf);
    var key_buf: [640]u8 = undefined;
    const cache_key = scraperEpisodeCacheKey(&key_buf, src, detail_url);

    // Paint cached episodes immediately. A stale entry stays visible while a
    // refresh runs; a provider failure can never replace it with an empty list.
    if (cache_key) |key| {
        if (content_cache.get(key, html_buf)) |hit| {
            if (publishScraperEpisodes(idx, generation, src, detail_url, base, hit.bytes) > 0) {
                clearScraperEpisodeFailure();
                if (hit.staleness == .fresh) return;
            }
        }
    }

    var attempt: u8 = 0;
    while (attempt < 3 and !workers_isQuitting()) : (attempt += 1) {
        const n = scraperGet(detail_url, html_buf);
        if (n > 0 and publishScraperEpisodes(idx, generation, src, detail_url, base, html_buf[0..n]) > 0) {
            if (cache_key) |key| content_cache.put(key, html_buf[0..n], ANIME_DETAIL_CACHE_TTL_S);
            clearScraperEpisodeFailure();
            return;
        }
        if (attempt < 2) @import("../core/io_global.zig").sleep((250 + @as(u64, attempt) * 500) * std.time.ns_per_ms);
    }
    markScraperEpisodeFailure(generation);
}

fn publishScraperEpisodes(idx: usize, generation: u32, src: AnimeScraper, detail_url: []const u8, base: []const u8, html: []const u8) usize {
    if (scraper_episode_gen.load(.acquire) != generation or workers_isQuitting()) return 0;

    // Collect episodes in document order, then reverse to oldest-first. Heap-
    // allocated (≈74 KB) — never on the worker's ~512 KB stack (CLAUDE.md).
    const EpTmp = struct {
        url: [256]u8 = undefined,
        url_len: usize = 0,
        label: [80]u8 = undefined,
        label_len: usize = 0,
        date: [12]u8 = undefined,
        date_len: usize = 0,
    };
    const tmp = alloc.alloc(EpTmp, catalog.capacity) catch return 0;
    defer alloc.free(tmp);
    var found: usize = 0;

    const addEp = struct {
        fn run(ep_url: []const u8, label: []const u8, date: []const u8, bse: []const u8, buf: []EpTmp, cnt: *usize) void {
            if (cnt.* >= buf.len) return;
            var abs_buf: [256]u8 = undefined;
            const abs = mt_pure.resolveUrl(bse, ep_url, &abs_buf);
            if (abs.len == 0 or abs.len >= 256) return;
            var e = &buf[cnt.*];
            @memcpy(e.url[0..abs.len], abs);
            e.url_len = abs.len;
            e.label_len = @min(label.len, e.label.len);
            @memcpy(e.label[0..e.label_len], label[0..e.label_len]);
            e.date_len = @min(date.len, e.date.len);
            @memcpy(e.date[0..e.date_len], date[0..e.date_len]);
            cnt.* += 1;
        }
    }.run;

    switch (src) {
        .dooplay => {
            var it = dooplay.episodeIter(html);
            while (it.next()) |e| addEp(e.url, e.label, e.date, base, tmp, &found);
            // Movie (no episode list) → single "Movie" episode = the detail page.
            // Require a real player option so a CDN/bot error page cannot be
            // cached and published as a playable movie.
            if (found == 0) {
                var players = dooplay.playerOptionIter(html);
                if (players.next() != null) addEp(detail_url, "Movie", "", base, tmp, &found);
            }
        },
        .animestream => {
            var it = animestream.episodeIter(html);
            while (it.next()) |e| {
                const lbl = if (e.title.len > 0) e.title else e.num;
                addEp(e.url, lbl, e.date, base, tmp, &found);
            }
        },
        .none => {},
    }
    if (found == 0 or workers_isQuitting()) return 0;
    if (state.app.anime.selected_idx != idx or !results_are_scraper or scraper_kind != src) return 0;
    if (!std.mem.eql(u8, scraper_detail_url[idx][0..scraper_detail_len[idx]], detail_url)) return 0;

    // Publish reversed (oldest-first) into the shared episode arrays. Episode
    // NUMBERS are 1..N (what the UI plays by); the site's own label becomes the
    // episode title. scraper_ep_url[i] is the episode page to resolve on play.
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    if (scraper_episode_gen.load(.acquire) != generation or state.app.anime.selected_idx != idx) return 0;
    const ep_n = @min(found, state.app.anime.episode_list.len);
    for (0..ep_n) |i| {
        const e = &tmp[found - 1 - i]; // reverse
        var nb: [8]u8 = undefined;
        const num = std.fmt.bufPrint(&nb, "{d}", .{i + 1}) catch "1";
        @memcpy(state.app.anime.episode_list[i][0..num.len], num);
        state.app.anime.episode_list_lens[i] = num.len;

        const ll = @min(e.label_len, state.app.anime.episode_titles[i].len);
        @memcpy(state.app.anime.episode_titles[i][0..ll], e.label[0..ll]);
        state.app.anime.episode_title_lens[i] = ll;

        const dl2 = @min(e.date_len, state.app.anime.episode_aired[i].len);
        @memcpy(state.app.anime.episode_aired[i][0..dl2], e.date[0..dl2]);
        state.app.anime.episode_aired_lens[i] = dl2;
        state.app.anime.episode_scores[i] = 0;
        state.app.anime.episode_filler[i] = false;

        @memcpy(scraper_ep_url[i][0..e.url_len], e.url[0..e.url_len]);
        scraper_ep_len[i] = e.url_len;
    }
    state.app.anime.episode_count = ep_n;
    state.app.anime.results[idx].episodes = @intCast(ep_n);

    // Hydrate watched flags from the DB (keyed by the card slug id).
    for (0..@min(ep_n, state.app.anime.episode_watched.len)) |i| state.app.anime.episode_watched[i] = false;
    const card_id = state.app.anime.results[idx].id[0..state.app.anime.results[idx].id_len];
    if (card_id.len > 0) @import("../core/db.zig").animeLoadWatched(card_id, state.app.anime.episode_watched[0..ep_n]);
    state.wakeUi();
    return ep_n;
}

/// Resolve the selected episode's EMBED URL (per framework) and hand it to
/// playEmbed. Runs on a worker thread (blocking HTTP).
fn scraperPlayThread(job: PlaybackJob) bool {
    const ep_url = job.episode_url[0..job.episode_url_len];
    if (ep_url.len == 0 or !playback_request.isCurrent(job.generation)) return false;
    var base_buf: [256]u8 = undefined;
    const base = scraperBase(job.scraper, &base_buf) orelse return false;
    const html_buf = alloc.alloc(u8, 1024 * 1024) catch return false;
    defer alloc.free(html_buf);
    const n = scraperGet(ep_url, html_buf);
    if (n == 0 or !playback_request.isCurrent(job.generation)) return false;
    var embed_buf: [1024]u8 = undefined;
    const embed = switch (job.scraper) {
        .animestream => animestream.firstEmbed(html_buf[0..n], &embed_buf),
        .dooplay => resolveDooplayEmbed(html_buf[0..n], base, ep_url, &embed_buf),
        .none => null,
    } orelse return false;
    const resolved = @import("anime_extractors.zig").resolveEmbed(embed) orelse return false;
    publishPlayback(.{ .job = job, .stream = resolved });
    return true;
}

/// DooPlay embed chain: walk #playeroptionsul, POST doo_player_ajax for each
/// server option until one returns an `embed_url`. Referer for the POST is the
/// site base (+ X-Requested-With), matching WordPress's AJAX contract.
fn resolveDooplayEmbed(html: []const u8, base: []const u8, ep_url: []const u8, out: []u8) ?[]const u8 {
    if (base.len == 0) return null;
    var ajax_url_buf: [320]u8 = undefined;
    const ajax_url = dooplay.buildAjaxUrl(base, &ajax_url_buf) orelse return null;
    const referer = if (ep_url.len > 0) ep_url else base;

    const resp_buf = alloc.alloc(u8, 128 * 1024) catch return null;
    defer alloc.free(resp_buf);

    var it = dooplay.playerOptionIter(html);
    var tried: usize = 0;
    while (it.next()) |opt| {
        if (tried >= 6) break; // bound the number of AJAX round-trips
        tried += 1;
        var body_buf: [160]u8 = undefined;
        const body = dooplay.buildAjaxBody(opt.post, opt.nume, opt.type_, &body_buf) orelse continue;
        const rn = scraperPost(ajax_url, referer, body, resp_buf);
        if (rn == 0 or workers_isQuitting()) continue;
        if (dooplay.parseEmbedUrl(resp_buf[0..rn], out)) |embed| {
            if (embed.len > 0) return embed;
        }
    }
    return null;
}

/// Resolve a streaming-host EMBED URL to a real playable stream and play it.
///
/// The Aniyomi "lib/" extractor entry point: given an embed like
/// `https://megacloud.blog/embed-2/e-1/<id>?k=1` or a StreamWish/Dood/StreamTape
/// page, resolve it (off the UI thread — the resolve blocks on HTTP), set mpv's
/// Referer via `http-header-fields`, loadfile the stream, attach subtitle tracks,
// ══════════════════════════════════════════════════════════
// UI Rendering (Drawer)
// ══════════════════════════════════════════════════════════

fn retryScraperEpisodesWhenDue(idx: usize) void {
    if (!results_are_scraper or !scraper_episode_failed.load(.acquire) or state.app.anime.is_loading.load(.acquire)) return;
    const now = @import("../core/io_global.zig").milliTimestamp();
    if (now >= scraper_episode_retry_at_ms.load(.acquire)) {
        startEpisodesScraper(idx, false);
    } else {
        components.pollRefresh(500_000);
    }
}

var native_loading_fixture = false;
pub fn setLoadingFixtureForTest(enabled: bool) void {
    if (!@import("builtin").is_test) @compileError("Browse loading fixture is test-only");
    native_loading_fixture = enabled;
    state.app.anime.is_loading.store(enabled, .release);
    state.app.anime.result_count = 0;
    state.app.anime.selected_idx = null;
    fetched_mode = state.app.anime.mode;
    fetched_nsfw_filter = state.app.nsfw_filter_enabled;
}

pub fn renderContent() void {
    // Free any poster textures queued by parse worker threads (UI-thread only).
    drainPendingTexFrees();
    applyPendingEpisodes();
    applyPendingRelations();
    applyPendingPlayback();
    syncNsfwFilter();

    // ── Mode dispatch. Each grid mode reuses results[]/renderGallery; only the
    //    fetch differs. We fire exactly once per (mode + sub-selector) change,
    //    plus SWR auto-refresh on Trending only (other modes don't cross-
    //    contaminate trending's last_fetch_s). Skipped while an anime detail is
    //    open (selected_idx != null) so the detail view stays stable. ──
    // "Airing this week" is a VIEW, not a browse mode: it has its own fetch
    // (AniList airingSchedules) and content path, so it bypasses the grid-mode
    // dispatch entirely.
    if (@import("builtin").is_test and native_loading_fixture) {
        // Actual renderer fixture without provider I/O or disk cache access.
    } else if (state.app.anime.sched_view) {
        anime_schedule.loadSchedule();
    } else if (state.app.anime.selected_idx == null) {
        // SWR seed: paint the last Trending grid from disk NOW (empty grid only)
        // so the tab isn't blank while dispatchModeFetch's revalidating fetch runs.
        seedTrendingFromCache();
        dispatchModeFetch();
    }

    // Full-page root so loading/empty branches fill width/height.
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer page.deinit();

    // Mode toolbar + per-mode sub-toolbar + count/card-size controls. Hidden
    // while an anime is selected (episode-list view has its own header).
    if (state.app.anime.selected_idx == null) {
        // Single unified toolbar row: mode tabs + the Airing toggle + per-mode
        // chips + count + zoom.
        renderModeToolbar(state.app.anime.result_count);
        // Search mode keeps the live search-as-you-type box (its own row).
        if (!state.app.anime.sched_view and state.app.anime.mode == .search) renderSearchBar();
    }

    // Airing-this-week: day-grouped schedule grid instead of the browse grid /
    // episode drill-down.
    if (state.app.anime.sched_view) {
        renderScheduleView();
        return;
    }

    // The real poster grid renders initial-load skeletons; useful refresh
    // results remain visible instead of taking a full-page loading branch.

    // Episode list (if anime selected)
    if (state.app.anime.selected_idx) |sel_idx| {
        if (sel_idx < state.app.anime.result_count) {
            retryScraperEpisodesWhenDue(sel_idx);
            const r = state.app.anime.results[sel_idx];
            {
                var navigation = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = dvui.Rect.all(4),
                });
                defer navigation.deinit();
                if (components.iconButton(@src(), icons.tvg.lucide.@"arrow-left", "Back to anime", false)) {
                    _ = scraper_episode_gen.fetchAdd(1, .acq_rel);
                    clearScraperEpisodeFailure();
                    state.app.anime.is_loading.store(false, .release);
                    state.app.anime.selected_idx = null;
                    cancelPlayback();
                    episode_request.cancel(&state.app.anime.episodes_loading);
                    state.app.anime.episode_count = 0;
                    return;
                }
                _ = dvui.label(@src(), "Anime", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5 });
            }

            // ── Rich detail header: poster (left) + title / meta / synopsis
            //    (right) — mirrors renderTvDetail's header. Poster reuses the
            //    grid's lazy poster on results[sel_idx] (same fields → no second
            //    fetch for the same URL). ──
            {
                const item = &state.app.anime.results[sel_idx];
                var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = 70,
                    .expand = .horizontal,
                    .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
                    .background = true,
                    .color_fill = theme.colors.bg_deep,
                    .color_border = theme.colors.border_subtle,
                    .border = dvui.Rect.all(0),
                });
                defer head.deinit();

                // Compact poster; reuse the browse card texture.
                {
                    var pbox = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .id_extra = 71,
                        .background = true,
                        .color_fill = theme.colors.bg_elevated,
                        .corner_radius = dvui.Rect.all(6),
                        .min_size_content = .{ .w = 72, .h = 108 },
                        .max_size_content = .{ .w = 72, .h = 108 },
                    });
                    defer pbox.deinit();

                    _ = poster.uploadIfReady(&item.poster_pixels, item.poster_w, item.poster_h, &item.poster_tex);
                    if (item.poster_tex) |*tex| {
                        _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                            .id_extra = 72,
                            .expand = .both,
                            .corner_radius = dvui.Rect.all(6),
                        });
                    } else {
                        // Same failure-latch/fetch dance as the grid so we never
                        // re-spawn a worker every frame for a dead URL.
                        // Routed through anime_pure.posterAction so the shipped decision is the
                        // tested one (see its regression test: a retired texture must not latch).
                        switch (anime_pure.posterAction(.{
                            .fetching = item.poster_fetching,
                            .attempted = item.poster_attempted,
                            .failed = item.poster_failed,
                            .has_pixels = item.poster_pixels != null,
                            .has_tex = item.poster_tex != null,
                            .has_url = item.poster_url_len > 0,
                        })) {
                            .mark_attempted => item.poster_attempted = true,
                            .latch_failed => item.poster_failed = true,
                            .fetch => {
                                poster.fetchAsync(item.poster_url[0..item.poster_url_len], &item.poster_pixels, &item.poster_w, &item.poster_h, &item.poster_fetching);
                                if (item.poster_fetching) item.poster_attempted = true;
                            },
                            .none => {},
                        }
                        if (!item.poster_failed and item.poster_url_len > 0)
                            components.coverSkeleton(@src(), 73, 6)
                        else
                            dvui.icon(@src(), "det-poster-ph", icons.tvg.lucide.film, .{}, .{
                                .id_extra = 73,
                                .gravity_x = 0.5,
                                .gravity_y = 0.5,
                                .color_text = theme.colors.text_secondary,
                                .expand = .both,
                            });
                    }
                }

                // Info column: title · meta row · synopsis.
                {
                    var info = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .id_extra = 74,
                        .expand = .horizontal,
                        .padding = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
                    });
                    defer info.deinit();

                    // Title (heading font, wraps).
                    var tn_buf: [160]u8 = undefined;
                    _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(r.name[0..r.name_len], &tn_buf)}, .{
                        .id_extra = 75,
                        .expand = .horizontal,
                        .color_text = theme.colors.text_primary,
                        .font = dvui.themeGet().font_heading,
                    });

                    // Meta row: "TV · 2024 · 24 eps" + score% + Airing chip.
                    {
                        var mrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .id_extra = 76,
                            .expand = .horizontal,
                            .padding = .{ .x = 0, .y = 4, .w = 0, .h = 2 },
                        });
                        defer mrow.deinit();

                        // Compose the "type · year · N eps" line, skipping empties.
                        var meta_buf: [64]u8 = undefined;
                        var ml: usize = 0;
                        const sep: []const u8 = " · ";
                        if (r.atype_len > 0) {
                            if (std.fmt.bufPrint(meta_buf[ml..], "{s}", .{r.atype[0..@min(r.atype_len, r.atype.len)]})) |wr| ml += wr.len else |_| {}
                        }
                        if (r.year > 0) {
                            if (std.fmt.bufPrint(meta_buf[ml..], "{s}{d}", .{ if (ml > 0) sep else "", r.year })) |wr| ml += wr.len else |_| {}
                        }
                        if (r.episodes > 0) {
                            if (std.fmt.bufPrint(meta_buf[ml..], "{s}{d} eps", .{ if (ml > 0) sep else "", r.episodes })) |wr| ml += wr.len else |_| {}
                        }
                        if (ml > 0) {
                            _ = dvui.label(@src(), "{s}", .{meta_buf[0..ml]}, .{
                                .id_extra = 77,
                                .color_text = theme.colors.text_secondary,
                                .gravity_y = 0.5,
                            });
                        }

                        // Score %.
                        if (r.score > 0) {
                            const pct = @as(u8, @intFromFloat(std.math.clamp(r.score * 10.0, 0.0, 100.0)));
                            const sc = if (pct >= 70) theme.colors.success else if (pct >= 50) theme.colors.warning else theme.colors.danger;
                            var pb: [8]u8 = undefined;
                            if (std.fmt.bufPrint(&pb, "{d}%", .{pct})) |ps| {
                                _ = dvui.label(@src(), "{s}", .{ps}, .{
                                    .id_extra = 78,
                                    .color_text = sc,
                                    .gravity_y = 0.5,
                                    .padding = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
                                });
                            } else |_| {}
                        }

                        // "Airing" chip for currently-broadcasting shows.
                        if (r.airing) {
                            _ = dvui.label(@src(), "Airing", .{}, .{
                                .id_extra = 79,
                                .background = true,
                                .color_fill = theme.colors.accent,
                                .color_text = theme.colors.text_on_accent,
                                .corner_radius = theme.dims.rad_sm,
                                .padding = .{ .x = 6, .y = 1, .w = 6, .h = 1 },
                                .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
                                .gravity_y = 0.5,
                            });
                        }
                    }

                    // Two quiet lines keep the episode browser above the fold.
                    if (r.overview_len > 0) {
                        var ov_buf: [512]u8 = undefined;
                        var overview = dvui.textLayout(@src(), .{}, .{
                            .background = false,
                            .id_extra = 80,
                            .expand = .horizontal,
                            .color_text = theme.colors.text_secondary,
                            .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
                            .max_size_content = .{ .w = std.math.floatMax(f32), .h = dvui.themeGet().font_body.lineHeight() * 2 },
                        });
                        overview.addText(safeUtf8Buf(r.overview[0..@min(r.overview_len, r.overview.len)], &ov_buf), .{});
                        overview.deinit();
                    }
                }
            }

            if (state.app.anime.episode_count > 0) {
                var toolbar = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 12, .y = 8, .w = 12, .h = 10 },
                });
                defer toolbar.deinit();
                var resume_buf: [48]u8 = undefined;
                const resume_label = std.fmt.bufPrint(&resume_buf, "Play E{d}", .{nextUnwatchedEp()}) catch "Play";
                if (components.actionButton(@src(), resume_label, .primary, 61)) {
                    var eb: [8]u8 = undefined;
                    playEpisode(std.fmt.bufPrint(&eb, "{d}", .{nextUnwatchedEp()}) catch "1");
                }
                _ = dvui.label(@src(), "{d} episodes · {d} watched", .{ state.app.anime.episode_count, watchedCount() }, .{
                    .color_text = theme.colors.text_secondary,
                    .gravity_y = 0.5,
                    .expand = .horizontal,
                    .padding = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
                });
                if (state.app.anime.episodes_loading.load(.acquire)) {
                    _ = dvui.label(@src(), "Loading details…", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5 });
                } else if (episode_failed.load(.acquire)) {
                    if (components.iconButton(@src(), icons.tvg.lucide.@"refresh-cw", "Retry episode details", false)) loadEpisodes(sel_idx);
                }
            }

            // ── Seasons & Related rail (Jikan relations) ──
            if (state.app.anime.relation_count > 0 or state.app.anime.relations_loading) {
                renderRelationsRail();
            }

            // Episode cards
            if (state.app.anime.episode_count > 0) {
                renderEpisodeGrid(sel_idx);
            } else if (state.app.anime.episodes_loading.load(.acquire)) {
                _ = dvui.label(@src(), "Loading episode details...", .{}, .{ .color_text = theme.colors.accent });
            } else if (episode_failed.load(.acquire)) {
                _ = dvui.label(@src(), "Episode catalog unavailable", .{}, .{ .color_text = theme.colors.text_secondary });
                if (components.actionButton(@src(), "Retry", .secondary, 706)) loadEpisodes(sel_idx);
            } else if (results_are_scraper and state.app.anime.is_loading.load(.acquire)) {
                _ = dvui.label(@src(), "Loading episodes…", .{}, .{
                    .color_text = theme.colors.accent,
                    .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
                });
            } else if (results_are_scraper and scraper_episode_failed.load(.acquire)) {
                _ = dvui.label(@src(), "Episode source unavailable. Retrying automatically…", .{}, .{
                    .color_text = theme.colors.accent,
                    .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
                });
                if (dvui.button(@src(), "Retry now", .{}, .{
                    .color_fill = theme.colors.bg_elevated,
                    .color_text = theme.colors.text_primary,
                    .corner_radius = theme.dims.rad_sm,
                    .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
                    .margin = .{ .x = 12, .y = 2, .w = 0, .h = 0 },
                })) startEpisodesScraper(sel_idx, true);
            } else {
                _ = dvui.label(@src(), "No episodes available", .{}, .{
                    .color_text = theme.colors.text_secondary,
                    .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
                });
            }
            return;
        }
    }

    // My List mode → Continue-Watching grid (db-backed); all other modes →
    // the standard Jikan gallery grid.
    if (state.app.anime.mode == .mylist) {
        renderContinueGrid();
    } else {
        renderGallery();
    }
}

// Dense, virtualized episode tiles. Missing provider titles keep the same
// compact footprint; play and watched are separate keyboard-focusable actions.
fn renderEpisodeGrid(sel_idx: usize) void {
    const a = &state.app.anime;
    const font = dvui.themeGet().font_body;
    const height = font.lineHeight() * 2 + 30;
    const pitch = height + 8;
    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &episode_scroll_info, .horizontal = .none, .vertical_bar = .auto_overlay }, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 0, .w = 12, .h = 8 },
        .border = dvui.Rect.all(0),
        .background = false,
    });
    defer scroll.deinit();
    const layout = catalog.episodeGrid(@max(1, scroll.data().contentRect().w - 8), a.episode_count);
    const visible = @import("tmdb_pure.zig").visibleRows(layout.rows, pitch, episode_scroll_info.viewport.y, episode_scroll_info.viewport.h, 2);
    const next = nextUnwatchedEp();
    if (visible.first > 0) {
        var spacer = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 1, .h = pitch * @as(f32, @floatFromInt(visible.first)) }, .padding = dvui.Rect.all(0) });
        spacer.deinit();
    }
    for (visible.first..visible.last) |row_idx| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_idx,
            .expand = .horizontal,
            .padding = dvui.Rect.all(0),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        defer row.deinit();
        const first = row_idx * layout.columns;
        for (first..@min(first + layout.columns, a.episode_count)) |ep_i| {
            const ep_str = a.episode_list[ep_i][0..a.episode_list_lens[ep_i]];
            const ep_num = ep_i + 1;
            const watched = a.episode_watched[ep_i];
            const is_next = ep_num == next;
            const requested = playbackEpisode() == ep_num;
            const busy = requested and a.stream_loading.load(.acquire);
            const failed = requested and playback_failed.load(.acquire);
            var card = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = ep_i,
                .background = true,
                .color_fill = if (busy) theme.colors.accent_dim else if (is_next) theme.colors.bg_elevated else theme.colors.bg_surface,
                .border = dvui.Rect.all(0),
                .corner_radius = dvui.Rect.all(8),
                .padding = dvui.Rect.all(10),
                .margin = .{ .x = 0, .y = 0, .w = if (ep_i + 1 < first + layout.columns) 8 else 0, .h = 0 },
                .min_size_content = .{ .w = @max(1, layout.width - 20), .h = height - 20 },
                .max_size_content = .{ .w = @max(1, layout.width - 20), .h = height - 20 },
            });
            defer card.deinit();
            {
                var controls = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = dvui.Rect.all(0) });
                defer controls.deinit();
                var number_buf: [32]u8 = undefined;
                const number = std.fmt.bufPrint(&number_buf, "Episode {s}", .{ep_str}) catch "Episode";
                if (dvui.button(@src(), number, .{}, .{
                    .color_fill = theme.transparent,
                    .color_fill_hover = theme.colors.bg_hover,
                    .color_text = if (is_next) theme.colors.accent else theme.colors.text_primary,
                    .border = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                    .gravity_y = 0.5,
                })) playEpisode(ep_str);
                var action_space = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = dvui.Rect.all(0) });
                action_space.deinit();
                if (busy or failed) {
                    if (dvui.button(@src(), if (busy) "Cancel" else "Retry", .{}, .{
                        .background = true,
                        .color_fill = theme.transparent,
                        .color_fill_hover = theme.colors.bg_hover,
                        .color_text = theme.colors.accent,
                        .border = dvui.Rect.all(0),
                        .corner_radius = theme.dims.rad_sm,
                        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
                        .gravity_y = 0.5,
                    })) {
                        if (busy) cancelPlayback() else playEpisode(ep_str);
                    }
                } else if (components.iconButton(@src(), icons.tvg.lucide.play, "Play episode", is_next)) playEpisode(ep_str);
                if (components.iconButton(@src(), if (watched) icons.tvg.lucide.@"circle-check-big" else icons.tvg.lucide.circle, if (watched) "Mark unwatched" else "Mark watched", watched)) toggleWatched(sel_idx, ep_num);
            }
            var title_buf: [256]u8 = undefined;
            const title = if (busy) "Finding stream…" else if (failed) "Source unavailable" else if (a.episode_title_lens[ep_i] > 0)
                safeUtf8Buf(a.episode_titles[ep_i][0..a.episode_title_lens[ep_i]], &title_buf)
            else if (a.episode_aired_lens[ep_i] > 0)
                a.episode_aired[ep_i][0..a.episode_aired_lens[ep_i]]
            else if (is_next) "Up next" else if (watched) "Watched" else "";
            var status_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = dvui.Rect.all(0),
                .min_size_content = .{ .w = 0, .h = font.lineHeight() },
            });
            defer status_row.deinit();
            if (busy) dvui.spinner(@src(), .{
                .color_text = theme.colors.accent,
                .min_size_content = .{ .w = 12, .h = 12 },
                .max_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
            });
            var caption = dvui.textLayout(@src(), .{ .break_lines = false }, .{
                .background = false,
                .expand = .horizontal,
                .padding = dvui.Rect.all(0),
                .color_text = if (busy) theme.colors.accent else if (failed) theme.colors.warning else theme.colors.text_secondary,
                .min_size_content = .{ .w = 0, .h = font.lineHeight() },
                .max_size_content = .{ .w = @max(1, layout.width - 20), .h = font.lineHeight() },
            });
            if (!busy and !failed and a.episode_filler[ep_i]) caption.addText("Filler · ", .{ .color_text = theme.colors.accent });
            caption.addText(title, .{});
            caption.deinit();
        }
    }
    if (visible.last < layout.rows) {
        var spacer = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 1, .h = pitch * @as(f32, @floatFromInt(layout.rows - visible.last)) }, .padding = dvui.Rect.all(0) });
        spacer.deinit();
    }
}

// ══════════════════════════════════════════════════════════
// "Airing this week" view — AniList airingSchedules, grouped by weekday
// ══════════════════════════════════════════════════════════

/// Render the day-grouped airing schedule. Slots arrive pre-sorted by air time
/// (AniList `sort: TIME`); we walk the 7 window days in order, printing a
/// weekday header before its episodes. All weekday / time math routes through
/// anime_schedule_pure (tested). Clicking a row kicks a universal search.
fn renderScheduleView() void {
    const asp = anime_schedule_pure;
    const loading = state.app.anime.sched_loading.load(.acquire);
    const count = state.app.anime.sched_count;

    if (loading and count == 0) {
        _ = dvui.label(@src(), "Loading airing schedule…", .{}, .{
            .color_text = theme.colors.accent,
            .gravity_x = 0.5,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
        return;
    }
    if (count == 0) {
        _ = dvui.label(@src(), "No airing schedule available right now. Try Refresh.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    const win_start = state.app.anime.sched_window_start;
    const tz = state.app.anime.sched_tz_offset_s;

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    // One pass per window day (0 = window.start's day … 6). Skip days with no
    // episodes so the list stays tight.
    var day: u8 = 0;
    while (day < 7) : (day += 1) {
        // Is anything airing this day?
        var has_any = false;
        var s: usize = 0;
        while (s < count) : (s += 1) {
            if (asp.dayIndexOf(state.app.anime.sched[s].airing_at, win_start)) |di| {
                if (di == day) {
                    has_any = true;
                    break;
                }
            }
        }
        if (!has_any) continue;

        // Day header: weekday name for this window day (local frame).
        const day_local = win_start + @as(i64, @intCast(day)) * 86400 + tz;
        _ = dvui.label(@src(), "{s}", .{asp.weekdayName(asp.weekdayMon0(day_local))}, .{
            .id_extra = @as(usize, day) + 90000,
            .expand = .horizontal,
            .color_text = theme.colors.accent,
            .background = true,
            .color_fill = theme.colors.bg_app,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        });

        // Rows for this day (already in air-time order).
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const slot = &state.app.anime.sched[i];
            const di = asp.dayIndexOf(slot.airing_at, win_start) orelse continue;
            if (di != day) continue;

            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i + 91000,
                .expand = .horizontal,
                .background = true,
                .color_fill = theme.colors.bg_surface,
                .color_border = theme.colors.border_subtle,
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            });
            defer row.deinit();

            // Air time (local HH:MM).
            var tbuf: [8]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{asp.fmtTime(slot.airing_at + tz, &tbuf)}, .{
                .id_extra = i + 92000,
                .color_text = theme.colors.text_secondary,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 48, .h = 0 },
            });

            // Title → click kicks a universal search for a stream.
            var nbuf: [160]u8 = undefined;
            const title = safeUtf8Buf(slot.title[0..slot.title_len], &nbuf);
            if (dvui.button(@src(), title, .{}, .{
                .id_extra = i + 93000,
                .expand = .horizontal,
                .color_text = theme.colors.text_primary,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                .gravity_y = 0.5,
            })) {
                anime_schedule.clickSlot(i);
            }

            // Episode badge.
            if (slot.episode > 0) {
                var eb: [16]u8 = undefined;
                const es = std.fmt.bufPrintZ(&eb, "Ep {d}", .{@as(u32, @intCast(slot.episode))}) catch "";
                _ = dvui.label(@src(), "{s}", .{es}, .{
                    .id_extra = i + 94000,
                    .color_text = theme.colors.accent,
                    .gravity_y = 0.5,
                    .padding = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
                });
            }
        }
    }
}

/// Fire the right fetch for the active mode, exactly once per change. Trending
/// also keeps its SWR auto-refresh; the other modes only refetch when their
/// sub-selector (season/day/filter) changes or on an explicit mode switch.
fn dispatchModeFetch() void {
    // Selector changes supersede in-flight work. Only unchanged automatic
    // trending refreshes are coalesced; epochs stop the previous transport.
    const busy = state.app.anime.is_loading.load(.acquire);
    const m = state.app.anime.mode;
    switch (m) {
        .trending => {
            // Initial load + SWR background refresh (trending only).
            const stale = state.app.anime.result_count == 0 or
                @import("browse_cache.zig").isStale(state.app.anime.last_fetch_s);
            if (fetched_mode != .trending or (stale and !busy)) {
                fetched_mode = .trending;
                loadTrendingAnime();
            }
        },
        .seasonal => {
            if (fetched_mode != .seasonal or
                fetched_season_sel != state.app.anime.season_sel or
                fetched_season_year != state.app.anime.season_year)
            {
                fetched_mode = .seasonal;
                fetched_season_sel = state.app.anime.season_sel;
                fetched_season_year = state.app.anime.season_year;
                loadSeasonal();
            }
        },
        .calendar => {
            if (fetched_mode != .calendar or fetched_cal_day != state.app.anime.cal_day) {
                fetched_mode = .calendar;
                fetched_cal_day = state.app.anime.cal_day;
                loadCalendar();
            }
        },
        .search => {
            // Search fires from the live search box (renderSearchBar). On first
            // entry with an empty box, show trending-style results once.
            if (fetched_mode != .search) {
                fetched_mode = .search;
                const buf = std.mem.sliceTo(&state.app.anime.search_buf, 0);
                if (buf.len >= 2) {
                    recordFired(buf);
                    searchAnime(buf);
                } else if (state.app.anime.result_count == 0) {
                    // Site-framework source installed → show its popular/latest
                    // catalog; otherwise the Jikan trending grid.
                    if (activeScraper() != .none) loadScraperPopular() else loadTrendingAnime();
                }
            }
        },
        .mylist => {
            if (fetched_mode != .mylist) fetched_mode = .mylist;
            if (!state.app.anime.continue_loaded) loadContinue();
        },
    }
}

/// Apply Settings › NSFW Filter changes to every Anime browse view. Enabling
/// it clears the visible grid before a safe cache/network refresh, so previously
/// loaded adult cards never linger on screen. Disabling it keeps the safe grid
/// visible while the broader result set refreshes.
fn syncNsfwFilter() void {
    const enabled = state.app.nsfw_filter_enabled;
    if (fetched_nsfw_filter != enabled) {
        fetched_nsfw_filter = enabled;
        fetched_mode = null;
        state.app.anime.last_fetch_s = 0;
        grid_page = 1;
        more_available.store(false, .release);
        search_request.cancel(&state.app.anime.is_loading);
        anime_schedule.refresh();
        clear_for_safe_refresh = enabled;
    }
    if (clear_for_safe_refresh and state.app.anime.selected_idx == null) {
        state.app.anime.result_count = 0;
        clear_for_safe_refresh = false;
    }
}

// ══════════════════════════════════════════════════════════
// Mode toolbar (Trending | Seasonal | Calendar | Search | My List)
// ══════════════════════════════════════════════════════════

var native_toolbar_rect: dvui.Rect.Physical = undefined;
pub fn nativeToolbarRectForTest() dvui.Rect.Physical {
    if (!@import("builtin").is_test) @compileError("Native fixture is test-only");
    return native_toolbar_rect;
}
fn renderModeToolbar(count: usize) void {
    // Keep controls in one scrollable row; narrow windows retain the gallery.
    const height = @import("../ui/browse_layout_pure.zig").toolbarHeight(dvui.themeGet().font_body.size);
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto, .horizontal_bar = .auto_overlay, .vertical = .none }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = height },
        .max_size_content = dvui.Options.MaxSize.height(height),
        .background = false,
    });
    defer scroll.deinit();
    if (@import("builtin").is_test) native_toolbar_rect = scroll.data().borderRectScale().r;
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 6 },
        .background = true,
        .color_fill = theme.colors.bg_app,
    });
    defer bar.deinit();

    renderModeTab(0, .trending, "Trending");
    renderModeTab(1, .seasonal, "Seasonal");
    renderModeTab(2, .calendar, "Calendar");
    if (@import("../ui/browse_layout_pure.zig").showLocalSearch(state.app.page_shell_enabled)) renderModeTab(3, .search, "Search");
    renderModeTab(4, .mylist, "My List");

    // ── "Airing this week" view toggle (AniList schedule) — a VIEW, not a mode,
    //    so it's a separate toggle rather than another mode tab. ──
    toolbarDivider(888);
    {
        const airing = state.app.anime.sched_view;
        if (dvui.button(@src(), "Airing this week", .{}, .{
            .id_extra = 20099,
            .background = true,
            .color_fill = if (airing) theme.colors.accent else theme.colors.bg_surface,
            .color_text = if (airing) dvui.Color.white else theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            state.app.anime.sched_view = !airing;
        }
    }
    // While the schedule view is active the per-mode browse chips are irrelevant.
    if (state.app.anime.sched_view) {
        // Airing view: show a refresh + a live episode count instead of the
        // browse chips / results counter.
        toolbarDivider(951);
        if (dvui.button(@src(), "Refresh", .{}, .{
            .id_extra = 20098,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
        })) {
            anime_schedule.refresh();
        }
        _ = dvui.label(@src(), "{d} episodes", .{state.app.anime.sched_count}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .padding = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
        });
        return;
    }

    // Per-mode chips, inline on the same row.
    switch (state.app.anime.mode) {
        .trending => {
            toolbarDivider(889);
            renderTrendChip(0, .airing, "Airing");
            renderTrendChip(1, .top, "Top");
            renderTrendChip(2, .bypopularity, "Popular");
            renderTrendChip(3, .upcoming, "Upcoming");
            // Only offered when the `lists` source plugin is installed — with no
            // endpoint the source is inert, so we don't advertise a dead chip.
            if (listsBase() != null) renderTrendChip(4, .lists, "Lists");
        },
        .seasonal => {
            toolbarDivider(889);
            renderSeasonalSubToolbar();
        },
        .calendar => {
            toolbarDivider(889);
            renderCalendarSubToolbar();
        },
        else => {},
    }

    // Result count + card-size −/+ (always, same row).
    toolbarDivider(950);
    _ = dvui.label(@src(), "{d} results", .{count}, .{
        .color_text = theme.colors.text_secondary,
        .gravity_y = 0.5,
    });
    const dim = dvui.Color{ .r = 120, .g = 120, .b = 148, .a = 200 };
    if (dvui.buttonIcon(@src(), "smaller", icons.tvg.lucide.minus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        card_w_pref = @max(110, card_w_pref - 40);
    }
    if (dvui.buttonIcon(@src(), "bigger", icons.tvg.lucide.plus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        card_w_pref = @min(320, card_w_pref + 40);
    }
}

fn renderModeTab(idx: usize, m: state.AnimeMode, label: []const u8) void {
    const active = state.app.anime.mode == m;
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = idx + 20000,
        .background = true,
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_surface,
        .color_text = if (active) dvui.Color.white else theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
        .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
    })) {
        setMode(m);
    }
}

/// Per-mode sub-toolbar (season selector / calendar days). Trending's category
/// chips live in renderToolbar; Search/My List have no sub-toolbar.
fn renderSubToolbar() void {
    switch (state.app.anime.mode) {
        .seasonal => renderSeasonalSubToolbar(),
        .calendar => renderCalendarSubToolbar(),
        else => {},
    }
}

fn renderSeasonChip(idx: usize, sel: state.AnimeSeasonSel, label: []const u8) void {
    const active = state.app.anime.season_sel == sel;
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = idx + 21000,
        .background = true,
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_surface,
        .color_text = if (active) dvui.Color.white else theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
    })) {
        state.app.anime.season_sel = sel;
    }
}

fn renderSeasonalSubToolbar() void {
    // No own flexbox — renders chips into the unified toolbar row (renderModeToolbar).
    renderSeasonChip(0, .now, "This Season");
    renderSeasonChip(1, .winter, "Winter");
    renderSeasonChip(2, .spring, "Spring");
    renderSeasonChip(3, .summer, "Summer");
    renderSeasonChip(4, .fall, "Fall");
    toolbarDivider(960);

    // Year stepper (only meaningful for the four named cours; still shown so the
    // user can pre-set a year before picking a season).
    if (dvui.button(@src(), "−", .{}, .{
        .id_extra = 21100,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
    })) {
        if (state.app.anime.season_year > 1960) state.app.anime.season_year -= 1;
    }
    {
        var yb: [8]u8 = undefined;
        const ys = std.fmt.bufPrint(&yb, "{d}", .{state.app.anime.season_year}) catch "----";
        _ = dvui.label(@src(), "{s}", .{ys}, .{
            .id_extra = 21101,
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
    }
    if (dvui.button(@src(), "+", .{}, .{
        .id_extra = 21102,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .margin = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
    })) {
        if (state.app.anime.season_year < 2027) state.app.anime.season_year += 1;
    }

    toolbarDivider(961);
    renderSeasonChip(5, .upcoming, "Upcoming");
}

fn renderCalDayChip(idx: usize, day: u8, label: []const u8) void {
    const active = state.app.anime.cal_day == day;
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = idx + 22000,
        .background = true,
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_surface,
        .color_text = if (active) dvui.Color.white else theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
    })) {
        state.app.anime.cal_day = day;
    }
}

fn renderCalendarSubToolbar() void {
    // No own flexbox — renders chips into the unified toolbar row (renderModeToolbar).
    renderCalDayChip(0, 0, "All");
    renderCalDayChip(1, 1, "Mon");
    renderCalDayChip(2, 2, "Tue");
    renderCalDayChip(3, 3, "Wed");
    renderCalDayChip(4, 4, "Thu");
    renderCalDayChip(5, 5, "Fri");
    renderCalDayChip(6, 6, "Sat");
    renderCalDayChip(7, 7, "Sun");
}

// ══════════════════════════════════════════════════════════
// Continue-Watching grid (My List mode)
// ══════════════════════════════════════════════════════════

fn renderContinueGrid() void {
    if (state.app.anime.continue_count == 0) {
        _ = dvui.label(@src(), "Nothing here yet — play an episode and it'll show up to resume.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const card_target_w: f32 = card_w_pref;
    const cols: usize = @max(1, @as(usize, @intFromFloat(avail_w / card_target_w)));
    const card_w: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));
    const total = state.app.anime.result_count;
    if (total == 0) {
        components.coverSkeletonGrid(@src(), 68000, cols, card_w, card_w * 1.45, GRID_CARD_EXTRA_H + 6, 3);
        return;
    }

    var i: usize = 0;
    while (i < state.app.anime.continue_count) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 72000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and i + col < state.app.anime.continue_count) : (col += 1) {
            renderContinueCard(&state.app.anime.continue_items[i + col], i + col, card_w);
        }
        i += cols;
    }
}

fn renderContinueCard(item: *state.ContinueItem, idx: usize, card_w: f32) void {
    if (item.title_len == 0) return;
    const title = item.title[0..item.title_len];
    const hue: u32 = @as(u32, @intCast(idx * 7 + 42)) *% 2654435761;
    const h1: u8 = @truncate(hue & 0xFF);
    const h2: u8 = @truncate((hue >> 8) & 0xFF);
    const poster_h: f32 = card_w * 1.45;

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx + 30000,
        .min_size_content = .{ .w = card_w, .h = 10 },
        .max_size_content = .{ .w = card_w, .h = poster_h + 70 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(6),
        .margin = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
    });
    defer card.deinit();

    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = idx + 30100,
            .background = true,
            .color_fill = dvui.Color{ .r = 20 + h1 / 6, .g = 25 + h2 / 8, .b = 35 + h1 / 5, .a = 255 },
            .corner_radius = .{ .x = theme.radius.md, .y = theme.radius.md, .w = 0, .h = 0 },
            .min_size_content = .{ .w = card_w, .h = poster_h },
            .max_size_content = .{ .w = card_w, .h = poster_h },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();

        // Upload pixels → texture once ready (same lifecycle as AnimeResult).
        _ = poster.uploadIfReady(&item.poster_pixels, item.poster_w, item.poster_h, &item.poster_tex);

        {
            var stack = dvui.overlay(@src(), .{ .id_extra = idx + 30140, .expand = .both });
            defer stack.deinit();

            if (item.poster_tex) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = idx + 30150,
                    .expand = .both,
                    .corner_radius = dvui.Rect.all(6),
                });
            } else {
                // Failure-latch (mirrors TmdbItem/JfItem): stop re-spawning a
                // poster worker every frame for a dead/undecodable URL.
                // Routed through anime_pure.posterAction so the shipped decision is the
                // tested one (see its regression test: a retired texture must not latch).
                switch (anime_pure.posterAction(.{
                    .fetching = item.poster_fetching,
                    .attempted = item.poster_attempted,
                    .failed = item.poster_failed,
                    .has_pixels = item.poster_pixels != null,
                    .has_tex = item.poster_tex != null,
                    .has_url = item.poster_url_len > 0,
                })) {
                    .mark_attempted => item.poster_attempted = true,
                    .latch_failed => item.poster_failed = true,
                    .fetch => {
                        poster.fetchAsync(item.poster_url[0..item.poster_url_len], &item.poster_pixels, &item.poster_w, &item.poster_h, &item.poster_fetching);
                        if (item.poster_fetching) item.poster_attempted = true;
                    },
                    .none => {},
                }
                if (!item.poster_failed and item.poster_url_len > 0)
                    components.coverSkeleton(@src(), idx + 30150, 6)
                else
                    dvui.icon(@src(), "", icons.tvg.lucide.play, .{}, .{
                        .id_extra = idx + 30150,
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .color_text = dvui.Color{ .r = h1, .g = h2, .b = 180, .a = 80 },
                        .expand = .both,
                    });
            }

            // "E{last}/{total}" progress badge, bottom-left.
            {
                var badge: [24]u8 = undefined;
                const bs = std.fmt.bufPrintZ(&badge, "E{d}/{d}", .{ item.last_episode, item.total_episodes }) catch "";
                if (bs.len > 0) {
                    var bb = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = idx + 30160,
                        .gravity_x = 0.02,
                        .gravity_y = 0.98,
                        .background = true,
                        .color_fill = dvui.Color{ .r = 8, .g = 10, .b = 16, .a = 220 },
                        .corner_radius = dvui.Rect.all(4),
                        .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
                    });
                    defer bb.deinit();
                    _ = dvui.label(@src(), "{s}", .{bs}, .{ .id_extra = idx + 30161, .color_text = theme.colors.accent });
                }
            }
        }

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (clicked) jumpToAnime(item.mal_id[0..item.mal_id_len]);
    }

    // Info column.
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 30200,
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 0 },
        });
        defer info.deinit();

        if (dvui.button(@src(), safeUtf8(title), .{}, .{
            .id_extra = idx + 30500,
            .expand = .horizontal,
            .color_text = theme.colors.text_primary,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .padding = dvui.Rect.all(0),
        })) {
            jumpToAnime(item.mal_id[0..item.mal_id_len]);
        }

        // "Continue E{last+1}/{total}" resume line.
        {
            const next_ep: u32 = @as(u32, item.last_episode) + 1;
            var rb: [40]u8 = undefined;
            const rs = std.fmt.bufPrintZ(&rb, "Continue E{d}/{d}", .{ next_ep, item.total_episodes }) catch "Continue";
            _ = dvui.label(@src(), "{s}", .{rs}, .{
                .id_extra = idx + 30600,
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            });
        }
    }
}

// ══════════════════════════════════════════════════════════
// Seasons & Related rail (detail view)
// ══════════════════════════════════════════════════════════

/// Horizontal chip rail of franchise relations (Sequel/Prequel/Side Story/…).
/// Clicking a chip jumps to that anime via /anime/{mal_id} → loadEpisodes.
fn renderRelationsRail() void {
    var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 80000,
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 4 },
    });
    defer wrap.deinit();

    _ = dvui.label(@src(), "Seasons & Related", .{}, .{
        .id_extra = 80001,
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
    });

    if (state.app.anime.relations_loading and state.app.anime.relation_count == 0) {
        _ = dvui.label(@src(), "Loading related…", .{}, .{
            .id_extra = 80002,
            .color_text = theme.colors.accent,
        });
        return;
    }

    var rail = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .id_extra = 80003,
        .expand = .horizontal,
    });
    defer rail.deinit();

    var i: usize = 0;
    while (i < state.app.anime.relation_count and i < state.app.anime.relations.len) : (i += 1) {
        const rel = &state.app.anime.relations[i];
        if (rel.name_len == 0) continue;
        var lbl: [160]u8 = undefined;
        const ls = std.fmt.bufPrintZ(&lbl, "{s}: {s}", .{
            rel.rel_type[0..rel.rel_type_len],
            safeUtf8(rel.name[0..@min(rel.name_len, 100)]),
        }) catch continue;
        if (dvui.button(@src(), ls, .{}, .{
            .id_extra = i + 80100,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        })) {
            jumpToAnime(rel.mal_id[0..rel.mal_id_len]);
        }
    }
}

// ══════════════════════════════════════════════════════════
// Search bar + toolbar (live search, chips, card-size controls)
// ══════════════════════════════════════════════════════════

/// Search box with LIVE / incremental search-as-you-type (350ms debounce) plus
/// the explicit Enter / button path. Empty query → trending.
fn renderSearchBar() void {
    if (!@import("../ui/browse_layout_pure.zig").showLocalSearch(state.app.page_shell_enabled)) return;
    const io = @import("../core/io_global.zig");

    var search_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .background = true,
        .color_fill = theme.colors.bg_app,
    });
    defer search_row.deinit();

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.anime.search_buf },
        .placeholder = "Search anime…",
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 200, .h = 20 },
        .color_fill = theme.colors.bg_elevated,
        .color_border = theme.colors.border_subtle,
        .color_text = theme.colors.text_primary,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_sm,
    });
    const enter_pressed = te.enter_pressed;
    te.deinit();

    const clicked = dvui.button(@src(), "Search", .{}, .{
        .color_fill = theme.colors.accent,
        .color_text = dvui.Color.white,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
    });

    // Current buffer contents (NUL-terminated fixed buffer).
    const buf = std.mem.sliceTo(&state.app.anime.search_buf, 0);
    const now_ms = io.milliTimestamp();

    // 1) Detect an edit this frame vs. the previous snapshot → restamp the
    //    debounce clock so we only fire after the user pauses typing.
    const changed = !(buf.len == last_buf_snapshot_len and
        std.mem.eql(u8, buf, last_buf_snapshot[0..last_buf_snapshot_len]));
    if (changed) {
        const n = @min(buf.len, last_buf_snapshot.len);
        @memcpy(last_buf_snapshot[0..n], buf[0..n]);
        last_buf_snapshot_len = n;
        last_edit_ms = now_ms;
    }

    // 2) Explicit fire (button / Enter) — immediate, no debounce.
    if (clicked or enter_pressed) {
        if (buf.len > 0) {
            recordFired(buf);
            searchAnime(buf);
        } else {
            // Empty query → back to trending.
            recordFired(buf);
            loadTrendingAnime();
        }
        return;
    }

    // 3) Live / debounced fire: buffer differs from what we last fired, has
    //    settled for >= 350ms, and is long enough to be a useful query.
    const differs = !(buf.len == last_fired_len and
        std.mem.eql(u8, buf, last_fired_query[0..last_fired_len]));
    if (differs and (now_ms - last_edit_ms) >= 350) {
        if (buf.len >= 2) {
            recordFired(buf);
            searchAnime(buf);
        } else if (buf.len == 0 and last_fired_len > 0) {
            // Cleared the box → restore trending.
            recordFired(buf);
            loadTrendingAnime();
        }
    }
}

/// Remember the query we just fired, so we don't re-fire it next frame.
fn recordFired(buf: []const u8) void {
    const n = @min(buf.len, last_fired_query.len);
    @memcpy(last_fired_query[0..n], buf[0..n]);
    last_fired_len = n;
}

/// Compact toolbar: trending category chips (only on the trending view),
/// a result count, and card-size +/- controls. Wraps on narrow widths.
fn renderToolbar(count: usize) void {
    const on_trending = state.app.anime.mode == .trending;

    var bar = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .margin = .{ .x = 8, .y = 0, .w = 8, .h = 6 },
    });
    defer bar.deinit();

    // Trending category chips (Jikan top/anime filters) — only in Trending mode.
    if (on_trending) {
        renderTrendChip(0, .airing, "Airing");
        renderTrendChip(1, .top, "Top");
        renderTrendChip(2, .bypopularity, "Popular");
        renderTrendChip(3, .upcoming, "Upcoming");
        toolbarDivider(900);
    }

    // Result count.
    _ = dvui.label(@src(), "{d} results", .{count}, .{
        .color_text = theme.colors.text_secondary,
        .gravity_y = 0.5,
    });

    // Card-size −/+ controls.
    toolbarDivider(950);
    const dim = dvui.Color{ .r = 120, .g = 120, .b = 148, .a = 200 };
    if (dvui.buttonIcon(@src(), "smaller", icons.tvg.lucide.minus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        card_w_pref = @max(110, card_w_pref - 40);
    }
    if (dvui.buttonIcon(@src(), "bigger", icons.tvg.lucide.plus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        card_w_pref = @min(320, card_w_pref + 40);
    }
}

/// A faint vertical separator between toolbar groups.
fn toolbarDivider(id: usize) void {
    var d = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .min_size_content = .{ .w = 1, .h = 18 },
        .background = true,
        .color_fill = theme.colors.border_subtle,
        .margin = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .gravity_y = 0.5,
    });
    d.deinit();
}

fn renderTrendChip(idx: usize, filter: TrendFilter, label: []const u8) void {
    const active = trend_filter == filter;
    const icon = switch (filter) {
        .airing => icons.tvg.lucide.radio,
        .top => icons.tvg.lucide.trophy,
        .bypopularity => icons.tvg.lucide.flame,
        .upcoming => icons.tvg.lucide.calendar,
        .lists => icons.tvg.lucide.list,
    };
    if (components.filterChip(@src(), label, icon, active, idx + 8000)) {
        if (trend_filter != filter) {
            trend_filter = filter;
            // Force a refresh even if SWR thinks the cache is fresh.
            state.app.anime.last_fetch_s = 0;
            loadTrendingAnime();
        }
    }
}

// ══════════════════════════════════════════════════════════
// Gallery Grid & Poster Cards
// ══════════════════════════════════════════════════════════

fn renderGallery() void {
    if (state.app.anime.result_count == 0 and !state.app.anime.is_loading.load(.acquire)) {
        components.emptyState(icons.tvg.lucide.sparkles, "No anime found", "Try another search or trending filter.");
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    // Responsive poster grid from the LIVE page width (one-frame lag; first
    // paint falls back to a sane default). Card width is user-cyclable.
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const card_target_w: f32 = card_w_pref;
    const cols: usize = @max(1, @as(usize, @intFromFloat(avail_w / card_target_w)));
    const card_w: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));
    const total = state.app.anime.result_count;
    if (total == 0) {
        components.coverSkeletonGrid(@src(), 68000, cols, card_w, card_w * 1.45, GRID_CARD_EXTRA_H + 6, 3);
        return;
    }

    // ── Virtualization (same shape as tmdb.zig renderGallery) ──
    // Uniform cards → fixed row pitch: content (poster + footer) + the card's
    // 6px bottom padding + 3px top/bottom margins. Off-viewport rows (±2
    // overscan) collapse into spacer boxes.
    const row_h: f32 = card_w * 1.45 + GRID_CARD_EXTRA_H + 6 + 6;
    const total_rows = (total + cols - 1) / cols;
    const win = @import("tmdb_pure.zig").visibleRows(total_rows, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 2);

    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 69998,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) },
        });
        sp.deinit();
    }

    var r: usize = win.first;
    while (r < win.last) : (r += 1) {
        const base = r * cols;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = base + 70000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and base + col < total) : (col += 1) {
            renderCard(&state.app.anime.results[base + col], base + col, card_w);
        }
    }

    if (win.last < total_rows) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 69999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(total_rows - win.last)) },
        });
        sp.deinit();
    }

    // ── Infinite scroll: a status row at the grid's tail (mirrors comics.zig).
    // When it scrolls near the bottom (viewport within 1.5 viewports of the
    // content end) we kick the next-page appender; the row also doubles as a
    // tap-to-load affordance. Only shown while there's a next page AND room.
    if (more_available.load(.acquire) and state.app.anime.result_count > 0 and
        state.app.anime.result_count < state.app.anime.results.len)
    {
        const busy = grid_loading_more.load(.acquire);
        if (busy) {
            dvui.spinner(@src(), .{
                .color_text = theme.colors.accent,
                .min_size_content = theme.iconSize(.lg),
                .gravity_x = 0.5,
                .margin = .{ .x = 3, .y = 8, .w = 3, .h = 12 },
            });
            state.wakeUi();
        } else if (components.filterChip(@src(), "More", icons.tvg.lucide.@"chevrons-down", false, 80002)) {
            loadMoreGrid(); // tap fallback
        }

        // Auto-trigger when the user scrolls near the bottom (within 1.5 view-
        // ports of the content end), so it feels infinite without a click.
        const si = scroll.si;
        const max_scroll = si.scrollMax(.vertical);
        if (max_scroll <= 0 or si.viewport.y >= max_scroll - si.viewport.h * 1.5) {
            loadMoreGrid();
        }
    }
}

/// Dimmed scrim + metadata shown over an anime poster while hovered.
/// Mirrors tmdb.zig renderHoverMeta — full title, score %, episode count,
/// and a truncated (UTF-8-safe) synopsis.
fn renderHoverMeta(item: *state.AnimeResult, idx: usize) void {
    var ov = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx + 1600,
        .expand = .both,
        .background = true,
        .color_fill = dvui.Color{ .r = 8, .g = 10, .b = 16, .a = 232 },
        .corner_radius = dvui.Rect.all(6),
        .padding = dvui.Rect.all(8),
    });
    defer ov.deinit();

    // Title (full, wraps).
    var hover_name_buf: [128]u8 = undefined;
    _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(item.name[0..@min(item.name_len, item.name.len)], &hover_name_buf)}, .{
        .id_extra = idx + 1601,
        .expand = .horizontal,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
    });

    // Score % · episode count line.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx + 1602,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
        });
        defer line.deinit();

        const pct = @as(u8, @intFromFloat(std.math.clamp(item.score * 10.0, 0.0, 100.0)));
        const sc = if (pct >= 70) theme.colors.success else if (pct >= 50) theme.colors.warning else theme.colors.danger;
        var pb: [8]u8 = undefined;
        if (std.fmt.bufPrint(&pb, "{d}%", .{pct})) |ps| {
            _ = dvui.label(@src(), "{s}", .{ps}, .{ .id_extra = idx + 1603, .color_text = sc });
        } else |_| {}

        var eb: [24]u8 = undefined;
        if (std.fmt.bufPrint(&eb, "  {d} eps", .{item.episodes})) |es| {
            _ = dvui.label(@src(), "{s}", .{es}, .{ .id_extra = idx + 1604, .color_text = theme.colors.text_secondary });
        } else |_| {}
    }

    // Synopsis (truncated ~300 chars; safeUtf8 trims any mid-codepoint cut).
    if (item.overview_len > 0) {
        var hover_ov_buf: [512]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(item.overview[0..@min(item.overview_len, 300)], &hover_ov_buf)}, .{
            .id_extra = idx + 1605,
            .expand = .horizontal,
            .color_text = theme.colors.text_secondary,
        });
    }
}

fn renderCard(item: *state.AnimeResult, idx: usize, card_w: f32) void {
    if (item.name_len == 0) return;
    // Snapshot+validate: a fetch worker can rewrite item.name mid-frame; dvui
    // panics on invalid UTF-8 it reads after validation (Utf8Invalid…).
    var title_buf: [128]u8 = undefined;
    const title = safeUtf8Buf(item.name[0..item.name_len], &title_buf);
    const hue: u32 = @as(u32, @intCast(idx * 7 + 42)) *% 2654435761;
    const h1: u8 = @truncate(hue & 0xFF);
    const h2: u8 = @truncate((hue >> 8) & 0xFF);

    const poster_h: f32 = card_w * 1.45;
    // min == max height → uniform row pitch, which the grid's virtualization
    // spacer math depends on (see GRID_CARD_EXTRA_H).
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx + 1000,
        .min_size_content = .{ .w = card_w, .h = poster_h + GRID_CARD_EXTRA_H },
        .max_size_content = .{ .w = card_w, .h = poster_h + GRID_CARD_EXTRA_H },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(6),
        .margin = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
    });
    defer card.deinit();

    // Poster placeholder / texture — a clickable button-widget hosting the
    // image, with a hover overlay revealing full metadata. Clicking the poster
    // loads episodes (same action as clicking the title).
    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = idx + 100,
            .background = true,
            .color_fill = dvui.Color{ .r = 20 + h1 / 6, .g = 25 + h2 / 8, .b = 35 + h1 / 5, .a = 255 },
            .corner_radius = .{ .x = theme.radius.md, .y = theme.radius.md, .w = 0, .h = 0 },
            .min_size_content = .{ .w = card_w, .h = poster_h },
            .max_size_content = .{ .w = card_w, .h = poster_h },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();

        // Upload pixels to GPU texture once ready
        _ = poster.uploadIfReady(&item.poster_pixels, item.poster_w, item.poster_h, &item.poster_tex);

        // Stack the poster + (on hover) a meta overlay, both filling the button.
        {
            var stack = dvui.overlay(@src(), .{ .id_extra = idx + 140, .expand = .both });
            defer stack.deinit();

            if (item.poster_tex) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = idx + 150,
                    .expand = .both,
                    .corner_radius = dvui.Rect.all(6),
                });
            } else {
                // Kick off async poster download via the shared poster daemon
                // (http.fetchImage — the proven path TMDB/Jellyfin use; the old
                // bespoke curl fetch left anime cards on placeholders). Latch
                // permanent failure so we stop re-spawning a worker every frame.
                // Routed through anime_pure.posterAction so the shipped decision is the
                // tested one (see its regression test: a retired texture must not latch).
                switch (anime_pure.posterAction(.{
                    .fetching = item.poster_fetching,
                    .attempted = item.poster_attempted,
                    .failed = item.poster_failed,
                    .has_pixels = item.poster_pixels != null,
                    .has_tex = item.poster_tex != null,
                    .has_url = item.poster_url_len > 0,
                })) {
                    .mark_attempted => item.poster_attempted = true,
                    .latch_failed => item.poster_failed = true,
                    .fetch => {
                        poster.fetchAsync(item.poster_url[0..item.poster_url_len], &item.poster_pixels, &item.poster_w, &item.poster_h, &item.poster_fetching);
                        if (item.poster_fetching) item.poster_attempted = true;
                    },
                    .none => {},
                }
                if (!item.poster_failed and item.poster_url_len > 0)
                    components.coverSkeleton(@src(), idx + 150, 6)
                else
                    dvui.icon(@src(), "", icons.tvg.lucide.film, .{}, .{
                        .id_extra = idx + 150,
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .color_text = dvui.Color{ .r = h1, .g = h2, .b = 180, .a = 80 },
                        .expand = .both,
                    });
            }

            // Hover reveals richer metadata over a dimmed scrim.
            if (bw.hovered()) renderHoverMeta(item, idx);
        }

        const poster_clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (poster_clicked) loadEpisodes(idx);
    }

    // Info column
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 200,
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 0 },
        });
        defer info.deinit();

        // Title — click to load episodes
        if (dvui.button(@src(), title, .{}, .{
            .id_extra = idx + 500,
            .expand = .horizontal,
            .color_text = theme.colors.text_primary,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .padding = dvui.Rect.all(0),
        })) {
            loadEpisodes(idx);
        }

        // Meta row: episodes + score
        {
            var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = idx + 600,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            });
            defer meta.deinit();

            // Episode count
            var ep_buf: [32]u8 = undefined;
            if (std.fmt.bufPrintZ(&ep_buf, "{d} eps", .{item.episodes})) |eps| {
                _ = dvui.label(@src(), "{s}", .{eps}, .{ .id_extra = idx + 610, .color_text = theme.colors.text_secondary });
            } else |_| {}

            _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 620, .color_text = theme.colors.text_secondary });

            // Score percentage
            const pct = @as(u8, @intFromFloat(std.math.clamp(item.score * 10.0, 0.0, 100.0)));
            const sc = if (pct >= 70) theme.colors.success else if (pct >= 50) theme.colors.warning else theme.colors.danger;
            var pb: [8]u8 = undefined;
            if (std.fmt.bufPrintZ(&pb, "{d}%", .{pct})) |ps| {
                _ = dvui.label(@src(), "{s}", .{ps}, .{ .id_extra = idx + 310, .color_text = sc });
            } else |_| {}
        }

        // Airtime badge aligned to this result index: Calendar fills it with
        // Jikan's broadcast.string ("Mondays at 01:00 (JST)"), the Lists plugin
        // with the next episode ("Ep 1170 · Jul 19"). Every other load path zeroes
        // broadcast_lens[], so a non-zero length here always means "this card has
        // a badge" — no mode check needed.
        if (idx < state.app.anime.broadcast_lens.len and
            state.app.anime.broadcast_lens[idx] > 0)
        {
            const bcast = state.app.anime.broadcast[idx][0..state.app.anime.broadcast_lens[idx]];
            var bb = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = idx + 640,
                .background = true,
                .color_fill = dvui.Color{ .r = 30, .g = 36, .b = 52, .a = 255 },
                .corner_radius = dvui.Rect.all(4),
                .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                .padding = .{ .x = 5, .y = 1, .w = 5, .h = 1 },
            });
            defer bb.deinit();
            dvui.icon(@src(), "", icons.tvg.lucide.clock, .{}, .{
                .id_extra = idx + 641,
                .color_text = theme.colors.accent,
                .min_size_content = .{ .w = 11, .h = 11 },
                .gravity_y = 0.5,
            });
            _ = dvui.label(@src(), "{s}", .{safeUtf8(bcast)}, .{
                .id_extra = idx + 642,
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
            });
        }

        // Synopsis snippet (click to expand)
        if (item.overview_len > 0) {
            var btn_buf: [128]u8 = undefined;
            var snip_buf: [64]u8 = undefined;
            const snip_len = @min(item.overview_len, 60);
            const snip = safeUtf8Buf(item.overview[0..snip_len], &snip_buf);
            const suffix: []const u8 = if (item.overview_len > 60) "..." else "";
            if (std.fmt.bufPrintZ(&btn_buf, "{s}{s}", .{ snip, suffix })) |snip_z| {
                if (dvui.button(@src(), snip_z, .{}, .{
                    .id_extra = idx + 650,
                    .color_text = theme.colors.text_secondary,
                    .expand = .horizontal,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .padding = dvui.Rect.all(0),
                })) {
                    item.expanded = !item.expanded;
                }
            } else |_| {}
        }

        // Full overview when expanded
        if (item.expanded and item.overview_len > 0) {
            var ov_buf: [512]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(item.overview[0..@min(item.overview_len, ov_buf.len)], &ov_buf)}, .{
                .id_extra = idx + 700,
                .color_text = theme.colors.text_secondary,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 4, .w = 0, .h = 2 },
            });
        }
    }

    // ── Right-click context menu ──
    {
        const ctext = dvui.context(@src(), .{ .rect = card.data().borderRectScale().r }, .{ .id_extra = idx + 3000 });
        defer ctext.deinit();

        if (ctext.activePoint()) |cp| {
            var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{
                .id_extra = idx + 3000,
                .color_fill = theme.colors.bg_surface,
                .color_border = theme.colors.border_subtle,
            });
            defer fw.deinit();

            if ((dvui.menuItemLabel(@src(), "Copy Title", .{}, .{ .expand = .horizontal, .id_extra = idx + 3100 })) != null) {
                dvui.clipboardTextSet(title);
                state.showToast("Title copied");
                fw.close();
            }
        }
    }
}

// ══════════════════════════════════════════════════════════
// Poster Fetching (async, curl + stb_image)
// ══════════════════════════════════════════════════════════

pub fn fetchPoster(item: *state.AnimeResult) void {
    if (item.poster_url_len == 0 or item.poster_fetching) return;

    // Find the index of this item in the results array.
    const results = state.app.anime.results[0..state.app.anime.result_count];
    var found_idx: ?usize = null;
    for (results, 0..) |*r, i| {
        if (r == item) {
            found_idx = i;
            break;
        }
    }
    const idx = found_idx orelse return;

    const url = item.poster_url[0..item.poster_url_len];
    if (url.len == 0 or url.len > 512) return;

    item.poster_fetching = true;

    // Copy the URL into a fixed array passed BY VALUE through the spawn args —
    // NEVER share module-level statics across poster fetches. The grid triggers
    // ~24 fetches in a single frame; shared statics get overwritten before the
    // worker threads read them, so only the last URL/idx survives and every
    // other card is stuck poster_fetching=true forever (all placeholders).
    var url_copy: [512]u8 = undefined;
    @memcpy(url_copy[0..url.len], url);

    const S = struct {
        fn markDone(idx_: usize, u: []const u8) void {
            if (idx_ < state.app.anime.result_count) {
                const ptr = &state.app.anime.results[idx_];
                if (ptr.poster_url_len == u.len and
                    std.mem.eql(u8, ptr.poster_url[0..ptr.poster_url_len], u))
                {
                    ptr.poster_fetching = false;
                }
            }
        }

        fn worker(url_buf: [512]u8, url_len: usize, result_idx: usize) void {
            const u = url_buf[0..url_len];

            const argv = [_][]const u8{ "curl", "-sL", "--max-time", "10", u };
            const img_buf = @import("../core/alloc.zig").allocator.alloc(u8, 512 * 1024) catch {
                markDone(result_idx, u);
                return;
            };
            defer @import("../core/alloc.zig").allocator.free(img_buf);
            const body = boundedCurl(&argv, img_buf, 12_000) orelse {
                markDone(result_idx, u);
                return;
            };
            if (body.len < 100) {
                markDone(result_idx, u);
                return;
            }

            const decoded = @import("../core/poster.zig").decodeCover(body) orelse {
                markDone(result_idx, u);
                return;
            };
            defer decoded.deinit();
            const p_slice = std.heap.c_allocator.alloc(u8, decoded.rgba_len) catch {
                markDone(result_idx, u);
                return;
            };
            @memcpy(p_slice, decoded.pixels[0..decoded.rgba_len]);

            // Verify the slot still holds the same URL before publishing.
            if (result_idx < state.app.anime.result_count) {
                const ptr = &state.app.anime.results[result_idx];
                if (ptr.poster_url_len == u.len and
                    std.mem.eql(u8, ptr.poster_url[0..ptr.poster_url_len], u))
                {
                    ptr.poster_w = @intCast(decoded.width);
                    ptr.poster_h = @intCast(decoded.height);
                    ptr.poster_pixels = p_slice;
                    ptr.poster_fetching = false;
                    return;
                }
            }
            std.heap.c_allocator.free(p_slice);
        }
    };

    workers.spawn(S.worker, .{ url_copy, url.len, idx }) catch {
        item.poster_fetching = false;
    };
}

// ══════════════════════════════════════════════════════════
// My List / Continue-Watching (db-backed Continue rail)
// ══════════════════════════════════════════════════════════

/// (Re)load the Continue-Watching rail from the DB. Frees any prior textures /
/// pending pixels on the old entries first so we don't leak when reloading.
pub fn loadContinue() void {
    // Free old textures + pending pixels before overwriting the slots.
    for (0..state.app.anime.continue_items.len) |i| {
        var it = &state.app.anime.continue_items[i];
        if (it.poster_tex) |tex| {
            dvui.textureDestroyLater(tex);
            it.poster_tex = null;
        }
        if (it.poster_pixels) |px| {
            std.heap.c_allocator.free(px);
            it.poster_pixels = null;
        }
        it.* = .{}; // reset to default (clears buffers/lens/fetching)
    }
    state.app.anime.continue_count = @import("../core/db.zig").animeGetContinue(state.app.anime.continue_items[0..]);
    state.app.anime.continue_loaded = true;
}

/// Lazy poster download for a ContinueItem — mirrors fetchPoster but keyed by
/// the continue_items[] index (looked up by pointer identity, same as fetchPoster).
pub fn fetchContinuePoster(item: *state.ContinueItem) void {
    if (item.poster_url_len == 0 or item.poster_fetching) return;
    item.poster_fetching = true;

    const S = struct {
        // URL + index are passed BY VALUE through the spawn args — never shared
        // statics (the My List grid spawns many fetches; shared statics race and
        // leave most cards stuck poster_fetching=true / placeholder forever).
        fn worker(url_buf: [512]u8, url_len: usize, cont_idx: usize) void {
            const idx = cont_idx;
            const url = url_buf[0..url_len];

            const argv = [_][]const u8{ "curl", "-sL", "--max-time", "10", url };
            const img_buf = @import("../core/alloc.zig").allocator.alloc(u8, 512 * 1024) catch {
                markDone(idx, url);
                return;
            };
            defer @import("../core/alloc.zig").allocator.free(img_buf);
            const body = boundedCurl(&argv, img_buf, 12_000) orelse {
                markDone(idx, url);
                return;
            };
            if (body.len < 100) {
                markDone(idx, url);
                return;
            }

            const decoded = @import("../core/poster.zig").decodeCover(body) orelse {
                markDone(idx, url);
                return;
            };
            defer decoded.deinit();
            const p_slice = std.heap.c_allocator.alloc(u8, decoded.rgba_len) catch {
                markDone(idx, url);
                return;
            };
            @memcpy(p_slice, decoded.pixels[0..decoded.rgba_len]);

            if (idx < state.app.anime.continue_count) {
                const ptr = &state.app.anime.continue_items[idx];
                if (ptr.poster_url_len == url.len and std.mem.eql(u8, ptr.poster_url[0..ptr.poster_url_len], url)) {
                    ptr.poster_w = @intCast(decoded.width);
                    ptr.poster_h = @intCast(decoded.height);
                    ptr.poster_pixels = p_slice;
                    ptr.poster_fetching = false;
                    return;
                }
            }
            std.heap.c_allocator.free(p_slice);
        }

        fn markDone(idx: usize, url: []const u8) void {
            if (idx < state.app.anime.continue_count) {
                const ptr = &state.app.anime.continue_items[idx];
                if (ptr.poster_url_len == url.len and std.mem.eql(u8, ptr.poster_url[0..ptr.poster_url_len], url)) {
                    ptr.poster_fetching = false;
                }
            }
        }
    };

    // Resolve the index of this item by pointer identity.
    var found_idx: ?usize = null;
    for (state.app.anime.continue_items[0..state.app.anime.continue_count], 0..) |*ci, i| {
        if (ci == item) {
            found_idx = i;
            break;
        }
    }
    const idx = found_idx orelse {
        item.poster_fetching = false;
        return;
    };

    const url = item.poster_url[0..item.poster_url_len];
    if (url.len == 0 or url.len > 512) {
        item.poster_fetching = false;
        return;
    }
    var url_copy: [512]u8 = undefined;
    @memcpy(url_copy[0..url.len], url);

    workers.spawn(S.worker, .{ url_copy, url.len, idx }) catch {
        item.poster_fetching = false;
    };
}

pub fn deinitEpisodeRequests() void {
    episode_request.cancel(&state.app.anime.episodes_loading);
    cancelPlayback();
    playback_tracking = null;
    episode_document_mutex.lock();
    defer episode_document_mutex.unlock();
    for (episode_documents.items) |doc| alloc.free(doc.bytes);
    episode_documents.deinit(alloc);
    episode_documents = .empty;
}

test "Anime playback unknown totals publish long episode lists and reject stale pages" {
    defer deinitEpisodeRequests();
    const a = &state.app.anime;
    const old_selected = a.selected_idx;
    const old_count = a.episode_count;
    defer {
        a.selected_idx = old_selected;
        a.episode_count = old_count;
    }
    a.selected_idx = 0;
    a.episode_count = 0;
    const first = episode_request.begin(&a.episodes_loading);
    var job = EpisodeJob{ .idx = 0, .generation = first, .mal = std.mem.zeroes([16]u8), .mal_len = 1 };
    job.mal[0] = '1';
    const json = "{\"data\":[{\"mal_id\":1200,\"title\":\"Beyond the old limit\",\"aired\":\"2026-09-01\"}]}";
    try episode_documents.append(alloc, .{ .job = job, .bytes = try alloc.dupe(u8, json) });
    applyPendingEpisodes();
    try std.testing.expectEqual(@as(usize, 1200), a.episode_count);
    try std.testing.expectEqualStrings("1200", a.episode_list[1199][0..a.episode_list_lens[1199]]);
    try std.testing.expectEqualStrings("Beyond the old limit", a.episode_titles[1199][0..a.episode_title_lens[1199]]);
    _ = episode_request.begin(&a.episodes_loading);
    a.episode_count = 0;
    try episode_documents.append(alloc, .{ .job = job, .bytes = try alloc.dupe(u8, json) });
    applyPendingEpisodes();
    try std.testing.expectEqual(@as(usize, 0), a.episode_count);
    episode_request.finish(first, &a.episodes_loading);
    try std.testing.expect(a.episodes_loading.load(.acquire));
}

test "Anime playback cancellation drops resolved streams without touching watched state" {
    defer deinitEpisodeRequests();
    const a = &state.app.anime;
    a.episode_watched[0] = false;
    const generation = playback_request.begin(&a.stream_loading);
    const job = PlaybackJob{ .generation = generation, .idx = 0, .row = .{}, .episode = 1, .player_address = 0, .player_serial = 0 };
    cancelPlayback();
    publishPlayback(.{ .job = job });
    try std.testing.expect(playback_ready == null);
    try std.testing.expect(!a.stream_loading.load(.acquire));
    try std.testing.expect(!a.episode_watched[0]);
}

test "Anime playback click acknowledges an episode before any player exists" {
    defer deinitEpisodeRequests();
    const a = &state.app.anime;
    const old_selected = a.selected_idx;
    const old_count = a.episode_count;
    const old_results = a.result_count;
    const old_row = a.results[0];
    defer {
        a.selected_idx = old_selected;
        a.episode_count = old_count;
        a.result_count = old_results;
        a.results[0] = old_row;
    }
    try std.testing.expectEqual(@as(usize, 0), state.app.players.items.len);
    a.selected_idx = 0;
    a.episode_count = 12;
    a.result_count = 1;
    a.results[0] = .{};
    playEpisode("1");
    try std.testing.expect(a.stream_loading.load(.acquire));
    try std.testing.expectEqual(@as(u16, 1), playbackEpisode());
    try std.testing.expect(playback_start != null);
    const generation = playback_request.current();
    playEpisode("1");
    try std.testing.expectEqual(generation, playback_request.current());
    playEpisode("2");
    try std.testing.expectEqual(@as(u16, 2), playbackEpisode());
    failPlayback(generation);
    try std.testing.expect(!playbackFailed());
    try std.testing.expect(a.stream_loading.load(.acquire));
    cancelPlayback();
    try std.testing.expect(!a.stream_loading.load(.acquire));
    try std.testing.expect(playback_start == null);
    try std.testing.expectEqual(@as(u16, 0), playbackEpisode());
    // Cancellation before the owner-loop drain must not initialize a player.
    applyPendingPlayback();
    try std.testing.expectEqual(@as(usize, 0), state.app.players.items.len);
    playEpisode("1");
    failPlayback(playback_request.current());
    try std.testing.expect(playbackFailed());
    try std.testing.expect(!a.stream_loading.load(.acquire));
}

test "Anime provider errors preserve the existing browse catalog" {
    const a = &state.app.anime;
    const saved_count = a.result_count;
    defer a.result_count = saved_count;
    a.result_count = 7;
    const generation = search_request.current();
    try std.testing.expectEqual(@as(usize, 0), parseJikanData("{\"error\":\"upstream unavailable\"}", generation));
    try std.testing.expectEqual(@as(usize, 7), a.result_count);
    try std.testing.expectEqual(@as(usize, 0), parseJikanData("{\"data\":[{", generation));
    try std.testing.expectEqual(@as(usize, 7), a.result_count);
    try std.testing.expectEqual(@as(usize, 0), publishAniListSearch("{\"data\":null,\"errors\":[{\"message\":\"temporarily unavailable\"}]}", generation));
    try std.testing.expectEqual(@as(usize, 7), a.result_count);
}

test "Browse regression anime request URL snapshots survive selector changes" {
    const a = &state.app.anime;
    const saved_sel = a.season_sel;
    const saved_year = a.season_year;
    const saved_sfw = state.app.nsfw_filter_enabled;
    defer {
        a.season_sel = saved_sel;
        a.season_year = saved_year;
        state.app.nsfw_filter_enabled = saved_sfw;
    }
    a.season_sel = .winter;
    a.season_year = 2023;
    state.app.nsfw_filter_enabled = true;
    const job = gridJob(7, .seasonal, 2).?;
    a.season_sel = .spring;
    a.season_year = 2026;
    state.app.nsfw_filter_enabled = false;
    try std.testing.expectEqualStrings("https://api.jikan.moe/v4/seasons/2023/winter?limit=25&page=2&sfw=true", job.url[0..job.url_len]);
    try std.testing.expectEqual(@as(u32, 7), job.generation);
    try std.testing.expect(job.sfw);
}

test "Browse regression anime relation parser publishes owned records only" {
    const saved_count = state.app.anime.relation_count;
    defer state.app.anime.relation_count = saved_count;
    state.app.anime.relation_count = 7;
    var rows: [16]state.AnimeRelation = @splat(.{});
    const count = parseRelations("{\"data\":[{\"relation\":\"Sequel\",\"entry\":[{\"mal_id\":2,\"type\":\"anime\",\"name\":\"Next work\"}]}]}", &rows);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("2", rows[0].mal_id[0..rows[0].mal_id_len]);
    try std.testing.expectEqualStrings("Next work", rows[0].name[0..rows[0].name_len]);
    try std.testing.expectEqual(@as(usize, 7), state.app.anime.relation_count);
}

test "Browse regression anime superseding request is admitted while busy" {
    const saved_loading = state.app.anime.is_loading.load(.acquire);
    defer state.app.anime.is_loading.store(saved_loading, .release);
    const first = beginCatalogRequest();
    try std.testing.expect(state.app.anime.is_loading.load(.acquire));
    const next = beginCatalogRequest();
    try std.testing.expect(next != first);
    search_request.finish(first, &state.app.anime.is_loading);
    try std.testing.expect(state.app.anime.is_loading.load(.acquire));
    search_request.finish(next, &state.app.anime.is_loading);
    try std.testing.expect(!state.app.anime.is_loading.load(.acquire));
}
