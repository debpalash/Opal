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
