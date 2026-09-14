const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_global = @import("../core/io_global.zig");
const anilist_pure = @import("anilist_pure.zig");
const secret_store = @import("../core/secret_store.zig");
const outbox = @import("sync_outbox.zig");
const workers = @import("../core/workers.zig");

// ══════════════════════════════════════════════════════════
// AniList Sync — anime watch progress via GraphQL API
// ══════════════════════════════════════════════════════════

const ANILIST_API = "https://graphql.anilist.co";

pub var access_token: [2048]u8 = std.mem.zeroes([2048]u8);
pub var access_token_len: usize = 0;
pub var client_id: [32]u8 = std.mem.zeroes([32]u8);
pub var client_id_len: usize = 0;
pub var enabled: std.atomic.Value(bool) = .init(false);
var outbox_busy: std.atomic.Value(bool) = .init(false);
var authorization_revoked: std.atomic.Value(bool) = .init(false);
var credential_mutex: @import("../core/sync.zig").Mutex = .{};

pub const AccountSnapshot = struct { connected: bool, has_client_id: bool, queued: usize, needs_reauth: bool };

pub fn snapshot() AccountSnapshot {
    credential_mutex.lock();
    const has_token = access_token_len > 0;
    const has_client = client_id_len > 0;
    credential_mutex.unlock();
    return .{ .connected = enabled.load(.acquire) and has_token, .has_client_id = has_client, .queued = outbox.count("anilist"), .needs_reauth = authorization_revoked.load(.acquire) };
}

fn cfgPath(buf: []u8) []const u8 {
    var config: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/anilist.json", .{@import("../core/paths.zig").configDir(&config)}) catch "";
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
    if (parsed.value.object.get("client_id")) |id| if (id == .string and validClientId(id.string)) {
        @memcpy(client_id[0..id.string.len], id.string);
        client_id_len = id.string.len;
    };
    const value = parsed.value.object.get("access_token") orelse return;
    if (value != .string) return;
    const plain = secret_store.reveal(value.string, &access_token) orelse return;
    access_token_len = plain.len;
    enabled.store(access_token_len > 0, .release);
    if (!secret_store.isSealed(value.string)) save();
    if (enabled.load(.acquire)) kickOutbox();
}

fn save() void {
    var protected: [4096]u8 = undefined;
    defer @memset(&protected, 0);
    const sealed = secret_store.seal(access_token[0..access_token_len], &protected) orelse return;
    var body_buf: [4352]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"client_id\":\"{s}\",\"access_token\":\"{s}\"}}", .{ client_id[0..client_id_len], sealed }) catch return;
    var path_buf: [600]u8 = undefined;
    @import("../core/secret_file.zig").write(cfgPath(&path_buf), body) catch {};
}

fn validClientId(id: []const u8) bool {
    if (id.len == 0 or id.len > client_id.len) return false;
    for (id) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

pub fn setClientId(id: []const u8) bool {
    if (!validClientId(id)) return false;
    credential_mutex.lock();
    defer credential_mutex.unlock();
    @memset(&client_id, 0);
    @memcpy(client_id[0..id.len], id);
    client_id_len = id.len;
    save();
    return true;
}

pub fn authorizationUrl(buf: []u8) []const u8 {
    credential_mutex.lock();
    defer credential_mutex.unlock();
    if (client_id_len == 0) return "";
    return std.fmt.bufPrint(buf, "https://anilist.co/api/v2/oauth/authorize?client_id={s}&response_type=token", .{client_id[0..client_id_len]}) catch "";
}

pub fn setToken(token: []const u8) bool {
    if (token.len == 0 or token.len > access_token.len) return false;
    credential_mutex.lock();
    @memset(&access_token, 0);
    @memcpy(access_token[0..token.len], token);
    access_token_len = token.len;
    authorization_revoked.store(false, .release);
    enabled.store(true, .release);
    save();
    credential_mutex.unlock();
    kickOutbox();
    return true;
}

pub fn disconnect() void {
    credential_mutex.lock();
    @memset(&access_token, 0);
    access_token_len = 0;
    enabled.store(false, .release);
    authorization_revoked.store(false, .release);
    save();
    credential_mutex.unlock();
}

/// Update watch progress for an anime on AniList.
/// `media_id` is the AniList media ID, `episode` is the episode number.
pub fn updateProgress(media_id: i64, episode: i32) void {
    // A revoked account keeps its invalid token in memory as the explicit
    // "was connected" marker until disconnect/replacement. Continue coalescing
    // progress while offline; kickOutbox stays disabled until reconnection.
    credential_mutex.lock();
    const configured = access_token_len > 0;
    credential_mutex.unlock();
    if (!configured or media_id <= 0) return;
    var gql_buf: [512]u8 = undefined;
    const payload = std.fmt.bufPrint(&gql_buf,
        \\{{"query":"mutation {{ SaveMediaListEntry(mediaId: {d}, progress: {d}, status: CURRENT) {{ id progress }} }}"}}
    , .{ media_id, episode }) catch return;
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "media:{d}", .{media_id}) catch return;
    if (outbox.enqueue("anilist", "progress", key, payload)) kickOutbox();
}

pub fn pendingCount() usize {
    return outbox.count("anilist");
}

