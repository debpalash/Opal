//! Plex AUDIO engine — PURE, unit-tested. Fourth source of the Music tab
//! (0 = JioSaavn, 1 = Subsonic, 2 = Jellyfin, 3 = Plex).
//!
//! `plex.zig` owns the video library and the PIN sign-in; this module adds only
//! the audio slice: the `/search?type=10` (10 = track) URL, the stream URL built
//! from a track's `Part.key`, the `thumb` cover URL, and the `MediaContainer`
//! extraction that turns a response into `MusicSong` rows.
//!
//! Response format: Plex serves XML unless the request asks for JSON, and
//! `plex.zig`'s own `httpGet` already sends `Accept: application/json` — the
//! Music worker sends the same header, so the parser below is JSON-only and the
//! two clients stay on one format.
//!
//! Auth: `X-Plex-Token` in the QUERY (mpv and the poster daemon issue plain GETs
//! with no header). The token is never logged and never placed in a cache key.

const std = @import("std");
const music = @import("music_subsonic_pure.zig");

pub const MusicSong = music.MusicSong;

/// Plex library type 10 = track. (8 = artist, 9 = album.)
pub const TYPE_TRACK: u32 = 10;

// ── Validation ──

pub fn isValidBase(base: []const u8) bool {
    return music.isValidBase(base);
}

fn trimBase(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

/// Re-exported so callers percent-encode with the SAME table these URLs were
/// tested against (space/&/=/#/?/%/+ escaped; only unreserved kept).
pub fn percentEncode(input: []const u8, out: []u8) usize {
    return music.percentEncode(input, out);
}

/// A `Part.key` / `thumb` is a server-relative path we splice onto the base. It
/// MUST start with `/` and carry no scheme, no `..`, and no query of its own —
/// otherwise a hostile/garbled response could redirect the request to another
/// host or append parameters ahead of the token.
pub fn isValidPath(p: []const u8) bool {
    if (p.len < 2 or p.len > 200 or p[0] != '/') return false;
    if (std.mem.indexOf(u8, p, "..") != null) return false;
    if (std.mem.indexOf(u8, p, "//") != null) return false;
    for (p) |c| {
        if (c <= ' ' or c == '?' or c == '#' or c == '%' or c == '&' or c == '"' or c == '\\') return false;
    }
    return true;
}

// ── URL builders ──

/// Track search: `<base>/search?query=…&type=10&limit=…&X-Plex-Token=…`.
pub fn buildSearchUrl(out: []u8, base: []const u8, token: []const u8, query: []const u8, limit: u32) ?[]const u8 {
    if (!isValidBase(base) or query.len == 0 or token.len == 0) return null;
    var enc: [512]u8 = undefined;
    const qn = percentEncode(query, &enc);
    if (qn == 0) return null;
    var ten: [256]u8 = undefined;
    const tn = percentEncode(token, &ten);
    return std.fmt.bufPrint(
        out,
        "{s}/search?query={s}&type={d}&limit={d}&X-Plex-Token={s}",
        .{ trimBase(base), enc[0..qn], TYPE_TRACK, limit, ten[0..tn] },
    ) catch null;
}

/// The playable audio URL: the track's `Part.key` appended to the base, with the
/// token as the only query parameter. Plex streams the original file bytes at
/// this path, so mpv gets no transcode.
pub fn buildStreamUrl(out: []u8, base: []const u8, token: []const u8, part_key: []const u8) ?[]const u8 {
    if (!isValidBase(base) or token.len == 0 or !isValidPath(part_key)) return null;
    var ten: [256]u8 = undefined;
    const tn = percentEncode(token, &ten);
    return std.fmt.bufPrint(out, "{s}{s}?X-Plex-Token={s}", .{ trimBase(base), part_key, ten[0..tn] }) catch null;
}

/// Cover art: the track's `thumb` path (already a server-rendered image).
pub fn buildCoverUrl(out: []u8, base: []const u8, token: []const u8, thumb: []const u8) ?[]const u8 {
    return buildStreamUrl(out, base, token, thumb);
}

// ── Persisted credentials (~/.config/opal/plex.json, written by plex.zig) ──

/// Server URI + access token read out of the file `plex.zig` saves, so the Music
/// tab reuses the existing Plex sign-in instead of asking for a second one.
/// `server_token` is the per-server token; the account token is the fallback,
/// matching `plex.zig`'s own `serverTok()`.
pub const Creds = struct { base: []const u8, token: []const u8 };

pub fn parseCreds(json: []const u8, base_buf: []u8, token_buf: []u8) ?Creds {
    const bn = music.jsonStr(json, "\"server\":\"", base_buf);
    if (bn == 0) return null;
    var tn = music.jsonStr(json, "\"server_token\":\"", token_buf);
    if (tn == 0) tn = music.jsonStr(json, "\"token\":\"", token_buf);
    if (tn == 0) return null;
    if (!isValidBase(base_buf[0..bn])) return null;
    return .{ .base = base_buf[0..bn], .token = token_buf[0..tn] };
}

// ── JSON extraction ──

/// The `"Metadata":[ … ]` slice of a MediaContainer, or "" when the search
/// matched nothing (Plex omits the array entirely rather than sending `[]`).
pub fn metadataScope(json: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, json, "\"Metadata\":[") orelse return "";
    return json[at..];
}

