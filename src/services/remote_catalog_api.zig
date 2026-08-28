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
    var json: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json);
    w.writeAll("{\"items\":[") catch return;
    {
        state.app.tmdb.results_mutex.lock();
        defer state.app.tmdb.results_mutex.unlock();
        for (state.app.tmdb.results.items, 0..) |item, idx| {
            if (idx >= 30) break;
            if (idx > 0) w.writeAll(",") catch return;
            const rating = @as(u8, @intFromFloat(std.math.clamp(item.rating * 10.0, 0.0, 100.0)));
            w.print("{{\"id\":{d},\"title\":\"", .{item.id}) catch return;
            wire.writeJsonString(&w, item.title[0..item.title_len]);
            w.writeAll("\",\"imdb\":\"") catch return;
            wire.writeJsonString(&w, item.imdb_id[0..item.imdb_id_len]);
            w.writeAll("\",\"year\":\"") catch return;
            wire.writeJsonString(&w, item.year[0..item.year_len]);
            w.print("\",\"rating\":{d},\"type\":\"", .{rating}) catch return;
            wire.writeJsonString(&w, item.media_type[0..item.media_type_len]);
            w.writeAll("\",\"overview\":\"") catch return;
            wire.writeJsonString(&w, item.overview[0..@min(item.overview_len, 200)]);
            w.writeAll("\",\"poster\":\"") catch return;
            wire.writeJsonString(&w, item.poster_path[0..item.poster_path_len]);
            w.writeAll("\"}") catch return;
        }
        w.writeAll("],\"loading\":") catch return;
        w.writeAll(if (state.app.tmdb.is_loading.load(.acquire)) "true" else "false") catch return;
        w.writeAll(",\"has_key\":") catch return;
        w.writeAll(if (state.app.tmdb.api_key_len > 0) "true" else "false") catch return;
        w.writeAll("}") catch return;
    }
    wire.sendJson(stream, json[0..w.end]);
}
