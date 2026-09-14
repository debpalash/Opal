const std = @import("std");

pub const Target = struct {
    player_addr: usize,
    load_serial: u64,
    epoch: u64,
};

/// A generated subtitle belongs to one process-unique player allocation and
/// one logical replacement load. The epoch independently invalidates work on
/// media changes and shutdown.
pub fn matches(target: Target, player_addr: usize, load_serial: u64, epoch: u64) bool {
    return target.epoch == epoch and
        target.player_addr == player_addr and
        target.load_serial == load_serial;
}

test "subtitle generation target rejects replacement media and recycled players" {
    const target: Target = .{ .player_addr = 0x1234, .load_serial = 41, .epoch = 7 };
    try std.testing.expect(matches(target, 0x1234, 41, 7));
    try std.testing.expect(!matches(target, 0x1234, 42, 7));
    try std.testing.expect(!matches(target, 0x5678, 41, 7));
    try std.testing.expect(!matches(target, 0x1234, 41, 8));
}
