//! Pure logic for the EZTV release calendar — feed URL building, string-aware
//! JSON parsing of the get-torrents payload, and the live relative-time label.
//! No io/state, so it unit-tests standalone; eztv_calendar.zig does the network.
//!
//! WHY THE JSON FEED AND NOT THE HTML CALENDAR PAGE
//! -----------------------------------------------
//! The EZTV site's /calendar/ and /countdown/ pages sit behind Cloudflare's
//! JS-challenge interstitial: a plain GET returns HTTP 403 with a
//! "Just a moment..." body, with or without a browser User-Agent. There is no
//! stable markup to parse, so shipping an HTML scraper for them would mean
//! shipping a parser that was never run against real bytes. We don't.
//! (The host itself is never named in this repo's source — it comes from the
//! installed source plugin via source_config. See plugins-manifest.json.)
//!
//! The keyless get-torrents JSON endpoint IS reachable and is what this module
//! parses. It carries `date_released_unix` per torrent, which is the only
//! timestamp we need: the countdown is recomputed from that epoch every frame.
//!
//! Field types below are taken from a real response (they are NOT what you'd
//! guess): `season`, `episode` and `size_bytes` arrive as JSON *strings*, while
//! `seeds` and `date_released_unix` are JSON *numbers*.

const std = @import("std");

pub const MAX_TITLE = 128;

pub const Release = struct {
    title: [MAX_TITLE]u8 = std.mem.zeroes([MAX_TITLE]u8),
    title_len: usize = 0,
    season: i32 = 0,
    episode: i32 = 0,
    seeds: u32 = 0,
    size_bytes: u64 = 0,
    released_epoch: i64 = 0,
};

// ── Feed URL ──

/// `<api>?limit=N` — respects an api endpoint that already carries a query
/// string. Null when the endpoint is empty or the result wouldn't fit `buf`
/// (callers treat null as "stay inert" rather than truncating into a bad URL).
///
/// `limit` is the only parameter and it's a plain integer, so there is nothing
/// to percent-encode here; keep it that way (a caller-supplied string param
/// would need encoding per the project's URL rule).
pub fn buildFeedUrl(api: []const u8, limit: u32, buf: []u8) ?[]const u8 {
    if (api.len == 0) return null;
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, api, '?') != null) "&" else "?";
    return std.fmt.bufPrint(buf, "{s}{s}limit={d}", .{ api, sep, limit }) catch null;
}

// ── String-aware JSON scanning ──
//
// A torrent object's `title` / `filename` can contain any byte, braces and
// escaped quotes included. Bounding an object at the next '}' (or a value at
// the next '"') therefore mis-pairs fields across object boundaries the moment
// a release name contains one — the same class of bug as the FROM/HotD id
// corruption in tmdb_pure. Every scan below tracks string state and escapes.

/// Iterates the top-level `{...}` objects of the `"torrents":[...]` array.
const ObjIter = struct {
    s: []const u8,
    i: usize,

    fn init(body: []const u8) ObjIter {
        const key = "\"torrents\":";
        const at = std.mem.indexOf(u8, body, key) orelse return .{ .s = body, .i = body.len };
        return .{ .s = body, .i = at + key.len };
    }

    fn next(self: *ObjIter) ?[]const u8 {
        // Seek the next structural '{'.
        while (self.i < self.s.len and self.s[self.i] != '{') : (self.i += 1) {
            // The array ends before any further object.
            if (self.s[self.i] == ']') return null;
        }
        if (self.i >= self.s.len) return null;

        const start = self.i;
        var depth: usize = 0;
        var in_str = false;
        var esc = false;
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (in_str) {
                if (esc) {
                    esc = false;
                } else if (c == '\\') {
                    esc = true;
                } else if (c == '"') {
                    in_str = false;
                }
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        self.i += 1;
                        return self.s[start..self.i];
                    }
                },
                else => {},
            }
        }
        return null; // truncated body
    }
};

