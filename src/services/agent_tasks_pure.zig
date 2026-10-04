//! Scheduled agent tasks: a prompt a coding agent runs on a timer, unattended.
//!
//! The risky parts are all here so they are unit tested without spawning
//! anything: input limits, the schedule and its daily cap, and the argv for the
//! headless run. The prompt travels as a single argv element and never through a
//! shell, so it cannot inject commands.

const std = @import("std");

/// Only agents whose headless mode Opal has verified are schedulable.
pub const Agent = enum {
    claude,
    codex,

    pub fn binary(self: Agent) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Agent {
        return std.meta.stringToEnum(Agent, s);
    }
};

pub const MAX_TASKS: usize = 20;
pub const NAME_MAX: usize = 60;
pub const PROMPT_MAX: usize = 2000;
pub const MIN_INTERVAL_MIN: u32 = 15;
pub const MAX_INTERVAL_MIN: u32 = 7 * 24 * 60;
pub const MAX_RUNS_PER_DAY_LIMIT: u32 = 24;
/// Hard ceiling on runs across all tasks per UTC day.
pub const GLOBAL_RUNS_PER_DAY: u32 = 48;
pub const MIN_BUDGET_CENTS: u32 = 5;
pub const MAX_BUDGET_CENTS: u32 = 1000;
pub const TIMEOUT_MS: i64 = 10 * 60 * 1000;
const DAY_MS: i64 = 24 * 60 * 60 * 1000;

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > NAME_MAX) return false;
    for (name) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

/// Newlines and tabs are fine in a prompt; NUL and other control bytes are not.
pub fn validPrompt(prompt: []const u8) bool {
    if (prompt.len == 0 or prompt.len > PROMPT_MAX) return false;
    for (prompt) |ch| if ((ch < 0x20 and ch != '\n' and ch != '\t' and ch != '\r') or ch == 0x7f) return false;
    return true;
}

pub fn validInterval(minutes: u32) bool {
    return minutes >= MIN_INTERVAL_MIN and minutes <= MAX_INTERVAL_MIN;
}

pub fn validRunsPerDay(n: u32) bool {
    return n >= 1 and n <= MAX_RUNS_PER_DAY_LIMIT;
}

pub fn validBudget(cents: u32) bool {
    return cents >= MIN_BUDGET_CENTS and cents <= MAX_BUDGET_CENTS;
}

/// UTC day number; the daily run cap resets when it changes.
pub fn dayIndex(ms: i64) i64 {
    return @divFloor(ms, DAY_MS);
}

pub const Schedule = struct {
    enabled: bool = true,
    interval_min: u32 = 60,
    max_runs_per_day: u32 = 4,
    /// Wall-clock ms of the last run start; 0 = never ran.
    last_run_ms: i64 = 0,
    /// The `dayIndex` that `runs_today` counts.
    day: i64 = 0,
    runs_today: u32 = 0,
};

fn runsToday(s: Schedule, now_ms: i64) u32 {
    return if (s.day == dayIndex(now_ms)) s.runs_today else 0;
}

/// A task that never ran is due immediately, so a new task proves itself at once.
pub fn isDue(s: Schedule, now_ms: i64) bool {
    if (!s.enabled) return false;
    if (runsToday(s, now_ms) >= s.max_runs_per_day) return false;
    if (s.last_run_ms == 0) return true;
    return now_ms - s.last_run_ms >= @as(i64, s.interval_min) * 60 * 1000;
}

/// When the task becomes due, for display. 0 when disabled.
pub fn nextRunMs(s: Schedule, now_ms: i64) i64 {
    if (!s.enabled) return 0;
    var at: i64 = if (s.last_run_ms == 0) now_ms else s.last_run_ms + @as(i64, s.interval_min) * 60 * 1000;
    if (runsToday(s, now_ms) >= s.max_runs_per_day) at = @max(at, (dayIndex(now_ms) + 1) * DAY_MS);
    return @max(at, now_ms);
}

/// Wrapped around every prompt: nobody is there to answer questions.
pub const preamble =
    "This is an unattended scheduled run started by Opal, so nobody can answer questions. " ++
    "Use the opal tools to do the task below, make only the changes it asks for, and end with " ++
    "one short line saying what you did.\n\nTask: ";

/// Fixed storage an argv slices into, so building one never allocates.
pub const Argv = struct {
    items: [16][]const u8 = undefined,
    len: usize = 0,
    prompt: [PROMPT_MAX + preamble.len + 8]u8 = undefined,
    budget: [16]u8 = undefined,
    override: [800]u8 = undefined,
    token_override: [800]u8 = undefined,

    pub fn slice(self: *const Argv) []const []const u8 {
        return self.items[0..self.len];
    }

    fn push(self: *Argv, s: []const u8) void {
        self.items[self.len] = s;
        self.len += 1;
    }
};

