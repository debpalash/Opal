//! Floating picker popovers for the in-player control bar.
//!
//! Extracted from footer.zig to keep that file focused on the control-bar
//! layout. These are the dropdown/popover selectors opened from the bottom
//! toolbar — chapter, aspect ratio, audio track, subtitle track, subtitle
//! language, and torrent-file playlist. Each is gated on the shared
//! `footer.open_picker` state (of type `footer.PickerKind`) which is
//! read/written across footer.zig and input.zig; that state deliberately
//! still lives in footer.zig — this module only references it, never
//! duplicates it. Only one picker is open at a time.
//!
//! footer.zig calls these at the end of its overlay render, in order.

const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const player = @import("../player/player.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const footer = @import("footer.zig");
const dropup = @import("dropup_pure.zig");

// ══════════════════════════════════════════════════════════
// Drop-ups
//
// These were MODAL dialogs: a dimming backdrop over the video, a title bar, a
// close button. That is a lot of ceremony for "switch the audio track", and the
// scrim dims the very thing you are adjusting.
//
// They are now panels anchored directly ABOVE the chip that opened them, with NO
// backdrop — the video stays fully visible behind. The placement rules
// (right-align to the chip, grow upwards, clamp into the window, flip downwards
// if there is no room above) are pure and unit-tested in dropup_pure.zig; this
// file only executes them.
// ══════════════════════════════════════════════════════════

/// Per-picker rect, kept across frames because dvui's FloatingWindowWidget wants a
/// mutable pointer. Recomputed from the chip anchor every frame, so a panel tracks
/// its chip if the control bar moves (e.g. entering fullscreen).
var dropup_rects: [8]dvui.Rect = [_]dvui.Rect{.{}} ** 8;

/// Open a backdrop-less panel anchored above `kind`'s chip. Caller must deinit.
fn beginDropUp(
    src: std.builtin.SourceLocation,
    kind: footer.PickerKind,
    w: f32,
    h: f32,
    open: *bool,
) *dvui.FloatingWindowWidget {
    const a = footer.anchorFor(kind);
    const win = dvui.windowRect();

    const pt = dropup.place(
        .{ .x = a.x, .y = a.y, .w = a.w, .h = a.h },
        .{ .x = win.x, .y = win.y, .w = win.w, .h = win.h },
        .{ .w = w, .h = h },
        dropup.GAP,
    );

    const i: usize = @intCast(@max(0, @intFromEnum(kind)));
    dropup_rects[i] = .{ .x = pt.x, .y = pt.y, .w = w, .h = h };

    return dvui.floatingWindow(src, .{
        .modal = false, // no backdrop — the video stays visible and undimmed
        .rect = &dropup_rects[i],
        .open_flag = open,
        .resize = .none,
    }, .{
        .min_size_content = .{ .w = w, .h = h },
        .max_size_content = .{ .w = w, .h = h },
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = dvui.Rect.all(theme.spacing.xs),
    });
}

/// Small caption at the top of a drop-up. Replaces the modal's title bar: it names
/// the panel without giving it window chrome.
fn dropUpTitle(src: std.builtin.SourceLocation, text: []const u8) void {
    _ = dvui.label(src, "{s}", .{text}, .{
        .color_text = theme.colors.text_tertiary,
        .padding = .{ .x = theme.spacing.sm, .y = 2, .w = theme.spacing.sm, .h = 4 },
    });
}

/// Esc closes whichever drop-up is open. With no backdrop there is nothing to
/// swallow a stray click, so Esc and re-clicking the chip are the dismissal paths.
pub fn handleDropUpKeys() void {
    if (footer.open_picker == .none) return;
    for (dvui.events()) |*e| {
        if (e.evt != .key) continue;
        if (e.evt.key.action == .down and e.evt.key.code == .escape) {
            footer.open_picker = .none;
        }
    }
}

pub fn renderChapterPickerPopover(active_p: *player.MediaPlayer) void {
    if (footer.open_picker != .chapter) return;
    var ch_count: i64 = 0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "chapter-list/count", c.mpv.MPV_FORMAT_INT64, &ch_count);
    if (ch_count <= 0) {
        footer.open_picker = .none;
        return;
    }

    var current_ch: i64 = -1;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "chapter", c.mpv.MPV_FORMAT_INT64, &current_ch);

    var open: bool = true;
    var fw = beginDropUp(@src(), .chapter, 360, 302, &open);
    defer fw.deinit();
    dropUpTitle(@src(), "Chapters");

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
            .color_text = if (is_current) theme.colors.accent else theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        })) {
            var cmd_buf: [32]u8 = undefined;
            if (std.fmt.bufPrintZ(&cmd_buf, "set chapter {d}", .{i})) |cmd| {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, cmd.ptr);
            } else |_| {}
            footer.open_picker = .none;
        }
    }

    if (!open) footer.open_picker = .none;
}

