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
        if (fullscreen) {
            hide_eligible = true;
        } else {
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
    }
    // Fully immersive once the fade completes (fullscreen skips the fade).
    const immersive = hide_eligible and (fullscreen or idle_ms >= autohide.DEFAULT_THRESHOLD_MS + autohide.FADE_MS);

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
        renderTopNav(compact);
        dvui.alphaSet(prev_alpha);
    }

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
                else => 0,
            };
            var page_fade = dvui.animate(@src(), .{ .kind = .alpha, .duration = theme.motion.base, .easing = theme.motion.enter }, .{
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

    // Compact: bottom tab bar (mobile-style) below everything — also hidden in
    // immersive playback so the video reaches the bottom edge.
    if (compact and !immersive) renderBottomTabs();

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


fn renderTopNav(compact: bool) void {
    // Transparent title bar — the nav floats over the app background (no solid
    // fill) for a lighter, content-focused feel; a hairline bottom border keeps
    // it separated from the page.
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 30 },
        .background = true,
        .color_fill = transparent,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = theme.spacing.md, .y = 1, .w = theme.spacing.md, .h = 1 },
    });
    defer bar.deinit();

    // Brand — clickable: always returns to the Home overview (even out of
    // the chat transcript, which otherwise owns the Home route while a
    // conversation exists).
    {
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

    // Back / forward — disabled (dimmed, inert) when there's no history in
    // that direction. Previously canGoBack() was passed as `active`, which
    // painted Back as a toggled-on accent chip whenever ANY history existed —
    // the same visual language the route buttons use for "current page".
    if (components.iconButtonEx(@src(), icons.tvg.lucide.@"chevron-left", "Back", false, state.app.router.canGoBack())) {
        state.app.router.goBack();
    }
    if (components.iconButtonEx(@src(), icons.tvg.lucide.@"chevron-right", "Forward", false, state.app.router.canGoForward())) {
        state.app.router.goForward();
    }

    // Primary nav links — hidden in compact (bottom tab bar takes over).
    if (!compact) {
        // Home / Downloads / Queue / History are icon-only (tooltip on hover);
        // the content destinations keep their labels.
        navLink(.home, "Home", icons.tvg.lucide.house, 1, true);
        navLink(.search, "Search", icons.tvg.lucide.search, 2, false);
        navLink(.browse, "Browse", icons.tvg.lucide.compass, 3, false);
        navLink(.watching, "Watching", icons.tvg.lucide.tv, 7, false);
        navLink(.downloads, "Downloads", icons.tvg.lucide.download, 4, true);
        navLink(.queue, "Queue", icons.tvg.lucide.@"list-video", 5, true);
        navLink(.history, "History", icons.tvg.lucide.history, 6, true);
    }

    omnibox();

    // Donate chip — the omnibox above is capped narrower to make room for it.
    if (!compact) header.donateButton();

    // Right-side actions (icon-only). The former "Assistant" button opened the
    // AI/Voice SETTINGS page (renderAIContent) — that now lives in Settings ›
    // AI & Voice, so it's dropped from the primary nav. AI chat is reachable
    // via the omnibox ('>' or trailing '?') — the conversation lives on Home.
    if (components.iconButton(@src(), icons.tvg.lucide.play, "Now playing", state.app.router.current == .player)) {
        state.app.router.navigate(.player);
    }
    if (components.iconButton(@src(), icons.tvg.lucide.@"scroll-text", "Logs & Plugins", state.app.router.current == .system)) {
        state.app.router.navigate(.system);
    }
    if (components.iconButton(@src(), icons.tvg.lucide.settings, "Settings", state.app.router.current == .settings)) {
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
            renderOverflowItems();
        }
    }
}

/// Body of the top-nav overflow menu. Each item is a leaf menuItemLabel; dvui
/// closes the floating menu on activation.
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
fn omnibox() void {
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.magnet_buf },
        .placeholder = "Ask, search, or paste a link…",
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 120, .h = 26 },
        // Capped at 640 (was 1000) to free nav width for the Donate chip.
        .max_size_content = .{ .w = 640, .h = 26 },
        .margin = .{ .x = theme.spacing.md, .y = 0, .w = 4, .h = 0 },
        .color_fill = theme.colors.bg_elevated,
        .color_border = theme.colors.border_subtle,
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
        if (components.iconButton(@src(), voice_icon, "Voice / conversation mode", voice.conversation_active.load(.acquire))) {
            voice.toggleConversation();
        }
    }
    {
        var gap = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = theme.spacing.sm, .h = 0 } });
        gap.deinit();
    }

    if (!entered) return;
    if (len == 0) return;
    const text = state.app.magnet_buf[0..len];

    // Leading '?' → conversational memory search over your own watch history
    // ("?the rainy argument scene") — seeds the matched title into multi-source
    // search. (Trailing '?' is AI chat, handled below.)
    if (text[0] == '?' and len > 1) {
        search_mod.memorySearch(text[1..]);
        @memset(&state.app.magnet_buf, 0);
        return;
    }

    if (isMedia(text)) {
        header.submitInput(); // loads into player (clears buffer); helper routes the player nav
        return;
    }
    if (text[0] == '>' or text[len - 1] == '?') {
        header.submitInput(); // → AI chat
        // The conversation renders on HOME (home.zig chat mode); the
        // .assistant route hosts AI SETTINGS, not the chat.
        state.app.router.navigate(.home);
        return;
    }
    // Default: unified search across every source.
    search_mod.submitQuery(text);
    @memset(&state.app.magnet_buf, 0);
    state.app.router.navigate(.search);
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
            subTabs(&.{ .TMDB, .YouTube, .Anime, .Podcasts, .Radio, .Comics, .Web, .RSS, .Jellyfin, .Plex }, &state.app.browse_source, 100);
            drawer.renderTabContent(state.app.browse_source);
        },
        .watching => @import("../services/tv_library.zig").renderContent(),
        .downloads => drawer.renderTabContent(.Downloads),
        .queue => drawer.renderTabContent(.Queue),
        .history => drawer.renderTabContent(.History),
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
        .Podcasts => "Podcasts",
        .Radio => "Radio",
        .History => "History",
        .RSS => "RSS",
        .Jellyfin => "Jellyfin",
        .Plex => "Plex",
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
        .Web => icons.tvg.lucide.globe,
        .Anime => icons.tvg.lucide.tv,
        .Podcasts => icons.tvg.lucide.podcast,
        .Radio => icons.tvg.lucide.radio,
        .History => icons.tvg.lucide.history,
        .RSS => icons.tvg.lucide.rss,
        .Jellyfin => icons.tvg.lucide.server,
        .Plex => icons.tvg.lucide.server,
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
        dvui.icon(@src(), "tab", iconForTab(t), .{}, .{
            .id_extra = id_extra + i + 1,
            .color_text = fg,
            .min_size_content = theme.iconSize(.sm),
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
    bottomTab(.downloads, "Downloads", icons.tvg.lucide.download, 404);
    bottomTab(.player, "Player", icons.tvg.lucide.play, 405);
}

fn bottomTab(r: Route, label: []const u8, icon: []const u8, id_extra: usize) void {
    const active = state.app.router.current == r;
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .color_fill = if (active) theme.colors.bg_elevated else transparent,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = theme.spacing.xs, .h = theme.spacing.xs },
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
    var f = dvui.themeGet().font_body;
    f.size = theme.font_size.micro;
    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id_extra,
        .color_text = fg,
        .font = f,
        .gravity_x = 0.5,
    });
}
