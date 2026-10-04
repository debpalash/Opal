//! Keyless TV tracking: the facts Opal needs about a tracked show (season map,
//! aired frontier, next episode, ended flag) derived from providers that need no
//! API key, plus the identity rules that keep two different shows apart.
//!
//! Sources, in order of authority:
//!   * Cinemeta `meta/series/{imdb}.json` -> `videos` (season, episode, released)
//!     gives the season map, the last aired episode and usually the next one.
//!   * TVmaze `lookup/shows?imdb=` and `shows/{id}?embed=nextepisode` -> series
//!     status and the scheduled next episode, used when Cinemeta has no future
//!     episode (Cinemeta only lists what a database already knows).
//!
//! IDENTITY
//! --------
//! Library rows are keyed by an i32 (`tmdb_id` column). A keyless catalog item
//! has no TMDB id, so the catalog hands out `cinemeta_pure.stableId(imdb)` (a
//! positive hash of the IMDb id). The IMDb id is remembered next to it in
//! `tv_external_ids`. Rules, all pure and tested here:
//!   * `isSynthetic(id, imdb)`: the id is exactly the hash of the stored IMDb id.
//!     Such an id is NOT a TMDB id and must never be sent to TMDB, Trakt or
//!     Simkl as one.
//!   * `identityConflict(stored, incoming)`: two different IMDb ids claim the
//!     same integer. The first claim wins and the second is refused, so one
//!     show's history can never be merged into another's.
//! Nothing here migrates or rewrites existing rows: TMDB-keyed rows keep
//! working exactly as before.
//!
//! No io, no state: tv_library.zig does the fetching.

const std = @import("std");
const tp = @import("tv_pure.zig");
const cal = @import("tv_calendar_pure.zig");
const cm = @import("cinemeta_pure.zig");
const tvmaze = @import("tvmaze_pure.zig");

// ══════════════════════════════════════════════════════════
// Identity
// ══════════════════════════════════════════════════════════

/// True when `id` is the keyless catalog hash of `imdb` (so not a TMDB id).
pub fn isSynthetic(id: i32, imdb: []const u8) bool {
    return id > 0 and cm.validImdbId(imdb) and cm.stableId(imdb) == id;
}

/// Two different, valid IMDb ids claiming one integer identity.
pub fn identityConflict(stored: []const u8, incoming: []const u8) bool {
    if (!cm.validImdbId(stored) or !cm.validImdbId(incoming)) return false;
    return !std.mem.eql(u8, stored, incoming);
}

/// Which provider answers for a tracked show.
pub const Source = enum {
    /// TMDB /3/tv/{id}: a real TMDB id and a key is available.
    tmdb,
    /// Cinemeta (+ TVmaze) via the remembered IMDb id.
    cinemeta,
    /// No key and no IMDb identity: nothing safe to ask.
    none,
};

/// Decide the provider for a show. A synthetic id always goes keyless, even
/// when a key exists, because asking TMDB about a hash would return some other
/// show entirely.
pub fn chooseSource(id: i32, imdb: []const u8, has_key: bool) Source {
    if (isSynthetic(id, imdb)) return .cinemeta;
    if (has_key) return .tmdb;
    return if (cm.validImdbId(imdb)) .cinemeta else .none;
}

// ══════════════════════════════════════════════════════════
// Show facts from Cinemeta
// ══════════════════════════════════════════════════════════

pub const Facts = struct {
    seasons: [tp.MAX_SEASONS]tp.Season = [_]tp.Season{.{}} ** tp.MAX_SEASONS,
    season_count: usize = 0,
    last: tp.Ep = .{},
    next: tp.Ep = .{},
    next_air_epoch: i64 = 0,
    next_name: [64]u8 = [_]u8{0} ** 64,
    next_name_len: usize = 0,
    ended: bool = false,
    /// At least one regular (non-special) episode was listed.
    has_episodes: bool = false,
    poster: [256]u8 = [_]u8{0} ** 256,
    poster_len: usize = 0,

    pub fn seasonSlice(self: *const Facts) []const tp.Season {
        return self.seasons[0..self.season_count];
    }
    pub fn nextName(self: *const Facts) []const u8 {
        return self.next_name[0..self.next_name_len];
    }
    pub fn posterSlice(self: *const Facts) []const u8 {
        return self.poster[0..self.poster_len];
    }
    fn setNextName(self: *Facts, s: []const u8) void {
        const n = @min(s.len, self.next_name.len);
        @memcpy(self.next_name[0..n], s[0..n]);
        self.next_name_len = n;
    }
};

