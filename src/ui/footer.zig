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

pub fn aspectDropdownMenu(ctx: *c.mpv.mpv_handle, id_extra: usize) void {
    const aspect_c = c.mpv.mpv_get_property_string(ctx, "video-aspect-override");
    defer if (aspect_c != null) c.mpv.mpv_free(@ptrCast(aspect_c));

    const aspect_val = if (aspect_c != null) std.mem.span(aspect_c) else "-1";
    var current_ar: []const u8 = "Auto";
    if (std.mem.eql(u8, aspect_val, "16:9") or std.mem.startsWith(u8, aspect_val, "1.77")) current_ar = "16:9";
    if (std.mem.eql(u8, aspect_val, "4:3") or std.mem.startsWith(u8, aspect_val, "1.33")) current_ar = "4:3";
    if (std.mem.eql(u8, aspect_val, "21:9") or std.mem.startsWith(u8, aspect_val, "2.33")) current_ar = "21:9";

    var btn_lbl: [32]u8 = undefined;
    const label = std.fmt.bufPrintZ(&btn_lbl, "{s}", .{current_ar}) catch "AR";



    if (dvui.menuItemLabel(@src(), label, .{ .submenu = true }, .{ .id_extra = id_extra, .gravity_y = 0.5, .color_fill = dvui.Color{ .r=0, .g=0, .b=0, .a=0 }, .color_text = theme.colors.text_muted })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = theme.colors.bg_drawer, .border = dvui.Rect.all(1), .color_border = theme.colors.border_drawer });
        defer menu.deinit();

        const modes = [_][]const u8{ "-1", "16:9", "4:3", "21:9" };
        const mode_labels = [_][]const u8{ "Auto", "16:9", "4:3", "21:9" };
        
        for (modes, 0..) |mode, k| {
            if (dvui.menuItemLabel(@src(), mode_labels[k], .{}, .{ .id_extra = k, .expand = .horizontal, .color_text = theme.colors.text_main })) |_| {
                var set_cmd_buf: [64]u8 = undefined;
                if (std.fmt.bufPrintZ(&set_cmd_buf, "set video-aspect-override \"{s}\"", .{mode})) |cmd| {
                    _ = c.mpv.mpv_command_string(ctx, cmd.ptr);
                } else |_| {}
            }
        }
    }
}

