//! In-memory Search facets and deterministic view ordering. No provider settings.
const std = @import("std");
pub const ContentKind = enum { all, video, movies, shows, anime, comics, books, music, podcasts, radio, live_tv, visual_novels };
pub const Availability = enum { all, playable, torrents, library };
pub const Sort = enum { relevance, quality, seeds, size, peers, health };
pub const Source = enum { jellyfin, stremio, torrent, anime, youtube, local, tmdb, comics, livetv, music, radio, podcast, plex, plugin, novels, vndb, audiobooks, opds };
pub const Provider = struct {
    tag: [64]u8 = @splat(0),
    len: u8 = 0,
    pub fn init(label: []const u8) Provider {
        var result: Provider = .{};
        if (std.mem.indexOf(u8, label, "://") != null or std.mem.indexOfScalar(u8, label, '@') != null) return result;
        // Tags contain provider identities, never URLs or credentials.
        for (label) |char| {
            if (result.len == result.tag.len) break;
            if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.') {
                result.tag[result.len] = std.ascii.toLower(char);
                result.len += 1;
            }
        }
        return result;
    }
    pub fn name(self: *const Provider) []const u8 {
        return self.tag[0..@min(self.len, self.tag.len)];
    }
    pub fn eql(a: Provider, b: Provider) bool {
        return std.mem.eql(u8, a.name(), b.name());
    }
};
pub const Filters = struct {
    content: ContentKind = .all,
    availability: Availability = .all,
    min_quality: u8 = 0,
    min_seeds: u16 = 0,
    min_size_bytes: u64 = 0,
    max_size_bytes: u64 = 0,
    provider: ?Provider = null,
};
pub const Item = struct {
    kind: ContentKind = .video,
    playable: bool = false,
    torrent: bool = false,
    library: bool = false,
    source: Source = .torrent,
    provider: Provider = .{},
    quality: u8 = 0,
    seeds: u16 = 0,
    leech: u16 = 0,
    size_bytes: u64 = 0,
    score: u32 = 9999,
    key: u64 = 0,
};
pub fn localKind(path: []const u8, typed_kind: []const u8) ContentKind {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".m4b")) return .books;
    inline for (.{ ".mp3", ".flac", ".m4a", ".wav", ".opus", ".aac", ".ogg", ".aiff" }) |audio| {
        if (std.ascii.eqlIgnoreCase(extension, audio)) return .music;
    }
    inline for (.{ ".pdf", ".epub", ".txt", ".cbz", ".cbr" }) |book| {
        if (std.ascii.eqlIgnoreCase(extension, book)) return .books;
    }
    return kindFor(.local, typed_kind);
}
pub fn localPlayable(path: []const u8) bool {
    if (path.len == 0) return false;
    const extension = std.fs.path.extension(path);
    inline for (.{ ".pdf", ".epub", ".txt", ".cbz", ".cbr" }) |book| {
        if (std.ascii.eqlIgnoreCase(extension, book)) return false;
    }
    return true;
}
pub fn kindFor(source: Source, catalog_kind: []const u8) ContentKind {
    return switch (source) {
        .anime => .anime,
        .comics => .comics,
        .novels, .opds, .audiobooks => .books,
        .music => .music,
        .podcast => .podcasts,
        .radio => .radio,
        .livetv => .live_tv,
        .vndb => .visual_novels,
        else => if (std.ascii.eqlIgnoreCase(catalog_kind, "audio") or std.ascii.eqlIgnoreCase(catalog_kind, "track")) .music else if (std.ascii.eqlIgnoreCase(catalog_kind, "movie")) .movies else if (std.ascii.eqlIgnoreCase(catalog_kind, "tv") or std.ascii.eqlIgnoreCase(catalog_kind, "episode") or std.ascii.eqlIgnoreCase(catalog_kind, "series")) .shows else .video,
    };
}
pub fn replaceCachedRows(count: *usize, cached: *bool) void {
    if (cached.*) {
        count.* = 0;
        cached.* = false;
    }
}
pub fn sameTypedWork(kind_a: []const u8, id_a: i32, kind_b: []const u8, id_b: i32) bool {
    return id_a > 0 and id_a == id_b and kind_a.len > 0 and std.mem.eql(u8, kind_a, kind_b);
}
pub fn torrentQueueable(url: []const u8, name: []const u8, size_bytes: u64) bool {
    return std.mem.startsWith(u8, url, "magnet:?") and @import("torrent_risk_pure.zig").assess(name, @floatFromInt(size_bytes)).risk != .block;
}
pub fn matches(item: Item, filters: Filters) bool {
    if (filters.content != .all and item.kind != filters.content) {
        if (filters.content != .video or !switch (item.kind) {
            .video, .movies, .shows, .anime, .live_tv => true,
            else => false,
        }) return false;
    }
    switch (filters.availability) {
        .all => {},
        .playable => if (!item.playable) return false,
        .torrents => if (!item.torrent) return false,
        .library => if (!item.library) return false,
    }
    if (filters.provider) |provider| if (!Provider.eql(provider, item.provider)) return false;
    if (item.quality < filters.min_quality or item.seeds < filters.min_seeds) return false;
    if ((filters.min_size_bytes != 0 or filters.max_size_bytes != 0) and item.size_bytes == 0) return false;
    if (item.size_bytes < filters.min_size_bytes) return false;
    if (filters.max_size_bytes != 0 and item.size_bytes > filters.max_size_bytes) return false;
    return true;
}
pub fn activeCount(filters: Filters) usize {
    return @as(usize, @intFromBool(filters.content != .all)) + @intFromBool(filters.availability != .all) + @intFromBool(filters.min_quality != 0) + @intFromBool(filters.min_seeds != 0) + @intFromBool(filters.min_size_bytes != 0 or filters.max_size_bytes != 0) + @intFromBool(filters.provider != null);
}
pub fn lessThan(sort: Sort, a: Item, b: Item) bool {
    const comparison: std.math.Order = switch (sort) {
        .relevance => std.math.order(b.score, a.score),
        .quality => std.math.order(a.quality, b.quality),
        .seeds => std.math.order(a.seeds, b.seeds),
        .size => std.math.order(a.size_bytes, b.size_bytes),
        .peers => std.math.order(@as(u32, a.seeds) + a.leech, @as(u32, b.seeds) + b.leech),
        .health => blk: {
            const at = @max(@as(u64, a.seeds) + a.leech, 1);
            const bt = @max(@as(u64, b.seeds) + b.leech, 1);
            break :blk std.math.order(@as(u64, a.seeds) * bt, @as(u64, b.seeds) * at);
        },
    };
    if (comparison != .eq) return comparison == .gt;
    if (a.score != b.score) return a.score < b.score;
    return a.key < b.key;
}
/// Admission to the bounded global relevance set. Late strong providers may
/// evict its worst row; transport arrival order never breaks equal-score ties.
pub fn admitTopK(count: usize, capacity: usize, candidate: Item, worst: Item) bool {
    return capacity > 0 and (count < capacity or lessThan(.relevance, candidate, worst));
}
pub const Range = struct { start: usize, end: usize };
pub fn visibleRange(count: usize, offset: f32, height: f32, row_height: f32) Range {
    if (!std.math.isFinite(offset) or !std.math.isFinite(height) or !std.math.isFinite(row_height) or row_height <= 0 or height <= 0) return .{ .start = 0, .end = 0 };
    const start: usize = @intFromFloat(@min(@as(f32, @floatFromInt(count)), @floor(@max(0, offset) / row_height)));
    const shown: usize = @intFromFloat(@min(@as(f32, @floatFromInt(count)), @ceil(height / row_height) + 2));
    return .{ .start = start, .end = @min(count, start + shown) };
}
test "facets are independent owned values and unknown sizes do not satisfy bounds" {
    const item: Item = .{ .kind = .movies, .playable = true, .provider = Provider.init("YTS"), .quality = 3 };
    try std.testing.expect(matches(item, .{ .content = .video, .availability = .playable }));
    try std.testing.expect(!matches(item, .{ .availability = .torrents }));
    try std.testing.expect(!matches(item, .{ .max_size_bytes = 100 }));
    try std.testing.expect(matches(item, .{ .provider = Provider.init("yts") }));
    try std.testing.expectEqual(@as(usize, 2), activeCount(.{ .content = .books, .min_seeds = 1 }));
}
test "all streamed sorts tie break by stable identity and preserve relevance" {
    const a: Item = .{ .key = 1, .score = 10, .seeds = 10, .leech = 1, .size_bytes = 20, .quality = 3 };
    const b: Item = .{ .key = 2, .score = 20, .seeds = 2, .leech = 8, .size_bytes = 5, .quality = 2 };
    inline for (std.meta.tags(Sort)) |sort| {
        try std.testing.expect(lessThan(sort, a, b));
        try std.testing.expect(!lessThan(sort, b, a));
        var tied = a;
        tied.key = 3;
        try std.testing.expect(lessThan(sort, a, tied));
        try std.testing.expect(!lessThan(sort, a, a));
    }
}
test "viewport clamps and does not render the entire bounded catalog" {
    const range = visibleRange(96, 480, 240, 48);
    try std.testing.expectEqual(@as(usize, 10), range.start);
    try std.testing.expectEqual(@as(usize, 17), range.end);
    try std.testing.expectEqual(@as(usize, 0), visibleRange(96, 0, 100, 0).end);
    try std.testing.expectEqual(@as(usize, 96), visibleRange(96, 100000, 240, 48).end);
}

