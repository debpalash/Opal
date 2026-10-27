//! Skip-segment policy — pure (no io_global, no globals, unit-testable).
//!
//! One skip machinery for every source of intro/recap/credits/preview ranges:
//!
//!   anime_skip  — crowdsourced Anime-Skip API (highest priority)
//!   chapters    — the file's own chapter titles ("Opening", "Ending", …)
//!   fingerprint — locally detected by audio fingerprinting (markers.zig)
//!
//! `merge` picks, per category, the highest-priority source that has it;
//! `decide` says whether the play head is inside a segment, what the button
//! should do ("Skip intro" vs "Next episode"), and whether the user's
//! "Skip intros & credits" mode wants it skipped automatically.
//! skip_segments.zig routes through these so the tested logic IS the shipped
//! logic.

const std = @import("std");
const anime = @import("anime_skip_pure.zig");

pub const Category = anime.Category;
pub const Prefs = anime.Prefs;

/// "Skip intros & credits" setting. Persisted as config key `skip_mode`.
pub const Mode = enum(u8) {
    off = 0,
    button = 1,
    auto = 2,
};

pub fn modeFromInt(v: u8) Mode {
    return switch (v) {
        0 => .off,
        1 => .button,
        else => .auto,
    };
}

pub fn modeLabel(m: Mode) []const u8 {
    return switch (m) {
        .off => "Off",
        .button => "Show button",
        .auto => "Auto-skip",
    };
}

/// Migration: configs written before `skip_mode` existed only had the anime
/// master toggle `anime_skip_enabled` (on = auto-skip). Keep that behaviour.
pub fn legacyMode(anime_skip_enabled: bool) Mode {
    return if (anime_skip_enabled) .auto else .off;
}

/// The legacy key is still written so an older build reading this config
/// keeps working: anything but Off means "enabled".
pub fn legacyEnabled(m: Mode) bool {
    return m != .off;
}

/// Priority order: lower value wins.
pub const Source = enum(u8) {
    anime_skip = 0,
    chapters = 1,
    fingerprint = 2,
};

pub fn sourceName(s: Source) []const u8 {
    return switch (s) {
        .anime_skip => "anime-skip",
        .chapters => "chapters",
        .fingerprint => "fingerprint",
    };
}

pub const Seg = struct {
    start: f64 = 0,
    end: f64 = 0,
    category: Category = .other,
    confidence: f32 = 1,
    source: Source = .chapters,
};

pub const MAX_SEGS = 16;
/// Below this a detected segment is not even offered as a button.
pub const DISPLAY_MIN_CONFIDENCE: f32 = 0.35;
/// Auto-skip needs more certainty than showing a button.
pub const AUTO_MIN_CONFIDENCE: f32 = 0.6;
/// Credits ending within this of EOF turn the button into "Next episode".
pub const NEXT_EPISODE_SLACK_S: f64 = 60;

/// Only these four categories are ever offered or skipped.
pub fn skippable(c: Category) bool {
    return switch (c) {
        .intro, .recap, .credits, .preview => true,
        else => false,
    };
}

fn overlaps(a: Seg, b: Seg) bool {
    return a.start < b.end and b.start < a.end;
}

/// Merge per-source lists (indexed by Source) into `out`, sorted by start.
/// A category supplied by a higher-priority source suppresses the same
/// category from lower ones; a lower-priority segment that overlaps an
/// already-accepted one is dropped. Returns the count written.
pub fn merge(lists: [3][]const Seg, out: []Seg) usize {
    var n: usize = 0;
    var claimed = std.EnumSet(Category).initEmpty();
    for (lists) |list| {
        var here = std.EnumSet(Category).initEmpty();
        for (list) |s| {
            if (!skippable(s.category) or !(s.end > s.start)) continue;
            if (claimed.contains(s.category)) continue;
            const clash = for (out[0..n]) |o| {
                if (overlaps(o, s)) break true;
            } else false;
            if (clash or n >= out.len) continue;
            out[n] = s;
            n += 1;
            here.insert(s.category);
        }
        claimed.setUnion(here);
    }
    std.mem.sort(Seg, out[0..n], {}, struct {
        fn lt(_: void, a: Seg, b: Seg) bool {
            return a.start < b.start;
        }
    }.lt);
    return n;
}

pub const Action = enum { skip, next_episode };

pub const Decision = struct {
    index: usize,
    target: f64,
    category: Category,
    source: Source,
    action: Action,
    /// Seek automatically right now (mode == auto, category opted in,
    /// confident enough, not already skipped this segment).
    auto: bool,
};

pub const Context = struct {
    mode: Mode,
    prefs: Prefs,
    duration: f64 = 0,
    has_next: bool = false,
    /// Index of the segment most recently auto-skipped (-1 = none).
    latch: i32 = -1,
};

pub fn decide(pos: f64, segs: []const Seg, ctx: Context) ?Decision {
    if (ctx.mode == .off) return null;
    for (segs, 0..) |s, i| {
        if (pos < s.start or pos >= s.end) continue;
        if (!skippable(s.category) or s.confidence < DISPLAY_MIN_CONFIDENCE) return null;
        const near_eof = ctx.duration > 0 and s.end >= ctx.duration - NEXT_EPISODE_SLACK_S;
        const action: Action = if ((s.category == .credits or s.category == .preview) and near_eof and ctx.has_next)
            .next_episode
        else
            .skip;
        const latched = ctx.latch >= 0 and @as(usize, @intCast(ctx.latch)) == i;
        return .{
            .index = i,
            .target = s.end,
            .category = s.category,
            .source = s.source,
            .action = action,
            .auto = ctx.mode == .auto and anime.enabled(s.category, ctx.prefs) and
                s.confidence >= AUTO_MIN_CONFIDENCE and !latched,
        };
    }
    return null;
}

