//! Continuum handoff (ROADMAP 7.4): move playback between Opals at the exact
//! second.
//!
//!   POST /api/handoff          receive: source=&title=&pos=&dur= (form). The
//!                              source must be http(s) or a magnet — never a
//!                              local path. Played through the normal
//!                              PlaybackRequest path at `pos` on the UI thread.
//!   GET  /api/handoff          the last handoff this host received (status)
//!   GET  /api/handoff/offer    [pause=1] this host's current item as a payload
//!                              ("Bring here" on another device reads this)
//!   POST /api/handoff/send     peer=<url>&token=<bearer>[&id=<library id>&pos=]
//!                              push the current item (or a library item) to a peer
//!   POST /api/handoff/bring    peer=<url>&token=<bearer> — take over the peer's item
//!
//! URLs and magnets travel as themselves. A local file travels as a direct
//! stream URL to THIS host (stream_session, signed token in the path) at an
//! address the peer can reach: 127.0.0.1 for a loopback peer, else our LAN
//! IPv4 (remote.lanIp), or the Host header the caller used for an offer.
//! Limits: per-request HTTP headers (Referer/cookies) do not travel; a
//! loopback-only source (a local proxy URL) is refused; a magnet resumes via
//! the torrent engine, which does not apply the exact second.
//!
//! The native "Continue on…" / "Bring here" actions (ui/continuum_ui.zig) run
//! on one worker (struct-static job, peer copied by value); results surface
//! as toasts from tick() on the UI thread. Wire format: stream_pure.zig.

const std = @import("std");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const io_g = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const workers = @import("../core/workers.zig");
const c = @import("../core/c.zig");
const wire = @import("remote_http.zig");
const pure = @import("stream_pure.zig");
const sync_pure = @import("library_sync_pure.zig");
const session = @import("stream_session.zig");
const reliable_fetch = @import("reliable_fetch.zig");

// ── Current item ──────────────────────────────────────────────────────────

pub const Current = struct {
    url: [pure.SOURCE_MAX]u8 = undefined,
    url_len: usize = 0,
    title: [pure.TITLE_MAX]u8 = undefined,
    title_len: usize = 0,
    position: f64 = 0,
    duration: f64 = 0,

    pub fn source(self: *const Current) []const u8 {
        return self.url[0..self.url_len];
    }
};

/// Snapshot the active player's item (under players_mutex). Torrents travel
/// as their magnet: current_url is a loopback proxy only this host can read.
pub fn snapshotCurrent(out: *Current, pause: bool) bool {
    state.players_mutex.lock();
    defer state.players_mutex.unlock();
    if (state.app.active_player_idx >= state.app.players.items.len) return false;
    const p = state.app.players.items[state.app.active_player_idx];
    const magnet = p.source_url[0..@min(p.source_url_len, p.source_url.len)];
    const src = if (std.mem.startsWith(u8, magnet, "magnet:"))
        magnet
    else
        p.current_url[0..@min(p.current_url_len, p.current_url.len)];
    if (src.len == 0 or src.len > out.url.len) return false;
    @memcpy(out.url[0..src.len], src);
    out.url_len = src.len;
    const title = if (p.np_title_len > 0)
        p.np_title[0..@min(p.np_title_len, p.np_title.len)]
    else
        p.loading_title[0..@min(p.loading_title_len, p.loading_title.len)];
    const tn = @min(title.len, out.title.len);
    @memcpy(out.title[0..tn], title[0..tn]);
    out.title_len = tn;
    const snap = p.playbackSnapshot();
    out.position = if (std.math.isFinite(snap.time_pos) and snap.time_pos > 0) snap.time_pos else 0;
    out.duration = if (std.math.isFinite(snap.duration) and snap.duration > 0) snap.duration else 0;
    if (pause) _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "pause", "yes");
    return true;
}

fn pauseActive() void {
    state.players_mutex.lock();
    defer state.players_mutex.unlock();
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    _ = c.mpv.mpv_set_property_string(state.app.players.items[state.app.active_player_idx].mpv_ctx, "pause", "yes");
}

