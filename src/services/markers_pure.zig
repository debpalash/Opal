//! Media-marker plumbing — pure (no io_global, no globals, unit-testable).
//!
//!   • mediaKey        — identity of a local file version (path+size+mtime)
//!   • parseEpisode    — "Show.S01E02…", "1x02", "Episode 2", "[Grp] Show - 02"
//!   • selectSiblings  — other episodes of the same show/season in a folder
//!   • nextEpisode     — the following episode's file in that folder
//!   • encode/decodePrints — fingerprint cache blobs (little-endian u32)
//!   • categoryFromKind — DB `kind` text → skip category
//!
//! markers.zig routes through these so the tested logic IS the shipped logic.

const std = @import("std");
const anime = @import("anime_skip_pure.zig");

pub const Category = anime.Category;
pub const MAX_PREFIX = 96;

/// "file:<size>:<mtime>:<path>" — a replaced/re-encoded file gets a new key,
/// so stale markers never apply to it. Empty on overflow.
pub fn mediaKey(path: []const u8, size: u64, mtime: i64, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "file:{d}:{d}:{s}", .{ size, mtime, path }) catch "";
}

pub fn categoryFromKind(kind: []const u8) ?Category {
    if (std.mem.eql(u8, kind, "intro")) return .intro;
    if (std.mem.eql(u8, kind, "credits")) return .credits;
    if (std.mem.eql(u8, kind, "recap")) return .recap;
    if (std.mem.eql(u8, kind, "preview")) return .preview;
    return null;
}

pub fn kindName(c: Category) []const u8 {
    return anime.label(c);
}

// ── Episode parsing ──────────────────────────────────────────────────────

pub const EpisodeId = struct {
    prefix: [MAX_PREFIX]u8 = undefined,
    prefix_len: usize = 0,
    season: i32 = -1, // -1 = unknown
    episode: i32 = 0,

    pub fn prefixSlice(self: *const EpisodeId) []const u8 {
        return self.prefix[0..self.prefix_len];
    }

    /// Same show (normalized title prefix) and, when both know it, same season.
    pub fn sameSeason(a: *const EpisodeId, b: *const EpisodeId) bool {
        if (!std.mem.eql(u8, a.prefixSlice(), b.prefixSlice())) return false;
        if (a.season >= 0 and b.season >= 0 and a.season != b.season) return false;
        return true;
    }
};

const video_exts = [_][]const u8{ ".mkv", ".mp4", ".avi", ".m4v", ".webm", ".mov", ".ts", ".wmv", ".mpg", ".mpeg", ".m2ts", ".flv", ".ogv" };

pub fn isVideoName(name: []const u8) bool {
    for (video_exts) |e| {
        if (name.len > e.len and std.ascii.endsWithIgnoreCase(name, e)) return true;
    }
    return false;
}

fn baseName(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[i + 1 ..];
}

fn stripExt(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    if (name.len - dot > 6) return name;
    return name[0..dot];
}

fn readNum(s: []const u8, at: usize, max_digits: usize) ?struct { v: i32, end: usize } {
    var i = at;
    var v: i32 = 0;
    while (i < s.len and i - at < max_digits and std.ascii.isDigit(s[i])) : (i += 1) v = v * 10 + @as(i32, s[i] - '0');
    if (i == at) return null;
    if (i < s.len and std.ascii.isDigit(s[i])) return null; // too many digits
    return .{ .v = v, .end = i };
}

fn boundaryBefore(s: []const u8, i: usize) bool {
    return i == 0 or !std.ascii.isAlphanumeric(s[i - 1]);
}

/// Lowercase, brackets ([Group], (2019)) dropped, separators collapsed.
fn normalizePrefix(raw: []const u8, out: *EpisodeId) void {
    var n: usize = 0;
    var depth: u32 = 0;
    var pending_space = false;
    for (raw) |ch| {
        if (ch == '[' or ch == '(' or ch == '{') {
            depth += 1;
            continue;
        }
        if (ch == ']' or ch == ')' or ch == '}') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth > 0) continue;
        if (std.ascii.isAlphanumeric(ch) or ch >= 0x80) {
            if (pending_space and n > 0 and n < MAX_PREFIX) {
                out.prefix[n] = ' ';
                n += 1;
            }
            pending_space = false;
            if (n < MAX_PREFIX) {
                out.prefix[n] = std.ascii.toLower(ch);
                n += 1;
            }
        } else pending_space = true;
    }
    out.prefix_len = n;
}

