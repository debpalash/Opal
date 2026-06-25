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

// ── Local module state ──
// Toggle between elapsed-and-total ("00:42/01:30") and elapsed-and-remaining
// ("00:42/-00:48") display. Survives across frames; cycled by clicking the
// time label.
var time_show_remaining: bool = false;

// Active toolbar dropdown — only one open at a time. We use stable id values
// derived from the picker kind. -1 = none.
const PickerKind = enum(i32) { none = -1, chapter = 0, aspect = 1, audio = 2, sub = 3, lang = 4, playlist = 5, ar = 6 };
var open_picker: PickerKind = .none;

// Persist the close-button screen rect across frames so we can hover-test it
// before the button is rendered (one frame of lag is acceptable for hover).
var close_button_rect: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

// ── Helpers ──

/// Pretty-format a duration in seconds as HH:MM:SS or MM:SS (when under 1h).
fn formatHmsBuf(buf: []u8, sec: u32) []const u8 {
    const h = sec / 3600;
    const m = (sec % 3600) / 60;
    const s = sec % 60;
    const res = if (h > 0)
        std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s })
    else
        std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ m, s });
    return res catch buf[0..0];
}

/// Returns true when the mouse is over the given screen rect this frame.
fn mouseOverRect(rect: dvui.Rect.Physical) bool {
    return state.app.last_mouse_x >= rect.x and state.app.last_mouse_x <= rect.x + rect.w and state.app.last_mouse_y >= rect.y and state.app.last_mouse_y <= rect.y + rect.h;
}

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

    if (dvui.menuItemLabel(@src(), label, .{ .submenu = true }, .{ .id_extra = id_extra, .gravity_y = 0.5, .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, .color_text = theme.colors.text_muted })) |r| {
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

    for (0..@as(usize, @intCast(@max(@as(i64, 0), count)))) |i| {
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

    // mpv track lang/title is untrusted metadata — validate before dvui.
    if (dvui.menuItemLabel(@src(), @import("../core/text.zig").safeUtf8(label), .{ .submenu = true }, .{ .id_extra = kind_id, .gravity_y = 0.5, .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, .color_text = theme.colors.text_muted })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = theme.colors.bg_drawer, .border = dvui.Rect.all(1), .color_border = theme.colors.border_drawer });
        defer menu.deinit();

        for (0..@as(usize, @intCast(@max(@as(i64, 0), count)))) |i| {
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

                    if (dvui.menuItemLabel(@src(), @import("../core/text.zig").safeUtf8(row_name), .{}, .{ .id_extra = i, .expand = .horizontal, .color_text = theme.colors.text_main })) |_| {
                        var set_cmd_buf: [64]u8 = undefined;
                        const prop = if (is_aud) "aid" else "sid";
                        if (std.fmt.bufPrintZ(&set_cmd_buf, "set {s} {d}", .{ prop, t_id })) |cmd| {
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

    if (dvui.menuItemLabel(@src(), "Files", .{ .submenu = true }, .{ .id_extra = 99, .gravity_y = 0.5, .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, .color_text = theme.colors.text_muted })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = theme.colors.bg_drawer, .border = dvui.Rect.all(1), .color_border = theme.colors.border_drawer });
        defer menu.deinit();

        for (0..@as(usize, @intCast(@max(@as(c_int, 0), file_count)))) |i| {
            var name_buf: [256]u8 = undefined;
            c.mpv.torrent_get_file_name(state.app.torrent_ses, p.current_torrent_id, @intCast(i), &name_buf, 256);

            const size = c.mpv.torrent_get_file_size(state.app.torrent_ses, p.current_torrent_id, @intCast(i));
            const size_mb = @as(f64, @floatFromInt(size)) / 1024.0 / 1024.0;

            var lbl_buf: [300]u8 = undefined;
            const label = std.fmt.bufPrintZ(&lbl_buf, "{s} ({d:.1} MB)", .{ std.mem.sliceTo(&name_buf, 0), size_mb }) catch "File";

            if (dvui.menuItemLabel(@src(), label, .{}, .{
                .id_extra = i,
                .expand = .horizontal,
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

pub fn subLanguageDropdown() void {
    const current_lang = state.app.sub_lang_buf[0..state.app.sub_lang_len];
    var btn_lbl: [16]u8 = undefined;
    const label = std.fmt.bufPrintZ(&btn_lbl, "{s}", .{current_lang}) catch "lang";

    if (dvui.menuItemLabel(@src(), label, .{ .submenu = true }, .{ .id_extra = 300, .gravity_y = 0.5, .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, .color_text = theme.colors.text_muted })) |r| {
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
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
    });
    defer win.deinit();

    win.dragAreaSet(dvui.windowHeader("Subtitles", "", &state.app.sub_picker_open));

    var pad = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
    });
    defer pad.deinit();

    var ctrl_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .y = theme.spacing.xs },
    });
    {
        defer ctrl_row.deinit();
        const lang = if (state.app.sub_lang_len > 0) state.app.sub_lang_buf[0..state.app.sub_lang_len] else "eng";
        var lbl_buf: [32]u8 = undefined;
        const lbl = std.fmt.bufPrint(&lbl_buf, "Lang: {s}", .{lang}) catch "Lang: eng";
        _ = dvui.label(@src(), "{s}", .{lbl}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .margin = .{ .w = theme.spacing.md },
        });
        // Primary action — the single accent affordance in this view.
        if (dvui.button(@src(), if (subs.is_searching) "Searching…" else "Auto-search", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = theme.colors.text_on_accent,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
            .margin = .{ .w = theme.spacing.sm },
        })) {
            if (!subs.is_searching) subs.autoSearchFromPlayer();
        }

        // Secondary action — quiet filled, demoted from accent.
        const auto_subs = @import("../services/auto_subs.zig");
        const gen_label = if (auto_subs.in_progress) "Generating…" else "Generate (whisper)";
        if (dvui.button(@src(), gen_label, .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
        })) {
            if (!auto_subs.in_progress) auto_subs.transcribeCurrent();
        }
    }

    if (@import("../services/auto_subs.zig").status_len > 0) {
        const as_mod = @import("../services/auto_subs.zig");
        _ = dvui.label(@src(), "{s}", .{as_mod.status_buf[0..as_mod.status_len]}, .{
            .color_text = theme.colors.text_secondary,
            .margin = .{ .y = theme.spacing.xs },
        });
    }

    if (subs.search_error_len > 0) {
        _ = dvui.label(@src(), "{s}", .{subs.search_error[0..subs.search_error_len]}, .{
            .color_text = theme.colors.semantic_warn,
            .margin = .{ .y = theme.spacing.xs },
        });
    }

    if (subs.result_count == 0 and !subs.is_searching) {
        _ = dvui.label(@src(), "No results yet. Click Auto-search.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .margin = .{ .y = theme.spacing.sm },
            .gravity_x = 0.5,
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .color_fill = theme.colors.bg_app,
    });
    defer scroll.deinit();

    for (0..subs.result_count) |ri| {
        const r = &subs.results[ri];
        // Borderless row — separated by fill-tier + spacing, no chrome.
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = ri + 58000,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .y = 2 },
        });
        defer row.deinit();

        if (r.lang_len > 0) {
            var fl_buf: [16]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(r.language[0..r.lang_len], &fl_buf)}, .{
                .id_extra = ri + 58100,
                .color_text = theme.colors.text_secondary,
                .gravity_y = 0.5,
                .margin = .{ .w = theme.spacing.sm },
            });
        }
        if (r.release_len > 0) {
            const show_len = @min(r.release_len, 70);
            // OpenSubtitles release names are untrusted + worker-written; snapshot
            // + validate a copy so an invalid/mid-codepoint byte can't panic dvui.
            var rel_buf: [128]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(r.release[0..show_len], &rel_buf)}, .{
                .id_extra = ri + 58200,
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
                .expand = .horizontal,
            });
        }
        if (r.download_count > 0) {
            var dc_buf: [16]u8 = undefined;
            const dc_str = std.fmt.bufPrint(&dc_buf, "{d}", .{r.download_count}) catch "";
            _ = dvui.icon(@src(), "dl-ic", icons.tvg.lucide.@"arrow-down", .{}, .{
                .id_extra = ri + 58350,
                .color_text = theme.colors.text_tertiary,
                .min_size_content = .{ .w = 12, .h = 12 },
                .max_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
            });
            _ = dvui.label(@src(), "{s}", .{dc_str}, .{
                .id_extra = ri + 58300,
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
                .margin = .{ .w = theme.spacing.xs },
            });
        }
        if (r.hearing_impaired) {
            _ = dvui.label(@src(), "CC", .{}, .{
                .id_extra = ri + 58400,
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
                .margin = .{ .w = theme.spacing.xs },
            });
        }
        // Per-row load — only the selected primary action carries accent; rows
        // are secondary here, so use a quiet filled button.
        if (dvui.button(@src(), if (subs.is_downloading) "…" else "Load", .{}, .{
            .id_extra = ri + 58500,
            .color_fill = theme.colors.bg_surface,
            .color_text = theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .gravity_y = 0.5,
        })) {
            if (!subs.is_downloading and r.file_id > 0) {
                subs.downloadSubtitle(r.file_id);
                state.app.sub_picker_open = false;
            }
        }
    }
}

