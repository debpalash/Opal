//! Copy-paste setup text for connecting coding agents to Opal's MCP server.
//!
//! Pure string building so the Settings page and the tests share one
//! implementation: the page shows whatever these return, and a bad quote here
//! would hand the user a command that silently fails in their shell.

const std = @import("std");

/// `<exe_dir>/opal-mcp` (`.exe` on Windows). Null when it does not fit.
pub fn mcpBinaryPath(buf: []u8, exe_dir: []const u8, windows: bool) ?[]const u8 {
    const sep: []const u8 = if (windows) "\\" else "/";
    const name: []const u8 = if (windows) "opal-mcp.exe" else "opal-mcp";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ exe_dir, sep, name }) catch null;
}

fn needsShellQuote(path: []const u8) bool {
    for (path) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '_' or c == '-' or c == '~' or c == ':' or c == '\\')) return true;
    }
    return false;
}

/// `claude mcp add opal -- <path>`; the path is single-quoted when it holds
/// spaces or shell metacharacters. A single quote in the path cannot be quoted
/// portably, so that returns null rather than a command that runs something else.
pub fn claudeCommand(buf: []u8, mcp_path: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, mcp_path, '\'') != null) return null;
    if (needsShellQuote(mcp_path)) {
        return std.fmt.bufPrint(buf, "claude mcp add opal -- '{s}'", .{mcp_path}) catch null;
    }
    return std.fmt.bufPrint(buf, "claude mcp add opal -- {s}", .{mcp_path}) catch null;
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8, quote: u8) std.Io.Writer.Error!void {
    for (s) |c| {
        if (c == '\\' or c == quote) try w.writeByte('\\');
        try w.writeByte(c);
    }
}

/// Codex `~/.codex/config.toml` block (TOML basic string).
pub fn codexToml(buf: []u8, mcp_path: []const u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("[mcp_servers.opal]\ncommand = \"") catch return null;
    writeEscaped(&w, mcp_path, '"') catch return null;
    w.writeAll("\"\n") catch return null;
    return w.buffered();
}

/// Generic `mcpServers` JSON for any other client.
pub fn jsonConfig(buf: []u8, mcp_path: []const u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("{\"mcpServers\":{\"opal\":{\"command\":\"") catch return null;
    writeEscaped(&w, mcp_path, '"') catch return null;
    w.writeAll("\"}}}") catch return null;
    return w.buffered();
}

/// `mcpServers` JSON that starts `opal-mcp` with extra arguments (each a plain
/// token, no quotes or backslashes). Used for unattended runs.
pub fn jsonConfigWithArgs(buf: []u8, mcp_path: []const u8, args: []const []const u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("{\"mcpServers\":{\"opal\":{\"command\":\"") catch return null;
    writeEscaped(&w, mcp_path, '"') catch return null;
    w.writeAll("\",\"args\":[") catch return null;
    for (args, 0..) |arg, i| {
        if (std.mem.indexOfAny(u8, arg, "\"\\\n") != null) return null;
        if (i > 0) w.writeAll(",") catch return null;
        w.print("\"{s}\"", .{arg}) catch return null;
    }
    w.writeAll("]}}}") catch return null;
    return w.buffered();
}

/// Where `opal-mcp` appends its audit log.
pub fn auditLogPath(buf: []u8, config_dir: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/mcp-audit.jsonl", .{config_dir}) catch null;
}

test "binary path joins per platform" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/opt/opal/opal-mcp", mcpBinaryPath(&b, "/opt/opal", false).?);
    try std.testing.expectEqualStrings("C:\\Opal\\opal-mcp.exe", mcpBinaryPath(&b, "C:\\Opal", true).?);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(mcpBinaryPath(&tiny, "/opt/opal", false) == null);
}

test "claude command quotes unsafe paths and refuses embedded quotes" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("claude mcp add opal -- /usr/bin/opal-mcp", claudeCommand(&b, "/usr/bin/opal-mcp").?);
    try std.testing.expectEqualStrings("claude mcp add opal -- '/Users/a b/Opal.app/opal-mcp'", claudeCommand(&b, "/Users/a b/Opal.app/opal-mcp").?);
    try std.testing.expect(claudeCommand(&b, "/tmp/it's/opal-mcp") == null);
    try std.testing.expectEqualStrings("claude mcp add opal -- '/tmp/$(rm)/opal-mcp'", claudeCommand(&b, "/tmp/$(rm)/opal-mcp").?);
}

test "codex and json escape backslashes and quotes" {
    var b: [160]u8 = undefined;
    try std.testing.expectEqualStrings("[mcp_servers.opal]\ncommand = \"/usr/bin/opal-mcp\"\n", codexToml(&b, "/usr/bin/opal-mcp").?);
    try std.testing.expectEqualStrings("[mcp_servers.opal]\ncommand = \"C:\\\\Opal\\\\opal-mcp.exe\"\n", codexToml(&b, "C:\\Opal\\opal-mcp.exe").?);
    try std.testing.expectEqualStrings("{\"mcpServers\":{\"opal\":{\"command\":\"C:\\\\Opal\\\\opal-mcp.exe\"}}}", jsonConfig(&b, "C:\\Opal\\opal-mcp.exe").?);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, jsonConfig(&b, "/a \"b\"/opal-mcp").?, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/a \"b\"/opal-mcp", parsed.value.object.get("mcpServers").?.object.get("opal").?.object.get("command").?.string);
}

test "audit path" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/home/u/.config/opal/mcp-audit.jsonl", auditLogPath(&b, "/home/u/.config/opal").?);
}

test "json config with args lists them and refuses quotes" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"mcpServers\":{\"opal\":{\"command\":\"/x/opal-mcp\",\"args\":[\"--deny-prefix\",\"agent_task\"]}}}",
        jsonConfigWithArgs(&b, "/x/opal-mcp", &.{ "--deny-prefix", "agent_task" }).?,
    );
    try std.testing.expect(jsonConfigWithArgs(&b, "/x", &.{"a\"b"}) == null);
}