pub fn renderAspectPickerPopover(active_p: *player.MediaPlayer) void {
    if (footer.open_picker != .aspect) return;
    var open: bool = true;
    var fw = beginDropUp(@src(), .aspect, 200, 182, &open);
    defer fw.deinit();
    dropUpTitle(@src(), "Aspect ratio");

    const cur = footer.currentAspectChipText(active_p.mpv_ctx);
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
            .color_text = if (is_cur) theme.colors.accent else theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        })) {
            var cmd: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&cmd, "set video-aspect-override \"{s}\"", .{m})) |cstr| {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, cstr.ptr);
            } else |_| {}
            footer.open_picker = .none;
        }
    }
    if (!open) footer.open_picker = .none;
}

pub fn renderTrackPickerPopover(active_p: *player.MediaPlayer, track_type: []const u8, kind: footer.PickerKind) void {
    if (footer.open_picker != kind) return;
    var open: bool = true;
    const title = if (kind == .audio) "Audio Track" else "Subtitles";
    var fw = beginDropUp(@src(), kind, 320, 262, &open);
    defer fw.deinit();
    dropUpTitle(@src(), title);

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        // Transparent — show the popup's themed bg, not dvui's default white fill.
        .background = false,
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
    });
    defer scroll.deinit();

    var count: i64 = 0;
    _ = c.mpv.mpv_get_property(active_p.mpv_ctx, "track-list/count", c.mpv.MPV_FORMAT_INT64, &count);

    var rows_rendered: usize = 0;
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

        rows_rendered += 1;
        if (dvui.button(@src(), @import("../core/text.zig").safeUtf8(row_name), .{}, .{
            .id_extra = @as(usize, @intCast(i)),
            .expand = .horizontal,
            .color_fill = if (is_selected) theme.colors.bg_elevated else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (is_selected) theme.colors.accent else theme.colors.text_primary,
            // Transparent fills kill dvui's derived hover — set it explicitly.
            .color_fill_hover = theme.colors.bg_hover,
            .color_fill_press = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        })) {
            var cmd: [64]u8 = undefined;
            const prop = if (kind == .audio) "aid" else "sid";
            if (std.fmt.bufPrintZ(&cmd, "set {s} {d}", .{ prop, t_id })) |cstr| {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, cstr.ptr);
            } else |_| {}
            footer.open_picker = .none;
        }
    }

    if (rows_rendered == 0) {
        _ = dvui.label(@src(), "{s}", .{if (kind == .audio) "No alternate audio tracks in this file." else "No subtitle tracks yet."}, .{
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = theme.spacing.xs },
        });
    }

    // Bridge to the online finder — subtitles rarely end at the embedded list.
    if (kind == .sub) {
        components.divider();
        if (dvui.button(@src(), "Find subtitles online…", .{}, .{
            .id_extra = 990,
            .expand = .horizontal,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.accent,
            .color_fill_hover = theme.colors.bg_hover,
            .color_fill_press = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
        })) {
            footer.open_picker = .none;
            state.app.sub_picker_open = true;
            @import("../player/subtitles.zig").searchFromActivePlayer(&state.app.sub_engine);
            if (state.app.opensub_api_key_len > 0) {
                const subs = @import("../services/subtitles.zig");
                if (!subs.is_searching.load(.acquire)) subs.autoSearchFromPlayer(false);
            }
        }
    }

    if (!open) footer.open_picker = .none;
}

