//! LAN media listener for casting local files. A Chromecast or DLNA TV must
//! fetch the media over HTTP from this machine, but the web UI / API listener
//! binds loopback by default. This second listener binds every interface on
//! an ephemeral port and serves exactly one route family: signed stream
//! session paths, `/api/stream/<sid>/<token>/<name>`, verified by
//! stream_session.handlePublic (HMAC token per session, dies with the
//! process). Everything else gets 404, so it is not a second door into the
//! API. Started on the first local-file cast.

const std = @import("std");
const io_g = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const workers = @import("../core/workers.zig");
const wire = @import("remote_http.zig");
const pure = @import("cast_pure.zig");

const MAX_CONNECTIONS = 8;

var port: std.atomic.Value(u16) = std.atomic.Value(u16).init(0);
var starting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// The listening port, starting the listener on first use. 0 when it could
/// not bind.
pub fn ensure() u16 {
    const p = port.load(.acquire);
    if (p != 0) return p;
    if (starting.swap(true, .acq_rel)) {
        // Another caller is binding: wait briefly for it.
        var waited: usize = 0;
        while (port.load(.acquire) == 0 and starting.load(.acquire) and waited < 50) : (waited += 1)
            io_g.sleep(20 * std.time.ns_per_ms);
        return port.load(.acquire);
    }
    defer starting.store(false, .release);
    const addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch return 0;
    const server = addr.listen(io_g.io(), .{}) catch {
        logs.pushLog("error", "cast", "Could not open the cast media port", true);
        return 0;
    };
    const bound = server.socket.address.getPort();
    const t = workers.spawnLegacy(acceptLoop, .{server}) catch {
        var s = server;
        s.deinit(io_g.io());
        return 0;
    };
    workers.release(t);
    port.store(bound, .release);
    var msg: [64]u8 = undefined;
    logs.pushLog("info", "cast", std.fmt.bufPrint(&msg, "cast media listener on port {d}", .{bound}) catch "cast media listener up", false);
    return bound;
}

fn acceptLoop(server_in: std.Io.net.Server) void {
    var server = server_in;
    defer server.deinit(io_g.io());
    while (!workers.isQuitting()) {
        const conn = server.accept(io_g.io()) catch continue;
        if (connections.fetchAdd(1, .acq_rel) >= MAX_CONNECTIONS) {
            _ = connections.fetchSub(1, .acq_rel);
            io_g.streamWriteAll(conn, "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n") catch {};
            conn.close(io_g.io());
            continue;
        }
        if (workers.spawnLegacy(handle, .{conn})) |t| workers.release(t) else |_| {
            _ = connections.fetchSub(1, .acq_rel);
            conn.close(io_g.io());
        }
    }
}

fn handle(conn: std.Io.net.Stream) void {
    defer _ = connections.fetchSub(1, .acq_rel);
    defer conn.close(io_g.io());
    var buf: [4096]u8 = undefined;
    const request = (wire.readRequest(conn, &buf) catch return) orelse return;
    const eol = std.mem.indexOfScalar(u8, request, '\n') orelse return;
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, request[0..eol], "\r"), ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const read_only = std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD");
    if (!read_only or !pure.castServePath(path) or
        !@import("stream_session.zig").handlePublic(conn, method, path, request))
    {
        io_g.streamWriteAll(conn, "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n") catch {};
    }
}
