//! The Activity tab on the Agents page: what the background operator is doing.
//! The master switch and daily limit at the top, the proposals that need a
//! person's OK first (a changed source address never applies itself), then the
//! recent jobs with their outcome.
//!
//! Nothing here runs an agent. The operator's own gate (switch, cooldown, daily
//! spend) decides that; this panel only shows the jobs table and records the
//! user's decisions through `operator.approve` / `operator.reject`. Wording is in
//! `operator_view_pure.zig`.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");
const tasks_ui = @import("agent_tasks_ui.zig");
const state = @import("../core/state.zig");
const io_global = @import("../core/io_global.zig");
const operator = @import("../services/operator.zig");
const view = @import("../services/operator_view_pure.zig");
const text_view = @import("../services/agent_tasks_view_pure.zig");

const Row = operator.Row;
const MAX_ROWS: usize = 40;
const MAX_RECENT: usize = 30;
const SUMMARY_SHOWN: usize = 150;

var rows: [MAX_ROWS]Row = undefined;
var row_count: usize = 0;
var spent_cents: u32 = 0;
var last_load_ms: i64 = 0;
var dirty = true;

/// Approving changes configuration, so it takes two clicks on the same job
/// within a few seconds; a second job's button starts over.
var armed_id: i64 = 0;
var armed_at_ms: i64 = 0;
const ARM_WINDOW_MS: i64 = 3000;

/// Offline pixel tests render fixed rows instead of reading the database.
var fixture_for_test: ?[]const Row = null;
var fixture_spent: u32 = 0;

pub fn setRenderFixtureForTest(fixture: ?[]const Row, spent: u32) void {
    fixture_for_test = fixture;
    fixture_spent = spent;
    armed_id = 0;
    dirty = true;
}

fn refresh() void {
    if (@import("builtin").is_test) {
        if (fixture_for_test) |f| {
            row_count = @min(f.len, rows.len);
            @memcpy(rows[0..row_count], f[0..row_count]);
            spent_cents = fixture_spent;
            return;
        }
    }
    const now = io_global.milliTimestamp();
    if (!dirty and now - last_load_ms < 1500) return;
    last_load_ms = now;
    dirty = false;
    row_count = operator.snapshot(&rows);
    spent_cents = operator.spentTodayCents();
}

/// How many proposals wait for the user. Cheap: it shares the throttled refresh
/// with the panel, so the tab header can show it from any tab.
pub fn pendingCount() usize {
    refresh();
    var n: usize = 0;
    for (rows[0..row_count]) |r| {
        if (r.state == .proposed) n += 1;
    }
    return n;
}

// ── Actions ──

fn decide(r: *const Row, approve: bool) void {
    const res = if (approve) operator.approve(r.id) else operator.reject(r.id);
    switch (res) {
        .ok => state.showToastTyped(if (approve) "Approved: the change is applied" else "Rejected: nothing was changed", .success),
        .not_proposed => state.showToastTyped("That proposal was already decided", .warning),
        .no_such_job => state.showToastTyped("That job no longer exists", .warning),
        .failed => state.showToastTyped("Could not apply it: the proposal is no longer valid", .warning),
        .unavailable => state.showToastTyped("Not available right now", .warning),
    }
    armed_id = 0;
    dirty = true;
}

/// Primary button that needs a second click on the same job to go through.
fn approveButton(r: *const Row, i: usize) bool {
    const now = io_global.milliTimestamp();
    const armed = armed_id == r.id and now - armed_at_ms < ARM_WINDOW_MS;
    if (components.actionButton(@src(), if (armed) "Click again to approve" else "Approve", .primary, 20000 + i)) {
        if (armed) return true;
        armed_id = r.id;
        armed_at_ms = now;
        // Repaint once the window is over so the label goes back by itself.
        dvui.timer(dvui.parentGet().data().id, ARM_WINDOW_MS * 1000 + 100_000);
    }
    return false;
}

// ── Drawing ──

fn toneColor(tone: view.Tone) dvui.Color {
    return switch (tone) {
        .muted => theme.colors.text_secondary,
        .active => theme.colors.accent,
        .good => theme.colors.success,
        .bad => theme.colors.danger,
    };
}

