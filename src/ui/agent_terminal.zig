//! The Agents page: coding agents (Claude Code, Codex, Gemini CLI) or a plain
//! shell running inside Opal, in a terminal drawn by libghostty-vt.
//!
//! The terminal state lives in `terminal/session.zig`; this file starts
//! sessions in the Opal workspace (already wired to the opal MCP server), draws
//! the cell grid with dvui, and turns key, text, mouse and clipboard events into
//! bytes for the program. While the terminal has focus it owns the keyboard, so
//! Opal's single-key shortcuts stay quiet; click outside it to get them back.

const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const alloc = @import("../core/alloc.zig").allocator;
const session_mod = @import("../terminal/session.zig");
const pointer = @import("../terminal/pointer.zig");
const keymap = @import("../terminal/keymap.zig");
const launch = @import("../services/agent_launch.zig");
const launch_pure = @import("../services/agent_launch_pure.zig");
const tasks_ui = @import("agent_tasks_ui.zig");
const operator_ui = @import("operator_ui.zig");
const operator_view = @import("../services/operator_view_pure.zig");

const tabs = @import("../terminal/tabs_pure.zig");

const Session = session_mod.Session;
const FONT_SIZE: f32 = 13;
const SCROLL_ROWS_PER_NOTCH: f32 = 3;

pub const Kind = tabs.Kind;

/// One terminal session and what the page remembers about it. Only the active
/// tab is drawn and gets input; the others keep running in the background.
const Tab = struct {
    session: *Session,
    snap: session_mod.Snapshot = .{},
    kind: Kind,
    /// Which "Shell 2" this is among the open tabs of its kind.
    ordinal: u8,
    /// Never reused: keeps the widget ids of two tabs apart.
    serial: usize,
    marker: tabs.Marker = .none,
    title_hash: u64 = 0,
    exit_seen: bool = false,
    /// Set when the tab becomes active: the next frame hands it keyboard focus.
    want_focus: bool = true,
};

var tab_list: [tabs.MAX_TABS]Tab = undefined;
var tab_count: usize = 0;
var cur: usize = 0;
var next_serial: usize = 1;

/// The active tab's snapshot while it is drawn (see `renderTerminal`); the
/// drawing and input code below reads it as `snap`.
var empty_snap: session_mod.Snapshot = .{};
var snap: *session_mod.Snapshot = &empty_snap;
/// The size of the last drawn terminal, so a new tab starts at about the right size.
var last_cols: u16 = 0;
var last_rows: u16 = 0;
var term_id: ?dvui.Id = null;
/// What the left button is doing since it went down inside the terminal.
const Drag = enum { none, select, report, scrollbar };
var drag: Drag = .none;
var pressed_button: ?pointer.Button = null;
var was_focused: bool = false;
var ime: keymap.ImeGuard = .{};
var frame_guard: pointer.FrameGuard = .{};
/// While dragging the scrollbar: where in the thumb it was grabbed, and the
/// offset last asked for (the snapshot lags a frame behind).
var sb_grab: f32 = 0;
var sb_offset: i64 = 0;
const SB_WIDTH: f32 = 6;
const SB_HIT: f32 = 14;
var view: enum { terminal, tasks, activity } = .terminal;
var note_buf: [128]u8 = undefined;
var note_len: usize = 0;

fn say(text: []const u8) void {
    note_len = @min(text.len, note_buf.len);
    @memcpy(note_buf[0..note_len], text[0..note_len]);
}

fn agentOf(kind: Kind) ?launch.Agent {
    return switch (kind) {
        .claude => .claude,
        .codex => .codex,
        .gemini => .gemini,
        .shell => null,
    };
}

/// Install the repaint hook once; the reader thread calls it on new output.
fn installWake() void {
    session_mod.wake_hook = struct {
        fn wake() void {
            state.wakeUi();
        }
    }.wake;
}

/// End every session (the app is quitting).
pub fn shutdown() void {
    for (tab_list[0..tab_count]) |*t| {
        t.session.deinit();
        t.snap.deinit(alloc);
    }
    tab_count = 0;
    cur = 0;
    snap = &empty_snap;
    term_id = null;
}

/// True while the active terminal has keyboard focus. Opal's global shortcuts
/// must leave keys alone then, or Ctrl+W (delete word) would close the window.
pub fn capturesKeyboard() bool {
    const id = term_id orelse return false;
    // dvui keeps focus on a widget that stopped rendering (the agent opened the
    // player, say); only a terminal that is still on screen owns the keys.
    if (!frame_guard.alive(dvui.frameTimeNS())) return false;
    return tab_count > 0 and dvui.focusedWidgetId() == id;
}

