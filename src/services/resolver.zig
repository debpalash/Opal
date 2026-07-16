const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const c = @import("../core/c.zig");
const logs = @import("../core/logs.zig");

const alloc = @import("../core/alloc.zig").allocator;
const content_cache = @import("../core/content_cache.zig");
const ccp = @import("../core/content_cache_pure.zig");

// ══════════════════════════════════════════════════════════
// Universal Resolver — one query, every source, ranked
//
// Priority: Local Jellyfin > Stremio Addons > Torrents > Anime > YouTube
// Each backend runs in a thread, results merge into a unified list.
// ══════════════════════════════════════════════════════════

pub const SourceType = enum {
    jellyfin, // Local library — fastest, already on disk
    stremio, // Addon streams — HTTP direct
    torrent, // Magnet links — needs download
    anime, // ani-cli streams — HTTP direct
    youtube, // yt-dlp streams — HTTP direct
    local, // user's own downloaded files in save_path — instant playback
    tmdb, // catalog entry (movie/show) — click to find sources
    comics, // readallcomics.com issues — open in the comics reader
};

pub const ResolvedItem = struct {
    name: [256]u8 = std.mem.zeroes([256]u8),
    name_len: usize = 0,
    detail: [128]u8 = std.mem.zeroes([128]u8), // size, seeds, source addon, etc.
    detail_len: usize = 0,
    url: [2048]u8 = std.mem.zeroes([2048]u8), // magnet/http/jf item id
    url_len: usize = 0,
    source: SourceType = .torrent,
    quality: u8 = 0, // 0=unknown, 1=480, 2=720, 3=1080, 4=4K
    seeds: u16 = 0,
    match_pct: u8 = 0, // 0-100% keyword match score for UI display
    score: u32 = 9999, // cached composite sort score (lower = better)
    is_nsfw: bool = false, // computed at insert from item name
    // For Jellyfin items
    jf_item_id: [64]u8 = std.mem.zeroes([64]u8),
    jf_item_id_len: usize = 0,
};

// Shared result buffer
pub var results: [64]ResolvedItem = std.mem.zeroes([64]ResolvedItem);
pub var result_count: usize = 0;
pub var results_mutex = @import("../core/sync.zig").Mutex{};

// Encrypted-content-cache SWR state. When a query's results are seeded from
// the on-disk cache (instant, no empty view), `results_from_cache` is true; the
// first live result of the fresh wave then replaces the placeholder (see
// pushResult). Guarded by results_mutex. Serialized blobs cap at ~160 KB
// (64 rows × fixed buffers), so 256 KB is a safe scratch size.
var results_from_cache: bool = false;
const SEARCH_BLOB_CAP: usize = 256 * 1024;
const SEARCH_TTL_S: i64 = @import("browse_cache.zig").TTL_S;

// Search state — shared across 7 worker threads + UI; access via atomics.
pub var is_resolving = std.atomic.Value(bool).init(false);
pub var resolver_query: [256]u8 = std.mem.zeroes([256]u8);
pub var resolver_query_len: usize = 0;
pub var resolver_intent: [32]u8 = std.mem.zeroes([32]u8);
pub var resolver_intent_len: usize = 0;

// Per-source status — atomics; load with .acquire, store with .release.
pub var status_jf = std.atomic.Value(SourceStatus).init(.idle);
pub var status_stremio = std.atomic.Value(SourceStatus).init(.idle);
pub var status_torrent = std.atomic.Value(SourceStatus).init(.idle);
pub var status_anime = std.atomic.Value(SourceStatus).init(.idle);
pub var status_yt = std.atomic.Value(SourceStatus).init(.idle);
pub var status_1337x = std.atomic.Value(SourceStatus).init(.idle);
pub var status_yts = std.atomic.Value(SourceStatus).init(.idle);
pub var status_local = std.atomic.Value(SourceStatus).init(.idle);
pub var status_rss = std.atomic.Value(SourceStatus).init(.idle);
pub var status_comics = std.atomic.Value(SourceStatus).init(.idle);
pub var status_torznab = std.atomic.Value(SourceStatus).init(.idle);
pub var status_archive = std.atomic.Value(SourceStatus).init(.idle);
pub var status_nasa = std.atomic.Value(SourceStatus).init(.idle);
pub var status_commons = std.atomic.Value(SourceStatus).init(.idle);

// Explicit u8 backing so std.atomic.Value(SourceStatus) is byte-atomic.
pub const SourceStatus = enum(u8) { idle, searching, done, failed };

/// UI source filter — one bit per Search-toolbar pill. Disabled sources are
/// not spawned by resolve() (their status reads .idle) and their result
/// groups are hidden. A mask of 0 is treated as "everything on" so the user
/// can never filter themselves into a permanently empty search.
pub const SourceBit = enum(u4) { local, torrent, jellyfin, youtube, anime, comics, stremio, rss };
pub var source_mask: std.atomic.Value(u16) = std.atomic.Value(u16).init(0xFF);

pub fn sourceOn(bit: SourceBit) bool {
    const m = source_mask.load(.acquire);
    if (m & 0xFF == 0) return true; // empty mask = all on
    return (m >> @intFromEnum(bit)) & 1 == 1;
}

pub fn toggleSource(bit: SourceBit) void {
    _ = source_mask.fetchXor(@as(u16, 1) << @intFromEnum(bit), .acq_rel);
}

/// Atomic accessor for is_resolving (UI reads, workers clear via checkAllDone).
pub fn isResolving() bool {
    return is_resolving.load(.acquire);
}

/// Re-sort the current results in place (UI-driven). mode: 0=relevance (score),
/// 1=quality (desc), 2=seeds (desc). Held under the results lock.
pub fn sortResultsBy(mode: usize) void {
    results_mutex.lock();
    defer results_mutex.unlock();
    const Ctx = struct {
        m: usize,
        fn lt(ctx: @This(), a: ResolvedItem, b: ResolvedItem) bool {
            return switch (ctx.m) {
                1 => a.quality > b.quality,
                2 => a.seeds > b.seeds,
                else => a.score < b.score,
            };
        }
    };
    std.sort.insertion(ResolvedItem, results[0..result_count], Ctx{ .m = mode }, Ctx.lt);
}

/// Reset the universal-result list under the results lock so a concurrent
/// worker insert can't race the UI clear-button.
pub fn clearResults() void {
    results_mutex.lock();
    defer results_mutex.unlock();
    result_count = 0;
}

/// Normalize a search query for torrent compatibility:
/// - "season 2 episode 5" → "S02E05"
/// - "ep 3" → "E03"
/// - "s2 e5" → "S02E05" (already short form)
fn normalizeQuery(raw: []const u8, buf: *[256]u8) []const u8 {
    // Lowercase copy for pattern matching
    var lower: [256]u8 = undefined;
    const rlen = @min(raw.len, 255);
    for (0..rlen) |i| lower[i] = std.ascii.toLower(raw[i]);
    const src = lower[0..rlen];

    var out: usize = 0;
    var i: usize = 0;

    while (i < rlen) {
        // Check for "season X" pattern
        if (i + 7 <= rlen and std.mem.eql(u8, src[i .. i + 7], "season ")) {
            const num_start = i + 7;
            var num_end = num_start;
            while (num_end < rlen and std.ascii.isDigit(src[num_end])) num_end += 1;
            if (num_end > num_start) {
                buf[out] = 'S';
                out += 1;
                // Zero-pad to 2 digits
                const num = src[num_start..num_end];
                if (num.len == 1) {
                    buf[out] = '0';
                    out += 1;
                }
                for (num) |ch| {
                    if (out < 255) {
                        buf[out] = ch;
                        out += 1;
                    }
                }
                i = num_end;
                // Check for "episode Y" immediately after
                while (i < rlen and src[i] == ' ') i += 1;
                if (i + 8 <= rlen and std.mem.eql(u8, src[i .. i + 8], "episode ")) {
                    const ep_start = i + 8;
                    var ep_end = ep_start;
                    while (ep_end < rlen and std.ascii.isDigit(src[ep_end])) ep_end += 1;
                    if (ep_end > ep_start) {
                        buf[out] = 'E';
                        out += 1;
                        const ep_num = src[ep_start..ep_end];
                        if (ep_num.len == 1) {
                            buf[out] = '0';
                            out += 1;
                        }
                        for (ep_num) |ch| {
                            if (out < 255) {
                                buf[out] = ch;
                                out += 1;
                            }
                        }
                        i = ep_end;
                    }
                } else if (i + 3 <= rlen and std.mem.eql(u8, src[i .. i + 3], "ep ")) {
                    const ep_start = i + 3;
                    var ep_end = ep_start;
                    while (ep_end < rlen and std.ascii.isDigit(src[ep_end])) ep_end += 1;
                    if (ep_end > ep_start) {
                        buf[out] = 'E';
                        out += 1;
                        const ep_num = src[ep_start..ep_end];
                        if (ep_num.len == 1) {
                            buf[out] = '0';
                            out += 1;
                        }
                        for (ep_num) |ch| {
                            if (out < 255) {
                                buf[out] = ch;
                                out += 1;
                            }
                        }
                        i = ep_end;
                    }
                }
                continue;
            }
        }
        // Check for standalone "episode X" or "ep X"
        if (i + 8 <= rlen and std.mem.eql(u8, src[i .. i + 8], "episode ")) {
            const ep_start = i + 8;
            var ep_end = ep_start;
            while (ep_end < rlen and std.ascii.isDigit(src[ep_end])) ep_end += 1;
            if (ep_end > ep_start) {
                buf[out] = 'E';
                out += 1;
                const ep_num = src[ep_start..ep_end];
                if (ep_num.len == 1) {
                    buf[out] = '0';
                    out += 1;
                }
                for (ep_num) |ch| {
                    if (out < 255) {
                        buf[out] = ch;
                        out += 1;
                    }
                }
                i = ep_end;
                continue;
            }
        }
        if (i + 3 <= rlen and std.mem.eql(u8, src[i .. i + 3], "ep ")) {
            const ep_start = i + 3;
            var ep_end = ep_start;
            while (ep_end < rlen and std.ascii.isDigit(src[ep_end])) ep_end += 1;
            if (ep_end > ep_start and ep_end - ep_start <= 3) {
                buf[out] = 'E';
                out += 1;
                const ep_num = src[ep_start..ep_end];
                if (ep_num.len == 1) {
                    buf[out] = '0';
                    out += 1;
                }
                for (ep_num) |ch| {
                    if (out < 255) {
                        buf[out] = ch;
                        out += 1;
                    }
                }
                i = ep_end;
                continue;
            }
        }
        // Default: copy character
        if (out < 255) {
            buf[out] = src[i];
            out += 1;
        }
        i += 1;
    }
    return buf[0..out];
}

