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
    summary: [512]u8 = std.mem.zeroes([512]u8),
    summary_len: usize = 0,
};

/// Project decoded Apple rows without relying on key order or JSON spacing.
/// Invalid envelopes are distinct from a valid search with no matches.
pub fn parseItunesValue(root: std.json.Value, out: []Podcast) ?usize {
    if (root != .object) return null;
    const rows = root.object.get("results") orelse return null;
    if (rows != .array) return null;
    var count: usize = 0;
    for (rows.array.items) |entry| {
        if (count == out.len) break;
        if (entry != .object) continue;
        const feed = valueText(entry, "feedUrl");
        if (feed.len == 0 or feed.len > 300 or (!std.mem.startsWith(u8, feed, "https://") and !std.mem.startsWith(u8, feed, "http://"))) continue;
        var title = valueText(entry, "collectionName");
        if (title.len == 0) title = valueText(entry, "trackName");
        if (title.len == 0) continue;
        var row: Podcast = .{};
        copyValueText(title, &row.name, &row.name_len);
        copyValueText(feed, &row.feed_url, &row.feed_url_len);
        var art = valueText(entry, "artworkUrl600");
        if (art.len == 0) art = valueText(entry, "artworkUrl100");
        if (art.len <= row.artwork.len) copyValueText(art, &row.artwork, &row.artwork_len);
        copyValueText(valueText(entry, "artistName"), &row.artist, &row.artist_len);
        out[count] = row;
        count += 1;
    }
    return count;
}

fn valueText(value: std.json.Value, key: []const u8) []const u8 {
    const field = value.object.get(key) orelse return "";
    return if (field == .string) field.string else "";
}

fn copyValueText(src: []const u8, out: []u8, len: *usize) void {
    len.* = @min(src.len, out.len);
    while (len.* > 0 and !std.unicode.utf8ValidateSlice(src[0..len.*])) len.* -= 1;
    @memcpy(out[0..len.*], src[0..len.*]);
}

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
    const key = std.mem.trimEnd(u8, attr, "=\"");
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, block, offset, key)) |at| {
        offset = at + key.len;
        if (at > 0 and !std.ascii.isWhitespace(block[at - 1])) continue;
        var rest = std.mem.trimStart(u8, block[offset..], " \t\r\n");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
        if (rest.len < 2 or (rest[0] != '\'' and rest[0] != '"')) continue;
        const end = std.mem.indexOfScalarPos(u8, rest, 1, rest[0]) orelse return null;
        return rest[1..end];
    }
    return null;
}

fn xmlText(dst: []u8, src: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < src.len and n < dst.len) {
        if (src[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, src, i, ';')) |end| {
                const entity = src[i + 1 .. end];
                const code: ?u21 = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "quot")) '"' else if (std.mem.eql(u8, entity, "apos")) '\'' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.startsWith(u8, entity, "#x")) std.fmt.parseInt(u21, entity[2..], 16) catch null else if (std.mem.startsWith(u8, entity, "#")) std.fmt.parseInt(u21, entity[1..], 10) catch null else null;
                if (code) |cp| {
                    var bytes: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &bytes) catch 0;
                    if (len > 0 and n + len <= dst.len) {
                        @memcpy(dst[n..][0..len], bytes[0..len]);
                        n += len;
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        dst[n] = src[i];
        n += 1;
        i += 1;
    }
    return n;
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
    return parseRssEpisodePage(xml, out, 0).count;
}

pub const EpisodePage = struct { count: usize, total: usize };

