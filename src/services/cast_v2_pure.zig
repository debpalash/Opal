//! Pure Chromecast (Cast v2) protocol: CastMessage protobuf framing, the JSON
//! payloads of the connection / heartbeat / receiver / media namespaces, the
//! sender state machine, and mDNS discovery packets. cast_net.zig does the
//! socket and TLS work and routes every byte through these functions, so the
//! tested logic is the shipped logic.
//!
//! Wire format (from the open-source Cast v2 sender libraries, e.g.
//! pychromecast / node-castv2):
//!   TLS to <device>:8009, self-signed certificate (not verifiable).
//!   Each frame: u32 big-endian length, then a protobuf CastMessage:
//!     1 protocol_version (varint, 0 = CASTV2_1_0)
//!     2 source_id        (string, "sender-0")
//!     3 destination_id   (string, "receiver-0" or an app transportId)
//!     4 namespace        (string)
//!     5 payload_type     (varint, 0 = STRING)
//!     6 payload_utf8     (string, JSON)
//!     7 payload_binary   (bytes, unused here)
//!
//! Load flow: CONNECT receiver-0, GET_STATUS; LAUNCH the Default Media
//! Receiver (CC1AD845) unless it already runs; CONNECT its transportId; LOAD.
//! Control flow: CONNECT, GET_STATUS, CONNECT the running app, media
//! GET_STATUS for the mediaSessionId, then PLAY / PAUSE / SEEK / STOP.

const std = @import("std");

pub const ns_connection = "urn:x-cast:com.google.cast.tp.connection";
pub const ns_heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat";
pub const ns_receiver = "urn:x-cast:com.google.cast.receiver";
pub const ns_media = "urn:x-cast:com.google.cast.media";
pub const default_media_receiver = "CC1AD845";
pub const sender_id = "sender-0";
pub const receiver_id = "receiver-0";
pub const default_port: u16 = 8009;
/// Receivers never send frames near this; anything larger is a broken stream.
pub const max_frame: usize = 64 * 1024;

// ── Protobuf CastMessage ───────────────────────────────────────────────────

pub const Message = struct {
    source: []const u8 = "",
    dest: []const u8 = "",
    namespace: []const u8 = "",
    payload: []const u8 = "",
};

fn putVarint(out: []u8, pos: *usize, value: u64) bool {
    var v = value;
    while (true) {
        if (pos.* >= out.len) return false;
        const byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        out[pos.*] = if (v != 0) byte | 0x80 else byte;
        pos.* += 1;
        if (v == 0) return true;
    }
}

fn putField(out: []u8, pos: *usize, field: u8, bytes: []const u8) bool {
    if (!putVarint(out, pos, (@as(u64, field) << 3) | 2)) return false;
    if (!putVarint(out, pos, bytes.len)) return false;
    if (pos.* + bytes.len > out.len) return false;
    @memcpy(out[pos.* .. pos.* + bytes.len], bytes);
    pos.* += bytes.len;
    return true;
}

/// Length-prefixed CastMessage frame in `out`, or null when it does not fit.
pub fn encodeFrame(out: []u8, m: Message) ?[]const u8 {
    if (out.len < 4) return null;
    var pos: usize = 4;
    if (!putVarint(out, &pos, (1 << 3) | 0) or !putVarint(out, &pos, 0)) return null;
    if (!putField(out, &pos, 2, m.source)) return null;
    if (!putField(out, &pos, 3, m.dest)) return null;
    if (!putField(out, &pos, 4, m.namespace)) return null;
    if (!putVarint(out, &pos, (5 << 3) | 0) or !putVarint(out, &pos, 0)) return null;
    if (!putField(out, &pos, 6, m.payload)) return null;
    std.mem.writeInt(u32, out[0..4], @intCast(pos - 4), .big);
    return out[0..pos];
}

/// Body length announced by a frame header; null when over `max_frame`.
pub fn frameLen(header: [4]u8) ?usize {
    const n = std.mem.readInt(u32, &header, .big);
    if (n == 0 or n > max_frame) return null;
    return n;
}

fn getVarint(body: []const u8, pos: *usize) ?u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (pos.* < body.len) {
        const b = body[pos.*];
        pos.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        if (shift >= 63) return null;
        shift += 7;
    }
    return null;
}

/// Decode a CastMessage body (without the length prefix). Slices borrow `body`.
/// Unknown fields are skipped; truncated or malformed input returns null.
pub fn decodeMessage(body: []const u8) ?Message {
    var m = Message{};
    var pos: usize = 0;
    while (pos < body.len) {
        const key = getVarint(body, &pos) orelse return null;
        const field = key >> 3;
        switch (key & 7) {
            0 => _ = getVarint(body, &pos) orelse return null,
            1 => {
                if (pos + 8 > body.len) return null;
                pos += 8;
            },
            5 => {
                if (pos + 4 > body.len) return null;
                pos += 4;
            },
            2 => {
                const len = getVarint(body, &pos) orelse return null;
                if (len > body.len - pos) return null;
                const bytes = body[pos .. pos + @as(usize, @intCast(len))];
                pos += @intCast(len);
                switch (field) {
                    2 => m.source = bytes,
                    3 => m.dest = bytes,
                    4 => m.namespace = bytes,
                    6 => m.payload = bytes,
                    else => {},
                }
            },
            else => return null,
        }
    }
    return m;
}

// ── JSON payloads ──────────────────────────────────────────────────────────

pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

pub const payload_connect = "{\"type\":\"CONNECT\"}";
pub const payload_close = "{\"type\":\"CLOSE\"}";
pub const payload_ping = "{\"type\":\"PING\"}";
pub const payload_pong = "{\"type\":\"PONG\"}";

pub const StreamType = enum { buffered, live };

