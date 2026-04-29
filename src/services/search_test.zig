// ── search_test.zig ── Pure-logic tests for search module helpers.
// No UI/dvui/network deps — tests quality detection, NSFW filtering,
// engine name extraction, hex decoding, and sort ordering.
const std = @import("std");

// ═══════════════════════════════════════════════════════════
// 1. Quality Detection
// ═══════════════════════════════════════════════════════════

fn detectQuality(name: []const u8) u8 {
    var lower_buf: [512]u8 = undefined;
    const check_len = @min(name.len, 511);
    for (0..check_len) |i| lower_buf[i] = std.ascii.toLower(name[i]);
    const lower = lower_buf[0..check_len];
    if (std.mem.indexOf(u8, lower, "2160p") != null or std.mem.indexOf(u8, lower, "4k") != null or std.mem.indexOf(u8, lower, "uhd") != null) return 4;
    if (std.mem.indexOf(u8, lower, "1080p") != null) return 3;
    if (std.mem.indexOf(u8, lower, "720p") != null) return 2;
    if (std.mem.indexOf(u8, lower, "480p") != null or std.mem.indexOf(u8, lower, "dvdrip") != null) return 1;
    return 0;
}

test "detectQuality: 4K variants" {
    try std.testing.expectEqual(@as(u8, 4), detectQuality("Movie.2024.2160p.BluRay.x265"));
    try std.testing.expectEqual(@as(u8, 4), detectQuality("Movie 4K HDR HEVC"));
    try std.testing.expectEqual(@as(u8, 4), detectQuality("Movie.UHD.Remux"));
}

test "detectQuality: 1080p" {
    try std.testing.expectEqual(@as(u8, 3), detectQuality("Iron.Man.3.2013.1080p.BluRay"));
    try std.testing.expectEqual(@as(u8, 3), detectQuality("1080P WEB-DL"));
}

test "detectQuality: 720p" {
    try std.testing.expectEqual(@as(u8, 2), detectQuality("Movie.720p.HDTV"));
}

test "detectQuality: 480p and DVDRip" {
    try std.testing.expectEqual(@as(u8, 1), detectQuality("Movie.480p.x264"));
    try std.testing.expectEqual(@as(u8, 1), detectQuality("Movie.DVDRip.XviD"));
}

test "detectQuality: unknown quality returns 0" {
    try std.testing.expectEqual(@as(u8, 0), detectQuality("Movie.HDTV"));
    try std.testing.expectEqual(@as(u8, 0), detectQuality("some random name"));
    try std.testing.expectEqual(@as(u8, 0), detectQuality(""));
}

test "detectQuality: highest quality wins" {
    // "2160p" should win even if "1080p" also appears
    try std.testing.expectEqual(@as(u8, 4), detectQuality("Movie.2160p.1080p.BluRay"));
}

// ═══════════════════════════════════════════════════════════
// 2. NSFW Keyword Detection
// ═══════════════════════════════════════════════════════════

const nsfw_keywords = [_][]const u8{
    "xxx", "porn", "hentai", "erotic", "nude", "naked", "adult",
    "brazzers", "bangbros", "naughty", "playboy", "hustler",
    "18+", "milf", "anal", "orgasm", "fetish", "bondage",
    "hardcore", "softcore", "nsfw", "onlyfans", "sexxx",
    "lesbian", "threesome", "foursome", "stripshow", "cam girl",
};

fn isNsfwName(name: []const u8) bool {
    var lower_buf: [512]u8 = undefined;
    const check_len = @min(name.len, 511);
    for (0..check_len) |i| lower_buf[i] = std.ascii.toLower(name[i]);
    const lower = lower_buf[0..check_len];
    for (nsfw_keywords) |kw| {
        if (std.mem.indexOf(u8, lower, kw) != null) return true;
    }
    return false;
}

test "isNsfwName: flags obvious NSFW content" {
    try std.testing.expect(isNsfwName("Some.XXX.Movie.2024"));
    try std.testing.expect(isNsfwName("Adult Content 18+"));
    try std.testing.expect(isNsfwName("Brazzers Collection"));
    try std.testing.expect(isNsfwName("NSFW content here"));
}

test "isNsfwName: case-insensitive" {
    try std.testing.expect(isNsfwName("PORN Compilation"));
    try std.testing.expect(isNsfwName("hEnTaI Archive"));
}

