//! Page-shell — the new website-like navigation root (P0 of the redesign).
//!
//! Renders a persistent top nav (brand · back/fwd · nav links · omnibox ·
//! actions) above a content region that swaps full pages by route. Driven by
//! `state.app.router` (see core/router.zig). Gated by `state.app.page_shell_enabled`
//! so the legacy header+grid+drawer layout stays the default until parity.
//!
//! Rules: SVG (lucide TVG) icons only — never emojis.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const components = @import("components.zig");
const state = @import("../core/state.zig");
const router = @import("../core/router.zig");
const Route = router.Route;

const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

/// Frame entry — called from appFrame when page_shell_enabled.
pub fn render() !void {
    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_app,
    });
    defer root.deinit();

    renderTopNav();

    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_deep,
    });
    defer content.deinit();

    try renderPage(state.app.router.current);
}

// ── Top navigation ──

fn renderTopNav() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 48 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
    });
    defer bar.deinit();

    // Brand
    dvui.icon(@src(), "brand", icons.tvg.lucide.zap, .{}, .{
        .color_text = theme.colors.accent_primary,
        .min_size_content = .{ .w = 18, .h = 18 },
        .gravity_y = 0.5,
    });
    _ = dvui.label(@src(), "Opal", .{}, .{
        .color_text = theme.colors.text_primary,
        .gravity_y = 0.5,
        .margin = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.md, .h = 0 },
    });

    // Back / forward
    if (components.iconButton(@src(), icons.tvg.lucide.@"chevron-left", "Back", state.app.router.canGoBack())) {
        state.app.router.goBack();
    }
    if (components.iconButton(@src(), icons.tvg.lucide.@"chevron-right", "Forward", state.app.router.canGoForward())) {
        state.app.router.goForward();
    }

    // Primary nav links
    navLink(.home, "Home", icons.tvg.lucide.house, 1);
    navLink(.search, "Search", icons.tvg.lucide.search, 2);
    navLink(.browse, "Browse", icons.tvg.lucide.compass, 3);
    navLink(.library, "Library", icons.tvg.lucide.library, 4);
    navLink(.assistant, "Assistant", icons.tvg.lucide.@"message-square-text", 5);

    // Omnibox (P0 placeholder — clicking jumps to Search; real input lands in P2)
    omnibox();

    // Right-side actions
    if (components.iconButton(@src(), icons.tvg.lucide.play, "Now playing", state.app.router.current == .player)) {
        state.app.router.navigate(.player);
    }
    if (components.iconButton(@src(), icons.tvg.lucide.settings, "Settings", state.app.router.current == .settings)) {
        state.app.router.navigate(.settings);
    }
}

/// A top-nav link: whole-row click target, icon + label, accent when active.
fn navLink(r: Route, label: []const u8, icon: []const u8, id_extra: usize) void {
    const active = state.app.router.current == r;
    var hovered: bool = false;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = 0, .h = 32 },
        .background = true,
        .color_fill = if (active) theme.colors.bg_elevated else if (hovered) theme.colors.bg_hover else transparent,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        .gravity_y = 0.5,
    });
    defer row.deinit();

    if (dvui.clicked(row.data(), .{ .hovered = &hovered })) {
        state.app.router.navigate(r);
    }
    row.drawBackground();

    const fg = if (active) theme.colors.accent_primary else theme.colors.text_secondary;
    dvui.icon(@src(), label, icon, .{}, .{
        .id_extra = id_extra,
        .color_text = fg,
        .min_size_content = .{ .w = 16, .h = 16 },
        .max_size_content = .{ .w = 16, .h = 16 },
        .gravity_y = 0.5,
    });
    _ = dvui.label(@src(), "  {s}", .{label}, .{
        .id_extra = id_extra,
        .color_text = fg,
        .gravity_y = 0.5,
    });
}

/// Omnibox placeholder. Grows to fill the bar; clicking routes to Search.
/// P2 replaces this with a live text input wired through `ai_intent`.
fn omnibox() void {
    var wrap = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = 0 },
        .gravity_y = 0.5,
    });
    defer wrap.deinit();

    var hovered: bool = false;
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 30 },
        .max_size_content = .{ .w = 560, .h = 30 },
        .background = true,
        .color_fill = if (hovered) theme.colors.bg_hover else theme.colors.bg_input,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
        .gravity_y = 0.5,
    });
    defer box.deinit();

    if (dvui.clicked(box.data(), .{ .hovered = &hovered })) {
        state.app.router.navigate(.search);
    }
    box.drawBackground();

    dvui.icon(@src(), "omni", icons.tvg.lucide.search, .{}, .{
        .color_text = theme.colors.text_tertiary,
        .min_size_content = .{ .w = 16, .h = 16 },
        .gravity_y = 0.5,
    });
    _ = dvui.label(@src(), "  Ask, search, or paste a link…", .{}, .{
        .color_text = theme.colors.text_tertiary,
        .gravity_y = 0.5,
    });
    {
        var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        sp.deinit();
    }
    _ = components.iconButton(@src(), icons.tvg.lucide.mic, "Voice", false);
}

// ── Page dispatch ──

fn renderPage(r: Route) !void {
    switch (r) {
        // Real pages already implemented elsewhere:
        .player => try @import("grid.zig").renderGrid(),
        .settings => @import("settings.zig").renderSettingsContent(),
        // P3 ports the remaining bodies from the drawer renderers.
        .home => placeholder("Home", icons.tvg.lucide.house, "Continue watching and recommendations will live here."),
        .search => placeholder("Search", icons.tvg.lucide.search, "Universal search across TMDB, torrents, YouTube and Jellyfin."),
        .browse => placeholder("Browse", icons.tvg.lucide.compass, "TMDB, YouTube, Anime, Comics and RSS sources."),
        .library => placeholder("Library", icons.tvg.lucide.library, "Queue, History, Downloads and Jellyfin."),
        .assistant => placeholder("Assistant", icons.tvg.lucide.@"message-square-text", "Chat with Opal to find and play anything."),
        .system => placeholder("System", icons.tvg.lucide.server, "Plugins and logs."),
    }
}

/// Centered empty-state for pages not yet ported. Icon + title + one line.
fn placeholder(title: []const u8, icon: []const u8, line: []const u8) void {
    var center = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    defer center.deinit();

    dvui.icon(@src(), title, icon, .{}, .{
        .color_text = theme.colors.text_tertiary,
        .min_size_content = .{ .w = 40, .h = 40 },
        .gravity_x = 0.5,
    });
    var t = dvui.themeGet().font_body;
    t.size = theme.font_size.title;
    _ = dvui.label(@src(), "{s}", .{title}, .{
        .color_text = theme.colors.text_primary,
        .font = t,
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.xs },
    });
    _ = dvui.label(@src(), "{s}", .{line}, .{
        .color_text = theme.colors.text_tertiary,
        .gravity_x = 0.5,
    });
}