fn intOf(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (f >= 0 and f < 1e9) @as(i64, @intFromFloat(f)) else null,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn strOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Parse a Cinemeta `meta/series/{imdb}.json` document. `now_s` decides what has
/// aired: an episode counts as aired once its release date (UTC midnight) is not
/// in the future, the same rule the detail page uses.
pub fn parseCinemetaSeries(allocator: std.mem.Allocator, body: []const u8, now_s: i64) !Facts {
    const doc = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer doc.deinit();
    if (doc.value != .object) return error.InvalidSeries;
    const meta_v = doc.value.object.get("meta") orelse return error.InvalidSeries;
    if (meta_v != .object) return error.InvalidSeries;
    const meta = meta_v.object;

    var f: Facts = .{};
    if (strOf(meta, "status")) |s| f.ended = std.mem.eql(u8, s, "Ended") or std.mem.eql(u8, s, "Canceled");
    if (strOf(meta, "poster")) |p| {
        if (cm.compatiblePosterUrl(p, &f.poster)) |u| f.poster_len = u.len;
    }

    const videos_v = meta.get("videos") orelse return f;
    if (videos_v != .array) return f;

    var next_found = false;
    for (videos_v.array.items) |v| {
        if (v != .object) continue;
        const o = v.object;
        const season_i = intOf(o.get("season") orelse continue) orelse continue;
        const ep_v = o.get("episode") orelse o.get("number") orelse continue;
        const ep_i = intOf(ep_v) orelse continue;
        if (season_i < 0 or season_i > 9999 or ep_i < 1 or ep_i > tp.MAX_EPISODES_PER_SEASON) continue;
        const season: i32 = @intCast(season_i);
        const episode: i32 = @intCast(ep_i);

        // Season map: count = highest episode number, like the detail page.
        var idx: ?usize = null;
        for (f.seasons[0..f.season_count], 0..) |s, i| {
            if (s.number == season) {
                idx = i;
                break;
            }
        }
        if (idx == null and f.season_count < f.seasons.len) {
            f.seasons[f.season_count] = .{ .number = season, .episode_count = 0 };
            idx = f.season_count;
            f.season_count += 1;
        }
        if (idx) |i| {
            const cur: i32 = f.seasons[i].episode_count;
            f.seasons[i].episode_count = @intCast(@max(cur, episode));
        }

        if (season < 1) continue; // specials never drive next-up
        f.has_episodes = true;

        const date = strOf(o, "released") orelse strOf(o, "firstAired") orelse continue;
        const epoch = cal.dateToEpoch(date) orelse continue;
        const here: tp.Ep = .{ .season = season, .episode = episode };
        if (epoch <= now_s) {
            if (here.after(f.last)) f.last = here;
        } else if (!next_found or f.next.after(here)) {
            next_found = true;
            f.next = here;
            f.next_air_epoch = epoch;
            const name = strOf(o, "name") orelse strOf(o, "title") orelse "";
            f.setNextName(name);
        }
    }
    std.mem.sort(tp.Season, f.seasons[0..f.season_count], {}, struct {
        fn less(_: void, a: tp.Season, b: tp.Season) bool {
            return a.number < b.number;
        }
    }.less);
    return f;
}

// ══════════════════════════════════════════════════════════
// TVmaze overlay
// ══════════════════════════════════════════════════════════

/// Series status from a TVmaze show object: "Ended" means no more episodes.
pub fn tvmazeEnded(body: []const u8) bool {
    const key = "\"status\":\"";
    const at = std.mem.indexOf(u8, body, key) orelse return false;
    const rest = body[at + key.len ..];
    return std.mem.startsWith(u8, rest, "Ended");
}

/// Prefer TVmaze's scheduled next episode when it is in the future. Cinemeta's
/// own future episode (if any) is kept when TVmaze has none.
pub fn applyTvmazeNext(f: *Facts, next: tvmaze.NextEp, now_s: i64) void {
    const stamp = next.airstamp[0..@min(next.airstamp_len, next.airstamp.len)];
    if (next.season < 1 or next.number < 1 or stamp.len < 10) return;
    const epoch = cal.dateToEpoch(stamp[0..10]) orelse return;
    if (epoch <= now_s) return;
    f.next = .{ .season = next.season, .episode = next.number };
    f.next_air_epoch = epoch;
    f.next_name_len = 0;
}

/// Apply a TVmaze show body (status) to the facts.
pub fn applyTvmazeShow(f: *Facts, body: []const u8) void {
    if (tvmazeEnded(body)) f.ended = true;
}

/// Compact cacheable TVmaze answer: status plus the scheduled next episode.
/// Shaped like TVmaze's own embed so `applyTvmazeShow` / `tvmaze.parseNextEpisode`
/// read it unchanged. `next` is only written when it has a usable stamp.
pub fn tvmazeSummary(ended: bool, next: ?tvmaze.NextEp, out: []u8) ?[]const u8 {
    const status: []const u8 = if (ended) "Ended" else "Running";
    if (next) |n| {
        const stamp = n.airstamp[0..@min(n.airstamp_len, n.airstamp.len)];
        for (stamp) |c| if (c == '"' or c == '\\' or c < 0x20) return null;
        return std.fmt.bufPrint(out, "{{\"status\":\"{s}\",\"_embedded\":{{\"nextepisode\":{{\"season\":{d},\"number\":{d},\"airstamp\":\"{s}\"}}}}}}", .{ status, n.season, n.number, stamp }) catch null;
    }
    return std.fmt.bufPrint(out, "{{\"status\":\"{s}\"}}", .{status}) catch null;
}

test "tvmaze summary round-trips through the overlay readers" {
    var out: [256]u8 = undefined;
    var ne = tvmaze.NextEp{ .season = 2, .number = 7 };
    const stamp = "2026-02-01T02:00:00+00:00";
    @memcpy(ne.airstamp[0..stamp.len], stamp);
    ne.airstamp_len = stamp.len;
    const doc = tvmazeSummary(false, ne, &out).?;
    var f = Facts{};
    applyTvmazeShow(&f, doc);
    try t.expect(!f.ended);
    applyTvmazeNext(&f, tvmaze.parseNextEpisode(doc).?, NOW);
    try t.expectEqual(tp.Ep{ .season = 2, .episode = 7 }, f.next);
    const ended = tvmazeSummary(true, null, &out).?;
    applyTvmazeShow(&f, ended);
    try t.expect(f.ended);
    try t.expect(tvmaze.parseNextEpisode(ended) == null);
}

// ══════════════════════════════════════════════════════════
// Resolving an IMDb id from a name (subtitles, untracked identities)
// ══════════════════════════════════════════════════════════

fn normChar(c: u8) ?u8 {
    return if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else null;
}

/// Case/punctuation-insensitive title equality ("Marvel's Agents of S.H.I.E.L.D."
/// vs "marvels agents of shield").
pub fn sameTitle(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and normChar(a[i]) == null) i += 1;
        while (j < b.len and normChar(b[j]) == null) j += 1;
        if (i >= a.len or j >= b.len) return i >= a.len and j >= b.len;
        if (normChar(a[i]).? != normChar(b[j]).?) return false;
        i += 1;
        j += 1;
    }
}

