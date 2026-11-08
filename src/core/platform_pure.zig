//! Mobile builds keep the shared media application without desktop helpers.
const std = @import("std");
const builtin = @import("builtin");
pub fn isMobile(os: std.Target.Os.Tag, abi: std.Target.Abi) bool {
    return os == .ios or abi.isAndroid();
}
pub const mobile = isMobile(builtin.os.tag, builtin.abi);
test "mobile targets exclude desktop helper processes without excluding desktop Linux" {
    try std.testing.expect(isMobile(.ios, .none));
    try std.testing.expect(isMobile(.linux, .android));
    try std.testing.expect(!isMobile(.linux, .gnu));
    try std.testing.expect(!isMobile(.macos, .none));
    try std.testing.expect(!isMobile(.windows, .msvc));
}

/// iOS moves an app's data container (new UUID path) across installs, so an
/// absolute path saved last run points into a container the app can no longer
/// write: torrents saved there failed with "Operation not permitted", sat in
/// upload mode and never downloaded. On a sandboxed platform a stored path is
/// honoured only inside the CURRENT home. `/private/var` and `/var` are the
/// same place on iOS (symlink) and compare equal.
pub fn storedPathUsable(stored: []const u8, home: []const u8, sandboxed: bool) bool {
    if (!sandboxed) return true;
    const s = stripPrivate(stored);
    const h = std.mem.trimEnd(u8, stripPrivate(home), "/");
    if (h.len == 0 or s.len <= h.len) return false;
    return std.mem.startsWith(u8, s, h) and s[h.len] == '/';
}
fn stripPrivate(path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, "/private/var/")) path["/private".len..] else path;
}
test "regression: a save path from a previous iOS container is not reused" {
    const home = "/private/var/mobile/Containers/Data/Application/NEW";
    try std.testing.expect(storedPathUsable(home ++ "/Documents/Downloads", home, true));
    try std.testing.expect(storedPathUsable("/var/mobile/Containers/Data/Application/NEW/Documents/Downloads", home, true));
    try std.testing.expect(!storedPathUsable("/private/var/mobile/Containers/Data/Application/F6EE3AFE/Documents/Downloads", home, true));
    try std.testing.expect(!storedPathUsable(home ++ "X/Documents", home, true));
    try std.testing.expect(storedPathUsable("/Volumes/Media/opal", "/Users/me", false));
}
