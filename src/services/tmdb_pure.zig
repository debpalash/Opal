//! Pure (io-free, state-free) TMDB string helpers — unit-testable via `zig build
//! test`. The production parsers in tmdb_parse.zig / tmdb_api.zig / tmdb.zig call
//! into these so the tested logic IS the shipped logic.

const std = @import("std");

/// Rewrite an `https://…` URL to `http://…` into `buf`. Returns null if `url`
/// isn't https or `buf` is too small. Used by the TMDB HTTPS→HTTP fallback for
/// SNI-blocked networks (see memory: opal-tmdb-https-block).
pub fn httpsToHttp(url: []const u8, buf: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, "https://")) return null;
    return std.fmt.bufPrint(buf, "http://{s}", .{url["https://".len..]}) catch null;
}

/// True if `key` is a TMDB v4 Read-Access-Token (a JWT, "eyJ…") rather than a v3
/// API key (32-char hex). v4 tokens MUST be sent via `Authorization: Bearer`; a
/// v4 token in the `?api_key=` query param returns 401 "Invalid API key" (the
/// bug that broke resolver/AI TMDB lookups). v3 keys go in `?api_key=`.
pub fn keyIsV4(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "eyJ");
}

/// True if `body` looks like a JSON document (first non-whitespace byte is `{` or
/// `[`). Used to reject ISP/captive-portal block pages (HTML) that some networks
/// inject over plain HTTP — accepting that HTML as a "successful" TMDB response
/// poisoned the sticky HTTPS→HTTP fallback and made all content stop loading.
pub fn looksLikeJson(body: []const u8) bool {
    for (body) |ch| {
        switch (ch) {
            ' ', '\t', '\r', '\n' => continue,
            '{', '[' => return true,
            else => return false,
        }
    }
    return false;
}

/// String-aware splitter for a TMDB `"results":[ {…}, {…} ]` array. Fills `out`
/// with a slice for each top-level object, WITHOUT entering string literals — so
/// a `{` or `}` inside a title/overview can't desync the brace counter (the bug
/// that corrupted item ids and broke TV-detail for "FROM" / "House of the
/// Dragon"). Returns the object count (capped at out.len).
pub fn splitResultObjects(body: []const u8, out: [][]const u8) usize {
    const key = "\"results\":[";
    const rs = std.mem.indexOf(u8, body, key) orelse return 0;
    var i = rs + key.len;
    var depth: i32 = 0;
    var obj_start: ?usize = null;
    var in_str = false;
    var esc = false;
    var count: usize = 0;
    while (i < body.len and count < out.len) : (i += 1) {
        const c = body[i];
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
            '{' => {
                if (depth == 0) obj_start = i;
                depth += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    if (obj_start) |s| {
                        out[count] = body[s .. i + 1];
                        count += 1;
                        obj_start = null;
                    }
                }
            },
            ']' => if (depth == 0) break,
            else => {},
        }
    }
    return count;
}

/// First non-negative integer following `key` in `s` (digits only). Used to pull
/// the top-level `"id":` out of a result object.
pub fn firstIntAfter(s: []const u8, key: []const u8) i64 {
    const ki = std.mem.indexOf(u8, s, key) orelse return 0;
    var i = ki + key.len;
    while (i < s.len and s[i] == ' ') i += 1;
    var v: i64 = 0;
    var any = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + @as(i64, s[i] - '0');
        any = true;
    }
    return if (any) v else 0;
}

test "splitResultObjects: brace inside a string doesn't desync (FROM/HotD regression)" {
    // The first result's overview contains a stray '}' — the old non-string-aware
    // splitter dropped/mis-sliced the SECOND result, corrupting its id.
    const body =
        "{\"page\":1,\"results\":[" ++
        "{\"id\":111,\"name\":\"Decoy\",\"overview\":\"a closing brace } in text\"}," ++
        "{\"id\":94997,\"name\":\"House of the Dragon\"}" ++
        "],\"total_pages\":1}";
    var out: [8][]const u8 = undefined;
    const n = splitResultObjects(body, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(i64, 111), firstIntAfter(out[0], "\"id\":"));
    try std.testing.expectEqual(@as(i64, 94997), firstIntAfter(out[1], "\"id\":"));
}