pub const TitleYear = struct { title: []const u8, year: u16 = 0 };

/// Split a trailing release year off a cleaned query ("Avengers Endgame 2019"
/// -> "Avengers Endgame", 2019). A year-only query keeps its text as the title.
pub fn splitTitleYear(term: []const u8) TitleYear {
    const trimmed = std.mem.trim(u8, term, " ");
    const sp = std.mem.lastIndexOfScalar(u8, trimmed, ' ') orelse return .{ .title = trimmed };
    const tail = trimmed[sp + 1 ..];
    if (tail.len != 4) return .{ .title = trimmed };
    const y = std.fmt.parseInt(u16, tail, 10) catch return .{ .title = trimmed };
    if (y < 1900 or y > 2100) return .{ .title = trimmed };
    return .{ .title = std.mem.trim(u8, trimmed[0..sp], " "), .year = y };
}

test "splitTitleYear strips only a plausible trailing year" {
    const a = splitTitleYear("Avengers Endgame 2019");
    try t.expectEqualStrings("Avengers Endgame", a.title);
    try t.expectEqual(@as(u16, 2019), a.year);
    const b = splitTitleYear("Blade Runner 2049");
    try t.expectEqualStrings("Blade Runner", b.title); // ambiguous by nature; the year filter then rejects a mismatch
    try t.expectEqual(@as(u16, 2049), b.year);
    const c = splitTitleYear("1917");
    try t.expectEqualStrings("1917", c.title);
    try t.expectEqual(@as(u16, 0), c.year);
    const d = splitTitleYear("Se7en");
    try t.expectEqualStrings("Se7en", d.title);
    const e = splitTitleYear("  Dune  ");
    try t.expectEqualStrings("Dune", e.title);
}

