//! Isolated shared-decoder/GPU proof. Synthetic lossless pixels are embedded;
//! OPAL_WEBP_PROVIDER_FILE optionally supplies an independently fetched cover.
const std = @import("std");
const dvui = @import("dvui");
const decode = @import("image_decode.zig");
const io = @import("io_global.zig");
const alloc = @import("alloc.zig").allocator;
extern fn opal_webp_info(data: [*]const u8, size: usize, width: *c_int, height: *c_int) c_int;
const fixture = @embedFile("testdata/lossless-cover.webp");
var textures: [2]?dvui.Texture = .{ null, null };

fn checkDecoder() !void {
    const cover = decode.cover(fixture) orelse return error.WebPDecodeFailed;
    defer cover.deinit();
    try std.testing.expectEqual(@as(c_int, 32), cover.width);
    try std.testing.expectEqual(@as(c_int, 32), cover.height);
    try std.testing.expectEqual(@as(usize, 4096), cover.rgba_len);
    const points = [_]struct { x: usize, y: usize, rgba: [4]u8 }{
        .{ .x = 4, .y = 4, .rgba = .{ 255, 0, 0, 255 } },  .{ .x = 20, .y = 4, .rgba = .{ 0, 255, 0, 255 } },
        .{ .x = 4, .y = 20, .rgba = .{ 0, 0, 255, 255 } }, .{ .x = 20, .y = 20, .rgba = .{ 255, 255, 0, 128 } },
    };
    for (points) |p| try std.testing.expectEqualSlices(u8, &p.rgba, cover.pixels[(p.y * 32 + p.x) * 4 ..][0..4]);
    const page = decode.comicPage(fixture) orelse return error.ComicWebPDecodeFailed;
    defer page.deinit();
    const frame = decode.browserFrame(fixture) orelse return error.FrameWebPDecodeFailed;
    defer frame.deinit();
    try std.testing.expect(decode.cover(fixture[0 .. fixture.len - 1]) == null);
    try std.testing.expect(decode.cover("RIFFbrokenWEBP") == null);
    // VP8L header dimensions are available before full decode. Set 8192x8192:
    // every shared content-class byte budget rejects this before allocation.
    var oversized: [fixture.len]u8 = undefined;
    @memcpy(&oversized, fixture);
    try std.testing.expectEqualSlices(u8, "VP8L", oversized[12..16]);
    const dimensions: u32 = 8191 | (8191 << 14) | (1 << 28);
    std.mem.writeInt(u32, oversized[21..25], dimensions, .little);
    var probed_width: c_int = 0;
    var probed_height: c_int = 0;
    try std.testing.expectEqual(@as(c_int, 1), opal_webp_info(&oversized, oversized.len, &probed_width, &probed_height));
    try std.testing.expectEqual(@as(c_int, 8192), probed_width);
    try std.testing.expectEqual(@as(c_int, 8192), probed_height);
    try std.testing.expect(decode.cover(&oversized) == null);
    try std.testing.expect(decode.comicPage(&oversized) == null);
    try std.testing.expect(decode.browserFrame(&oversized) == null);
}
fn upload(bytes: []const u8) !dvui.Texture {
    const image = decode.cover(bytes) orelse return error.WebPDecodeFailed;
    defer image.deinit();
    var pixels: ?[]u8 = try std.heap.c_allocator.alloc(u8, image.rgba_len);
    defer if (pixels) |left| std.heap.c_allocator.free(left);
    @memcpy(pixels.?, image.pixels[0..image.rgba_len]);
    var texture: ?dvui.Texture = null;
    try std.testing.expect(@import("poster.zig").uploadIfReady(&pixels, @intCast(image.width), @intCast(image.height), &texture));
    try std.testing.expect(pixels == null);
    return texture.?;
}
fn checkGpuAlpha(texture: dvui.Texture) !void {
    const black: [4]u8 = .{ 0, 0, 0, 255 };
    const background = try dvui.Texture.fromImageSource(.{ .pixels = .{ .rgba = &black, .width = 1, .height = 1 } });
    defer dvui.textureDestroyLater(background);
    var picture = dvui.Picture.start(.{ .w = 32, .h = 32 }) orelse return error.GpuProbeUnavailable;
    defer picture.deinit();
    var recording = true;
    defer if (recording) picture.stop();
    try dvui.renderTexture(background, .{ .r = .{ .w = 32, .h = 32 } }, .{});
    try dvui.renderTexture(texture, .{ .r = .{ .w = 32, .h = 32 } }, .{});
    picture.stop();
    recording = false;
    const pixels = try dvui.textureReadTarget(dvui.currentWindow().lifo(), picture.texture);
    defer dvui.currentWindow().lifo().free(pixels);
    const solid = pixels[4 * 32 + 4];
    try std.testing.expectEqual(@as(u8, 255), solid.r);
    try std.testing.expectEqual(@as(u8, 0), solid.g);
    const translucent = pixels[20 * 32 + 20];
    // Straight yellow at alpha128 composited onto black must be half bright.
    try std.testing.expectEqual(@as(u8, 128), translucent.r);
    try std.testing.expectEqual(@as(u8, 128), translucent.g);
    try std.testing.expectEqual(@as(u8, 0), translucent.b);
    try std.testing.expectEqual(@as(u8, 255), translucent.a);
}

fn draw() !void {
    if (textures[0] == null) {
        textures[0] = try upload(fixture);
        try checkGpuAlpha(textures[0].?);
    }
    if (textures[1] == null) {
        if (io.getenv("OPAL_WEBP_PROVIDER_FILE")) |path| {
            const bytes = try io.cwdReadFileAlloc(path, alloc, 1024 * 1024);
            defer alloc.free(bytes);
            const image = decode.cover(bytes) orelse return error.ProviderWebPDecodeFailed;
            defer image.deinit();
            try std.testing.expectEqual(@as(c_int, 204), image.width);
            try std.testing.expectEqual(@as(c_int, 325), image.height);
            textures[1] = try upload(bytes);
        }
    }
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(20), .color_fill = .{ .r = 24, .g = 24, .b = 24 }, .background = true });
    defer page.deinit();
    _ = dvui.label(@src(), "Shared WebP decoder / actual GPU upload", .{}, .{ .color_text = .{ .r = 245, .g = 245, .b = 245 } });
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    for (textures, 0..) |optional, index| {
        const texture = optional orelse continue;
        var column = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = index, .padding = dvui.Rect.all(12) });
        defer column.deinit();
        _ = dvui.label(@src(), "{s}", .{if (index == 0) "Synthetic lossless RGBA / 32×32" else "Real Wuxia cover / 204×325"}, .{ .id_extra = index, .font = dvui.themeGet().font_body.withSize(12), .color_text = .{ .r = 210, .g = 210, .b = 210 } });
        _ = dvui.image(@src(), .{ .source = .{ .texture = texture }, .shrink = .ratio }, .{ .id_extra = index, .min_size_content = .{ .w = 220, .h = 340 }, .max_size_content = .{ .w = 220, .h = 340 } });
    }
}
fn cleanup() void {
    for (&textures) |*texture| {
        if (texture.*) |t| dvui.textureDestroyLater(t);
        texture.* = null;
    }
}
test "Native WebP shared decoder and GPU upload" {
    try checkDecoder();
    try @import("../ui/native_capture.zig").capture(640, 440, "webp-covers", null, draw, cleanup);
}
