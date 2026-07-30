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

// ── Endpoint shape ───────────────────────────────────────────────────────────
//
// "Torznab" names a RESPONSE format, not a URL. Every server that speaks it puts
// the endpoint somewhere different, so the path must be configurable per install:
//
//   Jackett    {base}/api/v2.0/indexers/{indexer}/results/torznab/api   (default)
//   Prowlarr   {base}/{indexerId}/api        — :9696, per-indexer id
//   bitmagnet  {base}/torznab/api            — no indexer segment at all
//
// The path used to be baked in as Jackett's, so the source called
// "Torznab / Prowlarr" could only ever talk to Jackett. A `path` endpoint field
// (template, `{indexer}` substituted) covers all three with one adapter.

/// Jackett's path shape — the historical hardcoded value, kept as the default so
/// existing `torznab.json` installs (base+apikey+indexer, no `path`) keep working.
pub const DEFAULT_PATH = "/api/v2.0/indexers/{indexer}/results/torznab/api";

/// Base origin with surrounding whitespace and any trailing '/' removed, so
/// `{base}{path}` never produces a doubled slash.
pub fn trimBase(raw: []const u8) []const u8 {
    var b = std.mem.trim(u8, raw, " \t\r\n");
    while (b.len > 0 and b[b.len - 1] == '/') b = b[0 .. b.len - 1];
    return b;
}

/// Expand a path template: substitute every `{indexer}`, force a leading '/',
/// drop a trailing '/'. Empty template → `DEFAULT_PATH`. Null when it doesn't fit.
pub fn expandPath(template: []const u8, indexer: []const u8, buf: []u8) ?[]const u8 {
    var t = std.mem.trim(u8, template, " \t\r\n");
    if (t.len == 0) t = DEFAULT_PATH;

    var w: usize = 0;
    if (t[0] != '/') {
        if (w >= buf.len) return null;
        buf[w] = '/';
        w += 1;
    }

    const ph = "{indexer}";
    var pos: usize = 0;
    while (pos < t.len) {
        if (std.mem.indexOfPos(u8, t, pos, ph)) |at| {
            const lit = t[pos..at];
            if (w + lit.len + indexer.len > buf.len) return null;
            @memcpy(buf[w..][0..lit.len], lit);
            w += lit.len;
            @memcpy(buf[w..][0..indexer.len], indexer);
            w += indexer.len;
            pos = at + ph.len;
        } else {
            const lit = t[pos..];
            if (w + lit.len > buf.len) return null;
            @memcpy(buf[w..][0..lit.len], lit);
            w += lit.len;
            break;
        }
    }
    while (w > 1 and buf[w - 1] == '/') w -= 1;
    if (w == 0) return null;
    return buf[0..w];
}

/// Full Torznab search URL. `enc_key`/`enc_query` must already be percent-encoded.
/// An empty apikey omits the parameter entirely (bitmagnet needs no key, and
/// `apikey=` made Jackett reject the request outright). Null when it doesn't fit.
pub fn buildSearchUrl(
    base: []const u8,
    path_template: []const u8,
    indexer: []const u8,
    enc_key: []const u8,
    enc_query: []const u8,
    buf: []u8,
) ?[]const u8 {
    const b = trimBase(base);
    if (b.len == 0) return null;

    var path_buf: [512]u8 = undefined;
    const p = expandPath(path_template, indexer, &path_buf) orelse return null;

    // A template may already carry a query (e.g. bitmagnet "/torznab/api?cat=2000").
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, p, '?') != null) "&" else "?";

    var w = std.Io.Writer.fixed(buf);
    w.writeAll(b) catch return null;
    w.writeAll(p) catch return null;
    w.writeAll(sep) catch return null;
    if (enc_key.len > 0) {
        w.print("apikey={s}&", .{enc_key}) catch return null;
    }
    w.print("t=search&q={s}", .{enc_query}) catch return null;
    return buf[0..w.end];
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

test "trimBase strips whitespace and trailing slashes" {
    try std.testing.expectEqualStrings("http://h:9117", trimBase("http://h:9117"));
    try std.testing.expectEqualStrings("http://h:9117", trimBase("  http://h:9117/  "));
    try std.testing.expectEqualStrings("http://h:9117", trimBase("http://h:9117///"));
    try std.testing.expectEqualStrings("", trimBase("///"));
}

test "expandPath substitutes {indexer} and normalises the slashes" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/api/v2.0/indexers/all/results/torznab/api",
        expandPath("", "all", &buf).?, // empty → Jackett default
    );
    try std.testing.expectEqualStrings(
        "/api/v2.0/indexers/rarbg/results/torznab/api",
        expandPath(DEFAULT_PATH, "rarbg", &buf).?,
    );
    // No placeholder at all (bitmagnet) — template used verbatim.
    try std.testing.expectEqualStrings("/torznab/api", expandPath("/torznab/api", "all", &buf).?);
    // Missing leading slash and a trailing one.
    try std.testing.expectEqualStrings("/torznab/api", expandPath("torznab/api/", "all", &buf).?);
    // Multiple placeholders.
    try std.testing.expectEqualStrings("/a/x/b/x", expandPath("/a/{indexer}/b/{indexer}", "x", &buf).?);
    // Too small a buffer fails instead of truncating into a wrong URL.
    var tiny: [4]u8 = undefined;
    try std.testing.expect(expandPath(DEFAULT_PATH, "all", &tiny) == null);
}

test "buildSearchUrl covers Jackett, Prowlarr and bitmagnet from one adapter" {
    // REGRESSION: the path was hardcoded to Jackett's shape, so the source
    // shipped as "Torznab / Prowlarr" could not reach Prowlarr or bitmagnet.
    var buf: [512]u8 = undefined;

    // Jackett (default path, key present) — byte-identical to the old hardcode.
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:9117/api/v2.0/indexers/all/results/torznab/api?apikey=KEY&t=search&q=dune",
        buildSearchUrl("http://127.0.0.1:9117", "", "all", "KEY", "dune", &buf).?,
    );

    // Prowlarr — per-indexer path on :9696, no /api/v2.0 segment.
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:9696/12/api?apikey=KEY&t=search&q=dune",
        buildSearchUrl("http://127.0.0.1:9696", "/{indexer}/api", "12", "KEY", "dune", &buf).?,
    );

    // bitmagnet — fixed path, no indexer, no api key: the apikey param is OMITTED
    // (an empty `apikey=` is rejected outright by Jackett and meaningless here).
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:3333/torznab/api?t=search&q=dune",
        buildSearchUrl("http://127.0.0.1:3333/", "/torznab/api", "all", "", "dune", &buf).?,
    );

    // A template that already has a query string continues it with '&'.
    try std.testing.expectEqualStrings(
        "http://h/torznab/api?cat=2000&t=search&q=dune",
        buildSearchUrl("http://h", "/torznab/api?cat=2000", "all", "", "dune", &buf).?,
    );

    // Empty base → no URL (the source stays inert rather than hitting "/api/...").
    try std.testing.expect(buildSearchUrl("", "", "all", "K", "q", &buf) == null);
    try std.testing.expect(buildSearchUrl("   ", "", "all", "K", "q", &buf) == null);

    // Overflow returns null instead of a truncated, wrong URL.
    var small: [16]u8 = undefined;
    try std.testing.expect(buildSearchUrl("http://127.0.0.1:9117", "", "all", "KEY", "dune", &small) == null);
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