/// Parse a file name (or path) into show prefix + season/episode.
pub fn parseEpisode(path: []const u8) ?EpisodeId {
    const name = stripExt(baseName(path));
    var id = EpisodeId{};
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        const ch = std.ascii.toLower(name[i]);
        // S01E02 / s1e2
        if (ch == 's' and boundaryBefore(name, i)) {
            if (readNum(name, i + 1, 2)) |s| {
                if (s.end < name.len and std.ascii.toLower(name[s.end]) == 'e') {
                    if (readNum(name, s.end + 1, 4)) |e| {
                        normalizePrefix(name[0..i], &id);
                        id.season = s.v;
                        id.episode = e.v;
                        return id;
                    }
                }
            }
        }
        // 1x02
        if (std.ascii.isDigit(ch) and boundaryBefore(name, i)) {
            if (readNum(name, i, 2)) |s| {
                if (s.end < name.len and std.ascii.toLower(name[s.end]) == 'x') {
                    if (readNum(name, s.end + 1, 3)) |e| {
                        if (e.end - s.end - 1 >= 2) {
                            normalizePrefix(name[0..i], &id);
                            id.season = s.v;
                            id.episode = e.v;
                            return id;
                        }
                    }
                }
            }
        }
    }
    // "Episode 5" / "Ep05" / "Ep. 5"
    i = 0;
    while (i < name.len) : (i += 1) {
        if (!boundaryBefore(name, i)) continue;
        const rest = name[i..];
        const tag_len: usize = if (rest.len >= 7 and std.ascii.eqlIgnoreCase(rest[0..7], "episode"))
            7
        else if (rest.len >= 2 and std.ascii.eqlIgnoreCase(rest[0..2], "ep"))
            2
        else
            continue;
        var j = i + tag_len;
        while (j < name.len and (name[j] == ' ' or name[j] == '.' or name[j] == '_')) j += 1;
        if (readNum(name, j, 4)) |e| {
            normalizePrefix(name[0..i], &id);
            id.episode = e.v;
            return id;
        }
    }
    // Anime: "[Group] Show - 02 [1080p]" / "Show - 102v2"
    if (std.mem.indexOf(u8, name, " - ")) |_| {
        var it: usize = 0;
        while (std.mem.indexOfPos(u8, name, it, " - ")) |dash| : (it = dash + 3) {
            if (readNum(name, dash + 3, 3)) |e| {
                const after_ok = e.end == name.len or !std.ascii.isAlphabetic(name[e.end]) or
                    (name[e.end] == 'v' and e.end + 1 < name.len and std.ascii.isDigit(name[e.end + 1]));
                if (after_ok and e.end - dash - 3 >= 2) {
                    normalizePrefix(name[0..dash], &id);
                    id.episode = e.v;
                    return id;
                }
            }
        }
    }
    return null;
}

/// Indices into `names` of up to `out.len` other episodes of the same
/// show/season as `target`, nearest episode number first. Only video files
/// whose names parse as episodes count — a folder of unrelated movies never
/// gets fingerprinted against each other.
pub fn selectSiblings(target: []const u8, names: []const []const u8, out: []usize) usize {
    const t = parseEpisode(target) orelse return 0;
    if (t.prefix_len == 0) return 0;
    const tb = baseName(target);
    var n: usize = 0;
    var dist_buf: [64]i32 = undefined;
    for (names, 0..) |nm, idx| {
        if (!isVideoName(nm) or std.mem.eql(u8, baseName(nm), tb)) continue;
        const e = parseEpisode(nm) orelse continue;
        if (!t.sameSeason(&e) or e.episode == t.episode) continue;
        const d: i32 = @intCast(@abs(e.episode - t.episode));
        // Insertion into a bounded, distance-sorted list (ties: earlier ep).
        const key = d * 2 + @as(i32, if (e.episode < t.episode) 0 else 1);
        var pos: usize = n;
        while (pos > 0 and dist_buf[pos - 1] > key) pos -= 1;
        if (pos >= out.len or pos >= dist_buf.len) continue;
        const new_n = @min(n + 1, @min(out.len, dist_buf.len));
        var k = new_n - 1;
        while (k > pos) : (k -= 1) {
            out[k] = out[k - 1];
            dist_buf[k] = dist_buf[k - 1];
        }
        out[pos] = idx;
        dist_buf[pos] = key;
        n = new_n;
    }
    return n;
}

/// Index of the episode right after `target` (smallest higher number in the
/// same show/season), or null.
pub fn nextEpisode(target: []const u8, names: []const []const u8) ?usize {
    const t = parseEpisode(target) orelse return null;
    if (t.prefix_len == 0) return null;
    var best: ?usize = null;
    var best_ep: i32 = std.math.maxInt(i32);
    for (names, 0..) |nm, idx| {
        if (!isVideoName(nm)) continue;
        const e = parseEpisode(nm) orelse continue;
        if (!t.sameSeason(&e) or e.episode <= t.episode) continue;
        if (e.episode < best_ep) {
            best_ep = e.episode;
            best = idx;
        }
    }
    return best;
}

