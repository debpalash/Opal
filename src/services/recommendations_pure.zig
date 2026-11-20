//! Pure helpers for the Home "For You" rail (recommendations.zig +
//! ui/discovery_ui.zig): poster URL resolution and the score chip text.
//! Unit-tested; production routes through these so the tested logic ships.
const std = @import("std");
const cinemeta_pure = @import("cinemeta_pure.zig");

/// Poster width for rail cards — the same TMDB size Home's other rails use.
pub const TMDB_POSTER_BASE = "https://image.tmdb.org/t/p/w342";

/// Resolve a `tmdb_items.poster_path` value to a fetchable URL.
///
/// The column holds either a TMDB fragment ("/abc.jpg") or an absolute URL
/// (keyless Cinemeta rows). Absolute URLs pass through Cinemeta's
/// JPEG-forcing rewrite (Metahub's extensionless endpoint may serve WebP,
/// which stb_image cannot decode). Returns null when there is no art, so the
/// card shows its themed placeholder and never issues a request.
pub fn posterUrl(raw: []const u8, out: []u8) ?[]const u8 {
    if (raw.len == 0) return null;
    if (std.mem.startsWith(u8, raw, "https://") or std.mem.startsWith(u8, raw, "http://"))
        return cinemeta_pure.compatiblePosterUrl(raw, out);
    // A bare fragment must not smuggle a scheme/host or whitespace into the URL.
    for (raw) |c| if (c <= ' ' or c == '?' or c == '#' or c == '\\') return null;
    if (std.mem.indexOf(u8, raw, "..") != null or std.mem.indexOf(u8, raw, "://") != null) return null;
    const sep: []const u8 = if (raw[0] == '/') "" else "/";
    return std.fmt.bufPrint(out, "{s}{s}{s}", .{ TMDB_POSTER_BASE, sep, raw }) catch null;
}

/// Score chip text. Cosine similarities (0..1] become a percentage; anything
/// else (a TMDB rating from the genre fallback) shows one decimal. Null for
/// non-finite values so the chip is omitted rather than showing garbage.
pub fn formatScore(buf: []u8, score: f64) ?[]const u8 {
    if (std.math.isNan(score) or std.math.isInf(score)) return null;
    if (score > 0.0 and score <= 1.0) {
        const pct: u32 = @intFromFloat(@round(std.math.clamp(score, 0.0, 1.0) * 100.0));
        return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch null;
    }
    return std.fmt.bufPrint(buf, "{d:.1}", .{score}) catch null;
}

test "posterUrl builds TMDB w342 URLs from fragments" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://image.tmdb.org/t/p/w342/abc.jpg", posterUrl("/abc.jpg", &b).?);
    try std.testing.expectEqualStrings("https://image.tmdb.org/t/p/w342/abc.jpg", posterUrl("abc.jpg", &b).?);
}

test "posterUrl passes absolute URLs through the Cinemeta JPEG rewrite" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.org/p.jpg", posterUrl("https://example.org/p.jpg", &b).?);
    try std.testing.expectEqualStrings(
        "https://images.metahub.space/poster/medium/tt0111161/img.jpg",
        posterUrl("https://images.metahub.space/poster/medium/tt0111161/img", &b).?,
    );
}

test "posterUrl returns null for missing or hostile paths (no request, placeholder shown)" {
    var b: [512]u8 = undefined;
    try std.testing.expect(posterUrl("", &b) == null);
    try std.testing.expect(posterUrl("/a b.jpg", &b) == null);
    try std.testing.expect(posterUrl("/../x.jpg", &b) == null);
    try std.testing.expect(posterUrl("/x.jpg?y=1", &b) == null);
    var tiny: [8]u8 = undefined;
    try std.testing.expect(posterUrl("/abc.jpg", &tiny) == null);
}

test "formatScore renders cosine as percent, ratings with one decimal, drops non-finite" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("87%", formatScore(&b, 0.87).?);
    try std.testing.expectEqualStrings("100%", formatScore(&b, 1.0).?);
    try std.testing.expectEqualStrings("7.4", formatScore(&b, 7.4).?);
    try std.testing.expect(formatScore(&b, std.math.nan(f64)) == null);
    try std.testing.expect(formatScore(&b, std.math.inf(f64)) == null);
}
