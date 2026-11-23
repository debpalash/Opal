//! Pure query/ingest helpers for the SQLite Live TV channel catalog
//! (`iptv_catalog`). The SQL text, the LIKE-escape, and the adult group denylist
//! all live here so the exact queries the app runs — and the precise gate that
//! keeps porn out of the grid — are unit-tested rather than assembled inline in
//! the store where nothing can pin them.
//!
//! The catalog exists because the Live TV directory outgrew the fixed
//! [300]IptvChannel array (see core/db.zig). At 100k channels the render path
//! pages the table with LIMIT/OFFSET and searches it with a LIKE over the
//! lowercased-name index — no FTS module dependency, which the Windows build may
//! not carry.

const std = @import("std");
const p = @import("iptv_pure.zig");

/// Column order shared by the page query and the row reader below. A mismatch
/// between the two is the classic "everything shifts one column" bug, so both
/// sides reference THIS list rather than repeating literals.
pub const COLS = "name,url,logo,category,country,quality,user_agent,referrer,chan_id";
pub const COL_COUNT = 9;

/// The page SELECT, minus the WHERE clause (which is composed at bind time from
/// whichever filters are active). `order` is appended verbatim by the caller.
pub const SELECT_PAGE = "SELECT " ++ COLS ++ " FROM iptv_catalog";

/// Escape a user query for a `LIKE ? ESCAPE '\'` match. `%`, `_` and the escape
/// char itself are LIKE metacharacters; unescaped, a query containing `_` would
/// match any single char and `%` would match anything — surprising and, for a
/// `%`-heavy paste, a full scan that returns the whole table. Returns the
/// wrapped `%<escaped>%` pattern written into `out`, or null if it would not fit.
///
/// The query is ALSO lowercased here, because the indexed column (`name_lc`) is
/// stored lowercased at ingest — matching a mixed-case query against it would
/// silently return nothing.
pub fn buildLikePattern(query: []const u8, out: []u8) ?[]const u8 {
    if (out.len < 2) return null;
    var w: usize = 0;
    out[w] = '%';
    w += 1;
    for (query) |ch| {
        const c = std.ascii.toLower(ch);
        if (c == '%' or c == '_' or c == '\\') {
            if (w + 2 > out.len - 1) return null; // -1 reserves the trailing %
            out[w] = '\\';
            w += 1;
            out[w] = c;
            w += 1;
        } else {
            if (w + 1 > out.len - 1) return null;
            out[w] = c;
            w += 1;
        }
    }
    out[w] = '%';
    w += 1;
    return out[0..w];
}

/// Adult `group-title` denylist for the INGEST path. The GitHub m3u sources vary
/// wildly in provenance and the only adult signal many carry is the group name,
/// so — on top of iptv_pure.isNsfw over name+url — a channel whose group matches
/// any of these is dropped before it ever reaches the table. Live TV must NEVER
/// surface adult channels, unconditionally (CLAUDE.md), so this gate has no
/// nsfw_allowed escape hatch: it is always on.
///
/// Substring, case-insensitive. Kept explicit (not "adult", which false-positives
/// on "Adult Swim") — mirrors iptv_pure.isNsfw's conservative token choice.
pub fn isAdultGroup(group: []const u8) bool {
    const tokens = [_][]const u8{
        "xxx",       "porn",   "adult 18", "18+",        "adults only",
        "erotic",    "sex",    "playboy",  "brazzers",   "hustler",
        "penthouse", "hentai", "camsoda",  "chaturbate",
    };
    for (tokens) |t| {
        if (containsCI(group, t)) return true;
    }
    return false;
}

/// The full ingest-time adult gate: a channel is adult if EITHER its group is
/// denylisted OR its name/url trips the iptv_pure heuristic. Routed from the
/// store so the shipped decision is the tested one.
pub fn ingestIsAdult(name: []const u8, url: []const u8, group: []const u8) bool {
    return isAdultGroup(group) or p.isNsfw(name, url);
}

/// Leading integer of a quality label ("1080p" → 1080, "HD"/"" → 0). Stored as
/// `quality_tier` at ingest so the Live TV quality filter/sort is pure SQL over
/// an integer, not a per-row string parse. Mirrors iptv_pure.QualityFilter.tierOf.
pub fn qualityTier(quality: []const u8) u32 {
    var n: u32 = 0;
    for (quality) |ch| {
        if (ch >= '0' and ch <= '9') n = n * 10 + (ch - '0') else break;
    }
    return n;
}

