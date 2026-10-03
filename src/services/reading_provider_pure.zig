//! Independent installed reading providers. Contracts observed at the providers;
//! no third-party implementation code is copied.
const std = @import("std");
const html = @import("content_html_pure.zig");
const json = @import("comics_pure.zig");
const text = @import("novels_pure.zig");
const nsp = @import("novel_sources_pure.zig");
pub const Source = enum { standardebooks, wuxiaclick };
pub const Item = struct {
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    url: [1024]u8 = @splat(0),
    url_len: usize = 0,
    cover: [512]u8 = @splat(0),
    cover_len: usize = 0,
    author: [128]u8 = @splat(0),
    author_len: usize = 0,
    synopsis: [768]u8 = @splat(0),
    synopsis_len: usize = 0,
};
pub const Result = struct { count: usize = 0, valid_listing: bool = false };
pub fn searchUrl(out: []u8, base: []const u8, source: Source, query: []const u8, page: u32) ?[]const u8 {
    if (page == 0 or page > 10000) return null;
    var encoded: [768]u8 = undefined;
    const n = json.percentEncodeStrict(query, &encoded);
    if (query.len > 0 and n == 0) return null;
    const b = std.mem.trimEnd(u8, base, "/");
    if (!validBase(b)) return null;
    return switch (source) {
        .standardebooks => std.fmt.bufPrint(out, "{s}/ebooks?query={s}&page={d}", .{ b, encoded[0..n], page }) catch null,
        .wuxiaclick => std.fmt.bufPrint(out, "{s}/api/search/?search={s}&offset={d}&limit=12", .{ b, encoded[0..n], (page - 1) * 12 }) catch null,
    };
}
fn validBase(base: []const u8) bool {
    if (std.mem.indexOfAny(u8, base, "\r\n") != null) return false;
    const uri = std.Uri.parse(base) catch return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "https") and uri.host != null and uri.user == null and uri.password == null and uri.query == null and uri.fragment == null;
}
fn string(object: []const u8, key: []const u8) []const u8 {
    var needle: [64]u8 = undefined;
    const quoted = std.fmt.bufPrint(&needle, "\"{s}\"", .{key}) catch return "";
    const at = std.mem.indexOf(u8, object, quoted) orelse return "";
    var p = at + quoted.len;
    while (p < object.len and std.ascii.isWhitespace(object[p])) : (p += 1) {}
    if (p >= object.len or object[p] != ':') return "";
    p += 1;
    while (p < object.len and std.ascii.isWhitespace(object[p])) : (p += 1) {}
    if (p >= object.len or object[p] != '"') return "";
    return json.findJsonStr(object[p..], "\"") orelse "";
}
fn slugValid(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > 384) return false;
    for (slug) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}
