//! Live TV recording — pure decisions (issue #240: "set up a channel and a
//! period to record"). The service (recorder.zig) owns threads, files and
//! ffmpeg; everything it decides goes through here: when a job is due or
//! missed, how long ffmpeg records, the ffmpeg argv, the output file name and
//! the on-disk job list format.

const std = @import("std");

pub const MAX_JOBS: usize = 32;
/// Longest single recording: a whole evening, not an accidental week.
pub const MAX_DURATION_S: u32 = 12 * 3600;
pub const MIN_DURATION_S: u32 = 60;

pub const Status = enum {
    scheduled,
    recording,
    done,
    failed,
    cancelled,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .scheduled => "Scheduled",
            .recording => "Recording",
            .done => "Recorded",
            .failed => "Failed",
            .cancelled => "Cancelled",
        };
    }

    pub fn finished(self: Status) bool {
        return self == .done or self == .failed or self == .cancelled;
    }
};

/// A series: after each run (recorded, failed or missed) the next window is
/// scheduled. Cancel stops the series.
pub const Repeat = enum {
    none,
    daily,
    weekly,

    pub fn periodS(self: Repeat) i64 {
        return switch (self) {
            .none => 0,
            .daily => 24 * 3600,
            .weekly => 7 * 24 * 3600,
        };
    }

    pub fn label(self: Repeat) []const u8 {
        return switch (self) {
            .none => "Once",
            .daily => "Daily",
            .weekly => "Weekly",
        };
    }
};

pub const Job = struct {
    id: u32 = 0,
    status: Status = .scheduled,
    repeat: Repeat = .none,
    start_s: i64 = 0,
    duration_s: u32 = 0,
    name: [128]u8 = undefined,
    name_len: usize = 0,
    url: [512]u8 = undefined,
    url_len: usize = 0,
    user_agent: [256]u8 = undefined,
    user_agent_len: usize = 0,
    referrer: [256]u8 = undefined,
    referrer_len: usize = 0,
    /// Set once recording starts (the file ffmpeg writes).
    out: [512]u8 = undefined,
    out_len: usize = 0,

    pub fn nameSlice(self: *const Job) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn urlSlice(self: *const Job) []const u8 {
        return self.url[0..self.url_len];
    }
    pub fn userAgentSlice(self: *const Job) []const u8 {
        return self.user_agent[0..self.user_agent_len];
    }
    pub fn referrerSlice(self: *const Job) []const u8 {
        return self.referrer[0..self.referrer_len];
    }
    pub fn outSlice(self: *const Job) []const u8 {
        return self.out[0..self.out_len];
    }
    pub fn endS(self: *const Job) i64 {
        return self.start_s + self.duration_s;
    }
};

fn copyInto(dst: []u8, len: *usize, src: []const u8) bool {
    if (src.len > dst.len) return false;
    @memcpy(dst[0..src.len], src);
    len.* = src.len;
    return true;
}

pub const NewJobError = error{ InvalidStream, InvalidDuration, AlreadyOver, TooLong };

/// A validated job. `start_s` may be in the past only if the window is still
/// open (record the rest of a programme already on air).
pub fn newJob(id: u32, name: []const u8, url: []const u8, user_agent: []const u8, referrer: []const u8, start_s: i64, duration_s: u32, now: i64) NewJobError!Job {
    if (!isRecordableUrl(url)) return error.InvalidStream;
    if (duration_s < MIN_DURATION_S or duration_s > MAX_DURATION_S) return error.InvalidDuration;
    if (start_s + duration_s <= now) return error.AlreadyOver;
    var j: Job = .{ .id = id, .start_s = start_s, .duration_s = duration_s };
    const display = std.mem.trim(u8, name, " \t\r\n");
    if (!copyInto(&j.name, &j.name_len, if (display.len > 0) display[0..@min(display.len, j.name.len)] else "Live TV")) return error.TooLong;
    if (!copyInto(&j.url, &j.url_len, url)) return error.TooLong;
    if (!copyInto(&j.user_agent, &j.user_agent_len, user_agent)) return error.TooLong;
    if (!copyInto(&j.referrer, &j.referrer_len, referrer)) return error.TooLong;
    return j;
}

