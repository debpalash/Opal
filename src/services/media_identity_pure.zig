//! One canonical media/action identity shared by the native app and the remote
//! JSON API (and through it, web/index.html).
//!
//! Before this module every surface answered "is this the same title, and what
//! can I do with it?" on its own: native search picked a verb per source, the
//! web had its own `unifiedActionLabel` table, grouping compared raw IMDb text,
//! and the browser re-derived its own work key. They drifted. Now:
//!
//! - `Identity` names the media: kind, provider ids, and show/season/episode
//!   (with anime absolute numbering kept separately, not guessed).
//! - `compare` decides sameness across TMDB / IMDb / TVDB / AniList / MAL ids
//!   and across absolute-vs-season episode numbering. It answers `.unknown`
//!   rather than guess when the two sides share no evidence.
//! - `Targets` + `actions` turn "where can this play" into explicit, ordered
//!   actions with fixed labels ("Play here", "Play on Opal", "Queue", ...).
//! - `Progress` carries resume position and watched state using the same
//!   thresholds as server progress sync.
//! - `writeJson` is the one wire shape; `Selection` tokens stop a late async
//!   result from landing on a title the user has since navigated away from.
//!
//! Pure: no I/O, no allocation, fixed vocabulary in the JSON (no escaping).

const std = @import("std");
const progress_rules = @import("server_progress_pure.zig");
const playback = @import("playback_target_pure.zig");

// ── Kind ──

pub const Kind = enum { movie, show, season, episode, video, audio, book, live, other };

/// Provider id namespaces are per family: TMDB movie 1399 and TMDB TV 1399
/// are unrelated titles, so ids only compare within a family.
pub const Family = enum { film, series, other };

pub fn family(kind: Kind) Family {
    return switch (kind) {
        .movie => .film,
        .show, .season, .episode => .series,
        else => .other,
    };
}

/// Catalog kind strings as providers spell them ("tv", "series", "Movie", ...).
pub fn kindFromCatalog(text: []const u8) ?Kind {
    const table = [_]struct { []const u8, Kind }{
        .{ "movie", .movie },     .{ "film", .movie },
        .{ "tv", .show },         .{ "series", .show },
        .{ "show", .show },       .{ "season", .season },
        .{ "episode", .episode },
    };
    for (table) |entry| if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
    return null;
}

/// Fallback kind from the source that produced a row with no catalog kind.
pub fn kindFromSource(source: []const u8) Kind {
    const table = [_]struct { []const u8, Kind }{
        .{ "music", .audio },     .{ "radio", .audio },      .{ "podcast", .audio },
        .{ "audiobooks", .audio }, .{ "comics", .book },     .{ "novels", .book },
        .{ "opds", .book },       .{ "livetv", .live },      .{ "youtube", .video },
    };
    for (table) |entry| if (std.mem.eql(u8, source, entry[0])) return entry[1];
    return .other;
}

// ── Provider ids ──

pub const Namespace = enum { imdb, tmdb, tvdb, anilist, mal };
/// Strength order for keys: imdb is what cross-provider rows share.
const NAMESPACES = [_]Namespace{ .imdb, .tmdb, .tvdb, .anilist, .mal };

/// Zero means "not known". IMDb is stored as its number so `tt0944947`,
/// `TT944947`, and an imdb.com URL all normalise to one value.
pub const Ids = struct {
    imdb: u32 = 0,
    tmdb: u32 = 0,
    tvdb: u32 = 0,
    anilist: u32 = 0,
    mal: u32 = 0,

    pub fn get(self: Ids, ns: Namespace) u32 {
        return switch (ns) {
            .imdb => self.imdb,
            .tmdb => self.tmdb,
            .tvdb => self.tvdb,
            .anilist => self.anilist,
            .mal => self.mal,
        };
    }

    pub fn set(self: *Ids, ns: Namespace, value: u32) void {
        switch (ns) {
            .imdb => self.imdb = value,
            .tmdb => self.tmdb = value,
            .tvdb => self.tvdb = value,
            .anilist => self.anilist = value,
            .mal => self.mal = value,
        }
    }

    pub fn any(self: Ids) bool {
        return self.imdb | self.tmdb | self.tvdb | self.anilist | self.mal != 0;
    }
};

pub const ParsedId = struct { ns: Namespace, value: u32, family: ?Family = null };