/// Headless command for `agent`, run inside the Opal workspace. Claude Code
/// gets only the opal tools plus a hard dollar cap; Codex runs in a read-only
/// sandbox with the server passed as a config override. Codex hands an MCP
/// server a trimmed environment, so it also gets the token file explicitly. Null on bad input or
/// a path that would break the TOML string.
pub fn buildArgv(out: *Argv, agent: Agent, prompt: []const u8, mcp_path: []const u8, token_file: []const u8, scheduled_mcp_config: []const u8, budget_cents: u32) ?[]const []const u8 {
    if (!validPrompt(prompt) or !validBudget(budget_cents)) return null;
    out.len = 0;
    const full = std.fmt.bufPrint(&out.prompt, "{s}{s}", .{ preamble, prompt }) catch return null;
    out.push(agent.binary());
    switch (agent) {
        .claude => {
            const budget = std.fmt.bufPrint(&out.budget, "{d}.{d:0>2}", .{ budget_cents / 100, budget_cents % 100 }) catch return null;
            out.push("-p");
            out.push(full);
            out.push("--allowedTools");
            out.push("mcp__opal");
            out.push("--max-budget-usd");
            out.push(budget);
            // Only the config handed over here: the workspace's own .mcp.json
            // still lists the scheduling tools.
            out.push("--mcp-config");
            out.push(scheduled_mcp_config);
            out.push("--strict-mcp-config");
            out.push("--no-session-persistence");
        },
        .codex => {
            if (std.mem.indexOfAny(u8, mcp_path, "\"\\\n") != null) return null;
            if (std.mem.indexOfAny(u8, token_file, "\"\\\n") != null) return null;
            const override = std.fmt.bufPrint(&out.override, "mcp_servers.opal.command=\"{s}\"", .{mcp_path}) catch return null;
            const deny_override = "mcp_servers.opal.args=[\"--deny-prefix\",\"agent_task\"]";
            const token_override = std.fmt.bufPrint(&out.token_override, "mcp_servers.opal.env.OPAL_API_TOKEN_FILE=\"{s}\"", .{token_file}) catch return null;
            out.push("exec");
            out.push("--skip-git-repo-check");
            out.push("--ephemeral");
            out.push("-s");
            out.push("read-only");
            out.push("-c");
            out.push(override);
            out.push("-c");
            out.push(token_override);
            out.push("-c");
            out.push(deny_override);
            out.push(full);
        },
    }
    return out.slice();
}

/// The last `max` bytes of `text`, trimmed, starting on a line boundary when
/// there is one. Agents print a lot; only the closing line matters.
pub fn tail(text: []const u8, max: usize) []const u8 {
    var t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len > max) {
        t = t[t.len - max ..];
        // Do not start inside a multi-byte character.
        var skip: usize = 0;
        while (skip < t.len and t[skip] & 0xC0 == 0x80) skip += 1;
        t = t[skip..];
        if (std.mem.indexOfScalar(u8, t, '\n')) |nl| {
            const rest = std.mem.trim(u8, t[nl + 1 ..], " \t\r\n");
            if (rest.len > 0) t = rest;
        }
    }
    return t;
}

pub const Outcome = enum {
    ok,
    failed,
    timed_out,
    not_installed,

    pub fn id(self: Outcome) []const u8 {
        return @tagName(self);
    }
};

