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
const browser = @import("../services/browser.zig");
const browser_pure = @import("../services/browser_pure.zig");

const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

var player_top_chrome_rect: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

pub fn mouseInPlayerTopChrome(p: dvui.Point.Physical) bool {
    const r = player_top_chrome_rect;
    return p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h;
}

// Sub-navigation selections live in state.app (so any service can navigate to
// a Browse/Library/System sub-tab via state.navigateToTab without importing shell).

/// Frame entry — called from appFrame when page_shell_enabled.
pub fn render() !void {
    // Player popovers and panels are route-bound. Leaving Now Playing must not
    // leave an invisible modal armed that reappears on the next visit or eats
    // the first click on another page.
    if (state.app.router.current != .player) {
        footer.closePickers();
        state.app.playlist_drawer_open = false;
        state.app.media_info_open = false;
        state.app.stats_overlay_open = false;
    }

    const live_width = @import("../core/scale_pure.zig").layoutUnits(dvui.windowRect().w, state.app.ui_scale);
    const titlebar = @import("titlebar.zig");
    const titlebar_in_flow = titlebar.active() and state.app.router.current != .player;
    const live_height = @import("../core/scale_pure.zig").layoutUnits(
        @max(1, dvui.windowRect().h - @as(f32, if (titlebar_in_flow) titlebar.HEIGHT else 0)),
        state.app.ui_scale,
    );
    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        // Page minimum widths must not push navigation beyond the window.
        .min_size_content = .{ .w = live_width, .h = live_height },
        .max_size_content = .{ .w = live_width, .h = live_height },
        .background = true,
        .color_fill = theme.colors.bg_app,
    });
    defer root.deinit();

    // Responsive breakpoints use the live OS window, not this root widget's
    // previous-frame rect. The latter could leave the old navbar mounted after
    // resize and push More off-screen until some unrelated repaint happened.
    //   compact (< 900pt): mobile layout — top nav links move to a bottom tab bar.
    //   narrow  (< 950pt): still a top nav, but nav-link text collapses to
    //     icons-only and the omnibox tightens so everything fits as you resize.
    // The thresholds are ON-SCREEN POINTS. This shell renders inside
    // dvui.scale(ui_scale), so root.rect.w is in scaled units — scale_pure
    // converts. Comparing the raw value fired the breakpoints ~1/ui_scale too
    // late and pushed the right-hand nav actions off the window edge.
    const scale_pure = @import("../core/scale_pure.zig");
    const window_rect = dvui.windowRect();
    const w = scale_pure.layoutUnits(window_rect.w, state.app.ui_scale);
    const h = scale_pure.layoutUnits(window_rect.h, state.app.ui_scale);
    const compact = scale_pure.isCompact(w, state.app.ui_scale);
    const narrow = scale_pure.isNarrow(w, state.app.ui_scale) or w < 1200;
    const tiny = scale_pure.isTiny(w, state.app.ui_scale);
    const short = scale_pure.isShort(h, state.app.ui_scale);

    // A breakpoint swap changes the navbar's child set and therefore its
    // measured minimum size. Give dvui one explicit convergence frame so a
    // resize cannot stop with the outgoing layout's cached width.
    const ResponsiveState = struct {
        var last_tier: u3 = 7;
    };
    const tier: u3 = if (tiny) 3 else if (compact) 2 else if (narrow) 1 else 0;
    if (ResponsiveState.last_tier != tier) {
        ResponsiveState.last_tier = tier;
        dvui.refresh(null, @src(), null);
    }

    // Immersive playback: on the Player route, give the video the whole window by
    // hiding the top nav (and compact bottom tabs) once the viewer goes idle or
    // enters fullscreen — parity with the legacy layout's chrome auto-hide
    // (main.zig). Scoped to .player so the nav never vanishes while browsing with
    // a background player. Mouse motion bumps last_mouse_move_ms → reveals it.
    const autohide = @import("chrome_autohide.zig");
    const fullscreen = state.app.fullscreen_player_idx != null;
    var idle_ms: i64 = 0;
    var hide_eligible = false; // idle threshold crossed → nav fading or hidden
    if (state.app.router.current == .player) {
        var playing_video = false;
        if (state.app.active_player_idx < state.app.players.items.len) {
            const ap = state.app.players.items[state.app.active_player_idx];
            playing_video = ap.texture != null and !ap.cached_paused;
        }
        const text_len = std.mem.indexOfScalar(u8, &state.app.magnet_buf, 0) orelse state.app.magnet_buf.len;
        const now_ms = @import("../core/io_global.zig").milliTimestamp();
        idle_ms = now_ms - state.app.last_mouse_move_ms;
        hide_eligible = autohide.shouldHideChrome(.{
            .playing_video = playing_video,
            .typing = text_len > 0,
            .idle_ms = idle_ms,
            .threshold_ms = autohide.DEFAULT_THRESHOLD_MS,
        });
    }
    const immersive = hide_eligible and idle_ms >= autohide.DEFAULT_THRESHOLD_MS + autohide.FADE_MS;

    if (state.app.router.current == .player) {
        // Player is a true layer stack: the video owns the entire route and
        // chrome is painted above it. Neither the nav nor the transport panel
        // participates in layout, so showing controls never resizes the frame.
        var nav_alpha: f32 = 1.0;
        if (hide_eligible and !immersive) {
            const t = @as(f32, @floatFromInt(idle_ms - autohide.DEFAULT_THRESHOLD_MS)) / @as(f32, @floatFromInt(autohide.FADE_MS));
            nav_alpha = 1.0 - std.math.clamp(t, 0.0, 1.0);
            dvui.refresh(null, @src(), null);
        }

        var stage = dvui.overlay(@src(), .{ .expand = .both });
        try renderPage(.player);

        if (!immersive) {
            const prev_alpha = dvui.alpha(nav_alpha);
            var top_chrome = dvui.overlay(@src(), .{
                .expand = .horizontal,
                .gravity_y = 0.0,
            });
            // A continuous edge gradient reads like polished playback chrome;
            // separate uniform title/nav fills read as stacked dark toolbars.
            // Paint this first so all controls float above it.
            {
                var backdrop = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
                const edge_alphas = [_]u8{ 96, 92, 86, 78, 68, 56, 44, 32, 20, 10, 4 };
                inline for (edge_alphas, 0..) |alpha, i| {
                    var slice = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = i + 9810,
                        .expand = .horizontal,
                        .background = true,
                        .color_fill = theme.playerGlass(alpha),
                        .min_size_content = .{ .w = 0, .h = 9 },
                        .max_size_content = .{ .w = 0, .h = 9 },
                    });
                    slice.deinit();
                }
                backdrop.deinit();
            }
            var chrome_controls = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .gravity_y = 0.0,
            });
            // On the Player route the custom Windows title strip belongs to
            // this overlay as well, so the video extends behind all top chrome.
            titlebar.render();
            renderPlayerTopNav();
            player_top_chrome_rect = chrome_controls.data().borderRectScale().r;
            chrome_controls.deinit();
            top_chrome.deinit();
            dvui.alphaSet(prev_alpha);
        }
        stage.deinit();

        header.renderStreamKeyPopoverIfOpen();
        return;
    }

    if (!immersive) {
        // Fade the nav out over the same window as the control-bar fade
        // (footer.zig) instead of popping in one frame — a chrome layer
        // vanishing instantly above a smooth fade reads as a glitch. Self-
        // drive repaints through the fade window so it animates even when
        // nothing else requests frames (audio-only / buffering playback).
        var nav_alpha: f32 = 1.0;
        if (hide_eligible and !fullscreen) {
            const t = @as(f32, @floatFromInt(idle_ms - autohide.DEFAULT_THRESHOLD_MS)) / @as(f32, @floatFromInt(autohide.FADE_MS));
            nav_alpha = 1.0 - std.math.clamp(t, 0.0, 1.0);
            dvui.refresh(null, @src(), null);
        }
        const prev_alpha = dvui.alpha(nav_alpha);
        renderTopNav(compact, narrow);
        if (compact) {
            var search_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = dvui.Rect.all(theme.spacing.xs),
            });
            omnibox(true);
            search_row.deinit();
        }
        dvui.alphaSet(prev_alpha);
    }

    // Reserve bottom navigation before the page takes the remaining height.
    if (compact and !immersive) renderBottomTabs(tiny or short);

    {
        // The Player route owns its full bleed (video grid); every other page
        // gets a consistent gutter so content never sits flush to the window edge.
        const r = state.app.router.current;
        // Tight gutter so content fills the window (Browse/grids especially);
        // the player still bleeds edge-to-edge.
        const gutter: f32 = if (r == .player) 0 else if (tiny) theme.spacing.xs else theme.spacing.sm;
        var content = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = theme.colors.bg_deep,
            .padding = .{ .x = gutter, .y = if (r == .player) 0 else theme.spacing.xs, .w = gutter, .h = 0 },
        });
        defer content.deinit();
        // Fade each page in on navigation. id_extra keyed on the route AND the
        // active sub-tab so the AnimateWidget gets a fresh id per destination →
        // firstFrame true → the fade re-triggers on top-nav changes and on
        // Browse/Library/System sub-tab switches alike (previously sub-tab
        // swaps popped while route swaps faded). The Player route bleeds edge-
        // to-edge and must appear instantly (no flash over the video), so it
        // skips.
        if (r == .player) {
            try renderPage(r);
        } else {
            const sub_key: usize = switch (r) {
                .browse => @intFromEnum(state.app.browse_source),
                .system => @intFromEnum(state.app.system_tab),
                .plugins => @intFromEnum(state.app.plugin_tab),
                else => 0,
            };
            var page_fade = dvui.animate(@src(), .{ .kind = .alpha, .duration = theme.motionDuration(theme.motion.base), .easing = theme.motion.enter }, .{
                .id_extra = @as(usize, @intFromEnum(r)) * 100 + sub_key,
                .expand = .both,
            });
            defer page_fade.deinit();
            // AnimateWidget wraps a SINGLE child. Pages with sub-tabs render
            // TWO siblings (tab bar + content) — without this box they each
            // got the full page rect and drew on top of each other (the
            // Browse toolbar rows visibly interleaved).
            var page_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer page_col.deinit();
            try renderPage(r);
        }
    }

    // Docked mini-player — keeps transport visible while browsing other pages.
    if (state.app.router.current != .player and anyHasMedia()) {
        footer.renderGlobalBottomTray();
    }

    // Stream-key popover — floating, opened from the overflow menu. (Its
    // legacy render site is the header, which never runs in the shell.)
    header.renderStreamKeyPopoverIfOpen();
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

