const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const player = @import("../player/player.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const history = @import("history.zig");
const safeUtf8 = @import("../core/text.zig").safeUtf8;

pub const SearchResult = struct {
    name: []const u8,
    size: []const u8,
    seeds: []const u8,
    leech: []const u8,
    link: []const u8,
    engine: []const u8,
    is_nsfw: bool = false,
    added_ts: i64 = 0, // unix timestamp; 0 = unknown
};

pub var search_results = std.ArrayListUnmanaged(SearchResult).empty;
pub var search_results_mutex = @import("../core/sync.zig").Mutex{};
pub var search_page: usize = 0;
pub const SEARCH_ITEMS_PER_PAGE: usize = 20;

pub fn clearResults() void {
    const allocator = @import("../core/alloc.zig").allocator;
    search_results_mutex.lock();
    defer search_results_mutex.unlock();
    for (search_results.items) |r| {
        allocator.free(r.name);
        allocator.free(r.size);
        allocator.free(r.seeds);
        allocator.free(r.leech);
        allocator.free(r.link);
        allocator.free(r.engine);
    }
    search_results.clearRetainingCapacity();
}

pub var is_searching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var search_abort: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var search_thread: ?std.Thread = null;
pub var search_buf = std.mem.zeroes([1024]u8);

// Universal-search result sort mode (Relevance / Quality / Seeds).
const UniSort = enum(usize) { relevance = 0, quality = 1, seeds = 2 };
var uni_sort: UniSort = .relevance;

// Each search gets a monotonically-increasing generation. A worker only
// touches shared state (search_results, is_searching, search_thread) while it
// is still the current generation. A superseded worker that was detached writes
// nowhere and never frees buffers the new worker owns — avoids the UAF/
// double-free when triggerSearch aborts-and-respawns. (H2)
pub var search_generation = std.atomic.Value(u64).init(0);

pub const SortType = enum { Seeds, Size, Peers, Health, Time };
pub var current_sort: SortType = .Seeds;

// ── Minimum seed filter ──
pub var min_seed_filter: i64 = 0;
const seed_thresholds = [_]i64{ 0, 5, 10, 50 };

/// Detect quality from torrent name (2160p→4, 1080p→3, 720p→2, 480p→1, else 0)
fn detectQuality(name: []const u8) u8 {
    var lower_buf: [512]u8 = undefined;
    const check_len = @min(name.len, 511);
    for (0..check_len) |i| lower_buf[i] = std.ascii.toLower(name[i]);
    const lower = lower_buf[0..check_len];
    if (std.mem.indexOf(u8, lower, "2160p") != null or std.mem.indexOf(u8, lower, "4k") != null or std.mem.indexOf(u8, lower, "uhd") != null) return 4;
    if (std.mem.indexOf(u8, lower, "1080p") != null) return 3;
    if (std.mem.indexOf(u8, lower, "720p") != null) return 2;
    if (std.mem.indexOf(u8, lower, "480p") != null or std.mem.indexOf(u8, lower, "dvdrip") != null) return 1;
    return 0;
}

// ── Engine filter ──
pub const EngineFilter = enum(u4) {
    all = 0,
    @"1337x" = 1,
    yts = 2,
    piratebay = 3,
    eztv = 4,
    torrentproject = 5,
    nyaa = 6,
    limetorrents = 7,
    kickass = 8,
    solidtorrents = 9,
    torrentscsv = 10,
    apibay = 11,
    uindex = 12,

    pub fn label(self: EngineFilter) []const u8 {
        return switch (self) {
            .all => "All Engines",
            .@"1337x" => "1337x",
            .yts => "YTS",
            .piratebay => "PirateBay",
            .eztv => "EZTV",
            .torrentproject => "TorrentProject",
            .nyaa => "Nyaa",
            .limetorrents => "LimeTorrents",
            .kickass => "KickAss",
            .solidtorrents => "SolidTorrents",
            .torrentscsv => "TorrentsCSV",
            .apibay => "APIBay",
            .uindex => "UIndex",
        };
    }

    pub fn pyName(self: EngineFilter) []const u8 {
        return switch (self) {
            .all => "all",
            .@"1337x" => "one337x",
            .yts => "yts",
            .piratebay => "piratebay",
            .eztv => "eztv",
            .torrentproject => "torrentproject",
            .nyaa => "nyaa",
            .limetorrents => "limetorrents",
            .kickass => "kickass",
            .solidtorrents => "solidtorrents",
            .torrentscsv => "torrentscsv",
            .apibay => "apibay",
            .uindex => "uindex",
        };
    }
};
pub var engine_filter: EngineFilter = .all;

// ── NSFW keyword detection ──
const nsfw_keywords = [_][]const u8{
    "xxx",      "porn",     "hentai",  "erotic",    "nude",     "naked",     "adult",
    "brazzers", "bangbros", "naughty", "playboy",   "hustler",  "18+",       "milf",
    "anal",     "orgasm",   "fetish",  "bondage",   "hardcore", "softcore",  "nsfw",
    "onlyfans", "sexxx",    "lesbian", "threesome", "foursome", "stripshow", "cam girl",
};

pub fn isNsfwName(name: []const u8) bool {
    // Convert to lowercase for matching
    var lower_buf: [512]u8 = undefined;
    const check_len = @min(name.len, 511);
    for (0..check_len) |i| {
        lower_buf[i] = std.ascii.toLower(name[i]);
    }
    const lower = lower_buf[0..check_len];

    for (nsfw_keywords) |kw| {
        if (std.mem.indexOf(u8, lower, kw) != null) return true;
    }
    return false;
}

/// Extract clean engine name from URL: "https://thepiratebay.org" → "piratebay"
fn extractEngineName(engine_url: []const u8, buf: *[32]u8) []const u8 {
    // Strip protocol
    var s = engine_url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    // Strip "www." and "the"
    if (std.mem.startsWith(u8, s, "www.")) s = s[4..];
    if (std.mem.startsWith(u8, s, "the")) s = s[3..];
    // Take up to first dot or slash
    var end: usize = s.len;
    for (s, 0..) |ch, j| {
        if (ch == '.' or ch == '/') {
            end = j;
            break;
        }
    }
    if (end == 0) return "?";
    const name = s[0..@min(end, 31)];
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

fn engineColor(name: []const u8) dvui.Color {
    if (std.mem.eql(u8, name, "1337x")) return dvui.Color{ .r = 230, .g = 100, .b = 100, .a = 255 };
    if (std.mem.eql(u8, name, "yts")) return dvui.Color{ .r = 100, .g = 200, .b = 100, .a = 255 };
    if (std.mem.eql(u8, name, "piratebay")) return dvui.Color{ .r = 255, .g = 200, .b = 50, .a = 255 };
    if (std.mem.eql(u8, name, "eztv")) return dvui.Color{ .r = 100, .g = 180, .b = 255, .a = 255 };
    if (std.mem.eql(u8, name, "torrentproject")) return dvui.Color{ .r = 180, .g = 130, .b = 255, .a = 255 };
    if (std.mem.eql(u8, name, "nyaa")) return dvui.Color{ .r = 255, .g = 120, .b = 180, .a = 255 };
    if (std.mem.eql(u8, name, "kickass")) return dvui.Color{ .r = 255, .g = 160, .b = 80, .a = 255 };
    if (std.mem.eql(u8, name, "limetorrents")) return dvui.Color{ .r = 120, .g = 220, .b = 120, .a = 255 };
    if (std.mem.eql(u8, name, "solidtorrents")) return dvui.Color{ .r = 80, .g = 200, .b = 220, .a = 255 };
    if (std.mem.eql(u8, name, "torrentscsv")) return dvui.Color{ .r = 200, .g = 200, .b = 100, .a = 255 };
    if (std.mem.eql(u8, name, "EZTV API")) return dvui.Color{ .r = 100, .g = 180, .b = 255, .a = 255 };
    if (std.mem.eql(u8, name, "apibay")) return dvui.Color{ .r = 255, .g = 180, .b = 50, .a = 255 };
    if (std.mem.eql(u8, name, "uindex")) return dvui.Color{ .r = 80, .g = 210, .b = 210, .a = 255 };
    return dvui.Color{ .r = 140, .g = 150, .b = 170, .a = 200 };
}

fn sortResults(context: void, a: SearchResult, b: SearchResult) bool {
    _ = context;
    const s_a = std.fmt.parseInt(i64, a.seeds, 10) catch 0;
    const l_a = std.fmt.parseInt(i64, a.leech, 10) catch 0;
    const s_b = std.fmt.parseInt(i64, b.seeds, 10) catch 0;
    const l_b = std.fmt.parseInt(i64, b.leech, 10) catch 0;

    switch (current_sort) {
        .Seeds => return s_a > s_b,
        .Peers => return (s_a + l_a) > (s_b + l_b),
        .Size => {
            const sz_a: f64 = std.fmt.parseFloat(f64, a.size) catch 0.0;
            const sz_b: f64 = std.fmt.parseFloat(f64, b.size) catch 0.0;
            return sz_a > sz_b;
        },
        .Health => {
            const h_a = if (s_a + l_a == 0) 0.0 else @as(f32, @floatFromInt(s_a)) / @as(f32, @floatFromInt(s_a + l_a));
            const h_b = if (s_b + l_b == 0) 0.0 else @as(f32, @floatFromInt(s_b)) / @as(f32, @floatFromInt(s_b + l_b));
            if (h_a == h_b) return s_a > s_b;
            return h_a > h_b;
        },
        .Time => return a.added_ts > b.added_ts,
    }
}

pub fn asyncSearchTask(query: []const u8, my_gen: u64) void {
    const allocator = @import("../core/alloc.zig").allocator;
    defer allocator.free(query);

    // If a newer search already superseded us before we even started, bail
    // without touching any shared state.
    if (search_generation.load(.acquire) != my_gen) return;

    is_searching.store(true, .release);
    clearResults();

    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "python3") catch return;
    argv.append(allocator, "engines/nova2.py") catch return;
    argv.append(allocator, engine_filter.pyName()) catch return;
    argv.append(allocator, "all") catch return;
    argv.append(allocator, query) catch return;

    var child = @import("../core/io_global.zig").Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return;

    var child_reader_buf: [1024]u8 = undefined;
    var reader = child.stdout.?.reader(@import("../core/io_global.zig").io(), &child_reader_buf);

    var aborted = false;
    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        // On supersede/abort, stop PARSING but keep draining to EOF — nova2.py
        // runs a multiprocessing pool, and killing it mid-write spews
        // BrokenPipe + leaks semaphores. Draining lets it exit cleanly.
        if (!aborted and (search_abort.load(.acquire) or search_generation.load(.acquire) != my_gen)) aborted = true;
        if (aborted) continue;

        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, '|');

        const link = it.next() orelse continue;
        const name = it.next() orelse continue;
        const size_bytes = it.next() orelse continue;
        const seeds = it.next() orelse continue;
        const leech = it.next() orelse continue;
        const engine = it.next() orelse continue;

        const link_d = allocator.dupe(u8, link) catch continue;
        const name_d = allocator.dupe(u8, name) catch {
            allocator.free(link_d);
            continue;
        };
        const size_d = allocator.dupe(u8, size_bytes) catch {
            allocator.free(link_d);
            allocator.free(name_d);
            continue;
        };
        const seeds_d = allocator.dupe(u8, seeds) catch {
            allocator.free(link_d);
            allocator.free(name_d);
            allocator.free(size_d);
            continue;
        };
        const leech_d = allocator.dupe(u8, leech) catch {
            allocator.free(link_d);
            allocator.free(name_d);
            allocator.free(size_d);
            allocator.free(seeds_d);
            continue;
        };
        const engine_d = allocator.dupe(u8, engine) catch {
            allocator.free(link_d);
            allocator.free(name_d);
            allocator.free(size_d);
            allocator.free(seeds_d);
            allocator.free(leech_d);
            continue;
        };

        const item = SearchResult{
            .link = link_d,
            .name = name_d,
            .size = size_d,
            .seeds = seeds_d,
            .leech = leech_d,
            .engine = engine_d,
            .is_nsfw = isNsfwName(name),
        };

        search_results_mutex.lock();
        // Re-check generation under the lock: if we were superseded, the new
        // worker owns the list — drop our dupe rather than append/leak it.
        if (search_generation.load(.acquire) != my_gen) {
            search_results_mutex.unlock();
            freeSearchResult(item, allocator);
            break;
        }
        search_results.append(allocator, item) catch {
            search_results_mutex.unlock();
            freeSearchResult(item, allocator);
            continue;
        };
        search_results_mutex.unlock();
    }

    const superseded = search_generation.load(.acquire) != my_gen;

    // Drained to EOF above (even when aborted) so nova2 exits on its own — no
    // kill(), which would leave its pool workers spewing BrokenPipe.
    _ = child.wait() catch {};

    // A superseded worker must not touch shared state any further.
    if (superseded) return;

    // Also query EZTV JSON API directly (faster, no scraping)
    // Skip if engine filter is set to a non-EZTV specific engine
    if (!search_abort.load(.acquire) and (engine_filter == .all or engine_filter == .eztv))
        queryEztvApi(query, allocator, my_gen);

    if (!search_abort.load(.acquire) and search_generation.load(.acquire) == my_gen) {
        search_results_mutex.lock();
        std.sort.block(SearchResult, search_results.items, {}, sortResults);
        search_results_mutex.unlock();
    }
    // Only the current generation owns is_searching / search_thread.
    if (search_generation.load(.acquire) == my_gen) {
        is_searching.store(false, .release);
        search_thread = null;
    }
}

