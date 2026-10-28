//! Cached native text shaping for multilingual lyric lines on macOS.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const enabled = builtin.os.tag == .macos and !@import("build_options").headless;
extern fn opal_lyrics_raster([*]const u8, usize, f32, f32, f32, u32, *u32, *u32) ?[*]align(4) const dvui.Color.PMA;
extern fn opal_lyrics_raster_free([*]const dvui.Color.PMA) void;

pub fn line(text: []const u8, id: usize, color: dvui.Color) void {
    const size = dvui.themeGet().font_body.size;
    if (enabled and text.len > 0) {
        const width = @max(32, @floor(dvui.parentGet().data().contentRect().w - 16));
        const scale = @max(1, dvui.windowNaturalScale());
        const rgb = (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;
        var hash = std.hash.Wyhash.init(0x4c5952494353);
        hash.update(text);
        for ([_]f32{ width, size, scale }) |v| hash.update(std.mem.asBytes(&v));
        hash.update(std.mem.asBytes(&rgb));
        const key = hash.final();
        const texture = dvui.textureGetCached(key) orelse blk: {
            var w: u32 = 0;
            var h: u32 = 0;
            const pixels = opal_lyrics_raster(text.ptr, text.len, width, size, scale, rgb, &w, &h) orelse break :blk null;
            defer opal_lyrics_raster_free(pixels);
            const tex = dvui.Texture.create(pixels[0 .. @as(usize, w) * h], w, h, .linear, .rgba_32) catch break :blk null;
            dvui.textureAddToCache(key, tex);
            break :blk tex;
        };
        if (texture) |tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
                .id_extra = id,
                .label = .{ .text = text },
                .min_size_content = .{ .w = @as(f32, @floatFromInt(tex.width)) / scale, .h = @as(f32, @floatFromInt(tex.height)) / scale },
                .padding = .{ .x = 2, .y = 3, .w = 2, .h = 3 },
            });
            return;
        }
    }
    _ = dvui.label(@src(), "{s}", .{text}, .{ .id_extra = id, .color_text = color, .expand = .horizontal });
}