/// Main entry: fire all backends in parallel
pub fn resolve(query: []const u8, intent: []const u8) void {
    if (query.len == 0) return;
    // Supersede, don't drop: the old `is_resolving` early-return silently ate
    // every Enter/search-icon press while ANY slow source was still draining
    // (nova2 fans out to 20+ engines and can run a minute) — fast sources had
    // long since painted results, so the search looked idle but dead. Bumping
    // the generation orphans the in-flight wave: its pushResult calls no-op
    // (worker_gen mismatch) while this wave's workers own the fresh statuses.
    _ = run_gen.fetchAdd(1, .acq_rel);

    // Save query — normalize "season X episode Y" → "SXXEYY"
    var norm_buf: [256]u8 = undefined;
    const normalized = normalizeQuery(query, &norm_buf);
    const qlen = @min(normalized.len, 255);
    @memcpy(resolver_query[0..qlen], normalized[0..qlen]);
    resolver_query_len = qlen;
    {
        var qlog: [320]u8 = undefined;
        const m = std.fmt.bufPrint(&qlog, "query='{s}' intent='{s}'", .{ normalized, intent }) catch "query";
        logs.pushLog("info", "resolver", m, false);
    }

    // Save intent (e.g. "show", "movie", "auto")
    const ilen = @min(intent.len, 31);
    @memcpy(resolver_intent[0..ilen], intent[0..ilen]);
    resolver_intent_len = ilen;

    // Clear results
    results_mutex.lock();
    result_count = 0;
    results_from_cache = false;
    results_mutex.unlock();

    // SWR: seed from the encrypted on-disk cache so the view paints INSTANTLY
    // (never blank) while the workers below revalidate. The first live result
    // replaces this placeholder (see pushResult).
    populateFromCache(normalized);

    is_resolving.store(true, .release);
    // IMPORTANT: Set ALL to their final pre-spawn state BEFORE spawning any
    // thread. Otherwise a fast-finishing thread (e.g. no Jellyfin) calls
    // checkAllDone() before others start → premature is_resolving=false.
    // Sources the user filtered out (source_mask) sit at .idle and are never
    // spawned; checkAllDone treats .idle as complete.
    const Pre = struct {
        fn set(st: *std.atomic.Value(SourceStatus), bit: SourceBit) void {
            st.store(if (sourceOn(bit)) .searching else .idle, .release);
        }
    };
    Pre.set(&status_jf, .jellyfin);
    Pre.set(&status_stremio, .stremio);
    Pre.set(&status_torrent, .torrent);
    Pre.set(&status_anime, .anime);
    Pre.set(&status_yt, .youtube);
    Pre.set(&status_1337x, .torrent);
    Pre.set(&status_yts, .torrent);
    Pre.set(&status_local, .local);
    Pre.set(&status_rss, .rss);
    Pre.set(&status_comics, .comics);
    Pre.set(&status_torznab, .torrent); // generic Torznab/Prowlarr — a torrent source
    Pre.set(&status_archive, .stremio); // Internet Archive — legal HTTP-direct streams (rides the Stremio pill)
    Pre.set(&status_nasa, .stremio); // NASA image/video library — legal HTTP-direct, rides the Stremio pill
    Pre.set(&status_commons, .stremio); // Wikimedia Commons — legal HTTP-direct, rides the Stremio pill



    // Fire every backend in parallel. Each handle is detached (never joined) —
    // discarding it via `_ =` leaks the pthread resource for the process life.
    const Spawn = struct {
        // Wrapper stamps the worker thread's generation (threadlocal) before
        // running the backend, so pushResult can drop pushes from a superseded
        // wave. Query still travels BY VALUE through the spawn tuple.
        fn go(comptime f: anytype, st: *std.atomic.Value(SourceStatus)) void {
            const Wrap = struct {
                fn run(wq: [256]u8, wqlen: usize, wg: u32) void {
                    worker_gen = wg;
                    f(wq, wqlen);
                }
            };
            if (std.Thread.spawn(.{}, Wrap.run, .{ resolver_query, resolver_query_len, run_gen.load(.acquire) })) |t| {
                t.detach();
            } else |_| {
                st.store(.failed, .release);
                checkAllDone();
            }
        }
    };
    if (sourceOn(.local)) Spawn.go(resolveLocalFiles, &status_local); // instant — already on disk
    if (sourceOn(.rss)) Spawn.go(resolveRss, &status_rss); // already-fetched magnets matching query
    if (sourceOn(.jellyfin)) Spawn.go(resolveJellyfin, &status_jf);
    if (sourceOn(.torrent)) Spawn.go(resolveTorrentsNova2, &status_torrent);
    if (sourceOn(.torrent)) Spawn.go(resolve1337x, &status_1337x);
    if (sourceOn(.torrent)) Spawn.go(resolveYts, &status_yts);
    if (sourceOn(.torrent)) Spawn.go(resolveTorznab, &status_torznab); // self-hosted Prowlarr/Jackett — inert w/o marker
    if (sourceOn(.anime)) Spawn.go(resolveAnime, &status_anime);
    if (sourceOn(.youtube)) Spawn.go(resolveYouTube, &status_yt);
    if (sourceOn(.comics)) Spawn.go(resolveComics, &status_comics); // readallcomics.com HTML scrape
    if (sourceOn(.stremio)) Spawn.go(resolveStremio, &status_stremio); // needs IMDB id — TMDB then addons
    if (sourceOn(.stremio)) Spawn.go(resolveArchive, &status_archive); // archive.org public-domain — legal, default-on
    if (sourceOn(.stremio)) Spawn.go(resolveNasa, &status_nasa); // NASA library — legal HTTP-direct, default-on
    if (sourceOn(.stremio)) Spawn.go(resolveCommons, &status_commons); // Wikimedia Commons — legal HTTP-direct, default-on

    // If filtering left nothing to spawn, close the resolve immediately —
    // no worker exists to call checkAllDone().
    checkAllDone();
}

/// Monotonic search generation. Each worker thread carries the generation it
/// was spawned under (threadlocal, set by Spawn's wrapper); a new resolve()
/// bumps it, so superseded workers publish nothing and just wind down.
var run_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
threadlocal var worker_gen: u32 = 0;

fn pushResult(item: ResolvedItem) bool {
    // Superseded wave (user searched again mid-flight) — drop, don't mix
    // stale rows for the previous query into the fresh result list.
    if (worker_gen != run_gen.load(.acquire)) return false;
    results_mutex.lock();
    defer results_mutex.unlock();
    if (result_count >= 64) return false;

    // Filter out error/garbage results at the source
    const name = item.name[0..@min(item.name_len, 256)];
    if (isErrorResult(name)) return false;

    var scored_item = item;
    const match_info = computeMatch(scored_item);
    if (match_info.match_pct == 0) return false;

    scored_item.match_pct = match_info.match_pct;
    const score = match_info.score;
    scored_item.score = score; // cache so re-inserts don't recompute (S45)
    scored_item.is_nsfw = @import("search.zig").isNsfwName(name); // S16

    // SWR: the first live result of a fresh wave replaces the cache-seeded
    // placeholder, so stale cached rows never mix with the revalidated set.
    if (results_from_cache) {
        result_count = 0;
        results_from_cache = false;
    }

    // Insert sorted by score (lower = better) — compare cached scores, O(n)
    var insert_at: usize = result_count;
    var i: usize = 0;
    while (i < result_count) : (i += 1) {
        if (results[i].score > score) {
            insert_at = i;
            break;
        }
    }
    // Shift items down
    if (insert_at < result_count) {
        var j: usize = result_count;
        while (j > insert_at) : (j -= 1) {
            results[j] = results[j - 1];
        }
    }
    results[insert_at] = scored_item;
    result_count += 1;
    return true;
}

const local_media_exts = [_][]const u8{
    ".mp4", ".mkv", ".avi",  ".mov", ".webm", ".m4v",  ".flv", ".wmv", ".mpg", ".mpeg",
    ".ts",  ".mp3", ".flac", ".m4a", ".wav",  ".opus", ".aac", ".ogg",
};

fn isLocalMedia(name: []const u8) bool {
    var lower: [512]u8 = undefined;
    if (name.len == 0 or name.len > lower.len) return false;
    for (0..name.len) |i| lower[i] = std.ascii.toLower(name[i]);
    const l = lower[0..name.len];
    for (local_media_exts) |ext| {
        if (std.mem.endsWith(u8, l, ext)) return true;
    }
    return false;
}

/// Search the user's save/download folder for already-downloaded media whose
/// filename matches the query — instant, zero-network results so a movie you
/// already have is findable straight from the omnibox.
fn resolveLocalFiles(q: [256]u8, qlen: usize) void {
    const io_global = @import("../core/io_global.zig");
    defer {
        status_local.store(.done, .release);
        checkAllDone();
    }
    if (qlen == 0) return;

    var ql: [256]u8 = undefined;
    for (0..qlen) |i| ql[i] = std.ascii.toLower(q[i]);
    const query = ql[0..qlen];

    var path_buf: [1024]u8 = undefined;
    const save_path = if (state.app.save_path_len > 0)
        state.app.save_path_buf[0..state.app.save_path_len]
    else
        @import("../core/paths.zig").defaultSavePath(&path_buf);
    if (save_path.len == 0) return;

    var dir = io_global.cwdOpenDir(save_path, .{ .iterate = true }) catch return;
    defer dir.close(io_global.io());

    var iter = dir.iterate();
    var found: usize = 0;
    while (iter.next(io_global.io()) catch null) |entry| {
        if (found >= 20) break;
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!isLocalMedia(name)) continue;

        var nl: [512]u8 = undefined;
        if (name.len > nl.len) continue;
        for (0..name.len) |i| nl[i] = std.ascii.toLower(name[i]);
        if (std.mem.indexOf(u8, nl[0..name.len], query) == null) continue;

        var item = ResolvedItem{ .source = .local };
        const nlen = @min(name.len, 255);
        @memcpy(item.name[0..nlen], name[0..nlen]);
        item.name_len = nlen;

        var url_buf: [2048]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/{s}", .{ save_path, name }) catch continue;
        const ulen = @min(url.len, item.url.len);
        @memcpy(item.url[0..ulen], url[0..ulen]);
        item.url_len = ulen;

        const d = "On disk";
        @memcpy(item.detail[0..d.len], d);
        item.detail_len = d.len;

        _ = pushResult(item);
        found += 1;
    }
}

/// Match already-fetched RSS feed items against the query and surface them as
/// torrent-source results (they carry magnet URIs → play via loadTorrentToPlayer).
fn resolveRss(q: [256]u8, qlen: usize) void {
    const rss = @import("rss.zig");
    defer {
        status_rss.store(.done, .release);
        checkAllDone();
    }
    if (qlen == 0) return;

    var ql: [256]u8 = undefined;
    for (0..qlen) |i| ql[i] = std.ascii.toLower(q[i]);
    const query = ql[0..qlen];

    var found: usize = 0;
    var i: usize = 0;
    while (i < rss.item_count and found < 20) : (i += 1) {
        const it = &rss.items[i];
        if (it.magnet_len == 0 or it.title_len == 0) continue;
        const title = it.title[0..it.title_len];
        if (title.len > 256) continue;

        var tl: [256]u8 = undefined;
        for (0..title.len) |k| tl[k] = std.ascii.toLower(title[k]);
        if (std.mem.indexOf(u8, tl[0..title.len], query) == null) continue;

        var item = ResolvedItem{ .source = .torrent };
        const nlen = @min(it.title_len, 255);
        @memcpy(item.name[0..nlen], title[0..nlen]);
        item.name_len = nlen;
        const ulen = @min(it.magnet_len, item.url.len);
        @memcpy(item.url[0..ulen], it.magnet[0..ulen]);
        item.url_len = ulen;
        item.seeds = it.seeds;
        const d = "RSS feed";
        @memcpy(item.detail[0..d.len], d);
        item.detail_len = d.len;
        _ = pushResult(item);
        found += 1;
    }
}

