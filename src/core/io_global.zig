const std = @import("std");
const builtin = @import("builtin");
// Safe: alloc.zig imports only std, so there is no import cycle back to here.
const alloc_mod = @import("alloc.zig");

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
            // `Threaded.environ` is what processSpawn hands each child. On Windows
            // it defaulted to an empty block, so spawned curl had no SystemRoot,
            // WinSock's resolver never initialized, and every fetch died with
            // "curl: (6) Could not resolve host" — silently emptying every
            // network-backed feature (browse tabs, search, posters, plugins).
            // Hand children the real process environment. The `.global` block
            // only exists on Windows's GlobalBlock (POSIX's PosixBlock has no
            // such member), and POSIX already inherits a working env under the
            // default, so this override is Windows-only and comptime-pruned
            // elsewhere. `.async_limit = .unlimited` applies everywhere: blocking
            // child-stdout reads hold an async slot for as long as curl runs, and
            // startup fires several fetches at once (tmdb + anime + calendar +
            // yt-dlp + posters); the default (cpu_count - 1) limit could be
            // exhausted so later reads never dispatched and readAll() hung.
            threaded = if (builtin.os.tag == .windows)
                std.Io.Threaded.init(alloc, .{ .environ = .{ .block = .global }, .async_limit = .unlimited })
            else
                std.Io.Threaded.init(alloc, .{ .async_limit = .unlimited });
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

/// Fill `buf` with cryptographically secure random bytes. Returns false if the
/// platform has no entropy source (callers MUST treat that as fatal for secrets
/// — never fall back to a timestamp seed).
///
/// Use this instead of reading "/dev/urandom" directly: that path does not exist
/// on Windows, so every hand-rolled reader silently failed there and disabled
/// whatever it guarded (the remote API token, the content-cache key, the auth
/// store salt). std.Io routes to \Device\CNG on Windows, arc4random_buf on
/// macOS/BSD and getrandom(2) on Linux.
pub fn randomSecure(buf: []u8) bool {
    io().randomSecure(buf) catch return false;
    return true;
}

/// Platform temp directory, no trailing slash. `%TEMP%` on Windows (falling
/// back to the documented `C:\Windows\Temp`), `$TMPDIR` then `/tmp` elsewhere.
///
/// **Never hardcode "/tmp/…" for a file the app writes.** Windows has no /tmp,
/// so the create fails and whatever feature depended on it dies silently — this
/// is what killed scrub thumbnails and subtitle downloads there. For anything
/// that should SURVIVE a reboot use paths.cacheFile() instead; this is only for
/// genuinely transient scratch files.
pub fn tmpDir(buf: []u8) []const u8 {
    if (is_windows) {
        const t = getenv("TEMP") orelse getenv("TMP") orelse return "C:/Windows/Temp";
        const n = @min(t.len, buf.len);
        @memcpy(buf[0..n], t[0..n]);
        return buf[0..n];
    }
    const t = getenv("TMPDIR") orelse return "/tmp";
    // $TMPDIR conventionally carries a trailing slash on macOS; strip it so
    // callers can always join with "/".
    const trimmed = std.mem.trimEnd(u8, t, "/");
    if (trimmed.len == 0) return "/tmp";
    const n = @min(trimmed.len, buf.len);
    @memcpy(buf[0..n], trimmed[0..n]);
    return buf[0..n];
}

/// The platform's bit-bucket path, for passing to a spawned tool.
///
/// **Never hardcode "/dev/null" in an argv.** Windows has no such path: curl
/// resolves it relative to the CWD, fails to create `dev\null`, and exits
/// non-zero — so `curl -o /dev/null -w %{http_code}` (the health-probe idiom
/// used all over this codebase) reports failure for a server that is perfectly
/// healthy.
pub fn devNull() []const u8 {
    return if (is_windows) "NUL" else "/dev/null";
}

