//! The muted meta line under a universal-search result: quality, size, swarm.
//!
//! Split out of `search.zig::renderCompactRow` so the formatting rules are
//! testable rather than buried in a draw call.
//!
//! Background: the row showed only `quality · N seeds`. Every torrent backend
//! reports a payload size and a leecher count — nova2 prints both in its
//! pipe-delimited row, torznab_pure parses both off the feed — and every one of
//! them was discarded at the parse site. So a user picking between two releases
//! could not see which was a 700 MB rip and which was a 40 GB remux, and
//! `torrent_risk_pure.assess` was being handed a hardcoded size of 0, which
//! silently disabled its entire size-based arm.

const std = @import("std");

pub const Meta = struct {
    /// 0=unknown, 1=480p, 2=720p, 3=1080p, 4=4K.
    quality: u8 = 0,
    /// 0 = genuinely unknown; never render "0 B".
    size_bytes: u64 = 0,
    seeds: u16 = 0,
    leech: u16 = 0,
};
/// YouTube search returns both watchable titles and promotional clips. Limit
/// the preview section to standalone "trailer"/"teaser" words; a substring
/// match would mislabel titles such as "Trailer Park Boys" or "Trailers".
/// Explicit full-length labels win when a title mentions both.
pub fn isPreviewTitle(title: []const u8) bool {
    const full_markers = [_][]const u8{
        "full movie", "full film", "full episode", "full length",
        "complete movie", "complete film", "entire movie", "entire film",
    };
    for (full_markers) |marker| {
        if (hasWords(title, marker)) return false;
    }
    // "Trailer Park Boys" is a title, not a promotional designation.
    if (hasWords(title, "trailer park") and
        !hasWords(title, "official trailer") and
        !hasWords(title, "teaser") and
        !hasTrailingPreviewWord(title)) return false;
    return hasWords(title, "trailer") or hasWords(title, "teaser");
}

fn hasTrailingPreviewWord(title: []const u8) bool {
    var end = title.len;
    while (end > 0 and !std.ascii.isAlphanumeric(title[end - 1])) : (end -= 1) {}
    for ([_][]const u8{ "trailer", "teaser" }) |word| {
        if (end >= word.len and std.ascii.eqlIgnoreCase(title[end - word.len .. end], word) and
            (end == word.len or !std.ascii.isAlphanumeric(title[end - word.len - 1]))) return true;
    }
    return false;
}

fn hasWords(haystack: []const u8, words: []const u8) bool {
    if (words.len > haystack.len) return false;
    for (0..haystack.len - words.len + 1) |start| {
        if (start > 0 and std.ascii.isAlphanumeric(haystack[start - 1])) continue;
        var h = start;
        var w: usize = 0;
        while (w < words.len) : (w += 1) {
            if (words[w] == ' ') {
                if (h >= haystack.len or
                    !(std.ascii.isWhitespace(haystack[h]) or haystack[h] == '-' or haystack[h] == '_')) break;
                while (h < haystack.len and
                    (std.ascii.isWhitespace(haystack[h]) or haystack[h] == '-' or haystack[h] == '_')) : (h += 1) {}
            } else {
                if (h >= haystack.len or std.ascii.toLower(haystack[h]) != words[w]) break;
                h += 1;
            }
        }
        if (w == words.len and (h == haystack.len or !std.ascii.isAlphanumeric(haystack[h]))) return true;
    }
    return false;
}

/// Human-readable payload size. Chooses the unit by magnitude, one decimal for
/// GB and none below — a release list is scanned, not audited, and "1.4 GB"
/// reads faster than "1434 MB".
pub fn fmtSize(bytes: u64, buf: []u8) []const u8 {
    if (bytes == 0) return "";
    const b = @as(f64, @floatFromInt(bytes));
    if (b >= 1024.0 * 1024.0 * 1024.0 * 1024.0)
        return std.fmt.bufPrint(buf, "{d:.1} TB", .{b / (1024.0 * 1024.0 * 1024.0 * 1024.0)}) catch "";
    if (b >= 1024.0 * 1024.0 * 1024.0)
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{b / (1024.0 * 1024.0 * 1024.0)}) catch "";
    if (b >= 1024.0 * 1024.0)
        return std.fmt.bufPrint(buf, "{d:.0} MB", .{b / (1024.0 * 1024.0)}) catch "";
    return std.fmt.bufPrint(buf, "{d:.0} KB", .{b / 1024.0}) catch "";
}

pub fn qualityText(q: u8) []const u8 {
    return switch (q) {
        4 => "4K",
        3 => "1080p",
        2 => "720p",
        1 => "480p",
        else => "",
    };
}

