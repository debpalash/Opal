//! Pure geometry for the player control-bar drop-ups (see `pickers.zig`).
//!
//! The control-bar popovers are *anchored* panels: they float ABOVE the chip
//! that opened them, right-aligned to that chip, and must never leave the
//! window. dvui's `placeOnScreen` can only flip a menu below→above once it has
//! already run off the bottom, and it anchors from the spawner's TOP-left — so
//! the "grow upwards, right-align, clamp" decision is ours. It's also the only
//! part of the drop-up that is testable without a live dvui frame, so it lives
//! here and `pickers.zig` routes every popover through `place()`.
//!
//! All coordinates are in one space (dvui "natural" units at the call site);
//! this module is deliberately dvui-free so `zig build test` can run it.

const std = @import("std");

pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
pub const Size = struct { w: f32 = 0, h: f32 = 0 };
pub const Point = struct { x: f32 = 0, y: f32 = 0 };

/// Breathing room between the panel and its trigger chip.
pub const GAP: f32 = 8;

/// Top-left corner for a `size` panel opened from `anchor` inside `win`:
///
///  1. right edge aligned with the anchor's right edge (the chips live in the
///     bar's right-hand cluster, so growing leftwards keeps them on screen),
///  2. bottom edge `gap` above the anchor's top edge (drop-UP),
///  3. clamped into `win` on both axes — and if there is genuinely no room
///     above (anchor near the top of the window), it drops DOWN instead of
///     being clipped.
pub fn place(anchor: Rect, win: Rect, size: Size, gap: f32) Point {
    // ── x: right-align to the anchor, then clamp into the window ──
    var x = anchor.x + anchor.w - size.w;
    const max_x = win.x + win.w - size.w;
    if (x > max_x) x = max_x;
    if (x < win.x) x = win.x; // also covers a panel wider than the window

    // ── y: above the anchor; fall back to below, then clamp ──
    var y = anchor.y - size.h - gap;
    if (y < win.y) {
        const below = anchor.y + anchor.h + gap;
        y = if (below + size.h <= win.y + win.h) below else win.y;
    }
    const max_y = win.y + win.h - size.h;
    if (y > max_y) y = max_y;
    if (y < win.y) y = win.y; // panel taller than the window

    return .{ .x = x, .y = y };
}

/// Point-in-rect, used for the click-outside dismissal (the drop-ups have no
/// backdrop to swallow the click, so the footer polices it by hand).
pub fn contains(r: Rect, x: f32, y: f32) bool {
    return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h;
}

// ── Tests ──

const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "place: sits above the anchor, right edges aligned" {
    const win: Rect = .{ .x = 0, .y = 0, .w = 1280, .h = 720 };
    // A chip in the control bar near the bottom-right.
    const anchor: Rect = .{ .x = 1100, .y = 660, .w = 40, .h = 28 };
    const p = place(anchor, win, .{ .w = 220, .h = 300 }, GAP);
    // right-aligned: x + w == anchor right edge
    try expectApproxEqAbs(@as(f32, 1140 - 220), p.x, 0.01);
    // above: y + h + gap == anchor top
    try expectApproxEqAbs(@as(f32, 660 - 300 - 8), p.y, 0.01);
}

test "place: clamps to the window's right edge instead of running off" {
    const win: Rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    // Chip flush against the right edge; a 220-wide panel right-aligned to it
    // would still fit, but a 500-wide one cannot.
    const anchor: Rect = .{ .x = 380, .y = 260, .w = 20, .h = 28 };
    const wide = place(anchor, win, .{ .w = 500, .h = 100 }, GAP);
    try expectApproxEqAbs(@as(f32, 0), wide.x, 0.01);

    const fits = place(anchor, win, .{ .w = 220, .h = 100 }, GAP);
    try expectApproxEqAbs(@as(f32, 400 - 220), fits.x, 0.01);
    try expectApproxEqAbs(@as(f32, 260 - 100 - 8), fits.y, 0.01);
}

test "place: never crosses the window's left edge" {
    const win: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    // Chip at the far left — right-aligning a wide panel to it would give a
    // negative x.
    const anchor: Rect = .{ .x = 4, .y = 550, .w = 30, .h = 28 };
    const p = place(anchor, win, .{ .w = 240, .h = 200 }, GAP);
    try expectApproxEqAbs(@as(f32, 0), p.x, 0.01);
}

test "place: drops DOWN when there is no room above" {
    const win: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    // Control bar of a small grid cell pinned to the top of the window.
    const anchor: Rect = .{ .x = 700, .y = 10, .w = 40, .h = 28 };
    const p = place(anchor, win, .{ .w = 200, .h = 240 }, GAP);
    try expectApproxEqAbs(@as(f32, 10 + 28 + 8), p.y, 0.01);
}

test "place: a panel taller than the window pins to the top, never negative" {
    const win: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 300 };
    const anchor: Rect = .{ .x = 700, .y = 260, .w = 40, .h = 28 };
    const p = place(anchor, win, .{ .w = 200, .h = 460 }, GAP);
    try expectApproxEqAbs(@as(f32, 0), p.y, 0.01);
}

test "place: honours a non-zero window origin" {
    const win: Rect = .{ .x = 100, .y = 50, .w = 400, .h = 200 };
    // Anchor at the top-left of that window — no room above, drop down.
    const anchor: Rect = .{ .x = 110, .y = 55, .w = 20, .h = 20 };
    const p = place(anchor, win, .{ .w = 300, .h = 100 }, GAP);
    try expectApproxEqAbs(@as(f32, 100), p.x, 0.01); // clamped to win.x
    try expectApproxEqAbs(@as(f32, 55 + 20 + 8), p.y, 0.01);
}

test "contains: click-outside dismissal boundary" {
    const r: Rect = .{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try std.testing.expect(contains(r, 10, 20));
    try std.testing.expect(contains(r, 110, 70));
    try std.testing.expect(contains(r, 60, 45));
    try std.testing.expect(!contains(r, 9.9, 45));
    try std.testing.expect(!contains(r, 60, 70.1));
}
