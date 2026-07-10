//! Pure JSON parsing for the keyless TVmaze episode air-date enrichment — no
//! io/state imports, so the logic ships tested (see build.zig test step) and
//! the production tvmaze.zig routes every parse through here (no drift).
//!
//! Date math is reused from tv_calendar_pure (also pure) so a TVmaze airstamp
//! and a TMDB air_date format countdowns identically.

const std = @import("std");
const cal = @import("tv_calendar_pure.zig");

/// The show's next scheduled episode (from `/shows/{id}?embed=nextepisode` →
/// `_embedded.nextepisode`). Absent for ended shows.
pub const NextEp = struct {
    season: i32 = 0,
    number: i32 = 0,
    airstamp: [40]u8 = std.mem.zeroes([40]u8),
    airstamp_len: usize = 0,
};

/// One episode's air date, keyed by (season, number). Filled from the
/// `/shows/{id}/episodes` array; used to backfill rows where TMDB has no date.
pub const AirEntry = struct {
    season: i32 = 0,
    number: i32 = 0,
    airdate: [12]u8 = std.mem.zeroes([12]u8),
    airdate_len: usize = 0,
};

// ── tiny JSON scan helpers (self-contained; no allocation) ──

/// Integer immediately following `key` (allowing spaces/colon, optional '-').
/// Null when the key is absent or no digit follows.
fn intAfter(s: []const u8, key: []const u8) ?i64 {
    const ki = std.mem.indexOf(u8, s, key) orelse return null;
    var i = ki + key.len;
    while (i < s.len and (s[i] == ' ' or s[i] == ':')) i += 1;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    var v: i64 = 0;
    var any = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
        any = true;
    }
    if (!any) return null;
    return if (neg) -v else v;
}

/// Quoted-string value following `key` (which must include the opening quote,
/// e.g. `"\"airstamp\":\""`). Null when absent OR the value is JSON `null`.
/// Returns the raw inner slice (no escape decoding — TVmaze dates never escape).
fn strAfter(s: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, s, key) orelse return null;
    const vs = ki + key.len;
    const ve = std.mem.indexOfScalarPos(u8, s, vs, '"') orelse return null;
    return s[vs..ve];
}

/// Find the next complete brace-matched `{...}` object in `json` at/after
/// `from`, honoring string literals so braces inside strings (or nested
/// `_links`/`image` objects) don't confuse the depth counter. Returns the
/// object slice + the index just past its closing `}`. Null at end of input.
fn nextObject(json: []const u8, from: usize) ?struct { obj: []const u8, end: usize } {
    var i = from;
    while (i < json.len and json[i] != '{') : (i += 1) {}
    if (i >= json.len) return null;
    const start = i;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return .{ .obj = json[start .. i + 1], .end = i + 1 };
            },
            else => {},
        }
    }
    return null;
}

// ── Public parsers ──

/// Extract the show id from a `/singlesearch/shows` object (id at top level) or
/// the first match of a `/search/shows` array (`[{"score":..,"show":{"id":..`).
/// The first `"id":` in either body is the show id (the score object has none).
/// Null when absent / non-positive.
pub fn parseShowId(json: []const u8) ?i64 {
    const id = intAfter(json, "\"id\":") orelse return null;
    return if (id > 0) id else null;
}

/// Extract `_embedded.nextepisode.{season,number,airstamp}` from a
/// `/shows/{id}?embed=nextepisode` body. Null when the show has no scheduled
/// next episode (key absent — ended show) or the fields are malformed.
///
/// Only ONE nextepisode object exists in the body, so we scan forward from its
/// key for the fields (safe even though the episode object nests `_links`).
pub fn parseNextEpisode(json: []const u8) ?NextEp {
    const ki = std.mem.indexOf(u8, json, "\"nextepisode\":") orelse return null;
    const scope = json[ki..];
    // A `"nextepisode":null` (rare) has no following '{' before the fields.
    var i: usize = "\"nextepisode\":".len;
    while (i < scope.len and scope[i] == ' ') i += 1;
    if (i >= scope.len or scope[i] != '{') return null;

    var out = NextEp{};
    out.season = @intCast(intAfter(scope, "\"season\":") orelse return null);
    out.number = @intCast(intAfter(scope, "\"number\":") orelse return null);
    if (strAfter(scope, "\"airstamp\":\"")) |st| {
        const n = @min(st.len, out.airstamp.len);
        @memcpy(out.airstamp[0..n], st[0..n]);
        out.airstamp_len = n;
    } else if (strAfter(scope, "\"airdate\":\"")) |dt| {
        const n = @min(dt.len, out.airstamp.len);
        @memcpy(out.airstamp[0..n], dt[0..n]);
        out.airstamp_len = n;
    }
    return out;
}

