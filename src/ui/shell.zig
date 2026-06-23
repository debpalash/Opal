//! Page-shell — the website-like navigation root (redesign P0–P4).
//!
//! Persistent top nav (brand · back/fwd · nav links · omnibox · actions) over
//! a content region that swaps full pages by route, plus a docked mini-player
//! so playback continues while browsing. Page bodies reuse the exact drawer
//! content renderers via `drawer.renderTabContent`. Driven by `state.app.router`.
//!
//! Rules: SVG (lucide TVG) icons only — never emojis.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const components = @import("components.zig");
const drawer = @import("drawer.zig");
const footer = @import("footer.zig");
const header = @import("header.zig");
const state = @import("../core/state.zig");
const router = @import("../core/router.zig");
const Route = router.Route;

const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

// Sub-navigation selections (in-page segments).
var browse_source: state.DrawerTab = .TMDB;
var library_tab: state.DrawerTab = .Queue;
var system_tab: state.DrawerTab = .Logs;

/// Frame entry — called from appFrame when page_shell_enabled.
pub fn render() !void {
    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_app,
    });
    defer root.deinit();

    // Responsive breakpoint (one-frame lag acceptable; 0 on first paint → wide).
    const w = root.data().rect.w;
    const compact = w > 1 and w < 760;

    renderTopNav(compact);

    {
        var content = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = theme.colors.bg_deep,
        });
        defer content.deinit();
        try renderPage(state.app.router.current);
    }

    // Docked mini-player — keeps transport visible while browsing other pages.
    if (state.app.router.current != .player and activeHasMedia()) {
        footer.renderGlobalBottomTray();
    }

    // Compact: bottom tab bar (mobile-style) below everything.
    if (compact) renderBottomTabs();
}

fn activeHasMedia() bool {
    if (state.app.active_player_idx >= state.app.players.items.len) return false;
    return state.app.players.items[state.app.active_player_idx].current_url_len > 0;
}

// ── Top navigation ──

fn renderTopNav(compact: bool) void {
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
    if (!compact) {
        _ = dvui.label(@src(), "Opal", .{}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.md, .h = 0 },
        });
    }

    // Back / forward
    if (components.iconButton(@src(), icons.tvg.lucide.@"chevron-left", "Back", state.app.router.canGoBack())) {
        state.app.router.goBack();
    }
    if (components.iconButton(@src(), icons.tvg.lucide.@"chevron-right", "Forward", state.app.router.canGoForward())) {
        state.app.router.goForward();
    }

    // Primary nav links — hidden in compact (bottom tab bar takes over).
    if (!compact) {
        navLink(.home, "Home", icons.tvg.lucide.house, 1);
        navLink(.search, "Search", icons.tvg.lucide.search, 2);
        navLink(.browse, "Browse", icons.tvg.lucide.compass, 3);
        navLink(.library, "Library", icons.tvg.lucide.library, 4);
        navLink(.assistant, "Assistant", icons.tvg.lucide.@"message-square-text", 5);
    }

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

/// Live omnibox: type to chat / search / paste-a-link. Routes through the same
/// handler the legacy header used (`header.submitInput`), then navigates.
fn omnibox() void {
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.magnet_buf },
        .placeholder = "Ask, search, or paste a link…",
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 120, .h = 30 },
        .max_size_content = .{ .w = 620, .h = 30 },
        .margin = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = 0 },
        .color_fill = theme.colors.bg_input,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .gravity_y = 0.5,
    });
    const entered = te.enter_pressed;
    te.deinit();

    if (entered) {
        const len = std.mem.indexOfScalar(u8, &state.app.magnet_buf, 0) orelse state.app.magnet_buf.len;
        const is_media = len > 0 and isMedia(state.app.magnet_buf[0..len]);
        header.submitInput(); // routes media→player, else→AI chat; clears buffer
        state.app.router.navigate(if (is_media) .player else .assistant);
    }
}

fn isMedia(text: []const u8) bool {
    const prefixes = [_][]const u8{ "magnet:", "http://", "https://", "file://", "/", "~/", "./", "ftp://", "rtmp://", "rtsp://" };
    for (prefixes) |p| if (std.mem.startsWith(u8, text, p)) return true;
    return false;
}

