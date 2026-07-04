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

/// Current app version. Kept in sync with build.zig.zon + Info.plist.
pub const APP_VERSION: []const u8 = "0.1.1";

const RELEASE_API = "https://api.github.com/repos/debpalash/Opal/releases/latest";

// ── State visible to UI ──
pub var latest_tag_buf: [64]u8 = undefined;
pub var latest_tag_len: usize = 0;
pub var dl_url_buf: [1024]u8 = undefined;
pub var dl_url_len: usize = 0;
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

    const tn = @min(normalized_tag.len, latest_tag_buf.len);
    @memcpy(latest_tag_buf[0..tn], normalized_tag[0..tn]);
    latest_tag_len = tn;

    const dn = @min(dl.len, dl_url_buf.len);
    @memcpy(dl_url_buf[0..dn], dl[0..dn]);
    dl_url_len = dn;

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
        "curl",      "-L",
        "--silent",  "--show-error",
        "--fail",    "--max-time", "20",
        "-H",        "Accept: application/vnd.github+json",
        "-H",        "User-Agent: Opal-Updater",
        RELEASE_API,
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
    var cursor: usize = 0;
    while (cursor < body.len) {
        const sub = body[cursor..];
        const idx = std.mem.indexOf(u8, sub, "\"browser_download_url\"") orelse return null;
        const abs_key = cursor + idx;
        const url = extractJsonString(body[abs_key..], "\"browser_download_url\"") orelse return null;
        if (std.mem.endsWith(u8, url, ".dmg")) return url;
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
            return switch (r) { .lt => -1, .eq => 0, .gt => 1 };
        };
        const nb = std.fmt.parseInt(u32, sb, 10) catch {
            const r = std.mem.order(u8, sa, sb);
            return switch (r) { .lt => -1, .eq => 0, .gt => 1 };
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

    var path_buf: [256]u8 = undefined;
    const dmg_path = std.fmt.bufPrintZ(&path_buf, "/tmp/Opal-{s}.dmg", .{tag}) catch {
        setError("path too long");
        return;
    };

    logs.pushLog("info", "updater", "Downloading update…", true);

    var curl = io_global.Child.init(&.{
        "curl", "-L", "--fail", "--silent", "--show-error",
        "--max-time", "600",
        "-o",   dmg_path, url,
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

    // Hand off to Finder.
    var open_child = io_global.Child.init(&.{ "open", dmg_path }, alloc);
    open_child.stdout_behavior = .Ignore;
    open_child.stderr_behavior = .Ignore;
    _ = open_child.spawnAndWait() catch {};

    logs.pushLog("info", "updater", "Update downloaded — drag Opal to Applications", true);
    state.showToast("Update ready — drag to Applications");
}
