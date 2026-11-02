//! Western comic catalogs, issue identities and complete page manifests.
const std = @import("std");
const html = @import("content_html_pure.zig");
const text = @import("novels_pure.zig");
pub const Provider = enum {
    latestcomics,
    ysk,
    xoxo,
    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .latestcomics => "LatestComics",
            .ysk => "YSK Comics",
            .xoxo => "XOXO Comics",
        };
    }
};
pub fn Field(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,
        pub fn set(self: *@This(), value: []const u8) bool {
            if (value.len > capacity) return false;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
            return true;
        }
        pub fn get(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}
pub const Item = struct { title: Field(160) = .{}, route: Field(512) = .{}, cover: Field(512) = .{} };
pub const Issue = struct { title: Field(160) = .{}, url: Field(512) = .{}, number: f64 = 0 };
pub const Page = Field(512);
fn member(value: std.json.Value, key: []const u8) std.json.Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn string(value: std.json.Value) []const u8 {
    return if (value == .string) value.string else "";
}
fn numeric(value: std.json.Value) f64 {
    return switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        .string => std.fmt.parseFloat(f64, value.string) catch 0,
        else => 0,
    };
}
fn slug(value: []const u8) bool {
    if (value.len == 0 or value.len > 200 or std.mem.indexOf(u8, value, "..") != null) return false;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return true;
}
pub fn series(provider: Provider, base: []const u8, url: []const u8) bool {
    const b = std.mem.trimEnd(u8, base, "/");
    if (!std.mem.startsWith(u8, url, b)) return false;
    const path = url[b.len..];
    const prefix = if (provider == .latestcomics) "/en/comic/" else "/comic/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const name = std.mem.trimEnd(u8, path[prefix.len..], "/");
    return slug(name) and (provider != .latestcomics or std.mem.endsWith(u8, name, ".html"));
}
pub fn issueOwned(provider: Provider, base: []const u8, work: []const u8, url: []const u8) bool {
    if (!series(provider, base, work)) return false;
    const b = std.mem.trimEnd(u8, base, "/");
    if (!std.mem.startsWith(u8, url, b)) return false;
    const path = url[b.len..];
    if (provider == .ysk) return std.mem.startsWith(u8, path, "/chapter/") and slug(path[9..]);
    if (provider == .xoxo) {
        const stem = std.mem.trimEnd(u8, work, "/");
        if (!std.mem.startsWith(u8, url, stem) or url.len <= stem.len or url[stem.len] != '/') return false;
        const name = std.mem.trimEnd(u8, url[stem.len + 1 ..], "/");
        return slug(name) and (std.mem.startsWith(u8, name, "issue-") or std.mem.startsWith(u8, name, "tpb-"));
    }
    const name = work[b.len + "/en/comic/".len .. work.len - 5];
    if (!std.mem.startsWith(u8, path, "/en/") or !std.mem.startsWith(u8, path[4..], name)) return false;
    if (path.len <= 5 + name.len or path[4 + name.len] != '/') return false;
    const leaf = path[5 + name.len ..];
    return slug(leaf) and std.mem.endsWith(u8, leaf, ".html");
}
pub const Route = struct { provider: Provider, work: []const u8, issue: []const u8 = "" };
pub fn route(out: []u8, provider: Provider, base: []const u8, work: []const u8, issue: []const u8) ?[]const u8 {
    if (!series(provider, base, work) or (issue.len > 0 and !issueOwned(provider, base, work, issue))) return null;
    return std.fmt.bufPrint(out, "{s}:{s}{s}{s}", .{ @tagName(provider), work, if (issue.len > 0) "|" else "", issue }) catch null;
}
pub fn splitRoute(value: []const u8) ?Route {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    const provider = std.meta.stringToEnum(Provider, value[0..colon]) orelse return null;
    const rest = value[colon + 1 ..];
    const bar = std.mem.indexOfScalar(u8, rest, '|') orelse rest.len;
    const work = rest[0..bar];
    const uri = std.Uri.parse(work) catch return null;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.user != null or uri.password != null) return null;
    const scheme_end = (std.mem.indexOf(u8, work, "://") orelse return null) + 3;
    const path = std.mem.indexOfScalarPos(u8, work, scheme_end, '/') orelse return null;
    const base = work[0..path];
    const issue = if (bar < rest.len) rest[bar + 1 ..] else "";
    if (!series(provider, base, work) or (bar < rest.len and (issue.len == 0 or !issueOwned(provider, base, work, issue)))) return null;
    return .{ .provider = provider, .work = work, .issue = issue };
}
pub fn searchUrl(out: []u8, provider: Provider, base: []const u8, api: []const u8, query: []const u8, page: u32) ?[]const u8 {
    if (query.len > 256 or page == 0 or page > 1000) return null;
    var encoded: [1024]u8 = undefined;
    const q = if (provider == .ysk and query.len == 0) "the" else query;
    const result = @import("url_encode_pure.zig").encode(q, &encoded, .component);
    if (!result.complete) return null;
    const b = std.mem.trimEnd(u8, base, "/");
    return switch (provider) {
        .ysk => if (page != 1 or q.len < 3) null else std.fmt.bufPrint(out, "{s}/search-comics-home?name={s}", .{ std.mem.trimEnd(u8, api, "/"), result.bytes }) catch null,
        .latestcomics => if (page == 1) std.fmt.bufPrint(out, "{s}/en/?s={s}&lang=en", .{ b, result.bytes }) catch null else std.fmt.bufPrint(out, "{s}/en/page/{d}/?s={s}&lang=en", .{ b, page, result.bytes }) catch null,
        .xoxo => if (q.len == 0) std.fmt.bufPrint(out, "{s}/comic-list?page={d}", .{ b, page }) catch null else std.fmt.bufPrint(out, "{s}/search-comic?keyword={s}&page={d}", .{ b, result.bytes, page }) catch null,
    };
}
pub fn yskIssueUrl(out: []u8, api: []const u8, work: []const u8, page: u32) ?[]const u8 {
    const at = (std.mem.lastIndexOfScalar(u8, work, '/') orelse return null) + 1;
    if (!slug(work[at..]) or page == 0 or page > 1000) return null;
    return std.fmt.bufPrint(out, "{s}/comics/{s}/chapters?page={d}", .{ std.mem.trimEnd(u8, api, "/"), work[at..], page }) catch null;
}
pub fn imagesUrl(out: []u8, provider: Provider, api: []const u8, issue: []const u8) ?[]const u8 {
    if (provider == .xoxo) return std.fmt.bufPrint(out, "{s}/all", .{std.mem.trimEnd(u8, issue, "/")}) catch null;
    if (provider == .latestcomics) return std.fmt.bufPrint(out, "{s}", .{issue}) catch null;
    const at = (std.mem.lastIndexOfScalar(u8, issue, '/') orelse return null) + 1;
    if (!slug(issue[at..])) return null;
    return std.fmt.bufPrint(out, "{s}/chapters/{s}/images", .{ std.mem.trimEnd(u8, api, "/"), issue[at..] }) catch null;
}
fn image(value: []const u8) bool {
    if (value.len == 0 or value.len > 512 or std.mem.indexOfAny(u8, value, "\r\n\t ") != null) return false;
    const uri = std.Uri.parse(value) catch return false;
    return std.mem.eql(u8, uri.scheme, "https") and uri.host != null and uri.user == null and uri.password == null;
}
fn addItem(out: []Item, count: *usize, provider: Provider, base: []const u8, url: []const u8, title: []const u8, cover: []const u8) void {
    if (count.* == out.len) return;
    var item: Item = .{};
    const r = route(&item.route.bytes, provider, base, url, "") orelse return;
    item.route.len = r.len;
    item.title.len = text.htmlToText(title, &item.title.bytes);
    if (provider == .xoxo and std.mem.endsWith(u8, item.title.get(), " Comic")) item.title.len -= 6;
    if (item.title.len == 0) return;
    if (image(cover)) _ = item.cover.set(cover);
    for (out[0..count.*]) |*old| if (std.mem.eql(u8, old.route.get(), r)) {
        if (old.cover.len == 0 and item.cover.len > 0) old.cover = item.cover;
        return;
    };
    out[count.*] = item;
    count.* += 1;
}
pub fn yskItems(root: std.json.Value, base: []const u8, out: []Item) usize {
    if (member(root, "status") != .bool or !member(root, "status").bool) return 0;
    const data = member(root, "data");
    if (data != .array) return 0;
    var count: usize = 0;
    for (data.array.items) |row| {
        const name = string(member(row, "slug"));
        if (!slug(name)) continue;
        var address: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&address, "{s}/comic/{s}", .{ std.mem.trimEnd(u8, base, "/"), name }) catch continue;
        addItem(out, &count, .ysk, base, url, string(member(row, "full_name")), string(member(row, "image")));
    }
    return count;
}
pub fn htmlItems(body: []const u8, provider: Provider, base: []const u8, out: []Item) usize {
    var listing = body;
    if (provider == .latestcomics) {
        const start = std.mem.indexOf(u8, body, "<main") orelse return 0;
        const end = std.mem.indexOfPos(u8, body, start, "</main>") orelse return 0;
        listing = body[start..end];
    }
    var it: html.AnchorIter = .{ .html = listing, .path = "/comic/" };
    var count: usize = 0;
    while (it.next()) |anchor| {
        var address: [512]u8 = undefined;
        const url = html.sourceUrl(&address, base, anchor.url) orelse continue;
        if (!series(provider, base, url)) continue;
        // LatestComics covers may be CSS backgrounds inside the series anchor.
        const close = it.pos - 4;
        const start = std.mem.lastIndexOf(u8, listing[0..close], "<a ") orelse continue;
        const chunk = listing[start..it.pos];
        var cover = anchor.cover;
        if (std.mem.indexOf(u8, chunk, "<img")) |im| {
            const gt = std.mem.indexOfScalarPos(u8, chunk, im, '>') orelse continue;
            const tag = chunk[im .. gt + 1];
            cover = html.attr(tag, "data-src") orelse html.attr(tag, "data-original") orelse html.attr(tag, "data-lazy-src") orelse cover;
        }
        if (cover.len == 0 or !image(cover)) {
            if (std.mem.indexOf(u8, chunk, "url(")) |at| {
                var value = chunk[at + 4 ..];
                if (value.len > 0 and (value[0] == '\'' or value[0] == '"')) value = value[1..];
                const end = std.mem.indexOfAny(u8, value, "'\")") orelse 0;
                cover = value[0..end];
            }
        }
        var title = anchor.title;
        if (provider == .latestcomics) if (std.mem.indexOf(u8, chunk, "<h3")) |heading| {
            const gt = std.mem.indexOfScalarPos(u8, chunk, heading, '>') orelse continue;
            const end = std.mem.indexOfPos(u8, chunk, gt, "</h3>") orelse continue;
            title = chunk[gt + 1 .. end];
        };
        addItem(out, &count, provider, base, url, title, cover);
    }
    return count;
}
fn addIssue(out: []Issue, count: *usize, url: []const u8, title: []const u8, number: f64) bool {
    for (out[0..count.*]) |*old| if (std.mem.eql(u8, old.url.get(), url)) return true;
    if (count.* == out.len) return false;
    var row: Issue = .{ .number = number };
    if (!row.url.set(url)) return false;
    row.title.len = text.htmlToText(title, &row.title.bytes);
    if (row.title.len == 0) return true;
    out[count.*] = row;
    count.* += 1;
    return true;
}
pub fn sortIssues(rows: []Issue) void {
    std.mem.sort(Issue, rows, {}, struct {
        fn less(_: void, a: Issue, b: Issue) bool {
            return a.number < b.number;
        }
    }.less);
}
pub fn yskIssues(root: std.json.Value, base: []const u8, out: []Issue, count: *usize) ?u32 {
    if (member(root, "status") != .bool or !member(root, "status").bool) return null;
    const data = member(root, "data");
    const rows = member(data, "data_messages");
    if (rows != .array) return null;
    for (rows.array.items) |row| {
        const name = string(member(row, "slug"));
        if (!slug(name)) continue;
        var address: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&address, "{s}/chapter/{s}", .{ std.mem.trimEnd(u8, base, "/"), name }) catch continue;
        if (!addIssue(out, count, url, string(member(row, "name")), numeric(member(row, "rank")))) return null;
    }
    const pages = numeric(member(member(data, "meta"), "total_pages"));
    return if (pages >= 1 and pages <= 1000 and std.math.isFinite(pages)) @intFromFloat(pages) else 1;
}
pub fn htmlIssues(body: []const u8, provider: Provider, base: []const u8, work: []const u8, out: []Issue, count: *usize) bool {
    var it: html.AnchorIter = .{ .html = body, .path = if (provider == .latestcomics) "/en/" else "/comic/" };
    while (it.next()) |anchor| {
        var address: [512]u8 = undefined;
        const url = html.sourceUrl(&address, base, anchor.url) orelse continue;
        if (!issueOwned(provider, base, work, url)) continue;
        var number: f64 = 100000;
        for ([_][]const u8{ "-issue-", "/issue-", "/tpb-", "-tpb-" }) |marker| if (std.mem.lastIndexOf(u8, url, marker)) |at| {
            const tail = url[at + marker.len ..];
            var end: usize = 0;
            while (end < tail.len and (std.ascii.isDigit(tail[end]) or (tail[end] == '.' and end + 1 < tail.len and std.ascii.isDigit(tail[end + 1])))) : (end += 1) {}
            number = (std.fmt.parseFloat(f64, tail[0..end]) catch 0) + @as(f64, if (std.mem.endsWith(u8, marker, "tpb-")) 100000 else 0);
            break;
        };
        if (!addIssue(out, count, url, anchor.title, number)) return false;
    }
    return true;
}
pub const LatestCursor = struct { nonce: []const u8, category: []const u8 };
pub fn latestCursor(body: []const u8) ?LatestCursor {
    const start = std.mem.indexOf(u8, body, "mangaverse_ajax") orelse return null;
    const nonce_start = (std.mem.indexOfPos(u8, body, start, "\"nonce\":\"") orelse return null) + "\"nonce\":\"".len;
    const nonce_end = std.mem.indexOfScalarPos(u8, body, nonce_start, '"') orelse return null;
    const category_start = (std.mem.indexOf(u8, body, "data-category=\"") orelse return null) + "data-category=\"".len;
    const category_end = std.mem.indexOfScalarPos(u8, body, category_start, '"') orelse return null;
    const nonce = body[nonce_start..nonce_end];
    const category = body[category_start..category_end];
    if (!slug(nonce) or category.len == 0 or category.len > 10) return null;
    for (category) |ch| if (!std.ascii.isDigit(ch)) return null;
    return .{ .nonce = nonce, .category = category };
}
pub fn latestForm(out: []u8, cursor: LatestCursor, page: u32) ?[]const u8 {
    return std.fmt.bufPrint(out, "action=mangaverse_load_more&nonce={s}&page={d}&type=series&category_id={s}&order=desc&lang=en", .{ cursor.nonce, page, cursor.category }) catch null;
}
pub fn latestBatch(root: std.json.Value) ?struct { body: []const u8, more: bool } {
    const success = member(root, "success");
    if (success != .bool or !success.bool) return null;
    const data = member(root, "data");
    const content = member(data, "html");
    const more = member(data, "has_more");
    if (content != .string or more != .bool) return null;
    return .{ .body = content.string, .more = more.bool };
}
pub fn yskPages(root: std.json.Value, out: []Page) ?usize {
    const rows = member(root, "data");
    if (rows != .array or rows.array.items.len > out.len) return null;
    var count: usize = 0;
    for (rows.array.items) |row| {
        const url = string(row);
        if (!image(url) or !out[count].set(url)) return null;
        count += 1;
    }
    return count;
}
pub fn htmlPages(document: []const u8, provider: Provider, out: []Page) ?usize {
    const region = if (provider == .xoxo) @import("novel_sources_pure.zig").containerInner(document, "class=\"reading-detail") else null;
    const body = region orelse document;
    var pos: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "<img")) |at| {
        const end = std.mem.indexOfScalarPos(u8, body, at, '>') orelse return null;
        pos = end + 1;
        const tag = body[at..pos];
        const classes = html.attr(tag, "class") orelse "";
        const src = html.attr(tag, "data-src") orelse html.attr(tag, "data-original") orelse html.attr(tag, "data-lazy-src") orelse html.attr(tag, "src") orelse continue;
        if (provider == .xoxo) {
            var tokens = std.mem.tokenizeAny(u8, classes, " \t\r\n");
            var page = false;
            while (tokens.next()) |token| if (std.mem.eql(u8, token, "single-page")) {
                page = true;
            };
            if (!page and region == null) continue;
        } else if (!std.mem.startsWith(u8, src, "https://cdn.latestcomics.com/")) continue;
        if (!image(src)) return null;
        var duplicate = false;
        for (out[0..count]) |*old| if (std.mem.eql(u8, old.get(), src)) {
            duplicate = true;
        };
        if (duplicate) continue;
        if (count == out.len or !out[count].set(src)) return null;
        count += 1;
    }
    return count;
}

