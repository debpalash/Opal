//! Explicit offline native media layout fixtures. No profile/provider loading.
const std = @import("std");
const dvui = @import("dvui");
const capture = @import("native_capture.zig");
const state = @import("../core/state.zig");
const allocator = @import("../core/alloc.zig").allocator;
const c = @import("../core/c.zig").mpv;
const player = @import("../player/player.zig");
const footer = @import("footer.zig");
const temp = @import("../core/secure_temp.zig");
const clock = @import("../core/io_global.zig");
var workspace: ?temp.Workspace = null;
var audio_path: [1024]u8 = undefined;
const theme = @import("theme.zig");
var preview_test: @import("media_preview.zig").Player = .{};
var preview_frame: usize = 0;
var preview_initializations: usize = 0;
fn previewSetup() !void {
    preview_frame = 0;
    preview_initializations = @import("media_preview.zig").initializationCountForTest();
}
fn previewDraw() !void {
    if (preview_frame == 0 or preview_frame == 3) try std.testing.expect(preview_test.start("assets/media/browse.mp4", ""));
    _ = preview_test.draw(480, 270);
    if (preview_frame == 7) {
        const deadline = clock.monotonicMilliTimestamp() + 2000;
        while (!preview_test.ready and !preview_test.failed and clock.monotonicMilliTimestamp() < deadline) {
            clock.sleep(10 * std.time.ns_per_ms);
            _ = preview_test.draw(480, 270);
        }
        try std.testing.expectEqual(@as(usize, 1), @import("media_preview.zig").initializationCountForTest() - preview_initializations);
        try std.testing.expect(preview_test.ready and !preview_test.failed);
    }
    clock.sleep(33 * std.time.ns_per_ms);
    preview_frame += 1;
}
fn previewCleanup() void {
    preview_test.deinit();
}
test "Native media offline SDL fixture: wallpaper preview reuses its decoder across clips" {
    const workers = @import("../core/workers.zig");
    workers.init();
    defer {
        workers.beginShutdownAndDrain(0);
        workers.finishShutdown();
    }
    try capture.capture(640, 400, "wallpaper-preview-reuse", previewSetup, previewDraw, previewCleanup);
}
var fixture_player: ?*player.MediaPlayer = null;
var draw_count: usize = 0;
var mode: enum { dock, player, more, playlist, torrent, youtube } = .dock;

fn field(buffer: []u8, len: *usize, value: []const u8) void {
    len.* = @min(buffer.len, value.len);
    @memcpy(buffer[0..len.*], value[0..len.*]);
}

