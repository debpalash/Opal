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
        if (wire.requireMethod(stream, method, "GET")) library(stream, query);
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
    if (std.mem.eql(u8, path, "/library/item")) {
        if (wire.requireMethod(stream, method, "GET")) libraryItem(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/library/item/action")) {
        if (wire.requireMethod(stream, method, "POST")) libraryItemAction(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/jellyfin/action")) {
        if (wire.requireMethod(stream, method, "POST")) jellyfinAction(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/tv/recent")) {
        if (wire.requireMethod(stream, method, "GET")) recentEpisode(stream, query);
        return true;
    }
    return false;
}

fn libraryIdentity(stream: std.Io.net.Stream, query: []const u8, kind_buf: []u8, id_buf: []u8) ?struct { kind: []const u8, id: []const u8 } {
    const kind = if (wire.queryParam(query, "kind")) |raw| (wire.urlDecode(raw, kind_buf) orelse "") else "";
    const id = if (wire.queryParam(query, "id")) |raw| (wire.urlDecode(raw, id_buf) orelse "") else "";
    if (kind.len == 0 or kind.len > 16 or id.len == 0 or id.len > 128) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid library identity\"}");
        return null;
    }
    return .{ .kind = kind, .id = id };
}

fn libraryItem(stream: std.Io.net.Stream, query: []const u8) void {
    var kind_buf: [32]u8 = undefined;
    var id_buf: [256]u8 = undefined;
    const identity = libraryIdentity(stream, query, &kind_buf, &id_buf) orelse return;
    const item = @import("library_store.zig").getState(identity.kind, identity.id);
    var json: [192]u8 = undefined;
    const body = std.fmt.bufPrint(&json, "{{\"favorite\":{s},\"rating\":{d:.1},\"resume_secs\":{d:.3},\"duration_secs\":{d:.3}}}", .{
        if (item.favorite) "true" else "false", item.user_rating, item.resume_secs, item.duration_secs,
    }) catch return;
    wire.sendJson(stream, body);
}

fn libraryItemAction(stream: std.Io.net.Stream, query: []const u8) void {
    var kind_buf: [32]u8 = undefined;
    var id_buf: [256]u8 = undefined;
    const identity = libraryIdentity(stream, query, &kind_buf, &id_buf) orelse return;
    var title_buf: [512]u8 = undefined;
    var poster_buf: [1024]u8 = undefined;
    const title = if (wire.queryParam(query, "title")) |raw| (wire.urlDecode(raw, &title_buf) orelse "") else "";
    const poster = if (wire.queryParam(query, "poster")) |raw| (wire.urlDecode(raw, &poster_buf) orelse "") else "";
    const action = wire.queryParam(query, "action") orelse "";
    const store = @import("library_store.zig");
    if (std.mem.eql(u8, action, "favorite")) {
        const enabled = wire.queryParam(query, "enabled") orelse "";
        if (!std.mem.eql(u8, enabled, "true") and !std.mem.eql(u8, enabled, "false")) {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid favorite value\"}");
            return;
        }
        var link_buf: [544]u8 = undefined;
        const deep_link = std.fmt.bufPrint(&link_buf, "opal://search/{s}", .{title}) catch "";
        store.setFavorite(identity.kind, identity.id, std.mem.eql(u8, enabled, "true"), title, poster, deep_link);
    } else if (std.mem.eql(u8, action, "rating")) {
        const raw = wire.queryParam(query, "value") orelse "";
        const rating: ?f64 = if (std.mem.eql(u8, raw, "clear")) null else std.fmt.parseFloat(f64, raw) catch {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid rating\"}");
            return;
        };
        if (rating) |value| if (!std.math.isFinite(value) or value < 0 or value > 10 or @mod(value * 2, 1) != 0) {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"rating must be a half-step from 0 to 10\"}");
            return;
        };
        store.setRating(identity.kind, identity.id, rating, title, poster);
    } else {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown library item action\"}");
        return;
    }
    wire.sendJson(stream, "{\"ok\":true}");
}

