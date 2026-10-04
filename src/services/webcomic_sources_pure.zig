//! Official public comic contracts; independent original parser policy.
const std = @import("std");
const html = @import("content_html_pure.zig");
const audio = @import("audio_sources_pure.zig");
pub const htmlSource = html.sourceUrl;
pub const Provider = enum { xkcd, smbc };
pub const Item = struct {
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    route: [512]u8 = @splat(0),
    route_len: usize = 0,
    image: [1024]u8 = @splat(0),
    image_len: usize = 0,
    summary: [768]u8 = @splat(0),
    summary_len: usize = 0,
    number: u32 = 0,
};
pub const Listing = struct { count: usize = 0, total: usize = 0, valid: bool = false };
pub fn matches(title: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > title.len) return false;
    for (0..title.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(title[i .. i + query.len], query)) return true;
    return false;
}
pub fn numberFromPath(path: []const u8) ?u32 {
    const digits = std.mem.trim(u8, path, "/");
    if (digits.len == 0 or digits.len > 8) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u32, digits, 10) catch return null;
    return if (n > 0 and n != 404) n else null;
}
pub fn parseArchive(body: []const u8, query: []const u8, out: []Item) Listing {
    var result: Listing = .{ .valid = std.mem.indexOf(u8, body, "middleContainer") != null };
    if (!result.valid) return result;
    const exact = numberFromPath(query);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "<a ")) |at| {
        const end = std.mem.indexOfScalarPos(u8, body, at, '>') orelse break;
        const close = std.mem.indexOfPos(u8, body, end, "</a>") orelse break;
        pos = close + 4;
        const href = html.attr(body[at .. end + 1], "href") orelse continue;
        const title = body[end + 1 .. close];
        const n = numberFromPath(href) orelse continue;
        if (if (exact) |wanted| n != wanted else !matches(title, query)) continue;
        result.total += 1;
        if (result.count == out.len) continue;
        var row: Item = .{ .number = n };
        audio.copy(&row.title, &row.title_len, title);
        const route = std.fmt.bufPrint(&row.route, "xkcd:{d}", .{n}) catch continue;
        row.route_len = route.len;
        out[result.count] = row;
        result.count += 1;
    }
    return result;
}
pub fn parseXkcd(root: std.json.Value, expected: ?u32, base: []const u8) ?Item {
    const n = audio.number(audio.field(root, "num"));
    if (n == 0 or n == 404 or n > std.math.maxInt(u32) or (expected != null and n != expected.?)) return null;
    const image = audio.text(root, "img");
    if (!audio.safeUrl(image) or !allowedImage(image, base, "https://imgs.xkcd.com/comics/") or image.len > 1024) return null;
    const title = audio.text(root, "safe_title");
    if (title.len == 0) return null;
    var item: Item = .{ .number = @intCast(n) };
    audio.copy(&item.title, &item.title_len, title);
    audio.copy(&item.image, &item.image_len, image);
    audio.copy(&item.summary, &item.summary_len, audio.text(root, "alt"));
    item.route_len = (std.fmt.bufPrint(&item.route, "xkcd:{d}", .{n}) catch return null).len;
    return item;
}
fn tag(block: []const u8, name: []const u8) ?[]const u8 {
    var open: [64]u8 = undefined;
    var close: [64]u8 = undefined;
    const o = std.fmt.bufPrint(&open, "<{s}>", .{name}) catch return null;
    const c = std.fmt.bufPrint(&close, "</{s}>", .{name}) catch return null;
    const start = (std.mem.indexOf(u8, block, o) orelse return null) + o.len;
    const end = std.mem.indexOfPos(u8, block, start, c) orelse return null;
    var text = std.mem.trim(u8, block[start..end], " \r\n\t");
    if (std.mem.startsWith(u8, text, "<![CDATA[") and std.mem.endsWith(u8, text, "]]>")) text = text[9 .. text.len - 3];
    return text;
}
pub fn parseSmbc(body: []const u8, base: []const u8, query: []const u8, out: []Item) Listing {
    var result: Listing = .{ .valid = std.mem.indexOf(u8, body, "<rss") != null and std.mem.indexOf(u8, body, "</rss>") != null };
    if (!result.valid) return result;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "<item>")) |start| {
        const end = std.mem.indexOfPos(u8, body, start, "</item>") orelse return .{};
        pos = end + 7;
        const block = body[start..end];
        const title = tag(block, "title") orelse continue;
        if (!matches(title, query)) continue;
        const link = tag(block, "link") orelse continue;
        var route_url: [512]u8 = undefined;
        const abs = html.sourceUrl(&route_url, base, link) orelse continue;
        if (std.mem.indexOf(u8, abs, "/comic/") == null) continue;
        const description = tag(block, "description") orelse continue;
        const at = std.mem.indexOf(u8, description, "<img") orelse continue;
        const stop = std.mem.indexOfScalarPos(u8, description, at, '>') orelse continue;
        const image = html.attr(description[at .. stop + 1], "src") orelse continue;
        if (!audio.safeUrl(image) or !allowedImage(image, base, "https://www.smbc-comics.com/comics/") or image.len > 1024) continue;
        result.total += 1;
        if (result.count == out.len) continue;
        var item: Item = .{};
        audio.copy(&item.title, &item.title_len, title);
        audio.copy(&item.image, &item.image_len, image);
        item.route_len = (std.fmt.bufPrint(&item.route, "smbc:{s}", .{abs}) catch continue).len;
        audio.copy(&item.summary, &item.summary_len, "Zach Weinersmith · publisher's recent RSS comics; main panel. Bonus panel remains on publisher site.");
        out[result.count] = item;
        result.count += 1;
    }
    return result;
}

