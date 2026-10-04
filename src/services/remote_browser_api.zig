//! Direct browser link routes (docs/browser-integration.md, section 7).
//!
//!   POST /api/browser/pair     unauthenticated, code-gated: {code,label,browser,extension_id} -> {id,token}
//!   GET  /api/browser/links    host only: the paired browsers
//!   POST /api/browser/revoke   host: ?id=N removes one; a browser token unpairs itself
//!   GET  /api/browser/me       browser only: who this token is (also a cheap validity check)
//!   POST /api/browser/media    browser only: {page_url,title,art,candidates[],action} -> plays or queues
//!
//! Who may call what is decided in access_pure.zig (`browser_routes` for the
//! browser principal, `routeCapability` for the rest); the checks here repeat
//! the principal test so a mistake in one place does not open a door.

const std = @import("std");
const wire = @import("remote_http.zig");
const link = @import("browser_link.zig");
const pure = @import("browser_link_pure.zig");
const access = @import("access_pure.zig");
const forwarded_open = @import("forwarded_open.zig");
const alloc = @import("../core/alloc.zig").allocator;
const logs = @import("../core/logs.zig");

fn err(stream: std.Io.net.Stream, status: []const u8, why: []const u8) void {
    var buf: [384]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll("{\"error\":\"") catch {};
    wire.writeJsonString(&w, why);
    w.writeAll("\"}") catch {};
    wire.sendJsonStatus(stream, status, w.buffered());
}

// ── Pairing (no bearer) ────────────────────────────────────────────────────

const PairBody = struct {
    code: []const u8 = "",
    label: []const u8 = "",
    browser: []const u8 = "",
    extension_id: []const u8 = "",
};

/// Guards run cheapest first and none of the early refusals counts as a guess
/// or spends rate budget: a web page can fire cross-origin POSTs from this very
/// machine, and must not be able to use up the budget the real extension needs.
/// `consume` is the caller's per-source budget (null = allowed, else seconds to wait).
pub fn handlePair(
    stream: std.Io.net.Stream,
    method: []const u8,
    body: []const u8,
    host: ?[]const u8,
    origin: ?[]const u8,
    peer_is_loopback: bool,
    listen_port: u16,
    client_key: u64,
    consume: *const fn (key: u64) ?i64,
) void {
    if (!std.mem.eql(u8, method, "POST")) return err(stream, "405 Method Not Allowed", "method must be POST");
    // Pairing is for the browser on this machine. A LAN peer, a Host that is not
    // this loopback listener (DNS rebinding) and an Origin that is a web page
    // are all refused before a guess is counted.
    if (!peer_is_loopback) return err(stream, "403 Forbidden", "pairing is only accepted from this machine");
    if (!pure.hostAllowed(host, listen_port)) return err(stream, "403 Forbidden", "unexpected Host header");
    if (!pure.pairOriginAllowed(origin)) return err(stream, "403 Forbidden", "pairing is only accepted from the extension");

    if (consume(client_key)) |wait| {
        wire.sendRateLimited(stream, wait, "{\"error\":\"too many requests\"}");
        return;
    }

    var parsed = std.json.parseFromSlice(PairBody, alloc, body, .{ .ignore_unknown_fields = true }) catch
        return err(stream, "400 Bad Request", "body must be JSON {code,label,browser,extension_id}");
    defer parsed.deinit();
    const req = parsed.value;

    switch (link.pair(req.code, req.label, req.browser, req.extension_id)) {
        .ok => |ok| {
            var out: [192]u8 = undefined;
            const json = std.fmt.bufPrint(&out, "{{\"ok\":true,\"id\":{d},\"token\":\"{s}\"}}", .{ ok.id, ok.token[0..] }) catch
                return err(stream, "500 Internal Server Error", "server error");
            logs.pushLog("info", "browser", "A browser was paired", false);
            wire.sendJson(stream, json);
        },
        .wrong_code => err(stream, "403 Forbidden", "wrong code"),
        .burned => err(stream, "403 Forbidden", "too many wrong codes: start pairing again in Opal"),
        .expired => err(stream, "403 Forbidden", "the code expired: start pairing again in Opal"),
        .no_code => err(stream, "403 Forbidden", "pairing is not started: choose Pair in Opal's Settings"),
        .full => err(stream, "409 Conflict", "too many paired browsers: revoke one in Opal first"),
        .unavailable => err(stream, "503 Service Unavailable", "database not ready"),
    }
}

// ── Authenticated routes ───────────────────────────────────────────────────

