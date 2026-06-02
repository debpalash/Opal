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
    tipId(src, wd, text, 0);
}

/// Same as `tip`, but takes an explicit `id_extra` so callers that emit many
/// tooltips from one source location under one parent (e.g. the drawer rail's
/// tab/bottom-icon helpers) can give each tooltip a distinct, collision-free
/// id. Without this they all hash to the same FloatingTooltip id and dvui logs
/// "duplicate widget id" every frame a tooltip is shown.
pub fn tipId(src: std.builtin.SourceLocation, wd: dvui.WidgetData, text: []const u8, id_extra: usize) void {
    // FloatingTooltipWidget derives its widget id from the source location
    // alone — it builds its WidgetData from a fixed Options and ignores any
    // caller-supplied .id_extra. So a tooltip that reuses its owner widget's
    // @src() (as iconButton() does: buttonIcon(src) then tip(src)) hashes to
    // the *same* id as that widget under the same parent, and dvui logs
    // "duplicate widget id ... FloatingTooltip" on every frame the tooltip is
    // shown. Offset the column to give the tooltip a distinct, collision-free
    // id without disturbing the owner widget's id; fold in id_extra so repeated
    // calls from one source location stay distinct.
    var tip_src = src;
    tip_src.column +%= 0x1000 +% @as(u32, @truncate(id_extra));
    dvui.tooltip(tip_src, .{ .active_rect = wd.borderRectScale().r }, "{s}", .{text}, .{
        .color_fill = tk.bg_elevated(),
        .color_text = tk.text_primary(),
        .color_border = tk.border_subtle(),
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(6),
        .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
    });
}

// ══════════════════════════════════════════════════════════════════════
// Legacy primitives (preserved — live callers only)
// ══════════════════════════════════════════════════════════════════════

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
//
// Like divider() below, every sectionHeader() call shares THIS function's
// @src(), so two headers under the same parent hash to the same widget id and
// dvui flags the collision (red box). A monotonic sequence number as id_extra
// keeps each call's box + label unique within a frame.
var sectionheader_seq: usize = 0;
pub fn sectionHeader(label: []const u8) void {
    sectionheader_seq +%= 1;
    var pad_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = sectionheader_seq,
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = tk.sp_lg, .w = 0, .h = tk.sp_sm },
    });
    defer pad_box.deinit();

    var upper_buf: [96]u8 = undefined;
    const upper = upperBuf(&upper_buf, label);

    _ = dvui.label(@src(), "{s}", .{upper}, .{
        .id_extra = sectionheader_seq,
        .color_text = tk.text_tertiary(),
        .font = fontAt(tk.fs_small),
    });
}

/// 1px horizontal rule. Color: border_subtle.
/// Vertical margin: spacing.sm above and below.
// Every divider() call shares THIS function's @src(), so two dividers under the
// same parent would hash to the same widget id and dvui flags the collision by
// drawing a red box (the "empty red boxes" seen in Settings). A monotonic
// sequence number as id_extra keeps each call's id unique within a frame.
var divider_seq: usize = 0;
pub fn divider() void {
    divider_seq +%= 1;
    var d = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = divider_seq,
        .expand = .horizontal,
        .background = true,
        .color_fill = tk.border_subtle(),
        .min_size_content = .{ .w = 0, .h = 1 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = 1 },
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
            // Fill alone signals state — accent when on, bg_elevated when off.
            // No border (calm: avoid the extra hairline ring around the pill).
            .color_fill = if (value.*) tk.accent_primary() else tk.bg_elevated(),
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
            // Calm: bg_elevated fill + rad_md alone delimit the control — no border.
            .color_fill = tk.bg_elevated(),
            .color_text = tk.text_primary(),
            .corner_radius = tk.rad_md,
            .padding = .{ .x = tk.sp_md, .y = tk.sp_xs, .w = tk.sp_md, .h = tk.sp_xs },
        });
        if (dd_changed and builtin.mode == .Debug) {
            std.debug.print("[components.selectRow] '{s}' -> {d}\n", .{ label, selected.* });
        }
    }

    row.deinit();
}

