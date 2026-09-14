const std = @import("std");

pub const Stamp = struct {
    identity_hash: u64 = 0,
    sequence: u64 = 0,
    occupied: bool = false,
};

/// Admit only the newest observed save for one media identity. Callers
/// serialize this small table with the durable write it guards.
pub fn accept(stamps: []Stamp, cursor: *usize, identity_hash: u64, sequence: u64) bool {
    if (stamps.len == 0 or sequence == 0) return false;
    for (stamps) |*stamp| {
        if (!stamp.occupied or stamp.identity_hash != identity_hash) continue;
        if (sequence <= stamp.sequence) return false;
        stamp.sequence = sequence;
        return true;
    }

    const index = cursor.* % stamps.len;
    stamps[index] = .{ .identity_hash = identity_hash, .sequence = sequence, .occupied = true };
    cursor.* = (index + 1) % stamps.len;
    return true;
}

test "newer save makes a late older worker stale" {
    var stamps: [4]Stamp = [_]Stamp{.{}} ** 4;
    var cursor: usize = 0;
    try std.testing.expect(accept(&stamps, &cursor, 42, 2));
    try std.testing.expect(!accept(&stamps, &cursor, 42, 1));
    try std.testing.expect(accept(&stamps, &cursor, 42, 3));
}

test "different media identities advance independently" {
    var stamps: [2]Stamp = [_]Stamp{.{}} ** 2;
    var cursor: usize = 0;
    try std.testing.expect(accept(&stamps, &cursor, 10, 5));
    try std.testing.expect(accept(&stamps, &cursor, 20, 2));
    try std.testing.expect(!accept(&stamps, &cursor, 10, 4));
    try std.testing.expect(accept(&stamps, &cursor, 20, 3));
}

test "bounded table rotates without treating an empty hash as occupied" {
    var stamps: [1]Stamp = [_]Stamp{.{}} ** 1;
    var cursor: usize = 0;
    try std.testing.expect(accept(&stamps, &cursor, 0, 1));
    try std.testing.expect(!accept(&stamps, &cursor, 0, 1));
    try std.testing.expect(accept(&stamps, &cursor, 7, 2));
}