/// A bounded window over all playable enclosures in the feed. The cursor counts
/// usable episodes, so missing enclosures do not create gaps or repeated pages.
pub fn parseRssEpisodePage(xml: []const u8, out: []Episode, offset: usize) EpisodePage {
    var count: usize = 0;
    var total: usize = 0;
    var pos: usize = 0;
    while (pos < xml.len) {
        const item_start = std.mem.indexOfPos(u8, xml, pos, "<item") orelse break;
        const item_end = std.mem.indexOfPos(u8, xml, item_start, "</item>") orelse break;
        const block = xml[item_start..item_end];
        pos = item_end + "</item>".len;

        var episode: Episode = .{};
        const e = &episode;

        // Audio enclosure URL is the load-bearing field.
        if (std.mem.indexOf(u8, block, "<enclosure")) |enc_at| {
            const enc_end = std.mem.indexOfScalarPos(u8, block, enc_at, '>') orelse block.len;
            const enc = block[enc_at..@min(enc_end + 1, block.len)];
            if (xmlAttr(enc, "url=\"")) |u| {
                if (u.len > e.audio_url.len) continue;
                e.audio_url_len = xmlText(&e.audio_url, u);
            }
        }
        if (!isFeedUrl(e.audio_url[0..e.audio_url_len])) continue;

        if (xmlTag(block, "<title>", "</title>")) |t| e.title_len = xmlText(&e.title, t);
        if (e.title_len == 0) continue;

        if (xmlTag(block, "<pubDate>", "</pubDate>")) |d| e.date_len = xmlText(&e.date, d);
        if (xmlTag(block, "<itunes:duration>", "</itunes:duration>")) |d|
            e.duration_len = xmlText(&e.duration, d);
        if (xmlTag(block, "<description>", "</description>") orelse xmlTag(block, "<itunes:summary>", "</itunes:summary>")) |description|
            e.summary_len = plainXmlText(&e.summary, description);
        if (total >= offset and count < out.len) {
            out[count] = episode;
            count += 1;
        }
        total += 1;
    }
    return .{ .count = count, .total = total };
}

