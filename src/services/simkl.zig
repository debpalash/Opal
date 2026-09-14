const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_global = @import("../core/io_global.zig");
const secret_store = @import("../core/secret_store.zig");
const outbox = @import("sync_outbox.zig");
const workers = @import("../core/workers.zig");
const sync = @import("../core/sync.zig");

// ══════════════════════════════════════════════════════════
// SIMKL — simple watch tracking API (API key only, no OAuth)
// https://simkl.docs.apiary.io/
// ══════════════════════════════════════════════════════════

const SIMKL_API = "https://api.simkl.com";
const APP_VERSION = @import("../core/app_meta.zig").version;
const USER_AGENT = "Opal/" ++ APP_VERSION;

pub var api_key: [128]u8 = std.mem.zeroes([128]u8);
pub var api_key_len: usize = 0;
pub var access_token: [2048]u8 = std.mem.zeroes([2048]u8);
pub var access_token_len: usize = 0;
pub var enabled: std.atomic.Value(bool) = .init(false);
var outbox_busy: std.atomic.Value(bool) = .init(false);
var auth_pending: std.atomic.Value(bool) = .init(false);
var auth_generation: std.atomic.Value(u32) = .init(0);
var authorization_revoked: std.atomic.Value(bool) = .init(false);
var credential_mutex: sync.Mutex = .{};
var user_code: [24]u8 = std.mem.zeroes([24]u8);
var user_code_len: usize = 0;

pub const Snapshot = struct {
    connected: bool,
    pending: bool,
    has_client_id: bool,
    queued: usize,
    needs_reauth: bool,
    user_code: [24]u8 = std.mem.zeroes([24]u8),
    user_code_len: usize = 0,
};

fn cfgPath(buf: []u8) []const u8 {
    var config: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/simkl.json", .{@import("../core/paths.zig").configDir(&config)}) catch "";
}

pub fn init() void {
    const alloc = @import("../core/alloc.zig").allocator;
    var path_buf: [600]u8 = undefined;
    const path = cfgPath(&path_buf);
    @import("../core/secret_file.zig").restrictExisting(path);
    const body = io_global.cwdReadFileAlloc(path, alloc, 8192) catch return;
    defer alloc.free(body);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (parsed.value.object.get("client_id")) |value| if (value == .string and validClientId(value.string)) {
        @memcpy(api_key[0..value.string.len], value.string);
        api_key_len = value.string.len;
    };
    const stored = parsed.value.object.get("access_token") orelse return;
    if (stored != .string) return;
    const plain = secret_store.reveal(stored.string, &access_token) orelse return;
    access_token_len = plain.len;
    enabled.store(access_token_len > 0, .release);
    if (!secret_store.isSealed(stored.string)) save();
    if (enabled.load(.acquire)) kickOutbox();
}

fn save() void {
    var protected: [4096]u8 = undefined;
    defer @memset(&protected, 0);
    const sealed = secret_store.seal(access_token[0..access_token_len], &protected) orelse return;
    var body_buf: [4352]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"client_id\":\"{s}\",\"access_token\":\"{s}\"}}", .{ api_key[0..api_key_len], sealed }) catch return;
    var path_buf: [600]u8 = undefined;
    @import("../core/secret_file.zig").write(cfgPath(&path_buf), body) catch {};
}

