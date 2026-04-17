const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const search = @import("search.zig");
const history = @import("history.zig");

pub var expanded_torrent_id: i32 = -1;
var tab_idx: u8 = 1; // 0=Files 1=Active 2=History

// ══════════════════════════════════════════════════════════
// ENTRY POINT
// ══════════════════════════════════════════════════════════

pub fn renderTransfersContent() void {
    renderTopBar();
    renderTabBar();

    // One shared scroll area — all tab content renders inside it directly
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_drawer,
    });
    defer scroll.deinit();

    if (tab_idx == 0) {
        renderFilesInline();
    } else if (tab_idx == 1) {
        renderActiveInline();
    } else {
        renderHistoryInline();
    }
}

// ══════════════════════════════════════════════════════════
// TOP BAR  — speed limits
// ══════════════════════════════════════════════════════════

fn renderTopBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 },
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.colors.border_drawer,
    });
    defer row.deinit();

    _ = dvui.label(@src(), "Limit:", .{}, .{
        .gravity_y = 0.5,
        .color_text = theme.colors.text_muted,
        .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
    });

    const limits = [_]i32{ 0, 1, 5, 20 };
    const labels = [_][]const u8{ "∞", "1MB/s", "5MB/s", "20MB/s" };
    for (limits, 0..) |lim, k| {
        const active = state.app.global_download_limit == lim;
        if (dvui.button(@src(), labels[k], .{}, .{
            .id_extra = k,
            .color_fill = if (active) theme.colors.accent else dvui.Color{ .r = 24, .g = 24, .b = 34, .a = 255 },
            .color_text = if (active) dvui.Color{ .r = 10, .g = 10, .b = 15, .a = 255 } else theme.colors.text_muted,
            .color_border = if (active) theme.colors.accent else dvui.Color{ .r = 45, .g = 45, .b = 60, .a = 200 },
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(99),
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 5, .h = 0 },
            .gravity_y = 0.5,
        })) {
            state.app.global_download_limit = lim;
            c.mpv.torrent_set_download_limit(state.app.torrent_ses, lim * 1024 * 1024);
        }
    }
}

// ══════════════════════════════════════════════════════════
// TAB BAR
// ══════════════════════════════════════════════════════════

fn renderTabBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    defer row.deinit();

    const t_count = c.mpv.torrent_count(state.app.torrent_ses);
    const hist_count = state.app.dl_history_count;

    var b0: [24]u8 = undefined;
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    const l0 = std.fmt.bufPrintZ(&b0, "Files ({d})", .{cached_files_count}) catch "Files";
    const l1 = std.fmt.bufPrintZ(&b1, "Active ({d})", .{t_count}) catch "Active";
    const l2 = std.fmt.bufPrintZ(&b2, "History ({d})", .{hist_count}) catch "History";
    const tab_labels = [_][]const u8{ l0, l1, l2 };

    for (tab_labels, 0..) |lbl, k| {
        const sel = tab_idx == @as(u8, @intCast(k));
        if (dvui.button(@src(), lbl, .{}, .{
            .id_extra = k + 90000,
            .expand = .horizontal,
            .color_fill = if (sel) theme.colors.accent else dvui.Color{ .r = 22, .g = 22, .b = 32, .a = 255 },
            .color_text = if (sel) dvui.Color{ .r = 10, .g = 10, .b = 15, .a = 255 } else theme.colors.text_muted,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = if (sel) @as(f32, 2) else @as(f32, 0) },
            .color_border = theme.colors.accent,
        })) {
            tab_idx = @intCast(k);
        }
    }
}

// ══════════════════════════════════════════════════════════
// TAB 0 – FILES  (inline, directly in scroll area)
// ══════════════════════════════════════════════════════════