fn renderTopNav(compact: bool, narrow: bool) void {
    // Transparent title bar — the nav floats over the app background (no solid
    // fill) for a lighter, content-focused feel; a hairline bottom border keeps
    // it separated from the page.
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 30 },
        .background = true,
        .color_fill = transparent,
        .color_border = if (state.app.router.current == .player) transparent else theme.colors.border_subtle,
        .border = if (state.app.router.current == .player) dvui.Rect.all(0) else .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = if (compact) theme.spacing.xs else theme.spacing.md, .y = 1, .w = if (compact) theme.spacing.xs else theme.spacing.md, .h = 1 },
    });
    defer bar.deinit();

    // Brand — clickable: always returns to the Home overview (even out of
    // the chat transcript, which otherwise owns the Home route while a
    // conversation exists). Suppressed when the custom title bar is active
    // (Windows) — it already shows the Opal gem + wordmark, so a second copy in
    // the nav row would be a duplicate.
    if (!@import("titlebar.zig").active()) {
        var brand = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .background = true,
            .color_fill = transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.xs, .y = 2, .w = theme.spacing.xs, .h = 2 },
            .gravity_y = 0.5,
        });
        defer brand.deinit();
        var hovered = false;
        if (dvui.clicked(brand.data(), .{ .hovered = &hovered })) {
            @import("home.zig").showOverview();
            state.app.router.navigate(.home);
        }
        if (hovered) brand.data().options.color_fill = theme.colors.bg_hover;
        brand.drawBackground();
        // Brand mark — the real Opal gem (assets/logo.svg rendered to PNG at
        // build time via src/ui/opal_logo_64.png), not a generic zap glyph.
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = @embedFile("opal_logo_64.png"), .name = "opal-brand" } },
        }, .{
            .min_size_content = theme.iconSize(.md),
            .max_size_content = .{ .w = 20, .h = 20 },
            .gravity_y = 0.5,
        });
        if (!compact) {
            _ = dvui.label(@src(), "Opal", .{}, .{
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = 0 },
            });
        }
    }

    browseSourcePicker();

    // Back / forward — disabled (dimmed, inert) when there's no history in
    // that direction. Previously canGoBack() was passed as `active`, which
    // painted Back as a toggled-on accent chip whenever ANY history existed —
    // the same visual language the route buttons use for "current page".
    if (chromeIconButton(@src(), icons.tvg.lucide.@"chevron-left", "Back", false, state.app.router.canGoBack())) {
        state.app.router.goBack();
    }

    // Primary nav links — hidden in compact (bottom tab bar takes over).
    if (!compact) {
        // Home / Downloads / Queue / History are icon-only (tooltip on hover);
        // the content destinations keep their labels.
        // Search and Browse are owned by the omnibox and source selector.
        navLink(.home, "Home", icons.tvg.lucide.house, 1, true);
        navLink(.watching, "Watching", icons.tvg.lucide.tv, 7, narrow);
    }

    // Compact widths render the same input in a dedicated row below the nav.
    if (!compact) omnibox(narrow);

    // The search field takes available width; compact keeps actions right-aligned.
    if (compact) {
        var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        sp.deinit();
    }

    // Donate chip — dropped at narrow so the tighter row doesn't clip.

    // Right-side actions (icon-only). The former "Assistant" button opened the
    // AI/Voice SETTINGS page (renderAIContent) — that now lives in Settings ›
    // AI & Voice, so it's dropped from the primary nav. AI chat is reachable
    // via the omnibox ('>' or trailing '?') — the conversation lives on Home.
    if (chromeIconButton(@src(), icons.tvg.lucide.play, "Now playing", state.app.router.current == .player, true)) {
        state.app.router.navigate(.player);
    }
    // Plugins — its own nav-bar menu. Was a sub-tab hidden behind the
    // "Logs & Plugins" icon, which meant two clicks and no hint that Suwayomi /
    // Debrid / Trakt lived there at all. The dropdown lists every section, so
    // each is one click from anywhere.
    if (!compact and chromeIconButton(@src(), icons.tvg.lucide.settings, "Settings", state.app.router.current == .settings, true)) {
        state.app.router.navigate(.settings);
    }

    // Overflow (⋯) — commands that only existed in the legacy header and were
    // otherwise unreachable in the default shell UI (workspaces, hardware
    // decode, incognito, seek sync, voice, stream key, theme cycling, the
    // shortcut cheat sheet).
    {
        var m = dvui.menu(@src(), .horizontal, .{ .gravity_y = 0.5 });
        defer m.deinit();
        if (dvui.menuItemIcon(@src(), "More", icons.tvg.lucide.@"ellipsis-vertical", .{ .submenu = true }, .{
            .color_text = theme.colors.text_secondary,
            .color_fill = transparent,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .min_size_content = theme.iconSize(.sm),
            .padding = dvui.Rect.all(6),
        })) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            var col = dvui.menu(@src(), .vertical, .{
                .background = true,
                .color_fill = theme.colors.bg_surface,
                .border = dvui.Rect.all(1),
                .color_border = theme.colors.border_subtle,
                .corner_radius = dvui.Rect.all(theme.radius.md),
            });
            defer col.deinit();
            renderSecondaryDestinations(compact);
            renderOverflowItems();
        }
    }
}

