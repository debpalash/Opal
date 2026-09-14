//! Non-blocking playback-progress fanout for authenticated media servers.
//! Stable identities enter here; credentials exist only in bounded RAM work.
const std = @import("std");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const workers = @import("../core/workers.zig");
const http = @import("../core/http.zig");
const logs = @import("../core/logs.zig");
const io = @import("../core/io_global.zig");
const pure = @import("server_progress_pure.zig");

const max_pending = 12;
const max_seen = 16;

const Update = struct {
    provider: pure.Provider,
    event: pure.Event = .progress,
    item: [512]u8 = std.mem.zeroes([512]u8),
    item_len: usize = 0,
    server: [256]u8 = std.mem.zeroes([256]u8),
    server_len: usize = 0,
    token: [256]u8 = std.mem.zeroes([256]u8),
    token_len: usize = 0,
    device_id: [32]u8 = std.mem.zeroes([32]u8),
    device_id_len: usize = 0,
    position: f64,
    duration: f64,
};

const Seen = struct {
    provider: pure.Provider = .audiobookshelf,
    item: [512]u8 = std.mem.zeroes([512]u8),
    item_len: usize = 0,
    position: f64 = 0,
    next_retry_ms: i64 = 0,
    failures: u8 = 0,
    session_ready: bool = false,
};

var mutex: sync.Mutex = .{};
var pending: [max_pending]Update = undefined;
var pending_count: usize = 0;
var seen: [max_seen]Seen = undefined;
var seen_count: usize = 0;
var running = false;
var plex_server: [256]u8 = std.mem.zeroes([256]u8);
var plex_server_len: usize = 0;
var plex_token: [128]u8 = std.mem.zeroes([128]u8);
var plex_token_len: usize = 0;

pub fn registerPlexConnection(server: []const u8, token: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    @memset(&plex_server, 0);
    @memset(&plex_token, 0);
    plex_server_len = @min(server.len, plex_server.len);
    @memcpy(plex_server[0..plex_server_len], server[0..plex_server_len]);
    plex_token_len = @min(token.len, plex_token.len);
    @memcpy(plex_token[0..plex_token_len], token[0..plex_token_len]);
}

pub fn clearPlexConnection() void {
    mutex.lock();
    defer mutex.unlock();
    @memset(&plex_server, 0);
    plex_server_len = 0;
    @memset(&plex_token, 0);
    plex_token_len = 0;
}

/// Give a LAN server a tiny best-effort window to receive the final stopped
/// state after the native surface is hidden. The hard cap preserves fast close;
/// the normal worker supervisor cancels/drains anything still in flight.
pub fn flushForShutdown(max_ms: i64) void {
    const started_ms = io.monotonicMilliTimestamp();
    while (io.monotonicMilliTimestamp() - started_ms < @max(max_ms, 1)) {
        mutex.lock();
        const idle = !running and pending_count == 0;
        mutex.unlock();
        if (idle) return;
        io.sleep(2 * std.time.ns_per_ms);
    }
}

pub fn submit(identity: []const u8, position: f64, duration: f64, force: bool) void {
    submitEvent(identity, position, duration, if (force) .stopped else .progress, force);
}

pub fn playState(identity: []const u8, position: f64, duration: f64, paused: bool) void {
    const route = pure.parseIdentity(identity) orelse return;
    if (route.provider == .audiobookshelf) return;
    submitEvent(identity, position, duration, if (paused) .paused else .progress, true);
}

