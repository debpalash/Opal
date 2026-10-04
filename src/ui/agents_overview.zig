//! The Overview tab on the Agents page: the front door of Opal. Three bands.
//!
//!   1. Automations: one card per thing Opal can do for you on its own, each with
//!      its switch (where one exists), a live one-line status and a link to where
//!      it is managed. This only surfaces switches and engines that already exist
//!      (Wanted, follow tracked shows, scheduled agent tasks, the background
//!      operator, auto subtitles, source repair); it adds no automation of its own.
//!   2. For you: poster rails (picks, continue watching, coming up) that reuse
//!      Home's cards.
//!   3. What your agents did lately: a merged, newest-first activity feed.
//!
//! Nothing here runs an agent or creates a task by itself: the example tasks only
//! prefill the Add form on the Tasks tab. Wording and the feed merge are in
//! `agents_overview_pure.zig`.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const components = @import("components.zig");
const home = @import("home.zig");
const wanted_ui = @import("../services/wanted_ui.zig");
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");
const io_global = @import("../core/io_global.zig");
const source_config = @import("../core/source_config.zig");
const wanted = @import("../services/wanted.zig");
const wanted_pure = @import("../services/wanted_pure.zig");
const tasks = @import("../services/agent_tasks.zig");
const tasks_pure = @import("../services/agent_tasks_pure.zig");
const tasks_view = @import("../services/agent_tasks_view_pure.zig");
const tasks_ui = @import("agent_tasks_ui.zig");
const operator = @import("../services/operator.zig");
const op_view = @import("../services/operator_view_pure.zig");
const pure = @import("../services/agents_overview_pure.zig");

// ── Hand-offs to the rest of the page ───────────────────────────────────

/// Another tab of the Agents page. The tab strip lives in agent_terminal.zig,
/// which asks for a pending request every frame (`takeGoto`).
pub const Goto = enum { tasks, activity };
var goto_request: ?Goto = null;

pub fn takeGoto() ?Goto {
    const g = goto_request;
    goto_request = null;
    return g;
}

fn open(target: pure.Target) void {
    switch (target) {
        .activity => goto_request = .activity,
        .tasks => goto_request = .tasks,
        .downloads => state.app.router.navigate(.downloads),
    }
    state.wakeUi();
}

// ── Extension points ────────────────────────────────────────────────────

/// EXTENSION POINT: "Ask Opal", a one-line request box. Another agent is building
/// it (branch v2/ask-opal). It sits at the very top of the Overview. To wire it,
/// call its render function here; nothing else needs to change.
pub fn renderAskSlot() void {}

/// EXTENSION POINT: the "Picked for you" rail, fed by the background operator's
/// `picks` job (branch v2/operator-2). Draw it with the same poster-card component
/// Home uses and return true when something was drawn, false when there is
/// nothing to show (no picks yet, operator off). The merge is then one line:
/// `return home.renderPicksRail(card_w);` (or the equivalent that branch exposes).
pub fn renderPicks(card_w: f32) bool {
    _ = card_w;
    return false;
}

// ── Data ────────────────────────────────────────────────────────────────

const WANTED_MAX: usize = 200;
const OPS_MAX: usize = 100;
const SHOWS_MAX: usize = 64;

var wanted_rows: [WANTED_MAX]wanted.Row = undefined;
var wanted_n: usize = 0;
var task_rows: [tasks_pure.MAX_TASKS]tasks.Row = undefined;
var task_n: usize = 0;
var op_rows: [OPS_MAX]operator.Row = undefined;
var op_n: usize = 0;
var spent_cents: u32 = 0;
var tracked_shows: usize = 0;
var repair_sources: usize = 0;
var show_rows: [SHOWS_MAX]db.TvShowRow = undefined;

// Derived from the rows above by `derive`.
var counts: pure.WantedCounts = .{};
var tasks_enabled_n: usize = 0;
var tasks_next_ms: i64 = 0;
var proposals: usize = 0;
var repair: pure.RepairCounts = .{};
var feed: [pure.FEED_MAX]pure.Event = undefined;
var feed_n: usize = 0;

