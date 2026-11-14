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
// The public site migrated to server-rendered pages in November 2026.
// Private/legacy adapters keep their existing JSON endpoint contract.
pub fn modernWuxia(base: []const u8) bool {
    const uri = std.Uri.parse(base) catch return false;
    const host = if (uri.host) |value| value.percent_encoded else return false;
    return std.ascii.eqlIgnoreCase(host, "wuxia.click") or std.ascii.eqlIgnoreCase(host, "www.wuxia.click");
}
fn pageData(body: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, body, "id=\"__NEXT_DATA__\"") orelse return null;
    const start = std.mem.indexOfScalarPos(u8, body, at, '>') orelse return null;
    const end = std.mem.indexOfPos(u8, body, start, "</script>") orelse return null;
    const props = json.findJsonNode(body[start + 1 .. end], "\"pageProps\"") orelse return null;
    return props;
}
fn number(object: []const u8, key: []const u8) usize {
    var needle: [64]u8 = undefined;
    const quoted = std.fmt.bufPrint(&needle, "\"{s}\"", .{key}) catch return 0;
    const at = std.mem.indexOf(u8, object, quoted) orelse return 0;
    var start = at + quoted.len;
    while (start < object.len and (std.ascii.isWhitespace(object[start]) or object[start] == ':')) : (start += 1) {}
    var end = start;
    while (end < object.len and std.ascii.isDigit(object[end])) : (end += 1) {}
    return std.fmt.parseInt(usize, object[start..end], 10) catch 0;
}
pub fn searchUrl(out: []u8, base: []const u8, source: Source, query: []const u8, page: u32) ?[]const u8 {
    if (page == 0 or page > 10000) return null;
    var encoded: [768]u8 = undefined;
    const n = json.percentEncodeStrict(query, &encoded);
    if (query.len > 0 and n == 0) return null;
    const b = std.mem.trimEnd(u8, base, "/");
    if (!validBase(b)) return null;
    return switch (source) {
        .standardebooks => std.fmt.bufPrint(out, "{s}/ebooks?query={s}&page={d}", .{ b, encoded[0..n], page }) catch null,
        .wuxiaclick => if (modernWuxia(b))
            std.fmt.bufPrint(out, "{s}/search?q={s}&page={d}", .{ b, encoded[0..n], page }) catch null
        else
            std.fmt.bufPrint(out, "{s}/api/search/?search={s}&offset={d}&limit=12", .{ b, encoded[0..n], (page - 1) * 12 }) catch null,
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
        const modern = pageData(body);
        const rows = if (modern) |data| blk: {
            const listing = json.findJsonNode(data, "\"result\"") orelse return result;
            break :blk json.findJsonNode(listing, "\"items\"") orelse return result;
        } else json.findJsonNode(body, "\"results\"") orelse return result;
        result.valid_listing = true;
        var iter: json.ObjIter = .{ .buf = rows };
        while (iter.next()) |row| {
            if (result.count >= out.len) break;
            const slug = string(row, "slug");
            if (!slugValid(slug)) continue;
            var item: Item = .{};
            item.title_len = json.jsonUnescape(string(row, if (modern != null) "title" else "name"), &item.title);
            if (item.title_len == 0) continue;
            const address = std.fmt.bufPrint(&item.url, "{s}/novel/{s}", .{ std.mem.trimEnd(u8, base, "/"), slug }) catch continue;
            item.url_len = address.len;
            item.synopsis_len = json.jsonUnescape(string(row, "description"), &item.synopsis);
            if (json.findJsonNode(row, "\"author\"")) |author| item.author_len = json.jsonUnescape(string(author, "name"), &item.author);
            copyCover(&item, base, string(row, "image"));
            if (modern != null) {
                item.author_len = json.jsonUnescape(string(row, "authorName"), &item.author);
                const key = string(row, "coverKey");
                if (std.mem.startsWith(u8, key, "covers/v1/") and slugValid(key[10..])) {
                    const cover = std.fmt.bufPrint(&item.cover, "https://cdn.wuxiaworld.eu/{s}-240.webp", .{key}) catch "";
                    item.cover_len = cover.len;
                }
            }
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
    if (modernWuxia(base)) return std.fmt.bufPrint(out, "{s}", .{checked}) catch null;
    return std.fmt.bufPrint(out, "{s}/api/chapters/{s}/?format=json", .{ std.mem.trimEnd(u8, base, "/"), slug }) catch null;
}
pub const Chapter = struct { title: [256]u8 = @splat(0), title_len: usize = 0, url: [1024]u8 = @splat(0), url_len: usize = 0 };
pub const ChapterWindow = struct { count: usize = 0, total: usize = 0, has_more: bool = false, matched_ordinal: ?usize = null, page_count: usize = 0, page_total: usize = 0 };
pub fn windowSlot(ordinal: usize, offset: usize, capacity: usize) ?usize {
    if (ordinal < offset or ordinal - offset >= capacity) return null;
    return ordinal - offset;
}
pub fn chaptersInto(body: []const u8, base: []const u8, source: Source, work: []const u8, out: []Chapter) usize {
    return chaptersWindowInto(body, base, source, work, 0, out).count;
}
pub fn chaptersWindowInto(body: []const u8, base: []const u8, source: Source, work: []const u8, offset: usize, out: []Chapter) ChapterWindow {
    return chaptersWindowTargetInto(body, base, source, work, offset, "", out);
}
pub fn chaptersWindowTargetInto(body: []const u8, base: []const u8, source: Source, work: []const u8, offset: usize, target: []const u8, out: []Chapter) ChapterWindow {
    return chaptersPageTargetInto(body, base, source, work, offset, target, 0, out);
}
/// A provider range counts chapter numbers, which may have gaps. The caller
/// supplies how many real chapters preceded this page, keeping ordinals dense.
pub fn chaptersPageTargetInto(body: []const u8, base: []const u8, source: Source, work: []const u8, offset: usize, target: []const u8, first_ordinal: usize, out: []Chapter) ChapterWindow {
    var result: ChapterWindow = .{};
    if (source == .wuxiaclick) {
        if (pageData(body)) |data| {
            const novel = json.findJsonNode(data, "\"novel\"") orelse return result;
            const slug = string(novel, "slug");
            if (!slugValid(slug)) return result;
            var identity: [1024]u8 = undefined;
            const expected = std.fmt.bufPrint(&identity, "{s}/novel/{s}", .{ std.mem.trimEnd(u8, base, "/"), slug }) catch return result;
            if (!std.mem.eql(u8, expected, std.mem.trimEnd(u8, work, "/"))) return result;
            const toc = json.findJsonNode(data, "\"toc\"") orelse return result;
            const rows = json.findJsonNode(toc, "\"items\"") orelse return result;
            const range = json.findJsonNode(toc, "\"range\"") orelse return result;
            const page = number(range, "page");
            if (page == 0 or page > 10000) return result;
            var ordinal = first_ordinal;
            result.total = number(novel, "chapterCount");
            result.page_total = number(toc, "ranges");
            if (result.page_total == 0) result.page_total = (result.total +| 99) / 100;
            var iter: json.ObjIter = .{ .buf = rows };
            while (iter.next()) |row| {
                const chapter_number = number(row, "number");
                if (chapter_number == 0) continue;
                var chapter: Chapter = .{};
                chapter.title_len = json.jsonUnescape(string(row, "title"), &chapter.title);
                const address = std.fmt.bufPrint(&chapter.url, "{s}/chapter/{s}-{d}", .{ std.mem.trimEnd(u8, base, "/"), slug, chapter_number }) catch continue;
                chapter.url_len = address.len;
                if (target.len > 0 and std.mem.eql(u8, address, target)) result.matched_ordinal = ordinal;
                if (windowSlot(ordinal, offset, out.len)) |slot| {
                    out[slot] = chapter;
                    result.count += 1;
                }
                ordinal += 1;
                result.page_count += 1;
            }
            result.has_more = result.total > offset +| result.count;
            return result;
        }
        if (body.len == 0 or body[0] != '[') return result;
        var iter: json.ObjIter = .{ .buf = body };
        while (iter.next()) |row| {
            const slug = string(row, "novSlugChapSlug");
            if (!slugValid(slug)) continue;
            var chapter: Chapter = .{};
            chapter.title_len = json.jsonUnescape(string(row, "title"), &chapter.title);
            const address = std.fmt.bufPrint(&chapter.url, "{s}/api/getchapter/{s}/", .{ std.mem.trimEnd(u8, base, "/"), slug }) catch continue;
            chapter.url_len = address.len;
            if (chapter.title_len == 0) continue;
            if (target.len > 0 and std.mem.eql(u8, address, target)) result.matched_ordinal = result.total;
            if (windowSlot(result.total, offset, out.len)) |slot| {
                out[slot] = chapter;
                result.count += 1;
            }
            result.total += 1;
        }
        result.has_more = result.total > offset +| result.count;
        return result;
    }
    const toc = nsp.containerInner(body, "id=\"toc\"") orelse return result;
    var iter: html.AnchorIter = .{ .html = toc, .path = "text/" };
    while (iter.next()) |anchor| {
        if (!std.mem.startsWith(u8, anchor.url, "text/") or std.mem.indexOf(u8, anchor.url, "..") != null or std.mem.indexOfAny(u8, anchor.url, "?#\\\r\n") != null) continue;
        const part = anchor.url[5..];
        if (!slugValid(part)) continue;
        var chapter: Chapter = .{};
        chapter.title_len = text.htmlToText(anchor.title, &chapter.title);
        const address = std.fmt.bufPrint(&chapter.url, "{s}/{s}", .{ std.mem.trimEnd(u8, work, "/"), anchor.url }) catch continue;
        chapter.url_len = address.len;
        if (chapter.title_len == 0) continue;
        if (target.len > 0 and std.mem.eql(u8, address, target)) result.matched_ordinal = result.total;
        if (windowSlot(result.total, offset, out.len)) |slot| {
            out[slot] = chapter;
            result.count += 1;
        }
        result.total += 1;
    }
    result.has_more = result.total > offset +| result.count;
    return result;
}
pub fn chapterText(body: []const u8, source: Source, out: []u8) usize {
    if (source == .wuxiaclick) {
        if (pageData(body)) |data| {
            const chapter = json.findJsonNode(data, "\"chapter\"") orelse return 0;
            const paragraphs = json.findJsonNode(chapter, "\"paragraphs\"") orelse return 0;
            var iter: json.StrIter = .{ .buf = paragraphs };
            var n: usize = 0;
            while (iter.next()) |paragraph| {
                if (n > 0 and out.len - n >= 2) {
                    out[n] = '\n';
                    out[n + 1] = '\n';
                    n += 2;
                }
                n += json.jsonUnescape(paragraph, out[n..]);
                if (n == out.len) break;
            }
            return n;
        }
        return json.jsonUnescape(string(body, "text"), out);
    }
    const start = std.mem.indexOf(u8, body, "<main ") orelse return 0;
    const gt = std.mem.indexOfScalarPos(u8, body, start, '>') orelse return 0;
    const end = std.mem.indexOfPos(u8, body, gt, "</main>") orelse return 0;
    return text.htmlToText(body[gt + 1 .. end], out);
}
test "installed providers own query URLs and reject credential or traversal identities" {
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("https://wuxia.click/search?q=dragon%20%26%20rain&page=2", searchUrl(&buf, "https://wuxia.click", .wuxiaclick, "dragon & rain", 2).?);
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
    try std.testing.expectEqualStrings("https://wuxia.click/novel/dragon", chapterListUrl(&url, "https://wuxia.click", .wuxiaclick, "https://wuxia.click/novel/dragon").?);
    try std.testing.expectEqualStrings("https://standardebooks.org/ebooks/author/book/text", chapterListUrl(&url, "https://standardebooks.org", .standardebooks, "https://standardebooks.org/ebooks/author/book").?);
}

test "chapter windows traverse more than eight hundred entries without expanding row storage" {
    var body: [150000]u8 = undefined;
    var writer = std.Io.Writer.fixed(&body);
    try writer.writeAll("[");
    for (0..905) |i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"title\":\"Chapter {d}\",\"novSlugChapSlug\":\"book-{d}\"}}", .{ i + 1, i + 1 });
    }
    try writer.writeAll("]");
    var rows: [400]Chapter = undefined;
    for ([_]usize{ 0, 400, 800, 400, 0 }) |offset| {
        const result = chaptersWindowInto(writer.buffered(), "https://wuxia.click", .wuxiaclick, "https://wuxia.click/novel/book", offset, &rows);
        try std.testing.expectEqual(@as(usize, 905), result.total);
        try std.testing.expectEqual(@min(@as(usize, 400), 905 - offset), result.count);
        try std.testing.expectEqual(offset < 800, result.has_more);
        var expected: [64]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Chapter {d}", .{offset + 1}), rows[0].title[0..rows[0].title_len]);
    }
}

