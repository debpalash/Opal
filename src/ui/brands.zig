//! Bundled, attributed brand marks. No network requests during rendering.
//! Monochrome artwork follows the surrounding theme for contrast; actions and
//! categories keep their Lucide icons. See brands/sources.json for provenance.
const std = @import("std");
const dvui = @import("dvui");

pub const Brand = enum { youtube, youtubemusic, plex, jellyfin, emby, audiobookshelf, openverse, trakt, github, firefoxbrowser, googlechrome, brave, safari };
const count = @typeInfo(Brand).@"enum".fields.len;
const artwork = blk: {
    var entries: [count][]const u8 = undefined;
    for (@typeInfo(Brand).@"enum".fields, 0..) |field, i| entries[i] = @embedFile("brands/" ++ field.name ++ ".tvg");
    break :blk entries;
};

/// Preconverted vector bytes: no allocation, conversion, or network access.
pub fn icon(brand: Brand) []const u8 {
    return artwork[@intFromEnum(brand)];
}

pub fn forName(name: []const u8) ?Brand {
    const names = [_][]const u8{ "YouTube", "YouTube Music", "Plex", "Jellyfin", "Emby", "Audiobookshelf", "Openverse", "Trakt.tv", "GitHub", "Firefox", "Chrome", "Brave", "Safari" };
    for (names, 0..) |candidate, i| if (std.ascii.eqlIgnoreCase(name, candidate)) return @enumFromInt(i);
    if (std.ascii.eqlIgnoreCase(name, "Google Chrome")) return .googlechrome;
    if (std.ascii.eqlIgnoreCase(name, "Firefox Browser")) return .firefoxbrowser;
    if (std.ascii.eqlIgnoreCase(name, "Trakt")) return .trakt;
    return null;
}

pub fn verifyForTest() !void {
    for (0..count) |i| {
        const width = try dvui.iconWidth(@tagName(@as(Brand, @enumFromInt(i))), icon(@enumFromInt(i)), 24);
        try std.testing.expect(width > 0 and width <= 48);
    }
}