fn renderFilesInline() void {
    const save_path = state.app.save_path_buf[0..state.app.save_path_len];
    var effective_buf: [1024]u8 = undefined;
    const effective_path = if (browse_subdir_len > 0)
        std.fmt.bufPrintZ(&effective_buf, "{s}/{s}", .{ save_path, browse_subdir_buf[0..browse_subdir_len] }) catch save_path
    else
        save_path;

    const now = @import("../core/io_global.zig").timestamp();
    if (now != cached_files_last_scan or browse_path_changed) {
        cached_files_last_scan = now;
        browse_path_changed = false;
        triggerFileScan(effective_path); // non-blocking — bg thread updates cache
    }

    // Path bar — clickable breadcrumb opens folder in Finder/Files
    {
        var prow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 16, .g = 16, .b = 24, .a = 255 },
            .padding = .{ .x = 6, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        });
        defer prow.deinit();

        var lbuf: [256]u8 = undefined;
        const lbl = std.fmt.bufPrintZ(&lbuf, "  {s}  ({d} items)", .{ effective_path, cached_files_count }) catch effective_path;
        if (dvui.button(@src(), lbl, .{}, .{
            .expand = .horizontal,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_muted,
            .border = dvui.Rect.all(0),
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .gravity_y = 0.5,
        })) {
            openInFileManager(effective_path);
        }
        if (browse_subdir_len > 0) {
            if (dvui.button(@src(), "← Up", .{}, .{
                .color_fill = dvui.Color{ .r = 35, .g = 35, .b = 50, .a = 255 },
                .color_text = theme.colors.accent,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
                .gravity_y = 0.5,
            })) {
                if (std.mem.lastIndexOfScalar(u8, browse_subdir_buf[0..browse_subdir_len], '/')) |pos| {
                    browse_subdir_len = pos;
                } else {
                    browse_subdir_len = 0;
                }
                browse_path_changed = true;
            }
        }
    }

    if (cached_files_count == 0) {
        if (cached_files_error) {
            _ = dvui.label(@src(), "Cannot open download folder", .{}, .{
                .color_text = theme.colors.danger,
                .padding = .{ .x = 14, .y = 14, .w = 0, .h = 0 },
            });
        } else {
            _ = dvui.label(@src(), "Download folder is empty.", .{}, .{
                .color_text = theme.colors.text_muted,
                .padding = .{ .x = 14, .y = 14, .w = 0, .h = 0 },
            });
        }
        return;
    }

    // Column header row
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 20, .g = 20, .b = 30, .a = 255 },
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .color_border = dvui.Color{ .r = 40, .g = 40, .b = 60, .a = 200 },
        });
        defer hdr.deinit();
        _ = dvui.label(@src(), "Name", .{}, .{ .expand = .horizontal, .color_text = theme.colors.text_dim });
        _ = dvui.label(@src(), "  ", .{}, .{ .min_size_content = .{ .w = 114, .h = 0 } }); // reserve for sticky actions
    }

    // File rows
    var fi: usize = 0;
    while (fi < cached_files_count) : (fi += 1) {
        const name = cached_files_names[fi][0..cached_files_name_lens[fi]];
        const is_dir = cached_files_is_dir[fi];
        const fsize = cached_files_sizes[fi];
        const is_video = isVideoExt(name);
        const is_audio = isAudioExt(name);

        const row_bg = if (fi % 2 == 0)
            dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 }
        else
            dvui.Color{ .r = 21, .g = 21, .b = 30, .a = 255 };

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = fi + 20000,
            .expand = .horizontal,
            .background = true,
            .color_fill = row_bg,
            .padding = .{ .x = 10, .y = 7, .w = 10, .h = 7 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .color_border = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 140 },
        });
        defer row.deinit();

        // Icon
        const ficon = if (is_dir) icons.tvg.lucide.@"folder"
            else if (is_video) icons.tvg.lucide.@"film"
            else if (is_audio) icons.tvg.lucide.@"music"
            else icons.tvg.lucide.@"file";
        const icol = if (is_dir) dvui.Color{ .r = 100, .g = 170, .b = 255, .a = 255 }
            else if (is_video) dvui.Color{ .r = 100, .g = 220, .b = 120, .a = 255 }
            else if (is_audio) dvui.Color{ .r = 255, .g = 180, .b = 80, .a = 255 }
            else theme.colors.text_dim;
        _ = dvui.icon(@src(), "", ficon, .{}, .{
            .id_extra = fi + 20100,
            .color_text = icol,
            .min_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            .gravity_y = 0.5,
        });

        // Name (truncated to leave fixed room for actions)
        _ = dvui.label(@src(), "{s}", .{displayName(name)}, .{
            .id_extra = fi + 20200,
            .expand = .horizontal,
            .color_text = theme.colors.text_main,
            .gravity_y = 0.5,
        });

        // Sticky action overlay — fixed width so actions always visible
        var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = fi + 20700,
            .background = true,
            .color_fill = row_bg,
            .border = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
            .color_border = dvui.Color{ .r = 80, .g = 60, .b = 100, .a = 80 },
            .padding = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 110, .h = 0 },
        });
        defer acts.deinit();

        // Size inside acts (compact)
        if (!is_dir and fsize > 0) {
            var sbuf: [12]u8 = undefined;
            const sf = @as(f64, @floatFromInt(fsize));
            const s = if (sf >= 1073741824.0)
                std.fmt.bufPrintZ(&sbuf, "{d:.1}G", .{sf / 1073741824.0}) catch "?"
            else if (sf >= 1048576.0)
                std.fmt.bufPrintZ(&sbuf, "{d:.0}M", .{sf / 1048576.0}) catch "?"
            else
                std.fmt.bufPrintZ(&sbuf, "{d:.0}K", .{sf / 1024.0}) catch "?";
            _ = dvui.label(@src(), "{s}", .{s}, .{
                .id_extra = fi + 20300,
                .color_text = theme.colors.text_dim,
                .min_size_content = .{ .w = 38, .h = 0 },
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
            });
        }

        if (is_dir) {
            if (dvui.button(@src(), "Open", .{}, .{
                .id_extra = fi + 20400,
                .color_fill = theme.colors.accent,
                .color_text = dvui.Color{ .r = 10, .g = 10, .b = 15, .a = 255 },
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
                .gravity_y = 0.5,
            })) {
                if (browse_subdir_len == 0) {
                    const nlen = @min(name.len, browse_subdir_buf.len);
                    @memcpy(browse_subdir_buf[0..nlen], name[0..nlen]);
                    browse_subdir_len = nlen;
                } else {
                    if (std.fmt.bufPrint(browse_subdir_buf[browse_subdir_len..], "/{s}", .{name})) |app| {
                        browse_subdir_len += app.len;
                    } else |_| {}
                }
                browse_path_changed = true;
            }
        } else {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"play", .{}, .{}, .{
                .id_extra = fi + 20500,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.success,
                .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
                .gravity_y = 0.5,
            })) {
                var fp: [1024]u8 = undefined;
                if (std.fmt.bufPrintZ(&fp, "{s}/{s}", .{ effective_path, name })) |full| {
                    if (state.app.active_player_idx < state.app.players.items.len) {
                        state.app.players.items[state.app.active_player_idx].load_file(full);
                        addWatchHistory(name);
                    }
                } else |_| {}
            }
        }

        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"trash-2", .{}, .{}, .{
            .id_extra = fi + 20600,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = dvui.Color{ .r = 160, .g = 60, .b = 60, .a = 200 },
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .gravity_y = 0.5,
        })) {
            var dp: [1024]u8 = undefined;
            if (std.fmt.bufPrintZ(&dp, "{s}/{s}", .{ effective_path, name })) |del| {
                if (is_dir) @import("../core/io_global.zig").cwdDeleteTree(del) catch {}
                else @import("../core/io_global.zig").cwdDeleteFile(del) catch {};
                browse_path_changed = true;
                state.showToast("Deleted");
            } else |_| {}
        }
    }
}