pub const LoadArgs = struct {
    url: []const u8,
    content_type: []const u8 = "video/mp4",
    title: []const u8 = "",
    start_secs: f64 = 0,
    stream_type: StreamType = .buffered,
    /// fMP4 HLS needs hlsVideoSegmentFormat or the receiver assumes MPEG-TS.
    hls_fmp4: bool = false,
};

pub fn receiverGetStatus(buf: []u8, req: u32) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{{\"type\":\"GET_STATUS\",\"requestId\":{d}}}", .{req}) catch null;
}

pub fn launch(buf: []u8, req: u32, app_id: []const u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{{\"type\":\"LAUNCH\",\"requestId\":{d},\"appId\":", .{req}) catch return null;
    writeJsonString(&w, app_id) catch return null;
    w.writeAll("}") catch return null;
    return w.buffered();
}

fn finite(x: f64) f64 {
    return if (std.math.isFinite(x) and x > 0) x else 0;
}

pub fn load(buf: []u8, req: u32, a: LoadArgs) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{{\"type\":\"LOAD\",\"requestId\":{d},\"autoplay\":true,\"currentTime\":{d:.3},\"media\":{{\"contentId\":", .{ req, finite(a.start_secs) }) catch return null;
    writeJsonString(&w, a.url) catch return null;
    w.writeAll(",\"contentUrl\":") catch return null;
    writeJsonString(&w, a.url) catch return null;
    w.writeAll(",\"contentType\":") catch return null;
    writeJsonString(&w, a.content_type) catch return null;
    w.print(",\"streamType\":\"{s}\"", .{if (a.stream_type == .live) "LIVE" else "BUFFERED"}) catch return null;
    if (a.hls_fmp4) w.writeAll(",\"hlsSegmentFormat\":\"fmp4\",\"hlsVideoSegmentFormat\":\"fmp4\"") catch return null;
    w.writeAll(",\"metadata\":{\"metadataType\":0,\"title\":") catch return null;
    writeJsonString(&w, a.title) catch return null;
    w.writeAll("}}}") catch return null;
    return w.buffered();
}

pub const MediaCommand = enum { play, pause, stop, get_status };

pub fn mediaCommand(buf: []u8, req: u32, cmd: MediaCommand, media_session_id: ?i64) ?[]const u8 {
    const t = switch (cmd) {
        .play => "PLAY",
        .pause => "PAUSE",
        .stop => "STOP",
        .get_status => "GET_STATUS",
    };
    if (media_session_id) |id|
        return std.fmt.bufPrint(buf, "{{\"type\":\"{s}\",\"requestId\":{d},\"mediaSessionId\":{d}}}", .{ t, req, id }) catch null;
    return std.fmt.bufPrint(buf, "{{\"type\":\"{s}\",\"requestId\":{d}}}", .{ t, req }) catch null;
}

pub fn seek(buf: []u8, req: u32, media_session_id: i64, secs: f64) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{{\"type\":\"SEEK\",\"requestId\":{d},\"mediaSessionId\":{d},\"currentTime\":{d:.3},\"resumeState\":\"PLAYBACK_START\"}}", .{ req, media_session_id, finite(secs) }) catch null;
}

// ── Inbound parsing ────────────────────────────────────────────────────────

pub const PlayerState = enum {
    unknown,
    idle,
    buffering,
    playing,
    paused,

    pub fn fromCast(s: []const u8) PlayerState {
        if (std.mem.eql(u8, s, "PLAYING")) return .playing;
        if (std.mem.eql(u8, s, "PAUSED")) return .paused;
        if (std.mem.eql(u8, s, "BUFFERING") or std.mem.eql(u8, s, "LOADING")) return .buffering;
        if (std.mem.eql(u8, s, "IDLE")) return .idle;
        return .unknown;
    }
};

pub const Kind = enum {
    other,
    ping,
    pong,
    close,
    receiver_status,
    media_status,
    launch_error,
    load_failed,
    invalid_request,
};

pub const Id = struct {
    buf: [64]u8 = std.mem.zeroes([64]u8),
    len: usize = 0,
    pub fn slice(self: *const Id) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn set(self: *Id, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }
};

pub const App = struct {
    app_id: Id = .{},
    session_id: Id = .{},
    transport_id: Id = .{},
};

pub const Inbound = struct {
    kind: Kind = .other,
    request_id: u32 = 0,
    /// RECEIVER_STATUS: the Default Media Receiver when running, else the
    /// first app that has a transport (what a control command should talk to).
    app: ?App = null,
    app_is_default: bool = false,
    /// MEDIA_STATUS: the first status entry.
    media_session_id: ?i64 = null,
    player_state: PlayerState = .unknown,
    current_time: f64 = 0,
    duration: f64 = 0,
    idle_reason: Id = .{},
};

fn jfield(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn strField(v: std.json.Value, key: []const u8) []const u8 {
    const f = jfield(v, key) orelse return "";
    return if (f == .string) f.string else "";
}

fn numField(v: std.json.Value, key: []const u8) ?f64 {
    const f = jfield(v, key) orelse return null;
    return switch (f) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => null,
    };
}

/// Classify one inbound payload. Unparseable JSON is `.other`.
pub fn parseInbound(gpa: std.mem.Allocator, payload: []const u8) Inbound {
    var in = Inbound{};
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch return in;
    defer parsed.deinit();
    const root = parsed.value;
    const t = strField(root, "type");
    if (numField(root, "requestId")) |r| {
        if (r >= 0 and r <= std.math.maxInt(u32)) in.request_id = @intFromFloat(r);
    }
    if (std.mem.eql(u8, t, "PING")) {
        in.kind = .ping;
    } else if (std.mem.eql(u8, t, "PONG")) {
        in.kind = .pong;
    } else if (std.mem.eql(u8, t, "CLOSE")) {
        in.kind = .close;
    } else if (std.mem.eql(u8, t, "RECEIVER_STATUS")) {
        in.kind = .receiver_status;
        const status = jfield(root, "status") orelse return in;
        const apps = jfield(status, "applications") orelse return in;
        if (apps != .array) return in;
        for (apps.array.items) |a| {
            const tid = strField(a, "transportId");
            if (tid.len == 0) continue;
            const is_default = std.mem.eql(u8, strField(a, "appId"), default_media_receiver);
            if (in.app != null and !is_default) continue;
            var app = App{};
            app.app_id.set(strField(a, "appId"));
            app.session_id.set(strField(a, "sessionId"));
            app.transport_id.set(tid);
            in.app = app;
            in.app_is_default = is_default;
            if (is_default) break;
        }
    } else if (std.mem.eql(u8, t, "MEDIA_STATUS")) {
        in.kind = .media_status;
        const status = jfield(root, "status") orelse return in;
        if (status != .array or status.array.items.len == 0) return in;
        const s = status.array.items[0];
        if (numField(s, "mediaSessionId")) |id| in.media_session_id = @intFromFloat(id);
        in.player_state = PlayerState.fromCast(strField(s, "playerState"));
        in.current_time = numField(s, "currentTime") orelse 0;
        if (jfield(s, "media")) |m| in.duration = numField(m, "duration") orelse 0;
        in.idle_reason.set(strField(s, "idleReason"));
    } else if (std.mem.eql(u8, t, "LAUNCH_ERROR")) {
        in.kind = .launch_error;
    } else if (std.mem.eql(u8, t, "LOAD_FAILED") or std.mem.eql(u8, t, "LOAD_CANCELLED")) {
        in.kind = .load_failed;
    } else if (std.mem.eql(u8, t, "INVALID_REQUEST") or std.mem.eql(u8, t, "INVALID_PLAYER_STATE")) {
        in.kind = .invalid_request;
    }
    return in;
}

// ── Sender state machine ──────────────────────────────────────────────────

pub const Goal = union(enum) {
    load: LoadArgs,
    play,
    pause,
    stop,
    seek: f64,
    status,
};

pub const Phase = enum {
    start,
    await_receiver,
    await_launch,
    await_media,
    await_ack,
    done,
    failed,
};

pub const Failure = enum {
    none,
    launch_failed,
    load_failed,
    rejected,
    nothing_playing,
    receiver_closed,
    too_large,
};

pub fn failureMessage(f: Failure) []const u8 {
    return switch (f) {
        .none => "",
        .launch_failed => "The Chromecast could not start its media player",
        .load_failed => "The Chromecast could not load this media",
        .rejected => "The Chromecast rejected the command",
        .nothing_playing => "Nothing is playing on the Chromecast",
        .receiver_closed => "The Chromecast closed the connection",
        .too_large => "Media URL too long to cast",
    };
}

pub const payload_cap = 6144;

pub const Out = struct {
    dest: Id = .{},
    namespace: []const u8 = "",
    payload_buf: [payload_cap]u8 = undefined,
    payload_len: usize = 0,

    pub fn payload(self: *const Out) []const u8 {
        return self.payload_buf[0..self.payload_len];
    }
    pub fn message(self: *const Out) Message {
        return .{ .source = sender_id, .dest = self.dest.slice(), .namespace = self.namespace, .payload = self.payload() };
    }
};

pub const Outbox = struct {
    items: [3]Out = undefined,
    len: usize = 0,

    pub fn slice(self: *const Outbox) []const Out {
        return self.items[0..self.len];
    }
    fn push(self: *Outbox, dest: []const u8, namespace: []const u8, payload: ?[]const u8) bool {
        const p = payload orelse return false;
        if (self.len >= self.items.len or p.len > payload_cap) return false;
        var o = &self.items[self.len];
        o.* = .{ .namespace = namespace };
        o.dest.set(dest);
        @memcpy(o.payload_buf[0..p.len], p);
        o.payload_len = p.len;
        self.len += 1;
        return true;
    }
};

pub const Session = struct {
    goal: Goal,
    phase: Phase = .start,
    failure: Failure = .none,
    next_req: u32 = 1,
    pending_req: u32 = 0,
    transport: Id = .{},
    media_session_id: ?i64 = null,
    player_state: PlayerState = .unknown,
    current_time: f64 = 0,
    duration: f64 = 0,

    pub fn finished(self: *const Session) bool {
        return self.phase == .done or self.phase == .failed;
    }

    fn req(self: *Session) u32 {
        const r = self.next_req;
        self.next_req +%= 1;
        if (self.next_req == 0) self.next_req = 1;
        self.pending_req = r;
        return r;
    }

    fn fail(self: *Session, f: Failure) void {
        self.failure = f;
        self.phase = .failed;
    }

    fn applyMedia(self: *Session, in: *const Inbound) void {
        if (in.media_session_id) |id| self.media_session_id = id;
        self.player_state = in.player_state;
        self.current_time = in.current_time;
        if (in.duration > 0) self.duration = in.duration;
    }

    /// First frames: open the virtual connection and ask what is running.
    pub fn begin(self: *Session, out: *Outbox) void {
        var buf: [96]u8 = undefined;
        out.len = 0;
        _ = out.push(receiver_id, ns_connection, payload_connect);
        _ = out.push(receiver_id, ns_receiver, receiverGetStatus(&buf, self.req()));
        self.phase = .await_receiver;
    }

    fn connectAndSend(self: *Session, out: *Outbox) void {
        var buf: [payload_cap]u8 = undefined;
        const t = self.transport.slice();
        _ = out.push(t, ns_connection, payload_connect);
        switch (self.goal) {
            .load => |a| {
                if (!out.push(t, ns_media, load(&buf, self.req(), a))) return self.fail(.too_large);
                self.phase = .await_ack;
            },
            else => {
                _ = out.push(t, ns_media, mediaCommand(&buf, self.req(), .get_status, null));
                self.phase = .await_media;
            },
        }
    }

    /// Feed one decoded inbound frame; fills `out` with frames to send.
    pub fn onMessage(self: *Session, m: Message, in: *const Inbound, out: *Outbox) void {
        out.len = 0;
        if (self.finished()) return;
        if (std.mem.eql(u8, m.namespace, ns_heartbeat)) {
            if (in.kind == .ping) _ = out.push(m.source, ns_heartbeat, payload_pong);
            return;
        }
        if (std.mem.eql(u8, m.namespace, ns_connection)) {
            if (in.kind == .close) self.fail(.receiver_closed);
            return;
        }
        switch (self.phase) {
            .await_receiver, .await_launch => {
                if (in.kind == .launch_error) return self.fail(.launch_failed);
                if (in.kind == .invalid_request and in.request_id == self.pending_req) return self.fail(.rejected);
                if (in.kind != .receiver_status) return;
                const want_default = self.goal == .load;
                if (in.app) |app| if (!want_default or in.app_is_default) {
                    self.transport = app.transport_id;
                    return self.connectAndSend(out);
                };
                if (want_default) {
                    if (self.phase == .await_receiver) {
                        var buf: [128]u8 = undefined;
                        _ = out.push(receiver_id, ns_receiver, launch(&buf, self.req(), default_media_receiver));
                        self.phase = .await_launch;
                    }
                    // Still launching: wait for the status that lists it.
                    return;
                }
                // Control with no app running.
                if (self.goal == .status or self.goal == .stop) {
                    self.player_state = .idle;
                    self.phase = .done;
                } else self.fail(.nothing_playing);
            },
            .await_media => {
                if (in.kind == .invalid_request) return self.fail(.rejected);
                if (in.kind != .media_status) return;
                self.applyMedia(in);
                const id = self.media_session_id orelse {
                    if (self.goal == .status or self.goal == .stop) {
                        self.player_state = .idle;
                        self.phase = .done;
                    } else self.fail(.nothing_playing);
                    return;
                };
                var buf: [256]u8 = undefined;
                const t = self.transport.slice();
                const payload = switch (self.goal) {
                    .status => {
                        self.phase = .done;
                        return;
                    },
                    .play => mediaCommand(&buf, self.req(), .play, id),
                    .pause => mediaCommand(&buf, self.req(), .pause, id),
                    .stop => mediaCommand(&buf, self.req(), .stop, id),
                    .seek => |secs| seek(&buf, self.req(), id, secs),
                    .load => unreachable,
                };
                _ = out.push(t, ns_media, payload);
                self.phase = .await_ack;
            },
            .await_ack => {
                if (in.kind == .load_failed) return self.fail(.load_failed);
                if (in.kind == .invalid_request) return self.fail(if (self.goal == .load) .load_failed else .rejected);
                if (in.kind != .media_status) return;
                // Unsolicited broadcasts (requestId 0) carry progress, not our answer.
                if (in.request_id != self.pending_req) {
                    self.applyMedia(in);
                    return;
                }
                self.applyMedia(in);
                self.phase = .done;
            },
            .start, .done, .failed => {},
        }
    }
};

// ── mDNS discovery ─────────────────────────────────────────────────────────

pub const mdns_service = "_googlecast._tcp.local";
pub const mdns_group = "224.0.0.251";
pub const mdns_port: u16 = 5353;

/// One-question PTR query for `service` ("a.b.local"). Sent from an ephemeral
/// port, so responders answer unicast to it (RFC 6762 6.7 legacy unicast).
pub fn buildMdnsQuery(buf: []u8, service: []const u8) ?[]const u8 {
    if (buf.len < 12) return null;
    @memset(buf[0..12], 0);
    buf[5] = 1; // QDCOUNT
    var pos: usize = 12;
    var labels = std.mem.splitScalar(u8, service, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or pos + label.len + 1 > buf.len) return null;
        buf[pos] = @intCast(label.len);
        @memcpy(buf[pos + 1 .. pos + 1 + label.len], label);
        pos += label.len + 1;
    }
    if (pos + 5 > buf.len) return null;
    buf[pos] = 0;
    buf[pos + 1] = 0;
    buf[pos + 2] = 12; // PTR
    buf[pos + 3] = 0;
    buf[pos + 4] = 1; // IN
    return buf[0 .. pos + 5];
}