test "splitResultObjects: empty / missing results" {
    var out: [4][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), splitResultObjects("{\"x\":1}", &out));
    try std.testing.expectEqual(@as(usize, 0), splitResultObjects("{\"results\":[]}", &out));
}

test "splitResultObjects: nested object in a result stays one top-level slice" {
    const body = "{\"results\":[{\"id\":7,\"belongs_to\":{\"id\":99,\"name\":\"x\"}}]}";
    var out: [4][]const u8 = undefined;
    const n = splitResultObjects(body, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    // First "id": is still the top-level one.
    try std.testing.expectEqual(@as(i64, 7), firstIntAfter(out[0], "\"id\":"));
}

test "httpsToHttp rewrites only https" {
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://api.themoviedb.org/3/tv/94997",
        httpsToHttp("https://api.themoviedb.org/3/tv/94997", &buf).?,
    );
    try std.testing.expect(httpsToHttp("http://already", &buf) == null);
    try std.testing.expect(httpsToHttp("ftp://nope", &buf) == null);
}

test "keyIsV4 distinguishes JWT bearer tokens from v3 keys" {
    // v4 Read-Access-Token (JWT) → Bearer header.
    try std.testing.expect(keyIsV4("eyJhbGciOiJIUzI1NiJ9.payload.sig"));
    // v3 key (32-char hex) → ?api_key= query param.
    try std.testing.expect(!keyIsV4("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!keyIsV4(""));
}

test "looksLikeJson accepts JSON, rejects ISP HTML block pages" {
    try std.testing.expect(looksLikeJson("{\"results\":[]}"));
    try std.testing.expect(looksLikeJson("  \n\t [1,2,3]"));
    // The Airtel court-order block page that broke the HTTP fallback.
    try std.testing.expect(!looksLikeJson("<meta name=\"viewport\"><iframe src=\"http://www.airtel.in/court-orders/\">"));
    try std.testing.expect(!looksLikeJson("   "));
    try std.testing.expect(!looksLikeJson(""));
}

// ══════════════════════════════════════════════════════════
// Grid virtualization — visible row window
// ══════════════════════════════════════════════════════════

pub const RowWindow = struct { first: usize, last: usize };

/// Which rows of a uniform-row grid intersect the scroll viewport, padded by
/// `overscan` rows on each side. Rows outside [first, last) are replaced by
/// fixed-height spacers, so a 1900-item gallery lays out ~5 rows per frame
/// instead of all of them. Returns half-open [first, last).
pub fn visibleRows(total_rows: usize, row_h: f32, viewport_y: f32, viewport_h: f32, overscan: usize) RowWindow {
    if (total_rows == 0 or row_h <= 0) return .{ .first = 0, .last = 0 };
    const y = @max(0.0, viewport_y);
    const first_vis: usize = @intFromFloat(y / row_h);
    // ceil((y + h) / row_h) without float ceil: floor + 1 covers a partial row.
    const last_vis: usize = @as(usize, @intFromFloat((y + @max(0.0, viewport_h)) / row_h)) + 1;
    const first = @min(total_rows, first_vis -| overscan);
    const last = @min(total_rows, last_vis + overscan);
    return .{ .first = first, .last = @max(first, last) };
}

test "visibleRows windows a tall grid" {
    // 100 rows of 200px, viewport 600px tall scrolled to 2000px.
    const w = visibleRows(100, 200, 2000, 600, 2);
    // Rows 10..13 visible; ±2 overscan → [8, 16).
    try std.testing.expectEqual(@as(usize, 8), w.first);
    try std.testing.expectEqual(@as(usize, 16), w.last);
}

test "visibleRows clamps at the edges" {
    // Top of the list — no negative underflow from overscan.
    const top = visibleRows(100, 200, 0, 600, 2);
    try std.testing.expectEqual(@as(usize, 0), top.first);
    try std.testing.expectEqual(@as(usize, 6), top.last);
    // Bottom of the list — last clamps to total_rows.
    const bot = visibleRows(10, 200, 1400, 600, 2);
    try std.testing.expectEqual(@as(usize, 5), bot.first);
    try std.testing.expectEqual(@as(usize, 10), bot.last);
    // Everything fits — window is the whole list.
    const all = visibleRows(3, 200, 0, 600, 2);
    try std.testing.expectEqual(@as(usize, 0), all.first);
    try std.testing.expectEqual(@as(usize, 3), all.last);
}

test "visibleRows degenerate inputs" {
    const none = visibleRows(0, 200, 0, 600, 2);
    try std.testing.expectEqual(@as(usize, 0), none.last);
    const zero_h = visibleRows(10, 0, 0, 600, 2);
    try std.testing.expectEqual(@as(usize, 0), zero_h.last);
}

// ══════════════════════════════════════════════════════════
// Genre discover — static TMDB genre table
// ══════════════════════════════════════════════════════════

/// Movie and TV genre ids differ on TMDB (e.g. movie Action=28 vs TV
/// Action & Adventure=10759). Where TV has no exact counterpart (Horror,
/// Thriller, History) the closest TV genre is used.
pub const Genre = struct { name: []const u8, movie_id: u32, tv_id: u32 };

pub const GENRES = [_]Genre{
    .{ .name = "All genres", .movie_id = 0, .tv_id = 0 },
    .{ .name = "Action", .movie_id = 28, .tv_id = 10759 },
    .{ .name = "Adventure", .movie_id = 12, .tv_id = 10759 },
    .{ .name = "Animation", .movie_id = 16, .tv_id = 16 },
    .{ .name = "Comedy", .movie_id = 35, .tv_id = 35 },
    .{ .name = "Crime", .movie_id = 80, .tv_id = 80 },
    .{ .name = "Documentary", .movie_id = 99, .tv_id = 99 },
    .{ .name = "Drama", .movie_id = 18, .tv_id = 18 },
    .{ .name = "Family", .movie_id = 10751, .tv_id = 10751 },
    .{ .name = "Fantasy", .movie_id = 14, .tv_id = 10765 },
    .{ .name = "History", .movie_id = 36, .tv_id = 10768 },
    .{ .name = "Horror", .movie_id = 27, .tv_id = 9648 },
    .{ .name = "Music", .movie_id = 10402, .tv_id = 10402 },
    .{ .name = "Mystery", .movie_id = 9648, .tv_id = 9648 },
    .{ .name = "Romance", .movie_id = 10749, .tv_id = 10749 },
    .{ .name = "Sci-Fi", .movie_id = 878, .tv_id = 10765 },
    .{ .name = "Thriller", .movie_id = 53, .tv_id = 80 },
    .{ .name = "War", .movie_id = 10752, .tv_id = 10768 },
    .{ .name = "Western", .movie_id = 37, .tv_id = 37 },
};

/// Dropdown entry labels (parallel to GENRES).
pub const GENRE_NAMES = blk: {
    var names: [GENRES.len][]const u8 = undefined;
    for (GENRES, 0..) |g, gi| names[gi] = g.name;
    break :blk names;
};

/// The with_genres id for a selection, respecting the media filter.
/// Index 0 ("All genres") and out-of-range both return 0 = no genre filter.
pub fn genreId(genre_idx: usize, is_tv: bool) u32 {
    if (genre_idx >= GENRES.len) return 0;
    return if (is_tv) GENRES[genre_idx].tv_id else GENRES[genre_idx].movie_id;
}

test "genreId maps movie vs tv ids and bounds" {
    try std.testing.expectEqual(@as(u32, 0), genreId(0, false)); // All genres
    try std.testing.expectEqual(@as(u32, 28), genreId(1, false)); // Action movie
    try std.testing.expectEqual(@as(u32, 10759), genreId(1, true)); // Action & Adventure TV
    try std.testing.expectEqual(@as(u32, 878), genreId(15, false)); // Sci-Fi movie
    try std.testing.expectEqual(@as(u32, 10765), genreId(15, true)); // Sci-Fi & Fantasy TV
    try std.testing.expectEqual(@as(u32, 0), genreId(999, false)); // out of range
}

/// Reverse lookup for AI-intent calls that arrive with a raw TMDB movie genre
/// id (e.g. 28 for Action): the GENRES index that drives the dropdown/state.
pub fn genreIndexForMovieId(movie_id: u32) ?usize {
    if (movie_id == 0) return null;
    for (GENRES, 0..) |g, gi| {
        if (g.movie_id == movie_id) return gi;
    }
    return null;
}

test "genreIndexForMovieId reverse lookup" {
    try std.testing.expectEqual(@as(?usize, 1), genreIndexForMovieId(28)); // Action
    try std.testing.expectEqual(@as(?usize, 15), genreIndexForMovieId(878)); // Sci-Fi
    try std.testing.expectEqual(@as(?usize, null), genreIndexForMovieId(0));
    try std.testing.expectEqual(@as(?usize, null), genreIndexForMovieId(424242));
}

// ══════════════════════════════════════════════════════════
// Discover sort + grid keyboard navigation
// ══════════════════════════════════════════════════════════

/// sort_by query fragment for /discover. tag: 0=popularity, 1=rating,
/// 2=newest. Rating carries a vote-count floor — without it TMDB returns
/// obscure 10.0-rated entries with 3 votes.
pub fn discoverSortParam(tag: u8, is_tv: bool) []const u8 {
    return switch (tag) {
        1 => "vote_average.desc&vote_count.gte=200",
        2 => if (is_tv) "first_air_date.desc" else "primary_release_date.desc",
        else => "popularity.desc",
    };
}

test "discoverSortParam maps tags and media type" {
    try std.testing.expectEqualStrings("popularity.desc", discoverSortParam(0, false));
    try std.testing.expectEqualStrings("vote_average.desc&vote_count.gte=200", discoverSortParam(1, true));
    try std.testing.expectEqualStrings("primary_release_date.desc", discoverSortParam(2, false));
    try std.testing.expectEqualStrings("first_air_date.desc", discoverSortParam(2, true));
    try std.testing.expectEqualStrings("popularity.desc", discoverSortParam(99, false)); // unknown → default
}

/// Arrow-key movement across a uniform grid: dx=±1 column, dy=±1 row.
/// Clamps to [0, total) — never wraps, never leaves the list.
pub fn moveFocus(current: usize, total: usize, cols: usize, dx: i32, dy: i32) usize {
    if (total == 0) return 0;
    const cur: i64 = @intCast(@min(current, total - 1));
    var idx: i64 = cur + dx + dy * @as(i64, @intCast(@max(cols, 1)));
    if (idx < 0) idx = 0;
    if (idx >= total) idx = @intCast(total - 1);
    return @intCast(idx);
}

test "moveFocus clamps at grid edges" {
    // 10 items, 4 cols: rows are [0..3][4..7][8..9]
    try std.testing.expectEqual(@as(usize, 1), moveFocus(0, 10, 4, 1, 0)); // right
    try std.testing.expectEqual(@as(usize, 0), moveFocus(0, 10, 4, -1, 0)); // left at start clamps
    try std.testing.expectEqual(@as(usize, 4), moveFocus(0, 10, 4, 0, 1)); // down one row
    try std.testing.expectEqual(@as(usize, 9), moveFocus(6, 10, 4, 0, 1)); // down past end clamps to last
    try std.testing.expectEqual(@as(usize, 0), moveFocus(2, 10, 4, 0, -1)); // up from row 0 clamps
    try std.testing.expectEqual(@as(usize, 9), moveFocus(42, 10, 4, 0, 0)); // stale index clamps
    try std.testing.expectEqual(@as(usize, 0), moveFocus(0, 0, 4, 1, 0)); // empty list
}

/// New scroll offset to bring `row` fully into view, or null if it already is.
pub fn scrollOffsetForRow(row: usize, row_h: f32, viewport_y: f32, viewport_h: f32) ?f32 {
    const top = @as(f32, @floatFromInt(row)) * row_h;
    const bottom = top + row_h;
    if (top < viewport_y) return top;
    if (viewport_h > 0 and bottom > viewport_y + viewport_h) return bottom - viewport_h;
    return null;
}

test "scrollOffsetForRow scrolls only when needed" {
    // 200px rows, viewport shows 600px starting at 400 (rows 2..4 visible).
    try std.testing.expectEqual(@as(?f32, null), scrollOffsetForRow(2, 200, 400, 600));
    try std.testing.expectEqual(@as(?f32, null), scrollOffsetForRow(4, 200, 400, 600));
    try std.testing.expectEqual(@as(?f32, 200), scrollOffsetForRow(1, 200, 400, 600)); // above → align top
    try std.testing.expectEqual(@as(?f32, 600), scrollOffsetForRow(5, 200, 400, 600)); // below → align bottom
}

/// Normalize a TMDB show title into a stream-search query token stream:
/// lowercase ASCII, punctuation stripped (apostrophes/colons/commas break
/// torrent-index keyword matching — releases are named "X.Men.97.S02E02" /
/// "X-Men 97 S02E02", never "X-Men '97"), whitespace collapsed, and a
/// trailing standalone 2- or 4-digit YEAR token dropped ("X-Men '97" →
/// "x-men", "Dexter (2006)" → "dexter"). Longer numbers stay — "The 100"
/// must remain "the 100". Hyphens are kept: indexers tokenize "x-men" fine
/// and stripping it would glue words together.
pub fn streamQueryTitle(title: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    var pending_space = false;
    for (title) |ch| {
        const c = switch (ch) {
            'A'...'Z' => ch + 32,
            'a'...'z', '0'...'9', '-' => ch,
            else => ' ', // punctuation & non-ASCII → word break
        };
        if (c == ' ') {
            pending_space = len > 0; // collapse runs; no leading space
            continue;
        }
        if (pending_space) {
            if (len >= buf.len) break;
            buf[len] = ' ';
            len += 1;
            pending_space = false;
        }
        if (len >= buf.len) break;
        buf[len] = c;
        len += 1;
    }
    // Drop a trailing standalone 2- or 4-digit year token ("97", "2006").
    if (std.mem.lastIndexOfScalar(u8, buf[0..len], ' ')) |sp| {
        const last = buf[sp + 1 .. len];
        if ((last.len == 2 or last.len == 4) and blk: {
            for (last) |d| {
                if (d < '0' or d > '9') break :blk false;
            }
            break :blk true;
        }) len = sp;
    }
    return buf[0..len];
}

test "streamQueryTitle strips punctuation + trailing year (X-Men '97 regression)" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("x-men", streamQueryTitle("X-Men '97", &b));
    try std.testing.expectEqualStrings("dexter", streamQueryTitle("Dexter (2006)", &b));
    try std.testing.expectEqualStrings("star trek strange new worlds", streamQueryTitle("Star Trek: Strange New Worlds", &b));
    try std.testing.expectEqualStrings("silo", streamQueryTitle("Silo", &b));
}

test "streamQueryTitle keeps non-year numbers and handles edge cases" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("the 100", streamQueryTitle("The 100", &b)); // 3 digits ≠ year
    try std.testing.expectEqualStrings("9-1-1", streamQueryTitle("9-1-1", &b)); // hyphens kept
    try std.testing.expectEqualStrings("", streamQueryTitle("", &b));
    // Non-ASCII bytes word-break (no transliteration) — imperfect for accented
    // titles but never crashes; indexers' per-token substring match usually
    // still hits ("gun" ⊂ "shogun").
    try std.testing.expectEqualStrings("sh gun", streamQueryTitle("Shōgun", &b));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("x-me", streamQueryTitle("X-Men '97", &tiny)); // buf cap, no overflow
}

