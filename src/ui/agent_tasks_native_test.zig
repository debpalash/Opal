//! Offline pixels for the Tasks panel on the Agents page: populated list with
//! every outcome tone, the empty state with examples, and the open form with a
//! validation error. Fixed rows; no database, no agent is started.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const alloc = @import("../core/alloc.zig").allocator;
const workers = @import("../core/workers.zig");
const capture = @import("native_capture.zig");
const tasks = @import("../services/agent_tasks.zig");
const ui = @import("agent_tasks_ui.zig");
const theme = @import("theme.zig");
const io = @import("../core/io_global.zig");

const Case = enum { populated, populated_switch_off, empty, form };
var current: Case = .populated;
var fixture: [5]tasks.Row = @splat(.{});

fn put(dst: []u8, len: *usize, text: []const u8) void {
    @memcpy(dst[0..text.len], text);
    len.* = text.len;
}

fn setup() !void {
    state.app.ui_scale = 1;
    state.app.agent_tasks_enabled = current != .populated_switch_off;
    const now = io.milliTimestamp();
    const names = [_][]const u8{
        "Daily digest",
        "Check wanted list",
        "A task with a very long name that has to stay inside its card without pushing",
        "Finished downloads report",
        "Weekly cleanup (paused)",
    };
    const outcomes = [_][]const u8{ "ok", "running", "failed", "not_installed", "timed_out" };
    const summaries = [_][]const u8{
        "calling tool downloads_list\nNothing is stuck: 4 downloads active, all moving.",
        "",
        "Error: not logged in. Run `claude login` first, then enable the task again so it can retry; this summary is deliberately long enough to be cut by the one-line limit of the panel.",
        "The agent is not installed (not on PATH).",
        "",
    };
    for (&fixture, 0..) |*row, i| {
        row.* = .{
            .id = @intCast(i + 1),
            .agent = if (i == 1 or i == 3) .codex else .claude,
            .enabled = i != 4,
            .running = i == 1,
            .interval_min = ([_]u32{ 1440, 360, 90, 10080, 15 })[i],
            .max_runs_per_day = ([_]u32{ 1, 4, 2, 1, 24 })[i],
            .runs_today = ([_]u32{ 1, 2, 2, 0, 24 })[i],
            .budget_cents = ([_]u32{ 30, 50, 5, 30, 1000 })[i],
            .total_runs = 12,
            .last_run_ms = now - @as(i64, @intCast(i + 1)) * 47 * 60_000,
            .next_run_ms = if (i == 4) 0 else now + @as(i64, @intCast(i + 1)) * 83 * 60_000,
        };
        put(&row.name, &row.name_len, names[i][0..@min(names[i].len, 60)]);
        put(&row.outcome, &row.outcome_len, outcomes[i]);
        put(&row.summary, &row.summary_len, summaries[i]);
    }
    switch (current) {
        .populated, .populated_switch_off => {
            ui.setRenderFixtureForTest(&fixture);
            ui.setFormForTest(false, "");
        },
        .empty => {
            ui.setRenderFixtureForTest(fixture[0..0]);
            ui.setFormForTest(false, "");
        },
        .form => {
            ui.setRenderFixtureForTest(fixture[0..2]);
            ui.setFormForTest(true, "interval_min must be 15 to 10080");
        },
    }
}

fn draw() !void {
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_app });
    defer page.deinit();
    {
        // The real toolbar is a horizontal box.
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 } });
        defer bar.deinit();
        _ = ui.tabSwitch(2, "Activity");
    }
    ui.render();
}

fn cleanup() void {
    ui.setRenderFixtureForTest(null);
}

test "Native agent tasks offline SDL pixel capture" {
    const logs = @import("../core/logs.zig");
    logs.logs_allocator = alloc;
    defer logs.deinit();
    workers.init();
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    const names = [_][]const u8{ "agent-tasks-populated", "agent-tasks-switch-off", "agent-tasks-empty", "agent-tasks-form" };
    inline for (std.meta.fields(Case), 0..) |f, i| {
        current = @field(Case, f.name);
        for ([_][2]u32{ .{ 1100, 900 }, .{ 640, 800 } }) |size| {
            try capture.capture(size[0], size[1], names[i], setup, draw, cleanup);
        }
    }
}
