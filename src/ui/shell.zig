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

const search_mod = @import("../services/search.zig");

const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

// Sub-navigation selections live in state.app (so any service can navigate to
// a Browse/Library/System sub-tab via state.navigateToTab without importing shell).

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
        // The Player route owns its full bleed (video grid); every other page
        // gets a consistent gutter so content never sits flush to the window edge.
        const r = state.app.router.current;
        // Tight gutter so content fills the window (Browse/grids especially);
        // the player still bleeds edge-to-edge.
        const gutter: f32 = if (r == .player) 0 else theme.spacing.sm;
        var content = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = theme.colors.bg_deep,
            .padding = .{ .x = gutter, .y = if (r == .player) 0 else theme.spacing.xs, .w = gutter, .h = 0 },
        });
        defer content.deinit();
        try renderPage(r);
    }

    // Docked mini-player — keeps transport visible while browsing other pages.
    if (state.app.router.current != .player and anyHasMedia()) {
        footer.renderGlobalBottomTray();
    }

    // Compact: bottom tab bar (mobile-style) below everything.
    if (compact) renderBottomTabs();
}

/// True if ANY player has media loaded (so playback stays reachable via the
/// mini-player even when a background player — not the active one — is playing).
fn anyHasMedia() bool {
    for (state.app.players.items) |p| {
        if (p.current_url_len > 0) return true;
    }
    return false;
}

// ── Top navigation ──

fn renderTopNav(compact: bool) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 32 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = theme.spacing.md, .y = 2, .w = theme.spacing.md, .h = 2 },
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
    }

    omnibox();

    // Right-side actions (icon-only). Assistant lives here now.
    if (components.iconButton(@src(), icons.tvg.lucide.@"message-square-text", "Assistant", state.app.router.current == .assistant)) {
        state.app.router.navigate(.assistant);
    }
    if (components.iconButton(@src(), icons.tvg.lucide.play, "Now playing", state.app.router.current == .player)) {
        state.app.router.navigate(.player);
    }
    if (components.iconButton(@src(), icons.tvg.lucide.@"scroll-text", "Logs & Plugins", state.app.router.current == .system)) {
        state.app.router.navigate(.system);
    }
    if (components.iconButton(@src(), icons.tvg.lucide.settings, "Settings", state.app.router.current == .settings)) {
        state.app.router.navigate(.settings);
    }
}

/// A top-nav link: whole-row click target, icon + label, accent when active.
fn navLink(r: Route, label: []const u8, icon: []const u8, id_extra: usize) void {
    const active = state.app.router.current == r;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = 0, .h = 26 },
        .background = true,
        .color_fill = if (active) theme.colors.bg_elevated else transparent,
        .color_fill_hover = theme.colors.bg_hover, // native dvui hover (no stale local read)
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.sm, .y = 3, .w = theme.spacing.sm, .h = 3 },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        .gravity_y = 0.5,
    });
    defer row.deinit();

    if (dvui.clicked(row.data(), .{})) {
        state.app.router.navigate(r);
    }
    row.drawBackground();

    const fg = if (active) theme.colors.accent_primary else theme.colors.text_secondary;
    dvui.icon(@src(), label, icon, .{}, .{
        .id_extra = id_extra,
        .color_text = fg,
        .min_size_content = .{ .w = 15, .h = 15 },
        .max_size_content = .{ .w = 15, .h = 15 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id_extra,
        .color_text = fg,
        .gravity_y = 0.5,
    });
}

/// Live omnibox — the universal entry point. On Enter it classifies the text:
///   • media (magnet/url/path)        → load into player, go to Player
///   • leading '>' or trailing '?'    → AI assistant (chat)
///   • anything else                  → UNIFIED search across all sources
fn omnibox() void {
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.magnet_buf },
        .placeholder = "Ask, search, or paste a link…",
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 120, .h = 26 },
        .max_size_content = .{ .w = 1000, .h = 26 },
        .margin = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = 0 },
        .color_fill = theme.colors.bg_input,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .gravity_y = 0.5,
    });
    const entered = te.enter_pressed;
    te.deinit();

    if (!entered) return;
    const len = std.mem.indexOfScalar(u8, &state.app.magnet_buf, 0) orelse state.app.magnet_buf.len;
    if (len == 0) return;
    const text = state.app.magnet_buf[0..len];

    if (isMedia(text)) {
        header.submitInput(); // loads into player (clears buffer); helper routes the player nav
        return;
    }
    if (text[0] == '>' or text[len - 1] == '?') {
        header.submitInput(); // → AI chat
        state.app.router.navigate(.assistant);
        return;
    }
    // Default: unified search across every source.
    search_mod.submitQuery(text);
    @memset(&state.app.magnet_buf, 0);
    state.app.router.navigate(.search);
}