fn digitsAt(text: []const u8, start: usize) ?u32 {
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == start or end - start > 10) return null;
    const value = std.fmt.parseInt(u32, text[start..end], 10) catch return null;
    return if (value == 0) null else value;
}

fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or hay.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// `tt0944947`, `TT944947`, `imdb:tt0944947`, or an imdb.com/title URL.
/// The `tt` must start a token and the digits must end one, so `attt1` and
/// `tt12x` are not ids.
pub fn parseImdb(text: []const u8) ?u32 {
    var from: usize = 0;
    while (from + 2 <= text.len) : (from += 1) {
        const at = from;
        if (!std.ascii.eqlIgnoreCase(text[at .. at + 2], "tt")) continue;
        if (at > 0 and std.ascii.isAlphanumeric(text[at - 1])) continue;
        var end = at + 2;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        if (end == at + 2 or end - (at + 2) > 10) continue;
        if (end < text.len and std.ascii.isAlphanumeric(text[end])) continue;
        const value = std.fmt.parseInt(u32, text[at + 2 .. end], 10) catch continue;
        if (value != 0) return value;
    }
    return null;
}

/// Parse one provider id in any common written form:
/// `tt0944947`, `imdb:tt0944947`, `tmdb:1399`, `tmdb:tv:1399`,
/// `tvdb:121361`, `anilist:21`, `mal:21`, or the provider's own web URL.
pub fn parseId(raw: []const u8) ?ParsedId {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;
    if (indexOfIgnoreCase(text, "imdb") != null or std.ascii.startsWithIgnoreCase(text, "tt")) {
        if (parseImdb(text)) |value| return .{ .ns = .imdb, .value = value };
        return null;
    }
    const Prefix = struct { []const u8, Namespace, ?Family };
    const prefixes = [_]Prefix{
        .{ "tmdb:movie:", .tmdb, .film },      .{ "tmdb:tv:", .tmdb, .series },
        .{ "tmdb:series:", .tmdb, .series },   .{ "tmdb:", .tmdb, null },
        .{ "tvdb:", .tvdb, .series },          .{ "anilist:", .anilist, .series },
        .{ "mal:", .mal, .series },            .{ "themoviedb.org/movie/", .tmdb, .film },
        .{ "themoviedb.org/tv/", .tmdb, .series }, .{ "thetvdb.com/dereferrer/series/", .tvdb, .series },
        .{ "thetvdb.com/?tab=series&id=", .tvdb, .series }, .{ "anilist.co/anime/", .anilist, .series },
        .{ "myanimelist.net/anime/", .mal, .series },
    };
    for (prefixes) |p| {
        const at = indexOfIgnoreCase(text, p[0]) orelse continue;
        const value = digitsAt(text, at + p[0].len) orelse return null;
        return .{ .ns = p[1], .value = value, .family = p[2] };
    }
    return null;
}

/// Canonical IMDb spelling: `tt` + at least seven digits.
pub fn formatImdb(value: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "tt{d:0>7}", .{value}) catch "";
}

// ── Episode numbering ──

/// Season/episode as the catalog numbers them, plus the anime absolute
/// number when a source uses it (One Piece 1000, not S21E108). They are kept
/// apart: converting needs the per-season episode counts, which the caller
/// supplies to `compare` when it has them.
pub const Numbering = struct {
    season: ?u16 = null,
    episode: ?u16 = null,
    absolute: ?u16 = null,

    pub fn any(self: Numbering) bool {
        return self.episode != null or self.absolute != null;
    }
};

pub const SeasonEpisode = struct { season: u16, episode: u16 };

/// `season_lengths[0]` is season 1's episode count. Specials (season 0) are
/// outside absolute numbering.
pub fn toSeason(season_lengths: []const u16, absolute: u16) ?SeasonEpisode {
    if (absolute == 0) return null;
    var remaining: u32 = absolute;
    for (season_lengths, 0..) |len, i| {
        if (len == 0) return null;
        if (remaining <= len) return .{ .season = @intCast(i + 1), .episode = @intCast(remaining) };
        remaining -= len;
    }
    return null;
}

pub fn toAbsolute(season_lengths: []const u16, season: u16, episode: u16) ?u16 {
    if (season == 0 or episode == 0 or season > season_lengths.len) return null;
    if (episode > season_lengths[season - 1]) return null;
    var total: u32 = episode;
    for (season_lengths[0 .. season - 1]) |len| total += len;
    return std.math.cast(u16, total);
}

