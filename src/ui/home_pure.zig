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

/// Home shows the chat transcript while a conversation exists — unless the
/// user explicitly stepped back to the overview (logo click). A new message
/// (count grew) always pulls the page back into the chat.
pub fn chatModeActive(msg_count: usize, generating: bool, overview_requested: bool) bool {
    if (overview_requested) return false;
    return msg_count > 0 or generating;
}

test "chatModeActive respects the overview escape hatch" {
    try std.testing.expect(chatModeActive(3, false, false));
    try std.testing.expect(chatModeActive(0, true, false));
    try std.testing.expect(!chatModeActive(3, false, true)); // logo click wins
    try std.testing.expect(!chatModeActive(0, false, false));
}

/// If `link` points at the local filesystem, return the plain fs path
/// (strips a file:// scheme); null for streams/magnets/http — those can't
/// be existence-checked and are always shown.
pub fn localFsPath(link: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, link, "file://")) return link[7..];
    if (link.len > 0 and link[0] == '/') return link;
    return null;
}

test "localFsPath: local files verifiable, streams passed through" {
    try std.testing.expectEqualStrings("/a/b.mkv", localFsPath("/a/b.mkv").?);
    try std.testing.expectEqualStrings("/a/b.mkv", localFsPath("file:///a/b.mkv").?);
    try std.testing.expect(localFsPath("magnet:?xt=urn:btih:abc") == null);
    try std.testing.expect(localFsPath("https://x.test/v.m3u8") == null);
    try std.testing.expect(localFsPath("") == null);
}