/// Absolute filesystem path when `src` is a local file, else null.
pub fn localPathOf(src: []const u8) ?[]const u8 {
    const wh = @import("../player/watch_history_pure.zig");
    if (wh.classifyLink(src) != .local_abs) return null;
    return wh.localFsPath(src);
}

// ── Offers ────────────────────────────────────────────────────────────────

pub const OfferError = error{ NothingPlaying, LocalOnly, NoAddress, Stream, TooLong };

/// Turn an item into a payload a peer can play. `host_port` is how the peer
/// reaches THIS host (used only for a local file).
pub fn buildOffer(source: []const u8, title: []const u8, position: f64, duration: f64, host_port: ?[]const u8, out: *pure.Handoff) OfferError!void {
    out.* = .{};
    var url_buf: [pure.SOURCE_MAX]u8 = undefined;
    var src = source;
    if (localPathOf(source)) |abs| {
        const hp = host_port orelse return error.NoAddress;
        var created: session.Created = .{};
        session.create(.{ .abs_path = abs, .title = title, .force_direct = true }, &created) catch return error.Stream;
        src = std.fmt.bufPrint(&url_buf, "http://{s}/api/stream/{s}/{s}/direct", .{ hp, created.sid[0..], created.tokenText() }) catch return error.TooLong;
    } else if (pure.urlHost(source)) |host| {
        if (pure.isLoopbackHost(host)) return error.LocalOnly;
    }
    if (!pure.validSource(src)) return error.LocalOnly;
    @memcpy(out.source[0..src.len], src);
    out.source_len = src.len;
    const tn = @min(title.len, out.title.len);
    @memcpy(out.title[0..tn], title[0..tn]);
    out.title_len = tn;
    out.position = position;
    out.duration = duration;
}

pub fn hostForPeer(peer_url: []const u8, buf: []u8) ?[]const u8 {
    const remote = @import("remote.zig");
    const host = pure.advertiseHost(peer_url, remote.lanIp()) orelse return null;
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ host, remote.port }) catch null;
}

// ── Received handoffs ─────────────────────────────────────────────────────

var recv_mutex: sync.Mutex = .{};
var pending: pure.Handoff = .{}; // under recv_mutex
var pending_ready = false; // under recv_mutex
var last: pure.Handoff = .{}; // under recv_mutex
var last_at: i64 = 0; // under recv_mutex
var last_played = false; // under recv_mutex

fn stage(h: *const pure.Handoff) void {
    recv_mutex.lock();
    pending = h.*;
    pending_ready = true;
    last = h.*;
    last_at = io_g.timestamp();
    last_played = false;
    recv_mutex.unlock();
    var log_buf: [200]u8 = undefined;
    logs.pushLog("info", "handoff", std.fmt.bufPrint(&log_buf, "handoff received: {s} at {d:.0}s", .{ h.titleText(), h.position }) catch "handoff received", false);
    state.wakeUi();
}

// ── Peer client (blocking; worker / request threads only) ─────────────────

pub const PeerError = error{ BadPeer, Unreachable, BadOffer };

fn authHeader(buf: []u8, token: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "Bearer {s}", .{token}) catch null;
}

pub fn sendTo(peer_raw: []const u8, token: []const u8, offer: *const pure.Handoff) PeerError!void {
    const peer = sync_pure.normalizePeer(peer_raw) orelse return error.BadPeer;
    if (!sync_pure.validToken(token)) return error.BadPeer;
    var body: [6 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&body);
    pure.encodeHandoff(&w, offer.sourceText(), offer.titleText(), offer.position, offer.duration) catch return error.BadOffer;
    var url_buf: [480]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/handoff", .{peer}) catch return error.BadPeer;
    var auth_buf: [220]u8 = undefined;
    const auth = authHeader(&auth_buf, token) orelse return error.BadPeer;
    var resp: [1024]u8 = undefined;
    _ = reliable_fetch.fetch(url, &resp, .{
        .secret_headers = &.{.{ .name = "Authorization", .value = auth }},
        // The body can carry a signed stream token: stdin, never argv.
        .secret_post_body = body[0..w.end],
        .headers = &.{.{ .name = "Accept", .value = "application/json" }},
        .impersonate = false,
        .use_dpi_proxy = false,
        .follow_redirects = false,
        .timeout_secs = 10,
    }) orelse return error.Unreachable;
}

