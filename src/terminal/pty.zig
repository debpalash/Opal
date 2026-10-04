//! A child process on a pseudo-terminal. POSIX uses `forkpty` (below); Windows
//! uses ConPTY (pty_windows.zig). `Pty` and `spawn` are the same to callers on
//! both; the one difference is `argv` on Windows, documented at `spawn`.
//!
//! `forkpty` does the openpty/fork/setsid/controlling-terminal dance. The child
//! only calls `execve` (arguments and environment are built before the fork,
//! because a multithreaded process must not allocate between fork and exec).

const std = @import("std");
const builtin = @import("builtin");
const io_g = @import("../core/io_global.zig");
const win = @import("pty_windows.zig");
const sync = @import("../core/sync.zig");

const is_windows = builtin.os.tag == .windows;

pub const supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .windows => true,
    else => false,
};

const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };

const c = struct {
    extern "c" fn forkpty(amaster: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
    extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern "c" fn kill(pid: c_int, sig: c_int) c_int;
    extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
    extern "c" fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    extern "c" fn signal(sig: c_int, handler: ?*const anyopaque) ?*const anyopaque;
    extern "c" fn getdtablesize() c_int;
};

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 };
const POLLIN: i16 = 0x001;
const POLLOUT: i16 = 0x004;
const POLLERR: i16 = 0x008;
const POLLHUP: i16 = 0x010;
const POLLNVAL: i16 = 0x020;

const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5414,
    else => 0x80087467, // BSD and macOS
};
const WNOHANG: c_int = 1;
const SIGHUP: c_int = 1;
const SIGKILL: c_int = 9;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const F_SETFD: c_int = 2;
const FD_CLOEXEC: c_int = 1;
const SIGPIPE: c_int = 13;
const O_NONBLOCK: c_int = switch (builtin.os.tag) {
    .linux => 0o4000,
    else => 0x0004,
};

pub const Pty = if (is_windows) win.Pty else PosixPty;

const PosixPty = struct {
    master: c_int = -1,
    pid: c_int = 0,
    /// Guards `pid` between the reader thread (`alive`) and the UI thread.
    pid_lock: sync.Mutex = .{},

    pub const ReadResult = union(enum) { data: usize, idle, closed };

    /// Wait up to `timeout_ms` for output. `closed` means the child side hung up.
    pub fn readTimeout(self: *const PosixPty, buf: []u8, timeout_ms: c_int) ReadResult {
        var fds = [_]PollFd{.{ .fd = self.master, .events = POLLIN, .revents = 0 }};
        const ready = c.poll(&fds, 1, timeout_ms);
        if (ready < 0) return .closed;
        if (ready == 0) return .idle;
        // Drain what is buffered before reporting a hangup.
        if (fds[0].revents & POLLIN != 0) {
            const n = c.read(self.master, buf.ptr, buf.len);
            if (n > 0) return .{ .data = @intCast(n) };
            if (n < 0) {
                const err = std.c._errno().*;
                if (err == @intFromEnum(std.c.E.AGAIN) or err == @intFromEnum(std.c.E.INTR)) return .idle;
            }
            return .closed;
        }
        if (fds[0].revents & (POLLHUP | POLLERR | POLLNVAL) != 0) return .closed;
        return .idle;
    }

    /// Write all of `data`, waiting briefly when the child is not reading. Gives
    /// up after about 250 ms of no progress so a stuck child cannot freeze the UI.
    pub fn writeAll(self: *const PosixPty, data: []const u8) bool {
        var off: usize = 0;
        var stalled: u8 = 0;
        while (off < data.len) {
            const n = c.write(self.master, data[off..].ptr, data.len - off);
            if (n > 0) {
                off += @intCast(n);
                stalled = 0;
                continue;
            }
            if (n < 0 and std.c._errno().* != @intFromEnum(std.c.E.AGAIN) and std.c._errno().* != @intFromEnum(std.c.E.INTR)) return false;
            var fds = [_]PollFd{.{ .fd = self.master, .events = POLLOUT, .revents = 0 }};
            if (c.poll(&fds, 1, 50) <= 0) {
                stalled += 1;
                if (stalled >= 5) return false;
            }
        }
        return true;
    }

    pub fn resize(self: *const PosixPty, cols: u16, rows: u16, cell_w: u16, cell_h: u16) void {
        const ws = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = cols *| cell_w, .ws_ypixel = rows *| cell_h };
        _ = c.ioctl(self.master, TIOCSWINSZ, &ws);
    }

    /// True while the child has not exited. Collects its exit status once it has.
    pub fn alive(self: *PosixPty) bool {
        return !self.reap(false);
    }

    /// Ask the child to hang up without waiting for it. `deinit` calls this before
    /// joining the reader, so the child is usually gone by the time `close` runs.
    pub fn hangup(self: *PosixPty) void {
        self.pid_lock.lock();
        defer self.pid_lock.unlock();
        if (self.pid > 0) _ = c.kill(self.pid, SIGHUP);
    }

    /// Reap the child if it has exited (or, with `block`, wait for it). True when
    /// there is no child left. Reaping and signalling share `pid_lock`, so a pid is
    /// never signalled after it has been reaped and could have been recycled.
    fn reap(self: *PosixPty, block: bool) bool {
        self.pid_lock.lock();
        defer self.pid_lock.unlock();
        if (self.pid <= 0) return true;
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, if (block) 0 else WNOHANG);
        if (r == 0) return false;
        self.pid = 0;
        return true;
    }

    /// Hang up, then force-kill if the child ignores it, and release the master.
    /// Call after the reader thread has stopped.
    pub fn close(self: *PosixPty) void {
        self.hangup();
        var waited: u32 = 0;
        var gone = self.reap(false);
        while (!gone and waited < 40) : (waited += 1) {
            io_g.sleep(25 * std.time.ns_per_ms);
            gone = self.reap(false);
        }
        if (!gone) {
            self.pid_lock.lock();
            if (self.pid > 0) _ = c.kill(self.pid, SIGKILL);
            self.pid_lock.unlock();
            _ = self.reap(true);
        }
        if (self.master >= 0) _ = c.close(self.master);
        self.master = -1;
    }
};

