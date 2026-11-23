//! Socket side of native casting: Cast v2 over TLS, mDNS and SSDP discovery,
//! and UPnP AVTransport SOAP over HTTP. Every byte on the wire is built and
//! parsed by cast_v2_pure.zig / dlna_pure.zig; this file only moves it.
//!
//! Every network operation runs under a deadline (an Io.Select racing the
//! work against a sleep), so an unresponsive device can never pin the calling
//! worker or HTTP connection thread.
//!
//! Callers choose the discovery destination: the app passes the multicast
//! groups, the cast-probe test tool passes a loopback fake. Nothing here
//! picks a network target on its own.

const std = @import("std");
const io_g = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const cv2 = @import("cast_v2_pure.zig");
const dlna = @import("dlna_pure.zig");

pub const PlayerState = cv2.PlayerState;

pub const Result = struct {
    ok: bool = false,
    state: PlayerState = .unknown,
    /// Seconds; negative when the answer carried no position.
    position: f64 = -1,
    duration: f64 = 0,
    /// Static user-facing reason when !ok.
    err: []const u8 = "",
};

fn failed(msg: []const u8) Result {
    return .{ .err = msg };
}

// ── Deadline ───────────────────────────────────────────────────────────────

fn sleepMs(ms: i64) std.Io.Cancelable!void {
    return std.Io.Timeout.sleep(.{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(ms) } }, io_g.io());
}

/// `func(args)` or null when it did not finish within `ms` (the work is
/// cancelled: blocked socket calls return error.Canceled and unwind).
fn bounded(comptime T: type, comptime func: anytype, args: anytype, ms: i64) ?T {
    const Ev = union(enum) {
        done: T,
        deadline: std.Io.Cancelable!void,
    };
    var events: [2]Ev = undefined;
    var sel = std.Io.Select(Ev).init(io_g.io(), &events);
    defer sel.cancelDiscard();
    sel.concurrent(.done, func, args) catch return null;
    sel.concurrent(.deadline, sleepMs, .{ms}) catch return null;
    return switch (sel.await() catch return null) {
        .done => |v| v,
        .deadline => null,
    };
}

pub fn ip4Text(addr: std.Io.net.IpAddress, buf: []u8) []const u8 {
    return switch (addr) {
        .ip4 => |a| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch "",
        .ip6 => "",
    };
}

/// The local address the OS would use to reach `remote_ip` (a connected UDP
/// socket sends nothing). This is the address a receiver can fetch media from.
pub fn localAddressFor(remote_ip: []const u8, buf: []u8) []const u8 {
    const addr = std.Io.net.IpAddress.parse(remote_ip, 9) catch return "";
    const s = addr.connect(io_g.io(), .{ .mode = .dgram }) catch return "";
    defer s.close(io_g.io());
    return ip4Text(s.socket.address, buf);
}

// ── Chromecast (Cast v2) ──────────────────────────────────────────────────

const tls_len = std.crypto.tls.Client.min_buffer_len;

const CastBufs = struct {
    sock_read: [tls_len]u8,
    sock_write: [tls_len]u8,
    tls_read: [tls_len]u8,
    tls_write: [tls_len]u8,
    frame_out: [cv2.payload_cap + 512]u8,
    frame_in: [cv2.max_frame]u8,
    out: cv2.Outbox,
};

fn sendAll(w: *std.Io.Writer, sw: *std.Io.Writer, bufs: *CastBufs) bool {
    for (bufs.out.slice()) |*o| {
        const frame = cv2.encodeFrame(&bufs.frame_out, o.message()) orelse return false;
        w.writeAll(frame) catch return false;
    }
    w.flush() catch return false;
    sw.flush() catch return false;
    return true;
}

