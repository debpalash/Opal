//! Kid-mode maturity scale and the list / playback decisions built on it.
//!
//! One scale: a minimum age. US film (G, PG, PG-13, R, NC-17), US TV (TV-Y ...
//! TV-MA) and the regional ratings in profiles_pure.certAge all map onto it; a
//! profile's cap is the highest age it admits. The tiers below are the caps the
//! profile UI, web UI and API offer, each named by its film and TV rating.
//!
//! Decisions (the shipped logic; services/profiles_maturity.zig calls these):
//!   * listVisible  - may a catalog / search / rail / recommendation row show?
//!     A kid profile hides anything it cannot prove is within the cap: a rating
//!     still being fetched, or no rating at all (unless the parent allowed
//!     unrated titles).
//!   * playDecision - may a title start? Same rule, with the reason kept so the
//!     app and the API can say why.
//!   * loosens      - does an edit widen what a kid profile can see? Those edits
//!     (higher cap, unrated allowed, kid mode off) need the parent PIN.

const std = @import("std");
const profiles_pure = @import("profiles_pure.zig");

pub const NO_CAP = profiles_pure.NO_CAP;

pub const Tier = struct {
    age: u8,
    /// Short label for a segmented control.
    short: []const u8,
    /// Film / TV ratings this tier admits at most.
    film: []const u8,
    tv: []const u8,
};

/// Caps in ascending order.
pub const TIERS = [_]Tier{
    .{ .age = 0, .short = "G", .film = "G", .tv = "TV-G" },
    .{ .age = 7, .short = "TV-Y7", .film = "G", .tv = "TV-Y7" },
    .{ .age = 8, .short = "PG", .film = "PG", .tv = "TV-PG" },
    .{ .age = 13, .short = "PG-13", .film = "PG-13", .tv = "TV-PG" },
    .{ .age = 14, .short = "TV-14", .film = "PG-13", .tv = "TV-14" },
    .{ .age = 17, .short = "R", .film = "R", .tv = "TV-MA" },
    .{ .age = 18, .short = "NC-17", .film = "NC-17", .tv = "TV-MA" },
};

pub const TIER_SHORT = blk: {
    var out: [TIERS.len][]const u8 = undefined;
    for (TIERS, 0..) |t, i| out[i] = t.short;
    break :blk out;
};

/// Cap a new kid profile starts with: PG / TV-PG.
pub const KID_DEFAULT_CAP: u8 = profiles_pure.KID_DEFAULT_CAP;

/// Snap a stored cap onto the scale: the highest tier at or below it, so an
/// old free-form cap (10, 12, 16) only ever tightens. NO_CAP is unchanged.
pub fn normalizeCap(cap: u8) u8 {
    if (cap == NO_CAP) return NO_CAP;
    var best: u8 = TIERS[0].age;
    for (TIERS) |t| {
        if (t.age <= cap) best = t.age;
    }
    return best;
}

/// Index into TIERS for a cap (after normalizing).
pub fn tierIndex(cap: u8) usize {
    const c = normalizeCap(if (cap == NO_CAP) TIERS[TIERS.len - 1].age else cap);
    for (TIERS, 0..) |t, i| if (t.age == c) return i;
    return 0;
}

/// "PG-13 / TV-PG" style label, or "No limit".
pub fn capLabel(cap: u8, buf: []u8) []const u8 {
    if (cap == NO_CAP) return "No limit";
    const t = TIERS[tierIndex(cap)];
    if (std.mem.eql(u8, t.film, t.tv)) return t.film;
    return std.fmt.bufPrint(buf, "{s} / {s}", .{ t.film, t.tv }) catch t.short;
}

/// Parse a cap from the API / web form: a tier name ("PG-13", "tv-14"), any
/// certification profiles_pure knows ("12A", "FSK 16"), or a bare age.
/// Returns the normalized cap, or null when unparseable.
pub fn parseCap(raw: []const u8) ?u8 {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;
    for (TIERS) |t| if (std.ascii.eqlIgnoreCase(t.short, text)) return t.age;
    if (std.fmt.parseInt(u8, text, 10)) |n| {
        return if (n > 18) null else normalizeCap(n);
    } else |_| {}
    const age = profiles_pure.certAge(text) orelse return null;
    return normalizeCap(age);
}

/// A title's rating as far as the app knows right now.
pub const Rating = union(enum) {
    /// Not looked up yet (or the lookup is in flight).
    pending,
    /// Looked up: no usable certification anywhere (or no catalog identity).
    unrated,
    /// Minimum age from the certification.
    age: u8,

    pub fn fromAge(a: ?u8) Rating {
        return if (a) |v| .{ .age = v } else .unrated;
    }
};

