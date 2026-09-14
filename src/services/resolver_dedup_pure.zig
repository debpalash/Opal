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

fn isReleaseToken(token: []const u8) bool {
    const noise = [_][]const u8{
        "480p",   "720p",     "1080p", "2160p",  "4k",    "8k",    "web",  "dl",    "webdl", "webrip",
        "bluray", "brrip",    "hdrip", "dvdrip", "remux", "x264",  "x265", "h264",  "h265",  "hevc",
        "av1",    "aac",      "ac3",   "eac3",   "dts",   "atmos", "hdr",  "hdr10", "dolby", "proper",
        "repack", "extended", "multi", "dual",   "audio",
    };
    for (noise) |entry| if (std.mem.eql(u8, token, entry)) return true;
    return false;
}

/// Stable title identity across source-specific punctuation and release tags.
/// Years and episode tokens are deliberately retained so adjacent releases do
/// not collapse. Returns an empty key when the surviving title is too weak.
pub fn semanticKey(name: []const u8, out: []u8) []const u8 {
    var token: [64]u8 = undefined;
    var token_len: usize = 0;
    var written: usize = 0;
    var significant: usize = 0;
    var i: usize = 0;
    while (i <= name.len) : (i += 1) {
        const ch: u8 = if (i < name.len) name[i] else ' ';
        if (std.ascii.isAlphanumeric(ch)) {
            if (token_len < token.len) {
                token[token_len] = std.ascii.toLower(ch);
                token_len += 1;
            }
            continue;
        }
        if (token_len == 0) continue;
        const value = token[0..token_len];
        if (!isReleaseToken(value)) {
            if (written > 0) {
                if (written >= out.len) return "";
                out[written] = ' ';
                written += 1;
            }
            if (written + value.len > out.len) return "";
            @memcpy(out[written .. written + value.len], value);
            written += value.len;
            significant += value.len;
        }
        token_len = 0;
    }
    return if (significant >= 4) out[0..written] else "";
}

pub fn sameSemantic(a: []const u8, b: []const u8) bool {
    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    const ka = semanticKey(a, &a_buf);
    const kb = semanticKey(b, &b_buf);
    return ka.len > 0 and std.mem.eql(u8, ka, kb);
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

test "semantic identity ignores release tags but preserves editions" {
    try std.testing.expect(sameSemantic(
        "Reacher S03E04 2160p WEB-DL HEVC",
        "Reacher.S03E04.1080p.BluRay.x264",
    ));
    try std.testing.expect(!sameSemantic("Reacher S03E04 1080p", "Reacher S03E05 1080p"));
    try std.testing.expect(!sameSemantic("Up 1080p", "Us 1080p"));
}
