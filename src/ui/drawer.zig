const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const search = @import("../services/search.zig");
const transfers = @import("../services/transfers.zig");
const tmdb = @import("../services/tmdb.zig");
const youtube = @import("../services/youtube.zig");
const queue = @import("../services/queue.zig");
const watch_history = @import("../player/watch_history.zig");
const comics = @import("../services/comics.zig");
const anime = @import("../services/anime.zig");
const rss = @import("../services/rss.zig");
const jellyfin_ui = @import("jellyfin_ui.zig");
const ai_chat = @import("../services/ai_chat.zig");
const plugin_mod = @import("../services/plugins.zig");
const logs = @import("../core/logs.zig");
const components = @import("components.zig");
const settings_mod = @import("settings.zig");

var drawer_last_mouse_x: f32 = -1;

// ══════════════════════════════════════════════════════════
// Rail layout constants (production polish — Phase: drawer)
// ══════════════════════════════════════════════════════════
// Rail = fixed-geometry: a square icon button + side padding each side.
// Spacing within/between groups and the corner radius come from theme tokens
// (no inline magic numbers). Active state: a single 2px accent left indicator
// (no boxed fill). Hover: bg_hover lift. Focus: dvui's built-in ring on
// tab_index'd buttons.
const RAIL_W: f32 = 56; // fixed control width
const RAIL_SIDE_PAD: f32 = theme.spacing.sm;
const BTN_SIZE: f32 = 40; // fixed control size
const ICON_GLYPH: f32 = 22; // fixed glyph size
const ICON_GAP: f32 = theme.spacing.xs;
const GROUP_GAP: f32 = theme.spacing.lg;
const RADIUS_SM = theme.dims.rad_sm;

// Minimum drawer content width — used both as the auto-clamp floor and as the
// interactive drag minimum so they can't drift apart.
const MIN_DRAWER_W: f32 = 560;

// Transparent color used as the "no fill" baseline for icon buttons.
const TRANSPARENT: dvui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

// Bumped each time the drawer transitions closed→open so the open fade-in
// re-triggers (AnimateWidget only auto-starts on the first frame of an id).
var drawer_open_seq: usize = 0;
var drawer_was_open: bool = false;

