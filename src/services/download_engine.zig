//! Segmented multi-connection HTTP download engine ("IDM-class").
//!
//! Design:
//!   - Fixed slots (no per-download allocation), all shared metadata guarded by
//!     one mutex; hot per-segment progress counters are atomics so segment
//!     threads never contend with the UI snapshot.
//!   - One COORDINATOR thread per active download: probes range support with a
//!     `Range: bytes=0-0` GET (more reliable than HEAD, and it yields the ETag
//!     and total in one round-trip), plans segments via
//!     download_pure.planSegments, preallocates `<dest>.opal-part`, spawns one
//!     worker per segment, then monitors: stall detection (no bytes for 30s →
//!     kick the segment to reconnect), 1Hz sidecar persistence, rolling speed
//!     window. On success the part file is renamed to the real name and the
//!     sidecar removed.
//!   - SEGMENT workers issue `Range` GETs (plus `If-Range` when an ETag is
//!     known) and write at their own offsets with positional writes. Retries
//!     use download_pure.backoffMs (3 attempts, 1s/4s/15s); any received byte
//!     resets the attempt counter.
//!   - Pause/cancel bump a per-slot run token that every worker loop checks;
//!     pause persists the sidecar so resume (same session or after restart via
//!     restoreSidecar) continues from the per-segment offsets. A changed ETag
//!     (If-Range answered with 200) restarts the download from scratch.
//!   - Global token bucket (download_pure.take) shared by ALL segments of ALL
//!     downloads enforces the byte/s limit; a scheduler caps concurrent
//!     downloads and promotes queued ones FIFO.
//!
//! This file deliberately imports NOTHING that drags in dvui/state (only core
//! alloc/io/sync + the pure module), so a headless harness can drive the real
//! engine end-to-end. Logging goes through a settable function pointer that
//! src/services/downloads.zig points at core/logs.pushLog.

const std = @import("std");
const alloc = @import("../core/alloc.zig");
const io_global = @import("../core/io_global.zig");
const sync = @import("../core/sync.zig");
pub const dp = @import("download_pure.zig");

pub const MAX_DOWNLOADS: usize = 16;
pub const URL_LEN: usize = dp.URL_LEN;
pub const PATH_LEN: usize = 1024;
pub const NAME_LEN: usize = 256;
pub const ERR_LEN: usize = 96;

pub const Status = enum(u8) { empty, queued, probing, running, paused, failed, done, canceling };

/// UI-facing statuses that occupy a scheduler slot.
fn isActive(s: Status) bool {
    return s == .probing or s == .running;
}

const Download = struct {
    status: Status = .empty,
    /// Bumped whenever workers must stop (pause/cancel) and when the slot is
    /// re-occupied. Workers capture the value at spawn and stop when it moves.
    run_token: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// FIFO ordering for the queue.
    seq: u64 = 0,

    url: [URL_LEN]u8 = undefined,
    url_len: usize = 0,
    dest: [PATH_LEN]u8 = undefined, // final absolute path
    dest_len: usize = 0,
    name: [NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    etag: [dp.ETAG_LEN]u8 = undefined,
    etag_len: usize = 0,
    err: [ERR_LEN]u8 = undefined,
    err_len: usize = 0,

    total: u64 = 0, // 0 = unknown size (single stream)
    ranges_ok: bool = false,
    seg_count: usize = 1,
    segs: [dp.MAX_SEGMENTS]dp.Segment = @splat(dp.Segment{}),

    // ── hot counters (written by segment threads, read lock-free) ──
    done: [dp.MAX_SEGMENTS]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0)),
    seg_last_ms: [dp.MAX_SEGMENTS]std.atomic.Value(i64) = @splat(std.atomic.Value(i64).init(0)),
    /// Set by the monitor to force a segment to drop its connection and
    /// reconnect (stalled-transfer detection).
    seg_kick: [dp.MAX_SEGMENTS]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    seg_failed: [dp.MAX_SEGMENTS]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    /// A worker saw If-Range answered with 200 → content changed on the server.
    content_changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Coordinator tells sibling workers to wind down early (a segment failed
    /// permanently / content changed) without disturbing the run token.
    soft_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    speed: dp.SpeedWindow = .{},

    fn urlSlice(d: *const Download) []const u8 {
        return d.url[0..d.url_len];
    }
    fn destSlice(d: *const Download) []const u8 {
        return d.dest[0..d.dest_len];
    }
    fn nameSlice(d: *const Download) []const u8 {
        return d.name[0..d.name_len];
    }
    fn doneBytes(d: *const Download) u64 {
        var sum: u64 = 0;
        for (0..d.seg_count) |i| sum += d.done[i].load(.acquire);
        return sum;
    }
};