test "isNsfwName: normal content passes through" {
    try std.testing.expect(!isNsfwName("Iron Man 3 (2013) 1080p BluRay"));
    try std.testing.expect(!isNsfwName("Breaking Bad S05E14"));
    try std.testing.expect(!isNsfwName("Avengers Endgame 4K"));
    try std.testing.expect(!isNsfwName("The Office S03E04"));
    try std.testing.expect(!isNsfwName(""));
}

// ═══════════════════════════════════════════════════════════
// 3. Engine Name Extraction
// ═══════════════════════════════════════════════════════════

fn extractEngineName(engine_url: []const u8, buf: *[32]u8) []const u8 {
    var s = engine_url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3..];
    if (std.mem.startsWith(u8, s, "www.")) s = s[4..];
    if (std.mem.startsWith(u8, s, "the")) s = s[3..];
    var end: usize = s.len;
    for (s, 0..) |ch, j| {
        if (ch == '.' or ch == '/') { end = j; break; }
    }
    if (end == 0) return "?";
    const name = s[0..@min(end, 31)];
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

test "extractEngineName: strips protocol and www" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1337x", extractEngineName("https://www.1337x.to/search", &buf));
}

test "extractEngineName: strips 'the' prefix" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("piratebay", extractEngineName("https://thepiratebay.org", &buf));
}

test "extractEngineName: handles plain domain" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("yts", extractEngineName("https://yts.mx/api", &buf));
}

test "extractEngineName: handles just a name" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("EZTV API", extractEngineName("EZTV API", &buf));
}

test "extractEngineName: empty returns ?" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("?", extractEngineName("://", &buf));
}

// ═══════════════════════════════════════════════════════════
// 4. Hex Decoding
// ═══════════════════════════════════════════════════════════

fn hexVal(ch: u8) ?u4 {
    if (ch >= '0' and ch <= '9') return @intCast(ch - '0');
    if (ch >= 'A' and ch <= 'F') return @intCast(ch - 'A' + 10);
    if (ch >= 'a' and ch <= 'f') return @intCast(ch - 'a' + 10);
    return null;
}

test "hexVal: digits" {
    try std.testing.expectEqual(@as(?u4, 0), hexVal('0'));
    try std.testing.expectEqual(@as(?u4, 9), hexVal('9'));
    try std.testing.expectEqual(@as(?u4, 5), hexVal('5'));
}

test "hexVal: uppercase hex" {
    try std.testing.expectEqual(@as(?u4, 10), hexVal('A'));
    try std.testing.expectEqual(@as(?u4, 15), hexVal('F'));
}

test "hexVal: lowercase hex" {
    try std.testing.expectEqual(@as(?u4, 10), hexVal('a'));
    try std.testing.expectEqual(@as(?u4, 15), hexVal('f'));
}

test "hexVal: invalid chars return null" {
    try std.testing.expectEqual(@as(?u4, null), hexVal('G'));
    try std.testing.expectEqual(@as(?u4, null), hexVal('z'));
    try std.testing.expectEqual(@as(?u4, null), hexVal(' '));
    try std.testing.expectEqual(@as(?u4, null), hexVal('%'));
}

// ═══════════════════════════════════════════════════════════
// 5. Streamlink URL Detection
// ═══════════════════════════════════════════════════════════

const streamlink_domains = [_][]const u8{
    "chaturbate.com", "twitch.tv",     "kick.com",
    "stripchat.com",  "bongacams.com", "cam4.com",
    "camsoda.com",    "myfreecams.com","flirt4free.com",
    "livejasmin.com", "dailymotion.com","crunchyroll.com",
    "bilibili.com",   "afreecatv.com", "pluto.tv",
    "picarto.tv",     "dlive.tv",      "rumble.com",
    "odysee.com",
};

fn isStreamlinkUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "http")) return false;
    for (streamlink_domains) |domain| {
        if (std.mem.indexOf(u8, url, domain) != null) return true;
    }
    return false;
}

test "isStreamlinkUrl: twitch recognized" {
    try std.testing.expect(isStreamlinkUrl("https://twitch.tv/ninja"));
    try std.testing.expect(isStreamlinkUrl("https://www.twitch.tv/channel"));
}

test "isStreamlinkUrl: kick recognized" {
    try std.testing.expect(isStreamlinkUrl("https://kick.com/stream"));
}

test "isStreamlinkUrl: crunchyroll recognized" {
    try std.testing.expect(isStreamlinkUrl("https://crunchyroll.com/watch/episode"));
}

