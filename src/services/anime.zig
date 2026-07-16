const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const anime_pure = @import("anime_pure.zig");
const theme = @import("../ui/theme.zig");
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

const alloc = @import("../core/alloc.zig").allocator;

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
// Anime Tab — allanime.day API integration (built-in, no ani-cli)
// Trending -> Search → Select → Pick Episode → Stream to MPV
// ══════════════════════════════════════════════════════════

const allanime_api = "https://api.allanime.day";

const allanime_refr = "https://allmanga.to";
const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/121.0";

// NOTE: state.app.anime.is_loading.load(.acquire) / stream_loading / episodes_loading are plain
// bools in the global state struct, shared between UI and bg threads without
// atomics. Acceptable — worst case is one stale UI frame before the flag is seen.
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
// single monotonic generation (`search_gen`, already declared below) guards all
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
    state.app.anime.episode_count = 0;
    state.app.anime.last_fetch_s = 0; // bypass SWR on explicit switch
    fetched_mode = null; // force renderContent to re-dispatch
    grid_page = 1; // restart infinite-scroll pagination for the new mode
    more_available = false;
    _ = search_gen.fetchAdd(1, .acq_rel); // drop stale in-flight workers
}

// ── Infinite-scroll pagination (mirrors comics.zig loadMoreResults). ──
// Jikan paginates: the four grid fetchers request page 1, and loadMoreGrid()
// fetches page grid_page+1 and APPENDS into results[] at the current end.
// `more_available` is the parsed `has_next_page` flag from the last fetch;
// `grid_page` is the highest page currently merged into results[].
var more_available: bool = false;
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
    if (!more_available or grid_loading_more.load(.acquire) or state.app.anime.is_loading.load(.acquire)) return;
    if (state.app.anime.result_count == 0 or state.app.anime.result_count >= state.app.anime.results.len) return;
    if (grid_loading_more.swap(true, .acq_rel)) return;
    if (std.Thread.spawn(.{}, loadMoreGridWorker, .{ search_gen.load(.acquire), state.app.anime.mode })) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        grid_loading_more.store(false, .release);
    }
}

fn loadMoreGridWorker(my_gen: u32, mode: state.AnimeMode) void {
    defer grid_loading_more.store(false, .release);

    const next_page = grid_page + 1;
    var url_buf: [512]u8 = undefined;
    const url = buildGridUrl(&url_buf, mode, next_page) orelse return;

    const argv = [_][]const u8{ "curl", "-s", "-A", agent, "--max-time", "12", url };

    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const bytes = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, buf) catch 0 else 0;
    _ = child.wait() catch {};

    if (bytes == 0) return;
    // Bail if a newer fetch (mode switch / fresh search) superseded us mid-curl.
    if (search_gen.load(.acquire) != my_gen) return;

    const json = buf[0..bytes];
    const added = parseJikanDataEx(json, my_gen, mode == .calendar, state.app.anime.result_count);
    if (added == 0) {
        more_available = false;
    } else {
        grid_page = next_page;
        more_available = parsePagination(json);
    }
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
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

pub fn loadTrendingAnime() void {
    if (state.app.anime.is_loading.load(.acquire)) return;

    state.app.anime.is_loading.store(true, .release);
    // Don't clear result_count here — parseJikanData repopulates and sets the
    // count after the fetch, so a stale-refresh keeps old cards on screen.
    state.app.anime.selected_idx = null;
    state.app.anime.episode_count = 0;
    state.app.anime.last_fetch_s = @import("browse_cache.zig").now(); // SWR stamp
    grid_page = 1; // restart infinite-scroll pagination
    more_available = false;
    has_loaded_trending = true;
    // Trending owns the global generation too, so a stale in-flight search
    // worker won't overwrite freshly-loaded trending cards.
    _ = search_gen.fetchAdd(1, .acq_rel);

    // The Lists chip swaps the source: same grid, same results[], different fetch.
    if (usesLists()) {
        state.app.anime.thread = std.Thread.spawn(.{}, listsThread, .{}) catch {
            state.app.anime.is_loading.store(false, .release);
            return;
        };
        if (state.app.anime.thread) |t| t.detach();
        return;
    }

    state.app.anime.thread = std.Thread.spawn(.{}, trendingThread, .{}) catch {
        state.app.anime.is_loading.store(false, .release);
        return;
    };
    if (state.app.anime.thread) |t| t.detach(); // never joined — detach to avoid leaking the handle
}

// ══════════════════════════════════════════════════════════
// `lists` source plugin — anime index from debpalash/lists
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
const LISTS_DEFAULT_BASE = "https://raw.githubusercontent.com/debpalash/lists/main";

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
fn listsThread() void {
    defer state.app.anime.is_loading.store(false, .release);
    // Generation this load was spawned under — see searchThread/parseJikanDataEx.
    const my_gen = search_gen.load(.acquire);

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
    const argv = [_][]const u8{ "curl", "-sL", "-A", agent, "--max-time", "20", url };
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch {
        if (!have_cached) logs.pushLog("error", "anime", "Lists: curl failed", true);
        return;
    };

    const buf = alloc.alloc(u8, LISTS_MAX_BYTES) catch {
        _ = child.wait() catch {};
        return;
    };
    defer alloc.free(buf);
    const bytes = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, buf) catch 0 else 0;
    _ = child.wait() catch {};

    // Empty / error page → keep whatever the cache already put on screen.
    if (bytes < 32) {
        if (!have_cached) logs.pushLog("error", "anime", "Lists: empty response", true);
        return;
    }
    // Superseded by a newer fetch (mode switch, chip change) while we were in curl.
    if (search_gen.load(.acquire) != my_gen) return;

    const json = buf[0..bytes];
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
    if (search_gen.load(.acquire) != my_gen) return 0; // cheap pre-check, before the alloc

    // 100 Items ≈ 34 KB — heap, not the worker's stack.
    const items = alloc.alloc(lists_pure.Item, state.app.anime.results.len) catch return 0;
    defer alloc.free(items);

    const n = lists_pure.parseAiring(alloc, json, state.app.nsfw_filter_enabled, items);
    if (n == 0) return 0;

    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return 0; // re-check under the lock

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
    more_available = false; // single payload — nothing to page
    spawnAniListEnrich(my_gen); // fills score + synopsis (additive; never overwrites)
    return n;
}

fn trendingThread() void {
    defer state.app.anime.is_loading.store(false, .release);
    // Capture the generation this load was spawned under (see searchThread).
    const my_gen = search_gen.load(.acquire);

    const jikan_api = "https://api.jikan.moe/v4/top/anime";
    var arg1_buf: [256]u8 = undefined;
    const fv = trend_filter.jikan();
    const arg1 = (if (fv.len == 0)
        std.fmt.bufPrint(&arg1_buf, "{s}?limit=25&page={d}{s}", .{ jikan_api, grid_page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) })
    else
        std.fmt.bufPrint(&arg1_buf, "{s}?filter={s}&limit=25&page={d}{s}", .{ jikan_api, fv, grid_page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) })) catch return;

    const argv = [_][]const u8{
        "curl", "-s", "-A", agent, arg1,
    };

    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const bytes = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, buf) catch 0 else 0;
    _ = child.wait() catch {};

    if (bytes == 0) return;

    _ = parseJikanData(buf[0..bytes], my_gen);
    if (search_gen.load(.acquire) == my_gen) more_available = parsePagination(buf[0..bytes]);
    logs.pushLog("info", "anime", "Trending loaded (Jikan API)", false);
}

pub fn searchAnime(query: []const u8) void {
    if (query.len == 0) return;
    // NOTE: do NOT early-return on is_loading. Live-search supersedes an
    // in-flight fetch: we bump the generation so the older worker's results
    // are dropped, and the search_query_buf is overwritten for the new fetch.
    // (Worst case two curl workers run briefly; the stale one self-discards.)

    state.app.anime.is_loading.store(true, .release);
    // Don't clear result_count — keep prior cards visible until new results
    // arrive (no flicker). The new generation guards against stale publishes.
    state.app.anime.selected_idx = null;
    state.app.anime.episode_count = 0;

    // New generation for this search; the worker captures and re-checks it.
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;
    grid_page = 1; // restart infinite-scroll pagination
    more_available = false;

    // Copy query into a static buffer so the spawned thread doesn't read
    // from the potentially-mutated UI search_buf.
    const safe_len = @min(query.len, search_query_buf.len);
    @memcpy(search_query_buf[0..safe_len], query[0..safe_len]);
    search_query_len = safe_len;

    // Site-framework source installed → search the site's own catalog instead of
    // Jikan (source_config-gated; INERT by default). See the DooPlay/AnimeStream
    // section below.
    if (activeScraper() != .none) {
        if (std.Thread.spawn(.{}, scraperSearchThread, .{my_gen})) |t| {
            t.detach();
        } else |_| state.app.anime.is_loading.store(false, .release);
        return;
    }

    if (std.Thread.spawn(.{}, searchThread, .{my_gen})) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.anime.is_loading.store(false, .release);
    }
}

