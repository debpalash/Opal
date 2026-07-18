//! Pure parsing + decisions for the Live TV (IPTV) tab — the VIDEO twin of
//! radio_pure.zig. No app-state / dvui / atomics imports, so the logic ships
//! tested (registered as `test_iptv_pure` in build.zig).
//!
//! Data source: the iptv-org public directory `streams.json` — a flat JSON
//! array of stream objects:
//!   https://iptv-org.github.io/api/streams.json
//!   [{ "channel":null, "feed":null, "title":"Milennio TV",
//!      "url":"https://…/milenniotv.m3u8", "quality":"720p",
//!      "label":null, "user_agent":null, "referrer":null }, …]
//!
//! `url` is the playable HLS/m3u8 stream (mpv plays it natively). `channel`
//! links to channels.json (categories + is_nsfw) but is often null and adds a
//! second ~10 MB fetch, so v1 does NOT enrich country/group from it — those
//! fields exist on the record but stay empty. NSFW is gated heuristically from
//! the title/url instead (see isNsfw), since streams.json alone carries no
//! is_nsfw flag.
//!
//! The parser writes into a caller-provided fixed-buffer slice and returns the
//! number of channels filled — bounds-safe on a worker thread (a malformed feed
//! must never trip a slice panic → a worker panic aborts the whole app).

const std = @import("std");

// ── Fixed-buffer record (shared with state.zig; no dvui/atomics so std.mem.zeroes works). ──

pub const IptvChannel = struct {
    // Channel display name (streams.json `title`).
    name: [160]u8 = std.mem.zeroes([160]u8),
    name_len: usize = 0,
    // The playable HLS/m3u8 stream URL handed straight to mpv.
    url: [512]u8 = std.mem.zeroes([512]u8),
    url_len: usize = 0,
    // Quality label ("720p"/"1080p"/…); may be empty.
    quality: [8]u8 = std.mem.zeroes([8]u8),
    quality_len: usize = 0,
    // Optional enrichment from channels.json — LEFT EMPTY in v1 (single-file
    // fetch only). Present so the record is forward-compatible.
    country: [64]u8 = std.mem.zeroes([64]u8),
    country_len: usize = 0,
    group: [64]u8 = std.mem.zeroes([64]u8),
    group_len: usize = 0,
};

// ══════════════════════════════════════════════════════════
// Shared JSON helpers (mirrors radio_pure.zig)
// ══════════════════════════════════════════════════════════

/// Decode the common JSON string escapes (\" \\ \/ \n \r \t \uXXXX) from `src`
/// into `dst`, returning bytes written (bounded by dst.len). iptv-org escapes
/// URL slashes as "\/", which would otherwise leave a broken stream URL.
/// Anything not a recognized escape is copied verbatim so we never corrupt.
pub fn jsonUnescape(src: []const u8, dst: []u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < dst.len) {
        const ch = src[i];
        if (ch != '\\' or i + 1 >= src.len) {
            dst[out] = ch;
            out += 1;
            i += 1;
            continue;
        }
        switch (src[i + 1]) {
            '"' => {
                dst[out] = '"';
                out += 1;
                i += 2;
            },
            '\\' => {
                dst[out] = '\\';
                out += 1;
                i += 2;
            },
            '/' => {
                dst[out] = '/';
                out += 1;
                i += 2;
            },
            'n' => {
                dst[out] = '\n';
                out += 1;
                i += 2;
            },
            'r' => {
                dst[out] = '\r';
                out += 1;
                i += 2;
            },
            't' => {
                dst[out] = '\t';
                out += 1;
                i += 2;
            },
            'u' => {
                if (i + 6 <= src.len) {
                    if (std.fmt.parseInt(u21, src[i + 2 .. i + 6], 16)) |cp| {
                        var u8b: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &u8b) catch 0;
                        if (n > 0 and out + n <= dst.len) {
                            @memcpy(dst[out .. out + n], u8b[0..n]);
                            out += n;
                        }
                        i += 6;
                    } else |_| {
                        dst[out] = '\\';
                        out += 1;
                        i += 1;
                    }
                } else {
                    dst[out] = '\\';
                    out += 1;
                    i += 1;
                }
            },
            else => {
                dst[out] = '\\';
                out += 1;
                i += 1;
            },
        }
    }
    return out;
}