/// Whether a row may be listed for a profile with `cap` (NO_CAP = adult).
/// Unknown is hidden for kids: pending always, unrated unless allowed.
pub fn listVisible(cap: u8, allow_unrated: bool, r: Rating) bool {
    if (cap == NO_CAP) return true;
    return switch (r) {
        .pending => false,
        .unrated => profiles_pure.maturityAllows(cap, null, allow_unrated),
        .age => |a| profiles_pure.maturityAllows(cap, a, allow_unrated),
    };
}

pub const Decision = enum {
    allow,
    /// Still looking the rating up; try again in a moment.
    checking,
    /// Rated above the cap.
    over_cap,
    /// No rating and the profile hides unrated titles.
    unrated,

    pub fn message(self: Decision) []const u8 {
        return switch (self) {
            .allow => "",
            .checking => "Checking the age rating...",
            .over_cap => "Rated above this profile's age limit",
            .unrated => "Not rated - not available on this profile",
        };
    }
};

pub fn playDecision(cap: u8, allow_unrated: bool, r: Rating) Decision {
    if (listVisible(cap, allow_unrated, r)) return .allow;
    return switch (r) {
        .pending => .checking,
        .unrated => .unrated,
        .age => .over_cap,
    };
}

pub const KidOptions = struct {
    kid: bool,
    cap: u8,
    allow_unrated: bool,
};

/// True when `next` lets a kid profile see something `prev` did not. Turning
/// kid mode on, lowering the cap or hiding unrated titles only tightens.
pub fn loosens(prev: KidOptions, next: KidOptions) bool {
    if (!prev.kid) return false;
    if (!next.kid) return true;
    if (normalizeCap(next.cap) > normalizeCap(prev.cap)) return true;
    return next.allow_unrated and !prev.allow_unrated;
}

/// Whether an edit changes what is enforced (a raw cap inside the same tier,
/// or a cap / unrated flag on a non-kid profile, is no change).
pub fn differs(prev: KidOptions, next: KidOptions) bool {
    if (prev.kid != next.kid) return true;
    if (!next.kid) return false;
    return normalizeCap(prev.cap) != normalizeCap(next.cap) or prev.allow_unrated != next.allow_unrated;
}

