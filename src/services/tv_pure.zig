//! TV tracking engine — the single definition of "what do I watch next?".
//!
//! Every TV surface routes through this file: the TV detail Resume button, the
//! Home "Coming up" rail, and the My Shows page. Before this existed, each one
//! derived "next episode" itself and none of them agreed — the detail page could
//! not cross a season boundary, and the calendar rail inferred a bare `unseen`
//! bool by comparing the *last watched* episode against TMDB's last-aired one,
//! which is wrong for anyone who skipped, rewatched, or watched out of order.
//!
//! Two rules govern everything here:
//!
//!   1. **Never point at an episode that does not exist yet.** TMDB's
//!      `episode_count` counts *announced* episodes, not aired ones, so a naive
//!      successor search happily returns S03E05 of a season where only four have
//!      aired — and Resume would then go torrent-hunting for it. Every answer is
//!      clamped to `last_aired`.
//!
//!   2. **Never fabricate progress.** A watched row that the season map does not
//!      know about (a special, or an episode TMDB has since removed) is ignored
//!      rather than counted, so `watched` can never exceed `total`.
//!
//! Pure: no imports beyond `std`, no state, no allocator. The impure half (SQL,
//! TMDB fetches, dvui) lives in `tv_library.zig` and only *executes* these
//! decisions.

const std = @import("std");

/// Season 0 is TMDB's specials bucket. It is excluded from next-up and from
/// progress totals — nobody considers a Christmas special to be "the next
/// episode", and counting specials makes a finished show read as 38/42.
pub const SPECIALS_SEASON: i32 = 0;

pub const MAX_SEASONS: usize = 60;
pub const MAX_WATCHED: usize = 2000;
pub const MAX_SHOWS: usize = 200;

pub const Season = struct {
    number: i32 = 0,
    episode_count: u16 = 0,
};

pub const Ep = struct {
    season: i32 = 0,
    episode: i32 = 0,

    pub fn eql(a: Ep, b: Ep) bool {
        return a.season == b.season and a.episode == b.episode;
    }

    /// Air order: season first, then episode within the season.
    pub fn after(a: Ep, b: Ep) bool {
        if (a.season != b.season) return a.season > b.season;
        return a.episode > b.episode;
    }
};

pub const Progress = struct {
    watched: u32 = 0,
    total: u32 = 0,

    /// 0.0–1.0, saturating. `total == 0` means "we know nothing about this show"
    /// (no season map yet), which is 0 progress, not a divide-by-zero.
    pub fn fraction(self: Progress) f32 {
        if (self.total == 0) return 0;
        const num: f32 = @floatFromInt(@min(self.watched, self.total));
        const den: f32 = @floatFromInt(self.total);
        return num / den;
    }
};

pub const Status = enum {
    /// Tracked but nothing watched yet.
    unstarted,
    /// Has a next episode available to watch right now.
    watching,
    /// Everything that has aired is watched, but the show is still running.
    caught_up,
    /// Ended show, every aired episode watched. Done forever.
    completed,
    /// Explicitly abandoned by the user.
    dropped,
};

pub const Filter = enum { all, watching, caught_up, unstarted, completed, dropped };

/// What KIND of thing is being tracked. The Watching library is not TV-only.
pub const Kind = enum { tv, anime, movie };

pub fn kindName(k: Kind) []const u8 {
    return switch (k) {
        .tv => "TV",
        .anime => "Anime",
        .movie => "Movies",
    };
}

pub const KindFilter = enum { all, tv, anime, movie };

/// A status the USER set by hand, which always wins over the derived one.
///
/// Derived status answers "where are you in this?"; user status answers "what do
/// you want this to say?". They disagree all the time and both are legitimate —
/// a show you abandoned halfway still has a next episode, and one you've decided
/// is Completed shouldn't nag you because TMDB added a special.
pub const UserStatus = enum { none, plan, watching, completed, dropped };

pub fn userStatusName(u: UserStatus) []const u8 {
    return switch (u) {
        .none => "Track",
        .plan => "Plan",
        .watching => "Watching",
        .completed => "Completed",
        .dropped => "Dropped",
    };
}

/// DB round-trip. Unknown text degrades to `.none` (auto) rather than guessing.
pub fn userStatusFromStr(s: []const u8) UserStatus {
    if (std.mem.eql(u8, s, "plan")) return .plan;
    if (std.mem.eql(u8, s, "watching")) return .watching;
    if (std.mem.eql(u8, s, "completed")) return .completed;
    if (std.mem.eql(u8, s, "dropped")) return .dropped;
    return .none;
}

pub fn userStatusToStr(u: UserStatus) []const u8 {
    return switch (u) {
        .none => "",
        .plan => "plan",
        .watching => "watching",
        .completed => "completed",
        .dropped => "dropped",
    };
}

/// The user's hand-set status wins; `.none` falls back to what the data says.
pub fn effectiveStatus(u: UserStatus, derived: Status) Status {
    return switch (u) {
        .none => derived,
        .plan => .unstarted,
        .watching => .watching,
        .completed => .completed,
        .dropped => .dropped,
    };
}

// ══════════════════════════════════════════════════════════
// Season-map helpers
// ══════════════════════════════════════════════════════════

/// Episode count for `season_number`, or null if the map has no such season.
/// A watched row for a season we don't know about is data we cannot interpret,
/// so callers skip it rather than guess.
pub fn seasonEpisodeCount(seasons: []const Season, season_number: i32) ?u16 {
    for (seasons) |s| {
        if (s.number == season_number) return s.episode_count;
    }
    return null;
}

