//! Pure parse of an OMDb (omdbapi.com) response into the real IMDb / Rotten
//! Tomatoes / Metacritic scores that TMDB can't provide. No io/state imports,
//! so the logic ships unit-tested (see build.zig `test_omdb_pure`) and the
//! production omdb.zig routes every parse through here — the tested logic *is*
//! the shipped logic (no drift).
//!
//! OMDb shape (relevant fields):
//!   {"Rated":"TV-MA","Ratings":[
//!       {"Source":"Internet Movie Database","Value":"9.5/10"},
//!       {"Source":"Rotten Tomatoes","Value":"96%"},
//!       {"Source":"Metacritic","Value":"88/100"}],
//!    "imdbRating":"9.5","imdbVotes":"2,000,000",
//!    "Awards":"Won 2 Primetime Emmys...","Response":"True"}
//!
//! Missing fields come back as the literal string "N/A" — treated as absent.

const std = @import("std");

/// Parsed ratings for one title. Fixed buffers (no allocation) so the enrichment
/// worker can snapshot-copy it under a mutex, matching the codebase's state style.
pub const Ratings = struct {
    imdb_rating: [8]u8 = std.mem.zeroes([8]u8), // "9.5"
    imdb_rating_len: usize = 0,
    imdb_votes: [16]u8 = std.mem.zeroes([16]u8), // "2,000,000"
    imdb_votes_len: usize = 0,
    rt_percent: [8]u8 = std.mem.zeroes([8]u8), // "96%"
    rt_percent_len: usize = 0,
    metacritic: [8]u8 = std.mem.zeroes([8]u8), // "88" (score only, from "88/100")
    metacritic_len: usize = 0,
    rated: [16]u8 = std.mem.zeroes([16]u8), // "TV-MA"
    rated_len: usize = 0,
    awards: [128]u8 = std.mem.zeroes([128]u8), // "Won 2 Primetime Emmys..."
    awards_len: usize = 0,

    /// True when at least one *score* is populated. The render row and the
    /// omdb.zig "have data" gate both use this, so an all-empty parse (or an
    /// only-Rated/Awards parse) shows nothing.
    pub fn hasScores(self: *const Ratings) bool {
        return self.imdb_rating_len > 0 or self.rt_percent_len > 0 or self.metacritic_len > 0;
    }
};

// ── tiny JSON scan helpers (self-contained; no allocation) ──

/// A JSON string value is "usable" when non-empty and not the OMDb literal "N/A".
fn usable(v: []const u8) bool {
    return v.len > 0 and !std.mem.eql(u8, v, "N/A");
}

/// Quoted-string value following `key` (which must include everything up to the
/// value's opening quote, e.g. `"\"imdbRating\":\""`). Null when absent. No
/// escape decoding — the OMDb fields we read (ratings, rated, awards) never
/// contain embedded quotes, so a plain scan to the next `"` is correct.
fn strAfter(s: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, s, key) orelse return null;
    const vs = ki + key.len;
    const ve = std.mem.indexOfScalarPos(u8, s, vs, '"') orelse return null;
    return s[vs..ve];
}

/// In the `Ratings` array, the `Value` string of the entry whose `Source`
/// equals `source_quoted` (e.g. `"\"Rotten Tomatoes\""`). OMDb always lists
/// `Source` before `Value` inside each object, so we locate the source then the
/// next `Value` after it. Null when that source isn't present.
fn valueForSource(json: []const u8, source_quoted: []const u8) ?[]const u8 {
    const si = std.mem.indexOf(u8, json, source_quoted) orelse return null;
    const vkey = "\"Value\":\"";
    const vi = std.mem.indexOfPos(u8, json, si, vkey) orelse return null;
    const vs = vi + vkey.len;
    const ve = std.mem.indexOfScalarPos(u8, json, vs, '"') orelse return null;
    return json[vs..ve];
}

