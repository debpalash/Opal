//! Pure retry policy for durable third-party synchronization.

const std = @import("std");

pub fn retryDelaySeconds(attempts: u32) i64 {
    const schedule = [_]i64{ 2, 10, 30, 120, 300, 900 };
    return schedule[@min(attempts, schedule.len - 1)];
}

test "retry schedule is bounded exponential backoff" {
    try std.testing.expectEqual(@as(i64, 2), retryDelaySeconds(0));
    try std.testing.expectEqual(@as(i64, 120), retryDelaySeconds(3));
    try std.testing.expectEqual(@as(i64, 900), retryDelaySeconds(99));
}
