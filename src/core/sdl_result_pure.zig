//! SDL2 returns zero on success; SDL3 returns true.
const std = @import("std");
pub fn succeeded(value: anytype) bool {
    return if (@TypeOf(value) == bool) value else value == 0;
}
test "SDL2 and SDL3 texture upload results have opposite success conventions" {
    try std.testing.expect(succeeded(@as(c_int, 0)));
    try std.testing.expect(!succeeded(@as(c_int, -1)));
    try std.testing.expect(succeeded(true));
    try std.testing.expect(!succeeded(false));
}
