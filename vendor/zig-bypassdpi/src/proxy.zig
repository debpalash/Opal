//! The proxy I/O layer: accept loop, SOCKS5 / HTTP CONNECT handshakes, and the
//! bidirectional splice. All of the byte-fiddling that can be tested in
//! isolation lives in `desync.zig` and `socks.zig`; this file only does the
//! socket work and routes its first-write fragmentation through
//! `desync.computeSplits`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.Io.net;
const Io = std.Io;
const desync = @import("desync.zig");
const socks = @import("socks.zig");

const Handle = net.Socket.Handle;

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8881,
    mode: desync.Mode = .sni,
    verbose: bool = false,
};

var g_cfg: Config = .{};

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}
fn vlog(comptime fmt: []const u8, args: anytype) void {
    if (g_cfg.verbose) std.debug.print(fmt ++ "\n", args);
}

// ---------------------------------------------------------------------------
// Raw socket helpers (single read / whole-buffer write) over the Io vtable.
// Each `writeAll` fragment is one or more send() syscalls; separate calls
// produce separate TCP segments once TCP_NODELAY is set.
// ---------------------------------------------------------------------------

fn readSome(io: Io, h: Handle, buf: []u8) !usize {
    var v = [_][]u8{buf};
    const result = try (try io.operate(.{ .net_read = .{ .socket_handle = h, .data = &v } })).net_read;
    return result.data_len;
}

fn writeAll(io: Io, h: Handle, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    var off: usize = 0;
    // A single empty "pattern" buffer with splat 0 makes netWrite emit only the
    // header (`bytes`), avoiding an out-of-bounds on an empty `data` slice.
    const patt = [_][]const u8{&.{}};
    while (off < bytes.len) {
        const n = try (try io.operate(.{ .net_write = .{ .socket_handle = h, .header = bytes[off..], .data = &patt, .splat = 0 } })).net_write;
        if (n == 0) return error.WriteZero;
        off += n;
    }
}

fn closeHandle(io: Io, h: Handle) void {
    const socket: net.Socket = .{ .handle = h, .address = net.IpAddress.parse("0.0.0.0", 0) catch unreachable };
    socket.close(io);
}

fn shutdownBoth(io: Io, a: Handle, b: Handle) void {
    io.vtable.netShutdown(io.userdata, a, .both) catch {};
    io.vtable.netShutdown(io.userdata, b, .both) catch {};
}

fn setNoDelay(h: Handle) void {
    // Not available through std.posix on Windows (it @compileErrors); skip there.
    if (builtin.os.tag == .windows) return;
    const one: c_int = 1;
    posix.setsockopt(
        h,
        @as(i32, posix.IPPROTO.TCP),
        @as(u32, posix.TCP.NODELAY),
        std.mem.asBytes(&one),
    ) catch {};
}

// ---------------------------------------------------------------------------
// Address resolution: IP literal fast-path, otherwise a real DNS lookup.
// ---------------------------------------------------------------------------

fn resolveHost(io: Io, host: []const u8, port: u16) !net.IpAddress {
    if (net.IpAddress.parse(host, port)) |ip| return ip else |_| {}

    const hn = net.HostName.init(host) catch return error.BadHostName;
    var qbuf: [16]net.HostName.LookupResult = undefined;
    var q = Io.Queue(net.HostName.LookupResult).init(&qbuf);
    try hn.lookup(io, &q, .{ .port = port });

    var first: ?net.IpAddress = null;
    while (true) {
        const item = q.getOne(io) catch break; // Closed -> done draining
        switch (item) {
            .address => |a| {
                if (first == null) first = a;
                // Prefer IPv4 for the widest local reachability.
                if (a == .ip4) return a;
            },
            .canonical_name => {},
        }
    }
    return first orelse error.UnknownHostName;
}

fn connectUpstream(io: Io, host: []const u8, port: u16) !Handle {
    var addr = try resolveHost(io, host, port);
    addr.setPort(port);
    const stream = try net.IpAddress.connect(&addr, io, .{ .mode = .stream, .protocol = .tcp });
    setNoDelay(stream.socket.handle);
    return stream.socket.handle;
}

