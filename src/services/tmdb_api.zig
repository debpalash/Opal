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
    if (state.app.tmdb.is_loading) return;
    if (state.app.tmdb.api_key_len == 0) return;

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
    if (state.app.tmdb.is_loading) return;
    state.app.tmdb.is_loading = true;

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
                state.app.tmdb.is_loading = false;
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
        state.app.tmdb.is_loading = false;
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
    if (state.app.tmdb.is_loading) return;
    if (state.app.tmdb.api_key_len == 0) return;
    state.app.tmdb.is_loading = true;

    const S = struct {
        var gid: u32 = 0;
    };
    S.gid = genre_id;

    state.app.tmdb.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                state.app.tmdb.is_loading = false;
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
        state.app.tmdb.is_loading = false;
        break :blk null;
    };
    if (state.app.tmdb.thread) |t| t.detach(); // never joined — detach to avoid leaking the handle
}

// ══════════════════════════════════════════════════════════
// Poster Fetching
// ══════════════════════════════════════════════════════════

pub fn fetchPoster(item: *state.TmdbItem) void {
    if (item.poster_path_len == 0 or item.poster_fetching) return;
    item.poster_fetching = true;

    if (std.Thread.spawn(.{}, struct {
        fn worker(ptr: *state.TmdbItem) void {
            defer ptr.poster_fetching = false;

            var url_buf: [256]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://image.tmdb.org/t/p/w185{s}", .{ptr.poster_path[0..ptr.poster_path_len]}) catch return;

            const img_buf = alloc.alloc(u8, 512 * 1024) catch return;
            defer alloc.free(img_buf);
            const img_content = @import("../core/http.zig").fetchImage(url, img_buf) orelse return;
            const img_len = img_content.len;

            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            const pixels = dvui.c.stbi_load_from_memory(img_buf[0..img_len].ptr, @intCast(img_len), &w, &h, &comp, 4);
            if (pixels == null) return;
            defer dvui.c.stbi_image_free(pixels);

            const p_len: usize = @intCast(w * h * 4);
            const p_slice = alloc.alloc(u8, p_len) catch return;
            @memcpy(p_slice, pixels[0..p_len]);

            ptr.poster_w = @intCast(w);
            ptr.poster_h = @intCast(h);
            ptr.poster_pixels = p_slice;
        }
    }.worker, .{item})) |t| {
        t.detach(); // never joined — detach so the handle isn't leaked
    } else |_| {
        item.poster_fetching = false;
    }
}

fn httpGet(url: []const u8, bearer_token: []const u8) ?[]u8 {
    var client = std.http.Client{ .allocator = alloc, .io = @import("../core/io_global.zig").io() };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return null;

    var auth_buf: [300]u8 = undefined;
    const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{bearer_token}) catch return null;

    var req = client.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_val },
            .{ .name = "Accept", .value = "application/json" },
        },
    }) catch return null;
    defer req.deinit();

    req.sendBodiless() catch return null;

    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return null;

    if (response.head.status != .ok) return null;

    var transfer_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var rdr = response.readerDecompressing(&transfer_buf, &decompress, &.{});

    const body = rdr.allocRemaining(alloc, std.Io.Limit.limited(256 * 1024)) catch return null;
    return body;
}