fn start(kind: Kind) void {
    if (!session_mod.supported) {
        say("The embedded terminal is not available on this platform yet");
        return;
    }
    if (!tabs.canAdd(tab_count)) {
        say("At most 6 terminals can be open at once. Close one first.");
        return;
    }
    if (agentOf(kind)) |agent| {
        if (!launch.installed(agent)) {
            say("That agent is not installed (not on PATH)");
            return;
        }
    }
    var ws: launch.Workspace = .{};
    if (launch.prepareWorkspace(&ws) != .started) {
        say("Could not create the agent workspace");
        return;
    }
    // POSIX: `sh -c <script>`. Windows: one raw command line (no /bin/sh); agents
    // go through cmd.exe, which runs npm's .cmd shims, and the plain shell is
    // PowerShell.
    const is_windows = @import("builtin").os.tag == .windows;
    var script_buf: [8192]u8 = undefined;
    const script = (if (agentOf(kind)) |agent|
        (if (is_windows)
            launch_pure.windowsAgentCommand(&script_buf, .cmd, agent, ws.path(), ws.mcpPath(), ws.tokenFile())
        else
            launch_pure.agentScript(&script_buf, agent, ws.path(), ws.mcpPath(), ws.tokenFile()))
    else if (is_windows)
        launch_pure.windowsShellCommand(&script_buf, .powershell, ws.path())
    else
        launch_pure.shellScript(&script_buf, ws.path())) orelse {
        say("A path contains a character that cannot be quoted safely");
        return;
    };

    installWake();
    const cols: u16 = if (last_cols > 0) last_cols else 100;
    const rows: u16 = if (last_rows > 0) last_rows else 30;
    const argv: []const []const u8 = if (is_windows) &.{script} else &.{ "/bin/sh", "-c", script };
    const session = Session.start(alloc, argv, cols, rows) catch |err| {
        say(switch (err) {
            error.Unsupported => "The embedded terminal is not available on this platform yet",
            else => "Could not start the terminal",
        });
        return;
    };
    var open: [tabs.MAX_TABS]tabs.Named = undefined;
    for (tab_list[0..tab_count], 0..) |t, i| open[i] = .{ .kind = t.kind, .ordinal = t.ordinal };
    tab_list[tab_count] = .{
        .session = session,
        .kind = kind,
        .ordinal = tabs.nextOrdinal(open[0..tab_count], kind),
        .serial = next_serial,
    };
    next_serial += 1;
    tab_count += 1;
    activate(tab_count - 1);
    note_len = 0;
    state.wakeUi();
}

/// Show tab `i`. The tab left behind keeps running; a program that asked for
/// focus reports hears that it lost focus.
fn activate(i: usize) void {
    if (i >= tab_count) return;
    if (i != cur and cur < tab_count and was_focused) {
        tab_list[cur].session.sendFocus(false);
    }
    was_focused = false;
    ime.reset();
    drag = .none;
    pressed_button = null;
    cur = i;
    tab_list[i].marker = .none;
    tab_list[i].want_focus = true;
    state.wakeUi();
}

/// Close tab `i`: the session ends and its tab goes away.
fn closeTab(i: usize) void {
    if (i >= tab_count) return;
    const was_active = i == cur;
    tab_list[i].session.deinit();
    tab_list[i].snap.deinit(alloc);
    var k = i;
    while (k + 1 < tab_count) : (k += 1) tab_list[k] = tab_list[k + 1];
    const before = tab_count;
    tab_count -= 1;
    // `snap` may have pointed into the moved array: renderTerminal sets it again.
    snap = &empty_snap;
    ime.reset();
    drag = .none;
    pressed_button = null;
    if (tab_count == 0) {
        cur = 0;
        term_id = null;
        was_focused = false;
    } else {
        cur = tabs.activeAfterClose(before, i, cur) orelse 0;
        if (was_active) {
            was_focused = false;
            tab_list[cur].want_focus = true;
            tab_list[cur].marker = .none;
        }
    }
    state.wakeUi();
}

pub fn render() void {
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_app,
    });
    defer page.deinit();

    renderToolbar();

    switch (view) {
        .tasks => {
            tasks_ui.render();
            return;
        },
        .activity => {
            operator_ui.render();
            return;
        },
        .terminal => {},
    }
    if (tab_count == 0) {
        renderEmpty();
        return;
    }
    pollTabs();
    renderTabStrip();
    if (tab_count == 0) {
        renderEmpty();
        return;
    }
    renderTerminal(&tab_list[cur]);
}

