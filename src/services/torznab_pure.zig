//! Pure Torznab/Newznab XML item parsing — no I/O, no allocator, fully testable.
//!
//! The Torznab feed returned by Prowlarr/Jackett is RSS with a
//! `torznab.com/schemas/2015/feed` namespace. Torrent metadata (seeders, size,
//! magnet URL, …) lives in self-closing `<torznab:attr name="X" value="Y"/>`
//! elements whose attribute order is NOT guaranteed, so parsing must be
//! order-independent. `resolveTorznab` in resolver.zig routes ALL of its
//! per-item extraction through the functions here so the tested logic is the
//! shipped logic (CLAUDE.md *_pure discipline).

const std = @import("std");

/// Strip a `<![CDATA[ ... ]]>` wrapper and surrounding whitespace from a value.
pub fn stripCdata(raw: []const u8) []const u8 {
    var v = std.mem.trim(u8, raw, " \t\r\n");
    const cd_open = "<![CDATA[";
    if (std.mem.startsWith(u8, v, cd_open)) {
        v = v[cd_open.len..];
        if (std.mem.indexOf(u8, v, "]]>")) |e| v = v[0..e];
    }
    return std.mem.trim(u8, v, " \t\r\n");
}

/// Text between `open` and `close` within `block`, CDATA-stripped. Null if the
/// pair isn't present. `open`/`close` are literal tags e.g. "<title>".
pub fn extractTag(block: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const s = (std.mem.indexOf(u8, block, open) orelse return null) + open.len;
    const e = std.mem.indexOfPos(u8, block, s, close) orelse return null;
    return stripCdata(block[s..e]);
}

/// Value of `key="..."` inside a single element string `tag`. Null if absent.
pub fn attrByKey(tag: []const u8, key: []const u8) ?[]const u8 {
    // Match `key="` where the char before `key` is not alphanumeric so that a
    // request for "url" doesn't accidentally match a "posterurl" attribute.
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, pos, key)) |ki| {
        const after = ki + key.len;
        if (after < tag.len and tag[after] == '=' and
            (ki == 0 or !std.ascii.isAlphanumeric(tag[ki - 1])))
        {
            // step over ="  (tolerate an optional space before the quote)
            var q = after + 1;
            while (q < tag.len and (tag[q] == ' ' or tag[q] == '"')) {
                if (tag[q] == '"') {
                    q += 1;
                    const e = std.mem.indexOfScalarPos(u8, tag, q, '"') orelse return null;
                    return tag[q..e];
                }
                q += 1;
            }
            return null;
        }
        pos = ki + key.len;
    }
    return null;
}

/// Value of the `<torznab:attr name="<name>" value="..."/>` element within an
/// `<item>` block. Order-independent (value may precede or follow name).
pub fn torznabAttr(item_block: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, item_block, pos, "<torznab:attr")) |ts| {
        const te = std.mem.indexOfScalarPos(u8, item_block, ts, '>') orelse break;
        const tag = item_block[ts .. te + 1];
        pos = te + 1;
        const nm = attrByKey(tag, "name") orelse continue;
        if (std.mem.eql(u8, nm, name)) return attrByKey(tag, "value");
    }
    return null;
}

/// Choose the download link for a Torznab item. Prefers a magnet (magneturl
/// attr, then a magnet: enclosure/link), else a `.torrent` enclosure url, else
/// the `<link>` text. Null if the item carries no usable link.
pub fn pickLink(item_block: []const u8) ?[]const u8 {
    // 1. explicit magnet in a torznab attr
    if (torznabAttr(item_block, "magneturl")) |m| {
        if (std.mem.startsWith(u8, m, "magnet:")) return m;
    }
    // 2. <enclosure url="..."/> — commonly the magnet or the .torrent
    if (std.mem.indexOf(u8, item_block, "<enclosure")) |es| {
        const ee = std.mem.indexOfScalarPos(u8, item_block, es, '>') orelse item_block.len;
        if (attrByKey(item_block[es .. @min(ee + 1, item_block.len)], "url")) |u| {
            if (u.len >= 8) return u;
        }
    }
    // 3. <link>...</link> text (magnet or .torrent redirect)
    if (extractTag(item_block, "<link>", "</link>")) |l| {
        if (l.len >= 8) return l;
    }
    return null;
}

/// Seeders count for an item, or 0 when the attr is missing/malformed.
pub fn seeders(item_block: []const u8) u16 {
    const s = torznabAttr(item_block, "seeders") orelse return 0;
    return std.fmt.parseInt(u16, std.mem.trim(u8, s, " \t\r\n"), 10) catch 0;
}

