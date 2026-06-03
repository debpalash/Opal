const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");
const icons = @import("icons");

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
    {
        var c1 = components.card(@src()); _ = dvui.label(@src(), "Card one", .{}, .{ .color_text = theme.colors.text_primary }); c1.deinit();
        var c2 = components.card(@src()); _ = dvui.label(@src(), "Card two", .{}, .{ .color_text = theme.colors.text_primary }); c2.deinit();
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = dvui.Rect.all(theme.spacing.sm) });
        defer row.deinit();
        components.badge("Info", .info);
        components.badge("OK", .success);
        components.badge("Warn", .warn);
        components.badge("Err", .err);
        components.statusPill("Legacy", .info);
    }
    {
        const G = struct {
            var a: bool = false;
            var b: bool = true;
        };
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .margin = dvui.Rect.all(theme.spacing.sm) });
        defer col.deinit();
        _ = components.checkbox(@src(), "Enable A", &G.a);
        _ = components.checkbox(@src(), "Enable B", &G.b);
    }
    {
        const G = struct {
            var sel: usize = 0;
            const opts = [_][]const u8{ "Low", "Medium", "High" };
        };
        _ = components.radioGroup(@src(), &G.opts, &G.sel);
    }
    {
        const G = struct { var vol: f32 = 0.4; var bright: f32 = 0.7; };
        _ = components.slider(@src(), "Volume", &G.vol, 0.0, 1.0);
        _ = components.slider(@src(), "Brightness", &G.bright, 0.0, 1.0);
        components.ProgressBar(@src(), 0.33, "Download", 0);
    }
    {
        const names = [_][]const u8{ "First", "Second", "Third" };
        for (names, 0..) |nm, i| {
            _ = components.listItem(@src(), i, icons.tvg.lucide.@"file", nm, "›");
        }
    }
    { components.spinner(@src()); }
    // Primitives are appended here by later tasks.

    if (!printed_marker) {
        printed_marker = true;
        std.debug.print("ZZGALLERY: rendered\n", .{});
    }
}
