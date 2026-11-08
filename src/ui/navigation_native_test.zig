//! Drive the real global shortcuts and palette with native DVUI events.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const palette = @import("command_palette.zig");
const input = @import("input.zig");
const theme = @import("theme.zig");
const io = @import("../core/io_global.zig");
const components = @import("components.zig");
const builtin = @import("builtin");
/// Back/Forward are bound to the platform "ctrl/cmd" keybind: Cmd on macOS,
/// Ctrl elsewhere. Sending Cmd on Linux/Windows is not the shortcut there.
const history_mod: dvui.enums.Mod = if (builtin.os.tag == .macos) .lcommand else .lcontrol;
const Case = enum { open_control, open_command, close_shortcut, escape, downloads, movies, arrows, no_results, reopen, back, forward };
var current: Case = .open_control;
var frame: usize = 0;
var background_id: ?dvui.Id = null;
var background_text: [32]u8 = @splat(0);

fn setup() !void {
    frame = 0;
    background_id = null;
    @memset(&background_text, 0);
    state.app.page_shell_enabled = true;
    state.app.router = .{};
    state.app.drawer_open = false;
    state.app.settings_open = false;
    state.app.cheatsheet_open = false;
    state.app.browse_source = .YouTube;
    state.pending_nav.store(0, .release);
    state.app.command_palette_open = switch (current) {
        .open_control, .open_command, .back, .forward => false,
        else => true,
    };
    if (current == .back or current == .forward) {
        state.app.router.navigate(.downloads);
        state.app.router.navigate(.settings);
        if (current == .forward) state.app.router.goBack();
    }
}

fn key(code: dvui.enums.Key, mod: dvui.enums.Mod) !void {
    _ = try dvui.currentWindow().addEventKey(.{ .code = code, .action = .down, .mod = mod });
}

fn draw() !void {
    @import("components.zig").beginFrame();
    if (frame == 2) {
        switch (current) {
            .open_control, .open_command => {
                dvui.focusWidget(background_id, null, null);
                try key(.k, if (current == .open_command) .lcommand else .lcontrol);
            },
            .close_shortcut => try key(.k, .lcontrol),
            .escape => try key(.escape, .none),
            .downloads => _ = try dvui.currentWindow().addEventText(.{ .text = "downloads" }),
            .movies => _ = try dvui.currentWindow().addEventText(.{ .text = "movies" }),
            .arrows => try key(.down, .none),
            .no_results => _ = try dvui.currentWindow().addEventText(.{ .text = "zzzz-no-command" }),
            .reopen => _ = try dvui.currentWindow().addEventText(.{ .text = "downloads" }),
            .back => {
                dvui.focusWidget(background_id, null, null);
                try key(.left_bracket, history_mod);
            },
            .forward => {
                dvui.focusWidget(background_id, null, null);
                try key(.right_bracket, history_mod);
            },
        }
    }
    if (frame == 3) switch (current) {
        .downloads, .movies, .arrows, .no_results => try key(.enter, .none),
        .reopen => try key(.escape, .none),
        else => {},
    };
    if (current == .reopen and frame == 4) try key(.k, .lcontrol);
    if (current == .reopen and frame == 5) try key(.enter, .none);
    input.processGlobalInputs();

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_app) });
    defer page.deinit();
    var entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &background_text }, .placeholder = "Background field" }, .{ .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary) });
    background_id = entry.data().id;
    entry.deinit();
    palette.render();
    state.applyPendingNav();
    if (frame >= 5 and state.app.command_palette_open) {
        const bounds = palette.boundsForTest();
        try std.testing.expect(bounds.hint.h > 0);
        try std.testing.expect(bounds.hint.y >= bounds.title.y + bounds.title.h);
        try std.testing.expect(bounds.hint.y + bounds.hint.h <= bounds.dialog.y + bounds.dialog.h);
    }

    if (frame >= 2) switch (current) {
        .open_control, .open_command => {
            try std.testing.expect(state.app.command_palette_open);
            try std.testing.expect(dvui.focusedWidgetId() != null);
            try std.testing.expect(dvui.focusedWidgetId() != background_id);
        },
        .close_shortcut, .escape => try std.testing.expect(!state.app.command_palette_open),
        .downloads => if (frame >= 4) {
            try std.testing.expectEqual(.downloads, state.app.router.current);
            try std.testing.expect(!state.app.command_palette_open);
        },
        .movies => if (frame >= 4) {
            try std.testing.expectEqual(.browse, state.app.router.current);
            try std.testing.expectEqual(.TMDB, state.app.browse_source);
        },
        .arrows => if (frame >= 4) try std.testing.expectEqual(.agents, state.app.router.current),
        .no_results => if (frame >= 4) {
            try std.testing.expectEqual(.home, state.app.router.current);
            try std.testing.expect(state.app.command_palette_open);
        },
        .reopen => if (frame >= 6) try std.testing.expectEqual(.home, state.app.router.current),
        .back => try std.testing.expectEqual(.downloads, state.app.router.current),
        .forward => try std.testing.expectEqual(.settings, state.app.router.current),
    };
    frame += 1;
}

