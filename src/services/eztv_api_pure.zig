//! Parsing for EZTV's `/api/get-torrents` JSON feed.
//!
//! Why this backend exists at all: EZTV's HTML search page is unusable from
//! here. `eztvx.to` resets ~90% of connections, and its live mirror is
//! Cloudflare-walled and lists rows that link to `/ep/<id>/` detail pages
//! instead of embedding magnets — 50 detail fetches per search. The JSON API
//! answers in one request with everything a result row needs, and (measured
//! 2026-08-01) is served without a wall.
//!
//! The API is IMDb-keyed, not text-searchable, which is fine: the resolver
//! already turns a query into an IMDb id for the Stremio backend, and this
//! reuses that exact path (`resolveImdbId`).
//!
//! Parsed by hand rather than with std.json: the fields needed are five flat
//! scalars per item, the payload can be a megabyte, and the surrounding
//! resolver code already works this way (`extractStr` / `torznab_pure`).

const std = @import("std");

/// EZTV wants the id WITHOUT the `tt` prefix — `imdb_id=6048596`, not
/// `tt6048596`. Passing the tt form returns an empty torrent list, which reads
/// exactly like "this show has no releases" and is the easiest way to make this
/// backend look dead while it is in fact being asked the wrong question.
pub fn stripTtPrefix(imdb: []const u8) []const u8 {
    if (imdb.len > 2 and (imdb[0] == 't' or imdb[0] == 'T') and (imdb[1] == 't' or imdb[1] == 'T')) {
        return imdb[2..];
    }
    return imdb;
}

/// True when every byte is an ASCII digit and there is at least one. The id goes
/// straight into a URL query, so a non-numeric value is rejected rather than
/// escaped — EZTV has no use for one and it keeps the URL builder trivial.
pub fn isNumericId(s: []const u8) bool {
    if (s.len == 0 or s.len > 12) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// `{base}/api/get-torrents?imdb_id={id}&limit={n}`, or null if it will not fit.
/// `base` may carry a trailing slash; exactly one is emitted either way.
pub fn buildUrl(base: []const u8, imdb_numeric: []const u8, limit: u32, buf: []u8) ?[]const u8 {
    var b = std.mem.trim(u8, base, " \t\r\n");
    while (b.len > 0 and b[b.len - 1] == '/') b = b[0 .. b.len - 1];
    if (b.len == 0 or !isNumericId(imdb_numeric)) return null;
    return std.fmt.bufPrint(buf, "{s}/api/get-torrents?imdb_id={s}&limit={d}", .{ b, imdb_numeric, limit }) catch null;
}

pub const Item = struct {
    title: []const u8 = "",
    magnet: []const u8 = "",
    seeds: u16 = 0,
    peers: u16 = 0,
    size_bytes: u64 = 0,
};

/// Value of `"key":"..."` inside `block`, or null. Returns a slice INTO block.
fn strField(block: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [40]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, block, pat) orelse return null;
    const from = at + pat.len;
    const end = std.mem.indexOfScalarPos(u8, block, from, '"') orelse return null;
    return block[from..end];
}

/// Value of a numeric field. EZTV quotes some numbers and not others
/// (`"seeds":12` but `"size_bytes":"479545240"`), so both forms are accepted —
/// keying off the quoting would silently zero whichever one changed.
fn numField(block: []const u8, key: []const u8) ?u64 {
    var pat_buf: [40]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, block, pat) orelse return null;
    var i = at + pat.len;
    while (i < block.len and (block[i] == ' ' or block[i] == '"')) i += 1;
    const start = i;
    while (i < block.len and block[i] >= '0' and block[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u64, block[start..i], 10) catch null;
}

/// Parse up to `out.len` items from a feed. Returns how many were written.
///
/// An item with no magnet is skipped rather than emitted with an empty link: a
/// row that cannot be played is worse than one fewer row.
pub fn parseItems(body: []const u8, out: []Item) usize {
    var n: usize = 0;
    var pos: usize = 0;
    while (n < out.len) {
        // Items are objects in the "torrents" array; anchor on the field every
        // one of them has rather than trying to balance braces.
        const t_at = std.mem.indexOfPos(u8, body, pos, "\"title\":") orelse break;
        // The block runs to the next title (or the end) — enough to scope the
        // other fields to this item without a real JSON parse.
        const next = std.mem.indexOfPos(u8, body, t_at + 8, "\"title\":") orelse body.len;
        const block = body[t_at..next];
        pos = next;

        const title = strField(block, "title") orelse continue;
        if (title.len == 0) continue;
        const magnet = strField(block, "magnet_url") orelse continue;
        if (!std.mem.startsWith(u8, magnet, "magnet:")) continue;

        out[n] = .{
            .title = title,
            .magnet = magnet,
            .seeds = @intCast(@min(numField(block, "seeds") orelse 0, 65535)),
            .peers = @intCast(@min(numField(block, "peers") orelse 0, 65535)),
            .size_bytes = numField(block, "size_bytes") orelse 0,
        };
        n += 1;
    }
    return n;
}

// ── Tests ──

const t = std.testing;

