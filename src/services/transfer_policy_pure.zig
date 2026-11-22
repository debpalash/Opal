//! Typed transfer policy for torrents: explicit state machine, disk-space
//! guard, path containment, a cap on concurrent downloads, and a seeding goal
//! (share ratio and/or seeding time).
//!
//! The executor (transfer_policy.zig) samples libtorrent on the stall-watchdog
//! thread, hands the facts to `step`, and performs the single Action returned.
//! Every decision lives here so the shipped policy is the tested policy.
//!
//! Two rules shape the machine:
//!  - A user's explicit pause/resume always wins. Policy only ever pauses a
//!    transfer into a policy state (queued / blocked_disk / completed /
//!    rejected), and a libtorrent pause or resume that disagrees with the
//!    recorded state is read as the user's intent.
//!  - Restart never auto-starts anything (restored transfers wait for an
//!    explicit Resume, see torrent_intents.restoreIfReady). Persisted state is
//!    rehydrated through the `restore` event, which parks every running or
//!    waiting transfer as `paused` and keeps terminal outcomes.
//!
//! No dvui / state / c imports (registered in build.zig's `test` step).

const std = @import("std");

pub const State = enum(u8) {
    /// Running and fetching data (includes the metadata phase).
    downloading,
    /// Policy-paused: waiting for a download slot.
    queued,
    /// Running with every wanted byte present.
    seeding,
    /// Paused by the user (or restored after restart).
    paused,
    /// Policy-paused: the seeding goal was reached.
    completed,
    /// Policy-paused: not enough free disk space.
    blocked_disk,
    /// libtorrent reported an error (disk full, permissions, ...).
    errored,
    /// Policy-stopped for good: a file path escapes the download root.
    rejected,
};

pub const Event = enum {
    user_pause,
    resume_download,
    resume_seed,
    finish,
    enqueue,
    admit,
    disk_low,
    disk_ok,
    goal_met,
    fault,
    recover,
    path_escape,
    restore,
};

pub const TransitionError = error{InvalidTransition};

/// The whole state machine. Anything not listed is rejected.
pub fn transition(from: State, ev: Event) TransitionError!State {
    const bad = error.InvalidTransition;
    return switch (ev) {
        .user_pause => switch (from) {
            .downloading, .seeding => .paused,
            else => bad,
        },
        .resume_download => switch (from) {
            .paused, .queued, .blocked_disk, .completed => .downloading,
            else => bad,
        },
        .resume_seed => switch (from) {
            .paused, .queued, .blocked_disk, .completed => .seeding,
            else => bad,
        },
        .finish => if (from == .downloading) .seeding else bad,
        .enqueue => if (from == .downloading) .queued else bad,
        .admit => if (from == .queued) .downloading else bad,
        .disk_low => switch (from) {
            .downloading, .queued => .blocked_disk,
            else => bad,
        },
        .disk_ok => if (from == .blocked_disk) .queued else bad,
        .goal_met => if (from == .seeding) .completed else bad,
        .fault => switch (from) {
            .downloading, .queued, .seeding, .paused, .completed, .blocked_disk => .errored,
            else => bad,
        },
        .recover => if (from == .errored) .paused else bad,
        .path_escape => if (from == .rejected) bad else .rejected,
        .restore => switch (from) {
            .downloading, .queued, .seeding, .blocked_disk, .paused => .paused,
            .completed, .errored, .rejected => from,
        },
    };
}

/// States in which libtorrent should be paused.
pub fn expectsPaused(s: State) bool {
    return switch (s) {
        .downloading, .seeding => false,
        else => true,
    };
}

/// Running transfers that occupy a download slot.
pub fn occupiesSlot(s: State) bool {
    return s == .downloading;
}

// ── Persistence ──────────────────────────────────────────────────────────────

pub fn stateTag(s: State) []const u8 {
    return @tagName(s);
}

/// Parse a persisted tag. Empty / unknown tags (older rows, other builds) mean
/// "no persisted state", never a guess.
pub fn parseState(tag: []const u8) ?State {
    return std.meta.stringToEnum(State, tag);
}