test "xkcd archive searches exact titles or numeric identity without fake title merges" {
    const body = "<div id='middleContainer'><a href='/12/' title='2020'>Dragon &amp; Me</a><a href='/13/'>Other</a><a href='/404/'>Missing</a></div>";
    var out: [2]Item = undefined;
    const r = parseArchive(body, "dragon", &out);
    try std.testing.expect(r.valid);
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqual(@as(u32, 12), out[0].number);
    try std.testing.expectEqual(@as(usize, 1), parseArchive(body, "13", &out).count);
    try std.testing.expect(numberFromPath("1?token=x") == null);
}
test "xkcd metadata identity and owned image origin must agree" {
    const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"num\":12,\"safe_title\":\"Real\",\"img\":\"https://imgs.xkcd.com/comics/a.png\",\"alt\":\"Alt\"}", .{});
    defer p.deinit();
    try std.testing.expect(parseXkcd(p.value, 12, "https://xkcd.com") != null);
    try std.testing.expect(parseXkcd(p.value, 13, "https://xkcd.com") == null);
}
test "SMBC recent RSS includes full main image and refuses lookalike image origins" {
    const xml = "<rss><item><title><![CDATA[Real Dragon]]></title><link>https://www.smbc-comics.com/comic/dragon</link><description><![CDATA[<img src='https://www.smbc-comics.com/comics/a.png'>]]></description></item></rss>";
    var out: [1]Item = undefined;
    const r = parseSmbc(xml, "https://www.smbc-comics.com", "dragon", &out);
    try std.testing.expect(r.valid);
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqualStrings("smbc:https://www.smbc-comics.com/comic/dragon", out[0].route[0..out[0].route_len]);
    try std.testing.expect(!parseSmbc(xml[0 .. xml.len - 6], "https://www.smbc-comics.com", "", &out).valid);
}

fn allowedImage(image: []const u8, base: []const u8, official: []const u8) bool {
    if (std.mem.startsWith(u8, image, official)) return true;
    var address: [1024]u8 = undefined;
    const owned = html.sourceUrl(&address, base, image) orelse return false;
    const b = std.mem.trimEnd(u8, base, "/");
    return std.mem.startsWith(u8, owned[b.len..], "/comics/");
}
pub fn parseSmbcPage(body: []const u8, base: []const u8, url: []const u8) ?Item {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "<img")) |at| {
        const end = std.mem.indexOfScalarPos(u8, body, at, '>') orelse return null;
        pos = end + 1;
        const image_tag = body[at..pos];
        if (!std.mem.eql(u8, html.attr(image_tag, "id") orelse "", "cc-comic")) continue;
        const image = html.attr(image_tag, "src") orelse return null;
        if (!audio.safeUrl(image) or !allowedImage(image, base, "https://www.smbc-comics.com/comics/") or image.len > 1024) return null;
        var item: Item = .{};
        audio.copy(&item.image, &item.image_len, image);
        audio.copy(&item.title, &item.title_len, "Saturday Morning Breakfast Cereal");
        audio.copy(&item.summary, &item.summary_len, html.attr(image_tag, "title") orelse "Zach Weinersmith");
        item.route_len = (std.fmt.bufPrint(&item.route, "smbc:{s}", .{url}) catch return null).len;
        return item;
    }
    return null;
}
test "SMBC reader resolves old direct work after it leaves recent RSS and excludes bonus panel" {
    const body = "<img src='https://www.smbc-comics.com/comics/main.png' id='cc-comic' title='Actual alt'><img src='https://www.smbc-comics.com/comics/bonus.png'>";
    const row = parseSmbcPage(body, "https://www.smbc-comics.com", "https://www.smbc-comics.com/comic/old").?;
    try std.testing.expectEqualStrings("https://www.smbc-comics.com/comics/main.png", row.image[0..row.image_len]);
    try std.testing.expect(parseSmbcPage("<img id='cc-comic' src='https://www.smbc-comics.com.evil/comics/x.png'>", "https://www.smbc-comics.com", "") == null);
}

/// Preserve the verified comic number so numeric queries survive shared title ranking.
pub fn numberedTitle(out: []u8, title: []const u8, number: u32) []const u8 {
    const prefix = std.fmt.bufPrint(out, "#{d} · ", .{number}) catch return out[0..0];
    var copied: usize = 0;
    audio.copy(out[prefix.len..], &copied, title);
    return out[0 .. prefix.len + copied];
}
test "xkcd verified numeric match remains visible to common title ranking" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#12 · Fixture comic", numberedTitle(&out, "Fixture comic", 12));
    var narrow: [10]u8 = undefined;
    try std.testing.expect(std.unicode.utf8ValidateSlice(numberedTitle(&narrow, "日本語", 12)));
}

test "public comic cache retains reader identities but excludes embedded credentials" {
    const cache = @import("search_content_pure.zig");
    try std.testing.expect(cache.cacheEligible(.{ .source = "comics", .provider = "xkcd", .url = "xkcd:12" }));
    try std.testing.expect(cache.cacheEligible(.{ .source = "comics", .provider = "smbc", .url = "smbc:https://www.smbc-comics.com/comic/specify" }));
    try std.testing.expect(!cache.cacheEligible(.{ .source = "comics", .provider = "smbc", .url = "smbc:https://user:pass@host/comic/specify" }));
}
