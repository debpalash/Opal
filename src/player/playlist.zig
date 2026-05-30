const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("icons");

var filter_buf: [128]u8 = std.mem.zeroes([128]u8);

const PlaylistTab = enum { playlist, queue };
var active_tab: PlaylistTab = .queue;

pub fn renderDrawer() void {
    if (!state.app.playlist_drawer_open) return;

    // Use same width as main drawer for consistency
    const w = state.app.drawer_width_px;
    
    var drawer_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = theme.colors.bg_drawer,
        .expand = .vertical,
        .min_size_content = .{ .w = 350, .h = 0 },
        .max_size_content = .{ .w = w, .h = std.math.floatMax(f32) },
        .border = dvui.Rect{ .x=1, .y=0, .w=0, .h=0 },
        .color_border = theme.colors.border_drawer,
        .box_shadow = .{ .color = dvui.Color{ .r=0, .g=0, .b=0, .a=160 }, .offset = .{ .x=-2, .y=0 }, .fade = 16.0 },
    });
    defer drawer_box.deinit();

    // Header with tabs
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = dvui.Rect.all(10),
            .background = true,
            .color_fill = theme.colors.bg_header,
            .color_border = theme.colors.border_drawer,
            .border = .{ .x=0, .y=0, .w=0, .h=1 },
        });
        defer head.deinit();

        // Queue tab
        if (dvui.button(@src(), "Queue", .{}, .{
            .color_fill = if (active_tab == .queue) theme.colors.accent else dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
            .color_text = if (active_tab == .queue) theme.colors.bg_header else theme.colors.text_muted,
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
            .corner_radius = theme.dims.rad_sm,
            .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
        })) {
            active_tab = .queue;
        }

        // Playlist tab
        if (dvui.button(@src(), "Playlist", .{}, .{
            .color_fill = if (active_tab == .playlist) theme.colors.accent else dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
            .color_text = if (active_tab == .playlist) theme.colors.bg_header else theme.colors.text_muted,
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
            .corner_radius = theme.dims.rad_sm,
        })) {
            active_tab = .playlist;
        }

        { var s = dvui.box(@src(), .{}, .{ .expand = .horizontal }); s.deinit(); }
        
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"x", .{}, .{}, theme.optIconBtnDanger())) {
            state.app.playlist_drawer_open = false;
        }
    }

    switch (active_tab) {
        .queue => renderQueueTab(),
        .playlist => renderPlaylistTab(),
    }
}

// ══════════════════════════════════════════════════════════
// Queue Tab (extracted videos from yt-dlp)
// ══════════════════════════════════════════════════════════

fn renderQueueTab() void {
    const queue_mod = @import("../services/queue.zig");
    queue_mod.renderContent();
}

// ══════════════════════════════════════════════════════════
// Playlist Tab (M3U / IPTV channels)
// ══════════════════════════════════════════════════════════

fn renderPlaylistTab() void {
    // Empty state
    if (state.app.playlist == null) {
        var empty_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .gravity_x = 0.5, .gravity_y = 0.5, .padding = dvui.Rect.all(24) });
        _ = dvui.label(@src(), "No playlist loaded.", .{}, .{ .color_text = theme.colors.text_muted });
        _ = dvui.label(@src(), "Drop an .m3u file or folder here.", .{}, .{ .color_text = theme.colors.text_muted });
        empty_box.deinit();
        return;
    }

    const pl = state.app.playlist.?;

    // Filter bar
    {
        var filter_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        });
        defer filter_row.deinit();
        
        dvui.icon(@src(), "", icons.tvg.lucide.@"search", .{}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5, .margin = .{ .x=0, .y=0, .w=6, .h=0 } });
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &filter_buf } }, .{
            .expand = .horizontal,
            .color_fill = theme.colors.bg_input,
            .color_border = theme.colors.border_input,
            .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
        });
        te.deinit();
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .margin = dvui.Rect.all(12) });
    defer scroll.deinit();

    var list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer list.deinit();

    // Get filter text
    const filter_len = std.mem.indexOfScalar(u8, &filter_buf, 0) orelse 0;
    const filter_text = filter_buf[0..filter_len];

    // Get current player's URL for active highlighting
    var active_url: []const u8 = "";
    if (state.app.active_player_idx < state.app.players.items.len) {
        const ap = state.app.players.items[state.app.active_player_idx];
        active_url = ap.source_url[0..ap.source_url_len];
    }

    var rendered: usize = 0;
    for (pl.entries.items, 0..) |entry, i| {
        // Filter: skip entries that don't match
        if (filter_len > 0) {
            const title_match = caseContains(entry.title, filter_text);
            const group_match = if (entry.group) |g| caseContains(g, filter_text) else false;
            if (!title_match and !group_match) continue;
        }

        // Cap visible items for performance
        if (rendered >= 500) {
            _ = dvui.label(@src(), "... and more (refine filter)", .{}, .{ .color_text = theme.colors.text_muted });
            break;
        }
        rendered += 1;

        var row = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        defer row.deinit();

        const group_str = entry.group orelse "Unknown";
        var label_buf: [128]u8 = undefined;
        v_title_trunc: {
            const safe_len = @min(entry.title.len, 80);
            const safe_grp = @min(group_str.len, 30);
            const res = std.fmt.bufPrintZ(&label_buf, "{s}\n{s}", .{
                entry.title[0..safe_len],
                group_str[0..safe_grp]
            }) catch {
                label_buf[0] = 0;
                break :v_title_trunc;
            };
            _ = res;
        }

        const is_active = active_url.len > 0 and std.mem.eql(u8, active_url, entry.url);
        const bg_color = if (is_active) theme.colors.accent else theme.colors.bg_card;
        const fg_color = if (is_active) theme.colors.bg_header else theme.colors.text_main;
        
        const clicked = dvui.button(@src(), label_buf[0..std.mem.indexOfScalar(u8, &label_buf, 0) orelse 0], .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_fill = bg_color,
            .color_text = fg_color,
            .corner_radius = theme.dims.rad_sm,
            .gravity_x = 0.0,
        });

        if (clicked and state.app.active_player_idx < state.app.players.items.len) {
            const p = state.app.players.items[state.app.active_player_idx];
            p.current_torrent_id = -1;
            p.is_torrent = false;
            
            const copy_len = @min(entry.url.len, p.source_url.len - 1);
            @memcpy(p.source_url[0..copy_len], entry.url[0..copy_len]);
            p.source_url[copy_len] = 0;
            p.source_url_len = copy_len;
            
            p.load_file(@ptrCast(p.source_url[0..copy_len].ptr));
        }
    }
}

fn caseContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
