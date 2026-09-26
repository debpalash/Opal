//! Loopback adapter for YouTube's adaptive CDN streams.
//!
//! Google rejects FFmpeg's open-ended `Range: bytes=N-` request for these
//! URLs, while bounded ranges work. Each local request is capped to 8 MiB and
//! forwarded upstream as `bytes=N-M`; the truthful 206 response makes FFmpeg
//! request the next chunk or seek through this endpoint again.

const std = @import("std");
const pure = @import("../services/youtube_player_pure.zig");
const sync = @import("../core/sync.zig");
const io_g = @import("../core/io_global.zig");

const MAX_STREAMS = 8;
const PORT_START: u16 = 45778;
const PORT_END: u16 = 45878;
const TOKEN_LEN = 16;
const UPSTREAM_CHUNK: u64 = 1024 * 1024;

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

    var start_byte: u64 = 0;
    var requested_end: ?u64 = null;
    if (std.mem.indexOf(u8, request, "Range: bytes=")) |ri| {
        const value_start = ri + "Range: bytes=".len;
        const line_end = std.mem.indexOfAnyPos(u8, request, value_start, "\r\n") orelse request.len;
        const value = request[value_start..line_end];
        if (std.mem.indexOfScalar(u8, value, '-')) |dash| {
            start_byte = std.fmt.parseInt(u64, value[0..dash], 10) catch 0;
            if (dash + 1 < value.len) requested_end = std.fmt.parseInt(u64, value[dash + 1 ..], 10) catch null;
        }
    }
    const total = selected.content_length;
    if (start_byte >= total) return status(args.conn, "416 Range Not Satisfiable", total);
    var end = @min(total - 1, start_byte + UPSTREAM_CHUNK - 1);
    if (requested_end) |wanted| end = @min(end, wanted);
    const length = end - start_byte + 1;

    if (!is_head) {
        var range_buf: [96]u8 = undefined;
        const range = std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ start_byte, end }) catch return;
        const body_buf = @import("../core/alloc.zig").allocator.alloc(u8, @intCast(length + 1)) catch return status(args.conn, "503 Service Unavailable", total);
        defer @import("../core/alloc.zig").allocator.free(body_buf);
        const headers = [_]std.http.Header{.{ .name = "Range", .value = range }};
        const body = @import("../core/http.zig").fetchDirect(selected.slice(), body_buf, .{
            .timeout_secs = 8,
            .user_agent = pure.VR_USER_AGENT,
            .accept = "*/*",
            .max_response = body_buf.len,
            .extra_headers = &headers,
            .preserve_range_on_redirect = true,
        }) orelse return status(args.conn, "502 Bad Gateway", total);
        if (body.len != length) return status(args.conn, "502 Bad Gateway", total);

        var header_buf: [512]u8 = undefined;
        const mime = if (selected.height == 0) "audio/mp4" else if (selected.codec_rank == 1) "video/webm" else "video/mp4";
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ mime, start_byte, end, total, length }) catch return;
        io_g.streamWriteAll(args.conn, header) catch return;
        io_g.streamWriteAll(args.conn, body) catch return;
        return;
    }

    var header_buf: [512]u8 = undefined;
    const mime = if (selected.height == 0) "audio/mp4" else if (selected.codec_rank == 1) "video/webm" else "video/mp4";
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ mime, start_byte, end, total, length }) catch return;
    io_g.streamWriteAll(args.conn, header) catch return;
}
