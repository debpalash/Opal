//! JSON projection for the web plugin manager. Kept out of the top-level
//! router so plugin lifecycle details remain owned by the plugin boundary.

const std = @import("std");
const repo = @import("plugin_repo.zig");
const plugins = @import("plugins.zig");
const writeJsonString = @import("remote_http.zig").writeJsonString;

pub const TrustResponse = struct {
    status: ?[]const u8 = null,
    json: []const u8,
};

pub fn changeTrust(action: []const u8, id: []const u8) TrustResponse {
    return switch (plugins.setContentTrust(id, std.mem.eql(u8, action, "approve-exec"))) {
        .applied => .{ .json = "{\"ok\":true,\"result\":\"applied\"}" },
        .unchanged => .{ .json = "{\"ok\":true,\"result\":\"unchanged\"}" },
        .not_found => .{ .status = "404 Not Found", .json = "{\"error\":\"installed executable plugin not found\"}" },
        .failed => .{ .status = "500 Internal Server Error", .json = "{\"error\":\"could not change plugin trust\"}" },
    };
}

/// `scaffold` creates an inert plugin skeleton; `test` dry-runs an approved plugin's
/// `search`. Neither can approve anything: trust stays a user decision.
pub fn authoring(stream: std.Io.net.Stream, action: []const u8, body: []const u8, query: []const u8) void {
    const wire = @import("remote_http.zig");
    var id_buf: [64]u8 = undefined;
    const id = wire.formParam(body, query, "id", &id_buf) orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"plugin id required\"}");
        return;
    };
    if (std.mem.eql(u8, action, "scaffold")) {
        var name_buf: [64]u8 = undefined;
        var desc_buf: [160]u8 = undefined;
        const name = wire.formParam(body, query, "name", &name_buf) orelse id;
        const description = wire.formParam(body, query, "description", &desc_buf) orelse "";
        switch (plugins.scaffold(id, name, description)) {
            .created => wire.sendJson(stream, "{\"ok\":true,\"result\":\"created\",\"next\":\"Edit the search script in the plugin folder, then ask the user to review and approve it in Settings > Plugins. It does not run until approved.\"}"),
            .invalid_id => wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid id, name or description\"}"),
            .exists => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"a plugin with that id already exists\"}"),
            .failed => wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"could not create the plugin\"}"),
        }
        return;
    }
    var query_buf: [256]u8 = undefined;
    const search = wire.formParam(body, query, "query", &query_buf) orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"query required\"}");
        return;
    };
    const alloc = @import("../core/alloc.zig").allocator;
    const report = alloc.create(plugins.TestReport) catch {
        wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    defer alloc.destroy(report);
    plugins.testSearch(id, search, report);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer };
    s.beginObject() catch return;
    s.objectField("outcome") catch return;
    s.write(@tagName(report.outcome)) catch return;
    s.objectField("count") catch return;
    s.write(report.count) catch return;
    s.objectField("rows") catch return;
    s.beginArray() catch return;
    for (report.rows[0..report.count]) |*row| {
        s.beginObject() catch return;
        inline for (.{ .{ "id", "id" }, .{ "title", "title" }, .{ "stream_url", "stream_url" }, .{ "year", "year" }, .{ "type", "media_type" } }) |f| {
            s.objectField(f[0]) catch return;
            s.write(@field(row, f[1])[0..@field(row, f[1] ++ "_len")]) catch return;
        }
        s.endObject() catch return;
    }
    s.endArray() catch return;
    s.endObject() catch return;
    wire.sendJson(stream, out.written());
}

pub fn writeSources(writer: anytype, catalog: []repo.Plugin) !void {
    for (catalog, 0..) |*plugin, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"id\":\"");
        writeJsonString(writer, plugin.id[0..@min(plugin.id_len, plugin.id.len)]);
        try writer.writeAll("\",\"name\":\"");
        writeJsonString(writer, plugin.name[0..@min(plugin.name_len, plugin.name.len)]);
        try writer.writeAll("\",\"kind\":\"");
        writeJsonString(writer, plugin.kind[0..@min(plugin.kind_len, plugin.kind.len)]);
        try writer.writeAll("\",\"version\":\"");
        writeJsonString(writer, plugin.version[0..@min(plugin.version_len, plugin.version.len)]);
        const health = @import("source_request.zig").snapshot(plugin.idSlice());
        try writer.print("\",\"installed\":{s},\"health\":{{\"state\":\"{s}\",\"status\":{d},\"latency_ms\":{d},\"cached\":{s},\"fallback\":{s}}}}}", .{
            if (repo.isInstalled(plugin.idSlice())) "true" else "false", @tagName(health.state),                   health.status, health.latency_ms,
            if (health.cached) "true" else "false",                      if (health.fallback) "true" else "false",
        });
    }
}

pub fn writeExecutables(writer: anytype) !void {
    var installed: [32]plugins.Plugin = [_]plugins.Plugin{.{}} ** 32;
    const count = plugins.snapshotInstalled(&installed);
    for (installed[0..count], 0..) |*plugin, i| {
        if (i > 0) try writer.writeAll(",");
        const native = plugins.hasNativeEntrypoint(plugin);
        const trusted = plugin.user_trusted;
        const runnable = plugin.has_search or plugin.has_resolve or plugin.has_trending;
        const mode = if (!runnable) "invalid" else if (!trusted) "blocked" else if (trusted and (native or plugin.allow_unsafe)) "full-access" else "lua-sandbox";
        try writer.writeAll("{\"id\":\"");
        writeJsonString(writer, plugin.id[0..plugin.id_len]);
        try writer.writeAll("\",\"name\":\"");
        writeJsonString(writer, plugin.name[0..plugin.name_len]);
        try writer.writeAll("\",\"version\":\"");
        writeJsonString(writer, plugin.version[0..plugin.version_len]);
        try writer.writeAll("\",\"description\":\"");
        writeJsonString(writer, plugin.description[0..plugin.description_len]);
        try writer.print("\",\"search\":{s},\"resolve\":{s},\"trending\":{s},\"native\":{s},\"trusted\":{s},\"allow_unsafe\":{s},\"mode\":\"{s}\"}}", .{
            if (plugin.has_search) "true" else "false",
            if (plugin.has_resolve) "true" else "false",
            if (plugin.has_trending) "true" else "false",
            if (native) "true" else "false",
            if (trusted) "true" else "false",
            if (plugin.allow_unsafe) "true" else "false",
            mode,
        });
    }
}
