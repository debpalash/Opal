const std = @import("std");
const logs = @import("../core/logs.zig");
const io_global = @import("../core/io_global.zig");
const secret_store = @import("../core/secret_store.zig");
const outbox = @import("sync_outbox.zig");
const workers = @import("../core/workers.zig");
const sync = @import("../core/sync.zig");

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
var refresh_token: [256]u8 = std.mem.zeroes([256]u8);
var refresh_token_len: usize = 0;
pub var enabled: std.atomic.Value(bool) = .init(false);
pub var is_scrobbling: std.atomic.Value(bool) = .init(false);
var outbox_busy: std.atomic.Value(bool) = .init(false);
var auth_pending: std.atomic.Value(bool) = .init(false);
var auth_generation: std.atomic.Value(u32) = .init(0);
var authorization_revoked: std.atomic.Value(bool) = .init(false);
var credential_revision: std.atomic.Value(u32) = .init(1);
var credential_mutex: sync.Mutex = .{};
var refresh_mutex: sync.Mutex = .{};

pub const Snapshot = struct {
    connected: bool,
    pending: bool,
    scrobbling: bool,
    needs_reauth: bool,
    queued: usize,
    has_client_id: bool,
    has_client_secret: bool,
    user_code: [16]u8,
    user_code_len: usize,
};

pub fn isConnected() bool {
    return enabled.load(.acquire);
}

pub fn snapshot() Snapshot {
    credential_mutex.lock();
    defer credential_mutex.unlock();
    var result: Snapshot = .{
        .connected = enabled.load(.acquire) and access_token_len > 0,
        .pending = auth_pending.load(.acquire),
        .scrobbling = is_scrobbling.load(.acquire),
        .needs_reauth = authorization_revoked.load(.acquire),
        .queued = outbox.count("trakt"),
        .has_client_id = client_id_len > 0,
        .has_client_secret = client_secret_len > 0,
        .user_code = std.mem.zeroes([16]u8),
        .user_code_len = @min(user_code_len, user_code.len),
    };
    @memcpy(result.user_code[0..result.user_code_len], user_code[0..result.user_code_len]);
    return result;
}

pub fn setCredential(key: []const u8, value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    credential_mutex.lock();
    defer credential_mutex.unlock();
    var dst: []u8 = undefined;
    var len: *usize = undefined;
    if (std.mem.eql(u8, key, "client_id")) {
        dst = &client_id;
        len = &client_id_len;
    } else if (std.mem.eql(u8, key, "client_secret")) {
        dst = &client_secret;
        len = &client_secret_len;
    } else return false;
    @memset(dst, 0);
    @memcpy(dst[0..value.len], value);
    len.* = value.len;
    save();
    return true;
}

fn cfgPath(buf: []u8) []const u8 {
    var c: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/trakt.json", .{@import("../core/paths.zig").configDir(&c)}) catch "";
}

/// Persist client id/secret + access token.
pub fn save() void {
    var protected_secret: [512]u8 = undefined;
    defer @memset(&protected_secret, 0);
    var protected_token: [768]u8 = undefined;
    defer @memset(&protected_token, 0);
    var protected_refresh: [768]u8 = undefined;
    defer @memset(&protected_refresh, 0);
    const sealed_secret = secret_store.seal(client_secret[0..client_secret_len], &protected_secret) orelse return;
    const sealed_token = secret_store.seal(access_token[0..access_token_len], &protected_token) orelse return;
    const sealed_refresh = secret_store.seal(refresh_token[0..refresh_token_len], &protected_refresh) orelse return;
    var b: [3072]u8 = undefined;
    const body = std.fmt.bufPrint(&b, "{{\"client_id\":\"{s}\",\"client_secret\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"{s}\"}}", .{ client_id[0..client_id_len], sealed_secret, sealed_token, sealed_refresh }) catch return;
    var pb: [600]u8 = undefined;
    @import("../core/secret_file.zig").write(cfgPath(&pb), body) catch {};
}