fn renderToolbar() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.colors.border_subtle,
    });
    defer bar.deinit();

    _ = dvui.label(@src(), "Agents", .{}, .{
        .color_text = theme.colors.text_primary,
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 12, .h = 0 },
    });

    var tab_label: [24]u8 = undefined;
    const activity_label = operator_view.tabLabel(&tab_label, operator_ui.pendingCount());
    if (tasks_ui.tabSwitch(@intFromEnum(view), activity_label)) |i| view = @enumFromInt(i);
    if (view != .terminal) return;

    if (note_len > 0) {
        _ = dvui.label(@src(), "{s}", .{note_buf[0..note_len]}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .margin = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
        });
    }
}

/// Once a frame: bells and titles of every tab, so a bell in a background tab or
/// a program that changed its title shows up on the tab.
fn pollTabs() void {
    for (tab_list[0..tab_count], 0..) |*t, i| {
        const bell = t.session.takeBell();
        var title_buf: [128]u8 = undefined;
        const raw = t.session.titleSlice();
        const n = @min(raw.len, title_buf.len);
        @memcpy(title_buf[0..n], raw[0..n]);
        const h = std.hash.Wyhash.hash(0, title_buf[0..n]);
        const exited = t.session.isExited();
        const changed = h != t.title_hash or (exited and !t.exit_seen);
        t.title_hash = h;
        t.exit_seen = exited;
        if (i == cur and bell) state.showToast("Terminal bell");
        t.marker = tabs.markerAfter(t.marker, i == cur, bell, changed);
    }
}

/// Width of the tab strip last frame, in natural units (0 before the first).
var strip_avail: f32 = 0;

const transparent: dvui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

fn renderTabStrip() void {
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_deep,
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 0 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.colors.border_subtle,
    });
    defer strip.deinit();

    var select: ?usize = null;
    var close: ?usize = null;
    const budget = tabs.labelMaxFit(tab_count, strip_avail, dvui.Font.theme(.body).textSize("n").w);
    strip_avail = strip.data().contentRect().w;

    // First, so it stays reachable when the tabs run out of room.
    if (tabs.canAdd(tab_count)) {
        var m = dvui.menu(@src(), .horizontal, .{ .gravity_y = 0.5 });
        defer m.deinit();
        if (dvui.menuItemLabel(@src(), "+", .{ .submenu = true }, .{
            .color_text = theme.colors.text_secondary,
            .color_fill = transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
        })) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            var menu = dvui.menu(@src(), .vertical, .{
                .background = true,
                .color_fill = theme.colors.bg_surface,
                .border = dvui.Rect.all(1),
                .color_border = theme.colors.border_subtle,
            });
            defer menu.deinit();
            for (tabs.kinds, 0..) |kind, k| {
                var buf: [48]u8 = undefined;
                const missing = if (agentOf(kind)) |agent| !launch.installed(agent) else false;
                const text = std.fmt.bufPrint(&buf, "{s}{s}", .{ tabs.kindTitle(kind), if (missing) " (not installed)" else "" }) catch tabs.kindTitle(kind);
                if (dvui.menuItemLabel(@src(), text, .{}, .{
                    .id_extra = k,
                    .expand = .horizontal,
                    .color_text = if (missing) theme.colors.text_tertiary else theme.colors.text_primary,
                })) |_| {
                    start(kind);
                    // start() activated the new tab; the indices above are stale.
                    return;
                }
            }
        }
    } else {
        _ = dvui.label(@src(), "6 of 6", .{}, .{
            .color_text = theme.colors.text_tertiary,
            .gravity_y = 0.5,
            .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
        });
    }

    for (tab_list[0..tab_count], 0..) |*t, i| {
        const is_active = i == cur;
        var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = t.serial,
            .background = true,
            .color_fill = if (is_active) theme.colors.bg_app else transparent,
            .corner_radius = .{ .x = 6, .y = 6, .w = 0, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
            .border = if (is_active) .{ .x = 0, .y = 2, .w = 0, .h = 0 } else dvui.Rect.all(0),
            .color_border = theme.colors.accent,
        });
        defer cell.deinit();

        switch (t.marker) {
            .none => {},
            .title, .bell => {
                var dot = dvui.box(@src(), .{}, .{
                    .id_extra = t.serial,
                    .min_size_content = .{ .w = 7, .h = 7 },
                    .max_size_content = .{ .w = 7, .h = 7 },
                    .background = true,
                    .color_fill = if (t.marker == .bell) theme.colors.accent else theme.colors.text_tertiary,
                    .corner_radius = dvui.Rect.all(4),
                    .gravity_y = 0.5,
                    .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
                });
                dot.deinit();
            },
        }

        var base_buf: [32]u8 = undefined;
        var title_buf: [128]u8 = undefined;
        var label_buf: [64]u8 = undefined;
        const raw = t.session.titleSlice();
        const n = @min(raw.len, title_buf.len);
        @memcpy(title_buf[0..n], raw[0..n]);
        const text = tabs.label(&label_buf, tabs.baseName(&base_buf, t.kind, t.ordinal), title_buf[0..n], t.session.isExited(), budget);
        if (dvui.button(@src(), text, .{}, .{
            .id_extra = t.serial,
            .color_fill = transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .color_fill_press = theme.colors.bg_surface,
            .color_text = if (is_active) theme.colors.text_primary else theme.colors.text_secondary,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(0),
            .padding = .{ .x = 10, .y = 5, .w = 4, .h = 5 },
            .margin = dvui.Rect.all(0),
            .gravity_y = 0.5,
        })) select = i;
        if (dvui.button(@src(), "x", .{}, .{
            .id_extra = t.serial,
            .color_fill = transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .color_fill_press = theme.colors.bg_surface,
            .color_text = theme.colors.text_secondary,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(0),
            .padding = .{ .x = 6, .y = 5, .w = 8, .h = 5 },
            .margin = dvui.Rect.all(0),
            .gravity_y = 0.5,
        })) close = i;
    }

    // Applied after the strip is built, so the loop above never sees a tab vanish.
    if (close) |i| {
        closeTab(i);
    } else if (select) |i| {
        if (i != cur) activate(i);
    }
}

