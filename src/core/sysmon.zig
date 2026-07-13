//! System + process resource sampler.
//!
//! Publishes a snapshot the UI reads each frame: system CPU/memory, and this
//! process's own CPU, resident memory, thread count and energy impact.
//!
//! Sampled on a background thread at 1 Hz. NOT on the UI thread and NOT per
//! frame: every one of these is a syscall, several walk kernel structures, and a
//! meter that costs more than the thing it measures is a bad joke.
//!
//! CPU is a RATE, so it needs two samples and a delta. The first tick after
//! launch therefore reports 0 rather than a garbage spike — a meter that opens
//! at 100% teaches you to ignore it.
//!
//! macOS uses mach (host_statistics64 / host_processor_info / task_info); Linux
//! reads /proc. Anywhere else the sampler simply never starts and the meters
//! don't render — no fake numbers.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("io_global.zig");
const pure = @import("sysmon_pure.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
pub const supported = is_macos or is_linux;

const mach = if (is_macos) @cImport({
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_host.h");
    @cInclude("mach/task_info.h");
    @cInclude("sys/sysctl.h");
    @cInclude("unistd.h");
}) else struct {};

pub const Snapshot = struct {
    /// Whole-machine CPU across all cores, 0-100.
    sys_cpu_pct: f32 = 0,
    sys_mem_used: u64 = 0,
    sys_mem_total: u64 = 0,

    /// This process, 0-100 of ONE core (so >100 is possible on a busy decode —
    /// that's what Activity Monitor shows too, and clamping it would hide the
    /// truth).
    app_cpu_pct: f32 = 0,
    app_mem_rss: u64 = 0,
    app_threads: u32 = 0,
    /// Derived impact score (CPU + wakeups) — see sysmon_pure.energyImpact.
    app_energy: f32 = 0,

    /// False until the first delta has been computed. The UI hides the meters
    /// rather than showing a confident zero.
    valid: bool = false,
};

// ── Published state ──
//
// Written by the sampler thread, read by the UI thread every frame. Guarded by a
// mutex rather than atomics: it's one small struct copied at 1 Hz, and a torn
// read here would put a half-updated number on screen.
var snap_mutex: @import("sync.zig").Mutex = .{};
var snap: Snapshot = .{};

var running = std.atomic.Value(bool).init(false);
var stop_flag = std.atomic.Value(bool).init(false);

pub fn get() Snapshot {
    snap_mutex.lock();
    defer snap_mutex.unlock();
    return snap;
}

/// Start the sampler. Idempotent; a no-op on an unsupported OS.
pub fn start() void {
    if (!supported) return;
    if (running.swap(true, .acq_rel)) return;
    stop_flag.store(false, .release);
    (std.Thread.spawn(.{}, sampleLoop, .{}) catch {
        running.store(false, .release);
        return;
    }).detach();
}

pub fn stop() void {
    stop_flag.store(true, .release);
}

// ══════════════════════════════════════════════════════════
// Sampling
// ══════════════════════════════════════════════════════════

const Prev = struct {
    // System CPU ticks.
    sys_busy: u64 = 0,
    sys_total: u64 = 0,
    // Process CPU time (ns) + wakeups, and when we read them.
    app_cpu_ns: u64 = 0,
    app_wakeups: u64 = 0,
    at_ms: i64 = 0,
    have: bool = false,
};

fn sampleLoop() void {
    defer running.store(false, .release);
    var prev: Prev = .{};

    while (!stop_flag.load(.acquire)) {
        var s: Snapshot = .{};
        sampleInto(&s, &prev);

        snap_mutex.lock();
        snap = s;
        snap_mutex.unlock();


        io.sleep(1000 * std.time.ns_per_ms);
    }
}

fn sampleInto(s: *Snapshot, prev: *Prev) void {
    if (is_macos) {
        sampleMac(s, prev);
    } else if (is_linux) {
        sampleLinux(s, prev);
    }
}

// ── macOS ──

fn sampleMac(s: *Snapshot, prev: *Prev) void {
    const host = mach.mach_host_self();

    // ── System memory ──
    {
        var total: u64 = 0;
        var len: usize = @sizeOf(u64);
        if (mach.sysctlbyname("hw.memsize", &total, &len, null, 0) == 0) {
            s.sys_mem_total = total;
        }

        var vm: mach.vm_statistics64_data_t = std.mem.zeroes(mach.vm_statistics64_data_t);
        var count: mach.mach_msg_type_number_t = @sizeOf(mach.vm_statistics64_data_t) / @sizeOf(mach.integer_t);
        if (mach.host_statistics64(host, mach.HOST_VM_INFO64, @ptrCast(&vm), &count) == mach.KERN_SUCCESS) {
            const page: u64 = @intCast(mach.getpagesize());
            // "Used" the way Activity Monitor means it: what you can't get back
            // without paging. Free + purgeable + file-backed cache is reclaimable,
            // so counting it as used would make a healthy machine look full.
            const wired: u64 = @intCast(vm.wire_count);
            const active: u64 = @intCast(vm.active_count);
            const compressed: u64 = @intCast(vm.compressor_page_count);
            s.sys_mem_used = (wired + active + compressed) * page;
        }
    }

    // ── System CPU (delta of tick counters) ──
    {
        var cpu_count: mach.natural_t = 0;
        var info: mach.processor_info_array_t = undefined;
        var info_count: mach.mach_msg_type_number_t = 0;

        if (mach.host_processor_info(host, mach.PROCESSOR_CPU_LOAD_INFO, &cpu_count, &info, &info_count) == mach.KERN_SUCCESS) {
            const ticks: [*]mach.integer_t = @ptrCast(info);
            var busy: u64 = 0;
            var total: u64 = 0;
            var i: usize = 0;
            while (i < cpu_count) : (i += 1) {
                const base = i * mach.CPU_STATE_MAX;
                const user: u64 = @intCast(@max(0, ticks[base + mach.CPU_STATE_USER]));
                const sys: u64 = @intCast(@max(0, ticks[base + mach.CPU_STATE_SYSTEM]));
                const nice: u64 = @intCast(@max(0, ticks[base + mach.CPU_STATE_NICE]));
                const idle: u64 = @intCast(@max(0, ticks[base + mach.CPU_STATE_IDLE]));
                busy += user + sys + nice;
                total += user + sys + nice + idle;
            }
            // The kernel VM-allocated this array for us; leaking it every second
            // would be a slow, embarrassing leak in the thing that measures leaks.
            _ = mach.vm_deallocate(mach.mach_task_self_, @intFromPtr(info), info_count * @sizeOf(mach.integer_t));

            if (prev.have and total > prev.sys_total) {
                const dbusy: f32 = @floatFromInt(busy - prev.sys_busy);
                const dtotal: f32 = @floatFromInt(total - prev.sys_total);
                s.sys_cpu_pct = pure.frac(dbusy, dtotal) * 100;
            }
            prev.sys_busy = busy;
            prev.sys_total = total;
        }
    }

    const task = mach.mach_task_self_;

    // ── Process resident memory ──
    {
        var ti: mach.mach_task_basic_info_data_t = std.mem.zeroes(mach.mach_task_basic_info_data_t);
        var cnt: mach.mach_msg_type_number_t = mach.MACH_TASK_BASIC_INFO_COUNT;
        if (mach.task_info(task, mach.MACH_TASK_BASIC_INFO, @ptrCast(&ti), &cnt) == mach.KERN_SUCCESS) {
            s.app_mem_rss = ti.resident_size;
        }
    }

    // ── Thread count ──
    {
        var threads: mach.thread_act_array_t = undefined;
        var n: mach.mach_msg_type_number_t = 0;
        if (mach.task_threads(task, &threads, &n) == mach.KERN_SUCCESS) {
            s.app_threads = @intCast(n);
            // Each port has to be given back, and then the array itself — the
            // classic task_threads leak is forgetting one of the two.
            var i: usize = 0;
            while (i < n) : (i += 1) _ = mach.mach_port_deallocate(task, threads[i]);
            _ = mach.vm_deallocate(task, @intFromPtr(threads), n * @sizeOf(mach.thread_act_t));
        }
    }

    // ── Process CPU + energy (delta) ──
    {
        var pi: mach.task_power_info_data_t = std.mem.zeroes(mach.task_power_info_data_t);
        var cnt: mach.mach_msg_type_number_t = mach.TASK_POWER_INFO_COUNT;
        if (mach.task_info(task, mach.TASK_POWER_INFO, @ptrCast(&pi), &cnt) == mach.KERN_SUCCESS) {
            const cpu_ns: u64 = pi.total_user + pi.total_system;
            const wakeups: u64 = pi.task_interrupt_wakeups + pi.task_platform_idle_wakeups;
            const now = io.milliTimestamp();

            if (prev.have and now > prev.at_ms and cpu_ns >= prev.app_cpu_ns) {
                const dt_ms: f32 = @floatFromInt(now - prev.at_ms);
                const dcpu_ns: f32 = @floatFromInt(cpu_ns - prev.app_cpu_ns);
                // ns of CPU per ms of wall time -> % of one core.
                s.app_cpu_pct = (dcpu_ns / 1_000_000.0) / dt_ms * 100.0;

                const dwake: f32 = @floatFromInt(wakeups -| prev.app_wakeups);
                const wps = dwake / (dt_ms / 1000.0);
                s.app_energy = pure.energyImpact(s.app_cpu_pct, wps);
            }

            prev.app_cpu_ns = cpu_ns;
            prev.app_wakeups = wakeups;
            prev.at_ms = now;
        }
    }

    // Only now is a delta meaningful. Until then the UI shows nothing rather than
    // a confident zero.
    if (prev.have) s.valid = true;
    prev.have = true;
}

// ── Linux ──

fn sampleLinux(s: *Snapshot, prev: *Prev) void {
    var buf: [4096]u8 = undefined;

    // /proc/stat -> system CPU ticks
    if (readFile("/proc/stat", &buf)) |txt| {
        if (std.mem.indexOf(u8, txt, "cpu ")) |at| {
            var it = std.mem.tokenizeScalar(u8, txt[at + 4 ..], ' ');
            var total: u64 = 0;
            var idle: u64 = 0;
            var i: usize = 0;
            while (it.next()) |tok| : (i += 1) {
                if (i >= 10) break;
                const v = std.fmt.parseInt(u64, std.mem.trim(u8, tok, "\n\r"), 10) catch break;
                total += v;
                if (i == 3 or i == 4) idle += v; // idle + iowait
            }
            const busy = total -| idle;
            if (prev.have and total > prev.sys_total) {
                const dbusy: f32 = @floatFromInt(busy -| prev.sys_busy);
                const dtotal: f32 = @floatFromInt(total - prev.sys_total);
                s.sys_cpu_pct = pure.frac(dbusy, dtotal) * 100;
            }
            prev.sys_busy = busy;
            prev.sys_total = total;
        }
    }

    // /proc/meminfo -> system memory
    if (readFile("/proc/meminfo", &buf)) |txt| {
        const total_kb = kvKb(txt, "MemTotal:") orelse 0;
        const avail_kb = kvKb(txt, "MemAvailable:") orelse 0;
        s.sys_mem_total = total_kb * 1024;
        s.sys_mem_used = (total_kb -| avail_kb) * 1024;
    }

    // /proc/self/stat -> process CPU + threads
    if (readFile("/proc/self/stat", &buf)) |txt| {
        // Fields after the (comm) field, which can itself contain spaces.
        if (std.mem.lastIndexOfScalar(u8, txt, ')')) |close| {
            var it = std.mem.tokenizeScalar(u8, txt[close + 1 ..], ' ');
            var idx: usize = 0;
            var utime: u64 = 0;
            var stime: u64 = 0;
            var threads: u64 = 0;
            while (it.next()) |tok| : (idx += 1) {
                // Offsets are relative to field 3 (state) being idx 0.
                switch (idx) {
                    11 => utime = std.fmt.parseInt(u64, tok, 10) catch 0,
                    12 => stime = std.fmt.parseInt(u64, tok, 10) catch 0,
                    17 => threads = std.fmt.parseInt(u64, tok, 10) catch 0,
                    else => {},
                }
                if (idx > 18) break;
            }
            s.app_threads = @intCast(@min(threads, std.math.maxInt(u32)));

            const hz: u64 = 100; // USER_HZ; 100 on every mainstream kernel
            const cpu_ns = (utime + stime) * (1_000_000_000 / hz);
            const now = io.milliTimestamp();
            if (prev.have and now > prev.at_ms and cpu_ns >= prev.app_cpu_ns) {
                const dt_ms: f32 = @floatFromInt(now - prev.at_ms);
                const dcpu_ns: f32 = @floatFromInt(cpu_ns - prev.app_cpu_ns);
                s.app_cpu_pct = (dcpu_ns / 1_000_000.0) / dt_ms * 100.0;
                // No wakeup counter on Linux without perf events; energy is the
                // CPU term alone. Labelled the same, derived honestly from less.
                s.app_energy = pure.energyImpact(s.app_cpu_pct, 0);
            }
            prev.app_cpu_ns = cpu_ns;
            prev.at_ms = now;
        }
    }

    // /proc/self/statm -> resident pages
    if (readFile("/proc/self/statm", &buf)) |txt| {
        var it = std.mem.tokenizeScalar(u8, txt, ' ');
        _ = it.next(); // size
        if (it.next()) |res| {
            const pages = std.fmt.parseInt(u64, std.mem.trim(u8, res, "\n\r"), 10) catch 0;
            s.app_mem_rss = pages * 4096;
        }
    }

    if (prev.have) s.valid = true;
    prev.have = true;
}

fn readFile(path: []const u8, buf: []u8) ?[]const u8 {
    const f = io.openFileAbsolute(path, .{}) catch return null;
    defer f.close(io.io());
    const n = io.readAll(&f, buf) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

fn kvKb(txt: []const u8, key: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, txt, key) orelse return null;
    var it = std.mem.tokenizeScalar(u8, txt[at + key.len ..], ' ');
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, tok, "\n\r"), 10) catch null;
}