/// Button text — plain words, no glyphs (the caller adds a lucide icon).
pub fn buttonLabel(d: Decision) []const u8 {
    if (d.action == .next_episode) return "Next episode";
    return switch (d.category) {
        .intro => "Skip intro",
        .recap => "Skip recap",
        .credits => "Skip credits",
        .preview => "Skip preview",
        else => "Skip",
    };
}

/// Stable machine name for the web API.
pub fn kindName(c: Category) []const u8 {
    return anime.label(c);
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════
const testing = std.testing;

test "mode migration keeps the legacy anime toggle's behaviour" {
    try testing.expectEqual(Mode.auto, legacyMode(true));
    try testing.expectEqual(Mode.off, legacyMode(false));
    try testing.expect(legacyEnabled(.button));
    try testing.expect(legacyEnabled(.auto));
    try testing.expect(!legacyEnabled(.off));
    try testing.expectEqual(Mode.button, modeFromInt(1));
    try testing.expectEqual(Mode.auto, modeFromInt(9));
    try testing.expectEqualStrings("Show button", modeLabel(.button));
}

test "merge: per-category priority anime-skip > chapters > fingerprint" {
    const anime_l = [_]Seg{.{ .start = 90, .end = 180, .category = .intro, .source = .anime_skip }};
    const chap = [_]Seg{
        .{ .start = 85, .end = 175, .category = .intro, .source = .chapters }, // suppressed
        .{ .start = 1300, .end = 1390, .category = .credits, .source = .chapters },
    };
    const fpl = [_]Seg{
        .{ .start = 88, .end = 178, .category = .intro, .confidence = 0.9, .source = .fingerprint }, // suppressed
        .{ .start = 1310, .end = 1395, .category = .credits, .confidence = 0.9, .source = .fingerprint }, // suppressed
        .{ .start = 10, .end = 40, .category = .recap, .confidence = 0.9, .source = .fingerprint }, // new
        .{ .start = 5, .end = 6, .category = .filler, .source = .fingerprint }, // not skippable
    };
    var out: [MAX_SEGS]Seg = undefined;
    const n = merge(.{ &anime_l, &chap, &fpl }, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(Category.recap, out[0].category);
    try testing.expectEqual(Source.anime_skip, out[1].source);
    try testing.expectEqual(Source.chapters, out[2].source);
}

test "merge: overlapping lower-priority segment of another category is dropped" {
    const chap = [_]Seg{.{ .start = 0, .end = 100, .category = .intro, .source = .chapters }};
    const fpl = [_]Seg{.{ .start = 50, .end = 120, .category = .recap, .source = .fingerprint }};
    var out: [4]Seg = undefined;
    try testing.expectEqual(@as(usize, 1), merge(.{ &.{}, &chap, &fpl }, &out));
}

test "decide: button vs auto, confidence gates, latch, next episode" {
    const segs = [_]Seg{
        .{ .start = 60, .end = 150, .category = .intro, .confidence = 0.9, .source = .fingerprint },
        .{ .start = 300, .end = 340, .category = .recap, .confidence = 0.5, .source = .fingerprint },
        .{ .start = 1300, .end = 1395, .category = .credits, .confidence = 0.9, .source = .fingerprint },
        .{ .start = 1000, .end = 1010, .category = .intro, .confidence = 0.2, .source = .fingerprint },
    };
    const prefs = Prefs{};
    // Off: nothing.
    try testing.expect(decide(70, &segs, .{ .mode = .off, .prefs = prefs }) == null);
    // Button: offered, never auto.
    const b = decide(70, &segs, .{ .mode = .button, .prefs = prefs }).?;
    try testing.expect(!b.auto);
    try testing.expectEqual(@as(f64, 150), b.target);
    try testing.expectEqualStrings("Skip intro", buttonLabel(b));
    // Auto: intro skipped; latched once.
    try testing.expect(decide(70, &segs, .{ .mode = .auto, .prefs = prefs }).?.auto);
    try testing.expect(!decide(70, &segs, .{ .mode = .auto, .prefs = prefs, .latch = 0 }).?.auto);
    // Low-confidence recap: button only.
    const r = decide(310, &segs, .{ .mode = .auto, .prefs = prefs }).?;
    try testing.expect(!r.auto);
    // Below display confidence: nothing.
    try testing.expect(decide(1005, &segs, .{ .mode = .auto, .prefs = prefs }) == null);
    // Boundaries are [start, end).
    try testing.expect(decide(150, &segs, .{ .mode = .button, .prefs = prefs }) == null);
    try testing.expect(decide(60, &segs, .{ .mode = .button, .prefs = prefs }) != null);
    // Credits near EOF with a next episode -> "Next episode"; credits not
    // auto-skipped by default prefs.
    const c = decide(1320, &segs, .{ .mode = .auto, .prefs = prefs, .duration = 1420, .has_next = true }).?;
    try testing.expectEqual(Action.next_episode, c.action);
    try testing.expectEqualStrings("Next episode", buttonLabel(c));
    try testing.expect(!c.auto);
    const c2 = decide(1320, &segs, .{ .mode = .button, .prefs = prefs, .duration = 1420, .has_next = false }).?;
    try testing.expectEqualStrings("Skip credits", buttonLabel(c2));
    const c3 = decide(1320, &segs, .{ .mode = .button, .prefs = prefs, .duration = 2400, .has_next = true }).?;
    try testing.expectEqual(Action.skip, c3.action);
}
