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
const bounded_process = @import("../core/bounded_process.zig");

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

// Memory-assisted omnibox queries may invoke an embedding backend. Keep that
// work off the render thread, publish only the newest generation, and begin the
// normal universal resolver fan-out from the UI thread in drainMemorySearch().
const MemoryQuery = struct {
    phrase: [1024]u8 = std.mem.zeroes([1024]u8),
    phrase_len: usize = 0,
    current_title: [128]u8 = std.mem.zeroes([128]u8),
    current_title_len: usize = 0,
    current_pos: f64 = 0,
    generation: u64 = 0,
};

const MemoryPublish = struct {
    query: [1024]u8 = std.mem.zeroes([1024]u8),
    query_len: usize = 0,
    generation: u64 = 0,
};

var memory_generation = std.atomic.Value(u64).init(0);
var memory_publish_lock: @import("../core/sync.zig").Mutex = .{};
var memory_publish_ready = std.atomic.Value(bool).init(false);
var memory_publish: MemoryPublish = .{};

const torrent_open_queue = @import("torrent_open_queue.zig");
var pending_torrent_lock: @import("../core/sync.zig").Mutex = .{};
var pending_torrent_ready = std.atomic.Value(bool).init(false);
var pending_torrents: torrent_open_queue.Queue = .{};

const DetailResolveStatus = enum { success, fetch_failed, no_magnet };
const DetailResolveRequest = struct {
    url: [4096]u8 = std.mem.zeroes([4096]u8),
    url_len: usize = 0,
    generation: u64 = 0,
    player_address: usize = 0,
    load_serial: u64 = 0,
};
const DetailResolvePublication = struct {
    magnet: [4096]u8 = std.mem.zeroes([4096]u8),
    magnet_len: usize = 0,
    generation: u64 = 0,
    player_address: usize = 0,
    load_serial: u64 = 0,
    status: DetailResolveStatus = .fetch_failed,
};
var detail_resolve_generation = std.atomic.Value(u64).init(0);
var detail_resolve_lock: @import("../core/sync.zig").Mutex = .{};
var detail_resolve_ready = std.atomic.Value(bool).init(false);
var detail_resolve_publication: DetailResolvePublication = .{};

fn publishDetailResolve(request: DetailResolveRequest, status: DetailResolveStatus, magnet: []const u8) void {
    if (request.generation != detail_resolve_generation.load(.acquire)) return;
    detail_resolve_lock.lock();
    defer detail_resolve_lock.unlock();
    if (request.generation != detail_resolve_generation.load(.acquire)) return;
    var publication: DetailResolvePublication = .{
        .generation = request.generation,
        .player_address = request.player_address,
        .load_serial = request.load_serial,
        .status = status,
    };
    publication.magnet_len = @min(magnet.len, publication.magnet.len);
    @memcpy(publication.magnet[0..publication.magnet_len], magnet[0..publication.magnet_len]);
    detail_resolve_publication = publication;
    detail_resolve_ready.store(true, .release);
    state.wakeUi();
}

fn resolveDetailWorker(request: DetailResolveRequest) void {
    const allocator = @import("../core/alloc.zig").allocator;
    const html_buf = allocator.alloc(u8, 256 * 1024) catch {
        publishDetailResolve(request, .fetch_failed, "");
        return;
    };
    defer allocator.free(html_buf);
    const url = request.url[0..request.url_len];
    const argv = [_][]const u8{
        "curl",       "-sL",
        "-H",         "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
        "--max-time", "10",
        url,
    };
    var process = bounded_process.StreamProcess.init(&argv, .{
        .timeout_ms = 11_000,
        .terminate_grace_ms = 150,
        .max_output_bytes = html_buf.len,
        .cancel_epoch = .{ .epoch64 = .{ .value = &detail_resolve_generation, .expected = request.generation } },
        .cancel_flag = @import("../core/workers.zig").quittingSignal(),
    });
    process.start() catch {
        publishDetailResolve(request, .fetch_failed, "");
        return;
    };
    var total: usize = 0;
    var read_failed = false;
    if (process.stdout()) |stdout| {
        while (total < html_buf.len) {
            const n = @import("../core/io_global.zig").read(stdout, html_buf[total..]) catch {
                read_failed = true;
                process.requestStop();
                break;
            };
            if (n == 0) break;
            total += n;
            if (!process.noteOutput(n)) break;
        }
        if (!read_failed and total == html_buf.len) {
            var extra: [1]u8 = undefined;
            const n = @import("../core/io_global.zig").read(stdout, &extra) catch 0;
            if (n > 0) _ = process.noteOutput(n);
        }
    }
    const outcome = process.finish();
    if (outcome.cancelled or request.generation != detail_resolve_generation.load(.acquire) or
        @import("../core/workers.zig").isQuitting()) return;
    // A page larger than the cap is deliberately terminated, but its bounded
    // prefix is still useful when it already contains the magnet link.
    if ((read_failed or (!outcome.ok() and !outcome.output_limited)) or total < 50) {
        publishDetailResolve(request, .fetch_failed, "");
        return;
    }

    const html = html_buf[0..total];
    if (std.mem.indexOf(u8, html, "magnet:?")) |start| {
        var end = start;
        while (end < html.len and html[end] != '"' and html[end] != '\'' and html[end] != ' ' and html[end] != '<') : (end += 1) {}
        if (end - start > 20) {
            publishDetailResolve(request, .success, html[start..end]);
            return;
        }
    }
    if (std.mem.indexOf(u8, html, "magnet%3A%3F")) |start| {
        var end = start;
        while (end < html.len and html[end] != '"' and html[end] != '\'' and html[end] != ' ' and html[end] != '<') : (end += 1) {}
        var decoded: [4096]u8 = undefined;
        var di: usize = 0;
        var si = start;
        while (si < end and di < decoded.len) {
            if (html[si] == '%' and si + 2 < end) {
                const hi = hexVal(html[si + 1]);
                const lo = hexVal(html[si + 2]);
                if (hi != null and lo != null) {
                    decoded[di] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                    di += 1;
                    si += 3;
                    continue;
                }
            }
            decoded[di] = html[si];
            di += 1;
            si += 1;
        }
        if (di > 20 and std.mem.startsWith(u8, decoded[0..di], "magnet:?")) {
            publishDetailResolve(request, .success, decoded[0..di]);
            return;
        }
    }
    publishDetailResolve(request, .no_magnet, "");
}

/// Apply a detail-page result only to the exact player/load that requested it.
/// Worker threads never dereference MediaPlayer or mutate navigation state.
pub fn drainResolvedTorrentDetail() void {
    if (!detail_resolve_ready.load(.acquire)) return;
    detail_resolve_lock.lock();
    if (!detail_resolve_ready.load(.acquire)) {
        detail_resolve_lock.unlock();
        return;
    }
    const publication = detail_resolve_publication;
    detail_resolve_ready.store(false, .release);
    detail_resolve_lock.unlock();
    if (publication.generation != detail_resolve_generation.load(.acquire)) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const current = state.app.players.items[state.app.active_player_idx];
    if (@intFromPtr(current) != publication.player_address or current.load_serial != publication.load_serial) return;
    if (publication.status == .success) {
        addMagnetToEngine(publication.magnet[0..publication.magnet_len]);
        return;
    }
    current.is_loading = false;
    const message = if (publication.status == .no_magnet)
        "No magnet found on detail page"
    else
        "Failed to fetch torrent detail page";
    @import("../core/logs.zig").pushLog("error", "search", message, true);
    state.showToast(message);
}

fn deferTorrentOpen(kind: torrent_open_queue.Kind, source: []const u8) bool {
    pending_torrent_lock.lock();
    const accepted = pending_torrents.push(kind, source);
    if (accepted) pending_torrent_ready.store(true, .release);
    pending_torrent_lock.unlock();
    if (!accepted) return false;
    state.wakeUi();
    return true;
}

/// Called from the UI frame after the background torrent session publishes.
/// A bounded FIFO retains every ordinary cold-start action. One item is handled
/// per frame so player/list mutation remains serialized without a long frame.
pub fn flushPendingTorrentOpen() void {
    if (state.torrentSession() == null or !pending_torrent_ready.load(.acquire)) return;

    var entry: ?torrent_open_queue.Entry = null;
    var more = false;
    pending_torrent_lock.lock();
    entry = pending_torrents.pop();
    more = pending_torrents.count > 0;
    pending_torrent_ready.store(more, .release);
    pending_torrent_lock.unlock();
    const pending = entry orelse return;

    switch (pending.kind) {
        .magnet => addMagnetToEngine(pending.slice()),
        .torrent_file => addTorrentFileToEngine(pending.slice()),
    }
    if (more) state.wakeUi();
}

// Universal-search result sort mode (Relevance / Quality / Seeds).

// Each search gets a monotonically-increasing generation. A worker only
// touches shared state (search_results, is_searching, search_thread) while it
// is still the current generation. A superseded worker that was detached writes
// nowhere and never frees buffers the new worker owns — avoids the UAF/
// double-free when triggerSearch aborts-and-respawns. (H2)
pub var search_generation = std.atomic.Value(u64).init(0);
// Set once a nova2 subprocess is successfully started. Ordinary sessions skip
// the comparatively expensive process-table sweep during shutdown.
var nova_may_exist = std.atomic.Value(bool).init(false);

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
    // 8 was `kickass`. engines/engines/kickass.py was 14 bytes containing the
    // literal text "404: Not Found" — a failed download committed as source in
    // b9c4d15. nova2 never imported it, but this enum advertised it with a
    // label and a chip colour, so the UI offered a source that could not exist.
    // The discriminant is left as a gap: values are explicit and nothing maps
    // this enum to or from an integer.
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
            .solidtorrents => "solidtorrents",
            .torrentscsv => "torrentscsv",
            .apibay => "apibay",
            .uindex => "uindex",
        };
    }
};
pub var engine_filter: EngineFilter = .all;

