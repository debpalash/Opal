const std = @import("std");
const yt = @import("youtube_player_pure.zig");
const Field = @import("wallpapers_pure.zig").Field;
pub const Transport = struct { time: f64 = 0, rate: f64 = 1, volume: f64 = 1, muted: bool = false, paused: bool = false };
pub const Handoff = struct {
    url: Field(128) = .{},
    title: Field(512) = .{},
    user_agent: Field(512) = .{},
    cookies_file: Field(2048) = .{},
    proxy: Field(2048) = .{},
    session: u64 = 0,
    transport: Transport = .{},
    streams: yt.Streams = .{},
    captured: bool = false,
};
fn text(o: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}
fn number(o: std.json.ObjectMap, key: []const u8, fallback: f64) f64 {
    const v = o.get(key) orelse return fallback;
    const n: f64 = switch (v) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        else => return fallback,
    };
    return if (std.math.isFinite(n)) n else fallback;
}
fn boolean(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}
fn hostOf(url: []const u8) []const u8 {
    const uri = std.Uri.parse(url) catch return "";
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return "";
    const host = uri.host orelse return "";
    return switch (host) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
}
fn domain(host: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, expected) or (host.len > expected.len and host[host.len - expected.len - 1] == '.' and std.ascii.eqlIgnoreCase(host[host.len - expected.len ..], expected));
}
fn headers(allocator: std.mem.Allocator, v: ?std.json.Value, ua: []const u8, out: []u8) bool {
    var map = std.json.ObjectMap{};
    defer map.deinit(allocator);
    map.put(allocator, "User-Agent", .{ .string = ua }) catch return false;
    map.put(allocator, "Referer", .{ .string = "https://www.youtube.com/" }) catch return false;
    if (v) |value| if (value == .array) {
        if (value.array.items.len > 32) return false;
        for (value.array.items) |item| {
            if (item != .object) return false;
            const name = text(item.object, "name");
            const field = text(item.object, "value");
            if (name.len == 0 or name.len > 128 or field.len > 2048 or std.mem.indexOfAny(u8, field, "\r\n") != null) return false;
            for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
            if (std.ascii.eqlIgnoreCase(name, "Range") or std.ascii.eqlIgnoreCase(name, "Host") or std.ascii.eqlIgnoreCase(name, "Connection") or std.ascii.eqlIgnoreCase(name, "Content-Length") or std.ascii.eqlIgnoreCase(name, "Accept-Encoding") or std.ascii.eqlIgnoreCase(name, "Proxy-Authorization")) continue;
            const canonical = if (std.ascii.eqlIgnoreCase(name, "User-Agent")) "User-Agent" else if (std.ascii.eqlIgnoreCase(name, "Referer")) "Referer" else name;
            map.put(allocator, canonical, .{ .string = field }) catch return false;
        }
    };
    var writer = std.Io.Writer.fixed(out[0 .. out.len - 1]);
    std.json.Stringify.value(std.json.Value{ .object = map }, .{}, &writer) catch return false;
    out[writer.end] = 0;
    return true;
}
fn stream(allocator: std.mem.Allocator, value: ?std.json.Value, height: u16, ua: []const u8, out: *yt.Stream, fields: []u8) bool {
    const v = value orelse return false;
    if (v != .object) return false;
    const url = text(v.object, "url");
    const mime = text(v.object, "mime");
    if (!domain(hostOf(url), "googlevideo.com") or url.len > yt.MAX_URL - 64 or (!std.mem.startsWith(u8, mime, "video/") and !std.mem.startsWith(u8, mime, "audio/"))) return false;
    const query = std.mem.indexOfScalar(u8, url, '?') orelse return false;
    var w = std.Io.Writer.fixed(&out.url);
    w.writeAll(url[0..query]) catch return false;
    var items = std.mem.splitScalar(u8, url[query + 1 ..], '&');
    var separator: u8 = '?';
    while (items.next()) |item| {
        if (std.mem.startsWith(u8, item, "clen=")) out.content_length = std.fmt.parseInt(u64, item[5..], 10) catch return false;
        if (std.mem.startsWith(u8, item, "sparams=") and std.mem.indexOf(u8, item, "range") != null) return false;
        if (std.mem.startsWith(u8, item, "range=")) continue;
        w.writeByte(separator) catch return false;
        w.writeAll(item) catch return false;
        separator = '&';
    }
    if (out.content_length == 0 or !headers(allocator, v.object.get("headers"), ua, fields)) return false;
    out.url_len = w.end;
    out.height = height;
    out.codec_rank = if (std.mem.indexOf(u8, mime, "webm") != null) 1 else 2;
    return true;
}
pub fn parse(allocator: std.mem.Allocator, json: []const u8, out: *Handoff) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const o = parsed.value.object;
    const url = text(o, "url");
    if (!domain(hostOf(url), "youtube.com")) return false;
    const id = yt.videoId(url) orelse return false;
    out.* = .{};
    var canonical: [128]u8 = undefined;
    out.url.set(std.fmt.bufPrint(&canonical, "https://www.youtube.com/watch?v={s}", .{id}) catch return false);
    const session = o.get("session") orelse return false;
    if (session != .integer or session.integer <= 0) return false;
    out.session = @intCast(session.integer);
    out.streams.native_session = out.session;
    out.title.set(text(o, "title"));
    out.user_agent.set(text(o, "userAgent"));
    out.cookies_file.set(text(o, "cookies_file"));
    out.proxy.set(text(o, "proxy"));
    out.transport = .{ .time = std.math.clamp(number(o, "time", 0), 0, 1e9), .rate = std.math.clamp(number(o, "rate", 1), 0.25, 4), .volume = std.math.clamp(number(o, "volume", 1), 0, 1), .muted = boolean(o, "muted"), .paused = boolean(o, "paused") };
    const height: u16 = @intFromFloat(std.math.clamp(number(o, "height", 720), 1, 4320));
    const idx: usize = if (height > 1080) 2 else if (height > 720) 1 else 0;
    const video = switch (idx) {
        0 => &out.streams.video_720,
        1 => &out.streams.video_1080,
        else => &out.streams.video_2160,
    };
    out.streams.browser_quality = idx;
    const has_video = stream(allocator, o.get("video"), height, out.user_agent.text(), video, &out.streams.video_headers);
    out.captured = has_video and !combined(video.slice()) and stream(allocator, o.get("audio"), 0, out.user_agent.text(), &out.streams.audio, &out.streams.audio_headers);
    // A combined MP4 (itag 18/22) already includes audio.
    if (has_video and combined(video.slice())) {
        out.streams.progressive = video.*;
        video.* = .{};
        out.streams.browser_quality = 0;
        out.captured = true;
    }
    out.streams.title_len = @min(out.title.len, out.streams.title.len);
    @memcpy(out.streams.title[0..out.streams.title_len], out.title.text()[0..out.streams.title_len]);
    return true;
}
fn combined(url: []const u8) bool {
    const query = std.mem.indexOfScalar(u8, url, '?') orelse return false;
    var items = std.mem.splitScalar(u8, url[query + 1 ..], '&');
    while (items.next()) |item| if (std.mem.eql(u8, item, "itag=18") or std.mem.eql(u8, item, "itag=22")) return true;
    return false;
}
pub fn extractorHeaders(allocator: std.mem.Allocator, payload: []const u8, agent: []const u8, streams: *yt.Streams) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    var items = std.array_list.Managed(std.json.Value).init(allocator);
    defer items.deinit();
    var maps = std.array_list.Managed(std.json.ObjectMap).init(allocator);
    defer {
        for (maps.items) |*map| map.deinit(allocator);
        maps.deinit();
    }
    if (parsed.value.object.get("http_headers")) |value| if (value == .object) {
        var iterator = value.object.iterator();
        while (iterator.next()) |item| {
            if (item.value_ptr.* != .string or items.items.len >= 32) return false;
            var pair = std.json.ObjectMap{};
            pair.put(allocator, "name", .{ .string = item.key_ptr.* }) catch {
                pair.deinit(allocator);
                return false;
            };
            pair.put(allocator, "value", item.value_ptr.*) catch {
                pair.deinit(allocator);
                return false;
            };
            maps.append(pair) catch {
                pair.deinit(allocator);
                return false;
            };
            items.append(.{ .object = pair }) catch return false;
        }
    };
    if (!headers(allocator, .{ .array = items }, agent, &streams.video_headers)) return false;
    streams.audio_headers = streams.video_headers;
    return true;
}
test "browser handoff rejects lookalike sites and preserves headers position and range identity" {
    var h: Handoff = undefined;
    try std.testing.expect(!parse(std.testing.allocator, "{\"url\":\"https://youtube.com.evil.test/watch?v=abcdefghijk\",\"session\":1}", &h));
    const payload =
        \\{"url":"https://www.youtube.com/watch?v=abcdefghijk","session":3,"time":91.25,"rate":1.5,"volume":0.4,"muted":true,"height":1080,"userAgent":"browser","video":{"url":"https://r1.googlevideo.com/videoplayback?clen=1024&range=0-99&sig=abc","mime":"video/mp4","headers":[{"name":"Cookie","value":"a=1; b=2"},{"name":"Accept","value":"video/*, */*"}]},"audio":{"url":"https://r2.googlevideo.com/videoplayback?clen=512&sig=xyz","mime":"audio/mp4","headers":[]}}
    ;
    try std.testing.expect(parse(std.testing.allocator, payload, &h));
    try std.testing.expect(h.captured);
    try std.testing.expectEqual(@as(f64, 91.25), h.transport.time);
    try std.testing.expect(h.transport.muted);
    try std.testing.expectEqualStrings("https://r1.googlevideo.com/videoplayback?clen=1024&sig=abc", h.streams.video_1080.slice());
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&h.streams.video_headers, 0), "video/*, */*") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&h.streams.video_headers, 0), "a=1; b=2") != null);
    try std.testing.expect(@sizeOf(Handoff) < 65536);
}
test "browser extraction keeps literal comma headers and rejects line injection" {
    var streams: yt.Streams = .{};
    try std.testing.expect(extractorHeaders(std.testing.allocator, "{\"http_headers\":{\"Accept\":\"video/*, */*\",\"Cookie\":\"a=b; c=d\"}}", "browser", &streams));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&streams.video_headers, 0), "a=b; c=d") != null);
    try std.testing.expect(!extractorHeaders(std.testing.allocator, "{\"http_headers\":{\"Cookie\":\"a=b\\r\\nInjected: yes\"}}", "browser", &streams));
}
test "combined browser media has no second audio and subsecond positions stay explicit" {
    var h: Handoff = undefined;
    try std.testing.expect(parse(std.testing.allocator,
        \\{"url":"https://www.youtube.com/watch?v=abcdefghijk","session":4,"time":0.25,"video":{"url":"https://r1.googlevideo.com/videoplayback?clen=1024&itag=18","mime":"video/mp4","headers":[{"name":"user-agent","value":"actual request agent"}]}}
    , &h));
    try std.testing.expect(h.captured and h.streams.progressive.url_len > 0 and h.streams.audio.url_len == 0);
    try std.testing.expectEqual(@as(f64, 0.25), h.transport.time);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&h.streams.video_headers, 0), "actual request agent") != null);
    try std.testing.expect(!combined("https://r1.googlevideo.com/videoplayback?itag=180"));
}
