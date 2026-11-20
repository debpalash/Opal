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
    "exe", "msi", "bat", "cmd", "com", "scr", "ps1", "vbs", "js",
    "jar", "apk", "app", "dmg", "pkg", "deb", "rpm", "run", "bin",
    "sh",  "lnk", "pif", "hta", "wsf", "cpl", "scf", "reg", "vbe", "jse", "msp", "command",
    // Archives (non-playable, and the usual malware carriers).
    "rar", "zip", "7z",  "tar", "gz",  "bz2", "xz",
    "iso", "cab", "ace", "arj", "zipx", "lzh",
};

/// Why the player must not hand this torrent file to mpv, or null when it is
/// playable media. Checked on the FILE actually chosen, whichever path chose
/// it (auto-pick, file picker, footer list, Downloads play, session restore),
/// so a listing that looked clean cannot open "Episode.exe" (2026-11-20).
/// Bidi controls (U+202A-202E, U+2066-2069) reorder how a name is drawn:
/// "Movie\u{202E}vkm.exe" displays as "Movie exe.mkv". No real release needs them.
pub fn hasBidiControl(name: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < name.len) : (i += 1) {
        if (name[i] != 0xE2) continue;
        if (name[i + 1] == 0x80 and name[i + 2] >= 0xAA and name[i + 2] <= 0xAE) return true;
        if (name[i + 1] == 0x81 and name[i + 2] >= 0xA6 and name[i + 2] <= 0xA9) return true;
    }
    return false;
}

const EXECUTABLE = [_][]const u8{
    // Not "com": promo files named like "Downloaded from site.com" would
    // reject legitimate torrents. It stays unplayable via RISKY/isPlayable.
    "exe", "msi", "bat", "cmd", "scr", "ps1", "vbs", "js",  "jar",
    "apk", "app", "dmg", "pkg", "run", "sh",  "lnk", "pif", "hta", "wsf",
    "cpl", "scf", "reg", "vbe", "jse", "msp", "command",
};

/// Executables, installers and scripts (not archives). One of these anywhere
/// in a torrent's file list rejects the WHOLE torrent, as Sonarr/Radarr do at
/// grab time: a fake episode ships the payload beside a decoy video.
pub fn isExecutable(name: []const u8) bool {
    return extIn(name, &EXECUTABLE);
}

pub fn torrentFileRefusal(name: []const u8) ?[]const u8 {
    if (hasBidiControl(name))
        return "Not opened: the file name hides its real extension (possible malware)";
    if (isPlayable(name)) return null;
    if (isExecutableOrArchive(name))
        return "Not opened: this torrent's file is an executable or archive, not media (possible malware)";
    return "Not opened: this torrent's file is not playable media";
}

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

test "torrentFileRefusal: media plays; exe, archives, spoofs and unknown files are refused" {
    try std.testing.expect(torrentFileRefusal("Show.S01E03.1080p.WEB.mkv") == null);
    try std.testing.expect(torrentFileRefusal("album/01 track.flac") == null);
    try std.testing.expect(std.mem.indexOf(u8, torrentFileRefusal("12 12 12 S01E03 Einfach Obergeil 1080p WEB H264-MeGusta.exe").?, "malware") != null);
    try std.testing.expect(std.mem.indexOf(u8, torrentFileRefusal("Movie.2026.1080p.rar").?, "malware") != null);
    try std.testing.expect(std.mem.indexOf(u8, torrentFileRefusal("Movie \u{202E}vkm.exe").?, "hides") != null);
    try std.testing.expect(std.mem.indexOf(u8, torrentFileRefusal("Movie \u{202E}4pm.mkv").?, "hides") != null);
    try std.testing.expect(torrentFileRefusal("readme.txt") != null);
    try std.testing.expect(torrentFileRefusal("noext") != null);
}

test "isExecutable: payloads yes, archives and media no; bidi controls detected" {
    try std.testing.expect(isExecutable("Show.S01E03.1080p.mp4.exe"));
    try std.testing.expect(isExecutable("Codec.SCR"));
    try std.testing.expect(isExecutable("Open Me.command"));
    try std.testing.expect(!isExecutable("Subs.rar"));
    try std.testing.expect(!isExecutable("Show.S01E03.mkv"));
    try std.testing.expect(!isExecutable("Torrent downloaded from site.com"));
    try std.testing.expect(hasBidiControl("Movie \u{202E}vkm.exe"));
    try std.testing.expect(hasBidiControl("a\u{202D}b"));
    try std.testing.expect(hasBidiControl("a\u{2067}b.mkv"));
    try std.testing.expect(!hasBidiControl("\u{6d41}\u{6d6a}\u{5730}\u{7403} 2026 \u{2014} WEB.mkv"));
}
