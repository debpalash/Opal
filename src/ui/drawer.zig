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

pub fn renderDrawer() void {
    if (!state.app.drawer_open) return;

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
        .color_fill = theme.colors.bg_drawer,
    });
    defer container.deinit();

    // Resize Handle Bar (hide when expanded)
    if (!state.app.drawer_expanded) {
        var drag_bar = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .vertical,
            .min_size_content = .{ .w = 14, .h = 10 },
            .background = true,
            // Borderless: separated by fill-tier alone (bg_app sits below bg_drawer).
            .color_fill = theme.colors.bg_app,
        });

        const drag_bar_rect = drag_bar.data().borderRectScale().r;

        // Grab handle: 3 small dots stacked vertically in center
        {
            const handle_color = if (state.app.is_drawer_resizing)
                theme.colors.accent
            else
                theme.colors.text_dim;

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
                    .corner_radius = dvui.Rect.all(99),
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
        .color_fill = theme.colors.bg_drawer,
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
        renderRailTab(.Search, icons.tvg.lucide.search, "Search", 0);
        renderRailTab(.Downloads, icons.tvg.lucide.download, "Downloads", 1);
        renderRailTab(.Queue, icons.tvg.lucide.list, "Queue", 2);
        renderRailTab(.History, icons.tvg.lucide.clock, "History", 9);

        railGroupGap(0);

        // ── Group 2: Sources ──
        renderRailTab(.TMDB, icons.tvg.lucide.film, "TMDB", 3);
        renderRailTab(.YouTube, icons.tvg.lucide.play, "YouTube", 4);
        renderRailTab(.Anime, icons.tvg.lucide.zap, "Anime", 5);
        renderRailTab(.Comics, icons.tvg.lucide.image, "Comics", 6);
        renderRailTab(.Web, icons.tvg.lucide.globe, "Web", 15);
        renderRailTab(.RSS, icons.tvg.lucide.rss, "RSS", 7);
        renderRailTab(.Jellyfin, icons.tvg.lucide.server, "Jellyfin", 8);

        railGroupGap(1);

        // ── Group 3: Configure ──
        renderRailTab(.AI, icons.tvg.lucide.brain, "AI", 14);
        renderRailTab(.Plugins, icons.tvg.lucide.package, "Plugins", 11);
        renderRailTab(.Settings, icons.tvg.lucide.settings, "Settings", 13);

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
            .color_fill = theme.colors.bg_drawer,
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
        .Web => @import("../services/browser.zig").renderContent(),
        .Anime => anime.renderContent(),
        .History => renderHistoryContent(),
        .RSS => rss.renderContent(),
        .Jellyfin => jellyfin_ui.renderContent(),
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
            .color_fill = if (active) theme.colors.accent_primary else TRANSPARENT,
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
        .color_text = if (active) theme.colors.accent_primary else theme.colors.text_secondary,
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
            .corner_radius = dvui.Rect.all(99),
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
        .color_text = if (is_active) theme.colors.accent_primary else theme.colors.text_secondary,
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
        .Search => theme.colors.accent_primary,
        .Queue => theme.colors.accent_primary,
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

            // Text-only danger — transient action, not a resting red fill.
            if (dvui.button(@src(), "Clear All", .{}, .{
                .color_fill = TRANSPARENT,
                .color_text = theme.colors.danger,
                .corner_radius = RADIUS_SM,
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .gravity_y = 0.5,
            })) {
                watch_history.clearAll();
            }
        }
    }

    if (watch_history.count == 0) {
        components.emptyState(icons.tvg.lucide.clock, "No watch history yet", "Played items will appear here");
        return;
    }

    // Scrollable list
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_drawer,
    });
    defer scroll.deinit();

    for (0..watch_history.count) |i| {
        const entry = &watch_history.entries[i];
        const name = entry.name[0..entry.name_len];
        const pct = @as(u8, @intFromFloat(std.math.clamp(entry.percent, 0.0, 100.0)));

        // Clickable row — click to resume playback. Spacing-only list: no
        // resting fill and no per-row border; hover lifts the background.
        const clicked = dvui.button(@src(), "", .{}, .{
            .id_extra = i + 10000,
            .expand = .horizontal,
            .color_fill = TRANSPARENT,
            .color_fill_hover = theme.colors.bg_hover,
            .border = dvui.Rect.all(0),
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .corner_radius = RADIUS_SM,
        });

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        });
        defer row.deinit();

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
        _ = dvui.label(@src(), "{s}", .{display_name[0..show_len]}, .{
            .id_extra = i + 6000,
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        // Remove button
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.x, .{}, .{}, .{
            .id_extra = i + 7000,
            .color_fill = TRANSPARENT,
            .color_text = theme.colors.text_secondary,
            .padding = dvui.Rect.all(theme.spacing.xs),
        })) {
            watch_history.remove(i);
            return; // list shifted
        }

        if (clicked) {
            // Load into active player — resume position is auto-applied by tryResumePosition()
            if (state.app.active_player_idx < state.app.players.items.len) {
                const browser = @import("../services/browser.zig");
                browser.loadContent(name);
                state.showToast("Resuming playback...");
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
        // active affordance.
        if (dvui.buttonIcon(@src(), if (logs.show_only_errors) "Errors" else "All", icons.tvg.lucide.eye, .{}, .{}, .{
            .color_fill = if (logs.show_only_errors) theme.colors.bg_elevated else TRANSPARENT,
            .color_text = if (logs.show_only_errors) theme.colors.accent_primary else theme.colors.text_secondary,
            .corner_radius = RADIUS_SM,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
            .gravity_y = 0.5,
        })) {
            logs.show_only_errors = !logs.show_only_errors;
        }

        // Clear button — text-only danger.
        if (dvui.buttonIcon(@src(), "Clear", icons.tvg.lucide.@"trash-2", .{}, .{}, .{
            .color_fill = TRANSPARENT,
            .color_text = theme.colors.danger,
            .corner_radius = RADIUS_SM,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
        })) {
            logs.clearAll();
        }
    }

    // Log entries
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_app });
    defer scroll.deinit();
    var inner = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs } });
    defer inner.deinit();

    const count = logs.logCount();
    if (count == 0) {
        _ = dvui.label(@src(), "No logs yet", .{}, .{
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = theme.spacing.xl, .w = 0, .h = 0 },
        });
        return;
    }

    var li: usize = 0;
    while (li < count) : (li += 1) {
        const l = logs.getLog(li);
        if (logs.show_only_errors and !l.is_error) continue;
        const col = if (l.is_error) theme.colors.danger else theme.colors.text_dim;
        _ = dvui.labelNoFmt(@src(), l.text, .{}, .{
            .id_extra = li,
            .color_text = col,
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        });
    }
}
