//! Original HiAnime/ZokoAnime contract adapter; no upstream implementation copied.
const std = @import("std");
const html = @import("content_html_pure.zig");
const catalog = @import("anime_catalog_pure.zig");

pub fn showSlug(body: []const u8, name: []const u8, alias: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, body, "id=\"main-sidebar\"") orelse body.len;
    var it = html.AnchorIter{ .html = body[0..end], .path = "-" };
    while (it.next()) |a| {
        if (!catalog.titleMatches(a.title, name) and (alias.len == 0 or !catalog.titleMatches(a.title, alias))) continue;
        const slash = std.mem.lastIndexOfScalar(u8, a.url, '/') orelse continue;
        const slug = a.url[slash + 1 ..];
        if (slug.len == 0 or slug.len > 160) continue;
        var valid = true;
        for (slug) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') {
            valid = false;
        };
        if (!valid) continue;
        if (std.mem.indexOfAny(u8, slug, "?&#\\") != null) continue;
        const dash = std.mem.lastIndexOfScalar(u8, slug, '-') orelse continue;
        _ = std.fmt.parseInt(u32, slug[dash + 1 ..], 10) catch continue;
        return slug;
    }
    return null;
}

/// Show titles on a search page, in page order, for universal search rows.
/// Only result cards (`film-name` links ending in a numeric show id) before
/// the sidebar; `out` receives entity-decoded text. Returns the count.
pub fn searchTitles(body: []const u8, out: [][256]u8, lens: []usize) usize {
    const end = std.mem.indexOf(u8, body, "id=\"main-sidebar\"") orelse body.len;
    var it = html.AnchorIter{ .html = body[0..end], .path = "-" };
    var count: usize = 0;
    while (it.next()) |a| {
        if (count == out.len or count == lens.len) break;
        if (std.mem.indexOf(u8, a.url, "/watch/") != null) continue; // poster link duplicates the card
        const slash = std.mem.lastIndexOfScalar(u8, a.url, '/') orelse continue;
        const slug = a.url[slash + 1 ..];
        const dash = std.mem.lastIndexOfScalar(u8, slug, '-') orelse continue;
        _ = std.fmt.parseInt(u32, slug[dash + 1 ..], 10) catch continue;
        const n = decodeEntities(std.mem.trim(u8, a.title, " \t\r\n"), &out[count]);
        if (n < 2 or std.mem.indexOfScalar(u8, out[count][0..n], '<') != null) continue;
        var dup = false;
        for (0..count) |i| {
            if (std.mem.eql(u8, out[i][0..lens[i]], out[count][0..n])) dup = true;
        }
        if (dup) continue;
        lens[count] = n;
        count += 1;
    }
    return count;
}

fn decodeEntities(text: []const u8, out: []u8) usize {
    const table = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&#039;", "'" }, .{ "&#39;", "'" }, .{ "&quot;", "\"" }, .{ "&lt;", "<" }, .{ "&gt;", ">" } };
    var i: usize = 0;
    var n: usize = 0;
    outer: while (i < text.len and n < out.len) {
        if (text[i] == '&') for (table) |pair| {
            if (std.mem.startsWith(u8, text[i..], pair[0])) {
                out[n] = pair[1][0];
                n += 1;
                i += pair[0].len;
                continue :outer;
            }
        };
        out[n] = text[i];
        n += 1;
        i += 1;
    }
    return n;
}

pub fn episodeId(body: []const u8, ep: usize) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "<a")) |at| {
        const end = std.mem.indexOfScalarPos(u8, body, at, '>') orelse return null;
        pos = end + 1;
        const tag = body[at..pos];
        const number = html.attr(tag, "data-number") orelse continue;
        if ((std.fmt.parseInt(usize, number, 10) catch continue) != ep) continue;
        const id = html.attr(tag, "data-id") orelse continue;
        _ = std.fmt.parseInt(u64, id, 10) catch continue;
        if (id.len > 0 and id.len <= 20) return id;
    }
    return null;
}

pub fn embed(body: []const u8, out: []u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "<div")) |at| {
        const end = std.mem.indexOfScalarPos(u8, body, at, '>') orelse return null;
        pos = end + 1;
        const tag = body[at..pos];
        if (!std.mem.eql(u8, html.attr(tag, "data-type") orelse "", "sub") or !std.mem.eql(u8, html.attr(tag, "data-server-name") orelse "", "ZokoAnime")) continue;
        const raw = html.attr(tag, "data-hash") orelse continue;
        const n = std.base64.standard.Decoder.calcSizeForSlice(raw) catch continue;
        if (n > out.len) continue;
        std.base64.standard.Decoder.decode(out[0..n], raw) catch continue;
        if (!std.mem.startsWith(u8, out[0..n], "https://zokoanime.video/stream/mal/") or std.mem.indexOfAny(u8, out[0..n], "\r\n") != null) continue;
        return out[0..n];
    }
    return null;
}

