//! First-run welcome: one clear path into the app, with optional source
//! installation. Keys and AI setup belong in Settings, not a blocking wizard.
//! Existing installs are grandfathered by config.load(); Settings > About can
//! reopen this screen with replay().

const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const source_config = @import("../core/source_config.zig");
const plugin_repo = @import("../services/plugin_repo.zig");
const theme = @import("theme.zig");

var replay_active: bool = false;

pub fn replay() void {
    replay_active = true;
    state.app.onboarded = false;
    state.markConfigDirty();
}

pub fn render() void {
    if (!state.app.config_loaded.load(.acquire) or state.app.is_headless) return;
    if (!replay_active and state.app.onboarded) return;

    const has_sources = source_config.anyInstalled();
    const dialog_size = theme.fitWindowSize(.{ .w = 400, .h = if (has_sources) 170 else 300 }, .{ .w = 240, .h = if (has_sources) 150 else 190 });
    var open = true;
    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .center_on = dvui.windowRect(),
        .window_avoid = .none,
        .open_flag = &open,
        .resize = .none,
    }, .{
        .min_size_content = dialog_size,
        .max_size_content = dvui.Options.MaxSize.size(dialog_size),
        .color_fill = theme.colors.bg_surface,
        .border = dvui.Rect.all(1),
        .color_border = theme.colors.border_subtle,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
    });
    defer win.deinit();

    // The window manager may resize after the first layout, and installing
    // sources removes the optional card. Keep the dialog centered and sized
    // to its current contents instead of retaining stale floating geometry.
    win.autoPosition();
    win.autoSize();

    win.dragAreaSet(dvui.windowHeader("Welcome to Opal", "", &open));
    if (!open) finish();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = dvui.Rect.all(theme.spacing.lg),
    });
    defer body.deinit();

    // Reserve room for both actions on short windows; only the explanatory
    // content scrolls. A fresh install can still reach Browse without setup.
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
        .expand = .both,
        .min_size_content = .{ .w = 0, .h = 0 },
        .max_size_content = dvui.Options.MaxSize.height(@max(70, dialog_size.h - 125)),
        .background = false,
    });
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });

    description(1, "Play local files or browse movies & TV. No account needed.");
    if (!has_sources) {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .padding = dvui.Rect.all(theme.spacing.md),
            .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = 0 },
        });
        defer card.deinit();
        _ = dvui.label(@src(), "Add search sources (optional)", .{}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading,
        });
        description(2, "Find more streams and episodes.");
        if (dvui.button(@src(), "Install starter sources", .{}, .{
            .color_fill = theme.colors.bg_surface,
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(1),
            .color_border = theme.colors.border_subtle,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = dvui.Rect.all(theme.spacing.sm),
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
        })) {
            const n = plugin_repo.installStarterPack();
            var buf: [64]u8 = undefined;
            state.showToast(if (n == 0) "No new sources installed — check Logs" else
                std.fmt.bufPrint(&buf, "{d} sources installed", .{n}) catch "Sources installed");
        }
    }
    content.deinit();
    scroll.deinit();

    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
    });
    defer actions.deinit();
    if (dvui.button(@src(), "Browse movies & TV", .{}, .{
        .expand = .horizontal,
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.text_on_accent,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = dvui.Rect.all(theme.spacing.sm),
        .margin = dvui.Rect.all(0),
    })) {
        state.app.browse_source = .TMDB;
        state.app.router.navigate(.browse);
        finish();
    }
    if (dvui.button(@src(), "Home", .{}, .{
        .color_fill = theme.colors.bg_surface,
        .color_text = theme.colors.text_secondary,
        .border = dvui.Rect.all(0),
        .padding = dvui.Rect.all(theme.spacing.sm),
        .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
    })) {
        state.app.router.navigate(.home);
        finish();
    }
}

fn description(id: usize, text: []const u8) void {
    var tl = dvui.textLayout(@src(), .{}, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = false,
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    });
    tl.addText(text, .{ .color_text = theme.colors.text_secondary });
    tl.deinit();
}

fn finish() void {
    replay_active = false;
    state.app.onboarded = true;
    state.markConfigDirty();
}
