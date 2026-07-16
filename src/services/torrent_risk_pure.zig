//! Scam/malware-torrent heuristics. Pure — no I/O, no allocation.
//!
//! Torrent listings for popular releases attract fakes: a "movie" whose name
//! ends in .exe/.scr, an archive that wants a password, a "1080p BluRay"
//! that is 900 KB. `assess` classifies a listing NAME (plus optional size in
//! bytes when the indexer supplies it) into ok / warn / block. Block means
//! the UI disables play/queue for the row; warn only badges it.

const std = @import("std");

pub const Risk = enum(u2) { ok = 0, warn = 1, block = 2 };

pub const Assessment = struct {
    risk: Risk = .ok,
    /// Static human-readable reason, "" when ok. Shown in the toast/badge.
    reason: []const u8 = "",
};

/// Extensions that are Windows/scripting executables. A torrent named like a
/// video but ending in one of these is malware, full stop.
const exec_exts = [_][]const u8{
    "exe", "scr", "msi", "bat", "cmd", "pif", "vbs", "vbe",
    "js",  "jse", "wsf", "hta", "lnk", "jar", "ps1", "apk",
};

/// Archives can't be streamed and are the classic "password-protected movie"
/// bait when they headline a listing name.
const archive_exts = [_][]const u8{ "rar", "zip", "7z", "ace", "arj", "cab" };

/// Markers that the name claims to be a video release (quality/codec/source).
const video_markers = [_][]const u8{
    "2160p", "1080p",  "720p", "480p", "4k",     "uhd",  "bluray",
    "blu-ray", "webrip", "web-dl", "webdl", "hdtv", "dvdrip", "brrip",
    "x264",  "x265",  "h264", "h265", "hevc",   "cam",  "hdcam",
    "telesync", "hdrip",
};

fn lowered(name: []const u8, buf: []u8) []const u8 {
    const n = @min(name.len, buf.len);
    for (0..n) |i| buf[i] = std.ascii.toLower(name[i]);
    return buf[0..n];
}

/// The extension token at the very end of the name, or "" if none.
/// Trailing whitespace/quotes/brackets are trimmed first so `"Movie.exe"`
/// and `Movie.exe]` still match.
fn trailingExt(lower: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, lower, " \t\"')]}");
    const dot = std.mem.lastIndexOfScalar(u8, trimmed, '.') orelse return "";
    const ext = trimmed[dot + 1 ..];
    if (ext.len == 0 or ext.len > 4) return "";
    for (ext) |ch| if (!std.ascii.isAlphanumeric(ch)) return "";
    return ext;
}

fn extIn(ext: []const u8, list: []const []const u8) bool {
    for (list) |e| if (std.mem.eql(u8, ext, e)) return true;
    return false;
}

fn claimsVideo(lower: []const u8) bool {
    for (video_markers) |m| if (std.mem.indexOf(u8, lower, m) != null) return true;
    return false;
}

/// `size_bytes` <= 0 means unknown (universal results don't carry it).
pub fn assess(name: []const u8, size_bytes: f64) Assessment {
    var lb: [512]u8 = undefined;
    const lower = lowered(name, &lb);
    const ext = trailingExt(lower);
    const video = claimsVideo(lower);

    if (extIn(ext, &exec_exts))
        return .{ .risk = .block, .reason = "executable file posing as media" };

    // "movie.mp4.exe"-style double extension anywhere in the name.
    for (exec_exts) |e| {
        var pat_buf: [8]u8 = undefined;
        const pat = std.fmt.bufPrint(&pat_buf, ".{s} ", .{e}) catch continue;
        if (std.mem.indexOf(u8, lower, pat)) |at| {
            if (at > 0) return .{ .risk = .block, .reason = "executable file posing as media" };
        }
    }

    if (extIn(ext, &archive_exts))
        return .{ .risk = .block, .reason = "archive posing as a video release" };

    if (std.mem.indexOf(u8, lower, "password") != null or
        std.mem.indexOf(u8, lower, "passwd") != null)
        return .{ .risk = .block, .reason = "password-protected bait" };

    if (std.mem.indexOf(u8, lower, "keygen") != null or
        std.mem.indexOf(u8, lower, "activator") != null or
        std.mem.indexOf(u8, lower, "codec pack") != null or
        std.mem.indexOf(u8, lower, "codec-pack") != null)
        return .{ .risk = .block, .reason = "bundled software, not media" };

    // A claimed video release with an implausible payload size.
    if (video and size_bytes > 0) {
        if (size_bytes < 5 * 1024 * 1024)
            return .{ .risk = .block, .reason = "claimed video release smaller than 5 MB" };
        if (size_bytes < 50 * 1024 * 1024)
            return .{ .risk = .warn, .reason = "implausibly small for the claimed quality" };
    }

    if (std.mem.eql(u8, ext, "com"))
        return .{ .risk = .warn, .reason = "name ends in a domain/executable extension" };

    if (std.mem.indexOf(u8, lower, "leaked") != null and !video)
        return .{ .risk = .warn, .reason = "claims a leaked pre-release with no quality info" };

    return .{};
}