/// Copy `v` into a fixed `buf`, capping at its length, and store the length.
fn copyInto(buf: []u8, len: *usize, v: []const u8) void {
    const n = @min(v.len, buf.len);
    @memcpy(buf[0..n], v[0..n]);
    len.* = n;
}

/// Append `s` to `buf` at offset `n`, capped at buf.len; returns the new offset.
fn writeStr(buf: []u8, n: usize, s: []const u8) usize {
    const end = @min(buf.len, n + s.len);
    @memcpy(buf[n..end], s[0 .. end - n]);
    return end;
}

// ── Public API ──

/// Parse an OMDb JSON body. Always returns a Ratings (empty on garbage — never
/// panics). Sources: top-level `imdbRating`/`imdbVotes`/`Rated`/`Awards`, plus
/// the `Ratings[]` entries for Rotten Tomatoes ("96%") and Metacritic
/// ("88/100" → score "88" only).
pub fn parse(json: []const u8) Ratings {
    var out = Ratings{};

    if (strAfter(json, "\"imdbRating\":\"")) |v| {
        if (usable(v)) copyInto(&out.imdb_rating, &out.imdb_rating_len, v);
    }
    if (strAfter(json, "\"imdbVotes\":\"")) |v| {
        if (usable(v)) copyInto(&out.imdb_votes, &out.imdb_votes_len, v);
    }
    if (strAfter(json, "\"Rated\":\"")) |v| {
        if (usable(v)) copyInto(&out.rated, &out.rated_len, v);
    }
    if (strAfter(json, "\"Awards\":\"")) |v| {
        if (usable(v)) copyInto(&out.awards, &out.awards_len, v);
    }
    if (valueForSource(json, "\"Rotten Tomatoes\"")) |v| {
        if (usable(v)) copyInto(&out.rt_percent, &out.rt_percent_len, v);
    }
    if (valueForSource(json, "\"Metacritic\"")) |v| {
        if (usable(v)) {
            // "88/100" → "88" (drop the denominator).
            const score = v[0..(std.mem.indexOfScalar(u8, v, '/') orelse v.len)];
            copyInto(&out.metacritic, &out.metacritic_len, score);
        }
    }

    return out;
}

/// The `imdb_id` string from a TMDB `/external_ids` body ("tt0903747"), or null
/// when absent / JSON `null`. Feed the result to `normalizeImdbId`.
pub fn extractImdbId(json: []const u8) ?[]const u8 {
    const v = strAfter(json, "\"imdb_id\":\"") orelse return null;
    return if (usable(v)) v else null;
}

/// Normalize a raw IMDb id ("tt0903747", or a bare "0903747") into the canonical
/// "tt"+digits form OMDb's `?i=` param wants. Writes into `buf`, returns the
/// slice, or null when there are no id digits / any non-digit body char.
pub fn normalizeImdbId(raw: []const u8, buf: []u8) ?[]const u8 {
    var digits = raw;
    if (digits.len >= 2 and (digits[0] == 't' or digits[0] == 'T') and
        (digits[1] == 't' or digits[1] == 'T'))
    {
        digits = digits[2..];
    }
    if (digits.len == 0) return null;
    for (digits) |ch| if (ch < '0' or ch > '9') return null;
    return std.fmt.bufPrint(buf, "tt{s}", .{digits}) catch null;
}

/// Build the scores row "IMDb 9.5 · RT 96% · Metacritic 88" into `buf`, omitting
/// any missing source. Null when no score is present.
pub fn formatScores(r: *const Ratings, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    if (r.imdb_rating_len > 0) {
        n = writeStr(buf, n, "IMDb ");
        n = writeStr(buf, n, r.imdb_rating[0..r.imdb_rating_len]);
    }
    if (r.rt_percent_len > 0) {
        if (n > 0) n = writeStr(buf, n, " · ");
        n = writeStr(buf, n, "RT ");
        n = writeStr(buf, n, r.rt_percent[0..r.rt_percent_len]);
    }
    if (r.metacritic_len > 0) {
        if (n > 0) n = writeStr(buf, n, " · ");
        n = writeStr(buf, n, "Metacritic ");
        n = writeStr(buf, n, r.metacritic[0..r.metacritic_len]);
    }
    if (n == 0) return null;
    return buf[0..n];
}

