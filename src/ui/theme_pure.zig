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

// ── Color math (WCAG 2.x) — shared by theme.zig's comptime palette gate and
// components.zig's state-color mixing so the tested logic is the shipped one.

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// WCAG minimums: body/caption text, and non-text UI (icons, focus rings).
pub const min_text: f64 = 4.5;
pub const min_ui: f64 = 3.0;

fn linearChannel(v: u8) f64 {
    const c = @as(f64, @floatFromInt(v)) / 255.0;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

pub fn relativeLuminance(c: Rgb) f64 {
    return 0.2126 * linearChannel(c.r) + 0.7152 * linearChannel(c.g) + 0.0722 * linearChannel(c.b);
}

pub fn contrastRatio(a: Rgb, b: Rgb) f64 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// Linear blend of one 8-bit channel, t clamped to [0,1].
pub fn mixChannel(a: u8, b: u8, t_raw: f32) u8 {
    const t = std.math.clamp(t_raw, 0, 1);
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    return @intFromFloat(@round(fa + (fb - fa) * t));
}

/// Comptime gate used by theme.zig: fail the build on an unreadable pair.
pub fn assertContrast(fg: Rgb, bg: Rgb, min: f64) void {
    if (contrastRatio(fg, bg) < min) @compileError(std.fmt.comptimePrint(
        "theme contrast {d:.2}:1 < {d:.1}:1 for fg {any} on bg {any}",
        .{ contrastRatio(fg, bg), min, fg, bg },
    ));
}

/// Surface ladder must strictly brighten at every step.
pub fn assertLadder(steps: []const Rgb) void {
    var i: usize = 1;
    while (i < steps.len) : (i += 1) {
        if (!(relativeLuminance(steps[i]) > relativeLuminance(steps[i - 1])))
            @compileError(std.fmt.comptimePrint("theme surface ladder not increasing at step {d}", .{i}));
    }
}

test "contrastRatio matches WCAG reference values" {
    const black = Rgb{ .r = 0, .g = 0, .b = 0 };
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expectApproxEqAbs(@as(f64, 21.0), contrastRatio(black, white), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), contrastRatio(white, white), 1e-9);
    // Symmetric.
    const grey = Rgb{ .r = 118, .g = 118, .b = 118 }; // ~4.54:1 on white
    try std.testing.expectApproxEqAbs(contrastRatio(grey, white), contrastRatio(white, grey), 1e-12);
    try std.testing.expect(contrastRatio(grey, white) > 4.5 and contrastRatio(grey, white) < 4.6);
}

test "regression: old solarized dark ink on muted orange was below AA" {
    // 160,85,50 accent with base03 ink measures 2.75:1 — the gate must catch it.
    try std.testing.expect(contrastRatio(.{ .r = 0, .g = 43, .b = 54 }, .{ .r = 160, .g = 85, .b = 50 }) < min_text);
}

test "mixChannel endpoints, midpoint and clamp" {
    try std.testing.expectEqual(@as(u8, 10), mixChannel(10, 200, 0));
    try std.testing.expectEqual(@as(u8, 200), mixChannel(10, 200, 1));
    try std.testing.expectEqual(@as(u8, 105), mixChannel(10, 200, 0.5));
    try std.testing.expectEqual(@as(u8, 200), mixChannel(10, 200, 7));
    try std.testing.expectEqual(@as(u8, 10), mixChannel(10, 200, -1));
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
