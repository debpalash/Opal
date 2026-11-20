//! GPU video path against real SDL OpenGL and libmpv: a hidden window, a real
//! MediaPlayer started through MediaPlayer.init, and a still image whose top
//! half is red and bottom half blue. Proves the worker's shared GL context,
//! mpv's OpenGL render into SDL-owned textures, slot publication to the UI
//! thread, and image orientation, all through the production code.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const c = @import("../core/c.zig");
const player = @import("player.zig");
const gpu_video = @import("gpu_video.zig");

const W = 320;
const H = 240;

fn fixtureImage(workspace: *const @import("../core/secure_temp.zig").Workspace, out: []u8) ![]const u8 {
    // Binary PPM: mpv decodes it through FFmpeg's image demuxer.
    const header = std.fmt.comptimePrint("P6\n{d} {d}\n255\n", .{ W, H });
    const bytes = try alloc.alloc(u8, header.len + W * H * 3);
    defer alloc.free(bytes);
    @memcpy(bytes[0..header.len], header);
    for (0..H) |y| for (0..W) |x| {
        const at = header.len + (y * W + x) * 3;
        bytes[at..][0..3].* = if (y < H / 2) .{ 255, 0, 0 } else .{ 0, 0, 255 };
    };
    return workspace.writeFile("gpu-video-orientation.ppm", bytes, out);
}

fn readPixel(renderer: *c.sdl.SDL_Renderer, x: c_int, y: c_int) [4]u8 {
    var px: [4]u8 = .{ 0, 0, 0, 0 };
    var rect: c.sdl.SDL_Rect = .{ .x = x, .y = y, .w = 1, .h = 1 };
    _ = c.sdl.SDL_RenderReadPixels(renderer, &rect, c.sdl.SDL_PIXELFORMAT_ABGR8888, &px, 4);
    return px;
}

test "Native media offline GPU video renders mpv through SDL's OpenGL renderer" {
    if (comptime !gpu_video.supported_build) return error.SkipZigTest;
    // Windows keeps Direct3D by default (gpu_video_pure.requested).
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    @import("../core/workers.zig").init();
    defer @import("../core/workers.zig").markQuitting();
    @import("../ui/theme.zig").markUiThread();
    gpu_video.resetForTest();
    defer gpu_video.resetForTest();

    gpu_video.requestRendererHint();
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-gpu-video-fixture", .persist_window_geometry = false, .size = .{ .w = W, .h = H }, .vsync = false, .title = "Opal GPU video fixture", .hidden = true });
    defer backend.deinit();
    // Later fixtures in this binary keep SDL's default renderer.
    _ = c.sdl.SDL_ResetHint("SDL_RENDER_DRIVER");
    _ = c.sdl.SDL_ResetHint("SDL_RENDER_BATCHING");
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    const renderer: *c.sdl.SDL_Renderer = @ptrCast(@alignCast(backend.renderer));

    var workspace = try @import("../core/secure_temp.zig").Workspace.create("gpu-video");
    defer workspace.cleanup();
    var path_buf: [1024]u8 = undefined;
    const path = try fixtureImage(&workspace, &path_buf);

    try window.begin(1);
    const p = try player.MediaPlayer.init(alloc);
    _ = try window.end(.{});
    defer p.deinit(alloc);
    try std.testing.expect(p.gpu != null); // GPU path attached, not software
    try std.testing.expect(p.mpv_gl != null);
    try std.testing.expectEqual(@as(usize, 0), p.pixels.len); // CPU buffers returned

    _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "image-display-duration", "inf");
    _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "keep-open", "yes");
    // Typed load seam; the player is not registered, so nothing persists.
    try std.testing.expect(player.loadDetached(p.mpv_ctx, .{ .url = path }));

    var shown = false;
    const deadline = io.monotonicMilliTimestamp() + 5000;
    var frame: i128 = 2;
    while (!shown and io.monotonicMilliTimestamp() < deadline) : (frame += 1) {
        try window.begin(frame * 16_666_667);
        shown = p.presentGpuFrame(W, H);
        _ = try window.end(.{});
        if (!shown) io.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(shown);
    const tex = p.texture.?;
    try std.testing.expectEqual(@as(u32, W), tex.width);
    try std.testing.expectEqual(@as(u32, H), tex.height);

    // Draw the published texture over the whole output and read it back.
    var out_w: c_int = 0;
    var out_h: c_int = 0;
    _ = c.sdl.SDL_GetRendererOutputSize(renderer, &out_w, &out_h);
    _ = c.sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.sdl.SDL_RenderClear(renderer);
    _ = c.sdl.SDL_RenderCopy(renderer, @ptrCast(@alignCast(tex.ptr)), null, null);
    const top = readPixel(renderer, @divTrunc(out_w, 2), 2);
    const bottom = readPixel(renderer, @divTrunc(out_w, 2), out_h - 3);
    std.debug.print("GPU video fixture top={any} bottom={any}\n", .{ top, bottom });
    try std.testing.expect(top[0] > 200 and top[2] < 60); // red on top
    try std.testing.expect(bottom[2] > 200 and bottom[0] < 60); // blue below

    p.stopRenderWorker();
    try std.testing.expect(p.gpu == null and p.mpv_gl == null);
}
