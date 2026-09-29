const std = @import("std");
pub const html = @import("content_html_pure.zig");
const cp = @import("comics_pure.zig");
const nsp = @import("novel_sources_pure.zig");

pub fn novelListingHtml(body: []const u8, source: []const u8) ?[]const u8 {
    const marker = if (std.mem.eql(u8, source, "royalroad")) "class=\"fiction-list\"" else if (std.mem.eql(u8, source, "novelfire")) "class=\"novel-list horizontal col2 chapters\"" else return null;
    return nsp.containerInner(body, marker);
}

pub fn chapterListingHtml(body: []const u8, source: []const u8) ?[]const u8 {
    const marker = if (std.mem.eql(u8, source, "royalroad")) "tbody>" else if (std.mem.eql(u8, source, "novelfire")) "class=\"chapter-list\"" else return null;
    return nsp.containerInner(body, marker);
}

pub fn novelSearchUrl(out: []u8, base: []const u8, source: []const u8, query: []const u8, page: u32) ?[]const u8 {
    var enc: [768]u8 = undefined;
    const n = cp.percentEncodeQuery(query, &enc);
    const path = if (std.mem.eql(u8, source, "royalroad")) "/fictions/search?title=" else if (std.mem.eql(u8, source, "novelfire")) "/search?keyword=" else return null;
    return std.fmt.bufPrint(out, "{s}{s}{s}&page={d}", .{ std.mem.trimEnd(u8, base, "/"), path, enc[0..n], page }) catch null;
}

pub fn comicSearchUrl(out: []u8, base: []const u8, source: []const u8, query: []const u8, page: u32) ?[]const u8 {
    var enc: [768]u8 = undefined;
    const n = cp.percentEncodeQuery(query, &enc);
    const b = std.mem.trimEnd(u8, base, "/");
    if (std.mem.eql(u8, source, "weebcentral")) return std.fmt.bufPrint(out, "{s}/search/data?text={s}&sort=Best%20Match&order=Descending&official=Any&display_mode=Full%20Display&offset={d}", .{ b, enc[0..n], (page -| 1) * 32 }) catch null;
    // ComicBookPlus latest uploads is a browsable public-domain feed. Its
    // full-text search needs a site session; filter the returned titles locally.
    if (std.mem.eql(u8, source, "comicbookplus")) {
        if (page <= 1) return std.fmt.bufPrint(out, "{s}/?cbplus=latestuploads", .{b}) catch null;
        return std.fmt.bufPrint(out, "{s}/?cbplus=latestuploads_l_n_{d}", .{ b, page - 1 }) catch null;
    }
    return null;
}

pub fn weebChapterList(out: []u8, base: []const u8, detail: []const u8) ?[]const u8 {
    var abs: [1024]u8 = undefined;
    const url = html.sourceUrl(&abs, base, detail) orelse return null;
    const marker = std.mem.indexOf(u8, url, "/series/") orelse return null;
    const id_start = marker + "/series/".len;
    const id_end = std.mem.indexOfScalarPos(u8, url, id_start, '/') orelse url.len;
    if (id_end - id_start != 26) return null;
    return std.fmt.bufPrint(out, "{s}/full-chapter-list", .{url[0..id_end]}) catch null;
}

pub fn weebImages(out: []u8, base: []const u8, chapter: []const u8) ?[]const u8 {
    var abs: [1024]u8 = undefined;
    const url = html.sourceUrl(&abs, base, chapter) orelse return null;
    if (std.mem.indexOf(u8, url, "/chapters/") == null) return null;
    return std.fmt.bufPrint(out, "{s}/images?is_prev=False&current_page=1&reading_style=long_strip", .{url}) catch null;
}