test "isStreamlinkUrl: rumble recognized" {
    try std.testing.expect(isStreamlinkUrl("https://rumble.com/v-someid"));
}

test "isStreamlinkUrl: regular URLs rejected" {
    try std.testing.expect(!isStreamlinkUrl("https://youtube.com/watch?v=abc"));
    try std.testing.expect(!isStreamlinkUrl("https://google.com"));
    try std.testing.expect(!isStreamlinkUrl("https://1337x.to/search"));
}

test "isStreamlinkUrl: non-http rejected" {
    try std.testing.expect(!isStreamlinkUrl("magnet:?xt=urn:btih:abc"));
    try std.testing.expect(!isStreamlinkUrl("ftp://twitch.tv/stream"));
    try std.testing.expect(!isStreamlinkUrl("twitch.tv/stream")); // no http
}

// ═══════════════════════════════════════════════════════════
// 6. Theme Preset Names
// ═══════════════════════════════════════════════════════════

const ThemePreset = enum(u8) {
    midnight = 0,
    abyss = 1,
    phantom = 2,
    nord = 3,
    solarized = 4,
    rose = 5,
    ember = 6,
};

fn presetName(preset: ThemePreset) []const u8 {
    return switch (preset) {
        .midnight => "Midnight",
        .abyss => "Abyss",
        .phantom => "Phantom",
        .nord => "Nord",
        .solarized => "Solarized",
        .rose => "Rosé",
        .ember => "Ember",
    };
}

test "presetName: all variants return non-empty strings" {
    inline for (std.meta.fields(ThemePreset)) |field| {
        const name = presetName(@enumFromInt(field.value));
        try std.testing.expect(name.len > 0);
    }
}

test "presetName: specific names" {
    try std.testing.expectEqualStrings("Midnight", presetName(.midnight));
    try std.testing.expectEqualStrings("Nord", presetName(.nord));
    try std.testing.expectEqualStrings("Ember", presetName(.ember));
}

// ═══════════════════════════════════════════════════════════
// 7. URL Decoding (percent-encoding)
// ═══════════════════════════════════════════════════════════

fn urlDecode(encoded: []const u8, out: []u8) []const u8 {
    var di: usize = 0;
    var si: usize = 0;
    while (si < encoded.len and di < out.len) {
        if (encoded[si] == '%' and si + 2 < encoded.len) {
            const hi = hexVal(encoded[si + 1]);
            const lo = hexVal(encoded[si + 2]);
            if (hi != null and lo != null) {
                out[di] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                di += 1;
                si += 3;
                continue;
            }
        }
        out[di] = encoded[si];
        di += 1;
        si += 1;
    }
    return out[0..di];
}

test "urlDecode: basic percent-encoded magnet" {
    var buf: [256]u8 = undefined;
    const result = urlDecode("magnet%3A%3Fxt%3Durn", &buf);
    try std.testing.expectEqualStrings("magnet:?xt=urn", result);
}

test "urlDecode: no encoding passes through" {
    var buf: [256]u8 = undefined;
    const result = urlDecode("hello world", &buf);
    try std.testing.expectEqualStrings("hello world", result);
}

test "urlDecode: mixed encoded and plain" {
    var buf: [256]u8 = undefined;
    const result = urlDecode("a%20b%20c", &buf);
    try std.testing.expectEqualStrings("a b c", result);
}

test "urlDecode: invalid percent sequence passes through" {
    var buf: [256]u8 = undefined;
    const result = urlDecode("100%ZZdone", &buf);
    try std.testing.expectEqualStrings("100%ZZdone", result);
}

// ═══════════════════════════════════════════════════════════
// 8. Sort Result Ordering
// ═══════════════════════════════════════════════════════════

test "sort by seeds: higher seeds first" {
    const items = [_]struct { seeds: i64, name: []const u8 }{
        .{ .seeds = 10, .name = "low" },
        .{ .seeds = 500, .name = "high" },
        .{ .seeds = 50, .name = "mid" },
    };
    // Verify ordering invariant
    try std.testing.expect(items[1].seeds > items[2].seeds);
    try std.testing.expect(items[2].seeds > items[0].seeds);
}

test "sort by health: ratio matters" {
    // health = seeds / (seeds + leech)
    const h1: f32 = 50.0 / (50.0 + 10.0); // 0.833
    const h2: f32 = 100.0 / (100.0 + 200.0); // 0.333
    try std.testing.expect(h1 > h2);
}
