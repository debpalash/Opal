//! Pure helpers for AniList metadata enrichment — no app-state / io_global
//! imports, so the parsing logic ships tested (see build.zig `test` step).
//!
//! AniList's public GraphQL endpoint returns anime metadata as
//! `{"data":{"Page":{"media":[{ "id":.., "idMal":.., "averageScore":.., ... }]}}}`.
//! `Iter` walks that array allocator-free, yielding slices INTO the source JSON
//! (the caller copies them into fixed buffers). Every extractor tolerates
//! missing / null / truncated fields so a malformed response can never panic a
//! worker thread (a worker panic aborts the whole app).

const std = @import("std");

/// SFW gate clause for the AniList `media(...)` selector. Mirrors
/// `anime_pure.sfwSuffix`: when the NSFW filter is on we ask AniList to exclude
/// adult entries (`isAdult: false`); when off we add nothing. The returned
/// string is spliced verbatim into the GraphQL query.
pub fn adultGate(filter_enabled: bool) []const u8 {
    return if (filter_enabled) ", isAdult: false" else "";
}

/// One parsed AniList media entry. String fields are slices into the source
/// JSON (allocator-free, still JSON-escaped); the caller decodes/copies them.
pub const Media = struct {
    id: i64 = 0,
    id_mal: i64 = 0,
    /// averageScore (AniList's 0-100 scale) mapped to 0-10 to match MAL/Jikan.
    /// 0 when the field is absent or null.
    score10: f32 = 0,
    episodes: u16 = 0,
    year: u16 = 0,
    title_english: []const u8 = "",
    title_romaji: []const u8 = "",
    cover: []const u8 = "",
    description: []const u8 = "",
};

fn indexAfter(hay: []const u8, needle: []const u8) ?usize {
    const i = std.mem.indexOf(u8, hay, needle) orelse return null;
    return i + needle.len;
}

