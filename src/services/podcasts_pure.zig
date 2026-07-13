//! Pure parsing for the Podcasts tab — no app-state / dvui imports, so the
//! logic ships tested (registered as `test_podcasts_pure` in build.zig).
//!
//! Two data sources:
//!   1. iTunes Search API JSON  → podcast shows {collectionName, feedUrl, artwork}
//!      (the /lookup endpoint returns the SAME result objects, so the Popular
//!      chart reuses parseItunes verbatim — see parseTopChartIds below)
//!   2. a show's RSS feed (XML) → episodes {title, audio enclosure url, date, duration}
//!
//! Both parsers write into caller-provided fixed-buffer slices and return the
//! number of entries filled — bounds-safe on a worker thread (a malformed feed
//! must never trip a slice panic → worker panics abort the whole app).

const std = @import("std");

// ── Fixed-buffer records (shared with state.zig; no dvui/atomics so std.mem.zeroes works). ──

pub const Podcast = struct {
    name: [160]u8 = std.mem.zeroes([160]u8),
    name_len: usize = 0,
    feed_url: [300]u8 = std.mem.zeroes([300]u8),
    feed_url_len: usize = 0,
    artwork: [300]u8 = std.mem.zeroes([300]u8),
    artwork_len: usize = 0,
    // Publisher ("artistName") — the card subtitle. Optional: a show with no
    // artist still renders, just without a subtitle line.
    artist: [96]u8 = std.mem.zeroes([96]u8),
    artist_len: usize = 0,
};

pub const Episode = struct {
    title: [200]u8 = std.mem.zeroes([200]u8),
    title_len: usize = 0,
    audio_url: [512]u8 = std.mem.zeroes([512]u8),
    audio_url_len: usize = 0,
    date: [40]u8 = std.mem.zeroes([40]u8),
    date_len: usize = 0,
    duration: [16]u8 = std.mem.zeroes([16]u8),
    duration_len: usize = 0,
};

// ══════════════════════════════════════════════════════════
// Shared helpers
// ══════════════════════════════════════════════════════════

/// Decode the common JSON string escapes (\" \\ \/ \n \r \t \uXXXX) from `src`
/// into `dst`, returning bytes written (bounded by dst.len). iTunes escapes URL
/// slashes as "\/", which would otherwise leave a broken feed URL. Anything not
/// a recognized escape is copied verbatim (backslash kept) so we never corrupt.
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

/// Find `"key":"` in `scope`, then read the JSON string value up to the next
/// unescaped `"`, decoding escapes into `dst`. Returns bytes written, or 0 if
/// the key is absent. Bounds-safe against a truncated/malformed value.
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

/// Extract the text between `open`/`close`, stripping a `<![CDATA[ … ]]>` wrapper
/// and surrounding whitespace. Returns null if the tags are absent.
fn xmlTag(block: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const s = (std.mem.indexOf(u8, block, open) orelse return null) + open.len;
    const e = std.mem.indexOfPos(u8, block, s, close) orelse return null;
    var inner = block[s..e];
    if (std.mem.indexOf(u8, inner, "<![CDATA[")) |ci| {
        const cs = ci + "<![CDATA[".len;
        const ce = std.mem.indexOfPos(u8, inner, cs, "]]>") orelse inner.len;
        inner = inner[cs..ce];
    }
    return std.mem.trim(u8, inner, " \t\r\n");
}

/// Pull an attribute value: finds `attr` (e.g. `url="`) inside `block` and reads
/// to the next `"`. Used for `<enclosure url="…">`.
fn xmlAttr(block: []const u8, attr: []const u8) ?[]const u8 {
    const s = (std.mem.indexOf(u8, block, attr) orelse return null) + attr.len;
    const e = std.mem.indexOfScalarPos(u8, block, s, '"') orelse return null;
    return block[s..e];
}

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

// ══════════════════════════════════════════════════════════
// iTunes Search API → podcast shows
// https://itunes.apple.com/search?media=podcast&term=…
// {"resultCount":N,"results":[{ "collectionName":…, "feedUrl":…, "artworkUrl600":… }]}
// ══════════════════════════════════════════════════════════

