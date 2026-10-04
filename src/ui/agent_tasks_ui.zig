//! The Tasks panel on the Agents page: scheduled prompts that run a coding agent
//! on a timer, unattended. Lists the tasks with their last result and next run,
//! lets the user run, pause or delete them, and adds new ones through the same
//! validation the HTTP API uses (`agent_tasks.add`).
//!
//! Nothing here runs an agent. The master switch (Settings > Agent Access) gates
//! every run, so the panel says plainly when it is off and offers to turn it on.
//! Wording and limits live in `agent_tasks_view_pure.zig`.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");
const state = @import("../core/state.zig");
const io_global = @import("../core/io_global.zig");
const tasks = @import("../services/agent_tasks.zig");
const pure = @import("../services/agent_tasks_pure.zig");
const view = @import("../services/agent_tasks_view_pure.zig");

const MAX_ROWS: usize = pure.MAX_TASKS;
const SUMMARY_SHOWN: usize = 140;

var rows: [MAX_ROWS]tasks.Row = undefined;
var row_count: usize = 0;
var last_load_ms: i64 = 0;
var dirty = true;

// The Add form. Plain zero-terminated buffers, like the other single-field inputs.
var form_open = false;
var form_ready = false;
var name_buf: [pure.NAME_MAX + 4]u8 = std.mem.zeroes([pure.NAME_MAX + 4]u8);
var prompt_buf: [pure.PROMPT_MAX + 1]u8 = std.mem.zeroes([pure.PROMPT_MAX + 1]u8);
var interval_buf: [8]u8 = std.mem.zeroes([8]u8);
var runs_buf: [4]u8 = std.mem.zeroes([4]u8);
var budget_buf: [8]u8 = std.mem.zeroes([8]u8);
var agent_index: usize = 0;
var message_buf: [200]u8 = undefined;
var message_len: usize = 0;

const agent_labels = [_][]const u8{ "Claude Code", "Codex" };
const agent_values = [_]tasks.Agent{ .claude, .codex };

/// Offline pixel tests render fixed rows instead of reading the database.
var fixture_for_test: ?[]const tasks.Row = null;

pub fn setRenderFixtureForTest(fixture: ?[]const tasks.Row) void {
    fixture_for_test = fixture;
    dirty = true;
}

fn refresh() void {
    if (@import("builtin").is_test) {
        if (fixture_for_test) |f| {
            row_count = @min(f.len, rows.len);
            @memcpy(rows[0..row_count], f[0..row_count]);
            return;
        }
    }
    const now = io_global.milliTimestamp();
    if (!dirty and now - last_load_ms < 1500) return;
    last_load_ms = now;
    dirty = false;
    row_count = tasks.snapshot(&rows);
}

// ── Form helpers ──

fn setField(buf: []u8, text: []const u8) void {
    @memset(buf, 0);
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
}

fn setNumber(buf: []u8, value: u32) void {
    var tmp: [12]u8 = undefined;
    setField(buf, std.fmt.bufPrint(&tmp, "{d}", .{value}) catch "");
}

fn resetForm() void {
    setField(&name_buf, "");
    setField(&prompt_buf, "");
    setNumber(&interval_buf, 1440);
    setNumber(&runs_buf, 2);
    setNumber(&budget_buf, 50);
    agent_index = 0;
    message_len = 0;
    form_ready = true;
}

fn say(text: []const u8) void {
    message_len = @min(text.len, message_buf.len);
    @memcpy(message_buf[0..message_len], text[0..message_len]);
}

fn applyExample(e: view.Example) void {
    resetForm();
    setField(&name_buf, e.name);
    setField(&prompt_buf, e.prompt);
    setNumber(&interval_buf, e.interval_min);
    setNumber(&runs_buf, e.max_runs_per_day);
    setNumber(&budget_buf, e.budget_cents);
    form_open = true;
}

fn submit() void {
    const interval = view.parseCount(std.mem.sliceTo(&interval_buf, 0)) orelse {
        say("Interval must be a whole number of minutes, 15 to 10080");
        return;
    };
    const runs = view.parseCount(std.mem.sliceTo(&runs_buf, 0)) orelse {
        say("Max runs per day must be a whole number, 1 to 24");
        return;
    };
    const budget = view.parseCount(std.mem.sliceTo(&budget_buf, 0)) orelse {
        say("Budget must be a whole number of cents, 5 to 1000");
        return;
    };
    const res = tasks.add(.{
        .name = std.mem.sliceTo(&name_buf, 0),
        .prompt = std.mem.sliceTo(&prompt_buf, 0),
        .agent = agent_values[@min(agent_index, agent_values.len - 1)],
        .interval_min = interval,
        .max_runs_per_day = runs,
        .budget_cents = budget,
    });
    switch (res) {
        .added => {
            state.showToastTyped("Task added", .success);
            resetForm();
            form_open = false;
            dirty = true;
        },
        .exists => say("A task with that name already exists"),
        .invalid => |why| say(why),
        .full => say("You already have the maximum number of tasks; delete one first"),
        .unavailable => say("Not available right now"),
    }
    state.wakeUi();
}

