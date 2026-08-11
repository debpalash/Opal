//! Music discovery — ALL pure logic (no I/O, no dvui, no globals).
//!
//! Pipeline modelled on DiscoveryLastFM's *logic*, retargeted at ListenBrainz +
//! MusicBrainz (no API key, CC0 data — Opal never bakes in credentials):
//!
//!   seed artists (what Opal already saw you play)
//!     → MusicBrainz artist search        → artist MBID
//!     → ListenBrainz labs similar-artists → ranked similar artists
//!     → MusicBrainz release-group browse  → STUDIO albums only
//!     → dedupe + order                    → browsable rows
//!
//! Verified endpoint shapes (hit live 2026-07-30):
//!   GET https://musicbrainz.org/ws/2/artist?query=…&fmt=json&limit=N
//!       → {"artists":[{"id":"<mbid>","score":100,"name":"Radiohead",…}]}
//!   GET https://labs.api.listenbrainz.org/similar-artists/json
//!         ?artist_mbids=<mbid>&algorithm=<algo>          (algorithm REQUIRED —
//!       → [{"artist_mbid":"…","name":"Nirvana","score":11156,…}]   omitting it 400s)
//!   GET https://musicbrainz.org/ws/2/release-group?artist=<mbid>&type=album&fmt=json&limit=N
//!       → {"release-groups":[{"id":"…","title":"OK Computer",
//!          "primary-type":"Album","secondary-types":[],"first-release-date":"1997-05-21"}]}
//!
//! A studio album is `primary-type == "Album"` with an EMPTY `secondary-types`
//! array — that is exactly what drops compilations, live records and singles
//! (Nirvana's browse is 70% compilations without it).

const std = @import("std");

// ══════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════

/// MusicBrainz *requires* a descriptive, contactable User-Agent; a generic
/// browser UA is explicitly against their rules and gets you blocked.
pub const USER_AGENT = "Opal/0.6.5 ( https://github.com/debpalash/Opal )";

/// MusicBrainz enforces ~1 request/second per client. ListenBrainz labs is more
/// forgiving but we stay polite.
pub const MB_RATE_PER_SEC: f64 = 1.0;
pub const LB_RATE_PER_SEC: f64 = 2.0;

/// The ListenBrainz labs similar-artists dataset. The `algorithm` parameter is
/// mandatory (a request without it returns HTTP 400 with a validation error).
pub const LB_ALGORITHM = "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30";

pub const MAX_SEEDS: usize = 4;
pub const MAX_SIMILAR: usize = 24;
pub const MAX_ALBUMS: usize = 60;
pub const ALBUMS_PER_ARTIST: usize = 3;

// ══════════════════════════════════════════════════════════
// Records (fixed-size buffers, Opal's state convention)
// ══════════════════════════════════════════════════════════

