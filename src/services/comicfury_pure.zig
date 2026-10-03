//! Original public ComicFury listing/reader contract. No extension code copied.
const std = @import("std");
pub const html = @import("content_html_pure.zig");
const cp = @import("comics_pure.zig");

pub fn searchUrl(out: []u8, base: []const u8, query: []const u8, page: u32) ?[]const u8 {
    if (query.len > 256 or page == 0 or page > 1000) return null;
    var encoded: [1024]u8 = undefined;
    const n = cp.percentEncodeQuery(query, &encoded);
    return std.fmt.bufPrint(out, "{s}/search.php?combinedquery={s}&page={d}", .{ std.mem.trimEnd(u8, base, "/"), encoded[0..n], page }) catch null;
}

pub fn firstPageUrl(out: []u8, base: []const u8, profile: []const u8) ?[]const u8 {
    var abs: [1024]u8 = undefined;
    const url = html.sourceUrl(&abs, base, profile) orelse return null;
    const b = std.mem.trimEnd(u8, base, "/");
    if (std.mem.startsWith(u8, url[b.len..], "/read/")) {
        const path = url[b.len..];
        if (std.mem.indexOf(u8, path, "/comics/") == null) return null;
        for (path) |c| if (!std.ascii.isAlphanumeric(c) and c != '/' and c != '-' and c != '_') return null;
        return std.fmt.bufPrint(out, "{s}", .{url}) catch null;
    }
    const marker = "/comicprofile.php?url=";
    const at = (std.mem.indexOf(u8, url, marker) orelse return null) + marker.len;
    const slug = url[at..];
    if (slug.len == 0 or slug.len > 128) return null;
    for (slug) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    return std.fmt.bufPrint(out, "{s}/read/{s}/comics/first", .{ std.mem.trimEnd(u8, base, "/"), slug }) catch null;
}

pub const ImageIter = struct {
    body: []const u8,
    pos: usize = 0,
    pub fn next(self: *ImageIter) ?[]const u8 {
        while (std.mem.indexOfPos(u8, self.body, self.pos, "<img")) |at| {
            const end = std.mem.indexOfScalarPos(u8, self.body, at, '>') orelse return null;
            self.pos = end + 1;
            const tag = self.body[at..self.pos];
            const src = html.attr(tag, "src") orelse continue;
            // ComicFury's owned comic image origin, excluding avatars and UI art.
            if (!std.mem.startsWith(u8, src, "https://img.comicfury.com/comics/") or src.len > 1024 or std.mem.indexOfAny(u8, src, "\r\n") != null) continue;
            return src;
        }
        return null;
    }
};

test "ComicFury real search and first page URLs are bounded source identities" {
    var out: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("https://comicfury.com/search.php?combinedquery=x%26y&page=2", searchUrl(&out, "https://comicfury.com", "x&y", 2).?);
    try std.testing.expectEqualStrings("https://comicfury.com/read/example/comics/first", firstPageUrl(&out, "https://comicfury.com", "/comicprofile.php?url=example").?);
    try std.testing.expect(firstPageUrl(&out, "https://comicfury.com", "https://other.test/comicprofile.php?url=example") == null);
    try std.testing.expect(firstPageUrl(&out, "https://comicfury.com", "/comicprofile.php?url=example&x=y") == null);
    var tiny: [8]u8 = undefined;
    try std.testing.expect(searchUrl(&tiny, "https://comicfury.com", "x", 1) == null);
}

test "ComicFury includes only actual owned comic page images" {
    var it = ImageIter{ .body = "<img src='/avatar.png'><img src='https://img.comicfury.com/comics/1/a.png'><img src='https://img.comicfury.com.evil/comics/1/b.png'>" };
    try std.testing.expectEqualStrings("https://img.comicfury.com/comics/1/a.png", it.next().?);
    try std.testing.expect(it.next() == null);
}