/// GET the peer's offer (pausing it) and decode it into `out`.
pub fn fetchOffer(peer_raw: []const u8, token: []const u8, out: *pure.Handoff) PeerError!void {
    const peer = sync_pure.normalizePeer(peer_raw) orelse return error.BadPeer;
    if (!sync_pure.validToken(token)) return error.BadPeer;
    var url_buf: [480]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/handoff/offer?pause=1", .{peer}) catch return error.BadPeer;
    var auth_buf: [220]u8 = undefined;
    const auth = authHeader(&auth_buf, token) orelse return error.BadPeer;
    var resp: [8 * 1024]u8 = undefined;
    const json = reliable_fetch.fetch(url, &resp, .{
        .secret_headers = &.{.{ .name = "Authorization", .value = auth }},
        .headers = &.{.{ .name = "Accept", .value = "application/json" }},
        .impersonate = false,
        .use_dpi_proxy = false,
        .follow_redirects = false,
        .timeout_secs = 10,
    }) orelse return error.Unreachable;
    const payload = payloadField(json) orelse return error.BadOffer;
    pure.decodeHandoff(payload, out) catch return error.BadOffer;
}

/// The `"payload":"..."` string of an offer. The payload is form-encoded
/// (unreserved bytes, '%', '&', '='), so it never contains '"' or '\\'.
fn payloadField(json: []const u8) ?[]const u8 {
    const key = "\"payload\":\"";
    const i = std.mem.indexOf(u8, json, key) orelse return null;
    const rest = json[i + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

// ── HTTP ──────────────────────────────────────────────────────────────────

fn headerValue(request: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn sendOfferError(stream: std.Io.net.Stream, e: OfferError) void {
    switch (e) {
        error.NothingPlaying => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"nothing is playing\"}"),
        error.LocalOnly => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"this source only plays on this machine\"}"),
        error.NoAddress => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"no LAN address to stream this file from\"}"),
        error.Stream => wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"could not open a stream for this file\"}"),
        error.TooLong => wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"source too long\"}"),
    }
}

fn sendPeerError(stream: std.Io.net.Stream, e: PeerError) void {
    switch (e) {
        error.BadPeer => wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"peer must be an http(s) URL with a token\"}"),
        error.Unreachable => wire.sendJsonStatus(stream, "502 Bad Gateway", "{\"error\":\"the other device refused or is unreachable\"}"),
        error.BadOffer => wire.sendJsonStatus(stream, "502 Bad Gateway", "{\"error\":\"the other device has nothing to hand off\"}"),
    }
}

