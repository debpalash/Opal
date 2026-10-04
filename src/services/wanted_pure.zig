//! Decision logic for the Wanted list: what to search for, which release names
//! count as the thing wanted, which candidate to download, and when to retry.
//!
//! The Wanted list is Opal's CouchPotato-style automation: a title (a movie, or
//! one episode) is added by the user or by an agent, and the app keeps looking
//! until it finds a release that fits the quality profile, then downloads it.
//! Everything here is pure (std only) so the policy is unit-tested and the
//! shipped behaviour is exactly the tested behaviour; `wanted.zig` supplies the
//! database, search and torrent plumbing around it.

const std = @import("std");

pub const Kind = enum {
    movie,
    episode,

    pub fn id(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }
};

pub const Status = enum {
    /// Looking for a release.
    wanted,
    /// A release was chosen and is downloading.
    downloading,
    /// Downloaded; nothing more to do.
    fulfilled,
    /// Not searched until resumed.
    paused,

    pub fn id(self: Status) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Status {
        return std.meta.stringToEnum(Status, s);
    }
};

/// Quality ladder shared with the resolver: 0 unknown, 1 480p, 2 720p,
/// 3 1080p, 4 2160p.
pub const Q_UNKNOWN: u8 = 0;
pub const Q_MAX: u8 = 4;

pub const Profile = struct {
    min_quality: u8 = 2,
    max_quality: u8 = Q_MAX,
    /// The quality to aim for within [min, max]; nearer scores higher.
    prefer_quality: u8 = 3,
    /// Releases with fewer seeders are skipped (a dead swarm never finishes).
    min_seeds: u16 = 3,
    /// 0 means no limit.
    max_size_bytes: u64 = 0,
    /// Untagged releases are accepted at a lower score when true.
    allow_unknown_quality: bool = true,

    pub fn valid(self: Profile) bool {
        return self.min_quality >= 1 and self.min_quality <= self.max_quality and
            self.max_quality <= Q_MAX and self.prefer_quality >= self.min_quality and
            self.prefer_quality <= self.max_quality;
    }
};

pub const Target = struct {
    kind: Kind,
    title: []const u8,
    /// Movies: release year; 0 matches any year.
    year: u16 = 0,
    /// Episodes only.
    season: u16 = 0,
    episode: u16 = 0,
};

pub const Candidate = struct {
    name: []const u8,
    quality: u8,
    seeds: u16,
    /// 0 when unknown.
    size_bytes: u64,
    is_magnet: bool,
    /// Flagged by the torrent risk check (executable posing as media, ...).
    blocked: bool = false,
};

// ── Search ──────────────────────────────────────────────────────────────

/// Query text for the resolver: `Title 2010` or `Title S01E02`.
pub fn searchQuery(buf: []u8, t: Target) ?[]const u8 {
    return switch (t.kind) {
        .movie => if (t.year != 0)
            std.fmt.bufPrint(buf, "{s} {d}", .{ t.title, t.year }) catch null
        else
            std.fmt.bufPrint(buf, "{s}", .{t.title}) catch null,
        .episode => std.fmt.bufPrint(buf, "{s} S{d:0>2}E{d:0>2}", .{ t.title, t.season, t.episode }) catch null,
    };
}

/// Resolver intent string for the kind.
pub fn intent(k: Kind) []const u8 {
    return switch (k) {
        .movie => "movie",
        .episode => "tv",
    };
}

// ── Release name matching ───────────────────────────────────────────────

const max_tokens = 48;
const Tokens = struct {
    items: [max_tokens][]const u8 = undefined,
    n: usize = 0,
};

/// Lower-case alphanumeric runs. Copies into `scratch`, so the slices stay
/// valid for the caller's lifetime of `scratch`.
fn tokenize(s: []const u8, scratch: []u8, out: *Tokens) void {
    out.n = 0;
    var w: usize = 0;
    var start: ?usize = null;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            if (w >= scratch.len) break;
            if (start == null) start = w;
            scratch[w] = std.ascii.toLower(ch);
            w += 1;
        } else if (start) |st| {
            if (out.n < max_tokens) {
                out.items[out.n] = scratch[st..w];
                out.n += 1;
            }
            start = null;
        }
    }
    if (start) |st| if (out.n < max_tokens) {
        out.items[out.n] = scratch[st..w];
        out.n += 1;
    };
}

