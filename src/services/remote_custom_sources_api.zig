//! Typed CRUD for user-selected manga and novel framework endpoints.
const std = @import("std");
const wire = @import("remote_http.zig");
const config = @import("../core/source_config.zig");

const frameworks = [_][]const u8{ "madara", "mangathemesia", "heancms", "madara_novel", "lightnovelwp", "readwn" };

pub fn handle(stream: std.Io.net.Stream, method: []const u8, query: []const u8, body: []const u8) void {
    if (std.mem.eql(u8, method, "GET")) return list(stream);
    if (!wire.requireMethod(stream, method, "POST")) return;
    var action_buf: [16]u8 = undefined;
    var framework_buf: [32]u8 = undefined;
    const action = param(body, query, "action", &action_buf) orelse "";
    const framework = param(body, query, "framework", &framework_buf) orelse "";
    if (!validFramework(framework)) return wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unsupported source framework\"}");
    if (std.mem.eql(u8, action, "remove")) {
        config.uninstallById(framework);
        return wire.sendJson(stream, "{\"ok\":true}");
    }
    if (!std.mem.eql(u8, action, "save")) return wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"action must be save or remove\"}");
    var base_buf: [512]u8 = undefined;
    const base = param(body, query, "base", &base_buf) orelse "";
    if (!validBase(base)) return wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"valid http(s) source URL required\"}");
    var payload_buf: [640]u8 = undefined;
    var w = std.Io.Writer.fixed(&payload_buf);
    w.writeAll("{\"base\":\"") catch return;
    wire.writeJsonString(&w, std.mem.trimEnd(u8, base, "/"));
    w.writeAll("\"}") catch return;
    if (!config.install(framework, payload_buf[0..w.end])) return wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"source could not be saved\"}");
    wire.sendJson(stream, "{\"ok\":true}");
}

fn param(body: []const u8, query: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    return wire.urlDecode(wire.queryParam(body, key) orelse wire.queryParam(query, key) orelse return null, out);
}

fn validFramework(value: []const u8) bool {
    for (frameworks) |allowed| if (std.mem.eql(u8, value, allowed)) return true;
    return false;
}

fn validBase(value: []const u8) bool {
    if (value.len < 9 or value.len > 500) return false;
    if (!std.mem.startsWith(u8, value, "http://") and !std.mem.startsWith(u8, value, "https://")) return false;
    for (value) |ch| if (ch < 0x20) return false;
    return true;
}

fn list(stream: std.Io.net.Stream) void {
    var out: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    w.writeAll("{\"sources\":[") catch return;
    for (frameworks, 0..) |framework, index| {
        if (index > 0) w.writeByte(',') catch return;
        w.print("{{\"framework\":\"{s}\",\"base\":\"", .{framework}) catch return;
        wire.writeJsonString(&w, config.get(framework, "base") orelse "");
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
    wire.sendJson(stream, out[0..w.end]);
}

test "custom source boundary validates frameworks and URLs" {
    try std.testing.expect(validFramework("madara"));
    try std.testing.expect(!validFramework("../../other"));
    try std.testing.expect(validBase("https://reader.example"));
    try std.testing.expect(!validBase("file:///etc/passwd"));
}
