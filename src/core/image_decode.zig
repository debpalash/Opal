//! Bounded stb_image/libwebp adapter for untrusted raster content.
//!
//! Every path probes dimensions and applies its content-class budget before
//! stb is allowed to allocate an RGBA buffer.

const std = @import("std");
const dvui = @import("dvui");
const limits = @import("image_limits_pure.zig");

extern fn opal_webp_info(data: [*]const u8, size: usize, width: *c_int, height: *c_int) c_int;
extern fn opal_webp_decode_rgba(data: [*]const u8, size: usize, width: c_int, height: c_int, rgba_bytes: usize) [*c]u8;

pub const DecodedRgba = struct {
    pixels: [*c]u8,
    width: c_int,
    height: c_int,
    rgba_len: usize,

    pub fn deinit(self: DecodedRgba) void {
        dvui.c.stbi_image_free(self.pixels);
    }
};

fn decode(data: []const u8, max_edge: u64, max_bytes: u64) ?DecodedRgba {
    if (data.len == 0 or data.len > std.math.maxInt(c_int)) return null;
    if (limits.isWebP(data)) {
        var width: c_int = 0;
        var height: c_int = 0;
        if (opal_webp_info(data.ptr, data.len, &width, &height) == 0) return null;
        const bytes = limits.rgbaBytes(width, height, max_edge, max_bytes) orelse return null;
        // The C shim allocates with malloc, matching legacy stbi_image_free
        // callers as well as DecodedRgba.deinit. No WebP-owned buffers escape.
        const pixels = opal_webp_decode_rgba(data.ptr, data.len, width, height, bytes);
        if (pixels == null) return null;
        return .{ .pixels = pixels, .width = width, .height = height, .rgba_len = bytes };
    }

    var info_w: c_int = 0;
    var info_h: c_int = 0;
    var info_comp: c_int = 0;
    if (dvui.c.stbi_info_from_memory(data.ptr, @intCast(data.len), &info_w, &info_h, &info_comp) == 0) return null;
    const rgba_len = limits.rgbaBytes(info_w, info_h, max_edge, max_bytes) orelse return null;

    var width: c_int = 0;
    var height: c_int = 0;
    var comp: c_int = 0;
    const pixels = dvui.c.stbi_load_from_memory(data.ptr, @intCast(data.len), &width, &height, &comp, 4);
    if (pixels == null) return null;
    if (width != info_w or height != info_h or limits.rgbaBytes(width, height, max_edge, max_bytes) != rgba_len) {
        dvui.c.stbi_image_free(pixels);
        return null;
    }
    return .{ .pixels = pixels, .width = width, .height = height, .rgba_len = rgba_len };
}

pub fn cover(data: []const u8) ?DecodedRgba {
    return decode(data, limits.COVER_MAX_EDGE, limits.COVER_MAX_RGBA_BYTES);
}

pub fn browserFrame(data: []const u8) ?DecodedRgba {
    return decode(data, limits.BROWSER_FRAME_MAX_EDGE, limits.BROWSER_FRAME_MAX_RGBA_BYTES);
}

pub fn comicPage(data: []const u8) ?DecodedRgba {
    return decode(data, limits.COMIC_PAGE_MAX_EDGE, limits.COMIC_PAGE_MAX_RGBA_BYTES);
}