pub fn renderDrawer() void {
    if (!state.app.drawer_open) {
        drawer_was_open = false;
        return;
    }
    if (!drawer_was_open) {
        drawer_was_open = true;
        drawer_open_seq +%= 1;
    }
    // Fade the drawer in on open — the largest chrome transition in the app
    // was an instant 560px pop while routes and toasts animate.
    var open_fade = dvui.animate(@src(), .{ .kind = .alpha, .duration = theme.motion.base, .easing = theme.motion.enter }, .{
        .id_extra = drawer_open_seq,
        .expand = .vertical,
    });
    defer open_fade.deinit();

    // Expanded mode: use huge width so it fills the content area
    const is_expanded = state.app.drawer_expanded;
    const max_w = @as(f32, @floatFromInt(@max(state.app.win_w, 400)));
    const max_drawer_w = max_w * 0.85; // Allow up to 85% of window
    const w = if (is_expanded) @as(f32, 5000.0) else blk: {
        if (state.app.drawer_width_px < MIN_DRAWER_W) state.app.drawer_width_px = MIN_DRAWER_W;
        if (state.app.drawer_width_px > max_drawer_w) state.app.drawer_width_px = max_drawer_w;
        break :blk state.app.drawer_width_px;
    };

    // Drawer container — non-expanding horizontal layout with fixed width
    // In a horizontal split layout, this takes its width and the grid takes the rest
    var container = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .vertical,
        .min_size_content = .{ .w = if (is_expanded) 10 else w, .h = 10 },
        .max_size_content = if (is_expanded) .{ .w = std.math.floatMax(f32), .h = std.math.floatMax(f32) } else .{ .w = w, .h = std.math.floatMax(f32) },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer container.deinit();

    // Resize Handle Bar (hide when expanded)
    if (!state.app.drawer_expanded) {
        var drag_bar = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .vertical,
            .min_size_content = .{ .w = 14, .h = 10 },
            .background = true,
            // Borderless: separated by fill-tier alone (bg_app sits below bg_surface).
            .color_fill = theme.colors.bg_app,
        });

        const drag_bar_rect = drag_bar.data().borderRectScale().r;

        // Grab handle: 3 small dots stacked vertically in center
        {
            const handle_color = if (state.app.is_drawer_resizing)
                theme.colors.accent
            else
                theme.colors.text_tertiary;

            {
                var spacer_top = dvui.box(@src(), .{}, .{ .expand = .vertical });
                spacer_top.deinit();
            }
            for (0..3) |dot_i| {
                var dot = dvui.box(@src(), .{}, .{
                    .id_extra = dot_i,
                    .min_size_content = .{ .w = 3, .h = 3 },
                    .background = true,
                    .color_fill = handle_color,
                    .corner_radius = dvui.Rect.all(theme.radius.pill),
                    .margin = .{ .x = 4, .y = 1, .w = 4, .h = 1 },
                    .gravity_x = 0.5,
                });
                dot.deinit();
            }
            {
                var spacer_bot = dvui.box(@src(), .{}, .{ .expand = .vertical });
                spacer_bot.deinit();
            }
        }

        // Use global mouse state for reliable drag detection — dvui.events()
        // only delivers events within the widget's clip rect, which is too narrow
        // for comfortable dragging.
        for (dvui.events()) |*e| {
            if (e.evt == .mouse) {
                // Set resize cursor when hovering anywhere near the drag bar
                if (e.evt.mouse.action == .motion) {
                    if (e.evt.mouse.p.x >= drag_bar_rect.x - 6 and e.evt.mouse.p.x <= drag_bar_rect.x + drag_bar_rect.w + 6 and
                        e.evt.mouse.p.y >= drag_bar_rect.y and e.evt.mouse.p.y <= drag_bar_rect.y + drag_bar_rect.h)
                    {
                        dvui.cursorSet(.arrow_w_e);
                    }
                }

                if (e.evt.mouse.button == .left) {
                    if (e.evt.mouse.action == .press) {
                        // Wide hit target for initial grab
                        if (e.evt.mouse.p.x >= drag_bar_rect.x - 8 and e.evt.mouse.p.x <= drag_bar_rect.x + drag_bar_rect.w + 8 and
                            e.evt.mouse.p.y >= drag_bar_rect.y and e.evt.mouse.p.y <= drag_bar_rect.y + drag_bar_rect.h)
                        {
                            state.app.is_drawer_resizing = true;
                            drawer_last_mouse_x = e.evt.mouse.p.x;
                            e.handled = true;
                        }
                    }
                }
            }
        }

        // Handle drag motion and release globally (not clipped to widget)
        if (state.app.is_drawer_resizing) {
            dvui.cursorSet(.arrow_w_e);
            const mouse_x = state.app.last_mouse_x;

            // Check for mouse release via global mouse state
            // dvui events may miss release if cursor left the widget
            for (dvui.events()) |*e| {
                if (e.evt == .mouse and e.evt.mouse.button == .left and e.evt.mouse.action == .release) {
                    state.app.is_drawer_resizing = false;
                    state.markConfigDirty();
                }
            }

            // Track drag delta using global mouse position
            if (drawer_last_mouse_x >= 0 and mouse_x != drawer_last_mouse_x) {
                const delta = drawer_last_mouse_x - mouse_x;
                var new_w = state.app.drawer_width_px + delta;
                if (new_w < MIN_DRAWER_W) new_w = MIN_DRAWER_W;
                if (new_w > max_drawer_w) new_w = max_drawer_w;
                state.app.drawer_width_px = new_w;
                drawer_last_mouse_x = mouse_x;
            }
        }

        drag_bar.deinit();
    }

    // Main Drawer Content Box — horizontal: [tab_rail | content_panel]
    var content = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer content.deinit();

    // ══════════════════════════════════════════════════════════
    // Vertical Tab Rail (left side, fixed 48px wide).
    // Panel has no corner radius (touches window edge — requirement 4).
    // ══════════════════════════════════════════════════════════
    {
        var rail = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .vertical,
            .min_size_content = .{ .w = RAIL_W, .h = 10 },
            .max_size_content = .{ .w = RAIL_W, .h = std.math.floatMax(f32) },
            .background = true,
            .color_fill = theme.colors.bg_surface,
            // One hairline at the rail|content seam — a true structural break.
            .color_border = theme.colors.border_subtle,
            .border = .{ .x = 0, .y = 0, .w = 1, .h = 0 },
            .padding = .{ .x = 0, .y = RAIL_SIDE_PAD, .w = 0, .h = RAIL_SIDE_PAD },
        });
        defer rail.deinit();

        // ── Group 1: Find & Manage ──
        // Icons come from shell.iconForTab so the rail and the page shell
        // speak one icon language (the rail used to give the same tabs
        // different glyphs — Anime even wore the app's brand mark). Ids are
        // numbered in VISUAL order: tab_index = id + 1, so keyboard focus
        // walks the rail top-to-bottom instead of jumping around.
        const shell = @import("shell.zig");
        renderRailTab(.Search, shell.iconForTab(.Search), "Search", 0);
        renderRailTab(.Downloads, shell.iconForTab(.Downloads), "Downloads", 1);
        renderRailTab(.Queue, shell.iconForTab(.Queue), "Queue", 2);
        renderRailTab(.History, shell.iconForTab(.History), "History", 3);

        railGroupGap(0);

        // ── Group 2: Sources ──
        renderRailTab(.TMDB, shell.iconForTab(.TMDB), "TMDB", 4);
        renderRailTab(.YouTube, shell.iconForTab(.YouTube), "YouTube", 5);
        renderRailTab(.Anime, shell.iconForTab(.Anime), "Anime", 6);
        // id 21 — distinct high id so concurrent tab additions merge cleanly
        // (keyboard order lands it after the sources group, which is fine).
        renderRailTab(.Drama, shell.iconForTab(.Drama), "Asian Drama", 21);
        renderRailTab(.Podcasts, shell.iconForTab(.Podcasts), "Podcasts", 7);
        renderRailTab(.Radio, shell.iconForTab(.Radio), "Radio", 8);
        renderRailTab(.Comics, shell.iconForTab(.Comics), "Comics", 9);
        // id 20 (not 10) so Novels never shares a widget id with the Web tab —
        // inserted without renumbering the rest so concurrent tab additions merge
        // cleanly. Keyboard order puts it after the sources group, which is fine.
        renderRailTab(.Novels, shell.iconForTab(.Novels), "Novels", 20);
        renderRailTab(.Web, shell.iconForTab(.Web), "Web", 10);
        renderRailTab(.RSS, shell.iconForTab(.RSS), "RSS", 11);
        renderRailTab(.Jellyfin, shell.iconForTab(.Jellyfin), "Jellyfin / Emby", 12);
        renderRailTab(.Plex, shell.iconForTab(.Plex), "Plex", 13);
        renderRailTab(.Audiobooks, shell.iconForTab(.Audiobooks), "Audiobookshelf", 17);
        renderRailTab(.Opds, shell.iconForTab(.Opds), "Reading (OPDS)", 17);

        railGroupGap(1);

        // ── Group 3: Configure ──
        renderRailTab(.AI, shell.iconForTab(.AI), "AI", 14);
        renderRailTab(.Plugins, shell.iconForTab(.Plugins), "Plugins", 15);
        renderRailTab(.Settings, shell.iconForTab(.Settings), "Settings", 16);

        // Spacer to push bottom controls to the bottom of the rail.
        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .vertical });
            spacer.deinit();
        }

        // ── Bottom controls group (Console / Expand / Close) ──
        renderBottomIcon(
            .{ .Tab = .Logs },
            icons.tvg.lucide.terminal,
            "Developer Console",
            100,
        );
        renderBottomIcon(
            .ExpandToggle,
            if (state.app.drawer_expanded) icons.tvg.lucide.@"minimize-2" else icons.tvg.lucide.@"maximize-2",
            if (state.app.drawer_expanded) "Collapse drawer" else "Expand drawer",
            101,
        );
        renderBottomIcon(
            .CloseDrawer,
            icons.tvg.lucide.@"panel-right-close",
            "Hide drawer",
            102,
        );
    }

    // ══════════════════════════════════════════════════════════
    // Content Panel (right side, fills remaining width)
    // ══════════════════════════════════════════════════════════
    {
        var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer panel.deinit();

        // Body Routing
        renderTabContent(state.app.drawer_tab);
    }
}

