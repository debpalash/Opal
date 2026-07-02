//! Pure (io-free, dvui-free) helpers for workspace name handling, so the
//! sanitization the UI ships is the sanitization the tests exercise.

const std = @import("std");

/// Sanitize a user-typed workspace name into a filesystem-safe filename stem:
///   • path separators ('/', '\') become '-',
///   • control characters are dropped,
///   • leading dots/dashes/spaces are stripped (no hidden files, no "..-"
///     traversal residue), trailing dots/spaces trimmed,
///   • result capped at out.len.
/// Returns the sanitized slice — empty means the name was unusable.
/// Previously the raw name was interpolated straight into
/// "~/.config/opal/workspaces/{name}.json", so "../foo" silently wrote
/// foo.json OUTSIDE the workspaces dir and "a/b" failed with a generic
/// "Failed to create workspace file".
pub fn sanitizeName(out: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    var started = false;
    for (raw) |ch| {
        if (n >= out.len) break;
        var cc = ch;
        if (cc == '/' or cc == '\\') cc = '-';
        if (cc < 0x20) continue; // control chars (incl. NUL) dropped
        if (!started) {
            if (cc == ' ' or cc == '.' or cc == '-') continue;
            started = true;
        }
        out[n] = cc;
        n += 1;
    }
    while (n > 0 and (out[n - 1] == ' ' or out[n - 1] == '.')) n -= 1;
    return out[0..n];
}

test "sanitizeName neutralizes path traversal and separators" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("etc-passwd", sanitizeName(&buf, "../etc/passwd"));
    try std.testing.expectEqualStrings("a-b", sanitizeName(&buf, "a\\b"));
    try std.testing.expectEqualStrings("evening movies", sanitizeName(&buf, "  evening movies  "));
    try std.testing.expectEqualStrings("hidden", sanitizeName(&buf, ".hidden."));
    // Unusable names collapse to empty (caller shows a specific error).
    try std.testing.expectEqualStrings("", sanitizeName(&buf, "..."));
    try std.testing.expectEqualStrings("", sanitizeName(&buf, "///"));
    try std.testing.expectEqualStrings("", sanitizeName(&buf, ""));
}

test "sanitizeName keeps ordinary names intact" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Movie Night 2", sanitizeName(&buf, "Movie Night 2"));
    try std.testing.expectEqualStrings("anime_q3", sanitizeName(&buf, "anime_q3"));
}
