//! Pure helpers for the anime airing-schedule view ("Airing this week") — no
//! app-state / io_global imports, so the logic ships tested (see build.zig
//! `test` step). anime_schedule.zig routes production through these functions.
//!
//! Source: AniList's public GraphQL `Page.airingSchedules` query. It returns
//!   {"data":{"Page":{"airingSchedules":[
//!     {"episode":5,"airingAt":1721000000,
//!      "media":{"title":{"romaji":"..","english":".."},"coverImage":{"medium":".."}}}
//!   ]}}}
//! `Iter` walks that array allocator-free, yielding slices INTO the source JSON;
//! `parseInto` copies each into a fixed-buffer Slot. Every extractor tolerates
//! missing / null / truncated fields so a malformed response can never panic a
//! worker thread (a worker panic aborts the whole app).
//!
//! TIME NOTE: the weekday / clock helpers take an epoch that the CALLER has
//! already shifted into local time (airing_at + tz_offset_s). Keeping the shift
//! at the call site means these stay pure integer math — no clock read, no
//! std.time.timestamp() (banned in Zig 0.16). Signed-int `{d:0>2}` prints a
//! forced sign in 0.16, so every value is cast to an UNSIGNED int first.

const std = @import("std");

const SECS_PER_DAY: i64 = 86400;

// ══════════════════════════════════════════════════════════
// Week window + GraphQL body
// ══════════════════════════════════════════════════════════

pub const Window = struct { start: i64, end: i64 };

/// The [start, end) unix window for "this week": from the start of the current
/// LOCAL day through +7 days. `now_s` is the current unix (UTC) time and
/// `tz_offset_s` the local UTC offset. `start` is the UTC INSTANT of local
/// midnight, so day buckets (dayIndexOf) line up with the user's calendar. Uses
/// @mod so a pre-1970 (negative) clock still floors correctly.
pub fn weekWindow(now_s: i64, tz_offset_s: i64) Window {
    const local = now_s + tz_offset_s;
    const local_midnight = local - @mod(local, SECS_PER_DAY); // in the local frame
    const start = local_midnight - tz_offset_s; // back to the UTC instant
    return .{ .start = start, .end = start + 7 * SECS_PER_DAY };
}

/// Build the AniList `airingSchedules` GraphQL request body (JSON) for `w` into
/// `out`. `sort: TIME` gives chronological order, so the render just walks it.
/// Returns the formatted slice, or "" on a bufPrint overflow (caller aborts).
pub fn buildQuery(w: Window, out: []u8) []const u8 {
    return std.fmt.bufPrint(out,
        \\{{"query":"query {{ Page(perPage: 50) {{ airingSchedules(airingAt_greater: {d}, airingAt_lesser: {d}, sort: TIME) {{ episode airingAt media {{ title {{ romaji english }} coverImage {{ medium }} }} }} }} }}"}}
    , .{ w.start, w.end }) catch "";
}

// ══════════════════════════════════════════════════════════
// Weekday / clock formatting (local epoch in → label out)
// ══════════════════════════════════════════════════════════

const DAYS = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

/// Weekday index (0=Monday … 6=Sunday) for a LOCAL epoch. 1970-01-01 was a
/// Thursday (index 3 in the Mon=0 scheme), so day-number + 3 (mod 7) maps it.
pub fn weekdayMon0(local_epoch_s: i64) u8 {
    const day = @divFloor(local_epoch_s, SECS_PER_DAY);
    return @intCast(@mod(day + 3, 7));
}

/// Human weekday name for a Mon=0 index (bounds-safe).
pub fn weekdayName(mon0: u8) []const u8 {
    return if (mon0 < DAYS.len) DAYS[mon0] else "?";
}

/// "HH:MM" (24h) for a LOCAL epoch. Cast to unsigned before `{d:0>2}` — Zig
/// 0.16 prints a signed int under that spec with a forced sign.
pub fn fmtTime(local_epoch_s: i64, out: []u8) []const u8 {
    const sod = @mod(local_epoch_s, SECS_PER_DAY); // 0..86399, always ≥ 0
    const hour: u32 = @intCast(@divFloor(sod, 3600));
    const min: u32 = @intCast(@divFloor(@mod(sod, 3600), 60));
    return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}", .{ hour, min }) catch "??:??";
}

/// Which of the 7 window days (0 = window.start's day … 6) a schedule slot falls
/// in, or null when it lands outside the week. `window_start` is the UTC instant
/// of local midnight (see weekWindow), so days are exact 86400s steps from it and
/// no tz shift is needed here — measuring the slot's offset from local midnight
/// already gives the local calendar day. Boundaries: exactly window_start → day
/// 0; the last second of day 0 → day 0; the first second of day 1 → day 1.
pub fn dayIndexOf(airing_at: i64, window_start: i64) ?u8 {
    if (airing_at < window_start) return null;
    const idx = @divFloor(airing_at - window_start, SECS_PER_DAY);
    if (idx < 0 or idx > 6) return null;
    return @intCast(idx);
}

