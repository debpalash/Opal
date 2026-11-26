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
    "cpl", "scf", "msp", "command",
};

/// Archives can't be streamed and are the classic "password-protected movie"
/// bait when they headline a listing name.
const archive_exts = [_][]const u8{ "rar", "zip", "zipx", "7z", "ace", "arj", "lzh", "cab" };

/// Markers that the name claims to be a video release (quality/codec/source).
const video_markers = [_][]const u8{
    "2160p",    "1080p",  "720p",   "480p",  "4k",   "uhd",    "bluray",
    "blu-ray",  "webrip", "web-dl", "webdl", "hdtv", "dvdrip", "brrip",
    "x264",     "x265",   "h264",   "h265",  "hevc", "cam",    "hdcam",
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
    if (ext.len == 0 or ext.len > 7) return "";
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

/// Worst assessment over every line of a multi-line listing. Stremio addon
/// rows put the release on line 1 and the episode FILE on a later line
/// (Torrentio: "Show S01E03 1080p WEB\nShow.S01E03.MeGusta.exe\n<seeds>"), so
/// a single trailing-extension check on the whole text never saw the `.exe`.
pub fn assessText(text: []const u8, size_bytes: f64) Assessment {
    var worst: Assessment = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const a = assess(std.mem.trim(u8, line, " \t\r"), size_bytes);
        if (@intFromEnum(a.risk) > @intFromEnum(worst.risk)) worst = a;
        if (worst.risk == .block) break;
    }
    return worst;
}

/// Assess a magnet by its `dn=` display name (percent-decoded, `+` as space).
/// A magnet without `dn=` names nothing and passes; the player's file gate
/// (media_ext.torrentFileRefusal) still checks the real file once metadata
/// arrives.
pub fn assessMagnet(url: []const u8) Assessment {
    if (url.len < 8 or !std.ascii.eqlIgnoreCase(url[0..8], "magnet:?")) return .{};
    var params = std.mem.tokenizeScalar(u8, url[8..], '&');
    while (params.next()) |param| {
        if (param.len < 3 or !std.ascii.eqlIgnoreCase(param[0..3], "dn=")) continue;
        var buf: [512]u8 = undefined;
        var n: usize = 0;
        var i: usize = 3;
        while (i < param.len and n < buf.len) : (n += 1) {
            if (param[i] == '%' and i + 2 < param.len) {
                if (std.fmt.parseInt(u8, param[i + 1 .. i + 3], 16)) |b| {
                    buf[n] = b;
                    i += 3;
                    continue;
                } else |_| {}
            }
            buf[n] = if (param[i] == '+') ' ' else param[i];
            i += 1;
        }
        return assess(buf[0..n], 0);
    }
    return .{};
}

/// Whether a search row is dropped before anything can list, rank, auto-play
/// or queue it. Only torrent transports are judged: words like "password" or
/// "keygen" in a YouTube or music title say nothing about a payload. A fake
/// episode used to stay in the list as a disabled "Blocked" row, and episode
/// auto-play could still pick it and stall on the refusal.
pub fn rowRejected(torrent_transport: bool, name: []const u8, url: []const u8, size_bytes: f64) bool {
    if (!torrent_transport) return false;
    if (assessText(name, size_bytes).risk == .block) return true;
    return assessMagnet(url).risk == .block;
}

/// U+202A-202E and U+2066-2069 (see media_ext.hasBidiControl; duplicated
/// because this test module cannot import across src/core).
fn hasBidiControl(name: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < name.len) : (i += 1) {
        if (name[i] != 0xE2) continue;
        if (name[i + 1] == 0x80 and name[i + 2] >= 0xAA and name[i + 2] <= 0xAE) return true;
        if (name[i + 1] == 0x81 and name[i + 2] >= 0xA6 and name[i + 2] <= 0xA9) return true;
    }
    return false;
}