/// Raw (still-escaped) value of `"key":"..."` within `obj`, or null.
fn jsonRawStr(obj: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [40]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, obj, pat) orelse return null;
    const start = at + pat.len;
    var i = start;
    var esc = false;
    while (i < obj.len) : (i += 1) {
        if (esc) {
            esc = false;
        } else if (obj[i] == '\\') {
            esc = true;
        } else if (obj[i] == '"') {
            return obj[start..i];
        }
    }
    return null;
}

/// Numeric value of `"key":N` within `obj`, or null. Rejects `"key":"N"` — a
/// string-typed field must go through jsonRawStr + parseInt so a schema change
/// surfaces as a miss instead of a silently wrong 0.
fn jsonNum(obj: []const u8, key: []const u8) ?i64 {
    var pat_buf: [40]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, obj, pat) orelse return null;
    var i = at + pat.len;
    while (i < obj.len and obj[i] == ' ') i += 1;
    var neg = false;
    if (i < obj.len and obj[i] == '-') {
        neg = true;
        i += 1;
    }
    var v: i64 = 0;
    var any = false;
    while (i < obj.len and obj[i] >= '0' and obj[i] <= '9') : (i += 1) {
        v = v *| 10 +| (obj[i] - '0');
        any = true;
    }
    if (!any) return null;
    return if (neg) -v else v;
}

/// JSON string escapes → bytes, into `out`. Truncates at `out.len` (never
/// mid-escape). Unknown escapes pass through as the escaped char.
fn unescapeInto(raw: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len and n < out.len) {
        if (raw[i] != '\\' or i + 1 >= raw.len) {
            out[n] = raw[i];
            n += 1;
            i += 1;
            continue;
        }
        const e = raw[i + 1];
        i += 2;
        const ch: u8 = switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 8,
            'f' => 12,
            'u' => {
                // \uXXXX — decode the BMP codepoint and UTF-8 encode it. Bail
                // out to '?' on a surrogate half or a short/!hex sequence so we
                // never emit invalid UTF-8 into a fixed buffer.
                if (i + 4 > raw.len) break;
                const cp = std.fmt.parseInt(u21, raw[i .. i + 4], 16) catch {
                    out[n] = '?';
                    n += 1;
                    i += 4;
                    continue;
                };
                i += 4;
                if (cp >= 0xD800 and cp <= 0xDFFF) {
                    out[n] = '?';
                    n += 1;
                    continue;
                }
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &enc) catch {
                    out[n] = '?';
                    n += 1;
                    continue;
                };
                if (n + len > out.len) break; // never truncate mid-codepoint
                @memcpy(out[n .. n + len], enc[0..len]);
                n += len;
                continue;
            },
            else => e, // covers \" \\ \/ and anything unknown
        };
        out[n] = ch;
        n += 1;
    }
    return n;
}

/// Parse a get-torrents body into `out` (a CALLER-OWNED slice — this function
/// allocates nothing and so can't hand back a mis-sized heap buffer). Returns
/// the number of entries written, capped at `out.len`. Objects with no usable
/// release timestamp are skipped.
pub fn parseFeed(body: []const u8, out: []Release) usize {
    var n: usize = 0;
    var it = ObjIter.init(body);
    while (it.next()) |obj| {
        if (n >= out.len) break;

        const epoch = jsonNum(obj, "date_released_unix") orelse continue;
        if (epoch <= 0) continue;

        var r = Release{};
        r.released_epoch = epoch;

        if (jsonRawStr(obj, "title")) |raw| {
            r.title_len = unescapeInto(raw, &r.title);
        }
        if (r.title_len == 0) continue; // nothing to render

        // season / episode / size_bytes are STRINGS in this API.
        if (jsonRawStr(obj, "season")) |s| {
            r.season = std.fmt.parseInt(i32, s, 10) catch 0;
        }
        if (jsonRawStr(obj, "episode")) |s| {
            r.episode = std.fmt.parseInt(i32, s, 10) catch 0;
        }
        if (jsonRawStr(obj, "size_bytes")) |s| {
            r.size_bytes = std.fmt.parseInt(u64, s, 10) catch 0;
        }
        // seeds is a NUMBER.
        if (jsonNum(obj, "seeds")) |sd| {
            r.seeds = @intCast(std.math.clamp(sd, 0, std.math.maxInt(u32)));
        }

        out[n] = r;
        n += 1;
    }
    return n;
}