fn cleanup() void {
    state.app.command_palette_open = false;
    state.app.router = .{};
    state.pending_nav.store(0, .release);
}

pub fn run() !void {
    for (std.meta.tags(Case)) |case| {
        if (io.getenv("OPAL_NAV_CASE")) |filter| if (!std.mem.eql(u8, filter, @tagName(case))) continue;
        current = case;
        for ([_]u32{ 640, 1360 }) |width| {
            var name: [80]u8 = undefined;
            try @import("native_capture.zig").capture(width, 800, try std.fmt.bufPrint(&name, "navigation-{s}", .{@tagName(case)}), setup, draw, cleanup);
        }
    }
    try runSeeded();
}

fn runSeeded() !void {
    const alloc = @import("../core/alloc.zig").allocator;
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-seeded-navigation", .persist_window_geometry = false, .size = .{ .w = 1000, .h = 750 }, .vsync = false, .title = "Opal seeded command navigation", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    const old_router = state.app.router;
    const old_source = state.app.browse_source;
    const old_drawer = state.app.drawer_tab;
    const old_drawer_open = state.app.drawer_open;
    defer {
        palette.close();
        state.app.router = old_router;
        state.app.browse_source = old_source;
        state.app.drawer_tab = old_drawer;
        state.app.drawer_open = old_drawer_open;
    }
    const Target = struct { query: []const u8, route: @import("../core/router.zig").Route, tab: ?state.DrawerTab = null };
    const targets = [_]Target{
        .{ .query = "Home", .route = .home },                          .{ .query = "Agents", .route = .agents },
        .{ .query = "All content", .route = .search },                 .{ .query = "Watching", .route = .watching },
        .{ .query = "Movies & TV", .route = .browse, .tab = .TMDB },   .{ .query = "YouTube", .route = .browse, .tab = .YouTube },
        .{ .query = "Anime", .route = .browse, .tab = .Anime },        .{ .query = "Asian Drama", .route = .browse, .tab = .Drama },
        .{ .query = "Live TV", .route = .browse, .tab = .Iptv },       .{ .query = "Podcasts", .route = .browse, .tab = .Podcasts },
        .{ .query = "Radio", .route = .browse, .tab = .Radio },        .{ .query = "Music", .route = .browse, .tab = .Music },
        .{ .query = "Comics", .route = .browse, .tab = .Comics },      .{ .query = "Novels", .route = .browse, .tab = .Novels },
        .{ .query = "Visual Novels", .route = .browse, .tab = .Vndb }, .{ .query = "RSS", .route = .browse, .tab = .RSS },
        .{ .query = "Browser", .route = .browse, .tab = .Web },        .{ .query = "Wallpapers", .route = .browse, .tab = .Wallpapers },
        .{ .query = "Connect", .route = .connect },                    .{ .query = "Downloads", .route = .downloads },
        .{ .query = "Queue", .route = .queue },                        .{ .query = "History", .route = .history },
        .{ .query = "Jellyfin", .route = .browse, .tab = .Jellyfin },  .{ .query = "AI", .route = .assistant },
        .{ .query = "Plugins", .route = .plugins },                    .{ .query = "Settings", .route = .settings },
        .{ .query = "System and logs", .route = .system },
    };
    var rng = std.Random.DefaultPrng.init(20261103);
    var order: [targets.len]usize = undefined;
    for (&order, 0..) |*slot, i| slot.* = i;
    for (0..order.len) |i| std.mem.swap(usize, &order[i], &order[rng.random().uintLessThan(usize, order.len)]);
    for (0..108) |i| {
        const target = targets[order[i % order.len]];
        for (0..3) |stage| {
            try window.begin(@as(i128, @intCast(i * 3 + stage + 1)) * 16_666_667);
            errdefer _ = window.end(.{}) catch null;
            components.beginFrame();
            if (stage == 0) palette.toggle();
            if (stage == 1) _ = try window.addEventText(.{ .text = target.query });
            if (stage == 2) _ = try window.addEventKey(.{ .code = .enter, .action = .down, .mod = .none });
            palette.render();
            state.applyPendingNav();
            _ = try window.end(.{});
        }
        try std.testing.expect(!state.app.command_palette_open);
        try std.testing.expectEqual(target.route, state.app.router.current);
        if (target.tab) |tab| try std.testing.expectEqual(tab, state.app.browse_source);
    }
    std.debug.print("Seeded navigation: 108 keyboard selections across 27 destinations, no captures\n", .{});
}
