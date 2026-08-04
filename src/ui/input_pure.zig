//! Pure input-gesture logic. No dvui, no state, no io_global — so it unit-tests
//! standalone and the shipped decision IS the tested decision (CLAUDE.md's
//! *_pure rule).
//!
//! Right now that means one gesture: the double-tap. It existed already, hand
//! rolled inline in grid.zig for double-click-to-fullscreen, with the threshold
//! as a bare `500` in the middle of an event loop. Adding the same gesture on
//! the F key would have meant a second copy and a second chance for the two to
//! drift, so the rule and the timing live here once.

const std = @import("std");

/// How long a second tap may lag the first and still count as one gesture.
///
/// 500ms is what the mouse path has always used, and matches the platform
/// double-click defaults closely enough (macOS ~500ms, Windows 500ms default)
/// that neither gesture feels different from the other.
pub const DOUBLE_TAP_MS: i64 = 500;

/// Tracks one double-tap gesture. Fixed size, no allocation: callers keep one
/// of these in a `struct { var }` static next to the handler.
pub const DoubleTap = struct {
    /// When the first tap of a potential pair landed. 0 = armed for a first tap.
    last_ms: i64 = 0,
    /// Which target the first tap was on (a grid cell index, a key code, ...).
    /// A second tap on a DIFFERENT target is a first tap, not a completion —
    /// otherwise clicking two cells in quick succession would fullscreen the
    /// second one.
    last_target: usize = no_target,

    pub const no_target: usize = std.math.maxInt(usize);

    /// Feed a tap; true when it completes a double-tap on `target`.
    ///
    /// On completion the state resets rather than carrying `now_ms` forward, so
    /// three taps are one double-tap plus one pending first tap — NOT two
    /// overlapping gestures. Without that a held-down key repeat would toggle
    /// fullscreen on every repeat after the first.
    pub fn tap(self: *DoubleTap, now_ms: i64, target: usize, threshold_ms: i64) bool {
        const completes = self.last_target == target and
            self.last_ms != 0 and
            // A clock that jumped backwards (suspend/resume, NTP step) must not
            // produce a negative "elapsed" that passes the window forever.
            now_ms >= self.last_ms and
            now_ms - self.last_ms < threshold_ms;
        if (completes) {
            self.* = .{};
            return true;
        }
        self.last_ms = now_ms;
        self.last_target = target;
        return false;
    }

    /// Forget any pending first tap — for when something else consumed the
    /// interaction and a later tap should not complete a stale gesture.
    pub fn reset(self: *DoubleTap) void {
        self.* = .{};
    }
};

test "two taps inside the window are one gesture" {
    var d = DoubleTap{};
    try std.testing.expect(!d.tap(1000, 0, DOUBLE_TAP_MS));
    try std.testing.expect(d.tap(1200, 0, DOUBLE_TAP_MS));
}

test "the second tap must be inside the window" {
    var d = DoubleTap{};
    try std.testing.expect(!d.tap(1000, 0, DOUBLE_TAP_MS));
    try std.testing.expect(!d.tap(1000 + DOUBLE_TAP_MS, 0, DOUBLE_TAP_MS));
    // ...but that late tap re-arms, so the next quick one still counts.
    try std.testing.expect(d.tap(1000 + DOUBLE_TAP_MS + 10, 0, DOUBLE_TAP_MS));
}

test "a tap on a different target starts over" {
    var d = DoubleTap{};
    try std.testing.expect(!d.tap(1000, 0, DOUBLE_TAP_MS));
    // Second cell, well inside the window: this is its FIRST tap, not a
    // completion — otherwise a quick click on cell A then cell B would
    // fullscreen B off a single click.
    try std.testing.expect(!d.tap(1050, 1, DOUBLE_TAP_MS));
    try std.testing.expect(d.tap(1100, 1, DOUBLE_TAP_MS));
}

test "three fast taps are one gesture plus a pending tap, not two" {
    // The reset on completion is what makes this true. Holding F down produces a
    // stream of key repeats; without it every repeat after the first would
    // toggle fullscreen, flickering the window.
    var d = DoubleTap{};
    try std.testing.expect(!d.tap(1000, 0, DOUBLE_TAP_MS));
    try std.testing.expect(d.tap(1100, 0, DOUBLE_TAP_MS));
    try std.testing.expect(!d.tap(1200, 0, DOUBLE_TAP_MS));
    try std.testing.expect(d.tap(1300, 0, DOUBLE_TAP_MS));
}

test "a backwards clock cannot hold the window open" {
    var d = DoubleTap{};
    try std.testing.expect(!d.tap(5000, 0, DOUBLE_TAP_MS));
    // Clock stepped back an hour: elapsed is negative, which a naive
    // `elapsed < threshold` would accept.
    try std.testing.expect(!d.tap(5000 - 3_600_000, 0, DOUBLE_TAP_MS));
    // And it re-armed from the new reading, so the gesture still works after.
    try std.testing.expect(d.tap(5000 - 3_600_000 + 100, 0, DOUBLE_TAP_MS));
}

test "reset drops a pending first tap" {
    var d = DoubleTap{};
    try std.testing.expect(!d.tap(1000, 0, DOUBLE_TAP_MS));
    d.reset();
    try std.testing.expect(!d.tap(1050, 0, DOUBLE_TAP_MS));
}

test "a fresh tracker never completes on its first tap" {
    // last_ms == 0 is the armed state; target 0 is a legitimate target, so the
    // guard cannot be "target matches" alone.
    var d = DoubleTap{};
    try std.testing.expect(!d.tap(0, 0, DOUBLE_TAP_MS));
}