var slots: [MAX_DOWNLOADS]Download = @splat(Download{});
var mu: sync.Mutex = .{};
var next_seq: u64 = 1;

// ── Config knobs (set by downloads.zig from state/config) ──
pub var cfg_segments: std.atomic.Value(u32) = std.atomic.Value(u32).init(4);
pub var cfg_max_concurrent: std.atomic.Value(u32) = std.atomic.Value(u32).init(3);
pub var cfg_rate_bps: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// ── Global token bucket shared across every segment of every download ──
var bucket: dp.TokenBucket = .{};
var bucket_mu: sync.Mutex = .{};

fn takeTokens(want: u64) u64 {
    bucket_mu.lock();
    defer bucket_mu.unlock();
    bucket.rate = cfg_rate_bps.load(.acquire);
    return dp.take(&bucket, io_global.milliTimestamp(), want);
}

// ── Logging + completion hand-off (UI thread consumes) ──
fn nopLog(level: []const u8, text: []const u8, is_error: bool) void {
    _ = level;
    _ = text;
    _ = is_error;
}
pub var log_fn: *const fn (level: []const u8, text: []const u8, is_error: bool) void = nopLog;

fn logf(level: []const u8, is_error: bool, comptime fmt: []const u8, args: anytype) void {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch fmt;
    log_fn(level, s, is_error);
}

/// Completed names ring — popped by the glue layer on the UI thread (history +
/// toast happen there; state arrays are not thread-safe).
var completed_names: [8][NAME_LEN]u8 = undefined;
var completed_lens: [8]usize = @splat(0);
var completed_head: usize = 0;
var completed_count: usize = 0;

pub fn popCompleted(buf: *[NAME_LEN]u8) ?[]const u8 {
    mu.lock();
    defer mu.unlock();
    if (completed_count == 0) return null;
    const idx = (completed_head + 8 - completed_count) % 8;
    completed_count -= 1;
    const n = completed_lens[idx];
    @memcpy(buf[0..n], completed_names[idx][0..n]);
    return buf[0..n];
}

fn pushCompletedLocked(name: []const u8) void {
    const n = @min(name.len, NAME_LEN);
    @memcpy(completed_names[completed_head][0..n], name[0..n]);
    completed_lens[completed_head] = n;
    completed_head = (completed_head + 1) % 8;
    if (completed_count < 8) completed_count += 1;
}

// ══════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════

/// Queue a download of `url` to the absolute file path `dest`. Returns false
/// when the table is full or the same destination is already tracked.
pub fn start(url: []const u8, dest: []const u8) bool {
    if (url.len == 0 or url.len > URL_LEN or dest.len == 0 or dest.len > PATH_LEN) return false;
    mu.lock();
    var free_idx: ?usize = null;
    for (&slots, 0..) |*d, i| {
        if (d.status == .empty) {
            if (free_idx == null) free_idx = i;
            continue;
        }
        if (std.mem.eql(u8, d.destSlice(), dest) and d.status != .done and d.status != .failed) {
            mu.unlock();
            log_fn("info", "Download already tracked", false);
            return false;
        }
    }
    const idx = free_idx orelse {
        mu.unlock();
        log_fn("warn", "Download table full", true);
        return false;
    };
    claimSlotLocked(idx, url, dest);
    slots[idx].status = .queued;
    mu.unlock();
    schedule();
    return true;
}

fn claimSlotLocked(idx: usize, url: []const u8, dest: []const u8) void {
    const d = &slots[idx];
    _ = d.run_token.fetchAdd(1, .acq_rel);
    d.status = .empty;
    d.seq = next_seq;
    next_seq += 1;
    @memcpy(d.url[0..url.len], url);
    d.url_len = url.len;
    @memcpy(d.dest[0..dest.len], dest);
    d.dest_len = dest.len;
    const base = if (std.mem.lastIndexOfScalar(u8, dest, '/')) |i| dest[i + 1 ..] else dest;
    const nl = @min(base.len, NAME_LEN);
    @memcpy(d.name[0..nl], base[0..nl]);
    d.name_len = nl;
    d.etag_len = 0;
    d.err_len = 0;
    d.total = 0;
    d.ranges_ok = false;
    d.seg_count = 1;
    d.segs = @splat(dp.Segment{});
    for (&d.done) |*a| a.store(0, .release);
    for (&d.seg_kick) |*a| a.store(false, .release);
    for (&d.seg_failed) |*a| a.store(false, .release);
    d.content_changed.store(false, .release);
    d.soft_stop.store(false, .release);
    d.speed.reset();
}

