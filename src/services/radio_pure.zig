//! Pure parsing for the Internet Radio tab (RadioBrowser API) — no app-state /
//! dvui imports, so the logic ships tested (registered as `test_radio_pure` in
//! build.zig). Structural sibling of podcasts_pure.zig.
//!
//! Data source: RadioBrowser station search JSON (an array of station objects):
//!   https://all.api.radio-browser.info/json/stations/search?name=…
//!   [{ "stationuuid":…, "name":…, "url":…, "url_resolved":…, "favicon":…,
//!      "tags":…, "country":…, "codec":…, "bitrate":128, "votes":4210 }, …]
//!
//! The parser writes into a caller-provided fixed-buffer slice and returns the
//! number of stations filled — bounds-safe on a worker thread (a malformed feed
//! must never trip a slice panic → worker panics abort the whole app).

const std = @import("std");

// ── Fixed-buffer record (shared with state.zig; no dvui/atomics so std.mem.zeroes works). ──

pub const Station = struct {
    // stationuuid is load-bearing for the RadioBrowser click-count ping, so it
    // is parsed even though it is not surfaced in the UI.
    stationuuid: [40]u8 = std.mem.zeroes([40]u8),
    stationuuid_len: usize = 0,
    name: [160]u8 = std.mem.zeroes([160]u8),
    name_len: usize = 0,
    // url_resolved is the CDN-resolved stream mpv plays natively; url is the
    // fallback playlist/redirect the station advertises.
    url_resolved: [512]u8 = std.mem.zeroes([512]u8),
    url_resolved_len: usize = 0,
    url: [512]u8 = std.mem.zeroes([512]u8),
    url_len: usize = 0,
    favicon: [300]u8 = std.mem.zeroes([300]u8),
    favicon_len: usize = 0,
    tags: [160]u8 = std.mem.zeroes([160]u8),
    tags_len: usize = 0,
    country: [64]u8 = std.mem.zeroes([64]u8),
    country_len: usize = 0,
    codec: [16]u8 = std.mem.zeroes([16]u8),
    codec_len: usize = 0,
    votes: u32 = 0,
    bitrate: u32 = 0,
};

// ══════════════════════════════════════════════════════════
// Shared helpers (JSON — mirrors podcasts_pure.zig)
// ══════════════════════════════════════════════════════════

/// Decode the common JSON string escapes (\" \\ \/ \n \r \t \uXXXX) from `src`
/// into `dst`, returning bytes written (bounded by dst.len). RadioBrowser
/// escapes URL slashes as "\/", which would otherwise leave a broken stream
/// URL. Anything not a recognized escape is copied verbatim (backslash kept) so
/// we never corrupt.
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

/// Find `key` (e.g. `"name":"`) in `scope`, then read the JSON string value up
/// to the next unescaped `"`, decoding escapes into `dst`. Returns bytes
/// written, or 0 if the key is absent. Bounds-safe against a truncated value.
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

/// Read an unquoted JSON integer value following `key` (e.g. `"bitrate":`).
/// Returns 0 when the key is absent or the value is not a number. Saturates at
/// u32 max so a garbage/huge value can never overflow.
fn jsonIntField(scope: []const u8, key: []const u8) u32 {
    const at = std.mem.indexOf(u8, scope, key) orelse return 0;
    var i = at + key.len;
    while (i < scope.len and (scope[i] == ' ' or scope[i] == '\t')) : (i += 1) {}
    var v: u64 = 0;
    var any = false;
    while (i < scope.len and scope[i] >= '0' and scope[i] <= '9') : (i += 1) {
        v = v * 10 + (scope[i] - '0');
        any = true;
        if (v > @as(u64, std.math.maxInt(u32))) return std.math.maxInt(u32);
    }
    if (!any) return 0;
    return @intCast(v);
}

// ══════════════════════════════════════════════════════════
// URL builders
// ══════════════════════════════════════════════════════════

/// Build the RadioBrowser "most-voted stations, paginated" URL — the same
/// `/stations/search` endpoint the text search uses, ordered by votes
/// descending, with BOTH `limit` and `offset`, answering with the identical
/// station-object array, so parseStations below handles it verbatim.
/// This replaced the legacy path-param form (`/topvote/{rowcount}`), which has
/// no offset slot and so could only ever answer page one; `order=votes&
/// reverse=true` reproduces topvote's ranking, so the first window is
/// equivalent in content while loadMore() can walk forward from it.
/// `limit`/`offset` are clamped/saturated so a bad caller can't produce a
/// rejected URL. Returns "" only if `dst` is too small.
pub fn buildPopularUrl(limit: usize, offset: usize, dst: []u8) []const u8 {
    const n = std.math.clamp(limit, 1, 100);
    return std.fmt.bufPrint(
        dst,
        "https://all.api.radio-browser.info/json/stations/search?order=votes&reverse=true&limit={d}&offset={d}&hidebroken=true",
        .{ n, offset },
    ) catch "";
}

