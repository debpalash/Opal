//! Subsonic / OpenSubsonic music engine — PURE, unit-tested.
//!
//! The self-hosted music standard: ONE engine transparently covers Navidrome,
//! Airsonic, Gonic, Funkwhale, and Ampache (all speak the Subsonic REST API).
//! Keyless `token+salt` auth (no OAuth, no app registration), and the `stream`
//! endpoint returns audio bytes you hand straight to mpv — no transcode, no
//! signatures, no second call. This module owns only URL building + the auth
//! token + JSON extraction; fetch/state/threading live in the non-pure sibling,
//! so the shipped requests are the tested requests (twin of the Suwayomi engine).
//!
//! Auth (subsonic.org): pick a random ≥6-char `salt`; `token = md5(password ++
//! salt)` as lowercase hex. Every request carries
//!   u=<user>&t=<token>&s=<salt>&v=1.16.1&c=Opal&f=json
//! The password/token is NEVER logged and must be excluded from cache keys.

const std = @import("std");

pub const API_VERSION = "1.16.1";
pub const CLIENT = "Opal";

/// `subsonic:` pseudo-URL scheme — a track card stores `subsonic:<songId>`; the
/// player resolves it to a `stream` URL. (Kept parallel to the other engines'
/// scheme routing, though the music tab plays directly.)
pub const SCHEME = "subsonic:";

// ── Validation gates ──

/// The server base must be a plain http(s) origin we can safely prefix onto
/// `/rest/...`. A trailing slash is trimmed by the builders.
pub fn isValidBase(base: []const u8) bool {
    return (std.mem.startsWith(u8, base, "http://") or std.mem.startsWith(u8, base, "https://")) and
        base.len > 8 and base.len < 512 and
        std.mem.indexOfScalar(u8, base, ' ') == null;
}

fn trimBase(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

// ── Percent-encoding (unreserved kept; also curl-glob-safe) ──

pub fn percentEncode(input: []const u8, out: []u8) usize {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (input) |ch| {
        if (n + 3 > out.len) break;
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~')
        {
            out[n] = ch;
            n += 1;
        } else {
            out[n] = '%';
            out[n + 1] = hex[ch >> 4];
            out[n + 2] = hex[ch & 0xF];
            n += 3;
        }
    }
    return n;
}

// ── Auth token ──

/// `token = md5(password ++ salt)` as 32 lowercase hex chars, written to `out`.
/// Pure given the salt (the salt itself is generated once per session in the
/// impure layer via std.crypto.random).
pub fn authToken(password: []const u8, salt: []const u8, out: *[32]u8) void {
    var h = std.crypto.hash.Md5.init(.{});
    h.update(password);
    h.update(salt);
    var digest: [16]u8 = undefined;
    h.final(&digest);
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xF];
    }
}

/// The shared auth query fragment `u=&t=&s=&v=&c=&f=json` (no leading `?`/`&`).
/// `salt` and `token` are hex (safe); the username is percent-encoded. Returns
/// the written slice (or "" if `out` is too small).
pub fn buildAuthQuery(user: []const u8, token: []const u8, salt: []const u8, out: []u8) []const u8 {
    var enc: [128]u8 = undefined;
    const un = percentEncode(user, &enc);
    return std.fmt.bufPrint(out, "u={s}&t={s}&s={s}&v={s}&c={s}&f=json", .{ enc[0..un], token, salt, API_VERSION, CLIENT }) catch "";
}

// ── URL builders ──

/// Connectivity/auth test: `<base>/rest/ping?<authq>`.
pub fn buildPingUrl(out: []u8, base: []const u8, authq: []const u8) ?[]const u8 {
    if (!isValidBase(base)) return null;
    return std.fmt.bufPrint(out, "{s}/rest/ping?{s}", .{ trimBase(base), authq }) catch null;
}

/// Search: `<base>/rest/search3?query=&songCount=&<authq>`.
pub fn buildSearchUrl(out: []u8, base: []const u8, authq: []const u8, query: []const u8, song_count: u32) ?[]const u8 {
    if (!isValidBase(base) or query.len == 0) return null;
    var enc: [512]u8 = undefined;
    const qn = percentEncode(query, &enc);
    if (qn == 0) return null;
    return std.fmt.bufPrint(out, "{s}/rest/search3?query={s}&songCount={d}&artistCount=0&albumCount=0&{s}", .{ trimBase(base), enc[0..qn], song_count, authq }) catch null;
}

/// The playable audio URL for a song — `format=raw` tells the server NOT to
/// transcode, so mpv gets the original bytes. Hand this straight to load_file.
pub fn buildStreamUrl(out: []u8, base: []const u8, authq: []const u8, song_id: []const u8) ?[]const u8 {
    if (!isValidBase(base) or song_id.len == 0) return null;
    var enc: [128]u8 = undefined;
    const idn = percentEncode(song_id, &enc);
    return std.fmt.bufPrint(out, "{s}/rest/stream?id={s}&format=raw&{s}", .{ trimBase(base), enc[0..idn], authq }) catch null;
}

