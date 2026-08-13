//! Pure policy for resolver worker publication.
//!
//! The resolver has two kinds of workers: live search workers belong to one
//! monotonically increasing run, while cache-warm workers publish only into a
//! private sink.  Keeping this decision pure makes the stale-run boundary easy
//! to test without compiling the UI and network backends.

const std = @import("std");

pub const WorkerKind = enum { live, warm };

/// Observable lifecycle state for one resolver backend. `done` means at least
/// one usable candidate was produced; every other terminal value explains why
/// the source contributed nothing (or only a partial set).
pub const SourceStatus = enum(u8) {
    idle,
    searching,
    done,
    no_results,
    unavailable,
    partial,
    failed,
    transport_failed,
    parse_failed,
    timed_out,
};

pub fn isFailure(status: SourceStatus) bool {
    return switch (status) {
        .failed, .transport_failed, .parse_failed, .timed_out => true,
        else => false,
    };
}

/// A terminal outcome that prevents the source from being described as wholly
/// successful. `no_results` is a clean empty response, not a problem.
pub fn isProblem(status: SourceStatus) bool {
    return isFailure(status) or status == .unavailable or status == .partial;
}

fn severity(status: SourceStatus) u8 {
    return switch (status) {
        .timed_out => 6,
        .transport_failed => 5,
        .parse_failed => 4,
        .failed => 3,
        .unavailable => 2,
        .no_results => 1,
        else => 0,
    };
}

/// Preserve the most informative event reported during one worker run.
pub fn mergeReported(current: SourceStatus, next: SourceStatus) SourceStatus {
    return if (severity(next) > severity(current)) next else current;
}

/// Turn a worker's report plus observable publication into one terminal state.
/// An error after publishing rows is partial success, never a clean success;
/// a clean worker with zero rows is explicitly `no_results`.
pub fn finalize(reported: SourceStatus, produced: bool) SourceStatus {
    if (produced) return if (isProblem(reported)) .partial else .done;
    return if (reported == .done or reported == .searching or reported == .idle)
        .no_results
    else
        reported;
}

/// Fold two backends displayed as one logical source (for example nova2 and
/// YTS under the single "Torrents" chip). A successful backend plus a broken
/// peer is partial success; when neither produced results, retain the most
/// actionable terminal reason.
pub fn combineSources(a: SourceStatus, b: SourceStatus) SourceStatus {
    return combineMany(&.{ a, b });
}

pub fn combineMany(statuses: []const SourceStatus) SourceStatus {
    if (statuses.len == 0) return .idle;

    var any_produced = false;
    var any_problem = false;
    var strongest = SourceStatus.idle;
    for (statuses) |status| {
        if (status == .searching) return .searching;
        if (status == .done or status == .partial) any_produced = true;
        if (isProblem(status)) any_problem = true;
        if (severity(status) > severity(strongest)) strongest = status;
    }

    if (any_produced) return if (any_problem) .partial else .done;

    // All-idle is the pre-search/filtered-out state. A set of clean, empty
    // backends is no-results; otherwise preserve the strongest explanation.
    if (strongest == .idle) {
        for (statuses) |status| if (status == .no_results) return .no_results;
    }
    return strongest;
}

/// Whether a worker may mutate the live result/status/cache lifecycle.
pub fn mayMutateLive(kind: WorkerKind, worker_run: u32, active_run: u32) bool {
    return kind == .live and worker_run == active_run;
}

/// Failure is terminal for a source within one run. A later generic cleanup
/// reporting success must not erase the earlier, more informative outcome.
pub fn terminalFailed(current_failed: bool, reported_failed: bool) bool {
    return current_failed or reported_failed;
}

test "superseded worker cannot mutate the active run" {
    try std.testing.expect(mayMutateLive(.live, 12, 12));
    try std.testing.expect(!mayMutateLive(.live, 11, 12));
}

