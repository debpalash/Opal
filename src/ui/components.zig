const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");

// Local shim — colors are runtime (read theme.colors per-frame); spacing/radii/fonts are comptime.

const tk = struct {
    // ── colors (runtime — read fresh each frame from active theme) ──
    pub inline fn bg_deep()        dvui.Color { return theme.colors.bg_deep; }
    pub inline fn bg_surface()     dvui.Color { return theme.colors.bg_surface; }
    pub inline fn bg_elevated()    dvui.Color { return theme.colors.bg_elevated; }
    pub inline fn bg_hover()       dvui.Color { return theme.colors.bg_hover; }
    pub inline fn bg_muted()       dvui.Color { return theme.colors.bg_muted; }
    pub inline fn text_primary()   dvui.Color { return theme.colors.text_primary; }
    pub inline fn text_secondary() dvui.Color { return theme.colors.text_secondary; }
    pub inline fn text_tertiary()  dvui.Color { return theme.colors.text_tertiary; }
    pub inline fn text_on_accent() dvui.Color { return theme.colors.text_on_accent; }
    pub inline fn accent_primary() dvui.Color { return theme.colors.accent_primary; }
    pub inline fn accent_dim()     dvui.Color { return theme.colors.accent_dim; }
    pub inline fn semantic_success() dvui.Color { return theme.colors.semantic_success; }
    pub inline fn semantic_warn()    dvui.Color { return theme.colors.semantic_warn; }
    pub inline fn semantic_error()   dvui.Color { return theme.colors.semantic_error; }
    pub inline fn border_subtle()  dvui.Color { return theme.colors.border_subtle; }
    pub inline fn border_strong()  dvui.Color { return theme.colors.border_strong; }

    // ── spacing (pixels) ──
    pub const sp_xs:  f32 = theme.spacing.xs;
    pub const sp_sm:  f32 = theme.spacing.sm;
    pub const sp_md:  f32 = theme.spacing.md;
    pub const sp_lg:  f32 = theme.spacing.lg;
    pub const sp_xl:  f32 = theme.spacing.xl;
    pub const sp_xxl: f32 = theme.spacing.xxl;

    // ── radii (dvui.Rect-typed for corner_radius slots) ──
    pub const rad_sm   = dvui.Rect.all(theme.radius.sm);
    pub const rad_md   = dvui.Rect.all(theme.radius.md);
    pub const rad_lg   = dvui.Rect.all(theme.radius.lg);
    pub const rad_pill = dvui.Rect.all(theme.radius.pill);

    // ── font sizes ──
    pub const fs_micro:   f32 = theme.font_size.micro;
    pub const fs_small:   f32 = theme.font_size.small;
    pub const fs_body:    f32 = theme.font_size.body;
    pub const fs_title:   f32 = theme.font_size.title;
    pub const fs_display: f32 = theme.font_size.display;
};

fn fontAt(size: f32) dvui.Font {
    var f = dvui.themeGet().font_body;
    f.size = size;
    return f;
}

// ══════════════════════════════════════════════════════════════════════
// Tooltip helper — uses dvui.tooltip / FloatingTooltipWidget
// ══════════════════════════════════════════════════════════════════════
// Usage: var wd: dvui.WidgetData = undefined;
//        if (dvui.buttonIcon(@src(), "lbl", ic, .{}, .{}, .{ .data_out = &wd, ... })) { ... }
//        tip(@src(), wd, "Full description");
pub fn tip(src: std.builtin.SourceLocation, wd: dvui.WidgetData, text: []const u8) void {
    dvui.tooltip(src, .{ .active_rect = wd.borderRectScale().r }, "{s}", .{text}, .{
        .color_fill = tk.bg_elevated(),
        .color_text = tk.text_primary(),
        .color_border = tk.border_subtle(),
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(6),
        .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
    });
}

// ══════════════════════════════════════════════════════════════════════
// Legacy primitives (preserved)
// ══════════════════════════════════════════════════════════════════════

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

