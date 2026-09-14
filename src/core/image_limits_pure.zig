//! Allocation policy for untrusted raster images.
//!
//! Compressed byte limits alone do not prevent a tiny decompression bomb from
//! expanding into hundreds of megabytes. Call this with dimensions obtained
//! from the decoder's header probe before requesting RGBA pixels.

const std = @import("std");

pub const COVER_MAX_EDGE: u64 = 4096;
pub const COVER_MAX_RGBA_BYTES: u64 = 24 * 1024 * 1024;
pub const BROWSER_FRAME_MAX_EDGE: u64 = 8192;
pub const BROWSER_FRAME_MAX_RGBA_BYTES: u64 = 128 * 1024 * 1024;
pub const COMIC_PAGE_MAX_EDGE: u64 = 32 * 1024;
pub const COMIC_PAGE_MAX_RGBA_BYTES: u64 = 128 * 1024 * 1024;

/// Return the exact RGBA allocation size when dimensions fit both the edge and
/// byte budget. Invalid, overflowing, or excessive dimensions return null.
pub fn rgbaBytes(width: i64, height: i64, max_edge: u64, max_bytes: u64) ?usize {
    if (width <= 0 or height <= 0) return null;
    const w: u64 = @intCast(width);
    const h: u64 = @intCast(height);
    if (w > max_edge or h > max_edge) return null;
    const pixels = std.math.mul(u64, w, h) catch return null;
    const bytes = std.math.mul(u64, pixels, 4) catch return null;
    if (bytes > max_bytes or bytes > std.math.maxInt(usize)) return null;
    return @intCast(bytes);
}

pub fn coverRgbaBytes(width: i64, height: i64) ?usize {
    return rgbaBytes(width, height, COVER_MAX_EDGE, COVER_MAX_RGBA_BYTES);
}

pub fn browserFrameRgbaBytes(width: i64, height: i64) ?usize {
    return rgbaBytes(width, height, BROWSER_FRAME_MAX_EDGE, BROWSER_FRAME_MAX_RGBA_BYTES);
}

pub fn comicPageRgbaBytes(width: i64, height: i64) ?usize {
    return rgbaBytes(width, height, COMIC_PAGE_MAX_EDGE, COMIC_PAGE_MAX_RGBA_BYTES);
}

test "cover art dimensions are bounded before RGBA allocation" {
    try std.testing.expectEqual(@as(?usize, 500 * 750 * 4), coverRgbaBytes(500, 750));
    try std.testing.expectEqual(@as(?usize, 2000 * 3000 * 4), coverRgbaBytes(2000, 3000));
    try std.testing.expect(coverRgbaBytes(4096, 4096) == null);
    try std.testing.expect(coverRgbaBytes(8192, 1) == null);
    try std.testing.expect(coverRgbaBytes(0, 100) == null);
    try std.testing.expect(coverRgbaBytes(-1, 100) == null);
}

test "generic policy rejects multiplication overflow" {
    try std.testing.expect(rgbaBytes(std.math.maxInt(i64), std.math.maxInt(i64), std.math.maxInt(u64), std.math.maxInt(u64)) == null);
}

test "browser frames and long comic pages have distinct bounded budgets" {
    try std.testing.expectEqual(@as(?usize, 7680 * 4320 * 4), browserFrameRgbaBytes(7680, 4320));
    try std.testing.expect(browserFrameRgbaBytes(8192, 8192) == null);
    try std.testing.expectEqual(@as(?usize, 1000 * 20_000 * 4), comicPageRgbaBytes(1000, 20_000));
    try std.testing.expect(comicPageRgbaBytes(2000, 20_000) == null);
    try std.testing.expect(comicPageRgbaBytes(1000, 40_000) == null);
}
