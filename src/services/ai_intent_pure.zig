//! Pure intent classification / query normalization — no I/O, no state.
//! Kept standalone so zig test can reach it without crossing src/ module
//! boundaries. ai_intent.zig imports and delegates to these functions.

const std = @import("std");

pub const Intent = enum {
    specific_title,
    recommendation,
    browse_genre,
    search_title,
    contextual_nav,
    unknown,
};

// ── Number word lookup ──
const NumberWord = struct { word: []const u8, val: u8 };
const number_words = [_]NumberWord{
    .{ .word = "one", .val = 1 },     .{ .word = "two", .val = 2 },
    .{ .word = "three", .val = 3 },   .{ .word = "four", .val = 4 },
    .{ .word = "five", .val = 5 },    .{ .word = "six", .val = 6 },
    .{ .word = "seven", .val = 7 },   .{ .word = "eight", .val = 8 },
    .{ .word = "nine", .val = 9 },    .{ .word = "ten", .val = 10 },
    .{ .word = "eleven", .val = 11 }, .{ .word = "twelve", .val = 12 },
    .{ .word = "thirteen", .val = 13 }, .{ .word = "fourteen", .val = 14 },
    .{ .word = "fifteen", .val = 15 }, .{ .word = "sixteen", .val = 16 },
    .{ .word = "seventeen", .val = 17 }, .{ .word = "eighteen", .val = 18 },
    .{ .word = "nineteen", .val = 19 }, .{ .word = "twenty", .val = 20 },
    .{ .word = "first", .val = 1 },   .{ .word = "second", .val = 2 },
    .{ .word = "third", .val = 3 },   .{ .word = "fourth", .val = 4 },
    .{ .word = "fifth", .val = 5 },   .{ .word = "sixth", .val = 6 },
    .{ .word = "seventh", .val = 7 }, .{ .word = "eighth", .val = 8 },
    .{ .word = "ninth", .val = 9 },   .{ .word = "tenth", .val = 10 },
};

pub fn wordToNumber(word: []const u8) ?u8 {
    var lower: [32]u8 = undefined;
    const wl = @min(word.len, 31);
    for (0..wl) |i| lower[i] = std.ascii.toLower(word[i]);
    const lw = lower[0..wl];
    for (number_words) |nw| {
        if (std.mem.eql(u8, lw, nw.word)) return nw.val;
    }
    return null;
}

const rec_phrases = [_][]const u8{
    "some movies", "some shows", "some anime", "some series",
    "recommend", "suggest", "something to watch", "what should i watch",
    "what to watch", "anything good", "random movie", "random show",
    "movies to watch", "shows to watch", "popular movies", "trending",
    "top movies", "best movies", "best shows", "best anime",
    "new movies", "new shows", "latest movies", "whats popular",
    "what's popular", "what is trending", "whats trending",
    "play something", "put something on", "surprise me",
};

const GenreEntry = struct { keyword: []const u8, genre: []const u8 };
const genre_keywords = [_]GenreEntry{
    .{ .keyword = "sci-fi", .genre = "Science Fiction" },
    .{ .keyword = "scifi", .genre = "Science Fiction" },
    .{ .keyword = "science fiction", .genre = "Science Fiction" },
    .{ .keyword = "horror", .genre = "Horror" },
    .{ .keyword = "comedy", .genre = "Comedy" },
    .{ .keyword = "action", .genre = "Action" },
    .{ .keyword = "thriller", .genre = "Thriller" },
    .{ .keyword = "romance", .genre = "Romance" },
    .{ .keyword = "drama", .genre = "Drama" },
    .{ .keyword = "animation", .genre = "Animation" },
    .{ .keyword = "documentary", .genre = "Documentary" },
    .{ .keyword = "fantasy", .genre = "Fantasy" },
    .{ .keyword = "mystery", .genre = "Mystery" },
    .{ .keyword = "western", .genre = "Western" },
    .{ .keyword = "crime", .genre = "Crime" },
    .{ .keyword = "war", .genre = "War" },
};

const filler_prefixes = [_][]const u8{
    "can you play ", "could you play ", "i want to watch ",
    "i wanna watch ", "put on ", "let me watch ",
    "can you find ", "can you search ", "please play ",
    "please find ", "yo play ", "hey play ",
    "play me ", "show me ",
    // Bare verbs — order matters: longer prefixes first so "please play " wins over "play "
    "play ", "watch ", "find ", "search ", "stream ",
};

/// Contextual navigation refers to results already on screen:
/// "play the first one", "play that third item", "next", "previous".
/// Detected before title search so we don't try to resolve "first item" as a movie.
const nav_phrases = [_][]const u8{
    "the first ",  "the second ", "the third ",  "the fourth ",
    "the fifth ",  "the sixth ",  "the seventh ","the eighth ",
    "the ninth ",  "the tenth ",  "that first ", "that second ",
    "that third ", " first one",  " second one", " third one",
    " next one",   " previous one","next item",  "previous item",
    "first item",  "second item", "third item",
};

