//! GET /api/i18n?locale=<tag or Accept-Language>: the web UI's string table,
//! the same keys and fallback chain as the native UI (core/i18n.zig).
const std = @import("std");
const wire = @import("remote_http.zig");

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8) bool {
    if (!std.mem.eql(u8, path, "/i18n")) return false;
    if (!wire.requireMethod(stream, method, "GET")) return true;
    var locale_buf: [64]u8 = undefined;
    const want = wire.formParam("", query, "locale", &locale_buf) orelse "";
    var out: std.Io.Writer.Allocating = .init(@import("../core/alloc.zig").allocator);
    defer out.deinit();
    @import("../core/i18n.zig").writeJson(&out.writer, want) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"i18n unavailable\"}");
        return true;
    };
    wire.sendJson(stream, out.written());
    return true;
}