/// Free the owned buffers of a SearchResult that was never appended to the list.
fn freeSearchResult(r: SearchResult, allocator: std.mem.Allocator) void {
    allocator.free(r.name);
    allocator.free(r.size);
    allocator.free(r.seeds);
    allocator.free(r.leech);
    allocator.free(r.link);
    allocator.free(r.engine);
}

fn queryEztvApi(query: []const u8, allocator: std.mem.Allocator, my_gen: u64) void {
    // Build API URL: https://eztvx.to/api/get-torrents?limit=50&page=1
    // EZTV API doesn't support search by name — only by IMDB ID or listing all.
    // For name search, use the search page with scraping (already done by Python engine).
    // But we can supplement by querying pages and filtering client-side.
    var url_buf: [512]u8 = undefined;
    const api_url = std.fmt.bufPrint(&url_buf, "https://eztvx.to/api/get-torrents?limit=100&page=1", .{}) catch return;

    var client = std.http.Client{ .allocator = allocator, .io = @import("../core/io_global.zig").io() };
    defer client.deinit();

    const uri = std.Uri.parse(api_url) catch return;
    var req = client.request(.GET, uri, .{ .extra_headers = &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "ZigZag/1.0" },
    } }) catch return;
    defer req.deinit();
    req.sendBodiless() catch return;

    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return;
    if (response.head.status != .ok) return;

    var transfer_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var rdr = response.readerDecompressing(&transfer_buf, &decompress, &.{});

    const body = rdr.allocRemaining(allocator, std.Io.Limit.limited(512 * 1024)) catch return;
    defer allocator.free(body);

    // Parse EZTV JSON results — look for torrents matching query
    var lower_query: [256]u8 = undefined;
    const qlen = @min(query.len, 255);
    for (0..qlen) |i| lower_query[i] = std.ascii.toLower(query[i]);
    const lq = lower_query[0..qlen];

    // Simple JSON array item extraction
    var pos: usize = 0;
    while (pos < body.len) {
        // Find next torrent object
        const title_key = std.mem.indexOfPos(u8, body, pos, "\"title\":\"") orelse break;
        const title_start = title_key + 9;
        const title_end = std.mem.indexOfScalarPos(u8, body, title_start, '"') orelse break;
        const title = body[title_start..title_end];

        // Check query match (case-insensitive)
        var title_lower: [512]u8 = undefined;
        const tlen = @min(title.len, 511);
        for (0..tlen) |i| title_lower[i] = std.ascii.toLower(title[i]);

        pos = title_end + 1;

        // Check if any query word matches
        var matches = false;
        var words = std.mem.splitScalar(u8, lq, ' ');
        while (words.next()) |word| {
            if (word.len > 0 and std.mem.indexOf(u8, title_lower[0..tlen], word) != null) {
                matches = true;
                break;
            }
        }
        if (!matches) continue;

        // Extract magnet_url
        const magnet_key = std.mem.indexOfPos(u8, body, pos, "\"magnet_url\":\"") orelse continue;
        const magnet_start = magnet_key + 14;
        const magnet_end = std.mem.indexOfScalarPos(u8, body, magnet_start, '"') orelse continue;
        const magnet = body[magnet_start..magnet_end];

        // Extract size_bytes
        const size_key = std.mem.indexOfPos(u8, body, pos, "\"size_bytes\":\"") orelse continue;
        const size_start = size_key + 14;
        const size_end = std.mem.indexOfScalarPos(u8, body, size_start, '"') orelse continue;
        const size_str = body[size_start..size_end];

        // Extract seeds
        const seeds_key = std.mem.indexOfPos(u8, body, pos, "\"seeds\":") orelse continue;
        const seeds_start = seeds_key + 8;
        var seeds_end = seeds_start;
        while (seeds_end < body.len and body[seeds_end] != ',' and body[seeds_end] != '}') seeds_end += 1;
        const seeds_str = body[seeds_start..seeds_end];

        pos = seeds_end;

        // Extract date_released_unix
        var date_ts: i64 = 0;
        if (std.mem.indexOfPos(u8, body, pos, "\"date_released_unix\":")) |dk| {
            const ds = dk + 21;
            var de = ds;
            while (de < body.len and body[de] != ',' and body[de] != '}') de += 1;
            date_ts = std.fmt.parseInt(i64, body[ds..de], 10) catch 0;
        }

        const link_d = allocator.dupe(u8, magnet) catch continue;
        const name_d = allocator.dupe(u8, title) catch {
            allocator.free(link_d);
            continue;
        };
        const size_d = allocator.dupe(u8, size_str) catch {
            allocator.free(link_d);
            allocator.free(name_d);
            continue;
        };
        const seeds_d = allocator.dupe(u8, seeds_str) catch {
            allocator.free(link_d);
            allocator.free(name_d);
            allocator.free(size_d);
            continue;
        };
        const leech_d = allocator.dupe(u8, "0") catch {
            allocator.free(link_d);
            allocator.free(name_d);
            allocator.free(size_d);
            allocator.free(seeds_d);
            continue;
        };
        const engine_d = allocator.dupe(u8, "EZTV API") catch {
            allocator.free(link_d);
            allocator.free(name_d);
            allocator.free(size_d);
            allocator.free(seeds_d);
            allocator.free(leech_d);
            continue;
        };

        const item = SearchResult{
            .link = link_d,
            .name = name_d,
            .size = size_d,
            .seeds = seeds_d,
            .leech = leech_d,
            .engine = engine_d,
            .is_nsfw = isNsfwName(title),
            .added_ts = date_ts,
        };

        search_results_mutex.lock();
        // Drop our dupe if a newer search took over the list (H2).
        if (search_generation.load(.acquire) != my_gen) {
            search_results_mutex.unlock();
            freeSearchResult(item, allocator);
            return;
        }
        search_results.append(allocator, item) catch {
            search_results_mutex.unlock();
            freeSearchResult(item, allocator);
            continue;
        };
        search_results_mutex.unlock();
    }
}

