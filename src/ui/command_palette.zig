const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");

// Ephemeral palette state (module-local, mirroring header.zig's HeaderState).
const PaletteState = struct {
    var query_buf: [128]u8 = std.mem.zeroes([128]u8);
    var query_len: usize = 0;
};

/// A navigation/chrome command. `tab` non-null = jump to that drawer tab;
/// otherwise `action` runs.
const Command = struct {
    label: []const u8,
    icon: []const u8,
    tab: ?state.DrawerTab = null,
    action: ?*const fn () void = null,
};

fn actToggleTheme() void {
    theme.cycleTheme();
    state.showToast(theme.presetName(theme.active_preset));
}
fn actShortcuts() void {
    state.app.cheatsheet_open = true;
}

fn commands() []const Command {
    const C = struct {
        const list = [_]Command{
            .{ .label = "Go: Search", .icon = icons.tvg.lucide.@"search", .tab = .Search },
            .{ .label = "Go: Downloads", .icon = icons.tvg.lucide.@"download", .tab = .Downloads },
            .{ .label = "Go: Queue", .icon = icons.tvg.lucide.@"list", .tab = .Queue },
            .{ .label = "Go: History", .icon = icons.tvg.lucide.@"clock", .tab = .History },
            .{ .label = "Go: TMDB", .icon = icons.tvg.lucide.@"film", .tab = .TMDB },
            .{ .label = "Go: YouTube", .icon = icons.tvg.lucide.@"play", .tab = .YouTube },
            .{ .label = "Go: Anime", .icon = icons.tvg.lucide.@"zap", .tab = .Anime },
            .{ .label = "Go: Comics", .icon = icons.tvg.lucide.@"image", .tab = .Comics },
            .{ .label = "Go: RSS", .icon = icons.tvg.lucide.@"rss", .tab = .RSS },
            .{ .label = "Go: Jellyfin", .icon = icons.tvg.lucide.@"server", .tab = .Jellyfin },
            .{ .label = "Go: AI", .icon = icons.tvg.lucide.@"brain", .tab = .AI },
            .{ .label = "Go: Plugins", .icon = icons.tvg.lucide.@"package", .tab = .Plugins },
            .{ .label = "Go: Settings", .icon = icons.tvg.lucide.@"settings", .tab = .Settings },
            .{ .label = "Go: Logs", .icon = icons.tvg.lucide.@"terminal", .tab = .Logs },
            .{ .label = "Cycle Theme", .icon = icons.tvg.lucide.@"palette", .action = actToggleTheme },
            .{ .label = "Keyboard Shortcuts", .icon = icons.tvg.lucide.@"info", .action = actShortcuts },
        };
    };
    return &C.list;
}

fn matches(label: []const u8, q: []const u8) bool {
    if (q.len == 0) return true;
    // case-insensitive substring (mirrors settings.zig matchesSearch intent)
    var i: usize = 0;
    outer: while (i + q.len <= label.len) : (i += 1) {
        var j: usize = 0;
        while (j < q.len) : (j += 1) {
            if (std.ascii.toLower(label[i + j]) != std.ascii.toLower(q[j])) continue :outer;
        }
        return true;
    }
    return false;
}

fn runCommand(cmd: Command) void {
    if (cmd.tab) |t| {
        state.app.drawer_open = true;
        state.app.drawer_tab = t;
    } else if (cmd.action) |a| {
        a();
    }
    state.app.command_palette_open = false;
    @memset(&PaletteState.query_buf, 0);
    PaletteState.query_len = 0;
}

pub fn render() void {
    if (!state.app.command_palette_open) return;

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.command_palette_open,
    }, .{
        .min_size_content = .{ .w = 460, .h = 360 },
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(theme.radius.lg),
    });
    defer win.deinit();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.md, .w = theme.spacing.md, .h = theme.spacing.md },
    });
    defer body.deinit();

    _ = components.searchInput(@src(), &PaletteState.query_buf, &PaletteState.query_len, "Type a command…");

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = theme.transparent });
    defer scroll.deinit();

    const q = PaletteState.query_buf[0..PaletteState.query_len];
    var any = false;
    for (commands(), 0..) |cmd, i| {
        if (!matches(cmd.label, q)) continue;
        any = true;
        if (components.listItem(@src(), i, cmd.icon, cmd.label, "")) {
            runCommand(cmd);
            return; // list/state changed
        }
    }
    if (!any) {
        components.emptyState(icons.tvg.lucide.@"search-x", "No commands", "Try a different search");
    }
}