/// Publish a terminal search failure instead of leaving the UI's spinner
/// latched forever. Search startup used to `catch return` on allocation or
/// child-spawn errors, which made a broken Python/resource path look exactly
/// like a source with no results and gave the user no diagnostic.
fn failSearch(my_gen: u64, message: []const u8) void {
    if (search_generation.load(.acquire) != my_gen) return;
    is_searching.store(false, .release);
    @import("../core/logs.zig").pushLog("error", "search", message, true);
    state.showToast("Search failed — see Logs for details");
}

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
    // Resolve a real interpreter rather than hardcoding "python3": on Windows
    // that name is usually the Microsoft Store alias stub, which prints an
    // install prompt and exits — nova2 then produced no output and torrent
    // search silently returned nothing. pybin probes candidates and caches.
    const py = @import("../core/pybin.zig").python() orelse {
        state.showToast("Torrent search needs Python — see Settings › AI & Voice");
        @import("../core/logs.zig").pushLog("warn", "search", @import("../core/pybin.zig").missingHint(), true);
        is_searching.store(false, .release);
        return;
    };
    argv.append(allocator, py) catch {
        failSearch(my_gen, "Could not prepare Python search command");
        return;
    };
    argv.append(allocator, "engines/nova2.py") catch {
        failSearch(my_gen, "Could not prepare torrent engine path");
        return;
    };
    // Stream fast engines immediately, then stop the fan-out at a firm bound.
    // Without this, one dead scraper kept the whole search marked busy long
    // after APIBay and other API sources had already returned hundreds of rows.
    argv.append(allocator, "--timeout=6") catch {
        failSearch(my_gen, "Could not prepare torrent search deadline");
        return;
    };
    argv.append(allocator, engine_filter.pyName()) catch {
        failSearch(my_gen, "Could not prepare source filter");
        return;
    };
    argv.append(allocator, "all") catch {
        failSearch(my_gen, "Could not prepare source category");
        return;
    };
    argv.append(allocator, query) catch {
        failSearch(my_gen, "Could not prepare search query");
        return;
    };

    // Keep incremental results, but put the multi-process Python scraper under
    // a monotonic deadline and a POSIX process group / Windows Job. Advancing
    // the generation wakes a stale worker even while its pipe read is blocked.
    var process = bounded_process.StreamProcess.init(argv.items, .{
        .timeout_ms = 180 * 1000,
        .terminate_grace_ms = 500,
        .max_output_bytes = 64 * 1024 * 1024,
        .cwd = state.resourceRoot(),
        .stderr_behavior = .Inherit,
        .cancel_epoch = .{ .epoch64 = .{ .value = &search_generation, .expected = my_gen } },
        .cancel_flag = &search_abort,
    });
    process.start() catch {
        failSearch(my_gen, "Could not start Python torrent sources (check Python and the engines folder)");
        return;
    };
    nova_may_exist.store(true, .release);

    // Magnet URIs can carry a long tracker list. Real rows from the installed
    // engines exceed 1 KiB; takeDelimiter reports StreamTooLong when its
    // backing buffer cannot hold one row, and the old `catch null` then ended
    // the entire search as if the source returned EOF. Keep parity with the
    // universal resolver's generous line buffer.
    var child_reader_buf: [16 * 1024]u8 = undefined;
    var reader = process.stdout().?.reader(@import("../core/io_global.zig").io(), &child_reader_buf);

    var aborted = false;
    var stream_failed = false;
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch {
            stream_failed = true;
            process.requestStop();
            break;
        } orelse break;
        if (!process.noteOutput(line.len + 1)) {
            stream_failed = true;
            break;
        }
        if (search_abort.load(.acquire) or search_generation.load(.acquire) != my_gen) {
            aborted = true;
            process.requestStop();
            break;
        }

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
        const published_count = search_results.items.len;
        search_results_mutex.unlock();
        if (published_count == 1 or published_count % 16 == 0) state.wakeUi();
    }

    // finish() drains anything the parser left behind, reaps the leader, kills
    // lingering descendants, joins the watchdog, and closes the Job handle.
    const run = process.finish();
    const superseded = search_generation.load(.acquire) != my_gen;

    // A superseded or explicitly-aborted worker must not touch shared state any
    // further. (The guard reports cancellation even when the reader was
    // blocked and never got a chance to set the local `aborted` flag.)
    if (superseded or run.cancelled or search_abort.load(.acquire)) return;

    if (run.timed_out or run.output_limited or stream_failed) {
        search_results_mutex.lock();
        const empty = search_results.items.len == 0;
        search_results_mutex.unlock();
        if (empty) {
            failSearch(my_gen, if (run.timed_out)
                "Torrent sources exceeded their deadline"
            else if (run.output_limited)
                "Torrent sources exceeded their output budget"
            else
                "Torrent source output could not be read");
            return;
        }
    }

    if (run.term) |t| switch (t) {
        .exited => |code| if (code != 0) {
            search_results_mutex.lock();
            const empty = search_results.items.len == 0;
            search_results_mutex.unlock();
            if (empty) {
                failSearch(my_gen, "Torrent source process exited without results");
                return;
            }
        },
        else => {},
    } else if (!aborted) {
        search_results_mutex.lock();
        const empty = search_results.items.len == 0;
        search_results_mutex.unlock();
        if (empty) {
            failSearch(my_gen, "Torrent source process could not be reaped");
            return;
        }
    }

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
        state.wakeUi();
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
    // The EZTV API lists all/recent torrents (no name search); we filter
    // client-side and supplement the Python-engine results.
    // Endpoint migrated to opal-plugins — inert until the user installs "eztv".
    const api = @import("../core/source_config.zig").get("eztv", "api") orelse return;
    var url_buf: [512]u8 = undefined;
    const api_url = std.fmt.bufPrint(&url_buf, "{s}?limit=100&page=1", .{api}) catch return;

    var client = @import("../core/http.zig").newClient();
    defer client.deinit();

    const uri = std.Uri.parse(api_url) catch return;
    var req = client.request(.GET, uri, .{ .extra_headers = &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = @import("../core/app_meta.zig").user_agent },
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
    var owned: [1024]u8 = undefined;
    const n = @min(query_text.len, owned.len - 1);
    if (n == 0) return;
    // Callers may pass search_buf, the shell buffer, or resolver query storage.
    // Own the bytes before cancelling work or clearing either visible buffer.
    @memcpy(owned[0..n], query_text[0..n]);
    cancelPendingMemorySearch();
    @import("search_preview.zig").stop();
    @import("activity.zig").record(.search, owned[0..n], .{});
    setUniversalQuery(owned[0..n]);
    @import("resolver.zig").resolve(owned[0..n], "auto");
}

/// Display an already-resolved query through the same editable shell field.
pub fn setUniversalQuery(query_text: []const u8) void {
    var owned: [1024]u8 = undefined;
    const n = @min(query_text.len, owned.len - 1);
    @memcpy(owned[0..n], query_text[0..n]);
    @memset(&search_buf, 0);
    @memcpy(search_buf[0..n], owned[0..n]);
    if (state.app.page_shell_enabled) {
        @memset(&state.app.magnet_buf, 0);
        @memcpy(state.app.magnet_buf[0..n], owned[0..n]);
    }
    state.app.universal_search = true;
}

pub fn cancelPendingMemorySearch() void {
    _ = memory_generation.fetchAdd(1, .acq_rel);
    memory_publish_lock.lock();
    memory_publish_ready.store(false, .release);
    memory_publish_lock.unlock();
}

/// Unified Clear supersedes both searches and pending memory publication.
pub fn clearShellSearch() void {
    @import("search_preview.zig").stop();
    cancelPendingMemorySearch();
    search_abort.store(true, .release);
    _ = search_generation.fetchAdd(1, .acq_rel);
    if (search_thread) |thread| @import("../core/workers.zig").release(thread);
    search_thread = null;
    is_searching.store(false, .release);
    @memset(&search_buf, 0);
    @memset(&state.app.magnet_buf, 0);
    clearResults();
    @import("resolver.zig").clearResults();
    search_page = 0;
    view_dirty = true;
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
    const trimmed = std.mem.trim(u8, phrase, " \t\r\n");
    if (trimmed.len == 0) return;

    const allocator = @import("../core/alloc.zig").allocator;
    const query = allocator.create(MemoryQuery) catch {
        submitQuery(trimmed);
        return;
    };
    query.* = .{};
    query.generation = memory_generation.fetchAdd(1, .acq_rel) + 1;
    query.phrase_len = @min(trimmed.len, query.phrase.len - 1);
    @memcpy(query.phrase[0..query.phrase_len], trimmed[0..query.phrase_len]);

    // Snapshot player context on the UI thread; the worker never walks the
    // mutable player list or calls libmpv.
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        query.current_pos = @max(0, p.last_seen_pos);
        if (p.loading_label_len > 0 and p.loading_label_len <= p.loading_label.len) {
            query.current_title_len = @min(p.loading_label_len, query.current_title.len);
            @memcpy(query.current_title[0..query.current_title_len], p.loading_label[0..query.current_title_len]);
        }
    }

    state.showToast("Searching your memory…");
    @import("../core/workers.zig").spawn(memorySearchWorker, .{query}) catch {
        allocator.destroy(query);
        submitQuery(trimmed);
    };
}

fn memorySearchWorker(query: *MemoryQuery) void {
    const allocator = @import("../core/alloc.zig").allocator;
    defer allocator.destroy(query);

    const ai_memory = @import("ai_memory.zig");
    const db = @import("../core/db.zig");
    const phrase = query.phrase[0..query.phrase_len];

    // Embed the phrase; a null embedding makes retrieveScene use its keyword/LIKE
    // fallback (also spoiler-clamped). Either path is safe.
    var floats: [ai_memory.EMBED_DIM]f32 = undefined;
    const ok = ai_memory.getEmbedding(phrase, &floats);

    // Nearest scene memory (spoiler clamp reused from db.retrieveScene — not
    // reimplemented here).
    const hit = db.retrieveScene(
        if (ok) floats[0..] else null,
        phrase,
        query.current_title[0..query.current_title_len],
        query.current_pos,
    );

    if (memory_generation.load(.acquire) != query.generation or
        @import("../core/workers.zig").isQuitting()) return;

    const selected = if (hit) |h| blk: {
        const seed = h.title[0..h.title_len];
        break :blk if (seed.len > 0) seed else phrase;
    } else phrase;

    memory_publish_lock.lock();
    if (memory_generation.load(.acquire) == query.generation) {
        memory_publish.query_len = @min(selected.len, memory_publish.query.len - 1);
        @memset(&memory_publish.query, 0);
        @memcpy(memory_publish.query[0..memory_publish.query_len], selected[0..memory_publish.query_len]);
        memory_publish.generation = query.generation;
        memory_publish_ready.store(true, .release);
    }
    memory_publish_lock.unlock();
    state.wakeUi();
}

/// UI-thread publication seam for memorySearchWorker. Stale generations are
/// discarded; the current one fans into the ordinary deterministic search.
pub fn drainMemorySearch() void {
    if (!memory_publish_ready.load(.acquire)) return;
    var local: [1024]u8 = undefined;
    var len: usize = 0;
    var generation: u64 = 0;
    memory_publish_lock.lock();
    if (memory_publish_ready.load(.acquire)) {
        len = memory_publish.query_len;
        @memcpy(local[0..len], memory_publish.query[0..len]);
        generation = memory_publish.generation;
        memory_publish_ready.store(false, .release);
    }
    memory_publish_lock.unlock();
    if (len == 0 or generation != memory_generation.load(.acquire)) return;
    submitQuery(local[0..len]);
}

/// Shutdown sweep: reap any lingering `engines/nova2.py` torrent-search
/// subprocesses. The normal path already drains + waits the current search child
/// (appDeinit joins search_thread → asyncSearchTask's `child.wait()`), but a
/// SUPERSEDED search that was detached mid-flight (see triggerSearch) can outlive
/// a graceful exit and orphan its multiprocessing pool. Sweep those on teardown.
/// (A SIGKILL of Opal itself is inherently unreapable — this only helps clean
/// exit; mirrors the sidecar reaping in dev.sh / suwayomi_server.)
pub fn reapWorkers() void {
    // No OS guard: killByCommandLine is portable now, so Windows reaps its
    // nova2 workers too instead of orphaning a python process per search.
    @import("../core/io_global.zig").killByCommandLine("engines/nova2.py", false);
}

/// Cancel and reap all search work before the global worker barrier. Waiting
/// first would deadlock shutdown behind a child process that has not yet been
/// told to exit.
pub fn shutdown() void {
    @import("search_preview.zig").stop();
    search_abort.store(true, .release);
    _ = search_generation.fetchAdd(1, .acq_rel);
    if (nova_may_exist.load(.acquire)) reapWorkers();
    if (search_thread) |t| t.join();
    search_thread = null;
    is_searching.store(false, .release);
    if (view_cache.rows) |rows| @import("../core/alloc.zig").allocator.free(rows);
    view_cache.rows = null;
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
        if (search_thread) |t| @import("../core/workers.zig").release(t);
        search_thread = null;
        is_searching.store(false, .release);
    }

    search_abort.store(false, .release);

    // Pre-warm the anti-detect browser, non-blocking.
    //
    // Walled engines (1337x, uindex) reach it through /api/scrape, but the
    // bridge takes ~20s to boot and fetchHtmlBlocking gives up waiting after
    // that — so the FIRST walled search after launch was a guaranteed miss, and
    // only the retry returned rows. Starting it here means it is coming up while
    // the engines are still fetching, and it is already warm (~2s per scrape) by
    // the time one of them is actually blocked.
    //
    // Gated on the user having opted into browser-backed scraping AND having an
    // engine installed, so this never spawns a ~200 MB browser for someone who
    // does not use it. ensureBridge() is itself a no-op once running.
    if (state.app.scrape_use_browser) {
        const browser = @import("browser.zig");
        if (browser.engineReady(browser.active_engine)) browser.ensureBridge();
    }

    history.addSearchHistory(query_text);
    const query = @import("../core/alloc.zig").allocator.dupe(u8, query_text) catch return;
    search_thread = @import("../core/workers.zig").spawnLegacy(asyncSearchTask, .{ query, new_gen }) catch {
        @import("../core/alloc.zig").allocator.free(query);
        return;
    };
    search_page = 0;
}

const search_view = @import("search_view_pure.zig");
var view_filters: search_view.Filters = .{};
var view_sort: search_view.Sort = .relevance;
var filters_open = false;
var sources_open = false;
var view_dirty = true;
var result_scroll: dvui.ScrollInfo = .{};
var result_keyboard_layout = false;

/// One search entry, shared with the shell: opening targets never depend on an
/// existing player and query text is owned before any visible input is cleared.
fn submitSearchInput(raw: []const u8) void {
    const routing = @import("browser_pure.zig");
    var input: [1024]u8 = undefined;
    const text = std.mem.trim(u8, raw, " \t\r\n");
    const n = @min(text.len, input.len);
    @memcpy(input[0..n], text[0..n]);
    const copied = input[0..n];
    switch (routing.classifyOmnibox(copied)) {
        .empty => {},
        .open => {
            var target_buf: [2048]u8 = undefined;
            const target = routing.resolveOpenTarget(copied, &target_buf);
            @import("browser.zig").loadContent(target);
        },
        .memory => memorySearch(std.mem.trimStart(u8, copied[1..], " \t")),
        .assistant, .search => if (memory_mode) memorySearch(copied) else submitQuery(copied),
    }
}