// ══════════════════════════════════════════════════════════
// TAB 1 – ACTIVE TORRENTS  (inline)
// ══════════════════════════════════════════════════════════

fn renderActiveInline() void {
    const t_count = c.mpv.torrent_count(state.app.torrent_ses);

    if (t_count == 0) {
        _ = dvui.label(@src(), "No active downloads.", .{}, .{
            .color_text = theme.colors.text_muted,
            .padding = .{ .x = 14, .y = 20, .w = 0, .h = 0 },
        });
        return;
    }

    // Column header
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 20, .g = 20, .b = 30, .a = 255 },
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .color_border = dvui.Color{ .r = 40, .g = 40, .b = 60, .a = 200 },
        });
        defer hdr.deinit();
        _ = dvui.label(@src(), "Torrent", .{}, .{ .expand = .horizontal, .color_text = theme.colors.text_dim });
        _ = dvui.label(@src(), "Speed", .{}, .{ .color_text = theme.colors.text_dim, .min_size_content = .{ .w = 90, .h = 0 } });
        _ = dvui.label(@src(), "  ", .{}, .{ .min_size_content = .{ .w = 72, .h = 0 } });
    }

    var i: i32 = 0;
    while (i < t_count) : (i += 1) {
        const ui: usize = @intCast(i);

        var t_name: [256]u8 = undefined;
        c.mpv.torrent_get_name(state.app.torrent_ses, i, &t_name, 256);
        const name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse 255;
        const name = t_name[0..name_len];

        var progress: f32 = 0;
        var dl_rate: c_int = 0;
        var seeds: c_int = 0;
        _ = c.mpv.torrent_poll(state.app.torrent_ses, i, -1, null, 0, &progress, &dl_rate, &seeds);

        const is_paused = c.mpv.torrent_is_paused(state.app.torrent_ses, i) != 0;
        const pct = @as(u8, @intFromFloat(std.math.clamp(progress * 100.0, 0.0, 100.0)));

        const row_bg = if (ui % 2 == 0)
            dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 }
        else
            dvui.Color{ .r = 21, .g = 21, .b = 30, .a = 255 };

        // Main row
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = ui + 30000,
            .expand = .horizontal,
            .background = true,
            .color_fill = row_bg,
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .color_border = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 140 },
        });
        defer row.deinit();

        // Progress arc indicator (colored left border)
        {
            const prog_col = if (progress >= 1.0) theme.colors.success
                else if (is_paused) theme.colors.text_dim
                else theme.colors.accent;
            var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = ui + 30050,
                .min_size_content = .{ .w = 3, .h = 0 },
                .background = true,
                .color_fill = prog_col,
                .corner_radius = dvui.Rect.all(2),
                .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
                .gravity_y = 0.5,
            });
            bar.deinit();
        }

        // Name + percent (click to expand)
        {
            var nameblk = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = ui + 30100,
                .expand = .horizontal,
                .gravity_y = 0.5,
            });
            defer nameblk.deinit();

            if (dvui.button(@src(), displayName(name), .{}, .{
                .id_extra = ui + 30110,
                .expand = .horizontal,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = if (is_paused) theme.colors.text_muted else theme.colors.text_main,
                .padding = dvui.Rect.all(0),
            })) {
                expanded_torrent_id = if (expanded_torrent_id == i) -1 else i;
            }

            // Progress bar
            var pct_frac = std.math.clamp(progress, 0.0, 1.0);
            _ = dvui.slider(@src(), .{ .fraction = &pct_frac }, .{
                .id_extra = ui + 30120,
                .expand = .horizontal,
                .min_size_content = .{ .w = 10, .h = 4 },
                .color_fill = dvui.Color{ .r = 35, .g = 35, .b = 50, .a = 255 },
                .color_text = if (progress >= 1.0) theme.colors.success else theme.colors.accent,
                .corner_radius = dvui.Rect.all(2),
                .margin = .{ .x = 0, .y = 3, .w = 0, .h = 0 },
            });
        }

        // Speed column
        {
            var spd_buf: [32]u8 = undefined;
            const dl_mb = @as(f32, @floatFromInt(dl_rate)) / 1048576.0;
            const spd_str = if (is_paused)
                std.fmt.bufPrintZ(&spd_buf, "  {d}% paused", .{pct}) catch "paused"
            else
                std.fmt.bufPrintZ(&spd_buf, "↓{d:.1}M {d}%", .{dl_mb, pct}) catch "...";
            _ = dvui.label(@src(), "{s}", .{spd_str}, .{
                .id_extra = ui + 30200,
                .color_text = if (is_paused) theme.colors.text_dim else theme.colors.text_muted,
                .min_size_content = .{ .w = 90, .h = 0 },
                .gravity_y = 0.5,
            });
        }

        // Fixed-width actions column — always visible
        var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = ui + 30600,
            .min_size_content = .{ .w = 72, .h = 0 },
            .gravity_y = 0.5,
        });
        defer acts.deinit();

        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"play", .{}, .{}, .{
            .id_extra = ui + 30300,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.success,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .gravity_y = 0.5,
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                const p = state.app.players.items[state.app.active_player_idx];
                p.current_torrent_id = i;
                p.torrent_is_ready = false;
                p.has_metadata = false;
                p.last_load_time = 0;
                p.selected_file_idx = -1;
                p.metadata_start_time = @import("../core/io_global.zig").timestamp();
            }
        }
        {
            const pic = if (is_paused) icons.tvg.lucide.@"play" else icons.tvg.lucide.@"pause";
            const pcol = if (is_paused) theme.colors.accent else theme.colors.text_muted;
            if (dvui.buttonIcon(@src(), "", pic, .{}, .{}, .{
                .id_extra = ui + 30400,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = pcol,
                .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
                .gravity_y = 0.5,
            })) {
                if (is_paused) c.mpv.torrent_resume(state.app.torrent_ses, i)
                else c.mpv.torrent_pause(state.app.torrent_ses, i);
            }
        }
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"trash-2", .{}, .{}, .{
            .id_extra = ui + 30500,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.danger,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .gravity_y = 0.5,
        })) {
            history.addDownloadHistory(name, "");
            c.mpv.torrent_remove(state.app.torrent_ses, i);
            for (state.app.players.items) |p| {
                if (p.current_torrent_id == i) {
                    p.current_torrent_id = -1; p.torrent_is_ready = false;
                    p.has_metadata = false;
                    _ = c.mpv.mpv_command_string(p.mpv_ctx, "stop");
                } else if (p.current_torrent_id > i) p.current_torrent_id -= 1;
            }
            if (expanded_torrent_id == i) expanded_torrent_id = -1
            else if (expanded_torrent_id > i) { expanded_torrent_id -= 1; }
            return;
        }
    }

    // Expanded file list — rendered AFTER the main row loop
    // We render it for whichever torrent is expanded
    if (expanded_torrent_id >= 0 and expanded_torrent_id < t_count) {
        renderExpandedFiles(expanded_torrent_id);
    }
}

