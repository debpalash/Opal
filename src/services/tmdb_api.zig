const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const http = @import("../core/http.zig");
const parse = @import("tmdb_parse.zig");

const alloc = parse.alloc;

// ══════════════════════════════════════════════════════════
// Unified Fetch Logic
// ══════════════════════════════════════════════════════════

pub fn fetchCurrentView(append: bool) void {
    if (state.app.tmdb.is_loading.load(.acquire)) return;
    if (state.app.tmdb.api_key_len == 0) return;

    // SWR: stamp the cache time on a fresh (non-append) load so revisits within
    // the TTL skip the network (see browse_cache + renderTmdbContent).
    if (!append) state.app.tmdb.last_fetch_s = @import("browse_cache.zig").now();

    // CRITICAL: reserve a large, STABLE capacity for the results buffer once,
    // up front (before any poster-fetch worker thread can hold a *TmdbItem into
    // it). Poster workers write ptr.poster_w/_pixels asynchronously; if a later
    // page append() reallocated the buffer, those pointers would dangle → crash
    // (seen with infinite scroll). With capacity reserved here and appends
    // capped below it (see renderGallery), append never reallocates.
    state.app.tmdb.results.ensureTotalCapacity(alloc, 2048) catch {};

    if (state.app.tmdb.view == .Search) {
        const qlen = std.mem.indexOfScalar(u8, &state.app.tmdb.search_buf, 0) orelse 0;
        if (qlen > 0) {
            fetchTmdb(.search, state.app.tmdb.search_buf[0..qlen], append);
        }
    } else {
        fetchTmdb(.browse, "", append);
    }
}

const FetchMode = enum { search, browse };

fn fetchTmdb(mode: FetchMode, query: []const u8, append: bool) void {
    if (state.app.tmdb.is_loading.load(.acquire)) return;
    state.app.tmdb.is_loading.store(true, .release);

    const S = struct {
        var fetch_mode: FetchMode = .browse;
        var q: [256]u8 = undefined;
        var q_len: usize = 0;
        var do_append: bool = false;
        var category: state.TmdbCategory = .trending;
        var media_filter: state.TmdbMediaFilter = .all;
        var time_window: state.TmdbTimeWindow = .week;
        var page: u32 = 1;
    };

    S.fetch_mode = mode;
    S.do_append = append;
    S.category = state.app.tmdb.category;
    S.media_filter = state.app.tmdb.media_filter;
    S.time_window = state.app.tmdb.time_window;
    S.page = state.app.tmdb.page;
    if (query.len > 0) {
        const ql = @min(query.len, 255);
        @memcpy(S.q[0..ql], query[0..ql]);
        S.q_len = ql;
    } else {
        S.q_len = 0;
    }

    state.app.tmdb.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                state.app.tmdb.is_loading.store(false, .release);
            }

            const key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];

            var url_buf: [512]u8 = undefined;
            const url = buildApiUrl(&url_buf, S.fetch_mode, S.q[0..S.q_len], S.category, S.media_filter, S.time_window, S.page) orelse return;

            const body = httpGet(url, key) orelse return;
            defer alloc.free(body);

            if (!S.do_append) {
                state.app.tmdb.results.clearRetainingCapacity();
            }

            state.app.tmdb.total_pages = @intCast(@max(1, parse.extractJsonInt(body, "\"total_pages\":")));
            parse.parseTmdbResponse(body);
        }
    }.worker, .{}) catch blk: {
        state.app.tmdb.is_loading.store(false, .release);
        break :blk null;
    };
    if (state.app.tmdb.thread) |t| t.detach(); // never joined — detach to avoid leaking the handle
}