pub fn renderSearchContent() void {
    state.app.universal_search = true; // compatibility with saved sessions/API
    if (!state.app.page_shell_enabled) {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .padding = .{ .x = theme.spacing.sm, .y = 4, .w = theme.spacing.sm, .h = 4 },
        });
        defer bar.deinit();
        var input_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .max_size_content = .{ .w = 0, .h = 36 },
            .min_size_content = .{ .w = 0, .h = 36 },
            .gravity_y = 0.5,
        });
        var opts = theme.optInput();
        opts.color_fill = theme.transparent;
        opts.color_border = theme.transparent;
        opts.border = dvui.Rect.all(0);
        opts.expand = .horizontal;
        opts.max_size_content = .{ .w = 0, .h = 36 };
        opts.padding = .{ .x = theme.spacing.sm, .y = 5, .w = 0, .h = 5 };
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &search_buf }, .placeholder = "Search media, paste a link, or ask ? from memory" }, opts);
        const enter = te.enter_pressed;
        var submitted: [1024]u8 = undefined;
        const len = @min(te.textGet().len, submitted.len);
        @memcpy(submitted[0..len], te.textGet()[0..len]);
        te.deinit();
        const clicked = dvui.buttonIcon(@src(), "Search", icons.tvg.lucide.search, .{}, .{}, .{
            .color_fill = theme.transparent,
            .color_text = theme.colors.accent,
            .border = dvui.Rect.all(0),
            .gravity_y = 0.5,
            .padding = dvui.Rect.all(theme.spacing.xs),
        });
        if ((len > 0 or view_cache.query_len > 0 or view_cache.loaded > 0) and searchButton(91001, "Clear", false)) {
            clearShellSearch();
        }
        input_row.deinit();
        if (enter or clicked) submitSearchInput(submitted[0..len]);
        renderShellSearchControls(false);
    }
    refreshSearchView();
    if (filters_open) renderSearchFilters();
    renderActiveSearchFilters();
    renderUniversalResults();
}

/// Search contributes controls to the existing single shell row, never a second
/// query field. Dense mode uses bounded icons; popup choices remain named.
pub fn renderShellSearchControls(dense: bool) void {
    refreshSearchView();
    var label_buf: [48]u8 = undefined;
    const count = search_view.activeCount(view_filters);
    const label = if (count > 0) std.fmt.bufPrint(&label_buf, "Filters ({d})", .{count}) catch "Filters" else "Filters";
    var tip_buf: [64]u8 = undefined;
    const filters_tip = std.fmt.bufPrint(&tip_buf, "Filters ({d} active)", .{count}) catch "Filters";
    const filters_clicked = if (dense) searchIconButton(91002, icons.tvg.lucide.@"sliders-horizontal", filters_tip, filters_open or count > 0) else searchButton(91002, label, filters_open);
    if (filters_clicked) filters_open = !filters_open;
    if (searchSelectImpl(91300, &SORT_LABELS, @intFromEnum(view_sort), dense)) |choice| {
        view_sort = @enumFromInt(choice);
        view_dirty = true;
    }
    if (view_cache.loading) {
        const cancel_clicked = if (dense) searchIconButton(91303, icons.tvg.lucide.x, "Cancel search", false) else searchButton(91303, "Cancel", false);
        if (cancel_clicked) {
            cancelPendingMemorySearch();
            @import("resolver.zig").cancel();
        }
    } else if (view_cache.query_len > 0 and view_cache.loaded == 0) {
        const retry_clicked = if (dense) searchIconButton(91304, icons.tvg.lucide.@"rotate-ccw", "Retry search", false) else searchButton(91304, "Retry", false);
        if (retry_clicked) submitQuery(view_cache.query[0..view_cache.query_len]);
    }
}

/// A 26-point target keeps three dense controls within 78 points before shell gaps.
fn searchIconButton(id: usize, icon: []const u8, tooltip: []const u8, active: bool) bool {
    var data: dvui.WidgetData = undefined;
    const clicked = dvui.buttonIcon(@src(), tooltip, icon, .{}, .{}, .{
        .id_extra = id,
        .data_out = &data,
        .color_fill = if (active) theme.colors.bg_elevated else theme.transparent,
        .color_fill_hover = theme.colors.bg_hover,
        .color_fill_press = theme.colors.bg_elevated,
        .color_text = if (active) theme.colors.accent else theme.colors.text_secondary,
        .border = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .corner_radius = theme.dims.rad_sm,
        .min_size_content = .{ .w = 16, .h = 16 },
        .max_size_content = .{ .w = 16, .h = 16 },
        .padding = dvui.Rect.all(5),
        .gravity_y = 0.5,
    });
    components.tip(@src(), data, tooltip);
    return clicked;
}

fn searchButton(id: usize, label: []const u8, active: bool) bool {
    return dvui.button(@src(), label, .{}, .{
        .id_extra = id,
        .color_fill = if (active) theme.colors.bg_elevated else theme.transparent,
        .color_fill_hover = theme.colors.bg_hover,
        .color_fill_press = theme.colors.bg_elevated,
        .color_text = if (active) theme.colors.accent else theme.colors.text_secondary,
        .border = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = theme.spacing.sm, .y = 6, .w = theme.spacing.sm, .h = 6 },
        .gravity_y = 0.5,
    });
}

/// Explicitly themed popup, avoiding the default dropdown menu palette.
fn searchSelect(id: usize, labels: []const []const u8, selected: usize) ?usize {
    return searchSelectImpl(id, labels, selected, false);
}

fn searchSelectImpl(id: usize, labels: []const []const u8, selected: usize, icon_only: bool) ?usize {
    var menu = dvui.menu(@src(), .horizontal, .{ .id_extra = id, .color_fill = theme.transparent, .gravity_y = 0.5 });
    defer menu.deinit();
    const current_label = labels[@min(selected, labels.len - 1)];
    var data: dvui.WidgetData = undefined;
    const trigger = if (icon_only) dvui.menuItemIcon(@src(), current_label, icons.tvg.lucide.@"arrow-down-wide-narrow", .{ .submenu = true }, .{
        .id_extra = id,
        .data_out = &data,
        .color_fill = theme.transparent,
        .color_fill_hover = theme.colors.bg_hover,
        .color_fill_press = theme.colors.bg_elevated,
        .color_text = theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .min_size_content = .{ .w = 16, .h = 16 },
        .max_size_content = .{ .w = 16, .h = 16 },
        .padding = dvui.Rect.all(5),
    }) else dvui.menuItemLabel(@src(), current_label, .{ .submenu = true }, .{
        .id_extra = id,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .color_fill_hover = theme.colors.bg_hover,
        .color_fill_press = theme.colors.bg_surface,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = theme.spacing.sm, .y = 6, .w = theme.spacing.sm, .h = 6 },
    });
    if (icon_only) components.tip(@src(), data, current_label);
    if (trigger) |rect| {
        var popup = dvui.floatingMenu(@src(), .{ .from = rect }, .{ .id_extra = id, .color_fill = theme.colors.bg_surface, .color_border = theme.colors.border_subtle });
        defer popup.deinit();
        var choices = dvui.menu(@src(), .vertical, .{ .id_extra = id, .background = true, .color_fill = theme.colors.bg_surface, .color_border = theme.colors.border_subtle, .border = dvui.Rect.all(1) });
        defer choices.deinit();
        for (labels, 0..) |label, i| {
            if (dvui.menuItemLabel(@src(), label, .{}, .{ .id_extra = i, .expand = .horizontal, .color_text = if (i == selected) theme.colors.accent else theme.colors.text_primary, .color_fill_hover = theme.colors.bg_hover })) |_| {
                popup.close();
                return i;
            }
        }
    }
    return null;
}

const CONTENT_LABELS = [_][]const u8{ "All content", "Video", "Movies", "Shows", "Anime", "Comics", "Books", "Music", "Podcasts", "Radio", "Live TV", "Visual novels" };
const AVAILABILITY_LABELS = [_][]const u8{ "All availability", "Playable", "Torrents", "Library" };
const SORT_LABELS = [_][]const u8{ "Sort: relevance", "Sort: quality", "Sort: seeds", "Sort: size", "Sort: peers", "Sort: health" };
const QUALITY_LABELS = [_][]const u8{ "Any quality", "480p+", "720p+", "1080p+", "4K" };
const SEED_VALUES = [_]u16{ 0, 1, 5, 10, 20, 50, 100 };
const SEED_LABELS = [_][]const u8{ "Any seeds", "1+ seeds", "5+ seeds", "10+ seeds", "20+ seeds", "50+ seeds", "100+ seeds" };
const SIZE_LABELS = [_][]const u8{ "Any size", "Under 1 GB", "1–5 GB", "5–20 GB", "20 GB+" };
var size_choice: usize = 0;

fn renderSearchFilters() void {
    var panel = dvui.flexbox(@src(), .{}, .{ .expand = .horizontal, .background = true, .color_fill = theme.colors.bg_surface, .padding = dvui.Rect.all(theme.spacing.sm) });
    if (searchSelect(91100, &CONTENT_LABELS, @intFromEnum(view_filters.content))) |v| {
        view_filters.content = @enumFromInt(v);
        view_dirty = true;
    }
    if (searchSelect(91101, &AVAILABILITY_LABELS, @intFromEnum(view_filters.availability))) |v| {
        view_filters.availability = @enumFromInt(v);
        view_dirty = true;
    }
    if (searchSelect(91102, &QUALITY_LABELS, view_filters.min_quality)) |v| {
        view_filters.min_quality = @intCast(v);
        view_dirty = true;
    }
    var seeds_choice: usize = 0;
    for (SEED_VALUES, 0..) |value, i| if (value == view_filters.min_seeds) {
        seeds_choice = i;
    };
    if (searchSelect(91103, &SEED_LABELS, seeds_choice)) |v| {
        view_filters.min_seeds = SEED_VALUES[v];
        view_dirty = true;
    }
    if (searchSelect(91104, &SIZE_LABELS, size_choice)) |v| {
        size_choice = v;
        const gb: u64 = 1024 * 1024 * 1024;
        view_filters.min_size_bytes = switch (v) {
            2 => gb,
            3 => 5 * gb,
            4 => 20 * gb,
            else => 0,
        };
        view_filters.max_size_bytes = switch (v) {
            1 => gb - 1,
            2 => 5 * gb - 1,
            3 => 20 * gb - 1,
            else => 0,
        };
        view_dirty = true;
    }
    renderProviderFacet();
    panel.deinit();
    if (searchButton(91301, "Sources", sources_open)) sources_open = !sources_open;
    if (sources_open) renderSearchSources();
}

fn filterChip(id: usize, text: []const u8) bool {
    var label: [120]u8 = undefined;
    return searchButton(id, std.fmt.bufPrint(&label, "{s} ×", .{text}) catch text, true);
}

