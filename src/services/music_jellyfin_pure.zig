//! Jellyfin AUDIO engine — PURE, unit-tested. Third source of the Music tab
//! (0 = JioSaavn, 1 = Subsonic, 2 = Jellyfin, 3 = Plex).
//!
//! Jellyfin already has a full video client in `jellyfin.zig`; this module adds
//! ONLY the audio slice: the `/Items?IncludeItemTypes=Audio` search URL, the
//! `/Audio/{id}/universal` stream URL, and the `"Items":[…]` JSON extraction that
//! turns a response into `MusicSong` rows. Cover art is delegated to
//! `jellyfin_pure.primaryImageUrl` so the Music tab and the video tab can never
//! drift on image URLs.
//!
//! Auth: Jellyfin accepts `api_key=<token>` as a QUERY parameter (that's how an
//! `<img>`/mpv GET authenticates without a header), so every URL below carries
//! it. The token is never logged and must be excluded from cache keys.

const std = @import("std");
const jf_pure = @import("jellyfin_pure.zig");
const music = @import("music_subsonic_pure.zig");

pub const MusicSong = music.MusicSong;

/// A stable device id — Jellyfin's `universal` endpoint requires one to open a
/// playback session.
pub const DEVICE_ID = "opal-001";

// ── Validation ──

pub fn isValidBase(base: []const u8) bool {
    return music.isValidBase(base);
}

fn trimBase(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

/// Re-exported so callers percent-encode with the SAME table the URLs were
/// tested against (space/&/=/#/?/%/+ all escaped; only unreserved kept).
pub fn percentEncode(input: []const u8, out: []u8) usize {
    return music.percentEncode(input, out);
}

// ── URL builders ──

/// Audio search: `<base>/Items?IncludeItemTypes=Audio&Recursive=true&SearchTerm=…`.
/// `Recursive=true` is what makes the search span every library rather than the
/// root folder, and `Fields=…` pulls the album artist in on the same round trip.
pub fn buildSearchUrl(out: []u8, base: []const u8, api_key: []const u8, query: []const u8, limit: u32) ?[]const u8 {
    if (!isValidBase(base) or query.len == 0 or api_key.len == 0) return null;
    var enc: [512]u8 = undefined;
    const qn = percentEncode(query, &enc);
    if (qn == 0) return null;
    var ken: [256]u8 = undefined;
    const kn = percentEncode(api_key, &ken);
    return std.fmt.bufPrint(
        out,
        "{s}/Items?IncludeItemTypes=Audio&Recursive=true&SearchTerm={s}&Limit={d}&Fields=AlbumArtist&api_key={s}",
        .{ trimBase(base), enc[0..qn], limit, ken[0..kn] },
    ) catch null;
}

/// The playable audio URL. `static=true` tells Jellyfin to serve the ORIGINAL
/// bytes (no transcode, no session negotiation), which is exactly what mpv
/// wants — the transcoding variants of `universal` need a live playback session.
pub fn buildStreamUrl(out: []u8, base: []const u8, api_key: []const u8, item_id: []const u8) ?[]const u8 {
    if (!isValidBase(base) or api_key.len == 0) return null;
    if (!jf_pure.validItemId(item_id)) return null;
    var ken: [256]u8 = undefined;
    const kn = percentEncode(api_key, &ken);
    return std.fmt.bufPrint(
        out,
        "{s}/Audio/{s}/universal?api_key={s}&DeviceId={s}&static=true",
        .{ trimBase(base), item_id, ken[0..kn], DEVICE_ID },
    ) catch null;
}

/// Cover art — delegated to the shared Jellyfin image builder so the Music tab
/// and the video tab request (and cache) the same URL.
pub fn buildCoverUrl(out: []u8, base: []const u8, api_key: []const u8, item_id: []const u8) ?[]const u8 {
    if (!isValidBase(base) or api_key.len == 0) return null;
    if (!jf_pure.validItemId(item_id)) return null;
    return jf_pure.primaryImageUrl(trimBase(base), item_id, api_key, out);
}

// ── JSON extraction ──

/// The `"Items":[ … ]` slice of an /Items response, or "" when absent.
pub fn itemsScope(json: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, json, "\"Items\":[") orelse return "";
    return json[at..];
}

/// One track row (transient slices into the parse buffer).
pub const Song = struct {
    id: []const u8,
    title: []const u8,
    artist: []const u8,
};