/// Pick the IMDb id for `title` (and `year` when known, 0 = unknown) out of a
/// Cinemeta catalog search body. Only an exact title match is accepted; a year,
/// when given, must be the release year or the first year of a range. The search
/// ranks by popularity, so the first acceptable match wins. Never "the first
/// result": a wrong id would pull another show's subtitles.
pub fn pickImdb(allocator: std.mem.Allocator, body: []const u8, title: []const u8, year: u16, out: []u8) ![]const u8 {
    const doc = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer doc.deinit();
    if (doc.value != .object) return "";
    const metas = doc.value.object.get("metas") orelse return "";
    if (metas != .array) return "";
    for (metas.array.items) |m| {
        if (m != .object) continue;
        const o = m.object;
        const id = strOf(o, "imdb_id") orelse strOf(o, "id") orelse continue;
        if (!cm.validImdbId(id) or id.len > out.len) continue;
        const name = strOf(o, "name") orelse continue;
        if (!sameTitle(name, title)) continue;
        if (year != 0) {
            const y = strOf(o, "releaseInfo") orelse strOf(o, "year") orelse "";
            if (y.len >= 4) {
                const first = std.fmt.parseInt(u16, y[0..4], 10) catch 0;
                if (first != 0 and first != year) continue;
            }
        }
        @memcpy(out[0..id.len], id);
        return out[0..id.len];
    }
    return "";
}

/// Poster URL of the catalog entry `imdb` in a Cinemeta search body, in a
/// decoder-compatible form. Empty when absent.
pub fn catalogPoster(allocator: std.mem.Allocator, body: []const u8, imdb: []const u8, out: []u8) ![]const u8 {
    const doc = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer doc.deinit();
    if (doc.value != .object) return "";
    const metas = doc.value.object.get("metas") orelse return "";
    if (metas != .array) return "";
    for (metas.array.items) |m| {
        if (m != .object) continue;
        const id = strOf(m.object, "imdb_id") orelse strOf(m.object, "id") orelse continue;
        if (!std.mem.eql(u8, id, imdb)) continue;
        const p = strOf(m.object, "poster") orelse return "";
        return cm.compatiblePosterUrl(p, out) orelse "";
    }
    return "";
}

test "catalogPoster finds the exact entry's artwork" {
    var out: [256]u8 = undefined;
    const body = "{\"metas\":[{\"id\":\"tt1\",\"poster\":\"https://a.test/1.jpg\"},{\"id\":\"tt2\",\"poster\":\"https://images.metahub.space/poster/small/tt2/img\"}]}";
    try t.expectEqualStrings("https://images.metahub.space/poster/small/tt2/img.jpg", try catalogPoster(t.allocator, body, "tt2", &out));
    try t.expectEqualStrings("", try catalogPoster(t.allocator, body, "tt3", &out));
}