const Name = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    fn slice(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
    fn eql(self: *const Name, other: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.slice(), other);
    }
};

/// Read a (possibly compressed) DNS name at `pos.*` into `out` as dotted text.
/// Advances `pos` past the name in the record (not past pointer targets).
fn readName(pkt: []const u8, pos: *usize, out: *Name) bool {
    out.len = 0;
    var p = pos.*;
    var jumped = false;
    var hops: usize = 0;
    while (true) {
        if (p >= pkt.len) return false;
        const len = pkt[p];
        if (len == 0) {
            if (!jumped) pos.* = p + 1;
            return true;
        }
        if (len & 0xc0 == 0xc0) {
            if (p + 1 >= pkt.len) return false;
            hops += 1;
            if (hops > 16) return false;
            const target = (@as(usize, len & 0x3f) << 8) | pkt[p + 1];
            if (!jumped) pos.* = p + 2;
            jumped = true;
            if (target >= pkt.len) return false;
            p = target;
            continue;
        }
        if (len > 63 or p + 1 + len > pkt.len) return false;
        const label = pkt[p + 1 .. p + 1 + len];
        const extra: usize = if (out.len > 0) 1 else 0;
        if (out.len + extra + label.len > out.buf.len) return false;
        if (extra == 1) {
            out.buf[out.len] = '.';
            out.len += 1;
        }
        @memcpy(out.buf[out.len .. out.len + label.len], label);
        out.len += label.len;
        p += 1 + len;
    }
}

