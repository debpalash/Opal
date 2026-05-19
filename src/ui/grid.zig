const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const player = @import("../player/player.zig");
const logs = @import("../core/logs.zig");
const search = @import("../services/search.zig");
const transfers = @import("../services/transfers.zig");
const theme = @import("theme.zig");
const metadata_dialog = @import("metadata_dialog.zig");
const components = @import("components.zig");

/// Normalize a path / URL into a user-facing display name:
///   1. basename (after last `/` or `\\`)
///   2. strip short file extension (`.mkv`, `.mp4`, ...)
///   3. replace `.` and `_` with spaces, collapse runs of spaces
///   4. trim leading/trailing whitespace
/// Writes into `out` (capacity = `out.len`) and returns the populated
/// slice. Returns `raw` unchanged if cleanup would produce an empty
/// string.
fn cleanDisplayName(out: []u8, raw: []const u8) []const u8 {
    if (out.len == 0) return raw;

    // Step 1: basename
    var basename_start: usize = 0;
    for (raw, 0..) |ch, ci| {
        if (ch == '/' or ch == '\\') basename_start = ci + 1;
    }
    const basename = raw[basename_start..];

    // Step 2: strip short extension
    var name_end: usize = basename.len;
    {
        var last_dot: ?usize = null;
        for (basename, 0..) |ch, ci| {
            if (ch == '.') last_dot = ci;
        }
        if (last_dot) |dot| {
            if (basename.len - dot <= 6) name_end = dot;
        }
    }
    const stripped = basename[0..name_end];

    // Step 3: replace dots/underscores with spaces, collapse multiples
    var written: usize = 0;
    for (stripped) |ch| {
        if (written >= out.len - 1) break;
        const out_ch: u8 = if (ch == '.' or ch == '_') ' ' else ch;
        if (out_ch == ' ' and written > 0 and out[written - 1] == ' ') continue;
        out[written] = out_ch;
        written += 1;
    }

    // Step 4: trim trailing then leading spaces
    while (written > 0 and out[written - 1] == ' ') written -= 1;
    var trim_start: usize = 0;
    while (trim_start < written and out[trim_start] == ' ') trim_start += 1;
    if (trim_start > 0 and trim_start < written) {
        std.mem.copyForwards(u8, out[0 .. written - trim_start], out[trim_start..written]);
        written -= trim_start;
    }

    return if (written > 0) out[0..written] else raw;
}

fn renderInlineChat() void {
    const ai_chat = @import("../services/ai_chat.zig");

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 240 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = 480 },
        .background = false,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 10 },
    });
    defer scroll.deinit();

    // Inline results cards with play buttons — render at top for visibility
    ai_chat.renderInlineResults();

    var mi: usize = 0;
    while (mi < ai_chat.message_count) : (mi += 1) {
        const m = ai_chat.messages[mi];
        if (m.text_len == 0) continue;
        if (m.role == .system) continue; // tool-response internals, not shown to user
        const is_user = m.role == .user;

        var bubble = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = mi + 70000,
            .expand = .horizontal,
            .background = true,
            .color_fill = if (is_user)
                theme.colors.bg_surface
            else
                theme.colors.bg_card,
            .color_border = if (is_user) theme.colors.accent else theme.colors.border_card,
            .border = .{ .x = if (is_user) @as(f32, 3) else 0, .y = 0, .w = 0, .h = 0 },
            .corner_radius = dvui.Rect.all(10),
            .padding = .{ .x = 14, .y = 10, .w = 14, .h = 10 },
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        });
        defer bubble.deinit();

        // Role label with colored dot indicator + action icons on assistant rows
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = mi + 71500,
                .expand = .horizontal,
            });
            defer hdr.deinit();

            // Colored dot indicator for sender distinction
            const dot_color = if (is_user) theme.colors.accent else theme.colors.success;
            _ = dvui.label(@src(), "●", .{}, .{
                .id_extra = mi + 70900,
                .color_text = dot_color,
                .margin = .{ .w = 6 },
                .gravity_y = 0.5,
            });
            _ = dvui.label(@src(), "{s}", .{if (is_user) "You" else "AI"}, .{
                .id_extra = mi + 71000,
                .color_text = if (is_user) theme.colors.accent else theme.colors.text_muted,
                .gravity_y = 0.5,
            });
            if (!is_user) {
                { var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal }); sp.deinit(); }
                // Star toggle
                var star_wd: dvui.WidgetData = undefined;
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"star", .{}, .{}, .{
                    .id_extra = mi + 71700,
                    .data_out = &star_wd,
                    .color_text = if (m.starred)
                        dvui.Color{ .r = 255, .g = 200, .b = 80, .a = 255 }
                    else
                        theme.colors.text_dim,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                    .min_size_content = .{ .w = 12, .h = 12 },
                })) {
                    ai_chat.toggleStar(mi);
                }
                components.tip(@src(), star_wd, if (m.starred) "Unfavorite" else "Favorite");
                var regen_wd: dvui.WidgetData = undefined;
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"rotate-ccw", .{}, .{}, .{
                    .id_extra = mi + 71800,
                    .data_out = &regen_wd,
                    .color_text = theme.colors.text_dim,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                    .min_size_content = .{ .w = 12, .h = 12 },
                })) {
                    ai_chat.regenerateFrom(mi);
                }
                components.tip(@src(), regen_wd, "Regenerate");
            }
        }
        _ = dvui.label(@src(), "{s}", .{m.text[0..m.text_len]}, .{
            .id_extra = mi + 72000,
            .color_text = theme.colors.text_main,
            .margin = .{ .y = 2 },
        });
    }

    {
        const label = ai_chat.phaseLabel(ai_chat.phase);
        if (label.len > 0) {
            _ = dvui.label(@src(), "{s}", .{label}, .{
                .color_text = theme.colors.text_muted,
                .margin = .{ .x = 4, .y = 4, .w = 0, .h = 0 },
            });
        }
    }
}