pub fn handleApi(stream: std.Io.net.Stream, method: []const u8, api_path: []const u8, query: []const u8, body: []const u8, request: []const u8) bool {
    if (std.mem.eql(u8, api_path, "/handoff")) {
        if (std.mem.eql(u8, method, "GET")) {
            lastRoute(stream);
        } else if (wire.requireMethod(stream, method, "POST")) {
            var h: pure.Handoff = .{};
            pure.decodeHandoff(body, &h) catch |e| {
                wire.sendJsonStatus(stream, "400 Bad Request", switch (e) {
                    error.MissingSource, error.BadSource => "{\"error\":\"source must be an http(s) URL or a magnet\"}",
                    error.BadTitle => "{\"error\":\"invalid title\"}",
                    error.BadPosition => "{\"error\":\"invalid position\"}",
                });
                return true;
            };
            stage(&h);
            wire.sendJson(stream, "{\"ok\":true,\"queued\":true}");
        }
        return true;
    }
    if (std.mem.eql(u8, api_path, "/handoff/offer")) {
        if (!wire.requireMethod(stream, method, "GET")) return true;
        var cur: Current = .{};
        if (!snapshotCurrent(&cur, std.mem.eql(u8, wire.queryParam(query, "pause") orelse "", "1"))) {
            sendOfferError(stream, error.NothingPlaying);
            return true;
        }
        const host = if (headerValue(request, "host")) |h| pure.safeHostHeader(h) else null;
        var offer: pure.Handoff = .{};
        buildOffer(cur.source(), cur.title[0..cur.title_len], cur.position, cur.duration, host, &offer) catch |e| {
            sendOfferError(stream, e);
            return true;
        };
        writeOffer(stream, &offer);
        return true;
    }
    if (std.mem.eql(u8, api_path, "/handoff/send") or std.mem.eql(u8, api_path, "/handoff/bring")) {
        if (!wire.requireMethod(stream, method, "POST")) return true;
        var peer_buf: [400]u8 = undefined;
        var tok_buf: [220]u8 = undefined;
        const peer = wire.formParam(body, query, "peer", &peer_buf) orelse "";
        const token = wire.formParam(body, query, "token", &tok_buf) orelse "";
        if (std.mem.eql(u8, api_path, "/handoff/bring")) {
            var h: pure.Handoff = .{};
            fetchOffer(peer, token, &h) catch |e| {
                sendPeerError(stream, e);
                return true;
            };
            stage(&h);
            writeOffer(stream, &h);
            return true;
        }
        var offer: pure.Handoff = .{};
        var host_buf: [80]u8 = undefined;
        const host = hostForPeer(peer, &host_buf);
        var dec: [64]u8 = undefined;
        if (wire.formParam(body, query, "id", &dec)) |id_text| {
            var path_buf: [2048]u8 = undefined;
            var title_buf: [pure.TITLE_MAX]u8 = undefined;
            const id = std.fmt.parseInt(i64, id_text, 10) catch 0;
            const item = @import("local_library.zig").pathById(id, &path_buf, &title_buf) orelse {
                wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"media not found\"}");
                return true;
            };
            const pos = std.fmt.parseFloat(f64, wire.formParam(body, query, "pos", &dec) orelse "0") catch 0;
            buildOffer(item.path, item.title, if (std.math.isFinite(pos) and pos > 0) pos else 0, 0, host, &offer) catch |e| {
                sendOfferError(stream, e);
                return true;
            };
        } else {
            var cur: Current = .{};
            if (!snapshotCurrent(&cur, false)) {
                sendOfferError(stream, error.NothingPlaying);
                return true;
            }
            buildOffer(cur.source(), cur.title[0..cur.title_len], cur.position, cur.duration, host, &offer) catch |e| {
                sendOfferError(stream, e);
                return true;
            };
        }
        sendTo(peer, token, &offer) catch |e| {
            sendPeerError(stream, e);
            return true;
        };
        pauseActive();
        writeOffer(stream, &offer);
        return true;
    }
    return false;
}