/// Split the `"Items":[…]` scope into whole per-item objects by matching braces
/// (string- and escape-aware).
///
/// A marker-delimited split like Subsonic's (`"id":"` → next `"id":"`) is WRONG
/// here: Jellyfin emits `"Name"` BEFORE `"Id"` in each item, so a slice starting
/// at `"Id":"` would pick up the NEXT item's `"Name"` as its title, shifting
/// every title by one row. Brace matching keeps each object whole regardless of
/// field order. Bounds-safe on any truncated body (an unterminated final object
/// is dropped rather than emitted half-parsed).
pub const ItemIter = struct {
    json: []const u8,
    pos: usize = 0,
    started: bool = false,

    pub fn next(self: *ItemIter) ?[]const u8 {
        if (!self.started) {
            self.pos = (std.mem.indexOfScalarPos(u8, self.json, self.pos, '[') orelse return null) + 1;
            self.started = true;
        }
        const start = std.mem.indexOfScalarPos(u8, self.json, self.pos, '{') orelse return null;
        var depth: usize = 0;
        var in_str = false;
        var i = start;
        while (i < self.json.len) : (i += 1) {
            const c = self.json[i];
            if (in_str) {
                if (c == '\\') {
                    i += 1;
                } else if (c == '"') in_str = false;
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        self.pos = i + 1;
                        return self.json[start .. i + 1];
                    }
                },
                else => {},
            }
        }
        self.pos = self.json.len;
        return null; // truncated tail
    }
};

/// Extract id/title/artist from one item slice. Null without an id or a name.
/// Artist prefers `AlbumArtist`, falling back to the first entry of `Artists`.
pub fn parseSong(obj: []const u8, id_buf: []u8, title_buf: []u8, artist_buf: []u8) ?Song {
    const idn = music.jsonStr(obj, "\"Id\":\"", id_buf);
    if (idn == 0) return null;
    const tn = music.jsonStr(obj, "\"Name\":\"", title_buf);
    if (tn == 0) return null;
    var an = music.jsonStr(obj, "\"AlbumArtist\":\"", artist_buf);
    if (an == 0) an = music.jsonStr(obj, "\"Artists\":[\"", artist_buf);
    return .{ .id = id_buf[0..idn], .title = title_buf[0..tn], .artist = artist_buf[0..an] };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "search URL: audio-only, recursive, trailing slash trimmed" {
    var b: [700]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://nas:8096/Items?IncludeItemTypes=Audio&Recursive=true&SearchTerm=daft%20punk&Limit=50&Fields=AlbumArtist&api_key=abc123",
        buildSearchUrl(&b, "http://nas:8096/", "abc123", "daft punk", 50).?,
    );
}

test "search URL percent-encodes every reserved char (space & = # ? % +)" {
    var b: [700]u8 = undefined;
    const u = buildSearchUrl(&b, "http://nas:8096", "k", "a b&c=d#e?f%g+h", 10).?;
    try std.testing.expect(std.mem.indexOf(u8, u, "SearchTerm=a%20b%26c%3Dd%23e%3Ff%25g%2Bh&") != null);
}

test "auth token rides the query, not a header, on every URL" {
    var b: [700]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, buildSearchUrl(&b, "http://n:8096", "tok", "x", 5).?, "api_key=tok") != null);
    var c: [700]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, buildStreamUrl(&c, "http://n:8096", "tok", "abc").?, "api_key=tok") != null);
    var d: [700]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, buildCoverUrl(&d, "http://n:8096", "tok", "abc").?, "api_key=tok") != null);
}

test "stream URL is the static (untranscoded) universal endpoint" {
    var b: [700]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://nas:8096/Audio/f1e2d3/universal?api_key=abc&DeviceId=opal-001&static=true",
        buildStreamUrl(&b, "http://nas:8096", "abc", "f1e2d3").?,
    );
}

test "cover URL matches the shared jellyfin_pure builder (no drift)" {
    var b: [700]u8 = undefined;
    var c: [700]u8 = undefined;
    try std.testing.expectEqualStrings(
        jf_pure.primaryImageUrl("http://nas:8096", "f1e2d3", "abc", &c).?,
        buildCoverUrl(&b, "http://nas:8096/", "abc", "f1e2d3").?,
    );
}

test "URL builders reject a bad base, an empty key, and a path-escaping id" {
    var b: [700]u8 = undefined;
    try std.testing.expect(buildSearchUrl(&b, "ftp://x", "k", "q", 5) == null);
    try std.testing.expect(buildSearchUrl(&b, "http://nas:8096", "", "q", 5) == null);
    try std.testing.expect(buildSearchUrl(&b, "http://nas:8096", "k", "", 5) == null);
    // An id carrying `?`/`/` would splice extra path or query segments in.
    try std.testing.expect(buildStreamUrl(&b, "http://nas:8096", "k", "a/../x") == null);
    try std.testing.expect(buildStreamUrl(&b, "http://nas:8096", "k", "a?b=c") == null);
    try std.testing.expect(buildCoverUrl(&b, "http://nas:8096", "k", "") == null);
}