/// Parse iTunes podcast search JSON into `out`. Each result object is delimited
/// by its `"collectionId":` marker (present once per podcast). Only rows that
/// carry a usable feedUrl are kept (a show with no RSS feed can't be played).
/// Returns the number of podcasts written (≤ out.len).
pub fn parseItunes(json: []const u8, out: []Podcast) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < json.len and count < out.len) {
        const marker = "\"collectionId\":";
        const idx = std.mem.indexOfPos(u8, json, pos, marker) orelse break;
        const obj_start = idx + marker.len;

        var obj_end = json.len;
        if (std.mem.indexOfPos(u8, json, obj_start, marker)) |nidx| obj_end = nidx;
        const obj = json[obj_start..obj_end];
        pos = obj_end;

        var p = &out[count];
        p.* = .{};

        p.feed_url_len = jsonStrField(obj, "\"feedUrl\":\"", &p.feed_url);
        if (p.feed_url_len == 0) continue; // no RSS → unplayable, skip

        p.name_len = jsonStrField(obj, "\"collectionName\":\"", &p.name);
        if (p.name_len == 0) p.name_len = jsonStrField(obj, "\"trackName\":\"", &p.name);
        if (p.name_len == 0) continue;

        p.artwork_len = jsonStrField(obj, "\"artworkUrl600\":\"", &p.artwork);
        if (p.artwork_len == 0) p.artwork_len = jsonStrField(obj, "\"artworkUrl100\":\"", &p.artwork);

        p.artist_len = jsonStrField(obj, "\"artistName\":\"", &p.artist);

        count += 1;
    }
    return count;
}

// ══════════════════════════════════════════════════════════
// Popular chart → iTunes lookup (both keyless, both Apple)
//
// The Apple "Top Shows" chart (rss.marketingtools.apple.com) lists the current
// top podcasts but carries NO feedUrl, so its rows are unplayable on their own.
// The iTunes /lookup endpoint takes a comma-separated id list and answers with
// the exact same result objects as /search — so the chart supplies the ids and
// parseItunes (already tested above) does the parsing. No new API key, no new
// parser, no new HTTP path: the two-step is chart-ids → lookup → parseItunes.
// ══════════════════════════════════════════════════════════

/// Build the Apple "Top Shows" chart URL. `limit` is clamped to 1..100 so a bad
/// caller can't produce a rejected URL. Returns "" only if `dst` is too small.
pub fn buildTopChartUrl(limit: usize, dst: []u8) []const u8 {
    const n = std.math.clamp(limit, 1, 100);
    return std.fmt.bufPrint(
        dst,
        "https://rss.marketingtools.apple.com/api/v2/us/podcasts/top/{d}/podcasts.json",
        .{n},
    ) catch "";
}

/// Extract the numeric show ids from the Apple top-shows chart JSON, joined into
/// the comma-separated list the iTunes /lookup endpoint expects.
///
/// Scoped to the `"results":[…]` array so the feed's own `"id":"https://rss…"`
/// header field can't leak in, and a value is only accepted when it is entirely
/// digits followed by a closing quote (`"genreId":"1489"` doesn't even match the
/// `"id":"` key, but the digit check makes the extraction total anyway). Stops
/// cleanly when `dst` fills. Returns a slice of `dst` (empty on no/garbage input
/// — never panics on a truncated body from a worker thread).
pub fn parseTopChartIds(json: []const u8, dst: []u8) []const u8 {
    const results_at = std.mem.indexOf(u8, json, "\"results\":") orelse return dst[0..0];
    const key = "\"id\":\"";
    var pos = results_at;
    var out: usize = 0;
    while (std.mem.indexOfPos(u8, json, pos, key)) |at| {
        const s = at + key.len;
        var e = s;
        while (e < json.len and json[e] >= '0' and json[e] <= '9') : (e += 1) {}
        pos = @max(s, e); // e >= s always → the scan always advances past `at`
        if (e == s or e >= json.len or json[e] != '"') continue; // not a numeric id
        const id = json[s..e];
        const need = id.len + @as(usize, if (out == 0) 0 else 1);
        if (out + need > dst.len) break; // buffer full — keep what we have
        if (out != 0) {
            dst[out] = ',';
            out += 1;
        }
        @memcpy(dst[out .. out + id.len], id);
        out += id.len;
    }
    return dst[0..out];
}

/// Build the iTunes /lookup URL for a comma-separated id list. The ids are
/// digits+commas by construction (parseTopChartIds), so nothing here needs
/// percent-encoding. Returns "" for an empty list or an undersized `dst`.
pub fn buildLookupUrl(ids_csv: []const u8, dst: []u8) []const u8 {
    if (ids_csv.len == 0) return "";
    return std.fmt.bufPrint(
        dst,
        "https://itunes.apple.com/lookup?id={s}&entity=podcast",
        .{ids_csv},
    ) catch "";
}

// ══════════════════════════════════════════════════════════
// Podcast RSS feed → episodes
// <item><title>…</title><enclosure url="…" type="audio/…"/><pubDate>…</pubDate>
//   <itunes:duration>…</itunes:duration></item>
// ══════════════════════════════════════════════════════════

