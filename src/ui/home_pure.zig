//! Pure display logic for the Home console — no io, no dvui.

const std = @import("std");

/// True for bare content-hash names ("8248045d177933fc") that watch history
/// records for torrent streams. The Home console shows those as a friendly
/// "Torrent stream" label instead of raw hex.
pub fn looksLikeHexHash(name: []const u8) bool {
    if (name.len < 12) return false;
    for (name) |ch| {
        const hex = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!hex) return false;
    }
    return true;
}

test "looksLikeHexHash flags bare content hashes only" {
    try std.testing.expect(looksLikeHexHash("8248045d177933fc"));
    try std.testing.expect(looksLikeHexHash("DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF")); // 40-char infohash
    try std.testing.expect(!looksLikeHexHash("Dune Part Two"));
    try std.testing.expect(!looksLikeHexHash("deadbeef")); // too short — could be a word
    try std.testing.expect(!looksLikeHexHash("8248045d177933fc mkv")); // space → cleaned filename
    try std.testing.expect(!looksLikeHexHash(""));
}

/// Time-aware greeting eyebrow for the hero. Hour is local, 0-23.
pub fn greetingForHour(hour: u8) []const u8 {
    if (hour < 5) return "Late night session";
    if (hour < 12) return "Good morning";
    if (hour < 18) return "Good afternoon";
    return "Good evening";
}

/// Hero headline: "tonight" after dark, "today" otherwise.
pub fn headlineForHour(hour: u8) []const u8 {
    if (hour >= 18 or hour < 5) return "What are we watching tonight?";
    return "What are we watching today?";
}

/// Copy `name` into `out` clipped to `max_bytes` on a UTF-8 boundary,
/// appending an ellipsis when clipped. `out` must hold max_bytes + 3.
pub fn clipLabel(out: []u8, name: []const u8, max_bytes: usize) []const u8 {
    if (name.len <= max_bytes) {
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }
    var end = max_bytes;
    // Back off UTF-8 continuation bytes so we never cut mid-codepoint.
    while (end > 0 and (name[end] & 0xC0) == 0x80) end -= 1;
    @memcpy(out[0..end], name[0..end]);
    @memcpy(out[end..][0..3], "\xe2\x80\xa6"); // …
    return out[0 .. end + 3];
}

test "greeting + headline cover the day" {
    try std.testing.expectEqualStrings("Late night session", greetingForHour(2));
    try std.testing.expectEqualStrings("Good morning", greetingForHour(9));
    try std.testing.expectEqualStrings("Good afternoon", greetingForHour(14));
    try std.testing.expectEqualStrings("Good evening", greetingForHour(21));
    try std.testing.expectEqualStrings("What are we watching tonight?", headlineForHour(22));
    try std.testing.expectEqualStrings("What are we watching today?", headlineForHour(10));
}

test "clipLabel clips on UTF-8 boundaries with ellipsis" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("short", clipLabel(&buf, "short", 10));
    try std.testing.expectEqualStrings("exactlyten", clipLabel(&buf, "exactlyten", 10));
    try std.testing.expectEqualStrings("longer nam\xe2\x80\xa6", clipLabel(&buf, "longer name here", 10));
    // 2-byte é straddles the cut — must back off, not split.
    try std.testing.expectEqualStrings("caf\xe2\x80\xa6", clipLabel(&buf, "caf\xc3\xa9 society", 4));
}
