//! The first mobile player shares desktop browser URL validation.
const std = @import("std");
const links = @import("browser_link_pure.zig");
pub fn mediaLink(raw: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    // Magnets go to the shared torrent engine, exactly like a desktop paste.
    if (std.ascii.startsWithIgnoreCase(value, "magnet:?xt=urn:bt")) {
        if (value.len > 2047) return null;
        for (value) |ch| if (ch < 0x21 or ch == 0x7f) return null;
        return value;
    }
    links.validateHttpUrl(value, 2047) catch return null;
    return value;
}
test "iOS media links preserve stream queries and reject credentials or executable schemes" {
    try std.testing.expectEqualStrings("https://media.example/video.m3u8?token=a%26b", mediaLink(" https://media.example/video.m3u8?token=a%26b\n").?);
    for ([_][]const u8{ "", "javascript:alert(1)", "file:///etc/passwd", "https://user:pass@media.example/video.mp4", "https://media.example/a\r\nHeader:x" }) |bad| try std.testing.expect(mediaLink(bad) == null);
    const huge: [2048]u8 = @splat('x');
    try std.testing.expect(mediaLink(&huge) == null);
}

test "iOS media links accept torrent magnets but not malformed ones" {
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=x", mediaLink(" magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=x ").?);
    try std.testing.expect(mediaLink("magnet:?dn=no-hash") == null);
    try std.testing.expect(mediaLink("magnet:?xt=urn:btih:abc\r\nX") == null);
}
