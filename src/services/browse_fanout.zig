//! Worker-only bounded fan-out. Every borrowed job/context stays alive until all
//! admitted children are joined; providers own their response buffers.
const std = @import("std");
const workers = @import("../core/workers.zig");
const CancelEpoch = @import("../core/bounded_process.zig").CancelEpoch;
var deny_child_admission_for_test: bool = false;
pub const Options = struct { limit: u8 = 4, cancel_epoch: ?CancelEpoch = null };

pub fn cancelled(epoch: ?CancelEpoch) bool {
    const token = epoch orelse return false;
    return switch (token) {
        .epoch32 => |e| e.value.load(.acquire) != e.expected,
        .epoch64 => |e| e.value.load(.acquire) != e.expected,
    };
}

pub fn run(comptime Job: type, jobs: []const Job, context: anytype, comptime perform: anytype, options: Options) void {
    if (jobs.len == 0 or cancelled(options.cancel_epoch) or workers.isQuitting()) return;
    const Wave = struct {
        jobs: []const Job,
        context: @TypeOf(context),
        epoch: ?CancelEpoch,
        next: std.atomic.Value(usize) = .init(0),
        fn lane(wave: *@This()) void {
            while (!cancelled(wave.epoch) and !workers.isQuitting()) {
                const index = wave.next.fetchAdd(1, .acq_rel);
                if (index >= wave.jobs.len) return;
                if (cancelled(wave.epoch) or workers.isQuitting()) return;
                perform(wave.context, wave.jobs[index]);
            }
        }
    };
    var wave: Wave = .{ .jobs = jobs, .context = context, .epoch = options.cancel_epoch };
    var children: [3]?std.Thread = .{ null, null, null };
    const lanes = @min(jobs.len, std.math.clamp(@as(usize, options.limit), 1, 4));
    for (children[0 .. lanes - 1]) |*child| {
        if (@import("builtin").is_test and deny_child_admission_for_test) continue;
        child.* = workers.spawnLegacy(Wave.lane, .{&wave}) catch null;
    }
    Wave.lane(&wave);
    for (children) |child| if (child) |thread| thread.join();
}

test "Browse fanout overlaps providers, bounds lanes and joins all work" {
    workers.init();
    const C = struct {
        active: std.atomic.Value(u32) = .init(0),
        maximum: std.atomic.Value(u32) = .init(0),
        done: std.atomic.Value(u32) = .init(0),
        first_before_slow: std.atomic.Value(bool) = .init(false),
        slow_done: std.atomic.Value(bool) = .init(false),
        fn work(c: *@This(), job: u8) void {
            const active = c.active.fetchAdd(1, .acq_rel) + 1;
            var old = c.maximum.load(.acquire);
            while (active > old) {
                old = c.maximum.cmpxchgWeak(old, active, .acq_rel, .acquire) orelse break;
            }
            @import("../core/io_global.zig").sleep((if (job == 0) @as(u64, 80) else 10) * std.time.ns_per_ms);
            if (job == 0) c.slow_done.store(true, .release) else if (!c.slow_done.load(.acquire)) c.first_before_slow.store(true, .release);
            _ = c.active.fetchSub(1, .acq_rel);
            _ = c.done.fetchAdd(1, .acq_rel);
        }
    };
    var c: C = .{};
    run(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, &c, C.work, .{});
    try std.testing.expect(c.first_before_slow.load(.acquire));
    try std.testing.expect(c.maximum.load(.acquire) > 1 and c.maximum.load(.acquire) <= 4);
    try std.testing.expectEqual(@as(u32, 8), c.done.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), c.active.load(.acquire));
}

test "Browse fanout cancellation skips pending jobs and joins current provider" {
    workers.init();
    const C = struct {
        epoch: std.atomic.Value(u32) = .init(1),
        done: usize = 0,
        fn work(c: *@This(), _: u8) void {
            c.done += 1;
            c.epoch.store(2, .release);
        }
    };
    var c: C = .{};
    run(u8, &.{ 1, 2, 3 }, &c, C.work, .{ .limit = 1, .cancel_epoch = .{ .epoch32 = .{ .value = &c.epoch, .expected = 1 } } });
    try std.testing.expectEqual(@as(usize, 1), c.done);
}

test "Browse fanout four active providers cancel queued jobs and drain borrowed context" {
    workers.init();
    const C = struct {
        epoch: std.atomic.Value(u32) = .init(1),
        started: std.atomic.Value(u32) = .init(0),
        finished: std.atomic.Value(u32) = .init(0),
        fn work(c: *@This(), _: u8) void {
            const ordinal = c.started.fetchAdd(1, .acq_rel) + 1;
            while (c.started.load(.acquire) < 4) @import("../core/io_global.zig").sleep(std.time.ns_per_ms);
            if (ordinal == 4) c.epoch.store(2, .release);
            while (c.epoch.load(.acquire) == 1) @import("../core/io_global.zig").sleep(std.time.ns_per_ms);
            _ = c.finished.fetchAdd(1, .acq_rel);
        }
    };
    var c: C = .{};
    run(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, &c, C.work, .{ .cancel_epoch = .{ .epoch32 = .{ .value = &c.epoch, .expected = 1 } } });
    try std.testing.expectEqual(@as(u32, 4), c.started.load(.acquire));
    try std.testing.expectEqual(@as(u32, 4), c.finished.load(.acquire));
}

