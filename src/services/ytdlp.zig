const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

const alloc = @import("../core/alloc.zig").allocator;

// yt-dlp GitHub releases URL for standalone binary
const YTDLP_URL_LINUX = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp";
const YTDLP_URL_MACOS = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos";
const YTDLP_URL_WINDOWS = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";

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

var resolved_buf: [512]u8 = undefined;
var resolved_len: usize = 0;
var resolved_done: bool = false;

/// The yt-dlp executable to spawn. Prefers a system install (absolute path —
/// the GUI process PATH usually lacks /opt/homebrew/bin, so a bare "yt-dlp"
/// fails) because the bundled macOS standalone binary cold-starts ~20s per
/// run; falls back to the bundled copy, then to a bare PATH lookup. Cached.
pub fn binary() []const u8 {
    if (resolved_done) return resolved_buf[0..resolved_len];
    const io = @import("../core/io_global.zig");
    // Absolute system installs, per platform. The POSIX brew/usr prefixes can
    // never exist on Windows, where a system yt-dlp is on PATH (scoop/winget/
    // pip) — probing them there just wasted three syscalls before falling
    // through to the bundled copy.
    const candidates = if (@import("builtin").os.tag == .windows) [_][]const u8{} else [_][]const u8{
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/usr/bin/yt-dlp",
    };
    for (candidates) |c| {
        if (io.cwdAccess(c, .{})) {
            @memcpy(resolved_buf[0..c.len], c);
            resolved_len = c.len;
            resolved_done = true;
            return resolved_buf[0..resolved_len];
        } else |_| {}
    }
    const pick = getPath() orelse "yt-dlp";
    @memcpy(resolved_buf[0..pick.len], pick);
    resolved_len = pick.len;
    resolved_done = true;
    return resolved_buf[0..resolved_len];
}

// ── Version (cached; queried on a bg thread so the UI never blocks) ──
// `binary() --version` can cold-start ~20s on the bundled macOS standalone, so
// it MUST run off the UI thread. Settings polls versionReady() while pending.
var version_buf: [32]u8 = undefined;
var version_len: usize = 0;
// Atomic (acquire/release): the worker writes version_len THEN publishes
// version_ready with .release, so a UI reader that sees ready=true via .acquire
// also sees the finished string (torn-read-safe).
var version_ready = std.atomic.Value(bool).init(false);
var version_busy = std.atomic.Value(bool).init(false);

/// Kick a one-shot background query of `yt-dlp --version` (no-op once resolved
/// or in-flight). Call from the Settings render; read via versionString().
pub fn ensureVersion() void {
    if (version_ready.load(.acquire)) return;
    if (version_busy.swap(true, .acq_rel)) return; // one in flight already
    if (std.Thread.spawn(.{}, versionWorker, .{})) |t| {
        t.detach();
    } else |_| {
        version_busy.store(false, .release);
    }
}

/// Re-query the version after an update (clears the cache).
pub fn invalidateVersion() void {
    version_len = 0;
    version_ready.store(false, .release);
}

pub fn versionReady() bool {
    return version_ready.load(.acquire);
}

/// The cached `yt-dlp --version` string (empty until versionReady(); empty also
/// means the probe ran but yt-dlp isn't present → the "Download" path shows).
pub fn versionString() []const u8 {
    return version_buf[0..version_len];
}

fn versionWorker() void {
    defer version_busy.store(false, .release);
    // ALWAYS resolve — even on spawn failure (no yt-dlp on PATH). An empty
    // version then means "checked, not installed", so the Settings UI reaches
    // its Download branch instead of looping "Checking…" + re-spawning a worker
    // every frame (the pre-fix bug).
    version_len = 0;
    const io = @import("../core/io_global.zig");
    const argv = [_][]const u8{ binary(), "--version" };
    var child = io.Child.init(&argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    if (child.spawn()) {
        var buf: [64]u8 = undefined;
        const n = if (child.stdout) |*so| io.readAll(so, &buf) catch 0 else 0;
        _ = child.wait() catch {};
        const trimmed = std.mem.trim(u8, buf[0..n], " \r\n\t");
        const m = @min(trimmed.len, version_buf.len);
        @memcpy(version_buf[0..m], trimmed[0..m]);
        version_len = m;
    } else |_| {}
    version_ready.store(true, .release);
    if (state.app.dvui_win) |win| @import("dvui").refresh(win, @src(), null);
}

/// The directory containing the yt-dlp binary (for an "open folder" button),
/// written into `buf`. Uses the resolved binary's dir, else the config bin dir.
pub fn binaryDir(buf: []u8) []const u8 {
    const p = binary();
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| {
        const dir = p[0..i];
        const n = @min(dir.len, buf.len);
        @memcpy(buf[0..n], dir[0..n]);
        return buf[0..n];
    }
    var cfg_buf: [512]u8 = undefined;
    const cfg = @import("../core/paths.zig").configDir(&cfg_buf);
    return std.fmt.bufPrint(buf, "{s}/bin", .{cfg}) catch "";
}

pub fn isDownloading() bool {
    return is_downloading;
}

/// Check if yt-dlp exists, download if not. Call once at startup.
pub fn ensureAvailable() void {
    if (is_downloading or is_ready) return;

    // Install under the app's REAL config dir (paths.configDir), not a
    // hand-rolled HOME + "/.config/opal".
    //
    // WINDOWS BUG THIS FIXES: getenv("HOME") is null on Windows (it's
    // USERPROFILE), so this function returned on the very first line — yt-dlp
    // was NEVER downloaded and YouTube silently never worked. Windows also
    // needs the .exe extension or the file can't be executed, and its config
    // lives in %APPDATA%\opal rather than ~/.config/opal.
    var cfg_buf: [512]u8 = undefined;
    const cfg = @import("../core/paths.zig").configDir(&cfg_buf);
    const exe_name = if (@import("builtin").os.tag == .windows) "yt-dlp.exe" else "yt-dlp";
    const path = std.fmt.bufPrintZ(&bin_path_buf, "{s}/bin/{s}", .{ cfg, exe_name }) catch return;
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

    // Ensure directory exists — same configDir() the install path above uses.
    // (This had the identical HOME bug: null on Windows meant an early return,
    // so the download never even started.)
    var dir_buf: [512]u8 = undefined;
    var cfg_buf2: [512]u8 = undefined;
    const cfg2 = @import("../core/paths.zig").configDir(&cfg_buf2);
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/bin", .{cfg2}) catch return;
    @import("../core/io_global.zig").cwdMakePath(dir_path) catch {};

    const builtin = @import("builtin");
    const dl_url = switch (comptime builtin.os.tag) {
        .macos => YTDLP_URL_MACOS,
        .windows => YTDLP_URL_WINDOWS,
        else => YTDLP_URL_LINUX,
    };

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
        dl_url,
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
    invalidateVersion(); // re-query the version after a fresh download/update
    logs.pushLog("info", "ytdlp", "yt-dlp binary ready!", true);
    state.showToast("yt-dlp updated successfully!");
}
