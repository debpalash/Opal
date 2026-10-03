//! Verified TMDB preview metadata and generation policy; no guessed trailers.
const std = @import("std");

pub const Kind = enum { movie, tv };
pub const Status = enum { idle, loading, ready, unavailable, failed, starting, playing, ended };
pub const Failure = enum { none, no_credentials, no_official_video, transport, invalid_response, playback };
pub const https_arguments = [_][]const u8{ "--proto", "=https", "--proto-redir", "=https", "--fail" };
pub const Metadata = struct {
    catalog_id: i32 = 0,
    trailer_url: [128]u8 = @splat(0),
    trailer_url_len: usize = 0,
    title: [192]u8 = @splat(0),
    title_len: usize = 0,
    backdrop_url: [256]u8 = @splat(0),
    backdrop_url_len: usize = 0,
};

pub const Lifecycle = struct {
    generation: u64 = 0,
    identity: u64 = 0,
    selected: bool = false,

    pub fn select(self: *Lifecycle, identity: u64) u64 {
        self.generation +%= 1;
        self.identity = identity;
        self.selected = true;
        return self.generation;
    }
    pub fn stop(self: *Lifecycle) void {
        if (!self.selected) return;
        self.generation +%= 1;
        self.selected = false;
        self.identity = 0;
    }
    pub fn accepts(self: Lifecycle, generation: u64) bool {
        return self.selected and self.generation == generation;
    }
};

fn string(obj: std.json.Value, key: []const u8) []const u8 {
    if (obj != .object) return "";
    const v = obj.object.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

pub fn validVideoKey(key: []const u8) bool {
    if (key.len != 11) return false;
    for (key) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    return true;
}

fn validImagePath(path: []const u8) bool {
    if (path.len < 2 or path.len > 192 or path[0] != '/' or std.mem.indexOf(u8, path, "..") != null) return false;
    for (path[1..]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    return true;
}

/// An official YouTube Trailer is preferred to an official Teaser. Other sites,
/// arbitrary URLs, featurettes, and unofficial uploads are never playable here.
pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Metadata {
    if (body.len > 256 * 1024) return error.Oversized;
    var doc = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .max_value_len = 256 * 1024 });
    defer doc.deinit();
    if (doc.value != .object) return error.InvalidResponse;
    const id = doc.value.object.get("id") orelse return error.InvalidResponse;
    if (id != .integer or id.integer <= 0) return error.InvalidResponse;
    var result: Metadata = .{};
    result.catalog_id = std.math.cast(i32, id.integer) orelse return error.InvalidResponse;
    const backdrop = string(doc.value, "backdrop_path");
    if (validImagePath(backdrop)) {
        const url = std.fmt.bufPrint(&result.backdrop_url, "https://image.tmdb.org/t/p/w780{s}", .{backdrop}) catch "";
        result.backdrop_url_len = url.len;
    }
    const videos = doc.value.object.get("videos") orelse return error.InvalidResponse;
    if (videos != .object) return error.InvalidResponse;
    const rows = videos.object.get("results") orelse return error.InvalidResponse;
    if (rows != .array) return error.InvalidResponse;
    var best: ?std.json.Value = null;
    var best_rank: u8 = 255;
    for (rows.array.items) |row| {
        if (row != .object) continue;
        const official = row.object.get("official") orelse continue;
        if (official != .bool or !official.bool or !std.mem.eql(u8, string(row, "site"), "YouTube")) continue;
        const key = string(row, "key");
        if (!validVideoKey(key)) continue;
        const ty = string(row, "type");
        const rank: u8 = if (std.mem.eql(u8, ty, "Trailer")) 0 else if (std.mem.eql(u8, ty, "Teaser")) 2 else continue;
        const score = rank + @as(u8, if (std.mem.eql(u8, string(row, "iso_639_1"), "en")) 0 else 1);
        if (best == null or score < best_rank or (score == best_rank and std.mem.order(u8, key, string(best.?, "key")) == .lt)) {
            best = row;
            best_rank = score;
        }
    }
    if (best) |row| {
        const url = try std.fmt.bufPrint(&result.trailer_url, "https://www.youtube.com/watch?v={s}", .{string(row, "key")});
        result.trailer_url_len = url.len;
        const title = string(row, "name");
        // Labels have a fixed row; retain UTF-8 and remove ASCII control bytes.
        var n = @min(title.len, result.title.len);
        while (n > 0 and !std.unicode.utf8ValidateSlice(title[0..n])) n -= 1;
        for (title[0..n], 0..) |ch, i| result.title[i] = if (ch < 32 or ch == 127) ' ' else ch;
        result.title_len = n;
    }
    return result;
}

