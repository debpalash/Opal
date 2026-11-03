//! Cocoa child views yield to DVUI overlays and disappear on other routes.
const dvui = @import("dvui");
const native = @import("../services/native_browser.zig");
const pure = @import("../services/native_browser_pure.zig");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
var sidebar_cover: ?struct { id: dvui.Id, rect: dvui.Rect.Physical } = null;
pub fn occludeSidebar(id: dvui.Id, rect: dvui.Rect.Physical) void {
    sidebar_cover = .{ .id = id, .rect = rect };
}
pub fn beginFrame() void {
    sidebar_cover = null;
    @import("browser_hub.zig").dismissWhenInactive();
    native.beginFrame();
    if (comptime !native.supported) return;
    @import("../services/browser_privacy.zig").tick();
    native.render_chrome = @import("browser_privacy.zig").render;
}
pub fn endFrame() void {
    if (comptime !native.supported) return;
    var visible = !state.app.command_palette_open and !state.app.cheatsheet_open;
    const stack = dvui.currentWindow().subwindows.stack.items;
    if (stack.len > 1) for (stack[1..]) |sw| {
        if (@import("update_prompt.zig").popup_id) |id| if (sw.id == id) continue;
        const r = sw.rect_pixels;
        if (sidebar_cover) |cover| {
            if (sw.id == cover.id) continue;
            // Rail tooltips already lie over the area cropped for the sidebar.
            const c = cover.rect;
            if (!sw.modal and r.x >= c.x and r.y >= c.y and r.x + r.w <= c.x + c.w and r.y + r.h <= c.y + c.h) continue;
        }
        if (sw.used and (sw.modal or pure.intersects(native.viewport, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }))) {
            visible = false;
        }
    };
    const bg = theme.colors.bg_deep;
    native.api.opal_browser_occlude_left(if (sidebar_cover) |cover| cover.rect.x + cover.rect.w else 0);
    const rgb = (@as(c_uint, bg.r) << 16) | (@as(c_uint, bg.g) << 8) | bg.b;
    native.endFrame(visible, rgb, @as(u32, bg.r) + bg.g + bg.b < 384);
    const popup = @import("update_prompt.zig");
    const window = dvui.windowRectPixels();
    native.api.opal_browser_occlude_popup(popup.bounds.x, popup.bounds.y, if (popup.popup_id != null) popup.bounds.w else 0, if (popup.popup_id != null) popup.bounds.h else 0, window.w, window.h);
}
