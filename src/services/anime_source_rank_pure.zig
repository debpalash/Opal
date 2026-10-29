//! Rank measured resolution success/latency; recent failures remain fallbacks.
const std = @import("std");
pub const Observation = struct {
    successes: u32 = 0,
    latency_ms: u32 = 0,
    failed_at: i64 = 0,
};
pub fn score(observation: Observation, fallback_order: usize, now: i64) u64 {
    const failed: u64 = if (observation.failed_at > 0 and now >= observation.failed_at and now - observation.failed_at < 300_000) 60_000 else 0;
    return failed + if (observation.successes > 0) @as(u64, @min(observation.latency_ms, 30_000)) else 35_000 + @as(u64, fallback_order);
}
pub fn record(previous: Observation, elapsed: u32, success: bool, now: i64) Observation {
    if (!success) return .{ .successes = previous.successes, .latency_ms = previous.latency_ms, .failed_at = now };
    return .{ .successes = previous.successes +| 1, .latency_ms = if (previous.successes == 0) elapsed else @intCast((@as(u64, previous.latency_ms) * 3 + elapsed) / 4) };
}
test "Anime provider speed rank prefers successful fast sources and recovers failures" {
    const fast = record(.{}, 400, true, 1000);
    const slow = record(.{}, 2000, true, 1000);
    try std.testing.expect(score(fast, 2, 1000) < score(slow, 0, 1000));
    const failed = record(fast, 4000, false, 2000);
    try std.testing.expect(score(failed, 0, 2001) > score(.{}, 1, 2001));
    try std.testing.expect(score(failed, 0, 302001) < score(.{}, 1, 302001));
    try std.testing.expectEqual(@as(i64, 0), record(failed, 500, true, 3000).failed_at);
}
