//! Watching — the library page for EVERYTHING trackable, and the metadata sync
//! that feeds its TV half.
//!
//! Three kinds land in one list: TV shows (tv_shows + the season map), anime
//! (anime_continue, modelled as a single flat season so the SAME engine answers
//! next-up), and movies/one-off video (watch_history percent). Only these three
//! have real persisted progress; comics and podcasts have no watched state at
//! all, so they are deliberately absent rather than faked.
//!
//! Two halves:
//!
//!   * **syncOnce()** — one background pass over the tracked shows, hitting TMDB's
//!     /3/tv/{id} for the season map, the series status, and the aired frontier,
//!     and persisting all of it to `tv_shows` + `tv_seasons`. This is the ONLY
//!     place that fetch happens; `tv_calendar` used to make the same call for the
//!     same shows and derive its own idea of what was unseen.
//!
//!   * **renderContent()** — the page. Every decision it shows (what's next, how
//!     far in you are, which bucket a show falls in, what order they appear in)
//!     comes from `tv_pure`, which is unit-tested in isolation. This file only
//!     *executes* those decisions — same split as transfers.zig/transfers_pure.zig.
//!
//! The snapshot is rebuilt on a dirty flag, NOT on a timer. Each row costs two
//! queries (the season map + every watched row), so polling 200 shows at the 2 Hz
//! the Downloads list uses would be ~800 queries/sec for data that only changes
//! when you actually watch something.

const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");
const logs = @import("../core/logs.zig");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const poster = @import("../core/poster.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("icons");
const tp = @import("tv_pure.zig");
const cal_pure = @import("tv_calendar_pure.zig");
const tmdb_api = @import("tmdb_api.zig");
const components = @import("../ui/components.zig");
const display_name = @import("../core/display_name_pure.zig");

pub const MAX_SHOWS = tp.MAX_SHOWS;

// ── Snapshot (UI thread owns these) ──
var rows: [MAX_SHOWS]tp.Row = std.mem.zeroes([MAX_SHOWS]tp.Row);
var order: [MAX_SHOWS]u16 = std.mem.zeroes([MAX_SHOWS]u16);
var row_count: usize = 0;
var filter: tp.Filter = .all;
var kind_filter: tp.KindFilter = .all;

/// Poster state, keyed by tmdb_id and NEVER reordered or freed.
///
/// Mirrored into TmdbItems so the shared poster daemon + its sqlite blob cache
/// can be reused as-is rather than duplicating that machinery (the same trick as
/// tv_calendar's cal_items).
///
/// Emphatically NOT index-aligned with `rows`: the snapshot re-sorts on every
/// watch commit, so slot N would start belonging to a different show — while a
/// detached poster worker still held a `*TmdbItem` into it. Resetting that slot
/// would hand the worker's pixel write to the wrong show at best, and free memory
/// out from under it at worst. Slots are claimed once per show and never recycled;
/// 200 posters is a bounded, acceptable cost.
var poster_items: [MAX_SHOWS]state.TmdbItem = std.mem.zeroes([MAX_SHOWS]state.TmdbItem);

/// Poster slot for a row, keyed by kind+id. Claimed once, never recycled.
fn posterFor(r: *const tp.Row) *state.TmdbItem {
    // Wyhash of kind+id gives a stable non-zero key across kinds, so an anime and
    // a TV show that happen to share a numeric id can't collide on one slot.
    const key: i32 = @bitCast(@as(u32, @truncate(std.hash.Wyhash.hash(0x7147, r.idSlice()) ^
        @as(u64, @intFromEnum(r.kind)) *% 0x9E3779B1)) | 1);

    for (&poster_items) |*it| {
        if (it.id == key) return it;
    }
    for (&poster_items) |*it| {
        if (it.id == 0) {
            it.id = key;
            return it;
        }
    }
    // Table full (>200 tracked items): degrade to a shared slot rather than crash
    // or start recycling slots out from under in-flight workers.
    return &poster_items[0];
}

/// Set by anything that changes what the library should show: a watch commit, a
/// watched toggle, a status change, or the sync worker publishing fresh metadata.
var library_dirty = std.atomic.Value(bool).init(true);

pub fn markDirty() void {
    library_dirty.store(true, .release);
}

// ══════════════════════════════════════════════════════════
// Sync — TMDB metadata for every tracked show
// ══════════════════════════════════════════════════════════

var syncing = std.atomic.Value(bool).init(false);
var synced_once: bool = false;

pub fn isSyncing() bool {
    return syncing.load(.acquire);
}

/// One background metadata refresh per session. Cheap no-op afterwards.
pub fn syncOnce() void {
    if (synced_once) return;
    // Same first-start race the trending fetch has: don't latch until the config
    // worker has published the API key (acquire), or a cold launch arms the latch
    // before the key exists and the sync never fires again this session.
    if (!state.app.config_loaded.load(.acquire)) return;
    if (state.app.tmdb.api_key_len == 0) return;
    synced_once = true;
    if (syncing.swap(true, .acq_rel)) return;
    (std.Thread.spawn(.{}, syncWorker, .{}) catch {
        syncing.store(false, .release);
        return;
    }).detach();
}

/// Force a refresh (Settings / manual retry). Ignores the once-per-session latch
/// but still refuses to run two syncs at a time.
pub fn resync() void {
    if (state.app.tmdb.api_key_len == 0) return;
    if (syncing.swap(true, .acq_rel)) return;
    (std.Thread.spawn(.{}, syncWorker, .{}) catch {
        syncing.store(false, .release);
        return;
    }).detach();
}

fn syncWorker() void {
    defer syncing.store(false, .release);

    var shows: [MAX_SHOWS]db.TvShowRow = undefined;
    const n = db.tvGetShows(&shows);
    if (n == 0) return;

    const key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];

    // 256KB — heap, not the thread stack. macOS spawned threads get 512KB, and
    // a buffer this size on the stack is a guaranteed overflow.
    const body = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(body);

    var seasons: [tp.MAX_SEASONS]tp.Season = undefined;
    var watched: [tp.MAX_WATCHED]tp.Ep = undefined;
    var updated: usize = 0;

    // The Home "Coming up" rail is built from this same pass — it used to make
    // the identical /3/tv/{id} call for the identical shows.
    const cal = @import("tv_calendar.zig");
    cal.beginStage();
    defer cal.endStage();

    // The doc is needed after the EZTV lookup clobbers the shared scratch buffer,
    // so the calendar gets its own buffer to scribble in.
    const scratch = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(scratch);

    for (shows[0..n]) |*sh| {
        if (sh.tmdb_id == 0) continue;

        var url_buf: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "/3/tv/{d}", .{sh.tmdb_id}) catch continue;
        const got = tmdb_api.tmdbApiInto(url, key, body);
        if (got == 0) continue;
        const doc = body[0..got];

        const last = cal_pure.parseEpisodeToAir(doc, "\"last_episode_to_air\":");
        const next = cal_pure.parseEpisodeToAir(doc, "\"next_episode_to_air\":");

        const last_ep = tp.Ep{
            .season = if (last) |l| l.season else 0,
            .episode = if (last) |l| l.episode else 0,
        };
        const next_ep = tp.Ep{
            .season = if (next) |x| x.season else 0,
            .episode = if (next) |x| x.episode else 0,
        };
        const next_air: i64 = if (next) |x| x.air_epoch else 0;
        const next_name: []const u8 = if (next) |*x| x.name[0..x.name_len] else "";

        const status: []const u8 = if (tp.parseEnded(doc)) "Ended" else "Returning Series";

        db.tvUpsertShow(
            sh.tmdb_id,
            sh.name[0..sh.name_len],
            sh.poster_path[0..sh.poster_path_len],
            status,
            last_ep,
            next_ep,
            next_air,
            next_name,
        );

        const ns = tp.parseSeasonMap(doc, &seasons);
        if (ns > 0) db.tvUpsertSeasons(sh.tmdb_id, seasons[0..ns]);

        // Stage the Coming-up rail from the SAME document + the SAME next-up
        // answer the library uses, so the two surfaces can never disagree.
        const nw = db.tvLoadWatchedAll(sh.tmdb_id, &watched);
        const la: ?tp.Ep = if (last_ep.season > 0) last_ep else null;
        const nxt = tp.nextUp(seasons[0..ns], watched[0..nw], la);
        cal.stage(
            sh.tmdb_id,
            sh.name[0..sh.name_len],
            sh.poster_path[0..sh.poster_path_len],
            doc,
            nxt,
            scratch,
        );

        updated += 1;
    }

    if (updated > 0) {
        markDirty();
        var msg: [64]u8 = undefined;
        const m = std.fmt.bufPrint(&msg, "Synced {d} show(s)", .{updated}) catch "Synced shows";
        logs.pushLog("info", "tv", m, false);
        state.wakeUi();
    }
}

