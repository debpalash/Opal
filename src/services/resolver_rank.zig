//! Pure ranking / scoring extracted from resolver.zig.
//! No dvui, no state, no C — so zig test can reach it without
//! compiling the whole app. resolver.zig can later delegate to
//! these functions instead of keeping its own copy.

const std = @import("std");

pub const SourceType = enum {
    jellyfin,
    stremio,
    torrent,
    anime,
    youtube,
};

/// Minimal fixture item. Mirrors resolver.ResolvedItem's scoring-relevant
/// fields. Full ResolvedItem has name/url buffers that don't affect rank.
pub const Item = struct {
    name: []const u8,
    source: SourceType,
    quality: u8 = 3, // 1=480, 2=720, 3=1080, 4=4K
    seeds: u16 = 0,
};

pub const MatchInfo = struct {
    match_pct: u8,
    score: u32,
    match_words: u32,
    total_words: u32,
};

const stop_words = [_][]const u8{
    "the", "a", "an", "of", "in", "on", "to", "and",
    "for", "is", "it", "my", "me", "at", "by",
};

fn isStopWord(word: []const u8) bool {
    for (stop_words) |sw| if (std.mem.eql(u8, word, sw)) return true;
    return false;
}

/// Compute match % + composite sort score. Lower score = better.
/// Byte-for-byte equivalent to resolver.computeMatch scoring (as of 2026-04-19).
pub fn computeMatch(item: Item, query: []const u8, intent: []const u8) MatchInfo {
    var lower_name: [256]u8 = undefined;
    const nlen = @min(item.name.len, 255);
    for (0..nlen) |i| lower_name[i] = std.ascii.toLower(item.name[i]);

    var lower_query: [256]u8 = undefined;
    const ql = @min(query.len, 255);
    for (0..ql) |i| lower_query[i] = std.ascii.toLower(query[i]);

    var match_words: u32 = 0;
    var total_words: u32 = 0;

    var qi: usize = 0;
    while (qi < ql) {
        while (qi < ql and lower_query[qi] == ' ') qi += 1;
        if (qi >= ql) break;
        const word_start = qi;
        while (qi < ql and lower_query[qi] != ' ') qi += 1;
        const word = lower_query[word_start..qi];
        if (word.len == 0) continue;
        if (word.len == 1 and !std.ascii.isDigit(word[0])) continue;
        if (isStopWord(word)) continue;
        total_words += 1;

        var is_numeric = true;
        for (word) |ch| if (!std.ascii.isDigit(ch)) { is_numeric = false; break; };

        const hay = lower_name[0..nlen];
        if (is_numeric) {
            var hi: usize = 0;
            while (std.mem.indexOfPos(u8, hay, hi, word)) |p| {
                const before_ok = (p == 0) or !std.ascii.isDigit(hay[p - 1]);
                const after_idx = p + word.len;
                const after_ok = (after_idx >= hay.len) or !std.ascii.isDigit(hay[after_idx]);
                if (before_ok and after_ok) { match_words += 1; break; }
                hi = p + 1;
            }
        } else {
            if (std.mem.indexOf(u8, hay, word) != null) match_words += 1;
        }
    }

    const pct: u8 = if (total_words > 0)
        @intCast((match_words * 100) / total_words)
    else 50;

    if (match_words == 0) return .{
        .match_pct = 0, .score = 9999,
        .match_words = 0, .total_words = total_words,
    };

    const relevance: u32 = 100 - @as(u32, pct);
    const is_movie_or_show = std.mem.eql(u8, intent, "movie") or std.mem.eql(u8, intent, "show");

    var source_w: u32 = switch (item.source) {
        .jellyfin => 0, .stremio => 5, .torrent => 8, .anime => 12, .youtube => 20,
    };
    if (is_movie_or_show and item.source == .youtube) source_w += 1000;

    const quality_bonus: u32 = switch (item.quality) {
        4 => 2, 3 => 0, 2 => 5, 1 => 10, else => 15,
    };

    // Seed bonus is bounded so a well-seeded torrent can NEVER beat an
    // equal-match jellyfin item. Biggest gap it needs to preserve is
    // source_w(torrent=8) − source_w(jellyfin=0) = 8. Capping the bonus at 7
    // keeps inter-torrent ordering (high-seed vs low-seed still differs)
    // while preventing cross-source leapfrogging.
    const seed_bonus: u32 = if (item.seeds > 100) 7
        else if (item.seeds > 50) 6
        else if (item.seeds > 20) 5
        else if (item.seeds > 10) 4
        else if (item.seeds > 5) 3
        else if (item.seeds > 0) 1
        else 0;

    const junk = junkTitlePenalty(lower_name[0..nlen], lower_query[0..ql]);
    const raw = relevance + source_w + quality_bonus + junk;
    const score = if (raw > seed_bonus) raw - seed_bonus else 0;

    return .{
        .match_pct = pct,
        .score = score,
        .match_words = match_words,
        .total_words = total_words,
    };
}

