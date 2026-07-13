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

fn buildSnapshot() void {
    if (!library_dirty.load(.acquire)) return;
    library_dirty.store(false, .release);

    row_count = 0;
    addTvRows();
    addAnimeRows();
    addMovieRows();

    _ = tp.sortOrder(rows[0..row_count], &order);
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
        r.setName(name);
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
const CARD_CHROME: f32 = 74; // title + status line + progress bar

pub fn renderContent() void {
    syncOnce();
    buildSnapshot();

    // Release feed + live countdown. Periodically refreshed (15 min), and fully
    // inert unless the eztv source plugin is installed — its endpoints live in
    // the plugin config, never in the binary.
    const eztv = @import("eztv_calendar.zig");
    eztv.refreshTick();

    renderControlBar();

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    // Renders nothing when the plugin is absent or the feed is empty.
    eztv.renderSection();

    if (row_count == 0) {
        renderEmpty();
        return;
    }
    renderGrid();
}

fn renderControlBar() void {
    var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
    });
    defer bar.deinit();

    // Counts are cross-scoped: the status counts are computed WITHIN the active
    // kind and vice-versa, so both rows always add up to what's actually on
    // screen. A count that disagrees with the list is worse than no count.
    var counts: [6]usize = .{ 0, 0, 0, 0, 0, 0 };
    tp.countsFor(rows[0..row_count], kind_filter, &counts);
    var kcounts: [4]usize = .{ 0, 0, 0, 0 };
    tp.kindCountsFor(rows[0..row_count], filter, &kcounts);

    // ── Kind row: All / TV / Anime / Movies ──
    {
        var krow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer krow.deinit();

        const kinds = [_]tp.KindFilter{ .all, .tv, .anime, .movie };
        const knames = [_][]const u8{ "All", "TV", "Anime", "Movies" };
        for (kinds, 0..) |k, i| {
            var lbuf: [32]u8 = undefined;
            const lbl = std.fmt.bufPrint(&lbuf, "{s} ({d})", .{ knames[i], kcounts[i] }) catch knames[i];
            const sel = kind_filter == k;
            if (dvui.button(@src(), lbl, .{}, .{
                .id_extra = i + 60800,
                .background = true,
                .color_fill = if (sel) theme.colors.accent else theme.colors.bg_elevated,
                .color_text = if (sel) theme.colors.text_on_accent else theme.colors.text_secondary,
                .corner_radius = dvui.Rect.all(theme.radius.pill),
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            })) kind_filter = k;
        }

        if (isSyncing()) {
            _ = dvui.label(@src(), "Syncing...", .{}, .{
                .id_extra = 61500,
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
        }
    }

    // ── Status row: All / Watching / Caught up / Not started / Completed / Dropped ──
    {
        var srow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
        });
        defer srow.deinit();

        const chips = [_]tp.Filter{ .all, .watching, .caught_up, .unstarted, .completed, .dropped };
        const names = [_][]const u8{ "All", "Watching", "Caught up", "Not started", "Completed", "Dropped" };
        for (chips, 0..) |f, k| {
            var lbuf: [40]u8 = undefined;
            const lbl = std.fmt.bufPrint(&lbuf, "{s} ({d})", .{ names[k], counts[k] }) catch names[k];
            const sel = filter == f;
            if (dvui.button(@src(), lbl, .{}, .{
                .id_extra = k + 61000,
                .background = true,
                .color_fill = if (sel) theme.colors.bg_hover else theme.colors.bg_surface,
                .color_text = if (sel) theme.colors.text_primary else theme.colors.text_tertiary,
                .corner_radius = dvui.Rect.all(theme.radius.pill),
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
                .padding = .{ .x = theme.spacing.sm, .y = 2, .w = theme.spacing.sm, .h = 2 },
            })) filter = f;
        }
    }
}

fn renderEmpty() void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    defer box.deinit();

    _ = dvui.label(@src(), "Nothing tracked yet", .{}, .{
        .id_extra = 62000,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
        .gravity_x = 0.5,
    });
    _ = dvui.label(@src(), "Play an episode, or set a status on any show or movie — it lands here with your progress.", .{}, .{
        .id_extra = 62001,
        .color_text = theme.colors.text_tertiary,
        .gravity_x = 0.5,
    });
}

fn renderGrid() void {
    const avail_w = dvui.parentGet().data().contentRect().w;
    const per_card = CARD_W + 12;
    const cols: usize = @max(1, @as(usize, @intFromFloat(@max(1, avail_w / per_card))));

    var grid = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = dvui.Rect.all(theme.spacing.sm),
    });
    defer grid.deinit();

    // Visible rows only, in sorted order.
    var visible: [MAX_SHOWS]u16 = undefined;
    var vn: usize = 0;
    for (order[0..row_count]) |idx| {
        if (!tp.visible(&rows[idx], filter, kind_filter)) continue;
        visible[vn] = idx;
        vn += 1;
    }

    if (vn == 0) {
        _ = dvui.label(@src(), "Nothing in this filter.", .{}, .{
            .id_extra = 62100,
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
        });
        return;
    }

    var i: usize = 0;
    var row_i: usize = 0;
    while (i < vn) : (row_i += 1) {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = row_i + 63000,
            .expand = .horizontal,
        });
        defer hrow.deinit();

        var col: usize = 0;
        while (col < cols and i < vn) : (col += 1) {
            renderCard(visible[i], i);
            i += 1;
        }
    }
}

