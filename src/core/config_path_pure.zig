//! Config-directory policy shared by the desktop app and the std-only MCP
//! helper. This module deliberately has no libc or process-environment calls.
const std = @import("std");

pub const Parts = struct {
    base: []const u8,
    suffix: []const u8,
};

pub fn resolve(
    is_windows: bool,
    appdata: ?[]const u8,
    userprofile: ?[]const u8,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
) ?Parts {
    if (is_windows) {
        if (appdata) |base| {
            if (base.len > 0) return .{ .base = base, .suffix = "opal" };
        }
        const profile = userprofile orelse return null;
        if (profile.len == 0) return null;
        // The caller can format this without reading a second environment.
        return .{ .base = profile, .suffix = "AppData/Roaming/opal" };
    }
    if (xdg_config_home) |base| {
        if (base.len > 0) return .{ .base = base, .suffix = "opal" };
    }
    const base = home orelse return null;
    if (base.len == 0) return null;
    return .{ .base = base, .suffix = ".config/opal" };
}

test "config policy keeps desktop and standalone helper on the same Windows path" {
    try std.testing.expectEqualDeep(Parts{ .base = "C:/Users/A/AppData/Roaming", .suffix = "opal" }, resolve(true, "C:/Users/A/AppData/Roaming", "C:/Users/A", null, null).?);
    try std.testing.expectEqualDeep(Parts{ .base = "C:/Users/A", .suffix = "AppData/Roaming/opal" }, resolve(true, null, "C:/Users/A", null, null).?);
    try std.testing.expect(resolve(true, null, null, null, null) == null);
}

test "config policy honors XDG and otherwise uses the home config directory" {
    try std.testing.expectEqualDeep(Parts{ .base = "/xdg", .suffix = "opal" }, resolve(false, null, null, "/xdg", "/home/a").?);
    try std.testing.expectEqualDeep(Parts{ .base = "/home/a", .suffix = ".config/opal" }, resolve(false, null, null, null, "/home/a").?);
    try std.testing.expect(resolve(false, null, null, null, null) == null);
}
