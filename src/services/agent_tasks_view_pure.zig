//! Text and example data for the Tasks panel on the Agents page. Everything here
//! is pure (no state, no UI) so the wording and the limits it shows are unit
//! tested: interval and next-run phrasing, one-line summaries, the outcome
//! labels and the example tasks, which must pass the same validators the
//! scheduler enforces.

const std = @import("std");
const pure = @import("agent_tasks_pure.zig");

const MIN_MS: i64 = 60 * 1000;
const HOUR_MIN: u32 = 60;
const DAY_MIN: u32 = 24 * 60;
const WEEK_MIN: u32 = 7 * 24 * 60;

/// "every 15 min", "every 6 h", "daily", "weekly", "every 1 h 30 min".
pub fn intervalText(buf: []u8, minutes: u32) []const u8 {
    if (minutes == DAY_MIN) return "daily";
    if (minutes == WEEK_MIN) return "weekly";
    const text = if (minutes < HOUR_MIN)
        std.fmt.bufPrint(buf, "every {d} min", .{minutes})
    else if (minutes % DAY_MIN == 0)
        std.fmt.bufPrint(buf, "every {d} d", .{minutes / DAY_MIN})
    else if (minutes % HOUR_MIN == 0)
        std.fmt.bufPrint(buf, "every {d} h", .{minutes / HOUR_MIN})
    else if (minutes < DAY_MIN)
        std.fmt.bufPrint(buf, "every {d} h {d} min", .{ minutes / HOUR_MIN, minutes % HOUR_MIN })
    else
        std.fmt.bufPrint(buf, "every {d} min", .{minutes});
    return text catch "on a schedule";
}

/// "$0.50", "$10.00".
pub fn dollarsText(buf: []u8, cents: u32) []const u8 {
    return std.fmt.bufPrint(buf, "${d}.{d:0>2}", .{ cents / 100, cents % 100 }) catch "$?";
}

/// "2 of 4 runs today".
pub fn runsText(buf: []u8, runs_today: u32, cap: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d} of {d} runs today", .{ runs_today, cap }) catch "";
}

/// A duration in the coarsest useful form: "5 min", "3 h 20 min", "2 d".
pub fn durationText(buf: []u8, ms: i64) []const u8 {
    const total_min: i64 = @max(0, @divFloor(ms + MIN_MS - 1, MIN_MS)); // round up
    const text = if (total_min < 60)
        std.fmt.bufPrint(buf, "{d} min", .{@max(total_min, 1)})
    else if (total_min < 24 * 60) blk: {
        const h = @divFloor(total_min, 60);
        const m = @mod(total_min, 60);
        break :blk if (m == 0)
            std.fmt.bufPrint(buf, "{d} h", .{h})
        else
            std.fmt.bufPrint(buf, "{d} h {d} min", .{ h, m });
    } else blk: {
        const d = @divFloor(total_min, 24 * 60);
        const h = @divFloor(@mod(total_min, 24 * 60), 60);
        break :blk if (h == 0)
            std.fmt.bufPrint(buf, "{d} d", .{d})
        else
            std.fmt.bufPrint(buf, "{d} d {d} h", .{ d, h });
    };
    return text catch "a while";
}

/// What the "next run" cell says. A task that is paused never runs, and with the
/// master switch off nothing does, whatever the schedule says.
pub fn nextRunText(buf: []u8, task_enabled: bool, master_enabled: bool, running: bool, next_run_ms: i64, now_ms: i64) []const u8 {
    if (running) return "running now";
    if (!task_enabled) return "paused";
    if (!master_enabled) return "waiting for the switch";
    if (next_run_ms <= now_ms) return "next check, within a minute";
    var dur: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "in {s}", .{durationText(&dur, next_run_ms - now_ms)}) catch "later";
}

/// "3 h 20 min ago", "just now", or "never".
pub fn lastRunText(buf: []u8, last_run_ms: i64, now_ms: i64) []const u8 {
    if (last_run_ms <= 0) return "never run";
    if (now_ms - last_run_ms < MIN_MS) return "ran just now";
    var dur: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "ran {s} ago", .{durationText(&dur, now_ms - last_run_ms)}) catch "ran earlier";
}

