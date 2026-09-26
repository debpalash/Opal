const std = @import("std");
const json = @import("youtube_innertube_pure.zig");

pub const CLIENT_VERSION = "21.26.364";
pub const USER_AGENT = "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip";
pub const PLAYER_URL = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false";

pub fn videoId(url: []const u8) ?[]const u8 {
    var id: []const u8 = "";
    if (std.mem.indexOf(u8, url, "youtu.be/")) |p| {
        const start = p + "youtu.be/".len;
        const tail = url[start..];
        id = tail[0 .. std.mem.indexOfAny(u8, tail, "?&#/") orelse tail.len];
    } else if (std.mem.indexOf(u8, url, "youtube.com/")) |_| {
        const marker = "v=";
        const p = std.mem.indexOf(u8, url, marker) orelse return null;
        const tail = url[p + marker.len ..];
        id = tail[0 .. std.mem.indexOfAny(u8, tail, "?&#/") orelse tail.len];
    } else return null;
    if (id.len != 11) return null;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return null;
    return id;
}

pub fn buildPlayerBody(id: []const u8, out: []u8) ?[]const u8 {
    if (id.len != 11) return null;
    return std.fmt.bufPrint(out, "{{\"context\":{{\"client\":{{\"clientName\":\"ANDROID\",\"clientVersion\":\"{s}\",\"androidSdkVersion\":30,\"userAgent\":\"{s}\",\"osName\":\"Android\",\"osVersion\":\"11\",\"hl\":\"en\",\"timeZone\":\"UTC\",\"utcOffsetMinutes\":0}}}},\"videoId\":\"{s}\",\"playbackContext\":{{\"contentPlaybackContext\":{{\"html5Preference\":\"HTML5_PREF_WANTS\",\"signatureTimestamp\":20717}}}},\"contentCheckOk\":true,\"racyCheckOk\":true}}", .{ CLIENT_VERSION, USER_AGENT, id }) catch null;
}

/// Select the combined A/V rendition. The Android response currently exposes
/// itag 18 as a direct URL; it starts without the expensive JS challenge used
/// by the full adaptive extractor.
pub fn progressiveUrl(response: []const u8, out: []u8) ?[]const u8 {
    const formats = std.mem.indexOf(u8, response, "\"formats\":[") orelse return null;
    const adaptive = std.mem.indexOfPos(u8, response, formats, "\"adaptiveFormats\":[") orelse response.len;
    const raw = json.strValueAfter(response[formats..adaptive], "\"url\":") orelse return null;
    const n = json.unescapeJson(raw, out);
    if (n == 0 or !std.mem.startsWith(u8, out[0..n], "https://")) return null;
    return out[0..n];
}

test "video id accepts canonical and short links" {
    try std.testing.expectEqualStrings("HF5IAJ0x2g0", videoId("https://www.youtube.com/watch?v=HF5IAJ0x2g0&t=4").?);
    try std.testing.expectEqualStrings("HF5IAJ0x2g0", videoId("https://youtu.be/HF5IAJ0x2g0?si=x").?);
    try std.testing.expect(videoId("https://youtube.com/playlist?list=x") == null);
}

test "player body and progressive URL are bounded and decoded" {
    var body_buf: [1024]u8 = undefined;
    const body = buildPlayerBody("HF5IAJ0x2g0", &body_buf).?;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"clientName\":\"ANDROID\"") != null);
    var url_buf: [256]u8 = undefined;
    const response = "{\"streamingData\":{\"formats\":[{\"itag\":18,\"url\":\"https://r.test/v?x=1\\u0026y=2\"}],\"adaptiveFormats\":[{\"url\":\"https://wrong\"}]}}";
    try std.testing.expectEqualStrings("https://r.test/v?x=1&y=2", progressiveUrl(response, &url_buf).?);
}
