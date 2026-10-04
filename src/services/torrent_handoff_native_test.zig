//! Offline regression for worker-to-player metadata/GPU ownership.
const std = @import("std");
const dvui = @import("dvui");
const alloc = @import("../core/alloc.zig").allocator;
const state = @import("../core/state.zig");
const MediaPlayer = @import("../player/player.zig").MediaPlayer;
var fixture: *MediaPlayer = undefined;
var ran = false;
fn setup() !void {
    fixture = try alloc.create(MediaPlayer);
    // Only loading metadata fields are accessed; no mpv calls or media loads.
    @memset(std.mem.asBytes(fixture), 0);
    ran = false;
}
fn consume() void {
    state.consumePendingPlay(fixture);
}
test "Native torrent handoff worker consumes real GPU poster" {
    @import("../core/workers.zig").init();
    defer @import("../core/workers.zig").markQuitting();
    const io = @import("../core/io_global.zig");
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .allocator = alloc, .size = .{ .w = 320, .h = 240 }, .vsync = false, .title = "Offline torrent handoff regression", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    @import("../ui/theme.zig").markUiThread();
    try setup();
    defer alloc.destroy(fixture);
    try window.begin(1);
    const pixel = [_]dvui.Color.PMA{.{ .r = 255, .g = 64, .b = 32, .a = 255 }};
    fixture.loading_poster_tex = try dvui.textureCreate(&pixel, 1, 1, .linear, .rgba_32);
    state.drainPendingPlay();
    try state.app.players.append(alloc, fixture);
    defer {
        state.app.players.clearRetainingCapacity();
        state.app.players.deinit(alloc);
        state.app.players = .empty;
    }
    _ = try window.end(.{});
    state.stashPendingPlayFull("Offline episode", "https://fixture.invalid/poster.jpg", "Owned metadata", .tv, "2026", 8, "S01E02");
    const worker = try std.Thread.spawn(.{}, consume, .{});
    worker.join();
    try std.testing.expect(fixture.loading_poster_tex != null);
    try window.begin(2);
    state.drainPendingPlay();
    _ = try window.end(.{});
    try std.testing.expectEqualStrings("Offline episode", fixture.loading_title[0..fixture.loading_title_len]);
    try std.testing.expect(fixture.loading_poster_tex == null);
    try std.testing.expectEqualStrings("https://fixture.invalid/poster.jpg", fixture.loading_art[0..fixture.loading_art_len]);
    try std.testing.expectEqualStrings("S01E02", fixture.loading_extra[0..fixture.loading_extra_len]);
    // A replacement load and a reused allocation must discard stale metadata.
    state.stashPendingPlay("Stale serial", "", "", false);
    const stale_serial = try std.Thread.spawn(.{}, consume, .{});
    stale_serial.join();
    fixture.load_serial += 1;
    try window.begin(3);
    state.drainPendingPlay();
    _ = try window.end(.{});
    try std.testing.expectEqualStrings("Offline episode", fixture.loading_title[0..fixture.loading_title_len]);
    state.stashPendingPlay("Reused allocation", "", "", false);
    const stale_lifetime = try std.Thread.spawn(.{}, consume, .{});
    stale_lifetime.join();
    fixture.lifetime_id += 1;
    try window.begin(4);
    state.drainPendingPlay();
    _ = try window.end(.{});
    try std.testing.expectEqualStrings("Offline episode", fixture.loading_title[0..fixture.loading_title_len]);
    state.clearPendingPlay();
}

fn admitTorrents() void {
    const search = @import("search.zig");
    state.stashPendingPlayFull("First episode", "https://fixture.invalid/first.jpg", "First synopsis", .tv, "2025", 7, "S01E01");
    state.setPendingPlayCatalogId(123);
    search.loadTorrentToPlayer("magnet:?xt=urn:btih:fixture-first");
    state.stashPendingPlayFull("Second episode", "https://fixture.invalid/second.jpg", "Second synopsis", .tv, "2026", 8, "S01E02");
    search.addTorrentFileToEngine("/fixture/offline-second.torrent");
}
test "Native torrent handoff worker admission never acquires player" {
    @import("../core/workers.zig").init();
    defer @import("../core/workers.zig").markQuitting();
    const search = @import("search.zig");
    try std.testing.expectEqual(@as(usize, 0), state.app.players.items.len);
    const worker = try std.Thread.spawn(.{}, admitTorrents, .{});
    worker.join();
    try std.testing.expectEqual(@as(usize, 0), state.app.players.items.len);
    const first = search.popPendingTorrentForTest().?;
    const second = search.popPendingTorrentForTest().?;
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:fixture-first", first.entry.slice());
    try std.testing.expectEqualStrings("First episode", first.metadata.title[0..first.metadata.title_len]);
    try std.testing.expectEqual(@as(i32, 123), first.metadata.tmdb_id);
    try std.testing.expectEqual(@as(i32, 0), second.metadata.tmdb_id);
    try std.testing.expectEqualStrings("https://fixture.invalid/first.jpg", first.metadata.art[0..first.metadata.art_len]);
    try std.testing.expectEqualStrings("/fixture/offline-second.torrent", second.entry.slice());
    try std.testing.expectEqualStrings("Second episode", second.metadata.title[0..second.metadata.title_len]);
    try std.testing.expectEqualStrings("S01E02", second.metadata.extra[0..second.metadata.extra_len]);
    try std.testing.expect(search.popPendingTorrentForTest() == null);
    try std.testing.expect(!state.hasPendingPlay());
}

