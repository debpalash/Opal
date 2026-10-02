//! Primary-provider public book discovery. No guessed download links:
//! Gutenberg resolves its advertised UTF-8 download; OpenLibrary supplies IA IDs.
const std = @import("std");
const cj = @import("comics_pure.zig");
const html = @import("content_html_pure.zig");

pub const Item = struct {
    title: []const u8,
    author: []const u8 = "",
    id: []const u8,
    cover_id: u64 = 0,
    cover: []const u8 = "",
    year: u16 = 0,
};

pub fn openLibrarySearch(out: []u8, query: []const u8, page: u32) ?[]const u8 {
    if (query.len == 0 or page == 0) return null;
    var encoded: [1536]u8 = undefined;
    const n = cj.percentEncodeStrict(query, &encoded);
    return std.fmt.bufPrint(out, "https://openlibrary.org/search.json?q={s}%20AND%20ebook_access%3Apublic&fields=key,title,author_name,first_publish_year,cover_i,ia,ebook_access&limit=20&page={d}", .{ encoded[0..n], page }) catch null;
}

pub fn firstString(value: ?std.json.Value) []const u8 {
    const v = value orelse return "";
    if (v == .string) return v.string;
    if (v == .array) for (v.array.items) |entry| {
        if (entry == .string and entry.string.len > 0) return entry.string;
    };
    return "";
}

pub fn openLibraryItem(value: std.json.Value) ?Item {
    if (value != .object) return null;
    const access = firstString(value.object.get("ebook_access"));
    if (!std.mem.eql(u8, access, "public")) return null;
    const id = firstString(value.object.get("ia"));
    const title = firstString(value.object.get("title"));
    if (!archiveId(id) or title.len == 0) return null;
    var item: Item = .{ .id = id, .title = title, .author = firstString(value.object.get("author_name")) };
    if (value.object.get("cover_i")) |cover| if (cover == .integer and cover.integer > 0) {
        item.cover_id = @intCast(cover.integer);
    };
    if (value.object.get("first_publish_year")) |year| if (year == .integer and year.integer > 0 and year.integer <= 9999) {
        item.year = @intCast(year.integer);
    };
    return item;
}

pub fn archiveId(id: []const u8) bool {
    if (id.len == 0 or id.len > 512) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return true;
}

pub fn openLibraryCover(out: []u8, cover: u64) ?[]const u8 {
    if (cover == 0) return null;
    return std.fmt.bufPrint(out, "https://covers.openlibrary.org/b/id/{d}-M.jpg?default=false", .{cover}) catch null;
}

pub fn gutenbergSearch(out: []u8, query: []const u8, start: u32) ?[]const u8 {
    if (query.len == 0 or start == 0) return null;
    var encoded: [1536]u8 = undefined;
    const n = cj.percentEncodeStrict(query, &encoded);
    return std.fmt.bufPrint(out, "https://www.gutenberg.org/ebooks/search/?query={s}&start_index={d}", .{ encoded[0..n], start }) catch null;
}

pub fn gutenbergId(route: []const u8) ?[]const u8 {
    const prefix = "/ebooks/";
    if (!std.mem.startsWith(u8, route, prefix)) return null;
    const id = route[prefix.len..];
    if (id.len == 0 or id.len > 10) return null;
    for (id) |ch| if (!std.ascii.isDigit(ch)) return null;
    return id;
}

fn span(block: []const u8, class: []const u8) []const u8 {
    var marker: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&marker, "<span class=\"{s}\">", .{class}) catch return "";
    const at = std.mem.indexOf(u8, block, open) orelse return "";
    const start = at + open.len;
    const end = std.mem.indexOfPos(u8, block, start, "</span>") orelse return "";
    return block[start..end];
}