fn runNow(id: i64) void {
    switch (tasks.runNow(id)) {
        .queued => state.showToastTyped("Queued: it starts within a minute", .success),
        .no_such_task => state.showToastTyped("That task no longer exists", .warning),
        .switch_off => state.showToastTyped("Turn on scheduled tasks first", .warning),
        .capped => state.showToastTyped("Daily run limit reached for this task", .warning),
        .paused => state.showToastTyped("This task is paused: resume it first", .warning),
        .unavailable => state.showToastTyped("Not available right now", .warning),
    }
    dirty = true;
}

// ── Drawing ──

fn toneColor(tone: view.OutcomeKind.Tone) dvui.Color {
    return switch (tone) {
        .muted => theme.colors.text_secondary,
        .active => theme.colors.accent,
        .good => theme.colors.success,
        .bad => theme.colors.danger,
    };
}

/// A compact two-or-three way switch that sizes to its labels (the shared
/// `components.segment` is a flexbox that fills its row). Returns the index clicked.
pub fn compactSegment(src: std.builtin.SourceLocation, options: []const []const u8, selected: usize) ?usize {
    var clicked_index: ?usize = null;
    var bar = dvui.box(src, .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = theme.dims.rad_sm,
        .padding = dvui.Rect.all(2),
        // No gravity_y: in a vertical parent it floats to the middle of the panel.
    });
    defer bar.deinit();
    for (options, 0..) |opt, i| {
        const active = i == selected;
        var hovered = false;
        var seg = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .background = true,
            .color_fill = if (active) theme.colors.bg_elevated else theme.transparent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
            .margin = dvui.Rect.all(1),
        });
        defer seg.deinit();
        if (dvui.clicked(seg.data(), .{ .hovered = &hovered })) clicked_index = i;
        if (hovered and !active) seg.data().options.color_fill = theme.colors.bg_hover;
        seg.drawBackground();
        _ = dvui.label(@src(), "{s}", .{opt}, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .color_text = if (active) theme.colors.text_primary else theme.colors.text_secondary,
        });
    }
    return clicked_index;
}

/// The Terminal | Tasks | Activity switch for the Agents toolbar. `activity_label`
/// carries the count of proposals waiting ("Activity 1"). Returns the index clicked.
pub fn tabSwitch(selected: usize, activity_label: []const u8) ?usize {
    // The toolbar is a horizontal box, where centring vertically is safe.
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
    defer row.deinit();
    return compactSegment(@src(), &.{ "Terminal", "Tasks", activity_label }, selected);
}

fn entry(src: std.builtin.SourceLocation, buf: []u8, placeholder: []const u8, width: f32) void {
    var te = dvui.textEntry(src, .{ .text = .{ .buffer = buf }, .placeholder = placeholder }, .{
        .min_size_content = .{ .w = width, .h = components.TOOLBAR_INPUT_H },
        .max_size_content = .{ .w = width, .h = components.TOOLBAR_INPUT_H },
        .color_fill = theme.colors.bg_elevated,
        .color_border = theme.colors.border_subtle,
        .color_text = theme.colors.text_primary,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .gravity_y = 0.5,
    });
    te.deinit();
}

fn fieldLabel(src: std.builtin.SourceLocation, text: []const u8) void {
    _ = dvui.label(src, "{s}", .{text}, .{
        .color_text = theme.colors.text_secondary,
        .min_size_content = .{ .w = 150, .h = 0 },
        .gravity_y = 0.5,
    });
}

fn renderBanner() void {
    if (state.app.agent_tasks_enabled) return;
    var banner = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .border = dvui.Rect.all(1),
        .color_border = theme.colors.warning,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 12 },
    });
    defer banner.deinit();
    _ = dvui.label(@src(), "Scheduled tasks are switched off", .{}, .{ .color_text = theme.colors.text_primary });
    _ = dvui.label(@src(), "Tasks never run until you turn this on. Each run starts a coding agent that uses your own subscription or API credit, within the daily limit and budget of the task. You can change this any time in Settings > Agent Access.", .{}, .{
        .color_text = theme.colors.text_secondary,
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 8 },
    });
    if (components.actionButton(@src(), "Turn on scheduled tasks", .primary, 9700)) {
        tasks.setMasterEnabled(true);
        state.showToastTyped("Scheduled agent tasks on", .success);
        dirty = true;
    }
}