// ── Scrubber renderer ──
// Stacked layers from bottom to top:
//   1. Base track    (4px tall, `bg_elevated`)
//   2. Buffered fill (4px, `accent_dim`) — torrent download coverage
//   3. Played fill   (4px, `accent_primary`) — overlays buffered
//   4. Chapter pips  (2px wide, `text_tertiary`) — only when has_metadata
//   5. Hover knob    (8px circle, `accent_primary`) — appears on hover;
//      track expands to 6px on hover.
fn renderScrubber(
    active_p: *player.MediaPlayer,
    percent_pos: f64,
    duration: f64,
    now_ms: i64,
) void {
    var scrub_band = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 32 },
        .max_size_content = .{ .w = 0, .h = 32 },
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = 0 },
    });
    defer scrub_band.deinit();

    const band_rect = scrub_band.data().contentRectScale().r;
    const hovered = mouseOverRect(band_rect);
    const track_h: f32 = if (hovered) 6 else 4;

    var track_overlay = dvui.overlay(@src(), .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = track_h },
        .max_size_content = .{ .w = 0, .h = track_h },
        .gravity_y = 0.5,
    });
    defer track_overlay.deinit();

    const track_rect = track_overlay.data().contentRectScale().r;

    // 1. Base track.
    {
        var base = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 1,
            .expand = .both,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(track_h * 0.5),
        });
        base.deinit();
    }

    // 2. Buffered fill (torrent download — single leading bar).
    if (active_p.current_torrent_id >= 0) {
        var map_buf: [2048]u8 = undefined;
        const map_len = c.mpv.torrent_get_piece_map(state.app.torrent_ses, active_p.current_torrent_id, &map_buf, 2048);
        if (map_len > 0) {
            var downloaded_count: usize = 0;
            var i: usize = 0;
            while (i < @as(usize, @intCast(@max(@as(c_int, 0), map_len)))) : (i += 1) {
                if (map_buf[i] == '1') downloaded_count += 1;
            }
            const buf_frac: f32 = @as(f32, @floatFromInt(downloaded_count)) / @as(f32, @floatFromInt(map_len));
            if (buf_frac > 0.0) {
                var buf_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = 2,
                    .background = true,
                    .color_fill = theme.colors.accent_dim,
                    .corner_radius = dvui.Rect.all(track_h * 0.5),
                    .min_size_content = .{ .w = track_rect.w * buf_frac, .h = track_h },
                    .max_size_content = .{ .w = track_rect.w * buf_frac, .h = track_h },
                    .gravity_x = 0.0,
                    .gravity_y = 0.5,
                });
                buf_box.deinit();
            }
        }
    }

    // 3. Played fill — overlay on top.
    {
        const played_frac: f32 = @floatCast(@max(0.0, @min(1.0, percent_pos / 100.0)));
        if (played_frac > 0.0) {
            var played = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = 3,
                .background = true,
                .color_fill = theme.colors.accent_primary,
                .corner_radius = dvui.Rect.all(track_h * 0.5),
                .min_size_content = .{ .w = track_rect.w * played_frac, .h = track_h },
                .max_size_content = .{ .w = track_rect.w * played_frac, .h = track_h },
                .gravity_x = 0.0,
                .gravity_y = 0.5,
            });
            played.deinit();
        }
    }

    // 4. Chapter pips — only after metadata is loaded.
    if (active_p.has_metadata and duration > 0) {
        var ch_count: i64 = 0;
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "chapter-list/count", c.mpv.MPV_FORMAT_INT64, &ch_count);
        if (ch_count > 1) {
            const max_pips: i64 = @min(ch_count, 64);
            var ci: i64 = 0;
            while (ci < max_pips) : (ci += 1) {
                var q_buf: [64]u8 = undefined;
                const q = std.fmt.bufPrintZ(&q_buf, "chapter-list/{d}/time", .{ci}) catch continue;
                var t: f64 = 0;
                _ = c.mpv.mpv_get_property(active_p.mpv_ctx, q.ptr, c.mpv.MPV_FORMAT_DOUBLE, &t);
                if (std.math.isNan(t) or t <= 0 or t >= duration) continue;
                const pip_frac: f32 = @floatCast(t / duration);

                var pip = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = @as(usize, @intCast(ci)) + 1024,
                    .background = true,
                    .color_fill = theme.colors.text_tertiary,
                    .min_size_content = .{ .w = 2, .h = track_h },
                    .max_size_content = .{ .w = 2, .h = track_h },
                    .gravity_x = pip_frac,
                    .gravity_y = 0.5,
                });
                pip.deinit();
            }
        }
    }

    // 5. Hover knob.
    if (hovered) {
        const knob_frac: f32 = @floatCast(@max(0.0, @min(1.0, percent_pos / 100.0)));
        var knob = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = 4,
            .background = true,
            .color_fill = theme.colors.accent_primary,
            .corner_radius = dvui.Rect.all(99),
            .min_size_content = .{ .w = 8, .h = 8 },
            .max_size_content = .{ .w = 8, .h = 8 },
            .gravity_x = knob_frac,
            .gravity_y = 0.5,
        });
        knob.deinit();
    }

    // Interactive transparent slider — captures the seek input.
    var slider_pct: f32 = @floatCast(percent_pos / 100.0);
    if (std.math.isNan(slider_pct)) slider_pct = 0.0;
    if (dvui.slider(@src(), .{ .fraction = &slider_pct }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 100, .h = track_h },
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_border = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .background = false,
        .border = dvui.Rect.all(0),
    })) {
        const S = struct {
            var last_seek_ms: i64 = 0;
            var last_seek_pct: f64 = -1.0;
        };
        const seek_pct = @as(f64, slider_pct * 100.0);
        if (now_ms - S.last_seek_ms > 100 or @abs(seek_pct - S.last_seek_pct) > 2.0) {
            var buf: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&buf, "seek {d:.2} absolute-percent+keyframes", .{seek_pct})) |seek_cmd| {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, seek_cmd.ptr);
            } else |_| {}

            if (active_p.current_torrent_id >= 0 and now_ms - S.last_seek_ms > 500) {
                c.mpv.torrent_seek_prioritize(state.app.torrent_ses, active_p.current_torrent_id, active_p.selected_file_idx, seek_pct);
            }

            S.last_seek_ms = now_ms;
            S.last_seek_pct = seek_pct;
        }
    }

    // Hover-only timestamp tooltip above the cursor.
    if (hovered and duration > 0) {
        const mouse_x = state.app.last_mouse_x;
        const frac = @max(0.0, @min(1.0, (mouse_x - band_rect.x) / @max(1.0, band_rect.w)));
        const hover_time = frac * @as(f32, @floatCast(duration));
        const ht_sec = @as(u32, @intFromFloat(@max(0.0, hover_time)));
        var ht_buf: [16]u8 = undefined;
        const ht_str = formatHmsBuf(&ht_buf, ht_sec);

        _ = dvui.label(@src(), "{s}", .{ht_str}, .{
            .color_text = theme.colors.text_primary,
            .gravity_x = frac,
            .gravity_y = 0.0,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
    }
}

// ── Picker icon-chip (icon + tiny value chip) ──
//
// Returns true when clicked. No resting chrome — the chip is bare text+icon,
// separated only by spacing. Hover paints a faint fill; the active (selected)
// value reads in text_primary while idle values stay text_tertiary. No accent
// here — accent is reserved for the single primary affordance (play/pause).
fn pickerIconChip(
    src: std.builtin.SourceLocation,
    id_extra: usize,
    icon: []const u8,
    chip_text: []const u8,
    is_active: bool,
    tooltip: []const u8,
) bool {
    // We do hover detection by comparing the laid-out rect to the mouse pos.
    // The hover background relies on this — `dvui.clicked` runs *after* the
    // box is constructed, so the box's background can't depend on its return
    // value. We instead probe the laid-out rect before deciding the fill.
    var btn = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
        .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
        .min_size_content = .{ .w = 0, .h = 28 },
        .gravity_y = 0.5,
    });

    const btn_rect = btn.data().borderRectScale().r;
    const is_hovered = mouseOverRect(btn_rect);
    var hovered_signal: bool = false;
    const clicked = dvui.clicked(btn.data(), .{ .hovered = &hovered_signal });
    const wd_copy = btn.data().*;

    // Hover-only fill — drawn here so it's underneath the icon+label.
    if (is_hovered) {
        var bg = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = true,
            .color_fill = theme.colors.bg_hover,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .min_size_content = .{ .w = 0, .h = 0 },
        });
        bg.deinit();
    }

    dvui.icon(@src(), "picker-ic", icon, .{}, .{
        .color_text = if (is_active) theme.colors.text_primary else theme.colors.text_tertiary,
        .min_size_content = .{ .w = 14, .h = 14 },
        .max_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
    });

    if (chip_text.len > 0) {
        _ = dvui.label(@src(), "{s}", .{chip_text}, .{
            .color_text = if (is_active) theme.colors.text_primary else theme.colors.text_tertiary,
            .gravity_y = 0.5,
        });
    }

    btn.deinit();

    if (tooltip.len > 0) {
        components.tip(src, wd_copy, tooltip);
    }
    return clicked;
}

