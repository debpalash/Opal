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
