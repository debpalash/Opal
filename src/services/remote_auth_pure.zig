//! Pure parsing for browser-session cookies.

const std = @import("std");

pub fn cookieValue(header: []const u8, wanted: []const u8) ?[]const u8 {
    if (wanted.len == 0) return null;
    var cookies = std.mem.splitScalar(u8, header, ';');
    while (cookies.next()) |raw| {
        const cookie = std.mem.trim(u8, raw, " \t");
        const eq = std.mem.indexOfScalar(u8, cookie, '=') orelse continue;
        if (std.mem.eql(u8, cookie[0..eq], wanted)) return cookie[eq + 1 ..];
    }
    return null;
}

test "session cookie is selected exactly" {
    try std.testing.expectEqualStrings("abc123", cookieValue("theme=dark; opal_session=abc123; x=1", "opal_session").?);
    try std.testing.expect(cookieValue("not_opal_session=x", "opal_session") == null);
    try std.testing.expectEqualStrings("", cookieValue("opal_session=", "opal_session").?);
}
