//! Opt-in SDL pixel test. No HTTP, playback, user config, or screen recording.
//! OPAL_GALLERY_ART_DIR may contain tt2543164.jpg, tt1856101.jpg,
//! tt0816692.jpg, tt0245429.jpg. Without it, colored fixture geometry is used.
//! OPAL_GALLERY_CAPTURE_DIR optionally receives rendered PNG artifacts.
const std = @import("std");
const dvui = @import("dvui");
const io = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
const search = @import("search.zig");
const resolver = @import("resolver.zig");
const content = @import("search_content_pure.zig");

fn field(buffer: []u8, length: *usize, value: []const u8) void {
    length.* = @min(buffer.len, value.len);
    @memcpy(buffer[0..length.*], value[0..length.*]);
}

fn fixtureRows() ![]resolver.ResolvedItem {
    const rows = try alloc.alloc(resolver.ResolvedItem, 14);
    const catalog_ids = [_]i32{ 329865, 335984, 157336, 129 };
    const titles = [_][]const u8{ "Arrival", "Blade Runner 2049", "Interstellar", "Spirited Away", "Fixture album", "Fixture podcast" };
    for (rows, 0..) |*row, index| {
        row.* = .{};
        row.source = if (index < 12) .tmdb else if (index == 12) .music else .podcast;
        row.catalog_id = if (index < 4) catalog_ids[index] else if (index < 12) @intCast(10000 + index) else 0;
        field(&row.catalog_kind, &row.catalog_kind_len, "movie");
        var fixture_title: [64]u8 = undefined;
        const title = if (index < 4) titles[index] else if (index < 12) try std.fmt.bufPrint(&fixture_title, "Offline movie fixture {d}", .{index}) else titles[index - 8];
        field(&row.name, &row.name_len, title);
        field(&row.summary, &row.summary_len, "Explicit offline layout fixture: source comparison, artwork, and contextual actions. No provider availability or playback is asserted.");
        field(&row.poster_url, &row.poster_url_len, "fixture://offline-art");
        if (index == 0) {
            @import("cinemeta_pure.zig").copyCatalogPoster(row, "https://images.metahub.space/poster/small/tt2543164/img");
            try std.testing.expectEqualStrings("https://images.metahub.space/poster/small/tt2543164/img.jpg", row.poster_url[0..row.poster_url_len]);
        }
        row.year = 2016;
        row.score = @intCast(index);
    }
    return rows;
}

fn fixtureTexture(index: usize) !dvui.Texture {
    if (io.getenv("OPAL_GALLERY_ART_DIR")) |directory| {
        const names = [_][]const u8{ "tt2543164.jpg", "tt1856101.jpg", "tt0816692.jpg", "tt0245429.jpg" };
        const path = try std.fs.path.join(alloc, &.{ directory, names[index % names.len] });
        defer alloc.free(path);
        const bytes = try io.cwdReadFileAlloc(path, alloc, 4 * 1024 * 1024);
        defer alloc.free(bytes);
        return decodedFixtureTexture(bytes);
    }
    if (index == 0) return decodedFixtureTexture(@embedFile("testdata/gallery-cover.jpg"));
    var pixels: [64 * 96 * 4]u8 = undefined;
    for (0..64 * 96) |pixel| {
        const y = pixel / 64;
        pixels[pixel * 4] = @intCast(35 + (index % 8) * 20);
        pixels[pixel * 4 + 1] = @intCast(50 + y);
        pixels[pixel * 4 + 2] = @intCast(130 + (index % 8) * 12);
        pixels[pixel * 4 + 3] = 255;
    }
    return try dvui.Texture.fromImageSource(.{ .pixels = .{ .rgba = &pixels, .width = 64, .height = 96, .interpolation = .linear } });
}

fn decodedFixtureTexture(bytes: []const u8) !dvui.Texture {
    // Exercise the same bounded decoder and GPU upload as fetched covers,
    // rather than bypassing the poster pipeline with DVUI's image helper.
    const decoded = @import("../core/image_decode.zig").cover(bytes) orelse return error.CoverDecodeFailed;
    defer decoded.deinit();
    var pixels: ?[]u8 = try std.heap.c_allocator.alloc(u8, decoded.rgba_len);
    @memcpy(pixels.?, decoded.pixels[0..decoded.rgba_len]);
    var texture: ?dvui.Texture = null;
    defer if (pixels) |remaining| std.heap.c_allocator.free(remaining);
    try std.testing.expect(@import("../core/poster.zig").uploadIfReady(&pixels, @intCast(decoded.width), @intCast(decoded.height), &texture));
    try std.testing.expect(pixels == null);
    return texture.?;
}