/// Programmatic unified search — the shell omnibox's default action. Copies the
/// query into search_buf, switches to universal (all-source) mode, and kicks off
/// the resolver fan-out. Mirrors the in-page universal submit at renderSearchContent.
pub fn submitQuery(query_text: []const u8) void {
    if (query_text.len == 0) return;
    const resolver = @import("resolver.zig");
    const n = @min(query_text.len, search_buf.len - 1);
    @memset(&search_buf, 0);
    @memcpy(search_buf[0..n], query_text[0..n]);
    state.app.universal_search = true;
    resolver.resolve(search_buf[0..n], "auto");
}

/// Omnibox memory-mode flag. When set, the shell's submit path routes the
/// raw phrase through memorySearch() (conversational "?"-search) instead of the
/// plain unified search. R4 sets this; R3 honors it via the submit entry.
pub var memory_mode: bool = false;

/// Conversational "?"-search (Taste Receipts pillar). Embeds the phrase, finds
/// the nearest *spoiler-clamped* scene memory via db.retrieveScene, and uses
/// that scene's media_title as a SEED into the existing multi-source unified
/// search — results land in the normal grid (no new grid code).
///
/// Mandatory offline fallback: if getEmbedding fails OR no confident scene hit,
/// degrade to a plain unified search over the user's phrase. Never hard-fails.
pub fn memorySearch(phrase: []const u8) void {
    if (phrase.len == 0) return;

    const ai_memory = @import("ai_memory.zig");
    const db = @import("../core/db.zig");

    // Embed the phrase; a null embedding makes retrieveScene use its keyword/LIKE
    // fallback (also spoiler-clamped). Either path is safe.
    var floats: [ai_memory.EMBED_DIM]f32 = undefined;
    const ok = ai_memory.getEmbedding(phrase, &floats);

    // Active player's current title + time-pos drive the spoiler clamp. Guard the
    // index properly; an empty title means no same-title restriction.
    var cur_title: []const u8 = "";
    var cur_pos: f64 = 0;
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &cur_pos);
        cur_title = if (p.loading_label_len > 0 and p.loading_label_len <= 128)
            p.loading_label[0..p.loading_label_len]
        else
            "";
    }

    // Nearest scene memory (spoiler clamp reused from db.retrieveScene — not
    // reimplemented here).
    const hit = db.retrieveScene(if (ok) floats[0..] else null, phrase, cur_title, cur_pos);

    if (hit) |h| {
        const seed = h.title[0..h.title_len];
        if (seed.len > 0) {
            // Seed = the matched title; fan into the existing multi-source search.
            submitQuery(seed);
            return;
        }
    }

    // Offline / no-hit fallback: plain unified search over the raw phrase.
    submitQuery(phrase);
}

pub fn triggerSearch(query_text: []const u8) void {
    if (query_text.len == 0) return;

    // Bump the generation FIRST: any in-flight worker is now superseded and will
    // observe the new value before it touches shared state. Then detach (rather
    // than join, to keep the UI responsive) — the stale worker writes nowhere
    // and frees only its own un-appended dupes. (H2)
    const new_gen = search_generation.fetchAdd(1, .acq_rel) + 1;

    if (is_searching.load(.acquire)) {
        search_abort.store(true, .release);
        if (search_thread) |t| t.detach();
        search_thread = null;
        is_searching.store(false, .release);
    }

    search_abort.store(false, .release);
    history.addSearchHistory(query_text);
    const query = @import("../core/alloc.zig").allocator.dupe(u8, query_text) catch return;
    search_thread = std.Thread.spawn(.{}, asyncSearchTask, .{ query, new_gen }) catch {
        @import("../core/alloc.zig").allocator.free(query);
        return;
    };
    search_page = 0;
}

