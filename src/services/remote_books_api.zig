//! Audiobookshelf and OPDS catalog HTTP adapters; shared wire helpers, owner-thread actions.
const std = @import("std");
const state = @import("../core/state.zig");
const txt = @import("../core/text.zig");
const wire = @import("remote_http.zig");
const getQueryParam = wire.queryParam;
const sendJson = wire.sendJson;
const sendJsonStatus = wire.sendJsonStatus;
const requireMethod = wire.requireMethod;
const credParam = @import("remote.zig").credParam;
const escJsonWrite = wire.writeJsonString;

/// GET /api/abs — Audiobookshelf: libraries → books → play.
///
/// `POST /abs/login`, `/abs/libraries`, `/abs/open?idx=`,
/// `/abs/back`, `/abs/more`, `/abs/play?idx=`, `/abs/logout`.
pub fn apiAbs(stream: std.Io.net.Stream, method: []const u8, api_path: []const u8, query: []const u8, body: []const u8) void {
    const abs = @import("audiobookshelf.zig");
    const s = &state.app.abs;

    if (std.mem.eql(u8, api_path, "/abs/login")) {
        if (!requireMethod(stream, method, "POST")) return;
        // Credentials come from the POST body where possible (credParam), so a
        // password never lands in a URL or an access log — same rule as
        // /api/auth/login.
        var dec: [256]u8 = undefined;
        defer @memset(&dec, 0);
        if (credParam(body, "", "server", &dec)) |v| {
            const sv = txt.safeUtf8(v);
            abs.setServerUrl(sv);
        }
        if (credParam(body, "", "user", &dec)) |v| {
            const uv = txt.safeUtf8(v);
            @memset(&s.login_user_buf, 0);
            const n = @min(uv.len, s.login_user_buf.len - 1);
            @memcpy(s.login_user_buf[0..n], uv[0..n]);
            s.login_user_buf[n] = 0;
        }
        if (credParam(body, "", "pass", &dec)) |pv| {
            @memset(&s.login_pass_buf, 0);
            const n = @min(pv.len, s.login_pass_buf.len - 1);
            @memcpy(s.login_pass_buf[0..n], pv[0..n]);
            s.login_pass_buf[n] = 0;
        }
        abs.authenticate();
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_login\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/logout")) {
        if (!requireMethod(stream, method, "POST")) return;
        abs.disconnect();
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_logout\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/libraries")) {
        if (!requireMethod(stream, method, "POST")) return;
        abs.fetchLibraries();
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_libraries\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/open")) {
        if (!requireMethod(stream, method, "POST")) return;
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= s.library_count) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such library\"}");
            return;
        }
        abs.openLibrary(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_open\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/back")) {
        if (!requireMethod(stream, method, "POST")) return;
        abs.goToLibraries();
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_back\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/more")) {
        if (!requireMethod(stream, method, "POST")) return;
        abs.loadMore();
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_more\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/play")) {
        if (!requireMethod(stream, method, "POST")) return;
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (idx >= s.book_count) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such book\"}");
            return;
        }
        abs.playBook(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_play\"}");
        return;
    }

    if (std.mem.eql(u8, api_path, "/abs/audio")) {
        if (!requireMethod(stream, method, "POST")) return;
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "", 10) catch {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid track index\"}");
            return;
        };
        const generation = std.fmt.parseInt(u32, getQueryParam(query, "generation") orelse "", 10) catch {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid audio generation\"}");
            return;
        };
        if (!abs.playAudioTrack(idx, generation)) {
            sendJsonStatus(stream, "409 Conflict", "{\"error\":\"audio selection changed; refresh and retry\"}");
            return;
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"abs_audio\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/audio/book")) {
        if (!requireMethod(stream, method, "POST")) return;
        const generation = std.fmt.parseInt(u32, getQueryParam(query, "generation") orelse "", 10) catch {
            sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid audio generation\"}");
            return;
        };
        if (!abs.playWholeBook(generation)) {
            sendJsonStatus(stream, "409 Conflict", "{\"error\":\"complete book timeline is unavailable; refresh selection\"}");
            return;
        }
        sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/abs/audio/close")) {
        if (!requireMethod(stream, method, "POST")) return;
        abs.clearAudioSelection();
        sendJson(stream, "{\"ok\":true}");
        return;
    }

    if (!std.mem.eql(u8, api_path, "/abs")) {
        sendJsonStatus(stream, "404 Not Found", "{\"error\":\"unknown Audiobookshelf action\"}");
        return;
    }
    if (!requireMethod(stream, method, "GET")) return;
    const a = @import("../core/alloc.zig").allocator;
    const pure = @import("audiobookshelf_pure.zig");
    const books = a.alloc(pure.Book, 320) catch return;
    defer a.free(books);
    var libraries: [16]pure.Library = undefined;
    const catalog = abs.catalogSnapshot(books, &libraries);
    const tracks = a.alloc(pure.AudioTrack, 128) catch return;
    defer a.free(tracks);
    const audio = abs.audioSnapshot(tracks);
    const json_buf = a.alloc(u8, 1280 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"connected\":{s},\"loading\":{s},\"loading_more\":{s},\"has_more\":{s},\"view\":\"{s}\",\"server\":\"", .{
        if (catalog.connected) "true" else "false",    if (catalog.loading) "true" else "false",
        if (catalog.loading_more) "true" else "false", if (catalog.has_more) "true" else "false",
        catalog.view,
    }) catch return;
    escJsonWrite(&w, catalog.server[0..catalog.server_len]);
    w.writeAll("\",\"error\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(catalog.error_text[0..catalog.error_len]));
    w.writeAll("\",\"library\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(catalog.library[0..catalog.library_len]));
    w.writeAll("\",\"libraries\":[") catch return;
    for (libraries[0..catalog.library_count], 0..) |*library, idx| {
        if (idx > 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(library.name[0..@min(library.name_len, library.name.len)]));
        w.writeAll("\",\"media_type\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(library.media_type[0..@min(library.media_type_len, library.media_type.len)]));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"books\":[") catch return;
    for (books[0..catalog.book_count], 0..) |*book, idx| {
        if (idx > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(book.title[0..@min(book.title_len, book.title.len)]));
        w.writeAll("\",\"author\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(book.author[0..@min(book.author_len, book.author.len)]));
        w.print("\",\"duration\":{d}}}", .{book.duration_secs}) catch return;
    }
    w.print("],\"audio\":{{\"visible\":{s},\"complete_book\":{s},\"loading\":{s},\"generation\":{d},\"returned\":{d},\"total\":{d},\"truncated\":{s},\"title\":\"", .{
        if (audio.visible) "true" else "false", if (audio.complete_book) "true" else "false", if (audio.loading) "true" else "false",             audio.generation,
        audio.count,                            audio.total,                                  if (audio.count < audio.total) "true" else "false",
    }) catch return;
    escJsonWrite(&w, txt.safeUtf8(audio.title[0..audio.title_len]));
    w.writeAll("\",\"tracks\":[") catch return;
    for (tracks[0..audio.count], 0..) |*track, idx| {
        if (idx > 0) w.writeAll(",") catch return;
        w.print("{{\"index\":{d},\"episode\":{s},\"title\":\"", .{ idx, if (track.episode) "true" else "false" }) catch return;
        escJsonWrite(&w, txt.safeUtf8(track.title[0..track.title_len]));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}

/// OPDS catalog support (Komga / Kavita / Calibre-Web / LANraragi).
/// Browse-only: `POST /opds/connect`, `/opds/open?idx=`, `/opds/back`, `/opds/more`,
/// `/opds/disconnect`.
pub fn apiOpds(stream: std.Io.net.Stream, method: []const u8, api_path: []const u8, query: []const u8, body: []const u8) void {
    const opds = @import("opds.zig");
    const o = &state.app.opds;

    if (std.mem.eql(u8, api_path, "/opds/connect")) {
        if (!requireMethod(stream, method, "POST")) return;
        var connection = opds.connectionSnapshot();
        defer @memset(std.mem.asBytes(&connection), 0);
        var dec: [256]u8 = undefined;
        defer @memset(&dec, 0);
        if (credParam(body, "", "server", &dec)) |value| {
            connection.server_len = @min(value.len, connection.server.len);
            @memcpy(connection.server[0..connection.server_len], value[0..connection.server_len]);
        }
        if (credParam(body, "", "user", &dec)) |value| {
            connection.user_len = @min(value.len, connection.user.len - 1);
            @memcpy(connection.user[0..connection.user_len], value[0..connection.user_len]);
        }
        if (credParam(body, "", "pass", &dec)) |value| {
            connection.pass_len = @min(value.len, connection.pass.len - 1);
            @memcpy(connection.pass[0..connection.pass_len], value[0..connection.pass_len]);
        }
        opds.configureConnection(connection.server[0..connection.server_len], connection.user[0..connection.user_len], connection.pass[0..connection.pass_len]);
        opds.connect();
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_connect\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/opds/disconnect")) {
        if (!requireMethod(stream, method, "POST")) return;
        opds.disconnect();
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_disconnect\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/opds/open")) {
        if (!requireMethod(stream, method, "POST")) return;
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (getQueryParam(query, "generation") == null and idx >= opds.entryCount()) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such entry\"}");
            return;
        }
        if (getQueryParam(query, "generation")) |value| {
            const generation = std.fmt.parseInt(u32, value, 10) catch {
                sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid catalog generation\"}");
                return;
            };
            if (!opds.openEntryExpected(idx, generation)) {
                sendJsonStatus(stream, "409 Conflict", "{\"error\":\"catalog changed; refresh before reading\"}");
                return;
            }
        } else opds.openEntry(idx);
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_open\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/opds/category")) {
        if (!requireMethod(stream, method, "POST")) return;
        const idx = std.fmt.parseInt(usize, getQueryParam(query, "idx") orelse "999", 10) catch 999;
        if (!opds.openDiscoveryCategory(idx)) {
            sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such discovery category\"}");
            return;
        }
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_category\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/opds/back")) {
        if (!requireMethod(stream, method, "POST")) return;
        opds.goBack();
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_back\"}");
        return;
    }
    if (std.mem.eql(u8, api_path, "/opds/more")) {
        if (!requireMethod(stream, method, "POST")) return;
        opds.loadMore();
        sendJson(stream, "{\"ok\":true,\"action\":\"opds_more\"}");
        return;
    }

    if (!std.mem.eql(u8, api_path, "/opds")) {
        sendJsonStatus(stream, "404 Not Found", "{\"error\":\"unknown OPDS action\"}");
        return;
    }
    if (!requireMethod(stream, method, "GET")) return;
    opds.ensureLoadedOnce();
    const a = @import("../core/alloc.zig").allocator;
    const json_buf = a.alloc(u8, 256 * 1024) catch return;
    defer a.free(json_buf);
    var w = std.Io.Writer.fixed(json_buf);
    w.print("{{\"generation\":{d},\"connected\":{s},\"loading\":{s},\"depth\":{d},\"error\":{s},\"message\":\"", .{
        opds.catalogGeneration(),
        if (o.connected) "true" else "false",
        if (o.is_loading.load(.acquire)) "true" else "false",
        o.nav_depth,
        if (o.fetch_error) "true" else "false",
    }) catch return;
    escJsonWrite(&w, txt.safeUtf8(o.error_msg[0..@min(o.error_msg_len, o.error_msg.len)]));
    w.writeAll("\",\"server\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(o.server_url[0..@min(o.server_url_len, o.server_url.len)]));
    w.writeAll("\",\"feed\":\"") catch return;
    escJsonWrite(&w, txt.safeUtf8(o.feed_title[0..@min(o.feed_title_len, o.feed_title.len)]));
    const discovery = opds.discoverySnapshot();
    w.print("\",\"discovery\":{s},\"categories\":[", .{if (discovery.active) "true" else "false"}) catch return;
    for (discovery.categories[0..discovery.count], 0..) |category, index| {
        if (index > 0) w.writeAll(",") catch return;
        w.print("{{\"index\":{d},\"title\":\"", .{index}) catch return;
        escJsonWrite(&w, txt.safeUtf8(category.titleSlice()));
        w.writeAll("\"}") catch return;
    }
    w.writeAll("],\"entries\":[") catch return;
    const n = opds.entryCount();
    var emitted: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row = opds.entryRow(i) orelse continue;
        const e = &row;
        if (emitted > 0) w.writeAll(",") catch return;
        w.writeAll("{\"title\":\"") catch return;
        escJsonWrite(&w, txt.safeUtf8(e.titleSlice()));
        w.print("\",\"nav\":{s},\"streamable\":{s},\"pages\":{d},\"type\":\"", .{
            if (e.is_navigation) "true" else "false",
            if (e.isPseStreamable()) "true" else "false",
            e.pse_count,
        }) catch return;
        escJsonWrite(&w, txt.safeUtf8(e.contentTypeSlice()));
        const gutenberg = @import("opds_pure.zig").gutenbergWorkId(e.hrefSlice()) != null;
        w.print("\",\"gutenberg\":{s},\"author\":\"", .{if (gutenberg) "true" else "false"}) catch return;
        escJsonWrite(&w, txt.safeUtf8(e.author[0..e.author_len]));
        w.writeAll("\",\"cover\":\"") catch return;
        // Official public book covers require no personal-library credentials.
        if (gutenberg and std.mem.startsWith(u8, e.coverSlice(), "https://www.gutenberg.org/")) escJsonWrite(&w, e.coverSlice());
        w.writeAll("\"}") catch return;
        emitted += 1;
    }
    w.writeAll("]}") catch return;
    sendJson(stream, json_buf[0..w.end]);
}