fn smallFont() dvui.Font {
    var f = dvui.themeGet().font_body;
    f.size = theme.font_size.small;
    return f;
}

fn cardBox(src: std.builtin.SourceLocation, id_extra: usize) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 14, .y = 10, .w = 14, .h = 10 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });
}

fn sectionTitle(src: std.builtin.SourceLocation, text: []const u8) void {
    _ = dvui.label(src, "{s}", .{text}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.Font.theme(.title),
        .margin = .{ .x = 0, .y = 6, .w = 0, .h = 8 },
    });
}

fn renderControls() void {
    var card = cardBox(@src(), 0);
    defer card.deinit();

    const before = state.app.operator_enabled;
    components.toggleRow(
        @src(),
        "Background operator",
        "Quietly hands problems Opal cannot solve alone (other titles for something you want, a source whose address moved) to your coding agent and uses the answer. It runs on your own agent credit, within the daily limit below. It starts off.",
        &state.app.operator_enabled,
    );
    if (state.app.operator_enabled != before) {
        const now_on = state.app.operator_enabled;
        operator.setEnabled(now_on);
        state.showToast(if (now_on) "Background operator on" else "Background operator off");
        dirty = true;
    }

    var spend_buf: [48]u8 = undefined;
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 10, .w = 0, .h = 4 } });
        defer line.deinit();
        _ = dvui.label(@src(), "Spent", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5, .min_size_content = .{ .w = 80, .h = 0 } });
        _ = dvui.label(@src(), "{s}", .{view.spendText(&spend_buf, spent_cents, state.app.operator_daily_cents)}, .{
            .color_text = if (spent_cents >= state.app.operator_daily_cents) theme.colors.warning else theme.colors.text_primary,
            .gravity_y = 0.5,
        });
    }
    dvui.progress(@src(), .{
        .percent = view.spendFraction(spent_cents, state.app.operator_daily_cents),
        .color = if (spent_cents >= state.app.operator_daily_cents) theme.colors.warning else theme.colors.accent,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 10, .h = 5 },
        .max_size_content = .{ .w = 100000, .h = 5 },
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = theme.dims.rad_sm,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 10 },
    });

    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer line.deinit();
        _ = dvui.label(@src(), "Daily limit", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5, .min_size_content = .{ .w = 80, .h = 0 } });
        const sel = view.limitIndex(state.app.operator_daily_cents);
        if (tasks_ui.compactSegment(@src(), &view.limit_labels, sel orelse view.limit_labels.len)) |i| {
            state.app.operator_daily_cents = view.limit_presets[i];
            state.markConfigDirty();
            state.wakeUi();
        }
    }
}

fn renderEmpty() void {
    var card = cardBox(@src(), 0);
    defer card.deinit();
    _ = dvui.label(@src(), "Nothing to show yet", .{}, .{ .color_text = theme.colors.text_primary });
    _ = dvui.label(@src(), "When the operator helps, it shows up here: the other titles it found for something on your Wanted list, and any source address it proposes that waits for your OK. Jobs and what they cost are kept for review.", .{}, .{
        .color_text = theme.colors.text_secondary,
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 6 },
    });
    const status: []const u8 = if (state.app.operator_enabled)
        "The operator is on. It only acts when Opal runs into a problem it cannot solve itself."
    else
        "The operator is off by default. Nothing is sent to an agent until you switch it on above.";
    _ = dvui.label(@src(), "{s}", .{status}, .{
        .color_text = theme.colors.text_secondary,
        .expand = .horizontal,
    });
}