// ── Identity ──

pub const Identity = struct {
    kind: Kind = .other,
    ids: Ids = .{},
    numbering: Numbering = .{},
    /// Opaque source-local identity (a stable row hash) for media no provider
    /// id describes: a YouTube video, a local file, a radio station.
    local: u64 = 0,

    pub fn addId(self: *Identity, parsed: ParsedId) void {
        self.ids.set(parsed.ns, parsed.value);
    }
};

/// Build an identity from typed catalog fields (search rows, library rows).
/// `tmdb_id` is only meaningful when the row came from TMDB; other sources'
/// numeric ids live in their own namespaces and must not be passed here.
pub fn fromCatalog(kind_text: []const u8, source: []const u8, tmdb_id: i64, imdb_text: []const u8) Identity {
    var out = Identity{ .kind = kindFromCatalog(kind_text) orelse kindFromSource(source) };
    if (tmdb_id > 0 and tmdb_id <= std.math.maxInt(u32)) out.ids.tmdb = @intCast(tmdb_id);
    if (parseImdb(imdb_text)) |value| out.ids.imdb = value;
    return out;
}

pub const Match = enum { same, different, unknown };

/// Same title, ignoring episode numbering. Any namespace both sides carry
/// must agree; at least one must be shared to say `.same`.
pub fn compareTitle(a: Identity, b: Identity) Match {
    if (family(a.kind) != family(b.kind)) return .different;
    var agree: u8 = 0;
    for (NAMESPACES) |ns| {
        const x = a.ids.get(ns);
        const y = b.ids.get(ns);
        if (x != 0 and y != 0) {
            if (x != y) return .different;
            agree += 1;
        }
    }
    if (agree > 0) return .same;
    if (a.local != 0 and b.local != 0) return if (a.local == b.local) .same else .different;
    return .unknown;
}

/// Same media, episode included. `season_lengths` converts between anime
/// absolute and season numbering; pass `&.{}` when unknown — a mixed pair is
/// then `.unknown`, never a guess.
pub fn compare(a: Identity, b: Identity, season_lengths: []const u16) Match {
    const title = compareTitle(a, b);
    if (title != .same) return title;
    const x = a.numbering;
    const y = b.numbering;
    if (!x.any() and !y.any()) return .same;
    if (x.any() != y.any()) return .different; // a show is not one of its episodes
    var decided = false;
    if (x.season != null and x.episode != null and y.season != null and y.episode != null) {
        if (x.season.? != y.season.? or x.episode.? != y.episode.?) return .different;
        decided = true;
    }
    if (x.absolute != null and y.absolute != null) {
        if (x.absolute.? != y.absolute.?) return .different;
        decided = true;
    }
    if (decided) return .same;
    // One side numbers by season, the other by absolute episode.
    const abs_side = if (x.absolute != null) x else y;
    const season_side = if (x.absolute != null) y else x;
    const se_season = season_side.season orelse return .unknown;
    const se_episode = season_side.episode orelse return .unknown;
    const converted = toAbsolute(season_lengths, se_season, se_episode) orelse return .unknown;
    return if (converted == abs_side.absolute.?) .same else .different;
}

/// Stable, human-readable key: family, strongest id, then numbering.
/// Strength order is imdb > tmdb > tvdb > anilist > mal (imdb is what
/// cross-provider rows share). Two equal identities can still have different
/// keys when one lacks the stronger id — use `compare` for equality; the key
/// addresses a selection and dedups rows that carry the same strongest id.
pub fn key(identity: Identity, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeKey(&w, identity) catch return "";
    return buf[0..w.end];
}

fn writeKey(w: *std.Io.Writer, identity: Identity) !void {
    try w.writeAll(@tagName(family(identity.kind)));
    var wrote = false;
    for (NAMESPACES) |ns| {
        const value = identity.ids.get(ns);
        if (value == 0) continue;
        wrote = true;
        if (ns == .imdb) {
            try w.print(":imdb:tt{d:0>7}", .{value});
        } else try w.print(":{s}:{d}", .{ @tagName(ns), value });
        break;
    }
    if (!wrote) try w.print(":local:{x}", .{identity.local});
    const n = identity.numbering;
    if (n.season != null and n.episode != null) {
        try w.print(":s{d}e{d}", .{ n.season.?, n.episode.? });
    } else if (n.absolute) |abs| try w.print(":a{d}", .{abs});
}