// ── Live labels (recomputed every frame from the stored epoch) ──

/// Relative time to/from a release epoch: "in 3d", "in 4h 12m", "in 7m",
/// "airing now", "42m ago", "5h ago", "2d ago".
///
/// tv_calendar_pure.countdownLabel deliberately is NOT reused here: it is
/// tuned for TMDB *air dates*, which are day-granular (00:00 UTC), so every
/// past instant collapses to "today"/"aired" and it has no minute tier. An
/// EZTV release feed is dominated by timestamps minutes-to-hours old and the
/// countdown spec calls for "in 4h 12m" / "airing now" — neither of which that
/// function can express. Different granularity, different domain, own tests.
pub fn releaseLabel(now_s: i64, epoch: i64, buf: []u8) []const u8 {
    const NOW_WINDOW = 5 * 60; // ±5 min reads as "airing now"
    const diff = epoch - now_s;

    if (diff > 0) {
        const days = @divFloor(diff, 86400);
        if (days >= 1) return std.fmt.bufPrint(buf, "in {d}d", .{days}) catch "soon";
        const hours = @divFloor(diff, 3600);
        if (hours >= 1) {
            const mins = @divFloor(@mod(diff, 3600), 60);
            return std.fmt.bufPrint(buf, "in {d}h {d}m", .{ hours, mins }) catch "soon";
        }
        if (diff <= NOW_WINDOW) return "airing now";
        const mins = @divFloor(diff, 60);
        return std.fmt.bufPrint(buf, "in {d}m", .{mins}) catch "soon";
    }

    const ago = -diff;
    if (ago <= NOW_WINDOW) return "airing now";
    const mins = @divFloor(ago, 60);
    if (mins < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{mins}) catch "just now";
    const hours = @divFloor(ago, 3600);
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "just now";
    const days = @divFloor(ago, 86400);
    return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "just now";
}

/// "S03E04", or "" when the feed carried no season/episode (movies, packs).
pub fn episodeTag(season: i32, episode: i32, buf: []u8) []const u8 {
    if (season <= 0 or episode <= 0) return "";
    return std.fmt.bufPrint(buf, "S{d:0>2}E{d:0>2}", .{
        @as(u32, @intCast(season)),
        @as(u32, @intCast(episode)),
    }) catch "";
}


// ── Tests ──

test "buildFeedUrl appends limit, respects an existing query" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://example.test/api/get-torrents?limit=20",
        buildFeedUrl("https://example.test/api/get-torrents", 20, &b).?,
    );
    try std.testing.expectEqualStrings(
        "https://example.test/api?x=1&limit=5",
        buildFeedUrl("https://example.test/api?x=1", 5, &b).?,
    );
    // Inert inputs / no room → null, never a truncated URL.
    try std.testing.expect(buildFeedUrl("", 20, &b) == null);
    var tiny: [8]u8 = undefined;
    try std.testing.expect(buildFeedUrl("https://example.test/api", 20, &tiny) == null);
}

