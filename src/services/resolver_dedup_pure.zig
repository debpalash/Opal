//! Cross-source dedup for universal search — collapses the same result surfaced
//! by multiple sources so the list doesn't flood. PURE, unit-tested; pushResult
//! routes through `sameItem` so the shipped dedup is the tested dedup.
const std = @import("std");

/// The identity key of a result URL. For a magnet the infohash IS the identity
/// (the same release from 5 trackers differs only in the appended `&tr=` list),
/// so we key on `btih:<hash>`; otherwise the full URL. Returns a slice into `url`.
pub fn dedupKey(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "btih:")) |at| {
        const start = at + "btih:".len;
        var end = start;
        while (end < url.len and url[end] != '&' and url[end] != '.' and url[end] != '/') end += 1;
        if (end > start) return url[start..end];
    }
    return url;
}

/// Two result URLs point at the same item (case-insensitive key compare).
pub fn sameItem(a: []const u8, b: []const u8) bool {
    const ka = dedupKey(a);
    const kb = dedupKey(b);
    if (ka.len != kb.len) return false;
    for (ka, kb) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

test "dedupKey extracts the magnet infohash (ignoring trackers)" {
    try std.testing.expectEqualStrings(
        "C12FE1C06BBA254A9DC9F519B335AA7C1367A88A",
        dedupKey("magnet:?xt=urn:btih:C12FE1C06BBA254A9DC9F519B335AA7C1367A88A&dn=x&tr=udp://a"),
    );
    try std.testing.expectEqualStrings("https://x/y", dedupKey("https://x/y"));
}

test "sameItem: same infohash / different trackers → dup; different hash → not" {
    try std.testing.expect(sameItem(
        "magnet:?xt=urn:btih:AAAABBBBCCCCDDDDEEEE&tr=udp://a:1",
        "magnet:?xt=urn:btih:aaaabbbbccccddddeeee&dn=Movie&tr=http://b/announce",
    ));
    try std.testing.expect(!sameItem(
        "magnet:?xt=urn:btih:AAAA&tr=x",
        "magnet:?xt=urn:btih:BBBB&tr=x",
    ));
    try std.testing.expect(sameItem("https://cdn/a.mp4", "https://cdn/a.mp4"));
    try std.testing.expect(!sameItem("https://cdn/a.mp4", "https://cdn/b.mp4"));
}