pub fn classifyIntent(input_lower: []const u8) Intent {
    // Contextual nav beats everything — ordinal references to existing results.
    for (nav_phrases) |phrase| {
        if (std.mem.indexOf(u8, input_lower, phrase) != null) return .contextual_nav;
    }
    for (rec_phrases) |phrase| {
        if (std.mem.indexOf(u8, input_lower, phrase) != null) return .recommendation;
    }
    // Generic "play some X" / "put some X on" → treat as mood/rec even when
    // X isn't a media word. Catches "play some jazz", "put some chill music on".
    const some_markers = [_][]const u8{ "play some ", "put some ", "gimme some ", "give me some " };
    for (some_markers) |sm| {
        if (std.mem.indexOf(u8, input_lower, sm) != null) return .recommendation;
    }
    for (genre_keywords) |gk| {
        if (std.mem.indexOf(u8, input_lower, gk.keyword) != null) {
            const has_media_word = std.mem.indexOf(u8, input_lower, "movies") != null or
                std.mem.indexOf(u8, input_lower, "shows") != null or
                std.mem.indexOf(u8, input_lower, "anime") != null or
                std.mem.indexOf(u8, input_lower, "series") != null or
                std.mem.indexOf(u8, input_lower, "films") != null;
            if (has_media_word) return .browse_genre;
        }
    }
    return .specific_title;
}

pub fn normalizeQuery(raw: []const u8, buf: *[256]u8) []const u8 {
    if (raw.len == 0) return raw;

    var input = raw;
    var lower_copy: [512]u8 = undefined;
    const clen = @min(raw.len, 511);
    for (0..clen) |i| lower_copy[i] = std.ascii.toLower(raw[i]);
    const lc = lower_copy[0..clen];

    for (filler_prefixes) |fp| {
        if (std.mem.startsWith(u8, lc, fp)) {
            input = raw[fp.len..];
            break;
        }
    }

    var work: [256]u8 = undefined;
    const wlen = @min(input.len, 255);
    for (0..wlen) |i| work[i] = std.ascii.toLower(input[i]);
    const src = work[0..wlen];

    if (std.mem.indexOf(u8, src, "season ")) |season_pos| {
        const prefix = std.mem.trim(u8, input[0..season_pos], " ");
        var out: usize = 0;

        for (prefix) |ch| {
            if (out < 255) { buf[out] = ch; out += 1; }
        }
        if (out > 0 and buf[out - 1] != ' ') { buf[out] = ' '; out += 1; }

        const after_season = src[season_pos + 7..];
        var season_num: ?u8 = null;
        var consumed: usize = 0;

        if (after_season.len > 0 and std.ascii.isDigit(after_season[0])) {
            var end: usize = 0;
            var val: u8 = 0;
            while (end < after_season.len and std.ascii.isDigit(after_season[end])) : (end += 1) {
                val = val * 10 + (after_season[end] - '0');
            }
            season_num = val;
            consumed = end;
        } else {
            var end: usize = 0;
            while (end < after_season.len and after_season[end] != ' ') end += 1;
            if (end > 0) {
                season_num = wordToNumber(after_season[0..end]);
                if (season_num != null) consumed = end;
            }
        }

        if (season_num) |sn| {
            buf[out] = 'S'; out += 1;
            if (sn < 10) { buf[out] = '0'; out += 1; }
            const sn_str = std.fmt.bufPrint(buf[out..], "{d}", .{sn}) catch "";
            out += sn_str.len;

            var ep_rest = after_season[consumed..];
            while (ep_rest.len > 0 and ep_rest[0] == ' ') ep_rest = ep_rest[1..];

            const ep_prefixes = [_][]const u8{ "episode ", "ep " };
            for (ep_prefixes) |ep_prefix| {
                if (std.mem.startsWith(u8, ep_rest, ep_prefix)) {
                    const after_ep = ep_rest[ep_prefix.len..];
                    var ep_num: ?u8 = null;

                    if (after_ep.len > 0 and std.ascii.isDigit(after_ep[0])) {
                        var end2: usize = 0;
                        var val2: u8 = 0;
                        while (end2 < after_ep.len and std.ascii.isDigit(after_ep[end2])) : (end2 += 1) {
                            val2 = val2 * 10 + (after_ep[end2] - '0');
                        }
                        ep_num = val2;
                    } else {
                        var end2: usize = 0;
                        while (end2 < after_ep.len and after_ep[end2] != ' ') end2 += 1;
                        if (end2 > 0) ep_num = wordToNumber(after_ep[0..end2]);
                    }

                    if (ep_num) |en| {
                        buf[out] = 'E'; out += 1;
                        if (en < 10) { buf[out] = '0'; out += 1; }
                        const en_str = std.fmt.bufPrint(buf[out..], "{d}", .{en}) catch "";
                        out += en_str.len;
                    }
                    break;
                }
            }

            return buf[0..out];
        }
    }

    const trimmed = std.mem.trim(u8, input, " ");
    const tlen = @min(trimmed.len, 255);
    @memcpy(buf[0..tlen], trimmed[0..tlen]);
    return buf[0..tlen];
}