fn admitDirect() void {
    state.stashPendingPlayFull("Owned direct episode", "https://fixture.invalid/direct.jpg", "Direct synopsis", .tv, "2026", 9, "S02E03");
    @import("browser.zig").playDirect(.{ .url = "https://fixture.invalid/video.mp4", .title = "Fallback title", .resume_position_secs = 29, .queue_item_id = 42 });
}
test "Native torrent handoff direct worker preserves metadata resume and queue ID" {
    @import("../core/workers.zig").init();
    defer @import("../core/workers.zig").markQuitting();
    try std.testing.expectEqual(@as(usize, 0), state.app.players.items.len);
    const worker = try std.Thread.spawn(.{}, admitDirect, .{});
    worker.join();
    try std.testing.expectEqual(@as(usize, 0), state.app.players.items.len);
    state.stashPendingPlay("Unrelated later play", "", "", false);
    const owned = @import("browser.zig").popDeferredPlaybackForTest().?;
    const metadata = owned.metadata.?;
    try std.testing.expectEqualStrings("Owned direct episode", metadata.title[0..metadata.title_len]);
    try std.testing.expectEqualStrings("https://fixture.invalid/direct.jpg", metadata.art[0..metadata.art_len]);
    try std.testing.expectEqual(@as(?f64, 29), owned.resume_position_secs);
    try std.testing.expectEqual(@as(i64, 42), owned.queue_item_id);
    try std.testing.expect(state.hasPendingPlay());
    state.clearPendingPlay();
}

test "Native torrent handoff fresh music metadata clears abandoned movie ID" {
    @import("../core/workers.zig").init();
    defer @import("../core/workers.zig").markQuitting();
    state.stashPendingPlay("Abandoned movie", "", "", false);
    state.setPendingPlayCatalogId(456);
    state.stashPendingPlayFull("Fresh music", "", "", .album, "2026", 0, "Artist");
    const metadata = state.takePendingPlay();
    try std.testing.expectEqual(@as(i32, 0), metadata.tmdb_id);
    try std.testing.expectEqualStrings("Fresh music", metadata.title[0..metadata.title_len]);
}

test "Native torrent handoff rejected real mpv resume remains retryable" {
    const c = @import("../core/c.zig");
    const ctx = c.mpv.mpv_create() orelse return error.MpvCreateFailed;
    defer c.mpv.mpv_destroy(ctx);
    _ = c.mpv.mpv_set_option_string(ctx, "config", "no");
    _ = c.mpv.mpv_set_option_string(ctx, "load-scripts", "no");
    _ = c.mpv.mpv_set_option_string(ctx, "terminal", "no");
    _ = c.mpv.mpv_set_option_string(ctx, "ao", "null");
    _ = c.mpv.mpv_set_option_string(ctx, "vo", "null");
    try std.testing.expect(c.mpv.mpv_initialize(ctx) >= 0);
    const p = try alloc.create(MediaPlayer);
    defer alloc.destroy(p);
    @memset(std.mem.asBytes(p), 0);
    p.mpv_ctx = ctx;
    p.current_url[0] = 'x';
    p.current_url_len = 1;
    p.provider_resume_position = 30;
    // Actual idle mpv rejects a seek; no media, network or audio is started.
    try std.testing.expect(c.mpv.mpv_command_string(ctx, "seek 30 absolute") < 0);
    p.tryResumePosition();
    try std.testing.expectEqual(@as(?f64, 30), p.provider_resume_position);
    try std.testing.expect(!p.resume_seeked);
}
