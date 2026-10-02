//! Web API projection for live torrent transfers.

const std = @import("std");
const state = @import("../core/state.zig");
const c = @import("../core/c.zig");
const wire = @import("remote_http.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8) bool {
    if (std.mem.eql(u8, path, "/torrents")) {
        if (wire.requireMethod(stream, method, "GET")) snapshot(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/torrents/action")) {
        if (wire.requireMethod(stream, method, "POST")) applyAction(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/downloads/file-action")) {
        if (wire.requireMethod(stream, method, "POST")) applyDiskAction(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/downloads/history")) {
        if (wire.requireMethod(stream, method, "GET")) downloadHistory(stream);
        return true;
    }
    if (std.mem.eql(u8, path, "/downloads/history/action")) {
        if (wire.requireMethod(stream, method, "POST")) applyDownloadHistoryAction(stream, query);
        return true;
    }
    return false;
}

fn downloadHistory(stream: std.Io.net.Stream) void {
    const history = @import("history.zig");
    const alloc = @import("../core/alloc.zig").allocator;
    const entries = alloc.alloc(history.DownloadHistoryEntry, state.MAX_DL_HISTORY) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(entries);
    const count = history.snapshotDownloadHistory(entries);
    const json = alloc.alloc(u8, 1024 + count * (state.MAX_DL_NAME_LEN * 6 + 64)) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);
    w.writeAll("{\"items\":[") catch return;
    for (entries[0..count], 0..) |*entry, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.print("{{\"id\":{d},\"name\":\"", .{entry.id}) catch return;
        wire.writeJsonString(&w, entry.name[0..entry.name_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}

fn applyDownloadHistoryAction(stream: std.Io.net.Stream, query: []const u8) void {
    const history = @import("history.zig");
    const action = std.meta.stringToEnum(history.DownloadHistoryAction, wire.queryParam(query, "action") orelse "") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown history action\"}");
        return;
    };
    if (!std.mem.eql(u8, wire.queryParam(query, "confirm") orelse "", "1")) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"history cleanup requires confirm=1\"}");
        return;
    }
    const id = if (action == .remove) std.fmt.parseInt(i64, wire.queryParam(query, "id") orelse "", 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"history id required\"}");
        return;
    } else 0;
    if (!history.requestDownloadHistoryAction(action, id)) {
        wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"history cleanup queue busy\"}");
        return;
    }
    wire.sendJson(stream, "{\"ok\":true}");
}

fn applyDiskAction(stream: std.Io.net.Stream, query: []const u8) void {
    const transfers = @import("transfers.zig");
    const action = std.meta.stringToEnum(transfers.DiskAction, wire.queryParam(query, "action") orelse "") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown file action\"}");
        return;
    };
    var decoded: [512]u8 = undefined;
    const rel = if (wire.queryParam(query, "file")) |raw| (wire.urlDecode(raw, &decoded) orelse "") else "";
    if (action == .delete and !std.mem.eql(u8, wire.queryParam(query, "confirm") orelse "", "DELETE")) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"disk deletion requires confirm=DELETE\"}");
        return;
    }
    transfers.applyDiskAction(rel, action) catch |err| {
        const status: []const u8 = if (err == error.NotFound) "404 Not Found" else if (err == error.InvalidPath) "400 Bad Request" else "500 Internal Server Error";
        const body: []const u8 = if (err == error.NotFound) "{\"error\":\"download not found\"}" else if (err == error.InvalidPath) "{\"error\":\"invalid download path\"}" else "{\"error\":\"file action failed\"}";
        wire.sendJsonStatus(stream, status, body);
        return;
    };
    wire.sendJson(stream, "{\"ok\":true}");
}

fn snapshot(stream: std.Io.net.Stream, query: []const u8) void {
    const offset = std.fmt.parseInt(usize, wire.queryParam(query, "offset") orelse "0", 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid transfer offset\"}");
        return;
    };
    const limit = std.fmt.parseInt(usize, wire.queryParam(query, "limit") orelse "96", 10) catch 0;
    if (limit == 0 or limit > 96) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"transfer page out of range\"}");
        return;
    }
    const alloc = @import("../core/alloc.zig").allocator;
    const json = alloc.alloc(u8, 1024 + limit * (256 * 6 + 256)) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);
    w.writeAll("{\"torrents\":[") catch return;
    const count = c.mpv.torrent_count(state.torrentSession());
    var emitted: usize = 0;
    var total: usize = 0;
    var id: c_int = 0;
    while (id < count) : (id += 1) {
        if (c.mpv.torrent_is_alive(state.torrentSession(), id) == 0) continue;
        const position = total;
        total += 1;
        if (position < offset or emitted >= limit) continue;
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
            if (std.math.isFinite(progress)) std.math.clamp(progress * 100.0, 0.0, 100.0) else @as(f32, 0),
            rate,
            seeds,
            if (c.mpv.torrent_is_paused(state.torrentSession(), id) != 0) "true" else "false",
        }) catch return;
        emitted += 1;
    }
    w.print("],\"total\":{d},\"offset\":{d},\"limit\":{d},\"returned\":{d},\"has_more\":{s}}}", .{ total, offset, limit, emitted, if (offset < total and emitted < total - offset) "true" else "false" }) catch return;
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
