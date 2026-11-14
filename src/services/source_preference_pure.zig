const std = @import("std");
/// Episodes of the same show share a preference; release titles and URLs never
/// become persistence keys. The search layer canonicalizes season/episode text.
pub fn key(query: []const u8, out: []u8) ?[]const u8 {
    var normalized: [256]u8 = undefined;
    const n = @min(query.len, normalized.len);
    for (query[0..n], 0..) |c, i| normalized[i] = std.ascii.toLower(c);
    var end: usize = n;
    for (0..n) |i| {
        if (i + 6 <= n and normalized[i] == 's' and (i == 0 or normalized[i - 1] == ' ') and std.ascii.isDigit(normalized[i + 1]) and std.ascii.isDigit(normalized[i + 2]) and normalized[i + 3] == 'e' and std.ascii.isDigit(normalized[i + 4]) and std.ascii.isDigit(normalized[i + 5])) {
            end = i;
            break;
        }
    }
    const title = std.mem.trim(u8, normalized[0..end], " \t\r\n");
    if (title.len == 0) return null;
    return std.fmt.bufPrint(out, "source_preference:{x}", .{std.hash.Wyhash.hash(0, title)}) catch null;
}
test "show preferences survive episode changes without mixing titles" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings(key("Example S01E01", &a).?, key("example s02e03", &b).?);
    try std.testing.expect(!std.mem.eql(u8, key("Example", &a).?, key("Another example", &b).?));
}

/// A modest preference boost never wraps an already excellent score.
pub fn rankedScore(base: u32, preferred: bool) u32 {
    return base -| @as(u32, if (preferred) 32 else 0);
}
test "preferred provider ranks consistently in native and web projections" {
    try std.testing.expect(rankedScore(100, true) < rankedScore(90, false));
    try std.testing.expectEqual(@as(u32, 0), rankedScore(12, true));
    try std.testing.expectEqual(@as(u32, 90), rankedScore(90, false));
}