// ── Targets and actions ──

/// Where the browser stands on this media. `none` means the web has no
/// browser-reachable stream for it at all (private transport, host-only).
pub const Here = enum { none, direct, hls, transcode, unsupported };

pub fn hereFor(name: []const u8) Here {
    return switch (playback.classify(name)) {
        .direct => .direct,
        .hls => .hls,
        .transcode => .transcode,
        .unsupported => .unsupported,
    };
}

pub const Targets = struct {
    here: Here = .none,
    /// The desktop/host player can open it.
    opal: bool = false,
    /// A durable media target exists, so it can join the playback queue.
    queue: bool = false,
    download: bool = false,

    pub fn playHere(self: Targets) bool {
        return self.here == .direct or self.here == .hls or self.here == .transcode;
    }
};

pub const Action = enum {
    play_here,
    play_on_opal,
    queue,
    download,
    details,
    read,
    open,
    open_audio,

    pub fn label(self: Action) []const u8 {
        return switch (self) {
            .play_here => "Play here",
            .play_on_opal => "Play on Opal",
            .queue => "Queue",
            .download => "Download",
            .details => "View details",
            .read => "Read",
            .open => "Open",
            .open_audio => "Open audio",
        };
    }
};

/// The primary verb a search source offers. Catalog and reader sources do
/// not "play"; everything else is a playback target on the host.
pub fn primaryFor(source: []const u8) Action {
    const table = [_]struct { []const u8, Action }{
        .{ "comics", .read },     .{ "novels", .read },        .{ "opds", .read },
        .{ "vndb", .details },    .{ "tmdb", .details },       .{ "audiobooks", .open_audio },
        .{ "podcast", .open },    .{ "anime", .open },
    };
    for (table) |entry| if (std.mem.eql(u8, source, entry[0])) return entry[1];
    return .play_on_opal;
}

pub const MAX_ACTIONS = 4;

/// Ordered, explicit actions. When the primary verb is playback, every real
/// target gets its own labelled action — "Play here" and "Play on Opal" are
/// never folded into one toggle-dependent button. Queue follows playback.
pub fn actions(primary: Action, targets: Targets, out: *[MAX_ACTIONS]Action) []const Action {
    var n: usize = 0;
    if (primary == .play_on_opal or primary == .play_here) {
        if (targets.playHere()) {
            out[n] = .play_here;
            n += 1;
        }
        if (targets.opal) {
            out[n] = .play_on_opal;
            n += 1;
        }
    } else {
        out[n] = primary;
        n += 1;
    }
    if (targets.queue) {
        out[n] = .queue;
        n += 1;
    }
    if (targets.download) {
        out[n] = .download;
        n += 1;
    }
    return out[0..n];
}

// ── Resume and watched ──

pub const Progress = struct {
    /// Seconds to resume from; 0 when there is nothing to resume.
    resume_at: f64 = 0,
    duration: f64 = 0,
    watched: bool = false,
};

/// Same thresholds as server progress sync (≥95% is finished), so a title is
/// "watched" identically on the desktop, the web, and the media server.
pub fn progressFrom(position: f64, duration: f64, marked_watched: bool) Progress {
    const valid = progress_rules.validProgress(position, duration);
    const watched = marked_watched or progress_rules.isFinished(position, duration);
    return .{
        .resume_at = if (valid and !watched) @min(position, duration) else 0,
        .duration = if (valid) duration else 0,
        .watched = watched,
    };
}

// ── Wire shape ──

pub const Card = struct {
    identity: Identity,
    primary: Action = .play_on_opal,
    targets: Targets = .{},
    progress: Progress = .{},
};