fn chromecastInner(ip: []const u8, port: u16, goal: cv2.Goal) Result {
    const io = io_g.io();
    const addr = std.Io.net.IpAddress.parse(ip, port) catch return failed("Bad Chromecast address");
    const stream = addr.connect(io, .{ .mode = .stream }) catch return failed("Could not connect to the Chromecast");
    defer stream.close(io);

    const bufs = alloc.create(CastBufs) catch return failed("Out of memory");
    defer alloc.destroy(bufs);
    var sr = stream.reader(io, &bufs.sock_read);
    var sw = stream.writer(io, &bufs.sock_write);
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    // Cast receivers present a device certificate no public CA signs; the
    // protocol's own device authentication is optional and not used here.
    var tls = std.crypto.tls.Client.init(&sr.interface, &sw.interface, .{
        .host = .no_verification,
        .ca = .no_verification,
        .read_buffer = &bufs.tls_read,
        .write_buffer = &bufs.tls_write,
        .entropy = &entropy,
        .realtime_now = std.Io.Clock.real.now(io),
        .allow_truncation_attacks = true,
    }) catch return failed("TLS handshake with the Chromecast failed");

    var s = cv2.Session{ .goal = goal };
    s.begin(&bufs.out);
    if (!sendAll(&tls.writer, &sw.interface, bufs)) return failed("Could not talk to the Chromecast");
    var frames: usize = 0;
    while (!s.finished()) : (frames += 1) {
        if (frames > 200) return failed("The Chromecast never answered the request");
        var hdr: [4]u8 = undefined;
        tls.reader.readSliceAll(&hdr) catch return failed("The Chromecast closed the connection");
        const len = cv2.frameLen(hdr) orelse return failed("Bad frame from the Chromecast");
        tls.reader.readSliceAll(bufs.frame_in[0..len]) catch return failed("The Chromecast closed the connection");
        const m = cv2.decodeMessage(bufs.frame_in[0..len]) orelse return failed("Bad frame from the Chromecast");
        const in = cv2.parseInbound(alloc, m.payload);
        s.onMessage(m, &in, &bufs.out);
        if (bufs.out.len > 0 and !sendAll(&tls.writer, &sw.interface, bufs)) return failed("Could not talk to the Chromecast");
    }
    // Leave the receiver connection tidily; the app keeps playing.
    bufs.out.len = 0;
    var close_frame: [128]u8 = undefined;
    if (cv2.encodeFrame(&close_frame, .{ .source = cv2.sender_id, .dest = cv2.receiver_id, .namespace = cv2.ns_connection, .payload = cv2.payload_close })) |f| {
        tls.writer.writeAll(f) catch {};
        tls.writer.flush() catch {};
        sw.interface.flush() catch {};
    }
    if (s.phase == .failed) return .{ .err = cv2.failureMessage(s.failure), .state = s.player_state };
    return .{ .ok = true, .state = s.player_state, .position = s.current_time, .duration = s.duration };
}

pub fn chromecast(ip: []const u8, port: u16, goal: cv2.Goal, timeout_ms: i64) Result {
    return bounded(Result, chromecastInner, .{ ip, port, goal }, timeout_ms) orelse failed("The Chromecast did not answer in time");
}

// ── Discovery ─────────────────────────────────────────────────────────────

fn mdnsInner(dest: std.Io.net.IpAddress, wait_ms: i64, out: []cv2.Found) usize {
    const io = io_g.io();
    const any = std.Io.net.IpAddress.parse("0.0.0.0", 0) catch return 0;
    const sock = any.bind(io, .{ .mode = .dgram }) catch return 0;
    defer sock.close(io);
    var qbuf: [64]u8 = undefined;
    const query = cv2.buildMdnsQuery(&qbuf, cv2.mdns_service) orelse return 0;
    sock.send(io, &dest, query) catch return 0;
    var n: usize = 0;
    var pkt: [9000]u8 = undefined;
    const start = io_g.monotonicMilliTimestamp();
    var resent = false;
    while (true) {
        const left = wait_ms - (io_g.monotonicMilliTimestamp() - start);
        if (left <= 0) break;
        if (!resent and left < @divTrunc(wait_ms, 2)) {
            resent = true; // one retransmit: multicast is lossy on Wi-Fi
            sock.send(io, &dest, query) catch {};
        }
        const msg = sock.receiveTimeout(io, &pkt, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(@min(left, 250)) } }) catch |e| switch (e) {
            error.Timeout => continue,
            else => break,
        };
        var ip_buf: [46]u8 = undefined;
        n = cv2.parseMdnsResponse(msg.data, ip4Text(msg.from, &ip_buf), out, n);
        if (n >= out.len) break;
    }
    return n;
}

/// Chromecasts answering a `_googlecast._tcp.local` PTR query sent to `dest`.
pub fn discoverChromecasts(dest: std.Io.net.IpAddress, wait_ms: i64, out: []cv2.Found) usize {
    return bounded(usize, mdnsInner, .{ dest, wait_ms, out }, wait_ms + 1500) orelse 0;
}

const max_locations = 16;

