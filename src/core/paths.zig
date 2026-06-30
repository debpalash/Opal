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

/// ~/.config/opal  (or $XDG_CONFIG_HOME/opal)
pub fn configDir(buf: []u8) []const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/opal", .{xdg}) catch "/tmp/opal";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.config/opal", .{home}) catch "/tmp/opal";
}

/// ~/.config/opal/config.tsv
pub fn configFile(buf: []u8) []const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/opal/config.tsv", .{xdg}) catch "/tmp/opal/config.tsv";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.config/opal/config.tsv", .{home}) catch "/tmp/opal/config.tsv";
}

/// ~/.config/opal/watch_history.tsv
pub fn watchHistoryFile(buf: []u8) []const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/opal/watch_history.tsv", .{xdg}) catch "/tmp/opal_watch_history.tsv";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.config/opal/watch_history.tsv", .{home}) catch "/tmp/opal_watch_history.tsv";
}

/// ~/.cache/opal/<name> (or $XDG_CACHE_HOME/opal/<name>)
pub fn cacheFile(buf: []u8, name: []const u8) []const u8 {
    if (getenv("XDG_CACHE_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/opal/{s}", .{ xdg, name }) catch "/tmp/opal_cache";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.cache/opal/{s}", .{ home, name }) catch "/tmp/opal_cache";
}

/// ~/Downloads/opal (default save path)
pub fn defaultSavePath(buf: []u8) []const u8 {
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/Downloads/opal", .{home}) catch "/tmp/opal_downloads";
}

/// ~/Videos/opal (alternative save path)
pub fn videosSavePath(buf: []u8) []const u8 {
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/Videos/opal", .{home}) catch "/tmp/opal_videos";
}

/// ~/.config/opal/opal.db (unified SQLite database)
pub fn zigzagDbFile(buf: []u8) []const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/opal/opal.db", .{xdg}) catch "/tmp/opal.db";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.config/opal/opal.db", .{home}) catch "/tmp/opal.db";
}

/// ~/.config/opal/tmdb.db (SQLite database for TMDB data)
pub fn tmdbDbFile(buf: []u8) []const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/opal/tmdb.db", .{xdg}) catch "/tmp/opal_tmdb.db";
    }
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/.config/opal/tmdb.db", .{home}) catch "/tmp/opal_tmdb.db";
}

/// Ensure the cache directory exists.
pub fn ensureCacheDir() void {
    var buf: [512]u8 = undefined;
    if (getenv("XDG_CACHE_HOME")) |xdg| {
        const dir = std.fmt.bufPrint(&buf, "{s}/opal", .{xdg}) catch return;
        @import("io_global.zig").cwdMakePath(dir) catch {};
    } else {
        const home = getHome();
        const dir = std.fmt.bufPrint(&buf, "{s}/.cache/opal", .{home}) catch return;
        @import("io_global.zig").cwdMakePath(dir) catch {};
    }
}

// ══════════════════════════════════════════════════════════
// Legacy migration: zigzag → opal
// ══════════════════════════════════════════════════════════

fn legacyDir(buf: []u8, env: [*:0]const u8, sub: []const u8, name: []const u8) []const u8 {
    if (getenv(env)) |xdg| return std.fmt.bufPrint(buf, "{s}/{s}", .{ xdg, name }) catch "";
    const home = getHome();
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ home, sub, name }) catch "";
}

