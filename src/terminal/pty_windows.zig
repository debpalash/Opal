//! A child process on a Windows pseudo console (ConPTY). Same interface as the
//! POSIX `Pty` in pty.zig, which selects between the two at comptime.
//!
//! How ConPTY fits together:
//!   - Two anonymous pipes carry bytes: we write `input_write`, conhost reads
//!     `in_read`; conhost writes `out_write`, we read `output_read`.
//!   - `CreatePseudoConsole(size, in_read, out_write)` makes conhost duplicate
//!     those two ends, so we close our copies of `in_read` and `out_write` right
//!     after (leaving them open would also keep the pipes alive after exit).
//!   - The child is created with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` pointing at
//!     the console. It sees a real console; we see a VT byte stream.
//!   - Unlike a POSIX pty, the output pipe does not break when the child exits
//!     (conhost keeps its end until `ClosePseudoConsole`), so exit is detected by
//!     waiting on the process handle.
//!
//! Handle ownership once `spawn` succeeds, all released by `close`:
//!   `process`  the child, `job` a kill-on-close job holding the whole process
//!   tree, `hpc` the pseudo console, `input` our write end, `output` our read end.
//!
//! Only the structs, pure helpers and the tests that do not spawn compile on
//! other hosts; the Win32 calls sit behind `is_windows`.

const std = @import("std");
const builtin = @import("builtin");
const cmdline = @import("../services/win_cmdline_pure.zig");

const is_windows = builtin.os.tag == .windows;

const Handle = *anyopaque;
const Coord = extern struct { x: i16, y: i16 };

const StartupInfoW = extern struct {
    cb: u32,
    reserved: ?[*:0]u16,
    desktop: ?[*:0]u16,
    title: ?[*:0]u16,
    x: u32,
    y: u32,
    x_size: u32,
    y_size: u32,
    x_count_chars: u32,
    y_count_chars: u32,
    fill_attribute: u32,
    flags: u32,
    show_window: u16,
    cb_reserved2: u16,
    reserved2: ?*u8,
    std_input: ?Handle,
    std_output: ?Handle,
    std_error: ?Handle,
};

const StartupInfoExW = extern struct {
    startup_info: StartupInfoW,
    attribute_list: ?*anyopaque,
};

const ProcessInformation = extern struct {
    process: ?Handle,
    thread: ?Handle,
    process_id: u32,
    thread_id: u32,
};

// Kill-on-close job, same layout as in core/io_global.zig.
const IoCounters = extern struct {
    read_operation_count: u64,
    write_operation_count: u64,
    other_operation_count: u64,
    read_transfer_count: u64,
    write_transfer_count: u64,
    other_transfer_count: u64,
};
const JobBasicLimit = extern struct {
    per_process_user_time_limit: i64,
    per_job_user_time_limit: i64,
    limit_flags: u32,
    minimum_working_set_size: usize,
    maximum_working_set_size: usize,
    active_process_limit: u32,
    affinity: usize,
    priority_class: u32,
    scheduling_class: u32,
};
const JobExtendedLimit = extern struct {
    basic: JobBasicLimit,
    io_info: IoCounters,
    process_memory_limit: usize,
    job_memory_limit: usize,
    peak_process_memory_used: usize,
    peak_job_memory_used: usize,
};

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const EXTENDED_STARTUPINFO_PRESENT: u32 = 0x00080000;
const CREATE_UNICODE_ENVIRONMENT: u32 = 0x00000400;
const CREATE_SUSPENDED: u32 = 0x00000004;
const WAIT_TIMEOUT: u32 = 0x102;
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: c_int = 9;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
const pipe_size: u32 = 64 * 1024;