fn submitEvent(identity: []const u8, position: f64, duration: f64, event: pure.Event, force: bool) void {
    if (state.app.incognito_mode or workers.isQuitting()) return;
    const route = pure.parseIdentity(identity) orelse return;
    if (!pure.validProgress(position, duration)) return;

    const now = io.monotonicMilliTimestamp();
    var spawn_worker = false;
    mutex.lock();
    defer mutex.unlock();

    const seen_idx = findSeen(route.provider, route.item);
    const previous = if (seen_idx) |idx| seen[idx].position else null;
    if (seen_idx) |idx| {
        const retry_due = seen[idx].failures > 0 and now >= seen[idx].next_retry_ms;
        const provider_cadence_ready = route.provider != .plex or force or @abs(position - seen[idx].position) >= 10.0;
        if (!retry_due and (!pure.shouldQueue(previous, position, duration, force) or !provider_cadence_ready)) return;
        if (!force and now < seen[idx].next_retry_ms) return;
        seen[idx].position = position;
    } else {
        if (!pure.shouldQueue(null, position, duration, force)) return;
        remember(route.provider, route.item, position);
    }

    var update: Update = .{
        .provider = route.provider,
        .event = if (event == .stopped and route.provider == .audiobookshelf) .progress else event,
        .position = position,
        .duration = duration,
    };
    copyItem(&update, route.item);
    if (!snapshotConnection(&update)) return;
    enqueueLocked(update, &spawn_worker);
    spawnLocked(spawn_worker);
}

/// Jellyfin owns a session lifecycle; ABS uses a stateless progress resource.
pub fn started(identity: []const u8) void {
    if (state.app.incognito_mode or workers.isQuitting()) return;
    const route = pure.parseIdentity(identity) orelse return;
    if (route.provider == .audiobookshelf) return;

    var update: Update = .{ .provider = route.provider, .event = .started, .position = 0, .duration = 0 };
    copyItem(&update, route.item);
    if (!snapshotConnection(&update)) return;

    var spawn_worker = false;
    mutex.lock();
    defer mutex.unlock();
    if (findSeen(route.provider, route.item)) |idx| {
        seen[idx].position = 0;
        seen[idx].failures = 0;
        seen[idx].next_retry_ms = 0;
        seen[idx].session_ready = false;
    } else {
        remember(route.provider, route.item, 0);
    }
    enqueueLocked(update, &spawn_worker);
    spawnLocked(spawn_worker);
}

fn copyItem(update: *Update, item: []const u8) void {
    update.item_len = @min(item.len, update.item.len);
    @memcpy(update.item[0..update.item_len], item[0..update.item_len]);
}

fn snapshotConnection(update: *Update) bool {
    var server: []const u8 = undefined;
    var token: []const u8 = undefined;
    switch (update.provider) {
        .audiobookshelf => {
            if (!state.app.abs.connected) return false;
            server = state.app.abs.server_url[0..@min(state.app.abs.server_url_len, state.app.abs.server_url.len)];
            token = state.app.abs.token[0..@min(state.app.abs.token_len, state.app.abs.token.len)];
        },
        .jellyfin => {
            if (!state.app.jf.connected) return false;
            server = state.app.jf.server_url[0..@min(state.app.jf.server_url_len, state.app.jf.server_url.len)];
            token = state.app.jf.token[0..@min(state.app.jf.token_len, state.app.jf.token.len)];
        },
        .plex => {
            server = plex_server[0..plex_server_len];
            token = plex_token[0..plex_token_len];
        },
    }
    if (server.len == 0 or token.len == 0) return false;
    update.server_len = @min(server.len, update.server.len);
    @memcpy(update.server[0..update.server_len], server[0..update.server_len]);
    update.token_len = @min(token.len, update.token.len);
    @memcpy(update.token[0..update.token_len], token[0..update.token_len]);
    if (update.provider == .jellyfin or update.provider == .plex) {
        const id = if (state.app.install_id[0] != 0) state.app.install_id[0..] else "opal";
        update.device_id_len = @min(id.len, update.device_id.len);
        @memcpy(update.device_id[0..update.device_id_len], id[0..update.device_id_len]);
    }
    return true;
}

fn enqueueLocked(update: Update, spawn_worker: *bool) void {
    if (findPending(update.provider, update.event, update.item[0..update.item_len])) |idx| {
        pending[idx] = update;
    } else if (pending_count < pending.len) {
        pending[pending_count] = update;
        pending_count += 1;
    } else {
        pending[0] = update;
    }
    if (!running) {
        running = true;
        spawn_worker.* = true;
    }
}