/// Per-transfer record. `state`, `seed_seconds`, `uploaded` and `goal_waived`
/// are persisted; `settle` is runtime only.
pub const Record = struct {
    state: State = .downloading,
    /// Seconds spent seeding while running, accumulated across restarts.
    seed_seconds: u32 = 0,
    /// Highest all-time upload seen (libtorrent resets it if resume data is lost).
    uploaded: u64 = 0,
    /// The user resumed a completed transfer: keep seeding past the goal.
    goal_waived: bool = false,
    /// Ticks to wait for our own pause/resume to show up in libtorrent before
    /// a disagreement is read as user intent.
    settle: u8 = 0,
};

pub const SETTLE_TICKS: u8 = 4;

// ── Policy ───────────────────────────────────────────────────────────────────

pub const MiB: u64 = 1024 * 1024;

pub const Policy = struct {
    /// Concurrent downloading transfers. 0 = unlimited.
    max_active: u32 = 0,
    /// Free space to keep on the download volume.
    reserve_bytes: u64 = 256 * MiB,
    /// Stop seeding at this share ratio x100 (150 = 1.5). 0 = off.
    seed_ratio_x100: u32 = 0,
    /// Stop seeding after this many minutes. 0 = off.
    seed_minutes: u32 = 0,
};

pub fn clampMaxActive(v: i64) u32 {
    return @intCast(std.math.clamp(v, 0, 32));
}
pub fn clampReserveMb(v: i64) u32 {
    return @intCast(std.math.clamp(v, 0, 1024 * 1024));
}
pub fn clampRatioX100(v: i64) u32 {
    return @intCast(std.math.clamp(v, 0, 10_000));
}
pub fn clampSeedMinutes(v: i64) u32 {
    return @intCast(std.math.clamp(v, 0, 525_600));
}

/// One libtorrent sample plus the executor's own observations.
pub const Facts = struct {
    paused: bool = false,
    errored: bool = false,
    has_metadata: bool = false,
    wanted: u64 = 0,
    wanted_done: u64 = 0,
    uploaded: u64 = 0,
    /// Free bytes on the download volume; null when unknown.
    free_bytes: ?u64 = null,
    /// A player is reading it through the stream proxy right now.
    streaming: bool = false,
    /// It was opened for playback (never queued behind downloads).
    interactive: bool = false,
    /// Every file path stays inside the download root.
    paths_ok: bool = true,

    pub fn finished(f: Facts) bool {
        return f.has_metadata and f.wanted > 0 and f.wanted_done >= f.wanted;
    }
    pub fn remaining(f: Facts) u64 {
        return f.wanted -| f.wanted_done;
    }
};

pub const Disk = enum { ok, low };

/// Guard the download volume. Below the reserve everything that writes stops;
/// a background download that cannot fit its remaining bytes above the reserve
/// does not start. A stream is exempt from the fit check (it may only ever
/// read one file of a large pack) but not from the reserve floor.
pub fn diskVerdict(f: Facts, reserve: u64) Disk {
    const free = f.free_bytes orelse return .ok;
    if (free < reserve) return .low;
    if (!f.streaming and f.has_metadata and f.remaining() > free - reserve) return .low;
    return .ok;
}

pub fn seedGoalMet(p: Policy, rec: Record, size: u64) bool {
    if (rec.goal_waived) return false;
    if (p.seed_ratio_x100 > 0 and size > 0) {
        const up: u128 = rec.uploaded;
        if (up * 100 >= @as(u128, size) * p.seed_ratio_x100) return true;
    }
    if (p.seed_minutes > 0 and @as(u64, rec.seed_seconds) >= @as(u64, p.seed_minutes) * 60) return true;
    return false;
}

