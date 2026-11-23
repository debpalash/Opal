//! Custom (client-side) window title bar.
//!
//! Replaces the OS-native title bar with an in-app one that matches Opal's
//! chrome: the window is made borderless and this module draws a slim bar with
//! the app name (left) and minimize / maximize-restore / close controls
//! (right). Dragging and edge-resizing are handled by the OS via
//! SDL_SetWindowHitTest, so window snapping and multi-monitor behavior stay
//! native — we only tell SDL which regions drag vs. resize.
//!
//! The same hit-test runs on macOS and Linux with native decorations, where
//! it only adds the header's title cluster as a drag handle.
//!
//! Enabled on Windows by default (state.app.custom_titlebar). On a build where
//! it's off, nothing here runs and the native title bar is kept.

const builtin = @import("builtin");
const dvui = @import("dvui");
const icons = @import("icons");
const c = @import("../core/c.zig");
const theme = @import("theme.zig");
const state = @import("../core/state.zig");
const geometry = @import("titlebar_geometry.zig");
const hit_pure = @import("titlebar_hit_pure.zig");

const is_windows = builtin.os.tag == .windows;

/// Win32 window-procedure subclass (src/ui/win_titlebar.c). Fixes two things
/// SDL2 gets wrong for a borderless window and exposes no API for: maximize
/// sized to the raw screen instead of the monitor work area (so it covered the
/// taskbar), and caption double-click doing nothing. Stubbed off-Windows so
/// this file still compiles everywhere.
const native = if (is_windows) struct {
    extern fn opal_titlebar_install_native(win: ?*anyopaque) void;
    extern fn opal_titlebar_set_geometry(band: f32, controls: f32) void;
    extern fn opal_titlebar_begin_native_drag(win: ?*anyopaque) c_int;
} else struct {
    fn opal_titlebar_install_native(win: ?*anyopaque) void {
        _ = win;
    }
    fn opal_titlebar_set_geometry(band: f32, controls: f32) void {
        _ = band;
        _ = controls;
    }
    fn opal_titlebar_begin_native_drag(win: ?*anyopaque) c_int {
        _ = win;
        return 0;
    }
};

/// Logical (unscaled) bar height, in dvui points. Compact — just tall enough
/// for the logo + window controls.
pub const HEIGHT: f32 = geometry.HEIGHT;

/// Set by the close button; appFrame polls this and returns `.close`.
pub var close_requested: bool = false;

// The SDL window, captured on enable(). null until then.
var sdl_window: ?*c.sdl.SDL_Window = null;
var installed: bool = false;
var hit_test_installed: bool = false;
/// Header drag handle for the current frame (empty = none). See setHeaderDragRect.
var header_drag_rect: hit_pure.FracRect = .{};

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

fn playerOverlay() bool {
    return state.app.page_shell_enabled and state.app.router.current == .player;
}

/// Whether the custom title bar should be active. Windows-only for now; other
/// platforms keep their native decorations (macOS traffic lights, etc.).
pub fn active() bool {
    return is_windows and state.app.custom_titlebar;
}

/// SDL hit-test: map a point to drag / resize / normal. The geometry lives in
/// titlebar_hit_pure.classify; this only gathers the live inputs. DRAGGABLE is
/// the OS move (Windows HTCAPTION + Aero Snap, macOS window drag, X11
/// _NET_WM_MOVERESIZE, Wayland xdg move); RESIZE_* is a native edge resize.
/// SDL runs it on the thread that pumps window events, which is the UI thread
/// on every desktop backend, so the frame-written geometry needs no lock.
fn hitTest(win: ?*c.sdl.SDL_Window, area: [*c]const c.sdl.SDL_Point, data: ?*anyopaque) callconv(.c) c.sdl.SDL_HitTestResult {
    _ = data;
    var ww: c_int = 0;
    var wh: c_int = 0;
    c.sdl.SDL_GetWindowSize(win, &ww, &wh);
    const custom = active();
    // Resize borders only exist on the borderless custom title bar, and not
    // while maximized (no edges to grab).
    const maximized = win != null and (c.sdl.SDL_GetWindowFlags(win) & c.sdl.SDL_WINDOW_MAXIMIZED) != 0;
    const drag_rects: []const hit_pure.FracRect = if (header_drag_rect.isEmpty()) &.{} else (&header_drag_rect)[0..1];
    const hit = hit_pure.classify(.{
        .x = area.*.x,
        .y = area.*.y,
        .window_w = ww,
        .window_h = wh,
        .resize_border = if (custom and !maximized) 6 else 0,
        .band_fraction = if (custom) band_frac else 0,
        .controls_fraction = if (custom and controls_active) controls_frac else null,
        .drag_rects = drag_rects,
    });
    return switch (hit) {
        .normal => c.sdl.SDL_HITTEST_NORMAL,
        .draggable => c.sdl.SDL_HITTEST_DRAGGABLE,
        .resize_top_left => c.sdl.SDL_HITTEST_RESIZE_TOPLEFT,
        .resize_top => c.sdl.SDL_HITTEST_RESIZE_TOP,
        .resize_top_right => c.sdl.SDL_HITTEST_RESIZE_TOPRIGHT,
        .resize_right => c.sdl.SDL_HITTEST_RESIZE_RIGHT,
        .resize_bottom_right => c.sdl.SDL_HITTEST_RESIZE_BOTTOMRIGHT,
        .resize_bottom => c.sdl.SDL_HITTEST_RESIZE_BOTTOM,
        .resize_bottom_left => c.sdl.SDL_HITTEST_RESIZE_BOTTOMLEFT,
        .resize_left => c.sdl.SDL_HITTEST_RESIZE_LEFT,
    };
}

