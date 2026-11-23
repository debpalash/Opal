//! TheTVDB v4 fallback (anime and obscure shows): login, token cache, rate
//! limit, HTTP. Every decision lives in tvdb_pure.zig.
//!
//! Inert unless the user supplied a key (state.app.tvdb_api_key; Settings is
//! the web UI's Setup page or $OPAL_TVDB_KEY). The key and the bearer token
//! are never logged or put in a URL. All calls are worker / connection-thread
//! only (they block), and every request goes through rate_limit.zig.
//!
//! UNVERIFIED against the live service: no key was available while this was
//! written. The request/response shapes follow the public v4 docs and are
//! pinned by the fixtures in tvdb_pure.zig.

const std = @import("std");
const pure = @import("tvdb_pure.zig");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const io = @import("../core/io_global.zig");
const http = @import("../core/http.zig");
const logs = @import("../core/logs.zig");
const rate_limit = @import("../core/rate_limit.zig");
const alloc = @import("../core/alloc.zig").allocator;

const RESPONSE_MAX: usize = 1024 * 1024;

var mutex: sync.Mutex = .{};
/// Guarded by `mutex`.
var token: [pure.TOKEN_MAX]u8 = std.mem.zeroes([pure.TOKEN_MAX]u8);
var token_len: usize = 0;
var token_expires_s: i64 = 0;
/// Login failed with this key (wrong key): stop hammering until it changes.
var bad_key_hash: u64 = 0;

/// TMDB id -> TVDB series id, so a season change does not resolve again.
const IdSlot = struct { tmdb_id: i32 = 0, tvdb_id: u32 = 0 };
var ids: [64]IdSlot = @as([64]IdSlot, @splat(.{}));
var ids_next: usize = 0;

pub fn hasKey() bool {
    return state.app.tvdb_api_key_len > 0;
}

/// Drop the cached token (the key changed).
pub fn forgetToken() void {
    mutex.lock();
    defer mutex.unlock();
    @memset(&token, 0);
    token_len = 0;
    token_expires_s = 0;
    bad_key_hash = 0;
}

fn keyCopy(out: *[pure.KEY_MAX]u8) []const u8 {
    const n = @min(state.app.tvdb_api_key_len, out.len);
    @memcpy(out[0..n], state.app.tvdb_api_key[0..n]);
    return out[0..n];
}

/// Copy a valid bearer token into `out`, logging in when needed.
fn bearer(out: *[pure.TOKEN_MAX]u8) ?[]const u8 {
    var key_buf: [pure.KEY_MAX]u8 = undefined;
    const key = keyCopy(&key_buf);
    if (key.len == 0) return null;
    const key_hash = std.hash.Wyhash.hash(0x7d, key);
    const now = io.timestamp();
    mutex.lock();
    if (token_len > 0 and now < token_expires_s) {
        @memcpy(out[0..token_len], token[0..token_len]);
        const n = token_len;
        mutex.unlock();
        return out[0..n];
    }
    const known_bad = bad_key_hash == key_hash;
    mutex.unlock();
    if (known_bad) return null;

    var body_buf: [256]u8 = undefined;
    const body = pure.loginBody(key, &body_buf) orelse return null;
    rate_limit.acquire("tvdb", pure.RATE_PER_SEC);
    const resp_buf = alloc.alloc(u8, 16 * 1024) catch return null;
    defer alloc.free(resp_buf);
    var status: ?std.http.Status = null;
    const resp = http.fetch(pure.API_BASE ++ "/login", resp_buf, .{
        .status_out = &status,
        .method = .POST,
        .payload = body,
        .content_type = "application/json",
        .accept = "application/json",
        .max_response = 16 * 1024,
        .timeout_secs = 12,
    });
    // Scrub the request body (it holds the key).
    @memset(&body_buf, 0);
    const got = if (resp) |r| pure.parseToken(alloc, r, out) else null;
    mutex.lock();
    defer mutex.unlock();
    if (got) |t| {
        @memcpy(token[0..t.len], t);
        token_len = t.len;
        token_expires_s = now + pure.TOKEN_TTL_S;
        bad_key_hash = 0;
        return t;
    }
    // 401 means the key was refused; a transport failure (no status) may just
    // be the network, so allow a retry.
    if (status == .unauthorized) {
        bad_key_hash = key_hash;
        logs.pushLog("warn", "tvdb", "TheTVDB refused the key; check it on the Setup page", true);
    }
    return null;
}

/// GET `path` (under API_BASE) with the bearer token; one re-login when the
/// token was rejected. Caller frees.
fn get(path: []const u8) ?[]u8 {
    var status: ?std.http.Status = null;
    if (getOnce(path, &status)) |body| return body;
    if (status != .unauthorized) return null;
    mutex.lock();
    token_len = 0;
    token_expires_s = 0;
    mutex.unlock();
    return getOnce(path, &status);
}

fn getOnce(path: []const u8, status: *?std.http.Status) ?[]u8 {
    var tok_buf: [pure.TOKEN_MAX]u8 = undefined;
    const tok = bearer(&tok_buf) orelse return null;
    var auth_buf: [pure.TOKEN_MAX + 32]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{tok}) catch return null;
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ pure.API_BASE, path }) catch return null;
    rate_limit.acquire("tvdb", pure.RATE_PER_SEC);
    const buf = alloc.alloc(u8, RESPONSE_MAX) catch return null;
    defer alloc.free(buf);
    const resp = http.fetch(url, buf, .{
        .status_out = status,
        .auth_header = auth,
        .accept = "application/json",
        .max_response = RESPONSE_MAX,
        .timeout_secs = 15,
    });
    @memset(&auth_buf, 0);
    const r = resp orelse return null;
    return alloc.dupe(u8, r) catch null;
}

