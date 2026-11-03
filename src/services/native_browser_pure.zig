const std = @import("std");
pub const Rect = struct { x: f64 = 0, y: f64 = 0, w: f64 = 0, h: f64 = 0 };
pub fn intersects(a: Rect, b: Rect) bool {
    return a.w > 0 and a.h > 0 and b.w > 0 and b.h > 0 and a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}
pub fn clipped(r: Rect, width: f64, height: f64) Rect {
    if (!std.math.isFinite(r.x) or !std.math.isFinite(r.y) or !std.math.isFinite(r.w) or !std.math.isFinite(r.h)) return .{};
    const x = @max(0, r.x);
    const y = @max(0, r.y);
    return .{ .x = x, .y = y, .w = @max(0, @min(width, r.x + r.w) - x), .h = @max(0, @min(height, r.y + r.h) - y) };
}
pub fn allowedUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://") or std.mem.eql(u8, url, "about:blank");
}
test "native browser clips page to client area and detects overlapping popups" {
    const rect = clipped(.{ .x = -20, .y = 100, .w = 1200, .h = 900 }, 1000, 800);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 100, .w = 1000, .h = 700 }, rect);
    try std.testing.expect(intersects(rect, .{ .x = 10, .y = 80, .w = 200, .h = 40 }));
    try std.testing.expect(!intersects(rect, .{ .x = 0, .y = 0, .w = 1000, .h = 100 }));
    try std.testing.expectEqual(@as(f64, 0), clipped(.{ .x = std.math.nan(f64) }, 1000, 800).w);
}
test "native browser accepts web navigation without local file or script execution" {
    for ([_][]const u8{ "http://localhost:8080/test", "https://example.com/", "about:blank" }) |url| try std.testing.expect(allowedUrl(url));
    for ([_][]const u8{ "javascript:alert(1)", "file:///etc/passwd", "data:text/html,bad", "about:config", "" }) |url| try std.testing.expect(!allowedUrl(url));
}