/// Minimal segmented control — replaces saturated filled-pill single-selects.
/// A single bg_surface container (rad_sm, no border) holds N segments laid out
/// horizontally. The active segment carries a quiet bg_elevated fill +
/// text_primary; inactive segments are transparent + text_secondary. No
/// per-segment border, no accent fill (calm). Returns the index the user
/// clicked this frame, or null when nothing was clicked.
pub fn segment(
    src: std.builtin.SourceLocation,
    options: []const []const u8,
    selected: usize,
) ?usize {
    var clicked_index: ?usize = null;

    var bar = dvui.box(src, .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = tk.bg_surface(),
        .corner_radius = tk.rad_sm,
        .padding = dvui.Rect.all(tk.sp_xs),
    });
    defer bar.deinit();

    for (options, 0..) |opt, i| {
        const is_active = i == selected;
        var hovered: bool = false;

        var seg = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .background = true,
            // Active = subtle bg_elevated fill; inactive = transparent.
            // No per-segment border (calm).
            .color_fill = if (is_active) tk.bg_elevated() else theme.transparent,
            .corner_radius = tk.rad_sm,
            .padding = .{ .x = tk.sp_md, .y = tk.sp_xs, .w = tk.sp_md, .h = tk.sp_xs },
            .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
        });

        if (dvui.clicked(seg.data(), .{ .hovered = &hovered })) {
            clicked_index = i;
        }
        seg.drawBackground();

        _ = dvui.label(@src(), "{s}", .{opt}, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .color_text = if (is_active) tk.text_primary() else tk.text_secondary(),
            .font = fontAt(tk.fs_small),
        });

        seg.deinit();
    }

    return clicked_index;
}

/// 32px square icon button.  Active: subtle bg_elevated fill + accent_primary
/// glyph, no border.  Inactive: transparent fill + text_secondary glyph, no
/// border.  Returns true on click.  Tooltip uses `dvui.tooltip` via the local
/// `tip` helper.
pub fn iconButton(
    src: std.builtin.SourceLocation,
    icon: []const u8,
    tooltip: []const u8,
    active: bool,
) bool {
    var wd: dvui.WidgetData = undefined;
    // Calm: active state is carried by the glyph color (accent) over a quiet
    // bg_elevated fill — no accent border ring. Inactive is fully transparent.
    const clicked = dvui.buttonIcon(src, "iconButton", icon, .{}, .{}, .{
        .data_out = &wd,
        .color_fill = if (active) tk.bg_elevated() else theme.transparent,
        .color_text = if (active) tk.accent_primary() else tk.text_secondary(),
        .border = dvui.Rect.all(0),
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

pub const BadgeKind = enum { info, success, warn, err };

/// Small status label — colored text only (calm: no box/border/fill).
/// `.info` reads as a neutral secondary label; the semantic kinds use their
/// muted colors so the status reads without shouting. Horizontal padding
/// preserved.
// Every badge() shares this function's @src(); a monotonic id_extra (mirroring
// the divider_seq/sectionheader_seq pattern) keeps multiple badges under one
// parent from hashing to the same widget id.
var badge_seq: usize = 0;
pub fn badge(label: []const u8, kind: BadgeKind) void {
    badge_seq +%= 1;
    const fg = switch (kind) {
        .info    => tk.text_secondary(),
        .success => tk.semantic_success(),
        .warn    => tk.semantic_warn(),
        .err     => tk.semantic_error(),
    };
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = badge_seq,
        .padding = .{ .x = tk.sp_sm, .y = tk.sp_xs, .w = tk.sp_sm, .h = tk.sp_xs },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
    });
    defer pill.deinit();
    _ = dvui.label(@src(), "{s}", .{label}, .{ .id_extra = badge_seq, .color_text = fg, .font = fontAt(tk.fs_small) });
}

/// Legacy alias — delegates to `badge`. Kept so existing callers compile.
pub fn statusPill(label: []const u8, kind: enum { info, success, warn, err }) void {
    badge(label, switch (kind) { .info => .info, .success => .success, .warn => .warn, .err => .err });
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
        .color_fill = theme.transparent,
        .color_text = tk.text_primary(),
        .color_border = theme.transparent,
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

    return changed;
}

pub const ButtonKind = enum { primary, secondary, ghost, danger };

/// Flat calm button. `primary` = accent fill; `secondary` = bg_elevated;
/// `ghost` = transparent; `danger` = error-tinted. Returns true on click.
pub fn button(
    src: std.builtin.SourceLocation,
    label: []const u8,
    kind: ButtonKind,
) bool {
    const fill = switch (kind) {
        .primary   => tk.accent_primary(),
        .secondary => tk.bg_elevated(),
        .ghost     => theme.transparent,
        .danger    => tk.semantic_error(),
    };
    const fg = switch (kind) {
        .primary, .danger => tk.text_on_accent(),
        .secondary        => tk.text_primary(),
        .ghost            => tk.text_secondary(),
    };
    return dvui.button(src, label, .{}, .{
        .color_fill = fill,
        .color_text = fg,
        .border = dvui.Rect.all(0),
        .corner_radius = tk.rad_md,
        .padding = .{ .x = tk.sp_lg, .y = tk.sp_sm, .w = tk.sp_lg, .h = tk.sp_sm },
    });
}

pub const Card = struct {
    box: *dvui.BoxWidget,
    pub fn deinit(self: *Card) void {
        self.box.deinit();
    }
};

/// Calm-flat surface: bg_surface + 1px border_subtle + md padding. No shadow.
/// Usage: `var c = components.card(@src()); defer c.deinit();`
pub fn card(src: std.builtin.SourceLocation) Card {
    const b = dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = tk.bg_surface(),
        .color_border = tk.border_subtle(),
        .border = dvui.Rect.all(1),
        .corner_radius = tk.rad_md,
        .padding = dvui.Rect.all(tk.sp_md),
        .margin = .{ .x = 0, .y = tk.sp_xs, .w = 0, .h = tk.sp_xs },
    });
    return .{ .box = b };
}

