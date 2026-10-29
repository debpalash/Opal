//! Normalize YouTube's existing channel protocol into the podcast feed model.
const std = @import("std");
const yt = @import("youtube_innertube_pure.zig");
const music = @import("music_subsonic_pure.zig");
const podcasts = @import("podcasts_pure.zig");
pub fn channelId(url: []const u8) ?[]const u8 {
    if (!podcasts.isYouTubeFeed(url)) return null;
    const at = std.mem.indexOf(u8, url, "channel_id=") orelse return null;
    const rest = url[at + 11 ..];
    const id = rest[0 .. std.mem.indexOfScalar(u8, rest, '&') orelse rest.len];
    return if (yt.isChannelId(id)) id else null;
}
fn escaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}
pub fn channelFeed(a: std.mem.Allocator, json: []const u8, expected_id: []const u8, out: []u8) ?[]const u8 {
    const doc = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return null;
    defer doc.deinit();
    const meta = music.valueField(music.valueField(doc.value, "metadata"), "channelMetadataRenderer");
    const id = music.valueString(music.valueField(meta, "externalId"));
    const title = music.valueString(music.valueField(meta, "title"));
    if (!std.mem.eql(u8, id, expected_id) or title.len == 0) return null;
    var w = std.Io.Writer.fixed(out);
    w.writeAll("<feed xmlns='http://www.w3.org/2005/Atom' xmlns:yt='http://www.youtube.com/xml/schemas/2015'><title>") catch return null;
    escaped(&w, title) catch return null;
    w.writeAll("</title><author><name>") catch return null;
    escaped(&w, title) catch return null;
    w.writeAll("</name></author>") catch return null;
    var seen: [40][11]u8 = undefined;
    var count: usize = 0;
    for ([_]bool{ false, true }) |lockup| {
        var pos: usize = 0;
        while (if (lockup) yt.nextLockupVideo(json, &pos) else yt.nextVideo(json, &pos)) |video| {
            if (count == seen.len) break;
            var duplicate = false;
            for (seen[0..count]) |prior| if (std.mem.eql(u8, &prior, video.id)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            var decoded: [1024]u8 = undefined;
            const n = yt.unescapeJson(video.title_raw, &decoded);
            if (n == 0) continue;
            w.print("<entry><yt:videoId>{s}</yt:videoId><title>", .{video.id}) catch return null;
            escaped(&w, decoded[0..n]) catch return null;
            w.writeAll("</title></entry>") catch return null;
            @memcpy(&seen[count], video.id);
            count += 1;
        }
    }
    if (count == 0) return null;
    w.writeAll("</feed>") catch return null;
    return out[0..w.end];
}
test "YouTube podcast fallback preserves channel and playable episode identities" {
    const id = "UC1234567890123456789012";
    const json =
        \\{"metadata":{"channelMetadataRenderer":{"externalId":"UC1234567890123456789012","title":"Science & Stories"}},"contents":{"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"Space & life"}]}}}}
    ;
    var buf: [4096]u8 = undefined;
    const feed = channelFeed(std.testing.allocator, json, id, &buf).?;
    const show = podcasts.parseFeedShow(feed, "https://www.youtube.com/feeds/videos.xml?channel_id=UC1234567890123456789012").?;
    try std.testing.expectEqualStrings("Science & Stories", show.name[0..show.name_len]);
    var episodes: [2]podcasts.Episode = undefined;
    try std.testing.expectEqual(@as(usize, 1), podcasts.parseRssEpisodes(feed, &episodes));
    try std.testing.expectEqualStrings("Space & life", episodes[0].title[0..episodes[0].title_len]);
    try std.testing.expect(channelFeed(std.testing.allocator, json, "UCotherchannel", &buf) == null);
}
