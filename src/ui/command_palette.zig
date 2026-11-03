const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const router = @import("../core/router.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const colors = @import("color_compat.zig");

const PaletteState = struct {
    var query_buf: [128]u8 = @splat(0);
    var selected: usize = 0;
    var want_focus = true;
};
var dialog_rect: dvui.Rect.Physical = .{};
var hint_rect: dvui.Rect.Physical = .{};
var title_rect: dvui.Rect.Physical = .{};
pub fn boundsForTest() struct { dialog: dvui.Rect.Physical, hint: dvui.Rect.Physical, title: dvui.Rect.Physical } {
    return .{ .dialog = dialog_rect, .hint = hint_rect, .title = title_rect };
}

const Command = struct {
    label: []const u8,
    icon: []const u8,
    keywords: []const u8 = "",
    tab: ?state.DrawerTab = null,
    route: ?router.Route = null,
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
            .{ .label = "Home", .icon = icons.tvg.lucide.house, .route = .home },
            .{ .label = "Agents", .icon = icons.tvg.lucide.bot, .route = .agents },
            .{ .label = "All content", .keywords = "search", .icon = icons.tvg.lucide.search, .tab = .Search },
            .{ .label = "Watching", .icon = icons.tvg.lucide.tv, .route = .watching },
            .{ .label = "Movies & TV", .keywords = "tmdb films television", .icon = icons.tvg.lucide.film, .tab = .TMDB },
            .{ .label = "YouTube", .icon = icons.tvg.lucide.play, .tab = .YouTube },
            .{ .label = "Anime", .icon = icons.tvg.lucide.zap, .tab = .Anime },
            .{ .label = "Asian Drama", .icon = icons.tvg.lucide.clapperboard, .tab = .Drama },
            .{ .label = "Live TV", .keywords = "iptv", .icon = icons.tvg.lucide.tv, .tab = .Iptv },
            .{ .label = "Podcasts", .icon = icons.tvg.lucide.mic, .tab = .Podcasts },
            .{ .label = "Radio", .icon = icons.tvg.lucide.radio, .tab = .Radio },
            .{ .label = "Music", .icon = icons.tvg.lucide.music, .tab = .Music },
            .{ .label = "Comics", .icon = icons.tvg.lucide.image, .tab = .Comics },
            .{ .label = "Novels", .icon = icons.tvg.lucide.book, .tab = .Novels },
            .{ .label = "Visual Novels", .keywords = "vndb", .icon = icons.tvg.lucide.book, .tab = .Vndb },
            .{ .label = "RSS", .icon = icons.tvg.lucide.rss, .tab = .RSS },
            .{ .label = "Browser", .icon = icons.tvg.lucide.globe, .tab = .Web },
            .{ .label = "Wallpapers", .icon = icons.tvg.lucide.image, .tab = .Wallpapers },
            .{ .label = "Connect", .icon = icons.tvg.lucide.plug, .route = .connect },
            .{ .label = "Downloads", .icon = icons.tvg.lucide.download, .tab = .Downloads },
            .{ .label = "Queue", .icon = icons.tvg.lucide.list, .tab = .Queue },
            .{ .label = "History", .icon = icons.tvg.lucide.clock, .tab = .History },
            .{ .label = "Jellyfin", .icon = icons.tvg.lucide.server, .tab = .Jellyfin },
            .{ .label = "AI", .icon = icons.tvg.lucide.brain, .tab = .AI },
            .{ .label = "Plugins", .icon = icons.tvg.lucide.package, .tab = .Plugins },
            .{ .label = "Settings", .icon = icons.tvg.lucide.settings, .tab = .Settings },
            .{ .label = "System and logs", .icon = icons.tvg.lucide.terminal, .tab = .Logs },
            .{ .label = "Cycle theme", .icon = icons.tvg.lucide.palette, .action = actToggleTheme },
            .{ .label = "Keyboard shortcuts", .icon = icons.tvg.lucide.info, .action = actShortcuts },
        };
    };
    return &C.list;
}

fn matches(label: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > label.len) return false;
    for (0..label.len - query.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(label[i..][0..query.len], query)) return true;
    }
    return false;
}

pub fn close() void {
    state.app.command_palette_open = false;
    @memset(&PaletteState.query_buf, 0);
    PaletteState.selected = 0;
    PaletteState.want_focus = true;
}

pub fn toggle() void {
    const opening = !state.app.command_palette_open;
    close();
    state.app.command_palette_open = opening;
}

