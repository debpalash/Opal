//! Mapping from the UI toolkit's key names to libghostty-vt keys.
//!
//! Keyed by name so this file does not depend on the toolkit and can be tested
//! alone. A "text key" produces a character the toolkit also reports through
//! its text event, so it is sent from there; every other key goes through the
//! key encoder, which knows cursor-key mode, the kitty protocol and so on.

const std = @import("std");
const session = @import("session.zig");
const c = session.c;

pub const Entry = struct {
    name: []const u8,
    key: c.GhosttyKey,
    /// The unshifted character, for keys that type one (0 otherwise).
    ch: u8 = 0,
    /// Typing this key is reported as text by the toolkit.
    text: bool = false,
};

fn letters() [26]Entry {
    var out: [26]Entry = undefined;
    for (0..26) |i| {
        const n: u8 = @intCast(i);
        out[i] = .{
            .name = &[_]u8{'a' + n},
            .key = c.GHOSTTY_KEY_A + @as(c_int, n),
            .ch = 'a' + n,
            .text = true,
        };
    }
    return out;
}

const digit_names = [_][]const u8{ "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" };

fn digits() [10]Entry {
    var out: [10]Entry = undefined;
    for (0..10) |i| {
        const n: u8 = @intCast(i);
        out[i] = .{ .name = digit_names[i], .key = c.GHOSTTY_KEY_DIGIT_0 + @as(c_int, n), .ch = '0' + n, .text = true };
    }
    return out;
}

const fn_names = [_][]const u8{ "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24", "f25" };

fn functionKeys() [25]Entry {
    var out: [25]Entry = undefined;
    for (0..25) |i| out[i] = .{ .name = fn_names[i], .key = c.GHOSTTY_KEY_F1 + @as(c_int, @intCast(i)) };
    return out;
}

const kp_names = [_][]const u8{ "kp_0", "kp_1", "kp_2", "kp_3", "kp_4", "kp_5", "kp_6", "kp_7", "kp_8", "kp_9" };

fn keypad() [10]Entry {
    var out: [10]Entry = undefined;
    for (0..10) |i| {
        const n: u8 = @intCast(i);
        out[i] = .{ .name = kp_names[i], .key = c.GHOSTTY_KEY_NUMPAD_0 + @as(c_int, n), .ch = '0' + n, .text = true };
    }
    return out;
}