fn loadSecretStr(obj: std.json.Value, key: []const u8, buf: []u8, len: *usize) bool {
    const value = obj.object.get(key) orelse return false;
    if (value != .string or value.string.len == 0) return false;
    const plain = secret_store.reveal(value.string, buf) orelse {
        std.log.warn("could not unlock saved Trakt credentials", .{});
        return false;
    };
    len.* = plain.len;
    return !secret_store.isSealed(value.string);
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
    const path = cfgPath(&pb);
    // Upgrade credentials written by older builds before exposing their bytes.
    @import("../core/secret_file.zig").restrictExisting(path);
    const body = io_global.cwdReadFileAlloc(path, alloc, 8192) catch return;
    defer alloc.free(body);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    loadStr(parsed.value, "client_id", &client_id, &client_id_len);
    const legacy_secret = loadSecretStr(parsed.value, "client_secret", &client_secret, &client_secret_len);
    const legacy_token = loadSecretStr(parsed.value, "access_token", &access_token, &access_token_len);
    const legacy_refresh = loadSecretStr(parsed.value, "refresh_token", &refresh_token, &refresh_token_len);
    if (access_token_len > 0) {
        enabled.store(true, .release);
        kickOutbox();
    }
    if (@import("builtin").os.tag == .windows and (legacy_secret or legacy_token or legacy_refresh)) save();
}

pub fn disconnect() void {
    credential_mutex.lock();
    defer credential_mutex.unlock();
    _ = auth_generation.fetchAdd(1, .acq_rel);
    _ = credential_revision.fetchAdd(1, .acq_rel);
    @memset(&access_token, 0);
    @memset(&refresh_token, 0);
    access_token_len = 0;
    refresh_token_len = 0;
    user_code_len = 0;
    device_code_len = 0;
    enabled.store(false, .release);
    auth_pending.store(false, .release);
    authorization_revoked.store(false, .release);
    save();
}

/// Mark a TV episode watched in the user's Trakt history (id-based — reliable,
/// unlike the title-only scrobble). Called when an episode is played.
pub fn markWatchedEpisode(show_tmdb: i32, season: i32, episode: i32) void {
    setEpisodeWatched(show_tmdb, season, episode, true);
}

pub fn markUnwatchedEpisode(show_tmdb: i32, season: i32, episode: i32) void {
    setEpisodeWatched(show_tmdb, season, episode, false);
}

fn setEpisodeWatched(show_tmdb: i32, season: i32, episode: i32, watched: bool) void {
    if (!isConnected()) return;
    var body: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(&body, "{{\"shows\":[{{\"ids\":{{\"tmdb\":{d}}},\"seasons\":[{{\"number\":{d},\"episodes\":[{{\"number\":{d}}}]}}]}}]}}", .{ show_tmdb, season, episode }) catch return;
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "show:{d}:{d}:{d}", .{ show_tmdb, season, episode }) catch return;
    const operation = if (watched) "history" else "history_remove";
    if (outbox.enqueueState("trakt", operation, key, payload)) kickOutbox();
}

/// Mark a movie watched in the user's Trakt history.
pub fn markWatchedMovie(tmdb_id: i32) void {
    if (!isConnected()) return;
    var body: [128]u8 = undefined;
    const payload = std.fmt.bufPrint(&body, "{{\"movies\":[{{\"ids\":{{\"tmdb\":{d}}}}}]}}", .{tmdb_id}) catch return;
    var key_buf: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "movie:{d}", .{tmdb_id}) catch return;
    if (outbox.enqueue("trakt", "history", key, payload)) kickOutbox();
}

pub fn pendingCount() usize {
    return outbox.count("trakt");
}

pub fn retryPending() void {
    outbox.retryNow("trakt");
    kickOutbox();
}