pub const Found = struct {
    name: Id = .{},
    ip: [46]u8 = std.mem.zeroes([46]u8),
    ip_len: usize = 0,
    port: u16 = default_port,
    id: Id = .{},
    model: Id = .{},

    pub fn ipSlice(self: *const Found) []const u8 {
        return self.ip[0..self.ip_len];
    }
};

const Rec = struct {
    owner: Name = .{},
    rtype: u16 = 0,
    rdata_start: usize = 0,
    rdata_len: usize = 0,
};

fn u16At(pkt: []const u8, p: usize) u16 {
    return (@as(u16, pkt[p]) << 8) | pkt[p + 1];
}

fn txtValue(pkt: []const u8, r: *const Rec, key: []const u8) []const u8 {
    var p = r.rdata_start;
    const end = r.rdata_start + r.rdata_len;
    while (p < end) {
        const n = pkt[p];
        p += 1;
        if (p + n > end) return "";
        const entry = pkt[p .. p + n];
        p += n;
        if (entry.len > key.len and entry[key.len] == '=' and std.ascii.eqlIgnoreCase(entry[0..key.len], key))
            return entry[key.len + 1 ..];
    }
    return "";
}

/// Devices announced in one mDNS response packet, appended to `out[count..]`
/// (an instance already listed by id or ip is skipped). `source_ip` is the
/// packet's sender, used when the packet carries no A record for the host.
pub fn parseMdnsResponse(pkt: []const u8, source_ip: []const u8, out: []Found, count: usize) usize {
    if (pkt.len < 12) return count;
    if (pkt[2] & 0x80 == 0) return count; // a query, not a response
    const qd = u16At(pkt, 4);
    const total: usize = @as(usize, u16At(pkt, 6)) + u16At(pkt, 8) + u16At(pkt, 10);
    var pos: usize = 12;
    var scratch = Name{};
    for (0..qd) |_| {
        if (!readName(pkt, &pos, &scratch)) return count;
        pos += 4;
    }
    var recs: [48]Rec = undefined;
    var nrec: usize = 0;
    for (0..total) |_| {
        if (nrec >= recs.len) break;
        var r = Rec{};
        if (!readName(pkt, &pos, &r.owner)) break;
        if (pos + 10 > pkt.len) break;
        r.rtype = u16At(pkt, pos);
        r.rdata_len = u16At(pkt, pos + 8);
        r.rdata_start = pos + 10;
        if (r.rdata_start + r.rdata_len > pkt.len) break;
        pos = r.rdata_start + r.rdata_len;
        recs[nrec] = r;
        nrec += 1;
    }
    var n = count;
    for (recs[0..nrec]) |*ptr| {
        if (n >= out.len) break;
        if (ptr.rtype != 12 or !ptr.owner.eql(mdns_service)) continue;
        var instance = Name{};
        var p = ptr.rdata_start;
        if (!readName(pkt, &p, &instance)) continue;
        var f = Found{};
        var target = Name{};
        var have_srv = false;
        for (recs[0..nrec]) |*r| {
            if (r.rtype == 33 and r.owner.eql(instance.slice()) and r.rdata_len >= 7) {
                f.port = u16At(pkt, r.rdata_start + 4);
                var tp = r.rdata_start + 6;
                have_srv = readName(pkt, &tp, &target);
            } else if (r.rtype == 16 and r.owner.eql(instance.slice())) {
                f.name.set(txtValue(pkt, r, "fn"));
                f.id.set(txtValue(pkt, r, "id"));
                f.model.set(txtValue(pkt, r, "md"));
            }
        }
        if (have_srv) for (recs[0..nrec]) |*r| {
            if (r.rtype == 1 and r.rdata_len == 4 and r.owner.eql(target.slice())) {
                const b = pkt[r.rdata_start .. r.rdata_start + 4];
                const ip = std.fmt.bufPrint(&f.ip, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch "";
                f.ip_len = ip.len;
                break;
            }
        };
        if (f.ip_len == 0) {
            const k = @min(source_ip.len, f.ip.len);
            @memcpy(f.ip[0..k], source_ip[0..k]);
            f.ip_len = k;
        }
        if (f.ip_len == 0) continue;
        if (f.name.len == 0) {
            // Instance label: "Chromecast-<id>" before the service suffix.
            const inst = instance.slice();
            const cut = std.mem.indexOfScalar(u8, inst, '.') orelse inst.len;
            f.name.set(inst[0..cut]);
        }
        var dup = false;
        for (out[0..n]) |*e| {
            if ((f.id.len > 0 and std.mem.eql(u8, e.id.slice(), f.id.slice())) or
                (std.mem.eql(u8, e.ipSlice(), f.ipSlice()) and e.port == f.port)) dup = true;
        }
        if (dup) continue;
        out[n] = f;
        n += 1;
    }
    return n;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "encodeFrame: length prefix and protobuf field layout" {
    var buf: [256]u8 = undefined;
    const f = encodeFrame(&buf, .{ .source = "sender-0", .dest = "receiver-0", .namespace = ns_heartbeat, .payload = payload_ping }).?;
    const body_len = std.mem.readInt(u32, f[0..4], .big);
    try testing.expectEqual(f.len - 4, body_len);
    // field 1 varint 0, then field 2 (0x12) with "sender-0"
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x00, 0x12, 8 }, f[4..8]);
    try testing.expectEqualStrings("sender-0", f[8..16]);
    try testing.expectEqual(@as(u8, 0x1a), f[16]);
    const m = decodeMessage(f[4..]).?;
    try testing.expectEqualStrings("sender-0", m.source);
    try testing.expectEqualStrings("receiver-0", m.dest);
    try testing.expectEqualStrings(ns_heartbeat, m.namespace);
    try testing.expectEqualStrings(payload_ping, m.payload);
}

