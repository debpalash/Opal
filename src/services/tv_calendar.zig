//! TV calendar — powers Home's "Coming up" rail. For each show the user is
//! watching (tv_continue), TMDB's /tv/{id} gives the NEXT episode to air
//! (countdown) and the LAST aired one; EZTV's get-torrents API (keyless,
//! neutral-gated on the installed eztv source plugin) tells us whether that
//! latest episode is actually available to stream and how well seeded it is.
//!
//! One refresh per session (Home kicks it once history loads); results live
//! in fixed buffers the UI reads each frame (worker fills entries, publishes
//! `count` last — same convention as the tv seasons worker).

const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("tv_calendar_pure.zig");

pub const Entry = struct {
    tmdb_id: i32 = 0,
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    poster_path: [64]u8 = std.mem.zeroes([64]u8),
    poster_path_len: usize = 0,
    // Next episode to air (0 season → none scheduled).
    next_season: i32 = 0,
    next_episode: i32 = 0,
    next_air_epoch: i64 = 0,
    next_name: [64]u8 = std.mem.zeroes([64]u8),
    next_name_len: usize = 0,
    // Latest AIRED episode + its EZTV availability.
    last_season: i32 = 0,
    last_episode: i32 = 0,
    available: bool = false, // EZTV has torrents for the latest aired episode
    seeds: u32 = 0,
    // True when the latest aired episode is past the user's watched position.
    unseen: bool = false,
};

pub var entries: [12]Entry = undefined;
pub var count: usize = 0;
pub var loading = std.atomic.Value(bool).init(false);
var fetched_once: bool = false;

/// Kick one background refresh per session (call from a render site; cheap
/// no-op afterwards). Requires the TMDB key; EZTV availability additionally
/// requires the eztv source plugin (neutral-ship gate).
pub fn refreshOnce() void {
    if (fetched_once) return;
    if (state.app.tmdb.api_key_len == 0) return;
    fetched_once = true;
    loading.store(true, .release);
    (std.Thread.spawn(.{}, worker, .{}) catch {
        loading.store(false, .release);
        return;
    }).detach();
}

fn curlInto(url: []const u8, buf: []u8) usize {
    var child = io.Child.init(&.{ "curl", "-s", "--max-time", "12", url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

fn worker() void {
    defer loading.store(false, .release);
    const db = @import("../core/db.zig");
    const tmdb_api = @import("tmdb_api.zig");
    const source_config = @import("../core/source_config.zig");

    var cont: [12]state.TvContinueItem = undefined;
    const n_shows = db.tvGetContinue(&cont);
    if (n_shows == 0) return;

    const key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];
    const eztv_on = source_config.has("eztv");
    var eztv_api_buf: [256]u8 = std.mem.zeroes([256]u8);
    var eztv_api_len: usize = 0;
    if (eztv_on) {
        if (source_config.get("eztv", "api")) |api| {
            eztv_api_len = @min(api.len, eztv_api_buf.len);
            @memcpy(eztv_api_buf[0..eztv_api_len], api[0..eztv_api_len]);
        }
    }

    const body = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(body);

    var built: usize = 0;
    for (cont[0..n_shows]) |*ci| {
        if (built >= entries.len) break;
        if (ci.tmdb_id == 0) continue;

        var url_buf: [128]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "/3/tv/{d}", .{ci.tmdb_id}) catch continue;
        const n = tmdb_api.tmdbApiInto(url, key, body);
        if (n == 0) continue;
        const doc = body[0..n];

        var e = &entries[built];
        e.* = .{};
        e.tmdb_id = ci.tmdb_id;
        e.name_len = @min(ci.name_len, e.name.len);
        @memcpy(e.name[0..e.name_len], ci.name[0..e.name_len]);
        e.poster_path_len = @min(ci.poster_path_len, e.poster_path.len);
        @memcpy(e.poster_path[0..e.poster_path_len], ci.poster_path[0..e.poster_path_len]);

        if (pure.parseEpisodeToAir(doc, "\"next_episode_to_air\":")) |next| {
            e.next_season = next.season;
            e.next_episode = next.episode;
            e.next_air_epoch = next.air_epoch;
            e.next_name_len = next.name_len;
            @memcpy(e.next_name[0..next.name_len], next.name[0..next.name_len]);
        }
        if (pure.parseEpisodeToAir(doc, "\"last_episode_to_air\":")) |last| {
            e.last_season = last.season;
            e.last_episode = last.episode;
            // Past the user's watched position? (continue row = last watched)
            e.unseen = last.season > ci.season or
                (last.season == ci.season and last.episode > ci.episode);

            // EZTV availability for that latest aired episode.
            if (e.unseen and eztv_on and eztv_api_len > 0) {
                var ext_url_buf: [160]u8 = undefined;
                if (std.fmt.bufPrint(&ext_url_buf, "/3/tv/{d}/external_ids", .{ci.tmdb_id})) |ext_url| {
                    const en = tmdb_api.tmdbApiInto(ext_url, key, body);
                    var digits_buf: [12]u8 = undefined;
                    if (en > 0) {
                        if (pure.imdbDigits(body[0..en], &digits_buf)) |digits| {
                            var ez_url_buf: [320]u8 = undefined;
                            if (std.fmt.bufPrint(&ez_url_buf, "{s}?imdb_id={s}&limit=100", .{ eztv_api_buf[0..eztv_api_len], digits })) |ez_url| {
                                const zn = curlInto(ez_url, body);
                                if (zn > 0) {
                                    if (pure.eztvEpisodeSeeds(body[0..zn], last.season, last.episode)) |seeds| {
                                        e.available = true;
                                        e.seeds = seeds;
                                    }
                                }
                            } else |_| {}
                        }
                    }
                } else |_| {}
            }
        }

        // Keep only rows with something to say: a scheduled next episode or
        // an unseen aired one.
        if (e.next_season > 0 or e.unseen) built += 1;
    }

    count = built; // publish last
    if (built > 0) {
        var lb: [64]u8 = undefined;
        logs.pushLog("info", "calendar", std.fmt.bufPrint(&lb, "Coming up: {d} shows", .{built}) catch "Coming up ready", false);
        state.wakeUi();
    }
}
