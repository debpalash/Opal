//! Browser-only protection preferences, bounded profiles, and persistence.
const std = @import("std");
const Field = @import("wallpapers_pure.zig").Field;
pub const max_profiles = 8;
pub const max_extensions = 7;
pub const ProxyKind = enum { system, http, https, socks5, tor, pool };
pub const Profile = struct {
    name: Field(48) = .{},
    kind: ProxyKind = .http,
    host: Field(256) = .{},
    port: u16 = 8080,
    username: Field(128) = .{},
    password: Field(128) = .{},
};
pub const Extension = struct { path: Field(1024) = .{}, name: Field(96) = .{}, enabled: bool = true, private: bool = false, pinned: bool = false };
pub const Prefs = struct {
    canvas: bool = true,
    block_ads: bool = true,
    block_trackers: bool = true,
    clean_tracking_cookies: bool = true,
    block_webrtc: bool = false,
    https_only: bool = false,
    ubol_installed: bool = false,
    ubol_enabled: bool = true,
    ubol_private: bool = false,
    ubol_pinned: bool = true,
    proxy_mode: ProxyKind = .system,
    active_profile: usize = 0,
    profile_count: usize = 0,
    profiles: [max_profiles]Profile = @splat(.{}),
    canvas_exceptions: [16]Field(256) = @splat(.{}),
    canvas_exception_count: usize = 0,
    extensions: [max_extensions]Extension = @splat(.{}),
    extension_count: usize = 0,
};
pub fn validHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    for (host) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == ':' or c == '[' or c == ']')) return false;
    return true;
}
pub fn validProfile(p: *const Profile) bool {
    return p.name.len > 0 and validHost(p.host.text()) and p.port > 0 and (p.kind == .http or p.kind == .https or p.kind == .socks5);
}
pub fn hostAllowed(prefs: *const Prefs, host: []const u8) bool {
    for (prefs.canvas_exceptions[0..prefs.canvas_exception_count]) |*entry| if (std.ascii.eqlIgnoreCase(host, entry.text())) return true;
    return false;
}
const ProfileJSON = struct { name: []const u8 = "", kind: ProxyKind = .http, host: []const u8 = "", port: u16 = 8080, username: []const u8 = "", password: []const u8 = "" };
const ExtensionJSON = struct { path: []const u8 = "", name: []const u8 = "", enabled: bool = true, private: bool = false, pinned: bool = false };
const JSON = struct {
    canvas: bool = true,
    block_ads: bool = true,
    block_trackers: bool = true,
    clean_tracking_cookies: bool = true,
    block_webrtc: bool = false,
    https_only: bool = false,
    ubol_installed: bool = false,
    ubol_enabled: bool = true,
    ubol_private: bool = false,
    ubol_pinned: bool = true,
    proxy_mode: ProxyKind = .system,
    active_profile: usize = 0,
    profiles: []const ProfileJSON = &.{},
    extensions: []const ExtensionJSON = &.{},
    canvas_exceptions: []const []const u8 = &.{},
};
pub fn encode(prefs: *const Prefs, buffer: []u8, runtime_secrets: bool) ?[]const u8 {
    var profiles: [max_profiles]ProfileJSON = undefined;
    var extensions: [max_extensions]ExtensionJSON = undefined;
    var exceptions: [16][]const u8 = undefined;
    for (prefs.profiles[0..prefs.profile_count], 0..) |*p, i| profiles[i] = .{ .name = p.name.text(), .kind = p.kind, .host = p.host.text(), .port = p.port, .username = p.username.text(), .password = if (runtime_secrets) p.password.text() else "" };
    for (prefs.extensions[0..prefs.extension_count], 0..) |*e, i| extensions[i] = .{ .path = e.path.text(), .name = e.name.text(), .enabled = e.enabled, .private = e.private, .pinned = e.pinned };
    for (prefs.canvas_exceptions[0..prefs.canvas_exception_count], 0..) |*e, i| exceptions[i] = e.text();
    const value: JSON = .{ .canvas = prefs.canvas, .block_ads = prefs.block_ads, .block_trackers = prefs.block_trackers, .clean_tracking_cookies = prefs.clean_tracking_cookies, .block_webrtc = prefs.block_webrtc, .https_only = prefs.https_only, .ubol_installed = prefs.ubol_installed, .ubol_enabled = prefs.ubol_enabled, .ubol_private = prefs.ubol_private, .ubol_pinned = prefs.ubol_pinned, .proxy_mode = prefs.proxy_mode, .active_profile = prefs.active_profile, .profiles = profiles[0..prefs.profile_count], .extensions = extensions[0..prefs.extension_count], .canvas_exceptions = exceptions[0..prefs.canvas_exception_count] };
    var writer = std.Io.Writer.fixed(buffer);
    std.json.Stringify.value(value, .{}, &writer) catch return null;
    return writer.buffered();
}
pub fn decode(allocator: std.mem.Allocator, text: []const u8, prefs: *Prefs) !void {
    const parsed = try std.json.parseFromSlice(JSON, allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const json = parsed.value;
    if (json.profiles.len > max_profiles or json.extensions.len > max_extensions or json.canvas_exceptions.len > 16) return error.TooManyEntries;
    var next: Prefs = .{};
    next.canvas = json.canvas;
    next.block_ads = json.block_ads;
    next.block_trackers = json.block_trackers;
    next.clean_tracking_cookies = json.clean_tracking_cookies;
    next.block_webrtc = json.block_webrtc;
    next.https_only = json.https_only;
    next.ubol_installed = json.ubol_installed;
    next.ubol_enabled = json.ubol_enabled;
    next.ubol_private = json.ubol_private;
    next.ubol_pinned = json.ubol_pinned;
    next.proxy_mode = json.proxy_mode;
    next.active_profile = json.active_profile;
    for (json.profiles, 0..) |p, i| {
        if (p.name.len > 48 or p.host.len > 256 or p.username.len > 128) return error.InvalidProfile;
        const row = &next.profiles[i];
        row.name.set(p.name);
        row.kind = p.kind;
        row.host.set(p.host);
        row.port = p.port;
        row.username.set(p.username);
        // Password keys load independently, in either database order.
        row.password = prefs.profiles[i].password;
        if (!validProfile(row)) return error.InvalidProfile;
        next.profile_count += 1;
    }
    if (next.active_profile >= next.profile_count and next.proxy_mode != .system and next.proxy_mode != .tor and next.proxy_mode != .pool) return error.InvalidProfile;
    for (json.extensions, 0..) |e, i| {
        if (e.path.len == 0 or e.path.len > 1024 or e.name.len > 96 or !std.fs.path.isAbsolute(e.path)) return error.InvalidExtension;
        next.extensions[i].path.set(e.path);
        next.extensions[i].name.set(e.name);
        next.extensions[i].enabled = e.enabled;
        next.extensions[i].private = e.private;
        next.extensions[i].pinned = e.pinned;
        next.extension_count += 1;
    }
    for (json.canvas_exceptions, 0..) |host, i| {
        if (!validHost(host)) return error.InvalidHost;
        next.canvas_exceptions[i].set(host);
        next.canvas_exception_count += 1;
    }
    prefs.* = next;
}
test "Tor and empty pools persist without inventing a direct fallback profile" {
    var prefs: Prefs = .{};
    for ([_]ProxyKind{ .tor, .pool }) |mode| {
        prefs.proxy_mode = mode;
        prefs.https_only = true;
        prefs.block_webrtc = true;
        var buffer: [32768]u8 = undefined;
        const text = encode(&prefs, &buffer, false).?;
        var restored: Prefs = .{};
        try decode(std.testing.allocator, text, &restored);
        try std.testing.expectEqual(mode, restored.proxy_mode);
        try std.testing.expectEqual(@as(usize, 0), restored.profile_count);
        try std.testing.expect(restored.https_only and restored.block_webrtc);
        try std.testing.expect(restored.block_ads and restored.block_trackers and restored.clean_tracking_cookies);
    }
}
test "browser profiles reject URLs commands missing ports and control characters" {
    for ([_][]const u8{ "127.0.0.1", "localhost", "proxy.example.org", "::1", "[::1]" }) |host| try std.testing.expect(validHost(host));
    for ([_][]const u8{ "", "http://proxy", "proxy:80/path", "user@proxy", "proxy\r\nHeader", "$(touch file)" }) |host| try std.testing.expect(!validHost(host));
    var p: Profile = .{};
    p.name.set("Local");
    p.host.set("localhost");
    try std.testing.expect(validProfile(&p));
    p.port = 0;
    try std.testing.expect(!validProfile(&p));
}
test "browser preferences persist without proxy passwords and decode transactionally" {
    var prefs: Prefs = .{};
    prefs.profile_count = 1;
    prefs.proxy_mode = .socks5;
    prefs.profiles[0].name.set("Local");
    prefs.profiles[0].kind = .socks5;
    prefs.profiles[0].host.set("127.0.0.1");
    prefs.profiles[0].password.set("secret-password");
    var buf: [4096]u8 = undefined;
    const json = encode(&prefs, &buf, false).?;
    try std.testing.expect(std.mem.indexOf(u8, json, "secret-password") == null);
    var restored: Prefs = .{};
    restored.profiles[0].password.set("separate-secret");
    try decode(std.testing.allocator, json, &restored);
    try std.testing.expectEqualStrings("separate-secret", restored.profiles[0].password.text());
    try std.testing.expectEqual(ProxyKind.socks5, restored.proxy_mode);
    const before = restored;
    try std.testing.expectError(error.InvalidProfile, decode(std.testing.allocator, "{\"proxy_mode\":\"http\",\"active_profile\":999}", &restored));
    try std.testing.expectEqual(before, restored);
    const runtime = encode(&prefs, &buf, true).?;
    try std.testing.expect(std.mem.indexOf(u8, runtime, "secret-password") != null);
}
test "canvas exceptions match exact hosts and never grant third-party frames access" {
    var prefs: Prefs = .{};
    prefs.canvas_exceptions[0].set("editor.example");
    prefs.canvas_exception_count = 1;
    try std.testing.expect(hostAllowed(&prefs, "EDITOR.EXAMPLE"));
    try std.testing.expect(!hostAllowed(&prefs, "tracking.editor.example"));
    try std.testing.expect(!hostAllowed(&prefs, "editor.example.evil"));
}
test "extension toolbar pins persist independently of enabled and private access" {
    var prefs: Prefs = .{};
    prefs.ubol_pinned = false;
    prefs.extension_count = 1;
    prefs.extensions[0].name.set("Owned extension");
    prefs.extensions[0].path.set("/owned/extension");
    prefs.extensions[0].pinned = true;
    prefs.extensions[0].enabled = false;
    prefs.extensions[0].private = false;
    var buffer: [32768]u8 = undefined;
    var restored: Prefs = .{};
    try decode(std.testing.allocator, encode(&prefs, &buffer, false).?, &restored);
    try std.testing.expect(!restored.ubol_pinned and restored.extensions[0].pinned);
    try std.testing.expect(!restored.extensions[0].enabled and !restored.extensions[0].private);
}