fn writeOffer(stream: std.Io.net.Stream, offer: *const pure.Handoff) void {
    var json: [7 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&json);
    w.writeAll("{\"ok\":true,\"title\":\"") catch return;
    wire.writeJsonString(&w, offer.titleText());
    w.print("\",\"pos\":{d:.3},\"payload\":\"", .{offer.position}) catch return;
    pure.encodeHandoff(&w, offer.sourceText(), offer.titleText(), offer.position, offer.duration) catch return;
    w.writeAll("\"}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}

fn lastRoute(stream: std.Io.net.Stream) void {
    var json: [4 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&json);
    recv_mutex.lock();
    const snap = last;
    const at = last_at;
    const played = last_played;
    recv_mutex.unlock();
    if (at == 0) return wire.sendJson(stream, "{\"last\":null}");
    w.writeAll("{\"last\":{\"title\":\"") catch return;
    wire.writeJsonString(&w, snap.titleText());
    w.writeAll("\",\"source\":\"") catch return;
    wire.writeJsonString(&w, snap.sourceText());
    w.print("\",\"pos\":{d:.3},\"dur\":{d:.3},\"at\":{d},\"played\":{s}}}}}", .{ snap.position, snap.duration, at, if (played) "true" else "false" }) catch return;
    wire.sendJson(stream, json[0..w.end]);
}

// ── Native actions ("Continue on…" / "Bring here") ────────────────────────

const Job = struct {
    var busy: std.atomic.Value(bool) = .init(false);
    var bring: bool = false;
    var peer_url: [256]u8 = undefined;
    var peer_url_len: usize = 0;
    var token: [256]u8 = undefined;
    var token_len: usize = 0;
    var msg_mutex: sync.Mutex = .{};
    var msg: [160]u8 = undefined;
    var msg_len: usize = 0;

    fn say(text: []const u8) void {
        msg_mutex.lock();
        defer msg_mutex.unlock();
        const n = @min(text.len, msg.len);
        @memcpy(msg[0..n], text[0..n]);
        msg_len = n;
        state.wakeUi();
    }

    fn run() void {
        const S = @This();
        defer S.busy.store(false, .release);
        const peer = S.peer_url[0..S.peer_url_len];
        const token_text = S.token[0..S.token_len];
        if (S.bring) {
            var h: pure.Handoff = .{};
            fetchOffer(peer, token_text, &h) catch |e| return S.say(switch (e) {
                error.BadPeer => "Check that device's address and token",
                error.Unreachable => "That device is unreachable",
                error.BadOffer => "Nothing is playing on that device",
            });
            stage(&h);
            return;
        }
        var cur: Current = .{};
        if (!snapshotCurrent(&cur, false)) return S.say("Nothing is playing");
        var host_buf: [80]u8 = undefined;
        var offer: pure.Handoff = .{};
        buildOffer(cur.source(), cur.title[0..cur.title_len], cur.position, cur.duration, hostForPeer(peer, &host_buf), &offer) catch |e| return S.say(switch (e) {
            error.NothingPlaying => "Nothing is playing",
            error.LocalOnly => "This source only plays on this machine",
            error.NoAddress => "No LAN address to stream this file from",
            error.Stream, error.TooLong => "Could not open a stream for this file",
        });
        sendTo(peer, token_text, &offer) catch |e| return S.say(switch (e) {
            error.BadPeer => "Check that device's address and token",
            error.Unreachable => "That device refused or is unreachable",
            error.BadOffer => "Could not hand this item off",
        });
        pauseActive();
        S.say("Continuing on the other device");
    }
};

pub fn busy() bool {
    return Job.busy.load(.acquire);
}

/// UI thread: start a handoff to (bring=false) or from (bring=true) sync peer `i`.
pub fn startPeerJob(i: usize, bring: bool) bool {
    const ls = &state.app.lsync;
    if (i >= ls.peer_count) return false;
    if (Job.busy.swap(true, .acq_rel)) return false;
    const p = &ls.peers[i];
    const url = p.urlText();
    const tok = p.tokenText();
    if (url.len > Job.peer_url.len or tok.len > Job.token.len) {
        Job.busy.store(false, .release);
        return false;
    }
    Job.bring = bring;
    @memcpy(Job.peer_url[0..url.len], url);
    Job.peer_url_len = url.len;
    @memcpy(Job.token[0..tok.len], tok);
    Job.token_len = tok.len;
    const thread = workers.spawnLegacy(Job.run, .{}) catch {
        Job.busy.store(false, .release);
        return false;
    };
    workers.release(thread);
    return true;
}

// ── UI-thread tick ────────────────────────────────────────────────────────

/// UI thread / headless loop: play a received handoff, surface job results,
/// and run the stream-session janitor.
pub fn tick() void {
    session.tick();

    var msg_buf: [160]u8 = undefined;
    Job.msg_mutex.lock();
    const n = Job.msg_len;
    @memcpy(msg_buf[0..n], Job.msg[0..n]);
    Job.msg_len = 0;
    Job.msg_mutex.unlock();
    if (n > 0) state.showToast(msg_buf[0..n]);

    recv_mutex.lock();
    if (!pending_ready) {
        recv_mutex.unlock();
        return;
    }
    const h = pending;
    pending_ready = false;
    last_played = true;
    recv_mutex.unlock();

    const src = h.sourceText();
    const browser = @import("browser.zig");
    if (std.mem.startsWith(u8, src, "magnet:")) {
        browser.loadContent(src);
    } else {
        browser.playDirect(.{ .url = src, .title = h.titleText(), .resume_position_secs = if (h.position > 0) h.position else null });
    }
    var toast_buf: [200]u8 = undefined;
    state.showToast(std.fmt.bufPrint(&toast_buf, "Continuing {s}", .{if (h.title_len > 0) h.titleText() else "playback"}) catch "Continuing playback");
}
