const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");

// Local shim — colors are runtime (read theme.colors per-frame); spacing/radii/fonts are comptime.

const tk = struct {
    // ── colors (runtime — read fresh each frame from active theme) ──
    pub inline fn bg_deep() dvui.Color {
        return theme.colors.bg_deep;
    }
    pub inline fn bg_surface() dvui.Color {
        return theme.colors.bg_surface;
    }
    pub inline fn bg_elevated() dvui.Color {
        return theme.colors.bg_elevated;
    }
    pub inline fn bg_hover() dvui.Color {
        return theme.colors.bg_hover;
    }
    pub inline fn bg_muted() dvui.Color {
        return theme.colors.bg_app;
    }
    pub inline fn text_primary() dvui.Color {
        return theme.colors.text_primary;
    }
    pub inline fn text_secondary() dvui.Color {
        return theme.colors.text_secondary;
    }
    pub inline fn text_tertiary() dvui.Color {
        return theme.colors.text_tertiary;
    }
    pub inline fn text_on_accent() dvui.Color {
        return theme.colors.text_on_accent;
    }
    pub inline fn accent_primary() dvui.Color {
        return theme.colors.accent;
    }
    pub inline fn accent_dim() dvui.Color {
        return theme.colors.accent_dim;
    }
    pub inline fn semantic_success() dvui.Color {
        return theme.colors.success;
    }
    pub inline fn semantic_warn() dvui.Color {
        return theme.colors.warning;
    }
    pub inline fn semantic_error() dvui.Color {
        return theme.colors.danger;
    }
    pub inline fn border_subtle() dvui.Color {
        return theme.colors.border_subtle;
    }
    pub inline fn border_strong() dvui.Color {
        return theme.colors.border_strong;
    }

    // ── spacing (pixels) ──
    pub const sp_xs: f32 = theme.spacing.xs;
    pub const sp_sm: f32 = theme.spacing.sm;
    pub const sp_md: f32 = theme.spacing.md;
    pub const sp_lg: f32 = theme.spacing.lg;
    pub const sp_xl: f32 = theme.spacing.xl;
    pub const sp_xxl: f32 = theme.spacing.xxl;

    // ── radii (dvui.Rect-typed for corner_radius slots) ──
    pub const rad_sm = dvui.Rect.all(theme.radius.sm);
    pub const rad_md = dvui.Rect.all(theme.radius.md);
    pub const rad_lg = dvui.Rect.all(theme.radius.lg);
    pub const rad_pill = dvui.Rect.all(theme.radius.pill);

    // ── font sizes ──
    pub const fs_micro: f32 = theme.font_size.micro;
    pub const fs_small: f32 = theme.font_size.small;
    pub const fs_body: f32 = theme.font_size.body;
    pub const fs_title: f32 = theme.font_size.title;
    pub const fs_display: f32 = theme.font_size.display;
};

fn fontAt(size: f32) dvui.Font {
    var f = dvui.themeGet().font_body;
    f.size = size;
    return f;
}

// ══════════════════════════════════════════════════════════════════════
// Per-frame reset
// ══════════════════════════════════════════════════════════════════════

/// Reset the call-order sequence counters used for id_extra by
/// sectionHeader/divider/statusPill. MUST be called once at the top of every
/// frame (main.zig appFrame). Without the reset the counters grow forever, so
/// every one of these widgets gets a brand-new dvui id each frame — and dvui
/// calls refresh() unconditionally for first-frame ids (WidgetData
/// minSizeSetAndRefresh), forcing a full-rate repaint whenever Settings, the
/// drawer, or any status pill was visible. That silently defeated the phase-1
/// gated render loop. With a per-frame reset the ids are stable across frames
/// (call order) while staying unique within a frame.
pub fn beginFrame() void {
    sectionheader_seq = 0;
    divider_seq = 0;
    statuspill_seq = 0;
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
        .corner_radius = tk.rad_md,
        .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
    });
}

// ══════════════════════════════════════════════════════════════════════
// Legacy primitives (preserved — live callers only)
// ══════════════════════════════════════════════════════════════════════