/// Search readallcomics.com for comic issues matching the query and surface
/// them as .comics-source results (click → comics.loadComic → reader view).
/// Reuses the exact search URL + book-link/title/latest-chapter href parse that
/// comics.zig's buildSearchUrl/parseSearchResults use.
fn resolveComics(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_comics.store(.done, .release);
        checkAllDone();
    }
    if (qlen == 0) return;

    const query = query_buf[0..qlen];

    // URL-encode the query (percent-encode space/&/=/#/?/% per CLAUDE.md; space→+).
    var enc: [512]u8 = undefined;
    var el: usize = 0;
    const hex = "0123456789ABCDEF";
    for (query) |ch| {
        if (el + 3 >= enc.len) break;
        if (ch == ' ') {
            enc[el] = '+';
            el += 1;
        } else if (ch == '&' or ch == '=' or ch == '#' or ch == '?' or ch == '%' or ch == '+') {
            enc[el] = '%';
            enc[el + 1] = hex[ch >> 4];
            enc[el + 2] = hex[ch & 0x0F];
            el += 3;
        } else {
            enc[el] = ch;
            el += 1;
        }
    }

    // Endpoint migrated to opal-plugins — inert until the user installs "readallcomics".
    const base = @import("../core/source_config.zig").get("readallcomics", "base") orelse return;
    var url_buf: [640]u8 = undefined;
    // Same URL comics.zig builds for page 1.
    const url = std.fmt.bufPrint(&url_buf, "{s}/?story={s}&s=&type=comic", .{ base, enc[0..el] }) catch return;

    // readallcomics pages can be large — heap the fetch buffer (never on the
    // worker stack, per the >64KB rule).
    const page = alloc.alloc(u8, 512 * 1024) catch return;
    defer alloc.free(page);

    @import("../core/rate_limit.zig").acquire("readallcomics", 1.0);
    const body = @import("../core/http.zig").fetch(url, page, .{
        .timeout_secs = 6,
        .user_agent = "Mozilla/5.0",
    }) orelse return;
    const html = body;
    if (html.len < 100) return;

    // Parse: each result is a `class="book-link"` block carrying a title="…"
    // attribute and a following `class="latest-chapter"` anchor href (the
    // loadable issue URL). Mirror comics.zig parseSearchResults.
    var pos: usize = 0;
    var found: usize = 0;
    const block_needle = "class=\"book-link\"";
    while (pos < html.len and found < 12) {
        const b = std.mem.indexOfPos(u8, html, pos, block_needle) orelse break;
        const block_at = b;
        const a_open = std.mem.lastIndexOf(u8, html[0..block_at], "<a ") orelse {
            pos = block_at + block_needle.len;
            continue;
        };
        const next_rel = std.mem.indexOfPos(u8, html, block_at + block_needle.len, block_needle);
        const block_end = next_rel orelse html.len;
        pos = block_end;
        const block = html[a_open..block_end];

        // Title — the title="…" attribute on the book-link anchor.
        var title: []const u8 = "";
        if (attrValue(block, "title=", 600)) |t| title = t;

        // Loadable URL — the latest-chapter anchor's href (non-category).
        var link: []const u8 = "";
        if (std.mem.indexOf(u8, block, "class=\"latest-chapter\"")) |lc| {
            const a2 = std.mem.lastIndexOf(u8, block[0..lc], "<a ") orelse lc;
            if (attrValue(block[a2..], "href=", 256)) |h| {
                if (std.mem.startsWith(u8, h, "https://readallcomics.com/") and
                    std.mem.indexOf(u8, h, "/category/") == null)
                    link = h;
            }
        }
        // Fallback: the book-link's own href (category page still loads).
        if (link.len == 0) {
            if (attrValue(block, "href=", 256)) |h| {
                if (std.mem.startsWith(u8, h, "https://readallcomics.com/")) link = h;
            }
        }
        if (link.len == 0 or link.len > 2047) continue;

        // Title fallback: derive from the link slug.
        if (title.len == 0) {
            const prefix = "https://readallcomics.com/";
            const tail = if (link.len > prefix.len) std.mem.trimEnd(u8, link[prefix.len..], "/") else link;
            title = tail;
        }
        title = std.mem.trim(u8, title, " \t\r\n");
        if (title.len == 0) continue;

        var item = std.mem.zeroes(ResolvedItem);
        item.source = .comics;

        const nlen = @min(title.len, 255);
        @memcpy(item.name[0..nlen], title[0..nlen]);
        item.name_len = nlen;

        const ulen = @min(link.len, 2047);
        @memcpy(item.url[0..ulen], link[0..ulen]);
        item.url_len = ulen;

        const d = "Comic · ReadAllComics";
        @memcpy(item.detail[0..d.len], d);
        item.detail_len = d.len;

        if (pushResult(item)) found += 1;
    }
}

/// Read an HTML attribute value (`name="value"`) within the first `limit` bytes
/// of `html`. Returns the slice between the quotes. (Local copy of the comics.zig
/// helper so the resolver stays self-contained.)
fn attrValue(html: []const u8, name: []const u8, limit: usize) ?[]const u8 {
    const window = html[0..@min(limit, html.len)];
    const at = std.mem.indexOf(u8, window, name) orelse return null;
    var p = at + name.len;
    while (p < window.len and (window[p] == ' ' or window[p] == '=')) p += 1;
    if (p >= window.len or window[p] != '"') return null;
    p += 1;
    const end = std.mem.indexOfScalar(u8, html[p..], '"') orelse return null;
    return html[p .. p + end];
}

// ══════════════════════════════════════════════════════════
// Encrypted on-disk content cache — stale-while-revalidate wiring.
// Serialization routes through content_cache_pure.Writer/Reader (tested).
// ══════════════════════════════════════════════════════════

fn cacheKey(buf: []u8, query: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "search:{s}", .{query}) catch "search:";
}

/// Serialize the current `results` (under caller's lock) into `out`.
fn serializeResults(out: []u8) ?[]u8 {
    var w = ccp.Writer.init(out);
    const n: u16 = @intCast(@min(result_count, 64));
    w.u16v(n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const it = results[i];
        w.blob(it.name[0..@min(it.name_len, it.name.len)]);
        w.blob(it.detail[0..@min(it.detail_len, it.detail.len)]);
        w.blob(it.url[0..@min(it.url_len, it.url.len)]);
        w.u8v(@intFromEnum(it.source));
        w.u8v(it.quality);
        w.u16v(it.seeds);
        w.u8v(it.match_pct);
        w.u32v(it.score);
        w.boolv(it.is_nsfw);
        w.blob(it.jf_item_id[0..@min(it.jf_item_id_len, it.jf_item_id.len)]);
    }
    return w.done();
}

fn copyField(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

/// Reconstruct rows from a cached blob straight into `results` (under lock).
/// Returns how many rows were populated.
fn deserializeInto(bytes: []const u8) usize {
    var r = ccp.Reader.init(bytes);
    const n = r.u16v() orelse return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i < n and count < 64) : (i += 1) {
        var it = ResolvedItem{};
        const name = r.blob() orelse break;
        copyField(&it.name, &it.name_len, name);
        const detail = r.blob() orelse break;
        copyField(&it.detail, &it.detail_len, detail);
        const url = r.blob() orelse break;
        copyField(&it.url, &it.url_len, url);
        const src_tag = r.u8v() orelse break;
        const src_fields = @typeInfo(SourceType).@"enum".fields.len;
        it.source = if (src_tag < src_fields) @enumFromInt(src_tag) else .torrent;
        it.quality = r.u8v() orelse break;
        it.seeds = r.u16v() orelse break;
        it.match_pct = r.u8v() orelse break;
        it.score = r.u32v() orelse break;
        it.is_nsfw = r.boolv() orelse break;
        const jf = r.blob() orelse break;
        copyField(&it.jf_item_id, &it.jf_item_id_len, jf);
        results[count] = it;
        count += 1;
    }
    return count;
}

/// SWR read: seed `results` from the on-disk cache so the search view paints
/// instantly instead of showing an empty list while the workers fan out.
fn populateFromCache(query: []const u8) void {
    if (!state.app.content_cache_enabled) return;
    const buf = alloc.alloc(u8, SEARCH_BLOB_CAP) catch return;
    defer alloc.free(buf);
    var key_buf: [288]u8 = undefined;
    const key = cacheKey(&key_buf, query);
    const hit = content_cache.get(key, buf) orelse return;
    results_mutex.lock();
    defer results_mutex.unlock();
    const n = deserializeInto(hit.bytes);
    if (n > 0) {
        result_count = n;
        results_from_cache = true;
    }
}

/// SWR write: persist the freshly-fetched results so the next cold start (or a
/// repeat query) is instant. Only stores real live results — never re-stores a
/// cache-seeded placeholder (that would reset the TTL without a network fetch).
fn storeToCache() void {
    if (!state.app.content_cache_enabled) return;
    results_mutex.lock();
    if (result_count == 0 or results_from_cache) {
        results_mutex.unlock();
        return;
    }
    const buf = alloc.alloc(u8, SEARCH_BLOB_CAP) catch {
        results_mutex.unlock();
        return;
    };
    defer alloc.free(buf);
    var qbuf: [256]u8 = undefined;
    const qn = @min(resolver_query_len, resolver_query.len);
    @memcpy(qbuf[0..qn], resolver_query[0..qn]);
    const blob = serializeResults(buf);
    results_mutex.unlock();
    if (blob) |b| {
        var key_buf: [288]u8 = undefined;
        const key = cacheKey(&key_buf, qbuf[0..qn]);
        content_cache.put(key, b, SEARCH_TTL_S);
    }
}

fn checkAllDone() void {
    if (status_jf.load(.acquire) != .searching and status_stremio.load(.acquire) != .searching and
        status_torrent.load(.acquire) != .searching and status_anime.load(.acquire) != .searching and
        status_yt.load(.acquire) != .searching and status_1337x.load(.acquire) != .searching and
        status_yts.load(.acquire) != .searching and status_local.load(.acquire) != .searching and
        status_rss.load(.acquire) != .searching and status_comics.load(.acquire) != .searching and
        status_torznab.load(.acquire) != .searching and status_archive.load(.acquire) != .searching and
        status_nasa.load(.acquire) != .searching and status_commons.load(.acquire) != .searching)
    {
        // Swap so the resolving→done transition fires exactly once even if two
        // finishing workers observe "all done" concurrently — only the winner
        // persists the revalidated results for the next cold start (SWR write).
        if (is_resolving.swap(false, .acq_rel)) storeToCache();
    }
}

const stop_words = [_][]const u8{ "the", "a", "an", "of", "in", "on", "to", "and", "for", "is", "it", "my", "me", "at", "by" };

fn isStopWord(word: []const u8) bool {
    for (stop_words) |sw| {
        if (std.mem.eql(u8, word, sw)) return true;
    }
    return false;
}

/// Detect error/garbage results from broken indexers (Jackett API errors, etc.)
fn isErrorResult(name: []const u8) bool {
    const error_markers = [_][]const u8{
        "api key error",    "Jackett:",         "jackett:",      "API key",
        "error!",           "Error!",           "ERROR",         "configuration",
        "Right-click this", "right-click this", "indexer error", "Indexer Error",
    };
    for (error_markers) |marker| {
        if (std.mem.indexOf(u8, name, marker) != null) return true;
    }
    return false;
}

const MatchInfo = struct { match_pct: u8, score: u32 };

/// Compute match percentage + composite sorting score.
/// Lower score = better result. match_pct=0 means zero keyword hits (filtered).
fn computeMatch(item: ResolvedItem) MatchInfo {
    const query = resolver_query[0..resolver_query_len];
    const name = item.name[0..item.name_len];

    var match_words: u32 = 0;
    var total_words: u32 = 0;

    var lower_name: [256]u8 = undefined;
    const nlen = @min(name.len, 255);
    for (0..nlen) |i| lower_name[i] = std.ascii.toLower(name[i]);

    var lower_query: [256]u8 = undefined;
    const ql = @min(query.len, 255);
    for (0..ql) |i| lower_query[i] = std.ascii.toLower(query[i]);

    var qi: usize = 0;
    while (qi < ql) {
        while (qi < ql and lower_query[qi] == ' ') qi += 1;
        if (qi >= ql) break;
        const word_start = qi;
        while (qi < ql and lower_query[qi] != ' ') qi += 1;
        const word = lower_query[word_start..qi];
        if (word.len == 0) continue;
        if (word.len == 1 and !std.ascii.isDigit(word[0])) continue;
        if (isStopWord(word)) continue;
        total_words += 1;

        // Fully-numeric tokens (e.g. "2" in "iron man 2") must match on
        // word boundaries — otherwise "2" matches inside "2008" and ruins
        // ranking for sequels.
        var is_numeric = true;
        for (word) |ch| if (!std.ascii.isDigit(ch)) {
            is_numeric = false;
            break;
        };

        const hay = lower_name[0..nlen];
        if (is_numeric) {
            var hi: usize = 0;
            while (std.mem.indexOfPos(u8, hay, hi, word)) |p| {
                const before_ok = (p == 0) or !std.ascii.isDigit(hay[p - 1]);
                const after_idx = p + word.len;
                const after_ok = (after_idx >= hay.len) or !std.ascii.isDigit(hay[after_idx]);
                if (before_ok and after_ok) {
                    match_words += 1;
                    break;
                }
                hi = p + 1;
            }
        } else {
            if (std.mem.indexOf(u8, hay, word) != null) match_words += 1;
        }
    }

    const pct: u8 = if (total_words > 0)
        @intCast((match_words * 100) / total_words)
    else
        50;

    if (match_words == 0) return .{ .match_pct = 0, .score = 9999 };

    // Relevance: 100 (few match) to 0 (all match)
    const relevance: u32 = 100 - @as(u32, pct);

    const intent = resolver_intent[0..resolver_intent_len];
    const is_movie_or_show = std.mem.eql(u8, intent, "movie") or std.mem.eql(u8, intent, "show");

    var source_w: u32 = switch (item.source) {
        .local => 0, // already on disk — instant, rank first
        .jellyfin => 1,
        .stremio => 5,
        .torrent => 8,
        .anime => 12,
        .comics => 14, // readable issues — rank near anime
        .youtube => 20,
        .tmdb => 30, // catalog stub — not directly playable, rank last
    };

    // Heavily penalize YouTube if intent is movie or show to prevent playing random trailers
    if (is_movie_or_show and item.source == .youtube) {
        source_w += 1000;
    }

    // 1080p is ideal sweet spot
    const quality_bonus: u32 = switch (item.quality) {
        4 => 2,
        3 => 0,
        2 => 5,
        1 => 10,
        else => 15,
    };

    // Seed bonus capped at 7 so a well-seeded torrent can't leapfrog an
    // equal-match jellyfin item (torrent source_w=8 gap must survive).
    // Inter-torrent ordering is still preserved via the remaining spread.
    const seed_bonus: u32 = if (item.seeds > 100) 7 else if (item.seeds > 50) 6 else if (item.seeds > 20) 5 else if (item.seeds > 10) 4 else if (item.seeds > 5) 3 else if (item.seeds > 0) 1 else 0;

    // Derivative-content demotion (lyric videos, compilations, clips…) — the
    // "play iron man → Black Sabbath (lyrics)" regression. Pure + tested in
    // resolver_rank; only fires when the query didn't ask for that class.
    const junk = @import("resolver_rank.zig").junkTitlePenalty(lower_name[0..nlen], lower_query[0..ql]);

    const raw = relevance + source_w + quality_bonus + junk;
    const score = if (raw > seed_bonus) raw - seed_bonus else 0;

    return .{ .match_pct = pct, .score = score };
}

