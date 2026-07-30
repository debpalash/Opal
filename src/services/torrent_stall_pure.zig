//! Pure stall-detection / reannounce policy.
//!
//! A stalled DOWNLOAD is an inconvenience; a stalled STREAM is a frozen film.
//! libtorrent has had `force_reannounce()` forever and Opal called it never —
//! so a torrent whose tracker announce landed badly (or whose peers all left)
//! sat at 0 B/s until the user gave up, with nothing on screen explaining why.
//!
//! The *decision* lives here, not in the C++ wrapper and not in a UI callback,
//! because it is the only part with interesting behaviour: when is a torrent
//! stalled, how long to wait before poking the tracker again, how fast to back
//! off, and when to stop and tell the user instead of hammering trackers
//! forever. `torrent_stall.zig` only samples libtorrent and executes the verdict.
//!
//! Reannounce is NOT free — it is a request to every tracker in the list, and
//! trackers ban clients that ignore their min interval. Hence: a minimum
//! interval, exponential backoff, and a hard attempt cap.

const std = @import("std");

pub const Thresholds = struct {
    /// No new bytes for this long before we call it a stall. Short enough that
    /// a buffering viewer is not left staring, long enough that a slow piece
    /// under way is not mistaken for a dead swarm.
    stall_secs: i64 = 20,
    /// "Low peers". At or above this, the swarm is fine and more announces will
    /// not help — the stall is a piece-picking or bandwidth problem instead.
    peer_floor: u32 = 3,
    /// Never reannounce more often than this, no matter what.
    min_interval_secs: i64 = 30,
    /// Doubling per attempt: 30s, 60s, 120s, 240s, ... capped below.
    max_interval_secs: i64 = 300,
    /// After this many reannounces with nothing to show, stop and surface it.
    max_attempts: u8 = 5,
};

pub const Action = enum {
    /// Nothing to do.
    none,
    /// Poke the trackers (and the DHT) now.
    reannounce,
    /// Out of attempts — tell the user once and stop.
    give_up,
};

/// One live sample of a torrent, taken from the wrapper.
pub const Sample = struct {
    now_s: i64,
    /// Bytes verified so far. BYTES, not the float progress: on a 20 GB torrent
    /// a float 0..1 barely moves for a whole piece, which reads as a stall.
    downloaded: u64,
    /// Total bytes, or 0 while metadata is still being fetched.
    total: u64,
    peers: u32,
    paused: bool,
};

/// Per-torrent watchdog state. Fixed size, no allocation — one of these per
/// tracked torrent id lives in a flat array in torrent_stall.zig.
pub const Watch = struct {
    /// Bytes at the last observed *change*. `null`-equivalent sentinel is
    /// `started == false`, so 0 downloaded bytes is a legitimate value.
    last_downloaded: u64 = 0,
    /// When `last_downloaded` was last seen to change (or when we started).
    last_change_s: i64 = 0,
    /// When we last issued a reannounce for this torrent.
    last_announce_s: i64 = 0,
    attempts: u8 = 0,
    started: bool = false,
    /// Set once `give_up` has been reported, so it is reported exactly once.
    gave_up: bool = false,

    pub fn reset(self: *Watch) void {
        self.* = .{};
    }
};

/// Required wait before attempt number `attempts` (0-based): min_interval
/// doubled per previous attempt, clamped to max_interval. Saturating — a large
/// attempt count must not shift-overflow into a tiny interval.
pub fn backoffSecs(th: Thresholds, attempts: u8) i64 {
    if (attempts >= 24) return th.max_interval_secs;
    const mult: i64 = @as(i64, 1) << @intCast(attempts);
    const v = th.min_interval_secs *| mult;
    return @min(v, th.max_interval_secs);
}

