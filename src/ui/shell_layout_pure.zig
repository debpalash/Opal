//! Bounded navigation widths; the content always keeps a usable viewport.
const std = @import("std");
pub const RAIL_WIDTH: f32 = 48;
pub const EXPANDED_WIDTH: f32 = 208;
pub const Layout = struct { sidebar: f32, content: f32, expanded: bool };
pub fn layout(width: f32, collapsed: bool, forced: ?bool) Layout {
    const w = @max(0, width);
    const expanded = (forced orelse (!collapsed and w >= 900)) and w >= 400;
    const sidebar = @min(w, if (expanded) EXPANDED_WIDTH else RAIL_WIDTH);
    return .{ .sidebar = sidebar, .content = @max(0, w - sidebar), .expanded = expanded };
}
test "sidebar budgets retain content at desktop narrow and scaled widths" {
    for ([_]f32{ 320, 640, 900, 1360, 1360.0 / 1.5 }) |width| {
        for ([_]bool{ false, true }) |collapsed| {
            const result = layout(width, collapsed, null);
            try std.testing.expectEqual(width, result.sidebar + result.content);
            try std.testing.expect(result.content >= width - EXPANDED_WIDTH);
            if (width < 900) try std.testing.expect(!result.expanded);
        }
    }
    try std.testing.expectEqual(@as(f32, 432), layout(640, false, true).content);
    try std.testing.expectEqual(RAIL_WIDTH, layout(1360, false, false).sidebar);
}