const fixed = [_]Entry{
    .{ .name = "space", .key = c.GHOSTTY_KEY_SPACE, .ch = ' ', .text = true },
    .{ .name = "minus", .key = c.GHOSTTY_KEY_MINUS, .ch = '-', .text = true },
    .{ .name = "equal", .key = c.GHOSTTY_KEY_EQUAL, .ch = '=', .text = true },
    .{ .name = "left_bracket", .key = c.GHOSTTY_KEY_BRACKET_LEFT, .ch = '[', .text = true },
    .{ .name = "right_bracket", .key = c.GHOSTTY_KEY_BRACKET_RIGHT, .ch = ']', .text = true },
    .{ .name = "backslash", .key = c.GHOSTTY_KEY_BACKSLASH, .ch = '\\', .text = true },
    .{ .name = "semicolon", .key = c.GHOSTTY_KEY_SEMICOLON, .ch = ';', .text = true },
    .{ .name = "apostrophe", .key = c.GHOSTTY_KEY_QUOTE, .ch = '\'', .text = true },
    .{ .name = "comma", .key = c.GHOSTTY_KEY_COMMA, .ch = ',', .text = true },
    .{ .name = "period", .key = c.GHOSTTY_KEY_PERIOD, .ch = '.', .text = true },
    .{ .name = "slash", .key = c.GHOSTTY_KEY_SLASH, .ch = '/', .text = true },
    .{ .name = "grave", .key = c.GHOSTTY_KEY_BACKQUOTE, .ch = '`', .text = true },
    .{ .name = "kp_divide", .key = c.GHOSTTY_KEY_NUMPAD_DIVIDE, .ch = '/', .text = true },
    .{ .name = "kp_multiply", .key = c.GHOSTTY_KEY_NUMPAD_MULTIPLY, .ch = '*', .text = true },
    .{ .name = "kp_subtract", .key = c.GHOSTTY_KEY_NUMPAD_SUBTRACT, .ch = '-', .text = true },
    .{ .name = "kp_add", .key = c.GHOSTTY_KEY_NUMPAD_ADD, .ch = '+', .text = true },
    .{ .name = "kp_decimal", .key = c.GHOSTTY_KEY_NUMPAD_DECIMAL, .ch = '.', .text = true },
    .{ .name = "kp_equal", .key = c.GHOSTTY_KEY_NUMPAD_EQUAL, .ch = '=', .text = true },
    // Keys that never type a character: always encoded.
    .{ .name = "kp_enter", .key = c.GHOSTTY_KEY_NUMPAD_ENTER },
    .{ .name = "enter", .key = c.GHOSTTY_KEY_ENTER },
    .{ .name = "escape", .key = c.GHOSTTY_KEY_ESCAPE },
    .{ .name = "tab", .key = c.GHOSTTY_KEY_TAB },
    .{ .name = "backspace", .key = c.GHOSTTY_KEY_BACKSPACE },
    .{ .name = "delete", .key = c.GHOSTTY_KEY_DELETE },
    .{ .name = "insert", .key = c.GHOSTTY_KEY_INSERT },
    .{ .name = "home", .key = c.GHOSTTY_KEY_HOME },
    .{ .name = "end", .key = c.GHOSTTY_KEY_END },
    .{ .name = "page_up", .key = c.GHOSTTY_KEY_PAGE_UP },
    .{ .name = "page_down", .key = c.GHOSTTY_KEY_PAGE_DOWN },
    .{ .name = "left", .key = c.GHOSTTY_KEY_ARROW_LEFT },
    .{ .name = "right", .key = c.GHOSTTY_KEY_ARROW_RIGHT },
    .{ .name = "up", .key = c.GHOSTTY_KEY_ARROW_UP },
    .{ .name = "down", .key = c.GHOSTTY_KEY_ARROW_DOWN },
};

const table = blk: {
    const l = letters();
    const d = digits();
    const f = functionKeys();
    const k = keypad();
    var all: [l.len + d.len + f.len + k.len + fixed.len]Entry = undefined;
    var n: usize = 0;
    for (l) |e| {
        all[n] = e;
        n += 1;
    }
    for (d) |e| {
        all[n] = e;
        n += 1;
    }
    for (f) |e| {
        all[n] = e;
        n += 1;
    }
    for (k) |e| {
        all[n] = e;
        n += 1;
    }
    for (fixed) |e| {
        all[n] = e;
        n += 1;
    }
    break :blk all;
};

