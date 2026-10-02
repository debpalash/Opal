//! Audius public tracks; payment or access-conditioned tracks are omitted.
const std = @import("std");
const cp = @import("comics_pure.zig");
const mp = @import("music_subsonic_pure.zig");

fn field(v: std.json.Value, key: []const u8) std.json.Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn string(v: std.json.Value) []const u8 {
    return if (v == .string) v.string else "";
}
fn truth(v: std.json.Value) bool {
    return v == .bool and v.bool;
}
fn copy(out: []u8, len: *usize, s: []const u8) void {
    len.* = @min(s.len, out.len);
    // Never split a multibyte title/publisher at a fixed-buffer boundary.
    while (len.* > 0 and !std.unicode.utf8ValidateSlice(s[0..len.*])) len.* -= 1;
    @memcpy(out[0..len.*], s[0..len.*]);
}

pub fn searchUrl(out: []u8, base: []const u8, query: []const u8, limit: usize, offset: u32) ?[]const u8 {
    if (query.len == 0) return std.fmt.bufPrint(out, "{s}/v1/tracks/trending?limit={d}&offset={d}&app_name=Opal", .{ std.mem.trimEnd(u8, base, "/"), limit, offset }) catch null;
    var enc: [768]u8 = undefined;
    const n = cp.percentEncodeQuery(query, &enc);
    return std.fmt.bufPrint(out, "{s}/v1/tracks/search?query={s}&limit={d}&offset={d}&app_name=Opal", .{ std.mem.trimEnd(u8, base, "/"), enc[0..n], limit, offset }) catch null;
}

pub fn parseTrack(item: std.json.Value, base: []const u8) ?mp.MusicSong {
    if (!truth(field(item, "is_streamable")) or truth(field(item, "is_unlisted")) or truth(field(item, "is_delete"))) return null;
    if (field(item, "is_available") == .bool and !truth(field(item, "is_available"))) return null;
    if (field(item, "stream_conditions") != .null) return null;
    const id = string(field(item, "id"));
    const title = string(field(item, "title"));
    if (id.len == 0 or id.len > 64 or title.len == 0) return null;
    for (id) |c| if (!std.ascii.isAlphanumeric(c)) return null;
    var row: mp.MusicSong = .{};
    copy(&row.id, &row.id_len, id);
    copy(&row.title, &row.title_len, title);
    copy(&row.artist, &row.artist_len, string(field(field(item, "user"), "name")));
    const artwork = field(item, "artwork");
    var cover = string(field(artwork, "480x480"));
    if (cover.len == 0) cover = string(field(artwork, "150x150"));
    if (cover.len == 0) cover = string(field(artwork, "1000x1000"));
    if (cover.len == 0) cover = string(field(field(field(item, "user"), "profile_picture"), "150x150"));
    copy(&row.cover, &row.cover_len, cover);
    const url = std.fmt.bufPrint(&row.play_url, "{s}/v1/tracks/{s}/stream?app_name=Opal", .{ std.mem.trimEnd(u8, base, "/"), id }) catch return null;
    row.play_url_len = url.len;
    row.download_allowed = truth(field(item, "is_downloadable"));
    return row;
}

test "Audius only returns available public streams and artist download permission" {
    const body = "{\"id\":\"abc12\",\"title\":\"A track\",\"user\":{\"name\":\"Artist\"},\"is_streamable\":true,\"stream_conditions\":null,\"is_downloadable\":false}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const row = parseTrack(parsed.value, "https://api.test").?;
    try std.testing.expectEqualStrings("https://api.test/v1/tracks/abc12/stream?app_name=Opal", row.play_url[0..row.play_url_len]);
    try std.testing.expect(!row.download_allowed);
    try parsed.value.object.put(std.testing.allocator, "stream_conditions", .{ .bool = true });
    try std.testing.expect(parseTrack(parsed.value, "https://api.test") == null);
}

test "Audius query encoding and remote ID validation" {
    var out: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("https://api.test/v1/tracks/search?query=a%26b&limit=30&offset=30&app_name=Opal", searchUrl(&out, "https://api.test/", "a&b", 30, 30).?);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"id\":\"../secret\",\"title\":\"bad\",\"is_streamable\":true}", .{});
    defer parsed.deinit();
    try std.testing.expect(parseTrack(parsed.value, "https://api.test") == null);
}