/// Trimmed from a real response (eztv1.xyz, imdb_id=6048596, 2026-08-01).
const SAMPLE =
    \\{"imdb_id":"6048596","torrents_count":129,"limit":2,"page":1,"torrents":[
    \\{"id":1727876,"hash":"f6b98","filename":"The.Sinner.S04E08.mkv","title":"The Sinner S04E08 1080p HEVC x265-MeGusta EZTV",
    \\"magnet_url":"magnet:?xt=urn:btih:f6b983c6dc14fccd0741790cc3fb51fbf5d8c932&dn=The.Sinner","seeds":0,"peers":2,
    \\"size_bytes":"479545240","date_released_unix":1638430670},
    \\{"id":1727877,"title":"The Sinner S04E07 720p WEB x264","magnet_url":"magnet:?xt=urn:btih:aaaa","seeds":41,"peers":7,
    \\"size_bytes":"1073741824","date_released_unix":1638430000}]}
;

test "parseItems reads every field a result row needs" {
    var items: [8]Item = undefined;
    const n = parseItems(SAMPLE, &items);
    try t.expectEqual(@as(usize, 2), n);

    try t.expectEqualStrings("The Sinner S04E08 1080p HEVC x265-MeGusta EZTV", items[0].title);
    try t.expect(std.mem.startsWith(u8, items[0].magnet, "magnet:?xt=urn:btih:f6b983"));
    try t.expectEqual(@as(u16, 0), items[0].seeds);
    try t.expectEqual(@as(u16, 2), items[0].peers);
    // size_bytes arrives QUOTED; a parser that only accepted bare numbers would
    // silently report every EZTV release as 0 bytes.
    try t.expectEqual(@as(u64, 479545240), items[0].size_bytes);

    try t.expectEqual(@as(u16, 41), items[1].seeds);
    try t.expectEqual(@as(u64, 1073741824), items[1].size_bytes);
}

test "parseItems skips an item with no playable link" {
    // A row without a magnet cannot be played; emitting it with an empty link
    // would put a dead row in the results list.
    const feed =
        \\{"torrents":[{"title":"No Magnet Here","seeds":9},
        \\{"title":"Has One","magnet_url":"magnet:?xt=urn:btih:bbb","seeds":3}]}
    ;
    var items: [8]Item = undefined;
    const n = parseItems(feed, &items);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqualStrings("Has One", items[0].title);

    // Same for a non-magnet link.
    const bad =
        \\{"torrents":[{"title":"X","magnet_url":"http://not-a-magnet"}]}
    ;
    try t.expectEqual(@as(usize, 0), parseItems(bad, &items));
}

test "parseItems is bounded by the caller's buffer and survives junk" {
    var one: [1]Item = undefined;
    try t.expectEqual(@as(usize, 1), parseItems(SAMPLE, &one));

    var items: [4]Item = undefined;
    try t.expectEqual(@as(usize, 0), parseItems("", &items));
    try t.expectEqual(@as(usize, 0), parseItems("{}", &items));
    try t.expectEqual(@as(usize, 0), parseItems("{\"torrents\":[]}", &items));
    // Truncated mid-item: no crash, no half-built row.
    try t.expectEqual(@as(usize, 0), parseItems("{\"torrents\":[{\"title\":\"cut", &items));

    var none: [0]Item = undefined;
    try t.expectEqual(@as(usize, 0), parseItems(SAMPLE, &none));
}

test "stripTtPrefix: EZTV wants the bare number" {
    // REGRESSION GUARD: `imdb_id=tt6048596` returns an EMPTY torrent list, which
    // is indistinguishable from "no releases" — the backend would look dead
    // while simply asking the wrong question.
    try t.expectEqualStrings("6048596", stripTtPrefix("tt6048596"));
    try t.expectEqualStrings("6048596", stripTtPrefix("6048596"));
    try t.expectEqualStrings("6048596", stripTtPrefix("TT6048596"));
    try t.expectEqualStrings("", stripTtPrefix(""));
    // Not a tt prefix — must not eat real digits.
    try t.expectEqualStrings("12", stripTtPrefix("12"));
}

test "isNumericId rejects anything that would need escaping" {
    try t.expect(isNumericId("6048596"));
    try t.expect(!isNumericId(""));
    try t.expect(!isNumericId("tt6048596"));
    try t.expect(!isNumericId("604 8596"));
    try t.expect(!isNumericId("6048596&x=1")); // query injection
    try t.expect(!isNumericId("9999999999999"));
}

test "buildUrl normalises the base and refuses a bad id" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings(
        "https://eztv1.xyz/api/get-torrents?imdb_id=6048596&limit=100",
        buildUrl("https://eztv1.xyz", "6048596", 100, &buf).?,
    );
    // Trailing slashes must not double up.
    try t.expectEqualStrings(
        "https://eztv1.xyz/api/get-torrents?imdb_id=6048596&limit=50",
        buildUrl("https://eztv1.xyz///", "6048596", 50, &buf).?,
    );
    try t.expect(buildUrl("", "6048596", 100, &buf) == null);
    try t.expect(buildUrl("https://eztv1.xyz", "tt6048596", 100, &buf) == null);
    var tiny: [8]u8 = undefined;
    try t.expect(buildUrl("https://eztv1.xyz", "6048596", 100, &tiny) == null);
}