pub fn computeGridColumns() usize {
    if (state.app.fullscreen_player_idx != null) return 1;
    const n = state.app.players.items.len;
    if (n <= 1) return 1;

    return switch (state.app.grid_mode) {
        .auto => blk: {
            const w: f32 = @floatFromInt(state.app.win_w);
            const h: f32 = @floatFromInt(state.app.win_h);
            
            if (w <= 0 or h <= 0) break :blk if (n <= 4) @as(usize, 2) else 3;
            
            const target_ratio: f32 = 16.0 / 9.0;
            var best_cols: usize = 1;
            var max_area: f32 = 0;
            
            var col_idx: usize = 1;
            while (col_idx <= n) : (col_idx += 1) {
                const c_f: f32 = @floatFromInt(col_idx);
                const r_i = (n + col_idx - 1) / col_idx;
                const r_f: f32 = @floatFromInt(r_i);
                
                const cell_w = w / c_f;
                const cell_h = h / r_f;
                
                const possible_w = @min(cell_w, cell_h * target_ratio);
                const possible_h = possible_w / target_ratio;
                
                const area = possible_w * possible_h;
                if (area > max_area) {
                    max_area = area;
                    best_cols = col_idx;
                }
            }
            break :blk best_cols;
        },
        .cols_1 => 1,
        .cols_2 => 2,
        .cols_3 => 3,
        .cols_4 => 4,
    };
}

pub fn muteBackgroundPlayers() void {
    // Only update volume when active player changes (not every frame)
    const VS = struct { var last_active: usize = 999; };
    if (VS.last_active == state.app.active_player_idx) return;
    VS.last_active = state.app.active_player_idx;
    
    for (state.app.players.items, 0..) |p, i| {
        if (i == state.app.active_player_idx) {
            // Restore active cell volume
            var vol_cmd: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&vol_cmd, "set volume {d}", .{@as(i32, @intFromFloat(p.cell_volume))})) |cmd| {
                _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
            } else |_| {}
        } else {
            _ = c.mpv.mpv_command_string(p.mpv_ctx, "set volume 0");
        }
    }
}