fn renderEmpty() void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .padding = .{ .x = 24, .y = 40, .w = 24, .h = 24 },
    });
    defer col.deinit();
    _ = dvui.label(@src(), "Run a coding agent right here", .{}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.Font.theme(.title),
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
    });
    _ = dvui.label(@src(), "Opens in Opal's workspace with the opal tools already connected.", .{}, .{
        .color_text = theme.colors.text_secondary,
        .gravity_x = 0.5,
    });
    _ = dvui.label(@src(), "While a terminal has focus it gets every key. Press Ctrl+Shift+Esc to give the keyboard back to Opal.", .{}, .{
        .color_text = theme.colors.text_secondary,
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 6, .w = 0, .h = 16 },
    });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
        defer row.deinit();
        inline for (tabs.kinds, 0..) |kind, i| {
            if (components.actionButton(@src(), tabs.kindTitle(kind), if (kind == .claude) .primary else .secondary, 9500 + i)) start(kind);
        }
    }
    _ = dvui.label(@src(), "Open up to six at once and switch between them with the tabs.", .{}, .{
        .color_text = theme.colors.text_tertiary,
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 10, .w = 0, .h = 0 },
    });
    if (!session_mod.supported) {
        _ = dvui.label(@src(), "The embedded terminal is not available on this platform yet. Use Settings > Agent Access to open an agent in your own terminal.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = 12, .w = 0, .h = 0 },
        });
    }
}

// ── The terminal itself ──

fn toColor(c: session_mod.Rgb) dvui.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
}

fn font(bold: bool, italic: bool) dvui.Font {
    return dvui.Font.find(.{
        .family = theme.mono_font_family,
        .size = FONT_SIZE,
        .weight = if (bold) .bold else .normal,
        .style = if (italic) .italic else .normal,
    });
}

fn sameStyle(a: *const session_mod.Cell, b: *const session_mod.Cell) bool {
    return std.meta.eql(a.fg, b.fg) and a.bold == b.bold and a.italic == b.italic;
}

fn isAscii(cell: *const session_mod.Cell) bool {
    return cell.len == 1 and cell.utf8[0] >= 0x20 and cell.utf8[0] < 0x7f;
}

fn renderTerminal(t: *Tab) void {
    const s = t.session;
    snap = &t.snap;
    var area = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = t.serial,
        .expand = .both,
        .background = true,
        .color_fill = toColor(snap.default_bg),
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
    });
    defer area.deinit();
    const wd = area.data();
    term_id = wd.id;
    frame_guard.markRendered(dvui.frameTimeNS());
    if (t.want_focus) {
        t.want_focus = false;
        drag = .none;
        pressed_button = null;
        was_focused = false;
        dvui.focusWidget(wd.id, null, null);
    }

    const rs = wd.contentRectScale();
    const base = font(false, false);
    const cell_nat = base.textSize("M");
    const cw = @max(1, cell_nat.w * rs.s);
    const ch = @max(1, base.textHeight() * rs.s);

    const cols: u16 = @intFromFloat(std.math.clamp(@floor(rs.r.w / cw), 10, 400));
    const rows: u16 = @intFromFloat(std.math.clamp(@floor(rs.r.h / ch), 3, 200));
    s.resize(cols, rows, @intFromFloat(cw), @intFromFloat(ch));
    last_cols = cols;
    last_rows = rows;

    handleEvents(s, wd, rs.r, cw, ch);

    // Programs that asked for focus reports (DEC 1004) hear about gains and losses.
    const focused = dvui.focusedWidgetId() == wd.id;
    if (focused != was_focused) {
        was_focused = focused;
        if (!focused) ime.reset();
        s.sendFocus(focused);
    }

    _ = s.snapshot(snap);
    if (snap.cols == 0 or snap.cells.len == 0) return;

    // The input method puts its candidate window by this rectangle: the cursor cell.
    if (focused) {
        const cur_r = rect(rs, @as(f32, @floatFromInt(snap.cursor_x)) * cw, @as(f32, @floatFromInt(snap.cursor_y)) * ch, cw, ch);
        dvui.wantTextInput(cur_r.toNatural());
    }

    {
        const prev_clip = dvui.clip(rs.r);
        defer dvui.clipSet(prev_clip);
        drawGrid(rs, cw, ch, focused);
        drawScrollbar(rs.r, rs.s, drag == .scrollbar);
    }
    if (focused) drawFocusRing(wd.borderRectScale());
}

