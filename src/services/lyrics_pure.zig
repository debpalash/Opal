//! Synced lyrics (lrclib.net) — PURE, unit-tested.
//!
//! lrclib.net is a keyless, open lyrics database. `GET /api/get` takes the
//! track's artist/title/album/duration and returns one object with both
//! `plainLyrics` and `syncedLyrics` (an LRC document); `GET /api/search?q=`
//! is the fuzzy fallback when the exact match 404s.
//!
//! This module owns URL building (with percent-encoding), the `syncedLyrics` /
//! `plainLyrics` JSON extraction, and the LRC timeline parse. Fetch, threading
//! and rendering live in the non-pure sibling lyrics.zig, so the shipped
//! requests and the shipped timeline ARE the tested ones.

const std = @import("std");
const json_pure = @import("json_pure.zig");

pub const API_BASE = "https://lrclib.net/api";

/// Max lyric line text we keep — LRC lines are short; longer is truncated.
pub const LINE_TEXT_CAP = 192;

pub const LyricLine = struct {
    ms: u32 = 0,
    text: [LINE_TEXT_CAP]u8 = std.mem.zeroes([LINE_TEXT_CAP]u8),
    text_len: usize = 0,

    pub fn slice(self: *const LyricLine) []const u8 {
        return self.text[0..@min(self.text_len, self.text.len)];
    }
};

// ══════════════════════════════════════════════════════════
// Percent-encoding (unreserved kept — covers space & = # ? % + )
// ══════════════════════════════════════════════════════════

pub fn percentEncode(input: []const u8, out: []u8) usize {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (input) |ch| {
        if (n + 3 > out.len) break;
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~')
        {
            out[n] = ch;
            n += 1;
        } else {
            out[n] = '%';
            out[n + 1] = hex[ch >> 4];
            out[n + 2] = hex[ch & 0xF];
            n += 3;
        }
    }
    return n;
}

// ══════════════════════════════════════════════════════════
// URL builders
// ══════════════════════════════════════════════════════════

/// `/api/get?artist_name=..&track_name=..[&album_name=..][&duration=..]`.
/// Null when artist or title is empty, or the URL doesn't fit `out`.
pub fn buildLrclibUrl(
    artist: []const u8,
    title: []const u8,
    album: []const u8,
    duration_secs: u32,
    out: []u8,
) ?[]const u8 {
    if (artist.len == 0 or title.len == 0) return null;

    var enc: [768]u8 = undefined;
    var w: usize = 0;

    const head = API_BASE ++ "/get?artist_name=";
    if (head.len > out.len) return null;
    @memcpy(out[0..head.len], head);
    w = head.len;

    var n = percentEncode(artist, &enc);
    if (w + n > out.len) return null;
    @memcpy(out[w .. w + n], enc[0..n]);
    w += n;

    const tk = "&track_name=";
    if (w + tk.len > out.len) return null;
    @memcpy(out[w .. w + tk.len], tk);
    w += tk.len;

    n = percentEncode(title, &enc);
    if (w + n > out.len) return null;
    @memcpy(out[w .. w + n], enc[0..n]);
    w += n;

    if (album.len > 0) {
        const ak = "&album_name=";
        if (w + ak.len > out.len) return null;
        @memcpy(out[w .. w + ak.len], ak);
        w += ak.len;
        n = percentEncode(album, &enc);
        if (w + n > out.len) return null;
        @memcpy(out[w .. w + n], enc[0..n]);
        w += n;
    }

    if (duration_secs > 0) {
        const rest = std.fmt.bufPrint(out[w..], "&duration={d}", .{duration_secs}) catch return null;
        w += rest.len;
    }

    return out[0..w];
}

/// `/api/search?q=..` — the fuzzy fallback.
pub fn buildLrclibSearchUrl(query: []const u8, out: []u8) ?[]const u8 {
    if (query.len == 0) return null;
    const head = API_BASE ++ "/search?q=";
    if (head.len > out.len) return null;
    @memcpy(out[0..head.len], head);
    var enc: [768]u8 = undefined;
    const n = percentEncode(query, &enc);
    if (head.len + n > out.len) return null;
    @memcpy(out[head.len .. head.len + n], enc[0..n]);
    return out[0 .. head.len + n];
}