// ══════════════════════════════════════════════════════════
// Backend: Jellyfin (local library search)
// ══════════════════════════════════════════════════════════

fn resolveJellyfin(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_jf.store(.done, .release);
        checkAllDone();
    }

    if (!state.app.jf.connected or state.app.jf.server_url_len == 0) {
        return;
    }

    const query = query_buf[0..qlen];
    const server = state.app.jf.server_url[0..state.app.jf.server_url_len];
    const uid = state.app.jf.user_id[0..state.app.jf.user_id_len];
    const token = state.app.jf.token[0..state.app.jf.token_len];

    // URL-encode query
    var enc_buf: [512]u8 = undefined;
    var enc_len: usize = 0;
    for (query) |ch| {
        if (enc_len + 3 >= enc_buf.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') {
            enc_buf[enc_len] = ch;
            enc_len += 1;
        } else {
            enc_buf[enc_len] = '%';
            const hex = "0123456789ABCDEF";
            enc_buf[enc_len + 1] = hex[ch >> 4];
            enc_buf[enc_len + 2] = hex[ch & 0xF];
            enc_len += 3;
        }
    }

    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/Users/{s}/Items?searchTerm={s}&Limit=10&Recursive=true&Fields=Overview&api_key={s}", .{
        server, uid, enc_buf[0..enc_len], token,
    }) catch return;

    var buf: [64 * 1024]u8 = undefined;
    @import("../core/rate_limit.zig").acquire("jellyfin", 5.0);
    const body = @import("../core/http.zig").fetch(url, &buf, .{ .timeout_secs = 5 }) orelse return;
    const n = body.len;

    if (n < 10) return;

    // Parse items
    var pos: usize = 0;
    while (pos < n) {
        const id_key = "\"Id\":\"";
        const next = std.mem.indexOf(u8, buf[pos..], id_key) orelse break;
        const abs = pos + next;

        // Find object boundaries
        const obj_end = findObjEnd(buf[0..n], abs);
        const obj = buf[abs..obj_end];

        var item = std.mem.zeroes(ResolvedItem);
        item.source = .jellyfin;

        if (extractStr(obj, "\"Id\":\"")) |id| {
            const ilen = @min(id.len, 63);
            @memcpy(item.jf_item_id[0..ilen], id[0..ilen]);
            item.jf_item_id_len = ilen;
            @memcpy(item.url[0..ilen], id[0..ilen]);
            item.url_len = ilen;
        }
        if (extractStr(obj, "\"Name\":\"")) |name| {
            const nlen = @min(name.len, 255);
            @memcpy(item.name[0..nlen], name[0..nlen]);
            item.name_len = nlen;
        }
        if (extractStr(obj, "\"Type\":\"")) |mt| {
            const dstr = std.fmt.bufPrint(&item.detail, "Jellyfin · {s}", .{mt}) catch "";
            item.detail_len = dstr.len;
        } else {
            const dstr = "Jellyfin · Local";
            @memcpy(item.detail[0..dstr.len], dstr);
            item.detail_len = dstr.len;
        }

        if (item.name_len > 0) _ = pushResult(item);
        pos = obj_end;
    }
}

// ══════════════════════════════════════════════════════════
// Backend: Torrents — nova2.py multi-engine + YTS API
// ══════════════════════════════════════════════════════════

// Main torrent thread: uses nova2.py (same proven engine as Torrent Only tab)
fn resolveTorrentsNova2(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_torrent.store(.done, .release);
        checkAllDone();
    }

    const query = query_buf[0..qlen];

    // nova2.py requires running from the engines/ parent directory
    const argv = [_][]const u8{
        "python3", "engines/nova2.py", "all", "all", query,
    };
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    // Run from the bundled resource root when installed (CWD is "/" from a
    // /Applications launch); null in dev keeps the inherited project-dir CWD.
    child.cwd = state.resourceRoot();
    _ = child.spawn() catch {
        logs.pushLog("warn", "resolver", "nova2.py spawn failed", false);
        return;
    };

    // Use the same reader.interface.takeDelimiter pattern that search.zig
    // uses — it's 0.16-native and known to work (drawer search pulls 200+
    // rows reliably). Byte-by-byte reads via our shim were dropping data
    // on pipe WouldBlock + reader-buffer resets.
    var child_reader_buf: [8192]u8 = undefined;
    var reader = child.stdout.?.reader(@import("../core/io_global.zig").io(), &child_reader_buf);

    var found: usize = 0;
    var scanned: usize = 0;
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch break orelse break;
        scanned += 1;
        // Keep draining the pipe to EOF even after we have enough — see the
        // wait() note below. We just stop parsing.
        if (found >= 25 or line.len < 10) continue;

        // Parse pipe-delimited: link|name|size|seeds|leech|engine
        var it = std.mem.splitScalar(u8, line, '|');
        const link = it.next() orelse continue;
        const name = it.next() orelse continue;
        _ = it.next(); // size
        const seeds_str = it.next() orelse continue;
        _ = it.next(); // leech
        const engine = it.next() orelse continue;

        if (name.len < 3 or link.len < 5) continue;

        var item = std.mem.zeroes(ResolvedItem);
        item.source = .torrent;

        const nlen = @min(name.len, 255);
        @memcpy(item.name[0..nlen], name[0..nlen]);
        item.name_len = nlen;

        const ulen = @min(link.len, 2047);
        @memcpy(item.url[0..ulen], link[0..ulen]);
        item.url_len = ulen;

        item.quality = detectQuality(name);
        item.seeds = std.fmt.parseInt(u16, seeds_str, 10) catch 0;

        // Clean engine name from URL
        var eng_buf: [32]u8 = undefined;
        var eng_name: []const u8 = engine;
        if (std.mem.indexOf(u8, engine, "://")) |_| {
            var s = engine;
            if (std.mem.indexOf(u8, s, "://")) |pi| s = s[pi + 3 ..];
            if (std.mem.startsWith(u8, s, "www.")) s = s[4..];
            var end: usize = s.len;
            for (s, 0..) |ch, j| {
                if (ch == '.' or ch == '/') {
                    end = j;
                    break;
                }
            }
            const elen = @min(end, 31);
            @memcpy(eng_buf[0..elen], s[0..elen]);
            eng_name = eng_buf[0..elen];
        }

        var det: [128]u8 = undefined;
        const dstr = std.fmt.bufPrint(&det, "Torrent · {s} · {s} seeds", .{ eng_name, seeds_str }) catch "Torrent";
        const dlen = @min(dstr.len, 127);
        @memcpy(item.detail[0..dlen], dstr[0..dlen]);
        item.detail_len = dlen;

        if (pushResult(item)) found += 1;
    }

    // Drain to EOF (above) and let nova2.py exit on its own, THEN reap. We used
    // to kill() it once we had 25 rows, but nova2 runs a multiprocessing pool —
    // SIGTERM mid-run left its workers writing into a dead pipe, spewing
    // BrokenPipeError tracebacks and leaking semaphores. Draining is what the
    // torrent-mode search does too, and it tears down cleanly. (The earlier
    // deadlock came from NOT draining before wait(); now we always drain.)
    _ = child.wait() catch {};
    {
        var slog: [64]u8 = undefined;
        const m = std.fmt.bufPrint(&slog, "nova2 scanned={d} pushed={d}", .{ scanned, found }) catch "nova2";
        logs.pushLog("info", "resolver", m, false);
    }
}

// ══════════════════════════════════════════════════════════
// Backend: Direct 1337x HTTP scrape (no Jackett/nova2 needed)
// ══════════════════════════════════════════════════════════

