//! App self-update — polls GitHub releases for latest tag, downloads the
//! .dmg asset to /tmp, and `open`s it so macOS can handle install. No
//! silent replacement (trust + signing). Idempotent + non-blocking.
//!
//! Release asset convention: `Opal-<version>-macos-arm64.dmg` (produced by
//! scripts/build-app.sh when create-dmg is available).

const std = @import("std");
const io_global = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const workers = @import("../core/workers.zig");
const bounded = @import("../core/bounded_process.zig");
var mutex: @import("../core/sync.zig").Mutex = .{};
const alloc = @import("../core/alloc.zig").allocator;

/// Current app version, injected from build.zig.zon at build time.
///
/// This was a hand-maintained constant "kept in sync" with the zon. It drifted:
/// v0.6.1 shipped with it still reading "0.6.0", so the About page showed the
/// wrong version AND every 0.6.1 user was told an update was available forever,
/// since the check below compares this string to the latest GitHub tag
/// (issue #21). One source of truth now — build.zig parses the zon.
pub const APP_VERSION: []const u8 = @import("build_options").app_version;

const RELEASE_API = "https://api.github.com/repos/debpalash/Opal/releases/latest";
const HEX = "0123456789abcdef";

pub const Snapshot = struct {
    latest_tag_buf: [64]u8 = @splat(0),
    latest_tag_len: usize = 0,
    dl_url_buf: [1024]u8 = @splat(0),
    dl_url_len: usize = 0,
    sums_url_buf: [1024]u8 = @splat(0),
    sums_url_len: usize = 0,
    has_update: bool = false,
    is_checking: bool = false,
    is_downloading: bool = false,
    last_error_buf: [160]u8 = @splat(0),
    last_error_len: usize = 0,
    last_check_ts: i64 = 0,

    pub fn latestTag(self: *const Snapshot) []const u8 {
        return self.latest_tag_buf[0..self.latest_tag_len];
    }
    pub fn lastError(self: *const Snapshot) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }
};
var current: Snapshot = .{};

pub fn snapshot() Snapshot {
    mutex.lock();
    defer mutex.unlock();
    return current;
}

fn setError(msg: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    const n = @min(msg.len, current.last_error_buf.len);
    @memcpy(current.last_error_buf[0..n], msg[0..n]);
    current.last_error_len = n;
}

fn clearError() void {
    mutex.lock();
    defer mutex.unlock();
    current.last_error_len = 0;
}

/// Fire background thread that queries GitHub releases API. Safe to
/// call repeatedly — ignored while a check is in flight.
pub fn checkAsync() void {
    mutex.lock();
    if (current.is_checking or current.is_downloading or workers.isQuitting()) {
        mutex.unlock();
        return;
    }
    current.is_checking = true;
    mutex.unlock();
    workers.spawn(checkWorker, .{}) catch {
        mutex.lock();
        defer mutex.unlock();
        current.is_checking = false;
    };
}

fn checkWorker() void {
    defer {
        mutex.lock();
        current.is_checking = false;
        mutex.unlock();
    }
    clearError();

    // Fetch release JSON via curl (consistent with rest of codebase).
    var body_buf: [256 * 1024]u8 = undefined;
    const n = fetchJson(&body_buf) catch |err| {
        switch (err) {
            error.CurlSpawn => setError("curl not available"),
            error.CurlFailed => setError("network error fetching release"),
            error.ReadFailed => setError("read failed"),
        }
        return;
    };
    const body = body_buf[0..n];

    const parsed = std.json.parseFromSlice(Release, alloc, body, .{ .ignore_unknown_fields = true }) catch {
        setError("invalid release response");
        return;
    };
    defer parsed.deinit();
    const tag = parsed.value.tag_name;
    const normalized_tag = stripLeadingV(tag);
    if (normalized_tag.len == 0 or normalized_tag.len > 64) {
        setError("invalid release version length");
        return;
    }

    // Validate tag contains only safe path characters
    for (normalized_tag) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
            else => {
                setError("invalid tag name");
                return;
            },
        }
    }

    var dl: []const u8 = "";
    var sums: []const u8 = "";
    for (parsed.value.assets) |asset| {
        if (asset.browser_download_url.len > 1024) continue;
        if (!std.mem.startsWith(u8, asset.browser_download_url, "https://github.com/debpalash/Opal/releases/download/")) continue;
        if (std.mem.endsWith(u8, asset.name, ".dmg")) dl = asset.browser_download_url;
        if (std.mem.eql(u8, asset.name, "SHA256SUMS.txt")) sums = asset.browser_download_url;
    }
    mutex.lock();
    defer mutex.unlock();

    const tn = @min(normalized_tag.len, current.latest_tag_buf.len);
    @memcpy(current.latest_tag_buf[0..tn], normalized_tag[0..tn]);
    current.latest_tag_len = tn;

    const dn = @min(dl.len, current.dl_url_buf.len);
    @memcpy(current.dl_url_buf[0..dn], dl[0..dn]);
    current.dl_url_len = dn;
    const sn = @min(sums.len, current.sums_url_buf.len);
    @memcpy(current.sums_url_buf[0..sn], sums[0..sn]);
    current.sums_url_len = sn;

    current.has_update = compareVersions(APP_VERSION, normalized_tag) < 0;
    current.last_check_ts = io_global.timestamp();

    if (current.has_update) {
        var log_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&log_buf, "Update available: v{s}", .{normalized_tag}) catch "Update available";
        logs.pushLog("info", "updater", msg, true);
    } else {
        logs.pushLog("info", "updater", "Up to date", false);
    }
}