pub const ComicViewer = struct { directory: []const u8, pages: usize };
pub fn comicBookViewer(body: []const u8) ?ComicViewer {
    const at = (std.mem.indexOf(u8, body, "comicnumpages=") orelse return null) + "comicnumpages=".len;
    const end = std.mem.indexOfScalarPos(u8, body, at, ';') orelse return null;
    const pages = std.fmt.parseInt(usize, std.mem.trim(u8, body[at..end], " \r\n"), 10) catch return null;
    const loc = (std.mem.indexOf(u8, body, "comicloc=\"") orelse return null) + "comicloc=\"".len;
    const le = std.mem.indexOfScalarPos(u8, body, loc, '"') orelse return null;
    const dir = body[loc..le];
    if (pages == 0 or pages > 10000 or !std.mem.startsWith(u8, dir, "viewer/") or std.mem.indexOf(u8, dir, "..") != null) return null;
    for (dir) |c| if (!std.ascii.isAlphanumeric(c) and c != '/') return null;
    return .{ .directory = dir, .pages = pages };
}

test "installed novel search encodes queries and paginates" {
    var out: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("https://rr.test/fictions/search?title=x%26y&page=2", novelSearchUrl(&out, "https://rr.test/", "royalroad", "x&y", 2).?);
    try std.testing.expect(novelSearchUrl(&out, "https://rr.test", "unknown", "x", 1) == null);
}

test "NovelFire search excludes the empty nav search and unrelated popular shelf" {
    const body = "<section id=\"novelListBase\"></section><ul class=\"novel-list horizontal col2 chapters\"><li><a href=\"/book/match\" title=\"Match\">Match</a></li></ul><ul class=\"novel-list\"><a href=\"/book/other\">Other</a></ul>";
    var it = html.AnchorIter{ .html = novelListingHtml(body, "novelfire").?, .path = "/book/" };
    try std.testing.expectEqualStrings("/book/match", it.next().?.url);
    try std.testing.expect(it.next() == null);
}

test "NovelFire chapter ordering excludes latest-chapter banners before the directory" {
    const body = "<aside><a href=\"/book/story/chapter-434\">Latest chapter 434</a></aside><ul class=\"chapter-list\"><li><a href=\"/book/story/chapter-1\" title=\"Chapter 1\">1</a></li><li><a href=\"/book/story/chapter-2\">Chapter 2</a></li></ul>";
    var it = html.AnchorIter{ .html = chapterListingHtml(body, "novelfire").?, .path = "/chapter-" };
    try std.testing.expectEqualStrings("/book/story/chapter-1", it.next().?.url);
    try std.testing.expectEqualStrings("/book/story/chapter-2", it.next().?.url);
    try std.testing.expect(it.next() == null);
}

test "Weeb Central resolves full chapter list and image endpoint" {
    var out: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("https://wc.test/series/01J76XY7E9FNDZ1DBBM6PBJPFK/full-chapter-list", weebChapterList(&out, "https://wc.test", "/series/01J76XY7E9FNDZ1DBBM6PBJPFK/One-Piece").?);
    try std.testing.expect(weebChapterList(&out, "https://wc.test", "/series/short/Title") == null);
    try std.testing.expectEqualStrings("https://wc.test/chapters/id/images?is_prev=False&current_page=1&reading_style=long_strip", weebImages(&out, "https://wc.test", "/chapters/id").?);
}

test "ComicBookPlus viewer preserves page count and rejects unsafe paths" {
    const v = comicBookViewer("comicnumpages=159;comicloc=\"viewer/18/abcdef\";").?;
    try std.testing.expectEqual(@as(usize, 159), v.pages);
    try std.testing.expectEqualStrings("viewer/18/abcdef", v.directory);
    try std.testing.expect(comicBookViewer("comicnumpages=2;comicloc=\"viewer/../secret\";") == null);
}

test "ComicBookPlus follows the publisher's actual next-page route" {
    var out: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("https://cbp.test/?cbplus=latestuploads", comicSearchUrl(&out, "https://cbp.test", "comicbookplus", "", 1).?);
    try std.testing.expectEqualStrings("https://cbp.test/?cbplus=latestuploads_l_n_1", comicSearchUrl(&out, "https://cbp.test", "comicbookplus", "", 2).?);
}
