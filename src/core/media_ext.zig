//! File-extension classification — pure, tested. Governs which files inside a
//! torrent Opal will auto-select and play, and flags executables/archives that
//! must NEVER be auto-opened (a mislabeled or malicious torrent can ship a big
//! `.exe`/`.rar` as its largest file; auto-selecting it fed mpv garbage
//! ("Failed to recognize file format") and, worse, would auto-open a possible
//! malware payload). Used by the player's torrent file-selection.

const std = @import("std");

fn extOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return name[dot + 1 ..];
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

fn extIn(name: []const u8, comptime set: []const []const u8) bool {
    const e = extOf(name);
    if (e.len == 0) return false;
    inline for (set) |s| if (eqIgnoreCase(e, s)) return true;
    return false;
}

const VIDEO = [_][]const u8{ "mkv", "mp4", "avi", "mov", "wmv", "webm", "flv", "m4v", "ts", "m2ts", "mpg", "mpeg", "vob", "ogv", "3gp", "divx", "mts" };
const AUDIO = [_][]const u8{ "mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "wma", "alac", "aiff" };

/// True for a file mpv can actually play (video or audio) — the ONLY files
/// eligible for auto-selection inside a torrent.
pub fn isPlayable(name: []const u8) bool {
    return extIn(name, &VIDEO) or extIn(name, &AUDIO);
}

pub fn isVideo(name: []const u8) bool {
    return extIn(name, &VIDEO);
}

const RISKY = [_][]const u8{
    // Executables / installers / scripts.
    "exe",  "msi", "bat", "cmd", "com", "scr", "ps1", "vbs",  "js",
    "jar",  "apk", "app", "dmg", "pkg", "deb", "rpm", "run",  "bin",
    "sh",   "lnk",
    // Archives (non-playable, and the usual malware carriers).
    "rar",  "zip", "7z",  "tar", "gz",  "bz2", "xz",  "iso",  "cab",
};

/// True for executables, installers, scripts, and archives — files that must
/// never be auto-opened and that warrant a caution to the user.
pub fn isExecutableOrArchive(name: []const u8) bool {
    return extIn(name, &RISKY);
}

test "isPlayable accepts video+audio, rejects the rest" {
    try std.testing.expect(isPlayable("Show.S01E01.1080p.WEB.mkv"));
    try std.testing.expect(isPlayable("movie.MP4"));
    try std.testing.expect(isPlayable("track.flac"));
    try std.testing.expect(isPlayable("clip.webm"));
    try std.testing.expect(!isPlayable("Setup.exe"));
    try std.testing.expect(!isPlayable("pack.rar"));
    try std.testing.expect(!isPlayable("readme.txt"));
    try std.testing.expect(!isPlayable("noext"));
    try std.testing.expect(!isPlayable("cover.jpg"));
}

test "isExecutableOrArchive flags the dangerous set, case-insensitive" {
    try std.testing.expect(isExecutableOrArchive("Virus.EXE"));
    try std.testing.expect(isExecutableOrArchive("keygen.scr"));
    try std.testing.expect(isExecutableOrArchive("Movie.1080p.rar"));
    try std.testing.expect(isExecutableOrArchive("disc.iso"));
    try std.testing.expect(isExecutableOrArchive("install.msi"));
    try std.testing.expect(isExecutableOrArchive("payload.js"));
    try std.testing.expect(!isExecutableOrArchive("Show.mkv"));
    try std.testing.expect(!isExecutableOrArchive("subs.srt"));
}

test "isVideo excludes audio; extensionless is neither" {
    try std.testing.expect(isVideo("a.mkv"));
    try std.testing.expect(!isVideo("a.mp3"));
    try std.testing.expect(!isVideo("a"));
}