/// Index of the lowest real (non-special) season strictly greater than `after_n`,
/// or null when there is none. Used to walk seasons in air order without
/// requiring the caller to pre-sort — the DB returns them in whatever order it
/// likes, and sorting in place would mean allocating.
fn nextSeasonIdx(seasons: []const Season, after_n: i32) ?usize {
    var best: ?usize = null;
    for (seasons, 0..) |s, i| {
        if (s.number <= SPECIALS_SEASON) continue;
        if (s.number <= after_n) continue;
        if (best) |b| {
            if (s.number < seasons[b].number) best = i;
        } else best = i;
    }
    return best;
}

fn isWatched(watched: []const Ep, e: Ep) bool {
    for (watched) |w| {
        if (w.eql(e)) return true;
    }
    return false;
}

/// How many episodes of `s` have actually aired, given the frontier.
///
/// `last_aired == null` means "frontier unknown" and deliberately does NOT clamp.
/// The two failure modes are asymmetric: refusing to clamp when nothing has aired
/// costs a fruitless torrent search, whereas clamping because we merely failed to
/// parse the frontier would make the show read "Caught up" forever and silently
/// swallow the user's next episode. The second is far worse, so unknown means
/// "trust the season map".
fn airedInSeason(s: Season, last_aired: ?Ep) u16 {
    const la = last_aired orelse return s.episode_count;
    if (s.number < la.season) return s.episode_count;
    if (s.number > la.season) return 0;
    if (la.episode <= 0) return 0;
    const aired: u16 = @intCast(@min(@as(i64, la.episode), @as(i64, std.math.maxInt(u16))));
    return @min(s.episode_count, aired);
}

// ══════════════════════════════════════════════════════════
// The engine
// ══════════════════════════════════════════════════════════

/// First unwatched episode in air order, or null when there is nothing to watch.
///
/// Returns the *gap*, not the frontier: someone who watched S01E01 and S01E03 is
/// pointed at S01E02, not S02E01. Skips specials. Clamped to `last_aired`, so a
/// null result means "caught up on everything that exists", never "we ran off the
/// end of an announced-but-unaired season".
pub fn nextUp(seasons: []const Season, watched: []const Ep, last_aired: ?Ep) ?Ep {
    var cur: i32 = SPECIALS_SEASON; // walk seasons strictly above the specials bucket
    while (nextSeasonIdx(seasons, cur)) |idx| {
        const s = seasons[idx];
        cur = s.number;

        const aired = airedInSeason(s, last_aired);
        var ep: i32 = 1;
        while (ep <= @as(i32, aired)) : (ep += 1) {
            const cand = Ep{ .season = s.number, .episode = ep };
            if (!isWatched(watched, cand)) return cand;
        }
    }
    return null;
}

/// Aired, non-special episodes watched / total.
///
/// `watched` is intersected with the season map, so a stale row (a special, or an
/// episode TMDB no longer lists, or one past the aired frontier) is ignored rather
/// than counted. That intersection is the only thing standing between us and a
/// "63/62 watched" progress bar.
pub fn progress(seasons: []const Season, watched: []const Ep, last_aired: ?Ep) Progress {
    var p = Progress{};

    for (seasons) |s| {
        if (s.number <= SPECIALS_SEASON) continue;
        p.total += airedInSeason(s, last_aired);
    }

    for (watched) |w| {
        if (w.season <= SPECIALS_SEASON) continue;
        if (w.episode < 1) continue;
        const s = seasonEpisodeCount(seasons, w.season) orelse continue;
        const aired = airedInSeason(.{ .number = w.season, .episode_count = s }, last_aired);
        if (w.episode > @as(i32, aired)) continue;
        p.watched += 1;
    }

    return p;
}

/// `ended` is TMDB's series status ("Ended" / "Canceled"), which is the only way
/// to tell "watched everything, and there will never be more" from "watched
/// everything, next season lands in spring".
pub fn statusOf(p: Progress, next: ?Ep, ended: bool) Status {
    if (p.total == 0) return .unstarted; // no season map yet — don't claim anything
    if (p.watched == 0) return .unstarted;
    if (next != null) return .watching;
    if (ended and p.watched >= p.total) return .completed;
    return .caught_up;
}

/// The episode immediately AFTER `cur` in air order (crossing into the next
/// season when `cur` is a finale), or null when there is none.
///
/// Clamped to `last_aired` for the same reason nextUp is: offering a "next
/// episode" that has not aired sends the resolver hunting for a file that does
/// not exist.
pub fn episodeAfter(seasons: []const Season, cur: Ep, last_aired: ?Ep) ?Ep {
    const count = seasonEpisodeCount(seasons, cur.season) orelse return null;

    // Still inside this season?
    if (cur.episode < @as(i32, count)) {
        const cand = Ep{ .season = cur.season, .episode = cur.episode + 1 };
        if (last_aired) |la| {
            if (cand.after(la)) return null;
        }
        return cand;
    }

    // Season finale — roll into the first episode of the next real season.
    const idx = nextSeasonIdx(seasons, cur.season) orelse return null;
    const s = seasons[idx];
    if (s.episode_count == 0) return null;
    const cand = Ep{ .season = s.number, .episode = 1 };
    if (last_aired) |la| {
        if (cand.after(la)) return null;
    }
    return cand;
}

/// The episode immediately BEFORE `cur` in air order (crossing back into the
/// previous season's finale), or null when `cur` is the very first.
pub fn episodeBefore(seasons: []const Season, cur: Ep) ?Ep {
    if (cur.episode > 1) {
        return .{ .season = cur.season, .episode = cur.episode - 1 };
    }

    // Season premiere — step back to the previous real season's LAST episode.
    var best: ?Season = null;
    for (seasons) |s| {
        if (s.number <= SPECIALS_SEASON) continue; // never step back into specials
        if (s.number >= cur.season) continue;
        if (s.episode_count == 0) continue;
        if (best) |b| {
            if (s.number > b.number) best = s;
        } else best = s;
    }
    const prev = best orelse return null;
    return .{ .season = prev.number, .episode = @intCast(prev.episode_count) };
}

