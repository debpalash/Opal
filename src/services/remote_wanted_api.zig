//! Wanted-list routes: the list the app searches for and downloads on its own.
//!
//!   GET  /wanted                               the items and whether a check is running
//!   POST /wanted/add?kind=movie|episode&title=&year=&season=&episode=&min_quality=&prefer_quality=&max_quality=
//!   POST /wanted/pause?id=   POST /wanted/resume?id=   POST /wanted/remove?id=&confirm=1
//!   POST /wanted/follow?enabled=0|1            queue each tracked show's newest aired episode
//!   POST /wanted/check?id=                     search now, ignoring the retry backoff
//!
//! Qualities are 1 (480p) to 4 (2160p). The public `handle` is the only seam the
//! top-level router needs.

const std = @import("std");
const wire = @import("remote_http.zig");
const wanted = @import("wanted.zig");
const pure = @import("wanted_pure.zig");
const alloc = @import("../core/alloc.zig").allocator;

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/wanted")) return false;
    if (std.mem.eql(u8, path, "/wanted")) {
        if (wire.requireMethod(stream, method, "GET")) list(stream);
        return true;
    }
    if (std.mem.eql(u8, path, "/wanted/add")) {
        if (wire.requireMethod(stream, method, "POST")) add(stream, query);
        return true;
    }
    if (std.mem.eql(u8, path, "/wanted/follow")) {
        if (wire.requireMethod(stream, method, "POST")) follow(stream, query);
        return true;
    }
    inline for (.{ "pause", "resume", "remove", "check" }) |verb| {
        if (std.mem.eql(u8, path, "/wanted/" ++ verb)) {
            if (wire.requireMethod(stream, method, "POST")) byId(stream, query, verb);
            return true;
        }
    }
    return false;
}

fn list(stream: std.Io.net.Stream) void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    wanted.writeListJson(&out.writer) catch {
        wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"wanted list unavailable\"}");
        return;
    };
    wire.sendJson(stream, out.written());
}

fn uintParam(query: []const u8, key: []const u8, comptime T: type, default: T) ?T {
    const raw = wire.queryParam(query, key) orelse return default;
    return std.fmt.parseInt(T, raw, 10) catch null;
}

fn add(stream: std.Io.net.Stream, query: []const u8) void {
    var kind_buf: [16]u8 = undefined;
    const kind_raw = if (wire.queryParam(query, "kind")) |r| (wire.urlDecode(r, &kind_buf) orelse "") else "movie";
    const kind = pure.Kind.parse(kind_raw) orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"kind must be movie or episode\"}");
        return;
    };
    var title_buf: [256]u8 = undefined;
    const title = if (wire.queryParam(query, "title")) |r| (wire.urlDecode(r, &title_buf) orelse "") else "";

    const req = wanted.AddRequest{
        .kind = kind,
        .title = title,
        .year = uintParam(query, "year", u16, 0) orelse return bad(stream),
        .season = uintParam(query, "season", u16, 0) orelse return bad(stream),
        .episode = uintParam(query, "episode", u16, 0) orelse return bad(stream),
        .min_quality = uintParam(query, "min_quality", u8, 2) orelse return bad(stream),
        .prefer_quality = uintParam(query, "prefer_quality", u8, 3) orelse return bad(stream),
        .max_quality = uintParam(query, "max_quality", u8, 4) orelse return bad(stream),
    };
    var buf: [192]u8 = undefined;
    switch (wanted.add(req)) {
        .added => |id| wire.sendJson(stream, std.fmt.bufPrint(&buf, "{{\"ok\":true,\"id\":{d}}}", .{id}) catch "{\"ok\":true}"),
        .exists => |id| wire.sendJsonStatus(stream, "409 Conflict", std.fmt.bufPrint(&buf, "{{\"error\":\"already on the wanted list\",\"id\":{d}}}", .{id}) catch "{\"error\":\"exists\"}"),
        .invalid => |why| {
            var w = std.Io.Writer.fixed(&buf);
            w.writeAll("{\"error\":") catch {};
            var s = std.json.Stringify{ .writer = &w };
            s.write(why) catch {};
            w.writeAll("}") catch {};
            wire.sendJsonStatus(stream, "400 Bad Request", w.buffered());
        },
        .full => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"wanted list is full\"}"),
        .unavailable => wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"database not ready\"}"),
    }
}

fn follow(stream: std.Io.net.Stream, query: []const u8) void {
    const raw = wire.queryParam(query, "enabled") orelse "";
    const on = std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true");
    if (!on and !std.mem.eql(u8, raw, "0") and !std.mem.eql(u8, raw, "false")) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"enabled must be 0 or 1\"}");
        return;
    }
    wanted.setFollowTv(on);
    wire.sendJson(stream, if (on) "{\"ok\":true,\"follow_tv\":true}" else "{\"ok\":true,\"follow_tv\":false}");
}

fn bad(stream: std.Io.net.Stream) void {
    wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid number\"}");
}

fn byId(stream: std.Io.net.Stream, query: []const u8, comptime verb: []const u8) void {
    const id = std.fmt.parseInt(i64, wire.queryParam(query, "id") orelse "", 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"id required\"}");
        return;
    };
    // Removing deletes the user's standing request: like every destructive route it needs an explicit confirm.
    if (comptime std.mem.eql(u8, verb, "remove")) {
        if (!std.mem.eql(u8, wire.queryParam(query, "confirm") orelse "", "1")) {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"removing a wanted item needs confirm=1\"}");
            return;
        }
    }
    const ok = if (comptime std.mem.eql(u8, verb, "pause"))
        wanted.pause(id)
    else if (comptime std.mem.eql(u8, verb, "resume"))
        wanted.resume_(id)
    else if (comptime std.mem.eql(u8, verb, "remove"))
        wanted.remove(id)
    else
        wanted.checkNow(id);
    if (ok) {
        wire.sendJson(stream, "{\"ok\":true}");
    } else {
        wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such item, or it is not in a state that allows this\"}");
    }
}
