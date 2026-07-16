//! VirusTotal deep-link helpers — PURE (no io, no alloc, unit-tested).
//!
//! Consumer-protection lookups only: the app never talks to the VT API and
//! never uploads anything. We extract a torrent's info-hash (or hash a local
//! file elsewhere) and build a `virustotal.com/gui/...` URL that is opened in
//! the SYSTEM browser on an explicit user action.

const std = @import("std");

/// Extract the BitTorrent info-hash from a magnet link's `xt=urn:btih:<hash>`
/// parameter (case-insensitive scan, param ends at `&`). Handles both wire
/// forms — 40-char hex (normalized to lowercase) and 32-char RFC 4648 base32
/// (decoded to 20 bytes, re-encoded as lowercase hex). Anything else is
/// rejected. Returns a slice of `out` (always 40 chars) or null.
pub fn infoHashFromMagnet(magnet: []const u8, out: *[40]u8) ?[]const u8 {
    var i: usize = 0;
    while (i < magnet.len) {
        // Start of a parameter: position 0, or just after '?' / '&'.
        const at_start = i == 0 or magnet[i - 1] == '?' or magnet[i - 1] == '&';
        if (at_start and hasPrefixIgnoreCase(magnet[i..], "xt=urn:btih:")) {
            const val_start = i + "xt=urn:btih:".len;
            const val_end = std.mem.indexOfScalarPos(u8, magnet, val_start, '&') orelse magnet.len;
            const val = magnet[val_start..val_end];
            if (normalizeHash(val, out)) |h| return h;
            // Malformed value — keep scanning; another xt param may be valid.
            i = val_end;
            continue;
        }
        i += 1;
    }
    return null;
}

/// Normalize a raw btih value (40-hex or 32-base32) into lowercase hex.
fn normalizeHash(val: []const u8, out: *[40]u8) ?[]const u8 {
    if (val.len == 40) {
        for (val, 0..) |ch, j| {
            const lc = std.ascii.toLower(ch);
            if (!std.ascii.isHex(lc)) return null;
            out[j] = lc;
        }
        return out[0..40];
    }
    if (val.len == 32) {
        // RFC 4648 base32: 32 chars * 5 bits = 160 bits = 20 bytes, no padding.
        var bytes: [20]u8 = undefined;
        var acc: u32 = 0;
        var bits: u5 = 0;
        var n: usize = 0;
        for (val) |ch| {
            const v = base32Val(ch) orelse return null;
            acc = (acc << 5) | v;
            bits += 5;
            if (bits >= 8) {
                bits -= 8;
                bytes[n] = @truncate(acc >> bits);
                n += 1;
            }
        }
        if (n != 20) return null;
        const hex = "0123456789abcdef";
        for (bytes, 0..) |b, j| {
            out[j * 2] = hex[b >> 4];
            out[j * 2 + 1] = hex[b & 0xf];
        }
        return out[0..40];
    }
    return null;
}

/// RFC 4648 base32 alphabet (A–Z, 2–7), case-insensitive. `0189` are invalid.
fn base32Val(ch: u8) ?u32 {
    const u = std.ascii.toUpper(ch);
    if (u >= 'A' and u <= 'Z') return u - 'A';
    if (u >= '2' and u <= '7') return u - '2' + 26;
    return null;
}

fn hasPrefixIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// `https://www.virustotal.com/gui/search/<hash>` — works for any hash kind.
pub fn searchUrl(hash: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "https://www.virustotal.com/gui/search/{s}", .{hash}) catch buf[0..0];
}

/// `https://www.virustotal.com/gui/file/<sha256hex>` — direct file report.
pub fn fileUrl(sha256hex: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "https://www.virustotal.com/gui/file/{s}", .{sha256hex}) catch buf[0..0];
}

// ══════════════════════════════════════════════════════════
// TESTS
// ══════════════════════════════════════════════════════════

test "hex btih: uppercase normalized to lowercase" {
    var out: [40]u8 = undefined;
    const h = infoHashFromMagnet(
        "magnet:?xt=urn:btih:C12FE1C06BBA254A9DC9F519B335AA7C1367A88A&dn=x",
        &out,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("c12fe1c06bba254a9dc9f519b335aa7c1367a88a", h);
}

test "hex btih: lowercase passes through" {
    var out: [40]u8 = undefined;
    const h = infoHashFromMagnet(
        "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a",
        &out,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("c12fe1c06bba254a9dc9f519b335aa7c1367a88a", h);
}

test "base32 btih: known vector round-trips to hex" {
    // base32("abcdefghijklmnopqrst") == MFRGGZDFMZTWQ2LKNNWG23TPOBYXE43U
    var out: [40]u8 = undefined;
    const h = infoHashFromMagnet(
        "magnet:?xt=urn:btih:MFRGGZDFMZTWQ2LKNNWG23TPOBYXE43U&tr=udp://t.example:80",
        &out,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("6162636465666768696a6b6c6d6e6f7071727374", h);
}

test "base32 btih: lowercase alphabet accepted" {
    var out: [40]u8 = undefined;
    const h = infoHashFromMagnet(
        "magnet:?xt=urn:btih:mfrggzdfmztwq2lknnwg23tpobyxe43u",
        &out,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("6162636465666768696a6b6c6d6e6f7071727374", h);
}

test "magnet with dn/tr params before and after xt" {
    var out: [40]u8 = undefined;
    const h = infoHashFromMagnet(
        "magnet:?dn=Some+Movie+2026&tr=udp://tracker.example:1337&XT=URN:BTIH:C12FE1C06BBA254A9DC9F519B335AA7C1367A88A&tr=udp://t2.example:80",
        &out,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("c12fe1c06bba254a9dc9f519b335aa7c1367a88a", h);
}

test "magnet without btih -> null" {
    var out: [40]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), infoHashFromMagnet("magnet:?dn=hello&tr=udp://x", &out));
    // http detail page (torrent result without a magnet) -> null too.
    try std.testing.expectEqual(@as(?[]const u8, null), infoHashFromMagnet("https://example.org/torrent/12345", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), infoHashFromMagnet("", &out));
}

test "malformed base32 -> null" {
    var out: [40]u8 = undefined;
    // '1' and '0' are not in the RFC 4648 base32 alphabet.
    try std.testing.expectEqual(@as(?[]const u8, null), infoHashFromMagnet(
        "magnet:?xt=urn:btih:MFRGGZDFMZTWQ2LKNNWG23TPOBYX0143",
        &out,
    ));
    // Wrong length (neither 32 nor 40).
    try std.testing.expectEqual(@as(?[]const u8, null), infoHashFromMagnet(
        "magnet:?xt=urn:btih:abcdef",
        &out,
    ));
    // 40 chars but not hex.
    try std.testing.expectEqual(@as(?[]const u8, null), infoHashFromMagnet(
        "magnet:?xt=urn:btih:zzzze1c06bba254a9dc9f519b335aa7c1367a88a",
        &out,
    ));
}

test "URL builders" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://www.virustotal.com/gui/search/c12fe1c06bba254a9dc9f519b335aa7c1367a88a",
        searchUrl("c12fe1c06bba254a9dc9f519b335aa7c1367a88a", &buf),
    );
    var buf2: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://www.virustotal.com/gui/file/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        fileUrl("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &buf2),
    );
}