fn jellyfinAction(stream: std.Io.net.Stream, query: []const u8) void {
    const jf = @import("jellyfin.zig");
    var id_buf: [64]u8 = undefined;
    const id = if (wire.queryParam(query, "id")) |raw| (wire.urlDecode(raw, &id_buf) orelse "") else "";
    const action = std.meta.stringToEnum(jf.UserDataAction, wire.queryParam(query, "action") orelse "") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"ok\":false,\"error\":\"invalid action\"}");
        return;
    };
    const raw = wire.queryParam(query, "enabled") orelse "";
    const enabled = if (std.mem.eql(u8, raw, "true")) true else if (std.mem.eql(u8, raw, "false")) false else {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"ok\":false,\"error\":\"invalid enabled value\"}");
        return;
    };
    if (!jf.setUserData(id, action, enabled)) {
        wire.sendJsonStatus(stream, "409 Conflict", "{\"ok\":false,\"error\":\"item unavailable\"}");
        return;
    }
    wire.sendJson(stream, "{\"ok\":true,\"action\":\"user_data\"}");
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

const LibrarySort = enum { smart, recent, title, progress };

fn rowProgress(row: *const @import("tv_pure.zig").Row) f32 {
    if (row.prog.total > 0) return row.prog.fraction();
    return row.pct / 100.0;
}

fn libraryLessThan(sort: LibrarySort, a: @import("tv_pure.zig").Row, b: @import("tv_pure.zig").Row) bool {
    return switch (sort) {
        .smart => @import("tv_pure.zig").lessThan(&a, &b),
        .recent => if (a.updated_at != b.updated_at) a.updated_at > b.updated_at else std.mem.lessThan(u8, a.nameSlice(), b.nameSlice()),
        .title => std.ascii.lessThanIgnoreCase(a.nameSlice(), b.nameSlice()),
        .progress => if (rowProgress(&a) != rowProgress(&b)) rowProgress(&a) > rowProgress(&b) else std.mem.lessThan(u8, a.nameSlice(), b.nameSlice()),
    };
}

