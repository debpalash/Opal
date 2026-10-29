//! Shared compact country selector for regional browse catalogs.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const countries = @import("../services/countries_pure.zig");
var search: [96]u8 = @splat(0);
pub fn render(src: std.builtin.SourceLocation, selected: usize) ?usize {
    var menu = dvui.menu(src, .horizontal, .{ .gravity_y = 0.5 });
    defer menu.deinit();
    var result: ?usize = null;
    if (dvui.menuItemLabel(src, countries.at(selected).name, .{ .submenu = true }, .{
        .color_text = if (selected == 0) theme.colors.text_secondary else theme.colors.accent,
        .color_fill = theme.colors.bg_elevated,
        .background = true,
        .corner_radius = theme.dims.rad_sm,
        .padding = dvui.Rect.all(6),
    })) |r| {
        var popup = dvui.floatingMenu(src, .{ .from = r }, .{});
        defer popup.deinit();
        var box = dvui.box(src, .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 220 }, .padding = dvui.Rect.all(6), .background = true, .color_fill = theme.colors.bg_surface });
        defer box.deinit();
        var input = dvui.textEntry(src, .{ .text = .{ .buffer = &search }, .placeholder = "Find country…" }, .{ .expand = .horizontal });
        input.deinit();
        var scroll = dvui.scrollArea(src, .{ .horizontal = .none }, .{ .max_size_content = .{ .w = 280, .h = 320 }, .expand = .horizontal });
        defer scroll.deinit();
        var options = dvui.menu(src, .vertical, .{});
        defer options.deinit();
        const query = std.mem.sliceTo(&search, 0);
        for (countries.all, 0..) |country, i| {
            if (i != 0 and query.len > 0 and std.ascii.indexOfIgnoreCase(country.name, query) == null and std.ascii.indexOfIgnoreCase(country.code, query) == null) continue;
            if (dvui.menuItemLabel(src, country.name, .{}, .{ .id_extra = i, .expand = .horizontal, .color_text = if (i == selected) theme.colors.accent else theme.colors.text_primary })) |_| {
                result = i;
                @memset(&search, 0);
            }
        }
    }
    return result;
}
