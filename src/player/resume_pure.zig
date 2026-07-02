//! Pure (io-free, state-free) helpers for the "resume last played media" launch
//! prompt. main.zig routes the live watch-history entry through these so the
//! tested logic IS the shipped logic.

const std = @import("std");

/// True when a watch-history entry is worth offering to resume: it has a
/// re-openable link and a meaningful mid-playback position (percent is stored on
/// a 0–100 scale; >=0.5 mirrors savePosition's floor, <95 skips good-as-finished).
pub fn isResumable(link_len: usize, percent: f64) bool {
    return link_len > 0 and percent >= 0.5 and percent < 95.0;
}

/// Copy a display title into `out`, turning `.`/`_` separators into spaces and
/// collapsing runs, so a raw filename ("Dutton.Ranch.S01E08...") reads cleanly in
/// the banner. Returns the byte count written (clamped to `out.len`).
pub fn cleanTitle(in: []const u8, out: []u8) usize {
    var n: usize = 0;
    for (in) |ch| {
        if (n >= out.len) break;
        const c: u8 = if (ch == '.' or ch == '_') ' ' else ch;
        if (c == ' ' and (n == 0 or out[n - 1] == ' ')) continue; // collapse / no leading
        out[n] = c;
        n += 1;
    }
    while (n > 0 and out[n - 1] == ' ') n -= 1; // trim trailing
    return n;
}

test "isResumable gates on link + mid-playback percent" {
    try std.testing.expect(isResumable(42, 23.0));
    try std.testing.expect(!isResumable(0, 23.0)); // no link to reopen
    try std.testing.expect(!isResumable(42, 0.0)); // not started
    try std.testing.expect(!isResumable(42, 0.3)); // below savePosition floor
    try std.testing.expect(!isResumable(42, 98.0)); // basically finished
    try std.testing.expect(isResumable(42, 94.999));
}

test "cleanTitle de-dots and collapses" {
    var buf: [64]u8 = undefined;
    const n = cleanTitle("Dutton.Ranch.S01E08.1080p", &buf);
    try std.testing.expectEqualStrings("Dutton Ranch S01E08 1080p", buf[0..n]);
    // Collapses runs and trims, no leading/trailing space.
    const m = cleanTitle("_a__b._", &buf);
    try std.testing.expectEqualStrings("a b", buf[0..m]);
}

/// Guard for the mpv loadfile boundary: reject strings that are never a
/// playable path — empty/whitespace, bare "." / "..", or the filesystem root.
/// (Directories need a stat and are checked at the caller.)
pub fn plausibleMediaPath(path: []const u8) bool {
    const t = std.mem.trim(u8, path, " \t\r\n");
    if (t.len == 0) return false;
    if (std.mem.eql(u8, t, ".") or std.mem.eql(u8, t, "..") or std.mem.eql(u8, t, "/")) return false;
    return true;
}

test "plausibleMediaPath blocks the loadfile('')/directory-walk incident" {
    // mpv logged "Cannot open file ''" then recursively walked ~/Desktop/github
    // after being handed an empty path and a directory. Empty and dot paths
    // must never reach loadfile.
    try std.testing.expect(!plausibleMediaPath(""));
    try std.testing.expect(!plausibleMediaPath("   "));
    try std.testing.expect(!plausibleMediaPath("."));
    try std.testing.expect(!plausibleMediaPath(".."));
    try std.testing.expect(!plausibleMediaPath("/"));
    try std.testing.expect(plausibleMediaPath("/Users/x/movie.mkv"));
    try std.testing.expect(plausibleMediaPath("https://example.com/v.m3u8"));
    try std.testing.expect(plausibleMediaPath("magnet:?xt=urn:btih:abc"));
}