pub const Item = struct {
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    route: [512]u8 = @splat(0),
    route_len: usize = 0,
    cover: [512]u8 = @splat(0),
    cover_len: usize = 0,
};
pub const Listing = struct { count: usize = 0, valid: bool = false };
/// Independent owned rows for universal search; never accesses Comics Browse state.
pub fn parseInto(body: []const u8, base: []const u8, out: []Item) Listing {
    var result: Listing = .{ .valid = std.mem.indexOf(u8, body, "webcomic-results") != null };
    if (!result.valid) return result;
    var it = html.AnchorIter{ .html = body, .path = "/comicprofile.php?url=" };
    var pending_url: [512]u8 = undefined;
    var pending_url_len: usize = 0;
    var pending_cover: [512]u8 = undefined;
    var pending_cover_len: usize = 0;
    while (it.next()) |a| {
        if (result.count >= out.len) break;
        var abs: [512]u8 = undefined;
        const url = html.sourceUrl(&abs, base, a.url) orelse continue;
        var check: [1024]u8 = undefined;
        if (firstPageUrl(&check, base, url) == null) continue;
        if (a.cover.len > 0) {
            @memcpy(pending_url[0..url.len], url);
            pending_url_len = url.len;
            pending_cover_len = 0;
            if (html.sourceUrl(&pending_cover, base, a.cover)) |cover| pending_cover_len = cover.len;
        }
        var item: Item = .{};
        item.title_len = @import("novels_pure.zig").htmlToText(a.title, &item.title);
        if (item.title_len == 0) continue;
        const route = std.fmt.bufPrint(&item.route, "comicfury:{s}", .{url}) catch continue;
        item.route_len = route.len;
        var duplicate = false;
        for (out[0..result.count]) |old| if (std.mem.eql(u8, old.route[0..old.route_len], route)) {
            duplicate = true;
        };
        if (duplicate) continue;
        if (a.cover.len > 0) {
            if (html.sourceUrl(&item.cover, base, a.cover)) |cover| item.cover_len = cover.len;
        }
        if (item.cover_len == 0 and pending_cover_len > 0 and std.mem.eql(u8, pending_url[0..pending_url_len], url)) {
            @memcpy(item.cover[0..pending_cover_len], pending_cover[0..pending_cover_len]);
            item.cover_len = pending_cover_len;
        }
        out[result.count] = item;
        result.count += 1;
    }
    return result;
}

/// Adjacent batch identity from authoritative comic-page attributes.
pub fn adjacentRoute(out: []u8, base: []const u8, page_url: []const u8, body: []const u8, forward: bool) ?[]const u8 {
    var abs: [1024]u8 = undefined;
    const page = html.sourceUrl(&abs, base, page_url) orelse return null;
    const comics = std.mem.indexOf(u8, page, "/comics/") orelse return null;
    var pos: usize = 0;
    var id: ?[]const u8 = null;
    while (std.mem.indexOfPos(u8, body, pos, "<div")) |at| {
        const end = std.mem.indexOfScalarPos(u8, body, at, '>') orelse break;
        pos = end + 1;
        const tag = body[at..pos];
        if (html.attr(tag, "data-comicid") == null) continue;
        id = html.attr(tag, if (forward) "data-next-comicid" else "data-prev-comicid");
        if (!forward) break;
    }
    const number = id orelse return null;
    const numeric = std.fmt.parseInt(u64, number, 10) catch return null;
    if (numeric == 0 or number.len > 20) return null;
    return std.fmt.bufPrint(out, "comicfury:{s}/comics/{s}", .{ page[0..comics], number }) catch null;
}

test "ComicFury adjacent batches use first previous and last next owned identity" {
    var out: [512]u8 = undefined;
    const body = "<div data-comicid='1' data-prev-comicid='-1' data-next-comicid='2'></div><div data-comicid='2' data-prev-comicid='1' data-next-comicid='3'></div>";
    try std.testing.expectEqualStrings("comicfury:https://comicfury.com/read/example/comics/3", adjacentRoute(&out, "https://comicfury.com", "https://comicfury.com/read/example/comics/first", body, true).?);
    try std.testing.expect(adjacentRoute(&out, "https://comicfury.com", "https://comicfury.com/read/example/comics/first", body, false) == null);
}

test "ComicFury owned universal rows retain associated cover deduplicate and reject error pages" {
    var rows: [4]Item = undefined;
    const listing = "<div class='webcomic-results'><a href='/comicprofile.php?url=example'><img src='/comicavatars/a.png'></a><a href='/comicprofile.php?url=example'>Example</a><a href='/comicprofile.php?url=example'>Example</a></div>";
    const result = parseInto(listing, "https://comicfury.com", &rows);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqualStrings("Example", rows[0].title[0..rows[0].title_len]);
    try std.testing.expectEqualStrings("https://comicfury.com/comicavatars/a.png", rows[0].cover[0..rows[0].cover_len]);
    try std.testing.expect(!parseInto("<h1>Unavailable</h1>", "https://comicfury.com", &rows).valid);
}