var last_load_ms: i64 = 0;
var loaded = false;

/// Offline pixel tests render these instead of reading the database.
pub const Fixture = struct {
    wanted: []const wanted.Row = &.{},
    tasks: []const tasks.Row = &.{},
    ops: []const operator.Row = &.{},
    spent: u32 = 0,
    tracked: usize = 0,
    hide_entry: bool = false,
    sources: usize = 0,
};
var fixture_for_test: ?Fixture = null;

/// Offline pixel tests: show the bottom of the page (the activity feed).
pub fn scrollToEndForTest() void {
    if (!builtin.is_test) @compileError("test-only");
    scroll_info.scrollToOffset(.vertical, std.math.floatMax(f32));
}

pub fn setRenderFixtureForTest(fixture: ?Fixture) void {
    fixture_for_test = fixture;
    loaded = false;
}

fn refresh() void {
    const now = io_global.milliTimestamp();
    if (builtin.is_test) {
        if (fixture_for_test) |f| {
            wanted_n = @min(f.wanted.len, wanted_rows.len);
            @memcpy(wanted_rows[0..wanted_n], f.wanted[0..wanted_n]);
            task_n = @min(f.tasks.len, task_rows.len);
            @memcpy(task_rows[0..task_n], f.tasks[0..task_n]);
            op_n = @min(f.ops.len, op_rows.len);
            @memcpy(op_rows[0..op_n], f.ops[0..op_n]);
            spent_cents = f.spent;
            tracked_shows = f.tracked;
            repair_sources = f.sources;
            derive(now);
            return;
        }
    }
    if (loaded and now - last_load_ms < 1500) return;
    last_load_ms = now;
    loaded = true;
    wanted_n = wanted.snapshot(&wanted_rows);
    task_n = tasks.snapshot(&task_rows);
    op_n = operator.snapshot(&op_rows);
    spent_cents = operator.spentTodayCents();
    tracked_shows = db.tvGetShows(&show_rows);
    repair_sources = source_config.countField("base");
    derive(now);
}

var title_store: [WANTED_MAX][100]u8 = undefined;

/// Counts and the merged feed from the freshly loaded rows.
fn derive(now: i64) void {
    _ = now;
    counts = .{};
    var wanted_in: [WANTED_MAX]pure.WantedIn = undefined;
    for (wanted_rows[0..wanted_n], 0..) |*r, i| {
        counts.add(r.status);
        const label = pure.wantedLabel(&title_store[i], r.kind, r.title[0..@min(r.title_len, 60)], r.year, r.season, r.episode);
        wanted_in[i] = .{
            .status = r.status,
            .title = label,
            .when_ms = if (r.last_check_ms > 0) r.last_check_ms else r.added_ms,
        };
    }

    var task_in: [tasks_pure.MAX_TASKS]pure.TaskIn = undefined;
    tasks_enabled_n = 0;
    tasks_next_ms = 0;
    for (task_rows[0..task_n], 0..) |*r, i| {
        if (r.enabled) {
            tasks_enabled_n += 1;
            if (r.next_run_ms > 0 and (tasks_next_ms == 0 or r.next_run_ms < tasks_next_ms)) tasks_next_ms = r.next_run_ms;
        }
        task_in[i] = .{
            .name = r.name[0..@min(r.name_len, r.name.len)],
            .outcome = r.outcome[0..@min(r.outcome_len, r.outcome.len)],
            .summary = r.summary[0..@min(r.summary_len, r.summary.len)],
            .when_ms = r.last_run_ms,
        };
    }

    var op_in: [OPS_MAX]pure.OperatorIn = undefined;
    proposals = 0;
    repair = .{ .sources = repair_sources };
    for (op_rows[0..op_n], 0..) |*r, i| {
        if (r.state == .proposed) proposals += 1;
        if (r.kind == .endpoint_repair) switch (r.state) {
            .proposed => repair.proposed += 1,
            .applied => repair.applied += 1,
            .failed => repair.failed += 1,
            else => {},
        };
        op_in[i] = .{
            .state = r.state,
            .kind = r.kind,
            .summary = r.summary[0..@min(r.summary_len, r.summary.len)],
            .when_ms = if (r.finished_ms > 0) r.finished_ms else r.created_ms,
        };
    }
    feed_n = pure.mergeFeed(&feed, op_in[0..op_n], task_in[0..task_n], wanted_in[0..wanted_n]);
}

