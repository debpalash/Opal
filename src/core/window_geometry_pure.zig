//! Launch policy for dvui's persisted window geometry (windows_geometry.zon).
//!
//! dvui restores whatever state the window quit in, so quitting while the
//! window (or a video) was fullscreen made every later launch jump into a new
//! macOS fullscreen Space. Opal keeps the saved size/position and maximized
//! state, but always opens windowed; fullscreen is only ever a user action.
const std = @import("std");

const FULLSCREEN = ".state = .fullscreen";
const NORMAL = ".state = .normal";

/// Rewrite every saved `.state = .fullscreen` to `.state = .normal` into
/// `out`. Returns null when nothing needs changing (or `out` is too small),
/// so the caller leaves the file untouched.
pub fn dropFullscreen(saved: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.indexOf(u8, saved, FULLSCREEN) == null) return null;
    const needed = std.mem.replacementSize(u8, saved, FULLSCREEN, NORMAL);
    if (needed > out.len) return null;
    _ = std.mem.replace(u8, saved, FULLSCREEN, NORMAL, out[0..needed]);
    return out[0..needed];
}

test "saved fullscreen opens windowed at the saved geometry (auto-fullscreen regression)" {
    const saved =
        \\.{.{ .winid = 0, .geom = .{
        \\    .x = 0,
        \\    .y = 61,
        \\    .w = 1224,
        \\    .h = 751,
        \\    .state = .fullscreen,
        \\} }}
    ;
    var buf: [512]u8 = undefined;
    const fixed = dropFullscreen(saved, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, fixed, ".state = .normal,") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "fullscreen") == null);
    try std.testing.expect(std.mem.indexOf(u8, fixed, ".w = 1224,") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixed, ".y = 61,") != null);
}

test "maximized and normal geometry are left alone" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(dropFullscreen(".{.{ .winid = 0, .geom = .{ .x = 1, .y = 2, .w = 3, .h = 4, .state = .maximized } }}", &buf) == null);
    try std.testing.expect(dropFullscreen(".{.{ .winid = 0, .geom = .{ .x = 1, .y = 2, .w = 3, .h = 4 } }}", &buf) == null);
}

test "an undersized buffer leaves the file untouched" {
    var buf: [4]u8 = undefined;
    try std.testing.expect(dropFullscreen(".state = .fullscreen", &buf) == null);
}