test "cache warm never mutates live lifecycle" {
    try std.testing.expect(!mayMutateLive(.warm, 12, 12));
    try std.testing.expect(!mayMutateLive(.warm, 0, 12));
}

test "concurrent publication tokens admit only active live workers" {
    const Worker = struct {
        fn run(
            admitted: *std.atomic.Value(usize),
            kind: WorkerKind,
            worker_run: u32,
            active_run: u32,
        ) void {
            for (0..2_000) |_| {
                if (mayMutateLive(kind, worker_run, active_run))
                    _ = admitted.fetchAdd(1, .monotonic);
            }
        }
    };

    var admitted = std.atomic.Value(usize).init(0);
    var threads: [6]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, Worker.run, .{ &admitted, WorkerKind.live, 9, 9 });
    threads[1] = try std.Thread.spawn(.{}, Worker.run, .{ &admitted, WorkerKind.live, 9, 9 });
    threads[2] = try std.Thread.spawn(.{}, Worker.run, .{ &admitted, WorkerKind.live, 8, 9 });
    threads[3] = try std.Thread.spawn(.{}, Worker.run, .{ &admitted, WorkerKind.live, 10, 9 });
    threads[4] = try std.Thread.spawn(.{}, Worker.run, .{ &admitted, WorkerKind.warm, 9, 9 });
    threads[5] = try std.Thread.spawn(.{}, Worker.run, .{ &admitted, WorkerKind.warm, 0, 9 });
    for (&threads) |*thread| thread.join();

    try std.testing.expectEqual(@as(usize, 4_000), admitted.load(.acquire));
}

test "failure remains terminal within a run" {
    try std.testing.expect(terminalFailed(true, false));
    try std.testing.expect(terminalFailed(false, true));
    try std.testing.expect(!terminalFailed(false, false));
}

test "terminal outcome distinguishes empty failure partial and success" {
    try std.testing.expectEqual(SourceStatus.no_results, finalize(.done, false));
    try std.testing.expectEqual(SourceStatus.done, finalize(.done, true));
    try std.testing.expectEqual(SourceStatus.transport_failed, finalize(.transport_failed, false));
    try std.testing.expectEqual(SourceStatus.partial, finalize(.transport_failed, true));
    try std.testing.expectEqual(SourceStatus.unavailable, finalize(.unavailable, false));
    try std.testing.expectEqual(SourceStatus.partial, finalize(.unavailable, true));
}

test "reported failures retain the strongest reason" {
    try std.testing.expectEqual(SourceStatus.transport_failed, mergeReported(.no_results, .transport_failed));
    try std.testing.expectEqual(SourceStatus.timed_out, mergeReported(.parse_failed, .timed_out));
    try std.testing.expectEqual(SourceStatus.parse_failed, mergeReported(.parse_failed, .done));
}

test "combined logical source preserves partial and strongest failure" {
    try std.testing.expectEqual(SourceStatus.searching, combineSources(.done, .searching));
    try std.testing.expectEqual(SourceStatus.done, combineSources(.done, .no_results));
    try std.testing.expectEqual(SourceStatus.partial, combineSources(.done, .transport_failed));
    try std.testing.expectEqual(SourceStatus.timed_out, combineSources(.parse_failed, .timed_out));
    try std.testing.expectEqual(SourceStatus.no_results, combineSources(.no_results, .no_results));
    try std.testing.expectEqual(SourceStatus.partial, combineMany(&.{ .done, .no_results, .unavailable, .no_results }));
    try std.testing.expectEqual(SourceStatus.transport_failed, combineMany(&.{ .no_results, .transport_failed, .unavailable }));
    try std.testing.expectEqual(SourceStatus.idle, combineMany(&.{ .idle, .idle }));
}

test "outcome folding is order independent for every status pair" {
    const statuses = std.enums.values(SourceStatus);
    for (statuses) |a| {
        for (statuses) |b| {
            try std.testing.expectEqual(combineSources(a, b), combineSources(b, a));
        }
    }
}