fn ssdpInner(dest: std.Io.net.IpAddress, wait_ms: i64, locs: *[max_locations][512]u8, lens: *[max_locations]usize) usize {
    const io = io_g.io();
    const any = std.Io.net.IpAddress.parse("0.0.0.0", 0) catch return 0;
    const sock = any.bind(io, .{ .mode = .dgram }) catch return 0;
    defer sock.close(io);
    var host_buf: [46]u8 = undefined;
    var req: [512]u8 = undefined;
    const msearch = dlna.buildMsearch(&req, ip4Text(dest, &host_buf), dest.getPort(), dlna.av_transport, 2) orelse return 0;
    sock.send(io, &dest, msearch) catch return 0;
    var n: usize = 0;
    var pkt: [4096]u8 = undefined;
    const start = io_g.monotonicMilliTimestamp();
    var resent = false;
    while (n < max_locations) {
        const left = wait_ms - (io_g.monotonicMilliTimestamp() - start);
        if (left <= 0) break;
        if (!resent and left < @divTrunc(wait_ms, 2)) {
            resent = true;
            sock.send(io, &dest, msearch) catch {};
        }
        const msg = sock.receiveTimeout(io, &pkt, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(@min(left, 250)) } }) catch |e| switch (e) {
            error.Timeout => continue,
            else => break,
        };
        const hit = dlna.parseSsdpResponse(msg.data) orelse continue;
        if (hit.location.len > 512) continue;
        var dup = false;
        for (0..n) |i| {
            if (std.mem.eql(u8, locs[i][0..lens[i]], hit.location)) dup = true;
        }
        if (dup) continue;
        @memcpy(locs[n][0..hit.location.len], hit.location);
        lens[n] = hit.location.len;
        n += 1;
    }
    return n;
}

/// DLNA media renderers with an AVTransport service answering an M-SEARCH
/// sent to `dest`. Each LOCATION's description is fetched and parsed.
pub fn discoverRenderers(dest: std.Io.net.IpAddress, wait_ms: i64, out: []dlna.Renderer) usize {
    var locs: [max_locations][512]u8 = undefined;
    var lens: [max_locations]usize = undefined;
    const nloc = bounded(usize, ssdpInner, .{ dest, wait_ms, &locs, &lens }, wait_ms + 1500) orelse 0;
    var n: usize = 0;
    const buf = alloc.alloc(u8, http_cap) catch return 0;
    defer alloc.free(buf);
    for (0..nloc) |i| {
        if (n >= out.len) break;
        const loc = locs[i][0..lens[i]];
        const resp = http(loc, "GET", "", "", buf, 4000) orelse continue;
        if (resp.status != 200) continue;
        const r = dlna.parseDescription(resp.body, loc) orelse continue;
        var dup = false;
        for (out[0..n]) |*e| {
            if (std.mem.eql(u8, e.controlSlice(), r.controlSlice())) dup = true;
        }
        if (dup) continue;
        out[n] = r;
        n += 1;
    }
    return n;
}

// ── HTTP (renderer control) ───────────────────────────────────────────────

pub const http_cap = 256 * 1024;

fn httpInner(url: []const u8, method: []const u8, headers: []const u8, body: []const u8, buf: []u8) ?dlna.Response {
    const io = io_g.io();
    const u = dlna.parseHttpUrl(url) orelse return null;
    const addr = std.Io.net.IpAddress.parse(u.host, u.port) catch return null;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return null;
    defer stream.close(io);
    // Request built in the second half of `buf`; the response lands in the first.
    const half = buf.len / 2;
    const req = dlna.buildRequest(buf[half..], method, u, headers, body) orelse return null;
    io_g.streamWriteAll(stream, req) catch return null;
    var got: usize = 0;
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    while (got < half) {
        var vec: [1][]u8 = .{buf[got..half]};
        const n = r.interface.readVec(&vec) catch break;
        if (n == 0) break;
        got += n;
    }
    // De-chunking needs scratch: reuse the (already sent) request half.
    return dlna.parseResponse(buf[0..got], buf[half..]);
}

/// One HTTP exchange with `Connection: close`; the response body borrows `buf`.
pub fn http(url: []const u8, method: []const u8, headers: []const u8, body: []const u8, buf: []u8, timeout_ms: i64) ?dlna.Response {
    return bounded(?dlna.Response, httpInner, .{ url, method, headers, body, buf }, timeout_ms) orelse null;
}

const SoapReply = struct {
    ok: bool,
    body: []const u8 = "",
    err: []const u8 = "",
};

