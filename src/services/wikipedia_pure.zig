const std = @import("std");

// ══════════════════════════════════════════════════════════
// Pure logic behind the trivia-loading-screen Wikipedia lookup (see
// wikipedia.zig for the I/O side). Kept free of any core/io_global-touching
// import so it can be unit-tested standalone (see build.zig's test step).
// ══════════════════════════════════════════════════════════

/// Build the disambiguated title to try first — a bare title often collides
/// with an unrelated Wikipedia page (e.g. "Silo" the storage structure vs.
/// the TV series).
pub fn disambiguatedTitle(title: []const u8, is_tv: bool, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ title, if (is_tv) "TV series" else "film" }) catch title;
}

/// Wikipedia titles use underscores for spaces in URL paths.
pub fn spacesToUnderscores(input: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    for (input) |ch| {
        if (len >= buf.len) break;
        buf[len] = if (ch == ' ') '_' else ch;
        len += 1;
    }
    return buf[0..len];
}

/// Find a top-level `"key":"value"` string field in a flat JSON object.
/// Doesn't handle nested objects/escapes beyond `\"` — matches the ad-hoc
/// JSON scanning convention used throughout this codebase (tmdb_parse.zig,
/// core/http.zig) rather than pulling in a full JSON parser.
fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var kb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&kb, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = idx + needle.len;
    var end = start;
    var esc = false;
    while (end < json.len) : (end += 1) {
        if (esc) {
            esc = false;
            continue;
        }
        if (json[end] == '\\') {
            esc = true;
            continue;
        }
        if (json[end] == '"') break;
    }
    return json[start..end];
}

/// Pull a usable trivia extract out of a Wikipedia REST summary JSON body.
/// Returns null for disambiguation pages or extracts too short to be a real
/// blurb, so the caller can fall back to its next candidate title.
pub fn extractSummary(body: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, body, "\"type\":\"disambiguation\"") != null) return null;
    const extract = jsonStringField(body, "extract") orelse return null;
    if (extract.len < 20) return null;
    return extract;
}

test "disambiguatedTitle appends the right suffix per media type" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Silo (TV series)", disambiguatedTitle("Silo", true, &buf));
    try std.testing.expectEqualStrings("Obsession (film)", disambiguatedTitle("Obsession", false, &buf));
}

test "spacesToUnderscores replaces spaces only" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("House_of_the_Dragon", spacesToUnderscores("House of the Dragon", &buf));
    try std.testing.expectEqualStrings("Obsession", spacesToUnderscores("Obsession", &buf));
}

test "extractSummary rejects disambiguation pages" {
    const body = "{\"type\":\"disambiguation\",\"extract\":\"Silo may refer to several things.\"}";
    try std.testing.expect(extractSummary(body) == null);
}

test "extractSummary rejects too-short extracts" {
    const body = "{\"type\":\"standard\",\"extract\":\"Short.\"}";
    try std.testing.expect(extractSummary(body) == null);
}

test "extractSummary returns a usable extract" {
    const body = "{\"type\":\"standard\",\"extract\":\"Silo is an American science fiction television series based on a series of novellas by Hugh Howey.\"}";
    const got = extractSummary(body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Silo is an American science fiction television series based on a series of novellas by Hugh Howey.", got);
}

test "extractSummary handles escaped quotes in the extract" {
    const body = "{\"type\":\"standard\",\"extract\":\"He said \\\"hello\\\" to the crowd during the finale.\"}";
    const got = extractSummary(body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("He said \\\"hello\\\" to the crowd during the finale.", got);
}
