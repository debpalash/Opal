//! Native title-bar hit regions in fractions of the SDL/Win32 window.
//! The player paints the bar inside the user-scale widget; other routes paint
//! it before that widget. OS display DPI is already reflected in window points.

const std = @import("std");

pub const HEIGHT: f32 = 30;
pub const BUTTON_WIDTH: f32 = 44;
const BUTTON_COUNT: f32 = 3;

pub const HitRegion = struct {
    band_fraction: f32,
    controls_fraction: f32,
};

pub fn hitRegion(window_w: f32, window_h: f32, user_scale: f32) HitRegion {
    const scale = if (std.math.isFinite(user_scale) and user_scale > 0) user_scale else 1.0;
    return .{
        .band_fraction = if (window_h > 0) std.math.clamp(HEIGHT * scale / window_h, 0, 1) else 0.05,
        .controls_fraction = if (window_w > 0) std.math.clamp(1 - BUTTON_COUNT * BUTTON_WIDTH * scale / window_w, 0, 1) else 0.85,
    };
}

test "player title controls remain inside a high-DPI laptop window" {
    // 1366x768 physical at Windows 150%: SDL's window points are ~911x512.
    // UI scale 1.5 enlarges the player overlay; the native hit test must use
    // the same right edge, rather than the unscaled 132-point boundary.
    const width: f32 = 1366.0 / 1.5;
    const height: f32 = 768.0 / 1.5;
    const region = hitRegion(width, height, 1.5);
    const control_left = region.controls_fraction * width;
    try std.testing.expectApproxEqAbs(@as(f32, 198), width - control_left, 0.01);
    try std.testing.expect(control_left >= 0 and control_left < width);
    try std.testing.expectApproxEqAbs(@as(f32, 45), region.band_fraction * height, 0.01);
    // Outside the player scale layer, the strip stays native-sized.
    const normal = hitRegion(width, height, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 132), width - normal.controls_fraction * width, 0.01);
}

test "controls keep a draggable band on a narrow scaled window" {
    const region = hitRegion(500, 400, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 236), region.controls_fraction * 500, 0.01);
    try std.testing.expect(region.band_fraction > 0 and region.band_fraction < 1);
}