/// A 1px accent outline just inside the terminal's edge while it has focus.
fn drawFocusRing(brs: dvui.RectScale) void {
    const none = dvui.Rect.Physical.all(0);
    const t = @max(1, @round(brs.s));
    const r = brs.r;
    const color = theme.colors.accent;
    (dvui.Rect.Physical{ .x = r.x, .y = r.y, .w = r.w, .h = t }).fill(none, .{ .color = color });
    (dvui.Rect.Physical{ .x = r.x, .y = r.y + r.h - t, .w = r.w, .h = t }).fill(none, .{ .color = color });
    (dvui.Rect.Physical{ .x = r.x, .y = r.y, .w = t, .h = r.h }).fill(none, .{ .color = color });
    (dvui.Rect.Physical{ .x = r.x + r.w - t, .y = r.y, .w = t, .h = r.h }).fill(none, .{ .color = color });
}

fn rect(rs: dvui.RectScale, x: f32, y: f32, w: f32, h: f32) dvui.Rect.Physical {
    return .{ .x = rs.r.x + x, .y = rs.r.y + y, .w = w, .h = h };
}

fn drawGrid(rs: dvui.RectScale, cw: f32, ch: f32, focused: bool) void {
    const cols = snap.cols;
    const rows = snap.rows;
    const none = dvui.Rect.Physical.all(0);
    const selection_bg = theme.colors.accent;

    for (0..rows) |y| {
        const fy = @as(f32, @floatFromInt(y)) * ch;

        // Backgrounds, coalesced into runs of one colour.
        var x: usize = 0;
        while (x < cols) {
            const cell = snap.cell(x, y);
            if (!cell.has_bg and !cell.selected) {
                x += 1;
                continue;
            }
            var end = x + 1;
            while (end < cols) : (end += 1) {
                const next = snap.cell(end, y);
                if (next.selected != cell.selected or (!next.has_bg and !next.selected)) break;
                if (!cell.selected and !std.meta.eql(next.bg, cell.bg)) break;
            }
            const color = if (cell.selected) selection_bg else toColor(cell.bg);
            rect(rs, @as(f32, @floatFromInt(x)) * cw, fy, @as(f32, @floatFromInt(end - x)) * cw, ch).fill(none, .{ .color = color });
            x = end;
        }

        // Text: ASCII in runs, everything else cell by cell so columns stay put.
        x = 0;
        while (x < cols) {
            const cell = snap.cell(x, y);
            if (cell.spacer or cell.len == 0) {
                x += 1;
                continue;
            }
            const fg = if (cell.selected) theme.colors.text_on_accent else toColor(cell.fg);
            if (!isAscii(cell)) {
                const span: f32 = if (cell.wide) 2 else 1;
                drawText(rs, font(cell.bold, cell.italic), cell.text(), @as(f32, @floatFromInt(x)) * cw, fy, span * cw, ch, fg);
                decorate(rs, cell, @as(f32, @floatFromInt(x)) * cw, fy, span * cw, ch, fg);
                x += 1;
                continue;
            }
            var run: [512]u8 = undefined;
            var n: usize = 0;
            var end = x;
            while (end < cols and n < run.len) : (end += 1) {
                const next = snap.cell(end, y);
                if (next.spacer) break;
                if (next.len == 0) {
                    // A blank inside a run keeps the run going only if the next
                    // visible cell continues it; a blank cell otherwise ends it.
                    if (end + 1 < cols and isAscii(snap.cell(end + 1, y)) and sameStyle(cell, snap.cell(end + 1, y)) and !snap.cell(end + 1, y).selected == !cell.selected) {
                        run[n] = ' ';
                        n += 1;
                        continue;
                    }
                    break;
                }
                if (!isAscii(next) or !sameStyle(cell, next) or next.selected != cell.selected) break;
                run[n] = next.utf8[0];
                n += 1;
            }
            drawText(rs, font(cell.bold, cell.italic), run[0..n], @as(f32, @floatFromInt(x)) * cw, fy, @as(f32, @floatFromInt(n)) * cw, ch, fg);
            for (x..end) |ux| {
                const dc = snap.cell(ux, y);
                if (dc.underline or dc.strike) decorate(rs, dc, @as(f32, @floatFromInt(ux)) * cw, fy, cw, ch, fg);
            }
            x = @max(end, x + 1);
        }
    }

    drawCursor(rs, cw, ch, focused);
}

