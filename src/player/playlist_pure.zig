//! Pure playlist-advance engine — no io, no globals, standalone-testable.
//!
//! "What plays next?" for the M3U playlist drawer routes through here:
//! player.zig's auto-advance (END_FILE) and the drawer's next/prev buttons
//! both call nextIndex/prevIndex via playlist.zig. Shuffle uses a
//! precomputed permutation (buildShuffleOrder) seeded by the caller so
//! tests are deterministic (production seeds from io_global.milliTimestamp()).

const std = @import("std");

pub const RepeatMode = enum(u8) {
    off,
    all,
    one,

    /// Toolbar cycle order: off → all → one → off.
    pub fn cycled(self: RepeatMode) RepeatMode {
        return switch (self) {
            .off => .all,
            .all => .one,
            .one => .off,
        };
    }
};

/// Fill `order` with a deterministic permutation of 0..order.len (Fisher-Yates).
/// Same seed + same len ⇒ same permutation.
pub fn buildShuffleOrder(order: []u32, seed: u64) void {
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    if (order.len < 2) return;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var i: usize = order.len - 1;
    while (i > 0) : (i -= 1) {
        const j = rand.uintAtMost(usize, i);
        std.mem.swap(u32, &order[i], &order[j]);
    }
}

/// Index that plays after `current`, or null to stop.
///  - repeat .one  → same index (replay)
///  - repeat .all  → wraps at the end
///  - repeat .off  → null at the end
/// With `shuffle_order` set, walk the permutation instead of natural order.
/// A stale order (len != count) or stale current (>= count) yields null —
/// never an out-of-bounds index.
pub fn nextIndex(current: usize, count: usize, repeat: RepeatMode, shuffle_order: ?[]const u32) ?usize {
    return step(current, count, repeat, shuffle_order, .forward);
}

/// Mirror of nextIndex, walking backwards. repeat .one still replays;
/// repeat .all wraps from the first item to the last; .off stops at the start.
pub fn prevIndex(current: usize, count: usize, repeat: RepeatMode, shuffle_order: ?[]const u32) ?usize {
    return step(current, count, repeat, shuffle_order, .backward);
}

const Direction = enum { forward, backward };

