//! Pure RGBA cover downscaler for background poster workers.
//! Reduces oversized remote covers (e.g. 2000x3000 = 24 MB RGBA) to <=512px
//! before UI handoff, cutting VRAM, premultiply CPU, and GPU upload by 8x-34x.

const std = @import("std");

pub const COVER_TARGET_MAX_EDGE: u32 = 512;

pub const Dims = struct {
    w: u32,
    h: u32,
};

/// Compute aspect-preserving target dimensions bounded by `max_edge`.
/// Returns the original dimensions when already within budget.
pub fn fitDimensions(w: u32, h: u32, max_edge: u32) Dims {
    if (w == 0 or h == 0 or max_edge == 0) return .{ .w = 0, .h = 0 };
    if (w <= max_edge and h <= max_edge) return .{ .w = w, .h = h };
    if (w >= h) {
        const scaled_h: u32 = @intCast(@max(@as(u64, 1), (@as(u64, h) * max_edge + w / 2) / w));
        return .{ .w = max_edge, .h = scaled_h };
    } else {
        const scaled_w: u32 = @intCast(@max(@as(u64, 1), (@as(u64, w) * max_edge + h / 2) / h));
        return .{ .w = scaled_w, .h = max_edge };
    }
}

/// Box-area downscale of straight RGBA8888 pixels from (src_w, src_h) into
/// (dst_w, dst_h). Each destination pixel averages the covered source box.
pub fn downscaleRgba(src: []const u8, src_w: u32, src_h: u32, dst: []u8, dst_w: u32, dst_h: u32) void {
    std.debug.assert(dst_w > 0 and dst_h > 0 and src_w > 0 and src_h > 0);
    std.debug.assert(src.len >= @as(usize, src_w) * src_h * 4);
    std.debug.assert(dst.len >= @as(usize, dst_w) * dst_h * 4);

    const sw: usize = src_w;
    const sh: usize = src_h;
    const dw: usize = dst_w;
    const dh: usize = dst_h;

    var dy: usize = 0;
    while (dy < dh) : (dy += 1) {
        const sy0 = (dy * sh) / dh;
        const sy1 = @max(sy0 + 1, @min(sh, ((dy + 1) * sh + dh - 1) / dh));
        var dx: usize = 0;
        while (dx < dw) : (dx += 1) {
            const sx0 = (dx * sw) / dw;
            const sx1 = @max(sx0 + 1, @min(sw, ((dx + 1) * sw + dw - 1) / dw));
            var r: u64 = 0;
            var g: u64 = 0;
            var b: u64 = 0;
            var a: u64 = 0;
            var count: u64 = 0;

            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var row = (sy * sw + sx0) * 4;
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    r += src[row];
                    g += src[row + 1];
                    b += src[row + 2];
                    a += src[row + 3];
                    row += 4;
                    count += 1;
                }
            }

            const out = (dy * dw + dx) * 4;
            const half = count / 2;
            dst[out] = @intCast((r + half) / count);
            dst[out + 1] = @intCast((g + half) / count);
            dst[out + 2] = @intCast((b + half) / count);
            dst[out + 3] = @intCast((a + half) / count);
        }
    }
}

test "fitDimensions preserves small images and scales large posters proportionally" {
    try std.testing.expectEqual(Dims{ .w = 300, .h = 450 }, fitDimensions(300, 450, 512));
    try std.testing.expectEqual(Dims{ .w = 341, .h = 512 }, fitDimensions(2000, 3000, 512));
    try std.testing.expectEqual(Dims{ .w = 512, .h = 288 }, fitDimensions(1920, 1080, 512));
    try std.testing.expectEqual(Dims{ .w = 512, .h = 1 }, fitDimensions(4000, 2, 512));
    try std.testing.expectEqual(Dims{ .w = 0, .h = 0 }, fitDimensions(0, 100, 512));
}

test "downscaleRgba averages 2x2 blocks accurately" {
    // 2x2 image: (10,20,30,255), (30,40,50,255), (50,60,70,255), (70,80,90,255)
    // Average: (40, 50, 60, 255)
    const src = [_]u8{
        10, 20, 30, 255, 30, 40, 50, 255,
        50, 60, 70, 255, 70, 80, 90, 255,
    };
    var dst: [4]u8 = undefined;
    downscaleRgba(&src, 2, 2, &dst, 1, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 40, 50, 60, 255 }, &dst);
}

test "downscaleRgba preserves solid color across non-integer ratio" {
    var src: [10 * 15 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        src[i] = 123;
        src[i + 1] = 45;
        src[i + 2] = 200;
        src[i + 3] = 255;
    }
    var dst: [3 * 5 * 4]u8 = undefined;
    downscaleRgba(&src, 10, 15, &dst, 3, 5);
    var j: usize = 0;
    while (j < dst.len) : (j += 4) {
        try std.testing.expectEqualSlices(u8, &[_]u8{ 123, 45, 200, 255 }, dst[j .. j + 4]);
    }
}
