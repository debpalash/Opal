//! Web account lifecycle for watch-sync providers. Tokens are write-only: the
//! browser can replace or revoke them but never read stored credential bytes.

const std = @import("std");
const http = @import("remote_http.zig");
const anilist = @import("anilist.zig");
const simkl = @import("simkl.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, query: []const u8, body: []const u8) void {
    if (std.mem.eql(u8, method, "POST")) return mutate(stream, query, body);
    if (!http.requireMethod(stream, method, "GET")) return;
    var auth_buf: [256]u8 = undefined;
    const auth_url = anilist.authorizationUrl(&auth_buf);
    const anilist_state = anilist.snapshot();
    const simkl_state = simkl.snapshot();
    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    writer.print("{{\"anilist\":{{\"connected\":{s},\"has_client_id\":{s},\"queued\":{d},\"authorize_url\":\"", .{
        if (anilist_state.connected) "true" else "false",
        if (anilist_state.has_client_id) "true" else "false",
        anilist_state.queued,
    }) catch return;
    http.writeJsonString(&writer, auth_url);
    writer.print("\",\"needs_reauth\":{s}}},\"simkl\":{{\"connected\":{s},\"pending\":{s},\"needs_reauth\":{s},\"has_client_id\":{s},\"queued\":{d},\"user_code\":\"", .{
        if (anilist_state.needs_reauth) "true" else "false",
        if (simkl_state.connected) "true" else "false",
        if (simkl_state.pending) "true" else "false",
        if (simkl_state.needs_reauth) "true" else "false",
        if (simkl_state.has_client_id) "true" else "false",
        simkl_state.queued,
    }) catch return;
    http.writeJsonString(&writer, simkl_state.user_code[0..simkl_state.user_code_len]);
    writer.writeAll("\"}}}") catch return;
    http.sendJson(stream, out[0..writer.end]);
}

fn mutate(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var provider_buf: [24]u8 = undefined;
    const provider = http.formParam(body, query, "provider", &provider_buf) orelse "";
    var action_buf: [24]u8 = undefined;
    const action = http.formParam(body, query, "action", &action_buf) orelse "";
    if (std.mem.eql(u8, provider, "simkl")) return mutateSimkl(stream, action, query, body);
    if (!std.mem.eql(u8, provider, "anilist")) {
        http.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"unknown sync provider\"}");
        return;
    }
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

fn mutateSimkl(stream: std.Io.net.Stream, action: []const u8, query: []const u8, body: []const u8) void {
    if (std.mem.eql(u8, action, "connect")) {
        if (!simkl.startPinAuth()) {
            http.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"set a client ID first or authorization is already pending\"}");
            return;
        }
        http.sendJsonStatus(stream, "202 Accepted", "{\"ok\":true,\"pending\":true}");
        return;
    }
    if (std.mem.eql(u8, action, "disconnect")) {
        simkl.disconnect();
        http.sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, action, "retry")) {
        simkl.retryPending();
        http.sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, action, "set")) {
        var key_buf: [24]u8 = undefined;
        var value_buf: [256]u8 = undefined;
        const key = http.formParam(body, query, "key", &key_buf) orelse "";
        const value = http.formParam(body, query, "value", &value_buf) orelse "";
        if (std.mem.eql(u8, key, "client_id") and simkl.setClientId(value)) {
            http.sendJson(stream, "{\"ok\":true}");
            return;
        }
    }
    http.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid SIMKL action or setting\"}");
}