/// Restore a persisted `<dest>.opal-part.json` sidecar (called at startup).
/// Explicitly-paused downloads come back paused; interrupted ones re-queue.
pub fn restoreSidecar(meta: *const dp.PartMeta, dest: []const u8) bool {
    if (dest.len == 0 or dest.len > PATH_LEN) return false;
    mu.lock();
    var free_idx: ?usize = null;
    for (&slots, 0..) |*d, i| {
        if (d.status == .empty and free_idx == null) free_idx = i;
        if (d.status != .empty and std.mem.eql(u8, d.destSlice(), dest)) {
            mu.unlock();
            return false; // already tracked
        }
    }
    const idx = free_idx orelse {
        mu.unlock();
        return false;
    };
    claimSlotLocked(idx, meta.urlSlice(), dest);
    const d = &slots[idx];
    @memcpy(d.etag[0..meta.etag_len], meta.etagSlice());
    d.etag_len = meta.etag_len;
    d.total = meta.total;
    d.seg_count = @min(@max(meta.seg_count, 1), dp.MAX_SEGMENTS);
    if (d.total > 0) {
        var segs: [dp.MAX_SEGMENTS]dp.Segment = undefined;
        const n = dp.planSegments(d.total, d.seg_count, &segs);
        d.seg_count = n;
        d.segs = segs;
        d.ranges_ok = n > 1 or meta.seg_count > 1;
        for (0..n) |i| d.done[i].store(@min(meta.done[i], segs[i].len), .release);
    }
    d.status = if (meta.paused) .paused else .queued;
    mu.unlock();
    schedule();
    return true;
}

/// Pause: stop workers, keep the sidecar + part file for resume.
pub fn pause(idx: usize, token: u32) void {
    mu.lock();
    if (idx >= MAX_DOWNLOADS or slots[idx].run_token.load(.acquire) != token) {
        mu.unlock();
        return;
    }
    const d = &slots[idx];
    if (d.status == .queued) {
        d.status = .paused;
        mu.unlock();
        return;
    }
    if (!isActive(d.status)) {
        mu.unlock();
        return;
    }
    d.status = .paused;
    _ = d.run_token.fetchAdd(1, .acq_rel); // workers stop; coordinator persists
    mu.unlock();
    schedule();
}

/// Resume a paused or failed download (re-queues; scheduler picks it up).
/// `token` is the value the UI snapshot carried — stale actions are ignored.
pub fn resumeDl(idx: usize, token: u32) void {
    mu.lock();
    if (idx >= MAX_DOWNLOADS or slots[idx].run_token.load(.acquire) != token) {
        mu.unlock();
        return;
    }
    const d = &slots[idx];
    if (d.status != .paused and d.status != .failed) {
        mu.unlock();
        return;
    }
    d.status = .queued;
    d.err_len = 0;
    mu.unlock();
    schedule();
}

/// Cancel and forget. Removes the part file + sidecar.
pub fn cancel(idx: usize, token: u32) void {
    mu.lock();
    if (idx >= MAX_DOWNLOADS or slots[idx].run_token.load(.acquire) != token) {
        mu.unlock();
        return;
    }
    const d = &slots[idx];
    const was_active = isActive(d.status);
    _ = d.run_token.fetchAdd(1, .acq_rel);
    var dest_buf: [PATH_LEN]u8 = undefined;
    const dlen = d.dest_len;
    @memcpy(dest_buf[0..dlen], d.dest[0..dlen]);
    // An active coordinator must finish cleanup before the slot can be
    // reused, so park it in .canceling; finishStopped() empties it.
    d.status = if (was_active) .canceling else .empty;
    mu.unlock();

    if (!was_active) removeArtifacts(dest_buf[0..dlen]);
    schedule();
}

fn removeArtifacts(dest: []const u8) void {
    var pb: [PATH_LEN + 32]u8 = undefined;
    if (std.fmt.bufPrint(&pb, "{s}.opal-part", .{dest})) |p| {
        io_global.deleteFileAbsolute(p) catch {};
    } else |_| {}
    if (std.fmt.bufPrint(&pb, "{s}.opal-part.json", .{dest})) |p| {
        io_global.deleteFileAbsolute(p) catch {};
    } else |_| {}
}