pub fn ProgressBar(src: std.builtin.SourceLocation, fraction: f32, label: []const u8, id_extra: usize) void {
    var container = dvui.box(src, .{ .dir = .vertical }, .{ .id_extra = id_extra, .expand = .horizontal, .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 } });
    defer container.deinit();

    if (label.len > 0) {
        _ = dvui.label(@src(), "{s}", .{label}, .{ .id_extra = id_extra, .color_text = theme.colors.text_secondary });
    }

    // Read-only display. This was a dvui.slider, which captured drags and
    // showed press affordances on a value the user can't actually edit —
    // dvui.progress is the passive equivalent.
    dvui.progress(@src(), .{ .percent = std.math.clamp(fraction, 0.0, 1.0), .color = theme.colors.accent }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .{ .w = 10, .h = 8 },
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = tk.rad_sm,
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
        .margin = .{ .x = 0, .y = tk.sp_md, .w = 0, .h = tk.sp_xs },
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
/// Whole row clickable; hover state lifts the background; the row takes a tab
/// stop so keyboard users can reach and flip it (Enter/Space).
/// Toggle: pill, accent_primary when on, bg_elevated when off, with a knob
/// that slides between the ends on theme.motion.fast.
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
        .color_fill = tk.bg_surface(),
        .corner_radius = tk.rad_sm,
        .padding = .{ .x = tk.sp_md, .y = tk.sp_sm, .w = tk.sp_md, .h = tk.sp_sm },
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
    });

    // Keyboard access: give the row a tab stop and flip on Enter/Space.
    const rid = row.data().id;
    dvui.tabIndexSet(rid, null);
    const row_focused = dvui.focusedWidgetId() == rid;
    if (row_focused) {
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if (e.evt == .key and e.evt.key.action == .down and e.evt.key.matchBind("activate")) {
                e.handle(@src(), row.data());
                value.* = !value.*;
            }
        }
    }

    // Toggle on click anywhere in the row.
    if (dvui.clicked(row.data(), .{ .hovered = &hovered })) {
        value.* = !value.*;
        if (builtin.mode == .Debug) {
            std.debug.print("[components.toggleRow] '{s}' -> {}\n", .{ label, value.* });
        }
    }
    // Hover lift. dvui.box() draws the background at creation, BEFORE hover is
    // known (Options.color_fill_hover is button-only — plain boxes never read
    // it), so the old `if (hovered)` ternary at init could never render. Mutate
    // the stored options now that hover IS known and repaint over the base fill.
    if (hovered) row.data().options.color_fill = tk.bg_hover();
    row.drawBackground();
    if (row_focused) row.data().focusBorder();

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
    {
        var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        spacer.deinit();
    }

    // Right: pill toggle. The knob's position (and the pill's fill) animate
    // between the two ends over theme.motion.fast; dvui keyed animations force
    // repaints while running, so the slide plays out even under the gated
    // frame loop.
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

        // Kick a slide animation whenever the value changed since last frame;
        // if a slide is still in flight, start from its current position.
        const pid = pill.data().id;
        const target: f32 = if (value.*) 1.0 else 0.0;
        const prev_target = dvui.dataGet(null, pid, "_on", f32) orelse target;
        if (prev_target != target) {
            const from = if (dvui.animationGet(pid, "knob")) |a| std.math.clamp(a.value(), 0.0, 1.0) else prev_target;
            dvui.animation(pid, "knob", .{
                .start_val = from,
                .end_val = target,
                .end_time = theme.motion.fast,
                .easing = theme.motion.move,
            });
        }
        dvui.dataSet(null, pid, "_on", target);
        const frac: f32 = if (dvui.animationGet(pid, "knob")) |a| std.math.clamp(a.value(), 0.0, 1.0) else target;

        // Crossfade the pill fill along the same curve (overdraws the baked
        // end-state fill from init — children render after, so this is safe).
        pill.data().options.color_fill = tk.bg_elevated().lerp(tk.accent_primary(), frac);
        pill.drawBackground();

        var knob_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .background = true,
            .color_fill = if (frac > 0.5) tk.text_on_accent() else tk.text_primary(),
            .corner_radius = tk.rad_pill,
            .min_size_content = .{ .w = knob, .h = knob },
            .max_size_content = .{ .w = knob, .h = knob },
            .gravity_x = frac,
            .gravity_y = 0.5,
        });
        knob_box.deinit();
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

    // Flexbox so many-option ramps (UI Scale, Theme) wrap to a second row on
    // narrow panes instead of clipping the last options off the edge.
    var bar = dvui.flexbox(src, .{ .justify_content = .start }, .{
        .expand = .horizontal,
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
            .padding = .{ .x = tk.sp_sm, .y = tk.sp_xs, .w = tk.sp_sm, .h = tk.sp_xs },
            .margin = .{ .x = 1, .y = 1, .w = 1, .h = 1 },
        });

        // Keyboard: each segment takes a tab stop; Enter/Space selects it.
        const sid = seg.data().id;
        dvui.tabIndexSet(sid, null);
        const seg_focused = dvui.focusedWidgetId() == sid;
        if (seg_focused) {
            for (dvui.events()) |*e| {
                if (e.handled) continue;
                if (e.evt == .key and e.evt.key.action == .down and e.evt.key.matchBind("activate")) {
                    e.handle(@src(), seg.data());
                    clicked_index = i;
                }
            }
        }
        if (dvui.clicked(seg.data(), .{ .hovered = &hovered })) {
            clicked_index = i;
        }
        // Inactive segments get a hover fill so they read as clickable — the
        // background drawn at init couldn't know hover yet (see toggleRow).
        if (hovered and !is_active) seg.data().options.color_fill = tk.bg_hover();
        seg.drawBackground();
        if (seg_focused) seg.data().focusBorder();

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
    return iconButtonEx(src, icon, tooltip, active, true);
}