pub fn configJson(body: []const u8, out: []u8) ?[]const u8 {
    const marker = "window.__P=\"";
    const start = (std.mem.indexOf(u8, body, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return null;
    const raw = body[start..end];
    const n = std.base64.standard.Decoder.calcSizeForSlice(raw) catch return null;
    if (n > out.len) return null;
    std.base64.standard.Decoder.decode(out[0..n], raw) catch return null;
    const key = "otaku-embed-v1";
    for (out[0..n], 0..) |*b, i| b.* ^= key[i % key.len];
    return out[0..n];
}

pub fn streamUrl(value: std.json.Value) ?[]const u8 {
    const src = catalog.string(catalog.field(value, "src"));
    if (!std.mem.startsWith(u8, src, "https://") or src.len > 1024 or std.mem.indexOfAny(u8, src, "\r\n") != null) return null;
    const end = std.mem.indexOfAny(u8, src, "?#") orelse src.len;
    if (!std.mem.endsWith(u8, src[0..end], ".m3u8") and !std.mem.endsWith(u8, src[0..end], ".mp4")) return null;
    return src;
}

test "HiAnime selects exact show and requested numeric episode" {
    try std.testing.expectEqualStrings("naruto-1335", showSlug("<a href='/naruto-shippuden-1' title='Naruto Shippuden'>x</a><a href='/naruto-1335' title='Naruto'>x</a>", "Naruto", "").?);
    try std.testing.expect(showSlug("<a href='/other-1' title='Other'>x</a>", "Naruto", "") == null);
    try std.testing.expectEqualStrings("22676", episodeId("<a data-number='1' data-id='22676'></a><a data-number='2' data-id='x'></a>", 1).?);
    try std.testing.expect(episodeId("<a data-number='2' data-id='x'></a>", 2) == null);
}

test "HiAnime rejects unknown servers bad encoded data and webpage streams" {
    var buf: [1024]u8 = undefined;
    try std.testing.expect(embed("<div data-type='sub' data-server-name='Other' data-hash='eA=='></div>", &buf) == null);
    try std.testing.expect(configJson("window.__P=\"!invalid\"", &buf) == null);
    const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"src\":\"https://site.test/watch/1\"}", .{});
    defer doc.deinit();
    try std.testing.expect(streamUrl(doc.value) == null);
}

test "HiAnime search lists each result card once with decoded titles" {
    // Card markup captured from hianime.fm/search?keyword=naruto (2026-11).
    const page =
        \\<a href="https://hianime.fm/home" title="Home">Home</a>
        \\<div class="flw-item"><a href="https://hianime.fm/watch/naruto-1335" class="film-poster-ahref item-qtip" title="Naruto" data-id="1335"><i></i></a>
        \\<h3 class="film-name"> <a href="https://hianime.fm/naruto-1335" title="Naruto" class="dynamic-name" data-jname="Naruto"> Naruto </a> </h3></div>
        \\<h3 class="film-name"> <a href="https://hianime.fm/boruto-naruto-next-generations-650" title="Boruto: Naruto Next Generations" class="dynamic-name">x</a> </h3>
        \\<h3 class="film-name"> <a href="https://hianime.fm/rock-lee-amp-his-ninja-pals-99" title="Rock Lee &amp; His Ninja Pals&#039;" class="dynamic-name">x</a> </h3>
        \\<h3 class="film-name"> <a href="https://hianime.fm/naruto-1335" title="Naruto" class="dynamic-name">dup</a> </h3>
        \\<div id="main-sidebar"><a href="/one-piece-100" title="One Piece">x</a></div>
    ;
    var titles: [6][256]u8 = undefined;
    var lens: [6]usize = undefined;
    try std.testing.expectEqual(@as(usize, 3), searchTitles(page, &titles, &lens));
    try std.testing.expectEqualStrings("Naruto", titles[0][0..lens[0]]);
    try std.testing.expectEqualStrings("Boruto: Naruto Next Generations", titles[1][0..lens[1]]);
    try std.testing.expectEqualStrings("Rock Lee & His Ninja Pals'", titles[2][0..lens[2]]);
    try std.testing.expectEqual(@as(usize, 0), searchTitles("<title>Just a moment...</title>", &titles, &lens));
}
