//! Background operator routes.
//!
//!   GET  /operator                 jobs, the switch, today's spend
//!   POST /operator/approve?id=     apply a proposed job (a person does this in the UI)
//!   POST /operator/reject?id=
//!
//! Host-admin only (see access_pure). Approve and reject are deliberately not
//! agent tools: proposals exist so that a person decides.

const std = @import("std");
const wire = @import("remote_http.zig");
const operator = @import("operator.zig");
const alloc = @import("../core/alloc.zig").allocator;

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/operator")) return false;
    if (std.mem.eql(u8, path, "/operator")) {
        if (wire.requireMethod(stream, method, "GET")) list(stream);
        return true;
    }
    inline for (.{ "approve", "reject" }) |verb| {
        if (std.mem.eql(u8, path, "/operator/" ++ verb)) {
            if (wire.requireMethod(stream, method, "POST")) decide(stream, query, body, verb);
            return true;
        }
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

fn decide(stream: std.Io.net.Stream, query: []const u8, body: []const u8, comptime verb: []const u8) void {
    var id_buf: [24]u8 = undefined;
    const id = std.fmt.parseInt(i64, wire.formParam(body, query, "id", &id_buf) orelse "", 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"id required\"}");
        return;
    };
    const result = if (comptime std.mem.eql(u8, verb, "approve")) operator.approve(id) else operator.reject(id);
    switch (result) {
        .ok => wire.sendJson(stream, "{\"ok\":true}"),
        .no_such_job => wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such job\"}"),
        .not_proposed => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"the job is not waiting for a decision\"}"),
        .failed => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"the proposal could not be applied\"}"),
        .unavailable => wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"database not ready\"}"),
    }
}