/// Cover art (server-rendered thumbnail).
pub fn buildCoverUrl(out: []u8, base: []const u8, authq: []const u8, cover_id: []const u8, size: u32) ?[]const u8 {
    if (!isValidBase(base) or cover_id.len == 0) return null;
    var enc: [128]u8 = undefined;
    const cn = percentEncode(cover_id, &enc);
    return std.fmt.bufPrint(out, "{s}/rest/getCoverArt?id={s}&size={d}&{s}", .{ trimBase(base), enc[0..cn], size, authq }) catch null;
}

// ── Route round-trip (subsonic:<songId>) ──

pub fn buildRouteUrl(out: []u8, song_id: []const u8) ?[]const u8 {
    if (song_id.len == 0 or song_id.len > 256) return null;
    return std.fmt.bufPrint(out, "{s}{s}", .{ SCHEME, song_id }) catch null;
}

pub fn songIdFromRoute(url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, SCHEME)) return null;
    const id = url[SCHEME.len..];
    if (id.len == 0) return null;
    return id;
}

// ── JSON extraction ──

/// Read a JSON string field `"key":"…"` from `scope` into `dst` (bytes written,
/// 0 if absent). Bounds-safe; stops at the first unescaped quote.
pub fn jsonStr(scope: []const u8, key: []const u8, dst: []u8) usize {
    const at = std.mem.indexOf(u8, scope, key) orelse return 0;
    var i = at + key.len;
    var out: usize = 0;
    while (i < scope.len and out < dst.len) : (i += 1) {
        const c = scope[i];
        if (c == '\\' and i + 1 < scope.len) {
            dst[out] = scope[i + 1];
            out += 1;
            i += 1;
            continue;
        }
        if (c == '"') break;
        dst[out] = c;
        out += 1;
    }
    return out;
}

/// The `"song":[ … ]` slice of a search3 response — songs come last in
/// searchResult3 (after artist/album), so from `"song":[` to end is all songs.
/// Empty when the response carried no song array.
pub fn songsScope(json: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, json, "\"song\":[") orelse return "";
    return json[at..];
}

/// One track row (transient slices into a parse buffer).
pub const Song = struct {
    id: []const u8,
    title: []const u8,
    artist: []const u8,
    cover: []const u8, // coverArt id (may be empty)
};

/// Fixed-buffer track record (shared with state.zig; no dvui/atomics so
/// std.mem.zeroes works). Matches Opal's `[N]u8`+len state convention. Shared by
/// BOTH music sources: Subsonic fills `id` (+ `cover` = coverArt id, resolved
/// with creds at render), JioSaavn fills `play_url` (perma_url for mpv/yt-dlp) +
/// `cover` (a full image URL). The active source (state.app.music.source) picks
/// how each field is used.
pub const MusicSong = struct {
    id: [128]u8 = std.mem.zeroes([128]u8),
    id_len: usize = 0,
    title: [160]u8 = std.mem.zeroes([160]u8),
    title_len: usize = 0,
    artist: [128]u8 = std.mem.zeroes([128]u8),
    artist_len: usize = 0,
    cover: [200]u8 = std.mem.zeroes([200]u8),
    cover_len: usize = 0,
    play_url: [256]u8 = std.mem.zeroes([256]u8),
    play_url_len: usize = 0,
};

/// Iterate the objects of a `"song":[ … ]` scope, delimited by each object's
/// `"id":` (present once per song). Bounds-safe on any malformed/truncated body.
pub const SongIter = struct {
    json: []const u8,
    pos: usize = 0,
    const marker = "\"id\":\"";

    pub fn next(self: *SongIter) ?[]const u8 {
        const at = std.mem.indexOfPos(u8, self.json, self.pos, marker) orelse return null;
        var end = self.json.len;
        if (std.mem.indexOfPos(u8, self.json, at + marker.len, marker)) |n| end = n;
        self.pos = end;
        return self.json[at..end];
    }
};

/// Extract id/title/artist/cover from one song object slice into caller buffers.
/// Null when there's no id or title.
pub fn parseSong(obj: []const u8, id_buf: []u8, title_buf: []u8, artist_buf: []u8, cover_buf: []u8) ?Song {
    const idn = jsonStr(obj, "\"id\":\"", id_buf);
    if (idn == 0) return null;
    const tn = jsonStr(obj, "\"title\":\"", title_buf);
    if (tn == 0) return null;
    const an = jsonStr(obj, "\"artist\":\"", artist_buf);
    const cn = jsonStr(obj, "\"coverArt\":\"", cover_buf);
    return .{ .id = id_buf[0..idn], .title = title_buf[0..tn], .artist = artist_buf[0..an], .cover = cover_buf[0..cn] };
}

