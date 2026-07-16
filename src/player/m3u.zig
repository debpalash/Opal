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

    /// Serialize the whole playlist back to M3U text (#EXTM3U header +
    /// #EXTINF/URL pairs). Caller frees the returned slice.
    pub fn serialize(self: *const M3UPlaylist, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "#EXTM3U\n");
        for (self.entries.items) |e|
            try appendEntryLines(&out, allocator, e.title, e.url, e.logoUrl, e.group);
        return out.toOwnedSlice(allocator);
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
// M3U writing (pure format-building — no io)
// ══════════════════════════════════════════════════════════

/// Append one entry as M3U lines. Format:
///   #EXTINF:-1 tvg-logo="..." group-title="...",Title
///   <url>
/// Duration is always -1 (entries carry no duration; -1 is the M3U
/// convention for unknown/stream). Sanitization:
///  - newlines/CR in any field become spaces (they would corrupt the line format)
///  - '"' inside attribute values becomes '\'' (M3U attrs have no escaping)
///  - a blank title emits a bare URL line (the parser derives the title
///    from the filename on reload)
/// Commas in titles are emitted as-is (standard M3U has no escape for them;
/// the last-comma rule on reparse is a known parser limitation, not a writer bug).
pub fn appendEntryLines(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    title: []const u8,
    url: []const u8,
    logo: ?[]const u8,
    group: ?[]const u8,
) !void {
    const t = std.mem.trim(u8, title, " \r\t\n");
    if (t.len > 0) {
        try out.appendSlice(allocator, "#EXTINF:-1");
        if (logo) |l| {
            try out.appendSlice(allocator, " tvg-logo=\"");
            try appendSanitized(out, allocator, l, true);
            try out.append(allocator, '"');
        }
        if (group) |g| {
            try out.appendSlice(allocator, " group-title=\"");
            try appendSanitized(out, allocator, g, true);
            try out.append(allocator, '"');
        }
        try out.append(allocator, ',');
        try appendSanitized(out, allocator, t, false);
        try out.append(allocator, '\n');
    }
    try appendSanitized(out, allocator, std.mem.trim(u8, url, " \r\t\n"), false);
    try out.append(allocator, '\n');
}

fn appendSanitized(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    s: []const u8,
    in_attr: bool,
) !void {
    for (s) |ch| {
        const safe: u8 = switch (ch) {
            '\n', '\r' => ' ',
            '"' => if (in_attr) '\'' else ch,
            else => ch,
        };
        try out.append(allocator, safe);
    }
}

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

test "writer: header, -1 duration, attrs, and round-trip through the parser" {
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

    const text = try pl.serialize(alloc);
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "#EXTM3U\n"));
    try std.testing.expect(std.mem.indexOf(u8, text,
        "#EXTINF:-1 tvg-logo=\"http://logo.png\" group-title=\"News\",CNN\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "#EXTINF:-1,BBC World\n") != null);

    // Round-trip: reparse the emitted text, get identical entries back.
    var pl2 = M3UPlaylist.init(alloc);
    defer pl2.deinit();
    try pl2.parse(text);
    try std.testing.expectEqual(@as(usize, 2), pl2.entries.items.len);
    try std.testing.expectEqualStrings("CNN", pl2.entries.items[0].title);
    try std.testing.expectEqualStrings("http://stream.cnn.com/live.m3u8", pl2.entries.items[0].url);
    try std.testing.expectEqualStrings("http://logo.png", pl2.entries.items[0].logoUrl.?);
    try std.testing.expectEqualStrings("News", pl2.entries.items[0].group.?);
    try std.testing.expectEqualStrings("BBC World", pl2.entries.items[1].title);
}

test "writer: comma and # in titles are emitted verbatim on the EXTINF line" {
    const alloc = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try appendEntryLines(&out, alloc, "Hello, World", "http://a/1.mp4", null, null);
    try appendEntryLines(&out, alloc, "#1 Hits", "http://a/2.mp4", null, null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "#EXTINF:-1,Hello, World\nhttp://a/1.mp4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "#EXTINF:-1,#1 Hits\nhttp://a/2.mp4\n") != null);
}

test "writer: blank title emits a bare URL line (parser re-derives from filename)" {
    const alloc = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try appendEntryLines(&out, alloc, "   ", "http://a/song.mp3", null, null);
    try std.testing.expectEqualStrings("http://a/song.mp3\n", out.items);
}

test "writer: newlines in fields and quotes in attrs are sanitized" {
    const alloc = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try appendEntryLines(&out, alloc, "Two\nLines", "http://a/3.mp4", null, "Say \"News\"");
    try std.testing.expect(std.mem.indexOf(u8, out.items,
        "#EXTINF:-1 group-title=\"Say 'News'\",Two Lines\nhttp://a/3.mp4\n") != null);
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
