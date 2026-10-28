//! YouTube Music WEB_REMIX search. Protocol reference: sigma67/ytmusicapi.
const std = @import("std");
const music = @import("music_subsonic_pure.zig");
const yt = @import("youtube_innertube_pure.zig");
pub const endpoint = "https://music.youtube.com/youtubei/v1/search?prettyPrint=false";
pub const client_version = "1.20241023.01.00";
const field = music.valueField;
const str = music.valueString;

pub fn request(out: []u8, query: []const u8, cursor: []const u8) ?[]const u8 {
    var escaped: [8192]u8 = undefined;
    const n = yt.jsonEscape(if (cursor.len > 0) cursor else query, &escaped) orelse return null;
    const key = if (cursor.len > 0) "continuation" else "query";
    return std.fmt.bufPrint(out, "{{\"context\":{{\"client\":{{\"clientName\":\"WEB_REMIX\",\"clientVersion\":\"{s}\",\"hl\":\"en\"}}}},\"{s}\":\"{s}\",\"params\":\"EgWKAQIIAWoMEA4QChADEAQQCRAF\"}}", .{ client_version, key, escaped[0..n] }) catch null;
}

fn find(value: std.json.Value, key: []const u8, depth: usize) std.json.Value {
    if (depth > 32) return .null;
    switch (value) {
        .object => |obj| {
            if (obj.get(key)) |v| return v;
            for (obj.values()) |v| {
                const found = find(v, key, depth + 1);
                if (found != .null) return found;
            }
        },
        .array => |arr| for (arr.items) |v| {
            const found = find(v, key, depth + 1);
            if (found != .null) return found;
        },
        else => {},
    }
    return .null;
}

pub fn parseRow(value: std.json.Value) ?music.MusicSong {
    const id = str(find(value, "videoId", 0));
    if (!yt.validVideoId(id)) return null;
    const columns = field(value, "flexColumns");
    if (columns != .array or columns.array.items.len == 0) return null;
    const title = str(find(columns.array.items[0], "text", 0));
    // The column's first text is an object containing runs; select its first run.
    const name = if (title.len > 0) title else str(find(find(columns.array.items[0], "runs", 0), "text", 0));
    if (name.len == 0) return null;
    var row: music.MusicSong = .{ .download_allowed = false };
    music.copyValueText(&row.id, &row.id_len, id);
    music.copyValueText(&row.title, &row.title_len, name);
    if (columns.array.items.len > 1) {
        const artist = str(find(find(columns.array.items[1], "runs", 0), "text", 0));
        music.copyValueText(&row.artist, &row.artist_len, artist);
    }
    const url = std.fmt.bufPrint(&row.play_url, "https://www.youtube.com/watch?v={s}", .{id}) catch return null;
    row.play_url_len = url.len;
    const cover = yt.thumbUrl(id, &row.cover) orelse return null;
    row.cover_len = cover.len;
    return row;
}

pub fn collect(value: std.json.Value, out: []music.MusicSong) usize {
    var count: usize = 0;
    walk(value, out, &count, 0);
    return count;
}
fn walk(value: std.json.Value, out: []music.MusicSong, count: *usize, depth: usize) void {
    if (depth > 32 or count.* == out.len) return;
    switch (value) {
        .object => |obj| {
            if (obj.get("musicResponsiveListItemRenderer")) |item| {
                if (parseRow(item)) |row| {
                    for (out[0..count.*]) |existing| if (std.mem.eql(u8, existing.id[0..existing.id_len], row.id[0..row.id_len])) return;
                    out[count.*] = row;
                    count.* += 1;
                }
                return;
            }
            for (obj.values()) |v| walk(v, out, count, depth + 1);
        },
        .array => |arr| for (arr.items) |v| walk(v, out, count, depth + 1),
        else => {},
    }
}
pub fn continuation(value: std.json.Value) []const u8 {
    const next = find(value, "nextContinuationData", 0);
    if (next != .null) return str(field(next, "continuation"));
    return str(field(find(value, "continuationCommand", 0), "token"));
}

test "YouTube Music shelves yield songs, skip albums, and preserve continuation" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"contents":[{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"abcdefghijk"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song"}]}}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Artist"}]}}}]}},{"musicResponsiveListItemRenderer":{"flexColumns":[]}}],"continuations":[{"nextContinuationData":{"continuation":"next-page"}}]}
    , .{});
    defer parsed.deinit();
    var rows: [4]music.MusicSong = undefined;
    try std.testing.expectEqual(@as(usize, 1), collect(parsed.value, &rows));
    try std.testing.expectEqualStrings("Song", rows[0].title[0..rows[0].title_len]);
    try std.testing.expectEqualStrings("Artist", rows[0].artist[0..rows[0].artist_len]);
    try std.testing.expectEqualStrings("next-page", continuation(parsed.value));
    var buf: [10000]u8 = undefined;
    const body = request(&buf, "a\"b", "").?;
    const req = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer req.deinit();
    try std.testing.expectEqualStrings("a\"b", str(field(req.value, "query")));
}
