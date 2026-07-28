//! Pure logic for the playback loading screen — no io, no dvui, so it runs
//! under `zig build test` without a live frame.
//!
//! A torrent resolve plus first-parts buffering can take half a minute. The
//! loading screen used to be a hourglass with a truncated file path, and later
//! a poster plus ONE static paragraph that only ever appeared for TMDB movie
//! and TV plays. Music, anime and everything else got the bare hourglass, and
//! nothing on the screen ever changed while you waited.
//!
//! This module holds the decisions behind the richer screen: which poster URL
//! to fetch for any source, how to cut a summary into readable cards, which
//! card is showing, and how the header line reads. `grid.zig` renders through
//! these, so the tested logic IS the shipped logic.

const std = @import("std");

// ══════════════════════════════════════════════════════════════════
// Media kind
// ══════════════════════════════════════════════════════════════════

/// What is loading. Drives the badge on the loading screen and the
/// disambiguation hint used when looking up trivia.
pub const MediaKind = enum {
    movie,
    tv,
    album,
    anime,
    other,

    /// Numeric form for the fixed-size state structs (they store plain
    /// integers, not tagged unions — see the state.zig buffer convention).
    pub fn toInt(self: MediaKind) u8 {
        return @intFromEnum(self);
    }

    /// Reverse of `toInt`, saturating on a value from an older config or a
    /// corrupt row rather than panicking on an invalid enum tag.
    pub fn fromInt(v: u8) MediaKind {
        const max = @typeInfo(MediaKind).@"enum".fields.len - 1;
        return @enumFromInt(@min(v, max));
    }
};

pub fn kindLabel(kind: MediaKind) []const u8 {
    return switch (kind) {
        .movie => "Movie",
        .tv => "TV",
        .album => "Music",
        .anime => "Anime",
        .other => "",
    };
}

// ══════════════════════════════════════════════════════════════════
// Poster / cover art URL
// ══════════════════════════════════════════════════════════════════

pub const TMDB_IMG_BASE = "https://image.tmdb.org/t/p/w500";

/// Resolve the stashed art reference to a fetchable URL.
///
/// TMDB hands out a path fragment ("/abc.jpg"), and the loading screen used to
/// hard-code the TMDB base around it — which is exactly why no non-TMDB source
/// could ever show art here. An absolute URL (a Subsonic/Jellyfin/Plex cover, a
/// JioSaavn CDN image, an anime poster) now passes through untouched, so one
/// field serves every source.
///
/// Returns an empty slice when there is nothing to fetch, so callers can test
/// `.len == 0` instead of unwrapping.
pub fn posterUrl(raw: []const u8, buf: []u8) []const u8 {
    if (raw.len == 0) return buf[0..0];
    if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://")) {
        if (raw.len > buf.len) return buf[0..0];
        @memcpy(buf[0..raw.len], raw);
        return buf[0..raw.len];
    }
    // A bare TMDB fragment. It always starts with '/', but tolerate one that
    // does not rather than producing a URL with a missing separator.
    const sep: []const u8 = if (raw[0] == '/') "" else "/";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ TMDB_IMG_BASE, sep, raw }) catch buf[0..0];
}

// ══════════════════════════════════════════════════════════════════
// Fact cards
// ══════════════════════════════════════════════════════════════════

/// Most cards worth cycling through. A Wikipedia lead paragraph rarely yields
/// more than four or five usable sentences.
pub const MAX_CARDS = 6;

/// Below this a "sentence" is an abbreviation or a stray fragment, not a fact —
/// it gets glued onto the previous card instead of becoming its own.
pub const MIN_CARD_LEN = 40;

pub const Cards = struct {
    starts: [MAX_CARDS]usize = [_]usize{0} ** MAX_CARDS,
    ends: [MAX_CARDS]usize = [_]usize{0} ** MAX_CARDS,
    count: usize = 0,

    pub fn slice(self: *const Cards, text: []const u8, i: usize) []const u8 {
        if (i >= self.count) return text[0..0];
        const s = @min(self.starts[i], text.len);
        const e = @min(self.ends[i], text.len);
        if (e <= s) return text[0..0];
        return text[s..e];
    }
};

