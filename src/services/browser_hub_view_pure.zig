//! Wording and cut-offs for the Browser hub (Browse > Web). Pure, so the strings
//! the user reads and the length limits that keep every row a fixed size are
//! tested without a window.

const std = @import("std");
const page = @import("browser_page_pure.zig");

/// A paired browser that has not talked to Opal for this long is "away", and
/// after a day the hub just says how long ago.
pub fn seenText(buf: []u8, now: i64, last_seen: i64) []const u8 {
    const ago = @max(now - last_seen, 0);
    if (page.connected(now, last_seen)) return "connected";
    if (ago < 3600) return std.fmt.bufPrint(buf, "seen {d} min ago", .{@divTrunc(ago, 60)}) catch "";
    if (ago < 86400) return std.fmt.bufPrint(buf, "seen {d} h ago", .{@divTrunc(ago, 3600)}) catch "";
    return std.fmt.bufPrint(buf, "seen {d} d ago", .{@divTrunc(ago, 86400)}) catch "";
}

/// Cut `s` to at most `max_chars` characters (not bytes) and add an ellipsis
/// when something was removed. Writes into `out` (needs `max_chars * 4 + 3`).
pub fn clip(out: []u8, s: []const u8, max_chars: usize) []const u8 {
    var chars: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + len > s.len) break;
        if (chars == max_chars) break;
        chars += 1;
        i += len;
    }
    if (i >= s.len) {
        const n = @min(s.len, out.len);
        @memcpy(out[0..n], s[0..n]);
        return out[0..n];
    }
    const room = if (out.len > 3) out.len - 3 else 0;
    const n = @min(i, room);
    @memcpy(out[0..n], s[0..n]);
    if (n + 3 <= out.len) {
        @memcpy(out[n .. n + 3], "\xe2\x80\xa6");
        return out[0 .. n + 3];
    }
    return out[0..n];
}

/// How big the shared text is, for the card ("3.2 KB of text").
pub fn textSizeText(buf: []u8, bytes: usize) []const u8 {
    if (bytes == 0) return "no page text";
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} bytes of text", .{bytes}) catch "";
    return std.fmt.bufPrint(buf, "{d}.{d} KB of text", .{ bytes / 1024, (bytes % 1024) * 10 / 1024 }) catch "";
}

/// Who may read the shared page, for the card. Agents need both consents.
pub fn agentsText(page_agents: bool, switch_on: bool) []const u8 {
    if (!page_agents) return "Agents cannot read this page (you did not tick the box when sharing)";
    if (!switch_on) return "You allowed agents for this page, but Settings > Agent Access > Let agents read shared pages is off";
    return "Agents can read this page (it is untrusted text, and they are told so)";
}

const testing = std.testing;

test "seenText: connected, minutes, hours, days" {
    var b: [48]u8 = undefined;
    try testing.expectEqualStrings("connected", seenText(&b, 1000, 900));
    try testing.expectEqualStrings("seen 5 min ago", seenText(&b, 1000 + 300, 1000));
    try testing.expectEqualStrings("seen 3 h ago", seenText(&b, 1000 + 3 * 3600 + 10, 1000));
    try testing.expectEqualStrings("seen 2 d ago", seenText(&b, 1000 + 2 * 86400 + 5, 1000));
    // A clock that moved back is not "in the future".
    try testing.expectEqualStrings("connected", seenText(&b, 1000, 1000));
}

test "clip counts characters, keeps characters whole and marks the cut" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", clip(&b, "hello", 10));
    try testing.expectEqualStrings("hel\xe2\x80\xa6", clip(&b, "hello", 3));
    try testing.expectEqualStrings("\xc3\xa9\xc3\xa9\xe2\x80\xa6", clip(&b, "\xc3\xa9\xc3\xa9\xc3\xa9", 2));
    try testing.expectEqualStrings("", clip(&b, "", 5));
    var tiny: [4]u8 = undefined;
    try testing.expect(clip(&tiny, "abcdefgh", 6).len <= tiny.len);
}

test "textSizeText and agentsText" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("no page text", textSizeText(&b, 0));
    try testing.expectEqualStrings("512 bytes of text", textSizeText(&b, 512));
    try testing.expectEqualStrings("8.0 KB of text", textSizeText(&b, 8192));
    try testing.expect(std.mem.indexOf(u8, agentsText(false, true), "cannot") != null);
    try testing.expect(std.mem.indexOf(u8, agentsText(true, false), "off") != null);
    try testing.expect(std.mem.indexOf(u8, agentsText(true, true), "can read") != null);
}
