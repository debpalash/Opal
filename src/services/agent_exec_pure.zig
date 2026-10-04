//! Running a coding agent without a shell on Windows, for scheduled tasks and
//! the background operator. Pure, so every decision is unit tested on any host.
//!
//! Windows has no `/bin/sh`, and an npm-installed agent is a `.cmd` shim, which
//! can only be started through `cmd.exe`. Its parsing is hostile: `%`, `^`, `&`,
//! `|`, `<`, `>`, `!` and quotes are operators or expanders even in places that
//! look quoted, and a line break ends the command. So:
//!
//!  - A native program (`claude.exe`) is started with the plain argv. Zig quotes it
//!    for `CommandLineToArgvW`, which the program uses to split it again, so any
//!    text survives, the prompt included.
//!  - A `.cmd` shim is started with the path of the shim as `argv[0]`. Zig then
//!    runs it as `cmd.exe /d /e:ON /v:OFF /c "<shim> <args>"` from the system
//!    directory and escapes `%`. That is only safe for arguments free of the set
//!    above, so every argument is checked here first and a run is refused rather
//!    than risked. The prompt, the only free-form text, never goes on the command
//!    line: it is written to the agent's standard input (`claude -p` reads it when
//!    no prompt argument is given, `codex exec -` reads it).
//!  - An empty argument is refused for a shim: cmd's `%*` forwarding has no
//!    guaranteed way to keep it, and `claude --tools ""` (no built-in tools) is a
//!    safety setting that must never silently lose its value.

const std = @import("std");

pub const Shim = enum { native, cmd };