/// What a user typed into the "want it" box: a movie ("Dune 2021", "Dune") or
/// one episode ("Severance S02E03").
pub const Parsed = struct {
    kind: Kind,
    title: []const u8,
    year: u16 = 0,
    season: u16 = 0,
    episode: u16 = 0,
};

pub fn parseRequest(text: []const u8) ?Parsed {
    var t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;

    // Trailing SxxExx makes it an episode.
    if (std.mem.lastIndexOfScalar(u8, t, ' ')) |sp| {
        const tok = t[sp + 1 ..];
        if (tok.len >= 4 and (tok[0] == 'S' or tok[0] == 's')) {
            if (std.mem.indexOfAny(u8, tok, "Ee")) |e| {
                const season = std.fmt.parseInt(u16, tok[1..e], 10) catch 0;
                const episode = std.fmt.parseInt(u16, tok[e + 1 ..], 10) catch 0;
                const title = std.mem.trim(u8, t[0..sp], " ");
                if (season > 0 and episode > 0 and title.len > 0)
                    return .{ .kind = .episode, .title = title, .season = season, .episode = episode };
            }
        }
        // Trailing year, bare or in parentheses, makes it a dated movie.
        var ytok = tok;
        if (ytok.len == 6 and ytok[0] == '(' and ytok[5] == ')') ytok = ytok[1..5];
        if (ytok.len == 4) {
            if (std.fmt.parseInt(u16, ytok, 10)) |year| {
                const title = std.mem.trim(u8, t[0..sp], " ");
                if (year >= 1888 and year <= 2200 and title.len > 0)
                    return .{ .kind = .movie, .title = title, .year = year };
            } else |_| {}
        }
    }
    t = std.mem.trim(u8, t, " ");
    return .{ .kind = .movie, .title = t };
}

/// Release-name words that mean a low-quality capture or a preview.
const junk = [_][]const u8{
    "cam",     "hdcam",    "camrip", "ts",     "hdts",    "telesync", "tc",
    "telecine", "scr",     "screener", "dvdscr", "r5",    "workprint", "sample",
    "hdtc",    "pdvd",     "predvd",   "reconstructed", "fanedit", "fanedition", "trailer", "teaser",
};

fn isJunk(tok: []const u8) bool {
    for (junk) |j| if (std.mem.eql(u8, tok, j)) return true;
    return false;
}

fn parseUint(tok: []const u8) ?u32 {
    return std.fmt.parseInt(u32, tok, 10) catch null;
}

/// `s01e02` -> (1, 2). Null for anything else (including season packs).
fn parseSxxExx(tok: []const u8) ?struct { s: u32, e: u32 } {
    if (tok.len < 4 or tok[0] != 's') return null;
    const e_at = std.mem.indexOfScalar(u8, tok, 'e') orelse return null;
    if (e_at < 2) return null;
    const s = parseUint(tok[1..e_at]) orelse return null;
    const e = parseUint(tok[e_at + 1 ..]) orelse return null;
    return .{ .s = s, .e = e };
}

/// True when `release` names the wanted title: the title words appear in order
/// at the start of the release (ignoring bracketed tags), a movie carries its
/// year, an episode carries exactly that SxxExx, and no junk word marks it as a
/// cam or screener capture.
pub fn matches(t: Target, release: []const u8) bool {
    var scratch_title: [256]u8 = undefined;
    var scratch_rel: [512]u8 = undefined;
    var title: Tokens = .{};
    var rel: Tokens = .{};
    tokenize(t.title, &scratch_title, &title);
    tokenize(release, &scratch_rel, &rel);
    if (title.n == 0 or rel.n < title.n) return false;

    for (rel.items[0..rel.n]) |tok| if (isJunk(tok)) return false;

    // Find the title as a consecutive run within the first few tokens, which
    // tolerates a leading "[YTS]" / "www site com -" style tag.
    const lead = @min(rel.n - title.n, 6);
    var at: ?usize = null;
    var i: usize = 0;
    while (i <= lead) : (i += 1) {
        var ok = true;
        for (title.items[0..title.n], 0..) |tt, k| {
            if (!std.mem.eql(u8, tt, rel.items[i + k])) {
                ok = false;
                break;
            }
        }
        if (ok) {
            at = i;
            break;
        }
    }
    const start = at orelse return false;
    const after = rel.items[start + title.n .. rel.n];

    switch (t.kind) {
        .movie => {
            if (t.year == 0) return true;
            // The year must come right after the title (maybe after a few
            // qualifier words), so "Dune" 1984 does not match "Dune Part Two 2024".
            const window = @min(after.len, 3);
            for (after[0..window]) |tok| {
                if (parseUint(tok)) |n| if (n == t.year) return true;
            }
            return false;
        },
        .episode => {
            for (after) |tok| {
                if (parseSxxExx(tok)) |se| {
                    if (se.s == t.season and se.e == t.episode) return true;
                }
            }
            // "1x02" appears as tokens "1" "x02"? tokenization yields "1x02".
            for (after) |tok| {
                const x = std.mem.indexOfScalar(u8, tok, 'x') orelse continue;
                if (x == 0) continue;
                const s = parseUint(tok[0..x]) orelse continue;
                const e = parseUint(tok[x + 1 ..]) orelse continue;
                if (s == t.season and e == t.episode) return true;
            }
            return false;
        },
    }
}

