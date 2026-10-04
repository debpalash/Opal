//! Wording and the activity-feed merge for the Overview tab of the Agents page.
//! Pure (no state, no UI, no database) so the one-line statuses of each
//! automation card and the "what your agents did lately" feed are unit tested.
//!
//! The feed merges three sources, each already read by its own panel:
//! operator jobs, scheduled task runs and wanted items. Callers copy the few
//! fields they have into the small `*In` structs below; nothing here keeps a
//! reference to them after `mergeFeed` returns.

const std = @import("std");
const op = @import("operator_pure.zig");
const op_view = @import("operator_view_pure.zig");
const task_view = @import("agent_tasks_view_pure.zig");
const wanted = @import("wanted_pure.zig");

pub const Tone = op_view.Tone;

/// The feed shows at most this many entries.
pub const FEED_MAX: usize = 12;
/// Longest text of one entry, in bytes.
pub const TEXT_MAX: usize = 180;

/// Where a click on a feed entry (or a card's Manage link) goes.
pub const Target = enum { activity, tasks, downloads };

pub const Source = enum { operator, task, wanted };

pub const Event = struct {
    source: Source = .operator,
    tone: Tone = .muted,
    target: Target = .activity,
    when_ms: i64 = 0,
    text: [TEXT_MAX]u8 = undefined,
    len: usize = 0,

    pub fn line(self: *const Event) []const u8 {
        return self.text[0..self.len];
    }
};

pub const OperatorIn = struct {
    state: op.State,
    kind: op.Kind,
    summary: []const u8,
    /// When it finished, else when it was created.
    when_ms: i64,
};

pub const TaskIn = struct {
    name: []const u8,
    /// The stored outcome word ("ok", "failed", ...).
    outcome: []const u8,
    summary: []const u8,
    when_ms: i64,
};

pub const WantedIn = struct {
    status: wanted.Status,
    /// Already formatted ("Dune (2021)", "Severance S02E03").
    title: []const u8,
    when_ms: i64,
};

fn put(e: *Event, parts: []const []const u8) void {
    var n: usize = 0;
    for (parts) |p| {
        const room = TEXT_MAX - n;
        if (room == 0) break;
        var take = @min(p.len, room);
        // Never cut inside a UTF-8 sequence.
        if (take < p.len) while (take > 0 and (p[take] & 0xC0) == 0x80) : (take -= 1) {};
        @memcpy(e.text[n .. n + take], p[0..take]);
        n += take;
    }
    e.len = n;
}

/// The closing line of a summary, cut to `max` bytes (see task_view.summaryLine).
fn brief(buf: []u8, summary: []const u8, max: usize) []const u8 {
    return task_view.summaryLine(buf, summary, max);
}

fn operatorEvent(in: OperatorIn) ?Event {
    var e = Event{ .source = .operator, .target = .activity, .when_ms = in.when_ms };
    var sb: [120]u8 = undefined;
    const sum = brief(&sb, in.summary, 110);
    const title = op.spec(in.kind).title;
    switch (in.state) {
        .applied => {
            e.tone = .good;
            put(&e, &.{ "Operator applied: ", if (sum.len > 0) sum else title });
        },
        .proposed => {
            e.tone = .active;
            put(&e, &.{ "Operator proposes, waiting for your OK: ", if (sum.len > 0) sum else title });
        },
        .failed => {
            e.tone = .bad;
            put(&e, &.{ "Operator could not finish: ", title, if (sum.len > 0) " (" else "", sum, if (sum.len > 0) ")" else "" });
        },
        // Queued, running and rejected are not news.
        else => return null,
    }
    return e;
}

fn taskEvent(in: TaskIn) ?Event {
    const outcome = task_view.OutcomeKind.parse(in.outcome);
    if (outcome == .never or in.when_ms <= 0) return null;
    var e = Event{ .source = .task, .target = .tasks, .when_ms = in.when_ms };
    var nb: [60]u8 = undefined;
    var sb: [120]u8 = undefined;
    const name = brief(&nb, in.name, 40);
    const sum = brief(&sb, in.summary, 100);
    e.tone = switch (outcome.tone()) {
        .muted => .muted,
        .active => .active,
        .good => .good,
        .bad => .bad,
    };
    put(&e, &.{ "Task \"", name, "\" ", outcome.label(), if (sum.len > 0) ": " else "", sum });
    return e;
}

