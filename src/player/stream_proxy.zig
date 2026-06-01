const std = @import("std");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const sync = @import("../core/sync.zig");
const io_g = @import("../core/io_global.zig");

// ══════════════════════════════════════════════════════════
// Opal v2 — Multi-tenant Torrent HTTP Streaming Proxy
//
// Each torrent stream gets its own listener on a private port
// plus a per-stream random token in the URL path. This unlocks
// real split-view multi-stream (every player can stream a
// different torrent at the same time) and closes the local-CORS
// hole at the protocol layer — a browser tab that doesn't know
// the token literally can't read your private data.
//
// Flow:
//   1. startProxy(torrent_id, file_idx) -> Handle{ slot, port, token }
//   2. getStreamUrl(handle, buf) -> "http://127.0.0.1:<port>/s/<token>"
//   3. mpv requests bytes; we map Range → pieces → block until ready
//   4. stopProxy(handle) tears down that one stream
//
// Back-pressure (the reason this proxy exists at all) is unchanged:
// torrent_read_bytes blocks the worker until the requested pieces
// arrive, so mpv never reads undownloaded data.
// ══════════════════════════════════════════════════════════

const CHUNK_SIZE: usize = 512 * 1024;
pub const MAX_STREAMS: usize = 8;
const PORT_RANGE_START: u16 = 45678;
const PORT_RANGE_END: u16 = 45778; // exclusive
const TOKEN_HEX_LEN: usize = 16;

// Probe a port to get the concrete listener type — std.Io 0.16 doesn't
// expose this directly, so we recover it via @TypeOf on a known-good call.
const ListenerT = @TypeOf(blk: {
    const a = std.Io.net.IpAddress.parseIp4("127.0.0.1", PORT_RANGE_START) catch unreachable;
    break :blk a.listen(io_g.io(), .{ .reuse_address = true }) catch unreachable;
});

const Stream = struct {
    in_use: bool = false,
    id: u32 = 0,
    port: u16 = 0,
    token: [TOKEN_HEX_LEN]u8 = std.mem.zeroes([TOKEN_HEX_LEN]u8),
    torrent_id: i32 = -1,
    file_idx: i32 = -1,
    file_size: i64 = 0,
    file_name: [256]u8 = std.mem.zeroes([256]u8),
    file_name_len: usize = 0,
    stop: bool = false,
    thread: ?std.Thread = null,
    listener: ?ListenerT = null,
};

var streams: [MAX_STREAMS]Stream = [_]Stream{.{}} ** MAX_STREAMS;
var streams_mutex = sync.Mutex{};
var next_stream_id: u32 = 1;
var port_cursor: u16 = PORT_RANGE_START;

pub const Handle = struct {
    id: u32,
    slot: u8,
    port: u16,
    token: [TOKEN_HEX_LEN]u8,

    pub fn isValid(self: Handle) bool {
        return self.id != 0 and self.slot < MAX_STREAMS and self.port != 0;
    }
};

pub const INVALID_HANDLE: Handle = .{
    .id = 0,
    .slot = 0,
    .port = 0,
    .token = std.mem.zeroes([TOKEN_HEX_LEN]u8),
};

var csprng_init: bool = false;
var csprng: std.Random.DefaultCsprng = undefined;
var csprng_mutex = sync.Mutex{};

fn seedCsprng() void {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    // Try /dev/urandom (macOS + Linux). Fall back to time/pid/counter if unavailable.
    var seeded = false;
    if (io_g.openFileAbsolute("/dev/urandom", .{})) |f| {
        var fh = f;
        defer fh.close(io_g.io());
        const n = io_g.readAll(fh, &seed) catch 0;
        if (n == seed.len) seeded = true;
    } else |_| {}
    if (!seeded) {
        const t = io_g.milliTimestamp();
        const tid = std.Thread.getCurrentId();
        var i: usize = 0;
        while (i < seed.len) : (i += 1) {
            const mix: u64 = @as(u64, @bitCast(t)) ^ tid ^ (i *% 0x9e3779b97f4a7c15);
            seed[i] = @truncate(mix >> @as(u6, @intCast(i % 8)) * 8);
        }
    }
    csprng = std.Random.DefaultCsprng.init(seed);
}