pub const SpawnError = error{ Unsupported, ForkFailed, OutOfMemory, BadArgument };

/// POSIX: `argv[0]` must be an absolute path (no PATH search happens in the
/// child). Windows: a single element is the complete command line, already
/// quoted for the shell it starts (see `agent_launch_pure.windowsAgentCommand`);
/// several are quoted and joined, and the program is searched for as
/// CreateProcess does. `extra_env` entries are `NAME=value` on both; they replace
/// same-named inherited ones.
pub fn spawn(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    extra_env: []const []const u8,
    cols: u16,
    rows: u16,
) SpawnError!Pty {
    if (comptime is_windows) {
        return win.spawn(allocator, argv, extra_env, cols, rows);
    } else {
        return spawnPosix(allocator, argv, extra_env, cols, rows);
    }
}

fn spawnPosix(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    extra_env: []const []const u8,
    cols: u16,
    rows: u16,
) SpawnError!Pty {
    if (!supported) return error.Unsupported;
    if (argv.len == 0) return error.BadArgument;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c_argv = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.BadArgument;
        c_argv[i] = (try arena.dupeZ(u8, arg)).ptr;
    }

    var env: std.ArrayList(?[*:0]const u8) = .empty;
    var inherited = std.c.environ;
    while (inherited[0]) |entry| : (inherited += 1) {
        const text = std.mem.span(entry);
        var replaced = false;
        for (extra_env) |extra| {
            const eq = std.mem.indexOfScalar(u8, extra, '=') orelse continue;
            if (std.mem.startsWith(u8, text, extra[0 .. eq + 1])) replaced = true;
        }
        if (!replaced) try env.append(arena, entry);
    }
    for (extra_env) |extra| try env.append(arena, (try arena.dupeZ(u8, extra)).ptr);
    try env.append(arena, null);
    const c_env: [*:null]const ?[*:0]const u8 = @ptrCast(env.items.ptr);

    const exe = c_argv[0].?;
    const ws = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    var master: c_int = -1;
    // Looked up before the fork: only async-signal-safe calls may run in the child.
    const fd_limit: c_int = @min(c.getdtablesize(), 4096);
    const pid = c.forkpty(&master, null, null, &ws);
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        childPrepare(fd_limit);
        _ = c.execve(exe, @ptrCast(c_argv.ptr), c_env);
        c._exit(127);
    }

    // The reader polls, so a non-blocking master never stalls the thread; writes
    // handle EAGAIN themselves.
    const flags = c.fcntl(master, F_GETFL);
    if (flags >= 0) _ = c.fcntl(master, F_SETFL, flags | O_NONBLOCK);
    // Opal's other children (scheduled agent runs, mpv, ...) must not inherit the
    // master: they could read the terminal or type into it.
    _ = c.fcntl(master, F_SETFD, FD_CLOEXEC);
    return .{ .master = master, .pid = pid };
}

