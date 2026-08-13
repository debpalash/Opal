const std = @import("std");

/// One coherent, allocation-free view of the mpv properties needed by the UI.
/// MediaPlayer updates it from property-change events; render code only reads it.
pub const Snapshot = struct {
    paused: bool = true,
    paused_for_cache: bool = false,
    time_pos: f64 = 0,
    duration: f64 = 0,
    volume: f64 = 100,
    speed: f64 = 1,
    muted: bool = false,
    playlist_count: i64 = 0,
    playlist_pos: i64 = 0,
    video_width: i64 = 0,
    video_height: i64 = 0,

    pub fn percent(self: Snapshot) f64 {
        const pos = finiteNonNegative(self.time_pos);
        const dur = finiteNonNegative(self.duration);
        if (dur <= 0) return 0;
        return std.math.clamp(pos / dur * 100.0, 0.0, 100.0);
    }
};

pub const RenderSize = struct { width: u32, height: u32 };

/// Fit the decoded video into the reusable software-render buffer without
/// upscaling smaller sources. Invalid/unavailable metadata uses the full buffer.
pub fn renderSize(video_width: i64, video_height: i64, max_width: u32, max_height: u32) RenderSize {
    if (video_width <= 0 or video_height <= 0 or max_width < 2 or max_height < 2)
        return .{ .width = max_width, .height = max_height };

    const vw: u64 = @intCast(video_width);
    const vh: u64 = @intCast(video_height);
    if (vw <= max_width and vh <= max_height)
        return .{ .width = @intCast(vw), .height = @intCast(vh) };

    // Integer math keeps this deterministic and avoids precision loss on
    // malformed, extremely large dimensions.
    const width_limited = @as(u128, vw) * max_height > @as(u128, vh) * max_width;
    if (width_limited) {
        return .{
            .width = max_width,
            .height = @max(2, @as(u32, @intCast(@as(u128, vh) * max_width / vw))),
        };
    }
    return .{
        .width = @max(2, @as(u32, @intCast(@as(u128, vw) * max_height / vh))),
        .height = max_height,
    };
}

fn finiteNonNegative(value: f64) f64 {
    if (!std.math.isFinite(value) or value < 0) return 0;
    return value;
}

test "snapshot percent is finite and clamped" {
    try std.testing.expectEqual(@as(f64, 25), (Snapshot{ .time_pos = 30, .duration = 120 }).percent());
    try std.testing.expectEqual(@as(f64, 100), (Snapshot{ .time_pos = 121, .duration = 120 }).percent());
    try std.testing.expectEqual(@as(f64, 0), (Snapshot{ .time_pos = std.math.nan(f64), .duration = 120 }).percent());
    try std.testing.expectEqual(@as(f64, 0), (Snapshot{ .time_pos = 1, .duration = 0 }).percent());
}

test "render size preserves aspect and never upscales" {
    try std.testing.expectEqual(RenderSize{ .width = 1280, .height = 720 }, renderSize(1280, 720, 1920, 1080));
    try std.testing.expectEqual(RenderSize{ .width = 1920, .height = 1080 }, renderSize(3840, 2160, 1920, 1080));
    try std.testing.expectEqual(RenderSize{ .width = 607, .height = 1080 }, renderSize(1080, 1920, 1920, 1080));
    try std.testing.expectEqual(RenderSize{ .width = 1920, .height = 1080 }, renderSize(0, 0, 1920, 1080));
    try std.testing.expectEqual(RenderSize{ .width = 1920, .height = 2 }, renderSize(std.math.maxInt(i64), 1, 1920, 1080));
}
