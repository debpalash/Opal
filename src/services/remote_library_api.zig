//! Calendar, Watching-library, and TV detail routes for the web companion.
//!
//! These routes share one domain: the user's tracked media and its episode
//! state. The public `handle` function is the only seam the top-level router
//! needs; serialization and mutation validation stay feature-local.

const std = @import("std");
const state = @import("../core/state.zig");
const wire = @import("remote_http.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8) bool {
    if (std.mem.eql(u8, path, "/calendar")) {
        if (wire.requireMethod(stream, method, "GET")) calendar(stream);
        return true;
    }
    if (std.mem.eql(u8, path, "/tv")) {
        if (wire.requireMethod(stream, method, "GET")) tvDetails(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/movie")) {
        if (wire.requireMethod(stream, method, "GET")) movieDetails(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/library")) {
        if (wire.requireMethod(stream, method, "GET")) library(stream);
        return true;
    }
    if (std.mem.eql(u8, path, "/library/watched")) {
        if (wire.requireMethod(stream, method, "GET")) watchedEpisodes(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/library/action")) {
        if (wire.requireMethod(stream, method, "POST")) libraryAction(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/tv/recent")) {
        if (wire.requireMethod(stream, method, "GET")) recentEpisode(stream, query);
        return true;
    }
    return false;
}

fn calendar(stream: std.Io.net.Stream) void {
    const service = @import("tv_calendar.zig");
    service.refreshOnce();
    var json: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&json);
    w.writeAll("{\"entries\":[") catch return;
    for (0..service.count) |i| {
        const entry = &service.entries[i];
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        wire.writeJsonString(&w, entry.name[0..entry.name_len]);
        w.print("\",\"tmdb_id\":{d},\"next_season\":{d},\"next_episode\":{d},\"next_air\":{d},\"last_season\":{d},\"last_episode\":{d},\"available\":{s},\"seeds\":{d},\"unseen\":{s},\"poster\":\"", .{
            entry.tmdb_id,
            entry.next_season,
            entry.next_episode,
            entry.next_air_epoch,
            entry.last_season,
            entry.last_episode,
            if (entry.available) "true" else "false",
            entry.seeds,
            if (entry.unseen) "true" else "false",
        }) catch return;
        wire.writeJsonString(&w, entry.poster_path[0..entry.poster_path_len]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}

fn library(stream: std.Io.net.Stream) void {
    const service = @import("tv_library.zig");
    const model = @import("tv_pure.zig");
    const alloc = @import("../core/alloc.zig").allocator;
    const rows = alloc.alloc(model.Row, model.MAX_SHOWS) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(rows);
    const count = service.snapshotCopy(rows);
    const json = alloc.alloc(u8, 128 * 1024) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);

    w.print("{{\"syncing\":{s},\"items\":[", .{if (service.isSyncing()) "true" else "false"}) catch return;
    for (rows[0..count], 0..) |*row, i| {
        if (i > 0) w.writeAll(",") catch return;
        var status_buf: [48]u8 = undefined;
        const status = model.statusLabel(row, &status_buf);
        w.writeAll("{\"name\":\"") catch return;
        wire.writeJsonString(&w, row.name[0..@min(row.name_len, row.name.len)]);
        w.writeAll("\",\"id\":\"") catch return;
        wire.writeJsonString(&w, row.id[0..@min(row.id_len, row.id.len)]);
        w.print("\",\"kind\":\"{s}\",\"user_status\":\"{s}\",\"tmdb_id\":{d},\"watched\":{d},\"total\":{d},\"has_next\":{s},\"next_season\":{d},\"next_episode\":{d},\"pct\":{d:.0},\"state\":\"{s}\",\"status\":\"", .{
            @tagName(row.kind),
            @tagName(row.user),
            row.tmdb_id,
            row.prog.watched,
            row.prog.total,
            if (row.has_next) "true" else "false",
            row.next.season,
            row.next.episode,
            row.pct,
            @tagName(model.effectiveStatus(row.user, row.status)),
        }) catch return;
        wire.writeJsonString(&w, status);
        w.writeAll("\",\"poster\":\"") catch return;
        wire.writeJsonString(&w, row.poster_url[0..@min(row.poster_url_len, row.poster_url.len)]);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}

fn watchedEpisodes(stream: std.Io.net.Stream, query: []const u8) void {
    const service = @import("tv_library.zig");
    const model = @import("tv_pure.zig");
    const kind = std.meta.stringToEnum(model.Kind, wire.queryParam(query, "kind") orelse "") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown library kind\"}");
        return;
    };
    var id_buf: [128]u8 = undefined;
    const id = if (wire.queryParam(query, "id")) |raw| (wire.urlDecode(raw, &id_buf) orelse "") else "";
    const season = std.fmt.parseInt(i32, wire.queryParam(query, "season") orelse "", 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"season required\"}");
        return;
    };
    var episodes: [service.MAX_EPISODES_PER_SEASON]u32 = undefined;
    const count = service.watchedEpisodes(kind, id, season, &episodes) catch |err| {
        const status: []const u8 = if (err == error.ItemNotFound) "404 Not Found" else "400 Bad Request";
        const body: []const u8 = switch (err) {
            error.ItemNotFound => "{\"error\":\"library item not found\"}",
            error.InvalidEpisode => "{\"error\":\"invalid season\"}",
            error.Unsupported => "{\"error\":\"watched state is not available for this kind\"}",
        };
        wire.sendJsonStatus(stream, status, body);
        return;
    };
    var json: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&json);
    w.writeAll("{\"episodes\":[") catch return;
    for (episodes[0..count], 0..) |episode, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.print("{d}", .{episode}) catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}

fn libraryAction(stream: std.Io.net.Stream, query: []const u8) void {
    const service = @import("tv_library.zig");
    const model = @import("tv_pure.zig");
    const action = std.meta.stringToEnum(service.Action, wire.queryParam(query, "action") orelse "") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown library action\"}");
        return;
    };
    if (action == .refresh) {
        service.apply(.refresh) catch unreachable;
        wire.sendJson(stream, "{\"ok\":true}");
        return;
    }

    const kind = std.meta.stringToEnum(model.Kind, wire.queryParam(query, "kind") orelse "") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown library kind\"}");
        return;
    };
    var id_buf: [128]u8 = undefined;
    const id = if (wire.queryParam(query, "id")) |raw| (wire.urlDecode(raw, &id_buf) orelse "") else "";
    const item = service.ItemRef{ .kind = kind, .id = id };
    const command: service.Command = switch (action) {
        .status => blk: {
            const value = std.meta.stringToEnum(model.UserStatus, wire.queryParam(query, "value") orelse "") orelse {
                wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown library status\"}");
                return;
            };
            break :blk .{ .status = .{ .item = item, .value = value } };
        },
        .watched => blk: {
            const season = std.fmt.parseInt(i32, wire.queryParam(query, "season") orelse "", 10) catch {
                wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"season required\"}");
                return;
            };
            const episode = std.fmt.parseInt(i32, wire.queryParam(query, "episode") orelse "", 10) catch {
                wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"episode required\"}");
                return;
            };
            const raw = wire.queryParam(query, "value") orelse "";
            const value = if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1"))
                true
            else if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0"))
                false
            else {
                wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"watched value must be true or false\"}");
                return;
            };
            break :blk .{ .watched = .{ .item = item, .episode = .{ .season = season, .episode = episode }, .value = value } };
        },
        .remove => blk: {
            if (!std.mem.eql(u8, wire.queryParam(query, "confirm") orelse "", "1")) {
                wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"remove requires confirm=1\"}");
                return;
            }
            break :blk .{ .remove = item };
        },
        .refresh => unreachable,
    };
    service.apply(command) catch |err| {
        const status: []const u8 = if (err == error.ItemNotFound) "409 Conflict" else "400 Bad Request";
        const body: []const u8 = switch (err) {
            error.ItemNotFound => "{\"error\":\"library changed; refresh and retry\"}",
            error.InvalidEpisode => "{\"error\":\"invalid episode\"}",
            error.Unsupported => "{\"error\":\"action is not safe for this library kind yet\"}",
        };
        wire.sendJsonStatus(stream, status, body);
        return;
    };
    state.wakeUi();
    wire.sendJson(stream, "{\"ok\":true}");
}

