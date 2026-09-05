const std = @import("std");

pub const Layout = struct {
    width: f32,
    stacked: bool,
    thumbnail_width: f32,
    thumbnail_height: f32,
};

/// Work in layout units after display/UI scaling, including drawer mode.
pub fn calculate(available: f32) Layout {
    const width = if (std.math.isFinite(available)) @max(1, available) else 320;
    const stacked = width < 640;
    const thumbnail_width = if (stacked) @max(1, width - 24) else @min(240, width * 0.27);
    return .{ .width = width, .stacked = stacked, .thumbnail_width = thumbnail_width, .thumbnail_height = thumbnail_width * 9 / 16 };
}

test "TV cards fit phone tablet desktop and scaled drawer widths" {
    for ([_]f32{ 240, 320, 375, 480, 639, 640, 768, 1024, 1920 }) |width| {
        const layout = calculate(width);
        try std.testing.expect(layout.thumbnail_width <= width);
        try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), layout.thumbnail_width / layout.thumbnail_height, 0.001);
        try std.testing.expectEqual(width < 640, layout.stacked);
    }
    try std.testing.expect(calculate(std.math.nan(f32)).stacked);
    try std.testing.expect(calculate(0).thumbnail_width > 0);
}
