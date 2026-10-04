//! Pointer maths for the embedded terminal, free of the UI toolkit and of
//! libghostty so it can be tested alone: pixel to cell mapping, wheel notches
//! to rows, and the geometry of the overlay scrollbar.

const std = @import("std");

/// A pointer position resolved against the cell grid.
pub const Hit = struct {
    col: u16,
    row: u16,
    /// Position inside the cell, 0..1.
    fx: f32,
    fy: f32,
    /// False when the pointer was outside the grid (col/row are clamped).
    inside: bool,
};

/// Map a pixel position to a cell. `ox`/`oy` is the top-left of the grid and
/// `cw`/`ch` the (fractional) cell size, all in the same unit.
pub fn cellAt(px: f32, py: f32, ox: f32, oy: f32, cw: f32, ch: f32, cols: u16, rows: u16) Hit {
    const rx = (px - ox) / cw;
    const ry = (py - oy) / ch;
    const max_x: f32 = @floatFromInt(@max(cols, 1) - 1);
    const max_y: f32 = @floatFromInt(@max(rows, 1) - 1);
    const fcol = std.math.clamp(@floor(rx), 0, max_x);
    const frow = std.math.clamp(@floor(ry), 0, max_y);
    const inside = rx >= 0 and ry >= 0 and rx < @as(f32, @floatFromInt(cols)) and ry < @as(f32, @floatFromInt(rows));
    return .{
        .col = @intFromFloat(fcol),
        .row = @intFromFloat(frow),
        .fx = std.math.clamp(rx - fcol, 0, 1),
        .fy = std.math.clamp(ry - frow, 0, 1),
        .inside = inside,
    };
}

/// libghostty-vt's encoders divide pixel positions by an integer cell size. The
/// real cell size is fractional, so hand them a position rebuilt from the cell
/// the pointer is really in: columns then agree at any width.
pub fn surfacePos(hit: Hit, cell_w: u32, cell_h: u32) struct { x: f32, y: f32 } {
    return .{
        .x = (@as(f32, @floatFromInt(hit.col)) + hit.fx) * @as(f32, @floatFromInt(cell_w)),
        .y = (@as(f32, @floatFromInt(hit.row)) + hit.fy) * @as(f32, @floatFromInt(cell_h)),
    };
}

pub const Button = enum { left, right, middle, four, five, six, seven, eight };

/// Wheel delta to whole rows (sign kept); a slow wheel still moves one row.
/// Positive input (wheel up) gives a negative row count, as `scroll` expects
/// negative to go back in history.
pub fn wheelRows(delta: f32, rows_per_notch: f32) isize {
    if (delta == 0) return 0;
    const rows: isize = @intFromFloat(@round(-delta * rows_per_notch));
    if (rows != 0) return rows;
    return if (delta > 0) -1 else 1;
}

/// Where the overlay scrollbar's thumb sits within a track of `track_h`.
pub const Thumb = struct { y: f32, h: f32 };

/// Thumb geometry for `total` rows of which `len` are visible from `offset`.
/// Null when everything fits (no scrollback to show).
pub fn thumb(total: u64, offset: u64, len: u64, track_h: f32, min_h: f32) ?Thumb {
    if (total <= len or len == 0 or track_h <= 0) return null;
    const t: f32 = @floatFromInt(total);
    const h = std.math.clamp(track_h * @as(f32, @floatFromInt(len)) / t, @min(min_h, track_h), track_h);
    const max_off: f32 = @floatFromInt(total - len);
    const frac = std.math.clamp(@as(f32, @floatFromInt(offset)) / max_off, 0, 1);
    return .{ .y = (track_h - h) * frac, .h = h };
}

/// The row offset a dragged thumb whose top edge is at `top` stands for.
pub fn offsetForThumbTop(total: u64, len: u64, track_h: f32, thumb_h: f32, top: f32) u64 {
    if (total <= len) return 0;
    const room = track_h - thumb_h;
    if (room <= 0) return 0;
    const frac = std.math.clamp(top / room, 0, 1);
    const max_off: f32 = @floatFromInt(total - len);
    return @intFromFloat(@round(frac * max_off));
}

test "cellAt maps pixels to cells and clamps outside the grid" {
    const h = cellAt(25, 41, 5, 1, 10, 20, 80, 24);
    try std.testing.expectEqual(@as(u16, 2), h.col);
    try std.testing.expectEqual(@as(u16, 2), h.row);
    try std.testing.expect(h.inside);
    try std.testing.expectApproxEqAbs(@as(f32, 0), h.fx, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), h.fy, 0.001);

    const left = cellAt(0, 5, 5, 1, 10, 20, 80, 24);
    try std.testing.expectEqual(@as(u16, 0), left.col);
    try std.testing.expect(!left.inside);

    const far = cellAt(5000, 5000, 5, 1, 10, 20, 80, 24);
    try std.testing.expectEqual(@as(u16, 79), far.col);
    try std.testing.expectEqual(@as(u16, 23), far.row);
    try std.testing.expect(!far.inside);
    try std.testing.expect(far.fx <= 1 and far.fy <= 1);
}

test "cellAt handles fractional cell widths without drift" {
    // 8.4 px cells: column 100 starts at 840.
    const h = cellAt(845, 0, 0, 0, 8.4, 16.5, 120, 40);
    try std.testing.expectEqual(@as(u16, 100), h.col);
    const s = surfacePos(h, 8, 16);
    try std.testing.expectEqual(@as(u32, 100), @as(u32, @intFromFloat(s.x / 8)));
}

test "wheelRows keeps direction and moves at least one row" {
    try std.testing.expectEqual(@as(isize, -3), wheelRows(1, 3));
    try std.testing.expectEqual(@as(isize, 6), wheelRows(-2, 3));
    try std.testing.expectEqual(@as(isize, -1), wheelRows(0.1, 3));
    try std.testing.expectEqual(@as(isize, 1), wheelRows(-0.1, 3));
    try std.testing.expectEqual(@as(isize, 0), wheelRows(0, 3));
}

test "thumb geometry follows the viewport" {
    try std.testing.expect(thumb(24, 0, 24, 100, 12) == null);
    const top = thumb(100, 0, 25, 200, 12).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0), top.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), top.h, 0.001);
    const bottom = thumb(100, 75, 25, 200, 12).?;
    try std.testing.expectApproxEqAbs(@as(f32, 150), bottom.y, 0.001);
    // A huge history still leaves a grabbable thumb.
    const tiny = thumb(100000, 0, 25, 200, 12).?;
    try std.testing.expectApproxEqAbs(@as(f32, 12), tiny.h, 0.001);
}

test "dragging the thumb maps back to rows" {
    try std.testing.expectEqual(@as(u64, 0), offsetForThumbTop(100, 25, 200, 50, -10));
    try std.testing.expectEqual(@as(u64, 75), offsetForThumbTop(100, 25, 200, 50, 500));
    try std.testing.expectEqual(@as(u64, 38), offsetForThumbTop(100, 25, 200, 50, 75));
    // Round trip: the thumb for an offset maps back to that offset.
    const t = thumb(1000, 321, 30, 300, 12).?;
    try std.testing.expectEqual(@as(u64, 321), offsetForThumbTop(1000, 30, 300, t.h, t.y));
}