// ══════════════════════════════════════════════════════════
// Snapshot — DB → rows, via tv_pure
// ══════════════════════════════════════════════════════════

/// The next episode of `tmdb_id`, across ALL seasons and clamped to what has
/// aired. This is the one entry point the rest of the app uses (the TV detail
/// Resume button calls it) — nothing re-derives "next".
pub fn nextUpFor(tmdb_id: i32) ?tp.Ep {
    var seasons: [tp.MAX_SEASONS]tp.Season = undefined;
    var watched: [tp.MAX_WATCHED]tp.Ep = undefined;

    const ns = db.tvLoadSeasons(tmdb_id, &seasons);
    if (ns == 0) return null;
    const nw = db.tvLoadWatchedAll(tmdb_id, &watched);

    var shows: [MAX_SHOWS]db.TvShowRow = undefined;
    const n = db.tvGetShows(&shows);
    var last_aired: ?tp.Ep = null;
    for (shows[0..n]) |*sh| {
        if (sh.tmdb_id == tmdb_id and sh.last_aired.season > 0) last_aired = sh.last_aired;
    }

    return tp.nextUp(seasons[0..ns], watched[0..nw], last_aired);
}

/// The most recently AIRED episode of `tmdb_id`, and whether it has been
/// watched. Null when the aired frontier is not known yet.
///
/// This is the "latest drop" the TV detail's Play-latest button targets, and is
/// deliberately NOT nextUpFor: the newest episode can already be watched (in
/// which case nextUp is null, or points at an older gap), and the button still
/// has to name it and say so. Watched-ness goes through `tp.isWatched` so the
/// button and the episode list can never disagree about the same episode.
pub fn lastAiredFor(tmdb_id: i32) ?struct { ep: tp.Ep, watched: bool } {
    var shows: [MAX_SHOWS]db.TvShowRow = undefined;
    const n = db.tvGetShows(&shows);
    var last_aired: ?tp.Ep = null;
    for (shows[0..n]) |*sh| {
        if (sh.tmdb_id == tmdb_id and sh.last_aired.season > 0) last_aired = sh.last_aired;
    }
    const la = last_aired orelse return null;

    var watched: [tp.MAX_WATCHED]tp.Ep = undefined;
    const nw = db.tvLoadWatchedAll(tmdb_id, &watched);
    return .{ .ep = la, .watched = tp.isWatched(watched[0..nw], la) };
}

