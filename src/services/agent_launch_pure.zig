//! Launching coding agents (Claude Code, Codex, Gemini CLI) in the user's own
//! terminal, inside an Opal workspace that already has Opal's tools wired in.
//!
//! Pure string and argv building so the quoting rules, which are the dangerous
//! part of starting a shell command, are unit tested without spawning anything.

const std = @import("std");
const setup = @import("agent_setup_pure.zig");
const win = @import("win_cmdline_pure.zig");

test {
    _ = win;
}

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
pub fn agentScript(buf: []u8, agent: Agent, workspace: []const u8, mcp_path: []const u8, token_file: []const u8) ?[]const u8 {
    var ws: [700]u8 = undefined;
    const qws = shellQuote(&ws, workspace) orelse return null;
    switch (agent) {
        .codex => {
            var toml: [700]u8 = undefined;
            const override = std.fmt.bufPrint(&toml, "mcp_servers.opal.command=\"{s}\"", .{mcp_path}) catch return null;
            if (std.mem.indexOfAny(u8, mcp_path, "\"\\") != null) return null;
            if (std.mem.indexOfAny(u8, token_file, "\"\\") != null) return null;
            var q: [800]u8 = undefined;
            const qo = shellQuote(&q, override) orelse return null;
            // Codex gives MCP servers a trimmed environment, so say where the token is.
            var tbuf: [700]u8 = undefined;
            const env = std.fmt.bufPrint(&tbuf, "mcp_servers.opal.env.OPAL_API_TOKEN_FILE=\"{s}\"", .{token_file}) catch return null;
            var tq: [800]u8 = undefined;
            const qt = shellQuote(&tq, env) orelse return null;
            return std.fmt.bufPrint(buf, "cd {s} && exec codex -c {s} -c {s}", .{ qws, qo, qt }) catch null;
        },
        else => return std.fmt.bufPrint(buf, "cd {s} && exec {s}", .{ qws, agent.binary() }) catch null,
    }
}

/// `cd <workspace> && exec $SHELL`: a plain shell in the Opal workspace, for the
/// embedded terminal.
pub fn shellScript(buf: []u8, workspace: []const u8) ?[]const u8 {
    var ws: [700]u8 = undefined;
    const qws = shellQuote(&ws, workspace) orelse return null;
    return std.fmt.bufPrint(buf, "cd {s} && exec \"${{SHELL:-/bin/sh}}\"", .{qws}) catch null;
}

// ── Windows ──
//
// The embedded terminal on Windows starts one raw command line (there is no
// `/bin/sh`). Agents run under `cmd.exe` because npm installs them as `.cmd`
// shims, which PowerShell would shadow with a `.ps1` twin that the default
// execution policy refuses to run. The interactive shell is PowerShell. Both
// shapes are built here, with the quoting rules of each shell.

pub const WinShell = enum { powershell, cmd };

fn hasSmartQuote(s: []const u8) bool {
    // PowerShell treats U+2018..U+201B like an apostrophe inside '...'.
    var i: usize = 0;
    while (i + 2 < s.len) : (i += 1) {
        if (s[i] == 0xE2 and s[i + 1] == 0x80 and s[i + 2] >= 0x98 and s[i + 2] <= 0x9B) return true;
    }
    return false;
}

/// Copy `s` with `/` turned into `\`, refusing what could break out of the
/// quoting `shell` uses. `cmd` expands `%` even inside quotes and treats the rest
/// of the set as operators, so those are refused rather than escaped.
fn winClean(out: []u8, s: []const u8, shell: WinShell) ?[]const u8 {
    if (s.len == 0 or s.len > out.len) return null;
    for (s, 0..) |ch, i| {
        switch (ch) {
            0, '\r', '\n', '"' => return null,
            else => {},
        }
        if (shell == .cmd and std.mem.indexOfScalar(u8, "%^&|<>!", ch) != null) return null;
        out[i] = if (ch == '/') '\\' else ch;
    }
    if (shell == .powershell and hasSmartQuote(s)) return null;
    return out[0..s.len];
}

/// A PowerShell single-quoted string: nothing inside is expanded, and an
/// apostrophe is written twice.
fn psQuote(out: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    if (out.len < 2) return null;
    out[n] = '\'';
    n += 1;
    for (s) |ch| {
        const need: usize = if (ch == '\'') 2 else 1;
        if (n + need + 1 > out.len) return null;
        out[n] = ch;
        n += 1;
        if (ch == '\'') {
            out[n] = '\'';
            n += 1;
        }
    }
    out[n] = '\'';
    return out[0 .. n + 1];
}