fn renderActiveSearchFilters() void {
    if (search_view.activeCount(view_filters) == 0) return;
    var chips = dvui.flexbox(@src(), .{}, .{ .expand = .horizontal, .padding = .{ .x = theme.spacing.sm, .y = 2, .w = theme.spacing.sm, .h = 2 } });
    defer chips.deinit();
    if (view_filters.content != .all and filterChip(91200, CONTENT_LABELS[@intFromEnum(view_filters.content)])) {
        view_filters.content = .all;
        view_dirty = true;
    }
    if (view_filters.availability != .all and filterChip(91201, AVAILABILITY_LABELS[@intFromEnum(view_filters.availability)])) {
        view_filters.availability = .all;
        view_dirty = true;
    }
    if (view_filters.min_quality > 0 and filterChip(91202, QUALITY_LABELS[view_filters.min_quality])) {
        view_filters.min_quality = 0;
        view_dirty = true;
    }
    if (view_filters.min_seeds > 0) {
        var label: [40]u8 = undefined;
        if (filterChip(91203, std.fmt.bufPrint(&label, "{d}+ seeds", .{view_filters.min_seeds}) catch "Seeds")) {
            view_filters.min_seeds = 0;
            view_dirty = true;
        }
    }
    if (size_choice > 0 and filterChip(91204, SIZE_LABELS[size_choice])) {
        size_choice = 0;
        view_filters.min_size_bytes = 0;
        view_filters.max_size_bytes = 0;
        view_dirty = true;
    }
    if (view_filters.provider) |provider| if (filterChip(91205, provider.name())) {
        view_filters.provider = null;
        view_dirty = true;
    };
    if (searchButton(91206, "Clear filters", false)) {
        view_filters = .{};
        size_choice = 0;
        view_dirty = true;
    }
}

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
    _ = dvui.label(@src(), "Search", .{}, .{ .color_text = theme.colors.text_primary, .font = dvui.themeGet().font_title, .gravity_x = 0.5 });
    _ = dvui.label(@src(), "Search across your libraries and enabled sources.", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_x = 0.5 });

    const Src = struct { icon: []const u8, name: []const u8 };
    const sources = [_]Src{
        .{ .icon = icons.tvg.lucide.@"hard-drive", .name = "On disk" },
        .{ .icon = icons.tvg.lucide.magnet, .name = "Torrents" },
        .{ .icon = icons.tvg.lucide.server, .name = "Jellyfin" },
        .{ .icon = icons.tvg.lucide.youtube, .name = "YouTube" },
        .{ .icon = icons.tvg.lucide.tv, .name = "Anime" },
        .{ .icon = icons.tvg.lucide.image, .name = "Comics" },
        .{ .icon = icons.tvg.lucide.clapperboard, .name = "Stremio" },
        .{ .icon = icons.tvg.lucide.rss, .name = "RSS" },
        .{ .icon = icons.tvg.lucide.book, .name = "Books & audiobooks" },
        .{ .icon = icons.tvg.lucide.headphones, .name = "Music & podcasts" },
        .{ .icon = icons.tvg.lucide.radio, .name = "Radio & live TV" },
        .{ .icon = icons.tvg.lucide.server, .name = "Plex & connected catalogs" },
        .{ .icon = icons.tvg.lucide.book, .name = "Visual novels" },
    };
    var flow = dvui.flexbox(@src(), .{ .justify_content = .center }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = 0 } });
    defer flow.deinit();
    for (sources, 0..) |s, i| {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 9700,
            .background = true,
            .color_fill = theme.colors.bg_surface,
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
/// Source FILTER pills for the toolbar — always visible in universal mode.
/// Each pill is a toggle: click to exclude/include that source from the next
/// search (disabled sources aren't even spawned) AND from the visible result
/// groups. While a search runs, the pill tint doubles as live status
/// (accent = searching, green = done, red = failed); disabled pills are
/// dimmed. A spinner + live count leads the cluster while resolving.
fn renderSourceStatusCluster() void {
    const resolver = @import("resolver.zig");
    _ = dvui.label(@src(), "Enabled sources run on your next search. Result filters only change this view.", .{}, .{ .color_text = theme.colors.text_secondary, .padding = dvui.Rect.all(theme.spacing.sm) });
    const Row = struct { icon: []const u8, name: []const u8, bit: resolver.SourceBit, st: resolver.SourceStatus };
    const rows = [_]Row{
        .{ .icon = icons.tvg.lucide.@"hard-drive", .name = "On disk", .bit = .local, .st = resolver.status_local.load(.acquire) },
        .{ .icon = icons.tvg.lucide.magnet, .name = "Torrents", .bit = .torrent, .st = combinedTorrentStatus() },
        .{ .icon = icons.tvg.lucide.server, .name = "Jellyfin", .bit = .jellyfin, .st = resolver.status_jf.load(.acquire) },
        .{ .icon = icons.tvg.lucide.youtube, .name = "YouTube", .bit = .youtube, .st = resolver.status_yt.load(.acquire) },
        .{ .icon = icons.tvg.lucide.tv, .name = "Anime", .bit = .anime, .st = resolver.combineSourceStatuses(resolver.status_anime.load(.acquire), resolver.status_anime_catalog.load(.acquire)) },
        .{ .icon = icons.tvg.lucide.image, .name = "Comics", .bit = .comics, .st = resolver.combineSourceStatuses(resolver.status_comics.load(.acquire), resolver.status_manga_catalog.load(.acquire)) },
        .{ .icon = icons.tvg.lucide.clapperboard, .name = "Streams", .bit = .stremio, .st = combinedStreamStatus() },
        .{ .icon = icons.tvg.lucide.rss, .name = "RSS", .bit = .rss, .st = resolver.status_rss.load(.acquire) },
        .{ .icon = icons.tvg.lucide.tv, .name = "Live TV", .bit = .livetv, .st = resolver.status_livetv.load(.acquire) },
        .{ .icon = icons.tvg.lucide.music, .name = "Music", .bit = .music, .st = resolver.status_music.load(.acquire) },
        .{ .icon = icons.tvg.lucide.radio, .name = "Radio", .bit = .radio, .st = resolver.status_radio.load(.acquire) },
        .{ .icon = icons.tvg.lucide.podcast, .name = "Podcasts", .bit = .podcast, .st = resolver.status_podcast.load(.acquire) },
        .{ .icon = icons.tvg.lucide.book, .name = "Novels", .bit = .novels, .st = resolver.combineSourceStatuses(resolver.combineSourceStatuses(resolver.status_novels.load(.acquire), resolver.status_novel_archive.load(.acquire)), resolver.status_public_books.load(.acquire)) },
        .{ .icon = icons.tvg.lucide.book, .name = "Visual novels", .bit = .vndb, .st = resolver.status_vndb.load(.acquire) },
        .{ .icon = icons.tvg.lucide.headphones, .name = "Audiobooks", .bit = .audiobooks, .st = resolver.status_audiobooks.load(.acquire) },
        .{ .icon = icons.tvg.lucide.book, .name = "OPDS", .bit = .opds, .st = resolver.status_opds.load(.acquire) },
    };
    var source_list = dvui.flexbox(@src(), .{}, .{ .expand = .horizontal, .padding = dvui.Rect.all(theme.spacing.sm) });
    defer source_list.deinit();
    for (rows, 0..) |r, i| {
        const enabled = resolver.sourceOn(r.bit);
        const state_name: []const u8 = switch (r.st) {
            .searching => "searching",
            .done => "done",
            .no_results => "no results",
            .unavailable => "unavailable",
            .partial => "partial results",
            .failed => "failed",
            .transport_failed => "network error",
            .parse_failed => "invalid response",
            .timed_out => "timed out",
            .idle => "ready",
        };
        var label: [112]u8 = undefined;
        const title = std.fmt.bufPrint(&label, "{s} · {s} · {s}", .{ r.name, if (enabled) "enabled" else "disabled", state_name }) catch r.name;
        if (searchButton(9220 + i, title, enabled)) {
            resolver.toggleSource(r.bit);
            state.markConfigDirty();
        }
    }
    if (searchButton(9250, "Configure sources", false)) state.navigateToTab(.Plugins);
}

/// Torrent sources span two backends (nova2, YTS) — show one chip: searching if
/// either is still going, failed only if both failed, else done.
///
/// A third backend (a native 1337x scraper) used to be counted here. It could
/// never report .failed — it returned early on a source id that never matched —
/// so the `and`-chain below could never reach .failed either, and a total
/// torrent-search failure still rendered as "done". Removing it fixes that.
fn combinedTorrentStatus() @import("resolver.zig").SourceStatus {
    const r = @import("resolver.zig");
    const statuses = [_]r.SourceStatus{
        r.status_torrent.load(.acquire),
        r.status_yts.load(.acquire),
        r.status_torznab.load(.acquire),
        r.status_eztv.load(.acquire),
    };
    return r.combineManySourceStatuses(&statuses);
}

fn combinedStreamStatus() @import("resolver.zig").SourceStatus {
    const r = @import("resolver.zig");
    const statuses = [_]r.SourceStatus{
        r.status_stremio.load(.acquire),
        r.status_archive.load(.acquire),
        r.status_nasa.load(.acquire),
        r.status_commons.load(.acquire),
    };
    return r.combineManySourceStatuses(&statuses);
}

const ResultAction = struct {
    idx: usize,
    queue: bool = false,
};

const ViewCache = struct {
    rows: ?[]@import("resolver.zig").ResolvedItem = null,
    projected: [@import("resolver.zig").MAX_RESULTS]search_view.Item = @splat(.{}),
    order: [@import("resolver.zig").MAX_RESULTS]usize = @splat(0),
    count: usize = 0,
    loaded: usize = 0,
    revision: u64 = std.math.maxInt(u64),
    generation: u32 = 0,
    query: [256]u8 = @splat(0),
    query_len: usize = 0,
    loading: bool = false,
    nsfw: bool = false,
};
var view_cache: ViewCache = .{};

/// Copy once per publication revision. No network, GPU, or DVUI operations are
/// performed while the resolver's lifecycle/results locks are held.
fn refreshSearchView() void {
    const resolver = @import("resolver.zig");
    if (view_cache.rows == null) view_cache.rows = @import("../core/alloc.zig").allocator.alloc(resolver.ResolvedItem, resolver.MAX_RESULTS) catch return;
    const snap = resolver.copySearchSnapshot(view_cache.rows.?, view_cache.revision);
    const query_changed = !std.mem.eql(u8, view_cache.query[0..view_cache.query_len], snap.query[0..snap.query_len]);
    view_cache.loading = snap.loading;
    view_cache.query = snap.query;
    view_cache.query_len = snap.query_len;
    const generation_changed = view_cache.generation != snap.generation;
    if (!snap.changed and !view_dirty and view_cache.nsfw == state.app.nsfw_filter_enabled and !generation_changed) return;
    view_cache.revision = snap.revision;
    view_cache.generation = snap.generation;
    view_cache.loaded = snap.count;
    view_cache.nsfw = state.app.nsfw_filter_enabled;
    view_cache.count = 0;
    for (view_cache.rows.?[0..snap.count], 0..) |*item, i| {
        view_cache.projected[i] = resolver.searchView(item);
        if (item.name_len == 0 or (view_cache.nsfw and item.is_nsfw)) continue;
        if (!search_view.matches(view_cache.projected[i], view_filters)) continue;
        view_cache.order[view_cache.count] = i;
        view_cache.count += 1;
    }
    const Compare = struct {
        fn less(_: void, a: usize, b: usize) bool {
            return search_view.lessThan(view_sort, view_cache.projected[a], view_cache.projected[b]);
        }
    };
    std.sort.insertion(usize, view_cache.order[0..view_cache.count], {}, Compare.less);
    if (query_changed) result_scroll.viewport.y = 0;
    view_dirty = false;
}

fn renderProviderFacet() void {
    var providers: [@import("resolver.zig").MAX_RESULTS + 1]search_view.Provider = undefined;
    var labels: [@import("resolver.zig").MAX_RESULTS + 2][]const u8 = undefined;
    labels[0] = "All providers";
    var count: usize = 0;
    var selected: usize = 0;
    for (view_cache.projected[0..view_cache.loaded]) |projected| {
        const provider = projected.provider;
        if (provider.len == 0) continue;
        var duplicate = false;
        for (providers[0..count]) |present| if (search_view.Provider.eql(present, provider)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        providers[count] = provider;
        labels[count + 1] = providers[count].name();
        if (view_filters.provider) |current| if (search_view.Provider.eql(current, provider)) {
            selected = count + 1;
        };
        count += 1;
    }
    if (view_filters.provider) |provider| {
        if (selected == 0) {
            providers[count] = provider;
            labels[count + 1] = providers[count].name();
            selected = count + 1;
            count += 1;
        }
    }
    if (searchSelect(91105, labels[0 .. count + 1], selected)) |choice| {
        view_filters.provider = if (choice == 0) null else providers[choice - 1];
        view_dirty = true;
    }
}

fn renderSearchSources() void {
    const resolver = @import("resolver.zig");
    renderSourceStatusCluster();
    var source_has = std.EnumSet(resolver.SourceBit).initEmpty();
    if (view_cache.rows) |rows| for (rows[0..view_cache.loaded]) |*item| {
        if (sourceBitOf(item)) |bit| source_has.insert(bit);
    };
    renderSourceSummary(source_has);
    if (view_cache.query_len > 0 and searchButton(91302, "Retry search", false)) resolver.resolve(view_cache.query[0..view_cache.query_len], "auto");
}

fn renderUniversalResults() void {
    const resolver = @import("resolver.zig");
    // Facet changes from this frame update counts and rows together.
    if (view_dirty) refreshSearchView();
    if (view_cache.rows == null or view_cache.loaded == 0 or view_cache.count == 0) @import("search_preview.zig").stop();
    if (view_cache.rows != null) ensureContentProjection();
    if (view_cache.query_len > 0 or view_cache.loaded > 0) {
        var titles: usize = 0;
        var releases: usize = 0;
        for (content_projection.groups[0..content_projection.count]) |*group| {
            if (!galleryGroupVisible(group)) continue;
            if (group.category == .releases) releases += 1 else titles += 1;
        }
        var count_buf: [128]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d} titles · {d} other releases{s}", .{ titles, releases, if (view_cache.loading) " · searching…" else "" }) catch "Results";
        _ = dvui.label(@src(), "{s}", .{count}, .{ .color_text = theme.colors.text_secondary, .padding = dvui.Rect.all(theme.spacing.sm) });
    }
    if (view_cache.rows == null) {
        components.emptyState(icons.tvg.lucide.@"search-x", "Search could not allocate its result view", "Try again after closing unused players.");
        return;
    }
    if (view_cache.loaded == 0) {
        if (view_cache.loading) components.loadingState("Searching your enabled sources…") else if (view_cache.query_len > 0) components.emptyState(icons.tvg.lucide.@"search-x", "No matches", "Try a broader query or open Filters → Sources to check provider status.") else renderUniversalCapabilities();
        return;
    }
    if (view_cache.count == 0) {
        components.emptyState(icons.tvg.lucide.@"search-x", "No matches for these filters", "Remove a filter to see more of the loaded results.");
        return;
    }
    var pending: ?ResultAction = null;
    renderContentGallery(&pending);
    if (pending) |action| {
        // The selected row is owned by this frame's immutable snapshot.
        const item = &view_cache.rows.?[action.idx];
        if (action.queue) {
            if (!resolver.isRemoteQueueable(item)) {
                state.showToastTyped("This result cannot be queued. Open it to resolve a usable torrent.", .err);
                return;
            }
            const risk = @import("torrent_risk_pure.zig").assess(item.name[0..item.name_len], @floatFromInt(item.size_bytes));
            if (risk.risk == .block) {
                var text: [160]u8 = undefined;
                state.showToastTyped(std.fmt.bufPrint(&text, "Blocked scam torrent: {s}", .{risk.reason}) catch "Blocked scam torrent", .err);
            } else {
                @import("queue.zig").addToQueue(item.url[0..item.url_len], item.name[0..item.name_len], "torrent");
                state.showToast("Added to queue");
            }
        } else resolver.playResolvedItem(item);
    }
}

const search_content = @import("search_content_pure.zig");
const gallery_layout = @import("../ui/search_gallery_pure.zig");
var content_projection: search_content.Projection = .{};
var gallery_selection: u64 = 0;
var gallery_selected_manually = false;
var gallery_generation: u32 = 0;
var gallery_show_sources = false;
var gallery_release_limit: usize = 12;
const GalleryCover = struct { identity: u64 = 0, used: u64 = 0, slot: components.CoverSlot = .{} };
// Stable addresses: poster workers publish into these slots. Never move or
// recycle a slot while its worker is fetching.
var gallery_covers: [196]GalleryCover = @splat(.{});
var gallery_cover_clock: u64 = 0;
var gallery_backdrop: components.CoverSlot = .{};

fn galleryCover(identity: u64) ?*components.CoverSlot {
    gallery_cover_clock +%= 1;
    var oldest: ?usize = null;
    for (&gallery_covers, 0..) |*entry, index| {
        if (entry.identity == identity) {
            entry.used = gallery_cover_clock;
            return &entry.slot;
        }
        if (!entry.slot.fetching and (oldest == null or entry.used < gallery_covers[oldest.?].used)) oldest = index;
    }
    if (oldest) |index| {
        const entry = &gallery_covers[index];
        entry.slot.reset();
        entry.identity = identity;
        entry.used = gallery_cover_clock;
        return &entry.slot;
    }
    return null;
}

/// Called after the owned-worker barrier, while the graphics context exists.
pub fn deinitGallery() void {
    for (&gallery_covers) |*entry| entry.slot.reset();
    gallery_backdrop.reset();
    @import("search_preview.zig").deinit();
}

pub fn updateGalleryRoute() void {
    if (state.app.router.current != .search) @import("search_preview.zig").stop();
}

/// Native test harness only: immutable provider fixtures, no resolver network.
pub fn setGalleryFixtureForTest(rows: []const @import("resolver.zig").ResolvedItem, query: []const u8) void {
    if (!@import("builtin").is_test) @compileError("gallery fixture API is test-only");
    const resolver = @import("resolver.zig");
    if (view_cache.rows == null) view_cache.rows = @import("../core/alloc.zig").allocator.alloc(resolver.ResolvedItem, resolver.MAX_RESULTS) catch return;
    view_cache.loaded = @min(rows.len, resolver.MAX_RESULTS);
    view_cache.count = view_cache.loaded;
    @memcpy(view_cache.rows.?[0..view_cache.loaded], rows[0..view_cache.loaded]);
    for (rows[0..view_cache.loaded], 0..) |*item, index| {
        view_cache.projected[index] = resolver.searchView(item);
        view_cache.order[index] = index;
    }
    view_cache.query_len = @min(query.len, view_cache.query.len);
    @memcpy(view_cache.query[0..view_cache.query_len], query[0..view_cache.query_len]);
    view_cache.loading = false;
    view_cache.nsfw = false;
    view_cache.revision +%= 1;
    view_cache.generation +%= 1;
    view_filters = .{};
    view_sort = .relevance;
    view_dirty = false;
    state.app.router.current = .search;
    result_scroll.viewport.y = 0;
}
pub fn setGalleryTextureForTest(identity: u64, url: []const u8, texture: dvui.Texture, width: u32, height: u32) void {
    if (!@import("builtin").is_test) @compileError("gallery texture API is test-only");
    const slot = galleryCover(identity) orelse return;
    components.syncCoverSlot(slot, url);
    slot.tex = texture;
    slot.w = width;
    slot.h = height;
    slot.attempted = true;
}
pub fn setGalleryContentFilterForTest(filter: search_view.ContentKind) void {
    if (!@import("builtin").is_test) @compileError("gallery filter API is test-only");
    view_filters.content = filter;
    view_dirty = false;
}
pub fn renderGalleryForTest() void {
    if (!@import("builtin").is_test) @compileError("gallery renderer API is test-only");
    renderUniversalResults();
}

fn galleryCategoryLabel(category: search_content.Category) []const u8 {
    return switch (category) {
        .movies => "Movies",
        .shows => "Shows",
        .anime => "Anime",
        .comics => "Comics & manga",
        .books => "Books & audiobooks",
        .music => "Music",
        .podcasts => "Podcasts",
        .radio => "Radio",
        .live_tv => "Live TV",
        .visual_novels => "Visual novels",
        .videos => "Videos",
        .releases => "Other releases",
    };
}
fn galleryCategoryFilter(category: search_content.Category) search_view.ContentKind {
    return switch (category) {
        .movies => .movies,
        .shows => .shows,
        .anime => .anime,
        .comics => .comics,
        .books => .books,
        .music => .music,
        .podcasts => .podcasts,
        .radio => .radio,
        .live_tv => .live_tv,
        .visual_novels => .visual_novels,
        .videos, .releases => .video,
    };
}
fn galleryShape(category: search_content.Category) gallery_layout.Shape {
    return switch (category) {
        .movies, .shows, .anime, .comics, .books, .visual_novels => .portrait,
        .music, .podcasts, .radio => .square,
        .videos, .live_tv, .releases => .landscape,
    };
}
fn galleryIcon(category: search_content.Category) []const u8 {
    return switch (category) {
        .books, .comics, .visual_novels => icons.tvg.lucide.book,
        .music, .podcasts => icons.tvg.lucide.headphones,
        .radio => icons.tvg.lucide.radio,
        .releases => icons.tvg.lucide.magnet,
        else => icons.tvg.lucide.film,
    };
}
fn galleryGroupVisible(group: *const search_content.Group) bool {
    for (group.indexes[0..group.count]) |index| if (search_view.matches(view_cache.projected[index], view_filters)) return true;
    return false;
}

fn ensureContentProjection() void {
    const rows = view_cache.rows.?[0..view_cache.loaded];
    var indexes: [@import("resolver.zig").MAX_RESULTS]usize = undefined;
    var count: usize = 0;
    for (rows, 0..) |item, index| {
        if (item.name_len == 0 or (view_cache.nsfw and item.is_nsfw)) continue;
        indexes[count] = index;
        count += 1;
    }
    // Projection is rebuilt only when the immutable row revision/filter changes.
    const ProjectionCache = struct {
        var revision: u64 = std.math.maxInt(u64);
        var generation: u32 = 0;
        var nsfw = false;
    };
    if (ProjectionCache.revision != view_cache.revision or ProjectionCache.generation != view_cache.generation or ProjectionCache.nsfw != view_cache.nsfw) {
        search_content.projectInto(rows, indexes[0..count], &content_projection);
        ProjectionCache.revision = view_cache.revision;
        ProjectionCache.generation = view_cache.generation;
        ProjectionCache.nsfw = view_cache.nsfw;
    }
}

fn renderContentGallery(pending: *?ResultAction) void {
    const rows = view_cache.rows.?[0..view_cache.loaded];
    ensureContentProjection();
    if (gallery_generation != view_cache.generation) {
        gallery_selection = 0;
        gallery_selected_manually = false;
        gallery_show_sources = false;
        gallery_release_limit = 12;
        gallery_generation = view_cache.generation;
        @import("search_preview.zig").stop();
    }
    var visible: [search_content.MAX_ROWS]usize = undefined;
    var identities: [search_content.MAX_ROWS]u64 = undefined;
    var visible_count: usize = 0;
    for (content_projection.groups[0..content_projection.count], 0..) |*group, index| {
        if (!galleryGroupVisible(group)) continue;
        visible[visible_count] = index;
        identities[visible_count] = group.identity;
        visible_count += 1;
    }
    std.sort.insertion(usize, visible[0..visible_count], {}, struct {
        fn less(_: void, a: usize, b: usize) bool {
            return search_view.lessThan(view_sort, view_cache.projected[content_projection.groups[a].representative], view_cache.projected[content_projection.groups[b].representative]);
        }
    }.less);
    for (visible[0..visible_count], 0..) |index, position| identities[position] = content_projection.groups[index].identity;
    const selected_position = gallery_layout.retainSelection(identities[0..visible_count], gallery_selection) orelse {
        @import("search_preview.zig").stop();
        return;
    };
    const selected = &content_projection.groups[visible[selected_position]];
    gallery_selection = selected.identity;
    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &result_scroll }, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_app });
    defer scroll.deinit();
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(theme.spacing.md) });
    defer content.deinit();
    const width = content.data().contentRect().w;
    // A raw release has no dependable feature artwork. It stays in the compact
    // source comparison until a matching catalog or library record arrives.
    const featured_item = &rows[selected.representative];
    if (selected.category != .releases and gallery_layout.shouldFeature(view_cache.query[0..view_cache.query_len], featured_item.name[0..featured_item.name_len], featured_item.poster_url_len > 0 or featured_item.backdrop_url_len > 0, gallery_selected_manually)) renderGalleryHero(selected, width, pending) else @import("search_preview.zig").stop();
    if (gallery_show_sources) {
        renderResultGroupHeading("Available sources", 94500);
        var source_indexes: [search_content.MAX_ROWS]u16 = undefined;
        @memcpy(source_indexes[0..selected.count], selected.indexes[0..selected.count]);
        std.sort.insertion(u16, source_indexes[0..selected.count], {}, struct {
            fn less(_: void, a: u16, b: u16) bool {
                return search_view.lessThan(view_sort, view_cache.projected[a], view_cache.projected[b]);
            }
        }.less);
        for (source_indexes[0..selected.count]) |index| {
            if (rows[index].source == .tmdb and selected.count > 1) continue;
            renderCompactRow(index, &rows[index], pending);
        }
    }
    inline for (std.meta.tags(search_content.Category)) |category| {
        var category_count: usize = 0;
        for (visible[0..visible_count]) |index| if (content_projection.groups[index].category == category) {
            category_count += 1;
        };
        if (category_count > 0) {
            var heading = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 94600 + @as(usize, @intFromEnum(category)), .expand = .horizontal, .padding = .{ .x = 0, .y = 16, .w = 0, .h = 8 } });
            _ = dvui.label(@src(), "{s}", .{galleryCategoryLabel(category)}, .{ .font = dvui.themeGet().font_heading, .color_text = theme.colors.text_primary, .gravity_y = 0.5 });
            var tally: [32]u8 = undefined;
            const tally_text = std.fmt.bufPrint(&tally, "{d}", .{category_count}) catch "";
            _ = dvui.label(@src(), "{s}", .{tally_text}, .{ .color_text = theme.colors.text_tertiary, .gravity_y = 0.5, .margin = dvui.Rect.all(6) });
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
            if (category != .releases and view_filters.content == .all and components.actionButton(@src(), "See all", .secondary, 94650 + @as(usize, @intFromEnum(category)))) {
                view_filters.content = galleryCategoryFilter(category);
                view_dirty = true;
                result_scroll.viewport.y = 0;
            }
            heading.deinit();
            if (category == .releases) {
                var shown: usize = 0;
                for (visible[0..visible_count]) |index| {
                    const group = &content_projection.groups[index];
                    if (group.category != category or shown >= gallery_release_limit) continue;
                    renderCompactRow(group.representative, &rows[group.representative], pending);
                    shown += 1;
                }
                if (shown < category_count and components.actionButton(@src(), "Show more releases", .secondary, 94700)) gallery_release_limit += 24;
            } else {
                const art = gallery_layout.cardSize(galleryShape(category), width);
                if (view_filters.content != .all) {
                    var grid = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .id_extra = 94950 + @as(usize, @intFromEnum(category)), .expand = .horizontal });
                    for (visible[0..visible_count]) |index| {
                        const group = &content_projection.groups[index];
                        if (group.category == category) renderGalleryCard(group, if (rows[group.representative].source == .audiobooks) gallery_layout.cardSize(.square, width) else art);
                    }
                    grid.deinit();
                } else {
                    const rail_height = gallery_layout.shelfHeight(art.h, dvui.themeGet().font_body.textHeight());
                    var rail = dvui.scrollArea(@src(), .{ .horizontal = .auto, .horizontal_bar = .auto_overlay, .vertical = .none }, .{ .id_extra = 94800 + @as(usize, @intFromEnum(category)), .expand = .horizontal, .min_size_content = .{ .w = 1, .h = rail_height }, .max_size_content = .{ .w = std.math.floatMax(f32), .h = rail_height }, .background = false, .color_fill = theme.transparent });
                    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 94900 + @as(usize, @intFromEnum(category)) });
                    for (visible[0..visible_count]) |index| {
                        const group = &content_projection.groups[index];
                        if (group.category == category) renderGalleryCard(group, if (rows[group.representative].source == .audiobooks) gallery_layout.cardSize(.square, width) else art);
                    }
                    strip.deinit();
                    rail.deinit();
                }
            }
        }
    }
}

