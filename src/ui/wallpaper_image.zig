//! One full-resolution image, separate from the small shared thumbnail cache.
const std = @import("std");
const dvui = @import("dvui");
const poster = @import("../core/poster.zig");
const alloc = std.heap.c_allocator;
var epoch: std.atomic.Value(u32) = .init(0);
var done: std.atomic.Value(bool) = .init(false);
var active = false;
var attempted = false;
var url: [2048]u8 = undefined;
var url_len: usize = 0;
var pixels: ?[]u8 = null;
var width: u32 = 0;
var height: u32 = 0;
var texture: ?dvui.Texture = null;
const Job = struct { url: [2048]u8, len: usize, referer: [1024]u8, referer_len: usize, generation: u32 };
fn settle() void {
    if (active and done.load(.acquire)) active = false;
}
pub fn reset() void {
    _ = epoch.fetchAdd(1, .acq_rel);
    url_len = 0;
    attempted = false;
    settle();
    if (!active) poster.deinitPoster(&pixels, &texture);
}
pub fn get(target: []const u8, referer: []const u8) ?dvui.Texture {
    settle();
    if (!std.mem.eql(u8, target, url[0..url_len])) {
        reset();
        if (active or target.len == 0 or target.len > url.len) return null;
        @memcpy(url[0..target.len], target);
        url_len = target.len;
    }
    if (active) return null;
    if (!attempted) {
        if (@import("builtin").is_test) return null;
        done.store(false, .release);
        active = true;
        attempted = true;
        var ref: [1024]u8 = undefined;
        const ref_len = @min(referer.len, ref.len);
        @memcpy(ref[0..ref_len], referer[0..ref_len]);
        @import("../core/workers.zig").spawn(fetch, .{Job{ .url = url, .len = url_len, .referer = ref, .referer_len = ref_len, .generation = epoch.load(.acquire) }}) catch {
            active = false;
        };
        return null;
    }
    _ = poster.uploadIfReady(&pixels, width, height, &texture);
    return texture;
}
pub fn failed() bool {
    settle();
    return attempted and !active and pixels == null and texture == null;
}
fn fetch(job: Job) void {
    defer {
        done.store(true, .release);
        @import("../core/state.zig").wakeUi();
    }
    const buffer = alloc.alloc(u8, 32 * 1024 * 1024) catch return;
    defer alloc.free(buffer);
    const local = std.fs.path.isAbsolute(job.url[0..job.len]);
    const local_bytes = if (local) @import("../core/io_global.zig").cwdReadFileAlloc(job.url[0..job.len], alloc, buffer.len) catch null else null;
    defer if (local_bytes) |bytes| alloc.free(bytes);
    const data = local_bytes orelse @import("../services/reliable_fetch.zig").fetch(job.url[0..job.len], buffer, .{
        .timeout_secs = 25,
        .connect_timeout_secs = 4,
        .impersonate = false,
        .secret_url = true,
        .referer = if (job.referer_len > 0) job.referer[0..job.referer_len] else null,
        .cancel_epoch = .{ .epoch32 = .{ .value = &epoch, .expected = job.generation } },
    }) orelse return;
    if (epoch.load(.acquire) != job.generation) return;
    const decoded = @import("../core/image_decode.zig").browserFrame(data) orelse return;
    if (epoch.load(.acquire) != job.generation or @import("../core/workers.zig").isQuitting()) {
        decoded.deinit();
        return;
    }
    width = @intCast(decoded.width);
    height = @intCast(decoded.height);
    pixels = decoded.pixels[0..decoded.rgba_len];
}
/// Called on UI thread after the application worker barrier.
pub fn deinit() void {
    reset();
}

/// A cancelled worker may publish its completion after the viewer was closed.
pub fn releaseIfClosed() void {
    settle();
    if (!active) poster.deinitPoster(&pixels, &texture);
}
pub fn seedForTest(target: []const u8, data: []const u8) !void {
    if (!@import("builtin").is_test) @compileError("test only");
    reset();
    const decoded = @import("../core/image_decode.zig").browserFrame(data) orelse return error.InvalidOriginal;
    @memcpy(url[0..target.len], target);
    url_len = target.len;
    width = @intCast(decoded.width);
    height = @intCast(decoded.height);
    pixels = decoded.pixels[0..decoded.rgba_len];
    attempted = true;
}
test "Browse regression full resolution wallpaper exceeds thumbnail limits" {
    const io = @import("../core/io_global.zig");
    const path = io.getenv("OPAL_TEST_WALLPAPER_ORIGINAL") orelse return error.SkipZigTest;
    const data = try io.cwdReadFileAlloc(path, alloc, 32 * 1024 * 1024);
    defer alloc.free(data);
    try std.testing.expect(data.len > 512 * 1024);
    const decoded = @import("../core/image_decode.zig").browserFrame(data) orelse return error.InvalidOriginal;
    defer decoded.deinit();
    try std.testing.expect(decoded.width >= 3840);
    try std.testing.expect(decoded.rgba_len > 24 * 1024 * 1024);
}
