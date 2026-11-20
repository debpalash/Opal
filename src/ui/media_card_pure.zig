//! Geometry for the shared media card (media_card.zig).
//!
//! Every catalog card — Movies & TV, Continue, podcasts, music, Jellyfin, Plex,
//! YouTube — is a cover plus a measured footer. Galleries virtualize on a
//! fixed row pitch, so card height, skeleton tiles and spacer math must all
//! come from the same numbers. Before this module each screen carried its own
//! hard-coded footer constant (38, 46, 76, 152 …) and the footers clipped or
//! left dead bands whenever fonts changed.
const std = @import("std");

pub const Aspect = enum { poster, square, wide };

/// Space between the cover and the title.
pub const TITLE_GAP: f32 = 6;
/// One row of 14px icon actions (4px padding each side) plus a 4px top gap.
pub const ACTION_ROW_H: f32 = 26;
/// Rounding headroom so fractional font metrics never clip the last line.
pub const SLACK: f32 = 2;
/// Default outer margin on every side of a card.
pub const MARGIN: f32 = 4;

pub fn coverHeight(width: f32, aspect: Aspect) f32 {
    return switch (aspect) {
        .poster => width * 1.5,
        .square => width,
        .wide => width * 9.0 / 16.0,
    };
}

pub const Footer = struct {
    title_lines: u8 = 1,
    meta_lines: u8 = 0,
    action_row: bool = false,
};

/// Line heights of the live title/meta fonts (they follow UI scale/theme).
pub const Metrics = struct { title_line: f32, meta_line: f32 };

pub fn footerHeight(footer: Footer, metrics: Metrics) f32 {
    const title = metrics.title_line * @as(f32, @floatFromInt(footer.title_lines));
    const meta = metrics.meta_line * @as(f32, @floatFromInt(footer.meta_lines));
    const row: f32 = if (footer.action_row) ACTION_ROW_H else 0;
    return @ceil(TITLE_GAP + title + meta + row + SLACK);
}

/// Outer height of one card including its top and bottom margins — the
/// virtualized gallery's row pitch.
pub fn rowPitch(cover_h: f32, footer_h: f32, margin: f32) f32 {
    return cover_h + footer_h + 2 * margin;
}

pub const Columns = struct { count: usize, card_w: f32 };

/// Responsive columns: as many `target_w` cards as fit (at least `min_count`),
/// then stretch them to fill the width exactly, margins included.
pub fn columns(avail_w: f32, target_w: f32, margin: f32, min_count: usize, max_count: usize) Columns {
    const gutter = 2 * margin;
    const fit: usize = if (avail_w <= 0 or target_w <= 0) 1 else @intFromFloat(@max(1, @floor(avail_w / (target_w + gutter))));
    const count = std.math.clamp(fit, @max(1, min_count), @max(@max(1, min_count), max_count));
    const n: f32 = @floatFromInt(count);
    return .{ .count = count, .card_w = @max(1, (avail_w - n * gutter) / n) };
}

test "cover aspects" {
    try std.testing.expectEqual(@as(f32, 150), coverHeight(100, .poster));
    try std.testing.expectEqual(@as(f32, 100), coverHeight(100, .square));
    try std.testing.expectEqual(@as(f32, 90), coverHeight(160, .wide));
}

test "footer fits every requested line plus the action row (clipped-footer regression)" {
    const m: Metrics = .{ .title_line = 15.2, .meta_line = 12.6 };
    // Poster: two-line title + one action row.
    const poster = footerHeight(.{ .title_lines = 2, .action_row = true }, m);
    try std.testing.expect(poster >= TITLE_GAP + 2 * 15.2 + ACTION_ROW_H);
    try std.testing.expectEqual(@floor(poster), poster);
    // Square: one title line + one meta line, no actions.
    const square = footerHeight(.{ .title_lines = 1, .meta_lines = 1 }, m);
    try std.testing.expect(square >= TITLE_GAP + 15.2 + 12.6);
    try std.testing.expect(square < poster);
}

test "row pitch includes both margins" {
    try std.testing.expectEqual(@as(f32, 150 + 80 + 8), rowPitch(150, 80, 4));
}

test "columns fill the width and honour bounds" {
    const c = columns(900, 160, 4, 2, 8);
    try std.testing.expectEqual(@as(usize, 5), c.count);
    try std.testing.expectApproxEqAbs(@as(f32, 900), c.card_w * 5 + 5 * 8, 0.01);
    // Narrow pages still keep the minimum count.
    try std.testing.expectEqual(@as(usize, 2), columns(200, 160, 4, 2, 8).count);
    // Very wide pages stop at the cap.
    try std.testing.expectEqual(@as(usize, 8), columns(4000, 160, 4, 2, 8).count);
    // Degenerate input never divides by zero.
    try std.testing.expect(columns(0, 0, 4, 1, 4).card_w >= 1);
}
