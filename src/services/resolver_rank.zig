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

    const raw = relevance + source_w + quality_bonus;
    const score = if (raw > seed_bonus) raw - seed_bonus else 0;

    return .{
        .match_pct = pct,
        .score = score,
        .match_words = match_words,
        .total_words = total_words,
    };
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