pub fn trackDropdownMenu(ctx: *c.mpv.mpv_handle, track_type: []const u8) void {
    var count: i64 = 0;
    _ = c.mpv.mpv_get_property(ctx, "track-list/count", c.mpv.MPV_FORMAT_INT64, &count);
    
    var active_title: []const u8 = "None";
    var active_buf: [32]u8 = undefined;
    
    for (0..@intCast(count)) |i| {
        var qtype_buf: [64]u8 = undefined;
        const type_query = std.fmt.bufPrintZ(&qtype_buf, "track-list/{d}/type", .{i}) catch continue;
        const t_type_c = c.mpv.mpv_get_property_string(ctx, type_query.ptr);
        if (t_type_c != null) {
            defer c.mpv.mpv_free(@ptrCast(t_type_c));
            if (std.mem.eql(u8, std.mem.span(t_type_c), track_type)) {
                var qsel_buf: [64]u8 = undefined;
                const sel_query = std.fmt.bufPrintZ(&qsel_buf, "track-list/{d}/selected", .{i}) catch continue;
                const sel_c = c.mpv.mpv_get_property_string(ctx, sel_query.ptr);
                if (sel_c != null) {
                    defer c.mpv.mpv_free(@ptrCast(sel_c));
                    if (std.mem.eql(u8, std.mem.span(sel_c), "yes")) {
                        var qlang_buf: [64]u8 = undefined;
                        const lang_q = std.fmt.bufPrintZ(&qlang_buf, "track-list/{d}/lang", .{i}) catch continue;
                        const lang_c = c.mpv.mpv_get_property_string(ctx, lang_q.ptr);
                        if (lang_c != null) {
                            defer c.mpv.mpv_free(@ptrCast(lang_c));
                            active_title = std.fmt.bufPrint(&active_buf, "{s}", .{std.mem.span(lang_c)}) catch "Err";
                        } else {
                            var qtitle_buf: [64]u8 = undefined;
                            const title_q = std.fmt.bufPrintZ(&qtitle_buf, "track-list/{d}/title", .{i}) catch continue;
                            const title_c = c.mpv.mpv_get_property_string(ctx, title_q.ptr);
                            if (title_c != null) {
                                defer c.mpv.mpv_free(@ptrCast(title_c));
                                active_title = std.fmt.bufPrint(&active_buf, "{s}", .{std.mem.span(title_c)}) catch "Err";
                            }
                        }
                    }
                }
            }
        }
    }

    var btn_lbl: [80]u8 = undefined;
    const is_aud = std.mem.eql(u8, track_type, "audio");
    const label = std.fmt.bufPrintZ(&btn_lbl, "{s}", .{active_title}) catch "Trax";
    const kind_id: usize = if (is_aud) 1 else 2;



    if (dvui.menuItemLabel(@src(), label, .{ .submenu = true }, .{ .id_extra = kind_id, .gravity_y = 0.5, .color_fill = dvui.Color{ .r=0, .g=0, .b=0, .a=0 }, .color_text = theme.colors.text_muted })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = theme.colors.bg_drawer, .border = dvui.Rect.all(1), .color_border = theme.colors.border_drawer });
        defer menu.deinit();

        for (0..@intCast(count)) |i| {
            var qtype_buf: [64]u8 = undefined;
            const type_query = std.fmt.bufPrintZ(&qtype_buf, "track-list/{d}/type", .{i}) catch continue;
            const t_type_c = c.mpv.mpv_get_property_string(ctx, type_query.ptr);
            if (t_type_c != null) {
                defer c.mpv.mpv_free(@ptrCast(t_type_c));
                if (std.mem.eql(u8, std.mem.span(t_type_c), track_type)) {
                    var t_id: i64 = 0;
                    var qid_buf: [64]u8 = undefined;
                    const id_query = std.fmt.bufPrintZ(&qid_buf, "track-list/{d}/id", .{i}) catch continue;
                    _ = c.mpv.mpv_get_property(ctx, id_query.ptr, c.mpv.MPV_FORMAT_INT64, &t_id);

                    var row_name: []const u8 = "Unknown Track";
                    var name_buf: [64]u8 = undefined;
                    
                    var qlang_buf: [64]u8 = undefined;
                    const lang_q = std.fmt.bufPrintZ(&qlang_buf, "track-list/{d}/lang", .{i}) catch continue;
                    const lang_c = c.mpv.mpv_get_property_string(ctx, lang_q.ptr);
                    
                    if (lang_c != null) {
                        defer c.mpv.mpv_free(@ptrCast(lang_c));
                        row_name = std.fmt.bufPrint(&name_buf, "{s}", .{std.mem.span(lang_c)}) catch "Err";
                    } else {
                        var qtitle_buf: [64]u8 = undefined;
                        const title_q = std.fmt.bufPrintZ(&qtitle_buf, "track-list/{d}/title", .{i}) catch continue;
                        const title_c = c.mpv.mpv_get_property_string(ctx, title_q.ptr);
                        if (title_c != null) {
                            defer c.mpv.mpv_free(@ptrCast(title_c));
                            row_name = std.fmt.bufPrint(&name_buf, "{s}", .{std.mem.span(title_c)}) catch "Err";
                        } else {
                            row_name = std.fmt.bufPrint(&name_buf, "Track #{d}", .{i}) catch "Err";
                        }
                    }

                    if (dvui.menuItemLabel(@src(), row_name, .{}, .{ .id_extra = i, .expand = .horizontal, .color_text = theme.colors.text_main })) |_| {
                        var set_cmd_buf: [64]u8 = undefined;
                        const prop = if (is_aud) "aid" else "sid";
                        if (std.fmt.bufPrintZ(&set_cmd_buf, "set {s} {d}", .{prop, t_id})) |cmd| {
                            _ = c.mpv.mpv_command_string(ctx, cmd.ptr);
                        } else |_| {}
                    }
                }
            }
        }
    }
}

pub fn playlistDropdownMenu(p: *player.MediaPlayer) void {
    if (p.current_torrent_id < 0) return;

    const file_count = c.mpv.torrent_get_file_count(state.app.torrent_ses, p.current_torrent_id);
    if (file_count <= 1) return;



    if (dvui.menuItemLabel(@src(), "Files", .{ .submenu = true }, .{ .id_extra = 99, .gravity_y = 0.5, .color_fill = dvui.Color{ .r=0, .g=0, .b=0, .a=0 }, .color_text = theme.colors.text_muted })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = theme.colors.bg_drawer, .border = dvui.Rect.all(1), .color_border = theme.colors.border_drawer });
        defer menu.deinit();

        for (0..@intCast(file_count)) |i| {
            var name_buf: [256]u8 = undefined;
            c.mpv.torrent_get_file_name(state.app.torrent_ses, p.current_torrent_id, @intCast(i), &name_buf, 256);
            
            const size = c.mpv.torrent_get_file_size(state.app.torrent_ses, p.current_torrent_id, @intCast(i));
            const size_mb = @as(f64, @floatFromInt(size)) / 1024.0 / 1024.0;
            
            var lbl_buf: [300]u8 = undefined;
            const label = std.fmt.bufPrintZ(&lbl_buf, "{s} ({d:.1} MB)", .{ std.mem.sliceTo(&name_buf, 0), size_mb }) catch "File";

            if (dvui.menuItemLabel(@src(), label, .{}, .{ .id_extra = i, .expand = .horizontal,
                .color_text = if (p.selected_file_idx == @as(i32, @intCast(i))) theme.colors.accent else theme.colors.text_main,
            })) |_| {
                if (p.selected_file_idx != @as(i32, @intCast(i))) {
                    // Stop current playback immediately
                    _ = c.mpv.mpv_command_string(p.mpv_ctx, "stop");
                    
                    // Deprioritize old file, prioritize new one
                    const old_idx = p.selected_file_idx;
                    if (old_idx >= 0 and old_idx < file_count) {
                        c.mpv.torrent_set_file_priority(state.app.torrent_ses, p.current_torrent_id, old_idx, 0);
                    }
                    p.selected_file_idx = @as(i32, @intCast(i));
                    c.mpv.torrent_set_file_priority(state.app.torrent_ses, p.current_torrent_id, @intCast(i), 4);
                    p.torrent_is_ready = false; // Re-trigger load poll
                }
            }
        }
    }
}

