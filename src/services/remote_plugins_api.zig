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
        try writer.print("\",\"installed\":{s}}}", .{if (repo.isInstalled(plugin.idSlice())) "true" else "false"});
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
        const mode = if (!runnable) "invalid" else if (native and !trusted) "blocked" else if (trusted and (native or plugin.allow_unsafe)) "full-access" else "lua-sandbox";
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