/// Movies have no episodes — progress is the played fraction (0-100).
///
/// 95% is "finished" throughout this app (credits roll; the resume predicate in
/// resume_pure uses the same bar). Below the 0.5% floor, watch_history doesn't
/// even record a row, so it means "never really started".
pub const MOVIE_DONE_PCT: f32 = 95.0;
pub const MOVIE_START_PCT: f32 = 0.5;

pub fn statusOfMovie(pct: f32) Status {
    if (pct >= MOVIE_DONE_PCT) return .completed;
    if (pct >= MOVIE_START_PCT) return .watching;
    return .unstarted;
}

// ══════════════════════════════════════════════════════════
// My Shows rows
// ══════════════════════════════════════════════════════════

pub const Row = struct {
    kind: Kind = .tv,
    /// TMDB id for TV. 0 for anime/movies — they key off `id`.
    tmdb_id: i32 = 0,
    /// Stable string identity used for library_status: the TMDB id for TV, the
    /// MAL id for anime, the normalized name for a movie.
    id: [64]u8 = std.mem.zeroes([64]u8),
    id_len: usize = 0,

    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    poster_path: [64]u8 = std.mem.zeroes([64]u8),
    poster_path_len: usize = 0,
    /// Fully-qualified artwork URL. TV builds it from poster_path; anime already
    /// stores one. One field means one poster code path for every kind.
    poster_url: [160]u8 = std.mem.zeroes([160]u8),
    poster_url_len: usize = 0,

    /// What the user set by hand. Wins over `status` when not `.none`.
    user: UserStatus = .none,
    /// Movies only: watched fraction, 0-100 (watch_history percent).
    pct: f32 = 0,
    /// Movies only: index into watch_history.entries, or -1. Resume needs the link.
    hist_idx: i32 = -1,

    next: Ep = .{},
    has_next: bool = false,
    prog: Progress = .{},
    status: Status = .unstarted,
    ended: bool = false,

    /// Unix epoch (seconds) of the next episode's air date; 0 when unknown.
    next_air_epoch: i64 = 0,
    /// Last activity (ms) — drives "most recently watched first".
    updated_at: i64 = 0,
    /// Resume position (seconds) inside `next`, 0 when not started.
    resume_secs: f64 = 0,

    pub fn nameSlice(self: *const Row) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }
    pub fn posterSlice(self: *const Row) []const u8 {
        return self.poster_path[0..@min(self.poster_path_len, self.poster_path.len)];
    }
    pub fn setName(self: *Row, s: []const u8) void {
        const n = @min(s.len, self.name.len);
        @memcpy(self.name[0..n], s[0..n]);
        self.name_len = n;
    }
    pub fn setPoster(self: *Row, s: []const u8) void {
        const n = @min(s.len, self.poster_path.len);
        @memcpy(self.poster_path[0..n], s[0..n]);
        self.poster_path_len = n;
    }
    pub fn idSlice(self: *const Row) []const u8 {
        return self.id[0..@min(self.id_len, self.id.len)];
    }
    pub fn setId(self: *Row, s: []const u8) void {
        const n = @min(s.len, self.id.len);
        @memcpy(self.id[0..n], s[0..n]);
        self.id_len = n;
    }
    pub fn posterUrlSlice(self: *const Row) []const u8 {
        return self.poster_url[0..@min(self.poster_url_len, self.poster_url.len)];
    }
    pub fn setPosterUrl(self: *Row, s: []const u8) void {
        const n = @min(s.len, self.poster_url.len);
        @memcpy(self.poster_url[0..n], s[0..n]);
        self.poster_url_len = n;
    }
    /// The kind string used as the library_status key.
    pub fn kindKey(self: *const Row) []const u8 {
        return switch (self.kind) {
            .tv => "tv",
            .anime => "anime",
            .movie => "movie",
        };
    }
};

/// Sort bucket: what the user most likely wants to click. Shows with an episode
/// ready to watch come first; finished shows sink to the bottom.
fn statusRank(s: Status) u8 {
    return switch (s) {
        .watching => 0,
        .caught_up => 1,
        .unstarted => 2,
        .completed => 3,
        .dropped => 4, // abandoned on purpose — never surface it above live work
    };
}

/// Bucket ascending, then most-recent activity first.
pub fn lessThan(a: *const Row, b: *const Row) bool {
    const ra = statusRank(a.status);
    const rb = statusRank(b.status);
    if (ra != rb) return ra < rb;
    if (a.updated_at != b.updated_at) return a.updated_at > b.updated_at;
    return std.mem.lessThan(u8, a.nameSlice(), b.nameSlice());
}

