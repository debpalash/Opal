//! Lifecycle for asynchronous views where a newer request supersedes an older
//! one. The generation and the public loading flag change under one lock, so a
//! late worker cannot clear the busy state of the request that replaced it.

const std = @import("std");
const sync = @import("sync.zig");

pub const Gate = struct {
    transition: sync.Mutex = .{},
    generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Start a new request and return the generation owned by its worker.
    pub fn begin(self: *Gate, loading: *std.atomic.Value(bool)) u32 {
        self.transition.lock();
        defer self.transition.unlock();
        const token = self.generation.fetchAdd(1, .acq_rel) +% 1;
        loading.store(true, .release);
        return token;
    }

    /// Invalidate the current worker without starting another one yet.
    pub fn cancel(self: *Gate, loading: *std.atomic.Value(bool)) void {
        self.transition.lock();
        defer self.transition.unlock();
        _ = self.generation.fetchAdd(1, .acq_rel);
        loading.store(false, .release);
    }

    /// Clear loading only when `token` still owns the view.
    pub fn finish(self: *Gate, token: u32, loading: *std.atomic.Value(bool)) void {
        self.transition.lock();
        defer self.transition.unlock();
        if (self.generation.load(.acquire) == token) loading.store(false, .release);
    }

    pub fn current(self: *const Gate) u32 {
        return self.generation.load(.acquire);
    }

    pub fn isCurrent(self: *const Gate, token: u32) bool {
        return self.current() == token;
    }
};

test "latest request owns the loading state" {
    var gate: Gate = .{};
    var loading = std.atomic.Value(bool).init(false);

    const old = gate.begin(&loading);
    const newest = gate.begin(&loading);
    gate.finish(old, &loading);
    try std.testing.expect(loading.load(.acquire));

    gate.finish(newest, &loading);
    try std.testing.expect(!loading.load(.acquire));
}

test "cancel invalidates a late completion" {
    var gate: Gate = .{};
    var loading = std.atomic.Value(bool).init(false);

    const token = gate.begin(&loading);
    gate.cancel(&loading);
    gate.finish(token, &loading);

    try std.testing.expect(!loading.load(.acquire));
    try std.testing.expect(!gate.isCurrent(token));
}