fn cachedSeriesId(tmdb_id: i32) ?u32 {
    mutex.lock();
    defer mutex.unlock();
    for (ids) |s| if (s.tmdb_id == tmdb_id and s.tvdb_id != 0) return s.tvdb_id;
    return null;
}

fn rememberSeriesId(tmdb_id: i32, tvdb_id: u32) void {
    mutex.lock();
    defer mutex.unlock();
    ids[ids_next] = .{ .tmdb_id = tmdb_id, .tvdb_id = tvdb_id };
    ids_next = (ids_next + 1) % ids.len;
}

/// TVDB series for a TMDB show: TMDB's own external_ids first, then TVDB's
/// remote-id search by IMDb id.
fn resolveSeries(tmdb_id: i32, imdb: []const u8, tmdb_key: []const u8) ?u32 {
    if (cachedSeriesId(tmdb_id)) |id| return id;
    var found: ?u32 = null;
    if (tmdb_key.len > 0 and tmdb_id > 0) {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/3/tv/{d}/external_ids", .{tmdb_id}) catch "";
        if (path.len > 0) if (@import("tmdb_api.zig").tmdbApiOwned(path, tmdb_key, 64 * 1024)) |body| {
            defer alloc.free(body);
            found = pure.seriesIdFromExternalIds(alloc, body);
        };
    }
    if (found == null and @import("cinemeta_pure.zig").validImdbId(imdb)) {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/search/remoteid/{s}", .{imdb}) catch "";
        if (path.len > 0) if (get(path)) |body| {
            defer alloc.free(body);
            found = pure.seriesIdFromRemoteId(alloc, body);
        };
    }
    if (found) |id| rememberSeriesId(tmdb_id, id);
    return found;
}

/// Worker threads. Given TMDB's answer for `/tv/{id}/season/{n}` (null when
/// TMDB failed or has no such season), return a TMDB-shaped document with the
/// gaps filled from TVDB, or null when TVDB is off, not needed, or has nothing.
/// Caller owns the result (core allocator).
pub fn completeSeason(tmdb_id: i32, season: i32, tmdb_body: ?[]const u8, imdb: []const u8, tmdb_key: []const u8) ?[]u8 {
    if (!hasKey() or season < 0) return null;
    if (!pure.seasonIncomplete(alloc, tmdb_body)) return null;
    const series = resolveSeries(tmdb_id, imdb, tmdb_key) orelse return null;
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/series/{d}/episodes/default?page=0&season={d}", .{ series, season }) catch return null;
    const body = get(path) orelse return null;
    defer alloc.free(body);
    const eps = alloc.alloc(pure.Episode, pure.MAX_EPISODES) catch return null;
    defer alloc.free(eps);
    const n = pure.parseEpisodes(alloc, body, season, eps);
    if (n == 0) return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    pure.writeMergedSeason(alloc, &out.writer, tmdb_body, season, eps[0..n]) catch return null;
    logs.pushLog("info", "tvdb", "Filled missing episode data from TheTVDB", false);
    return out.toOwnedSlice() catch null;
}

/// Worker threads. TMDB found no show for `query`: append TVDB matches that
/// carry an identity Opal can open (a TMDB id, or an IMDb id for the keyless
/// Cinemeta path) as catalog rows. Returns how many were added.
pub fn searchFallback(query: []const u8, out: *std.ArrayListUnmanaged(state.TmdbItem)) usize {
    if (!hasKey()) return 0;
    const q = std.mem.trim(u8, query, " ");
    if (q.len == 0) return 0;
    var enc_buf: [512]u8 = undefined;
    const enc = http.urlEncode(pure.splitYear(q).title, &enc_buf);
    var path_buf: [640]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/search?query={s}&type=series&limit=10", .{enc}) catch return 0;
    const body = get(path) orelse return 0;
    defer alloc.free(body);
    var cands: [pure.MAX_CANDIDATES]pure.Candidate = undefined;
    var n = pure.parseSearch(alloc, body, &cands);
    n = pure.rankCandidates(q, cands[0..n]);
    var added: usize = 0;
    for (cands[0..n]) |*c| {
        const id = pure.catalogId(c) orelse continue;
        var it: state.TmdbItem = .{ .id = id };
        copy(&it.title, &it.title_len, c.displayTitle());
        copy(&it.overview, &it.overview_len, c.overview[0..c.overview_len]);
        copy(&it.media_type, &it.media_type_len, "tv");
        copy(&it.imdb_id, &it.imdb_id_len, c.imdbText());
        copy(&it.poster_path, &it.poster_path_len, c.image[0..c.image_len]);
        if (c.year > 0) {
            const y = std.fmt.bufPrint(&it.year, "{d}", .{c.year}) catch "";
            it.year_len = y.len;
        }
        if (c.tmdb_id <= 0) @import("tmdb_api.zig").rememberIdentity(.series, id, c.imdbText());
        out.append(alloc, it) catch break;
        added += 1;
    }
    if (added > 0) logs.pushLog("info", "tvdb", "TMDB had no match; showing TheTVDB results", false);
    return added;
}

fn copy(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}