/// Build the RadioBrowser station-search URL with `limit`+`offset`, so
/// infinite scroll can walk forward through the same search term. `encoded`
/// must already be percent-encoded (percentEncode in radio.zig) — this
/// function does no escaping of its own. Returns "" only if `dst` is too
/// small.
pub fn buildSearchUrl(encoded: []const u8, limit: usize, offset: usize, dst: []u8) []const u8 {
    const n = std.math.clamp(limit, 1, 100);
    return std.fmt.bufPrint(
        dst,
        "https://all.api.radio-browser.info/json/stations/search?name={s}&limit={d}&offset={d}&hidebroken=true&order=votes&reverse=true",
        .{ encoded, n, offset },
    ) catch "";
}

// ══════════════════════════════════════════════════════════
// RadioBrowser station search JSON → stations
// ══════════════════════════════════════════════════════════

/// Parse a RadioBrowser station-search JSON array into `out`. Each station
/// object is delimited by its `"stationuuid":` marker (present once per
/// station). Only rows that carry a usable stream URL (url_resolved OR url) and
/// a name are kept — a station with neither can't be played. Returns the number
/// of stations written (≤ out.len).
pub fn parseStations(json: []const u8, out: []Station) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < json.len and count < out.len) {
        const marker = "\"stationuuid\":";
        const idx = std.mem.indexOfPos(u8, json, pos, marker) orelse break;
        // Object scope starts at this station's marker and ends at the next
        // station's marker (or EOF) — so field reads see only this station.
        const scan_from = idx + marker.len;
        var obj_end = json.len;
        if (std.mem.indexOfPos(u8, json, scan_from, marker)) |nidx| obj_end = nidx;
        const obj = json[idx..obj_end];
        pos = obj_end;

        var s = &out[count];
        s.* = .{};

        // Stream URL is load-bearing: url_resolved preferred, url fallback.
        s.url_resolved_len = jsonStrField(obj, "\"url_resolved\":\"", &s.url_resolved);
        s.url_len = jsonStrField(obj, "\"url\":\"", &s.url);
        if (s.url_resolved_len == 0 and s.url_len == 0) continue; // unplayable

        s.name_len = jsonStrField(obj, "\"name\":\"", &s.name);
        if (s.name_len == 0) continue;

        s.stationuuid_len = jsonStrField(obj, "\"stationuuid\":\"", &s.stationuuid);
        s.favicon_len = jsonStrField(obj, "\"favicon\":\"", &s.favicon);
        s.tags_len = jsonStrField(obj, "\"tags\":\"", &s.tags);
        s.country_len = jsonStrField(obj, "\"country\":\"", &s.country);
        s.codec_len = jsonStrField(obj, "\"codec\":\"", &s.codec);
        s.votes = jsonIntField(obj, "\"votes\":");
        s.bitrate = jsonIntField(obj, "\"bitrate\":");

        count += 1;
    }
    return count;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "jsonUnescape decodes slashes/quotes/unicode" {
    var buf: [64]u8 = undefined;
    const n = jsonUnescape("http:\\/\\/a.com\\/x", &buf);
    try std.testing.expectEqualStrings("http://a.com/x", buf[0..n]);
    const m = jsonUnescape("a\\u0026b", &buf);
    try std.testing.expectEqualStrings("a&b", buf[0..m]);
}

