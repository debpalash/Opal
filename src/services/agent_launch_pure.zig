//! Launching coding agents (Claude Code, Codex, Gemini CLI) in the user's own
//! terminal, inside an Opal workspace that already has Opal's tools wired in.
//!
//! Pure string and argv building so the quoting rules, which are the dangerous
//! part of starting a shell command, are unit tested without spawning anything.

const std = @import("std");
const setup = @import("agent_setup_pure.zig");

pub const Agent = enum {
    claude,
    codex,
    gemini,

    pub fn binary(self: Agent) []const u8 {
        return @tagName(self);
    }

    pub fn title(self: Agent) []const u8 {
        return switch (self) {
            .claude => "Claude Code",
            .codex => "Codex",
            .gemini => "Gemini CLI",
        };
    }

    pub fn parse(s: []const u8) ?Agent {
        return std.meta.stringToEnum(Agent, s);
    }
};

/// Instructions every agent reads on start (CLAUDE.md, AGENTS.md, GEMINI.md).
pub const instructions = @embedFile("agent_workspace_md");
/// The Opal skill, installed as a Claude Code project skill.
pub const skill = @embedFile("skill_md");

/// Quote for a POSIX shell. A single quote cannot be quoted portably inside
/// single quotes, so such a string is refused instead of risking injection.
pub fn shellQuote(buf: []u8, s: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\'') != null) return null;
    for (s) |ch| if (ch == 0 or ch == '\n') return null;
    return std.fmt.bufPrint(buf, "'{s}'", .{s}) catch null;
}

/// `cd <workspace> && exec <agent>`. Codex has no project MCP file, so the
/// server is passed as a config override on its command line.
pub fn agentScript(buf: []u8, agent: Agent, workspace: []const u8, mcp_path: []const u8) ?[]const u8 {
    var ws: [700]u8 = undefined;
    const qws = shellQuote(&ws, workspace) orelse return null;
    switch (agent) {
        .codex => {
            var toml: [700]u8 = undefined;
            const override = std.fmt.bufPrint(&toml, "mcp_servers.opal.command=\"{s}\"", .{mcp_path}) catch return null;
            if (std.mem.indexOfAny(u8, mcp_path, "\"\\") != null) return null;
            var q: [800]u8 = undefined;
            const qo = shellQuote(&q, override) orelse return null;
            return std.fmt.bufPrint(buf, "cd {s} && exec codex -c {s}", .{ qws, qo }) catch null;
        },
        else => return std.fmt.bufPrint(buf, "cd {s} && exec {s}", .{ qws, agent.binary() }) catch null,
    }
}

pub const Terminal = struct {
    exe: []const u8,
    /// Arguments placed before the `sh -c <script>` the terminal should run.
    prefix: []const []const u8,
};

/// Candidates in preference order. Each runs `sh -c <script>` after `prefix`.
pub const terminals = [_]Terminal{
    .{ .exe = "ghostty", .prefix = &.{"-e"} },
    .{ .exe = "kitty", .prefix = &.{} },
    .{ .exe = "alacritty", .prefix = &.{"-e"} },
    .{ .exe = "wezterm", .prefix = &.{ "start", "--" } },
    .{ .exe = "foot", .prefix = &.{} },
    .{ .exe = "gnome-terminal", .prefix = &.{"--"} },
    .{ .exe = "konsole", .prefix = &.{"-e"} },
    .{ .exe = "xfce4-terminal", .prefix = &.{"-x"} },
    .{ .exe = "xterm", .prefix = &.{"-e"} },
};

/// argv for `terminal` running `script` under `sh -c`. Null when `out` is small.
pub fn terminalArgv(out: [][]const u8, terminal: Terminal, script: []const u8) ?[][]const u8 {
    const need = 1 + terminal.prefix.len + 3;
    if (out.len < need) return null;
    var n: usize = 0;
    out[n] = terminal.exe;
    n += 1;
    for (terminal.prefix) |p| {
        out[n] = p;
        n += 1;
    }
    out[n] = "sh";
    out[n + 1] = "-c";
    out[n + 2] = script;
    return out[0 .. n + 3];
}

/// The `.mcp.json` / `.gemini/settings.json` body wiring `opal-mcp`.
pub fn mcpJson(buf: []u8, mcp_path: []const u8) ?[]const u8 {
    return setup.jsonConfig(buf, mcp_path);
}

test "shellQuote wraps and refuses single quotes and newlines" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("'/a b/c'", shellQuote(&b, "/a b/c").?);
    try std.testing.expect(shellQuote(&b, "/a'b") == null);
    try std.testing.expect(shellQuote(&b, "/a\nb") == null);
    var tiny: [3]u8 = undefined;
    try std.testing.expect(shellQuote(&tiny, "/abc") == null);
}

test "scripts change into the workspace and exec the agent" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("cd '/w s' && exec claude", agentScript(&b, .claude, "/w s", "/x/opal-mcp").?);
    try std.testing.expectEqualStrings("cd '/w' && exec gemini", agentScript(&b, .gemini, "/w", "/x/opal-mcp").?);
}

test "codex gets the MCP server as a quoted config override" {
    var b: [512]u8 = undefined;
    const s = agentScript(&b, .codex, "/w", "/opt/Opal App/opal-mcp").?;
    try std.testing.expectEqualStrings("cd '/w' && exec codex -c 'mcp_servers.opal.command=\"/opt/Opal App/opal-mcp\"'", s);
}

test "paths that could break out of quoting are refused" {
    var b: [512]u8 = undefined;
    try std.testing.expect(agentScript(&b, .claude, "/it's", "/x") == null);
    try std.testing.expect(agentScript(&b, .codex, "/w", "/x\"; rm -rf ~; \"") == null);
    try std.testing.expect(agentScript(&b, .codex, "/w", "/x'y") == null);
}

test "terminal argv places the script after sh -c" {
    var out: [8][]const u8 = undefined;
    const argv = terminalArgv(&out, terminals[0], "echo hi").?;
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("ghostty", argv[0]);
    try std.testing.expectEqualStrings("-e", argv[1]);
    try std.testing.expectEqualStrings("sh", argv[2]);
    try std.testing.expectEqualStrings("echo hi", argv[4]);
    var tiny: [2][]const u8 = undefined;
    try std.testing.expect(terminalArgv(&tiny, terminals[0], "x") == null);
}

test "agent names round-trip" {
    try std.testing.expectEqual(Agent.codex, Agent.parse("codex").?);
    try std.testing.expect(Agent.parse("bash") == null);
    try std.testing.expectEqualStrings("Claude Code", Agent.claude.title());
}
