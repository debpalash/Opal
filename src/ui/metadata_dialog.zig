const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const icons = @import("icons");

const TRANSPARENT: dvui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

pub fn renderMetadataDialog() void {
    if (state.app.pending_magnet_tid < 0) return;

    // Full screen blocker to disable click-through
    var backdrop = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.overlay,
    });
    defer backdrop.deinit();

    // True modal: no border — separated by the elevated fill + a single soft
    // shadow (the one legitimate shadow per the calm rules).
    var win = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = theme.dims.rad_lg,
        .margin = dvui.Rect.all(theme.spacing.xl),
        .padding = dvui.Rect.all(theme.spacing.md),
        .min_size_content = .{ .w = 600, .h = 400 },
        .expand = .both,
        .box_shadow = .{
            .color = theme.colors.overlay,
            .offset = .{ .x = 0, .y = 6 },
            .fade = 28,
        },
    });
    defer win.deinit();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer col.deinit();

    if (!state.app.pending_has_metadata) {
        _ = dvui.label(@src(), "Fetching Torrent Metadata...", .{}, .{ .expand = .both, .color_text = theme.colors.text_primary, .gravity_x = 0.5, .gravity_y = 0.5 });

        var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 1.0 });
        defer footer.deinit();
        // Ghost Cancel — text-only danger, no resting fill.
        if (dvui.button(@src(), "Cancel", .{}, .{ .color_fill = TRANSPARENT, .color_text = theme.colors.danger, .padding = theme.dims.pad_sm })) {
            c.mpv.torrent_remove(state.app.torrent_ses, state.app.pending_magnet_tid);
            state.app.pending_magnet_tid = -1;
        }
        return;
    }

    var t_name: [256]u8 = undefined;
    c.mpv.torrent_get_name(state.app.torrent_ses, state.app.pending_magnet_tid, &t_name, 256);
    const name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse 255;

    _ = dvui.label(@src(), "Pre-Download Filter", .{}, .{ .color_text = theme.colors.text_primary });
    _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(t_name[0..name_len])}, .{ .color_text = theme.colors.text_secondary, .margin = .{ .x=0, .y=0, .w=0, .h=theme.spacing.md } });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    
    var f_list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = theme.dims.pad_sm });
    
    const f_count = c.mpv.torrent_get_file_count(state.app.torrent_ses, state.app.pending_magnet_tid);
    // f_count is untrusted (.torrent metadata). Clamp to the fixed-size
    // pending_files_selection buffer so the index below can never go OOB.
    const shown = @min(f_count, @as(@TypeOf(f_count), @intCast(state.app.pending_files_selection.len)));

    var i: i32 = 0;
    while (i < shown) : (i += 1) {
        var f_name: [256]u8 = undefined;
        c.mpv.torrent_get_file_name(state.app.torrent_ses, state.app.pending_magnet_tid, i, &f_name, 256);
        const f_len = std.mem.indexOfScalar(u8, &f_name, 0) orelse 255;
        const safe_name = @import("../core/text.zig").safeUtf8(f_name[0..f_len]);
        const sz = c.mpv.torrent_get_file_size(state.app.torrent_ses, state.app.pending_magnet_tid, i);
        const sz_mb = @as(f64, @floatFromInt(sz)) / (1024.0 * 1024.0);

        var f_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x=0, .y=0, .w=0, .h=4 }, .gravity_y = 0.5 });

        const selected = &state.app.pending_files_selection[@as(usize, @intCast(i))];
        _ = dvui.checkbox(@src(), selected, "", .{});

        var f_buf: [300]u8 = undefined;
        if (std.fmt.bufPrintZ(&f_buf, "{s} ({d:.1} MB)", .{safe_name, sz_mb})) |n| {
            _ = dvui.label(@src(), "{s}", .{n}, .{ .color_text = theme.colors.text_primary, .expand = .horizontal });
        } else |_| {}

        f_row.deinit();
    }
    
    f_list.deinit();
    scroll.deinit();

    var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x=0, .y=theme.spacing.md, .w=0, .h=0 } });
    defer footer.deinit();

    // Quiet instruction line — not a resting warning hue.
    _ = dvui.label(@src(), "Select files to allocate your disk space.", .{}, .{ .color_text = theme.colors.text_tertiary, .expand = .horizontal, .gravity_y = 0.5 });

    // Ghost Cancel — text-only danger.
    if (dvui.button(@src(), "Cancel", .{}, .{ .color_fill = TRANSPARENT, .color_text = theme.colors.danger, .padding = theme.dims.pad_md })) {
        c.mpv.torrent_remove(state.app.torrent_ses, state.app.pending_magnet_tid);
        state.app.pending_magnet_tid = -1;
    }

    // Primary action — the single accent affordance of the dialog.
    if (dvui.button(@src(), "Start Download", .{}, .{ .color_fill = theme.colors.accent, .color_text = theme.colors.text_on_accent, .padding = theme.dims.pad_md, .margin = .{ .x=theme.spacing.sm, .y=0, .w=0, .h=0 } })) {
        var fi: i32 = 0;
        const shown_dl = @min(f_count, @as(@TypeOf(f_count), @intCast(state.app.pending_files_selection.len)));
        while (fi < shown_dl) : (fi += 1) {
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
