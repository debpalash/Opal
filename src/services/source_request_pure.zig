//! Public source transport policy. Configured mirrors preserve request path boundaries.
const std = @import("std");
pub fn mirrorUrl(out: []u8, url: []const u8, base_raw: []const u8, mirror_raw: []const u8) ?[]const u8 {
    const base = std.mem.trimEnd(u8, base_raw, "/");
    const mirror = std.mem.trimEnd(u8, mirror_raw, "/");
    if (!std.mem.startsWith(u8, url, base) or url.len <= base.len) return null;
    if (url[base.len] != '/' and url[base.len] != '?') return null;
    const uri = std.Uri.parse(mirror) catch return null;
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return null;
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return null;
    return std.fmt.bufPrint(out, "{s}{s}", .{ mirror, url[base.len..] }) catch null;
}
pub fn cacheable(status: u16, valid: bool, size: usize) bool {
    return valid and status >= 200 and status < 300 and size > 0 and size <= 1024 * 1024;
}
pub fn fresh(stored: i64, now: i64, ttl: u32) bool {
    return ttl > 0 and now >= stored and now - stored < ttl;
}
test "mirror substitution respects authority and path boundaries" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://backup.test/api/chapters?q=a%20b", mirrorUrl(&out, "https://primary.test/api/chapters?q=a%20b", "https://primary.test/api", "https://backup.test/api/").?);
    try std.testing.expect(mirrorUrl(&out, "https://primary.test.evil/chapters", "https://primary.test", "https://backup.test") == null);
    try std.testing.expect(mirrorUrl(&out, "https://primary.test/a", "https://primary.test", "https://user:pass@backup.test") == null);
    try std.testing.expect(mirrorUrl(&out, "https://primary.test/a", "https://primary.test", "file:///tmp") == null);
}
test "only bounded successful validated bodies have positive cache lifetime" {
    try std.testing.expect(cacheable(200, true, 500));
    try std.testing.expect(!cacheable(503, true, 500));
    try std.testing.expect(!cacheable(200, false, 500));
    try std.testing.expect(!cacheable(200, true, 1024 * 1024 + 1));
    try std.testing.expect(fresh(100, 110, 50));
    try std.testing.expect(!fresh(100, 150, 50));
    try std.testing.expect(!fresh(100, 90, 50));
}

pub fn publicUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (uri.host == null or uri.user != null or uri.password != null) return false;
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return false;
    var lower: [4096]u8 = undefined;
    if (url.len > lower.len) return false;
    for (url, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    for ([_][]const u8{ "token=", "key=", "password=", "secret=", "auth=", "signature=", "sig=" }) |name| {
        if (std.mem.indexOf(u8, lower[0..url.len], name) != null) return false;
    }
    // Encoded query keys are conservatively excluded from shared caching/failover.
    if (uri.query != null) {
        const start = std.mem.indexOfScalar(u8, url, '?') orelse return false;
        var fields = std.mem.splitScalar(u8, url[start + 1 ..], '&');
        while (fields.next()) |field| {
            const end = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
            if (std.mem.indexOfScalar(u8, field[0..end], '%') != null) return false;
        }
    }
    return true;
}
pub fn publicHeader(name: []const u8) bool {
    for ([_][]const u8{ "Accept", "Accept-Language", "User-Agent", "Referer", "Origin", "Content-Type" }) |allowed| {
        if (std.ascii.eqlIgnoreCase(name, allowed)) return true;
    }
    return false;
}
test "private URL credentials and unknown credential headers never fail over or cache" {
    try std.testing.expect(publicUrl("https://api.test/search?q=x%20y"));
    try std.testing.expect(!publicUrl("https://u:p@api.test/a"));
    try std.testing.expect(!publicUrl("https://api.test/a?access_token=s"));
    try std.testing.expect(!publicUrl("https://api.test/a?%74oken=s"));
    try std.testing.expect(!publicHeader("X-Plex-Token"));
    try std.testing.expect(!publicHeader("X-Emby-Token"));
    try std.testing.expect(!publicHeader("Cookie"));
    try std.testing.expect(publicHeader("Accept"));
}