/// The one JSON shape (an object, no trailing comma):
/// {"key":"series:imdb:tt0944947:s1e1","kind":"episode",
///  "ids":{"imdb":"tt0944947","tmdb":1399},
///  "season":1,"episode":1,"absolute":null,
///  "resume":0,"duration":0,"watched":false,
///  "targets":{"here":"none","opal":true,"queue":true,"download":false},
///  "actions":[{"id":"play_on_opal","label":"Play on Opal"},{"id":"queue","label":"Queue"}]}
pub fn writeJson(w: *std.Io.Writer, card: Card) !void {
    const id = card.identity;
    try w.writeAll("{\"key\":\"");
    try writeKey(w, id);
    try w.print("\",\"kind\":\"{s}\",\"ids\":{{", .{@tagName(id.kind)});
    var first = true;
    for (NAMESPACES) |ns| {
        const value = id.ids.get(ns);
        if (value == 0) continue;
        if (!first) try w.writeAll(",");
        first = false;
        if (ns == .imdb) {
            try w.print("\"imdb\":\"tt{d:0>7}\"", .{value});
        } else try w.print("\"{s}\":{d}", .{ @tagName(ns), value });
    }
    try w.writeAll("}");
    inline for (.{ "season", "episode", "absolute" }) |name| {
        if (@field(id.numbering, name)) |value| {
            try w.print(",\"" ++ name ++ "\":{d}", .{value});
        } else try w.writeAll(",\"" ++ name ++ "\":null");
    }
    const p = card.progress;
    try w.print(",\"resume\":{d:.0},\"duration\":{d:.0},\"watched\":{s}", .{ p.resume_at, p.duration, if (p.watched) "true" else "false" });
    const t = card.targets;
    try w.print(",\"targets\":{{\"here\":\"{s}\",\"opal\":{s},\"queue\":{s},\"download\":{s}}},\"actions\":[", .{
        @tagName(t.here), if (t.opal) "true" else "false", if (t.queue) "true" else "false", if (t.download) "true" else "false",
    });
    var list: [MAX_ACTIONS]Action = undefined;
    for (actions(card.primary, t, &list), 0..) |action, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"id\":\"{s}\",\"label\":\"{s}\"}}", .{ @tagName(action), action.label() });
    }
    try w.writeAll("]}");
}

// ── Selection tokens ──

/// What the user has selected right now. Every async fetch for a selection
/// captures a `Token`; the result is applied only if the token still matches,
/// so a slow answer for title A can never paint onto title B.
pub const Token = struct { generation: u32 = 0, key_hash: u64 = 0 };

pub const Selection = struct {
    generation: u32 = 0,
    key_hash: u64 = 0,

    pub fn select(self: *Selection, selection_key: []const u8) Token {
        self.generation +%= 1;
        self.key_hash = std.hash.Wyhash.hash(0x6f70616c_69640001, selection_key);
        return self.token();
    }

    pub fn clear(self: *Selection) void {
        self.generation +%= 1;
        self.key_hash = 0;
    }

    pub fn token(self: Selection) Token {
        return .{ .generation = self.generation, .key_hash = self.key_hash };
    }

    /// Strict: the same selection event (re-selecting A after B is a new one).
    pub fn isCurrent(self: Selection, t: Token) bool {
        return self.key_hash != 0 and t.generation == self.generation and t.key_hash == self.key_hash;
    }

    /// Lenient: the same title is still selected, whenever it was selected.
    /// For idempotent results (an id lookup for A is valid for A forever).
    pub fn isSameTitle(self: Selection, t: Token) bool {
        return self.key_hash != 0 and t.key_hash == self.key_hash;
    }
};

pub const Verdict = enum { apply, discard, discard_and_refetch };

/// Decide what to do with a title-level async result (an id lookup, a
/// metadata document) that finished just now. It applies only to the title it
/// was fetched for. When it belonged to a previous title and the current one
/// is still waiting behind the same single-flight worker, the caller must
/// refetch for the current title — otherwise the new title waits forever.
pub fn titleResult(selection: Selection, t: Token, current_waiting: bool) Verdict {
    if (selection.isSameTitle(t)) return .apply;
    return if (current_waiting) .discard_and_refetch else .discard;
}

// ── Tests ──

const testing = std.testing;

test "parseId: IMDb forms normalise to one value" {
    const forms = [_][]const u8{ "tt0944947", "TT0944947", "tt944947", "imdb:tt0944947", "https://www.imdb.com/title/tt0944947/", " tt0944947 " };
    for (forms) |form| {
        const parsed = parseId(form) orelse return error.TestUnexpectedNull;
        try testing.expectEqual(Namespace.imdb, parsed.ns);
        try testing.expectEqual(@as(u32, 944947), parsed.value);
    }
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("tt0944947", formatImdb(944947, &buf));
    try testing.expectEqualStrings("tt10872600", formatImdb(10872600, &buf));
}

test "parseId: rejects junk and partial ids" {
    for ([_][]const u8{ "", "tt", "ttabc", "tt0", "tmdb:", "tmdb:abc", "tt123x", "1399", "attt123" }) |junk|
        try testing.expect(parseId(junk) == null);
}