// ══════════════════════════════════════════════════════════
// Derivative-content demotion
// ══════════════════════════════════════════════════════════

/// Title fragments that signal a DERIVATIVE of the work rather than the work
/// itself — lyric videos, compilations, isolated scenes, reactions. These
/// flooded "play iron man" with 100%-match YouTube junk (the Black Sabbath
/// lyrics video outranked everything). Markers are matched against the
/// lowercased title; a marker the QUERY itself contains is skipped, so
/// "iron man lyrics" still ranks lyric videos normally.
const junk_markers = [_][]const u8{
    "lyric",       "karaoke",     "compilation",       "movie clip",
    "(clip",       " clip)",      "(scene",            " scene)",
    "trailer",     "teaser",      "reaction",          "recap",
    "explained",   "behind the scenes",                "soundtrack",
    "suit up",     "best of",     "top 10",            "top 20",
    "8d audio",    "fan made",    "fanmade",           "(cover",
    "full ost",    " clip",       "film review",       "& review",
    "fact & ",     "action scenes",                    "final battle",
};

/// Additive score penalty (lower score = better rank, so junk sinks well
/// below any clean title regardless of source). 0 when the query asked for
/// that content class itself.
pub fn junkTitlePenalty(lower_name: []const u8, lower_query: []const u8) u32 {
    for (junk_markers) |m| {
        const bare = std.mem.trim(u8, m, " ()");
        if (std.mem.indexOf(u8, lower_query, bare) != null) continue; // asked for it
        if (std.mem.indexOf(u8, lower_name, m) != null) return 80;
    }
    return 0;
}

test "junkTitlePenalty demotes derivative titles (play iron man regression)" {
    // The exact top results that outranked everything for "play iron man".
    try std.testing.expect(junkTitlePenalty("black sabbath - iron man (lyrics)", "iron man") > 0);
    try std.testing.expect(junkTitlePenalty("tony stark's best iron man suit ups | mcu compilation (4k)", "iron man") > 0);
    try std.testing.expect(junkTitlePenalty("iron man nanotechnology suit up | avengers | official clip", "iron man") > 0);
    try std.testing.expect(junkTitlePenalty("tony stark builds miniature arc reactor (scene) - movie clip hd", "iron man") > 0);
    // Round 2 — the exact titles that won "play iron man three/movie":
    try std.testing.expect(junkTitlePenalty("iron man suits save tony and rhodey | iron man 3 | official clip", "iron man three") > 0);
    try std.testing.expect(junkTitlePenalty("iron man full movie (2008) | robert downey jr | fact & review", "iron man movie") > 0);
    try std.testing.expect(junkTitlePenalty("iron man 3 movie (2013) action/sci-fi | film review & facts", "iron man three") > 0);
    try std.testing.expect(junkTitlePenalty("iron man all action scenes in hindi avengers iron man movies", "iron man movie") > 0);
    // Clean titles pass untouched.
    try std.testing.expect(junkTitlePenalty("iron man (2008) 1080p bluray", "iron man") == 0);
    try std.testing.expect(junkTitlePenalty("iron man", "iron man") == 0);
    try std.testing.expect(junkTitlePenalty("iron.man.three.2013.1080p.bluray.avc", "iron man three") == 0);
    // Asking for the derivative keeps it rankable.
    try std.testing.expect(junkTitlePenalty("black sabbath - iron man (lyrics)", "iron man lyrics") == 0);
    try std.testing.expect(junkTitlePenalty("dune official trailer", "dune trailer") == 0);
    // "clip"/"scene" only match with delimiters — not inside words.
    try std.testing.expect(junkTitlePenalty("total eclipse of the heart", "eclipse") == 0);
    try std.testing.expect(junkTitlePenalty("the obscene tape", "tape") == 0);
}

pub const Ranked = struct {
    index: usize,
    info: MatchInfo,
};

/// Rank items. Writes sorted indices (best first) into `out`.
/// Returns the slice of `out` actually populated (skips zero-match items).
pub fn rankAll(items: []const Item, query: []const u8, intent: []const u8, out: []Ranked) []Ranked {
    var n: usize = 0;
    for (items, 0..) |it, i| {
        const mi = computeMatch(it, query, intent);
        if (mi.match_pct == 0) continue;
        if (n >= out.len) break;
        out[n] = .{ .index = i, .info = mi };
        n += 1;
    }
    std.mem.sort(Ranked, out[0..n], {}, struct {
        fn lt(_: void, a: Ranked, b: Ranked) bool {
            return a.info.score < b.info.score;
        }
    }.lt);
    return out[0..n];
}

