//! Background operator routes.
//!
//!   GET  /operator                 jobs, the switch, today's spend
//! Host-admin only (see access_pure). There is deliberately NO HTTP route to approve
//! or reject a proposal: the machine token that opal-mcp and any agent with a shell
//! can read would then be enough to approve its own proposals. Decisions are made
//! in the desktop UI, which calls operator.approve / operator.reject in-process.

const std = @import("std");
const wire = @import("remote_http.zig");
const operator = @import("operator.zig");
const alloc = @import("../core/alloc.zig").allocator;

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    _ = query;
    _ = body;
    if (!std.mem.startsWith(u8, path, "/operator")) return false;
    if (std.mem.eql(u8, path, "/operator")) {
        if (wire.requireMethod(stream, method, "GET")) list(stream);
        return true;
    }
    return false;
}

fn list(stream: std.Io.net.Stream) void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    operator.writeListJson(&out.writer) catch {
        wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"operator unavailable\"}");
        return;
    };
    wire.sendJson(stream, out.written());
}
