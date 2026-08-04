//! Stall watchdog — detect a wedged torrent and force a tracker reannounce.
//!
//! `grep -rn reannounce src/` used to return nothing: Opal could neither detect
//! nor recover from a stalled torrent. That matters more here than in a plain
//! downloader — a stalled download is an inconvenience, a stalled stream is a
//! frozen film — and it is exactly what Cleanuparr / decluttarr exist to do for
//! the *arr stack.
//!
//! This module is only the sampler + executor. Every threshold, the backoff
//! curve and the give-up rule live in `torrent_stall_pure.zig` so the shipped
//! policy IS the tested policy.
//!
//! Runs on its OWN thread, not the UI thread.
//!
//! It used to be called from appFrame, which is only reached when dvui draws a
//! frame — and dvui idles when the window has no events. Measured 2026-08-01: a
//! torrent pinned at 0 bytes with 0 peers for over two minutes, far past the 20s
//! threshold, produced no reannounce at all while the window sat in the
//! background. A watchdog whose entire job is rescuing a wedged download cannot
//! be gated on the user looking at the window.
//!
//! Self-throttled to 2 Hz; each sample is three cheap C calls per live torrent.

const std = @import("std");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_g = @import("../core/io_global.zig");
const pure = @import("torrent_stall_pure.zig");

/// Watch slots. Torrent ids are monotonic and never reused, so the table is
/// keyed by id with a free-slot scan; 32 concurrent torrents is far beyond what
/// a streaming session ever has open.
const MAX_WATCH = 32;

var ids: [MAX_WATCH]i32 = [_]i32{-1} ** MAX_WATCH;
var watches: [MAX_WATCH]pure.Watch = [_]pure.Watch{.{}} ** MAX_WATCH;

const TH = pure.Thresholds{};

var last_tick_ms: i64 = 0;

/// Find (or claim) the watch slot for `id`. Returns null when the table is full
/// — a full table simply means that torrent is not watched, never a crash.
fn slotFor(id: i32) ?*pure.Watch {
    var free: ?usize = null;
    for (ids, 0..) |sid, i| {
        if (sid == id) return &watches[i];
        if (sid == -1 and free == null) free = i;
    }
    const k = free orelse return null;
    ids[k] = id;
    watches[k].reset();
    return &watches[k];
}

// ── Toast hand-off (watchdog thread → UI thread) ─────────────────────────────
//
// The watchdog runs off-thread now, and state.showToastTyped writes the shared
// toast buffer with no lock. Queue here, drain on the UI thread.
var toast_lock: @import("../core/sync.zig").Mutex = .{};
var toast_buf: [128]u8 = std.mem.zeroes([128]u8);
var toast_len: usize = 0;
var toast_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn queueToast(msg: []const u8) void {
    toast_lock.lock();
    defer toast_lock.unlock();
    const n = @min(msg.len, toast_buf.len);
    @memcpy(toast_buf[0..n], msg[0..n]);
    toast_len = n;
    toast_pending.store(true, .release);
}

/// UI-thread only: show any toast the watchdog queued. Cheap no-op when idle.
pub fn drainToast() void {
    if (!toast_pending.load(.acquire)) return;
    toast_lock.lock();
    var msg: [128]u8 = undefined;
    const n = toast_len;
    @memcpy(msg[0..n], toast_buf[0..n]);
    toast_pending.store(false, .release);
    toast_lock.unlock();
    state.showToastTyped(msg[0..n], .warning);
}

var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var thread: ?std.Thread = null;

/// Start the watchdog thread. Idempotent — safe to call from init more than once.
pub fn start() void {
    if (running.swap(true, .acq_rel)) return;
    thread = std.Thread.spawn(.{}, loop, .{}) catch {
        running.store(false, .release);
        return;
    };
}

/// Stop and join. Called at shutdown so the thread cannot outlive the session.
pub fn stop() void {
    if (!running.swap(false, .acq_rel)) return;
    if (thread) |t| {
        t.join();
        thread = null;
    }
}