fn renderGalleryCard(group: *const search_content.Group, size: gallery_layout.Size) void {
    const item = &view_cache.rows.?[group.representative];
    const key: usize = @truncate(group.identity);
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = key, .min_size_content = .{ .w = size.w, .h = 0 }, .max_size_content = .{ .w = size.w, .h = std.math.floatMax(f32) }, .margin = .{ .x = 0, .y = 0, .w = 12, .h = if (view_filters.content == .all) 0 else 16 }, .background = false, .color_fill = theme.transparent });
    defer card.deinit();
    var art = dvui.overlay(@src(), .{ .id_extra = key +% 1, .min_size_content = .{ .w = size.w, .h = size.h }, .max_size_content = .{ .w = size.w, .h = size.h }, .background = true, .color_fill = theme.colors.bg_surface, .corner_radius = dvui.Rect.all(theme.radius.md), .border = dvui.Rect.all(if (gallery_selection == group.identity) 2 else 0), .color_border = theme.colors.accent });
    if (art.data().visible()) {
        if (galleryCover(group.identity)) |slot| components.galleryCoverArt(@src(), key +% 2, slot, item.poster_url[0..item.poster_url_len], galleryIcon(group.category), theme.radius.md, size.w, size.h);
    }
    var hovered = false;
    if (dvui.clicked(art.data(), .{ .hovered = &hovered })) {
        gallery_selection = group.identity;
        gallery_selected_manually = true;
        gallery_show_sources = false;
        result_scroll.viewport.y = 0;
    }
    art.deinit();
    const body = dvui.themeGet().font_body;
    var title: [520]u8 = undefined;
    _ = dvui.label(@src(), "{s}", .{searchRowTitle(item.name[0..item.name_len], body, size.w, &title)}, .{ .id_extra = key +% 3, .font = body, .color_text = theme.colors.text_primary, .min_size_content = .{ .w = size.w, .h = body.textHeight() * 2 }, .max_size_content = .{ .w = size.w, .h = body.textHeight() * 2 }, .margin = .{ .x = 0, .y = 7, .w = 0, .h = 0 } });
    var metadata: [128]u8 = undefined;
    const line = if (group.offer_count > 0) std.fmt.bufPrint(&metadata, "{d} source{s}", .{ group.offer_count, if (group.offer_count == 1) "" else "s" }) catch "" else if (item.author_len > 0) item.author[0..item.author_len] else item.detail[0..item.detail_len];
    searchRowLine(key +% 4, safeUtf8(line), body.withSize(theme.font_size.small), size.w, theme.colors.text_secondary);
    if (components.actionButton(@src(), "Details", .secondary, key +% 5)) {
        gallery_selection = group.identity;
        gallery_selected_manually = true;
        gallery_show_sources = false;
        result_scroll.viewport.y = 0;
    }
    components.tipId(@src(), card.data().*, safeUtf8(item.name[0..item.name_len]), key);
    renderSearchResultContext(key, card.data().borderRectScale().r, item);
}

