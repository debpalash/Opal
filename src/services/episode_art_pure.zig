const std = @import("std");

pub const Metadata = struct {
    title: [256]u8 = .{0} ** 256,
    title_len: usize = 0,
    url: [512]u8 = .{0} ** 512,
    url_len: usize = 0,
    runtime_secs: f64 = 0,
};

/// Recover a keyless catalog identity only on an exact numeric identity match,
/// not the first similarly named show returned by search.
pub fn findImdb(allocator: std.mem.Allocator, body: []const u8, id: i32, out: []u8) ![]const u8 {
    const doc = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer doc.deinit();
    if (doc.value != .object) return "";
    const metas = doc.value.object.get("metas") orelse return "";
    if (metas != .array) return "";
    for (metas.array.items) |m| {
        if (m != .object) continue;
        const imdb = m.object.get("imdb_id") orelse m.object.get("id") orelse continue;
        if (imdb != .string or !@import("cinemeta_pure.zig").validImdbId(imdb.string)) continue;
        const tmdb = m.object.get("moviedb_id");
        const same = if (tmdb) |v| (v == .integer and v.integer == id) else false;
        const stable = @import("cinemeta_pure.zig").stableId(imdb.string);
        if (!same and stable != id and -stable != id) continue;
        if (imdb.string.len > out.len) return "";
        @memcpy(out[0..imdb.string.len], imdb.string);
        return out[0..imdb.string.len];
    }
    return "";
}

pub fn parseCinemeta(allocator: std.mem.Allocator, body: []const u8, season: i32, episode: i32) !Metadata {
    const doc = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer doc.deinit();
    if (doc.value != .object) return error.InvalidEpisode;
    const meta = doc.value.object.get("meta") orelse return error.InvalidEpisode;
    if (meta != .object) return error.InvalidEpisode;
    const videos = meta.object.get("videos") orelse return error.InvalidEpisode;
    if (videos != .array) return error.InvalidEpisode;
    for (videos.array.items) |v| {
        if (v != .object) continue;
        const s = v.object.get("season") orelse continue;
        const e = v.object.get("episode") orelse continue;
        if (s != .integer or e != .integer or s.integer != season or e.integer != episode) continue;
        var result: Metadata = .{};
        if (v.object.get("title") orelse v.object.get("name")) |title| if (title == .string) {
            result.title_len = @min(title.string.len, result.title.len);
            @memcpy(result.title[0..result.title_len], title.string[0..result.title_len]);
        };
        if (v.object.get("thumbnail")) |thumb| if (thumb == .string and std.mem.startsWith(u8, thumb.string, "https://")) {
            if (@import("cinemeta_pure.zig").compatiblePosterUrl(thumb.string, &result.url)) |url| result.url_len = url.len;
        };
        return result;
    }
    return error.InvalidEpisode;
}

test "keyless previews use exact catalog and episode identities" {
    const a = std.testing.allocator;
    var id: [16]u8 = undefined;
    const json = "{\"metas\":[{\"id\":\"tt0903747\",\"moviedb_id\":1396}]}";
    try std.testing.expectEqualStrings("tt0903747", try findImdb(a, json, 1396, &id));
    try std.testing.expectEqualStrings("", try findImdb(a, json, 42, &id));
    const m = try parseCinemeta(a, "{\"meta\":{\"videos\":[{\"season\":1,\"episode\":2,\"title\":\"Pilot\",\"thumbnail\":\"https://example.test/still.jpg\"}]}}", 1, 2);
    try std.testing.expectEqualStrings("https://example.test/still.jpg", m.url[0..m.url_len]);
    const named = try parseCinemeta(a, "{\"meta\":{\"videos\":[{\"season\":1,\"episode\":2,\"name\":\"Cat's in the Bag\"}]}}", 1, 2);
    try std.testing.expectEqualStrings("Cat's in the Bag", named.title[0..named.title_len]);
}

/// Exact episode identity is required: never attach another episode's artwork.
pub fn parse(allocator: std.mem.Allocator, body: []const u8, season: i32, episode: i32) !Metadata {
    const doc = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer doc.deinit();
    const root = doc.value;
    if (root != .object) return error.InvalidEpisode;
    const s = root.object.get("season_number") orelse return error.InvalidEpisode;
    const e = root.object.get("episode_number") orelse return error.InvalidEpisode;
    if (s != .integer or e != .integer or s.integer != season or e.integer != episode) return error.InvalidEpisode;
    var result: Metadata = .{};
    if (root.object.get("name")) |v| if (v == .string) {
        result.title_len = @min(v.string.len, result.title.len);
        @memcpy(result.title[0..result.title_len], v.string[0..result.title_len]);
    };
    if (root.object.get("still_path")) |v| if (v == .string and v.string.len > 1 and v.string[0] == '/') {
        const url = try std.fmt.bufPrint(&result.url, "https://image.tmdb.org/t/p/w500{s}", .{v.string});
        result.url_len = url.len;
    };
    if (root.object.get("runtime")) |v| if (v == .integer and v.integer > 0 and v.integer < 1440) {
        result.runtime_secs = @floatFromInt(v.integer * 60);
    };
    return result;
}

test "episode preview metadata validates identity and handles missing artwork" {
    const a = std.testing.allocator;
    const body = "{\"season_number\":2,\"episode_number\":4,\"name\":\"The return\",\"still_path\":\"/still.jpg\",\"runtime\":42}";
    const m = try parse(a, body, 2, 4);
    try std.testing.expectEqualStrings("The return", m.title[0..m.title_len]);
    try std.testing.expectEqualStrings("https://image.tmdb.org/t/p/w500/still.jpg", m.url[0..m.url_len]);
    try std.testing.expectEqual(@as(f64, 2520), m.runtime_secs);
    try std.testing.expectError(error.InvalidEpisode, parse(a, body, 2, 5));
    const missing = try parse(a, "{\"season_number\":0,\"episode_number\":1,\"still_path\":null}", 0, 1);
    try std.testing.expectEqual(@as(usize, 0), missing.url_len);
}