pub fn renderSearchContent() void {
    const resolver = @import("resolver.zig");

    // ── Mode toggle: Torrent vs Universal ──
    {
        var mode_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 2 },
            .background = true,
            .color_fill = theme.colors.bg_drawer,
        });
        defer mode_row.deinit();

        const uni_active = state.app.universal_search;
        // Segmented control — shared border, no gap, suppresses focus ring clash.
        var seg = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .background = true,
            .color_fill = dvui.Color{ .r = 22, .g = 22, .b = 32, .a = 255 },
            .color_border = dvui.Color{ .r = 42, .g = 42, .b = 58, .a = 200 },
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(6),
            .padding = dvui.Rect.all(2),
            .gravity_y = 0.5,
        });
        defer seg.deinit();

        const seg_btn = struct {
            fn opts(active: bool, id: usize) dvui.Options {
                return .{
                    .id_extra = id,
                    .color_fill = if (active) theme.colors.accent else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_text = if (active) dvui.Color{ .r = 10, .g = 10, .b = 16, .a = 255 } else theme.colors.text_muted,
                    .color_border = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
                    .corner_radius = dvui.Rect.all(4),
                    .gravity_y = 0.5,
                };
            }
        };

        if (dvui.button(@src(), "Universal", .{}, seg_btn.opts(uni_active, 8000))) {
            state.app.universal_search = true;
        }
        if (dvui.button(@src(), "Torrent", .{}, seg_btn.opts(!uni_active, 8001))) {
            state.app.universal_search = false;
        }

        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        // Source status indicators (universal mode)
        if (uni_active and resolver.isResolving()) {
            const dots = [_]struct { name: []const u8, st: resolver.SourceStatus, color: dvui.Color }{
                .{ .name = "JF", .st = resolver.status_jf.load(.acquire), .color = dvui.Color{ .r = 100, .g = 180, .b = 255, .a = 255 } },
                .{ .name = "ST", .st = resolver.status_stremio.load(.acquire), .color = dvui.Color{ .r = 100, .g = 220, .b = 100, .a = 255 } },
                .{ .name = "TR", .st = resolver.status_torrent.load(.acquire), .color = dvui.Color{ .r = 255, .g = 180, .b = 80, .a = 255 } },
                .{ .name = "AN", .st = resolver.status_anime.load(.acquire), .color = dvui.Color{ .r = 255, .g = 120, .b = 180, .a = 255 } },
                .{ .name = "YT", .st = resolver.status_yt.load(.acquire), .color = dvui.Color{ .r = 255, .g = 80, .b = 80, .a = 255 } },
            };
            for (dots, 0..) |d, di| {
                const tc = switch (d.st) {
                    .searching => d.color,
                    .done => theme.colors.success,
                    .failed => theme.colors.danger,
                    .idle => theme.colors.text_muted,
                };
                _ = dvui.label(@src(), "{s}", .{safeUtf8(d.name)}, .{
                    .id_extra = di + 8010,
                    .color_text = tc,
                    .padding = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                    .gravity_y = 0.5,
                });
            }
        }
    }

    // ── Search input row (single pill with inline button, matches paste-box) ──
    {
        var outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_drawer,
        });
        defer outer.deinit();

        const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        var input_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 },
            .corner_radius = dvui.Rect.all(8),
            .border = dvui.Rect.all(1),
            .color_border = dvui.Color{ .r = 40, .g = 40, .b = 55, .a = 180 },
            .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        });
        defer input_row.deinit();

        var te_opts = theme.optInput();
        te_opts.color_fill = transparent;
        te_opts.color_border = transparent;
        te_opts.border = dvui.Rect.all(0);
        te_opts.expand = .horizontal;
        te_opts.padding = .{ .x = 6, .y = 3, .w = 4, .h = 3 };

        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &search_buf }, .placeholder = "Search movies, shows, torrents, URLs…" }, te_opts);
        const enter_pressed = te.enter_pressed;
        const query_text = te.textGet();
        te.deinit();

        const clicked_search = dvui.buttonIcon(@src(), "", icons.tvg.lucide.search, .{}, .{}, .{
            .color_fill = transparent,
            .color_text = theme.colors.accent,
            .border = dvui.Rect.all(0),
            .gravity_y = 0.5,
            .padding = .{ .x = 5, .y = 4, .w = 3, .h = 4 },
        });
        if (clicked_search or enter_pressed) {
            // ── Intercept streamlink/direct URLs ──
            const sl = @import("streamlink.zig");
            const is_url = std.mem.startsWith(u8, query_text, "http://") or std.mem.startsWith(u8, query_text, "https://");
            if (is_url and state.app.players.items.len > 0) {
                const pi = @min(state.app.active_player_idx, state.app.players.items.len - 1);
                var url_z: [1024]u8 = std.mem.zeroes([1024]u8);
                const ulen = @min(query_text.len, url_z.len - 1);
                @memcpy(url_z[0..ulen], query_text[0..ulen]);
                state.app.players.items[pi].load_file(@ptrCast(&url_z));
                if (sl.isStreamlinkUrl(query_text)) {
                    state.showToast("Opening live stream...");
                } else {
                    state.showToast("Loading URL...");
                }
            } else if (memory_mode) {
                // Conversational "?"-search: route the raw phrase through the
                // taste/scene seed path (degrades silently to unified search).
                memorySearch(query_text);
            } else if (state.app.universal_search) {
                resolver.resolve(query_text, "auto");
            } else {
                triggerSearch(query_text);
            }
        }

        // Clear button — inline inside pill
        const has_text = std.mem.indexOfScalar(u8, &search_buf, 0) != @as(?usize, 0);
        if (has_text or search_results.items.len > 0 or resolver.result_count > 0) {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.x, .{}, .{}, .{
                .color_fill = transparent,
                .color_text = theme.colors.text_muted,
                .border = dvui.Rect.all(0),
                .gravity_y = 0.5,
                .padding = .{ .x = 3, .y = 4, .w = 5, .h = 4 },
            })) {
                @memset(&search_buf, 0);
                clearResults();
                resolver.clearResults();
            }
        }
    }

    // ── Universal results (if in universal mode) ──
    if (state.app.universal_search) {
        renderUniversalResults();
        return;
    }

    // ── Filters row (Sort + NSFW toggle) ──
    {
        var filter_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 4, .w = 0, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_drawer,
        });
        defer filter_row.deinit();

        _ = dvui.label(@src(), "Sort: ", .{}, .{ .gravity_y = 0.5, .color_text = theme.colors.text_muted });

        inline for (std.meta.fields(SortType)) |field| {
            const is_active = current_sort == @field(SortType, field.name);
            const color = if (is_active) theme.colors.accent else theme.colors.bg_glass;
            if (dvui.button(@src(), field.name, .{}, .{ .id_extra = field.value, .color_fill = color, .color_text = theme.colors.text_main, .corner_radius = theme.dims.rad_sm })) {
                current_sort = @enumFromInt(field.value);
                search_results_mutex.lock();
                std.sort.block(SearchResult, search_results.items, {}, sortResults);
                search_results_mutex.unlock();
                search_page = 0;
            }
        }

        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        // Min seed filter toggle
        {
            var seed_label_buf: [16]u8 = undefined;
            const seed_lbl = std.fmt.bufPrintZ(&seed_label_buf, "{d}+ seeds", .{min_seed_filter}) catch "0+";
            if (dvui.button(@src(), seed_lbl, .{}, .{
                .id_extra = 8900,
                .color_fill = if (min_seed_filter > 0) dvui.Color{ .r = 40, .g = 80, .b = 50, .a = 255 } else theme.colors.bg_glass,
                .color_text = if (min_seed_filter > 0) dvui.Color{ .r = 80, .g = 220, .b = 120, .a = 255 } else theme.colors.text_muted,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
            })) {
                // Cycle through thresholds
                var next_idx: usize = 0;
                for (seed_thresholds, 0..) |t, ti| {
                    if (t == min_seed_filter) {
                        next_idx = ti + 1;
                        break;
                    }
                }
                if (next_idx >= seed_thresholds.len) next_idx = 0;
                min_seed_filter = seed_thresholds[next_idx];
            }
        }

        // NSFW filter toggle
        if (dvui.button(@src(), if (state.app.nsfw_filter_enabled) "NSFW: Off" else "NSFW: On", .{}, .{
            .id_extra = 8950,
            .color_fill = if (state.app.nsfw_filter_enabled) dvui.Color{ .r = 60, .g = 30, .b = 30, .a = 255 } else dvui.Color{ .r = 50, .g = 30, .b = 50, .a = 255 },
            .color_text = if (state.app.nsfw_filter_enabled) dvui.Color{ .r = 220, .g = 80, .b = 80, .a = 255 } else dvui.Color{ .r = 180, .g = 100, .b = 180, .a = 255 },
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            state.app.nsfw_filter_enabled = !state.app.nsfw_filter_enabled;
        }

        // Engine filter selector
        if (dvui.button(@src(), engine_filter.label(), .{}, .{
            .id_extra = 9000,
            .color_fill = if (engine_filter != .all) theme.colors.accent else theme.colors.bg_glass,
            .color_text = if (engine_filter != .all) dvui.Color{ .r = 10, .g = 10, .b = 16, .a = 255 } else theme.colors.text_muted,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        })) {
            // Cycle to next engine
            const cur = @intFromEnum(engine_filter);
            engine_filter = @enumFromInt(if (cur >= 12) 0 else cur + 1);
        }
    }

    search_results_mutex.lock();
    defer search_results_mutex.unlock();

    // Current query (shown in the status line so it's clear what was searched).
    const qlen0 = std.mem.indexOfScalar(u8, &search_buf, 0) orelse search_buf.len;
    const cur_query = safeUtf8(search_buf[0..qlen0]);

    // ── Status line ──
    if (is_searching.load(.acquire)) {
        var live_buf: [320]u8 = undefined;
        const live_lbl = std.fmt.bufPrintZ(&live_buf, "Searching “{s}” … ({d} found)", .{ cur_query, search_results.items.len }) catch "Searching…";
        _ = dvui.label(@src(), "{s}", .{live_lbl}, .{
            .color_text = theme.colors.warning,
            .padding = .{ .x = 0, .y = 2, .w = 0, .h = 4 },
        });
    } else if (search_results.items.len > 0) {
        // Count visible results (after filters)
        var visible_count: usize = 0;
        for (search_results.items) |r| {
            if (state.app.nsfw_filter_enabled and r.is_nsfw) continue;
            const s_num_chk = std.fmt.parseInt(i64, r.seeds, 10) catch 0;
            if (s_num_chk < min_seed_filter) continue;
            visible_count += 1;
        }
        var count_buf: [320]u8 = undefined;
        const count_lbl = std.fmt.bufPrintZ(&count_buf, "{d} results for “{s}” ({d} total)", .{ visible_count, cur_query, search_results.items.len }) catch "results";
        _ = dvui.label(@src(), "{s}", .{count_lbl}, .{
            .color_text = dvui.Color{ .r = 120, .g = 130, .b = 150, .a = 255 },
            .padding = .{ .x = 0, .y = 2, .w = 0, .h = 4 },
        });
    }

    // ── Show search history when no results ──
    if (search_results.items.len == 0 and !is_searching.load(.acquire) and state.app.search_history_count > 0) {
        // Header
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .x = 12, .y = 10, .w = 12, .h = 4 },
            });
            defer hdr.deinit();
            _ = dvui.icon(@src(), "", icons.tvg.lucide.eye, .{}, .{
                .color_text = theme.colors.text_muted,
                .min_size_content = .{ .w = 14, .h = 14 },
                .gravity_y = 0.5,
            });
            _ = dvui.label(@src(), " Recent Searches", .{}, .{
                .color_text = theme.colors.text_muted,
                .gravity_y = 0.5,
            });
        }

        var scroll_hist = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_drawer });
        defer scroll_hist.deinit();

        var hi: usize = 0;
        while (hi < state.app.search_history_count) : (hi += 1) {
            const q = state.app.search_history_buf[hi][0..state.app.search_history_len[hi]];
            var hist_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = hi,
                .expand = .horizontal,
                .background = true,
                .color_fill = theme.colors.bg_card,
                .color_border = theme.colors.bg_header_border,
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .padding = .{ .x = 12, .y = 8, .w = 8, .h = 8 },
                .margin = .{ .x = 6, .y = 0, .w = 6, .h = 2 },
                .corner_radius = theme.dims.rad_sm,
            });
            defer hist_row.deinit();

            // Clock icon
            _ = dvui.icon(@src(), "", icons.tvg.lucide.search, .{}, .{
                .id_extra = hi + 1000,
                .color_text = theme.colors.text_muted,
                .min_size_content = .{ .w = 14, .h = 14 },
                .gravity_y = 0.5,
            });

            // Query text button (clickable to re-search)
            if (dvui.button(@src(), q, .{}, .{
                .id_extra = hi,
                .expand = .horizontal,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.text_main,
                .corner_radius = theme.dims.rad_sm,
                .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
            })) {
                @memset(&search_buf, 0);
                @memcpy(search_buf[0..q.len], q);
                triggerSearch(q);
            }

            // Delete button
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.x, .{}, .{}, .{
                .id_extra = hi,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.text_muted,
            })) {
                history.removeSearchHistory(hi);
                return;
            }
        }
        return;
    }

    // ── No-results empty state ──
    // When the user has a query in the box but the result list is empty
    // and nothing is in flight, show the canonical "no matches" surface
    // rather than a blank scroll area.
    if (search_results.items.len == 0 and !is_searching.load(.acquire)) {
        const buf_has_text = std.mem.indexOfScalar(u8, &search_buf, 0) != @as(?usize, 0);
        if (buf_has_text) {
            components.emptyState(
                icons.tvg.lucide.@"search-x",
                "No matches",
                "Try a broader query or check your spelling.",
            );
            return;
        }
    }

    // ── Pagination Controls (inline with search bar) ──
    const search_len = search_results.items.len;
    const total_pages = if (search_len == 0) 1 else (search_len + SEARCH_ITEMS_PER_PAGE - 1) / SEARCH_ITEMS_PER_PAGE;
    if (total_pages > 1) {
        var page_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 4 },
            .background = true,
            .color_fill = theme.colors.bg_drawer,
        });
        defer page_row.deinit();

        // "Searching..." or result count on the left
        if (is_searching.load(.acquire)) {
            _ = dvui.label(@src(), "Searching…", .{}, .{
                .color_text = theme.colors.warning,
                .gravity_y = 0.5,
            });
        }

        // Spacer pushes pagination to the right
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        // Prev button
        if (dvui.buttonIcon(@src(), "prev", icons.tvg.lucide.@"chevron-left", .{}, .{}, .{
            .color_fill = if (search_page > 0) theme.colors.bg_card else theme.colors.bg_glass,
            .color_text = if (search_page > 0) theme.colors.accent else theme.colors.text_muted,
            .corner_radius = theme.dims.rad_sm,
            .padding = dvui.Rect.all(5),
            .border = dvui.Rect.all(1),
            .color_border = theme.colors.border_drawer,
        })) {
            if (search_page > 0) search_page -= 1;
        }

        // Page indicator
        var page_label: [32]u8 = undefined;
        const page_str = std.fmt.bufPrintZ(&page_label, "{d}/{d}", .{ search_page + 1, total_pages }) catch "?";
        _ = dvui.label(@src(), "{s}", .{page_str}, .{
            .gravity_y = 0.5,
            .color_text = theme.colors.text_muted,
            .padding = .{ .x = 6, .y = 0, .w = 6, .h = 0 },
        });

        // Next button
        if (dvui.buttonIcon(@src(), "next", icons.tvg.lucide.@"chevron-right", .{}, .{}, .{
            .color_fill = if (search_page < total_pages - 1) theme.colors.bg_card else theme.colors.bg_glass,
            .color_text = if (search_page < total_pages - 1) theme.colors.accent else theme.colors.text_muted,
            .corner_radius = theme.dims.rad_sm,
            .padding = dvui.Rect.all(5),
            .border = dvui.Rect.all(1),
            .color_border = theme.colors.border_drawer,
        })) {
            if (search_page < total_pages - 1) search_page += 1;
        }
    }

    // ── Scrollable results list ──
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_drawer });
    defer scroll.deinit();

    const start_idx = search_page * SEARCH_ITEMS_PER_PAGE;
    const end_idx = @min(start_idx + SEARCH_ITEMS_PER_PAGE, search_len);
    if (start_idx < search_len) {
        for (search_results.items[start_idx..end_idx], start_idx..) |r, idx| {
            // Skip NSFW when filter is on
            if (state.app.nsfw_filter_enabled and r.is_nsfw) continue;
            // Skip below min seed threshold
            const s_num_filter = std.fmt.parseInt(i64, r.seeds, 10) catch 0;
            if (s_num_filter < min_seed_filter) continue;

            // ── Card container ──
            var row = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = idx,
                .expand = .horizontal,
                .background = true,
                .color_fill = theme.colors.bg_card,
                .color_border = if (r.is_nsfw) theme.colors.danger else theme.colors.bg_header_border,
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
            });
            defer row.deinit();

            // ── Row 1: Title ──
            _ = dvui.label(@src(), "{s}", .{safeUtf8(r.name)}, .{
                .id_extra = idx,
                .expand = .horizontal,
                .color_text = if (r.is_nsfw) theme.colors.warning else theme.colors.text_main,
            });

            // ── Row 1b: Quality badge (if detected) ──
            {
                const quality = detectQuality(r.name);
                if (quality > 0) {
                    const q_text: []const u8 = switch (quality) {
                        4 => "4K",
                        3 => "1080p",
                        2 => "720p",
                        1 => "480p",
                        else => "",
                    };
                    const q_color = switch (quality) {
                        4 => dvui.Color{ .r = 255, .g = 215, .b = 0, .a = 255 },
                        3 => dvui.Color{ .r = 100, .g = 200, .b = 255, .a = 255 },
                        2 => dvui.Color{ .r = 180, .g = 200, .b = 140, .a = 255 },
                        else => theme.colors.text_muted,
                    };
                    _ = dvui.label(@src(), "{s}", .{q_text}, .{
                        .id_extra = idx + 80000,
                        .color_text = q_color,
                        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 2 },
                    });
                }
            }

            // ── Row 2: Meta chips ──
            {
                var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = idx,
                    .expand = .horizontal,
                    .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
                });
                defer meta.deinit();

                const size_bytes_f = std.fmt.parseFloat(f64, r.size) catch 0.0;
                const s_num = std.fmt.parseInt(i64, r.seeds, 10) catch 0;
                const l_num = std.fmt.parseInt(i64, r.leech, 10) catch 0;

                // Health color by seed count
                const h_color = if (s_num >= 50) dvui.Color{ .r = 40, .g = 200, .b = 100, .a = 255 } else if (s_num >= 10) dvui.Color{ .r = 120, .g = 200, .b = 80, .a = 255 } else if (s_num >= 2) dvui.Color{ .r = 220, .g = 180, .b = 50, .a = 255 } else dvui.Color{ .r = 220, .g = 60, .b = 60, .a = 255 };

                // Health dot
                _ = dvui.label(@src(), "●", .{}, .{
                    .id_extra = idx,
                    .color_text = h_color,
                    .gravity_y = 0.5,
                    .padding = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                });

                // Seeds (green)
                _ = dvui.label(@src(), "{d}", .{s_num}, .{
                    .id_extra = idx,
                    .color_text = dvui.Color{ .r = 80, .g = 200, .b = 120, .a = 255 },
                    .gravity_y = 0.5,
                });

                // Separator
                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = idx,
                    .color_text = theme.colors.text_muted,
                    .gravity_y = 0.5,
                });

                // Leechers (red-ish)
                _ = dvui.label(@src(), "L:{d}", .{l_num}, .{
                    .id_extra = idx,
                    .color_text = dvui.Color{ .r = 200, .g = 100, .b = 80, .a = 255 },
                    .gravity_y = 0.5,
                });

                // Separator
                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = idx + 10000,
                    .color_text = theme.colors.text_muted,
                    .gravity_y = 0.5,
                });

                // Size (formatted as GB/MB)
                var size_buf: [24]u8 = undefined;
                const size_str = if (size_bytes_f >= 1073741824.0)
                    std.fmt.bufPrintZ(&size_buf, "{d:.1} GB", .{size_bytes_f / 1073741824.0}) catch "?"
                else if (size_bytes_f >= 1048576.0)
                    std.fmt.bufPrintZ(&size_buf, "{d:.0} MB", .{size_bytes_f / 1048576.0}) catch "?"
                else if (size_bytes_f >= 1024.0)
                    std.fmt.bufPrintZ(&size_buf, "{d:.0} KB", .{size_bytes_f / 1024.0}) catch "?"
                else
                    std.fmt.bufPrintZ(&size_buf, "{d:.0} B", .{size_bytes_f}) catch "?";

                _ = dvui.label(@src(), "{s}", .{size_str}, .{
                    .id_extra = idx,
                    .color_text = dvui.Color{ .r = 160, .g = 170, .b = 190, .a = 255 },
                    .gravity_y = 0.5,
                });

                // Spacer
                {
                    var sp = dvui.box(@src(), .{}, .{ .id_extra = idx, .expand = .horizontal });
                    sp.deinit();
                }

                // Engine name badge (color-coded)
                var eng_buf: [32]u8 = undefined;
                const eng_name = extractEngineName(r.engine, &eng_buf);
                const eng_color = engineColor(eng_name);
                _ = dvui.label(@src(), "{s}", .{eng_name}, .{
                    .id_extra = idx,
                    .color_text = eng_color,
                    .gravity_y = 0.5,
                    .padding = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
                });

                // Copy magnet button
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.clipboard, .{}, .{}, .{
                    .id_extra = idx + 90000,
                    .color_fill = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 255 },
                    .color_text = theme.colors.text_muted,
                    .corner_radius = theme.dims.rad_sm,
                    .padding = dvui.Rect.all(4),
                    .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
                    .min_size_content = .{ .w = 13, .h = 13 },
                    .gravity_y = 0.5,
                })) {
                    dvui.clipboardTextSet(r.link);
                    state.showToast("Magnet link copied");
                }

                // Add to queue button
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.plus, .{}, .{}, .{
                    .id_extra = idx + 70000,
                    .color_fill = dvui.Color{ .r = 30, .g = 35, .b = 50, .a = 255 },
                    .color_text = dvui.Color{ .r = 160, .g = 170, .b = 200, .a = 255 },
                    .corner_radius = theme.dims.rad_sm,
                    .padding = dvui.Rect.all(4),
                    .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
                    .min_size_content = .{ .w = 13, .h = 13 },
                    .gravity_y = 0.5,
                })) {
                    const queue = @import("queue.zig");
                    queue.addToQueue(r.link, r.name, r.engine);
                    state.showToast("Added to queue");
                }

                // Play button
                if (dvui.button(@src(), "Play", .{}, .{
                    .id_extra = idx,
                    .color_fill = theme.colors.accent,
                    .color_text = dvui.Color{ .r = 15, .g = 15, .b = 20, .a = 255 },
                    .corner_radius = theme.dims.rad_sm,
                })) {
                    if (r.is_nsfw) {
                        const nl = @min(r.link.len, 4095);
                        @memcpy(state.app.nsfw_confirm_link_buf[0..nl], r.link[0..nl]);
                        state.app.nsfw_confirm_link_len = nl;
                        const nn = @min(r.name.len, 255);
                        @memcpy(state.app.nsfw_confirm_name_buf[0..nn], r.name[0..nn]);
                        state.app.nsfw_confirm_name_len = nn;
                        state.app.nsfw_confirm_pending = true;
                    } else {
                        loadTorrentToPlayer(r.link);
                    }
                }

                // Drag & Double click logic
                for (dvui.events()) |*e| {
                    if (dvui.eventMatch(e, .{ .id = row.data().id, .r = row.data().borderRectScale().r })) {
                        if (e.evt == .mouse and e.evt.mouse.action == .motion and dvui.dragging(e.evt.mouse.p, null) != null) {
                            const max_len = @min(r.link.len, 4095);
                            @memcpy(state.app.dragging_magnet_buf[0..max_len], r.link[0..max_len]);
                            state.app.dragging_magnet_len = max_len;
                        }
                        if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button == .left) {
                            const now = @import("../core/io_global.zig").milliTimestamp();
                            if (state.app.last_clicked_search_idx == idx and (now - state.app.last_clicked_time) < 400) {
                                if (r.is_nsfw) {
                                    const nl2 = @min(r.link.len, 4095);
                                    @memcpy(state.app.nsfw_confirm_link_buf[0..nl2], r.link[0..nl2]);
                                    state.app.nsfw_confirm_link_len = nl2;
                                    const nn2 = @min(r.name.len, 255);
                                    @memcpy(state.app.nsfw_confirm_name_buf[0..nn2], r.name[0..nn2]);
                                    state.app.nsfw_confirm_name_len = nn2;
                                    state.app.nsfw_confirm_pending = true;
                                } else {
                                    loadTorrentToPlayer(r.link);
                                }
                            }
                            state.app.last_clicked_search_idx = idx;
                            state.app.last_clicked_time = now;
                        }
                    }
                }
            } // End meta

            // ── Right-click context menu for copy ──
            {
                const ctext = dvui.context(@src(), .{ .rect = row.data().borderRectScale().r }, .{ .id_extra = idx });
                defer ctext.deinit();

                if (ctext.activePoint()) |cp| {
                    var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{
                        .id_extra = idx,
                        .color_fill = theme.colors.bg_card,
                        .color_border = theme.colors.border_drawer,
                    });
                    defer fw.deinit();

                    if ((dvui.menuItemLabel(@src(), "Copy Title", .{}, .{ .expand = .horizontal, .id_extra = idx })) != null) {
                        dvui.clipboardTextSet(r.name);
                        state.showToast("Title copied");
                        fw.close();
                    }
                    if ((dvui.menuItemLabel(@src(), "Copy Magnet Link", .{}, .{ .expand = .horizontal, .id_extra = idx + 50000 })) != null) {
                        dvui.clipboardTextSet(r.link);
                        state.showToast("Magnet link copied");
                        fw.close();
                    }
                    if ((dvui.menuItemLabel(@src(), "Copy Size", .{}, .{ .expand = .horizontal, .id_extra = idx + 60000 })) != null) {
                        dvui.clipboardTextSet(r.size);
                        state.showToast("Size copied");
                        fw.close();
                    }
                }
            }
        } // End for
    } // End if
} // End of function