/// One track row (transient slices into the parse buffer).
pub const Song = struct {
    id: []const u8,
    title: []const u8,
    artist: []const u8,
    thumb: []const u8,
    part_key: []const u8,
};

/// Split `"Metadata":[…]` into whole objects by matching braces (string- and
/// escape-aware). Depth matters here more than anywhere else: each track nests
/// `Media[].Part[]`, so a flat marker split would slice a track in half and lose
/// its `Part.key` — i.e. the stream URL. A truncated tail is dropped.
pub const TrackIter = struct {
    json: []const u8,
    pos: usize = 0,
    started: bool = false,

    pub fn next(self: *TrackIter) ?[]const u8 {
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
        return null;
    }
};

/// Extract ratingKey/title/grandparentTitle/thumb/Part.key from one track
/// object. Null without a ratingKey or a title.
///
/// `part_key` is read from AFTER the `"Part":` marker on purpose: a Metadata
/// object has its OWN top-level `"key"` (`/library/metadata/123`), which is a
/// metadata endpoint, not audio — handing that to mpv plays nothing.
pub fn parseSong(
    obj: []const u8,
    id_buf: []u8,
    title_buf: []u8,
    artist_buf: []u8,
    thumb_buf: []u8,
    part_buf: []u8,
) ?Song {
    const idn = music.jsonStr(obj, "\"ratingKey\":\"", id_buf);
    if (idn == 0) return null;
    const tn = music.jsonStr(obj, "\"title\":\"", title_buf);
    if (tn == 0) return null;
    const an = music.jsonStr(obj, "\"grandparentTitle\":\"", artist_buf);
    const cn = music.jsonStr(obj, "\"thumb\":\"", thumb_buf);
    var pn: usize = 0;
    if (std.mem.indexOf(u8, obj, "\"Part\":")) |at| {
        pn = music.jsonStr(obj[at..], "\"key\":\"", part_buf);
    }
    return .{
        .id = id_buf[0..idn],
        .title = title_buf[0..tn],
        .artist = artist_buf[0..an],
        .thumb = thumb_buf[0..cn],
        .part_key = part_buf[0..pn],
    };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "search URL asks for type=10 (tracks) and trims a trailing slash" {
    var b: [700]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://plex:32400/search?query=daft%20punk&type=10&limit=50&X-Plex-Token=tok123",
        buildSearchUrl(&b, "http://plex:32400/", "tok123", "daft punk", 50).?,
    );
}

test "search URL percent-encodes every reserved char (space & = # ? % +)" {
    var b: [700]u8 = undefined;
    const u = buildSearchUrl(&b, "http://plex:32400", "t", "a b&c=d#e?f%g+h", 10).?;
    try std.testing.expect(std.mem.indexOf(u8, u, "query=a%20b%26c%3Dd%23e%3Ff%25g%2Bh&") != null);
}

