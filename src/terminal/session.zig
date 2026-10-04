//! An embedded terminal: a child process on a pty, parsed by libghostty-vt.
//!
//! One reader thread feeds the pty's output into the terminal under a mutex.
//! The UI thread asks for a `Snapshot` each frame (cheap when nothing changed),
//! sends keys and pastes, and resizes. libghostty-vt owns all terminal state
//! (screen, scrollback, modes, colours, cursor); this file only moves bytes and
//! flattens the render state into plain cells the UI can draw without the lock.

const std = @import("std");
const sync = @import("../core/sync.zig");
const workers = @import("../core/workers.zig");
const pty_mod = @import("pty.zig");

pub const c = @cImport({
    @cInclude("ghostty/vt.h");
});

pub const supported = pty_mod.supported;

/// Called from the reader thread when new output arrives so the UI repaints. The
/// UI layer installs it; leaving it null keeps this file free of UI imports.
pub var wake_hook: ?*const fn () void = null;

fn wake() void {
    if (wake_hook) |hook| hook();
}

test {
    _ = pty_mod;
}

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Cell = struct {
    /// UTF-8 of the whole grapheme cluster; `len == 0` is an empty cell.
    utf8: [12]u8 = undefined,
    len: u8 = 0,
    fg: Rgb = .{ .r = 255, .g = 255, .b = 255 },
    bg: Rgb = .{ .r = 0, .g = 0, .b = 0 },
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    /// Occupies this column and the next; the next cell is a spacer.
    wide: bool = false,
    /// Second half of a wide character: draw nothing.
    spacer: bool = false,
    selected: bool = false,
    /// Differs from the terminal background, so it needs a fill.
    has_bg: bool = false,

    pub fn text(self: *const Cell) []const u8 {
        return self.utf8[0..self.len];
    }
};

pub const CursorStyle = enum { bar, block, underline, hollow };