fn renderExpandedFiles(torrent_id: i32) void {
    const ui: usize = @intCast(torrent_id);
    const f_count = c.mpv.torrent_get_file_count(state.app.torrent_ses, torrent_id);
    if (f_count <= 0) return;

    // Header for expanded section
    {
        var xhdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 22, .a = 255 },
            .padding = .{ .x = 18, .y = 4, .w = 10, .h = 4 },
            .border = .{ .x = 3, .y = 0, .w = 0, .h = 1 },
            .color_border = theme.colors.accent,
        });
        defer xhdr.deinit();
        _ = dvui.label(@src(), "Files", .{}, .{ .color_text = theme.colors.text_dim, .expand = .horizontal });
        _ = dvui.label(@src(), "Size", .{}, .{ .color_text = theme.colors.text_dim, .min_size_content = .{ .w = 56, .h = 0 } });
        _ = dvui.label(@src(), "Progress", .{}, .{ .color_text = theme.colors.text_dim, .min_size_content = .{ .w = 80, .h = 0 } });
        _ = dvui.label(@src(), "Priority", .{}, .{ .color_text = theme.colors.text_dim });
    }

    var f_idx: i32 = 0;
    while (f_idx < f_count) : (f_idx += 1) {
        const fi: usize = @intCast(f_idx);
        const cid = fi + ui * 1000 + 31000;

        var f_name: [256]u8 = undefined;
        c.mpv.torrent_get_file_name(state.app.torrent_ses, torrent_id, f_idx, &f_name, 256);
        const f_len = std.mem.indexOfScalar(u8, &f_name, 0) orelse 255;
        const f_prog = c.mpv.torrent_get_file_progress(state.app.torrent_ses, torrent_id, f_idx);
        const f_size = c.mpv.torrent_get_file_size(state.app.torrent_ses, torrent_id, f_idx);

        var frow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = cid,
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 15, .g = 15, .b = 22, .a = 255 },
            .padding = .{ .x = 18, .y = 6, .w = 10, .h = 6 },
            .border = .{ .x = 3, .y = 0, .w = 0, .h = 1 },
            .color_border = theme.colors.accent,
            .gravity_y = 0.5,
        });
        defer frow.deinit();

        // Play file
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"play", .{}, .{}, .{
            .id_extra = cid + 100,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.success,
            .padding = .{ .x = 3, .y = 3, .w = 6, .h = 3 },
            .gravity_y = 0.5,
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                const p = state.app.players.items[state.app.active_player_idx];
                p.current_torrent_id = torrent_id;
                p.selected_file_idx = f_idx;
                p.torrent_is_ready = false;
                p.has_metadata = true;
                p.last_load_time = 0;
            }
        }

        // Filename
        _ = dvui.label(@src(), "{s}", .{f_name[0..f_len]}, .{
            .id_extra = cid + 200,
            .expand = .horizontal,
            .color_text = theme.colors.text_main,
            .gravity_y = 0.5,
        });

        // Size
        {
            var sbuf: [16]u8 = undefined;
            const mb = @as(f64, @floatFromInt(f_size)) / 1048576.0;
            const s = if (mb > 1024)
                std.fmt.bufPrintZ(&sbuf, "{d:.1}G", .{mb / 1024.0}) catch "?"
            else
                std.fmt.bufPrintZ(&sbuf, "{d:.0}M", .{mb}) catch "?";
            _ = dvui.label(@src(), "{s}", .{s}, .{
                .id_extra = cid + 300,
                .color_text = theme.colors.text_dim,
                .min_size_content = .{ .w = 56, .h = 0 },
                .gravity_y = 0.5,
            });
        }

        // Progress
        {
            var pct = @as(f32, @floatCast(f_prog));
            _ = dvui.slider(@src(), .{ .fraction = &pct }, .{
                .id_extra = cid + 400,
                .min_size_content = .{ .w = 80, .h = 5 },
                .color_fill = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 255 },
                .color_text = theme.colors.accent,
                .corner_radius = dvui.Rect.all(2),
                .gravity_y = 0.5,
            });
        }

        // Priority
        if (dvui.button(@src(), "Skip", .{}, .{
            .id_extra = cid + 500,
            .color_fill = dvui.Color{ .r = 50, .g = 20, .b = 20, .a = 255 },
            .color_text = theme.colors.text_muted,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .margin = .{ .x = 4, .y = 0, .w = 2, .h = 0 },
            .gravity_y = 0.5,
        })) { c.mpv.torrent_set_file_priority(state.app.torrent_ses, torrent_id, f_idx, 0); }

        if (dvui.button(@src(), "High", .{}, .{
            .id_extra = cid + 600,
            .color_fill = dvui.Color{ .r = 20, .g = 45, .b = 20, .a = 255 },
            .color_text = theme.colors.success,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
            .gravity_y = 0.5,
        })) { c.mpv.torrent_set_file_priority(state.app.torrent_ses, torrent_id, f_idx, 7); }
    }
}