pub fn renderGrid() !void {
    const grid_columns = computeGridColumns();
    muteBackgroundPlayers();

    var grid_wrapper = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer grid_wrapper.deinit();

    var current_row: ?*dvui.BoxWidget = null;
    var draw_col: usize = 0;

    for (state.app.players.items, 0..) |p, i| {
        if (state.app.fullscreen_player_idx != null and state.app.fullscreen_player_idx.? != i) continue;

        if (draw_col % grid_columns == 0) {
            if (current_row != null) current_row.?.deinit();
            current_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = draw_col, .min_size_content = .{ .w = 10, .h = 10 }, .expand = .both });
        }
        draw_col += 1;

        const is_active = i == state.app.active_player_idx and state.app.players.items.len > 1;
        const cell_color = if (is_active) theme.colors.active_border else theme.colors.bg_app;
        // Top-only 2px accent for active cell. Full border bled into player UI edges.
        const border_rect: dvui.Rect = if (is_active)
            .{ .x = 0, .y = 2, .w = 0, .h = 0 }
        else
            .{ .x = 0, .y = 0, .w = 0, .h = 0 };

        // Cap cell width so text-heavy panes (browser) can't push other cells away
        const grid_w = grid_wrapper.data().borderRectScale().r.w;
        const max_cell_w: f32 = if (grid_columns > 0 and grid_w > 0) grid_w / @as(f32, @floatFromInt(grid_columns)) else 9999;
        
        var cell_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .min_size_content = .{ .w = 10, .h = 10 }, .max_size_content = .{ .w = max_cell_w, .h = std.math.floatMax(f32) }, .expand = .both, .background = true, .color_fill = dvui.Color.black, .color_border = cell_color, .border = border_rect, .margin = dvui.Rect.all(2), .corner_radius = dvui.Rect.all(2) });
        
        // Single wrapper overlay — ensures video content and control badges layer
        // rather than splitting the cell height vertically
        var cell_wrapper = dvui.overlay(@src(), .{ .id_extra = i + 11000, .expand = .both });
        
        // When not showing MPV, still drain its render context to prevent blocking
        if (p.provider != .mpv) {
            const flags = c.mpv.mpv_render_context_update(p.mpv_gl);
            if ((flags & c.mpv.MPV_RENDER_UPDATE_FRAME) != 0) {
                const size = [2]c_int{ player.video_w, player.video_h };
                const img_format = "rgba";
                const pitch: usize = player.video_w * 4;
                var drain_params = [_]c.mpv.mpv_render_param{
                    .{ .type = c.mpv.MPV_RENDER_PARAM_SW_SIZE, .data = @constCast(&size) },
                    .{ .type = c.mpv.MPV_RENDER_PARAM_SW_FORMAT, .data = @constCast(img_format.ptr) },
                    .{ .type = c.mpv.MPV_RENDER_PARAM_SW_STRIDE, .data = @constCast(&pitch) },
                    .{ .type = c.mpv.MPV_RENDER_PARAM_SW_POINTER, .data = p.pixels.ptr },
                    .{ .type = c.mpv.MPV_RENDER_PARAM_INVALID, .data = null },
                };
                _ = c.mpv.mpv_render_context_render(p.mpv_gl, &drain_params);
            }
        }

        switch (p.provider) {
        .mpv => {
        // ── MPV Video Player ──
        const flags = c.mpv.mpv_render_context_update(p.mpv_gl);
        const size = [2]c_int{ player.video_w, player.video_h };
        const img_format = "rgba";
        const pitch: usize = player.video_w * 4;
        var render_params = [_]c.mpv.mpv_render_param{
            .{ .type = c.mpv.MPV_RENDER_PARAM_SW_SIZE, .data = @constCast(&size) },
            .{ .type = c.mpv.MPV_RENDER_PARAM_SW_FORMAT, .data = @constCast(img_format.ptr) },
            .{ .type = c.mpv.MPV_RENDER_PARAM_SW_STRIDE, .data = @constCast(&pitch) },
            .{ .type = c.mpv.MPV_RENDER_PARAM_SW_POINTER, .data = p.pixels.ptr },
            .{ .type = c.mpv.MPV_RENDER_PARAM_INVALID, .data = null },
        };

        if ((flags & c.mpv.MPV_RENDER_UPDATE_FRAME) != 0) {
            if (c.mpv.mpv_render_context_render(p.mpv_gl, &render_params) >= 0) {
                // MPV renders with "rgba" format — alpha is already 0xFF, no fill needed
                if (p.texture == null) {
                    p.texture = try dvui.textureCreate(p.pixels, player.video_w, player.video_h, .linear, .rgba_32);
                } else {
                    try dvui.Texture.update(&p.texture.?, p.pixels, .linear);
                }
                // First frame rendered — clear loading state
                p.is_loading = false;
                // Try to resume from saved position on first frame
                p.tryResumePosition();
                // Only request UI refresh when we actually have a new video frame
                dvui.refresh(null, @src(), null);
            }
        }
        
        // Periodic position save (every ~120 frames ≈ 4 sec)
        p.save_counter +%= 1;
        if (p.save_counter % 120 == 0) {
            p.saveCurrentPosition();
        }

        if (p.texture) |*tex| {
            var cell_overlay = dvui.overlay(@src(), .{ .id_extra = i, .expand = .both });
            const img_wd = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{ .id_extra = i, .min_size_content = .{ .w = 10, .h = 10 }, .expand = .both, .gravity_x = 0.5, .gravity_y = 0.5 });
            
            for (dvui.events()) |*e| {
                if (e.evt == .mouse) {
                    const me = e.evt.mouse;
                    if (me.p.x >= img_wd.rect.x and me.p.x <= img_wd.rect.x + img_wd.rect.w and me.p.y >= img_wd.rect.y and me.p.y <= img_wd.rect.y + img_wd.rect.h) {
                        if (me.action == .press and me.button == .left) {
                            state.app.active_player_idx = i;
                            // Double-click detection → fullscreen toggle
                            const DblClick = struct {
                                var last_click_ms: i64 = 0;
                                var last_click_cell: usize = 999;
                            };
                            const now_ms = @import("../core/io_global.zig").milliTimestamp();
                            if (DblClick.last_click_cell == i and now_ms - DblClick.last_click_ms < 500) {
                                // Double-click: toggle fullscreen
                                if (state.app.fullscreen_player_idx == null) {
                                    state.app.fullscreen_player_idx = i;
                                } else {
                                    state.app.fullscreen_player_idx = null;
                                }
                                DblClick.last_click_ms = 0; // reset to prevent triple-click
                            } else {
                                // Single click: toggle pause
                                p.togglePause();
                                DblClick.last_click_ms = now_ms;
                                DblClick.last_click_cell = i;
                            }
                        } else if (me.action == .release and me.button == .left) {
                            if (state.app.dragging_magnet_len > 0) {
                                state.app.active_player_idx = i;
                                search.loadTorrentToPlayer(state.app.dragging_magnet_buf[0..state.app.dragging_magnet_len]);
                            }
                        }
                    }
                }
            }

            if (p.is_torrent and (!p.torrent_is_ready or p.is_buffering_paused)) {
                // Background darkener overlay
                var dim_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .both, .background = true, .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 210 }, .corner_radius = theme.dims.rad_sm });
                dim_box.deinit();
                
                var o_lay = dvui.overlay(@src(), .{ .id_extra = i, .expand = .both });
                defer o_lay.deinit();
                
                var loading_box = dvui.box(@src(), .{ .dir = .vertical }, .{ 
                    .id_extra = i,
                    .gravity_y = 0.5, 
                    .gravity_x = 0.5, 
                    .background = true, 
                    .color_fill = theme.colors.bg_glass,
                    .color_border = theme.colors.border_glass,
                    .border = dvui.Rect.all(1),
                    .padding = theme.dims.pad_lg,
                    .margin = dvui.Rect.all(20),
                    .corner_radius = theme.dims.rad_lg,
                    .min_size_content = .{ .w = 320, .h = 10 }
                });
                
                var t_name: [256]u8 = undefined;
                c.mpv.torrent_get_name(state.app.torrent_ses, p.current_torrent_id, &t_name, 256);
                const name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse 255;
                
                _ = dvui.label(@src(), "{s}", .{t_name[0..name_len]}, .{ .color_text = theme.colors.text_main, .margin = dvui.Rect{ .x=0, .y=4, .w=0, .h=0 } });
                
                var buf_pct: f32 = 0;
                var dl_rate: i32 = 0;
                var peers: i32 = 0;
                var buf_path: [512]u8 = undefined;
                
                if (p.current_torrent_id >= 0) {
                    _ = c.mpv.torrent_poll(state.app.torrent_ses, p.current_torrent_id, p.selected_file_idx, &buf_path, 512, &buf_pct, &dl_rate, &peers);
                }
                
                const is_dead = p.metadata_start_time > 0 and @import("../core/io_global.zig").timestamp() - p.metadata_start_time > 15 and peers == 0 and !p.has_metadata;

                if (is_dead) {
                    _ = dvui.label(@src(), "Dead Torrent ❌", .{}, .{ .color_text = theme.colors.danger, .margin = dvui.Rect{ .x=0, .y=8, .w=0, .h=0 } });
                    _ = dvui.label(@src(), "No peers found after 15 seconds.", .{}, .{ .color_text = theme.colors.text_muted, .margin = dvui.Rect{ .x=0, .y=8, .w=0, .h=0 } });
                    if (dvui.button(@src(), "Close Stream", .{}, .{ .color_fill = theme.colors.danger, .color_text = dvui.Color.white })) {
                        p.current_torrent_id = -1;
                        p.is_torrent = false;
                        p.torrent_is_ready = false;
                        p.has_metadata = false;
                        p.metadata_start_time = 0;
                        if (state.app.active_player_idx == i) state.app.active_player_idx = 0;
                    }
                } else {
                    const dr_mb = @as(f32, @floatFromInt(dl_rate)) / (1024.0 * 1024.0);
                    var status_lb: [128]u8 = undefined;
                    if (std.fmt.bufPrintZ(&status_lb, "Downloading: {d:.1} MB/s | {d} Peers", .{dr_mb, peers})) |msg| {
                        _ = dvui.label(@src(), "{s}", .{msg}, .{ .color_text = theme.colors.accent, .margin = .{ .y=8 } });
                    } else |_| {}
                    
                    var prog_lb: [64]u8 = undefined;
                    if (std.fmt.bufPrintZ(&prog_lb, "Buffer: {d}%", .{@as(i32, @intFromFloat(buf_pct * 100.0))})) |msg| {
                        components.ProgressBar(@src(), buf_pct, msg, i);
                    } else |_| {}
                }
                
                loading_box.deinit();

            } else if (p.is_buffering_paused) {
                var loading_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ 
                    .id_extra = i,
                    .gravity_y = 0.5, 
                    .gravity_x = 0.5, 
                    .background = true, 
                    .color_fill = theme.colors.bg_glass,
                    .padding = theme.dims.pad_md,
                    .corner_radius = theme.dims.rad_md
                });
                _ = dvui.label(@src(), "⏳ Initializing network...", .{}, .{ .color_text = theme.colors.text_muted });
                loading_box.deinit();
            }

            if (state.app.show_cell_overlay) {
                var tr_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = i,
                    .expand = .none,
                    .gravity_x = 1.0, 
                    .gravity_y = 0.0,
                    .padding = dvui.Rect.all(8)
                });
                
                var x_bg = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = i,
                    .background = true,
                    .color_fill = dvui.Color{ .r=20, .g=20, .b=20, .a=180 },
                    .corner_radius = dvui.Rect.all(99),
                    .padding = theme.dims.pad_xs
                });

                if (dvui.buttonIcon(@src(), "CellClose", icons.tvg.lucide.@"x", .{}, .{}, .{ .id_extra = i, .color_text = theme.colors.danger, .color_fill = .{ .r=0,.g=0,.b=0,.a=0 }, .border = dvui.Rect.all(0) })) {
                    state.app.pending_remove_player_idx = @as(i32, @intCast(i));
                }
                
                x_bg.deinit();
                tr_box.deinit();
            }

            cell_overlay.deinit();

            // ── Recording indicator (red pulsing REC dot) ──
            {
                const sl = @import("../services/streamlink.zig");
                if (sl.is_recording) {
                    var rec_overlay = dvui.overlay(@src(), .{ .id_extra = i + 7000, .expand = .both });
                    var rec_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = i + 7001,
                        .gravity_x = 0.0,
                        .gravity_y = 0.0,
                        .background = true,
                        .color_fill = dvui.Color{ .r = 180, .g = 20, .b = 20, .a = 200 },
                        .corner_radius = dvui.Rect.all(6),
                        .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                        .margin = .{ .x = 8, .y = 8, .w = 0, .h = 0 },
                    });
                    _ = dvui.label(@src(), "● REC", .{}, .{
                        .id_extra = i + 7002,
                        .color_text = dvui.Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
                    });
                    rec_box.deinit();
                    rec_overlay.deinit();
                }
            }
        } else if (p.is_loading) {
            // ── Loading indicator — shown immediately on load_file() ──
            // Polished: uses components.emptyState for the canonical
            // "loading" surface plus the source path beneath it.
            var load_overlay = dvui.overlay(@src(), .{ .id_extra = i, .expand = .both });
            {
                // Dark backdrop captures clicks to select this pane.
                if (dvui.button(@src(), "", .{}, .{ .id_extra = i + 3000, .expand = .both, .color_fill = theme.colors.bg_app })) {
                    state.app.active_player_idx = i;
                }

                var load_stack = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = i + 3100,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .both,
                });
                defer load_stack.deinit();

                components.emptyState(icons.tvg.lucide.@"hourglass", "Loading...", "");

                // Truncated source path beneath the canonical empty state.
                if (p.loading_label_len > 0) {
                    const src_text = p.loading_label[0..p.loading_label_len];
                    const display = if (src_text.len > 45) src_text[src_text.len - 45 ..] else src_text;
                    _ = dvui.label(@src(), "{s}", .{display}, .{
                        .id_extra = i + 4002,
                        .color_text = theme.colors.text_tertiary,
                        .gravity_x = 0.5,
                        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 8 },
                    });
                }
            }
            load_overlay.deinit();
            dvui.refresh(null, @src(), null);
        } else {
            var is_audio_only = false;
            if (p.torrent_is_ready) {
                const vid_str = c.mpv.mpv_get_property_string(p.mpv_ctx, "vid");
                if (vid_str != null) {
                    defer c.mpv.mpv_free(@ptrCast(vid_str));
                    if (std.mem.eql(u8, std.mem.span(vid_str), "no")) {
                        is_audio_only = true;
                    }
                }
            }

            const header = @import("header.zig");
            if (p.current_torrent_id < 0 and i == state.app.active_player_idx and header.shouldUrlInputBeInGrid()) {
                const ai_chat = @import("../services/ai_chat.zig");
                const has_chat = ai_chat.message_count > 0 or ai_chat.is_generating;

                var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = i,
                    .expand = .both,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                });

                var card = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = i,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .background = false,
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = 24, .y = 20, .w = 24, .h = 20 },
                    .min_size_content = .{ .w = 620, .h = 0 },
                    .max_size_content = .{ .w = 760, .h = std.math.floatMax(f32) },
                });

                // Input bar first — primary action, immediately reachable
                header.renderUrlInput(true);

                // Continue Watching — returning users want this front and center
                renderContinueWatching();

                if (!has_chat) {
                    // Compact drop zone hint below the content
                    { var gap = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 0, .h = 8 }, .expand = .horizontal }); gap.deinit(); }
                    _ = dvui.icon(@src(), "", icons.tvg.lucide.@"cloud-upload", .{}, .{
                        .color_text = theme.colors.text_dim,
                        .min_size_content = .{ .w = 28, .h = 28 },
                        .gravity_x = 0.5,
                    });
                    _ = dvui.label(@src(), "Drop media or paste a URL", .{}, .{
                        .color_text = theme.colors.text_dim,
                        .margin = .{ .y = 4 },
                        .gravity_x = 0.5,
                    });
                } else {
                    renderInlineChat();
                }

                // ── Context chip: shows what AI "sees" (current media + time) ──
                {
                    const voice = @import("../services/ai_voice.zig");
                    const has_media = state.app.players.items.len > 0;
                    if (has_media) {
                        const ap = state.app.players.items[state.app.active_player_idx];
                        var title_buf: [128]u8 = undefined;
                        const title_len = ap.getMediaTitle(&title_buf);
                        const media_label = title_buf[0..title_len];
                        var chip_buf: [256]u8 = undefined;
                        if (media_label.len > 0) {
                            const chip_txt = std.fmt.bufPrint(&chip_buf, "Seeing: {s}", .{media_label}) catch "";
                            if (chip_txt.len > 0) {
                                var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
                                    .margin = .{ .y = 6 },
                                    .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
                                    .background = true,
                                    .color_fill = dvui.Color{ .r = 24, .g = 24, .b = 38, .a = 180 },
                                    .color_border = dvui.Color{ .r = 50, .g = 50, .b = 70, .a = 180 },
                                    .border = dvui.Rect.all(1),
                                    .corner_radius = dvui.Rect.all(6),
                                    .gravity_x = 0.5,
                                });
                                defer chip.deinit();
                                _ = dvui.icon(@src(), "", icons.tvg.lucide.@"bot", .{}, .{
                                    .color_text = theme.colors.accent,
                                    .min_size_content = .{ .w = 12, .h = 12 },
                                    .margin = .{ .w = 6 },
                                    .gravity_y = 0.5,
                                });
                                _ = dvui.label(@src(), "{s}", .{chip_txt}, .{
                                    .color_text = theme.colors.text_muted,
                                    .gravity_y = 0.5,
                                });
                            }
                        }
                    }

                    // Status line (Listening / Thinking / Speaking)
                    const ai_chat_mod = @import("../services/ai_chat.zig");
                    const phase_txt: ?[]const u8 = switch (voice.conv_phase) {
                        .listening => "Listening…",
                        .transcribing => "Transcribing…",
                        .thinking => "Thinking…",
                        .speaking => "Speaking…",
                        .idle => if (ai_chat_mod.is_generating) "Thinking…" else null,
                    };
                    if (phase_txt) |txt| {
                        var status_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .margin = .{ .y = 4 },
                            .gravity_x = 0.5,
                        });
                        defer status_row.deinit();
                        const phase_color: dvui.Color = switch (voice.conv_phase) {
                            .listening => .{ .r = 100, .g = 220, .b = 130, .a = 255 },
                            .speaking => .{ .r = 130, .g = 180, .b = 255, .a = 255 },
                            else => theme.colors.accent,
                        };
                        _ = dvui.icon(@src(), "", icons.tvg.lucide.@"activity", .{}, .{
                            .color_text = phase_color,
                            .min_size_content = .{ .w = 14, .h = 14 },
                            .margin = .{ .w = 6 },
                            .gravity_y = 0.5,
                        });
                        _ = dvui.label(@src(), "{s}", .{txt}, .{
                            .color_text = phase_color,
                            .gravity_y = 0.5,
                        });
                    }
                }

                if (has_chat) {
                    // Clear chat — two-step confirm to avoid accidental wipe.
                    // Uses a static Guard var so the confirm state survives
                    // across frames but resets if user clicks elsewhere.
                    const Guard = struct { var armed: bool = false; };
                    const label: []const u8 = if (Guard.armed) "Click again to confirm" else "Clear chat";
                    if (dvui.button(@src(), label, .{}, .{
                        .color_fill = if (Guard.armed)
                            dvui.Color{ .r = 55, .g = 20, .b = 20, .a = 255 }
                        else
                            dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                        .color_text = if (Guard.armed)
                            dvui.Color{ .r = 255, .g = 140, .b = 140, .a = 255 }
                        else
                            theme.colors.text_muted,
                        .border = dvui.Rect.all(0),
                        .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                        .margin = .{ .y = 8 },
                        .gravity_x = 0.5,
                        .corner_radius = dvui.Rect.all(4),
                    })) {
                        if (Guard.armed) {
                            ai_chat.clearHistory();
                            Guard.armed = false;
                        } else {
                            Guard.armed = true;
                        }
                    }
                }

                card.deinit();
                outer.deinit();
            } else {
                // Empty / pre-buffer state for an idle player cell.
                // Loading states get the hourglass empty-state; the truly
                // empty (no torrent, no media) state gets the library
                // empty-state with a "Search above" hint.
                const is_loading_torrent = p.current_torrent_id >= 0;
                const placeholder_text = if (is_loading_torrent)
                    (if (!p.torrent_is_ready)
                        (if (p.has_metadata) "Buffering first video parts..." else "Loading torrent metadata...")
                    else (if (is_audio_only) "Audio stream playing" else "Buffering video stream..."))
                    else "Nothing here yet";
                const placeholder_hint: []const u8 = if (is_loading_torrent)
                    ""
                else
                    "Search above to find something to watch.";
                const placeholder_icon = if (is_loading_torrent)
                    icons.tvg.lucide.@"hourglass"
                else
                    icons.tvg.lucide.@"library";

                // Transparent overlay captures clicks to select this pane
                // without painting over the centered empty-state widget.
                var placeholder_overlay = dvui.overlay(@src(), .{
                    .id_extra = i + 5500,
                    .expand = .both,
                });
                defer placeholder_overlay.deinit();

                if (dvui.button(@src(), "", .{}, .{
                    .id_extra = i + 5510,
                    .expand = .both,
                    .color_fill = theme.colors.bg_drawer,
                    .color_text = theme.colors.text_main,
                    .border = dvui.Rect.all(0),
                    .corner_radius = theme.dims.rad_sm,
                })) {
                    state.app.active_player_idx = i;
                }

                components.emptyState(placeholder_icon, placeholder_text, placeholder_hint);
            }
        }
        }, // end .mpv

        .comic_viewer => {
            // ── Comic Viewer Pane ──
            const comics = @import("../services/comics.zig");
            
            // Click to select pane
            if (dvui.button(@src(), "", .{}, .{
                .id_extra = i + 5000,
                .expand = .both,
                .color_fill = dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
            })) {
                state.app.active_player_idx = i;
            }
            
            if (state.app.comic.page_count == 0 and !state.app.comic.is_loading) {
                components.emptyState(icons.tvg.lucide.@"book", "Comic Viewer", "Open a comic to start reading.");
            } else {
                comics.renderPaneContent(i);
            }
        },

        .browser => {
            // ── Browser Pane ──
            const browser = @import("../services/browser.zig");
            browser.renderPaneContent(i);
        },
        } // end switch
        

        
        
        cell_wrapper.deinit();
        cell_box.deinit();
    }
    
    if (current_row != null) current_row.?.deinit();
}