/// Per-weekday (Mon=0) counts across `slots[0..count]`, using each slot's LOCAL
/// airing time. Testable summary of the group-by-weekday bucketing the render
/// walks. `tz_offset_s` shifts UTC airing times into the local frame.
pub fn bucketCounts(slots: []const Slot, count: usize, tz_offset_s: i64, out: *[7]usize) void {
    out.* = .{ 0, 0, 0, 0, 0, 0, 0 };
    const n = @min(count, slots.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const b = weekdayMon0(slots[i].airing_at + tz_offset_s);
        if (b < 7) out[b] += 1;
    }
}

// ══════════════════════════════════════════════════════════
// Parse
// ══════════════════════════════════════════════════════════

/// One parsed airing entry as slices INTO the source JSON (allocator-free, still
/// JSON-escaped). The caller copies into a fixed-buffer Slot.
pub const Raw = struct {
    episode: i32 = 0,
    airing_at: i64 = 0,
    title: []const u8 = "",
    cover: []const u8 = "",
};

/// One published schedule slot (fixed buffers, so state save/restore stays a
/// memcpy). Referenced from state.zig's `anime` struct.
pub const Slot = struct {
    episode: i32 = 0,
    airing_at: i64 = 0,
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    cover: [128]u8 = std.mem.zeroes([128]u8),
    cover_len: usize = 0,
};

fn indexAfter(hay: []const u8, needle: []const u8) ?usize {
    const i = std.mem.indexOf(u8, hay, needle) orelse return null;
    return i + needle.len;
}

/// Integer value following `key`. Skips one leading space and an optional `-`.
/// Returns null when the key is absent or the value is non-numeric.
fn fieldInt(slice: []const u8, key: []const u8) ?i64 {
    var p = indexAfter(slice, key) orelse return null;
    if (p < slice.len and slice[p] == ' ') p += 1;
    var neg = false;
    if (p < slice.len and slice[p] == '-') {
        neg = true;
        p += 1;
    }
    const st = p;
    while (p < slice.len and slice[p] >= '0' and slice[p] <= '9') p += 1;
    if (p == st) return null;
    const v = std.fmt.parseInt(i64, slice[st..p], 10) catch return null;
    return if (neg) -v else v;
}

/// String value following `quoted_key` (which includes the opening quote, e.g.
/// `"\"english\":\""`). Reads until the next UNESCAPED `"`. Returns "" when the
/// key is absent (so `"english":null` yields "") or the string is unterminated.
fn fieldStr(slice: []const u8, quoted_key: []const u8) []const u8 {
    const st = indexAfter(slice, quoted_key) orelse return "";
    var end = st;
    var esc = false;
    while (end < slice.len) : (end += 1) {
        if (esc) {
            esc = false;
        } else if (slice[end] == '\\') {
            esc = true;
        } else if (slice[end] == '"') {
            break;
        }
    }
    if (end >= slice.len) return ""; // unterminated → malformed → empty
    return slice[st..end];
}

/// english → romaji, first non-empty (AniList often leaves `english` null).
pub fn pickTitle(english: []const u8, romaji: []const u8) []const u8 {
    if (english.len > 0) return english;
    return romaji;
}

/// Walks `data.Page.airingSchedules[]`, anchoring on each object's leading
/// `"episode":` (the first field AniList emits per entry, and one that never
/// occurs inside the requested media sub-objects). Each object slice runs from
/// one `"episode":` to the next, so field order within the object is irrelevant.
pub const Iter = struct {
    json: []const u8,
    pos: usize = 0,

    const KEY = "\"episode\":";

    pub fn next(self: *Iter) ?Raw {
        const rel = std.mem.indexOf(u8, self.json[self.pos..], KEY) orelse return null;
        const start = self.pos + rel;
        var end = self.json.len;
        if (std.mem.indexOf(u8, self.json[start + KEY.len ..], KEY)) |n| {
            end = start + KEY.len + n;
        }
        const slice = self.json[start..end];
        self.pos = end;

        var r = Raw{};
        if (fieldInt(slice, "\"episode\":")) |v| {
            if (v > 0 and v < 100000) r.episode = @intCast(v);
        }
        if (fieldInt(slice, "\"airingAt\":")) |v| r.airing_at = v;
        r.title = pickTitle(
            fieldStr(slice, "\"english\":\""),
            fieldStr(slice, "\"romaji\":\""),
        );
        r.cover = fieldStr(slice, "\"medium\":\"");
        return r;
    }
};