pub const Seed = struct {
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,

    pub fn slice(self: *const Seed) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const SimilarArtist = struct {
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    mbid: [36]u8 = std.mem.zeroes([36]u8),
    mbid_len: usize = 0,
    score: u32 = 0,

    pub fn nameSlice(self: *const SimilarArtist) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn mbidSlice(self: *const SimilarArtist) []const u8 {
        return self.mbid[0..self.mbid_len];
    }
};

pub const Album = struct {
    artist: [128]u8 = std.mem.zeroes([128]u8),
    artist_len: usize = 0,
    title: [160]u8 = std.mem.zeroes([160]u8),
    title_len: usize = 0,
    mbid: [36]u8 = std.mem.zeroes([36]u8),
    mbid_len: usize = 0,
    year: [4]u8 = std.mem.zeroes([4]u8),
    year_len: usize = 0,
    /// Verbatim "because" receipt, e.g. "Similar to Radiohead".
    reason: [96]u8 = std.mem.zeroes([96]u8),
    reason_len: usize = 0,
    score: u32 = 0,

    pub fn artistSlice(self: *const Album) []const u8 {
        return self.artist[0..self.artist_len];
    }
    pub fn titleSlice(self: *const Album) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn yearSlice(self: *const Album) []const u8 {
        return self.year[0..self.year_len];
    }
    pub fn reasonSlice(self: *const Album) []const u8 {
        return self.reason[0..self.reason_len];
    }
};

fn setField(buf: []u8, len: *usize, val: []const u8) void {
    const n = @min(val.len, buf.len);
    @memcpy(buf[0..n], val[0..n]);
    len.* = n;
}

// ══════════════════════════════════════════════════════════
// Name normalisation (dedupe key)
// ══════════════════════════════════════════════════════════

/// Fold an artist/album name to a comparison key: ASCII-lowercased, a leading
/// "the " dropped, punctuation removed, runs of whitespace collapsed to one
/// space, trimmed. Non-ASCII bytes are kept verbatim (so "Björk" still matches
/// itself) — this is a dedupe key, not a transliteration.
pub fn normalizeName(in: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    for (in) |c0| {
        if (n >= out.len) break;
        const c = if (c0 >= 'A' and c0 <= 'Z') c0 + 32 else c0;
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '_' or c == '-') {
            if (n > 0) pending_space = true;
            continue;
        }
        // Drop ASCII punctuation entirely (apostrophes, dots, brackets, …).
        if (c < 0x80 and !((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'))) continue;
        if (pending_space) {
            out[n] = ' ';
            n += 1;
            pending_space = false;
            if (n >= out.len) break;
        }
        out[n] = c;
        n += 1;
    }
    var s = out[0..n];
    if (s.len > 4 and std.mem.eql(u8, s[0..4], "the ")) s = s[4..];
    return s;
}

fn sameName(a: []const u8, b: []const u8) bool {
    var ab: [160]u8 = undefined;
    var bb: [160]u8 = undefined;
    return std.mem.eql(u8, normalizeName(a, &ab), normalizeName(b, &bb));
}

// ══════════════════════════════════════════════════════════
// Seeds
// ══════════════════════════════════════════════════════════

/// Build the seed list from artist names Opal already observed (most recent
/// first). Dedupes on the normalised name, drops empties, caps at `out.len`.
/// An empty input yields ZERO seeds — discovery must degrade to nothing rather
/// than invent a taste profile.
pub fn collectSeeds(names: []const []const u8, out: []Seed) usize {
    var n: usize = 0;
    for (names) |raw| {
        if (n >= out.len) break;
        const name = std.mem.trim(u8, raw, " \t\r\n");
        if (name.len == 0 or name.len > 128) continue;
        var dup = false;
        for (out[0..n]) |*prev| {
            if (sameName(prev.slice(), name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        setField(&out[n].name, &out[n].name_len, name);
        n += 1;
    }
    return n;
}

// ══════════════════════════════════════════════════════════
// URL builders (every parameter percent-encoded)
// ══════════════════════════════════════════════════════════

/// Percent-encode to the RFC 3986 unreserved set. Covers, at minimum, space,
/// `&`, `=`, `#`, `?`, `%` and `+` as Opal's URL rule requires.
pub fn percentEncode(in: []const u8, out: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (in) |c| {
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~')
        {
            if (n + 1 > out.len) break;
            out[n] = c;
            n += 1;
        } else {
            if (n + 3 > out.len) break;
            out[n] = '%';
            out[n + 1] = hex[c >> 4];
            out[n + 2] = hex[c & 0xF];
            n += 3;
        }
    }
    return out[0..n];
}

/// A MusicBrainz identifier: 8-4-4-4-12 lowercase hex with dashes.
pub fn isValidMbid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
            continue;
        }
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// `GET /ws/2/artist?query=artist:"<name>"&fmt=json&limit=N` — resolve a plain
/// artist name to its MBID.
pub fn buildArtistSearchUrl(out: []u8, name: []const u8, limit: u8) ?[]const u8 {
    if (name.len == 0 or name.len > 128) return null;
    var q_buf: [160]u8 = undefined;
    const q = std.fmt.bufPrint(&q_buf, "artist:\"{s}\"", .{name}) catch return null;
    var enc_buf: [512]u8 = undefined;
    const enc = percentEncode(q, &enc_buf);
    if (enc.len == 0) return null;
    return std.fmt.bufPrint(
        out,
        "https://musicbrainz.org/ws/2/artist?query={s}&fmt=json&limit={d}",
        .{ enc, limit },
    ) catch null;
}

/// ListenBrainz labs similar-artists. `algorithm` is mandatory upstream.
pub fn buildSimilarArtistsUrl(out: []u8, mbid: []const u8) ?[]const u8 {
    if (!isValidMbid(mbid)) return null;
    var enc_buf: [128]u8 = undefined;
    const enc = percentEncode(mbid, &enc_buf);
    return std.fmt.bufPrint(
        out,
        "https://labs.api.listenbrainz.org/similar-artists/json?artist_mbids={s}&algorithm={s}",
        .{ enc, LB_ALGORITHM },
    ) catch null;
}

/// `GET /ws/2/release-group?artist=<mbid>&type=album&fmt=json&limit=N`.
/// `type=album` is only a coarse primary-type filter; the studio-album cut is
/// made by `isStudioAlbum` on the parsed rows.
pub fn buildReleaseGroupUrl(out: []u8, artist_mbid: []const u8, limit: u16) ?[]const u8 {
    if (!isValidMbid(artist_mbid)) return null;
    var enc_buf: [128]u8 = undefined;
    const enc = percentEncode(artist_mbid, &enc_buf);
    return std.fmt.bufPrint(
        out,
        "https://musicbrainz.org/ws/2/release-group?artist={s}&type=album&fmt=json&limit={d}",
        .{ enc, limit },
    ) catch null;
}

// ══════════════════════════════════════════════════════════
// Cache keys + TTL
// ══════════════════════════════════════════════════════════

pub const CacheKind = enum { artist_mbid, similar, albums };

/// Seconds an entry of this kind stays usable. Artist→MBID is essentially
/// immutable, similarity is recomputed upstream on a slow cadence, and a
/// discography changes only when something is released.
pub fn ttlFor(kind: CacheKind) i64 {
    return switch (kind) {
        .artist_mbid => 30 * 24 * 60 * 60,
        .similar => 7 * 24 * 60 * 60,
        .albums => 14 * 24 * 60 * 60,
    };
}

/// Stable cache key for (kind, id). Normalised so "Daft Punk" and "daft  punk"
/// share one entry, and namespaced so it can't collide with another subsystem's
/// cache. Returns null for an empty id.
pub fn cacheKey(kind: CacheKind, id: []const u8, out: []u8) ?[]const u8 {
    var norm_buf: [160]u8 = undefined;
    const norm = normalizeName(id, &norm_buf);
    if (norm.len == 0) return null;
    return std.fmt.bufPrint(out, "musicdisc:{s}:{s}", .{ @tagName(kind), norm }) catch null;
}

/// True when an entry written at `created_ts` is past its TTL at `now`.
/// A non-positive TTL means "never cache".
pub fn cacheExpired(created_ts: i64, ttl_s: i64, now: i64) bool {
    if (ttl_s <= 0) return true;
    if (now < created_ts) return false; // clock went backwards — keep the entry
    return (now - created_ts) >= ttl_s;
}

/// Exponential backoff for a 429 / transient failure: 500ms, 1s, 2s, 4s, 8s cap.
pub fn backoffMs(attempt: u32) u32 {
    if (attempt >= 4) return 8000;
    return @as(u32, 500) << @intCast(attempt);
}

// ══════════════════════════════════════════════════════════
// JSON extraction
// ══════════════════════════════════════════════════════════

/// The `[ … ]` slice for `"key":[`, brackets included. Empty when absent.
pub fn arrayScope(json: []const u8, key: []const u8) []const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":[", .{key}) catch return "";
    const at = std.mem.indexOf(u8, json, needle) orelse return "";
    const open = at + needle.len - 1;
    return sliceBracket(json, open, '[', ']');
}

fn sliceBracket(json: []const u8, open: usize, o: u8, c: u8) []const u8 {
    var depth: i32 = 0;
    var i = open;
    var in_str = false;
    var esc = false;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (ch == '\\') {
                esc = true;
            } else if (ch == '"') {
                in_str = false;
            }
            continue;
        }
        if (ch == '"') {
            in_str = true;
        } else if (ch == o) {
            depth += 1;
        } else if (ch == c) {
            depth -= 1;
            if (depth == 0) return json[open .. i + 1];
        }
    }
    return "";
}

/// Iterate the top-level `{…}` objects of a JSON array. String- and
/// nesting-aware, so a nested object or a `}` inside a string never splits a
/// row (MusicBrainz emits keys in arbitrary order, so a marker-delimited
/// iterator like the Subsonic one is not safe here).
pub const ObjIter = struct {
    json: []const u8,
    pos: usize = 0,

    pub fn init(json: []const u8) ObjIter {
        return .{ .json = json, .pos = 0 };
    }

    pub fn next(self: *ObjIter) ?[]const u8 {
        var i = self.pos;
        var in_str = false;
        var esc = false;
        while (i < self.json.len) : (i += 1) {
            const ch = self.json[i];
            if (in_str) {
                if (esc) {
                    esc = false;
                } else if (ch == '\\') {
                    esc = true;
                } else if (ch == '"') in_str = false;
                continue;
            }
            if (ch == '"') {
                in_str = true;
            } else if (ch == '{') {
                const obj = sliceBracket(self.json, i, '{', '}');
                if (obj.len == 0) return null;
                self.pos = i + obj.len;
                return obj;
            }
        }
        return null;
    }
};

/// Read the string value of `"key"` from `scope` into `dst`; bytes written, 0
/// when absent or non-string (e.g. `"primary-type":null`). Unescapes `\"`/`\\`.
pub fn jsonStrField(scope: []const u8, key: []const u8, dst: []u8) usize {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return 0;
    const at = std.mem.indexOf(u8, scope, needle) orelse return 0;
    var i = at + needle.len;
    while (i < scope.len and (scope[i] == ' ' or scope[i] == '\t')) i += 1;
    if (i >= scope.len or scope[i] != '"') return 0;
    i += 1;
    var n: usize = 0;
    while (i < scope.len and n < dst.len) : (i += 1) {
        const c = scope[i];
        if (c == '\\' and i + 1 < scope.len) {
            dst[n] = scope[i + 1];
            n += 1;
            i += 1;
            continue;
        }
        if (c == '"') break;
        dst[n] = c;
        n += 1;
    }
    return n;
}

/// Read a non-negative integer value of `"key"`; null when absent/negative.
pub fn jsonU32Field(scope: []const u8, key: []const u8) ?u32 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, scope, needle) orelse return null;
    var i = at + needle.len;
    while (i < scope.len and (scope[i] == ' ' or scope[i] == '\t')) i += 1;
    var n: u32 = 0;
    var any = false;
    while (i < scope.len and scope[i] >= '0' and scope[i] <= '9') : (i += 1) {
        n = n *| 10 +| (scope[i] - '0');
        any = true;
    }
    return if (any) n else null;
}