/// Fill `out` with indices into `rows`, in display order. Returns the count.
/// Insertion sort: `rows` is capped at MAX_SHOWS and this only runs when the
/// library snapshot is rebuilt (never per-frame), so O(n²) is free here.
pub fn sortOrder(rows: []const Row, out: []u16) usize {
    const n = @min(rows.len, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = @intCast(i);

    var a: usize = 1;
    while (a < n) : (a += 1) {
        const key = out[a];
        var b: usize = a;
        while (b > 0 and lessThan(&rows[key], &rows[out[b - 1]])) : (b -= 1) {
            out[b] = out[b - 1];
        }
        out[b] = key;
    }
    return n;
}

pub fn matchesFilter(r: *const Row, f: Filter) bool {
    return switch (f) {
        .all => true,
        .watching => r.status == .watching,
        .caught_up => r.status == .caught_up,
        .unstarted => r.status == .unstarted,
        .completed => r.status == .completed,
        .dropped => r.status == .dropped,
    };
}

pub fn matchesKind(r: *const Row, k: KindFilter) bool {
    return switch (k) {
        .all => true,
        .tv => r.kind == .tv,
        .anime => r.kind == .anime,
        .movie => r.kind == .movie,
    };
}

/// A row is visible only when it satisfies BOTH chip rows.
pub fn visible(r: *const Row, f: Filter, k: KindFilter) bool {
    return matchesFilter(r, f) and matchesKind(r, k);
}

/// Counts per status chip, indexed by `@intFromEnum(Filter)`. Counted WITHIN the
/// active kind filter, so the numbers always add up to what is on screen — a
/// count that disagrees with the list is worse than no count.
pub fn countsFor(rows: []const Row, k: KindFilter, out: *[6]usize) void {
    out.* = .{ 0, 0, 0, 0, 0, 0 };
    const filters = [_]Filter{ .all, .watching, .caught_up, .unstarted, .completed, .dropped };
    for (rows) |*r| {
        if (!matchesKind(r, k)) continue;
        for (filters, 0..) |f, i| {
            if (matchesFilter(r, f)) out[i] += 1;
        }
    }
}

/// Counts per kind chip, indexed by `@intFromEnum(KindFilter)`, within the active
/// status filter — same reasoning as above.
pub fn kindCountsFor(rows: []const Row, f: Filter, out: *[4]usize) void {
    out.* = .{ 0, 0, 0, 0 };
    const kinds = [_]KindFilter{ .all, .tv, .anime, .movie };
    for (rows) |*r| {
        if (!matchesFilter(r, f)) continue;
        for (kinds, 0..) |k, i| {
            if (matchesKind(r, k)) out[i] += 1;
        }
    }
}

// ══════════════════════════════════════════════════════════
// Labels
// ══════════════════════════════════════════════════════════

/// "S02E04". Zero-padded, and the casts to unsigned are load-bearing: Zig 0.16
/// formats a *signed* int under `{d:0>2}` with an explicit sign, which is how
/// `episodeQuery` once emitted "x-men S+2E+2" and matched nothing on any indexer.
/// Same trap, same fix — see tmdb_pure.episodeQuery.
pub fn episodeLabel(e: Ep, buf: []u8) []const u8 {
    const s: u32 = @intCast(@max(0, e.season));
    const ep: u32 = @intCast(@max(0, e.episode));
    return std.fmt.bufPrint(buf, "S{d:0>2}E{d:0>2}", .{ s, ep }) catch "";
}

/// The one-line status a card shows under the title.
pub fn statusLabel(r: *const Row, buf: []u8) []const u8 {
    if (r.kind == .movie) {
        if (r.pct >= MOVIE_DONE_PCT) return "Watched";
        if (r.pct >= MOVIE_START_PCT) {
            return std.fmt.bufPrint(buf, "{d:.0}% watched", .{r.pct}) catch "In progress";
        }
        return "Not started";
    }

    if (r.has_next) {
        var eb: [16]u8 = undefined;
        const el = episodeLabel(r.next, &eb);
        if (r.resume_secs > 2) {
            const mins: u32 = @intFromFloat(r.resume_secs / 60);
            const secs: u32 = @intFromFloat(@mod(r.resume_secs, 60));
            return std.fmt.bufPrint(buf, "{s} · {d}:{d:0>2} in", .{ el, mins, secs }) catch el;
        }
        return std.fmt.bufPrint(buf, "{s} · Next", .{el}) catch el;
    }

    // No next episode — which is NOT the same as "caught up". With no season map
    // (a show that has never synced) we simply do not know, and claiming "Caught
    // up" there hides the user's next episode: Silo read "Caught up" at 0/10
    // watched. Unknown has to say unknown.
    if (r.prog.total == 0) return "Not synced yet";

    return switch (r.status) {
        .completed => "Completed",
        .caught_up => "Caught up",
        .unstarted => "Not started",
        .dropped => "Dropped",
        .watching => "Caught up", // marked watching but nothing left aired
    };
}

// ══════════════════════════════════════════════════════════
// TMDB /3/tv/{id} parsing
//
// A deliberately narrow parser: it wants only the season map (number →
// episode_count) and the series status. `tmdb.zig` already has a `parseSeasons`,
// but it writes straight into `state.app.tmdb` and pulls dvui in with it, so it
// cannot be imported from a pure module. This one carries no state and is tested.
// ══════════════════════════════════════════════════════════

/// Scan `body` for `"key": <int>` starting at `from`. Returns the value and the
/// index just past it.
fn intAfter(body: []const u8, key: []const u8, from: usize) ?struct { val: i64, end: usize } {
    if (from >= body.len) return null;
    const rel = std.mem.indexOfPos(u8, body, from, key) orelse return null;
    var i = rel + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == ':')) i += 1;

    var neg = false;
    if (i < body.len and body[i] == '-') {
        neg = true;
        i += 1;
    }
    if (i >= body.len or !std.ascii.isDigit(body[i])) return null;

    var v: i64 = 0;
    while (i < body.len and std.ascii.isDigit(body[i])) : (i += 1) {
        v = v * 10 + @as(i64, body[i] - '0');
    }
    return .{ .val = if (neg) -v else v, .end = i };
}