/// Keep, in order, only the items `ratingOf` says a profile may list. Returns
/// the kept count; items past it are unspecified.
pub fn filterInPlace(
    comptime Item: type,
    items: []Item,
    cap: u8,
    allow_unrated: bool,
    ctx: anytype,
    comptime ratingOf: fn (@TypeOf(ctx), *const Item) Rating,
) usize {
    if (cap == NO_CAP) return items.len;
    var kept: usize = 0;
    for (0..items.len) |i| {
        if (!listVisible(cap, allow_unrated, ratingOf(ctx, &items[i]))) continue;
        if (kept != i) items[kept] = items[i];
        kept += 1;
    }
    return kept;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

const T = std.testing;

test "film and TV ratings land on one age scale" {
    const c = profiles_pure.certAge;
    try T.expect(c("G").? <= c("TV-Y7").?);
    try T.expect(c("TV-Y7").? < c("PG").?);
    try T.expectEqual(c("PG").?, c("TV-PG").?);
    try T.expect(c("PG-13").? < c("TV-14").?);
    try T.expectEqual(c("R").?, c("TV-MA").?);
    try T.expect(c("R").? < c("NC-17").?);
    try T.expectEqual(@as(?u8, 0), c("TV-Y"));
    // Every tier admits exactly its own film and TV rating.
    for (TIERS) |t| {
        try T.expect(c(t.film).? <= t.age);
        try T.expect(c(t.tv).? <= t.age);
    }
}

test "tiers ascend and old free-form caps only tighten" {
    var prev: i16 = -1;
    for (TIERS) |t| {
        try T.expect(@as(i16, t.age) > prev);
        prev = t.age;
    }
    try T.expectEqual(@as(u8, 8), normalizeCap(12)); // old default -> PG
    try T.expectEqual(@as(u8, 8), normalizeCap(10));
    try T.expectEqual(@as(u8, 14), normalizeCap(16));
    try T.expectEqual(@as(u8, 13), normalizeCap(13));
    try T.expectEqual(@as(u8, 0), normalizeCap(5));
    try T.expectEqual(NO_CAP, normalizeCap(NO_CAP));
    try T.expectEqual(KID_DEFAULT_CAP, normalizeCap(KID_DEFAULT_CAP));
}

test "cap labels and parsing" {
    var b: [32]u8 = undefined;
    try T.expectEqualStrings("PG-13 / TV-PG", capLabel(13, &b));
    try T.expectEqualStrings("R / TV-MA", capLabel(17, &b));
    try T.expectEqualStrings("No limit", capLabel(NO_CAP, &b));
    try T.expectEqual(@as(?u8, 13), parseCap("pg-13"));
    try T.expectEqual(@as(?u8, 14), parseCap("TV-14"));
    try T.expectEqual(@as(?u8, 17), parseCap("TV-MA"));
    try T.expectEqual(@as(?u8, 8), parseCap("12A")); // UK 12 -> PG tier
    try T.expectEqual(@as(?u8, 14), parseCap("FSK 16"));
    try T.expectEqual(@as(?u8, 18), parseCap("18"));
    try T.expectEqual(@as(?u8, null), parseCap("99"));
    try T.expectEqual(@as(?u8, null), parseCap("NR"));
    try T.expectEqual(@as(?u8, null), parseCap(""));
    try T.expectEqual(@as(usize, 3), tierIndex(13));
    try T.expectEqual(TIERS.len - 1, tierIndex(NO_CAP));
}

test "unknown rating is hidden for kids; adults see everything" {
    try T.expect(!listVisible(13, false, .unrated));
    try T.expect(!listVisible(13, false, .pending));
    try T.expect(!listVisible(13, true, .pending)); // in flight is never shown
    try T.expect(listVisible(13, true, .unrated)); // parent opted in
    try T.expect(listVisible(13, false, .{ .age = 13 }));
    try T.expect(!listVisible(13, false, .{ .age = 14 }));
    try T.expect(listVisible(NO_CAP, false, .pending));
    try T.expect(listVisible(NO_CAP, false, .unrated));
    try T.expect(listVisible(NO_CAP, false, .{ .age = 18 }));
}

test "play decision keeps the reason" {
    try T.expectEqual(Decision.allow, playDecision(8, false, .{ .age = 0 }));
    try T.expectEqual(Decision.over_cap, playDecision(8, false, .{ .age = 17 }));
    try T.expectEqual(Decision.unrated, playDecision(8, false, .unrated));
    try T.expectEqual(Decision.checking, playDecision(8, false, .pending));
    try T.expectEqual(Decision.allow, playDecision(NO_CAP, false, .{ .age = 18 }));
    try T.expect(Decision.over_cap.message().len > 0);
}

test "only loosening edits need the parent PIN" {
    const kid13: KidOptions = .{ .kid = true, .cap = 13, .allow_unrated = false };
    try T.expect(loosens(kid13, .{ .kid = false, .cap = NO_CAP, .allow_unrated = false })); // leave kid mode
    try T.expect(loosens(kid13, .{ .kid = true, .cap = 17, .allow_unrated = false })); // raise cap
    try T.expect(loosens(kid13, .{ .kid = true, .cap = 13, .allow_unrated = true })); // allow unrated
    try T.expect(!loosens(kid13, .{ .kid = true, .cap = 8, .allow_unrated = false })); // lower cap
    try T.expect(!loosens(kid13, kid13));
    try T.expect(!loosens(.{ .kid = false, .cap = NO_CAP, .allow_unrated = false }, kid13)); // kid mode on
    // A raw value inside the same tier is not a raise.
    try T.expect(!loosens(kid13, .{ .kid = true, .cap = 13, .allow_unrated = false }));
    try T.expect(!loosens(.{ .kid = true, .cap = 14, .allow_unrated = false }, .{ .kid = true, .cap = 16, .allow_unrated = false }));
}

test "edit differs only when enforcement changes" {
    const kid13: KidOptions = .{ .kid = true, .cap = 13, .allow_unrated = false };
    try T.expect(!differs(kid13, kid13));
    try T.expect(differs(kid13, .{ .kid = true, .cap = 8, .allow_unrated = false }));
    try T.expect(differs(kid13, .{ .kid = true, .cap = 13, .allow_unrated = true }));
    try T.expect(differs(kid13, .{ .kid = false, .cap = NO_CAP, .allow_unrated = false }));
    const adult: KidOptions = .{ .kid = false, .cap = NO_CAP, .allow_unrated = false };
    try T.expect(!differs(adult, .{ .kid = false, .cap = 8, .allow_unrated = true }));
}

test "filter keeps allowed rows in order and hides unknown for kids" {
    const Row = struct { id: u8, r: Rating };
    const rows = [_]Row{
        .{ .id = 1, .r = .{ .age = 0 } },
        .{ .id = 2, .r = .{ .age = 17 } },
        .{ .id = 3, .r = .unrated },
        .{ .id = 4, .r = .pending },
        .{ .id = 5, .r = .{ .age = 8 } },
    };
    const get = struct {
        fn f(_: void, row: *const Row) Rating {
            return row.r;
        }
    }.f;
    var copy = rows;
    const n = filterInPlace(Row, &copy, 8, false, {}, get);
    try T.expectEqual(@as(usize, 2), n);
    try T.expectEqual(@as(u8, 1), copy[0].id);
    try T.expectEqual(@as(u8, 5), copy[1].id);
    copy = rows;
    try T.expectEqual(@as(usize, 3), filterInPlace(Row, &copy, 8, true, {}, get));
    copy = rows;
    try T.expectEqual(rows.len, filterInPlace(Row, &copy, NO_CAP, false, {}, get));
}
