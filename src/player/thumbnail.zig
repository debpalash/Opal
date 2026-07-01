const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

pub const thumb_width: u32 = 160;
pub const thumb_height: u32 = 90;
pub const thumb_interval: u32 = 10; // seconds between thumbnails

pub const ThumbnailState = struct {
    ready: bool = false,
    generating: bool = false,
    count: u32 = 0,
    dir_buf: [256]u8 = undefined,
    dir_len: usize = 0,
    source_path_buf: [512]u8 = undefined,
    source_path_len: usize = 0,
    duration_secs: u32 = 0,
    pid: ?@import("../core/io_global.zig").Child = null,

    pub fn init() ThumbnailState {
        return .{};
    }

    pub fn reset(self: *ThumbnailState) void {
        if (self.pid) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
        self.ready = false;
        self.generating = false;
        self.count = 0;
        self.dir_len = 0;
        self.source_path_len = 0;
        self.duration_secs = 0;
        self.pid = null;
    }
};

/// Start generating thumbnails for a file. Call once when playback starts.
pub fn startGeneration(thumb: *ThumbnailState, file_path: []const u8, duration_secs: u32) void {
    if (thumb.generating or thumb.ready) return;
    if (file_path.len == 0 or duration_secs == 0) return;

    // Create temp directory for this file's thumbnails
    // Use a hash of the path for uniqueness
    var hash: u32 = 0;
    for (file_path) |ch| {
        hash = hash *% 31 +% ch;
    }
    
    const dir_str = std.fmt.bufPrintZ(&thumb.dir_buf, "/tmp/opal_thumbs/{x}", .{hash}) catch return;
    thumb.dir_len = dir_str.len;

    // Create directory
    @import("../core/io_global.zig").makeDirAbsolute("/tmp/opal_thumbs") catch {};
    @import("../core/io_global.zig").makeDirAbsolute(dir_str) catch {};

    // Store source info
    const copy_len = @min(file_path.len, thumb.source_path_buf.len - 1);
    @memcpy(thumb.source_path_buf[0..copy_len], file_path[0..copy_len]);
    thumb.source_path_buf[copy_len] = 0;
    thumb.source_path_len = copy_len;
    thumb.duration_secs = duration_secs;
    thumb.count = duration_secs / thumb_interval;

    thumb.generating = true;
    logs.pushLog("info", "thumbs", "Starting thumbnail generation...", false);

    // Spawn ffmpeg in background
    // ffmpeg -i <file> -vf "fps=1/10,scale=160:-1" -q:v 5 <dir>/thumb_%04d.jpg
    var output_pattern: [384]u8 = undefined;
    const pattern = std.fmt.bufPrintZ(&output_pattern, "{s}/thumb_%04d.jpg", .{dir_str}) catch return;

    var fps_buf: [16]u8 = undefined;
    const fps_str = std.fmt.bufPrintZ(&fps_buf, "fps=1/{d},scale={d}:-1", .{ thumb_interval, thumb_width }) catch return;

    const argv = [_][]const u8{
        "ffmpeg",
        "-y",
        "-i",
        thumb.source_path_buf[0..copy_len],
        "-vf",
        fps_str,
        "-q:v",
        "5",
        "-threads",
        "1",
        pattern,
    };

    var child = @import("../core/io_global.zig").Child.init(&argv, @import("../core/alloc.zig").allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        logs.pushLog("error", "thumbs", "Failed to spawn ffmpeg", true);
        thumb.generating = false;
        return;
    };

    thumb.pid = child;
}

/// Poll for thumbnail generation completion.
/// NOTE: child.wait() here BLOCKS until ffmpeg exits, so this must NOT be
/// called per-frame from the UI thread (it freezes the UI). Generation is
/// currently disabled in player.zig; if re-enabling for a seek-preview
/// feature, run generation+wait on a background thread and have this only
/// read a thread-set `ready` flag. (H8)
pub fn pollGeneration(thumb: *ThumbnailState) void {
    if (!thumb.generating) return;

    if (thumb.pid) |*child| {
        // BLOCKING wait — see note above. Only safe off the UI thread.
        const result = child.wait() catch {
            thumb.generating = false;
            thumb.pid = null;
            return;
        };
        
        if (result.exited == 0) {
            thumb.ready = true;
            logs.pushLog("info", "thumbs", "Thumbnails ready!", false);
        } else {
            logs.pushLog("warn", "thumbs", "ffmpeg exited with error", true);
        }
        thumb.generating = false;
        thumb.pid = null;
    }
}

/// Get the thumbnail file path for a given playback percent.
/// Returns null if thumbnails aren't ready.
pub fn getThumbPath(thumb: *const ThumbnailState, percent: f64, out_buf: *[384]u8) ?[]const u8 {
    if (!thumb.ready or thumb.count == 0) return null;

    const time_secs = percent / 100.0 * @as(f64, @floatFromInt(thumb.duration_secs));
    var frame_idx = @as(u32, @intFromFloat(@max(0.0, time_secs / @as(f64, @floatFromInt(thumb_interval))))) + 1;
    if (frame_idx > thumb.count) frame_idx = thumb.count;
    if (frame_idx == 0) frame_idx = 1;

    const dir = thumb.dir_buf[0..thumb.dir_len];
    const path = std.fmt.bufPrintZ(out_buf, "{s}/thumb_{d:0>4}.jpg", .{ dir, frame_idx }) catch return null;
    return path;
}
