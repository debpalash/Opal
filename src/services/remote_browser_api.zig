//! Direct browser link routes (docs/browser-integration.md, section 7).
//!
//!   POST /api/browser/pair     unauthenticated, code-gated: {code,label,browser,extension_id} -> {id,token}
//!   GET  /api/browser/links    host only: the paired browsers
//!   POST /api/browser/revoke   host: ?id=N removes one; a browser token unpairs itself
//!   GET  /api/browser/me       browser only: who this token is (also a cheap validity check)
//!   POST /api/browser/media    browser only: {page_url,title,art,candidates[],action} -> plays or queues, or
//!                              (action add_to_wanted, no candidates) adds the user-edited title to Wanted
//!   POST /api/browser/page     browser only: the page the user chose to share (kept in memory, last one only)
//!   POST /api/browser/tabs     browser only: the open tabs; refused with the user's switch off, nothing stored
//!   GET  /api/browser/context  host only (machine token, admin session): ?view=status|page|candidates|tabs, what
//!                              agents may see; content views are empty unless the user allowed agents twice
//!   POST /api/browser/play     host only: ?page=&id=&action=play|queue, a candidate of the shared page by id
//!   POST /api/browser/fetch    host only: ?url= fetched through the user's browser with their cookies, for an
//!                              origin the user allowed in the extension; blocks until answered (403 if not allowed)
//!   GET  /api/browser/jobs     browser only: long poll (?wait=seconds) for a page Opal wants fetched
//!   POST /api/browser/jobs/<id> browser only: the answer, metadata in the query and the page text as the raw body
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
const shared_page = @import("browser_page.zig");
const tabs_store = @import("browser_tabs.zig");
const tabs_pure = @import("browser_tabs_pure.zig");
const fetcher = @import("browser_fetch.zig");
const fetch_pure = @import("browser_fetch_pure.zig");
const wanted = @import("wanted.zig");
const wanted_pure = @import("wanted_pure.zig");
const alloc = @import("../core/alloc.zig").allocator;
const logs = @import("../core/logs.zig");
const io_g = @import("../core/io_global.zig");

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
    if (std.mem.eql(u8, path, "/browser/page")) {
        if (!wire.requireMethod(stream, method, "POST")) return true;
        if (principal != .browser) {
            err(stream, "403 Forbidden", "insufficient capability");
            return true;
        }
        sharePage(stream, body, presented);
        return true;
    }
    if (std.mem.eql(u8, path, "/browser/tabs")) {
        if (!wire.requireMethod(stream, method, "POST")) return true;
        if (principal != .browser) {
            err(stream, "403 Forbidden", "insufficient capability");
            return true;
        }
        tabsReport(stream, body);
        return true;
    }
    if (std.mem.eql(u8, path, "/browser/context")) {
        if (!wire.requireMethod(stream, method, "GET")) return true;
        if (principal != .machine and principal != .admin_session) {
            err(stream, "403 Forbidden", "insufficient capability");
            return true;
        }
        context(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/browser/play")) {
        if (!wire.requireMethod(stream, method, "POST")) return true;
        if (principal != .machine and principal != .admin_session) {
            err(stream, "403 Forbidden", "insufficient capability");
            return true;
        }
        playCandidate(stream, query, body);
        return true;
    }
    if (std.mem.eql(u8, path, "/browser/fetch")) {
        if (!wire.requireMethod(stream, method, "POST")) return true;
        if (principal != .machine and principal != .admin_session) {
            err(stream, "403 Forbidden", "insufficient capability");
            return true;
        }
        fetchRoute(stream, query, body);
        return true;
    }
    if (std.mem.eql(u8, path, "/browser/jobs")) {
        if (!wire.requireMethod(stream, method, "GET")) return true;
        if (principal != .browser) {
            err(stream, "403 Forbidden", "insufficient capability");
            return true;
        }
        jobsRoute(stream, query, presented);
        return true;
    }
    if (access.browserJobResultId(path)) |id| {
        if (!wire.requireMethod(stream, method, "POST")) return true;
        if (principal != .browser) {
            err(stream, "403 Forbidden", "insufficient capability");
            return true;
        }
        jobResultRoute(stream, id, query, body, presented);
        return true;
    }
    return false;
}