fn buildApiUrl(buf: *[512]u8, mode: FetchMode, query: []const u8, cat: state.TmdbCategory, mf: state.TmdbMediaFilter, tw: state.TmdbTimeWindow, page: u32) ?[]const u8 {
    const trending_mt = switch (mf) {
        .all => "all",
        .movie => "movie",
        .tv => "tv",
    };
    const list_mt = switch (mf) {
        .all => "movie",
        .movie => "movie",
        .tv => "tv",
    };
    const tw_str = switch (tw) {
        .day => "day",
        .week => "week",
    };

    if (mode == .search) {
        var enc_buf: [256]u8 = undefined;
        const enc = http.urlEncode(query, &enc_buf);
        const search_type = switch (mf) {
            .all => "multi",
            .movie => "movie",
            .tv => "tv",
        };
        return std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/search/{s}?query={s}&page={d}", .{ search_type, enc, page }) catch null;
    }

    return switch (cat) {
        .trending => std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/trending/{s}/{s}?page={d}", .{ trending_mt, tw_str, page }) catch null,
        .popular => std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/{s}/popular?page={d}", .{ list_mt, page }) catch null,
        .top_rated => std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/{s}/top_rated?page={d}", .{ list_mt, page }) catch null,
        .now_playing => std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/movie/now_playing?page={d}", .{page}) catch null,
        .upcoming => std.fmt.bufPrint(buf, "https://api.themoviedb.org/3/movie/upcoming?page={d}", .{page}) catch null,
    };
}

// ══════════════════════════════════════════════════════════
// Genre Discover
// ══════════════════════════════════════════════════════════

/// Fetch movies by TMDB genre ID (e.g. 28 = Action, 878 = Sci-Fi).
/// Populates the same results grid as the search/browse views.
pub fn fetchDiscover(genre_id: u32) void {
    if (state.app.tmdb.is_loading.load(.acquire)) return;
    if (state.app.tmdb.api_key_len == 0) return;
    state.app.tmdb.is_loading.store(true, .release);

    const S = struct {
        var gid: u32 = 0;
    };
    S.gid = genre_id;

    state.app.tmdb.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                state.app.tmdb.is_loading.store(false, .release);
            }
            const key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];
            var url_buf: [512]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://api.themoviedb.org/3/discover/movie?with_genres={d}&sort_by=popularity.desc&page=1", .{S.gid}) catch return;

            const body = httpGet(url, key) orelse return;
            defer alloc.free(body);

            state.app.tmdb.results.clearRetainingCapacity();
            state.app.tmdb.total_pages = @intCast(@max(1, parse.extractJsonInt(body, "\"total_pages\":")));
            parse.parseTmdbResponse(body);
        }
    }.worker, .{}) catch blk: {
        state.app.tmdb.is_loading.store(false, .release);
        break :blk null;
    };
    if (state.app.tmdb.thread) |t| t.detach(); // never joined — detach to avoid leaking the handle
}

// ══════════════════════════════════════════════════════════
// Poster Fetching
// ══════════════════════════════════════════════════════════

pub fn fetchPoster(item: *state.TmdbItem) void {
    if (item.poster_path_len == 0 or item.poster_fetching) return;
    // Route through the shared poster daemon: it carries the global concurrency
    // cap (no fetch storm when the infinite-scroll grid is flung), usize-first
    // pixel math (no i32 w*h*4 overflow), and the torn-publish guard — all of
    // which this provider's hand-rolled worker was missing.
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://image.tmdb.org/t/p/w185{s}", .{item.poster_path[0..item.poster_path_len]}) catch return;
    @import("../core/poster.zig").fetchAsync(url, &item.poster_pixels, &item.poster_w, &item.poster_h, &item.poster_fetching);
}