/// Square checkbox + label on one clickable row. Returns true on the frame
/// the value toggles.
pub fn checkbox(
    src: std.builtin.SourceLocation,
    label: []const u8,
    value: *bool,
) bool {
    var changed = false;
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .padding = .{ .x = tk.sp_sm, .y = tk.sp_xs, .w = tk.sp_sm, .h = tk.sp_xs },
    });
    if (dvui.clicked(row.data(), .{})) {
        value.* = !value.*;
        changed = true;
    }
    row.drawBackground();

    var bx = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 0.5,
        .background = true,
        .color_fill = if (value.*) tk.accent_primary() else theme.transparent,
        .color_border = if (value.*) tk.accent_primary() else tk.border_strong(),
        .border = dvui.Rect.all(1),
        .corner_radius = tk.rad_sm,
        .min_size_content = .{ .w = 16, .h = 16 },
        .max_size_content = .{ .w = 16, .h = 16 },
        .margin = .{ .x = 0, .y = 0, .w = tk.sp_sm, .h = 0 },
    });
    if (value.*) {
        dvui.icon(@src(), "check", icons.tvg.lucide.@"check", .{}, .{
            .color_text = tk.text_on_accent(),
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
    }
    bx.deinit();

    _ = dvui.label(@src(), "{s}", .{label}, .{
        .gravity_y = 0.5,
        .color_text = tk.text_primary(),
        .font = fontAt(tk.fs_body),
    });
    row.deinit();
    return changed;
}

/// Vertical radio list. `selected` is the chosen index. Returns true when the
/// selection changes this frame. Each option row is id_extra-disambiguated.
pub fn radioGroup(
    src: std.builtin.SourceLocation,
    options: []const []const u8,
    selected: *usize,
) bool {
    var changed = false;
    if (selected.* >= options.len and options.len > 0) selected.* = 0;
    var col = dvui.box(src, .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer col.deinit();

    for (options, 0..) |opt, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .padding = .{ .x = tk.sp_sm, .y = tk.sp_xs, .w = tk.sp_sm, .h = tk.sp_xs },
        });
        if (dvui.clicked(row.data(), .{})) {
            selected.* = i;
            changed = true;
        }
        row.drawBackground();

        const on = i == selected.*;
        var dot = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .background = true,
            .color_fill = if (on) tk.accent_primary() else theme.transparent,
            .color_border = if (on) tk.accent_primary() else tk.border_strong(),
            .border = dvui.Rect.all(1),
            .corner_radius = tk.rad_pill,
            .min_size_content = .{ .w = 14, .h = 14 },
            .max_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = tk.sp_sm, .h = 0 },
        });
        dot.deinit();

        _ = dvui.label(@src(), "{s}", .{opt}, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .color_text = tk.text_primary(),
            .font = fontAt(tk.fs_body),
        });
        row.deinit();
    }
    return changed;
}