test "encodeFrame: multi-byte varint lengths round-trip; tiny buffer refused" {
    var big: [300]u8 = undefined;
    @memset(&big, 'x');
    var buf: [512]u8 = undefined;
    const f = encodeFrame(&buf, .{ .source = "a", .dest = "b", .namespace = "c", .payload = &big }).?;
    const m = decodeMessage(f[4..]).?;
    try testing.expectEqual(@as(usize, 300), m.payload.len);
    var small: [16]u8 = undefined;
    try testing.expect(encodeFrame(&small, .{ .source = "a", .dest = "b", .namespace = "c", .payload = &big }) == null);
}

test "decodeMessage: skips unknown fields, rejects truncation" {
    // field 9 varint, field 6 "hi", field 10 fixed32
    const body = [_]u8{ 0x48, 0x96, 0x01, 0x32, 2, 'h', 'i', 0x55, 1, 2, 3, 4 };
    const m = decodeMessage(&body).?;
    try testing.expectEqualStrings("hi", m.payload);
    try testing.expect(decodeMessage(&.{ 0x32, 5, 'a' }) == null);
    try testing.expect(decodeMessage(&.{ 0x33 }) == null); // wire type 3 unsupported
}

test "frameLen bounds" {
    try testing.expectEqual(@as(?usize, 10), frameLen(.{ 0, 0, 0, 10 }));
    try testing.expect(frameLen(.{ 0, 0, 0, 0 }) == null);
    try testing.expect(frameLen(.{ 0x7f, 0, 0, 0 }) == null);
}