/// Cut `text` into sentence-sized cards the screen can rotate through.
///
/// Splits on ". " / "! " / "? " only — a period with no following space is an
/// abbreviation, a decimal or an initial ("J.R.R."), and splitting there
/// produced one-word cards. Fragments under MIN_CARD_LEN are merged forward for
/// the same reason. Text with no sentence break at all yields exactly one card,
/// so the caller never has to special-case a short summary.
pub fn splitFacts(text: []const u8) Cards {
    var out: Cards = .{};
    const first = leadingSpace(text);
    if (first >= text.len) return out;

    var start = first;
    var i = first;
    while (i < text.len and out.count < MAX_CARDS) {
        const c = text[i];
        const is_end = (c == '.' or c == '!' or c == '?');
        const boundary = is_end and (i + 1 == text.len or text[i + 1] == ' ' or text[i + 1] == '\n');
        if (!boundary) {
            i += 1;
            continue;
        }
        const end = i + 1;
        if (end - start >= MIN_CARD_LEN) {
            out.starts[out.count] = start;
            out.ends[out.count] = end;
            out.count += 1;
            start = end + leadingSpace(text[end..]);
            i = start;
            continue;
        }
        // Too short to be a fact on its own. If there is a previous card, glue
        // it on; otherwise keep scanning WITHOUT moving `start`, so the
        // fragment merges forward into the next sentence. This is what keeps
        // "J.R.R." and "7.8" from each becoming their own card.
        if (out.count > 0) {
            out.ends[out.count - 1] = end;
            start = end + leadingSpace(text[end..]);
            i = start;
        } else {
            i = end;
        }
    }

    // Trailing text with no terminator: keep it if substantial, else fold it
    // into the last card rather than dropping half a sentence.
    if (start < text.len and out.count < MAX_CARDS) {
        if (text.len - start >= MIN_CARD_LEN) {
            out.starts[out.count] = start;
            out.ends[out.count] = text.len;
            out.count += 1;
        } else if (out.count > 0) {
            out.ends[out.count - 1] = text.len;
        }
    }

    // Nothing met the length floor — a one-line summary, or a blurb that is all
    // abbreviations. Show it whole rather than showing nothing.
    if (out.count == 0) {
        out.starts[0] = first;
        out.ends[0] = text.len;
        out.count = 1;
    }
    return out;
}

fn leadingSpace(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and (s[n] == ' ' or s[n] == '\n' or s[n] == '\t')) n += 1;
    return n;
}

/// How long each card stays up before the deck advances on its own.
pub const CARD_INTERVAL_MS: i64 = 7000;

/// Which card is showing. `elapsed_ms` is time since the last manual page (the
/// caller resets it on a click, so tapping ‹ › does not fight the auto-rotate),
/// `manual` is how many times the user has paged. Wraps in both directions and
/// is safe for count 0 or a negative clock.
pub fn cardIndex(count: usize, elapsed_ms: i64, manual: usize) usize {
    if (count == 0) return 0;
    const ticks: usize = if (elapsed_ms <= 0) 0 else @intCast(@divFloor(elapsed_ms, CARD_INTERVAL_MS));
    return (manual +% ticks) % count;
}

// ══════════════════════════════════════════════════════════════════
// Header line
// ══════════════════════════════════════════════════════════════════

/// The line under the title: "Movie · 2024 · 78%", skipping whatever is
/// missing so a source with no year or rating does not render stray separators.
///
/// The score is a PERCENTAGE, matching how every other Opal surface prints a
/// TMDB rating (grid cards, Home rails) — one convention, not two. Ratings of 0
/// mean "not rated / no votes yet" in TMDB's payload rather than a zero score,
/// so they are omitted instead of printed as "0%".
pub fn metaLine(buf: []u8, kind: MediaKind, year: []const u8, rating: f32, extra: []const u8) []const u8 {
    var w: usize = 0;
    const parts = [_][]const u8{ kindLabel(kind), year, extra };
    for (parts) |part| {
        if (part.len == 0) continue;
        w += appendPart(buf, w, part);
    }
    if (rating > 0.0 and rating <= 10.0) {
        var rbuf: [16]u8 = undefined;
        const pct: u32 = @intFromFloat(@round(rating * 10.0));
        const r = std.fmt.bufPrint(&rbuf, "{d}%", .{pct}) catch return buf[0..w];
        w += appendPart(buf, w, r);
    }
    return buf[0..w];
}

