const std = @import("std");

/// Decode AllAnime's obfuscated source hash into a playable URL. `base` is the
/// installed "allanime" endpoint (from source_config) — passed in rather than
/// hardcoded so no source host lives in the binary; a relative "/..." decode is
/// joined onto it.
pub fn decodeSourceURL(allocator: std.mem.Allocator, encoded: []const u8, base: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);

    // Provider obfuscation is a bytewise XOR, not a partial substitution table.
    // A partial alphabet corrupts uppercase IDs, punctuation and signatures.
    const hash = if (std.mem.startsWith(u8, encoded, "--")) encoded[2..] else encoded;
    if (hash.len == 0 or hash.len % 2 != 0) return error.InvalidSourceHash;
    var i: usize = 0;
    while (i < hash.len) : (i += 2) {
        const byte = std.fmt.parseInt(u8, hash[i..][0..2], 16) catch return error.InvalidSourceHash;
        const ch = byte ^ 0x38;
        if (ch < 0x20 or ch == 0x7f) return error.InvalidSourceHash;
        try out.append(allocator, ch);
    }

    // if string contains /clock, replace with /clock.json per GoAnime
    const decoded_str = out.items;
    var res_str: []u8 = undefined;

    if (std.mem.indexOf(u8, decoded_str, "/clock?")) |idx| {
        // "/clock?id=..." -> "/clock.json?id=..."
        res_str = try std.fmt.allocPrint(allocator, "{s}/clock.json{s}", .{
            decoded_str[0..idx],
            decoded_str[idx + 6 ..],
        });
    } else {
        res_str = try allocator.dupe(u8, decoded_str);
    }

    defer allocator.free(res_str);

    if (std.mem.startsWith(u8, res_str, "/")) {
        const full_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ std.mem.trimEnd(u8, base, "/"), res_str });
        return full_url;
    }

    return allocator.dupe(u8, res_str);
}

test "decodeSourceURL joins a relative decode onto the passed-in base (no hardcoded host)" {
    const alloc = std.testing.allocator;
    // "17" decodes to '/', so this encodes a leading-slash path → joined onto base.
    const decoded = try decodeSourceURL(alloc, "17", "https://example.test");
    defer alloc.free(decoded);
    try std.testing.expect(std.mem.startsWith(u8, decoded, "https://example.test/"));
}

test "AllAnime decodes the full URL alphabet and rejects malformed hashes" {
    const a = std.testing.allocator;
    const expected = "/clock?id=AZ_g.m3u8&sig=abc%2F";
    var encoded: [expected.len * 2]u8 = undefined;
    const hex = "0123456789abcdef";
    for (expected, 0..) |ch, i| {
        const v = ch ^ 0x38;
        encoded[i * 2] = hex[v >> 4];
        encoded[i * 2 + 1] = hex[v & 15];
    }
    const url = try decodeSourceURL(a, &encoded, "https://source.test");
    defer a.free(url);
    try std.testing.expectEqualStrings("https://source.test/clock.json?id=AZ_g.m3u8&sig=abc%2F", url);
    try std.testing.expectError(error.InvalidSourceHash, decodeSourceURL(a, "zz", "https://source.test"));
}
