const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("icons");
const logs = @import("../core/logs.zig");
const player = @import("../player/player.zig");
const safeUtf8 = @import("../core/text.zig").safeUtf8;
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;
const poster = @import("../core/poster.zig");

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

/// Trending category chip — maps to Jikan top/anime `filter=` values.
const TrendFilter = enum {
    airing,
    top,
    bypopularity,
    upcoming,

    /// Jikan query value. `.top` is the un-filtered top list (no filter param).
    fn jikan(self: TrendFilter) []const u8 {
        return switch (self) {
            .airing => "airing",
            .top => "", // no filter → overall top
            .bypopularity => "bypopularity",
            .upcoming => "upcoming",
        };
    }
};
var trend_filter: TrendFilter = .airing;

/// User-cyclable card width (compact ↔ large), clamped 110–320 in the +/- wires.
var card_w_pref: f32 = 150;

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
            const jikan_api = "https://api.jikan.moe/v4/top/anime";
            const fv = trend_filter.jikan();
            break :blk (if (fv.len == 0)
                std.fmt.bufPrint(out, "{s}?limit=25&page={d}", .{ jikan_api, page })
            else
                std.fmt.bufPrint(out, "{s}?filter={s}&limit=25&page={d}", .{ jikan_api, fv, page })) catch null;
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
            break :blk std.fmt.bufPrint(out, "https://api.jikan.moe/v4/anime?q={s}&limit=25&page={d}", .{ enc_buf[0..enc_len], page }) catch null;
        },
        .seasonal => switch (state.app.anime.season_sel) {
            .now => std.fmt.bufPrint(out, "https://api.jikan.moe/v4/seasons/now?limit=25&page={d}", .{page}) catch null,
            .upcoming => std.fmt.bufPrint(out, "https://api.jikan.moe/v4/seasons/upcoming?limit=25&page={d}", .{page}) catch null,
            else => std.fmt.bufPrint(out, "https://api.jikan.moe/v4/seasons/{d}/{s}?limit=25&page={d}", .{ state.app.anime.season_year, seasonStr(state.app.anime.season_sel), page }) catch null,
        },
        .calendar => blk: {
            const day = calDayStr(state.app.anime.cal_day);
            break :blk (if (day.len == 0)
                std.fmt.bufPrint(out, "https://api.jikan.moe/v4/schedules?limit=25&page={d}", .{page})
            else
                std.fmt.bufPrint(out, "https://api.jikan.moe/v4/schedules?filter={s}&limit=25&page={d}", .{ day, page })) catch null;
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

    state.app.anime.thread = std.Thread.spawn(.{}, trendingThread, .{}) catch {
        state.app.anime.is_loading.store(false, .release);
        return;
    };
    if (state.app.anime.thread) |t| t.detach(); // never joined — detach to avoid leaking the handle
}

fn trendingThread() void {
    defer state.app.anime.is_loading.store(false, .release);
    // Capture the generation this load was spawned under (see searchThread).
    const my_gen = search_gen.load(.acquire);

    const jikan_api = "https://api.jikan.moe/v4/top/anime";
    var arg1_buf: [256]u8 = undefined;
    const fv = trend_filter.jikan();
    const arg1 = (if (fv.len == 0)
        std.fmt.bufPrint(&arg1_buf, "{s}?limit=25&page={d}", .{ jikan_api, grid_page })
    else
        std.fmt.bufPrint(&arg1_buf, "{s}?filter={s}&limit=25&page={d}", .{ jikan_api, fv, grid_page })) catch return;

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
    const url = std.fmt.bufPrint(&url_buf, "{s}?q={s}&limit=25&page={d}", .{ jikan_api, enc_buf[0..enc_len], grid_page }) catch return;

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
        .now => std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/seasons/now?limit=25&page={d}", .{grid_page}),
        .upcoming => std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/seasons/upcoming?limit=25&page={d}", .{grid_page}),
        else => std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/seasons/{d}/{s}?limit=25&page={d}", .{ year, seasonStr(sel), grid_page }),
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
        std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/schedules?limit=25&page={d}", .{grid_page})
    else
        std.fmt.bufPrint(&url_buf, "https://api.jikan.moe/v4/schedules?filter={s}&limit=25&page={d}", .{ day, grid_page })) catch return;

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
    return count - start_offset; // rows actually added (0 ⇒ no more pages worth fetching)
}