/// Full stream-search query for a TV episode: normalized title + " sXXeYY".
/// REGRESSION (the "x-men S+2E+2" bug): Zig 0.16's std.fmt renders zero-fill
/// on SIGNED ints as a forced sign — `{d:0>2}` with `@as(i32, 2)` prints
/// "+2", not "02" — so queries built from the i32 season/episode searched
/// "S+2E+2" and matched nothing. Formatting here goes through unsigned casts;
/// non-positive inputs clamp to 0 rather than crashing on the cast.
pub fn episodeQuery(title: []const u8, season: i32, episode: i32, buf: []u8) []const u8 {
    var tbuf: [128]u8 = undefined;
    const t = streamQueryTitle(title, &tbuf);
    const s: u32 = if (season > 0) @intCast(season) else 0;
    const e: u32 = if (episode > 0) @intCast(episode) else 0;
    return std.fmt.bufPrint(buf, "{s} s{d:0>2}e{d:0>2}", .{ t, s, e }) catch t;
}

test "episodeQuery zero-pads via unsigned (x-men S+2E+2 regression)" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("x-men s02e02", episodeQuery("X-Men '97", 2, 2, &b));
    try std.testing.expectEqualStrings("silo s01e10", episodeQuery("Silo", 1, 10, &b));
    try std.testing.expectEqualStrings("the 100 s12e05", episodeQuery("The 100", 12, 5, &b));
    // Sanity: no '+' anywhere for single-digit numbers.
    try std.testing.expect(std.mem.indexOfScalar(u8, episodeQuery("Silo", 3, 4, &b), '+') == null);
    // Degenerate inputs clamp instead of crashing the @intCast.
    try std.testing.expectEqualStrings("silo s00e00", episodeQuery("Silo", -1, 0, &b));
}

