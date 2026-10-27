//! Cross-device progress + favorites sync over the local API (ROADMAP 6.3).
//! Protocol v2 (library_sync_pure.PROTOCOL): cursors are the server's local
//! change sequence, rows carry no echo back to their sender.
//!
//!   GET  /api/library/sync?seq=<n>[&from=<device id>]
//!                                          rows with seq > n (paged), minus rows
//!                                          that came from `from`
//!   POST /api/library/sync                apply a peer's rows (JSON body; its
//!                                          `device` becomes their origin)
//!   POST /api/library/sync/pull           peer=<base url>&token=<peer bearer>[&since=N][&device=D]
//!                                          — this host pulls from a peer
//!   POST /api/library/sync/push           peer=..&token=..[&since=N][&device=D] — this host pushes to a peer
//!
//! A v1 request (`since=` without `seq=`) is refused with 400 rather than
//! served from a cursor space it would misread.
//!
//! All are host administration (machine token / admin session; see
//! `access_pure.routeCapability`). Wire format + merge rule: library_sync_pure.zig.

const std = @import("std");
const wire = @import("remote_http.zig");
const store = @import("library_store.zig");
const sync_pure = @import("library_sync_pure.zig");
const alloc = @import("../core/alloc.zig").allocator;

pub const RESPONSE_BYTES: usize = 256 * 1024;

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    if (std.mem.eql(u8, path, "/library/sync")) {
        if (std.mem.eql(u8, method, "GET")) {
            serve(stream, query);
        } else if (wire.requireMethod(stream, method, "POST")) {
            accept(stream, body);
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/library/sync/pull")) {
        if (wire.requireMethod(stream, method, "POST")) pullRoute(stream, query, body);
        return true;
    }
    if (std.mem.eql(u8, path, "/library/sync/push")) {
        if (wire.requireMethod(stream, method, "POST")) pushRoute(stream, query, body);
        return true;
    }
    return false;
}

fn serve(stream: std.Io.net.Stream, query: []const u8) void {
    const seq_raw = wire.queryParam(query, "seq") orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"sync protocol 2 required: pass seq=\",\"v\":2}");
        return;
    };
    const after = std.fmt.parseInt(i64, seq_raw, 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid seq\"}");
        return;
    };
    var from_buf: [64]u8 = undefined;
    const from_raw = if (wire.queryParam(query, "from")) |raw| (wire.urlDecode(raw, &from_buf) orelse "") else "";
    const from = if (sync_pure.validDeviceId(from_raw)) from_raw else "";

    const rows = alloc.alloc(sync_pure.SyncRow, sync_pure.PAGE_ROWS) catch return oom(stream);
    defer alloc.free(rows);
    const json = alloc.alloc(u8, RESPONSE_BYTES) catch return oom(stream);
    defer alloc.free(json);
    // Snapshot first: rows written while this page is read wait for the next.
    const snapshot = store.maxSeq();
    const n = store.loadChangedSince(after, snapshot, from, rows);
    const end = sync_pure.pageEnd(n, rows.len, if (n == 0) after else rows[n - 1].seq, snapshot);
    var dev_buf: [sync_pure.DEVICE_ID_MAX]u8 = undefined;
    var w = std.Io.Writer.fixed(json);
    sync_pure.encodePayload(&w, rows[0..n], end.next, end.has_more, store.deviceId(&dev_buf)) catch return oom(stream);
    wire.sendJson(stream, json[0..w.end]);
}

fn accept(stream: std.Io.net.Stream, body: []const u8) void {
    const rows = alloc.alloc(sync_pure.SyncRow, sync_pure.MAX_POST_ROWS) catch return oom(stream);
    defer alloc.free(rows);
    const decoded = sync_pure.decodePayload(alloc, body, rows) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid sync payload\"}");
        return;
    };
    const applied = store.applySyncRows(rows[0..decoded.count], decoded.deviceId());
    var dev_buf: [sync_pure.DEVICE_ID_MAX]u8 = undefined;
    var buf: [192]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"received\":{d},\"applied\":{d},\"rejected\":{d},\"device\":\"{s}\"}}", .{
        decoded.count, applied, decoded.rejected, store.deviceId(&dev_buf),
    }) catch return;
    wire.sendJson(stream, out);
}

const RouteArgs = struct {
    peer_buf: [512]u8 = undefined,
    token_buf: [256]u8 = undefined,
    since_buf: [24]u8 = undefined,
    device_buf: [64]u8 = undefined,
    peer: []const u8 = "",
    token: []const u8 = "",
    since: i64 = 0,
    device: []const u8 = "",

    fn parse(self: *RouteArgs, query: []const u8, body: []const u8) void {
        self.peer = wire.formParam(body, query, "peer", &self.peer_buf) orelse "";
        self.token = wire.formParam(body, query, "token", &self.token_buf) orelse "";
        self.since = @max(0, std.fmt.parseInt(i64, wire.formParam(body, query, "since", &self.since_buf) orelse "0", 10) catch 0);
        const dev = wire.formParam(body, query, "device", &self.device_buf) orelse "";
        self.device = if (sync_pure.validDeviceId(dev)) dev else "";
    }
};

fn pullRoute(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var a: RouteArgs = .{};
    a.parse(query, body);
    const res = @import("library_sync.zig").pull(a.peer, a.token, a.since, a.device) orelse {
        wire.sendJsonStatus(stream, "502 Bad Gateway", "{\"error\":\"peer sync failed\"}");
        return;
    };
    var buf: [256]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"received\":{d},\"applied\":{d},\"since\":{d},\"device\":\"{s}\",\"restarted\":{}}}", .{
        res.received, res.applied, res.cursor, res.deviceId(), res.restarted,
    }) catch return;
    wire.sendJson(stream, out);
}

fn pushRoute(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var a: RouteArgs = .{};
    a.parse(query, body);
    const res = @import("library_sync.zig").push(a.peer, a.token, a.since, a.device) orelse {
        wire.sendJsonStatus(stream, "502 Bad Gateway", "{\"error\":\"peer sync failed\"}");
        return;
    };
    var buf: [192]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"sent\":{d},\"applied\":{d},\"since\":{d}}}", .{ res.sent, res.applied, res.cursor }) catch return;
    wire.sendJson(stream, out);
}

fn oom(stream: std.Io.net.Stream) void {
    wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
}
