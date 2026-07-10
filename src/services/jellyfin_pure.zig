//! Pure helpers for Jellyfin image proxying — no I/O / state / dvui imports, so
//! the logic ships tested (registered as `test_jellyfin_pure` in build.zig).
//!
//! Both the desktop poster worker (jellyfin.zig fetchPoster) and the web
//! companion's `/api/jellyfin/poster` proxy (remote_stream.zig) route their URL
//! + cache-key building through here, so the two can never drift.

const std = @import("std");

/// A Jellyfin item id is a 32-char hex GUID in practice; be lenient (alnum +
/// dash, bounded) but reject anything that could escape the
/// `/Items/{id}/Images/Primary` path or inject extra query params into the
/// proxied URL (slash, dot, `?`, `&`, `=`, `%`, whitespace). This is the
/// gate the untrusted `?id=` query param passes before it reaches curl.
pub fn validItemId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Build the authenticated primary-image URL (small thumbnail). `api_key` in the
/// query is how Jellyfin authenticates an `<img>`-style GET (no header needed).
pub fn primaryImageUrl(server: []const u8, id: []const u8, token: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/Items/{s}/Images/Primary?maxWidth=200&quality=80&api_key={s}", .{ server, id, token }) catch null;
}

/// Cache key EXCLUDES the api_key so a token rotation can't orphan every cached
/// Jellyfin poster in the shared disk cache.
pub fn primaryImageCacheKey(server: []const u8, id: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/Items/{s}/Images/Primary?maxWidth=200", .{ server, id }) catch null;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "validItemId accepts GUIDs, rejects injection" {
    try std.testing.expect(validItemId("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"));
    try std.testing.expect(validItemId("abc-123-DEF"));
    try std.testing.expect(!validItemId(""));
    // Path traversal / query injection attempts must be rejected.
    try std.testing.expect(!validItemId("../secret"));
    try std.testing.expect(!validItemId("id/Images"));
    try std.testing.expect(!validItemId("id&api_key=x"));
    try std.testing.expect(!validItemId("id?x=1"));
    try std.testing.expect(!validItemId("a b"));
    // Over-long is rejected (bound).
    try std.testing.expect(!validItemId("a" ** 65));
}

test "primaryImageUrl embeds token, cache key omits it" {
    var buf: [256]u8 = undefined;
    const url = primaryImageUrl("https://jf.example", "ITEM1", "TOK", &buf).?;
    try std.testing.expectEqualStrings("https://jf.example/Items/ITEM1/Images/Primary?maxWidth=200&quality=80&api_key=TOK", url);

    var kbuf: [256]u8 = undefined;
    const key = primaryImageCacheKey("https://jf.example", "ITEM1", &kbuf).?;
    try std.testing.expectEqualStrings("https://jf.example/Items/ITEM1/Images/Primary?maxWidth=200", key);
    // The cache key must not contain the api_key (token-rotation safety).
    try std.testing.expect(std.mem.indexOf(u8, key, "api_key") == null);
}