fn appendPart(buf: []u8, at: usize, part: []const u8) usize {
    const sep: []const u8 = if (at == 0) "" else " \u{00B7} ";
    const need = sep.len + part.len;
    if (at + need > buf.len) return 0;
    @memcpy(buf[at .. at + sep.len], sep);
    @memcpy(buf[at + sep.len .. at + need], part);
    return need;
}

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "posterUrl expands a TMDB fragment and passes an absolute URL through" {
    var b: [256]u8 = undefined;
    try expectEqualStrings(
        "https://image.tmdb.org/t/p/w500/abc123.jpg",
        posterUrl("/abc123.jpg", &b),
    );
    // REGRESSION: the base used to be hard-coded at the call site, so a
    // Subsonic/Jellyfin/JioSaavn cover URL came out as
    // "https://image.tmdb.org/t/p/w500https://..." — i.e. no music source could
    // ever show art on the loading screen.
    const abs = "https://music.example.com/rest/getCoverArt?id=al-9&size=512";
    try expectEqualStrings(abs, posterUrl(abs, &b));
    try expectEqualStrings("http://nas.local/art.png", posterUrl("http://nas.local/art.png", &b));
    // A fragment missing its leading slash still produces a valid URL.
    try expectEqualStrings("https://image.tmdb.org/t/p/w500/x.jpg", posterUrl("x.jpg", &b));
}

test "posterUrl yields an empty slice rather than a truncated URL" {
    var b: [256]u8 = undefined;
    try expectEqual(@as(usize, 0), posterUrl("", &b).len);
    // Too small to hold the result: empty, never a half URL that 404s.
    var tiny: [8]u8 = undefined;
    try expectEqual(@as(usize, 0), posterUrl("/abc123.jpg", &tiny).len);
    try expectEqual(@as(usize, 0), posterUrl("https://example.com/a-very-long-url.jpg", &tiny).len);
}

test "splitFacts cuts on sentence ends, not on every period" {
    const text = "Dune is a 2021 epic science fiction film directed by Denis Villeneuve. " ++
        "It was co-written by Jon Spaihts, Villeneuve and Eric Roth. " ++
        "The film stars an ensemble cast and was released to acclaim.";
    const cards = splitFacts(text);
    try expectEqual(@as(usize, 3), cards.count);
    try expect(std.mem.startsWith(u8, cards.slice(text, 0), "Dune is a 2021"));
    try expect(std.mem.endsWith(u8, cards.slice(text, 0), "Villeneuve."));
    try expect(std.mem.startsWith(u8, cards.slice(text, 1), "It was co-written"));
    // No leading space bleeds into a card.
    for (0..cards.count) |i| try expect(cards.slice(text, i)[0] != ' ');
}

test "splitFacts does not break on abbreviations or decimals" {
    // "J.R.R." and "7.8" have periods with no following space — splitting there
    // produced one- and two-character cards.
    const text = "The novel by J.R.R. Tolkien holds a rating of 7.8 out of 10 on the site. " ++
        "It was adapted for the screen several decades after publication.";
    const cards = splitFacts(text);
    try expectEqual(@as(usize, 2), cards.count);
    try expect(std.mem.indexOf(u8, cards.slice(text, 0), "J.R.R. Tolkien") != null);
    try expect(std.mem.indexOf(u8, cards.slice(text, 0), "7.8") != null);
}

test "splitFacts always yields one card for text with no sentence break" {
    const short = "A short blurb with no terminator";
    const c1 = splitFacts(short);
    try expectEqual(@as(usize, 1), c1.count);
    try expectEqualStrings(short, c1.slice(short, 0));

    const one = "Exactly one complete sentence that runs past the minimum length.";
    const c2 = splitFacts(one);
    try expectEqual(@as(usize, 1), c2.count);
    try expectEqualStrings(one, c2.slice(one, 0));

    const empty = splitFacts("");
    try expectEqual(@as(usize, 0), empty.count);
    try expectEqual(@as(usize, 0), empty.slice("", 0).len);
}

test "splitFacts is bounded and never emits an out-of-range slice" {
    var long: [4000]u8 = undefined;
    var i: usize = 0;
    while (i + 50 < long.len) : (i += 50) {
        @memcpy(long[i .. i + 50], "This is a padded sentence of fifty characters.... ");
    }
    const cards = splitFacts(long[0..i]);
    try expect(cards.count <= MAX_CARDS);
    for (0..cards.count) |n| {
        const s = cards.slice(long[0..i], n);
        try expect(s.len > 0);
        try expect(cards.ends[n] <= i);
        try expect(cards.starts[n] < cards.ends[n]);
    }
    // Asking past the end is empty, not a panic.
    try expectEqual(@as(usize, 0), cards.slice(long[0..i], MAX_CARDS + 3).len);
}