fn setup() !void {
    draw_count = 0;
    const handle = c.mpv_create() orelse return error.MpvUnavailable;
    errdefer c.mpv_terminate_destroy(handle);
    for ([_][2][*:0]const u8{ .{ "config", "no" }, .{ "load-scripts", "no" }, .{ "vo", "null" }, .{ "ao", "null" }, .{ "terminal", "no" }, .{ "idle", "yes" } }) |option| {
        if (c.mpv_set_option_string(handle, option[0], option[1]) < 0) return error.MpvOption;
    }
    if (c.mpv_initialize(handle) < 0) return error.MpvInitialize;
    workspace = try temp.Workspace.create("media-layout");
    var wav: [32044]u8 = @splat(0);
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 32036, .little);
    @memcpy(wav[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 1, .little);
    std.mem.writeInt(u32, wav[24..28], 8000, .little);
    std.mem.writeInt(u32, wav[28..32], 16000, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 32000, .little);
    const path = try workspace.?.writeFile("offline-audio.wav", &wav, &audio_path);
    var flag: c_int = 1;
    try std.testing.expect(c.mpv_set_property(handle, "pause", c.MPV_FORMAT_FLAG, &flag) >= 0);
    try std.testing.expect(c.mpv_set_property(handle, "mute", c.MPV_FORMAT_FLAG, &flag) >= 0);
    try std.testing.expect(player.loadDetached(handle, .{ .url = path, .media_title = "Offline audio fixture" }));
    const deadline = clock.milliTimestamp() + 2000;
    var loaded = false;
    while (clock.milliTimestamp() < deadline) {
        const event = c.mpv_wait_event(handle, 0.01);
        if (event.*.event_id == c.MPV_EVENT_FILE_LOADED) {
            loaded = true;
            break;
        }
    }
    try std.testing.expect(loaded);
    var duration: f64 = 0;
    try std.testing.expect(c.mpv_get_property(handle, "duration", c.MPV_FORMAT_DOUBLE, &duration) >= 0);
    try std.testing.expectApproxEqAbs(@as(f64, 2), duration, 0.1);
    for ([_][*:0]const u8{ "pause", "mute" }) |property| {
        flag = 0;
        try std.testing.expect(c.mpv_get_property(handle, property, c.MPV_FORMAT_FLAG, &flag) >= 0);
        try std.testing.expectEqual(@as(c_int, 1), flag);
    }
    try std.testing.expect(c.mpv_command_string(handle, "seek 0.5 absolute+exact") >= 0);
    var position: f64 = 0;
    const seek_deadline = clock.milliTimestamp() + 1000;
    while (clock.milliTimestamp() < seek_deadline) {
        _ = c.mpv_wait_event(handle, 0.01);
        _ = c.mpv_get_property(handle, "time-pos", c.MPV_FORMAT_DOUBLE, &position);
        if (position >= 0.4 and position <= 0.7) break;
    }
    try std.testing.expect(position >= 0.4 and position <= 0.7);
    for (0..2) |_| try std.testing.expect(player.loadDetached(handle, .{ .url = path, .mode = .append, .media_title = "Offline queued audio" }));
    var count: i64 = 0;
    const append_deadline = clock.milliTimestamp() + 1000;
    while (clock.milliTimestamp() < append_deadline) {
        try std.testing.expect(c.mpv_get_property(handle, "playlist-count", c.MPV_FORMAT_INT64, &count) >= 0);
        if (count == 3) break;
        _ = c.mpv_wait_event(handle, 0.01);
    }
    try std.testing.expectEqual(@as(i64, 3), count);
    var playlist: c.mpv_node = undefined;
    try std.testing.expect(c.mpv_get_property(handle, "playlist", c.MPV_FORMAT_NODE, &playlist) >= 0);
    var target_id: i64 = -1;
    const target = playlist.u.list.*.values[1].u.list.*;
    for (0..@intCast(target.num)) |i| {
        if (std.mem.eql(u8, std.mem.span(target.keys[i]), "id")) target_id = target.values[i].u.int64;
    }
    c.mpv_free_node_contents(&playlist);
    try std.testing.expect(target_id >= 0);
    try std.testing.expect(c.mpv_command_string(handle, "playlist-move 1 0") >= 0);
    try std.testing.expect(@import("pickers.zig").playPlaylistEntry(handle, target_id));
    var selected: i64 = -1;
    try std.testing.expect(c.mpv_get_property(handle, "playlist-pos", c.MPV_FORMAT_INT64, &selected) >= 0);
    try std.testing.expectEqual(@as(i64, 0), selected);
    try std.testing.expect(!@import("pickers.zig").playPlaylistEntry(handle, std.math.maxInt(i64)));
    // Playlist selection loads asynchronously; titlebar checks require the
    // selected track's actual FILE_LOADED event rather than an interim title.
    if (mode == .torrent) {
        const selection_deadline = clock.milliTimestamp() + 2000;
        var selection_loaded = false;
        while (clock.milliTimestamp() < selection_deadline) {
            const event = c.mpv_wait_event(handle, 0.01);
            if (event.*.event_id == c.MPV_EVENT_FILE_LOADED) {
                selection_loaded = true;
                break;
            }
        }
        try std.testing.expect(selection_loaded);
    }
    const p = try allocator.create(player.MediaPlayer);
    errdefer allocator.destroy(p);
    @memset(std.mem.asBytes(p), 0);
    p.mpv_ctx = handle;
    p.provider = .mpv;
    p.current_torrent_id = if (mode == .torrent) 42 else -1;
    if (mode == .torrent) footer.setTorrentFixtureForTest("An exceptionally long transfer filename — Complete.Series.S01E01.2160p.REMUX.Multi.Language.日本語.mkv");
    p.has_metadata = true;
    p.cached_vid_no = true;
    p.cached_paused = true;
    p.cached_duration = 7265;
    p.last_seen_pos = 3651;
    p.cached_volume = 75;
    p.cached_speed = 1;
    p.cached_playlist_count = 3;
    p.cached_playlist_pos = 0;
    field(&p.current_url, &p.current_url_len, if (mode == .youtube) "https://www.youtube.com/watch?v=jNQXAC9IVRw" else path);
    if (mode == .torrent) {
        try std.testing.expect(state.torrentSession() == null);
        p.current_torrent_id = -1;
        var baseline: [256]u8 = undefined;
        const baseline_len = p.getMediaTitle(&baseline);
        try std.testing.expect(baseline_len > 0);
        p.current_torrent_id = 42;
        var null_session_title: [256]u8 = undefined;
        const title_len = p.getMediaTitle(&null_session_title);
        try std.testing.expectEqualSlices(u8, baseline[0..baseline_len], null_session_title[0..title_len]);
        var empty_name: [256]u8 = @splat(0);
        c.torrent_get_name(null, 42, &empty_name, empty_name.len);
        try std.testing.expectEqual(@as(u8, 0), empty_name[0]);
        try std.testing.expectEqual(@as(c_int, 0), c.torrent_get_file_count(null, 42));
    }

    field(&p.np_title, &p.np_title_len, "An exceptionally long audiobook episode title with international text 日本語");
    field(&p.np_subtitle, &p.np_subtitle_len, "A very long publisher and series subtitle that must stay clear of transport controls");
    state.app.ui_scale = 1;
    state.app.active_player_idx = 0;
    state.app.show_cell_overlay = true;
    state.app.router.navigate(if (mode == .dock) .home else .player);
    try state.app.players.append(allocator, p);
    fixture_player = p;
    footer.closePickers();
}

