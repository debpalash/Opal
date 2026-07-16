//! Pure (io-free, state-free) helpers for seconds-accurate, path-keyed resume.
//! watch_history.zig / history.zig / player.zig / main.zig route their resume
//! decisions through these so the tested logic IS the shipped logic.

const std = @import("std");

/// Don't offer to resume anything shorter than this into playback — restarting
/// costs nothing and a sub-30s "resume" reads as a glitch.
pub const MIN_RESUME_SECS: f64 = 30.0;

/// At or past this fraction of the duration the item counts as finished.
pub const FINISHED_FRACTION: f64 = 0.95;

/// True when a seconds-accurate saved position is worth resuming:
/// at least MIN_RESUME_SECS in, and (when the duration is known) not
/// effectively finished. Unknown duration (<= 0) only gates on the floor.
pub fn resumeEligible(position_secs: f64, duration_secs: f64) bool {
    if (!(position_secs >= MIN_RESUME_SECS)) return false; // rejects NaN too
    if (duration_secs > 0 and position_secs >= FINISHED_FRACTION * duration_secs) return false;
    return true;
}

/// How a playback link is keyed in watch_history.
pub const KeyKind = enum {
    local_abs, // absolute filesystem path (or file:// URL) — key by path
    local_rel, // relative filesystem path — resolve to absolute, then key by path
    remote, // stream / torrent / URL — keep the legacy name key
};

/// Classify a playback link for key selection. Anything with a URI scheme
/// (magnet:, http://, ytdl://, ...) is remote; "/..." and "file://..." are
/// local; everything else is a relative local path.
pub fn classifyLink(link: []const u8) KeyKind {
    if (link.len == 0) return .remote;
    if (link[0] == '/') return .local_abs;
    if (std.mem.startsWith(u8, link, "file://")) return .local_abs;
    if (std.mem.startsWith(u8, link, "magnet:")) return .remote;
    if (std.mem.indexOf(u8, link, "://") != null) return .remote;
    return .local_rel;
}

/// Filesystem path for a local link: "/abs/path" as-is, "file:///abs/path"
/// stripped of its scheme. Null for anything that isn't a local file.
pub fn localFsPath(link: []const u8) ?[]const u8 {
    if (link.len == 0) return null;
    if (link[0] == '/') return link;
    if (std.mem.startsWith(u8, link, "file://")) {
        const rest = link["file://".len..];
        if (rest.len > 0 and rest[0] == '/') return rest;
        return null;
    }
    return null;
}

/// Legacy-fallback decision: prefer the path-keyed hit; fall back to the
/// legacy name-keyed hit so pre-migration entries still resume once.
pub fn pickPosition(path_pos: f64, legacy_pos: f64) f64 {
    return if (path_pos > 0) path_pos else legacy_pos;
}

/// Display name for a history entry: local-path names collapse to their
/// basename ("/Users/x/Movies/Foo.mkv" → "Foo.mkv"); everything else as-is.
pub fn displayName(name: []const u8) []const u8 {
    if (name.len == 0 or name[0] != '/') return name;
    const idx = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    if (idx + 1 >= name.len) return name; // trailing slash — keep as-is
    return name[idx + 1 ..];
}

test "resumeEligible: 30s floor and 95% ceiling" {
    try std.testing.expect(resumeEligible(43.0 * 60.0 + 12.0, 7200));
    try std.testing.expect(!resumeEligible(29.9, 7200)); // too early
    try std.testing.expect(resumeEligible(30.0, 7200)); // floor is inclusive
    try std.testing.expect(!resumeEligible(6900, 7200)); // >= 95% → finished
    try std.testing.expect(resumeEligible(6839, 7200)); // just under 95%
    try std.testing.expect(!resumeEligible(0, 7200));
    try std.testing.expect(!resumeEligible(-5, 7200));
    // Unknown duration: only the floor applies.
    try std.testing.expect(resumeEligible(120, 0));
    try std.testing.expect(!resumeEligible(10, 0));
    // NaN position must never be eligible.
    try std.testing.expect(!resumeEligible(std.math.nan(f64), 7200));
}

test "classifyLink: path vs URL key selection" {
    try std.testing.expectEqual(KeyKind.local_abs, classifyLink("/Users/x/movie.mkv"));
    try std.testing.expectEqual(KeyKind.local_abs, classifyLink("file:///Users/x/movie.mkv"));
    try std.testing.expectEqual(KeyKind.local_rel, classifyLink("clips/movie.mkv"));
    try std.testing.expectEqual(KeyKind.remote, classifyLink("magnet:?xt=urn:btih:abc"));
    try std.testing.expectEqual(KeyKind.remote, classifyLink("https://example.com/v.m3u8"));
    try std.testing.expectEqual(KeyKind.remote, classifyLink("ytdl://dQw4w9WgXcQ"));
    try std.testing.expectEqual(KeyKind.remote, classifyLink(""));
}

test "localFsPath strips file:// and passes bare absolute paths" {
    try std.testing.expectEqualStrings("/a/b.mkv", localFsPath("/a/b.mkv").?);
    try std.testing.expectEqualStrings("/a/b.mkv", localFsPath("file:///a/b.mkv").?);
    try std.testing.expect(localFsPath("https://x/y.mp4") == null);
    try std.testing.expect(localFsPath("magnet:?xt=abc") == null);
    try std.testing.expect(localFsPath("") == null);
    try std.testing.expect(localFsPath("file://") == null);
}

test "displayName: basename for local paths, untouched otherwise" {
    try std.testing.expectEqualStrings("Foo.mkv", displayName("/Users/x/Movies/Foo.mkv"));
    try std.testing.expectEqualStrings("Show S01E02", displayName("Show S01E02"));
    try std.testing.expectEqualStrings("https://x/y.mp4", displayName("https://x/y.mp4"));
    try std.testing.expectEqualStrings("/ends/with/", displayName("/ends/with/"));
    try std.testing.expectEqualStrings("", displayName(""));
}

test "pickPosition: path key wins, legacy name key resumes old entries" {
    try std.testing.expectEqual(@as(f64, 123.5), pickPosition(123.5, 42.0));
    try std.testing.expectEqual(@as(f64, 42.0), pickPosition(0, 42.0));
    try std.testing.expectEqual(@as(f64, 0), pickPosition(0, 0));
}