/// Parse a contextual-nav utterance into a zero-based index into
/// the on-screen results list. `current` is the currently-highlighted
/// index (used for "next" / "previous" relative nav). Returns null if
/// no ordinal/direction is recognizable.
pub fn parseNavIndex(input_lower: []const u8, current: usize) ?usize {
    // Sequential: "next"/"prev" → relative to current
    if (std.mem.indexOf(u8, input_lower, "next") != null) return current + 1;
    if (std.mem.indexOf(u8, input_lower, "previous") != null or
        std.mem.indexOf(u8, input_lower, "prev ") != null)
    {
        return if (current == 0) 0 else current - 1;
    }

    // Ordinal: scan tokens for a recognized number-word or digit
    var i: usize = 0;
    while (i < input_lower.len) {
        while (i < input_lower.len and !std.ascii.isAlphanumeric(input_lower[i])) i += 1;
        const start = i;
        while (i < input_lower.len and std.ascii.isAlphanumeric(input_lower[i])) i += 1;
        if (i == start) break;
        const tok = input_lower[start..i];

        // Try word ordinal ("first" → 1, "second" → 2, …)
        if (wordToNumber(tok)) |n| {
            if (n >= 1) return n - 1;
        }
        // Try digit literal ("1", "3") but skip if embedded in S01E01-style tokens
        if (tok.len <= 2) {
            var is_num = true;
            for (tok) |ch| if (!std.ascii.isDigit(ch)) { is_num = false; break; };
            if (is_num) {
                const v = std.fmt.parseInt(u8, tok, 10) catch continue;
                if (v >= 1) return v - 1;
            }
        }
    }
    return null;
}

pub fn isErrorResult(name: []const u8) bool {
    const error_markers = [_][]const u8{
        "api key error", "Jackett:", "jackett:", "API key",
        "error!", "Error!", "ERROR", "configuration",
        "Right-click this", "right-click this",
        "indexer error", "Indexer Error",
    };
    for (error_markers) |marker| {
        if (std.mem.indexOf(u8, name, marker) != null) return true;
    }
    return false;
}

pub fn findGenre(input_lower: []const u8) ?[]const u8 {
    for (genre_keywords) |gk| {
        if (std.mem.indexOf(u8, input_lower, gk.keyword) != null) return gk.genre;
    }
    return null;
}

// ══════════════════════════════════════════════════════════
//  Tests
// ══════════════════════════════════════════════════════════

test "classifyIntent: recommendation phrases" {
    try std.testing.expectEqual(Intent.recommendation, classifyIntent("recommend something"));
    try std.testing.expectEqual(Intent.recommendation, classifyIntent("play some movies"));
    try std.testing.expectEqual(Intent.recommendation, classifyIntent("what should i watch tonight"));
    try std.testing.expectEqual(Intent.recommendation, classifyIntent("surprise me"));
    try std.testing.expectEqual(Intent.recommendation, classifyIntent("whats trending"));
    // "play some X" for non-media X (mood / genre) should also classify as rec
    try std.testing.expectEqual(Intent.recommendation, classifyIntent("play some jazz"));
    try std.testing.expectEqual(Intent.recommendation, classifyIntent("put some chill music on"));
}

test "classifyIntent: contextual nav — ordinal references" {
    try std.testing.expectEqual(Intent.contextual_nav, classifyIntent("play the first item"));
    try std.testing.expectEqual(Intent.contextual_nav, classifyIntent("play the third one"));
    try std.testing.expectEqual(Intent.contextual_nav, classifyIntent("next item"));
    try std.testing.expectEqual(Intent.contextual_nav, classifyIntent("play that second one"));
}

test "classifyIntent: genre browse requires media word" {
    try std.testing.expectEqual(Intent.browse_genre, classifyIntent("find sci-fi movies"));
    try std.testing.expectEqual(Intent.browse_genre, classifyIntent("show me horror films"));
    try std.testing.expectEqual(Intent.browse_genre, classifyIntent("comedy shows"));
    // No media word → genre alone should NOT classify as browse_genre
    try std.testing.expectEqual(Intent.specific_title, classifyIntent("play horror 2023"));
}

