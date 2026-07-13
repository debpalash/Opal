//! The readiness gate: decides WHEN a still-downloading torrent may be handed to
//! mpv, and steers libtorrent at the bytes that decision depends on.
//!
//! The bug this exists to kill: playback was started as soon as ONE piece existed,
//! on the theory that "the proxy blocks, so mpv will just buffer". It doesn't work
//! that way. mpv's Matroska demuxer seeks to the END of the file during open, to
//! read the Cues and the Tags — so it blocked inside demux_mkv_open(), before
//! creating a single track, waiting for bytes that were never prioritized. The
//! picture stayed black at 00:00 while the torrent happily downloaded the middle
//! of the file. Head progress was irrelevant; it never got past that seek.
//!
//! So: work out what the demuxer will actually read (see container_pure.zig — the
//! answer differs per container), pin exactly those byte ranges at top priority
//! with immediate deadlines, and refuse to call loadfile until they are all
//! present. Two phases, because the tail's location is recorded in the head:
//!
//!   1. Pin a head probe + a conservative tail guess.
//!   2. Once the probe lands, parse the container's own index pointer out of it,
//!      and re-pin the EXACT tail. (For a faststart MP4 that tail turns out to be
//!      nothing at all, and we stop asking for it.)
//!
//! State is keyed by torrent id, not held on MediaPlayer, so the player struct
//! stays untouched.

const std = @import("std");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const cp = @import("container_pure.zig");

pub const MAX_GATES = 16;

const Gate = struct {
    torrent_id: i32 = -1,
    file_idx: i32 = -1,
    active: bool = false,

    plan: cp.Plan = .{},
    planned: bool = false,
    refined: bool = false,
    ready: bool = false,

    /// Percent of the required bytes present (0-100). Drives the buffering bar.
    progress: u8 = 0,
};

var gates: [MAX_GATES]Gate = std.mem.zeroes([MAX_GATES]Gate);

fn gateFor(torrent_id: i32, file_idx: i32) ?*Gate {
    for (&gates) |*g| {
        if (g.active and g.torrent_id == torrent_id and g.file_idx == file_idx) return g;
    }
    for (&gates) |*g| {
        if (!g.active) {
            g.* = .{ .torrent_id = torrent_id, .file_idx = file_idx, .active = true };
            return g;
        }
    }
    return null; // table full — caller degrades to "ready" rather than deadlocking
}

/// Forget a torrent's gate (on remove, or when switching files within a torrent).
pub fn reset(torrent_id: i32) void {
    for (&gates) |*g| {
        if (g.torrent_id == torrent_id) g.* = .{};
    }
}

/// Buffering progress (0-100) for the UI. 0 when we know nothing yet.
pub fn bufferPercent(torrent_id: i32, file_idx: i32) u8 {
    for (&gates) |*g| {
        if (g.active and g.torrent_id == torrent_id and g.file_idx == file_idx) return g.progress;
    }
    return 0;
}

/// True once the gate has a plan and can say something meaningful about it.
pub fn hasPlan(torrent_id: i32, file_idx: i32) bool {
    for (&gates) |*g| {
        if (g.active and g.torrent_id == torrent_id and g.file_idx == file_idx) return g.planned;
    }
    return false;
}

fn pin(torrent_id: i32, file_idx: i32, off: u64, len: u64) void {
    if (len == 0) return;
    c.mpv.torrent_prioritize_range(
        state.torrentSession(),
        torrent_id,
        file_idx,
        @intCast(off),
        @intCast(len),
        0, // deadline 0 = "already due" = maximum urgency
    );
}

fn rangeReady(torrent_id: i32, file_idx: i32, off: u64, len: u64) bool {
    if (len == 0) return true;
    return c.mpv.torrent_range_ready(
        state.torrentSession(),
        torrent_id,
        file_idx,
        @intCast(off),
        @intCast(len),
    ) != 0;
}

fn rangeProgress(torrent_id: i32, file_idx: i32, off: u64, len: u64) u32 {
    if (len == 0) return 100;
    const v = c.mpv.torrent_range_progress(
        state.torrentSession(),
        torrent_id,
        file_idx,
        @intCast(off),
        @intCast(len),
    );
    return @intCast(@max(0, @min(100, v)));
}