/// Size in bytes: `<size>` tag first, then a `size` torznab attr, then the
/// `length` of the enclosure. 0 when none parse.
pub fn sizeBytes(item_block: []const u8) u64 {
    if (extractTag(item_block, "<size>", "</size>")) |s| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, s, " \t\r\n"), 10)) |v| return v else |_| {}
    }
    if (torznabAttr(item_block, "size")) |s| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, s, " \t\r\n"), 10)) |v| return v else |_| {}
    }
    if (std.mem.indexOf(u8, item_block, "<enclosure")) |es| {
        const ee = std.mem.indexOfScalarPos(u8, item_block, es, '>') orelse item_block.len;
        if (attrByKey(item_block[es .. @min(ee + 1, item_block.len)], "length")) |l| {
            if (std.fmt.parseInt(u64, std.mem.trim(u8, l, " \t\r\n"), 10)) |v| return v else |_| {}
        }
    }
    return 0;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const sample_item =
    \\<item>
    \\  <title>Big Buck Bunny 1080p BluRay</title>
    \\  <guid>abc123</guid>
    \\  <enclosure url="magnet:?xt=urn:btih:DEADBEEF&amp;dn=bbb" length="734003200" type="application/x-bittorrent"/>
    \\  <torznab:attr name="seeders" value="142"/>
    \\  <torznab:attr name="peers" value="7"/>
    \\  <torznab:attr name="size" value="734003200"/>
    \\</item>
;

test "extractTag pulls title" {
    const t = extractTag(sample_item, "<title>", "</title>").?;
    try std.testing.expectEqualStrings("Big Buck Bunny 1080p BluRay", t);
}

test "torznabAttr is order-independent" {
    // value BEFORE name — must still resolve.
    const block = "<item><torznab:attr value=\"55\" name=\"seeders\"/></item>";
    try std.testing.expectEqualStrings("55", torznabAttr(block, "seeders").?);
    // normal order
    try std.testing.expectEqualStrings("142", torznabAttr(sample_item, "seeders").?);
    // absent attr
    try std.testing.expect(torznabAttr(sample_item, "grabs") == null);
}

test "attrByKey does not match a superstring key" {
    const tag = "<enclosure posterurl=\"http://x/p.jpg\" url=\"magnet:?xt=urn:btih:AA\"/>";
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:AA", attrByKey(tag, "url").?);
}

test "pickLink prefers magnet enclosure" {
    const l = pickLink(sample_item).?;
    try std.testing.expect(std.mem.startsWith(u8, l, "magnet:"));
}

test "pickLink falls back to torrent enclosure then link" {
    const torrent_item =
        "<item><title>X</title>" ++
        "<enclosure url=\"https://host/x.torrent\" type=\"application/x-bittorrent\"/></item>";
    try std.testing.expectEqualStrings("https://host/x.torrent", pickLink(torrent_item).?);

    const link_item = "<item><title>Y</title><link>https://host/dl?id=9</link></item>";
    try std.testing.expectEqualStrings("https://host/dl?id=9", pickLink(link_item).?);
}

test "pickLink prefers magneturl attr over enclosure" {
    const both =
        "<item><enclosure url=\"https://host/x.torrent\"/>" ++
        "<torznab:attr name=\"magneturl\" value=\"magnet:?xt=urn:btih:CAFE\"/></item>";
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:CAFE", pickLink(both).?);
}

test "seeders and sizeBytes parse" {
    try std.testing.expectEqual(@as(u16, 142), seeders(sample_item));
    try std.testing.expectEqual(@as(u64, 734003200), sizeBytes(sample_item));
}

test "stripCdata unwraps CDATA titles" {
    const block = "<item><title><![CDATA[ Some & Title ]]></title></item>";
    try std.testing.expectEqualStrings("Some & Title", extractTag(block, "<title>", "</title>").?);
}

test "malformed XML regression: no crash, no bogus links" {
    // Truncated tags, unterminated quotes, missing closers — must return null /
    // 0 rather than panic or read out of bounds.
    const cases = [_][]const u8{
        "",
        "<item>",
        "<item><title>Trunc",
        "<item><enclosure url=\"magnet:?xt=urn:btih:AA", // unterminated quote
        "<item><torznab:attr name=\"seeders\" value=\"12", // unterminated
        "<item><torznab:attr name=\"seeders\"/></item>", // name but no value
        "<<<>>><item</item>",
    };
    for (cases) |cse| {
        _ = pickLink(cse);
        _ = seeders(cse);
        _ = sizeBytes(cse);
        _ = extractTag(cse, "<title>", "</title>");
        _ = torznabAttr(cse, "seeders");
    }
    // Specifically: an unterminated value quote yields null, not garbage.
    try std.testing.expect(torznabAttr("<item><torznab:attr name=\"seeders\" value=\"12", "seeders") == null);
    // name-without-value yields null.
    try std.testing.expect(torznabAttr("<item><torznab:attr name=\"seeders\"/></item>", "seeders") == null);
}