fn plainXmlText(out: []u8, html: []const u8) usize {
    var stripped: [1024]u8 = undefined;
    var count: usize = 0;
    var inside = false;
    for (html) |ch| {
        if (ch == '<') {
            inside = true;
            continue;
        }
        if (ch == '>') {
            inside = false;
            if (count > 0 and count < stripped.len and stripped[count - 1] != ' ') {
                stripped[count] = ' ';
                count += 1;
            }
            continue;
        }
        if (inside) continue;
        if (count == stripped.len) break;
        stripped[count] = ch;
        count += 1;
    }
    return xmlText(out, std.mem.trim(u8, stripped[0..count], " \t\r\n"));
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

// ══════════════════════════════════════════════════════════
// Home deep link (library_items → reopen + resume an episode)
// ══════════════════════════════════════════════════════════
//
// Episode POSITION is already persisted by the generic mpv path
// (player.saveCurrentPosition → history.savePlaybackPosition → watch_history,
// keyed by the enclosure URL, and replayed by player.tryResumePosition). What a
// podcast lacked was IDENTITY in the unified read-model: this link carries the
// show/episode/artwork so `library_items` holds a real podcast row instead of an
// anonymous playback entry, and reopening it restores the now-playing card.

/// The fields a home "Continue" row needs to reopen a podcast episode.
pub const PodcastLink = struct {
    url: []const u8, // audio enclosure URL — also the resume key mpv uses
    artwork: []const u8, // show artwork (now-playing card)
    show: []const u8, // show name → card subtitle
    title: []const u8, // episode title → card title
};

/// Encode a podcast deep link: `podcast|<url>|<artwork>|<show>|<title>`. The
/// episode title runs to the end so its own separators can't truncate it.
/// Empty slice when there's no URL to play or it won't fit.
pub fn formatDeepLink(out: []u8, url: []const u8, artwork: []const u8, show: []const u8, title: []const u8) []const u8 {
    if (url.len == 0) return out[0..0];
    return std.fmt.bufPrint(out, "podcast|{s}|{s}|{s}|{s}", .{ url, artwork, show, title }) catch out[0..0];
}

/// Decode a `podcast|…` deep link. Null when the prefix/field count is wrong, so
/// a foreign link can never be routed into the podcast player.
pub fn parseDeepLink(link: []const u8) ?PodcastLink {
    const prefix = "podcast|";
    if (!std.mem.startsWith(u8, link, prefix)) return null;
    var rest = link[prefix.len..];
    const i = std.mem.indexOfScalar(u8, rest, '|') orelse return null;
    const url = rest[0..i];
    if (url.len == 0) return null;
    rest = rest[i + 1 ..];
    const j = std.mem.indexOfScalar(u8, rest, '|') orelse return null;
    const artwork = rest[0..j];
    rest = rest[j + 1 ..];
    const k = std.mem.indexOfScalar(u8, rest, '|') orelse return null;
    return .{ .url = url, .artwork = artwork, .show = rest[0..k], .title = rest[k + 1 ..] };
}

test "podcast deep link: round-trips through format/parse" {
    var buf: [1024]u8 = undefined;
    const link = formatDeepLink(&buf, "https://cdn.x/ep12.mp3", "https://cdn.x/art.jpg", "The Show", "Episode 12");
    try std.testing.expectEqualStrings(
        "podcast|https://cdn.x/ep12.mp3|https://cdn.x/art.jpg|The Show|Episode 12",
        link,
    );
    const got = parseDeepLink(link).?;
    try std.testing.expectEqualStrings("https://cdn.x/ep12.mp3", got.url);
    try std.testing.expectEqualStrings("https://cdn.x/art.jpg", got.artwork);
    try std.testing.expectEqualStrings("The Show", got.show);
    try std.testing.expectEqualStrings("Episode 12", got.title);
}

test "podcast deep link: optional artwork/show still parse" {
    var buf: [1024]u8 = undefined;
    const link = formatDeepLink(&buf, "https://cdn.x/e.mp3", "", "", "Ep");
    const got = parseDeepLink(link).?;
    try std.testing.expectEqualStrings("", got.artwork);
    try std.testing.expectEqualStrings("", got.show);
    try std.testing.expectEqualStrings("Ep", got.title);
}

test "podcast deep link: rejects foreign links and malformed input" {
    try std.testing.expect(parseDeepLink("https://cdn.x/e.mp3") == null);
    try std.testing.expect(parseDeepLink("comic|https://x.tld/i|T") == null);
    try std.testing.expect(parseDeepLink("novel|wikisource||F") == null);
    try std.testing.expect(parseDeepLink("podcast|https://cdn.x/e.mp3|art") == null); // too few fields
    try std.testing.expect(parseDeepLink("podcast||art|show|T") == null); // no playable url
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("", formatDeepLink(&buf, "", "a", "s", "T"));
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", formatDeepLink(&tiny, "https://cdn.x/e.mp3", "", "", "T"));
}

test "podcast deep link: an episode title containing '|' survives" {
    var buf: [1024]u8 = undefined;
    const link = formatDeepLink(&buf, "https://cdn.x/e.mp3", "", "Show", "Ep 4 | Part 2");
    try std.testing.expectEqualStrings("Ep 4 | Part 2", parseDeepLink(link).?.title);
}

/// gpodder.net is an independent, keyless directory with direct RSS URLs.
pub fn parseGpodder(a: std.mem.Allocator, json: []const u8, out: []Podcast) usize {
    const doc = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return 0;
    defer doc.deinit();
    return parseGpodderValue(doc.value, out) orelse 0;
}

/// Independent directory adapter distinguishes a valid empty page from an
/// error/malformed top-level response, matching the Apple parser contract.
pub fn parseGpodderValue(root: std.json.Value, out: []Podcast) ?usize {
    if (root != .array) return null;
    var n: usize = 0;
    for (root.array.items) |row| {
        if (n == out.len) break;
        if (row != .object) continue;
        const title = jsonValueString(row.object.get("title"));
        const feed = jsonValueString(row.object.get("url"));
        if (title.len == 0 or !isFeedUrl(feed) or feed.len > out[n].feed_url.len) continue;
        out[n] = .{};
        out[n].name_len = copyInto(&out[n].name, title);
        out[n].feed_url_len = copyInto(&out[n].feed_url, feed);
        out[n].artist_len = copyInto(&out[n].artist, jsonValueString(row.object.get("author")));
        out[n].artwork_len = copyInto(&out[n].artwork, jsonValueString(row.object.get("logo_url")));
        n += 1;
    }
    return n;
}

test "gpodder universal search distinguishes empty directory from error JSON" {
    var rows: [2]Podcast = undefined;
    const empty = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "[]", .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(?usize, 0), parseGpodderValue(empty.value, &rows));
    const failure = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"error\":\"unavailable\"}", .{});
    defer failure.deinit();
    try std.testing.expect(parseGpodderValue(failure.value, &rows) == null);
}

