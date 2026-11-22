//! M3U/M3U8 IPTV playlist parsing — PURE, unit-tested.
//!
//! Lets a user point Live TV at their OWN playlist (a personal `.m3u` or an IPTV
//! provider's URL) instead of the public directory — which is how most people
//! actually use IPTV. Each `#EXTINF` line + its following URL maps 1:1 onto the
//! existing `IptvChannel` record (name / url / logo / category), so the grid,
//! filters, favorites, health probing and play path all work unchanged.
//!
//!   #EXTM3U
//!   #EXTINF:-1 tvg-id="BBC1.uk" tvg-logo="https://…/bbc.png" group-title="News",BBC One
//!   https://cdn.example/bbc1/index.m3u8

const std = @import("std");
const p = @import("iptv_pure.zig");

/// Value of an `attr="…"` on an `#EXTINF` line, into `dst` (0 if absent).
fn attr(line: []const u8, key: []const u8, dst: []u8) usize {
    var kb: [32]u8 = undefined;
    if (key.len + 2 > kb.len) return 0;
    @memcpy(kb[0..key.len], key);
    kb[key.len] = '=';
    kb[key.len + 1] = '"';
    const needle = kb[0 .. key.len + 2];
    const at = std.mem.indexOf(u8, line, needle) orelse return 0;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return 0;
    const val = line[start..end];
    const n = @min(val.len, dst.len);
    @memcpy(dst[0..n], val[0..n]);
    return n;
}

/// First present attribute among `keys` (aliases for the same header).
fn firstAttr(line: []const u8, keys: []const []const u8, dst: []u8) usize {
    for (keys) |k| {
        const n = attr(line, k, dst);
        if (n > 0) return n;
    }
    return 0;
}

/// A header value from an `#EXTHTTP:{…}` JSON object, by case-insensitive
/// name. Plain string values only (escapes are refused, not half-decoded), and
/// a value carrying control characters is dropped — it becomes an HTTP header.
fn jsonHeader(obj: []const u8, name: []const u8) []const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, obj, i, '"')) |q| {
        const kend = std.mem.indexOfScalarPos(u8, obj, q + 1, '"') orelse return "";
        const key = obj[q + 1 .. kend];
        i = kend + 1;
        var j = kend + 1;
        while (j < obj.len and (obj[j] == ' ' or obj[j] == '\t')) j += 1;
        if (j >= obj.len or obj[j] != ':') continue;
        j += 1;
        while (j < obj.len and (obj[j] == ' ' or obj[j] == '\t')) j += 1;
        if (j >= obj.len or obj[j] != '"') continue;
        const vend = std.mem.indexOfScalarPos(u8, obj, j + 1, '"') orelse return "";
        const val = obj[j + 1 .. vend];
        i = vend + 1;
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        for (val) |ch| if (ch < 0x20 or ch == 0x7f or ch == '\\') return "";
        return val;
    }
    return "";
}

/// The display name on an `#EXTINF` line — everything after the LAST comma.
fn displayName(line: []const u8) []const u8 {
    const comma = std.mem.lastIndexOfScalar(u8, line, ',') orelse return "";
    return std.mem.trim(u8, line[comma + 1 ..], " \r\t");
}

/// The stream URL as it fits the channel record. A URL longer than `cap` is cut
/// at a query-parameter boundary — FAST playlists (Xumo, Local Now, Vizio, TCL)
/// append 1-3 KB of ad-targeting parameters, and cutting one mid-value would
/// send a malformed request. Verified live 2026-11: 18 of 20 sampled long URLs
/// still answer with their HLS manifest after this cut. A URL whose PATH alone
/// overflows is unusable when truncated, so it yields "" (entry skipped).
pub fn fitUrl(line: []const u8, cap: usize) []const u8 {
    if (line.len <= cap) return line;
    const head = line[0..cap];
    const query = std.mem.indexOfScalar(u8, head, '?') orelse return "";
    if (std.mem.lastIndexOfScalar(u8, head, '&')) |amp| {
        if (amp > query) return head[0..amp];
    }
    return head[0..query];
}

/// Value of a `#EXTVLCOPT:<key>=<value>` play hint ("" when the line is another
/// directive or the value is empty).
fn vlcOpt(line: []const u8, key: []const u8) []const u8 {
    const prefix = "#EXTVLCOPT:";
    if (!std.mem.startsWith(u8, line, prefix)) return "";
    const rest = line[prefix.len..];
    if (rest.len <= key.len or !std.ascii.eqlIgnoreCase(rest[0..key.len], key) or rest[key.len] != '=') return "";
    return std.mem.trim(u8, rest[key.len + 1 ..], " \t");
}