/// Render just the body for a given tab (no rail/chrome). Shared by the drawer
/// and the page-shell so pages reuse the exact same content renderers.
pub fn renderTabContent(tab: state.DrawerTab) void {
    switch (tab) {
        .Search => search.renderSearchContent(),
        .Downloads => transfers.renderTransfersContent(),
        .TMDB => tmdb.renderTmdbContent(),
        .YouTube => youtube.renderContent(),
        .Queue => queue.renderContent(),
        .Comics => comics.renderContent(),
        .Novels => @import("../services/novels.zig").renderContent(),
        .Web => @import("../services/browser.zig").renderContent(),
        .Anime => anime.renderContent(),
        .Drama => @import("../services/drama.zig").renderContent(),
        .Podcasts => @import("../services/podcasts.zig").renderContent(),
        .Radio => @import("../services/radio.zig").renderContent(),
        .History => renderHistoryContent(),
        .RSS => rss.renderContent(),
        .Jellyfin => jellyfin_ui.renderContent(),
        .Plex => @import("../services/plex.zig").renderContent(),
        .Audiobooks => @import("../services/audiobookshelf.zig").renderContent(),
        .Opds => @import("../services/opds.zig").renderContent(),
        .Plugins => plugin_mod.renderContent(),
        .Logs => renderLogsContent(),
        .Settings => settings_mod.renderSettingsContent(),
        // AI tab is live — renders the AI settings/config panel.
        .AI => settings_mod.renderAIContent(),
    }
}