/// Playback-only header. Browsing destinations and the omnibox belong to the
/// browsing shell; repeating all of them over a film creates a wall of icons.
fn renderPlayerTopNav() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 30 },
        .padding = .{ .x = theme.spacing.md, .y = 1, .w = theme.spacing.md, .h = 1 },
    });
    defer bar.deinit();

    if (components.iconButtonOverlay(@src(), icons.tvg.lucide.@"chevron-left", "Back", false, true)) {
        if (state.app.router.canGoBack()) state.app.router.goBack() else state.app.router.navigate(.home);
        dvui.refresh(null, @src(), null);
    }

    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        if (p.current_url_len > 0) {
            const raw = p.current_url[0..p.current_url_len];
            var safe_buf: [2048]u8 = undefined;
            const full = @import("../player/watch_history_pure.zig").persistedTarget(raw, &safe_buf).identity;
            const base = std.fs.path.basename(full);
            const clipped = if (base.len > 72) base[0..72] else base;
            _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(clipped)}, .{
                .expand = .horizontal,
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
        }
    }

    var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
    spacer.deinit();
    if (components.iconButtonOverlay(@src(), icons.tvg.lucide.settings, "Settings", false, true)) {
        state.app.router.navigate(.settings);
        dvui.refresh(null, @src(), null);
    }
}