// ══════════════════════════════════════════════════════════
// JSON field extraction
// ══════════════════════════════════════════════════════════

/// Slice the RAW (still-escaped) value of a JSON string field, honouring
/// backslash escapes so a `\"` inside the value doesn't end it early. Null
/// when the key is absent or every occurrence is `null`.
///
/// Keeps scanning past non-string values: `/api/search` returns an ARRAY whose
/// leading entries commonly carry `"syncedLyrics":null` (plain-only matches),
/// and stopping at the first one would discard a synced match further down.
fn rawStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [64]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\"", .{key}) catch return null;

    var from: usize = 0;
    while (std.mem.indexOfPos(u8, json, from, needle)) |at| {
        var i = at + needle.len;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
        if (i >= json.len or json[i] != ':') {
            from = at + needle.len;
            continue;
        }
        i += 1;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) i += 1;
        if (i >= json.len or json[i] != '"') {
            from = at + needle.len; // `null` / number → try the next entry
            continue;
        }
        i += 1;
        const start = i;
        while (i < json.len) : (i += 1) {
            if (json[i] == '\\') {
                i += 1;
                continue;
            }
            if (json[i] == '"') return json[start..i];
        }
        return null;
    }
    return null;
}

fn unescapedField(json: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    const raw = rawStringField(json, key) orelse return null;
    if (raw.len == 0) return null;
    const s = json_pure.jsonUnescape(raw, out);
    if (s.len == 0) return null;
    return s;
}

/// The `syncedLyrics` LRC document, JSON-unescaped into `out`.
pub fn extractSyncedLyrics(json: []const u8, out: []u8) ?[]const u8 {
    return unescapedField(json, "syncedLyrics", out);
}

/// The `plainLyrics` fallback, JSON-unescaped into `out`.
pub fn extractPlainLyrics(json: []const u8, out: []u8) ?[]const u8 {
    return unescapedField(json, "plainLyrics", out);
}

// ══════════════════════════════════════════════════════════
// LRC parse
// ══════════════════════════════════════════════════════════

/// Parse `[mm:ss.xx] text` / `[mm:ss] text`. A line may carry several
/// timestamps (`[00:12.00][01:44.00] chorus`) — each becomes its own entry.
/// Metadata tags (`[ar:..]`, `[length:..]`) are skipped: they have a
/// non-digit first char inside the bracket. Output is sorted ascending;
/// returns how many entries were written into `out`.
pub fn parseLrc(lrc: []const u8, out: []LyricLine) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, lrc, '\n');
    while (it.next()) |raw_line| {
        if (count >= out.len) break;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] != '[') continue;

        // Collect the leading run of timestamps.
        var stamps: [8]u32 = undefined;
        var stamp_n: usize = 0;
        var i: usize = 0;
        while (i < line.len and line[i] == '[' and stamp_n < stamps.len) {
            const close = std.mem.indexOfScalarPos(u8, line, i, ']') orelse break;
            const body = line[i + 1 .. close];
            const ms = parseStamp(body) orelse break; // metadata tag → stop
            stamps[stamp_n] = ms;
            stamp_n += 1;
            i = close + 1;
        }
        if (stamp_n == 0) continue;

        const text = std.mem.trim(u8, line[i..], " \t\r");
        var s: usize = 0;
        while (s < stamp_n and count < out.len) : (s += 1) {
            var e = LyricLine{ .ms = stamps[s] };
            const n = @min(text.len, e.text.len);
            @memcpy(e.text[0..n], text[0..n]);
            e.text_len = n;
            out[count] = e;
            count += 1;
        }
    }

    std.mem.sort(LyricLine, out[0..count], {}, struct {
        fn lt(_: void, a: LyricLine, b: LyricLine) bool {
            return a.ms < b.ms;
        }
    }.lt);
    return count;
}

