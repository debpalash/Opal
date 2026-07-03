//! Pure parsing helpers for keyless subtitle providers — no app-state or I/O,
//! so the logic ships tested (see build.zig test step).

const std = @import("std");

pub const Parsed = struct {
    /// Cleaned free-text query (release tags/year stripped, separators → spaces).
    query: []const u8,
    /// TV episode fields — set when an SxxEyy pattern is found.
    is_tv: bool = false,
    show: []const u8 = "",
    season: u16 = 0,
    episode: u16 = 0,
};

fn isSep(ch: u8) bool {
    return ch == '.' or ch == '_' or ch == ' ' or ch == '-';
}

/// Find `S<dd>E<dd>` (case-insensitive) and return (index, season, episode).
fn findSxxEyy(name: []const u8) ?struct { at: usize, s: u16, e: u16 } {
    var i: usize = 0;
    while (i + 3 < name.len) : (i += 1) {
        if (name[i] != 'S' and name[i] != 's') continue;
        var j = i + 1;
        var s: u32 = 0;
        var sd: usize = 0;
        while (j < name.len and name[j] >= '0' and name[j] <= '9' and sd < 2) : (j += 1) {
            s = s * 10 + (name[j] - '0');
            sd += 1;
        }
        if (sd == 0) continue;
        if (j >= name.len or (name[j] != 'E' and name[j] != 'e')) continue;
        j += 1;
        var e: u32 = 0;
        var ed: usize = 0;
        while (j < name.len and name[j] >= '0' and name[j] <= '9' and ed < 3) : (j += 1) {
            e = e * 10 + (name[j] - '0');
            ed += 1;
        }
        if (ed == 0) continue;
        return .{ .at = i, .s = @intCast(s), .e = @intCast(e) };
    }
    return null;
}

/// Copy `src` into `out`, turning `.`/`_`/`-` separators into spaces and
/// collapsing runs of whitespace. Returns the trimmed slice.
fn normalizeInto(src: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var prev_space = true; // leading — skip leading spaces
    for (src) |ch| {
        const c = if (isSep(ch)) ' ' else ch;
        if (c == ' ') {
            if (prev_space) continue;
            prev_space = true;
        } else prev_space = false;
        if (n >= out.len) break;
        out[n] = c;
        n += 1;
    }
    while (n > 0 and out[n - 1] == ' ') n -= 1; // trim trailing
    return out[0..n];
}

/// Parse a media name (torrent title, filename, or media-title) into a search
/// query plus optional TV episode fields. `query_out` and `show_out` are
/// caller-owned scratch buffers the returned slices point into.
pub fn parse(name_in: []const u8, query_out: []u8, show_out: []u8) Parsed {
    // Drop a trailing file extension (last dot with a short alnum tail).
    var name = name_in;
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        const ext = name[dot + 1 ..];
        if (ext.len >= 2 and ext.len <= 4) {
            var alnum = true;
            for (ext) |c| if (!std.ascii.isAlphanumeric(c)) {
                alnum = false;
                break;
            };
            if (alnum) name = name[0..dot];
        }
    }

    if (findSxxEyy(name)) |m| {
        const show = normalizeInto(name[0..m.at], show_out);
        // Query = "show SxxEyy" so query-based providers still match.
        const q = normalizeInto(name, query_out);
        return .{ .query = q, .is_tv = true, .show = show, .season = m.s, .episode = m.e };
    }

    // Movie: cut at the first release/quality marker so the query stays clean.
    const markers = [_][]const u8{ "1080p", "720p", "2160p", "480p", "bluray", "webrip", "web-dl", "web dl", "hdtv", "dvdrip", "bdrip", "x264", "x265", "hevc", "xvid", "brrip", "proper", "repack", "extended", "remastered", "internal", "limited", "unrated" };
    var cut = name.len;
    var lower_buf: [512]u8 = undefined;
    const ln = @min(name.len, lower_buf.len);
    for (name[0..ln], 0..) |c, k| lower_buf[k] = std.ascii.toLower(c);
    const lower = lower_buf[0..ln];
    for (markers) |mk| {
        if (std.mem.indexOf(u8, lower, mk)) |idx| {
            if (idx < cut) cut = idx;
        }
    }
    const q = normalizeInto(name[0..cut], query_out);
    return .{ .query = q, .is_tv = false };
}

/// Map an ISO-ish language code to the full English name Gestdown expects.
/// Falls back to "English" for anything unmapped.
pub fn langFullName(code: []const u8) []const u8 {
    const pairs = [_]struct { c: []const u8, n: []const u8 }{
        .{ .c = "en", .n = "English" },   .{ .c = "eng", .n = "English" },
        .{ .c = "es", .n = "Spanish" },   .{ .c = "spa", .n = "Spanish" },
        .{ .c = "fr", .n = "French" },    .{ .c = "fre", .n = "French" },
        .{ .c = "de", .n = "German" },    .{ .c = "ger", .n = "German" },
        .{ .c = "it", .n = "Italian" },   .{ .c = "ita", .n = "Italian" },
        .{ .c = "pt", .n = "Portuguese" },.{ .c = "por", .n = "Portuguese" },
        .{ .c = "ru", .n = "Russian" },   .{ .c = "rus", .n = "Russian" },
        .{ .c = "ja", .n = "Japanese" },  .{ .c = "jpn", .n = "Japanese" },
        .{ .c = "ko", .n = "Korean" },    .{ .c = "kor", .n = "Korean" },
    };
    for (pairs) |p| if (std.mem.eql(u8, p.c, code)) return p.n;
    return "English";
}

test "parse extracts TV show/season/episode" {
    var q: [256]u8 = undefined;
    var s: [256]u8 = undefined;
    const p = parse("The.Boys.S01E01.1080p.WEB.H264-NTG.mkv", &q, &s);
    try std.testing.expect(p.is_tv);
    try std.testing.expectEqual(@as(u16, 1), p.season);
    try std.testing.expectEqual(@as(u16, 1), p.episode);
    try std.testing.expectEqualStrings("The Boys", p.show);
}

test "parse cleans a movie query" {
    var q: [256]u8 = undefined;
    var s: [256]u8 = undefined;
    const p = parse("Inception.2010.PROPER.1080p.BluRay.x264-GROUP.mp4", &q, &s);
    try std.testing.expect(!p.is_tv);
    try std.testing.expectEqualStrings("Inception 2010", p.query);
}

test "parse handles lowercase sxxeyy and plain names" {
    var q: [256]u8 = undefined;
    var s: [256]u8 = undefined;
    const p = parse("breaking.bad.s05e14.mkv", &q, &s);
    try std.testing.expect(p.is_tv);
    try std.testing.expectEqual(@as(u16, 5), p.season);
    try std.testing.expectEqual(@as(u16, 14), p.episode);
    try std.testing.expectEqualStrings("breaking bad", p.show);

    const p2 = parse("Some Movie Title", &q, &s);
    try std.testing.expect(!p2.is_tv);
    try std.testing.expectEqualStrings("Some Movie Title", p2.query);
}

test "langFullName maps codes, defaults English" {
    try std.testing.expectEqualStrings("Spanish", langFullName("es"));
    try std.testing.expectEqualStrings("English", langFullName("eng"));
    try std.testing.expectEqualStrings("English", langFullName("xx"));
}