/// `path` is relative to `/api`. Returns false for a path that is not ours.
pub fn handle(
    stream: std.Io.net.Stream,
    method: []const u8,
    path: []const u8,
    query: []const u8,
    body: []const u8,
    principal: access.Principal,
    presented: []const u8,
) bool {
    if (!std.mem.startsWith(u8, path, "/browser/")) return false;
    if (std.mem.eql(u8, path, "/browser/links")) {
        if (!wire.requireMethod(stream, method, "GET")) return true;
        if (principal != .machine and principal != .admin_session) {
            err(stream, "403 Forbidden", "insufficient capability");
            return true;
        }
        links(stream);
        return true;
    }
    if (std.mem.eql(u8, path, "/browser/revoke")) {
        if (!wire.requireMethod(stream, method, "POST")) return true;
        revokeRoute(stream, query, body, principal, presented);
        return true;
    }
    if (std.mem.eql(u8, path, "/browser/me")) {
        if (!wire.requireMethod(stream, method, "GET")) return true;
        if (principal != .browser) {
            err(stream, "403 Forbidden", "insufficient capability");
            return true;
        }
        me(stream, presented);
        return true;
    }
    if (std.mem.eql(u8, path, "/browser/media")) {
        if (!wire.requireMethod(stream, method, "POST")) return true;
        if (principal != .browser) {
            err(stream, "403 Forbidden", "insufficient capability");
            return true;
        }
        media(stream, body);
        return true;
    }
    return false;
}

fn links(stream: std.Io.net.Stream) void {
    var rows: [pure.MAX_LINKS]link.Link = undefined;
    const n = link.list(&rows);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    w.writeAll("{\"links\":[") catch return;
    for (rows[0..n], 0..) |*row, i| {
        if (i > 0) w.writeByte(',') catch return;
        w.print("{{\"id\":{d},\"label\":\"", .{row.id}) catch return;
        wire.writeJsonString(w, row.labelSlice());
        w.writeAll("\",\"browser\":\"") catch return;
        wire.writeJsonString(w, row.browserSlice());
        w.print("\",\"created_at\":{d},\"last_seen\":{d}}}", .{ row.created_at, row.last_seen }) catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, out.written());
}

fn revokeRoute(stream: std.Io.net.Stream, query: []const u8, body: []const u8, principal: access.Principal, presented: []const u8) void {
    if (principal == .browser) {
        // A browser unpairs only itself, whatever id it names.
        if (link.revokeToken(presented)) {
            logs.pushLog("info", "browser", "A browser unpaired itself", false);
            wire.sendJson(stream, "{\"ok\":true}");
        } else err(stream, "404 Not Found", "not paired");
        return;
    }
    if (principal != .machine and principal != .admin_session) {
        err(stream, "403 Forbidden", "insufficient capability");
        return;
    }
    var id_buf: [24]u8 = undefined;
    const id = std.fmt.parseInt(i64, wire.formParam(body, query, "id", &id_buf) orelse "", 10) catch
        return err(stream, "400 Bad Request", "id required");
    if (link.revoke(id)) {
        logs.pushLog("info", "browser", "A paired browser was revoked", false);
        wire.sendJson(stream, "{\"ok\":true}");
    } else err(stream, "404 Not Found", "no such paired browser");
}

fn me(stream: std.Io.net.Stream, presented: []const u8) void {
    const id = link.validToken(presented) orelse return err(stream, "401 Unauthorized", "not paired");
    var row: link.Link = undefined;
    if (!link.linkById(id, &row)) return err(stream, "401 Unauthorized", "not paired");
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("{{\"ok\":true,\"id\":{d},\"label\":\"", .{id}) catch return;
    wire.writeJsonString(&w, row.labelSlice());
    w.writeAll("\"}") catch return;
    wire.sendJson(stream, w.buffered());
}

fn media(stream: std.Io.net.Stream, body: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const m = pure.parseMedia(arena.allocator(), body) catch |e|
        return err(stream, "400 Bad Request", pure.parseErrorMessage(e));
    const pick = pure.best(m.candidates) orelse return err(stream, "400 Bad Request", "at least one candidate is required");

    const queue_only = m.action == .queue;
    var hb: pure.HeaderBuf = .{};
    const headers = pure.playHeaders(pick.*, m.page_url, &hb);
    var referer: []const u8 = "";
    var origin: []const u8 = "";
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, "Referer")) referer = h.value;
        if (std.mem.eql(u8, h.name, "Origin")) origin = h.value;
    }

    if (queue_only and pick.url.len > pure.MAX_QUEUE_URL)
        return err(stream, "400 Bad Request", "this URL is too long to queue (2047 bytes); play it instead");

    if (!forwarded_open.pushBrowser(queue_only, pick.url, m.title, m.art, referer, origin, pick.ua))
        return err(stream, "503 Service Unavailable", "Opal is busy opening other media, try again");

    // The queue stores a bare URL, so a queued stream plays later without the
    // Referer/User-Agent it was found with. Say so rather than imply otherwise.
    const dropped = queue_only and (referer.len > 0 or origin.len > 0 or pick.ua.len > 0);
    var out: [192]u8 = undefined;
    const json = std.fmt.bufPrint(&out, "{{\"ok\":true,\"action\":\"{s}\",\"kind\":\"{s}\",\"referer_sent\":{s},\"queued_without_headers\":{s}}}", .{
        @tagName(m.action),
        @tagName(pick.kind),
        if (referer.len > 0 and !queue_only) "true" else "false",
        if (dropped) "true" else "false",
    }) catch return err(stream, "500 Internal Server Error", "server error");
    wire.sendJson(stream, json);
}