// ---------------------------------------------------------------------------
// The desynced first write + the bidirectional splice.
// ---------------------------------------------------------------------------

const Pair = struct {
    io: Io,
    client: Handle,
    upstream: Handle,
};

/// Copy `upstream` -> `client` until EOF/error, then tear down both ends.
fn pumpReverse(p: *Pair) void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = readSome(p.io, p.upstream, &buf) catch break;
        if (n == 0) break;
        writeAll(p.io, p.client, buf[0..n]) catch break;
    }
    shutdownBoth(p.io, p.client, p.upstream);
}

/// Write the ClientHello split into segments per `mode`.
fn writeSegmented(io: Io, h: Handle, hello: []const u8, mode: desync.Mode) !void {
    const splits = desync.computeSplits(hello, mode);
    var prev: usize = 0;
    for (splits.slice()) |off| {
        try writeAll(io, h, hello[prev..off]);
        prev = off;
    }
    try writeAll(io, h, hello[prev..]);
}

/// Copy `client` -> `upstream`, fragmenting the first TLS ClientHello to a
/// :443 target. Runs on the connection's own thread.
fn pumpForward(p: *Pair, port: u16) void {
    var buf: [16 * 1024]u8 = undefined;
    var first = true;
    while (true) {
        const n = readSome(p.io, p.client, &buf) catch break;
        if (n == 0) break;
        const data = buf[0..n];
        if (first) {
            first = false;
            if (port == 443 and desync.looksLikeTlsClientHello(data)) {
                vlog("[desync] fragmenting ClientHello ({d} bytes) mode={s}", .{ data.len, modeName(g_cfg.mode) });
                writeSegmented(p.io, p.upstream, data, g_cfg.mode) catch break;
                continue;
            }
        }
        writeAll(p.io, p.upstream, data) catch break;
    }
    shutdownBoth(p.io, p.client, p.upstream);
}

fn splice(io: Io, client: Handle, upstream: Handle, port: u16) void {
    var pair: Pair = .{ .io = io, .client = client, .upstream = upstream };
    const t = std.Thread.spawn(.{}, pumpReverse, .{&pair}) catch {
        // Could not spawn: fall back to single-direction (client->upstream) only.
        pumpForward(&pair, port);
        return;
    };
    pumpForward(&pair, port);
    t.join();
}

// ---------------------------------------------------------------------------
// Handshakes
// ---------------------------------------------------------------------------

const HandshakeError = error{ Eof, Overflow, Protocol };

/// Append one read into `buf` past `len`. Grows `len`. Errors on peer close or
/// a full buffer.
fn readMore(io: Io, h: Handle, buf: []u8, len: *usize) HandshakeError!void {
    if (len.* >= buf.len) return error.Overflow;
    const n = readSome(io, h, buf[len.*..]) catch return error.Eof;
    if (n == 0) return error.Eof;
    len.* += n;
}

