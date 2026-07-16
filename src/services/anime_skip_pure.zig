const std = @import("std");

// ══════════════════════════════════════════════════════════════════════════
// Anime-Skip — pure logic (no io_global, no allocator globals, unit-testable)
//
// anime-skip.com is "SponsorBlock for anime": crowdsourced markers for
// intros, recaps, credits, previews, etc. Their GraphQL API stores POINT
// markers (a `type` name at a Float `at` in seconds), NOT ranges: a section
// runs FROM one marker's `at` UNTIL the next marker's `at` (sorted ascending);
// the final marker runs to end-of-file. So "skip the intro" = when playback
// enters the Intro marker, seek to the NEXT marker's `at`.
//
// This module owns:
//   • buildRequestBody  — GraphQL POST body (JSON-escapes the episode name)
//   • parseResponse     — JSON → markers (best-episode pick + ascending sort)
//   • buildSkipSegments — point markers → [start,end) ranges
//   • categorize        — type.name → skip Category
//   • shouldSkip        — is `pos` inside a skippable segment? (once-per-seg)
// The shipped service (anime_skip.zig) routes through these so the tested
// logic IS the shipped logic.
// ══════════════════════════════════════════════════════════════════════════

pub const MAX_MARKERS = 48;
pub const MAX_SEGMENTS = MAX_MARKERS;
pub const TYPE_NAME_CAP = 32;

/// A skip category. Only intro/recap/credits/preview have user toggles; the
/// rest are recognised (so ranges are built correctly) but never auto-skipped.
pub const Category = enum {
    intro,
    recap,
    credits,
    preview,
    filler,
    canon,
    must_watch,
    branding,
    title_card,
    transition,
    mixed,
    other,
};

pub const Marker = struct {
    at: f64 = 0,
    type_name: [TYPE_NAME_CAP]u8 = std.mem.zeroes([TYPE_NAME_CAP]u8),
    type_len: usize = 0,

    pub fn name(self: *const Marker) []const u8 {
        return self.type_name[0..self.type_len];
    }
};

pub const Segment = struct {
    start: f64 = 0,
    end: f64 = 0,
    category: Category = .other,
};

/// Which categories the user wants auto-skipped.
pub const Prefs = struct {
    intro: bool = true,
    recap: bool = true,
    credits: bool = false,
    preview: bool = false,
};

pub const SkipDecision = struct {
    target: f64,
    seg_index: usize,
    category: Category,
};

// ── type.name → Category ─────────────────────────────────────────────────
// anime-skip's canonical type names. Matched case-insensitively so minor
// server-side casing changes don't silently drop a category.
pub fn categorize(type_name: []const u8) Category {
    const eq = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.ascii.eqlIgnoreCase(a, b);
        }
    }.f;
    if (eq(type_name, "Intro") or eq(type_name, "New Intro")) return .intro;
    if (eq(type_name, "Recap")) return .recap;
    if (eq(type_name, "Credits") or eq(type_name, "Mixed Credits") or
        eq(type_name, "New Credits") or eq(type_name, "Ending")) return .credits;
    if (eq(type_name, "Preview")) return .preview;
    if (eq(type_name, "Filler")) return .filler;
    if (eq(type_name, "Canon")) return .canon;
    if (eq(type_name, "Must Watch")) return .must_watch;
    if (eq(type_name, "Branding")) return .branding;
    if (eq(type_name, "Title Card")) return .title_card;
    if (eq(type_name, "Transition")) return .transition;
    return .other;
}

/// Is this category one the user has opted to auto-skip?
pub fn enabled(cat: Category, prefs: Prefs) bool {
    return switch (cat) {
        .intro => prefs.intro,
        .recap => prefs.recap,
        .credits => prefs.credits,
        .preview => prefs.preview,
        else => false, // filler/canon/branding/etc. are never auto-skipped
    };
}

/// Full label for the manual "Skip" affordance in the player control bar
/// (e.g. "Skip Intro", prefixed with a U+23ED skip-forward glyph). Only the
/// four toggle-able categories get a specific noun; anything else (never
/// offered by currentSkippable) falls back to a generic "Skip". Routed through
/// from footer.zig so the tested label IS the shipped label.
pub fn skipButtonLabel(cat: Category) []const u8 {
    return switch (cat) {
        .intro => "\xE2\x8F\xAD Skip Intro",
        .recap => "\xE2\x8F\xAD Skip Recap",
        .credits => "\xE2\x8F\xAD Skip Credits",
        .preview => "\xE2\x8F\xAD Skip Preview",
        else => "\xE2\x8F\xAD Skip",
    };
}