/// Horizontal divider line with themed color (legacy signature).
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

/// Empty state placeholder with icon + message (legacy signature).
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

// ══════════════════════════════════════════════════════════════════════
// Canonical shared widget library (v2 — drawer & settings)
// ══════════════════════════════════════════════════════════════════════

/// Convert an ASCII label to uppercase into a stack-local 96-byte buffer.
/// Falls back to the original slice when over budget (never allocates).
fn upperBuf(buf: *[96]u8, label: []const u8) []const u8 {
    if (label.len > buf.len) return label;
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        buf[i] = std.ascii.toUpper(label[i]);
    }
    return buf[0..label.len];
}

/// Uppercase tracked-out heading inside a panel.
/// Color: text_tertiary, font_size.small.
/// Padding: spacing.lg above, spacing.sm below.
pub fn sectionHeader(label: []const u8) void {
    var pad_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = tk.sp_lg, .w = 0, .h = tk.sp_sm },
    });
    defer pad_box.deinit();

    var upper_buf: [96]u8 = undefined;
    const upper = upperBuf(&upper_buf, label);

    _ = dvui.label(@src(), "{s}", .{upper}, .{
        .color_text = tk.text_tertiary(),
        .font = fontAt(tk.fs_small),
    });
}

/// 1px horizontal rule. Color: border_subtle.
/// Vertical margin: spacing.sm above and below.
pub fn divider() void {
    var d = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = tk.border_subtle(),
        .min_size_content = .{ .w = 0, .h = 1 },
        .max_size_content = .{ .w = 0, .h = 1 },
        .margin = .{ .x = 0, .y = tk.sp_sm, .w = 0, .h = tk.sp_sm },
    });
    d.deinit();
}

/// Row with label on left, optional hint below, toggle switch on right.
/// Whole row clickable; hover state lifts the background.
/// Toggle: pill, accent_primary when on, bg_elevated when off, with a
/// smooth 4px circle indicator.
pub fn toggleRow(
    src: std.builtin.SourceLocation,
    label: []const u8,
    hint: ?[]const u8,
    value: *bool,
) void {
    var hovered: bool = false;

    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = if (hovered) tk.bg_hover() else tk.bg_surface(),
        .corner_radius = tk.rad_sm,
        .padding = .{ .x = tk.sp_lg, .y = tk.sp_md, .w = tk.sp_lg, .h = tk.sp_md },
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
    });

    // Toggle on click anywhere in the row.
    if (dvui.clicked(row.data(), .{ .hovered = &hovered })) {
        value.* = !value.*;
        if (builtin.mode == .Debug) {
            std.debug.print("[components.toggleRow] '{s}' -> {}\n", .{ label, value.* });
        }
    }
    row.drawBackground();

    // Left: label + optional hint stacked vertically.
    {
        var text_col = dvui.box(@src(), .{ .dir = .vertical }, .{
            .gravity_y = 0.5,
        });
        defer text_col.deinit();

        _ = dvui.label(@src(), "{s}", .{label}, .{
            .color_text = tk.text_primary(),
            .font = fontAt(tk.fs_body),
        });
        if (hint) |h| {
            if (h.len > 0) {
                _ = dvui.label(@src(), "{s}", .{h}, .{
                    .color_text = tk.text_tertiary(),
                    .font = fontAt(tk.fs_small),
                    .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                });
            }
        }
    }

    // Spacer to push the toggle to the right edge.
    { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }

    // Right: pill toggle. The pill itself is a rounded box; a small
    // circle indicator slides to one of the two ends based on `value.*`.
    {
        const pill_w: f32 = 36;
        const pill_h: f32 = 20;
        const knob: f32 = 14;
        var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .background = true,
            .color_fill = if (value.*) tk.accent_primary() else tk.bg_elevated(),
            .color_border = if (value.*) tk.accent_primary() else tk.border_strong(),
            .border = dvui.Rect.all(1),
            .corner_radius = tk.rad_pill,
            .min_size_content = .{ .w = pill_w, .h = pill_h },
            .max_size_content = .{ .w = pill_w, .h = pill_h },
            .padding = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
        });
        defer pill.deinit();

        // Spacer that pushes the knob to the right when on.
        if (value.*) {
            var s = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            s.deinit();
        }
        var knob_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .background = true,
            .color_fill = if (value.*) tk.text_on_accent() else tk.text_primary(),
            .corner_radius = tk.rad_pill,
            .min_size_content = .{ .w = knob, .h = knob },
            .max_size_content = .{ .w = knob, .h = knob },
        });
        knob_box.deinit();
        if (!value.*) {
            var s = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            s.deinit();
        }
    }

    row.deinit();
}