pub fn parseForId(allocator: std.mem.Allocator, body: []const u8, expected_id: i32) !Metadata {
    const meta = try parse(allocator, body);
    if (expected_id <= 0 or meta.catalog_id != expected_id) return error.InvalidResponse;
    return meta;
}

test "preview selection and close reject late metadata" {
    var life: Lifecycle = .{};
    const a = life.select(1);
    try std.testing.expect(life.accepts(a));
    const b = life.select(2);
    try std.testing.expect(!life.accepts(a));
    try std.testing.expect(life.accepts(b));
    life.stop();
    try std.testing.expect(!life.accepts(b));
    const stopped_generation = life.generation;
    life.stop();
    try std.testing.expectEqual(stopped_generation, life.generation);
}

test "verified preview transport forbids HTTP and insecure redirects" {
    try std.testing.expectEqualStrings("--proto", https_arguments[0]);
    try std.testing.expectEqualStrings("=https", https_arguments[1]);
    try std.testing.expectEqualStrings("--proto-redir", https_arguments[2]);
    try std.testing.expectEqualStrings("=https", https_arguments[3]);
    try std.testing.expectEqualStrings("--fail", https_arguments[4]);
}

test "preview is verified official typed TMDB trailer not arbitrary video" {
    const body =
        \\{"id":42,"backdrop_path":"/actual.jpg","videos":{"results":[
        \\{"site":"YouTube","official":false,"type":"Trailer","key":"aaaaaaaaaaa"},
        \\{"site":"YouTube","official":true,"type":"Featurette","key":"bbbbbbbbbbb"},
        \\{"site":"YouTube","official":true,"type":"Teaser","key":"ccccccccccc"},
        \\{"site":"YouTube","official":true,"type":"Trailer","iso_639_1":"en","name":"Real\ntrailer","key":"ddddddddddd"}]}}
    ;
    const meta = try parse(std.testing.allocator, body);
    try std.testing.expectEqualStrings("https://www.youtube.com/watch?v=ddddddddddd", meta.trailer_url[0..meta.trailer_url_len]);
    try std.testing.expectEqualStrings("Real trailer", meta.title[0..meta.title_len]);
    try std.testing.expectEqualStrings("https://image.tmdb.org/t/p/w780/actual.jpg", meta.backdrop_url[0..meta.backdrop_url_len]);
}

test "preview tie deterministic independent of provider result order" {
    const a = try parse(std.testing.allocator, "{\"id\":1,\"videos\":{\"results\":[{\"official\":true,\"site\":\"YouTube\",\"type\":\"Trailer\",\"key\":\"bbbbbbbbbbb\"},{\"official\":true,\"site\":\"YouTube\",\"type\":\"Trailer\",\"key\":\"aaaaaaaaaaa\"}]}}");
    try std.testing.expect(std.mem.endsWith(u8, a.trailer_url[0..a.trailer_url_len], "aaaaaaaaaaa"));
}

test "preview missing official video preserves real artwork and rejects path injection" {
    const a = try parse(std.testing.allocator, "{\"id\":1,\"backdrop_path\":\"/real.png\",\"videos\":{\"results\":[]}}");
    try std.testing.expectEqual(@as(usize, 0), a.trailer_url_len);
    try std.testing.expect(a.backdrop_url_len > 0);
    const b = try parse(std.testing.allocator, "{\"id\":1,\"backdrop_path\":\"//evil.com/x\",\"videos\":{\"results\":[{\"official\":true,\"site\":\"YouTube\",\"type\":\"Trailer\",\"key\":\"x&v=evil123\"}]}}");
    try std.testing.expectEqual(@as(usize, 0), b.backdrop_url_len);
    try std.testing.expectEqual(@as(usize, 0), b.trailer_url_len);
    try std.testing.expectError(error.InvalidResponse, parse(std.testing.allocator, "{\"status_message\":\"bad key\"}"));
    try std.testing.expectError(error.InvalidResponse, parseForId(std.testing.allocator, "{\"id\":2,\"videos\":{\"results\":[]}}", 1));
}