/// `mm:ss`, `mm:ss.xx`, `mm:ss.xxx` → milliseconds. Null for metadata tags.
fn parseStamp(body: []const u8) ?u32 {
    if (body.len < 4) return null;
    if (body[0] < '0' or body[0] > '9') return null;
    const colon = std.mem.indexOfScalar(u8, body, ':') orelse return null;
    const mins = std.fmt.parseInt(u32, body[0..colon], 10) catch return null;

    const rest = body[colon + 1 ..];
    var secs_str = rest;
    var frac_str: []const u8 = "";
    if (std.mem.indexOfAny(u8, rest, ".:")) |dot| {
        secs_str = rest[0..dot];
        frac_str = rest[dot + 1 ..];
    }
    const secs = std.fmt.parseInt(u32, secs_str, 10) catch return null;
    if (secs > 59) return null;

    var frac_ms: u32 = 0;
    if (frac_str.len > 0) {
        const take = @min(frac_str.len, 3);
        const v = std.fmt.parseInt(u32, frac_str[0..take], 10) catch return null;
        frac_ms = switch (take) {
            1 => v * 100,
            2 => v * 10,
            else => v,
        };
    }
    return mins * 60_000 + secs * 1000 + frac_ms;
}

/// Index of the LAST line whose timestamp is <= `pos_ms`; null before the
/// first line starts (or when there are no lines).
pub fn activeLineAt(lines: []const LyricLine, pos_ms: u32) ?usize {
    if (lines.len == 0) return null;
    if (pos_ms < lines[0].ms) return null;
    var lo: usize = 0;
    var hi: usize = lines.len; // first index with ms > pos
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lines[mid].ms <= pos_ms) lo = mid + 1 else hi = mid;
    }
    return lo - 1;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "buildLrclibUrl encodes reserved characters" {
    var buf: [1024]u8 = undefined;
    const u = buildLrclibUrl("AC/DC & Co", "Q?A #1 100%", "Best+Of", 245, &buf).?;
    try std.testing.expectEqualStrings(
        "https://lrclib.net/api/get?artist_name=AC%2FDC%20%26%20Co&track_name=Q%3FA%20%231%20100%25&album_name=Best%2BOf&duration=245",
        u,
    );
}

test "buildLrclibUrl omits empty album and zero duration" {
    var buf: [1024]u8 = undefined;
    const u = buildLrclibUrl("Daft Punk", "Aerodynamic", "", 0, &buf).?;
    try std.testing.expectEqualStrings(
        "https://lrclib.net/api/get?artist_name=Daft%20Punk&track_name=Aerodynamic",
        u,
    );
}

test "buildLrclibUrl rejects empty artist or title" {
    var buf: [1024]u8 = undefined;
    try std.testing.expect(buildLrclibUrl("", "x", "", 0, &buf) == null);
    try std.testing.expect(buildLrclibUrl("x", "", "", 0, &buf) == null);
}

test "buildLrclibUrl refuses to truncate into a tiny buffer" {
    var small: [24]u8 = undefined;
    try std.testing.expect(buildLrclibUrl("Daft Punk", "Aerodynamic", "", 0, &small) == null);
}

test "buildLrclibSearchUrl encodes the query" {
    var buf: [512]u8 = undefined;
    const u = buildLrclibSearchUrl("daft punk & one more time", &buf).?;
    try std.testing.expectEqualStrings(
        "https://lrclib.net/api/search?q=daft%20punk%20%26%20one%20more%20time",
        u,
    );
    try std.testing.expect(buildLrclibSearchUrl("", &buf) == null);
}

test "extractSyncedLyrics unescapes newlines quotes and backslashes" {
    const json =
        \\{"id":42,"trackName":"One More Time","plainLyrics":"one more time\nwe're gonna celebrate",
        \\"syncedLyrics":"[00:07.00] \"One\" more \\ time\n[00:12.50] Celebrate"}
    ;
    var out: [512]u8 = undefined;
    const s = extractSyncedLyrics(json, &out).?;
    try std.testing.expectEqualStrings("[00:07.00] \"One\" more \\ time\n[00:12.50] Celebrate", s);

    var out2: [512]u8 = undefined;
    const p = extractPlainLyrics(json, &out2).?;
    try std.testing.expectEqualStrings("one more time\nwe're gonna celebrate", p);
}

test "extractSyncedLyrics returns null for instrumental null field" {
    const json = "{\"instrumental\":true,\"plainLyrics\":null,\"syncedLyrics\":null}";
    var out: [128]u8 = undefined;
    try std.testing.expect(extractSyncedLyrics(json, &out) == null);
    try std.testing.expect(extractPlainLyrics(json, &out) == null);
}