fn endsWithFold(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

/// How an executable found on PATH is started: `.cmd` and `.bat` need `cmd.exe`.
pub fn shimOf(exe_path: []const u8) Shim {
    return if (endsWithFold(exe_path, ".cmd") or endsWithFold(exe_path, ".bat")) .cmd else .native;
}

/// Bytes `cmd.exe` would act on or lose: control characters (a line break ends
/// the command, NUL ends the string, CR is dropped), quotes, and the expanders
/// and operators `% ^ & | < > !`.
pub fn unsafeForCmd(arg: []const u8) bool {
    for (arg) |ch| {
        if (ch < 0x20 or ch == 0x7f) return true;
        if (std.mem.indexOfScalar(u8, "\"%^&|<>!", ch) != null) return true;
    }
    return false;
}

pub const Refusal = enum {
    empty_command,
    unsafe_path,
    unsafe_argument,
    empty_argument,
    prompt_unsupported,
    too_many_arguments,

    /// What the person sees as the run's summary.
    pub fn message(self: Refusal) []const u8 {
        return switch (self) {
            .empty_command => "The task could not be turned into a command.",
            .unsafe_path => "The agent's install path has a character cmd.exe cannot carry safely (such as % or &). Install it somewhere else.",
            .unsafe_argument => "A setting of this run cannot be passed safely to an agent installed as an npm .cmd shim. Install the native program instead.",
            .empty_argument => "This agent is installed as an npm .cmd shim, which cannot be trusted to keep an empty setting (--tools). Install the native program instead, or use Codex.",
            .prompt_unsupported => "This agent cannot be given its prompt safely through a .cmd shim. Install the native program instead.",
            .too_many_arguments => "The task has too many arguments.",
        };
    }
};

pub const MAX_ARGS: usize = 24;

/// The command to run and what to feed it.
pub const Plan = struct {
    items: [MAX_ARGS][]const u8 = undefined,
    len: usize = 0,
    /// Text to write to the program's standard input, then close it. Null: the
    /// program gets no standard input.
    stdin: ?[]const u8 = null,

    pub fn argv(self: *const Plan) []const []const u8 {
        return self.items[0..self.len];
    }

    fn push(self: *Plan, s: []const u8) bool {
        if (self.len >= self.items.len) return false;
        self.items[self.len] = s;
        self.len += 1;
        return true;
    }
};

/// Where the prompt sits in an agent argv: `claude -p <prompt> ...` has it after
/// `-p`; a `codex exec ... <prompt>` has it last. Null when the layout is
/// not one of those.
pub fn promptIndex(agent_argv: []const []const u8) ?usize {
    if (agent_argv.len == 0) return null;
    if (std.mem.eql(u8, agent_argv[0], "claude")) {
        if (agent_argv.len >= 3 and std.mem.eql(u8, agent_argv[1], "-p")) return 2;
        return null;
    }
    if (std.mem.eql(u8, agent_argv[0], "codex")) {
        if (agent_argv.len >= 3) return agent_argv.len - 1;
        return null;
    }
    return null;
}

/// Plan the run of `agent_argv` (`argv[0]` is the bare agent name) from the
/// executable found at `exe_path`. Null on success, else why the run is refused.
pub fn windowsPlan(out: *Plan, exe_path: []const u8, agent_argv: []const []const u8) ?Refusal {
    out.* = .{};
    if (agent_argv.len == 0 or exe_path.len == 0) return .empty_command;
    switch (shimOf(exe_path)) {
        .native => {
            if (!out.push(exe_path)) return .too_many_arguments;
            for (agent_argv[1..]) |a| if (!out.push(a)) return .too_many_arguments;
            return null;
        },
        .cmd => {
            if (unsafeForCmd(exe_path)) return .unsafe_path;
            const pi = promptIndex(agent_argv) orelse return .prompt_unsupported;
            const is_claude = std.mem.eql(u8, agent_argv[0], "claude");
            if (!out.push(exe_path)) return .too_many_arguments;
            for (agent_argv[1..], 1..) |a, i| {
                if (i == pi) {
                    // The prompt goes through standard input. Claude takes it when
                    // no prompt argument is given; Codex takes `-`.
                    out.stdin = a;
                    if (!is_claude and !out.push("-")) return .too_many_arguments;
                    continue;
                }
                if (a.len == 0) return .empty_argument;
                if (unsafeForCmd(a)) return .unsafe_argument;
                if (!out.push(a)) return .too_many_arguments;
            }
            return null;
        },
    }
}

fn expectArgv(plan: *const Plan, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, plan.argv().len);
    for (want, plan.argv()) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "shims are found by extension" {
    try std.testing.expectEqual(Shim.native, shimOf("C:\\Users\\u\\.local\\bin\\claude.exe"));
    try std.testing.expectEqual(Shim.cmd, shimOf("C:\\Users\\u\\AppData\\Roaming\\npm\\codex.cmd"));
    try std.testing.expectEqual(Shim.cmd, shimOf("C:\\x\\CODEX.CMD"));
    try std.testing.expectEqual(Shim.cmd, shimOf("C:\\x\\agent.bat"));
    try std.testing.expectEqual(Shim.native, shimOf("C:\\x\\cmdline"));
}

test "cmd metacharacters, quotes and line breaks are refused" {
    for ([_][]const u8{ "a&b", "a|b", "a<b", "a>b", "a^b", "50%", "!x!", "say \"hi\"", "a\nb", "a\rb", "a\x00b", "a\x1bb" }) |bad| {
        try std.testing.expect(unsafeForCmd(bad));
    }
    for ([_][]const u8{ "-p", "--max-budget-usd", "0.50", "C:\\Program Files (x86)\\Opal\\opal-mcp.exe", "mcp_servers.opal.command='C:\\x y\\opal-mcp.exe'", "mcp_servers.opal.args=['--deny-prefix','agent_task']", "read-only", "-" }) |ok| {
        try std.testing.expect(!unsafeForCmd(ok));
    }
}

test "a native program gets the plain argv, prompt included" {
    var plan: Plan = .{};
    const prompt = "Find stuck downloads; fix \"them\" & more\nsecond line %PATH%";
    const argv = [_][]const u8{ "claude", "-p", prompt, "--tools", "", "--mcp-config", "C:\\ws\\.mcp-scheduled.json" };
    try std.testing.expect(windowsPlan(&plan, "C:\\Users\\u\\.local\\bin\\claude.exe", &argv) == null);
    try expectArgv(&plan, &.{ "C:\\Users\\u\\.local\\bin\\claude.exe", "-p", prompt, "--tools", "", "--mcp-config", "C:\\ws\\.mcp-scheduled.json" });
    try std.testing.expect(plan.stdin == null);
}

test "a codex shim gets the prompt on stdin and a dash" {
    var plan: Plan = .{};
    const prompt = "Check the queue & do \"x\"\n%COMSPEC%";
    const argv = [_][]const u8{ "codex", "exec", "--skip-git-repo-check", "-s", "read-only", "-c", "mcp_servers.opal.command='C:\\Program Files\\Opal\\opal-mcp.exe'", prompt };
    try std.testing.expect(windowsPlan(&plan, "C:\\Users\\u\\AppData\\Roaming\\npm\\codex.cmd", &argv) == null);
    try expectArgv(&plan, &.{ "C:\\Users\\u\\AppData\\Roaming\\npm\\codex.cmd", "exec", "--skip-git-repo-check", "-s", "read-only", "-c", "mcp_servers.opal.command='C:\\Program Files\\Opal\\opal-mcp.exe'", "-" });
    try std.testing.expectEqualStrings(prompt, plan.stdin.?);
    // Nothing the prompt held is left on the command line.
    for (plan.argv()) |a| try std.testing.expect(std.mem.indexOf(u8, a, "COMSPEC") == null);
}

test "a claude shim is refused because --tools \"\" cannot be kept" {
    var plan: Plan = .{};
    const argv = [_][]const u8{ "claude", "-p", "hello", "--allowedTools", "mcp__opal", "--tools", "", "--permission-mode", "dontAsk" };
    try std.testing.expectEqual(@as(?Refusal, .empty_argument), windowsPlan(&plan, "C:\\npm\\claude.cmd", &argv));
}

test "a claude shim without empty settings drops the prompt argument and reads stdin" {
    var plan: Plan = .{};
    const argv = [_][]const u8{ "claude", "-p", "hello & bye", "--max-budget-usd", "0.50" };
    try std.testing.expect(windowsPlan(&plan, "C:\\npm\\claude.cmd", &argv) == null);
    try expectArgv(&plan, &.{ "C:\\npm\\claude.cmd", "-p", "--max-budget-usd", "0.50" });
    try std.testing.expectEqualStrings("hello & bye", plan.stdin.?);
}

test "a shim is refused for a setting with quotes or operators" {
    var plan: Plan = .{};
    // The operator's JSON arguments cannot ride through cmd.exe.
    const json = [_][]const u8{ "claude", "-p", "x", "--json-schema", "{\"type\":\"object\"}" };
    try std.testing.expectEqual(@as(?Refusal, .unsafe_argument), windowsPlan(&plan, "C:\\npm\\claude.cmd", &json));
    // A codex override in the basic-string form has quotes: refused too.
    const quoted = [_][]const u8{ "codex", "exec", "-c", "mcp_servers.opal.command=\"C:\\x\"", "x" };
    try std.testing.expectEqual(@as(?Refusal, .unsafe_argument), windowsPlan(&plan, "C:\\npm\\codex.cmd", &quoted));
    const amp = [_][]const u8{ "codex", "exec", "-o", "C:\\a&b\\out.txt", "x" };
    try std.testing.expectEqual(@as(?Refusal, .unsafe_argument), windowsPlan(&plan, "C:\\npm\\codex.cmd", &amp));
}

test "a shim path with percent or an ampersand is refused" {
    var plan: Plan = .{};
    const argv = [_][]const u8{ "codex", "exec", "x" };
    try std.testing.expectEqual(@as(?Refusal, .unsafe_path), windowsPlan(&plan, "C:\\100%\\codex.cmd", &argv));
    try std.testing.expectEqual(@as(?Refusal, .unsafe_path), windowsPlan(&plan, "C:\\a&b\\codex.cmd", &argv));
    // A path with spaces and parentheses is fine: Zig quotes it.
    try std.testing.expect(windowsPlan(&plan, "C:\\Program Files (x86)\\npm\\codex.cmd", &argv) == null);
}

test "an unknown agent layout and empty input are refused for a shim, not guessed" {
    var plan: Plan = .{};
    const gemini = [_][]const u8{ "gemini", "-p", "x" };
    try std.testing.expectEqual(@as(?Refusal, .prompt_unsupported), windowsPlan(&plan, "C:\\npm\\gemini.cmd", &gemini));
    try std.testing.expectEqual(@as(?Refusal, .empty_command), windowsPlan(&plan, "C:\\npm\\codex.cmd", &.{}));
    const argv = [_][]const u8{"codex"};
    try std.testing.expectEqual(@as(?Refusal, .empty_command), windowsPlan(&plan, "", &argv));
    // Every refusal has words for the person.
    inline for (@typeInfo(Refusal).@"enum".fields) |f| {
        try std.testing.expect(@as(Refusal, @enumFromInt(f.value)).message().len > 20);
    }
}

test "promptIndex finds the prompt in both layouts" {
    try std.testing.expectEqual(@as(?usize, 2), promptIndex(&.{ "claude", "-p", "x", "--tools", "" }));
    try std.testing.expectEqual(@as(?usize, 4), promptIndex(&.{ "codex", "exec", "-s", "read-only", "x" }));
    try std.testing.expectEqual(@as(?usize, null), promptIndex(&.{ "claude", "x" }));
}