fn chromeIconButton(src: std.builtin.SourceLocation, icon: []const u8, tooltip: []const u8, active: bool, enabled: bool) bool {
    if (state.app.router.current == .player) {
        return components.iconButtonOverlay(src, icon, tooltip, active, enabled);
    }
    return components.iconButtonEx(src, icon, tooltip, active, enabled);
}

/// Nav-bar Plugins menu: a puzzle-icon dropdown listing every section of the
/// Plugins route. Selecting one navigates AND sets the sub-tab, so the menu is
/// a direct jump rather than "open the page, then hunt for the card".
fn pluginsMenu() void {
    const on_route = state.app.router.current == .plugins;
    var m = dvui.menu(@src(), .horizontal, .{ .gravity_y = 0.5 });
    defer m.deinit();
    if (dvui.menuItemIcon(@src(), "Plugins", icons.tvg.lucide.puzzle, .{ .submenu = true }, .{
        .color_text = if (on_route) theme.colors.accent else theme.colors.text_secondary,
        .color_fill = if (on_route) theme.colors.bg_elevated else transparent,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(6),
    })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var col = dvui.menu(@src(), .vertical, .{
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .border = dvui.Rect.all(1),
            .color_border = theme.colors.border_subtle,
            .corner_radius = dvui.Rect.all(theme.radius.md),
        });
        defer col.deinit();

        for (router.PLUGIN_TABS, 0..) |t, i| {
            const active = on_route and state.app.plugin_tab == t;
            if (dvui.menuItemLabel(@src(), router.pluginTabLabel(t), .{}, .{
                .id_extra = 900 + i,
                .expand = .horizontal,
                .color_text = if (active) theme.colors.accent else theme.colors.text_primary,
            }) != null) {
                state.app.plugin_tab = t;
                state.app.router.navigate(.plugins);
            }
            var f = dvui.themeGet().font_body;
            f.size = theme.font_size.micro;
            _ = dvui.label(@src(), "{s}", .{router.pluginTabHint(t)}, .{
                .id_extra = 900 + i,
                .color_text = theme.colors.text_tertiary,
                .font = f,
                .margin = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = theme.spacing.xs },
            });
        }
    }
}

/// Body of the top-nav overflow menu. Each item is a leaf menuItemLabel; dvui
/// closes the floating menu on activation.
fn renderSecondaryDestinations(compact: bool) void {
    const item_opts = dvui.Options{ .expand = .horizontal, .color_text = theme.colors.text_primary };
    // The compact shell deliberately removes the desktop link row. Keep every
    // destination reachable instead of treating "mobile" as five hand-picked
    // pages and silently losing the rest of the application.
    if (compact) {
        if (dvui.menuItemLabel(@src(), "Home", .{}, item_opts) != null) state.app.router.navigate(.home);
        if (dvui.menuItemLabel(@src(), "Watching", .{}, item_opts) != null) state.app.router.navigate(.watching);
    }
    if (dvui.menuItemLabel(@src(), "Downloads", .{}, item_opts) != null) state.app.router.navigate(.downloads);
    if (dvui.menuItemLabel(@src(), "Queue", .{}, item_opts) != null) state.app.router.navigate(.queue);
    if (dvui.menuItemLabel(@src(), "History", .{}, item_opts) != null) state.app.router.navigate(.history);
    if (dvui.menuItemLabel(@src(), "Plugins", .{}, item_opts) != null) state.app.router.navigate(.plugins);
    if (dvui.menuItemLabel(@src(), "Logs", .{}, item_opts) != null) state.app.router.navigate(.system);
    if (dvui.menuItemLabel(@src(), "Web remote settings", .{}, item_opts) != null) {
        state.app.settings_tab = .WebUi;
        state.app.router.navigate(.settings);
    }
    if (dvui.menuItemLabel(@src(), "Donate", .{}, item_opts) != null) {
        @import("settings.zig").openExternal(header.DONATE_URL);
    }
    if (compact and dvui.menuItemLabel(@src(), "Settings", .{}, item_opts) != null) state.app.router.navigate(.settings);
}

fn renderOverflowItems() void {
    const item_opts = dvui.Options{ .expand = .horizontal, .color_text = theme.colors.text_primary };
    const voice = @import("../services/ai_voice.zig");

    if (dvui.menuItemLabel(@src(), "Open file…", .{}, item_opts) != null) {
        @import("ui.zig").triggerFileOpen();
    }
    if (dvui.menuItemLabel(@src(), "Save workspace…", .{}, item_opts) != null) {
        @memset(&state.app.ws_name_input, 0);
        state.app.ws_save_open = true;
        state.app.ws_load_open = false;
    }
    if (dvui.menuItemLabel(@src(), "Load workspace…", .{}, item_opts) != null) {
        @import("workspace.zig").scanWorkspaces();
        state.app.ws_load_open = true;
        state.app.ws_save_open = false;
    }
    if (dvui.menuItemLabel(@src(), if (state.app.seek_sync) "Seek sync: on" else "Seek sync: off", .{}, item_opts) != null) {
        state.app.seek_sync = !state.app.seek_sync;
        state.markConfigDirty();
    }
    if (dvui.menuItemLabel(@src(), if (state.app.hwdec_enabled) "Hardware decode: on" else "Hardware decode: off", .{}, item_opts) != null) {
        state.app.hwdec_enabled = !state.app.hwdec_enabled;
        state.markConfigDirty();
        const hw_val: []const u8 = if (state.app.hwdec_enabled) "auto" else "no";
        for (state.app.players.items) |p| {
            var hw_cmd: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&hw_cmd, "set hwdec {s}", .{hw_val})) |cmd| {
                _ = @import("../core/c.zig").mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
            } else |_| {}
        }
    }
    if (dvui.menuItemLabel(@src(), if (state.app.incognito_mode) "Incognito: on" else "Incognito: off", .{}, item_opts) != null) {
        state.app.incognito_mode = !state.app.incognito_mode;
        state.showToast(if (state.app.incognito_mode) "Incognito ON — no history saved" else "Incognito OFF");
    }
    if (dvui.menuItemLabel(@src(), if (voice.conversation_active.load(.acquire)) "Voice conversation: on" else "Voice conversation…", .{}, item_opts) != null) {
        voice.toggleConversation();
    }
    if (header.hasStreamToken()) {
        if (dvui.menuItemLabel(@src(), "Stream key…", .{}, item_opts) != null) {
            header.toggleStreamKeyPopover();
        }
    }
    if (dvui.menuItemLabel(@src(), "Cycle theme", .{}, item_opts) != null) {
        theme.cycleTheme();
        state.showToast(theme.presetName(theme.active_preset));
    }
    if (dvui.menuItemLabel(@src(), "Keyboard shortcuts", .{}, item_opts) != null) {
        state.app.cheatsheet_open = !state.app.cheatsheet_open;
    }
}