fn renderGalleryHero(group: *const search_content.Group, width: f32, pending: *?ResultAction) void {
    const item = &view_cache.rows.?[group.representative];
    const key: usize = @truncate(group.identity);
    var hero = dvui.box(@src(), .{ .dir = if (gallery_layout.stackedHero(width)) .vertical else .horizontal }, .{ .id_extra = 95000, .expand = .horizontal, .background = true, .color_fill = theme.colors.bg_surface, .corner_radius = dvui.Rect.all(theme.radius.lg), .padding = dvui.Rect.all(12), .margin = .{ .x = 0, .y = 0, .w = 0, .h = 12 } });
    defer hero.deinit();
    const preview = @import("search_preview.zig");
    if (item.source == .tmdb and item.catalog_id > 0) {
        preview.select(group.identity, if (std.mem.eql(u8, item.catalog_kind[0..item.catalog_kind_len], "tv")) .tv else .movie, item.catalog_id);
    } else preview.stop();
    preview.poll();
    const preview_state = preview.snapshot();
    const has_preview_backdrop = preview_state.identity == group.identity and preview_state.metadata.backdrop_url_len > 0;
    const has_backdrop = item.backdrop_url_len > 0 or has_preview_backdrop;
    const preview_active = preview_state.status == .playing or preview_state.status == .starting;
    const art_size = gallery_layout.heroArtSize(width, has_backdrop or preview_active);
    var art = dvui.overlay(@src(), .{ .id_extra = key +% 8, .min_size_content = .{ .w = art_size.w, .h = art_size.h }, .max_size_content = .{ .w = art_size.w, .h = art_size.h }, .color_fill = theme.colors.bg_elevated, .background = true, .corner_radius = dvui.Rect.all(theme.radius.md), .margin = .{ .x = 0, .y = 0, .w = 20, .h = 0 } });
    if (preview_active) {
        if (art.data().visible()) preview.render(@src(), key +% 9, art_size.w, art_size.h);
    } else if (has_backdrop) {
        const backdrop = if (item.backdrop_url_len > 0) item.backdrop_url[0..item.backdrop_url_len] else preview_state.metadata.backdrop_url[0..preview_state.metadata.backdrop_url_len];
        components.galleryCoverArt(@src(), key +% 9, &gallery_backdrop, backdrop, galleryIcon(group.category), theme.radius.md, art_size.w, art_size.h);
    } else if (galleryCover(group.identity)) |slot| components.galleryCoverArt(@src(), key +% 9, slot, item.poster_url[0..item.poster_url_len], galleryIcon(group.category), theme.radius.md, art_size.w, art_size.h);
    art.deinit();
    var copy = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = 95001, .expand = .horizontal, .gravity_y = gallery_layout.heroCopyGravity(width), .padding = dvui.Rect.all(4) });
    defer copy.deinit();
    _ = dvui.label(@src(), "{s}", .{galleryCategoryLabel(group.category)}, .{ .color_text = theme.colors.accent, .font = dvui.themeGet().font_body.withSize(theme.font_size.small) });
    const copy_width = @max(1, copy.data().contentRect().w);
    const heading = dvui.themeGet().font_title.withSize(if (width < 760) 26 else 34);
    var title: [520]u8 = undefined;
    _ = dvui.label(@src(), "{s}", .{searchRowTitle(item.name[0..item.name_len], heading, copy_width, &title)}, .{ .id_extra = 95002, .color_text = theme.colors.text_primary, .font = heading, .max_size_content = .{ .w = copy_width, .h = heading.textHeight() * 2 }, .margin = .{ .x = 0, .y = 4, .w = 0, .h = 8 } });
    searchRowLine(95003, safeUtf8(item.detail[0..item.detail_len]), dvui.themeGet().font_body.withSize(theme.font_size.small), copy_width, theme.colors.text_secondary);
    if (item.summary_len > 0) {
        var summary = dvui.textLayout(@src(), .{ .break_lines = true }, .{ .id_extra = 95004, .expand = .horizontal, .background = false, .color_fill = theme.transparent, .max_size_content = .{ .w = copy_width, .h = dvui.themeGet().font_body.textHeight() * 4 }, .margin = .{ .x = 0, .y = 10, .w = 0, .h = 12 } });
        summary.addText(safeUtf8(item.summary[0..item.summary_len]), .{ .color_text = theme.colors.text_secondary });
        summary.deinit();
    }
    var actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .id_extra = 95005, .expand = .horizontal });
    const television = item.source == .tmdb and std.mem.eql(u8, item.catalog_kind[0..item.catalog_kind_len], "tv");
    if (item.source != .tmdb or television) {
        if (components.actionButton(@src(), if (television) "Episodes" else "Open", .primary, 95006)) pending.* = .{ .idx = group.representative };
    }
    if (group.offer_count > 0) {
        var source_text: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&source_text, "Sources ({d})", .{group.offer_count}) catch "Sources";
        if (components.actionButton(@src(), text, .secondary, 95007)) gallery_show_sources = !gallery_show_sources;
    }
    const store = @import("library_store.zig");
    var identity: [32]u8 = undefined;
    const identity_text = std.fmt.bufPrint(&identity, "{x}", .{group.identity}) catch "";
    const saved = store.isFavorite("search", identity_text);
    if (components.actionButton(@src(), if (saved) "Saved" else "Save", .secondary, 95008)) {
        var saved_link: [288]u8 = undefined;
        const reopen = std.fmt.bufPrint(&saved_link, "opal://search/{s}", .{item.name[0..item.name_len]}) catch "";
        store.setFavorite("search", identity_text, !saved, item.name[0..item.name_len], item.poster_url[0..item.poster_url_len], reopen);
        state.showToast(if (saved) "Removed from saved content" else "Saved to your library");
    }
    if (preview_state.canStart()) {
        if (components.actionButton(@src(), "Preview", .secondary, 95009)) _ = preview.start();
    }
    if (preview_active) {
        if (components.actionButton(@src(), if (preview_state.muted) "Unmute" else "Mute", .secondary, 95010)) preview.setMuted(!preview_state.muted);
        if (components.actionButton(@src(), "Close preview", .secondary, 95011)) preview.closePlayback();
    }
    actions.deinit();
    if (item.source == .tmdb and preview_state.status != .idle) searchRowLine(95012, preview_state.label(), dvui.themeGet().font_body.withSize(theme.font_size.small), copy_width, theme.colors.text_tertiary);
}

fn showResult(item: *const @import("resolver.zig").ResolvedItem) bool {
    const resolver = @import("resolver.zig");
    if (item.name_len == 0 or (state.app.nsfw_filter_enabled and item.is_nsfw)) return false;
    if (sourceBitOf(item)) |bit| return resolver.sourceOn(bit);
    return true;
}

fn isPreviewResult(item: *const @import("resolver.zig").ResolvedItem) bool {
    return item.source == .youtube and @import("search_meta_pure.zig").isPreviewTitle(item.name[0..item.name_len]);
}

fn renderResultGroupHeading(text: []const u8, id_extra: usize) void {
    var heading = dvui.textLayout(@src(), .{ .break_lines = true }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 0 },
        .background = false,
        .padding = .{ .x = 20, .y = 12, .w = 12, .h = 6 },
    });
    heading.addText(text, .{ .color_text = theme.colors.text_secondary, .font = dvui.themeGet().font_heading });
    heading.deinit();
}

/// Toolbar filter pill governing a result (RSS magnets are pushed with
/// source=.torrent, split from real torrents by their detail prefix).
fn sourceBitOf(item: *const @import("resolver.zig").ResolvedItem) ?@import("resolver.zig").SourceBit {
    return switch (item.source) {
        .torrent => if (std.mem.startsWith(u8, item.detail[0..item.detail_len], "RSS")) .rss else .torrent,
        .jellyfin => .jellyfin,
        .anime => .anime,
        .youtube => .youtube,
        .comics => .comics,
        .stremio => .stremio,
        .local => .local,
        // Catalog rows are always-on discovery results, not a playable-source
        // backend. They must not disappear with the Torrents pill or make the
        // no-hit summary claim that a torrent provider returned something.
        .tmdb => null,
        .plex => null,
        .plugin => null,
        .livetv => .livetv,
        .music => .music,
        .radio => .radio,
        .podcast => .podcast,
        .novels => .novels,
        .vndb => .vndb,
        .audiobooks => .audiobooks,
        .opds => .opds,
    };
}

