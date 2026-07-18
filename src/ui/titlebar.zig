//! Custom (client-side) window title bar.
//!
//! Replaces the OS-native title bar with an in-app one that matches Opal's
//! chrome: the window is made borderless and this module draws a slim bar with
//! the app name (left) and minimize / maximize-restore / close controls
//! (right). Dragging and edge-resizing are handled by the OS via
//! SDL_SetWindowHitTest, so window snapping and multi-monitor behavior stay
//! native — we only tell SDL which regions drag vs. resize.
//!
//! Enabled on Windows by default (state.app.custom_titlebar). On a build where
//! it's off, nothing here runs and the native title bar is kept.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const icons = @import("icons");
const c = @import("../core/c.zig");
const theme = @import("theme.zig");
const state = @import("../core/state.zig");

const is_windows = builtin.os.tag == .windows;

/// Logical (unscaled) bar height, in dvui points. Compact — just tall enough
/// for the logo + window controls.
pub const HEIGHT: f32 = 30;
/// Logical width of each window-control button.
const BTN_W: f32 = 44;
const NUM_BTNS: f32 = 3;

/// Set by the close button; appFrame polls this and returns `.close`.
pub var close_requested: bool = false;

// The SDL window, captured on enable(). null until then.
var sdl_window: ?*c.sdl.SDL_Window = null;
var installed: bool = false;

// Physical-pixel geometry of the draggable band, refreshed each frame by
// render() and read by the (event-thread) hit-test callback. The band spans the
// bar height; the control buttons on the right are excluded so they stay
// clickable.
// Stored as FRACTIONS of the window (0..1), so the hit-test — which gets points
// in SDL's window-coordinate space — can compare without knowing whether that
// space is pixels or points (the fraction is invariant either way). This avoids
// the DPI coordinate-conversion bug that left the drag band mispositioned.
var band_frac: f32 = 0.05;
var controls_frac: f32 = 0.85;
var controls_active: bool = false;

/// Whether the custom title bar should be active. Windows-only for now; other
/// platforms keep their native decorations (macOS traffic lights, etc.).
pub fn active() bool {
    return is_windows and state.app.custom_titlebar;
}

/// SDL hit-test: map a point to drag / resize / normal. Everything is done in
/// SDL's own window-coordinate space (the space `area` and SDL_GetWindowSize
/// share), using fractions for the title band / controls so no DPI conversion
/// is needed. DRAGGABLE → Windows HTCAPTION → native move + Aero Snap +
/// double-click-maximize; RESIZE_* → native edge resize.
fn hitTest(win: ?*c.sdl.SDL_Window, area: [*c]const c.sdl.SDL_Point, data: ?*anyopaque) callconv(.c) c.sdl.SDL_HitTestResult {
    _ = data;
    var ww: c_int = 0;
    var wh: c_int = 0;
    c.sdl.SDL_GetWindowSize(win, &ww, &wh);
    if (ww <= 0 or wh <= 0) return c.sdl.SDL_HITTEST_NORMAL;
    const x = area.*.x;
    const y = area.*.y;
    const xf: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(ww));
    const yf: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(wh));

    // Resize borders (SDL-space px). Skipped when maximized (no edges to grab).
    const maximized = win != null and (c.sdl.SDL_GetWindowFlags(win) & c.sdl.SDL_WINDOW_MAXIMIZED) != 0;
    const b: c_int = 6;
    if (!maximized and (x < b or y < b or x >= ww - b or y >= wh - b)) {
        const on_top = y < b;
        const on_bot = y >= wh - b;
        const on_left = x < b;
        const on_right = x >= ww - b;
        if (on_top and on_left) return c.sdl.SDL_HITTEST_RESIZE_TOPLEFT;
        if (on_top and on_right) return c.sdl.SDL_HITTEST_RESIZE_TOPRIGHT;
        if (on_bot and on_left) return c.sdl.SDL_HITTEST_RESIZE_BOTTOMLEFT;
        if (on_bot and on_right) return c.sdl.SDL_HITTEST_RESIZE_BOTTOMRIGHT;
        if (on_top) return c.sdl.SDL_HITTEST_RESIZE_TOP;
        if (on_bot) return c.sdl.SDL_HITTEST_RESIZE_BOTTOM;
        if (on_left) return c.sdl.SDL_HITTEST_RESIZE_LEFT;
        return c.sdl.SDL_HITTEST_RESIZE_RIGHT;
    }

    // Title-bar band → draggable, except over the control buttons.
    if (yf < band_frac) {
        if (controls_active and xf >= controls_frac) return c.sdl.SDL_HITTEST_NORMAL;
        return c.sdl.SDL_HITTEST_DRAGGABLE;
    }
    return c.sdl.SDL_HITTEST_NORMAL;
}

