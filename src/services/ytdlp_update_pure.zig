const std = @import("std");

/// Return the 64-character SHA-256 field for an exact release asset. GNU sums
/// may prefix binary filenames with `*`; no partial/suffix matching is allowed.
pub fn expectedChecksum(sums: []const u8, asset_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len < 66) continue;
        const digest = line[0..64];
        var all_hex = true;
        for (digest) |ch| {
            if (!std.ascii.isHex(ch)) {
                all_hex = false;
                break;
            }
        }
        if (!all_hex) continue;
        var name = std.mem.trimStart(u8, line[64..], " \t");
        if (name.len > 0 and name[0] == '*') name = name[1..];
        if (std.mem.eql(u8, name, asset_name)) return digest;
    }
    return null;
}

pub fn checksumMatches(expected: []const u8, actual: [32]u8) bool {
    if (expected.len != 64) return false;
    const hex = "0123456789abcdef";
    for (actual, 0..) |byte, i| {
        if (std.ascii.toLower(expected[i * 2]) != hex[byte >> 4] or
            std.ascii.toLower(expected[i * 2 + 1]) != hex[byte & 0x0f]) return false;
    }
    return true;
}

pub fn validVersionOutput(output: []const u8) bool {
    const value = std.mem.trim(u8, output, " \t\r\n");
    if (value.len < 6 or value.len > 32) return false;
    for (value) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_' or ch == '+')) return false;
    }
    return true;
}

test "checksum lookup requires the exact asset" {
    const sums =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  yt-dlp\n" ++
        "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB *yt-dlp.exe\r\n";
    try std.testing.expectEqualStrings("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", expectedChecksum(sums, "yt-dlp.exe").?);
    try std.testing.expect(expectedChecksum(sums, "dlp.exe") == null);
}

test "checksum comparison accepts upper case sums" {
    const actual = [_]u8{0xbb} ** 32;
    try std.testing.expect(checksumMatches("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", actual));
    try std.testing.expect(!checksumMatches("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", actual));
}

test "version probe rejects empty or command-like output" {
    try std.testing.expect(validVersionOutput("2026.08.19\n"));
    try std.testing.expect(!validVersionOutput(""));
    try std.testing.expect(!validVersionOutput("2026.08.19 && calc"));
}
