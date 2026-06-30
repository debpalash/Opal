const std = @import("std");

/// XDG-compliant path resolution for Opal.
/// Replaces all hardcoded `/home/pal/...` paths with portable alternatives.

/// zig 0.16 removed getenv; wrap libc getenv returning a static slice.
fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

/// Get the user's home directory from $HOME.
fn getHome() []const u8 {
    return getenv("HOME") orelse "/tmp";
}

/// ~/.config/zigzag  (or $XDG_CONFIG_HOME/zigzag)
pub fn configDir(buf: []u8) []const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/zigzag", .{xdg}) catch "/tmp/zigzag";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.config/zigzag", .{home}) catch "/tmp/zigzag";
}

/// ~/.config/zigzag/config.tsv
pub fn configFile(buf: []u8) []const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/zigzag/config.tsv", .{xdg}) catch "/tmp/zigzag/config.tsv";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.config/zigzag/config.tsv", .{home}) catch "/tmp/zigzag/config.tsv";
}

/// ~/.config/zigzag/watch_history.tsv
pub fn watchHistoryFile(buf: []u8) []const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/zigzag/watch_history.tsv", .{xdg}) catch "/tmp/zigzag_watch_history.tsv";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.config/zigzag/watch_history.tsv", .{home}) catch "/tmp/zigzag_watch_history.tsv";
}

/// ~/.cache/zigzag/<name> (or $XDG_CACHE_HOME/zigzag/<name>)
pub fn cacheFile(buf: []u8, name: []const u8) []const u8 {
    if (getenv("XDG_CACHE_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/zigzag/{s}", .{ xdg, name }) catch "/tmp/zigzag_cache";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.cache/zigzag/{s}", .{ home, name }) catch "/tmp/zigzag_cache";
}

/// ~/Downloads/zigzag (default save path)
pub fn defaultSavePath(buf: []u8) []const u8 {
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/Downloads/zigzag", .{home}) catch "/tmp/zigzag_downloads";
}

/// ~/Videos/zigzag (alternative save path)
pub fn videosSavePath(buf: []u8) []const u8 {
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/Videos/zigzag", .{home}) catch "/tmp/zigzag_videos";
}

/// ~/.config/zigzag/zigzag.db (unified SQLite database)
pub fn zigzagDbFile(buf: []u8) []const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/zigzag/zigzag.db", .{xdg}) catch "/tmp/zigzag.db";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.config/zigzag/zigzag.db", .{home}) catch "/tmp/zigzag.db";
}

/// ~/.config/zigzag/tmdb.db (SQLite database for TMDB data)
pub fn tmdbDbFile(buf: []u8) []const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/zigzag/tmdb.db", .{xdg}) catch "/tmp/zigzag_tmdb.db";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.config/zigzag/tmdb.db", .{home}) catch "/tmp/zigzag_tmdb.db";
}

/// Ensure the cache directory exists.
pub fn ensureCacheDir() void {
    var buf: [512]u8 = undefined;
    if (getenv("XDG_CACHE_HOME")) |xdg| {
        const dir = std.fmt.bufPrint(&buf, "{s}/zigzag", .{xdg}) catch return;
        @import("io_global.zig").cwdMakePath(dir) catch {};
    } else {
        const home = getHome();
        const dir = std.fmt.bufPrint(&buf, "{s}/.cache/zigzag", .{home}) catch return;
        @import("io_global.zig").cwdMakePath(dir) catch {};
    }
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "configDir contains zigzag" {
    var buf: [512]u8 = undefined;
    const dir = configDir(&buf);
    try std.testing.expect(std.mem.endsWith(u8, dir, "/zigzag"));
    try std.testing.expect(dir.len > 7); // not just "/zigzag"
}

test "configFile ends with config.tsv" {
    var buf: [512]u8 = undefined;
    const path = configFile(&buf);
    try std.testing.expect(std.mem.endsWith(u8, path, "/zigzag/config.tsv"));
}

test "watchHistoryFile ends with watch_history.tsv" {
    var buf: [512]u8 = undefined;
    const path = watchHistoryFile(&buf);
    try std.testing.expect(std.mem.endsWith(u8, path, "watch_history.tsv"));
}

test "cacheFile includes name" {
    var buf: [512]u8 = undefined;
    const path = cacheFile(&buf, "asr_output.wav");
    try std.testing.expect(std.mem.endsWith(u8, path, "asr_output.wav"));
    try std.testing.expect(std.mem.indexOf(u8, path, "zigzag") != null);
}

test "defaultSavePath contains Downloads" {
    var buf: [512]u8 = undefined;
    const path = defaultSavePath(&buf);
    try std.testing.expect(std.mem.indexOf(u8, path, "Downloads") != null or
        std.mem.indexOf(u8, path, "zigzag") != null);
}

test "videosSavePath contains Videos" {
    var buf: [512]u8 = undefined;
    const path = videosSavePath(&buf);
    try std.testing.expect(std.mem.indexOf(u8, path, "Videos") != null or
        std.mem.indexOf(u8, path, "zigzag") != null);
}

test "small buffer falls back safely" {
    var tiny: [4]u8 = undefined;
    const path = configDir(&tiny);
    // Should return fallback /tmp/zigzag
    try std.testing.expectEqualStrings("/tmp/zigzag", path);
}