fn runCommand(cmd: Command) void {
    if (cmd.tab) |tab| {
        if (tab == .Search) @import("../services/search.zig").changeSearchScope(.all);
        state.navigateToTabNow(tab);
    } else if (cmd.route) |route| {
        if (route == .home) @import("home.zig").showOverview();
        state.app.router.navigate(route);
    } else if (cmd.action) |action| {
        action();
    }
    close();
    dvui.refresh(null, @src(), null);
}

pub fn render() void {
    if (!state.app.command_palette_open) return;
    const dialog_size = theme.fitWindowSize(.{ .w = 480, .h = 420 }, .{ .w = 240, .h = 200 });
    var win = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &state.app.command_palette_open }, .{
        .min_size_content = dialog_size,
        .max_size_content = .{ .w = dialog_size.w, .h = dialog_size.h },
        .color_fill = colors.wrap(theme.colors.bg_surface),
        .color_border = colors.wrap(theme.colors.border_subtle),
        .border = dvui.Rect.all(1),
        .corners = dvui.CornerRect.all(theme.radius.lg),
    });
    defer win.deinit();
    if (@import("builtin").is_test) dialog_rect = win.data().borderRectScale().r;
    const opening = dvui.firstFrame(win.data().id) or PaletteState.want_focus;
    if (opening) {
        @memset(&PaletteState.query_buf, 0);
        PaletteState.selected = 0;
    }
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(theme.spacing.md) });
    defer body.deinit();
    {
        var heading = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer heading.deinit();
        var words = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        var title_data: dvui.WidgetData = undefined;
        _ = dvui.label(@src(), "Go to a page", .{}, .{ .data_out = &title_data, .color_text = colors.wrap(theme.colors.text_primary) });
        if (@import("builtin").is_test) title_rect = title_data.borderRectScale().r;
        var hint_data: dvui.WidgetData = undefined;
        _ = dvui.label(@src(), "Arrow keys to move · Enter to open · Esc to close", .{}, .{
            .data_out = &hint_data,
            .color_text = colors.wrap(theme.colors.text_secondary),
            .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
        });
        if (@import("builtin").is_test) hint_rect = hint_data.borderRectScale().r;
        words.deinit();
        if (components.iconButton(@src(), icons.tvg.lucide.x, "Close command palette (Esc)", false)) {
            close();
            return;
        }
    }

    // Arrow keys move through results rather than moving the text cursor.
    var step: i32 = 0;
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;
        const key = event.evt.key;
        if ((key.action == .down or key.action == .repeat) and !key.mod.control() and !key.mod.command() and !key.mod.alt() and (key.code == .up or key.code == .down)) {
            step += if (key.code == .up) @as(i32, -1) else 1;
            event.handled = true;
        }
    }
    var entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &PaletteState.query_buf }, .placeholder = "Search pages and actions…" }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 24 },
        .padding = dvui.Rect.all(theme.spacing.sm),
        .color_fill = colors.wrap(theme.colors.bg_elevated),
        .color_text = colors.wrap(theme.colors.text_primary),
        .color_border = colors.wrap(theme.colors.border_subtle),
        .border = dvui.Rect.all(1),
        .corners = theme.dims.rad_md,
    });
    if (opening) {
        dvui.focusWidget(entry.data().id, null, null);
        PaletteState.want_focus = false;
    }
    const entered = entry.enter_pressed;
    const changed = entry.text_changed;
    const query = std.mem.trim(u8, entry.textGet(), " \t");
    entry.deinit();

    var filtered: [commands().len]usize = undefined;
    var count: usize = 0;
    for (commands(), 0..) |cmd, i| {
        if (matches(cmd.label, query) or (cmd.keywords.len > 0 and matches(cmd.keywords, query))) {
            filtered[count] = i;
            count += 1;
        }
    }
    if (changed or PaletteState.selected >= count) PaletteState.selected = 0;
    if (count > 0 and step != 0) PaletteState.selected = @intCast(@mod(@as(i32, @intCast(PaletteState.selected)) + step, @as(i32, @intCast(count))));
    if (entered and count > 0) {
        runCommand(commands()[filtered[PaletteState.selected]]);
        return;
    }
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = @max(40, dialog_size.h - 132) },
            .color_fill = colors.wrap(theme.transparent),
        });
        defer scroll.deinit();
        if (changed or opening) scroll.si.scrollToOffset(.vertical, 0);
        for (filtered[0..count], 0..) |index, position| {
            const cmd = commands()[index];
            const selected = position == PaletteState.selected;
            if (components.selectableListItem(@src(), index, cmd.icon, cmd.label, "", .{ .selected = selected, .reveal = selected and step != 0 })) {
                runCommand(cmd);
                return;
            }
        }
        if (count == 0) components.emptyState(icons.tvg.lucide.@"search-x", "No matching commands", "Try a page name, such as Movies or Downloads.");
    }
}