// ══════════════════════════════════════════════════════════
// Rail Tab Helpers
// ══════════════════════════════════════════════════════════

/// Render one tab in the vertical rail.
///   - Active: 2px accent_primary left border + bg_elevated fill on the row.
///   - Hover:  bg_hover lift via dvui's color_fill_hover.
///   - Focus:  dvui draws its theme.focus ring automatically on tab_index'd buttons.
///   - Tooltip after 300ms hover via components.tip().
fn renderRailTab(tab: state.DrawerTab, icon_data: anytype, label: []const u8, id: usize) void {
    const active = state.app.drawer_tab == tab;
    const has_badge = tabHasBadge(tab);

    // Row container — sized so a 32px square button + 2px indicator fits with the rail's 8px side padding.
    // Vertical gap between rows is theme.spacing.xs (4px).
    // No boxed fill on the active row — the accent glyph + the 2px left
    // indicator carry selection (calm: state is signalled once, not boxed).
    var tab_item = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .w = RAIL_W - 2 * RAIL_SIDE_PAD, .h = BTN_SIZE },
        .margin = .{ .x = RAIL_SIDE_PAD, .y = ICON_GAP / 2, .w = RAIL_SIDE_PAD, .h = ICON_GAP / 2 },
    });
    defer tab_item.deinit();

    // 2px accent left indicator for the active tab. Reserves 2px on the inactive
    // tabs too so the icon never shifts when selection changes.
    {
        var indicator = dvui.box(@src(), .{}, .{
            .id_extra = id + 3000,
            .expand = .vertical,
            .min_size_content = .{ .w = 2, .h = 0 },
            .background = active,
            .color_fill = if (active) theme.colors.accent else TRANSPARENT,
        });
        indicator.deinit();
    }

    // 32×32 icon button. The glyph itself is min-sized to 16×16 and centered.
    // tab_index is set so keyboard nav can land here; dvui will draw its
    // built-in focus ring (uses theme.focus color) when the button has focus.
    var wd: dvui.WidgetData = undefined;
    if (dvui.buttonIcon(@src(), "", icon_data, .{}, .{}, .{
        .data_out = &wd,
        .id_extra = id + 1000,
        .color_fill = TRANSPARENT,
        .color_fill_hover = theme.colors.bg_hover,
        .color_text = if (active) theme.colors.accent else theme.colors.text_secondary,
        .border = dvui.Rect.all(0),
        .corner_radius = RADIUS_SM,
        .padding = dvui.Rect.all((BTN_SIZE - ICON_GLYPH) / 2),
        .min_size_content = .{ .w = BTN_SIZE, .h = BTN_SIZE },
        .max_size_content = .{ .w = BTN_SIZE, .h = BTN_SIZE },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .tab_index = @intCast(id + 1),
    })) {
        state.app.drawer_tab = tab;
    }
    // Tooltip appears after the user hovers for >300ms (dvui default delay).
    // All rail tabs share this source location + parent, so pass the tab id as
    // id_extra to avoid duplicate FloatingTooltip ids each frame.
    components.tipId(@src(), wd, label, id);

    // Notification dot — small, overlapping the right side of the row.
    if (has_badge) {
        const badge_color = tabBadgeColor(tab);
        var badge = dvui.box(@src(), .{}, .{
            .id_extra = id + 5000,
            .min_size_content = .{ .w = 6, .h = 6 },
            .background = true,
            .color_fill = badge_color,
            .corner_radius = dvui.Rect.all(theme.radius.pill),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
        });
        badge.deinit();
    }
}