// ── Drawing helpers ─────────────────────────────────────────────────────

const MIN_CARD_W: f32 = 300;
const CARD_MARGIN: f32 = 6;
const CARD_PAD: f32 = 12;
const card_min_h: f32 = 120;
const FEED_ROW_H: f32 = 30;

fn smallFont() dvui.Font {
    var f = dvui.themeGet().font_body;
    f.size = theme.font_size.small;
    return f;
}

fn wrapText(src: std.builtin.SourceLocation, id: usize, text: []const u8, color: dvui.Color, small: bool, top: f32) void {
    var tl = dvui.textLayout(src, .{ .break_lines = true }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = false,
        .color_text = color,
        .font = if (small) smallFont() else dvui.themeGet().font_body,
        .margin = .{ .x = 0, .y = top, .w = 0, .h = 0 },
        .padding = dvui.Rect.all(0),
    });
    tl.addText(text, .{});
    tl.deinit();
}

fn sectionHeader(id: usize, glyph: []const u8, title: []const u8, sub: []const u8) void {
    var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .padding = .{ .x = 4, .y = 14, .w = 4, .h = 6 },
    });
    defer hdr.deinit();
    dvui.icon(@src(), title, glyph, .{}, .{
        .id_extra = id,
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{title}, .{
        .id_extra = id,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading.withSize(17),
        .gravity_y = 0.5,
    });
    if (sub.len > 0) {
        _ = dvui.label(@src(), "{s}", .{sub}, .{
            .id_extra = id,
            .color_text = theme.colors.text_tertiary,
            .font = smallFont(),
            .gravity_y = 0.5,
            .margin = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
        });
    }
}

fn cardBox(src: std.builtin.SourceLocation, id: usize, w: f32) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .vertical, // cards in one row share the tallest card's height
        .min_size_content = .{ .w = w - CARD_PAD * 2 - 2, .h = card_min_h },
        .max_size_content = .{ .w = w - CARD_PAD * 2 - 2, .h = std.math.floatMax(f32) },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .border = dvui.Rect.all(1),
        .color_border = theme.colors.border_subtle,
        .corner_radius = theme.dims.rad_sm,
        .padding = dvui.Rect.all(CARD_PAD),
        .margin = dvui.Rect.all(CARD_MARGIN),
    });
}

/// Title and status of a card that has no switch.
fn plainHeader(title: []const u8, status: []const u8) void {
    _ = dvui.label(@src(), "{s}", .{title}, .{
        .color_text = theme.colors.text_primary,
    });
    wrapText(@src(), 0, status, theme.colors.text_secondary, false, 2);
}

fn creditNote() void {
    wrapText(@src(), 0, pure.credit_note, theme.colors.text_tertiary, true, 4);
}

fn footerBegin() *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 8, .w = 0, .h = 0 },
    });
}

// ── Automation cards ────────────────────────────────────────────────────

fn wantedCard(w: f32, inner: f32) void {
    var card = cardBox(@src(), 1, w);
    defer card.deinit();
    var sb: [96]u8 = undefined;
    plainHeader("Wanted list", pure.wantedStatus(&sb, counts));
    // The offline capture backend blanks everything drawn after a text entry
    // (the Tasks form capture shows the same), so the fixture can hide it.
    if (!(builtin.is_test and fixture_for_test != null and fixture_for_test.?.hide_entry)) wanted_ui.renderAddBox(@max(120, inner - 110));
    var foot = footerBegin();
    defer foot.deinit();
    if (components.actionButton(@src(), "Manage", .secondary, 30001)) open(.downloads);
}