// ── Fetch through the user's browser ───────────────────────────────────────

/// `POST /api/browser/fetch?url=`. GET only on this route: a POST through the
/// user's logged-in session is an action, not a read, and no agent tool offers
/// one (the scraper's form POST uses the internal call, not this route).
fn fetchRoute(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var url_buf: [fetch_pure.MAX_URL + 1]u8 = undefined;
    const url = wire.formParam(body, query, "url", &url_buf) orelse
        return err(stream, "400 Bad Request", "url is required");
    fetch_pure.validateTarget(url) catch |e|
        return err(stream, "400 Bad Request", fetch_pure.targetErrorMessage(e));

    const result = fetcher.fetch(.{ .url = url, .method = .get, .prompt = true }, null);
    switch (result) {
        .ok => |f| {
            defer fetcher.freeBody(f.body);
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            fetch_pure.writeAgentJson(alloc, &out.writer, &f.outcome, f.body) catch
                return err(stream, "500 Internal Server Error", "server error");
            logs.pushLog("info", "browser", if (fetch_pure.isPrivateTarget(url))
                "A page on the private network was fetched through the paired browser"
            else
                "A page was fetched through the paired browser", false);
            wire.sendJson(stream, out.written());
        },
        .failed => |code| err(stream, code.httpStatus(), code.message()),
        .no_browser => err(stream, "503 Service Unavailable", "no paired browser is connected: open the browser with Opal Connect paired"),
        .busy => err(stream, "429 Too Many Requests", "too many fetches are waiting, try again shortly"),
        .bad_request => err(stream, "400 Bad Request", "this request cannot be fetched"),
        .cancelled => err(stream, "503 Service Unavailable", "cancelled"),
    }
}

/// True when the client of an idle request has closed its end. A GET that is
/// waiting for an answer sends nothing more, so readable means end of stream
/// (or an error); anything else is unexpected and also ends the wait.
fn peerClosed(stream: std.Io.net.Stream) bool {
    if (@import("builtin").os.tag == .windows) return false;
    var pfd = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&pfd, 0) catch return false;
    return ready > 0;
}

fn jobsRoute(stream: std.Io.net.Stream, query: []const u8, presented: []const u8) void {
    const browser_id = link.validToken(presented) orelse return err(stream, "401 Unauthorized", "not paired");
    var wb: [8]u8 = undefined;
    const wait = std.fmt.parseInt(i64, wire.formParam("", query, "wait", &wb) orelse "0", 10) catch 0;
    var job: fetch_pure.Job = undefined;
    const wait_s = std.math.clamp(wait, 0, fetch_pure.POLL_MAX_WAIT_S);
    const started = io_g.timestamp();
    while (true) {
        // Never claim a job for a browser that already hung up (it would sit
        // claimed until its deadline): look at the socket before each attempt.
        if (peerClosed(stream)) return;
        if (fetcher.pollOnce(browser_id, &job)) break;
        if (io_g.timestamp() - started >= wait_s) return wire.sendJson(stream, "{\"job\":null}");
        io_g.sleep(100 * std.time.ns_per_ms);
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    w.print("{{\"job\":{{\"id\":{d},\"method\":\"{s}\",\"prompt\":{s},\"url\":\"", .{
        job.id,
        if (job.method == .post) "POST" else "GET",
        if (job.prompt) "true" else "false",
    }) catch return err(stream, "500 Internal Server Error", "server error");
    wire.writeJsonString(w, job.urlSlice());
    w.writeAll("\",\"body\":\"") catch return;
    wire.writeJsonString(w, job.bodySlice());
    w.writeAll("\"}}") catch return;
    wire.sendJson(stream, out.written());
}

/// The head was split from the body by the caller: `body` is the page text.
fn jobResultRoute(stream: std.Io.net.Stream, id: u32, query: []const u8, body: []const u8, presented: []const u8) void {
    const browser_id = link.validToken(presented) orelse return err(stream, "401 Unauthorized", "not paired");
    switch (fetcher.complete(browser_id, id, query, body)) {
        .ok => wire.sendJson(stream, "{\"ok\":true}"),
        .bad_result => |e| err(stream, "400 Bad Request", switch (e) {
            error.Malformed => "malformed result",
            error.NotText => "only text, JSON and HTML are accepted",
            error.BinaryBody => "the body is not text",
            error.TooLarge => "the body is over 2 MB",
        }),
        .no_such_job => err(stream, "404 Not Found", "no such job"),
        .not_yours => err(stream, "403 Forbidden", "that job belongs to another browser"),
        .expired => err(stream, "410 Gone", "the job expired"),
        .unavailable => err(stream, "503 Service Unavailable", "server busy"),
    }
}

fn sharePage(stream: std.Io.net.Stream, body: []const u8, presented: []const u8) void {
    const link_id = link.validToken(presented) orelse return err(stream, "401 Unauthorized", "not paired");
    const id = shared_page.share(body, link_id) catch |e|
        return err(stream, "400 Bad Request", @import("browser_page_pure.zig").parseErrorMessage(e));
    shared_page.logShared();
    var out: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&out, "{{\"ok\":true,\"page_id\":{d}}}", .{id}) catch
        return err(stream, "500 Internal Server Error", "server error");
    wire.sendJson(stream, json);
}