/// Short human label for a category (used in the "Skipped X" toast).
pub fn label(cat: Category) []const u8 {
    return switch (cat) {
        .intro => "intro",
        .recap => "recap",
        .credits => "credits",
        .preview => "preview",
        .filler => "filler",
        .canon => "canon",
        .must_watch => "must-watch",
        .branding => "branding",
        .title_card => "title card",
        .transition => "transition",
        .mixed => "mixed",
        .other => "section",
    };
}

// ── GraphQL request body ─────────────────────────────────────────────────
const QUERY = "query($n:String!){findEpisodeByName(name:$n){number name baseDuration source timestamps{at type{name}}}}";

/// Build the POST body `{"query":...,"variables":{"n":"<escaped name>"}}`
/// into `out`. Returns the slice, or an empty slice if it doesn't fit.
pub fn buildRequestBody(name: []const u8, out: []u8) []const u8 {
    var w = Writer{ .buf = out };
    w.str("{\"query\":\"");
    w.str(QUERY);
    w.str("\",\"variables\":{\"n\":\"");
    w.jsonEsc(name);
    w.str("\"}}");
    if (w.overflow) return out[0..0];
    return out[0..w.len];
}

const Writer = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,

    fn byte(self: *Writer, ch: u8) void {
        if (self.len >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.len] = ch;
        self.len += 1;
    }
    fn str(self: *Writer, s: []const u8) void {
        for (s) |ch| self.byte(ch);
    }
    /// Escape a string for embedding inside a JSON string literal.
    fn jsonEsc(self: *Writer, s: []const u8) void {
        for (s) |ch| {
            switch (ch) {
                '"' => self.str("\\\""),
                '\\' => self.str("\\\\"),
                '\n' => self.str("\\n"),
                '\r' => self.str("\\r"),
                '\t' => self.str("\\t"),
                0...8, 11, 12, 14...31 => {}, // drop other control chars
                else => self.byte(ch),
            }
        }
    }
};

// ── Response parsing ─────────────────────────────────────────────────────
const TsType = struct { name: []const u8 = "" };
const Ts = struct { at: f64 = 0, type: TsType = .{} };
const Ep = struct {
    source: []const u8 = "",
    baseDuration: ?f64 = null,
    timestamps: []Ts = &.{},
};
const RespData = struct { findEpisodeByName: []Ep = &.{} };
const Resp = struct { data: RespData = .{} };