test "parseStations extracts fields + numeric votes/bitrate" {
    const json =
        \\[
        \\{"changeuuid":"c1","stationuuid":"uuid-1","name":"Jazz FM","url":"http:\/\/a\/1","url_resolved":"http:\/\/a\/1r","homepage":"http:\/\/hp\/1","favicon":"http:\/\/f\/1.png","tags":"jazz,smooth","country":"United Kingdom","codec":"MP3","bitrate":128,"votes":4210},
        \\{"stationuuid":"uuid-2","name":"Rock & Roll","url":"http:\/\/a\/2","url_resolved":"","favicon":"","tags":"rock","country":"USA","codec":"AAC","bitrate":64,"votes":99}
        \\]
    ;
    var out: [8]Station = undefined;
    const n = parseStations(json, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    // First: url_resolved preferred, all fields decoded.
    try std.testing.expectEqualStrings("uuid-1", out[0].stationuuid[0..out[0].stationuuid_len]);
    try std.testing.expectEqualStrings("Jazz FM", out[0].name[0..out[0].name_len]);
    try std.testing.expectEqualStrings("http://a/1r", out[0].url_resolved[0..out[0].url_resolved_len]);
    try std.testing.expectEqualStrings("http://a/1", out[0].url[0..out[0].url_len]);
    try std.testing.expectEqualStrings("http://f/1.png", out[0].favicon[0..out[0].favicon_len]);
    try std.testing.expectEqualStrings("jazz,smooth", out[0].tags[0..out[0].tags_len]);
    try std.testing.expectEqualStrings("United Kingdom", out[0].country[0..out[0].country_len]);
    try std.testing.expectEqualStrings("MP3", out[0].codec[0..out[0].codec_len]);
    try std.testing.expectEqual(@as(u32, 128), out[0].bitrate);
    try std.testing.expectEqual(@as(u32, 4210), out[0].votes);
    // Second: empty url_resolved falls back to url; & decoded.
    try std.testing.expectEqual(@as(usize, 0), out[1].url_resolved_len);
    try std.testing.expectEqualStrings("http://a/2", out[1].url[0..out[1].url_len]);
    try std.testing.expectEqualStrings("Rock & Roll", out[1].name[0..out[1].name_len]);
}

test "buildPopularUrl embeds limit and offset for infinite-scroll paging" {
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://all.api.radio-browser.info/json/stations/search?order=votes&reverse=true&limit=30&offset=0&hidebroken=true",
        buildPopularUrl(30, 0, &buf),
    );
    // A load-more call for the second window — offset advances by the page size.
    try std.testing.expectEqualStrings(
        "https://all.api.radio-browser.info/json/stations/search?order=votes&reverse=true&limit=30&offset=30&hidebroken=true",
        buildPopularUrl(30, 30, &buf),
    );
    // limit still clamps to 1..100; offset is passed through unclamped (a plain
    // cumulative count, never attacker-controlled).
    try std.testing.expectEqualStrings(
        "https://all.api.radio-browser.info/json/stations/search?order=votes&reverse=true&limit=100&offset=150&hidebroken=true",
        buildPopularUrl(9999, 150, &buf),
    );
    try std.testing.expectEqualStrings(
        "https://all.api.radio-browser.info/json/stations/search?order=votes&reverse=true&limit=1&offset=0&hidebroken=true",
        buildPopularUrl(0, 0, &buf),
    );
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", buildPopularUrl(30, 30, &tiny));
}

test "buildSearchUrl embeds the encoded term, limit, and offset" {
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://all.api.radio-browser.info/json/stations/search?name=jazz&limit=30&offset=0&hidebroken=true&order=votes&reverse=true",
        buildSearchUrl("jazz", 30, 0, &buf),
    );
    // loadMore's second window for the same term — only offset changes.
    try std.testing.expectEqualStrings(
        "https://all.api.radio-browser.info/json/stations/search?name=jazz&limit=30&offset=30&hidebroken=true&order=votes&reverse=true",
        buildSearchUrl("jazz", 30, 30, &buf),
    );
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", buildSearchUrl("jazz", 30, 30, &tiny));
}

test "parseStations parses the topvote response with the search parser" {
    // The topvote endpoint answers with the same station objects as search — a
    // regression guard that the popular rail needs no second parser.
    const json =
        \\[{"changeuuid":"c","stationuuid":"78012206","serveruuid":null,"name":"MANGORADIO","url":"https:\/\/m\/s","url_resolved":"https:\/\/m\/s","favicon":"https:\/\/m\/l.png","tags":"music,variety","country":"Germany","votes":815268,"codec":"MP3","bitrate":128,"lastcheckok":1}]
    ;
    var out: [8]Station = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseStations(json, &out));
    try std.testing.expectEqualStrings("MANGORADIO", out[0].name[0..out[0].name_len]);
    try std.testing.expectEqualStrings("https://m/s", out[0].url_resolved[0..out[0].url_resolved_len]);
    try std.testing.expectEqualStrings("https://m/l.png", out[0].favicon[0..out[0].favicon_len]);
    try std.testing.expectEqual(@as(u32, 815268), out[0].votes);
}

test "parseStations skips a station with no playable url" {
    const json =
        \\[
        \\{"stationuuid":"x","name":"No URL"},
        \\{"stationuuid":"y","name":"Has URL","url":"http:\/\/z"}
        \\]
    ;
    var out: [8]Station = undefined;
    const n = parseStations(json, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("Has URL", out[0].name[0..out[0].name_len]);
    try std.testing.expectEqualStrings("http://z", out[0].url[0..out[0].url_len]);
}

test "parseStations regression: malformed JSON never panics" {
    var out: [8]Station = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseStations("", &out));
    try std.testing.expectEqual(@as(usize, 0), parseStations("[", &out));
    try std.testing.expectEqual(@as(usize, 0), parseStations("[{\"stationuuid\":", &out));
    // Truncated value mid-string — must not read past end.
    _ = parseStations("\"stationuuid\":\"y\",\"url\":\"http:\\/\\/", &out);
    _ = parseStations("\"stationuuid\":\"stationuuid\":\"stationuuid\":", &out);
    _ = parseStations("[{\"stationuuid\":\"z\",\"name\":\"n\",\"url\":\"u\",\"bitrate\":99999999999999}]", &out);
}