pub fn renderLangPickerPopover() void {
    if (footer.open_picker != .lang) return;
    var open: bool = true;
    var fw = beginDropUp(@src(), .lang, 240, 342, &open);
    defer fw.deinit();
    dropUpTitle(@src(), "Subtitle language");

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        // Transparent — show the popup's themed bg, not dvui's default white fill.
        .background = false,
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
    });
    defer scroll.deinit();

    _ = dvui.label(@src(), "Searches re-run in the language you pick.", .{}, .{
        .color_text = theme.colors.text_tertiary,
        .margin = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.sm, .h = theme.spacing.xs },
    });

    const langs = [_][]const u8{ "eng", "spa", "fre", "ger", "por", "ita", "dut", "pol", "rus", "chi", "jpn", "kor", "ara", "hin", "tur" };
    const names = [_][]const u8{ "English", "Spanish", "French", "German", "Portuguese", "Italian", "Dutch", "Polish", "Russian", "Chinese", "Japanese", "Korean", "Arabic", "Hindi", "Turkish" };
    const current = state.app.sub_lang_buf[0..state.app.sub_lang_len];

    for (langs, 0..) |l, k| {
        const is_cur = std.mem.eql(u8, current, l);
        if (dvui.button(@src(), names[k], .{}, .{
            .id_extra = k,
            .expand = .horizontal,
            .color_fill = if (is_cur) theme.colors.bg_elevated else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (is_cur) theme.colors.accent else theme.colors.text_primary,
            // Transparent fills kill dvui's derived hover — set it explicitly.
            .color_fill_hover = theme.colors.bg_hover,
            .color_fill_press = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        })) {
            @memcpy(state.app.sub_lang_buf[0..l.len], l);
            state.app.sub_lang_len = l.len;
            state.markConfigDirty();
            // Language changed — re-run the current subtitle search with it.
            @import("../player/subtitles.zig").refire(&state.app.sub_engine);
            footer.open_picker = .none;
        }
    }
    if (!open) footer.open_picker = .none;
}

pub fn renderPlaylistPickerPopover(active_p: *player.MediaPlayer) void {
    if (footer.open_picker != .playlist) return;
    if (active_p.current_torrent_id < 0) {
        footer.open_picker = .none;
        return;
    }
    const file_count = c.mpv.torrent_get_file_count(state.torrentSession(), active_p.current_torrent_id);
    if (file_count <= 1) {
        footer.open_picker = .none;
        return;
    }

    var open: bool = true;
    var fw = beginDropUp(@src(), .playlist, 460, 342, &open);
    defer fw.deinit();
    dropUpTitle(@src(), "Files");

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
        c.mpv.torrent_get_file_name(state.torrentSession(), active_p.current_torrent_id, @intCast(i), &name_buf, 256);
        const size = c.mpv.torrent_get_file_size(state.torrentSession(), active_p.current_torrent_id, @intCast(i));
        const size_mb = @as(f64, @floatFromInt(size)) / 1024.0 / 1024.0;
        var lbl_buf: [320]u8 = undefined;
        const label = std.fmt.bufPrintZ(&lbl_buf, "{s}  ({d:.1} MB)", .{ std.mem.sliceTo(&name_buf, 0), size_mb }) catch "File";
        const is_sel = active_p.selected_file_idx == @as(i32, @intCast(i));
        if (dvui.button(@src(), label, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_fill = if (is_sel) theme.colors.bg_elevated else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = if (is_sel) theme.colors.accent else theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        })) {
            if (active_p.selected_file_idx != @as(i32, @intCast(i))) {
                _ = c.mpv.mpv_command_string(active_p.mpv_ctx, "stop");
                const old_idx = active_p.selected_file_idx;
                if (old_idx >= 0 and old_idx < file_count) {
                    c.mpv.torrent_set_file_priority(state.torrentSession(), active_p.current_torrent_id, old_idx, 0);
                }
                active_p.selected_file_idx = @as(i32, @intCast(i));
                c.mpv.torrent_set_file_priority(state.torrentSession(), active_p.current_torrent_id, @intCast(i), 4);
                active_p.torrent_is_ready = false;
            }
            footer.open_picker = .none;
        }
    }
    if (!open) footer.open_picker = .none;
}
