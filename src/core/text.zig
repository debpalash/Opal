//! Small text helpers shared across renderers.

const std = @import("std");

/// Longest valid-UTF-8 prefix of `s`.
///
/// Titles, names, and overviews from network sources are copied into
/// fixed-size `[N]u8` buffers and can be truncated mid-codepoint (or carry
/// stray bytes). dvui's text layout asserts valid UTF-8
/// (`utf8ByteSequenceLength(...) catch unreachable`), so passing a raw buffer
/// slice straight to a label/button can panic the whole app. Any free text
/// drawn by dvui must pass through here first.
pub fn safeUtf8(s: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + n > s.len) break;
        _ = std.unicode.utf8Decode(s[i .. i + n]) catch break;
        i += n;
    }
    return s[0..i];
}

test "safeUtf8 passes valid through and trims invalid tail" {
    try std.testing.expectEqualStrings("hello", safeUtf8("hello"));
    // Valid 2-byte é (0xC3 0xA9) then a lone continuation byte 0xA9.
    try std.testing.expectEqualStrings("\xC3\xA9", safeUtf8("\xC3\xA9\xA9"));
    // Truncated leading byte of a 2-byte sequence at the very end.
    try std.testing.expectEqualStrings("ab", safeUtf8("ab\xC3"));
    // Lone start byte only.
    try std.testing.expectEqualStrings("", safeUtf8("\xFF"));
}