fn followCard(w: f32) void {
    var card = cardBox(@src(), 2, w);
    defer card.deinit();
    var sb: [96]u8 = undefined;
    const before = state.app.wanted_follow_tv;
    components.toggleRow(@src(), "Follow tracked shows", pure.followStatus(&sb, state.app.wanted_follow_tv, tracked_shows), &state.app.wanted_follow_tv);
    if (state.app.wanted_follow_tv != before) {
        wanted.setFollowTv(state.app.wanted_follow_tv);
        state.showToast(if (state.app.wanted_follow_tv) "Following tracked shows" else "Stopped following shows");
    }
    wrapText(@src(), 0, "Adds the newest aired episode of each show you track to the Wanted list.", theme.colors.text_tertiary, true, 4);
    var foot = footerBegin();
    defer foot.deinit();
    if (components.actionButton(@src(), "Manage", .secondary, 30002)) state.app.router.navigate(.watching);
}

fn tasksCard(w: f32) void {
    var card = cardBox(@src(), 3, w);
    defer card.deinit();
    var sb: [96]u8 = undefined;
    const now = io_global.milliTimestamp();
    const before = state.app.agent_tasks_enabled;
    components.toggleRow(@src(), "Scheduled agent tasks", pure.tasksStatus(&sb, state.app.agent_tasks_enabled, task_n, tasks_enabled_n, tasks_next_ms, now), &state.app.agent_tasks_enabled);
    if (state.app.agent_tasks_enabled != before) {
        tasks.setMasterEnabled(state.app.agent_tasks_enabled);
        state.showToast(if (state.app.agent_tasks_enabled) "Scheduled agent tasks on" else "Scheduled agent tasks off");
    }
    creditNote();
    // One-click starting points. They only fill in the Add form on the Tasks tab;
    // nothing is created until the user reviews the prompt and presses Add.
    _ = dvui.label(@src(), "Start from an example", .{}, .{
        .color_text = theme.colors.text_secondary,
        .font = smallFont(),
        .margin = .{ .x = 0, .y = 8, .w = 0, .h = 2 },
    });
    {
        var chips = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
        defer chips.deinit();
        for (tasks_view.examples, 0..) |e, i| {
            if (components.actionButton(@src(), e.name, .secondary, 30100 + i)) {
                tasks_ui.applyExample(e);
                open(.tasks);
            }
        }
    }
    var foot = footerBegin();
    defer foot.deinit();
    if (components.actionButton(@src(), "Add a task", .primary, 30003)) {
        tasks_ui.openNewForm();
        open(.tasks);
    }
    if (components.actionButton(@src(), "Manage", .secondary, 30004)) open(.tasks);
}

fn operatorCard(w: f32) void {
    var card = cardBox(@src(), 4, w);
    defer card.deinit();
    var sb: [128]u8 = undefined;
    const before = state.app.operator_enabled;
    components.toggleRow(@src(), "Background operator", pure.operatorStatus(&sb, state.app.operator_enabled, spent_cents, state.app.operator_daily_cents, proposals), &state.app.operator_enabled);
    if (state.app.operator_enabled != before) {
        operator.setEnabled(state.app.operator_enabled);
        state.showToast(if (state.app.operator_enabled) "Background operator on" else "Background operator off");
    }
    creditNote();
    dvui.progress(@src(), .{
        .percent = op_view.spendFraction(spent_cents, state.app.operator_daily_cents),
        .color = if (spent_cents >= state.app.operator_daily_cents) theme.colors.warning else theme.colors.accent,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 10, .h = 5 },
        .max_size_content = .{ .w = 100000, .h = 5 },
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = theme.dims.rad_sm,
        .margin = .{ .x = 0, .y = 8, .w = 0, .h = 0 },
    });
    var foot = footerBegin();
    defer foot.deinit();
    if (proposals > 0) {
        var lb: [40]u8 = undefined;
        const label = std.fmt.bufPrint(&lb, "Review {d} {s}", .{ proposals, if (proposals == 1) "proposal" else "proposals" }) catch "Review";
        if (components.actionButton(@src(), label, .primary, 30005)) open(.activity);
    }
    if (components.actionButton(@src(), "Manage", .secondary, 30006)) open(.activity);
}