// ══════════════════════════════════════════════════════════
// Universal Search Results Renderer
// ══════════════════════════════════════════════════════════

/// Pre-search hint: a grid of the sources Universal search queries in parallel,
/// so an empty box doesn't look broken.
fn renderUniversalCapabilities() void {
    // Normal flow block BELOW the search bar (horizontal-only expand + a top
    // margin) — an `expand=.both` + gravity_y box floats up over the input.
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .gravity_x = 0.5,
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.xl, .w = theme.spacing.lg, .h = theme.spacing.lg },
    });
    defer col.deinit();

    dvui.icon(@src(), "uni", icons.tvg.lucide.telescope, .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = .{ .w = 36, .h = 36 },
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
    });
    _ = dvui.label(@src(), "Universal search", .{}, .{ .color_text = theme.colors.text_main, .font = dvui.themeGet().font_title, .gravity_x = 0.5 });
    _ = dvui.label(@src(), "One query, every source — searched in parallel.", .{}, .{ .color_text = theme.colors.text_muted, .gravity_x = 0.5 });

    const Src = struct { icon: []const u8, name: []const u8 };
    const sources = [_]Src{
        .{ .icon = icons.tvg.lucide.@"hard-drive", .name = "On disk" },
        .{ .icon = icons.tvg.lucide.magnet, .name = "Torrents" },
        .{ .icon = icons.tvg.lucide.server, .name = "Jellyfin" },
        .{ .icon = icons.tvg.lucide.youtube, .name = "YouTube" },
        .{ .icon = icons.tvg.lucide.tv, .name = "Anime" },
        .{ .icon = icons.tvg.lucide.clapperboard, .name = "Stremio" },
        .{ .icon = icons.tvg.lucide.rss, .name = "RSS" },
    };
    var flow = dvui.flexbox(@src(), .{ .justify_content = .center }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = 0 } });
    defer flow.deinit();
    for (sources, 0..) |s, i| {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 9700,
            .background = true,
            .color_fill = theme.colors.bg_card,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            .margin = dvui.Rect.all(4),
        });
        defer chip.deinit();
        dvui.icon(@src(), s.name, s.icon, .{}, .{ .id_extra = i + 9700, .color_text = theme.colors.accent, .min_size_content = .{ .w = 15, .h = 15 }, .gravity_y = 0.5, .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 } });
        _ = dvui.label(@src(), "{s}", .{s.name}, .{ .id_extra = i + 9700, .color_text = theme.colors.text_secondary, .gravity_y = 0.5 });
    }
}

