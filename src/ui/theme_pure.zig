const std = @import("std");

/// Standard motion durations (milliseconds).
pub const duration = struct {
    pub const fast: f32 = 120;
    pub const base: f32 = 200;
    pub const slow: f32 = 320;
};

/// Cubic ease-in-out over a normalized t in [0,1].
pub fn easeInOut(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    if (x < 0.5) return 4 * x * x * x;
    const f = -2 * x + 2;
    return 1 - (f * f * f) / 2;
}

/// Triangle wave in [0,1]: 0 at phase 0, 1 at the midpoint, back to 0.
/// `t_ms` is an absolute time; `period_ms` the cycle length.
pub fn pulse(t_ms: f32, period_ms: f32) f32 {
    if (period_ms <= 0) return 0;
    const phase = @mod(t_ms, period_ms) / period_ms; // 0..1
    return 1 - @abs(2 * phase - 1);
}

pub const SkeletonMotion = struct { phase: f32, glow: f32, animate: bool };
pub fn skeletonMotion(now_ms: i64, reduced: bool) SkeletonMotion {
    if (reduced) return .{ .phase = 0.5, .glow = 0.25, .animate = false };
    const cycle: f32 = @floatFromInt(@mod(now_ms, 1400));
    return .{ .phase = cycle / 1400, .glow = pulse(cycle, 1400), .animate = true };
}

test "Skeleton reduced motion stays stable without requesting animation frames" {
    const first = skeletonMotion(0, true);
    const later = skeletonMotion(9876, true);
    try std.testing.expectEqual(first, later);
    try std.testing.expect(!first.animate);
    for ([_]i64{ -1, 0, 700, 1400, 9876 }) |now| {
        const motion = skeletonMotion(now, false);
        try std.testing.expect(motion.animate);
        try std.testing.expect(motion.phase >= 0 and motion.phase <= 1);
        try std.testing.expect(motion.glow >= 0 and motion.glow <= 1);
    }
}

/// Line-height in pixels for a font size + ratio (e.g. 1.4).
pub fn lineHeightPx(size_px: f32, ratio: f32) f32 {
    return size_px * ratio;
}

test "easeInOut endpoints and midpoint" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), easeInOut(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), easeInOut(1.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), easeInOut(0.5), 1e-6);
}

test "easeInOut clamps out-of-range input" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), easeInOut(-3.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), easeInOut(9.0), 1e-6);
}

test "pulse triangle wave" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pulse(0, 200), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pulse(100, 200), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pulse(200, 200), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), pulse(50, 0)); // guard period<=0
}

test "lineHeightPx" {
    try std.testing.expectApproxEqAbs(@as(f32, 18.2), lineHeightPx(13, 1.4), 1e-4);
}