fn subsCard(w: f32) void {
    var card = cardBox(@src(), 5, w);
    defer card.deinit();
    const before = state.app.auto_download_subs;
    components.toggleRow(@src(), "Auto subtitles", pure.subsStatus(state.app.auto_download_subs), &state.app.auto_download_subs);
    if (state.app.auto_download_subs != before) state.markConfigDirty();
    wrapText(@src(), 0, "Free: no agent and no account involved.", theme.colors.text_tertiary, true, 4);
    var foot = footerBegin();
    defer foot.deinit();
    if (components.actionButton(@src(), "Manage", .secondary, 30007)) {
        state.app.settings_tab = .Subtitles;
        state.app.router.navigate(.settings);
    }
}

fn repairCard(w: f32) void {
    var card = cardBox(@src(), 6, w);
    defer card.deinit();
    var sb: [128]u8 = undefined;
    plainHeader("Source repair", pure.repairStatus(&sb, state.app.operator_enabled, repair));
    wrapText(@src(), 0, "Part of the background operator. When a source keeps failing it asks your agent where it moved, and waits for your OK before changing anything.", theme.colors.text_tertiary, true, 4);
    var foot = footerBegin();
    defer foot.deinit();
    if (repair.proposed > 0) {
        if (components.actionButton(@src(), "Review fixes", .primary, 30008)) open(.activity);
    }
    if (components.actionButton(@src(), "Manage", .secondary, 30009)) state.app.router.navigate(.plugins);
}

fn automationsOn() usize {
    var n: usize = 0;
    if (state.app.wanted_follow_tv) n += 1;
    if (state.app.agent_tasks_enabled) n += 1;
    if (state.app.operator_enabled) n += 1;
    if (state.app.auto_download_subs) n += 1;
    return n;
}

fn renderAutomations(avail_w: f32) void {
    var sum: [40]u8 = undefined;
    sectionHeader(1, icons.tvg.lucide.zap, "Automations", pure.onSummary(&sum, automationsOn(), 4));

    const slot = MIN_CARD_W + CARD_MARGIN * 2;
    const cols: f32 = @max(1, @floor(avail_w / slot));
    const w: f32 = @max(200, @floor(avail_w / cols) - CARD_MARGIN * 2 - 1);
    const inner = w - CARD_PAD * 2 - 2;

    // Rows of fixed-width cards. (A flexbox lays cards out from the previous
    // frame's sizes and mis-sizes the one holding a text entry.)
    const card_count: usize = 6;
    const per_row: usize = @intFromFloat(cols);
    var i: usize = 0;
    var r: usize = 0;
    while (i < card_count) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = r, .expand = .horizontal });
        defer row.deinit();
        var k: usize = 0;
        while (k < per_row and i < card_count) : (k += 1) {
            switch (i) {
                0 => wantedCard(w, inner),
                1 => followCard(w),
                2 => tasksCard(w),
                3 => operatorCard(w),
                4 => subsCard(w),
                else => repairCard(w),
            }
            i += 1;
        }
    }
}

// ── For you ─────────────────────────────────────────────────────────────

fn renderForYou(avail_w: f32) void {
    sectionHeader(2, icons.tvg.lucide.sparkles, "For you", "");
    const card_w = std.math.clamp(avail_w / 6.5, 108, 150);
    var any = renderPicks(card_w);
    // Same one-refresh-per-session kick Home gives the calendar rail.
    if (!builtin.is_test and state.app.init_history_loaded) @import("../services/tv_calendar.zig").refreshOnce();
    if (home.renderLibraryContinueRail(card_w)) any = true;
    if (home.renderComingUpRail(card_w)) any = true;
    if (!any) {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 14, .y = 12, .w = 14, .h = 12 },
        });
        defer box.deinit();
        _ = dvui.label(@src(), "Nothing here yet", .{}, .{ .color_text = theme.colors.text_primary });
        wrapText(@src(), 0, "Start watching something and it shows up here to pick up where you left off. Track a show and its next episode appears under Coming up.", theme.colors.text_secondary, false, 2);
    }
}