/// Only allow http:// and https:// stream URLs from untrusted M3U playlists.
/// Rejects file://, local filesystem paths, and mpv pseudo-protocols
/// (edl://, lavfi://, mf://, av://, ytdl://, etc.).
pub fn isAllowedStreamUrl(url: []const u8) bool {
    if (url.len < 8) return false;
    const is_http = std.ascii.startsWithIgnoreCase(url, "http://");
    const is_https = std.ascii.startsWithIgnoreCase(url, "https://");
    if (!is_http and !is_https) return false;
    for (url) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}

/// Parse an M3U playlist into `out`, keeping entries that pass the same
/// name/url/NSFW/query/category gates as the directory path (via acceptChannel).
/// `nsfw_allowed` lifts the adult gate; `query`/`category` are case-insensitive
/// filters ("" = all). Returns the count written (≤ out.len). Bounds-safe.
pub fn parseM3u(text: []const u8, out: []p.IptvChannel, nsfw_allowed: bool, query: []const u8, category: []const u8) usize {
    var count: usize = 0;
    var pending_name: [160]u8 = undefined;
    var pending_name_len: usize = 0;
    var pending_logo: [256]u8 = undefined;
    var pending_logo_len: usize = 0;
    var pending_cat: [48]u8 = undefined;
    var pending_cat_len: usize = 0;
    var pending_country: [64]u8 = undefined;
    var pending_country_len: usize = 0;
    // Per-entry play hints (#EXTVLCOPT between the #EXTINF and its URL). Some
    // CDNs reject a request without the playlist's declared User-Agent.
    var pending_ua: [256]u8 = undefined;
    var pending_ua_len: usize = 0;
    var pending_ref: [256]u8 = undefined;
    var pending_ref_len: usize = 0;
    // tvg-id (or the mjh-style channel-id) — the XMLTV guide join key.
    var pending_id: [64]u8 = undefined;
    var pending_id_len: usize = 0;
    var have_inf = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (count >= out.len) break;
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "#EXTINF")) {
            const nm = displayName(line);
            pending_name_len = @min(nm.len, pending_name.len);
            @memcpy(pending_name[0..pending_name_len], nm[0..pending_name_len]);
            pending_logo_len = attr(line, "tvg-logo", &pending_logo);
            pending_cat_len = attr(line, "group-title", &pending_cat);
            pending_country_len = attr(line, "tvg-country", &pending_country);
            pending_id_len = attr(line, "tvg-id", &pending_id);
            if (pending_id_len == 0) pending_id_len = attr(line, "channel-id", &pending_id);
            // Per-channel request headers declared on the EXTINF line itself
            // (Kodi/TiviMate style). A later #EXTVLCOPT / #EXTHTTP overrides.
            pending_ua_len = firstAttr(line, &.{ "http-user-agent", "user-agent" }, &pending_ua);
            pending_ref_len = firstAttr(line, &.{ "http-referrer", "http-referer", "referrer", "referer" }, &pending_ref);
            have_inf = true;
            continue;
        }
        if (line[0] == '#') {
            if (have_inf) {
                const ua = vlcOpt(line, "http-user-agent");
                if (ua.len > 0 and ua.len <= pending_ua.len) {
                    @memcpy(pending_ua[0..ua.len], ua);
                    pending_ua_len = ua.len;
                }
                const ref = vlcOpt(line, "http-referrer");
                if (ref.len > 0 and ref.len <= pending_ref.len) {
                    @memcpy(pending_ref[0..ref.len], ref);
                    pending_ref_len = ref.len;
                }
                // #EXTHTTP:{"User-Agent":"…","Referer":"…"} (TiviMate/OTT).
                if (std.mem.startsWith(u8, line, "#EXTHTTP:")) {
                    const obj = line["#EXTHTTP:".len..];
                    const hua = jsonHeader(obj, "user-agent");
                    if (hua.len > 0 and hua.len <= pending_ua.len) {
                        @memcpy(pending_ua[0..hua.len], hua);
                        pending_ua_len = hua.len;
                    }
                    var href = jsonHeader(obj, "referer");
                    if (href.len == 0) href = jsonHeader(obj, "referrer");
                    if (href.len > 0 and href.len <= pending_ref.len) {
                        @memcpy(pending_ref[0..href.len], href);
                        pending_ref_len = href.len;
                    }
                }
            }
            continue; // other directives (#EXTGRP, #KODIPROP…)
        }

        // A non-# line is the stream URL for the pending #EXTINF.
        if (!have_inf) continue;
        have_inf = false;

        var c = &out[count];
        c.* = .{};
        c.name_len = @min(pending_name_len, c.name.len);
        @memcpy(c.name[0..c.name_len], pending_name[0..c.name_len]);
        const stream_url = fitUrl(line, c.url.len);
        if (stream_url.len == 0 or !isAllowedStreamUrl(stream_url)) continue;
        c.url_len = stream_url.len;
        @memcpy(c.url[0..c.url_len], stream_url);
        c.user_agent_len = @min(pending_ua_len, c.user_agent.len);
        @memcpy(c.user_agent[0..c.user_agent_len], pending_ua[0..c.user_agent_len]);
        c.referrer_len = @min(pending_ref_len, c.referrer.len);
        @memcpy(c.referrer[0..c.referrer_len], pending_ref[0..c.referrer_len]);
        c.chan_id_len = @min(pending_id_len, c.chan_id.len);
        @memcpy(c.chan_id[0..c.chan_id_len], pending_id[0..c.chan_id_len]);
        c.logo_len = @min(pending_logo_len, c.logo.len);
        @memcpy(c.logo[0..c.logo_len], pending_logo[0..c.logo_len]);
        c.category_len = @min(pending_cat_len, c.category.len);
        @memcpy(c.category[0..c.category_len], pending_cat[0..c.category_len]);

        const country = playlistCountry(pending_country[0..pending_country_len], pending_cat[0..pending_cat_len]);
        @memcpy(c.country[0..country.len], country);
        c.country_len = country.len;

        const filters = p.Filters{
            .query = query,
            .category = category,
            .country = "",
            .quality = .any,
            .nsfw_allowed = nsfw_allowed,
        };
        // Carry the adult flag (name/url heuristic) so a store can gate it on a
        // setting; acceptChannel still drops it when nsfw_allowed is false.
        c.nsfw = p.isNsfw(c.name[0..c.name_len], c.url[0..c.url_len]);
        if (!p.acceptChannel(c, c.category[0..c.category_len], c.country[0..c.country_len], false, filters)) continue;
        count += 1;
    }
    return count;
}

