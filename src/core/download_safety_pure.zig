//! Download safety policy — pure, tested. Decides which torrents are malware by
//! their FILE LIST (not the listing name), keeps a persistent info-hash
//! blocklist so a fake caught once stays blocked when another source offers
//! it, and formats the OS "downloaded from the internet" marks Opal writes on
//! finished files (macOS quarantine xattr, Windows Mark-of-the-Web).
//!
//! Basis: Sonarr/Radarr TorrentClientBase.ValidateFileNames (block + blocklist
//! a release whose file list holds executables), qBittorrent os.cpp (quarantine
//! / Zone.Identifier on completed files, on by default).

const std = @import("std");
const media_ext = @import("media_ext.zig");

/// A file whose presence rejects the whole torrent: an executable, installer
/// or script, or a name using bidi controls to disguise its extension.
pub fn blocksTorrent(file_name: []const u8) bool {
    return media_ext.isExecutable(file_name) or media_ext.hasBidiControl(file_name);
}

/// What one pass over a torrent's file list learned.
pub const FileFacts = struct {
    executable: bool = false,
    archive: bool = false,
    password_note: bool = false,
};

pub fn noteFile(facts: *FileFacts, file_name: []const u8) void {
    if (blocksTorrent(file_name)) facts.executable = true;
    if (media_ext.isExecutableOrArchive(file_name) and !media_ext.isExecutable(file_name)) facts.archive = true;
    if (containsIgnoreCase(file_name, "password") or containsIgnoreCase(file_name, "passwd")) facts.password_note = true;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Why the torrent is malware, or null. An executable anywhere blocks; so
/// does the "password-protected archive" bait (an archive shipped with a
/// password note — the archive hides its payload from scanners). Archives
/// alone pass: scene releases still ship as RAR sets with a sample video.
pub fn torrentVerdict(facts: FileFacts) ?[]const u8 {
    if (facts.executable) return "contains an executable";
    if (facts.archive and facts.password_note) return "password-protected archive bait";
    return null;
}

/// Lowercase 40-hex info-hash, or null for anything else.
pub fn normalizeHash(raw: []const u8, out: *[40]u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len != 40) return null;
    for (trimmed, 0..) |c, i| {
        if (!std.ascii.isHex(c)) return null;
        out[i] = std.ascii.toLower(c);
    }
    return out[0..];
}

/// Fixed-capacity info-hash set. Oldest entries are evicted when full, so the
/// file can never grow without bound.
pub const Blocklist = struct {
    pub const capacity = 1024;
    hashes: [capacity][40]u8 = undefined,
    count: usize = 0,
    next: usize = 0,

    pub fn contains(self: *const Blocklist, hash: []const u8) bool {
        if (hash.len != 40) return false;
        for (self.hashes[0..self.count]) |*h| if (std.mem.eql(u8, h, hash)) return true;
        return false;
    }

    /// Add a normalized hash; false when it was already present or invalid.
    pub fn add(self: *Blocklist, raw: []const u8) bool {
        var buf: [40]u8 = undefined;
        const hash = normalizeHash(raw, &buf) orelse return false;
        if (self.contains(hash)) return false;
        self.hashes[self.next] = buf;
        self.next = (self.next + 1) % capacity;
        if (self.count < capacity) self.count += 1;
        return true;
    }

    /// One hash per line; blank lines, `#` comments and junk are skipped.
    pub fn parse(self: *Blocklist, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            _ = self.add(t);
        }
    }

    /// Serialize oldest-first into `out`; null when `out` is too small.
    pub fn format(self: *const Blocklist, out: []u8) ?[]const u8 {
        const header = "# Opal: torrents blocked as malware (info-hash per line)\n";
        if (out.len < header.len + self.count * 41) return null;
        @memcpy(out[0..header.len], header);
        var n: usize = header.len;
        const start = if (self.count < capacity) 0 else self.next;
        for (0..self.count) |k| {
            const h = &self.hashes[(start + k) % capacity];
            @memcpy(out[n .. n + 40], h);
            out[n + 40] = '\n';
            n += 41;
        }
        return out[0..n];
    }
};