fn loop() void {
    logs.pushLog("info", "torrent", "Stall watchdog running (own thread, 2 Hz)", false);
    // 250ms slices rather than one long sleep: stop() must not wait half a
    // second per shutdown, and tick() throttles itself to 2 Hz anyway.
    while (running.load(.acquire)) {
        tick();
        io_g.sleep(250 * std.time.ns_per_ms);
    }
}

/// Sample every live torrent and act on the pure verdict. Throttled to 2 Hz.
pub fn tick() void {
    const now_ms = io_g.milliTimestamp();
    if (now_ms - last_tick_ms < 500) return;
    last_tick_ms = now_ms;

    // Drive the torrent → mpv handoff. It runs on the UI thread, on rendered
    // frames only, and the dvui loop sleeps when idle — so a torrent left alone
    // finished downloading without ever starting to play. This thread is already
    // awake at 2 Hz watching the same torrents, so it is the natural place to ask
    // for the frames. Scoped to the waiting window (see awaitingHandoff) rather
    // than "any live torrent", so background downloads still let the UI sleep.
    if (state.torrent_handoff_pending.load(.acquire)) state.wakeUi();

    const ses = state.torrentSession() orelse return;
    const now_s = io_g.timestamp();

    // Retire slots whose torrent has been removed (ids are never reused, so a
    // dead id can be dropped for good).
    for (ids, 0..) |sid, i| {
        if (sid < 0) continue;
        if (c.mpv.torrent_is_alive(ses, sid) == 0) {
            ids[i] = -1;
            watches[i].reset();
        }
    }

    const total = c.mpv.torrent_count(ses);
    var i: i32 = 0;
    while (i < total) : (i += 1) {
        if (c.mpv.torrent_is_alive(ses, i) == 0) continue;

        const w = slotFor(i) orelse continue;

        const done = c.mpv.torrent_get_downloaded(ses, i);
        const size = c.mpv.torrent_get_total_size(ses, i);
        const peers = c.mpv.torrent_get_num_peers(ses, i);

        const s = pure.Sample{
            .now_s = now_s,
            .downloaded = if (done > 0) @intCast(done) else 0,
            .total = if (size > 0) @intCast(size) else 0,
            .peers = if (peers > 0) @intCast(peers) else 0,
            .paused = c.mpv.torrent_is_paused(ses, i) != 0,
        };

        switch (pure.evaluate(w, s, TH)) {
            .none => {},
            .reannounce => {
                c.mpv.torrent_force_reannounce(ses, i);
                report(ses, i, "Torrent stalled - reannouncing to trackers", .{ .attempt = w.attempts });
            },
            .give_up => {
                report(ses, i, "Torrent stalled - no peers after repeated reannounces", .{});
                // Queued, not shown directly: showToastTyped writes app.toast_*
                // with no lock, and this is no longer the UI thread. drainToast()
                // below hands it over on the next frame.
                queueToast("Torrent stalled: no peers found. Try another source.");
            },
        }
    }
}

/// One log line naming the torrent, so a stall is visible in the Logs tab
/// instead of being a silent freeze.
fn report(ses: c.mpv.TorrentSession, id: i32, what: []const u8, extra: struct { attempt: ?u8 = null }) void {
    var nbuf: [128]u8 = undefined;
    nbuf[0] = 0;
    c.mpv.torrent_get_name(ses, id, &nbuf, nbuf.len);
    const nlen = std.mem.indexOfScalar(u8, &nbuf, 0) orelse nbuf.len;
    const name = @import("../core/text.zig").safeUtf8(nbuf[0..@min(nlen, 60)]);

    var msg: [256]u8 = undefined;
    const txt = if (extra.attempt) |a|
        std.fmt.bufPrint(&msg, "{s} (attempt {d}/{d}): {s}", .{ what, a, TH.max_attempts, name }) catch what
    else
        std.fmt.bufPrint(&msg, "{s}: {s}", .{ what, name }) catch what;

    logs.pushLog("warn", "torrent", txt, false);
}
