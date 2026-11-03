//! UI-thread WebKit owner. Navigations from services are copied into a mailbox.
const std = @import("std");
const state = @import("../core/state.zig");
const pure = @import("native_browser_pure.zig");
pub const supported = @import("builtin").os.tag == .macos and !@import("build_options").headless;
pub const api = struct {
    pub extern fn opal_browser_attach(window: ?*anyopaque, private: c_int, wake: *const fn () callconv(.c) void) c_int;
    pub extern fn opal_browser_present(x: f64, y: f64, w: f64, h: f64, pixel_w: f64, pixel_h: f64, visible: c_int, rgb: c_uint, dark: c_int) void;
    pub extern fn opal_browser_close() void;
    pub extern fn opal_browser_has_focus() c_int;
    pub extern fn opal_browser_navigate(url: [*:0]const u8) void;
    pub extern fn opal_browser_command(command: c_int) void;
    pub extern fn opal_browser_zoom(zoom: f64) void;
    pub extern fn opal_browser_find(text: [*:0]const u8, backwards: c_int) void;
    pub extern fn opal_browser_read() void;
    pub extern fn opal_browser_poll(url: [*]u8, url_cap: usize, title: [*]u8, title_cap: usize, err: [*]u8, err_cap: usize, loading: *c_int, found: *c_int) c_uint;
    pub extern fn opal_browser_reader(out: [*]u8, cap: usize) usize;
    pub extern fn opal_browser_test_html(html: [*:0]const u8) void;
    pub extern fn opal_browser_test_pump() void;
    pub extern fn opal_browser_test_attached() c_int;
};
pub const Chrome = enum { toolbar, panel };
// The UI supplies themed controls without importing presentation into services.
pub var render_chrome: ?*const fn (Chrome) void = null;
var lock: @import("../core/sync.zig").Mutex = .{};
var destination: [2048:0]u8 = @splat(0);
var destination_len: usize = 0;
var initialized = false;
var private_mode = false;
pub var presented = false;
pub var viewport: pure.Rect = .{};
var window_size: [2]f64 = .{ 0, 0 };
pub var focus_address = false;
pub var focus_find = false;
fn wake() callconv(.c) void {
    state.wakeUi();
}
pub fn navigate(url: []const u8) void {
    if (!supported or !pure.allowedUrl(url) or url.len >= destination.len) return;
    lock.lock();
    defer lock.unlock();
    @memcpy(destination[0..url.len], url);
    destination[url.len] = 0;
    destination_len = url.len;
}
pub fn beginFrame() void {
    presented = false;
}
pub fn present(window: ?*anyopaque, rect: pure.Rect, width: f64, height: f64) void {
    if (comptime !supported) return;
    if (!initialized or private_mode != state.app.incognito_mode) {
        initialized = api.opal_browser_attach(window, @intFromBool(state.app.incognito_mode), wake) != 0;
        private_mode = state.app.incognito_mode;
        if (!initialized) {
            state.showToast("Could not open the browser");
            return;
        }
    }
    lock.lock();
    if (destination_len > 0) {
        api.opal_browser_navigate(&destination);
        destination_len = 0;
    }
    lock.unlock();
    viewport = pure.clipped(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h }, width, height);
    window_size = .{ width, height };
    presented = viewport.w > 0 and viewport.h > 0;
}
pub fn endFrame(visible: bool, rgb: c_uint, dark: bool) void {
    if (comptime !supported) return;
    if (!initialized) return;
    api.opal_browser_present(viewport.x, viewport.y, viewport.w, viewport.h, window_size[0], window_size[1], @intFromBool(presented and visible), rgb, @intFromBool(dark));
}
pub fn deinit() void {
    if (comptime supported) api.opal_browser_close();
    initialized = false;
    presented = false;
}
pub fn command(cmd: c_int) void {
    if (comptime supported) api.opal_browser_command(cmd);
}
pub fn zoom(factor: f32) void {
    if (comptime supported) api.opal_browser_zoom(factor);
}
pub fn find(text: []const u8, backwards: bool) void {
    if (comptime !supported) return;
    var buf: [2048:0]u8 = @splat(0);
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    api.opal_browser_find(&buf, @intFromBool(backwards));
}
pub fn read() void {
    if (comptime supported) api.opal_browser_read();
}