fn randomToken(out: *[TOKEN_HEX_LEN]u8) void {
    csprng_mutex.lock();
    defer csprng_mutex.unlock();
    if (!csprng_init) {
        seedCsprng();
        csprng_init = true;
    }
    var bytes: [TOKEN_HEX_LEN / 2]u8 = undefined;
    csprng.fill(&bytes);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

fn nextProbe(p: u16) u16 {
    const n = p + 1;
    return if (n >= PORT_RANGE_END) PORT_RANGE_START else n;
}

pub fn startProxy(torrent_id: i32, file_idx: i32) ?Handle {
    const file_size = c.mpv.torrent_get_file_size(state.app.torrent_ses, torrent_id, file_idx);
    if (file_size <= 0) {
        logs.pushLog("error", "proxy", "Cannot start proxy: file size unknown", false);
        return null;
    }

    streams_mutex.lock();

    // Find a free slot.
    var slot_idx: ?usize = null;
    for (streams, 0..) |s, i| {
        if (!s.in_use) {
            slot_idx = i;
            break;
        }
    }
    if (slot_idx == null) {
        streams_mutex.unlock();
        logs.pushLog("error", "proxy", "Max concurrent streams reached", false);
        return null;
    }
    const idx = slot_idx.?;
    const s = &streams[idx];

    s.* = .{
        .in_use = true,
        .id = next_stream_id,
        .torrent_id = torrent_id,
        .file_idx = file_idx,
        .file_size = file_size,
    };
    next_stream_id +%= 1;
    if (next_stream_id == 0) next_stream_id = 1; // never hand out id 0
    randomToken(&s.token);

    c.mpv.torrent_get_file_name(state.app.torrent_ses, torrent_id, file_idx, &s.file_name, 256);
    s.file_name_len = std.mem.indexOfScalar(u8, &s.file_name, 0) orelse 0;

    // Probe ports; start from the rotating cursor so concurrent slots spread out.
    var bound: u16 = 0;
    var probe: u16 = port_cursor;
    var tried: u16 = 0;
    const span: u16 = PORT_RANGE_END - PORT_RANGE_START;
    while (tried < span) : (tried += 1) {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", probe) catch {
            probe = nextProbe(probe);
            continue;
        };
        if (addr.listen(io_g.io(), .{ .reuse_address = true })) |listener| {
            s.listener = listener;
            bound = probe;
            port_cursor = nextProbe(probe);
            break;
        } else |_| {}
        probe = nextProbe(probe);
    }
    if (bound == 0) {
        s.in_use = false;
        streams_mutex.unlock();
        logs.pushLog("error", "proxy", "No free port in 45678-45777", false);
        return null;
    }
    s.port = bound;

    const slot_u8: u8 = @intCast(idx);
    s.thread = std.Thread.spawn(.{}, acceptLoop, .{slot_u8}) catch {
        if (s.listener) |*l| l.deinit(io_g.io());
        s.listener = null;
        s.port = 0;
        s.in_use = false;
        streams_mutex.unlock();
        logs.pushLog("error", "proxy", "Failed to spawn proxy thread", false);
        return null;
    };

    const handle: Handle = .{
        .id = s.id,
        .slot = slot_u8,
        .port = s.port,
        .token = s.token,
    };

    streams_mutex.unlock();

    var msg_buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&msg_buf, "Stream proxy #{d} on :{d}", .{ handle.id, handle.port }) catch "Stream proxy started";
    logs.pushLog("info", "proxy", msg, false);
    return handle;
}

pub fn stopProxy(h: Handle) void {
    if (!h.isValid()) return;
    if (h.slot >= MAX_STREAMS) return;

    streams_mutex.lock();
    const s = &streams[h.slot];
    if (!s.in_use or s.id != h.id) {
        streams_mutex.unlock();
        return;
    }
    s.stop = true;
    const port = s.port;
    const thread = s.thread;
    streams_mutex.unlock();

    // Kick accept() awake by making one local connection.
    if (port > 0) {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
        if (addr.connect(io_g.io(), .{ .mode = .stream })) |conn| {
            var c2 = conn;
            c2.close(io_g.io());
        } else |_| {}
    }

    if (thread) |t| t.join();
    // acceptLoop has already reset the slot on exit.
}

