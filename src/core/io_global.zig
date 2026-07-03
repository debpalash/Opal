const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

// Minimal kernel32 bindings zig 0.16 std doesn't expose. MinGW/MSVC both
// export these from kernel32.dll; zig auto-generates the import lib.
const win = if (is_windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    extern "kernel32" fn TerminateProcess(hProcess: ?*anyopaque, uExitCode: c_uint) callconv(.winapi) c_int;
} else struct {};

/// Global io instance for zig 0.16 migration. Lazy-initialized on first call.
/// Pre-0.16, std.fs/std.time/std.process.Child were io-free. 0.16 routes all
/// of them through Io. We keep a process-wide Threaded Io to avoid threading
/// io through every function signature.
var threaded: std.Io.Threaded = undefined;
// `constructing` is claimed by the single thread that builds `threaded`.
// `ready` is published with .release ONLY after construction completes, so a
// concurrent first-caller can never observe ready=true and then use a
// half-constructed `threaded` (the old single-flag design had that race).
var constructing = std.atomic.Value(bool).init(false);
var ready = std.atomic.Value(bool).init(false);

pub fn io() std.Io {
    if (!ready.load(.acquire)) {
        if (constructing.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            // We won the race — construct, then publish readiness.
            const alloc = @import("alloc.zig").allocator;
            threaded = std.Io.Threaded.init(alloc, .{});
            ready.store(true, .release);
        } else {
            // Another thread is constructing — wait for it to publish.
            while (!ready.load(.acquire)) std.atomic.spinLoopHint();
        }
    }
    return threaded.io();
}

/// Replacement for removed std.posix.getenv.
pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

/// Replacement for removed std.time.timestamp (seconds since epoch).
pub fn timestamp() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @intCast(tv.sec);
}

/// Replacement for removed std.time.milliTimestamp (ms since epoch).
pub fn milliTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, @intCast(tv.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tv.usec)), 1000);
}

/// Replacement for removed std.Thread.sleep (ns to nanosleep; kernel32
/// Sleep on Windows, where neither std.c.timespec nor nanosleep exist).
pub fn sleep(ns: u64) void {
    if (is_windows) {
        const ms = @divTrunc(ns + 999_999, 1_000_000); // round up: never busy-spin a 1ms poll loop
        win.Sleep(@intCast(@min(ms, std.math.maxInt(u32))));
        return;
    }
    const ts: std.c.timespec = .{
        .sec = @intCast(@divTrunc(ns, 1_000_000_000)),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    _ = std.c.nanosleep(&ts, null);
}

// ────────── File system wrappers ──────────
// Use global io to preserve zero-arg call sites from pre-0.16 code.

pub fn cwdMakePath(path: []const u8) !void {
    return std.Io.Dir.cwd().createDirPath(io(), path);
}

pub fn cwdOpenFile(path: []const u8, opts: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io(), path, opts);
}

pub fn cwdOpenDir(path: []const u8, opts: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.cwd().openDir(io(), path, opts);
}

pub fn cwdCreateFile(path: []const u8, opts: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return std.Io.Dir.cwd().createFile(io(), path, opts);
}

pub fn cwdAccess(path: []const u8, opts: std.Io.Dir.AccessOptions) !void {
    return std.Io.Dir.cwd().access(io(), path, opts);
}

pub fn cwdWriteFile(options: std.Io.Dir.WriteFileOptions) !void {
    return std.Io.Dir.cwd().writeFile(io(), options);
}

pub fn cwdReadFileAlloc(
    sub_path: []const u8,
    gpa: std.mem.Allocator,
    max_bytes: usize,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), sub_path, gpa, .limited(max_bytes));
}

pub fn openFileAbsolute(path: []const u8, opts: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(io(), path, opts);
}

pub fn openDirAbsolute(path: []const u8, opts: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io(), path, opts);
}

pub fn makeDirAbsolute(path: []const u8) !void {
    return std.Io.Dir.createDirAbsolute(io(), path, .default_dir);
}

pub fn deleteFileAbsolute(path: []const u8) !void {
    return std.Io.Dir.deleteFileAbsolute(io(), path);
}