pub fn retryPending() void {
    outbox.retryNow("anilist");
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
        if (!outbox.nextDue("anilist", now, &job)) return;
        switch (postMutation(job.payload[0..job.payload_len])) {
            .success => {
                outbox.complete(job.id);
                continue;
            },
            .revoked => {
                authorization_revoked.store(true, .release);
                enabled.store(false, .release);
                outbox.deferFailure(job.id, job.attempts, now, "Authorization revoked; reconnect required");
                logs.pushLog("error", "anilist", "AniList authorization was revoked; reconnect to resume queued sync", true);
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

fn postMutation(payload: []const u8) Delivery {
    const alloc = @import("../core/alloc.zig").allocator;
    var token: [2048]u8 = undefined;
    defer @memset(&token, 0);
    credential_mutex.lock();
    const token_len = access_token_len;
    @memcpy(token[0..token_len], access_token[0..token_len]);
    credential_mutex.unlock();
    if (token_len == 0) return .retry;
    var auth_buf: [2200]u8 = undefined;
    const auth = std.fmt.bufPrintZ(&auth_buf, "Authorization: Bearer {s}", .{token[0..token_len]}) catch return .retry;
    var child = io_global.Child.init(&.{
        "curl",                     "-sS",      "--connect-timeout", "5",  "--max-time",                     "15",
        "-X",                       "POST",     ANILIST_API,         "-H", "Content-Type: application/json", "-H",
        "Accept: application/json", "--config", "-",                 "-d", payload,                          "-o",
        io_global.devNull(),        "-w",       "%{http_code}",
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    @import("../core/curl_secret.zig").spawnWithHeaders(&child, &.{auth}) catch return .retry;
    var status_buf: [16]u8 = undefined;
    const status_len = if (child.stdout) |*stdout| io_global.readAll(stdout, &status_buf) catch 0 else 0;
    const result = child.wait() catch return .retry;
    if (result != .exited or result.exited != 0) return .retry;
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, status_buf[0..status_len], " \r\n\t"), 10) catch return .retry;
    if (status >= 200 and status < 300) {
        logs.pushLog("info", "anilist", "AniList progress updated", false);
        return .success;
    }
    if (status == 401) return .revoked;
    logs.pushLog("warn", "anilist", "AniList sync queued for retry", false);
    return .retry;
}

/// Fetch AniList metadata for a batch of MAL ids in ONE keyless GraphQL query.
/// `ids_csv` is a comma-separated list of MAL ids (e.g. "1535,9999"). Writes the
/// raw JSON response into `out` and returns the byte count (0 on any failure).
/// The caller parses `out` with `anilist_pure.Iter`.
///
/// SFW-gated: when `sfw` is true the `media(...)` selector carries
/// `isAdult: false`, so AniList itself drops adult entries — the same intent as
/// the anime tab's Jikan `sfw=true` param (see anime_pure.sfwSuffix). Runs on
/// the caller's (worker) thread; does no allocation of its own beyond curl.
pub fn fetchMetaByMalIds(ids_csv: []const u8, sfw: bool, out: []u8) usize {
    if (ids_csv.len == 0) return 0;
    const alloc = @import("../core/alloc.zig").allocator;

    var gql_buf: [2048]u8 = undefined;
    const gql = std.fmt.bufPrintZ(&gql_buf,
        \\{{"query":"query {{ Page(perPage: 50) {{ media(idMal_in: [{s}], type: ANIME{s}) {{ id idMal averageScore title {{ romaji english }} coverImage {{ large }} episodes seasonYear description(asHtml: false) }} }} }}"}}
    , .{ ids_csv, anilist_pure.adultGate(sfw) }) catch return 0;

    var child = io_global.Child.init(&.{
        "curl", "-s",                             "-X", "POST",                     ANILIST_API,
        "-H",   "Content-Type: application/json", "-H", "Accept: application/json", "-d",
        gql,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;

    const n = if (child.stdout) |*s| io_global.readAll(s, out) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

/// Search AniList for an anime by title, return media ID.
pub fn searchAnime(title: []const u8, out_id: *i64) void {
    if (title.len == 0) return;
    const alloc = @import("../core/alloc.zig").allocator;

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

    var gql_buf: [512]u8 = undefined;
    const gql = std.fmt.bufPrintZ(&gql_buf,
        \\{{"query":"{{ Media(search: \"{s}\", type: ANIME) {{ id title {{ romaji english }} }} }}"}}
    , .{esc[0..ei]}) catch return;

    var child = io_global.Child.init(&.{
        "curl", "-s",                             "-X", "POST",                     ANILIST_API,
        "-H",   "Content-Type: application/json", "-H", "Accept: application/json", "-d",
        gql,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;

    var out: [4096]u8 = undefined;
    const n = if (child.stdout) |*s| io_global.readAll(s, &out) catch 0 else 0;
    _ = child.wait() catch {};

    if (n < 10) return;
    // Extract "id":NNNN from response
    if (std.mem.indexOf(u8, out[0..n], "\"id\":")) |idx| {
        const start = idx + 5;
        var end = start;
        while (end < n and out[end] >= '0' and out[end] <= '9') end += 1;
        if (end > start) {
            out_id.* = std.fmt.parseInt(i64, out[start..end], 10) catch 0;
        }
    }
}
