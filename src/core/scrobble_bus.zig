const std = @import("std");
const sync = @import("sync.zig");
const io_global = @import("io_global.zig");
pub const pure = @import("scrobble_pure.zig");

// ══════════════════════════════════════════════════════════
// Scrobble bus: the one path from playback to the tracker services.
//
// Player code never calls Trakt / SIMKL / AniList. It sends:
//   - tick(): one progress sample per frame for the active player
//   - mark(): an explicit watched/unwatched change (history removal,
//     the TV episode commit, the anime episode tracker)
// The bus runs scrobble_pure's debounce / threshold / dedupe rules and fans
// the resulting events out to the sinks registered at startup
// (services/scrobble_sinks.zig). Sinks are function pointers so this module
// depends only on core/ and runs under `zig build test` with a MockIo.
// ══════════════════════════════════════════════════════════

pub const Media = pure.Media;
pub const Event = pure.Event;
pub const Tracker = pure.Tracker;

pub const Delivery = struct { event: Event, media: Media, progress: f64 };
pub const Sink = struct { tracker: Tracker, deliver: *const fn (Delivery) void };

const MAX_SINKS = 4;
const MAX_PENDING = 4;

var mutex: sync.Mutex = .{};
var sinks: [MAX_SINKS]Sink = undefined;
var sink_count: usize = 0;
var session: ?pure.Session = null;
var session_owner: usize = 0;
var dedupe: pure.Dedupe = .{};
const config: pure.Config = .{};

/// Register (or replace) the sink for one tracker. Called once at startup.
pub fn registerSink(sink: Sink) void {
    mutex.lock();
    defer mutex.unlock();
    for (sinks[0..sink_count]) |*s| if (s.tracker == sink.tracker) {
        s.* = sink;
        return;
    };
    if (sink_count < MAX_SINKS) {
        sinks[sink_count] = sink;
        sink_count += 1;
    }
}

pub const Sample = struct {
    position: f64,
    duration: f64,
    paused: bool,
    played_seconds: f64,
};

/// One progress sample for the active player. `owner` identifies the player
/// (pointer identity); `media` is null when the player has no tracker
/// identity. A changed owner or media ends the previous session first.
pub fn tick(owner: usize, media: ?Media, sample: Sample) void {
    const now = io_global.monotonicMilliTimestamp();
    var pending: [MAX_PENDING]Delivery = undefined;
    var n: usize = 0;
    var targets: [MAX_SINKS]Sink = undefined;
    var target_count: usize = 0;
    {
        mutex.lock();
        defer mutex.unlock();
        if (session) |*s| {
            const same = owner == session_owner and media != null and media.?.eql(s.media);
            if (!same) {
                if (s.finish()) {
                    pending[n] = .{ .event = .stop, .media = s.media, .progress = s.last_progress };
                    n += 1;
                }
                session = null;
            }
        }
        if (session == null) if (media) |m| if (m.valid()) {
            session = pure.Session.begin(m);
            session_owner = owner;
        };
        if (session) |*s| {
            const emission = s.step(.{
                .now_ms = now,
                .position = sample.position,
                .duration = sample.duration,
                .paused = sample.paused,
                .played_seconds = sample.played_seconds,
            }, config);
            for (emission.slice()) |event| {
                if (!dedupe.admit(s.media, event, now, config.dedupe_window_ms)) continue;
                pending[n] = .{ .event = event, .media = s.media, .progress = emission.progress };
                n += 1;
            }
        }
        if (n > 0) target_count = snapshotSinks(&targets);
    }
    fanOut(pending[0..n], targets[0..target_count]);
}

/// Playback closed: end the current session (reports `stop` when due).
pub fn end() void {
    tick(0, null, .{ .position = 0, .duration = 0, .paused = true, .played_seconds = 0 });
}

/// Explicit watched / unwatched change from any source.
pub fn mark(media: Media, watched: bool) void {
    if (!media.valid()) return;
    const now = io_global.monotonicMilliTimestamp();
    const event: Event = if (watched) .watched else .unwatched;
    var targets: [MAX_SINKS]Sink = undefined;
    var target_count: usize = 0;
    {
        mutex.lock();
        defer mutex.unlock();
        if (!dedupe.admit(media, event, now, config.dedupe_window_ms)) return;
        target_count = snapshotSinks(&targets);
    }
    fanOut(&.{.{ .event = event, .media = media, .progress = if (watched) 100 else 0 }}, targets[0..target_count]);
}

fn snapshotSinks(out: *[MAX_SINKS]Sink) usize {
    @memcpy(out[0..sink_count], sinks[0..sink_count]);
    return sink_count;
}

// Delivered outside the mutex: sinks enqueue into durable outboxes or spawn
// workers, and a sink must never be able to deadlock the bus.
fn fanOut(deliveries: []const Delivery, targets: []const Sink) void {
    for (deliveries) |d| for (targets) |sink| {
        if (pure.routes(sink.tracker, d.media, d.event)) sink.deliver(d);
    };
}

