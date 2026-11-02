const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const footer = @import("footer.zig");
const capture = @import("native_capture.zig");

var factor_for_test: f32 = 1;

fn setup() !void {
    state.showToast("Saved");
    state.app.toast_expire += 60_000;
}
fn cleanup() void {
    state.app.toast_len = 0;
}
fn draw() !void {
    var factor = factor_for_test;
    var scale = dvui.scale(@src(), .{ .scale = &factor }, .{ .expand = .both });
    defer scale.deinit();
    var content = dvui.box(@src(), .{}, .{ .expand = .both });
    content.deinit();
    footer.renderToast();
    try std.testing.expectApproxEqAbs(scale.data().contentRect().h / factor, footer.toast_rect_for_test.h, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), footer.toast_rect_for_test.y, 1);
}
test "Native toast overlays expanded content without red layout borders" {
    const logs = @import("../core/logs.zig");
    logs.logs_allocator = @import("../core/alloc.zig").allocator;
    defer logs.deinit();
    for ([_]f32{ 1, 1.5 }) |factor| {
        factor_for_test = factor;
        try capture.capture(640, 480, "toast-after-expanded-content", setup, draw, cleanup);
    }
}
