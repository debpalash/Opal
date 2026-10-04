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
const O_NONBLOCK: c_int = switch (builtin.os.tag) {
    .linux => 0o4000,
    else => 0x0004,
};

pub const Pty = if (is_windows) win.Pty else PosixPty;

const PosixPty = struct {
    master: c_int = -1,
    pid: c_int = 0,

    pub const ReadResult = union(enum) { data: usize, idle, closed };

    /// Wait up to `timeout_ms` for output. `closed` means the child side hung up.
    pub fn readTimeout(self: *const Pty, buf: []u8, timeout_ms: c_int) ReadResult {
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
    pub fn writeAll(self: *const Pty, data: []const u8) bool {
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

    pub fn resize(self: *const Pty, cols: u16, rows: u16, cell_w: u16, cell_h: u16) void {
        const ws = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = cols *| cell_w, .ws_ypixel = rows *| cell_h };
        _ = c.ioctl(self.master, TIOCSWINSZ, &ws);
    }

    /// True while the child has not exited. Collects its exit status once it has.
    pub fn alive(self: *Pty) bool {
        if (self.pid <= 0) return false;
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, WNOHANG);
        if (r == 0) return true;
        self.pid = 0;
        return false;
    }

    /// Hang up, then force-kill if the child ignores it, and release the master.
    pub fn close(self: *Pty) void {
        if (self.pid > 0) {
            _ = c.kill(self.pid, SIGHUP);
            var waited: u32 = 0;
            var status: c_int = 0;
            while (waited < 40) : (waited += 1) {
                if (c.waitpid(self.pid, &status, WNOHANG) != 0) {
                    self.pid = 0;
                    break;
                }
                io_g.sleep(25 * std.time.ns_per_ms);
            }
            if (self.pid > 0) {
                _ = c.kill(self.pid, SIGKILL);
                _ = c.waitpid(self.pid, &status, 0);
                self.pid = 0;
            }
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
    const pid = c.forkpty(&master, null, null, &ws);
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.execve(exe, @ptrCast(c_argv.ptr), c_env);
        c._exit(127);
    }

    // The reader polls, so a non-blocking master never stalls the thread; writes
    // handle EAGAIN themselves.
    const flags = c.fcntl(master, F_GETFL);
    if (flags >= 0) _ = c.fcntl(master, F_SETFL, flags | O_NONBLOCK);
    return .{ .master = master, .pid = pid };
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