fn cleanup() void {
    footer.closePickers();
    footer.setTorrentFixtureForTest(null);
    if (fixture_player) |p| {
        c.mpv_terminate_destroy(p.mpv_ctx);
        allocator.destroy(p);
    }
    fixture_player = null;
    if (workspace) |*w| w.cleanup();
    workspace = null;
    state.app.players.clearRetainingCapacity();
    state.app.players.deinit(allocator);
    state.app.players = .empty;
}

fn draw() !void {
    draw_count += 1;
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_app) });
    defer panel.deinit();
    _ = dvui.label(@src(), "{s}", .{if (mode == .torrent) "Synthetic cached transfer UI fixture — no torrent session" else "Offline media layout fixture"}, .{ .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary), .padding = dvui.Rect.all(16) });
    var space = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    if (mode != .dock) {
        if (mode == .more or mode == .torrent or mode == .youtube) footer.open_picker = .more;
        if (mode == .playlist) footer.open_picker = .playlist;
        footer.renderLiquidGlassOverlay();
    }
    space.deinit();
    if (mode == .dock) footer.renderGlobalBottomTray();
    const layout = footer.mediaLayoutForTest();
    if (mode == .dock and draw_count >= 8) {
        try std.testing.expect(layout.dock_close.w > 0);
        try std.testing.expect(layout.dock_close.x >= layout.dock_play.x + layout.dock_play.w);
        try std.testing.expect(layout.dock_close.y + layout.dock_close.h <= dvui.windowRectPixels().h + 1);
        try std.testing.expect(layout.dock_close.x + layout.dock_close.w <= dvui.windowRectPixels().w + 1);
    }
    if ((mode == .player or mode == .torrent) and draw_count >= 8) {
        const rect = layout.player_close;
        try std.testing.expect(rect.w > 0 and rect.h > 0);
        try std.testing.expect(rect.x + rect.w <= dvui.windowRectPixels().w + 1);
        try std.testing.expect(rect.y + rect.h <= dvui.windowRectPixels().h + 1);
    }
    if (mode == .torrent and draw_count >= 8) {
        const rows = layout.torrent;
        for (rows) |rect| {
            try std.testing.expect(rect.w > 0 and rect.h > 0);
            try std.testing.expect(rect.x + rect.w <= dvui.windowRectPixels().w + 1);
            try std.testing.expect(rect.y + rect.h <= dvui.windowRectPixels().h + 1);
        }
        for (rows[1..], rows[0..3]) |current, previous| try std.testing.expect(current.y >= previous.y + previous.h - 1);
    }
    if (mode == .youtube and draw_count >= 8) {
        try std.testing.expect(layout.youtube_quality.w > 0 and layout.youtube_quality.h > 0);
        try std.testing.expect(layout.youtube_quality.x + layout.youtube_quality.w <= dvui.windowRectPixels().w + 1);
    }
    if (mode == .more) {
        try std.testing.expect(layout.menu_count > 3);
        for (layout.menu[1..layout.menu_count], layout.menu[0 .. layout.menu_count - 1]) |current, previous| {
            try std.testing.expect(current.y >= previous.y + previous.h - 1);
        }
    }
}

