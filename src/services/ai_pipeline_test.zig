//! End-to-end pipeline test (pure, no network, no LLM).
//!
//! Simulates the flow a user query takes through the AI chat → search →
//! player path and prints a human-readable reasoning trace so we can see
//! exactly where "garbage" decisions originate.
//!
//! Stages:
//!   1. classifyIntent      → Intent enum
//!   2. normalizeQuery      → cleaned search string
//!   3. rankAll (fixture)   → ordered result list
//!   4. "playItem(top)"     → asserts top candidate matches expectation
//!
//! Backends are faked with canned ResolvedItem fixtures. That isolates
//! the classifier / normalizer / scorer from network + LLM noise.

const std = @import("std");
const intent = @import("ai_intent_pure.zig");
const rank = @import("resolver_rank.zig");

const Item = rank.Item;

// ══════════════════════════════════════════════════════════
// Fixture: a canned mixed-source result set, roughly what
// resolver.resolve() would produce for a typical media query.
// ══════════════════════════════════════════════════════════
const library = [_]Item{
    // Jellyfin (local library)
    .{ .name = "The Boys S01E01 The Name of the Game",  .source = .jellyfin, .quality = 3 },
    .{ .name = "The Boys S01E02 Cherry",                .source = .jellyfin, .quality = 3 },
    .{ .name = "Inception (2010)",                      .source = .jellyfin, .quality = 3 },
    .{ .name = "Iron Man (2008)",                       .source = .jellyfin, .quality = 3 },
    .{ .name = "Iron Man 2 (2010)",                     .source = .jellyfin, .quality = 3 },
    .{ .name = "Iron Man 3 (2013)",                     .source = .jellyfin, .quality = 3 },
    .{ .name = "Breaking Bad S05E14 Ozymandias",        .source = .jellyfin, .quality = 3 },

    // Torrent (1337x, YTS, nova)
    .{ .name = "The.Boys.S01E01.1080p.WEB.H264",        .source = .torrent, .quality = 3, .seeds = 320 },
    .{ .name = "Inception 2010 BluRay 1080p x265",      .source = .torrent, .quality = 3, .seeds = 540 },
    .{ .name = "Iron Man 3 2013 1080p BluRay",          .source = .torrent, .quality = 3, .seeds = 210 },
    .{ .name = "Random Jazz Music Collection 320kbps",  .source = .torrent, .quality = 0, .seeds = 15 },

    // YouTube (trailers, clips, playlists — noisy)
    .{ .name = "The Boys Season 1 Official Trailer",    .source = .youtube, .quality = 2, .seeds = 0 },
    .{ .name = "Inception Official Trailer HD",         .source = .youtube, .quality = 2, .seeds = 0 },
    .{ .name = "Smooth Jazz Study Music 3 Hour Mix",    .source = .youtube, .quality = 3, .seeds = 0 },
    .{ .name = "Best Jazz Classics Playlist",           .source = .youtube, .quality = 3, .seeds = 0 },

    // Anime
    .{ .name = "Attack on Titan S04E01 1080p",          .source = .anime, .quality = 3 },
};

// Intent keyword → expected search routing for tests below
const Case = struct {
    user_input: []const u8,
    expected_intent: intent.Intent,
    expected_norm: []const u8,
    /// If null, query is expected NOT to be a resolver search (genre/recommendation).
    /// If set, expected_top_name MUST appear in library[].name for the top-ranked item.
    expected_top_name: ?[]const u8,
    search_intent_tag: []const u8, // "movie" | "show" | "auto"
    note: []const u8,
};

const cases = [_]Case{
    .{
        .user_input       = "play the boys s01e01",
        .expected_intent  = .specific_title,
        .expected_norm    = "the boys s01e01",
        .expected_top_name = "The Boys S01E01 The Name of the Game",
        .search_intent_tag = "show",
        .note = "Fixed: 'play ' filler stripped + seed_bonus cap keeps jellyfin on top.",
    },
    .{
        .user_input       = "can you play iron man 3",
        .expected_intent  = .specific_title,
        .expected_norm    = "iron man 3",
        .expected_top_name = "Iron Man 3 (2013)",
        .search_intent_tag = "movie",
        .note = "Numeric sequel must not get confused with Iron Man 2008 / 2010.",
    },
    .{
        .user_input       = "i wanna watch inception",
        .expected_intent  = .specific_title,
        .expected_norm    = "inception",
        .expected_top_name = "Inception (2010)",
        .search_intent_tag = "movie",
        .note = "Filler prefix stripped. Jellyfin hit beats yt trailer (movie intent penalizes yt).",
    },
    .{
        .user_input       = "breaking bad season five episode fourteen",
        .expected_intent  = .specific_title,
        .expected_norm    = "breaking bad S05E14",
        .expected_top_name = "Breaking Bad S05E14 Ozymandias",
        .search_intent_tag = "show",
        .note = "Word-number season/episode → SxxExx.",
    },
    .{
        .user_input       = "play some jazz",
        .expected_intent  = .recommendation,
        .expected_norm    = "some jazz", // "play " stripped as filler
        .expected_top_name = null,        // should route to recommendation engine, NOT resolver
        .search_intent_tag = "auto",
        .note = "Fixed: 'play some X' → recommendation even when X isn't a media word.",
    },
    .{
        .user_input       = "surprise me",
        .expected_intent  = .recommendation,
        .expected_norm    = "surprise me",
        .expected_top_name = null,
        .search_intent_tag = "auto",
        .note = "Should go to TMDB trending, not resolver.",
    },
    .{
        .user_input       = "find sci-fi movies",
        .expected_intent  = .browse_genre,
        .expected_norm    = "sci-fi movies", // "find " stripped as filler
        .expected_top_name = null,
        .search_intent_tag = "auto",
        .note = "Genre + media word → should open genre browser, NOT keyword-search.",
    },
    .{
        .user_input       = "play the first item",
        .expected_intent  = .contextual_nav,
        .expected_norm    = "the first item", // filler 'play ' stripped
        .expected_top_name = null,             // nav intent → don't search resolver
        .search_intent_tag = "auto",
        .note = "Fixed: ordinal nav detected before title search. Downstream must act on chat_results, not resolver.",
    },
};