test "cardIndex auto-rotates, wraps, and honours manual paging" {
    // Nothing to show.
    try expectEqual(@as(usize, 0), cardIndex(0, 999_999, 3));
    // Before the first interval elapses, card 0.
    try expectEqual(@as(usize, 0), cardIndex(3, 0, 0));
    try expectEqual(@as(usize, 0), cardIndex(3, CARD_INTERVAL_MS - 1, 0));
    // One interval → next card; wraps at the end.
    try expectEqual(@as(usize, 1), cardIndex(3, CARD_INTERVAL_MS, 0));
    try expectEqual(@as(usize, 2), cardIndex(3, 2 * CARD_INTERVAL_MS, 0));
    try expectEqual(@as(usize, 0), cardIndex(3, 3 * CARD_INTERVAL_MS, 0));
    // Manual paging offsets the deck; the caller resets elapsed on a click so
    // the freshly-chosen card gets a full interval.
    try expectEqual(@as(usize, 1), cardIndex(3, 0, 1));
    try expectEqual(@as(usize, 0), cardIndex(3, 0, 3));
    try expectEqual(@as(usize, 1), cardIndex(3, 0, 4));
    // A clock that goes backwards (the load started before a resync) must not
    // underflow into a huge index.
    try expectEqual(@as(usize, 0), cardIndex(3, -5000, 0));
    try expect(cardIndex(3, -5000, 2) < 3);
}

test "metaLine joins only the parts that exist" {
    var b: [96]u8 = undefined;
    try expectEqualStrings("Movie \u{00B7} 2021 \u{00B7} 78%", metaLine(&b, .movie, "2021", 7.8, ""));
    try expectEqualStrings("TV \u{00B7} S2E4", metaLine(&b, .tv, "", 0, "S2E4"));
    // A music track has no year or rating — no dangling separators.
    try expectEqualStrings("Music \u{00B7} Boards of Canada", metaLine(&b, .album, "", 0, "Boards of Canada"));
    // Unknown kind with nothing else is empty, not a lone separator.
    try expectEqualStrings("", metaLine(&b, .other, "", 0, ""));
}

test "metaLine omits an unrated score instead of printing zero" {
    var b: [96]u8 = undefined;
    // TMDB sends 0 for "no votes yet"; printing "0%" reads as a terrible
    // score rather than as "unrated".
    try expectEqualStrings("Movie \u{00B7} 1999", metaLine(&b, .movie, "1999", 0, ""));
    try expectEqualStrings("Movie \u{00B7} 1999", metaLine(&b, .movie, "1999", -1, ""));
    // Out-of-range values (a malformed payload) are dropped too.
    try expectEqualStrings("Movie \u{00B7} 1999", metaLine(&b, .movie, "1999", 99, ""));
    try expectEqualStrings("Movie \u{00B7} 1999 \u{00B7} 100%", metaLine(&b, .movie, "1999", 10, ""));
    // Rounds rather than truncates: 7.85 is 79%, not 78%.
    try expectEqualStrings("Movie \u{00B7} 1999 \u{00B7} 79%", metaLine(&b, .movie, "1999", 7.85, ""));
}

test "metaLine never overruns a small buffer" {
    var tiny: [10]u8 = undefined;
    const s = metaLine(&tiny, .movie, "2021", 7.8, "a-very-long-extra-part");
    try expect(s.len <= tiny.len);
    // What fits, fits; nothing past the end is written.
    try expect(std.mem.startsWith(u8, "Movie", s[0..@min(s.len, 5)]));
}

test "MediaKind survives a corrupt integer" {
    try expectEqual(MediaKind.movie, MediaKind.fromInt(0));
    try expectEqual(MediaKind.other, MediaKind.fromInt(4));
    // Out of range saturates rather than producing an invalid tag.
    try expectEqual(MediaKind.other, MediaKind.fromInt(200));
    // Round-trip.
    for ([_]MediaKind{ .movie, .tv, .album, .anime, .other }) |k| {
        try expectEqual(k, MediaKind.fromInt(k.toInt()));
        try expect(kindLabel(k).len > 0 or k == .other);
    }
}