/// Parse the `"seasons":[…]` array of a TMDB /3/tv/{id} document into the season
/// map. Returns the number of seasons written.
///
/// Bounded to the seasons array: `"episode_count"` appears nowhere else in the
/// document, but `"season_number"` does (inside `next_episode_to_air` and
/// `last_episode_to_air`), so a naive global scan would invent a phantom season
/// from the next-episode object. Each season is read as the PAIR
/// (season_number, episode_count) taken from the same object.
pub fn parseSeasonMap(body: []const u8, out: []Season) usize {
    const arr_key = "\"seasons\":";
    const arr_at = std.mem.indexOf(u8, body, arr_key) orelse return 0;
    var i = arr_at + arr_key.len;
    while (i < body.len and body[i] == ' ') i += 1;
    if (i >= body.len or body[i] != '[') return 0;

    // Find the end of the seasons array. Season objects don't nest, so tracking
    // bracket depth over the array is enough.
    const start = i;
    var depth: i32 = 0;
    var end: usize = body.len;
    var k = start;
    while (k < body.len) : (k += 1) {
        if (body[k] == '[') depth += 1;
        if (body[k] == ']') {
            depth -= 1;
            if (depth == 0) {
                end = k;
                break;
            }
        }
    }
    const arr = body[start..@min(end + 1, body.len)];

    var n: usize = 0;
    var pos: usize = 0;
    while (n < out.len) {
        const ec = intAfter(arr, "\"episode_count\"", pos) orelse break;
        const sn = intAfter(arr, "\"season_number\"", pos) orelse break;
        // Both keys belong to the same season object regardless of field order,
        // so advance past whichever came last.
        pos = @max(ec.end, sn.end);

        if (sn.val < 0) continue;
        out[n] = .{
            .number = @intCast(@min(sn.val, std.math.maxInt(i32))),
            .episode_count = @intCast(@max(0, @min(ec.val, std.math.maxInt(u16)))),
        };
        n += 1;
    }
    return n;
}

/// TMDB's series `"status"` — "Ended" and "Canceled" both mean no more episodes.
/// This is the only signal that separates "Completed" from "Caught up".
pub fn parseEnded(body: []const u8) bool {
    const key = "\"status\":";
    const at = std.mem.indexOf(u8, body, key) orelse return false;
    var i = at + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '"')) i += 1;
    const rest = body[@min(i, body.len)..];
    return std.mem.startsWith(u8, rest, "Ended") or std.mem.startsWith(u8, rest, "Canceled");
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

const t = std.testing;

const three_seasons = [_]Season{
    .{ .number = 1, .episode_count = 3 },
    .{ .number = 2, .episode_count = 3 },
};

test "nextUp: nothing watched → first episode of the first real season" {
    const got = nextUp(&three_seasons, &.{}, .{ .season = 2, .episode = 3 });
    try t.expect(got != null);
    try t.expect(got.?.eql(.{ .season = 1, .episode = 1 }));
}

test "nextUp: crosses the season boundary once a season is complete" {
    const watched = [_]Ep{
        .{ .season = 1, .episode = 1 },
        .{ .season = 1, .episode = 2 },
        .{ .season = 1, .episode = 3 },
    };
    const got = nextUp(&three_seasons, &watched, .{ .season = 2, .episode = 3 });
    try t.expect(got.?.eql(.{ .season = 2, .episode = 1 }));
}

test "nextUp: returns the GAP, not the boundary" {
    // Watched S01E01 + S01E03. The answer is the hole at S01E02 — a successor
    // search that only tracked "highest watched" would wrongly jump to S02E01.
    const watched = [_]Ep{
        .{ .season = 1, .episode = 1 },
        .{ .season = 1, .episode = 3 },
    };
    const got = nextUp(&three_seasons, &watched, .{ .season = 2, .episode = 3 });
    try t.expect(got.?.eql(.{ .season = 1, .episode = 2 }));
}

test "nextUp: clamped to last_aired — no phantom unaired episode" {
    // S03 is announced with 10 episodes but only 4 have aired, and all 4 are
    // watched. The answer is "caught up", NOT a phantom S03E05 that Resume would
    // then go hunting for on an indexer.
    const seasons = [_]Season{.{ .number = 3, .episode_count = 10 }};
    const watched = [_]Ep{
        .{ .season = 3, .episode = 1 },
        .{ .season = 3, .episode = 2 },
        .{ .season = 3, .episode = 3 },
        .{ .season = 3, .episode = 4 },
    };
    try t.expect(nextUp(&seasons, &watched, .{ .season = 3, .episode = 4 }) == null);

    // ...but the fifth episode airing must immediately unblock it.
    const got = nextUp(&seasons, &watched, .{ .season = 3, .episode = 5 });
    try t.expect(got.?.eql(.{ .season = 3, .episode = 5 }));
}

test "nextUp: unknown frontier does NOT clamp" {
    // last_aired == null means "we failed to learn the frontier", not "nothing
    // aired". Clamping here would make every show read Caught up forever and
    // silently swallow the user's next episode — the worst possible failure.
    const got = nextUp(&three_seasons, &.{}, null);
    try t.expect(got.?.eql(.{ .season = 1, .episode = 1 }));
}

test "nextUp: specials (season 0) are never the next episode" {
    const seasons = [_]Season{
        .{ .number = 0, .episode_count = 5 },
        .{ .number = 1, .episode_count = 2 },
    };
    const got = nextUp(&seasons, &.{}, .{ .season = 1, .episode = 2 });
    try t.expect(got.?.eql(.{ .season = 1, .episode = 1 }));
}

test "nextUp: unsorted season map still walks in air order" {
    const seasons = [_]Season{
        .{ .number = 2, .episode_count = 3 },
        .{ .number = 1, .episode_count = 1 },
    };
    const got = nextUp(&seasons, &.{}, .{ .season = 2, .episode = 3 });
    try t.expect(got.?.eql(.{ .season = 1, .episode = 1 }));
}

test "nextUp: fully watched, ended show → null" {
    const watched = [_]Ep{
        .{ .season = 1, .episode = 1 }, .{ .season = 1, .episode = 2 }, .{ .season = 1, .episode = 3 },
        .{ .season = 2, .episode = 1 }, .{ .season = 2, .episode = 2 }, .{ .season = 2, .episode = 3 },
    };
    try t.expect(nextUp(&three_seasons, &watched, .{ .season = 2, .episode = 3 }) == null);
}

test "nextUp: empty season map → null (never fabricate)" {
    try t.expect(nextUp(&.{}, &.{}, null) == null);
}