fn drawText(rs: dvui.RectScale, f: dvui.Font, text: []const u8, x: f32, y: f32, w: f32, h: f32, color: dvui.Color) void {
    if (text.len == 0) return;
    dvui.renderText(.{
        .font = f,
        .text = text,
        .rs = .{ .r = rect(rs, x, y, w, h), .s = rs.s },
        .color = color,
        .kerning = false,
    }) catch {};
}

fn decorate(rs: dvui.RectScale, cell: *const session_mod.Cell, x: f32, y: f32, w: f32, h: f32, color: dvui.Color) void {
    const none = dvui.Rect.Physical.all(0);
    const thick = @max(1, @round(rs.s));
    if (cell.underline) rect(rs, x, y + h - thick * 1.5, w, thick).fill(none, .{ .color = color });
    if (cell.strike) rect(rs, x, y + h * 0.5, w, thick).fill(none, .{ .color = color });
}

fn drawCursor(rs: dvui.RectScale, cw: f32, ch: f32, focused: bool) void {
    if (!snap.cursor_visible or snap.cursor_x >= snap.cols or snap.cursor_y >= snap.rows) return;
    const none = dvui.Rect.Physical.all(0);
    const x = @as(f32, @floatFromInt(snap.cursor_x)) * cw;
    const y = @as(f32, @floatFromInt(snap.cursor_y)) * ch;
    const color = toColor(snap.default_fg);
    const thick = @max(1, @round(rs.s));
    const style: session_mod.CursorStyle = if (focused) snap.cursor_style else .hollow;
    switch (style) {
        .block => {
            rect(rs, x, y, cw, ch).fill(none, .{ .color = color });
            const cell = snap.cell(snap.cursor_x, snap.cursor_y);
            if (cell.len > 0 and !cell.spacer) drawText(rs, font(cell.bold, cell.italic), cell.text(), x, y, if (cell.wide) cw * 2 else cw, ch, toColor(snap.default_bg));
        },
        .bar => rect(rs, x, y, thick * 2, ch).fill(none, .{ .color = color }),
        .underline => rect(rs, x, y + ch - thick * 2, cw, thick * 2).fill(none, .{ .color = color }),
        .hollow => {
            rect(rs, x, y, cw, thick).fill(none, .{ .color = color });
            rect(rs, x, y + ch - thick, cw, thick).fill(none, .{ .color = color });
            rect(rs, x, y, thick, ch).fill(none, .{ .color = color });
            rect(rs, x + cw - thick, y, thick, ch).fill(none, .{ .color = color });
        },
    }
}

// ── Input ──

fn scrollThumb(content: dvui.Rect.Physical, scale: f32) ?pointer.Thumb {
    return pointer.thumb(snap.scroll_total, snap.scroll_offset, snap.scroll_len, content.h, 24 * scale);
}

fn inScrollbarZone(content: dvui.Rect.Physical, scale: f32, p: dvui.Point.Physical) bool {
    return p.x >= content.x + content.w - SB_HIT * scale and p.x <= content.x + content.w and p.y >= content.y and p.y <= content.y + content.h;
}

/// Scroll so the thumb's grabbed point follows the pointer at `py`.
fn scrollbarTo(s: *Session, content: dvui.Rect.Physical, scale: f32, py: f32) void {
    const th = scrollThumb(content, scale) orelse return;
    const target: i64 = @intCast(pointer.offsetForThumbTop(snap.scroll_total, snap.scroll_len, content.h, th.h, py - content.y - sb_grab));
    if (target == sb_offset) return;
    s.scroll(@intCast(target - sb_offset));
    sb_offset = target;
}

fn drawScrollbar(content: dvui.Rect.Physical, scale: f32, active: bool) void {
    const th = scrollThumb(content, scale) orelse return;
    const hover = inScrollbarZone(content, scale, dvui.currentWindow().mouse_pt);
    const w = SB_WIDTH * scale;
    const c = toColor(snap.default_fg);
    const alpha: u8 = if (active) 170 else if (hover) 120 else 60;
    const r = dvui.Rect.Physical{ .x = content.x + content.w - w - 2 * scale, .y = content.y + th.y, .w = w, .h = th.h };
    r.fill(dvui.Rect.Physical.all(w / 2), .{ .color = .{ .r = c.r, .g = c.g, .b = c.b, .a = alpha } });
}

