const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const icons = @import("icons");

pub fn renderMetadataDialog() void {
    if (state.app.pending_magnet_tid < 0) return;

    // Full screen blocker to disable click-through
    var backdrop = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = dvui.Color{ .r = 0, .g=0, .b=0, .a=180 }
    });
    defer backdrop.deinit();

    var win = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = theme.colors.bg_drawer,
        .color_border = theme.colors.border_drawer,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_md,
        .margin = dvui.Rect.all(20),
        .padding = dvui.Rect.all(12),
        .min_size_content = .{ .w = 600, .h = 400 },
        .expand = .both
    });
    defer win.deinit();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer col.deinit();

    if (!state.app.pending_has_metadata) {
        _ = dvui.label(@src(), "Fetching Torrent Metadata...", .{}, .{ .expand = .both, .color_text = theme.colors.text_main, .gravity_x = 0.5, .gravity_y = 0.5 });
        
        var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 1.0 });
        defer footer.deinit();
        if (dvui.button(@src(), "Cancel", .{}, .{ .color_fill = theme.colors.danger, .color_text = theme.colors.text_main, .padding = theme.dims.pad_sm })) {
            c.mpv.torrent_remove(state.app.torrent_ses, state.app.pending_magnet_tid);
            state.app.pending_magnet_tid = -1;
        }
        return;
    }

    var t_name: [256]u8 = undefined;
    c.mpv.torrent_get_name(state.app.torrent_ses, state.app.pending_magnet_tid, &t_name, 256);
    const name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse 255;

    _ = dvui.label(@src(), "Pre-Download Filter", .{}, .{ .color_text = theme.colors.text_main });
    _ = dvui.label(@src(), "{s}", .{t_name[0..name_len]}, .{ .color_text = theme.colors.text_muted, .margin = .{ .x=0, .y=0, .w=0, .h=12 } });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_input });
    
    var f_list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = theme.dims.pad_sm });
    
    const f_count = c.mpv.torrent_get_file_count(state.app.torrent_ses, state.app.pending_magnet_tid);
    
    var i: i32 = 0;
    while (i < f_count) : (i += 1) {
        var f_name: [256]u8 = undefined;
        c.mpv.torrent_get_file_name(state.app.torrent_ses, state.app.pending_magnet_tid, i, &f_name, 256);
        const f_len = std.mem.indexOfScalar(u8, &f_name, 0) orelse 255;
        const sz = c.mpv.torrent_get_file_size(state.app.torrent_ses, state.app.pending_magnet_tid, i);
        const sz_mb = @as(f64, @floatFromInt(sz)) / (1024.0 * 1024.0);

        var f_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x=0, .y=0, .w=0, .h=4 }, .gravity_y = 0.5 });
        
        const selected = &state.app.pending_files_selection[@as(usize, @intCast(i))];
        _ = dvui.checkbox(@src(), selected, "", .{});
        
        var f_buf: [300]u8 = undefined;
        if (std.fmt.bufPrintZ(&f_buf, "{s} ({d:.1} MB)", .{f_name[0..f_len], sz_mb})) |n| {
            _ = dvui.label(@src(), "{s}", .{n}, .{ .color_text = theme.colors.text_main, .expand = .horizontal });
        } else |_| {}
        
        f_row.deinit();
    }
    
    f_list.deinit();
    scroll.deinit();

    var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x=0, .y=12, .w=0, .h=0 } });
    defer footer.deinit();
    
    _ = dvui.label(@src(), "Select files to allocate your disk space.", .{}, .{ .color_text = theme.colors.warning, .expand = .horizontal, .gravity_y = 0.5 });
    
    if (dvui.button(@src(), "Cancel", .{}, .{ .color_fill = theme.colors.danger, .color_text = theme.colors.text_main, .padding = theme.dims.pad_md })) {
        c.mpv.torrent_remove(state.app.torrent_ses, state.app.pending_magnet_tid);
        state.app.pending_magnet_tid = -1;
    }
    
    if (dvui.button(@src(), "Start Download", .{}, .{ .color_fill = theme.colors.success, .color_text = dvui.Color.black, .padding = theme.dims.pad_md, .margin = .{ .x=8, .y=0, .w=0, .h=0 } })) {
        var fi: i32 = 0;
        while (fi < f_count) : (fi += 1) {
            if (!state.app.pending_files_selection[@as(usize, @intCast(fi))]) {
                c.mpv.torrent_set_file_priority(state.app.torrent_ses, state.app.pending_magnet_tid, fi, 0); // Skip
            } else {
                c.mpv.torrent_set_file_priority(state.app.torrent_ses, state.app.pending_magnet_tid, fi, 4); // Normal
            }
        }
        
        // Finalize state transfer to the active player
        if (state.app.pending_magnet_player_idx < state.app.players.items.len) {
            const p = state.app.players.items[state.app.pending_magnet_player_idx];
            p.current_torrent_id = state.app.pending_magnet_tid;
            p.torrent_is_ready = false;
            p.has_metadata = true;
            p.last_load_time = 0;
            @memcpy(p.source_url[0..state.app.pending_source_url_len], state.app.pending_source_url[0..state.app.pending_source_url_len]);
            p.source_url_len = state.app.pending_source_url_len;
            @memcpy(p.current_url[0..state.app.pending_source_url_len], state.app.pending_source_url[0..state.app.pending_source_url_len]);
            p.current_url_len = state.app.pending_source_url_len;
            p.is_torrent = true;
        } else {
            // Player vanished? Clean up leak.
            c.mpv.torrent_remove(state.app.torrent_ses, state.app.pending_magnet_tid);
        }
        
        state.app.pending_magnet_tid = -1; // Closes dialog
    }
}