test "progress: counts only aired, non-special episodes" {
    const seasons = [_]Season{
        .{ .number = 0, .episode_count = 4 }, // specials — excluded entirely
        .{ .number = 1, .episode_count = 3 },
        .{ .number = 2, .episode_count = 10 }, // announced 10, only 2 aired
    };
    const watched = [_]Ep{
        .{ .season = 0, .episode = 1 }, // a watched special must not count
        .{ .season = 1, .episode = 1 },
        .{ .season = 2, .episode = 1 },
    };
    const p = progress(&seasons, &watched, .{ .season = 2, .episode = 2 });
    try t.expectEqual(@as(u32, 5), p.total); // 3 aired in S1 + 2 aired in S2
    try t.expectEqual(@as(u32, 2), p.watched); // the special is ignored
}

test "progress: a stale watched row can never push watched past total" {
    // The user marked E11 of a 10-episode season (or TMDB later dropped an
    // episode). Counting it would render a 11/10 progress bar.
    const seasons = [_]Season{.{ .number = 1, .episode_count = 3 }};
    const watched = [_]Ep{
        .{ .season = 1, .episode = 1 },
        .{ .season = 1, .episode = 2 },
        .{ .season = 1, .episode = 3 },
        .{ .season = 1, .episode = 11 }, // does not exist
        .{ .season = 9, .episode = 1 }, // season not in the map
    };
    const p = progress(&seasons, &watched, .{ .season = 1, .episode = 3 });
    try t.expectEqual(@as(u32, 3), p.total);
    try t.expectEqual(@as(u32, 3), p.watched);
    try t.expect(p.watched <= p.total);
    try t.expectEqual(@as(f32, 1.0), p.fraction());
}

test "progress: empty season map → 0/0 and fraction 0, not a divide by zero" {
    const p = progress(&.{}, &.{}, null);
    try t.expectEqual(@as(u32, 0), p.total);
    try t.expectEqual(@as(f32, 0), p.fraction());
}

test "statusOf: every transition" {
    const none: ?Ep = null;
    const some: ?Ep = Ep{ .season = 1, .episode = 2 };

    // No season map yet — we know nothing, so claim nothing.
    try t.expectEqual(Status.unstarted, statusOf(.{ .watched = 0, .total = 0 }, some, false));
    // Tracked, nothing watched.
    try t.expectEqual(Status.unstarted, statusOf(.{ .watched = 0, .total = 6 }, some, false));
    // Something to watch right now.
    try t.expectEqual(Status.watching, statusOf(.{ .watched = 1, .total = 6 }, some, false));
    // Watched everything aired, show still running.
    try t.expectEqual(Status.caught_up, statusOf(.{ .watched = 6, .total = 6 }, none, false));
    // Watched everything, show is over.
    try t.expectEqual(Status.completed, statusOf(.{ .watched = 6, .total = 6 }, none, true));
    // Ended, but there are still gaps → not completed.
    try t.expectEqual(Status.caught_up, statusOf(.{ .watched = 5, .total = 6 }, none, true));
}

test "episodeLabel: zero-padded and UNSIGNED (the 'S+2E+2' regression)" {
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("S02E04", episodeLabel(.{ .season = 2, .episode = 4 }, &buf));
    try t.expectEqualStrings("S01E01", episodeLabel(.{ .season = 1, .episode = 1 }, &buf));
    try t.expectEqualStrings("S10E12", episodeLabel(.{ .season = 10, .episode = 12 }, &buf));
    // The bug: Zig 0.16 prints a signed int under {d:0>2} with its sign, giving
    // "S+2E+2". Any '+' here means the unsigned casts were lost.
    const out = episodeLabel(.{ .season = 2, .episode = 2 }, &buf);
    try t.expect(std.mem.indexOfScalar(u8, out, '+') == null);
}

test "sortOrder: ready-to-watch first, then most recent, completed last" {
    var rows: [4]Row = .{ .{}, .{}, .{}, .{} };
    rows[0].setName("Completed Show");
    rows[0].status = .completed;
    rows[0].updated_at = 900;

    rows[1].setName("Older Watching");
    rows[1].status = .watching;
    rows[1].updated_at = 100;

    rows[2].setName("Caught Up Show");
    rows[2].status = .caught_up;
    rows[2].updated_at = 800;

    rows[3].setName("Newer Watching");
    rows[3].status = .watching;
    rows[3].updated_at = 500;

    var order: [4]u16 = undefined;
    const n = sortOrder(&rows, &order);
    try t.expectEqual(@as(usize, 4), n);
    try t.expectEqualStrings("Newer Watching", rows[order[0]].nameSlice());
    try t.expectEqualStrings("Older Watching", rows[order[1]].nameSlice());
    try t.expectEqualStrings("Caught Up Show", rows[order[2]].nameSlice());
    try t.expectEqualStrings("Completed Show", rows[order[3]].nameSlice());
}

test "countsFor + matchesFilter" {
    var rows: [3]Row = .{ .{}, .{}, .{} };
    rows[0].status = .watching;
    rows[1].status = .watching;
    rows[2].status = .completed;

    var counts: [6]usize = undefined;
    countsFor(&rows, .all, &counts);
    try t.expectEqual(@as(usize, 3), counts[@intFromEnum(Filter.all)]);
    try t.expectEqual(@as(usize, 2), counts[@intFromEnum(Filter.watching)]);
    try t.expectEqual(@as(usize, 0), counts[@intFromEnum(Filter.caught_up)]);
    try t.expectEqual(@as(usize, 0), counts[@intFromEnum(Filter.unstarted)]);
    try t.expectEqual(@as(usize, 1), counts[@intFromEnum(Filter.completed)]);
    try t.expectEqual(@as(usize, 0), counts[@intFromEnum(Filter.dropped)]);

    try t.expect(matchesFilter(&rows[0], .watching));
    try t.expect(!matchesFilter(&rows[0], .completed));
    try t.expect(matchesFilter(&rows[2], .all));
}