// ── Choosing a candidate ────────────────────────────────────────────────

/// Higher is better; null when the candidate is not acceptable at all.
pub fn score(p: Profile, t: Target, c: Candidate) ?i64 {
    if (!c.is_magnet or c.blocked) return null;
    if (!matches(t, c.name)) return null;
    if (c.seeds < p.min_seeds) return null;
    if (p.max_size_bytes != 0 and c.size_bytes > p.max_size_bytes) return null;

    var total: i64 = 0;
    if (c.quality == Q_UNKNOWN) {
        if (!p.allow_unknown_quality) return null;
        total += 1000;
    } else {
        if (c.quality < p.min_quality or c.quality > p.max_quality) return null;
        const gap: i64 = @intCast(if (c.quality > p.prefer_quality) c.quality - p.prefer_quality else p.prefer_quality - c.quality);
        total += 4000 - gap * 800;
    }
    total += @as(i64, @min(c.seeds, 200)) * 5;
    return total;
}

/// Index of the best acceptable candidate; ties go to the earliest (the
/// resolver already orders by its own relevance score).
pub fn pickBest(p: Profile, t: Target, cands: []const Candidate) ?usize {
    var best: ?usize = null;
    var best_score: i64 = std.math.minInt(i64);
    for (cands, 0..) |c, i| {
        const s = score(p, t, c) orelse continue;
        if (s > best_score) {
            best_score = s;
            best = i;
        }
    }
    return best;
}

// ── Scheduling ──────────────────────────────────────────────────────────

pub const min_retry_ms: i64 = 30 * 60 * 1000;
pub const max_retry_ms: i64 = 24 * 60 * 60 * 1000;

/// Delay before the next search after `attempts` fruitless ones: 30 min,
/// doubling, capped at a day. A title nobody has released yet should not be
/// hammering every source all day.
pub fn retryDelayMs(attempts: u32) i64 {
    var d: i64 = min_retry_ms;
    var i: u32 = 0;
    while (i < attempts and d < max_retry_ms) : (i += 1) d *= 2;
    return @min(d, max_retry_ms);
}

pub fn isDue(status: Status, next_check_ms: i64, now_ms: i64) bool {
    return status == .wanted and now_ms >= next_check_ms;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const matrix = Target{ .kind = .movie, .title = "The Matrix", .year = 1999 };

test "search query for movies and episodes" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("The Matrix 1999", searchQuery(&b, matrix).?);
    try testing.expectEqualStrings("Severance S02E05", searchQuery(&b, .{ .kind = .episode, .title = "Severance", .season = 2, .episode = 5 }).?);
    try testing.expectEqualStrings("Heat", searchQuery(&b, .{ .kind = .movie, .title = "Heat" }).?);
    var tiny: [3]u8 = undefined;
    try testing.expect(searchQuery(&tiny, matrix) == null);
}

test "movie names match on title and year" {
    try testing.expect(matches(matrix, "The.Matrix.1999.1080p.BluRay.x264-GRP"));
    try testing.expect(matches(matrix, "The Matrix (1999) [1080p]"));
    try testing.expect(matches(matrix, "[YTS.MX] The Matrix 1999 720p"));
    try testing.expect(!matches(matrix, "The.Matrix.Reloaded.2003.1080p"));
    try testing.expect(!matches(matrix, "The.Matrix.2021.1080p"));
    try testing.expect(!matches(matrix, "Matrix.1999.1080p"));
    try testing.expect(!matches(matrix, "Totally.Different.Film.1999"));
}