// ══════════════════════════════════════════════════════════
// Artwork and external ids
// ══════════════════════════════════════════════════════════

/// Fully-qualified poster URL from whatever the show row stored: an absolute URL
/// (Cinemeta), a TMDB relative path, or nothing (then the IMDb poster on
/// Metahub, a short stable URL).
pub fn posterUrl(stored: []const u8, imdb: []const u8, out: []u8) []const u8 {
    if (std.mem.startsWith(u8, stored, "https://") or std.mem.startsWith(u8, stored, "http://")) {
        return cm.compatiblePosterUrl(stored, out) orelse "";
    }
    if (std.mem.startsWith(u8, stored, "/")) {
        return std.fmt.bufPrint(out, "https://image.tmdb.org/t/p/w185{s}", .{stored}) catch "";
    }
    if (cm.validImdbId(imdb)) {
        return std.fmt.bufPrint(out, "https://images.metahub.space/poster/small/{s}/img.jpg", .{imdb}) catch "";
    }
    return "";
}

/// The `ids` object body for a scrobble service. Real TMDB ids go as `tmdb`;
/// a synthetic id is sent as `imdb` so the wrong show is never marked.
/// `quote_tmdb` is for services that want the tmdb id as a string.
pub fn externalIds(id: i32, imdb: []const u8, quote_tmdb: bool, out: []u8) ?[]const u8 {
    if (isSynthetic(id, imdb)) return std.fmt.bufPrint(out, "\"imdb\":\"{s}\"", .{imdb}) catch null;
    if (id <= 0) return null;
    return (if (quote_tmdb)
        std.fmt.bufPrint(out, "\"tmdb\":\"{d}\"", .{id})
    else
        std.fmt.bufPrint(out, "\"tmdb\":{d}", .{id})) catch null;
}

// ══════════════════════════════════════════════════════════
// Tests (small fixtures)
// ══════════════════════════════════════════════════════════

const t = std.testing;

// 2026-01-10 00:00 UTC
const NOW: i64 = 1_768_003_200;

const series_fixture =
    \\{"meta":{"imdb_id":"tt1","name":"Show","status":"Continuing",
    \\ "poster":"https://images.metahub.space/poster/small/tt1/img",
    \\ "videos":[
    \\ {"name":"Sneak Peek","season":0,"number":1,"released":"2025-01-01T05:00:00.000Z","episode":1},
    \\ {"name":"Pilot","season":1,"number":1,"released":"2025-01-01T05:00:00.000Z","episode":1},
    \\ {"name":"Two","season":1,"number":2,"released":"2025-01-08T05:00:00.000Z","episode":2},
    \\ {"name":"Three","season":1,"number":3,"released":"2026-01-09T05:00:00.000Z","episode":3},
    \\ {"name":"Four, \"quoted\"","season":1,"number":4,"released":"2026-01-16T05:00:00.000Z","episode":4},
    \\ {"name":"Five","season":1,"number":5,"released":"2026-01-23T05:00:00.000Z","episode":5},
    \\ {"name":"S2E1","season":2,"episode":1}
    \\ ]}}
;

test "series facts: season map, aired frontier, next episode" {
    const f = try parseCinemetaSeries(t.allocator, series_fixture, NOW);
    try t.expectEqual(@as(usize, 3), f.season_count);
    try t.expectEqual(@as(i32, 0), f.seasons[0].number);
    try t.expectEqual(@as(u16, 5), f.seasons[1].episode_count);
    try t.expectEqual(@as(u16, 1), f.seasons[2].episode_count);
    try t.expectEqual(tp.Ep{ .season = 1, .episode = 3 }, f.last);
    try t.expectEqual(tp.Ep{ .season = 1, .episode = 4 }, f.next);
    try t.expectEqual(cal.dateToEpoch("2026-01-16").?, f.next_air_epoch);
    try t.expectEqualStrings("Four, \"quoted\"", f.nextName());
    try t.expect(!f.ended and f.has_episodes);
    try t.expectEqualStrings("https://images.metahub.space/poster/small/tt1/img.jpg", f.posterSlice());
}