pub fn renameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    return std.Io.Dir.renameAbsolute(old_path, new_path, io());
}

pub fn selfExeDirPath(buf: []u8) ![]const u8 {
    const n = try std.process.executableDirPath(io(), buf);
    return buf[0..n];
}

pub fn cwdDeleteFile(path: []const u8) !void {
    return std.Io.Dir.cwd().deleteFile(io(), path);
}

pub fn cwdDeleteTree(path: []const u8) !void {
    return std.Io.Dir.cwd().deleteTree(io(), path);
}

pub fn cwdStatFile(path: []const u8) !std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io(), path, .{});
}

pub fn createFileAbsolute(path: []const u8, opts: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return std.Io.Dir.createFileAbsolute(io(), path, opts);
}

pub fn selfExePath(buf: []u8) ![]const u8 {
    const n = try std.process.executablePath(io(), buf);
    return buf[0..n];
}

// ────────── Net shims ──────────
// 0.16 replaced std.net.Address with std.Io.net.IpAddress/UnixAddress.
// Stream lost direct writeAll/readAll — must go through .writer/.reader.

pub fn streamWriteAll(stream: anytype, data: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = stream.writer(io(), &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

pub fn streamReadAll(stream: anytype, buf: []u8) !usize {
    var tmp: [1024]u8 = undefined;
    var r = stream.reader(io(), &tmp);
    var vec: [1][]u8 = .{buf};
    return r.interface.readVec(&vec) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => err,
    };
}

/// Partial read from a network stream (returns available bytes, does not
/// fill the entire buffer). Use this instead of streamReadAll for
/// line-based protocols where blocking until the buffer is full would
/// stall the reader loop.
pub fn streamRead(stream: anytype, buf: []u8) !usize {
    var tmp: [1]u8 = undefined;
    var r = stream.reader(io(), &tmp);
    var vec: [1][]u8 = .{buf};
    return r.interface.readVec(&vec) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => err,
    };
}

/// Parse IPv4/IPv6 address with port.
pub fn parseIp(text: []const u8, port: u16) !std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parseIp4(text, port) catch
        std.Io.net.IpAddress.parseIp6(text, port);
}

// File method shims. Call-sites pattern: `file.readAll(buf)` can be
// rewritten to `readAll(file, buf)` since 0.16 File methods take io.
// anytype accepts both File and *File.

/// Drain `file` into `buf` until EOF or `buf` is full.
///
/// Streams via `read()` rather than `readPositionalAll` — pipes (a child's
/// stdout) are NOT seekable, so the positional read returned 0 bytes for every
/// subprocess reader (anime/youtube/comics/voice/plugins all silently loaded
/// nothing). Streaming works for both regular files and pipes.
pub fn readAll(file: anytype, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = read(file, buf[total..]) catch |e| {
            if (total > 0) break; // return what we already have
            return e; // nothing read yet — surface the error
        };
        if (n == 0) break; // EOF (or no data within read()'s retry window)
        total += n;
    }
    return total;
}

/// Partial read (up to buf.len bytes). Returns 0 on EOF.
/// Uses readStreaming directly — no Reader buffering, so byte-at-a-time
/// callers don't lose data (each call was creating a new Reader with a
/// fresh tmp buf, so bytes read ahead into tmp on one call were lost
/// on the next).
pub fn read(file: anytype, buf: []u8) !usize {
    var vec: [1][]u8 = .{buf};
    // WouldBlock: pipe has no data YET but not EOF. Retry with 1ms
    // nanosleep so caller's byte-loop doesn't exit prematurely.
    var retries: u32 = 0;
    while (retries < 10_000) : (retries += 1) {
        const n = file.readStreaming(io(), &vec) catch |err| switch (err) {
            error.EndOfStream => return 0,
            error.WouldBlock => {
                sleep(1_000_000); // 1ms
                continue;
            },
            else => return err,
        };
        return n;
    }
    return 0;
}

pub fn writeAll(file: anytype, bytes: []const u8) !void {
    return file.writeStreamingAll(io(), bytes);
}

