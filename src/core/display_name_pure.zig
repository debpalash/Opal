//! User-facing names for local media paths and release-style filenames.

const std = @import("std");

/// Basename, remove a short extension, replace separators used as spaces, and
/// collapse whitespace. Returns `raw` if cleanup would produce an empty name.
pub fn clean(out: []u8, raw: []const u8) []const u8 {
    if (out.len == 0) return raw;

    var basename_start: usize = 0;
    for (raw, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') basename_start = i + 1;
    }
    const basename = raw[basename_start..];

    var name_end = basename.len;
    if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| {
        if (basename.len - dot <= 6) name_end = dot;
    }

    var written: usize = 0;
    for (basename[0..name_end]) |ch| {
        if (written >= out.len) break;
        const display_ch: u8 = if (ch == '.' or ch == '_') ' ' else ch;
        if (display_ch == ' ' and (written == 0 or out[written - 1] == ' ')) continue;
        out[written] = display_ch;
        written += 1;
    }
    while (written > 0 and out[written - 1] == ' ') written -= 1;
    return if (written > 0) out[0..written] else raw;
}

test "local paths become readable media titles" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Making music symbol with dust 202608071750",
        clean(&out, "/Users/me/Downloads/Making_music_symbol_with_dust_202608071750.mp4"),
    );
    try std.testing.expectEqualStrings("Dune Part Two", clean(&out, "Dune.Part_Two.mkv"));
    try std.testing.expectEqualStrings("Episode", clean(&out, "C:\\Media\\Episode.webm"));
}
