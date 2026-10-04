//! The logic of the Agents page's terminal tabs, free of the UI toolkit and of
//! libghostty so it is tested alone: how many tabs may exist, what a tab is
//! called, which tab becomes active when one closes, and when a background tab
//! earns an attention marker.

const std = @import("std");

/// What a tab runs.
pub const Kind = enum { claude, codex, gemini, shell };

pub const kinds = [_]Kind{ .claude, .codex, .gemini, .shell };

pub fn kindTitle(kind: Kind) []const u8 {
    return switch (kind) {
        .claude => "Claude Code",
        .codex => "Codex",
        .gemini => "Gemini CLI",
        .shell => "Shell",
    };
}

/// Most sessions open at once. Each owns a pty, a reader thread and a snapshot.
pub const MAX_TABS: usize = 6;

pub fn canAdd(count: usize) bool {
    return count < MAX_TABS;
}

/// A tab as far as naming goes.
pub const Named = struct { kind: Kind, ordinal: u8 };

/// The lowest ordinal (from 1) that no open tab of `kind` uses, so closing
/// "Shell" and opening another gives "Shell" again, not "Shell 3".
pub fn nextOrdinal(open: []const Named, kind: Kind) u8 {
    var n: u8 = 1;
    while (n < 255) : (n += 1) {
        var used = false;
        for (open) |t| {
            if (t.kind == kind and t.ordinal == n) {
                used = true;
                break;
            }
        }
        if (!used) return n;
    }
    return n;
}

/// "Claude Code", "Shell 2": the ordinal shows from the second one on.
pub fn baseName(buf: []u8, kind: Kind, ordinal: u8) []const u8 {
    if (ordinal <= 1) return std.fmt.bufPrint(buf, "{s}", .{kindTitle(kind)}) catch kindTitle(kind);
    return std.fmt.bufPrint(buf, "{s} {d}", .{ kindTitle(kind), ordinal }) catch kindTitle(kind);
}

/// Longest tab label in bytes before the title is cut with an ellipsis, by how
/// many tabs share the strip: few tabs get room, six must all fit a small window.
pub fn labelMax(count: usize) usize {
    return if (count <= 2) 40 else if (count <= 4) 28 else 20;
}

/// The longest prefix of `s` of at most `max` bytes that ends on a character
/// boundary.
pub fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// What a tab shows: the agent name, then the terminal title when the program
/// set one, or "exited" once the process ended. Control bytes in a title become
/// spaces (a program controls that text). The name and title together stay within
/// `max` bytes (the name is never cut); `buf` should hold `max + 16`.
pub fn label(buf: []u8, base: []const u8, title: []const u8, exited: bool, max: usize) []const u8 {
    var n: usize = 0;
    appendBytes(buf, &n, base);
    if (exited) {
        appendBytes(buf, &n, " (exited)");
        return buf[0..n];
    }
    const t = std.mem.trim(u8, title, " \t\r\n");
    if (t.len == 0 or std.mem.eql(u8, t, base)) return buf[0..n];
    appendBytes(buf, &n, " \xc2\xb7 "); // middle dot
    const room = max -| n;
    const clipped = clipUtf8(t, room);
    const start = n;
    appendBytes(buf, &n, clipped);
    for (buf[start..n]) |*ch| {
        if (ch.* < 0x20 or ch.* == 0x7f) ch.* = ' ';
    }
    if (clipped.len < t.len) appendBytes(buf, &n, "\xe2\x80\xa6");
    return buf[0..n];
}

fn appendBytes(buf: []u8, n: *usize, bytes: []const u8) void {
    const k = @min(bytes.len, buf.len - n.*);
    @memcpy(buf[n.*..][0..k], bytes[0..k]);
    n.* += k;
}

/// The active tab after tab `closed` of `count` (before removal) went away while
/// `active` was active. Null when nothing is left. Closing the active tab moves to
/// its right neighbour, else its left; closing another tab keeps the same one active.
pub fn activeAfterClose(count: usize, closed: usize, active: usize) ?usize {
    if (count <= 1 or closed >= count) return if (count <= 1) null else active;
    if (closed == active) return if (closed + 1 < count) closed else closed - 1;
    return if (closed < active) active - 1 else active;
}

/// What a background tab shows next to its name.
pub const Marker = enum { none, title, bell };

/// The marker a tab shows after a frame: the active tab never has one (looking
/// at it clears it); a bell outranks a title change, and both stay until the
/// tab is activated.
pub fn markerAfter(prev: Marker, active: bool, bell: bool, title_changed: bool) Marker {
    if (active) return .none;
    if (bell or prev == .bell) return .bell;
    if (title_changed or prev == .title) return .title;
    return .none;
}

