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
const pickers = @import("pickers.zig");

// ── Local module state ──
// Toggle between elapsed-and-total ("00:42/01:30") and elapsed-and-remaining
// ("00:42/-00:48") display. Survives across frames; cycled by clicking the
// time label.
var time_show_remaining: bool = false;

// Active toolbar dropdown — only one open at a time. We use stable id values
// derived from the picker kind. -1 = none.
pub const PickerKind = enum(i32) { none = -1, chapter = 0, aspect = 1, audio = 2, sub = 3, lang = 4, playlist = 5, ar = 6 };
/// pub so input.zig's staged-Escape chain can peel an open picker popover
/// (audio/sub/chapter/aspect/lang/playlist) before touching bigger surfaces.
pub var open_picker: PickerKind = .none;

/// On-screen rect of each picker's chip, in dvui NATURAL units, recorded as the
/// chip is laid out. The drop-up panels anchor to this: they float ABOVE their
/// chip with no backdrop, so they need to know where the chip actually landed.
/// Indexed by @intFromEnum(PickerKind); .none (-1) has no slot.
pub var picker_anchor: [8]dvui.Rect.Natural = [_]dvui.Rect.Natural{.{}} ** 8;

pub fn anchorFor(kind: PickerKind) dvui.Rect.Natural {
    const i = @intFromEnum(kind);
    if (i < 0 or i >= picker_anchor.len) return .{};
    return picker_anchor[@intCast(i)];
}

fn recordAnchor(kind: PickerKind, r: dvui.Rect.Physical) void {
    const i = @intFromEnum(kind);
    if (i < 0 or i >= picker_anchor.len) return;
    picker_anchor[@intCast(i)] = r.toNatural();
}

// Persist the close-button screen rect across frames so we can hover-test it
// before the button is rendered (one frame of lag is acceptable for hover).
var close_button_rect: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

// Physical rect of the in-player control panel, captured each frame it draws.
// grid.zig uses it to keep video-cell click handling (pause toggle / cell
// select) out of the control-bar band — those buttons render AFTER the grid,
// so the grid can't rely on `handled` flags to avoid double-firing.
var control_panel_rect: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// True when a physical mouse point lies within the control panel captured
/// last frame (one frame of lag — fine for click exclusion).
pub fn mouseInControlPanel(p: dvui.Point.Physical) bool {
    const r = control_panel_rect;
    return p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h;
}