/// Clear a finished (done/failed) row from the list. Keeps disk bytes for
/// .done; removes partials for .failed.
pub fn dismiss(idx: usize, token: u32) void {
    mu.lock();
    if (idx >= MAX_DOWNLOADS or slots[idx].run_token.load(.acquire) != token) {
        mu.unlock();
        return;
    }
    const d = &slots[idx];
    if (isActive(d.status) or d.status == .canceling) {
        mu.unlock();
        return;
    }
    const failed = d.status == .failed or d.status == .paused;
    var dest_buf: [PATH_LEN]u8 = undefined;
    const dlen = d.dest_len;
    @memcpy(dest_buf[0..dlen], d.dest[0..dlen]);
    _ = d.run_token.fetchAdd(1, .acq_rel);
    d.status = .empty;
    mu.unlock();
    if (failed) removeArtifacts(dest_buf[0..dlen]);
}

// ── UI snapshot ──

pub const Snap = struct {
    idx: usize = 0,
    token: u32 = 0,
    status: Status = .empty,
    name: [NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    err: [ERR_LEN]u8 = undefined,
    err_len: usize = 0,
    total: u64 = 0,
    done: u64 = 0,
    rate: u64 = 0, // bytes/sec, rolling average
    seg_count: usize = 1,
    seg_frac: [dp.MAX_SEGMENTS]f32 = @splat(0),

    pub fn nameSlice(s: *const Snap) []const u8 {
        return s.name[0..s.name_len];
    }
    pub fn errSlice(s: *const Snap) []const u8 {
        return s.err[0..s.err_len];
    }
    pub fn etaSecs(s: *const Snap) ?u64 {
        if (s.total == 0 or s.done >= s.total) return null;
        return dp.etaSeconds(s.total - s.done, s.rate);
    }
};

/// Copy all live rows out under the mutex (UI renders from this copy). Rows
/// are ordered by queue sequence so the list is stable frame to frame.
pub fn snapshot(out: *[MAX_DOWNLOADS]Snap) usize {
    mu.lock();
    defer mu.unlock();
    var n: usize = 0;
    // Insertion-ordered by seq (small N — simple selection).
    var used: [MAX_DOWNLOADS]bool = @splat(false);
    while (n < MAX_DOWNLOADS) {
        var best: ?usize = null;
        for (&slots, 0..) |*d, i| {
            if (used[i] or d.status == .empty or d.status == .canceling) continue;
            if (best == null or d.seq < slots[best.?].seq) best = i;
        }
        const i = best orelse break;
        used[i] = true;
        const d = &slots[i];
        var s = Snap{
            .idx = i,
            .token = d.run_token.load(.acquire),
            .status = d.status,
            .name_len = d.name_len,
            .err_len = d.err_len,
            .total = d.total,
            .done = d.doneBytes(),
            .rate = d.speed.rate(io_global.milliTimestamp()),
            .seg_count = d.seg_count,
        };
        @memcpy(s.name[0..d.name_len], d.name[0..d.name_len]);
        @memcpy(s.err[0..d.err_len], d.err[0..d.err_len]);
        for (0..d.seg_count) |k| {
            const len = d.segs[k].len;
            s.seg_frac[k] = if (len == 0)
                0
            else
                @min(@as(f32, @floatFromInt(d.done[k].load(.acquire))) / @as(f32, @floatFromInt(len)), 1.0);
        }
        out[n] = s;
        n += 1;
    }
    return n;
}

pub fn activeAndQueued() struct { active: usize, queued: usize, rate: u64 } {
    mu.lock();
    defer mu.unlock();
    var a: usize = 0;
    var q: usize = 0;
    var r: u64 = 0;
    const now = io_global.milliTimestamp();
    for (&slots) |*d| {
        if (isActive(d.status)) {
            a += 1;
            r += d.speed.rate(now);
        } else if (d.status == .queued) q += 1;
    }
    return .{ .active = a, .queued = q, .rate = r };
}

// ══════════════════════════════════════════════════════════
// Scheduler — max N concurrent, FIFO promotion
// ══════════════════════════════════════════════════════════

fn schedule() void {
    while (true) {
        mu.lock();
        var running: usize = 0;
        for (&slots) |*d| {
            if (isActive(d.status)) running += 1;
        }
        const cap = @max(cfg_max_concurrent.load(.acquire), 1);
        if (running >= cap) {
            mu.unlock();
            return;
        }
        // Oldest queued first.
        var pick: ?usize = null;
        for (&slots, 0..) |*d, i| {
            if (d.status != .queued) continue;
            if (pick == null or d.seq < slots[pick.?].seq) pick = i;
        }
        const idx = pick orelse {
            mu.unlock();
            return;
        };
        slots[idx].status = .probing;
        const token = slots[idx].run_token.load(.acquire);
        mu.unlock();

        const t = std.Thread.spawn(.{}, coordinate, .{ idx, token }) catch {
            mu.lock();
            slots[idx].status = .queued;
            mu.unlock();
            return;
        };
        t.detach();
    }
}

// ══════════════════════════════════════════════════════════
// HTTP plumbing
// ══════════════════════════════════════════════════════════

const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

const ProbeResult = struct {
    total: u64 = 0,
    ranges_ok: bool = false,
    etag: [dp.ETAG_LEN]u8 = undefined,
    etag_len: usize = 0,
};

/// Probe with `Range: bytes=0-0`: a 206 proves range support AND carries the
/// full size in Content-Range; a 200 means no ranges (Content-Length = size).
fn probe(url: []const u8) ?ProbeResult {
    var client = std.http.Client{ .allocator = alloc.allocator, .io = io_global.io() };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return null;
    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = UA },
        .{ .name = "Range", .value = "bytes=0-0" },
        .{ .name = "Accept", .value = "*/*" },
    };
    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
        .extra_headers = &headers,
    }) catch return null;
    defer req.deinit();
    req.sendBodiless() catch return null;

    var redirect_buf: [16 * 1024]u8 = undefined;
    const response = req.receiveHead(&redirect_buf) catch return null;

    var out = ProbeResult{};
    switch (response.head.status) {
        .partial_content => {
            out.ranges_ok = true;
            var it = response.head.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "Content-Range")) {
                    if (dp.parseContentRangeTotal(h.value)) |t| out.total = t;
                }
            }
        },
        .ok => {
            out.ranges_ok = false;
            if (response.head.content_length) |cl| out.total = cl;
        },
        else => return null,
    }
    var it2 = response.head.iterateHeaders();
    while (it2.next()) |h| {
        const use = std.ascii.eqlIgnoreCase(h.name, "ETag") or
            (out.etag_len == 0 and std.ascii.eqlIgnoreCase(h.name, "Last-Modified"));
        if (use) {
            const n = @min(h.value.len, dp.ETAG_LEN);
            @memcpy(out.etag[0..n], h.value[0..n]);
            out.etag_len = n;
        }
    }
    return out;
}

