//! Bounded RSS 2.0 item parsing shared by fetching and regression tests.
const std = @import("std");
const text = @import("novels_pure.zig");
pub const Item = struct {
    title: [200]u8 = undefined,
    title_len: usize = 0,
    magnet: [1024]u8 = undefined,
    magnet_len: usize = 0,
    url: [2048]u8 = undefined,
    url_len: usize = 0,
    date: [96]u8 = undefined,
    date_len: usize = 0,
    size_bytes: u64 = 0,
    seeds: u16 = 0,
    peers: u16 = 0,
};
fn tag(block: []const u8, name: []const u8, out: []u8) usize {
    var opening: [64]u8 = undefined;
    var closing: [64]u8 = undefined;
    const start_tag = std.fmt.bufPrint(&opening, "<{s}>", .{name}) catch return 0;
    const end_tag = std.fmt.bufPrint(&closing, "</{s}>", .{name}) catch return 0;
    const start = (std.mem.indexOf(u8, block, start_tag) orelse return 0) + start_tag.len;
    const end = std.mem.indexOfPos(u8, block, start, end_tag) orelse return 0;
    var raw = std.mem.trim(u8, block[start..end], " \r\n\t");
    if (std.mem.startsWith(u8, raw, "<![CDATA[") and std.mem.endsWith(u8, raw, "]]>")) raw = raw[9 .. raw.len - 3];
    return text.htmlToText(raw, out);
}
pub fn parse(body: []const u8, out: []Item) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (count < out.len) {
        const start = std.mem.indexOfPos(u8, body, pos, "<item>") orelse break;
        const end = std.mem.indexOfPos(u8, body, start, "</item>") orelse break;
        pos = end + 7;
        const block = body[start..end];
        const item = &out[count];
        item.* = .{};
        item.title_len = tag(block, "title", &item.title);
        if (item.title_len == 0) continue;
        item.url_len = tag(block, "link", &item.url);
        item.date_len = tag(block, "pubDate", &item.date);
        item.magnet_len = tag(block, "torrent:magnetURI", &item.magnet);
        if (item.magnet_len == 0 and std.mem.startsWith(u8, item.url[0..item.url_len], "magnet:?")) {
            item.magnet_len = @min(item.url_len, item.magnet.len);
            @memcpy(item.magnet[0..item.magnet_len], item.url[0..item.magnet_len]);
        }
        if (!std.mem.startsWith(u8, item.magnet[0..item.magnet_len], "magnet:?")) item.magnet_len = 0;
        const url = item.url[0..item.url_len];
        if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) or std.mem.indexOfAny(u8, url, "\r\n\t ") != null) item.url_len = 0;
        var number: [32]u8 = undefined;
        var len = tag(block, "torrent:contentLength", &number);
        item.size_bytes = std.fmt.parseInt(u64, number[0..len], 10) catch 0;
        len = tag(block, "torrent:seeds", &number);
        item.seeds = std.fmt.parseInt(u16, number[0..len], 10) catch 0;
        len = tag(block, "torrent:peers", &number);
        item.peers = std.fmt.parseInt(u16, number[0..len], 10) catch 0;
        count += 1;
    }
    return count;
}
test "news entries preserve usable links, dates and decoded titles" {
    var items: [1]Item = undefined;
    try std.testing.expectEqual(@as(usize, 1), parse("<rss><item><title><![CDATA[Books &amp; stories]]></title><link>https://example.org/read?a=1&amp;b=2</link><pubDate>Thu, 29 Oct 2026</pubDate></item></rss>", &items));
    try std.testing.expectEqualStrings("Books & stories", items[0].title[0..items[0].title_len]);
    try std.testing.expectEqualStrings("https://example.org/read?a=1&b=2", items[0].url[0..items[0].url_len]);
    try std.testing.expect(items[0].date_len > 0 and items[0].magnet_len == 0);
}
test "torrent feeds retain playback metadata and reject executable article links" {
    var items: [2]Item = undefined;
    const body = "<item><title>Video</title><link>magnet:?xt=urn:btih:123&amp;dn=Video</link><torrent:seeds>42</torrent:seeds></item><item><title>Unsafe</title><link>javascript:alert(1)</link></item>";
    try std.testing.expectEqual(@as(usize, 2), parse(body, &items));
    try std.testing.expectEqual(@as(u16, 42), items[0].seeds);
    try std.testing.expect(items[0].magnet_len > 0 and items[0].url_len == 0);
    try std.testing.expectEqual(@as(usize, 0), items[1].url_len);
    try std.testing.expectEqual(@as(usize, 1), parse(body, items[0..1]));
}