/// True while any in-player picker popover is open — main.zig holds the
/// control overlay visible so a popover can't outlive its anchor bar.
pub fn pickerOpen() bool {
    return open_picker != .none;
}

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

    if (dvui.menuItemLabel(@src(), label, .{ .submenu = true }, .{ .id_extra = id_extra, .gravity_y = 0.5, .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, .color_text = theme.colors.text_secondary })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = theme.colors.bg_surface, .border = dvui.Rect.all(1), .color_border = theme.colors.border_subtle });
        defer menu.deinit();

        const modes = [_][]const u8{ "-1", "16:9", "4:3", "21:9" };
        const mode_labels = [_][]const u8{ "Auto", "16:9", "4:3", "21:9" };

        for (modes, 0..) |mode, k| {
            if (dvui.menuItemLabel(@src(), mode_labels[k], .{}, .{ .id_extra = k, .expand = .horizontal, .color_text = theme.colors.text_primary })) |_| {
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
    if (dvui.menuItemLabel(@src(), @import("../core/text.zig").safeUtf8(label), .{ .submenu = true }, .{ .id_extra = kind_id, .gravity_y = 0.5, .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, .color_text = theme.colors.text_secondary })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = theme.colors.bg_surface, .border = dvui.Rect.all(1), .color_border = theme.colors.border_subtle });
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

                    if (dvui.menuItemLabel(@src(), @import("../core/text.zig").safeUtf8(row_name), .{}, .{ .id_extra = i, .expand = .horizontal, .color_text = theme.colors.text_primary })) |_| {
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

    const file_count = c.mpv.torrent_get_file_count(state.torrentSession(), p.current_torrent_id);
    if (file_count <= 1) return;

    if (dvui.menuItemLabel(@src(), "Files", .{ .submenu = true }, .{ .id_extra = 99, .gravity_y = 0.5, .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, .color_text = theme.colors.text_secondary })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = theme.colors.bg_surface, .border = dvui.Rect.all(1), .color_border = theme.colors.border_subtle });
        defer menu.deinit();

        for (0..@as(usize, @intCast(@max(@as(c_int, 0), file_count)))) |i| {
            var name_buf: [256]u8 = undefined;
            c.mpv.torrent_get_file_name(state.torrentSession(), p.current_torrent_id, @intCast(i), &name_buf, 256);

            const size = c.mpv.torrent_get_file_size(state.torrentSession(), p.current_torrent_id, @intCast(i));
            const size_mb = @as(f64, @floatFromInt(size)) / 1024.0 / 1024.0;

            var lbl_buf: [300]u8 = undefined;
            const label = std.fmt.bufPrintZ(&lbl_buf, "{s} ({d:.1} MB)", .{ std.mem.sliceTo(&name_buf, 0), size_mb }) catch "File";

            if (dvui.menuItemLabel(@src(), label, .{}, .{
                .id_extra = i,
                .expand = .horizontal,
                .color_text = if (p.selected_file_idx == @as(i32, @intCast(i))) theme.colors.accent else theme.colors.text_primary,
            })) |_| {
                if (p.selected_file_idx != @as(i32, @intCast(i))) {
                    // Stop current playback immediately
                    _ = c.mpv.mpv_command_string(p.mpv_ctx, "stop");

                    // Deprioritize old file, prioritize new one
                    const old_idx = p.selected_file_idx;
                    if (old_idx >= 0 and old_idx < file_count) {
                        c.mpv.torrent_set_file_priority(state.torrentSession(), p.current_torrent_id, old_idx, 0);
                    }
                    p.selected_file_idx = @as(i32, @intCast(i));
                    c.mpv.torrent_set_file_priority(state.torrentSession(), p.current_torrent_id, @intCast(i), 4);
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

    if (dvui.menuItemLabel(@src(), label, .{ .submenu = true }, .{ .id_extra = 300, .gravity_y = 0.5, .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, .color_text = theme.colors.text_secondary })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        var menu = dvui.menu(@src(), .vertical, .{ .background = true, .color_fill = theme.colors.bg_surface, .border = dvui.Rect.all(1), .color_border = theme.colors.border_subtle });
        defer menu.deinit();

        const langs = [_][]const u8{ "eng", "spa", "fre", "ger", "por", "ita", "dut", "pol", "rus", "chi", "jpn", "kor", "ara", "hin", "tur" };
        const lang_names = [_][]const u8{ "English", "Spanish", "French", "German", "Portuguese", "Italian", "Dutch", "Polish", "Russian", "Chinese", "Japanese", "Korean", "Arabic", "Hindi", "Turkish" };

        for (langs, 0..) |l, k| {
            if (dvui.menuItemLabel(@src(), lang_names[k], .{}, .{ .id_extra = k, .expand = .horizontal, .color_text = theme.colors.text_primary })) |_| {
                @memcpy(state.app.sub_lang_buf[0..l.len], l);
                state.app.sub_lang_len = l.len;
                // Language changed — re-run the current subtitle search with it.
                @import("../player/subtitles.zig").refire(&state.app.sub_engine);
            }
        }
    }
}

/// Small source/language chip — pill outline, small font, quiet color.
fn subChip(text: []const u8, id_extra: usize) void {
    var f = dvui.themeGet().font_body;
    f.size = theme.font_size.small;
    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .border = dvui.Rect.all(1),
        .color_border = theme.colors.border_subtle,
        .corner_radius = dvui.Rect.all(theme.radius.pill),
        .padding = .{ .x = theme.spacing.sm, .y = 1, .w = theme.spacing.sm, .h = 1 },
        .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
    });
    defer chip.deinit();
    _ = dvui.label(@src(), "{s}", .{text}, .{
        .id_extra = id_extra,
        .color_text = theme.colors.text_secondary,
        .font = f,
        .gravity_y = 0.5,
    });
}

/// Inline spinner + status label row (ai_chat catalog-rail pattern). Keeps its
/// own repaint chain alive via dvui.refresh.
fn subStatusRow(text: []const u8, id_extra: usize) void {
    var lrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.xs },
    });
    defer lrow.deinit();
    dvui.spinner(@src(), .{
        .color_text = theme.colors.accent,
        .min_size_content = .{ .w = 12, .h = 12 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{text}, .{
        .color_text = theme.colors.text_tertiary,
        .gravity_y = 0.5,
    });
    dvui.refresh(null, @src(), null);
}

/// Quick-access subtitle finder. The footer chip opens this modal AND kicks a
/// keyless search (rest.opensubtitles.org + Gestdown/Addic7ed) immediately —
/// no account needed. When an opensubtitles.com API key is configured, its
/// results are appended under their own section.
pub fn renderSubPicker() void {
    if (!state.app.sub_picker_open) return;
    const subs = @import("../services/subtitles.zig"); // keyed: opensubtitles.com
    const engine_mod = @import("../player/subtitles.zig"); // keyless engine
    const engine = &state.app.sub_engine;
    const auto_subs = @import("../services/auto_subs.zig");
    const text_mod = @import("../core/text.zig");
    const has_key = state.app.opensub_api_key_len > 0;

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.sub_picker_open,
    }, .{
        .min_size_content = .{ .w = 600, .h = 460 },
        .color_fill = theme.colors.bg_surface,
        .border = dvui.Rect.all(1),
        .color_border = theme.colors.border_subtle,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
    });
    defer win.deinit();

    win.dragAreaSet(dvui.windowHeader("Find Subtitles", "", &state.app.sub_picker_open));

    var pad = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
    });
    defer pad.deinit();

    const engine_busy = engine.state == .searching or engine.state == .downloading;

    // ── Search row: free-text query + one accent action ──
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.xs },
        });
        defer row.deinit();

        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &state.app.sub_search_buf },
            .placeholder = "Search a title — e.g. The Boys S01E01",
        }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 200, .h = 20 },
            .color_fill = theme.colors.bg_elevated,
            .color_border = theme.colors.border_subtle,
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .gravity_y = 0.5,
        });
        const enter = te.enter_pressed;
        te.deinit();

        // Primary action — the single accent affordance in this view.
        const go = dvui.button(@src(), if (engine_busy) "Searching…" else "Search", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = theme.colors.text_on_accent,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
        });
        if ((go or enter) and !engine_busy) {
            const q_len = std.mem.indexOfScalar(u8, &state.app.sub_search_buf, 0) orelse 0;
            const lang = if (state.app.sub_lang_len > 0) state.app.sub_lang_buf[0..state.app.sub_lang_len] else "en";
            if (q_len > 0) {
                engine_mod.searchQuery(engine, state.app.sub_search_buf[0..q_len]);
                if (has_key and !subs.is_searching.load(.acquire)) subs.searchByQuery(state.app.sub_search_buf[0..q_len], lang);
            } else {
                engine_mod.searchFromActivePlayer(engine);
                if (has_key and !subs.is_searching.load(.acquire)) subs.autoSearchFromPlayer(false);
            }
        }

        // Re-detect from the playing file — quiet secondary.
        if (dvui.button(@src(), "Auto", .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
        })) {
            if (!engine_busy) {
                engine_mod.searchFromActivePlayer(engine);
                if (has_key and !subs.is_searching.load(.acquire)) subs.autoSearchFromPlayer(false);
            }
        }

        // Whisper generation — last resort, quiet.
        const gen_label = if (auto_subs.in_progress.load(.acquire)) "Generating…" else "Whisper";
        var gen_wd: dvui.WidgetData = undefined;
        if (dvui.button(@src(), gen_label, .{}, .{
            .data_out = &gen_wd,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
        })) {
            if (!auto_subs.in_progress.load(.acquire)) auto_subs.transcribeCurrent();
        }
        components.tip(@src(), gen_wd, "Transcribe the audio locally (whisper)");
    }

    // ── Context line: active query + search language ──
    {
        var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.xs },
        });
        defer meta.deinit();
        if (engine.query_len > 0) {
            var q_buf: [160]u8 = undefined;
            const q_show = text_mod.safeUtf8Buf(engine.query_buf[0..@min(engine.query_len, 120)], &q_buf);
            var lbl_buf: [176]u8 = undefined;
            const lbl = std.fmt.bufPrint(&lbl_buf, "Looking for: {s}", .{q_show}) catch "Looking for subtitles";
            _ = dvui.label(@src(), "{s}", .{lbl}, .{
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
            });
        }
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        const lang = if (state.app.sub_lang_len > 0) state.app.sub_lang_buf[0..state.app.sub_lang_len] else "eng";
        var lang_buf: [24]u8 = undefined;
        const lang_lbl = std.fmt.bufPrint(&lang_buf, "Language: {s}", .{lang}) catch "Language";
        _ = dvui.label(@src(), "{s}", .{lang_lbl}, .{
            .id_extra = 57001,
            .color_text = theme.colors.text_tertiary,
            .gravity_y = 0.5,
        });
    }

    // ── Live status while any worker runs ── (worker states have no UI wake
    // of their own — the spinner row's refresh keeps the modal repainting.)
    if (engine.state == .searching) {
        subStatusRow("Scouring OpenSubtitles and Addic7ed…", 57010);
    } else if (engine.state == .downloading) {
        subStatusRow("Downloading subtitle…", 57011);
    } else if (subs.is_searching.load(.acquire) or subs.is_downloading.load(.acquire)) {
        subStatusRow("Checking opensubtitles.com…", 57012);
    } else if (auto_subs.in_progress.load(.acquire)) {
        subStatusRow("Transcribing with whisper…", 57013);
    }

    if (auto_subs.status_len > 0 and !auto_subs.in_progress.load(.acquire)) {
        _ = dvui.label(@src(), "{s}", .{auto_subs.status_buf[0..auto_subs.status_len]}, .{
            .color_text = theme.colors.text_secondary,
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.xs },
        });
    }

    const keyed_count = if (has_key) subs.result_count else 0;
    const any_busy = engine_busy or subs.is_searching.load(.acquire) or auto_subs.in_progress.load(.acquire);

    // ── Empty state ──
    if (engine.result_count == 0 and keyed_count == 0 and !any_busy) {
        if (engine.state == .failed) {
            components.emptyState(icons.tvg.lucide.captions, "Nothing surfaced", "Try a shorter title, or switch the search language from the globe chip.");
        } else {
            components.emptyState(icons.tvg.lucide.captions, "Search the open providers", "No account needed — results come straight from OpenSubtitles and Addic7ed.");
        }
        if (!has_key) {
            _ = dvui.label(@src(), "Add an OpenSubtitles.com key in Settings › Subtitles for more results.", .{}, .{
                .id_extra = 57020,
                .color_text = theme.colors.text_tertiary,
                .gravity_x = 0.5,
            });
        }
        return;
    }

    // ── Results ──
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = false,
    });
    defer scroll.deinit();

    // Keyless results — full experience, no key required.
    if (engine.result_count > 0) {
        components.sectionHeader("Open providers");
        for (0..engine.result_count) |ri| {
            const r = &engine.results[ri];
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = ri + 58000,
                .expand = .horizontal,
                .background = true,
                .color_fill = theme.colors.bg_elevated,
                .corner_radius = dvui.Rect.all(theme.radius.md),
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            });
            defer row.deinit();

            // Name — untrusted + worker-written; validate a snapshot so an
            // invalid/mid-codepoint byte can't panic dvui.
            var nm_buf: [160]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(r.movie_name[0..@min(r.movie_name_len, 120)], &nm_buf)}, .{
                .id_extra = ri + 58100,
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
                .expand = .horizontal,
            });

            if (r.lang_len > 0) {
                var fl_buf: [16]u8 = undefined;
                subChip(text_mod.safeUtf8Buf(r.lang[0..r.lang_len], &fl_buf), ri + 58200);
            }
            subChip(engine_mod.sourceName(r.source), ri + 58300);

            if (engine.loaded_idx == @as(i32, @intCast(ri))) {
                _ = dvui.icon(@src(), "sub-loaded", icons.tvg.lucide.check, .{}, .{
                    .id_extra = ri + 58450,
                    .color_text = theme.colors.success,
                    .min_size_content = theme.iconSize(.xs),
                    .gravity_y = 0.5,
                    .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 2, .h = 0 },
                });
                _ = dvui.label(@src(), "Loaded", .{}, .{
                    .id_extra = ri + 58400,
                    .color_text = theme.colors.success,
                    .gravity_y = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
                });
            } else if (engine.state == .downloading and engine.selected_idx == ri) {
                dvui.spinner(@src(), .{
                    .id_extra = ri + 58400,
                    .color_text = theme.colors.accent,
                    .min_size_content = .{ .w = 12, .h = 12 },
                    .gravity_y = 0.5,
                    .margin = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.xs, .h = 0 },
                });
            } else {
                if (dvui.button(@src(), "Download", .{}, .{
                    .id_extra = ri + 58500,
                    .color_fill = theme.colors.bg_surface,
                    .color_text = theme.colors.text_primary,
                    .color_fill_hover = theme.colors.bg_hover,
                    .corner_radius = dvui.Rect.all(theme.radius.sm),
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                    .gravity_y = 0.5,
                    .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
                })) {
                    engine_mod.downloadIndex(engine, ri);
                }
            }
        }
    }

    // Keyed results — appended under their own section when a key exists.
    if (has_key) {
        if (subs.result_count > 0 or subs.search_error_len > 0) {
            components.sectionHeader("OpenSubtitles.com");
        }
        if (subs.search_error_len > 0 and subs.result_count == 0 and !subs.is_searching.load(.acquire)) {
            var err_buf: [128]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(subs.search_error[0..subs.search_error_len], &err_buf)}, .{
                .id_extra = 57030,
                .color_text = theme.colors.warning,
                .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.xs },
            });
        }
        for (0..subs.result_count) |ri| {
            const r = &subs.results[ri];
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = ri + 59000,
                .expand = .horizontal,
                .background = true,
                .color_fill = theme.colors.bg_elevated,
                .corner_radius = dvui.Rect.all(theme.radius.md),
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            });
            defer row.deinit();

            if (r.release_len > 0) {
                var rel_buf: [128]u8 = undefined;
                _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(r.release[0..@min(r.release_len, 70)], &rel_buf)}, .{
                    .id_extra = ri + 59100,
                    .color_text = theme.colors.text_primary,
                    .gravity_y = 0.5,
                    .expand = .horizontal,
                });
            } else {
                var sp = dvui.box(@src(), .{}, .{ .id_extra = ri + 59150, .expand = .horizontal });
                sp.deinit();
            }
            if (r.download_count > 0) {
                var dc_buf: [16]u8 = undefined;
                const dc_str = std.fmt.bufPrint(&dc_buf, "{d}", .{r.download_count}) catch "";
                _ = dvui.icon(@src(), "dl-ic", icons.tvg.lucide.@"arrow-down", .{}, .{
                    .id_extra = ri + 59200,
                    .color_text = theme.colors.text_tertiary,
                    .min_size_content = theme.iconSize(.xs),
                    .max_size_content = .{ .w = 12, .h = 12 },
                    .gravity_y = 0.5,
                });
                _ = dvui.label(@src(), "{s}", .{dc_str}, .{
                    .id_extra = ri + 59300,
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
                });
            }
            if (r.hearing_impaired) {
                _ = dvui.label(@src(), "CC", .{}, .{
                    .id_extra = ri + 59400,
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
                });
            }
            if (r.lang_len > 0) {
                var fl_buf: [16]u8 = undefined;
                subChip(text_mod.safeUtf8Buf(r.language[0..r.lang_len], &fl_buf), ri + 59500);
            }
            subChip("OS.com", ri + 59600);
            if (dvui.button(@src(), if (subs.is_downloading.load(.acquire)) "…" else "Download", .{}, .{
                .id_extra = ri + 59700,
                .color_fill = theme.colors.bg_surface,
                .color_text = theme.colors.text_primary,
                .color_fill_hover = theme.colors.bg_hover,
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            })) {
                if (!subs.is_downloading.load(.acquire) and r.file_id > 0) {
                    subs.downloadSubtitle(r.file_id);
                }
            }
        }
    } else {
        // Quiet upsell — one line, never blocks the keyless flow.
        _ = dvui.label(@src(), "Add an OpenSubtitles.com key in Settings › Subtitles for more results.", .{}, .{
            .id_extra = 57040,
            .color_text = theme.colors.text_tertiary,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
        });
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
    time_pos: f64,
    duration: f64,
    now_ms: i64,
) void {
    // IINA-style scrub row: elapsed time on the left, the seek band filling
    // the middle, total/remaining on the right (click the right label to
    // toggle, same as IINA).
    var srow = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 26 },
        .max_size_content = .{ .w = 0, .h = 26 },
        .padding = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = 0 },
    });
    defer srow.deinit();

    const safe_time = @max(0.0, if (std.math.isNan(time_pos)) 0.0 else time_pos);
    const safe_dur = @max(0.0, if (std.math.isNan(duration)) 0.0 else duration);
    const t_sec: u32 = @intFromFloat(safe_time);
    const d_sec: u32 = @intFromFloat(safe_dur);

    {
        var cur_buf: [16]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{formatHmsBuf(&cur_buf, t_sec)}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
    }

    var scrub_band = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
    });
    defer {
        scrub_band.deinit();
        // Right: duration (or remaining) — rendered after the band so it sits
        // at the row's right edge; click toggles total/remaining.
        var dur_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
            .corner_radius = dvui.Rect.all(theme.radius.sm),
        });
        if (dvui.clicked(dur_box.data(), .{})) time_show_remaining = !time_show_remaining;
        components.tip(@src(), dur_box.data().*, if (time_show_remaining) "Showing remaining — click for total" else "Click to show remaining time");
        var dur_buf: [20]u8 = undefined;
        const dur_str = if (time_show_remaining and d_sec >= t_sec) blk: {
            var b2: [16]u8 = undefined;
            const r = formatHmsBuf(&b2, d_sec - t_sec);
            break :blk std.fmt.bufPrint(&dur_buf, "-{s}", .{r}) catch "-0:00";
        } else formatHmsBuf(&dur_buf, d_sec);
        _ = dvui.label(@src(), "{s}", .{dur_str}, .{
            .color_text = theme.colors.text_tertiary,
            .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
            .gravity_y = 0.5,
        });
        dur_box.deinit();
    }

    const band_rect = scrub_band.data().contentRectScale().r;
    const hovered = mouseOverRect(band_rect);
    const track_h: f32 = if (hovered) 6 else 4;

    // The overlay spans the FULL band height: the transparent slider that
    // captures seek drags fills it, so the grab target is the whole 26px
    // band — the drawn line stays thin (track_h). It used to be clamped to
    // the 4-6px visual track, which made drags miss more often than not.
    var track_overlay = dvui.overlay(@src(), .{
        .expand = .both,
    });
    defer track_overlay.deinit();

    const track_rect = track_overlay.data().contentRectScale().r;

    // 1. Base track — thin visual line centered in the tall band.
    {
        var base = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 1,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(track_h * 0.5),
            // Explicit width from the measured overlay rect — expand does
            // NOT stretch inside this overlay (the line collapsed to a dash).
            .min_size_content = .{ .w = track_rect.w, .h = track_h },
            .max_size_content = .{ .w = track_rect.w, .h = track_h },
            .gravity_y = 0.5,
        });
        base.deinit();
    }

    // 2. Buffered fill (torrent download — single leading bar). The piece-map
    // fetch + full have-count scan used to run every frame (~30fps); cache the
    // computed fraction at ~2Hz keyed on the torrent id (same idiom as PipCache
    // below — switching to a different torrent invalidates it immediately).
    if (active_p.current_torrent_id >= 0) {
        const BufCache = struct {
            var tid: i32 = -1;
            var last_ms: i64 = 0;
            var frac: f32 = 0.0;
        };
        if (BufCache.tid != active_p.current_torrent_id or now_ms - BufCache.last_ms > 500) {
            BufCache.tid = active_p.current_torrent_id;
            BufCache.last_ms = now_ms;
            BufCache.frac = 0.0;
            var map_buf: [2048]u8 = undefined;
            const map_len = c.mpv.torrent_get_piece_map(state.torrentSession(), active_p.current_torrent_id, &map_buf, 2048);
            if (map_len > 0) {
                var downloaded_count: usize = 0;
                var i: usize = 0;
                while (i < @as(usize, @intCast(@max(@as(c_int, 0), map_len)))) : (i += 1) {
                    if (map_buf[i] == '1') downloaded_count += 1;
                }
                BufCache.frac = @as(f32, @floatFromInt(downloaded_count)) / @as(f32, @floatFromInt(map_len));
            }
        }
        const buf_frac: f32 = BufCache.frac;
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

    // 3. Played fill — overlay on top.
    {
        const played_frac: f32 = @floatCast(@max(0.0, @min(1.0, percent_pos / 100.0)));
        if (played_frac > 0.0) {
            var played = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = 3,
                .background = true,
                .color_fill = theme.colors.accent,
                .corner_radius = dvui.Rect.all(track_h * 0.5),
                .min_size_content = .{ .w = track_rect.w * played_frac, .h = track_h },
                .max_size_content = .{ .w = track_rect.w * played_frac, .h = track_h },
                .gravity_x = 0.0,
                .gravity_y = 0.5,
            });
            played.deinit();
        }
    }

    // 4. Chapter pips — only after metadata is loaded. Chapter times are
    // CACHED (refreshed at most every 2s per player): they only change on
    // file load, but this block used to make up to 65 synchronous mpv IPC
    // calls per frame for the whole time the scrubber was visible.
    if (active_p.has_metadata and duration > 0) {
        const PipCache = struct {
            var fracs: [64]f32 = undefined;
            var count: usize = 0;
            var ctx_key: usize = 0;
            var last_ms: i64 = 0;
        };
        const pc_key = @intFromPtr(active_p.mpv_ctx);
        if (PipCache.ctx_key != pc_key or now_ms - PipCache.last_ms > 2000) {
            PipCache.ctx_key = pc_key;
            PipCache.last_ms = now_ms;
            PipCache.count = 0;
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
                    PipCache.fracs[PipCache.count] = @floatCast(t / duration);
                    PipCache.count += 1;
                }
            }
        }
        for (PipCache.fracs[0..PipCache.count], 0..) |pip_frac, pi| {
            var pip = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = pi + 1024,
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

    // 5. Hover knob.
    if (hovered) {
        const knob_frac: f32 = @floatCast(@max(0.0, @min(1.0, percent_pos / 100.0)));
        var knob = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = 4,
            .background = true,
            .color_fill = theme.colors.accent,
            .corner_radius = dvui.Rect.all(theme.radius.pill),
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
        .expand = .both,
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
                c.mpv.torrent_seek_prioritize(state.torrentSession(), active_p.current_torrent_id, active_p.selected_file_idx, seek_pct);
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
    kind: PickerKind,
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
    // The drop-up panel floats above this chip, so remember where it landed.
    recordAnchor(kind, btn_rect);
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

/// pub so pickers.zig's aspect popover can label the current mode; also used
/// by the toolbar aspect chip in this file.
pub fn currentAspectChipText(ctx: *c.mpv.mpv_handle) []const u8 {
    // The footer aspect chip polls this every frame, but the override only
    // changes on user action — cache the mpv read at ~2Hz keyed on ctx (same
    // 500ms gate as the audio/sub track chips). Returned values are string
    // literals, so caching the slice is lifetime-safe.
    const Cache = struct {
        var key: usize = 0;
        var last_ms: i64 = 0;
        var text: []const u8 = "Auto";
    };
    const key = @intFromPtr(ctx);
    const now = @import("../core/io_global.zig").milliTimestamp();
    if (Cache.key == key and now - Cache.last_ms < 500) return Cache.text;

    const result: []const u8 = blk: {
        const aspect_c = c.mpv.mpv_get_property_string(ctx, "video-aspect-override");
        defer if (aspect_c != null) c.mpv.mpv_free(@ptrCast(aspect_c));
        if (aspect_c == null) break :blk "Auto";
        const v = std.mem.span(aspect_c);
        if (std.mem.eql(u8, v, "16:9") or std.mem.startsWith(u8, v, "1.77")) break :blk "16:9";
        if (std.mem.eql(u8, v, "4:3") or std.mem.startsWith(u8, v, "1.33")) break :blk "4:3";
        if (std.mem.eql(u8, v, "21:9") or std.mem.startsWith(u8, v, "2.33")) break :blk "21:9";
        break :blk "Auto";
    };
    Cache.key = key;
    Cache.last_ms = now;
    Cache.text = result;
    return result;
}

fn currentChapterChipText(ctx: *c.mpv.mpv_handle, out_buf: []u8) struct { text: []const u8, count: i64 } {
    // Polled every frame by the footer chapter chip; cache the two mpv reads at
    // ~2Hz keyed on ctx (same 500ms gate as the track chips). The label is
    // re-formatted from cached values each call (cheap; no IPC).
    const Cache = struct {
        var key: usize = 0;
        var last_ms: i64 = 0;
        var count: i64 = 0;
        var current: i64 = -1;
    };
    const key = @intFromPtr(ctx);
    const now = @import("../core/io_global.zig").milliTimestamp();
    if (!(Cache.key == key and now - Cache.last_ms < 500)) {
        var ch_count: i64 = 0;
        _ = c.mpv.mpv_get_property(ctx, "chapter-list/count", c.mpv.MPV_FORMAT_INT64, &ch_count);
        var current_ch: i64 = -1;
        if (ch_count > 0) _ = c.mpv.mpv_get_property(ctx, "chapter", c.mpv.MPV_FORMAT_INT64, &current_ch);
        Cache.key = key;
        Cache.last_ms = now;
        Cache.count = ch_count;
        Cache.current = current_ch;
    }
    if (Cache.count <= 0) return .{ .text = "", .count = 0 };
    const s = std.fmt.bufPrint(out_buf, "{d}/{d}", .{ Cache.current + 1, Cache.count }) catch "";
    return .{ .text = s, .count = Cache.count };
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
    // Pause state mirrors mpv "pause" via the player worker's event loop
    // (cached_paused) — avoids a per-frame mpv IPC read at ~30fps.
    const is_paused: bool = active_p.cached_paused;
    const now_ms = @import("../core/io_global.zig").milliTimestamp();
    // Smooth fade-out instead of a hard pop: hold full opacity until 2.5s idle,
    // then fade to 0 over ~220ms, then stop rendering. Held fully visible while
    // paused or a picker is open. dvui.alpha() multiplies alpha for everything
    // drawn until the paired alphaSet() restores it (same primitive AnimateWidget
    // uses). During video playback the mpv render callback keeps frames coming so
    // the fade advances; paused → chrome_held so no fade.
    const idle_ms = now_ms - state.app.last_mouse_move_ms;
    const chrome_held = is_paused or open_picker != .none;
    const FADE_START_MS: i64 = 2500;
    const FADE_LEN_MS: i64 = 220;
    if (!chrome_held and idle_ms > FADE_START_MS + FADE_LEN_MS) return; // fully hidden
    const chrome_vis: f32 = if (chrome_held or idle_ms <= FADE_START_MS)
        1.0
    else
        1.0 - @min(@as(f32, 1.0), @as(f32, @floatFromInt(idle_ms - FADE_START_MS)) / @as(f32, @floatFromInt(FADE_LEN_MS)));
    // Self-drive the fade: main.zig only forces continuous repaints while idle
    // < FADE_START_MS, and the mpv frame callback doesn't fire for audio-only /
    // buffering / still-image playback — so without this the overlay would render
    // once at ~full opacity and FREEZE visible, never reaching the hidden early-
    // return above. Requesting a frame through the fade window animates it out.
    if (!chrome_held and idle_ms > FADE_START_MS and idle_ms <= FADE_START_MS + FADE_LEN_MS) {
        dvui.refresh(null, @src(), null);
    }
    const prev_chrome_alpha = dvui.alpha(chrome_vis);
    defer dvui.alphaSet(prev_chrome_alpha);

    // ── Anchor: push the footer to the bottom of the active cell. ──
    var anchor = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 1.0, .expand = .horizontal });
    defer anchor.deinit();

    // ── Scrim: thin slices fading upward so the glass panel melts into the
    // video (the standard streaming-player treatment) instead of ending in a
    // hard border. Approximates a gradient — dvui has no gradient fill.
    {
        const scrim_alphas = [_]u8{ 14, 36, 68, 110 };
        inline for (scrim_alphas, 0..) |sa, si| {
            var g = theme.colors.bg_glass;
            g.a = sa;
            var sl = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = si + 9200,
                .expand = .horizontal,
                .background = true,
                .color_fill = g,
                .min_size_content = .{ .w = 0, .h = 5 },
                .max_size_content = .{ .w = 0, .h = 5 },
            });
            sl.deinit();
        }
    }

    // ── Footer panel: translucent glass (bg_glass, ~63% opaque) — the video
    // stays visible through the chrome; the scrim above keeps the transition
    // soft and the controls legible over bright scenes. ──
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_glass,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    defer panel.deinit();
    control_panel_rect = panel.data().borderRectScale().r;

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

    const toggle_icon = if (is_paused) icons.tvg.lucide.play else icons.tvg.lucide.pause;

    // ═══════════════════════════════════════════════════════════════
    // ROW 1 — Scrubber + chapter pips + hover time-at-cursor
    // ═══════════════════════════════════════════════════════════════
    renderScrubber(active_p, percent_pos, time_pos, duration, now_ms);

    // ═══════════════════════════════════════════════════════════════
    // ROW 2 — Controls: transport | time | volume | pickers | close
    // ═══════════════════════════════════════════════════════════════
    {
        var ctrl_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 36 },
            .max_size_content = .{ .w = 0, .h = 36 },
            .padding = .{ .x = theme.spacing.md, .y = 1, .w = theme.spacing.md, .h = 1 },
        });
        defer ctrl_row.deinit();

        var wd: dvui.WidgetData = undefined;
        const has_playlist = SlowProps.pl_count > 1;

        // ── Previous episode ──
        //
        // Only for a tracked TV episode (state.playing_episode). A movie or a
        // one-off file has no "previous episode", and mpv's playlist-prev is a
        // different thing entirely — that's the button below, and it only appears
        // when there IS an mpv playlist.
        const tv_lib = @import("../services/tv_library.zig");
        const on_episode = tv_lib.playingEpisode();
        if (on_episode) {
            const has_prev = tv_lib.neighborEpisode(-1) != null;
            if (dvui.buttonIcon(@src(), "ep-prev", icons.tvg.lucide.@"chevron-first", .{}, .{}, .{
                .data_out = &wd,
                .color_fill = transparent,
                .color_text = if (has_prev) theme.colors.text_primary else theme.colors.text_tertiary,
                .border = dvui.Rect.all(0),
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .gravity_y = 0.5,
                .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
                .min_size_content = theme.iconSize(.xl),
                .max_size_content = .{ .w = 32, .h = 32 },
            })) {
                if (has_prev) tv_lib.playNeighborEpisode(-1);
            }
            components.tip(@src(), wd, if (has_prev) "Previous episode" else "This is the first episode");
        }

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
                .min_size_content = theme.iconSize(.xl),
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
            .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
            .min_size_content = .{ .w = 30, .h = 30 },
            .max_size_content = .{ .w = 30, .h = 30 },
        })) {
            _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "seek -10");
        }
        components.tip(@src(), wd, "Skip back 10s (\xE2\x86\x90)");

        // Play / Pause — bare icon, no resting fill: it reads as part of the
        // transport row rather than a stamped accent chip. Size (34px vs 30px)
        // still marks it as the primary affordance. The icon must be
        // text_primary, NOT text_on_accent — the latter is the dark ink meant to
        // sit on the bright accent fill, and without that fill it would be
        // near-invisible against the glass panel.
        if (dvui.buttonIcon(@src(), "toggle-pp", toggle_icon, .{}, .{}, .{
            .data_out = &wd,
            .color_fill = transparent,
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .gravity_y = 0.5,
            .padding = .{ .x = 7, .y = 7, .w = 7, .h = 7 },
            .min_size_content = .{ .w = 34, .h = 34 },
            .max_size_content = .{ .w = 34, .h = 34 },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        })) {
            active_p.togglePause();
        }
        components.tip(@src(), wd, "Play/Pause (Space)");

        // Fullscreen toggle. (This button used to seek +10s; seeking forward is
        // still on the right-arrow key, which is where it always was.)
        {
            const is_fs = state.app.fullscreen_player_idx != null;
            if (dvui.buttonIcon(@src(), "ff10", icons.tvg.lucide.@"fast-forward", .{}, .{}, .{
                .data_out = &wd,
                .color_fill = transparent,
                .color_text = if (is_fs) theme.colors.accent else theme.colors.text_primary,
                .border = dvui.Rect.all(0),
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .gravity_y = 0.5,
                .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
                .min_size_content = .{ .w = 30, .h = 30 },
                .max_size_content = .{ .w = 30, .h = 30 },
            })) {
                // Same toggle the 'f' key drives (input.zig) — one fullscreen path,
                // not two. The active-player index is only stored when there IS an
                // active player, per the guard convention.
                if (state.app.fullscreen_player_idx == null) {
                    if (state.app.active_player_idx < state.app.players.items.len) {
                        state.app.fullscreen_player_idx = state.app.active_player_idx;
                    }
                } else {
                    state.app.fullscreen_player_idx = null;
                }
                dvui.refresh(null, @src(), null);
            }
            components.tip(@src(), wd, if (is_fs) "Exit fullscreen (f)" else "Fullscreen (f)");
        }

        if (has_playlist) {
            if (dvui.buttonIcon(@src(), "skip-next", icons.tvg.lucide.@"skip-forward", .{}, .{}, .{
                .data_out = &wd,
                .color_fill = transparent,
                .color_text = if (SlowProps.pl_pos + 1 < SlowProps.pl_count) theme.colors.text_primary else theme.colors.text_tertiary,
                .border = dvui.Rect.all(0),
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .gravity_y = 0.5,
                .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
                .min_size_content = theme.iconSize(.xl),
                .max_size_content = .{ .w = 32, .h = 32 },
            })) {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "playlist-next");
            }
            components.tip(@src(), wd, "Next track");
        }

        // ── Next episode ──
        if (on_episode) {
            const has_next = tv_lib.neighborEpisode(1) != null;
            if (dvui.buttonIcon(@src(), "ep-next", icons.tvg.lucide.@"chevron-last", .{}, .{}, .{
                .data_out = &wd,
                .color_fill = transparent,
                .color_text = if (has_next) theme.colors.text_primary else theme.colors.text_tertiary,
                .border = dvui.Rect.all(0),
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .gravity_y = 0.5,
                .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
                .min_size_content = theme.iconSize(.xl),
                .max_size_content = .{ .w = 32, .h = 32 },
            })) {
                if (has_next) tv_lib.playNeighborEpisode(1);
            }
            // Greyed out rather than hidden when there's nothing next: a button
            // that vanishes mid-show is more confusing than one that's dim.
            components.tip(@src(), wd, if (has_next) "Next episode" else "No next episode yet");
        }

        // ── Status badges — times moved to the scrub row (IINA layout:
        // elapsed left of the seek line, total/remaining right of it). ──
        {
            var time_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.sm, .h = 0 },
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

        // Wheel over the volume group = ±5 volume (the scrubber band already
        // seeks on wheel; the volume slider ignored it).
        for (dvui.events()) |*ev| {
            if (ev.handled or ev.evt != .mouse) continue;
            const me = ev.evt.mouse;
            if (me.floating_win != dvui.subwindowCurrentId()) continue;
            switch (me.action) {
                .wheel_y => |wy| {
                    if (me.p.x >= slider_rect.x and me.p.x <= slider_rect.x + slider_rect.w and
                        me.p.y >= slider_rect.y and me.p.y <= slider_rect.y + slider_rect.h)
                    {
                        _ = c.mpv.mpv_command_string(active_p.mpv_ctx, if (wy > 0) "add volume 5" else "add volume -5");
                        SlowProps.frame_ctr = 7; // refresh cached volume next frame
                        ev.handled = true;
                    }
                },
                else => {},
            }
        }

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
            if (pickerIconChip(@src(), 700, icons.tvg.lucide.ratio, ar_text, ar_active, "Aspect ratio", .aspect)) {
                open_picker = if (open_picker == .aspect) .none else .aspect;
            }
        }

        // Chapters — only when count > 1.
        {
            var chp_buf: [16]u8 = undefined;
            const chp = currentChapterChipText(active_p.mpv_ctx, &chp_buf);
            if (chp.count > 1) {
                if (pickerIconChip(@src(), 701, icons.tvg.lucide.bookmark, chp.text, true, "Chapters", .chapter)) {
                    open_picker = if (open_picker == .chapter) .none else .chapter;
                }
            }
        }

        // Audio.
        {
            var aud_buf: [32]u8 = undefined;
            const aud = currentTrackChipText(active_p.mpv_ctx, "audio", &aud_buf);
            if (pickerIconChip(@src(), 702, icons.tvg.lucide.music, aud.text, aud.active, "Audio track", .audio)) {
                open_picker = if (open_picker == .audio) .none else .audio;
            }
        }

        // Subs.
        {
            var sub_buf: [32]u8 = undefined;
            const sub = currentTrackChipText(active_p.mpv_ctx, "sub", &sub_buf);
            if (pickerIconChip(@src(), 703, icons.tvg.lucide.captions, sub.text, sub.active, "Subtitle track", .sub)) {
                open_picker = if (open_picker == .sub) .none else .sub;
            }
        }

        // Subtitle language.
        {
            const cur_lang = state.app.sub_lang_buf[0..state.app.sub_lang_len];
            const chip = if (cur_lang.len > 0) cur_lang else "eng";
            if (pickerIconChip(@src(), 704, icons.tvg.lucide.globe, chip, cur_lang.len > 0, "Subtitle search language", .lang)) {
                open_picker = if (open_picker == .lang) .none else .lang;
            }
        }

        // Find Subtitles — direct shortcut. Opens the picker AND kicks the
        // keyless search immediately (debounced inside the engine); the keyed
        // opensubtitles.com search joins in only when a key is configured.
        if (pickerIconChip(@src(), 705, icons.tvg.lucide.search, "Subs", false, "Find subtitles online", .none)) {
            state.app.sub_picker_open = true;
            @import("../player/subtitles.zig").searchFromActivePlayer(&state.app.sub_engine);
            if (state.app.opensub_api_key_len > 0) {
                const subs = @import("../services/subtitles.zig");
                if (!subs.is_searching.load(.acquire)) subs.autoSearchFromPlayer(false);
            }
        }

        // Files (torrent multi-file playlist).
        if (active_p.current_torrent_id >= 0) {
            const file_count = c.mpv.torrent_get_file_count(state.torrentSession(), active_p.current_torrent_id);
            if (file_count > 1) {
                var f_buf: [16]u8 = undefined;
                const f_chip = std.fmt.bufPrint(&f_buf, "{d}", .{file_count}) catch "";
                if (pickerIconChip(@src(), 706, icons.tvg.lucide.list, f_chip, true, "Files in torrent", .playlist)) {
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
            .color_text = if (close_hovered_now) theme.colors.danger else theme.colors.text_secondary,
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
            .min_size_content = .{ .w = 0, .h = 18 },
            .padding = .{ .x = theme.spacing.md, .y = 2, .w = theme.spacing.md, .h = 2 },
        });
        defer info_row.deinit();

        // Name + stats were fetched every frame (torrent_get_name +
        // torrent_poll IPC at ~30fps); cache at ~2Hz keyed on the torrent id
        // (a torrent switch invalidates immediately).
        const StatusCache = struct {
            var tid: i32 = -1;
            var last_ms: i64 = 0;
            var name: [64]u8 = std.mem.zeroes([64]u8);
            var name_len: usize = 0;
            var pct: f32 = 0.0;
            var dl_rate: c_int = 0;
            var seeds: c_int = 0;
        };
        if (StatusCache.tid != active_p.current_torrent_id or now_ms - StatusCache.last_ms > 500) {
            StatusCache.tid = active_p.current_torrent_id;
            StatusCache.last_ms = now_ms;
            var t_name: [64]u8 = undefined;
            c.mpv.torrent_get_name(state.torrentSession(), active_p.current_torrent_id, &t_name, 64);
            @memcpy(&StatusCache.name, &t_name);
            StatusCache.name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse t_name.len;
            var pct: f32 = 0.0;
            var dl_rate: c_int = 0;
            var seeds: c_int = 0;
            _ = c.mpv.torrent_poll(state.torrentSession(), active_p.current_torrent_id, active_p.selected_file_idx, null, 0, &pct, &dl_rate, &seeds);
            StatusCache.pct = pct;
            StatusCache.dl_rate = dl_rate;
            StatusCache.seeds = seeds;
        }
        const name_slice = StatusCache.name[0..StatusCache.name_len];
        const pct = StatusCache.pct;
        const seeds = StatusCache.seeds;
        const rate_mb = @as(f32, @floatFromInt(StatusCache.dl_rate)) / 1024.0 / 1024.0;

        // Untrusted torrent metadata, truncated at the 64-byte buffer (possibly
        // mid-codepoint) — validate before dvui (matches grid.zig).
        _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(name_slice)}, .{
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
                c.mpv.torrent_set_download_limit(state.torrentSession(), state.app.download_rate_limit);
            }
        }

        // Stop + delete — two-step confirm (same component as other destructive
        // actions in the app). The playing file's path is captured lazily INSIDE
        // the confirm branch (torrent_poll) rather than every frame — it is only
        // needed at teardown, and torrent_remove() invalidates it, so we grab it
        // just before removing.
        {
            if (components.confirmDangerButton(@src(), "Delete", 201)) {
                const tid = active_p.current_torrent_id;
                var del_path: [512]u8 = undefined;
                var del_pct: f32 = 0;
                var del_rate: c_int = 0;
                var del_peers: c_int = 0;
                const del_status = c.mpv.torrent_poll(state.torrentSession(), tid, active_p.selected_file_idx, &del_path, del_path.len, &del_pct, &del_rate, &del_peers);
                if (del_status >= 1) {
                    const plen = std.mem.indexOfScalar(u8, &del_path, 0) orelse del_path.len;
                    @import("../core/io_global.zig").deleteFileAbsolute(del_path[0..plen]) catch {
                        @import("../core/logs.zig").pushLog("warn", "torrent", "Delete file failed", true);
                    };
                }
                c.mpv.torrent_remove(state.torrentSession(), tid);
                // STABLE-SLOT model: torrent ids are never renumbered on remove,
                // so other handles stay valid — only clear players on this one.
                for (state.app.players.items) |p| {
                    if (p.current_torrent_id == tid) {
                        p.current_torrent_id = -1;
                        p.torrent_is_ready = false;
                        p.has_metadata = false;
                        _ = c.mpv.mpv_command_string(p.mpv_ctx, "stop");
                    }
                }
                state.showToast("Stopped and deleted");
            }
        }
    }

    // ── Floating popovers (rendered last — they're free-positioned) ──
    // Esc dismisses whichever drop-up is open (there is no backdrop to catch it).
    pickers.handleDropUpKeys();
    pickers.renderChapterPickerPopover(active_p);
    pickers.renderAspectPickerPopover(active_p);
    pickers.renderTrackPickerPopover(active_p, "audio", .audio);
    pickers.renderTrackPickerPopover(active_p, "sub", .sub);
    pickers.renderLangPickerPopover();
    pickers.renderPlaylistPickerPopover(active_p);
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
    // Pause mirrors mpv "pause" via the player worker (cached_paused) — no
    // per-frame mpv IPC read.
    const is_paused: bool = p.cached_paused;
    var percent_pos: f64 = 0.0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "percent-pos", c.mpv.MPV_FORMAT_DOUBLE, &percent_pos);
    var time_pos: f64 = 0.0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &time_pos);
    var duration: f64 = 0.0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &duration);
    var volume: f64 = 100.0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "volume", c.mpv.MPV_FORMAT_DOUBLE, &volume);

    // ── Bar panel: bg_surface + 1px top border, ~84px tall (compact) ──
    var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
        .min_size_content = .{ .w = 0, .h = 84 },
        .max_size_content = .{ .w = 0, .h = 84 },
    });
    defer bar.deinit();

    // ── Row 1: scrubber + chapter pips (reused, identical seek behavior) ──
    renderScrubber(p, percent_pos, time_pos, duration, now_ms);

    // ── Row 2: [thumb + title] | [transport] | [time] | [volume] | [queue] ──
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = 48 },
        .max_size_content = .{ .w = 0, .h = 48 },
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

        // Advance now-playing audio cover art (podcast/radio) — idempotent, so
        // the art still appears here even when the player grid isn't on screen.
        p.tickNowPlayingArt();

        // Thumbnail priority: now-playing audio cover, then any mpv-exposed
        // thumbnail, else a music/film glyph.
        if (p.np_art_tex) |np_tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = np_tex } }, .{
                .min_size_content = .{ .w = 30, .h = 30 },
                .max_size_content = .{ .w = 30, .h = 30 },
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
        } else if (p.thumb_texture != null) {
            _ = dvui.image(@src(), .{ .source = .{ .texture = p.thumb_texture.? } }, .{
                .min_size_content = theme.iconSize(.xl),
                .max_size_content = .{ .w = 32, .h = 32 },
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

        // Title + optional subtitle stacked vertically. Prefer the rich
        // now-playing title (podcast episode / station); fall back to the load
        // label (works for any audio-only stream), else a generic label.
        var txt_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 0.5 });
        defer txt_col.deinit();

        const raw_title = if (p.np_title_len > 0)
            p.np_title[0..p.np_title_len]
        else if (p.loading_label_len > 0)
            p.loading_label[0..p.loading_label_len]
        else
            "Now Playing";
        // safeUtf8Buf (not plain safeUtf8): these buffers are mutated by workers,
        // so validating a slice into the live buffer can still let dvui re-read
        // mutated bytes mid-frame. Snapshot a stable copy first.
        var nt_buf: [128]u8 = undefined;
        var title = text.safeUtf8Buf(raw_title, &nt_buf);
        if (title.len > 42) title = text.safeUtf8(title[0..42]); // re-trim to a codepoint boundary (on the copy)
        _ = dvui.label(@src(), "{s}", .{title}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
        });

        // Subtitle (show name / station codec·bitrate·country) — secondary tone,
        // only for now-playing audio, ellipsized to keep the left block bounded.
        if (p.np_subtitle_len > 0) {
            var st_buf: [192]u8 = undefined;
            var sub = text.safeUtf8Buf(p.np_subtitle[0..p.np_subtitle_len], &st_buf);
            if (sub.len > 46) sub = text.safeUtf8(sub[0..46]);
            _ = dvui.label(@src(), "{s}", .{sub}, .{
                .color_text = theme.colors.text_secondary,
                .font = dvui.themeGet().font_body.withSize(11),
                .gravity_y = 0.5,
            });
        }
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
        const toggle_icon = if (is_paused) icons.tvg.lucide.play else icons.tvg.lucide.pause;
        if (dvui.buttonIcon(@src(), "np-pp", toggle_icon, .{}, .{}, .{
            .data_out = &wd,
            .color_fill = theme.colors.accent,
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
            .min_size_content = theme.iconSize(.sm),
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
        if (pickerIconChip(@src(), 720, icons.tvg.lucide.@"list-music", q_label, queue.queue_count > 0, "Queue / playlist", .none)) {
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

    // Tally first — the strip only earns its space when a torrent is actually
    // present. Otherwise it sat at the bottom forever reading "0 Active / 0 Peers".
    //
    // This ran a torrent_poll for EVERY player on EVERY non-player tab, every
    // frame (~30fps). Cache the aggregate at ~2Hz. A cheap per-frame signature
    // over the players' torrent ids (no IPC) forces an immediate refresh when a
    // torrent is added / removed / switched; otherwise we serve the last tally.
    const Cache = struct {
        var last_ms: i64 = 0;
        var sig: u64 = 0;
        var total_dl: f32 = 0.0;
        var total_peers: i32 = 0;
        var total_active: i32 = 0;
        var any_torrent: bool = false;
    };
    const now_ms = @import("../core/io_global.zig").milliTimestamp();
    var sig: u64 = 0;
    for (state.app.players.items) |p| {
        if (p.is_torrent and p.current_torrent_id >= 0) {
            sig = sig *% 31 +% @as(u64, @intCast(p.current_torrent_id)) +% 1;
            sig = sig *% 31 +% @as(u64, @bitCast(@as(i64, p.selected_file_idx)));
        }
    }
    if (Cache.sig != sig or now_ms - Cache.last_ms > 500) {
        Cache.sig = sig;
        Cache.last_ms = now_ms;
        var total_dl: f32 = 0.0;
        var total_peers: i32 = 0;
        var total_active: i32 = 0;
        var any_torrent = false;
        for (state.app.players.items) |p| {
            if (p.is_torrent and p.current_torrent_id >= 0) {
                any_torrent = true;
                var dl_rate: i32 = 0;
                var peers: i32 = 0;
                var pct: f32 = 0;
                _ = c.mpv.torrent_poll(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, null, 0, &pct, &dl_rate, &peers);
                total_dl += @as(f32, @floatFromInt(dl_rate));
                total_peers += peers;
                if (dl_rate > 0) total_active += 1;
            }
        }
        Cache.total_dl = total_dl;
        Cache.total_peers = total_peers;
        Cache.total_active = total_active;
        Cache.any_torrent = any_torrent;
    }
    const total_dl = Cache.total_dl;
    const total_peers = Cache.total_peers;
    const total_active = Cache.total_active;
    const any_torrent = Cache.any_torrent;

    if (!any_torrent) return; // no bottom bar when there's nothing to report

    var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_app,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect{ .x = 0, .y = 1, .w = 0, .h = 0 },
        .padding = .{ .x = theme.spacing.sm, .y = 1, .w = theme.spacing.sm, .h = 1 },
    });
    defer b.deinit();

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

/// One-shot "Resume last played?" banner shown on launch (top-center, below the
/// navbar). Resume reopens the saved link; the per-media seek (player.zig) jumps
/// to the stored position. Armed in main.zig from watch history. Dismisses itself
/// the moment anything is playing — including right after Resume opens a player.
pub fn renderResumePrompt() void {
    if (!state.app.resume_prompt_active) return;
    if (state.app.players.items.len > 0) {
        state.app.resume_prompt_active = false;
        return;
    }

    var anchor = dvui.overlay(@src(), .{ .expand = .both });
    defer anchor.deinit();

    // Fade in like the toast — the banner is the first thing a returning user
    // sees; popping in fully formed read as a glitch.
    var prompt_fade = dvui.animate(@src(), .{ .kind = .alpha, .duration = theme.motion.base, .easing = theme.motion.enter }, .{ .expand = .both });
    defer prompt_fade.deinit();

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.08,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
        .box_shadow = .{
            .color = theme.shadow_soft,
            .offset = .{ .x = 0, .y = 4 },
            .fade = 20,
        },
    });
    defer bar.deinit();

    _ = dvui.icon(@src(), "", icons.tvg.lucide.play, .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.sm),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });

    var lb: [128]u8 = undefined;
    const label = @import("../core/text.zig").safeUtf8Buf(state.app.resume_prompt_label[0..state.app.resume_prompt_label_len], &lb);
    var msg_buf: [200]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Resume \u{201c}{s}\u{201d} \u{b7} {d}%", .{ label, state.app.resume_prompt_pct }) catch label;
    _ = dvui.label(@src(), "{s}", .{msg}, .{
        .color_text = theme.colors.text_primary,
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.md, .h = 0 },
    });

    if (dvui.button(@src(), "Resume", .{}, .{
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.text_on_accent,
        .corner_radius = theme.dims.rad_sm,
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
    })) {
        // loadContent creates a player if none exists on a cold start.
        @import("../services/browser.zig").resumePlayback(state.app.resume_prompt_link[0..state.app.resume_prompt_link_len]);
        state.app.resume_prompt_active = false;
    }

    if (dvui.button(@src(), "\u{2715}", .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = theme.colors.text_tertiary,
        .border = dvui.Rect.all(0),
        .corner_radius = theme.dims.rad_sm,
        .gravity_y = 0.5,
    })) {
        state.app.resume_prompt_active = false;
    }
}

