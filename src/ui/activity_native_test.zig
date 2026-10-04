//! Offline production Queue and Downloads renderer pixels; no engine/database startup.
const std = @import("std");
const queue = @import("../services/queue.zig");
const transfers = @import("../services/transfers.zig");
const tp = @import("../services/transfers_pure.zig");
const engine = @import("../services/download_engine.zig");
const capture = @import("native_capture.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
var queue_case = true;
var items: [8]queue.QueueItem = @splat(.{});
var download_rows: [3]tp.Row = @splat(.{});
var http_rows: [4]engine.Snap = @splat(.{});
var wanted_fixture: [3]@import("../services/wanted.zig").Row = @splat(.{});
fn setup() !void {
    const state = @import("../core/state.zig");
    state.app.page_shell_enabled = true;
    state.app.ui_scale = 1;
    state.app.router.current = if (queue_case) .queue else .downloads;
    state.app.config_loaded.store(false, .release);
    if (queue_case) {
        const sources = [_][]const u8{ "direct", "youtube", "magnet", "m3u" };
        for (&items, 0..) |*item, i| {
            item.* = .{ .id = @intCast(i + 1), .position = @intCast(i), .duration = @intCast(3600 + i * 83), .played = i == 1, .thumb_failed = true };
            const title = try std.fmt.bufPrint(&item.title, "Offline queue fixture {d} — a long movie title with commentary and multilingual audio", .{i + 1});
            item.title_len = title.len;
            const source = sources[i % sources.len];
            @memcpy(item.source[0..source.len], source);
            item.source_len = source.len;
            const url = "https://example.invalid/offline-fixture.mp4";
            @memcpy(item.url[0..url.len], url);
            item.url_len = url.len;
        }
        queue.setRenderFixtureForTest(&items);
    } else {
        for (&http_rows, 0..) |*row, i| {
            row.* = .{ .idx = i, .token = @intCast(i + 1), .status = ([_]engine.Status{ .running, .paused, .failed, .done })[i], .total = 1_000_000_000, .done = if (i == 3) 1_000_000_000 else 370_000_000, .rate = if (i == 0) 1_200_000 else 0, .seg_count = 4, .seg_frac = @splat(0.37) };
            const name = try std.fmt.bufPrint(&row.name, "Offline download fixture {d} — a long video title with director commentary.mp4", .{i + 1});
            row.name_len = name.len;
            if (i == 2) {
                const err = "Offline transport error fixture; retry remains available";
                @memcpy(row.err[0..err.len], err);
                row.err_len = err.len;
            }
        }
        for (&download_rows, 0..) |*row, i| {
            row.* = .{ .origin = if (i == 2) .history else .file, .size = 740_000_000, .hist_idx = if (i == 2) 0 else -1 };
            var buf: [160]u8 = undefined;
            const name = try std.fmt.bufPrint(&buf, "Offline finished fixture {d} with a long readable name.mp4", .{i + 1});
            tp.setName(row, name);
            if (i != 2) tp.setDisk(row, name);
        }
        transfers.setRenderFixtureForTest(&download_rows, &http_rows);
        const wanted = @import("../services/wanted.zig");
        const wanted_titles = [_][]const u8{ "Dune", "Severance", "A very long wanted title that must not push the row buttons out of view" };
        for (&wanted_fixture, 0..) |*row, i| {
            row.* = .{ .id = @intCast(i + 1), .kind = if (i == 1) .episode else .movie, .status = ([_]@import("../services/wanted_pure.zig").Status{ .wanted, .downloading, .paused })[i], .year = 2021, .season = 2, .episode = 3, .attempts = 2 };
            @memcpy(row.title[0..wanted_titles[i].len], wanted_titles[i]);
            row.title_len = wanted_titles[i].len;
            if (i == 1) {
                const picked = "Severance.S02E03.1080p.WEB.x265";
                @memcpy(row.picked[0..picked.len], picked);
                row.picked_len = picked.len;
            }
        }
        @import("../services/wanted_ui.zig").setRenderFixtureForTest(&wanted_fixture);
        _ = wanted;
    }
}
fn draw() !void {
    try @import("shell.zig").render();
}
fn cleanup() void {
    queue.setRenderFixtureForTest(null);
    transfers.setRenderFixtureForTest(null, &.{});
    @import("../services/wanted_ui.zig").setRenderFixtureForTest(null);
}
test "Native activity offline SDL pixel capture" {
    const logs = @import("../core/logs.zig");
    logs.logs_allocator = alloc;
    defer logs.deinit();
    workers.init();
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    for ([_]bool{ true, false }) |is_queue| {
        if (@import("../core/io_global.zig").getenv("OPAL_ACTIVITY_CASE")) |value| {
            if (!std.mem.eql(u8, value, if (is_queue) "queue" else "downloads")) continue;
        }
        queue_case = is_queue;
        for ([_][2]u32{ .{ 1360, 1000 }, .{ 640, 800 } }) |size| {
            if (@import("../core/io_global.zig").getenv("OPAL_ACTIVITY_WIDTH")) |value| {
                if ((std.fmt.parseInt(u32, value, 10) catch 0) != size[0]) continue;
            }
            try capture.capture(size[0], size[1], if (is_queue) "queue-populated" else "downloads-populated", setup, draw, cleanup);
            const rects = if (is_queue) queue.test_row_rects[0..4] else transfers.test_http_rects[0..4];
            if (!is_queue) {
                for (transfers.test_http_action_rects) |rect| try std.testing.expect(rect.w >= 60);
                for (transfers.test_file_action_rects, 0..) |rect, i| try std.testing.expect(rect.w >= (if (i < 2) @as(f32, 120) else 50));
            }
            for (1..rects.len) |i| {
                try std.testing.expect(rects[i].h > 0);
                try std.testing.expect(rects[i].y >= rects[i - 1].y + rects[i - 1].h);
            }
        }
    }
}