// ── Querying helpers for the picker chips ──

// Throttle cache for the now-playing audio/subtitle chips. The track-list only
// changes on file load / track switch, but this was queried via BLOCKING mpv IPC
// every frame (per chip) — visible jank. Cache per chip (0=audio, 1=sub) keyed by
// the mpv ctx and refresh at most ~2x/sec.
const track_chip_cache = struct {
    var last_ms: [2]i64 = .{ 0, 0 };
    var ctx_key: [2]usize = .{ 0, 0 };
    var buf: [2][64]u8 = undefined;
    var len: [2]usize = .{ 0, 0 };
    var active: [2]bool = .{ false, false };
};

fn currentTrackChipText(
    ctx: *c.mpv.mpv_handle,
    track_type: []const u8,
    out_buf: []u8,
) struct { text: []const u8, active: bool } {
    const C = track_chip_cache;
    const slot: usize = if (std.mem.eql(u8, track_type, "audio")) 0 else 1;
    const key = @intFromPtr(ctx);
    const now = @import("../core/io_global.zig").milliTimestamp();

    // Serve from cache (no mpv IPC) unless stale (>500ms) or the player changed.
    if (!(C.ctx_key[slot] == key and now - C.last_ms[slot] < 500)) {
        var res_text: []const u8 = "Off";
        var res_active = false;
        var local: [64]u8 = undefined;

        var count: i64 = 0;
        _ = c.mpv.mpv_get_property(ctx, "track-list/count", c.mpv.MPV_FORMAT_INT64, &count);
        var i: i64 = 0;
        scan: while (i < count) : (i += 1) {
            var q_buf: [64]u8 = undefined;
            const tq = std.fmt.bufPrintZ(&q_buf, "track-list/{d}/type", .{i}) catch continue;
            const tc = c.mpv.mpv_get_property_string(ctx, tq.ptr);
            if (tc == null) continue;
            const matches = std.mem.eql(u8, std.mem.span(tc), track_type);
            c.mpv.mpv_free(@ptrCast(tc));
            if (!matches) continue;

            var sq_buf: [64]u8 = undefined;
            const sq = std.fmt.bufPrintZ(&sq_buf, "track-list/{d}/selected", .{i}) catch continue;
            const sc = c.mpv.mpv_get_property_string(ctx, sq.ptr);
            if (sc == null) continue;
            const selected_yes = std.mem.eql(u8, std.mem.span(sc), "yes");
            c.mpv.mpv_free(@ptrCast(sc));
            if (!selected_yes) continue;

            var lq_buf: [64]u8 = undefined;
            const lq = std.fmt.bufPrintZ(&lq_buf, "track-list/{d}/lang", .{i}) catch continue;
            const lc = c.mpv.mpv_get_property_string(ctx, lq.ptr);
            if (lc != null) {
                const lang_span = std.mem.span(lc);
                const ln = @min(lang_span.len, local.len);
                @memcpy(local[0..ln], lang_span[0..ln]);
                c.mpv.mpv_free(@ptrCast(lc));
                res_text = local[0..ln];
                res_active = true;
                break :scan;
            }
            res_text = "On";
            res_active = true;
            break :scan;
        }

        const cn = @min(res_text.len, C.buf[slot].len);
        @memcpy(C.buf[slot][0..cn], res_text[0..cn]);
        C.len[slot] = cn;
        C.active[slot] = res_active;
        C.ctx_key[slot] = key;
        C.last_ms[slot] = now;
    }

    const n = @min(C.len[slot], out_buf.len);
    @memcpy(out_buf[0..n], C.buf[slot][0..n]);
    return .{ .text = out_buf[0..n], .active = C.active[slot] };
}

fn currentAspectChipText(ctx: *c.mpv.mpv_handle) []const u8 {
    const aspect_c = c.mpv.mpv_get_property_string(ctx, "video-aspect-override");
    defer if (aspect_c != null) c.mpv.mpv_free(@ptrCast(aspect_c));
    if (aspect_c == null) return "Auto";
    const v = std.mem.span(aspect_c);
    if (std.mem.eql(u8, v, "16:9") or std.mem.startsWith(u8, v, "1.77")) return "16:9";
    if (std.mem.eql(u8, v, "4:3") or std.mem.startsWith(u8, v, "1.33")) return "4:3";
    if (std.mem.eql(u8, v, "21:9") or std.mem.startsWith(u8, v, "2.33")) return "21:9";
    return "Auto";
}

fn currentChapterChipText(ctx: *c.mpv.mpv_handle, out_buf: []u8) struct { text: []const u8, count: i64 } {
    var ch_count: i64 = 0;
    _ = c.mpv.mpv_get_property(ctx, "chapter-list/count", c.mpv.MPV_FORMAT_INT64, &ch_count);
    if (ch_count <= 0) return .{ .text = "", .count = 0 };
    var current_ch: i64 = -1;
    _ = c.mpv.mpv_get_property(ctx, "chapter", c.mpv.MPV_FORMAT_INT64, &current_ch);
    const s = std.fmt.bufPrint(out_buf, "{d}/{d}", .{ current_ch + 1, ch_count }) catch "";
    return .{ .text = s, .count = ch_count };
}

// ── Floating pickers — opened by setting `open_picker` ──

fn renderChapterPickerPopover(active_p: *player.MediaPlayer) void {
    if (open_picker != .chapter) return;
    var ch_count: i64 = 0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "chapter-list/count", c.mpv.MPV_FORMAT_INT64, &ch_count);
    if (ch_count <= 0) {
        open_picker = .none;
        return;
    }

    var current_ch: i64 = -1;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "chapter", c.mpv.MPV_FORMAT_INT64, &current_ch);

    var open: bool = true;
    var fw = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{
        .min_size_content = .{ .w = 360, .h = 280 },
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.md),
    });
    defer fw.deinit();
    fw.dragAreaSet(dvui.windowHeader("Chapters", "", &open));

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        // Transparent — show the popup's themed bg, not dvui's default white fill.
        .background = false,
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
    });
    defer scroll.deinit();

    var i: usize = 0;
    while (i < @as(usize, @intCast(@max(@as(i64, 0), ch_count)))) : (i += 1) {
        var qtitle_buf: [64]u8 = undefined;
        const title_q = std.fmt.bufPrintZ(&qtitle_buf, "chapter-list/{d}/title", .{i}) catch continue;
        const title_c = c.mpv.mpv_get_property_string(active_p.mpv_ctx, title_q.ptr);
        var qtime_buf: [64]u8 = undefined;
        const time_q = std.fmt.bufPrintZ(&qtime_buf, "chapter-list/{d}/time", .{i}) catch continue;
        var ch_time: f64 = 0;
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, time_q.ptr, c.mpv.MPV_FORMAT_DOUBLE, &ch_time);
        const safe = @max(0.0, if (std.math.isNan(ch_time)) 0.0 else ch_time);
        const t_sec = @as(u32, @intFromFloat(safe));

        var label_buf: [128]u8 = undefined;
        const label = if (title_c != null) blk: {
            const title_span = std.mem.span(title_c);
            const s = std.fmt.bufPrintZ(&label_buf, "{d:0>2}:{d:0>2}:{d:0>2}  {s}", .{
                t_sec / 3600, (t_sec % 3600) / 60, t_sec % 60, title_span,
            }) catch "";
            c.mpv.mpv_free(@ptrCast(title_c));
            break :blk s;
        } else (std.fmt.bufPrintZ(&label_buf, "{d:0>2}:{d:0>2}:{d:0>2}  Chapter {d}", .{
            t_sec / 3600, (t_sec % 3600) / 60, t_sec % 60, i + 1,
        }) catch "");

        const is_current = i == @as(usize, @intCast(@max(0, current_ch)));
        if (dvui.button(@src(), label, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_fill = if (is_current) theme.colors.bg_elevated else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (is_current) theme.colors.accent_primary else theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        })) {
            var cmd_buf: [32]u8 = undefined;
            if (std.fmt.bufPrintZ(&cmd_buf, "set chapter {d}", .{i})) |cmd| {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, cmd.ptr);
            } else |_| {}
            open_picker = .none;
        }
    }

    if (!open) open_picker = .none;
}