/// 16px gap between groups in the vertical rail. NO divider line — gaps only,
/// per polish requirement #5.
fn railGroupGap(id: usize) void {
    var gap = dvui.box(@src(), .{}, .{
        .id_extra = id + 9000,
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = GROUP_GAP },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = GROUP_GAP },
    });
    gap.deinit();
}

/// Bottom-rail action identifier — distinguishes click handlers without a
/// new state struct (per project convention).
const BottomAction = union(enum) {
    Tab: state.DrawerTab,
    ExpandToggle,
    CloseDrawer,
};

/// Render one of the bottom-rail action icons. Shares the rail tab visual
/// language (hover lift, 32px button, 16px glyph, accent when active).
fn renderBottomIcon(action: BottomAction, icon_data: anytype, label: []const u8, id: usize) void {
    const is_active = switch (action) {
        .Tab => |t| state.app.drawer_tab == t,
        .ExpandToggle => state.app.drawer_expanded,
        .CloseDrawer => false,
    };

    var wd: dvui.WidgetData = undefined;
    const clicked = dvui.buttonIcon(@src(), "", icon_data, .{}, .{}, .{
        .data_out = &wd,
        .id_extra = id + 1000,
        .color_fill = TRANSPARENT,
        .color_fill_hover = theme.colors.bg_hover,
        .color_text = if (is_active) theme.colors.accent else theme.colors.text_secondary,
        .border = dvui.Rect.all(0),
        .corner_radius = RADIUS_SM,
        .padding = dvui.Rect.all((BTN_SIZE - ICON_GLYPH) / 2),
        .min_size_content = .{ .w = BTN_SIZE, .h = BTN_SIZE },
        .max_size_content = .{ .w = BTN_SIZE, .h = BTN_SIZE },
        .margin = .{ .x = RAIL_SIDE_PAD, .y = ICON_GAP / 2, .w = RAIL_SIDE_PAD, .h = ICON_GAP / 2 },
        .gravity_x = 0.5,
        .tab_index = @intCast(id + 1),
    });
    // All bottom icons share this source location + parent, so pass the icon id
    // as id_extra to avoid duplicate FloatingTooltip ids each frame.
    components.tipId(@src(), wd, label, id);

    if (clicked) {
        switch (action) {
            .Tab => |t| state.app.drawer_tab = t,
            .ExpandToggle => {
                if (state.app.drawer_expanded) {
                    state.app.drawer_expanded = false;
                    state.app.drawer_width_px = state.app.drawer_saved_width;
                } else {
                    state.app.drawer_saved_width = state.app.drawer_width_px;
                    state.app.drawer_expanded = true;
                }
            },
            .CloseDrawer => {
                state.app.drawer_open = false;
                state.app.drawer_expanded = false;
            },
        }
    }
}

fn tabHasBadge(tab: state.DrawerTab) bool {
    return switch (tab) {
        .Search => search.is_searching.load(.acquire),
        .Queue => queue.queue_count > 0,
        else => false,
    };
}

fn tabBadgeColor(tab: state.DrawerTab) dvui.Color {
    return switch (tab) {
        .Search => theme.colors.accent,
        .Queue => theme.colors.accent,
        else => theme.colors.text_secondary,
    };
}

// ══════════════════════════════════════════════════════════
// Watch History Tab
// ══════════════════════════════════════════════════════════

