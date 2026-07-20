//! JioSaavn music source — PURE, unit-tested.
//!
//! A keyless, public music source (huge Indian + international catalog) that
//! works with NO server config — the complement to the self-hosted Subsonic
//! engine. Search hits JioSaavn's own public endpoint (www.jiosaavn.com/api.php);
//! playback hands the song's `perma_url` to mpv, whose bundled yt-dlp
//! (`jiosaavn:song` extractor) resolves the signed CDN stream. So we need NO DES
//! decryption of `encrypted_media_url` and NO flaky third-party API instance —
//! only search metadata + a perma_url, same shape as the YouTube Music approach.
//!
//! Search response (api.php __call=search.getResults, _format=json):
//!   { "results":[ {"id":"…","song":"Kesariya","primary_artists":"…",
//!      "image":"https://c.saavncdn.com/…-150x150.jpg",
//!      "perma_url":"https://www.jiosaavn.com/song/kesariya/…"}, … ] }

const std = @import("std");

pub const API = "https://www.jiosaavn.com/api.php";

// ── Percent-encoding (unreserved kept; curl-glob-safe) ──
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

/// `search.getResults` for `query`, returning up to `n` songs as JSON.
pub fn buildSearchUrl(out: []u8, query: []const u8, n: u32) ?[]const u8 {
    if (query.len == 0) return null;
    var enc: [512]u8 = undefined;
    const qn = percentEncode(query, &enc);
    if (qn == 0) return null;
    return std.fmt.bufPrint(out, "{s}?__call=search.getResults&q={s}&_format=json&_marker=0&ctx=web6dot0&n={d}&p=1", .{ API, enc[0..qn], n }) catch null;
}

/// A JioSaavn `perma_url` is what mpv/yt-dlp resolves. Accept only the real host
/// so a malformed row can't hand mpv something unexpected.
pub fn isPlayableUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://www.jiosaavn.com/song/");
}

/// Upgrade a cover image URL to 500x500 (search returns 150x150/50x50 thumbs).
/// Returns the upgraded URL in `out`, or the original when no size token is found.
pub fn coverUpgrade(image: []const u8, out: []u8) []const u8 {
    const sizes = [_][]const u8{ "150x150", "50x50" };
    for (sizes) |sz| {
        if (std.mem.indexOf(u8, image, sz)) |at| {
            const total = image.len - sz.len + "500x500".len;
            if (total > out.len) return image;
            var w: usize = 0;
            @memcpy(out[0..at], image[0..at]);
            w = at;
            @memcpy(out[w .. w + 7], "500x500");
            w += 7;
            const rest = image[at + sz.len ..];
            @memcpy(out[w .. w + rest.len], rest);
            return out[0 .. w + rest.len];
        }
    }
    return image;
}

// ── JSON extraction ──

/// Read a JSON string field `"key":"…"` from `scope` into `dst`, decoding the
/// few HTML entities JioSaavn titles carry (&amp; &quot; &#39;) so display text
/// is clean. Bounds-safe; stops at the first unescaped quote. Returns bytes.
pub fn jsonStr(scope: []const u8, key: []const u8, dst: []u8) usize {
    const at = std.mem.indexOf(u8, scope, key) orelse return 0;
    var i = at + key.len;
    var out: usize = 0;
    while (i < scope.len and out < dst.len) : (i += 1) {
        const c = scope[i];
        if (c == '\\' and i + 1 < scope.len) {
            // JSON escape — JioSaavn escapes "/" as "\/" in URLs; copy the target.
            dst[out] = scope[i + 1];
            out += 1;
            i += 1;
            continue;
        }
        if (c == '"') break;
        if (c == '&') {
            const rest = scope[i..];
            if (std.mem.startsWith(u8, rest, "&amp;")) {
                dst[out] = '&';
                out += 1;
                i += 4;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&quot;")) {
                dst[out] = '"';
                out += 1;
                i += 5;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&#39;") or std.mem.startsWith(u8, rest, "&#039;")) {
                dst[out] = '\'';
                out += 1;
                i += if (rest[3] == '0') @as(usize, 5) else 4;
                continue;
            }
        }
        dst[out] = c;
        out += 1;
    }
    return out;
}