/// The user's hand-set status for one item, or `.none`.
fn userStatusOf(kind: []const u8, id: []const u8) tp.UserStatus {
    var buf: [16]u8 = undefined;
    return tp.userStatusFromStr(db.libraryGetStatus(kind, id, &buf));
}

/// Is the player currently on a tracked TV episode? Gates the prev/next episode
/// buttons in the player control bar — they must not appear for a movie or a
/// one-off file, where "next episode" is meaningless.
pub fn playingEpisode() bool {
    return state.app.playing_episode.active and state.app.playing_episode.tmdb_id != 0;
}

/// The episode before/after the one now playing, or null at either end of the show.
/// `delta` is -1 (previous) or +1 (next).
pub fn neighborEpisode(delta: i32) ?tp.Ep {
    if (!playingEpisode()) return null;
    const pe = &state.app.playing_episode;

    var seasons: [tp.MAX_SEASONS]tp.Season = undefined;
    const ns = db.tvLoadSeasons(pe.tmdb_id, &seasons);
    if (ns == 0) return null; // no season map yet — we genuinely don't know

    const cur = tp.Ep{ .season = pe.season, .episode = pe.episode };

    if (delta < 0) return tp.episodeBefore(seasons[0..ns], cur);

    // Clamp "next" to what has aired, so the button never sends the resolver
    // hunting for an episode that doesn't exist yet.
    var shows: [MAX_SHOWS]db.TvShowRow = undefined;
    const n = db.tvGetShows(&shows);
    var last_aired: ?tp.Ep = null;
    for (shows[0..n]) |*sh| {
        if (sh.tmdb_id == pe.tmdb_id and sh.last_aired.season > 0) last_aired = sh.last_aired;
    }
    return tp.episodeAfter(seasons[0..ns], cur, last_aired);
}

/// Play the previous (-1) or next (+1) episode of the show now playing.
pub fn playNeighborEpisode(delta: i32) void {
    const pe = &state.app.playing_episode;
    const target = neighborEpisode(delta) orelse return;

    // The show's name/poster live on its tv_shows row, not on playing_episode.
    var shows: [MAX_SHOWS]db.TvShowRow = undefined;
    const n = db.tvGetShows(&shows);
    for (shows[0..n]) |*sh| {
        if (sh.tmdb_id != pe.tmdb_id) continue;
        @import("tmdb.zig").playEpisodeOf(
            sh.tmdb_id,
            sh.name[0..sh.name_len],
            sh.poster_path[0..sh.poster_path_len],
            target.season,
            target.episode,
            "",
        );
        return;
    }
}

/// Guards `rows` / `order` / `row_count`.
///
/// These were UI-thread-only until the web companion grew a Watching page:
/// `/api/library` runs on a server thread, and the snapshot re-sorts on every
/// watch commit, so an unguarded read there could walk a half-rebuilt array or
/// an `order` pointing at rows that just moved.
var snapshot_mutex: @import("../core/sync.zig").Mutex = .{};

fn buildSnapshotLocked() void {
    if (!library_dirty.load(.acquire)) return;
    library_dirty.store(false, .release);

    row_count = 0;
    addTvRows();
    addAnimeRows();
    addMovieRows();

    _ = tp.sortOrder(rows[0..row_count], &order);
}

/// Copy the library snapshot, in display order, into `out`. Returns how many
/// rows were written. Safe to call from any thread — the JSON API does.
///
/// Builds the snapshot itself when stale rather than relying on a render pass:
/// headless mode has no UI thread calling renderContent, so the web page would
/// otherwise see an empty library forever.
///
/// `out` is ~600 bytes/row — heap-allocate it. A 200-row buffer on a spawned
/// thread's stack blows the budget (see CLAUDE.md).
pub fn snapshotCopy(out: []tp.Row) usize {
    snapshot_mutex.lock();
    defer snapshot_mutex.unlock();
    buildSnapshotLocked();
    const n = @min(out.len, row_count);
    for (0..n) |i| out[i] = rows[order[i]];
    return n;
}

// ══════════════════════════════════════════════════════════
// Commands — shared by native and web library surfaces
// ══════════════════════════════════════════════════════════

pub const ItemRef = struct {
    kind: tp.Kind,
    id: []const u8,
};

pub const Action = enum { status, watched, remove, refresh };

/// A small typed seam over the source-specific persistence below. HTTP callers
/// never choose a table or issue SQL, and future clients can reuse the same
/// validation and semantics.
pub const Command = union(Action) {
    status: struct { item: ItemRef, value: tp.UserStatus },
    watched: struct { item: ItemRef, episode: tp.Ep, value: bool },
    remove: ItemRef,
    refresh,
};

