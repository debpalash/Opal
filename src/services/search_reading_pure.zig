//! Owned, bounded independent reading listings. Reuses Browse's real DOM seam.
const std = @import("std");
const expanded = @import("expanded_reading_pure.zig");
const text = @import("novels_pure.zig");
pub const Source = enum { royalroad, novelfire, readnovelfull, standardebooks, wuxiaclick };
pub const MAX_ITEMS = 12;
pub const Item = @import("reading_provider_pure.zig").Item;
pub const Result = struct { count: usize = 0, valid_listing: bool = false };

/// Budget for one keyless reading-catalog request from universal search
/// (Wikisource, Internet Archive texts, VNDB). VNDB was measured answering a
/// valid 200 after ~10 s on a slow route, which the previous 8 s cap reported
/// as a transport failure.
pub const CATALOG_TIMEOUT_SECS: u32 = 15;

/// Sources whose listing sits behind a TLS-fingerprint wall. Royal Road
/// answered plain curl with HTTP 403 and curl-impersonate with 200, so its
/// request asks for the browser transport; the rest keep plain curl.
pub fn wantsBrowserTransport(source: Source) bool {
    return source == .royalroad;
}

test "Royal Road asks for the browser transport; open catalogs do not" {
    try std.testing.expect(wantsBrowserTransport(.royalroad));
    try std.testing.expect(!wantsBrowserTransport(.standardebooks));
    try std.testing.expect(!wantsBrowserTransport(.novelfire));
}

/// How a keyless reading-catalog request that produced no usable body is
/// reported. A deadline is `timed_out` (slow route, worth retrying), a refusal
/// is `unavailable` (retrying will not help), anything else is transport.
pub fn catalogFailure(timed_out: bool, http_status: u16) @import("resolver_lifecycle_pure.zig").SourceStatus {
    if (timed_out) return .timed_out;
    if (http_status == 401 or http_status == 403 or http_status == 451) return .unavailable;
    return .transport_failed;
}
test "keyless reading catalog failures keep their real cause" {
    try std.testing.expectEqual(.timed_out, catalogFailure(true, 0));
    try std.testing.expectEqual(.timed_out, catalogFailure(true, 200)); // slow body after a 200 head
    try std.testing.expectEqual(.unavailable, catalogFailure(false, 403));
    try std.testing.expectEqual(.unavailable, catalogFailure(false, 401));
    try std.testing.expectEqual(.transport_failed, catalogFailure(false, 0)); // DNS / connect / TLS
    try std.testing.expectEqual(.transport_failed, catalogFailure(false, 503)); // provider maintenance
    try std.testing.expectEqual(.transport_failed, catalogFailure(false, 429));
    try std.testing.expect(CATALOG_TIMEOUT_SECS > 10 and CATALOG_TIMEOUT_SECS <= 20);
}
pub fn searchUrl(out: []u8, base: []const u8, source: Source, query: []const u8, page: u32) ?[]const u8 {
    return switch (source) {
        .royalroad, .novelfire, .readnovelfull => expanded.novelSearchUrl(out, base, @tagName(source), query, page),
        .standardebooks => @import("reading_provider_pure.zig").searchUrl(out, base, .standardebooks, query, page),
        .wuxiaclick => @import("reading_provider_pure.zig").searchUrl(out, base, .wuxiaclick, query, page),
    };
}
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
    if (source == .standardebooks or source == .wuxiaclick) {
        const result = @import("reading_provider_pure.zig").parseInto(body, base, if (source == .standardebooks) .standardebooks else .wuxiaclick, out[0..@min(out.len, MAX_ITEMS)]);
        return .{ .count = result.count, .valid_listing = result.valid_listing };
    }
    const listing = expanded.novelListingHtml(body, @tagName(source)) orelse return .{};
    var result: Result = .{ .valid_listing = true };
    var iter = expanded.html.AnchorIter{ .html = listing, .path = if (source == .readnovelfull) "/" else if (source == .royalroad) "/fiction/" else "/book/" };
    while (iter.next()) |anchor| {
        if (std.mem.indexOf(u8, anchor.url, "/chapter") != null or std.mem.endsWith(u8, anchor.url, "/random")) continue;
        var item: Item = .{};
        const url = expanded.html.sourceUrl(&item.url, base, anchor.url) orelse continue;
        if (source == .readnovelfull and !expanded.readNovelFullWork(url, base)) continue;
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
test "ReadNovelFull independent search preserves works and excludes chapter or category links" {
    const body = "<div id=\"list-page\"><a href='/story-v1.html' title='Story'>Story</a><a href='/story/chapter-1.html'>Chapter</a><a href='/novel-list/search.html'>Category</a><a href='https://evil.test/other.html'>Other</a></div>";
    var out: [2]Item = undefined;
    const result = parseInto(body, "https://rnf.test", .readnovelfull, &out);
    try std.testing.expect(result.valid_listing);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqualStrings("https://rnf.test/story-v1.html", out[0].url[0..out[0].url_len]);
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