test "western source identities retain case and keep chapters inside the selected series" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("https://api.test/search-comics-home?name=bat%26man", searchUrl(&buf, .ysk, "https://ysk.test", "https://api.test", "bat&man", 1).?);
    try std.testing.expect(searchUrl(&buf, .ysk, "https://ysk.test", "https://api.test", "bat", 2) == null);
    try std.testing.expectEqualStrings("https://api.test/comics/Invincible-2003/chapters?page=2", yskIssueUrl(&buf, "https://api.test", "https://ysk.test/comic/Invincible-2003", 2).?);
    try std.testing.expect(splitRoute("xoxo:https://xoxo.test/comic/batman|https://xoxo.test/comic/batman/issue-1") != null);
    try std.testing.expect(splitRoute("xoxo:https://xoxo.test/comic/batman|https://evil.test/comic/batman/issue-1") == null);
    try std.testing.expect(splitRoute("xoxo:https://xoxo.test/comic/batman|https://xoxo.test/comic/other/issue-1") == null);
    try std.testing.expect(splitRoute("latestcomics:https://latest.test/en/comic/batman.html|https://latest.test/en/batman/batman-issue-1.html") != null);
    try std.testing.expect(splitRoute("xoxo:https://user:pass@xoxo.test/comic/batman") == null);
    try std.testing.expect(splitRoute("ysk:https://ysk.test.bad/comic/../secret") == null);
}
test "western reader fetches XOXO complete manifest and rejects truncated issues" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://xoxo.test/comic/story/issue-1/all", imagesUrl(&buf, .xoxo, "", "https://xoxo.test/comic/story/issue-1/").?);
    var pages: [2]Page = @splat(.{});
    const body = "<img src='https://cdn.test/advert.jpg'><img class='single-page lazy' data-src='https://cdn.test/1.jpg'><img class='single-page' src='https://cdn.test/2.jpg'>";
    try std.testing.expectEqual(@as(usize, 2), htmlPages(body, .xoxo, &pages).?);
    try std.testing.expectEqualStrings("https://cdn.test/1.jpg", pages[0].get());
    try std.testing.expect(htmlPages(body, .xoxo, pages[0..1]) == null);
    try std.testing.expectEqual(@as(usize, 0), htmlPages("<img src='https://cdn.latestcomics.com.evil/1.jpg'>", .latestcomics, &pages).?);
}
test "western issue lists sort numeric and fractional issue numbers and reject unrelated series" {
    var rows: [4]Issue = @splat(.{});
    var count: usize = 0;
    try std.testing.expect(htmlIssues("<a href='/comic/story/issue-10'>10</a><a href='/comic/other/issue-1'>bad</a><a href='/comic/story/issue-2.5'>2.5</a><a href='/comic/story/issue-2'>2</a><a href='/comic/story/issue-2'>duplicate</a>", .xoxo, "https://x.test", "https://x.test/comic/story", &rows, &count));
    sortIssues(rows[0..count]);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("2", rows[0].title.get());
    try std.testing.expectEqualStrings("2.5", rows[1].title.get());
}
test "LatestComics catalog excludes navigation and uses CSS covers" {
    var rows: [3]Item = @splat(.{});
    const count = htmlItems("<nav><a href='/en/comic/no.html'>Navigation</a></nav><main><a href='/en/comic/story.html'><div><b>170</b></div><div style=\"background-image:url('https://cdn.test/cover.jpg')\"></div><h3>Story &amp; Good</h3></a></main>", .latestcomics, "https://l.test", &rows);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("Story & Good", rows[0].title.get());
    try std.testing.expectEqualStrings("https://cdn.test/cover.jpg", rows[0].cover.get());
    const cursor = latestCursor("<div data-category=\"4\"></div><script>var mangaverse_ajax={\"nonce\":\"abc123\"};</script>").?;
    var buf: [512]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, latestForm(&buf, cursor, 2).?, "page=2") != null);
}
test "YSK JSON preserves full issue pagination and page order" {
    const root = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"status\":true,\"data\":{\"data_messages\":[{\"slug\":\"story-2\",\"name\":\"Issue 2\",\"rank\":\"2\"}],\"meta\":{\"total_pages\":2}}}", .{});
    defer root.deinit();
    var rows: [2]Issue = @splat(.{});
    var count: usize = 0;
    try std.testing.expectEqual(@as(u32, 2), yskIssues(root.value, "https://y.test", &rows, &count).?);
    try std.testing.expectEqualStrings("https://y.test/chapter/story-2", rows[0].url.get());
    const manifest = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"data\":[\"https://cdn.test/2.webp\",\"https://cdn.test/1.webp\"]}", .{});
    defer manifest.deinit();
    var pages: [2]Page = @splat(.{});
    try std.testing.expectEqual(@as(usize, 2), yskPages(manifest.value, &pages).?);
    try std.testing.expectEqualStrings("https://cdn.test/2.webp", pages[0].get());
}