/// The libghostty-vt entry for a toolkit key name, or null for keys the
/// terminal never receives (modifiers, lock keys, unknown).
pub fn find(name: []const u8) ?*const Entry {
    for (&table) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub const Mods = struct { shift: bool = false, ctrl: bool = false, alt: bool = false, super: bool = false };

pub fn mods(m: Mods) c.GhosttyMods {
    var out: c.GhosttyMods = 0;
    if (m.shift) out |= c.GHOSTTY_MODS_SHIFT;
    if (m.ctrl) out |= c.GHOSTTY_MODS_CTRL;
    if (m.alt) out |= c.GHOSTTY_MODS_ALT;
    if (m.super) out |= c.GHOSTTY_MODS_SUPER;
    return out;
}

/// What a key press should do. Text keys without ctrl/alt/super are left to the
/// toolkit's text event, so a character is never sent twice.
pub const Plan = enum { ignore, encode, wait_for_text };

pub fn plan(entry: ?*const Entry, m: Mods) Plan {
    const e = entry orelse return .ignore;
    if (!e.text) return .encode;
    if (m.ctrl or m.alt or m.super) return .encode;
    return .wait_for_text;
}

/// The one chord that always hands the keyboard back to Opal: while the
/// terminal has focus every other key (Tab, Escape, Ctrl+Q) belongs to the
/// program in it.
pub fn isReleaseChord(name: []const u8, m: Mods) bool {
    return std.mem.eql(u8, name, "escape") and m.ctrl and m.shift and !m.alt and !m.super;
}

/// Clipboard chords. macOS: Cmd+C / Cmd+V (Shift allowed, never with Ctrl or
/// Alt). Elsewhere: Ctrl+Shift+C / Ctrl+Shift+V, and the classic Ctrl+Insert
/// (copy) and Shift+Insert (paste). Plain Ctrl+C and Ctrl+V are never taken: they
/// belong to the program (interrupt, quoted insert).
pub const Clip = enum { none, copy, paste };

pub fn clipboardChord(mac: bool, name: []const u8, m: Mods) Clip {
    const copy = std.mem.eql(u8, name, "c");
    const paste = std.mem.eql(u8, name, "v");
    if (mac) {
        if (!m.super or m.ctrl or m.alt) return .none;
        return if (copy) .copy else if (paste) .paste else .none;
    }
    if (m.alt or m.super) return .none;
    if (m.ctrl and m.shift) return if (copy) .copy else if (paste) .paste else .none;
    if (std.mem.eql(u8, name, "insert")) {
        if (m.ctrl and !m.shift) return .copy;
        if (m.shift and !m.ctrl) return .paste;
    }
    return .none;
}

/// Input method composition. The toolkit reports the text being composed
/// (preedit) as a text event flagged `selected`, and the finished text as a plain
/// one. Only the plain one is typed; the preedit must not reach the program (it
/// would arrive twice), and keys the input method uses to edit or confirm the
/// composition (Enter, Backspace, arrows) must not reach it either, or a stray
/// carriage return follows every confirmed word. Times are nanoseconds on any
/// monotonic clock (the frame time).
pub const ImeGuard = struct {
    composing: bool = false,
    last_ns: i128 = 0,
    ended_ns: i128 = 0,

    /// A composition that sent nothing for this long is taken as abandoned, so a
    /// lost "preedit cleared" event cannot leave the keyboard dead.
    pub const stale_ns: i128 = 10 * std.time.ns_per_s;
    /// The key that confirmed a composition can arrive just after its text.
    pub const grace_ns: i128 = 30 * std.time.ns_per_ms;

    /// A text event: `selected` is the toolkit's flag for composing text. Returns
    /// whether the text should be typed.
    pub fn onText(self: *ImeGuard, txt_len: usize, selected: bool, now: i128) bool {
        if (selected) {
            if (self.composing and txt_len == 0) self.ended_ns = now;
            self.composing = txt_len > 0;
            self.last_ns = now;
            return false;
        }
        if (self.composing) self.ended_ns = now;
        self.composing = false;
        return true;
    }

    /// Whether a key press belongs to the input method. Ctrl, Alt and Super
    /// chords never do.
    pub fn swallowsKey(self: *const ImeGuard, m: Mods, now: i128) bool {
        if (m.ctrl or m.alt or m.super) return false;
        if (self.composing and now - self.last_ns < stale_ns) return true;
        return self.ended_ns != 0 and now - self.ended_ns <= grace_ns;
    }

    pub fn reset(self: *ImeGuard) void {
        self.* = .{};
    }
};

/// Some toolkits report Alt+x or Ctrl+x as a key and as a text event too. The key
/// is already encoded, so the text that directly follows it with the same
/// character must be dropped, and nothing else: Enter then `x` in one frame
/// types both. Create one per frame.
pub const TextGuard = struct {
    skip: u8 = 0,

    /// Call for every key press, in order.
    pub fn onKey(self: *TextGuard, entry: ?*const Entry, m: Mods) void {
        self.skip = 0;
        const e = entry orelse return;
        if (e.text and e.ch != 0 and (m.ctrl or m.alt or m.super)) self.skip = e.ch;
    }

    /// Whether the text event just seen is the echo of an encoded key.
    pub fn drops(self: *TextGuard, text: []const u8) bool {
        const hit = self.skip != 0 and text.len == 1 and std.ascii.toLower(text[0]) == self.skip;
        self.skip = 0;
        return hit;
    }
};

test "only the release chord releases the keyboard" {
    try std.testing.expect(isReleaseChord("escape", .{ .ctrl = true, .shift = true }));
    try std.testing.expect(!isReleaseChord("escape", .{}));
    try std.testing.expect(!isReleaseChord("escape", .{ .ctrl = true }));
    try std.testing.expect(!isReleaseChord("q", .{ .ctrl = true, .shift = true }));
    try std.testing.expect(!isReleaseChord("escape", .{ .ctrl = true, .shift = true, .alt = true }));
}

test "clipboard chords: Cmd on macOS, Ctrl+Shift elsewhere, never plain Ctrl" {
    try std.testing.expectEqual(Clip.copy, clipboardChord(true, "c", .{ .super = true }));
    try std.testing.expectEqual(Clip.paste, clipboardChord(true, "v", .{ .super = true }));
    try std.testing.expectEqual(Clip.paste, clipboardChord(true, "v", .{ .super = true, .shift = true }));
    // On macOS Ctrl+C is the interrupt, and Ctrl+Shift+C is not a chord.
    try std.testing.expectEqual(Clip.none, clipboardChord(true, "c", .{ .ctrl = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(true, "c", .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(true, "c", .{ .super = true, .alt = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(true, "c", .{ .super = true, .ctrl = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(true, "x", .{ .super = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(true, "c", .{}));

    try std.testing.expectEqual(Clip.copy, clipboardChord(false, "c", .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Clip.paste, clipboardChord(false, "v", .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(false, "c", .{ .ctrl = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(false, "v", .{ .ctrl = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(false, "c", .{ .super = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(false, "c", .{ .ctrl = true, .shift = true, .alt = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(false, "c", .{ .ctrl = true, .shift = true, .super = true }));
    try std.testing.expectEqual(Clip.copy, clipboardChord(false, "insert", .{ .ctrl = true }));
    try std.testing.expectEqual(Clip.paste, clipboardChord(false, "insert", .{ .shift = true }));
    try std.testing.expectEqual(Clip.none, clipboardChord(false, "insert", .{}));
    try std.testing.expectEqual(Clip.none, clipboardChord(true, "insert", .{ .shift = true }));
}

test "composing text is not typed, only the committed text is" {
    var g = ImeGuard{};
    const t0: i128 = 1_000_000_000;
    try std.testing.expect(!g.onText(3, true, t0)); // preedit "ni"
    try std.testing.expect(!g.onText(6, true, t0 + 1)); // preedit grows
    try std.testing.expect(g.composing);
    try std.testing.expect(!g.onText(0, true, t0 + 2)); // preedit cleared...
    try std.testing.expect(g.onText(6, false, t0 + 2)); // ...and the commit types
    try std.testing.expect(!g.composing);
    // Ordinary typing is plain text and never composing.
    try std.testing.expect(g.onText(1, false, t0 + 100_000_000));
}

test "the key that confirms a composition is swallowed, later keys are not" {
    var g = ImeGuard{};
    const t0: i128 = 5 * std.time.ns_per_s;
    _ = g.onText(3, true, t0);
    // Enter while composing belongs to the input method.
    try std.testing.expect(g.swallowsKey(.{}, t0 + 1));
    // Ctrl+C still reaches the program.
    try std.testing.expect(!g.swallowsKey(.{ .ctrl = true }, t0 + 1));
    // Commit, then Enter in the same frame (or just after) is the confirming key.
    _ = g.onText(3, false, t0 + 2);
    try std.testing.expect(g.swallowsKey(.{}, t0 + 2));
    try std.testing.expect(g.swallowsKey(.{}, t0 + 2 + ImeGuard.grace_ns));
    // A real Enter a moment later goes through.
    try std.testing.expect(!g.swallowsKey(.{}, t0 + 2 + ImeGuard.grace_ns + 1));
    // Typing without composition never swallows anything.
    var h = ImeGuard{};
    _ = h.onText(1, false, t0);
    try std.testing.expect(!h.swallowsKey(.{}, t0));
}

test "a composition that never ends does not lock the keyboard" {
    var g = ImeGuard{};
    _ = g.onText(3, true, 1_000);
    try std.testing.expect(g.swallowsKey(.{}, 1_000 + ImeGuard.stale_ns - 1));
    try std.testing.expect(!g.swallowsKey(.{}, 1_000 + ImeGuard.stale_ns));
    g.reset();
    try std.testing.expect(!g.composing);
}

test "text after Enter in the same frame is kept, the echo of Alt+x is dropped" {
    var g = TextGuard{};
    g.onKey(find("enter"), .{});
    try std.testing.expect(!g.drops("x"));

    g.onKey(find("x"), .{ .alt = true });
    try std.testing.expect(g.drops("x"));
    // The drop is one-shot: a second x types.
    try std.testing.expect(!g.drops("x"));

    // A different character after Alt+x is real typing.
    g.onKey(find("x"), .{ .alt = true });
    try std.testing.expect(!g.drops("y"));

    // Shifted echo still matches; a later key clears the pending drop.
    g.onKey(find("a"), .{ .alt = true, .shift = true });
    try std.testing.expect(g.drops("A"));
    g.onKey(find("a"), .{ .ctrl = true });
    g.onKey(find("enter"), .{});
    try std.testing.expect(!g.drops("a"));
}

test "letters, digits and named keys resolve" {
    try std.testing.expect(find("a").?.key == c.GHOSTTY_KEY_A);
    try std.testing.expect(find("z").?.key == c.GHOSTTY_KEY_Z);
    try std.testing.expectEqual(@as(u8, 'q'), find("q").?.ch);
    try std.testing.expect(find("zero").?.key == c.GHOSTTY_KEY_DIGIT_0);
    try std.testing.expect(find("nine").?.key == c.GHOSTTY_KEY_DIGIT_9);
    try std.testing.expect(find("f1").?.key == c.GHOSTTY_KEY_F1);
    try std.testing.expect(find("f12").?.key == c.GHOSTTY_KEY_F12);
    try std.testing.expect(find("kp_5").?.key == c.GHOSTTY_KEY_NUMPAD_5);
    try std.testing.expect(find("page_down").?.key == c.GHOSTTY_KEY_PAGE_DOWN);
    try std.testing.expect(find("up").?.key == c.GHOSTTY_KEY_ARROW_UP);
    try std.testing.expect(find("grave").?.key == c.GHOSTTY_KEY_BACKQUOTE);
}

test "modifier and unknown keys are not sent" {
    try std.testing.expect(find("left_shift") == null);
    try std.testing.expect(find("left_control") == null);
    try std.testing.expect(find("caps_lock") == null);
    try std.testing.expect(find("unknown") == null);
    try std.testing.expectEqual(Plan.ignore, plan(find("left_alt"), .{}));
}

test "plain typing waits for the text event but ctrl and alt encode" {
    try std.testing.expectEqual(Plan.wait_for_text, plan(find("a"), .{}));
    try std.testing.expectEqual(Plan.wait_for_text, plan(find("a"), .{ .shift = true }));
    try std.testing.expectEqual(Plan.encode, plan(find("c"), .{ .ctrl = true }));
    try std.testing.expectEqual(Plan.encode, plan(find("b"), .{ .alt = true }));
    try std.testing.expectEqual(Plan.encode, plan(find("enter"), .{}));
    try std.testing.expectEqual(Plan.encode, plan(find("escape"), .{}));
    try std.testing.expectEqual(Plan.encode, plan(find("up"), .{}));
    try std.testing.expectEqual(Plan.encode, plan(find("f5"), .{}));
}

test "ctrl-c encodes to ETX through the real encoder" {
    var enc: c.GhosttyKeyEncoder = null;
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_key_encoder_new(null, &enc));
    defer c.ghostty_key_encoder_free(enc);
    var ev: c.GhosttyKeyEvent = null;
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_key_event_new(null, &ev));
    defer c.ghostty_key_event_free(ev);
    const entry = find("c").?;
    c.ghostty_key_event_set_action(ev, c.GHOSTTY_KEY_ACTION_PRESS);
    c.ghostty_key_event_set_key(ev, entry.key);
    c.ghostty_key_event_set_mods(ev, mods(.{ .ctrl = true }));
    var out: [32]u8 = undefined;
    var written: usize = 0;
    try std.testing.expectEqual(@as(c_int, c.GHOSTTY_SUCCESS), c.ghostty_key_encoder_encode(enc, ev, &out, out.len, &written));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x03}, out[0..written]);
}