test "inputs are bounded and refuse control bytes" {
    try std.testing.expect(validName("Weekly digest"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("a\nb"));
    try std.testing.expect(!validName("x" ** 61));
    try std.testing.expect(validPrompt("Check the wanted list.\nTell me what is stuck."));
    try std.testing.expect(!validPrompt(""));
    try std.testing.expect(!validPrompt("a\x00b"));
    try std.testing.expect(!validPrompt("x" ** 2001));
    try std.testing.expect(validInterval(15) and !validInterval(14) and validInterval(10080) and !validInterval(10081));
    try std.testing.expect(validRunsPerDay(1) and !validRunsPerDay(0) and !validRunsPerDay(25));
    try std.testing.expect(validBudget(5) and !validBudget(4) and validBudget(1000) and !validBudget(1001));
}

test "a new task is due at once, then waits its interval" {
    const day: i64 = 86_400_000;
    const now: i64 = 100 * day + 5000;
    var s = Schedule{ .interval_min = 60 };
    try std.testing.expect(isDue(s, now));
    s.last_run_ms = now - 59 * 60 * 1000;
    try std.testing.expect(!isDue(s, now));
    s.last_run_ms = now - 61 * 60 * 1000;
    try std.testing.expect(isDue(s, now));
    s.enabled = false;
    try std.testing.expect(!isDue(s, now));
}

test "the daily cap blocks until the next UTC day" {
    const day: i64 = 86_400_000;
    const now: i64 = 100 * day + 3_600_000;
    var s = Schedule{ .interval_min = 15, .max_runs_per_day = 2, .last_run_ms = now - 3_600_000, .day = 100, .runs_today = 2 };
    try std.testing.expect(!isDue(s, now));
    try std.testing.expectEqual(@as(i64, 101 * day), nextRunMs(s, now));
    // Yesterday's count does not carry over.
    s.day = 99;
    try std.testing.expect(isDue(s, now));
    // Under the cap, the interval governs.
    s.day = 100;
    s.runs_today = 1;
    try std.testing.expect(isDue(s, now));
    try std.testing.expectEqual(@as(i64, now), nextRunMs(s, now));
}

test "nextRunMs is zero when disabled and now for a new task" {
    try std.testing.expectEqual(@as(i64, 0), nextRunMs(.{ .enabled = false }, 5000));
    try std.testing.expectEqual(@as(i64, 5000), nextRunMs(.{}, 5000));
}

test "claude argv carries the prompt as one element with a budget cap" {
    var a: Argv = .{};
    const argv = buildArgv(&a, .claude, "Find stuck downloads; fix \"them\" $(rm -rf ~)", "/x/opal-mcp", "/c/api.token", "/c/.mcp-scheduled.json", 50).?;
    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expectEqualStrings("-p", argv[1]);
    try std.testing.expect(std.mem.startsWith(u8, argv[2], "This is an unattended scheduled run"));
    try std.testing.expect(std.mem.endsWith(u8, argv[2], "fix \"them\" $(rm -rf ~)"));
    try std.testing.expectEqualStrings("mcp__opal", argv[4]);
    try std.testing.expectEqualStrings("--max-budget-usd", argv[5]);
    try std.testing.expectEqualStrings("0.50", argv[6]);
    try std.testing.expectEqualStrings("--mcp-config", argv[7]);
    try std.testing.expectEqualStrings("/c/.mcp-scheduled.json", argv[8]);
    try std.testing.expectEqualStrings("--strict-mcp-config", argv[9]);
    try std.testing.expectEqual(@as(usize, 11), argv.len);
    const b = buildArgv(&a, .claude, "x", "/x", "/t", "/s.json", 1000).?;
    try std.testing.expectEqualStrings("10.00", b[6]);
    const c = buildArgv(&a, .claude, "x", "/x", "/t", "/s.json", 305).?;
    try std.testing.expectEqualStrings("3.05", c[6]);
}

test "codex argv is read-only with the server override" {
    var a: Argv = .{};
    const argv = buildArgv(&a, .codex, "Check the queue", "/opt/Opal App/opal-mcp", "/home/u/.config/opal/api.token", "/s.json", 50).?;
    try std.testing.expectEqualStrings("codex", argv[0]);
    try std.testing.expectEqualStrings("exec", argv[1]);
    try std.testing.expectEqualStrings("read-only", argv[5]);
    try std.testing.expectEqualStrings("mcp_servers.opal.command=\"/opt/Opal App/opal-mcp\"", argv[7]);
    try std.testing.expectEqualStrings("-c", argv[8]);
    try std.testing.expectEqualStrings("mcp_servers.opal.env.OPAL_API_TOKEN_FILE=\"/home/u/.config/opal/api.token\"", argv[9]);
    try std.testing.expectEqualStrings("-c", argv[10]);
    try std.testing.expectEqualStrings("mcp_servers.opal.args=[\"--deny-prefix\",\"agent_task\"]", argv[11]);
    try std.testing.expect(std.mem.endsWith(u8, argv[12], "Check the queue"));
}

test "bad input yields no argv" {
    var a: Argv = .{};
    try std.testing.expect(buildArgv(&a, .claude, "", "/x", "/t", "/s.json", 50) == null);
    try std.testing.expect(buildArgv(&a, .claude, "x", "/x", "/t", "/s.json", 4) == null);
    try std.testing.expect(buildArgv(&a, .codex, "x", "/x\"y", "/t", "/s.json", 50) == null);
    try std.testing.expect(buildArgv(&a, .codex, "x", "/x\\y", "/t", "/s.json", 50) == null);
    try std.testing.expect(buildArgv(&a, .codex, "x", "/x", "/t\"y", "/s.json", 50) == null);
}

test "tail keeps the closing line" {
    try std.testing.expectEqualStrings("done", tail("  done \n", 100));
    try std.testing.expectEqualStrings("last line", tail("a very long first line\nlast line\n", 14));
    try std.testing.expectEqualStrings("lo", tail("hello", 2));
    // "é" is two bytes; cutting between them must not leave a stray byte.
    try std.testing.expectEqualStrings("a", tail("\xc3\xa9a", 2));
}