// ── Tests ──

test "parseM3u maps EXTINF attrs + name + url onto IptvChannel" {
    const m3u =
        "#EXTM3U\n" ++
        "#EXTINF:-1 tvg-id=\"BBC1.uk\" tvg-logo=\"https://x/bbc.png\" group-title=\"News\",BBC One\n" ++
        "https://cdn/bbc1/index.m3u8\n" ++
        "#EXTINF:-1 group-title=\"Sports\",ESPN\n" ++
        "https://cdn/espn.m3u8\n";
    var out: [8]p.IptvChannel = undefined;
    const n = parseM3u(m3u, &out, false, "", "");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("BBC One", out[0].name[0..out[0].name_len]);
    try std.testing.expectEqualStrings("https://cdn/bbc1/index.m3u8", out[0].url[0..out[0].url_len]);
    try std.testing.expectEqualStrings("https://x/bbc.png", out[0].logo[0..out[0].logo_len]);
    try std.testing.expectEqualStrings("News", out[0].category[0..out[0].category_len]);
    try std.testing.expectEqualStrings("ESPN", out[1].name[0..out[1].name_len]);
}

test "parseM3u applies query + category filters + NSFW gate" {
    const m3u =
        "#EXTINF:-1 group-title=\"News\",BBC News\n" ++ "https://a/bbc.m3u8\n" ++
        "#EXTINF:-1 group-title=\"Sports\",ESPN\n" ++ "https://a/espn.m3u8\n" ++
        "#EXTINF:-1 group-title=\"XXX\",Blue XXX\n" ++ "https://a/xxx.m3u8\n";
    var out: [8]p.IptvChannel = undefined;
    // Query "news" → only BBC.
    try std.testing.expectEqual(@as(usize, 1), parseM3u(m3u, &out, false, "news", ""));
    // Category "sports" → only ESPN.
    try std.testing.expectEqual(@as(usize, 1), parseM3u(m3u, &out, false, "", "sports"));
    // No filter, NSFW off → BBC + ESPN (XXX dropped).
    try std.testing.expectEqual(@as(usize, 2), parseM3u(m3u, &out, false, "", ""));
}