fn renderHeader() void {
    var head = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });
    defer head.deinit();
    var title: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&title, "Scheduled tasks ({d})", .{row_count}) catch "Scheduled tasks";
    _ = dvui.label(@src(), "{s}", .{text}, .{ .color_text = theme.colors.text_primary, .gravity_y = 0.5, .font = dvui.Font.theme(.title) });
    var right = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
    defer right.deinit();
    if (components.actionButton(@src(), if (form_open) "Close form" else "New task", if (form_open) .secondary else .primary, 9701)) {
        if (!form_open and !form_ready) resetForm();
        form_open = !form_open;
    }
}

fn renderEmpty() void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 14, .y = 12, .w = 14, .h = 12 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 12 },
    });
    defer box.deinit();
    _ = dvui.label(@src(), "No scheduled tasks yet", .{}, .{ .color_text = theme.colors.text_primary });
    _ = dvui.label(@src(), "A task is a prompt a coding agent runs by itself on a timer, with the opal tools connected. Start from an example and adjust it, or write your own.", .{}, .{
        .color_text = theme.colors.text_secondary,
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 8 },
    });
    var line = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
    defer line.deinit();
    for (view.examples, 0..) |e, i| {
        if (components.actionButton(@src(), e.title, .secondary, 9710 + i)) applyExample(e);
    }
}

fn renderForm() void {
    if (!form_ready) resetForm();
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .border = dvui.Rect.all(1),
        .color_border = theme.colors.border_subtle,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 14, .y = 12, .w = 14, .h = 12 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 12 },
    });
    defer card.deinit();

    _ = dvui.label(@src(), "New task", .{}, .{ .color_text = theme.colors.text_primary, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 } });

    {
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 } });
        defer r.deinit();
        fieldLabel(@src(), "Name");
        entry(@src(), &name_buf, "Daily digest", 320);
    }
    {
        var r = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 } });
        defer r.deinit();
        _ = dvui.label(@src(), "What should the agent do? Nobody can answer questions during a run, so be specific.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 3 },
        });
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &prompt_buf },
            .placeholder = "Use the opal tools to ... End with one line saying what you found.",
            .multiline = true,
            .break_lines = true,
        }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 96 },
            .max_size_content = .{ .w = 100000, .h = 160 },
            .color_fill = theme.colors.bg_elevated,
            .color_border = theme.colors.border_subtle,
            .color_text = theme.colors.text_primary,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        });
        te.deinit();
    }
    {
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 6, .w = 0, .h = 2 } });
        defer r.deinit();
        fieldLabel(@src(), "Agent");
        if (compactSegment(@src(), &agent_labels, agent_index)) |i| agent_index = i;
    }
    {
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 } });
        defer r.deinit();
        fieldLabel(@src(), "Every (minutes)");
        entry(@src(), &interval_buf, "1440", 80);
        var text_buf: [40]u8 = undefined;
        const current = view.parseCount(std.mem.sliceTo(&interval_buf, 0));
        const shown: []const u8 = if (current) |m| view.intervalText(&text_buf, m) else "";
        _ = dvui.label(@src(), "{s}", .{shown}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5, .margin = .{ .x = 8, .y = 0, .w = 12, .h = 0 } });
        for (view.interval_presets, 0..) |p, i| {
            if (components.actionButton(@src(), p.label, .secondary, 9730 + i)) setNumber(&interval_buf, p.minutes);
        }
    }
    {
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 } });
        defer r.deinit();
        fieldLabel(@src(), "Max runs per day");
        entry(@src(), &runs_buf, "2", 80);
        _ = dvui.label(@src(), "1 to 24. Every run counts, including Run now.", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5, .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 } });
    }
    {
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 } });
        defer r.deinit();
        fieldLabel(@src(), "Budget (cents)");
        entry(@src(), &budget_buf, "50", 80);
        _ = dvui.label(@src(), "5 to 1000 per run. A hard spending cap for Claude Code; Codex runs in a read-only sandbox.", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5, .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 } });
    }

    if (message_len > 0) {
        _ = dvui.label(@src(), "{s}", .{message_buf[0..message_len]}, .{
            .color_text = theme.colors.danger,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 6, .w = 0, .h = 0 },
        });
    }
    {
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 8, .w = 0, .h = 0 } });
        defer r.deinit();
        if (components.actionButton(@src(), "Add task", .primary, 9740)) submit();
        if (components.actionButton(@src(), "Cancel", .secondary, 9741)) {
            form_open = false;
            message_len = 0;
        }
    }
}