/// Find `key` (e.g. `"title":"`) in `scope`, then read the JSON string value up
/// to the next unescaped `"`, decoding escapes into `dst`. Returns bytes
/// written, or 0 if the key is absent (or its value is `null`, which has no
/// opening quote). Bounds-safe against a truncated value.
fn jsonStrField(scope: []const u8, key: []const u8, dst: []u8) usize {
    const at = std.mem.indexOf(u8, scope, key) orelse return 0;
    const start = at + key.len;
    var end = start;
    var esc = false;
    while (end < scope.len) : (end += 1) {
        if (esc) {
            esc = false;
        } else if (scope[end] == '\\') {
            esc = true;
        } else if (scope[end] == '"') {
            break;
        }
    }
    if (end > scope.len) return 0;
    return jsonUnescape(scope[start..@min(end, scope.len)], dst);
}

// ══════════════════════════════════════════════════════════
// Pure decisions (URL shape, m3u8 recognition, NSFW gate, query match)
// ══════════════════════════════════════════════════════════

/// True when `url` is an http/https stream mpv can open directly.
pub fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

/// Case-insensitive substring test.
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return true;
    }
    return false;
}

/// Recognize an HLS/m3u8 playlist URL (path ends in `.m3u8`/`.m3u`, ignoring a
/// trailing `?query`/`#fragment`). Surfaced as an "HLS" badge in the UI, so the
/// tested logic is the shipped logic. mpv also plays non-m3u8 http streams, so
/// this is a display hint, NOT the accept gate (that's isHttpUrl).
pub fn isM3u8(url: []const u8) bool {
    var path = url;
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
    return std.mem.endsWith(u8, path, ".m3u8") or std.mem.endsWith(u8, path, ".m3u");
}

/// Heuristic adult-content detector over the title + url. streams.json carries
/// no is_nsfw flag (that lives in channels.json, a separate ~10 MB file this v1
/// does not fetch), so the gate keys on explicit adult tokens. Deliberately
/// conservative to avoid false positives on benign names like "Adult Swim" or
/// "Adult Animation" — plain "adult" is NOT a trigger; only explicit tokens are.
pub fn isNsfw(title: []const u8, url: []const u8) bool {
    const tokens = [_][]const u8{
        "xxx",     "porn",  "brazzers", "playboy", "hustler",
        "penthouse", "hentai", "camsoda", "chaturbate", "redtube",
        "18+",     "adults only",
    };
    for (tokens) |t| {
        if (containsCI(title, t)) return true;
        if (containsCI(url, t)) return true;
    }
    return false;
}

/// Case-insensitive title filter for search. Empty query matches everything (so
/// the popular/all-channels load reuses the same accept path).
pub fn matchesQuery(title: []const u8, query: []const u8) bool {
    return containsCI(title, query);
}

/// Whole accept decision for one stream entry, routed from parseStreams so the
/// tested logic IS the shipped logic:
///   • a non-empty display name, AND
///   • a playable http(s) URL, AND
///   • passes the NSFW gate (unless `nsfw_allowed`), AND
///   • matches the (possibly empty) search query.
pub fn acceptEntry(title: []const u8, url: []const u8, quality: []const u8, nsfw_allowed: bool, query: []const u8) bool {
    _ = quality; // reserved (kept in the signature so callers pass full context)
    if (title.len == 0) return false;
    if (!isHttpUrl(url)) return false;
    if (!nsfw_allowed and isNsfw(title, url)) return false;
    if (!matchesQuery(title, query)) return false;
    return true;
}

// ══════════════════════════════════════════════════════════
// URL builder
// ══════════════════════════════════════════════════════════

/// `<base>/streams.json` for the installed iptv-org endpoint. A trailing slash
/// on `base` is trimmed so we never emit `//streams.json`. Returns "" only if
/// `dst` is too small.
pub fn buildStreamsUrl(base: []const u8, dst: []u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.bufPrint(dst, "{s}/streams.json", .{trimmed}) catch "";
}

// ══════════════════════════════════════════════════════════
// streams.json → channels
// ══════════════════════════════════════════════════════════