/// Footer "Get subtitles" button — opens the floating picker + triggers an
/// auto-search against the currently playing media.
pub fn subtitlesButton() void {
    if (dvui.button(@src(), "Subs", .{}, .{
        .id_extra = 301,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = theme.colors.text_muted,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .gravity_y = 0.5,
    })) {
        state.app.sub_picker_open = true;
        const subs = @import("../services/subtitles.zig");
        if (!subs.is_searching) subs.autoSearchFromPlayer();
    }
}

pub fn subLanguageDropdown() void {
    const current_lang = state.app.sub_lang_buf[0..state.app.sub_lang_len];
    var btn_lbl: [16]u8 = undefined;
    const label = std.fmt.bufPrintZ(&btn_lbl, "{s}", .{current_lang}) catch "lang";
    
    if (dvui.menuItemLabel(@src(), label, .{ .submenu = true }, .{ .id_extra = 300, .gravity_y = 0.5, .color_fill = dvui.Color{ .r=0, .g=0, .b=0, .a=0 }, .color_text = theme.colors.text_muted })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = theme.colors.bg_drawer, .border = dvui.Rect.all(1), .color_border = theme.colors.border_drawer });
        defer menu.deinit();
        
        const langs = [_][]const u8{ "eng", "spa", "fre", "ger", "por", "ita", "dut", "pol", "rus", "chi", "jpn", "kor", "ara", "hin", "tur" };
        const lang_names = [_][]const u8{ "English", "Spanish", "French", "German", "Portuguese", "Italian", "Dutch", "Polish", "Russian", "Chinese", "Japanese", "Korean", "Arabic", "Hindi", "Turkish" };
        
        for (langs, 0..) |l, k| {
            if (dvui.menuItemLabel(@src(), lang_names[k], .{}, .{ .id_extra = k, .expand = .horizontal, .color_text = theme.colors.text_main })) |_| {
                @memcpy(state.app.sub_lang_buf[0..l.len], l);
                state.app.sub_lang_len = l.len;
            }
        }
    }
}

