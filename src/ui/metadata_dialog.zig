const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const icons = @import("icons");

const TRANSPARENT: dvui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

pub const FileFixture = struct { name: []const u8, size: u64 };
pub const Fixture = struct { name: []const u8, files: []const FileFixture };
var fixture_for_test: ?Fixture = null;
pub var test_dialog_rect: dvui.Rect = .{};
pub var test_row_rects: [4]dvui.Rect = @splat(.{});
pub var test_row_count: usize = 0;
pub var test_waiting_rect: dvui.Rect = .{};
pub var test_footer_rect: dvui.Rect = .{};
pub fn setFixtureForTest(value: ?Fixture) void {
    if (!@import("builtin").is_test) @compileError("Metadata fixture is test-only");
    fixture_for_test = value;
}
fn fixture() ?Fixture {
    return if (@import("builtin").is_test) fixture_for_test else null;
}
pub fn renderMetadataDialog() void {
    if (state.app.pending_magnet_tid < 0) return;
    const dialog_size = theme.fitWindowSize(.{ .w = 600, .h = 400 }, .{ .w = 260, .h = 180 });

    var open = true;
    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .center_on = dvui.windowRect(),
        .window_avoid = .none,
        .open_flag = &open,
        .resize = .none,
    }, .{
        .min_size_content = dialog_size,
        .max_size_content = dvui.Options.MaxSize.size(dialog_size),
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = theme.dims.rad_lg,
    });
    defer win.deinit();
    win.autoPosition();
    win.autoSize();
    if (@import("builtin").is_test) {
        test_dialog_rect = win.data().rect;
        test_row_count = 0;
    }
    win.dragAreaSet(dvui.windowHeader("Torrent files", "", &open));
    if (!open) {
        c.mpv.torrent_remove(state.torrentSession(), state.app.pending_magnet_tid);
        state.app.pending_magnet_tid = -1;
        return;
    }
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = theme.spacing.md, .y = 6, .w = theme.spacing.md, .h = 6 } });
    defer col.deinit();

    if (!state.app.pending_has_metadata) {
        var waiting = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        _ = dvui.label(@src(), "Fetching Torrent Metadata...", .{}, .{ .expand = .horizontal, .color_text = theme.colors.text_primary, .margin = dvui.Rect.all(theme.spacing.md) });

        if (@import("builtin").is_test) test_waiting_rect = waiting.data().rect;
        waiting.deinit();
        var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 1.0 });
        if (@import("builtin").is_test) test_footer_rect = footer.data().rect;
        defer footer.deinit();
        // Ghost Cancel — text-only danger, no resting fill.
        if (dvui.button(@src(), "Cancel", .{}, .{ .color_fill = TRANSPARENT, .color_text = theme.colors.danger, .padding = theme.dims.pad_sm })) {
            c.mpv.torrent_remove(state.torrentSession(), state.app.pending_magnet_tid);
            state.app.pending_magnet_tid = -1;
        }
        return;
    }

    var t_name: [256]u8 = undefined;
    if (fixture()) |data| {
        @memset(&t_name, 0);
        const copied = @min(data.name.len, t_name.len - 1);
        @memcpy(t_name[0..copied], data.name[0..copied]);
    } else c.mpv.torrent_get_name(state.torrentSession(), state.app.pending_magnet_tid, &t_name, 256);
    const name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse 255;

    _ = dvui.label(@src(), "Pre-Download Filter", .{}, .{ .color_text = theme.colors.text_primary });
    var title = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
    title.addText(@import("../core/text.zig").safeUtf8(t_name[0..name_len]), .{ .color_text = theme.colors.text_secondary });
    title.deinit();

    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .min_size_content = .{ .w = 0, .h = 0 }, .max_size_content = dvui.Options.MaxSize.height(@max(80, dialog_size.h - 180)), .background = true, .color_fill = theme.colors.bg_surface });

    var f_list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = theme.dims.pad_sm });

    const f_count: i32 = if (fixture()) |data| @intCast(@min(data.files.len, std.math.maxInt(i32))) else c.mpv.torrent_get_file_count(state.torrentSession(), state.app.pending_magnet_tid);
    // f_count is untrusted (.torrent metadata). Clamp to the fixed-size
    // pending_files_selection buffer so the index below can never go OOB.
    const shown = @min(f_count, @as(@TypeOf(f_count), @intCast(state.app.pending_files_selection.len)));

    var i: i32 = 0;
    while (i < shown) : (i += 1) {
        var f_name: [256]u8 = undefined;
        if (fixture()) |data| {
            @memset(&f_name, 0);
            const name = data.files[@intCast(i)].name;
            const copied = @min(name.len, f_name.len - 1);
            @memcpy(f_name[0..copied], name[0..copied]);
        } else c.mpv.torrent_get_file_name(state.torrentSession(), state.app.pending_magnet_tid, i, &f_name, 256);
        const f_len = std.mem.indexOfScalar(u8, &f_name, 0) orelse 255;
        const safe_name = @import("../core/text.zig").safeUtf8(f_name[0..f_len]);
        const sz: u64 = if (fixture()) |data| data.files[@intCast(i)].size else @intCast(@max(0, c.mpv.torrent_get_file_size(state.torrentSession(), state.app.pending_magnet_tid, i)));
        const sz_mb = @as(f64, @floatFromInt(sz)) / (1024.0 * 1024.0);

        var f_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = @intCast(i), .expand = .horizontal, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 } });

        if (@import("builtin").is_test) {
            if (test_row_count < test_row_rects.len) {
                test_row_rects[test_row_count] = f_row.data().rect;
                test_row_count += 1;
            }
        }
        const selected = &state.app.pending_files_selection[@as(usize, @intCast(i))];
        _ = dvui.checkbox(@src(), selected, "", .{ .color_fill = if (selected.*) theme.colors.accent else theme.colors.bg_surface, .color_border = theme.colors.border_subtle, .color_text = theme.colors.text_on_accent });

        var f_buf: [300]u8 = undefined;
        if (std.fmt.bufPrintZ(&f_buf, "{s} ({d:.1} MB)", .{ safe_name, sz_mb })) |n| {
            var text = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
            text.addText(n, .{ .color_text = theme.colors.text_primary, .font = theme.mediaTitleFont(safe_name, dvui.themeGet().font_body) });
            text.deinit();
        } else |_| {}

        f_row.deinit();
    }

    f_list.deinit();
    scroll.deinit();

    var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 44 }, .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = 0 } });
    defer footer.deinit();

    // Ghost Cancel — text-only danger.
    if (dvui.button(@src(), "Cancel", .{}, .{ .color_fill = TRANSPARENT, .color_text = theme.colors.danger, .padding = .{ .x = theme.spacing.md, .y = 6, .w = theme.spacing.md, .h = 6 } })) {
        c.mpv.torrent_remove(state.torrentSession(), state.app.pending_magnet_tid);
        state.app.pending_magnet_tid = -1;
    }

    // Primary action — the single accent affordance of the dialog.
    if (dvui.button(@src(), "Start Download", .{}, .{ .color_fill = theme.colors.accent, .color_text = theme.colors.text_on_accent, .padding = .{ .x = theme.spacing.md, .y = 6, .w = theme.spacing.md, .h = 6 }, .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 } })) {
        var fi: i32 = 0;
        const shown_dl = @min(f_count, @as(@TypeOf(f_count), @intCast(state.app.pending_files_selection.len)));
        while (fi < shown_dl) : (fi += 1) {
            if (!state.app.pending_files_selection[@as(usize, @intCast(fi))]) {
                c.mpv.torrent_set_file_priority(state.torrentSession(), state.app.pending_magnet_tid, fi, 0); // Skip
            } else {
                c.mpv.torrent_set_file_priority(state.torrentSession(), state.app.pending_magnet_tid, fi, 4); // Normal
            }
        }

        // Finalize state transfer to the active player
        if (state.app.pending_magnet_player_idx < state.app.players.items.len) {
            const p = state.app.players.items[state.app.pending_magnet_player_idx];
            p.attachTorrent(state.app.pending_magnet_tid);
            p.torrent_is_ready = false;
            p.has_metadata = true;
            p.last_load_time = 0;
            @memcpy(p.source_url[0..state.app.pending_source_url_len], state.app.pending_source_url[0..state.app.pending_source_url_len]);
            p.source_url_len = state.app.pending_source_url_len;
            @memcpy(p.current_url[0..state.app.pending_source_url_len], state.app.pending_source_url[0..state.app.pending_source_url_len]);
            p.current_url_len = state.app.pending_source_url_len;
            p.is_torrent = true;
            p.playback_origin = .torrent;
        } else {
            // Player vanished? Clean up leak.
            c.mpv.torrent_remove(state.torrentSession(), state.app.pending_magnet_tid);
        }

        state.app.pending_magnet_tid = -1; // Closes dialog
    }
}
