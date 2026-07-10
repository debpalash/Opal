//! Keyless TVmaze episode air-date enrichment. TVmaze is a FREE, keyless TV
//! API; we use it to fill TMDB's gaps — a show-level "Next: SxEy · airs {date}"
//! line and real per-episode air-dates on rows where TMDB has none.
//!
//! Opening a TV detail (tmdb.openTvDetail) kicks onTvDetailOpen(); a single
//! detached worker resolves the show by title, then fetches its next episode
//! and full episode list. Results live in module vars (NOT state.zig) behind a
//! mutex; the UI thread reads them each frame via nextLabel()/airdateFor().
//!
//! All JSON parsing routes through tvmaze_pure.zig (unit-tested, no drift).
//! Endpoints (keyless):
//!   - /singlesearch/shows?q={title}          → show id
//!   - /shows/{id}?embed=nextepisode          → _embedded.nextepisode
//!   - /shows/{id}/episodes                    → [{season,number,airdate,...}]

const std = @import("std");
const io = @import("../core/io_global.zig");
const http = @import("../core/http.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const pure = @import("tvmaze_pure.zig");

const alloc = @import("../core/alloc.zig").allocator;

// ── Module-level cache (protected by data_mutex). Keyed by the TMDB id we were
//    opened for, so re-opening the same show reuses the fetched data. ──
var data_mutex: sync.Mutex = .{};
var cached_tmdb_id: i32 = 0; // show these results belong to (0 = none)
var have_next: bool = false;
var next_ep: pure.NextEp = .{};
var air_entries: [1200]pure.AirEntry = undefined;
var air_count: usize = 0;

/// Bumped on every open; a worker only publishes if it is still the latest, so
/// fast show-switching never shows another show's air dates.
var gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
/// Concurrent-spawn guard (a second open before the first worker returns).
var busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// curl `url` into `buf`, returning bytes read (0 on failure). TVmaze is a
/// plain keyless HTTPS JSON API — no auth, no SNI-block dance needed.
fn curlInto(url: []const u8, buf: []u8) usize {
    var child = io.Child.init(&.{ "curl", "-s", "--max-time", "12", url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

/// Trigger a background TVmaze fetch for a freshly-opened TV show. No-op when
/// we already hold this show's data, when a fetch is in flight, or on an empty
/// title. Safe to call from the UI thread (openTvDetail).
pub fn onTvDetailOpen(tmdb_id: i32, title: []const u8) void {
    if (title.len == 0) return;

    // Already cached for this show? Nothing to do (guard read under the lock).
    data_mutex.lock();
    const cached = cached_tmdb_id == tmdb_id and (have_next or air_count > 0);
    data_mutex.unlock();
    if (cached) return;

    if (busy.swap(true, .acq_rel)) return; // a worker is already running

    // New generation; drop any stale published data immediately so the UI
    // doesn't show the previous show's "Next" line while the fetch runs.
    const my_gen = gen.fetchAdd(1, .acq_rel) + 1;
    data_mutex.lock();
    cached_tmdb_id = tmdb_id;
    have_next = false;
    next_ep = .{};
    air_count = 0;
    data_mutex.unlock();

    const S = struct {
        var id: i32 = 0;
        var g: u32 = 0;
        var title_buf: [256]u8 = undefined;
        var title_len: usize = 0;
    };
    S.id = tmdb_id;
    S.g = my_gen;
    const tl = @min(title.len, S.title_buf.len);
    @memcpy(S.title_buf[0..tl], title[0..tl]);
    S.title_len = tl;

    if (std.Thread.spawn(.{}, worker, .{ S.id, S.g, S.title_buf[0..S.title_len] })) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        busy.store(false, .release);
    }
}

fn worker(tmdb_id: i32, my_gen: u32, title: []const u8) void {
    defer busy.store(false, .release);

    const buf = alloc.alloc(u8, 512 * 1024) catch return;
    defer alloc.free(buf);

    // 1) Resolve the show by title → TVmaze id.
    var enc_buf: [512]u8 = undefined;
    const enc = http.urlEncode(title, &enc_buf); // percent-encodes query params
    var url_buf: [640]u8 = undefined;
    const search_url = std.fmt.bufPrint(&url_buf, "https://api.tvmaze.com/singlesearch/shows?q={s}", .{enc}) catch return;
    var n = curlInto(search_url, buf);
    if (n == 0) return;
    if (gen.load(.acquire) != my_gen) return; // superseded

    const show_id = pure.parseShowId(buf[0..n]) orelse {
        logs.pushLog("info", "tvmaze", "no TVmaze match for show", false);
        return;
    };

    // 2) Next episode (embed=nextepisode). Absent for ended shows.
    const next_url = std.fmt.bufPrint(&url_buf, "https://api.tvmaze.com/shows/{d}?embed=nextepisode", .{show_id}) catch return;
    n = curlInto(next_url, buf);
    if (gen.load(.acquire) != my_gen) return;
    var parsed_next: ?pure.NextEp = null;
    if (n > 0) parsed_next = pure.parseNextEpisode(buf[0..n]);

    // 3) Full episode list → per-(season,number) air-dates.
    const eps_url = std.fmt.bufPrint(&url_buf, "https://api.tvmaze.com/shows/{d}/episodes", .{show_id}) catch return;
    n = curlInto(eps_url, buf);
    if (gen.load(.acquire) != my_gen) return;

    // Publish under the lock, re-checking the generation so a newer open wins.
    data_mutex.lock();
    defer data_mutex.unlock();
    if (gen.load(.acquire) != my_gen) return;
    if (cached_tmdb_id != tmdb_id) return;

    if (parsed_next) |ne| {
        next_ep = ne;
        have_next = true;
    }
    if (n > 0) air_count = pure.parseEpisodesInto(buf[0..n], &air_entries);

    var lb: [96]u8 = undefined;
    logs.pushLog("info", "tvmaze", std.fmt.bufPrint(&lb, "TVmaze id={d}: {d} episode dates, next={}", .{ show_id, air_count, have_next }) catch "TVmaze loaded", false);
    state.wakeUi();
}

/// UI-thread read: the show-level "Next: SxEy · airs {date} · {countdown}" line
/// for the currently-open show, or null when there is no scheduled episode.
/// Writes into caller `buf`. Snapshots under the lock (cheap copy), releases,
/// then formats — never holds the lock across UI work.
pub fn nextLabel(tmdb_id: i32, buf: []u8) ?[]const u8 {
    data_mutex.lock();
    const ok = have_next and cached_tmdb_id == tmdb_id;
    const snap = next_ep;
    data_mutex.unlock();
    if (!ok) return null;
    return pure.formatNextLabel(io.timestamp(), snap, buf);
}

/// UI-thread read: TVmaze air-date ("YYYY-MM-DD") for (season, number) of the
/// currently-open show, or null when unknown. Copies into caller `buf`.
pub fn airdateFor(tmdb_id: i32, season: i32, number: i32, buf: []u8) ?[]const u8 {
    data_mutex.lock();
    defer data_mutex.unlock();
    if (cached_tmdb_id != tmdb_id or air_count == 0) return null;
    const found = pure.findAirdate(air_entries[0..air_count], season, number) orelse return null;
    const m = @min(found.len, buf.len);
    @memcpy(buf[0..m], found[0..m]);
    return buf[0..m];
}