/// A top-nav link: whole-row click target, icon + label, accent when active.
/// Hover lifts the fill; the row takes a tab stop (Enter/Space activates) and
/// draws dvui's focus ring when keyboard-focused.
/// `icon_only` drops the text label. The label is still passed (and still names
/// the icon), so it becomes a hover tooltip — an unlabelled glyph with no tooltip
/// is a guessing game.
fn navLink(r: Route, label: []const u8, icon: []const u8, id_extra: usize, icon_only: bool) void {
    const active = state.app.router.current == r;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = 0, .h = 24 },
        .background = true,
        .color_fill = if (active) theme.colors.bg_elevated else transparent,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = .{ .x = theme.spacing.sm, .y = 2, .w = theme.spacing.sm, .h = 2 },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        .gravity_y = 0.5,
    });
    defer row.deinit();

    if (navRowInteract(row)) {
        state.app.router.navigate(r);
    }

    const fg = if (active) theme.colors.accent else theme.colors.text_secondary;
    dvui.icon(@src(), label, icon, .{}, .{
        .id_extra = id_extra,
        .color_text = fg,
        .min_size_content = theme.iconSize(.sm),
        .gravity_y = 0.5,
        // No label to separate from — the trailing gap would just off-center the
        // glyph inside its pill.
        .margin = if (icon_only)
            dvui.Rect.all(0)
        else
            .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
    });

    if (icon_only) {
        // Every navLink shares this @src(), so the tooltip needs an explicit
        // id_extra or all of them collide on one widget id.
        components.tipId(@src(), row.data().*, label, id_extra);
        return;
    }

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
fn omnibox(narrow: bool) void {
    var placeholder_buf: [96]u8 = undefined;
    const placeholder: []const u8 = if (state.app.router.current == .browse)
        std.fmt.bufPrint(&placeholder_buf, "Search {s}, or paste a link…", .{tabLabel(state.app.browse_source)}) catch "Search this source, or paste a link…"
    else if (narrow)
        "Search, ask, paste…"
    else
        "Search everything, ask, or paste a link…";
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.magnet_buf },
        .placeholder = placeholder,
    }, .{
        // Consume only the width left after navigation/actions. On compact
        // windows this is the full second row, never a hidden search control.
        .expand = .horizontal,
        .min_size_content = .{ .w = 80, .h = 26 },
        .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 4, .h = 0 },
        .color_fill = if (state.app.router.current == .player) theme.playerGlass(40) else theme.colors.bg_elevated,
        .color_border = if (state.app.router.current == .player) theme.playerGlass(76) else theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .gravity_y = 0.5,
    });
    const entered = te.enter_pressed;
    te.deinit();

    const len = std.mem.indexOfScalar(u8, &state.app.magnet_buf, 0) orelse state.app.magnet_buf.len;

    // Inline affordances next to the box: clear-✕ while text is present
    // (mouse users had no way to empty it), paste when empty, and the voice
    // conversation toggle (was legacy-header-only).
    if (len > 0) {
        if (components.iconButton(@src(), icons.tvg.lucide.x, "Clear", false)) {
            @memset(&state.app.magnet_buf, 0);
            return;
        }
    } else {
        if (components.iconButton(@src(), icons.tvg.lucide.@"clipboard-paste", "Paste", false)) {
            header.handleClipboardPaste();
            return;
        }
    }
    {
        const voice = @import("../services/ai_voice.zig");
        const voice_icon = if (voice.conv_phase == .speaking)
            icons.tvg.lucide.@"volume-2"
        else if (voice.conv_phase == .listening or voice.is_recording.load(.acquire))
            icons.tvg.lucide.mic
        else
            icons.tvg.lucide.headphones;
        if (chromeIconButton(@src(), voice_icon, "Voice / conversation mode", voice.conversation_active.load(.acquire), true)) {
            voice.toggleConversation();
        }
    }
    {
        var gap = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = theme.spacing.sm, .h = 0 } });
        gap.deinit();
    }

    if (!entered) return;
    if (len == 0) return;
    const text = std.mem.trim(u8, state.app.magnet_buf[0..len], " \t\r\n");
    switch (browser_pure.classifyOmnibox(text)) {
        .empty => {},
        .memory => {
            search_mod.memorySearch(std.mem.trim(u8, text[1..], " \t"));
            @memset(&state.app.magnet_buf, 0);
            state.app.router.navigate(.search);
        },
        .assistant => {
            header.submitInput();
            // The conversation renders on HOME (home.zig chat mode); the
            // .assistant route hosts AI SETTINGS, not the chat.
            state.app.router.navigate(.home);
        },
        .open => openOmniboxTarget(text),
        .search => {
            if (browser.searchCurrentBrowse(text)) {
                @memset(&state.app.magnet_buf, 0);
            } else {
                search_mod.submitQuery(text);
                @memset(&state.app.magnet_buf, 0);
                state.app.router.navigate(.search);
            }
        },
    }
}