/// Make the window borderless + install the hit-test. Idempotent; call each
/// frame — it self-gates. `win` is dvui's underlying SDL_Window.
pub fn ensureEnabled(win: ?*c.sdl.SDL_Window) void {
    if (!active() or win == null) return;
    sdl_window = win;
    if (installed) return;
    installed = true;
    c.sdl.SDL_SetWindowBordered(win, c.sdl.SDL_FALSE);
    c.sdl.SDL_SetWindowResizable(win, c.sdl.SDL_TRUE);
    _ = c.sdl.SDL_SetWindowHitTest(win, hitTest, null);
}

fn ctlButton(id: u32, icon_data: []const u8, danger: bool) bool {
    return dvui.buttonIcon(@src(), "", icon_data, .{}, .{}, .{
        .id_extra = id,
        .color_fill = theme.colors.bg_surface,
        .color_fill_hover = if (danger) theme.colors.danger else theme.colors.bg_hover,
        .color_text = theme.colors.text_secondary,
        .border = dvui.Rect.all(0),
        .corner_radius = dvui.Rect.all(0),
        .padding = .{ .x = 15, .y = 8, .w = 15, .h = 8 },
        .min_size_content = .{ .w = 12, .h = 12 },
        .max_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
    });
}

/// Draw the bar. Call once, at the very top of the frame (above all other
/// chrome). No-op when the custom title bar isn't active.
pub fn render() void {
    if (!active()) return;
    const win = sdl_window;

    // Overlay lets us pin the brand hard-left and the window controls hard-right
    // independently (a plain horizontal box + spacer proved unreliable for the
    // right group). Full width, fixed compact height.
    var bar = dvui.overlay(@src(), .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .min_size_content = .{ .w = 0, .h = HEIGHT },
    });

    // Left: Opal gem + wordmark. The nav bar's own brand is suppressed while the
    // custom title bar is active (see shell.zig) so this is the only copy.
    {
        var left = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_x = 0.0,
            .gravity_y = 0.5,
            .padding = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
        });
        defer left.deinit();
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = @embedFile("opal_logo_64.png"), .name = "opal-brand" } },
        }, .{
            .min_size_content = .{ .w = 16, .h = 16 },
            .max_size_content = .{ .w = 16, .h = 16 },
            .gravity_y = 0.5,
        });
        _ = dvui.label(@src(), "Opal", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
        });
    }

    // Right: minimize / maximize-restore / close.
    {
        var right = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
        defer right.deinit();

        if (ctlButton(9701, icons.tvg.lucide.minus, false)) {
            if (win != null) c.sdl.SDL_MinimizeWindow(win);
        }
        const maximized = win != null and (c.sdl.SDL_GetWindowFlags(win) & c.sdl.SDL_WINDOW_MAXIMIZED) != 0;
        const max_icon = if (maximized) icons.tvg.lucide.copy else icons.tvg.lucide.square;
        if (ctlButton(9702, max_icon, false)) {
            if (win != null) {
                if (maximized) c.sdl.SDL_RestoreWindow(win) else c.sdl.SDL_MaximizeWindow(win);
            }
        }
        if (ctlButton(9703, icons.tvg.lucide.x, true)) {
            close_requested = true;
        }
    }

    bar.deinit();

    // Hit-test geometry as FRACTIONS of the window (invariant to whatever units
    // SDL reports points in). Band height = logical HEIGHT ÷ window logical
    // height; controls occupy the rightmost NUM_BTNS×BTN_W logical pts. Uses the
    // dvui window rect (points) so the ratio is unit-consistent.
    const wr = dvui.windowRect();
    band_frac = if (wr.h > 0) HEIGHT / wr.h else 0.05;
    controls_frac = if (wr.w > 0) 1.0 - (NUM_BTNS * BTN_W) / wr.w else 0.85;
    controls_active = true;
}
