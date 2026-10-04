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

const Session = session_mod.Session;
const FONT_SIZE: f32 = 13;
const SCROLL_ROWS_PER_NOTCH: f32 = 3;

var session: ?*Session = null;
var snap: session_mod.Snapshot = .{};
var term_id: ?dvui.Id = null;
/// Set when a session starts: the next frame hands the terminal keyboard focus.
var want_focus: bool = false;
/// What the left button is doing since it went down inside the terminal.
const Drag = enum { none, select, report, scrollbar };
var drag: Drag = .none;
var pressed_button: ?pointer.Button = null;
var was_focused: bool = false;
var frame_guard: pointer.FrameGuard = .{};
/// While dragging the scrollbar: where in the thumb it was grabbed, and the
/// offset last asked for (the snapshot lags a frame behind).
var sb_grab: f32 = 0;
var sb_offset: i64 = 0;
const SB_WIDTH: f32 = 6;
const SB_HIT: f32 = 14;
var launched: ?Kind = null;
var tab: enum { terminal, tasks } = .terminal;
var note_buf: [128]u8 = undefined;
var note_len: usize = 0;

pub const Kind = enum { claude, codex, gemini, shell };

fn say(text: []const u8) void {
    note_len = @min(text.len, note_buf.len);
    @memcpy(note_buf[0..note_len], text[0..note_len]);
}

fn kindTitle(kind: Kind) []const u8 {
    return switch (kind) {
        .claude => "Claude Code",
        .codex => "Codex",
        .gemini => "Gemini CLI",
        .shell => "Shell",
    };
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

pub fn shutdown() void {
    if (session) |s| s.deinit();
    session = null;
    snap.deinit(alloc);
    term_id = null;
}

/// True while the terminal has keyboard focus. Opal's global shortcuts must
/// leave keys alone then, or Ctrl+W (delete word) would close the window.
pub fn capturesKeyboard() bool {
    const id = term_id orelse return false;
    // dvui keeps focus on a widget that stopped rendering (the agent opened the
    // player, say); only a terminal that is still on screen owns the keys.
    if (!frame_guard.alive(dvui.frameTimeNS())) return false;
    return session != null and dvui.focusedWidgetId() == id;
}

fn start(kind: Kind) void {
    if (!session_mod.supported) {
        say("The embedded terminal is not available on this platform yet");
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

    stop();
    installWake();
    const cols: u16 = if (snap.cols > 0) snap.cols else 100;
    const rows: u16 = if (snap.rows > 0) snap.rows else 30;
    const argv: []const []const u8 = if (is_windows) &.{script} else &.{ "/bin/sh", "-c", script };
    session = Session.start(alloc, argv, cols, rows) catch |err| {
        say(switch (err) {
            error.Unsupported => "The embedded terminal is not available on this platform yet",
            else => "Could not start the terminal",
        });
        return;
    };
    launched = kind;
    note_len = 0;
    want_focus = true;
    snap.deinit(alloc);
    state.wakeUi();
}

fn stop() void {
    if (session) |s| s.deinit();
    session = null;
    launched = null;
}

pub fn render() void {
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_app,
    });
    defer page.deinit();

    renderToolbar();

    if (tab == .tasks) {
        tasks_ui.render();
        return;
    }
    if (session == null) {
        renderEmpty();
        return;
    }
    renderTerminal(session.?);
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

    if (tasks_ui.tabSwitch(@intFromEnum(tab))) |i| tab = @enumFromInt(i);
    if (tab == .tasks) return;

    const kinds = [_]Kind{ .claude, .codex, .gemini, .shell };
    inline for (kinds, 0..) |kind, i| {
        const active = launched != null and launched.? == kind and session != null;
        if (components.actionButton(@src(), kindTitle(kind), if (active) .primary else .secondary, 9500 + i)) start(kind);
    }

    if (session) |s| {
        var title_buf: [128]u8 = undefined;
        const raw = s.titleSlice();
        const n = @min(raw.len, title_buf.len);
        @memcpy(title_buf[0..n], raw[0..n]);
        const label: []const u8 = if (s.isExited()) "process exited" else title_buf[0..n];
        _ = dvui.label(@src(), "{s}", .{label}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .margin = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
        });
        if (components.actionButton(@src(), if (s.isExited()) "Close" else "Stop", .secondary, 9510)) {
            // stop() frees the session: nothing below may touch `s`.
            stop();
            return;
        }
        if (s.takeBell()) state.showToast("Terminal bell");
    } else if (note_len > 0) {
        _ = dvui.label(@src(), "{s}", .{note_buf[0..note_len]}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .margin = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
        });
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
        .margin = .{ .x = 0, .y = 6, .w = 0, .h = 0 },
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

fn renderTerminal(s: *Session) void {
    var area = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = toColor(snap.default_bg),
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
    });
    defer area.deinit();
    const wd = area.data();
    term_id = wd.id;
    frame_guard.markRendered(dvui.frameTimeNS());
    if (want_focus) {
        want_focus = false;
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

    handleEvents(s, wd, rs.r, cw, ch);

    // Programs that asked for focus reports (DEC 1004) hear about gains and losses.
    const focused = dvui.focusedWidgetId() == wd.id;
    if (focused != was_focused) {
        was_focused = focused;
        s.sendFocus(focused);
    }

    _ = s.snapshot(&snap);
    if (snap.cols == 0 or snap.cells.len == 0) return;

    if (focused) dvui.wantTextInput(.{ .x = 0, .y = 0, .w = 0, .h = 0 });

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
                    },
                    else => {},
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
                // Copy and paste: Cmd+C/V on macOS, Ctrl+Shift+C/V elsewhere.
                const mac = @import("builtin").os.tag == .macos;
                const clip_mod = if (mac) (m.super and !m.ctrl and !m.alt) else (m.ctrl and m.shift and !m.alt);
                if (clip_mod and ke.code == .v) {
                    e.handle(@src(), wd);
                    switch (s.paste(dvui.clipboardText())) {
                        .too_large => state.showToast("Paste is too large for the terminal (limit 512 KB)"),
                        .failed => state.showToast("The terminal did not accept the whole paste"),
                        else => {},
                    }
                    s.scrollToBottom();
                    continue;
                }
                if (clip_mod and ke.code == .c) {
                    e.handle(@src(), wd);
                    clipboardCopy(s);
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
