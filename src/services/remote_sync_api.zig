//! Web account lifecycle for watch-sync providers. Tokens are write-only: the
//! browser can replace or revoke them but never read stored credential bytes.

const std = @import("std");
const http = @import("remote_http.zig");
const anilist = @import("anilist.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, query: []const u8, body: []const u8) void {
    if (std.mem.eql(u8, method, "POST")) return mutate(stream, query, body);
    if (!http.requireMethod(stream, method, "GET")) return;
    var auth_buf: [256]u8 = undefined;
    const auth_url = anilist.authorizationUrl(&auth_buf);
    var out: [768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    writer.print("{{\"anilist\":{{\"connected\":{s},\"has_client_id\":{s},\"queued\":{d},\"authorize_url\":\"", .{
        if (anilist.enabled and anilist.access_token_len > 0) "true" else "false",
        if (anilist.client_id_len > 0) "true" else "false",
        anilist.pendingCount(),
    }) catch return;
    http.writeJsonString(&writer, auth_url);
    writer.writeAll("\"}}}") catch return;
    http.sendJson(stream, out[0..writer.end]);
}

fn mutate(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var provider_buf: [24]u8 = undefined;
    const provider = http.formParam(body, query, "provider", &provider_buf) orelse "";
    if (!std.mem.eql(u8, provider, "anilist")) {
        http.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown sync provider\"}");
        return;
    }
    var action_buf: [24]u8 = undefined;
    const action = http.formParam(body, query, "action", &action_buf) orelse "";
    if (std.mem.eql(u8, action, "disconnect")) {
        anilist.disconnect();
        http.sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, action, "retry")) {
        anilist.retryPending();
        http.sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (!std.mem.eql(u8, action, "set")) {
        http.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"action must be set, disconnect or retry\"}");
        return;
    }
    var key_buf: [24]u8 = undefined;
    var value_buf: [4096]u8 = undefined;
    const key = http.formParam(body, query, "key", &key_buf) orelse "";
    const value = http.formParam(body, query, "value", &value_buf) orelse "";
    const ok = if (std.mem.eql(u8, key, "client_id")) anilist.setClientId(value) else if (std.mem.eql(u8, key, "access_token")) anilist.setToken(value) else false;
    if (!ok) {
        http.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid sync account setting\"}");
        return;
    }
    http.sendJson(stream, "{\"ok\":true}");
}