// Shape copied verbatim from a real get-torrents response (2026-07): season,
// episode and size_bytes are strings; seeds and date_released_unix are numbers.
const REAL_BODY =
    "{\"torrents_count\":1063193,\"limit\":3,\"page\":1,\"torrents\":[" ++
    "{\"id\":3124293,\"hash\":\"c1d5\",\"filename\":\"Big Brother US S28E03 720p[EZTVx.to].mkv\"," ++
    "\"magnet_url\":\"magnet:?xt=urn:btih:c1d5&tr=udp:\\/\\/tracker.opentrackr.org:1337\\/announce\"," ++
    "\"title\":\"Big Brother US S28E03 720p AMZN WEB-DL DDP2 0 H 264-NTb EZTV\",\"imdb_id\":\"7948268\"," ++
    "\"season\":\"28\",\"episode\":\"3\",\"small_screenshot\":\"\",\"large_screenshot\":\"\"," ++
    "\"seeds\":0,\"peers\":4,\"date_released_unix\":1783926162,\"size_bytes\":\"2930308381\"}," ++
    "{\"id\":3124290,\"title\":\"Evolution 2026 S01E01 720p WEB H264-JFF EZTV\",\"imdb_id\":\"0\"," ++
    "\"season\":\"1\",\"episode\":\"1\",\"seeds\":35,\"peers\":9," ++
    "\"date_released_unix\":1783923976,\"size_bytes\":\"1073741824\"}]}";

test "parseFeed: real payload, string season/episode/size, number seeds/epoch" {
    var out: [8]Release = undefined;
    const n = parseFeed(REAL_BODY, &out);
    try std.testing.expectEqual(@as(usize, 2), n);

    try std.testing.expectEqualStrings(
        "Big Brother US S28E03 720p AMZN WEB-DL DDP2 0 H 264-NTb EZTV",
        out[0].title[0..out[0].title_len],
    );
    try std.testing.expectEqual(@as(i32, 28), out[0].season);
    try std.testing.expectEqual(@as(i32, 3), out[0].episode);
    try std.testing.expectEqual(@as(u32, 0), out[0].seeds);
    try std.testing.expectEqual(@as(u64, 2930308381), out[0].size_bytes);
    try std.testing.expectEqual(@as(i64, 1783926162), out[0].released_epoch);

    try std.testing.expectEqual(@as(i32, 1), out[1].season);
    try std.testing.expectEqual(@as(u32, 35), out[1].seeds);
    try std.testing.expectEqual(@as(i64, 1783923976), out[1].released_epoch);
    // The magnet_url's escaped slashes must not leak into the next object's
    // fields (raw-scan parsers drift here).
    try std.testing.expectEqual(@as(u64, 1073741824), out[1].size_bytes);
}

test "parseFeed: cap at out.len, never overrun the caller's buffer" {
    var one: [1]Release = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseFeed(REAL_BODY, &one));
    var zero: [0]Release = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseFeed(REAL_BODY, &zero));
}

