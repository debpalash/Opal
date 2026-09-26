//! Thin Zig boundary for the app-owned NSOpenPanel.

const builtin = @import("builtin");
const build_options = @import("build_options");

const enabled = builtin.os.tag == .macos and !build_options.headless;

extern fn opal_open_panel_show() void;
extern fn opal_open_panel_take(output: [*]u8, capacity: usize) usize;

pub fn show() void {
    if (enabled) opal_open_panel_show();
}

pub fn take(output: []u8) usize {
    if (!enabled or output.len == 0) return 0;
    return opal_open_panel_take(output.ptr, output.len);
}