fn validClientId(id: []const u8) bool {
    if (id.len == 0 or id.len > api_key.len) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

pub fn setClientId(id: []const u8) bool {
    if (!validClientId(id)) return false;
    credential_mutex.lock();
    defer credential_mutex.unlock();
    @memset(&api_key, 0);
    @memcpy(api_key[0..id.len], id);
    api_key_len = id.len;
    save();
    return true;
}

pub fn disconnect() void {
    _ = auth_generation.fetchAdd(1, .acq_rel);
    auth_pending.store(false, .release);
    authorization_revoked.store(false, .release);
    credential_mutex.lock();
    defer credential_mutex.unlock();
    @memset(&access_token, 0);
    access_token_len = 0;
    enabled.store(false, .release);
    user_code_len = 0;
    save();
}

pub fn snapshot() Snapshot {
    credential_mutex.lock();
    defer credential_mutex.unlock();
    var result: Snapshot = .{
        .connected = enabled.load(.acquire) and access_token_len > 0,
        .pending = auth_pending.load(.acquire),
        .has_client_id = api_key_len > 0,
        .queued = outbox.count("simkl"),
        .needs_reauth = authorization_revoked.load(.acquire),
    };
    result.user_code_len = user_code_len;
    @memcpy(result.user_code[0..user_code_len], user_code[0..user_code_len]);
    return result;
}

pub fn startPinAuth() bool {
    credential_mutex.lock();
    const configured = api_key_len > 0;
    credential_mutex.unlock();
    if (!configured or auth_pending.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return false;
    authorization_revoked.store(false, .release);
    const generation = auth_generation.fetchAdd(1, .acq_rel) + 1;
    workers.spawn(pinAuthWorker, .{generation}) catch {
        auth_pending.store(false, .release);
        return false;
    };
    return true;
}

fn apiUrl(path: []const u8, client_id: []const u8, out: []u8) ?[:0]const u8 {
    return std.fmt.bufPrintZ(out, "{s}{s}?client_id={s}&app-name=opal&app-version={s}", .{ SIMKL_API, path, client_id, APP_VERSION }) catch null;
}

fn pinAuthWorker(generation: u32) void {
    defer if (auth_generation.load(.acquire) == generation) auth_pending.store(false, .release);
    var client: [128]u8 = undefined;
    credential_mutex.lock();
    const client_len = api_key_len;
    @memcpy(client[0..client_len], api_key[0..client_len]);
    credential_mutex.unlock();
    if (client_len == 0) return;
    var url_buf: [512]u8 = undefined;
    const url = apiUrl("/oauth/pin", client[0..client_len], &url_buf) orelse return;
    var response: [4096]u8 = undefined;
    const n = curlGet(url, &response);
    const raw_code = extractJsonString(response[0..n], "user_code") orelse return;
    var code_buf: [24]u8 = undefined;
    const code_len = @min(raw_code.len, code_buf.len);
    @memcpy(code_buf[0..code_len], raw_code[0..code_len]);
    const code = code_buf[0..code_len];
    const interval: usize = @intCast(std.math.clamp(extractJsonInt(response[0..n], "interval") orelse 5, 1, 30));
    credential_mutex.lock();
    user_code_len = @min(code.len, user_code.len);
    @memcpy(user_code[0..user_code_len], code[0..user_code_len]);
    credential_mutex.unlock();

    var attempt: usize = 0;
    while (attempt < 120 and auth_generation.load(.acquire) == generation and !workers.isQuitting()) : (attempt += 1) {
        var waited: usize = 0;
        while (waited < interval and auth_generation.load(.acquire) == generation and !workers.isQuitting()) : (waited += 1) io_global.sleep(std.time.ns_per_s);
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/oauth/pin/{s}", .{code}) catch return;
        const poll_url = apiUrl(path, client[0..client_len], &url_buf) orelse return;
        const bytes = curlGet(poll_url, &response);
        const token = extractJsonString(response[0..bytes], "access_token") orelse continue;
        if (auth_generation.load(.acquire) != generation) return;
        credential_mutex.lock();
        const len = @min(token.len, access_token.len);
        @memset(&access_token, 0);
        @memcpy(access_token[0..len], token[0..len]);
        access_token_len = len;
        enabled.store(len > 0, .release);
        authorization_revoked.store(false, .release);
        user_code_len = 0;
        save();
        credential_mutex.unlock();
        outbox.retryNow("simkl");
        kickOutbox();
        logs.pushLog("info", "simkl", "SIMKL PIN authorization completed", true);
        return;
    }
}

fn curlGet(url: [:0]const u8, out: []u8) usize {
    const alloc = @import("../core/alloc.zig").allocator;
    var child = io_global.Child.init(&.{ "curl", "-fsS", "--connect-timeout", "5", "--max-time", "15", "-A", USER_AGENT, url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;
    const n = if (child.stdout) |*stdout| io_global.readAll(stdout, out) catch 0 else 0;
    const result = child.wait() catch return 0;
    return if (result == .exited and result.exited == 0) n else 0;
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const found = std.mem.indexOf(u8, json, needle) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, json, found + needle.len, ':') orelse return null;
    const quote = std.mem.indexOfScalarPos(u8, json, colon + 1, '"') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, json, quote + 1, '"') orelse return null;
    return json[quote + 1 .. end];
}

fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const found = std.mem.indexOf(u8, json, needle) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, json, found + needle.len, ':') orelse return null;
    var start = colon + 1;
    while (start < json.len and (json[start] == ' ' or json[start] == '\t')) start += 1;
    var end = start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
    if (end == start) return null;
    return std.fmt.parseInt(i64, json[start..end], 10) catch null;
}

pub fn markWatchedEpisode(tmdb_id: i32, season: i32, episode: i32) void {
    if (!enabled.load(.acquire) or tmdb_id <= 0) return;
    var payload_buf: [320]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"shows\":[{{\"ids\":{{\"tmdb\":\"{d}\"}},\"seasons\":[{{\"number\":{d},\"episodes\":[{{\"number\":{d}}}]}}]}}]}}", .{ tmdb_id, season, episode }) catch return;
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "show:{d}:{d}:{d}", .{ tmdb_id, season, episode }) catch return;
    if (outbox.enqueue("simkl", "history", key, payload)) kickOutbox();
}

pub fn markWatchedMovie(tmdb_id: i32) void {
    if (!enabled.load(.acquire) or tmdb_id <= 0) return;
    var body: [160]u8 = undefined;
    const payload = std.fmt.bufPrint(&body, "{{\"movies\":[{{\"ids\":{{\"tmdb\":\"{d}\"}}}}]}}", .{tmdb_id}) catch return;
    var key_buf: [40]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "movie:{d}", .{tmdb_id}) catch return;
    if (outbox.enqueue("simkl", "history", key, payload)) kickOutbox();
}

pub fn pendingCount() usize {
    return outbox.count("simkl");
}