/// Parse an anime-skip `findEpisodeByName` response into `out` markers.
///
/// Multiple ThirdPartyEpisode entries can share the same episode name (the
/// same title reused across shows). Pick-best heuristic:
///   1. Prefer `source == "ANIME_SKIP"` (anime-skip's own curated data).
///   2. Among candidates, the one whose `baseDuration` is closest to the
///      player's known duration (`known_duration`, 0 = unknown → skip step 2).
///   3. Else the first entry with any timestamps.
/// Markers are copied into `out` and SORTED ascending by `at`. Malformed or
/// empty JSON returns 0 (never crashes). Returns the marker count.
pub fn parseResponse(allocator: std.mem.Allocator, json: []const u8, known_duration: f64, out: []Marker) usize {
    const parsed = std.json.parseFromSlice(Resp, allocator, json, .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();

    const eps = parsed.value.data.findEpisodeByName;
    if (eps.len == 0) return 0;

    // Pick the best episode.
    var best: ?*const Ep = null;
    var best_score: i64 = std.math.minInt(i64);
    for (eps) |*ep| {
        if (ep.timestamps.len == 0) continue;
        var score: i64 = 0;
        if (std.ascii.eqlIgnoreCase(ep.source, "ANIME_SKIP")) score += 1_000_000;
        if (known_duration > 0) {
            if (ep.baseDuration) |bd| {
                const diff = @abs(bd - known_duration);
                // Closer duration = higher score (subtract the gap in seconds).
                score -= @intFromFloat(@min(diff, 900_000));
            }
        }
        if (best == null or score > best_score) {
            best = ep;
            best_score = score;
        }
    }

    const chosen = best orelse return 0;

    var n: usize = 0;
    for (chosen.timestamps) |ts| {
        if (n >= out.len) break;
        var m = Marker{ .at = ts.at };
        const tn = ts.type.name;
        const cn = @min(tn.len, TYPE_NAME_CAP);
        @memcpy(m.type_name[0..cn], tn[0..cn]);
        m.type_len = cn;
        out[n] = m;
        n += 1;
    }

    // Sort ascending by `at` — anime-skip does not guarantee order.
    std.mem.sort(Marker, out[0..n], {}, struct {
        fn lt(_: void, a: Marker, b: Marker) bool {
            return a.at < b.at;
        }
    }.lt);

    return n;
}

// ── Point markers → ranges ───────────────────────────────────────────────
/// Convert POINT markers into [start, end) segments: each marker runs until
/// the next marker's `at`; the LAST marker runs to `duration` (or a large
/// sentinel when duration is unknown, i.e. <= 0). `markers` must be sorted
/// ascending. Returns the segment count written to `out`.
pub fn buildSkipSegments(markers: []const Marker, duration: f64, out: []Segment) usize {
    const end_sentinel: f64 = if (duration > 0) duration else 1.0e12;
    var n: usize = 0;
    for (markers, 0..) |m, i| {
        if (n >= out.len) break;
        const end = if (i + 1 < markers.len) markers[i + 1].at else end_sentinel;
        out[n] = .{
            .start = m.at,
            .end = end,
            .category = categorize(m.name()),
        };
        n += 1;
    }
    return n;
}

// ── Skip decision ────────────────────────────────────────────────────────
/// Given the current playback position and the segment list, return a seek
/// target if `pos` is inside a skippable (enabled) segment, else null.
///
/// Membership is [start, end): a marker exactly at its `at` is inside; a
/// position exactly at `end` belongs to the NEXT segment. `already_skipped`
/// is the seg_index most recently skipped (-1 = none) — the once-per-segment
/// latch so a single segment fires exactly one seek instead of re-seeking
/// every tick.
pub fn shouldSkip(pos: f64, segs: []const Segment, prefs: Prefs, already_skipped: i32) ?SkipDecision {
    for (segs, 0..) |s, i| {
        if (pos < s.start or pos >= s.end) continue;
        if (!enabled(s.category, prefs)) return null; // inside, but not opted-in
        if (already_skipped >= 0 and @as(usize, @intCast(already_skipped)) == i) return null;
        return .{ .target = s.end, .seg_index = i, .category = s.category };
    }
    return null;
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════
const testing = std.testing;

fn mk(at: f64, name: []const u8) Marker {
    var m = Marker{ .at = at };
    @memcpy(m.type_name[0..name.len], name);
    m.type_len = name.len;
    return m;
}

test "categorize maps all known type names" {
    try testing.expectEqual(Category.intro, categorize("Intro"));
    try testing.expectEqual(Category.intro, categorize("New Intro"));
    try testing.expectEqual(Category.recap, categorize("Recap"));
    try testing.expectEqual(Category.credits, categorize("Credits"));
    try testing.expectEqual(Category.credits, categorize("Mixed Credits"));
    try testing.expectEqual(Category.credits, categorize("New Credits"));
    try testing.expectEqual(Category.credits, categorize("Ending"));
    try testing.expectEqual(Category.preview, categorize("Preview"));
    try testing.expectEqual(Category.filler, categorize("Filler"));
    try testing.expectEqual(Category.canon, categorize("Canon"));
    try testing.expectEqual(Category.must_watch, categorize("Must Watch"));
    try testing.expectEqual(Category.branding, categorize("Branding"));
    try testing.expectEqual(Category.title_card, categorize("Title Card"));
    try testing.expectEqual(Category.transition, categorize("Transition"));
    try testing.expectEqual(Category.other, categorize("Something Else"));
    // case-insensitive
    try testing.expectEqual(Category.intro, categorize("intro"));
}

test "skipButtonLabel names the four toggle categories, else generic" {
    try testing.expectEqualStrings("\xE2\x8F\xAD Skip Intro", skipButtonLabel(.intro));
    try testing.expectEqualStrings("\xE2\x8F\xAD Skip Recap", skipButtonLabel(.recap));
    try testing.expectEqualStrings("\xE2\x8F\xAD Skip Credits", skipButtonLabel(.credits));
    try testing.expectEqualStrings("\xE2\x8F\xAD Skip Preview", skipButtonLabel(.preview));
    // Non-offered categories fall back to a generic label.
    try testing.expectEqualStrings("\xE2\x8F\xAD Skip", skipButtonLabel(.filler));
    try testing.expectEqualStrings("\xE2\x8F\xAD Skip", skipButtonLabel(.other));
}

test "enabled respects prefs; non-toggle categories never enabled" {
    const p = Prefs{ .intro = true, .recap = true, .credits = false, .preview = false };
    try testing.expect(enabled(.intro, p));
    try testing.expect(enabled(.recap, p));
    try testing.expect(!enabled(.credits, p));
    try testing.expect(!enabled(.preview, p));
    try testing.expect(!enabled(.filler, p));
    try testing.expect(!enabled(.canon, p));
    try testing.expect(!enabled(.branding, p));
}

test "buildRequestBody embeds query, name, and escapes quotes/backslashes" {
    var buf: [512]u8 = undefined;
    const body = buildRequestBody("Fullmetal \"Al\" \\ Test", &buf);
    try testing.expect(std.mem.indexOf(u8, body, "findEpisodeByName") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\\\"Al\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\\\\ Test") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"variables\"") != null);
}

