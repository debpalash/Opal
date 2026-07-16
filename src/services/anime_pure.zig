//! Pure helpers for the anime tab (Jikan API) — no app-state imports, so the
//! logic ships tested (see build.zig test step).

const std = @import("std");

/// True when a Jikan anime object's `rating` marks adult content.
/// Jikan ratings: G, PG, PG-13, "R - 17+ (violence & profanity)",
/// "R+ - Mild Nudity", "Rx - Hentai". The NSFW filter hides Rx (hentai)
/// and R+ (nudity/ecchi covers) — plain "R - 17+" stays: violence is not
/// what the toggle is about. Matching is on the exact "Rx"/"R+" prefix, so
/// "R -" never false-positives.
pub fn jikanRatingIsAdult(obj_json: []const u8) bool {
    const key = "\"rating\":\"";
    const start = (std.mem.indexOf(u8, obj_json, key) orelse return false) + key.len;
    const rest = obj_json[start..];
    if (std.mem.startsWith(u8, rest, "Rx")) return true;
    if (std.mem.startsWith(u8, rest, "R+")) return true;
    return false;
}

/// Query-string suffix for Jikan endpoints. Historically `&sfw=true` asked the API itself
/// Jikan currently 504s ("failed to connect to MyAnimeList") on ANY request
/// carrying the `sfw` query param — which, since the NSFW filter is ON by
/// default, broke every anime view (trending/seasonal/search/calendar). The
/// param is redundant anyway: parseJikanDataEx already drops adult entries
/// client-side via `jikanRatingIsAdult` when the filter is on. So send NO sfw
/// param and rely on that client-side filter. Kept as a function (not inlined)
/// so re-enabling a server-side param later is a one-line change.
pub fn sfwSuffix(filter_enabled: bool) []const u8 {
    _ = filter_enabled;
    return "";
}

/// Detail-header metadata extracted from a single Jikan anime object's raw JSON.
/// `atype` is a slice INTO `obj_json` (copy it before the buffer goes away).
pub const JikanMeta = struct {
    atype: []const u8 = "", // "TV"/"Movie"/"OVA"/"ONA"/"Special"/"Music"
    year: u16 = 0, // release year (0 = unknown)
    airing: bool = false, // currently broadcasting
};

/// First numeric `"year":<n>` (1000–9999) in the object. Jikan emits
/// aired.prop.from.year BEFORE aired.prop.to.year and the top-level "year",
/// so the first parseable hit is the release/start year — exactly what the
/// header shows. `"year":null` (unaired/movies) is skipped.
fn extractYear(obj: []const u8) u16 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, obj, pos, "\"year\":")) |yi| {
        const s = yi + 7;
        pos = s;
        if (s < obj.len and obj[s] >= '0' and obj[s] <= '9') {
            var e = s;
            while (e < obj.len and obj[e] >= '0' and obj[e] <= '9') : (e += 1) {}
            const y = std.fmt.parseInt(u16, obj[s..e], 10) catch continue;
            if (y >= 1000 and y <= 9999) return y;
        }
    }
    return 0;
}

/// Extract `type`, `year`, and `airing` from a Jikan anime object.
pub fn parseJikanMeta(obj: []const u8) JikanMeta {
    var m = JikanMeta{};

    // type — a short string ("TV"/"Movie"/…). Guard the null form.
    if (std.mem.indexOf(u8, obj, "\"type\":\"")) |ti| {
        const s = ti + 8;
        var e = s;
        while (e < obj.len and obj[e] != '"') : (e += 1) {}
        if (e <= obj.len) m.atype = obj[s..e];
    }

    // airing — plain boolean; only true matters for the header badge.
    if (std.mem.indexOf(u8, obj, "\"airing\":true") != null) m.airing = true;

    m.year = extractYear(obj);
    return m;
}

test "parseJikanMeta extracts type, year (aired.prop.from), airing" {
    const j =
        \\{"mal_id":1,"type":"TV","episodes":24,"status":"Currently Airing","airing":true,
        \\"aired":{"from":"2024-04-06","prop":{"from":{"day":6,"month":4,"year":2024},
        \\"to":{"day":null,"month":null,"year":null}},"string":"Apr 6, 2024 to ?"},
        \\"score":8.5,"year":2024}
    ;
    const m = parseJikanMeta(j);
    try std.testing.expectEqualStrings("TV", m.atype);
    try std.testing.expectEqual(@as(u16, 2024), m.year);
    try std.testing.expect(m.airing);
}

test "parseJikanMeta: finished movie, no airing, null top-level year" {
    const j =
        \\{"mal_id":5,"type":"Movie","episodes":1,"status":"Finished Airing","airing":false,
        \\"aired":{"prop":{"from":{"day":1,"month":9,"year":1997},"to":{"day":1,"month":9,"year":1997}}},
        \\"year":null}
    ;
    const m = parseJikanMeta(j);
    try std.testing.expectEqualStrings("Movie", m.atype);
    try std.testing.expectEqual(@as(u16, 1997), m.year);
    try std.testing.expect(!m.airing);
}

test "parseJikanMeta tolerates missing fields" {
    const m = parseJikanMeta("{\"mal_id\":9,\"title\":\"x\"}");
    try std.testing.expectEqualStrings("", m.atype);
    try std.testing.expectEqual(@as(u16, 0), m.year);
    try std.testing.expect(!m.airing);
}