/// Sticky flag: some networks SNI-block api.themoviedb.org over HTTPS (the TLS
/// ClientHello is reset). Once we've seen HTTPS fail and HTTP succeed, prefer
/// HTTP for the rest of the session so we don't pay a failed HTTPS attempt each
/// call. (image.tmdb.org is a different host and is not blocked, so posters stay
/// HTTPS.) Shared with tmdb.zig's TV-detail fetch.
pub var tmdb_https_blocked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn curlIntoOnce(url: []const u8, auth_header: []const u8, buf: []u8) usize {
    const io_g = @import("../core/io_global.zig");
    var child = if (auth_header.len > 0)
        io_g.Child.init(&.{ "curl", "-s", "-H", auth_header, "--max-time", "12", url }, alloc)
    else
        io_g.Child.init(&.{ "curl", "-s", "--max-time", "12", url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io_g.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

/// curl `url` (HTTPS) into `buf`, with an HTTPS→HTTP fallback for SNI-blocked
/// networks. CRITICAL: a response is only accepted if it looks like JSON — some
/// ISPs hijack plain HTTP to api.themoviedb.org and inject an HTML block page
/// (200 OK). Treating that HTML as success poisoned `tmdb_https_blocked` (sticky)
/// and routed every later call to the block page → all content stopped loading.
/// The flag now self-heals: it clears whenever HTTPS returns JSON again.
fn curlFallbackInto(url: []const u8, auth_header: []const u8, buf: []u8) usize {
    const pure = @import("tmdb_pure.zig");
    var hb: [768]u8 = undefined;
    const http_url = pure.httpsToHttp(url, &hb);

    // Known-blocked: try HTTP first, but only trust valid JSON. If HTTP no longer
    // returns JSON (ISP now hijacks HTTP too), fall through and re-try HTTPS.
    if (tmdb_https_blocked.load(.acquire)) {
        if (http_url) |hu| {
            const n = curlIntoOnce(hu, auth_header, buf);
            if (n > 0 and pure.looksLikeJson(buf[0..n])) return n;
        }
    }

    const n = curlIntoOnce(url, auth_header, buf); // HTTPS
    if (n > 0 and pure.looksLikeJson(buf[0..n])) {
        tmdb_https_blocked.store(false, .release); // HTTPS works — clear any stale block
        return n;
    }

    if (http_url) |hu| {
        const m = curlIntoOnce(hu, auth_header, buf);
        if (m > 0 and pure.looksLikeJson(buf[0..m])) {
            tmdb_https_blocked.store(true, .release); // genuine SNI-block network
            return m;
        }
    }
    return 0;
}

/// Fetch a TMDB API endpoint into `buf`, picking the auth mechanism by key shape:
/// a v4 Read-Access-Token (JWT) goes in `Authorization: Bearer`, a v3 key in the
/// `?api_key=` query param. `path_query` is the part after the host with NO auth,
/// e.g. "/3/search/multi?query=batman&page=1". Returns bytes written (0 on fail).
/// Use this (not http.fetch/std.http) for api.themoviedb.org — std.http
/// SEGV-crashes on the TLS reset that SNI-blocked networks return.
pub fn tmdbApiInto(path_query: []const u8, key: []const u8, buf: []u8) usize {
    const v4 = @import("tmdb_pure.zig").keyIsV4(key);

    var url_buf: [768]u8 = undefined;
    const url = if (v4)
        std.fmt.bufPrint(&url_buf, "https://api.themoviedb.org{s}", .{path_query}) catch return 0
    else blk: {
        const sep: u8 = if (std.mem.indexOfScalar(u8, path_query, '?') != null) '&' else '?';
        break :blk std.fmt.bufPrint(&url_buf, "https://api.themoviedb.org{s}{c}api_key={s}", .{ path_query, sep, key }) catch return 0;
    };

    var auth_buf: [320]u8 = undefined;
    const auth: []const u8 = if (v4)
        (std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{key}) catch return 0)
    else
        "";

    return curlFallbackInto(url, auth, buf);
}

fn httpGet(url: []const u8, bearer_token: []const u8) ?[]u8 {
    var auth_buf: [320]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{bearer_token}) catch return null;
    // Route through the shared HTTPS→HTTP fallback so the browse tab gets the same
    // JSON validation (rejects ISP block pages) + sticky-flag self-heal.
    const buf = alloc.alloc(u8, 256 * 1024) catch return null;
    defer alloc.free(buf);
    const n = curlFallbackInto(url, auth, buf);
    if (n == 0) return null;
    return alloc.dupe(u8, buf[0..n]) catch null;
}