/// Row with label on left and a dropdown of `options` on the right,
/// `selected` is the chosen index. Same hover/padding rules as toggleRow.
pub fn selectRow(
    src: std.builtin.SourceLocation,
    label: []const u8,
    options: []const []const u8,
    selected: *usize,
) void {
    var hovered: bool = false;

    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = if (hovered) tk.bg_hover() else tk.bg_surface(),
        .corner_radius = tk.rad_sm,
        .padding = .{ .x = tk.sp_lg, .y = tk.sp_md, .w = tk.sp_lg, .h = tk.sp_md },
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
    });
    _ = dvui.clicked(row.data(), .{ .hovered = &hovered });
    row.drawBackground();

    // Left label.
    _ = dvui.label(@src(), "{s}", .{label}, .{
        .gravity_y = 0.5,
        .color_text = tk.text_primary(),
        .font = fontAt(tk.fs_body),
    });

    { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }

    // Right dropdown. dvui.dropdown draws the chosen entry + chevron and
    // pops a floating menu on click.
    if (options.len > 0) {
        if (selected.* >= options.len) selected.* = 0;
        const dd_changed = dvui.dropdown(@src(), options, .{ .choice = selected }, .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 120, .h = 24 },
            .color_fill = tk.bg_elevated(),
            .color_text = tk.text_primary(),
            .color_border = tk.border_strong(),
            .border = dvui.Rect.all(1),
            .corner_radius = tk.rad_md,
            .padding = .{ .x = tk.sp_md, .y = tk.sp_xs, .w = tk.sp_md, .h = tk.sp_xs },
        });
        if (dd_changed and builtin.mode == .Debug) {
            std.debug.print("[components.selectRow] '{s}' -> {d}\n", .{ label, selected.* });
        }
    }

    row.deinit();
}

/// 32px square icon button.  Hover: bg_elevated; active: bg_elevated +
/// 2px accent_primary border.  Returns true on click.  Tooltip uses
/// `dvui.tooltip` via the local `tip` helper.
pub fn iconButton(
    src: std.builtin.SourceLocation,
    icon: []const u8,
    tooltip: []const u8,
    active: bool,
) bool {
    var wd: dvui.WidgetData = undefined;
    const clicked = dvui.buttonIcon(src, "iconButton", icon, .{}, .{}, .{
        .data_out = &wd,
        .color_fill = if (active) tk.bg_elevated() else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = if (active) tk.accent_primary() else tk.text_secondary(),
        .color_border = if (active) tk.accent_primary() else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border = if (active) dvui.Rect.all(2) else dvui.Rect.all(0),
        .corner_radius = tk.rad_sm,
        .min_size_content = .{ .w = 32, .h = 32 },
        .max_size_content = .{ .w = 32, .h = 32 },
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
    });
    if (tooltip.len > 0) {
        tip(src, wd, tooltip);
    }
    return clicked;
}

