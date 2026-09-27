//! Loopback adapter for YouTube's adaptive CDN streams.
//!
//! Google rejects FFmpeg's open-ended `Range: bytes=N-` request for these
//! URLs, while bounded ranges work. Each local response therefore advertises
//! exactly the bounded chunk it can deliver; FFmpeg reconnects for the next
//! chunk and can seek by opening a new range at the requested byte.

const std = @import("std");
const pure = @import("../services/youtube_player_pure.zig");
const sync = @import("../core/sync.zig");
const io_g = @import("../core/io_global.zig");

const MAX_STREAMS = 8;
const PORT_START: u16 = 45778;
const PORT_END: u16 = 45878;
const TOKEN_LEN = 16;
// Google Video may reject larger `range=` windows with HTTP 403.
const UPSTREAM_CHUNK: u64 = 1024 * 1024;
const UPSTREAM_ATTEMPTS: usize = 3;

const ListenerT = @TypeOf(blk: {
    const a = std.Io.net.IpAddress.parseIp4("127.0.0.1", PORT_START) catch unreachable;
    break :blk a.listen(io_g.io(), .{ .reuse_address = true }) catch unreachable;
});

const Slot = struct {
    in_use: bool = false,
    id: u32 = 0,
    port: u16 = 0,
    token: [TOKEN_LEN]u8 = @splat(0),
    streams: pure.Streams = .{},
    stop: bool = false,
    thread: ?std.Thread = null,
    listener: ?ListenerT = null,
};

pub const Handle = struct {
    id: u32 = 0,
    slot: u8 = 0,
    port: u16 = 0,
    token: [TOKEN_LEN]u8 = @splat(0),

    pub fn valid(self: Handle) bool {
        return self.id != 0 and self.slot < MAX_STREAMS and self.port != 0;
    }
};

pub const invalid_handle: Handle = .{};

var slots: [MAX_STREAMS]Slot = [_]Slot{.{}} ** MAX_STREAMS;
var mutex = sync.Mutex{};
var next_id: u32 = 1;
var port_cursor: u16 = PORT_START;
var rng_ready = false;
var rng: std.Random.DefaultCsprng = undefined;
var rng_mutex = sync.Mutex{};

fn randomToken(out: *[TOKEN_LEN]u8) void {
    rng_mutex.lock();
    defer rng_mutex.unlock();
    if (!rng_ready) {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        if (!io_g.randomSecure(&seed)) {
            const t: u64 = @bitCast(io_g.milliTimestamp());
            for (&seed, 0..) |*b, i| b.* = @truncate(t >> @intCast((i % 8) * 8));
        }
        rng = std.Random.DefaultCsprng.init(seed);
        rng_ready = true;
    }
    var bytes: [TOKEN_LEN / 2]u8 = undefined;
    rng.fill(&bytes);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 15];
    }
}

fn nextPort(p: u16) u16 {
    return if (p + 1 >= PORT_END) PORT_START else p + 1;
}

pub fn start(streams: pure.Streams) ?Handle {
    mutex.lock();
    var idx: ?usize = null;
    for (slots, 0..) |s, i| if (!s.in_use) {
        idx = i;
        break;
    };
    const i = idx orelse {
        mutex.unlock();
        return null;
    };
    const s = &slots[i];
    s.* = .{ .in_use = true, .id = next_id, .streams = streams };
    next_id +%= 1;
    if (next_id == 0) next_id = 1;
    randomToken(&s.token);

    var probe = port_cursor;
    var tried: u16 = 0;
    while (tried < PORT_END - PORT_START) : (tried += 1) {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", probe) catch {
            probe = nextPort(probe);
            continue;
        };
        if (addr.listen(io_g.io(), .{ .reuse_address = true })) |listener| {
            s.listener = listener;
            s.port = probe;
            port_cursor = nextPort(probe);
            break;
        } else |_| {}
        probe = nextPort(probe);
    }
    if (s.port == 0) {
        s.* = .{};
        mutex.unlock();
        return null;
    }
    const slot_u8: u8 = @intCast(i);
    s.thread = @import("../core/workers.zig").spawnLegacy(acceptLoop, .{slot_u8}) catch {
        if (s.listener) |*listener| listener.deinit(io_g.io());
        s.* = .{};
        mutex.unlock();
        return null;
    };
    const handle: Handle = .{ .id = s.id, .slot = slot_u8, .port = s.port, .token = s.token };
    mutex.unlock();
    return handle;
}

pub fn stop(handle: Handle) void {
    if (!handle.valid()) return;
    mutex.lock();
    const s = &slots[handle.slot];
    if (!s.in_use or s.id != handle.id) {
        mutex.unlock();
        return;
    }
    s.stop = true;
    const port = s.port;
    const thread = s.thread;
    mutex.unlock();
    if (std.Io.net.IpAddress.parseIp4("127.0.0.1", port)) |addr| {
        if (addr.connect(io_g.io(), .{ .mode = .stream })) |conn_value| {
            var conn = conn_value;
            conn.close(io_g.io());
        } else |_| {}
    } else |_| {}
    if (thread) |t| t.join();
}