fn openOmniboxTarget(text: []const u8) void {
    var normalized_buf: [2048]u8 = undefined;
    const normalized = browser_pure.resolveOpenTarget(text, &normalized_buf);
    // resolveOpenTarget may return a slice into magnet_buf; browser.loadContent
    // needs it intact after the visible box is cleared.
    var target_buf: [2048]u8 = undefined;
    const n = @min(normalized.len, target_buf.len);
    @memcpy(target_buf[0..n], normalized[0..n]);
    @memset(&state.app.magnet_buf, 0);
    const target = target_buf[0..n];
    state.showToast(switch (browser_pure.routeContent(target)) {
        .mpv => "Preparing playback…",
        .comic_viewer => "Opening reader…",
        .torrent => "Opening torrent…",
        .web => "Opening in Web…",
    });
    browser.loadContent(target);
}

/// Shared interaction for the box-based nav rows (top-nav links, sub-tabs,
/// bottom tabs): click + hover lift + tab stop + Enter/Space activation +
/// focus ring. Plain boxes get NONE of this from dvui (color_fill_hover is
/// only consulted by button widgets, and boxes never register a tab index),
/// which left the app's primary navigation mouse-only with zero feedback.
/// Returns true when the row was activated (click or key) this frame.
/// Call AFTER creating the box and BEFORE adding children (the hover repaint
/// draws over the base fill; children then draw on top).
fn navRowInteract(row: *dvui.BoxWidget) bool {
    var activated = false;
    var hovered = false;

    const rid = row.data().id;
    dvui.tabIndexSet(rid, null);
    const focused = dvui.focusedWidgetId() == rid;
    if (focused) {
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if (e.evt == .key and e.evt.key.action == .down and e.evt.key.matchBind("activate")) {
                e.handle(@src(), row.data());
                activated = true;
            }
        }
    }
    if (dvui.clicked(row.data(), .{ .hovered = &hovered })) activated = true;

    if (hovered) row.data().options.color_fill = theme.colors.bg_hover;
    row.drawBackground();
    if (focused) row.data().focusBorder();
    return activated;
}

// ── Page dispatch ──

fn renderPage(r: Route) !void {
    switch (r) {
        .player => {
            // Player route: the grid (video/waveform cell) on the left, and — when
            // synced lyrics are loaded — a docked lyrics column on the right. The
            // lyrics column is a real layout slot, NOT an overlay, so it can never
            // cover the waveform/video in the cell.
            const show_lyrics = blk: {
                if (state.app.active_player_idx >= state.app.players.items.len) break :blk false;
                if (state.app.players.items[state.app.active_player_idx].provider != .mpv) break :blk false;
                break :blk @import("../services/music_subsonic.zig").lyricsHave();
            };

            if (show_lyrics) {
                const lyrics_below = dvui.windowRect().w < 720;
                // Horizontal split: video/waveform grid (flex) + docked lyrics
                // column (fixed 320px). renderGrid()'s own grid_wrapper is
                // `.expand = .both`, so it IS the flex child directly — no extra
                // `left` wrapper. That matters: the video texture fills the cell
                // via `.expand = .ratio`, which (dvui.placeIn) only grows to a
                // parent whose content rect already has a DEFINITE height. Every
                // ancestor box must propagate full height down its main axis; an
                // extra vertical wrapper here added a min-size propagation level
                // that (together with the fixed, non-vertically-expanding lyrics
                // sibling) left the cell chain resolving to the grid's tiny min
                // height, collapsing the ratio image to a min-sized box. Fewer
                // levels + both split children vertically-expanding (see the
                // panel's `.expand = .vertical`) keeps the height unambiguous.
                var split = dvui.box(@src(), .{ .dir = if (lyrics_below) .vertical else .horizontal }, .{ .expand = .both });
                defer split.deinit();
                try @import("grid.zig").renderGrid();
                @import("../services/music_subsonic.zig").renderLyricsPanel(if (lyrics_below) .bottom else .side);
            } else {
                try @import("grid.zig").renderGrid();
            }

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
            drawer.renderTabContent(state.app.browse_source);
        },
        .watching => @import("../services/tv_library.zig").renderContent(),
        .downloads => drawer.renderTabContent(.Downloads),
        .queue => drawer.renderTabContent(.Queue),
        .history => drawer.renderTabContent(.History),
        .plugins => {
            pluginSubTabs();
            @import("../services/plugins.zig").renderSection(state.app.plugin_tab);
        },
        .system => {
            // Logs only — Plugins moved to its own nav-bar menu/route. A
            // one-entry tab strip would be pure chrome, so it's dropped.
            state.app.system_tab = .Logs;
            drawer.renderTabContent(.Logs);
        },
    }
}

const BROWSE_SOURCES = [_]state.DrawerTab{ .TMDB, .YouTube, .Iptv, .Anime, .Podcasts, .Radio, .Music, .Comics, .Web, .RSS, .Jellyfin, .Plex, .Audiobooks, .Opds, .Novels, .Vndb, .Drama };
const WATCH_SOURCES = [_]state.DrawerTab{ .TMDB, .YouTube, .Anime, .Drama, .Iptv };
const LISTEN_SOURCES = [_]state.DrawerTab{ .Podcasts, .Radio, .Music, .Audiobooks };
const READ_SOURCES = [_]state.DrawerTab{ .Comics, .Novels, .Vndb, .Opds, .RSS };
const CONNECTED_SOURCES = [_]state.DrawerTab{ .Web, .Jellyfin, .Plex };