test "Native media offline SDL fixture" {
    if (clock.getenv("OPAL_README_CAPTURE") != null) {
        try captureReadme();
        return;
    }
    for ([_][2]u32{ .{ 1360, 850 }, .{ 640, 800 } }) |size| {
        for ([_]@TypeOf(mode){ .dock, .player, .more, .playlist, .torrent, .youtube }) |view| {
            if (clock.getenv("OPAL_MEDIA_CASE")) |only| {
                var cases = std.mem.splitScalar(u8, only, ',');
                var selected = false;
                while (cases.next()) |name| if (std.mem.eql(u8, name, @tagName(view))) {
                    selected = true;
                    break;
                };
                if (!selected) continue;
            }
            mode = view;
            try capture.capture(size[0], size[1], @tagName(view), setup, draw, cleanup);
        }
    }
}

// Opt-in documentation captures use the production shell, video surface and
// controls with a paused, openly licensed film frame. No provider requests.
var readme_bunny = false;
fn setupReadme() !void {
    mode = .player;
    try setup();
    const p = fixture_player.?;
    const title: [:0]const u8 = if (readme_bunny) "Big Buck Bunny" else "Sintel";
    _ = c.mpv_set_property_string(p.mpv_ctx, "force-media-title", title);
    field(&p.np_title, &p.np_title_len, title);
    field(&p.np_subtitle, &p.np_subtitle_len, "Blender Foundation · CC BY 3.0");
    p.cached_vid_no = false;
    p.cached_playlist_count = 1;
    p.cached_duration = if (readme_bunny) 596 else 52;
    p.last_seen_pos = if (readme_bunny) 60 else 30;
    theme.active_preset = .midnight;
    state.app.page_shell_enabled = true;
    state.app.last_mouse_move_ms = clock.milliTimestamp();
}
fn drawReadme() !void {
    if (fixture_player) |p| {
        if (p.texture == null) {
            const source = if (readme_bunny) "assets/readme/sources/bunny-frame.jpg" else "assets/readme/sources/sintel-frame.jpg";
            const bytes = try clock.cwdReadFileAlloc(source, allocator, 4 * 1024 * 1024);
            defer allocator.free(bytes);
            const frame = @import("../core/image_decode.zig").browserFrame(bytes) orelse return error.ReadmeFrameDecode;
            defer frame.deinit();
            p.texture = try dvui.Texture.fromImageSource(.{ .pixels = .{ .rgba = frame.pixels[0 .. @as(usize, @intCast(frame.width)) * @as(usize, @intCast(frame.height)) * 4], .width = @intCast(frame.width), .height = @intCast(frame.height), .interpolation = .linear } });
        }
    }
    @import("components.zig").beginFrame();
    try @import("shell.zig").render();
}
fn cleanupReadme() void {
    if (fixture_player) |p| if (p.texture) |texture| dvui.textureDestroyLater(texture);
    cleanup();
}
fn setupReadmeConnections() !void {
    theme.active_preset = .midnight;
    state.app.page_shell_enabled = true;
    state.app.ui_scale = 1;
    state.app.router.current = .connect;
}
fn captureReadme() !void {
    const workers = @import("../core/workers.zig");
    workers.init();
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    for ([_]bool{ false, true }) |bunny| {
        readme_bunny = bunny;
        try capture.capture(1400, 900, if (bunny) "bunny-player" else "sintel-player", setupReadme, drawReadme, cleanupReadme);
    }
    try capture.capture(1400, 900, "connections", setupReadmeConnections, drawReadme, null);
}