/// Live search progress — a header with the query + a running result count,
/// and a chip per source that flips searching → done/failed in real time.
fn renderUniversalProgress() void {
    const resolver = @import("resolver.zig");

    // Header: query + live count.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 9200,
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 4 },
        });
        defer hdr.deinit();
        dvui.icon(@src(), "searching", icons.tvg.lucide.@"loader-circle", .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 16, .h = 16 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        });
        const q = resolver.resolver_query[0..resolver.resolver_query_len];
        var hb: [320]u8 = undefined;
        const hs = std.fmt.bufPrintZ(&hb, "Searching “{s}” — {d} found", .{ safeUtf8(q), resolver.result_count }) catch "Searching…";
        _ = dvui.label(@src(), "{s}", .{hs}, .{ .color_text = theme.colors.text_main, .gravity_y = 0.5 });
    }

    // Per-source status chips (live).
    const Row = struct { icon: []const u8, name: []const u8, st: resolver.SourceStatus };
    const tr = combinedTorrentStatus();
    const rows = [_]Row{
        .{ .icon = icons.tvg.lucide.@"hard-drive", .name = "On disk", .st = resolver.status_local.load(.acquire) },
        .{ .icon = icons.tvg.lucide.magnet, .name = "Torrents", .st = tr },
        .{ .icon = icons.tvg.lucide.server, .name = "Jellyfin", .st = resolver.status_jf.load(.acquire) },
        .{ .icon = icons.tvg.lucide.youtube, .name = "YouTube", .st = resolver.status_yt.load(.acquire) },
        .{ .icon = icons.tvg.lucide.tv, .name = "Anime", .st = resolver.status_anime.load(.acquire) },
        .{ .icon = icons.tvg.lucide.clapperboard, .name = "Stremio", .st = resolver.status_stremio.load(.acquire) },
        .{ .icon = icons.tvg.lucide.rss, .name = "RSS", .st = resolver.status_rss.load(.acquire) },
    };
    var flow = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .id_extra = 9210, .expand = .horizontal, .padding = .{ .x = 12, .y = 2, .w = 12, .h = 6 } });
    defer flow.deinit();
    for (rows, 0..) |r, i| {
        const done = r.st == .done;
        const failed = r.st == .failed;
        const accent = if (failed) theme.colors.danger else if (done) theme.colors.success else theme.colors.accent;
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 9220,
            .background = true,
            .color_fill = theme.colors.bg_card,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
            .margin = dvui.Rect.all(3),
        });
        defer chip.deinit();
        dvui.icon(@src(), r.name, r.icon, .{}, .{ .id_extra = i + 9220, .color_text = if (done or failed) theme.colors.text_secondary else theme.colors.accent, .min_size_content = .{ .w = 14, .h = 14 }, .gravity_y = 0.5, .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 } });
        _ = dvui.label(@src(), "{s}", .{r.name}, .{ .id_extra = i + 9220, .color_text = theme.colors.text_secondary, .gravity_y = 0.5 });
        const glyph = if (failed) icons.tvg.lucide.@"circle-x" else if (done) icons.tvg.lucide.@"circle-check" else icons.tvg.lucide.@"loader-circle";
        dvui.icon(@src(), "st", glyph, .{}, .{ .id_extra = i + 9230, .color_text = accent, .min_size_content = .{ .w = 13, .h = 13 }, .gravity_y = 0.5, .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 } });
    }

    // Poll ~5×/s while resolving so counts/status update live without input.
    const tid = flow.data().id;
    if (dvui.timerDoneOrNone(tid)) dvui.timer(tid, 200_000);
}

/// Torrent sources span three backends (nova2, 1337x, YTS) — show one chip:
/// searching if any is still going, failed only if all failed, else done.
fn combinedTorrentStatus() @import("resolver.zig").SourceStatus {
    const r = @import("resolver.zig");
    const a = r.status_torrent.load(.acquire);
    const b = r.status_1337x.load(.acquire);
    const c2 = r.status_yts.load(.acquire);
    if (a == .searching or b == .searching or c2 == .searching) return .searching;
    if (a == .failed and b == .failed and c2 == .failed) return .failed;
    return .done;
}