/// Browse is one task with a source filter, not seventeen permanent navigation
/// tabs. Connectors remain reachable from the command palette even when their
/// setup is incomplete; Plugins/Settings owns configuration.
fn browseSourcePicker() void {
    if (browseSourceSelect()) |picked| {
        state.app.browse_source = picked;
        state.app.drawer_tab = state.app.browse_source;
        state.app.router.navigate(.browse);
    }
}

/// Compact task-grouped source selector, retaining every source. Disconnected
/// integrations stay discoverable so their sign-in/recovery UI remains usable.
/// Keep it single-level: cascading hover submenus were fragile at the window
/// edges and could lose their anchor before a source click reached them.
fn browseSourceSelect() ?state.DrawerTab {
    var picked: ?state.DrawerTab = null;
    var menu = dvui.menu(@src(), .horizontal, .{
        .color_fill = transparent,
        .gravity_y = 0.5,
    });
    defer menu.deinit();

    const selected = state.app.browse_source;
    if (dvui.menuItemLabel(@src(), tabLabel(selected), .{ .submenu = true }, .{
        .min_size_content = .{ .w = 118, .h = 0 },
        .background = true,
        .color_fill = if (state.app.router.current == .player) transparent else theme.colors.bg_surface,
        .color_fill_hover = if (state.app.router.current == .player) theme.playerGlass(42) else theme.colors.bg_hover,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = theme.spacing.sm, .y = 4, .w = theme.spacing.sm, .h = 4 },
    })) |anchor| {
        var popup = dvui.floatingMenu(@src(), .{ .from = anchor }, .{
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .padding = dvui.Rect.all(theme.spacing.xs),
            .corner_radius = theme.dims.rad_lg,
        });
        defer popup.deinit();
        var choices = dvui.menu(@src(), .vertical, .{
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .corner_radius = theme.dims.rad_lg,
        });
        defer choices.deinit();
        browseSourceSection("WATCH", &WATCH_SOURCES, 8100, &picked);
        browseSourceSection("LISTEN", &LISTEN_SOURCES, 8200, &picked);
        browseSourceSection("READ", &READ_SOURCES, 8300, &picked);
        browseSourceSection("WEB & LIBRARIES", &CONNECTED_SOURCES, 8400, &picked);
    }
    return picked;
}

fn browseSourceSection(label: []const u8, sources: []const state.DrawerTab, id: usize, picked: *?state.DrawerTab) void {
    const selected = state.app.browse_source;

    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .w = 196, .h = 14 },
        .color_text = theme.colors.text_tertiary,
        .padding = .{ .x = theme.spacing.sm, .y = 5, .w = theme.spacing.sm, .h = 2 },
    });
    for (sources, 0..) |source, i| {
        if (dvui.menuItemLabel(@src(), tabLabel(source), .{}, .{
            .id_extra = id + i + 1,
            .expand = .horizontal,
            .min_size_content = .{ .w = 196, .h = 28 },
            .color_fill = if (source == selected) theme.colors.bg_elevated else transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .color_text = if (source == selected) theme.colors.accent else theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.sm, .y = 3, .w = theme.spacing.sm, .h = 3 },
        }) != null) picked.* = source;
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
        .Novels => "Novels",
        .Vndb => "Visual Novels",
        .Web => "Web",
        .Anime => "Anime",
        .Drama => "Asian Drama",
        .Podcasts => "Podcasts",
        .Radio => "Radio",
        .Iptv => "Live TV",
        .Music => "Music",
        .History => "History",
        .RSS => "RSS",
        .Jellyfin => "Jellyfin",
        .Plex => "Plex",
        .Audiobooks => "Audiobooks",
        .Opds => "Reading",
        .Plugins => "Plugins",
        .Logs => "Logs",
        .Settings => "Settings",
        .AI => "Assistant",
    };
}

/// One icon vocabulary for every navigation surface — the legacy drawer rail
/// reuses this so the same destination never wears two different glyphs.
pub fn iconForTab(t: state.DrawerTab) []const u8 {
    return switch (t) {
        .Search => icons.tvg.lucide.search,
        .Downloads => icons.tvg.lucide.download,
        .TMDB => icons.tvg.lucide.film,
        .YouTube => icons.tvg.lucide.youtube,
        .Queue => icons.tvg.lucide.@"list-video",
        .Comics => icons.tvg.lucide.@"book-open",
        .Novels => icons.tvg.lucide.@"book-marked",
        .Vndb => icons.tvg.lucide.@"gamepad-2",
        .Web => icons.tvg.lucide.globe,
        .Anime => icons.tvg.lucide.tv,
        .Drama => icons.tvg.lucide.clapperboard,
        .Podcasts => icons.tvg.lucide.podcast,
        .Radio => icons.tvg.lucide.radio,
        .Iptv => icons.tvg.lucide.@"monitor-play",
        .Music => icons.tvg.lucide.music,
        .History => icons.tvg.lucide.history,
        .RSS => icons.tvg.lucide.rss,
        .Jellyfin => icons.tvg.lucide.server,
        .Plex => icons.tvg.lucide.server,
        .Audiobooks => icons.tvg.lucide.@"book-audio",
        .Opds => icons.tvg.lucide.@"library-big",
        .Plugins => icons.tvg.lucide.puzzle,
        .Logs => icons.tvg.lucide.@"scroll-text",
        .Settings => icons.tvg.lucide.settings,
        .AI => icons.tvg.lucide.@"message-square-text",
    };
}