pub const CommandError = error{ ItemNotFound, InvalidEpisode, Unsupported };
pub const MAX_EPISODES_PER_SEASON: usize = @intCast(tp.MAX_EPISODES_PER_SEASON);

fn itemExistsLocked(item: ItemRef) bool {
    if (item.id.len == 0 or item.id.len > (tp.Row{}).id.len) return false;
    buildSnapshotLocked();
    for (rows[0..row_count]) |*r| {
        if (r.kind == item.kind and std.mem.eql(u8, r.idSlice(), item.id)) return true;
    }
    return false;
}

fn tvId(item: ItemRef) CommandError!i32 {
    const id = std.fmt.parseInt(i32, item.id, 10) catch return error.ItemNotFound;
    if (id <= 0) return error.ItemNotFound;
    return id;
}

/// Apply one authenticated library mutation. Episode watched state is allowed
/// for an untracked TV show because the native detail view permits the same
/// action; status/removal require a current library row so stale browser cards
/// cannot mutate an item that has since disappeared.
pub fn apply(command: Command) CommandError!void {
    switch (command) {
        .watched => |cmd| {
            if (cmd.item.id.len == 0 or cmd.item.id.len > (tp.Row{}).id.len)
                return error.ItemNotFound;
            if (!tp.validUserEpisode(cmd.episode)) return error.InvalidEpisode;
            switch (cmd.item.kind) {
                .tv => db.tvMarkWatched(
                    try tvId(cmd.item),
                    @intCast(cmd.episode.season),
                    @intCast(cmd.episode.episode),
                    cmd.value,
                ),
                .anime => {
                    if (cmd.episode.season != 1) return error.InvalidEpisode;
                    db.animeMarkWatched(cmd.item.id, @intCast(cmd.episode.episode), cmd.value);
                },
                .movie => return error.Unsupported,
            }
            markDirty();
        },
        .status => |cmd| {
            snapshot_mutex.lock();
            defer snapshot_mutex.unlock();
            if (!itemExistsLocked(cmd.item)) return error.ItemNotFound;
            db.librarySetStatus(@tagName(cmd.item.kind), cmd.item.id, tp.userStatusToStr(cmd.value));
            markDirty();
        },
        .remove => |item| {
            snapshot_mutex.lock();
            defer snapshot_mutex.unlock();
            if (!itemExistsLocked(item)) return error.ItemNotFound;
            switch (item.kind) {
                .tv => db.tvSetTracked(try tvId(item), false),
                .anime => db.animeRemoveContinue(item.id),
                // watch_history's cache is UI-thread-owned. Mutating it from an
                // HTTP worker would race the native grid, so movie history stays
                // unavailable here until that store owns a synchronized command.
                .movie => return error.Unsupported,
            }
            markDirty();
        },
        .refresh => resync(),
    }
}

/// Copy watched episode numbers for one season. The fixed bound matches the
/// command validator and the app's anime tracking capacity.
pub fn watchedEpisodes(kind: tp.Kind, id: []const u8, season: i32, out: []u32) CommandError!usize {
    if (id.len == 0 or id.len > (tp.Row{}).id.len) return error.ItemNotFound;
    if (!tp.validUserEpisode(.{ .season = season, .episode = 1 })) return error.InvalidEpisode;
    if (kind == .movie) return error.Unsupported;

    var flags: [MAX_EPISODES_PER_SEASON]bool = std.mem.zeroes([MAX_EPISODES_PER_SEASON]bool);
    switch (kind) {
        .tv => db.tvLoadWatched(try tvId(.{ .kind = kind, .id = id }), @intCast(season), &flags),
        .anime => {
            if (season != 1) return error.InvalidEpisode;
            db.animeLoadWatched(id, &flags);
        },
        .movie => unreachable,
    }

    var n: usize = 0;
    for (flags, 0..) |is_watched, i| {
        if (!is_watched or n >= out.len) continue;
        out[n] = @intCast(i + 1);
        n += 1;
    }
    return n;
}

fn nextRow() ?*tp.Row {
    if (row_count >= rows.len) return null;
    const r = &rows[row_count];
    r.* = .{};
    row_count += 1;
    return r;
}