/// Path containment for one torrent file path RELATIVE to the download root.
/// Rejects absolute paths (POSIX, UNC, drive letters), NUL, and any empty,
/// `.` or `..` component on either separator, so the joined path can never
/// leave the root lexically.
pub fn relativeContained(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (rel[0] == '/' or rel[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return false;
    if (rel.len >= 2 and std.ascii.isAlphabetic(rel[0]) and rel[1] == ':') return false;
    var it = std.mem.splitAny(u8, rel, "/\\");
    while (it.next()) |comp| {
        if (comp.len == 0) return false;
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

pub const Action = enum { none, pause, resume_ };

pub const Context = struct {
    /// Downloading transfers OTHER than this one.
    active_others: u32 = 0,
    /// Seconds since the previous sample of this transfer.
    dt_s: u32 = 0,
    /// First sample this process, with a persisted state loaded from disk.
    restored: bool = false,
    /// First sample this process, without a persisted state (a new add).
    first_sight: bool = false,
};

/// State for a transfer seen for the first time with nothing persisted.
pub fn initialState(f: Facts) State {
    if (f.paused) return .paused;
    if (f.finished()) return .seeding;
    return .downloading;
}

fn apply(rec: *Record, ev: Event) bool {
    rec.state = transition(rec.state, ev) catch return false;
    return true;
}

fn act(rec: *Record, a: Action) Action {
    if (a != .none) rec.settle = SETTLE_TICKS;
    return a;
}

/// Advance one transfer by one sample. Mutates `rec`, returns what to do.
pub fn step(rec: *Record, f: Facts, p: Policy, ctx: Context) Action {
    rec.uploaded = @max(rec.uploaded, f.uploaded);

    // Containment is checked first and is sticky: a transfer that would write
    // outside the root stays stopped whatever else happens.
    if (rec.state == .rejected or !f.paths_ok) {
        if (rec.state != .rejected) _ = apply(rec, .path_escape);
        return if (f.paused) .none else act(rec, .pause);
    }

    if (ctx.restored) {
        _ = apply(rec, .restore);
        return .none;
    }

    // Our own pause/resume is asynchronous in libtorrent.
    if (rec.settle > 0) {
        if (expectsPaused(rec.state) == f.paused) {
            rec.settle = 0;
        } else {
            rec.settle -= 1;
            return .none;
        }
    }

    if (f.errored) {
        if (rec.state != .errored) _ = apply(rec, .fault);
        return .none;
    }
    if (rec.state == .errored) _ = apply(rec, .recover);

    // Explicit user intent, inferred from a disagreement with the record.
    if (!expectsPaused(rec.state) and f.paused) {
        _ = apply(rec, .user_pause);
        return .none;
    }
    var user_started = false;
    if (expectsPaused(rec.state) and !f.paused) {
        if (rec.state == .completed) rec.goal_waived = true;
        _ = apply(rec, if (f.finished()) .resume_seed else .resume_download);
        user_started = true;
    }

    if (rec.state == .downloading and f.finished()) _ = apply(rec, .finish);

    switch (rec.state) {
        .downloading, .queued => if (diskVerdict(f, p.reserve_bytes) == .low) {
            const was_running = rec.state == .downloading;
            _ = apply(rec, .disk_low);
            return if (was_running) act(rec, .pause) else .none;
        },
        .blocked_disk => if (diskVerdict(f, p.reserve_bytes) == .ok) {
            _ = apply(rec, .disk_ok);
        },
        else => {},
    }

    const slot_free = p.max_active == 0 or ctx.active_others < p.max_active;
    if (rec.state == .downloading and ctx.first_sight and !user_started and !slot_free and !f.interactive) {
        _ = apply(rec, .enqueue);
        return act(rec, .pause);
    }
    if (rec.state == .queued and (slot_free or f.interactive)) {
        _ = apply(rec, .admit);
        return act(rec, .resume_);
    }

    if (rec.state == .seeding) {
        if (!f.paused) rec.seed_seconds +|= ctx.dt_s;
        if (!f.streaming and seedGoalMet(p, rec.*, f.wanted)) {
            _ = apply(rec, .goal_met);
            return act(rec, .pause);
        }
    }
    return .none;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const t = std.testing;

fn running(wanted: u64, done: u64) Facts {
    return .{ .has_metadata = true, .wanted = wanted, .wanted_done = done, .free_bytes = 1 << 40 };
}

test "transition table: every valid edge" {
    try t.expectEqual(State.paused, try transition(.downloading, .user_pause));
    try t.expectEqual(State.paused, try transition(.seeding, .user_pause));
    try t.expectEqual(State.downloading, try transition(.paused, .resume_download));
    try t.expectEqual(State.seeding, try transition(.completed, .resume_seed));
    try t.expectEqual(State.seeding, try transition(.downloading, .finish));
    try t.expectEqual(State.queued, try transition(.downloading, .enqueue));
    try t.expectEqual(State.downloading, try transition(.queued, .admit));
    try t.expectEqual(State.blocked_disk, try transition(.queued, .disk_low));
    try t.expectEqual(State.queued, try transition(.blocked_disk, .disk_ok));
    try t.expectEqual(State.completed, try transition(.seeding, .goal_met));
    try t.expectEqual(State.errored, try transition(.paused, .fault));
    try t.expectEqual(State.paused, try transition(.errored, .recover));
    try t.expectEqual(State.rejected, try transition(.seeding, .path_escape));
}

test "transition table: invalid edges are rejected" {
    try t.expectError(error.InvalidTransition, transition(.paused, .user_pause));
    try t.expectError(error.InvalidTransition, transition(.seeding, .enqueue));
    try t.expectError(error.InvalidTransition, transition(.downloading, .admit));
    try t.expectError(error.InvalidTransition, transition(.paused, .goal_met));
    try t.expectError(error.InvalidTransition, transition(.seeding, .disk_low));
    try t.expectError(error.InvalidTransition, transition(.rejected, .resume_download));
    try t.expectError(error.InvalidTransition, transition(.rejected, .path_escape));
    try t.expectError(error.InvalidTransition, transition(.rejected, .fault));
    try t.expectError(error.InvalidTransition, transition(.errored, .resume_seed));
}

test "restore parks running and waiting transfers, keeps outcomes" {
    for ([_]State{ .downloading, .queued, .seeding, .blocked_disk, .paused }) |s|
        try t.expectEqual(State.paused, try transition(s, .restore));
    for ([_]State{ .completed, .errored, .rejected }) |s|
        try t.expectEqual(s, try transition(s, .restore));
}

test "persisted tag round-trips; unknown tags are not guessed" {
    for (std.enums.values(State)) |s| {
        try t.expectEqual(@as(?State, s), parseState(stateTag(s)));
    }
    try t.expect(parseState("") == null);
    try t.expect(parseState("Downloading") == null);
    try t.expect(parseState("seeding; DROP TABLE") == null);
}

test "restart: restored record stays paused and does not resume" {
    var rec = Record{ .state = .downloading, .seed_seconds = 10 };
    var f = running(100, 10);
    f.paused = true;
    try t.expectEqual(Action.none, step(&rec, f, .{ .max_active = 1 }, .{ .restored = true }));
    try t.expectEqual(State.paused, rec.state);
    // Subsequent samples keep it paused; a free slot does not start it.
    try t.expectEqual(Action.none, step(&rec, f, .{ .max_active = 1 }, .{}));
    try t.expectEqual(State.paused, rec.state);
    try t.expectEqual(@as(u32, 10), rec.seed_seconds);
}

test "restart: a completed transfer stays completed" {
    var rec = Record{ .state = .completed, .uploaded = 500 };
    var f = running(100, 100);
    f.paused = true;
    _ = step(&rec, f, .{ .seed_ratio_x100 = 100 }, .{ .restored = true });
    try t.expectEqual(State.completed, rec.state);
}

test "max concurrent: a new background add queues; an interactive one never does" {
    const p = Policy{ .max_active = 2 };
    var rec = Record{ .state = initialState(running(100, 0)) };
    try t.expectEqual(Action.pause, step(&rec, running(100, 0), p, .{ .active_others = 2, .first_sight = true }));
    try t.expectEqual(State.queued, rec.state);

    var play = Record{};
    var f = running(100, 0);
    f.interactive = true;
    try t.expectEqual(Action.none, step(&play, f, p, .{ .active_others = 2, .first_sight = true }));
    try t.expectEqual(State.downloading, play.state);
}

test "max concurrent: queued is admitted when a slot frees" {
    const p = Policy{ .max_active = 1 };
    var rec = Record{ .state = .queued };
    var f = running(100, 0);
    f.paused = true;
    try t.expectEqual(Action.none, step(&rec, f, p, .{ .active_others = 1 }));
    try t.expectEqual(State.queued, rec.state);
    try t.expectEqual(Action.resume_, step(&rec, f, p, .{ .active_others = 0 }));
    try t.expectEqual(State.downloading, rec.state);
}

test "max concurrent: unlimited by default" {
    var rec = Record{};
    try t.expectEqual(Action.none, step(&rec, running(100, 0), .{}, .{ .active_others = 500, .first_sight = true }));
    try t.expectEqual(State.downloading, rec.state);
}

test "user intent: pause and resume are inferred; user resume beats the cap" {
    const p = Policy{ .max_active = 1 };
    var rec = Record{};
    var f = running(100, 0);
    f.paused = true;
    _ = step(&rec, f, p, .{});
    try t.expectEqual(State.paused, rec.state);
    f.paused = false;
    try t.expectEqual(Action.none, step(&rec, f, p, .{ .active_others = 5 }));
    try t.expectEqual(State.downloading, rec.state);
}

test "settle: our own pause is not misread as a user resume while it lands" {
    const p = Policy{ .max_active = 1 };
    var rec = Record{};
    try t.expectEqual(Action.pause, step(&rec, running(100, 0), p, .{ .active_others = 1, .first_sight = true }));
    // libtorrent still reports running for a tick or two.
    _ = step(&rec, running(100, 0), p, .{ .active_others = 1 });
    try t.expectEqual(State.queued, rec.state);
    var f = running(100, 0);
    f.paused = true;
    _ = step(&rec, f, p, .{ .active_others = 1 });
    try t.expectEqual(State.queued, rec.state);
    try t.expectEqual(@as(u8, 0), rec.settle);
}

test "settle expires: a lasting disagreement becomes user intent" {
    var rec = Record{ .state = .queued, .settle = 2 };
    const f = running(100, 0);
    _ = step(&rec, f, .{ .max_active = 1 }, .{ .active_others = 1 });
    _ = step(&rec, f, .{ .max_active = 1 }, .{ .active_others = 1 });
    try t.expectEqual(State.queued, rec.state);
    _ = step(&rec, f, .{ .max_active = 1 }, .{ .active_others = 1 });
    try t.expectEqual(State.downloading, rec.state);
}

test "disk guard: below the reserve a download pauses, then re-queues and resumes" {
    const p = Policy{ .reserve_bytes = 1000 };
    var rec = Record{};
    var f = running(100, 0);
    f.free_bytes = 999;
    try t.expectEqual(Action.pause, step(&rec, f, p, .{}));
    try t.expectEqual(State.blocked_disk, rec.state);
    f.paused = true;
    try t.expectEqual(Action.none, step(&rec, f, p, .{}));
    try t.expectEqual(State.blocked_disk, rec.state);
    f.free_bytes = 5000;
    try t.expectEqual(Action.resume_, step(&rec, f, p, .{}));
    try t.expectEqual(State.downloading, rec.state);
}

test "disk guard: remaining bytes must fit above the reserve" {
    try t.expectEqual(Disk.low, diskVerdict(.{ .has_metadata = true, .wanted = 10_000, .free_bytes = 5_000 }, 1_000));
    try t.expectEqual(Disk.ok, diskVerdict(.{ .has_metadata = true, .wanted = 10_000, .wanted_done = 7_000, .free_bytes = 5_000 }, 1_000));
    // Unknown free space never blocks; no metadata means size unknown.
    try t.expectEqual(Disk.ok, diskVerdict(.{ .has_metadata = true, .wanted = 10_000 }, 1_000));
    try t.expectEqual(Disk.ok, diskVerdict(.{ .free_bytes = 5_000 }, 1_000));
    // A stream skips the fit check but not the floor.
    try t.expectEqual(Disk.ok, diskVerdict(.{ .has_metadata = true, .wanted = 10_000, .free_bytes = 5_000, .streaming = true }, 1_000));
    try t.expectEqual(Disk.low, diskVerdict(.{ .free_bytes = 500, .streaming = true }, 1_000));
}

test "disk guard: seeding is not blocked (it does not write)" {
    var rec = Record{ .state = .seeding };
    var f = running(100, 100);
    f.free_bytes = 0;
    try t.expectEqual(Action.none, step(&rec, f, .{}, .{}));
    try t.expectEqual(State.seeding, rec.state);
}

test "finish moves downloading to seeding" {
    var rec = Record{};
    _ = step(&rec, running(100, 100), .{}, .{});
    try t.expectEqual(State.seeding, rec.state);
}

test "seeding goal: ratio" {
    const p = Policy{ .seed_ratio_x100 = 150 };
    var rec = Record{ .state = .seeding };
    var f = running(1000, 1000);
    f.uploaded = 1499;
    try t.expectEqual(Action.none, step(&rec, f, p, .{}));
    f.uploaded = 1500;
    try t.expectEqual(Action.pause, step(&rec, f, p, .{}));
    try t.expectEqual(State.completed, rec.state);
}

test "seeding goal: time accrues only while running, across restarts" {
    const p = Policy{ .seed_minutes = 1 };
    var rec = Record{ .state = .seeding, .seed_seconds = 50 };
    try t.expectEqual(Action.none, step(&rec, running(10, 10), p, .{ .dt_s = 5 }));
    try t.expectEqual(@as(u32, 55), rec.seed_seconds);
    try t.expectEqual(Action.pause, step(&rec, running(10, 10), p, .{ .dt_s = 5 }));
    try t.expectEqual(State.completed, rec.state);
}

test "seeding goal: never stops a stream; uploaded never goes backwards" {
    const p = Policy{ .seed_ratio_x100 = 100 };
    var rec = Record{ .state = .seeding, .uploaded = 5000 };
    var f = running(1000, 1000);
    f.streaming = true;
    f.uploaded = 0; // resume data lost
    try t.expectEqual(Action.none, step(&rec, f, p, .{}));
    try t.expectEqual(@as(u64, 5000), rec.uploaded);
    f.streaming = false;
    try t.expectEqual(Action.pause, step(&rec, f, p, .{}));
}

test "seeding goal: resuming a completed transfer waives the goal" {
    const p = Policy{ .seed_ratio_x100 = 100 };
    var rec = Record{ .state = .completed, .uploaded = 5000 };
    var f = running(1000, 1000);
    f.uploaded = 5000;
    try t.expectEqual(Action.none, step(&rec, f, p, .{}));
    try t.expectEqual(State.seeding, rec.state);
    try t.expect(rec.goal_waived);
    try t.expectEqual(Action.none, step(&rec, f, p, .{ .dt_s = 60 }));
    try t.expectEqual(State.seeding, rec.state);
}

test "containment: escaping path rejects and re-pauses on every resume" {
    var rec = Record{};
    var f = running(100, 0);
    f.paths_ok = false;
    try t.expectEqual(Action.pause, step(&rec, f, .{}, .{}));
    try t.expectEqual(State.rejected, rec.state);
    f.paths_ok = true; // sticky even if a later sample can't see the bad path
    f.paused = false;
    rec.settle = 0;
    try t.expectEqual(Action.pause, step(&rec, f, .{}, .{}));
    f.paused = true;
    try t.expectEqual(Action.none, step(&rec, f, .{}, .{ .restored = true }));
    try t.expectEqual(State.rejected, rec.state);
}

test "errors: fault parks, recovery returns to paused, then user resume runs" {
    var rec = Record{};
    var f = running(100, 0);
    f.errored = true;
    _ = step(&rec, f, .{}, .{});
    try t.expectEqual(State.errored, rec.state);
    f.errored = false;
    f.paused = true;
    _ = step(&rec, f, .{}, .{});
    try t.expectEqual(State.paused, rec.state);
    f.paused = false;
    _ = step(&rec, f, .{}, .{});
    try t.expectEqual(State.downloading, rec.state);
}

test "relativeContained rejects every escape spelling" {
    try t.expect(relativeContained("Show/S01/e01.mkv"));
    try t.expect(relativeContained("Movie: The Sequel (2020).mkv"));
    try t.expect(relativeContained("a..b/..c"));
    try t.expect(!relativeContained(""));
    try t.expect(!relativeContained("/etc/passwd"));
    try t.expect(!relativeContained("\\\\server\\share\\x"));
    try t.expect(!relativeContained("C:\\Windows\\x.dll"));
    try t.expect(!relativeContained("c:x"));
    try t.expect(!relativeContained("../x"));
    try t.expect(!relativeContained("a/../../x"));
    try t.expect(!relativeContained("a\\..\\x"));
    try t.expect(!relativeContained("a/./x"));
    try t.expect(!relativeContained("a//x"));
    try t.expect(!relativeContained("a/"));
    try t.expect(!relativeContained("a\x00b"));
}

test "policy clamps" {
    try t.expectEqual(@as(u32, 0), clampMaxActive(-3));
    try t.expectEqual(@as(u32, 32), clampMaxActive(99));
    try t.expectEqual(@as(u32, 0), clampRatioX100(-1));
    try t.expectEqual(@as(u32, 10_000), clampRatioX100(1 << 40));
    try t.expectEqual(@as(u32, 525_600), clampSeedMinutes(1 << 40));
    try t.expectEqual(@as(u32, 1024 * 1024), clampReserveMb(1 << 40));
}
