//! Shared policy for cache-backed routes that reconnect after transient errors.

const std = @import("std");

pub fn retryDelayMs(attempt: u8) i64 {
    const delays = [_]i64{ 1_000, 2_000, 5_000, 10_000, 30_000 };
    return delays[@min(if (attempt > 0) attempt - 1 else 0, delays.len - 1)];
}

pub fn nextAttempt(current: u8) u8 {
    return if (current == std.math.maxInt(u8)) current else current + 1;
}

pub fn isXmlFeed(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "<rss") != null or std.mem.indexOf(u8, body, "<feed") != null;
}

test "route retry backoff is bounded" {
    try std.testing.expectEqual(@as(i64, 1_000), retryDelayMs(0));
    try std.testing.expectEqual(@as(i64, 1_000), retryDelayMs(1));
    try std.testing.expectEqual(@as(i64, 5_000), retryDelayMs(3));
    try std.testing.expectEqual(@as(i64, 30_000), retryDelayMs(99));
    try std.testing.expectEqual(std.math.maxInt(u8), nextAttempt(std.math.maxInt(u8)));
}

test "route feed validation rejects transport error pages" {
    try std.testing.expect(isXmlFeed("<?xml version=\"1.0\"?><rss><channel></channel></rss>"));
    try std.testing.expect(isXmlFeed("<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>"));
    try std.testing.expect(!isXmlFeed("<html><title>502 Bad Gateway</title></html>"));
    try std.testing.expect(!isXmlFeed(""));
}