/// One muted line summarizing sources that finished (or failed) with no
/// matches — replaces the old full-height "No results from X" sections.
/// `source_has` is the per-source hit bitset built during the result loop
/// (renderUniversalResults) so this doesn't re-scan the array each repaint.
/// Draws caller-owned snapshot data after the resolver locks are released.
fn renderSourceSummary(source_has: std.EnumSet(@import("resolver.zig").SourceBit)) void {
    const resolver = @import("resolver.zig");
    const Entry = struct {
        name: []const u8,
        src: resolver.SourceType,
        rss: bool,
        st: resolver.SourceStatus,
        bit: resolver.SourceBit,
    };
    const entries = [_]Entry{
        .{ .name = "Torrents", .src = .torrent, .rss = false, .st = combinedTorrentStatus(), .bit = .torrent },
        .{ .name = "Jellyfin", .src = .jellyfin, .rss = false, .st = resolver.status_jf.load(.acquire), .bit = .jellyfin },
        .{ .name = "Anime", .src = .anime, .rss = false, .st = resolver.combineSourceStatuses(resolver.status_anime.load(.acquire), resolver.status_anime_catalog.load(.acquire)), .bit = .anime },
        .{ .name = "YouTube", .src = .youtube, .rss = false, .st = resolver.status_yt.load(.acquire), .bit = .youtube },
        .{ .name = "Comics", .src = .comics, .rss = false, .st = resolver.combineSourceStatuses(resolver.status_comics.load(.acquire), resolver.status_manga_catalog.load(.acquire)), .bit = .comics },
        .{ .name = "Streams", .src = .stremio, .rss = false, .st = combinedStreamStatus(), .bit = .stremio },
        .{ .name = "RSS", .src = .torrent, .rss = true, .st = resolver.status_rss.load(.acquire), .bit = .rss },
        .{ .name = "On-disk", .src = .local, .rss = false, .st = resolver.status_local.load(.acquire), .bit = .local },
        .{ .name = "Live TV", .src = .livetv, .rss = false, .st = resolver.status_livetv.load(.acquire), .bit = .livetv },
        .{ .name = "Music", .src = .music, .rss = false, .st = resolver.status_music.load(.acquire), .bit = .music },
        .{ .name = "Radio", .src = .radio, .rss = false, .st = resolver.status_radio.load(.acquire), .bit = .radio },
        .{ .name = "Podcasts", .src = .podcast, .rss = false, .st = resolver.status_podcast.load(.acquire), .bit = .podcast },
        .{ .name = "Novels", .src = .novels, .rss = false, .st = resolver.combineSourceStatuses(resolver.combineSourceStatuses(resolver.status_novels.load(.acquire), resolver.status_novel_archive.load(.acquire)), resolver.status_public_books.load(.acquire)), .bit = .novels },
        .{ .name = "Visual novels", .src = .vndb, .rss = false, .st = resolver.status_vndb.load(.acquire), .bit = .vndb },
        .{ .name = "Audiobooks", .src = .audiobooks, .rss = false, .st = resolver.status_audiobooks.load(.acquire), .bit = .audiobooks },
        .{ .name = "OPDS", .src = .opds, .rss = false, .st = resolver.status_opds.load(.acquire), .bit = .opds },
    };

    const appendName = struct {
        fn f(buf: []u8, w: *usize, s: []const u8) void {
            if (w.* > 0) {
                const sep = ", ";
                const n0 = @min(sep.len, buf.len - w.*);
                @memcpy(buf[w.*..][0..n0], sep[0..n0]);
                w.* += n0;
            }
            const n = @min(s.len, buf.len - w.*);
            @memcpy(buf[w.*..][0..n], s[0..n]);
            w.* += n;
        }
    }.f;

    const appendGroup = struct {
        fn raw(buf: []u8, w: *usize, text: []const u8) void {
            if (w.* >= buf.len) return;
            const n = @min(text.len, buf.len - w.*);
            @memcpy(buf[w.*..][0..n], text[0..n]);
            w.* += n;
        }

        fn f(buf: []u8, w: *usize, label: []const u8, names: []const u8) void {
            if (names.len == 0) return;
            if (w.* > 0) raw(buf, w, "  ·  ");
            raw(buf, w, label);
            raw(buf, w, ": ");
            raw(buf, w, names);
        }
    }.f;

    var quiet_buf: [160]u8 = undefined;
    var qw: usize = 0;
    var unavailable_buf: [160]u8 = undefined;
    var uw: usize = 0;
    var partial_buf: [160]u8 = undefined;
    var pw: usize = 0;
    var failed_buf: [160]u8 = undefined;
    var fw: usize = 0;

    for (entries) |en| {
        if (!resolver.sourceOn(en.bit)) continue;
        if (en.st == .searching) continue;
        if (source_has.contains(en.bit)) continue;
        if (resolver.sourceStatusIsFailure(en.st)) {
            appendName(&failed_buf, &fw, en.name);
        } else switch (en.st) {
            .unavailable => appendName(&unavailable_buf, &uw, en.name),
            .partial => appendName(&partial_buf, &pw, en.name),
            .idle, .done, .no_results => appendName(&quiet_buf, &qw, en.name),
            .searching, .failed, .transport_failed, .parse_failed, .timed_out => unreachable,
        }
    }

    if (qw == 0 and uw == 0 and pw == 0 and fw == 0) return;

    var line_buf: [704]u8 = undefined;
    var line_len: usize = 0;
    appendGroup(&line_buf, &line_len, "No hits", quiet_buf[0..qw]);
    appendGroup(&line_buf, &line_len, "Unavailable", unavailable_buf[0..uw]);
    appendGroup(&line_buf, &line_len, "Partial", partial_buf[0..pw]);
    appendGroup(&line_buf, &line_len, "Failed", failed_buf[0..fw]);
    const line = line_buf[0..line_len];

    _ = dvui.label(@src(), "{s}", .{line}, .{
        .id_extra = 12900,
        .color_text = if (fw > 0)
            theme.colors.danger
        else if (pw > 0 or uw > 0)
            theme.colors.warning
        else
            theme.colors.text_tertiary,
        .padding = .{ .x = 14, .y = 8, .w = 12, .h = 6 },
    });

    // Fresh-install / post-reset state: Opal ships NEUTRAL — zero source
    // plugins installed means every torrent/comics/anime engine silently ran
    // as a no-op above. A bare "No hits" here reads as a broken search (it
    // cost a real debugging session); say why and offer the one-click fix.
    if (!@import("../core/source_config.zig").anyInstalled()) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 12901,
            .padding = .{ .x = 14, .y = 0, .w = 12, .h = 6 },
        });
        defer row.deinit();
        _ = dvui.label(@src(), "No source plugins installed — searches can't return torrents yet.", .{}, .{
            .id_extra = 12902,
            .color_text = theme.colors.warning,
            .gravity_y = 0.5,
        });
        if (dvui.button(@src(), "Open Plugins", .{}, .{
            .id_extra = 12903,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
            .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
        })) {
            state.navigateToTab(.Plugins);
        }
    }
}

/// A result row with a wrapping title and one metadata line beside its actions.
/// Whole row clicks to play; source, play and queue remain visible.
/// Draws caller-owned snapshot data after the resolver locks are released.
/// Two title lines, one precise metadata line and one real synopsis preview.
/// Every row has the same font-derived height for viewport virtualization.
fn searchRowTitle(text: []const u8, font: dvui.Font, width: f32, out: []u8) []const u8 {
    var normalized: [1024]u8 = undefined;
    var rest = std.mem.trim(u8, search_view.singleLine(&normalized, text), " \t\r\n");
    var written: usize = 0;
    for (0..2) |line| {
        if (rest.len == 0) break;
        var end: usize = 0;
        const reserve = if (line == 1) font.textSizeEx("…", .{}).w else 0;
        _ = font.textSizeEx(rest, .{ .max_width = @max(1, width - reserve), .end_idx = &end });
        if (end == 0) break;
        if (end < rest.len) if (std.mem.lastIndexOfScalar(u8, rest[0..end], ' ')) |space| {
            if (space > 0) end = space;
        };
        const piece = std.mem.trim(u8, rest[0..end], " \t\r\n");
        if (written + piece.len + 4 > out.len) break;
        @memcpy(out[written..][0..piece.len], piece);
        written += piece.len;
        rest = std.mem.trimStart(u8, rest[end..], " \t\r\n");
        if (rest.len > 0) {
            if (line == 1) {
                @memcpy(out[written..][0..3], "…");
                written += 3;
            } else {
                out[written] = '\n';
                written += 1;
            }
        }
    }
    return out[0..written];
}

fn searchRowLine(id: usize, text: []const u8, font: dvui.Font, width: f32, color: dvui.Color) void {
    var normalized: [1024]u8 = undefined;
    const clean = search_view.singleLine(&normalized, text);
    var end: usize = clean.len;
    if (font.textSizeEx(clean, .{}).w > width) _ = font.textSizeEx(clean, .{ .max_width = @max(1, width - font.textSizeEx("…", .{}).w), .end_idx = &end });
    var line: [1024]u8 = undefined;
    const clipped = @import("../ui/footer_pure.zig").compactTitle(&line, clean, end);
    _ = dvui.label(@src(), "{s}", .{clipped}, .{ .id_extra = id, .font = font, .color_text = color, .max_size_content = .{ .w = @max(0, width), .h = font.textHeight() } });
}

fn renderCompactRow(idx: usize, item: *const @import("resolver.zig").ResolvedItem, pending: *?ResultAction) void {
    const resolver = @import("resolver.zig");
    const row_key: usize = @truncate(resolver.actionKey(item));
    const risk = if (item.source == .torrent) @import("torrent_risk_pure.zig").assess(item.name[0..item.name_len], @floatFromInt(item.size_bytes)) else @import("torrent_risk_pure.zig").Assessment{};
    const chip_text = switch (item.source) {
        .jellyfin => "Jellyfin",
        .stremio => "Stream",
        .torrent => "Torrent",
        .anime => "Anime",
        .youtube => if (isPreviewResult(item)) "Trailer · YouTube" else "YouTube",
        .local => "On disk",
        .tmdb => "Catalog",
        .plex => "Plex",
        .plugin => "Plugin",
        .comics => "Comics",
        .livetv => "Live TV",
        .music => "Music",
        .radio => "Radio",
        .podcast => "Podcast",
        .novels => "Novel",
        .vndb => "Visual novel",
        .audiobooks => "Audiobook",
        .opds => "OPDS",
    };
    const body = dvui.themeGet().font_body;
    const small = body.withSize(theme.font_size.small);
    const row_height = body.textHeight() * 3 + 14 + (if (risk.risk != .ok) small.textHeight() else @as(f32, 0));
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = row_key,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.transparent,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .min_size_content = .{ .w = 0, .h = row_height - 13 },
        .max_size_content = .{ .w = 0, .h = row_height - 13 },
        .padding = .{ .x = theme.spacing.sm, .y = 6, .w = theme.spacing.sm, .h = 6 },
    });
    defer row.deinit();
    if (row.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt)) row.data().options.color_fill = theme.colors.bg_hover;
    row.drawBackground();
    const queueable = item.source == .torrent and resolver.isRemoteQueueable(item);
    const actions_width: f32 = if (queueable) 72 else 36;
    const text_width = @max(0, row.data().contentRect().w - actions_width - theme.spacing.sm);
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .max_size_content = .{ .w = 0, .h = row_height - 13 } });
    var title_buffer: [520]u8 = undefined;
    const title = searchRowTitle(item.name[0..item.name_len], body, text_width, &title_buffer);
    _ = dvui.label(@src(), "{s}", .{title}, .{ .id_extra = row_key +% 1, .font = body, .color_text = theme.colors.text_primary, .max_size_content = .{ .w = text_width, .h = body.textHeight() * 2 } });
    const meta_pure = @import("search_meta_pure.zig");
    var meta_buffer: [64]u8 = undefined;
    const meta = meta_pure.metaLine(.{ .quality = item.quality, .size_bytes = item.size_bytes, .seeds = item.seeds, .leech = item.leech }, &meta_buffer);
    var line: [512]u8 = undefined;
    const provider = if (item.provider.len > 0) item.provider.name() else "Provider unknown";
    const metadata = if (item.source == .torrent)
        std.fmt.bufPrint(&line, "{s} · {s}{s}{s}", .{ chip_text, provider, if (meta.len > 0) " · " else "", meta }) catch chip_text
    else
        std.fmt.bufPrint(&line, "{s}{s}{s}{s}{s}", .{ chip_text, if (meta.len > 0) " · " else "", meta, if (item.detail_len > 0) " · " else "", safeUtf8(item.detail[0..item.detail_len]) }) catch chip_text;
    searchRowLine(row_key +% 2, metadata, small, text_width, theme.colors.text_secondary);
    if (risk.risk != .ok) searchRowLine(row_key +% 3, if (risk.risk == .block) "Scam? · blocked torrent" else "Caution · check torrent details", small, text_width, if (risk.risk == .block) theme.colors.danger else theme.colors.warning);
    content.deinit();
    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
    defer actions.deinit();
    const action_icon = if (item.source == .anime or item.source == .podcast) icons.tvg.lucide.@"arrow-up-right" else if (item.source == .novels or item.source == .comics or item.source == .opds) icons.tvg.lucide.book else if (item.source == .vndb or item.source == .tmdb or item.source == .audiobooks) icons.tvg.lucide.info else icons.tvg.lucide.play;
    const action_name = if (item.source == .anime or item.source == .podcast) "Open" else if (item.source == .novels or item.source == .comics or item.source == .opds) "read" else if (item.source == .audiobooks) "open audio" else if (item.source == .vndb or item.source == .tmdb) "details" else "play";
    var button_data: dvui.WidgetData = undefined;
    if (dvui.buttonIcon(@src(), action_name, action_icon, .{}, .{}, .{ .id_extra = row_key +% 4, .data_out = &button_data, .color_fill = theme.transparent, .color_fill_hover = theme.colors.bg_hover, .color_text = if (risk.risk == .block) theme.colors.text_tertiary else theme.colors.accent, .border = dvui.Rect.all(0), .padding = dvui.Rect.all(8), .min_size_content = .{ .w = 16, .h = 16 } })) pending.* = .{ .idx = idx };
    components.tip(@src(), button_data, action_name);
    if (queueable) {
        if (dvui.buttonIcon(@src(), "queue", icons.tvg.lucide.plus, .{}, .{}, .{ .id_extra = row_key +% 5, .data_out = &button_data, .color_fill = theme.transparent, .color_fill_hover = theme.colors.bg_hover, .color_text = theme.colors.text_secondary, .border = dvui.Rect.all(0), .padding = dvui.Rect.all(8), .min_size_content = .{ .w = 16, .h = 16 } })) pending.* = .{ .idx = idx, .queue = true };
        components.tip(@src(), button_data, "Add torrent to queue");
    }
    components.tipId(@src(), row.data().*, safeUtf8(item.name[0..item.name_len]), row_key);
    if (dvui.clicked(row.data(), .{})) pending.* = .{ .idx = idx };
    renderSearchResultContext(row_key, row.data().borderRectScale().r, item);
}