// ── Fingerprint cache blobs ──────────────────────────────────────────────

pub fn encodePrints(prints: []const u32, out: []u8) []const u8 {
    const n = @min(prints.len, out.len / 4);
    for (prints[0..n], 0..) |p, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], p, .little);
    return out[0 .. n * 4];
}

pub fn decodePrints(bytes: []const u8, out: []u32) usize {
    const n = @min(bytes.len / 4, out.len);
    for (0..n) |i| out[i] = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    return n;
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════
const testing = std.testing;

test "mediaKey changes with size and mtime" {
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    try testing.expectEqualStrings("file:10:20:/x/a.mkv", mediaKey("/x/a.mkv", 10, 20, &a));
    try testing.expect(!std.mem.eql(u8, mediaKey("/x/a.mkv", 10, 20, &a), mediaKey("/x/a.mkv", 10, 21, &b)));
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("", mediaKey("/x/a.mkv", 1, 2, &tiny));
}

test "parseEpisode handles common naming schemes" {
    const Case = struct { []const u8, []const u8, i32, i32 };
    const cases = [_]Case{
        .{ "/tv/Show Name/Season 1/Show.Name.S01E02.1080p.WEB.x264-GRP.mkv", "show name", 1, 2 },
        .{ "Show Name - s02e10 - Title.mp4", "show name", 2, 10 },
        .{ "show_name_1x03.avi", "show name", 1, 3 },
        .{ "[SubsGroup] Some Anime - 07 [1080p][ABCD1234].mkv", "some anime", -1, 7 },
        .{ "[SubsGroup] Some Anime - 112v2 (BD).mkv", "some anime", -1, 112 },
        .{ "Documentary Episode 4.mkv", "documentary", -1, 4 },
        .{ "Docu.Ep05.mkv", "docu", -1, 5 },
    };
    for (cases) |c| {
        const e = parseEpisode(c[0]) orelse {
            std.debug.print("no parse: {s}\n", .{c[0]});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(c[1], e.prefixSlice());
        try testing.expectEqual(c[2], e.season);
        try testing.expectEqual(c[3], e.episode);
    }
    try testing.expect(parseEpisode("The.Matrix.1999.1080p.mkv") == null);
    try testing.expect(parseEpisode("2001 A Space Odyssey.mkv") == null);
    try testing.expect(parseEpisode("Movie - 2019.mkv") == null);
}

test "selectSiblings: same show+season, nearest first, videos only, bounded" {
    const names = [_][]const u8{
        "Show.S01E01.mkv", "Show.S01E02.mkv", "Show.S01E03.mkv", "Show.S01E04.mkv",
        "Show.S01E05.mkv", "Show.S02E03.mkv", "Other.S01E02.mkv", "Show.S01E02.srt",
        "notes.txt",
    };
    var out: [3]usize = undefined;
    const n = selectSiblings("/tv/Show.S01E03.mkv", &names, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(usize, 1), out[0]); // E02
    try testing.expectEqual(@as(usize, 3), out[1]); // E04
    try testing.expectEqual(@as(usize, 0), out[2]); // E01
    // A movie folder yields nothing.
    const movies = [_][]const u8{ "Alien.1979.mkv", "Aliens.1986.mkv" };
    try testing.expectEqual(@as(usize, 0), selectSiblings("/m/Alien.1979.mkv", &movies, &out));
}

test "nextEpisode finds the following file" {
    const names = [_][]const u8{ "Show.S01E01.mkv", "Show.S01E04.mkv", "Show.S01E03.mkv", "Show.S02E01.mkv" };
    try testing.expectEqual(@as(?usize, 2), nextEpisode("Show.S01E01.mkv", &names));
    try testing.expectEqual(@as(?usize, 1), nextEpisode("Show.S01E03.mkv", &names));
    try testing.expectEqual(@as(?usize, null), nextEpisode("Show.S01E04.mkv", &names));
}

test "prints blob roundtrip and kind names" {
    const p = [_]u32{ 0, 1, 0xdeadbeef, 0xffffffff };
    var bytes: [16]u8 = undefined;
    const enc = encodePrints(&p, &bytes);
    try testing.expectEqual(@as(usize, 16), enc.len);
    var back: [4]u32 = undefined;
    try testing.expectEqual(@as(usize, 4), decodePrints(enc, &back));
    try testing.expectEqualSlices(u32, &p, &back);
    try testing.expectEqual(@as(?Category, .credits), categoryFromKind(kindName(.credits)));
    try testing.expectEqual(@as(?Category, null), categoryFromKind("filler"));
}
