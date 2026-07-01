//! Pure .env-style parser. No I/O — caller hands it the bytes.
//! Kept separate from state.zig so `zig test` can exercise it
//! without pulling the full app graph (dvui, sqlite, mpv, etc).

const std = @import("std");

/// Find value for `key_eq` (which MUST include the trailing `=`,
/// e.g. `"TMDB_API_TOKEN="`) in an env file body. Returns the value
/// slice with surrounding whitespace + optional surrounding quotes
/// stripped, or null if not found or empty.
///
/// Matches only at the start of a line (after `\n`, `\r`, or at offset 0)
/// to avoid a `KEY=` embedded in another key's value.
///
/// `#` at the start of a line starts a comment — that line is skipped.
pub fn findValue(content: []const u8, key_eq: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    while (line_start < content.len) {
        // Find end of current logical line
        var line_end = line_start;
        while (line_end < content.len and content[line_end] != '\n' and content[line_end] != '\r') {
            line_end += 1;
        }
        const line = std.mem.trim(u8, content[line_start..line_end], " \t");

        // Advance to next line marker now so `continue` works cleanly
        var next = line_end;
        while (next < content.len and (content[next] == '\n' or content[next] == '\r')) next += 1;
        defer line_start = next;

        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, key_eq)) continue;

        var val = line[key_eq.len..];
        val = std.mem.trim(u8, val, " \t");
        // Strip inline comment starting with ` #` (space then #)
        if (std.mem.indexOf(u8, val, " #")) |hash_idx| {
            val = std.mem.trim(u8, val[0..hash_idx], " \t");
        }
        // Strip matched surrounding quotes
        if (val.len >= 2) {
            const q = val[0];
            if ((q == '"' or q == '\'') and val[val.len - 1] == q) {
                val = val[1 .. val.len - 1];
            }
        }
        if (val.len == 0) return null;
        return val;
    }
    return null;
}

// ══════════════════════════════════════════════════════════
//  Tests
// ══════════════════════════════════════════════════════════

test "findValue: basic key=value" {
    const body = "TMDB_API_TOKEN=abc123\n";
    const got = findValue(body, "TMDB_API_TOKEN=");
    try std.testing.expectEqualStrings("abc123", got.?);
}

test "findValue: no trailing newline" {
    const body = "TMDB_API_TOKEN=abc123";
    try std.testing.expectEqualStrings("abc123", findValue(body, "TMDB_API_TOKEN=").?);
}

test "findValue: CRLF line endings" {
    const body = "FOO=bar\r\nTMDB_API_TOKEN=xyz\r\n";
    try std.testing.expectEqualStrings("xyz", findValue(body, "TMDB_API_TOKEN=").?);
}

test "findValue: quoted values stripped" {
    try std.testing.expectEqualStrings("hello world", findValue("X=\"hello world\"\n", "X=").?);
    try std.testing.expectEqualStrings("single", findValue("X='single'\n", "X=").?);
}

test "findValue: comment lines skipped" {
    const body = "# TMDB_API_TOKEN=ignored\nTMDB_API_TOKEN=real\n";
    try std.testing.expectEqualStrings("real", findValue(body, "TMDB_API_TOKEN=").?);
}

test "findValue: trailing inline comment stripped" {
    try std.testing.expectEqualStrings("abc", findValue("X=abc # note\n", "X=").?);
}

test "findValue: empty value returns null" {
    try std.testing.expect(findValue("X=\n", "X=") == null);
    try std.testing.expect(findValue("X=   \n", "X=") == null);
}

test "findValue: key not found" {
    try std.testing.expect(findValue("OTHER=v\n", "TMDB_API_TOKEN=") == null);
}

test "findValue: key as substring doesn't match" {
    // "MY_TMDB_API_TOKEN=ignored" should NOT match "TMDB_API_TOKEN="
    const body = "MY_TMDB_API_TOKEN=ignored\n";
    try std.testing.expect(findValue(body, "TMDB_API_TOKEN=") == null);
}

test "findValue: JWT token (Opal .env shape)" {
    // Synthetic v4-shaped token (header.payload.signature) — never a real key.
    const body = "TMDB_API_TOKEN=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJFWEFNUExFIiwic2NvcGVzIjpbImFwaV9yZWFkIl19.FAKE_SIGNATURE_FOR_TESTS_ONLY";
    const got = findValue(body, "TMDB_API_TOKEN=").?;
    try std.testing.expect(std.mem.startsWith(u8, got, "eyJhbGci"));
    try std.testing.expect(std.mem.endsWith(u8, got, "TESTS_ONLY"));
    try std.testing.expect(std.mem.count(u8, got, ".") == 2);
}

test "findValue: multiple keys, first match wins" {
    const body = "A=one\nB=two\nC=three\n";
    try std.testing.expectEqualStrings("one", findValue(body, "A=").?);
    try std.testing.expectEqualStrings("two", findValue(body, "B=").?);
    try std.testing.expectEqualStrings("three", findValue(body, "C=").?);
}
