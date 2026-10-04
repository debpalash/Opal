//! Offline pixels for the Activity tab on the Agents page: proposals waiting for
//! an OK plus every job state, the empty state with the operator off, and the
//! empty state with it on. Fixed rows; no database, no agent is started.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const alloc = @import("../core/alloc.zig").allocator;
const workers = @import("../core/workers.zig");
const capture = @import("native_capture.zig");
const operator = @import("../services/operator.zig");
const pure = @import("../services/operator_pure.zig");
const tasks_ui = @import("agent_tasks_ui.zig");
const ui = @import("operator_ui.zig");
const theme = @import("theme.zig");
const io = @import("../core/io_global.zig");

const Case = enum { populated, empty_off, empty_on };
var current: Case = .populated;
var fixture: [8]operator.Row = @splat(.{});

fn put(dst: []u8, len: *usize, text: []const u8) void {
    const n = @min(text.len, dst.len);
    @memcpy(dst[0..n], text[0..n]);
    len.* = n;
}

fn setup() !void {
    state.app.ui_scale = 1;
    state.app.operator_enabled = current != .empty_off;
    state.app.operator_daily_cents = 100;
    const now = io.milliTimestamp();
    const States = [_]pure.State{ .proposed, .proposed, .running, .applied, .failed, .rejected, .queued, .applied };
    const kinds = [_]pure.Kind{ .endpoint_repair, .endpoint_repair, .match_help, .match_help, .endpoint_repair, .endpoint_repair, .match_help, .match_help };
    const summaries = [_][]const u8{
        "Move the source \"Example Index\" from https://old.example to https://new.example (confidence 85%)",
        "Move a source with a very long name from https://a-very-long-old-address.example.invalid/path to https://another-very-long-new-address.example.invalid, found on the project's status page, which is deliberately long enough to be cut by the one-line limit",
        "",
        "Now also searching: Sen to Chihiro no Kamikakushi, Spirited Away",
        "The agent did not finish (not signed in, out of credit, or an error)",
        "Move the source \"Other\" to https://other.example",
        "",
        "Now also searching: Duna",
    };
    const agents = [_][]const u8{ "claude", "codex", "claude", "claude", "codex", "claude", "", "claude" };
    const costs = [_]u32{ 22, 31, 0, 6, 0, 18, 0, 4 };
    for (&fixture, 0..) |*row, i| {
        row.* = .{
            .id = @intCast(i + 1),
            .kind = kinds[i],
            .state = States[i],
            .cost_cents = costs[i],
            .created_ms = now - @as(i64, @intCast(i + 1)) * 53 * 60_000,
            .finished_ms = if (States[i] == .queued or States[i] == .running or States[i] == .proposed) 0 else now - @as(i64, @intCast(i)) * 47 * 60_000,
        };
        put(&row.key, &row.key_len, "7");
        put(&row.summary, &row.summary_len, summaries[i]);
        put(&row.agent, &row.agent_len, agents[i]);
    }
    switch (current) {
        .populated => ui.setRenderFixtureForTest(&fixture, 12),
        .empty_off, .empty_on => ui.setRenderFixtureForTest(fixture[0..0], 0),
    }
}

fn draw() !void {
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_app });
    defer page.deinit();
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 } });
        defer bar.deinit();
        var buf: [24]u8 = undefined;
        _ = tasks_ui.tabSwitch(3, @import("../services/operator_view_pure.zig").tabLabel(&buf, if (current == .populated) 2 else 0));
    }
    ui.render();
}

fn cleanup() void {
    ui.setRenderFixtureForTest(null, 0);
}

test "Native operator activity offline SDL pixel capture" {
    const logs = @import("../core/logs.zig");
    logs.logs_allocator = alloc;
    defer logs.deinit();
    workers.init();
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    const names = [_][]const u8{ "operator-populated", "operator-empty-off", "operator-empty-on" };
    inline for (std.meta.fields(Case), 0..) |f, i| {
        current = @field(Case, f.name);
        for ([_][2]u32{ .{ 1100, 1000 }, .{ 640, 800 } }) |size| {
            try capture.capture(size[0], size[1], names[i], setup, draw, cleanup);
        }
    }
}