// ══════════════════════════════════════════════════════════
// Trace helpers — print decisions so `zig build test` output
// documents the pipeline's reasoning for each input.
// ══════════════════════════════════════════════════════════
fn dumpTrace(c: Case, got_intent: intent.Intent, got_norm: []const u8, ranked: []rank.Ranked) void {
    std.debug.print("\n── CASE: \"{s}\" ──\n", .{c.user_input});
    std.debug.print("  intent:    {s} (expected {s})\n", .{ @tagName(got_intent), @tagName(c.expected_intent) });
    std.debug.print("  normalize: \"{s}\" (expected \"{s}\")\n", .{ got_norm, c.expected_norm });
    std.debug.print("  note:      {s}\n", .{c.note});
    if (ranked.len == 0) {
        std.debug.print("  ranked:    (no matches — resolver would show nothing)\n", .{});
    } else {
        std.debug.print("  ranked top {d}:\n", .{@min(ranked.len, 5)});
        for (ranked[0..@min(ranked.len, 5)], 0..) |r, i| {
            const it = library[r.index];
            std.debug.print("    {d}. [{s:>8}] score={d:>4} match={d:>3}% \"{s}\"\n", .{
                i + 1, @tagName(it.source), r.info.score, r.info.match_pct, it.name,
            });
        }
    }
    if (c.expected_top_name) |want| {
        if (ranked.len > 0) {
            const got_name = library[ranked[0].index].name;
            const ok = std.mem.eql(u8, got_name, want);
            std.debug.print("  → would play: \"{s}\" {s}\n", .{ got_name, if (ok) "✓" else "✗ MISMATCH" });
        } else {
            std.debug.print("  → would play: (nothing) ✗ expected \"{s}\"\n", .{want});
        }
    } else {
        std.debug.print("  → expected: route away from resolver (recommendation / genre / nav)\n", .{});
    }
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "pipeline: every case — classify + normalize + rank + play decision" {
    var buf: [256]u8 = undefined;
    var rbuf: [32]rank.Ranked = undefined;

    var failures: u32 = 0;

    for (cases) |c| {
        // Stage 1: classify on lowercased input (matches ai_context.tryFastPath)
        var lower: [256]u8 = undefined;
        const llen = @min(c.user_input.len, 255);
        for (0..llen) |i| lower[i] = std.ascii.toLower(c.user_input[i]);
        const got_intent = intent.classifyIntent(lower[0..llen]);

        // Stage 2: normalize
        const got_norm = intent.normalizeQuery(c.user_input, &buf);

        // Stage 3: rank against library (only meaningful for specific_title / search)
        const ranked = rank.rankAll(&library, got_norm, c.search_intent_tag, &rbuf);

        // Stage 4: emit trace
        dumpTrace(c, got_intent, got_norm, ranked);

        // Assertions — tally don't abort, so trace for ALL cases prints
        if (got_intent != c.expected_intent) failures += 1;
        if (!std.mem.eql(u8, got_norm, c.expected_norm)) failures += 1;

        if (c.expected_top_name) |want| {
            if (ranked.len == 0) {
                failures += 1;
            } else if (!std.mem.eql(u8, library[ranked[0].index].name, want)) {
                failures += 1;
            }
        }
    }

    std.debug.print("\n── pipeline summary: {d} assertion failure(s) across {d} cases ──\n", .{ failures, cases.len });
    try std.testing.expectEqual(@as(u32, 0), failures);
}

test "pipeline: ordinal nav classified correctly" {
    try std.testing.expectEqual(intent.Intent.contextual_nav, intent.classifyIntent("play the first item"));
    try std.testing.expectEqual(intent.Intent.contextual_nav, intent.classifyIntent("play the third one"));
    try std.testing.expectEqual(intent.Intent.contextual_nav, intent.classifyIntent("next item"));
}

test "pipeline: jellyfin always preferred over equal-match torrent" {
    var rbuf: [8]rank.Ranked = undefined;
    const ranked = rank.rankAll(&library, "the boys s01e01", "show", &rbuf);
    try std.testing.expect(ranked.len >= 2);
    try std.testing.expectEqual(rank.SourceType.jellyfin, library[ranked[0].index].source);
}

test "pipeline: youtube trailer never wins a movie query" {
    var rbuf: [8]rank.Ranked = undefined;
    const ranked = rank.rankAll(&library, "inception", "movie", &rbuf);
    try std.testing.expect(ranked.len > 0);
    try std.testing.expect(library[ranked[0].index].source != .youtube);
}
