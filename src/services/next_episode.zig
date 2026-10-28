//! One speculative resolver warmup for the active tracked episode.
const std = @import("std");
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");
const alloc = @import("../core/alloc.zig").allocator;
const workers = @import("../core/workers.zig");
const pure = @import("next_episode_pure.zig");
const tv = @import("tv_pure.zig");
var epoch = std.atomic.Value(u64).init(0);
var busy = std.atomic.Value(bool).init(false);
// Owner-thread state; profile switches restart the process and drain workers.
var player_address: usize = 0;
var serial: u64 = 0;
var attempted = false;
const Job = struct { generation: u64, show: i32, current: tv.Ep };

pub fn tick() void {
    const p = if (state.app.active_player_idx < state.app.players.items.len) state.app.players.items[state.app.active_player_idx] else null;
    const address = if (p) |v| @intFromPtr(v) else 0;
    const load = if (p) |v| v.load_serial else 0;
    if (address != player_address or load != serial) {
        _ = epoch.fetchAdd(1, .acq_rel);
        player_address = address;
        serial = load;
        attempted = false;
    }
    const player = p orelse return;
    if (attempted or !state.app.content_cache_enabled) return;
    const ep = &state.app.playing_episode;
    if (!ep.matches(player.current_url[0..player.current_url_len])) return;
    const snap = player.playbackSnapshot();
    if (!pure.shouldWarm(snap.time_pos, snap.duration, snap.paused)) return;
    if (busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    const job: Job = .{ .generation = epoch.load(.acquire), .show = ep.tmdb_id, .current = .{ .season = ep.season, .episode = ep.episode } };
    if (workers.spawnLegacy(run, .{job})) |thread| {
        attempted = true;
        workers.release(thread);
    } else |_| busy.store(false, .release);
}

fn run(job: Job) void {
    defer busy.store(false, .release);
    if (workers.isQuitting() or epoch.load(.acquire) != job.generation) return;
    const seasons = db.tvSeasonList(alloc, job.show) catch return;
    defer alloc.free(seasons);
    var shows: [128]db.TvShowRow = undefined;
    const count = db.tvGetShows(&shows);
    for (shows[0..count]) |*show| {
        if (show.tmdb_id != job.show) continue;
        const next = pure.nextAfter(seasons, job.current, show.last_aired) orelse return;
        var query_buf: [256]u8 = undefined;
        const query = std.fmt.bufPrint(&query_buf, "{s} S{d:0>2}E{d:0>2}", .{ show.name[0..show.name_len], next.season, next.episode }) catch return;
        @import("resolver.zig").warmQueryForEpoch(query, &epoch, job.generation);
        return;
    }
}