test "year disambiguates sequels and remakes" {
    const dune84 = Target{ .kind = .movie, .title = "Dune", .year = 1984 };
    try testing.expect(matches(dune84, "Dune.1984.1080p"));
    try testing.expect(!matches(dune84, "Dune.Part.Two.2024.1080p"));
    try testing.expect(!matches(dune84, "Dune.2021.2160p"));
}

test "no year matches any year" {
    try testing.expect(matches(.{ .kind = .movie, .title = "Heat" }, "Heat.1995.1080p"));
}

test "episodes need the exact SxxExx" {
    const t = Target{ .kind = .episode, .title = "Severance", .season = 2, .episode = 5 };
    try testing.expect(matches(t, "Severance.S02E05.1080p.WEB.h264-GRP"));
    try testing.expect(matches(t, "severance s02e05 720p"));
    try testing.expect(matches(t, "Severance 2x05 HDTV"));
    try testing.expect(!matches(t, "Severance.S02E06.1080p"));
    try testing.expect(!matches(t, "Severance.S01E05.1080p"));
    try testing.expect(!matches(t, "Severance.S02.COMPLETE.1080p"));
}

test "fan edits and previews never match" {
    try testing.expect(!matches(matrix, "The.Matrix.1999.Reconstructed.1080p.x264"));
    try testing.expect(!matches(matrix, "The.Matrix.1999.Trailer.1080p"));
}

test "cam and screener captures never match" {
    try testing.expect(!matches(matrix, "The.Matrix.1999.HDCAM.x264"));
    try testing.expect(!matches(matrix, "The.Matrix.1999.TS.720p"));
    try testing.expect(!matches(matrix, "The.Matrix.1999.DVDScr"));
    // a word that merely contains the letters is fine
    try testing.expect(matches(.{ .kind = .movie, .title = "Cast Away", .year = 2000 }, "Cast.Away.2000.1080p"));
}

test "score rejects wrong quality, thin swarms, non-magnets and blocked" {
    const p = Profile{};
    const ok = Candidate{ .name = "The.Matrix.1999.1080p", .quality = 3, .seeds = 50, .size_bytes = 0, .is_magnet = true };
    try testing.expect(score(p, matrix, ok) != null);

    var c = ok;
    c.quality = 1;
    try testing.expect(score(p, matrix, c) == null);
    c = ok;
    c.seeds = 1;
    try testing.expect(score(p, matrix, c) == null);
    c = ok;
    c.is_magnet = false;
    try testing.expect(score(p, matrix, c) == null);
    c = ok;
    c.blocked = true;
    try testing.expect(score(p, matrix, c) == null);
    c = ok;
    c.name = "The.Matrix.Reloaded.2003.1080p";
    try testing.expect(score(p, matrix, c) == null);
}

test "size cap and unknown quality policy" {
    var p = Profile{ .max_size_bytes = 5 * 1024 * 1024 * 1024 };
    var c = Candidate{ .name = "The.Matrix.1999.1080p", .quality = 3, .seeds = 50, .size_bytes = 9 * 1024 * 1024 * 1024, .is_magnet = true };
    try testing.expect(score(p, matrix, c) == null);
    c.size_bytes = 0; // unknown size passes
    try testing.expect(score(p, matrix, c) != null);

    p = Profile{};
    c = Candidate{ .name = "The.Matrix.1999.BluRay", .quality = Q_UNKNOWN, .seeds = 50, .size_bytes = 0, .is_magnet = true };
    try testing.expect(score(p, matrix, c) != null);
    p.allow_unknown_quality = false;
    try testing.expect(score(p, matrix, c) == null);
}