/// The 4-digit year of a MusicBrainz date (`YYYY`, `YYYY-MM`, `YYYY-MM-DD`).
/// Empty for a missing or malformed date.
pub fn firstYear(date: []const u8) []const u8 {
    if (date.len < 4) return "";
    for (date[0..4]) |c| {
        if (c < '0' or c > '9') return "";
    }
    return date[0..4];
}

// ══════════════════════════════════════════════════════════
// Release-type filtering
// ══════════════════════════════════════════════════════════

/// A STUDIO album: primary type "Album" with no secondary types. Anything
/// carrying a secondary type (Compilation, Live, Remix, Soundtrack, DJ-mix, …)
/// and every non-Album primary type (Single, EP, Broadcast, Other) is rejected.
pub fn isStudioAlbum(primary_type: []const u8, secondary_types_scope: []const u8) bool {
    if (!std.mem.eql(u8, primary_type, "Album")) return false;
    // `secondary_types_scope` is the raw `[...]` slice; empty array (possibly
    // with whitespace) is the only accepted form.
    const inner = std.mem.trim(u8, secondary_types_scope, "[] \t\r\n");
    return inner.len == 0;
}

// ══════════════════════════════════════════════════════════
// Parsers
// ══════════════════════════════════════════════════════════

/// Highest-scoring MBID from a MusicBrainz `/ws/2/artist?query=…` response.
/// Prefers an exact (normalised) name match over raw score, so searching
/// "Nirvana" can't latch onto a higher-scoring tribute act listed first.
pub fn parseTopArtistMbid(json: []const u8, want_name: []const u8, out: []u8) usize {
    const scope = arrayScope(json, "artists");
    if (scope.len == 0) return 0;
    var it = ObjIter.init(scope);

    var best_id: [36]u8 = undefined;
    var best_len: usize = 0;
    var best_score: u32 = 0;
    var best_exact = false;

    while (it.next()) |obj| {
        var id_buf: [64]u8 = undefined;
        const idn = jsonStrField(obj, "id", &id_buf);
        if (idn != 36 or !isValidMbid(id_buf[0..idn])) continue;
        var name_buf: [128]u8 = undefined;
        const nn = jsonStrField(obj, "name", &name_buf);
        const score = jsonU32Field(obj, "score") orelse 0;
        const exact = nn > 0 and sameName(name_buf[0..nn], want_name);
        const better = if (exact != best_exact) exact else score > best_score;
        if (best_len != 0 and !better) continue;
        @memcpy(best_id[0..36], id_buf[0..36]);
        best_len = 36;
        best_score = score;
        best_exact = exact;
    }
    if (best_len == 0) return 0;
    const n = @min(best_len, out.len);
    @memcpy(out[0..n], best_id[0..n]);
    return n;
}