fn renderSize(width: u32, height: u32, rows: []const resolver.ResolvedItem, movies_only: bool) !void {
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .allocator = alloc, .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) }, .vsync = false, .title = "Opal offline gallery pixel regression", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    @import("../ui/theme.zig").markUiThread();
    search.setGalleryFixtureForTest(rows, "Arrival");
    if (movies_only) search.setGalleryContentFilterForTest(.movies);
    // Parent-owned workers must finish before their GPU storage is destroyed.
    defer workers.beginShutdownAndDrain(800);
    const projection = try alloc.create(content.Projection);
    defer alloc.destroy(projection);
    const indices = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
    content.projectInto(rows, &indices, projection);
    for (0..if (movies_only) @as(usize, 6) else 4) |frame| {
        try window.begin(@as(i128, @intCast(frame + 1)) * 16_666_667);
        errdefer {
            workers.beginShutdownAndDrain(800);
            search.shutdown();
            search.deinitGallery();
            _ = window.end(.{}) catch null;
        }
        if (frame == 0) {
            for (projection.groups[0..projection.count]) |group| {
                const texture = try fixtureTexture(group.representative);
                search.setGalleryTextureForTest(group.identity, rows[group.representative].poster_url[0..rows[group.representative].poster_url_len], texture, texture.width, texture.height);
            }
        }
        if (movies_only and frame == 4) {
            _ = try window.addEventMouseMotion(.{ .pt = .{ .x = @as(f32, @floatFromInt(width)), .y = @as(f32, @floatFromInt(height)) } });
            _ = try window.addEventMouseWheel(-600, .vertical);
        }
        if (frame == 2 or frame == 3) _ = try window.addEventKey(.{ .code = .tab, .action = .down, .mod = .none });
        @import("../ui/theme.zig").setTheme();
        const rect = dvui.windowRectPixels();
        try std.testing.expect(rect.w >= @as(f32, @floatFromInt(width)));
        try std.testing.expect(rect.h >= @as(f32, @floatFromInt(height)));
        var picture = dvui.Picture.start(rect) orelse return error.CaptureUnavailable;
        var recording = true;
        var picture_alive = true;
        errdefer if (picture_alive) {
            if (recording) picture.stop();
            picture.deinit();
        };
        search.renderGalleryForTest();
        window.endRendering(.{});
        picture.stop();
        recording = false;
        if (frame == 3 or (movies_only and frame == 5)) {
            var png: std.Io.Writer.Allocating = try .initCapacity(alloc, 128 * 1024);
            defer png.deinit();
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
            // Assert actual GPU capture bounds, including Retina/high-DPI scale.
            try std.testing.expectEqual(@as(u32, @intFromFloat(rect.w)), std.mem.readInt(u32, encoded[16..20], .big));
            try std.testing.expectEqual(@as(u32, @intFromFloat(rect.h)), std.mem.readInt(u32, encoded[20..24], .big));
            if (io.getenv("OPAL_GALLERY_CAPTURE_DIR")) |directory| {
                try std.Io.Dir.cwd().createDirPath(io.io(), directory);
                const name = try std.fmt.allocPrint(alloc, "gallery-{d}x{d}{s}.png", .{ width, height, if (movies_only and frame == 5) "-movies-scrolled" else if (movies_only) "-movies" else "" });
                defer alloc.free(name);
                const path = try std.fs.path.join(alloc, &.{ directory, name });
                defer alloc.free(path);
                try io.cwdWriteFile(.{ .sub_path = path, .data = encoded });
            }
        }
        picture.deinit();
        picture_alive = false;
        if (frame == (if (movies_only) @as(usize, 5) else 3)) {
            workers.beginShutdownAndDrain(800);
            search.shutdown();
            search.deinitGallery();
        }
        _ = try window.end(.{});
        if (frame == 2 or frame == 3) try std.testing.expect(window.subwindows.focused().?.focused_widget_id != null);
    }
}

