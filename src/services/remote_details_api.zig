//! Movie and TV details routes for the web companion: TMDB proxy when a key
//! exists, Cinemeta in the TMDB document shape when it does not.

const std = @import("std");
const keyless = @import("cinemeta_meta_pure.zig");
const state = @import("../core/state.zig");
const wire = @import("remote_http.zig");

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

pub fn tvDetails(stream: std.Io.net.Stream, query: []const u8) void {
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

pub fn movieDetails(stream: std.Io.net.Stream, query: []const u8) void {
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
