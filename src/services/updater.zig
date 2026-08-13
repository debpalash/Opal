//! App self-update — polls GitHub releases for latest tag, downloads the
//! .dmg asset to /tmp, and `open`s it so macOS can handle install. No
//! silent replacement (trust + signing). Idempotent + non-blocking.
//!
//! Release asset convention: `Opal-<version>.dmg` (produced by
//! scripts/build-app.sh when create-dmg is available).

const std = @import("std");
const io_global = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
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

// ── State visible to UI ──
pub var latest_tag_buf: [64]u8 = undefined;
pub var latest_tag_len: usize = 0;
pub var dl_url_buf: [1024]u8 = undefined;
pub var dl_url_len: usize = 0;
var sums_url_buf: [1024]u8 = undefined;
var sums_url_len: usize = 0;
pub var has_update: bool = false;
pub var is_checking: bool = false;
pub var is_downloading: bool = false;
pub var last_error_buf: [160]u8 = undefined;
pub var last_error_len: usize = 0;
pub var last_check_ts: i64 = 0;

pub fn latestTag() []const u8 {
    return latest_tag_buf[0..latest_tag_len];
}

pub fn lastError() []const u8 {
    return last_error_buf[0..last_error_len];
}

fn setError(msg: []const u8) void {
    const n = @min(msg.len, last_error_buf.len);
    @memcpy(last_error_buf[0..n], msg[0..n]);
    last_error_len = n;
}

fn clearError() void {
    last_error_len = 0;
}

/// Fire background thread that queries GitHub releases API. Safe to
/// call repeatedly — ignored while a check is in flight.
pub fn checkAsync() void {
    if (is_checking) return;
    is_checking = true;
    if (std.Thread.spawn(.{}, checkWorker, .{})) |t| {
        t.detach();
    } else |_| {
        is_checking = false;
    }
}

fn checkWorker() void {
    defer is_checking = false;
    clearError();

    // Fetch release JSON via curl (consistent with rest of codebase).
    var body_buf: [8192]u8 = undefined;
    const n = fetchJson(&body_buf) catch |err| {
        switch (err) {
            error.CurlSpawn => setError("curl not available"),
            error.CurlFailed => setError("network error fetching release"),
            error.ReadFailed => setError("read failed"),
        }
        return;
    };
    const body = body_buf[0..n];

    const tag = extractJsonString(body, "\"tag_name\"") orelse {
        setError("could not parse tag_name");
        return;
    };
    const normalized_tag = stripLeadingV(tag);

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

    const dl = findDmgAssetUrl(body) orelse "";
    const sums = findAssetUrl(body, "SHA256SUMS.txt") orelse "";

    const tn = @min(normalized_tag.len, latest_tag_buf.len);
    @memcpy(latest_tag_buf[0..tn], normalized_tag[0..tn]);
    latest_tag_len = tn;

    const dn = @min(dl.len, dl_url_buf.len);
    @memcpy(dl_url_buf[0..dn], dl[0..dn]);
    dl_url_len = dn;
    const sn = @min(sums.len, sums_url_buf.len);
    @memcpy(sums_url_buf[0..sn], sums[0..sn]);
    sums_url_len = sn;

    has_update = compareVersions(APP_VERSION, normalized_tag) < 0;
    last_check_ts = io_global.timestamp();

    if (has_update) {
        var log_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&log_buf, "Update available: v{s}", .{normalized_tag}) catch "Update available";
        logs.pushLog("info", "updater", msg, true);
    } else {
        logs.pushLog("info", "updater", "Up to date", false);
    }
}

fn fetchJson(buf: []u8) !usize {
    var curl = io_global.Child.init(&.{
        "curl",                                "-L",
        "--silent",                            "--show-error",
        "--fail",                              "--max-time",
        "20",                                  "-H",
        "Accept: application/vnd.github+json", "-H",
        "User-Agent: Opal-Updater",            RELEASE_API,
    }, alloc);
    curl.stdout_behavior = .Pipe;
    curl.stderr_behavior = .Ignore;
    curl.spawn() catch return error.CurlSpawn;

    const n: usize = if (curl.stdout) |*stdout|
        io_global.readAll(stdout, buf) catch {
            _ = curl.wait() catch {};
            return error.ReadFailed;
        }
    else
        0;

    const term = curl.wait() catch return error.CurlFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }
    return n;
}