test "Native Search performance offline warmed maximum gallery scroll frames" {
    const rows = try alloc.alloc(resolver.ResolvedItem, resolver.MAX_RESULTS);
    defer alloc.free(rows);
    for (rows, 0..) |*row, index| {
        row.* = .{ .source = .tmdb, .catalog_id = @intCast(10000 + index) };
        field(&row.catalog_kind, &row.catalog_kind_len, "movie");
        var title: [64]u8 = undefined;
        field(&row.name, &row.name_len, try std.fmt.bufPrint(&title, "Owned maximum gallery fixture {d}", .{index}));
        field(&row.poster_url, &row.poster_url_len, "fixture://offline-art");
    }
    const projection = try alloc.create(content.Projection);
    defer alloc.destroy(projection);
    var indices: [resolver.MAX_RESULTS]usize = undefined;
    for (&indices, 0..) |*index, i| index.* = i;
    content.projectInto(rows, &indices, projection);
    try std.testing.expectEqual(rows.len, projection.count);
    for ([_][2]u32{ .{ 1360, 1000 }, .{ 640, 800 } }) |size| {
        workers.init();
        defer workers.finishShutdown();
        var backend = try dvui.backend.initWindow(.{ .io = io.io(), .allocator = alloc, .size = .{ .w = @floatFromInt(size[0]), .h = @floatFromInt(size[1]) }, .vsync = false, .title = "Opal owned scroll benchmark", .hidden = true });
        defer backend.deinit();
        var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
        defer window.deinit();
        @import("../ui/theme.zig").markUiThread();
        search.setGalleryFixtureForTest(rows, "Owned maximum gallery");
        search.setGalleryContentFilterForTest(.movies);
        var timings: [120]f64 = undefined;
        for (0..timings.len + 8) |frame| {
            const started = std.Io.Clock.awake.now(io.io()).toNanoseconds();
            try window.begin(@as(i128, @intCast(frame + 1)) * 16_666_667);
            errdefer {
                workers.beginShutdownAndDrain(800);
                search.shutdown();
                search.deinitGallery();
                _ = window.end(.{}) catch null;
            }
            if (frame == 0) for (projection.groups[0..projection.count]) |group| {
                const texture = try fixtureTexture(group.representative);
                search.setGalleryTextureForTest(group.identity, "fixture://offline-art", texture, texture.width, texture.height);
            };
            if (frame >= 8) {
                _ = try window.addEventMouseMotion(.{ .pt = .{ .x = @as(f32, @floatFromInt(size[0])) / 2, .y = @as(f32, @floatFromInt(size[1])) / 2 } });
                _ = try window.addEventMouseWheel(if (frame % 60 < 30) -120 else 120, .vertical);
            }
            @import("../ui/theme.zig").setTheme();
            search.renderGalleryForTest();
            window.endRendering(.{});
            if (frame == 12) {
                try std.testing.expect(search.galleryScrollForTest() > 0);
                try std.testing.expect(search.galleryTextRowsForTest() > 0);
                try std.testing.expect(search.galleryTextRowsForTest() < rows.len);
            }
            if (frame == timings.len + 7) {
                workers.beginShutdownAndDrain(800);
                search.shutdown();
                search.deinitGallery();
            }
            _ = try window.end(.{});
            if (frame >= 8) timings[frame - 8] = @as(f64, @floatFromInt(std.Io.Clock.awake.now(io.io()).toNanoseconds() - started)) / 1_000_000;
        }
        std.mem.sort(f64, &timings, {}, std.sort.asc(f64));
        // Includes native renderer submission, excludes preload and PNG capture.
        // Hidden window without vsync: not monitor presentation or an FPS claim.
        std.debug.print("Native gallery {d}x{d}, {d} owned rows, 120 warmed frames: p50={d:.3}ms p95={d:.3}ms\n", .{ size[0], size[1], rows.len, (timings[59] + timings[60]) / 2, timings[113] });
    }
}

test "Native Search gallery offline SDL pixel capture" {
    const rows = try fixtureRows();
    defer alloc.free(rows);
    for ([_][2]u32{ .{ 1360, 1000 }, .{ 640, 800 } }) |size| {
        for ([_]bool{ false, true }) |movies_only| {
            workers.init();
            try renderSize(size[0], size[1], rows, movies_only);
            workers.finishShutdown();
        }
    }
}