/// The browser's tab list. With the user's switch off nothing is read, stored or
/// kept: the answer says so and the extension stops reporting.
fn tabsReport(stream: std.Io.net.Stream, body: []const u8) void {
    tabs_store.report(body) catch |e| switch (e) {
        error.SwitchOff => return err(stream, "403 Forbidden", "tab sharing is off in Opal (Settings > Agent Access > Share tab list with agents)"),
        error.BadJson => return err(stream, "400 Bad Request", tabs_pure.parseErrorMessage(error.BadJson)),
        error.TooManyTabs => return err(stream, "400 Bad Request", tabs_pure.parseErrorMessage(error.TooManyTabs)),
        error.Empty => return err(stream, "400 Bad Request", tabs_pure.parseErrorMessage(error.Empty)),
    };
    wire.sendJson(stream, "{\"ok\":true}");
}

fn context(stream: std.Io.net.Stream, query: []const u8) void {
    var vb: [16]u8 = undefined;
    const name = wire.formParam("", query, "view", &vb) orelse "status";
    if (std.mem.eql(u8, name, "tabs")) {
        var tabs_out: std.Io.Writer.Allocating = .init(alloc);
        defer tabs_out.deinit();
        tabs_store.writeContext(&tabs_out.writer) catch return err(stream, "500 Internal Server Error", "server error");
        return wire.sendJson(stream, tabs_out.written());
    }
    const view: shared_page.View = if (std.mem.eql(u8, name, "status"))
        .status
    else if (std.mem.eql(u8, name, "page"))
        .page
    else if (std.mem.eql(u8, name, "candidates"))
        .candidates
    else
        return err(stream, "400 Bad Request", "view must be status, page, candidates or tabs");
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    shared_page.writeContext(&out.writer, view) catch return err(stream, "500 Internal Server Error", "server error");
    wire.sendJson(stream, out.written());
}