/// Quick-access subtitle picker. Triggered from the footer toolbar — one
/// click kicks off an auto-search and opens a floating modal listing hits.
pub fn renderSubPicker() void {
    if (!state.app.sub_picker_open) return;
    const subs = @import("../services/subtitles.zig");

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.sub_picker_open,
    }, .{
        .min_size_content = .{ .w = 560, .h = 420 },
        .color_fill = theme.colors.bg_drawer,
        .color_border = theme.colors.accent,
        .corner_radius = dvui.Rect.all(10),
    });
    defer win.deinit();

    win.dragAreaSet(dvui.windowHeader("Subtitles", "", &state.app.sub_picker_open));

    var pad = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 14, .y = 10, .w = 14, .h = 10 },
    });
    defer pad.deinit();

    var ctrl_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .y = 4 },
    });
    {
        defer ctrl_row.deinit();
        const lang = if (state.app.sub_lang_len > 0) state.app.sub_lang_buf[0..state.app.sub_lang_len] else "eng";
        var lbl_buf: [32]u8 = undefined;
        const lbl = std.fmt.bufPrint(&lbl_buf, "Lang: {s}", .{lang}) catch "Lang: eng";
        _ = dvui.label(@src(), "{s}", .{lbl}, .{
            .color_text = theme.colors.text_muted,
            .gravity_y = 0.5,
            .margin = .{ .w = 12 },
        });
        if (dvui.button(@src(), if (subs.is_searching) "Searching…" else "Auto-search", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = dvui.Rect.all(4),
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
            .gravity_y = 0.5,
            .margin = .{ .w = 6 },
        })) {
            if (!subs.is_searching) subs.autoSearchFromPlayer();
        }

        const auto_subs = @import("../services/auto_subs.zig");
        const gen_label = if (auto_subs.in_progress) "Generating…" else "Generate (whisper)";
        if (dvui.button(@src(), gen_label, .{}, .{
            .color_fill = theme.colors.accent_hover,
            .color_text = theme.colors.bg_header,
            .corner_radius = dvui.Rect.all(4),
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
            .gravity_y = 0.5,
        })) {
            if (!auto_subs.in_progress) auto_subs.transcribeCurrent();
        }
    }

    if (@import("../services/auto_subs.zig").status_len > 0) {
        const as_mod = @import("../services/auto_subs.zig");
        _ = dvui.label(@src(), "{s}", .{as_mod.status_buf[0..as_mod.status_len]}, .{
            .color_text = theme.colors.text_muted,
            .margin = .{ .y = 4 },
        });
    }

    if (subs.search_error_len > 0) {
        _ = dvui.label(@src(), "{s}", .{subs.search_error[0..subs.search_error_len]}, .{
            .color_text = theme.colors.warning,
            .margin = .{ .y = 4 },
        });
    }

    if (subs.result_count == 0 and !subs.is_searching) {
        _ = dvui.label(@src(), "No results yet. Click Auto-search.", .{}, .{
            .color_text = theme.colors.text_muted,
            .margin = .{ .y = 8 },
            .gravity_x = 0.5,
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 22, .a = 220 },
    });
    defer scroll.deinit();

    for (0..subs.result_count) |ri| {
        const r = &subs.results[ri];
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = ri + 58000,
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 22, .g = 22, .b = 34, .a = 200 },
            .color_border = dvui.Color{ .r = 50, .g = 50, .b = 70, .a = 160 },
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(6),
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .margin = .{ .y = 2 },
        });
        defer row.deinit();

        if (r.lang_len > 0) {
            _ = dvui.label(@src(), "{s}", .{r.language[0..r.lang_len]}, .{
                .id_extra = ri + 58100,
                .color_text = theme.colors.accent,
                .gravity_y = 0.5,
                .margin = .{ .w = 6 },
            });
        }
        if (r.release_len > 0) {
            const show_len = @min(r.release_len, 70);
            _ = dvui.label(@src(), "{s}", .{r.release[0..show_len]}, .{
                .id_extra = ri + 58200,
                .color_text = theme.colors.text_main,
                .gravity_y = 0.5,
                .expand = .horizontal,
            });
        }
        if (r.download_count > 0) {
            var dc_buf: [16]u8 = undefined;
            const dc_str = std.fmt.bufPrint(&dc_buf, "↓{d}", .{r.download_count}) catch "";
            _ = dvui.label(@src(), "{s}", .{dc_str}, .{
                .id_extra = ri + 58300,
                .color_text = theme.colors.text_muted,
                .gravity_y = 0.5,
                .margin = .{ .w = 4 },
            });
        }
        if (r.hearing_impaired) {
            _ = dvui.label(@src(), "CC", .{}, .{
                .id_extra = ri + 58400,
                .color_text = theme.colors.warning,
                .gravity_y = 0.5,
                .margin = .{ .w = 4 },
            });
        }
        if (dvui.button(@src(), if (subs.is_downloading) "…" else "Load", .{}, .{
            .id_extra = ri + 58500,
            .color_fill = theme.colors.accent_hover,
            .color_text = theme.colors.bg_header,
            .corner_radius = dvui.Rect.all(4),
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .gravity_y = 0.5,
        })) {
            if (!subs.is_downloading and r.file_id > 0) {
                subs.downloadSubtitle(r.file_id);
                state.app.sub_picker_open = false;
            }
        }
    }
}

