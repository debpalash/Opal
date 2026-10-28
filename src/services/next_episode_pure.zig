//! Predictive episode selection and once-per-load scheduling, without I/O.
const std = @import("std");
const tv = @import("tv_pure.zig");

pub fn nextAfter(seasons: []const tv.Season, current: tv.Ep, aired: tv.Ep) ?tv.Ep {
    if (current.season <= 0 or current.episode <= 0) return null;
    var next: ?tv.Ep = null;
    for (seasons) |s| {
        if (s.number < current.season or s.episode_count == 0) continue;
        const ep: tv.Ep = .{ .season = s.number, .episode = if (s.number == current.season) current.episode +| 1 else 1 };
        if (ep.episode > s.episode_count or ep.after(aired)) continue;
        if (next == null or next.?.after(ep)) next = ep;
    }
    return next;
}

pub fn shouldWarm(position: f64, duration: f64, paused: bool) bool {
    return !paused and std.math.isFinite(position) and std.math.isFinite(duration) and
        duration >= 60 and position >= @max(30, duration * 0.6) and position < duration;
}

test "predict next aired episode across season boundary without warming future episodes" {
    const seasons = [_]tv.Season{ .{ .number = 2, .episode_count = 8 }, .{ .number = 1, .episode_count = 10 } };
    try std.testing.expectEqual(tv.Ep{ .season = 2, .episode = 1 }, nextAfter(&seasons, .{ .season = 1, .episode = 10 }, .{ .season = 2, .episode = 2 }).?);
    try std.testing.expect(nextAfter(&seasons, .{ .season = 2, .episode = 2 }, .{ .season = 2, .episode = 2 }) == null);
}

test "warmup waits for sustained playback and rejects pause and invalid snapshots" {
    try std.testing.expect(!shouldWarm(10, 100, false));
    try std.testing.expect(shouldWarm(60, 100, false));
    try std.testing.expect(!shouldWarm(70, 100, true));
    try std.testing.expect(!shouldWarm(std.math.nan(f64), 100, false));
    try std.testing.expect(!shouldWarm(100, 100, false));
}