// ── TV ──
fn addTvRows() void {
    var shows: [MAX_SHOWS]db.TvShowRow = undefined;
    const n = db.tvGetShows(&shows);

    var seasons: [tp.MAX_SEASONS]tp.Season = undefined;
    var watched: [tp.MAX_WATCHED]tp.Ep = undefined;

    for (shows[0..n]) |*sh| {
        if (sh.tmdb_id == 0) continue;

        const ns = db.tvLoadSeasons(sh.tmdb_id, &seasons);
        const nw = db.tvLoadWatchedAll(sh.tmdb_id, &watched);

        // A show with no season map yet still gets a row — it reads "Not synced
        // yet" until the sync lands. Dropping it would make the library look empty
        // on a first run, which is worse than an unknown count.
        const last_aired: ?tp.Ep = if (sh.last_aired.season > 0) sh.last_aired else null;
        const nxt = tp.nextUp(seasons[0..ns], watched[0..nw], last_aired);
        const prog = tp.progress(seasons[0..ns], watched[0..nw], last_aired);

        const r = nextRow() orelse return;
        r.kind = .tv;
        r.tmdb_id = sh.tmdb_id;
        r.setName(sh.name[0..sh.name_len]);
        r.setPoster(sh.poster_path[0..sh.poster_path_len]);
        r.ended = sh.ended;
        r.next_air_epoch = sh.next_air_epoch;
        r.updated_at = sh.updated_at;
        r.prog = prog;
        if (nxt) |e| {
            r.next = e;
            r.has_next = true;
            r.resume_secs = db.tvGetPosition(sh.tmdb_id, e.season, e.episode);
        }

        var idb: [24]u8 = undefined;
        r.setId(std.fmt.bufPrint(&idb, "{d}", .{sh.tmdb_id}) catch "");

        var ub: [160]u8 = undefined;
        r.setPosterUrl(std.fmt.bufPrint(&ub, "https://image.tmdb.org/t/p/w185{s}", .{r.posterSlice()}) catch "");

        r.user = userStatusOf("tv", r.idSlice());
        r.status = tp.effectiveStatus(r.user, tp.statusOf(prog, nxt, sh.ended));
    }
}

// ── Anime ──
//
// Anime is episodic but flat: `anime_continue` carries total_episodes and
// `anime_watched` per-episode flags, with no seasons. Model it as a single
// season so the SAME engine answers next-up and progress — a second, parallel
// "what's next for anime" implementation is exactly the drift this whole
// subsystem exists to prevent.
fn addAnimeRows() void {
    var items: [64]state.ContinueItem = undefined;
    const n = db.animeGetContinue(&items);

    for (items[0..n]) |*ci| {
        const mal = ci.mal_id[0..@min(ci.mal_id_len, ci.mal_id.len)];
        if (mal.len == 0) continue;

        const total: u16 = ci.total_episodes;

        var flags: [512]bool = std.mem.zeroes([512]bool);
        const cap = @min(@as(usize, total), flags.len);
        db.animeLoadWatched(mal, flags[0..@max(cap, 1)]);

        var watched_eps: [512]tp.Ep = undefined;
        var nw: usize = 0;
        for (flags[0..cap], 0..) |on, i| {
            if (!on) continue;
            watched_eps[nw] = .{ .season = 1, .episode = @intCast(i + 1) };
            nw += 1;
        }

        const seasons = [_]tp.Season{.{ .number = 1, .episode_count = total }};
        // No aired frontier for anime (Jikan doesn't give one here), so nothing is
        // clamped — per airedInSeason's rule, unknown must not clamp, or a running
        // series would read "caught up" forever.
        const map: []const tp.Season = if (total > 0) seasons[0..] else &.{};
        const nxt = tp.nextUp(map, watched_eps[0..nw], null);
        const prog = tp.progress(map, watched_eps[0..nw], null);

        const r = nextRow() orelse return;
        r.kind = .anime;
        r.setName(ci.title[0..@min(ci.title_len, ci.title.len)]);
        r.setId(mal);
        r.setPosterUrl(ci.poster_url[0..@min(ci.poster_url_len, ci.poster_url.len)]);
        r.prog = prog;
        if (nxt) |e| {
            r.next = e;
            r.has_next = true;
        }
        r.user = userStatusOf("anime", mal);
        // Anime has no "returning vs ended" signal here, so a fully-watched series
        // reads caught_up rather than completed unless the user says otherwise.
        r.status = tp.effectiveStatus(r.user, tp.statusOf(prog, nxt, false));
    }
}

// ── Movies / one-off video ──
//
// Sourced from watch_history (percent-based). Episodes are EXCLUDED: a TV episode
// played from a torrent also lands in watch_history under its release name, and
// listing it here would duplicate the show it belongs to under a second, worse
// identity. `subtitles_pure.findSxxEyy` is the existing, tested SxxExx detector —
// reused rather than re-rolled.
fn addMovieRows() void {
    const watch = @import("../player/watch_history.zig");
    const subs = @import("subtitles_pure.zig");

    var qbuf: [256]u8 = undefined;
    var showbuf: [128]u8 = undefined;

    var i: usize = 0;
    while (i < watch.count and i < watch.entries.len) : (i += 1) {
        const e = &watch.entries[i];
        const name = e.name[0..@min(e.name_len, e.name.len)];
        if (name.len == 0) continue;
        if (e.link_len == 0) continue;
        // `parse` is the public, tested entry point; `is_tv` is true exactly when
        // it found an SxxEyy. An episode belongs to its show, not here.
        if (subs.parse(name, &qbuf, &showbuf).is_tv) continue;

        const r = nextRow() orelse return;
        r.kind = .movie;
        var display_buf: [256]u8 = undefined;
        r.setName(display_name.clean(&display_buf, name));
        r.setId(name);
        r.hist_idx = @intCast(i);
        r.pct = @floatCast(e.percent);
        r.prog = .{
            .watched = @intFromFloat(@max(0, @min(100, e.percent))),
            .total = 100,
        };
        r.user = userStatusOf("movie", name);
        r.status = tp.effectiveStatus(r.user, tp.statusOfMovie(r.pct));
    }
}