test "parseFeed regression: a brace or quote inside a title must not split the object" {
    // A release name containing '}' and an escaped '"'. A parser that bounds
    // objects at the next '}' pairs THIS title with the NEXT object's numbers.
    const body =
        "{\"torrents\":[" ++
        "{\"title\":\"Show \\\"Quoted\\\" S01E02 {rare} release\",\"season\":\"1\",\"episode\":\"2\"," ++
        "\"seeds\":7,\"date_released_unix\":1000,\"size_bytes\":\"2048\"}," ++
        "{\"title\":\"Other S09E09\",\"season\":\"9\",\"episode\":\"9\"," ++
        "\"seeds\":99,\"date_released_unix\":2000,\"size_bytes\":\"4096\"}]}";
    var out: [4]Release = undefined;
    const n = parseFeed(body, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings(
        "Show \"Quoted\" S01E02 {rare} release",
        out[0].title[0..out[0].title_len],
    );
    try std.testing.expectEqual(@as(i32, 1), out[0].season);
    try std.testing.expectEqual(@as(u32, 7), out[0].seeds); // not 99
    try std.testing.expectEqual(@as(i64, 1000), out[0].released_epoch);
    try std.testing.expectEqual(@as(i32, 9), out[1].season);
    try std.testing.expectEqual(@as(u32, 99), out[1].seeds);
}

test "parseFeed: skips rows with no timestamp or no title, tolerates junk" {
    const body =
        "{\"torrents\":[" ++
        "{\"title\":\"No Timestamp S01E01\",\"season\":\"1\",\"episode\":\"1\",\"seeds\":5}," ++
        "{\"season\":\"2\",\"episode\":\"2\",\"seeds\":6,\"date_released_unix\":1500}," ++
        "{\"title\":\"Good S03E03\",\"season\":\"3\",\"episode\":\"3\",\"seeds\":8,\"date_released_unix\":1600}]}";
    var out: [8]Release = undefined;
    const n = parseFeed(body, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("Good S03E03", out[0].title[0..out[0].title_len]);

    // Garbage / empty / truncated bodies are a no-op, not a crash.
    try std.testing.expectEqual(@as(usize, 0), parseFeed("", &out));
    try std.testing.expectEqual(@as(usize, 0), parseFeed("not json", &out));
    try std.testing.expectEqual(@as(usize, 0), parseFeed("{\"torrents\":[{\"title\":\"trunc", &out));
    try std.testing.expectEqual(@as(usize, 0), parseFeed("{\"torrents\":[]}", &out));
}

test "parseFeed: unescapes and never overflows the fixed title buffer" {
    // 200-char title into a 128-byte field: truncated, never overrun.
    const long = "x" ** 200;
    const body = "{\"torrents\":[{\"title\":\"" ++ long ++ "\",\"date_released_unix\":10}]}";
    var out: [2]Release = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseFeed(body, &out));
    try std.testing.expectEqual(@as(usize, MAX_TITLE), out[0].title_len);

    // \/ and \u escapes decode.
    const esc = "{\"torrents\":[{\"title\":\"A\\/B \\u00e9\",\"date_released_unix\":10}]}";
    try std.testing.expectEqual(@as(usize, 1), parseFeed(esc, &out));
    try std.testing.expectEqualStrings("A/B \u{e9}", out[0].title[0..out[0].title_len]);
}

test "releaseLabel: future tiers, now window, past tiers" {
    var b: [32]u8 = undefined;
    const day = 86400;
    // Future.
    try std.testing.expectEqualStrings("in 3d", releaseLabel(0, 3 * day + 3600, &b));
    try std.testing.expectEqualStrings("in 4h 12m", releaseLabel(0, 4 * 3600 + 12 * 60, &b));
    try std.testing.expectEqualStrings("in 42m", releaseLabel(0, 42 * 60, &b));
    // Now window (±5 min).
    try std.testing.expectEqualStrings("airing now", releaseLabel(0, 60, &b));
    try std.testing.expectEqualStrings("airing now", releaseLabel(0, 0, &b));
    try std.testing.expectEqualStrings("airing now", releaseLabel(300, 0, &b));
    // Past.
    try std.testing.expectEqualStrings("42m ago", releaseLabel(42 * 60, 0, &b));
    try std.testing.expectEqualStrings("5h ago", releaseLabel(5 * 3600, 0, &b));
    try std.testing.expectEqualStrings("2d ago", releaseLabel(2 * day, 0, &b));
}

test "releaseLabel is a pure function of (now, epoch) — it moves as now moves" {
    // The countdown must NOT be baked at fetch time: same stored epoch, two
    // different `now`s, two different labels.
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const epoch: i64 = 10_000;
    const a = releaseLabel(epoch - 2 * 3600, epoch, &b1); // 2h before release
    const c = releaseLabel(epoch + 2 * 3600, epoch, &b2); // 2h after
    try std.testing.expectEqualStrings("in 2h 0m", a);
    try std.testing.expectEqualStrings("2h ago", c);
}

test "episodeTag" {
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("S03E04", episodeTag(3, 4, &b));
    try std.testing.expectEqualStrings("S28E03", episodeTag(28, 3, &b));
    try std.testing.expectEqualStrings("", episodeTag(0, 0, &b));
    try std.testing.expectEqualStrings("", episodeTag(1, 0, &b));

}

// ══════════════════════════════════════════════════════════
// Grouping releases into SHOW cards
//
// The feed is a flat list of torrent releases; the rail wants one card per SHOW,
// carrying its newest episode. Two releases of the same episode (different
// groups/qualities) must collapse to one card, or the rail is three rows of the
// same show.
// ══════════════════════════════════════════════════════════

pub const MAX_SHOW_CARDS = 20;

pub const ShowCard = struct {
    /// Show name parsed out of the release title ("Rick and Morty").
    name: [96]u8 = std.mem.zeroes([96]u8),
    name_len: usize = 0,
    /// Newest episode seen for this show in the feed.
    season: i32 = 0,
    episode: i32 = 0,
    released_epoch: i64 = 0,
    seeds: u32 = 0,

    pub fn nameSlice(self: *const ShowCard) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }
};