fn spawnLocked(needed: bool) void {
    if (!needed) return;
    workers.spawn(run, .{}) catch {
        running = false;
    };
}

fn run() void {
    while (!workers.isQuitting()) {
        mutex.lock();
        if (pending_count == 0) {
            running = false;
            mutex.unlock();
            return;
        }
        var update = pending[0];
        var i: usize = 1;
        while (i < pending_count) : (i += 1) pending[i - 1] = pending[i];
        pending_count -= 1;
        @memset(&pending[pending_count].token, 0);
        mutex.unlock();

        var ok = false;
        const session_gate = if (update.provider == .jellyfin and update.event != .started) sessionGate(&update) else .ready;
        if (session_gate == .wait) {
            @memset(&update.token, 0);
            continue;
        }
        if (update.provider == .jellyfin and update.event != .started and session_gate == .retry) {
            var start = update;
            start.event = .started;
            start.position = 0;
            start.duration = 0;
            const start_ok = sendJellyfin(&start);
            recordResult(&start, start_ok);
            if (!start_ok) {
                @memset(&update.token, 0);
                continue;
            }
            ok = sendJellyfin(&update);
        } else {
            ok = switch (update.provider) {
                .audiobookshelf => sendAudiobookshelf(&update),
                .jellyfin => sendJellyfin(&update),
                .plex => sendPlex(&update),
            };
        }
        recordResult(&update, ok);
        @memset(&update.token, 0);
    }
    mutex.lock();
    running = false;
    for (pending[0..pending_count]) |*entry| @memset(&entry.token, 0);
    pending_count = 0;
    mutex.unlock();
}

fn sendAudiobookshelf(update: *const Update) bool {
    var url_buf: [896]u8 = undefined;
    const server = std.mem.trimEnd(u8, update.server[0..update.server_len], "/");
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/me/progress/{s}", .{ server, update.item[0..update.item_len] }) catch return false;
    var auth_buf: [320]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{update.token[0..update.token_len]}) catch return false;
    var body_buf: [128]u8 = undefined;
    const body = pure.absProgressBody(update.position, update.duration, &body_buf) orelse return false;
    return post(url, .PATCH, auth, body, 16 * 1024);
}

fn sendJellyfin(update: *const Update) bool {
    var url_buf: [512]u8 = undefined;
    const server = std.mem.trimEnd(u8, update.server[0..update.server_len], "/");
    const suffix = switch (update.event) {
        .started => "/Sessions/Playing",
        .progress, .paused => "/Sessions/Playing/Progress",
        .stopped => "/Sessions/Playing/Stopped",
    };
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ server, suffix }) catch return false;
    var auth_buf: [768]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Authorization: MediaBrowser Client=\"Opal\", Device=\"Desktop\", DeviceId=\"{s}\", Version=\"{s}\", Token=\"{s}\"", .{ update.device_id[0..update.device_id_len], @import("../core/app_meta.zig").version, update.token[0..update.token_len] }) catch return false;
    var body_buf: [384]u8 = undefined;
    const body = pure.jellyfinProgressBody(update.item[0..update.item_len], update.event, update.position, update.duration, &body_buf) orelse return false;
    return post(url, .POST, auth, body, 4096);
}

