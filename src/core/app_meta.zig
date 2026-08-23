//! Canonical application identity derived from build metadata.

pub const version: []const u8 = @import("build_options").app_version;
pub const user_agent: []const u8 = "Opal/" ++ version;
pub const user_agent_with_url: []const u8 = user_agent ++ " (+https://github.com/debpalash/Opal)";
pub const browser_user_agent: []const u8 = "Mozilla/5.0 (X11; Linux x86_64) " ++ user_agent;

test "application identity uses the injected version" {
    const std = @import("std");
    try std.testing.expect(version.len > 0);
    try std.testing.expectEqualStrings("Opal/" ++ version, user_agent);
    try std.testing.expect(std.mem.endsWith(u8, browser_user_agent, user_agent));
}