fn kickOutbox() void {
    if (!isConnected() or workers.isQuitting()) return;
    if (outbox_busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    workers.spawn(drainOutbox, .{}) catch {
        outbox_busy.store(false, .release);
    };
}

fn drainOutbox() void {
    defer outbox_busy.store(false, .release);
    while (!workers.isQuitting()) {
        var job: outbox.Job = .{};
        const now = io_global.timestamp();
        if (!outbox.nextDue("trakt", now, &job)) return;
        const endpoint = if (std.mem.eql(u8, job.operation[0..job.operation_len], "history_remove"))
            "/sync/history/remove"
        else
            "/sync/history";
        const delivery = postScrobble(endpoint, job.payload[0..job.payload_len]);
        if (delivery.status == .success) {
            outbox.complete(job.id);
            continue;
        }
        if (delivery.status == .revoked) {
            if (refreshAccessToken(delivery.revision)) continue;
            outbox.deferFailure(job.id, job.attempts, now, "authorization revoked");
            revokeAuthorization(delivery.revision);
            return;
        }
        outbox.deferFailure(job.id, job.attempts, now, "HTTP delivery failed");
        const delay = outbox.retryDelaySeconds(job.attempts);
        var elapsed: i64 = 0;
        while (elapsed < delay and !workers.isQuitting()) : (elapsed += 1)
            io_global.sleep(std.time.ns_per_s);
    }
}

/// Called when playback starts — POST /scrobble/start
pub fn scrobbleStart(title: []const u8, progress: f64) void {
    if (!enabled.load(.acquire)) return;
    if (is_scrobbling.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    defer is_scrobbling.store(false, .release);

    var json_buf: [1024]u8 = undefined;
    // Escape title for JSON
    var esc: [256]u8 = undefined;
    var ei: usize = 0;
    for (title) |ch| {
        if (ei + 2 >= esc.len) break;
        if (ch == '"') {
            esc[ei] = '\\';
            ei += 1;
            esc[ei] = '"';
            ei += 1;
        } else {
            esc[ei] = ch;
            ei += 1;
        }
    }
    const json = std.fmt.bufPrintZ(&json_buf,
        \\{{"movie":{{"title":"{s}"}},"progress":{d:.1}}}
    , .{ esc[0..ei], progress }) catch return;

    const result = postScrobble("/scrobble/start", json);
    if (result.status == .revoked) revokeAuthorization(result.revision);
}

/// Called when playback pauses — POST /scrobble/pause
pub fn scrobblePause(title: []const u8, progress: f64) void {
    if (!enabled.load(.acquire)) return;
    var json_buf: [1024]u8 = undefined;
    var esc: [256]u8 = undefined;
    var ei: usize = 0;
    for (title) |ch| {
        if (ei + 2 >= esc.len) break;
        if (ch == '"') {
            esc[ei] = '\\';
            ei += 1;
            esc[ei] = '"';
            ei += 1;
        } else {
            esc[ei] = ch;
            ei += 1;
        }
    }
    const json = std.fmt.bufPrintZ(&json_buf,
        \\{{"movie":{{"title":"{s}"}},"progress":{d:.1}}}
    , .{ esc[0..ei], progress }) catch return;
    const result = postScrobble("/scrobble/pause", json);
    if (result.status == .revoked) revokeAuthorization(result.revision);
}

/// Called when playback stops — POST /scrobble/stop
pub fn scrobbleStop(title: []const u8, progress: f64) void {
    if (!enabled.load(.acquire)) return;
    var json_buf: [1024]u8 = undefined;
    var esc: [256]u8 = undefined;
    var ei: usize = 0;
    for (title) |ch| {
        if (ei + 2 >= esc.len) break;
        if (ch == '"') {
            esc[ei] = '\\';
            ei += 1;
            esc[ei] = '"';
            ei += 1;
        } else {
            esc[ei] = ch;
            ei += 1;
        }
    }
    const json = std.fmt.bufPrintZ(&json_buf,
        \\{{"movie":{{"title":"{s}"}},"progress":{d:.1}}}
    , .{ esc[0..ei], progress }) catch return;
    const result = postScrobble("/scrobble/stop", json);
    if (result.status == .revoked) revokeAuthorization(result.revision);
}

const Delivery = enum { success, retry, revoked };
const DeliveryResult = struct { status: Delivery, revision: u32 };

fn refreshAccessToken(expected_revision: u32) bool {
    refresh_mutex.lock();
    defer refresh_mutex.unlock();

    var refresh: [256]u8 = undefined;
    var refresh_len: usize = 0;
    var cid: [128]u8 = undefined;
    var cid_len: usize = 0;
    var secret: [128]u8 = undefined;
    var secret_len: usize = 0;
    credential_mutex.lock();
    if (credential_revision.load(.acquire) != expected_revision) {
        const connected = enabled.load(.acquire);
        credential_mutex.unlock();
        return connected;
    }
    refresh_len = refresh_token_len;
    cid_len = client_id_len;
    secret_len = client_secret_len;
    @memcpy(refresh[0..refresh_len], refresh_token[0..refresh_len]);
    @memcpy(cid[0..cid_len], client_id[0..cid_len]);
    @memcpy(secret[0..secret_len], client_secret[0..secret_len]);
    credential_mutex.unlock();
    defer @memset(&refresh, 0);
    defer @memset(&secret, 0);
    if (refresh_len == 0 or cid_len == 0 or secret_len == 0) return false;

    var body_buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrintZ(
        &body_buf,
        "{{\"refresh_token\":\"{s}\",\"client_id\":\"{s}\",\"client_secret\":\"{s}\",\"redirect_uri\":\"urn:ietf:wg:oauth:2.0:oob\",\"grant_type\":\"refresh_token\"}}",
        .{ refresh[0..refresh_len], cid[0..cid_len], secret[0..secret_len] },
    ) catch return false;
    const alloc = @import("../core/alloc.zig").allocator;
    var child = io_global.Child.init(&.{
        "curl",                              "-fsS", "--connect-timeout",              "5",  "--max-time", "15", "-X", "POST",
        "https://auth.trakt.tv/oauth/token", "-H",   "Content-Type: application/json", "-d", body,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    var response: [4096]u8 = undefined;
    const n = if (child.stdout) |*stdout| io_global.readAll(stdout, &response) catch 0 else 0;
    const result = child.wait() catch return false;
    if (result != .exited or result.exited != 0) return false;
    const next_access = extractJsonStr(response[0..n], "\"access_token\":\"") orelse return false;
    const next_refresh = extractJsonStr(response[0..n], "\"refresh_token\":\"") orelse return false;
    if (next_access.len == 0 or next_access.len > access_token.len or next_refresh.len == 0 or next_refresh.len > refresh_token.len) return false;

    credential_mutex.lock();
    defer credential_mutex.unlock();
    if (credential_revision.load(.acquire) != expected_revision) return enabled.load(.acquire);
    @memset(&access_token, 0);
    @memset(&refresh_token, 0);
    @memcpy(access_token[0..next_access.len], next_access);
    @memcpy(refresh_token[0..next_refresh.len], next_refresh);
    access_token_len = next_access.len;
    refresh_token_len = next_refresh.len;
    _ = credential_revision.fetchAdd(1, .acq_rel);
    enabled.store(true, .release);
    authorization_revoked.store(false, .release);
    save();
    logs.pushLog("info", "trakt", "Trakt access token refreshed", true);
    return true;
}

fn revokeAuthorization(expected_revision: u32) void {
    credential_mutex.lock();
    if (credential_revision.load(.acquire) != expected_revision) {
        credential_mutex.unlock();
        return;
    }
    @memset(&access_token, 0);
    access_token_len = 0;
    enabled.store(false, .release);
    authorization_revoked.store(true, .release);
    _ = credential_revision.fetchAdd(1, .acq_rel);
    save();
    credential_mutex.unlock();
    logs.pushLog("error", "trakt", "Trakt authorization was revoked; reconnect to resume queued sync", true);
}

fn postScrobble(endpoint: []const u8, json_body: []const u8) DeliveryResult {
    const alloc = @import("../core/alloc.zig").allocator;
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "{s}{s}", .{ TRAKT_API_URL, endpoint }) catch return .{ .status = .retry, .revision = 0 };

    var token: [256]u8 = undefined;
    var token_len: usize = 0;
    var cid: [128]u8 = undefined;
    var cid_len: usize = 0;
    credential_mutex.lock();
    const revision = credential_revision.load(.acquire);
    token_len = access_token_len;
    cid_len = client_id_len;
    @memcpy(token[0..token_len], access_token[0..token_len]);
    @memcpy(cid[0..cid_len], client_id[0..cid_len]);
    credential_mutex.unlock();
    defer @memset(&token, 0);
    if (token_len == 0 or cid_len == 0) return .{ .status = .retry, .revision = revision };

    var auth_buf: [300]u8 = undefined;
    const auth = std.fmt.bufPrintZ(&auth_buf, "Authorization: Bearer {s}", .{token[0..token_len]}) catch return .{ .status = .retry, .revision = revision };

    var cid_buf: [200]u8 = undefined;
    const cid_hdr = std.fmt.bufPrintZ(&cid_buf, "trakt-api-key: {s}", .{cid[0..cid_len]}) catch return .{ .status = .retry, .revision = revision };

    var child = io_global.Child.init(&.{
        "curl",                           "-fsS",    "--connect-timeout",    "5",                 "--max-time",
        "15",                             "-X",      "POST",                 url,                 "-H",
        "Content-Type: application/json", "-H",      "trakt-api-version: 2", "--config",          "-",
        "-d",                             json_body, "-o",                   io_global.devNull(), "-w",
        "%{http_code}",
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    @import("../core/curl_secret.zig").spawnWithHeaders(&child, &.{ cid_hdr, auth }) catch {
        logs.pushLog("warn", "trakt", "Failed to send scrobble", false);
        return .{ .status = .retry, .revision = revision };
    };
    var status_buf: [8]u8 = undefined;
    const n = if (child.stdout) |*stdout| io_global.readAll(stdout, &status_buf) catch 0 else 0;
    const result = child.wait() catch return .{ .status = .retry, .revision = revision };
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, status_buf[0..n], " \r\n\t"), 10) catch 0;
    if (result == .exited and result.exited == 0 and status >= 200 and status < 300) {
        logs.pushLog("info", "trakt", "Scrobble sent", false);
        return .{ .status = .success, .revision = revision };
    }
    if (status == 401) return .{ .status = .revoked, .revision = revision };
    logs.pushLog("warn", "trakt", "Trakt rejected or failed a sync request; queued for retry", false);
    return .{ .status = .retry, .revision = revision };
}

/// OAuth Device Code flow — step 1: get device code
pub var device_code: [64]u8 = std.mem.zeroes([64]u8);
pub var device_code_len: usize = 0;
pub var user_code: [16]u8 = std.mem.zeroes([16]u8);
pub var user_code_len: usize = 0;
pub fn startDeviceAuth() bool {
    credential_mutex.lock();
    const ready = client_id_len > 0 and client_secret_len > 0;
    if (!ready or auth_pending.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        credential_mutex.unlock();
        return false;
    }
    authorization_revoked.store(false, .release);
    const generation = auth_generation.fetchAdd(1, .acq_rel) + 1;
    credential_mutex.unlock();
    workers.spawn(deviceAuthWorker, .{generation}) catch {
        auth_pending.store(false, .release);
        return false;
    };
    return true;
}

fn deviceAuthWorker(generation: u32) void {
    defer if (auth_generation.load(.acquire) == generation) auth_pending.store(false, .release);
    const alloc = @import("../core/alloc.zig").allocator;

    var cid: [128]u8 = undefined;
    var cid_len: usize = 0;
    var secret: [128]u8 = undefined;
    var secret_len: usize = 0;
    credential_mutex.lock();
    cid_len = client_id_len;
    secret_len = client_secret_len;
    @memcpy(cid[0..cid_len], client_id[0..cid_len]);
    @memcpy(secret[0..secret_len], client_secret[0..secret_len]);
    credential_mutex.unlock();
    defer @memset(&secret, 0);

    // Step 1: POST /oauth/device/code
    var json_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrintZ(&json_buf, "{{\"client_id\":\"{s}\"}}", .{cid[0..cid_len]}) catch return;

    var child = io_global.Child.init(&.{
        "curl",                                "-fsS", "--connect-timeout",              "5",  "--max-time", "15", "-X", "POST",
        TRAKT_API_URL ++ "/oauth/device/code", "-H",   "Content-Type: application/json", "-d", body,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;

    var out: [4096]u8 = undefined;
    const n = if (child.stdout) |*s| io_global.readAll(s, &out) catch 0 else 0;
    _ = child.wait() catch {};

    if (n < 10) return;
    const resp = out[0..n];
    const poll_interval: usize = @intCast(std.math.clamp(extractJsonInt(resp, "interval") orelse 5, 1, 30));
    const expires_in: usize = @intCast(std.math.clamp(extractJsonInt(resp, "expires_in") orelse 600, 60, 1800));

    // Copy provider codes before the response buffer is reused by polling.
    const dc = extractJsonStr(resp, "\"device_code\":\"") orelse return;
    var code: [64]u8 = undefined;
    const code_len = @min(dc.len, code.len);
    @memcpy(code[0..code_len], dc[0..code_len]);
    credential_mutex.lock();
    device_code_len = code_len;
    @memcpy(device_code[0..code_len], code[0..code_len]);
    if (extractJsonStr(resp, "\"user_code\":\"")) |uc| {
        const len = @min(uc.len, user_code.len);
        @memcpy(user_code[0..len], uc[0..len]);
        user_code_len = len;
    }
    credential_mutex.unlock();

    // Step 2: Poll for token
    var elapsed: usize = 0;
    while (elapsed < expires_in and auth_generation.load(.acquire) == generation and !workers.isQuitting()) {
        var waited: usize = 0;
        while (waited < poll_interval and auth_generation.load(.acquire) == generation and !workers.isQuitting()) : (waited += 1) {
            io_global.sleep(std.time.ns_per_s);
            elapsed += 1;
        }
        if (auth_generation.load(.acquire) != generation or workers.isQuitting()) return;

        var poll_body: [256]u8 = undefined;
        const pb = std.fmt.bufPrintZ(&poll_body, "{{\"code\":\"{s}\",\"client_id\":\"{s}\",\"client_secret\":\"{s}\"}}", .{
            code[0..code_len], cid[0..cid_len], secret[0..secret_len],
        }) catch return;

        var poll = io_global.Child.init(&.{
            "curl",                                 "-fsS", "--connect-timeout",              "5",  "--max-time", "15", "-X", "POST",
            TRAKT_API_URL ++ "/oauth/device/token", "-H",   "Content-Type: application/json", "-d", pb,
        }, alloc);
        poll.stdout_behavior = .Pipe;
        poll.stderr_behavior = .Ignore;
        poll.spawn() catch continue;

        var poll_out: [4096]u8 = undefined;
        const pn = if (poll.stdout) |*s| io_global.readAll(s, &poll_out) catch 0 else 0;
        _ = poll.wait() catch {};

        if (pn > 10) {
            if (extractJsonStr(poll_out[0..pn], "\"access_token\":\"")) |at| {
                if (auth_generation.load(.acquire) != generation) return;
                const rt = extractJsonStr(poll_out[0..pn], "\"refresh_token\":\"") orelse return;
                if (rt.len == 0 or rt.len > refresh_token.len) return;
                credential_mutex.lock();
                const len = @min(at.len, access_token.len);
                @memset(&access_token, 0);
                @memset(&refresh_token, 0);
                @memcpy(access_token[0..len], at[0..len]);
                @memcpy(refresh_token[0..rt.len], rt);
                access_token_len = len;
                refresh_token_len = rt.len;
                _ = credential_revision.fetchAdd(1, .acq_rel);
                enabled.store(len > 0, .release);
                authorization_revoked.store(false, .release);
                user_code_len = 0;
                device_code_len = 0;
                save();
                credential_mutex.unlock();
                outbox.retryNow("trakt");
                kickOutbox();
                logs.pushLog("info", "trakt", "OAuth token received", true);
                return;
            }
        }
    }
    logs.pushLog("warn", "trakt", "Trakt authorization timed out; try again", true);
}

fn extractJsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    const start = idx + key.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    return json[start..end];
}

fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, json, pos + needle.len, ':') orelse return null;
    var start = colon + 1;
    while (start < json.len and std.ascii.isWhitespace(json[start])) : (start += 1) {}
    var end = start;
    while (end < json.len and std.ascii.isDigit(json[end])) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i64, json[start..end], 10) catch null;
}