/// Secondary muted line "Rated TV-MA · Won 2 Emmys…" into `buf`, omitting any
/// missing part. Null when neither Rated nor Awards is present.
pub fn formatDetails(r: *const Ratings, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    if (r.rated_len > 0) {
        n = writeStr(buf, n, "Rated ");
        n = writeStr(buf, n, r.rated[0..r.rated_len]);
    }
    if (r.awards_len > 0) {
        if (n > 0) n = writeStr(buf, n, " · ");
        n = writeStr(buf, n, r.awards[0..r.awards_len]);
    }
    if (n == 0) return null;
    return buf[0..n];
}

// ── Tests ──

const full_body =
    "{\"Title\":\"Breaking Bad\",\"Year\":\"2008–2013\",\"Rated\":\"TV-MA\"," ++
    "\"Ratings\":[" ++
    "{\"Source\":\"Internet Movie Database\",\"Value\":\"9.5/10\"}," ++
    "{\"Source\":\"Rotten Tomatoes\",\"Value\":\"96%\"}," ++
    "{\"Source\":\"Metacritic\",\"Value\":\"88/100\"}]," ++
    "\"Metascore\":\"88\",\"imdbRating\":\"9.5\",\"imdbVotes\":\"2,000,000\"," ++
    "\"imdbID\":\"tt0903747\",\"Awards\":\"Won 16 Primetime Emmys. 173 wins & 271 nominations total\"," ++
    "\"Response\":\"True\"}";

test "parse: full body extracts every field" {
    const r = parse(full_body);
    try std.testing.expectEqualStrings("9.5", r.imdb_rating[0..r.imdb_rating_len]);
    try std.testing.expectEqualStrings("2,000,000", r.imdb_votes[0..r.imdb_votes_len]);
    try std.testing.expectEqualStrings("96%", r.rt_percent[0..r.rt_percent_len]);
    // "88/100" → score only.
    try std.testing.expectEqualStrings("88", r.metacritic[0..r.metacritic_len]);
    try std.testing.expectEqualStrings("TV-MA", r.rated[0..r.rated_len]);
    try std.testing.expectEqualStrings("Won 16 Primetime Emmys. 173 wins & 271 nominations total", r.awards[0..r.awards_len]);
    try std.testing.expect(r.hasScores());
}

test "parse: missing fields (N/A + absent) leave empties, no false scores" {
    // A movie with no RT/Metacritic and an N/A rating.
    const body =
        "{\"Title\":\"Obscure Film\",\"Rated\":\"N/A\"," ++
        "\"Ratings\":[{\"Source\":\"Internet Movie Database\",\"Value\":\"6.1/10\"}]," ++
        "\"imdbRating\":\"6.1\",\"imdbVotes\":\"N/A\",\"Awards\":\"N/A\",\"Response\":\"True\"}";
    const r = parse(body);
    try std.testing.expectEqualStrings("6.1", r.imdb_rating[0..r.imdb_rating_len]);
    // N/A → treated as absent.
    try std.testing.expectEqual(@as(usize, 0), r.imdb_votes_len);
    try std.testing.expectEqual(@as(usize, 0), r.rated_len);
    try std.testing.expectEqual(@as(usize, 0), r.awards_len);
    // No RT / Metacritic entries in the array.
    try std.testing.expectEqual(@as(usize, 0), r.rt_percent_len);
    try std.testing.expectEqual(@as(usize, 0), r.metacritic_len);
    try std.testing.expect(r.hasScores()); // imdb present
}