test "parseM3u regression: garbage never panics" {
    var out: [4]p.IptvChannel = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseM3u("", &out, false, "", ""));
    try std.testing.expectEqual(@as(usize, 0), parseM3u("#EXTINF:-1,Name\n", &out, false, "", "")); // no url
    _ = parseM3u("#EXTINF\nhttp://a\n#EXTINF:-1,", &out, false, "", "");
}

test "parseM3u rejects non-http(s) schemes and local paths" {
    const m3u =
        "#EXTM3U\n" ++
        "#EXTINF:-1,Local\n/etc/passwd\n" ++
        "#EXTINF:-1,File\nfile:///etc/passwd\n" ++
        "#EXTINF:-1,Edl\nedl://%10%/etc/passwd\n" ++
        "#EXTINF:-1,Lavfi\nlavfi://testsrc\n" ++
        "#EXTINF:-1,Ytdl\nytdl://https://evil.example/x\n" ++
        "#EXTINF:-1,Safe\nhttps://cdn.example/live.m3u8\n";
    var out: [8]p.IptvChannel = undefined;
    const n = parseM3u(m3u, &out, false, "", "");
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("Safe", out[0].name[0..out[0].name_len]);
}

fn playlistCountry(explicit: []const u8, group: []const u8) []const u8 {
    const countries = @import("countries_pure.zig");
    for ([_][]const u8{ explicit, group }) |raw| {
        const text = std.mem.trim(u8, raw, " ");
        if (std.ascii.eqlIgnoreCase(text, "UK")) return "GB";
        for (countries.all[1..]) |country| {
            if (std.ascii.eqlIgnoreCase(text, country.code) or std.ascii.eqlIgnoreCase(text, country.name)) return country.code;
        }
    }
    return "";
}
test "playlist catalog preserves explicit countries and geographic group names" {
    var rows: [3]p.IptvChannel = undefined;
    const n = parseM3u("#EXTM3U\n#EXTINF:-1 tvg-country=\"IN\" group-title=\"News\",India news\nhttps://tv.test/in.m3u8\n#EXTINF:-1 group-title=\"United Kingdom\",British news\nhttps://tv.test/uk.m3u8\n", &rows, false, "", "");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("IN", rows[0].country[0..rows[0].country_len]);
    try std.testing.expectEqualStrings("GB", rows[1].country[0..rows[1].country_len]);
    try std.testing.expectEqualStrings("", playlistCountry("", "News"));
}

test "regression: long FAST stream URLs are cut at a parameter boundary, never mid-value" {
    // Captured shape: apsattv.com xumo.m3u (2026-11) — 372 of 389 URLs exceed the
    // 512-byte channel field; the blind cut landed inside an ad parameter.
    const base = "https://dbrb49pjoymg4.cloudfront.net/10001/99991635/hls/playlist.m3u8?ads.xumo_channelId=99991635&ads._fw_ifa_type=[IFA_TYPE]";
    try std.testing.expectEqualStrings(base, fitUrl(base, 512));
    try std.testing.expectEqualStrings(
        "https://dbrb49pjoymg4.cloudfront.net/10001/99991635/hls/playlist.m3u8?ads.xumo_channelId=99991635",
        fitUrl(base, 110),
    );
    // Only one parameter fits → drop the whole query, keep the manifest path.
    try std.testing.expectEqualStrings("https://dbrb49pjoymg4.cloudfront.net/10001/99991635/hls/playlist.m3u8", fitUrl(base, 80));
    // The path itself overflows → unusable, skipped by the parser.
    try std.testing.expectEqualStrings("", fitUrl(base, 40));

    var long: [900]u8 = undefined;
    const filler = "&ads.caid=FoxNewsNow";
    @memcpy(long[0..base.len], base);
    var w: usize = base.len;
    while (w + filler.len <= long.len) : (w += filler.len) @memcpy(long[w..][0..filler.len], filler);
    var text: [1024]u8 = undefined;
    const m3u = try std.fmt.bufPrint(&text, "#EXTINF:-1 group-title=\"News\",LiveNOW from FOX\n{s}\n", .{long[0..w]});
    var rows: [1]p.IptvChannel = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseM3u(m3u, &rows, false, "", ""));
    const got = rows[0].url[0..rows[0].url_len];
    try std.testing.expect(got.len <= rows[0].url.len);
    try std.testing.expect(std.mem.endsWith(u8, got, "ads.caid=FoxNewsNow"));
}