// ══════════════════════════════════════════════════════════
// UI
// ══════════════════════════════════════════════════════════

const CARD_W: f32 = 150;
const POSTER_H: f32 = CARD_W * 1.5;

pub fn renderContent() void {
    syncOnce();
    // Hold the snapshot lock for the whole frame's read. buildSnapshot alone
    // isn't enough: warmNextUp / renderControlBar / renderGrid all iterate
    // `rows` and `order` afterwards, and /api/library on the server thread can
    // trigger a rebuild (and re-sort) in between. Contention is effectively
    // zero — one rare reader — and nothing below re-enters this module.
    snapshot_mutex.lock();
    defer snapshot_mutex.unlock();
    buildSnapshotLocked();
    warmNextUp();

    // Release feed + live countdown. Periodically refreshed (15 min), and fully
    // inert unless the eztv source plugin is installed — its endpoints live in
    // the plugin config, never in the binary.
    const eztv = @import("eztv_calendar.zig");
    eztv.refreshTick();

    renderControlBar();

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_app,
        .gravity_y = 0,
    });
    defer scroll.deinit();

    if (row_count == 0) {
        renderEmpty();
    } else {
        renderLibrary();
    }

    // Discovery is useful, but it is not the user's library. Keep the optional
    // release feed below personal progress so opening Watching always answers
    // "what should I continue?" first.
    eztv.renderSection();
}

fn renderControlBar() void {
    var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_app,
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.md, .w = theme.spacing.lg, .h = theme.spacing.sm },
    });
    defer bar.deinit();

    var counts: [6]usize = .{ 0, 0, 0, 0, 0, 0 };
    tp.countsFor(rows[0..row_count], kind_filter, &counts);

    // Page identity + one useful summary. Counts no longer repeat inside every
    // chip, which made the old toolbar read like a diagnostic panel.
    {
        var mast = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer mast.deinit();
        {
            var copy = dvui.box(@src(), .{ .dir = .vertical }, .{});
            defer copy.deinit();
            _ = dvui.label(@src(), "Watching", .{}, .{
                .color_text = theme.colors.text_primary,
                .font = dvui.themeGet().font_heading,
            });
            var summary_buf: [96]u8 = undefined;
            const summary = std.fmt.bufPrint(&summary_buf, "{d} titles · {d} ready to continue", .{
                counts[@intFromEnum(tp.Filter.all)],
                counts[@intFromEnum(tp.Filter.watching)],
            }) catch "Your saved progress";
            _ = dvui.label(@src(), "{s}", .{summary}, .{
                .color_text = theme.colors.text_tertiary,
                .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
            });
        }
        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }
        if (isSyncing()) {
            _ = dvui.label(@src(), "Refreshing metadata…", .{}, .{
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
            });
        } else if (dvui.button(@src(), "Refresh", .{}, .{
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .color_fill_hover = theme.colors.bg_hover,
            .color_text = theme.colors.text_secondary,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
        })) {
            resync();
        }
    }

    // One calm toolbar. Each control is a segmented group rather than ten
    // unrelated pills, and the pair wraps as units on narrow windows.
    var filters = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
    });
    defer filters.deinit();
    {
        var group = dvui.box(@src(), .{ .dir = .vertical }, .{
            .max_size_content = .{ .w = 340, .h = std.math.floatMax(f32) },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.md, .h = theme.spacing.xs },
        });
        defer group.deinit();
        _ = dvui.label(@src(), "TYPE", .{}, .{ .color_text = theme.colors.text_tertiary });
        const labels = [_][]const u8{ "All", "TV", "Anime", "Movies" };
        if (components.segment(@src(), &labels, @intFromEnum(kind_filter))) |picked|
            kind_filter = @enumFromInt(picked);
    }
    {
        var group = dvui.box(@src(), .{ .dir = .vertical }, .{
            .max_size_content = .{ .w = 620, .h = std.math.floatMax(f32) },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.xs },
        });
        defer group.deinit();
        _ = dvui.label(@src(), "PROGRESS", .{}, .{ .color_text = theme.colors.text_tertiary });
        const labels = [_][]const u8{ "All", "In progress", "Caught up", "Planned", "Done", "Dropped" };
        if (components.segment(@src(), &labels, @intFromEnum(filter))) |picked|
            filter = @enumFromInt(picked);
    }
}

fn renderEmpty() void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = dvui.Rect.all(theme.spacing.lg),
        .margin = .{ .x = theme.spacing.lg, .y = theme.spacing.md, .w = theme.spacing.lg, .h = theme.spacing.lg },
    });
    defer box.deinit();

    _ = dvui.label(@src(), "Nothing here yet", .{}, .{
        .id_extra = 62000,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
    });
    _ = dvui.label(@src(), "Save a show or movie and your next episode and progress will appear here.", .{}, .{
        .id_extra = 62001,
        .color_text = theme.colors.text_tertiary,
        .padding = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.md },
    });

    if (dvui.button(@src(), "Browse movies & TV", .{}, .{
        .id_extra = 62002,
        .background = true,
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.text_on_accent,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
    })) {
        state.app.browse_source = .TMDB;
        state.app.router.navigate(.browse);
    }
}

const LibraryBucket = enum { all, up_next, saved };