/// iconButton with a disabled state: a disabled button renders as a plain
/// dimmed glyph (same footprint — no hover fill, no hand cursor, no click) so
/// e.g. Back/Forward read as unavailable instead of silently ignoring clicks.
pub fn iconButtonEx(
    src: std.builtin.SourceLocation,
    icon: []const u8,
    tooltip: []const u8,
    active: bool,
    enabled: bool,
) bool {
    if (!enabled) {
        // Same geometry as the live button (ButtonWidget default margin 4 +
        // our padding 6 + 20px glyph) so layouts don't shift when state flips.
        dvui.icon(src, "iconButtonDisabled", icon, .{}, .{
            .color_text = tk.text_tertiary(),
            .margin = dvui.Rect.all(4),
            .padding = dvui.Rect.all(6),
            .min_size_content = theme.iconSize(.md),
            .gravity_y = 0.5,
        });
        return false;
    }
    var wd: dvui.WidgetData = undefined;
    // Calm: active state is carried by the glyph color (accent) over a quiet
    // bg_elevated fill — no accent border ring. Inactive is fully transparent.
    // Hover/press fills are explicit: dvui derives them by lightening
    // color_fill, and lighten(transparent) is still transparent — every
    // transparent-fill button in the app had ZERO pointer feedback.
    const clicked = dvui.buttonIcon(src, "iconButton", icon, .{}, .{}, .{
        .data_out = &wd,
        .color_fill = if (active) tk.bg_elevated() else theme.transparent,
        .color_fill_hover = tk.bg_hover(),
        .color_fill_press = tk.bg_elevated(),
        .color_text = if (active) tk.accent_primary() else tk.text_secondary(),
        .border = dvui.Rect.all(0),
        .corner_radius = tk.rad_sm,
        .min_size_content = theme.iconSize(.md),
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
    });
    if (tooltip.len > 0) {
        tip(src, wd, tooltip);
    }
    return clicked;
}

/// Small status label — info / success / warn / err.
/// Calm: colored TEXT only (no box, no border, no fill). `.info` reads as a
/// neutral secondary label; the semantic kinds use their muted colors so the
/// status reads without shouting. Horizontal padding preserved.
// Like divider()/sectionHeader(): every statusPill() shares this @src(), so
// two pills under the same parent (e.g. one per search result) collide on the
// same widget id (dvui draws red boxes + spams "duplicate widget id"). A
// monotonic sequence as id_extra keeps each call's box + label unique.
var statuspill_seq: usize = 0;
pub fn statusPill(label: []const u8, kind: enum { info, success, warn, err }) void {
    statuspill_seq +%= 1;
    const fg = switch (kind) {
        .info => tk.text_secondary(),
        .success => tk.semantic_success(),
        .warn => tk.semantic_warn(),
        .err => tk.semantic_error(),
    };

    var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = statuspill_seq,
        .padding = .{ .x = tk.sp_sm, .y = tk.sp_xs, .w = tk.sp_sm, .h = tk.sp_xs },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
    });
    defer pill.deinit();

    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = statuspill_seq,
        .color_text = fg,
        .font = fontAt(tk.fs_small),
    });
}

/// Centered empty-state placeholder.  Large icon + title + hint.
pub fn emptyState(icon: []const u8, title: []const u8, hint: []const u8) void {
    _ = emptyStateCta(icon, title, hint, "");
}

