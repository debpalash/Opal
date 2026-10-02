//! Pointer-free YouTube companion snapshots.
const std = @import("std");
const text = @import("../core/text.zig");
pub const LIMIT = 30;
pub const Snapshot = struct { count: usize, total: usize, loading: bool, request_generation: u32 };
pub const Row = struct {
    video_id: [32]u8,
    video_id_len: usize,
    title: [128]u8,
    title_len: usize,
    uploader: [64]u8,
    uploader_len: usize,
    channel_id: [32]u8,
    channel_id_len: usize,
    thumbnail_url: [512]u8,
    thumbnail_url_len: usize,
    duration: i64,
    views: i64,
    pub fn copy(item: anytype) Row {
        return .{ .video_id = item.video_id, .video_id_len = @min(item.video_id_len, item.video_id.len), .title = item.title, .title_len = @min(item.title_len, item.title.len), .uploader = item.uploader, .uploader_len = @min(item.uploader_len, item.uploader.len), .channel_id = item.channel_id, .channel_id_len = @min(item.channel_id_len, item.channel_id.len), .thumbnail_url = item.thumbnail_url, .thumbnail_url_len = @min(item.thumbnail_url_len, item.thumbnail_url.len), .duration = @max(0, item.duration), .views = @max(0, item.views) };
    }
};
pub fn capacity(count: usize) usize {
    return 512 + count * (6 * (32 + 128 + 64 + 32 + 512) + 256);
}
pub fn write(w: *std.Io.Writer, rows: []const Row, info: Snapshot) !void {
    try w.writeAll("{\"items\":[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try w.writeByte(',');
        try std.json.Stringify.value(.{ .id = text.safeUtf8(row.video_id[0..row.video_id_len]), .title = text.safeUtf8(row.title[0..row.title_len]), .channel = text.safeUtf8(row.uploader[0..row.uploader_len]), .channel_id = text.safeUtf8(row.channel_id[0..row.channel_id_len]), .thumbnail = text.safeUtf8(row.thumbnail_url[0..row.thumbnail_url_len]), .dur_min = @divTrunc(row.duration, 60), .dur_sec = @rem(row.duration, 60), .views = row.views }, .{}, w);
    }
    try w.print("],\"loading\":{s},\"request_generation\":{d},\"total\":{d},\"returned\":{d},\"truncated\":{s}}}", .{ if (info.loading) "true" else "false", info.request_generation, info.total, rows.len, if (info.total > rows.len) "true" else "false" });
}
test "escaped YouTube snapshots fit actual bounded writer and retain thumbnails" {
    const alloc = std.testing.allocator;
    const rows = try alloc.alloc(Row, LIMIT);
    defer alloc.free(rows);
    for (rows) |*row| row.* = .{ .video_id = @splat(1), .video_id_len = 32, .title = @splat(1), .title_len = 128, .uploader = @splat(1), .uploader_len = 64, .channel_id = @splat(1), .channel_id_len = 32, .thumbnail_url = @splat(1), .thumbnail_url_len = 512, .duration = 61, .views = 100 };
    const buf = try alloc.alloc(u8, capacity(rows.len));
    defer alloc.free(buf);
    var w = std.Io.Writer.fixed(buf);
    try write(&w, rows, .{ .count = rows.len, .total = 40, .loading = true, .request_generation = 7 });
    try std.testing.expect(w.end > 32768);
    const doc = try std.json.parseFromSlice(std.json.Value, alloc, buf[0..w.end], .{});
    defer doc.deinit();
    const root = doc.value.object;
    try std.testing.expectEqual(@as(i64, 40), root.get("total").?.integer);
    try std.testing.expect(root.get("truncated").?.bool);
    try std.testing.expectEqual(@as(usize, 512), root.get("items").?.array.items[0].object.get("thumbnail").?.string.len);
}

test "production row copy owns metadata and clamps bad numeric and length fields" {
    var title = [_]u8{'a'} ** 128;
    std.mem.doNotOptimizeAway(&title);
    const item = .{ .video_id = [_]u8{'v'} ** 32, .video_id_len = @as(usize, 500), .title = title, .title_len = @as(usize, 500), .uploader = [_]u8{'u'} ** 64, .uploader_len = @as(usize, 500), .channel_id = [_]u8{'c'} ** 32, .channel_id_len = @as(usize, 500), .thumbnail_url = [_]u8{'t'} ** 512, .thumbnail_url_len = @as(usize, 900), .duration = @as(i64, -1), .views = @as(i64, -10) };
    const copy = Row.copy(item);
    title[0] = 'b';
    try std.testing.expectEqual(@as(u8, 'a'), copy.title[0]);
    try std.testing.expectEqual(@as(usize, 512), copy.thumbnail_url_len);
    try std.testing.expectEqual(@as(usize, 128), copy.title_len);
    try std.testing.expectEqual(@as(i64, 0), copy.duration);
    try std.testing.expectEqual(@as(i64, 0), copy.views);
}