var search_query_buf: [256]u8 = undefined;
var search_query_len: usize = 0;

fn searchThread(my_gen: u32) void {
    defer state.app.anime.is_loading.store(false, .release);
    // Snapshot the query immediately — a newer search may overwrite the static
    // buffer mid-flight. We only re-check the generation right before publish.
    var local_query_buf: [256]u8 = undefined;
    const qlen = @min(search_query_len, local_query_buf.len);
    @memcpy(local_query_buf[0..qlen], search_query_buf[0..qlen]);
    const query = local_query_buf[0..qlen];

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
    const url = std.fmt.bufPrint(&url_buf, "{s}?q={s}&limit=25&page={d}{s}", .{ jikan_api, enc_buf[0..enc_len], grid_page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) }) catch return;

    const argv = [_][]const u8{
        "curl", "-s", "-A", agent, url,
    };

    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const bytes = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, buf) catch 0 else 0;
    _ = child.wait() catch {};

    if (bytes == 0) return;

    _ = parseJikanData(buf[0..bytes], my_gen);
    if (search_gen.load(.acquire) == my_gen) more_available = parsePagination(buf[0..bytes]);
    logs.pushLog("info", "anime", "Search done (Jikan API)", false);
}

// ══════════════════════════════════════════════════════════
// Seasonal mode (/seasons/now, /seasons/{year}/{season}, /seasons/upcoming)
// ══════════════════════════════════════════════════════════

/// Kick a seasonal fetch for the current season_sel / season_year. Reuses the
/// shared results[]/generation machinery (parseJikanData publishes the cards).
pub fn loadSeasonal() void {
    if (state.app.anime.is_loading.load(.acquire)) return;
    state.app.anime.is_loading.store(true, .release);
    state.app.anime.selected_idx = null;
    state.app.anime.episode_count = 0;
    state.app.anime.last_fetch_s = @import("browse_cache.zig").now();
    grid_page = 1; // restart infinite-scroll pagination
    more_available = false;
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    state.app.anime.thread = std.Thread.spawn(.{}, seasonalThread, .{my_gen}) catch {
        state.app.anime.is_loading.store(false, .release);
        return;
    };
    if (state.app.anime.thread) |t| t.detach();
}

fn seasonalThread(my_gen: u32) void {
    defer state.app.anime.is_loading.store(false, .release);

    const sel = state.app.anime.season_sel;
    const year = state.app.anime.season_year;

    var url_buf: [256]u8 = undefined;
    const url = switch (sel) {
        .now => std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/seasons/now?limit=25&page={d}{s}", .{ grid_page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) }),
        .upcoming => std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/seasons/upcoming?limit=25&page={d}{s}", .{ grid_page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) }),
        else => std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/seasons/{d}/{s}?limit=25&page={d}{s}", .{ year, seasonStr(sel), grid_page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) }),
    } catch return;

    const argv = [_][]const u8{ "curl", "-s", "-A", agent, "--max-time", "12", url };

    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const bytes = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, buf) catch 0 else 0;
    _ = child.wait() catch {};

    if (bytes == 0) return;
    _ = parseJikanData(buf[0..bytes], my_gen);
    if (search_gen.load(.acquire) == my_gen) more_available = parsePagination(buf[0..bytes]);
    logs.pushLog("info", "anime", "Seasonal loaded (Jikan API)", false);
}

// ══════════════════════════════════════════════════════════
// Calendar mode (/schedules?filter={day}) — same anime shape + broadcast.string
// ══════════════════════════════════════════════════════════

pub fn loadCalendar() void {
    if (state.app.anime.is_loading.load(.acquire)) return;
    state.app.anime.is_loading.store(true, .release);
    state.app.anime.selected_idx = null;
    state.app.anime.episode_count = 0;
    state.app.anime.last_fetch_s = @import("browse_cache.zig").now();
    grid_page = 1; // restart infinite-scroll pagination
    more_available = false;
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    state.app.anime.thread = std.Thread.spawn(.{}, calendarThread, .{my_gen}) catch {
        state.app.anime.is_loading.store(false, .release);
        return;
    };
    if (state.app.anime.thread) |t| t.detach();
}