pub fn renderLiquidGlassOverlay() void {
    if (!state.app.show_cell_overlay or state.app.players.items.len <= state.app.active_player_idx) return;

    const active_p = state.app.players.items[state.app.active_player_idx];
    if (active_p.provider != .mpv) return;

    // Hide transport/badges when no media: no texture, no torrent, no URL loaded.
    const has_media = active_p.texture != null
        or active_p.torrent_is_ready
        or active_p.current_torrent_id >= 0
        or active_p.current_url_len > 0
        or active_p.is_loading;
    if (!has_media) return;

    const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    // Outer wrapper: push panel to bottom of video cell
    var anchor = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 1.0, .expand = .horizontal });
    defer anchor.deinit();

    // ── Panel background — floating glass card over video ──
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = dvui.Color{ .r = 14, .g = 14, .b = 20, .a = 235 },
        .color_border = dvui.Color{ .r = 60, .g = 60, .b = 90, .a = 180 },
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(10),
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .margin = .{ .x = 8, .y = 0, .w = 8, .h = 8 },
        .box_shadow = .{
            .color = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 140 },
            .offset = .{ .x = 0, .y = 4 },
            .fade = 16.0,
        },
    });
    defer panel.deinit();

    // ── Mouse wheel: scroll on panel = volume up/down ──
    for (dvui.events()) |*ev| {
        switch (ev.evt) {
            .mouse => |mouse| {
                switch (mouse.action) {
                    .wheel_y => |wy| {
                        // Check if mouse is over the seekbar area (top ~16px of panel)
                        const panel_rect = panel.data().contentRectScale().r;
                        const mouse_y_in_panel = mouse.p.y - panel_rect.y;
                        if (mouse_y_in_panel >= 0 and mouse_y_in_panel < 20) {
                            // Scroll on seekbar → seek ±5 seconds
                            if (wy > 0) {
                                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "seek 5");
                            } else {
                                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "seek -5");
                            }
                        } else {
                            // Scroll elsewhere on panel → volume ±5
                            if (wy > 0) {
                                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "add volume 5");
                            } else {
                                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "add volume -5");
                            }
                        }
                        ev.handled = true;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    // Query mpv properties — seekbar-critical props every frame, slow props cached
    var is_paused: c_int = 0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &is_paused);
    var percent_pos: f64 = 0.0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "percent-pos", c.mpv.MPV_FORMAT_DOUBLE, &percent_pos);
    var time_pos: f64 = 0.0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &time_pos);
    var duration: f64 = 0.0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &duration);

    // Slow-changing properties: cached, refreshed every ~8 frames
    const SlowProps = struct {
        var frame_ctr: u32 = 0;
        var speed: f64 = 1.0;
        var is_muted: i64 = 0;
        var volume: f64 = 100.0;
        var width: i64 = 0;
        var height: i64 = 0;
        var fps: f64 = 0;
        var pl_count: i64 = 0;
        var pl_pos: i64 = 0;
    };
    SlowProps.frame_ctr +%= 1;
    if (SlowProps.frame_ctr % 8 == 0) {
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "speed", c.mpv.MPV_FORMAT_DOUBLE, &SlowProps.speed);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "mute", c.mpv.MPV_FORMAT_FLAG, &SlowProps.is_muted);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "volume", c.mpv.MPV_FORMAT_DOUBLE, &SlowProps.volume);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "width", c.mpv.MPV_FORMAT_INT64, &SlowProps.width);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "height", c.mpv.MPV_FORMAT_INT64, &SlowProps.height);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "estimated-vf-fps", c.mpv.MPV_FORMAT_DOUBLE, &SlowProps.fps);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "playlist-count", c.mpv.MPV_FORMAT_INT64, &SlowProps.pl_count);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "playlist-pos", c.mpv.MPV_FORMAT_INT64, &SlowProps.pl_pos);
    }

    const toggle_icon = if (is_paused != 0) icons.tvg.lucide.@"play" else icons.tvg.lucide.@"pause";

    // ═══════════════════════════════════════════════════════════════
    // ROW 1: Seekbar — full width, compact 12px height
    // ═══════════════════════════════════════════════════════════════
    {
        var seek_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 12 },
            .max_size_content = .{ .w = 0, .h = 12 },
        });
        defer seek_row.deinit();

        var seek_overlay = dvui.overlay(@src(), .{ .expand = .horizontal });
        defer seek_overlay.deinit();

        // Piece map background (torrent streaming)
        if (active_p.current_torrent_id >= 0) {
            var map_buf: [2048]u8 = undefined;
            const map_len = c.mpv.torrent_get_piece_map(state.app.torrent_ses, active_p.current_torrent_id, &map_buf, 2048);
            if (map_len > 0) {
                var p_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .min_size_content = .{ .w = 0, .h = 3 },
                    .gravity_y = 0.5,
                });

                const VISUAL_PARTS = 60;
                var part_i: usize = 0;
                while (part_i < VISUAL_PARTS) : (part_i += 1) {
                    const start_idx = (part_i * @as(usize, @intCast(map_len))) / VISUAL_PARTS;
                    const end_idx = ((part_i + 1) * @as(usize, @intCast(map_len))) / VISUAL_PARTS;

                    var downloaded = false;
                    var bit_i: usize = start_idx;
                    while (bit_i < end_idx and bit_i < map_len) : (bit_i += 1) {
                        if (map_buf[bit_i] == '1') { downloaded = true; break; }
                    }

                    var p_seg = dvui.box(@src(), .{}, .{
                        .id_extra = part_i,
                        .expand = .both,
                        .background = true,
                        .color_fill = if (downloaded) dvui.Color{ .r = 69, .g = 133, .b = 136, .a = 180 } else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 100 },
                    });
                    p_seg.deinit();
                }

                p_row.deinit();
            }
        }

        // Interactive slider on top
        var slider_pct: f32 = @floatCast(percent_pos / 100.0);
        if (std.math.isNan(slider_pct)) slider_pct = 0.0;
        if (dvui.slider(@src(), .{ .fraction = &slider_pct }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 100, .h = 8 },
            .color_fill = transparent,
        })) {
            const now_ms = @import("../core/io_global.zig").milliTimestamp();
            const S = struct { var last_seek_ms: i64 = 0; var last_seek_pct: f64 = -1.0; };
            const seek_pct = @as(f64, slider_pct * 100.0);

            if (now_ms - S.last_seek_ms > 100 or @abs(seek_pct - S.last_seek_pct) > 2.0) {
                var buf: [64]u8 = undefined;
                if (std.fmt.bufPrintZ(&buf, "seek {d:.2} absolute-percent+keyframes", .{seek_pct})) |seek_cmd| {
                    _ = c.mpv.mpv_command_string(active_p.mpv_ctx, seek_cmd.ptr);
                } else |_| {}

                if (active_p.current_torrent_id >= 0 and now_ms - S.last_seek_ms > 500) {
                    c.mpv.torrent_seek_prioritize(state.app.torrent_ses, active_p.current_torrent_id,
                        active_p.selected_file_idx, seek_pct);
                }

                S.last_seek_ms = now_ms;
                S.last_seek_pct = seek_pct;
            }
        }
    }

    // 4px gap
    { var gap = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 0, .h = 3 }, .expand = .horizontal }); gap.deinit(); }

    // ═══════════════════════════════════════════════════════════════
    // ROW 2: Transport | Time | Volume | Spacer | Menus | Close
    // ═══════════════════════════════════════════════════════════════
    {
        var ctrl_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
            .max_size_content = .{ .w = 0, .h = 24 },
        });
        defer ctrl_row.deinit();

        var wd: dvui.WidgetData = undefined;
        const ctrl_pad = dvui.Rect{ .x = 3, .y = 3, .w = 3, .h = 3 };

        // Query playlist state (from cache)
        const pl_count = SlowProps.pl_count;
        const pl_pos = SlowProps.pl_pos;
        const has_playlist = pl_count > 1;

        // Prev track
        if (has_playlist) {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"skip-back", .{}, .{}, .{
                .data_out = &wd, .color_fill = transparent,
                .color_text = if (pl_pos > 0) theme.colors.accent else theme.colors.text_muted,
                .border = dvui.Rect.all(0), .gravity_y = 0.5, .padding = ctrl_pad,
            })) {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "playlist-prev");
            }
            components.tip(@src(), wd, "Previous");
        }

        // Rewind
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"rewind", .{}, .{}, .{
            .data_out = &wd, .color_fill = transparent, .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(0), .gravity_y = 0.5, .padding = ctrl_pad,
        })) {
            _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "seek -10");
        }
        components.tip(@src(), wd, "−10s");

        // Play/Pause
        if (dvui.buttonIcon(@src(), "", toggle_icon, .{}, .{}, .{
            .data_out = &wd, .color_fill = transparent, .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(0), .gravity_y = 0.5, .padding = ctrl_pad,
        })) {
            _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "cycle pause");
        }
        components.tip(@src(), wd, if (is_paused != 0) "Play" else "Pause");

        // Forward
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"fast-forward", .{}, .{}, .{
            .data_out = &wd, .color_fill = transparent, .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(0), .gravity_y = 0.5, .padding = ctrl_pad,
        })) {
            _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "seek 10");
        }
        components.tip(@src(), wd, "+10s");

        // Next track
        if (has_playlist) {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"skip-forward", .{}, .{}, .{
                .data_out = &wd, .color_fill = transparent,
                .color_text = if (pl_pos + 1 < pl_count) theme.colors.accent else theme.colors.text_muted,
                .border = dvui.Rect.all(0), .gravity_y = 0.5, .padding = ctrl_pad,
            })) {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "playlist-next");
            }
            components.tip(@src(), wd, "Next");
        }

        // Time display
        {
            const safe_time = @max(0.0, if (std.math.isNan(time_pos)) 0.0 else time_pos);
            const safe_dur = @max(0.0, if (std.math.isNan(duration)) 0.0 else duration);
            const t_sec = @as(u32, @intFromFloat(safe_time));
            const d_sec = @as(u32, @intFromFloat(safe_dur));
            var time_buf: [32]u8 = undefined;
            const time_str = std.fmt.bufPrintZ(&time_buf, "{d:0>2}:{d:0>2}:{d:0>2}/{d:0>2}:{d:0>2}:{d:0>2}", .{
                t_sec / 3600, (t_sec % 3600) / 60, t_sec % 60,
                d_sec / 3600, (d_sec % 3600) / 60, d_sec % 60,
            }) catch "00:00:00/00:00:00";

            _ = dvui.label(@src(), "{s}", .{time_str}, .{
                .color_text = theme.colors.text_muted,
                .margin = .{ .x = 6, .y = 0, .w = 2, .h = 0 },
            });

            if (has_playlist) {
                var pl_buf: [16]u8 = undefined;
                if (std.fmt.bufPrintZ(&pl_buf, "{d}/{d}", .{ pl_pos + 1, pl_count })) |pl_str| {
                    _ = dvui.label(@src(), "{s}", .{pl_str}, .{
                        .color_text = theme.colors.accent,
                        .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
                    });
                } else |_| {}
            }
        }

        // Speed indicator (from cache)
        {
            const speed = SlowProps.speed;
            if (@abs(speed - 1.0) > 0.01) {
                var spd_buf: [16]u8 = undefined;
                if (std.fmt.bufPrintZ(&spd_buf, "{d:.1}×", .{speed})) |spd_str| {
                    _ = dvui.label(@src(), "{s}", .{spd_str}, .{
                        .color_text = theme.colors.accent,
                        .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
                    });
                } else |_| {}
            }
        }

        // A-B loop
        if (active_p.loop_a >= 0) {
            const loop_lbl = if (active_p.loop_b >= 0) "🔁 A-B" else "🔁 A..";
            _ = dvui.label(@src(), "{s}", .{loop_lbl}, .{
                .color_text = theme.colors.accent_hover,
                .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
            });
        }

        // Mute + Volume (from cache)
        const is_muted = SlowProps.is_muted;
        const m_icon = if (is_muted == 1) icons.tvg.lucide.@"volume-x" else icons.tvg.lucide.@"volume-2";
        if (dvui.buttonIcon(@src(), "", m_icon, .{}, .{}, .{
            .data_out = &wd, .color_fill = transparent, .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(0), .gravity_y = 0.5, .padding = ctrl_pad,
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        })) {
            _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "cycle mute");
        }
        components.tip(@src(), wd, if (is_muted == 1) "Unmute" else "Mute");

        const vol_f64: f64 = SlowProps.volume;
        var vol_val: f32 = @floatCast(@max(0.0, @min(1.0, vol_f64 / 100.0)));
        if (dvui.slider(@src(), .{ .fraction = &vol_val }, .{
            .min_size_content = .{ .w = 50, .h = 4 },
            .max_size_content = .{ .w = 80, .h = 10 },
            .gravity_y = 0.5,
        })) {
            var set_vol_cmd: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&set_vol_cmd, "set volume {d}", .{@as(i32, @intFromFloat(vol_val * 100.0))})) |cmd| {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, cmd.ptr);
            } else |_| {}
        }

        // Spacer
        { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }

        // Dropdown menus — compact
        var hook_menu = dvui.menu(@src(), .horizontal, .{ .background = false });

        // Resolution badge (from cache)
        {
            const width_v = SlowProps.width;
            const height_v = SlowProps.height;
            if (width_v > 0 and height_v > 0) {
                var grp = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 } });
                dvui.icon(@src(), "", icons.tvg.lucide.@"monitor", .{}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5 });
                var res_buf: [32]u8 = undefined;
                if (std.fmt.bufPrintZ(&res_buf, "{d}×{d}", .{ width_v, height_v })) |res| {
                    _ = dvui.label(@src(), "{s}", .{res}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5, .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 } });
                } else |_| {}
                grp.deinit();
            }
        }

        // FPS badge (from cache)
        {
            const fps_v = SlowProps.fps;
            if (fps_v > 0) {
                var grp = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 } });
                dvui.icon(@src(), "", icons.tvg.lucide.@"gauge", .{}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5 });
                var fps_buf: [16]u8 = undefined;
                if (std.fmt.bufPrintZ(&fps_buf, "{d:.0}fps", .{fps_v})) |fp| {
                    _ = dvui.label(@src(), "{s}", .{fp}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5, .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 } });
                } else |_| {}
                grp.deinit();
            }
        }

        // Aspect ratio
        {
            var grp = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 } });
            dvui.icon(@src(), "", icons.tvg.lucide.@"ratio", .{}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5 });
            aspectDropdownMenu(active_p.mpv_ctx, 3);
            grp.deinit();
        }

        // Audio track
        {
            var grp = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 } });
            dvui.icon(@src(), "", icons.tvg.lucide.@"music", .{}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5 });
            trackDropdownMenu(active_p.mpv_ctx, "audio");
            grp.deinit();
        }

        // Subtitle track
        {
            var grp = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 } });
            dvui.icon(@src(), "", icons.tvg.lucide.@"captions", .{}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5 });
            trackDropdownMenu(active_p.mpv_ctx, "sub");
            grp.deinit();
        }

        // Subtitle language + quick picker
        {
            var grp = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 } });
            dvui.icon(@src(), "", icons.tvg.lucide.@"globe", .{}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5 });
            subLanguageDropdown();
            subtitlesButton();
            grp.deinit();
        }

        // Playlist
        {
            var grp = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5, .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 } });
            dvui.icon(@src(), "", icons.tvg.lucide.@"list", .{}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5 });
            playlistDropdownMenu(active_p);
            grp.deinit();
        }

        hook_menu.deinit();

        // Close button
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"x", .{}, .{}, .{
            .data_out = &wd,
            .color_fill = transparent,
            .color_text = theme.colors.danger,
            .corner_radius = dvui.Rect.all(6),
            .border = dvui.Rect.all(0),
            .padding = ctrl_pad,
        })) {
            state.app.pending_remove_player_idx = @as(i32, @intCast(state.app.active_player_idx));
        }
        components.tip(@src(), wd, "Close player");
    }

    // ═══════════════════════════════════════════════════════════════
    // ROW 3: Torrent status (only during torrent streaming)
    // ═══════════════════════════════════════════════════════════════
    if (active_p.current_torrent_id >= 0) {
        { var gap2 = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 0, .h = 2 }, .expand = .horizontal }); gap2.deinit(); }

        var info_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 22 },
        });
        defer info_row.deinit();

        _ = dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"download", .{}, .{}, .{
            .color_text = theme.colors.accent_hover,
            .color_fill = transparent,
        });

        var t_name: [64]u8 = undefined;
        c.mpv.torrent_get_name(state.app.torrent_ses, active_p.current_torrent_id, &t_name, 64);
        var pct: f32 = 0.0;
        var dl_rate: c_int = 0;
        var seeds: c_int = 0;
        _ = c.mpv.torrent_poll(state.app.torrent_ses, active_p.current_torrent_id, active_p.selected_file_idx, null, 0, &pct, &dl_rate, &seeds);
        const name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse t_name.len;
        const rate_mb = @as(f32, @floatFromInt(dl_rate)) / 1024.0 / 1024.0;

        _ = dvui.label(@src(), "{s}", .{t_name[0..name_len]}, .{
            .color_text = theme.colors.text_muted,
            .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
        });

        { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }

        var stat_buf: [48]u8 = undefined;
        if (std.fmt.bufPrintZ(&stat_buf, "{d:.1}% | {d:.1} MB/s | {d} seeds", .{ pct * 100.0, rate_mb, seeds })) |st| {
            _ = dvui.label(@src(), "{s}", .{st}, .{
                .color_text = theme.colors.accent_hover,
            });
        } else |_| {}

        // Speed limit toggle
        {
            const limit = state.app.download_rate_limit;
            var lim_buf: [24]u8 = undefined;
            const lim_label = if (limit == 0)
                "Unlimited"
            else blk: {
                break :blk std.fmt.bufPrintZ(&lim_buf, "{d}MB/s", .{@divTrunc(limit, 1024 * 1024)}) catch "?";
            };

            if (dvui.button(@src(), lim_label, .{}, .{
                .id_extra = 200,
                .color_fill = transparent,
                .color_text = theme.colors.text_muted,
                .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
            })) {
                const limits = [_]i32{ 0, 1 * 1024 * 1024, 2 * 1024 * 1024, 5 * 1024 * 1024, 10 * 1024 * 1024 };
                var next_idx: usize = 0;
                for (limits, 0..) |l, idx| {
                    if (l == limit and idx + 1 < limits.len) {
                        next_idx = idx + 1;
                        break;
                    }
                }
                state.app.download_rate_limit = limits[next_idx];
                c.mpv.torrent_set_download_limit(state.app.torrent_ses, state.app.download_rate_limit);
            }
        }
    }
}