test "counts are scoped to the OTHER chip row (they must add up to the list)" {
    // A count that disagrees with what's on screen is worse than no count.
    var rows: [3]Row = .{ .{}, .{}, .{} };
    rows[0].kind = .tv;
    rows[0].status = .watching;
    rows[1].kind = .anime;
    rows[1].status = .watching;
    rows[2].kind = .movie;
    rows[2].status = .completed;

    var counts: [6]usize = undefined;
    countsFor(&rows, .anime, &counts); // status counts WITHIN anime
    try t.expectEqual(@as(usize, 1), counts[@intFromEnum(Filter.all)]);
    try t.expectEqual(@as(usize, 1), counts[@intFromEnum(Filter.watching)]);
    try t.expectEqual(@as(usize, 0), counts[@intFromEnum(Filter.completed)]);

    var kinds: [4]usize = undefined;
    kindCountsFor(&rows, .watching, &kinds); // kind counts WITHIN "watching"
    try t.expectEqual(@as(usize, 2), kinds[@intFromEnum(KindFilter.all)]);
    try t.expectEqual(@as(usize, 1), kinds[@intFromEnum(KindFilter.tv)]);
    try t.expectEqual(@as(usize, 1), kinds[@intFromEnum(KindFilter.anime)]);
    try t.expectEqual(@as(usize, 0), kinds[@intFromEnum(KindFilter.movie)]);

    try t.expect(visible(&rows[1], .watching, .anime));
    try t.expect(!visible(&rows[1], .watching, .tv));
}

test "user status always beats the derived one" {
    // A show you abandoned still HAS a next episode; one you called Completed
    // shouldn't nag you because TMDB added a special. The hand-set value wins.
    try t.expectEqual(Status.watching, effectiveStatus(.none, .watching));
    try t.expectEqual(Status.dropped, effectiveStatus(.dropped, .watching));
    try t.expectEqual(Status.completed, effectiveStatus(.completed, .watching));
    try t.expectEqual(Status.unstarted, effectiveStatus(.plan, .watching));
    try t.expectEqual(Status.watching, effectiveStatus(.watching, .caught_up));

    // DB round-trip, including the degrade-to-auto path for junk.
    try t.expectEqual(UserStatus.dropped, userStatusFromStr("dropped"));
    try t.expectEqual(UserStatus.none, userStatusFromStr("banana"));
    try t.expectEqual(UserStatus.none, userStatusFromStr(""));
    inline for (.{ UserStatus.plan, .watching, .completed, .dropped }) |u| {
        try t.expectEqual(u, userStatusFromStr(userStatusToStr(u)));
    }
}

test "episodeAfter / episodeBefore: neighbours cross season boundaries" {
    const seasons = [_]Season{
        .{ .number = 0, .episode_count = 4 }, // specials — never a neighbour
        .{ .number = 1, .episode_count = 3 },
        .{ .number = 2, .episode_count = 5 },
    };
    const la = Ep{ .season = 2, .episode = 5 };

    // Within a season.
    try t.expect(episodeAfter(&seasons, .{ .season = 1, .episode = 1 }, la).?.eql(.{ .season = 1, .episode = 2 }));
    try t.expect(episodeBefore(&seasons, .{ .season = 1, .episode = 2 }).?.eql(.{ .season = 1, .episode = 1 }));

    // Finale -> next season's premiere.
    try t.expect(episodeAfter(&seasons, .{ .season = 1, .episode = 3 }, la).?.eql(.{ .season = 2, .episode = 1 }));
    // Premiere -> previous season's FINALE (not its premiere).
    try t.expect(episodeBefore(&seasons, .{ .season = 2, .episode = 1 }).?.eql(.{ .season = 1, .episode = 3 }));

    // The very first episode has no predecessor — and must NOT step into specials.
    try t.expect(episodeBefore(&seasons, .{ .season = 1, .episode = 1 }) == null);
    // The last aired episode has no successor.
    try t.expect(episodeAfter(&seasons, .{ .season = 2, .episode = 5 }, la) == null);
}

test "episodeAfter: never offers an episode that hasn't aired" {
    // S2 announces 5 episodes but only 2 have aired. "Next" after S02E02 is
    // nothing — offering S02E03 would send the resolver hunting for a file that
    // does not exist yet.
    const seasons = [_]Season{
        .{ .number = 1, .episode_count = 3 },
        .{ .number = 2, .episode_count = 5 },
    };
    const la = Ep{ .season = 2, .episode = 2 };
    try t.expect(episodeAfter(&seasons, .{ .season = 2, .episode = 1 }, la).?.eql(.{ .season = 2, .episode = 2 }));
    try t.expect(episodeAfter(&seasons, .{ .season = 2, .episode = 2 }, la) == null);

    // With no known frontier we don't clamp — same asymmetry as nextUp.
    try t.expect(episodeAfter(&seasons, .{ .season = 2, .episode = 2 }, null).?.eql(.{ .season = 2, .episode = 3 }));
}

test "statusOfMovie: percent-based, 95% is finished" {
    try t.expectEqual(Status.unstarted, statusOfMovie(0));
    try t.expectEqual(Status.unstarted, statusOfMovie(0.4));
    try t.expectEqual(Status.watching, statusOfMovie(0.5));
    try t.expectEqual(Status.watching, statusOfMovie(50));
    try t.expectEqual(Status.watching, statusOfMovie(94.9));
    try t.expectEqual(Status.completed, statusOfMovie(95));
    try t.expectEqual(Status.completed, statusOfMovie(100));
}

