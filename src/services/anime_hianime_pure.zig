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