test "parseId: TMDB, TVDB, AniList and MAL forms carry their family" {
    const cases = [_]struct { []const u8, Namespace, u32, ?Family }{
        .{ "tmdb:1399", .tmdb, 1399, null },
        .{ "tmdb:tv:1399", .tmdb, 1399, .series },
        .{ "tmdb:movie:550", .tmdb, 550, .film },
        .{ "https://www.themoviedb.org/tv/1399-game-of-thrones", .tmdb, 1399, .series },
        .{ "https://www.themoviedb.org/movie/550-fight-club", .tmdb, 550, .film },
        .{ "tvdb:121361", .tvdb, 121361, .series },
        .{ "https://thetvdb.com/dereferrer/series/121361", .tvdb, 121361, .series },
        .{ "anilist:21", .anilist, 21, .series },
        .{ "https://anilist.co/anime/21/one-piece/", .anilist, 21, .series },
        .{ "https://myanimelist.net/anime/21/One_Piece", .mal, 21, .series },
    };
    for (cases) |c| {
        const parsed = parseId(c[0]) orelse return error.TestUnexpectedNull;
        try testing.expectEqual(c[1], parsed.ns);
        try testing.expectEqual(c[2], parsed.value);
        try testing.expectEqual(c[3], parsed.family);
    }
}

test "compareTitle: TMDB-only and IMDb-only rows share no evidence" {
    const tmdb_only = Identity{ .kind = .show, .ids = .{ .tmdb = 1399 } };
    const imdb_only = Identity{ .kind = .show, .ids = .{ .imdb = 944947 } };
    try testing.expectEqual(Match.unknown, compareTitle(tmdb_only, imdb_only));
    const both = Identity{ .kind = .show, .ids = .{ .tmdb = 1399, .imdb = 944947, .tvdb = 121361 } };
    try testing.expectEqual(Match.same, compareTitle(tmdb_only, both));
    try testing.expectEqual(Match.same, compareTitle(imdb_only, both));
    const tvdb_only = Identity{ .kind = .episode, .ids = .{ .tvdb = 121361 } };
    try testing.expectEqual(Match.same, compareTitle(both, tvdb_only));
}

test "compareTitle: any conflicting namespace means different titles" {
    // Same IMDb id but a different TVDB id is a bad mapping, not a match.
    const a = Identity{ .kind = .show, .ids = .{ .imdb = 944947, .tvdb = 121361 } };
    const b = Identity{ .kind = .show, .ids = .{ .imdb = 944947, .tvdb = 999 } };
    try testing.expectEqual(Match.different, compareTitle(a, b));
}

test "compareTitle: TMDB movie and TV ids live in different namespaces" {
    // Regression: TMDB movie 1399 and TMDB TV 1399 are unrelated titles. An
    // integer-only comparison retargeted one onto the other.
    const movie = Identity{ .kind = .movie, .ids = .{ .tmdb = 1399 } };
    const show = Identity{ .kind = .show, .ids = .{ .tmdb = 1399 } };
    try testing.expectEqual(Match.different, compareTitle(movie, show));
    try testing.expectEqual(Match.different, compare(movie, show, &.{}));
}

test "compare: season numbering vs anime absolute numbering" {
    const lengths = [_]u16{ 25, 12, 22 }; // three seasons
    const s2e1 = Identity{ .kind = .episode, .ids = .{ .tvdb = 267440 }, .numbering = .{ .season = 2, .episode = 1 } };
    const abs26 = Identity{ .kind = .episode, .ids = .{ .tvdb = 267440 }, .numbering = .{ .absolute = 26 } };
    const abs27 = Identity{ .kind = .episode, .ids = .{ .tvdb = 267440 }, .numbering = .{ .absolute = 27 } };
    try testing.expectEqual(Match.same, compare(s2e1, abs26, &lengths));
    try testing.expectEqual(Match.same, compare(abs26, s2e1, &lengths));
    try testing.expectEqual(Match.different, compare(s2e1, abs27, &lengths));
    // Without season lengths, never guess.
    try testing.expectEqual(Match.unknown, compare(s2e1, abs26, &.{}));
    // Beyond the known seasons is unknown too.
    const s9e1 = Identity{ .kind = .episode, .ids = .{ .tvdb = 267440 }, .numbering = .{ .season = 9, .episode = 1 } };
    try testing.expectEqual(Match.unknown, compare(s9e1, abs26, &lengths));
}

