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

    const projection = @import("remote_youtube_pure.zig");
    const alloc = @import("../core/alloc.zig").allocator;
    const rows = alloc.alloc(projection.Row, projection.LIMIT) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"YouTube snapshot allocation failed\"}");
        return;
    };
    defer alloc.free(rows);
    const snapshot = youtube.snapshotCopy(rows);
    const json = alloc.alloc(u8, projection.capacity(snapshot.count)) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"YouTube response allocation failed\"}");
        return;
    };
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);
    projection.write(&w, rows[0..snapshot.count], snapshot) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"YouTube serialization failed\"}");
        return;
    };
    wire.sendJson(stream, json[0..w.end]);
}