pub fn stopAll() void {
    var i: usize = 0;
    while (i < MAX_STREAMS) : (i += 1) {
        streams_mutex.lock();
        const in_use = streams[i].in_use;
        const h: Handle = .{
            .id = streams[i].id,
            .slot = @intCast(i),
            .port = streams[i].port,
            .token = streams[i].token,
        };
        streams_mutex.unlock();
        if (in_use) stopProxy(h);
    }
}

pub fn getStreamUrl(h: Handle, buf: []u8) ?[]const u8 {
    if (!h.isValid()) return null;
    const token_slice: []const u8 = h.token[0..];
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/s/{s}", .{ h.port, token_slice }) catch null;
}

fn getMimeType(name: []const u8) []const u8 {
    if (name.len == 0) return "application/octet-stream";
    if (std.mem.endsWith(u8, name, ".mkv")) return "video/x-matroska";
    if (std.mem.endsWith(u8, name, ".mp4")) return "video/mp4";
    if (std.mem.endsWith(u8, name, ".avi")) return "video/x-msvideo";
    if (std.mem.endsWith(u8, name, ".mov")) return "video/quicktime";
    if (std.mem.endsWith(u8, name, ".wmv")) return "video/x-ms-wmv";
    if (std.mem.endsWith(u8, name, ".webm")) return "video/webm";
    if (std.mem.endsWith(u8, name, ".flv")) return "video/x-flv";
    if (std.mem.endsWith(u8, name, ".ts")) return "video/mp2t";
    if (std.mem.endsWith(u8, name, ".m4v")) return "video/mp4";
    return "application/octet-stream";
}

const ConnArgs = struct {
    slot: u8,
    stream_id: u32,
    conn: std.Io.net.Stream,
};

fn acceptLoop(slot: u8) void {
    // Each iteration accepts one connection and hands it off; we keep the
    // listener owned by this thread and tear it down when the slot stops.
    while (true) {
        streams_mutex.lock();
        const stop_now = streams[slot].stop or !streams[slot].in_use;
        streams_mutex.unlock();
        if (stop_now) break;

        var conn = streams[slot].listener.?.accept(io_g.io()) catch continue;

        streams_mutex.lock();
        const stop2 = streams[slot].stop;
        const id_now = streams[slot].id;
        streams_mutex.unlock();
        if (stop2) {
            conn.close(io_g.io());
            break;
        }

        const args = ConnArgs{ .slot = slot, .stream_id = id_now, .conn = conn };
        _ = std.Thread.spawn(.{}, handleConnectionThread, .{args}) catch {
            handleConnection(args) catch {};
            var c2 = conn;
            c2.close(io_g.io());
            continue;
        };
    }

    // Teardown: close listener, mark slot free.
    streams_mutex.lock();
    if (streams[slot].listener) |*l| l.deinit(io_g.io());
    streams[slot] = .{}; // reset to default (in_use=false)
    streams_mutex.unlock();
}

fn handleConnectionThread(args: ConnArgs) void {
    var conn = args.conn;
    defer conn.close(io_g.io());
    handleConnection(args) catch {};
}

fn writeStatus(stream: std.Io.net.Stream, status: []const u8) void {
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status}) catch return;
    _ = io_g.streamWriteAll(stream, line) catch {};
}