/// Integer value following `key` (e.g. `"averageScore":`). Skips one leading
/// space and an optional `-`. Returns null when the key is absent or the value
/// is non-numeric (`null`, `true`, …) — the caller keeps its default.
pub fn fieldInt(slice: []const u8, key: []const u8) ?i64 {
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

/// String value following `quoted_key` (which must include the opening quote,
/// e.g. `"\"english\":\""`). Reads until the next UNESCAPED `"`. Returns "" when
/// the key is absent (so `"english":null` yields "") or the string is
/// unterminated (truncated / malformed response).
pub fn fieldStr(slice: []const u8, quoted_key: []const u8) []const u8 {
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

/// Walks `data.Page.media[]`, anchoring on each object's leading `"id":`. Each
/// object slice runs from one `"id":` to the next, so field order within the
/// object doesn't matter. `"idMal":` never false-matches `"id":` (the byte after
/// `id` is `M`, not `"`), and unescaped `"id":` can't occur inside a JSON string
/// value, so description/cover text can't spoof an object boundary.
pub const Iter = struct {
    json: []const u8,
    pos: usize = 0,

    const KEY = "\"id\":";

    pub fn next(self: *Iter) ?Media {
        const rel = std.mem.indexOf(u8, self.json[self.pos..], KEY) orelse return null;
        const start = self.pos + rel;
        var end = self.json.len;
        if (std.mem.indexOf(u8, self.json[start + KEY.len ..], KEY)) |n| {
            end = start + KEY.len + n;
        }
        const slice = self.json[start..end];
        self.pos = end;

        var m = Media{};
        if (fieldInt(slice, "\"id\":")) |v| m.id = v;
        if (fieldInt(slice, "\"idMal\":")) |v| m.id_mal = v;
        if (fieldInt(slice, "\"averageScore\":")) |v| {
            if (v > 0) m.score10 = @as(f32, @floatFromInt(v)) / 10.0;
        }
        if (fieldInt(slice, "\"episodes\":")) |v| {
            if (v > 0 and v < 65535) m.episodes = @intCast(v);
        }
        if (fieldInt(slice, "\"seasonYear\":")) |v| {
            if (v > 0 and v < 65535) m.year = @intCast(v);
        }
        m.title_english = fieldStr(slice, "\"english\":\"");
        m.title_romaji = fieldStr(slice, "\"romaji\":\"");
        m.cover = fieldStr(slice, "\"large\":\"");
        m.description = fieldStr(slice, "\"description\":\"");
        return m;
    }
};

// ── tests ──────────────────────────────────────────────────

test "adultGate mirrors the NSFW toggle" {
    try std.testing.expectEqualStrings(", isAdult: false", adultGate(true));
    try std.testing.expectEqualStrings("", adultGate(false));
}

test "Iter parses a well-formed Page.media array" {
    const json =
        \\{"data":{"Page":{"media":[
        \\{"id":1,"idMal":1535,"averageScore":85,"title":{"romaji":"Death Note","english":"Death Note"},"coverImage":{"large":"https://img/a.jpg"},"episodes":37,"seasonYear":2006,"description":"A notebook."},
        \\{"id":2,"idMal":9999,"averageScore":72,"title":{"romaji":"Foo","english":null},"coverImage":{"large":"https://img/b.jpg"},"episodes":12,"seasonYear":2021,"description":"Bar."}
        \\]}}}
    ;
    var it = Iter{ .json = json };

    const a = it.next().?;
    try std.testing.expectEqual(@as(i64, 1), a.id);
    try std.testing.expectEqual(@as(i64, 1535), a.id_mal);
    try std.testing.expectApproxEqAbs(@as(f32, 8.5), a.score10, 0.001);
    try std.testing.expectEqual(@as(u16, 37), a.episodes);
    try std.testing.expectEqual(@as(u16, 2006), a.year);
    try std.testing.expectEqualStrings("Death Note", a.title_english);
    try std.testing.expectEqualStrings("https://img/a.jpg", a.cover);
    try std.testing.expectEqualStrings("A notebook.", a.description);

    const b = it.next().?;
    try std.testing.expectEqual(@as(i64, 9999), b.id_mal);
    try std.testing.expectApproxEqAbs(@as(f32, 7.2), b.score10, 0.001);
    // english:null → empty; romaji still present.
    try std.testing.expectEqualStrings("", b.title_english);
    try std.testing.expectEqualStrings("Foo", b.title_romaji);

    try std.testing.expect(it.next() == null);
}

test "Iter tolerates missing / null numeric fields" {
    const json =
        \\{"data":{"Page":{"media":[{"id":7,"idMal":42,"averageScore":null,"title":{"romaji":"X","english":"X"},"episodes":null,"seasonYear":null}]}}}
    ;
    var it = Iter{ .json = json };
    const m = it.next().?;
    try std.testing.expectEqual(@as(i64, 42), m.id_mal);
    try std.testing.expectEqual(@as(f32, 0), m.score10);
    try std.testing.expectEqual(@as(u16, 0), m.episodes);
    try std.testing.expectEqual(@as(u16, 0), m.year);
    try std.testing.expect(it.next() == null);
}

test "Iter regression: truncated / malformed JSON never panics" {
    // Response cut off mid-string: id/idMal parse, the unterminated english
    // string yields "" rather than reading past the buffer, and next() ends.
    const truncated =
        \\{"data":{"Page":{"media":[{"id":123,"idMal":456,"averageScore":80,"title":{"romaji":"Foo","english":"Foobar
    ;
    var it = Iter{ .json = truncated };
    const m = it.next().?;
    try std.testing.expectEqual(@as(i64, 456), m.id_mal);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), m.score10, 0.001);
    try std.testing.expectEqualStrings("Foo", m.title_romaji);
    try std.testing.expectEqualStrings("", m.title_english); // unterminated
    try std.testing.expect(it.next() == null);

    // Garbage, empty, and no-media payloads all terminate cleanly.
    var e1 = Iter{ .json = "" };
    try std.testing.expect(e1.next() == null);
    var e2 = Iter{ .json = "not json at all" };
    try std.testing.expect(e2.next() == null);
    var e3 = Iter{ .json = "{\"data\":{\"Page\":{\"media\":[]}}}" };
    try std.testing.expect(e3.next() == null);
    var e4 = Iter{ .json = "{\"errors\":[{\"message\":\"boom\"}]}" };
    try std.testing.expect(e4.next() == null);
}

test "fieldInt / fieldStr direct" {
    try std.testing.expectEqual(@as(?i64, 85), fieldInt("\"averageScore\":85,", "\"averageScore\":"));
    try std.testing.expectEqual(@as(?i64, null), fieldInt("\"averageScore\":null", "\"averageScore\":"));
    try std.testing.expectEqual(@as(?i64, null), fieldInt("{}", "\"x\":"));
    try std.testing.expectEqualStrings("hi", fieldStr("\"english\":\"hi\"", "\"english\":\""));
    try std.testing.expectEqualStrings("", fieldStr("\"english\":null", "\"english\":\""));
}
