//! Small bounded reuse pool for software video frame buffers.
//!
//! A 1080p PMA buffer is about 8 MiB and every software-rendered player needs
//! a front/back pair. Keep one pair warm when a player closes so reopening or
//! replacing a player avoids two large allocator round trips. Extra buffers
//! are freed immediately, so closing a split view cannot retain its peak.

const std = @import("std");
const dvui = @import("dvui");
const Mutex = @import("../core/sync.zig").Mutex;

const capacity = 2;
var slots: [capacity]?Buffer = .{ null, null };
var mutex: Mutex = .{};

pub const Buffer = []dvui.Color.PMA;

pub fn acquire(allocator: std.mem.Allocator, len: usize) !Buffer {
    mutex.lock();
    for (&slots) |*slot| {
        if (slot.*) |buf| {
            if (buf.len == len) {
                slot.* = null;
                mutex.unlock();
                return buf;
            }
        }
    }
    mutex.unlock();
    return allocator.alloc(dvui.Color.PMA, len);
}

pub fn release(allocator: std.mem.Allocator, buf: Buffer) void {
    if (buf.len == 0) return;
    mutex.lock();
    for (&slots) |*slot| {
        if (slot.* == null) {
            slot.* = buf;
            mutex.unlock();
            return;
        }
    }
    mutex.unlock();
    allocator.free(buf);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    mutex.lock();
    const retained = slots;
    slots = .{ null, null };
    mutex.unlock();
    for (retained) |slot| if (slot) |buf| allocator.free(buf);
}

test "pool reuses a released buffer and stays bounded" {
    const allocator = std.testing.allocator;
    defer deinit(allocator);

    const first = try acquire(allocator, 4);
    const ptr = first.ptr;
    release(allocator, first);
    const reused = try acquire(allocator, 4);
    try std.testing.expectEqual(ptr, reused.ptr);
    release(allocator, reused);

    const extra1 = try allocator.alloc(dvui.Color.PMA, 4);
    const extra2 = try allocator.alloc(dvui.Color.PMA, 4);
    release(allocator, extra1);
    release(allocator, extra2); // pool is full, so this is freed immediately
}