pub const Snapshot = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    cells: []Cell = &.{},
    capacity: usize = 0,
    default_fg: Rgb = .{ .r = 229, .g = 229, .b = 229 },
    default_bg: Rgb = .{ .r = 20, .g = 20, .b = 24 },
    cursor_visible: bool = false,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_style: CursorStyle = .block,
    /// Scrollback geometry in rows: `total` rows exist, the viewport starts at
    /// `offset` and shows `len` of them.
    scroll_total: u64 = 0,
    scroll_offset: u64 = 0,
    scroll_len: u64 = 0,
    /// Bumped whenever the content changes.
    generation: u64 = 0,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        if (self.capacity > 0) allocator.free(self.cells.ptr[0..self.capacity]);
        self.* = .{};
    }

    pub fn cell(self: *const Snapshot, x: usize, y: usize) *const Cell {
        return &self.cells[y * self.cols + x];
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    term: c.GhosttyTerminal = null,
    render: c.GhosttyRenderState = null,
    row_iter: c.GhosttyRenderStateRowIterator = null,
    row_cells: c.GhosttyRenderStateRowCells = null,
    encoder: c.GhosttyKeyEncoder = null,
    key_event: c.GhosttyKeyEvent = null,
    pty: pty_mod.Pty = .{},
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    bell: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cols: u16,
    rows: u16,
    cell_w: u16 = 8,
    cell_h: u16 = 16,
    generation: u64 = 0,
    title: [128]u8 = undefined,
    title_len: usize = 0,

    pub const StartError = error{ Unsupported, OutOfMemory, TerminalFailed, SpawnFailed };

    /// Start `argv` (absolute executable path) on a pty of `cols` x `rows`.
    pub fn start(allocator: std.mem.Allocator, argv: []const []const u8, cols: u16, rows: u16) StartError!*Session {
        if (!supported) return error.Unsupported;
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .cols = @max(cols, 2), .rows = @max(rows, 1) };

        if (c.ghostty_terminal_new(null, &self.term, self.cols, self.rows) != c.GHOSTTY_SUCCESS) return error.TerminalFailed;
        errdefer c.ghostty_terminal_free(self.term);
        if (c.ghostty_render_state_new(null, &self.render) != c.GHOSTTY_SUCCESS) return error.TerminalFailed;
        errdefer c.ghostty_render_state_free(self.render);
        if (c.ghostty_render_state_row_iterator_new(null, &self.row_iter) != c.GHOSTTY_SUCCESS) return error.TerminalFailed;
        errdefer c.ghostty_render_state_row_iterator_free(self.row_iter);
        if (c.ghostty_render_state_row_cells_new(null, &self.row_cells) != c.GHOSTTY_SUCCESS) return error.TerminalFailed;
        errdefer c.ghostty_render_state_row_cells_free(self.row_cells);
        if (c.ghostty_key_encoder_new(null, &self.encoder) != c.GHOSTTY_SUCCESS) return error.TerminalFailed;
        errdefer c.ghostty_key_encoder_free(self.encoder);
        if (c.ghostty_key_event_new(null, &self.key_event) != c.GHOSTTY_SUCCESS) return error.TerminalFailed;
        errdefer c.ghostty_key_event_free(self.key_event);

        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_USERDATA, self);
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @as(c.GhosttyTerminalWritePtyFn, onWritePty));
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_BELL, @as(c.GhosttyTerminalBellFn, onBell));
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @as(c.GhosttyTerminalTitleChangedFn, onTitle));

        self.pty = pty_mod.spawn(allocator, argv, &.{ "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=Opal" }, self.cols, self.rows) catch return error.SpawnFailed;
        errdefer self.pty.close();
        self.thread = workers.spawnLegacy(readerMain, .{self}) catch return error.SpawnFailed;
        return self;
    }

    /// Stops the reader, terminates the child and frees everything.
    pub fn deinit(self: *Session) void {
        // Hang up first so the child is already going while the reader notices
        // `stop` (within one poll) and is joined; only then reap it and release
        // the descriptor, so nothing is closed while a read is still using it.
        self.stop.store(true, .release);
        self.pty.hangup();
        if (self.thread) |t| t.join();
        self.pty.close();
        c.ghostty_key_event_free(self.key_event);
        c.ghostty_key_encoder_free(self.encoder);
        c.ghostty_render_state_row_cells_free(self.row_cells);
        c.ghostty_render_state_row_iterator_free(self.row_iter);
        c.ghostty_render_state_free(self.render);
        c.ghostty_terminal_free(self.term);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn isExited(self: *const Session) bool {
        return self.exited.load(.acquire);
    }

    pub fn takeBell(self: *Session) bool {
        return self.bell.swap(false, .acq_rel);
    }

    pub fn titleSlice(self: *Session) []const u8 {
        return self.title[0..self.title_len];
    }

    // ── Output: pty -> terminal ──

    fn readerMain(self: *Session) void {
        var buf: [16 * 1024]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            switch (self.pty.readTimeout(&buf, 100)) {
                .data => |n| {
                    self.mutex.lock();
                    c.ghostty_terminal_vt_write(self.term, &buf, n);
                    self.mutex.unlock();
                    self.changed.store(true, .release);
                    wake();
                },
                .idle => {
                    if (!self.pty.alive()) break;
                },
                .closed => break,
            }
        }
        _ = self.pty.alive();
        self.exited.store(true, .release);
        self.changed.store(true, .release);
        wake();
    }

    fn fromUserdata(userdata: ?*anyopaque) ?*Session {
        return @ptrCast(@alignCast(userdata orelse return null));
    }

    fn onWritePty(_: c.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
        const self = fromUserdata(userdata) orelse return;
        _ = self.pty.writeAll(data[0..len]);
    }

    fn onBell(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
        const self = fromUserdata(userdata) orelse return;
        self.bell.store(true, .release);
    }

    fn onTitle(term: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
        const self = fromUserdata(userdata) orelse return;
        var s: c.GhosttyString = std.mem.zeroes(c.GhosttyString);
        if (c.ghostty_terminal_get(term, c.GHOSTTY_TERMINAL_DATA_TITLE, &s) != c.GHOSTTY_SUCCESS) return;
        const n = @min(s.len, self.title.len);
        if (n > 0) @memcpy(self.title[0..n], s.ptr[0..n]);
        self.title_len = n;
    }

    // ── Input: UI -> pty ──

    pub fn write(self: *Session, bytes: []const u8) void {
        if (bytes.len == 0 or self.isExited()) return;
        _ = self.pty.writeAll(bytes);
    }

    pub const KeyAction = enum { press, repeat, release };

    /// Encode a key through the terminal's current modes (cursor-key mode, kitty
    /// protocol, ...) and send it. Returns whether anything was sent.
    pub fn sendKey(self: *Session, key: c.GhosttyKey, mods: c.GhosttyMods, action: KeyAction, utf8: []const u8) bool {
        if (self.isExited()) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        c.ghostty_key_encoder_setopt_from_terminal(self.encoder, self.term);
        c.ghostty_key_event_set_action(self.key_event, switch (action) {
            .press => c.GHOSTTY_KEY_ACTION_PRESS,
            .repeat => c.GHOSTTY_KEY_ACTION_REPEAT,
            .release => c.GHOSTTY_KEY_ACTION_RELEASE,
        });
        c.ghostty_key_event_set_key(self.key_event, key);
        c.ghostty_key_event_set_mods(self.key_event, mods);
        c.ghostty_key_event_set_utf8(self.key_event, if (utf8.len > 0) utf8.ptr else null, utf8.len);
        var out: [128]u8 = undefined;
        var written: usize = 0;
        if (c.ghostty_key_encoder_encode(self.encoder, self.key_event, &out, out.len, &written) != c.GHOSTTY_SUCCESS) return false;
        if (written == 0) return false;
        _ = self.pty.writeAll(out[0..written]);
        return true;
    }

    /// Paste text. libghostty-vt scrubs control bytes and, when the program
    /// asked for bracketed paste, wraps the text in the bracket sequences.
    pub fn paste(self: *Session, text: []const u8) void {
        if (text.len == 0 or text.len > 4 * 1024 * 1024 or self.isExited()) return;
        const data = self.allocator.dupe(u8, text) catch return;
        defer self.allocator.free(data);
        const out = self.allocator.alloc(u8, text.len + 32) catch return;
        defer self.allocator.free(out);

        var cfg = std.mem.zeroes(c.GhosttyTerminalModeConfig);
        cfg.mode = 2004; // bracketed paste: DEC private mode 2004
        self.mutex.lock();
        const have_mode = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_MODE, &cfg) == c.GHOSTTY_SUCCESS;
        self.mutex.unlock();

        var written: usize = 0;
        if (c.ghostty_paste_encode(data.ptr, data.len, have_mode and cfg.value, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) return;
        self.write(out[0..written]);
    }

    pub fn resize(self: *Session, cols: u16, rows: u16, cell_w: u16, cell_h: u16) void {
        const nc = @max(cols, 2);
        const nr = @max(rows, 1);
        if (nc == self.cols and nr == self.rows and cell_w == self.cell_w and cell_h == self.cell_h) return;
        self.mutex.lock();
        _ = c.ghostty_terminal_resize(self.term, nc, nr, cell_w, cell_h);
        self.mutex.unlock();
        self.cols = nc;
        self.rows = nr;
        self.cell_w = cell_w;
        self.cell_h = cell_h;
        self.pty.resize(nc, nr, cell_w, cell_h);
        self.changed.store(true, .release);
    }

    pub fn scroll(self: *Session, delta_rows: isize) void {
        if (delta_rows == 0) return;
        self.mutex.lock();
        var behavior = std.mem.zeroes(c.GhosttyTerminalScrollViewport);
        behavior.tag = c.GHOSTTY_SCROLL_VIEWPORT_DELTA;
        behavior.value.delta = delta_rows;
        c.ghostty_terminal_scroll_viewport(self.term, behavior);
        self.mutex.unlock();
        self.changed.store(true, .release);
    }

    pub fn scrollToBottom(self: *Session) void {
        self.mutex.lock();
        var behavior = std.mem.zeroes(c.GhosttyTerminalScrollViewport);
        behavior.tag = c.GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
        c.ghostty_terminal_scroll_viewport(self.term, behavior);
        self.mutex.unlock();
        self.changed.store(true, .release);
    }

    // ── Output: terminal -> cells ──

    fn sized(comptime T: type) T {
        var v = std.mem.zeroes(T);
        v.size = @sizeOf(T);
        return v;
    }

    fn resolve(color: c.GhosttyStyleColor, colors: *const c.GhosttyRenderStateColors, fallback: Rgb) Rgb {
        return switch (color.tag) {
            c.GHOSTTY_STYLE_COLOR_RGB => .{ .r = color.value.rgb.r, .g = color.value.rgb.g, .b = color.value.rgb.b },
            c.GHOSTTY_STYLE_COLOR_PALETTE => blk: {
                const p = colors.palette[color.value.palette];
                break :blk .{ .r = p.r, .g = p.g, .b = p.b };
            },
            else => fallback,
        };
    }

    /// Refresh `out` from the terminal. False when nothing changed since the last
    /// call (the previous contents are still valid).
    pub fn snapshot(self: *Session, out: *Snapshot) bool {
        if (!self.changed.swap(false, .acq_rel) and out.cells.len != 0) return false;
        self.mutex.lock();
        defer self.mutex.unlock();

        if (c.ghostty_render_state_update(self.render, self.term) != c.GHOSTTY_SUCCESS) return false;

        var cols: u16 = 0;
        var rows: u16 = 0;
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
        if (cols == 0 or rows == 0) return false;

        const need = @as(usize, cols) * rows;
        if (need > out.capacity) {
            if (out.capacity > 0) self.allocator.free(out.cells.ptr[0..out.capacity]);
            const mem = self.allocator.alloc(Cell, need) catch {
                out.capacity = 0;
                out.cells = &.{};
                return false;
            };
            out.capacity = need;
            out.cells = mem;
        }
        out.cols = cols;
        out.rows = rows;
        out.cells = out.cells.ptr[0..need];

        var colors = sized(c.GhosttyRenderStateColors);
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
        out.default_fg = .{ .r = colors.foreground.r, .g = colors.foreground.g, .b = colors.foreground.b };
        out.default_bg = .{ .r = colors.background.r, .g = colors.background.g, .b = colors.background.b };

        var cursor = sized(c.GhosttyRenderStateCursor);
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
        out.cursor_visible = cursor.visible and cursor.viewport_has_value;
        out.cursor_x = cursor.viewport_x;
        out.cursor_y = cursor.viewport_y;
        out.cursor_style = switch (cursor.visual_style) {
            c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => .bar,
            c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => .underline,
            c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => .hollow,
            else => .block,
        };

        var scrollbar = std.mem.zeroes(c.GhosttyTerminalScrollbar);
        if (c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar) == c.GHOSTTY_SUCCESS) {
            out.scroll_total = scrollbar.total;
            out.scroll_offset = scrollbar.offset;
            out.scroll_len = scrollbar.len;
        }

        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @as(?*anyopaque, @ptrCast(&self.row_iter)));
        var y: usize = 0;
        while (c.ghostty_render_state_row_iterator_next(self.row_iter) and y < rows) : (y += 1) {
            _ = c.ghostty_render_state_row_get(self.row_iter, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @as(?*anyopaque, @ptrCast(&self.row_cells)));
            var x: usize = 0;
            while (c.ghostty_render_state_row_cells_next(self.row_cells) and x < cols) : (x += 1) {
                self.readCell(&out.cells[y * cols + x], &colors, out.default_fg, out.default_bg);
            }
            while (x < cols) : (x += 1) out.cells[y * cols + x] = .{ .fg = out.default_fg, .bg = out.default_bg };
        }
        while (y < rows) : (y += 1) {
            for (0..cols) |x| out.cells[y * cols + x] = .{ .fg = out.default_fg, .bg = out.default_bg };
        }

        _ = c.ghostty_render_state_clean(self.render);
        self.generation +%= 1;
        out.generation = self.generation;
        return true;
    }

    fn readCell(self: *Session, cell: *Cell, colors: *const c.GhosttyRenderStateColors, default_fg: Rgb, default_bg: Rgb) void {
        cell.* = .{ .fg = default_fg, .bg = default_bg };
        const cells = self.row_cells;

        var raw: c.GhosttyCell = 0;
        if (c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == c.GHOSTTY_SUCCESS) {
            var wide: c_uint = c.GHOSTTY_CELL_WIDE_NARROW;
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, &wide);
            cell.wide = wide == c.GHOSTTY_CELL_WIDE_WIDE;
            cell.spacer = wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL or wide == c.GHOSTTY_CELL_WIDE_SPACER_HEAD;
        }

        var glen: u32 = 0;
        _ = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);
        if (glen > 0) {
            var buf = c.GhosttyBuffer{ .ptr = &cell.utf8, .cap = cell.utf8.len, .len = 0 };
            if (c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buf) == c.GHOSTTY_SUCCESS) {
                cell.len = @intCast(@min(buf.len, cell.utf8.len));
            } else {
                // Cluster longer than the buffer: keep the base character.
                var cp: [1]u32 = undefined;
                var base_buf: [64]u32 = undefined;
                if (glen <= base_buf.len and c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &base_buf) == c.GHOSTTY_SUCCESS) {
                    cp[0] = base_buf[0];
                    const n = std.unicode.utf8Encode(@intCast(@min(cp[0], 0x10FFFF)), &cell.utf8) catch 0;
                    cell.len = @intCast(n);
                }
            }
        }

        var fg_set = false;
        var bg: c.GhosttyColorRgb = undefined;
        if (c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == c.GHOSTTY_SUCCESS) {
            cell.bg = .{ .r = bg.r, .g = bg.g, .b = bg.b };
            cell.has_bg = true;
        }
        var fg: c.GhosttyColorRgb = undefined;
        if (c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == c.GHOSTTY_SUCCESS) {
            cell.fg = .{ .r = fg.r, .g = fg.g, .b = fg.b };
            fg_set = true;
        }

        var styled: bool = false;
        _ = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled);
        if (styled) {
            var style = sized(c.GhosttyStyle);
            if (c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == c.GHOSTTY_SUCCESS) {
                cell.bold = style.bold;
                cell.italic = style.italic;
                cell.underline = style.underline != 0;
                cell.strike = style.strikethrough;
                if (style.faint) {
                    cell.fg = .{
                        .r = @intCast((@as(u16, cell.fg.r) + cell.bg.r) / 2),
                        .g = @intCast((@as(u16, cell.fg.g) + cell.bg.g) / 2),
                        .b = @intCast((@as(u16, cell.fg.b) + cell.bg.b) / 2),
                    };
                }
                if (style.inverse) {
                    const t = cell.fg;
                    cell.fg = cell.bg;
                    cell.bg = t;
                    cell.has_bg = true;
                }
                if (style.invisible) cell.len = 0;
            }
        }
        _ = colors;

        var selected: bool = false;
        _ = c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected);
        cell.selected = selected;
    }
};

