const std = @import("std");
const json = @import("youtube_innertube_pure.zig");

pub const CLIENT_VERSION = "21.26.364";
pub const USER_AGENT = "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip";
pub const VR_CLIENT_VERSION = "1.65.10";
pub const VR_USER_AGENT = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
pub const PLAYER_URL = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false";
pub const MAX_URL = 8192;

pub const Stream = struct {
    url: [MAX_URL]u8 = undefined,
    url_len: usize = 0,
    content_length: u64 = 0,
    height: u16 = 0,
    bitrate: u64 = 0,
    codec_rank: u8 = 0,

    pub fn slice(self: *const Stream) []const u8 {
        return self.url[0..self.url_len];
    }
};

pub const Streams = struct {
    title: [256]u8 = undefined,
    title_len: usize = 0,
    progressive: Stream = .{},
    video_720: Stream = .{},
    video_1080: Stream = .{},
    video_2160: Stream = .{},
    audio: Stream = .{},

    pub fn titleSlice(self: *const Streams) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn videoFor(self: *const Streams, quality_idx: usize) ?*const Stream {
        const wanted = switch (quality_idx) {
            0 => &self.video_720,
            1 => &self.video_1080,
            2 => &self.video_2160,
            else => return null,
        };
        if (wanted.url_len > 0) return wanted;
        if (quality_idx >= 2 and self.video_1080.url_len > 0) return &self.video_1080;
        if (quality_idx >= 1 and self.video_720.url_len > 0) return &self.video_720;
        if (self.progressive.url_len > 0) return &self.progressive;
        return null;
    }
};

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

pub fn buildVrPlayerBody(id: []const u8, out: []u8) ?[]const u8 {
    if (id.len != 11) return null;
    return std.fmt.bufPrint(out, "{{\"context\":{{\"client\":{{\"clientName\":\"ANDROID_VR\",\"clientVersion\":\"{s}\",\"androidSdkVersion\":32,\"userAgent\":\"{s}\",\"osName\":\"Android\",\"osVersion\":\"12L\",\"hl\":\"en\",\"timeZone\":\"UTC\",\"utcOffsetMinutes\":0}}}},\"videoId\":\"{s}\",\"playbackContext\":{{\"contentPlaybackContext\":{{\"html5Preference\":\"HTML5_PREF_WANTS\",\"signatureTimestamp\":20717}}}},\"contentCheckOk\":true,\"racyCheckOk\":true}}", .{ VR_CLIENT_VERSION, VR_USER_AGENT, id }) catch null;
}

pub fn visitorData(watch_html: []const u8, out: []u8) ?[]const u8 {
    const raw = json.strValueAfter(watch_html, "\"visitorData\":") orelse
        json.strValueAfter(watch_html, "\"VISITOR_DATA\":") orelse return null;
    if (raw.len > out.len) return null;
    const n = json.unescapeJson(raw, out);
    if (n == 0) return null;
    return out[0..n];
}

fn integer(v: ?std.json.Value) u64 {
    const value = v orelse return 0;
    return switch (value) {
        .integer => |n| if (n > 0) @intCast(n) else 0,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        else => 0,
    };
}

fn copyStream(dst: *Stream, url: []const u8, height: u16, length: u64, bitrate: u64, codec_rank: u8) void {
    if (!std.mem.startsWith(u8, url, "https://") or url.len > dst.url.len) return;
    if (dst.url_len > 0 and (codec_rank < dst.codec_rank or (codec_rank == dst.codec_rank and bitrate <= dst.bitrate))) return;
    @memcpy(dst.url[0..url.len], url);
    dst.url_len = url.len;
    dst.height = height;
    dst.content_length = length;
    dst.bitrate = bitrate;
    dst.codec_rank = codec_rank;
}

