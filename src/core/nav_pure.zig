//! Pure encode/decode for the deferred cross-thread navigation slot
//! (state.pending_nav): 0 = none, else enum ordinal + 1, carried in a u8.
//!
//! Regression: the first version stored `@intFromEnum(tab) +| 1`. For a
//! 16-variant enum the tag type is u4, the comptime 1 coerces to u4, and the
//! saturating add runs IN u4 — so the last variant (ordinal 15) encoded as
//! 15 +| 1 == 15 and decoded as ordinal 14: navigateToTab(.Web) silently
//! opened the AI tab. Widening to u8 BEFORE the add fixes it; these helpers
//! are the shipped path so the tested logic is the production logic.

const std = @import("std");

pub fn encode(comptime E: type, tab: E) u8 {
    return @as(u8, @intFromEnum(tab)) + 1;
}

pub fn decode(comptime E: type, v: u8) ?E {
    if (v == 0) return null;
    const fields = @typeInfo(E).@"enum".fields;
    if (v - 1 >= fields.len) return null; // corrupted value
    return @enumFromInt(v - 1);
}

// Mirrors DrawerTab's shape: exactly 16 variants → u4 tag type, the case that
// triggered the saturating-add bug.
const Tab16 = enum { a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p };

test "every variant of a 16-entry enum round-trips (u4 saturation regression)" {
    inline for (@typeInfo(Tab16).@"enum".fields, 0..) |_, i| {
        const tab: Tab16 = @enumFromInt(i);
        const v = encode(Tab16, tab);
        try std.testing.expect(v != 0);
        try std.testing.expectEqual(tab, decode(Tab16, v).?);
    }
    // The exact failure case: the LAST variant must not alias its neighbor.
    try std.testing.expectEqual(Tab16.p, decode(Tab16, encode(Tab16, .p)).?);
    try std.testing.expect(encode(Tab16, .p) != encode(Tab16, .o));
}

test "decode rejects the empty slot and corrupted values" {
    try std.testing.expectEqual(@as(?Tab16, null), decode(Tab16, 0));
    try std.testing.expectEqual(@as(?Tab16, null), decode(Tab16, 17));
    try std.testing.expectEqual(@as(?Tab16, null), decode(Tab16, 255));
}