fn sendPlex(update: *const Update) bool {
    var url_buf: [1024]u8 = undefined;
    const url = pure.plexTimelineUrl(
        update.server[0..update.server_len],
        update.item[0..update.item_len],
        update.event,
        update.position,
        update.duration,
        &url_buf,
    ) orelse return false;
    var token_header_buf: [180]u8 = undefined;
    const token_header = std.fmt.bufPrint(&token_header_buf, "X-Plex-Token: {s}", .{update.token[0..update.token_len]}) catch return false;
    const client_id = update.device_id[0..update.device_id_len];
    const extra_headers = [_]std.http.Header{
        .{ .name = "X-Plex-Product", .value = "Opal" },
        .{ .name = "X-Plex-Client-Identifier", .value = client_id },
        .{ .name = "X-Plex-Version", .value = @import("../core/app_meta.zig").version },
        .{ .name = "X-Plex-Platform", .value = "Desktop" },
        .{ .name = "X-Plex-Device", .value = "Desktop" },
        .{ .name = "X-Plex-Device-Name", .value = "Opal" },
    };
    var response_buf: [4096]u8 = undefined;
    var status: ?std.http.Status = null;
    _ = http.fetch(url, &response_buf, .{
        .timeout_secs = 8,
        .method = .POST,
        .accept = "application/xml",
        .auth_header = token_header,
        .extra_headers = &extra_headers,
        .max_response = response_buf.len,
        .status_out = &status,
    });
    return if (status) |value| @intFromEnum(value) >= 200 and @intFromEnum(value) < 300 else false;
}

fn post(url: []const u8, method: std.http.Method, auth: []const u8, body: []const u8, comptime response_size: usize) bool {
    var response_buf: [response_size]u8 = undefined;
    var status: ?std.http.Status = null;
    _ = http.fetch(url, &response_buf, .{
        .timeout_secs = 8,
        .method = method,
        .payload = body,
        .content_type = "application/json",
        .accept = "application/json",
        .auth_header = auth,
        .max_response = response_buf.len,
        .status_out = &status,
    });
    return if (status) |value| @intFromEnum(value) >= 200 and @intFromEnum(value) < 300 else false;
}

fn recordResult(update: *const Update, ok: bool) void {
    mutex.lock();
    defer mutex.unlock();
    const idx = findSeen(update.provider, update.item[0..update.item_len]) orelse return;
    if (ok) {
        seen[idx].failures = 0;
        seen[idx].next_retry_ms = 0;
        if (update.event == .started) seen[idx].session_ready = true;
        return;
    }
    seen[idx].failures +|= 1;
    const shift: u6 = @intCast(@min(seen[idx].failures - 1, 5));
    const delay_ms: i64 = @as(i64, 5_000) << shift;
    seen[idx].next_retry_ms = io.monotonicMilliTimestamp() + @min(delay_ms, 120_000);
    if (seen[idx].failures == 1)
        logs.pushLog("warn", "progress", "Server progress sync delayed; local resume remains saved", false);
}

const SessionGate = enum { ready, retry, wait };

fn sessionGate(update: *const Update) SessionGate {
    mutex.lock();
    defer mutex.unlock();
    const idx = findSeen(update.provider, update.item[0..update.item_len]) orelse return .retry;
    if (seen[idx].session_ready) return .ready;
    if (io.monotonicMilliTimestamp() >= seen[idx].next_retry_ms) return .retry;
    return .wait;
}

fn same(provider: pure.Provider, item: []const u8, other_provider: pure.Provider, other: []const u8) bool {
    return provider == other_provider and std.mem.eql(u8, item, other);
}

fn findPending(provider: pure.Provider, event: pure.Event, item: []const u8) ?usize {
    for (pending[0..pending_count], 0..) |*entry, idx| {
        if (event == entry.event and same(provider, item, entry.provider, entry.item[0..entry.item_len])) return idx;
    }
    return null;
}

fn findSeen(provider: pure.Provider, item: []const u8) ?usize {
    for (seen[0..seen_count], 0..) |*entry, idx| {
        if (same(provider, item, entry.provider, entry.item[0..entry.item_len])) return idx;
    }
    return null;
}

fn remember(provider: pure.Provider, item: []const u8, position: f64) void {
    const idx = if (seen_count < seen.len) blk: {
        const result = seen_count;
        seen_count += 1;
        break :blk result;
    } else 0;
    seen[idx] = .{ .provider = provider, .position = position };
    seen[idx].item_len = @min(item.len, seen[idx].item.len);
    @memcpy(seen[idx].item[0..seen[idx].item_len], item[0..seen[idx].item_len]);
}