/// Iterate the `results` array objects, delimited by each song's `"id":"`.
pub const SongIter = struct {
    json: []const u8,
    pos: usize = 0,
    const marker = "\"id\":\"";

    pub fn next(self: *SongIter) ?[]const u8 {
        const at = std.mem.indexOfPos(u8, self.json, self.pos, marker) orelse return null;
        var end = self.json.len;
        if (std.mem.indexOfPos(u8, self.json, at + marker.len, marker)) |nx| end = nx;
        self.pos = end;
        return self.json[at..end];
    }
};

pub const Song = struct {
    title: []const u8,
    artist: []const u8,
    perma_url: []const u8, // the play URL (mpv/yt-dlp resolves it)
    image: []const u8,
};

/// Extract one song from a results object slice into caller buffers. Null when
/// there's no title or no playable perma_url.
pub fn parseSong(obj: []const u8, title_buf: []u8, artist_buf: []u8, url_buf: []u8, img_buf: []u8) ?Song {
    const tn = jsonStr(obj, "\"song\":\"", title_buf);
    if (tn == 0) return null;
    const un = jsonStr(obj, "\"perma_url\":\"", url_buf);
    if (un == 0 or !isPlayableUrl(url_buf[0..un])) return null;
    const an = jsonStr(obj, "\"primary_artists\":\"", artist_buf);
    const in = jsonStr(obj, "\"image\":\"", img_buf);
    return .{ .title = title_buf[0..tn], .artist = artist_buf[0..an], .perma_url = url_buf[0..un], .image = img_buf[0..in] };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "buildSearchUrl hits the public api.php search endpoint" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://www.jiosaavn.com/api.php?__call=search.getResults&q=arijit%20singh&_format=json&_marker=0&ctx=web6dot0&n=30&p=1",
        buildSearchUrl(&b, "arijit singh", 30).?,
    );
    try std.testing.expect(buildSearchUrl(&b, "", 30) == null);
}

test "isPlayableUrl accepts only jiosaavn song perma_urls" {
    try std.testing.expect(isPlayableUrl("https://www.jiosaavn.com/song/kesariya/AgIAQyBeWlI"));
    try std.testing.expect(!isPlayableUrl("https://evil.example/song/x"));
    try std.testing.expect(!isPlayableUrl("https://www.jiosaavn.com/album/x"));
}

test "coverUpgrade bumps 150x150/50x50 to 500x500" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://c.saavncdn.com/871/x-500x500.jpg",
        coverUpgrade("https://c.saavncdn.com/871/x-150x150.jpg", &b),
    );
    try std.testing.expectEqualStrings(
        "https://c.saavncdn.com/871/x-500x500.jpg",
        coverUpgrade("https://c.saavncdn.com/871/x-50x50.jpg", &b),
    );
    // No size token → returned unchanged.
    try std.testing.expectEqualStrings("https://x/cover.jpg", coverUpgrade("https://x/cover.jpg", &b));
}

test "parseSong extracts title/artist/perma_url + decodes entities + unescapes /" {
    const json =
        \\{"results":[
        \\{"id":"rjkrTnma","song":"Kesariya &amp; More","primary_artists":"Pritam, Arijit Singh","image":"https:\/\/c.saavncdn.com\/871\/x-150x150.jpg","perma_url":"https:\/\/www.jiosaavn.com\/song\/kesariya\/AgIAQyBeWlI"},
        \\{"id":"nourl","song":"Bad","primary_artists":"X","image":"","perma_url":"https:\/\/www.jiosaavn.com\/album\/y"}]}
    ;
    var it = SongIter{ .json = json };
    var tb: [160]u8 = undefined;
    var ab: [128]u8 = undefined;
    var ub: [400]u8 = undefined;
    var ib: [400]u8 = undefined;
    const s0 = parseSong(it.next().?, &tb, &ab, &ub, &ib).?;
    try std.testing.expectEqualStrings("Kesariya & More", s0.title);
    try std.testing.expectEqualStrings("Pritam, Arijit Singh", s0.artist);
    try std.testing.expectEqualStrings("https://www.jiosaavn.com/song/kesariya/AgIAQyBeWlI", s0.perma_url);
    try std.testing.expectEqualStrings("https://c.saavncdn.com/871/x-150x150.jpg", s0.image);
    // Second row is an album (not a song perma_url) → rejected.
    try std.testing.expect(parseSong(it.next().?, &tb, &ab, &ub, &ib) == null);
}