pub fn retryPending() void {
    outbox.retryNow("simkl");
    kickOutbox();
}

fn kickOutbox() void {
    if (!enabled.load(.acquire) or workers.isQuitting()) return;
    if (outbox_busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    workers.spawn(drainOutbox, .{}) catch outbox_busy.store(false, .release);
}

fn drainOutbox() void {
    defer outbox_busy.store(false, .release);
    while (!workers.isQuitting()) {
        var job: outbox.Job = .{};
        const now = io_global.timestamp();
        if (!outbox.nextDue("simkl", now, &job)) return;
        switch (postSync(job.operation[0..job.operation_len], job.payload[0..job.payload_len])) {
            .success => {
                outbox.complete(job.id);
                continue;
            },
            .revoked => {
                outbox.deferFailure(job.id, job.attempts, now, "Authorization revoked; reconnect required");
                authorization_revoked.store(true, .release);
                credential_mutex.lock();
                @memset(&access_token, 0);
                access_token_len = 0;
                enabled.store(false, .release);
                save();
                credential_mutex.unlock();
                logs.pushLog("error", "simkl", "SIMKL authorization was revoked; reconnect to resume queued sync", true);
                return;
            },
            .retry => {},
        }
        outbox.deferFailure(job.id, job.attempts, now, "HTTP delivery failed");
        const delay = outbox.retryDelaySeconds(job.attempts);
        var elapsed: i64 = 0;
        while (elapsed < delay and !workers.isQuitting()) : (elapsed += 1) io_global.sleep(std.time.ns_per_s);
    }
}

const Delivery = enum { success, retry, revoked };

fn postSync(operation: []const u8, payload: []const u8) Delivery {
    var client: [128]u8 = undefined;
    var token: [2048]u8 = undefined;
    credential_mutex.lock();
    const client_len = api_key_len;
    const token_len = access_token_len;
    @memcpy(client[0..client_len], api_key[0..client_len]);
    @memcpy(token[0..token_len], access_token[0..token_len]);
    credential_mutex.unlock();
    if (client_len == 0 or token_len == 0) return .retry;
    var url_buf: [512]u8 = undefined;
    const path = if (std.mem.eql(u8, operation, "watchlist")) "/sync/add-to-list" else "/sync/history";
    const url = apiUrl(path, client[0..client_len], &url_buf) orelse return .retry;
    var auth_buf: [2200]u8 = undefined;
    const auth = std.fmt.bufPrintZ(&auth_buf, "Authorization: Bearer {s}", .{token[0..token_len]}) catch return .retry;
    const alloc = @import("../core/alloc.zig").allocator;
    var child = io_global.Child.init(&.{ "curl", "-sS", "--connect-timeout", "5", "--max-time", "15", "-A", USER_AGENT, "-X", "POST", url, "-H", "Content-Type: application/json", "--config", "-", "-d", payload, "-o", io_global.devNull(), "-w", "%{http_code}" }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    @import("../core/curl_secret.zig").spawnWithHeaders(&child, &.{auth}) catch return .retry;
    var status_buf: [16]u8 = undefined;
    const status_len = if (child.stdout) |*stdout| io_global.readAll(stdout, &status_buf) catch 0 else 0;
    const result = child.wait() catch return .retry;
    if (result != .exited or result.exited != 0) return .retry;
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, status_buf[0..status_len], " \r\n\t"), 10) catch return .retry;
    if (status >= 200 and status < 300) return .success;
    if (status == 401) return .revoked;
    logs.pushLog("warn", "simkl", "SIMKL sync queued for retry", false);
    return .retry;
}

/// Checkin — mark something as watching now.
pub fn checkin(title: []const u8, media_type: []const u8) void {
    if (!enabled.load(.acquire)) return;
    const collection = if (std.mem.eql(u8, media_type, "movie")) "movies" else if (std.mem.eql(u8, media_type, "show")) "shows" else return;
    var escaped: [384]u8 = undefined;
    const safe_title = escapeJsonString(title, &escaped) orelse return;
    var payload_buf: [512]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"{s}\":[{{\"title\":\"{s}\"}}]}}", .{ collection, safe_title }) catch return;
    var key_buf: [320]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ media_type, title[0..@min(title.len, 280)] }) catch return;
    if (outbox.enqueue("simkl", "history", key, payload)) kickOutbox();
}

/// Add to watchlist
pub fn addToWatchlist(title: []const u8) void {
    if (!enabled.load(.acquire)) return;
    var escaped: [384]u8 = undefined;
    const safe_title = escapeJsonString(title, &escaped) orelse return;
    var payload_buf: [512]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"movies\":[{{\"title\":\"{s}\",\"to\":\"plantowatch\"}}]}}", .{safe_title}) catch return;
    if (outbox.enqueue("simkl", "watchlist", title[0..@min(title.len, 300)], payload)) kickOutbox();
}

fn escapeJsonString(value: []const u8, out: []u8) ?[]const u8 {
    var writer = std.Io.Writer.fixed(out);
    @import("remote_http.zig").writeJsonString(&writer, value);
    if (writer.end == out.len and value.len > 0) return null;
    return out[0..writer.end];
}
