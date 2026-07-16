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

/// Query-string suffix for Jikan endpoints. Historically `&sfw=true` asked the API itself
/// Jikan currently 504s ("failed to connect to MyAnimeList") on ANY request
/// carrying the `sfw` query param — which, since the NSFW filter is ON by
/// default, broke every anime view (trending/seasonal/search/calendar). The
/// param is redundant anyway: parseJikanDataEx already drops adult entries
/// client-side via `jikanRatingIsAdult` when the filter is on. So send NO sfw
/// param and rely on that client-side filter. Kept as a function (not inlined)
/// so re-enabling a server-side param later is a one-line change.
pub fn sfwSuffix(filter_enabled: bool) []const u8 {
    _ = filter_enabled;
    return "";
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
    // Jikan 504s on the `sfw` param, so we send none and filter adult entries
    // client-side (jikanRatingIsAdult) instead — suffix is empty regardless.
    try std.testing.expectEqualStrings("", sfwSuffix(true));
    try std.testing.expectEqualStrings("", sfwSuffix(false));
}