fn wantedEvent(in: WantedIn) ?Event {
    if (in.when_ms <= 0) return null;
    var e = Event{ .source = .wanted, .target = .downloads, .when_ms = in.when_ms };
    var tb: [100]u8 = undefined;
    const title = brief(&tb, in.title, 80);
    switch (in.status) {
        .fulfilled => {
            e.tone = .good;
            put(&e, &.{ "Wanted: got ", title });
        },
        .downloading => {
            e.tone = .active;
            put(&e, &.{ "Wanted: downloading ", title });
        },
        else => return null,
    }
    return e;
}

fn newer(a: Event, b: Event) bool {
    return a.when_ms > b.when_ms;
}

/// Insert `e` into the newest-first `out[0..n]`, dropping the oldest when full.
/// Equal times keep the earlier insertion first, so the order is stable.
fn insert(out: []Event, n: *usize, e: Event) void {
    var at: usize = n.*;
    while (at > 0 and newer(e, out[at - 1])) at -= 1;
    if (at >= out.len) return;
    const last = @min(n.*, out.len - 1);
    var i: usize = last;
    while (i > at) : (i -= 1) out[i] = out[i - 1];
    out[at] = e;
    if (n.* < out.len) n.* += 1;
}

/// Merge the three sources into `out`, newest first. Returns how many entries
/// were written (at most `out.len`, and `FEED_MAX` when `out` is that big).
pub fn mergeFeed(out: []Event, operator_jobs: []const OperatorIn, tasks: []const TaskIn, wanted_items: []const WantedIn) usize {
    var n: usize = 0;
    if (out.len == 0) return 0;
    for (operator_jobs) |j| if (operatorEvent(j)) |e| insert(out, &n, e);
    for (tasks) |t| if (taskEvent(t)) |e| insert(out, &n, e);
    for (wanted_items) |w| if (wantedEvent(w)) |e| insert(out, &n, e);
    return n;
}

// ── Card statuses ───────────────────────────────────────────────────────

pub const WantedCounts = struct {
    looking: u32 = 0,
    downloading: u32 = 0,
    done: u32 = 0,
    paused: u32 = 0,

    pub fn add(self: *WantedCounts, s: wanted.Status) void {
        switch (s) {
            .wanted => self.looking += 1,
            .downloading => self.downloading += 1,
            .fulfilled => self.done += 1,
            .paused => self.paused += 1,
        }
    }

    pub fn total(self: WantedCounts) u32 {
        return self.looking + self.downloading + self.done + self.paused;
    }
};

/// "2 looking, 1 downloading, 3 done" (parts at zero are left out; paused is
/// mentioned only when there are some).
pub fn wantedStatus(buf: []u8, c: WantedCounts) []const u8 {
    if (c.total() == 0) return "Nothing on the list yet";
    var w = std.Io.Writer.fixed(buf);
    var first = true;
    const parts = [_]struct { n: u32, word: []const u8 }{
        .{ .n = c.looking, .word = "looking" },
        .{ .n = c.downloading, .word = "downloading" },
        .{ .n = c.done, .word = "done" },
        .{ .n = c.paused, .word = "paused" },
    };
    for (parts) |p| {
        if (p.n == 0) continue;
        w.print("{s}{d} {s}", .{ if (first) "" else ", ", p.n, p.word }) catch break;
        first = false;
    }
    return w.buffered();
}

/// The shows the follow switch acts on: how many are tracked.
pub fn followStatus(buf: []u8, on: bool, tracked: usize) []const u8 {
    if (tracked == 0) return if (on) "On. No tracked shows yet: track one from Watching." else "Off. No tracked shows yet.";
    return std.fmt.bufPrint(buf, "{s}. {d} tracked {s}", .{
        if (on) "On" else "Off",
        tracked,
        if (tracked == 1) "show" else "shows",
    }) catch "";
}

