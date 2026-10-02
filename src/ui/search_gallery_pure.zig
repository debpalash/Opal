//! Geometry policy shared by the native search gallery and its regression tests.
const std = @import("std");
pub const Shape = enum { portrait, square, landscape };
pub const Size = struct { w: f32, h: f32 };
pub const Crop = struct { x: f32 = 0, y: f32 = 0, w: f32 = 1, h: f32 = 1 };
pub fn shouldFetchCover(has_url: bool, failed: bool, fetching: bool, has_pixels: bool, has_texture: bool) bool {
    return has_url and !failed and !fetching and !has_pixels and !has_texture;
}
pub fn coverCrop(image: Size, target: Size) Crop {
    if (image.w <= 0 or image.h <= 0 or target.w <= 0 or target.h <= 0) return .{};
    const source_ratio = image.w / image.h;
    const target_ratio = target.w / target.h;
    if (source_ratio > target_ratio) {
        const width = target_ratio / source_ratio;
        return .{ .x = (1 - width) / 2, .w = width };
    }
    const height = source_ratio / target_ratio;
    return .{ .y = (1 - height) / 2, .h = height };
}
pub fn cardSize(shape: Shape, viewport_width: f32) Size {
    const compact = viewport_width < 640;
    const width: f32 = switch (shape) {
        .portrait => if (compact) 128 else 164,
        .square => if (compact) 148 else 180,
        .landscape => if (compact) 224 else 272,
    };
    return .{ .w = width, .h = switch (shape) {
        .portrait => width * 1.5,
        .square => width,
        .landscape => width * 9 / 16,
    } };
}
pub fn stackedHero(width: f32) bool {
    return width < 760;
}
pub fn heroCopyGravity(width: f32) f32 {
    // Fractional gravity in a vertical Box positions a child as an overlay.
    return if (stackedHero(width)) 0 else 0.5;
}
pub fn shelfHeight(art_height: f32, body_height: f32) f32 {
    // Two title lines, a metadata line, button, and widget margins/padding.
    return art_height + body_height * 4 + 64;
}
pub fn heroArtSize(width: f32, backdrop: bool) Size {
    const w = if (backdrop) @min(560, @max(200, if (stackedHero(width)) width - 24 else width * 0.49)) else @min(184, @max(112, width * 0.2));
    return .{ .w = w, .h = if (backdrop) w * 9 / 16 else w * 1.5 };
}
pub fn retainSelection(identities: []const u64, selected: u64) ?usize {
    if (identities.len == 0) return null;
    for (identities, 0..) |identity, index| if (identity == selected and selected != 0) return index;
    return 0;
}
pub fn shouldFeature(query: []const u8, title: []const u8, has_art: bool, selected: bool) bool {
    if (selected) return true;
    if (!has_art) return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, query, " \t\r\n"), std.mem.trim(u8, title, " \t\r\n"));
}
test "search cards retain meaningful aspect ratios at narrow and wide widths" {
    for ([_]f32{ 320, 640, 1440 }) |width| {
        const portrait = cardSize(.portrait, width);
        const square = cardSize(.square, width);
        const video = cardSize(.landscape, width);
        try std.testing.expectApproxEqAbs(@as(f32, 1.5), portrait.h / portrait.w, 0.001);
        try std.testing.expectEqual(square.w, square.h);
        try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), video.w / video.h, 0.001);
    }
}
test "search hero stacks on narrow windows without expanding portrait artwork" {
    try std.testing.expect(stackedHero(600));
    try std.testing.expect(!stackedHero(1000));
    try std.testing.expect(heroArtSize(1440, false).w <= 184);
    try std.testing.expect(heroArtSize(320, true).w <= 320);
    try std.testing.expectEqual(@as(f32, 0), heroCopyGravity(640));
    try std.testing.expectEqual(@as(f32, 0.5), heroCopyGravity(1360));
}
test "search shelf reserves complete card actions instead of clipping Details" {
    for ([_]f32{ 14, 20, 30 }) |body_height| {
        const art = cardSize(.portrait, 1360);
        try std.testing.expect(shelfHeight(art.h, body_height) >= art.h + body_height * 4 + 48);
    }
}
test "progressive search publications preserve selected content by identity" {
    try std.testing.expectEqual(@as(?usize, 2), retainSelection(&.{ 1, 9, 5 }, 5));
    try std.testing.expectEqual(@as(?usize, 0), retainSelection(&.{ 1, 9 }, 5));
    try std.testing.expectEqual(@as(?usize, null), retainSelection(&.{}, 5));
}
test "broad query does not invent a confident featured match" {
    try std.testing.expect(!shouldFeature("space", "Space Jam", true, false));
    try std.testing.expect(shouldFeature(" Reacher ", "reacher", true, false));
    try std.testing.expect(!shouldFeature("Reacher", "Reacher", false, false));
    try std.testing.expect(shouldFeature("space", "Space Jam", false, true));
}
test "search artwork crops centrally instead of stretching square covers" {
    const crop = coverCrop(.{ .w = 400, .h = 400 }, .{ .w = 160, .h = 240 });
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), crop.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 6.0), crop.x, 0.001);
    const wide = coverCrop(.{ .w = 100, .h = 150 }, .{ .w = 272, .h = 153 });
    try std.testing.expect(wide.h < 1 and wide.y > 0);
    try std.testing.expectEqual(Crop{}, coverCrop(.{ .w = 0, .h = 0 }, .{ .w = 1, .h = 1 }));
}
test "ready artwork must not refetch every rendered frame" {
    try std.testing.expect(shouldFetchCover(true, false, false, false, false));
    try std.testing.expect(!shouldFetchCover(true, false, false, false, true));
    try std.testing.expect(!shouldFetchCover(true, false, false, true, false));
    try std.testing.expect(!shouldFetchCover(true, false, true, false, false));
    try std.testing.expect(!shouldFetchCover(true, true, false, false, false));
}