fn renderCard(idx: usize, slot: usize) void {
    const r = &rows[idx];
    const it = posterFor(r);

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = slot + 64000,
        .min_size_content = .{ .w = CARD_W, .h = POSTER_H + CARD_CHROME },
        .max_size_content = .{ .w = CARD_W, .h = POSTER_H + CARD_CHROME },
        .margin = dvui.Rect.all(6),
    });
    defer card.deinit();

    // -- Poster (click opens the item) --
    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = slot + 64100,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(8),
            .min_size_content = .{ .w = CARD_W, .h = POSTER_H },
            .max_size_content = .{ .w = CARD_W, .h = POSTER_H },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();
        if (bw.clicked()) openRow(r);

        if (poster.uploadIfReady(&it.poster_pixels, it.poster_w, it.poster_h, &it.poster_tex)) {
            if (it.poster_tex) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = slot + 64200,
                    .expand = .both,
                    .corner_radius = dvui.Rect.all(8),
                });
            }
        } else {
            // Full attempted -> failed transition. Gating on !failed without ever
            // SETTING it is how the TMDB grid used to re-spawn a fetch for a dead
            // poster on every single frame.
            const url = r.posterUrlSlice();
            if (it.poster_fetching) {
                it.poster_attempted = true;
            } else if (it.poster_attempted and it.poster_pixels == null and it.poster_tex == null) {
                it.poster_failed = true;
            } else if (!it.poster_failed and it.poster_pixels == null and url.len > 0) {
                // fetchAsync by URL, not tmdb_api.fetchPoster: anime posters are
                // absolute URLs, not TMDB paths. One code path for every kind.
                poster.fetchAsync(url, &it.poster_pixels, &it.poster_w, &it.poster_h, &it.poster_fetching);
                if (it.poster_fetching) it.poster_attempted = true;
            }
        }
        bw.deinit();
    }

    // -- Title --
    _ = dvui.label(@src(), "{s}", .{r.nameSlice()}, .{
        .id_extra = slot + 64300,
        .color_text = theme.colors.text_primary,
        .expand = .horizontal,
        .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
    });

    // -- Status line --
    {
        var sbuf: [48]u8 = undefined;
        const s_lbl = tp.statusLabel(r, &sbuf);
        _ = dvui.label(@src(), "{s}", .{s_lbl}, .{
            .id_extra = slot + 64400,
            .color_text = if (r.has_next or (r.kind == .movie and r.pct >= tp.MOVIE_START_PCT and r.pct < tp.MOVIE_DONE_PCT))
                theme.colors.accent
            else
                theme.colors.text_tertiary,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 2 },
        });
    }

    // -- Progress bar + count --
    if (r.prog.total > 0) {
        var pbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = slot + 64500,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 2 },
        });
        defer pbox.deinit();

        // Manual track + fill, not dvui.progress/slider: the slider is DRAGGABLE
        // and takes the control-blue fill rather than the theme accent (that's the
        // stray blue bar the TV detail's season header used to show).
        {
            var track = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = slot + 64510,
                .expand = .horizontal,
                .gravity_y = 0.5,
                .background = true,
                .color_fill = theme.colors.bg_elevated,
                .min_size_content = .{ .w = 0, .h = 3 },
                .max_size_content = .{ .w = std.math.floatMax(f32), .h = 3 },
            });
            const track_w = track.data().contentRectScale().r.w;
            const frac = r.prog.fraction();
            var fill = dvui.box(@src(), .{}, .{
                .id_extra = slot + 64511,
                .background = true,
                .color_fill = theme.colors.accent,
                .min_size_content = .{ .w = frac * track_w, .h = 3 },
                .max_size_content = .{ .w = frac * track_w, .h = 3 },
            });
            fill.deinit();
            track.deinit();
        }

        // Movies count in percent, not episodes -- "42/100 episodes" is nonsense.
        var cbuf: [16]u8 = undefined;
        const cl = if (r.kind == .movie)
            (std.fmt.bufPrint(&cbuf, "{d:.0}%", .{r.pct}) catch "")
        else
            (std.fmt.bufPrint(&cbuf, "{d}/{d}", .{ r.prog.watched, r.prog.total }) catch "");
        _ = dvui.label(@src(), "{s}", .{cl}, .{
            .id_extra = slot + 64520,
            .color_text = theme.colors.text_tertiary,
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
        });
    }

    // -- Play (only when there is something to actually play) --
    if (playLabel(r)) |lbl| {
        if (dvui.button(@src(), lbl, .{}, .{
            .id_extra = slot + 64600,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        })) playRow(r);
    }
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