test "compare: episode numbering decides after the title matches" {
    const show = Identity{ .kind = .show, .ids = .{ .imdb = 944947 } };
    const e1 = Identity{ .kind = .episode, .ids = .{ .imdb = 944947 }, .numbering = .{ .season = 1, .episode = 1 } };
    const e2 = Identity{ .kind = .episode, .ids = .{ .tmdb = 1399, .imdb = 944947 }, .numbering = .{ .season = 1, .episode = 2 } };
    try testing.expectEqual(Match.different, compare(show, e1, &.{}));
    try testing.expectEqual(Match.different, compare(e1, e2, &.{}));
    try testing.expectEqual(Match.same, compare(e1, e1, &.{}));
    // Both numberings present and contradicting is different.
    const bad = Identity{ .kind = .episode, .ids = .{ .imdb = 944947 }, .numbering = .{ .season = 1, .episode = 1, .absolute = 5 } };
    const good = Identity{ .kind = .episode, .ids = .{ .imdb = 944947 }, .numbering = .{ .season = 1, .episode = 1, .absolute = 1 } };
    try testing.expectEqual(Match.different, compare(bad, good, &.{}));
}

test "toSeason / toAbsolute round-trip and bounds" {
    const lengths = [_]u16{ 12, 13 };
    try testing.expectEqual(SeasonEpisode{ .season = 1, .episode = 12 }, toSeason(&lengths, 12).?);
    try testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 1 }, toSeason(&lengths, 13).?);
    try testing.expect(toSeason(&lengths, 26) == null);
    try testing.expect(toSeason(&lengths, 0) == null);
    try testing.expectEqual(@as(u16, 25), toAbsolute(&lengths, 2, 13).?);
    try testing.expect(toAbsolute(&lengths, 2, 14) == null);
    try testing.expect(toAbsolute(&lengths, 0, 1) == null);
}

test "key: strongest id first, numbering last, local fallback" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("series:imdb:tt0944947:s1e2", key(.{ .kind = .episode, .ids = .{ .tmdb = 1399, .imdb = 944947 }, .numbering = .{ .season = 1, .episode = 2 } }, &buf));
    try testing.expectEqualStrings("film:tmdb:550", key(.{ .kind = .movie, .ids = .{ .tmdb = 550 } }, &buf));
    try testing.expectEqualStrings("series:anilist:21:a1000", key(.{ .kind = .episode, .ids = .{ .anilist = 21 }, .numbering = .{ .absolute = 1000 } }, &buf));
    try testing.expectEqualStrings("other:local:ab", key(.{ .kind = .video, .local = 0xab }, &buf));
}

test "fromCatalog: TMDB row with IMDb text, non-TMDB numeric ids ignored" {
    const row = fromCatalog("tv", "tmdb", 1399, "tt0944947");
    try testing.expectEqual(Kind.show, row.kind);
    try testing.expectEqual(@as(u32, 1399), row.ids.tmdb);
    try testing.expectEqual(@as(u32, 944947), row.ids.imdb);
    const music = fromCatalog("", "music", 0, "");
    try testing.expectEqual(Kind.audio, music.kind);
    try testing.expect(!music.ids.any());
}

test "actions: explicit Play here / Play on Opal / Queue when targets coexist" {
    var out: [MAX_ACTIONS]Action = undefined;
    const all = actions(.play_on_opal, .{ .here = .direct, .opal = true, .queue = true }, &out);
    try testing.expectEqualSlices(Action, &.{ .play_here, .play_on_opal, .queue }, all);
    try testing.expectEqualStrings("Play here", all[0].label());
    try testing.expectEqualStrings("Play on Opal", all[1].label());
    try testing.expectEqualStrings("Queue", all[2].label());
    // A browser that cannot decode it gets no "Play here" at all.
    try testing.expectEqualSlices(Action, &.{.play_on_opal}, actions(.play_on_opal, .{ .here = .unsupported, .opal = true }, &out));
    // Headless: only the browser target.
    try testing.expectEqualSlices(Action, &.{.play_here}, actions(.play_on_opal, .{ .here = .transcode }, &out));
    // Reader and catalog verbs stay themselves.
    try testing.expectEqualSlices(Action, &.{.read}, actions(primaryFor("comics"), .{ .opal = true }, &out));
    try testing.expectEqualSlices(Action, &.{ .details, .queue }, actions(primaryFor("tmdb"), .{ .queue = true }, &out));
}