test "typed source facets never infer movies or shows from titles" {
    try std.testing.expectEqual(ContentKind.video, kindFor(.torrent, ""));
    try std.testing.expectEqual(ContentKind.movies, kindFor(.tmdb, "movie"));
    try std.testing.expectEqual(ContentKind.shows, kindFor(.jellyfin, "Episode"));
    try std.testing.expectEqual(ContentKind.visual_novels, kindFor(.vndb, ""));
    try std.testing.expectEqual(ContentKind.books, kindFor(.audiobooks, ""));
    try std.testing.expect(!matches(.{ .kind = .visual_novels }, .{ .availability = .playable }));
}

test "work grouping requires matching positive typed IDs and provider tags exclude credentials" {
    try std.testing.expect(sameTypedWork("movie", 42, "movie", 42));
    try std.testing.expect(!sameTypedWork("movie", 42, "tv", 42));
    try std.testing.expect(!sameTypedWork("movie", 0, "movie", 0));
    try std.testing.expect(!sameTypedWork("", 42, "", 42));
    try std.testing.expectEqual(@as(u8, 0), Provider.init("https://user:secret@host").len);
    try std.testing.expectEqual(@as(u8, 0), Provider.init("user@host").len);
}

test "first live result replaces even a full cached wave and size range is one facet" {
    var count: usize = 96;
    var cached = true;
    replaceCachedRows(&count, &cached);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expect(!cached);
    count = 1;
    replaceCachedRows(&count, &cached);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), activeCount(.{ .min_size_bytes = 10, .max_size_bytes = 20 }));
}