// ══════════════════════════════════════════════════════════
// Coordinator
// ══════════════════════════════════════════════════════════

fn alive(d: *Download, token: u32) bool {
    return d.run_token.load(.acquire) == token;
}

/// Workers additionally wind down when the coordinator soft-stops the download
/// (a sibling segment failed for good / content changed).
fn workerAlive(d: *Download, token: u32) bool {
    return alive(d, token) and !d.soft_stop.load(.acquire);
}

fn partPath(dest: []const u8, buf: *[PATH_LEN + 32]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}.opal-part", .{dest}) catch unreachable;
}
fn sidecarPath(dest: []const u8, buf: *[PATH_LEN + 32]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}.opal-part.json", .{dest}) catch unreachable;
}

fn setError(idx: usize, token: u32, msg: []const u8) void {
    mu.lock();
    defer mu.unlock();
    const d = &slots[idx];
    if (d.run_token.load(.acquire) != token) return;
    d.status = .failed;
    const n = @min(msg.len, ERR_LEN);
    @memcpy(d.err[0..n], msg[0..n]);
    d.err_len = n;
}

fn writeSidecar(d: *Download, paused: bool) void {
    var meta = dp.PartMeta{ .total = d.total, .seg_count = d.seg_count, .paused = paused };
    meta.setUrl(d.urlSlice());
    meta.setEtag(d.etag[0..d.etag_len]);
    for (0..d.seg_count) |i| meta.done[i] = d.done[i].load(.acquire);
    var jb: [4096]u8 = undefined;
    const json = dp.writePartMeta(&meta, &jb) orelse return;
    var pb: [PATH_LEN + 32]u8 = undefined;
    const path = sidecarPath(d.destSlice(), &pb);
    const f = io_global.createFileAbsolute(path, .{ .truncate = true }) catch return;
    defer io_global.closeFile(f);
    io_global.writeAll(f, json) catch {};
}