/// ` -c <override> -c <override>` for codex. The overrides are TOML literal
/// strings ('...'), so Windows backslashes need no escaping and no double quote
/// has to survive both the shell and the C runtime.
fn winCodexArgs(out: []u8, shell: WinShell, mcp_path: []const u8, token_file: []const u8) ?[]const u8 {
    var m: [700]u8 = undefined;
    var t: [700]u8 = undefined;
    const mcp = winClean(&m, mcp_path, shell) orelse return null;
    const token = winClean(&t, token_file, shell) orelse return null;
    // A TOML literal string cannot hold an apostrophe.
    if (std.mem.indexOfScalar(u8, mcp, '\'') != null or std.mem.indexOfScalar(u8, token, '\'') != null) return null;
    var o1: [800]u8 = undefined;
    var o2: [800]u8 = undefined;
    const a = std.fmt.bufPrint(&o1, "mcp_servers.opal.command='{s}'", .{mcp}) catch return null;
    const b = std.fmt.bufPrint(&o2, "mcp_servers.opal.env.OPAL_API_TOKEN_FILE='{s}'", .{token}) catch return null;
    switch (shell) {
        .cmd => return std.fmt.bufPrint(out, " -c \"{s}\" -c \"{s}\"", .{ a, b }) catch null,
        .powershell => {
            var qa: [1700]u8 = undefined;
            var qb: [1700]u8 = undefined;
            const pa = psQuote(&qa, a) orelse return null;
            const pb = psQuote(&qb, b) orelse return null;
            return std.fmt.bufPrint(out, " -c {s} -c {s}", .{ pa, pb }) catch null;
        },
    }
}

/// The whole command line that runs `agent` inside `workspace` under `shell`.
/// Path separators are normalised to `\`; paths that cannot be quoted safely
/// give null.
pub fn windowsAgentCommand(buf: []u8, shell: WinShell, agent: Agent, workspace: []const u8, mcp_path: []const u8, token_file: []const u8) ?[]const u8 {
    var wsb: [700]u8 = undefined;
    const ws = winClean(&wsb, workspace, shell) orelse return null;
    var args_buf: [3600]u8 = undefined;
    const args: []const u8 = if (agent == .codex) winCodexArgs(&args_buf, shell, mcp_path, token_file) orelse return null else "";
    switch (shell) {
        // /s makes cmd strip exactly the outer quotes and run the rest verbatim.
        .cmd => return std.fmt.bufPrint(buf, "cmd.exe /d /s /c \"cd /d \"{s}\" && {s}{s}\"", .{ ws, agent.binary(), args }) catch null,
        .powershell => {
            var q: [1500]u8 = undefined;
            var script: [3600]u8 = undefined;
            const quoted = psQuote(&q, ws) orelse return null;
            const text = std.fmt.bufPrint(&script, "Set-Location -LiteralPath {s}; & {s}{s}", .{ quoted, agent.binary(), args }) catch return null;
            var arg: [7300]u8 = undefined;
            const wrapped = win.argQuote(&arg, text) orelse return null;
            return std.fmt.bufPrint(buf, "powershell.exe -NoLogo -NoProfile -Command {s}", .{wrapped}) catch null;
        },
    }
}

/// An interactive shell in `workspace`: the command line the embedded terminal
/// runs when no agent is chosen. It stays open after the `cd`.
pub fn windowsShellCommand(buf: []u8, shell: WinShell, workspace: []const u8) ?[]const u8 {
    var wsb: [700]u8 = undefined;
    const ws = winClean(&wsb, workspace, shell) orelse return null;
    switch (shell) {
        .cmd => return std.fmt.bufPrint(buf, "cmd.exe /d /s /k \"cd /d \"{s}\"\"", .{ws}) catch null,
        .powershell => {
            var q: [1500]u8 = undefined;
            var script: [1600]u8 = undefined;
            const quoted = psQuote(&q, ws) orelse return null;
            const text = std.fmt.bufPrint(&script, "Set-Location -LiteralPath {s}", .{quoted}) catch return null;
            var arg: [3300]u8 = undefined;
            const wrapped = win.argQuote(&arg, text) orelse return null;
            return std.fmt.bufPrint(buf, "powershell.exe -NoLogo -NoExit -Command {s}", .{wrapped}) catch null;
        },
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
    try std.testing.expectEqualStrings("cd '/w s' && exec claude", agentScript(&b, .claude, "/w s", "/x/opal-mcp", "/t").?);
    try std.testing.expectEqualStrings("cd '/w' && exec gemini", agentScript(&b, .gemini, "/w", "/x/opal-mcp", "/t").?);
}

test "codex gets the MCP server as a quoted config override" {
    var b: [512]u8 = undefined;
    const s = agentScript(&b, .codex, "/w", "/opt/Opal App/opal-mcp", "/h/.config/opal/api.token").?;
    try std.testing.expectEqualStrings("cd '/w' && exec codex -c 'mcp_servers.opal.command=\"/opt/Opal App/opal-mcp\"' -c 'mcp_servers.opal.env.OPAL_API_TOKEN_FILE=\"/h/.config/opal/api.token\"'", s);
}

test "shell script keeps the workspace quoted and falls back to sh" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("cd '/w s' && exec \"${SHELL:-/bin/sh}\"", shellScript(&b, "/w s").?);
    try std.testing.expect(shellScript(&b, "/it's") == null);
}

