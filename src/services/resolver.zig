const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const c = @import("../core/c.zig");
const logs = @import("../core/logs.zig");

const alloc = @import("../core/alloc.zig").allocator;

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

// Explicit u8 backing so std.atomic.Value(SourceStatus) is byte-atomic.
pub const SourceStatus = enum(u8) { idle, searching, done, failed };

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
    if (query.len == 0 or is_resolving.load(.acquire)) return;

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
    results_mutex.unlock();

    is_resolving.store(true, .release);
    // IMPORTANT: Set ALL to .searching BEFORE spawning any thread.
    // Otherwise a fast-finishing thread (e.g. no Jellyfin) calls
    // checkAllDone() before others start → premature is_resolving=false.
    status_jf.store(.searching, .release);
    status_stremio.store(.searching, .release);
    status_torrent.store(.searching, .release);
    status_anime.store(.searching, .release);
    status_yt.store(.searching, .release);
    status_1337x.store(.searching, .release);
    status_yts.store(.searching, .release);
    status_local.store(.searching, .release);
    status_rss.store(.searching, .release);
    status_comics.store(.searching, .release);

    // Fire every backend in parallel. Each handle is detached (never joined) —
    // discarding it via `_ =` leaks the pthread resource for the process life.
    const Spawn = struct {
        fn go(comptime f: anytype, st: *std.atomic.Value(SourceStatus)) void {
            if (std.Thread.spawn(.{}, f, .{ resolver_query, resolver_query_len })) |t| {
                t.detach();
            } else |_| {
                st.store(.failed, .release);
                checkAllDone();
            }
        }
    };
    Spawn.go(resolveLocalFiles, &status_local); // instant — already on disk
    Spawn.go(resolveRss, &status_rss); // already-fetched magnets matching query
    Spawn.go(resolveJellyfin, &status_jf);
    Spawn.go(resolveTorrentsNova2, &status_torrent);
    Spawn.go(resolve1337x, &status_1337x);
    Spawn.go(resolveYts, &status_yts);
    Spawn.go(resolveAnime, &status_anime);
    Spawn.go(resolveYouTube, &status_yt);
    Spawn.go(resolveComics, &status_comics); // readallcomics.com HTML scrape
    Spawn.go(resolveStremio, &status_stremio); // needs IMDB id — TMDB then addons
}

fn pushResult(item: ResolvedItem) bool {
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

fn checkAllDone() void {
    if (status_jf.load(.acquire) != .searching and status_stremio.load(.acquire) != .searching and
        status_torrent.load(.acquire) != .searching and status_anime.load(.acquire) != .searching and
        status_yt.load(.acquire) != .searching and status_1337x.load(.acquire) != .searching and
        status_yts.load(.acquire) != .searching and status_local.load(.acquire) != .searching and
        status_rss.load(.acquire) != .searching and status_comics.load(.acquire) != .searching)
    {
        is_resolving.store(false, .release);
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

    const raw = relevance + source_w + quality_bonus;
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
        .user_agent = "ZigZag/1.0",
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
            const tlen = @min(title.len, 255);
            @memcpy(item.name[0..tlen], title[0..tlen]);
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

fn resolveStremio(query_buf: [256]u8, qlen: usize) void {
    defer {
        status_stremio.store(.done, .release);
        checkAllDone();
    }

    const stremio = @import("stremio.zig");
    // Lazily install the well-known addons so the stremio source works
    // out of the box without separate UI wiring (S15). Idempotent.
    stremio.ensureDefaultAddons();
    if (stremio.installed_count == 0) return;

    const query = query_buf[0..qlen];

    // First, search TMDB to get IMDB ID
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

    const api_key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];
    if (api_key.len == 0) return;

    var tmdb_url: [512]u8 = undefined;
    const turl = std.fmt.bufPrint(&tmdb_url, "/3/search/multi?query={s}&page=1", .{enc[0..el]}) catch return;

    var buf: [32 * 1024]u8 = undefined;
    @import("../core/rate_limit.zig").acquire("tmdb", 3.0);
    // curl + HTTPS→HTTP fallback; tmdbApiInto picks Bearer (v4 JWT) vs ?api_key=
    // (v3) by key shape and rejects ISP HTML block pages.
    const n = @import("tmdb_api.zig").tmdbApiInto(turl, api_key, &buf);

    if (n < 20) return;

    // Find first result with an IMDB ID (via external_ids endpoint)
    // First get the TMDB ID and media type
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

    // Fetch external IDs to get IMDB ID
    const mt_str = if (media_type_len > 0) media_type[0..media_type_len] else "movie";
    var ext_url: [256]u8 = undefined;
    const eurl = std.fmt.bufPrint(&ext_url, "/3/{s}/{s}/external_ids", .{ mt_str, tmdb_id[0..tmdb_id_len] }) catch return;

    var buf2: [4096]u8 = undefined;
    @import("../core/rate_limit.zig").acquire("tmdb", 3.0);
    const n2 = @import("tmdb_api.zig").tmdbApiInto(eurl, api_key, &buf2);
    if (n2 == 0) return;

    if (n2 < 10) return;

    var imdb_id: [16]u8 = undefined;
    var imdb_len: usize = 0;
    if (extractStr(buf2[0..n2], "\"imdb_id\":\"")) |imdb| {
        imdb_len = @min(imdb.len, 15);
        @memcpy(imdb_id[0..imdb_len], imdb[0..imdb_len]);
    }

    if (imdb_len == 0) return;

    // Now query each installed addon
    const stremio_type = if (std.mem.eql(u8, mt_str, "tv")) "series" else "movie";

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

        var stream_url: [512]u8 = undefined;
        const surl = std.fmt.bufPrint(&stream_url, "{s}/stream/{s}/{s}.json", .{
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