test "pickBest prefers the target quality, then health" {
    const p = Profile{ .prefer_quality = 3 };
    const cands = [_]Candidate{
        .{ .name = "The.Matrix.1999.720p", .quality = 2, .seeds = 200, .size_bytes = 0, .is_magnet = true },
        .{ .name = "The.Matrix.1999.2160p", .quality = 4, .seeds = 200, .size_bytes = 0, .is_magnet = true },
        .{ .name = "The.Matrix.1999.1080p.A", .quality = 3, .seeds = 10, .size_bytes = 0, .is_magnet = true },
        .{ .name = "The.Matrix.1999.1080p.B", .quality = 3, .seeds = 80, .size_bytes = 0, .is_magnet = true },
        .{ .name = "The.Matrix.1999.HDCAM", .quality = 3, .seeds = 999, .size_bytes = 0, .is_magnet = true },
        .{ .name = "Other.Movie.2020.1080p", .quality = 3, .seeds = 999, .size_bytes = 0, .is_magnet = true },
    };
    try testing.expectEqual(@as(?usize, 3), pickBest(p, matrix, &cands));
}

test "pickBest returns null when nothing qualifies" {
    const cands = [_]Candidate{
        .{ .name = "The.Matrix.1999.480p", .quality = 1, .seeds = 100, .size_bytes = 0, .is_magnet = true },
    };
    try testing.expect(pickBest(.{}, matrix, &cands) == null);
    try testing.expect(pickBest(.{}, matrix, &.{}) == null);
}

test "a 4K-only world still yields a pick when 4K is allowed" {
    const cands = [_]Candidate{
        .{ .name = "The.Matrix.1999.2160p", .quality = 4, .seeds = 30, .size_bytes = 0, .is_magnet = true },
    };
    try testing.expectEqual(@as(?usize, 0), pickBest(.{ .max_quality = 4 }, matrix, &cands));
    try testing.expect(pickBest(.{ .max_quality = 3 }, matrix, &cands) == null);
}

test "profile validity" {
    try testing.expect((Profile{}).valid());
    try testing.expect(!(Profile{ .min_quality = 4, .max_quality = 2 }).valid());
    try testing.expect(!(Profile{ .prefer_quality = 1 }).valid());
    try testing.expect(!(Profile{ .max_quality = 9 }).valid());
}

test "retry backoff doubles from 30 minutes and caps at a day" {
    try testing.expectEqual(min_retry_ms, retryDelayMs(0));
    try testing.expectEqual(min_retry_ms * 2, retryDelayMs(1));
    try testing.expectEqual(min_retry_ms * 4, retryDelayMs(2));
    try testing.expectEqual(max_retry_ms, retryDelayMs(10));
    try testing.expectEqual(max_retry_ms, retryDelayMs(1000));
}

test "only wanted items past their time are due" {
    try testing.expect(isDue(.wanted, 100, 100));
    try testing.expect(!isDue(.wanted, 101, 100));
    try testing.expect(!isDue(.paused, 0, 100));
    try testing.expect(!isDue(.downloading, 0, 100));
    try testing.expect(!isDue(.fulfilled, 0, 100));
}

test "request text parses into movies and episodes" {
    const m = parseRequest("  Dune  ").?;
    try testing.expectEqual(Kind.movie, m.kind);
    try testing.expectEqualStrings("Dune", m.title);
    try testing.expectEqual(@as(u16, 0), m.year);

    const y = parseRequest("Dune 2021").?;
    try testing.expectEqualStrings("Dune", y.title);
    try testing.expectEqual(@as(u16, 2021), y.year);
    try testing.expectEqual(@as(u16, 2008), parseRequest("Big Buck Bunny (2008)").?.year);

    const e = parseRequest("Severance S02E03").?;
    try testing.expectEqual(Kind.episode, e.kind);
    try testing.expectEqualStrings("Severance", e.title);
    try testing.expectEqual(@as(u16, 2), e.season);
    try testing.expectEqual(@as(u16, 3), e.episode);
    try testing.expectEqual(@as(u16, 12), parseRequest("the show s1e12").?.episode);
}

test "request text keeps numeric titles and rejects empties" {
    try testing.expect(parseRequest("   ") == null);
    // A lone number is a title, not a year, and "1917" alone must not vanish.
    const lone = parseRequest("1917").?;
    try testing.expectEqualStrings("1917", lone.title);
    try testing.expectEqual(@as(u16, 0), lone.year);
    // A year-like number that is out of range stays part of the title.
    try testing.expectEqualStrings("Apollo 9999", parseRequest("Apollo 9999").?.title);
    // S00E00 and half-formed tokens are not episodes.
    try testing.expectEqual(Kind.movie, parseRequest("Show S00E01").?.kind);
    try testing.expectEqual(Kind.movie, parseRequest("Season Sale").?.kind);
}