/// Extract string value for a given JSON key. Walks past the key, the
/// `:`, and the opening quote, then returns bytes up to the next
/// unescaped quote. No allocator — returns a slice into `body`.
fn extractJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    const key_idx = std.mem.indexOf(u8, body, key) orelse return null;
    var i = key_idx + key.len;
    while (i < body.len and body[i] != ':') : (i += 1) {}
    if (i >= body.len) return null;
    i += 1;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {
        if (body[i] == '\\' and i + 1 < body.len) i += 1;
    }
    if (i >= body.len) return null;
    return body[start..i];
}

/// Find the first `browser_download_url` whose value ends in `.dmg`.
/// Walks assets array linearly; tolerates ordering variations.
fn findDmgAssetUrl(body: []const u8) ?[]const u8 {
    return findAssetUrl(body, ".dmg");
}

fn findAssetUrl(body: []const u8, suffix: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < body.len) {
        const sub = body[cursor..];
        const idx = std.mem.indexOf(u8, sub, "\"browser_download_url\"") orelse return null;
        const abs_key = cursor + idx;
        const url = extractJsonString(body[abs_key..], "\"browser_download_url\"") orelse return null;
        if (std.mem.endsWith(u8, url, suffix)) return url;
        // Advance past this match so we scan the next asset.
        cursor = abs_key + "\"browser_download_url\"".len;
    }
    return null;
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
    if (is_downloading) return;
    if (dl_url_len == 0) {
        setError("no download URL — run check first");
        return;
    }
    is_downloading = true;
    if (std.Thread.spawn(.{}, downloadWorker, .{})) |t| {
        t.detach();
    } else |_| {
        is_downloading = false;
    }
}

fn downloadWorker() void {
    defer is_downloading = false;
    clearError();

    const url = dl_url_buf[0..dl_url_len];
    const tag = latest_tag_buf[0..latest_tag_len];

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

    var curl = io_global.Child.init(&.{
        "curl",       "-L",  "--fail", "--silent", "--show-error",
        "--max-time", "600", "-o",     dmg_path,   url,
    }, alloc);
    curl.stdout_behavior = .Ignore;
    curl.stderr_behavior = .Ignore;
    curl.spawn() catch {
        setError("curl spawn failed");
        return;
    };
    const term = curl.wait() catch {
        setError("download failed");
        return;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            setError("download failed (curl exit non-zero)");
            return;
        },
        else => {
            setError("download terminated");
            return;
        },
    }

    if (!verifyReleaseChecksum(dmg_path)) {
        setError("download checksum verification failed");
        logs.pushLog("error", "updater", "Refusing update whose SHA-256 is absent or mismatched", true);
        return;
    }

    // Hand off to Finder.
    var open_child = io_global.Child.init(&.{ "open", dmg_path }, alloc);
    open_child.stdout_behavior = .Ignore;
    open_child.stderr_behavior = .Ignore;
    _ = open_child.spawnAndWait() catch {};
    handed_off = true;

    logs.pushLog("info", "updater", "Update downloaded — drag Opal to Applications", true);
    state.showToast("Update ready — drag to Applications");
}

fn verifyReleaseChecksum(dmg_path: []const u8) bool {
    if (sums_url_len == 0) return false;
    var sums: [16 * 1024]u8 = undefined;
    var curl = io_global.Child.init(&.{
        "curl",                        "-L", "--fail", "--silent", "--show-error", "--max-time", "30",
        sums_url_buf[0..sums_url_len],
    }, alloc);
    curl.stdout_behavior = .Pipe;
    curl.stderr_behavior = .Ignore;
    curl.spawn() catch return false;
    const n = if (curl.stdout) |*stdout| io_global.readAll(stdout, &sums) catch 0 else 0;
    const term = curl.wait() catch return false;
    switch (term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }

    var expected: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, sums[0..n], '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const digest = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        // Release sums contain the deterministic asset name, while our local
        // file has a random suffix. Match the sole DMG row, not the local name.
        if (digest.len == 64 and std.mem.endsWith(u8, name, ".dmg")) {
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
