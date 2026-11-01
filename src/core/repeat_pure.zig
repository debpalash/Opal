//! Comptime byte repetition for fixtures formerly using Zig's removed ** operator.
pub fn bytes(comptime text: []const u8, comptime count: usize) [text.len * count]u8 {
    var result: [text.len * count]u8 = undefined;
    for (0..count) |i| @memcpy(result[i * text.len ..][0..text.len], text);
    return result;
}
