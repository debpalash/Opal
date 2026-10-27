//! Cross-source dedup for universal search — collapses the same result surfaced
//! by multiple sources so the list doesn't flood. PURE, unit-tested; pushResult
//! routes through `sameItem` so the shipped dedup is the tested dedup.
const std = @import("std");

/// The identity key of a result URL. For a magnet the infohash IS the identity
/// (the same release from 5 trackers differs only in the appended `&tr=` list),
/// so we key on `btih:<hash>`; otherwise the full URL. Returns a slice into `url`.
pub fn dedupKey(url: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, url, "magnet:?")) return url;
    if (std.mem.indexOf(u8, url, "xt=urn:btih:")) |at| {
        const start = at + "xt=urn:btih:".len;
        var end = start;
        while (end < url.len and url[end] != '&' and url[end] != '.' and url[end] != '/') end += 1;
        if (end > start) return url[start..end];
    }
    return url;
}

/// Magnet hashes ignore case; URL paths and query values preserve case.
pub fn sameItem(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const ka = dedupKey(a);
    const kb = dedupKey(b);
    if (ka.len != kb.len) return false;
    // Whole URLs include case-sensitive paths, signed tokens, and provider IDs.
    // Only an extracted magnet infohash permits case folding.
    if (ka.len == a.len or kb.len == b.len) return std.mem.eql(u8, a, b);
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

// ── Logical result groups (ROADMAP 6.3) ─────────────────────────────────
// pushInto folds same-work renditions into one row: `url` plus up to two
// fallbacks. These helpers turn that row back into a pickable source list.

/// Number of distinct playable sources a folded row carries (0..3).
pub fn sourceCount(primary: []const u8, fallback_1: []const u8, fallback_2: []const u8) usize {
    var n: usize = 0;
    for ([_][]const u8{ primary, fallback_1, fallback_2 }) |u| {
        if (u.len > 0) n += 1;
    }
    return n;
}

/// Reorders the row's sources so the `pick`-th non-empty one plays first and
/// the remaining ones keep their order as fallbacks. Out-of-range `pick`
/// returns the original order (compacted).
pub fn promoteSource(primary: []const u8, fallback_1: []const u8, fallback_2: []const u8, pick: usize) [3][]const u8 {
    var list: [3][]const u8 = .{ "", "", "" };
    var n: usize = 0;
    for ([_][]const u8{ primary, fallback_1, fallback_2 }) |u| {
        if (u.len == 0) continue;
        list[n] = u;
        n += 1;
    }
    if (pick == 0 or pick >= n) return list;
    var out: [3][]const u8 = .{ list[pick], "", "" };
    var w: usize = 1;
    for (list[0..n], 0..) |u, i| {
        if (i == pick) continue;
        out[w] = u;
        w += 1;
    }
    return out;
}

/// Short human label for a source URL: its host, "Torrent" for a magnet, or
/// "Local file" for an absolute path. Returns a slice into `url` or a literal.
pub fn sourceLabel(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "magnet:?")) return "Torrent";
    if (std.mem.startsWith(u8, url, "/") or std.mem.startsWith(u8, url, "file://")) return "Local file";
    const at = std.mem.indexOf(u8, url, "://") orelse return url;
    var host = url[at + 3 ..];
    if (std.mem.indexOfAny(u8, host, "/?#")) |end| host = host[0..end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |cred| host = host[cred + 1 ..];
    if (std.mem.startsWith(u8, host, "www.")) host = host[4..];
    return if (host.len > 0) host else url;
}

test "sourceCount counts the primary plus non-empty fallbacks" {
    try std.testing.expectEqual(@as(usize, 0), sourceCount("", "", ""));
    try std.testing.expectEqual(@as(usize, 1), sourceCount("a", "", ""));
    try std.testing.expectEqual(@as(usize, 2), sourceCount("a", "", "c"));
    try std.testing.expectEqual(@as(usize, 3), sourceCount("a", "b", "c"));
}

test "promoteSource plays the picked source first, rest stay as fallbacks" {
    const p0 = promoteSource("a", "b", "c", 0);
    try std.testing.expectEqualStrings("a", p0[0]);
    try std.testing.expectEqualStrings("b", p0[1]);
    const p2 = promoteSource("a", "b", "c", 2);
    try std.testing.expectEqualStrings("c", p2[0]);
    try std.testing.expectEqualStrings("a", p2[1]);
    try std.testing.expectEqualStrings("b", p2[2]);
    const p1 = promoteSource("a", "", "c", 1);
    try std.testing.expectEqualStrings("c", p1[0]);
    try std.testing.expectEqualStrings("a", p1[1]);
    try std.testing.expectEqualStrings("", p1[2]);
    const oob = promoteSource("a", "b", "", 5);
    try std.testing.expectEqualStrings("a", oob[0]);
    try std.testing.expectEqualStrings("b", oob[1]);
}

test "sourceLabel names the host, torrent, or local file" {
    try std.testing.expectEqualStrings("cdn.example.com", sourceLabel("https://www.cdn.example.com/v/a.mp4?t=1"));
    try std.testing.expectEqualStrings("host:8080", sourceLabel("http://u:p@host:8080/x"));
    try std.testing.expectEqualStrings("Torrent", sourceLabel("magnet:?xt=urn:btih:AAAA"));
    try std.testing.expectEqualStrings("Local file", sourceLabel("/Users/x/movie.mkv"));
}