// ══════════════════════════════════════════════════════════
// TAB 2 – HISTORY  (inline)
// ══════════════════════════════════════════════════════════

fn renderHistoryInline() void {
    const has_dl = state.app.dl_history_count > 0;
    const has_watch = watch_history_count > 0;

    if (!has_dl and !has_watch) {
        _ = dvui.label(@src(), "No history yet.", .{}, .{
            .color_text = theme.colors.text_muted,
            .padding = .{ .x = 14, .y = 20, .w = 0, .h = 0 },
        });
        return;
    }

    // Section: Download History
    if (has_dl) {
        // Section header
        {
            var shdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .background = true,
                .color_fill = dvui.Color{ .r = 20, .g = 20, .b = 30, .a = 255 },
                .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .color_border = dvui.Color{ .r = 40, .g = 40, .b = 60, .a = 200 },
            });
            defer shdr.deinit();
            _ = dvui.label(@src(), "Download History", .{}, .{ .expand = .horizontal, .color_text = theme.colors.text_dim });
            _ = dvui.label(@src(), "  ", .{}, .{ .min_size_content = .{ .w = 50, .h = 0 } });
        }

        var hi: usize = 0;
        while (hi < state.app.dl_history_count) : (hi += 1) {
            const raw_name = state.app.dl_history_names[hi][0..state.app.dl_history_name_lens[hi]];
            const link = state.app.dl_history_links[hi][0..state.app.dl_history_link_lens[hi]];
            const display = if (std.mem.startsWith(u8, raw_name, "magnet:"))
                extractDn(raw_name)
            else if (raw_name.len == 0 and link.len > 0)
                extractDn(link)
            else
                raw_name;

            const row_bg = if (hi % 2 == 0)
                dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 }
            else
                dvui.Color{ .r = 21, .g = 21, .b = 30, .a = 255 };

            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = hi + 40000,
                .expand = .horizontal,
                .background = true,
                .color_fill = row_bg,
                .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .color_border = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 140 },
            });
            defer row.deinit();

            _ = dvui.label(@src(), "{s}", .{displayName(display)}, .{
                .id_extra = hi + 40100,
                .expand = .horizontal,
                .color_text = theme.colors.text_main,
                .gravity_y = 0.5,
            });

            // Fixed-width actions — always visible
            var hacts = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = hi + 40400,
                .min_size_content = .{ .w = 50, .h = 0 },
                .gravity_y = 0.5,
            });
            defer hacts.deinit();

            if (link.len > 0) {
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"play", .{}, .{}, .{
                    .id_extra = hi + 40200,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_text = theme.colors.accent,
                    .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
                    .gravity_y = 0.5,
                })) {
                    search.loadTorrentToPlayer(link);
                }
            }

            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"x", .{}, .{}, .{
                .id_extra = hi + 40300,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.text_dim,
                .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
                .gravity_y = 0.5,
            })) {
                history.removeDownloadHistory(hi);
                return;
            }
        }
    }

    // Section: Recently Played
    if (has_watch) {
        {
            var shdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .background = true,
                .color_fill = dvui.Color{ .r = 20, .g = 20, .b = 30, .a = 255 },
                .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .color_border = dvui.Color{ .r = 40, .g = 40, .b = 60, .a = 200 },
                .margin = .{ .x = 0, .y = 8, .w = 0, .h = 0 },
            });
            defer shdr.deinit();
            _ = dvui.label(@src(), "Recently Played", .{}, .{ .expand = .horizontal, .color_text = theme.colors.text_dim });
        }

        var hi: usize = 0;
        while (hi < watch_history_count) : (hi += 1) {
            const row_bg = if (hi % 2 == 0)
                dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 }
            else
                dvui.Color{ .r = 21, .g = 21, .b = 30, .a = 255 };

            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = hi + 50000,
                .expand = .horizontal,
                .background = true,
                .color_fill = row_bg,
                .padding = .{ .x = 10, .y = 7, .w = 10, .h = 7 },
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
                .color_border = dvui.Color{ .r = 30, .g = 30, .b = 45, .a = 140 },
            });
            defer row.deinit();

            _ = dvui.icon(@src(), "", icons.tvg.lucide.@"film", .{}, .{
                .id_extra = hi + 50100,
                .color_text = theme.colors.text_dim,
                .min_size_content = .{ .w = 13, .h = 13 },
                .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
                .gravity_y = 0.5,
            });
            _ = dvui.label(@src(), "{s}", .{displayName(watch_history_names[hi][0..watch_history_name_lens[hi]])}, .{
                .id_extra = hi + 50200,
                .expand = .horizontal,
                .color_text = theme.colors.text_muted,
                .gravity_y = 0.5,
            });
        }
    }
}

