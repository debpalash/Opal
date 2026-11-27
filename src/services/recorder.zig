//! Live TV recording service (issue #240). Jobs live in fixed slots, are saved
//! to `<config>/recordings.tsv`, and a once-a-second tick starts each one when
//! its window opens. A recording is one worker thread running ffmpeg
//! (`-c copy` into MPEG-TS) under bounded_process: `-t` stops it at the end of
//! the window, Cancel stops it early and keeps what was captured. Files go to
//! `<save path>/Recordings/`, so they show up in Downloads too. All decisions
//! (due/missed, length, argv, file name, list format) are recorder_pure.

const std = @import("std");
const pure = @import("recorder_pure.zig");
const state = @import("../core/state.zig");
const io = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const logs = @import("../core/logs.zig");
const alloc = @import("../core/alloc.zig").allocator;
const Mutex = @import("../core/sync.zig").Mutex;

pub const Job = pure.Job;
pub const Status = pure.Status;

const Slot = struct {
    used: bool = false,
    job: Job = .{},
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
};

var slots: [pure.MAX_JOBS]Slot = @splat(.{});
var mutex: Mutex = .{};
var loaded = false;
var next_id: u32 = 1;
var last_tick_s: i64 = 0;

fn listPath(buf: []u8) ?[]const u8 {
    var dir_buf: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/recordings.tsv", .{paths.configDir(&dir_buf)}) catch null;
}

/// `<save path>/Recordings`.
pub fn recordingsDir(buf: []u8) []const u8 {
    var save_buf: [512]u8 = undefined;
    const save = if (state.app.save_path_len > 0)
        state.app.save_path_buf[0..state.app.save_path_len]
    else
        paths.defaultSavePath(&save_buf);
    return std.fmt.bufPrint(buf, "{s}/Recordings", .{save}) catch "";
}

/// Caller holds `mutex`.
fn loadLocked() void {
    if (loaded) return;
    loaded = true;
    var path_buf: [600]u8 = undefined;
    const path = listPath(&path_buf) orelse return;
    const body = io.cwdReadFileAlloc(path, alloc, 512 * 1024) catch return;
    defer alloc.free(body);
    var lines = std.mem.splitScalar(u8, body, '\n');
    var i: usize = 0;
    while (lines.next()) |line| {
        if (i >= slots.len) break;
        const job = pure.decode(line) orelse continue;
        slots[i] = .{ .used = true, .job = job };
        if (job.id >= next_id) next_id = job.id + 1;
        i += 1;
    }
}

/// Caller holds `mutex`. Write-then-rename so a crash never truncates the list.
fn saveLocked() void {
    var path_buf: [600]u8 = undefined;
    const path = listPath(&path_buf) orelse return;
    var tmp_buf: [610]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(alloc);
    var line_buf: [2048]u8 = undefined;
    for (&slots) |*s| {
        if (!s.used) continue;
        const line = pure.encode(&s.job, &line_buf);
        if (line.len == 0) continue;
        body.appendSlice(alloc, line) catch return;
        body.append(alloc, '\n') catch return;
    }
    io.cwdWriteFile(.{ .sub_path = tmp, .data = body.items }) catch return;
    io.renameAbsolute(tmp, path) catch {};
}

pub const ScheduleError = pure.NewJobError || error{Full};

/// Add a recording. `start_s` = when to start (unix seconds; may be now or a
/// moment in the past for a programme already on air).
pub fn schedule(name: []const u8, url: []const u8, user_agent: []const u8, referrer: []const u8, start_s: i64, duration_s: u32) ScheduleError!u32 {
    mutex.lock();
    defer mutex.unlock();
    loadLocked();
    const job = try pure.newJob(next_id, name, url, user_agent, referrer, start_s, duration_s, io.timestamp());
    for (&slots) |*s| {
        if (s.used) continue;
        s.* = .{ .used = true, .job = job };
        next_id += 1;
        saveLocked();
        last_tick_s = 0; // let the next tick start it right away when due
        return job.id;
    }
    return error.Full;
}

/// Stop a recording (keeps the captured part) or drop a scheduled one.
pub fn cancel(id: u32) void {
    mutex.lock();
    defer mutex.unlock();
    for (&slots) |*s| {
        if (!s.used or s.job.id != id) continue;
        switch (s.job.status) {
            .scheduled => {
                s.job.status = .cancelled;
                saveLocked();
            },
            .recording => s.cancel.store(true, .release), // worker records the outcome
            else => {},
        }
    }
}

/// Forget a job that is not recording. The file (if any) stays on disk.
pub fn remove(id: u32) void {
    mutex.lock();
    defer mutex.unlock();
    for (&slots) |*s| {
        if (!s.used or s.job.id != id or s.job.status == .recording) continue;
        if (s.thread) |th| th.join(); // finished worker: reap before reuse
        s.* = .{};
        saveLocked();
    }
}

/// Snapshot for the UI (copied under the lock).
pub fn snapshot(out: []Job) usize {
    mutex.lock();
    defer mutex.unlock();
    loadLocked();
    var n: usize = 0;
    for (&slots) |*s| {
        if (!s.used or n >= out.len) continue;
        out[n] = s.job;
        n += 1;
    }
    std.mem.sort(Job, out[0..n], {}, struct {
        fn lt(_: void, a: Job, b: Job) bool {
            return a.start_s > b.start_s; // newest first
        }
    }.lt);
    return n;
}