pub fn loadEpisodes(idx: usize) void {
    if (idx >= state.app.anime.result_count) return;
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

    var ep_copy: [8]u8 = std.mem.zeroes([8]u8);
    const ep_len = @min(ep_no.len, 7);
    @memcpy(ep_copy[0..ep_len], ep_no[0..ep_len]);

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

    // Search AnimePahe for the anime
    var url_buf: [512]u8 = undefined;
    const search_url = std.fmt.bufPrint(&url_buf, "https://animepahe.pw/api?m=search&q={s}", .{enc_buf[0..enc_len]}) catch return false;

    const argv_search = [_][]const u8{
        "curl",     "-sL",                                                                                          "--max-time", "10",
        "-H",       "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0", "-H",         "Referer: https://animepahe.pw",
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

    // Construct the watch URL for mpv + ytdl-hook
    // AnimePahe format: https://animepahe.pw/anime/{session}
    // mpv will use yt-dlp/ytdl to extract the stream
    var watch_url_buf: [256]u8 = undefined;
    const watch_url = std.fmt.bufPrintZ(&watch_url_buf, "https://animepahe.pw/play/{s}/{s}", .{ session, ep_no }) catch return false;

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
    if (state.app.anime.selected_idx == null) dispatchModeFetch();

    // Full-page root so loading/empty branches fill width/height.
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer page.deinit();

    // Mode toolbar + per-mode sub-toolbar + count/card-size controls. Hidden
    // while an anime is selected (episode-list view has its own header).
    if (state.app.anime.selected_idx == null) {
        // Single unified toolbar row: mode tabs + per-mode chips + count + zoom.
        renderModeToolbar(state.app.anime.result_count);
        // Search mode keeps the live search-as-you-type box (its own row).
        if (state.app.anime.mode == .search) renderSearchBar();
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
                    .color_fill = theme.colors.bg_card,
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
                    .color_text = theme.colors.text_main,
                    .expand = .horizontal,
                    .padding = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
                });

                // Episode count badge
                {
                    var ep_info: [32]u8 = undefined;
                    const info = std.fmt.bufPrintZ(&ep_info, "{d} ep", .{state.app.anime.episode_count}) catch "?";
                    _ = dvui.label(@src(), "{s}", .{info}, .{
                        .id_extra = 50,
                        .color_text = theme.colors.text_muted,
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
                        .color_text = theme.colors.text_muted,
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
                        .color_fill = theme.colors.bg_input,
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
                        .color_text = theme.colors.text_main,
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
                        theme.colors.bg_card;

                    var ep_card = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .id_extra = ep_i + 2000,
                        .expand = .horizontal,
                        .background = true,
                        .color_fill = fill_color,
                        .color_border = theme.colors.bg_header_border,
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
                            .color_text = if (is_watched) dvui.Color.white else theme.colors.text_muted,
                            .corner_radius = dvui.Rect.all(10),
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
                            .color_text = if (is_watched) theme.colors.text_muted else theme.colors.accent,
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
                            .color_text = theme.colors.text_main,
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
                            .color_text = theme.colors.text_main,
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
                            .color_text = theme.colors.text_muted,
                        });
                    }
                }
            } else {
                _ = dvui.label(@src(), "No episodes available", .{}, .{
                    .color_text = theme.colors.text_muted,
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
                    loadTrendingAnime();
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
        .color_fill = theme.colors.bg_header,
    });
    defer bar.deinit();

    renderModeTab(0, .trending, "Trending");
    renderModeTab(1, .seasonal, "Seasonal");
    renderModeTab(2, .calendar, "Calendar");
    renderModeTab(3, .search, "Search");
    renderModeTab(4, .mylist, "My List");

    // Per-mode chips, inline on the same row.
    switch (state.app.anime.mode) {
        .trending => {
            toolbarDivider(889);
            renderTrendChip(0, .airing, "Airing");
            renderTrendChip(1, .top, "Top");
            renderTrendChip(2, .bypopularity, "Popular");
            renderTrendChip(3, .upcoming, "Upcoming");
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
        .color_text = theme.colors.text_muted,
        .gravity_y = 0.5,
    });
    const dim = dvui.Color{ .r = 120, .g = 120, .b = 148, .a = 200 };
    if (dvui.buttonIcon(@src(), "smaller", icons.tvg.lucide.minus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = .{ .w = 16, .h = 16 },
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        card_w_pref = @max(110, card_w_pref - 40);
    }
    if (dvui.buttonIcon(@src(), "bigger", icons.tvg.lucide.plus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = .{ .w = 16, .h = 16 },
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
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_card,
        .color_text = if (active) dvui.Color.white else theme.colors.text_muted,
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
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_card,
        .color_text = if (active) dvui.Color.white else theme.colors.text_muted,
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
        .color_fill = theme.colors.bg_card,
        .color_text = theme.colors.text_main,
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
            .color_text = theme.colors.text_main,
            .gravity_y = 0.5,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
    }
    if (dvui.button(@src(), "+", .{}, .{
        .id_extra = 21102,
        .background = true,
        .color_fill = theme.colors.bg_card,
        .color_text = theme.colors.text_main,
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
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_card,
        .color_text = if (active) dvui.Color.white else theme.colors.text_muted,
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
            .color_text = theme.colors.text_muted,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_drawer });
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
        .color_fill = theme.colors.bg_card,
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
                if (!item.poster_fetching and item.poster_url_len > 0)
                    poster.fetchAsync(item.poster_url[0..item.poster_url_len], &item.poster_pixels, &item.poster_w, &item.poster_h, &item.poster_fetching);
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
            .color_text = theme.colors.text_main,
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
                .color_text = theme.colors.text_muted,
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
        .color_text = theme.colors.text_muted,
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
            .color_fill = theme.colors.bg_card,
            .color_text = theme.colors.text_main,
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
        .color_fill = theme.colors.bg_header,
    });
    defer search_row.deinit();

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.anime.search_buf },
        .placeholder = "Search anime…",
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 200, .h = 20 },
        .color_fill = theme.colors.bg_input,
        .color_border = theme.colors.border_input,
        .color_text = theme.colors.text_main,
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
        .color_text = theme.colors.text_muted,
        .gravity_y = 0.5,
    });

    // Card-size −/+ controls.
    toolbarDivider(950);
    const dim = dvui.Color{ .r = 120, .g = 120, .b = 148, .a = 200 };
    if (dvui.buttonIcon(@src(), "smaller", icons.tvg.lucide.minus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = .{ .w = 16, .h = 16 },
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        card_w_pref = @max(110, card_w_pref - 40);
    }
    if (dvui.buttonIcon(@src(), "bigger", icons.tvg.lucide.plus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = .{ .w = 16, .h = 16 },
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
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_card,
        .color_text = if (active) dvui.Color.white else theme.colors.text_muted,
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
            .color_text = theme.colors.text_muted,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_drawer });
    defer scroll.deinit();

    // Responsive poster grid from the LIVE page width (one-frame lag; first
    // paint falls back to a sane default). Card width is user-cyclable.
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const card_target_w: f32 = card_w_pref;
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / card_target_w)));
    const card_w: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));

    var i: usize = 0;
    while (i < state.app.anime.result_count) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 70000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and i + col < state.app.anime.result_count) : (col += 1) {
            renderCard(&state.app.anime.results[i + col], i + col, card_w);
        }
        i += cols;
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
                .color_text = theme.colors.text_muted,
                .margin = .{ .x = 3, .y = 8, .w = 3, .h = 12 },
            });
        } else if (dvui.button(@src(), "▾ Load more", .{}, .{
            .id_extra = 80002,
            .expand = .horizontal,
            .color_fill = theme.colors.bg_glass,
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
        .color_text = theme.colors.text_main,
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
            _ = dvui.label(@src(), "{s}", .{es}, .{ .id_extra = idx + 1604, .color_text = theme.colors.text_muted });
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
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx + 1000,
        .min_size_content = .{ .w = card_w, .h = 10 },
        .max_size_content = .{ .w = card_w, .h = poster_h + 92 },
        .background = true,
        .color_fill = theme.colors.bg_card,
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
                // bespoke curl fetch left anime cards on placeholders).
                if (!item.poster_fetching and item.poster_url_len > 0)
                    poster.fetchAsync(item.poster_url[0..item.poster_url_len], &item.poster_pixels, &item.poster_w, &item.poster_h, &item.poster_fetching);
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
            .color_text = theme.colors.text_main,
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
                _ = dvui.label(@src(), "{s}", .{eps}, .{ .id_extra = idx + 610, .color_text = theme.colors.text_muted });
            } else |_| {}

            _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 620, .color_text = theme.colors.text_muted });

            // Score percentage
            const pct = @as(u8, @intFromFloat(std.math.clamp(item.score * 10.0, 0.0, 100.0)));
            const sc = if (pct >= 70) theme.colors.success else if (pct >= 50) theme.colors.warning else theme.colors.danger;
            var pb: [8]u8 = undefined;
            if (std.fmt.bufPrintZ(&pb, "{d}%", .{pct})) |ps| {
                _ = dvui.label(@src(), "{s}", .{ps}, .{ .id_extra = idx + 310, .color_text = sc });
            } else |_| {}
        }

        // Calendar mode: airtime badge (broadcast.string, e.g. "Mondays at 01:00
        // (JST)") aligned to this result index. Only set in Calendar mode.
        if (state.app.anime.mode == .calendar and idx < state.app.anime.broadcast_lens.len and
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
                    .color_text = theme.colors.text_muted,
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
                .color_text = theme.colors.text_muted,
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
                .color_fill = theme.colors.bg_card,
                .color_border = theme.colors.border_drawer,
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