pub fn renderToast() void {
    if (state.app.toast_len == 0) return;
    const now = @import("../core/io_global.zig").milliTimestamp();
    if (now >= state.app.toast_expire) {
        state.app.toast_len = 0;
        return;
    }

    var toast_anchor = dvui.overlay(@src(), .{ .expand = .both });
    defer toast_anchor.deinit();

    // Fade each toast in. id_extra keyed on the monotonic toast_seq so every new
    // toast gets a fresh widget id → firstFrame true → the fade re-triggers
    // (AnimateWidget only auto-starts on the first frame of a given id). Using a
    // counter (not toast_expire) means back-to-back toasts still each fade in.
    var toast_fade = dvui.animate(@src(), .{ .kind = .alpha, .duration = theme.motion.base, .easing = theme.motion.enter }, .{
        .id_extra = @as(usize, @truncate(state.app.toast_seq)),
        .expand = .both,
    });
    defer toast_fade.deinit();

    // Fade OUT over the final motion.base window instead of popping away.
    // Self-drive repaints through the fade (and request the expiry frame) so
    // the exit animates even when nothing else refreshes the UI.
    const remaining_ms = state.app.toast_expire - now;
    const fade_out_ms: i64 = @divTrunc(theme.motion.base, 1000);
    if (remaining_ms <= fade_out_ms) {
        const t: f32 = @as(f32, @floatFromInt(remaining_ms)) / @as(f32, @floatFromInt(fade_out_ms));
        const prev = dvui.alpha(theme.motion.exit(std.math.clamp(t, 0.0, 1.0)));
        defer dvui.alphaSet(prev);
        dvui.refresh(null, @src(), null);
        renderToastBody();
        return;
    }
    // Ask for a frame at the moment the fade-out should begin, so an idle UI
    // still starts the exit on time (timer arms a wakeup that many µs out).
    dvui.timer(toast_anchor.data().id, @intCast(@max(1, (remaining_ms - fade_out_ms) * 1000)));
    renderToastBody();
}