pub fn stopAll() void {
    var i: usize = 0;
    while (i < MAX_STREAMS) : (i += 1) {
        mutex.lock();
        const h: Handle = .{ .id = slots[i].id, .slot = @intCast(i), .port = slots[i].port, .token = slots[i].token };
        const active = slots[i].in_use;
        mutex.unlock();
        if (active) stop(h);
    }
}

pub fn url(handle: Handle, quality_idx: usize, audio: bool, out: []u8) ?[]const u8 {
    if (!handle.valid()) return null;
    const kind = if (audio) "a" else switch (quality_idx) {
        0 => "720",
        1 => "1080",
        2 => "2160",
        else => "p",
    };
    return std.fmt.bufPrint(out, "http://127.0.0.1:{d}/{s}/{s}", .{ handle.port, kind, handle.token }) catch null;
}

const ConnArgs = struct { slot: u8, id: u32, conn: std.Io.net.Stream };

fn acceptLoop(slot: u8) void {
    while (true) {
        mutex.lock();
        const done = slots[slot].stop or !slots[slot].in_use;
        mutex.unlock();
        if (done) break;
        var conn = slots[slot].listener.?.accept(io_g.io()) catch continue;
        mutex.lock();
        const id = slots[slot].id;
        const stopping = slots[slot].stop;
        mutex.unlock();
        if (stopping) {
            conn.close(io_g.io());
            break;
        }
        const args: ConnArgs = .{ .slot = slot, .id = id, .conn = conn };
        if (@import("../core/workers.zig").spawnLegacy(handleThread, .{args})) |t|
            @import("../core/workers.zig").release(t)
        else |_| {
            handleThread(args);
        }
    }
    mutex.lock();
    if (slots[slot].listener) |*listener| listener.deinit(io_g.io());
    slots[slot] = .{};
    mutex.unlock();
}

fn handleThread(args: ConnArgs) void {
    var conn = args.conn;
    defer conn.close(io_g.io());
    handleConnection(args) catch {};
}

fn status(conn: std.Io.net.Stream, code: []const u8, total: u64) void {
    var buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Range: bytes */{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ code, total }) catch return;
    io_g.streamWriteAll(conn, msg) catch {};
}

fn choose(path: []const u8, streams: *const pure.Streams) ?*const pure.Stream {
    if (std.mem.startsWith(u8, path, "/a/")) return if (streams.audio.url_len > 0) &streams.audio else null;
    if (std.mem.startsWith(u8, path, "/720/")) return streams.videoFor(0);
    if (std.mem.startsWith(u8, path, "/1080/")) return streams.videoFor(1);
    if (std.mem.startsWith(u8, path, "/2160/")) return streams.videoFor(2);
    if (std.mem.startsWith(u8, path, "/p/")) return if (streams.progressive.url_len > 0) &streams.progressive else null;
    return null;
}

const ByteRange = struct { start: u64, end: u64 };
const ParsedRange = union(enum) {
    absent,
    invalid,
    range: ByteRange,
};

/// HTTP field names and the `bytes` unit are case-insensitive. FFmpeg normally
/// emits `Range`, but accepting only that exact spelling turns a valid seek
/// into a byte-zero request as soon as a client or library changes casing.
fn parseRange(request: []const u8, total: u64) ParsedRange {
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "range")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len < 6 or !std.ascii.eqlIgnoreCase(value[0..6], "bytes=")) return .invalid;
        const spec = std.mem.trim(u8, value[6..], " \t");
        if (std.mem.indexOfScalar(u8, spec, ',') != null) return .invalid;
        const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .invalid;
        if (dash == 0) {
            const suffix = std.fmt.parseInt(u64, spec[1..], 10) catch return .invalid;
            if (suffix == 0 or total == 0) return .invalid;
            return .{ .range = .{ .start = total -| suffix, .end = total - 1 } };
        }
        const start_byte = std.fmt.parseInt(u64, spec[0..dash], 10) catch return .invalid;
        if (start_byte >= total) return .invalid;
        const end = if (dash + 1 < spec.len)
            std.fmt.parseInt(u64, spec[dash + 1 ..], 10) catch return .invalid
        else
            total - 1;
        if (end < start_byte) return .invalid;
        return .{ .range = .{ .start = start_byte, .end = @min(end, total - 1) } };
    }
    return .absent;
}

fn responseHead(conn: std.Io.net.Stream, partial: bool, range: ByteRange, total: u64, mime: []const u8) bool {
    var buf: [512]u8 = undefined;
    const length = range.end - range.start + 1;
    const header = if (partial)
        std.fmt.bufPrint(&buf, "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ mime, range.start, range.end, total, length }) catch return false
    else
        std.fmt.bufPrint(&buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ mime, total }) catch return false;
    io_g.streamWriteAll(conn, header) catch return false;
    return true;
}