test "buildRequestBody overflow returns empty" {
    var tiny: [8]u8 = undefined;
    const body = buildRequestBody("some long episode name", &tiny);
    try testing.expectEqual(@as(usize, 0), body.len);
}

test "buildSkipSegments point->range including single and empty" {
    var out: [MAX_SEGMENTS]Segment = undefined;

    // empty
    try testing.expectEqual(@as(usize, 0), buildSkipSegments(&.{}, 1440, &out));

    // single marker → runs to duration
    const one = [_]Marker{mk(90, "Intro")};
    const n1 = buildSkipSegments(&one, 1440, &out);
    try testing.expectEqual(@as(usize, 1), n1);
    try testing.expectEqual(@as(f64, 90), out[0].start);
    try testing.expectEqual(@as(f64, 1440), out[0].end);
    try testing.expectEqual(Category.intro, out[0].category);

    // single marker, unknown duration → sentinel
    const n1b = buildSkipSegments(&one, 0, &out);
    try testing.expectEqual(@as(usize, 1), n1b);
    try testing.expect(out[0].end > 1.0e11);

    // three markers → two internal ranges + last to duration
    const three = [_]Marker{ mk(0, "Recap"), mk(85, "Intro"), mk(1380, "Credits") };
    const n3 = buildSkipSegments(&three, 1440, &out);
    try testing.expectEqual(@as(usize, 3), n3);
    try testing.expectEqual(@as(f64, 0), out[0].start);
    try testing.expectEqual(@as(f64, 85), out[0].end);
    try testing.expectEqual(@as(f64, 85), out[1].start);
    try testing.expectEqual(@as(f64, 1380), out[1].end);
    try testing.expectEqual(@as(f64, 1380), out[2].start);
    try testing.expectEqual(@as(f64, 1440), out[2].end);
}

test "shouldSkip boundaries and once-per-segment latch" {
    // Intro 85..105 (enabled), Credits 1380..1440 (disabled by default prefs)
    const segs = [_]Segment{
        .{ .start = 85, .end = 105, .category = .intro },
        .{ .start = 1380, .end = 1440, .category = .credits },
    };
    const prefs = Prefs{ .intro = true, .recap = true, .credits = false, .preview = false };

    // just before intro → no skip
    try testing.expect(shouldSkip(84.9, &segs, prefs, -1) == null);
    // exactly at start (inclusive) → skip to end
    {
        const d = shouldSkip(85, &segs, prefs, -1).?;
        try testing.expectEqual(@as(f64, 105), d.target);
        try testing.expectEqual(@as(usize, 0), d.seg_index);
    }
    // inside → skip
    try testing.expect(shouldSkip(95, &segs, prefs, -1) != null);
    // exactly at end (exclusive) → not in intro; not in credits either → null
    try testing.expect(shouldSkip(105, &segs, prefs, -1) == null);
    // once-per-segment latch: same seg already skipped → null
    try testing.expect(shouldSkip(95, &segs, prefs, 0) == null);
    // credits disabled → null even though inside
    try testing.expect(shouldSkip(1400, &segs, prefs, -1) == null);
    // credits enabled → skip to end (duration)
    {
        const p2 = Prefs{ .intro = true, .recap = true, .credits = true, .preview = false };
        const d = shouldSkip(1400, &segs, p2, -1).?;
        try testing.expectEqual(@as(f64, 1440), d.target);
        try testing.expectEqual(@as(usize, 1), d.seg_index);
    }
}