fn soap(control: []const u8, action: []const u8, args: []const dlna.Arg, buf: []u8) SoapReply {
    var env_buf: [12 * 1024]u8 = undefined;
    const env = dlna.soapEnvelope(&env_buf, action, args) orelse return .{ .ok = false, .err = "Media URL too long to cast" };
    var sa_buf: [128]u8 = undefined;
    var hdr_buf: [256]u8 = undefined;
    const headers = std.fmt.bufPrint(&hdr_buf, "Content-Type: text/xml; charset=\"utf-8\"\r\nSOAPACTION: {s}\r\n", .{dlna.soapActionHeader(&sa_buf, action) orelse ""}) catch return .{ .ok = false };
    const resp = http(control, "POST", headers, env, buf, 6000) orelse return .{ .ok = false, .err = "The DLNA renderer did not answer" };
    if (resp.status != 200 or dlna.soapFault(resp.body) != null) return .{ .ok = false, .body = resp.body, .err = "The DLNA renderer refused the command" };
    return .{ .ok = true, .body = resp.body };
}

pub const DlnaGoal = union(enum) {
    load: struct { url: []const u8, title: []const u8, mime: []const u8, start_secs: f64 },
    play,
    pause,
    stop,
    seek: f64,
    status,
};

fn mapState(t: dlna.TransportState) PlayerState {
    return switch (t) {
        .playing => .playing,
        .paused => .paused,
        .transitioning => .buffering,
        .stopped, .no_media => .idle,
        .unknown => .unknown,
    };
}

/// Run one AVTransport goal against the renderer at `control`.
pub fn dlnaRun(control: []const u8, goal: DlnaGoal) Result {
    const buf = alloc.alloc(u8, 64 * 1024) catch return failed("Out of memory");
    defer alloc.free(buf);
    const inst: dlna.Arg = .{ .name = "InstanceID", .value = "0" };
    var t_buf: [16]u8 = undefined;
    switch (goal) {
        .load => |l| {
            var meta_buf: [6144]u8 = undefined;
            const meta = dlna.didlLite(&meta_buf, l.title, l.url, l.mime) orelse return failed("Media URL too long to cast");
            for (dlna.loadPlan(l.start_secs)) |step| {
                const r = switch (step) {
                    .set_uri => soap(control, "SetAVTransportURI", &.{ inst, .{ .name = "CurrentURI", .value = l.url }, .{ .name = "CurrentURIMetaData", .value = meta } }, buf),
                    .play => soap(control, "Play", &.{ inst, .{ .name = "Speed", .value = "1" } }, buf),
                    .seek => soap(control, "Seek", &.{ inst, .{ .name = "Unit", .value = "REL_TIME" }, .{ .name = "Target", .value = dlna.formatHms(l.start_secs, &t_buf) } }, buf),
                };
                // A renderer that cannot seek yet still plays from the start.
                if (!r.ok and step != .seek) return failed(r.err);
            }
            return .{ .ok = true, .state = .playing, .position = l.start_secs };
        },
        .play => {
            const r = soap(control, "Play", &.{ inst, .{ .name = "Speed", .value = "1" } }, buf);
            return if (r.ok) .{ .ok = true, .state = .playing } else failed(r.err);
        },
        .pause => {
            const r = soap(control, "Pause", &.{inst}, buf);
            return if (r.ok) .{ .ok = true, .state = .paused } else failed(r.err);
        },
        .stop => {
            const r = soap(control, "Stop", &.{inst}, buf);
            return if (r.ok) .{ .ok = true, .state = .idle } else failed(r.err);
        },
        .seek => |secs| {
            const r = soap(control, "Seek", &.{ inst, .{ .name = "Unit", .value = "REL_TIME" }, .{ .name = "Target", .value = dlna.formatHms(secs, &t_buf) } }, buf);
            return if (r.ok) .{ .ok = true, .state = .unknown, .position = secs } else failed(r.err);
        },
        .status => {
            const ti = soap(control, "GetTransportInfo", &.{inst}, buf);
            if (!ti.ok) return failed(ti.err);
            var res = Result{ .ok = true, .state = mapState(dlna.TransportState.parse(dlna.element(ti.body, "CurrentTransportState") orelse "")) };
            const pi = soap(control, "GetPositionInfo", &.{inst}, buf);
            if (pi.ok) {
                res.position = dlna.parseHms(dlna.element(pi.body, "RelTime") orelse "") orelse 0;
                res.duration = dlna.parseHms(dlna.element(pi.body, "TrackDuration") orelse "") orelse 0;
            }
            return res;
        },
    }
}