test "the token rides the query on stream and cover URLs too" {
    var b: [700]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://plex:32400/library/parts/45/file.mp3?X-Plex-Token=tok",
        buildStreamUrl(&b, "http://plex:32400", "tok", "/library/parts/45/file.mp3").?,
    );
    var c: [700]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://plex:32400/library/metadata/120/thumb/1?X-Plex-Token=tok",
        buildCoverUrl(&c, "http://plex:32400/", "tok", "/library/metadata/120/thumb/1").?,
    );
}

test "a token needing escapes is encoded, not spliced raw into the query" {
    var b: [700]u8 = undefined;
    const u = buildStreamUrl(&b, "http://plex:32400", "a b&x", "/p/1.mp3").?;
    try std.testing.expectEqualStrings("http://plex:32400/p/1.mp3?X-Plex-Token=a%20b%26x", u);
}

test "URL builders reject a bad base, an empty token, and a hostile path" {
    var b: [700]u8 = undefined;
    try std.testing.expect(buildSearchUrl(&b, "ftp://x", "t", "q", 5) == null);
    try std.testing.expect(buildSearchUrl(&b, "http://plex:32400", "", "q", 5) == null);
    try std.testing.expect(buildSearchUrl(&b, "http://plex:32400", "t", "", 5) == null);
    // Anything that could leave the server or pre-empt the token param.
    try std.testing.expect(!isValidPath("library/parts/1")); // relative
    try std.testing.expect(!isValidPath("/../../etc/passwd"));
    try std.testing.expect(!isValidPath("//evil.example.com/x")); // protocol-relative
    try std.testing.expect(!isValidPath("/p?X-Plex-Token=stolen"));
    try std.testing.expect(!isValidPath("/p 1.mp3"));
    try std.testing.expect(!isValidPath(""));
    try std.testing.expect(isValidPath("/library/parts/45/file.mp3"));
    try std.testing.expect(buildStreamUrl(&b, "http://plex:32400", "t", "/../x") == null);
}

test "parse a /search?type=10 MediaContainer into tracks" {
    const json =
        \\{"MediaContainer":{"size":2,"Metadata":[
        \\{"ratingKey":"301","key":"/library/metadata/301","parentRatingKey":"300","grandparentRatingKey":"290",
        \\"title":"One More Time","parentTitle":"Discovery","grandparentTitle":"Daft Punk","type":"track",
        \\"thumb":"/library/metadata/300/thumb/1",
        \\"Media":[{"id":11,"Part":[{"id":12,"key":"/library/parts/45/file.mp3","container":"mp3"}]}]},
        \\{"ratingKey":"302","key":"/library/metadata/302","title":"Aerodynamic","grandparentTitle":"Daft Punk",
        \\"type":"track","Media":[{"id":13,"Part":[{"id":14,"key":"/library/parts/46/file.flac"}]}]}]}}
    ;
    const scope = metadataScope(json);
    try std.testing.expect(scope.len > 0);
    var it = TrackIter{ .json = scope };
    var idb: [128]u8 = undefined;
    var tb: [160]u8 = undefined;
    var ab: [128]u8 = undefined;
    var cb: [200]u8 = undefined;
    var pb: [256]u8 = undefined;
    const s0 = parseSong(it.next().?, &idb, &tb, &ab, &cb, &pb).?;
    try std.testing.expectEqualStrings("301", s0.id);
    try std.testing.expectEqualStrings("One More Time", s0.title);
    try std.testing.expectEqualStrings("Daft Punk", s0.artist);
    try std.testing.expectEqualStrings("/library/metadata/300/thumb/1", s0.thumb);
    try std.testing.expectEqualStrings("/library/parts/45/file.mp3", s0.part_key);
    const s1 = parseSong(it.next().?, &idb, &tb, &ab, &cb, &pb).?;
    try std.testing.expectEqualStrings("302", s1.id);
    try std.testing.expectEqualStrings("/library/parts/46/file.flac", s1.part_key);
    try std.testing.expectEqualStrings("", s1.thumb); // absent thumb is empty, not junk
    try std.testing.expect(it.next() == null);
}