/// Parse a podcast RSS feed into `out`. Walks each `<item>…</item>` block and
/// keeps rows that have both a title and an audio enclosure URL. Returns the
/// number of episodes written (≤ out.len).
pub fn parseRssEpisodes(xml: []const u8, out: []Episode) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < xml.len and count < out.len) {
        const item_start = std.mem.indexOfPos(u8, xml, pos, "<item") orelse break;
        const item_end = std.mem.indexOfPos(u8, xml, item_start, "</item>") orelse break;
        const block = xml[item_start..item_end];
        pos = item_end + "</item>".len;

        var e = &out[count];
        e.* = .{};

        // Audio enclosure URL is the load-bearing field.
        if (std.mem.indexOf(u8, block, "<enclosure")) |enc_at| {
            const enc_end = std.mem.indexOfScalarPos(u8, block, enc_at, '>') orelse block.len;
            const enc = block[enc_at..@min(enc_end + 1, block.len)];
            if (xmlAttr(enc, "url=\"")) |u| e.audio_url_len = copyInto(&e.audio_url, u);
        }
        if (e.audio_url_len == 0) continue;

        if (xmlTag(block, "<title>", "</title>")) |t| e.title_len = copyInto(&e.title, t);
        if (e.title_len == 0) continue;

        if (xmlTag(block, "<pubDate>", "</pubDate>")) |d| e.date_len = copyInto(&e.date, d);
        if (xmlTag(block, "<itunes:duration>", "</itunes:duration>")) |d|
            e.duration_len = copyInto(&e.duration, d);

        count += 1;
    }
    return count;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "jsonUnescape decodes slashes/quotes/unicode" {
    var buf: [64]u8 = undefined;
    const n = jsonUnescape("https:\\/\\/a.com\\/x", &buf);
    try std.testing.expectEqualStrings("https://a.com/x", buf[0..n]);
    const m = jsonUnescape("a\\u0026b", &buf);
    try std.testing.expectEqualStrings("a&b", buf[0..m]);
}

test "parseItunes extracts name/feed/artwork" {
    const json =
        \\{"resultCount":2,"results":[
        \\{"collectionId":1,"collectionName":"The Daily","feedUrl":"https:\/\/feeds.x\/daily","artworkUrl600":"https:\/\/img\/600.jpg"},
        \\{"collectionId":2,"trackName":"Radiolab","feedUrl":"https:\/\/feeds.x\/radiolab","artworkUrl100":"https:\/\/img\/100.jpg"}
        \\]}
    ;
    var out: [8]Podcast = undefined;
    const n = parseItunes(json, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("The Daily", out[0].name[0..out[0].name_len]);
    try std.testing.expectEqualStrings("https://feeds.x/daily", out[0].feed_url[0..out[0].feed_url_len]);
    try std.testing.expectEqualStrings("https://img/600.jpg", out[0].artwork[0..out[0].artwork_len]);
    // Second falls back to trackName + artworkUrl100.
    try std.testing.expectEqualStrings("Radiolab", out[1].name[0..out[1].name_len]);
    try std.testing.expectEqualStrings("https://img/100.jpg", out[1].artwork[0..out[1].artwork_len]);
}

test "parseItunes extracts artistName as the card subtitle" {
    const json =
        \\{"results":[
        \\{"collectionId":1,"artistName":"The New York Times","collectionName":"The Daily","feedUrl":"https:\/\/f\/d"},
        \\{"collectionId":2,"collectionName":"No Publisher","feedUrl":"https:\/\/f\/n"}
        \\]}
    ;
    var out: [8]Podcast = undefined;
    const n = parseItunes(json, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("The New York Times", out[0].artist[0..out[0].artist_len]);
    // Missing artistName is not fatal — the show still parses, subtitle empty.
    try std.testing.expectEqual(@as(usize, 0), out[1].artist_len);
}

test "parseTopChartIds pulls the chart ids, skipping the feed header id" {
    const json =
        \\{"feed":{"title":"Top Shows","id":"https://rss.marketingtools.apple.com/x.json",
        \\"results":[
        \\{"artistName":"NYT","id":"1200361736","name":"The Daily","genres":[{"genreId":"1489","name":"News"}]},
        \\{"artistName":"Audiochuck","id":"1322200189","name":"Crime Junkie"}
        \\]}}
    ;
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("1200361736,1322200189", parseTopChartIds(json, &buf));
}

test "parseTopChartIds regression: malformed/empty input never panics" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", parseTopChartIds("", &buf));
    try std.testing.expectEqualStrings("", parseTopChartIds("{\"feed\":{\"id\":\"1\"}}", &buf)); // no results scope
    try std.testing.expectEqualStrings("", parseTopChartIds("{\"results\":[{\"id\":\"", &buf)); // truncated
    try std.testing.expectEqualStrings("", parseTopChartIds("{\"results\":[{\"id\":\"abc\"}]}", &buf)); // non-numeric
    // A tiny dst truncates at a whole id (never a half id / trailing comma).
    var small: [10]u8 = undefined;
    try std.testing.expectEqualStrings("1200361736", parseTopChartIds("{\"results\":[{\"id\":\"1200361736\"},{\"id\":\"1322200189\"}]}", &small));
}

test "buildTopChartUrl / buildLookupUrl" {
    var buf: [200]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://rss.marketingtools.apple.com/api/v2/us/podcasts/top/30/podcasts.json",
        buildTopChartUrl(30, &buf),
    );
    // limit clamped into 1..100.
    try std.testing.expectEqualStrings(
        "https://rss.marketingtools.apple.com/api/v2/us/podcasts/top/100/podcasts.json",
        buildTopChartUrl(9999, &buf),
    );
    try std.testing.expectEqualStrings(
        "https://itunes.apple.com/lookup?id=1,2&entity=podcast",
        buildLookupUrl("1,2", &buf),
    );
    try std.testing.expectEqualStrings("", buildLookupUrl("", &buf));
    // Undersized dst → "" rather than a truncated (wrong) URL.
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", buildLookupUrl("1,2", &tiny));
    try std.testing.expectEqualStrings("", buildTopChartUrl(30, &tiny));
}

