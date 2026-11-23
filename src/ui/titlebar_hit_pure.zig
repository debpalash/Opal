//! Window hit-test geometry for SDL_SetWindowHitTest, shared by every desktop
//! platform. SDL maps `draggable` to the OS move: HTCAPTION on Windows,
//! setMovableByWindowBackground on macOS, _NET_WM_MOVERESIZE on X11 and
//! xdg_toplevel.move on Wayland.
//!
//! Regions are fractions of the window (0..1), so the callback can compare
//! SDL's window-coordinate points without knowing whether that space is
//! pixels or points. dvui widget rects (physical pixels) divided by the
//! window's physical size give the same fraction.

const std = @import("std");

pub const Hit = enum {
    normal,
    draggable,
    resize_top_left,
    resize_top,
    resize_top_right,
    resize_right,
    resize_bottom_right,
    resize_bottom,
    resize_bottom_left,
    resize_left,
};

/// Half-open rectangle in window fractions: x0 <= x < x1, y0 <= y < y1.
pub const FracRect = struct {
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,

    pub fn isEmpty(self: FracRect) bool {
        return !(self.x1 > self.x0 and self.y1 > self.y0);
    }

    pub fn contains(self: FracRect, xf: f32, yf: f32) bool {
        return !self.isEmpty() and xf >= self.x0 and xf < self.x1 and yf >= self.y0 and yf < self.y1;
    }
};

/// Convert a widget rect (any unit) into fractions of a window measured in the
/// same unit. Clamped to the window; empty on a degenerate window or rect.
pub fn fracRect(x: f32, y: f32, w: f32, h: f32, window_w: f32, window_h: f32) FracRect {
    if (!(window_w > 0 and window_h > 0) or !(w > 0 and h > 0)) return .{};
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(w) or !std.math.isFinite(h)) return .{};
    return .{
        .x0 = std.math.clamp(x / window_w, 0, 1),
        .y0 = std.math.clamp(y / window_h, 0, 1),
        .x1 = std.math.clamp((x + w) / window_w, 0, 1),
        .y1 = std.math.clamp((y + h) / window_h, 0, 1),
    };
}

pub const Input = struct {
    /// Point and window size in SDL window coordinates.
    x: i32,
    y: i32,
    window_w: i32,
    window_h: i32,
    /// Edge-resize border width, in the same units. 0 = no resize edges
    /// (native decorations own them, or the window is maximized).
    resize_border: i32 = 0,
    /// Custom title-bar band height as a window fraction. 0 = no band.
    band_fraction: f32 = 0,
    /// Left edge of the window-control buttons inside the band (fraction).
    /// null = the band has no controls to keep clickable.
    controls_fraction: ?f32 = null,
    /// Extra drag handles (e.g. the header's title cluster).
    drag_rects: []const FracRect = &.{},
};

pub fn classify(in: Input) Hit {
    if (in.window_w <= 0 or in.window_h <= 0) return .normal;
    const x = in.x;
    const y = in.y;
    if (x < 0 or y < 0 or x >= in.window_w or y >= in.window_h) return .normal;

    const b = in.resize_border;
    if (b > 0 and (x < b or y < b or x >= in.window_w - b or y >= in.window_h - b)) {
        const top = y < b;
        const bottom = y >= in.window_h - b;
        const left = x < b;
        const right = x >= in.window_w - b;
        if (top and left) return .resize_top_left;
        if (top and right) return .resize_top_right;
        if (bottom and left) return .resize_bottom_left;
        if (bottom and right) return .resize_bottom_right;
        if (top) return .resize_top;
        if (bottom) return .resize_bottom;
        if (left) return .resize_left;
        return .resize_right;
    }

    const xf: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(in.window_w));
    const yf: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(in.window_h));

    if (in.band_fraction > 0 and yf < in.band_fraction) {
        if (in.controls_fraction) |cf| {
            if (xf >= cf) return .normal;
        }
        return .draggable;
    }
    for (in.drag_rects) |r| {
        if (r.contains(xf, yf)) return .draggable;
    }
    return .normal;
}

/// Whether this OS gets the SDL hit-test drag handle. Mobile hosts have no
/// movable window.
pub fn platformSupported(os: std.Target.Os.Tag, abi: std.Target.Abi) bool {
    return switch (os) {
        .macos, .windows => true,
        .linux, .freebsd, .openbsd, .netbsd => !abi.isAndroid(),
        else => false,
    };
}