/// `size_bytes` <= 0 means unknown (universal results don't carry it).
pub fn assess(name: []const u8, size_bytes: f64) Assessment {
    // U+202E RIGHT-TO-LEFT OVERRIDE renders "Movie\u{202E}vkm.exe" as
    // "Movie exe.mkv": a filename spoof with no place in a release name.
    if (hasBidiControl(name))
        return .{ .risk = .block, .reason = "bidi control characters hide the real file extension" };
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

test "fake episode with the .exe only on the file line blocks (12 12 12 S01E03 MeGusta.exe)" {
    // The listing reported on 2026-11-20: Torrentio-style row whose release
    // line looks clean and whose file line is the executable.
    const row = "12 12 12 S01E03 Einfach Obergeil 1080p WEB H264-MeGusta\n12 12 12 S01E03 Einfach Obergeil 1080p WEB H264-MeGusta.exe\n\u{1F464} 1 \u{1F4BE} 1.2 GB";
    try std.testing.expectEqual(Risk.ok, assess(row, 0).risk);
    try std.testing.expectEqual(Risk.block, assessText(row, 0).risk);
    try std.testing.expectEqual(Risk.block, assess("12 12 12 S01E03 Einfach Obergeil 1080p WEB H264-MeGusta.exe", 0).risk);
    try std.testing.expectEqual(Risk.ok, assessText("Show S01E03 1080p WEB\nShow.S01E03.1080p.WEB.mkv\n\u{1F464} 368", 0).risk);
}

test "magnet dn= is decoded and assessed" {
    try std.testing.expectEqual(Risk.block, assessMagnet("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Show+S01E03+1080p+WEB+H264-MeGusta.exe&tr=udp%3A%2F%2Fx").risk);
    try std.testing.expectEqual(Risk.block, assessMagnet("magnet:?dn=Movie%202026%201080p.SCR&xt=urn:btih:00").risk);
    try std.testing.expectEqual(Risk.ok, assessMagnet("magnet:?xt=urn:btih:00&dn=Show.S01E03.1080p.WEB.mkv").risk);
    try std.testing.expectEqual(Risk.ok, assessMagnet("magnet:?xt=urn:btih:00").risk);
    try std.testing.expectEqual(Risk.ok, assessMagnet("https://example.org/a.exe").risk);
}

test "right-to-left override spoof blocks" {
    try std.testing.expectEqual(Risk.block, assess("Movie 2026 1080p \u{202E}vkm.exe", 0).risk);
}

test "Nov 2024 Lumma fake-episode carriers block (zipx archive, scr payload)" {
    try std.testing.expectEqual(Risk.block, assess("Show S02E05 1080p WEB H264-GROUP.zipx", 0).risk);
    try std.testing.expectEqual(Risk.block, assess("Show S02E05 1080p WEB.scr", 0).risk);
    try std.testing.expectEqual(Risk.block, assess("Show S02E05 1080p \u{2066}vkm.exe", 0).risk);
}

test "rowRejected drops fake episodes from every torrent transport, never other media" {
    const exe_magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Show.S01E03.1080p.WEB.H264-MeGusta.exe";
    try std.testing.expect(rowRejected(true, "Show S01E03 1080p WEB H264-MeGusta.exe", "https://x.org/t/1", 0));
    try std.testing.expect(rowRejected(true, "Show S01E03 1080p WEB H264-MeGusta", exe_magnet, 0));
    try std.testing.expect(rowRejected(true, "Show S01E03 1080p WEB\nShow.S01E03.MeGusta.exe", "magnet:?xt=urn:btih:00", 0));
    try std.testing.expect(rowRejected(true, "Show S01E03 1080p WEB x264", "magnet:?xt=urn:btih:00", 900 * 1024));
    try std.testing.expect(!rowRejected(true, "Show S01E03 1080p WEB x264-GROUP", "magnet:?xt=urn:btih:00&dn=Show.S01E03.mkv", 0));
    try std.testing.expect(!rowRejected(false, "Password (2019) official trailer", "https://youtube.com/watch?v=x", 0));
}
