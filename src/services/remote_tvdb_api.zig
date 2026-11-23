//! POST /api/setup/tvdb — store the user's TheTVDB v4 key (host
//! administration; access_pure host_routes). The key arrives in the POST body
//! only, never a URL, and is never echoed or logged.

const std = @import("std");
const state = @import("../core/state.zig");
const wire = @import("remote_http.zig");

pub fn handleSetup(stream: std.Io.net.Stream, method: []const u8, body: []const u8) void {
    if (!wire.requireMethod(stream, method, "POST")) return;
    var dec: [400]u8 = undefined;
    const key = @import("remote.zig").credParam(body, "", "key", &dec) orelse
        return wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"missing TheTVDB key\"}");
    const trimmed = std.mem.trim(u8, key, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > state.app.tvdb_api_key.len)
        return wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid TheTVDB key length\"}");
    state.setTvdbKey(trimmed);
    @memset(&dec, 0);
    @import("tvdb.zig").forgetToken();
    state.markConfigDirty();
    wire.sendJson(stream, "{\"ok\":true}");
}
