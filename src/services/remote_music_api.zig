//! Music catalog, source selection and playback routes.
const std = @import("std");
const state = @import("../core/state.zig");
const txt = @import("../core/text.zig");
const wire = @import("remote_http.zig");

pub fn handle(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8) void {
    const music = @import("music_subsonic.zig");
    const alloc = @import("../core/alloc.zig").allocator;

    if (std.mem.eql(u8, api_path, "/music/source")) {
        const raw = wire.queryParam(query, "id") orelse "";
        const src = std.fmt.parseInt(u8, raw, 10) catch 255;
        if (!music.selectSource(src)) {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown music source\"}");
            return;
        }
        wire.sendJson(stream, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, api_path, "/music/search")) {
        if (wire.queryParam(query, "q")) |raw| {
            var dec: [256]u8 = undefined;
            music.searchMusic(wire.urlDecode(raw, &dec) orelse raw);
        }
        wire.sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/music/play")) {
        if (wire.queryParam(query, "idx")) |v| {
            const idx = std.fmt.parseInt(usize, v, 10) catch 0;
            if (idx < music.resultCount()) music.playSong(idx);
        }
        wire.sendJson(stream, "{\"ok\":true}");
        return;
    }

    const buf = alloc.alloc(u8, 96 * 1024) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(buf);
    var w = std.Io.Writer.fixed(buf);
    w.print("{{\"loading\":{s},\"source\":{d},\"songs\":[", .{
        if (state.app.music.is_loading.load(.acquire)) "true" else "false",
        state.app.music.source,
    }) catch return;
    var i: usize = 0;
    const n = @min(music.resultCount(), 80);
    while (i < n) : (i += 1) {
        const s = music.resultRow(i) orelse continue;
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        wire.writeJsonString(&w, txt.safeUtf8(s.title[0..@min(s.title_len, s.title.len)]));
        w.writeAll("\",\"artist\":\"") catch return;
        wire.writeJsonString(&w, txt.safeUtf8(s.artist[0..@min(s.artist_len, s.artist.len)]));
        w.writeAll("\",\"cover\":\"") catch return;
        wire.writeJsonString(&w, txt.safeUtf8(s.cover[0..@min(s.cover_len, s.cover.len)]));
        w.writeAll("\",\"url\":\"") catch return;
        wire.writeJsonString(&w, txt.safeUtf8(s.play_url[0..@min(s.play_url_len, s.play_url.len)]));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, buf[0..w.end]);
}