const k32 = if (is_windows) struct {
    extern "kernel32" fn CreatePipe(read: *?Handle, write: *?Handle, attrs: ?*anyopaque, size: u32) callconv(.winapi) c_int;
    extern "kernel32" fn CreatePseudoConsole(size: Coord, input: Handle, output: Handle, flags: u32, out: *?Handle) callconv(.winapi) i32;
    extern "kernel32" fn ResizePseudoConsole(hpc: Handle, size: Coord) callconv(.winapi) i32;
    extern "kernel32" fn ClosePseudoConsole(hpc: Handle) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: u32, flags: u32, size: *usize) callconv(.winapi) c_int;
    extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: u32, attribute: usize, value: ?*anyopaque, size: usize, previous: ?*anyopaque, return_size: ?*usize) callconv(.winapi) c_int;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, command_line: ?[*:0]u16, process_attrs: ?*anyopaque, thread_attrs: ?*anyopaque, inherit: c_int, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, startup: *StartupInfoExW, info: *ProcessInformation) callconv(.winapi) c_int;
    extern "kernel32" fn PeekNamedPipe(pipe: Handle, buf: ?*anyopaque, size: u32, read: ?*u32, available: ?*u32, left: ?*u32) callconv(.winapi) c_int;
    extern "kernel32" fn ReadFile(file: Handle, buf: [*]u8, n: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn WriteFile(file: Handle, buf: [*]const u8, n: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn WaitForSingleObject(h: Handle, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn TerminateProcess(process: Handle, code: c_uint) callconv(.winapi) c_int;
    extern "kernel32" fn ResumeThread(thread: Handle) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(h: Handle) callconv(.winapi) c_int;
    extern "kernel32" fn CreateJobObjectW(attrs: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?Handle;
    extern "kernel32" fn SetInformationJobObject(job: Handle, class: c_int, info: *const anyopaque, size: u32) callconv(.winapi) c_int;
    extern "kernel32" fn AssignProcessToJobObject(job: Handle, process: Handle) callconv(.winapi) c_int;
    extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
    extern "kernel32" fn FreeEnvironmentStringsW(block: [*]u16) callconv(.winapi) c_int;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
} else struct {};

fn closeHandle(h: ?Handle) void {
    if (h) |handle| _ = k32.CloseHandle(handle);
}

pub const Pty = struct {
    process: ?Handle = null,
    job: ?Handle = null,
    hpc: ?Handle = null,
    input: ?Handle = null,
    output: ?Handle = null,

    pub const ReadResult = union(enum) { data: usize, idle, closed };

    /// Wait up to `timeout_ms` for output. `closed` means the child has exited and
    /// its output is drained. Anonymous pipes cannot be waited on, so this peeks
    /// and sleeps in short steps; the UI thread never calls it.
    pub fn readTimeout(self: *const Pty, buf: []u8, timeout_ms: c_int) ReadResult {
        const out = self.output orelse return .closed;
        if (buf.len == 0) return .idle;
        const deadline = k32.GetTickCount64() +| @as(u64, @intCast(@max(timeout_ms, 0)));
        var exit_seen = false;
        while (true) {
            var avail: u32 = 0;
            if (k32.PeekNamedPipe(out, null, 0, null, &avail, null) == 0) return .closed;
            if (avail > 0) {
                var got: u32 = 0;
                const want: u32 = @intCast(@min(@as(usize, avail), buf.len));
                if (k32.ReadFile(out, buf.ptr, want, &got, null) == 0 or got == 0) return .closed;
                return .{ .data = got };
            }
            if (!self.processRunning()) {
                // conhost may still be flushing the last frame after the child
                // exits: look once more after a short pause before giving up.
                if (exit_seen) return .closed;
                exit_seen = true;
                k32.Sleep(100);
                continue;
            }
            const now = k32.GetTickCount64();
            if (now >= deadline) return .idle;
            k32.Sleep(@intCast(@min(deadline - now, 10)));
        }
    }

    /// Write all of `data` to the child's input. The pipe holds 64 KiB and conhost
    /// drains it independently of the child, so this does not block in practice.
    pub fn writeAll(self: *const Pty, data: []const u8) bool {
        const in = self.input orelse return false;
        var off: usize = 0;
        while (off < data.len) {
            const n: u32 = @intCast(@min(data.len - off, std.math.maxInt(u32)));
            var written: u32 = 0;
            if (k32.WriteFile(in, data[off..].ptr, n, &written, null) == 0 or written == 0) return false;
            off += written;
        }
        return true;
    }

    /// Pixel sizes are unused: ConPTY only knows cells.
    pub fn resize(self: *const Pty, cols: u16, rows: u16, cell_w: u16, cell_h: u16) void {
        _ = cell_w;
        _ = cell_h;
        const hpc = self.hpc orelse return;
        _ = k32.ResizePseudoConsole(hpc, .{ .x = @intCast(@min(cols, 32767)), .y = @intCast(@min(rows, 32767)) });
    }

    fn processRunning(self: *const Pty) bool {
        const p = self.process orelse return false;
        return k32.WaitForSingleObject(p, 0) == WAIT_TIMEOUT;
    }

    /// True while the child has not exited.
    pub fn alive(self: *Pty) bool {
        return self.processRunning();
    }

    /// Start ending the child without waiting; `close` finishes the job.
    pub fn hangup(self: *Pty) void {
        const p = self.process orelse return;
        if (self.processRunning()) _ = k32.TerminateProcess(p, 1);
    }

    /// Terminate the child tree and release every handle. Safe to call twice.
    /// Call it only once no other thread is reading or writing this `Pty`.
    pub fn close(self: *Pty) void {
        if (self.process) |p| {
            if (self.processRunning()) {
                _ = k32.TerminateProcess(p, 1);
                _ = k32.WaitForSingleObject(p, 2000);
            }
            closeHandle(p);
            self.process = null;
        }
        // Closing the job kills anything the child started and left running.
        closeHandle(self.job);
        self.job = null;
        if (self.hpc) |hpc| closeConsole(hpc, self.output);
        self.hpc = null;
        closeHandle(self.input);
        self.input = null;
        closeHandle(self.output);
        self.output = null;
    }
};

const CloseCtx = struct {
    hpc: Handle,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn closeConsoleThread(ctx: *CloseCtx) void {
    k32.ClosePseudoConsole(ctx.hpc);
    ctx.done.store(true, .release);
}

/// `ClosePseudoConsole` can block until conhost's final output has been read
/// (before Windows 11 24H2). Run it on a helper thread and drain the pipe here
/// meanwhile; give up waiting after ~2 s and leave the helper to finish alone.
fn closeConsole(hpc: Handle, output: ?Handle) void {
    const ctx = std.heap.page_allocator.create(CloseCtx) catch {
        k32.ClosePseudoConsole(hpc);
        return;
    };
    ctx.* = .{ .hpc = hpc };
    const th = std.Thread.spawn(.{}, closeConsoleThread, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        k32.ClosePseudoConsole(hpc);
        return;
    };
    th.detach();
    var sink: [4096]u8 = undefined;
    var waited: u32 = 0;
    while (!ctx.done.load(.acquire) and waited < 200) : (waited += 1) {
        var avail: u32 = 0;
        if (output) |out| {
            if (k32.PeekNamedPipe(out, null, 0, null, &avail, null) != 0 and avail > 0) {
                var got: u32 = 0;
                _ = k32.ReadFile(out, &sink, @intCast(@min(@as(usize, avail), sink.len)), &got, null);
                continue;
            }
        }
        k32.Sleep(10);
    }
    // Only free once the helper has certainly stopped touching it.
    if (ctx.done.load(.acquire)) std.heap.page_allocator.destroy(ctx);
}

pub const SpawnError = error{ Unsupported, ForkFailed, OutOfMemory, BadArgument };

/// Start a command on a new pseudo console of `cols` x `rows`.
///
/// Unlike POSIX, a single `argv` element is taken as the complete, already
/// quoted command line (agent_launch_pure builds those for cmd and PowerShell,
/// whose quoting differs); several elements are quoted and joined. The
/// executable is found like CreateProcess does (system directory, then PATH).
/// `extra_env` entries are `NAME=value` and replace same-named inherited ones.
/// `ForkFailed` means a Win32 call failed.
pub fn spawn(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    extra_env: []const []const u8,
    cols: u16,
    rows: u16,
) SpawnError!Pty {
    if (!is_windows) return error.Unsupported;
    if (argv.len == 0) return error.BadArgument;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = if (argv.len == 1) argv[0] else try cmdline.joinArgv(arena, argv);
    if (line.len == 0 or std.mem.indexOfScalar(u8, line, 0) != null) return error.BadArgument;
    const line_w = std.unicode.utf8ToUtf16LeAllocZ(arena, line) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.BadArgument,
    };
    for (extra_env) |entry| if (std.mem.indexOfScalar(u8, entry, 0) != null) return error.BadArgument;

    // Environment: our own, with `extra_env` laid over it.
    const inherited = k32.GetEnvironmentStringsW() orelse return error.ForkFailed;
    defer _ = k32.FreeEnvironmentStringsW(inherited);
    var inherited_len: usize = 0;
    while (inherited[inherited_len] != 0 or inherited[inherited_len + 1] != 0) inherited_len += 1;
    const env_w = buildEnvBlock(arena, inherited[0 .. inherited_len + 1], extra_env) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.BadArgument,
    };

    // Pipes. `in_read` / `out_write` belong to conhost once the console exists,
    // so they are closed here on every path; the other two ends go to the Pty.
    var in_read: ?Handle = null;
    var in_write: ?Handle = null;
    var out_read: ?Handle = null;
    var out_write: ?Handle = null;
    if (k32.CreatePipe(&in_read, &in_write, null, pipe_size) == 0) return error.ForkFailed;
    defer closeHandle(in_read);
    errdefer closeHandle(in_write);
    if (k32.CreatePipe(&out_read, &out_write, null, pipe_size) == 0) return error.ForkFailed;
    defer closeHandle(out_write);
    errdefer closeHandle(out_read);

    var hpc: ?Handle = null;
    const size: Coord = .{ .x = @intCast(@min(@max(cols, 1), 32767)), .y = @intCast(@min(@max(rows, 1), 32767)) };
    if (k32.CreatePseudoConsole(size, in_read.?, out_write.?, 0, &hpc) < 0 or hpc == null) return error.ForkFailed;
    // Nothing has been read from the output yet, so closing cannot block.
    errdefer k32.ClosePseudoConsole(hpc.?);

    // Attribute list holding the pseudo console. The first call only reports the
    // size it needs and is expected to "fail".
    var list_size: usize = 0;
    _ = k32.InitializeProcThreadAttributeList(null, 1, 0, &list_size);
    if (list_size == 0) return error.ForkFailed;
    const list_mem = arena.alignedAlloc(u8, .of(usize), list_size) catch return error.OutOfMemory;
    const list: *anyopaque = list_mem.ptr;
    if (k32.InitializeProcThreadAttributeList(list, 1, 0, &list_size) == 0) return error.ForkFailed;
    defer k32.DeleteProcThreadAttributeList(list);
    // The value is the HPCON itself, not a pointer to it.
    if (k32.UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc.?, @sizeOf(Handle), null, null) == 0) return error.ForkFailed;

    // A kill-on-close job keeps the whole agent tree from outliving the terminal.
    // It is optional: without one, closing the console still ends the child.
    const job = createKillOnCloseJob();
    errdefer closeHandle(job);

    var startup = std.mem.zeroes(StartupInfoExW);
    startup.startup_info.cb = @sizeOf(StartupInfoExW);
    startup.attribute_list = list;
    var info = std.mem.zeroes(ProcessInformation);
    var flags: u32 = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT;
    // Start suspended when a job exists, so the child cannot spawn processes
    // before it is inside the job.
    if (job != null) flags |= CREATE_SUSPENDED;
    // bInheritHandles must be FALSE: the console is attached by the attribute.
    if (k32.CreateProcessW(null, line_w.ptr, null, null, 0, flags, env_w.ptr, null, &startup, &info) == 0) return error.ForkFailed;
    const process = info.process orelse return error.ForkFailed;
    errdefer {
        _ = k32.TerminateProcess(process, 1);
        closeHandle(process);
    }
    if (job) |j| _ = k32.AssignProcessToJobObject(j, process);
    if (info.thread) |t| {
        if (job != null and k32.ResumeThread(t) == std.math.maxInt(u32)) {
            closeHandle(t);
            return error.ForkFailed;
        }
        closeHandle(t);
    }

    return .{ .process = process, .job = job, .hpc = hpc, .input = in_write, .output = out_read };
}

fn createKillOnCloseJob() ?Handle {
    const job = k32.CreateJobObjectW(null, null) orelse return null;
    var limits = std.mem.zeroes(JobExtendedLimit);
    limits.basic.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (k32.SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, &limits, @sizeOf(JobExtendedLimit)) == 0) {
        _ = k32.CloseHandle(job);
        return null;
    }
    return job;
}