fn recentEpisode(stream: std.Io.net.Stream, query: []const u8) void {
    const id = std.fmt.parseInt(i32, wire.queryParam(query, "id") orelse "", 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"missing id\"}");
        return;
    };
    const latest = @import("tv_library.zig").lastAiredFor(id) orelse {
        wire.sendJson(stream, "{\"found\":false}");
        return;
    };
    var label_buf: [48]u8 = undefined;
    const label = @import("tv_pure.zig").recentEpisodeLabel(latest.ep, latest.watched, &label_buf);
    var json: [192]u8 = undefined;
    const body = std.fmt.bufPrint(&json, "{{\"found\":true,\"season\":{d},\"episode\":{d},\"watched\":{s},\"label\":\"{s}\"}}", .{
        latest.ep.season,
        latest.ep.episode,
        if (latest.watched) "true" else "false",
        label,
    }) catch return;
    wire.sendJson(stream, body);
}

fn tvDetails(stream: std.Io.net.Stream, query: []const u8) void {
    const id = std.fmt.parseInt(i32, wire.queryParam(query, "id") orelse "", 10) catch {
        wire.sendJson(stream, "{\"error\":\"bad id\"}");
        return;
    };
    var path_buf: [96]u8 = undefined;
    const path = if (wire.queryParam(query, "season")) |raw| blk: {
        const season = std.fmt.parseInt(i32, raw, 10) catch 0;
        break :blk std.fmt.bufPrint(&path_buf, "/3/tv/{d}/season/{d}", .{ id, season }) catch return;
    } else std.fmt.bufPrint(&path_buf, "/3/tv/{d}", .{id}) catch return;
    sendTmdbJson(stream, path);
}

fn movieDetails(stream: std.Io.net.Stream, query: []const u8) void {
    const id = std.fmt.parseInt(i32, wire.queryParam(query, "id") orelse "", 10) catch {
        wire.sendJson(stream, "{\"error\":\"bad id\"}");
        return;
    };
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/3/movie/{d}", .{id}) catch return;
    sendTmdbJson(stream, path);
}

/// Proxy one TMDB details GET through the server. The browser never holds the
/// TMDB key; both the movie and TV detail routes funnel through this seam.
fn sendTmdbJson(stream: std.Io.net.Stream, path: []const u8) void {
    if (state.app.tmdb.api_key_len == 0) {
        wire.sendJson(stream, "{\"error\":\"no tmdb key\"}");
        return;
    }
    const alloc = @import("../core/alloc.zig").allocator;
    const body = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(body);
    const len = @import("tmdb_api.zig").tmdbApiInto(path, state.app.tmdb.api_key[0..state.app.tmdb.api_key_len], body);
    if (len == 0) {
        wire.sendJson(stream, "{\"error\":\"tmdb fetch failed\"}");
        return;
    }
    wire.sendJson(stream, body[0..len]);
}