/// Case-insensitive show-name equality — "Rick and Morty" and "rick.and.morty"
/// are the same show, and the feed is not consistent about either.
fn sameShow(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Collapse `releases` into one card per show, keeping each show's NEWEST episode
/// (and the best seed count seen for it). Returns the number of cards written.
///
/// `showNameOf` is injected so this stays pure: the caller passes the tested
/// `subtitles_pure.parse` show extractor rather than this file re-rolling one.
pub fn groupShows(
    releases: []const Release,
    out: []ShowCard,
    comptime showNameOf: fn (title: []const u8, buf: []u8) []const u8,
) usize {
    var n: usize = 0;

    for (releases) |*r| {
        const title = r.title[0..@min(r.title_len, r.title.len)];
        if (title.len == 0) continue;

        var nbuf: [96]u8 = undefined;
        const show = showNameOf(title, &nbuf);
        if (show.len == 0) continue;
        // A release with no SxxEyy isn't an episode we can name — skip it rather
        // than make a card titled after a raw torrent filename.
        if (r.season <= 0 or r.episode <= 0) continue;

        // Already have this show? Keep the NEWER episode.
        var found = false;
        for (out[0..n]) |*c| {
            if (!sameShow(c.nameSlice(), show)) continue;
            found = true;
            const newer = r.season > c.season or
                (r.season == c.season and r.episode > c.episode);
            if (newer) {
                c.season = r.season;
                c.episode = r.episode;
                c.released_epoch = r.released_epoch;
            }
            if (r.seeds > c.seeds) c.seeds = r.seeds;
            break;
        }
        if (found) continue;

        if (n >= out.len) break;
        var c = &out[n];
        c.* = .{};
        const ln = @min(show.len, c.name.len);
        @memcpy(c.name[0..ln], show[0..ln]);
        c.name_len = ln;
        c.season = r.season;
        c.episode = r.episode;
        c.released_epoch = r.released_epoch;
        c.seeds = r.seeds;
        n += 1;
    }

    return n;
}

// ── Tests ──

/// Stand-in for subtitles_pure.parse's show extractor: take everything before the
/// SxxEyy and turn separators into spaces. Good enough to exercise groupShows.
fn testShowName(title: []const u8, buf: []u8) []const u8 {
    const cut = std.mem.indexOf(u8, title, ".S0") orelse title.len;
    var n: usize = 0;
    for (title[0..cut]) |ch| {
        if (n >= buf.len) break;
        buf[n] = if (ch == '.' or ch == '_') ' ' else ch;
        n += 1;
    }
    return std.mem.trim(u8, buf[0..n], " ");
}

fn mkRelease(title: []const u8, s: i32, e: i32, seeds: u32, epoch: i64) Release {
    var r = Release{ .season = s, .episode = e, .seeds = seeds, .released_epoch = epoch };
    const n = @min(title.len, r.title.len);
    @memcpy(r.title[0..n], title[0..n]);
    r.title_len = n;
    return r;
}

test "groupShows: one card per show, keeping the newest episode" {
    const rels = [_]Release{
        mkRelease("Rick.and.Morty.S09E07.1080p.WEB.h264-EDITH.mkv", 9, 7, 50, 100),
        // Same episode, different release group — must NOT become a second card.
        mkRelease("Rick.and.Morty.S09E07.720p.WEB.x265-OTHER.mkv", 9, 7, 90, 90),
        // Newer episode of the same show — must REPLACE, not append.
        mkRelease("Rick.and.Morty.S09E08.1080p.WEB.h264-EDITH.mkv", 9, 8, 30, 200),
        mkRelease("The.Boys.S04E01.1080p.WEB.mkv", 4, 1, 10, 50),
    };
    var out: [MAX_SHOW_CARDS]ShowCard = undefined;
    const n = groupShows(&rels, &out, testShowName);

    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("Rick and Morty", out[0].nameSlice());
    try std.testing.expectEqual(@as(i32, 9), out[0].season);
    try std.testing.expectEqual(@as(i32, 8), out[0].episode); // the newer one won
    try std.testing.expectEqual(@as(u32, 90), out[0].seeds); // best seeds seen
    try std.testing.expectEqualStrings("The Boys", out[1].nameSlice());
}

test "groupShows: case-insensitive show matching" {
    const rels = [_]Release{
        mkRelease("Rick.and.Morty.S09E01.mkv", 9, 1, 5, 10),
        mkRelease("rick.and.morty.S09E02.mkv", 9, 2, 5, 20),
    };
    var out: [MAX_SHOW_CARDS]ShowCard = undefined;
    try std.testing.expectEqual(@as(usize, 1), groupShows(&rels, &out, testShowName));
    try std.testing.expectEqual(@as(i32, 2), out[0].episode);
}

test "groupShows: a release with no SxxEyy is skipped, not titled after a filename" {
    const rels = [_]Release{
        mkRelease("Some.Random.Movie.2024.1080p.mkv", 0, 0, 100, 10),
        mkRelease("The.Boys.S04E01.mkv", 4, 1, 10, 20),
    };
    var out: [MAX_SHOW_CARDS]ShowCard = undefined;
    const n = groupShows(&rels, &out, testShowName);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("The Boys", out[0].nameSlice());
}

test "groupShows: never overruns the output buffer" {
    var rels: [40]Release = undefined;
    for (&rels, 0..) |*r, i| {
        var tb: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&tb, "Show{d}.S01E01.mkv", .{i}) catch unreachable;
        r.* = mkRelease(t, 1, 1, 1, @intCast(i));
    }
    var out: [4]ShowCard = undefined;
    try std.testing.expectEqual(@as(usize, 4), groupShows(&rels, &out, testShowName));
}