/// True when a `/rest/ping` (or any) response reports success
/// (`"status":"ok"`). A failed auth returns `"status":"failed"` + an error.
pub fn responseOk(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"status\":\"ok\"") != null;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "authToken = md5(password ++ salt), lowercase hex (subsonic.org example)" {
    // subsonic.org documents: password "sesame", salt "c19b2d" → token
    // "26719a1196d2a940705a59634eb18eab".
    var tok: [32]u8 = undefined;
    authToken("sesame", "c19b2d", &tok);
    try std.testing.expectEqualStrings("26719a1196d2a940705a59634eb18eab", &tok);
}

test "buildAuthQuery encodes the user, carries version/client/json" {
    var tok: [32]u8 = undefined;
    authToken("sesame", "c19b2d", &tok);
    var q: [256]u8 = undefined;
    const authq = buildAuthQuery("joe user", &tok, "c19b2d", &q);
    try std.testing.expectEqualStrings("u=joe%20user&t=26719a1196d2a940705a59634eb18eab&s=c19b2d&v=1.16.1&c=Opal&f=json", authq);
}

test "URL builders produce the Subsonic REST paths (trimming a trailing slash)" {
    var b: [512]u8 = undefined;
    const authq = "u=joe&t=abc&s=def&v=1.16.1&c=Opal&f=json";
    try std.testing.expectEqualStrings(
        "http://nas:4040/rest/ping?u=joe&t=abc&s=def&v=1.16.1&c=Opal&f=json",
        buildPingUrl(&b, "http://nas:4040/", authq).?,
    );
    try std.testing.expectEqualStrings(
        "http://nas:4040/rest/search3?query=daft%20punk&songCount=50&artistCount=0&albumCount=0&u=joe&t=abc&s=def&v=1.16.1&c=Opal&f=json",
        buildSearchUrl(&b, "http://nas:4040", authq, "daft punk", 50).?,
    );
    try std.testing.expectEqualStrings(
        "http://nas:4040/rest/stream?id=300&format=raw&u=joe&t=abc&s=def&v=1.16.1&c=Opal&f=json",
        buildStreamUrl(&b, "http://nas:4040", authq, "300").?,
    );
    try std.testing.expectEqualStrings(
        "http://nas:4040/rest/getCoverArt?id=al-5&size=300&u=joe&t=abc&s=def&v=1.16.1&c=Opal&f=json",
        buildCoverUrl(&b, "http://nas:4040", authq, "al-5", 300).?,
    );
    try std.testing.expect(buildPingUrl(&b, "ftp://x", authq) == null);
}

test "route round-trips subsonic:<id>" {
    var b: [300]u8 = undefined;
    const r = buildRouteUrl(&b, "tr-42").?;
    try std.testing.expectEqualStrings("subsonic:tr-42", r);
    try std.testing.expectEqualStrings("tr-42", songIdFromRoute(r).?);
    try std.testing.expect(songIdFromRoute("mangadex:x") == null);
}

test "parse search3 song rows (scoped to the song array)" {
    const json =
        \\{"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
        \\"artist":[{"id":"ar-1","name":"Daft Punk"}],
        \\"album":[{"id":"al-9","name":"Discovery","coverArt":"al-9"}],
        \\"song":[
        \\{"id":"tr-1","title":"One More Time","artist":"Daft Punk","album":"Discovery","coverArt":"al-9","duration":320},
        \\{"id":"tr-2","title":"Aerodynamic","artist":"Daft Punk","coverArt":"al-9","duration":212}]}}}
    ;
    const scope = songsScope(json);
    try std.testing.expect(scope.len > 0);
    var it = SongIter{ .json = scope };
    var idb: [64]u8 = undefined;
    var tb: [128]u8 = undefined;
    var ab: [128]u8 = undefined;
    var cb: [64]u8 = undefined;
    const s0 = parseSong(it.next().?, &idb, &tb, &ab, &cb).?;
    try std.testing.expectEqualStrings("tr-1", s0.id);
    try std.testing.expectEqualStrings("One More Time", s0.title);
    try std.testing.expectEqualStrings("Daft Punk", s0.artist);
    try std.testing.expectEqualStrings("al-9", s0.cover);
    const s1 = parseSong(it.next().?, &idb, &tb, &ab, &cb).?;
    try std.testing.expectEqualStrings("tr-2", s1.id);
    try std.testing.expectEqualStrings("Aerodynamic", s1.title);
    try std.testing.expect(it.next() == null);
    // The artist/album ids BEFORE the song array must NOT leak in (scope guard).
}

test "responseOk detects ok vs failed" {
    try std.testing.expect(responseOk("{\"subsonic-response\":{\"status\":\"ok\"}}"));
    try std.testing.expect(!responseOk("{\"subsonic-response\":{\"status\":\"failed\",\"error\":{\"code\":40}}}"));
}