/// Small status pill — info / success / warn / err.
pub fn statusPill(label: []const u8, kind: enum { info, success, warn, err }) void {
    const fg = switch (kind) {
        .info    => tk.accent_dim(),
        .success => tk.semantic_success(),
        .warn    => tk.semantic_warn(),
        .err     => tk.semantic_error(),
    };
    // Render with a faint translucent background of the same hue.
    const bg = dvui.Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 40 };

    var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = bg,
        .color_border = fg,
        .border = dvui.Rect.all(1),
        .corner_radius = tk.rad_pill,
        .padding = .{ .x = tk.sp_sm, .y = tk.sp_xs, .w = tk.sp_sm, .h = tk.sp_xs },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
    });
    defer pill.deinit();

    _ = dvui.label(@src(), "{s}", .{label}, .{
        .color_text = fg,
        .font = fontAt(tk.fs_small),
    });
}

/// Centered empty-state placeholder.  Large icon + title + hint.
pub fn emptyState(icon: []const u8, title: []const u8, hint: []const u8) void {
    var container = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(tk.sp_xl),
    });
    defer container.deinit();

    // Top spacer for vertical centering.
    { var s = dvui.box(@src(), .{}, .{ .expand = .vertical }); s.deinit(); }

    if (icon.len > 0) {
        dvui.icon(@src(), "empty-state", icon, .{}, .{
            .color_text = tk.text_tertiary(),
            .min_size_content = .{ .w = 48, .h = 48 },
            .max_size_content = .{ .w = 48, .h = 48 },
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = tk.sp_md },
        });
    }
    _ = dvui.label(@src(), "{s}", .{title}, .{
        .color_text = tk.text_secondary(),
        .font = fontAt(tk.fs_title),
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = tk.sp_xs },
    });
    if (hint.len > 0) {
        _ = dvui.label(@src(), "{s}", .{hint}, .{
            .color_text = tk.text_tertiary(),
            .font = fontAt(tk.fs_body),
            .gravity_x = 0.5,
        });
    }

    // Bottom spacer for vertical centering.
    { var s = dvui.box(@src(), .{}, .{ .expand = .vertical }); s.deinit(); }
}

/// Full-width search input with magnifier prefix and placeholder text.
/// Returns true when the value changed this frame.  `len` is kept in
/// sync with `std.mem.indexOfScalar(buf, 0)` so the caller can read
/// `buf[0..len.*]` for the live value.
pub fn searchInput(
    src: std.builtin.SourceLocation,
    buf: []u8,
    len: *usize,
    placeholder: []const u8,
) bool {
    // Track focus to drive the focus-state border / background swap.
    var has_focus = false;

    var shell = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = if (has_focus) tk.bg_hover() else tk.bg_elevated(),
        .color_border = if (has_focus) tk.accent_primary() else tk.border_subtle(),
        .border = dvui.Rect.all(1),
        .corner_radius = tk.rad_md,
        .padding = .{ .x = tk.sp_md, .y = tk.sp_xs, .w = tk.sp_md, .h = tk.sp_xs },
        .min_size_content = .{ .w = 0, .h = 32 },
    });
    defer shell.deinit();

    // Magnifier prefix.
    dvui.icon(@src(), "search", icons.tvg.lucide.@"search", .{}, .{
        .color_text = tk.text_tertiary(),
        .min_size_content = .{ .w = 16, .h = 16 },
        .max_size_content = .{ .w = 16, .h = 16 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = tk.sp_sm, .h = 0 },
    });

    // Text entry stripped of its own background — the shell box owns it.
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = buf },
        .placeholder = placeholder,
    }, .{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = tk.text_primary(),
        .color_border = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border = dvui.Rect.all(0),
        .background = false,
        .min_size_content = .{ .w = 0, .h = 24 },
        .padding = dvui.Rect.all(0),
    });

    const changed = te.text_changed;
    if (dvui.focusedWidgetIdInCurrentSubwindow()) |fid| {
        has_focus = te.data().id == fid;
    }

    // Keep `len.*` honest so callers don't need a separate scan.
    const text_slice = te.getText();
    len.* = text_slice.len;

    te.deinit();

    if (changed and builtin.mode == .Debug) {
        std.debug.print("[components.searchInput] changed len={d}\n", .{len.*});
    }

    return changed;
}