fn fetchChunk(selected: *const pure.Stream, start_byte: u64, end_byte: u64, buf: []u8) ?[]const u8 {
    const length: usize = @intCast(end_byte - start_byte + 1);
    // The videoplayback endpoint has a first-class `range=` query contract.
    // It is more reliable across its keep-alive/CDN frontends than issuing a
    // succession of HTTP Range fields on one pooled client (the latter starts
    // returning 502 after a few chunks on current Google Video hosts).
    var url_buf: [pure.MAX_URL + 64]u8 = undefined;
    const separator: u8 = if (std.mem.indexOfScalar(u8, selected.slice(), '?') == null) '?' else '&';
    const ranged_url = std.fmt.bufPrint(&url_buf, "{s}{c}range={d}-{d}", .{ selected.slice(), separator, start_byte, end_byte }) catch return null;
    var attempt: usize = 0;
    while (attempt < UPSTREAM_ATTEMPTS) : (attempt += 1) {
        var upstream_status: ?std.http.Status = null;
        const body = @import("../core/http.zig").fetchDirect(ranged_url, buf, .{
            .timeout_secs = 12,
            .user_agent = pure.VR_USER_AGENT,
            .accept = "*/*",
            .max_response = length + 1,
            .status_out = &upstream_status,
        }) orelse continue;
        if (body.len == length and
            (upstream_status == .ok or upstream_status == .partial_content)) return body;
    }
    return null;
}

fn handleConnection(args: ConnArgs) !void {
    mutex.lock();
    const live = slots[args.slot].in_use and slots[args.slot].id == args.id;
    const streams = slots[args.slot].streams;
    const token = slots[args.slot].token;
    mutex.unlock();
    if (!live) return;

    var request_buf: [4096]u8 = undefined;
    const n = io_g.streamReadAll(args.conn, &request_buf) catch return;
    const request = request_buf[0..n];
    const is_head = std.mem.startsWith(u8, request, "HEAD ");
    if (!is_head and !std.mem.startsWith(u8, request, "GET ")) return status(args.conn, "405 Method Not Allowed", 0);
    const first_space = std.mem.indexOfScalar(u8, request, ' ') orelse return;
    const tail = request[first_space + 1 ..];
    const path = tail[0 .. std.mem.indexOfScalar(u8, tail, ' ') orelse return];
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    const supplied = path[last_slash + 1 ..];
    if (supplied.len != TOKEN_LEN) return status(args.conn, "403 Forbidden", 0);
    var mismatch: u8 = 0;
    for (supplied, 0..) |ch, i| mismatch |= ch ^ token[i];
    if (mismatch != 0) return status(args.conn, "403 Forbidden", 0);
    const selected = choose(path, &streams) orelse return status(args.conn, "404 Not Found", 0);
    if (selected.content_length == 0) return status(args.conn, "502 Bad Gateway", 0);

    const total = selected.content_length;
    const parsed = parseRange(request, total);
    const requested = switch (parsed) {
        .absent => ByteRange{ .start = 0, .end = total - 1 },
        .invalid => return status(args.conn, "416 Range Not Satisfiable", total),
        .range => |r| r,
    };
    const served = ByteRange{
        .start = requested.start,
        .end = @min(requested.end, requested.start +| (UPSTREAM_CHUNK - 1)),
    };
    const mime = if (selected.height == 0) "audio/mp4" else if (selected.codec_rank == 1) "video/webm" else "video/mp4";
    if (is_head) {
        _ = responseHead(args.conn, true, served, total, mime);
        return;
    }

    const body_buf = @import("../core/alloc.zig").allocator.alloc(u8, UPSTREAM_CHUNK + 1) catch return status(args.conn, "503 Service Unavailable", total);
    defer @import("../core/alloc.zig").allocator.free(body_buf);
    const body = fetchChunk(selected, served.start, served.end, body_buf) orelse return status(args.conn, "502 Bad Gateway", total);
    if (!responseHead(args.conn, true, served, total, mime)) return;
    io_g.streamWriteAll(args.conn, body) catch return;
}

test "range parser accepts FFmpeg casing and open ended seeks" {
    const total: u64 = 10_000;
    const lower = parseRange("GET / HTTP/1.1\r\nrange: bytes=4321-\r\n\r\n", total);
    try std.testing.expectEqual(ByteRange{ .start = 4321, .end = 9999 }, lower.range);
    const mixed = parseRange("GET / HTTP/1.1\r\nRaNgE: ByTeS=10-19\r\n\r\n", total);
    try std.testing.expectEqual(ByteRange{ .start = 10, .end = 19 }, mixed.range);
}

test "range parser handles suffixes and rejects malformed ranges" {
    const suffix = parseRange("GET / HTTP/1.1\r\nRange: bytes=-500\r\n\r\n", 10_000);
    try std.testing.expectEqual(ByteRange{ .start = 9500, .end = 9999 }, suffix.range);
    try std.testing.expect(parseRange("GET / HTTP/1.1\r\nRange: bytes=900-100\r\n\r\n", 1000) == .invalid);
    try std.testing.expect(parseRange("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", 1000) == .absent);
}
