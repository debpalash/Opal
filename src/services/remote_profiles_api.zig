//! Household profiles over the JSON API (ROADMAP 7.3).
//!
//!   GET  /api/profiles            names, colours, kid flag, has_pin, which one
//!                                 runs — never a PIN hash. Any signed-in caller.
//!   POST /api/profiles/switch     id=<id>[&pin=<pin>] — verify the PIN policy
//!                                 (with backoff), then restart into it.
//!   POST /api/profiles/create     name=..[&kid=1][&color=..][&pin=..]
//!   POST /api/profiles/delete     id=<id> (never the default or the running one)
//!
//! The POST routes are host administration (machine token / admin session;
//! access_pure.routeCapability). Rules live in profiles_pure.zig.

const std = @import("std");
const wire = @import("remote_http.zig");
const profiles = @import("profiles.zig");
const pure = @import("profiles_pure.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    if (std.mem.eql(u8, path, "/profiles")) {
        if (wire.requireMethod(stream, method, "GET")) list(stream);
        return true;
    }
    if (std.mem.eql(u8, path, "/profiles/switch")) {
        if (wire.requireMethod(stream, method, "POST")) switchRoute(stream, query, body);
        return true;
    }
    if (std.mem.eql(u8, path, "/profiles/create")) {
        if (wire.requireMethod(stream, method, "POST")) createRoute(stream, query, body);
        return true;
    }
    if (std.mem.eql(u8, path, "/profiles/delete")) {
        if (wire.requireMethod(stream, method, "POST")) deleteRoute(stream, query, body);
        return true;
    }
    return false;
}

fn list(stream: std.Io.net.Stream) void {
    var items: [pure.MAX_PROFILES]pure.Profile = undefined;
    const n = profiles.snapshot(&items);
    const running = profiles.runningProfile();
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    pure.writePublicProfiles(&w, running.idText(), items[0..n]) catch return;
    wire.sendJson(stream, w.buffered());
}

fn editStatus(e: profiles.EditError) struct { status: []const u8, body: []const u8 } {
    return switch (e) {
        error.Forbidden => .{ .status = "403 Forbidden", .body = "{\"error\":\"forbidden\"}" },
        error.NotFound => .{ .status = "404 Not Found", .body = "{\"error\":\"no such profile\"}" },
        error.NameEmpty, error.NameTooLong, error.NameBadCharacter => .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid name\"}" },
        error.NameTaken => .{ .status = "409 Conflict", .body = "{\"error\":\"name taken\"}" },
        error.BadPin => .{ .status = "400 Bad Request", .body = "{\"error\":\"pin must be 4-8 digits\"}" },
        error.Full => .{ .status = "409 Conflict", .body = "{\"error\":\"profile limit reached\"}" },
        error.Default => .{ .status = "409 Conflict", .body = "{\"error\":\"the default profile cannot be removed\"}" },
        error.Running => .{ .status = "409 Conflict", .body = "{\"error\":\"switch away from this profile first\"}" },
        error.Storage => .{ .status = "500 Internal Server Error", .body = "{\"error\":\"could not save profiles\"}" },
    };
}

fn switchRoute(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var id_buf: [64]u8 = undefined;
    var pin_buf: [32]u8 = undefined;
    const id = wire.formParam(body, query, "id", &id_buf) orelse "";
    const pin = wire.formParam(body, query, "pin", &pin_buf) orelse "";
    if (!pure.validId(id)) return wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid id\"}");
    switch (profiles.requestSwitch(id, pin)) {
        .switching => wire.sendJson(stream, "{\"ok\":true,\"restarting\":true}"),
        .same => wire.sendJson(stream, "{\"ok\":true,\"restarting\":false}"),
        .not_found => wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such profile\"}"),
        .pin_required => |src| wire.sendJsonStatus(stream, "401 Unauthorized", if (src == .owner) "{\"error\":\"pin required\",\"pin_of\":\"owner\"}" else "{\"error\":\"pin required\",\"pin_of\":\"profile\"}"),
        .bad_pin => wire.sendJsonStatus(stream, "401 Unauthorized", "{\"error\":\"wrong pin\"}"),
        .locked_ms => |ms| {
            var b: [96]u8 = undefined;
            const secs = @divTrunc(ms + 999, 1000);
            wire.sendRateLimited(stream, secs, std.fmt.bufPrint(&b, "{{\"error\":\"too many attempts\",\"retry_after\":{d}}}", .{secs}) catch "{\"error\":\"too many attempts\"}");
        },
        .storage => wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"could not save profiles\"}"),
    }
}

fn createRoute(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var name_buf: [128]u8 = undefined;
    var kid_buf: [8]u8 = undefined;
    var color_buf: [16]u8 = undefined;
    var pin_buf: [32]u8 = undefined;
    const name = wire.formParam(body, query, "name", &name_buf) orelse "";
    const kid = std.mem.eql(u8, wire.formParam(body, query, "kid", &kid_buf) orelse "0", "1");
    const color = pure.parseColor(wire.formParam(body, query, "color", &color_buf) orelse "") orelse .accent;
    const pin = wire.formParam(body, query, "pin", &pin_buf) orelse "";
    const id = profiles.create(.admin_api, name, color, kid, pin) catch |e| {
        const r = editStatus(e);
        return wire.sendJsonStatus(stream, r.status, r.body);
    };
    var out: [96]u8 = undefined;
    wire.sendJson(stream, std.fmt.bufPrint(&out, "{{\"ok\":true,\"id\":\"{s}\"}}", .{&id}) catch "{\"ok\":true}");
}

fn deleteRoute(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var id_buf: [64]u8 = undefined;
    const id = wire.formParam(body, query, "id", &id_buf) orelse "";
    if (!pure.validId(id)) return wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid id\"}");
    profiles.delete(.admin_api, id) catch |e| {
        const r = editStatus(e);
        return wire.sendJsonStatus(stream, r.status, r.body);
    };
    wire.sendJson(stream, "{\"ok\":true}");
}
