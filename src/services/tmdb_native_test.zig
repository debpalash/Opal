//! Offline production episode-page captures and layout regression checks.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const capture = @import("../ui/native_capture.zig");
const alloc = @import("../core/alloc.zig").allocator;
var render: *const fn () void = undefined;
var enabled = false;
var frame: usize = 0;
var images: [6]?dvui.Rect = @splat(null);
var actions: [2]?dvui.Rect = @splat(null);
var details: [6]?dvui.Rect = @splat(null);

pub fn artwork(index: usize, rect: dvui.Rect) void {
    if (enabled and index < images.len) images[index] = rect;
}
pub fn information(index: usize, rect: dvui.Rect) void {
    if (enabled and index < details.len) details[index] = rect;
}
pub fn action(index: usize, rect: dvui.Rect) void {
    if (enabled) actions[index] = rect;
}
fn field(buffer: []u8, length: *usize, text: []const u8) void {
    length.* = @min(buffer.len, text.len);
    @memcpy(buffer[0..length.*], text[0..length.*]);
}
fn setup() !void {
    frame = 0;
    const t = &state.app.tmdb;
    // No DB initialization, requests, player, or real profile in this fixture.
    t.tv_id = 0;
    t.tv_seasons_failed = false;
    t.tv_episodes_failed = false;
    t.tv_seasons_refresh_pending = false;
    t.tv_seasons_loading = false;
    t.tv_episodes_loading = false;
    t.tv_sel_season = 0;
    field(&t.tv_name, &t.tv_name_len, "Yoroi Shinden Samurai Troopers");
    t.tv_seasons = try alloc.alloc(state.TvSeason, 1);
    t.tv_seasons[0] = .{ .season_number = 1, .episode_count = 6 };
    t.tv_season_count = 1;
    t.tv_episodes = try alloc.alloc(state.TvEpisode, 6);
    t.tv_episode_watched = try alloc.alloc(bool, 6);
    @memset(t.tv_episode_watched, false);
    t.tv_episode_watched[0] = true;
    t.tv_episode_count = 6;
    const titles = [_][]const u8{ "The first of the Four Beast Warriors", "A promise across the stars", "The return", "Love", "True", "Gai" };
    for (t.tv_episodes, 0..) |*ep, i| {
        ep.* = .{ .episode_number = @intCast(i + 1), .runtime = 24, .vote_average = 8.1, .still_attempted = true };
        field(&ep.name, &ep.name_len, titles[i]);
        field(&ep.overview, &ep.overview_len, "The Troopers find themselves trapped within Gai's psyche while Sagume deals a resurrected enemy one final blow.");
        if (i != 5) field(&ep.air_date, &ep.air_date_len, if (i == 4) "2099-09-15" else "2026-09-08");
    }
}
fn draw() !void {
    if (frame == 0) {
        for (state.app.tmdb.tv_episodes, 0..) |*ep, i| {
            if (i == 2 or i == 5) continue; // Missing art and undated episode.
            var pixels: [160 * 90 * 4]u8 = undefined;
            for (0..160 * 90) |p| {
                pixels[p * 4] = @intCast(30 + i * 22 + p % 160 / 3);
                pixels[p * 4 + 1] = @intCast(48 + p / 160);
                pixels[p * 4 + 2] = @intCast(95 + i * 17);
                pixels[p * 4 + 3] = 255;
            }
            ep.still_tex = try dvui.Texture.fromImageSource(.{ .pixels = .{ .rgba = &pixels, .width = 160, .height = 90, .interpolation = .linear } });
        }
    }
    images = @splat(null);
    details = @splat(null);
    actions = @splat(null);
    render();
    if (frame >= 4) {
        for (actions) |action_rect| {
            const rect = action_rect orelse return error.MissingPlaybackAction;
            try std.testing.expect(rect.x >= 0 and rect.x + rect.w <= dvui.windowRect().w + 0.5);
        }
        const first = actions[0].?;
        const second = actions[1].?;
        try std.testing.expect(first.x + first.w <= second.x + 0.5 or first.y + first.h <= second.y + 0.5);
        var checked: usize = 0;
        for (images, details) |image_rect, detail_rect| {
            if (image_rect) |art| {
                const info = detail_rect orelse return error.MissingEpisodeInformation;
                // Regression: centered artwork used to paint over the synopsis.
                try std.testing.expect(art.y + art.h <= info.y + 0.5);
                try std.testing.expectApproxEqAbs(art.x, info.x, 0.5);
                try std.testing.expectApproxEqAbs(art.w, info.w, 0.5);
                checked += 1;
            }
        }
        try std.testing.expect(checked > 0);
    }
    frame += 1;
}
fn cleanup() void {
    for (state.app.tmdb.tv_episodes) |*ep| {
        if (ep.still_tex) |texture| dvui.textureDestroyLater(texture);
        ep.still_tex = null;
    }
    @import("tmdb.zig").deinitDetail();
}
pub fn run(draw_page: *const fn () void) !void {
    render = draw_page;
    enabled = true;
    defer enabled = false;
    const previous_scale = state.app.ui_scale;
    state.app.ui_scale = 1;
    defer state.app.ui_scale = previous_scale;
    const previous = theme.active_preset;
    defer theme.active_preset = previous;
    for ([_]theme.ThemePreset{ .midnight, .ember }) |preset| {
        theme.active_preset = preset;
        for ([_][2]u32{ .{ 1200, 900 }, .{ 760, 900 }, .{ 390, 850 } }) |size| {
            try capture.capture(size[0], size[1], if (preset == .ember) "episodes-ember" else "episodes-midnight", setup, draw, cleanup);
        }
    }
}