fn resolve1337x(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_1337x.store(.done, .release);
        checkAllDone();
    }

    const query = query_buf[0..qlen];

    // URL-encode query (replace spaces with +)
    var enc: [256]u8 = undefined;
    var el: usize = 0;
    for (query) |ch| {
        if (el + 3 >= enc.len) break;
        if (ch == ' ') {
            enc[el] = '+';
            el += 1;
        } else if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') {
            enc[el] = ch;
            el += 1;
        } else {
            enc[el] = '%';
            enc[el + 1] = "0123456789ABCDEF"[ch >> 4];
            enc[el + 2] = "0123456789ABCDEF"[ch & 0xF];
            el += 3;
        }
    }

    // Endpoint migrated to opal-plugins — inert until the user installs "1337x".
    const base = @import("../core/source_config.zig").get("1337x", "base") orelse return;

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/search/{s}/1/", .{ base, enc[0..el] }) catch return;

    // v2: throttle to ≤1 req/sec per origin so parallel queries don't trip rate limits.
    @import("../core/rate_limit.zig").acquire("1337x", 1.0);

    // Heap, not stack: the search page (128 KB) plus the per-result detail page
    // (another 128 KB) would put 256 KB of live buffers on this spawned worker's
    // 512 KB stack — close enough to overflow (with the other locals) to crash.
    // One reused det_buf for the whole result loop keeps it to two heap blocks.
    const page_buf = alloc.alloc(u8, 128 * 1024) catch return;
    defer alloc.free(page_buf);
    const det_buf = alloc.alloc(u8, 128 * 1024) catch return;
    defer alloc.free(det_buf);

    // Fetch search page
    const page = @import("../core/http.zig").fetch(url, page_buf, .{
        .timeout_secs = 8,
        .user_agent = "Mozilla/5.0",
    }) orelse return;
    const pn = page.len;
    if (pn < 100) return;

    // Parse result links: <a href="/torrent/12345/Title-Here/">
    var pos: usize = 0;
    var found: usize = 0;
    const link_prefix = "/torrent/";

    while (found < 10 and pos < pn) {
        const href_start = std.mem.indexOfPos(u8, page, pos, link_prefix) orelse break;
        // Find the enclosing <a> tag to get the title text
        const close_tag = std.mem.indexOfScalarPos(u8, page, href_start, '>') orelse {
            pos = href_start + 1;
            continue;
        };
        const href_end = std.mem.indexOfScalarPos(u8, page, href_start, '"') orelse close_tag;

        // Extract href path
        const href = page[href_start..href_end];
        if (href.len < 15) {
            pos = href_end + 1;
            continue;
        }

        // Extract title text between > and </a>
        const title_start = close_tag + 1;
        const title_end = std.mem.indexOfPos(u8, page, title_start, "</a>") orelse {
            pos = close_tag + 1;
            continue;
        };
        const raw_title = page[title_start..title_end];

        // Clean HTML tags from title (there might be nested spans)
        var clean_title: [256]u8 = undefined;
        var ct_len: usize = 0;
        var in_tag = false;
        for (raw_title) |ch| {
            if (ch == '<') {
                in_tag = true;
                continue;
            }
            if (ch == '>') {
                in_tag = false;
                continue;
            }
            if (!in_tag and ct_len < 255) {
                clean_title[ct_len] = ch;
                ct_len += 1;
            }
        }

        if (ct_len < 3) {
            pos = title_end + 1;
            continue;
        }

        // Extract seeds from the same row — look for <td class="coll-2 seeds">N</td>
        const seeds_marker = "seeds\">";
        var seeds_val: u16 = 0;
        if (std.mem.indexOfPos(u8, page, title_end, seeds_marker)) |sp| {
            const ss = sp + seeds_marker.len;
            const se = std.mem.indexOfScalarPos(u8, page, ss, '<') orelse ss;
            seeds_val = std.fmt.parseInt(u16, page[ss..se], 10) catch 0;
        }

        // Build full URL for magnet fetch
        var detail_url: [512]u8 = undefined;
        const du = std.fmt.bufPrint(&detail_url, "{s}{s}", .{ base, href }) catch {
            pos = title_end + 1;
            continue;
        };

        // Fetch the detail page to get magnet link (reuses the function-level
        // heap det_buf — overwritten each iteration, processed before the next).
        @import("../core/rate_limit.zig").acquire("1337x", 1.0);
        const det_page = @import("../core/http.zig").fetch(du, det_buf, .{
            .timeout_secs = 6,
            .user_agent = "Mozilla/5.0",
        }) orelse {
            pos = title_end + 1;
            continue;
        };
        const dn = det_page.len;

        // Find magnet link
        const magnet_prefix = "magnet:?xt=";
        if (dn > 50) {
            if (std.mem.indexOf(u8, det_buf[0..dn], magnet_prefix)) |mp| {
                const magnet_end = std.mem.indexOfScalarPos(u8, det_buf[0..dn], mp, '"') orelse
                    std.mem.indexOfScalarPos(u8, det_buf[0..dn], mp, '\'') orelse
                    @min(mp + 500, dn);
                const magnet = det_buf[mp..magnet_end];

                var item = std.mem.zeroes(ResolvedItem);
                item.source = .torrent;

                const nlen = @min(ct_len, 255);
                @memcpy(item.name[0..nlen], clean_title[0..nlen]);
                item.name_len = nlen;

                const ulen = @min(magnet.len, 2047);
                @memcpy(item.url[0..ulen], magnet[0..ulen]);
                item.url_len = ulen;

                item.quality = detectQuality(clean_title[0..ct_len]);
                item.seeds = seeds_val;

                var det: [128]u8 = undefined;
                const dstr = std.fmt.bufPrint(&det, "Torrent · 1337x · {d} seeds", .{seeds_val}) catch "Torrent · 1337x";
                const dlen = @min(dstr.len, 127);
                @memcpy(item.detail[0..dlen], dstr[0..dlen]);
                item.detail_len = dlen;

                _ = pushResult(item);
                found += 1;
            }
        }

        pos = title_end + 1;
    }

    if (found > 0) {
        logs.pushLog("info", "resolver", "1337x direct results found", false);
    }
}

// YTS API — fast movie search (runs in parallel)
fn resolveYts(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_yts.store(.done, .release);
        checkAllDone();
    }

    const query = query_buf[0..qlen];

    // URL-encode query — percent-encode all non-unreserved bytes ('+' for space)
    var enc: [512]u8 = undefined;
    const enc_q = @import("../core/http.zig").urlEncode(query, &enc);

    // Endpoint migrated to opal-plugins — inert until the user installs "yts".
    const api = @import("../core/source_config.zig").get("yts", "api") orelse return;

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}?query_term={s}&limit=8&sort_by=seeds", .{
        api, enc_q,
    }) catch return;

    var buf: [64 * 1024]u8 = undefined;
    @import("../core/rate_limit.zig").acquire("yts", 1.0);
    const body = @import("../core/http.zig").fetch(url, &buf, .{
        .timeout_secs = 6,
        .user_agent = "Opal/1.0",
    }) orelse return;
    const n = body.len;

    if (n < 50) return;

    // Parse YTS JSON: find "title_long" and "url" entries
    var pos: usize = 0;
    var found: usize = 0;
    while (pos < n and found < 8) {
        const title_key = "\"title_long\":\"";
        const next = std.mem.indexOf(u8, buf[pos..], title_key) orelse break;
        const abs = pos + next + title_key.len;
        const te = std.mem.indexOfScalarPos(u8, buf[0..n], abs, '"') orelse break;
        const title = buf[abs..te];

        // Find torrent URL in this movie block
        const hash_key = "\"hash\":\"";
        const hash_pos = std.mem.indexOfPos(u8, buf[0..n], te, hash_key) orelse {
            pos = te + 1;
            continue;
        };
        const hs = hash_pos + hash_key.len;
        const he = std.mem.indexOfScalarPos(u8, buf[0..n], hs, '"') orelse {
            pos = te + 1;
            continue;
        };
        const hash = buf[hs..he];

        // Find quality
        var quality_str: []const u8 = "";
        const qkey = "\"quality\":\"";
        if (std.mem.indexOfPos(u8, buf[0..n], te, qkey)) |qp| {
            const qs = qp + qkey.len;
            if (std.mem.indexOfScalarPos(u8, buf[0..n], qs, '"')) |qe| {
                quality_str = buf[qs..qe];
            }
        }

        if (title.len > 2 and hash.len > 5) {
            var item = std.mem.zeroes(ResolvedItem);
            item.source = .torrent;

            const nlen = @min(title.len, 255);
            @memcpy(item.name[0..nlen], title[0..nlen]);
            item.name_len = nlen;

            // Build magnet link from hash
            var magnet_buf: [512]u8 = undefined;
            const magnet = std.fmt.bufPrint(&magnet_buf, "magnet:?xt=urn:btih:{s}", .{hash}) catch "";
            const ulen = @min(magnet.len, 2047);
            @memcpy(item.url[0..ulen], magnet[0..ulen]);
            item.url_len = ulen;

            item.quality = detectQuality(title);

            var det: [128]u8 = undefined;
            const dstr = std.fmt.bufPrint(&det, "Torrent · YTS · {s}", .{quality_str}) catch "Torrent · YTS";
            const dlen = @min(dstr.len, 127);
            @memcpy(item.detail[0..dlen], dstr[0..dlen]);
            item.detail_len = dlen;

            _ = pushResult(item);
            found += 1;
        }
        pos = he + 1;
    }
}

// ══════════════════════════════════════════════════════════
// Backend: Torznab / Prowlarr / Jackett (generic self-hosted indexer)
//
// One adapter for the user's OWN self-hosted Prowlarr/Jackett: it aggregates
// every indexer the user has configured there via the standard Torznab endpoint,
// instead of hardcoding each tracker. Ships INERT — no endpoint is baked into
// the binary. The source stays silent until the user installs a marker at
// ~/.config/opal/plugins/sources/torznab.json supplying {base, apikey, indexer}.
// With no marker, get("torznab","base") is null → this returns immediately →
// zero network activity (neutral-ship). XML item parsing is routed through the
// tested torznab_pure.zig helpers.
// ══════════════════════════════════════════════════════════

fn resolveTorznab(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_torznab.store(.done, .release);
        checkAllDone();
    }

    const query = query_buf[0..qlen];
    const sc = @import("../core/source_config.zig");

    // Endpoint migrated to opal-plugins — inert until the user installs "torznab".
    // get() returns a slice into a static table that reload() can mutate, so copy
    // every config value into a local buffer before issuing the next get().
    const base_raw = sc.get("torznab", "base") orelse return;
    if (base_raw.len == 0 or base_raw.len > 512) return;
    var base_buf: [512]u8 = undefined;
    @memcpy(base_buf[0..base_raw.len], base_raw);
    var base: []const u8 = base_buf[0..base_raw.len];
    if (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1]; // strip trailing slash

    var key_buf: [256]u8 = undefined;
    var key_len: usize = 0;
    if (sc.get("torznab", "apikey")) |k| {
        if (k.len > 0 and k.len <= key_buf.len) {
            @memcpy(key_buf[0..k.len], k);
            key_len = k.len;
        }
    }

    var idx_buf: [64]u8 = undefined;
    var indexer: []const u8 = "all"; // default: query every configured indexer
    if (sc.get("torznab", "indexer")) |ix| {
        if (ix.len > 0 and ix.len <= idx_buf.len) {
            @memcpy(idx_buf[0..ix.len], ix);
            indexer = idx_buf[0..ix.len];
        }
    }

    // Percent-encode the query + apikey (both go in the query string) per CLAUDE.md.
    var q_enc: [512]u8 = undefined;
    const enc_q = @import("../core/http.zig").urlEncode(query, &q_enc);
    var k_enc: [512]u8 = undefined;
    const enc_k = @import("../core/http.zig").urlEncode(key_buf[0..key_len], &k_enc);

    // Standard Prowlarr/Jackett Torznab/Newznab search endpoint.
    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "{s}/api/v2.0/indexers/{s}/results/torznab/api?apikey={s}&t=search&q={s}",
        .{ base, indexer, enc_k, enc_q },
    ) catch return;

    // Heap, not stack: a Torznab response with many indexers can be large; keep
    // it off this spawned worker's 512 KB stack.
    const page_buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(page_buf);

    @import("../core/rate_limit.zig").acquire("torznab", 1.0);
    const body = @import("../core/http.zig").fetch(url, page_buf, .{
        .timeout_secs = 12,
        .user_agent = "Opal/1.0",
    }) orelse return;
    const n = body.len;
    if (n < 50) return;

    const tz = @import("torznab_pure.zig");

    var pos: usize = 0;
    var found: usize = 0;
    while (found < 20 and pos < n) {
        const item_start = std.mem.indexOfPos(u8, body, pos, "<item>") orelse break;
        const item_end = std.mem.indexOfPos(u8, body, item_start, "</item>") orelse break;
        const block = body[item_start..item_end];
        pos = item_end + 7; // skip "</item>"

        const title = tz.extractTag(block, "<title>", "</title>") orelse continue;
        if (title.len < 2) continue;

        const link = tz.pickLink(block) orelse continue; // magnet or .torrent url
        if (link.len < 8) continue;

        var item = std.mem.zeroes(ResolvedItem);
        item.source = .torrent;

        const nlen = @min(title.len, 255);
        @memcpy(item.name[0..nlen], title[0..nlen]);
        item.name_len = nlen;

        const ulen = @min(link.len, 2047);
        @memcpy(item.url[0..ulen], link[0..ulen]);
        item.url_len = ulen;

        item.quality = detectQuality(title);
        item.seeds = tz.seeders(block);

        var det: [128]u8 = undefined;
        const dstr = std.fmt.bufPrint(&det, "Torrent · Torznab · {d} seeds", .{item.seeds}) catch "Torrent · Torznab";
        const dlen = @min(dstr.len, 127);
        @memcpy(item.detail[0..dlen], dstr[0..dlen]);
        item.detail_len = dlen;

        _ = pushResult(item);
        found += 1;
    }

    if (found > 0) {
        logs.pushLog("info", "resolver", "torznab results found", false);
    }
}

// ══════════════════════════════════════════════════════════
// Backend: Internet Archive (archive.org public-domain / CC video)
//
// LEGAL, default-on direct-play source — no torrent, no source_config marker.
// advancedsearch.php gives us matching movie items; for each we hit
// metadata/{id} and pick the largest playable video file (archive_pure) so the
// emitted URL is a real https stream mpv can open — NOT the guessed
// "{id}.mp4" form (which 404s on most items). Results ride the .stremio source
// variant (HTTP-direct, plays via mpv load_file in playItem) and the Stremio
// filter pill. All JSON parsing is routed through the tested archive_pure.zig.
// ══════════════════════════════════════════════════════════