test "parseItunes skips a result with no feedUrl" {
    const json =
        \\{"results":[
        \\{"collectionId":1,"collectionName":"No Feed"},
        \\{"collectionId":2,"collectionName":"Has Feed","feedUrl":"https:\/\/f\/x"}
        \\]}
    ;
    var out: [8]Podcast = undefined;
    const n = parseItunes(json, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("Has Feed", out[0].name[0..out[0].name_len]);
}

test "parseItunes regression: malformed JSON never panics" {
    var out: [8]Podcast = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseItunes("", &out));
    try std.testing.expectEqual(@as(usize, 0), parseItunes("{\"results\":[", &out));
    // Truncated value mid-string — must not read past end.
    _ = parseItunes("\"collectionId\":1,\"feedUrl\":\"https:\\/\\/", &out);
    _ = parseItunes("\"collectionId\":\"collectionId\":\"collectionId\":", &out);
}

test "parseRssEpisodes extracts title/enclosure/date/duration" {
    const xml =
        \\<rss><channel>
        \\<item><title>Episode One</title>
        \\<enclosure url="https://cdn.x/1.mp3" length="100" type="audio/mpeg"/>
        \\<pubDate>Mon, 01 Jan 2026 00:00:00 GMT</pubDate>
        \\<itunes:duration>32:10</itunes:duration></item>
        \\<item><title><![CDATA[Ep Two & More]]></title>
        \\<enclosure type="audio/mpeg" url="https://cdn.x/2.mp3"/></item>
        \\</channel></rss>
    ;
    var out: [8]Episode = undefined;
    const n = parseRssEpisodes(xml, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("Episode One", out[0].title[0..out[0].title_len]);
    try std.testing.expectEqualStrings("https://cdn.x/1.mp3", out[0].audio_url[0..out[0].audio_url_len]);
    try std.testing.expectEqualStrings("32:10", out[0].duration[0..out[0].duration_len]);
    // CDATA stripped; enclosure url attr found even when it follows `type`.
    try std.testing.expectEqualStrings("Ep Two & More", out[1].title[0..out[1].title_len]);
    try std.testing.expectEqualStrings("https://cdn.x/2.mp3", out[1].audio_url[0..out[1].audio_url_len]);
}

test "parseRssEpisodes regression: item without enclosure is skipped, malformed never panics" {
    const xml =
        \\<item><title>No Audio</title></item>
        \\<item><title>Good</title><enclosure url="https://cdn.x/g.mp3"/></item>
    ;
    var out: [8]Episode = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseRssEpisodes(xml, &out));
    try std.testing.expectEqualStrings("Good", out[0].title[0..out[0].title_len]);
    // Truncated / garbage input.
    try std.testing.expectEqual(@as(usize, 0), parseRssEpisodes("", &out));
    _ = parseRssEpisodes("<item><enclosure url=\"", &out);
    _ = parseRssEpisodes("<item><item><item></item>", &out);
}
