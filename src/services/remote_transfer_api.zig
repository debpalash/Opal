//! Web API projection for live torrent transfers.

const std = @import("std");
const state = @import("../core/state.zig");
const c = @import("../core/c.zig");
const wire = @import("remote_http.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8) bool {
    if (std.mem.eql(u8, path, "/torrents")) {
        if (wire.requireMethod(stream, method, "GET")) snapshot(stream);
        return true;
    }
    if (std.mem.eql(u8, path, "/torrents/action")) {
        if (wire.requireMethod(stream, method, "POST")) applyAction(stream, query);
        return true;
    }
    return false;
}

fn snapshot(stream: std.Io.net.Stream) void {
    var json: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&json);
    w.writeAll("{\"torrents\":[") catch return;
    const count = c.mpv.torrent_count(state.torrentSession());
    var emitted: usize = 0;
    var id: c_int = 0;
    while (id < count) : (id += 1) {
        if (c.mpv.torrent_is_alive(state.torrentSession(), id) == 0) continue;
        var name_buf: [256]u8 = undefined;
        c.mpv.torrent_get_name(state.torrentSession(), id, &name_buf, name_buf.len);
        const name_len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse name_buf.len - 1;
        var progress: f32 = 0;
        var rate: c_int = 0;
        var seeds: c_int = 0;
        _ = c.mpv.torrent_poll(state.torrentSession(), id, -1, null, 0, &progress, &rate, &seeds);
        if (emitted > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        wire.writeJsonString(&w, name_buf[0..name_len]);
        w.print("\",\"id\":{d},\"pct\":{d:.1},\"rate\":{d},\"seeds\":{d},\"paused\":{s}}}", .{
            id,
            std.math.clamp(progress * 100.0, 0.0, 100.0),
            rate,
            seeds,
            if (c.mpv.torrent_is_paused(state.torrentSession(), id) != 0) "true" else "false",
        }) catch return;
        emitted += 1;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}

fn applyAction(stream: std.Io.net.Stream, query: []const u8) void {
    const transfers = @import("transfers.zig");
    const action_name = wire.queryParam(query, "action") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"torrent action required\"}");
        return;
    };
    const action = std.meta.stringToEnum(transfers.TorrentAction, action_name) orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown torrent action\"}");
        return;
    };
    const id = std.fmt.parseInt(c_int, wire.queryParam(query, "id") orelse "", 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"torrent id required\"}");
        return;
    };
    var file_idx: c_int = -1;
    var priority: c_int = -1;
    if (action == .priority) {
        file_idx = std.fmt.parseInt(c_int, wire.queryParam(query, "file") orelse "", 10) catch {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"file index required\"}");
            return;
        };
        priority = std.fmt.parseInt(c_int, wire.queryParam(query, "value") orelse "", 10) catch {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"priority required\"}");
            return;
        };
    }
    if (action == .cancel and !std.mem.eql(u8, wire.queryParam(query, "confirm") orelse "", "1")) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"cancel requires confirm=1\"}");
        return;
    }

    const lock_players = action == .cancel;
    if (lock_players) state.players_mutex.lock();
    defer if (lock_players) state.players_mutex.unlock();
    if (!transfers.applyTorrentAction(id, action, file_idx, priority)) {
        wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"torrent changed; refresh and retry\"}");
        return;
    }
    state.wakeUi();
    wire.sendJson(stream, "{\"ok\":true}");
}