fn resolveArchive(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_archive.store(.done, .release);
        checkAllDone();
    }
    if (qlen == 0) return;

    const ap = @import("archive_pure.zig");
    const http = @import("../core/http.zig");
    const query = query_buf[0..qlen];

    // Intent-aware: a music/audiobook query searches IA's legal audio collections
    // (LibriVox public-domain audiobooks + etree trade-friendly live concerts)
    // and picks an audio file; every other intent keeps the default movies path
    // exactly as-is. The intent is the same global computeMatch reads (set before
    // any worker spawns); worker_gen still guards pushResult against stale waves.
    const audio_mode = ap.isAudioIntent(resolver_intent[0..resolver_intent_len]);

    // q value — percent-encode the whole thing (urlEncode handles the spaces,
    // parens and colons IA's Lucene query syntax needs). A broad audio-mediatype
    // filter is deliberately kept OUT of the default query — the audio path is
    // scoped to the two legal collections below.
    var q_raw: [512]u8 = undefined;
    const q_val = if (audio_mode)
        std.fmt.bufPrint(&q_raw, "{s} AND (collection:(librivoxaudio) OR collection:(etree))", .{query}) catch return
    else
        std.fmt.bufPrint(&q_raw, "{s} AND mediatype:(movies)", .{query}) catch return;
    var q_enc: [1024]u8 = undefined;
    const enc_q = http.urlEncode(q_val, &q_enc);

    // fl[] param names carry literal brackets (IA expects them); only the q
    // value is user data and is encoded above.
    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://archive.org/advancedsearch.php?q={s}&fl[]=identifier&fl[]=title&fl[]=year&rows=20&output=json",
        .{enc_q},
    ) catch return;

    // Heap the response — keep it off this spawned worker's 512 KB stack.
    const page = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(page);

    @import("../core/rate_limit.zig").acquire("archive", 1.0);
    const body = http.fetch(url, page, .{
        .timeout_secs = 8,
        .user_agent = "Opal/1.0",
    }) orelse return;
    if (body.len < 30) return;

    // Reused heap buffer for the per-item metadata fetch (bounded work: we only
    // resolve up to `max_hits` playable items, one extra fetch each).
    const meta_buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(meta_buf);

    const max_hits = 8;
    var found: usize = 0;
    var it = ap.iterateDocs(body);
    while (it.next()) |doc| {
        if (found >= max_hits) break;
        if (doc.identifier.len == 0 or doc.identifier.len > 512) continue;

        // Resolve the actual playable file via metadata/{id}.
        var meta_url: [640]u8 = undefined;
        var id_enc: [1024]u8 = undefined;
        const enc_id = http.urlEncode(doc.identifier, &id_enc);
        const murl = std.fmt.bufPrint(&meta_url, "https://archive.org/metadata/{s}", .{enc_id}) catch continue;

        @import("../core/rate_limit.zig").acquire("archive", 1.0);
        const meta = http.fetch(murl, meta_buf, .{
            .timeout_secs = 8,
            .user_agent = "Opal/1.0",
        }) orelse continue;
        if (meta.len < 20) continue;

        const file_name = if (audio_mode)
            ap.pickBestAudioFile(meta) orelse continue
        else
            ap.pickBestVideoFile(meta) orelse continue;

        // Build the direct-play URL: download/{id}/{file}. Percent-encode each
        // path segment (space→%20, NOT '+', which is literal in a path).
        var url_out: [2048]u8 = undefined;
        var w: usize = 0;
        const prefix = "https://archive.org/download/";
        @memcpy(url_out[0..prefix.len], prefix);
        w = prefix.len;
        w += encPathSegment(doc.identifier, url_out[w..]);
        if (w < url_out.len) {
            url_out[w] = '/';
            w += 1;
        }
        w += encPathSegment(file_name, url_out[w..]);
        if (w < 8) continue;

        // Title (fall back to identifier). JSON escapes are rare here; use raw.
        const raw_title = if (doc.title.len > 0) doc.title else doc.identifier;

        var item = std.mem.zeroes(ResolvedItem);
        item.source = .stremio; // HTTP-direct stream — plays via mpv load_file

        const nlen = @min(raw_title.len, 255);
        @memcpy(item.name[0..nlen], raw_title[0..nlen]);
        item.name_len = nlen;

        const ulen = @min(w, 2047);
        @memcpy(item.url[0..ulen], url_out[0..ulen]);
        item.url_len = ulen;

        item.quality = detectQuality(raw_title);

        var det: [128]u8 = undefined;
        const label = if (audio_mode) "Internet Archive · Audio" else "Internet Archive";
        const dstr = if (doc.year.len > 0)
            std.fmt.bufPrint(&det, "{s} · {s}", .{ label, doc.year }) catch label
        else
            std.fmt.bufPrint(&det, "{s}", .{label}) catch label;
        const dlen = @min(dstr.len, 127);
        @memcpy(item.detail[0..dlen], dstr[0..dlen]);
        item.detail_len = dlen;

        if (pushResult(item)) found += 1;
    }

    if (found > 0) {
        logs.pushLog("info", "resolver", "archive.org results found", false);
    }
}

/// Percent-encode a single URL path segment into `out`, returning bytes written.
/// Unreserved chars pass through; space and everything else become %XX (space →
/// %20, never '+' — '+' is a literal plus in a path segment). '/' is encoded so
/// a stray slash in a name can't split the path.
fn encPathSegment(seg: []const u8, out: []u8) usize {
    const hex = "0123456789ABCDEF";
    var w: usize = 0;
    for (seg) |ch| {
        if (w + 3 >= out.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            out[w] = ch;
            w += 1;
        } else {
            out[w] = '%';
            out[w + 1] = hex[ch >> 4];
            out[w + 2] = hex[ch & 0x0F];
            w += 3;
        }
    }
    return w;
}

/// Copy a JSON-string URL into `out`, undoing `\/` and `\\` escapes (MediaWiki's
/// default format=json escapes forward slashes) and rewriting an `http://`
/// prefix to `https://`. Returns bytes written (0 if it wouldn't fit).
fn writeSafeUrl(src: []const u8, out: []u8) usize {
    var tmp: [2048]u8 = undefined;
    var t: usize = 0;
    var i: usize = 0;
    while (i < src.len and t < tmp.len) : (i += 1) {
        if (src[i] == '\\' and i + 1 < src.len and (src[i + 1] == '/' or src[i + 1] == '\\')) {
            tmp[t] = src[i + 1];
            t += 1;
            i += 1;
            continue;
        }
        tmp[t] = src[i];
        t += 1;
    }
    const cleaned = tmp[0..t];
    // Upgrade http:// → https:// (NASA asset URLs, some Commons mirrors).
    var w: usize = 0;
    if (std.mem.startsWith(u8, cleaned, "http://")) {
        const https = "https://";
        if (https.len + (cleaned.len - "http://".len) > out.len) return 0;
        @memcpy(out[0..https.len], https);
        w = https.len;
        const rest = cleaned["http://".len..];
        @memcpy(out[w .. w + rest.len], rest);
        w += rest.len;
    } else {
        if (cleaned.len > out.len) return 0;
        @memcpy(out[0..cleaned.len], cleaned);
        w = cleaned.len;
    }
    return w;
}

// ══════════════════════════════════════════════════════════
// Backend: NASA image/video library (images-api.nasa.gov)
//
// LEGAL, default-on direct-play source — NASA media is public domain. Two-stage
// like Archive: a search returns collection.items[], each pointing at a
// per-asset collection.json we fetch to pick the best playable .mp4. The emitted
// URL is a real https stream mpv opens directly; results ride the .stremio
// source variant + Stremio filter pill. All JSON parsing is routed through the
// tested nasa_pure.zig.
// ══════════════════════════════════════════════════════════

fn resolveNasa(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_nasa.store(.done, .release);
        checkAllDone();
    }
    if (qlen == 0) return;

    const np = @import("nasa_pure.zig");
    const http = @import("../core/http.zig");
    const query = query_buf[0..qlen];

    var enc: [512]u8 = undefined;
    const enc_q = http.urlEncode(query, &enc);

    var url_buf: [640]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://images-api.nasa.gov/search?q={s}&media_type=video&page_size=10",
        .{enc_q},
    ) catch return;

    // Heap the response — keep it off this spawned worker's 512 KB stack.
    const page = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(page);

    @import("../core/rate_limit.zig").acquire("nasa", 1.0);
    const body = http.fetch(url, page, .{
        .timeout_secs = 8,
        .user_agent = "Opal/1.0 (https://github.com/debpalash/Opal)",
    }) orelse return;
    if (body.len < 30) return;

    // Reused heap buffer for the per-asset collection.json fetch (bounded work).
    const coll_buf = alloc.alloc(u8, 128 * 1024) catch return;
    defer alloc.free(coll_buf);

    const max_hits = 8;
    var found: usize = 0;
    var it = np.iterateItems(body);
    while (it.next()) |hit| {
        if (found >= max_hits) break;
        if (hit.href.len < 8 or hit.href.len > 1024) continue;
        if (hit.title.len == 0) continue; // no title → can't match query; skip

        // Fetch the asset's collection.json and pick the best .mp4.
        @import("../core/rate_limit.zig").acquire("nasa", 1.0);
        const coll = http.fetch(hit.href, coll_buf, .{
            .timeout_secs = 8,
            .user_agent = "Opal/1.0 (https://github.com/debpalash/Opal)",
        }) orelse continue;
        if (coll.len < 5) continue;

        const mp4 = np.pickBestMp4(coll) orelse continue;

        var url_out: [2048]u8 = undefined;
        const w = writeSafeUrl(mp4, &url_out);
        if (w < 12) continue;

        var item = std.mem.zeroes(ResolvedItem);
        item.source = .stremio; // HTTP-direct stream — plays via mpv load_file

        const nlen = @min(hit.title.len, 255);
        @memcpy(item.name[0..nlen], hit.title[0..nlen]);
        item.name_len = nlen;

        const ulen = @min(w, 2047);
        @memcpy(item.url[0..ulen], url_out[0..ulen]);
        item.url_len = ulen;

        item.quality = detectQuality(hit.title);

        var det: [128]u8 = undefined;
        const dstr = if (hit.year.len > 0)
            std.fmt.bufPrint(&det, "NASA · {s}", .{hit.year}) catch "NASA"
        else
            std.fmt.bufPrint(&det, "NASA", .{}) catch "NASA";
        const dlen = @min(dstr.len, 127);
        @memcpy(item.detail[0..dlen], dstr[0..dlen]);
        item.detail_len = dlen;

        if (pushResult(item)) found += 1;
    }

    if (found > 0) {
        logs.pushLog("info", "resolver", "NASA library results found", false);
    }
}

// ══════════════════════════════════════════════════════════
// Backend: Wikimedia Commons (commons.wikimedia.org MediaWiki API)
//
// LEGAL, default-on direct-play source — Commons hosts freely-licensed media. A
// SINGLE generator=search query returns query.pages{} where each page's
// imageinfo[0].url is the direct upload.wikimedia.org file (.webm/.ogv, mpv
// native). Results ride the .stremio source variant + Stremio filter pill. A
// descriptive User-Agent is sent per Wikimedia's UA policy. All JSON parsing is
// routed through the tested commons_pure.zig.
// ══════════════════════════════════════════════════════════