fn parseFormats(value: ?std.json.Value, out: *Streams, adaptive: bool) void {
    const formats = value orelse return;
    if (formats != .array) return;
    for (formats.array.items) |format| {
        if (format != .object) continue;
        const obj = format.object;
        const url_v = obj.get("url") orelse continue;
        if (url_v != .string) continue;
        const mime_v = obj.get("mimeType") orelse continue;
        if (mime_v != .string) continue;
        const mime = mime_v.string;
        const bitrate = integer(obj.get("bitrate"));
        const length = integer(obj.get("contentLength"));
        if (!adaptive and std.mem.startsWith(u8, mime, "video/mp4")) {
            copyStream(&out.progressive, url_v.string, @intCast(@min(integer(obj.get("height")), 65535)), length, bitrate, 2);
            continue;
        }
        if (std.mem.startsWith(u8, mime, "audio/mp4")) {
            copyStream(&out.audio, url_v.string, 0, length, bitrate, 2);
            continue;
        }
        const codec_rank: u8 = if (std.mem.startsWith(u8, mime, "video/mp4") and std.mem.indexOf(u8, mime, "avc1") != null)
            2
        else if (std.mem.startsWith(u8, mime, "video/webm") and std.mem.indexOf(u8, mime, "vp9") != null)
            1
        else
            continue;
        const height: u16 = @intCast(@min(integer(obj.get("height")), 65535));
        const dst: *Stream = switch (height) {
            720 => &out.video_720,
            1080 => &out.video_1080,
            2160 => &out.video_2160,
            else => continue,
        };
        copyStream(dst, url_v.string, height, length, bitrate, codec_rank);
    }
}

pub fn parseStreams(allocator: std.mem.Allocator, response: []const u8, out: *Streams) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const streaming = parsed.value.object.get("streamingData") orelse return false;
    if (streaming != .object) return false;
    out.* = .{};
    if (parsed.value.object.get("videoDetails")) |details| if (details == .object) {
        if (details.object.get("title")) |title| if (title == .string) {
            out.title_len = @min(title.string.len, out.title.len);
            @memcpy(out.title[0..out.title_len], title.string[0..out.title_len]);
        };
    };
    parseFormats(streaming.object.get("formats"), out, false);
    parseFormats(streaming.object.get("adaptiveFormats"), out, true);
    return out.progressive.url_len > 0 or
        (out.audio.url_len > 0 and (out.video_720.url_len > 0 or out.video_1080.url_len > 0 or out.video_2160.url_len > 0));
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

test "VR response exposes only real qualities and prefers AVC plus AAC" {
    const response =
        "{\"videoDetails\":{\"title\":\"Test video\"},\"streamingData\":{\"formats\":[{\"url\":\"https://p\",\"mimeType\":\"video/mp4\",\"height\":360,\"contentLength\":\"10\"}]," ++
        "\"adaptiveFormats\":[{\"url\":\"https://v720\",\"mimeType\":\"video/mp4; codecs=\\\"avc1.4d401f\\\"\",\"height\":720,\"contentLength\":\"20\",\"bitrate\":2}," ++
        "{\"url\":\"https://vp9\",\"mimeType\":\"video/webm; codecs=\\\"vp9\\\"\",\"height\":1080,\"contentLength\":\"30\"}," ++
        "{\"url\":\"https://v1080\",\"mimeType\":\"video/mp4; codecs=\\\"avc1.640028\\\"\",\"height\":1080,\"contentLength\":\"40\",\"bitrate\":4}," ++
        "{\"url\":\"https://v2160\",\"mimeType\":\"video/webm; codecs=\\\"vp9\\\"\",\"height\":2160,\"contentLength\":\"50\",\"bitrate\":5}," ++
        "{\"url\":\"https://a\",\"mimeType\":\"audio/mp4; codecs=\\\"mp4a.40.2\\\"\",\"contentLength\":\"5\",\"bitrate\":3}]}}";
    var streams: Streams = .{};
    try std.testing.expect(parseStreams(std.testing.allocator, response, &streams));
    try std.testing.expectEqualStrings("https://v720", streams.video_720.slice());
    try std.testing.expectEqualStrings("https://v1080", streams.video_1080.slice());
    try std.testing.expectEqualStrings("https://a", streams.audio.slice());
    try std.testing.expectEqualStrings("Test video", streams.titleSlice());
    try std.testing.expectEqualStrings("https://v2160", streams.video_2160.slice());
    try std.testing.expectEqual(@as(u64, 40), streams.video_1080.content_length);
}

test "visitor data is decoded from watch HTML" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abc+123=", visitorData("x\"visitorData\":\"abc+123=\"y", &out).?);
}