fn renderHistoryContent() void {
    // Masthead — sectionHeader title on the left, count + text-only Clear on
    // the right. No header fill: separated by whitespace and fill-tier.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = 0 },
        });
        defer hdr.deinit();

        components.sectionHeader("Watch History");

        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        if (watch_history.count > 0) {
            var count_buf: [16]u8 = undefined;
            const count_str = std.fmt.bufPrintZ(&count_buf, "{d}", .{watch_history.count}) catch "";
            _ = dvui.label(@src(), "{s}", .{count_str}, .{
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.md, .h = 0 },
            });

            // Destructive: two-step arm — one stray click used to wipe the
            // entire watch history irreversibly.
            if (components.confirmDangerButton(@src(), "Clear All", 0)) {
                watch_history.clearAll();
                state.showToast("Watch history cleared");
            }
        }
    }

    if (watch_history.count == 0) {
        if (watch_history.backup_available) {
            // A cleared snapshot exists — offer the one-level undo.
            if (components.emptyStateCta(icons.tvg.lucide.history, "No watch history yet", "You cleared it — the last snapshot can be restored.", "Restore cleared history")) {
                watch_history.restoreBackup();
                state.showToast("Watch history restored");
            }
        } else if (components.emptyStateCta(icons.tvg.lucide.history, "No watch history yet", "Played items will appear here", "Browse")) {
            state.navigateToTab(.TMDB);
        }
        return;
    }

    // Scrollable list
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    for (0..watch_history.count) |i| {
        const entry = &watch_history.entries[i];
        const name = entry.name[0..entry.name_len];
        const pct = @as(u8, @intFromFloat(std.math.clamp(entry.percent, 0.0, 100.0)));

        // Clickable row — click to resume playback. The old code used an
        // empty-label dvui.button as a SIBLING above the visible row, so the
        // actual click/hover target was an invisible one-line strip and
        // clicking the visible title did nothing. The row box itself is the
        // target now; its click is evaluated AFTER the children so the inner
        // remove-✕ button wins (it marks its events handled), and hover uses
        // last frame's state so the lift can be painted before the children.
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = TRANSPARENT,
            .corner_radius = RADIUS_SM,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        });
        defer row.deinit();
        if (dvui.dataGet(null, row.data().id, "_hover", bool) orelse false) {
            row.data().options.color_fill = theme.colors.bg_hover;
            row.drawBackground();
        }

        // Progress — quiet metadata, not a resting status hue.
        var pct_buf: [8]u8 = undefined;
        const pct_str = std.fmt.bufPrintZ(&pct_buf, "{d}%", .{pct}) catch "?";
        _ = dvui.label(@src(), "{s}", .{pct_str}, .{
            .id_extra = i + 5000,
            .color_text = theme.colors.text_tertiary,
            .min_size_content = .{ .w = 32, .h = 0 },
            .gravity_y = 0.5,
        });

        // Title (extract basename for nicer display)
        var display_name = name;
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| {
            if (slash + 1 < name.len) display_name = name[slash + 1 ..];
        }
        const show_len = @min(display_name.len, 50);
        var dn_buf: [64]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(display_name[0..show_len], &dn_buf)}, .{
            .id_extra = i + 6000,
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        // Remove button (processes its click before the row's, and marks it
        // handled — so removing an entry never also resumes it).
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.x, .{}, .{}, .{
            .id_extra = i + 7000,
            .color_fill = TRANSPARENT,
            .color_fill_hover = theme.colors.bg_hover,
            .color_text = theme.colors.text_secondary,
            .padding = dvui.Rect.all(theme.spacing.xs),
        })) {
            watch_history.remove(i);
            return; // list shifted
        }

        var hovered = false;
        const clicked = dvui.clicked(row.data(), .{ .hovered = &hovered });
        dvui.dataSet(null, row.data().id, "_hover", hovered);
        if (clicked) {
            // resumePlayback forces known playback (magnet → torrent engine,
            // comics → reader, else straight into mpv) instead of loadContent's
            // auto-routing, which sends a bare title (no extension/domain) to
            // the web browser tab — creates a player on a cold start, so no
            // active-player guard needed; resume position is auto-applied by
            // tryResumePosition().
            const browser = @import("../services/browser.zig");
            if (entry.link_len > 0) {
                browser.resumePlayback(entry.link[0..entry.link_len]);
                state.showToast("Resuming playback...");
            } else {
                state.showToast("Can't resume — no saved link for this item");
            }
        }
    }
}