fn resolveCommons(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_commons.store(.done, .release);
        checkAllDone();
    }
    if (qlen == 0) return;

    const cp = @import("commons_pure.zig");
    const http = @import("../core/http.zig");
    const query = query_buf[0..qlen];

    var enc: [512]u8 = undefined;
    const enc_q = http.urlEncode(query, &enc);

    // gsrsearch = "filetype:video <query>"; iiprop separators (|) are %7C.
    var url_buf: [768]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://commons.wikimedia.org/w/api.php?action=query&generator=search" ++
            "&gsrsearch=filetype:video%20{s}&gsrnamespace=6&gsrlimit=10" ++
            "&prop=imageinfo&iiprop=url%7Csize%7Cmime&format=json",
        .{enc_q},
    ) catch return;

    // Heap the response — off this spawned worker's 512 KB stack.
    const page = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(page);

    @import("../core/rate_limit.zig").acquire("commons", 1.0);
    const body = http.fetch(url, page, .{
        .timeout_secs = 8,
        // Wikimedia UA policy requires a descriptive, contactable agent.
        .user_agent = "Opal/1.0 (https://github.com/debpalash/Opal)",
    }) orelse return;
    if (body.len < 30) return;

    const max_hits = 10;
    var found: usize = 0;
    var it = cp.iteratePages(body);
    while (it.next()) |pg| {
        if (found >= max_hits) break;
        if (pg.url.len < 12 or pg.url.len > 2000) continue;
        if (pg.title.len == 0) continue;

        var url_out: [2048]u8 = undefined;
        const w = writeSafeUrl(pg.url, &url_out);
        if (w < 12) continue;

        var item = std.mem.zeroes(ResolvedItem);
        item.source = .stremio; // HTTP-direct stream — plays via mpv load_file

        const nlen = @min(pg.title.len, 255);
        @memcpy(item.name[0..nlen], pg.title[0..nlen]);
        item.name_len = nlen;

        const ulen = @min(w, 2047);
        @memcpy(item.url[0..ulen], url_out[0..ulen]);
        item.url_len = ulen;

        item.quality = detectQuality(pg.title);

        const d = "Wikimedia Commons";
        @memcpy(item.detail[0..d.len], d);
        item.detail_len = d.len;

        if (pushResult(item)) found += 1;
    }

    if (found > 0) {
        logs.pushLog("info", "resolver", "Wikimedia Commons results found", false);
    }
}

// ══════════════════════════════════════════════════════════
// Backend: Anime (ani-cli search)
// ══════════════════════════════════════════════════════════

fn resolveAnime(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_anime.store(.done, .release);
        checkAllDone();
    }

    const query = query_buf[0..qlen];

    // Escape quotes and backslashes for JSON safety
    var safe_q: [256]u8 = undefined;
    var si: usize = 0;
    for (query) |ch| {
        if (si + 2 > safe_q.len) break;
        if (ch == '"') {
            safe_q[si] = '\\';
            si += 1;
            safe_q[si] = '"';
            si += 1;
        } else if (ch == '\\') {
            safe_q[si] = '\\';
            si += 1;
            safe_q[si] = '\\';
            si += 1;
        } else {
            safe_q[si] = ch;
            si += 1;
        }
    }

    // Use allanime GraphQL API directly (same as anime.zig) — never call ani-cli
    // which would auto-play
    const search_gql = "query( $search: SearchInput $limit: Int $page: Int $translationType: VaildTranslationTypeEnumType $countryOrigin: VaildCountryOriginEnumType ) { shows( search: $search limit: $limit page: $page translationType: $translationType countryOrigin: $countryOrigin ) { edges { _id name availableEpisodes __typename } }}";

    var vars_buf: [512]u8 = undefined;
    const vars = std.fmt.bufPrint(
        &vars_buf,
        "{{\"search\":{{\"allowAdult\":false,\"allowUnknown\":false,\"query\":\"{s}\"}},\"limit\":6,\"page\":1,\"translationType\":\"sub\",\"countryOrigin\":\"ALL\"}}",
        .{safe_q[0..si]},
    ) catch return;

    var vars_enc_buf: [1024]u8 = undefined;
    const vars_enc = @import("../core/http.zig").urlEncode(vars, &vars_enc_buf);

    var query_enc_buf: [1024]u8 = undefined;
    const query_enc = @import("../core/http.zig").urlEncode(search_gql, &query_enc_buf);

    var final_url_buf: [2048]u8 = undefined;
    const url = std.fmt.bufPrint(&final_url_buf, "https://api.allanime.day/api?variables={s}&query={s}", .{ vars_enc, query_enc }) catch return;

    var buf: [64 * 1024]u8 = undefined;
    @import("../core/rate_limit.zig").acquire("allanime", 1.0); // scrape-class — be gentle
    const body = @import("../core/http.zig").fetch(url, &buf, .{
        .timeout_secs = 8,
        .referer = "https://allmanga.to",
        .user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/121.0",
    }) orelse return;
    const n = body.len;

    if (n < 10) return;

    // Parse JSON: find "name":"..." entries
    var pos: usize = 0;
    var found: usize = 0;
    while (pos < n and found < 6) {
        const name_key = "\"name\":\"";
        const next = std.mem.indexOf(u8, buf[pos..], name_key) orelse break;
        const abs = pos + next + name_key.len;

        // Find end of name
        var name_end: usize = 0;
        var ni: usize = 0;
        while (abs + ni < n) : (ni += 1) {
            if (buf[abs + ni] == '"' and (ni == 0 or buf[abs + ni - 1] != '\\')) {
                name_end = ni;
                break;
            }
        }
        if (name_end == 0) {
            pos = abs + 1;
            continue;
        }

        const name = buf[abs .. abs + name_end];
        if (name.len > 2 and name.len < 256) {
            var item = std.mem.zeroes(ResolvedItem);
            item.source = .anime;

            const nlen = @min(name.len, 255);
            @memcpy(item.name[0..nlen], name[0..nlen]);
            item.name_len = nlen;
            // Store name as URL (anime.playEpisode needs the anime name)
            @memcpy(item.url[0..nlen], name[0..nlen]);
            item.url_len = nlen;

            const detail = "Anime - allanime";
            @memcpy(item.detail[0..detail.len], detail);
            item.detail_len = detail.len;

            _ = pushResult(item);
            found += 1;
        }
        pos = abs + name_end;
    }
}

// ══════════════════════════════════════════════════════════
// Backend: YouTube (yt-dlp search)
// ══════════════════════════════════════════════════════════

fn resolveYouTube(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_yt.store(.done, .release);
        checkAllDone();
    }

    const query = query_buf[0..qlen];
    var search_arg: [300]u8 = undefined;
    const sa = std.fmt.bufPrint(&search_arg, "ytsearch5:{s}", .{query}) catch return;

    const ytdlp_bin = @import("ytdlp.zig").binary();
    const argv = [_][]const u8{
        ytdlp_bin, "--flat-playlist", "--dump-json", "--no-warnings", sa,
    };
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;

    var buf: [64 * 1024]u8 = undefined;
    const n = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &buf) catch 0 else 0;
    _ = child.wait() catch {};

    if (n < 10) return;

    // Each line is a JSON object with "title", "url", "id"
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    var found: usize = 0;
    while (lines.next()) |line| {
        if (found >= 5 or line.len < 10) continue;

        var item = std.mem.zeroes(ResolvedItem);
        item.source = .youtube;

        if (extractStr(line, "\"title\": \"")) |title| {
            // yt-dlp titles carry JSON escapes (’ etc.) — decode them
            // or the UI shows "You’ve" literally.
            var unesc_buf: [256]u8 = undefined;
            const clean = @import("json_pure.zig").jsonUnescape(title, &unesc_buf);
            const tlen = @min(clean.len, 255);
            @memcpy(item.name[0..tlen], clean[0..tlen]);
            item.name_len = tlen;
        }
        if (extractStr(line, "\"url\": \"")) |url| {
            const ulen = @min(url.len, 2047);
            @memcpy(item.url[0..ulen], url[0..ulen]);
            item.url_len = ulen;
        } else if (extractStr(line, "\"id\": \"")) |vid_id| {
            var yt_url: [128]u8 = undefined;
            const yt = std.fmt.bufPrint(&yt_url, "https://www.youtube.com/watch?v={s}", .{vid_id}) catch "";
            const ulen = @min(yt.len, 2047);
            @memcpy(item.url[0..ulen], yt[0..ulen]);
            item.url_len = ulen;
        }

        if (item.name_len > 0 and item.url_len > 0) {
            const detail = "YouTube";
            @memcpy(item.detail[0..detail.len], detail);
            item.detail_len = detail.len;
            _ = pushResult(item);
            found += 1;
        }
    }
}

// ══════════════════════════════════════════════════════════
// Backend: Stremio (query installed addons via TMDB IMDB ID)
// ══════════════════════════════════════════════════════════

/// Parse S(\d+)E(\d+) from a query like "from s01e05" (case-insensitive).
/// Sets *season and *episode to 0 if not found.
fn parseSxxEyy(query: []const u8, out_season: *i32, out_episode: *i32) void {
    out_season.* = 0;
    out_episode.* = 0;
    var i: usize = 0;
    while (i < query.len) : (i += 1) {
        if (std.ascii.toLower(query[i]) != 's') continue;
        // Collect digits after 's'
        var se = i + 1;
        while (se < query.len and std.ascii.isDigit(query[se])) se += 1;
        if (se == i + 1) continue; // no digits
        if (se >= query.len or std.ascii.toLower(query[se]) != 'e') continue;
        var ee = se + 1;
        while (ee < query.len and std.ascii.isDigit(query[ee])) ee += 1;
        if (ee == se + 1) continue; // no episode digits
        out_season.* = std.fmt.parseInt(i32, query[i + 1 .. se], 10) catch continue;
        out_episode.* = std.fmt.parseInt(i32, query[se + 1 .. ee], 10) catch continue;
        return;
    }
}