/// "3 tasks, next in 2 h" / "Switched off: nothing runs" / "No tasks yet".
pub fn tasksStatus(buf: []u8, master_on: bool, count: usize, enabled: usize, next_run_ms: i64, now_ms: i64) []const u8 {
    if (!master_on) {
        if (count == 0) return "Off. No tasks yet.";
        return std.fmt.bufPrint(buf, "Off: {d} {s} saved, nothing runs", .{ count, if (count == 1) "task" else "tasks" }) catch "Off";
    }
    if (count == 0) return "On. No tasks yet.";
    var dur: [32]u8 = undefined;
    if (enabled == 0) return std.fmt.bufPrint(buf, "On. {d} {s}, all paused", .{ count, if (count == 1) "task" else "tasks" }) catch "On";
    const next: []const u8 = if (next_run_ms <= 0)
        "none scheduled"
    else if (next_run_ms <= now_ms)
        "next within a minute"
    else blk: {
        var nb: [48]u8 = undefined;
        break :blk std.fmt.bufPrint(&nb, "next in {s}", .{task_view.durationText(&dur, next_run_ms - now_ms)}) catch "next later";
    };
    return std.fmt.bufPrint(buf, "On. {d} {s}, {s}", .{ count, if (count == 1) "task" else "tasks", next }) catch "On";
}

/// "12 of 100 cents today, 2 proposals waiting".
pub fn operatorStatus(buf: []u8, on: bool, spent: u32, limit: u32, proposals: usize) []const u8 {
    var sb: [48]u8 = undefined;
    const spend = op_view.spendText(&sb, spent, limit);
    if (!on) {
        if (proposals > 0) return std.fmt.bufPrint(buf, "Off. {d} {s} still waiting for you", .{ proposals, if (proposals == 1) "proposal" else "proposals" }) catch "Off";
        return "Off. Nothing is sent to an agent.";
    }
    if (proposals == 0) return std.fmt.bufPrint(buf, "On. {s}", .{spend}) catch "On";
    return std.fmt.bufPrint(buf, "On. {s}, {d} {s} waiting", .{ spend, proposals, if (proposals == 1) "proposal" else "proposals" }) catch "On";
}

/// Auto subtitles: a plain switch in Settings, no agent involved.
pub fn subsStatus(on: bool) []const u8 {
    return if (on) "On. A video with no subtitles gets the best match." else "Off. Subtitles are only added when you ask.";
}

pub const RepairCounts = struct {
    sources: usize = 0,
    proposed: usize = 0,
    applied: usize = 0,
    failed: usize = 0,
};

/// Source repair is read-only: it runs inside the background operator when a
/// source keeps failing, so its status comes from the operator and from the
/// endpoint_repair jobs it already ran.
pub fn repairStatus(buf: []u8, operator_on: bool, c: RepairCounts) []const u8 {
    if (!operator_on) {
        if (c.proposed > 0) return std.fmt.bufPrint(buf, "Operator off. {d} fix {s} waiting for you", .{ c.proposed, if (c.proposed == 1) "proposal" else "proposals" }) catch "";
        return "Needs the background operator.";
    }
    if (c.sources == 0) return "On. No sources installed to watch.";
    if (c.proposed > 0) return std.fmt.bufPrint(buf, "Watching {d} {s}. {d} new {s} to review", .{ c.sources, if (c.sources == 1) "source" else "sources", c.proposed, if (c.proposed == 1) "address" else "addresses" }) catch "";
    if (c.applied > 0) return std.fmt.bufPrint(buf, "Watching {d} {s}. {d} {s} repaired recently", .{ c.sources, if (c.sources == 1) "source" else "sources", c.applied, if (c.applied == 1) "address" else "addresses" }) catch "";
    return std.fmt.bufPrint(buf, "Watching {d} {s}. Nothing needed fixing", .{ c.sources, if (c.sources == 1) "source" else "sources" }) catch "";
}

/// "3 of 5 automations on".
pub fn onSummary(buf: []u8, on: usize, total: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d} of {d} automations on", .{ on, total }) catch "";
}

/// "Dune (2021)", "Severance S02E03", or just the title.
pub fn wantedLabel(buf: []u8, kind: wanted.Kind, title: []const u8, year: u16, season: u16, episode: u16) []const u8 {
    return switch (kind) {
        .episode => std.fmt.bufPrint(buf, "{s} S{d:0>2}E{d:0>2}", .{ title, season, episode }) catch title,
        .movie => if (year > 0) std.fmt.bufPrint(buf, "{s} ({d})", .{ title, year }) catch title else title,
    };
}