// ── Activity feed ───────────────────────────────────────────────────────

var scroll_info: dvui.ScrollInfo = .{};

fn toneColor(tone: pure.Tone) dvui.Color {
    return switch (tone) {
        .muted => theme.colors.text_secondary,
        .active => theme.colors.accent,
        .good => theme.colors.success,
        .bad => theme.colors.danger,
    };
}

fn glyphFor(source: pure.Source) []const u8 {
    return switch (source) {
        .operator => icons.tvg.lucide.sparkles,
        .task => icons.tvg.lucide.@"calendar-clock",
        .wanted => icons.tvg.lucide.download,
    };
}

fn renderFeedRow(i: usize, now: i64, text_chars: usize) void {
    const e = &feed[i];
    var hovered = false;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = i,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        .min_size_content = .{ .w = 0, .h = FEED_ROW_H },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = FEED_ROW_H },
    });
    defer row.deinit();
    if (dvui.clicked(row.data(), .{ .hovered = &hovered })) open(e.target);
    if (hovered) {
        row.data().options.color_fill = theme.colors.bg_hover;
        row.drawBackground();
        dvui.cursorSet(.hand);
    }
    dvui.icon(@src(), "feed", glyphFor(e.source), .{}, .{
        .id_extra = i,
        .color_text = toneColor(e.tone),
        .min_size_content = .{ .w = 16, .h = 16 },
        .max_size_content = .{ .w = 16, .h = 16 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
    });
    var cut: [pure.TEXT_MAX + 4]u8 = undefined;
    _ = dvui.label(@src(), "{s}", .{tasks_view.summaryLine(&cut, e.line(), text_chars)}, .{
        .id_extra = i,
        .color_text = theme.colors.text_primary,
        .gravity_y = 0.5,
    });
    var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .gravity_x = 1.0, .gravity_y = 0.5 });
    defer meta.deinit();
    var tb: [24]u8 = undefined;
    _ = dvui.label(@src(), "{s}", .{op_view.relativeText(&tb, e.when_ms, now)}, .{
        .id_extra = i,
        .color_text = theme.colors.text_secondary,
        .font = smallFont(),
        .gravity_y = 0.5,
    });
}

fn renderFeed(avail_w: f32) void {
    sectionHeader(3, icons.tvg.lucide.history, "What your agents did lately", "");
    if (feed_n == 0) {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 14, .y = 12, .w = 14, .h = 12 },
        });
        defer box.deinit();
        _ = dvui.label(@src(), "Nothing yet", .{}, .{ .color_text = theme.colors.text_primary });
        wrapText(@src(), 0, "When your agents act, it shows up here: titles the Wanted list found or is downloading, scheduled task runs and how they went, and fixes the background operator applied or proposes. Turn on an automation above to get started.", theme.colors.text_secondary, false, 2);
        if (components.actionButton(@src(), "Show the switches", .secondary, 30200)) scroll_info.scrollToOffset(.vertical, 0);
        return;
    }
    const now = io_global.milliTimestamp();
    // Row text is cut to what fits on one line, so every row has the same height.
    const room = avail_w - 24 - 26 - 100;
    const chars: usize = @intFromFloat(std.math.clamp(room / 7.0, 24, @as(f32, pure.TEXT_MAX)));
    for (0..feed_n) |i| renderFeedRow(i, now, chars);
}

// ── Page ────────────────────────────────────────────────────────────────

/// Draw the Overview. Safe to call every frame.
pub fn render() void {
    refresh();

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &scroll_info, .horizontal = .none }, .{
        .expand = .both,
        .background = false,
    });
    defer scroll.deinit();
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 4, .w = 16, .h = 24 },
    });
    defer col.deinit();
    const measured = col.data().contentRect().w;
    const avail_w: f32 = if (measured > 120) measured else 600;

    renderAskSlot();
    renderAutomations(avail_w);
    renderForYou(avail_w);
    renderFeed(avail_w);
}