pub const OutcomeKind = enum {
    never,
    running,
    ok,
    failed,
    timed_out,
    not_installed,
    unknown,

    pub fn parse(s: []const u8) OutcomeKind {
        if (s.len == 0) return .never;
        return std.meta.stringToEnum(OutcomeKind, s) orelse .unknown;
    }

    pub fn label(self: OutcomeKind) []const u8 {
        return switch (self) {
            .never => "not run yet",
            .running => "running",
            .ok => "finished",
            .failed => "failed",
            .timed_out => "timed out",
            .not_installed => "agent not installed",
            .unknown => "unknown",
        };
    }

    pub const Tone = enum { muted, active, good, bad };

    pub fn tone(self: OutcomeKind) Tone {
        return switch (self) {
            .never, .unknown => .muted,
            .running => .active,
            .ok => .good,
            .failed, .timed_out, .not_installed => .bad,
        };
    }
};

/// The closing line of the agent's output, on one line and at most `max` bytes
/// (ending in "..." when cut, never inside a UTF-8 sequence). The agent is told
/// to end with one line saying what it did, so the last non-empty line is the
/// report; earlier lines are usually tool chatter.
pub fn summaryLine(buf: []u8, summary: []const u8, max: usize) []const u8 {
    const limit = @min(max, buf.len);
    var rest = std.mem.trim(u8, summary, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, rest, '\n')) |nl| rest = std.mem.trim(u8, rest[nl + 1 ..], " \t\r");
    if (rest.len == 0 or limit == 0) return "";

    const ellipsis = "...";
    var end = rest.len;
    if (rest.len > limit) {
        end = if (limit > ellipsis.len) limit - ellipsis.len else 0;
        while (end > 0 and (rest[end] & 0xC0) == 0x80) end -= 1; // back to a char start
    }
    var n: usize = 0;
    for (rest[0..end]) |ch| {
        buf[n] = if (ch < 0x20 or ch == 0x7f) ' ' else ch;
        n += 1;
    }
    if (end < rest.len) {
        const room = @min(ellipsis.len, limit - n);
        @memcpy(buf[n .. n + room], ellipsis[0..room]);
        n += room;
    }
    return buf[0..n];
}

/// A whole-number text field. Null when empty, not a number or out of range.
pub fn parseCount(text: []const u8) ?u32 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}

pub const IntervalPreset = struct { label: []const u8, minutes: u32 };

pub const interval_presets = [_]IntervalPreset{
    .{ .label = "15m", .minutes = 15 },
    .{ .label = "1h", .minutes = 60 },
    .{ .label = "6h", .minutes = 360 },
    .{ .label = "Daily", .minutes = 1440 },
    .{ .label = "Weekly", .minutes = 10080 },
};

/// One-click example that prefills the Add form. Prompts are self-contained: an
/// unattended run cannot ask a question, and the agent has the opal tools.
pub const Example = struct {
    /// Button label in the empty state.
    title: []const u8,
    name: []const u8,
    prompt: []const u8,
    interval_min: u32,
    max_runs_per_day: u32,
    budget_cents: u32,
};

pub const examples = [_]Example{
    .{
        .title = "Daily digest of what's stuck",
        .name = "Daily digest",
        .prompt = "Use the opal tools to list the active downloads and the wanted list. " ++
            "Find anything that looks stuck: a download with no progress or no peers, a wanted item that has been searched many times without a match, a failed transfer. " ++
            "Do not change, pause, remove or retry anything. " ++
            "End with one line: how many items are stuck and the name of the worst one, or that nothing is stuck.",
        .interval_min = 1440,
        .max_runs_per_day = 1,
        .budget_cents = 30,
    },
    .{
        .title = "Check the wanted list",
        .name = "Check wanted list",
        .prompt = "Use the opal tools to read the wanted list. " ++
            "For each item that is still waiting and has been searched at least twice without a result, search once more using a different phrasing of the title (for example the original title or without the year). " ++
            "Do not start any download yourself; only report. " ++
            "End with one line: how many waiting items you re-checked and which ones now have a result.",
        .interval_min = 360,
        .max_runs_per_day = 4,
        .budget_cents = 50,
    },
    .{
        .title = "Tidy finished downloads report",
        .name = "Finished downloads report",
        .prompt = "Use the opal tools to list the downloads and the history. " ++
            "Report the finished downloads that are not in the library or not yet watched, and any duplicates by name. " ++
            "Do not delete, move or cancel anything. " ++
            "End with one line: how many finished downloads are waiting and the total size if the tools report it.",
        .interval_min = 10080,
        .max_runs_per_day = 1,
        .budget_cents = 30,
    },
};