/// "Continue Watching" strip rendered on the empty home screen. Surfaces the
/// top few in-progress items from watch history with a progress bar; click
/// resumes at the saved position (player.tryResumePosition handles the seek).
fn renderContinueWatching() void {
    const watch_history = @import("../player/watch_history.zig");
    if (watch_history.count == 0) return;

    // Collect up to 6 entries that are not already completed. Treat >=95% as
    // finished so the row stays curated.
    const MAX_SHOW: usize = 6;
    var show_idx: [MAX_SHOW]usize = undefined;
    var show_count: usize = 0;
    var wi: usize = 0;
    while (wi < watch_history.count and show_count < MAX_SHOW) : (wi += 1) {
        const e = watch_history.entries[wi];
        if (e.name_len == 0) continue;
        if (e.percent >= 95.0) continue;
        show_idx[show_count] = wi;
        show_count += 1;
    }
    if (show_count == 0) return;

    // Header row: section header + Clear button
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer hdr.deinit();

        // Section header takes the left side and expands; Clear button sits
        // on the right edge. Wrapping in a flex row keeps the header's
        // built-in vertical margin (spacing.lg above, sm below).
        {
            var header_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
            defer header_col.deinit();
            components.sectionHeader("Continue Watching");
        }

        if (dvui.button(@src(), "Clear", .{}, .{
            .id_extra = 43900,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_tertiary,
            .border = dvui.Rect.all(0),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .gravity_y = 0.5,
        })) {
            watch_history.clearAll();
            state.showToast("Watch history cleared");
            return;
        }
    }

    var strip = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .y = 2 },
    });
    defer strip.deinit();

    for (0..show_count) |si| {
        const idx = show_idx[si];
        const e = watch_history.entries[idx];
        const raw_name = e.name[0..e.name_len];

        // Display-name cleanup is shared with poster tiles so every
        // surface gets identical formatting.
        var clean_buf: [128]u8 = undefined;
        const display_name = cleanDisplayName(&clean_buf, raw_name);
        const disp = display_name[0..@min(display_name.len, 56)];

        const pct_f = std.math.clamp(e.percent, 0.0, 100.0);
        const pct = @as(u8, @intFromFloat(pct_f));

        // ── Card container ──
        // Per spec: padding spacing.md, bg_surface fill, radius.lg corners,
        // 1px border_subtle outline. Gap between cards = spacing.sm.
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = si + 43000,
            .expand = .horizontal,
            .padding = dvui.Rect.all(theme.spacing.md),
            .margin = .{ .x = 0, .y = theme.spacing.sm / 2, .w = 0, .h = theme.spacing.sm / 2 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(theme.radius.lg),
        });
        defer card.deinit();

        // Top row: play icon + title + percentage pill + resume button
        {
            var top_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = si + 43050,
                .expand = .horizontal,
            });
            defer top_row.deinit();

            _ = dvui.icon(@src(), "", icons.tvg.lucide.@"play", .{}, .{
                .id_extra = si + 43100,
                .color_text = theme.colors.accent_primary,
                .min_size_content = .{ .w = 14, .h = 14 },
                .margin = .{ .w = theme.spacing.sm },
                .gravity_y = 0.5,
            });

            _ = dvui.label(@src(), "{s}", .{disp}, .{
                .id_extra = si + 43200,
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
                .expand = .horizontal,
            });

            // Percentage as a status pill (info — themed accent).
            var pct_buf: [32]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d}% watched", .{pct}) catch "0% watched";
            components.statusPill(pct_str, .info);

            // Resume button — 36px tall, accent_primary bg, text_on_accent
            // text, radius.md corners. Hover lifts the fill via dvui.clicked
            // tracking; we paint the brighter accent_hover when hovered.
            var resume_hovered: bool = false;
            // Use a transparent pre-pass to get the hovered state, then a
            // styled button. dvui doesn't expose hover-pass on dvui.button
            // directly, but we can rely on bg_card_hover semantics by
            // toggling fill in subsequent frames. For now we use
            // accent_primary baseline and accent_hover when hovered via
            // a separate hover box.
            const resume_clicked = dvui.button(@src(), "Resume", .{}, .{
                .id_extra = si + 43400,
                .color_fill = if (resume_hovered) theme.colors.accent_hover else theme.colors.accent_primary,
                .color_text = theme.colors.text_on_accent,
                .corner_radius = dvui.Rect.all(theme.radius.md),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
                .min_size_content = .{ .w = 0, .h = 36 },
                .max_size_content = .{ .w = std.math.floatMax(f32), .h = 36 },
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
            // Suppress unused-var warning while keeping the hover hook
            // ready for a future frame-aware highlight.
            _ = &resume_hovered;
            if (resume_clicked) {
                if (state.app.active_player_idx < state.app.players.items.len) {
                    const browser = @import("../services/browser.zig");
                    // Watch history stores both the display name and the
                    // original URL/magnet/path. Routing must use the URL —
                    // the display name has no extension or domain so it
                    // routes to .browser and opens the HTML browser
                    // instead of mpv.
                    const url_to_load = if (e.link_len > 0) e.link[0..e.link_len] else raw_name;
                    browser.loadContent(url_to_load);
                    state.showToast("Resuming...");
                }
            }
        }

        // Bottom: thin progress bar spanning full width.
        // 3px tall, bg_elevated track, accent_primary fill, radius.sm.
        {
            const bar_h: f32 = 3;
            var bar_track = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = si + 43500,
                .expand = .horizontal,
                .background = true,
                .color_fill = theme.colors.bg_elevated,
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .min_size_content = .{ .w = 0, .h = bar_h },
                .max_size_content = .{ .w = std.math.floatMax(f32), .h = bar_h },
                .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
            });

            // Fill portion (proportional width inside the track).
            const fill_frac: f32 = @floatCast(pct_f / 100.0);
            var fill_box = dvui.box(@src(), .{}, .{
                .id_extra = si + 43600,
                .background = true,
                .color_fill = theme.colors.accent_primary,
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .min_size_content = .{ .w = fill_frac * 600, .h = bar_h },
                .max_size_content = .{ .w = fill_frac * 600, .h = bar_h },
            });
            fill_box.deinit();

            bar_track.deinit();
        }
    }
}

