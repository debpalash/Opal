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
const pointer = @import("pointer.zig");

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
    _ = pointer;
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
    mouse_encoder: c.GhosttyMouseEncoder = null,
    mouse_event: c.GhosttyMouseEvent = null,
    gesture: c.GhosttySelectionGesture = null,
    gesture_press: c.GhosttySelectionGestureEvent = null,
    gesture_drag: c.GhosttySelectionGestureEvent = null,
    gesture_release: c.GhosttySelectionGestureEvent = null,
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

        try self.initPointer();
        errdefer self.freePointer();

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
        self.stop.store(true, .release);
        self.pty.close();
        if (self.thread) |t| t.join();
        self.freePointer();
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

    // ── Pointer: mouse reports, selection, focus ──

    /// Create the mouse encoder and selection gesture objects.
    fn initPointer(self: *Session) StartError!void {
        const ok = c.GHOSTTY_SUCCESS;
        if (c.ghostty_mouse_encoder_new(null, &self.mouse_encoder) != ok) return error.TerminalFailed;
        if (c.ghostty_mouse_event_new(null, &self.mouse_event) != ok) return error.TerminalFailed;
        if (c.ghostty_selection_gesture_new(null, &self.gesture) != ok) return error.TerminalFailed;
        if (c.ghostty_selection_gesture_event_new(null, &self.gesture_press, c.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) != ok) return error.TerminalFailed;
        if (c.ghostty_selection_gesture_event_new(null, &self.gesture_drag, c.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) != ok) return error.TerminalFailed;
        if (c.ghostty_selection_gesture_event_new(null, &self.gesture_release, c.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) != ok) return error.TerminalFailed;
        const track_last = true;
        c.ghostty_mouse_encoder_setopt(self.mouse_encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track_last);
    }

    /// Safe on partly created state: every free accepts null.
    fn freePointer(self: *Session) void {
        c.ghostty_selection_gesture_event_free(self.gesture_release);
        c.ghostty_selection_gesture_event_free(self.gesture_drag);
        c.ghostty_selection_gesture_event_free(self.gesture_press);
        if (self.gesture != null) c.ghostty_selection_gesture_free(self.gesture, self.term);
        c.ghostty_mouse_event_free(self.mouse_event);
        c.ghostty_mouse_encoder_free(self.mouse_encoder);
        self.gesture_release = null;
        self.gesture_drag = null;
        self.gesture_press = null;
        self.gesture = null;
        self.mouse_event = null;
        self.mouse_encoder = null;
    }

    pub const Modes = struct {
        /// The program asked for mouse reports (any tracking mode).
        mouse_tracking: bool = false,
        /// DEC 1004: send focus in/out.
        focus_events: bool = false,
        /// DEC 1007: wheel becomes arrow keys on the alternate screen.
        alt_scroll: bool = false,
        alt_screen: bool = false,
    };

    /// Caller holds the mutex.
    fn modeOn(self: *Session, mode: u16) bool {
        var cfg = std.mem.zeroes(c.GhosttyTerminalModeConfig);
        cfg.mode = mode;
        if (c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_MODE, &cfg) != c.GHOSTTY_SUCCESS) return false;
        return cfg.value;
    }

    pub fn modes(self: *Session) Modes {
        self.mutex.lock();
        defer self.mutex.unlock();
        var m = Modes{
            .focus_events = self.modeOn(1004),
            .alt_scroll = self.modeOn(1007),
        };
        var tracking: bool = false;
        if (c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking) == c.GHOSTTY_SUCCESS) m.mouse_tracking = tracking;
        var screen: c.GhosttyTerminalScreen = c.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        if (c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen) == c.GHOSTTY_SUCCESS) {
            m.alt_screen = screen == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
        }
        return m;
    }

    pub const MouseAction = enum { press, release, motion };

    fn cButton(b: pointer.Button) c.GhosttyMouseButton {
        return switch (b) {
            .left => c.GHOSTTY_MOUSE_BUTTON_LEFT,
            .right => c.GHOSTTY_MOUSE_BUTTON_RIGHT,
            .middle => c.GHOSTTY_MOUSE_BUTTON_MIDDLE,
            .four => c.GHOSTTY_MOUSE_BUTTON_FOUR,
            .five => c.GHOSTTY_MOUSE_BUTTON_FIVE,
            .six => c.GHOSTTY_MOUSE_BUTTON_SIX,
            .seven => c.GHOSTTY_MOUSE_BUTTON_SEVEN,
            .eight => c.GHOSTTY_MOUSE_BUTTON_EIGHT,
        };
    }

    /// Encode a mouse event under the terminal's current tracking mode and
    /// format, and send it. `hit` locates the pointer in cells. Returns whether
    /// anything was sent (the mode may not want this kind of event).
    pub fn mouseReport(self: *Session, action: MouseAction, button: ?pointer.Button, mods: c.GhosttyMods, hit: pointer.Hit, any_pressed: bool) bool {
        if (self.isExited()) return false;
        var out: [128]u8 = undefined;
        const n = self.mouseBytes(&out, action, button, mods, hit, any_pressed);
        if (n == 0) return false;
        _ = self.pty.writeAll(out[0..n]);
        return true;
    }

    fn mouseBytes(self: *Session, out: []u8, action: MouseAction, button: ?pointer.Button, mods: c.GhosttyMods, hit: pointer.Hit, any_pressed: bool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        c.ghostty_mouse_encoder_setopt_from_terminal(self.mouse_encoder, self.term);
        const size = c.GhosttyMouseEncoderSize{
            .size = @sizeOf(c.GhosttyMouseEncoderSize),
            .screen_width = @as(u32, self.cols) * self.cell_w,
            .screen_height = @as(u32, self.rows) * self.cell_h,
            .cell_width = self.cell_w,
            .cell_height = self.cell_h,
            .padding_top = 0,
            .padding_bottom = 0,
            .padding_right = 0,
            .padding_left = 0,
        };
        c.ghostty_mouse_encoder_setopt(self.mouse_encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
        c.ghostty_mouse_encoder_setopt(self.mouse_encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any_pressed);
        c.ghostty_mouse_event_set_action(self.mouse_event, switch (action) {
            .press => c.GHOSTTY_MOUSE_ACTION_PRESS,
            .release => c.GHOSTTY_MOUSE_ACTION_RELEASE,
            .motion => c.GHOSTTY_MOUSE_ACTION_MOTION,
        });
        if (button) |b| c.ghostty_mouse_event_set_button(self.mouse_event, cButton(b)) else c.ghostty_mouse_event_clear_button(self.mouse_event);
        c.ghostty_mouse_event_set_mods(self.mouse_event, mods);
        const pos = pointer.surfacePos(hit, self.cell_w, self.cell_h);
        c.ghostty_mouse_event_set_position(self.mouse_event, .{ .x = pos.x, .y = pos.y });
        var written: usize = 0;
        if (c.ghostty_mouse_encoder_encode(self.mouse_encoder, self.mouse_event, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) return 0;
        return written;
    }

    /// Tell the program the terminal gained or lost focus (only if it asked, DEC 1004).
    pub fn sendFocus(self: *Session, gained: bool) void {
        if (self.isExited()) return;
        var out: [8]u8 = undefined;
        const n = self.focusBytes(&out, gained);
        if (n > 0) _ = self.pty.writeAll(out[0..n]);
    }

    fn focusBytes(self: *Session, out: []u8, gained: bool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.modeOn(1004)) return 0;
        var written: usize = 0;
        if (c.ghostty_focus_encode(if (gained) c.GHOSTTY_FOCUS_GAINED else c.GHOSTTY_FOCUS_LOST, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) return 0;
        return written;
    }

    // Selection. The terminal owns the active selection (it tracks it through
    // scrolling and the render state flags selected cells); the gesture object
    // does click counting and word/line expansion.

    fn viewportRef(self: *Session, col: u16, row: u16) ?c.GhosttyGridRef {
        var ref = sized(c.GhosttyGridRef);
        const point = c.GhosttyPoint{
            .tag = c.GHOSTTY_POINT_TAG_VIEWPORT,
            .value = .{ .coordinate = .{ .x = col, .y = row } },
        };
        if (c.ghostty_terminal_grid_ref(self.term, point, &ref) != c.GHOSTTY_SUCCESS) return null;
        return ref;
    }

    fn installSelection(self: *Session, sel: ?*c.GhosttySelection) void {
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_SELECTION, sel);
        self.changed.store(true, .release);
    }

    fn setEvent(event: c.GhosttySelectionGestureEvent, opt: c.GhosttySelectionGestureEventOption, value: ?*const anyopaque) void {
        _ = c.ghostty_selection_gesture_event_set(event, opt, value);
    }

    /// Left button down. Clears any selection; a double or triple click selects a
    /// word or line right away. `time_ns` drives click counting.
    pub fn selectPress(self: *Session, hit: pointer.Hit, time_ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.installSelection(null);
        var ref = self.viewportRef(hit.col, hit.row) orelse return;
        const pos = pointer.surfacePos(hit, self.cell_w, self.cell_h);
        var surface = c.GhosttySurfacePosition{ .x = pos.x, .y = pos.y };
        var distance: f64 = @floatFromInt(self.cell_w);
        var t = time_ns;
        var interval: u64 = 500 * std.time.ns_per_ms;
        setEvent(self.gesture_press, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
        setEvent(self.gesture_press, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surface);
        setEvent(self.gesture_press, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance);
        setEvent(self.gesture_press, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &t);
        setEvent(self.gesture_press, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval);
        var sel = sized(c.GhosttySelection);
        if (c.ghostty_selection_gesture_event(self.gesture, self.term, self.gesture_press, &sel) == c.GHOSTTY_SUCCESS) {
            self.installSelection(&sel);
        }
    }

    /// Pointer moved with the left button held.
    pub fn selectDrag(self: *Session, hit: pointer.Hit, rectangle: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var ref = self.viewportRef(hit.col, hit.row) orelse return;
        const pos = pointer.surfacePos(hit, self.cell_w, self.cell_h);
        var surface = c.GhosttySurfacePosition{ .x = pos.x, .y = pos.y };
        var geometry = c.GhosttySelectionGestureGeometry{
            .columns = self.cols,
            .cell_width = self.cell_w,
            .padding_left = 0,
            .screen_height = @as(u32, self.rows) * self.cell_h,
        };
        var rect = rectangle;
        setEvent(self.gesture_drag, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
        setEvent(self.gesture_drag, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surface);
        setEvent(self.gesture_drag, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry);
        setEvent(self.gesture_drag, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect);
        var sel = sized(c.GhosttySelection);
        if (c.ghostty_selection_gesture_event(self.gesture, self.term, self.gesture_drag, &sel) == c.GHOSTTY_SUCCESS) {
            self.installSelection(&sel);
        }
    }

    pub fn selectRelease(self: *Session, hit: pointer.Hit) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var ref = self.viewportRef(hit.col, hit.row);
        setEvent(self.gesture_release, c.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, if (ref) |*r| r else null);
        _ = c.ghostty_selection_gesture_event(self.gesture, self.term, self.gesture_release, null);
    }

    /// Cheap to call on every keystroke: does nothing when nothing is selected.
    pub fn clearSelection(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var sel = sized(c.GhosttySelection);
        if (c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != c.GHOSTTY_SUCCESS) return;
        self.installSelection(null);
    }

    pub fn hasSelection(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var sel = sized(c.GhosttySelection);
        return c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == c.GHOSTTY_SUCCESS;
    }

    /// The selected text (soft-wrapped lines joined, trailing blanks trimmed),
    /// owned by `allocator`; null when nothing is selected.
    pub fn copySelection(self: *Session, allocator: std.mem.Allocator) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var sel = sized(c.GhosttySelection);
        if (c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != c.GHOSTTY_SUCCESS) return null;
        var opts = sized(c.GhosttyTerminalSelectionFormatOptions);
        opts.emit = c.GHOSTTY_FORMATTER_FORMAT_PLAIN;
        opts.unwrap = true;
        opts.trim = true;
        opts.selection = &sel;
        var ptr: [*c]u8 = null;
        var len: usize = 0;
        if (c.ghostty_terminal_selection_format_alloc(self.term, null, opts, &ptr, &len) != c.GHOSTTY_SUCCESS) return null;
        defer c.ghostty_free(null, ptr, len);
        if (len == 0) return null;
        return allocator.dupe(u8, ptr[0..len]) catch null;
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

fn testSession(term: c.GhosttyTerminal, cols: u16, rows: u16) !Session {
    var session = Session{ .allocator = std.testing.allocator, .cols = cols, .rows = rows, .cell_w = 10, .cell_h = 20 };
    session.term = term;
    try session.initPointer();
    return session;
}

fn hitAt(col: u16, row: u16) pointer.Hit {
    return .{ .col = col, .row = row, .fx = 0.25, .fy = 0.5, .inside = true };
}

/// The right half of a cell: a drag ending here includes the cell.
fn hitRight(col: u16, row: u16) pointer.Hit {
    return .{ .col = col, .row = row, .fx = 0.75, .fy = 0.5, .inside = true };
}

test "click, drag, double and triple click select and copy" {
    var term: c.GhosttyTerminal = null;
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_terminal_new(null, &term, 30, 4));
    defer c.ghostty_terminal_free(term);
    const text = "hello world foo.bar\r\nsecond line here";
    c.ghostty_terminal_vt_write(term, text, text.len);
    var s = try testSession(term, 30, 4);
    defer s.freePointer();

    // Drag across "hello".
    s.selectPress(hitAt(0, 0), 1_000_000_000);
    try std.testing.expect(!s.hasSelection());
    s.selectDrag(hitRight(4, 0), false);
    s.selectRelease(hitAt(4, 0));
    try std.testing.expect(s.hasSelection());
    const dragged = s.copySelection(std.testing.allocator).?;
    defer std.testing.allocator.free(dragged);
    try std.testing.expectEqualStrings("hello", dragged);

    // A plain click elsewhere clears it.
    s.selectPress(hitAt(20, 3), 5_000_000_000);
    s.selectRelease(hitAt(20, 3));
    try std.testing.expect(!s.hasSelection());
    try std.testing.expect(s.copySelection(std.testing.allocator) == null);

    // Double click selects the word under the pointer.
    s.selectPress(hitAt(7, 0), 10_000_000_000);
    s.selectRelease(hitAt(7, 0));
    s.selectPress(hitAt(7, 0), 10_200_000_000);
    const word = s.copySelection(std.testing.allocator).?;
    defer std.testing.allocator.free(word);
    try std.testing.expectEqualStrings("world", word);
    s.selectRelease(hitAt(7, 0));

    // Triple click selects the line.
    s.selectPress(hitAt(7, 0), 10_400_000_000);
    const line = s.copySelection(std.testing.allocator).?;
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("hello world foo.bar", line);

    s.clearSelection();
    try std.testing.expect(!s.hasSelection());
}

test "selected cells are flagged in the snapshot" {
    var term: c.GhosttyTerminal = null;
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_terminal_new(null, &term, 20, 3));
    defer c.ghostty_terminal_free(term);
    c.ghostty_terminal_vt_write(term, "abcdef", 6);
    var s = try testSession(term, 20, 3);
    defer s.freePointer();
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_render_state_new(null, &s.render));
    defer c.ghostty_render_state_free(s.render);
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_render_state_row_iterator_new(null, &s.row_iter));
    defer c.ghostty_render_state_row_iterator_free(s.row_iter);
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_render_state_row_cells_new(null, &s.row_cells));
    defer c.ghostty_render_state_row_cells_free(s.row_cells);

    var snap = Snapshot{};
    defer snap.deinit(std.testing.allocator);
    try std.testing.expect(s.snapshot(&snap));
    try std.testing.expect(!snap.cell(1, 0).selected);

    s.selectPress(hitAt(1, 0), 1_000_000_000);
    s.selectDrag(hitRight(3, 0), false);
    try std.testing.expect(s.snapshot(&snap));
    try std.testing.expect(!snap.cell(0, 0).selected);
    try std.testing.expect(snap.cell(1, 0).selected);
    try std.testing.expect(snap.cell(3, 0).selected);
    try std.testing.expect(!snap.cell(5, 0).selected);

    s.clearSelection();
    try std.testing.expect(s.snapshot(&snap));
    try std.testing.expect(!snap.cell(1, 0).selected);
}