const Release = struct {
    tag_name: []const u8,
    assets: []const struct { name: []const u8, browser_download_url: []const u8 },
};

fn runHelper(argv: []const []const u8, output: []u8, timeout_ms: i64) !usize {
    var process = bounded.StreamProcess.init(argv, .{
        .timeout_ms = timeout_ms,
        .terminate_grace_ms = 250,
        .max_output_bytes = output.len,
        .cancel_flag = workers.quittingSignal(),
    });
    process.start() catch return error.CurlSpawn;
    var total: usize = 0;
    if (process.stdout()) |stdout| {
        while (total < output.len) {
            const n = io_global.read(stdout, output[total..]) catch {
                process.requestStop();
                _ = process.finish();
                return error.ReadFailed;
            };
            if (n == 0) break;
            total += n;
            if (!process.noteOutput(n)) break;
        }
        if (total == output.len) {
            var extra: [1]u8 = undefined;
            const n = io_global.read(stdout, &extra) catch {
                process.requestStop();
                _ = process.finish();
                return error.ReadFailed;
            };
            if (n > 0) {
                process.requestStop();
                _ = process.finish();
                return error.ReadFailed;
            }
        }
    }
    if (!process.finish().ok()) return error.CurlFailed;
    return total;
}

fn fetchJson(buf: []u8) error{ CurlSpawn, CurlFailed, ReadFailed }!usize {
    return runHelper(&.{
        "curl", "-L",                                  "--silent", "--show-error",             "--fail",    "--max-time", "20",
        "-H",   "Accept: application/vnd.github+json", "-H",       "User-Agent: Opal-Updater", RELEASE_API,
    }, buf, 21_000);
}

fn stripLeadingV(tag: []const u8) []const u8 {
    if (tag.len > 0 and (tag[0] == 'v' or tag[0] == 'V')) return tag[1..];
    return tag;
}

/// Dotted-numeric version compare. Returns -1, 0, 1. Non-numeric
/// components fall back to lexicographic compare of that component.
fn compareVersions(a: []const u8, b: []const u8) i8 {
    var it_a = std.mem.splitScalar(u8, a, '.');
    var it_b = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const pa = it_a.next();
        const pb = it_b.next();
        if (pa == null and pb == null) return 0;
        const sa = pa orelse "0";
        const sb = pb orelse "0";
        const na = std.fmt.parseInt(u32, sa, 10) catch {
            const r = std.mem.order(u8, sa, sb);
            return switch (r) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        };
        const nb = std.fmt.parseInt(u32, sb, 10) catch {
            const r = std.mem.order(u8, sa, sb);
            return switch (r) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        };
        if (na < nb) return -1;
        if (na > nb) return 1;
    }
}