test "exact resume identity found outside a bounded chapter window" {
    const body = "[{\"title\":\"New\",\"novSlugChapSlug\":\"book-new\"},{\"title\":\"Saved\",\"novSlugChapSlug\":\"book-saved\"}]";
    var rows: [1]Chapter = undefined;
    const result = chaptersWindowTargetInto(body, "https://wuxia.click", .wuxiaclick, "https://wuxia.click/novel/book", 0, "https://wuxia.click/api/getchapter/book-saved/", &rows);
    try std.testing.expectEqual(@as(?usize, 1), result.matched_ordinal);
    try std.testing.expectEqual(@as(usize, 1), result.count);
}

test "modern Wuxia search and reader pages retain exact identities and prose" {
    const search = "<script id=\"__NEXT_DATA__\" type=\"application/json\">{\"props\":{\"pageProps\":{\"result\":{\"items\":[{\"slug\":\"fixture\",\"title\":\"Fixture work\",\"coverKey\":\"covers/v1/abc123\",\"authorName\":\"Writer\"}]}}}}</script>";
    var items: [2]Item = undefined;
    const listing = parseInto(search, "https://wuxia.click", .wuxiaclick, &items);
    try std.testing.expect(listing.valid_listing);
    try std.testing.expectEqual(@as(usize, 1), listing.count);
    try std.testing.expectEqualStrings("Fixture work", items[0].title[0..items[0].title_len]);
    try std.testing.expectEqualStrings("https://wuxia.click/novel/fixture", items[0].url[0..items[0].url_len]);
    try std.testing.expectEqualStrings("https://cdn.wuxiaworld.eu/covers/v1/abc123-240.webp", items[0].cover[0..items[0].cover_len]);
    var rows: [2]Chapter = undefined;
    const directory = "<script id=\"__NEXT_DATA__\">{\"props\":{\"pageProps\":{\"novel\":{\"slug\":\"fixture\",\"chapterCount\":205},\"toc\":{\"range\":{\"page\":2},\"items\":[{\"number\":101,\"title\":\"Chapter 101\"},{\"number\":102,\"title\":\"Chapter 102\"}]}}}}</script>";
    const window = chaptersPageTargetInto(directory, "https://wuxia.click", .wuxiaclick, "https://wuxia.click/novel/fixture", 100, "https://wuxia.click/chapter/fixture-102", 100, &rows);
    try std.testing.expectEqual(@as(usize, 2), window.count);
    try std.testing.expectEqual(@as(usize, 205), window.total);
    try std.testing.expectEqual(@as(?usize, 101), window.matched_ordinal);
    try std.testing.expect(window.has_more);
    const gap = chaptersPageTargetInto(directory, "https://wuxia.click", .wuxiaclick, "https://wuxia.click/novel/fixture", 99, "https://wuxia.click/chapter/fixture-102", 99, &rows);
    try std.testing.expectEqual(@as(usize, 2), gap.count);
    try std.testing.expectEqual(@as(?usize, 100), gap.matched_ordinal);
    try std.testing.expectEqual(@as(usize, 2), gap.page_count);
    try std.testing.expectEqualStrings("https://wuxia.click/chapter/fixture-101", rows[0].url[0..rows[0].url_len]);
    const prose = "<script id=\"__NEXT_DATA__\">{\"props\":{\"pageProps\":{\"data\":{\"chapter\":{\"paragraphs\":[\"First line.\",\"Second \\\"line\\\".\"]}}}}}</script>";
    var output: [100]u8 = undefined;
    const n = chapterText(prose, .wuxiaclick, &output);
    try std.testing.expectEqualStrings("First line.\n\nSecond \"line\".", output[0..n]);
    try std.testing.expect(!parseInto("<h1>Page not found</h1>", "https://wuxia.click", .wuxiaclick, &items).valid_listing);
    var address: [1600]u8 = undefined;
    try std.testing.expectEqualStrings("https://legacy.test/api/search/?search=rain&offset=0&limit=12", searchUrl(&address, "https://legacy.test", .wuxiaclick, "rain", 1).?);
}
