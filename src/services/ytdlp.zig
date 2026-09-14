const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const builtin = @import("builtin");
const io = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const bounded_process = @import("../core/bounded_process.zig");
const update_pure = @import("ytdlp_update_pure.zig");
const sync = @import("../core/sync.zig");

// yt-dlp GitHub releases URL for standalone binary
const YTDLP_URL_LINUX = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp";
const YTDLP_URL_MACOS = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos";
const YTDLP_URL_WINDOWS = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";
const YTDLP_SUMS_URL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS";

var is_downloading = std.atomic.Value(bool).init(false);
var is_ready = std.atomic.Value(bool).init(false);
var bin_path_buf: [512]u8 = undefined;
var bin_path_len: usize = 0;

/// Get the path to the bundled yt-dlp binary, or null if not ready yet
pub fn getPath() ?[]const u8 {
    if (is_ready.load(.acquire) and bin_path_len > 0) return bin_path_buf[0..bin_path_len];
    return null;
}

/// Confirm the binary at `bin_path_buf` actually executes, and disown it if
/// not. Runs on its own thread: the macOS standalone build cold-starts ~20s.
fn verifyWorker() void {
    const path = bin_path_buf[0..bin_path_len];
    var buf: [64]u8 = undefined;
    const result = bounded_process.run(
        &.{ path, "--version" },
        &buf,
        .{ .timeout_ms = 30_000, .terminate_grace_ms = 150 },
    );
    // yt-dlp --version prints a bare date-ish version and exits 0. Requiring
    // both guards against a truncated file that spawns and dies instantly.
    const ok = result.ok() and std.mem.trim(u8, result.output, " \r\n\t").len > 0;
    if (ok) return;
    // Stand down: getPath() goes null, so binary() resolves to a PATH lookup
    // and mpv gets a name it can find if the user installed one themselves.
    is_ready.store(false, .release);
    bin_path_len = 0;
    resolved_done.store(false, .release);
    logs.pushLog(
        "error",
        "ytdlp",
        "Bundled yt-dlp will not run (truncated download, or blocked by the OS) — falling back to PATH",
        true,
    );
}

var resolved_buf: [512]u8 = undefined;
var resolved_len: usize = 0;
var resolved_done = std.atomic.Value(bool).init(false);
var resolved_mutex: sync.Mutex = .{};

/// The yt-dlp executable to spawn. Prefers a system install (absolute path —
/// the GUI process PATH usually lacks /opt/homebrew/bin, so a bare "yt-dlp"
/// fails) because the bundled macOS standalone binary cold-starts ~20s per
/// run; falls back to the bundled copy, then to a bare PATH lookup. Cached.
pub fn binary() []const u8 {
    if (resolved_done.load(.acquire)) return resolved_buf[0..resolved_len];
    resolved_mutex.lock();
    defer resolved_mutex.unlock();
    if (resolved_done.load(.acquire)) return resolved_buf[0..resolved_len];
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
            resolved_done.store(true, .release);
            return resolved_buf[0..resolved_len];
        } else |_| {}
    }
    const pick = getPath() orelse "yt-dlp";
    @memcpy(resolved_buf[0..pick.len], pick);
    resolved_len = pick.len;
    resolved_done.store(true, .release);
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
    @import("../core/workers.zig").spawn(versionWorker, .{}) catch {
        version_busy.store(false, .release);
    };
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
    const argv = [_][]const u8{ binary(), "--version" };
    var buf: [64]u8 = undefined;
    const result = bounded_process.run(
        &argv,
        &buf,
        .{ .timeout_ms = 30_000, .terminate_grace_ms = 150 },
    );
    if (result.ok()) {
        const trimmed = std.mem.trim(u8, result.output, " \r\n\t");
        const m = @min(trimmed.len, version_buf.len);
        @memcpy(version_buf[0..m], trimmed[0..m]);
        version_len = m;
    }
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
    return is_downloading.load(.acquire);
}

/// Register an already-installed bundled binary without starting a download.
/// Call this before creating mpv so its ytdl hook receives the absolute path.
pub fn discoverExisting() bool {
    if (is_ready.load(.acquire)) return true;
    if (is_downloading.load(.acquire)) return false;

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
    const path = std.fmt.bufPrintZ(&bin_path_buf, "{s}/bin/{s}", .{ cfg, exe_name }) catch return false;
    bin_path_len = path.len;

    // Check if binary already exists. Existing is NOT the same as working: a
    // download interrupted partway leaves a truncated file, and on Windows a
    // freshly downloaded .exe can carry a mark-of-the-web that Defender blocks.
    // Both look identical to cwdAccess. That is how issue #23 presented — Opal
    // logged "yt-dlp binary found" while mpv's ytdl_hook reported "youtube-dl
    // failed: not found or not enough permissions" on the very same path, and
    // the user had to install yt-dlp by hand to get YouTube working.
    //
    // So mark it ready optimistically (the common case is a good binary, and
    // the probe costs a process spawn) but verify off-thread and stand it back
    // down if it will not run — binary() then falls through to a PATH lookup,
    // which is exactly what unblocked that reporter.
    if (@import("../core/io_global.zig").cwdAccess(path, .{})) {
        is_ready.store(true, .release);
        resolved_done.store(false, .release);
        logs.pushLog("info", "ytdlp", "yt-dlp binary found", false);
        @import("../core/workers.zig").spawn(verifyWorker, .{}) catch {};
        return true;
    } else |_| {}

    return false;
}

/// Check if yt-dlp exists, download if not. Call once at startup.
pub fn ensureAvailable() void {
    if (is_downloading.load(.acquire) or is_ready.load(.acquire)) return;
    if (discoverExisting()) return;

    // Need to download
    if (is_downloading.swap(true, .acq_rel)) return;
    logs.pushLog("info", "ytdlp", "Downloading yt-dlp binary...", true);

    workers.spawn(downloadWorker, .{}) catch {
        is_downloading.store(false, .release);
        return;
    };
}