fn calendarThread(my_gen: u32) void {
    defer state.app.anime.is_loading.store(false, .release);

    const day = calDayStr(state.app.anime.cal_day);
    var url_buf: [256]u8 = undefined;
    const url = (if (day.len == 0)
        std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/schedules?limit=25&page={d}{s}", .{ grid_page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) })
    else
        std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/schedules?filter={s}&limit=25&page={d}{s}", .{ day, grid_page, anime_pure.sfwSuffix(state.app.nsfw_filter_enabled) })) catch return;

    const argv = [_][]const u8{ "curl", "-s", "-A", agent, "--max-time", "12", url };

    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const bytes = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, buf) catch 0 else 0;
    _ = child.wait() catch {};

    if (bytes == 0) return;
    // parseJikanData handles the cards; pass with_broadcast so it also extracts
    // each item's broadcast.string into anime.broadcast[] (aligned to index).
    _ = parseJikanDataEx(buf[0..bytes], my_gen, true, 0);
    if (search_gen.load(.acquire) == my_gen) more_available = parsePagination(buf[0..bytes]);
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

fn parseJikanDataEx(json: []const u8, my_gen: u32, with_broadcast: bool, start_offset: usize) usize {
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();

    // Drop stale results: if a newer search/trending load fired while we were
    // in-flight, this generation is no longer the latest — discard silently so
    // fast typing never shows out-of-order results, and we don't clobber the
    // newer fetch's cards/textures. (Re-checked here under the lock so a worker
    // that waited on the mutex sees the latest generation.)
    if (search_gen.load(.acquire) != my_gen) return 0;

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

    while (pos < json.len and count < state.app.anime.results.len) {
        // Find next mal_id object securely to avoid nested array overlap
        const id_idx = std.mem.indexOf(u8, json[pos..], "\"mal_id\":") orelse break;
        pos += id_idx + 9;

        var next_obj_pos = json.len;
        if (std.mem.indexOf(u8, json[pos..], "\"mal_id\":")) |nidx| {
            next_obj_pos = pos + nidx;
        }

        const obj_slice = json[pos..next_obj_pos];

        // NSFW filter (Settings › Behavior): drop Rx/R+ rated entries. The
        // request already asks Jikan for sfw=true; this rating check also
        // catches R+ (ecchi covers) and anything from cached pages.
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
        var ep_count: u16 = 100;
        if (std.mem.indexOf(u8, obj_slice, "\"episodes\":")) |ep_idx| {
            const num_st = ep_idx + 11;
            if (num_st < obj_slice.len and obj_slice[num_st] >= '0' and obj_slice[num_st] <= '9') {
                var ne = num_st;
                while (ne < obj_slice.len and obj_slice[ne] >= '0' and obj_slice[ne] <= '9') : (ne += 1) {}
                if (ne > num_st) ep_count = std.fmt.parseInt(u16, obj_slice[num_st..ne], 10) catch 100;
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
            item.score = score;

            // Decode JSON escapes (Jikan escapes the URL slashes as "\/", which
            // makes std.Uri.parse reject it → posters never fetched). Must run
            // through decodeJsonEscapes just like the name/synopsis.
            item.poster_url_len = decodeJsonEscapes(poster_url, &item.poster_url);

            // Decode JSON escapes in synopsis (\" \\ \/ \n \t \uXXXX, etc.)
            item.overview_len = decodeJsonEscapes(synopsis, &item.overview);

            item.poster_fetching = false;
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

        pos = next_obj_pos;
    }

    // Final generation re-check before publishing the count: a newer fetch may
    // have superseded us during parsing. If so, drop our results.
    if (search_gen.load(.acquire) != my_gen) return 0;
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
// parse, so it takes the same anime_parse_mutex and re-checks search_gen before
// touching anything. Stale generations (superseded by a newer search) exit at
// the snapshot gen-check before any network work, so at most one enrich worker
// per settled query ever reaches curl — no busy flag needed.

fn spawnAniListEnrich(my_gen: u32) void {
    if (std.Thread.spawn(.{}, anilistEnrichThread, .{my_gen})) |t| t.detach() else |_| {}
}

fn anilistEnrichThread(my_gen: u32) void {
    // 1) Snapshot the visible MAL ids as a CSV under the parse mutex.
    var csv_buf: [512]u8 = undefined;
    var csv_len: usize = 0;
    var sfw = false;
    {
        anime_parse_mutex.lock();
        defer anime_parse_mutex.unlock();
        if (search_gen.load(.acquire) != my_gen) return; // superseded — bail cheaply
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
    const bytes = anilist.fetchMetaByMalIds(csv_buf[0..csv_len], sfw, buf);
    if (bytes == 0) return;

    // 3) Merge under the lock, re-checking the generation.
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return;

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

pub fn loadEpisodes(idx: usize) void {
    if (idx >= state.app.anime.result_count) return;
    // Scraper cards resolve episodes from the site's detail page, not Jikan.
    if (results_are_scraper) {
        loadEpisodesScraper(idx);
        return;
    }
    state.app.anime.selected_idx = idx;

    // Instantly populate numbered episode slots so UI is responsive
    const max_eps = state.app.anime.results[idx].episodes;
    var ep_count: usize = 0;

    while (ep_count < max_eps and ep_count < 200) : (ep_count += 1) {
        var str_buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&str_buf, "{d}", .{ep_count + 1}) catch "1";
        @memcpy(state.app.anime.episode_list[ep_count][0..s.len], s);
        state.app.anime.episode_list_lens[ep_count] = s.len;
        state.app.anime.episode_title_lens[ep_count] = 0;
        state.app.anime.episode_aired_lens[ep_count] = 0;
        state.app.anime.episode_scores[ep_count] = 0;
        state.app.anime.episode_filler[ep_count] = false;
    }
    state.app.anime.episode_count = ep_count;
    state.app.anime.is_loading.store(false, .release);

    // ── Tracking: zero the watched flags for the visible range, then hydrate
    //    from the DB (animeLoadWatched only sets trues; we must clear first). ──
    for (0..@min(ep_count, state.app.anime.episode_watched.len)) |i| state.app.anime.episode_watched[i] = false;
    const mal_id = state.app.anime.results[idx].id[0..state.app.anime.results[idx].id_len];
    if (mal_id.len > 0 and ep_count > 0) {
        @import("../core/db.zig").animeLoadWatched(mal_id, state.app.anime.episode_watched[0..ep_count]);
    }

    // Detail view also shows a "Seasons & Related" rail — load relations.
    loadRelations(idx);

    // Now kick off Jikan episodes enrichment in background
    if (!state.app.anime.episodes_loading) {
        state.app.anime.episodes_loading = true;
        if (std.Thread.spawn(.{}, fetchEpisodeDataThread, .{idx})) |t| {
            t.detach(); // never joined — detach so the handle isn't leaked
        } else |_| {
            state.app.anime.episodes_loading = false;
        }
    }
}

fn fetchEpisodeDataThread(idx: usize) void {
    defer state.app.anime.episodes_loading = false;

    const mal_id = state.app.anime.results[idx].id[0..state.app.anime.results[idx].id_len];

    // Fetch up to 4 pages of episodes (100 eps per page from Jikan)
    var page: u32 = 1;
    var total_parsed: usize = 0;

    while (page <= 4 and total_parsed < state.app.anime.episode_count) : (page += 1) {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/anime/{s}/episodes?page={d}", .{ mal_id, page }) catch break;

        const argv = [_][]const u8{
            "curl", "-s", "-A", agent, "--max-time", "10", url,
        };
        var child = @import("../core/io_global.zig").Child.init(&argv, std.heap.c_allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        _ = child.spawn() catch break;

        var buf: [64 * 1024]u8 = undefined;
        const len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &buf) catch 0 else 0;
        _ = child.wait() catch {};

        if (len < 10) break;
        const json = buf[0..len];

        // Parse each episode in the data array
        var pos: usize = 0;
        var found_any = false;

        while (pos < json.len and total_parsed < 200) {
            // Find next "mal_id": in episodes array
            const id_idx = std.mem.indexOf(u8, json[pos..], "\"mal_id\":") orelse break;
            pos += id_idx + 9;

            // Extract episode number
            var num_end: usize = 0;
            while (num_end < json.len - pos and json[pos + num_end] >= '0' and json[pos + num_end] <= '9') : (num_end += 1) {}
            if (num_end == 0) continue;
            const ep_num = std.fmt.parseInt(usize, json[pos .. pos + num_end], 10) catch continue;
            if (ep_num == 0 or ep_num > 200) {
                pos += num_end;
                continue;
            }
            const ep_idx = ep_num - 1;

            // Find scope of this episode object
            var next_ep = json.len;
            if (std.mem.indexOf(u8, json[pos..], "\"mal_id\":")) |nidx| {
                next_ep = pos + nidx;
            }
            const obj = json[pos..next_ep];

            // Extract title
            if (std.mem.indexOf(u8, obj, "\"title\":\"")) |ti| {
                const start = ti + 9;
                var end = start;
                var esc = false;
                while (end < obj.len) : (end += 1) {
                    if (esc) {
                        esc = false;
                    } else if (obj[end] == '\\') {
                        esc = true;
                    } else if (obj[end] == '"') break;
                }
                if (end < obj.len) {
                    const tlen = @min(end - start, 80);
                    @memcpy(state.app.anime.episode_titles[ep_idx][0..tlen], obj[start .. start + tlen]);
                    state.app.anime.episode_title_lens[ep_idx] = tlen;
                }
            }

            // Extract aired date (just YYYY-MM-DD)
            if (std.mem.indexOf(u8, obj, "\"aired\":\"")) |ai| {
                const start = ai + 9;
                const dlen = @min(10, obj.len - start);
                @memcpy(state.app.anime.episode_aired[ep_idx][0..dlen], obj[start .. start + dlen]);
                state.app.anime.episode_aired_lens[ep_idx] = dlen;
            }

            // Extract score
            if (std.mem.indexOf(u8, obj, "\"score\":")) |si| {
                const start = si + 8;
                if (start < obj.len and ((obj[start] >= '0' and obj[start] <= '9') or obj[start] == '.')) {
                    var end = start;
                    while (end < obj.len and ((obj[end] >= '0' and obj[end] <= '9') or obj[end] == '.')) : (end += 1) {}
                    state.app.anime.episode_scores[ep_idx] = std.fmt.parseFloat(f32, obj[start..end]) catch 0;
                }
            }

            // Extract filler flag
            if (std.mem.indexOf(u8, obj, "\"filler\":true")) |_| {
                state.app.anime.episode_filler[ep_idx] = true;
            }

            total_parsed += 1;
            found_any = true;
            pos = next_ep;
        }

        if (!found_any) break;

        // Jikan rate limit: ~3 req/sec
        @import("../core/io_global.zig").sleep(400 * std.time.ns_per_ms);
    }
}

// ══════════════════════════════════════════════════════════
// Relations rail (/anime/{mal_id}/relations) — Sequel/Prequel/Side Story/…
// ══════════════════════════════════════════════════════════

var relations_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn loadRelations(idx: usize) void {
    if (idx >= state.app.anime.result_count) return;
    if (relations_busy.swap(true, .acq_rel)) return; // already in flight
    state.app.anime.relations_loading = true;
    state.app.anime.relation_count = 0;

    const S = struct {
        var mal_id_buf: [16]u8 = undefined;
        var mal_id_len: usize = 0;

        fn worker() void {
            defer {
                state.app.anime.relations_loading = false;
                relations_busy.store(false, .release);
            }
            const mal_id = @This().mal_id_buf[0..@This().mal_id_len];
            if (mal_id.len == 0) return;

            var url_buf: [128]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/anime/{s}/relations", .{mal_id}) catch return;

            const argv = [_][]const u8{ "curl", "-s", "-A", agent, "--max-time", "10", url };
            var child = @import("../core/io_global.zig").Child.init(&argv, std.heap.c_allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            _ = child.spawn() catch return;

            const buf = @import("../core/alloc.zig").allocator.alloc(u8, 128 * 1024) catch {
                _ = child.wait() catch {};
                return;
            };
            defer @import("../core/alloc.zig").allocator.free(buf);
            const len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, buf) catch 0 else 0;
            _ = child.wait() catch {};
            if (len < 10) return;
            parseRelations(buf[0..len]);
        }
    };

    const mal = state.app.anime.results[idx].id[0..state.app.anime.results[idx].id_len];
    const n = @min(mal.len, S.mal_id_buf.len);
    @memcpy(S.mal_id_buf[0..n], mal[0..n]);
    S.mal_id_len = n;

    if (std.Thread.spawn(.{}, S.worker, .{})) |t| {
        t.detach();
    } else |_| {
        state.app.anime.relations_loading = false;
        relations_busy.store(false, .release);
    }
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
fn parseRelations(json: []const u8) void {
    var count: usize = 0;
    var pos: usize = 0;

    while (pos < json.len and count < state.app.anime.relations.len) {
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
        while (epos < scope.len and count < state.app.anime.relations.len) {
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

            var r = &state.app.anime.relations[count];
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

    state.app.anime.relation_count = count;
}

// ══════════════════════════════════════════════════════════
// Jump to a single anime by mal_id (/anime/{id}) — related & continue rails.
// Parses one anime object into results[0], selects it, loads episodes.
// ══════════════════════════════════════════════════════════

var jump_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn jumpToAnime(mal_id: []const u8) void {
    if (mal_id.len == 0 or mal_id.len > 15) return;
    if (jump_busy.swap(true, .acq_rel)) return;
    state.app.anime.is_loading.store(true, .release);
    state.app.anime.selected_idx = null;
    state.app.anime.episode_count = 0;
    // New generation so any in-flight grid fetch can't clobber results[0].
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;
    grid_page = 1; // single-anime view has no further pages
    more_available = false;

    const S = struct {
        var id_buf: [16]u8 = undefined;
        var id_len: usize = 0;
        var gen: u32 = 0;

        fn worker() void {
            defer {
                state.app.anime.is_loading.store(false, .release);
                jump_busy.store(false, .release);
            }
            const id = @This().id_buf[0..@This().id_len];
            var url_buf: [96]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/anime/{s}", .{id}) catch return;

            const argv = [_][]const u8{ "curl", "-s", "-A", agent, "--max-time", "12", url };
            var child = @import("../core/io_global.zig").Child.init(&argv, std.heap.c_allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            _ = child.spawn() catch return;

            const buf = @import("../core/alloc.zig").allocator.alloc(u8, 128 * 1024) catch {
                _ = child.wait() catch {};
                return;
            };
            defer @import("../core/alloc.zig").allocator.free(buf);
            const len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, buf) catch 0 else 0;
            _ = child.wait() catch {};
            if (len < 10) return;

            // The single-anime endpoint wraps one object in {"data":{...}} — the
            // same field shape parseJikanData walks, so reuse it (it caps at the
            // first mal_id object → exactly one card in results[0]).
            _ = parseJikanData(buf[0..len], @This().gen);

            // If still current, select it and load its episodes on this thread.
            if (search_gen.load(.acquire) == @This().gen and state.app.anime.result_count > 0) {
                state.app.anime.selected_idx = 0;
                loadEpisodes(0);
            }
        }
    };

    const n = @min(mal_id.len, S.id_buf.len);
    @memcpy(S.id_buf[0..n], mal_id[0..n]);
    S.id_len = n;
    S.gen = my_gen;

    if (std.Thread.spawn(.{}, S.worker, .{})) |t| {
        t.detach();
    } else |_| {
        state.app.anime.is_loading.store(false, .release);
        jump_busy.store(false, .release);
    }
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

pub fn playEpisode(ep_no: []const u8) void {
    if (state.app.anime.selected_idx == null) return;
    const idx = state.app.anime.selected_idx.?;
    if (idx >= state.app.anime.result_count) return;

    // ── Tracking: mark this episode watched + upsert the Continue entry so it
    //    surfaces in My List with the next episode to resume. ──
    {
        const ep_num = std.fmt.parseInt(u16, ep_no, 10) catch 0;
        const r = &state.app.anime.results[idx];
        const mal_id = r.id[0..r.id_len];
        if (ep_num >= 1 and ep_num <= state.app.anime.episode_watched.len and mal_id.len > 0) {
            state.app.anime.episode_watched[ep_num - 1] = true;
            const db = @import("../core/db.zig");
            db.animeMarkWatched(mal_id, ep_num, true);
            db.animeUpsertContinue(mal_id, r.name[0..r.name_len], r.poster_url[0..r.poster_url_len], ep_num, r.episodes);
            // Refresh the cached Continue rail so My List reflects this play.
            state.app.anime.continue_loaded = false;
        }
    }

    state.app.anime.stream_loading = true;

    // ── Anime-Skip: arm crowdsourced intro/recap/credits auto-skip for the
    //    episode we're about to load. anime-skip matches on episode NAME, so
    //    prefer the Jikan-enriched episode title when we have one; otherwise
    //    fall back to "<show> Episode N". Best-effort — title spelling can
    //    differ from anime-skip's DB, in which case no markers come back.
    {
        const ep_num = std.fmt.parseInt(u16, ep_no, 10) catch 0;
        var name_buf: [160]u8 = undefined;
        var name_slice: []const u8 = "";
        if (ep_num >= 1 and ep_num <= state.app.anime.episode_title_lens.len and
            state.app.anime.episode_title_lens[ep_num - 1] > 0)
        {
            const tl = state.app.anime.episode_title_lens[ep_num - 1];
            name_slice = state.app.anime.episode_titles[ep_num - 1][0..tl];
        } else {
            const r = &state.app.anime.results[idx];
            name_slice = std.fmt.bufPrint(&name_buf, "{s} Episode {s}", .{ r.name[0..r.name_len], ep_no }) catch "";
        }
        @import("anime_skip.zig").onEpisodeLoad(name_slice);
    }

    var ep_copy: [8]u8 = std.mem.zeroes([8]u8);
    const ep_len = @min(ep_no.len, 7);
    @memcpy(ep_copy[0..ep_len], ep_no[0..ep_len]);

    // Scraper cards resolve the episode's EMBED URL from the site and hand it to
    // playEmbed (→ the shared extractor stack), instead of the torrent/AnimePahe path.
    if (results_are_scraper) {
        if (std.Thread.spawn(.{}, scraperPlayThread, .{ ep_copy, ep_len })) |t| {
            t.detach();
        } else |_| state.app.anime.stream_loading = false;
        return;
    }

    if (std.Thread.spawn(.{}, fetchStreamThread, .{ ep_copy, ep_len })) |t| {
        t.detach(); // never joined — detach so the handle isn't leaked
    } else |_| {
        state.app.anime.stream_loading = false;
    }
}

fn fetchStreamThread(ep_buf: [8]u8, ep_len: usize) void {
    defer state.app.anime.stream_loading = false;

    const ep_no = ep_buf[0..ep_len];
    const sel_idx = state.app.anime.selected_idx orelse return;

    var name_buf: [129]u8 = undefined;
    const name_len = state.app.anime.results[sel_idx].name_len;
    @memcpy(name_buf[0..name_len], state.app.anime.results[sel_idx].name[0..name_len]);
    const name_str = name_buf[0..name_len];

    var query_buf: [256]u8 = undefined;
    const query = std.fmt.bufPrintZ(&query_buf, "{s} {s}", .{ name_str, ep_no }) catch return;

    // ── Phase 1: Try torrent resolution ──
    logs.pushLog("info", "anime", "Resolving stream via Torrents...", false);

    const resolver = @import("resolver.zig");
    resolver.resolve(query, "anime");

    var waited: usize = 0;
    while (resolver.isResolving() and waited < 100) : (waited += 1) {
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
    }

    {
        resolver.results_mutex.lock();
        defer resolver.results_mutex.unlock();

        for (0..resolver.result_count) |i| {
            const item = resolver.results[i];
            if (item.source == .torrent or item.source == .stremio) {
                const srch = @import("search.zig");
                srch.loadTorrentToPlayer(item.url[0..item.url_len]);

                var log_buf2: [128]u8 = undefined;
                const log_msg2 = std.fmt.bufPrintZ(&log_buf2, "Playing: {s}", .{item.name[0..@min(item.name_len, 40)]}) catch "Playing";
                logs.pushLog("info", "anime", log_msg2, false);
                return;
            }
        }
    }

    // ── Phase 2: DDL fallback via AnimePahe ──
    logs.pushLog("info", "anime", "No torrent peers. Trying DDL fallback...", false);

    if (tryAnimePaheDDL(name_str, ep_no)) return;

    logs.pushLog("error", "anime", "No streams found. Try universal search.", true);
}

fn tryAnimePaheDDL(name: []const u8, ep_no: []const u8) bool {
    const c_alloc = std.heap.c_allocator;

    // URL-encode the anime name for search
    var enc_buf: [256]u8 = undefined;
    var enc_len: usize = 0;
    for (name) |ch| {
        if (enc_len + 3 >= enc_buf.len) break;
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_') {
            enc_buf[enc_len] = ch;
            enc_len += 1;
        } else if (ch == ' ') {
            enc_buf[enc_len] = '+';
            enc_len += 1;
        } else {
            enc_buf[enc_len] = '%';
            enc_buf[enc_len + 1] = "0123456789ABCDEF"[ch >> 4];
            enc_buf[enc_len + 2] = "0123456789ABCDEF"[ch & 0xF];
            enc_len += 3;
        }
    }

    // Endpoint migrated to opal-plugins — inert until the user installs "animepahe".
    const base = @import("../core/source_config.zig").get("animepahe", "base") orelse return false;
    // Search AnimePahe for the anime
    var url_buf: [512]u8 = undefined;
    const search_url = std.fmt.bufPrint(&url_buf, "{s}/api?m=search&q={s}", .{ base, enc_buf[0..enc_len] }) catch return false;
    var refr_buf: [600]u8 = undefined;
    const referer = std.fmt.bufPrint(&refr_buf, "Referer: {s}", .{base}) catch return false;

    const argv_search = [_][]const u8{
        "curl",     "-sL",                                                                                          "--max-time", "10",
        "-H",       "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0", "-H",         referer,
        search_url,
    };
    var child = @import("../core/io_global.zig").Child.init(&argv_search, c_alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return false;

    var buf: [32 * 1024]u8 = undefined;
    const len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &buf) catch 0 else 0;
    _ = child.wait() catch {};

    if (len < 10) return false;
    const json = buf[0..len];

    // Extract first matching session from search results
    // Format: {"data":[{"session":"xxxx-xxxx","title":"...","episodes":N},...]}
    var session: []const u8 = "";
    if (std.mem.indexOf(u8, json, "\"session\":\"")) |si| {
        const start = si + 11;
        var end = start;
        while (end < json.len and json[end] != '"') : (end += 1) {}
        if (end < json.len) session = json[start..end];
    }

    if (session.len == 0) {
        logs.pushLog("warn", "anime", "AnimePahe: anime not found", false);
        return false;
    }

    // Construct the watch URL for mpv + ytdl-hook (format: {base}/play/{session}/{ep})
    // mpv will use yt-dlp/ytdl to extract the stream. `base` (animepahe) is the
    // opal-plugins endpoint resolved at the top of this function.
    var watch_url_buf: [320]u8 = undefined;
    const watch_url = std.fmt.bufPrintZ(&watch_url_buf, "{s}/play/{s}/{s}", .{ base, session, ep_no }) catch return false;

    logs.pushLog("info", "anime", "DDL: Loading via AnimePahe...", false);

    // Load directly via mpv (it will use ytdl-hook or we can try yt-dlp extraction)
    const c = @import("../core/c.zig");
    if (state.app.players.items.len > 0 and state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        var cmd_buf: [300]u8 = undefined;
        const cmd_str = std.fmt.bufPrintZ(&cmd_buf, "loadfile \"{s}\"", .{watch_url}) catch return false;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd_str.ptr);
        return true;
    }

    return false;
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
//   3. playEpisode(ep)         → scraperPlayThread → EMBED URL → playEmbed()
//
// The EMBED URL each framework produces is fed to the SAME extractor stack
// (anime_extractors.resolveEmbed via playEmbed) already on main:
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
var scraper_ep_url: [200][256]u8 = undefined;
var scraper_ep_len: [200]usize = std.mem.zeroes([200]usize);
/// True when results[] currently holds scraper cards (set at publish, cleared by
/// the Jikan/lists publishers). Routes loadEpisodes/playEpisode to the scraper.
var results_are_scraper: bool = false;
/// Which framework produced the current results[]/episodes.
var scraper_kind: AnimeScraper = .none;

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
    state.app.anime.is_loading.store(true, .release);
    state.app.anime.selected_idx = null;
    state.app.anime.episode_count = 0;
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;
    grid_page = 1;
    more_available = false;
    search_query_len = 0; // empty query → popular
    if (std.Thread.spawn(.{}, scraperSearchThread, .{my_gen})) |t| {
        t.detach();
    } else |_| state.app.anime.is_loading.store(false, .release);
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
    const io_g = @import("../core/io_global.zig");
    var ref_buf: [320]u8 = undefined;
    const ref_hdr = std.fmt.bufPrint(&ref_buf, "Referer: {s}", .{referer}) catch return 0;
    const argv = [_][]const u8{
        "curl",       "-sL",           "-A",   agent,
        "-H",         "X-Requested-With: XMLHttpRequest",
        "-H",         ref_hdr,         "--data", body,
        "--max-time", "15",            url,
    };
    var child = io_g.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io_g.readAll(so, dst) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

/// Fetch + parse a scraper search (or popular) grid and publish into results[].
/// Shares results[]/generation with the Jikan parser → takes anime_parse_mutex and
/// re-checks the generation, exactly like publishListsJson.
fn scraperSearchThread(my_gen: u32) void {
    defer state.app.anime.is_loading.store(false, .release);
    const src = activeScraper();
    if (src == .none) return;

    var base_buf: [256]u8 = undefined;
    const base = scraperBase(src, &base_buf) orelse return;

    // Snapshot the query (a newer search may overwrite the static buffer).
    var q_buf: [256]u8 = undefined;
    const qlen = @min(search_query_len, q_buf.len);
    @memcpy(q_buf[0..qlen], search_query_buf[0..qlen]);
    const query = q_buf[0..qlen];

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
    if (search_gen.load(.acquire) != my_gen) return; // superseded mid-fetch

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
    if (search_gen.load(.acquire) != my_gen) return 0;

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

    if (search_gen.load(.acquire) != my_gen) return 0;
    results_are_scraper = true;
    scraper_kind = src;
    state.app.anime.result_count = count;
    more_available = false;
    return count;
}

/// Fetch the selected card's detail page, parse its episode list, and publish the
/// episodes (oldest-first). Routed to from loadEpisodes when results are scraper
/// cards. Sets up the same episode_list/titles/aired arrays the UI already renders.
fn loadEpisodesScraper(idx: usize) void {
    if (idx >= state.app.anime.result_count) return;
    state.app.anime.selected_idx = idx;
    state.app.anime.episode_count = 0;
    state.app.anime.is_loading.store(true, .release);
    if (std.Thread.spawn(.{}, episodesScraperThread, .{idx})) |t| {
        t.detach();
    } else |_| state.app.anime.is_loading.store(false, .release);
}

fn episodesScraperThread(idx: usize) void {
    defer state.app.anime.is_loading.store(false, .release);
    const src = scraper_kind;
    if (src == .none or idx >= state.app.anime.results.len) return;
    const durl = scraper_detail_url[idx][0..scraper_detail_len[idx]];
    if (durl.len == 0) return;

    var base_buf: [256]u8 = undefined;
    const base = scraperBase(src, &base_buf) orelse durl; // fall back to detail origin

    var detail_copy: [256]u8 = undefined;
    @memcpy(detail_copy[0..durl.len], durl);
    const detail_url = detail_copy[0..durl.len];

    const html_buf = alloc.alloc(u8, 1024 * 1024) catch return;
    defer alloc.free(html_buf);
    const n = scraperGet(detail_url, html_buf);
    if (n == 0 or workers_isQuitting()) return;
    const html = html_buf[0..n];

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
    const tmp = alloc.alloc(EpTmp, 200) catch return;
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
            if (found == 0) addEp(detail_url, "Movie", "", base, tmp, &found);
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
    if (found == 0 or workers_isQuitting()) return;
    if (state.app.anime.selected_idx != idx) return; // user navigated away

    // Publish reversed (oldest-first) into the shared episode arrays. Episode
    // NUMBERS are 1..N (what the UI plays by); the site's own label becomes the
    // episode title. scraper_ep_url[i] is the episode page to resolve on play.
    anime_parse_mutex.lock();
    defer anime_parse_mutex.unlock();
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
}

/// Resolve the selected episode's EMBED URL (per framework) and hand it to
/// playEmbed. Runs on a worker thread (blocking HTTP).
fn scraperPlayThread(ep_buf: [8]u8, ep_len: usize) void {
    defer state.app.anime.stream_loading = false;
    const src = scraper_kind;
    if (src == .none) return;
    const ep_no = ep_buf[0..ep_len];

    // Map episode number → the parallel scraper_ep_url index (episode_list is 1..N,
    // so index = number-1; fall back to a label scan for robustness).
    var ep_idx: usize = blk: {
        if (std.fmt.parseInt(usize, ep_no, 10)) |n| {
            if (n >= 1 and n <= state.app.anime.episode_count) break :blk n - 1;
        } else |_| {}
        var i: usize = 0;
        while (i < state.app.anime.episode_count) : (i += 1) {
            if (std.mem.eql(u8, state.app.anime.episode_list[i][0..state.app.anime.episode_list_lens[i]], ep_no)) break :blk i;
        }
        break :blk 0;
    };
    if (ep_idx >= scraper_ep_url.len) ep_idx = 0;
    const eurl = scraper_ep_url[ep_idx][0..scraper_ep_len[ep_idx]];
    if (eurl.len == 0) {
        logs.pushLog("error", "anime", "Scraper: no episode URL for this episode", true);
        return;
    }
    var ep_copy: [256]u8 = undefined;
    @memcpy(ep_copy[0..eurl.len], eurl);
    const ep_url = ep_copy[0..eurl.len];

    var base_buf: [256]u8 = undefined;
    const base = scraperBase(src, &base_buf) orelse "";

    const html_buf = alloc.alloc(u8, 1024 * 1024) catch return;
    defer alloc.free(html_buf);
    const n = scraperGet(ep_url, html_buf);
    if (n == 0 or workers_isQuitting()) {
        logs.pushLog("error", "anime", "Scraper: episode page fetch failed", true);
        return;
    }
    const html = html_buf[0..n];

    var embed_buf: [1024]u8 = undefined;
    const embed: ?[]const u8 = switch (src) {
        .animestream => animestream.firstEmbed(html, &embed_buf),
        .dooplay => resolveDooplayEmbed(html, base, ep_url, &embed_buf),
        .none => null,
    };
    const e = embed orelse {
        logs.pushLog("error", "anime", "Scraper: no embed found on episode page", true);
        return;
    };
    logs.pushLog("info", "anime", "Scraper: embed resolved → playing", false);
    playEmbed(e);
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
/// and reveal the player. Hosts yt-dlp already handles are passed through
/// untouched (see anime_extractors.resolveEmbed).
pub fn playEmbed(embed_url: []const u8) void {
    const S = struct {
        var busy: bool = false;
        var url_buf: [2048]u8 = undefined;
        var url_len: usize = 0;

        fn worker() void {
            defer @This().busy = false;
            const extractors = @import("anime_extractors.zig");
            const embed = @This().url_buf[0..@This().url_len];

            const resolved = extractors.resolveEmbed(embed) orelse {
                logs.pushLog("error", "anime", "Embed resolve failed — no playable stream", true);
                return;
            };

            const c = @import("../core/c.zig");
            // Player-access guard (CLAUDE convention): never index players by a
            // stale active_player_idx.
            if (!(state.app.active_player_idx < state.app.players.items.len)) {
                logs.pushLog("warn", "anime", "No active player to load the embed into", false);
                return;
            }
            const p = state.app.players.items[state.app.active_player_idx];

            if (resolved.delegate) {
                // yt-dlp handles this host — hand the embed to mpv's ytdl-hook,
                // no Referer of ours.
                p.loadStreamWithHeaders(resolved.streamUrl(), "");
            } else {
                p.loadStreamWithHeaders(resolved.streamUrl(), resolved.refererStr());
                // Attach subtitle tracks (e.g. MegaCloud caption tracks).
                for (resolved.subs[0..resolved.sub_count]) |sub| {
                    var cmd_buf: [640]u8 = undefined;
                    if (std.fmt.bufPrintZ(&cmd_buf, "sub-add \"{s}\"", .{sub.url[0..sub.url_len]})) |cmd| {
                        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
                    } else |_| {}
                }
                logs.pushLog("info", "anime", "Embed resolved → streaming", false);
            }

            state.gotoPlayer();
        }
    };

    if (S.busy) return;
    if (embed_url.len == 0 or embed_url.len > S.url_buf.len) return;
    S.busy = true;
    @memcpy(S.url_buf[0..embed_url.len], embed_url);
    S.url_len = embed_url.len;

    if (std.Thread.spawn(.{}, S.worker, .{})) |t| {
        t.detach();
    } else |_| {
        S.busy = false;
    }
}

// ══════════════════════════════════════════════════════════
// UI Rendering (Drawer)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    // Free any poster textures queued by parse worker threads (UI-thread only).
    drainPendingTexFrees();

    // ── Mode dispatch. Each grid mode reuses results[]/renderGallery; only the
    //    fetch differs. We fire exactly once per (mode + sub-selector) change,
    //    plus SWR auto-refresh on Trending only (other modes don't cross-
    //    contaminate trending's last_fetch_s). Skipped while an anime detail is
    //    open (selected_idx != null) so the detail view stays stable. ──
    // "Airing this week" is a VIEW, not a browse mode: it has its own fetch
    // (AniList airingSchedules) and content path, so it bypasses the grid-mode
    // dispatch entirely.
    if (state.app.anime.sched_view) {
        anime_schedule.loadSchedule();
    } else if (state.app.anime.selected_idx == null) {
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

    // Only show the spinner on an INITIAL load (nothing to show yet). During a
    // live-search / stale refresh the current cards stay on screen — seamless.
    if (state.app.anime.is_loading.load(.acquire) and state.app.anime.result_count == 0 and
        state.app.anime.selected_idx == null)
    {
        _ = dvui.label(@src(), "Loading...", .{}, .{
            .color_text = theme.colors.accent,
            .gravity_x = 0.5,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
        return;
    }

    if (state.app.anime.stream_loading) {
        _ = dvui.label(@src(), "Loading stream...", .{}, .{
            .color_text = theme.colors.accent,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    // Episode list (if anime selected)
    if (state.app.anime.selected_idx) |sel_idx| {
        if (sel_idx < state.app.anime.result_count) {
            const r = state.app.anime.results[sel_idx];
            {
                var sel_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                    .background = true,
                    .color_fill = theme.colors.bg_surface,
                });
                defer sel_row.deinit();

                if (dvui.button(@src(), "<", .{}, .{
                    .color_fill = theme.colors.accent,
                    .color_text = dvui.Color.white,
                    .corner_radius = theme.dims.rad_sm,
                    .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
                })) {
                    state.app.anime.selected_idx = null;
                    state.app.anime.episode_count = 0;
                }

                var rn_buf: [128]u8 = undefined;
                _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(r.name[0..r.name_len], &rn_buf)}, .{
                    .color_text = theme.colors.text_primary,
                    .expand = .horizontal,
                    .padding = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
                });

                // Episode count badge
                {
                    var ep_info: [32]u8 = undefined;
                    const info = std.fmt.bufPrintZ(&ep_info, "{d} ep", .{state.app.anime.episode_count}) catch "?";
                    _ = dvui.label(@src(), "{s}", .{info}, .{
                        .id_extra = 50,
                        .color_text = theme.colors.text_secondary,
                    });
                }
            }

            // ── Tracking header: progress bar + "{watched}/{total}" + Resume ──
            if (state.app.anime.episode_count > 0) {
                const total = state.app.anime.episode_count;
                const watched = watchedCount();
                var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = 60,
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                });
                defer hdr.deinit();

                // Resume button → plays the lowest unwatched episode.
                if (dvui.button(@src(), "Resume", .{}, .{
                    .id_extra = 61,
                    .color_fill = theme.colors.accent,
                    .color_text = dvui.Color.white,
                    .corner_radius = theme.dims.rad_sm,
                    .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
                    .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
                    .gravity_y = 0.5,
                })) {
                    var eb: [8]u8 = undefined;
                    const es = std.fmt.bufPrint(&eb, "{d}", .{nextUnwatchedEp()}) catch "1";
                    playEpisode(es);
                }

                // "Resume E{n}" hint label.
                {
                    var rl: [16]u8 = undefined;
                    const rs = std.fmt.bufPrintZ(&rl, "E{d}", .{nextUnwatchedEp()}) catch "";
                    _ = dvui.label(@src(), "{s}", .{rs}, .{
                        .id_extra = 62,
                        .color_text = theme.colors.text_secondary,
                        .gravity_y = 0.5,
                        .padding = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
                    });
                }

                // Progress bar (filled fraction = watched/total).
                {
                    const frac: f32 = if (total > 0) @as(f32, @floatFromInt(watched)) / @as(f32, @floatFromInt(total)) else 0;
                    var track = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = 63,
                        .expand = .horizontal,
                        .min_size_content = .{ .w = 80, .h = 8 },
                        .background = true,
                        .color_fill = theme.colors.bg_elevated,
                        .corner_radius = dvui.Rect.all(4),
                        .gravity_y = 0.5,
                    });
                    defer track.deinit();
                    if (frac > 0) {
                        var fill = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .id_extra = 64,
                            .min_size_content = .{ .w = @max(4, track.data().rect.w * frac), .h = 8 },
                            .background = true,
                            .color_fill = theme.colors.accent,
                            .corner_radius = dvui.Rect.all(4),
                        });
                        fill.deinit();
                    }
                }

                // "{watched}/{total}" count.
                {
                    var cb: [24]u8 = undefined;
                    const cs = std.fmt.bufPrintZ(&cb, "{d}/{d}", .{ watched, total }) catch "";
                    _ = dvui.label(@src(), "{s}", .{cs}, .{
                        .id_extra = 65,
                        .color_text = theme.colors.text_primary,
                        .gravity_y = 0.5,
                        .padding = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
                    });
                }
            }

            // ── Seasons & Related rail (Jikan relations) ──
            if (state.app.anime.relation_count > 0 or state.app.anime.relations_loading) {
                renderRelationsRail();
            }

            // Episode cards
            if (state.app.anime.episode_count > 0) {
                // Loading indicator for episode enrichment
                if (state.app.anime.episodes_loading) {
                    _ = dvui.label(@src(), "Loading episode details...", .{}, .{
                        .color_text = theme.colors.accent,
                        .padding = .{ .x = 12, .y = 4, .w = 0, .h = 0 },
                    });
                }

                var scroll = dvui.scrollArea(@src(), .{}, .{
                    .expand = .both,
                });
                defer scroll.deinit();

                var ep_i: usize = 0;
                while (ep_i < state.app.anime.episode_count) : (ep_i += 1) {
                    const ep_len = state.app.anime.episode_list_lens[ep_i];
                    if (ep_len == 0) continue;
                    const ep_str = state.app.anime.episode_list[ep_i][0..ep_len];
                    const has_title = state.app.anime.episode_title_lens[ep_i] > 0;
                    const is_filler = state.app.anime.episode_filler[ep_i];
                    const is_watched = ep_i < state.app.anime.episode_watched.len and state.app.anime.episode_watched[ep_i];

                    // Episode card container — watched rows get a subtle dim.
                    const fill_color = if (is_filler)
                        dvui.Color{ .r = 60, .g = 40, .b = 40, .a = 255 }
                    else if (is_watched)
                        dvui.Color{ .r = 18, .g = 22, .b = 30, .a = 255 }
                    else
                        theme.colors.bg_surface;

                    var ep_card = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .id_extra = ep_i + 2000,
                        .expand = .horizontal,
                        .background = true,
                        .color_fill = fill_color,
                        .color_border = theme.colors.border_subtle,
                        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
                    });
                    defer ep_card.deinit();

                    // Top row: Ep number + play button
                    {
                        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .id_extra = ep_i + 3000,
                            .expand = .horizontal,
                        });
                        defer top.deinit();

                        // Watched toggle — click flips the flag + persists to DB.
                        // Filled check (✓) when watched, hollow circle when not.
                        const chk_label: []const u8 = if (is_watched) "\xe2\x9c\x93" else "\xe2\x97\x8b"; // ✓ / ○
                        if (dvui.button(@src(), chk_label, .{}, .{
                            .id_extra = ep_i + 3050,
                            .background = true,
                            .color_fill = if (is_watched) theme.colors.success else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                            .color_text = if (is_watched) dvui.Color.white else theme.colors.text_secondary,
                            .corner_radius = theme.dims.rad_xl,
                            .padding = .{ .x = 5, .y = 1, .w = 5, .h = 1 },
                            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
                            .gravity_y = 0.5,
                        })) {
                            const ep_num = std.fmt.parseInt(usize, ep_str, 10) catch 0;
                            if (ep_num > 0) toggleWatched(sel_idx, ep_num);
                        }

                        // Episode number badge
                        var ep_badge: [16]u8 = undefined;
                        const badge = std.fmt.bufPrintZ(&ep_badge, "Ep {s}", .{ep_str}) catch "?";
                        _ = dvui.label(@src(), "{s}", .{badge}, .{
                            .id_extra = ep_i + 3100,
                            .color_text = if (is_watched) theme.colors.text_secondary else theme.colors.accent,
                        });

                        // Filler badge
                        if (is_filler) {
                            _ = dvui.label(@src(), " FILLER", .{}, .{
                                .id_extra = ep_i + 3200,
                                .color_text = dvui.Color{ .r = 255, .g = 100, .b = 100, .a = 200 },
                            });
                        }

                        // Score on the right
                        const sc = state.app.anime.episode_scores[ep_i];
                        if (sc > 0) {
                            var sc_buf: [8]u8 = undefined;
                            const sc_pct = @as(u8, @intFromFloat(std.math.clamp(sc * 20.0, 0.0, 100.0)));
                            const sc_color = if (sc_pct >= 70) theme.colors.success else if (sc_pct >= 50) theme.colors.warning else theme.colors.danger;
                            if (std.fmt.bufPrintZ(&sc_buf, " {d}%", .{sc_pct})) |scs| {
                                _ = dvui.label(@src(), "{s}", .{scs}, .{
                                    .id_extra = ep_i + 3300,
                                    .color_text = sc_color,
                                });
                            } else |_| {}
                        }
                    }

                    // Title row (if enriched)
                    if (has_title) {
                        // Jikan-sourced + worker-written: validate a copy so a
                        // malformed title can't panic dvui (whole-app abort).
                        var et_buf: [256]u8 = undefined;
                        const title = @import("../core/text.zig").safeUtf8Buf(state.app.anime.episode_titles[ep_i][0..state.app.anime.episode_title_lens[ep_i]], &et_buf);
                        if (dvui.button(@src(), title, .{}, .{
                            .id_extra = ep_i + 4000,
                            .expand = .horizontal,
                            .color_text = theme.colors.text_primary,
                            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                            .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                        })) {
                            playEpisode(ep_str);
                        }
                    } else {
                        // Fallback: plain play button
                        if (dvui.button(@src(), "▶ Play", .{}, .{
                            .id_extra = ep_i + 4000,
                            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                            .color_text = theme.colors.text_primary,
                            .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                        })) {
                            playEpisode(ep_str);
                        }
                    }

                    // Aired date
                    const aired_len = state.app.anime.episode_aired_lens[ep_i];
                    if (aired_len > 0) {
                        _ = dvui.label(@src(), "{s}", .{state.app.anime.episode_aired[ep_i][0..aired_len]}, .{
                            .id_extra = ep_i + 5000,
                            .color_text = theme.colors.text_secondary,
                        });
                    }
                }
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
    if (state.app.anime.is_loading.load(.acquire)) {
        // Don't stack fetches; record intent so we re-dispatch once it lands.
        return;
    }

    const m = state.app.anime.mode;
    switch (m) {
        .trending => {
            // Initial load + SWR background refresh (trending only).
            const stale = state.app.anime.result_count == 0 or
                @import("browse_cache.zig").isStale(state.app.anime.last_fetch_s);
            if (fetched_mode != .trending or stale) {
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

// ══════════════════════════════════════════════════════════
// Mode toolbar (Trending | Seasonal | Calendar | Search | My List)
// ══════════════════════════════════════════════════════════

fn renderModeToolbar(count: usize) void {
    // ONE wrapping flexbox holding the mode tabs, the per-mode chips, the result
    // count and the card-size controls — all on a single row (wraps if narrow).
    var bar = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 6 },
        .background = true,
        .color_fill = theme.colors.bg_app,
    });
    defer bar.deinit();

    renderModeTab(0, .trending, "Trending");
    renderModeTab(1, .seasonal, "Seasonal");
    renderModeTab(2, .calendar, "Calendar");
    renderModeTab(3, .search, "Search");
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
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / card_target_w)));
    const card_w: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));

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
                if (item.poster_fetching) {
                    item.poster_attempted = true;
                } else if (item.poster_attempted and item.poster_pixels == null and item.poster_tex == null) {
                    item.poster_failed = true;
                } else if (!item.poster_failed and item.poster_pixels == null and item.poster_url_len > 0) {
                    poster.fetchAsync(item.poster_url[0..item.poster_url_len], &item.poster_pixels, &item.poster_w, &item.poster_h, &item.poster_fetching);
                    if (item.poster_fetching) item.poster_attempted = true;
                }
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
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = idx + 8000,
        .background = true,
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_surface,
        .color_text = if (active) dvui.Color.white else theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
    })) {
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
        _ = dvui.label(@src(), "Search for anime or wait for trending...", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    // Responsive poster grid from the LIVE page width (one-frame lag; first
    // paint falls back to a sane default). Card width is user-cyclable.
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const card_target_w: f32 = card_w_pref;
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / card_target_w)));
    const card_w: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));

    // ── Virtualization (same shape as tmdb.zig renderGallery) ──
    // Uniform cards → fixed row pitch: content (poster + footer) + the card's
    // 6px bottom padding + 3px top/bottom margins. Off-viewport rows (±2
    // overscan) collapse into spacer boxes.
    const total = state.app.anime.result_count;
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
    if (more_available and state.app.anime.result_count > 0 and
        state.app.anime.result_count < state.app.anime.results.len)
    {
        const busy = grid_loading_more.load(.acquire);
        if (busy) {
            _ = dvui.label(@src(), "Loading more…", .{}, .{
                .id_extra = 80001,
                .expand = .horizontal,
                .gravity_x = 0.5,
                .color_text = theme.colors.text_secondary,
                .margin = .{ .x = 3, .y = 8, .w = 3, .h = 12 },
            });
        } else if (dvui.button(@src(), "▾ Load more", .{}, .{
            .id_extra = 80002,
            .expand = .horizontal,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 12, .w = 8, .h = 12 },
            .margin = .{ .x = 3, .y = 8, .w = 3, .h = 12 },
            .gravity_x = 0.5,
        })) {
            loadMoreGrid(); // tap fallback
        }

        // Auto-trigger when the user scrolls near the bottom (within 1.5 view-
        // ports of the content end), so it feels infinite without a click.
        const si = scroll.si;
        const max_scroll = si.scrollMax(.vertical);
        if (max_scroll > 0 and si.viewport.y >= max_scroll - si.viewport.h * 1.5) {
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
                if (item.poster_fetching) {
                    item.poster_attempted = true;
                } else if (item.poster_attempted and item.poster_pixels == null and item.poster_tex == null) {
                    item.poster_failed = true;
                } else if (!item.poster_failed and item.poster_pixels == null and item.poster_url_len > 0) {
                    poster.fetchAsync(item.poster_url[0..item.poster_url_len], &item.poster_pixels, &item.poster_w, &item.poster_h, &item.poster_fetching);
                    if (item.poster_fetching) item.poster_attempted = true;
                }
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
            var child = @import("../core/io_global.zig").Child.init(&argv, std.heap.c_allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            _ = child.spawn() catch {
                markDone(result_idx, u);
                return;
            };

            const img_buf = @import("../core/alloc.zig").allocator.alloc(u8, 512 * 1024) catch {
                _ = child.wait() catch {};
                markDone(result_idx, u);
                return;
            };
            defer @import("../core/alloc.zig").allocator.free(img_buf);
            const img_len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, img_buf) catch 0 else 0;
            _ = child.wait() catch {};

            if (img_len < 100) {
                markDone(result_idx, u);
                return;
            }

            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            const pixels = dvui.c.stbi_load_from_memory(img_buf[0..img_len].ptr, @intCast(img_len), &w, &h, &comp, 4);
            if (pixels == null) {
                markDone(result_idx, u);
                return;
            }
            defer dvui.c.stbi_image_free(pixels);

            if (w <= 0 or h <= 0) {
                markDone(result_idx, u);
                return;
            }
            // Compute in usize: w*h*4 in c_int (i32) overflows on a large crafted
            // image, panicking this worker thread and aborting the whole app.
            const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
            const p_slice = std.heap.c_allocator.alloc(u8, p_len) catch {
                markDone(result_idx, u);
                return;
            };
            @memcpy(p_slice, pixels[0..p_len]);

            // Verify the slot still holds the same URL before publishing.
            if (result_idx < state.app.anime.result_count) {
                const ptr = &state.app.anime.results[result_idx];
                if (ptr.poster_url_len == u.len and
                    std.mem.eql(u8, ptr.poster_url[0..ptr.poster_url_len], u))
                {
                    ptr.poster_w = @intCast(w);
                    ptr.poster_h = @intCast(h);
                    ptr.poster_pixels = p_slice;
                    ptr.poster_fetching = false;
                    return;
                }
            }
            std.heap.c_allocator.free(p_slice);
        }
    };

    if (std.Thread.spawn(.{}, S.worker, .{ url_copy, url.len, idx })) |t| {
        t.detach(); // never joined — detach so the handle isn't leaked
    } else |_| {
        item.poster_fetching = false;
    }
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
            var child = @import("../core/io_global.zig").Child.init(&argv, std.heap.c_allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;
            _ = child.spawn() catch {
                markDone(idx, url);
                return;
            };

            const img_buf = @import("../core/alloc.zig").allocator.alloc(u8, 512 * 1024) catch {
                _ = child.wait() catch {};
                markDone(idx, url);
                return;
            };
            defer @import("../core/alloc.zig").allocator.free(img_buf);
            const img_len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, img_buf) catch 0 else 0;
            _ = child.wait() catch {};

            if (img_len < 100) {
                markDone(idx, url);
                return;
            }

            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            const pixels = dvui.c.stbi_load_from_memory(img_buf[0..img_len].ptr, @intCast(img_len), &w, &h, &comp, 4);
            if (pixels == null) {
                markDone(idx, url);
                return;
            }
            defer dvui.c.stbi_image_free(pixels);

            if (w <= 0 or h <= 0) {
                markDone(idx, url);
                return;
            }
            // usize-first: w*h*4 in c_int overflows on a large crafted image and
            // panics this worker thread (whole-app abort).
            const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
            const p_slice = std.heap.c_allocator.alloc(u8, p_len) catch {
                markDone(idx, url);
                return;
            };
            @memcpy(p_slice, pixels[0..p_len]);

            if (idx < state.app.anime.continue_count) {
                const ptr = &state.app.anime.continue_items[idx];
                if (ptr.poster_url_len == url.len and std.mem.eql(u8, ptr.poster_url[0..ptr.poster_url_len], url)) {
                    ptr.poster_w = @intCast(w);
                    ptr.poster_h = @intCast(h);
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

    if (std.Thread.spawn(.{}, S.worker, .{ url_copy, url.len, idx })) |t| {
        t.detach();
    } else |_| {
        item.poster_fetching = false;
    }
}
