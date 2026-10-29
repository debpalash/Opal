//! Shared browse menu shell. Views own menu data and apply returned action IDs;
//! this module owns layout, accessibility, visual state, and overflow.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");
const icons = @import("icons");

pub const Item = struct {
    /// Stable within a menu, independent of display order and visibility.
    id: usize,
    label: []const u8,
    icon: ?[]const u8 = null,
    active: bool = false,
    visible: bool = true,
    enabled: bool = true,
    /// Sources sharing a glyph should use labels; distinct categories use icons.
    presentation: enum { icon, label, icon_label, adaptive } = .icon,
};
pub const Menu = struct {
    items: []const Item,
    selected: ?usize = null,
};

pub const Toolbar = struct {
    scroll: *dvui.ScrollAreaWidget,
    row: *dvui.BoxWidget,
    compact: bool,

    pub fn deinit(self: *Toolbar) void {
        self.row.deinit();
        self.scroll.deinit();
    }
    pub fn rect(self: Toolbar) dvui.Rect.Physical {
        return self.scroll.data().borderRectScale().r;
    }
    /// Native controls (search, genre selectors, year steppers) may be drawn
    /// between menus. They inherit this shell without provider callbacks here.
    pub fn menu(self: Toolbar, src: std.builtin.SourceLocation, config: Menu) ?usize {
        return renderMenu(src, config, self.compact);
    }
};

pub fn begin(src: std.builtin.SourceLocation) Toolbar {
    if (@import("builtin").is_test) native_count = 0;
    const compact = dvui.parentGet().data().contentRect().w < 850;
    const height = @import("browse_layout_pure.zig").toolbarHeight(dvui.themeGet().font_body.size);
    const scroll = dvui.scrollArea(src, .{ .horizontal = .auto, .horizontal_bar = .auto_overlay, .vertical = .none }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = height },
        .max_size_content = dvui.Options.MaxSize.height(height),
        .background = false,
    });
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        .background = true,
        .color_fill = theme.colors.bg_app,
    });
    return .{ .scroll = scroll, .row = row, .compact = compact };
}

pub fn renderMenu(src: std.builtin.SourceLocation, config: Menu, compact: bool) ?usize {
    var selected: ?usize = null;
    for (config.items) |entry| {
        var control = entry;
        if (config.selected) |id| control.active = id == control.id;
        if (control.presentation == .adaptive) control.presentation = if (compact) .icon else .label;
        if (item(src, control)) selected = control.id;
    }
    return selected;
}

pub fn item(src: std.builtin.SourceLocation, config: Item) bool {
    if (!config.visible) return false;
    var wd: dvui.WidgetData = undefined;
    const opts: dvui.Options = .{
        .id_extra = config.id,
        .data_out = &wd,
        .color_fill = if (config.active) theme.colors.bg_elevated else theme.transparent,
        .color_fill_hover = if (config.enabled) theme.colors.bg_hover else theme.transparent,
        .color_text = if (!config.enabled) theme.colors.text_tertiary else if (config.active) theme.colors.accent else theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = dvui.Rect.all(6),
        .margin = .{ .x = 1, .w = 1 },
        .gravity_y = 0.5,
        .min_size_content = theme.iconSize(.sm),
    };
    // Disabled controls are deliberately not focusable or actionable.
    if (!config.enabled) {
        if (config.icon != null and config.presentation != .label) {
            _ = dvui.icon(src, config.label, config.icon.?, .{}, opts);
        } else {
            _ = dvui.label(src, "{s}", .{config.label}, opts);
        }
        recordNative(config, wd);
        components.tipId(src, wd, config.label, config.id);
        return false;
    }
    const clicked = if (config.icon != null and config.presentation == .icon_label)
        iconLabelButton(src, config.label, config.icon.?, opts)
    else if (config.icon != null and config.presentation != .label)
        dvui.buttonIcon(src, config.label, config.icon.?, .{}, .{}, opts)
    else
        dvui.button(src, config.label, .{}, opts);
    recordNative(config, wd);
    components.tipId(src, wd, config.label, config.id);
    return clicked;
}

fn iconLabelButton(src: std.builtin.SourceLocation, label: []const u8, glyph: []const u8, opts: dvui.Options) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, opts.override(.{ .label = .{ .text = label } }));
    button.processEvents();
    button.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        const style = opts.strip().override(button.style());
        dvui.icon(@src(), label, glyph, .{}, style.override(.{ .min_size_content = theme.iconSize(.sm), .margin = .{ .w = 6 }, .gravity_y = 0.5, .color_text = opts.color_text, .role = .none }));
        dvui.labelNoFmt(@src(), label, .{}, style.override(.{ .padding = dvui.Rect.all(0), .gravity_y = 0.5, .color_text = opts.color_text, .role = .none }));
    }
    const clicked = button.clicked();
    button.drawFocus();
    button.deinit();
    return clicked;
}

pub fn divider(src: std.builtin.SourceLocation, id: usize) void {
    var box = dvui.box(src, .{}, .{
        .id_extra = id,
        .min_size_content = .{ .w = 1, .h = 18 },
        .background = true,
        .color_fill = theme.colors.border_subtle,
        .margin = .{ .x = 6, .w = 6 },
        .gravity_y = 0.5,
    });
    box.deinit();
}

pub fn zoom(src: std.builtin.SourceLocation, current: f32, min: f32, max: f32) f32 {
    const action = renderMenu(src, .{ .items = &.{
        .{ .id = 99001, .label = "Smaller cards", .icon = icons.tvg.lucide.minus, .enabled = current > min },
        .{ .id = 99002, .label = "Larger cards", .icon = icons.tvg.lucide.plus, .enabled = current < max },
    } }, true) orelse return current;
    return std.math.clamp(current + @as(f32, if (action == 99001) -40 else 40), min, max);
}

// Native verification observes production controls; no separate test renderer.
pub const NativeControl = struct { id: usize, widget: dvui.Id, rect: dvui.Rect.Physical, active: bool, enabled: bool };
var native_controls: [128]NativeControl = undefined;
var native_count: usize = 0;
pub fn nativeControlsForTest() []const NativeControl {
    if (!@import("builtin").is_test) @compileError("Native fixture is test-only");
    return native_controls[0..native_count];
}
fn recordNative(config: Item, wd: dvui.WidgetData) void {
    if (@import("builtin").is_test and native_count < native_controls.len) {
        native_controls[native_count] = .{ .id = config.id, .widget = wd.id, .rect = wd.borderRectScale().r, .active = config.active, .enabled = config.enabled };
        native_count += 1;
    }
}