test "Browse fanout denied child admission falls back without losing jobs" {
    workers.init();
    deny_child_admission_for_test = true;
    defer deny_child_admission_for_test = false;
    const C = struct {
        done: usize = 0,
        fn work(c: *@This(), _: u8) void {
            c.done += 1;
        }
    };
    var c: C = .{};
    run(u8, &.{ 1, 2, 3, 4, 5 }, &c, C.work, .{});
    try std.testing.expectEqual(@as(usize, 5), c.done);
}

/// Must run under the category row mutex. A refresh retains old rows until the
/// first nonempty provider commit; later providers append, never reuse an index.
pub fn appendPosition(wave: u32, published: u32, generation: u32, count: usize, hint: usize) usize {
    if (wave != generation) return hint;
    return if (published == generation) count else 0;
}
pub fn usefulPublication(current: u32, generation: u32, start: usize, end: usize) bool {
    return current == generation and end > start;
}

test "Browse fanout publication retains cached rows on failure and excludes stale work" {
    try std.testing.expectEqual(@as(usize, 0), appendPosition(2, 1, 2, 40, 40));
    try std.testing.expect(!usefulPublication(2, 2, 0, 0));
    try std.testing.expect(usefulPublication(2, 2, 0, 3));
    try std.testing.expectEqual(@as(usize, 3), appendPosition(2, 2, 2, 3, 0));
    try std.testing.expect(!usefulPublication(3, 2, 3, 8));
    try std.testing.expectEqual(@as(usize, 10), appendPosition(0, 0, 2, 3, 10));
}

pub fn coverIdentityMatches(current: u32, generation: u32, current_url: []const u8, requested_url: []const u8) bool {
    return current == generation and requested_url.len > 0 and std.mem.eql(u8, current_url, requested_url);
}
test "Browse fanout cover ownership rejects stale generation and repurposed slot" {
    try std.testing.expect(coverIdentityMatches(2, 2, "https://cover/a", "https://cover/a"));
    try std.testing.expect(!coverIdentityMatches(3, 2, "https://cover/a", "https://cover/a"));
    try std.testing.expect(!coverIdentityMatches(2, 2, "https://cover/b", "https://cover/a"));
    try std.testing.expect(!coverIdentityMatches(2, 2, "", ""));
}

/// Caller holds the row mutex. Recheck after acquiring it: an old pagination
/// task must never replace the publication markers of a newer search.
pub fn beginAppendWave(current: u32, generation: u32, wave: *u32, published: *u32) bool {
    if (current != generation) return false;
    wave.* = generation;
    published.* = generation;
    return true;
}
test "Browse fanout stale pagination cannot overwrite newer publication markers" {
    var wave: u32 = 2;
    var published: u32 = 2;
    try std.testing.expect(!beginAppendWave(2, 1, &wave, &published));
    try std.testing.expectEqual(@as(u32, 2), wave);
    try std.testing.expectEqual(@as(u32, 2), published);
    try std.testing.expectEqual(@as(usize, 5), appendPosition(wave, published, 2, 5, 0));
    try std.testing.expect(beginAppendWave(2, 2, &wave, &published));
    try std.testing.expectEqual(@as(usize, 5), appendPosition(wave, published, 2, 5, 0));
}

pub fn reserveNextPage(page: *u32) ?u32 {
    if (page.* == std.math.maxInt(u32)) return null;
    page.* += 1;
    return page.*;
}
pub fn rollbackPage(current: u32, generation: u32, page: *u32, reserved: u32) void {
    if (current == generation and page.* == reserved and reserved > 0) page.* -= 1;
}
test "Browse fanout page reservation never rolls a newer query forward or backward" {
    var page: u32 = 1;
    const reserved = reserveNextPage(&page).?;
    try std.testing.expectEqual(@as(u32, 2), reserved);
    rollbackPage(1, 1, &page, reserved);
    try std.testing.expectEqual(@as(u32, 1), page);
    _ = reserveNextPage(&page);
    page = 1; // New query resets its cursor inside the same row mutex.
    rollbackPage(2, 1, &page, reserved);
    try std.testing.expectEqual(@as(u32, 1), page);
    page = std.math.maxInt(u32);
    try std.testing.expect(reserveNextPage(&page) == null);
}
