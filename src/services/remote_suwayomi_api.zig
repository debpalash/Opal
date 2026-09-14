//! Complete web lifecycle for embedded or external Suwayomi servers.
const std = @import("std");
const wire = @import("remote_http.zig");
const source_config = @import("../core/source_config.zig");
const server = @import("suwayomi_server.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, query: []const u8, body: []const u8) void {
    if (std.mem.eql(u8, method, "GET")) return status(stream);
    if (!wire.requireMethod(stream, method, "POST")) return;
    var action_buf: [32]u8 = undefined;
    const action = param(body, query, "action", &action_buf) orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"action required\"}");
        return;
    };
    if (std.mem.eql(u8, action, "start")) server.startEmbedded() else if (std.mem.eql(u8, action, "stop")) server.stopEmbedded() else if (std.mem.eql(u8, action, "disconnect")) {
        server.stopEmbedded();
        source_config.uninstallById("suwayomi");
    } else if (std.mem.eql(u8, action, "save")) {
        var base_buf: [512]u8 = undefined;
        const base = param(body, query, "base", &base_buf) orelse "";
        if (!validBase(base) or !saveBase(base)) {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"enter a valid http(s) Suwayomi URL\"}");
            return;
        }
    } else {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown Suwayomi action\"}");
        return;
    }
    wire.sendJson(stream, "{\"ok\":true}");
}

fn param(body: []const u8, query: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    return wire.urlDecode(wire.queryParam(body, key) orelse wire.queryParam(query, key) orelse return null, out);
}

fn validBase(raw: []const u8) bool {
    const base = std.mem.trim(u8, raw, " \t\r\n");
    if (base.len < 10 or base.len > 500) return false;
    if (!std.mem.startsWith(u8, base, "http://") and !std.mem.startsWith(u8, base, "https://")) return false;
    for (base) |ch| if (ch < 0x20 or ch == '"' or ch == '\\') return false;
    return true;
}

fn saveBase(raw: []const u8) bool {
    const base = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t\r\n"), "/");
    const source = source_config.get("suwayomi", "source") orelse "";
    var body: [640]u8 = undefined;
    const payload = std.fmt.bufPrint(&body, "{{\"base\":\"{s}\",\"source\":\"{s}\"}}", .{ base, source }) catch return false;
    return source_config.install("suwayomi", payload);
}

fn status(stream: std.Io.net.Stream) void {
    const base = source_config.get("suwayomi", "base") orelse "";
    var out: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    w.print("{{\"running\":{s},\"configured\":{s},\"status\":\"", .{
        if (server.isRunning()) "true" else "false",
        if (base.len > 0) "true" else "false",
    }) catch return;
    wire.writeJsonString(&w, server.statusText());
    w.writeAll("\",\"base\":\"") catch return;
    wire.writeJsonString(&w, base);
    w.writeAll("\"}") catch return;
    wire.sendJson(stream, out[0..w.end]);
}

test "Suwayomi external endpoints are explicitly http(s)" {
    try std.testing.expect(validBase("http://localhost:4567"));
    try std.testing.expect(validBase("https://manga.example.test/server"));
    try std.testing.expect(!validBase("file:///tmp/server"));
    try std.testing.expect(!validBase("https://bad.example/\"oops"));
}