// ══════════════════════════════════════════════════════════
//  Tests
// ══════════════════════════════════════════════════════════

test "computeMatch: exact title on jellyfin ranks top" {
    const items = [_]Item{
        .{ .name = "The Boys S01E01 1080p",         .source = .jellyfin, .quality = 3, .seeds = 0 },
        .{ .name = "The Boys Parody YouTube Clip",  .source = .youtube,  .quality = 2, .seeds = 0 },
        .{ .name = "The Boys S01E01 720p WEB",      .source = .torrent,  .quality = 2, .seeds = 150 },
    };
    var buf: [8]Ranked = undefined;
    const ranked = rankAll(&items, "the boys s01e01", "show", &buf);
    try std.testing.expect(ranked.len == 3);
    try std.testing.expectEqual(@as(usize, 0), ranked[0].index);
}

test "computeMatch: youtube penalized for show intent" {
    const items = [_]Item{
        .{ .name = "Inception 2010 YouTube Trailer HD", .source = .youtube, .quality = 3, .seeds = 0 },
        .{ .name = "Inception 2010 BluRay 1080p",       .source = .torrent, .quality = 3, .seeds = 200 },
    };
    var buf: [4]Ranked = undefined;
    const ranked = rankAll(&items, "inception 2010", "movie", &buf);
    try std.testing.expect(ranked.len == 2);
    try std.testing.expectEqual(@as(usize, 1), ranked[0].index); // torrent beats penalized yt
}

test "computeMatch: numeric tokens word-bounded" {
    // "2" must not match "2008" / "2022"
    const items = [_]Item{
        .{ .name = "Iron Man 2008",     .source = .torrent, .quality = 3, .seeds = 100 },
        .{ .name = "Iron Man 2 (2010)", .source = .torrent, .quality = 3, .seeds = 50 },
    };
    var buf: [4]Ranked = undefined;
    const ranked = rankAll(&items, "iron man 2", "movie", &buf);
    // Iron Man 2008: matches "iron", "man" but NOT "2" (inside 2008)
    // Iron Man 2:    matches all three tokens → higher match_pct → lower score
    try std.testing.expectEqual(@as(usize, 1), ranked[0].index);
    try std.testing.expect(ranked[0].info.match_pct == 100);
}

test "computeMatch: genre-only query yields zero matches (garbage diagnostic)" {
    // User types "jazz" → resolver searches torrents, gets random stuff back.
    // This test documents the failure: no item in a generic result set will
    // have "jazz" as a useful title token, match_pct collapses.
    const items = [_]Item{
        .{ .name = "The Boys S01E01",       .source = .jellyfin, .quality = 3 },
        .{ .name = "Inception 2010 BluRay", .source = .torrent,  .quality = 3, .seeds = 100 },
    };
    var buf: [4]Ranked = undefined;
    const ranked = rankAll(&items, "jazz", "auto", &buf);
    try std.testing.expectEqual(@as(usize, 0), ranked.len); // all filtered
}

test "computeMatch: stop words stripped" {
    const items = [_]Item{
        .{ .name = "The Matrix",         .source = .jellyfin, .quality = 3 },
        .{ .name = "Completely Unrelated", .source = .torrent, .quality = 3, .seeds = 0 },
    };
    var buf: [4]Ranked = undefined;
    const ranked = rankAll(&items, "the matrix", "movie", &buf);
    try std.testing.expectEqual(@as(usize, 1), ranked.len); // only matrix survives
    try std.testing.expect(ranked[0].info.match_pct == 100);
}

test "computeMatch: high-seed torrent beats low-seed torrent" {
    const items = [_]Item{
        .{ .name = "The Boys S01E01 1080p", .source = .torrent, .quality = 3, .seeds = 5 },
        .{ .name = "The Boys S01E01 1080p", .source = .torrent, .quality = 3, .seeds = 200 },
    };
    var buf: [4]Ranked = undefined;
    const ranked = rankAll(&items, "the boys s01e01", "show", &buf);
    try std.testing.expectEqual(@as(usize, 1), ranked[0].index);
}

test "computeMatch: quality preference — 1080p beats 480p at tie" {
    const items = [_]Item{
        .{ .name = "Inception 1080p", .source = .torrent, .quality = 3, .seeds = 100 },
        .{ .name = "Inception 480p",  .source = .torrent, .quality = 1, .seeds = 100 },
    };
    var buf: [4]Ranked = undefined;
    const ranked = rankAll(&items, "inception", "movie", &buf);
    try std.testing.expectEqual(@as(usize, 0), ranked[0].index);
}

