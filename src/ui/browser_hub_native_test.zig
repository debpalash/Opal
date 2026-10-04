//! Offline pixels for the Browser hub (Browse > Web): paired browsers, a shared
//! page with detected streams, the first-run state with install guidance and a
//! live pairing code, and a shared page that came without streams. Fixed rows;
//! no database, no listener, no browser.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const alloc = @import("../core/alloc.zig").allocator;
const workers = @import("../core/workers.zig");
const capture = @import("native_capture.zig");
const link = @import("../services/browser_link.zig");
const shared = @import("../services/browser_page.zig");
const ui = @import("browser_hub.zig");
const theme = @import("theme.zig");

const Case = enum { populated, first_run, no_streams };
var current: Case = .populated;
var links_fixture: [3]link.Link = @splat(.{});
const NOW: i64 = 1_800_000_000;

fn put(dst: []u8, len: *usize, text: []const u8) void {
    const n = @min(text.len, dst.len);
    @memcpy(dst[0..n], text[0..n]);
    len.* = n;
}

fn pageFixture(streams: usize, agents: bool) shared.UiView {
    var v: shared.UiView = .{ .present = true, .page_id = 4, .text_len = 6400, .agents = agents, .shared_at = NOW - 40 };
    put(&v.title, &v.title_len, "Dune: Part Two (2024) - Watch Full Movie Online Free in HD with a title that is far too long for one line of the card");
    put(&v.where, &v.where_len, "https://streams.example.org/watch/dune-part-two-2024/a-long-path-segment/that-keeps-going");
    const kinds = [_]@import("../services/browser_link_pure.zig").Kind{ .hls, .mp4, .dash, .audio, .ts };
    const labels = [_][]const u8{
        "cdn.example.net/hls/dune-part-two/master.m3u8",
        "127.0.0.1:8802/clip.mp4",
        "cdn2.example.net/a/very/long/path/that/should/be/cut/before/it/breaks/the/row/manifest.mpd",
        "media.example.org/audio/track-01.mp3",
        "cdn.example.net/seg-1.ts",
    };
    v.cand_count = streams;
    for (0..streams) |i| {
        v.cands[i] = .{ .id = @intCast(i + 1), .kind = kinds[i], .has_referer = i != 1 };
        put(&v.cands[i].label, &v.cands[i].label_len, labels[i]);
    }
    return v;
}

fn setup() !void {
    state.app.ui_scale = 1;
    state.app.web_remote_enabled = current != .first_run;
    state.app.browser_share_agents = current == .populated;
    for (&links_fixture, 0..) |*row, i| {
        row.* = .{ .id = @intCast(i + 1) };
        const labels = [_][]const u8{ "chrome on Linux x86_64", "firefox on a laptop with a surprisingly long label that is cut", "edge on Windows" };
        const browsers = [_][]const u8{ "chrome", "firefox", "edge" };
        put(&row.label, &row.label_len, labels[i]);
        put(&row.browser, &row.browser_len, browsers[i]);
        row.last_seen = NOW - ([_]i64{ 20, 50 * 60, 3 * 86400 })[i];
    }
    switch (current) {
        .populated => ui.setRenderFixtureForTest(.{ .links = &links_fixture, .page = pageFixture(5, true), .now = NOW }),
        .first_run => ui.setRenderFixtureForTest(.{ .links = links_fixture[0..0], .now = NOW, .pairing = .{ .active = true, .code = "482913".*, .remaining = 97 } }),
        .no_streams => ui.setRenderFixtureForTest(.{ .links = links_fixture[0..1], .page = pageFixture(0, false), .now = NOW }),
    }
}

fn draw() !void {
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_app });
    defer page.deinit();
    ui.render();
}

fn cleanup() void {
    ui.setRenderFixtureForTest(null);
}

test "Native browser hub offline SDL pixel capture" {
    const logs = @import("../core/logs.zig");
    logs.logs_allocator = alloc;
    defer logs.deinit();
    workers.init();
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    const names = [_][]const u8{ "browser-hub-populated", "browser-hub-first-run", "browser-hub-no-streams" };
    inline for (std.meta.fields(Case), 0..) |f, i| {
        current = @field(Case, f.name);
        for ([_][2]u32{ .{ 1000, 780 }, .{ 640, 780 } }) |size| {
            try capture.capture(size[0], size[1], names[i], setup, draw, cleanup);
        }
    }
}