fn renderAspectPickerPopover(active_p: *player.MediaPlayer) void {
    if (open_picker != .aspect) return;
    var open: bool = true;
    var fw = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{
        .min_size_content = .{ .w = 200, .h = 160 },
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.md),
    });
    defer fw.deinit();
    fw.dragAreaSet(dvui.windowHeader("Aspect Ratio", "", &open));

    const cur = currentAspectChipText(active_p.mpv_ctx);
    const modes = [_][]const u8{ "-1", "16:9", "4:3", "21:9" };
    const labels = [_][]const u8{ "Auto", "16:9", "4:3", "21:9" };

    var pad = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
    });
    defer pad.deinit();

    for (modes, 0..) |m, k| {
        const is_cur = std.mem.eql(u8, cur, labels[k]);
        if (dvui.button(@src(), labels[k], .{}, .{
            .id_extra = k,
            .expand = .horizontal,
            .color_fill = if (is_cur) theme.colors.bg_elevated else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (is_cur) theme.colors.accent_primary else theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        })) {
            var cmd: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&cmd, "set video-aspect-override \"{s}\"", .{m})) |cstr| {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, cstr.ptr);
            } else |_| {}
            open_picker = .none;
        }
    }
    if (!open) open_picker = .none;
}

fn renderTrackPickerPopover(active_p: *player.MediaPlayer, track_type: []const u8, kind: PickerKind) void {
    if (open_picker != kind) return;
    var open: bool = true;
    const title = if (kind == .audio) "Audio Track" else "Subtitles";
    var fw = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{
        .min_size_content = .{ .w = 320, .h = 240 },
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.md),
    });
    defer fw.deinit();
    fw.dragAreaSet(dvui.windowHeader(title, "", &open));

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        // Transparent — show the popup's themed bg, not dvui's default white fill.
        .background = false,
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
    });
    defer scroll.deinit();

    var count: i64 = 0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "track-list/count", c.mpv.MPV_FORMAT_INT64, &count);

    var i: i64 = 0;
    while (i < count) : (i += 1) {
        var tq_buf: [64]u8 = undefined;
        const tq = std.fmt.bufPrintZ(&tq_buf, "track-list/{d}/type", .{i}) catch continue;
        const tc = c.mpv.mpv_get_property_string(active_p.mpv_ctx, tq.ptr);
        if (tc == null) continue;
        const matches = std.mem.eql(u8, std.mem.span(tc), track_type);
        c.mpv.mpv_free(@ptrCast(tc));
        if (!matches) continue;

        var id_buf: [64]u8 = undefined;
        const idq = std.fmt.bufPrintZ(&id_buf, "track-list/{d}/id", .{i}) catch continue;
        var t_id: i64 = 0;
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, idq.ptr, c.mpv.MPV_FORMAT_INT64, &t_id);

        var sel_buf: [64]u8 = undefined;
        const sq = std.fmt.bufPrintZ(&sel_buf, "track-list/{d}/selected", .{i}) catch continue;
        const sc = c.mpv.mpv_get_property_string(active_p.mpv_ctx, sq.ptr);
        const is_selected = sc != null and std.mem.eql(u8, std.mem.span(sc), "yes");
        if (sc != null) c.mpv.mpv_free(@ptrCast(sc));

        var name_buf: [128]u8 = undefined;
        var row_name: []const u8 = "Unknown";
        var qlang_buf: [64]u8 = undefined;
        const lq = std.fmt.bufPrintZ(&qlang_buf, "track-list/{d}/lang", .{i}) catch continue;
        const lc = c.mpv.mpv_get_property_string(active_p.mpv_ctx, lq.ptr);
        if (lc != null) {
            row_name = std.fmt.bufPrint(&name_buf, "{s}", .{std.mem.span(lc)}) catch "Err";
            c.mpv.mpv_free(@ptrCast(lc));
        } else {
            var qtitle_buf: [64]u8 = undefined;
            const tlq = std.fmt.bufPrintZ(&qtitle_buf, "track-list/{d}/title", .{i}) catch continue;
            const tlc = c.mpv.mpv_get_property_string(active_p.mpv_ctx, tlq.ptr);
            if (tlc != null) {
                row_name = std.fmt.bufPrint(&name_buf, "{s}", .{std.mem.span(tlc)}) catch "Err";
                c.mpv.mpv_free(@ptrCast(tlc));
            } else {
                row_name = std.fmt.bufPrint(&name_buf, "Track #{d}", .{i}) catch "Err";
            }
        }

        if (dvui.button(@src(), @import("../core/text.zig").safeUtf8(row_name), .{}, .{
            .id_extra = @as(usize, @intCast(i)),
            .expand = .horizontal,
            .color_fill = if (is_selected) theme.colors.bg_elevated else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (is_selected) theme.colors.accent_primary else theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        })) {
            var cmd: [64]u8 = undefined;
            const prop = if (kind == .audio) "aid" else "sid";
            if (std.fmt.bufPrintZ(&cmd, "set {s} {d}", .{ prop, t_id })) |cstr| {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, cstr.ptr);
            } else |_| {}
            open_picker = .none;
        }
    }

    if (!open) open_picker = .none;
}

fn renderLangPickerPopover() void {
    if (open_picker != .lang) return;
    var open: bool = true;
    var fw = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{
        .min_size_content = .{ .w = 240, .h = 320 },
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.md),
    });
    defer fw.deinit();
    fw.dragAreaSet(dvui.windowHeader("Subtitle Language", "", &open));

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        // Transparent — show the popup's themed bg, not dvui's default white fill.
        .background = false,
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
    });
    defer scroll.deinit();

    const langs = [_][]const u8{ "eng", "spa", "fre", "ger", "por", "ita", "dut", "pol", "rus", "chi", "jpn", "kor", "ara", "hin", "tur" };
    const names = [_][]const u8{ "English", "Spanish", "French", "German", "Portuguese", "Italian", "Dutch", "Polish", "Russian", "Chinese", "Japanese", "Korean", "Arabic", "Hindi", "Turkish" };
    const current = state.app.sub_lang_buf[0..state.app.sub_lang_len];

    for (langs, 0..) |l, k| {
        const is_cur = std.mem.eql(u8, current, l);
        if (dvui.button(@src(), names[k], .{}, .{
            .id_extra = k,
            .expand = .horizontal,
            .color_fill = if (is_cur) theme.colors.bg_elevated else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (is_cur) theme.colors.accent_primary else theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        })) {
            @memcpy(state.app.sub_lang_buf[0..l.len], l);
            state.app.sub_lang_len = l.len;
            open_picker = .none;
        }
    }
    if (!open) open_picker = .none;
}

fn renderPlaylistPickerPopover(active_p: *player.MediaPlayer) void {
    if (open_picker != .playlist) return;
    if (active_p.current_torrent_id < 0) {
        open_picker = .none;
        return;
    }
    const file_count = c.mpv.torrent_get_file_count(state.app.torrent_ses, active_p.current_torrent_id);
    if (file_count <= 1) {
        open_picker = .none;
        return;
    }

    var open: bool = true;
    var fw = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{
        .min_size_content = .{ .w = 460, .h = 320 },
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.md),
    });
    defer fw.deinit();
    fw.dragAreaSet(dvui.windowHeader("Files", "", &open));

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        // Transparent — show the popup's themed bg, not dvui's default white fill.
        .background = false,
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
    });
    defer scroll.deinit();

    var i: usize = 0;
    while (i < @as(usize, @intCast(@max(@as(c_int, 0), file_count)))) : (i += 1) {
        var name_buf: [256]u8 = undefined;
        c.mpv.torrent_get_file_name(state.app.torrent_ses, active_p.current_torrent_id, @intCast(i), &name_buf, 256);
        const size = c.mpv.torrent_get_file_size(state.app.torrent_ses, active_p.current_torrent_id, @intCast(i));
        const size_mb = @as(f64, @floatFromInt(size)) / 1024.0 / 1024.0;
        var lbl_buf: [320]u8 = undefined;
        const label = std.fmt.bufPrintZ(&lbl_buf, "{s}  ({d:.1} MB)", .{ std.mem.sliceTo(&name_buf, 0), size_mb }) catch "File";
        const is_sel = active_p.selected_file_idx == @as(i32, @intCast(i));
        if (dvui.button(@src(), label, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_fill = if (is_sel) theme.colors.bg_elevated else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (is_sel) theme.colors.accent_primary else theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        })) {
            if (active_p.selected_file_idx != @as(i32, @intCast(i))) {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "stop");
                const old_idx = active_p.selected_file_idx;
                if (old_idx >= 0 and old_idx < file_count) {
                    c.mpv.torrent_set_file_priority(state.app.torrent_ses, active_p.current_torrent_id, old_idx, 0);
                }
                active_p.selected_file_idx = @as(i32, @intCast(i));
                c.mpv.torrent_set_file_priority(state.app.torrent_ses, active_p.current_torrent_id, @intCast(i), 4);
                active_p.torrent_is_ready = false;
            }
            open_picker = .none;
        }
    }
    if (!open) open_picker = .none;
}