/// Is this file ready to hand to mpv?
///
/// Call once per frame from the UI thread while waiting to start. Cheap: piece
/// lookups only. Never blocks — the one call that can block (`torrent_read_bytes`)
/// is issued ONLY after its range is confirmed present, so it returns immediately.
pub fn isReady(torrent_id: i32, file_idx: i32, file_name: []const u8, file_size: u64) bool {
    if (torrent_id < 0 or file_idx < 0) return false;
    // No metadata yet — nothing to plan against. Don't claim ready.
    if (file_size == 0) return false;

    const g = gateFor(torrent_id, file_idx) orelse return true; // degrade open, never deadlock
    if (g.ready) return true;

    // ── Phase 1: plan + pin ──
    if (!g.planned) {
        const fmt = cp.formatOf(file_name);
        g.plan = cp.initialPlan(fmt, file_size);
        g.planned = true;

        // Probe first, so the exact tail can be computed before we spend bandwidth
        // on a guessed one.
        pin(torrent_id, file_idx, 0, @min(cp.PROBE_BYTES, file_size));
        pin(torrent_id, file_idx, 0, g.plan.head_end);
        pin(torrent_id, file_idx, g.plan.tail_start, g.plan.tailLen());

        var lb: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&lb, "stream: {s} {d}MB - head {d}MB + tail {d}MB ({s})", .{
            @tagName(fmt),
            file_size / (1 << 20),
            g.plan.head_end / (1 << 20),
            g.plan.tailLen() / (1 << 20),
            if (g.plan.needsTail()) "index at EOF" else "no tail needed",
        }) catch "stream: planned";
        logs.pushLog("info", "stream", msg, false);
    }

    // ── Phase 2: refine the tail from the container's own index ──
    //
    // Only once the probe is actually present — torrent_read_bytes BLOCKS until
    // its pieces arrive, and this runs on the UI thread, so calling it early would
    // freeze the whole app.
    if (!g.refined and g.plan.needsTail()) {
        const probe_len = @min(cp.PROBE_BYTES, file_size);
        if (rangeReady(torrent_id, file_idx, 0, probe_len)) {
            var probe: [cp.PROBE_BYTES]u8 = undefined;
            const n = c.mpv.torrent_read_bytes(
                state.torrentSession(),
                torrent_id,
                file_idx,
                0,
                &probe,
                @intCast(probe_len),
            );
            if (n > 0) {
                const before = g.plan;
                g.plan = cp.refine(g.plan, probe[0..@intCast(n)]);
                g.refined = true;

                if (g.plan.tail_start != before.tail_start) {
                    // Stop paying for the guessed tail; pin the real one.
                    pin(torrent_id, file_idx, g.plan.tail_start, g.plan.tailLen());

                    var lb: [160]u8 = undefined;
                    const msg = std.fmt.bufPrint(&lb, "stream: exact index at {d}MB - tail now {d}MB (was {d}MB guess)", .{
                        g.plan.tail_start / (1 << 20),
                        g.plan.tailLen() / (1 << 20),
                        before.tailLen() / (1 << 20),
                    }) catch "stream: refined";
                    logs.pushLog("info", "stream", msg, false);
                }
            } else {
                // Probe unreadable — keep the conservative guess rather than
                // spin on it every frame.
                g.refined = true;
            }
        }
    }

    // ── Readiness: the SMALLEST wait that still works ──
    //
    // The gate deliberately does NOT wait for the whole head window, and does NOT
    // wait for the tail. It waits only for enough bytes for the demuxer to start
    // reading at all — a couple of seconds' worth — and hands over.
    //
    // That is safe now, and it was not before. The original black screen came from
    // two things that are both fixed: the tail (the container index at EOF) was
    // never prioritized, so the demuxer's tail seek waited on bytes nobody had
    // asked for; and the proxy TRUNCATED the body after 30s, which ffmpeg reads as
    // end-of-file, killing the demuxer for good. Now the tail is pinned at top
    // priority the moment we plan, and the proxy blocks instead of truncating. So
    // mpv can start immediately, hit its tail seek, and block for the second or so
    // it takes the (already-racing) index to land — with its own buffering UI, not
    // a black screen forever.
    //
    // Waiting for the full 16 MB head + tail was correct but needlessly slow: it
    // was the reason a torrent pulling 8 MB/s still showed "Buffering 87%".
    const head_len = @min(g.plan.head_end, file_size);
    const start_len = @min(cp.START_BYTES, file_size);

    const start_pct = rangeProgress(torrent_id, file_idx, 0, start_len);
    g.progress = @intCast(@min(100, start_pct));

    if (rangeReady(torrent_id, file_idx, 0, start_len)) {
        g.ready = true;
        g.progress = 100;

        // Keep the rest of the head and the index racing in the background: the
        // demuxer is about to ask for the index, and playback is about to ask for
        // the head.
        pin(torrent_id, file_idx, 0, head_len);
        pin(torrent_id, file_idx, g.plan.tail_start, g.plan.tailLen());

        logs.pushLog("info", "stream", "stream: enough to start - handing to player (index still racing)", false);
        return true;
    }
    return false;
}
