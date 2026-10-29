//! Compact identity and status elements shared by service management pages.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");

pub fn iconTile(src: std.builtin.SourceLocation, glyph: []const u8, color: dvui.Color, size: f32) void {
    var tile = dvui.box(src, .{}, .{ .background = true, .color_fill = color.opacity(0.12), .border = dvui.Rect.all(1), .color_border = color.opacity(0.25), .corner_radius = dvui.Rect.all(12), .padding = dvui.Rect.all(10) });
    defer tile.deinit();
    dvui.icon(@src(), "", glyph, .{}, .{ .min_size_content = .{ .w = size, .h = size }, .color_text = color });
}

pub fn badge(src: std.builtin.SourceLocation, label: []const u8, color: dvui.Color) void {
    dvui.labelNoFmt(src, label, .{}, .{ .background = true, .color_fill = color.opacity(0.1), .color_text = color, .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 }, .corner_radius = dvui.Rect.all(8), .font = dvui.themeGet().font_body.withSize(11), .gravity_y = 0.5 });
}

pub fn heading(src: std.builtin.SourceLocation, title: []const u8, detail: []const u8) void {
    const compact = dvui.parentGet().data().contentRect().w < 420;
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 4, .y = 8, .w = 4, .h = 12 } });
    defer row.deinit();
    dvui.labelNoFmt(@src(), title, .{}, .{ .font = dvui.themeGet().font_heading, .color_text = theme.colors.text_primary, .expand = .horizontal, .padding = dvui.Rect.all(0), .gravity_y = 0.5 });
    if (!compact) badge(@src(), detail, theme.colors.text_secondary);
}

/// Compact section label; longer guidance stays available on hover.
pub fn section(src: std.builtin.SourceLocation, title: []const u8, detail: []const u8, glyph: []const u8) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(8),
        .padding = .{ .x = 10, .y = 7, .w = 8, .h = 7 },
        .margin = .{ .y = 10, .h = 6 },
    });
    var show_help = dvui.dataGet(null, row.data().id, "section_help", bool) orelse false;
    dvui.icon(@src(), "", glyph, .{}, .{ .min_size_content = theme.iconSize(.sm), .color_text = theme.colors.accent, .gravity_y = 0.5, .margin = .{ .w = 8 } });
    dvui.labelNoFmt(@src(), title, .{}, .{ .expand = .horizontal, .font = dvui.themeGet().font_body.withSize(13), .color_text = theme.colors.text_primary, .padding = dvui.Rect.all(0), .gravity_y = 0.5 });
    if (detail.len > 0) {
        var help: dvui.WidgetData = undefined;
        const clicked = dvui.buttonIcon(@src(), "Section help", @import("icons").tvg.lucide.info, .{}, .{}, .{ .data_out = &help, .color_fill = theme.transparent, .color_text = theme.colors.text_tertiary, .min_size_content = theme.iconSize(.sm), .padding = dvui.Rect.all(2), .gravity_y = 0.5 });
        @import("components.zig").tip(@src(), help, detail);
        if (clicked) {
            show_help = !show_help;
            dvui.dataSet(null, row.data().id, "section_help", show_help);
        }
    }
    row.deinit();
    if (show_help and detail.len > 0) @import("components.zig").bodyText(@src(), detail, theme.colors.text_secondary);
}