pub fn renderLiquidGlassOverlay() void {
    if (!state.app.show_cell_overlay or state.app.players.items.len <= state.app.active_player_idx) return;

    const active_p = state.app.players.items[state.app.active_player_idx];
    if (active_p.provider != .mpv) return;

    // Hide transport/badges when no media: no texture, no torrent, no URL loaded.
    const has_media = active_p.texture != null or active_p.torrent_is_ready or active_p.current_torrent_id >= 0 or active_p.current_url_len > 0 or active_p.is_loading;
    if (!has_media) return;

    const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    // ── Auto-hide if playing and idle for 2.5s. Stay visible while a popover is open. ──
    var is_paused: c_int = 0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &is_paused);
    const now_ms = @import("../core/io_global.zig").milliTimestamp();
    if (is_paused == 0 and now_ms - state.app.last_mouse_move_ms > 2500 and open_picker == .none) return;

    // ── Anchor: push the footer to the bottom of the active cell. ──
    var anchor = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 1.0, .expand = .horizontal });
    defer anchor.deinit();

    // ── Footer panel: bg_surface + 1px top border ──
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    defer panel.deinit();

    // ── Wheel on scrubber band = ±5s seek ──
    for (dvui.events()) |*ev| {
        switch (ev.evt) {
            .mouse => |mouse| {
                switch (mouse.action) {
                    .wheel_y => |wy| {
                        const panel_rect = panel.data().contentRectScale().r;
                        const mouse_y_in_panel = mouse.p.y - panel_rect.y;
                        if (mouse_y_in_panel >= 0 and mouse_y_in_panel < 32) {
                            if (wy > 0) {
                                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "seek 5");
                            } else {
                                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "seek -5");
                            }
                            ev.handled = true;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    // Query mpv properties — seekbar-critical props every frame, slow props cached.
    var percent_pos: f64 = 0.0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "percent-pos", c.mpv.MPV_FORMAT_DOUBLE, &percent_pos);
    var time_pos: f64 = 0.0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &time_pos);
    var duration: f64 = 0.0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &duration);

    const SlowProps = struct {
        var frame_ctr: u32 = 0;
        var speed: f64 = 1.0;
        var is_muted: i64 = 0;
        var volume: f64 = 100.0;
        var pl_count: i64 = 0;
        var pl_pos: i64 = 0;
        var last_player_idx: usize = 0;
    };
    if (SlowProps.last_player_idx != state.app.active_player_idx) {
        SlowProps.last_player_idx = state.app.active_player_idx;
        SlowProps.frame_ctr = 8; // force refresh on next frame
    }
    SlowProps.frame_ctr +%= 1;
    if (SlowProps.frame_ctr % 8 == 0) {
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "speed", c.mpv.MPV_FORMAT_DOUBLE, &SlowProps.speed);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "mute", c.mpv.MPV_FORMAT_FLAG, &SlowProps.is_muted);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "volume", c.mpv.MPV_FORMAT_DOUBLE, &SlowProps.volume);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "playlist-count", c.mpv.MPV_FORMAT_INT64, &SlowProps.pl_count);
        _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "playlist-pos", c.mpv.MPV_FORMAT_INT64, &SlowProps.pl_pos);
    }

    const toggle_icon = if (is_paused != 0) icons.tvg.lucide.play else icons.tvg.lucide.pause;

    // ═══════════════════════════════════════════════════════════════
    // ROW 1 — Scrubber + chapter pips + hover time-at-cursor
    // ═══════════════════════════════════════════════════════════════
    renderScrubber(active_p, percent_pos, duration, now_ms);

    // ═══════════════════════════════════════════════════════════════
    // ROW 2 — Controls: transport | time | volume | pickers | close
    // ═══════════════════════════════════════════════════════════════
    {
        var ctrl_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 40 },
            .max_size_content = .{ .w = 0, .h = 40 },
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
        });
        defer ctrl_row.deinit();

        var wd: dvui.WidgetData = undefined;
        const has_playlist = SlowProps.pl_count > 1;

        // ── Transport: skip-back | rewind | play/pause | forward | skip-forward ──
        if (has_playlist) {
            if (dvui.buttonIcon(@src(), "skip-prev", icons.tvg.lucide.@"skip-back", .{}, .{}, .{
                .data_out = &wd,
                .color_fill = transparent,
                .color_text = if (SlowProps.pl_pos > 0) theme.colors.text_primary else theme.colors.text_tertiary,
                .border = dvui.Rect.all(0),
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .gravity_y = 0.5,
                .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
                .min_size_content = .{ .w = 32, .h = 32 },
                .max_size_content = .{ .w = 32, .h = 32 },
            })) {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "playlist-prev");
            }
            components.tip(@src(), wd, "Previous track");
        }

        // Rewind 10s — 36px square.
        if (dvui.buttonIcon(@src(), "rewind10", icons.tvg.lucide.rewind, .{}, .{}, .{
            .data_out = &wd,
            .color_fill = transparent,
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .gravity_y = 0.5,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .min_size_content = .{ .w = 36, .h = 36 },
            .max_size_content = .{ .w = 36, .h = 36 },
        })) {
            _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "seek -10");
        }
        components.tip(@src(), wd, "Skip back 10s (\xE2\x86\x90)");

        // Play / Pause — 44px square. The single accent affordance of the
        // footer; carries the accent fill in BOTH play and pause states.
        if (dvui.buttonIcon(@src(), "toggle-pp", toggle_icon, .{}, .{}, .{
            .data_out = &wd,
            .color_fill = theme.colors.accent_primary,
            .color_text = theme.colors.text_on_accent,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .gravity_y = 0.5,
            .padding = .{ .x = 10, .y = 10, .w = 10, .h = 10 },
            .min_size_content = .{ .w = 44, .h = 44 },
            .max_size_content = .{ .w = 44, .h = 44 },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        })) {
            active_p.togglePause();
        }
        components.tip(@src(), wd, "Play/Pause (Space)");

        // Forward 10s.
        if (dvui.buttonIcon(@src(), "ff10", icons.tvg.lucide.@"fast-forward", .{}, .{}, .{
            .data_out = &wd,
            .color_fill = transparent,
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .gravity_y = 0.5,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .min_size_content = .{ .w = 36, .h = 36 },
            .max_size_content = .{ .w = 36, .h = 36 },
        })) {
            _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "seek 10");
        }
        components.tip(@src(), wd, "Skip forward 10s (\xE2\x86\x92)");

        if (has_playlist) {
            if (dvui.buttonIcon(@src(), "skip-next", icons.tvg.lucide.@"skip-forward", .{}, .{}, .{
                .data_out = &wd,
                .color_fill = transparent,
                .color_text = if (SlowProps.pl_pos + 1 < SlowProps.pl_count) theme.colors.text_primary else theme.colors.text_tertiary,
                .border = dvui.Rect.all(0),
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .gravity_y = 0.5,
                .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
                .min_size_content = .{ .w = 32, .h = 32 },
                .max_size_content = .{ .w = 32, .h = 32 },
            })) {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "playlist-next");
            }
            components.tip(@src(), wd, "Next track");
        }

        // ── Time display — current in text_primary, separator+total in text_tertiary ──
        {
            const safe_time = @max(0.0, if (std.math.isNan(time_pos)) 0.0 else time_pos);
            const safe_dur = @max(0.0, if (std.math.isNan(duration)) 0.0 else duration);
            const t_sec = @as(u32, @intFromFloat(safe_time));
            const d_sec = @as(u32, @intFromFloat(safe_dur));

            var cur_buf: [16]u8 = undefined;
            const cur_str = formatHmsBuf(&cur_buf, t_sec);

            var rest_buf: [24]u8 = undefined;
            const rest_str = if (time_show_remaining and d_sec >= t_sec) blk: {
                const rem = d_sec - t_sec;
                const h = rem / 3600;
                const m = (rem % 3600) / 60;
                const s = rem % 60;
                break :blk if (h > 0)
                    (std.fmt.bufPrint(&rest_buf, " / -{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch " / --:--")
                else
                    (std.fmt.bufPrint(&rest_buf, " / -{d:0>2}:{d:0>2}", .{ m, s }) catch " / --:--");
            } else blk: {
                const h = d_sec / 3600;
                const m = (d_sec % 3600) / 60;
                const s = d_sec % 60;
                break :blk if (h > 0)
                    (std.fmt.bufPrint(&rest_buf, " / {d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch " / 00:00")
                else
                    (std.fmt.bufPrint(&rest_buf, " / {d:0>2}:{d:0>2}", .{ m, s }) catch " / 00:00");
            };

            var time_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.sm, .h = 0 },
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
            });
            if (dvui.clicked(time_box.data(), .{})) {
                time_show_remaining = !time_show_remaining;
            }

            _ = dvui.label(@src(), "{s}", .{cur_str}, .{
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
            });
            _ = dvui.label(@src(), "{s}", .{rest_str}, .{
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
            });

            // Playlist position / Speed / Loop badges.
            if (has_playlist) {
                var pl_buf: [16]u8 = undefined;
                if (std.fmt.bufPrintZ(&pl_buf, " \xC2\xB7 {d}/{d}", .{ SlowProps.pl_pos + 1, SlowProps.pl_count })) |pl_str| {
                    _ = dvui.label(@src(), "{s}", .{pl_str}, .{
                        .color_text = theme.colors.text_tertiary,
                        .gravity_y = 0.5,
                    });
                } else |_| {}
            }
            if (@abs(SlowProps.speed - 1.0) > 0.01) {
                var spd_buf: [16]u8 = undefined;
                if (std.fmt.bufPrintZ(&spd_buf, " \xC2\xB7 {d:.1}\xC3\x97", .{SlowProps.speed})) |sp| {
                    _ = dvui.label(@src(), "{s}", .{sp}, .{
                        .color_text = theme.colors.text_tertiary,
                        .gravity_y = 0.5,
                    });
                } else |_| {}
            }
            if (active_p.loop_a >= 0) {
                const loop_lbl = if (active_p.loop_b >= 0) " \xC2\xB7 A-B" else " \xC2\xB7 A..";
                _ = dvui.label(@src(), "{s}", .{loop_lbl}, .{
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                });
            }

            time_box.deinit();
        }

        // ── Volume: mute toggle + barely-there track, visually grouped ──
        const is_muted = SlowProps.is_muted == 1;
        const m_icon = if (is_muted) icons.tvg.lucide.@"volume-x" else icons.tvg.lucide.@"volume-2";
        if (dvui.buttonIcon(@src(), "mute-tog", m_icon, .{}, .{}, .{
            .data_out = &wd,
            .color_fill = transparent,
            .color_text = if (is_muted) theme.colors.text_tertiary else theme.colors.text_primary,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .gravity_y = 0.5,
            .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
            .min_size_content = .{ .w = 28, .h = 28 },
            .max_size_content = .{ .w = 28, .h = 28 },
            .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
        })) {
            _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "cycle mute");
        }
        components.tip(@src(), wd, if (is_muted) "Unmute" else "Mute");

        // 120px fixed slider — grouped tight against the mute icon, no boxed
        // chrome: faint trough, secondary (non-accent) fill.
        var slider_host = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = 120, .h = 20 },
            .max_size_content = .{ .w = 120, .h = 20 },
            .gravity_y = 0.5,
        });
        const slider_rect = slider_host.data().contentRectScale().r;
        const slider_hover = mouseOverRect(slider_rect);

        const vol_f64: f64 = SlowProps.volume;
        var vol_val: f32 = @floatCast(@max(0.0, @min(1.0, vol_f64 / 100.0)));
        if (dvui.slider(@src(), .{ .fraction = &vol_val }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 120, .h = 4 },
            .max_size_content = .{ .w = 120, .h = 4 },
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = dvui.Rect.all(2),
            .gravity_y = 0.5,
            .background = true,
        })) {
            var set_vol_cmd: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&set_vol_cmd, "set volume {d}", .{@as(i32, @intFromFloat(vol_val * 100.0))})) |cmd| {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, cmd.ptr);
            } else |_| {}
        }
        slider_host.deinit();

        // Hover-only percentage label.
        if (slider_hover) {
            const vol_pct = @as(i32, @intFromFloat(@max(0.0, @min(100.0, vol_f64))));
            var vol_pct_buf: [8]u8 = undefined;
            const vol_pct_str = std.fmt.bufPrint(&vol_pct_buf, "{d}%", .{vol_pct}) catch "0%";
            _ = dvui.label(@src(), "{s}", .{vol_pct_str}, .{
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
                .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
            });
        } else {
            var gap = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 4, .h = 0 } });
            gap.deinit();
        }

        // ── Spacer pushes pickers + close to the right edge ──
        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        // ── Picker icon-chips: aspect, chapters, audio, subs, lang, files ──

        // Aspect (always available)
        {
            const ar_text = currentAspectChipText(active_p.mpv_ctx);
            const ar_active = !std.mem.eql(u8, ar_text, "Auto");
            if (pickerIconChip(@src(), 700, icons.tvg.lucide.ratio, ar_text, ar_active, "Aspect ratio")) {
                open_picker = if (open_picker == .aspect) .none else .aspect;
            }
        }

        // Chapters — only when count > 1.
        {
            var chp_buf: [16]u8 = undefined;
            const chp = currentChapterChipText(active_p.mpv_ctx, &chp_buf);
            if (chp.count > 1) {
                if (pickerIconChip(@src(), 701, icons.tvg.lucide.bookmark, chp.text, true, "Chapters")) {
                    open_picker = if (open_picker == .chapter) .none else .chapter;
                }
            }
        }

        // Audio.
        {
            var aud_buf: [32]u8 = undefined;
            const aud = currentTrackChipText(active_p.mpv_ctx, "audio", &aud_buf);
            if (pickerIconChip(@src(), 702, icons.tvg.lucide.music, aud.text, aud.active, "Audio track")) {
                open_picker = if (open_picker == .audio) .none else .audio;
            }
        }

        // Subs.
        {
            var sub_buf: [32]u8 = undefined;
            const sub = currentTrackChipText(active_p.mpv_ctx, "sub", &sub_buf);
            if (pickerIconChip(@src(), 703, icons.tvg.lucide.captions, sub.text, sub.active, "Subtitle track")) {
                open_picker = if (open_picker == .sub) .none else .sub;
            }
        }

        // Subtitle language.
        {
            const cur_lang = state.app.sub_lang_buf[0..state.app.sub_lang_len];
            const chip = if (cur_lang.len > 0) cur_lang else "eng";
            if (pickerIconChip(@src(), 704, icons.tvg.lucide.globe, chip, cur_lang.len > 0, "Subtitle search language")) {
                open_picker = if (open_picker == .lang) .none else .lang;
            }
        }

        // Find Subtitles — direct shortcut.
        if (pickerIconChip(@src(), 705, icons.tvg.lucide.search, "Subs", false, "Find subtitles online")) {
            state.app.sub_picker_open = true;
            const subs = @import("../services/subtitles.zig");
            if (!subs.is_searching) subs.autoSearchFromPlayer();
        }

        // Files (torrent multi-file playlist).
        if (active_p.current_torrent_id >= 0) {
            const file_count = c.mpv.torrent_get_file_count(state.app.torrent_ses, active_p.current_torrent_id);
            if (file_count > 1) {
                var f_buf: [16]u8 = undefined;
                const f_chip = std.fmt.bufPrint(&f_buf, "{d}", .{file_count}) catch "";
                if (pickerIconChip(@src(), 706, icons.tvg.lucide.list, f_chip, true, "Files in torrent")) {
                    open_picker = if (open_picker == .playlist) .none else .playlist;
                }
            }
        }

        // ── Close player — far right, semantic_error on hover ──
        // We use module-level state to carry hover across frames: read the
        // rect captured last frame, then update it after this frame's button
        // is laid out. One frame of lag is fine for a hover effect.
        {
            var spacer2 = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = theme.spacing.sm, .h = 0 } });
            spacer2.deinit();
        }

        const close_hovered_now = mouseOverRect(close_button_rect);
        if (dvui.buttonIcon(@src(), "close", icons.tvg.lucide.x, .{}, .{}, .{
            .data_out = &wd,
            .color_fill = transparent,
            .color_text = if (close_hovered_now) theme.colors.semantic_error else theme.colors.text_secondary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .border = dvui.Rect.all(0),
            .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
            .min_size_content = .{ .w = 28, .h = 28 },
            .max_size_content = .{ .w = 28, .h = 28 },
            .gravity_y = 0.5,
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
        })) {
            state.app.pending_remove_player_idx = @as(i32, @intCast(state.app.active_player_idx));
        }
        // Capture the actual rendered rect for next frame's hover test.
        close_button_rect = wd.borderRectScale().r;
        components.tip(@src(), wd, "Close player (Esc)");
    }

    // ═══════════════════════════════════════════════════════════════
    // ROW 3 — Demoted torrent status (font_size.small, text_tertiary)
    // ═══════════════════════════════════════════════════════════════
    if (active_p.current_torrent_id >= 0) {
        var info_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 22 },
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
        });
        defer info_row.deinit();

        var t_name: [64]u8 = undefined;
        c.mpv.torrent_get_name(state.app.torrent_ses, active_p.current_torrent_id, &t_name, 64);
        var pct: f32 = 0.0;
        var dl_rate: c_int = 0;
        var seeds: c_int = 0;
        _ = c.mpv.torrent_poll(state.app.torrent_ses, active_p.current_torrent_id, active_p.selected_file_idx, null, 0, &pct, &dl_rate, &seeds);
        const name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse t_name.len;
        const rate_mb = @as(f32, @floatFromInt(dl_rate)) / 1024.0 / 1024.0;

        // Untrusted torrent metadata, truncated at the 64-byte buffer (possibly
        // mid-codepoint) — validate before dvui (matches grid.zig).
        _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(t_name[0..name_len])}, .{
            .color_text = theme.colors.text_tertiary,
            .gravity_y = 0.5,
        });

        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        var stat_buf: [80]u8 = undefined;
        if (std.fmt.bufPrintZ(&stat_buf, "{d:.1}% \xC2\xB7 {d:.1} MB/s \xC2\xB7 {d} seeds", .{ pct * 100.0, rate_mb, seeds })) |st| {
            _ = dvui.label(@src(), "{s}", .{st}, .{
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
            });
        } else |_| {}

        // Speed-limit cycle — also demoted.
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
                .color_text = theme.colors.text_tertiary,
                .border = dvui.Rect.all(0),
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
                .gravity_y = 0.5,
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

    // ── Floating popovers (rendered last — they're free-positioned) ──
    renderChapterPickerPopover(active_p);
    renderAspectPickerPopover(active_p);
    renderTrackPickerPopover(active_p, "audio", .audio);
    renderTrackPickerPopover(active_p, "sub", .sub);
    renderLangPickerPopover();
    renderPlaylistPickerPopover(active_p);
}