/// `quality · size · S seeds · L leech`, skipping every field that is unknown,
/// with no stray separators at either end. Returns a slice of `buf`.
///
/// A field is omitted rather than shown as zero: "0 seeds" and "0 B" both read
/// as measurements when they actually mean "the source did not say".
pub fn metaLine(m: Meta, buf: []u8) []const u8 {
    var w: usize = 0;

    const parts_written = struct {
        fn sep(b: []u8, at: usize) usize {
            if (at == 0) return 0;
            const s = " \u{00B7} ";
            if (at + s.len > b.len) return 0;
            @memcpy(b[at..][0..s.len], s);
            return s.len;
        }
    };

    const q = qualityText(m.quality);
    if (q.len > 0 and q.len <= buf.len) {
        @memcpy(buf[0..q.len], q);
        w = q.len;
    }

    if (m.size_bytes > 0) {
        var sb: [16]u8 = undefined;
        const s = fmtSize(m.size_bytes, &sb);
        if (s.len > 0 and w + 3 + s.len <= buf.len) {
            w += parts_written.sep(buf, w);
            @memcpy(buf[w..][0..s.len], s);
            w += s.len;
        }
    }

    if (m.seeds > 0) {
        var nb: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&nb, "{d} seeds", .{m.seeds}) catch "";
        if (s.len > 0 and w + 3 + s.len <= buf.len) {
            w += parts_written.sep(buf, w);
            @memcpy(buf[w..][0..s.len], s);
            w += s.len;
        }
    }

    // Leechers only alongside seeds: on its own the number is meaningless, and
    // the pair is what tells you whether a swarm is alive or merely listed.
    if (m.leech > 0 and m.seeds > 0) {
        var nb: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&nb, "{d} leech", .{m.leech}) catch "";
        if (s.len > 0 and w + 3 + s.len <= buf.len) {
            w += parts_written.sep(buf, w);
            @memcpy(buf[w..][0..s.len], s);
            w += s.len;
        }
    }

    return buf[0..w];
}

// ── Tests ──

const t = std.testing;

test "fmtSize picks the unit by magnitude" {
    var b: [16]u8 = undefined;
    try t.expectEqualStrings("1.4 GB", fmtSize(1503238553, &b));
    try t.expectEqualStrings("700 MB", fmtSize(734003200, &b));
    try t.expectEqualStrings("512 KB", fmtSize(524288, &b));
    try t.expectEqualStrings("2.0 TB", fmtSize(2199023255552, &b));
    // Unknown must render as nothing at all, never "0 KB" — that reads as a
    // measured value when it means the source did not report one.
    try t.expectEqualStrings("", fmtSize(0, &b));
}

test "metaLine joins only the fields that are known" {
    var b: [64]u8 = undefined;
    try t.expectEqualStrings(
        "1080p \u{00B7} 1.4 GB \u{00B7} 42 seeds \u{00B7} 7 leech",
        metaLine(.{ .quality = 3, .size_bytes = 1503238553, .seeds = 42, .leech = 7 }, &b),
    );
    // No quality: no leading separator.
    try t.expectEqualStrings("1.4 GB \u{00B7} 42 seeds",
        metaLine(.{ .size_bytes = 1503238553, .seeds = 42 }, &b));
    // No size: the old shape still works.
    try t.expectEqualStrings("720p \u{00B7} 5 seeds",
        metaLine(.{ .quality = 2, .seeds = 5 }, &b));
    // Nothing known at all: empty, so the caller draws no label.
    try t.expectEqualStrings("", metaLine(.{}, &b));
    // Quality alone: no trailing separator.
    try t.expectEqualStrings("4K", metaLine(.{ .quality = 4 }, &b));
}

test "metaLine: leech without seeds is dropped" {
    // A leecher count with no seed count says nothing useful and invites the
    // reading "7 people have this", which is the opposite of the truth.
    var b: [64]u8 = undefined;
    try t.expectEqualStrings("1080p", metaLine(.{ .quality = 3, .leech = 7 }, &b));
    try t.expectEqualStrings("1080p \u{00B7} 1 seeds \u{00B7} 7 leech",
        metaLine(.{ .quality = 3, .seeds = 1, .leech = 7 }, &b));
}

test "metaLine never overruns a short buffer" {
    // Truncation must drop whole fields, never emit a half-written one or run
    // past the end — this string goes straight into a draw call.
    var tiny: [8]u8 = undefined;
    const s = metaLine(.{ .quality = 3, .size_bytes = 1503238553, .seeds = 42, .leech = 7 }, &tiny);
    try t.expect(s.len <= tiny.len);
    try t.expectEqualStrings("1080p", s);

    var none: [1]u8 = undefined;
    try t.expectEqualStrings("", metaLine(.{ .quality = 3, .seeds = 9 }, &none));

    // Exactly-fits is not an overrun.
    var exact: [5]u8 = undefined;
    try t.expectEqualStrings("1080p", metaLine(.{ .quality = 3 }, &exact));
}

test "metaLine: huge values still fit the row buffer search.zig uses" {
    // u16 seeds/leech and a TB-scale size are the worst case; the caller's
    // 64-byte buffer must hold it, or sizes would silently vanish on big rows.
    var b: [64]u8 = undefined;
    const s = metaLine(.{
        .quality = 3,
        .size_bytes = 9_999_999_999_999,
        .seeds = 65535,
        .leech = 65535,
    }, &b);
    try t.expect(std.mem.indexOf(u8, s, "TB") != null);
    try t.expect(std.mem.indexOf(u8, s, "65535 seeds") != null);
    try t.expect(std.mem.indexOf(u8, s, "65535 leech") != null);
}

test "YouTube preview titles are standalone promotional clips, not full movies" {
    try t.expect(isPreviewTitle("Some Movie (2026) - Official Trailer"));
    try t.expect(isPreviewTitle("Some Movie | TEASER #2"));
    try t.expect(isPreviewTitle("Trailer Park Boys Official Trailer"));
    try t.expect(!isPreviewTitle("Trailer Park Boys: The Movie"));
    try t.expect(!isPreviewTitle("Some Movie Full Movie (Trailer in credits)"));
    try t.expect(!isPreviewTitle("The Trailers (2026)"));
    try t.expect(!isPreviewTitle("Teasertown: Full Film"));
    try t.expect(!isPreviewTitle("Some Movie - Official Trailer - Full Movie"));
    try t.expect(!isPreviewTitle("Some Movie - Full-Movie (Trailer included)"));
}