// ── Environment block (pure) ──

fn upper(c: u16) u16 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

/// Offset of the `=` ending a variable name. Names may start with `=` (the
/// per-drive `=C:` entries), so the search starts at the second character.
fn nameEnd(entry: []const u16) usize {
    if (entry.len < 2) return entry.len;
    return std.mem.indexOfScalarPos(u16, entry, 1, '=') orelse entry.len;
}

fn nameLess(_: void, a: []const u16, b: []const u16) bool {
    const an = a[0..nameEnd(a)];
    const bn = b[0..nameEnd(b)];
    for (0..@min(an.len, bn.len)) |i| {
        const x = upper(an[i]);
        const y = upper(bn[i]);
        if (x != y) return x < y;
    }
    return an.len < bn.len;
}

fn sameName(entry: []const u16, name: []const u8) bool {
    const en = entry[0..nameEnd(entry)];
    if (en.len != name.len) return false;
    for (en, name) |x, y| {
        if (x >= 128 or upper(x) != upper(y)) return false;
    }
    return true;
}

/// A CreateProcess environment block: `inherited` (a block as returned by
/// GetEnvironmentStringsW, NUL separated, ended by an empty string) with every
/// `NAME=value` in `extra_env` replacing a same-named entry (names compare
/// case-insensitively, as Windows treats them). Sorted by name, double-NUL ended.
pub fn buildEnvBlock(allocator: std.mem.Allocator, inherited: []const u16, extra_env: []const []const u8) error{ OutOfMemory, InvalidUtf8 }![]u16 {
    var entries: std.ArrayList([]const u16) = .empty;
    var i: usize = 0;
    while (i < inherited.len and inherited[i] != 0) {
        var j = i;
        while (j < inherited.len and inherited[j] != 0) j += 1;
        const entry = inherited[i..j];
        i = j + 1;
        var replaced = false;
        for (extra_env) |extra| {
            const eq = std.mem.indexOfScalar(u8, extra, '=') orelse continue;
            if (eq > 0 and sameName(entry, extra[0..eq])) replaced = true;
        }
        if (!replaced) try entries.append(allocator, entry);
    }
    for (extra_env) |extra| {
        const eq = std.mem.indexOfScalar(u8, extra, '=') orelse continue;
        if (eq == 0) continue;
        try entries.append(allocator, try std.unicode.utf8ToUtf16LeAlloc(allocator, extra));
    }
    std.mem.sort([]const u16, entries.items, {}, nameLess);

    var total: usize = 1;
    for (entries.items) |e| total += e.len + 1;
    // An empty block still needs two terminators.
    if (entries.items.len == 0) total += 1;
    const block = try allocator.alloc(u16, total);
    var n: usize = 0;
    for (entries.items) |e| {
        @memcpy(block[n..][0..e.len], e);
        n += e.len;
        block[n] = 0;
        n += 1;
    }
    while (n < total) : (n += 1) block[n] = 0;
    return block;
}