/// Horizontal segment of sub-tabs (icon + label); updates `sel` on click.
/// Rendered inside a HORIZONTAL scroll strip with an explicit row height
/// (the posterStrip pattern): a plain box clipped trailing tabs off-screen on
/// narrow windows, and flexbox wrapping reported a collapsed min height here,
/// letting the page content render on top of the bar.
fn subTabs(tabs: []const state.DrawerTab, sel: *state.DrawerTab, id_extra: usize) void {
    subTabsOf(state.DrawerTab, tabs, sel, id_extra, tabLabel, iconForTab);
}

/// Generic body of `subTabs`, parameterised over the tab enum so the Plugins
/// route reuses the exact same strip (and its self-measuring height fix)
/// instead of a second copy that drifts. Each instantiation gets its own
/// `MeasuredH` static, which is what we want — one per strip.
fn subTabsOf(
    comptime T: type,
    tabs: []const T,
    sel: *T,
    id_extra: usize,
    comptime labelFn: fn (T) []const u8,
    comptime iconFn: fn (T) []const u8,
) void {
    // Strip height: SELF-MEASURED from the previous frame's laid-out bar
    // (plus a fallback floor). Exact-fit constants kept clipping label
    // descenders whenever the type ramp or fonts changed — the bar knows its
    // own height better than any hand-derived formula.
    const MeasuredH = struct {
        var h: f32 = 0;
    };
    const strip_h: f32 = if (MeasuredH.h > 1) MeasuredH.h else 32;
    var strip = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none, .horizontal_bar = .hide }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .w = 10, .h = strip_h },
        .max_size_content = dvui.Options.MaxSize.height(strip_h),
    });
    defer strip.deinit();

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .padding = .{ .x = theme.spacing.xs, .y = 2, .w = theme.spacing.xs, .h = 2 },
    });
    defer bar.deinit();
    // Record the bar's converged height (previous frame's min size) so the
    // strip tracks the real content height instead of clipping descenders.
    if (dvui.minSizeGet(bar.data().id)) |ms| MeasuredH.h = ms.h;

    for (tabs, 0..) |t, i| {
        const active = sel.* == t;
        const fg = if (active) theme.colors.accent else theme.colors.text_secondary;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id_extra + i + 1,
            .min_size_content = .{ .w = 0, .h = 22 },
            .background = true,
            .color_fill = if (active) theme.colors.bg_elevated else transparent,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .padding = .{ .x = theme.spacing.sm, .y = 2, .w = theme.spacing.sm, .h = 2 },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
        defer row.deinit();
        if (navRowInteract(row)) sel.* = t;
        dvui.icon(@src(), "tab", iconFn(t), .{}, .{
            .id_extra = id_extra + i + 1,
            .color_text = fg,
            .min_size_content = theme.iconSize(.sm),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{labelFn(t)}, .{
            .id_extra = id_extra + i + 1,
            .color_text = fg,
            .gravity_y = 0.5,
        });
    }
}

/// In-page tab strip for the Plugins route. Mirrors the nav-bar Plugins menu
/// (same order, same labels — both read `router.PLUGIN_TABS`).
fn pluginSubTabs() void {
    subTabsOf(router.PluginTab, &router.PLUGIN_TABS, &state.app.plugin_tab, 320, router.pluginTabLabel, pluginTabIcon);
}

fn pluginTabIcon(t: router.PluginTab) []const u8 {
    return switch (t) {
        .sources => icons.tvg.lucide.@"plug-zap",
        .suwayomi => icons.tvg.lucide.@"book-open",
        .debrid => icons.tvg.lucide.cloud,
        .trakt => icons.tvg.lucide.@"refresh-cw",
        .content => icons.tvg.lucide.puzzle,
    };
}

// ── Compact bottom tab bar (mobile) ──

fn renderBottomTabs(dense: bool) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .gravity_y = 1,
        .min_size_content = .{ .w = 0, .h = if (dense) 40 else 52 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
        .padding = .{ .x = if (dense) 2 else theme.spacing.sm, .y = if (dense) 2 else theme.spacing.xs, .w = if (dense) 2 else theme.spacing.sm, .h = if (dense) 2 else theme.spacing.xs },
    });
    defer bar.deinit();

    bottomTab(.home, "Home", icons.tvg.lucide.house, 401, dense);
    bottomTab(.watching, "Watching", icons.tvg.lucide.tv, 402, dense);
    bottomTab(.history, "History", icons.tvg.lucide.history, 403, dense);
    bottomTab(.downloads, "Downloads", icons.tvg.lucide.download, 404, dense);
    bottomTab(.player, "Player", icons.tvg.lucide.play, 405, dense);
}

fn bottomTab(r: Route, label: []const u8, icon: []const u8, id_extra: usize, dense: bool) void {
    const active = state.app.router.current == r;
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .color_fill = if (active) theme.colors.bg_elevated else transparent,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = 2, .y = if (dense) 2 else theme.spacing.xs, .w = 2, .h = if (dense) 2 else theme.spacing.xs },
    });
    defer col.deinit();
    if (navRowInteract(col)) state.app.router.navigate(r);

    const fg = if (active) theme.colors.accent else theme.colors.text_secondary;
    dvui.icon(@src(), label, icon, .{}, .{
        .id_extra = id_extra,
        .color_text = fg,
        .min_size_content = theme.iconSize(.md),
        .gravity_x = 0.5,
    });
    if (!dense) {
        var f = dvui.themeGet().font_body;
        f.size = theme.font_size.micro;
        _ = dvui.label(@src(), "{s}", .{label}, .{
            .id_extra = id_extra,
            .color_text = fg,
            .font = f,
            .gravity_x = 0.5,
        });
    } else {
        components.tipId(@src(), col.data().*, label, id_extra);
    }
}
