const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");

// --- Tooltip helper ---
/// Show a themed tooltip anchored to a widget's rect.
/// Usage: var wd: dvui.WidgetData = undefined;
///        if (dvui.buttonIcon(@src(), "lbl", ic, .{}, .{}, .{ .data_out = &wd, ... })) { ... }
///        tip(@src(), wd, "Full description");
pub fn tip(src: std.builtin.SourceLocation, wd: dvui.WidgetData, text: []const u8) void {
    dvui.tooltip(src, .{ .active_rect = wd.borderRectScale().r }, "{s}", .{text}, .{
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_main,
        .color_border = theme.colors.divider,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(6),
        .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
    });
}
// --- Primitives ---
pub fn initCard(src: std.builtin.SourceLocation) !dvui.BoxWidget {
    const b = dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_card,
        .color_border = theme.colors.border_card,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_md,
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        .padding = theme.dims.pad_md
    });
    return b;
}

pub fn initGlassPanel(src: std.builtin.SourceLocation) !dvui.BoxWidget {
    const b = dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_glass,
        .color_border = theme.colors.border_glass,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_lg,
        .padding = theme.dims.pad_md,
        .box_shadow = .{ .color = dvui.Color{ .r=0, .g=0, .b=0, .a=180 }, .offset = .{ .x=0, .y=4 }, .fade = 12.0 },
    });
    return b;
}

pub fn initDrawer(src: std.builtin.SourceLocation, override_width: ?f32) !dvui.BoxWidget {
    const w = if (override_width) |ov| ov else 480;
    const b = dvui.box(src, .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = w, .h = 10 },
        .expand = .vertical,
        .background = true,
        .color_fill = theme.colors.bg_drawer,
        .color_border = theme.colors.border_drawer,
        .border = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
        .padding = theme.dims.pad_lg,
    });
    return b;
}

// --- Specific Controls ---

pub fn IconBtn(src: std.builtin.SourceLocation, name: []const u8, icon: anytype, color_text: dvui.Color, color_fill: dvui.Color) bool {
    const opts = dvui.Options{ .color_text = color_text, .color_fill = color_fill };
    return dvui.buttonIcon(src, name, icon, .{}, .{}, opts);
}

pub fn AlertCard(src: std.builtin.SourceLocation, msg: []const u8, level: enum { warning, danger, success }) void {
    const col = switch(level) {
        .warning => theme.colors.warning,
        .danger => theme.colors.danger,
        .success => theme.colors.success,
    };
    
    var b = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_input,
        .color_border = col,
        .border = .{ .x=2, .y=0, .w=0, .h=0 }, // Left edge accent
        .padding = theme.dims.pad_sm,
        .margin = .{ .x=0, .y=4, .w=0, .h=4 }
    });
    defer b.deinit();
    
    _ = dvui.label(src, "{s}", .{msg}, .{ .color_text = col });
}

pub fn ProgressBar(src: std.builtin.SourceLocation, fraction: f32, label: []const u8, id_extra: usize) void {
    var container = dvui.box(src, .{ .dir = .vertical }, .{ .id_extra = id_extra, .expand = .horizontal, .margin = .{ .x=0, .y=4, .w=0, .h=4 } });
    defer container.deinit();
    
    if (label.len > 0) {
        _ = dvui.label(@src(), "{s}", .{label}, .{ .id_extra = id_extra, .color_text = theme.colors.text_muted });
    }
    
    var pct_val = std.math.clamp(fraction, 0.0, 1.0);
    _ = dvui.slider(@src(), .{ .fraction = &pct_val }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .{ .w = 10, .h = 8 },
        .color_fill = theme.colors.bg_input,
        .color_text = theme.colors.accent,
        .corner_radius = dvui.Rect.all(4)
    });
}

// ── Phase 4: Additional UI Primitives ──

/// Small colored pill badge for status display.
/// Usage: StatusBadge(@src(), "LIVE", .success);
pub fn StatusBadge(src: std.builtin.SourceLocation, label: []const u8, level: enum { info, success, warning, danger }) void {
    const col = switch (level) {
        .info => theme.colors.accent,
        .success => theme.colors.success,
        .warning => theme.colors.warning,
        .danger => theme.colors.danger,
    };
    var b = dvui.box(src, .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = dvui.Color{ .r = col.r, .g = col.g, .b = col.b, .a = 30 },
        .color_border = col,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(99),
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
    });
    defer b.deinit();
    _ = dvui.label(src, "{s}", .{label}, .{ .color_text = col });
}

/// Horizontal divider line with themed color.
pub fn Divider(src: std.builtin.SourceLocation) void {
    var d = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.divider,
        .min_size_content = .{ .w = 0, .h = 1 },
        .max_size_content = .{ .w = 0, .h = 1 },
        .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 },
    });
    d.deinit();
}

/// Empty state placeholder with icon + message.
pub fn EmptyState(src: std.builtin.SourceLocation, icon: anytype, title: []const u8, subtitle: []const u8) void {
    var container = dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.4,
        .padding = dvui.Rect.all(20),
    });
    defer container.deinit();

    _ = dvui.icon(src, "", icon, .{}, .{
        .color_text = theme.colors.text_dim,
        .min_size_content = .{ .w = 36, .h = 36 },
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });
    _ = dvui.label(src, "{s}", .{title}, .{
        .color_text = theme.colors.text_muted,
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });
    if (subtitle.len > 0) {
        _ = dvui.label(src, "{s}", .{subtitle}, .{
            .color_text = theme.colors.text_dim,
            .gravity_x = 0.5,
        });
    }
}

/// Compact inline progress indicator (thin bar, no label).
pub fn MiniProgress(src: std.builtin.SourceLocation, fraction: f32, color: dvui.Color) void {
    var pct = std.math.clamp(fraction, 0.0, 1.0);
    _ = dvui.slider(src, .{ .fraction = &pct }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 10, .h = 3 },
        .max_size_content = .{ .w = 9999, .h = 4 },
        .color_fill = theme.colors.bg_input,
        .color_text = color,
        .corner_radius = dvui.Rect.all(2),
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
    });
}