test "snapshot flattens a styled screen" {
    var term: c.GhosttyTerminal = null;
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_terminal_new(null, &term, 20, 3));
    defer c.ghostty_terminal_free(term);
    const text = "hi \x1b[1;31mred\x1b[0m\r\nok";
    c.ghostty_terminal_vt_write(term, text, text.len);

    var session = Session{ .allocator = std.testing.allocator, .cols = 20, .rows = 3 };
    session.term = term;
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_render_state_new(null, &session.render));
    defer c.ghostty_render_state_free(session.render);
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_render_state_row_iterator_new(null, &session.row_iter));
    defer c.ghostty_render_state_row_iterator_free(session.row_iter);
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_render_state_row_cells_new(null, &session.row_cells));
    defer c.ghostty_render_state_row_cells_free(session.row_cells);

    var snap = Snapshot{};
    defer snap.deinit(std.testing.allocator);
    try std.testing.expect(session.snapshot(&snap));
    try std.testing.expectEqual(@as(u16, 20), snap.cols);
    try std.testing.expectEqual(@as(u16, 3), snap.rows);
    try std.testing.expectEqualStrings("h", snap.cell(0, 0).text());
    try std.testing.expectEqualStrings("r", snap.cell(3, 0).text());
    try std.testing.expect(snap.cell(3, 0).bold);
    try std.testing.expect(snap.cell(3, 0).fg.r > snap.cell(3, 0).fg.g);
    try std.testing.expect(!snap.cell(0, 0).bold);
    try std.testing.expectEqualStrings("o", snap.cell(0, 1).text());
    try std.testing.expectEqual(@as(usize, 0), snap.cell(10, 2).text().len);
    // Nothing changed: the second call reports no new frame.
    try std.testing.expect(!session.snapshot(&snap));
}
