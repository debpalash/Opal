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

/// The display name on an `#EXTINF` line — everything after the LAST comma.
fn displayName(line: []const u8) []const u8 {
    const comma = std.mem.lastIndexOfScalar(u8, line, ',') orelse return "";
    return std.mem.trim(u8, line[comma + 1 ..], " \r\t");
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
            have_inf = true;
            continue;
        }
        if (line[0] == '#') continue; // other directives (#EXTGRP, #EXTVLCOPT…)

        // A non-# line is the stream URL for the pending #EXTINF.
        if (!have_inf) continue;
        have_inf = false;

        var c = &out[count];
        c.* = .{};
        c.name_len = @min(pending_name_len, c.name.len);
        @memcpy(c.name[0..c.name_len], pending_name[0..c.name_len]);
        c.url_len = @min(line.len, c.url.len);
        @memcpy(c.url[0..c.url_len], line[0..c.url_len]);
        c.logo_len = @min(pending_logo_len, c.logo.len);
        @memcpy(c.logo[0..c.logo_len], pending_logo[0..c.logo_len]);
        c.category_len = @min(pending_cat_len, c.category.len);
        @memcpy(c.category[0..c.category_len], pending_cat[0..c.category_len]);

        const filters = p.Filters{
            .query = query,
            .category = category,
            .country = "",
            .quality = .any,
            .nsfw_allowed = nsfw_allowed,
        };
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