fn playCandidate(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var pb: [16]u8 = undefined;
    var ib: [16]u8 = undefined;
    var ab: [8]u8 = undefined;
    const page_id = std.fmt.parseInt(u32, wire.formParam(body, query, "page", &pb) orelse "", 10) catch
        return err(stream, "400 Bad Request", "page required: the page_id from browser_media_candidates");
    const id = std.fmt.parseInt(u32, wire.formParam(body, query, "id", &ib) orelse "", 10) catch
        return err(stream, "400 Bad Request", "id required: a candidate id from browser_media_candidates");
    const action = wire.formParam(body, query, "action", &ab) orelse "play";
    const queue_only = if (std.mem.eql(u8, action, "queue")) true else if (std.mem.eql(u8, action, "play")) false else
        return err(stream, "400 Bad Request", "action must be play or queue");
    const played = shared_page.playForAgent(page_id, id, queue_only) catch |e| switch (e) {
        error.not_shared => return err(stream, "403 Forbidden", "no page is shared with agents (the user decides in the Opal Connect panel and Settings > Agent Access)"),
        error.stale => return err(stream, "409 Conflict", "the shared page changed: read browser_media_candidates again"),
        error.missing => return err(stream, "404 Not Found", "no such candidate on the shared page"),
        error.busy => return err(stream, "503 Service Unavailable", "Opal is busy opening other media, try again"),
    };
    var out: [192]u8 = undefined;
    const json = std.fmt.bufPrint(&out, "{{\"ok\":true,\"action\":\"{s}\",\"kind\":\"{s}\",\"referer_sent\":{s}}}", .{
        if (queue_only) "queue" else "play",
        @tagName(played.kind),
        if (played.referer_sent) "true" else "false",
    }) catch return err(stream, "500 Internal Server Error", "server error");
    wire.sendJson(stream, json);
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
    w.print("{{\"ok\":true,\"id\":{d},\"share_tabs\":{s},\"label\":\"", .{ id, if (tabs_store.switchOn()) "true" else "false" }) catch return;
    wire.writeJsonString(&w, row.labelSlice());
    w.writeAll("\"}") catch return;
    wire.sendJson(stream, w.buffered());
}

fn media(stream: std.Io.net.Stream, body: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const m = pure.parseMedia(arena.allocator(), body) catch |e|
        return err(stream, "400 Bad Request", pure.parseErrorMessage(e));
    if (m.action == .add_to_wanted) return addToWanted(stream, m.title);
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

    // A queued stream keeps the Referer, Origin and User-Agent it was found with
    // (queue.rememberHttpIdentity, keyed by URL) and plays with them later.
    const keeps = queue_only and (referer.len > 0 or origin.len > 0 or pick.ua.len > 0);
    var out: [192]u8 = undefined;
    const json = std.fmt.bufPrint(&out, "{{\"ok\":true,\"action\":\"{s}\",\"kind\":\"{s}\",\"referer_sent\":{s},\"headers_kept\":{s}}}", .{
        @tagName(m.action),
        @tagName(pick.kind),
        if (referer.len > 0 and !queue_only) "true" else "false",
        if (keeps) "true" else "false",
    }) catch return err(stream, "500 Internal Server Error", "server error");
    wire.sendJson(stream, json);
}

/// `action: add_to_wanted`. The title is whatever the user typed or edited in the
/// extension (a page title is rarely a clean "Dune 2021"); the same parser as the
/// Wanted box in the app turns it into a movie or an episode.
fn addToWanted(stream: std.Io.net.Stream, title: []const u8) void {
    const parsed = wanted_pure.parseRequest(title) orelse
        return err(stream, "400 Bad Request", "type a title first, for example Dune 2021 or Severance S02E03");
    var out: [320]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    const result: []const u8 = switch (wanted.add(.{ .kind = parsed.kind, .title = parsed.title, .year = parsed.year, .season = parsed.season, .episode = parsed.episode })) {
        .added => "added",
        .exists => "exists",
        .invalid => |why| return err(stream, "400 Bad Request", why),
        .full => return err(stream, "409 Conflict", "the Wanted list is full"),
        .unavailable => return err(stream, "503 Service Unavailable", "the Wanted list is not available right now"),
    };
    w.print("{{\"ok\":true,\"action\":\"add_to_wanted\",\"result\":\"{s}\",\"kind\":\"{s}\",\"title\":\"", .{ result, @tagName(parsed.kind) }) catch return;
    wire.writeJsonString(&w, parsed.title);
    w.writeAll("\"}") catch return;
    if (std.mem.eql(u8, result, "added")) logs.pushLog("info", "browser", "A title was added to Wanted from the paired browser", false);
    wire.sendJson(stream, w.buffered());
}
