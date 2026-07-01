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
pub var client_secret: [128]u8 = std.mem.zeroes([128]u8);
pub var client_secret_len: usize = 0;
pub var access_token: [256]u8 = std.mem.zeroes([256]u8);
pub var access_token_len: usize = 0;
pub var enabled: bool = false;
pub var is_scrobbling: bool = false;

pub fn isConnected() bool {
    return access_token_len > 0;
}

fn cfgPath(buf: []u8) []const u8 {
    var c: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/trakt.json", .{@import("../core/paths.zig").configDir(&c)}) catch "";
}

/// Persist client id/secret + access token.
pub fn save() void {
    var b: [900]u8 = undefined;
    const body = std.fmt.bufPrint(&b, "{{\"client_id\":\"{s}\",\"client_secret\":\"{s}\",\"access_token\":\"{s}\"}}", .{ client_id[0..client_id_len], client_secret[0..client_secret_len], access_token[0..access_token_len] }) catch return;
    var pb: [600]u8 = undefined;
    io_global.cwdWriteFile(.{ .sub_path = cfgPath(&pb), .data = body }) catch {};
}

fn loadStr(obj: std.json.Value, key: []const u8, buf: []u8, len: *usize) void {
    if (obj.object.get(key)) |v| if (v == .string and v.string.len <= buf.len) {
        @memcpy(buf[0..v.string.len], v.string);
        len.* = v.string.len;
    };
}

/// Load saved credentials + token at startup.
pub fn init() void {
    const alloc = @import("../core/alloc.zig").allocator;
    var pb: [600]u8 = undefined;
    const body = io_global.cwdReadFileAlloc(cfgPath(&pb), alloc, 8192) catch return;
    defer alloc.free(body);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    loadStr(parsed.value, "client_id", &client_id, &client_id_len);
    loadStr(parsed.value, "client_secret", &client_secret, &client_secret_len);
    loadStr(parsed.value, "access_token", &access_token, &access_token_len);
    if (access_token_len > 0) enabled = true;
}

pub fn disconnect() void {
    access_token_len = 0;
    enabled = false;
    save();
}

/// Mark a TV episode watched in the user's Trakt history (id-based — reliable,
/// unlike the title-only scrobble). Called when an episode is played.
pub fn markWatchedEpisode(show_tmdb: i32, season: i32, episode: i32) void {
    if (!isConnected()) return;
    const S = struct {
        var busy: bool = false;
        var sid: i32 = 0;
        var sn: i32 = 0;
        var ep: i32 = 0;
        fn worker() void {
            defer busy = false;
            var body: [256]u8 = undefined;
            const b = std.fmt.bufPrintZ(&body, "{{\"shows\":[{{\"ids\":{{\"tmdb\":{d}}},\"seasons\":[{{\"number\":{d},\"episodes\":[{{\"number\":{d}}}]}}]}}]}}", .{ sid, sn, ep }) catch return;
            postScrobble("/sync/history", b);
        }
    };
    if (S.busy) return;
    S.busy = true;
    S.sid = show_tmdb;
    S.sn = season;
    S.ep = episode;
    (std.Thread.spawn(.{}, S.worker, .{}) catch {
        S.busy = false;
        return;
    }).detach();
}

/// Mark a movie watched in the user's Trakt history.
pub fn markWatchedMovie(tmdb_id: i32) void {
    if (!isConnected()) return;
    const S = struct {
        var busy: bool = false;
        var id: i32 = 0;
        fn worker() void {
            defer busy = false;
            var body: [128]u8 = undefined;
            const b = std.fmt.bufPrintZ(&body, "{{\"movies\":[{{\"ids\":{{\"tmdb\":{d}}}}}]}}", .{id}) catch return;
            postScrobble("/sync/history", b);
        }
    };
    if (S.busy) return;
    S.busy = true;
    S.id = tmdb_id;
    (std.Thread.spawn(.{}, S.worker, .{}) catch {
        S.busy = false;
        return;
    }).detach();
}

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
    if (std.Thread.spawn(.{}, deviceAuthWorker, .{})) |t| {
        t.detach();
    } else |_| {
        auth_pending = false;
    }
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
        const pb = std.fmt.bufPrintZ(&poll_body, "{{\"code\":\"{s}\",\"client_id\":\"{s}\",\"client_secret\":\"{s}\"}}", .{
            device_code[0..device_code_len], client_id[0..client_id_len], client_secret[0..client_secret_len],
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
                save();
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