test "torrent queue accepts magnets and refuses detail pages and blocked executables" {
    try std.testing.expect(torrentQueueable("magnet:?xt=urn:btih:123", "Film 1080p", 2 * 1024 * 1024 * 1024));
    try std.testing.expect(!torrentQueueable("https://index.test/film", "Film 1080p", 2 * 1024 * 1024 * 1024));
    try std.testing.expect(!torrentQueueable("magnet:?xt=urn:btih:123", "Film.exe", 2 * 1024 * 1024 * 1024));
}

test "local file formats separate audio books and reader-only files" {
    try std.testing.expectEqual(ContentKind.music, localKind("/media/title.MP3", "movie"));
    try std.testing.expectEqual(ContentKind.books, localKind("/media/title.m4b", ""));
    try std.testing.expect(localPlayable("/media/title.m4b"));
    try std.testing.expectEqual(ContentKind.books, localKind("/media/title.pdf", ""));
    try std.testing.expect(!localPlayable("/media/title.pdf"));
    try std.testing.expectEqual(ContentKind.video, localKind("/media/title.2026.mkv", ""));
}

/// Bounded single-line text for fixed-height result rows. Invalid bytes become
/// '?' and truncated copies end at a complete UTF-8 codepoint.
pub fn singleLine(out: []u8, text: []const u8) []const u8 {
    var read: usize = 0;
    var written: usize = 0;
    while (read < text.len and written < out.len) {
        const byte = text[read];
        if (byte < 0x80) {
            out[written] = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
            written += 1;
            read += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        if (length == 0 or read + length > text.len) {
            out[written] = '?';
            written += 1;
            read += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(text[read..][0..length]) catch {
            out[written] = '?';
            written += 1;
            read += 1;
            continue;
        };
        if (written + length > out.len) break;
        @memcpy(out[written..][0..length], text[read..][0..length]);
        written += length;
        read += length;
    }
    return out[0..written];
}

test "single-line fixed rows normalize controls and preserve bounded UTF8" {
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a b c d e ", singleLine(&out, "a\nb\tc\rd\x00e\x7f"));
    try std.testing.expectEqualStrings("x", singleLine(out[0..3], "x東"));
    try std.testing.expectEqualStrings("x東", singleLine(out[0..4], "x東"));
    try std.testing.expectEqualStrings("?", singleLine(&out, "\xff"));
    try std.testing.expectEqualStrings("", singleLine(out[0..0], "title"));
}

test "bounded relevance admits a late exact match and ties use stable keys" {
    const weakest: Item = .{ .score = 500, .key = 100 };
    try std.testing.expect(admitTopK(96, 96, .{ .score = 1, .key = 200 }, weakest));
    try std.testing.expect(!admitTopK(96, 96, .{ .score = 501, .key = 1 }, weakest));
    try std.testing.expect(admitTopK(96, 96, .{ .score = 500, .key = 99 }, weakest));
    try std.testing.expect(!admitTopK(96, 96, .{ .score = 500, .key = 101 }, weakest));
    try std.testing.expect(!admitTopK(0, 0, .{}, .{}));
    try std.testing.expect(admitTopK(95, 96, .{ .score = 9999 }, weakest));
}