fn resetForTest() void {
    mutex.lock();
    defer mutex.unlock();
    sink_count = 0;
    session = null;
    session_owner = 0;
    dedupe = .{};
}

// ══════════════════════════════════════════════════════════
// Tests: run under src/io_seam_tests.zig with a MockIo fake clock.
// ══════════════════════════════════════════════════════════

const Recorder = struct {
    const Seen = struct { tracker: Tracker, event: Event, media: Media };
    var seen: [32]Seen = undefined;
    var len: usize = 0;

    fn record(tracker: Tracker, d: Delivery) void {
        if (len < seen.len) {
            seen[len] = .{ .tracker = tracker, .event = d.event, .media = d.media };
            len += 1;
        }
    }
    fn trakt(d: Delivery) void {
        record(.trakt, d);
    }
    fn simkl(d: Delivery) void {
        record(.simkl, d);
    }
    fn anilist(d: Delivery) void {
        record(.anilist, d);
    }
    fn count(tracker: Tracker, event: Event) usize {
        var c: usize = 0;
        for (seen[0..len]) |s| {
            if (s.tracker == tracker and s.event == event) c += 1;
        }
        return c;
    }
    fn install() void {
        len = 0;
        resetForTest();
        registerSink(.{ .tracker = .trakt, .deliver = trakt });
        registerSink(.{ .tracker = .simkl, .deliver = simkl });
        registerSink(.{ .tracker = .anilist, .deliver = anilist });
    }
};

fn playing(pos: f64, played: f64) Sample {
    return .{ .position = pos, .duration = 100, .paused = false, .played_seconds = played };
}

test "bus: one tick stream fans out start, watched and dedupes the later commit" {
    var mock = @import("mock_io.zig").MockIo.init();
    mock.install();
    defer mock.deinit();
    Recorder.install();
    defer resetForTest();

    const player: usize = 0x1000;
    const ep = Media.tvEpisode(1399, 1, 2);
    tick(player, ep, playing(0, 0));
    mock.advanceMs(1_000);
    tick(player, ep, playing(1, 1));
    try std.testing.expectEqual(@as(usize, 0), Recorder.len);
    mock.advanceMs(2_000);
    tick(player, ep, playing(3, 3));
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.trakt, .start));
    try std.testing.expectEqual(@as(usize, 0), Recorder.count(.simkl, .start));

    mock.advanceMs(77_000);
    tick(player, ep, playing(80, 80));
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.trakt, .watched));
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.simkl, .watched));
    try std.testing.expectEqual(@as(usize, 0), Recorder.count(.anilist, .watched));

    // The 90% local-history commit marks the same episode: deduped.
    mock.advanceMs(10_000);
    mark(ep, true);
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.trakt, .watched));
    // Closing after watched sends no stop.
    end();
    try std.testing.expectEqual(@as(usize, 0), Recorder.count(.trakt, .stop));
}

test "bus: switching media stops the old session" {
    var mock = @import("mock_io.zig").MockIo.init();
    mock.install();
    defer mock.deinit();
    Recorder.install();
    defer resetForTest();

    const player: usize = 0x2000;
    tick(player, Media.movie(278), playing(0, 0));
    mock.advanceMs(3_000);
    tick(player, Media.movie(278), playing(3, 3));
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.trakt, .start));
    // Pause holds past the debounce, then a new movie loads.
    tick(player, Media.movie(278), .{ .position = 3, .duration = 100, .paused = true, .played_seconds = 3 });
    mock.advanceMs(3_000);
    tick(player, Media.movie(278), .{ .position = 3, .duration = 100, .paused = true, .played_seconds = 3 });
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.trakt, .pause));
    tick(player, Media.movie(550), playing(0, 0));
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.trakt, .stop));
    try std.testing.expect(Recorder.seen[Recorder.len - 1].media.eql(Media.movie(278)));
    // No tracker identity (a local file) ends the session too.
    mock.advanceMs(3_000);
    tick(player, Media.movie(550), playing(3, 3));
    tick(player, null, playing(3, 3));
    try std.testing.expectEqual(@as(usize, 2), Recorder.count(.trakt, .stop));
}

test "bus: explicit marks route by tracker and expire from dedupe" {
    var mock = @import("mock_io.zig").MockIo.init();
    mock.install();
    defer mock.deinit();
    Recorder.install();
    defer resetForTest();

    mark(Media.anime(21, 4), true);
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.anilist, .watched));
    try std.testing.expectEqual(@as(usize, 0), Recorder.count(.trakt, .watched));
    mark(Media.anime(21, 4), true);
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.anilist, .watched));
    mock.advanceMs(config.dedupe_window_ms);
    mark(Media.anime(21, 4), true);
    try std.testing.expectEqual(@as(usize, 2), Recorder.count(.anilist, .watched));

    mark(Media.movie(278), false);
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.trakt, .unwatched));
    try std.testing.expectEqual(@as(usize, 1), Recorder.count(.simkl, .unwatched));
    mark(Media.movie(0), true); // invalid identity never reaches a sink
    try std.testing.expectEqual(@as(usize, 0), Recorder.count(.trakt, .watched));
}
