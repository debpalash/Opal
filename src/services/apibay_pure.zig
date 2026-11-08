//! Native APIBay (The Pirate Bay JSON API) indexer for platforms without the
//! Python nova2 engines (iOS). Desktop keeps its nova2 apibay engine; this is
//! the same installed `apibay` source endpoint, read without Python.
//! Pure: URL building, row validation, magnet construction.
const std = @import("std");

pub const Row = struct {
    name: []const u8,
    hash: [40]u8,
    seeds: u16,
    leech: u16,
    size: u64,
};

/// `<base>/q.php?q=<query>&cat=<cat>`; cat 0 = all, 200 = video.
pub fn queryUrl(base: []const u8, query: []const u8, cat: u16, out: []u8) ?[]const u8 {
    var enc: [768]u8 = undefined;
    var n: usize = 0;
    for (query) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            if (n + 1 > enc.len) return null;
            enc[n] = c;
            n += 1;
        } else {
            if (n + 3 > enc.len) return null;
            _ = std.fmt.bufPrint(enc[n..][0..3], "%{X:0>2}", .{c}) catch return null;
            n += 3;
        }
    }
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.bufPrint(out, "{s}/q.php?q={s}&cat={d}", .{ trimmed, enc[0..n], cat }) catch null;
}

fn parseCount(text: []const u8) u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " "), 10) catch 0;
}

/// One API row → Row, or null for the "No results returned" sentinel (id 0,
/// all-zero hash) and anything without a real 40-hex info hash.
pub fn row(name: []const u8, info_hash: []const u8, seeders: []const u8, leechers: []const u8, size: []const u8) ?Row {
    if (name.len == 0 or info_hash.len != 40) return null;
    var hash: [40]u8 = undefined;
    var nonzero = false;
    for (info_hash, 0..) |c, i| {
        if (!std.ascii.isHex(c)) return null;
        hash[i] = std.ascii.toLower(c);
        if (c != '0') nonzero = true;
    }
    if (!nonzero) return null;
    return .{
        .name = name,
        .hash = hash,
        .seeds = @intCast(@min(parseCount(seeders), std.math.maxInt(u16))),
        .leech = @intCast(@min(parseCount(leechers), std.math.maxInt(u16))),
        .size = parseCount(size),
    };
}

/// magnet:?xt=urn:btih:<hash>&dn=<name> (the engine adds its own trackers).
pub fn magnet(r: Row, out: []u8) ?[]const u8 {
    var w: usize = 0;
    const head = std.fmt.bufPrint(out, "magnet:?xt=urn:btih:{s}&dn=", .{r.hash}) catch return null;
    w = head.len;
    for (r.name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') {
            if (w + 1 > out.len) return null;
            out[w] = c;
            w += 1;
        } else {
            if (w + 3 > out.len) return null;
            _ = std.fmt.bufPrint(out[w..][0..3], "%{X:0>2}", .{c}) catch return null;
            w += 3;
        }
    }
    return out[0..w];
}

test "apibay query url encodes the episode query" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://apibay.org/q.php?q=breaking%20bad%20s01e01&cat=0", queryUrl("https://apibay.org/", "breaking bad s01e01", 0, &buf).?);
}

test "apibay rows: real release accepted, no-results sentinel rejected" {
    const r = row("Breaking.Bad.S01E01.Pilot.1080p", "0C9FA2CB87DA2D5FCCD4AF71FB1E0A7E7638B4E9", "53", "13", "1193049621").?;
    try std.testing.expectEqual(@as(u16, 53), r.seeds);
    try std.testing.expectEqual(@as(u64, 1193049621), r.size);
    try std.testing.expectEqualStrings("0c9fa2cb87da2d5fccd4af71fb1e0a7e7638b4e9", &r.hash);
    try std.testing.expect(row("No results returned", "0000000000000000000000000000000000000000", "0", "0", "0") == null);
    try std.testing.expect(row("x", "zz", "1", "1", "1") == null);
}

test "apibay magnet carries hash and encoded name" {
    var buf: [256]u8 = undefined;
    const r = row("Breaking Bad S01E01", "0C9FA2CB87DA2D5FCCD4AF71FB1E0A7E7638B4E9", "1", "0", "0").?;
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:0c9fa2cb87da2d5fccd4af71fb1e0a7e7638b4e9&dn=Breaking%20Bad%20S01E01", magnet(r, &buf).?);
}