/// Parse an iptv-org streams.json array into `out`, keeping the first
/// `out.len` entries that pass acceptEntry (playable URL, name, NSFW gate,
/// query filter). `query` is a case-insensitive title filter ("" = all).
/// `nsfw_allowed` lifts the adult gate. Each stream object is delimited by its
/// `"channel":` marker (present once per object, even when its value is null).
/// Returns the number of channels written (≤ out.len). Bounds-safe on any
/// malformed / truncated feed.
pub fn parseStreams(json: []const u8, out: []IptvChannel, nsfw_allowed: bool, query: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    const marker = "\"channel\":";
    while (pos < json.len and count < out.len) {
        const idx = std.mem.indexOfPos(u8, json, pos, marker) orelse break;
        // Object scope: this marker to the next object's marker (or EOF), so
        // field reads never bleed into a neighbouring object.
        const scan_from = idx + marker.len;
        var obj_end = json.len;
        if (std.mem.indexOfPos(u8, json, scan_from, marker)) |nidx| obj_end = nidx;
        const obj = json[idx..obj_end];
        pos = obj_end;

        var c = &out[count];
        c.* = .{};

        c.url_len = jsonStrField(obj, "\"url\":\"", &c.url);
        c.name_len = jsonStrField(obj, "\"title\":\"", &c.name);
        c.quality_len = jsonStrField(obj, "\"quality\":\"", &c.quality);

        if (!acceptEntry(
            c.name[0..c.name_len],
            c.url[0..c.url_len],
            c.quality[0..c.quality_len],
            nsfw_allowed,
            query,
        )) continue;

        count += 1;
    }
    return count;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "isHttpUrl accepts http/https only" {
    try std.testing.expect(isHttpUrl("http://a/x.m3u8"));
    try std.testing.expect(isHttpUrl("https://a/x.m3u8"));
    try std.testing.expect(!isHttpUrl("rtmp://a/x"));
    try std.testing.expect(!isHttpUrl(""));
}

test "isM3u8 recognizes HLS playlists incl. query/fragment" {
    try std.testing.expect(isM3u8("https://a/b/index.m3u8"));
    try std.testing.expect(isM3u8("https://a/b/playlist.m3u8?token=abc"));
    try std.testing.expect(isM3u8("https://a/b/live.m3u#x"));
    try std.testing.expect(!isM3u8("https://a/b/stream.ts"));
    try std.testing.expect(!isM3u8("https://a/b/live.mpd"));
}

test "isNsfw flags explicit adult tokens but not 'Adult Swim'" {
    try std.testing.expect(isNsfw("Blue XXX TV", ""));
    try std.testing.expect(isNsfw("Some Channel", "https://x/porn/live.m3u8"));
    try std.testing.expect(isNsfw("Hentai Haven", ""));
    // Regression: benign names containing "adult" must NOT be filtered.
    try std.testing.expect(!isNsfw("Adult Swim Latin America Brazil", "https://a/as.m3u8"));
    try std.testing.expect(!isNsfw("Pluto TV Adult Animation", "https://a/pluto.m3u8"));
    try std.testing.expect(!isNsfw("Stingray Pop Adult", "https://a/s.m3u8"));
}

test "matchesQuery is a case-insensitive substring; empty = all" {
    try std.testing.expect(matchesQuery("BBC News HD", "news"));
    try std.testing.expect(matchesQuery("BBC News HD", "BBC"));
    try std.testing.expect(matchesQuery("anything", ""));
    try std.testing.expect(!matchesQuery("BBC News HD", "cnn"));
}

test "acceptEntry gates name/url/nsfw/query" {
    // Happy path.
    try std.testing.expect(acceptEntry("BBC", "https://a/x.m3u8", "720p", false, ""));
    // No name → reject.
    try std.testing.expect(!acceptEntry("", "https://a/x.m3u8", "720p", false, ""));
    // Non-http URL → reject.
    try std.testing.expect(!acceptEntry("BBC", "rtmp://a/x", "720p", false, ""));
    // NSFW rejected when filter on, allowed when off.
    try std.testing.expect(!acceptEntry("XXX Channel", "https://a/x.m3u8", "", false, ""));
    try std.testing.expect(acceptEntry("XXX Channel", "https://a/x.m3u8", "", true, ""));
    // Query filter.
    try std.testing.expect(acceptEntry("BBC News", "https://a/x.m3u8", "", false, "news"));
    try std.testing.expect(!acceptEntry("BBC News", "https://a/x.m3u8", "", false, "sports"));
}

test "buildStreamsUrl appends streams.json and trims a trailing slash" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://iptv-org.github.io/api/streams.json",
        buildStreamsUrl("https://iptv-org.github.io/api", &buf),
    );
    try std.testing.expectEqualStrings(
        "https://iptv-org.github.io/api/streams.json",
        buildStreamsUrl("https://iptv-org.github.io/api/", &buf),
    );
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", buildStreamsUrl("https://a", &tiny));
}