fn utf16Lit(comptime s: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

test "environment block replaces names case-insensitively and sorts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const inherited = comptime utf16Lit("=C:=C:\\work\x00Path=C:\\Windows\x00TERM=dumb\x00\x00");
    const block = try buildEnvBlock(arena_state.allocator(), inherited, &.{ "term=xterm-256color", "OPAL_X=1", "NOEQUALS" });
    const want = comptime utf16Lit("=C:=C:\\work\x00OPAL_X=1\x00Path=C:\\Windows\x00term=xterm-256color\x00\x00");
    try std.testing.expectEqualSlices(u16, want, block);
}

test "an empty environment still ends in two NULs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const block = try buildEnvBlock(arena_state.allocator(), &.{ 0, 0 }, &.{});
    try std.testing.expectEqualSlices(u16, &.{ 0, 0 }, block);
}

test "a drive entry is not mistaken for a variable named empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const inherited = comptime utf16Lit("=C:=C:\\x\x00\x00");
    // `=C` is not `C:`; nothing is replaced.
    const block = try buildEnvBlock(arena_state.allocator(), inherited, &.{"C:=1"});
    try std.testing.expectEqualSlices(u16, comptime utf16Lit("=C:=C:\\x\x00C:=1\x00\x00"), block);
}

fn drain(pty: *Pty, needle: []const u8) !void {
    var out: [512]u8 = undefined;
    var len: usize = 0;
    var spins: u32 = 0;
    while (spins < 100) : (spins += 1) {
        switch (pty.readTimeout(out[len..], 100)) {
            .data => |n| len += n,
            .idle => {},
            .closed => break,
        }
        if (std.mem.indexOf(u8, out[0..len], needle) != null) return;
    }
    return error.TestExpectedEqual;
}

test "a child on a pseudo console produces output and exits" {
    if (!is_windows) return error.SkipZigTest;
    var pty = try spawn(std.testing.allocator, &.{"cmd.exe /d /c echo hello from conpty"}, &.{"TERM=xterm-256color"}, 80, 24);
    defer pty.close();
    try drain(&pty, "hello from conpty");
}

test "input written to the pseudo console reaches the child" {
    if (!is_windows) return error.SkipZigTest;
    var pty = try spawn(std.testing.allocator, &.{"cmd.exe /d /k"}, &.{}, 80, 24);
    defer pty.close();
    // The typed line is echoed back too; only the expanded variable proves cmd ran it.
    try std.testing.expect(pty.writeAll("echo got:%OS%\r"));
    try drain(&pty, "got:Windows_NT");
    pty.resize(100, 30, 8, 16);
    try std.testing.expect(pty.alive());
}
