//! Pure helpers for music downloads (filename sanitization + yt-dlp argv shape).
const std = @import("std");

/// Sanitize "artist - title" into a filesystem-safe base name (no path
/// separators / reserved chars), collapsed + trimmed, written to `out`. Returns
/// the slice. Never empty (falls back to "track").
pub fn sanitizeName(artist: []const u8, title: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    const put = struct {
        fn c(o: []u8, i: *usize, ch: u8) void {
            if (i.* >= o.len) return;
            // Map path/reserved chars to a space; keep the rest.
            const safe: u8 = switch (ch) {
                '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0, '\n', '\r', '\t' => ' ',
                else => ch,
            };
            // Collapse runs of spaces.
            if (safe == ' ' and (i.* == 0 or o[i.* - 1] == ' ')) return;
            o[i.*] = safe;
            i.* += 1;
        }
    }.c;

    for (artist) |ch| put(out, &n, ch);
    if (artist.len > 0 and title.len > 0) {
        put(out, &n, ' ');
        put(out, &n, '-');
        put(out, &n, ' ');
    }
    for (title) |ch| put(out, &n, ch);

    // Trim a trailing space.
    while (n > 0 and out[n - 1] == ' ') n -= 1;
    if (n == 0) {
        const fallback = "track";
        @memcpy(out[0..fallback.len], fallback);
        return out[0..fallback.len];
    }
    return out[0..n];
}

test "sanitizeName strips path chars + collapses spaces" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Daft Punk - One More Time", sanitizeName("Daft Punk", "One More Time", &b));
    try std.testing.expectEqualStrings("AC DC - T N T", sanitizeName("AC/DC", "T/N/T", &b));
    try std.testing.expectEqualStrings("Song", sanitizeName("", "Song", &b));
    try std.testing.expectEqualStrings("track", sanitizeName("", "", &b));
}