test "tabs are capped at six" {
    try std.testing.expect(canAdd(0));
    try std.testing.expect(canAdd(5));
    try std.testing.expect(!canAdd(6));
    try std.testing.expect(!canAdd(7));
}

test "a new tab takes the lowest free ordinal of its kind" {
    var open = [_]Named{.{ .kind = .shell, .ordinal = 1 }};
    try std.testing.expectEqual(@as(u8, 2), nextOrdinal(&open, .shell));
    try std.testing.expectEqual(@as(u8, 1), nextOrdinal(&open, .claude));
    const two = [_]Named{ .{ .kind = .shell, .ordinal = 2 }, .{ .kind = .claude, .ordinal = 1 } };
    // Shell 1 was closed: it is free again.
    try std.testing.expectEqual(@as(u8, 1), nextOrdinal(&two, .shell));
    const three = [_]Named{ .{ .kind = .shell, .ordinal = 1 }, .{ .kind = .shell, .ordinal = 2 } };
    try std.testing.expectEqual(@as(u8, 3), nextOrdinal(&three, .shell));
    try std.testing.expectEqual(@as(u8, 1), nextOrdinal(&.{}, .codex));
}

test "names show the ordinal from the second tab on" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Claude Code", baseName(&b, .claude, 1));
    try std.testing.expectEqualStrings("Shell 2", baseName(&b, .shell, 2));
    try std.testing.expectEqualStrings("Codex 3", baseName(&b, .codex, 3));
}

test "a label is the name, then the title, or exited" {
    var b: [56]u8 = undefined;
    try std.testing.expectEqualStrings("Codex", label(&b, "Codex", "", false, 40));
    try std.testing.expectEqualStrings("Codex", label(&b, "Codex", "  \n", false, 40));
    try std.testing.expectEqualStrings("Codex", label(&b, "Codex", "Codex", false, 40));
    try std.testing.expectEqualStrings("Codex \xc2\xb7 fixing tests", label(&b, "Codex", "fixing tests", false, 40));
    try std.testing.expectEqualStrings("Shell 2 (exited)", label(&b, "Shell 2", "bash", true, 40));
}

test "a long or hostile title is clipped on a character boundary and cleaned" {
    var b: [56]u8 = undefined;
    const long = "x" ** 100;
    const got = label(&b, "Shell", long, false, 40);
    try std.testing.expect(got.len <= 40 + 3);
    try std.testing.expect(std.mem.endsWith(u8, got, "\xe2\x80\xa6"));
    // Six tabs get less room than two.
    try std.testing.expect(label(&b, "Shell", long, false, labelMax(6)).len < got.len);
    // A title of two-byte characters never gets cut in the middle of one.
    const e = "\xc3\xa9" ** 50;
    for ([_]usize{ 20, 21, 28, 40 }) |m| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(label(&b, "Shell", e, false, m)));
    }
    // Escape and other control bytes cannot reach the screen.
    const g3 = label(&b, "Shell", "a\x1b[31mb\x07", false, 40);
    for (g3) |ch| try std.testing.expect(ch >= 0x20 and ch != 0x7f);
    // A tiny buffer gives a prefix rather than overflowing.
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("Code", label(&tiny, "Codex", "abc", false, 40));
}

test "closing a tab picks a neighbour" {
    // [A B C D], active B (1)
    try std.testing.expectEqual(@as(?usize, 1), activeAfterClose(4, 1, 1)); // close active: C slides in
    try std.testing.expectEqual(@as(?usize, 2), activeAfterClose(4, 3, 3)); // close last active: C
    try std.testing.expectEqual(@as(?usize, 0), activeAfterClose(4, 0, 1)); // close left of active: B stays active, now index 0
    try std.testing.expectEqual(@as(?usize, 1), activeAfterClose(4, 2, 1)); // close right of active: unchanged
    try std.testing.expectEqual(@as(?usize, null), activeAfterClose(1, 0, 0));
    try std.testing.expectEqual(@as(?usize, 0), activeAfterClose(2, 0, 0));
    try std.testing.expectEqual(@as(?usize, 0), activeAfterClose(2, 1, 1));
}

test "background tabs keep a marker until looked at" {
    try std.testing.expectEqual(Marker.none, markerAfter(.none, false, false, false));
    try std.testing.expectEqual(Marker.title, markerAfter(.none, false, false, true));
    try std.testing.expectEqual(Marker.title, markerAfter(.title, false, false, false));
    try std.testing.expectEqual(Marker.bell, markerAfter(.title, false, true, false));
    // A bell stays a bell even if only the title changes afterwards.
    try std.testing.expectEqual(Marker.bell, markerAfter(.bell, false, false, true));
    // The active tab never carries one.
    try std.testing.expectEqual(Marker.none, markerAfter(.bell, true, true, true));
}