// ══════════════════════════════════════════════════════════
// Developer Logs Tab
// ══════════════════════════════════════════════════════════

fn renderLogsContent() void {
    // Controls masthead — sectionHeader title, no header fill/border.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = 0 },
        });
        defer hdr.deinit();

        components.sectionHeader("Developer Console");

        {
            var s = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            s.deinit();
        }

        // Filter toggle — calm active state: accent glyph on a subtle
        // bg_elevated fill (no saturated pill). Reserve accent for this single
        // active affordance. buttonIcon's name string is accessibility-only
        // (never rendered), so the state cue lives in the TOOLTIP.
        var filter_wd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), if (logs.show_only_errors) "Errors" else "All", icons.tvg.lucide.eye, .{}, .{}, .{
            .data_out = &filter_wd,
            .color_fill = if (logs.show_only_errors) theme.colors.bg_elevated else TRANSPARENT,
            .color_fill_hover = theme.colors.bg_hover,
            .color_text = if (logs.show_only_errors) theme.colors.accent else theme.colors.text_secondary,
            .corner_radius = RADIUS_SM,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
            .gravity_y = 0.5,
        })) {
            logs.show_only_errors = !logs.show_only_errors;
        }
        components.tip(@src(), filter_wd, if (logs.show_only_errors) "Showing errors only — click for all logs" else "Showing all logs — click for errors only");

        // Clear — two-step arm (was an unlabeled trash icon that wiped the
        // console in one click, with no tooltip either).
        if (components.confirmDangerButton(@src(), "Clear", 0)) {
            logs.clear(); // locked — never call unlocked clearAll() from the UI thread
        }
    }

    // Log entries
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_app });
    defer scroll.deinit();
    var inner = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs } });
    defer inner.deinit();

    const count = logs.logCount();
    if (count == 0) {
        components.emptyState(icons.tvg.lucide.@"scroll-text", "No logs yet", "App activity will appear here");
        return;
    }

    // Hold the log lock across read+draw so a worker's pushLog eviction can't free
    // a text slice mid-draw (use-after-free). Validate UTF-8 — log text is
    // untrusted (mpv stderr / scraper output) and would otherwise panic dvui.
    //
    // Render only the most recent MAX_RENDER entries: the ring holds up to
    // 1024, and laying out a label per entry EVERY frame made the Logs tab the
    // most expensive page in the app while mostly drawing rows outside the
    // scroll viewport.
    const MAX_RENDER: usize = 200;
    logs.lockRead();
    defer logs.unlockRead();
    const snap = logs.logCount();

    // Apply the errors-only filter BEFORE the render window, so toggling the
    // filter shows the last 200 MATCHING entries — windowing first could show
    // an empty list while older errors still sat in the ring.
    var matching: usize = 0;
    {
        var ci: usize = 0;
        while (ci < snap) : (ci += 1) {
            if (logs.show_only_errors and !logs.getLog(ci).is_error) continue;
            matching += 1;
        }
    }
    if (matching > MAX_RENDER) {
        var note_buf: [64]u8 = undefined;
        const note = std.fmt.bufPrint(&note_buf, "Showing the last {d} of {d} entries", .{ MAX_RENDER, matching }) catch "";
        _ = dvui.label(@src(), "{s}", .{note}, .{
            .color_text = theme.colors.text_tertiary,
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = theme.spacing.xs },
        });
    }
    var to_skip = matching -| MAX_RENDER;
    var li: usize = 0;
    while (li < snap) : (li += 1) {
        const l = logs.getLog(li);
        if (logs.show_only_errors and !l.is_error) continue;
        if (to_skip > 0) {
            to_skip -= 1;
            continue;
        }
        const col = if (l.is_error) theme.colors.danger else theme.colors.text_tertiary;
        _ = dvui.labelNoFmt(@src(), @import("../core/text.zig").safeUtf8(l.text), .{}, .{
            .id_extra = li,
            .color_text = col,
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        });
    }
}