fn inBucket(r: *const tp.Row, bucket: LibraryBucket) bool {
    return switch (bucket) {
        .all => true,
        .up_next => tp.isUpNext(r),
        .saved => !tp.isUpNext(r),
    };
}

fn visibleCount(bucket: LibraryBucket) usize {
    var count: usize = 0;
    for (order[0..row_count]) |idx| {
        if (tp.visible(&rows[idx], filter, kind_filter) and inBucket(&rows[idx], bucket)) count += 1;
    }
    return count;
}

fn renderLibrary() void {
    const is_default = filter == .all and kind_filter == .all;
    if (!is_default) {
        const count = visibleCount(.all);
        if (count == 0) {
            renderFilteredEmpty();
            return;
        }
        renderSectionHeading("Filtered library", count, "titles");
        renderGrid(.all);
        return;
    }

    const up_next = visibleCount(.up_next);
    const saved = visibleCount(.saved);

    if (up_next > 0) {
        renderSectionHeading("Up next", up_next, "ready");
        renderUpNextRail();
    }
    if (saved > 0) {
        renderSectionHeading("Your library", saved, "saved");
        renderGrid(.saved);
    }
}

fn renderSectionHeading(title: []const u8, count: usize, suffix: []const u8) void {
    var heading = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.md, .w = theme.spacing.lg, .h = theme.spacing.xs },
    });
    defer heading.deinit();

    _ = dvui.label(@src(), "{s}", .{title}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_body.withSize(theme.font_size.title),
        .gravity_y = 0.5,
    });
    _ = dvui.label(@src(), "{d} {s}", .{ count, suffix }, .{
        .color_text = theme.colors.text_tertiary,
        .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
        .gravity_y = 0.5,
        .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
    });
}

fn renderUpNextRail() void {
    const media_card = @import("../ui/media_card.zig");
    var rail = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none, .horizontal_bar = .hide }, .{
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .w = 10, .h = media_card.cardHeight(true, true) + 12 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = std.math.floatMax(f32) },
        .padding = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = 0 },
        .gravity_y = 0,
    });
    defer rail.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0 });
    defer row.deinit();
    for (order[0..row_count]) |idx| {
        if (!tp.visible(&rows[idx], filter, kind_filter) or !inBucket(&rows[idx], .up_next)) continue;
        renderCard(idx, idx);
    }
}

fn renderFilteredEmpty() void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = dvui.Rect.all(theme.spacing.lg),
        .margin = .{ .x = theme.spacing.lg, .y = theme.spacing.md, .w = theme.spacing.lg, .h = theme.spacing.lg },
    });
    defer box.deinit();

    _ = dvui.label(@src(), "No titles match these filters", .{}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
    });
    if (dvui.button(@src(), "Clear filters", .{}, .{
        .color_fill = theme.colors.bg_elevated,
        .color_fill_hover = theme.colors.bg_hover,
        .color_text = theme.colors.text_primary,
        .border = dvui.Rect.all(0),
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
    })) {
        filter = .all;
        kind_filter = .all;
    }
}

fn renderGrid(bucket: LibraryBucket) void {
    const avail_w = dvui.parentGet().data().contentRect().w;
    const per_card = CARD_W + 12;
    const cols: usize = @max(1, @as(usize, @intFromFloat(@max(1, avail_w / per_card))));

    var grid = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = dvui.Rect.all(theme.spacing.sm),
        .gravity_y = 0,
    });
    defer grid.deinit();

    // Visible rows only, in sorted order.
    var visible: [MAX_SHOWS]u16 = undefined;
    var vn: usize = 0;
    for (order[0..row_count]) |idx| {
        if (!tp.visible(&rows[idx], filter, kind_filter) or !inBucket(&rows[idx], bucket)) continue;
        visible[vn] = idx;
        vn += 1;
    }

    var i: usize = 0;
    var row_i: usize = 0;
    while (i < vn) : (row_i += 1) {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_i + 63000,
            .expand = .horizontal,
            .gravity_y = 0,
        });
        defer hrow.deinit();

        var col: usize = 0;
        while (col < cols and i < vn) : (col += 1) {
            // Row identity is unique across the Up-next rail and this grid;
            // a per-section ordinal can collide with a card rendered above.
            renderCard(visible[i], visible[i]);
            i += 1;
        }
    }
}

fn renderCard(idx: usize, slot: usize) void {
    const r = &rows[idx];
    const media_card = @import("../ui/media_card.zig");

    // Movies count in percent; episodes count in episodes. "42/100 episodes" is
    // nonsense.
    var cbuf: [16]u8 = undefined;
    const prog_label: []const u8 = if (r.prog.total == 0)
        ""
    else if (r.kind == .movie)
        (std.fmt.bufPrint(&cbuf, "{d:.0}%", .{r.pct}) catch "")
    else
        (std.fmt.bufPrint(&cbuf, "{d}/{d}", .{ r.prog.watched, r.prog.total }) catch "");

    var sbuf: [48]u8 = undefined;

    const click = media_card.render(@src(), slot + 64000, posterFor(r), .{
        .poster_url = r.posterUrlSlice(),
        .title = r.nameSlice(),
        .subtitle = tp.statusLabel(r, &sbuf),
        .subtitle_accent = r.has_next or
            (r.kind == .movie and r.pct >= tp.MOVIE_START_PCT and r.pct < tp.MOVIE_DONE_PCT),
        .progress = if (r.prog.total > 0) r.prog.fraction() else null,
        .progress_label = prog_label,
        .action_label = playLabel(r),
        .removable = true,
    });

    switch (click) {
        .none => {},
        .open => openRow(r),
        .action => playRow(r),
        .remove => removeRow(r),
    }
}

