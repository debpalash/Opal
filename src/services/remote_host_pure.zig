//! Host-capability response construction, separated for behavior-level tests.

const std = @import("std");

pub fn build(out: []u8, headless: bool, version: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(out, "{{\"headless\":{s},\"version\":\"{s}\"}}", .{
        if (headless) "true" else "false",
        version,
    }) catch null;
}

test "host response reports the canonical application version" {
    const canonical_version = @import("build_options").app_version;
    var actual_buf: [128]u8 = undefined;
    const actual = build(&actual_buf, true, canonical_version) orelse return error.TestUnexpectedResult;
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{{\"headless\":true,\"version\":\"{s}\"}}", .{canonical_version});
    try std.testing.expectEqualStrings(expected, actual);
}