/// SOCKS5 (RFC 1928), no authentication, CONNECT only. `seed`/`seed_len` are the
/// bytes already read while sniffing the protocol.
fn handleSocks5(io: Io, client: Handle, seed: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var len: usize = seed.len;
    @memcpy(buf[0..seed.len], seed);

    // greeting: VER NMETHODS METHODS...
    while (len < 2) try readMore(io, client, &buf, &len);
    if (buf[0] != 0x05) return error.Protocol;
    const nmethods = buf[1];
    while (len < 2 + @as(usize, nmethods)) try readMore(io, client, &buf, &len);

    // method selection: no authentication (0x00)
    try writeAll(io, client, &[_]u8{ 0x05, 0x00 });

    // The request may have arrived pipelined after the greeting.
    const consumed = 2 + @as(usize, nmethods);
    var req: [1024]u8 = undefined;
    var rlen: usize = len - consumed;
    @memcpy(req[0..rlen], buf[consumed..len]);

    const target = while (true) {
        if (socks.parseSocks5Request(req[0..rlen])) |t| {
            break t;
        } else |e| switch (e) {
            error.Truncated => try readMore(io, client, &req, &rlen),
            else => {
                // reply: general failure
                try writeAll(io, client, &[_]u8{ 0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
                return error.Protocol;
            },
        }
    };

    const upstream = connectUpstream(io, target.host(), target.port) catch {
        // reply: host unreachable
        try writeAll(io, client, &[_]u8{ 0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
        return error.Protocol;
    };
    errdefer closeHandle(io, upstream);

    // reply: succeeded, BND.ADDR 0.0.0.0:0
    try writeAll(io, client, &[_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });

    vlog("[socks5] {s}:{d} -> connected", .{ target.host(), target.port });
    splice(io, client, upstream, target.port);
    closeHandle(io, upstream);
}

/// HTTP CONNECT tunnel.
fn handleHttpConnect(io: Io, client: Handle, seed: []const u8) !void {
    var buf: [8192]u8 = undefined;
    var len: usize = seed.len;
    @memcpy(buf[0..seed.len], seed);

    while (std.mem.indexOfScalar(u8, buf[0..len], '\n') == null)
        try readMore(io, client, &buf, &len);

    const target = socks.parseHttpConnect(buf[0..len]) catch {
        try writeAll(io, client, "HTTP/1.1 400 Bad Request\r\n\r\n");
        return error.Protocol;
    };

    const upstream = connectUpstream(io, target.host(), target.port) catch {
        try writeAll(io, client, "HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return error.Protocol;
    };
    errdefer closeHandle(io, upstream);

    try writeAll(io, client, "HTTP/1.1 200 Connection Established\r\n\r\n");

    vlog("[http] {s}:{d} -> connected", .{ target.host(), target.port });
    splice(io, client, upstream, target.port);
    closeHandle(io, upstream);
}

// ---------------------------------------------------------------------------
// Per-connection entry + accept loop
// ---------------------------------------------------------------------------

const Conn = struct {
    io: Io,
    client: Handle,
};

fn serve(conn: *Conn) void {
    const io = conn.io;
    const client = conn.client;
    std.heap.page_allocator.destroy(conn);
    defer closeHandle(io, client);

    // Sniff the first byte to pick the protocol: 0x05 => SOCKS5, else HTTP.
    var seed: [4096]u8 = undefined;
    const n = readSome(io, client, &seed) catch return;
    if (n == 0) return;

    if (seed[0] == 0x05) {
        handleSocks5(io, client, seed[0..n]) catch {};
    } else {
        handleHttpConnect(io, client, seed[0..n]) catch {};
    }
}

pub fn run(io: Io, cfg: Config) !void {
    g_cfg = cfg;

    var addr = net.IpAddress.parse(cfg.host, cfg.port) catch {
        log("error: --listen must be an IP literal (got \"{s}\")", .{cfg.host});
        return error.BadListenAddress;
    };
    addr.setPort(cfg.port);

    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        log("error: cannot listen on {s}:{d}: {s}", .{ cfg.host, cfg.port, @errorName(e) });
        return e;
    };
    defer server.deinit(io);

    log("zig-bypassdpi listening on {s}:{d}  (mode={s})", .{ cfg.host, cfg.port, modeName(cfg.mode) });
    log("  SOCKS5:  curl --socks5-hostname {s}:{d} https://example.com", .{ cfg.host, cfg.port });
    log("  HTTP:    curl -x http://{s}:{d} https://example.com", .{ cfg.host, cfg.port });

    while (true) {
        const stream = server.accept(io) catch |e| {
            switch (e) {
                error.ConnectionAborted, error.WouldBlock => continue,
                else => {
                    log("accept error: {s}", .{@errorName(e)});
                    return e;
                },
            }
        };
        const conn = std.heap.page_allocator.create(Conn) catch {
            closeHandle(io, stream.socket.handle);
            continue;
        };
        conn.* = .{ .io = io, .client = stream.socket.handle };
        const t = std.Thread.spawn(.{}, serve, .{conn}) catch {
            closeHandle(io, conn.client);
            std.heap.page_allocator.destroy(conn);
            continue;
        };
        t.detach();
    }
}

pub fn modeName(m: desync.Mode) []const u8 {
    return switch (m) {
        .split => "split",
        .sni => "sni",
    };
}