fn coordinate(idx: usize, token: u32) void {
    const d = &slots[idx];

    // ── Probe (unless a restored sidecar already told us the shape) ──
    const pr = probe(d.urlSlice());
    if (pr == null) {
        if (!alive(d, token)) {
            finishStopped(idx, token);
            return;
        }
        setError(idx, token, "Connection failed");
        logf("warn", true, "Download probe failed: {s}", .{d.nameSlice()});
        schedule();
        return;
    }
    const p = pr.?;

    mu.lock();
    if (d.run_token.load(.acquire) != token) {
        mu.unlock();
        finishStopped(idx, token);
        return;
    }
    const had_resume_state = d.total > 0 and d.doneBytes() > 0;
    var resume_valid = had_resume_state;
    if (had_resume_state) {
        // Restart from scratch when the server no longer supports ranges, the
        // size changed, or the validator (etag/last-modified) mismatches.
        if (!p.ranges_ok or p.total != d.total) resume_valid = false;
        if (d.etag_len > 0 and p.etag_len > 0 and
            !std.mem.eql(u8, d.etag[0..d.etag_len], p.etag[0..p.etag_len])) resume_valid = false;
    }
    d.ranges_ok = p.ranges_ok;
    d.total = p.total;
    @memcpy(d.etag[0..p.etag_len], p.etag[0..p.etag_len]);
    d.etag_len = p.etag_len;

    var segs: [dp.MAX_SEGMENTS]dp.Segment = undefined;
    if (resume_valid) {
        // Keep the persisted plan + progress (seg_count already set).
        _ = dp.planSegments(d.total, d.seg_count, &segs);
        d.segs = segs;
    } else {
        const want: usize = if (p.ranges_ok) dp.pickSegmentCount(p.total, cfg_segments.load(.acquire)) else 1;
        d.seg_count = dp.planSegments(d.total, want, &segs);
        d.segs = segs;
        for (&d.done) |*a| a.store(0, .release);
    }
    for (&d.seg_failed) |*a| a.store(false, .release);
    for (&d.seg_kick) |*a| a.store(false, .release);
    d.content_changed.store(false, .release);
    d.speed.reset();
    const now0 = io_global.milliTimestamp();
    for (0..d.seg_count) |i| d.seg_last_ms[i].store(now0, .release);
    d.status = .running;
    const seg_count = d.seg_count;
    mu.unlock();

    logf("info", false, "Downloading {s} ({d} segment{s})", .{
        d.nameSlice(), seg_count, if (seg_count == 1) "" else "s",
    });

    // ── Preallocate the part file ──
    var pb: [PATH_LEN + 32]u8 = undefined;
    const part = partPath(d.destSlice(), &pb);
    {
        const f = io_global.createFileAbsolute(part, .{ .truncate = !resume_valid }) catch {
            setError(idx, token, "Cannot create file");
            schedule();
            return;
        };
        if (d.total > 0) f.setLength(io_global.io(), d.total) catch {};
        io_global.closeFile(f);
    }

    // ── Spawn segment workers ──
    var threads: [dp.MAX_SEGMENTS]?std.Thread = @splat(null);
    for (0..seg_count) |si| {
        threads[si] = std.Thread.spawn(.{}, segmentWorker, .{ idx, token, si }) catch null;
        if (threads[si] == null) d.seg_failed[si].store(true, .release);
    }

    // ── Monitor: stall detection + sidecar persistence + speed samples ──
    var last_sidecar_ms: i64 = 0;
    while (alive(d, token)) {
        io_global.sleep(200 * std.time.ns_per_ms);
        const now = io_global.milliTimestamp();
        const done_now = d.doneBytes();

        mu.lock();
        if (d.run_token.load(.acquire) == token) d.speed.push(now, done_now);
        mu.unlock();

        // Segment finished/failed accounting.
        var all_done = true;
        var any_failed = false;
        for (0..seg_count) |si| {
            const seg_len = d.segs[si].len;
            const seg_done = d.done[si].load(.acquire);
            const finished = seg_len > 0 and seg_done >= seg_len;
            if (d.seg_failed[si].load(.acquire)) {
                any_failed = true;
                continue;
            }
            if (!finished) {
                all_done = false;
                // Stall: no bytes for STALL_MS → kick the worker to reconnect.
                const last = d.seg_last_ms[si].load(.acquire);
                if (now - last > dp.STALL_MS and !d.seg_kick[si].load(.acquire)) {
                    d.seg_kick[si].store(true, .release);
                    logf("warn", false, "Segment {d} stalled — reconnecting ({s})", .{ si, d.nameSlice() });
                }
            }
        }
        // Unknown-size single stream: worker signals completion via seg_failed
        // never and a sentinel: done stops growing after EOF — handled by the
        // worker setting segs[0].len = done on success (under mu).
        if (d.content_changed.load(.acquire) or any_failed) {
            d.soft_stop.store(true, .release); // wind down the other segments
            break;
        }
        if (all_done and d.total > 0) break;
        if (d.total == 0) {
            mu.lock();
            const fin = d.segs[0].len > 0; // worker stamped the final size
            mu.unlock();
            if (fin) break;
        }

        if (now - last_sidecar_ms >= 1000 and d.total > 0) {
            last_sidecar_ms = now;
            writeSidecar(d, false);
        }
    }

    // ── Join workers (token bump or completion ends their loops) ──
    const stopped = !alive(d, token);
    if (stopped) _ = d.run_token.load(.acquire); // workers already told to stop
    for (0..seg_count) |si| {
        if (threads[si]) |t| t.join();
    }

    if (stopped) {
        finishStopped(idx, token);
        return;
    }

    if (d.content_changed.load(.acquire)) {
        // Server content changed under us — restart from scratch.
        mu.lock();
        for (&d.done) |*a| a.store(0, .release);
        d.etag_len = 0;
        if (d.run_token.load(.acquire) == token) d.status = .queued;
        mu.unlock();
        removeArtifacts(d.destSlice());
        logf("warn", true, "Content changed on server — restarting {s}", .{d.nameSlice()});
        schedule();
        return;
    }

    var failed = false;
    for (0..seg_count) |si| {
        if (d.seg_failed[si].load(.acquire)) failed = true;
    }
    const done_total = d.doneBytes();
    if (failed or (d.total > 0 and done_total < d.total)) {
        writeSidecar(d, false); // resumable
        setError(idx, token, "Failed after retries");
        logf("warn", true, "Download failed: {s} ({d}/{d} bytes)", .{ d.nameSlice(), done_total, d.total });
        schedule();
        return;
    }

    // ── Success: part → final name, drop sidecar ──
    var fb: [PATH_LEN + 32]u8 = undefined;
    const spath = sidecarPath(d.destSlice(), &fb);
    io_global.deleteFileAbsolute(spath) catch {};
    var pb2: [PATH_LEN + 32]u8 = undefined;
    const part2 = partPath(d.destSlice(), &pb2);
    io_global.renameAbsolute(part2, d.destSlice()) catch {
        setError(idx, token, "Rename failed");
        schedule();
        return;
    };

    mu.lock();
    if (d.run_token.load(.acquire) == token) {
        d.status = .done;
        pushCompletedLocked(d.nameSlice());
    }
    mu.unlock();
    logf("info", false, "Download complete: {s}", .{d.nameSlice()});
    schedule();
}

