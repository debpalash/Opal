//! Offline pixels for the Overview tab on the Agents page: populated (every
//! automation on, a full activity feed, proposals waiting) and empty (all
//! switches off, nothing happened yet), each at a wide and a narrow window and
//! at the top and bottom of the page. Fixed rows; no database, no agent is
//! started, no network.
//!
//! The Wanted card's text entry is hidden in these captures: the offline capture
//! backend blanks whatever is drawn after a text entry (the Tasks form capture
//! shows the same), so the entry itself is checked in the live app instead.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const alloc = @import("../core/alloc.zig").allocator;
const workers = @import("../core/workers.zig");
const capture = @import("native_capture.zig");
const wanted = @import("../services/wanted.zig");
const tasks = @import("../services/agent_tasks.zig");
const operator = @import("../services/operator.zig");
const op_pure = @import("../services/operator_pure.zig");
const wanted_pure = @import("../services/wanted_pure.zig");
const tasks_ui = @import("agent_tasks_ui.zig");
const ui = @import("agents_overview.zig");
const theme = @import("theme.zig");
const io = @import("../core/io_global.zig");

const Case = enum { populated, empty };
var current: Case = .populated;
var at_end = false;
var wanted_fx: [6]wanted.Row = @splat(.{});
var tasks_fx: [3]tasks.Row = @splat(.{});
var ops_fx: [6]operator.Row = @splat(.{});

fn put(dst: []u8, len: *usize, text: []const u8) void {
    const n = @min(text.len, dst.len);
    @memcpy(dst[0..n], text[0..n]);
    len.* = n;
}

fn setup() !void {
    state.app.ui_scale = 1;
    const populated = current == .populated;
    state.app.wanted_follow_tv = populated;
    state.app.agent_tasks_enabled = populated;
    state.app.operator_enabled = populated;
    state.app.auto_download_subs = populated;
    state.app.operator_daily_cents = 100;
    const now = io.milliTimestamp();
    const min: i64 = 60_000;

    const titles = [_][]const u8{ "Fixture Movie Alpha", "Fixture Show Beta", "Fixture Movie Gamma With A Rather Long Name Indeed", "Fixture Show Delta", "Fixture Movie Epsilon", "Fixture Show Zeta" };
    const status = [_]wanted_pure.Status{ .wanted, .downloading, .fulfilled, .fulfilled, .wanted, .paused };
    for (&wanted_fx, 0..) |*r, i| {
        r.* = .{
            .id = @intCast(i + 1),
            .kind = if (i % 2 == 1) .episode else .movie,
            .status = status[i],
            .year = if (i % 2 == 0) 2020 + @as(u16, @intCast(i)) else 0,
            .season = 2,
            .episode = @intCast(i + 1),
            .added_ms = now - @as(i64, @intCast(i + 1)) * 300 * min,
            .last_check_ms = now - @as(i64, @intCast(i + 1)) * 41 * min,
        };
        put(&r.title, &r.title_len, titles[i]);
    }

    const task_names = [_][]const u8{ "Daily digest", "Check wanted list", "Weekly cleanup (paused)" };
    const outcomes = [_][]const u8{ "ok", "failed", "" };
    const sums = [_][]const u8{ "Nothing is stuck: 4 downloads active, all moving.", "Error: not logged in. Run `claude login` first, then enable the task again so it can retry.", "" };
    for (&tasks_fx, 0..) |*r, i| {
        r.* = .{
            .id = @intCast(i + 1),
            .enabled = i != 2,
            .interval_min = ([_]u32{ 1440, 360, 10080 })[i],
            .max_runs_per_day = 2,
            .last_run_ms = if (i == 2) 0 else now - @as(i64, @intCast(i + 1)) * 130 * min,
            .next_run_ms = if (i == 2) 0 else now + @as(i64, @intCast(i + 1)) * 83 * min,
        };
        put(&r.name, &r.name_len, task_names[i]);
        put(&r.outcome, &r.outcome_len, outcomes[i]);
        put(&r.summary, &r.summary_len, sums[i]);
    }

    const states = [_]op_pure.State{ .proposed, .applied, .failed, .applied, .queued, .rejected };
    const kinds = [_]op_pure.Kind{ .endpoint_repair, .match_help, .endpoint_repair, .endpoint_repair, .match_help, .endpoint_repair };
    const op_sums = [_][]const u8{
        "Move the source \"Example Index\" from https://old.example to https://new.example (confidence 85%)",
        "Now also searching: Fixture Alt Title, Another Alt",
        "The agent did not finish (not signed in, out of credit, or an error)",
        "Moved a source to https://new-address.example",
        "",
        "",
    };
    for (&ops_fx, 0..) |*r, i| {
        r.* = .{
            .id = @intCast(i + 1),
            .kind = kinds[i],
            .state = states[i],
            .cost_cents = 12,
            .created_ms = now - @as(i64, @intCast(i + 1)) * 67 * min,
            .finished_ms = if (states[i] == .queued or states[i] == .proposed) 0 else now - @as(i64, @intCast(i)) * 59 * min,
        };
        put(&r.key, &r.key_len, "7");
        put(&r.summary, &r.summary_len, op_sums[i]);
        put(&r.agent, &r.agent_len, "claude");
    }

    switch (current) {
        .populated => ui.setRenderFixtureForTest(.{ .wanted = &wanted_fx, .tasks = &tasks_fx, .ops = &ops_fx, .spent = 36, .tracked = 7, .sources = 12, .hide_entry = true }),
        .empty => ui.setRenderFixtureForTest(.{ .hide_entry = true }),
    }
}

fn draw() !void {
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_app });
    defer page.deinit();
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 } });
        defer bar.deinit();
        _ = tasks_ui.tabSwitch(0, if (current == .populated) "Activity 1" else "Activity");
    }
    if (at_end) ui.scrollToEndForTest();
    ui.render();
}

fn cleanup() void {
    ui.setRenderFixtureForTest(null);
}

test "Native agents overview offline SDL pixel capture" {
    const logs = @import("../core/logs.zig");
    logs.logs_allocator = alloc;
    defer logs.deinit();
    workers.init();
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    const names = [_][]const u8{ "agents-overview-populated", "agents-overview-empty" };
    const ends = [_][]const u8{ "-top", "-end" };
    inline for (std.meta.fields(Case), 0..) |f, i| {
        current = @field(Case, f.name);
        for ([_][2]u32{ .{ 1100, 1000 }, .{ 640, 1000 } }) |size| {
            for ([_]bool{ false, true }, 0..) |end, e| {
                at_end = end;
                var name_buf: [64]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "{s}{s}", .{ names[i], ends[e] });
                try capture.capture(size[0], size[1], name, setup, draw, cleanup);
            }
        }
    }
}