fn copyCover(item: *Item, base: []const u8, raw: []const u8) void {
    var decoded: [512]u8 = undefined;
    const n = json.jsonUnescape(raw, &decoded);
    const address = decoded[0..n];
    if (std.mem.startsWith(u8, address, "https://")) {
        const uri = std.Uri.parse(address) catch return;
        if (uri.host == null or uri.user != null or uri.password != null or std.mem.indexOfAny(u8, address, "\r\n") != null) return;
        @memcpy(item.cover[0..n], address);
        item.cover_len = n;
    } else if (html.sourceUrl(&item.cover, base, address)) |url| item.cover_len = url.len;
}
pub fn parseInto(body: []const u8, base: []const u8, source: Source, out: []Item) Result {
    if (!validBase(base)) return .{};
    var result: Result = .{};
    if (source == .wuxiaclick) {
        const rows = json.findJsonNode(body, "\"results\"") orelse return result;
        result.valid_listing = true;
        var iter: json.ObjIter = .{ .buf = rows };
        while (iter.next()) |row| {
            if (result.count >= out.len) break;
            const slug = string(row, "slug");
            if (!slugValid(slug)) continue;
            var item: Item = .{};
            item.title_len = json.jsonUnescape(string(row, "name"), &item.title);
            if (item.title_len == 0) continue;
            const address = std.fmt.bufPrint(&item.url, "{s}/novel/{s}", .{ std.mem.trimEnd(u8, base, "/"), slug }) catch continue;
            item.url_len = address.len;
            item.synopsis_len = json.jsonUnescape(string(row, "description"), &item.synopsis);
            if (json.findJsonNode(row, "\"author\"")) |author| item.author_len = json.jsonUnescape(string(author, "name"), &item.author);
            copyCover(&item, base, string(row, "image"));
            out[result.count] = item;
            result.count += 1;
        }
        return result;
    }
    // Only schema:Book list items are works; author links and honeypots never
    // enter the catalog, and the advertised JPEG img is preferred over AVIF.
    var position: usize = 0;
    while (std.mem.indexOfPos(u8, body, position, "<li")) |start| {
        const gt = std.mem.indexOfScalarPos(u8, body, start, '>') orelse break;
        const end = std.mem.indexOfPos(u8, body, gt, "</li>") orelse break;
        position = end + 5;
        const tag = body[start .. gt + 1];
        if (!std.mem.eql(u8, html.attr(tag, "typeof") orelse "", "schema:Book")) continue;
        result.valid_listing = true;
        if (result.count >= out.len) break;
        const raw = html.attr(tag, "about") orelse continue;
        if (!std.mem.startsWith(u8, raw, "/ebooks/")) continue;
        const scope = body[gt + 1 .. end];
        var item: Item = .{};
        const address = html.sourceUrl(&item.url, base, raw) orelse continue;
        item.url_len = address.len;
        var links: html.AnchorIter = .{ .html = scope, .path = raw };
        while (links.next()) |link| {
            var cleaned: [256]u8 = undefined;
            const len = text.htmlToText(link.title, &cleaned);
            if (len > 0) {
                @memcpy(item.title[0..len], cleaned[0..len]);
                item.title_len = len;
            }
            if (link.cover.len > 0) copyCover(&item, base, link.cover);
        }
        if (std.mem.indexOf(u8, scope, "class=\"author\"")) |a| {
            if (nsp.containerInner(scope[a..], "schema:name")) |author| item.author_len = text.htmlToText(author, &item.author);
        }
        if (item.title_len == 0) continue;
        out[result.count] = item;
        result.count += 1;
    }
    // Genuine empty search still contains the site's search form, while a
    // challenge page must not be reported as an empty successful listing.
    result.valid_listing = result.valid_listing or (std.mem.indexOf(u8, body, "name=\"query\"") != null and std.mem.indexOf(u8, body, "Standard Ebooks") != null);
    return result;
}
pub fn chapterListUrl(out: []u8, base: []const u8, source: Source, work: []const u8) ?[]const u8 {
    var owned: [1024]u8 = undefined;
    const checked = html.sourceUrl(&owned, base, work) orelse return null;
    if (source == .standardebooks) {
        const path = checked[std.mem.trimEnd(u8, base, "/").len..];
        if (!std.mem.startsWith(u8, path, "/ebooks/") or std.mem.indexOf(u8, path, "..") != null or std.mem.indexOfAny(u8, path, "%?#\\\r\n") != null) return null;
        return std.fmt.bufPrint(out, "{s}/text", .{std.mem.trimEnd(u8, checked, "/")}) catch null;
    }
    const prefix = std.fmt.bufPrint(out, "{s}/novel/", .{std.mem.trimEnd(u8, base, "/")}) catch return null;
    if (!std.mem.startsWith(u8, checked, prefix)) return null;
    const slug = checked[prefix.len..];
    if (!slugValid(slug)) return null;
    return std.fmt.bufPrint(out, "{s}/api/chapters/{s}/?format=json", .{ std.mem.trimEnd(u8, base, "/"), slug }) catch null;
}
pub const Chapter = struct { title: [256]u8 = @splat(0), title_len: usize = 0, url: [1024]u8 = @splat(0), url_len: usize = 0 };
pub fn chaptersInto(body: []const u8, base: []const u8, source: Source, work: []const u8, out: []Chapter) usize {
    var count: usize = 0;
    if (source == .wuxiaclick) {
        if (body.len == 0 or body[0] != '[') return 0;
        var iter: json.ObjIter = .{ .buf = body };
        while (iter.next()) |row| {
            if (count >= out.len) break;
            const slug = string(row, "novSlugChapSlug");
            if (!slugValid(slug)) continue;
            var chapter: Chapter = .{};
            chapter.title_len = json.jsonUnescape(string(row, "title"), &chapter.title);
            const address = std.fmt.bufPrint(&chapter.url, "{s}/api/getchapter/{s}/", .{ std.mem.trimEnd(u8, base, "/"), slug }) catch continue;
            chapter.url_len = address.len;
            if (chapter.title_len == 0) continue;
            out[count] = chapter;
            count += 1;
        }
        return count;
    }
    const toc = nsp.containerInner(body, "id=\"toc\"") orelse return 0;
    var iter: html.AnchorIter = .{ .html = toc, .path = "text/" };
    while (iter.next()) |anchor| {
        if (count >= out.len) break;
        if (!std.mem.startsWith(u8, anchor.url, "text/") or std.mem.indexOf(u8, anchor.url, "..") != null or std.mem.indexOfAny(u8, anchor.url, "?#\\\r\n") != null) continue;
        const part = anchor.url[5..];
        if (!slugValid(part)) continue;
        var chapter: Chapter = .{};
        chapter.title_len = text.htmlToText(anchor.title, &chapter.title);
        const address = std.fmt.bufPrint(&chapter.url, "{s}/{s}", .{ std.mem.trimEnd(u8, work, "/"), anchor.url }) catch continue;
        chapter.url_len = address.len;
        if (chapter.title_len == 0) continue;
        out[count] = chapter;
        count += 1;
    }
    return count;
}
pub fn chapterText(body: []const u8, source: Source, out: []u8) usize {
    if (source == .wuxiaclick) return json.jsonUnescape(string(body, "text"), out);
    const start = std.mem.indexOf(u8, body, "<main ") orelse return 0;
    const gt = std.mem.indexOfScalarPos(u8, body, start, '>') orelse return 0;
    const end = std.mem.indexOfPos(u8, body, gt, "</main>") orelse return 0;
    return text.htmlToText(body[gt + 1 .. end], out);
}
test "installed providers own query URLs and reject credential or traversal identities" {
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("https://wuxia.click/api/search/?search=dragon%20%26%20rain&offset=12&limit=12", searchUrl(&buf, "https://wuxia.click", .wuxiaclick, "dragon & rain", 2).?);
    try std.testing.expect(searchUrl(&buf, "https://user:secret@host", .standardebooks, "", 1) == null);
    try std.testing.expect(chapterListUrl(&buf, "https://wuxia.click", .wuxiaclick, "https://evil.test/novel/a") == null);
    try std.testing.expect(chapterListUrl(&buf, "https://wuxia.click", .wuxiaclick, "https://wuxia.click/novel/../bad") == null);
    try std.testing.expect(chapterListUrl(&buf, "https://standardebooks.org", .standardebooks, "https://standardebooks.org/ebooks/../../honeypot") == null);
}
test "Standard Ebooks schema works retain author and advertised JPEG excluding navigation" {
    const fixture = "<a href='/honeypot'>trap</a><li typeof='schema:Book' about='/ebooks/author/book'><a href='/ebooks/author/book'><img src='/images/cover.jpg'></a><a href='/ebooks/author/book'><span>Book &amp; Rain</span></a><p class=\"author\"><a href='/ebooks/author'><span property=\"schema:name\">Real Author</span></a></p></li>";
    var items: [3]Item = undefined;
    const parsed = parseInto(fixture, "https://standardebooks.org", .standardebooks, &items);
    try std.testing.expect(parsed.valid_listing);
    try std.testing.expectEqual(@as(usize, 1), parsed.count);
    try std.testing.expectEqualStrings("Book & Rain", items[0].title[0..items[0].title_len]);
    try std.testing.expectEqualStrings("Real Author", items[0].author[0..items[0].author_len]);
    try std.testing.expectEqualStrings("https://standardebooks.org/images/cover.jpg", items[0].cover[0..items[0].cover_len]);
}
test "WuxiaClick listing and chapter text preserve owned metadata and prose line breaks" {
    var items: [2]Item = undefined;
    const parsed = parseInto("{\"results\":[{\"name\":\"Dragon\",\"slug\":\"dragon-1\",\"description\":\"Real\\nSynopsis\",\"image\":\"https://cdn.test/cover.webp\"},{\"name\":\"Bad\",\"slug\":\"../bad\"}]}", "https://wuxia.click", .wuxiaclick, &items);
    try std.testing.expectEqual(@as(usize, 1), parsed.count);
    var output: [128]u8 = undefined;
    const n = chapterText("{\"title\":\"Chapter\",\"text\":\"First line\\nSecond line\"}", .wuxiaclick, &output);
    try std.testing.expectEqualStrings("First line\nSecond line", output[0..n]);
    try std.testing.expect(!parseInto("<h1>Cloudflare challenge</h1>", "https://wuxia.click", .wuxiaclick, &items).valid_listing);
}
test "Standard Ebooks TOC retains provider order and excludes external links" {
    var chapters: [8]Chapter = undefined;
    const n = chaptersInto("<nav id=\"toc\"><a href='text/chapter-1'>I</a><a href='https://evil.test/text/x'>No</a><a href='text/../x'>No</a><a href='text/chapter-2'>II</a></nav>", "https://standardebooks.org", .standardebooks, "https://standardebooks.org/ebooks/author/book", &chapters);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("https://standardebooks.org/ebooks/author/book/text/chapter-1", chapters[0].url[0..chapters[0].url_len]);
    var out: [128]u8 = undefined;
    const length = chapterText("<header>Menu</header><main epub:type='bodymatter'><p>Actual prose.</p></main><footer>Ads</footer>", .standardebooks, &out);
    try std.testing.expect(std.mem.indexOf(u8, out[0..length], "Actual prose.") != null);
}