/// Only network streams; never a local path or a pseudo-scheme ffmpeg would
/// read from disk or a device.
pub fn isRecordableUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > 512) return false;
    if (std.mem.indexOfAny(u8, url, " \t\r\n") != null) return false;
    for ([_][]const u8{ "http://", "https://", "rtmp://", "rtsp://" }) |scheme| {
        if (url.len > scheme.len and std.ascii.eqlIgnoreCase(url[0..scheme.len], scheme)) return true;
    }
    return false;
}

pub const Action = enum { wait, start, mark_missed, none };

/// What the scheduler does with `job` at `now`.
pub fn actionAt(job: *const Job, now: i64) Action {
    if (job.status != .scheduled) return .none;
    if (now >= job.endS()) return .mark_missed; // the app was not running for the window
    if (now >= job.start_s) return .start;
    return .wait;
}

/// Seconds ffmpeg records when starting at `now`: the rest of the window, so a
/// late start (app launched mid-programme) still stops at the scheduled end.
pub fn recordSeconds(job: *const Job, now: i64) u32 {
    const left = job.endS() - @max(now, job.start_s);
    return @intCast(std.math.clamp(left, 1, @as(i64, MAX_DURATION_S)));
}

/// The next window of a series, or null for a one-off or a cancelled series.
/// Windows already over at `now` are skipped (Opal was closed through them);
/// the copy is a fresh scheduled job with `id`, no output file yet.
pub fn nextOccurrence(job: *const Job, id: u32, now: i64) ?Job {
    if (job.repeat == .none or job.status == .cancelled or !job.status.finished()) return null;
    const period = job.repeat.periodS();
    var start = job.start_s + period;
    if (start + job.duration_s <= now) {
        const behind = @divFloor(now - (start + job.duration_s), period) + 1;
        start += behind * period;
    }
    var next = job.*;
    next.id = id;
    next.status = .scheduled;
    next.start_s = start;
    next.out_len = 0;
    return next;
}

/// Hard stop for the ffmpeg process: the window plus a short grace for
/// connecting and finalising. ffmpeg's `-t` counts media time, so a stalling
/// live stream would otherwise keep recording past the scheduled end.
pub fn watchdogMs(record_s: u32) i64 {
    return (@as(i64, record_s) + 30) * 1000;
}