fn library(stream: std.Io.net.Stream, query: []const u8) void {
    const service = @import("tv_library.zig");
    const model = @import("tv_pure.zig");
    const alloc = @import("../core/alloc.zig").allocator;
    const rows = alloc.alloc(model.Row, model.MAX_SHOWS) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(rows);
    const catalog_count = service.snapshotCopy(rows);
    const filter = std.meta.stringToEnum(model.Filter, wire.queryParam(query, "filter") orelse "all") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown library filter\"}");
        return;
    };
    const kind = std.meta.stringToEnum(model.KindFilter, wire.queryParam(query, "kind") orelse "all") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown library kind filter\"}");
        return;
    };
    const sort = std.meta.stringToEnum(LibrarySort, wire.queryParam(query, "sort") orelse "smart") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown library sort\"}");
        return;
    };
    const offset = std.fmt.parseInt(usize, wire.queryParam(query, "offset") orelse "0", 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid library offset\"}");
        return;
    };
    const limit = std.fmt.parseInt(usize, wire.queryParam(query, "limit") orelse "48", 10) catch 0;
    if (limit == 0 or limit > 96 or offset > model.MAX_SHOWS) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"library page out of range\"}");
        return;
    }
    var count: usize = 0;
    for (rows[0..catalog_count]) |row| {
        if (!model.matchesFilter(&row, filter) or !model.matchesKind(&row, kind)) continue;
        rows[count] = row;
        count += 1;
    }
    std.mem.sort(model.Row, rows[0..count], sort, libraryLessThan);
    const json = alloc.alloc(u8, 128 * 1024) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);

    const start = @min(offset, count);
    const end = @min(start + limit, count);
    w.print("{{\"syncing\":{s},\"total\":{d},\"catalog_total\":{d},\"offset\":{d},\"limit\":{d},\"items\":[", .{ if (service.isSyncing()) "true" else "false", count, catalog_count, start, limit }) catch return;
    for (rows[start..end], 0..) |*row, i| {
        if (i > 0) w.writeAll(",") catch return;
        var status_buf: [48]u8 = undefined;
        const status = model.statusLabel(row, &status_buf);
        w.writeAll("{\"name\":\"") catch return;
        wire.writeJsonString(&w, row.name[0..@min(row.name_len, row.name.len)]);
        w.writeAll("\",\"id\":\"") catch return;
        wire.writeJsonString(&w, row.id[0..@min(row.id_len, row.id.len)]);
        w.print("\",\"kind\":\"{s}\",\"user_status\":\"{s}\",\"tmdb_id\":{d},\"watched\":{d},\"total\":{d},\"has_next\":{s},\"next_season\":{d},\"next_episode\":{d},\"pct\":{d:.0},\"updated_at\":{d},\"state\":\"{s}\",\"status\":\"", .{
            @tagName(row.kind),
            @tagName(row.user),
            row.tmdb_id,
            row.prog.watched,
            row.prog.total,
            if (row.has_next) "true" else "false",
            row.next.season,
            row.next.episode,
            row.pct,
            row.updated_at,
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
    var id_buf: [512]u8 = undefined;
    const id = if (wire.queryParam(query, "id")) |raw| (wire.urlDecode(raw, &id_buf) orelse "") else "";
    const season = std.fmt.parseInt(i32, wire.queryParam(query, "season") orelse "", 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"season required\"}");
        return;
    };
    const alloc = @import("../core/alloc.zig").allocator;
    const episodes = alloc.alloc(u32, service.MAX_EPISODES_PER_SEASON) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(episodes);
    const count = service.watchedEpisodes(kind, id, season, episodes) catch |err| {
        const status: []const u8 = if (err == error.ItemNotFound) "404 Not Found" else "400 Bad Request";
        const body: []const u8 = switch (err) {
            error.ItemNotFound => "{\"error\":\"library item not found\"}",
            error.InvalidEpisode => "{\"error\":\"invalid season\"}",
            error.Unsupported => "{\"error\":\"watched state is not available for this kind\"}",
            error.Busy => unreachable,
        };
        wire.sendJsonStatus(stream, status, body);
        return;
    };
    const json = alloc.alloc(u8, 32 + count * 7) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);
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
            error.Busy => "{\"error\":\"library update queue is busy; retry\"}",
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
    if (state.app.tmdb.api_key_len == 0) {
        var imdb_buf: [32]u8 = undefined;
        const imdb = if (wire.queryParam(query, "imdb")) |raw| (wire.urlDecode(raw, &imdb_buf) orelse "") else "";
        if (!@import("cinemeta_pure.zig").validImdbId(imdb)) {
            wire.sendJson(stream, "{\"error\":\"keyless TV metadata unavailable\"}");
            return;
        }
        sendCinemetaMeta(stream, "series", imdb);
        return;
    }
    var path_buf: [96]u8 = undefined;
    const path = if (wire.queryParam(query, "season")) |raw| blk: {
        const season = std.fmt.parseInt(i32, raw, 10) catch 0;
        break :blk std.fmt.bufPrint(&path_buf, "/3/tv/{d}/season/{d}", .{ id, season }) catch return;
    } else std.fmt.bufPrint(&path_buf, "/3/tv/{d}", .{id}) catch return;
    sendTmdbJson(stream, path);
}

fn sendCinemetaMeta(stream: std.Io.net.Stream, kind: []const u8, imdb: []const u8) void {
    const alloc = @import("../core/alloc.zig").allocator;
    const body = alloc.alloc(u8, 1024 * 1024) catch return;
    defer alloc.free(body);
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/meta/{s}/{s}.json", .{ kind, imdb }) catch return;
    const len = @import("tmdb_api.zig").cinemetaApiInto(path, body);
    if (len == 0) {
        wire.sendJson(stream, "{\"error\":\"cinemeta fetch failed\"}");
        return;
    }
    wire.sendJson(stream, body[0..len]);
}

fn movieDetails(stream: std.Io.net.Stream, query: []const u8) void {
    const id = std.fmt.parseInt(i32, wire.queryParam(query, "id") orelse "", 10) catch {
        wire.sendJson(stream, "{\"error\":\"bad id\"}");
        return;
    };
    if (state.app.tmdb.api_key_len == 0) {
        var imdb_buf: [32]u8 = undefined;
        const imdb = if (wire.queryParam(query, "imdb")) |raw| (wire.urlDecode(raw, &imdb_buf) orelse "") else "";
        if (!@import("cinemeta_pure.zig").validImdbId(imdb)) {
            wire.sendJson(stream, "{\"error\":\"keyless movie metadata unavailable\"}");
            return;
        }
        sendCinemetaMeta(stream, "movie", imdb);
        return;
    }
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
