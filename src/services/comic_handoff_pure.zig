//! Comic identity from browser metadata; matching never guesses a different volume.
const std = @import("std");
const Field = @import("wallpapers_pure.zig").Field;
pub const Target = struct {
    series: Field(256) = .{},
    title: Field(512) = .{},
    publisher: Field(64) = .{},
    url: Field(2048) = .{},
    year: ?u16 = null,
    issue: ?f64 = null,
};
fn text(o: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}
pub fn parse(allocator: std.mem.Allocator, payload: []const u8, out: *Target) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const o = parsed.value.object;
    if (!std.mem.eql(u8, text(o, "what"), "read-comic")) return false;
    const kind = text(o, "kind");
    if (!std.mem.eql(u8, kind, "comic_issue") and !std.mem.eql(u8, kind, "comic_series")) return false;
    const confidence = o.get("confidence") orelse return false;
    if (confidence != .integer or confidence.integer < 80 or confidence.integer > 100) return false;
    const series = std.mem.trim(u8, text(o, "series"), " \t\r\n");
    if (series.len == 0 or series.len > 255 or !std.unicode.utf8ValidateSlice(series)) return false;
    for (series) |ch| if (ch < 32 or ch == 127) return false;
    const url = text(o, "url");
    const uri = std.Uri.parse(url) catch return false;
    if (url.len > 2048 or uri.host == null or (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(uri.scheme, "http"))) return false;
    out.* = .{};
    out.series.set(series);
    out.title.set(text(o, "title"));
    out.publisher.set(text(o, "publisher"));
    out.url.set(url);
    if (o.get("year")) |v| if (v != .null) {
        if (v != .integer or v.integer < 1800 or v.integer > 2199) return false;
        out.year = @intCast(v.integer);
    };
    if (o.get("issue")) |v| if (v != .null) {
        const n: f64 = switch (v) {
            .integer => |n| @floatFromInt(n),
            .float => |n| n,
            else => return false,
        };
        if (!std.math.isFinite(n) or n < 0 or n > 100000) return false;
        out.issue = n;
    };
    return true;
}
fn yearIn(title: []const u8) ?u16 {
    var i: usize = 0;
    while (i + 5 <= title.len) : (i += 1) if (title[i] == '(') {
        const y = std.fmt.parseInt(u16, title[i + 1 .. i + 5], 10) catch continue;
        if (y >= 1800 and y <= 2199 and (i + 5 == title.len or !std.ascii.isDigit(title[i + 5]))) return y;
    };
    return null;
}
fn issueIn(title: []const u8) ?f64 {
    const start = (std.mem.indexOfScalar(u8, title, '#') orelse return null) + 1;
    const tail = std.mem.trimStart(u8, title[start..], " ");
    var n: usize = 0;
    while (n < tail.len and (std.ascii.isDigit(tail[n]) or tail[n] == '.')) : (n += 1) {}
    return std.fmt.parseFloat(f64, tail[0..n]) catch null;
}
fn normalized(title: []const u8, out: []u8) []const u8 {
    var end = std.mem.indexOfScalar(u8, title, '#') orelse title.len;
    if (yearIn(title) != null) if (std.mem.indexOfScalar(u8, title, '(')) |i| {
        end = @min(end, i);
    };
    var n: usize = 0;
    for (title[0..end]) |ch| {
        if (ch >= 128 or std.ascii.isAlphanumeric(ch)) {
            if (n == out.len) break;
            out[n] = std.ascii.toLower(ch);
            n += 1;
        }
    }
    return out[0..n];
}
pub fn matches(target: *const Target, title: []const u8) bool {
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    if (!std.mem.eql(u8, normalized(target.series.text(), &a), normalized(title, &b))) return false;
    if (target.year) |expected| if (yearIn(title)) |actual| if (actual != expected) return false;
    if (target.issue) |expected| if (issueIn(title)) |actual| if (@abs(actual - expected) > 0.00001) return false;
    return true;
}
pub fn automaticScore(target: *const Target, title: []const u8) u8 {
    if (!matches(target, title)) return 0;
    if (target.year == null or yearIn(title) != target.year) return 0;
    return if (issueIn(title) != null) 3 else 2;
}
pub fn chooseIssue(comptime Row: type, rows: []const Row, number: f64) ?usize {
    for (rows, 0..) |row, i| if (std.math.isFinite(row.number) and @abs(row.number - number) < 0.00001) return i;
    return null;
}
test "browser comic identity distinguishes volume issue and similarly named spinoffs" {
    var target: Target = undefined;
    try std.testing.expect(parse(std.testing.allocator,
        \\{"what":"read-comic","kind":"comic_issue","confidence":90,"url":"https://www.marvel.com/comics/issue/133101/queen_in_black_2026_1","series":"Queen in Black","title":"Queen in Black (2026) #1","year":2026,"issue":1}
    , &target));
    try std.testing.expect(automaticScore(&target, "Queen In Black (2026)") > 0);
    try std.testing.expect(!matches(&target, "Queen In Black: Venom Unchained (2026)"));
    try std.testing.expect(!matches(&target, "Queen In Black (2025) #1"));
    try std.testing.expect(!matches(&target, "Queen In Black (2026) #2"));
    try std.testing.expectEqual(@as(u8, 0), automaticScore(&target, "Queen In Black"));
    const Row = struct { number: f64 };
    const rows = [_]Row{ .{ .number = 0 }, .{ .number = 1 }, .{ .number = 2 } };
    try std.testing.expectEqual(@as(?usize, 1), chooseIssue(Row, &rows, 1));
    try std.testing.expect(chooseIssue(Row, &rows, 5) == null);
    target.year = null;
    try std.testing.expectEqual(@as(u8, 0), automaticScore(&target, "Queen In Black (2026)"));
}
