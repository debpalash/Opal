const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");

/// Debug-only visual QA surface for the v2 primitives. Gated by the
/// `ZZ_GALLERY` env var so it never shows in normal use. Renders each
/// primitive at least twice under one parent — the exact scenario that
/// surfaces duplicate-widget-id collisions — and prints a one-shot marker
/// proving the render loop executed (used by the RENDER-SMOKE recipe).
var printed_marker: bool = false;

pub fn render() void {
    if (comptime builtin.mode != .Debug) return;
    const io_global = @import("../core/io_global.zig");
    if (io_global.getenv("ZZ_GALLERY") == null) return;
    dvui.refresh(null, @src(), null); // force continuous frames while open

    var win = dvui.floatingWindow(@src(), .{ .modal = false }, .{
        .min_size_content = .{ .w = 420, .h = 600 },
        .color_fill = theme.colors.bg_drawer,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(8),
    });
    defer win.deinit();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = theme.transparent });
    defer scroll.deinit();

    components.sectionHeader("Gallery");
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = dvui.Rect.all(theme.spacing.sm) });
        defer row.deinit();
        _ = components.button(@src(), "Primary", .primary);
        _ = components.button(@src(), "Secondary", .secondary);
        _ = components.button(@src(), "Ghost", .ghost);
        _ = components.button(@src(), "Danger", .danger);
    }
    // Primitives are appended here by later tasks.

    if (!printed_marker) {
        printed_marker = true;
        std.debug.print("ZZGALLERY: rendered\n", .{});
    }
}