// ── Tests ──

test "interval text reads like a person would say it" {
    var b: [40]u8 = undefined;
    try std.testing.expectEqualStrings("every 15 min", intervalText(&b, 15));
    try std.testing.expectEqualStrings("every 45 min", intervalText(&b, 45));
    try std.testing.expectEqualStrings("every 1 h", intervalText(&b, 60));
    try std.testing.expectEqualStrings("every 6 h", intervalText(&b, 360));
    try std.testing.expectEqualStrings("every 1 h 30 min", intervalText(&b, 90));
    try std.testing.expectEqualStrings("daily", intervalText(&b, 1440));
    try std.testing.expectEqualStrings("weekly", intervalText(&b, 10080));
    try std.testing.expectEqualStrings("every 2 d", intervalText(&b, 2880));
    try std.testing.expectEqualStrings("every 25 h", intervalText(&b, 1500));
    try std.testing.expectEqualStrings("every 1501 min", intervalText(&b, 1501));
    // A buffer that is too small degrades to a generic phrase instead of failing.
    var tiny: [3]u8 = undefined;
    try std.testing.expectEqualStrings("on a schedule", intervalText(&tiny, 15));
}

test "money and run counters" {
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("$0.05", dollarsText(&b, 5));
    try std.testing.expectEqualStrings("$0.50", dollarsText(&b, 50));
    try std.testing.expectEqualStrings("$10.00", dollarsText(&b, 1000));
    try std.testing.expectEqualStrings("2 of 4 runs today", runsText(&b, 2, 4));
}

test "durations round up to the minute and pick a unit" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1 min", durationText(&b, 1));
    try std.testing.expectEqualStrings("1 min", durationText(&b, 60_000));
    try std.testing.expectEqualStrings("2 min", durationText(&b, 60_001));
    try std.testing.expectEqualStrings("59 min", durationText(&b, 59 * 60_000));
    try std.testing.expectEqualStrings("1 h", durationText(&b, 60 * 60_000));
    try std.testing.expectEqualStrings("3 h 20 min", durationText(&b, (3 * 60 + 20) * 60_000));
    try std.testing.expectEqualStrings("1 d", durationText(&b, 24 * 60 * 60_000));
    try std.testing.expectEqualStrings("2 d 5 h", durationText(&b, (2 * 24 + 5) * 60 * 60_000));
    try std.testing.expectEqualStrings("1 min", durationText(&b, -5));
}

test "next run text: paused and switch-off beat the schedule" {
    var b: [48]u8 = undefined;
    const now: i64 = 1_000_000_000;
    try std.testing.expectEqualStrings("running now", nextRunText(&b, true, true, true, now + 1, now));
    try std.testing.expectEqualStrings("paused", nextRunText(&b, false, true, false, now + 60_000, now));
    try std.testing.expectEqualStrings("paused", nextRunText(&b, false, false, false, 0, now));
    try std.testing.expectEqualStrings("waiting for the switch", nextRunText(&b, true, false, false, now + 60_000, now));
    try std.testing.expectEqualStrings("next check, within a minute", nextRunText(&b, true, true, false, now, now));
    try std.testing.expectEqualStrings("next check, within a minute", nextRunText(&b, true, true, false, 0, now));
    try std.testing.expectEqualStrings("in 6 h", nextRunText(&b, true, true, false, now + 6 * 60 * 60_000, now));
}

test "last run text" {
    var b: [48]u8 = undefined;
    const now: i64 = 1_000_000_000;
    try std.testing.expectEqualStrings("never run", lastRunText(&b, 0, now));
    try std.testing.expectEqualStrings("ran just now", lastRunText(&b, now - 10_000, now));
    try std.testing.expectEqualStrings("ran 5 min ago", lastRunText(&b, now - 5 * 60_000, now));
}