/// Parse the AniList airingSchedules response into `out`, copying titles/covers
/// into fixed buffers. Drops entries with no airing time or no title (a blank
/// row). Returns the number of slots written (≤ out.len). Allocator-free.
pub fn parseInto(json: []const u8, out: []Slot) usize {
    if (out.len == 0) return 0;
    var it = Iter{ .json = json };
    var n: usize = 0;
    while (it.next()) |raw| {
        if (n >= out.len) break;
        if (raw.airing_at <= 0) continue;
        if (raw.title.len == 0) continue;
        var s = &out[n];
        s.* = .{};
        s.episode = raw.episode;
        s.airing_at = raw.airing_at;
        s.title_len = copyInto(&s.title, raw.title);
        s.cover_len = copyInto(&s.cover, raw.cover);
        n += 1;
    }
    return n;
}

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "weekWindow floors to local midnight and spans 7 days" {
    // 2021-01-01 12:34:56 UTC = 1609504496; UTC day start = 1609459200.
    const w = weekWindow(1609504496, 0); // UTC
    try std.testing.expectEqual(@as(i64, 1609459200), w.start);
    try std.testing.expectEqual(@as(i64, 1609459200 + 7 * 86400), w.end);
    // Exactly a UTC-day boundary at tz 0 stays put.
    const w2 = weekWindow(1609459200, 0);
    try std.testing.expectEqual(@as(i64, 1609459200), w2.start);
    // With a +2h offset, "now" 00:30 UTC is already 02:30 local on the same day,
    // so start = local midnight = 1609459200 - 2h (the UTC instant of 00:00 local).
    const w3 = weekWindow(1609459200 + 1800, 2 * 3600);
    try std.testing.expectEqual(@as(i64, 1609459200 - 2 * 3600), w3.start);
}

test "buildQuery embeds the window bounds and is valid-ish JSON" {
    var buf: [512]u8 = undefined;
    const q = buildQuery(.{ .start = 100, .end = 200 }, &buf);
    try std.testing.expect(std.mem.indexOf(u8, q, "airingAt_greater: 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "airingAt_lesser: 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "airingSchedules") != null);
    try std.testing.expect(std.mem.startsWith(u8, q, "{\"query\":"));
}

test "weekdayMon0 anchors 1970-01-01 to Thursday and rolls Mon..Sun" {
    try std.testing.expectEqual(@as(u8, 3), weekdayMon0(0)); // Thu
    try std.testing.expectEqual(@as(u8, 4), weekdayMon0(86400)); // Fri
    try std.testing.expectEqual(@as(u8, 0), weekdayMon0(4 * 86400)); // Mon 1970-01-05
    try std.testing.expectEqualStrings("Monday", weekdayName(weekdayMon0(4 * 86400)));
    try std.testing.expectEqualStrings("Sunday", weekdayName(6));
    try std.testing.expectEqualStrings("?", weekdayName(9));
}

test "fmtTime pads and never emits a sign (Zig 0.16 signed-zero-pad bug)" {
    var buf: [8]u8 = undefined;
    // 09:05 UTC on some day: 9*3600 + 5*60 = 32700.
    try std.testing.expectEqualStrings("09:05", fmtTime(32700, &buf));
    try std.testing.expectEqualStrings("00:00", fmtTime(0, &buf));
    try std.testing.expectEqualStrings("23:59", fmtTime(86399, &buf));
    // A large real epoch must still pad both fields with no leading '+'.
    const out = fmtTime(1609504496, &buf); // 12:34:56 UTC → "12:34"
    try std.testing.expectEqualStrings("12:34", out);
}

test "dayIndexOf buckets across the 7-day window, honoring boundaries" {
    // window_start is the UTC instant of local midnight (see weekWindow).
    const start: i64 = 1609459200;
    try std.testing.expectEqual(@as(?u8, 0), dayIndexOf(start, start));
    try std.testing.expectEqual(@as(?u8, 0), dayIndexOf(start + 86399, start)); // last sec of day 0
    try std.testing.expectEqual(@as(?u8, 1), dayIndexOf(start + 86400, start)); // first sec of day 1
    try std.testing.expectEqual(@as(?u8, 6), dayIndexOf(start + 6 * 86400, start));
    try std.testing.expectEqual(@as(?u8, null), dayIndexOf(start - 1, start)); // before window
    try std.testing.expectEqual(@as(?u8, null), dayIndexOf(start + 7 * 86400, start)); // at/after end
    // End-to-end with a +2h tz: a slot at 23:00 local on day 0 buckets to day 0,
    // and 01:00 local the next calendar day buckets to day 1.
    const w = weekWindow(start + 3600, 2 * 3600); // "now" ~ 01:00 local, day-0 midnight
    const slot_2300_local = w.start + 23 * 3600; // 23:00 local, day 0
    const slot_0100_next = w.start + 25 * 3600; // 01:00 local, day 1
    try std.testing.expectEqual(@as(?u8, 0), dayIndexOf(slot_2300_local, w.start));
    try std.testing.expectEqual(@as(?u8, 1), dayIndexOf(slot_0100_next, w.start));
}

