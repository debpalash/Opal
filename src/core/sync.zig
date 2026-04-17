const std = @import("std");

/// Drop-in replacement for std.Thread.Mutex removed in zig 0.16.
/// Backed by pthread_mutex_t on POSIX. API matches old std.Thread.Mutex:
/// default-init, .lock(), .tryLock(), .unlock().
pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    pub fn lock(m: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }

    pub fn tryLock(m: *Mutex) bool {
        return std.c.pthread_mutex_trylock(&m.inner) == .SUCCESS;
    }

    pub fn unlock(m: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
};
