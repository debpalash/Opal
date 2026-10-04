//! Start a coding agent in the user's terminal, inside an Opal workspace.
//!
//! The workspace (`<config>/agent-workspace`) is rewritten on every launch with
//! the agent instructions, the Opal skill and an MCP config pointing at the
//! `opal-mcp` that sits next to this executable, so each agent starts already
//! knowing Opal and holding its tools. The terminal is the user's own; an
//! embedded one is a later step.

const std = @import("std");
const builtin = @import("builtin");
const io_g = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const logs = @import("../core/logs.zig");
const workers = @import("../core/workers.zig");
const bounded = @import("../core/bounded_process.zig");
const pure = @import("agent_launch_pure.zig");
const setup = @import("agent_setup_pure.zig");

pub const Agent = pure.Agent;

pub const Result = enum {
    started,
    not_installed,
    no_terminal,
    unsupported_platform,
    workspace_failed,
    bad_path,
    spawn_failed,

    pub fn message(self: Result) []const u8 {
        return switch (self) {
            .started => "Opened in your terminal",
            .not_installed => "That agent is not installed (not on PATH)",
            .no_terminal => "No supported terminal found",
            .unsupported_platform => "Launching is Linux-only for now; use the copy buttons",
            .workspace_failed => "Could not create the agent workspace",
            .bad_path => "A path contains a character that cannot be quoted safely",
            .spawn_failed => "Could not start the terminal",
        };
    }
};

fn existsOnDisk(path: []const u8) bool {
    // Windows has no execute bit to ask for; a file with a launchable extension is enough.
    io_g.cwdAccess(path, .{ .execute = builtin.os.tag != .windows }) catch return false;
    return true;
}

/// Whether `name` is a program on PATH. POSIX: an executable file of that name.
/// Windows: `;` separated, trying `name.exe`, `name.cmd` and `name.bat` (npm
/// installs the agent CLIs as `.cmd` shims); the current directory is not
/// searched. The search itself is `agent_launch_pure.searchPath`.
pub fn onPath(name: []const u8) bool {
    var buf: [1024]u8 = undefined;
    return findOnPath(&buf, name) != null;
}

/// The full path `name` runs from, written into `buf`; null when it is not on
/// PATH. Windows prefers `name.exe` over the npm `.cmd` shim in the same folder.
/// A scheduled run starts this path, never the bare name, so the current
/// directory and the app's own folder are never searched.
pub fn findOnPath(buf: []u8, name: []const u8) ?[]const u8 {
    const path = io_g.getenv("PATH") orelse return null;
    if (builtin.os.tag == .windows) return pure.searchPath(buf, path, name, ';', '\\', &pure.windows_exts, existsOnDisk);
    return pure.searchPath(buf, path, name, ':', '/', &.{""}, existsOnDisk);
}

/// Write `prompt` to a started process's standard input and close it, so the
/// agent reads the prompt from there instead of the command line. Pipe buffers are
/// small and the agent reads its whole input before it answers, so this blocks
/// only until it has; if it exits early the write fails and the caller stops it.
pub fn feedPrompt(process: *bounded.StreamProcess, prompt: []const u8) bool {
    defer process.child.closeStdin();
    const stdin = process.child.stdin orelse return false;
    io_g.writeAll(stdin, prompt) catch return false;
    return true;
}

pub fn installed(agent: Agent) bool {
    return onPath(agent.binary());
}

fn writeManaged(workspace: []const u8, rel: []const u8, data: []const u8) bool {
    var buf: [900]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ workspace, rel }) catch return false;
    if (std.fs.path.dirname(full)) |dir| io_g.cwdMakePath(dir) catch return false;
    io_g.cwdWriteFile(.{ .sub_path = full, .data = data }) catch return false;
    return true;
}

fn ensureWorkspace(workspace: []const u8, mcp_path: []const u8) bool {
    io_g.cwdMakePath(workspace) catch return false;
    var json_buf: [768]u8 = undefined;
    const json = pure.mcpJson(&json_buf, mcp_path) orelse return false;
    return writeManaged(workspace, "CLAUDE.md", pure.instructions) and
        writeManaged(workspace, "AGENTS.md", pure.instructions) and
        writeManaged(workspace, "GEMINI.md", pure.instructions) and
        writeManaged(workspace, ".mcp.json", json) and
        writeManaged(workspace, ".gemini/settings.json", json) and
        writeManaged(workspace, ".claude/skills/opal-media/SKILL.md", pure.skill);
}

fn reapTerminal(child: *io_g.Child) void {
    // Terminals either exit after handing off to a server or run until the user
    // closes the window; waiting just keeps the child from lingering as a zombie.
    _ = child.wait() catch {};
    std.heap.page_allocator.destroy(child);
}

pub const Workspace = struct {
    path_buf: [600]u8 = undefined,
    path_len: usize = 0,
    mcp_buf: [600]u8 = undefined,
    mcp_len: usize = 0,
    token_buf: [600]u8 = undefined,
    token_len: usize = 0,

    pub fn path(self: *const Workspace) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn mcpPath(self: *const Workspace) []const u8 {
        return self.mcp_buf[0..self.mcp_len];
    }

    pub fn tokenFile(self: *const Workspace) []const u8 {
        return self.token_buf[0..self.token_len];
    }
};

/// Create or refresh the workspace and locate `opal-mcp`. Shared by the terminal
/// launcher and the scheduled tasks, so both start an agent that knows Opal.
pub fn prepareWorkspace(out: *Workspace) Result {
    var exe_buf: [512]u8 = undefined;
    const exe_dir = io_g.selfExeDirPath(&exe_buf) catch return .workspace_failed;
    const mcp_path = setup.mcpBinaryPath(&out.mcp_buf, exe_dir, false) orelse return .bad_path;
    out.mcp_len = mcp_path.len;

    var cfg_buf: [512]u8 = undefined;
    const workspace = std.fmt.bufPrint(&out.path_buf, "{s}/agent-workspace", .{paths.configDir(&cfg_buf)}) catch return .bad_path;
    out.path_len = workspace.len;
    const token = std.fmt.bufPrint(&out.token_buf, "{s}/api.token", .{paths.configDir(&cfg_buf)}) catch return .bad_path;
    out.token_len = token.len;
    if (!ensureWorkspace(workspace, mcp_path)) return .workspace_failed;
    return .started;
}

pub fn launch(agent: Agent) Result {
    if (builtin.os.tag != .linux) return .unsupported_platform;
    if (!installed(agent)) return .not_installed;

    var ws: Workspace = .{};
    const prep = prepareWorkspace(&ws);
    if (prep != .started) return prep;
    const workspace = ws.path();
    const mcp_path = ws.mcpPath();

    var script_buf: [2048]u8 = undefined;
    const script = pure.agentScript(&script_buf, agent, workspace, mcp_path, ws.tokenFile()) orelse return .bad_path;

    for (pure.terminals) |term| {
        if (!onPath(term.exe)) continue;
        var argv_buf: [8][]const u8 = undefined;
        const argv = pure.terminalArgv(&argv_buf, term, script) orelse continue;
        const child = std.heap.page_allocator.create(io_g.Child) catch return .spawn_failed;
        child.* = io_g.Child.init(argv, std.heap.page_allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.cwd = workspace;
        child.spawn() catch {
            std.heap.page_allocator.destroy(child);
            return .spawn_failed;
        };
        const th = workers.spawnLegacy(reapTerminal, .{child}) catch return .started;
        workers.release(th);
        logs.pushLog("info", "agents", "Launched a coding agent in the terminal", false);
        return .started;
    }
    return .no_terminal;
}
