//! Cocoa child views yield to DVUI overlays and disappear on other routes.
const dvui = @import("dvui");
const native = @import("../services/native_browser.zig");
const pure = @import("../services/native_browser_pure.zig");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
pub fn endFrame() void {
    if (comptime !native.supported) return;
    var visible = !state.app.command_palette_open and !state.app.cheatsheet_open;
    const stack = dvui.currentWindow().subwindows.stack.items;
    if (stack.len > 1) for (stack[1..]) |sw| {
        const r = sw.rect_pixels;
        if (sw.used and (sw.modal or pure.intersects(native.viewport, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }))) visible = false;
    };
    const bg = theme.colors.bg_deep;
    const rgb = (@as(c_uint, bg.r) << 16) | (@as(c_uint, bg.g) << 8) | bg.b;
    native.endFrame(visible, rgb, @as(u32, bg.r) + bg.g + bg.b < 384);
}