fn renderSearchResultContext(id: usize, rect: dvui.Rect.Physical, item: *const @import("resolver.zig").ResolvedItem) void {
    const context = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id });
    defer context.deinit();
    if (context.activePoint()) |point| {
        var menu = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(point) }, .{ .id_extra = id, .color_fill = theme.colors.bg_surface, .color_border = theme.colors.border_subtle });
        defer menu.deinit();
        if (dvui.menuItemLabel(@src(), "Copy title", .{}, .{ .color_text = theme.colors.text_primary })) |_| {
            dvui.clipboardTextSet(safeUtf8(item.name[0..item.name_len]));
            menu.close();
        }
        if (dvui.menuItemLabel(@src(), "Copy link", .{}, .{ .color_text = theme.colors.text_primary })) |_| {
            dvui.clipboardTextSet(item.url[0..item.url_len]);
            menu.close();
        }
        if (item.source == .torrent) {
            if (dvui.menuItemLabel(@src(), "Check VirusTotal", .{}, .{ .color_text = theme.colors.text_primary })) |_| {
                var hash: [40]u8 = undefined;
                if (@import("virustotal_pure.zig").infoHashFromMagnet(item.url[0..item.url_len], &hash)) |value| {
                    var target: [128]u8 = undefined;
                    @import("../ui/settings.zig").openExternal(@import("virustotal_pure.zig").searchUrl(value, &target));
                } else state.showToast("No info-hash in this result");
                menu.close();
            }
        }
    }
}

pub fn loadTorrentToPlayer(magnet_link: []const u8) void {
    const logs = @import("../core/logs.zig");
    const playermod = @import("../player/player.zig");

    if (magnet_link.len == 0) {
        logs.pushLog("error", "search", "Empty magnet link", true);
        return;
    }
    // Every newer torrent intent supersedes a still-resolving detail page,
    // including an immediate magnet that needs no resolver worker.
    const action_generation = detail_resolve_generation.fetchAdd(1, .acq_rel) +% 1;

    // The cold-start torrent FIFO can retain a direct magnet before a player
    // exists. Initializing libmpv first only delayed acknowledgement.
    if (std.mem.startsWith(u8, magnet_link, "magnet:?")) {
        addMagnetToEngine(magnet_link);
        return;
    }

    // Detail-page resolution uses the player as its loading surface. Direct
    // magnets returned above and never pay this initialization cost.
    if (state.app.players.items.len == 0) {
        if (playermod.acquire(@import("../core/alloc.zig").allocator)) |new_p| {
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

    if (state.app.players.items.len > 0 and state.app.active_player_idx >= state.app.players.items.len) {
        state.app.active_player_idx = state.app.players.items.len - 1;
    }

    // If it's an HTTP URL (detail page), resolve to magnet in background
    if (std.mem.startsWith(u8, magnet_link, "http://") or std.mem.startsWith(u8, magnet_link, "https://")) {
        logs.pushLog("info", "search", "Resolving detail page to magnet...", false);

        // Show loading state, but pass only its process-unique identity to the
        // worker. The UI-thread drain revalidates pointer address + load serial.
        if (state.app.active_player_idx < state.app.players.items.len) {
            const p = state.app.players.items[state.app.active_player_idx];
            p.is_loading = true;
            const lbl = "Resolving magnet...";
            @memcpy(p.loading_label[0..lbl.len], lbl);
            p.loading_label_len = lbl.len;
        }

        const current = state.app.players.items[state.app.active_player_idx];
        detail_resolve_lock.lock();
        detail_resolve_ready.store(false, .release);
        detail_resolve_lock.unlock();
        var request: DetailResolveRequest = .{
            .generation = action_generation,
            .player_address = @intFromPtr(current),
            .load_serial = current.load_serial,
        };
        const ulen = @min(magnet_link.len, 4095);
        @memcpy(request.url[0..ulen], magnet_link[0..ulen]);
        request.url_len = ulen;
        @import("../core/workers.zig").spawn(resolveDetailWorker, .{request}) catch {
            current.is_loading = false;
            logs.pushLog("error", "search", "Failed to spawn resolver thread", true);
        };
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
    const playermod = @import("../player/player.zig");

    // A cold-start magnet can live in the pending FIFO without a player;
    // initialize libmpv only once the engine can consume it.
    if (state.torrentSession() != null and state.app.players.items.len == 0) {
        if (playermod.acquire(@import("../core/alloc.zig").allocator)) |new_p| {
            state.app.players.append(@import("../core/alloc.zig").allocator, new_p) catch {
                new_p.deinit(@import("../core/alloc.zig").allocator);
                return;
            };
            state.app.active_player_idx = 0;
        } else |_| return;
    }

    if (state.app.players.items.len > 0 and state.app.active_player_idx >= state.app.players.items.len) {
        state.app.active_player_idx = state.app.players.items.len - 1;
    }

    var null_term_uri: [4096]u8 = undefined;
    @memset(&null_term_uri, 0);
    const copy_len = @min(magnet_link.len, 4095);
    @memcpy(null_term_uri[0..copy_len], magnet_link[0..copy_len]);

    // The session is built on a background thread at startup (DHT bootstrap
    // takes 5-10s). Before it exists, torrent_add_magnet returns -1 and the old
    // message for that was "invalid or duplicate magnet" — which is wrong, and
    // sent people off checking a link that was fine. Clicking a result in the
    // first few seconds after launch did nothing and blamed the link.
    if (state.torrentSession() == null) {
        if (deferTorrentOpen(.magnet, magnet_link)) {
            @import("../core/logs.zig").pushLog("info", "search", "Torrent queued until engine startup completes", false);
            state.showToast("Torrent queued — starting engine");
        } else {
            @import("../core/logs.zig").pushLog("error", "search", "Cold-start torrent queue is full", true);
            state.showToast("Too many torrents queued — wait for startup");
        }
        return;
    }

    const tid = c.mpv.torrent_add_magnet(state.torrentSession(), @ptrCast(&null_term_uri[0]), state.getSavePath());
    attachTorrentToPlayer(tid, magnet_link);
}

/// Wire a freshly-added torrent (magnet OR .torrent file) into the active player.
///
/// Shared by addMagnetToEngine and addTorrentFileToEngine: both add to the same
/// engine and need identical player setup, so this lives in ONE place rather than
/// being copied — the two entry points differ only in which C add_* call produced
/// `tid` and what `source` string gets persisted.
///
/// Callers must have already ensured a valid active player exists.
fn attachTorrentToPlayer(tid: c_int, source: []const u8) void {
    const logs = @import("../core/logs.zig");

    if (state.app.active_player_idx >= state.app.players.items.len) return;

    if (tid >= 0) {
        @import("torrent_intents.zig").rememberTorrent(tid);
        const p = state.app.players.items[state.app.active_player_idx];

        // Stop whatever is playing RIGHT NOW.
        //
        // Playback used to be handed to mpv the instant a torrent was added, and
        // that loadfile is what implicitly ended the previous file. Now that we
        // wait for a readable head before calling loadfile, nothing stops the old
        // media — so picking a new episode left the PREVIOUS one playing (audio and
        // all) behind the buffering overlay, with a timeline still ticking. Ending
        // it here keeps "I clicked a new thing" and "the old thing stopped" in the
        // same instant, which is what the user actually asked for.
        if (p.current_url_len > 0) {
            _ = c.mpv.mpv_command_string(p.mpv_ctx, "stop");
            p.current_url_len = 0;
        }

        p.attachTorrent(tid);
        p.torrent_is_ready = false;
        p.has_metadata = false;
        p.last_load_time = 0;
        p.selected_file_idx = -1;
        p.metadata_start_time = @import("../core/io_global.zig").timestamp();
        p.is_loading = true;
        p.is_torrent = true;
        p.playback_origin = .torrent;
        const lbl = "Torrent stream";
        @memcpy(p.loading_label[0..lbl.len], lbl);
        p.loading_label_len = lbl.len;

        // Adopt the TMDB-linked loading context (if any) stashed by whoever
        // kicked off this play (tmdb.zig's sendToSearch / playTvEpisode), so
        // Loading-screen context (art, meta line, trivia). One shared
        // consumer — the direct-URL path uses it too, so music and streams get
        // the same screen instead of a bare hourglass.
        state.consumePendingPlay(p);

        // Store URL for workspace persistence
        const url_len = @min(source.len, 2048);
        @memcpy(p.source_url[0..url_len], source[0..url_len]);
        p.source_url_len = url_len;
        @memcpy(p.current_url[0..url_len], source[0..url_len]);
        p.current_url_len = url_len;

        logs.pushLog("info", "search", "Torrent added, waiting for metadata...", false);

        // Publish the handoff flag HERE, not only from the UI thread's per-frame
        // recompute: this path also runs off-frame (JSON API /load, resolver
        // callbacks). Waiting for a frame to set the flag that causes frames is
        // circular — with an idle window the torrent downloaded to 100% and never
        // started. wakeUi() gets the first frame; the watchdog keeps them coming.
        state.torrent_handoff_pending.store(true, .release);
        state.wakeUi();

        // Reveal the player so the user sees the stream start.
        state.gotoPlayer();

        // Save magnet to download history for library persistence
        const hist = @import("history.zig");
        hist.addDownloadHistory(source[0..@min(source.len, 64)], source);
    } else {
        logs.pushLog("error", "search", "Failed to add torrent - invalid magnet or already added", true);
        state.showToast("Couldn't add torrent (invalid or duplicate magnet)");
    }
}

/// Add a local .torrent FILE to the engine and stream it in the player.
///
/// The file-path sibling of addMagnetToEngine: same engine, same player setup
/// (via attachTorrentToPlayer), only the C entry point differs. Reached from
/// browser.loadContent's .torrent route — i.e. `opal foo.torrent`, drag-drop,
/// and the Open dialog.
pub fn addTorrentFileToEngine(path: []const u8) void {
    const logs = @import("../core/logs.zig");
    const playermod = @import("../player/player.zig");

    if (path.len == 0) {
        logs.pushLog("error", "search", "Empty torrent file path", true);
        return;
    }
    _ = detail_resolve_generation.fetchAdd(1, .acq_rel);

    // A cold-start `.torrent` path can live in the pending FIFO without a
    // player; initialize libmpv only once the engine can consume it.
    if (state.torrentSession() != null and state.app.players.items.len == 0) {
        if (playermod.acquire(@import("../core/alloc.zig").allocator)) |new_p| {
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

    if (state.app.players.items.len > 0 and state.app.active_player_idx >= state.app.players.items.len) {
        state.app.active_player_idx = state.app.players.items.len - 1;
    }

    var null_term_path: [4096]u8 = undefined;
    @memset(&null_term_path, 0);
    const copy_len = @min(path.len, 4095);
    @memcpy(null_term_path[0..copy_len], path[0..copy_len]);

    if (state.torrentSession() == null) {
        if (deferTorrentOpen(.torrent_file, path)) {
            @import("../core/logs.zig").pushLog("info", "search", ".torrent queued until engine startup completes", false);
            state.showToast("Torrent queued — starting engine");
        } else {
            @import("../core/logs.zig").pushLog("error", "search", "Cold-start torrent queue is full", true);
            state.showToast("Too many torrents queued — wait for startup");
        }
        return;
    }
    const tid = c.mpv.torrent_add_file(state.torrentSession(), @ptrCast(&null_term_path[0]), state.getSavePath());
    if (tid < 0) {
        logs.pushLog("error", "search", "Failed to add torrent — invalid .torrent file or already added", true);
        state.showToast("Couldn't add torrent (invalid .torrent file or duplicate)");
        return;
    }
    attachTorrentToPlayer(tid, path);
}

// ── NSFW Confirmation Modal ──
pub fn renderNsfwModal() void {
    if (!state.app.nsfw_confirm_pending) return;

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.nsfw_confirm_pending,
    }, .{
        .min_size_content = .{ .w = 400, .h = 10 },
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.danger,
    });
    defer win.deinit();

    win.dragAreaSet(dvui.windowHeader("NSFW Warning", "", &state.app.nsfw_confirm_pending));

    _ = dvui.label(@src(), "NSFW Content Warning", .{}, .{
        .color_text = theme.colors.danger,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });

    _ = dvui.label(@src(), "This content may contain adult material:", .{}, .{
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });

    const name = safeUtf8(state.app.nsfw_confirm_name_buf[0..state.app.nsfw_confirm_name_len]);
    _ = dvui.label(@src(), "{s}", .{name}, .{
        .color_text = theme.colors.warning,
        .padding = .{ .x = 0, .y = 4, .w = 0, .h = 12 },
    });

    _ = dvui.label(@src(), "Are you sure you want to load this?", .{}, .{
        .color_text = theme.colors.text_primary,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 12 },
    });

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .gravity_x = 1.0,
    });
    defer btn_row.deinit();

    if (dvui.button(@src(), "Cancel", .{}, .{
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_primary,
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
