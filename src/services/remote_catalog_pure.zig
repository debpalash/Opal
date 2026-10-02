//! Immutable web catalog projection; no artwork pointers or provider credentials.
const std = @import("std");
pub const LIMIT = 30;
pub const Row = struct {
    id: i32,
    title: [128]u8,
    title_len: usize,
    imdb: [16]u8,
    imdb_len: usize,
    year: [8]u8,
    year_len: usize,
    media: [8]u8,
    media_len: usize,
    overview: [512]u8,
    overview_len: usize,
    poster: [256]u8,
    poster_len: usize,
    rating: u8,
    pub fn copy(item: anytype) Row {
        return .{ .id = item.id, .title = item.title, .title_len = @min(item.title_len, item.title.len), .imdb = item.imdb_id, .imdb_len = @min(item.imdb_id_len, item.imdb_id.len), .year = item.year, .year_len = @min(item.year_len, item.year.len), .media = item.media_type, .media_len = @min(item.media_type_len, item.media_type.len), .overview = item.overview, .overview_len = @min(item.overview_len, item.overview.len), .poster = item.poster_path, .poster_len = @min(item.poster_path_len, item.poster_path.len), .rating = if (std.math.isFinite(item.rating)) @intFromFloat(std.math.clamp(item.rating * 10.0, 0.0, 100.0)) else 0 };
    }
};
pub fn capacity(count: usize) usize {
    return 512 + count * (6 * (128 + 16 + 8 + 8 + 512 + 256) + 256);
}
pub fn write(w: *std.Io.Writer, rows: []const Row, total: usize, loading: bool, has_key: bool) !void {
    try w.writeAll("{\"items\":[");
    for (rows, 0..) |r, i| {
        if (i != 0) try w.writeByte(',');
        try std.json.Stringify.value(.{ .id = r.id, .title = r.title[0..r.title_len], .imdb = r.imdb[0..r.imdb_len], .year = r.year[0..r.year_len], .rating = r.rating, .type = r.media[0..r.media_len], .overview = r.overview[0..r.overview_len], .poster = r.poster[0..r.poster_len] }, .{}, w);
    }
    try w.print("],\"loading\":{s},\"has_key\":{s},\"total\":{d},\"returned\":{d},\"truncated\":{s}}}", .{ if (loading) "true" else "false", if (has_key) "true" else "false", total, rows.len, if (total > rows.len) "true" else "false" });
}
test "maximum escaped catalog metadata exceeds old buffer and fits bounded projection" {
    const alloc = std.testing.allocator;
    const rows = try alloc.alloc(Row, LIMIT);
    defer alloc.free(rows);
    for (rows) |*r| r.* = .{ .id = 1, .title = @splat(1), .title_len = 128, .imdb = @splat(1), .imdb_len = 16, .year = @splat(1), .year_len = 8, .media = @splat(1), .media_len = 8, .overview = @splat(1), .overview_len = 512, .poster = @splat(1), .poster_len = 256, .rating = 0 };
    const buf = try alloc.alloc(u8, capacity(rows.len));
    defer alloc.free(buf);
    var w = std.Io.Writer.fixed(buf);
    try write(&w, rows, 100, false, false);
    try std.testing.expect(w.end > 32768);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf[0..w.end], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 100), parsed.value.object.get("total").?.integer);
    try std.testing.expectEqual(@as(usize, 30), parsed.value.object.get("items").?.array.items.len);
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
}

fn ratingPercent(value: f32) u8 {
    return if (std.math.isFinite(value)) @intFromFloat(std.math.clamp(value * 10.0, 0.0, 100.0)) else 0;
}
test "nonfinite provider ratings cannot trap or become invalid JSON" {
    try std.testing.expectEqual(@as(u8, 0), ratingPercent(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u8, 0), ratingPercent(std.math.inf(f32)));
    try std.testing.expectEqual(@as(u8, 100), ratingPercent(11));
    try std.testing.expectEqual(@as(u8, 75), ratingPercent(7.5));
}

test "production row projection bounds metadata and sanitizes provider rating" {
    var provider_rating: f32 = std.math.nan(f32);
    std.mem.doNotOptimizeAway(&provider_rating);
    var item = .{
        .id = @as(i32, 42),
        .title = [_]u8{1} ** 128,
        .title_len = @as(usize, 999),
        .imdb_id = [_]u8{1} ** 16,
        .imdb_id_len = @as(usize, 999),
        .year = [_]u8{1} ** 8,
        .year_len = @as(usize, 999),
        .media_type = [_]u8{1} ** 8,
        .media_type_len = @as(usize, 999),
        .overview = [_]u8{1} ** 512,
        .overview_len = @as(usize, 999),
        .poster_path = [_]u8{1} ** 256,
        .poster_path_len = @as(usize, 999),
        .rating = provider_rating,
    };
    var row = Row.copy(item);
    try std.testing.expectEqual(@as(u8, 0), row.rating);
    try std.testing.expectEqual(@as(usize, 512), row.overview_len);
    try std.testing.expectEqual(@as(usize, 128), row.title_len);
    item.rating = std.math.inf(f32);
    try std.testing.expectEqual(@as(u8, 0), Row.copy(item).rating);
    item.rating = -20;
    try std.testing.expectEqual(@as(u8, 0), Row.copy(item).rating);
    item.rating = 20;
    row = Row.copy(item);
    try std.testing.expectEqual(@as(u8, 100), row.rating);
    var buf: [capacity(1)]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write(&writer, &.{row}, 1, false, false);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf[0..writer.end], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 100), parsed.value.object.get("items").?.array.items[0].object.get("rating").?.integer);
}
