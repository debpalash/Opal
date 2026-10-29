//! Allocation-free query encoding shared by network actions.
const std = @import("std");
pub const Style = enum { component, form, query };
pub const Result = struct { bytes: []const u8, complete: bool };
/// Writes only complete escapes, including when the output exactly fits.
/// component uses RFC 3986; form/query use '+' for spaces. Legacy form
/// callers encode '~', while query callers preserve it.
pub fn encode(input: []const u8, out: []u8, style: Style) Result {
    var n: usize = 0;
    for (input) |ch| {
        const plain = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or (ch == '~' and style != .form);
        const plus = ch == ' ' and style != .component;
        const need: usize = if (plain or plus) 1 else 3;
        if (need > out.len - n) return .{ .bytes = out[0..n], .complete = false };
        if (plain or plus) {
            out[n] = if (plus) '+' else ch;
        } else {
            out[n] = '%';
            out[n + 1] = "0123456789ABCDEF"[ch >> 4];
            out[n + 2] = "0123456789ABCDEF"[ch & 15];
        }
        n += need;
    }
    return .{ .bytes = out[0..n], .complete = true };
}
test "query encoding preserves provider conventions and Unicode bytes" {
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("a+b%26%2B%7E", encode("a b&+~", &buf, .form).bytes);
    try std.testing.expectEqualStrings("a+b%26%2B~", encode("a b&+~", &buf, .query).bytes);
    try std.testing.expectEqualStrings("a%20b%26%2B~", encode("a b&+~", &buf, .component).bytes);
    try std.testing.expectEqualStrings("%E6%97%A5", encode("日", &buf, .component).bytes);
}
test "exact fits and overflow never emit incomplete escapes" {
    var buf: [3]u8 = undefined;
    try std.testing.expect(encode("&", &buf, .component).complete);
    try std.testing.expectEqualStrings("%26", &buf);
    try std.testing.expect(encode("abc", &buf, .component).complete);
    const short = encode("a&", &buf, .component);
    try std.testing.expect(!short.complete);
    try std.testing.expectEqualStrings("a", short.bytes);
    try std.testing.expect(!encode("a", buf[0..0], .component).complete);
    try std.testing.expect(encode("", buf[0..0], .component).complete);
}