fn handleConnection(args: ConnArgs) !void {
    // Snapshot the stream config; if the slot has been recycled mid-request,
    // we'll detect via the stream_id check below and bail.
    streams_mutex.lock();
    const slot = args.slot;
    const expected_id = args.stream_id;
    const cur_id = streams[slot].id;
    const torrent_id = streams[slot].torrent_id;
    const file_idx = streams[slot].file_idx;
    const file_size = streams[slot].file_size;
    const token = streams[slot].token;
    const fname_buf = streams[slot].file_name;
    const fname_len = streams[slot].file_name_len;
    streams_mutex.unlock();

    if (cur_id != expected_id) return; // slot was reused

    var req_buf: [4096]u8 = undefined;
    const req_len = io_g.streamReadAll(args.conn, &req_buf) catch return;
    if (req_len < 14) return; // shorter than "GET /s/X HTTP/"
    const request = req_buf[0..req_len];

    const is_head = std.mem.startsWith(u8, request, "HEAD ");
    const is_get = std.mem.startsWith(u8, request, "GET ");
    if (!is_head and !is_get) {
        writeStatus(args.conn, "405 Method Not Allowed");
        return;
    }

    // Extract the path: skip method, take until SP.
    const method_end_opt = std.mem.indexOfScalar(u8, request, ' ');
    if (method_end_opt == null) return;
    const after_method = request[method_end_opt.? + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, after_method, ' ') orelse return;
    const path = after_method[0..sp2];

    // Path must be exactly "/s/<token>".
    const prefix = "/s/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        writeStatus(args.conn, "404 Not Found");
        return;
    }
    const path_token = path[prefix.len..];
    if (path_token.len != TOKEN_HEX_LEN) {
        writeStatus(args.conn, "403 Forbidden");
        return;
    }
    // Constant-time compare to avoid timing oracle on the token.
    var mismatch: u8 = 0;
    for (path_token, 0..) |ch, i| mismatch |= ch ^ token[i];
    if (mismatch != 0) {
        writeStatus(args.conn, "403 Forbidden");
        return;
    }

    // Parse Range header.
    var range_start: i64 = 0;
    var range_end: i64 = file_size - 1;
    var has_range = false;

    if (std.mem.indexOf(u8, request, "Range: bytes=")) |range_idx| {
        has_range = true;
        const range_line_start = range_idx + "Range: bytes=".len;
        var range_line_end = range_line_start;
        while (range_line_end < request.len and request[range_line_end] != '\r' and request[range_line_end] != '\n') : (range_line_end += 1) {}
        const range_str = request[range_line_start..range_line_end];

        if (std.mem.indexOf(u8, range_str, "-")) |dash_idx| {
            const start_str = range_str[0..dash_idx];
            range_start = std.fmt.parseInt(i64, start_str, 10) catch 0;
            if (dash_idx + 1 < range_str.len) {
                const end_str = range_str[dash_idx + 1 ..];
                if (end_str.len > 0) {
                    range_end = std.fmt.parseInt(i64, end_str, 10) catch (file_size - 1);
                }
            }
        }
    }

    if (range_start < 0) range_start = 0;
    if (range_end >= file_size) range_end = file_size - 1;
    if (range_start > range_end) {
        writeStatus(args.conn, "416 Range Not Satisfiable");
        return;
    }

    const content_length = range_end - range_start + 1;
    const mime = getMimeType(fname_buf[0..fname_len]);

    var hdr_buf: [512]u8 = undefined;
    const status_line = if (has_range) "206 Partial Content" else "200 OK";
    const hdr = std.fmt.bufPrint(&hdr_buf,
        "HTTP/1.1 {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Accept-Ranges: bytes\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n",
        // No CORS on purpose: mpv ignores it, and a wildcard would let any
        // local browser page fetch the user's private torrent stream.
        .{ status_line, mime, content_length },
    ) catch return;
    _ = io_g.streamWriteAll(args.conn, hdr) catch return;

    if (has_range) {
        var range_hdr: [128]u8 = undefined;
        const rh = std.fmt.bufPrint(&range_hdr, "Content-Range: bytes {d}-{d}/{d}\r\n", .{ range_start, range_end, file_size }) catch return;
        _ = io_g.streamWriteAll(args.conn, rh) catch return;
    }

    _ = io_g.streamWriteAll(args.conn, "\r\n") catch return;
    if (is_head) return;

    var offset: i64 = range_start;
    var data_buf: [CHUNK_SIZE]u8 = undefined;

    while (offset <= range_end) {
        // Re-check stop flag each chunk so stopProxy isn't blocked by a slow seek.
        streams_mutex.lock();
        const should_stop = streams[slot].stop or streams[slot].id != expected_id;
        streams_mutex.unlock();
        if (should_stop) break;

        const remaining: usize = @intCast(range_end - offset + 1);
        const want = @min(remaining, CHUNK_SIZE);
        const read = c.mpv.torrent_read_bytes(
            state.app.torrent_ses,
            torrent_id,
            file_idx,
            offset,
            @ptrCast(&data_buf),
            @intCast(want),
        );
        if (read <= 0) break;

        const read_u: usize = @intCast(read);
        io_g.streamWriteAll(args.conn, data_buf[0..read_u]) catch break;
        offset += read;
    }
}
