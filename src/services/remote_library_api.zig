//! Calendar, Watching-library, and TV detail routes for the web companion.
//!
//! These routes share one domain: the user's tracked media and its episode
//! state. The public `handle` function is the only seam the top-level router
//! needs; serialization and mutation validation stay feature-local.

const std = @import("std");
const keyless = @import("cinemeta_meta_pure.zig");
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
        const is_on = std.mem.eql(u8, enabled, "true") or std.mem.eql(u8, enabled, "1");
        const is_off = std.mem.eql(u8, enabled, "false") or std.mem.eql(u8, enabled, "0");
        if (!is_on and !is_off) {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid favorite value\"}");
            return;
        }
        var link_buf: [544]u8 = undefined;
        const deep_link = std.fmt.bufPrint(&link_buf, "opal://search/{s}", .{title}) catch "";
        store.setFavorite(identity.kind, identity.id, is_on, title, poster, deep_link);
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
    const alloc = @import("../core/alloc.zig").allocator;
    const entries = alloc.alloc(service.Entry, 12) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(entries);
    const snapshot = service.snapshotCopy(entries);
    const json = alloc.alloc(u8, 1024 + snapshot.count * ((128 + 64) * 6 + 512)) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);
    w.print("{{\"loading\":{s},\"loaded\":{s},\"failed\":{s},\"partial\":{s},\"stale\":{s},\"entries\":[", .{ if (snapshot.loading) "true" else "false", if (snapshot.loaded) "true" else "false", if (snapshot.failed) "true" else "false", if (snapshot.partial) "true" else "false", if (snapshot.stale) "true" else "false" }) catch return;
    for (entries[0..snapshot.count], 0..) |*entry, i| {
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

const library_pure = @import("remote_library_pure.zig");
const LibrarySort = library_pure.Sort;
var library_projection: library_pure.Projection = .{};
var library_projection_mutex: @import("../core/sync.zig").Mutex = .{};

fn library(stream: std.Io.net.Stream, query: []const u8) void {
    const service = @import("tv_library.zig");
    const model = @import("tv_pure.zig");
    const alloc = @import("../core/alloc.zig").allocator;
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
    const selection: library_pure.Selection = .{ .filter = filter, .kind = kind, .sort = sort };
    library_projection_mutex.lock();
    var projection_locked = true;
    defer if (projection_locked) library_projection_mutex.unlock();
    const current_revision = service.revision();
    if (!library_projection.matches(current_revision, selection)) {
        const snapshot = alloc.alloc(model.Row, model.MAX_SHOWS) catch {
            wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
            return;
        };
        defer alloc.free(snapshot);
        const before = service.revision();
        const n = service.snapshotCopy(snapshot);
        library_projection.rebuild(snapshot[0..n], before, selection);
        // A mutation racing the snapshot is not a reusable coherent revision.
        if (service.revision() != before) library_projection.valid = false;
    }
    var version_buf: [128]u8 = undefined;
    const version = library_pure.version(library_projection.revision, selection, offset, limit, &version_buf) orelse return;
    var since_buf: [128]u8 = undefined;
    const since = if (wire.queryParam(query, "since")) |raw| wire.urlDecode(raw, &since_buf) orelse "" else "";
    if (library_projection.valid and std.mem.eql(u8, since, version)) {
        var response: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&response, "{{\"unchanged\":true,\"version\":\"{s}\",\"syncing\":{s}}}", .{ version, if (service.isSyncing()) "true" else "false" }) catch return;
        library_projection_mutex.unlock();
        projection_locked = false;
        wire.sendJson(stream, body);
        return;
    }
    const rows = alloc.alloc(model.Row, limit) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(rows);
    const page = library_projection.page(offset, rows);
    library_projection_mutex.unlock();
    projection_locked = false;
    const json = alloc.alloc(u8, library_pure.jsonCapacity(page.count)) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.free(json);
    var w = std.Io.Writer.fixed(json);

    w.print("{{\"version\":\"{s}\",\"unchanged\":false,\"syncing\":{s},\"total\":{d},\"catalog_total\":{d},\"offset\":{d},\"limit\":{d},\"returned\":{d},\"has_more\":{s},\"items\":[", .{ version, if (service.isSyncing()) "true" else "false", page.total, page.catalog_total, page.offset, limit, page.count, if (page.offset + page.count < page.total) "true" else "false" }) catch return;
    for (rows[0..page.count], 0..) |*row, i| {
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
    const json = alloc.alloc(u8, 64 + count * 7) catch {
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
    // `tracked` lets the web details page offer Track only for shows that are
    // not already in Watching (tracking would reset their chosen status).
    if (kind == .tv) {
        const id_num = std.fmt.parseInt(i32, id, 10) catch 0;
        w.print("],\"tracked\":{s}}}", .{if (id_num != 0 and @import("../core/db.zig").tvIsTracked(id_num)) "true" else "false"}) catch return;
    } else {
        w.writeAll("]}") catch return;
    }
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

/// Cinemeta answers when there is no TMDB key, and also when the id is a keyless
/// catalog hash of a known IMDb id even though a key exists now (a Watching row
/// or stale card from before the key was added): TMDB would answer that integer
/// with some other title entirely.
fn useKeyless(query: []const u8, kind: keyless.Kind, id: i32) bool {
    if (state.app.tmdb.api_key_len == 0) return true;
    const db = @import("../core/db.zig");
    var from_query: [32]u8 = undefined;
    var remembered: [16]u8 = undefined;
    const given: []const u8 = if (wire.queryParam(query, "imdb")) |raw| (wire.urlDecode(raw, &from_query) orelse "") else "";
    const stored = if (kind == .series) db.tvImdbId(id, &remembered) else db.movieImdbId(id, &remembered);
    const kl = @import("keyless_tv_pure.zig");
    return kl.isSynthetic(id, given) or kl.isSynthetic(id, stored);
}

fn tvDetails(stream: std.Io.net.Stream, query: []const u8) void {
    const id = std.fmt.parseInt(i32, wire.queryParam(query, "id") orelse "", 10) catch {
        wire.sendJson(stream, "{\"error\":\"bad id\"}");
        return;
    };
    const season: ?i32 = if (wire.queryParam(query, "season")) |raw| (std.fmt.parseInt(i32, raw, 10) catch 0) else null;
    if (useKeyless(query, .series, id)) {
        sendKeyless(stream, query, .series, id, season);
        return;
    }
    var path_buf: [96]u8 = undefined;
    const path = if (season) |sn|
        std.fmt.bufPrint(&path_buf, "/3/tv/{d}/season/{d}", .{ id, sn }) catch return
    else
        std.fmt.bufPrint(&path_buf, "/3/tv/{d}", .{id}) catch return;
    sendTmdbJson(stream, path);
}

/// No TMDB key: answer from Cinemeta in the TMDB document shape. The id is
/// either a TMDB id or a synthetic catalog id; either way the IMDb identity
/// comes from the `imdb` parameter or from the listing that produced the id.
fn sendKeyless(stream: std.Io.net.Stream, query: []const u8, kind: keyless.Kind, id: i32, season: ?i32) void {
    const api = @import("tmdb_api.zig");
    var imdb_buf: [32]u8 = undefined;
    var found: [16]u8 = undefined;
    var imdb: []const u8 = if (wire.queryParam(query, "imdb")) |raw| (wire.urlDecode(raw, &imdb_buf) orelse "") else "";
    if (imdb.len != 0 and !@import("cinemeta_pure.zig").validImdbId(imdb)) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"bad imdb id\"}");
        return;
    }
    if (imdb.len == 0) {
        var title_buf: [256]u8 = undefined;
        const title = if (wire.queryParam(query, "title")) |raw| (wire.urlDecode(raw, &title_buf) orelse "") else "";
        imdb = api.resolveImdb(kind, id, title, &found);
    }
    if (imdb.len == 0) {
        wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"unknown title: browse or search for it first, or pass imdb=tt...\"}");
        return;
    }
    api.rememberIdentity(kind, id, imdb);
    if (kind == .series) @import("../core/db.zig").tvRememberImdb(id, imdb) else @import("../core/db.zig").movieRememberImdb(id, imdb);
    const body = api.cinemetaMetaOwned(kind, imdb) orelse {
        wire.sendJsonStatus(stream, "502 Bad Gateway", "{\"error\":\"cinemeta fetch failed\"}");
        return;
    };
    const alloc = @import("../core/alloc.zig").allocator;
    defer alloc.free(body);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    (if (season) |sn|
        keyless.writeSeason(&out.writer, alloc, body, sn)
    else
        keyless.writeTitle(&out.writer, alloc, body, kind, id)) catch {
        wire.sendJsonStatus(stream, "502 Bad Gateway", "{\"error\":\"cinemeta returned an unusable document\"}");
        return;
    };
    wire.sendJson(stream, out.written());
}

fn movieDetails(stream: std.Io.net.Stream, query: []const u8) void {
    const id = std.fmt.parseInt(i32, wire.queryParam(query, "id") orelse "", 10) catch {
        wire.sendJson(stream, "{\"error\":\"bad id\"}");
        return;
    };
    if (useKeyless(query, .movie, id)) {
        sendKeyless(stream, query, .movie, id, null);
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
