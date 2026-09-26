//! Anime browse, paging, episode, and playback endpoints for the web companion.

const std = @import("std");
const state = @import("../core/state.zig");
const text = @import("../core/text.zig");
const wire = @import("remote_http.zig");
const anime = @import("anime.zig");
const alloc = @import("../core/alloc.zig").allocator;

pub fn handle(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    if (std.mem.eql(u8, api_path, "/anime/more")) {
        anime.loadMoreGrid();
        wire.sendJson(stream, "{\"ok\":true,\"action\":\"anime_more\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/anime/search")) {
        if (wire.queryParam(query, "q")) |raw| {
            var decoded: [256]u8 = undefined;
            anime.searchAnime(wire.urlDecode(raw, &decoded) orelse raw);
        }
        wire.sendJson(stream, "{\"ok\":true,\"action\":\"anime_search\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/anime/episodes")) {
        const idx = std.fmt.parseInt(usize, wire.queryParam(query, "idx") orelse "0", 10) catch 0;
        anime.loadEpisodes(idx);
        wire.sendJson(stream, "{\"ok\":true,\"action\":\"load_episodes\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/anime/play")) {
        if (wire.queryParam(query, "ep")) |raw| {
            var decoded: [16]u8 = undefined;
            anime.playEpisode(wire.urlDecode(raw, &decoded) orelse raw);
        }
        wire.sendJson(stream, "{\"ok\":true,\"action\":\"play_episode\"}");
        return;
    }
    sendSnapshot(stream);
}

fn sendSnapshot(stream: std.Io.net.Stream) void {
    const json = alloc.alloc(u8, 192 * 1024) catch {
        wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"anime view unavailable\"}");
        return;
    };
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);
    w.writeAll("{\"results\":[") catch return;
    var emitted: usize = 0;
    for (0..anime.resultCount()) |idx| {
        const row = anime.resultRow(idx) orelse continue;
        if (row.name_len == 0) continue;
        if (emitted > 0) w.writeAll(",") catch return;
        w.writeAll("{\"id\":\"") catch return;
        wire.writeJsonString(&w, text.safeUtf8(row.id[0..@min(row.id_len, row.id.len)]));
        w.writeAll("\",\"name\":\"") catch return;
        wire.writeJsonString(&w, text.safeUtf8(row.name[0..@min(row.name_len, row.name.len)]));
        w.writeAll("\",\"poster\":\"") catch return;
        wire.writeJsonString(&w, row.poster_url[0..@min(row.poster_url_len, row.poster_url.len)]);
        w.writeAll("\",\"overview\":\"") catch return;
        wire.writeJsonString(&w, text.safeUtf8(row.overview[0..@min(row.overview_len, row.overview.len)]));
        w.writeAll("\",\"type\":\"") catch return;
        wire.writeJsonString(&w, text.safeUtf8(row.atype[0..@min(row.atype_len, row.atype.len)]));
        w.print("\",\"episodes\":{d},\"year\":{d},\"score\":{d:.1},\"airing\":{s}}}", .{
            row.episodes, row.year, row.score, if (row.airing) "true" else "false",
        }) catch return;
        emitted += 1;
    }
    w.writeAll("],\"episodes\":[") catch return;
    const episode_count = @min(state.app.anime.episode_count, state.app.anime.episode_list.len);
    var emitted_episodes: usize = 0;
    for (0..episode_count) |idx| {
        const len = @min(state.app.anime.episode_list_lens[idx], state.app.anime.episode_list[idx].len);
        if (len == 0) continue;
        if (emitted_episodes > 0) w.writeAll(",") catch return;
        w.writeAll("\"") catch return;
        wire.writeJsonString(&w, text.safeUtf8(state.app.anime.episode_list[idx][0..len]));
        w.writeAll("\"") catch return;
        emitted_episodes += 1;
    }
    w.writeAll("],\"selected\":") catch return;
    if (state.app.anime.selected_idx) |idx| w.print("{d}", .{idx}) catch return else w.writeAll("null") catch return;
    w.writeAll(",\"loading_more\":") catch return;
    w.writeAll(if (anime.isLoadingMoreGrid()) "true" else "false") catch return;
    w.writeAll(",\"has_more\":") catch return;
    w.writeAll(if (anime.hasMoreGrid()) "true" else "false") catch return;
    w.writeAll(",\"loading\":") catch return;
    w.writeAll(if (state.app.anime.is_loading.load(.acquire)) "true" else "false") catch return;
    w.writeAll(",\"stream_loading\":") catch return;
    w.writeAll(if (state.app.anime.stream_loading) "true" else "false") catch return;
    w.writeAll("}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}
