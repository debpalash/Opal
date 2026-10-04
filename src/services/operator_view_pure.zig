//! Wording for the Activity tab on the Agents page (the background operator's
//! jobs). Pure: no state, no UI, so the text and the small decisions behind it
//! (colour tone of a state, which limit is selected, the tab label with its
//! pending count) are unit tested.

const std = @import("std");
const pure = @import("operator_pure.zig");

const MIN_MS: i64 = 60 * 1000;
const HOUR_MS: i64 = 60 * MIN_MS;
const DAY_MS: i64 = 24 * HOUR_MS;

/// The choices offered for the daily limit, in cents.
pub const limit_presets = [_]u32{ 50, 100, 250, 500 };
pub const limit_labels = [_][]const u8{ "50\u{a2}", "100\u{a2}", "250\u{a2}", "500\u{a2}" };

/// Index of the preset equal to `cents`, or null for a custom value (set through
/// the API or the config file), in which case nothing is highlighted.
pub fn limitIndex(cents: u32) ?usize {
    for (limit_presets, 0..) |p, i| if (p == cents) return i;
    return null;
}

/// "12¢ of 100¢ today".
pub fn spendText(buf: []u8, spent: u32, limit: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}\u{a2} of {d}\u{a2} today", .{ spent, limit }) catch "";
}

/// How much of the daily limit is used, 0 to 1 (1 when the limit is 0).
pub fn spendFraction(spent: u32, limit: u32) f32 {
    if (limit == 0) return 1;
    const f = @as(f32, @floatFromInt(spent)) / @as(f32, @floatFromInt(limit));
    return std.math.clamp(f, 0, 1);
}

/// "just now", "5 min ago", "3 h ago", "2 d ago". Times in the future (clock
/// changes) read as "just now"; an unset time reads as empty.
pub fn relativeText(buf: []u8, then_ms: i64, now_ms: i64) []const u8 {
    if (then_ms <= 0) return "";
    const d = now_ms - then_ms;
    const text = if (d < MIN_MS)
        std.fmt.bufPrint(buf, "just now", .{})
    else if (d < HOUR_MS)
        std.fmt.bufPrint(buf, "{d} min ago", .{@divFloor(d, MIN_MS)})
    else if (d < DAY_MS)
        std.fmt.bufPrint(buf, "{d} h ago", .{@divFloor(d, HOUR_MS)})
    else
        std.fmt.bufPrint(buf, "{d} d ago", .{@divFloor(d, DAY_MS)});
    return text catch "";
}

pub const Tone = enum { muted, active, good, bad };

pub fn stateLabel(st: pure.State) []const u8 {
    return switch (st) {
        .queued => "Queued",
        .running => "Working",
        .proposed => "Needs OK",
        .applied => "Applied",
        .rejected => "Rejected",
        .failed => "Failed",
    };
}

pub fn stateTone(st: pure.State) Tone {
    return switch (st) {
        .queued, .rejected => .muted,
        .running, .proposed => .active,
        .applied => .good,
        .failed => .bad,
    };
}

/// "Activity" or "Activity 2" for the Agents tab header.
pub fn tabLabel(buf: []u8, pending: usize) []const u8 {
    if (pending == 0) return "Activity";
    return std.fmt.bufPrint(buf, "Activity {d}", .{pending}) catch "Activity";
}

/// "12¢", or "" when the job cost nothing (not run yet, or no cost reported).
pub fn costText(buf: []u8, cents: u32) []const u8 {
    if (cents == 0) return "";
    return std.fmt.bufPrint(buf, "{d}\u{a2}", .{cents}) catch "";
}

/// The agent's display name, or the raw value for one this build does not know.
pub fn agentLabel(agent: []const u8) []const u8 {
    if (std.mem.eql(u8, agent, "claude")) return "Claude Code";
    if (std.mem.eql(u8, agent, "codex")) return "Codex";
    return agent;
}

test "limit presets match their labels and selection" {
    try std.testing.expectEqual(limit_presets.len, limit_labels.len);
    try std.testing.expectEqual(@as(?usize, 1), limitIndex(100));
    try std.testing.expectEqual(@as(?usize, 3), limitIndex(500));
    try std.testing.expectEqual(@as(?usize, null), limitIndex(70));
}

test "spend text and fraction" {
    var b: [40]u8 = undefined;
    try std.testing.expectEqualStrings("12\u{a2} of 100\u{a2} today", spendText(&b, 12, 100));
    try std.testing.expectEqual(@as(f32, 0.12), spendFraction(12, 100));
    try std.testing.expectEqual(@as(f32, 1), spendFraction(300, 100));
    try std.testing.expectEqual(@as(f32, 1), spendFraction(0, 0));
    try std.testing.expectEqual(@as(f32, 0), spendFraction(0, 100));
}

test "relative time" {
    var b: [24]u8 = undefined;
    const now: i64 = 10 * DAY_MS;
    try std.testing.expectEqualStrings("", relativeText(&b, 0, now));
    try std.testing.expectEqualStrings("just now", relativeText(&b, now - 20_000, now));
    try std.testing.expectEqualStrings("just now", relativeText(&b, now + 5000, now));
    try std.testing.expectEqualStrings("1 min ago", relativeText(&b, now - MIN_MS, now));
    try std.testing.expectEqualStrings("59 min ago", relativeText(&b, now - 59 * MIN_MS - 30_000, now));
    try std.testing.expectEqualStrings("1 h ago", relativeText(&b, now - HOUR_MS, now));
    try std.testing.expectEqualStrings("23 h ago", relativeText(&b, now - 23 * HOUR_MS - MIN_MS, now));
    try std.testing.expectEqualStrings("3 d ago", relativeText(&b, now - 3 * DAY_MS - HOUR_MS, now));
}

test "every state has a label and a tone" {
    inline for (std.meta.fields(pure.State)) |f| {
        const st: pure.State = @enumFromInt(f.value);
        try std.testing.expect(stateLabel(st).len > 0);
        _ = stateTone(st);
    }
    try std.testing.expectEqual(Tone.good, stateTone(.applied));
    try std.testing.expectEqual(Tone.bad, stateTone(.failed));
    try std.testing.expectEqual(Tone.active, stateTone(.running));
    try std.testing.expectEqual(Tone.muted, stateTone(.rejected));
    try std.testing.expectEqual(Tone.muted, stateTone(.queued));
}

test "tab label shows the pending count only when there is one" {
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("Activity", tabLabel(&b, 0));
    try std.testing.expectEqualStrings("Activity 1", tabLabel(&b, 1));
    try std.testing.expectEqualStrings("Activity 12", tabLabel(&b, 12));
}

test "cost and agent wording" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", costText(&b, 0));
    try std.testing.expectEqualStrings("7\u{a2}", costText(&b, 7));
    try std.testing.expectEqualStrings("Claude Code", agentLabel("claude"));
    try std.testing.expectEqualStrings("Codex", agentLabel("codex"));
    try std.testing.expectEqualStrings("", agentLabel(""));
}