/// `<Channel> YYYY-MM-DD HHMM.ts` in local time (`offset_s` = UTC offset).
/// Path separators and control/shell-hostile characters become `_`.
pub fn fileName(name: []const u8, start_s: i64, offset_s: i64, out: []u8) []const u8 {
    var safe: [96]u8 = undefined;
    var n: usize = 0;
    for (name) |c| {
        if (n >= safe.len) break;
        safe[n] = switch (c) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => '_',
            else => if (c < 0x20 or c == 0x7f) '_' else c,
        };
        n += 1;
    }
    const trimmed = std.mem.trim(u8, safe[0..n], " ._");
    const base = if (trimmed.len > 0) trimmed else "Live TV";
    const local: u64 = @intCast(@max(0, start_s + offset_s));
    const es = std.time.epoch.EpochSeconds{ .secs = local };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(out, "{s} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}{d:0>2}.ts", .{
        base, day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch "";
}

/// ffmpeg argv: copy the stream as-is into MPEG-TS (survives a cut-off end;
/// plays everywhere), stop after `seconds`, never prompt, never overwrite.
pub fn ffmpegArgv(ffmpeg: []const u8, job: *const Job, seconds: u32, out_path: []const u8, secs_buf: []u8, header_buf: []u8, argv: *[32][]const u8) [][]const u8 {
    var n: usize = 0;
    const push = struct {
        fn f(a: *[32][]const u8, i: *usize, v: []const u8) void {
            a[i.*] = v;
            i.* += 1;
        }
    }.f;
    push(argv, &n, ffmpeg);
    for ([_][]const u8{ "-hide_banner", "-loglevel", "error", "-nostdin", "-n" }) |a| push(argv, &n, a);
    if (job.user_agent_len > 0) {
        push(argv, &n, "-user_agent");
        push(argv, &n, job.userAgentSlice());
    }
    if (job.referrer_len > 0) {
        // -headers needs CRLF-terminated lines; a referrer with CR/LF is dropped.
        if (std.mem.indexOfAny(u8, job.referrerSlice(), "\r\n") == null) {
            if (std.fmt.bufPrint(header_buf, "Referer: {s}\r\n", .{job.referrerSlice()})) |h| {
                push(argv, &n, "-headers");
                push(argv, &n, h);
            } else |_| {}
        }
    }
    // Reconnect through brief network drops instead of ending the recording;
    // a read that stalls 15 s fails over to a reconnect rather than hanging.
    for ([_][]const u8{ "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "10", "-rw_timeout", "15000000" }) |a| push(argv, &n, a);
    push(argv, &n, "-i");
    push(argv, &n, job.urlSlice());
    push(argv, &n, "-t");
    push(argv, &n, std.fmt.bufPrint(secs_buf, "{d}", .{seconds}) catch "60");
    for ([_][]const u8{ "-map", "0", "-c", "copy", "-f", "mpegts" }) |a| push(argv, &n, a);
    push(argv, &n, out_path);
    return argv[0..n];
}

/// Outcome of a finished ffmpeg run. `window_over`: stopped by the hard stop
/// at the end of the window (a stalling stream), which is the scheduled end.
pub fn outcome(cancelled: bool, exit_ok: bool, window_over: bool, bytes_written: u64) Status {
    if (bytes_written == 0) return if (cancelled) .cancelled else .failed;
    // A cancelled or window-ended recording keeps what it captured.
    if (cancelled or window_over) return .done;
    return if (exit_ok) .done else .failed;
}

/// `{"ffmpeg":bool,"recordings":[{id,status,start,end,repeat,name,file}]}` for
/// GET /api/livetv/recordings. `file` is the recording's file name only, never
/// the host's directory.
pub fn writeListJson(w: *std.Io.Writer, jobs: []const Job, ffmpeg_available: bool) !void {
    try w.print("{{\"ffmpeg\":{},\"recordings\":[", .{ffmpeg_available});
    for (jobs, 0..) |*job, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"id\":{d},\"status\":\"{s}\",\"start\":{d},\"end\":{d},\"repeat\":\"{s}\",\"name\":{f},\"file\":{f}}}", .{
            job.id,                             @tagName(job.status),                                    job.start_s, job.endS(), @tagName(job.repeat),
            std.json.fmt(job.nameSlice(), .{}), std.json.fmt(std.fs.path.basename(job.outSlice()), .{}),
        });
    }
    try w.writeAll("]}");
}

// ── Persistence: one job per line, tab-separated, free text last ──

fn tabFree(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\t\r\n") == null;
}

/// `id status start duration repeat url ua referrer out name`. Empty if a
/// field cannot be framed (a tab or newline in it).
pub fn encode(job: *const Job, buf: []u8) []const u8 {
    for ([_][]const u8{ job.urlSlice(), job.userAgentSlice(), job.referrerSlice(), job.outSlice(), job.nameSlice() }) |f| {
        if (!tabFree(f)) return "";
    }
    return std.fmt.bufPrint(buf, "{d}\t{s}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}", .{
        job.id, @tagName(job.status), job.start_s, job.duration_s, @tagName(job.repeat), job.urlSlice(), job.userAgentSlice(), job.referrerSlice(), job.outSlice(), job.nameSlice(),
    }) catch "";
}

/// Inverse of encode. A job that was `recording` when the app stopped comes
/// back `failed` (its ffmpeg died with the app; the window may still be open
/// but the partial file is already there).
pub fn decode(line_in: []const u8) ?Job {
    const line = std.mem.trimEnd(u8, line_in, "\r\n");
    var it = std.mem.splitScalar(u8, line, '\t');
    var j: Job = .{};
    j.id = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    j.status = std.meta.stringToEnum(Status, it.next() orelse return null) orelse return null;
    j.start_s = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    j.duration_s = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    // Lines written before repeats existed go straight to the URL.
    var field = it.next() orelse return null;
    if (std.meta.stringToEnum(Repeat, field)) |r| {
        j.repeat = r;
        field = it.next() orelse return null;
    }
    if (!copyInto(&j.url, &j.url_len, field)) return null;
    if (!copyInto(&j.user_agent, &j.user_agent_len, it.next() orelse return null)) return null;
    if (!copyInto(&j.referrer, &j.referrer_len, it.next() orelse return null)) return null;
    if (!copyInto(&j.out, &j.out_len, it.next() orelse return null)) return null;
    const name = it.rest();
    if (!copyInto(&j.name, &j.name_len, name[0..@min(name.len, j.name.len)])) return null;
    if (!isRecordableUrl(j.urlSlice())) return null;
    if (j.duration_s < MIN_DURATION_S or j.duration_s > MAX_DURATION_S) return null;
    if (j.status == .recording) j.status = .failed;
    return j;
}

// ── Tests ──

const t = std.testing;

fn sample(now: i64) Job {
    return newJob(7, "BBC News", "https://example.test/live.m3u8", "", "", now + 600, 3600, now) catch unreachable;
}

test "newJob validates the stream, the period and late starts" {
    const now: i64 = 1_800_000_000;
    try t.expectError(error.InvalidStream, newJob(1, "x", "/etc/passwd", "", "", now, 3600, now));
    try t.expectError(error.InvalidStream, newJob(1, "x", "file:///dev/video0", "", "", now, 3600, now));
    try t.expectError(error.InvalidDuration, newJob(1, "x", "https://a.test/s", "", "", now, 10, now));
    try t.expectError(error.InvalidDuration, newJob(1, "x", "https://a.test/s", "", "", now, MAX_DURATION_S + 1, now));
    try t.expectError(error.AlreadyOver, newJob(1, "x", "https://a.test/s", "", "", now - 7200, 3600, now));
    // A programme already on air can still be recorded for its remainder.
    const late = try newJob(1, "  ", "https://a.test/s", "", "", now - 600, 3600, now);
    try t.expectEqualStrings("Live TV", late.nameSlice());
}

test "scheduler waits, starts in the window and marks a missed window" {
    const now: i64 = 1_800_000_000;
    var j = sample(now);
    try t.expectEqual(Action.wait, actionAt(&j, now));
    try t.expectEqual(Action.start, actionAt(&j, now + 600));
    try t.expectEqual(Action.start, actionAt(&j, now + 4000));
    try t.expectEqual(Action.mark_missed, actionAt(&j, now + 4200));
    j.status = .recording;
    try t.expectEqual(Action.none, actionAt(&j, now + 700));
}

test "a late start records only the rest of the window" {
    const now: i64 = 1_800_000_000;
    const j = sample(now);
    try t.expectEqual(@as(u32, 3600), recordSeconds(&j, now + 600));
    try t.expectEqual(@as(u32, 600), recordSeconds(&j, now + 3600));
    try t.expectEqual(@as(i64, 3630_000), watchdogMs(3600));
}

test "file name is local, dated and path-safe" {
    var buf: [160]u8 = undefined;
    // 2026-11-27 16:00:00 UTC, viewer at UTC+05:30 → 21:30 local.
    try t.expectEqualStrings("BBC News 2026-11-27 2130.ts", fileName("BBC News", 1_795_795_200, 19_800, &buf));
    try t.expectEqualStrings("a_b_c 2026-11-27 1600.ts", fileName("a/b:c", 1_795_795_200, 0, &buf));
    try t.expectEqualStrings("Live TV 2026-11-27 1600.ts", fileName("../", 1_795_795_200, 0, &buf));
}

test "ffmpeg argv copies the stream for the window and sends channel headers" {
    const now: i64 = 1_800_000_000;
    var j = try newJob(1, "Ch", "https://a.test/s.m3u8", "Mozilla/5.0", "https://site.test/", now, 1800, now);
    var secs: [16]u8 = undefined;
    var hdr: [300]u8 = undefined;
    var argv: [32][]const u8 = undefined;
    const a = ffmpegArgv("ffmpeg", &j, 1800, "/rec/Ch.ts", &secs, &hdr, &argv);
    const joined = try std.mem.join(t.allocator, " ", a);
    defer t.allocator.free(joined);
    try t.expect(std.mem.indexOf(u8, joined, "-nostdin -n") != null); // never prompt or overwrite
    try t.expect(std.mem.indexOf(u8, joined, "-user_agent Mozilla/5.0") != null);
    try t.expect(std.mem.indexOf(u8, joined, "-headers Referer: https://site.test/\r\n") != null);
    try t.expect(std.mem.endsWith(u8, joined, "-i https://a.test/s.m3u8 -t 1800 -map 0 -c copy -f mpegts /rec/Ch.ts"));
    // A referrer with a newline cannot inject extra headers.
    j.referrer_len = 0;
    @memcpy(j.referrer[0..9], "x\r\nEvil:1");
    j.referrer_len = 9;
    const b = ffmpegArgv("ffmpeg", &j, 60, "/rec/Ch.ts", &secs, &hdr, &argv);
    for (b) |arg| try t.expect(!std.mem.eql(u8, arg, "-headers"));
}

test "outcome keeps a cancelled partial recording and fails an empty one" {
    try t.expectEqual(Status.done, outcome(false, true, false, 1000));
    try t.expectEqual(Status.failed, outcome(false, false, false, 1000));
    try t.expectEqual(Status.failed, outcome(false, true, false, 0));
    try t.expectEqual(Status.done, outcome(true, false, false, 1000));
    try t.expectEqual(Status.cancelled, outcome(true, false, false, 0));
    // A stalling stream stopped at the window end keeps its capture.
    try t.expectEqual(Status.done, outcome(false, false, true, 1000));
    try t.expectEqual(Status.failed, outcome(false, false, true, 0));
}

test "job list round-trips; an interrupted recording comes back failed" {
    const now: i64 = 1_800_000_000;
    var j = try newJob(3, "Ch One", "https://a.test/s", "UA", "", now, 600, now);
    j.status = .recording;
    j.out_len = 0;
    @memcpy(j.out[0..8], "/r/a.ts ");
    j.out_len = 7;
    var buf: [2048]u8 = undefined;
    const line = encode(&j, &buf);
    const back = decode(line).?;
    try t.expectEqual(@as(u32, 3), back.id);
    try t.expectEqual(Status.failed, back.status);
    try t.expectEqualStrings("Ch One", back.nameSlice());
    try t.expectEqualStrings("UA", back.userAgentSlice());
    try t.expectEqualStrings("/r/a.ts", back.outSlice());
    try t.expect(decode("garbage") == null);
    try t.expect(decode("1\tscheduled\t0\t600\t/local/file\t\t\t\tx") == null);
}

test "a series schedules its next window and skips ones missed while closed" {
    const now: i64 = 1_800_000_000;
    var j = sample(now); // starts now+600, 1 h
    j.repeat = .daily;
    try t.expect(nextOccurrence(&j, 9, now) == null); // still scheduled: no next yet
    j.status = .done;
    const next = nextOccurrence(&j, 9, now + 700).?;
    try t.expectEqual(@as(i64, now + 600 + 86_400), next.start_s);
    try t.expectEqual(Status.scheduled, next.status);
    try t.expectEqual(@as(u32, 9), next.id);
    try t.expectEqual(@as(usize, 0), next.out_len);
    // Opal closed for three days: the next window is the first one still open.
    const later = nextOccurrence(&j, 10, now + 3 * 86_400 + 5000).?;
    try t.expect(later.start_s + later.duration_s > now + 3 * 86_400 + 5000);
    try t.expectEqual(@as(i64, 0), @mod(later.start_s - j.start_s, 86_400));
    // Cancel ends the series; a one-off never repeats.
    j.status = .cancelled;
    try t.expect(nextOccurrence(&j, 11, now) == null);
    j.status = .done;
    j.repeat = .none;
    try t.expect(nextOccurrence(&j, 11, now) == null);
}

test "repeat survives the job list; lines from before repeats still load" {
    const now: i64 = 1_800_000_000;
    var j = try newJob(4, "Ch", "https://a.test/s", "", "", now, 600, now);
    j.repeat = .weekly;
    var buf: [2048]u8 = undefined;
    try t.expectEqual(Repeat.weekly, decode(encode(&j, &buf)).?.repeat);
    const old = decode("4\tscheduled\t1800000000\t600\thttps://a.test/s\t\t\t\tCh").?;
    try t.expectEqual(Repeat.none, old.repeat);
    try t.expectEqualStrings("https://a.test/s", old.urlSlice());
}

test "recording list JSON parses, escapes names and hides host paths" {
    const now: i64 = 1_800_000_000;
    var a = try newJob(1, "+24 \"News\"", "https://a.test/s", "", "", now, 600, now);
    a.repeat = .daily;
    @memcpy(a.out[0..24], "/Users/me/Rec/+24 x.ts\x00\x00");
    a.out_len = 22;
    const b = try newJob(2, "Two", "https://a.test/t", "", "", now, 600, now);
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeListJson(&w, &.{ a, b }, true);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, buf[0..w.end], .{});
    defer parsed.deinit();
    const list = parsed.value.object.get("recordings").?.array.items;
    try t.expectEqual(@as(usize, 2), list.len);
    try t.expectEqualStrings("+24 \"News\"", list[0].object.get("name").?.string);
    try t.expectEqualStrings("+24 x.ts", list[0].object.get("file").?.string);
    try t.expectEqualStrings("daily", list[0].object.get("repeat").?.string);
    try t.expect(std.mem.indexOf(u8, buf[0..w.end], "/Users/") == null);
}
