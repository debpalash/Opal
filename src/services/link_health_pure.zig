//! App-wide stream-health classifier — PURE, tested, no I/O.
//!
//! Extracted from iptv_pure.zig so every vertical that plays a remote URL
//! (Live TV, Radio, …) classifies a probe the SAME way. `link_health.zig` owns
//! the probe pool + persistence; this file owns the decisions and is the single
//! implementation (iptv_pure.zig re-exports these names for its callers).

const std = @import("std");

/// Result of probing a stream URL. Persisted as the int value in `link_health`
/// (and the legacy `iptv_health`) — the numbers are on-disk, don't renumber.
pub const Status = enum(u8) {
    unknown = 0,
    live = 1,
    slow = 2, // reachable + playable but sluggish to first byte
    dead = 3,
};

/// A response body "looks playable" when it is an HLS playlist (`#EXTM3U`,
/// ignoring leading BOM/whitespace). Non-m3u8 targets don't get this check — a
/// 2xx is enough — so this only gates m3u8 probes (see the classify caller).
pub fn looksLikePlaylist(body: []const u8) bool {
    var s = body;
    if (s.len >= 3 and s[0] == 0xEF and s[1] == 0xBB and s[2] == 0xBF) s = s[3..]; // UTF-8 BOM
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\n' or s[i] == '\r' or s[i] == '\t')) i += 1;
    return std.mem.startsWith(u8, s[i..], "#EXTM3U");
}

/// Recognize an HLS/m3u8 playlist URL (path ends in `.m3u8`/`.m3u`, ignoring a
/// trailing `?query`/`#fragment`). Also surfaced as an "HLS" badge in the UI, so
/// the tested logic is the shipped logic.
pub fn isM3u8(url: []const u8) bool {
    var path = url;
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
    return std.mem.endsWith(u8, path, ".m3u8") or std.mem.endsWith(u8, path, ".m3u");
}

/// Latency above this (strictly) demotes a reachable stream to `.slow`.
pub const SLOW_MS: u32 = 4000;

/// Classify a probe. `http_code` 0 means connect/DNS failure. `playable` is
/// whether the payload passed its content check (playlist validity for m3u8;
/// true for non-m3u8 2xx). `slow` latencies still count as reachable.
pub fn classify(http_code: u32, playable: bool, latency_ms: u32) Status {
    if (http_code == 0 or http_code >= 400) return .dead; // DNS/connect fail, 4xx/5xx
    if (!playable) return .dead; // 2xx but not a real stream (login/error page)
    if (latency_ms > SLOW_MS) return .slow;
    return .live;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "looksLikePlaylist detects #EXTM3U past BOM/whitespace" {
    try std.testing.expect(looksLikePlaylist("#EXTM3U\n#EXT-X-VERSION:3"));
    try std.testing.expect(looksLikePlaylist("  \n#EXTM3U"));
    try std.testing.expect(looksLikePlaylist("\xEF\xBB\xBF#EXTM3U"));
    // BOM + whitespace together (the order the trim runs in).
    try std.testing.expect(looksLikePlaylist("\xEF\xBB\xBF \r\n\t#EXTM3U"));
    try std.testing.expect(!looksLikePlaylist("<html>login</html>"));
    try std.testing.expect(!looksLikePlaylist(""));
    try std.testing.expect(!looksLikePlaylist("\xEF\xBB\xBF")); // BOM only
    try std.testing.expect(!looksLikePlaylist("#EXTM3")); // truncated tag
}

test "isM3u8 recognizes HLS playlists incl. query/fragment" {
    try std.testing.expect(isM3u8("https://a/b/index.m3u8"));
    try std.testing.expect(isM3u8("https://a/b/playlist.m3u8?token=abc"));
    try std.testing.expect(isM3u8("https://a/b/live.m3u#x"));
    try std.testing.expect(!isM3u8("https://a/b/stream.ts"));
    try std.testing.expect(!isM3u8("https://a/b/live.mpd"));
    try std.testing.expect(!isM3u8(""));
}

test "classify maps code/playable/latency to status" {
    try std.testing.expectEqual(Status.dead, classify(0, true, 100)); // DNS/connect fail
    try std.testing.expectEqual(Status.dead, classify(403, true, 100)); // Cloudflare/geo
    try std.testing.expectEqual(Status.dead, classify(200, false, 100)); // 200 but not a stream
    try std.testing.expectEqual(Status.live, classify(200, true, 500));
    try std.testing.expectEqual(Status.slow, classify(200, true, 6000));
}

test "classify: every http_code band" {
    try std.testing.expectEqual(Status.live, classify(200, true, 0));
    try std.testing.expectEqual(Status.live, classify(206, true, 10)); // ranged GET (-r 0-2047)
    try std.testing.expectEqual(Status.live, classify(302, true, 10)); // redirect still reachable
    try std.testing.expectEqual(Status.dead, classify(400, true, 10));
    try std.testing.expectEqual(Status.dead, classify(404, true, 10));
    try std.testing.expectEqual(Status.dead, classify(500, true, 10)); // 5xx
    try std.testing.expectEqual(Status.dead, classify(503, true, 10));
    // A dead code wins over a fast latency, and over playable.
    try std.testing.expectEqual(Status.dead, classify(0, false, 0));
}

test "classify: SLOW_MS is an exclusive boundary" {
    try std.testing.expectEqual(Status.live, classify(200, true, SLOW_MS - 1));
    try std.testing.expectEqual(Status.live, classify(200, true, SLOW_MS)); // exactly at → still live
    try std.testing.expectEqual(Status.slow, classify(200, true, SLOW_MS + 1));
    // Slow only applies to otherwise-healthy probes.
    try std.testing.expectEqual(Status.dead, classify(404, true, SLOW_MS + 1));
    try std.testing.expectEqual(Status.dead, classify(200, false, SLOW_MS + 1));
}

test "Status int values are the persisted encoding" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Status.unknown));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Status.live));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Status.slow));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Status.dead));
    try std.testing.expectEqual(Status.dead, @as(Status, @enumFromInt(@as(u8, 3))));
}