/// Inclusive quality_tier bounds for a QualityFilter index (0 any / 1 sd / 2 hd
/// / 3 fhd). `max == 0` means "no upper bound". Matches iptv_pure.QualityFilter:
/// sd = a real-but-sub-720 tier, hd = >=720, fhd = >=1080.
pub const QBounds = struct { min: u32 = 0, max: u32 = 0 };
pub fn qualityBounds(index: u8) QBounds {
    return switch (index) {
        1 => .{ .min = 1, .max = 719 }, // sd
        2 => .{ .min = 720, .max = 0 }, // hd
        3 => .{ .min = 1080, .max = 0 }, // fhd
        else => .{}, // any → no bound
    };
}

/// Where the universal (omnibox) Live TV search reads from.
pub const UniversalRoute = enum {
    /// No Live TV source installed at all.
    unavailable,
    /// The ingested SQLite catalog — every installed playlist, 36k+ channels.
    catalog,
    /// Catalog not ingested yet: iptv-org's streams.json directly.
    directory,
    /// Sources are installed but nothing is searchable until the first ingest.
    pending,
};

/// The omnibox used to search ONLY iptv-org's streams.json and report
/// `unavailable` unless that one plugin was installed — the other installed
/// playlists (Pluto, Samsung TV Plus, Plex, Free-TV, …) were invisible to it.
pub fn universalRoute(any_installed: bool, has_directory: bool, catalog_rows: usize) UniversalRoute {
    if (catalog_rows > 0) return .catalog;
    if (has_directory) return .directory;
    return if (any_installed) .pending else .unavailable;
}

fn startsWordCI(name: []const u8, query: []const u8) bool {
    if (query.len == 0 or query.len > name.len) return false;
    var i: usize = 0;
    while (i + query.len <= name.len) : (i += 1) {
        if (i > 0 and std.ascii.isAlphanumeric(name[i - 1])) continue;
        if (std.ascii.eqlIgnoreCase(name[i..][0..query.len], query)) return true;
    }
    return false;
}

/// Match strength of a channel name: 0 = starts with the query, 1 = a word
/// starts with it, 2 = substring only. The catalog page is alphabetical, so
/// without this "news" lists "ABC Kids News-ish" rows ahead of "News 12".
pub fn matchRank(name: []const u8, query: []const u8) u8 {
    if (query.len <= name.len and std.ascii.eqlIgnoreCase(name[0..query.len], query)) return 0;
    return if (startsWordCI(name, query)) 1 else 2;
}

/// Collapse a catalog page for the omnibox: drop rows whose stream URL already
/// appeared (iptv-org and its full index list the same stream), then order by
/// matchRank, stable within a rank. Returns the kept count (≤ rows.len).
pub fn rankUniversal(rows: []p.IptvChannel, query: []const u8) usize {
    var n: usize = 0;
    outer: for (rows) |row| {
        const url = row.url[0..row.url_len];
        if (url.len == 0) continue;
        for (rows[0..n]) |kept| {
            if (std.mem.eql(u8, kept.url[0..kept.url_len], url)) continue :outer;
        }
        rows[n] = row;
        n += 1;
    }
    // Stable insertion sort by rank; a page is a few dozen rows.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const row = rows[i];
        const rank = matchRank(row.name[0..row.name_len], query);
        var j = i;
        while (j > 0 and matchRank(rows[j - 1].name[0..rows[j - 1].name_len], query) > rank) : (j -= 1) rows[j] = rows[j - 1];
        rows[j] = row;
    }
    return n;
}

fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

// ── Tests ──

test "buildLikePattern wraps, lowercases, and escapes LIKE metacharacters" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("%bbc%", buildLikePattern("BBC", &b).?);
    // `_` and `%` in the query are literal, not wildcards.
    try std.testing.expectEqualStrings("%a\\_b%", buildLikePattern("A_b", &b).?);
    try std.testing.expectEqualStrings("%50\\%%", buildLikePattern("50%", &b).?);
    // A backslash is itself escaped.
    try std.testing.expectEqualStrings("%a\\\\b%", buildLikePattern("a\\b", &b).?);
}

test "buildLikePattern empty query matches all" {
    var b: [8]u8 = undefined;
    try std.testing.expectEqualStrings("%%", buildLikePattern("", &b).?);
}

test "buildLikePattern rejects an overflowing pattern instead of truncating" {
    var tiny: [3]u8 = undefined;
    // "ab" would need %ab% = 4 bytes; the trailing % cannot fit → null, not a
    // pattern missing its closing wildcard (which would change the match).
    try std.testing.expect(buildLikePattern("ab", &tiny) == null);
}