/// Per frame (and per headless loop): at most one real pass a second.
pub fn tick() void {
    const now = io.timestamp();
    if (now == last_tick_s) return;
    last_tick_s = now;
    mutex.lock();
    defer mutex.unlock();
    loadLocked();
    var changed = false;
    for (&slots, 0..) |*s, i| {
        if (!s.used) continue;
        switch (pure.actionAt(&s.job, now)) {
            .mark_missed => {
                s.job.status = .failed;
                changed = true;
                logs.pushLog("warn", "recorder", "Missed a scheduled recording: Opal was not running during its window", false);
            },
            .start => {
                if (s.thread) |th| th.join(); // a reused slot's old worker has ended
                s.thread = null;
                s.cancel.store(false, .release);
                s.job.status = .recording;
                s.thread = std.Thread.spawn(.{}, worker, .{ i, s.job.id }) catch {
                    s.job.status = .failed;
                    changed = true;
                    continue;
                };
                changed = true;
            },
            .wait, .none => {},
        }
    }
    if (changed) saveLocked();
}

fn ffmpegPath() []const u8 {
    return @import("live_captions_engine.zig").ffmpegPath();
}

/// Whether ffmpeg can be found (a known install path, else a PATH entry).
/// Without it a recording fails at its start time, so the UI warns up front.
pub fn ffmpegAvailable() bool {
    if (!std.mem.eql(u8, ffmpegPath(), "ffmpeg")) return true;
    const path_env = io.getenv("PATH") orelse return false;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    var buf: [600]u8 = undefined;
    while (it.next()) |dir| {
        const candidate = std.fmt.bufPrint(&buf, "{s}/ffmpeg", .{dir}) catch continue;
        if (io.cwdAccess(candidate, .{})) |_| return true else |_| {}
    }
    return false;
}

fn finishJob(slot: usize, id: u32, status: Status, out: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    const s = &slots[slot];
    if (!s.used or s.job.id != id) return;
    s.job.status = status;
    const n = @min(out.len, s.job.out.len);
    @memcpy(s.job.out[0..n], out[0..n]);
    s.job.out_len = n;
    saveLocked();
}

/// One recording: snapshot the job, run ffmpeg for the rest of the window,
/// record the outcome. Never touches `slots` without the lock.
fn worker(slot: usize, id: u32) void {
    var job: Job = undefined;
    {
        mutex.lock();
        defer mutex.unlock();
        if (!slots[slot].used or slots[slot].job.id != id) return;
        job = slots[slot].job;
    }
    const now = io.timestamp();
    const seconds = pure.recordSeconds(&job, now);

    var dir_buf: [600]u8 = undefined;
    const dir = recordingsDir(&dir_buf);
    io.cwdMakePath(dir) catch {};
    var name_buf: [160]u8 = undefined;
    const file = pure.fileName(job.nameSlice(), now, @import("epg.zig").localOffsetAt(now), &name_buf);
    var out_buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&out_buf, "{s}/{s}", .{ dir, file }) catch {
        finishJob(slot, id, .failed, "");
        return;
    };
    finishJob(slot, id, .recording, out); // show the path while recording

    var secs_buf: [16]u8 = undefined;
    var header_buf: [300]u8 = undefined;
    var argv_buf: [32][]const u8 = undefined;
    const argv = pure.ffmpegArgv(ffmpegPath(), &job, seconds, out, &secs_buf, &header_buf, &argv_buf);

    var msg_buf: [200]u8 = undefined;
    logs.pushLog("info", "recorder", std.fmt.bufPrint(&msg_buf, "Recording {s} for {d} min", .{ job.nameSlice(), seconds / 60 }) catch "Recording started", false);

    const bp = @import("../core/bounded_process.zig");
    var process = bp.StreamProcess.init(argv, .{
        .timeout_ms = pure.watchdogMs(seconds),
        .terminate_grace_ms = 3000, // let ffmpeg finalise the file on Cancel
        .max_output_bytes = 1024 * 1024,
        .cancel_flag = &slots[slot].cancel,
    });
    var exit_ok = false;
    if (process.start()) |_| {
        const r = process.finish();
        exit_ok = r.ok();
    } else |_| {
        logs.pushLog("error", "recorder", "Could not start ffmpeg for a recording (is ffmpeg installed?)", true);
    }
    const bytes: u64 = if (io.cwdStatFile(out)) |st| st.size else |_| 0;
    const status = pure.outcome(slots[slot].cancel.load(.acquire), exit_ok, bytes);
    finishJob(slot, id, status, out);
    logs.pushLog(if (status == .done) "info" else "warn", "recorder", std.fmt.bufPrint(&msg_buf, "Recording {s}: {s}", .{ job.nameSlice(), status.label() }) catch "Recording finished", status != .done);
    state.wakeUi();
}

/// appDeinit: stop running recordings (ffmpeg finalises what it has) and reap
/// every worker so none outlives the allocator.
pub fn deinit() void {
    mutex.lock();
    for (&slots) |*s| {
        if (s.used and s.job.status == .recording) s.cancel.store(true, .release);
    }
    var threads: [pure.MAX_JOBS]?std.Thread = @splat(null);
    for (&slots, 0..) |*s, i| {
        threads[i] = s.thread;
        s.thread = null;
    }
    mutex.unlock();
    for (threads) |t| if (t) |th| th.join();
}
