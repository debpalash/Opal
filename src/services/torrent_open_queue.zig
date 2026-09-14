//! Bounded FIFO for magnet/.torrent opens received before libtorrent is ready.
//! Synchronization and UI wakeups live in search.zig; this file owns the
//! deterministic storage policy and is unit-tested without a torrent engine.

const std = @import("std");

pub const CAPACITY: usize = 8;
pub const MAX_SOURCE: usize = 4095;
pub const Kind = enum { magnet, torrent_file };

pub const Entry = struct {
    kind: Kind = .magnet,
    source: [MAX_SOURCE + 1]u8 = [_]u8{0} ** (MAX_SOURCE + 1),
    len: usize = 0,

    pub fn slice(self: *const Entry) []const u8 {
        return self.source[0..self.len];
    }
};

pub const Queue = struct {
    slots: [CAPACITY]Entry = [_]Entry{.{}} ** CAPACITY,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *Queue, kind: Kind, source: []const u8) bool {
        if (source.len == 0 or source.len > MAX_SOURCE or self.count == CAPACITY) return false;
        const slot = (self.head + self.count) % CAPACITY;
        @memset(&self.slots[slot].source, 0);
        @memcpy(self.slots[slot].source[0..source.len], source);
        self.slots[slot].len = source.len;
        self.slots[slot].kind = kind;
        self.count += 1;
        return true;
    }

    pub fn pop(self: *Queue) ?Entry {
        if (self.count == 0) return null;
        const slot = self.head;
        const result = self.slots[slot];
        self.slots[slot] = .{};
        self.head = (self.head + 1) % CAPACITY;
        self.count -= 1;
        return result;
    }
};

test "queue preserves FIFO order and kind across wraparound" {
    var q: Queue = .{};
    for (0..CAPACITY) |i| {
        var buf: [16]u8 = undefined;
        const source = try std.fmt.bufPrint(&buf, "magnet:{d}", .{i});
        try std.testing.expect(q.push(if (i % 2 == 0) .magnet else .torrent_file, source));
    }
    try std.testing.expect(!q.push(.magnet, "magnet:overflow"));
    for (0..4) |i| {
        const entry = q.pop().?;
        var expected_buf: [16]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "magnet:{d}", .{i});
        try std.testing.expectEqualStrings(expected, entry.slice());
    }
    for (0..4) |i| {
        var buf: [16]u8 = undefined;
        const source = try std.fmt.bufPrint(&buf, "later:{d}", .{i});
        try std.testing.expect(q.push(.torrent_file, source));
    }
    for (4..CAPACITY) |i| {
        const entry = q.pop().?;
        var expected_buf: [16]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "magnet:{d}", .{i});
        try std.testing.expectEqualStrings(expected, entry.slice());
    }
    for (0..4) |i| {
        const entry = q.pop().?;
        var expected_buf: [16]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "later:{d}", .{i});
        try std.testing.expectEqualStrings(expected, entry.slice());
        try std.testing.expectEqual(Kind.torrent_file, entry.kind);
    }
    try std.testing.expect(q.pop() == null);
}

test "queue rejects empty and overlong sources without mutating state" {
    var q: Queue = .{};
    try std.testing.expect(!q.push(.magnet, ""));
    const too_long = [_]u8{'x'} ** (MAX_SOURCE + 1);
    try std.testing.expect(!q.push(.magnet, &too_long));
    try std.testing.expectEqual(@as(usize, 0), q.count);
}
