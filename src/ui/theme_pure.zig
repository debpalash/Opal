const std = @import("std");

/// Standard motion durations (milliseconds).
pub const duration = struct {
    pub const fast: f32 = 120;
    pub const base: f32 = 200;
    pub const slow: f32 = 320;
};

// Layout tokens. Shared by every theme preset (colors vary per preset; the
// geometry does not). theme.zig re-exports these as theme.spacing /
// theme.radius / theme.font_size.

/// Spacing — 4px-based scale.
pub const spacing = struct {
    pub const xxs: f32 = 2; // hairline gaps: icon-to-badge, stacked meta lines
    pub const xs: f32 = 4;
    pub const sm: f32 = 8;
    pub const md: f32 = 12;
    pub const lg: f32 = 16;
    pub const xl: f32 = 24;
    pub const xxl: f32 = 32;
    pub const xxxl: f32 = 48; // hero/empty-state breathing room
};

/// Corner radii. Softer scale (was 2/3/6/8/12). Rule of thumb: controls
/// (buttons, inputs, segments, rows) = sm; cards/posters/tooltips = md;
/// floating bars, dialogs, popovers = lg; hero sheets = xl. Nested shapes use
/// one step smaller than their container so inner/outer curves stay concentric.
pub const radius = struct {
    pub const xs: f32 = 3;
    pub const sm: f32 = 5;
    pub const md: f32 = 7;
    pub const lg: f32 = 10;
    pub const xl: f32 = 14;
    pub const pill: f32 = 999;
};

/// Type ramp — COMPACT, in dvui logical units (dvui's own default body is 10;
/// the backend multiplies by the display's content scale). Most of the app
/// used to render at the dvui default 10 while components.zig used 13 — two
/// visibly different "body" sizes side by side. Unified DOWN to the compact
/// end: a media player's chrome should stay quiet at 1x scale.
pub const font_size = struct {
    pub const micro: f32 = 9;
    pub const small: f32 = 10;
    pub const body: f32 = 11;
    pub const subtitle: f32 = 13; // card titles, dialog subheads
    pub const title: f32 = 15; // section/page headings (dvui font_heading)
    pub const headline: f32 = 18; // detail-page titles
    pub const display: f32 = 22; // hero titles (dvui font_title)
};

fn expectAscending(steps: []const f32) !void {
    for (steps[1..], steps[0 .. steps.len - 1]) |v, prev| try std.testing.expect(v > prev);
}

test "spacing is the 4px scale, ascending" {
    const steps = [_]f32{ spacing.xxs, spacing.xs, spacing.sm, spacing.md, spacing.lg, spacing.xl, spacing.xxl, spacing.xxxl };
    try expectAscending(&steps);
    for (steps[1..]) |v| try std.testing.expectEqual(@as(f32, 0), @mod(v, 4));
    try std.testing.expectEqual(@as(f32, 2), spacing.xxs);
}

test "radius steps ascend so nested shapes can step down one" {
    try expectAscending(&.{ radius.xs, radius.sm, radius.md, radius.lg, radius.xl, radius.pill });
}

test "font_size ramp ascends and body sits at the compact 11" {
    try expectAscending(&.{ font_size.micro, font_size.small, font_size.body, font_size.subtitle, font_size.title, font_size.headline, font_size.display });
    try std.testing.expectEqual(@as(f32, 11), font_size.body);
}

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
