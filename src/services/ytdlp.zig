const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const builtin = @import("builtin");
const io = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const bounded_process = @import("../core/bounded_process.zig");
const update_pure = @import("ytdlp_update_pure.zig");
const sync = @import("../core/sync.zig");
const helper_install = @import("../core/helper_install.zig");

// yt-dlp GitHub releases URL for standalone binary
const YTDLP_URL_LINUX = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp";
const YTDLP_URL_MACOS = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos";
const YTDLP_URL_WINDOWS = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";
const YTDLP_SUMS_URL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS";

var is_downloading = std.atomic.Value(bool).init(false);
var is_ready = std.atomic.Value(bool).init(false);
var existing_rejected = std.atomic.Value(bool).init(false);
var bin_path_buf: [512]u8 = undefined;
var bin_path_len: usize = 0;
var discovery_mutex: sync.Mutex = .{};
// 255=unchecked, 0=no absolute system install, 1..3=candidate index + 1.
// Only the tiny index changes; returned path storage is always a string literal.
var system_binary_pick = std.atomic.Value(u8).init(255);
const SYSTEM_BINARY_CANDIDATES = [_][]const u8{
    "/opt/homebrew/bin/yt-dlp",
    "/usr/local/bin/yt-dlp",
    "/usr/bin/yt-dlp",
};

fn cachedSystemBinary(pick: u8) ?[]const u8 {
    if (pick == 0 or pick == 255) return null;
    const idx = pick - 1;
    return if (idx < SYSTEM_BINARY_CANDIDATES.len) SYSTEM_BINARY_CANDIDATES[idx] else null;
}

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
    // A kept previous copy that still runs beats a PATH lookup.
    if (rollback()) {
        const again = bounded_process.run(&.{ path, "--version" }, &buf, .{ .timeout_ms = 30_000, .terminate_grace_ms = 150 });
        if (again.ok() and std.mem.trim(u8, again.output, " \r\n\t").len > 0) return;
    }
    // Stand down: getPath() goes null, so binary() can use a PATH install while
    // the checksum-verified replacement is downloaded in the background.
    existing_rejected.store(true, .release);
    is_ready.store(false, .release);
    logs.pushLog(
        "error",
        "ytdlp",
        "Bundled yt-dlp will not run (truncated download, or blocked by the OS) — falling back to PATH",
        true,
    );
    ensureAvailable();
}