/// Kill every process whose FULL COMMAND LINE contains `pattern`.
///
/// `pkill -f` does not exist on Windows, and `taskkill` cannot filter on a
/// command line (its COMMANDLINE filter is not supported), so matching a JVM by
/// the jar it is running needs CIM. Without this, every `pkill` cleanup path in
/// the app is a silent no-op on Windows and the child — a Suwayomi JVM, a voice
/// sidecar, a llama-server — is orphaned when Opal exits.
///
/// `force` maps to `pkill -9` on POSIX. Windows Stop-Process is always forceful,
/// so it only affects the POSIX side — pass it where the caller previously used
/// -9, so a stubborn child (llama-server) still dies.
///
/// Best-effort by design: callers use this for cleanup and must not depend on
/// the process actually being gone.
/// Same contract as `killByCommandLine`, for a whole set of patterns at once.
///
/// Exists purely for shutdown latency on Windows. Each `killByCommandLine`
/// there pays for a PowerShell startup plus a `Get-CimInstance Win32_Process`
/// enumeration of every process on the machine — measured at ~420ms. appDeinit
/// sweeps seven patterns, so the obvious loop cost ~3s, and Opal's window sat
/// on screen for that whole time after the user clicked close. One spawn, one
/// WMI enumeration, seven `-like` tests against the rows it already has.
///
/// The match is character-for-character what the per-pattern version does
/// (`-like '*pattern*'`, OR'd) — this is a spawn-count fix, not a semantic one.
/// POSIX keeps the plain loop: `pkill` costs a few milliseconds.
pub fn killByCommandLineAny(patterns: []const []const u8, force: bool) void {
    if (patterns.len == 0) return;
    if (!is_windows) {
        for (patterns) |p| killByCommandLine(p, force);
        return;
    }

    // ($c -like '*a*') -or ($c -like '*b*') -or …
    var clause: [1536]u8 = undefined;
    var n: usize = 0;
    for (patterns) |pattern| {
        const prefix = if (n == 0) "($c -like '*" else " -or ($c -like '*";
        if (n + prefix.len > clause.len) break;
        @memcpy(clause[n..][0..prefix.len], prefix);
        n += prefix.len;
        // Single-quoted in PowerShell: escape an embedded quote by doubling.
        for (pattern) |ch| {
            if (n + 2 > clause.len) break;
            if (ch == '\'') {
                clause[n] = '\'';
                n += 1;
            }
            clause[n] = ch;
            n += 1;
        }
        const suffix = "*')";
        if (n + suffix.len > clause.len) break;
        @memcpy(clause[n..][0..suffix.len], suffix);
        n += suffix.len;
    }
    if (n == 0) return;

    var script_buf: [2048]u8 = undefined;
    const script = std.fmt.bufPrint(
        &script_buf,
        "Get-CimInstance Win32_Process | Where-Object {{ $c = $_.CommandLine; {s} }} | " ++
            "ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }}",
        .{clause[0..n]},
    ) catch return;

    var c = Child.init(&.{ "powershell", "-NoProfile", "-NonInteractive", "-Command", script }, alloc_mod.allocator);
    c.stdin_behavior = .Ignore;
    c.stdout_behavior = .Ignore;
    c.stderr_behavior = .Ignore;
    c.spawn() catch return;
    _ = c.wait() catch {};
}

pub fn killByCommandLine(pattern: []const u8, force: bool) void {
    if (is_windows) {
        var script_buf: [512]u8 = undefined;
        // Single-quoted in PowerShell, so escape any embedded quote by doubling.
        var pat_buf: [256]u8 = undefined;
        var n: usize = 0;
        for (pattern) |ch| {
            if (n + 2 > pat_buf.len) break;
            if (ch == '\'') {
                pat_buf[n] = '\'';
                n += 1;
            }
            pat_buf[n] = ch;
            n += 1;
        }
        const script = std.fmt.bufPrint(
            &script_buf,
            "Get-CimInstance Win32_Process | Where-Object {{ $_.CommandLine -like '*{s}*' }} | " ++
                "ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }}",
            .{pat_buf[0..n]},
        ) catch return;
        var c = Child.init(&.{ "powershell", "-NoProfile", "-NonInteractive", "-Command", script }, alloc_mod.allocator);
        c.stdin_behavior = .Ignore;
        c.stdout_behavior = .Ignore;
        c.stderr_behavior = .Ignore;
        c.spawn() catch return;
        _ = c.wait() catch {};
    } else {
        var c = if (force)
            Child.init(&.{ "pkill", "-9", "-f", pattern }, alloc_mod.allocator)
        else
            Child.init(&.{ "pkill", "-f", pattern }, alloc_mod.allocator);
        c.stdin_behavior = .Ignore;
        c.stdout_behavior = .Ignore;
        c.stderr_behavior = .Ignore;
        c.spawn() catch return;
        _ = c.wait() catch {};
    }
}