// Open a directory in the OS file manager (Finder / Explorer / xdg-open).
fn openInFileManager(path: []const u8) void {
    const builtin = @import("builtin");
    const cmd: []const u8 = switch (builtin.target.os.tag) {
        .macos => "open",
        .windows => "explorer",
        else => "xdg-open",
    };
    var child = @import("../core/io_global.zig").Child.init(&.{ cmd, path }, @import("../core/alloc.zig").allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch {};
}

// Strip scrape-site prefixes like "www.uindex.org - " or "[rarbg.to] - " from filenames.
fn displayName(name: []const u8) []const u8 {
    // Pattern 1: leading "www.*.tld[.tld] <sep> "
    if (std.mem.startsWith(u8, name, "www.")) {
        if (std.mem.indexOfAny(u8, name, " -_")) |_| {
            // Find first ' - ' (space-dash-space) or ' -' separator after TLD
            if (std.mem.indexOf(u8, name, " - ")) |sep| {
                const after = name[sep + 3 ..];
                if (after.len > 0) return std.mem.trimStart(u8, after, " -_");
            }
        }
    }
    // Pattern 2: bracket tag at start "[site] - title" or "[site] title"
    if (name.len > 0 and name[0] == '[') {
        if (std.mem.indexOfScalar(u8, name, ']')) |close| {
            const after = std.mem.trimStart(u8, name[close + 1 ..], " -_");
            if (after.len > 0) return after;
        }
    }
    return name;
}

// Extract display name from magnet dn= param, or truncate hash
fn extractDn(magnet: []const u8) []const u8 {
    if (std.mem.indexOf(u8, magnet, "dn=")) |pos| {
        const after = magnet[pos + 3..];
        const end = std.mem.indexOfScalar(u8, after, '&') orelse after.len;
        if (end > 0) return after[0..end];
    }
    if (std.mem.indexOf(u8, magnet, "btih:")) |pos| {
        const after = magnet[pos + 5..];
        const end = std.mem.indexOfScalar(u8, after, '&') orelse after.len;
        if (end > 0) return after[0..@min(end, 20)];
    }
    return if (magnet.len > 36) magnet[0..36] else magnet;
}

// ══════════════════════════════════════════════════════════
// FILE CACHE
// ══════════════════════════════════════════════════════════

const MAX_CACHED_FILES = 200;
const MAX_NAME_LEN = 256;

var cached_files_names: [MAX_CACHED_FILES][MAX_NAME_LEN]u8 = undefined;
var cached_files_name_lens: [MAX_CACHED_FILES]usize = std.mem.zeroes([MAX_CACHED_FILES]usize);
var cached_files_is_dir: [MAX_CACHED_FILES]bool = std.mem.zeroes([MAX_CACHED_FILES]bool);
var cached_files_sizes: [MAX_CACHED_FILES]u64 = std.mem.zeroes([MAX_CACHED_FILES]u64);
var cached_files_count: usize = 0;
var cached_files_last_scan: i64 = 0;
var cached_files_error: bool = false;

var browse_subdir_buf: [1024]u8 = std.mem.zeroes([1024]u8);
var browse_subdir_len: usize = 0;
var browse_path_changed: bool = true;

// Background scan mutex — prevents render thread from blocking on dir I/O
var files_mutex: @import("../core/sync.zig").Mutex = .{};
var files_scanning: bool = false;
var files_scan_path_buf: [1024]u8 = std.mem.zeroes([1024]u8);
var files_scan_path_len: usize = 0;

// Staging buffers written by bg thread, swapped under mutex
var staged_names: [MAX_CACHED_FILES][MAX_NAME_LEN]u8 = undefined;
var staged_name_lens: [MAX_CACHED_FILES]usize = std.mem.zeroes([MAX_CACHED_FILES]usize);
var staged_is_dir: [MAX_CACHED_FILES]bool = std.mem.zeroes([MAX_CACHED_FILES]bool);
var staged_sizes: [MAX_CACHED_FILES]u64 = std.mem.zeroes([MAX_CACHED_FILES]u64);
var staged_count: usize = 0;
var staged_error: bool = false;

fn bgRefreshFiles(_: void) void {
    files_mutex.lock();
    const plen = files_scan_path_len;
    var pbuf: [1024]u8 = undefined;
    @memcpy(pbuf[0..plen], files_scan_path_buf[0..plen]);
    files_mutex.unlock();

    const path = pbuf[0..plen];
    var cnt: usize = 0;
    var tmp_names: [MAX_CACHED_FILES][MAX_NAME_LEN]u8 = undefined;
    var tmp_lens:  [MAX_CACHED_FILES]usize = std.mem.zeroes([MAX_CACHED_FILES]usize);
    var tmp_dirs:  [MAX_CACHED_FILES]bool  = std.mem.zeroes([MAX_CACHED_FILES]bool);
    var tmp_sizes: [MAX_CACHED_FILES]u64   = std.mem.zeroes([MAX_CACHED_FILES]u64);

    var dir = @import("../core/io_global.zig").cwdOpenDir(path, .{ .iterate = true }) catch {
        files_mutex.lock();
        staged_count = 0; staged_error = true; files_scanning = false;
        files_mutex.unlock();
        return;
    };
    defer dir.close(@import("../core/io_global.zig").io());
    var iter = dir.iterate();
    while (iter.next(@import("../core/io_global.zig").io()) catch null) |entry| {
        if (cnt >= MAX_CACHED_FILES) break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.endsWith(u8, entry.name, ".torrent")) continue;
        if (std.mem.endsWith(u8, entry.name, ".parts")) continue;
        const nlen = @min(entry.name.len, MAX_NAME_LEN);
        @memcpy(tmp_names[cnt][0..nlen], entry.name[0..nlen]);
        tmp_lens[cnt] = nlen;
        tmp_dirs[cnt] = entry.kind == .directory;
        tmp_sizes[cnt] = if (entry.kind == .file) blk: {
            const stat = dir.statFile(@import("../core/io_global.zig").io(), entry.name, .{}) catch null;
            break :blk if (stat) |s| s.size else 0;
        } else 0;
        cnt += 1;
    }

    files_mutex.lock();
    staged_names = tmp_names;
    staged_name_lens = tmp_lens;
    staged_is_dir = tmp_dirs;
    staged_sizes = tmp_sizes;
    staged_count = cnt;
    staged_error = false;
    // Swap into live buffers
    cached_files_names = staged_names;
    cached_files_name_lens = staged_name_lens;
    cached_files_is_dir = staged_is_dir;
    cached_files_sizes = staged_sizes;
    cached_files_count = staged_count;
    cached_files_error = staged_error;
    files_scanning = false;
    files_mutex.unlock();
}