/// A pause or cancel interrupted the coordinator. Persist or clean up
/// according to the status the UI action left behind. The slot cannot be
/// reclaimed while .paused/.canceling, so the un-locked reads are stable.
fn finishStopped(idx: usize, token: u32) void {
    _ = token;
    const d = &slots[idx];
    mu.lock();
    const st = d.status;
    mu.unlock();
    if (st == .paused) {
        if (d.total > 0) writeSidecar(d, true);
        logf("info", false, "Paused: {s}", .{d.nameSlice()});
    } else if (st == .canceling) {
        removeArtifacts(d.destSlice());
        mu.lock();
        d.status = .empty;
        mu.unlock();
    }
    schedule();
}

// ══════════════════════════════════════════════════════════
// Segment worker
// ══════════════════════════════════════════════════════════

const BUF_LEN: usize = 64 * 1024;

fn segmentWorker(idx: usize, token: u32, si: usize) void {
    const d = &slots[idx];
    // Heap buffer — never put >64KB on a spawned thread's stack.
    const buf = alloc.allocator.alloc(u8, BUF_LEN) catch {
        d.seg_failed[si].store(true, .release);
        return;
    };
    defer alloc.allocator.free(buf);

    var pb: [PATH_LEN + 32]u8 = undefined;
    const part = partPath(d.destSlice(), &pb);
    const file = io_global.openFileAbsolute(part, .{ .mode = .write_only }) catch {
        d.seg_failed[si].store(true, .release);
        return;
    };
    defer io_global.closeFile(file);

    var client = std.http.Client{ .allocator = alloc.allocator, .io = io_global.io() };
    defer client.deinit();

    const seg = d.segs[si];
    const ranged = d.ranges_ok and d.total > 0;
    var attempts: u32 = 0;

    attempt_loop: while (workerAlive(d, token)) {
        const done0 = d.done[si].load(.acquire);
        if (seg.len > 0 and done0 >= seg.len) return; // segment complete

        // ── Connect ──
        const uri = std.Uri.parse(d.urlSlice()) catch {
            d.seg_failed[si].store(true, .release);
            return;
        };
        var range_buf: [96]u8 = undefined;
        var headers_buf: [4]std.http.Header = undefined;
        var hn: usize = 0;
        headers_buf[hn] = .{ .name = "User-Agent", .value = UA };
        hn += 1;
        headers_buf[hn] = .{ .name = "Accept", .value = "*/*" };
        hn += 1;
        if (ranged) {
            const range_start = seg.offset + done0;
            const range_end = seg.offset + seg.len - 1;
            headers_buf[hn] = .{
                .name = "Range",
                .value = std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ range_start, range_end }) catch unreachable,
            };
            hn += 1;
            if (d.etag_len > 0) {
                headers_buf[hn] = .{ .name = "If-Range", .value = d.etag[0..d.etag_len] };
                hn += 1;
            }
        }

        var req = client.request(.GET, uri, .{
            .redirect_behavior = @enumFromInt(5),
            .extra_headers = headers_buf[0..hn],
        }) catch {
            if (!retryWait(d, token, si, &attempts)) return;
            continue :attempt_loop;
        };
        defer req.deinit();
        req.sendBodiless() catch {
            if (!retryWait(d, token, si, &attempts)) return;
            continue :attempt_loop;
        };
        var redirect_buf: [16 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch {
            if (!retryWait(d, token, si, &attempts)) return;
            continue :attempt_loop;
        };

        const status = response.head.status;
        if (ranged and status == .ok) {
            // Server answered a Range request with the FULL body: either
            // If-Range said the content changed, or ranges silently broke.
            d.content_changed.store(true, .release);
            return;
        }
        if (status != .ok and status != .partial_content) {
            if (!retryWait(d, token, si, &attempts)) return;
            continue :attempt_loop;
        }

        // ── Stream body → positional writes at our own offset ──
        var transfer_buf: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        d.seg_kick[si].store(false, .release);

        while (workerAlive(d, token)) {
            const done = d.done[si].load(.acquire);
            const remaining: u64 = if (seg.len > 0) seg.len - done else BUF_LEN;
            if (seg.len > 0 and remaining == 0) return;
            if (d.seg_kick[si].load(.acquire)) {
                // Stalled — drop this connection and reconnect immediately.
                d.seg_kick[si].store(false, .release);
                continue :attempt_loop;
            }

            // Global speed limit: ask the shared bucket for a quota first.
            var want: usize = @intCast(@min(remaining, BUF_LEN));
            const granted = takeTokens(want);
            if (granted == 0) {
                io_global.sleep(25 * std.time.ns_per_ms);
                continue;
            }
            want = @intCast(@min(granted, want));

            const n = reader.readSliceShort(buf[0..want]) catch {
                if (!retryWait(d, token, si, &attempts)) return;
                continue :attempt_loop;
            };
            if (n == 0) {
                // EOF.
                if (seg.len == 0) {
                    // Unknown-size single stream finished: stamp the final size
                    // so the coordinator knows we are done.
                    mu.lock();
                    if (d.run_token.load(.acquire) == token) {
                        d.segs[si].len = @max(done, 1);
                        d.total = done;
                    }
                    mu.unlock();
                    return;
                }
                // Short body — server closed early; retry the remainder.
                if (!retryWait(d, token, si, &attempts)) return;
                continue :attempt_loop;
            }

            file.writePositionalAll(io_global.io(), buf[0..n], seg.offset + done) catch {
                d.seg_failed[si].store(true, .release);
                return;
            };
            d.done[si].store(done + n, .release);
            d.seg_last_ms[si].store(io_global.milliTimestamp(), .release);
            attempts = 0; // progress resets the retry budget
        }
        return; // token moved — pause/cancel
    }
}

/// Sleep out the backoff for this attempt (checking for pause/cancel every
/// 100ms). Returns false when the retry budget is exhausted or we were
/// stopped — the segment then reports failure/stops.
fn retryWait(d: *Download, token: u32, si: usize, attempts: *u32) bool {
    if (!workerAlive(d, token)) return false;
    if (attempts.* >= dp.MAX_RETRIES) {
        d.seg_failed[si].store(true, .release);
        return false;
    }
    const wait_ms = dp.backoffMs(attempts.*);
    attempts.* += 1;
    var waited: u64 = 0;
    while (waited < wait_ms) : (waited += 100) {
        if (!workerAlive(d, token)) return false;
        io_global.sleep(100 * std.time.ns_per_ms);
    }
    return workerAlive(d, token);
}