test "outcomes map to a label and a tone, and unknown text never crashes" {
    try std.testing.expectEqual(OutcomeKind.never, OutcomeKind.parse(""));
    try std.testing.expectEqual(OutcomeKind.ok, OutcomeKind.parse("ok"));
    try std.testing.expectEqual(OutcomeKind.running, OutcomeKind.parse("running"));
    try std.testing.expectEqual(OutcomeKind.timed_out, OutcomeKind.parse("timed_out"));
    try std.testing.expectEqual(OutcomeKind.unknown, OutcomeKind.parse("exploded"));
    try std.testing.expectEqual(OutcomeKind.Tone.good, OutcomeKind.ok.tone());
    try std.testing.expectEqual(OutcomeKind.Tone.bad, OutcomeKind.failed.tone());
    try std.testing.expectEqual(OutcomeKind.Tone.bad, OutcomeKind.not_installed.tone());
    try std.testing.expectEqual(OutcomeKind.Tone.active, OutcomeKind.running.tone());
    try std.testing.expectEqual(OutcomeKind.Tone.muted, OutcomeKind.never.tone());
    // Every outcome the scheduler can write is understood.
    inline for (std.meta.fields(pure.Outcome)) |f| {
        try std.testing.expect(OutcomeKind.parse(f.name) != .unknown);
    }
}

test "summary keeps the closing line, flattens it and truncates on a character boundary" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", summaryLine(&b, "", 60));
    try std.testing.expectEqualStrings("", summaryLine(&b, " \n\t\n", 60));
    try std.testing.expectEqualStrings("Nothing is stuck.", summaryLine(&b, "Nothing is stuck.", 60));
    try std.testing.expectEqualStrings("2 items stuck.", summaryLine(&b, "calling tool...\nlisting\n2 items stuck.\n", 60));
    try std.testing.expectEqualStrings("a b", summaryLine(&b, "a\x01b", 60));
    try std.testing.expectEqualStrings("0123456...", summaryLine(&b, "0123456789ABCDEF", 10));
    try std.testing.expectEqualStrings("0123456789", summaryLine(&b, "0123456789", 10));

    // Never cut a multi-byte character in half: "é" is two bytes.
    const cut = summaryLine(&b, "abcdéfghijk", 8);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqualStrings("abcd...", cut);
    try std.testing.expect(std.mem.endsWith(u8, cut, "..."));

    // A limit larger than the buffer is clamped to it.
    var small: [8]u8 = undefined;
    try std.testing.expect(summaryLine(&small, "x" ** 100, 1000).len <= 8);
    // Tiny limits do not underflow.
    try std.testing.expectEqualStrings("..", summaryLine(&b, "abcdef", 2));
    try std.testing.expectEqualStrings("", summaryLine(&b, "abcdef", 0));
}

test "count fields parse digits only" {
    try std.testing.expectEqual(@as(?u32, 15), parseCount("15"));
    try std.testing.expectEqual(@as(?u32, 360), parseCount("  360 "));
    try std.testing.expectEqual(@as(?u32, null), parseCount(""));
    try std.testing.expectEqual(@as(?u32, null), parseCount("6h"));
    try std.testing.expectEqual(@as(?u32, null), parseCount("-3"));
    try std.testing.expectEqual(@as(?u32, null), parseCount("99999999999999"));
}

test "interval presets and examples satisfy the scheduler's own limits" {
    for (interval_presets) |p| try std.testing.expect(pure.validInterval(p.minutes));
    try std.testing.expectEqual(@as(usize, 3), examples.len);
    for (examples) |e| {
        try std.testing.expect(pure.validName(e.name));
        try std.testing.expect(pure.validPrompt(e.prompt));
        try std.testing.expect(pure.validInterval(e.interval_min));
        try std.testing.expect(pure.validRunsPerDay(e.max_runs_per_day));
        try std.testing.expect(pure.validBudget(e.budget_cents));
        // The titles fit a button and the prompts leave room for the user to extend them.
        try std.testing.expect(e.title.len <= 40);
        try std.testing.expect(e.prompt.len <= pure.PROMPT_MAX - 200);
        // Nobody can answer a question in an unattended run.
        try std.testing.expect(std.mem.indexOf(u8, e.prompt, "End with one line") != null);
    }
}
