//! YouTube browse endpoints for the web companion.

const std = @import("std");
const state = @import("../core/state.zig");
const text = @import("../core/text.zig");
const wire = @import("remote_http.zig");
const youtube = @import("youtube.zig");

pub fn handle(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    if (std.mem.eql(u8, api_path, "/youtube/search")) {
        if (wire.queryParam(query, "q")) |raw| {
            var decoded: [256]u8 = undefined;
            const value = wire.urlDecode(raw, &decoded) orelse raw;
            var len: usize = 0;
            text.setFixedUtf8(state.app.yt.search_buf[0 .. state.app.yt.search_buf.len - 1], &len, value);
            state.app.yt.search_buf[len] = 0;
            youtube.fetchYoutube(state.app.yt.search_buf[0..len]);
        }
        wire.sendJson(stream, "{\"ok\":true,\"action\":\"yt_search\"}");
        return;
    }

    var json: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&json);
    w.writeAll("{\"items\":[") catch return;
    const count = @min(youtube.resultCount(), 30);
    var emitted: usize = 0;
    for (0..count) |idx| {
        const item = youtube.resultRow(idx) orelse continue;
        if (emitted > 0) w.writeAll(",") catch return;
        w.writeAll("{\"id\":\"") catch return;
        wire.writeJsonString(&w, text.safeUtf8(item.video_id[0..@min(item.video_id_len, item.video_id.len)]));
        w.writeAll("\",\"title\":\"") catch return;
        wire.writeJsonString(&w, text.safeUtf8(item.title[0..@min(item.title_len, item.title.len)]));
        w.writeAll("\",\"channel\":\"") catch return;
        wire.writeJsonString(&w, text.safeUtf8(item.uploader[0..@min(item.uploader_len, item.uploader.len)]));
        w.print("\",\"dur_min\":{d},\"dur_sec\":{d},\"views\":{d}}}", .{
            @divTrunc(item.duration, 60), @rem(item.duration, 60), item.views,
        }) catch return;
        emitted += 1;
    }
    w.writeAll("],\"loading\":") catch return;
    w.writeAll(if (state.app.yt.is_loading.load(.acquire)) "true" else "false") catch return;
    w.writeAll("}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}