// ══════════════════════════════════════════════════════════
// Resolving artwork
//
// The feed carries a torrent title and nothing else — no poster, no TMDB id. To
// draw the same poster card the library uses, each show has to be looked up. These
// two helpers are the pure half of that.
// ══════════════════════════════════════════════════════════

/// Percent-encode a search query. Encodes everything that isn't unreserved, which
/// is stricter than necessary and therefore safe: a stray `&` or `#` in a show
/// name would otherwise truncate the query or start a fragment.
pub fn encodeQuery(s: []const u8, buf: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |ch| {
        const unreserved = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            if (n + 1 > buf.len) break;
            buf[n] = ch;
            n += 1;
        } else if (ch == ' ') {
            if (n + 3 > buf.len) break;
            buf[n] = '%';
            buf[n + 1] = '2';
            buf[n + 2] = '0';
            n += 3;
        } else {
            if (n + 3 > buf.len) break;
            buf[n] = '%';
            buf[n + 1] = hex[ch >> 4];
            buf[n + 2] = hex[ch & 0x0F];
            n += 3;
        }
    }
    return buf[0..n];
}

pub const TvHit = struct {
    tmdb_id: i32 = 0,
    poster_path: [64]u8 = std.mem.zeroes([64]u8),
    poster_path_len: usize = 0,

    pub fn posterSlice(self: *const TvHit) []const u8 {
        return self.poster_path[0..@min(self.poster_path_len, self.poster_path.len)];
    }
};