fn step(current: usize, count: usize, repeat: RepeatMode, shuffle_order: ?[]const u32, dir: Direction) ?usize {
    if (count == 0) return null;
    if (current >= count) return null; // stale index — never go out of bounds
    if (repeat == .one) return current;

    if (shuffle_order) |order| {
        if (order.len != count) return null; // stale permutation
        const pos = std.mem.indexOfScalar(u32, order, @intCast(current)) orelse return null;
        switch (dir) {
            .forward => {
                if (pos + 1 < order.len) return order[pos + 1];
                return if (repeat == .all) order[0] else null;
            },
            .backward => {
                if (pos > 0) return order[pos - 1];
                return if (repeat == .all) order[order.len - 1] else null;
            },
        }
    }

    switch (dir) {
        .forward => {
            if (current + 1 < count) return current + 1;
            return if (repeat == .all) 0 else null;
        },
        .backward => {
            if (current > 0) return current - 1;
            return if (repeat == .all) count - 1 else null;
        },
    }
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "repeat cycle order off→all→one→off" {
    try std.testing.expectEqual(RepeatMode.all, RepeatMode.off.cycled());
    try std.testing.expectEqual(RepeatMode.one, RepeatMode.all.cycled());
    try std.testing.expectEqual(RepeatMode.off, RepeatMode.one.cycled());
}

test "nextIndex repeat off: advances then stops at end" {
    try std.testing.expectEqual(@as(?usize, 1), nextIndex(0, 3, .off, null));
    try std.testing.expectEqual(@as(?usize, 2), nextIndex(1, 3, .off, null));
    try std.testing.expectEqual(@as(?usize, null), nextIndex(2, 3, .off, null));
}

test "nextIndex repeat all: wraps at end" {
    try std.testing.expectEqual(@as(?usize, 0), nextIndex(2, 3, .all, null));
    try std.testing.expectEqual(@as(?usize, 1), nextIndex(0, 3, .all, null));
}

test "nextIndex repeat one: replays same index" {
    try std.testing.expectEqual(@as(?usize, 1), nextIndex(1, 3, .one, null));
    try std.testing.expectEqual(@as(?usize, 0), nextIndex(0, 1, .one, null));
}

test "prevIndex repeat off: goes back then stops at start" {
    try std.testing.expectEqual(@as(?usize, 1), prevIndex(2, 3, .off, null));
    try std.testing.expectEqual(@as(?usize, null), prevIndex(0, 3, .off, null));
}

test "prevIndex repeat all: wraps from first to last" {
    try std.testing.expectEqual(@as(?usize, 2), prevIndex(0, 3, .all, null));
}

test "prevIndex repeat one: replays same index" {
    try std.testing.expectEqual(@as(?usize, 2), prevIndex(2, 3, .one, null));
}

test "empty playlist and stale current never advance" {
    try std.testing.expectEqual(@as(?usize, null), nextIndex(0, 0, .all, null));
    try std.testing.expectEqual(@as(?usize, null), prevIndex(0, 0, .all, null));
    // current out of range (playlist shrank underneath us)
    try std.testing.expectEqual(@as(?usize, null), nextIndex(5, 3, .all, null));
    try std.testing.expectEqual(@as(?usize, null), prevIndex(5, 3, .off, null));
}

test "single-item playlist" {
    try std.testing.expectEqual(@as(?usize, null), nextIndex(0, 1, .off, null));
    try std.testing.expectEqual(@as(?usize, 0), nextIndex(0, 1, .all, null));
    try std.testing.expectEqual(@as(?usize, 0), prevIndex(0, 1, .all, null));
}

test "shuffle order is a deterministic permutation covering every index once" {
    var a: [16]u32 = undefined;
    var b: [16]u32 = undefined;
    buildShuffleOrder(&a, 42);
    buildShuffleOrder(&b, 42);
    try std.testing.expectEqualSlices(u32, &a, &b); // same seed ⇒ same order

    // Permutation: every index 0..16 appears exactly once.
    var seen = [_]bool{false} ** 16;
    for (a) |v| {
        try std.testing.expect(v < 16);
        try std.testing.expect(!seen[v]);
        seen[v] = true;
    }

    // A different seed produces a different order (16! ≫ collision odds).
    var c: [16]u32 = undefined;
    buildShuffleOrder(&c, 43);
    try std.testing.expect(!std.mem.eql(u32, &a, &c));
}

test "shuffle: nextIndex walks the permutation, wraps only on repeat all" {
    const order = [_]u32{ 2, 0, 3, 1 };
    // Walk: 2 → 0 → 3 → 1
    try std.testing.expectEqual(@as(?usize, 0), nextIndex(2, 4, .off, &order));
    try std.testing.expectEqual(@as(?usize, 3), nextIndex(0, 4, .off, &order));
    try std.testing.expectEqual(@as(?usize, 1), nextIndex(3, 4, .off, &order));
    // End of shuffle order: stop on .off, wrap to order[0] on .all.
    try std.testing.expectEqual(@as(?usize, null), nextIndex(1, 4, .off, &order));
    try std.testing.expectEqual(@as(?usize, 2), nextIndex(1, 4, .all, &order));
    // repeat one wins over shuffle
    try std.testing.expectEqual(@as(?usize, 3), nextIndex(3, 4, .one, &order));
}

test "shuffle: prevIndex walks the permutation backwards" {
    const order = [_]u32{ 2, 0, 3, 1 };
    try std.testing.expectEqual(@as(?usize, 3), prevIndex(1, 4, .off, &order));
    try std.testing.expectEqual(@as(?usize, 0), prevIndex(3, 4, .off, &order));
    try std.testing.expectEqual(@as(?usize, 2), prevIndex(0, 4, .off, &order));
    // Start of shuffle order: stop on .off, wrap to the last on .all.
    try std.testing.expectEqual(@as(?usize, null), prevIndex(2, 4, .off, &order));
    try std.testing.expectEqual(@as(?usize, 1), prevIndex(2, 4, .all, &order));
}

test "shuffle: stale order length yields null (playlist changed under us)" {
    const order = [_]u32{ 1, 0 };
    try std.testing.expectEqual(@as(?usize, null), nextIndex(0, 3, .all, &order));
    try std.testing.expectEqual(@as(?usize, null), prevIndex(0, 3, .all, &order));
}