fn isMedia(text: []const u8) bool {
    const prefixes = [_][]const u8{ "magnet:", "http://", "https://", "file://", "/", "~/", "./", "ftp://", "rtmp://", "rtsp://" };
    for (prefixes) |p| if (std.mem.startsWith(u8, text, p)) return true;
    return false;
}

// ── Page dispatch ──

fn renderPage(r: Route) !void {
    switch (r) {
        .player => {
            try @import("grid.zig").renderGrid();
            // Transport controls overlay (play/pause/scrubber/volume). The
            // legacy layout calls this right after the grid (main.zig); the page
            // shell must too, or the player has no controls. Gated internally by
            // show_cell_overlay (mouse-activity auto-hide) + provider == .mpv.
            @import("footer.zig").renderLiquidGlassOverlay();
            @import("footer.zig").renderStatsOverlay();
        },
        .settings => drawer.renderTabContent(.Settings),
        .assistant => drawer.renderTabContent(.AI),
        .search => drawer.renderTabContent(.Search),
        .home => @import("home.zig").render(), // personal hub: metrics + lists
        .browse => {
            subTabs(&.{ .TMDB, .YouTube, .Anime, .Comics, .Web, .RSS, .Jellyfin }, &state.app.browse_source, 100);
            drawer.renderTabContent(state.app.browse_source);
        },
        .library => {
            subTabs(&.{ .Queue, .History, .Downloads }, &state.app.library_tab, 200);
            drawer.renderTabContent(state.app.library_tab);
        },
        .system => {
            subTabs(&.{ .Logs, .Plugins }, &state.app.system_tab, 300);
            drawer.renderTabContent(state.app.system_tab);
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
        .Web => "Web",
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

fn iconForTab(t: state.DrawerTab) []const u8 {
    return switch (t) {
        .Search => icons.tvg.lucide.search,
        .Downloads => icons.tvg.lucide.download,
        .TMDB => icons.tvg.lucide.film,
        .YouTube => icons.tvg.lucide.youtube,
        .Queue => icons.tvg.lucide.@"list-video",
        .Comics => icons.tvg.lucide.@"book-open",
        .Web => icons.tvg.lucide.globe,
        .Anime => icons.tvg.lucide.tv,
        .History => icons.tvg.lucide.history,
        .RSS => icons.tvg.lucide.rss,
        .Jellyfin => icons.tvg.lucide.server,
        .Plugins => icons.tvg.lucide.puzzle,
        .Logs => icons.tvg.lucide.@"scroll-text",
        .Settings => icons.tvg.lucide.settings,
        .AI => icons.tvg.lucide.@"message-square-text",
    };
}

/// Horizontal segment of sub-tabs (icon + label); updates `sel` on click.
/// Compact, full-width; wraps when narrow.
fn subTabs(tabs: []const state.DrawerTab, sel: *state.DrawerTab, id_extra: usize) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer bar.deinit();

    for (tabs, 0..) |t, i| {
        const active = sel.* == t;
        const fg = if (active) theme.colors.accent_primary else theme.colors.text_secondary;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id_extra + i + 1,
            .min_size_content = .{ .w = 0, .h = 24 },
            .background = true,
            .color_fill = if (active) theme.colors.bg_elevated else transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = 3, .w = theme.spacing.sm, .h = 3 },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
        defer row.deinit();
        if (dvui.clicked(row.data(), .{})) sel.* = t;
        row.drawBackground();
        dvui.icon(@src(), "tab", iconForTab(t), .{}, .{
            .id_extra = id_extra + i + 1,
            .color_text = fg,
            .min_size_content = .{ .w = 14, .h = 14 },
            .max_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{tabLabel(t)}, .{
            .id_extra = id_extra + i + 1,
            .color_text = fg,
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
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .color_fill = if (active) theme.colors.bg_elevated else transparent,
        .color_fill_hover = theme.colors.bg_hover,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer col.deinit();
    if (dvui.clicked(col.data(), .{})) state.app.router.navigate(r);
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