/// Install the hit-test (every desktop OS) and, with the custom title bar,
/// make the window borderless. Call each frame before any chrome is drawn: it
/// self-gates, and it clears last frame's header drag handle so a hidden
/// header (immersive playback, page shell) stops dragging. `win` is dvui's
/// underlying SDL_Window.
pub fn ensureEnabled(win: ?*c.sdl.SDL_Window) void {
    header_drag_rect = .{};
    if (comptime !hit_pure.platformSupported(builtin.os.tag, builtin.abi)) return;
    if (win == null) return;
    sdl_window = win;
    if (!hit_test_installed) {
        hit_test_installed = true;
        _ = c.sdl.SDL_SetWindowHitTest(win, hitTest, null);
    }
    if (!active() or installed) return;
    installed = true;
    c.sdl.SDL_SetWindowBordered(win, c.sdl.SDL_FALSE);
    c.sdl.SDL_SetWindowResizable(win, c.sdl.SDL_TRUE);
    native.opal_titlebar_install_native(win);
}

/// Mark a widget as a window drag handle for the next hit tests. `r` is a
/// physical-pixel rect (dvui `borderRectScale().r`); it is stored as a window
/// fraction so it matches SDL's window coordinates at any DPI. Only labels and
/// images may sit under it: the OS consumes presses on a drag handle.
pub fn setHeaderDragRect(r: dvui.Rect.Physical) void {
    const wp = dvui.windowRectPixels();
    header_drag_rect = hit_pure.fracRect(r.x, r.y, r.w, r.h, wp.w, wp.h);
}

/// Enter the platform's native caption-drag loop from a drag gesture on the
/// video surface. Windows owns the move from here, including Aero Snap.
pub fn beginNativeDrag() bool {
    if (!active() or sdl_window == null) return false;
    return native.opal_titlebar_begin_native_drag(sdl_window) != 0;
}

fn ctlButton(id: u32, icon_data: []const u8, danger: bool) bool {
    return dvui.buttonIcon(@src(), "", icon_data, .{}, .{}, .{
        .id_extra = id,
        .color_fill = @import("color_compat.zig").wrap(if (playerOverlay()) theme.transparent else theme.colors.bg_surface),
        .color_fill_hover = @import("color_compat.zig").wrap(if (danger) theme.colors.danger else theme.colors.bg_hover),
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
        .border = dvui.Rect.all(0),
        .corners = dvui.CornerRect.all(0),
        .margin = dvui.Rect.all(0),
        .padding = .{ .x = 16, .y = 8, .w = 16, .h = 8 },
        .min_size_content = .{ .w = 12, .h = 12 },
        .max_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
    });
}

/// Draw the bar. Call once, at the very top of the frame (above all other
/// chrome). No-op when the custom title bar isn't active.
pub fn render() void {
    // Comptime gate: the window-control body uses SDL2-only window calls.
    if (comptime !is_windows) return;
    if (!active()) return;
    const win = sdl_window;

    // Overlay lets us pin the brand hard-left and the window controls hard-right
    // independently (a plain horizontal box + spacer proved unreliable for the
    // right group). Full width, fixed compact height.
    var bar = dvui.overlay(@src(), .{
        .expand = .horizontal,
        .background = true,
        .color_fill = @import("color_compat.zig").wrap(if (playerOverlay()) theme.transparent else theme.colors.bg_surface),
        .min_size_content = .{ .w = 0, .h = HEIGHT },
    });

    // The page shell keeps its brand beside the sidebar toggle. Only the
    // legacy chrome and full-screen player need a brand in this title strip.
    if (!state.app.page_shell_enabled or state.app.router.current == .player) {
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
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
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

    // The player draws this bar inside dvui.scale(ui_scale); other routes
    // draw it outside. The Win32 hit-test must exclude the *rendered* control
    // widths, not the unscaled 132-point footprint on the player route.
    // Fractions also work when SDL's window coordinates differ from pixels.
    const wr = dvui.windowRect();
    const hit = geometry.hitRegion(wr.w, wr.h, if (playerOverlay()) state.app.ui_scale else 1.0);
    band_frac = hit.band_fraction;
    controls_frac = hit.controls_fraction;
    controls_active = true;
    native.opal_titlebar_set_geometry(band_frac, controls_frac);
}