/// Download the .dmg from the last check result into /tmp, then open
/// it via `open` (Finder mounts + shows the drag-to-Applications
/// window). Non-blocking.
pub fn downloadAndOpenAsync() void {
    if (@import("builtin").os.tag != .macos) {
        setError("Update using your package manager or the release download");
        return;
    }
    mutex.lock();
    if (current.is_downloading or current.is_checking or workers.isQuitting()) {
        mutex.unlock();
        return;
    }
    if (current.dl_url_len == 0 or current.sums_url_len == 0) {
        mutex.unlock();
        setError("release download or checksum is missing");
        return;
    }
    current.is_downloading = true;
    const release = current;
    mutex.unlock();
    workers.spawn(downloadWorker, .{release}) catch {
        mutex.lock();
        defer mutex.unlock();
        current.is_downloading = false;
    };
}

fn downloadWorker(release: Snapshot) void {
    defer {
        mutex.lock();
        current.is_downloading = false;
        mutex.unlock();
    }
    clearError();

    const url = release.dl_url_buf[0..release.dl_url_len];
    const tag = release.latestTag();

    var nonce: [16]u8 = undefined;
    if (!io_global.randomSecure(&nonce)) {
        setError("secure temporary path unavailable");
        return;
    }
    var nonce_hex: [32]u8 = undefined;
    for (nonce, 0..) |byte, i| {
        nonce_hex[i * 2] = HEX[byte >> 4];
        nonce_hex[i * 2 + 1] = HEX[byte & 0x0f];
    }
    var path_buf: [512]u8 = undefined;
    var tmp_buf: [256]u8 = undefined;
    const dmg_path = std.fmt.bufPrintZ(&path_buf, "{s}/Opal-{s}-{s}.dmg", .{ io_global.tmpDir(&tmp_buf), tag, nonce_hex }) catch {
        setError("path too long");
        return;
    };
    var handed_off = false;
    defer if (!handed_off) io_global.deleteFileAbsolute(dmg_path) catch {};

    logs.pushLog("info", "updater", "Downloading update…", true);

    var output: [1024]u8 = undefined;
    _ = runHelper(&.{
        "curl",       "-L",  "--fail", "--silent", "--show-error",
        "--max-time", "600", "-o",     dmg_path,   url,
    }, &output, 601_000) catch {
        setError("update download failed or was cancelled");
        return;
    };

    if (!verifyReleaseChecksum(dmg_path, release)) {
        setError("download checksum verification failed");
        logs.pushLog("error", "updater", "Refusing update whose SHA-256 is absent or mismatched", true);
        return;
    }

    if (workers.isQuitting()) return;

    // Hand off to Finder.
    var open_child = io_global.Child.init(&.{ "open", dmg_path }, alloc);
    open_child.stdout_behavior = .Ignore;
    open_child.stderr_behavior = .Ignore;
    const opened = open_child.spawnAndWait() catch {
        setError("could not open the downloaded installer");
        return;
    };
    switch (opened) {
        .exited => |code| if (code != 0) {
            setError("installer opener failed");
            return;
        },
        else => {
            setError("installer opener was interrupted");
            return;
        },
    }
    handed_off = true;

    logs.pushLog("info", "updater", "Update downloaded — drag Opal to Applications", true);
}

fn verifyReleaseChecksum(dmg_path: []const u8, release: Snapshot) bool {
    if (release.sums_url_len == 0) return false;
    var sums: [16 * 1024]u8 = undefined;
    const n = runHelper(&.{
        "curl",                                        "-L", "--fail", "--silent", "--show-error", "--max-time", "30",
        release.sums_url_buf[0..release.sums_url_len],
    }, &sums, 31_000) catch return false;
    const url = release.dl_url_buf[0..release.dl_url_len];
    const asset_name = url[(std.mem.lastIndexOfScalar(u8, url, '/') orelse return false) + 1 ..];

    var expected: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, sums[0..n], '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const digest = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        // Release sums contain the deterministic asset name, while our local
        // file has a random suffix. Match the exact downloaded asset.
        if (digest.len == 64 and std.mem.eql(u8, name, asset_name)) {
            expected = digest;
            break;
        }
    }
    const want = expected orelse return false;
    const file = io_global.openFileAbsolute(dmg_path, .{}) catch return false;
    defer io_global.closeFile(file);
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [256 * 1024]u8 = undefined;
    while (true) {
        if (workers.isQuitting()) return false;
        const got = io_global.read(file, &buf) catch return false;
        if (got == 0) break;
        sha.update(buf[0..got]);
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    var actual: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        actual[i * 2] = HEX[byte >> 4];
        actual[i * 2 + 1] = HEX[byte & 0x0f];
    }
    return std.ascii.eqlIgnoreCase(want, &actual);
}
