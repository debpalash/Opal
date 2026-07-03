const std = @import("std");
const builtin = @import("builtin");

/// Drop-in replacement for std.Thread.Mutex removed in zig 0.16.
/// Backed by pthread_mutex_t on POSIX and an SRWLOCK on Windows (zig's
/// std.c defines pthread_mutex_t as `void` for windows targets, and MinGW
/// winpthreads would add a needless DLL dependency). API matches old
/// std.Thread.Mutex: default-init, .lock(), .tryLock(), .unlock().
pub const Mutex = if (builtin.os.tag == .windows) struct {
    // SRWLOCK is a single pointer-sized word; SRWLOCK_INIT is all-zero.
    // Exclusive acquire/release only — same non-recursive semantics as the
    // default POSIX mutex below.
    inner: ?*anyopaque = null,

    extern "kernel32" fn AcquireSRWLockExclusive(srw: *?*anyopaque) callconv(.winapi) void;
    extern "kernel32" fn ReleaseSRWLockExclusive(srw: *?*anyopaque) callconv(.winapi) void;
    extern "kernel32" fn TryAcquireSRWLockExclusive(srw: *?*anyopaque) callconv(.winapi) u8;

    pub fn lock(m: *Mutex) void {
        AcquireSRWLockExclusive(&m.inner);
    }

    pub fn tryLock(m: *Mutex) bool {
        return TryAcquireSRWLockExclusive(&m.inner) != 0;
    }

    pub fn unlock(m: *Mutex) void {
        ReleaseSRWLockExclusive(&m.inner);
    }
} else struct {
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