fn mapButton(b: dvui.enums.Button) ?pointer.Button {
    return switch (b) {
        .left => .left,
        .right => .right,
        .middle => .middle,
        .four => .four,
        .five => .five,
        .six => .six,
        .seven => .seven,
        .eight => .eight,
        else => null,
    };
}

fn modsOf(mod: dvui.enums.Mod) keymap.Mods {
    return .{ .shift = mod.shift(), .ctrl = mod.control(), .alt = mod.alt(), .super = mod.command() };
}

fn clipboardCopy(s: *Session) void {
    const text = s.copySelection(alloc) orelse return;
    defer alloc.free(text);
    dvui.clipboardTextSet(text);
}

/// A vertical wheel turn: to a program that tracks the mouse, as arrows on the
/// alternate screen for one that does not, otherwise through the scrollback.
/// `bypass` (Shift) skips the mouse report, like selecting does.
fn wheelVertical(s: *Session, dy: f32, bypass: bool, mods: session_mod.c.GhosttyMods, hit: pointer.Hit) void {
    const modes = s.modes();
    if (!bypass and modes.mouse_tracking) {
        // Wheel notches are buttons four (up) and five (down).
        const notches: usize = @max(1, @as(usize, @intFromFloat(@round(@abs(dy)))));
        const btn: pointer.Button = if (dy > 0) .four else .five;
        for (0..@min(notches, 10)) |_| _ = s.mouseReport(.press, btn, mods, hit, false);
    } else if (modes.alt_screen and modes.alt_scroll) {
        // Full-screen programs without mouse support (less, man) get arrows.
        const n: usize = @abs(pointer.wheelRows(dy, SCROLL_ROWS_PER_NOTCH));
        const key: session_mod.c.GhosttyKey = @intCast(if (dy > 0) session_mod.c.GHOSTTY_KEY_ARROW_UP else session_mod.c.GHOSTTY_KEY_ARROW_DOWN);
        for (0..@min(n, 30)) |_| _ = s.sendKey(key, 0, .press, "");
    } else {
        s.scroll(pointer.wheelRows(dy, SCROLL_ROWS_PER_NOTCH));
    }
    state.wakeUi();
}

