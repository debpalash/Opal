const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_global = @import("../core/io_global.zig");

// ══════════════════════════════════════════════════════════
// Trakt.tv Scrobbling — auto-report watch progress
// Uses OAuth device flow for auth + scrobble API.
// ══════════════════════════════════════════════════════════

const TRAKT_API_URL = "https://api.trakt.tv";
const TRAKT_CLIENT_ID = "opal-media-player"; // Users supply their own via settings

pub var client_id: [128]u8 = std.mem.zeroes([128]u8);
pub var client_id_len: usize = 0;
pub var access_token: [256]u8 = std.mem.zeroes([256]u8);
pub var access_token_len: usize = 0;
pub var enabled: bool = false;
pub var is_scrobbling: bool = false;

/// Called when playback starts — POST /scrobble/start
pub fn scrobbleStart(title: []const u8, progress: f64) void {
    if (!enabled or access_token_len == 0 or client_id_len == 0) return;
    if (is_scrobbling) return;
    is_scrobbling = true;
    defer is_scrobbling = false;

    var json_buf: [1024]u8 = undefined;
    // Escape title for JSON
    var esc: [256]u8 = undefined;
    var ei: usize = 0;
    for (title) |ch| {
        if (ei + 2 >= esc.len) break;
        if (ch == '"') { esc[ei] = '\\'; ei += 1; esc[ei] = '"'; ei += 1; }
        else { esc[ei] = ch; ei += 1; }
    }
    const json = std.fmt.bufPrintZ(&json_buf,
        \\{{"movie":{{"title":"{s}"}},"progress":{d:.1}}}
    , .{ esc[0..ei], progress }) catch return;

    postScrobble("/scrobble/start", json);
}

/// Called when playback pauses — POST /scrobble/pause
pub fn scrobblePause(title: []const u8, progress: f64) void {
    if (!enabled or access_token_len == 0) return;
    var json_buf: [1024]u8 = undefined;
    var esc: [256]u8 = undefined;
    var ei: usize = 0;
    for (title) |ch| {
        if (ei + 2 >= esc.len) break;
        if (ch == '"') { esc[ei] = '\\'; ei += 1; esc[ei] = '"'; ei += 1; }
        else { esc[ei] = ch; ei += 1; }
    }
    const json = std.fmt.bufPrintZ(&json_buf,
        \\{{"movie":{{"title":"{s}"}},"progress":{d:.1}}}
    , .{ esc[0..ei], progress }) catch return;
    postScrobble("/scrobble/pause", json);
}

/// Called when playback stops — POST /scrobble/stop
pub fn scrobbleStop(title: []const u8, progress: f64) void {
    if (!enabled or access_token_len == 0) return;
    var json_buf: [1024]u8 = undefined;
    var esc: [256]u8 = undefined;
    var ei: usize = 0;
    for (title) |ch| {
        if (ei + 2 >= esc.len) break;
        if (ch == '"') { esc[ei] = '\\'; ei += 1; esc[ei] = '"'; ei += 1; }
        else { esc[ei] = ch; ei += 1; }
    }
    const json = std.fmt.bufPrintZ(&json_buf,
        \\{{"movie":{{"title":"{s}"}},"progress":{d:.1}}}
    , .{ esc[0..ei], progress }) catch return;
    postScrobble("/scrobble/stop", json);
}

fn postScrobble(endpoint: []const u8, json_body: []const u8) void {
    const alloc = @import("../core/alloc.zig").allocator;
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "{s}{s}", .{ TRAKT_API_URL, endpoint }) catch return;

    var auth_buf: [300]u8 = undefined;
    const auth = std.fmt.bufPrintZ(&auth_buf, "Authorization: Bearer {s}", .{access_token[0..access_token_len]}) catch return;

    var cid_buf: [200]u8 = undefined;
    const cid_hdr = std.fmt.bufPrintZ(&cid_buf, "trakt-api-key: {s}", .{client_id[0..client_id_len]}) catch return;

    var child = io_global.Child.init(&.{
        "curl", "-s", "-X", "POST", url,
        "-H", "Content-Type: application/json",
        "-H", "trakt-api-version: 2",
        "-H", cid_hdr,
        "-H", auth,
        "-d", json_body,
    }, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        logs.pushLog("warn", "trakt", "Failed to send scrobble", false);
        return;
    };
    const result = child.wait() catch return;
    if (result.exited == 0) {
        logs.pushLog("info", "trakt", "Scrobble sent", false);
    }
}