test "load payload escapes the URL and title and carries fMP4 HLS hints" {
    var buf: [1024]u8 = undefined;
    const p = load(&buf, 7, .{ .url = "http://10.0.0.2:5000/a\"b.m3u8", .content_type = "application/x-mpegURL", .title = "Tom \"T\"", .start_secs = 61.5, .hls_fmp4 = true }).?;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, p, .{});
    defer parsed.deinit();
    const media = parsed.value.object.get("media").?;
    try testing.expectEqualStrings("LOAD", parsed.value.object.get("type").?.string);
    try testing.expectEqual(@as(i64, 7), parsed.value.object.get("requestId").?.integer);
    try testing.expectEqualStrings("http://10.0.0.2:5000/a\"b.m3u8", media.object.get("contentId").?.string);
    try testing.expectEqualStrings("BUFFERED", media.object.get("streamType").?.string);
    try testing.expectEqualStrings("fmp4", media.object.get("hlsVideoSegmentFormat").?.string);
    try testing.expectEqualStrings("Tom \"T\"", media.object.get("metadata").?.object.get("title").?.string);
}

test "control payloads" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"type\":\"PAUSE\",\"requestId\":3,\"mediaSessionId\":9}", mediaCommand(&buf, 3, .pause, 9).?);
    try testing.expectEqualStrings("{\"type\":\"GET_STATUS\",\"requestId\":4}", mediaCommand(&buf, 4, .get_status, null).?);
    try testing.expect(std.mem.indexOf(u8, seek(&buf, 5, 9, 90).?, "\"currentTime\":90.000") != null);
    try testing.expect(std.mem.indexOf(u8, launch(&buf, 2, default_media_receiver).?, "\"appId\":\"CC1AD845\"") != null);
}

test "parseInbound: receiver status prefers the Default Media Receiver" {
    const js =
        \\{"type":"RECEIVER_STATUS","requestId":1,"status":{"applications":[
        \\ {"appId":"233637DE","sessionId":"yt","transportId":"t-yt"},
        \\ {"appId":"CC1AD845","sessionId":"s1","transportId":"web-5"}],"volume":{"level":1}}}
    ;
    const in = parseInbound(testing.allocator, js);
    try testing.expectEqual(Kind.receiver_status, in.kind);
    try testing.expect(in.app_is_default);
    try testing.expectEqualStrings("web-5", in.app.?.transport_id.slice());
    const other = parseInbound(testing.allocator, "{\"type\":\"RECEIVER_STATUS\",\"status\":{\"applications\":[{\"appId\":\"233637DE\",\"transportId\":\"t-yt\"}]}}");
    try testing.expect(!other.app_is_default);
    try testing.expectEqualStrings("t-yt", other.app.?.transport_id.slice());
    const idle = parseInbound(testing.allocator, "{\"type\":\"RECEIVER_STATUS\",\"status\":{\"volume\":{}}}");
    try testing.expect(idle.app == null);
}

test "parseInbound: media status and errors" {
    const in = parseInbound(testing.allocator, "{\"type\":\"MEDIA_STATUS\",\"requestId\":0,\"status\":[{\"mediaSessionId\":4,\"playerState\":\"PAUSED\",\"currentTime\":12.5,\"media\":{\"duration\":3600}}]}");
    try testing.expectEqual(Kind.media_status, in.kind);
    try testing.expectEqual(@as(?i64, 4), in.media_session_id);
    try testing.expectEqual(PlayerState.paused, in.player_state);
    try testing.expectEqual(@as(f64, 3600), in.duration);
    try testing.expectEqual(Kind.load_failed, parseInbound(testing.allocator, "{\"type\":\"LOAD_FAILED\",\"requestId\":3}").kind);
    try testing.expectEqual(Kind.other, parseInbound(testing.allocator, "not json").kind);
    const empty = parseInbound(testing.allocator, "{\"type\":\"MEDIA_STATUS\",\"status\":[]}");
    try testing.expect(empty.media_session_id == null);
}

fn feed(s: *Session, ns: []const u8, src: []const u8, json: []const u8, out: *Outbox) void {
    const in = parseInbound(testing.allocator, json);
    s.onMessage(.{ .source = src, .dest = sender_id, .namespace = ns, .payload = json }, &in, out);
}