/// Advance the watchdog by one sample and say what to do.
///
/// Ordering matters and is deliberate:
///   1. paused / complete       → not a stall, and reset the attempt budget
///   2. bytes moved             → healthy, reset the attempt budget
///   3. not stalled long enough → wait
///   4. swarm is healthy        → a reannounce would not help
///   5. attempt budget spent    → give_up (once)
///   6. min interval / backoff  → wait
///   otherwise                  → reannounce
pub fn evaluate(w: *Watch, s: Sample, th: Thresholds) Action {
    if (!w.started) {
        w.started = true;
        w.last_downloaded = s.downloaded;
        w.last_change_s = s.now_s;
        return .none;
    }

    // A clock that went backwards (suspend/resume, NTP step) would otherwise
    // freeze `last_change_s` in the future and stall detection with it.
    if (s.now_s < w.last_change_s) {
        w.last_change_s = s.now_s;
        w.last_announce_s = @min(w.last_announce_s, s.now_s);
    }

    const complete = s.total > 0 and s.downloaded >= s.total;
    if (s.paused or complete) {
        w.last_downloaded = s.downloaded;
        w.last_change_s = s.now_s;
        w.attempts = 0;
        w.gave_up = false;
        return .none;
    }

    if (s.downloaded != w.last_downloaded) {
        w.last_downloaded = s.downloaded;
        w.last_change_s = s.now_s;
        // Progress means the last poke worked (or none was needed) — hand the
        // full attempt budget back, so a torrent that stalls again later is not
        // punished for an earlier stall.
        w.attempts = 0;
        w.gave_up = false;
        return .none;
    }

    if (s.now_s - w.last_change_s < th.stall_secs) return .none;

    // Plenty of peers but no bytes is not a tracker problem. Announcing again
    // would just add load and cannot produce peers we already have.
    if (s.peers >= th.peer_floor) return .none;

    if (w.attempts >= th.max_attempts) {
        if (w.gave_up) return .none;
        w.gave_up = true;
        return .give_up;
    }

    const wait = backoffSecs(th, w.attempts);
    if (w.last_announce_s != 0 and s.now_s - w.last_announce_s < wait) return .none;

    w.last_announce_s = s.now_s;
    w.attempts += 1;
    return .reannounce;
}

// ══════════════════════════════════════════════════════════
// TESTS
// ══════════════════════════════════════════════════════════

const T = Thresholds{};

fn sample(now: i64, done: u64, peers: u32) Sample {
    return .{ .now_s = now, .downloaded = done, .total = 1_000_000, .peers = peers, .paused = false };
}

test "first sample only primes the watchdog" {
    var w = Watch{};
    try std.testing.expectEqual(Action.none, evaluate(&w, sample(100, 0, 0), T));
    try std.testing.expect(w.started);
    try std.testing.expectEqual(@as(i64, 100), w.last_change_s);
}

test "steady progress never reannounces" {
    var w = Watch{};
    var t: i64 = 0;
    var done: u64 = 0;
    while (t < 600) : (t += 2) {
        done += 4096;
        try std.testing.expectEqual(Action.none, evaluate(&w, sample(t, done, 1), T));
    }
    try std.testing.expectEqual(@as(u8, 0), w.attempts);
}

test "no bytes + no peers for stall_secs triggers exactly one reannounce" {
    var w = Watch{};
    _ = evaluate(&w, sample(0, 500, 0), T);
    // Still inside the stall window.
    try std.testing.expectEqual(Action.none, evaluate(&w, sample(19, 500, 0), T));
    try std.testing.expectEqual(Action.reannounce, evaluate(&w, sample(20, 500, 0), T));
    try std.testing.expectEqual(@as(u8, 1), w.attempts);
    // Immediately after: min interval not elapsed.
    try std.testing.expectEqual(Action.none, evaluate(&w, sample(21, 500, 0), T));
    try std.testing.expectEqual(Action.none, evaluate(&w, sample(49, 500, 0), T));
}