/// Drop a row from the Watching page.
///
/// Each kind lives in a different store, so "remove" means a different call for
/// each — but none of them destroys watch progress. TV un-tracks the show
/// (tvGetShows filters on `tracked <> 0`), anime deletes only its
/// continue-watching row, and a movie drops its watch-history entry. Per-episode
/// watched flags are left alone in every case, so re-adding a show later does
/// not silently reset how far the user had got.
/// Warm the search cache for the next episode of the first show that has one.
///
/// Opening Watching is the strongest signal available that the user is about to
/// press play on something here, and the search that follows is always cold —
/// SWR only caches as a side effect of a search that already happened. This
/// spends one background lookup so that press is instant.
///
/// Deliberately ONE show, once per page visit, on a detached thread: this is
/// speculative work for something the user has not asked for, so it must not
/// turn opening a page into a burst of network traffic. resolver.warmQuery
/// writes to a private sink, so it cannot disturb whatever the user searches
/// next (that is exactly what the sink exists for).
fn warmNextUp() void {
    const S = struct {
        var done: bool = false;
        var busy: bool = false;
        var q: [256]u8 = std.mem.zeroes([256]u8);
        var qlen: usize = 0;

        fn run() void {
            defer busy = false;
            @import("resolver.zig").warmQuery(q[0..qlen]);
        }
    };
    if (S.done or S.busy) return;

    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const r = &rows[i];
        if (r.kind != .tv or !r.has_next) continue;
        const name = r.nameSlice();
        if (name.len == 0) continue;
        const q = std.fmt.bufPrint(&S.q, "{s} S{d:0>2}E{d:0>2}", .{
            name, r.next.season, r.next.episode,
        }) catch return;
        S.qlen = q.len;
        S.done = true;
        S.busy = true;
        if (std.Thread.spawn(.{}, S.run, .{})) |t| {
            t.detach();
        } else |_| {
            S.busy = false;
        }
        return;
    }
    // Nothing to warm — don't re-scan the list on every repaint.
    if (row_count > 0) S.done = true;
}

fn removeRow(r: *const tp.Row) void {
    switch (r.kind) {
        .tv => {
            if (r.tmdb_id == 0) return;
            db.tvSetTracked(r.tmdb_id, false);
        },
        .anime => {
            const mal = r.id[0..@min(r.id_len, r.id.len)];
            if (mal.len == 0) return;
            db.animeRemoveContinue(mal);
        },
        .movie => {
            // hist_idx is an index into a live array, so it is only valid for
            // this frame's snapshot — remove immediately and rebuild.
            if (r.hist_idx < 0) return;
            @import("../player/watch_history.zig").remove(@intCast(r.hist_idx));
        },
    }
    // The snapshot is cached until something marks it stale; without this the
    // card stays on screen until an unrelated change happens to invalidate it.
    library_dirty.store(true, .release);
    state.showToast("Removed from Watching");
    dvui.refresh(null, @src(), null);
}

/// The play button's label, or null when this row has nothing playable.
fn playLabel(r: *const tp.Row) ?[]const u8 {
    switch (r.kind) {
        .tv => {
            if (!r.has_next) return null;
            if (r.prog.watched == 0) return "Start";
            return if (r.resume_secs > 2) "Resume" else "Play next";
        },
        .movie => {
            if (r.hist_idx < 0) return null;
            if (r.pct >= tp.MOVIE_DONE_PCT) return "Watch again";
            return if (r.pct >= tp.MOVIE_START_PCT) "Resume" else "Play";
        },
        // Anime playback runs through the Anime tab's own resolver/episode flow,
        // which needs the show loaded in that page's state. Rather than fake a
        // play path that would silently pick the wrong source, the card opens the
        // Anime tab. Honest limitation, called out rather than papered over.
        .anime => return null,
    }
}

fn openRow(r: *const tp.Row) void {
    switch (r.kind) {
        .tv => @import("tmdb.zig").openTvDetailById(r.tmdb_id, r.nameSlice(), r.posterSlice()),
        .anime => state.navigateToTab(.Anime),
        .movie => playRow(r),
    }
}

fn playRow(r: *const tp.Row) void {
    switch (r.kind) {
        .tv => {
            if (!r.has_next) return;
            @import("tmdb.zig").playEpisodeOf(
                r.tmdb_id,
                r.nameSlice(),
                r.posterSlice(),
                r.next.season,
                r.next.episode,
                "",
            );
        },
        .movie => {
            const watch = @import("../player/watch_history.zig");
            if (r.hist_idx < 0) return;
            const i: usize = @intCast(r.hist_idx);
            if (i >= watch.count or i >= watch.entries.len) return; // history moved under us
            const e = &watch.entries[i];
            const link = e.link[0..@min(e.link_len, e.link.len)];
            if (link.len == 0) return;
            @import("browser.zig").resumePlayback(link);
        },
        .anime => state.navigateToTab(.Anime),
    }
}