test "screenshot scams: exe and scr releases block" {
    try std.testing.expectEqual(Risk.block, assess("The Odyssey 2026 1080p H264-DJT.exe", 0).risk);
    try std.testing.expectEqual(Risk.block, assess("The Odyssey 2026 1080p WEBRip-LAMA.scr", 0).risk);
    try std.testing.expectEqual(Risk.block, assess("Movie 2026 [1080p] [WEBRip].EXE", 0).risk);
}

test "double extension and bracket-trimmed extension block" {
    try std.testing.expectEqual(Risk.block, assess("Movie.2026.mp4.exe torrent", 0).risk);
    try std.testing.expectEqual(Risk.block, assess("Movie 2026 (1080p.exe)", 0).risk);
}

test "archives posing as releases block" {
    try std.testing.expectEqual(Risk.block, assess("The Odyssey 2026 BluRay.rar", 0).risk);
    try std.testing.expectEqual(Risk.block, assess("Movie.2026.1080p.zip", 0).risk);
    try std.testing.expectEqual(Risk.block, assess("Show S01 complete.7z", 0).risk);
}

test "password bait and bundled-software bait block" {
    try std.testing.expectEqual(Risk.block, assess("Movie 2026 1080p [password in file]", 0).risk);
    try std.testing.expectEqual(Risk.block, assess("Movie 2026 + codec pack included", 0).risk);
    try std.testing.expectEqual(Risk.block, assess("Photoshop 2026 keygen", 0).risk);
}

test "size heuristics: tiny claimed-video blocks, small warns, unknown passes" {
    try std.testing.expectEqual(Risk.block, assess("Movie 2026 1080p BluRay x264", 900 * 1024).risk);
    try std.testing.expectEqual(Risk.warn, assess("Movie 2026 1080p BluRay x264", 30 * 1024 * 1024).risk);
    try std.testing.expectEqual(Risk.ok, assess("Movie 2026 1080p BluRay x264", 0).risk);
    try std.testing.expectEqual(Risk.ok, assess("Movie 2026 1080p BluRay x264", 2.1 * 1024 * 1024 * 1024).risk);
    // No video claim → size never triggers (could be an ebook/subtitle pack).
    try std.testing.expectEqual(Risk.ok, assess("Movie 2026 subtitles pack", 900 * 1024).risk);
}

test "leaked with no quality info warns; leaked with real rip info passes" {
    try std.testing.expectEqual(Risk.warn, assess("The Odyssey 2026 Leaked", 0).risk);
    try std.testing.expectEqual(Risk.ok, assess("Movie 2026 leaked WEBRip 1080p x264", 0).risk);
}

test "legit release names pass" {
    try std.testing.expectEqual(Risk.ok, assess("The.Odyssey.2026.1080p.WEB-DL.x264-GROUP", 0).risk);
    try std.testing.expectEqual(Risk.ok, assess("The Odyssey (2026) [2160p] [4K] [WEB] [5.1] [YTS.MX]", 0).risk);
    try std.testing.expectEqual(Risk.ok, assess("Movie 2026 720p HDTV x265-MeGusta [eztv.re]", 0).risk);
    try std.testing.expectEqual(Risk.ok, assess("movie.2026.complete.bluray-group.mkv", 0).risk);
    try std.testing.expectEqual(Risk.ok, assess("Episode.S01E05.1080p.mp4", 0).risk);
    // Non-Latin titles must not trip anything (screenshot rows 7-8).
    try std.testing.expectEqual(Risk.ok, assess("\u{6d41}\u{6d6a}\u{5730}\u{7403} [The Odyssey] (2026)", 0).risk);
}

test "words containing marker substrings do not false-positive" {
    // "js"/"com" only match as the trailing extension token, not mid-word.
    try std.testing.expectEqual(Risk.ok, assess("Jsontown 2026 1080p x264", 0).risk);
    try std.testing.expectEqual(Risk.ok, assess("Community S02 1080p [www.site.com] x264", 0).risk);
    // Trailing bare domain still warns (spam-ish, not provably malware).
    try std.testing.expectEqual(Risk.warn, assess("Movie 2026 1080p www.spamsite.com", 0).risk);
}

test "empty and degenerate names pass" {
    try std.testing.expectEqual(Risk.ok, assess("", 0).risk);
    try std.testing.expectEqual(Risk.ok, assess(".", 0).risk);
    try std.testing.expectEqual(Risk.ok, assess("no extension here", 0).risk);
}