/// Parse the ListenBrainz labs similar-artists array (a bare top-level array).
/// Rows without a valid MBID or a name are skipped. Returns rows written.
pub fn parseSimilarArtists(json: []const u8, out: []SimilarArtist) usize {
    var it = ObjIter.init(json);
    var n: usize = 0;
    while (it.next()) |obj| {
        if (n >= out.len) break;
        var id_buf: [64]u8 = undefined;
        const idn = jsonStrField(obj, "artist_mbid", &id_buf);
        if (idn != 36 or !isValidMbid(id_buf[0..idn])) continue;
        var name_buf: [128]u8 = undefined;
        const nn = jsonStrField(obj, "name", &name_buf);
        if (nn == 0) continue;
        out[n] = .{};
        setField(&out[n].name, &out[n].name_len, name_buf[0..nn]);
        setField(&out[n].mbid, &out[n].mbid_len, id_buf[0..idn]);
        out[n].score = jsonU32Field(obj, "score") orelse 0;
        n += 1;
    }
    return n;
}

/// Sort similar artists by score descending and drop duplicates (same
/// normalised name) plus anything matching `exclude` (the seed itself).
/// Returns the surviving count; `list` is compacted in place.
pub fn rankSimilar(list: []SimilarArtist, exclude: []const u8) usize {
    std.mem.sort(SimilarArtist, list, {}, struct {
        fn lt(_: void, a: SimilarArtist, b: SimilarArtist) bool {
            return a.score > b.score;
        }
    }.lt);

    var n: usize = 0;
    for (0..list.len) |i| {
        const cand = list[i];
        if (cand.name_len == 0) continue;
        if (exclude.len > 0 and sameName(cand.nameSlice(), exclude)) continue;
        var dup = false;
        for (list[0..n]) |*kept| {
            if (sameName(kept.nameSlice(), cand.nameSlice())) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        list[n] = cand;
        n += 1;
    }
    return n;
}

/// Parse a MusicBrainz release-group browse response, keeping only studio
/// albums. `artist` and `reason` are stamped onto every row so a card can show
/// its provenance verbatim. Returns rows written, newest first.
pub fn parseStudioAlbums(
    json: []const u8,
    artist: []const u8,
    reason: []const u8,
    score: u32,
    out: []Album,
) usize {
    const scope = arrayScope(json, "release-groups");
    if (scope.len == 0) return 0;
    var it = ObjIter.init(scope);
    var n: usize = 0;
    while (it.next()) |obj| {
        if (n >= out.len) break;
        var ptype_buf: [32]u8 = undefined;
        const pn = jsonStrField(obj, "primary-type", &ptype_buf);
        const sec = arrayScope(obj, "secondary-types");
        if (!isStudioAlbum(ptype_buf[0..pn], sec)) continue;

        var id_buf: [64]u8 = undefined;
        const idn = jsonStrField(obj, "id", &id_buf);
        if (idn != 36 or !isValidMbid(id_buf[0..idn])) continue;
        var title_buf: [160]u8 = undefined;
        const tn = jsonStrField(obj, "title", &title_buf);
        if (tn == 0) continue;
        var date_buf: [16]u8 = undefined;
        const dn = jsonStrField(obj, "first-release-date", &date_buf);

        out[n] = .{};
        setField(&out[n].artist, &out[n].artist_len, artist);
        setField(&out[n].title, &out[n].title_len, title_buf[0..tn]);
        setField(&out[n].mbid, &out[n].mbid_len, id_buf[0..idn]);
        setField(&out[n].year, &out[n].year_len, firstYear(date_buf[0..dn]));
        setField(&out[n].reason, &out[n].reason_len, reason);
        out[n].score = score;
        n += 1;
    }
    sortAlbums(out[0..n]);
    return n;
}

/// Order albums for display: newest first, then by seed score, then by title —
/// a total order, so the rail never reshuffles between frames.
pub fn sortAlbums(list: []Album) void {
    std.mem.sort(Album, list, {}, struct {
        fn lt(_: void, a: Album, b: Album) bool {
            const ay = a.yearSlice();
            const by = b.yearSlice();
            if (!std.mem.eql(u8, ay, by)) {
                if (ay.len == 0) return false; // undated sinks
                if (by.len == 0) return true;
                return std.mem.order(u8, ay, by) == .gt;
            }
            if (a.score != b.score) return a.score > b.score;
            return std.mem.order(u8, a.titleSlice(), b.titleSlice()) == .lt;
        }
    }.lt);
}

/// Drop albums that repeat a (artist, title) pair after normalisation — the
/// same record reappears across re-issues and across two different seeds.
/// Compacts in place, keeping the first (best-ordered) occurrence.
pub fn dedupeAlbums(list: []Album) usize {
    var n: usize = 0;
    for (0..list.len) |i| {
        const cand = list[i];
        if (cand.title_len == 0) continue;
        var dup = false;
        for (list[0..n]) |*kept| {
            if (sameName(kept.titleSlice(), cand.titleSlice()) and
                sameName(kept.artistSlice(), cand.artistSlice()))
            {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        list[n] = cand;
        n += 1;
    }
    return n;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "normalizeName folds case, punctuation, spacing and a leading 'The'" {
    var b: [160]u8 = undefined;
    try std.testing.expectEqualStrings("beatles", normalizeName("The Beatles", &b));
    try std.testing.expectEqualStrings("daft punk", normalizeName("  Daft   Punk  ", &b));
    try std.testing.expectEqualStrings("sigur ros", normalizeName("Sigur-Ros!", &b));
    try std.testing.expectEqualStrings("acdc", normalizeName("AC/DC", &b));
    // "The" only drops as a leading WORD, never mid-name or as the whole name.
    try std.testing.expectEqualStrings("them", normalizeName("Them", &b));
    try std.testing.expectEqualStrings("the", normalizeName("The", &b));
}

test "collectSeeds dedupes, trims, and degrades to zero on empty input" {
    var seeds: [MAX_SEEDS]Seed = undefined;
    const names = [_][]const u8{ "Radiohead", " radiohead ", "The Beatles", "Beatles", "Portishead" };
    const n = collectSeeds(&names, &seeds);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("Radiohead", seeds[0].slice());
    try std.testing.expectEqualStrings("The Beatles", seeds[1].slice());
    try std.testing.expectEqualStrings("Portishead", seeds[2].slice());

    const empty = [_][]const u8{ "", "   " };
    try std.testing.expectEqual(@as(usize, 0), collectSeeds(&empty, &seeds));
    try std.testing.expectEqual(@as(usize, 0), collectSeeds(&.{}, &seeds));
}

test "collectSeeds honours the output cap" {
    var seeds: [2]Seed = undefined;
    const names = [_][]const u8{ "A", "B", "C", "D" };
    try std.testing.expectEqual(@as(usize, 2), collectSeeds(&names, &seeds));
}

test "isValidMbid" {
    try std.testing.expect(isValidMbid("a74b1b7f-71a5-4011-9441-d0b5e4122711"));
    try std.testing.expect(!isValidMbid("a74b1b7f71a540119441d0b5e4122711"));
    try std.testing.expect(!isValidMbid("a74b1b7f-71a5-4011-9441-d0b5e412271z"));
    try std.testing.expect(!isValidMbid(""));
}

test "URL builders percent-encode and match the verified endpoint shapes" {
    var b: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://musicbrainz.org/ws/2/artist?query=artist%3A%22Daft%20Punk%22&fmt=json&limit=5",
        buildArtistSearchUrl(&b, "Daft Punk", 5).?,
    );
    // Injection attempt: the & / = / # can never escape into the query string.
    const evil = buildArtistSearchUrl(&b, "a&b=c#d+e", 5).?;
    try std.testing.expect(std.mem.indexOf(u8, evil, "a&b") == null);
    try std.testing.expect(std.mem.indexOf(u8, evil, "%26") != null);
    try std.testing.expect(std.mem.indexOf(u8, evil, "%2B") != null);

    try std.testing.expectEqualStrings(
        "https://labs.api.listenbrainz.org/similar-artists/json?artist_mbids=" ++
            "a74b1b7f-71a5-4011-9441-d0b5e4122711&algorithm=" ++ LB_ALGORITHM,
        buildSimilarArtistsUrl(&b, "a74b1b7f-71a5-4011-9441-d0b5e4122711").?,
    );
    // The algorithm parameter is mandatory upstream (a bare call 400s) — assert
    // we never build a URL without it.
    try std.testing.expect(std.mem.indexOf(u8, buildSimilarArtistsUrl(&b, "a74b1b7f-71a5-4011-9441-d0b5e4122711").?, "&algorithm=") != null);
    try std.testing.expect(buildSimilarArtistsUrl(&b, "not-an-mbid") == null);

    try std.testing.expectEqualStrings(
        "https://musicbrainz.org/ws/2/release-group?artist=5b11f4ce-a62d-471e-81fc-a69a8278c7da&type=album&fmt=json&limit=100",
        buildReleaseGroupUrl(&b, "5b11f4ce-a62d-471e-81fc-a69a8278c7da", 100).?,
    );
    try std.testing.expect(buildReleaseGroupUrl(&b, "", 100) == null);
}

test "cache key is stable, normalised and namespaced; TTLs are ordered" {
    var a: [256]u8 = undefined;
    var c: [256]u8 = undefined;
    try std.testing.expectEqualStrings("musicdisc:similar:daft punk", cacheKey(.similar, "Daft  Punk", &a).?);
    try std.testing.expectEqualStrings(cacheKey(.similar, "DAFT PUNK", &a).?, cacheKey(.similar, "daft punk", &c).?);
    // Kind namespacing keeps two lookups for the same artist apart.
    try std.testing.expect(!std.mem.eql(u8, cacheKey(.similar, "x y", &a).?, cacheKey(.albums, "x y", &c).?));
    try std.testing.expect(cacheKey(.albums, "", &a) == null);

    try std.testing.expect(ttlFor(.artist_mbid) > ttlFor(.albums));
    try std.testing.expect(ttlFor(.albums) > ttlFor(.similar));
}

test "cacheExpired honours the TTL boundary and a backwards clock" {
    const t: i64 = 1_000_000;
    try std.testing.expect(!cacheExpired(t, 100, t));
    try std.testing.expect(!cacheExpired(t, 100, t + 99));
    try std.testing.expect(cacheExpired(t, 100, t + 100)); // boundary is expired
    try std.testing.expect(cacheExpired(t, 100, t + 5000));
    try std.testing.expect(cacheExpired(t, 0, t + 1)); // ttl<=0 → never cache
    try std.testing.expect(!cacheExpired(t, 100, t - 5000)); // clock skew → keep
}

test "backoffMs is exponential and capped" {
    try std.testing.expectEqual(@as(u32, 500), backoffMs(0));
    try std.testing.expectEqual(@as(u32, 1000), backoffMs(1));
    try std.testing.expectEqual(@as(u32, 2000), backoffMs(2));
    try std.testing.expectEqual(@as(u32, 4000), backoffMs(3));
    try std.testing.expectEqual(@as(u32, 8000), backoffMs(4));
    try std.testing.expectEqual(@as(u32, 8000), backoffMs(99));
}

test "isStudioAlbum keeps studio albums, drops compilations/live/singles" {
    try std.testing.expect(isStudioAlbum("Album", "[]"));
    try std.testing.expect(isStudioAlbum("Album", "[ ]"));
    try std.testing.expect(!isStudioAlbum("Album", "[\"Compilation\"]"));
    try std.testing.expect(!isStudioAlbum("Album", "[\"Compilation\",\"Live\"]"));
    try std.testing.expect(!isStudioAlbum("Album", "[\"Live\"]"));
    try std.testing.expect(!isStudioAlbum("Single", "[]"));
    try std.testing.expect(!isStudioAlbum("EP", "[]"));
    try std.testing.expect(!isStudioAlbum("", "")); // primary-type: null
}

test "ObjIter splits array rows regardless of key order or nesting" {
    const json =
        \\[{"a":1,"nested":{"b":"}"},"name":"one"},{"name":"two","z":[1,2]}]
    ;
    var it = ObjIter.init(json);
    var nb: [32]u8 = undefined;
    const o0 = it.next().?;
    try std.testing.expectEqualStrings("one", nb[0..jsonStrField(o0, "name", &nb)]);
    const o1 = it.next().?;
    try std.testing.expectEqualStrings("two", nb[0..jsonStrField(o1, "name", &nb)]);
    try std.testing.expect(it.next() == null);
}

test "jsonStrField / jsonU32Field / arrayScope / firstYear" {
    const json =
        \\{"id":"x","score":11156,"secondary-types":[],"secondary-type-ids":["a"],"primary-type":null,"first-release-date":"1997-05-21"}
    ;
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("x", b[0..jsonStrField(json, "id", &b)]);
    try std.testing.expectEqual(@as(usize, 0), jsonStrField(json, "primary-type", &b)); // null is not a string
    try std.testing.expectEqual(@as(u32, 11156), jsonU32Field(json, "score").?);
    try std.testing.expect(jsonU32Field(json, "nope") == null);
    // `secondary-types` must not be confused with `secondary-type-ids`.
    try std.testing.expectEqualStrings("[]", arrayScope(json, "secondary-types"));
    try std.testing.expectEqualStrings("[\"a\"]", arrayScope(json, "secondary-type-ids"));
    try std.testing.expectEqualStrings("1997", firstYear("1997-05-21"));
    try std.testing.expectEqualStrings("1997", firstYear("1997"));
    try std.testing.expectEqualStrings("", firstYear(""));
    try std.testing.expectEqualStrings("", firstYear("199"));
    try std.testing.expectEqualStrings("", firstYear("abcd-01"));
}

test "parseTopArtistMbid prefers an exact name match over a higher score" {
    // Verbatim shape from musicbrainz.org/ws/2/artist?query=artist:radiohead.
    const json =
        \\{"created":"2026-07-29T22:41:48.868Z","count":7,"offset":0,"artists":[
        \\{"id":"11111111-71a5-4011-9441-d0b5e4122711","score":100,"name":"Radiohead Tribute","type":"Group"},
        \\{"id":"a74b1b7f-71a5-4011-9441-d0b5e4122711","score":97,"name":"Radiohead","type":"Group","country":"GB"}]}
    ;
    var out: [36]u8 = undefined;
    const n = parseTopArtistMbid(json, "Radiohead", &out);
    try std.testing.expectEqualStrings("a74b1b7f-71a5-4011-9441-d0b5e4122711", out[0..n]);
    // No exact match → fall back to the top score.
    const n2 = parseTopArtistMbid(json, "Someone Else", &out);
    try std.testing.expectEqualStrings("11111111-71a5-4011-9441-d0b5e4122711", out[0..n2]);
    try std.testing.expectEqual(@as(usize, 0), parseTopArtistMbid("{\"artists\":[]}", "x", &out));
    try std.testing.expectEqual(@as(usize, 0), parseTopArtistMbid("garbage", "x", &out));
}

test "parseSimilarArtists reads the ListenBrainz labs array" {
    // Verbatim shape from labs.api.listenbrainz.org/similar-artists/json.
    const json =
        \\[{"artist_mbid": "5b11f4ce-a62d-471e-81fc-a69a8278c7da", "name": "Nirvana", "comment": "1980s–1990s US grunge band", "type": "Group", "gender": null, "score": 11156, "reference_mbid": "a74b1b7f-71a5-4011-9441-d0b5e4122711"},
        \\{"artist_mbid": "8bfac288-ccc5-448d-9573-c33ea2aa5c30", "name": "Red Hot Chili Peppers", "comment": "", "type": "Group", "gender": null, "score": 10587, "reference_mbid": "a74b1b7f-71a5-4011-9441-d0b5e4122711"},
        \\{"artist_mbid": "bogus", "name": "Skip Me", "score": 99999}]
    ;
    var out: [8]SimilarArtist = undefined;
    const n = parseSimilarArtists(json, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("Nirvana", out[0].nameSlice());
    try std.testing.expectEqualStrings("5b11f4ce-a62d-471e-81fc-a69a8278c7da", out[0].mbidSlice());
    try std.testing.expectEqual(@as(u32, 11156), out[0].score);
    try std.testing.expectEqualStrings("Red Hot Chili Peppers", out[1].nameSlice());
    try std.testing.expectEqual(@as(usize, 0), parseSimilarArtists("[]", &out));
}

fn mkSimilar(name: []const u8, score: u32) SimilarArtist {
    var s = SimilarArtist{ .score = score };
    setField(&s.name, &s.name_len, name);
    setField(&s.mbid, &s.mbid_len, "a74b1b7f-71a5-4011-9441-d0b5e4122711");
    return s;
}

test "rankSimilar orders by score, dedupes, and drops the seed itself" {
    var list = [_]SimilarArtist{
        mkSimilar("Muse", 300),
        mkSimilar("The Beatles", 900),
        mkSimilar("Radiohead", 999), // the seed — must not recommend itself
        mkSimilar("beatles", 500), // duplicate of "The Beatles" after folding
        mkSimilar("Portishead", 700),
    };
    const n = rankSimilar(&list, "radiohead");
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("The Beatles", list[0].nameSlice());
    try std.testing.expectEqualStrings("Portishead", list[1].nameSlice());
    try std.testing.expectEqualStrings("Muse", list[2].nameSlice());
}

test "parseStudioAlbums filters a real Nirvana browse down to the studio records" {
    // Rows lifted verbatim from a live /ws/2/release-group?artist=…&type=album
    // response (key order deliberately varies between rows, as upstream does).
    const json =
        \\{"release-groups":[
        \\{"secondary-type-ids":[],"disambiguation":"","secondary-types":["Compilation"],"id":"11111111-1111-1111-1111-111111111111","first-release-date":"1992-12-15","primary-type":"Album","title":"Incesticide"},
        \\{"secondary-types":[],"first-release-date":"1991-09-24","id":"22222222-2222-2222-2222-222222222222","primary-type":"Album","title":"Nevermind","disambiguation":"","secondary-type-ids":[]},
        \\{"secondary-types":["Compilation","Live"],"first-release-date":"1996-10-01","id":"33333333-3333-3333-3333-333333333333","primary-type":"Album","title":"From the Muddy Banks of the Wishkah"},
        \\{"secondary-types":[],"first-release-date":"1993-09-13","id":"44444444-4444-4444-4444-444444444444","primary-type":"Album","title":"In Utero"},
        \\{"secondary-types":["Live"],"first-release-date":"2009-11-02","id":"55555555-5555-5555-5555-555555555555","primary-type":"Album","title":"Live at Reading"},
        \\{"secondary-types":[],"first-release-date":"1989-06-15","id":"66666666-6666-6666-6666-666666666666","primary-type":"Album","title":"Bleach"},
        \\{"secondary-types":[],"first-release-date":"1992-01-01","id":"77777777-7777-7777-7777-777777777777","primary-type":"Single","title":"Lithium"}],
        \\"release-group-count":384,"release-group-offset":0}
    ;
    var out: [16]Album = undefined;
    const n = parseStudioAlbums(json, "Nirvana", "Similar to Radiohead", 11156, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    // Newest first.
    try std.testing.expectEqualStrings("In Utero", out[0].titleSlice());
    try std.testing.expectEqualStrings("1993", out[0].yearSlice());
    try std.testing.expectEqualStrings("Nevermind", out[1].titleSlice());
    try std.testing.expectEqualStrings("Bleach", out[2].titleSlice());
    try std.testing.expectEqualStrings("Nirvana", out[0].artistSlice());
    try std.testing.expectEqualStrings("Similar to Radiohead", out[0].reasonSlice());
    try std.testing.expectEqual(@as(u32, 11156), out[0].score);
    try std.testing.expectEqual(@as(usize, 0), parseStudioAlbums("{}", "x", "y", 0, &out));
}

test "dedupeAlbums collapses the same record reached via two seeds" {
    var list: [4]Album = .{ .{}, .{}, .{}, .{} };
    const rows = [_]struct { a: []const u8, t: []const u8 }{
        .{ .a = "Nirvana", .t = "Nevermind" },
        .{ .a = "nirvana", .t = "  Nevermind " },
        .{ .a = "Nirvana", .t = "In Utero" },
        .{ .a = "Muse", .t = "Nevermind" }, // same title, different artist — keep
    };
    for (rows, 0..) |r, i| {
        setField(&list[i].artist, &list[i].artist_len, r.a);
        setField(&list[i].title, &list[i].title_len, r.t);
    }
    const n = dedupeAlbums(&list);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("Nevermind", list[0].titleSlice());
    try std.testing.expectEqualStrings("In Utero", list[1].titleSlice());
    try std.testing.expectEqualStrings("Muse", list[2].artistSlice());
}

test "sortAlbums sinks undated records instead of floating them" {
    var list: [3]Album = .{ .{}, .{}, .{} };
    setField(&list[0].title, &list[0].title_len, "no date");
    setField(&list[1].title, &list[1].title_len, "old");
    setField(&list[1].year, &list[1].year_len, "1990");
    setField(&list[2].title, &list[2].title_len, "new");
    setField(&list[2].year, &list[2].year_len, "2020");
    sortAlbums(&list);
    try std.testing.expectEqualStrings("new", list[0].titleSlice());
    try std.testing.expectEqualStrings("old", list[1].titleSlice());
    try std.testing.expectEqualStrings("no date", list[2].titleSlice());
}

test "user agent is descriptive and contactable (MusicBrainz requirement)" {
    try std.testing.expect(std.mem.startsWith(u8, USER_AGENT, "Opal/"));
    try std.testing.expect(std.mem.indexOf(u8, USER_AGENT, "github.com") != null);
    // Never a browser UA — MusicBrainz blocks those.
    try std.testing.expect(std.mem.indexOf(u8, USER_AGENT, "Mozilla") == null);
}