/// Kill processes matching any of several command-line patterns with one
/// process-table scan. Used during shutdown to avoid launching a scanner for
/// every individual helper process.
pub fn killAnyByCommandLine(patterns: []const []const u8, force: bool) void {
    if (patterns.len == 0) return;
    if (is_windows) {
        var script_buf: [2048]u8 = undefined;
        var n: usize = 0;
        const prefix = "Get-CimInstance Win32_Process | Where-Object { ";
        @memcpy(script_buf[n .. n + prefix.len], prefix);
        n += prefix.len;
        for (patterns, 0..) |pattern, i| {
            const joiner: []const u8 = if (i == 0) "" else " -or ";
            const clause = "$_.CommandLine -like '*";
            if (n + joiner.len + clause.len >= script_buf.len) return;
            @memcpy(script_buf[n .. n + joiner.len], joiner);
            n += joiner.len;
            @memcpy(script_buf[n .. n + clause.len], clause);
            n += clause.len;
            for (pattern) |ch| {
                if (n + 2 >= script_buf.len) return;
                if (ch == '\'') {
                    script_buf[n] = '\'';
                    n += 1;
                }
                script_buf[n] = ch;
                n += 1;
            }
            script_buf[n] = '*';
            script_buf[n + 1] = '\'';
            n += 2;
        }
        const suffix = " } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }";
        if (n + suffix.len > script_buf.len) return;
        @memcpy(script_buf[n .. n + suffix.len], suffix);
        n += suffix.len;
        var child = Child.init(&.{ "powershell", "-NoProfile", "-NonInteractive", "-Command", script_buf[0..n] }, alloc_mod.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return;
        _ = child.wait() catch {};
    } else {
        var regex_buf: [1024]u8 = undefined;
        var n: usize = 0;
        for (patterns, 0..) |pattern, i| {
            const separator_len: usize = if (i == 0) 0 else 1;
            if (n + pattern.len + separator_len > regex_buf.len) return;
            if (i != 0) {
                regex_buf[n] = '|';
                n += 1;
            }
            @memcpy(regex_buf[n .. n + pattern.len], pattern);
            n += pattern.len;
        }
        var child = if (force)
            Child.init(&.{ "pkill", "-9", "-f", regex_buf[0..n] }, alloc_mod.allocator)
        else
            Child.init(&.{ "pkill", "-f", regex_buf[0..n] }, alloc_mod.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return;
        _ = child.wait() catch {};
    }
}

/// Kill processes by EXACT executable name (`pkill -x`) — not a command-line
/// substring. Use when the name is unambiguous and matching a substring could
/// hit unrelated processes. Windows matches the image name, where the `.exe`
/// suffix is optional in the filter.
pub fn killByName(name: []const u8) void {
    if (is_windows) {
        var img_buf: [128]u8 = undefined;
        const img = if (std.mem.endsWith(u8, name, ".exe"))
            name
        else
            std.fmt.bufPrint(&img_buf, "{s}.exe", .{name}) catch return;
        var c = Child.init(&.{ "taskkill", "/F", "/IM", img }, alloc_mod.allocator);
        c.stdin_behavior = .Ignore;
        c.stdout_behavior = .Ignore;
        c.stderr_behavior = .Ignore;
        c.spawn() catch return;
        _ = c.wait() catch {};
    } else {
        var c = Child.init(&.{ "pkill", "-x", name }, alloc_mod.allocator);
        c.stdin_behavior = .Ignore;
        c.stdout_behavior = .Ignore;
        c.stderr_behavior = .Ignore;
        c.spawn() catch return;
        _ = c.wait() catch {};
    }
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

/// Resolve `sub_path` (relative to cwd) to an absolute, symlink-free path.
/// Returns the slice of `buf` holding the result.
pub fn cwdRealPathFile(sub_path: []const u8, buf: []u8) ![]const u8 {
    const n = try std.Io.Dir.cwd().realPathFile(io(), sub_path, buf);
    return buf[0..n];
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
            // Windows GUI build has no console for a spawned console app (curl,
            // etc.) to inherit, so without this each spawn would flash its own
            // console window. CREATE_NO_WINDOW suppresses that. No-op elsewhere.
            .create_no_window = is_windows,
            // The process environment comes from `Threaded.environ` (set in
            // io()), which is what processSpawn actually uses; only override it
            // here when a caller supplied an explicit map.
            .environ_map = self.env_map,
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

    /// Close our read end of the child's stdout, exactly once.
    ///
    /// Streaming callers sometimes close the pipe as a way to STOP the child:
    /// an ffmpeg blocked writing to a full stdout pipe ignores SIGTERM (its
    /// handler sets a flag, then it retries the interrupted write and blocks
    /// again), and EPIPE is what actually ends it.
    ///
    /// Doing that through `self.stdout` alone is a trap. `spawn()` COPIES the
    /// File handles out of the real child, so nulling the wrapper's copy leaves
    /// `real.stdout` pointing at the same descriptor — and std's own cleanup,
    /// which runs inside both wait() and kill(), closes it a second time. That
    /// second close lands on a freed fd: EBADF, which the debug Io turns into
    /// `reached unreachable code` (it panicked Opal mid-stream on every web
    /// "Play here"), and which in a release build closes whatever unrelated
    /// descriptor — another client's socket — inherited the number.
    pub fn closeStdout(self: *Child) void {
        var closed = false;
        if (self.stdout) |*so| {
            so.close(io());
            self.stdout = null;
            closed = true;
        }
        // Take it away from std either way, so its cleanup cannot re-close.
        if (self.real) |*r| {
            if (r.stdout) |*ro| {
                if (!closed) ro.close(io());
                r.stdout = null;
            }
        }
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

/// The forceful sibling of terminateProcess, for a child that has already
/// ignored a polite stop. POSIX: SIGKILL. Windows: TerminateProcess, which is
/// forceful either way — `std.posix.SIG` has no KILL member there at all, so a
/// bare `std.posix.SIG.KILL` is not merely wrong on Windows, it fails to
/// COMPILE. That is what broke the headless Windows build in CI.
pub fn killProcess(id: Child.Id) void {
    if (is_windows) {
        _ = win.TerminateProcess(id, 1);
    } else {
        std.posix.kill(id, std.posix.SIG.KILL) catch {};
    }
}