fn handleEvents(s: *Session, wd: *dvui.WidgetData, content: dvui.Rect.Physical, cw: f32, ch: f32) void {
    var text_guard = keymap.TextGuard{};
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, wd)) continue;
        switch (e.evt) {
            .mouse => |me| {
                const hit = pointer.cellAt(me.p.x, me.p.y, content.x, content.y, cw, ch, snap.cols, snap.rows);
                const mods = keymap.mods(modsOf(me.mod));
                // Shift always means "select, whatever the program asked for".
                const bypass = me.mod.shift();
                switch (me.action) {
                    .focus => {
                        e.handle(@src(), wd);
                        dvui.focusWidget(wd.id, null, e.num);
                    },
                    .press => {
                        const btn = mapButton(me.button) orelse continue;
                        const scale = wd.contentRectScale().s;
                        if (btn == .left and inScrollbarZone(content, scale, me.p)) {
                            if (scrollThumb(content, scale)) |th| {
                                e.handle(@src(), wd);
                                dvui.captureMouse(wd, e.num);
                                drag = .scrollbar;
                                const top = content.y + th.y;
                                sb_grab = if (me.p.y >= top and me.p.y <= top + th.h) me.p.y - top else th.h / 2;
                                sb_offset = @intCast(snap.scroll_offset);
                                scrollbarTo(s, content, scale, me.p.y);
                                state.wakeUi();
                                continue;
                            }
                        }
                        const report = !bypass and s.modes().mouse_tracking;
                        if (!report and btn != .left) continue;
                        e.handle(@src(), wd);
                        dvui.captureMouse(wd, e.num);
                        if (report) {
                            drag = .report;
                            pressed_button = btn;
                            s.clearSelection();
                            _ = s.mouseReport(.press, btn, mods, hit, true);
                        } else {
                            drag = .select;
                            s.selectPress(hit, @intCast(@max(0, dvui.frameTimeNS())));
                        }
                        state.wakeUi();
                    },
                    .motion => switch (drag) {
                        .select => {
                            e.handle(@src(), wd);
                            // Dragging past the top or bottom edge walks through scrollback.
                            if (me.p.y < content.y) s.scroll(-1) else if (me.p.y > content.y + content.h) s.scroll(1);
                            s.selectDrag(hit, me.mod.alt());
                            state.wakeUi();
                        },
                        .report => {
                            e.handle(@src(), wd);
                            _ = s.mouseReport(.motion, pressed_button, mods, hit, true);
                        },
                        .scrollbar => {
                            e.handle(@src(), wd);
                            scrollbarTo(s, content, wd.contentRectScale().s, me.p.y);
                            state.wakeUi();
                        },
                        .none => if (!bypass and hit.inside and s.modes().mouse_tracking) {
                            _ = s.mouseReport(.motion, null, mods, hit, false);
                        },
                    },
                    .release => {
                        const btn = mapButton(me.button) orelse continue;
                        if (drag == .report and pressed_button == btn) {
                            e.handle(@src(), wd);
                            dvui.captureMouse(null, e.num);
                            drag = .none;
                            pressed_button = null;
                            _ = s.mouseReport(.release, btn, mods, hit, false);
                        } else if (drag == .scrollbar and btn == .left) {
                            e.handle(@src(), wd);
                            dvui.captureMouse(null, e.num);
                            drag = .none;
                            state.wakeUi();
                        } else if (drag == .select and btn == .left) {
                            e.handle(@src(), wd);
                            dvui.captureMouse(null, e.num);
                            drag = .none;
                            s.selectRelease(hit);
                            state.wakeUi();
                        }
                    },
                    .position => dvui.cursorSet(.ibeam),
                    .wheel_y => |dy| {
                        e.handle(@src(), wd);
                        wheelVertical(s, dy, bypass, mods, hit);
                    },
                    .wheel_x => |dx| switch (pointer.horizontalWheel(s.modes().mouse_tracking, bypass)) {
                        // Nothing to scroll sideways: leave the event alone.
                        .ignore => {},
                        .report => {
                            e.handle(@src(), wd);
                            const notches: usize = @max(1, @as(usize, @intFromFloat(@round(@abs(dx)))));
                            const btn = pointer.hwheelButton(dx);
                            for (0..@min(notches, 10)) |_| _ = s.mouseReport(.press, btn, mods, hit, false);
                            state.wakeUi();
                        },
                        // Shift+wheel: the toolkit rotated a vertical wheel.
                        .vertical => {
                            e.handle(@src(), wd);
                            wheelVertical(s, -dx, true, mods, hit);
                        },
                    },
                }
            },
            .key => |ke| {
                const name = @tagName(ke.code);
                const m = modsOf(ke.mod);
                if (ke.action == .up) {
                    e.handle(@src(), wd);
                    continue;
                }
                // The way out: gives the keyboard back to Opal's shortcuts.
                if (keymap.isReleaseChord(name, m)) {
                    e.handle(@src(), wd);
                    dvui.focusWidget(null, null, null);
                    state.wakeUi();
                    continue;
                }
                // Copy and paste: Cmd+C/V on macOS, Ctrl+Shift+C/V (and Ctrl/Shift+Insert) elsewhere.
                switch (keymap.clipboardChord(@import("builtin").os.tag == .macos, name, m)) {
                    .paste => {
                        e.handle(@src(), wd);
                        switch (s.paste(dvui.clipboardText())) {
                            .too_large => state.showToast("Paste is too large for the terminal (limit 512 KB)"),
                            .failed => state.showToast("The terminal did not accept the whole paste"),
                            else => {},
                        }
                        s.scrollToBottom();
                        continue;
                    },
                    .copy => {
                        e.handle(@src(), wd);
                        clipboardCopy(s);
                        continue;
                    },
                    .none => {},
                }
                // Enter, Backspace and the arrows that edit or confirm an input
                // method composition are the input method's, not the program's.
                if (ime.swallowsKey(m, dvui.frameTimeNS())) {
                    e.handle(@src(), wd);
                    continue;
                }
                const entry = keymap.find(name);
                text_guard.onKey(entry, m);
                switch (keymap.plan(entry, m)) {
                    .ignore => {},
                    .wait_for_text => {},
                    .encode => {
                        e.handle(@src(), wd);
                        const ch_buf: [1]u8 = .{entry.?.ch};
                        const utf8: []const u8 = if (entry.?.ch != 0) &ch_buf else "";
                        const press: Session.KeyAction = if (ke.action == .repeat) .repeat else .press;
                        if (s.sendKey(entry.?.key, keymap.mods(m), press, utf8)) {
                            s.clearSelection();
                            s.scrollToBottom();
                        }
                    },
                }
            },
            .text => |te| {
                switch (te.action) {
                    .value => |v| {
                        e.handle(@src(), wd);
                        // Text still being composed is not typed; the finished text arrives next.
                        if (!ime.onText(v.txt.len, v.selected, dvui.frameTimeNS())) continue;
                        // The echo of an Alt/Ctrl-encoded key must not also type.
                        if (text_guard.drops(v.txt)) continue;
                        s.write(v.txt);
                        s.clearSelection();
                        s.scrollToBottom();
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}
