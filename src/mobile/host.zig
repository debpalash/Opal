//! Selects the iOS or Android host externs; ios_frame.zig stays platform-neutral.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../core/platform_pure.zig");
const android = builtin.abi.isAndroid();

extern fn opal_ios_resource_dir() [*:0]const u8;
extern fn opal_ios_safe_area(top: *f32, bottom: *f32, left: *f32, right: *f32, keyboard: *f32) void;
extern fn opal_ios_ready() void;
extern fn opal_ios_ui_test() bool;
extern fn opal_android_resource_dir() [*:0]const u8;
extern fn opal_android_safe_area(top: *f32, bottom: *f32, left: *f32, right: *f32, keyboard: *f32) void;
extern fn opal_android_ready() void;
extern fn opal_android_pick_file() void;
extern fn opal_android_set_landscape(on: bool) void;
extern fn opal_android_move_task_to_back() void;

/// No UI walkthrough hook exists on Android.
pub const ui_test_supported = !android;

pub fn resourceDir() [*:0]const u8 {
    return if (comptime android) opal_android_resource_dir() else opal_ios_resource_dir();
}
pub fn ready() void {
    if (comptime android) opal_android_ready() else opal_ios_ready();
}
pub fn uiTest() bool {
    return if (comptime android) false else opal_ios_ui_test();
}
pub fn pickFile() void {
    if (comptime android) opal_android_pick_file();
}

/// Android Back key: consume the pending press (always false elsewhere).
pub fn takeBack() bool {
    if (comptime !android) return false;
    return @import("android_pure.zig").back_pending.swap(false, .acq_rel);
}
pub fn setLandscape(on: bool) void {
    if (comptime android) opal_android_set_landscape(on);
}
pub fn moveTaskToBack() void {
    if (comptime android) opal_android_move_task_to_back();
}

/// Safe area in dvui logical units, plus the on-screen keyboard height.
pub fn safeArea(top: *f32, bottom: *f32, left: *f32, right: *f32, keyboard: *f32) void {
    if (comptime !android) return opal_ios_safe_area(top, bottom, left, right, keyboard);
    const dvui = @import("dvui");
    var px: @import("android_pure.zig").Insets = .{};
    var kb: f32 = 0;
    opal_android_safe_area(&px.top, &px.bottom, &px.left, &px.right, &kb);
    const logical = dvui.windowRect().w;
    const pixel = dvui.windowRectPixels().w;
    const l = @import("android_pure.zig").toLogical(px, kb, logical, pixel);
    top.* = l.insets.top;
    bottom.* = l.insets.bottom;
    left.* = l.insets.left;
    right.* = l.insets.right;
    keyboard.* = l.keyboard;
}