// ── Persistent NOW-PLAYING media bar ──
//
// A Spotify/SoundCloud-style transport bar that lives at the very bottom of the
// app (above the thin torrent-activity strip) so playback stays controllable
// while the user browses any tab. It is intentionally robust for audio-only
// media (e.g. YouTube audio): it never needs a video texture — title, transport
// and scrubber render purely off mpv properties + the player's loading label.
//
// Rendered only when there is *active media*:
//   active_player_idx < players.items.len  AND  provider == .mpv
//   AND (p.has_metadata OR p.loading_label_len > 0)
// On the `.player` route the full in-player controls (renderLiquidGlassOverlay)
// already show, so we skip the bar there to avoid a duplicate transport. (Shell
// also gates this whole tray off the player route, but we guard here too.)

/// Returns the active mpv player when there is loaded/loading media to control,
/// else null. All callers MUST treat null as "no media bar". Player access is
/// guarded by the active-idx bound check before any indexing.
fn activeMediaPlayer() ?*player.MediaPlayer {
    if (state.app.active_player_idx >= state.app.players.items.len) return null;
    const p = state.app.players.items[state.app.active_player_idx];
    if (p.provider != .mpv) return null;
    // "Active media" mirrors the scrubber/overlay heuristic: metadata loaded,
    // or a loading label present (covers the audio-only / still-buffering case).
    if (!p.has_metadata and p.loading_label_len == 0) return null;
    return p;
}