/// OAuth Device Code flow — step 1: get device code
pub var device_code: [64]u8 = std.mem.zeroes([64]u8);
pub var device_code_len: usize = 0;
pub var user_code: [16]u8 = std.mem.zeroes([16]u8);
pub var user_code_len: usize = 0;
pub var auth_pending: bool = false;

pub fn startDeviceAuth() void {
    if (client_id_len == 0) {
        state.showToast("Set Trakt Client ID first");
        return;
    }
    auth_pending = true;
    _ = std.Thread.spawn(.{}, deviceAuthWorker, .{}) catch {
        auth_pending = false;
    };
}

fn deviceAuthWorker() void {
    defer auth_pending = false;
    const alloc = @import("../core/alloc.zig").allocator;

    // Step 1: POST /oauth/device/code
    var json_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrintZ(&json_buf, "{{\"client_id\":\"{s}\"}}", .{client_id[0..client_id_len]}) catch return;

    var child = io_global.Child.init(&.{
        "curl", "-s", "-X", "POST",
        TRAKT_API_URL ++ "/oauth/device/code",
        "-H", "Content-Type: application/json",
        "-d", body,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;

    var out: [4096]u8 = undefined;
    const n = if (child.stdout) |*s| io_global.readAll(s, &out) catch 0 else 0;
    _ = child.wait() catch {};

    if (n < 10) return;
    const resp = out[0..n];

    // Parse device_code and user_code from JSON
    if (extractJsonStr(resp, "\"device_code\":\"")) |dc| {
        const len = @min(dc.len, device_code.len);
        @memcpy(device_code[0..len], dc[0..len]);
        device_code_len = len;
    }
    if (extractJsonStr(resp, "\"user_code\":\"")) |uc| {
        const len = @min(uc.len, user_code.len);
        @memcpy(user_code[0..len], uc[0..len]);
        user_code_len = len;
        state.showToast("Go to trakt.tv/activate and enter the code");
    }

    // Step 2: Poll for token
    var attempts: usize = 0;
    while (attempts < 60) : (attempts += 1) {
        io_global.sleep(5 * std.time.ns_per_s);

        var poll_body: [256]u8 = undefined;
        const pb = std.fmt.bufPrintZ(&poll_body, "{{\"code\":\"{s}\",\"client_id\":\"{s}\"}}", .{
            device_code[0..device_code_len], client_id[0..client_id_len],
        }) catch return;

        var poll = io_global.Child.init(&.{
            "curl", "-s", "-X", "POST",
            TRAKT_API_URL ++ "/oauth/device/token",
            "-H", "Content-Type: application/json",
            "-d", pb,
        }, alloc);
        poll.stdout_behavior = .Pipe;
        poll.stderr_behavior = .Ignore;
        poll.spawn() catch continue;

        var poll_out: [4096]u8 = undefined;
        const pn = if (poll.stdout) |*s| io_global.readAll(s, &poll_out) catch 0 else 0;
        _ = poll.wait() catch {};

        if (pn > 10) {
            if (extractJsonStr(poll_out[0..pn], "\"access_token\":\"")) |at| {
                const len = @min(at.len, access_token.len);
                @memcpy(access_token[0..len], at[0..len]);
                access_token_len = len;
                enabled = true;
                state.showToast("Trakt.tv connected!");
                logs.pushLog("info", "trakt", "OAuth token received", true);
                return;
            }
        }
    }
    state.showToast("Trakt auth timed out — try again");
}

fn extractJsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    const start = idx + key.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    return json[start..end];
}