test "primaryFor: one verb table for native and web" {
    try testing.expectEqual(Action.read, primaryFor("novels"));
    try testing.expectEqual(Action.details, primaryFor("vndb"));
    try testing.expectEqual(Action.open_audio, primaryFor("audiobooks"));
    try testing.expectEqual(Action.open, primaryFor("anime"));
    try testing.expectEqual(Action.play_on_opal, primaryFor("torrent"));
    try testing.expectEqual(Action.play_on_opal, primaryFor("youtube"));
}

test "hereFor: follows the browser playability rules" {
    try testing.expectEqual(Here.direct, hereFor("a.mp4"));
    try testing.expectEqual(Here.transcode, hereFor("a.mkv"));
    try testing.expectEqual(Here.hls, hereFor("x.m3u8"));
    try testing.expectEqual(Here.unsupported, hereFor("disc.iso"));
}

test "progressFrom: resume and watched share the server sync thresholds" {
    const mid = progressFrom(600, 3600, false);
    try testing.expectEqual(@as(f64, 600), mid.resume_at);
    try testing.expect(!mid.watched);
    const done = progressFrom(3500, 3600, false);
    try testing.expect(done.watched);
    try testing.expectEqual(@as(f64, 0), done.resume_at);
    const marked = progressFrom(10, 3600, true);
    try testing.expect(marked.watched);
    try testing.expectEqual(@as(f64, 0), marked.resume_at);
    const junk = progressFrom(std.math.nan(f64), 0, false);
    try testing.expectEqual(@as(f64, 0), junk.resume_at);
    try testing.expectEqual(@as(f64, 0), junk.duration);
}

test "writeJson: canonical wire shape" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJson(&w, .{
        .identity = .{ .kind = .episode, .ids = .{ .tmdb = 1399, .imdb = 944947 }, .numbering = .{ .season = 1, .episode = 1 } },
        .targets = .{ .opal = true, .queue = true },
        .progress = progressFrom(120, 3600, false),
    });
    try testing.expectEqualStrings(
        "{\"key\":\"series:imdb:tt0944947:s1e1\",\"kind\":\"episode\",\"ids\":{\"imdb\":\"tt0944947\",\"tmdb\":1399}," ++
            "\"season\":1,\"episode\":1,\"absolute\":null,\"resume\":120,\"duration\":3600,\"watched\":false," ++
            "\"targets\":{\"here\":\"none\",\"opal\":true,\"queue\":true,\"download\":false}," ++
            "\"actions\":[{\"id\":\"play_on_opal\",\"label\":\"Play on Opal\"},{\"id\":\"queue\",\"label\":\"Queue\"}]}",
        buf[0..w.end],
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf[0..w.end], .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("actions").?.array.items.len == 2);
}

test "Selection: a late result for the previous title is rejected" {
    var selection = Selection{};
    const a = selection.select("series:tmdb:1399");
    try testing.expect(selection.isCurrent(a));
    const b = selection.select("film:tmdb:550");
    // A's fetch finishes after B was selected: it must not land on B.
    try testing.expect(!selection.isCurrent(a));
    try testing.expect(!selection.isSameTitle(a));
    try testing.expect(selection.isCurrent(b));
    // Re-selecting A is a new selection event: strict tokens from the first
    // visit are stale, but an idempotent title-level result is still valid.
    _ = selection.select("series:tmdb:1399");
    try testing.expect(!selection.isCurrent(a));
    try testing.expect(selection.isSameTitle(a));
    selection.clear();
    try testing.expect(!selection.isSameTitle(a));
}

test "titleResult: a late lookup never lands on the next title, and the next title is not stranded" {
    // Regression: native TV details resolved a keyless show's IMDb id on a
    // single-flight worker. Opening show B while A's lookup ran left B
    // "loading" forever (its lookup was never started), and only an integer
    // id check stood between A's answer and B's page.
    var selection = Selection{};
    const a = selection.select("series:tmdb:1399");
    try std.testing.expectEqual(Verdict.apply, titleResult(selection, a, true));
    _ = selection.select("series:tmdb:94997");
    try std.testing.expectEqual(Verdict.discard_and_refetch, titleResult(selection, a, true));
    try std.testing.expectEqual(Verdict.discard, titleResult(selection, a, false));
    selection.clear();
    try std.testing.expectEqual(Verdict.discard, titleResult(selection, a, false));
}