/// macOS `com.apple.quarantine` value: flags;hex-seconds;agent;. 0081 marks a
/// download that Gatekeeper must check before it can be launched.
pub fn quarantineValue(buf: []u8, now_s: i64) ?[]const u8 {
    const secs: u64 = if (now_s > 0) @intCast(now_s) else 0;
    return std.fmt.bufPrint(buf, "0081;{x:0>8};Opal;", .{secs}) catch null;
}

/// Windows Mark-of-the-Web written to `<file>:Zone.Identifier` (Internet zone).
pub const zone_identifier = "[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=about:internet\r\n";

test "file lists: executables and bidi spoofs block the torrent, media and promo files do not" {
    try std.testing.expect(blocksTorrent("12 12 12 S01E03 Einfach Obergeil 1080p WEB H264-MeGusta.exe"));
    try std.testing.expect(blocksTorrent("Codec Pack/setup.msi"));
    try std.testing.expect(blocksTorrent("Movie \u{202E}vkm.scr"));
    try std.testing.expect(!blocksTorrent("Show.S01E03.1080p.WEB.mkv"));
    try std.testing.expect(!blocksTorrent("Subs/English.srt"));
    try std.testing.expect(!blocksTorrent("Torrent downloaded from site.com"));
    try std.testing.expect(!blocksTorrent("www.YTS.MX.jpg"));
}

test "blocklist normalizes, dedupes, round-trips and evicts the oldest" {
    var list: Blocklist = .{};
    try std.testing.expect(list.add("0123456789ABCDEF0123456789ABCDEF01234567"));
    try std.testing.expect(!list.add("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expect(!list.add("not-a-hash"));
    try std.testing.expect(list.contains("0123456789abcdef0123456789abcdef01234567"));
    var buf: [256]u8 = undefined;
    const text = list.format(&buf).?;
    var again: Blocklist = .{};
    again.parse(text);
    try std.testing.expectEqual(@as(usize, 1), again.count);
    try std.testing.expect(again.contains("0123456789abcdef0123456789abcdef01234567"));

    var full: Blocklist = .{};
    var hex: [40]u8 = undefined;
    for (0..Blocklist.capacity + 1) |i| {
        _ = std.fmt.bufPrint(&hex, "{x:0>40}", .{i}) catch unreachable;
        _ = full.add(&hex);
    }
    try std.testing.expectEqual(@as(usize, Blocklist.capacity), full.count);
    _ = std.fmt.bufPrint(&hex, "{x:0>40}", .{0}) catch unreachable;
    try std.testing.expect(!full.contains(&hex)); // oldest evicted
    _ = std.fmt.bufPrint(&hex, "{x:0>40}", .{Blocklist.capacity}) catch unreachable;
    try std.testing.expect(full.contains(&hex));
}

test "quarantine and Mark-of-the-Web values" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0081;6739a000;Opal;", quarantineValue(&buf, 0x6739a000).?);
    try std.testing.expectEqualStrings("0081;00000000;Opal;", quarantineValue(&buf, -5).?);
    try std.testing.expect(std.mem.indexOf(u8, zone_identifier, "ZoneId=3") != null);
}

test "torrentVerdict: executables and password-archive bait block, scene RAR sets pass" {
    var bait: FileFacts = .{};
    for ([_][]const u8{ "Show.S02E05.1080p.WEB.zipx", "PASSWORD - read me.txt", "sample.mkv" }) |n| noteFile(&bait, n);
    try std.testing.expectEqualStrings("password-protected archive bait", torrentVerdict(bait).?);

    var payload: FileFacts = .{};
    for ([_][]const u8{ "Show.S01E03.mkv", "Show.S01E03.mkv.exe" }) |n| noteFile(&payload, n);
    try std.testing.expectEqualStrings("contains an executable", torrentVerdict(payload).?);

    var scene: FileFacts = .{};
    for ([_][]const u8{ "movie.2026.1080p.bluray-grp.rar", "movie.2026.1080p.bluray-grp.r00", "Sample/sample.mkv", "movie.nfo" }) |n| noteFile(&scene, n);
    try std.testing.expect(torrentVerdict(scene) == null);

    var clean: FileFacts = .{};
    for ([_][]const u8{ "Show.S01E01.mkv", "Show.S01E02.mkv", "Subs/en.srt" }) |n| noteFile(&clean, n);
    try std.testing.expect(torrentVerdict(clean) == null);
}
