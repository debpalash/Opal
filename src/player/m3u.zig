const std = @import("std");

pub const M3UEntry = struct {
    title: []u8,
    url: []u8,
    logoUrl: ?[]u8 = null,
    group: ?[]u8 = null,
};

pub const M3UPlaylist = struct {
    entries: std.ArrayListUnmanaged(M3UEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) M3UPlaylist {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *M3UPlaylist) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.title);
            self.allocator.free(e.url);
            if (e.logoUrl) |l| self.allocator.free(l);
            if (e.group) |g| self.allocator.free(g);
        }
        self.entries.deinit(self.allocator);
    }

    /// Caller passes io so this file stays self-contained (unit tests
    /// build m3u.zig as a standalone module — imports outside its
    /// dir would violate module boundaries).
    pub fn loadFile(self: *M3UPlaylist, io: std.Io, file_path: []const u8) !void {
        const file = if (file_path.len > 0 and file_path[0] == '/')
            try std.Io.Dir.openFileAbsolute(io, file_path, .{})
        else
            try std.Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);
        const len = try file.length(io);
        if (len > 50 * 1024 * 1024) return error.FileTooBig;
        const text = try self.allocator.alloc(u8, len);
        defer self.allocator.free(text);
        const bytes_read = try file.readPositionalAll(io, text, 0);
        try self.parse(text[0..bytes_read]);
    }

    // Very permissive M3U parser
    pub fn parse(self: *M3UPlaylist, text: []const u8) !void {
        var lines = std.mem.splitSequence(u8, text, "\n");
        var current_title: ?[]const u8 = null;
        var current_logo: ?[]const u8 = null;
        var current_group: ?[]const u8 = null;

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, "#EXTINF:")) {
                // Parse attributes
                // #EXTINF:-1 tvg-id="123" tvg-logo="http:..." group-title="News",CNN
                
                // Extract title
                const comma_idx = std.mem.lastIndexOfScalar(u8, line, ',');
                if (comma_idx) |idx| {
                    current_title = std.mem.trim(u8, line[idx + 1 ..], " ");
                } else {
                    current_title = "Unknown Channel";
                }

                // Extract tvg-logo
                if (std.mem.indexOf(u8, line, "tvg-logo=\"")) |logo_start| {
                    const l_start = logo_start + 10;
                    if (std.mem.indexOfScalarPos(u8, line, l_start, '"')) |l_end| {
                        current_logo = line[l_start..l_end];
                    }
                }

                // Extract group-title
                if (std.mem.indexOf(u8, line, "group-title=\"")) |group_start| {
                    const g_start = group_start + 13;
                    if (std.mem.indexOfScalarPos(u8, line, g_start, '"')) |g_end| {
                        current_group = line[g_start..g_end];
                    }
                }
            } else if (!std.mem.startsWith(u8, line, "#")) {
                // It's a URL/URI
                if (current_title == null) {
                    // Raw URI without EXTINF
                    // use the filename as title
                    const slash_idx = std.mem.lastIndexOfScalar(u8, line, '/');
                    if (slash_idx) |idx| {
                        current_title = line[idx + 1 ..];
                    } else {
                        current_title = line;
                    }
                }

                try self.entries.append(self.allocator, .{
                    .title = try self.allocator.dupe(u8, current_title.?),
                    .url = try self.allocator.dupe(u8, line),
                    .logoUrl = if (current_logo) |cl| try self.allocator.dupe(u8, cl) else null,
                    .group = if (current_group) |cg| try self.allocator.dupe(u8, cg) else null,
                });

                // Reset for next entry
                current_title = null;
                current_logo = null;
                current_group = null;
            }
        }
    }
};

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "parse standard M3U playlist" {
    const alloc = std.testing.allocator;
    var pl = M3UPlaylist.init(alloc);
    defer pl.deinit();

    try pl.parse(
        \\#EXTM3U
        \\#EXTINF:-1 tvg-logo="http://logo.png" group-title="News",CNN
        \\http://stream.cnn.com/live.m3u8
        \\#EXTINF:-1,BBC World
        \\http://stream.bbc.com/live.m3u8
    );

    try std.testing.expectEqual(@as(usize, 2), pl.entries.items.len);
    try std.testing.expectEqualStrings("CNN", pl.entries.items[0].title);
    try std.testing.expectEqualStrings("http://stream.cnn.com/live.m3u8", pl.entries.items[0].url);
    try std.testing.expectEqualStrings("http://logo.png", pl.entries.items[0].logoUrl.?);
    try std.testing.expectEqualStrings("News", pl.entries.items[0].group.?);
    try std.testing.expectEqualStrings("BBC World", pl.entries.items[1].title);
    try std.testing.expect(pl.entries.items[1].logoUrl == null);
    try std.testing.expect(pl.entries.items[1].group == null);
}

test "parse raw URLs without EXTINF" {
    const alloc = std.testing.allocator;
    var pl = M3UPlaylist.init(alloc);
    defer pl.deinit();

    try pl.parse(
        \\http://example.com/stream1.mp4
        \\http://example.com/path/stream2.mkv
    );

    try std.testing.expectEqual(@as(usize, 2), pl.entries.items.len);
    // Title derived from filename
    try std.testing.expectEqualStrings("stream1.mp4", pl.entries.items[0].title);
    try std.testing.expectEqualStrings("stream2.mkv", pl.entries.items[1].title);
}

test "parse empty and whitespace-only input" {
    const alloc = std.testing.allocator;
    var pl = M3UPlaylist.init(alloc);
    defer pl.deinit();

    try pl.parse("");
    try std.testing.expectEqual(@as(usize, 0), pl.entries.items.len);

    try pl.parse("   \n\n  \n");
    try std.testing.expectEqual(@as(usize, 0), pl.entries.items.len);
}

test "parse EXTINF without comma uses fallback title" {
    const alloc = std.testing.allocator;
    var pl = M3UPlaylist.init(alloc);
    defer pl.deinit();

    try pl.parse(
        \\#EXTINF:-1
        \\http://example.com/stream.mp4
    );

    try std.testing.expectEqual(@as(usize, 1), pl.entries.items.len);
    try std.testing.expectEqualStrings("Unknown Channel", pl.entries.items[0].title);
}