test "jikanRatingIsAdult flags Rx and R+, keeps R and below" {
    try std.testing.expect(jikanRatingIsAdult("{\"mal_id\":1,\"rating\":\"Rx - Hentai\",\"title\":\"x\"}"));
    try std.testing.expect(jikanRatingIsAdult("{\"rating\":\"R+ - Mild Nudity\"}"));
    try std.testing.expect(!jikanRatingIsAdult("{\"rating\":\"R - 17+ (violence & profanity)\"}"));
    try std.testing.expect(!jikanRatingIsAdult("{\"rating\":\"PG-13 - Teens 13 or older\"}"));
    try std.testing.expect(!jikanRatingIsAdult("{\"rating\":\"G - All Ages\"}"));
}

test "jikanRatingIsAdult tolerates missing/null rating" {
    try std.testing.expect(!jikanRatingIsAdult("{\"mal_id\":5,\"title\":\"no rating field\"}"));
    try std.testing.expect(!jikanRatingIsAdult("{\"rating\":null}"));
    try std.testing.expect(!jikanRatingIsAdult(""));
}

test "sfwSuffix" {
    // Jikan 504s on the `sfw` param, so we send none and filter adult entries
    // client-side (jikanRatingIsAdult) instead — suffix is empty regardless.
    try std.testing.expectEqualStrings("", sfwSuffix(true));
    try std.testing.expectEqualStrings("", sfwSuffix(false));
}

// ── Poster lifecycle ──────────────────────────────────────────────────
// A card's poster moves through: no URL → fetch → pixels decoded → texture
// uploaded (pixels freed). The grid re-evaluates this every frame from the
// row's flags alone, so those flags ARE the state machine — modelled here so
// the shipped decision is the tested one — the three render sites route
// through posterAction.

/// A card's poster flags, as the render loop observes them.
pub const PosterRow = struct {
    /// A fetch worker is in flight for this row.
    fetching: bool = false,
    /// A fetch was started for this row at some point.
    attempted: bool = false,
    /// Latched dead — a fetch ran and produced nothing renderable.
    failed: bool = false,
    /// Decoded pixels are waiting to be uploaded (freed once uploaded).
    has_pixels: bool = false,
    /// An uploaded GPU texture exists — the poster renders.
    has_tex: bool = false,
    /// The row has a poster URL to fetch.
    has_url: bool = false,
};

pub const PosterAction = enum {
    /// Nothing to do (already rendering, pixels pending upload, or latched).
    none,
    /// A worker is running — record that we tried.
    mark_attempted,
    /// A fetch ran and produced nothing: give up so we don't respawn forever.
    latch_failed,
    /// Kick off a fetch.
    fetch,
};

/// The grid's per-frame decision for one card's poster.
pub fn posterAction(r: PosterRow) PosterAction {
    if (r.has_tex) return .none;
    if (r.fetching) return .mark_attempted;
    // "Tried, not fetching, nothing to show" == the fetch failed. This is only
    // sound while `attempted` is cleared whenever the row's texture/pixels are
    // deliberately dropped by a parser — otherwise a row that loaded
    // fine and then had its texture retired by a reparse reads as failed here
    // and stays blank forever.
    if (r.attempted and !r.has_pixels and !r.has_tex) return .latch_failed;
    if (!r.failed and !r.has_pixels and r.has_url) return .fetch;
    return .none;
}

test "posterAction: normal lifecycle" {
    // Nothing yet → fetch.
    try std.testing.expectEqual(PosterAction.fetch, posterAction(.{ .has_url = true }));
    // No URL → nothing to fetch.
    try std.testing.expectEqual(PosterAction.none, posterAction(.{}));
    // Worker running → just record the attempt.
    try std.testing.expectEqual(PosterAction.mark_attempted, posterAction(.{ .fetching = true, .has_url = true }));
    // Pixels decoded, awaiting upload → don't refetch.
    try std.testing.expectEqual(PosterAction.none, posterAction(.{ .attempted = true, .has_pixels = true, .has_url = true }));
    // Uploaded → rendering.
    try std.testing.expectEqual(PosterAction.none, posterAction(.{ .attempted = true, .has_tex = true, .has_url = true }));
    // Latched dead → never respawn.
    try std.testing.expectEqual(PosterAction.none, posterAction(.{ .failed = true, .has_url = true }));
}

test "posterAction: a real failure still latches" {
    // Fetch ran, produced no pixels and no texture → give up (this is the
    // latch's reason to exist: don't respawn a worker every frame on a dead URL).
    try std.testing.expectEqual(
        PosterAction.latch_failed,
        posterAction(.{ .attempted = true, .has_url = true }),
    );
}

test "regression: retiring a loaded poster's texture must not latch it dead" {
    // The anime grid blanked on every SWR revalidate: the disk-cache seed's
    // posters loaded (texture uploaded, pixels freed), then the network reparse
    // retired those textures and reused the rows — but parseJikan cleared only
    // the texture, not attempted/failed.
    const loaded = PosterRow{ .attempted = true, .has_tex = true, .has_url = true };
    try std.testing.expectEqual(PosterAction.none, posterAction(loaded));

    // The bug: texture dropped, latch flags left set. The row is now
    // indistinguishable from a dead URL → latched blank forever, no refetch.
    var stale = loaded;
    stale.has_tex = false;
    try std.testing.expectEqual(PosterAction.latch_failed, posterAction(stale));

    // The fix: a parser retiring the texture clears attempted/failed with it,
    // so the row is back to "never loaded" and fetches again.
    var reset = stale;
    reset.attempted = false;
    reset.failed = false;
    try std.testing.expectEqual(PosterAction.fetch, posterAction(reset));
}