/// The ~100px now-playing bar. Caller guarantees `p` is the active mpv player.
fn renderNowPlayingBar(p: *player.MediaPlayer) void {
    const text = @import("../core/text.zig");
    const queue = @import("../services/queue.zig");
    const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const now_ms = @import("../core/io_global.zig").milliTimestamp();

    // ── Transport state (cheap, every frame) ──
    var is_paused: c_int = 0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &is_paused);
    var percent_pos: f64 = 0.0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "percent-pos", c.mpv.MPV_FORMAT_DOUBLE, &percent_pos);
    var time_pos: f64 = 0.0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &time_pos);
    var duration: f64 = 0.0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &duration);
    var volume: f64 = 100.0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "volume", c.mpv.MPV_FORMAT_DOUBLE, &volume);

    // ── Bar panel: bg_surface + 1px top border, ~100px tall ──
    var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
        .min_size_content = .{ .w = 0, .h = 100 },
        .max_size_content = .{ .w = 0, .h = 100 },
    });
    defer bar.deinit();

    // ── Row 1: scrubber + chapter pips (reused, identical seek behavior) ──
    renderScrubber(p, percent_pos, duration, now_ms);

    // ── Row 2: [thumb + title] | [transport] | [time] | [volume] | [queue] ──
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 56 },
        .max_size_content = .{ .w = 0, .h = 56 },
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
    });
    defer row.deinit();

    var wd: dvui.WidgetData = undefined;

    // ── Left: glyph + now-playing title (ellipsized, capped width) ──
    {
        var left = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 200, .h = 0 },
            .max_size_content = .{ .w = 280, .h = 0 },
        });
        defer left.deinit();

        // A small thumbnail when mpv exposed one, else a music/film glyph.
        if (p.thumb_texture != null) {
            _ = dvui.image(@src(), .{ .source = .{ .texture = p.thumb_texture.? } }, .{
                .min_size_content = .{ .w = 40, .h = 40 },
                .max_size_content = .{ .w = 40, .h = 40 },
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
        } else {
            _ = dvui.icon(@src(), "np-glyph", icons.tvg.lucide.music, .{}, .{
                .color_text = theme.colors.accent,
                .min_size_content = .{ .w = 22, .h = 22 },
                .max_size_content = .{ .w = 22, .h = 22 },
                .gravity_y = 0.5,
                .margin = .{ .x = 4, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
        }

        // Title from the player's loading label (works for audio-only).
        const raw_title = if (p.loading_label_len > 0) p.loading_label[0..p.loading_label_len] else "Now Playing";
        // safeUtf8Buf (not plain safeUtf8): loading_label is mutated by the load
        // worker, so validating a slice into the live buffer can still let dvui
        // re-read mutated bytes mid-frame. Snapshot a stable copy first.
        var nt_buf: [128]u8 = undefined;
        var title = text.safeUtf8Buf(raw_title, &nt_buf);
        if (title.len > 42) title = text.safeUtf8(title[0..42]); // re-trim to a codepoint boundary (on the copy)
        _ = dvui.label(@src(), "{s}", .{title}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
        });
    }

    // ── Center: transport (Previous | Play/Pause | Next) ──
    {
        var center = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .gravity_x = 0.5,
            .expand = .horizontal,
        });
        defer center.deinit();

        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        // Previous — best-effort. No prev-queue API, so use mpv playlist-prev
        // (handles internal playlists / torrent files); harmless otherwise.
        if (dvui.buttonIcon(@src(), "np-prev", icons.tvg.lucide.@"skip-back", .{}, .{}, .{
            .data_out = &wd,
            .color_fill = transparent,
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .gravity_y = 0.5,
            .padding = .{ .x = 7, .y = 7, .w = 7, .h = 7 },
            .min_size_content = .{ .w = 34, .h = 34 },
            .max_size_content = .{ .w = 34, .h = 34 },
        })) {
            _ = c.mpv.mpv_command_string(p.mpv_ctx, "playlist-prev");
        }
        components.tip(@src(), wd, "Previous");

        // Play / Pause — the single accent affordance.
        const toggle_icon = if (is_paused != 0) icons.tvg.lucide.play else icons.tvg.lucide.pause;
        if (dvui.buttonIcon(@src(), "np-pp", toggle_icon, .{}, .{}, .{
            .data_out = &wd,
            .color_fill = theme.colors.accent_primary,
            .color_text = theme.colors.text_on_accent,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .gravity_y = 0.5,
            .padding = .{ .x = 10, .y = 10, .w = 10, .h = 10 },
            .min_size_content = .{ .w = 40, .h = 40 },
            .max_size_content = .{ .w = 40, .h = 40 },
            .margin = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.sm, .h = 0 },
        })) {
            p.togglePause();
        }
        components.tip(@src(), wd, "Play/Pause");

        // Next — plays the next unplayed queue item.
        if (dvui.buttonIcon(@src(), "np-next", icons.tvg.lucide.@"skip-forward", .{}, .{}, .{
            .data_out = &wd,
            .color_fill = transparent,
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .gravity_y = 0.5,
            .padding = .{ .x = 7, .y = 7, .w = 7, .h = 7 },
            .min_size_content = .{ .w = 34, .h = 34 },
            .max_size_content = .{ .w = 34, .h = 34 },
        })) {
            queue.playNextUnplayed(p);
        }
        components.tip(@src(), wd, "Next (from queue)");

        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
    }

    // ── Time readout: elapsed / total ──
    {
        const safe_time = @max(0.0, if (std.math.isNan(time_pos)) 0.0 else time_pos);
        const safe_dur = @max(0.0, if (std.math.isNan(duration)) 0.0 else duration);
        var cur_buf: [16]u8 = undefined;
        var tot_buf: [16]u8 = undefined;
        const cur_str = formatHmsBuf(&cur_buf, @as(u32, @intFromFloat(safe_time)));
        const tot_str = formatHmsBuf(&tot_buf, @as(u32, @intFromFloat(safe_dur)));
        _ = dvui.label(@src(), "{s}", .{cur_str}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
        });
        _ = dvui.label(@src(), " / {s}", .{tot_str}, .{
            .color_text = theme.colors.text_tertiary,
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
    }

    // ── Right: volume slider + queue toggle ──
    {
        _ = dvui.icon(@src(), "np-vol-ic", icons.tvg.lucide.@"volume-2", .{}, .{
            .color_text = theme.colors.text_secondary,
            .min_size_content = .{ .w = 16, .h = 16 },
            .max_size_content = .{ .w = 16, .h = 16 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
        });
        var vol_val: f32 = @floatCast(@max(0.0, @min(1.0, volume / 100.0)));
        if (dvui.slider(@src(), .{ .fraction = &vol_val }, .{
            .min_size_content = .{ .w = 90, .h = 4 },
            .max_size_content = .{ .w = 90, .h = 4 },
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = dvui.Rect.all(2),
            .gravity_y = 0.5,
            .background = true,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        })) {
            var vc: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&vc, "set volume {d}", .{@as(i32, @intFromFloat(vol_val * 100.0))})) |cmd| {
                _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
            } else |_| {}
        }

        // Queue / playlist toggle — opens the torrent files dropdown when this
        // is a multi-file torrent; also shows the queue count badge.
        var q_buf: [16]u8 = undefined;
        const q_label = std.fmt.bufPrint(&q_buf, "{d}", .{queue.queue_count}) catch "";
        if (pickerIconChip(@src(), 720, icons.tvg.lucide.@"list-music", q_label, queue.queue_count > 0, "Queue / playlist")) {
            state.app.router.navigate(.player);
        }
        // Inline torrent-files dropdown (no-op when single file / no torrent).
        var pl_menu = dvui.menu(@src(), .horizontal, .{ .gravity_y = 0.5 });
        defer pl_menu.deinit();
        playlistDropdownMenu(p);
    }
}

