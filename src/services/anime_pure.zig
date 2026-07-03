//! Pure helpers for the anime tab (Jikan API) — no app-state imports, so the
//! logic ships tested (see build.zig test step).

const std = @import("std");

/// True when a Jikan anime object's `rating` marks adult content.
/// Jikan ratings: G, PG, PG-13, "R - 17+ (violence & profanity)",
/// "R+ - Mild Nudity", "Rx - Hentai". The NSFW filter hides Rx (hentai)
/// and R+ (nudity/ecchi covers) — plain "R - 17+" stays: violence is not
/// what the toggle is about. Matching is on the exact "Rx"/"R+" prefix, so
/// "R -" never false-positives.
pub fn jikanRatingIsAdult(obj_json: []const u8) bool {
    const key = "\"rating\":\"";
    const start = (std.mem.indexOf(u8, obj_json, key) orelse return false) + key.len;
    const rest = obj_json[start..];
    if (std.mem.startsWith(u8, rest, "Rx")) return true;
    if (std.mem.startsWith(u8, rest, "R+")) return true;
    return false;
}

/// Query-string suffix for Jikan endpoints: `&sfw=true` asks the API itself
/// to drop Rx entries (the rating check above still guards R+ and any cached
/// or malformed responses). Every call site already has a `?…` query, so the
/// suffix always joins with '&'.
pub fn sfwSuffix(filter_enabled: bool) []const u8 {
    return if (filter_enabled) "&sfw=true" else "";
}

test "jikanRatingIsAdult flags Rx and R+, keeps R and below" {
    try std.testing.expect(jikanRatingIsAdult("{\"mal_id\":1,\"rating\":\"Rx - Hentai\",\"title\":\"x\"}"));
    try std.testing.expect(jikanRatingIsAdult("{\"rating\":\"R+ - Mild Nudity\"}"));
    try std.testing.expect(!jikanRatingIsAdult("{\"rating\":\"R - 17+ (violence & profanity)\"}"));
    try std.testing.expect(!jikanRatingIsAdult("{\"rating\":\"PG-13 - Teens 13 or older\"}"));
    try std.testing.expect(!jikanRatingIsAdult("{\"rating\":\"G - All Ages\"}"));
}

test "jikanRatingIsAdult tolerates missing/null rating" {
    try std.testing.expect(!jikanRatingIsAdult("{\"mal_id\":5,\"title\":\"no rating field\"}"));
    try std.testing.expect(!jikanRatingIsAdult("{\"rating\":null}"));
    try std.testing.expect(!jikanRatingIsAdult(""));
}

test "sfwSuffix" {
    try std.testing.expectEqualStrings("&sfw=true", sfwSuffix(true));
    try std.testing.expectEqualStrings("", sfwSuffix(false));
}
