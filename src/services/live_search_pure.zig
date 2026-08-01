//! When a type-as-you-go search box should actually issue a request.
//!
//! Split out of the draw call because every rule here is a way to waste an API
//! call or make the box feel broken, and none of them are obvious:
//!
//!   * Fire on every keystroke and a five-letter title costs five TMDB requests,
//!     four of which are thrown away — and they can land out of order, so the
//!     grid ends up showing results for a prefix of what was typed.
//!   * Fire on one character and "a" searches the entire catalogue.
//!   * Fire again for text already searched and every repaint re-requests.
//!   * Fire while a request is in flight and the same race comes back.
//!
//! The caller records WHEN the text last changed; this decides whether enough
//! quiet has passed since.

const std = @import("std");

/// Quiet period after the last keystroke before a request goes out. 350ms is
/// past a typical inter-key gap while still feeling immediate.
pub const DEBOUNCE_MS: i64 = 350;

/// Below this, the query matches too much to be worth a round trip.
pub const MIN_CHARS: usize = 2;

pub const Input = struct {
    /// What is in the box right now.
    current: []const u8,
    /// What was last actually requested (empty if nothing yet).
    last_fired: []const u8,
    /// Milliseconds since `current` last changed.
    ms_since_change: i64,
    /// A request is already running.
    in_flight: bool,
    debounce_ms: i64 = DEBOUNCE_MS,
    min_chars: usize = MIN_CHARS,
};

/// Whether to issue a search request now.
pub fn shouldFire(in: Input) bool {
    if (in.in_flight) return false;
    if (in.current.len < in.min_chars) return false;
    // Already searched for exactly this — a repaint is not a new query.
    if (std.mem.eql(u8, in.current, in.last_fired)) return false;
    if (in.ms_since_change < in.debounce_ms) return false;
    return true;
}

/// Whether clearing the box should restore the pre-search view.
///
/// Separate from `shouldFire` because it is the one transition that must NOT
/// wait for the debounce: the user has deleted everything and is looking at
/// stale results for a query that no longer exists. Restoring immediately is
/// what makes the box feel like it is tracking them.
pub fn shouldRestore(current: []const u8, last_fired: []const u8) bool {
    return current.len == 0 and last_fired.len > 0;
}

// ── Tests ──

const t = std.testing;

test "shouldFire waits for the typing to stop" {
    // Mid-word: no request.
    try t.expect(!shouldFire(.{ .current = "mat", .last_fired = "", .ms_since_change = 50, .in_flight = false }));
    try t.expect(!shouldFire(.{ .current = "mat", .last_fired = "", .ms_since_change = 349, .in_flight = false }));
    // Quiet long enough: go.
    try t.expect(shouldFire(.{ .current = "mat", .last_fired = "", .ms_since_change = 350, .in_flight = false }));
    try t.expect(shouldFire(.{ .current = "mat", .last_fired = "", .ms_since_change = 5000, .in_flight = false }));
}

test "shouldFire: one character is not a query" {
    // "a" would match the whole catalogue; the round trip is pure waste.
    try t.expect(!shouldFire(.{ .current = "a", .last_fired = "", .ms_since_change = 9999, .in_flight = false }));
    try t.expect(!shouldFire(.{ .current = "", .last_fired = "", .ms_since_change = 9999, .in_flight = false }));
    try t.expect(shouldFire(.{ .current = "ab", .last_fired = "", .ms_since_change = 9999, .in_flight = false }));
}

test "shouldFire: identical text never re-requests" {
    // REGRESSION GUARD: this runs from a draw call, so without it every repaint
    // issues another request for the text already on screen.
    try t.expect(!shouldFire(.{ .current = "matrix", .last_fired = "matrix", .ms_since_change = 9999, .in_flight = false }));
    // One more character is a different query.
    try t.expect(shouldFire(.{ .current = "matrix2", .last_fired = "matrix", .ms_since_change = 9999, .in_flight = false }));
    // So is deleting one, as long as it stays long enough to be worth asking.
    try t.expect(shouldFire(.{ .current = "matri", .last_fired = "matrix", .ms_since_change = 9999, .in_flight = false }));
}

test "shouldFire: never overlaps an in-flight request" {
    // Two overlapping requests can land out of order and leave the grid showing
    // results for a prefix of what was typed.
    try t.expect(!shouldFire(.{ .current = "matrix", .last_fired = "", .ms_since_change = 9999, .in_flight = true }));
}

test "shouldRestore fires the moment the box is emptied" {
    // Deliberately NOT debounced: the user is staring at results for a query
    // they just deleted.
    try t.expect(shouldRestore("", "matrix"));
    // Nothing was searched, so there is nothing to restore.
    try t.expect(!shouldRestore("", ""));
    // Still typing: not a restore.
    try t.expect(!shouldRestore("m", "matrix"));
}

test "debounce/min-chars are overridable for callers with other budgets" {
    try t.expect(shouldFire(.{ .current = "m", .last_fired = "", .ms_since_change = 10, .in_flight = false, .debounce_ms = 0, .min_chars = 1 }));
    try t.expect(!shouldFire(.{ .current = "mat", .last_fired = "", .ms_since_change = 900, .in_flight = false, .debounce_ms = 1000 }));
}