test "state machine: load launches the Default Media Receiver, connects and loads" {
    var s = Session{ .goal = .{ .load = .{ .url = "http://192.168.1.5:9000/x.mp4", .title = "X" } } };
    var out = Outbox{};
    s.begin(&out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings(ns_connection, out.items[0].namespace);
    try testing.expectEqualStrings("receiver-0", out.items[1].dest.slice());

    // Idle receiver -> LAUNCH.
    feed(&s, ns_receiver, receiver_id, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1,\"status\":{}}", &out);
    try testing.expectEqual(Phase.await_launch, s.phase);
    try testing.expect(std.mem.indexOf(u8, out.items[0].payload(), "LAUNCH") != null);
    // A heartbeat in between is answered and changes nothing.
    feed(&s, ns_heartbeat, receiver_id, payload_ping, &out);
    try testing.expectEqualStrings(payload_pong, out.items[0].payload());
    try testing.expectEqual(Phase.await_launch, s.phase);
    // Launched -> CONNECT transport + LOAD.
    feed(&s, ns_receiver, receiver_id, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":2,\"status\":{\"applications\":[{\"appId\":\"CC1AD845\",\"sessionId\":\"s\",\"transportId\":\"web-1\"}]}}", &out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("web-1", out.items[0].dest.slice());
    try testing.expectEqualStrings(payload_connect, out.items[0].payload());
    try testing.expectEqualStrings(ns_media, out.items[1].namespace);
    try testing.expect(std.mem.indexOf(u8, out.items[1].payload(), "\"contentId\":\"http://192.168.1.5:9000/x.mp4\"") != null);
    const load_req = s.pending_req;
    // A broadcast status (requestId 0) is progress, not the answer.
    feed(&s, ns_media, "web-1", "{\"type\":\"MEDIA_STATUS\",\"requestId\":0,\"status\":[{\"mediaSessionId\":1,\"playerState\":\"BUFFERING\"}]}", &out);
    try testing.expectEqual(Phase.await_ack, s.phase);
    var buf: [256]u8 = undefined;
    const ack = try std.fmt.bufPrint(&buf, "{{\"type\":\"MEDIA_STATUS\",\"requestId\":{d},\"status\":[{{\"mediaSessionId\":1,\"playerState\":\"PLAYING\",\"currentTime\":0.2}}]}}", .{load_req});
    feed(&s, ns_media, "web-1", ack, &out);
    try testing.expectEqual(Phase.done, s.phase);
    try testing.expectEqual(PlayerState.playing, s.player_state);
    try testing.expectEqual(@as(?i64, 1), s.media_session_id);
}

test "state machine: load reuses a running Default Media Receiver and reports LOAD_FAILED" {
    var s = Session{ .goal = .{ .load = .{ .url = "http://h/x.mp4" } } };
    var out = Outbox{};
    s.begin(&out);
    feed(&s, ns_receiver, receiver_id, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1,\"status\":{\"applications\":[{\"appId\":\"CC1AD845\",\"transportId\":\"web-9\"}]}}", &out);
    try testing.expectEqual(Phase.await_ack, s.phase);
    feed(&s, ns_media, "web-9", "{\"type\":\"LOAD_FAILED\",\"requestId\":2}", &out);
    try testing.expectEqual(Phase.failed, s.phase);
    try testing.expectEqual(Failure.load_failed, s.failure);
}

test "state machine: a different app running is replaced by LAUNCH for load" {
    var s = Session{ .goal = .{ .load = .{ .url = "http://h/x.mp4" } } };
    var out = Outbox{};
    s.begin(&out);
    feed(&s, ns_receiver, receiver_id, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1,\"status\":{\"applications\":[{\"appId\":\"233637DE\",\"transportId\":\"t-yt\"}]}}", &out);
    try testing.expectEqual(Phase.await_launch, s.phase);
    feed(&s, ns_receiver, receiver_id, "{\"type\":\"LAUNCH_ERROR\",\"requestId\":2}", &out);
    try testing.expectEqual(Failure.launch_failed, s.failure);
}

test "state machine: seek finds the media session then sends SEEK" {
    var s = Session{ .goal = .{ .seek = 754 } };
    var out = Outbox{};
    s.begin(&out);
    feed(&s, ns_receiver, receiver_id, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1,\"status\":{\"applications\":[{\"appId\":\"CC1AD845\",\"transportId\":\"web-2\"}]}}", &out);
    try testing.expectEqual(Phase.await_media, s.phase);
    try testing.expect(std.mem.indexOf(u8, out.items[1].payload(), "GET_STATUS") != null);
    feed(&s, ns_media, "web-2", "{\"type\":\"MEDIA_STATUS\",\"requestId\":2,\"status\":[{\"mediaSessionId\":3,\"playerState\":\"PLAYING\",\"currentTime\":10}]}", &out);
    try testing.expectEqual(Phase.await_ack, s.phase);
    try testing.expect(std.mem.indexOf(u8, out.items[0].payload(), "\"type\":\"SEEK\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0].payload(), "\"mediaSessionId\":3") != null);
    feed(&s, ns_media, "web-2", "{\"type\":\"MEDIA_STATUS\",\"requestId\":3,\"status\":[{\"mediaSessionId\":3,\"playerState\":\"PLAYING\",\"currentTime\":754}]}", &out);
    try testing.expectEqual(Phase.done, s.phase);
    try testing.expectEqual(@as(f64, 754), s.current_time);
}

test "state machine: pause with nothing playing fails; status and stop report idle" {
    var out = Outbox{};
    var p = Session{ .goal = .pause };
    p.begin(&out);
    feed(&p, ns_receiver, receiver_id, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1,\"status\":{}}", &out);
    try testing.expectEqual(Failure.nothing_playing, p.failure);
    var st = Session{ .goal = .status };
    st.begin(&out);
    feed(&st, ns_receiver, receiver_id, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1,\"status\":{}}", &out);
    try testing.expectEqual(Phase.done, st.phase);
    try testing.expectEqual(PlayerState.idle, st.player_state);
    var stop = Session{ .goal = .stop };
    stop.begin(&out);
    feed(&stop, ns_receiver, receiver_id, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1,\"status\":{\"applications\":[{\"appId\":\"CC1AD845\",\"transportId\":\"w\"}]}}", &out);
    feed(&stop, ns_media, "w", "{\"type\":\"MEDIA_STATUS\",\"requestId\":2,\"status\":[]}", &out);
    try testing.expectEqual(Phase.done, stop.phase);
}

test "state machine: receiver CLOSE and INVALID_REQUEST fail" {
    var out = Outbox{};
    var s = Session{ .goal = .play };
    s.begin(&out);
    feed(&s, ns_connection, receiver_id, payload_close, &out);
    try testing.expectEqual(Failure.receiver_closed, s.failure);
    var t = Session{ .goal = .{ .seek = 5 } };
    t.begin(&out);
    feed(&t, ns_receiver, receiver_id, "{\"type\":\"RECEIVER_STATUS\",\"requestId\":1,\"status\":{\"applications\":[{\"appId\":\"CC1AD845\",\"transportId\":\"w\"}]}}", &out);
    feed(&t, ns_media, "w", "{\"type\":\"MEDIA_STATUS\",\"requestId\":2,\"status\":[{\"mediaSessionId\":1}]}", &out);
    feed(&t, ns_media, "w", "{\"type\":\"INVALID_REQUEST\",\"requestId\":3}", &out);
    try testing.expectEqual(Failure.rejected, t.failure);
}

test "mDNS query layout" {
    var buf: [128]u8 = undefined;
    const q = buildMdnsQuery(&buf, mdns_service).?;
    try testing.expectEqual(@as(u8, 1), q[5]);
    try testing.expectEqualSlices(u8, "\x0b_googlecast\x04_tcp\x05local\x00\x00\x0c\x00\x01", q[12..]);
}

/// Test helper: write a name as labels.
fn putName(buf: []u8, pos: *usize, name: []const u8) void {
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |l| {
        buf[pos.*] = @intCast(l.len);
        @memcpy(buf[pos.* + 1 .. pos.* + 1 + l.len], l);
        pos.* += l.len + 1;
    }
    buf[pos.*] = 0;
    pos.* += 1;
}

fn putRec(buf: []u8, pos: *usize, rtype: u16, rdata: []const u8) void {
    std.mem.writeInt(u16, buf[pos.*..][0..2], rtype, .big);
    std.mem.writeInt(u16, buf[pos.* + 2 ..][0..2], 0x8001, .big);
    std.mem.writeInt(u32, buf[pos.* + 4 ..][0..4], 120, .big);
    std.mem.writeInt(u16, buf[pos.* + 8 ..][0..2], @intCast(rdata.len), .big);
    @memcpy(buf[pos.* + 10 .. pos.* + 10 + rdata.len], rdata);
    pos.* += 10 + rdata.len;
}

test "parseMdnsResponse: PTR + SRV + TXT + A with name compression" {
    var pkt: [512]u8 = std.mem.zeroes([512]u8);
    pkt[2] = 0x84; // response, authoritative
    pkt[7] = 1; // ANCOUNT
    pkt[11] = 3; // ARCOUNT
    var pos: usize = 12;
    const svc_at = pos;
    putName(&pkt, &pos, mdns_service);
    // PTR rdata: "Chromecast-abc" + pointer to the service name.
    var rd: [64]u8 = undefined;
    rd[0] = 14;
    @memcpy(rd[1..15], "Chromecast-abc");
    rd[15] = 0xc0;
    rd[16] = @intCast(svc_at);
    putRec(&pkt, &pos, 12, rd[0..17]);
    const inst_at = pos;
    // SRV owner = instance (written in full), target host "abc.local".
    putName(&pkt, &pos, "Chromecast-abc._googlecast._tcp.local");
    var srv: [64]u8 = undefined;
    @memcpy(srv[0..6], &[_]u8{ 0, 0, 0, 0, 0x1f, 0x49 }); // port 8009
    var sp: usize = 6;
    putName(&srv, &sp, "abc.local");
    putRec(&pkt, &pos, 33, srv[0..sp]);
    // TXT owner via pointer to the instance name.
    pkt[pos] = 0xc0;
    pkt[pos + 1] = @intCast(inst_at);
    pos += 2;
    const txt = "\x06id=abc\x0efn=Living Room\x0dmd=Chromecast";
    putRec(&pkt, &pos, 16, txt);
    putName(&pkt, &pos, "abc.local");
    putRec(&pkt, &pos, 1, &.{ 192, 168, 1, 40 });

    var out: [4]Found = undefined;
    const n = parseMdnsResponse(pkt[0..pos], "192.168.1.99", &out, 0);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("Living Room", out[0].name.slice());
    try testing.expectEqualStrings("192.168.1.40", out[0].ipSlice());
    try testing.expectEqual(@as(u16, 8009), out[0].port);
    try testing.expectEqualStrings("abc", out[0].id.slice());
    try testing.expectEqualStrings("Chromecast", out[0].model.slice());
    // The same device again is not duplicated.
    try testing.expectEqual(@as(usize, 1), parseMdnsResponse(pkt[0..pos], "192.168.1.99", &out, 1));
}

test "parseMdnsResponse: queries, truncation and pointer loops are ignored" {
    var out: [2]Found = undefined;
    try testing.expectEqual(@as(usize, 0), parseMdnsResponse(&.{ 0, 0, 0, 0 }, "1.2.3.4", &out, 0));
    // A query packet (QR bit clear).
    var q: [64]u8 = undefined;
    const query = buildMdnsQuery(&q, mdns_service).?;
    try testing.expectEqual(@as(usize, 0), parseMdnsResponse(query, "1.2.3.4", &out, 0));
    // Self-referencing pointer in the answer name.
    const loop = [_]u8{ 0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xc0, 12 };
    try testing.expectEqual(@as(usize, 0), parseMdnsResponse(&loop, "1.2.3.4", &out, 0));
}