/// The one line shown under a switch that spends the user's agent credit.
pub const credit_note = "Uses your own agent credit, within a limit you set.";

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "feed is newest first and capped" {
    var ops = [_]OperatorIn{
        .{ .state = .applied, .kind = .match_help, .summary = "Now also searching: Duna", .when_ms = 5_000 },
        .{ .state = .proposed, .kind = .endpoint_repair, .summary = "Move Example to https://new.example", .when_ms = 9_000 },
        .{ .state = .queued, .kind = .match_help, .summary = "", .when_ms = 99_000 },
        .{ .state = .failed, .kind = .endpoint_repair, .summary = "", .when_ms = 1_000 },
    };
    var tasks = [_]TaskIn{
        .{ .name = "Daily digest", .outcome = "ok", .summary = "Nothing is stuck", .when_ms = 7_000 },
        .{ .name = "Never", .outcome = "", .summary = "", .when_ms = 0 },
    };
    var items = [_]WantedIn{
        .{ .status = .fulfilled, .title = "Zork (2001)", .when_ms = 3_000 },
        .{ .status = .wanted, .title = "Ignored", .when_ms = 8_000 },
        .{ .status = .downloading, .title = "Fake Show S01E02", .when_ms = 6_000 },
    };
    var out: [FEED_MAX]Event = undefined;
    const n = mergeFeed(&out, &ops, &tasks, &items);
    try testing.expectEqual(@as(usize, 6), n);
    var i: usize = 1;
    while (i < n) : (i += 1) try testing.expect(out[i - 1].when_ms >= out[i].when_ms);
    try testing.expectEqual(Source.operator, out[0].source);
    try testing.expectEqual(Tone.active, out[0].tone);
    try testing.expectEqual(Target.activity, out[0].target);
    try testing.expectEqual(Source.task, out[1].source);
    try testing.expectEqual(Target.tasks, out[1].target);
    try testing.expectEqual(Source.wanted, out[2].source);
    try testing.expectEqual(Target.downloads, out[2].target);
    try testing.expectEqualStrings("Wanted: downloading Fake Show S01E02", out[2].line());
}

test "feed keeps only the newest when more than the cap" {
    var many: [30]WantedIn = undefined;
    for (&many, 0..) |*w, i| w.* = .{ .status = .fulfilled, .title = "T", .when_ms = @intCast(1000 + i) };
    var out: [FEED_MAX]Event = undefined;
    const n = mergeFeed(&out, &.{}, &.{}, &many);
    try testing.expectEqual(FEED_MAX, n);
    try testing.expectEqual(@as(i64, 1029), out[0].when_ms);
    try testing.expectEqual(@as(i64, 1018), out[FEED_MAX - 1].when_ms);
}

test "feed ties keep input order and empty input is empty" {
    var out: [FEED_MAX]Event = undefined;
    try testing.expectEqual(@as(usize, 0), mergeFeed(&out, &.{}, &.{}, &.{}));
    const items = [_]WantedIn{
        .{ .status = .fulfilled, .title = "First", .when_ms = 500 },
        .{ .status = .fulfilled, .title = "Second", .when_ms = 500 },
    };
    const n = mergeFeed(&out, &.{}, &.{}, &items);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("Wanted: got First", out[0].line());
    try testing.expectEqual(@as(usize, 0), mergeFeed(out[0..0], &.{}, &.{}, &items));
}

test "event wording" {
    const failed = operatorEvent(.{ .state = .failed, .kind = .match_help, .summary = "The agent did not finish", .when_ms = 1 }).?;
    try testing.expectEqual(Tone.bad, failed.tone);
    try testing.expect(std.mem.startsWith(u8, failed.line(), "Operator could not finish: "));
    try testing.expect(std.mem.endsWith(u8, failed.line(), "(The agent did not finish)"));
    const bare = operatorEvent(.{ .state = .applied, .kind = .match_help, .summary = "", .when_ms = 1 }).?;
    try testing.expect(std.mem.indexOf(u8, bare.line(), op.spec(.match_help).title) != null);
    const t = taskEvent(.{ .name = "Weekly", .outcome = "timed_out", .summary = "", .when_ms = 2 }).?;
    try testing.expectEqualStrings("Task \"Weekly\" timed out", t.line());
    try testing.expectEqual(Tone.bad, t.tone);
    try testing.expect(taskEvent(.{ .name = "x", .outcome = "ok", .summary = "", .when_ms = 0 }) == null);
    try testing.expect(wantedEvent(.{ .status = .paused, .title = "x", .when_ms = 9 }) == null);
    try testing.expect(wantedEvent(.{ .status = .fulfilled, .title = "x", .when_ms = 0 }) == null);
}

