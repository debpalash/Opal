//! Provider-independent episode metadata and conservative title matching.
const std = @import("std");
pub const capacity = 4096;
pub const EpisodeGrid = struct { columns: usize, rows: usize, width: f32 };
pub fn episodeGrid(available: f32, total: usize) EpisodeGrid {
    const width = @max(1, available);
    const columns: usize = @min(6, @max(1, @as(usize, @intFromFloat((width + 8) / 264))));
    return .{ .columns = columns, .rows = (total + columns - 1) / columns, .width = (width - 8 * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns)) };
}

test "episode grid fits narrow windows and keeps long catalogs in compact rows" {
    for ([_]f32{ 240, 390, 720, 1200, 1920 }) |width| {
        const layout = episodeGrid(width, 1180);
        try std.testing.expect(layout.width > 0);
        try std.testing.expect(layout.width * @as(f32, @floatFromInt(layout.columns)) + 8 * @as(f32, @floatFromInt(layout.columns - 1)) <= width + 0.1);
        try std.testing.expect(layout.rows * layout.columns >= 1180);
    }
    try std.testing.expectEqual(@as(usize, 1), episodeGrid(390, 180).columns);
    try std.testing.expectEqual(@as(usize, 4), episodeGrid(1200, 180).columns);
}
pub const Episode = struct {
    number: usize,
    title: []const u8 = "",
    aired: []const u8 = "",
    score: f32 = 0,
    filler: bool = false,
};
pub fn field(v: std.json.Value, key: []const u8) std.json.Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn string(v: std.json.Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn number(v: std.json.Value) usize {
    return if (v == .integer and v.integer > 0) @intCast(v.integer) else 0;
}
pub fn data(v: std.json.Value) ?[]const std.json.Value {
    const d = field(v, "data");
    return if (d == .array) d.array.items else null;
}
pub fn hasNext(v: std.json.Value) bool {
    const next = field(field(v, "pagination"), "has_next_page");
    return next == .bool and next.bool;
}
pub fn anilistEpisodeCount(root: std.json.Value) ?usize {
    const media = field(field(root, "data"), "Media");
    const next = number(field(field(media, "nextAiringEpisode"), "episode"));
    const total = if (next > 0) next - 1 else number(field(media, "episodes"));
    return if (total > 0) @min(total, capacity) else null;
}
pub fn episode(v: std.json.Value) ?Episode {
    const n = number(field(v, "mal_id"));
    if (n == 0 or n > capacity) return null;
    const score = field(v, "score");
    const filler = field(v, "filler");
    const aired = string(field(v, "aired"));
    return .{ .number = n, .title = string(field(v, "title")), .aired = aired[0..@min(10, aired.len)], .score = switch (score) {
        .float => @floatCast(score.float),
        .integer => @floatFromInt(score.integer),
        else => 0,
    }, .filler = filler == .bool and filler.bool };
}
fn normalized(text: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (text) |ch| {
        if ((std.ascii.isAlphanumeric(ch) or ch >= 128) and n < out.len) {
            out[n] = std.ascii.toLower(ch);
            n += 1;
        }
    }
    return out[0..n];
}
/// Exact normalized aliases avoid choosing a sequel/remake just because it is
/// the first search result. A second query can use the English title alias.
pub fn titleMatches(a: []const u8, b: []const u8) bool {
    var aa: [512]u8 = undefined;
    var bb: [512]u8 = undefined;
    const x = normalized(a, &aa);
    const y = normalized(b, &bb);
    return x.len > 0 and std.mem.eql(u8, x, y);
}
pub fn paheShow(root: std.json.Value, title: []const u8, alias: []const u8) ?std.json.Value {
    for (data(root) orelse return null) |show| {
        const name = string(field(show, "title"));
        if ((titleMatches(title, name) or titleMatches(alias, name)) and string(field(show, "session")).len > 0) return show;
    }
    return null;
}
pub const Release = struct { page: usize, session: ?[]const u8 = null };
pub fn paheRelease(root: std.json.Value, ep: usize, current_page: usize) ?Release {
    const rows = data(root) orelse return null;
    const per_page = number(field(root, "per_page"));
    if (ep == 0 or per_page == 0) return null;
    const page = (ep - 1) / per_page + 1;
    if (page != current_page) return .{ .page = page };
    const offset = (ep - 1) % per_page;
    if (offset >= rows.len) return null;
    const session = string(field(rows[offset], "session"));
    if (session.len == 0) return null;
    return .{ .page = page, .session = session };
}

test "unknown totals still have discoverable episodes and long series exceed 200" {
    const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"pagination":{"has_next_page":true},"data":[{"mal_id":1200,"title":"A \"quoted\" title","aired":"2026-09-20T00:00:00Z","score":4.5,"filler":true}]}
    , .{});
    defer doc.deinit();
    const ep = episode(data(doc.value).?[0]).?;
    try std.testing.expectEqual(@as(usize, 1200), ep.number);
    try std.testing.expectEqualStrings("2026-09-20", ep.aired);
    try std.testing.expect(ep.filler);
    try std.testing.expect(hasNext(doc.value));
}
test "failed episode responses are distinct from authoritative empty lists" {
    const bad = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"status\":429,\"message\":\"Rate limited\"}", .{});
    defer bad.deinit();
    try std.testing.expect(data(bad.value) == null);
    const empty = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"data\":[]}", .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), data(empty.value).?.len);
}
test "AniList fallback uses aired episode count for ongoing shows with unknown totals" {
    const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"data":{"Media":{"episodes":null,"nextAiringEpisode":{"episode":1156}}}}
    , .{});
    defer doc.deinit();
    try std.testing.expectEqual(@as(?usize, 1155), anilistEpisodeCount(doc.value));
    try std.testing.expect(anilistEpisodeCount(.null) == null);
}
test "AnimePahe matches title aliases and actual episode sessions" {
    const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"data":[{"title":"Example Season 2","session":"wrong"},{"title":"Example!","session":"show-session"}]}
    , .{});
    defer doc.deinit();
    try std.testing.expectEqualStrings("show-session", string(field(paheShow(doc.value, "Example", "").?, "session")));
    try std.testing.expect(paheShow(doc.value, "Missing", "") == null);
    const eps = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"per_page":2,"data":[{"episode":13,"session":"episode-session"},{"episode":14,"session":"other"}]}
    , .{});
    defer eps.deinit();
    try std.testing.expectEqualStrings("episode-session", paheRelease(eps.value, 1, 1).?.session.?);
    try std.testing.expectEqual(@as(usize, 2), paheRelease(eps.value, 3, 1).?.page);
    try std.testing.expect(paheRelease(eps.value, 0, 1) == null);
}