test "extractSyncedLyrics skips null entries in a search array" {
    // /api/search shape: the first two hits are plain-only, the third is synced.
    const json =
        \\[{"trackName":"A","plainLyrics":"a","syncedLyrics":null},
        \\{"trackName":"B","syncedLyrics":null},
        \\{"trackName":"C","syncedLyrics":"[00:05.00] found me"}]
    ;
    var out: [256]u8 = undefined;
    const s = extractSyncedLyrics(json, &out).?;
    try std.testing.expectEqualStrings("[00:05.00] found me", s);
}

test "parseLrc handles metadata, multi-timestamp lines and mm:ss" {
    const lrc =
        "[ar: Daft Punk]\n" ++
        "[ti: One More Time]\n" ++
        "[length: 05:20]\n" ++
        "\n" ++
        "[00:07.00] One more time\n" ++
        "[00:12.5] Celebrate\n" ++
        "[00:20][01:40] Chorus\n" ++
        "[01:00] Music's got me feeling\n" ++
        "not a lyric line\n";

    var lines: [16]LyricLine = undefined;
    const n = parseLrc(lrc, &lines);
    // 5 timed entries; the [ar:]/[ti:]/[length:] tags and the untimed line are skipped.
    try std.testing.expectEqual(@as(usize, 5), n);

    try std.testing.expectEqual(@as(u32, 7000), lines[0].ms);
    try std.testing.expectEqualStrings("One more time", lines[0].slice());
    try std.testing.expectEqual(@as(u32, 12500), lines[1].ms);
    try std.testing.expectEqual(@as(u32, 20000), lines[2].ms);
    try std.testing.expectEqualStrings("Chorus", lines[2].slice());
    try std.testing.expectEqual(@as(u32, 60000), lines[3].ms);
    try std.testing.expectEqual(@as(u32, 100000), lines[4].ms);
    try std.testing.expectEqualStrings("Chorus", lines[4].slice());
}

test "parseLrc output is sorted ascending" {
    const lrc = "[01:00.00] b\n[00:10.00] a\n[02:00.00] c\n";
    var lines: [8]LyricLine = undefined;
    const n = parseLrc(lrc, &lines);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("a", lines[0].slice());
    try std.testing.expectEqualStrings("b", lines[1].slice());
    try std.testing.expectEqualStrings("c", lines[2].slice());
}

test "parseLrc keeps empty-text timed lines and respects out capacity" {
    const lrc = "[00:01.00]\n[00:02.00] two\n[00:03.00] three\n";
    var lines: [2]LyricLine = undefined;
    const n = parseLrc(lrc, &lines);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 0), lines[0].text_len);
}

test "activeLineAt boundaries" {
    var lines: [3]LyricLine = undefined;
    lines[0] = .{ .ms = 1000 };
    lines[1] = .{ .ms = 2000 };
    lines[2] = .{ .ms = 3000 };

    try std.testing.expect(activeLineAt(lines[0..0], 5000) == null);
    try std.testing.expect(activeLineAt(&lines, 0) == null);
    try std.testing.expect(activeLineAt(&lines, 999) == null);
    try std.testing.expectEqual(@as(usize, 0), activeLineAt(&lines, 1000).?); // exact hit
    try std.testing.expectEqual(@as(usize, 0), activeLineAt(&lines, 1999).?);
    try std.testing.expectEqual(@as(usize, 1), activeLineAt(&lines, 2000).?);
    try std.testing.expectEqual(@as(usize, 2), activeLineAt(&lines, 3000).?); // last, exact
    try std.testing.expectEqual(@as(usize, 2), activeLineAt(&lines, 999_999).?); // after last
}

test "end to end: lrclib response to active line" {
    const json =
        \\{"syncedLyrics":"[00:07.00] One more time\n[00:12.00] Celebrate\n[00:18.00] Oh yeah"}
    ;
    var lyr_buf: [512]u8 = undefined;
    const lrc = extractSyncedLyrics(json, &lyr_buf).?;
    var lines: [32]LyricLine = undefined;
    const n = parseLrc(lrc, &lines);
    try std.testing.expectEqual(@as(usize, 3), n);
    const idx = activeLineAt(lines[0..n], 13_400).?;
    try std.testing.expectEqualStrings("Celebrate", lines[idx].slice());
}