/// emptyState with an optional call-to-action button beneath the hint, so
/// empty screens offer a way forward instead of dead-ending ("No watch history
/// yet" → "Browse"). Returns true when the CTA was clicked; pass "" for no CTA.
pub fn emptyStateCta(icon: []const u8, title: []const u8, hint: []const u8, cta: []const u8) bool {
    var cta_clicked = false;
    var container = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(tk.sp_xl),
    });
    defer container.deinit();

    // Top spacer for vertical centering.
    {
        var s = dvui.box(@src(), .{}, .{ .expand = .vertical });
        s.deinit();
    }

    if (icon.len > 0) {
        dvui.icon(@src(), "empty-state", icon, .{}, .{
            .color_text = tk.text_tertiary(),
            .min_size_content = theme.iconSize(.hero),
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
    if (cta.len > 0) {
        cta_clicked = dvui.button(@src(), cta, .{}, .{
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = tk.sp_md, .w = 0, .h = 0 },
            .color_fill = tk.accent_primary(),
            .color_text = tk.text_on_accent(),
            .corner_radius = tk.rad_sm,
            .padding = .{ .x = tk.sp_lg, .y = tk.sp_sm, .w = tk.sp_lg, .h = tk.sp_sm },
        });
    }

    // Bottom spacer for vertical centering.
    {
        var s = dvui.box(@src(), .{}, .{ .expand = .vertical });
        s.deinit();
    }
    return cta_clicked;
}

/// Centered loading placeholder: a self-refreshing spinner + quiet label.
/// Use instead of a static hourglass emptyState — the spinner keeps its own
/// repaint chain alive, so loading progress stays visible under the gated
/// frame loop even when the mouse is still.
pub fn loadingState(label: []const u8) void {
    var container = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(tk.sp_xl),
    });
    defer container.deinit();

    {
        var s = dvui.box(@src(), .{}, .{ .expand = .vertical });
        s.deinit();
    }
    dvui.spinner(@src(), .{
        .color_text = tk.accent_primary(),
        .min_size_content = theme.iconSize(.xl),
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = tk.sp_md },
    });
    if (label.len > 0) {
        _ = dvui.label(@src(), "{s}", .{label}, .{
            .color_text = tk.text_secondary(),
            .font = fontAt(tk.fs_body),
            .gravity_x = 0.5,
        });
    }
    {
        var s = dvui.box(@src(), .{}, .{ .expand = .vertical });
        s.deinit();
    }
}

/// Two-step destructive button (immediate-mode confirm without a modal):
/// first click arms it — the label flips to "Click again to confirm" in the
/// danger color for 3 seconds — and only the confirming second click returns
/// true. A ghost/text button; pass a stable id_extra when emitting several
/// from one source location.
pub fn confirmDangerButton(src: std.builtin.SourceLocation, label: []const u8, id_extra: usize) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{}, .{
        .id_extra = id_extra,
        .color_fill = theme.transparent,
        .color_fill_hover = tk.bg_hover(),
        .color_fill_press = tk.bg_elevated(),
        .border = dvui.Rect.all(0),
        .corner_radius = tk.rad_sm,
        .padding = .{ .x = tk.sp_sm, .y = tk.sp_xs, .w = tk.sp_sm, .h = tk.sp_xs },
        .gravity_y = 0.5,
    });
    bw.processEvents();

    const id = bw.data().id;
    var armed = dvui.dataGet(null, id, "_armed", bool) orelse false;
    if (armed and dvui.timerDone(id)) armed = false; // auto-disarm after 3s

    bw.drawBackground();
    _ = dvui.labelNoFmt(@src(), if (armed) "Click again to confirm" else label, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .color_text = if (armed) tk.semantic_error() else tk.text_secondary(),
        .font = fontAt(tk.fs_small),
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    bw.drawFocus();
    const clicked = bw.clicked();
    bw.deinit();

    var confirmed = false;
    if (clicked) {
        if (armed) {
            armed = false;
            confirmed = true;
        } else {
            armed = true;
            dvui.timer(id, 3_000_000);
        }
    }
    dvui.dataSet(null, id, "_armed", armed);
    return confirmed;
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
    var shell = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = tk.bg_elevated(),
        .color_border = tk.border_subtle(),
        .border = dvui.Rect.all(1),
        .corner_radius = tk.rad_md,
        .padding = .{ .x = tk.sp_md, .y = tk.sp_xs, .w = tk.sp_md, .h = tk.sp_xs },
        .min_size_content = .{ .w = 0, .h = 32 },
    });
    defer shell.deinit();

    // Focus ring. The old code computed the focus colors BEFORE the text entry
    // existed (always false) and never redrew — dead code, so the field showed
    // no focus indication at all. Persist last frame's focus under the shell id
    // and repaint the shell with the accent border (one frame of lag is fine).
    const sid = shell.data().id;
    if (dvui.dataGet(null, sid, "_focus", bool) orelse false) {
        shell.data().options.color_fill = tk.bg_hover();
        shell.data().options.color_border = tk.accent_primary();
        shell.drawBackground();
    }

    // Magnifier prefix.
    dvui.icon(@src(), "search", icons.tvg.lucide.search, .{}, .{
        .color_text = tk.text_tertiary(),
        .min_size_content = theme.iconSize(.sm),
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
    var has_focus = false;
    if (dvui.focusedWidgetIdInCurrentSubwindow()) |fid| {
        has_focus = te.data().id == fid;
    }
    dvui.dataSet(null, sid, "_focus", has_focus);

    // Keep `len.*` honest so callers don't need a separate scan.
    const text_slice = te.getText();
    len.* = text_slice.len;

    te.deinit();

    return changed;
}
