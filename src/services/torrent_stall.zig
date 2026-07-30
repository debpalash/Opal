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
//! UI thread only (called from appFrame). Self-throttled to 2 Hz; each sample
//! is three cheap C calls per live torrent.

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

/// Sample every live torrent and act on the pure verdict. Cheap to call every
/// frame — throttled to 2 Hz internally.
pub fn tick() void {
    const now_ms = io_g.milliTimestamp();
    if (now_ms - last_tick_ms < 500) return;
    last_tick_ms = now_ms;

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
                state.showToastTyped("Torrent stalled: no peers found. Try another source.", .warning);
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
