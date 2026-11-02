//! Drive the real global shortcuts and palette with native DVUI events.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const palette = @import("command_palette.zig");
const input = @import("input.zig");
const theme = @import("theme.zig");
const io = @import("../core/io_global.zig");
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
                try key(.left_bracket, .lcommand);
            },
            .forward => {
                dvui.focusWidget(background_id, null, null);
                try key(.right_bracket, .lcommand);
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
}