pub const GutenbergIter = struct {
    body: []const u8,
    pos: usize = 0,
    pub fn next(self: *GutenbergIter) ?Item {
        while (std.mem.indexOfPos(u8, self.body, self.pos, "<li class=\"booklink\">")) |start| {
            const end = std.mem.indexOfPos(u8, self.body, start, "</li>") orelse return null;
            self.pos = end + 5;
            const block = self.body[start..end];
            const a = std.mem.indexOf(u8, block, "<a ") orelse continue;
            const a_end = std.mem.indexOfScalarPos(u8, block, a, '>') orelse continue;
            const route = html.attr(block[a..a_end], "href") orelse continue;
            const id = gutenbergId(route) orelse continue;
            const title = span(block, "title");
            if (title.len == 0) continue;
            var cover: []const u8 = "";
            if (std.mem.indexOf(u8, block, "<img ")) |im| {
                if (std.mem.indexOfScalarPos(u8, block, im, '>')) |im_end| cover = html.attr(block[im..im_end], "src") orelse "";
            }
            return .{ .id = id, .title = title, .author = span(block, "subtitle"), .cover = cover };
        }
        return null;
    }
};

/// The actual next-results link carries query= as well as start_index. Header
/// rel=next can omit the query; read its cursor and rebuild our original query.
pub fn gutenbergNext(body: []const u8) ?u32 {
    const marker = "title=\"Next Page\"";
    const at = std.mem.indexOf(u8, body, marker) orelse return null;
    const end = std.mem.indexOfScalarPos(u8, body, at, '>') orelse return null;
    const route = html.attr(body[at..end], "href") orelse return null;
    const cursor = std.mem.indexOf(u8, route, "start_index=") orelse return null;
    const tail = route[cursor + "start_index=".len ..];
    var n: usize = 0;
    while (n < tail.len and std.ascii.isDigit(tail[n])) : (n += 1) {}
    if (n == 0) return null;
    const value = std.fmt.parseInt(u32, tail[0..n], 10) catch return null;
    return if (value > 0) value else null;
}

pub fn gutenbergDetail(out: []u8, id: []const u8) ?[]const u8 {
    var route: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&route, "/ebooks/{s}", .{id}) catch return null;
    if (gutenbergId(path) == null) return null;
    return std.fmt.bufPrint(out, "https://www.gutenberg.org{s}", .{path}) catch null;
}

pub fn gutenbergTextUrl(out: []u8, body: []const u8) ?[]const u8 {
    var p: usize = 0;
    while (std.mem.indexOfPos(u8, body, p, "<a ")) |at| {
        const end = std.mem.indexOfScalarPos(u8, body, at, '>') orelse return null;
        p = end + 1;
        const tag = body[at..end];
        const mime = html.attr(tag, "type") orelse continue;
        if (!std.mem.startsWith(u8, mime, "text/plain") or std.mem.indexOf(u8, mime, "utf-8") == null) continue;
        const route = html.attr(tag, "href") orelse continue;
        return html.sourceUrl(out, "https://www.gutenberg.org", route);
    }
    return null;
}

test "OpenLibrary public book metadata excludes restricted and unavailable books" {
    const json = "{\"title\":\"Frankenstein\",\"author_name\":[\"Mary Shelley\"],\"first_publish_year\":1818,\"cover_i\":123,\"ia\":[\"frankenstein_scan\"],\"ebook_access\":\"public\"}";
    const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer p.deinit();
    const item = openLibraryItem(p.value).?;
    try std.testing.expectEqualStrings("Mary Shelley", item.author);
    try std.testing.expectEqual(@as(u16, 1818), item.year);
    const restricted = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"title\":\"Book\",\"ia\":[\"scan\"],\"ebook_access\":\"borrowable\"}", .{});
    defer restricted.deinit();
    try std.testing.expect(openLibraryItem(restricted.value) == null);
    try std.testing.expect(!archiveId("../unsafe"));
}

