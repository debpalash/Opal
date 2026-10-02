//! Owned, bounded independent reading listings. Reuses Browse's real DOM seam.
const std = @import("std");
const expanded = @import("expanded_reading_pure.zig");
const text = @import("novels_pure.zig");
pub const Source = enum { royalroad, novelfire };
pub const MAX_ITEMS = 12;
pub const Item = struct {
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    url: [1024]u8 = @splat(0),
    url_len: usize = 0,
    cover: [512]u8 = @splat(0),
    cover_len: usize = 0,
};
pub const Result = struct { count: usize = 0, valid_listing: bool = false };
fn coverUrl(out: []u8, base: []const u8, raw: []const u8) ?[]const u8 {
    const candidate = expanded.html.sourceUrl(out, base, raw) orelse raw;
    // Providers advertise real cover CDN URLs outside the listing origin.
    // Preserve those HTTPS URLs without admitting scripts or user credentials.
    if (candidate.len > out.len or std.mem.indexOfAny(u8, candidate, "\r\n") != null) return null;
    const uri = std.Uri.parse(candidate) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.host == null or uri.user != null or uri.password != null) return null;
    if (candidate.ptr != out.ptr) @memcpy(out[0..candidate.len], candidate);
    return out[0..candidate.len];
}
/// Only links inside the advertised work-list container are admitted. Chapter,
/// random-navigation, external-host, script and duplicate links are excluded.
pub fn parseInto(body: []const u8, base: []const u8, source: Source, out: []Item) Result {
    const listing = expanded.novelListingHtml(body, @tagName(source)) orelse return .{};
    var result: Result = .{ .valid_listing = true };
    var iter = expanded.html.AnchorIter{ .html = listing, .path = if (source == .royalroad) "/fiction/" else "/book/" };
    while (iter.next()) |anchor| {
        if (std.mem.indexOf(u8, anchor.url, "/chapter") != null or std.mem.endsWith(u8, anchor.url, "/random")) continue;
        var item: Item = .{};
        const url = expanded.html.sourceUrl(&item.url, base, anchor.url) orelse continue;
        item.url_len = url.len;
        item.title_len = text.htmlToText(anchor.title, &item.title);
        if (item.title_len == 0) continue;
        if (coverUrl(&item.cover, base, anchor.cover)) |cover| item.cover_len = cover.len;
        var duplicate = false;
        for (out[0..result.count]) |*previous| {
            if (!std.mem.eql(u8, previous.url[0..previous.url_len], url)) continue;
            if (previous.cover_len == 0 and item.cover_len > 0) {
                previous.cover = item.cover;
                previous.cover_len = item.cover_len;
            }
            duplicate = true;
            break;
        }
        if (duplicate) continue;
        if (result.count == @min(out.len, MAX_ITEMS)) break;
        out[result.count] = item;
        result.count += 1;
    }
    return result;
}
test "independent reading list owns valid works and merges cover without chapter or foreign links" {
    const html = "<a href='/book/outside'>Outside</a><div class=\"novel-list horizontal col2 chapters\"><a href='/book/real'>Real &amp; Good</a><a href='/book/real' title='Real'><img src='/cover.jpg'></a><a href='/book/real/chapter-1'>Chapter</a><a href='https://evil.test/book/bad'>Bad</a></div>";
    var out: [MAX_ITEMS]Item = undefined;
    const result = parseInto(html, "https://books.test", .novelfire, &out);
    try std.testing.expect(result.valid_listing);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqualStrings("Real & Good", out[0].title[0..out[0].title_len]);
    try std.testing.expectEqualStrings("https://books.test/book/real", out[0].url[0..out[0].url_len]);
    try std.testing.expectEqualStrings("https://books.test/cover.jpg", out[0].cover[0..out[0].cover_len]);
    try std.testing.expect(!parseInto("<html>Challenge</html>", "https://books.test", .novelfire, &out).valid_listing);
}
test "reading results stay bounded and valid empty containers are not parser failures" {
    var out: [1]Item = undefined;
    const result = parseInto("<div class=\"fiction-list\"><a href='/fiction/1'>One</a><a href='/fiction/2'>Two</a></div>", "https://rr.test", .royalroad, &out);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expect(parseInto("<div class=\"fiction-list\"></div>", "https://rr.test", .royalroad, &out).valid_listing);
}
test "advertised cover CDN preserved but credentials and unsafe schemes rejected" {
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://cdn.test/cover.jpg", coverUrl(&out, "https://books.test", "https://cdn.test/cover.jpg").?);
    try std.testing.expect(coverUrl(&out, "https://books.test", "https://user:pass@cdn.test/cover.jpg") == null);
    try std.testing.expect(coverUrl(&out, "https://user:pass@books.test", "/cover.jpg") == null);
    try std.testing.expect(coverUrl(&out, "https://books.test", "javascript:alert(1)") == null);
}