test "resize edges and corners win over the drag band" {
    const base: Input = .{ .x = 0, .y = 0, .window_w = 800, .window_h = 600, .resize_border = 6, .band_fraction = 0.05, .controls_fraction = 0.85 };
    var in = base;
    try std.testing.expectEqual(Hit.resize_top_left, classify(in));
    in.x = 799;
    try std.testing.expectEqual(Hit.resize_top_right, classify(in));
    in.y = 599;
    try std.testing.expectEqual(Hit.resize_bottom_right, classify(in));
    in.x = 3;
    try std.testing.expectEqual(Hit.resize_bottom_left, classify(in));
    in = base;
    in.x = 400;
    in.y = 2;
    try std.testing.expectEqual(Hit.resize_top, classify(in));
    in.y = 300;
    in.x = 2;
    try std.testing.expectEqual(Hit.resize_left, classify(in));
    in.x = 797;
    try std.testing.expectEqual(Hit.resize_right, classify(in));
    in.x = 400;
    in.y = 597;
    try std.testing.expectEqual(Hit.resize_bottom, classify(in));
}

test "maximized window (no border) drags from its very top edge" {
    const hit = classify(.{ .x = 100, .y = 0, .window_w = 800, .window_h = 600, .band_fraction = 0.05, .controls_fraction = 0.85 });
    try std.testing.expectEqual(Hit.draggable, hit);
}

test "window controls inside the band stay clickable" {
    const in: Input = .{ .x = 790 - 10, .y = 15, .window_w = 800, .window_h = 600, .resize_border = 6, .band_fraction = 0.05, .controls_fraction = 0.85 };
    try std.testing.expectEqual(Hit.normal, classify(in));
    var left = in;
    left.x = 100;
    try std.testing.expectEqual(Hit.draggable, classify(left));
    var below = in;
    below.x = 100;
    below.y = 200;
    try std.testing.expectEqual(Hit.normal, classify(below));
}

test "header title cluster is a drag handle with native decorations" {
    // macOS/Linux keep their native title bar: no band, no resize border,
    // only the header's logo + title region drags.
    const header = fracRect(8, 38, 220, 38, 1600, 1000);
    const rects = [_]FracRect{header};
    const base: Input = .{ .x = 0, .y = 0, .window_w = 800, .window_h = 500, .drag_rects = &rects };
    var in = base;
    in.x = 50; // 100 px of 1600 = 50 pt of 800
    in.y = 25; // 50 px of 1000
    try std.testing.expectEqual(Hit.draggable, classify(in));
    in.x = 200; // past the cluster (114 pt)
    try std.testing.expectEqual(Hit.normal, classify(in));
    in.x = 50;
    in.y = 5; // above the header, inside the OS title bar area
    try std.testing.expectEqual(Hit.normal, classify(in));
    in.y = 0;
    in.x = 0;
    try std.testing.expectEqual(Hit.normal, classify(in));
}

test "fracRect is DPI invariant and clamps to the window" {
    const px = fracRect(20, 40, 200, 60, 2000, 1200);
    const pt = fracRect(10, 20, 100, 30, 1000, 600);
    try std.testing.expectApproxEqAbs(px.x0, pt.x0, 1e-6);
    try std.testing.expectApproxEqAbs(px.y1, pt.y1, 1e-6);
    const over = fracRect(-50, 0, 5000, 10, 1000, 600);
    try std.testing.expectEqual(@as(f32, 0), over.x0);
    try std.testing.expectEqual(@as(f32, 1), over.x1);
    try std.testing.expect(fracRect(0, 0, 10, 10, 0, 600).isEmpty());
    try std.testing.expect(fracRect(0, 0, 0, 10, 100, 600).isEmpty());
    try std.testing.expect(fracRect(std.math.nan(f32), 0, 10, 10, 100, 600).isEmpty());
}

test "degenerate window and out-of-window points are normal" {
    const rects = [_]FracRect{.{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }};
    try std.testing.expectEqual(Hit.normal, classify(.{ .x = 1, .y = 1, .window_w = 0, .window_h = 0, .drag_rects = &rects }));
    try std.testing.expectEqual(Hit.normal, classify(.{ .x = -1, .y = 1, .window_w = 10, .window_h = 10, .drag_rects = &rects }));
    try std.testing.expectEqual(Hit.draggable, classify(.{ .x = 1, .y = 1, .window_w = 10, .window_h = 10, .drag_rects = &rects }));
}

test "drag handle is desktop-only" {
    try std.testing.expect(platformSupported(.macos, .none));
    try std.testing.expect(platformSupported(.windows, .gnu));
    try std.testing.expect(platformSupported(.linux, .gnu));
    try std.testing.expect(!platformSupported(.linux, .android));
    try std.testing.expect(!platformSupported(.ios, .none));
}