fn resolveStremio(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_stremio.store(.done, .release);
        checkAllDone();
    }

    const stremio = @import("stremio.zig");
    // Neutral: query only the Stremio addons the user has installed via the
    // plugin manager (re-read each search so installs/uninstalls take effect).
    stremio.loadInstalledAddons();
    if (stremio.installed_count == 0) return;

    const query = query_buf[0..qlen];
    const api_key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];
    if (api_key.len == 0) return;

    // Parse season/episode from query (e.g. "from s01e05" → season=1, episode=5)
    var ep_season: i32 = 0;
    var ep_episode: i32 = 0;
    parseSxxEyy(query, &ep_season, &ep_episode);

    // ── Resolve TMDB ID → IMDB ID ──
    // Fast path when intent="tv": we already know the TMDB TV ID from the detail
    // view — skip the text search, use the stored ID directly for external_ids.
    var imdb_id: [16]u8 = undefined;
    var imdb_len: usize = 0;
    var stremio_type: []const u8 = "movie";

    const intent = resolver_intent[0..resolver_intent_len];
    const tv_id = state.app.tmdb.tv_id;

    if (std.mem.eql(u8, intent, "tv") and tv_id > 0) {
        // Direct external_ids lookup — one fewer TMDB API call
        stremio_type = "series";
        var ext_url: [256]u8 = undefined;
        const eurl = std.fmt.bufPrint(&ext_url, "/3/tv/{d}/external_ids", .{tv_id}) catch return;
        var buf2: [4096]u8 = undefined;
        @import("../core/rate_limit.zig").acquire("tmdb", 3.0);
        const n2 = @import("tmdb_api.zig").tmdbApiInto(eurl, api_key, &buf2);
        if (n2 < 10) return;
        if (extractStr(buf2[0..n2], "\"imdb_id\":\"")) |imdb| {
            imdb_len = @min(imdb.len, 15);
            @memcpy(imdb_id[0..imdb_len], imdb[0..imdb_len]);
        }
    } else {
        // General path: text search to find TMDB ID, then external_ids
        var enc: [512]u8 = undefined;
        var el: usize = 0;
        for (query) |ch| {
            if (el + 3 >= enc.len) break;
            if (ch == ' ') {
                enc[el] = '+';
                el += 1;
            } else if (ch == '%') {
                enc[el] = '%';
                enc[el + 1] = '2';
                enc[el + 2] = '5';
                el += 3;
            } else if (ch == '&') {
                enc[el] = '%';
                enc[el + 1] = '2';
                enc[el + 2] = '6';
                el += 3;
            } else if (ch == '=') {
                enc[el] = '%';
                enc[el + 1] = '3';
                enc[el + 2] = 'D';
                el += 3;
            } else if (ch == '#') {
                enc[el] = '%';
                enc[el + 1] = '2';
                enc[el + 2] = '3';
                el += 3;
            } else if (ch == '?') {
                enc[el] = '%';
                enc[el + 1] = '3';
                enc[el + 2] = 'F';
                el += 3;
            } else {
                enc[el] = ch;
                el += 1;
            }
        }

        var tmdb_url: [512]u8 = undefined;
        const turl = std.fmt.bufPrint(&tmdb_url, "/3/search/multi?query={s}&page=1", .{enc[0..el]}) catch return;

        var buf: [32 * 1024]u8 = undefined;
        @import("../core/rate_limit.zig").acquire("tmdb", 3.0);
        const n = @import("tmdb_api.zig").tmdbApiInto(turl, api_key, &buf);
        if (n < 20) return;

        var tmdb_id: [16]u8 = undefined;
        var tmdb_id_len: usize = 0;
        var media_type: [16]u8 = undefined;
        var media_type_len: usize = 0;

        if (extractNumStr(buf[0..n], "\"id\":")) |id_str| {
            const clen = @min(id_str.len, 15);
            @memcpy(tmdb_id[0..clen], id_str[0..clen]);
            tmdb_id_len = clen;
        }
        if (extractStr(buf[0..n], "\"media_type\":\"")) |mt| {
            const mtl = @min(mt.len, 15);
            @memcpy(media_type[0..mtl], mt[0..mtl]);
            media_type_len = mtl;
        }
        if (tmdb_id_len == 0) return;

        const mt_str = if (media_type_len > 0) media_type[0..media_type_len] else "movie";
        stremio_type = if (std.mem.eql(u8, mt_str, "tv")) "series" else "movie";

        var ext_url: [256]u8 = undefined;
        const eurl = std.fmt.bufPrint(&ext_url, "/3/{s}/{s}/external_ids", .{ mt_str, tmdb_id[0..tmdb_id_len] }) catch return;

        var buf2: [4096]u8 = undefined;
        @import("../core/rate_limit.zig").acquire("tmdb", 3.0);
        const n2 = @import("tmdb_api.zig").tmdbApiInto(eurl, api_key, &buf2);
        if (n2 < 10) return;

        if (extractStr(buf2[0..n2], "\"imdb_id\":\"")) |imdb| {
            imdb_len = @min(imdb.len, 15);
            @memcpy(imdb_id[0..imdb_len], imdb[0..imdb_len]);
        }
    }

    if (imdb_len == 0) return;

    // ── Query each installed addon ──
    for (0..stremio.installed_count) |ai| {
        const addon = &stremio.installed_addons[ai];
        const base = addon.url[0..addon.url_len];

        // Remove /manifest.json to get base URL
        var base_url: [256]u8 = undefined;
        const blen = if (std.mem.indexOf(u8, base, "/manifest.json")) |mp|
            @min(mp, 255)
        else
            @min(base.len, 255);
        @memcpy(base_url[0..blen], base[0..blen]);

        // Stremio series streams need {imdb_id}:{season}:{episode} per the protocol
        var stream_url: [512]u8 = undefined;
        const surl: []u8 = if (std.mem.eql(u8, stremio_type, "series") and ep_season > 0 and ep_episode > 0)
            std.fmt.bufPrint(&stream_url, "{s}/stream/{s}/{s}:{d}:{d}.json", .{
                base_url[0..blen], stremio_type, imdb_id[0..imdb_len], ep_season, ep_episode,
            }) catch continue
        else
            std.fmt.bufPrint(&stream_url, "{s}/stream/{s}/{s}.json", .{
                base_url[0..blen], stremio_type, imdb_id[0..imdb_len],
            }) catch continue;

        var sbuf: [64 * 1024]u8 = undefined;
        @import("../core/rate_limit.zig").acquire("stremio", 1.0); // third-party addon — be gentle
        const s_body = @import("../core/http.zig").fetch(surl, &sbuf, .{ .timeout_secs = 8 }) orelse continue;
        const sn = s_body.len;

        if (sn < 20) continue;

        // Parse streams
        var spos: usize = 0;
        while (spos < sn) {
            const url_key = "\"url\":\"";
            const next = std.mem.indexOf(u8, sbuf[spos..], url_key) orelse break;
            const uabs = spos + next + url_key.len;
            const ue = std.mem.indexOfScalar(u8, sbuf[uabs..], '"') orelse break;

            var item = std.mem.zeroes(ResolvedItem);
            item.source = .stremio;

            const ulen = @min(ue, 2047);
            @memcpy(item.url[0..ulen], sbuf[uabs .. uabs + ulen]);
            item.url_len = ulen;

            // Get title
            if (std.mem.lastIndexOf(u8, sbuf[spos .. spos + next], "\"title\":\"")) |tp| {
                const tabs = spos + tp + 9;
                const tee = std.mem.indexOfScalar(u8, sbuf[tabs..], '"') orelse 0;
                const tlen = @min(tee, 255);
                @memcpy(item.name[0..tlen], sbuf[tabs .. tabs + tlen]);
                item.name_len = tlen;
            }

            if (item.name_len == 0) {
                // Fall back to addon name
                const aname = addon.name[0..addon.name_len];
                var fallback: [128]u8 = undefined;
                const fb = std.fmt.bufPrint(&fallback, "Stream from {s}", .{aname}) catch "Stream";
                const fblen = @min(fb.len, 255);
                @memcpy(item.name[0..fblen], fb[0..fblen]);
                item.name_len = fblen;
            }

            // Detail
            {
                const aname = addon.name[0..addon.name_len];
                const det = std.fmt.bufPrint(&item.detail, "Stremio · {s}", .{aname}) catch "Stremio";
                item.detail_len = det.len;
            }

            item.quality = detectQuality(item.name[0..item.name_len]);
            if (item.url_len > 0) _ = pushResult(item);
            spos = uabs + ue;
        }

        // Torrentio (and similar) without debrid returns "infoHash" with no "url".
        // Convert each infoHash to a magnet link so it can be fed to the torrent engine.
        var ih_pos: usize = 0;
        while (ih_pos < sn) {
            const ih_key = "\"infoHash\":\"";
            const ih_next = std.mem.indexOf(u8, sbuf[ih_pos..sn], ih_key) orelse break;
            const ih_abs = ih_pos + ih_next + ih_key.len;
            const ih_end = std.mem.indexOfScalar(u8, sbuf[ih_abs..sn], '"') orelse break;
            const hash = sbuf[ih_abs .. ih_abs + ih_end];
            // Valid SHA-1 info hash is exactly 40 hex chars; SHA-256 is 64
            if (hash.len >= 40 and hash.len <= 64) {
                var ih_item = std.mem.zeroes(ResolvedItem);
                ih_item.source = .stremio;
                var mag_buf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&mag_buf, "magnet:?xt=urn:btih:{s}", .{hash})) |mag| {
                    const mlen = @min(mag.len, 2047);
                    @memcpy(ih_item.url[0..mlen], mag[0..mlen]);
                    ih_item.url_len = mlen;
                    // Look backward in this chunk for a "title" field
                    const look_start = if (ih_next > 512) ih_pos + ih_next - 512 else ih_pos;
                    if (std.mem.lastIndexOf(u8, sbuf[look_start .. ih_pos + ih_next], "\"title\":\"")) |tp| {
                        const tabs = look_start + tp + 9;
                        const tee = std.mem.indexOfScalar(u8, sbuf[tabs..sn], '"') orelse 0;
                        const tlen = @min(tee, 255);
                        @memcpy(ih_item.name[0..tlen], sbuf[tabs .. tabs + tlen]);
                        ih_item.name_len = tlen;
                    }
                    if (ih_item.name_len == 0) {
                        const aname = addon.name[0..addon.name_len];
                        var fb: [128]u8 = undefined;
                        const fbs = std.fmt.bufPrint(&fb, "Stream from {s}", .{aname}) catch "Stream";
                        const fbl = @min(fbs.len, 255);
                        @memcpy(ih_item.name[0..fbl], fbs[0..fbl]);
                        ih_item.name_len = fbl;
                    }
                    const aname = addon.name[0..addon.name_len];
                    const det = std.fmt.bufPrint(&ih_item.detail, "Stremio · {s}", .{aname}) catch "Stremio";
                    ih_item.detail_len = det.len;
                    ih_item.quality = detectQuality(ih_item.name[0..ih_item.name_len]);
                    _ = pushResult(ih_item);
                } else |_| {}
            }
            ih_pos = ih_abs + ih_end;
        }
    }
}

// ══════════════════════════════════════════════════════════
// Play a resolved item
// ══════════════════════════════════════════════════════════

pub fn playItem(idx: usize) void {
    if (idx >= result_count) return;
    const item = &results[idx];

    switch (item.source) {
        .jellyfin => {
            const jf = @import("jellyfin.zig");
            jf.playItem(item.jf_item_id[0..item.jf_item_id_len]);
            state.gotoPlayer();
        },
        .torrent => {
            // Central chokepoint for torrent playback from universal results —
            // row clicks and play buttons all land here, so a scam-flagged
            // name (exe/scr "movie", archive bait, …) is refused in one place.
            const risk = @import("torrent_risk_pure.zig").assess(item.name[0..item.name_len], 0);
            if (risk.risk == .block) {
                var tb: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&tb, "Blocked scam torrent: {s}", .{risk.reason}) catch "Blocked scam torrent";
                state.showToastTyped(msg, .err);
                @import("../core/logs.zig").pushLog("warn", "search", msg, false);
                return;
            }
            // URL is a 1337x detail page — need to resolve magnet
            // For now, load directly (the search.zig loadTorrentToPlayer handles magnets)
            const url = item.url[0..item.url_len];
            if (std.mem.startsWith(u8, url, "magnet:") or
                std.mem.startsWith(u8, url, "http://") or
                std.mem.startsWith(u8, url, "https://"))
            {
                // loadTorrentToPlayer handles magnets directly and resolves
                // http(s) detail-page URLs to a magnet in the background.
                const search = @import("search.zig");
                search.loadTorrentToPlayer(url);
            } else {
                state.showToast("Open in browser to get magnet link");
            }
        },
        .anime => {
            const anime = @import("anime.zig");
            anime.playEpisode(item.url[0..item.url_len]);
            state.gotoPlayer();
        },
        .comics => {
            // Load the issue and reveal the Browse › Comics reader (comics read
            // inside the Comics tab now, not the player route).
            const comics = @import("comics.zig");
            comics.loadComic(item.url[0..item.url_len]);
            state.navigateToTab(.Comics);
        },
        .tmdb => {
            // Catalog stub, not directly playable — kick off a universal source
            // search for its title so the user can pick a real stream. Must use
            // submitQuery (resolver fan-out) so results land in the universal view.
            @import("search.zig").submitQuery(item.name[0..item.name_len]);
        },
        .youtube, .stremio, .local => {
            // Direct URL / local path — load into mpv.
            if (state.app.active_player_idx < state.app.players.items.len) {
                const p = state.app.players.items[state.app.active_player_idx];
                p.provider = .mpv;
                var url_z: [2049]u8 = undefined;
                const ulen = item.url_len;
                @memcpy(url_z[0..ulen], item.url[0..ulen]);
                url_z[ulen] = 0;
                p.load_file(@ptrCast(&url_z[0]));
                state.gotoPlayer();
            }
        },
    }
}

// ══════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════

fn detectQuality(name: []const u8) u8 {
    var lower: [256]u8 = undefined;
    const clen = @min(name.len, 255);
    for (0..clen) |i| lower[i] = std.ascii.toLower(name[i]);
    const l = lower[0..clen];

    if (std.mem.indexOf(u8, l, "2160p") != null or std.mem.indexOf(u8, l, "4k") != null) return 4;
    if (std.mem.indexOf(u8, l, "1080p") != null) return 3;
    if (std.mem.indexOf(u8, l, "720p") != null) return 2;
    if (std.mem.indexOf(u8, l, "480p") != null) return 1;
    return 0;
}

fn extractStr(data: []const u8, key: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, data, key) orelse return null) + key.len;
    if (start >= data.len) return null;
    const end = std.mem.indexOfScalar(u8, data[start..], '"') orelse return null;
    return data[start .. start + end];
}

fn extractNumStr(data: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, data, key) orelse return null;
    const start = ki + key.len;
    if (start >= data.len) return null;
    // Find end: next comma, brace, bracket, or whitespace
    var end = start;
    while (end < data.len) : (end += 1) {
        switch (data[end]) {
            ',', '}', ']', ' ', '\n' => break,
            else => {},
        }
    }
    if (end == start) return null;
    return data[start..end];
}

fn findObjEnd(data: []const u8, start: usize) usize {
    var depth: i32 = 0;
    var i = start;
    while (i < data.len) : (i += 1) {
        if (data[i] == '{') depth += 1;
        if (data[i] == '}') {
            depth -= 1;
            if (depth <= 0) return i + 1;
        }
    }
    return data.len;
}
