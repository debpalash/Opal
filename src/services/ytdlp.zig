const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

const alloc = @import("../core/alloc.zig").allocator;

// yt-dlp GitHub releases URL for standalone binary
const YTDLP_URL_LINUX = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp";
const YTDLP_URL_MACOS = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos";

var download_thread: ?std.Thread = null;
var is_downloading: bool = false;
var is_ready: bool = false;
var bin_path_buf: [512]u8 = undefined;
var bin_path_len: usize = 0;

/// Get the path to the bundled yt-dlp binary, or null if not ready yet
pub fn getPath() ?[]const u8 {
    if (is_ready and bin_path_len > 0) return bin_path_buf[0..bin_path_len];
    return null;
}

pub fn isDownloading() bool {
    return is_downloading;
}

/// Check if yt-dlp exists, download if not. Call once at startup.
pub fn ensureAvailable() void {
    if (is_downloading or is_ready) return;

    // Build path: ~/.config/zigzag/bin/yt-dlp
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return;
    const path = std.fmt.bufPrintZ(&bin_path_buf, "{s}/.config/zigzag/bin/yt-dlp", .{home}) catch return;
    bin_path_len = path.len;

    // Check if binary already exists
    if (@import("../core/io_global.zig").cwdAccess(path, .{})) {
        is_ready = true;
        logs.pushLog("info", "ytdlp", "yt-dlp binary found", false);
        return;
    } else |_| {}

    // Need to download
    is_downloading = true;
    logs.pushLog("info", "ytdlp", "Downloading yt-dlp binary...", true);

    download_thread = std.Thread.spawn(.{}, downloadWorker, .{}) catch {
        is_downloading = false;
        return;
    };
}

/// Update yt-dlp by re-downloading the latest release
pub fn update() void {
    if (is_downloading) return;
    if (bin_path_len == 0) {
        ensureAvailable();
        return;
    }
    is_downloading = true;
    is_ready = false;
    logs.pushLog("info", "ytdlp", "Updating yt-dlp...", true);
    download_thread = std.Thread.spawn(.{}, downloadWorker, .{}) catch {
        is_downloading = false;
        return;
    };
}

fn downloadWorker() void {
    defer {
        is_downloading = false;
    }

    const path = bin_path_buf[0..bin_path_len];

    // Ensure directory exists
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return;
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/.config/zigzag/bin", .{home}) catch return;
    @import("../core/io_global.zig").cwdMakePath(dir_path) catch {};

    // Use curl to download (most reliable cross-platform)
    const argv = [_][]const u8{
        "curl",
        "-L",
        "--connect-timeout",
        "15",
        "--max-time",
        "120",
        "-o",
        path,
        YTDLP_URL_LINUX,
    };

    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        logs.pushLog("error", "ytdlp", "Failed to spawn curl for yt-dlp download", true);
        return;
    };

    const result = child.wait() catch {
        logs.pushLog("error", "ytdlp", "yt-dlp download failed", true);
        return;
    };

    if (result.exited != 0) {
        logs.pushLog("error", "ytdlp", "yt-dlp download failed (non-zero exit)", true);
        return;
    }

    // Make executable
    const chmod_argv = [_][]const u8{ "chmod", "+x", path };
    var chmod = @import("../core/io_global.zig").Child.init(&chmod_argv, alloc);
    chmod.stdin_behavior = .Ignore;
    chmod.stdout_behavior = .Ignore;
    chmod.stderr_behavior = .Ignore;
    chmod.spawn() catch return;
    _ = chmod.wait() catch {};

    is_ready = true;
    logs.pushLog("info", "ytdlp", "yt-dlp binary ready!", true);
    state.showToast("yt-dlp downloaded successfully!");
}