test "tvg-id (or channel-id) is kept as the guide join key" {
    const m3u =
        "#EXTM3U url-tvg=\"https://epg.example/guide.xml.gz\"\n" ++
        "#EXTINF:-1 tvg-id=\"BBCOne.uk\" group-title=\"News\",BBC One HD\nhttps://cdn/bbc1.m3u8\n" ++
        "#EXTINF:-1 channel-id=\"mjh-sky-hgtv\",HGTV\nhttps://cdn/hgtv.m3u8\n" ++
        "#EXTINF:-1,No Id\nhttps://cdn/none.m3u8\n";
    var rows: [3]p.IptvChannel = undefined;
    try std.testing.expectEqual(@as(usize, 3), parseM3u(m3u, &rows, false, "", ""));
    try std.testing.expectEqualStrings("BBCOne.uk", rows[0].chan_id[0..rows[0].chan_id_len]);
    try std.testing.expectEqualStrings("mjh-sky-hgtv", rows[1].chan_id[0..rows[1].chan_id_len]);
    try std.testing.expectEqual(@as(usize, 0), rows[2].chan_id_len);
}

test "per-channel request headers from EXTINF attrs and #EXTHTTP, scoped per entry" {
    const m3u =
        "#EXTM3U\n" ++
        "#EXTINF:-1 http-referrer=\"https://site.example/\" http-user-agent=\"Kodi/20\",Attr\nhttps://cdn/a.m3u8\n" ++
        "#EXTINF:-1 user-agent=\"OldUA\",Http\n" ++
        "#EXTHTTP:{\"User-Agent\":\"TiviMate/4.7\", \"Referer\":\"https://ott.example/\"}\n" ++
        "https://cdn/b.m3u8\n" ++
        "#EXTINF:-1,Bad\n" ++
        "#EXTHTTP:{\"user-agent\":\"evil\\r\\nX: y\"}\n" ++
        "https://cdn/c.m3u8\n" ++
        "#EXTINF:-1,Plain\nhttps://cdn/d.m3u8\n";
    var rows: [4]p.IptvChannel = undefined;
    try std.testing.expectEqual(@as(usize, 4), parseM3u(m3u, &rows, false, "", ""));
    try std.testing.expectEqualStrings("Kodi/20", rows[0].user_agent[0..rows[0].user_agent_len]);
    try std.testing.expectEqualStrings("https://site.example/", rows[0].referrer[0..rows[0].referrer_len]);
    // #EXTHTTP overrides the line's attribute.
    try std.testing.expectEqualStrings("TiviMate/4.7", rows[1].user_agent[0..rows[1].user_agent_len]);
    try std.testing.expectEqualStrings("https://ott.example/", rows[1].referrer[0..rows[1].referrer_len]);
    // An escaped/control-laden value is refused, not passed on as a header.
    try std.testing.expectEqual(@as(usize, 0), rows[2].user_agent_len);
    // Hints never leak into the next entry.
    try std.testing.expectEqual(@as(usize, 0), rows[3].user_agent_len);
    try std.testing.expectEqual(@as(usize, 0), rows[3].referrer_len);
}

test "EXTVLCOPT play hints attach to their own channel only" {
    // Captured shape: i.mjh.nz/nz/raw-tv.m3u8 (2026-11).
    const m3u =
        "#EXTM3U\n" ++
        "#EXTINF:-1 channel-id=\"mjh-sky-hgtv\" group-title=\"Nz\" , HGTV\n" ++
        "#EXTVLCOPT:http-user-agent=otg/1.5.1 (AppleTv Apple TV 4; tvOS16.0; appletv.client) libcurl/7.58.0\n" ++
        "#EXTVLCOPT:http-referrer=\n" ++
        "https://i.mjh.nz/.r/sky-hgtv.m3u8\n" ++
        "#EXTINF:-1 group-title=\"Nz\",Plain\n" ++
        "#EXTVLCOPT:http-referrer=https://example.test/\n" ++
        "https://i.mjh.nz/.r/plain.m3u8\n";
    var rows: [2]p.IptvChannel = undefined;
    try std.testing.expectEqual(@as(usize, 2), parseM3u(m3u, &rows, false, "", ""));
    try std.testing.expectEqualStrings("HGTV", rows[0].name[0..rows[0].name_len]);
    try std.testing.expect(std.mem.startsWith(u8, rows[0].user_agent[0..rows[0].user_agent_len], "otg/1.5.1 (AppleTv"));
    try std.testing.expectEqual(@as(usize, 0), rows[0].referrer_len);
    try std.testing.expectEqual(@as(usize, 0), rows[1].user_agent_len);
    try std.testing.expectEqualStrings("https://example.test/", rows[1].referrer[0..rows[1].referrer_len]);
}