/// Runs in the forked child just before `execve`; async-signal-safe calls only.
/// Closes every inherited descriptor (libtorrent, libmpv, sockets...) and puts
/// SIGPIPE back to its default: Zig's I/O layer ignores it, and an ignored
/// disposition survives `execve`, which would make shell pipelines fail with EPIPE.
fn childPrepare(fd_limit: c_int) void {
    _ = c.signal(SIGPIPE, null);
    if (builtin.os.tag == .linux) {
        // close_range(3, ~0, 0); kernels before 5.9 answer ENOSYS, so loop then.
        const rc = std.os.linux.syscall3(.close_range, 3, std.math.maxInt(u32), 0);
        if (std.os.linux.errno(rc) == .SUCCESS) return;
    }
    var fd: c_int = 3;
    while (fd < fd_limit) : (fd += 1) _ = c.close(fd);
}

test {
    _ = win;
}

test "a child on a pty produces output and exits" {
    if (!supported or is_windows) return error.SkipZigTest;
    var pty = try spawn(std.testing.allocator, &.{ "/bin/sh", "-c", "printf 'hello from pty'" }, &.{"TERM=xterm-256color"}, 80, 24);
    defer pty.close();
    var out: [256]u8 = undefined;
    var len: usize = 0;
    var spins: u32 = 0;
    while (spins < 50) : (spins += 1) {
        switch (pty.readTimeout(out[len..], 100)) {
            .data => |n| len += n,
            .idle => {},
            .closed => break,
        }
        if (std.mem.indexOf(u8, out[0..len], "hello from pty") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, out[0..len], "hello from pty") != null);
}

fn collect(pty: *Pty, out: []u8, needle: []const u8) []const u8 {
    var len: usize = 0;
    var spins: u32 = 0;
    while (spins < 50) : (spins += 1) {
        switch (pty.readTimeout(out[len..], 100)) {
            .data => |n| len += n,
            .idle => {},
            .closed => break,
        }
        if (std.mem.indexOf(u8, out[0..len], needle) != null) break;
    }
    return out[0..len];
}

test "the child inherits no stray descriptors and a default SIGPIPE" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // A descriptor without CLOEXEC, standing in for libtorrent's or mpv's.
    const leak = c.fcntl(2, 0, @as(c_int, 50)); // F_DUPFD at 50 or above, clear of the shell's own
    try std.testing.expect(leak >= 50);
    defer _ = c.close(leak);
    // The Zig runtime ignores SIGPIPE; the child must not inherit that.
    const old = c.signal(SIGPIPE, @ptrFromInt(1));
    defer _ = c.signal(SIGPIPE, old);

    var pty = try spawn(std.testing.allocator, &.{ "/bin/sh", "-c", "for f in /proc/self/fd/*; do echo fd:${f##*/}; done; grep SigIgn /proc/self/status; echo end" }, &.{}, 80, 24);
    defer pty.close();
    var out: [1024]u8 = undefined;
    const text = collect(&pty, &out, "end");
    var needle: [32]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&needle, "fd:{d}\r", .{leak})) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fd:0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "SigIgn:\t0000000000000000") != null);
}

test "the master is not inherited by other children" {
    if (!supported or is_windows) return error.SkipZigTest;
    var pty = try spawn(std.testing.allocator, &.{ "/bin/sh", "-c", "sleep 1" }, &.{}, 80, 24);
    defer pty.close();
    const flags = c.fcntl(pty.master, 1); // F_GETFD
    try std.testing.expect(flags >= 0 and flags & FD_CLOEXEC != 0);
}

test "input written to the pty reaches the child" {
    if (!supported or is_windows) return error.SkipZigTest;
    var pty = try spawn(std.testing.allocator, &.{ "/bin/sh", "-c", "read line; printf 'got:%s' \"$line\"" }, &.{}, 80, 24);
    defer pty.close();
    try std.testing.expect(pty.writeAll("ping\n"));
    var out: [256]u8 = undefined;
    var len: usize = 0;
    var spins: u32 = 0;
    while (spins < 50) : (spins += 1) {
        switch (pty.readTimeout(out[len..], 100)) {
            .data => |n| len += n,
            .idle => {},
            .closed => break,
        }
        if (std.mem.indexOf(u8, out[0..len], "got:ping") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, out[0..len], "got:ping") != null);
}