/// Update yt-dlp by re-downloading the latest release
pub fn update() void {
    if (is_downloading.load(.acquire)) return;
    if (bin_path_len == 0) {
        ensureAvailable();
        return;
    }
    if (is_downloading.swap(true, .acq_rel)) return;
    logs.pushLog("info", "ytdlp", "Updating yt-dlp...", true);
    workers.spawn(downloadWorker, .{}) catch {
        is_downloading.store(false, .release);
        return;
    };
}

fn downloadWorker() void {
    defer {
        is_downloading.store(false, .release);
        state.wakeUi();
    }

    const path = bin_path_buf[0..bin_path_len];
    var stage_buf: [544]u8 = undefined;
    const stage_path = std.fmt.bufPrint(
        &stage_buf,
        if (builtin.os.tag == .windows) "{s}.new.exe" else "{s}.new",
        .{path},
    ) catch return;
    io.deleteFileAbsolute(stage_path) catch {};
    defer io.deleteFileAbsolute(stage_path) catch {};

    // Ensure directory exists — same configDir() the install path above uses.
    // (This had the identical HOME bug: null on Windows meant an early return,
    // so the download never even started.)
    var dir_buf: [512]u8 = undefined;
    var cfg_buf2: [512]u8 = undefined;
    const cfg2 = @import("../core/paths.zig").configDir(&cfg_buf2);
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/bin", .{cfg2}) catch return;
    io.cwdMakePath(dir_path) catch {};

    const dl_url = switch (comptime builtin.os.tag) {
        .macos => YTDLP_URL_MACOS,
        .windows => YTDLP_URL_WINDOWS,
        else => YTDLP_URL_LINUX,
    };
    const asset_name = switch (comptime builtin.os.tag) {
        .macos => "yt-dlp_macos",
        .windows => "yt-dlp.exe",
        else => "yt-dlp",
    };

    // Download beside the live executable. --fail rejects GitHub error pages;
    // HTTPS-only redirect policy prevents a compromised redirect from
    // downgrading transport. The process supervisor owns timeout/tree cleanup.
    var helper_output: [1024]u8 = undefined;
    const download = bounded_process.run(&.{
        "curl",    "-L",         "--fail",        "--silent", "--show-error",
        "--proto", "=https",     "--proto-redir", "=https",   "--connect-timeout",
        "15",      "--max-time", "120",           "-o",       stage_path,
        dl_url,
    }, &helper_output, .{ .timeout_ms = 121_000 });
    if (!download.ok()) {
        logs.pushLog("error", "ytdlp", "yt-dlp staged download failed; keeping the working version", true);
        return;
    }

    var sums_buf: [16 * 1024]u8 = undefined;
    const sums_result = bounded_process.run(&.{
        "curl",    "-L",         "--fail",        "--silent",     "--show-error",
        "--proto", "=https",     "--proto-redir", "=https",       "--connect-timeout",
        "15",      "--max-time", "30",            YTDLP_SUMS_URL,
    }, &sums_buf, .{ .timeout_ms = 31_000 });
    if (!sums_result.ok()) {
        logs.pushLog("error", "ytdlp", "yt-dlp checksum download failed; keeping the working version", true);
        return;
    }
    const expected = update_pure.expectedChecksum(sums_result.output, asset_name) orelse {
        logs.pushLog("error", "ytdlp", "yt-dlp release checksum is missing; refusing update", true);
        return;
    };
    if (!fileChecksumMatches(stage_path, expected)) {
        logs.pushLog("error", "ytdlp", "yt-dlp SHA-256 mismatch; refusing update", true);
        return;
    }

    // Windows executes the staged .exe directly. POSIX needs the executable bit
    // before the probe; never spawn a nonexistent chmod on Windows.
    if (builtin.os.tag != .windows) {
        const chmod = bounded_process.run(&.{ "chmod", "+x", stage_path }, &helper_output, .{ .timeout_ms = 5_000 });
        if (!chmod.ok()) {
            logs.pushLog("error", "ytdlp", "Could not mark staged yt-dlp executable", true);
            return;
        }
    }

    const probe = bounded_process.run(&.{ stage_path, "--version" }, &helper_output, .{ .timeout_ms = 30_000 });
    if (!probe.ok() or !update_pure.validVersionOutput(probe.output)) {
        logs.pushLog("error", "ytdlp", "Staged yt-dlp failed its version probe; keeping the working version", true);
        return;
    }
    if (workers.isQuitting()) return;

    // renameAbsolute replaces atomically. Until this line every player keeps
    // using the previous executable; a failed publish leaves it untouched.
    io.renameAbsolute(stage_path, path) catch {
        logs.pushLog("error", "ytdlp", "Could not publish yt-dlp update; keeping the working version", true);
        return;
    };
    is_ready.store(true, .release);
    resolved_done.store(false, .release);
    invalidateVersion(); // re-query the version after a fresh download/update
    logs.pushLog("info", "ytdlp", "yt-dlp binary ready!", true);
    state.showToast("yt-dlp updated successfully!");
}

fn fileChecksumMatches(path: []const u8, expected: []const u8) bool {
    const file = io.openFileAbsolute(path, .{}) catch return false;
    defer io.closeFile(file);
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        if (workers.isQuitting()) return false;
        const n = io.read(file, &buf) catch return false;
        if (n == 0) break;
        sha.update(buf[0..n]);
    }
    var actual: [32]u8 = undefined;
    sha.final(&actual);
    return update_pure.checksumMatches(expected, actual);
}