test "a healthy swarm is never reannounced, however long it stalls" {
    var w = Watch{};
    _ = evaluate(&w, sample(0, 500, 8), T);
    var t: i64 = 10;
    while (t < 3600) : (t += 10) {
        try std.testing.expectEqual(Action.none, evaluate(&w, sample(t, 500, 8), T));
    }
    try std.testing.expectEqual(@as(u8, 0), w.attempts);
}

test "paused and complete torrents are not stalls" {
    var w = Watch{};
    _ = evaluate(&w, sample(0, 500, 0), T);
    var s = sample(1000, 500, 0);
    s.paused = true;
    try std.testing.expectEqual(Action.none, evaluate(&w, s, T));

    var w2 = Watch{};
    _ = evaluate(&w2, sample(0, 1_000_000, 0), T);
    try std.testing.expectEqual(Action.none, evaluate(&w2, sample(1000, 1_000_000, 0), T));
}

test "pre-metadata (total == 0) still counts as stallable" {
    // A magnet stuck fetching metadata is the worst stall of all — nothing on
    // screen at all. total == 0 must not read as 'complete'.
    var w = Watch{};
    var s0 = sample(0, 0, 0);
    s0.total = 0;
    _ = evaluate(&w, s0, T);
    var s1 = sample(25, 0, 0);
    s1.total = 0;
    try std.testing.expectEqual(Action.reannounce, evaluate(&w, s1, T));
}

test "backoff doubles and clamps" {
    try std.testing.expectEqual(@as(i64, 30), backoffSecs(T, 0));
    try std.testing.expectEqual(@as(i64, 60), backoffSecs(T, 1));
    try std.testing.expectEqual(@as(i64, 120), backoffSecs(T, 2));
    try std.testing.expectEqual(@as(i64, 240), backoffSecs(T, 3));
    try std.testing.expectEqual(@as(i64, 300), backoffSecs(T, 4)); // clamped
    try std.testing.expectEqual(@as(i64, 300), backoffSecs(T, 200)); // no shift overflow
}

test "reannounce respects backoff, then gives up exactly once" {
    var w = Watch{};
    _ = evaluate(&w, sample(0, 500, 0), T);

    var t: i64 = 0;
    var reannounces: usize = 0;
    var give_ups: usize = 0;
    while (t <= 4000) : (t += 1) {
        switch (evaluate(&w, sample(t, 500, 0), T)) {
            .reannounce => reannounces += 1,
            .give_up => give_ups += 1,
            .none => {},
        }
    }
    try std.testing.expectEqual(@as(usize, T.max_attempts), reannounces);
    try std.testing.expectEqual(@as(usize, 1), give_ups);
}

test "a reannounce that works hands the whole budget back" {
    var w = Watch{};
    _ = evaluate(&w, sample(0, 500, 0), T);
    try std.testing.expectEqual(Action.reannounce, evaluate(&w, sample(20, 500, 0), T));
    // Peers arrived, bytes moved.
    try std.testing.expectEqual(Action.none, evaluate(&w, sample(25, 900, 5), T));
    try std.testing.expectEqual(@as(u8, 0), w.attempts);
    // A LATER stall gets the full budget again, starting at the min interval.
    try std.testing.expectEqual(Action.reannounce, evaluate(&w, sample(60, 900, 0), T));
}

test "clock going backwards does not wedge detection" {
    var w = Watch{};
    _ = evaluate(&w, sample(10_000, 500, 0), T);
    // Machine resumes from sleep with a corrected (earlier) clock.
    try std.testing.expectEqual(Action.none, evaluate(&w, sample(1_000, 500, 0), T));
    try std.testing.expectEqual(Action.reannounce, evaluate(&w, sample(1_030, 500, 0), T));
}

test "reset clears everything" {
    var w = Watch{};
    _ = evaluate(&w, sample(0, 500, 0), T);
    _ = evaluate(&w, sample(20, 500, 0), T);
    try std.testing.expect(w.attempts > 0);
    w.reset();
    try std.testing.expect(!w.started);
    try std.testing.expectEqual(@as(u8, 0), w.attempts);
}
