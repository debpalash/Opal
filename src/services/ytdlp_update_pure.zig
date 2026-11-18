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

/// Attempts allowed for the small SHA2-256SUMS request after the binary staged.
pub const CHECKSUM_FETCH_ATTEMPTS: u8 = 2;

/// Whether to (re)try the checksum request: bounded, and never during shutdown.
pub fn shouldFetchChecksums(attempts_made: u8, quitting: bool) bool {
    return !quitting and attempts_made < CHECKSUM_FETCH_ATTEMPTS;
}

test "checksum request is retried once, never while quitting" {
    try std.testing.expect(shouldFetchChecksums(0, false));
    try std.testing.expect(shouldFetchChecksums(1, false));
    try std.testing.expect(!shouldFetchChecksums(2, false));
    try std.testing.expect(!shouldFetchChecksums(0, true));
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
    const actual = @as([32]u8, @splat(0xbb));
    try std.testing.expect(checksumMatches("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", actual));
    try std.testing.expect(!checksumMatches("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", actual));
}

test "version probe rejects empty or command-like output" {
    try std.testing.expect(validVersionOutput("2026.08.19\n"));
    try std.testing.expect(!validVersionOutput(""));
    try std.testing.expect(!validVersionOutput("2026.08.19 && calc"));
}

test "live SHA2-256SUMS layout: macOS asset resolves, never its .zip sibling" {
    // Captured 2026-11 from github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS
    // (release 2026.10.26; two redirects to release-assets.githubusercontent.com).
    const sums =
        "e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3  yt-dlp\n" ++
        "f5389d3698ecde4ef06f4e6b1ce0294fe9ac1396228c8990b8d3416d6d177a7d  yt-dlp.exe\n" ++
        "767ba9dce7052aa196f8b12652f433d76de128ba168966fa84b6394d5e6c6795  yt-dlp_linux\n" ++
        "20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1  yt-dlp_macos.zip\n" ++
        "0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa  yt-dlp_macos\n";
    try std.testing.expectEqualStrings("0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa", expectedChecksum(sums, "yt-dlp_macos").?);
    try std.testing.expectEqualStrings("e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3", expectedChecksum(sums, "yt-dlp").?);
    try std.testing.expectEqualStrings("f5389d3698ecde4ef06f4e6b1ce0294fe9ac1396228c8990b8d3416d6d177a7d", expectedChecksum(sums, "yt-dlp.exe").?);
}