test "Gutenberg parser keeps author cover and authoritative cursor and rejects invented text URLs" {
    const body = "<link rel=\"next\" title=\"Next Page\" href=\"/ebooks/search/?start_index=26\"><li class=\"booklink\"><a href=\"/ebooks/84\"><img src=\"/cover.jpg\"><span class=\"title\">Frankenstein</span><span class=\"subtitle\">Mary Shelley</span></a></li>";
    var it = GutenbergIter{ .body = body };
    const item = it.next().?;
    try std.testing.expectEqualStrings("84", item.id);
    try std.testing.expectEqualStrings("Mary Shelley", item.author);
    try std.testing.expectEqualStrings("/cover.jpg", item.cover);
    try std.testing.expectEqual(@as(?u32, 26), gutenbergNext(body));
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://www.gutenberg.org/ebooks/84.txt.utf-8", gutenbergTextUrl(&out, "<a href=\"/ebooks/84.txt.utf-8\" type=\"text/plain; charset=utf-8\">Plain Text</a>").?);
    try std.testing.expect(gutenbergTextUrl(&out, "<a href=\"https://bad.test/a.txt\" type=\"text/plain; charset=utf-8\">Plain Text</a>") == null);
    try std.testing.expect(gutenbergId("/ebooks/84?bad") == null);
}

/// Refuse dark/restricted items and private derivatives before claiming a
/// catalog work has a readable Archive text. Metadata availability alone is
/// insufficient: borrowed editions can advertise OCR files without public URLs.
pub fn publicArchiveText(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    if (truth(root.object.get("is_dark"))) return null;
    if (root.object.get("metadata")) |metadata| {
        if (metadata == .object and truth(metadata.object.get("access-restricted-item"))) return null;
    }
    const files = root.object.get("files") orelse return null;
    if (files != .array) return null;
    var best: ?[]const u8 = null;
    var best_tier: u8 = 255;
    var best_size: u64 = 0;
    for (files.array.items) |file| {
        if (file != .object or truth(file.object.get("private"))) continue;
        const name = firstString(file.object.get("name"));
        if (!std.mem.endsWith(u8, name, ".txt") or std.mem.endsWith(u8, name, "_meta.txt") or std.mem.indexOf(u8, name, "searchtext") != null) continue;
        const tier: u8 = if (std.mem.endsWith(u8, name, "_djvu.txt")) 0 else 1;
        const size_value = file.object.get("size");
        const size: u64 = if (size_value != null and size_value.? == .integer and size_value.?.integer > 0)
            @intCast(size_value.?.integer)
        else
            std.fmt.parseInt(u64, firstString(size_value), 10) catch 0;
        if (tier < best_tier or (tier == best_tier and size > best_size)) {
            best = name;
            best_tier = tier;
            best_size = size;
        }
    }
    return best;
}

fn truth(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return switch (v) {
        .bool => v.bool,
        .string => std.ascii.eqlIgnoreCase(v.string, "true"),
        else => false,
    };
}

pub fn plainTextPrefix(body: []const u8, capacity: usize) []const u8 {
    if (!std.unicode.utf8ValidateSlice(body)) return "";
    var n = @min(body.len, capacity);
    while (n > 0 and n < body.len and body[n] & 0xC0 == 0x80) : (n -= 1) {}
    return body[0..n];
}

test "public Archive full text excludes private OCR and restricted editions" {
    const json = "{\"files\":[{\"name\":\"private_djvu.txt\",\"private\":\"true\",\"size\":\"9000\"},{\"name\":\"book.txt\",\"size\":\"1000\"},{\"name\":\"public_djvu.txt\",\"size\":\"2000\"}]}";
    const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("public_djvu.txt", publicArchiveText(p.value).?);
    const r = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"metadata\":{\"access-restricted-item\":\"true\"},\"files\":[{\"name\":\"book.txt\"}]}", .{});
    defer r.deinit();
    try std.testing.expect(publicArchiveText(r.value) == null);
}

test "Gutenberg plain text preserves comparison signs and UTF8 boundaries" {
    try std.testing.expectEqualStrings("1 < 2\nA > B", plainTextPrefix("1 < 2\nA > B", 100));
    try std.testing.expectEqualStrings("A", plainTextPrefix("A東京", 2));
    try std.testing.expectEqualStrings("", plainTextPrefix("\xff", 1));
}
