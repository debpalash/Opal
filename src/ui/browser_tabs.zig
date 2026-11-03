//! Compact horizontal tabs beneath the browser address toolbar.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const browser = @import("../services/browser.zig");
const state = @import("../core/state.zig");
pub const height: f32 = 32;
pub var tab_bounds_for_test: [browser.tab_model.max_tabs]dvui.Rect.Physical = @splat(.{});
pub var close_bounds_for_test: [browser.tab_model.max_tabs]dvui.Rect.Physical = @splat(.{});
pub var title_bounds_for_test: [browser.tab_model.max_tabs]dvui.Rect.Physical = @splat(.{});
pub var new_bounds_for_test: dvui.Rect.Physical = .{};
var revealed_tab: u32 = 0;
var revealed_width: f32 = 0;

pub fn handleShortcuts() void {
    if (comptime !browser.native.supported) return;
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key or event.evt.key.action != .down) continue;
        const key = event.evt.key;
        const command = key.mod.command() or key.mod.control();
        if (command and key.code == .t) {
            browser.newTab("");
            event.handled = true;
        }
        if (command and key.code == .w) {
            browser.closeTab(browser.tabsView().items[browser.tabsView().active].id);
            event.handled = true;
        }
        if (key.mod.control() and key.code == .tab) {
            browser.cycleTab(key.mod.shift());
            event.handled = true;
        }
    }
}
pub fn render() void {
    if (comptime !browser.native.supported) return;
    handleShortcuts();
    browser.refreshTabs();
    const model = browser.tabsView();
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = height },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = height },
        .background = true,
        .color_fill = .{ .color = theme.colors.bg_app },
        .padding = .{ .x = 4, .w = 4 },
        .border = .{ .h = 1 },
        .color_border = .{ .color = theme.colors.border_subtle },
    });
    defer strip.deinit();
    const available = dvui.windowRect().w / state.app.ui_scale - 44;
    const width = std.math.clamp(available / @as(f32, @floatFromInt(model.count)) - 2, 96, 220);
    const tabs_width = @min(available, (width + 2) * @as(f32, @floatFromInt(model.count)));
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto, .horizontal_bar = .hide, .vertical = .none }, .{ .expand = .vertical, .min_size_content = .{ .w = tabs_width }, .max_size_content = .{ .w = tabs_width, .h = height } });
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .vertical });
    var select: ?u32 = null;
    var close: ?u32 = null;
    for (model.items[0..model.count], 0..) |*tab, index| {
        const active = index == model.active;
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{
            .id_extra = tab.id,
            .min_size_content = .{ .w = width - 12, .h = 24 },
            .max_size_content = .{ .w = width - 12, .h = 24 },
            .color_fill = .{ .color = if (active) theme.colors.bg_elevated else theme.transparent },
            .color_fill_hover = .{ .color = theme.colors.bg_hover },
            .color_text = .{ .color = if (active) theme.colors.text_primary else theme.colors.text_secondary },
            .color_border = .{ .color = if (active) theme.colors.accent else theme.transparent },
            .border = .{ .h = 2 },
            .padding = .{ .x = 6, .w = 6, .y = 2, .h = 2 },
            .corners = theme.dims.rad_sm,
            .margin = .{ .w = 2 },
        });
        button.processHover();
        button.drawBackground();
        if (active and (revealed_tab != tab.id or revealed_width != available) and button.data().rect.w > 0) {
            dvui.scrollTo(.{ .screen_rect = button.data().borderRectScale().r });
            revealed_tab = tab.id;
            revealed_width = available;
        }
        if (@import("builtin").is_test) tab_bounds_for_test[index] = button.data().borderRectScale().r;
        var contents = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        if (tab.loading) dvui.spinner(@src(), .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.accent } }) else dvui.icon(@src(), "Page", icons.tvg.lucide.globe, .{}, .{ .min_size_content = .{ .w = 12, .h = 12 }, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.text_tertiary } });
        var title_data: dvui.WidgetData = undefined;
        _ = dvui.label(@src(), "{s}", .{if (tab.title.len > 0) tab.title.text() else "New tab"}, .{ .data_out = &title_data, .expand = .horizontal, .gravity_y = 0.5, .padding = dvui.Rect.all(0), .margin = .{ .x = 6 }, .color_text = .{ .color = if (active) theme.colors.text_primary else theme.colors.text_secondary } });
        if (@import("builtin").is_test) title_bounds_for_test[index] = title_data.borderRectScale().r;
        var close_data: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), "Close tab", icons.tvg.lucide.x, .{}, .{}, .{
            .data_out = &close_data,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 12, .h = 12 },
            .padding = dvui.Rect.all(3),
            .margin = dvui.Rect.all(0),
            .color_fill = .{ .color = theme.transparent },
            .color_fill_hover = .{ .color = theme.colors.bg_hover },
            .color_text = .{ .color = theme.colors.text_secondary },
            .corners = theme.dims.rad_sm,
        })) close = tab.id;
        if (@import("builtin").is_test) close_bounds_for_test[index] = close_data.borderRectScale().r;
        contents.deinit();
        // Children consume close clicks before the containing tab can activate.
        button.processEvents();
        if (button.clicked() and close == null) select = tab.id;
        button.drawFocus();
        button.deinit();
    }
    row.deinit();
    scroll.deinit();
    var new_data: dvui.WidgetData = undefined;
    const create = dvui.buttonIcon(@src(), "New tab", icons.tvg.lucide.plus, .{}, .{}, .{
        .data_out = &new_data,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 16, .h = 16 },
        .padding = dvui.Rect.all(6),
        .margin = dvui.Rect.all(0),
        .color_fill = .{ .color = theme.transparent },
        .color_fill_hover = .{ .color = theme.colors.bg_hover },
        .color_text = .{ .color = theme.colors.text_secondary },
        .corners = theme.dims.rad_sm,
    });
    if (@import("builtin").is_test) new_bounds_for_test = new_data.borderRectScale().r;
    if (close) |id| browser.closeTab(id) else if (select) |id| browser.selectTab(id);
    if (create) browser.newTab("");
}