test "Iter parses a well-formed airingSchedules array" {
    const json =
        \\{"data":{"Page":{"airingSchedules":[
        \\{"episode":5,"airingAt":1721000000,"media":{"title":{"romaji":"Foo","english":"Foo EN"},"coverImage":{"medium":"https://img/a.jpg"}}},
        \\{"episode":1,"airingAt":1721086400,"media":{"title":{"romaji":"Bar","english":null},"coverImage":{"medium":"https://img/b.jpg"}}}
        \\]}}}
    ;
    var it = Iter{ .json = json };
    const a = it.next().?;
    try std.testing.expectEqual(@as(i32, 5), a.episode);
    try std.testing.expectEqual(@as(i64, 1721000000), a.airing_at);
    try std.testing.expectEqualStrings("Foo EN", a.title); // english preferred
    try std.testing.expectEqualStrings("https://img/a.jpg", a.cover);

    const b = it.next().?;
    try std.testing.expectEqual(@as(i32, 1), b.episode);
    try std.testing.expectEqualStrings("Bar", b.title); // english:null → romaji fallback

    try std.testing.expect(it.next() == null);
}

test "parseInto copies into fixed buffers and drops blank/timeless rows" {
    const json =
        \\{"data":{"Page":{"airingSchedules":[
        \\{"episode":3,"airingAt":1721000000,"media":{"title":{"romaji":"Alpha","english":"Alpha"},"coverImage":{"medium":"c1"}}},
        \\{"episode":9,"airingAt":0,"media":{"title":{"romaji":"NoTime","english":"NoTime"},"coverImage":{"medium":"c2"}}},
        \\{"episode":4,"airingAt":1721100000,"media":{"title":{"romaji":"","english":null},"coverImage":{"medium":"c3"}}}
        \\]}}}
    ;
    var slots: [8]Slot = undefined;
    const n = parseInto(json, &slots);
    try std.testing.expectEqual(@as(usize, 1), n); // timeless + titleless dropped
    try std.testing.expectEqual(@as(i32, 3), slots[0].episode);
    try std.testing.expectEqual(@as(i64, 1721000000), slots[0].airing_at);
    try std.testing.expectEqualStrings("Alpha", slots[0].title[0..slots[0].title_len]);
    try std.testing.expectEqualStrings("c1", slots[0].cover[0..slots[0].cover_len]);
}

test "bucketCounts groups by local weekday" {
    var slots: [3]Slot = std.mem.zeroes([3]Slot);
    slots[0].airing_at = 4 * 86400; // Mon
    slots[1].airing_at = 4 * 86400 + 3600; // Mon
    slots[2].airing_at = 5 * 86400; // Tue
    var counts: [7]usize = undefined;
    bucketCounts(&slots, 3, 0, &counts);
    try std.testing.expectEqual(@as(usize, 2), counts[0]); // Mon
    try std.testing.expectEqual(@as(usize, 1), counts[1]); // Tue
    try std.testing.expectEqual(@as(usize, 0), counts[2]);
}

test "parse regression: truncated / malformed JSON never panics" {
    // Cut off mid-string: episode/airingAt parse, unterminated english yields ""
    // so the title falls back to romaji, and next() ends cleanly.
    const truncated =
        \\{"data":{"Page":{"airingSchedules":[{"episode":2,"airingAt":1721000000,"media":{"title":{"romaji":"Romy","english":"Trunc
    ;
    var it = Iter{ .json = truncated };
    const m = it.next().?;
    try std.testing.expectEqual(@as(i64, 1721000000), m.airing_at);
    try std.testing.expectEqualStrings("Romy", m.title); // unterminated english → romaji
    try std.testing.expect(it.next() == null);

    // Garbage / empty / no-schedule payloads all terminate cleanly.
    var e1 = Iter{ .json = "" };
    try std.testing.expect(e1.next() == null);
    var e2 = Iter{ .json = "not json at all" };
    try std.testing.expect(e2.next() == null);
    var e3 = Iter{ .json = "{\"data\":{\"Page\":{\"airingSchedules\":[]}}}" };
    try std.testing.expect(e3.next() == null);
    var e4 = Iter{ .json = "{\"errors\":[{\"message\":\"boom\"}]}" };
    try std.testing.expect(e4.next() == null);

    var slots: [4]Slot = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseInto("garbage", &slots));
}