test "XOXO lazy full reader container excludes covers and includes every page" {
    var pages: [3]Page = @splat(.{});
    const body = "<img src='https://cdn.test/cover.jpg'><div class=\"reading-detail box_doc\"><div class='page-chapter'><img class='lazy' src='data:placeholder' data-original='https://cdn.test/1.jpg'></div><div class='page-chapter'><img data-original='https://cdn.test/2.jpg'></div></div><img src='https://cdn.test/ad.jpg'>";
    try std.testing.expectEqual(@as(usize, 2), htmlPages(body, .xoxo, &pages).?);
    try std.testing.expectEqualStrings("https://cdn.test/2.jpg", pages[1].get());
    var rows: [1]Item = @splat(.{});
    try std.testing.expectEqual(@as(usize, 1), htmlItems("<a href='/comic/story' title='Story Comic'><img src='data:placeholder' data-original='https://cdn.test/cover.jpg'></a>", .xoxo, "https://x.test", &rows));
    try std.testing.expectEqualStrings("https://cdn.test/cover.jpg", rows[0].cover.get());
}

pub fn xoxoIssueListUrl(out: []u8, work: []const u8, page: u32) ?[]const u8 {
    if (page == 0 or page > 1000) return null;
    return std.fmt.bufPrint(out, "{s}?page={d}", .{ work, page }) catch null;
}
pub fn xoxoHasNext(body: []const u8, work: []const u8, page: u32) bool {
    var address: [512]u8 = undefined;
    const next = xoxoIssueListUrl(&address, work, page +| 1) orelse return false;
    const last_slash = (std.mem.lastIndexOfScalar(u8, next, '/') orelse return false) + 1;
    var it: html.AnchorIter = .{ .html = body, .path = "?page=" };
    while (it.next()) |anchor| {
        if (std.mem.eql(u8, anchor.url, next) or std.mem.eql(u8, anchor.url, next[last_slash..])) return true;
    }
    return false;
}
test "XOXO follows all issue-list pages through its owned series query" {
    const body = "<a href='invincible?page=2' rel='next'>Next</a><a href='https://evil.test/comic/invincible?page=3'>bad</a>";
    try std.testing.expect(xoxoHasNext(body, "https://x.test/comic/invincible", 1));
    try std.testing.expect(!xoxoHasNext(body, "https://x.test/comic/invincible", 2));
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://x.test/comic/invincible?page=2", xoxoIssueListUrl(&out, "https://x.test/comic/invincible", 2).?);
}

test "collected editions do not become the initial regular issue" {
    var issues: [3]Issue = @splat(.{});
    var count: usize = 0;
    try std.testing.expect(htmlIssues("<a href='/en/story/story-tpb-1.html'>Collected edition</a><a href='/en/story/story-issue-2.html'>Issue 2</a><a href='/en/story/story-issue-1.html'>Issue 1</a>", .latestcomics, "https://l.test", "https://l.test/en/comic/story.html", &issues, &count));
    sortIssues(issues[0..count]);
    try std.testing.expectEqualStrings("Issue 1", issues[0].title.get());
}
