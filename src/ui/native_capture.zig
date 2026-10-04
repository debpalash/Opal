//! Test-only native GPU capture: hidden SDL window, no screen-recording API.
const std = @import("std");
const dvui = @import("dvui");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
pub const Draw = *const fn () anyerror!void;
pub fn capture(width: u32, height: u32, name: []const u8, setup: ?Draw, draw: Draw, cleanup: ?*const fn () void) !void {
    if (!@import("builtin").is_test) @compileError("Native capture is test-only");
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .allocator = alloc, .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) }, .vsync = false, .title = "Opal isolated native layout fixture", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    @import("theme.zig").markUiThread();
    if (setup) |init| try init();
    var cleaned = false;
    defer if (!cleaned) {
        if (cleanup) |done| done();
    };
    for (0..8) |frame| {
        try window.begin(@as(i128, @intCast(frame + 1)) * 16_666_667);
        errdefer _ = window.end(.{}) catch null;
        errdefer if (!cleaned) {
            if (cleanup) |done| done();
            cleaned = true;
        };
        @import("theme.zig").setTheme();
        const rect = dvui.windowRectPixels();
        var picture = dvui.Picture.start(rect) orelse return error.CaptureUnavailable;
        var recording = true;
        var picture_alive = true;
        errdefer if (picture_alive) {
            if (recording) picture.stop();
            picture.deinit();
        };
        try draw();
        window.endRendering(.{});
        picture.stop();
        recording = false;
        if (frame == 7) {
            var png: std.Io.Writer.Allocating = try .initCapacity(alloc, 128 * 1024);
            defer png.deinit();
            // Screenshots are review artifacts; avoid expensive compression
            // across the complete route matrix while preserving exact pixels.
            const compression = dvui.c.stbi_write_png_compression_level;
            const filter = dvui.c.stbi_write_force_png_filter;
            dvui.c.stbi_write_png_compression_level = 0;
            dvui.c.stbi_write_force_png_filter = 0;
            defer dvui.c.stbi_write_png_compression_level = compression;
            defer dvui.c.stbi_write_force_png_filter = filter;
            try picture.png(&png.writer);
            const encoded = png.written();
            try std.testing.expect(encoded.len > 1000);
            try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", encoded[0..8]);
            try std.testing.expectEqual(@as(u32, @intFromFloat(rect.w)), std.mem.readInt(u32, encoded[16..20], .big));
            try std.testing.expectEqual(@as(u32, @intFromFloat(rect.h)), std.mem.readInt(u32, encoded[20..24], .big));
            if (io.getenv("OPAL_NATIVE_CAPTURE_DIR")) |directory| {
                try std.Io.Dir.cwd().createDirPath(io.io(), directory);
                const filename = try std.fmt.allocPrint(alloc, "{s}-{d}x{d}.png", .{ name, width, height });
                defer alloc.free(filename);
                const path = try std.fs.path.join(alloc, &.{ directory, filename });
                defer alloc.free(path);
                try io.cwdWriteFile(.{ .sub_path = path, .data = encoded });
            }
        }
        picture.deinit();
        picture_alive = false;
        if (frame == 7) {
            // GPU textures belong to the active DVUI frame, not just the
            // backend window. Destroy fixture resources before Window.end.
            if (cleanup) |done| done();
            cleaned = true;
        }
        _ = try window.end(.{});
    }
}