fn triggerFileScan(path: []const u8) void {
    files_mutex.lock();
    if (files_scanning) { files_mutex.unlock(); return; }
    files_scanning = true;
    const plen = @min(path.len, files_scan_path_buf.len);
    @memcpy(files_scan_path_buf[0..plen], path[0..plen]);
    files_scan_path_len = plen;
    files_mutex.unlock();
    const t = std.Thread.spawn(.{}, bgRefreshFiles, .{{}}) catch {
        files_mutex.lock(); files_scanning = false; files_mutex.unlock();
        return;
    };
    t.detach();
}

// ══════════════════════════════════════════════════════════
// WATCH HISTORY (session only)
// ══════════════════════════════════════════════════════════

const MAX_WATCH_HISTORY = 20;
var watch_history_names: [MAX_WATCH_HISTORY][MAX_NAME_LEN]u8 = undefined;
var watch_history_name_lens: [MAX_WATCH_HISTORY]usize = std.mem.zeroes([MAX_WATCH_HISTORY]usize);
var watch_history_count: usize = 0;

fn addWatchHistory(name: []const u8) void {
    if (watch_history_count > 0 and std.mem.eql(u8, watch_history_names[0][0..watch_history_name_lens[0]], name)) return;
    if (watch_history_count > 0) {
        var j: usize = @min(watch_history_count, MAX_WATCH_HISTORY - 1);
        while (j > 0) : (j -= 1) {
            watch_history_names[j] = watch_history_names[j - 1];
            watch_history_name_lens[j] = watch_history_name_lens[j - 1];
        }
    }
    const nlen = @min(name.len, MAX_NAME_LEN);
    @memcpy(watch_history_names[0][0..nlen], name[0..nlen]);
    watch_history_name_lens[0] = nlen;
    if (watch_history_count < MAX_WATCH_HISTORY) watch_history_count += 1;
}

// ══════════════════════════════════════════════════════════
// HELPERS
// ══════════════════════════════════════════════════════════

fn isVideoExt(name: []const u8) bool {
    const exts = [_][]const u8{ ".mp4", ".mkv", ".avi", ".webm", ".mov", ".flv", ".ts", ".wmv", ".m4v" };
    for (exts) |ext| if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len..], ext)) return true;
    return false;
}

fn isAudioExt(name: []const u8) bool {
    const exts = [_][]const u8{ ".mp3", ".flac", ".wav", ".ogg", ".m4a", ".opus", ".aac", ".wma" };
    for (exts) |ext| if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len..], ext)) return true;
    return false;
}