test "mouse reports follow the tracking mode and focus reports mode 1004" {
    var term: c.GhosttyTerminal = null;
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_terminal_new(null, &term, 80, 24));
    defer c.ghostty_terminal_free(term);
    var s = try testSession(term, 80, 24);
    defer s.freePointer();
    var out: [128]u8 = undefined;

    var m = s.modes();
    try std.testing.expect(!m.mouse_tracking and !m.focus_events and !m.alt_screen);
    try std.testing.expectEqual(@as(usize, 0), s.mouseBytes(&out, .press, .left, 0, hitAt(4, 2), true));
    try std.testing.expectEqual(@as(usize, 0), s.focusBytes(&out, true));

    // Normal tracking (1000) with SGR encoding (1006), focus (1004), alt scroll (1007).
    const on = "\x1b[?1000h\x1b[?1006h\x1b[?1004h\x1b[?1007h";
    c.ghostty_terminal_vt_write(term, on, on.len);
    m = s.modes();
    try std.testing.expect(m.mouse_tracking and m.focus_events and m.alt_scroll and !m.alt_screen);

    // Column 4, row 2 are 1-based 5;3 in SGR.
    var n = s.mouseBytes(&out, .press, .left, 0, hitAt(4, 2), true);
    try std.testing.expectEqualStrings("\x1b[<0;5;3M", out[0..n]);
    n = s.mouseBytes(&out, .release, .left, 0, hitAt(4, 2), false);
    try std.testing.expectEqualStrings("\x1b[<0;5;3m", out[0..n]);
    // Wheel up is button four (64 in SGR).
    n = s.mouseBytes(&out, .press, .four, 0, hitAt(4, 2), false);
    try std.testing.expectEqualStrings("\x1b[<64;5;3M", out[0..n]);
    // Plain motion is not reported in normal tracking.
    try std.testing.expectEqual(@as(usize, 0), s.mouseBytes(&out, .motion, null, 0, hitAt(9, 9), false));

    n = s.focusBytes(&out, true);
    try std.testing.expectEqualStrings("\x1b[I", out[0..n]);
    n = s.focusBytes(&out, false);
    try std.testing.expectEqualStrings("\x1b[O", out[0..n]);

    // Alternate screen is reported.
    c.ghostty_terminal_vt_write(term, "\x1b[?1049h", 8);
    try std.testing.expect(s.modes().alt_screen);
}