/// Parse a `/shows/{id}/episodes` array into `out`, one AirEntry per episode
/// object (season/number/airdate). Returns the number written (capped at
/// out.len). Objects with no airdate are still recorded (empty airdate) so a
/// (season,number) lookup can distinguish "no date" from "unknown episode".
pub fn parseEpisodesInto(json: []const u8, out: []AirEntry) usize {
    var count: usize = 0;
    var p: usize = 0;
    while (count < out.len) {
        const found = nextObject(json, p) orelse break;
        const obj = found.obj;
        p = found.end;

        const season = intAfter(obj, "\"season\":") orelse continue;
        const number = intAfter(obj, "\"number\":") orelse continue;
        var e = AirEntry{ .season = @intCast(season), .number = @intCast(number) };
        if (strAfter(obj, "\"airdate\":\"")) |dt| {
            const n = @min(dt.len, e.airdate.len);
            @memcpy(e.airdate[0..n], dt[0..n]);
            e.airdate_len = n;
        }
        out[count] = e;
        count += 1;
    }
    return count;
}

/// Linear lookup of a (season, number) episode's airdate in a filled entries
/// slice. Null when the episode isn't present or has no (non-empty) date.
pub fn findAirdate(entries: []const AirEntry, season: i32, number: i32) ?[]const u8 {
    for (entries) |*e| {
        if (e.season == season and e.number == number and e.airdate_len > 0) {
            return e.airdate[0..@min(e.airdate_len, e.airdate.len)];
        }
    }
    return null;
}

/// Build the show-level "Next: S{s}E{n} · airs {date} · {countdown}" line into
/// `buf`. `date_or_stamp` may be an airstamp ("2026-07-15T21:00:00+00:00") or a
/// bare "YYYY-MM-DD"; only the leading 10 chars (the date) are shown. Countdown
/// is reused from tv_calendar_pure so it matches the "Coming up" rail. Null when
/// the date is malformed.
pub fn formatNextLabel(now_s: i64, next: NextEp, buf: []u8) ?[]const u8 {
    const stamp = next.airstamp[0..@min(next.airstamp_len, next.airstamp.len)];
    if (stamp.len < 10) return null;
    const date = stamp[0..10];
    const epoch = cal.dateToEpoch(date) orelse return null;
    var cd_buf: [24]u8 = undefined;
    const cd = cal.countdownLabel(now_s, epoch, &cd_buf);
    return std.fmt.bufPrint(buf, "Next: S{d}E{d} · airs {s} · {s}", .{ next.season, next.number, date, cd }) catch null;
}

// ── Tests ──

test "parseShowId: singlesearch object + search array first match" {
    // /singlesearch/shows — id at top level.
    try std.testing.expectEqual(@as(?i64, 169), parseShowId("{\"id\":169,\"url\":\"x\",\"name\":\"Breaking Bad\"}"));
    // /search/shows — array; score object has no id, so first "id" is the show's.
    try std.testing.expectEqual(@as(?i64, 82), parseShowId("[{\"score\":6.9,\"show\":{\"id\":82,\"name\":\"Game of Thrones\"}}]"));
    // Absent / malformed → null (must not panic).
    try std.testing.expect(parseShowId("{\"name\":\"no id here\"}") == null);
    try std.testing.expect(parseShowId("") == null);
    try std.testing.expect(parseShowId("{\"id\":0}") == null);
}

