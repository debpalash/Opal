//! Bound the mobile page to the screen even when its content has a tall minimum.
const std = @import("std");
pub const Insets = struct { top: f32 = 0, bottom: f32 = 0, left: f32 = 0, right: f32 = 0 };
pub const Viewport = struct { width: f32, height: f32, content_width: f32, content_height: f32, insets: Insets };
pub fn fit(width: f32, height: f32, requested: Insets) Viewport {
    const w = if (std.math.isFinite(width)) @max(1, width) else 1;
    const h = if (std.math.isFinite(height)) @max(1, height) else 1;
    const top = std.math.clamp(requested.top, 0, h - 1);
    const bottom = std.math.clamp(requested.bottom, 0, h - top - 1);
    const left = std.math.clamp(requested.left, 0, w - 1);
    const right = std.math.clamp(requested.right, 0, w - left - 1);
    return .{ .width = w, .height = h, .content_width = w - left - right, .content_height = h - top - bottom, .insets = .{ .top = top, .bottom = bottom, .left = left, .right = right } };
}
/// Edge-to-edge shell: the status bar is hidden and the home indicator
/// auto-hides, so only the hardware cutout (Dynamic Island / notch) and the
/// on-screen keyboard keep content off an edge. iOS reports the cutout edge as
/// its safe inset; the cutout itself ends ~cutout_slack pt before that.
pub const cutout_slack: f32 = 12;
pub fn immersive(safe: Insets, keyboard: f32) Insets {
    return .{
        .top = edge(safe.top),
        .bottom = @max(0, keyboard),
        .left = edge(safe.left),
        .right = edge(safe.right),
    };
}
fn edge(inset: f32) f32 {
    // Small insets are system bars (hidden), not a cutout.
    return if (inset > 24) inset - cutout_slack else 0;
}
/// Top offset that centres a control of `height` on the Dynamic Island /
/// notch, which spans ~11pt down to ~2pt above the band's bottom. No band:
/// a small edge margin.
pub fn bandOffset(band: f32, height: f32) f32 {
    if (band <= 0) return 8;
    const island_center = (11 + band - 2) / 2;
    return @max(0, @min(band - height, island_center - height / 2));
}
test "band controls centre on the island and fit inside the band" {
    const off = bandOffset(50, 32);
    try std.testing.expect(off >= 0 and off + 32 <= 50);
    try std.testing.expectApproxEqAbs(@as(f32, 29.5), off + 16, 1.0);
    try std.testing.expectEqual(@as(f32, 8), bandOffset(0, 32));
}
test "immersive shell reaches every edge except the cutout and keyboard" {
    const portrait = immersive(.{ .top = 62, .bottom = 34 }, 0);
    try std.testing.expectEqual(@as(f32, 50), portrait.top);
    try std.testing.expectEqual(@as(f32, 0), portrait.bottom);
    const typing = immersive(.{ .top = 62, .bottom = 34 }, 336);
    try std.testing.expectEqual(@as(f32, 336), typing.bottom);
    const landscape = immersive(.{ .left = 62, .right = 62, .bottom = 21 }, 0);
    try std.testing.expectEqual(@as(f32, 50), landscape.left);
    try std.testing.expectEqual(@as(f32, 0), landscape.bottom);
    const home_button = immersive(.{ .top = 20 }, 0);
    try std.testing.expectEqual(@as(f32, 0), home_button.top);
}
test "portrait landscape and keyboard layouts fit the full mobile display" {
    const portrait = fit(402, 874, .{ .top = 62, .bottom = 34 });
    try std.testing.expectEqual(@as(f32, 778), portrait.content_height);
    const keyboard = fit(402, 874, .{ .top = 62, .bottom = 320 });
    try std.testing.expectEqual(@as(f32, 492), keyboard.content_height);
    const landscape = fit(874, 402, .{ .left = 62, .right = 62, .bottom = 21 });
    try std.testing.expectEqual(@as(f32, 750), landscape.content_width);
    try std.testing.expectEqual(@as(f32, 381), landscape.content_height);
    const invalid = fit(0, 0, .{ .top = 1000, .bottom = 1000 });
    try std.testing.expect(invalid.content_width > 0 and invalid.content_height > 0);
}
