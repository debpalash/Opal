//! Exercise real empty-loading renderers without any provider or profile reads.
const std = @import("std");
const state = @import("../core/state.zig");
const components = @import("components.zig");
const theme = @import("theme.zig");
const capture = @import("native_capture.zig");
const Case = struct { name: []const u8, tab: state.DrawerTab, search: bool = false };
var current: Case = undefined;
var frames: usize = 0;
fn fixture(enabled: bool) void {
    switch (current.tab) {
        .Anime => @import("../services/anime.zig").setLoadingFixtureForTest(enabled),
        .YouTube => @import("../services/youtube.zig").setLoadingFixtureForTest(enabled),
        .Drama => @import("../services/drama.zig").setLoadingFixtureForTest(enabled),
        .Comics => @import("../services/comics.zig").setLoadingFixtureForTest(enabled),
        .Novels => @import("../services/novels.zig").setLoadingFixtureForTest(enabled),
        .Podcasts => @import("../services/podcasts.zig").setLoadingFixtureForTest(enabled),
        .Radio => @import("../services/radio.zig").setLoadingFixtureForTest(enabled),
        .Music => @import("../services/music_subsonic.zig").setLoadingFixtureForTest(enabled),
        .Vndb => @import("../services/vndb.zig").setLoadingFixtureForTest(enabled),
        .Opds => @import("../services/opds.zig").setLoadingFixtureForTest(enabled),
        else => unreachable,
    }
}
fn setup() !void {
    state.app.config_loaded.store(false, .release);
    state.app.page_shell_enabled = true;
    state.app.content_cache_enabled = false;
    state.app.ui_scale = 1;
    state.app.reduce_motion = true;
    state.app.router.current = .browse;
    state.app.browse_source = current.tab;
    state.app.anime.mode = if (current.search) .search else .trending;
    state.app.tmdb.api_key_len = 7;
    @memcpy(state.app.tmdb.api_key[0..7], "fixture");
    theme.active_preset = .midnight;
    frames = 0;
    fixture(true);
}
fn draw() !void {
    components.beginFrame();
    try @import("shell.zig").render();
    frames += 1;
    if (frames >= 4) {
        const observation = components.skeletonStateForTest();
        try std.testing.expect(observation.count > 0);
        try std.testing.expect(!observation.animated);
    }
}
fn cleanup() void {
    fixture(false);
    state.app.reduce_motion = false;
    state.app.tmdb.api_key_len = 0;
    state.app.config_loaded.store(false, .release);
}
test "Native Browse loading skeletons across all content views" {
    const workers = @import("../core/workers.zig");
    const logs = @import("../core/logs.zig");
    logs.logs_allocator = @import("../core/alloc.zig").allocator;
    defer logs.deinit();
    workers.init();
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    const cases = [_]Case{
        .{ .name = "loading-anime-discover", .tab = .Anime },
        .{ .name = "loading-anime-search", .tab = .Anime, .search = true },
        .{ .name = "loading-youtube", .tab = .YouTube },
        .{ .name = "loading-asian-drama", .tab = .Drama },
        .{ .name = "loading-comics", .tab = .Comics },
        .{ .name = "loading-novels", .tab = .Novels },
        .{ .name = "loading-podcasts", .tab = .Podcasts },
        .{ .name = "loading-radio", .tab = .Radio },
        .{ .name = "loading-music", .tab = .Music },
        .{ .name = "loading-visual-novels", .tab = .Vndb },
        .{ .name = "loading-gutenberg-discover", .tab = .Opds },
    };
    for (cases) |case| {
        current = case;
        for ([_][2]u32{ .{ 1360, 1000 }, .{ 640, 800 } }) |size|
            try capture.capture(size[0], size[1], current.name, setup, draw, cleanup);
    }
}