fn renderUniversalResults() void {
    const resolver = @import("resolver.zig");

    // Status / loading indicator
    if (resolver.isResolving()) {
        renderUniversalProgress();
    } else if (resolver.result_count > 0) {
        // Count + sort/filter row.
        var fr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 9050,
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        });
        defer fr.deinit();

        var count_buf: [320]u8 = undefined;
        const clbl = std.fmt.bufPrintZ(&count_buf, "{d} results for “{s}”", .{ resolver.result_count, safeUtf8(resolver.resolver_query[0..resolver.resolver_query_len]) }) catch "Results";
        _ = dvui.label(@src(), "{s}", .{clbl}, .{
            .id_extra = 9001,
            .color_text = theme.colors.text_muted,
            .gravity_y = 0.5,
        });
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        // Sort: relevance / quality / seeds
        const sorts = [_][]const u8{ "Relevance", "Quality", "Seeds" };
        if (components.segment(@src(), &sorts, @intFromEnum(uni_sort))) |clicked| {
            uni_sort = @enumFromInt(clicked);
            resolver.sortResultsBy(@intFromEnum(uni_sort));
        }
        // NSFW filter toggle (honored by the card loop's is_nsfw check below).
        const nsfw_label = if (state.app.nsfw_filter_enabled) "NSFW: off" else "NSFW: on";
        if (dvui.button(@src(), nsfw_label, .{}, .{
            .id_extra = 9060,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_muted,
            .border = dvui.Rect.all(0),
            .gravity_y = 0.5,
            .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
        })) {
            state.app.nsfw_filter_enabled = !state.app.nsfw_filter_enabled;
            state.markConfigDirty();
        }
    } else if (!resolver.isResolving() and resolver.resolver_query_len > 0) {
        // Canonical empty state — search-x icon + canonical copy.
        components.emptyState(
            icons.tvg.lucide.@"search-x",
            "No matches",
            "Try a broader query or check your spelling.",
        );
        // Retry affordance stays — wrap in a centering row.
        var retry_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.md },
        });
        defer retry_row.deinit();
        if (dvui.button(@src(), "Retry Universal Search", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = theme.colors.text_on_accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .gravity_x = 0.5,
        })) {
            resolver.resolve(resolver.resolver_query[0..resolver.resolver_query_len], "auto");
        }
        return;
    } else {
        // No query yet — show what Universal search reaches across.
        renderUniversalCapabilities();
        return;
    }

    // Results list
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_drawer });
    defer scroll.deinit();

    var list_layout = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = 4, .w = 0, .h = 100 } });
    defer list_layout.deinit();

    // Hold the results lock for the read loop so resolver workers can't shift
    // the array out from under us. Snapshot the count under the lock.
    resolver.results_mutex.lock();
    defer resolver.results_mutex.unlock();
    const snap_count = resolver.result_count;

    for (0..snap_count) |idx| {
        const item = &resolver.results[idx];
        if (item.name_len == 0) continue;
        // NSFW filter (S16) — hide adult-named items when the filter is on.
        if (state.app.nsfw_filter_enabled and item.is_nsfw) continue;

        // Source badge colors
        const badge_color = switch (item.source) {
            .jellyfin => dvui.Color{ .r = 100, .g = 180, .b = 255, .a = 255 },
            .stremio => dvui.Color{ .r = 100, .g = 220, .b = 100, .a = 255 },
            .torrent => dvui.Color{ .r = 255, .g = 180, .b = 80, .a = 255 },
            .anime => dvui.Color{ .r = 255, .g = 120, .b = 180, .a = 255 },
            .youtube => dvui.Color{ .r = 255, .g = 80, .b = 80, .a = 255 },
            .local => dvui.Color{ .r = 130, .g = 230, .b = 200, .a = 255 },
            .tmdb => dvui.Color{ .r = 1, .g = 180, .b = 228, .a = 255 },
        };
        const badge_text = switch (item.source) {
            .jellyfin => "JELLYFIN",
            .stremio => "STREAM",
            .torrent => "TORRENT",
            .anime => "ANIME",
            .youtube => "YT",
            .local => "ON DISK",
            .tmdb => "CATALOG",
        };

        // Result card — the whole card is clickable (→ play), plus an explicit
        // Play button and (for torrents) a +queue button below.
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 9100,
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 22, .g = 22, .b = 30, .a = 255 },
            .color_fill_hover = theme.colors.bg_hover,
            .color_border = dvui.Color{ .r = 40, .g = 40, .b = 55, .a = 180 },
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
            .margin = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        });
        defer card.deinit();
        if (dvui.clicked(card.data(), .{})) resolver.playItem(idx);
        card.drawBackground();

        // Top row: badge + name
        {
            var top_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = idx + 9200,
                .expand = .horizontal,
            });
            defer top_row.deinit();

            // Source badge
            if (dvui.button(@src(), badge_text, .{}, .{
                .id_extra = idx + 9300,
                .color_fill = badge_color,
                .color_text = dvui.Color{ .r = 10, .g = 10, .b = 16, .a = 255 },
                .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
                .corner_radius = dvui.Rect.all(4),
                .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            })) {
                // Badge click = play
                resolver.playItem(idx);
            }

            // Quality badge
            if (item.quality > 0) {
                const q_text = switch (item.quality) {
                    4 => "4K",
                    3 => "1080p",
                    2 => "720p",
                    1 => "480p",
                    else => "",
                };
                const q_color = switch (item.quality) {
                    4 => dvui.Color{ .r = 255, .g = 215, .b = 0, .a = 255 }, // Gold
                    3 => dvui.Color{ .r = 100, .g = 200, .b = 255, .a = 255 }, // Blue
                    else => theme.colors.text_muted,
                };
                _ = dvui.label(@src(), "{s}", .{q_text}, .{
                    .id_extra = idx + 9400,
                    .color_text = q_color,
                    .gravity_y = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
                });
            }

            // Name — expands to fill (dvui ellipsizes long titles).
            _ = dvui.label(@src(), "{s}", .{safeUtf8(item.name[0..item.name_len])}, .{
                .id_extra = idx + 9500,
                .expand = .horizontal,
                .color_text = theme.colors.text_main,
                .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
                .gravity_y = 0.5,
            });

            // Explicit Play affordance (don't rely on discovering the badge).
            if (dvui.buttonIcon(@src(), "play", icons.tvg.lucide.play, .{}, .{}, .{
                .id_extra = idx + 9700,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.accent,
                .border = dvui.Rect.all(0),
                .gravity_y = 0.5,
                .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
            })) {
                resolver.playItem(idx);
            }

            // Torrent results can also be queued for later.
            if (item.source == .torrent) {
                if (dvui.buttonIcon(@src(), "queue", icons.tvg.lucide.plus, .{}, .{}, .{
                    .id_extra = idx + 9800,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_text = theme.colors.text_secondary,
                    .border = dvui.Rect.all(0),
                    .gravity_y = 0.5,
                    .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                })) {
                    @import("queue.zig").addToQueue(item.url[0..item.url_len], item.name[0..item.name_len], "torrent");
                    state.showToast("Added to queue");
                }
            }
        }

        // Detail row
        if (item.detail_len > 0) {
            _ = dvui.label(@src(), "{s}", .{item.detail[0..item.detail_len]}, .{
                .id_extra = idx + 9600,
                .color_text = theme.colors.text_muted,
                .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            });
        }
    }
}

