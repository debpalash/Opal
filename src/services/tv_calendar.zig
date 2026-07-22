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
/// Parallel TmdbItem per entry — carries the poster-fetch state so the Home
/// rail can show real poster cards (like Trending) via the shared poster
/// daemon, instead of duplicating that machinery. Index-aligned with entries.
pub var cal_items: [12]state.TmdbItem = undefined;
pub var count: usize = 0;
pub var loading = std.atomic.Value(bool).init(false);
var fetched_once: bool = false;

/// Kick the TV metadata sync (which builds this rail as a side-effect).
///
/// The fetch used to live here: this module hit /3/tv/{id} for every show the
/// user was watching, and separately derived its own `unseen` flag. tv_library
/// now makes exactly that same call for exactly those same shows, so the fetch
/// moved there and this module became a consumer. One fetch, one definition of
/// "what's next" — see tv_pure.nextUp.
pub fn refreshOnce() void {
    @import("tv_library.zig").syncOnce();
}

fn curlInto(url: []const u8, buf: []u8) usize {
    // Same DPI-bypass routing as eztv_calendar.curlInto — this one also hits the
    // eztv get-torrents API (for "is the latest aired episode available?"), and
    // was likewise ignoring the user's bypass setting.
    var argv: [12][]const u8 = undefined;
    var argc: usize = 0;
    for ([_][]const u8{ "curl", "-s", "--connect-timeout", "3", "--max-time", "8" }) |x| {
        argv[argc] = x;
        argc += 1;
    }
    if (@import("dpi_bypass.zig").proxyArgs()) |pa| {
        for (pa) |x| {
            if (argc >= argv.len - 1) break;
            argv[argc] = x;
            argc += 1;
        }
    }
    argv[argc] = url;
    argc += 1;

    var child = io.Child.init(argv[0..argc], alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

// ══════════════════════════════════════════════════════════
// Staging — driven by tv_library's sync worker
//
// The sync worker already holds the /3/tv/{id} document and a scratch buffer for
// each tracked show, so it hands them straight here rather than refetching. It
// also hands us tv_pure's answer for "is there anything to watch", which replaces
// the bad heuristic this module used to compute (it compared TMDB's last-aired
// episode against the LAST WATCHED one, which is wrong for anyone who skipped,
// rewatched, or watched out of order).
// ══════════════════════════════════════════════════════════

var built: usize = 0;
var eztv_on: bool = false;
var eztv_api_buf: [256]u8 = std.mem.zeroes([256]u8);
var eztv_api_len: usize = 0;

pub fn beginStage() void {
    const source_config = @import("../core/source_config.zig");
    built = 0;
    loading.store(true, .release);
    eztv_on = source_config.has("eztv");
    eztv_api_len = 0;
    if (eztv_on) {
        if (source_config.get("eztv", "api")) |api| {
            eztv_api_len = @min(api.len, eztv_api_buf.len);
            @memcpy(eztv_api_buf[0..eztv_api_len], api[0..eztv_api_len]);
        }
    }
}

/// Stage one show. `doc` is the /3/tv/{id} body the sync worker just fetched;
/// `next_up` is tv_pure's next episode for this show (null = caught up).
/// `scratch` is a large heap buffer we may clobber for the EZTV lookup.
pub fn stage(
    tmdb_id: i32,
    name: []const u8,
    poster_path: []const u8,
    doc: []const u8,
    next_up: ?@import("tv_pure.zig").Ep,
    scratch: []u8,
) void {
    if (built >= entries.len) return;
    if (tmdb_id == 0) return;

    const tmdb_api = @import("tmdb_api.zig");
    const key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];

    var e = &entries[built];
    e.* = .{};
    e.tmdb_id = tmdb_id;
    e.name_len = @min(name.len, e.name.len);
    @memcpy(e.name[0..e.name_len], name[0..e.name_len]);
    e.poster_path_len = @min(poster_path.len, e.poster_path.len);
    @memcpy(e.poster_path[0..e.poster_path_len], poster_path[0..e.poster_path_len]);

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

        // "Something to watch right now" is exactly tv_pure's answer — no local
        // re-derivation, which is how this rail and the detail page used to
        // disagree about the same show.
        e.unseen = next_up != null;

        // EZTV availability for the latest aired episode.
        if (e.unseen and eztv_on and eztv_api_len > 0) {
            var ext_url_buf: [160]u8 = undefined;
            if (std.fmt.bufPrint(&ext_url_buf, "/3/tv/{d}/external_ids", .{tmdb_id})) |ext_url| {
                const en = tmdb_api.tmdbApiInto(ext_url, key, scratch);
                var digits_buf: [12]u8 = undefined;
                if (en > 0) {
                    if (pure.imdbDigits(scratch[0..en], &digits_buf)) |digits| {
                        var ez_url_buf: [320]u8 = undefined;
                        if (std.fmt.bufPrint(&ez_url_buf, "{s}?imdb_id={s}&limit=100", .{ eztv_api_buf[0..eztv_api_len], digits })) |ez_url| {
                            const zn = curlInto(ez_url, scratch);
                            if (zn > 0) {
                                if (pure.eztvEpisodeSeeds(scratch[0..zn], last.season, last.episode)) |seeds| {
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

    // Keep only rows with something to say: a scheduled next episode, or one
    // that has aired and is still unwatched.
    if (e.next_season > 0 or e.unseen) {
        // Mirror into a TmdbItem for the poster-card rail (fresh state, so no
        // stale texture/pixels carry over from a previous refresh).
        var it = &cal_items[built];
        it.* = .{};
        it.id = e.tmdb_id;
        const inl = @min(e.name_len, it.title.len);
        @memcpy(it.title[0..inl], e.name[0..inl]);
        it.title_len = inl;
        const ipl = @min(e.poster_path_len, it.poster_path.len);
        @memcpy(it.poster_path[0..ipl], e.poster_path[0..ipl]);
        it.poster_path_len = ipl;
        @memcpy(it.media_type[0..2], "tv");
        it.media_type_len = 2;
        built += 1;
    }
}

pub fn endStage() void {
    count = built; // publish last
    loading.store(false, .release);
    if (built > 0) {
        var lb: [64]u8 = undefined;
        logs.pushLog("info", "calendar", std.fmt.bufPrint(&lb, "Coming up: {d} shows", .{built}) catch "Coming up ready", false);
        state.wakeUi();
    }
}