fn renderToastBody() void {

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
            .color = theme.shadow_soft,
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
            .color = theme.shadow_soft,
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

    // SNAPSHOT the mpv reads (500ms TTL + a timer tick): ~10 synchronous
    // property reads per frame — 3 of them allocating string reads — contended
    // with the demux/render threads for the whole time the overlay was open.
    // Live stats still update twice a second, which is what the eye can use.
    const stat_props = [_][2][]const u8{
        .{ "video-codec", "Video" },
        .{ "audio-codec-name", "Audio" },
        .{ "hwdec-current", "HW Dec" },
    };
    const Snap = struct {
        var res: [48]u8 = undefined;
        var res_len: usize = 0;
        var br: [48]u8 = undefined;
        var br_len: usize = 0;
        var drop: [24]u8 = undefined;
        var drop_len: usize = 0;
        var strs: [stat_props.len][64]u8 = undefined;
        var str_lens: [stat_props.len]usize = .{0} ** stat_props.len;
        var last_ms: i64 = 0;
        var last_ctx: usize = 0;
    };
    const now_ms = @import("../core/io_global.zig").milliTimestamp();
    const ctx_key = @intFromPtr(p.mpv_ctx);
    if (now_ms - Snap.last_ms > 500 or Snap.last_ctx != ctx_key) {
        Snap.last_ms = now_ms;
        Snap.last_ctx = ctx_key;

        var w: i64 = 0;
        var h: i64 = 0;
        var fps: f64 = 0;
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "width", c.mpv.MPV_FORMAT_INT64, &w);
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "height", c.mpv.MPV_FORMAT_INT64, &h);
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "estimated-vf-fps", c.mpv.MPV_FORMAT_DOUBLE, &fps);
        Snap.res_len = if (std.fmt.bufPrint(&Snap.res, "{d}×{d} @ {d:.1} fps", .{ w, h, fps })) |sres| sres.len else |_| 0;

        var vbr: f64 = 0;
        var abr: f64 = 0;
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "video-bitrate", c.mpv.MPV_FORMAT_DOUBLE, &vbr);
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "audio-bitrate", c.mpv.MPV_FORMAT_DOUBLE, &abr);
        Snap.br_len = if (std.fmt.bufPrint(&Snap.br, "V: {d} kb/s  A: {d} kb/s", .{
            @as(i64, @intFromFloat(vbr / 1000.0)),
            @as(i64, @intFromFloat(abr / 1000.0)),
        })) |sbr| sbr.len else |_| 0;

        var dropped: i64 = 0;
        _ = c.mpv.mpv_get_property(p.mpv_ctx, "frame-drop-count", c.mpv.MPV_FORMAT_INT64, &dropped);
        Snap.drop_len = if (std.fmt.bufPrint(&Snap.drop, "{d}", .{dropped})) |sdrop| sdrop.len else |_| 0;

        for (stat_props, 0..) |prop, idx| {
            const val_ptr: ?[*:0]u8 = @ptrCast(c.mpv.mpv_get_property_string(p.mpv_ctx, @ptrCast(prop[0].ptr)));
            if (val_ptr) |vp| {
                const span = std.mem.span(vp);
                const n = @min(span.len, Snap.strs[idx].len);
                @memcpy(Snap.strs[idx][0..n], span[0..n]);
                Snap.str_lens[idx] = n;
                c.mpv.mpv_free(vp);
            } else {
                Snap.str_lens[idx] = 0;
            }
        }
    }
    // Tick a frame every 500ms while open so the numbers keep moving even
    // when nothing else repaints (re-arm pattern — 2 frames/s).
    const tick_id = stats_box.data().id;
    if (dvui.timerDoneOrNone(tick_id)) dvui.timer(tick_id, 500_000);

    renderStatRow("Resolution", Snap.res[0..Snap.res_len], 0);
    renderStatRow("Bitrate", Snap.br[0..Snap.br_len], 1);
    renderStatRow("Dropped", Snap.drop[0..Snap.drop_len], 2);
    for (stat_props, 0..) |prop, idx| {
        if (Snap.str_lens[idx] > 0) {
            renderStatRow(prop[1], @import("../core/text.zig").safeUtf8(Snap.strs[idx][0..Snap.str_lens[idx]]), idx + 10);
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
        .color_text = theme.colors.text_secondary,
        .min_size_content = .{ .w = 80, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{value}, .{
        .id_extra = id_extra + 200,
        .color_text = theme.colors.text_primary,
    });
}