// ── Page dispatch ──

fn renderPage(r: Route) !void {
    switch (r) {
        .player => try @import("grid.zig").renderGrid(),
        .settings => drawer.renderTabContent(.Settings),
        .assistant => drawer.renderTabContent(.AI),
        .search => drawer.renderTabContent(.Search),
        .home => drawer.renderTabContent(.TMDB), // discover hub (trending/recs)
        .browse => {
            subTabs(&.{ .TMDB, .YouTube, .Anime, .Comics, .RSS }, &browse_source, 100);
            drawer.renderTabContent(browse_source);
        },
        .library => {
            subTabs(&.{ .Queue, .History, .Downloads, .Jellyfin }, &library_tab, 200);
            drawer.renderTabContent(library_tab);
        },
        .system => {
            subTabs(&.{ .Logs, .Plugins }, &system_tab, 300);
            drawer.renderTabContent(system_tab);
        },
    }
}

fn tabLabel(t: state.DrawerTab) []const u8 {
    return switch (t) {
        .Search => "Search",
        .Downloads => "Downloads",
        .TMDB => "Movies & TV",
        .YouTube => "YouTube",
        .Queue => "Queue",
        .Comics => "Comics",
        .Anime => "Anime",
        .History => "History",
        .RSS => "RSS",
        .Jellyfin => "Jellyfin",
        .Plugins => "Plugins",
        .Logs => "Logs",
        .Settings => "Settings",
        .AI => "Assistant",
    };
}

/// Horizontal segment of sub-tabs; updates `sel` on click. Wraps when narrow.
fn subTabs(tabs: []const state.DrawerTab, sel: *state.DrawerTab, id_extra: usize) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.sm, .w = theme.spacing.lg, .h = theme.spacing.xs },
    });
    defer bar.deinit();

    for (tabs, 0..) |t, i| {
        const active = sel.* == t;
        var hovered: bool = false;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id_extra + i + 1,
            .min_size_content = .{ .w = 0, .h = 28 },
            .background = true,
            .color_fill = if (active) theme.colors.bg_elevated else if (hovered) theme.colors.bg_hover else transparent,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
        defer row.deinit();
        if (dvui.clicked(row.data(), .{ .hovered = &hovered })) sel.* = t;
        row.drawBackground();
        _ = dvui.label(@src(), "{s}", .{tabLabel(t)}, .{
            .id_extra = id_extra + i + 1,
            .color_text = if (active) theme.colors.accent_primary else theme.colors.text_secondary,
            .gravity_y = 0.5,
        });
    }
}

// ── Compact bottom tab bar (mobile) ──

fn renderBottomTabs() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 52 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
    });
    defer bar.deinit();

    bottomTab(.home, "Home", icons.tvg.lucide.house, 401);
    bottomTab(.search, "Search", icons.tvg.lucide.search, 402);
    bottomTab(.browse, "Browse", icons.tvg.lucide.compass, 403);
    bottomTab(.library, "Library", icons.tvg.lucide.library, 404);
    bottomTab(.assistant, "Chat", icons.tvg.lucide.@"message-square-text", 405);
}

fn bottomTab(r: Route, label: []const u8, icon: []const u8, id_extra: usize) void {
    const active = state.app.router.current == r;
    var hovered: bool = false;
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .color_fill = if (hovered) theme.colors.bg_hover else transparent,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer col.deinit();
    if (dvui.clicked(col.data(), .{ .hovered = &hovered })) state.app.router.navigate(r);
    col.drawBackground();

    const fg = if (active) theme.colors.accent_primary else theme.colors.text_secondary;
    dvui.icon(@src(), label, icon, .{}, .{
        .id_extra = id_extra,
        .color_text = fg,
        .min_size_content = .{ .w = 18, .h = 18 },
        .max_size_content = .{ .w = 18, .h = 18 },
        .gravity_x = 0.5,
    });
    var f = dvui.themeGet().font_body;
    f.size = theme.font_size.micro;
    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id_extra,
        .color_text = fg,
        .font = f,
        .gravity_x = 0.5,
    });
}