/// True once playback has progressed enough to count the episode as watched
/// (2 minutes). Clicking ▶ no longer marks anything — the commit happens from
/// the player's time-pos stream (see player.zig → tmdb.commitPendingWatch).
/// NaN-safe: mpv reports NaN time-pos during loading/EOF edges.
pub fn tvWatchCommitDue(time_pos_s: f64) bool {
    if (!std.math.isFinite(time_pos_s)) return false;
    return time_pos_s >= 120.0;
}

test "tvWatchCommitDue: 2min threshold, NaN-safe" {
    try std.testing.expect(!tvWatchCommitDue(0));
    try std.testing.expect(!tvWatchCommitDue(119.9));
    try std.testing.expect(tvWatchCommitDue(120.0));
    try std.testing.expect(tvWatchCommitDue(4000));
    try std.testing.expect(!tvWatchCommitDue(std.math.nan(f64)));
    try std.testing.expect(!tvWatchCommitDue(-5));
}

/// Gate for the one-shot "Trending tonight" / Movies&TV initial fetch.
///
/// Regression guard for the first-start race: the fetch used to fire (and latch
/// its one-shot flags) the instant `api_key_len` flipped non-zero — which can be
/// BEFORE the detached config worker has fully published the key (torn read) and
/// before `config_loaded`. The single no-retry request then failed on the cold
/// path, both latches stayed set, and nothing re-fired → permanent "Nothing
/// loaded". Requiring `config_loaded` (loaded with .acquire, paired with the
/// worker's .release store) means the key bytes are fully visible before we arm.
/// Neutral-ship safe: with no key (`api_key_len == 0`) it returns false, so the
/// caller falls through to the graceful empty/no-key state instead of spinning.
pub fn shouldKickTrending(
    config_loaded: bool,
    api_key_len: usize,
    results_len: usize,
    is_loading: bool,
    already_kicked: bool,
) bool {
    return config_loaded and api_key_len > 0 and results_len == 0 and !is_loading and !already_kicked;
}

test "shouldKickTrending waits for config_loaded (first-start race)" {
    // The exact run-1 condition that must NOT fire early: key present but config
    // not yet published.
    try std.testing.expect(!shouldKickTrending(false, 32, 0, false, false));
}

test "shouldKickTrending neutral-ship: no key does not spin" {
    try std.testing.expect(!shouldKickTrending(true, 0, 0, false, false));
    try std.testing.expect(!shouldKickTrending(false, 0, 0, false, false));
}

test "shouldKickTrending fires once ready" {
    try std.testing.expect(shouldKickTrending(true, 32, 0, false, false));
}

test "shouldKickTrending does not refire after arm or success" {
    try std.testing.expect(!shouldKickTrending(true, 32, 0, false, true)); // already kicked
    try std.testing.expect(!shouldKickTrending(true, 32, 5, false, false)); // has results
    try std.testing.expect(!shouldKickTrending(true, 32, 0, true, false)); // already loading
}