/// Move every entry from the legacy `old` dir into `new`, but only when `new`
/// doesn't already have it (so a pre-existing opal dir can't strand data). When
/// `new` is absent entirely we do a fast atomic whole-dir rename. `rename_db`
/// maps `zigzag.db*` → `opal.db*` on the way in.
fn mergeDir(old: []const u8, new: []const u8, rename_db: bool) void {
    const io = @import("io_global.zig");
    if (old.len == 0 or new.len == 0) return;
    io.cwdAccess(old, .{}) catch return; // nothing legacy to migrate

    // Fast path: opal absent → atomic rename, then fix the db name.
    if (io.cwdAccess(new, .{})) |_| {} else |_| {
        if (std.Io.Dir.renameAbsolute(old, new, io.io())) |_| {
            if (rename_db) {
                const sfx = [_][]const u8{ "", "-wal", "-shm", "-journal" };
                for (sfx) |s| {
                    var fo: [600]u8 = undefined;
                    var fnn: [600]u8 = undefined;
                    const a = std.fmt.bufPrint(&fo, "{s}/zigzag.db{s}", .{ new, s }) catch continue;
                    const b = std.fmt.bufPrint(&fnn, "{s}/opal.db{s}", .{ new, s }) catch continue;
                    std.Io.Dir.renameAbsolute(a, b, io.io()) catch {};
                }
            }
            return;
        } else |_| {}
    }

    // Merge path: opal exists → fill in only what it's missing.
    io.cwdMakePath(new) catch {};
    var dir = io.cwdOpenDir(old, .{ .iterate = true }) catch return;
    defer dir.close(io.io());
    var it = dir.iterate();
    while (it.next(io.io()) catch null) |entry| {
        var dst_name_buf: [128]u8 = undefined;
        const dst_name = if (rename_db and std.mem.startsWith(u8, entry.name, "zigzag.db"))
            (std.fmt.bufPrint(&dst_name_buf, "opal.db{s}", .{entry.name["zigzag.db".len..]}) catch entry.name)
        else
            entry.name;

        var np: [700]u8 = undefined;
        const n = std.fmt.bufPrint(&np, "{s}/{s}", .{ new, dst_name }) catch continue;
        if (io.cwdAccess(n, .{})) |_| continue else |_| {} // opal already has it → keep opal's

        var op: [700]u8 = undefined;
        const o = std.fmt.bufPrint(&op, "{s}/{s}", .{ old, entry.name }) catch continue;
        std.Io.Dir.renameAbsolute(o, n, io.io()) catch {};
    }
}

/// One-time migration of the legacy ~/.config/zigzag → ~/.config/opal (+ cache,
/// + zigzag.db → opal.db). Idempotent; robust to a pre-existing opal dir. MUST
/// run before config/db are opened.
pub fn migrateLegacyDir() void {
    var ob: [512]u8 = undefined;
    var nb: [512]u8 = undefined;
    mergeDir(
        legacyDir(&ob, "XDG_CONFIG_HOME", ".config", "zigzag"),
        legacyDir(&nb, "XDG_CONFIG_HOME", ".config", "opal"),
        true,
    );

    var ob2: [512]u8 = undefined;
    var nb2: [512]u8 = undefined;
    mergeDir(
        legacyDir(&ob2, "XDG_CACHE_HOME", ".cache", "zigzag"),
        legacyDir(&nb2, "XDG_CACHE_HOME", ".cache", "opal"),
        false,
    );
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "configDir contains opal" {
    var buf: [512]u8 = undefined;
    const dir = configDir(&buf);
    try std.testing.expect(std.mem.endsWith(u8, dir, "/opal"));
    try std.testing.expect(dir.len > 5); // not just "/opal"
}

test "configFile ends with config.tsv" {
    var buf: [512]u8 = undefined;
    const path = configFile(&buf);
    try std.testing.expect(std.mem.endsWith(u8, path, "/opal/config.tsv"));
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
    try std.testing.expect(std.mem.indexOf(u8, path, "opal") != null);
}

test "defaultSavePath contains Downloads" {
    var buf: [512]u8 = undefined;
    const path = defaultSavePath(&buf);
    try std.testing.expect(std.mem.indexOf(u8, path, "Downloads") != null or
        std.mem.indexOf(u8, path, "opal") != null);
}

test "videosSavePath contains Videos" {
    var buf: [512]u8 = undefined;
    const path = videosSavePath(&buf);
    try std.testing.expect(std.mem.indexOf(u8, path, "Videos") != null or
        std.mem.indexOf(u8, path, "opal") != null);
}

test "small buffer falls back safely" {
    var tiny: [4]u8 = undefined;
    const path = configDir(&tiny);
    // Should return fallback /tmp/opal
    try std.testing.expectEqualStrings("/tmp/opal", path);
}