test "regression: the stream URL comes from Part.key, not the Metadata key" {
    // A Metadata object's own "key" is /library/metadata/<id> — a metadata
    // endpoint. Reading it as the stream would hand mpv XML instead of audio.
    const obj =
        \\{"ratingKey":"301","key":"/library/metadata/301","title":"T",
        \\"Media":[{"Part":[{"key":"/library/parts/45/file.mp3"}]}]}
    ;
    var idb: [128]u8 = undefined;
    var tb: [160]u8 = undefined;
    var ab: [128]u8 = undefined;
    var cb: [200]u8 = undefined;
    var pb: [256]u8 = undefined;
    const s = parseSong(obj, &idb, &tb, &ab, &cb, &pb).?;
    try std.testing.expectEqualStrings("/library/parts/45/file.mp3", s.part_key);
}

test "regression: parentTitle/grandparentRatingKey must not shadow title/ratingKey" {
    const obj =
        \\{"ratingKey":"301","grandparentRatingKey":"290","parentTitle":"Discovery",
        \\"title":"One More Time","grandparentTitle":"Daft Punk"}
    ;
    var idb: [128]u8 = undefined;
    var tb: [160]u8 = undefined;
    var ab: [128]u8 = undefined;
    var cb: [200]u8 = undefined;
    var pb: [256]u8 = undefined;
    const s = parseSong(obj, &idb, &tb, &ab, &cb, &pb).?;
    try std.testing.expectEqualStrings("301", s.id);
    try std.testing.expectEqualStrings("One More Time", s.title);
    try std.testing.expectEqualStrings("Daft Punk", s.artist);
}

test "creds come from the plex.json plex.zig writes (server_token preferred)" {
    var bb: [256]u8 = undefined;
    var tb: [160]u8 = undefined;
    const c = parseCreds(
        "{\"token\":\"acct\",\"server\":\"http://plex:32400\",\"server_token\":\"srv\",\"name\":\"NAS\"}",
        &bb,
        &tb,
    ).?;
    try std.testing.expectEqualStrings("http://plex:32400", c.base);
    try std.testing.expectEqualStrings("srv", c.token);
    // Account token is the fallback (plex.zig's serverTok() does the same).
    const c2 = parseCreds("{\"token\":\"acct\",\"server\":\"http://plex:32400\"}", &bb, &tb).?;
    try std.testing.expectEqualStrings("acct", c2.token);
}

test "creds: signed-out / empty / malformed plex.json is null (tab stays inert)" {
    var bb: [256]u8 = undefined;
    var tb: [160]u8 = undefined;
    try std.testing.expect(parseCreds("", &bb, &tb) == null);
    try std.testing.expect(parseCreds("{}", &bb, &tb) == null);
    try std.testing.expect(parseCreds("{\"server\":\"http://plex:32400\"}", &bb, &tb) == null); // no token
    try std.testing.expect(parseCreds("{\"token\":\"t\",\"server\":\"\"}", &bb, &tb) == null); // signed out
    try std.testing.expect(parseCreds("{\"token\":\"t\",\"server\":\"nonsense\"}", &bb, &tb) == null);
}

test "empty and malformed bodies yield no rows and never trap" {
    try std.testing.expectEqualStrings("", metadataScope(""));
    try std.testing.expectEqualStrings("", metadataScope("<MediaContainer size=\"0\"/>")); // XML fallback path
    try std.testing.expectEqualStrings("", metadataScope("{\"MediaContainer\":{\"size\":0}}"));
    var it = TrackIter{ .json = metadataScope("{\"MediaContainer\":{\"Metadata\":[{\"ratingKey\":\"1\"") };
    try std.testing.expect(it.next() == null); // truncated tail dropped
    var idb: [128]u8 = undefined;
    var tb: [160]u8 = undefined;
    var ab: [128]u8 = undefined;
    var cb: [200]u8 = undefined;
    var pb: [256]u8 = undefined;
    try std.testing.expect(parseSong("{\"title\":\"x\"}", &idb, &tb, &ab, &cb, &pb) == null);
    try std.testing.expect(parseSong("{\"ratingKey\":\"1\"}", &idb, &tb, &ab, &cb, &pb) == null);
    var none = TrackIter{ .json = "" };
    try std.testing.expect(none.next() == null);
}