test "classifyIntent: specific title fallback" {
    try std.testing.expectEqual(Intent.specific_title, classifyIntent("play iron man 3"));
    try std.testing.expectEqual(Intent.specific_title, classifyIntent("the boys s01e01"));
    try std.testing.expectEqual(Intent.specific_title, classifyIntent("inception"));
}

test "normalizeQuery: strips filler prefixes" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("iron man", normalizeQuery("can you play iron man", &buf));
    try std.testing.expectEqualStrings("the boys", normalizeQuery("i wanna watch the boys", &buf));
    try std.testing.expectEqualStrings("inception", normalizeQuery("please play inception", &buf));
    // Bare verb prefixes — previously not stripped, caused garbage searches
    try std.testing.expectEqualStrings("the boys s01e01", normalizeQuery("play the boys s01e01", &buf));
    try std.testing.expectEqualStrings("inception", normalizeQuery("watch inception", &buf));
    try std.testing.expectEqualStrings("iron man", normalizeQuery("find iron man", &buf));
}

test "normalizeQuery: word-number season episode → SxxExx" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("the boys S01E01", normalizeQuery("the boys season one episode one", &buf));
    try std.testing.expectEqualStrings("breaking bad S05E14", normalizeQuery("breaking bad season five episode fourteen", &buf));
    try std.testing.expectEqualStrings("show S02", normalizeQuery("show season two", &buf));
}

test "normalizeQuery: digit season/episode preserved" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("the boys S01E01", normalizeQuery("the boys season 1 episode 1", &buf));
    try std.testing.expectEqualStrings("show S12E07", normalizeQuery("show season 12 ep 7", &buf));
}

test "normalizeQuery: empty and trivial inputs" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", normalizeQuery("", &buf));
    try std.testing.expectEqualStrings("hello", normalizeQuery("hello", &buf));
    try std.testing.expectEqualStrings("hello world", normalizeQuery("  hello world  ", &buf));
}

test "isErrorResult: flags indexer errors" {
    try std.testing.expect(isErrorResult("Jackett: API key error"));
    try std.testing.expect(isErrorResult("Indexer Error: timeout"));
    try std.testing.expect(isErrorResult("Right-click this row to configure"));
    try std.testing.expect(isErrorResult("check your configuration"));
}

test "isErrorResult: real content passes" {
    try std.testing.expect(!isErrorResult("The Boys S01E01 1080p"));
    try std.testing.expect(!isErrorResult("Iron Man 3 (2013)"));
    try std.testing.expect(!isErrorResult("Inception.2010.BluRay"));
}

test "findGenre: matches keyword variants" {
    try std.testing.expectEqualStrings("Science Fiction", findGenre("find sci-fi movies").?);
    try std.testing.expectEqualStrings("Science Fiction", findGenre("scifi stuff").?);
    try std.testing.expectEqualStrings("Horror", findGenre("i like horror").?);
    try std.testing.expectEqualStrings("Action", findGenre("action films tonight").?);
    try std.testing.expect(findGenre("just random text here") == null);
}

test "parseNavIndex: ordinal words" {
    try std.testing.expectEqual(@as(?usize, 0), parseNavIndex("play the first item", 0));
    try std.testing.expectEqual(@as(?usize, 2), parseNavIndex("play the third one", 0));
    try std.testing.expectEqual(@as(?usize, 1), parseNavIndex("play that second one", 0));
}

test "parseNavIndex: next/previous relative to current" {
    try std.testing.expectEqual(@as(?usize, 3), parseNavIndex("next item", 2));
    try std.testing.expectEqual(@as(?usize, 1), parseNavIndex("previous one", 2));
    try std.testing.expectEqual(@as(?usize, 0), parseNavIndex("previous item", 0)); // clamps at 0
}

test "parseNavIndex: digit literals" {
    try std.testing.expectEqual(@as(?usize, 2), parseNavIndex("play 3", 0));
    try std.testing.expectEqual(@as(?usize, 0), parseNavIndex("play number 1", 0));
}

test "wordToNumber: cardinal + ordinal" {
    try std.testing.expectEqual(@as(?u8, 1), wordToNumber("one"));
    try std.testing.expectEqual(@as(?u8, 1), wordToNumber("first"));
    try std.testing.expectEqual(@as(?u8, 14), wordToNumber("fourteen"));
    try std.testing.expectEqual(@as(?u8, 10), wordToNumber("tenth"));
    try std.testing.expectEqual(@as(?u8, 20), wordToNumber("TWENTY"));
    try std.testing.expect(wordToNumber("notanumber") == null);
    try std.testing.expect(wordToNumber("") == null);
}