test "parseNextEpisode: object with nested _links, null, absent" {
    const body =
        "{\"id\":169,\"name\":\"Silo\",\"_embedded\":{\"nextepisode\":" ++
        "{\"id\":277,\"name\":\"The Vault\",\"season\":3,\"number\":4," ++
        "\"airdate\":\"2026-07-15\",\"airstamp\":\"2026-07-15T21:00:00+00:00\"," ++
        "\"_links\":{\"self\":{\"href\":\"https://api.tvmaze.com/episodes/277\"}}}}}";
    const ne = parseNextEpisode(body).?;
    try std.testing.expectEqual(@as(i32, 3), ne.season);
    try std.testing.expectEqual(@as(i32, 4), ne.number);
    try std.testing.expectEqualStrings("2026-07-15T21:00:00+00:00", ne.airstamp[0..ne.airstamp_len]);
    // Ended show — no _embedded / nextepisode key.
    try std.testing.expect(parseNextEpisode("{\"id\":1,\"name\":\"Ended\"}") == null);
    // Explicit null value.
    try std.testing.expect(parseNextEpisode("{\"_embedded\":{\"nextepisode\":null}}") == null);
}

test "parseEpisodesInto + findAirdate: nested objects, exact key match" {
    const body =
        "[" ++
        "{\"id\":1,\"name\":\"Pilot\",\"season\":1,\"number\":1,\"airdate\":\"2018-05-02\"," ++
        "\"image\":{\"medium\":\"https://x/1.jpg\"},\"_links\":{\"self\":{\"href\":\"y\"}}}," ++
        "{\"id\":2,\"name\":\"Two\",\"season\":1,\"number\":2,\"airdate\":\"2018-05-09\"}," ++
        "{\"id\":3,\"name\":\"Future\",\"season\":2,\"number\":10,\"airdate\":\"\"}" ++
        "]";
    var entries: [8]AirEntry = undefined;
    const n = parseEpisodesInto(body, &entries);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("2018-05-02", findAirdate(entries[0..n], 1, 1).?);
    try std.testing.expectEqualStrings("2018-05-09", findAirdate(entries[0..n], 1, 2).?);
    // Episode 1x10 does not exist (must not match 1x1 or 2x10) → null.
    try std.testing.expect(findAirdate(entries[0..n], 1, 10) == null);
    // Present but empty airdate → null (distinct from unknown episode).
    try std.testing.expect(findAirdate(entries[0..n], 2, 10) == null);
}

test "formatNextLabel: airstamp + bare date + malformed" {
    var buf: [64]u8 = undefined;
    var ne = NextEp{ .season = 3, .number = 4 };
    const stamp = "2026-07-15T21:00:00+00:00";
    @memcpy(ne.airstamp[0..stamp.len], stamp);
    ne.airstamp_len = stamp.len;
    // now = 2026-07-12 → 3 days out (see tv_calendar_pure.dateToEpoch cross-check).
    const now = cal.dateToEpoch("2026-07-12").?;
    try std.testing.expectEqualStrings("Next: S3E4 · airs 2026-07-15 · in 3d", formatNextLabel(now, ne, &buf).?);

    // Bare "YYYY-MM-DD" airstamp works too.
    var nd = NextEp{ .season = 1, .number = 1 };
    @memcpy(nd.airstamp[0..10], "2026-07-15");
    nd.airstamp_len = 10;
    try std.testing.expectEqualStrings("Next: S1E1 · airs 2026-07-15 · in 3d", formatNextLabel(now, nd, &buf).?);

    // Malformed / too-short stamp → null (regression: must not slice-panic).
    var bad = NextEp{ .season = 1, .number = 1 };
    @memcpy(bad.airstamp[0..4], "2026");
    bad.airstamp_len = 4;
    try std.testing.expect(formatNextLabel(now, bad, &buf) == null);
}

test "malformed JSON never panics" {
    var entries: [4]AirEntry = undefined;
    // Truncated / garbage bodies must return safely, not crash.
    _ = parseEpisodesInto("[{\"season\":1,\"number\":", &entries);
    _ = parseEpisodesInto("{{{{", &entries);
    _ = parseShowId("\"id\":");
    _ = parseNextEpisode("{\"nextepisode\":{");
    var buf: [64]u8 = undefined;
    _ = formatNextLabel(0, NextEp{}, &buf);
    try std.testing.expect(true);
}