test "parseResponse extracts, sorts, picks ANIME_SKIP source" {
    // Two episodes with the same name: a non-anime-skip one first, the
    // curated ANIME_SKIP one second. Timestamps intentionally out of order.
    const json =
        \\{"data":{"findEpisodeByName":[
        \\  {"number":"1","name":"E","baseDuration":1400,"source":"OTHER","timestamps":[{"at":10,"type":{"name":"Intro"}}]},
        \\  {"number":"1","name":"E","baseDuration":1440,"source":"ANIME_SKIP","timestamps":[
        \\     {"at":1380,"type":{"name":"Credits"}},
        \\     {"at":85,"type":{"name":"Intro"}},
        \\     {"at":0,"type":{"name":"Recap"}}]}
        \\]}}
    ;
    var out: [MAX_MARKERS]Marker = undefined;
    const n = parseResponse(testing.allocator, json, 0, &out);
    try testing.expectEqual(@as(usize, 3), n);
    // sorted ascending
    try testing.expectEqual(@as(f64, 0), out[0].at);
    try testing.expectEqual(@as(f64, 85), out[1].at);
    try testing.expectEqual(@as(f64, 1380), out[2].at);
    try testing.expectEqualStrings("Recap", out[0].name());
    try testing.expectEqualStrings("Intro", out[1].name());
    try testing.expectEqualStrings("Credits", out[2].name());
}

test "parseResponse best-duration tiebreak when no ANIME_SKIP" {
    const json =
        \\{"data":{"findEpisodeByName":[
        \\  {"source":"A","baseDuration":600,"timestamps":[{"at":5,"type":{"name":"Intro"}}]},
        \\  {"source":"B","baseDuration":1440,"timestamps":[{"at":88,"type":{"name":"Intro"}}]}
        \\]}}
    ;
    var out: [MAX_MARKERS]Marker = undefined;
    // known duration 1450 → the 1440 entry wins
    const n = parseResponse(testing.allocator, json, 1450, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(f64, 88), out[0].at);
}

test "parseResponse malformed / empty does not crash" {
    var out: [MAX_MARKERS]Marker = undefined;
    try testing.expectEqual(@as(usize, 0), parseResponse(testing.allocator, "", 0, &out));
    try testing.expectEqual(@as(usize, 0), parseResponse(testing.allocator, "not json", 0, &out));
    try testing.expectEqual(@as(usize, 0), parseResponse(testing.allocator, "{}", 0, &out));
    try testing.expectEqual(@as(usize, 0), parseResponse(testing.allocator, "{\"data\":{\"findEpisodeByName\":[]}}", 0, &out));
    // episode present but no timestamps → 0
    try testing.expectEqual(@as(usize, 0), parseResponse(testing.allocator, "{\"data\":{\"findEpisodeByName\":[{\"source\":\"ANIME_SKIP\",\"timestamps\":[]}]}}", 0, &out));
}

test "end-to-end: parse → segments → skip" {
    const json =
        \\{"data":{"findEpisodeByName":[
        \\  {"source":"ANIME_SKIP","baseDuration":1440,"timestamps":[
        \\     {"at":85,"type":{"name":"Intro"}},
        \\     {"at":105,"type":{"name":"Canon"}},
        \\     {"at":1380,"type":{"name":"Credits"}}]}
        \\]}}
    ;
    var markers: [MAX_MARKERS]Marker = undefined;
    const nm = parseResponse(testing.allocator, json, 1440, &markers);
    try testing.expectEqual(@as(usize, 3), nm);

    var segs: [MAX_SEGMENTS]Segment = undefined;
    const ns = buildSkipSegments(markers[0..nm], 1440, &segs);
    try testing.expectEqual(@as(usize, 3), ns);

    const prefs = Prefs{ .intro = true, .recap = true, .credits = false, .preview = false };
    // inside intro → skip to 105 (start of Canon)
    const d = shouldSkip(90, segs[0..ns], prefs, -1).?;
    try testing.expectEqual(@as(f64, 105), d.target);
    try testing.expectEqual(Category.intro, d.category);
    // inside canon (not skippable) → null
    try testing.expect(shouldSkip(110, segs[0..ns], prefs, -1) == null);
}