test "parse an /Items audio response (AlbumArtist, then Artists fallback)" {
    const json =
        \\{"Items":[
        \\{"Name":"One More Time","ServerId":"s1","Id":"tr1","AlbumId":"al9","AlbumArtist":"Daft Punk","Type":"Audio"},
        \\{"Name":"Aerodynamic","ServerId":"s1","Id":"tr2","Artists":["Daft Punk"],"Type":"Audio"}],
        \\"TotalRecordCount":2}
    ;
    const scope = itemsScope(json);
    try std.testing.expect(scope.len > 0);
    var it = ItemIter{ .json = scope };
    var idb: [128]u8 = undefined;
    var tb: [160]u8 = undefined;
    var ab: [128]u8 = undefined;
    const s0 = parseSong(it.next().?, &idb, &tb, &ab).?;
    try std.testing.expectEqualStrings("tr1", s0.id);
    try std.testing.expectEqualStrings("One More Time", s0.title);
    try std.testing.expectEqualStrings("Daft Punk", s0.artist);
    const s1 = parseSong(it.next().?, &idb, &tb, &ab).?;
    try std.testing.expectEqualStrings("tr2", s1.id);
    try std.testing.expectEqualStrings("Aerodynamic", s1.title);
    try std.testing.expectEqualStrings("Daft Punk", s1.artist); // Artists[0] fallback
    try std.testing.expect(it.next() == null);
}

test "regression: AlbumId/ServerId must not be read as the item id" {
    // `"AlbumId":"` ends in `Id":"` — a marker without its own opening quote
    // would split objects on it and hand the ALBUM id to the stream URL.
    const json = "{\"Items\":[{\"Name\":\"T\",\"AlbumId\":\"al9\",\"ServerId\":\"s1\",\"Id\":\"tr1\"}]}";
    var it = ItemIter{ .json = itemsScope(json) };
    var idb: [128]u8 = undefined;
    var tb: [160]u8 = undefined;
    var ab: [128]u8 = undefined;
    const s = parseSong(it.next().?, &idb, &tb, &ab).?;
    try std.testing.expectEqualStrings("tr1", s.id);
    try std.testing.expect(it.next() == null);
}

test "regression: Name-before-Id field order must not shift titles by one row" {
    // Jellyfin emits "Name" first. A marker split on `"Id":"` gave row 0 the id
    // of track 1 paired with the NAME of track 2 (every title off by one, the
    // last row losing its title entirely).
    const json =
        \\{"Items":[{"Name":"First","Id":"tr1"},{"Name":"Second","Id":"tr2"}]}
    ;
    var it = ItemIter{ .json = itemsScope(json) };
    var idb: [128]u8 = undefined;
    var tb: [160]u8 = undefined;
    var ab: [128]u8 = undefined;
    const s0 = parseSong(it.next().?, &idb, &tb, &ab).?;
    try std.testing.expectEqualStrings("tr1", s0.id);
    try std.testing.expectEqualStrings("First", s0.title);
    const s1 = parseSong(it.next().?, &idb, &tb, &ab).?;
    try std.testing.expectEqualStrings("tr2", s1.id);
    try std.testing.expectEqualStrings("Second", s1.title);
    try std.testing.expect(it.next() == null);
}

test "empty and malformed bodies yield no rows and never trap" {
    try std.testing.expectEqualStrings("", itemsScope(""));
    try std.testing.expectEqualStrings("", itemsScope("not json at all"));
    try std.testing.expectEqualStrings("", itemsScope("{\"TotalRecordCount\":0}"));
    var idb: [128]u8 = undefined;
    var tb: [160]u8 = undefined;
    var ab: [128]u8 = undefined;
    // Truncated mid-object: the unterminated object is dropped, not half-parsed.
    var it = ItemIter{ .json = itemsScope("{\"Items\":[{\"Id\":\"tr1\"") };
    try std.testing.expect(it.next() == null);
    // No id at all.
    try std.testing.expect(parseSong("{\"Name\":\"x\"}", &idb, &tb, &ab) == null);
    var none = ItemIter{ .json = "" };
    try std.testing.expect(none.next() == null);
}