test "parse: OMDb error response yields no scores (hasScores false)" {
    // {"Response":"False","Error":"Incorrect IMDb ID."}
    const r = parse("{\"Response\":\"False\",\"Error\":\"Incorrect IMDb ID.\"}");
    try std.testing.expect(!r.hasScores());
    try std.testing.expectEqual(@as(usize, 0), r.imdb_rating_len);
}

test "parse: malformed JSON never panics (regression)" {
    // Truncated / garbage bodies must return safely, not crash.
    _ = parse("{\"imdbRating\":\"");
    _ = parse("{\"Ratings\":[{\"Source\":\"Rotten Tomatoes\",\"Value\":");
    _ = parse("{{{{");
    _ = parse("");
    _ = parse("\"imdbRating\":");
    const r = parse("{\"Ratings\":[{\"Source\":\"Metacritic\"}]}"); // Source but no Value
    try std.testing.expectEqual(@as(usize, 0), r.metacritic_len);
    try std.testing.expect(true);
}

test "extractImdbId: present, null, absent" {
    try std.testing.expectEqualStrings("tt0903747", extractImdbId("{\"imdb_id\":\"tt0903747\",\"tvdb_id\":81189}").?);
    // TMDB returns bare null for titles with no IMDb link.
    try std.testing.expect(extractImdbId("{\"imdb_id\":null,\"tvdb_id\":81189}") == null);
    try std.testing.expect(extractImdbId("{\"tvdb_id\":81189}") == null);
    try std.testing.expect(extractImdbId("{\"imdb_id\":\"N/A\"}") == null);
}

test "normalizeImdbId: tt-prefixed, bare digits, invalid" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("tt0903747", normalizeImdbId("tt0903747", &buf).?);
    // Already-bare digits get the tt prefix.
    try std.testing.expectEqualStrings("tt0903747", normalizeImdbId("0903747", &buf).?);
    // Uppercase TT tolerated.
    try std.testing.expectEqualStrings("tt55", normalizeImdbId("TT55", &buf).?);
    // No digits / garbage → null (must not build a bogus "tt" url).
    try std.testing.expect(normalizeImdbId("tt", &buf) == null);
    try std.testing.expect(normalizeImdbId("", &buf) == null);
    try std.testing.expect(normalizeImdbId("ttabc", &buf) == null);
}

test "formatScores: all present, partial, none" {
    var buf: [96]u8 = undefined;
    const r = parse(full_body);
    try std.testing.expectEqualStrings("IMDb 9.5 · RT 96% · Metacritic 88", formatScores(&r, &buf).?);

    // Only IMDb.
    var only = Ratings{};
    copyInto(&only.imdb_rating, &only.imdb_rating_len, "7.4");
    try std.testing.expectEqualStrings("IMDb 7.4", formatScores(&only, &buf).?);

    // RT + Metacritic, no IMDb (no leading separator).
    var two = Ratings{};
    copyInto(&two.rt_percent, &two.rt_percent_len, "72%");
    copyInto(&two.metacritic, &two.metacritic_len, "61");
    try std.testing.expectEqualStrings("RT 72% · Metacritic 61", formatScores(&two, &buf).?);

    // Empty → null.
    const none = Ratings{};
    try std.testing.expect(formatScores(&none, &buf) == null);
}

test "formatDetails: rated + awards, partial, none" {
    var buf: [160]u8 = undefined;
    const r = parse(full_body);
    try std.testing.expectEqualStrings("Rated TV-MA · Won 16 Primetime Emmys. 173 wins & 271 nominations total", formatDetails(&r, &buf).?);

    var only_awards = Ratings{};
    copyInto(&only_awards.awards, &only_awards.awards_len, "Nominated for 1 Oscar");
    try std.testing.expectEqualStrings("Nominated for 1 Oscar", formatDetails(&only_awards, &buf).?);

    const none = Ratings{};
    try std.testing.expect(formatDetails(&none, &buf) == null);
}
