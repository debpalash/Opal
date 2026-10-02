//! Provider-neutral Movies/TV catalog API for the web companion.

const std = @import("std");
const state = @import("../core/state.zig");
const wire = @import("remote_http.zig");

pub fn handle(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    // With no TMDB key, tmdb_api transparently routes browse/search to
    // Cinemeta. The browser never needs either provider's credentials.
    if (std.mem.eql(u8, api_path, "/tmdb/trending")) {
        if (!state.app.tmdb.is_loading.load(.acquire)) {
            applyMediaFilter(wire.queryParam(query, "type") orelse "all");
            const category = wire.queryParam(query, "category") orelse "trending";
            state.app.tmdb.category = if (std.mem.eql(u8, category, "popular"))
                .popular
            else if (std.mem.eql(u8, category, "top_rated"))
                .top_rated
            else if (std.mem.eql(u8, category, "new"))
                .now_playing
            else
                .trending;
            const genre = std.fmt.parseInt(usize, wire.queryParam(query, "genre") orelse "0", 10) catch 0;
            state.app.tmdb.genre_idx = if (genre < @import("tmdb_pure.zig").GENRE_NAMES.len) genre else 0;
            state.app.tmdb.view = .Trending;
            state.app.tmdb.page = 1;
            state.app.tmdb.loaded_once = true;
            @import("tmdb_api.zig").fetchCurrentView(false);
        }
        wire.sendJson(stream, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, api_path, "/tmdb/search")) {
        if (wire.queryParam(query, "q")) |q| {
            var decoded: [256]u8 = undefined;
            const value = wire.urlDecode(q, &decoded) orelse q;
            const len = @min(value.len, state.app.tmdb.search_buf.len - 1);
            @memcpy(state.app.tmdb.search_buf[0..len], value[0..len]);
            state.app.tmdb.search_buf[len] = 0;
            applyMediaFilter(wire.queryParam(query, "type") orelse "all");
            state.app.tmdb.genre_idx = 0;
            state.app.tmdb.view = .Search;
            state.app.tmdb.page = 1;
            @import("tmdb_api.zig").fetchCurrentView(false);
        }
        wire.sendJson(stream, "{\"ok\":true,\"action\":\"tmdb_search\"}");
        return;
    }

    sendSnapshot(stream);
}

fn applyMediaFilter(media: []const u8) void {
    state.app.tmdb.media_filter = if (std.mem.eql(u8, media, "movie"))
        .movie
    else if (std.mem.eql(u8, media, "tv"))
        .tv
    else
        .all;
}

fn sendSnapshot(stream: std.Io.net.Stream) void {
    const projection = @import("remote_catalog_pure.zig");
    const alloc = @import("../core/alloc.zig").allocator;
    const rows = alloc.alloc(projection.Row, projection.LIMIT) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"catalog allocation failed\"}");
        return;
    };
    defer alloc.free(rows);
    state.app.tmdb.results_mutex.lock();
    const total = state.app.tmdb.results.items.len;
    const count = @min(total, rows.len);
    for (state.app.tmdb.results.items[0..count], rows[0..count]) |item, *row| row.* = projection.Row.copy(item);
    const loading = state.app.tmdb.is_loading.load(.acquire);
    const has_key = state.app.tmdb.api_key_len > 0;
    state.app.tmdb.results_mutex.unlock();
    const json = alloc.alloc(u8, projection.capacity(count)) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"catalog allocation failed\"}");
        return;
    };
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);
    projection.write(&w, rows[0..count], total, loading, has_key) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"catalog serialization failed\"}");
        return;
    };
    wire.sendJson(stream, json[0..w.end]);
}