test "WuxiaClick chapter identities use bounded provider API and preserve directory order" {
    var rows: [2]Chapter = undefined;
    const n = chaptersInto("[{\"index\":1,\"title\":\"First\",\"novSlugChapSlug\":\"dragon-1\"},{\"title\":\"Foreign\",\"novSlugChapSlug\":\"https://evil.test/x\"},{\"index\":2,\"title\":\"Second\",\"novSlugChapSlug\":\"dragon-2\"},{\"index\":3,\"title\":\"Overflow\",\"novSlugChapSlug\":\"dragon-3\"}]", "https://wuxia.click", .wuxiaclick, "https://wuxia.click/novel/dragon", &rows);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("First", rows[0].title[0..rows[0].title_len]);
    try std.testing.expectEqualStrings("https://wuxia.click/api/getchapter/dragon-2/", rows[1].url[0..rows[1].url_len]);
    var url: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("https://wuxia.click/api/chapters/dragon/?format=json", chapterListUrl(&url, "https://wuxia.click", .wuxiaclick, "https://wuxia.click/novel/dragon").?);
    try std.testing.expectEqualStrings("https://standardebooks.org/ebooks/author/book/text", chapterListUrl(&url, "https://standardebooks.org", .standardebooks, "https://standardebooks.org/ebooks/author/book").?);
}