fn jsonValueString(value: ?std.json.Value) []const u8 {
    const v = value orelse return "";
    return if (v == .string) v.string else "";
}

pub fn isFeedUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://");
}

pub fn parseFeedShow(xml: []const u8, url: []const u8) ?Podcast {
    if (!isFeedUrl(url) or url.len > 300 or std.mem.indexOf(u8, xml, "<channel") == null) return null;
    const channel = xml[0 .. std.mem.indexOf(u8, xml, "<item") orelse xml.len];
    const title = xmlTag(channel, "<title>", "</title>") orelse return null;
    var show: Podcast = .{};
    show.name_len = xmlText(&show.name, title);
    show.feed_url_len = copyInto(&show.feed_url, url);
    if (xmlTag(channel, "<itunes:author>", "</itunes:author>")) |author| show.artist_len = xmlText(&show.artist, author);
    if (std.mem.indexOf(u8, channel, "<itunes:image")) |at| {
        const end = std.mem.indexOfScalarPos(u8, channel, at, '>') orelse channel.len;
        if (xmlAttr(channel[at..end], "href=\"")) |art| show.artwork_len = xmlText(&show.artwork, art);
    }
    return show;
}

/// Preserve directory order and deduplicate shows shared by multiple catalogs.
pub fn appendUnique(out: []Podcast, start: usize, incoming: []const Podcast) usize {
    var n = @min(start, out.len);
    rows: for (incoming) |row| {
        if (n == out.len) break;
        for (out[0..n]) |old| {
            if (std.mem.eql(u8, old.feed_url[0..old.feed_url_len], row.feed_url[0..row.feed_url_len])) continue :rows;
        }
        out[n] = row;
        n += 1;
    }
    return n;
}

test "independent podcast directory merges by feed URL and accepts direct RSS" {
    var rows: [3]Podcast = undefined;
    const n = parseGpodder(std.testing.allocator,
        \\[{"title":"Science","url":"https://example.test/rss","author":"Publisher"},{"title":"Bad","url":"file:///tmp/no"}]
    , &rows);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(usize, 1), appendUnique(&rows, n, rows[0..n]));
    const show = parseFeedShow("<rss><channel><title>Independent show</title><item><title>Episode</title></item></channel></rss>", "https://example.test/feed").?;
    try std.testing.expectEqualStrings("Independent show", show.name[0..show.name_len]);
    try std.testing.expectEqual(@as(usize, 2), appendUnique(&rows, n, &.{show}));
}

test "RSS enclosures decode XML entities and accept single quoted attributes" {
    var episodes: [2]Episode = undefined;
    const n = parseRssEpisodes("<rss><channel><item><title>Science &amp; Space</title><enclosure url='https://cdn.test/audio.mp3?a=1&amp;b=2' type='audio/mpeg'/></item></channel></rss>", &episodes);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("https://cdn.test/audio.mp3?a=1&b=2", episodes[0].audio_url[0..episodes[0].audio_url_len]);
    try std.testing.expectEqualStrings("Science & Space", episodes[0].title[0..episodes[0].title_len]);
}

test "RSS pages count usable items beyond 200 and have a truthful end" {
    const item = "<item><title>Episode</title><enclosure url='https://cdn.test/a.mp3'/></item>";
    const invalid = "<item><title>No enclosure</title></item>";
    const xml = "<rss><channel>" ++ (item ++ invalid) ** 205 ++ "</channel></rss>";
    const rows = try std.testing.allocator.alloc(Episode, 200);
    defer std.testing.allocator.free(rows);
    const first = parseRssEpisodePage(xml, rows, 0);
    try std.testing.expectEqual(@as(usize, 200), first.count);
    try std.testing.expectEqual(@as(usize, 205), first.total);
    const last = parseRssEpisodePage(xml, rows, 200);
    try std.testing.expectEqual(@as(usize, 5), last.count);
    try std.testing.expectEqual(@as(usize, 205), last.total);
    try std.testing.expectEqual(@as(usize, 0), parseRssEpisodePage(xml, rows, 205).count);
}