test "series facts: facts feed nextUp without a phantom unaired episode" {
    const f = try parseCinemetaSeries(t.allocator, series_fixture, NOW);
    const watched = [_]tp.Ep{ .{ .season = 1, .episode = 1 }, .{ .season = 1, .episode = 2 } };
    const nxt = tp.nextUp(f.seasonSlice(), &watched, f.last).?;
    try t.expectEqual(tp.Ep{ .season = 1, .episode = 3 }, nxt);
    const all = [_]tp.Ep{ .{ .season = 1, .episode = 1 }, .{ .season = 1, .episode = 2 }, .{ .season = 1, .episode = 3 } };
    try t.expect(tp.nextUp(f.seasonSlice(), &all, f.last) == null);
}

test "series facts: ended status, missing dates and malformed documents" {
    const ended = try parseCinemetaSeries(t.allocator, "{\"meta\":{\"status\":\"Ended\",\"videos\":[{\"season\":1,\"episode\":1}]}}", NOW);
    try t.expect(ended.ended);
    try t.expectEqual(@as(i32, 0), ended.last.season);
    try t.expectEqual(@as(usize, 1), ended.season_count);
    const none = try parseCinemetaSeries(t.allocator, "{\"meta\":{\"name\":\"x\"}}", NOW);
    try t.expectEqual(@as(usize, 0), none.season_count);
    try t.expectError(error.InvalidSeries, parseCinemetaSeries(t.allocator, "{\"nope\":1}", NOW));
    try t.expectError(error.InvalidSeries, parseCinemetaSeries(t.allocator, "[1]", NOW));
    try t.expect(std.meta.isError(parseCinemetaSeries(t.allocator, "{not json", NOW)));
}

test "series facts: string numbers and the 'number' field are accepted, junk skipped" {
    const body =
        \\{"meta":{"videos":[{"season":"1","number":"2","released":"2025-02-01"},{"season":-1,"number":3},{"season":1},{"number":1},"x"]}}
    ;
    const f = try parseCinemetaSeries(t.allocator, body, NOW);
    try t.expectEqual(@as(usize, 1), f.season_count);
    try t.expectEqual(@as(u16, 2), f.seasons[0].episode_count);
    try t.expectEqual(tp.Ep{ .season = 1, .episode = 2 }, f.last);
}

test "tvmaze overlay: future next episode wins, past or malformed is ignored" {
    var f = try parseCinemetaSeries(t.allocator, series_fixture, NOW);
    var ne = tvmaze.NextEp{ .season = 1, .number = 4 };
    const stamp = "2026-01-17T02:00:00+00:00";
    @memcpy(ne.airstamp[0..stamp.len], stamp);
    ne.airstamp_len = stamp.len;
    applyTvmazeNext(&f, ne, NOW);
    try t.expectEqual(cal.dateToEpoch("2026-01-17").?, f.next_air_epoch);

    var g = Facts{};
    var past = tvmaze.NextEp{ .season = 2, .number = 1 };
    const old = "2020-01-01";
    @memcpy(past.airstamp[0..old.len], old);
    past.airstamp_len = old.len;
    applyTvmazeNext(&g, past, NOW);
    try t.expectEqual(@as(i64, 0), g.next_air_epoch);
    applyTvmazeNext(&g, .{}, NOW);
    try t.expectEqual(@as(i32, 0), g.next.season);

    applyTvmazeShow(&g, "{\"id\":1,\"status\":\"Ended\"}");
    try t.expect(g.ended);
    var h = Facts{};
    applyTvmazeShow(&h, "{\"id\":1,\"status\":\"Running\"}");
    try t.expect(!h.ended);
}

