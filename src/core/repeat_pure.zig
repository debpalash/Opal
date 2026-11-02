//! Comptime byte repetition for fixtures formerly using Zig's removed ** operator.
pub fn bytes(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    const result = comptime blk: {
        var out: [text.len * count]u8 = undefined;
        if (out.len > 0) {
            @memcpy(out[0..text.len], text);
            var filled = text.len;
            while (filled < out.len) {
                const n = @min(filled, out.len - filled);
                @memcpy(out[filled..][0..n], out[0..n]);
                filled += n;
            }
        }
        break :blk out;
    };
    return &result;
}

test "repetition preserves bytes and handles large and empty fixtures" {
    const t = @import("std").testing;
    try t.expectEqualStrings("ababab", bytes("ab", 3));
    try t.expectEqualStrings("", bytes("x", 0));
    try t.expectEqualStrings("", bytes("", 2001));
    const large = bytes("xy", 2001);
    try t.expectEqual(@as(usize, 4002), large.len);
    try t.expectEqualStrings("xyxy", large[3998..]);
}