pub fn closeFile(file: anytype) void {
    file.close(io());
}

pub fn closeDir(dir: anytype) void {
    dir.close(io());
}

// Read up to max_bytes from file into a freshly-allocated buffer.
pub fn readToEndAlloc(file: anytype, gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
    const size = file.length(io()) catch max_bytes;
    const len = @min(size, max_bytes);
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);
    const n = try file.readPositionalAll(io(), buf, 0);
    return buf[0..n];
}

/// Drop-in shim for removed std.process.Child.init API. Mirrors the
/// pre-0.16 Child struct fields/methods the codebase uses so call sites
/// keep working. Lazy-spawns via std.process.spawn(io, ...).
pub const Child = struct {
    argv: []const []const u8,
    allocator: std.mem.Allocator,
    stdin_behavior: StdIo = .Inherit,
    stdout_behavior: StdIo = .Inherit,
    stderr_behavior: StdIo = .Inherit,
    cwd: ?[]const u8 = null,
    env_map: ?*std.process.Environ.Map = null,

    // Post-spawn fields:
    real: ?std.process.Child = null,
    stdin: ?std.Io.File = null,
    stdout: ?std.Io.File = null,
    stderr: ?std.Io.File = null,
    /// POSIX: pid. Windows: process HANDLE. null until spawned.
    id: ?Id = null,

    pub const Id = std.process.Child.Id;
    pub const StdIo = enum { Inherit, Ignore, Pipe, Close };
    pub const Term = std.process.Child.Term;

    pub fn init(argv: []const []const u8, allocator: std.mem.Allocator) Child {
        return .{ .argv = argv, .allocator = allocator };
    }

    fn mapBehavior(b: StdIo) std.process.SpawnOptions.StdIo {
        return switch (b) {
            .Inherit => .inherit,
            .Ignore => .ignore,
            .Pipe => .pipe,
            .Close => .close,
        };
    }

    pub fn spawn(self: *Child) !void {
        const i = io();
        const cwd_val: std.process.Child.Cwd = if (self.cwd) |c|
            .{ .path = c }
        else
            .inherit;
        const real = try std.process.spawn(i, .{
            .argv = self.argv,
            .stdin = mapBehavior(self.stdin_behavior),
            .stdout = mapBehavior(self.stdout_behavior),
            .stderr = mapBehavior(self.stderr_behavior),
            .cwd = cwd_val,
        });
        self.stdin = real.stdin;
        self.stdout = real.stdout;
        self.stderr = real.stderr;
        self.id = real.id;
        self.real = real;
    }

    pub fn wait(self: *Child) !Term {
        if (self.real) |*r| {
            // std's wait()/kill() assert(child.id != null) and panic otherwise
            // (spawn that never set a pid, or an already-reaped child). Guard so
            // callers get a catchable error instead of an ABRT.
            if (r.id == null) return error.NotSpawned;
            return r.wait(io());
        }
        return error.NotSpawned;
    }

    pub fn kill(self: *Child) !Term {
        if (self.real) |*r| {
            if (r.id == null) return error.NotSpawned;
            // std's kill() sends the signal AND reaps (it nulls child.id and
            // asserts so). Calling wait() afterwards would assert id != null
            // and panic — so we must NOT wait here. Return a synthetic term
            // (the real exit status is unavailable after a kill-reap); all
            // callers discard it anyway.
            r.kill(io());
            return Term{ .unknown = 0 };
        }
        return error.NotSpawned;
    }

    pub fn spawnAndWait(self: *Child) !Term {
        try self.spawn();
        return self.wait();
    }
};

/// Ask a running child (identified by its snapshotted `Child.Id`) to stop,
/// WITHOUT reaping it — the owning worker's wait() still observes the exit.
/// POSIX: SIGTERM (graceful). Windows: TerminateProcess (forceful; PE has no
/// cross-process console signal for a detached child).
pub fn terminateProcess(id: Child.Id) void {
    if (is_windows) {
        _ = win.TerminateProcess(id, 1);
    } else {
        std.posix.kill(id, std.posix.SIG.TERM) catch {};
    }
}