test "identity: synthetic ids are recognised, conflicts refused, sources chosen safely" {
    const imdb = "tt0903747";
    const id = cm.stableId(imdb);
    try t.expect(isSynthetic(id, imdb));
    try t.expect(!isSynthetic(1396, imdb)); // a real TMDB id for the same show
    try t.expect(!isSynthetic(id, ""));
    try t.expect(!isSynthetic(id, "bogus"));
    try t.expect(identityConflict("tt0903747", "tt0944947"));
    try t.expect(!identityConflict("tt0903747", "tt0903747"));
    try t.expect(!identityConflict("", "tt0944947"));

    try t.expectEqual(Source.cinemeta, chooseSource(id, imdb, true)); // key never makes a hash a TMDB id
    try t.expectEqual(Source.cinemeta, chooseSource(id, imdb, false));
    try t.expectEqual(Source.tmdb, chooseSource(1396, "", true));
    try t.expectEqual(Source.tmdb, chooseSource(1396, imdb, true)); // existing keyed row keeps TMDB
    try t.expectEqual(Source.cinemeta, chooseSource(1396, imdb, false)); // keyless, but identity known
    try t.expectEqual(Source.none, chooseSource(1396, "", false));
}

test "two different shows never share a synthetic identity" {
    const a = "tt0903747";
    const b = "tt0944947";
    try t.expect(cm.stableId(a) != cm.stableId(b));
    try t.expect(!isSynthetic(cm.stableId(a), b));
}

test "title matching ignores case and punctuation but not content" {
    try t.expect(sameTitle("Marvel's Agents of S.H.I.E.L.D.", "marvels agents of shield"));
    try t.expect(sameTitle("  Severance ", "severance"));
    try t.expect(!sameTitle("Severance", "Severance Part 2"));
    try t.expect(!sameTitle("", "x"));
}

const search_fixture =
    \\{"metas":[
    \\ {"id":"tt0000001","name":"The Office","releaseInfo":"2001–2003","type":"series"},
    \\ {"id":"tt0386676","name":"The Office","releaseInfo":"2005–2013","type":"series"},
    \\ {"id":"tt2","name":"The Office Space","releaseInfo":"1999"},
    \\ {"id":"nm1","name":"The Office"}]}
;

test "pickImdb: exact title, year-aware, never the first result blindly" {
    var out: [16]u8 = undefined;
    try t.expectEqualStrings("tt0386676", try pickImdb(t.allocator, search_fixture, "the office", 2005, &out));
    try t.expectEqualStrings("tt0000001", try pickImdb(t.allocator, search_fixture, "The Office", 0, &out));
    try t.expectEqualStrings("", try pickImdb(t.allocator, search_fixture, "The Office", 1990, &out));
    try t.expectEqualStrings("", try pickImdb(t.allocator, search_fixture, "Parks and Recreation", 0, &out));
    try t.expectEqualStrings("", try pickImdb(t.allocator, "{\"metas\":[]}", "x", 0, &out));
    try t.expectEqualStrings("", try pickImdb(t.allocator, "[]", "x", 0, &out));
}

test "poster URLs: absolute, TMDB relative, imdb fallback, unknown" {
    var b: [320]u8 = undefined;
    try t.expectEqualStrings("https://images.metahub.space/poster/small/tt1/img.jpg", posterUrl("https://images.metahub.space/poster/small/tt1/img", "", &b));
    try t.expectEqualStrings("https://m.media-amazon.com/x.jpg", posterUrl("https://m.media-amazon.com/x.jpg", "tt1", &b));
    try t.expectEqualStrings("https://image.tmdb.org/t/p/w185/abc.jpg", posterUrl("/abc.jpg", "", &b));
    try t.expectEqualStrings("https://images.metahub.space/poster/small/tt1234567/img.jpg", posterUrl("", "tt1234567", &b));
    try t.expectEqualStrings("", posterUrl("", "", &b));
}

test "external ids: synthetic goes as imdb, real as tmdb" {
    var b: [64]u8 = undefined;
    const imdb = "tt0903747";
    try t.expectEqualStrings("\"imdb\":\"tt0903747\"", externalIds(cm.stableId(imdb), imdb, false, &b).?);
    try t.expectEqualStrings("\"tmdb\":1396", externalIds(1396, imdb, false, &b).?);
    try t.expectEqualStrings("\"tmdb\":\"1396\"", externalIds(1396, "", true, &b).?);
    try t.expect(externalIds(0, "", false, &b) == null);
}
