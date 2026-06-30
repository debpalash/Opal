const std = @import("std");

// ══════════════════════════════════════════════════════════
// Opal v2 — Shared Types
//
// Replaces hundreds of foo_buf + foo_len pairs with a
// single generic BoundedString(N). Provides shared
// MediaItem and PosterState used across all content providers.
// ══════════════════════════════════════════════════════════

/// Fixed-capacity string that replaces the buf[N] + len pattern.
pub fn BoundedString(comptime N: usize) type {
    return struct {
        buf: [N]u8 = std.mem.zeroes([N]u8),
        len: usize = 0,

        const Self = @This();

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn sliceZ(self: *Self) [:0]const u8 {
            if (self.len < N) self.buf[self.len] = 0;
            return self.buf[0..self.len :0];
        }

        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, N);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }

        pub fn clear(self: *Self) void {
            @memset(&self.buf, 0);
            self.len = 0;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn eql(self: *const Self, other: []const u8) bool {
            if (self.len != other.len) return false;
            return std.mem.eql(u8, self.buf[0..self.len], other);
        }

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll(self.buf[0..self.len]);
        }
    };
}

// Common string sizes
pub const Str16 = BoundedString(16);
pub const Str32 = BoundedString(32);
pub const Str64 = BoundedString(64);
pub const Str128 = BoundedString(128);
pub const Str256 = BoundedString(256);
pub const Str512 = BoundedString(512);
pub const Str1K = BoundedString(1024);
pub const Str2K = BoundedString(2048);

/// Poster/thumbnail texture state shared across all media items.
pub const PosterState = struct {
    fetching: bool = false,
    pixels: ?[]u8 = null,
    w: u32 = 0,
    h: u32 = 0,
    tex_id: u64 = 0, // opaque texture handle
    loaded: bool = false,
};

/// Media type classification.
pub const MediaType = enum {
    movie,
    tv,
    anime,
    comic,
    music,
    live,
    other,
};

/// Generic media item used by content providers.
pub const MediaItem = struct {
    id: Str64 = .{},
    title: Str128 = .{},
    overview: Str512 = .{},
    poster_url: Str256 = .{},
    stream_url: Str512 = .{},
    year: Str16 = .{},
    score: f32 = 0,
    episodes: u16 = 0,
    media_type: MediaType = .other,
    poster: PosterState = .{},
    expanded: bool = false,
};

/// Stream resolution result.
pub const StreamResult = struct {
    url: Str512 = .{},
    title: Str128 = .{},
    quality: Str32 = .{},
    source: Str64 = .{},
    seeders: u32 = 0,
    size_mb: u32 = 0,
};