/// The thin torrent-activity strip — unchanged from the original tray. Rendered
/// below the now-playing bar (or alone, when nothing is playing).
fn renderTorrentActivityStrip() void {
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

    // Single accent — the leading "Active" indicator. Everything else reads
    // on the neutral text ramp (rate brightens to text_primary when live).
    _ = dvui.buttonIcon(@src(), "", icons.tvg.lucide.activity, .{}, .{}, .{
        .gravity_y = 0.5,
        .color_fill = transparent,
        .color_text = theme.colors.accent,
        .padding = dvui.Rect.all(2),
    });
    _ = dvui.label(@src(), "{d} Active", .{total_active}, .{ .color_text = theme.colors.text_primary, .gravity_y = 0.5 });

    {
        var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        spacer.deinit();
    }

    const mb_s = total_dl / (1024.0 * 1024.0);
    const rate_color = if (mb_s > 0.1) theme.colors.text_primary else theme.colors.text_tertiary;
    _ = dvui.buttonIcon(@src(), "", icons.tvg.lucide.download, .{}, .{}, .{
        .gravity_y = 0.5,
        .color_fill = transparent,
        .color_text = rate_color,
        .padding = dvui.Rect.all(2),
    });
    var mb_str: [32]u8 = undefined;
    if (std.fmt.bufPrintZ(&mb_str, "{d:.2} MB/s", .{mb_s})) |msg| {
        _ = dvui.label(@src(), "{s}", .{msg}, .{
            .color_text = rate_color,
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
    } else |_| {}

    _ = dvui.buttonIcon(@src(), "", icons.tvg.lucide.users, .{}, .{}, .{
        .gravity_y = 0.5,
        .color_fill = transparent,
        .color_text = theme.colors.text_tertiary,
        .padding = dvui.Rect.all(2),
    });
    _ = dvui.label(@src(), "{d} Peers", .{total_peers}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5 });
}

/// The persistent bottom tray, rendered across every non-player tab by shell.zig.
/// Vertical stack:
///   [ NOW-PLAYING media bar — only when there is active media ]
///   [ thin torrent-activity strip — always, unchanged ]
/// When nothing is playing the tray looks exactly as it did before.
pub fn renderGlobalBottomTray() void {
    var stack = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer stack.deinit();

    // Media bar: only with active media, and never on the player route (the
    // in-player overlay owns transport there). Player access is guarded inside
    // activeMediaPlayer() before any indexing.
    if (state.app.router.current != .player) {
        if (activeMediaPlayer()) |p| {
            renderNowPlayingBar(p);
        }
    }

    renderTorrentActivityStrip();
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

    // Semantic colors based on toast type
    const toast_color = switch (state.app.toast_type) {
        .info => theme.colors.accent,
        .success => theme.colors.success,
        .warning => theme.colors.warning,
        .err => theme.colors.danger,
    };
    const toast_icon = switch (state.app.toast_type) {
        .info => icons.tvg.lucide.info,
        .success => icons.tvg.lucide.@"circle-check-big",
        .warning => icons.tvg.lucide.info,
        .err => icons.tvg.lucide.x,
    };

    // Toast container — top-center, flat elevated surface + one soft shadow.
    // No colored border; the type is conveyed by the icon hue alone.
    var toast_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.06,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.md, .w = theme.spacing.lg, .h = theme.spacing.md },
        .box_shadow = .{
            .color = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 160 },
            .offset = .{ .x = 0, .y = 4 },
            .fade = 20,
        },
    });
    defer toast_box.deinit();

    // Icon prefix — color carries the (transient) toast type signal.
    _ = dvui.icon(@src(), "", toast_icon, .{}, .{
        .color_text = toast_color,
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
    });

    // Toast text is written by background workers (subtitle/streamlink/cast) and
    // @min-truncated at 127 bytes — validate a snapshot copy so a non-UTF-8 or
    // mid-codepoint byte can't panic dvui.
    var tb: [128]u8 = undefined;
    _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(state.app.toast_buf[0..state.app.toast_len], &tb)}, .{
        .color_text = theme.colors.text_primary,
        .gravity_y = 0.5,
    });
}

/// Stats for Nerds — semi-transparent HUD in top-left corner.
/// Toggle with Ctrl+I (already wired in input.zig as media_info_open toggle —
/// this overlay uses a separate `stats_overlay_open` flag).
pub fn renderStatsOverlay() void {
    if (!state.app.stats_overlay_open) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    if (p.provider != .mpv) return;

    var overlay_anchor = dvui.overlay(@src(), .{ .expand = .both });
    defer overlay_anchor.deinit();

    var stats_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_x = 0.02,
        .gravity_y = 0.04,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        .min_size_content = .{ .w = 220, .h = 0 },
        .box_shadow = .{
            .color = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 160 },
            .offset = .{ .x = 0, .y = 4 },
            .fade = 20,
        },
    });
    defer stats_box.deinit();

    // Title — the single accent in this overlay.
    _ = dvui.label(@src(), "Stats for Nerds", .{}, .{
        .color_text = theme.colors.accent,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.xs },
    });

    // Helper: query a string prop from mpv
    const stat_props = [_][2][]const u8{
        .{ "video-codec", "Video" },
        .{ "audio-codec-name", "Audio" },
        .{ "hwdec-current", "HW Dec" },
    };

    // Resolution + FPS (from cached SlowProps would be ideal, but we query directly here)
    {
        var w: i64 = 0;
        var h: i64 = 0;
        var fps: f64 = 0;
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "width", c.mpv.MPV_FORMAT_INT64, &w);
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "height", c.mpv.MPV_FORMAT_INT64, &h);
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "estimated-vf-fps", c.mpv.MPV_FORMAT_DOUBLE, &fps);

        var res_buf: [48]u8 = undefined;
        const res_str = std.fmt.bufPrint(&res_buf, "{d}×{d} @ {d:.1} fps", .{ w, h, fps }) catch "—";
        renderStatRow("Resolution", res_str, 0);
    }

    // Bitrate
    {
        var vbr: f64 = 0;
        var abr: f64 = 0;
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "video-bitrate", c.mpv.MPV_FORMAT_DOUBLE, &vbr);
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "audio-bitrate", c.mpv.MPV_FORMAT_DOUBLE, &abr);
        const vbr_kbps = @as(i64, @intFromFloat(vbr / 1000.0));
        const abr_kbps = @as(i64, @intFromFloat(abr / 1000.0));
        var br_buf: [48]u8 = undefined;
        const br_str = std.fmt.bufPrint(&br_buf, "V: {d} kb/s  A: {d} kb/s", .{ vbr_kbps, abr_kbps }) catch "—";
        renderStatRow("Bitrate", br_str, 1);
    }

    // Dropped frames
    {
        var dropped: i64 = 0;
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "frame-drop-count", c.mpv.MPV_FORMAT_INT64, &dropped);
        var drop_buf: [24]u8 = undefined;
        const drop_str = std.fmt.bufPrint(&drop_buf, "{d}", .{dropped}) catch "0";
        renderStatRow("Dropped", drop_str, 2);
    }

    // String props (codec, hwdec)
    for (stat_props, 0..) |prop, idx| {
        const val_ptr: ?[*:0]u8 = @ptrCast(c.mpv.mpv_get_property_string(p.mpv_ctx, @ptrCast(prop[0].ptr)));
        if (val_ptr) |vp| {
            const val_str = std.mem.span(vp);
            renderStatRow(prop[1], val_str, idx + 10);
            c.mpv.mpv_free(vp);
        } else {
            renderStatRow(prop[1], "—", idx + 10);
        }
    }
}

fn renderStatRow(label: []const u8, value: []const u8, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
    });
    defer row.deinit();

    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id_extra + 100,
        .color_text = theme.colors.text_muted,
        .min_size_content = .{ .w = 80, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{value}, .{
        .id_extra = id_extra + 200,
        .color_text = theme.colors.text_main,
    });
}