test "long and multibyte text never overflows or splits a character" {
    var long: [400]u8 = undefined;
    for (&long, 0..) |*c, i| c.* = if (i % 2 == 0) 0xC3 else 0xA9; // "é" repeated
    const e = taskEvent(.{ .name = &long, .outcome = "failed", .summary = &long, .when_ms = 5 }).?;
    try testing.expect(e.len <= TEXT_MAX);
    try testing.expect(std.unicode.utf8ValidateSlice(e.line()));
}

test "wanted status line" {
    var b: [96]u8 = undefined;
    try testing.expectEqualStrings("Nothing on the list yet", wantedStatus(&b, .{}));
    var c = WantedCounts{};
    for ([_]wanted.Status{ .wanted, .wanted, .downloading, .fulfilled, .fulfilled, .fulfilled }) |s| c.add(s);
    try testing.expectEqualStrings("2 looking, 1 downloading, 3 done", wantedStatus(&b, c));
    try testing.expectEqual(@as(u32, 6), c.total());
    c = .{ .done = 1, .paused = 2 };
    try testing.expectEqualStrings("1 done, 2 paused", wantedStatus(&b, c));
}

test "summary and wanted labels" {
    var b: [96]u8 = undefined;
    try testing.expectEqualStrings("2 of 5 automations on", onSummary(&b, 2, 5));
    try testing.expectEqualStrings("Dune (2021)", wantedLabel(&b, .movie, "Dune", 2021, 0, 0));
    try testing.expectEqualStrings("Dune", wantedLabel(&b, .movie, "Dune", 0, 0, 0));
    try testing.expectEqualStrings("Severance S02E03", wantedLabel(&b, .episode, "Severance", 0, 2, 3));
}

test "follow and subtitle status" {
    var b: [96]u8 = undefined;
    try testing.expectEqualStrings("On. 3 tracked shows", followStatus(&b, true, 3));
    try testing.expectEqualStrings("Off. 1 tracked show", followStatus(&b, false, 1));
    try testing.expect(std.mem.indexOf(u8, followStatus(&b, true, 0), "No tracked shows") != null);
    try testing.expect(std.mem.startsWith(u8, subsStatus(true), "On"));
    try testing.expect(std.mem.startsWith(u8, subsStatus(false), "Off"));
}

test "tasks status line" {
    var b: [96]u8 = undefined;
    const now: i64 = 1_000_000_000;
    try testing.expectEqualStrings("Off. No tasks yet.", tasksStatus(&b, false, 0, 0, 0, now));
    try testing.expectEqualStrings("Off: 2 tasks saved, nothing runs", tasksStatus(&b, false, 2, 2, now + 1, now));
    try testing.expectEqualStrings("On. No tasks yet.", tasksStatus(&b, true, 0, 0, 0, now));
    try testing.expectEqualStrings("On. 1 task, all paused", tasksStatus(&b, true, 1, 0, 0, now));
    try testing.expectEqualStrings("On. 3 tasks, next in 2 h", tasksStatus(&b, true, 3, 2, now + 2 * 60 * 60 * 1000, now));
    try testing.expectEqualStrings("On. 3 tasks, next within a minute", tasksStatus(&b, true, 3, 2, now - 5, now));
}

test "operator and repair status lines" {
    var b: [128]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, operatorStatus(&b, false, 0, 100, 0), "Off"));
    try testing.expectEqualStrings("Off. 2 proposals still waiting for you", operatorStatus(&b, false, 0, 100, 2));
    try testing.expectEqualStrings("On. 12\u{a2} of 100\u{a2} today", operatorStatus(&b, true, 12, 100, 0));
    try testing.expectEqualStrings("On. 12\u{a2} of 100\u{a2} today, 1 proposal waiting", operatorStatus(&b, true, 12, 100, 1));
    try testing.expectEqualStrings("Needs the background operator.", repairStatus(&b, false, .{ .sources = 4 }));
    try testing.expectEqualStrings("Watching 4 sources. Nothing needed fixing", repairStatus(&b, true, .{ .sources = 4 }));
    try testing.expectEqualStrings("Watching 1 source. 2 addresses repaired recently", repairStatus(&b, true, .{ .sources = 1, .applied = 2 }));
    try testing.expectEqualStrings("Watching 4 sources. 1 new address to review", repairStatus(&b, true, .{ .sources = 4, .proposed = 1, .applied = 9 }));
    try testing.expect(std.mem.indexOf(u8, repairStatus(&b, true, .{}), "No sources") != null);
}