test "statusLabel: 'no data' must never render as 'Caught up' (the Silo bug)" {
    // Silo showed "Caught up" at 0/10 watched, because an unsynced show has no
    // season map, nextUp returns null, and null was being read as "caught up".
    // That lie hides the user's next episode.
    var buf: [48]u8 = undefined;
    var r = Row{ .kind = .tv };
    r.has_next = false;
    r.prog = .{ .watched = 0, .total = 0 }; // never synced
    r.status = .unstarted;
    try t.expectEqualStrings("Not synced yet", statusLabel(&r, &buf));

    // With a real map and everything watched, "Caught up" is the truth.
    r.prog = .{ .watched = 10, .total = 10 };
    r.status = .caught_up;
    try t.expectEqualStrings("Caught up", statusLabel(&r, &buf));
}

test "statusLabel: movies" {
    var buf: [48]u8 = undefined;
    var r = Row{ .kind = .movie };
    r.pct = 0;
    try t.expectEqualStrings("Not started", statusLabel(&r, &buf));
    r.pct = 42.4;
    try t.expectEqualStrings("42% watched", statusLabel(&r, &buf));
    r.pct = 99;
    try t.expectEqualStrings("Watched", statusLabel(&r, &buf));
}

// A trimmed but structurally faithful /3/tv/{id} document. The ordering matters:
// `last_episode_to_air` / `next_episode_to_air` sit BEFORE `seasons` and both
// contain a "season_number" key — a parser that scanned globally would read one
// of those as a season and corrupt the map.
const tv_doc =
    \\{"id":1399,"name":"Test Show","status":"Returning Series",
    \\ "last_episode_to_air":{"season_number":2,"episode_number":4,"name":"Latest"},
    \\ "next_episode_to_air":{"season_number":2,"episode_number":5,"name":"Soon"},
    \\ "number_of_seasons":2,
    \\ "seasons":[
    \\   {"air_date":"2011-04-17","episode_count":8,"season_number":0,"name":"Specials"},
    \\   {"air_date":"2011-04-17","episode_count":10,"season_number":1,"name":"Season 1"},
    \\   {"air_date":"2012-04-01","episode_count":10,"season_number":2,"name":"Season 2"}
    \\ ]}
;

test "parseSeasonMap: reads the seasons array, not the episode-to-air objects" {
    var seasons: [MAX_SEASONS]Season = undefined;
    const n = parseSeasonMap(tv_doc, &seasons);
    try t.expectEqual(@as(usize, 3), n);

    try t.expectEqual(@as(i32, 0), seasons[0].number);
    try t.expectEqual(@as(u16, 8), seasons[0].episode_count);
    try t.expectEqual(@as(i32, 1), seasons[1].number);
    try t.expectEqual(@as(u16, 10), seasons[1].episode_count);
    try t.expectEqual(@as(i32, 2), seasons[2].number);
    try t.expectEqual(@as(u16, 10), seasons[2].episode_count);
}

test "parseSeasonMap: the map + aired clamp agree on a real document" {
    // S2 announces 10 episodes but only 4 have aired. Nothing watched → next is
    // S01E01; watch all of S1 and the 4 aired S2 episodes → caught up, NOT S02E05.
    var seasons: [MAX_SEASONS]Season = undefined;
    const n = parseSeasonMap(tv_doc, &seasons);
    const map = seasons[0..n];
    const last_aired = Ep{ .season = 2, .episode = 4 };

    try t.expect(nextUp(map, &.{}, last_aired).?.eql(.{ .season = 1, .episode = 1 }));

    var watched: [14]Ep = undefined;
    var i: usize = 0;
    var e: i32 = 1;
    while (e <= 10) : (e += 1) {
        watched[i] = .{ .season = 1, .episode = e };
        i += 1;
    }
    e = 1;
    while (e <= 4) : (e += 1) {
        watched[i] = .{ .season = 2, .episode = e };
        i += 1;
    }
    try t.expect(nextUp(map, watched[0..i], last_aired) == null);

    const p = progress(map, watched[0..i], last_aired);
    try t.expectEqual(@as(u32, 14), p.total); // specials excluded, S2 clamped to 4
    try t.expectEqual(@as(u32, 14), p.watched);
}

test "parseSeasonMap: malformed / missing seasons array → 0, never a bogus map" {
    var seasons: [MAX_SEASONS]Season = undefined;
    try t.expectEqual(@as(usize, 0), parseSeasonMap("{\"id\":1}", &seasons));
    try t.expectEqual(@as(usize, 0), parseSeasonMap("", &seasons));
    try t.expectEqual(@as(usize, 0), parseSeasonMap("{\"seasons\":null}", &seasons));
}

test "parseEnded" {
    try t.expect(!parseEnded(tv_doc));
    try t.expect(parseEnded("{\"status\":\"Ended\"}"));
    try t.expect(parseEnded("{\"status\": \"Canceled\"}"));
    try t.expect(!parseEnded("{\"status\":\"In Production\"}"));
    try t.expect(!parseEnded("{}"));
}

test "statusLabel" {
    var buf: [48]u8 = undefined;
    var r = Row{};

    r.status = .watching;
    r.has_next = true;
    r.next = .{ .season = 2, .episode = 4 };
    try t.expectEqualStrings("S02E04 · Next", statusLabel(&r, &buf));

    r.resume_secs = 751; // 12:31 into the episode
    try t.expectEqualStrings("S02E04 · 12:31 in", statusLabel(&r, &buf));

    // These all require a REAL season map. Without one (total == 0) the label is
    // "Not synced yet", because we genuinely don't know — see the Silo bug test.
    r.has_next = false;
    r.resume_secs = 0;
    r.prog = .{ .watched = 10, .total = 10 };
    r.status = .caught_up;
    try t.expectEqualStrings("Caught up", statusLabel(&r, &buf));
    r.status = .completed;
    try t.expectEqualStrings("Completed", statusLabel(&r, &buf));
    r.prog = .{ .watched = 0, .total = 10 };
    r.status = .unstarted;
    try t.expectEqualStrings("Not started", statusLabel(&r, &buf));
    r.status = .dropped;
    try t.expectEqualStrings("Dropped", statusLabel(&r, &buf));
}