test "parseStreams extracts title/url/quality from real-shaped JSON" {
    const json =
        \\[{"channel":null,"feed":null,"title":"Milennio TV","url":"https:\/\/v.example.com:19360\/milenniotv\/milenniotv.m3u8","quality":"720p","label":null,"user_agent":null,"referrer":null},
        \\{"channel":"BBCNews.uk","feed":null,"title":"BBC News","url":"https:\/\/b\/news.m3u8","quality":"1080p","label":null}]
    ;
    var out: [8]IptvChannel = undefined;
    const n = parseStreams(json, &out, false, "");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("Milennio TV", out[0].name[0..out[0].name_len]);
    try std.testing.expectEqualStrings("https://v.example.com:19360/milenniotv/milenniotv.m3u8", out[0].url[0..out[0].url_len]);
    try std.testing.expectEqualStrings("720p", out[0].quality[0..out[0].quality_len]);
    try std.testing.expect(isM3u8(out[0].url[0..out[0].url_len]));
    try std.testing.expectEqualStrings("BBC News", out[1].name[0..out[1].name_len]);
    try std.testing.expectEqualStrings("1080p", out[1].quality[0..out[1].quality_len]);
}

test "parseStreams applies the query filter" {
    const json =
        \\[{"channel":null,"title":"BBC News","url":"https:\/\/b\/news.m3u8","quality":"1080p"},
        \\{"channel":null,"title":"ESPN Sports","url":"https:\/\/e\/sport.m3u8","quality":"720p"}]
    ;
    var out: [8]IptvChannel = undefined;
    const n = parseStreams(json, &out, false, "news");
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("BBC News", out[0].name[0..out[0].name_len]);
}

test "parseStreams drops entries with no playable url or no title" {
    const json =
        \\[{"channel":null,"title":"No URL","url":null,"quality":"720p"},
        \\{"channel":null,"title":null,"url":"https:\/\/a\/x.m3u8","quality":"720p"},
        \\{"channel":null,"title":"Good","url":"https:\/\/a\/y.m3u8","quality":"480p"}]
    ;
    var out: [8]IptvChannel = undefined;
    const n = parseStreams(json, &out, false, "");
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("Good", out[0].name[0..out[0].name_len]);
}

test "parseStreams honours the NSFW gate" {
    const json =
        \\[{"channel":null,"title":"XXX Live","url":"https:\/\/a\/xxx.m3u8","quality":"720p"},
        \\{"channel":null,"title":"Family TV","url":"https:\/\/a\/fam.m3u8","quality":"720p"}]
    ;
    var out: [8]IptvChannel = undefined;
    // Filter ON → only the SFW channel.
    try std.testing.expectEqual(@as(usize, 1), parseStreams(json, &out, false, ""));
    try std.testing.expectEqualStrings("Family TV", out[0].name[0..out[0].name_len]);
    // Filter OFF → both.
    try std.testing.expectEqual(@as(usize, 2), parseStreams(json, &out, true, ""));
}

test "parseStreams regression: malformed JSON never panics" {
    var out: [8]IptvChannel = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseStreams("", &out, false, ""));
    try std.testing.expectEqual(@as(usize, 0), parseStreams("[", &out, false, ""));
    try std.testing.expectEqual(@as(usize, 0), parseStreams("[{\"channel\":", &out, false, ""));
    _ = parseStreams("\"channel\":null,\"url\":\"https:\\/\\/", &out, false, "");
    _ = parseStreams("[{\"channel\":null,\"title\":\"n\",\"url\":\"https://a\"}]", &out, false, "");
}