// ── parseSxxEyy pure tests ──
// Mirrors the parseSxxEyy function in resolver.zig so it can be unit-tested
// without pulling in the full app (state, io_global, etc.).

pub fn parseSxxEyy(query: []const u8, out_season: *i32, out_episode: *i32) void {
    out_season.* = 0;
    out_episode.* = 0;
    var i: usize = 0;
    while (i < query.len) : (i += 1) {
        if (std.ascii.toLower(query[i]) != 's') continue;
        var se = i + 1;
        while (se < query.len and std.ascii.isDigit(query[se])) se += 1;
        if (se == i + 1) continue;
        if (se >= query.len or std.ascii.toLower(query[se]) != 'e') continue;
        var ee = se + 1;
        while (ee < query.len and std.ascii.isDigit(query[ee])) ee += 1;
        if (ee == se + 1) continue;
        out_season.* = std.fmt.parseInt(i32, query[i + 1 .. se], 10) catch continue;
        out_episode.* = std.fmt.parseInt(i32, query[se + 1 .. ee], 10) catch continue;
        return;
    }
}

test "parseSxxEyy: standard S01E05 format" {
    var s: i32 = 0;
    var e: i32 = 0;
    parseSxxEyy("from s01e05", &s, &e);
    try std.testing.expectEqual(@as(i32, 1), s);
    try std.testing.expectEqual(@as(i32, 5), e);
}

test "parseSxxEyy: uppercase S03E12" {
    var s: i32 = 0;
    var e: i32 = 0;
    parseSxxEyy("FROM S03E12", &s, &e);
    try std.testing.expectEqual(@as(i32, 3), s);
    try std.testing.expectEqual(@as(i32, 12), e);
}

test "parseSxxEyy: no match returns zeros" {
    var s: i32 = 0;
    var e: i32 = 0;
    parseSxxEyy("inception 2010", &s, &e);
    try std.testing.expectEqual(@as(i32, 0), s);
    try std.testing.expectEqual(@as(i32, 0), e);
}

// ── Smart episode play: confident auto-pick ──

/// Minimal projection of a resolver result for the auto-pick decision, so
/// this stays pure (no resolver/state import).
pub const PickCand = struct {
    playable: bool, // stremio/torrent with a non-empty url
    needs_seeds: bool, // plain torrent-index magnet (stremio streams don't)
    match_pct: u8,
    seeds: u16,
};

pub const PICK_MIN_MATCH: u8 = 60;
pub const PICK_MIN_SEEDS: u16 = 2;

/// First confident auto-playable candidate, or null → show the source picker
/// instead. `cands` must already be in rank order (resolver.results is kept
/// insertion-sorted by score). Confidence: a playable url whose title matches
/// the query well; plain torrents additionally need a couple of seeds so we
/// never auto-play a dead magnet.
pub fn pickBest(cands: []const PickCand) ?usize {
    for (cands, 0..) |c, i| {
        if (!c.playable) continue;
        if (c.match_pct < PICK_MIN_MATCH) continue;
        if (c.needs_seeds and c.seeds < PICK_MIN_SEEDS) continue;
        return i;
    }
    return null;
}

test "pickBest: first confident hit wins; dead magnets and weak matches skipped" {
    const cands = [_]PickCand{
        .{ .playable = false, .needs_seeds = false, .match_pct = 100, .seeds = 0 }, // tmdb card — not a stream
        .{ .playable = true, .needs_seeds = true, .match_pct = 95, .seeds = 0 }, // dead magnet
        .{ .playable = true, .needs_seeds = true, .match_pct = 40, .seeds = 900 }, // wrong title
        .{ .playable = true, .needs_seeds = true, .match_pct = 88, .seeds = 120 }, // ← this one
        .{ .playable = true, .needs_seeds = false, .match_pct = 90, .seeds = 0 },
    };
    try std.testing.expectEqual(@as(?usize, 3), pickBest(&cands));
}

test "pickBest: stremio streams need no seeds; empty/junk lists yield null" {
    const stremio_only = [_]PickCand{
        .{ .playable = true, .needs_seeds = false, .match_pct = 75, .seeds = 0 },
    };
    try std.testing.expectEqual(@as(?usize, 0), pickBest(&stremio_only));

    const junk = [_]PickCand{
        .{ .playable = true, .needs_seeds = true, .match_pct = 59, .seeds = 50 },
        .{ .playable = false, .needs_seeds = false, .match_pct = 100, .seeds = 0 },
    };
    try std.testing.expectEqual(@as(?usize, null), pickBest(&junk));
    try std.testing.expectEqual(@as(?usize, null), pickBest(&.{}));
}