/// First result of a TMDB `/3/search/tv` response.
///
/// Scans the `"results":[` array specifically — `"id"` and `"poster_path"` also
/// appear elsewhere in the document, and a naive global search would happily pull
/// the id out of some other object.
pub fn firstTvResult(json: []const u8) ?TvHit {
    const key = "\"results\":";
    const at = std.mem.indexOf(u8, json, key) orelse return null;
    var i = at + key.len;
    while (i < json.len and json[i] == ' ') i += 1;
    if (i >= json.len or json[i] != '[') return null;
    i += 1;
    // Empty results array -> no hit, rather than a bogus one.
    while (i < json.len and (json[i] == ' ' or json[i] == '\n')) i += 1;
    if (i >= json.len or json[i] != '{') return null;

    // Bound to the first object so we can't read fields out of the second.
    const end = std.mem.indexOfScalarPos(u8, json, i, '}') orelse return null;
    const obj = json[i .. end + 1];

    var hit = TvHit{};

    if (std.mem.indexOf(u8, obj, "\"id\":")) |idx| {
        var j = idx + 5;
        while (j < obj.len and obj[j] == ' ') j += 1;
        var v: i64 = 0;
        var any = false;
        while (j < obj.len and std.ascii.isDigit(obj[j])) : (j += 1) {
            v = v * 10 + @as(i64, obj[j] - '0');
            any = true;
        }
        if (!any) return null;
        hit.tmdb_id = @intCast(@min(v, std.math.maxInt(i32)));
    } else return null;

    if (std.mem.indexOf(u8, obj, "\"poster_path\":")) |pidx| {
        var j = pidx + "\"poster_path\":".len;
        while (j < obj.len and obj[j] == ' ') j += 1;
        if (j < obj.len and obj[j] == '"') {
            j += 1;
            const start = j;
            while (j < obj.len and obj[j] != '"') j += 1;
            const p = obj[start..j];
            const n = @min(p.len, hit.poster_path.len);
            @memcpy(hit.poster_path[0..n], p[0..n]);
            hit.poster_path_len = n;
        }
        // `"poster_path": null` -> leave empty; the card renders its empty frame.
    }

    return hit;
}

test "encodeQuery: a stray & or # can't truncate the query" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Rick%20and%20Morty", encodeQuery("Rick and Morty", &buf));
    try std.testing.expectEqualStrings("S.W.A.T.", encodeQuery("S.W.A.T.", &buf));
    try std.testing.expectEqualStrings("Cheers%26Jeers", encodeQuery("Cheers&Jeers", &buf));
    try std.testing.expectEqualStrings("A%23B", encodeQuery("A#B", &buf));
}

test "firstTvResult: reads the FIRST result, not fields from elsewhere" {
    const json =
        \\{"page":1,"results":[
        \\{"id":60625,"name":"Rick and Morty","poster_path":"/abc.jpg"},
        \\{"id":999,"name":"Other","poster_path":"/zzz.jpg"}
        \\],"total_results":2}
    ;
    const hit = firstTvResult(json).?;
    try std.testing.expectEqual(@as(i32, 60625), hit.tmdb_id);
    try std.testing.expectEqualStrings("/abc.jpg", hit.posterSlice());
}

test "firstTvResult: no results / null poster / junk" {
    try std.testing.expect(firstTvResult("{\"results\":[]}") == null);
    try std.testing.expect(firstTvResult("{}") == null);
    try std.testing.expect(firstTvResult("") == null);

    // A show with no artwork still resolves an id — the card just draws an empty
    // poster frame rather than being dropped.
    const hit = firstTvResult("{\"results\":[{\"id\":42,\"poster_path\":null}]}").?;
    try std.testing.expectEqual(@as(i32, 42), hit.tmdb_id);
    try std.testing.expectEqual(@as(usize, 0), hit.poster_path_len);
}