test "isAdultGroup denies porn groups, allows benign lookalikes" {
    try std.testing.expect(isAdultGroup("XXX"));
    try std.testing.expect(isAdultGroup("Adult 18+"));
    try std.testing.expect(isAdultGroup("Erotic"));
    try std.testing.expect(isAdultGroup("| PORN |"));
    // Must NOT trip on these.
    try std.testing.expect(!isAdultGroup("Adult Swim"));
    try std.testing.expect(!isAdultGroup("News"));
    try std.testing.expect(!isAdultGroup("Kids"));
    try std.testing.expect(!isAdultGroup(""));
}

test "ingestIsAdult combines group denylist with name/url heuristic" {
    // Clean group but adult name (heuristic catches it).
    try std.testing.expect(ingestIsAdult("Redtube Live", "http://x/s.m3u8", "General"));
    // Adult group, clean name.
    try std.testing.expect(ingestIsAdult("Channel 7", "http://x/s.m3u8", "XXX"));
    // Fully clean.
    try std.testing.expect(!ingestIsAdult("BBC One", "http://x/bbc.m3u8", "News"));
}

test "qualityTier extracts the leading integer" {
    try std.testing.expectEqual(@as(u32, 1080), qualityTier("1080p"));
    try std.testing.expectEqual(@as(u32, 720), qualityTier("720p"));
    try std.testing.expectEqual(@as(u32, 0), qualityTier("HD"));
    try std.testing.expectEqual(@as(u32, 0), qualityTier(""));
}

test "qualityBounds maps the filter index to inclusive tier bounds" {
    try std.testing.expectEqual(@as(u32, 0), qualityBounds(0).min); // any
    const sd = qualityBounds(1);
    try std.testing.expectEqual(@as(u32, 1), sd.min);
    try std.testing.expectEqual(@as(u32, 719), sd.max);
    try std.testing.expectEqual(@as(u32, 720), qualityBounds(2).min); // hd
    try std.testing.expectEqual(@as(u32, 0), qualityBounds(2).max); // unbounded
    try std.testing.expectEqual(@as(u32, 1080), qualityBounds(3).min); // fhd
}

test "column count matches the COLS list" {
    var n: usize = 1;
    for (COLS) |ch| {
        if (ch == ',') n += 1;
    }
    try std.testing.expectEqual(COL_COUNT, n);
}

fn testChannel(name: []const u8, url: []const u8) p.IptvChannel {
    var c: p.IptvChannel = .{};
    @memcpy(c.name[0..name.len], name);
    c.name_len = name.len;
    @memcpy(c.url[0..url.len], url);
    c.url_len = url.len;
    return c;
}

test "regression: universal Live TV search covers every installed playlist, not only iptv-org" {
    // An ingested catalog always wins — it holds all installed sources.
    try std.testing.expectEqual(UniversalRoute.catalog, universalRoute(true, true, 36000));
    try std.testing.expectEqual(UniversalRoute.catalog, universalRoute(true, false, 12));
    // Before the first ingest the iptv-org directory still answers.
    try std.testing.expectEqual(UniversalRoute.directory, universalRoute(true, true, 0));
    // Playlists installed without iptv-org are pending, never "unavailable".
    try std.testing.expectEqual(UniversalRoute.pending, universalRoute(true, false, 0));
    try std.testing.expectEqual(UniversalRoute.unavailable, universalRoute(false, false, 0));
}

test "universal ranking dedupes mirrored streams and puts name-prefix matches first" {
    var rows = [_]p.IptvChannel{
        testChannel("ABC Kids Newsroom", "https://a/1.m3u8"),
        testChannel("BBC News", "https://a/2.m3u8"),
        testChannel("BBC News", "https://a/2.m3u8"), // same stream from a second source
        testChannel("News 12 New York", "https://a/3.m3u8"),
        testChannel("", "https://a/4.m3u8"),
        testChannel("No URL News", ""),
    };
    const n = rankUniversal(&rows, "news");
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("News 12 New York", rows[0].name[0..rows[0].name_len]);
    try std.testing.expectEqualStrings("ABC Kids Newsroom", rows[1].name[0..rows[1].name_len]);
    try std.testing.expectEqualStrings("BBC News", rows[2].name[0..rows[2].name_len]);
    try std.testing.expectEqual(@as(u8, 0), matchRank("News 12", "NEWS"));
    try std.testing.expectEqual(@as(u8, 1), matchRank("BBC News", "news"));
    try std.testing.expectEqual(@as(u8, 2), matchRank("Renews", "news"));
}
