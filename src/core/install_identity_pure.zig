const std = @import("std");

pub const encoded_len: usize = 32;

pub fn encode(bytes: [16]u8) [encoded_len]u8 {
    const alphabet = "0123456789abcdef";
    var out: [encoded_len]u8 = undefined;
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

pub fn valid(value: []const u8) bool {
    if (value.len != encoded_len) return false;
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

test "installation identity is fixed-width lowercase hex" {
    const value = encode(.{ 0x00, 0x12, 0xab, 0xff, 0x45, 0x67, 0x89, 0xcd, 0xef, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70 });
    try std.testing.expectEqualStrings("0012abff456789cdef10203040506070", &value);
    try std.testing.expect(valid(&value));
}

test "installation identity rejects malformed values" {
    try std.testing.expect(!valid(""));
    try std.testing.expect(!valid("0012abff456789cdef1020304050607"));
    try std.testing.expect(!valid("0012abff456789cdef1020304050607z"));
}
