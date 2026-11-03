//! Stable release selection and notification policy; no network or filesystem.
const std = @import("std");
const Field = @import("wallpapers_pure.zig").Field;
pub const Platform = enum { mac_arm64, mac_intel, windows, linux };
pub const Mode = enum { bundle, installer, website };
pub const Release = struct { tag_name: []const u8, draft: bool = false, prerelease: bool = false, assets: []const struct { name: []const u8, browser_download_url: []const u8, size: u64 = 0 } };
pub const Selection = struct { version: Field(64) = .{}, asset: Field(160) = .{}, url: Field(1024) = .{}, sums: Field(1024) = .{}, mode: Mode = .website, size: u64 = 0 };
pub fn version(tag: []const u8) ?std.SemanticVersion {
    const value = if (tag.len > 0 and (tag[0] == 'v' or tag[0] == 'V')) tag[1..] else tag;
    if (value.len == 0 or value.len > 63) return null;
    const parsed = std.SemanticVersion.parse(value) catch return null;
    return if (parsed.pre == null and parsed.build == null) parsed else null;
}
pub fn newer(current: []const u8, tag: []const u8) bool {
    const a = version(current) orelse return false;
    const b = version(tag) orelse return false;
    return a.order(b) == .lt;
}
fn validURL(tag: []const u8, name: []const u8, url: []const u8) bool {
    var expected: [1400]u8 = undefined;
    const exact = std.fmt.bufPrint(&expected, "https://github.com/debpalash/Opal/releases/download/{s}/{s}", .{ tag, name }) catch return false;
    return std.mem.eql(u8, url, exact);
}
pub fn select(allocator: std.mem.Allocator, payload: []const u8, current: []const u8, platform: Platform, bundle_install: bool, out: *Selection) bool {
    const doc = std.json.parseFromSlice(Release, allocator, payload, .{ .ignore_unknown_fields = true }) catch return false;
    defer doc.deinit();
    const r = doc.value;
    if (r.draft or r.prerelease or !newer(current, r.tag_name)) return false;
    const v = std.mem.trimStart(u8, r.tag_name, "vV");
    out.* = .{};
    out.version.set(v);
    var name: [160]u8 = undefined;
    const wanted = switch (platform) {
        .mac_arm64 => std.fmt.bufPrint(&name, "Opal-{s}-macos-arm64.{s}", .{ v, if (bundle_install) "app.zip" else "dmg" }),
        .mac_intel => std.fmt.bufPrint(&name, "Opal-{s}-macos-x86_64.{s}", .{ v, if (bundle_install) "app.zip" else "dmg" }),
        .windows => std.fmt.bufPrint(&name, "Opal-{s}-windows-x86_64.msi", .{v}),
        .linux => std.fmt.bufPrint(&name, "", .{}),
    } catch return false;
    for (r.assets) |asset| {
        if (!validURL(r.tag_name, asset.name, asset.browser_download_url) or asset.browser_download_url.len > 1024) continue;
        if (std.mem.eql(u8, asset.name, "SHA256SUMS.txt")) out.sums.set(asset.browser_download_url);
        if (wanted.len > 0 and std.mem.eql(u8, asset.name, wanted) and asset.size <= 512 * 1024 * 1024) {
            out.asset.set(asset.name);
            out.url.set(asset.browser_download_url);
            out.size = asset.size;
        }
    }
    if (out.url.len > 0 and out.sums.len > 0) out.mode = if (bundle_install and (platform == .mac_arm64 or platform == .mac_intel)) .bundle else .installer;
    return true;
}
pub const Notice = struct {
    announced: Field(64) = .{},
    visible: bool = false,
    pub fn offer(self: *Notice, tag: []const u8, manual: bool) void {
        if (manual or !std.mem.eql(u8, self.announced.text(), tag)) self.visible = true;
        self.announced.set(tag);
    }
    pub fn dismiss(self: *Notice) void {
        self.visible = false;
    }
};
test "update version comparison rejects old malformed and prerelease versions" {
    try std.testing.expect(newer("0.9.2", "v0.10.0"));
    try std.testing.expect(!newer("0.9.2", "v0.9.1"));
    try std.testing.expect(!newer("0.9.2", "v0.9.3-beta"));
    try std.testing.expect(!newer("0.9.2", "v../update"));
    try std.testing.expect(!newer("0.9.2", "vv0.9.3"));
}
test "exact native archive and checksum belong to the same stable release" {
    const json =
        \\{"tag_name":"v0.9.3","assets":[{"name":"Opal-0.9.3-macos-arm64.app.zip","browser_download_url":"https://github.com/debpalash/Opal/releases/download/v0.9.3/Opal-0.9.3-macos-arm64.app.zip","size":123},{"name":"SHA256SUMS.txt","browser_download_url":"https://github.com/debpalash/Opal/releases/download/v0.9.3/SHA256SUMS.txt"}]}
    ;
    var s: Selection = undefined;
    try std.testing.expect(select(std.testing.allocator, json, "0.9.2", .mac_arm64, true, &s));
    try std.testing.expectEqual(Mode.bundle, s.mode);
    try std.testing.expect(select(std.testing.allocator, json, "0.9.2", .linux, false, &s));
    try std.testing.expectEqual(Mode.website, s.mode);
    try std.testing.expect(!select(std.testing.allocator, json, "0.9.3", .mac_arm64, true, &s));
    var notice: Notice = .{};
    notice.offer("0.9.3", false);
    try std.testing.expect(notice.visible);
    notice.dismiss();
    notice.offer("0.9.3", false);
    try std.testing.expect(!notice.visible);
    notice.offer("0.9.3", true);
    try std.testing.expect(notice.visible);
}
test "update selection refuses foreign hosts wrong architecture and unverified assets" {
    const payloads = [_][]const u8{
        \\{"tag_name":"v0.9.3","assets":[{"name":"Opal-0.9.3-macos-arm64.app.zip","browser_download_url":"https://evil.example/Opal-0.9.3-macos-arm64.app.zip"},{"name":"SHA256SUMS.txt","browser_download_url":"https://github.com/debpalash/Opal/releases/download/v0.9.3/SHA256SUMS.txt"}]}
        ,
        \\{"tag_name":"v0.9.3","assets":[{"name":"Opal-0.9.3-macos-x86_64.app.zip","browser_download_url":"https://github.com/debpalash/Opal/releases/download/v0.9.3/Opal-0.9.3-macos-x86_64.app.zip"}]}
        ,
        \\{"tag_name":"v0.9.3","assets":[{"name":"Opal-0.9.3-macos-arm64.app.zip","browser_download_url":"https://github.com/debpalash/Opal/releases/download/v0.9.3/Opal-0.9.3-macos-arm64.app.zip"}]}
        ,
    };
    for (payloads) |payload| {
        var selected: Selection = undefined;
        try std.testing.expect(select(std.testing.allocator, payload, "0.9.2", .mac_arm64, true, &selected));
        try std.testing.expectEqual(Mode.website, selected.mode);
    }
    var selected: Selection = undefined;
    try std.testing.expect(!select(std.testing.allocator, "{\"tag_name\":\"v0.9.3\",\"prerelease\":true,\"assets\":[]}", "0.9.2", .mac_arm64, true, &selected));
}