test "paths that could break out of quoting are refused" {
    var b: [512]u8 = undefined;
    try std.testing.expect(agentScript(&b, .claude, "/it's", "/x", "/t") == null);
    try std.testing.expect(agentScript(&b, .codex, "/w", "/x\"; rm -rf ~; \"", "/t") == null);
    try std.testing.expect(agentScript(&b, .codex, "/w", "/x'y", "/t") == null);
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

test "windows cmd agent line cds with /d and quotes a path with spaces" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "cmd.exe /d /s /c \"cd /d \"C:\\Users\\a b\\opal\\agent-workspace\" && claude\"",
        windowsAgentCommand(&b, .cmd, .claude, "C:\\Users\\a b\\opal/agent-workspace", "C:\\x\\opal-mcp.exe", "C:\\t").?,
    );
    try std.testing.expectEqualStrings(
        "cmd.exe /d /s /c \"cd /d \"D:\\w\" && gemini\"",
        windowsAgentCommand(&b, .cmd, .gemini, "D:\\w", "x", "y").?,
    );
}

test "windows cmd codex line passes TOML literal overrides" {
    var b: [1024]u8 = undefined;
    const s = windowsAgentCommand(&b, .cmd, .codex, "C:\\w s", "C:\\Program Files\\Opal\\opal-mcp.exe", "C:\\Users\\a\\opal\\api.token").?;
    try std.testing.expectEqualStrings(
        "cmd.exe /d /s /c \"cd /d \"C:\\w s\" && codex -c \"mcp_servers.opal.command='C:\\Program Files\\Opal\\opal-mcp.exe'\" -c \"mcp_servers.opal.env.OPAL_API_TOKEN_FILE='C:\\Users\\a\\opal\\api.token'\"\"",
        s,
    );
}

test "windows powershell agent line uses a literal path and survives apostrophes" {
    var b: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "powershell.exe -NoLogo -NoProfile -Command \"Set-Location -LiteralPath 'C:\\Users\\O''Brien\\ws'; & claude\"",
        windowsAgentCommand(&b, .powershell, .claude, "C:/Users/O'Brien/ws", "x", "y").?,
    );
    const codex = windowsAgentCommand(&b, .powershell, .codex, "C:\\w", "C:\\a b\\opal-mcp.exe", "C:\\t").?;
    try std.testing.expectEqualStrings(
        "powershell.exe -NoLogo -NoProfile -Command \"Set-Location -LiteralPath 'C:\\w'; & codex -c 'mcp_servers.opal.command=''C:\\a b\\opal-mcp.exe''' -c 'mcp_servers.opal.env.OPAL_API_TOKEN_FILE=''C:\\t'''\"",
        codex,
    );
}

test "windows shell lines stay open after the cd" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("cmd.exe /d /s /k \"cd /d \"C:\\w s\"\"", windowsShellCommand(&b, .cmd, "C:/w s").?);
    try std.testing.expectEqualStrings(
        "powershell.exe -NoLogo -NoExit -Command \"Set-Location -LiteralPath 'C:\\w s'\"",
        windowsShellCommand(&b, .powershell, "C:\\w s").?,
    );
}

test "windows paths that could break out of quoting are refused" {
    var b: [1024]u8 = undefined;
    // cmd expands %VAR% and treats & | ^ < > ! as operators even next to quotes.
    try std.testing.expect(windowsAgentCommand(&b, .cmd, .claude, "C:\\%PATH%", "x", "y") == null);
    try std.testing.expect(windowsAgentCommand(&b, .cmd, .claude, "C:\\a&calc", "x", "y") == null);
    try std.testing.expect(windowsShellCommand(&b, .cmd, "C:\\a\"b") == null);
    try std.testing.expect(windowsShellCommand(&b, .powershell, "C:\\a\nb") == null);
    // PowerShell takes curly apostrophes as quotes.
    try std.testing.expect(windowsShellCommand(&b, .powershell, "C:\\it\xe2\x80\x99s") == null);
    // Codex overrides are TOML literals, which cannot hold an apostrophe.
    try std.testing.expect(windowsAgentCommand(&b, .cmd, .codex, "C:\\w", "C:\\it's\\opal-mcp.exe", "C:\\t") == null);
    try std.testing.expect(windowsAgentCommand(&b, .cmd, .claude, "", "x", "y") == null);
    var tiny: [20]u8 = undefined;
    try std.testing.expect(windowsAgentCommand(&tiny, .cmd, .claude, "C:\\w", "x", "y") == null);
}
