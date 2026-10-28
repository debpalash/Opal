//! Exercise real menu widgets: stable actions, focus, hidden/disabled options,
//! adaptive sizing, and selection across reordering.
const std = @import("std");
const dvui = @import("dvui");
const filters = @import("browse_filters.zig");
const icons = @import("icons");
var frame: usize = 0;
var selected: usize = 91;
var changes: usize = 0;
var compact: bool = false;
fn setup() !void {
    frame = 0;
    selected = 91;
    changes = 0;
}
fn control(id: usize) !filters.NativeControl {
    for (filters.nativeControlsForTest()) |entry| if (entry.id == id) return entry;
    return error.MissingControl;
}
fn click(id: usize) !void {
    const entry = try control(id);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = entry.rect.center() });
    _ = try dvui.currentWindow().addEventMouseButton(.left, .press);
    _ = try dvui.currentWindow().addEventMouseButton(.left, .release);
}
fn draw() !void {
    if (frame == 2) try click(7);
    if (frame == 4) {
        const entry = try control(91);
        dvui.focusWidget(entry.widget, null, null);
        _ = try dvui.currentWindow().addEventKey(.{ .code = .space, .action = .down, .mod = .none });
    }
    if (frame == 6) try click(33);
    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer root.deinit();
    var bar = filters.begin(@src());
    defer bar.deinit();
    try std.testing.expectEqual(compact, bar.compact);
    var menu = [_]filters.Item{
        .{ .id = 91, .label = "Trending", .icon = icons.tvg.lucide.compass, .presentation = .adaptive },
        .{ .id = 44, .label = "Hidden", .icon = icons.tvg.lucide.star, .visible = false },
        .{ .id = 7, .label = "Favorites", .icon = icons.tvg.lucide.heart, .presentation = .adaptive },
        .{ .id = 33, .label = "Unavailable", .icon = icons.tvg.lucide.lock, .enabled = false },
    };
    if (frame >= 3) std.mem.swap(filters.Item, &menu[0], &menu[2]);
    if (bar.menu(@src(), .{ .items = &menu, .selected = selected })) |id| {
        selected = id;
        changes += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), filters.nativeControlsForTest().len);
    if (frame >= 2 and frame < 4) try std.testing.expectEqual(@as(usize, 7), selected);
    if (frame >= 4) try std.testing.expectEqual(@as(usize, 91), selected);
    if (frame >= 5) try std.testing.expect((try control(91)).active);
    if (frame >= 3) {
        const bounds = bar.rect();
        for (filters.nativeControlsForTest()) |entry| {
            try std.testing.expect(entry.rect.h > 0);
            try std.testing.expect(entry.rect.y >= bounds.y);
            try std.testing.expect(entry.rect.y + entry.rect.h <= bounds.y + bounds.h + 1);
        }
    }
    if (frame == 7) try std.testing.expectEqual(@as(usize, 2), changes);
    frame += 1;
}
pub fn run() !void {
    for ([_]u32{ 360, 1200 }) |width| {
        compact = width < 850;
        try @import("native_capture.zig").capture(width, 240, "browse-filter-actions", setup, draw, null);
    }
}