fn renderProposal(i: usize, now: i64) void {
    const r = &rows[i];
    var card = cardBox(@src(), i);
    defer card.deinit();

    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer line.deinit();
        _ = dvui.label(@src(), "{s}", .{r.title()}, .{ .color_text = theme.colors.text_primary, .gravity_y = 0.5 });
        var agent_buf: [24]u8 = undefined;
        const agent = view.agentLabel(r.agent[0..@min(r.agent_len, r.agent.len)]);
        _ = dvui.label(@src(), "{s}", .{text_view.summaryLine(&agent_buf, agent, 20)}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
        });
        var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
        defer acts.deinit();
        if (components.actionButton(@src(), "Reject", .secondary, 20100 + i)) decide(r, false);
        if (approveButton(r, i)) decide(r, true);
    }
    {
        var sbuf: [SUMMARY_SHOWN]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{text_view.summaryLine(&sbuf, r.summary[0..@min(r.summary_len, r.summary.len)], SUMMARY_SHOWN)}, .{
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
    }
    {
        var tbuf: [24]u8 = undefined;
        _ = dvui.label(@src(), "Proposed {s}. Nothing changes until you approve.", .{view.relativeText(&tbuf, r.created_ms, now)}, .{
            .color_text = theme.colors.text_secondary,
            .font = smallFont(),
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
        });
    }
}

fn renderChip(st: @import("../services/operator_pure.zig").State, id_extra: usize) void {
    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 1, .w = 8, .h = 1 },
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 76, .h = 0 },
    });
    defer chip.deinit();
    _ = dvui.label(@src(), "{s}", .{view.stateLabel(st)}, .{
        .id_extra = id_extra,
        .color_text = toneColor(view.stateTone(st)),
        .font = smallFont(),
        .gravity_x = 0.5,
    });
}

fn renderRecent(i: usize, now: i64) void {
    const r = &rows[i];
    var card = cardBox(@src(), i);
    defer card.deinit();

    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer line.deinit();
        renderChip(r.state, i);
        _ = dvui.label(@src(), "{s}", .{r.title()}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
            .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
        });
        var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
        defer meta.deinit();
        var cbuf: [16]u8 = undefined;
        var tbuf: [24]u8 = undefined;
        const agent = view.agentLabel(r.agent[0..@min(r.agent_len, r.agent.len)]);
        const when = view.relativeText(&tbuf, if (r.finished_ms > 0) r.finished_ms else r.created_ms, now);
        var meta_buf: [96]u8 = undefined;
        const cost = view.costText(&cbuf, r.cost_cents);
        const text = std.fmt.bufPrint(&meta_buf, "{s}{s}{s}{s}{s}", .{
            agent,
            if (agent.len > 0 and cost.len > 0) "  |  " else "",
            cost,
            if ((agent.len > 0 or cost.len > 0) and when.len > 0) "  |  " else "",
            when,
        }) catch when;
        _ = dvui.label(@src(), "{s}", .{text}, .{ .color_text = theme.colors.text_secondary, .font = smallFont(), .gravity_y = 0.5 });
    }
    if (r.summary_len > 0) {
        var sbuf: [SUMMARY_SHOWN]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{text_view.summaryLine(&sbuf, r.summary[0..@min(r.summary_len, r.summary.len)], SUMMARY_SHOWN)}, .{
            .color_text = if (r.state == .failed) theme.colors.danger else theme.colors.text_primary,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
    }
}

/// Draw the panel. Safe to call every frame.
pub fn render() void {
    refresh();
    const now = io_global.milliTimestamp();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 16 },
    });
    defer col.deinit();

    renderControls();

    var pending: usize = 0;
    for (rows[0..row_count]) |r| {
        if (r.state == .proposed) pending += 1;
    }

    if (row_count == 0) {
        renderEmpty();
        return;
    }

    if (pending > 0) {
        var hbuf: [40]u8 = undefined;
        sectionTitle(@src(), std.fmt.bufPrint(&hbuf, "Needs your OK ({d})", .{pending}) catch "Needs your OK");
        var i: usize = 0;
        while (i < row_count) : (i += 1) {
            if (rows[i].state == .proposed) renderProposal(i, now);
        }
    }

    if (row_count > pending) {
        sectionTitle(@src(), "Recent");
        var shown: usize = 0;
        var i: usize = 0;
        while (i < row_count and shown < MAX_RECENT) : (i += 1) {
            if (rows[i].state == .proposed) continue;
            renderRecent(i, now);
            shown += 1;
        }
    }
}