pub fn renderGlobalBottomTray() void {
    const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_header,
        .color_border = theme.colors.border_drawer,
        .border = dvui.Rect{ .x = 0, .y = 1, .w = 0, .h = 0 },
        .padding = .{ .x = 10, .y = 2, .w = 10, .h = 2 },
    });
    defer b.deinit();

    var total_dl: f32 = 0.0;
    var total_peers: i32 = 0;
    var total_active: i32 = 0;

    for (state.app.players.items) |p| {
        if (p.is_torrent and p.current_torrent_id >= 0) {
            var dl_rate: i32 = 0;
            var peers: i32 = 0;
            var pct: f32 = 0;
            _ = c.mpv.torrent_poll(state.app.torrent_ses, p.current_torrent_id, p.selected_file_idx, null, 0, &pct, &dl_rate, &peers);
            total_dl += @as(f32, @floatFromInt(dl_rate));
            total_peers += peers;
            if (dl_rate > 0) total_active += 1;
        }
    }

    _ = dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"activity", .{}, .{}, .{
        .gravity_y = 0.5, .color_fill = transparent, .color_text = theme.colors.accent, .padding = dvui.Rect.all(2),
    });
    _ = dvui.label(@src(), "{d} Active", .{total_active}, .{ .color_text = theme.colors.text_main, .gravity_y = 0.5 });

    { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }

    const mb_s = total_dl / (1024.0 * 1024.0);
    _ = dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"download", .{}, .{}, .{
        .gravity_y = 0.5, .color_fill = transparent,
        .color_text = if (mb_s > 0.1) theme.colors.success else theme.colors.text_muted,
        .padding = dvui.Rect.all(2),
    });
    var mb_str: [32]u8 = undefined;
    if (std.fmt.bufPrintZ(&mb_str, "{d:.2} MB/s", .{mb_s})) |msg| {
        _ = dvui.label(@src(), "{s}", .{msg}, .{
            .color_text = if (mb_s > 0.1) theme.colors.success else theme.colors.text_muted,
            .gravity_y = 0.5, .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        });
    } else |_| {}

    _ = dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"users", .{}, .{}, .{
        .gravity_y = 0.5, .color_fill = transparent, .color_text = theme.colors.accent, .padding = dvui.Rect.all(2),
    });
    _ = dvui.label(@src(), "{d} Peers", .{total_peers}, .{ .color_text = theme.colors.accent, .gravity_y = 0.5 });
}

pub fn renderToast() void {
    if (state.app.toast_len == 0) return;
    const now = @import("../core/io_global.zig").timestamp();
    if (now >= state.app.toast_expire) {
        state.app.toast_len = 0;
        return;
    }
    
    var toast_anchor = dvui.overlay(@src(), .{ .expand = .both });
    defer toast_anchor.deinit();

    // Glass-style toast container — top-center, semi-transparent
    var toast_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.06,
        .background = true,
        .color_fill = theme.colors.bg_glass,
        .color_border = theme.colors.accent,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        .corner_radius = dvui.Rect.all(10),
        .padding = .{ .x = 14, .y = 10, .w = 14, .h = 10 },
    });
    defer toast_box.deinit();

    // Icon prefix
    _ = dvui.icon(@src(), "", icons.tvg.lucide.@"info", .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    _ = dvui.label(@src(), "{s}", .{state.app.toast_buf[0..state.app.toast_len]}, .{
        .color_text = theme.colors.text_main,
        .gravity_y = 0.5,
    });
}