pub fn loadTorrentToPlayer(magnet_link: []const u8) void {
    const logs = @import("../core/logs.zig");
    const playermod = @import("../player/player.zig");

    // Auto-create a player if none exists
    if (state.app.players.items.len == 0) {
        if (playermod.MediaPlayer.init(@import("../core/alloc.zig").allocator)) |new_p| {
            state.app.players.append(@import("../core/alloc.zig").allocator, new_p) catch {
                new_p.deinit(@import("../core/alloc.zig").allocator);
                logs.pushLog("error", "search", "Failed to create player", true);
                return;
            };
            state.app.active_player_idx = 0;
        } else |_| {
            logs.pushLog("error", "search", "Failed to init player", true);
            return;
        }
    }

    if (state.app.active_player_idx >= state.app.players.items.len) {
        state.app.active_player_idx = state.app.players.items.len - 1;
    }

    if (magnet_link.len == 0) {
        logs.pushLog("error", "search", "Empty magnet link", true);
        return;
    }

    // If it's already a magnet link, use directly
    if (std.mem.startsWith(u8, magnet_link, "magnet:?")) {
        addMagnetToEngine(magnet_link);
        return;
    }

    // If it's an HTTP URL (detail page), resolve to magnet in background
    if (std.mem.startsWith(u8, magnet_link, "http://") or std.mem.startsWith(u8, magnet_link, "https://")) {
        logs.pushLog("info", "search", "Resolving detail page to magnet...", false);

        // Show loading state on the current active player. We do NOT capture the
        // *MediaPlayer pointer into the detached worker: the frame-top single-player
        // collapse / teardown can destroy() that player during the up-to-10s resolve,
        // which would make any later write a use-after-free. Instead the worker
        // re-looks-up the current active player under the bounds guard whenever it
        // needs to clear the loading flag (same semantics as addMagnetToEngine, which
        // already operates on the current active player).
        if (state.app.active_player_idx < state.app.players.items.len) {
            const p = state.app.players.items[state.app.active_player_idx];
            p.is_loading = true;
            const lbl = "Resolving magnet...";
            @memcpy(p.loading_label[0..lbl.len], lbl);
            p.loading_label_len = lbl.len;
        }

        // Copy URL for thread
        var url_copy: [4096]u8 = undefined;
        const ulen = @min(magnet_link.len, 4095);
        @memcpy(url_copy[0..ulen], magnet_link[0..ulen]);

        const ThreadContext = struct {
            url: [4096]u8,
            url_len: usize,
        };
        const ctx_store = ThreadContext{ .url = url_copy, .url_len = ulen };

        if (std.Thread.spawn(.{}, struct {
            // Clear the loading flag on the CURRENT active player via a bounds-guarded
            // re-lookup. Never deref a captured *MediaPlayer — it may have been
            // destroy()'d by teardown / single-player collapse during the resolve.
            fn clearLoading() void {
                if (state.app.active_player_idx < state.app.players.items.len) {
                    state.app.players.items[state.app.active_player_idx].is_loading = false;
                }
            }
            fn worker(ctx: ThreadContext) void {
                const alloc = @import("../core/alloc.zig").allocator;
                const u = ctx.url[0..ctx.url_len];

                // Fetch detail page with curl
                const argv = [_][]const u8{
                    "curl",       "-sL",
                    "-H",         "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
                    "--max-time", "10",
                    u,
                };
                var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
                child.stdout_behavior = .Pipe;
                child.stderr_behavior = .Ignore;
                _ = child.spawn() catch return;

                // Heap-allocate the 256KB fetch buffer: a buffer this large on a
                // spawned thread's stack would overflow the 512KB macOS thread stack.
                const html_buf = alloc.alloc(u8, 256 * 1024) catch {
                    _ = child.wait() catch {};
                    @import("../core/logs.zig").pushLog("error", "search", "Out of memory resolving magnet", true);
                    @This().clearLoading();
                    return;
                };
                defer alloc.free(html_buf);
                var total: usize = 0;
                if (child.stdout) |*so| {
                    while (total < html_buf.len) {
                        const n = @import("../core/io_global.zig").read(so, html_buf[total..]) catch break;
                        if (n == 0) break;
                        total += n;
                    }
                }
                _ = child.wait() catch {};

                if (total < 50) {
                    const logs2 = @import("../core/logs.zig");
                    logs2.pushLog("error", "search", "Failed to fetch detail page", true);
                    @This().clearLoading();
                    return;
                }

                const html = html_buf[0..total];

                // Find magnet link in HTML — try raw first, then URL-encoded
                const magnet_needle = "magnet:?";
                const encoded_needle = "magnet%3A%3F";

                if (std.mem.indexOf(u8, html, magnet_needle)) |mag_start| {
                    // Raw magnet link
                    var mag_end = mag_start;
                    while (mag_end < html.len and html[mag_end] != '"' and html[mag_end] != '\'' and html[mag_end] != ' ' and html[mag_end] != '<') {
                        mag_end += 1;
                    }
                    const resolved_magnet = html[mag_start..mag_end];
                    if (resolved_magnet.len > 20) {
                        addMagnetToEngine(resolved_magnet);
                        return;
                    }
                } else if (std.mem.indexOf(u8, html, encoded_needle)) |enc_start| {
                    // URL-encoded magnet (mylink.cloud/?url=magnet%3A%3F...)
                    var enc_end = enc_start;
                    while (enc_end < html.len and html[enc_end] != '"' and html[enc_end] != '\'' and html[enc_end] != ' ' and html[enc_end] != '<') {
                        enc_end += 1;
                    }
                    const encoded = html[enc_start..enc_end];
                    // URL-decode: replace %XX with byte
                    var decoded_buf: [4096]u8 = undefined;
                    var di: usize = 0;
                    var si: usize = 0;
                    while (si < encoded.len and di < decoded_buf.len) {
                        if (encoded[si] == '%' and si + 2 < encoded.len) {
                            const hi = hexVal(encoded[si + 1]);
                            const lo = hexVal(encoded[si + 2]);
                            if (hi != null and lo != null) {
                                decoded_buf[di] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                                di += 1;
                                si += 3;
                                continue;
                            }
                        }
                        decoded_buf[di] = encoded[si];
                        di += 1;
                        si += 1;
                    }
                    if (di > 20 and std.mem.startsWith(u8, decoded_buf[0..di], "magnet:?")) {
                        addMagnetToEngine(decoded_buf[0..di]);
                        return;
                    }
                }

                const logs2 = @import("../core/logs.zig");
                logs2.pushLog("error", "search", "No magnet found on detail page", true);
                @This().clearLoading();
            }
        }.worker, .{ctx_store})) |t| t.detach() else |_| {
            logs.pushLog("error", "search", "Failed to spawn resolver thread", true);
        }
        return;
    }

    logs.pushLog("warn", "search", "Unrecognized link format — not magnet or HTTP", true);
}

fn hexVal(ch: u8) ?u4 {
    if (ch >= '0' and ch <= '9') return @intCast(ch - '0');
    if (ch >= 'A' and ch <= 'F') return @intCast(ch - 'A' + 10);
    if (ch >= 'a' and ch <= 'f') return @intCast(ch - 'a' + 10);
    return null;
}

fn addMagnetToEngine(magnet_link: []const u8) void {
    const logs = @import("../core/logs.zig");
    const playermod = @import("../player/player.zig");

    // Auto-create a player if none exists
    if (state.app.players.items.len == 0) {
        if (playermod.MediaPlayer.init(@import("../core/alloc.zig").allocator)) |new_p| {
            state.app.players.append(@import("../core/alloc.zig").allocator, new_p) catch {
                new_p.deinit(@import("../core/alloc.zig").allocator);
                return;
            };
            state.app.active_player_idx = 0;
        } else |_| return;
    }

    if (state.app.active_player_idx >= state.app.players.items.len) {
        state.app.active_player_idx = state.app.players.items.len - 1;
    }

    var null_term_uri: [4096]u8 = undefined;
    @memset(&null_term_uri, 0);
    const copy_len = @min(magnet_link.len, 4095);
    @memcpy(null_term_uri[0..copy_len], magnet_link[0..copy_len]);

    const tid = c.mpv.torrent_add_magnet(state.app.torrent_ses, @ptrCast(&null_term_uri[0]), state.getSavePath());
    if (tid >= 0) {
        const p = state.app.players.items[state.app.active_player_idx];
        p.current_torrent_id = tid;
        p.torrent_is_ready = false;
        p.has_metadata = false;
        p.last_load_time = 0;
        p.selected_file_idx = -1;
        p.metadata_start_time = @import("../core/io_global.zig").timestamp();
        p.is_loading = true;
        p.is_torrent = true;
        const lbl = "Torrent stream";
        @memcpy(p.loading_label[0..lbl.len], lbl);
        p.loading_label_len = lbl.len;

        // Store URL for workspace persistence
        const url_len = @min(magnet_link.len, 2048);
        @memcpy(p.source_url[0..url_len], magnet_link[0..url_len]);
        p.source_url_len = url_len;
        @memcpy(p.current_url[0..url_len], magnet_link[0..url_len]);
        p.current_url_len = url_len;

        logs.pushLog("info", "search", "Torrent added, waiting for metadata...", false);

        // Reveal the player so the user sees the stream start.
        state.gotoPlayer();

        // Save magnet to download history for library persistence
        const hist = @import("history.zig");
        hist.addDownloadHistory(magnet_link[0..@min(magnet_link.len, 64)], magnet_link);
    } else {
        logs.pushLog("error", "search", "Failed to add torrent - invalid magnet or already added", true);
        state.showToast("Couldn't add torrent (invalid or duplicate magnet)");
    }
}

// ── NSFW Confirmation Modal ──
pub fn renderNsfwModal() void {
    if (!state.app.nsfw_confirm_pending) return;

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.nsfw_confirm_pending,
    }, .{
        .min_size_content = .{ .w = 400, .h = 10 },
        .color_fill = theme.colors.bg_drawer,
        .color_border = theme.colors.danger,
    });
    defer win.deinit();

    win.dragAreaSet(dvui.windowHeader("NSFW Warning", "", &state.app.nsfw_confirm_pending));

    _ = dvui.label(@src(), "NSFW Content Warning", .{}, .{
        .color_text = theme.colors.danger,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });

    _ = dvui.label(@src(), "This content may contain adult material:", .{}, .{
        .color_text = theme.colors.text_muted,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });

    const name = safeUtf8(state.app.nsfw_confirm_name_buf[0..state.app.nsfw_confirm_name_len]);
    _ = dvui.label(@src(), "{s}", .{name}, .{
        .color_text = theme.colors.warning,
        .padding = .{ .x = 0, .y = 4, .w = 0, .h = 12 },
    });

    _ = dvui.label(@src(), "Are you sure you want to load this?", .{}, .{
        .color_text = theme.colors.text_main,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 12 },
    });

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .gravity_x = 1.0,
    });
    defer btn_row.deinit();

    if (dvui.button(@src(), "Cancel", .{}, .{
        .color_fill = theme.colors.bg_glass,
        .color_text = theme.colors.text_main,
        .corner_radius = theme.dims.rad_sm,
        .margin = dvui.Rect{ .w = 8 },
    })) {
        state.app.nsfw_confirm_pending = false;
    }

    if (dvui.button(@src(), "Play Anyway", .{}, .{
        .color_fill = theme.colors.danger,
        .color_text = dvui.Color.white,
        .corner_radius = theme.dims.rad_sm,
    })) {
        const link = state.app.nsfw_confirm_link_buf[0..state.app.nsfw_confirm_link_len];
        loadTorrentToPlayer(link);
        state.app.nsfw_confirm_pending = false;
    }
}