fn renderRow(i: usize, now: i64) void {
    const r = &rows[i];
    const master = state.app.agent_tasks_enabled;

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 14, .y = 10, .w = 14, .h = 10 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });
    defer card.deinit();

    // Line 1: name and agent on the left, the actions on the right.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer line.deinit();
        var shown_name: [48]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{view.summaryLine(&shown_name, r.name[0..@min(r.name_len, r.name.len)], 44)}, .{
            .color_text = if (r.enabled) theme.colors.text_primary else theme.colors.text_secondary,
            .gravity_y = 0.5,
        });
        _ = dvui.label(@src(), "{s}", .{agent_labels[if (r.agent == .codex) 1 else 0]}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
        });
        var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
        defer acts.deinit();
        if (components.actionButton(@src(), "Run now", .secondary, 9800 + i)) runNow(r.id);
        if (components.actionButton(@src(), if (r.enabled) "Pause" else "Resume", .secondary, 9900 + i)) {
            _ = tasks.setEnabled(r.id, !r.enabled);
            dirty = true;
        }
        // Keyed by the task id, not the row position: after another row is deleted the
        // list shifts, and a position-keyed "click again to confirm" would land on a
        // different task.
        if (components.confirmDangerButton(@src(), "Delete", 10000 + @as(usize, @intCast(@mod(r.id, 1_000_000))))) {
            _ = tasks.remove(r.id);
            state.showToast("Task deleted");
            dirty = true;
        }
    }

    // Line 2: how often, how much, and when next.
    {
        var a: [40]u8 = undefined;
        var b: [32]u8 = undefined;
        var c: [24]u8 = undefined;
        var d: [48]u8 = undefined;
        var e: [48]u8 = undefined;
        var f: [48]u8 = undefined;
        var detail: [220]u8 = undefined;
        const spend: []const u8 = if (r.agent == .claude)
            std.fmt.bufPrint(&c, "{s} budget per run", .{view.dollarsText(&b, r.budget_cents)}) catch ""
        else
            "read-only sandbox";
        const text = std.fmt.bufPrint(&detail, "{s}  |  {s}  |  {s}  |  next: {s}  |  {s}", .{
            view.intervalText(&a, r.interval_min),
            view.runsText(&d, r.runs_today, r.max_runs_per_day),
            spend,
            view.nextRunText(&e, r.enabled, master, r.running, r.next_run_ms, now),
            view.lastRunText(&f, r.last_run_ms, now),
        }) catch "";
        _ = dvui.label(@src(), "{s}", .{text}, .{
            .color_text = theme.colors.text_secondary,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
    }

    // Line 3: what the task will do, in full, so it can be reviewed.
    if (r.prompt_len > 0) {
        var tl = dvui.textLayout(@src(), .{ .break_lines = true }, .{
            .expand = .horizontal,
            .background = false,
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
        defer tl.deinit();
        tl.addText("Prompt: ", .{ .color_text = theme.colors.text_secondary });
        var shown_prompt: [tasks.Row.prompt_capacity + 8]u8 = undefined;
        tl.addText(@import("../core/text.zig").safeUtf8Buf(r.prompt[0..@min(r.prompt_len, r.prompt.len)], &shown_prompt), .{ .color_text = theme.colors.text_primary });
    }

    // Line 4: the last outcome, coloured, and the agent's closing line.
    {
        const outcome = view.OutcomeKind.parse(r.outcome[0..@min(r.outcome_len, r.outcome.len)]);
        var sbuf: [SUMMARY_SHOWN]u8 = undefined;
        const summary = view.summaryLine(&sbuf, r.summary[0..@min(r.summary_len, r.summary.len)], SUMMARY_SHOWN);
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 } });
        defer line.deinit();
        _ = dvui.label(@src(), "{s}", .{outcome.label()}, .{ .color_text = toneColor(outcome.tone()), .gravity_y = 0.0 });
        if (summary.len > 0) {
            _ = dvui.label(@src(), "{s}", .{summary}, .{
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
                .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
            });
        }
    }
}

/// Offline pixel tests: set the form state without clicking.
pub fn setFormForTest(open: bool, message: []const u8) void {
    if (!@import("builtin").is_test) @compileError("test-only");
    form_ready = false;
    form_open = open;
    if (open) resetForm();
    say(message);
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

    renderBanner();
    renderHeader();
    if (row_count == 0 and !form_open) renderEmpty();
    if (form_open) renderForm();

    var i: usize = 0;
    while (i < row_count) : (i += 1) renderRow(i, now);
}
