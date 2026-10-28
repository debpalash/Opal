//! Opt-in production recap worker + SQLite + real model integration.
const std = @import("std");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");
const recap = @import("recap.zig");

fn waitReady() !recap.Snapshot {
    const end = io.milliTimestamp() + 130_000;
    while (io.milliTimestamp() < end) {
        const s = recap.snapshot();
        if (s.phase == .ready) return s;
        if (s.phase == .failed or s.phase == .nothing) {
            std.debug.print("recap: {s}\n", .{s.text[0..s.text_len]});
            return error.RecapFailed;
        }
        io.sleep(20 * std.time.ns_per_ms);
    }
    return error.RecapTimedOut;
}

test "Horizon device validation recap excludes future and unwatched episodes before model submission" {
    const root = io.getenv("OPAL_HORIZON_FIXTURE_DIR") orelse return error.SkipZigTest;
    var cfg_buf: [512]u8 = undefined;
    const cfg = @import("../core/paths.zig").configDir(&cfg_buf);
    try std.testing.expect(std.mem.startsWith(u8, cfg, root));
    @import("../core/logs.zig").logs_allocator = alloc;
    @import("../core/workers.zig").init();
    db.init();
    defer db.deinit();
    defer @import("../core/workers.zig").beginShutdownAndDrain(5_000);
    @import("ai_server.zig").backend_kind = .cloud;
    try std.testing.expect(@import("ai_server.zig").cloudConfigured());
    db.tvTouchShow(987654, "Compass Mystery", "");
    db.tvMarkWatched(987654, 1, 1, true);
    db.tvMarkWatched(987654, 1, 2, false);
    db.tvMarkWatched(987654, 1, 4, true);
    const transcripts = [_][]const u8{
        "Mara found a brass compass inside a red suitcase. She brought the compass to the harbor. On the way, she met her friend Tomas, who recognized the markings on the lid. They agreed to find the owner before sunset. Mara placed the suitcase on the dock and waited beside the fishing boats.",
        "UNWATCHED_CANARY: The lighthouse keeper is secretly a dragon.",
        "CURRENT_CANARY: The island vanishes forever.",
        "FUTURE_CANARY: Captain Voss is Mara's father and destroys the harbor.",
    };
    for (transcripts, 1..) |text, episode| {
        var path: [800]u8 = undefined;
        // Every source must exceed the minimum transcript length, otherwise
        // a spoiler-selection bug could pass merely because its text is short.
        const long_text = try std.mem.concat(alloc, u8, &.{ text, " ", text, " ", text, " ", text, " ", text, " ", text, " ", text, " ", text });
        defer alloc.free(long_text);
        try std.testing.expect(long_text.len >= @import("recap_pure.zig").min_transcript_chars);
        try io.cwdWriteFile(.{ .sub_path = @import("babel.zig").transcriptPath(&path, 987654, 1, @intCast(episode)), .data = long_text });
    }
    // currentEpisode only reads the bound identity. No mpv or UI is faked as
    // having played media: this fixture exercises the recap worker itself.
    const p = try alloc.create(@import("../player/player.zig").MediaPlayer);
    defer alloc.destroy(p);
    p.current_url_len = 7;
    @memcpy(p.current_url[0..7], "fixture");
    try state.app.players.append(alloc, p);
    defer state.app.players.deinit(alloc);
    state.app.active_player_idx = 0;
    state.app.playing_episode = .{ .active = true, .tmdb_id = 987654, .season = 1, .episode = 3 };
    state.app.playing_episode.url_len = 7;
    @memcpy(state.app.playing_episode.url[0..7], "fixture");
    recap.request(true);
    const result = try waitReady();
    try std.testing.expect(!result.cached);
    const text = result.text[0..result.text_len];
    try std.testing.expect(std.ascii.indexOfIgnoreCase(text, "compass") != null);
    for ([_][]const u8{ "CANARY", "dragon", "father", "vanishes" }) |spoiler| try std.testing.expect(std.ascii.indexOfIgnoreCase(text, spoiler) == null);
    // Wait for the worker's deferred busy release before requesting cache.
    io.sleep(100 * std.time.ns_per_ms);
    recap.onMediaChange();
    recap.request(false);
    const cached = try waitReady();
    try std.testing.expect(cached.cached);
    try std.testing.expectEqualStrings(text, cached.text[0..cached.text_len]);
    var output: [800]u8 = undefined;
    try io.cwdWriteFile(.{ .sub_path = try std.fmt.bufPrint(&output, "{s}/recap.txt", .{root}), .data = text });
}