/// The yt-dlp executable to spawn. Prefers a system install (absolute path —
/// the GUI process PATH usually lacks /opt/homebrew/bin, so a bare "yt-dlp"
/// fails) because the bundled macOS standalone binary cold-starts ~20s per
/// run; falls back to the bundled copy, then to a bare PATH lookup. Every
/// returned slice is immutable, including the once-published bundled path.
pub fn binary() []const u8 {
    // Absolute system installs, per platform. The POSIX brew/usr prefixes can
    // never exist on Windows, where a system yt-dlp is on PATH (scoop/winget/
    // pip) — probing them there just wasted three syscalls before falling
    // through to the bundled copy.
    const cached = system_binary_pick.load(.acquire);
    if (cached != 255) return cachedSystemBinary(cached) orelse getPath() orelse "yt-dlp";
    if (comptime builtin.os.tag != .windows) {
        for (SYSTEM_BINARY_CANDIDATES, 0..) |candidate, idx| {
            if (io.cwdAccess(candidate, .{})) {
                system_binary_pick.store(@intCast(idx + 1), .release);
                return candidate;
            } else |_| {}
        }
    }
    system_binary_pick.store(0, .release);
    return getPath() orelse "yt-dlp";
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
    discovery_mutex.lock();
    defer discovery_mutex.unlock();
    if (is_ready.load(.acquire)) return true;
    if (is_downloading.load(.acquire) or existing_rejected.load(.acquire)) return false;
    cleanupStaleOnce();

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
    const path = @import("opal-fmt").bufPrintZ(&bin_path_buf, "{s}/bin/{s}", .{ cfg, exe_name }) catch return false;
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
    // Acquire-ready is the publication barrier for bin_path_buf/bin_path_len;
    // never inspect the non-atomic length while discovery may be writing it.
    if (!is_ready.load(.acquire)) {
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

const DL_URL = switch (builtin.os.tag) {
    .macos => YTDLP_URL_MACOS,
    .windows => YTDLP_URL_WINDOWS,
    else => YTDLP_URL_LINUX,
};
const ASSET_NAME = switch (builtin.os.tag) {
    .macos => "yt-dlp_macos",
    .windows => "yt-dlp.exe",
    else => "yt-dlp",
};
const EXE_NAME = if (builtin.os.tag == .windows) "yt-dlp.exe" else "yt-dlp";

/// Hooks for helper_install: the release download, the staged `--version`
/// probe, and shutdown as cancellation.
const InstallHooks = struct {
    fn fetch(_: ?*anyopaque, stage_path: []const u8) helper_install.FetchResult {
        // HTTPS on every hop, status-checked (rejects GitHub error pages).
        const dl = @import("reliable_fetch.zig").download(DL_URL, stage_path, .{
            .timeout_secs = 120,
            .connect_timeout_secs = 15,
            .https_only = true,
            .impersonate = false,
        });
        if (dl.failure == .cancelled) return .cancelled;
        if (dl.ok()) return .ok;
        return if (dl.status >= 400) .http_error else .transport;
    }
    fn probe(_: ?*anyopaque, stage_path: []const u8) bool {
        var out: [1024]u8 = undefined;
        const r = bounded_process.run(&.{ stage_path, "--version" }, &out, .{ .timeout_ms = 30_000 });
        return r.ok() and update_pure.validVersionOutput(r.output);
    }
    fn cancelled(_: ?*anyopaque) bool {
        return workers.isQuitting();
    }
};

fn binDirPath(buf: []u8) ?[]const u8 {
    var cfg_buf: [512]u8 = undefined;
    const cfg = @import("../core/paths.zig").configDir(&cfg_buf);
    return std.fmt.bufPrint(buf, "{s}/bin", .{cfg}) catch null;
}

/// Startup repair, once per process and never while a download runs: drop
/// partial downloads and restore a kept copy a crash left without a live file.
var stale_cleaned = std.atomic.Value(bool).init(false);
fn cleanupStaleOnce() void {
    if (stale_cleaned.swap(true, .acq_rel)) return;
    var dir_buf: [512]u8 = undefined;
    const dir_path = binDirPath(&dir_buf) orelse return;
    const dir = io.openDirAbsolute(dir_path, .{}) catch return;
    defer io.closeDir(dir);
    const report = helper_install.cleanupStale(io.io(), dir, EXE_NAME);
    if (report.removed > 0) logs.pushLog("info", "ytdlp", "Removed a partial yt-dlp download", false);
    if (report.restored) logs.pushLog("warn", "ytdlp", "Restored the previous yt-dlp after an interrupted update", true);
}

/// Put the previous yt-dlp back (kept by the last update). False when there
/// is no previous copy.
pub fn rollback() bool {
    if (is_downloading.load(.acquire)) return false;
    var dir_buf: [512]u8 = undefined;
    const dir_path = binDirPath(&dir_buf) orelse return false;
    const dir = io.openDirAbsolute(dir_path, .{}) catch return false;
    defer io.closeDir(dir);
    if (!helper_install.rollback(io.io(), dir, EXE_NAME)) return false;
    invalidateVersion();
    logs.pushLog("info", "ytdlp", "Rolled back to the previous yt-dlp", true);
    return true;
}

fn downloadWorker() void {
    defer {
        is_downloading.store(false, .release);
        state.wakeUi();
    }

    // Ensure directory exists — same configDir() the install path above uses.
    // (This had the identical HOME bug: null on Windows meant an early return,
    // so the download never even started.)
    var dir_buf: [512]u8 = undefined;
    const dir_path = binDirPath(&dir_buf) orelse return;
    io.cwdMakePath(dir_path) catch {};

    // Checksum first: without it nothing is downloaded. The release CDN
    // publishes several addresses and a single unreachable one can eat a whole
    // attempt's connect budget, so the small sums file gets one retry.
    var sums_buf: [16 * 1024]u8 = undefined;
    var sums_output: ?[]const u8 = null;
    var sums_attempt: u8 = 0;
    while (sums_output == null and update_pure.shouldFetchChecksums(sums_attempt, workers.isQuitting())) : (sums_attempt += 1) {
        sums_output = @import("reliable_fetch.zig").fetch(YTDLP_SUMS_URL, &sums_buf, .{
            .timeout_secs = 30,
            .connect_timeout_secs = 15,
            .https_only = true,
            .impersonate = false,
        });
    }
    if (workers.isQuitting()) return;
    const sums = sums_output orelse {
        logs.pushLog("error", "ytdlp", "yt-dlp checksum download failed; keeping the working version", true);
        return;
    };
    const expected = update_pure.expectedChecksum(sums, ASSET_NAME) orelse {
        logs.pushLog("error", "ytdlp", "yt-dlp release checksum is missing; refusing update", true);
        return;
    };

    const dir = io.openDirAbsolute(dir_path, .{}) catch {
        logs.pushLog("error", "ytdlp", "Could not open the yt-dlp folder; keeping the working version", true);
        return;
    };
    defer io.closeDir(dir);

    // Stage beside the live executable, verify SHA-256, set native
    // permissions, run a bounded version probe, keep the previous copy, then
    // publish with an atomic rename. Until publish every player keeps using
    // the previous executable; any failure leaves it untouched.
    const result = helper_install.install(io.io(), .{ .dir = dir, .dir_path = dir_path, .name = EXE_NAME }, .{
        .expect = .{ .sha256_hex = expected },
        .executable = true,
    }, .{ .fetch = InstallHooks.fetch, .probe = InstallHooks.probe, .cancelled = InstallHooks.cancelled });
    if (!result.ok()) {
        const failure = result.failure orelse return;
        if (failure == .cancelled) return;
        logs.pushLog("error", "ytdlp", switch (failure) {
            .checksum_mismatch, .size_mismatch, .empty => "yt-dlp SHA-256 mismatch; refusing update",
            .probe_failed => "Staged yt-dlp failed its version probe; keeping the working version",
            .permissions => "Could not mark staged yt-dlp executable",
            .fetch_http, .fetch_transport => "yt-dlp staged download failed; keeping the working version",
            else => "Could not publish yt-dlp update; keeping the working version",
        }, true);
        return;
    }
    existing_rejected.store(false, .release);
    is_ready.store(true, .release);
    invalidateVersion(); // re-query the version after a fresh download/update
    logs.pushLog("info", "ytdlp", "yt-dlp binary ready!", true);
    state.showToast("yt-dlp updated successfully!");
}
