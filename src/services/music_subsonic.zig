//! Music (Subsonic/OpenSubsonic) tab — the AUDIO twin of iptv.zig. Search a
//! self-hosted music server (Navidrome/Airsonic/Gonic/Funkwhale/Ampache), play a
//! track by handing its `stream` URL straight to mpv. All URL/auth/JSON logic is
//! in music_subsonic_pure.zig (tested); this module owns the async fetch worker,
//! thread-safety, cover art, and dvui rendering.
//!
//! Opt-in: source_config "subsonic" with base/user/pass. Not configured →
//! creds() is null → the tab is INERT (shows a hint). The auth token is
//! md5(pass+salt) with a per-session random salt; the password is never logged
//! and never placed in a cache key.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const pure = @import("music_subsonic_pure.zig");
const js_pure = @import("music_jiosaavn_pure.zig");
const jf_pure = @import("music_jellyfin_pure.zig");
const px_pure = @import("music_plex_pure.zig");
const paths = @import("../core/paths.zig");
const components = @import("../ui/components.zig");
const io = @import("../core/io_global.zig");
const poster = @import("../core/poster.zig");
const source_config = @import("../core/source_config.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;
const lyrics = @import("lyrics.zig");
const mpvc = @import("../core/c.zig");
const alloc = @import("../core/alloc.zig").allocator;

const agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

// ══════════════════════════════════════════════════════════
// Auth (per-session salt; token = md5(pass+salt))
// ══════════════════════════════════════════════════════════
var salt_hex: [12]u8 = undefined;
var salt_ready: bool = false;

fn ensureSalt() void {
    if (salt_ready) return;
    // The salt only needs to be non-repeating (it varies the token so the raw
    // password is never sent), not a crypto secret — a clock-seeded PRNG is
    // sufficient and avoids std.crypto.random (removed in Zig 0.16).
    var raw: [6]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@bitCast(io.milliTimestamp()));
    prng.random().bytes(&raw);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        salt_hex[i * 2] = hex[b >> 4];
        salt_hex[i * 2 + 1] = hex[b & 0xF];
    }
    salt_ready = true;
}

fn cfg(field: []const u8) ?[]const u8 {
    return source_config.get("subsonic", field);
}

const Creds = struct { base: []const u8, authq: []const u8 };

/// Resolve base + a fresh auth query into caller buffers, or null when the
/// "subsonic" source isn't configured. Reads pass, computes the token, and never
/// retains the password.
fn creds(base_out: []u8, authq_out: []u8) ?Creds {
    const base_raw = cfg("base") orelse return null;
    if (!pure.isValidBase(base_raw)) return null;
    const bn = @min(base_raw.len, base_out.len);
    @memcpy(base_out[0..bn], base_raw[0..bn]);

    const user = cfg("user") orelse return null;
    const pass = cfg("pass") orelse return null;
    ensureSalt();
    var tok: [32]u8 = undefined;
    pure.authToken(pass, &salt_hex, &tok);
    const authq = pure.buildAuthQuery(user, &tok, &salt_hex, authq_out);
    if (authq.len == 0) return null;
    return .{ .base = base_out[0..bn], .authq = authq };
}

/// True when the source is configured (drives the inert hint).
fn configured() bool {
    var b: [256]u8 = undefined;
    var q: [300]u8 = undefined;
    return creds(&b, &q) != null;
}

// ══════════════════════════════════════════════════════════
// Sources
// ══════════════════════════════════════════════════════════
// state.app.music.source selects the engine for search / play / download /
// cover. Every dispatch below switches on these — never on a bare integer.
pub const SRC_JIOSAAVN: u8 = 0;
pub const SRC_SUBSONIC: u8 = 1;
pub const SRC_JELLYFIN: u8 = 2;
pub const SRC_PLEX: u8 = 3;

// ── Jellyfin (source 2) ──
// Reuses the sign-in `jellyfin.zig` already performed; there is no second
// login. Not signed in → jfCreds() is null → the source is INERT.

const ServerCreds = struct { base: []const u8, token: []const u8 };

fn jfCreds(base_out: []u8, tok_out: []u8) ?ServerCreds {
    const jf = &state.app.jf;
    if (!jf.connected or jf.server_url_len == 0 or jf.token_len == 0) return null;
    const bn = @min(jf.server_url_len, base_out.len);
    @memcpy(base_out[0..bn], jf.server_url[0..bn]);
    if (!jf_pure.isValidBase(base_out[0..bn])) return null;
    const tn = @min(jf.token_len, tok_out.len);
    @memcpy(tok_out[0..tn], jf.token[0..tn]);
    return .{ .base = base_out[0..bn], .token = tok_out[0..tn] };
}

// ── Plex (source 3) ──
// `plex.zig` keeps its token/server URI in module-private state, but it PERSISTS
// both to `~/.config/opal/plex.json` on every sign-in — so the Music tab reads
// that file rather than forcing a second PIN flow (or a cross-module accessor).
// The file is re-read at most every PLEX_CREDS_TTL_S so signing in mid-session
// lights the source up without a restart, and a signed-out state can't pin a
// stale token. UI-thread only; the worker gets a snapshot before it spawns.
const PLEX_CREDS_TTL_S: i64 = 5;
var plex_base: [256]u8 = undefined;
var plex_base_len: usize = 0;
var plex_token: [160]u8 = undefined;
var plex_token_len: usize = 0;
var plex_checked_s: i64 = 0;

fn plexCreds(base_out: []u8, tok_out: []u8) ?ServerCreds {
    const now = io.timestamp();
    // A backwards clock (NTP step / suspend) must not wedge the refresh.
    if (plex_checked_s == 0 or now < plex_checked_s or now - plex_checked_s >= PLEX_CREDS_TTL_S) {
        plex_checked_s = now;
        plex_base_len = 0;
        plex_token_len = 0;
        var pb: [600]u8 = undefined;
        var cb: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/plex.json", .{paths.configDir(&cb)}) catch "";
        if (path.len > 0) {
            if (io.cwdReadFileAlloc(path, alloc, 8192)) |body| {
                defer alloc.free(body);
                if (px_pure.parseCreds(body, &plex_base, &plex_token)) |c| {
                    plex_base_len = c.base.len;
                    plex_token_len = c.token.len;
                }
            } else |_| {}
        }
    }
    if (plex_base_len == 0 or plex_token_len == 0) return null;
    const bn = @min(plex_base_len, base_out.len);
    @memcpy(base_out[0..bn], plex_base[0..bn]);
    const tn = @min(plex_token_len, tok_out.len);
    @memcpy(tok_out[0..tn], plex_token[0..tn]);
    return .{ .base = base_out[0..bn], .token = tok_out[0..tn] };
}

/// True when the ACTIVE source has everything it needs to fetch. Sources that
/// aren't configured stay inert: no spawn, no curl, no error spam — just the
/// hint in the empty grid.
fn sourceConfigured(src: u8) bool {
    var b: [256]u8 = undefined;
    var t: [320]u8 = undefined;
    return switch (src) {
        SRC_JIOSAAVN => true, // public, keyless
        SRC_SUBSONIC => configured(),
        SRC_JELLYFIN => jfCreds(&b, &t) != null,
        SRC_PLEX => plexCreds(&b, &t) != null,
        else => false,
    };
}

// ══════════════════════════════════════════════════════════
// Settings config (base/user/pass) — persisted via source_config
// ══════════════════════════════════════════════════════════

fn fillBuf(dst: []u8, src: ?[]const u8) void {
    @memset(dst, 0);
    if (src) |s| {
        const n = @min(s.len, dst.len - 1);
        @memcpy(dst[0..n], s[0..n]);
    }
}

/// Load the current source_config values into the Settings input buffers once,
/// so the fields show what's saved. UI-thread only.
pub fn prefillConfig() void {
    if (state.app.music.cfg_loaded) return;
    state.app.music.cfg_loaded = true;
    fillBuf(&state.app.music.cfg_base, cfg("base"));
    fillBuf(&state.app.music.cfg_user, cfg("user"));
    fillBuf(&state.app.music.cfg_pass, cfg("pass"));
}

fn writeEsc(w: *std.Io.Writer, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"', '\\' => w.writeAll(&.{ '\\', c }) catch {},
            else => w.writeByte(c) catch {},
        }
    }
}

/// Persist the Settings input buffers to source_config("subsonic"). Resets the
/// session salt so the next request re-derives the token from the new password.
pub fn saveConfig() void {
    const base = std.mem.sliceTo(&state.app.music.cfg_base, 0);
    const user = std.mem.sliceTo(&state.app.music.cfg_user, 0);
    const pass = std.mem.sliceTo(&state.app.music.cfg_pass, 0);

    var body: [900]u8 = undefined;
    var bw = std.Io.Writer.fixed(&body);
    bw.writeAll("{\"base\":\"") catch return;
    writeEsc(&bw, base);
    bw.writeAll("\",\"user\":\"") catch return;
    writeEsc(&bw, user);
    bw.writeAll("\",\"pass\":\"") catch return;
    writeEsc(&bw, pass);
    bw.writeAll("\"}") catch return;

    _ = source_config.install("subsonic", body[0..bw.end]);
    salt_ready = false; // new pass → new token
    state.app.music.fetch_error = false;
    logs.pushLog("info", "music", "Subsonic server saved", false);
}

// ══════════════════════════════════════════════════════════
// Thread-safety + worker snapshot
// ══════════════════════════════════════════════════════════
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Snapshots handed to the detached worker (never read the reloadable config
// table or the mutable UI search_buf from the thread).
var query_buf: [256]u8 = undefined;
var query_len: usize = 0;
var w_base: [256]u8 = undefined;
var w_base_len: usize = 0;
var w_authq: [320]u8 = undefined;
var w_authq_len: usize = 0;
// Jellyfin/Plex reuse w_base for the server origin and w_token for the API
// key / X-Plex-Token (both go in the query, not a header).
var w_token: [320]u8 = undefined;
var w_token_len: usize = 0;

const RESULTS_CAP: usize = 200;

pub fn searchMusic(query: []const u8) void {
    if (query.len == 0) return;

    state.app.music.is_loading.store(true, .release);
    state.app.music.fetch_error = false;

    // Snapshot the query BEFORE spawning.
    const n = @min(query.len, query_buf.len);
    @memcpy(query_buf[0..n], query[0..n]);
    query_len = n;
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    if (state.app.music.source == SRC_JIOSAAVN) {
        // JioSaavn — public, keyless.
        if (std.Thread.spawn(.{}, jiosaavnWorker, .{my_gen})) |t| {
            t.detach();
        } else |_| {
            state.app.music.is_loading.store(false, .release);
        }
        return;
    }

    // Every other source needs credentials. Snapshot them into the worker
    // statics BEFORE spawning — a detached thread must never read the
    // reloadable config table, plex.json, or state.app.jf.
    var b: [256]u8 = undefined;
    var tok: [320]u8 = undefined;

    // std.Thread.spawn takes the function COMPTIME, so the snapshot step picks a
    // tag and each arm spawns its own worker (no runtime fn pointer).
    switch (state.app.music.source) {
        SRC_SUBSONIC => {
            var q: [300]u8 = undefined;
            const c = creds(&b, &q) orelse return abortSearch();
            snapBase(c.base);
            w_authq_len = @min(c.authq.len, w_authq.len);
            @memcpy(w_authq[0..w_authq_len], c.authq[0..w_authq_len]);
            spawnWorker(subsonicWorker, my_gen);
        },
        SRC_JELLYFIN => {
            const c = jfCreds(&b, &tok) orelse return abortSearch();
            snapBase(c.base);
            snapToken(c.token);
            spawnWorker(jellyfinMusicWorker, my_gen);
        },
        SRC_PLEX => {
            const c = plexCreds(&b, &tok) orelse return abortSearch();
            snapBase(c.base);
            snapToken(c.token);
            spawnWorker(plexMusicWorker, my_gen);
        },
        else => return abortSearch(),
    }
}

fn spawnWorker(comptime f: fn (u32) void, my_gen: u32) void {
    if (std.Thread.spawn(.{}, f, .{my_gen})) |t| {
        t.detach();
    } else |_| {
        state.app.music.is_loading.store(false, .release);
    }
}

/// Drop the spinner and return without a fetch — the source isn't configured
/// (or is unknown). Deliberately silent: an unconfigured source is inert, and
/// the empty grid already carries the "configure this" hint.
fn abortSearch() void {
    state.app.music.is_loading.store(false, .release);
}

fn snapBase(base: []const u8) void {
    w_base_len = @min(base.len, w_base.len);
    @memcpy(w_base[0..w_base_len], base[0..w_base_len]);
}

fn snapToken(t: []const u8) void {
    w_token_len = @min(t.len, w_token.len);
    @memcpy(w_token[0..w_token_len], t[0..w_token_len]);
}

/// JioSaavn search worker — public API, no auth. Fills play_url (perma_url) +
/// a full cover URL; playback hands perma_url to mpv/yt-dlp.
fn jiosaavnWorker(my_gen: u32) void {
    defer state.app.music.is_loading.store(false, .release);

    var url_buf: [1024]u8 = undefined;
    const url = js_pure.buildSearchUrl(&url_buf, query_buf[0..query_len], 40) orelse return;

    const body = curl(url, 3 * 1024 * 1024, "") orelse {
        state.app.music.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (search_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return;

    var count: usize = 0;
    var it = js_pure.SongIter{ .json = body };
    while (it.next()) |obj| {
        if (count >= RESULTS_CAP) break;
        var tb: [160]u8 = undefined;
        var ab: [128]u8 = undefined;
        var ub: [400]u8 = undefined;
        var ib: [400]u8 = undefined;
        const s = js_pure.parseSong(obj, &tb, &ab, &ub, &ib) orelse continue;
        var row = &state.app.music.results[count];
        row.* = .{};
        copyField(&row.title, &row.title_len, s.title);
        copyField(&row.artist, &row.artist_len, s.artist);
        copyField(&row.play_url, &row.play_url_len, s.perma_url);
        var cov: [256]u8 = undefined;
        copyField(&row.cover, &row.cover_len, js_pure.coverUpgrade(s.image, &cov));
        count += 1;
    }
    state.app.music.result_count = count;
    if (count == 0) logs.pushLog("info", "music", "No tracks found", false);
}

fn subsonicWorker(my_gen: u32) void {
    defer state.app.music.is_loading.store(false, .release);

    var url_buf: [1024]u8 = undefined;
    const url = pure.buildSearchUrl(&url_buf, w_base[0..w_base_len], w_authq[0..w_authq_len], query_buf[0..query_len], 100) orelse return;

    const body = curl(url, 2 * 1024 * 1024, "") orelse {
        state.app.music.fetch_error = true;
        return;
    };
    defer alloc.free(body);

    if (search_gen.load(.acquire) != my_gen) return; // superseded

    if (!pure.responseOk(body)) {
        state.app.music.fetch_error = true;
        logs.pushLog("info", "music", "Subsonic auth/search failed — check server URL + credentials", false);
        return;
    }

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return;

    const scope = pure.songsScope(body);
    var count: usize = 0;
    var it = pure.SongIter{ .json = scope };
    while (it.next()) |obj| {
        if (count >= RESULTS_CAP) break;
        var idb: [128]u8 = undefined;
        var tb: [160]u8 = undefined;
        var ab: [128]u8 = undefined;
        var cb: [96]u8 = undefined;
        const s = pure.parseSong(obj, &idb, &tb, &ab, &cb) orelse continue;
        var row = &state.app.music.results[count];
        row.* = .{};
        copyField(&row.id, &row.id_len, s.id);
        copyField(&row.title, &row.title_len, s.title);
        copyField(&row.artist, &row.artist_len, s.artist);
        copyField(&row.cover, &row.cover_len, s.cover);
        count += 1;
    }
    state.app.music.result_count = count;
    if (count == 0) logs.pushLog("info", "music", "No tracks found", false);
}

/// Jellyfin audio search worker — twin of subsonicWorker. Fills `id` (the item
/// id, which is also its Primary-image id, so `cover` mirrors it); the stream
/// URL is built from live creds at play time, never cached in the row.
fn jellyfinMusicWorker(my_gen: u32) void {
    defer state.app.music.is_loading.store(false, .release);

    var url_buf: [1024]u8 = undefined;
    const url = jf_pure.buildSearchUrl(&url_buf, w_base[0..w_base_len], w_token[0..w_token_len], query_buf[0..query_len], 100) orelse return;

    const body = curl(url, 2 * 1024 * 1024, "application/json") orelse {
        state.app.music.fetch_error = true;
        return;
    };
    defer alloc.free(body);

    if (search_gen.load(.acquire) != my_gen) return; // superseded

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return;

    const scope = jf_pure.itemsScope(body);
    if (scope.len == 0) {
        state.app.music.fetch_error = true;
        logs.pushLog("info", "music", "Jellyfin search failed — check the server sign-in", false);
        return;
    }

    var count: usize = 0;
    var it = jf_pure.ItemIter{ .json = scope };
    while (it.next()) |obj| {
        if (count >= RESULTS_CAP) break;
        var idb: [128]u8 = undefined;
        var tb: [160]u8 = undefined;
        var ab: [128]u8 = undefined;
        const s = jf_pure.parseSong(obj, &idb, &tb, &ab) orelse continue;
        var row = &state.app.music.results[count];
        row.* = .{};
        copyField(&row.id, &row.id_len, s.id);
        copyField(&row.title, &row.title_len, s.title);
        copyField(&row.artist, &row.artist_len, s.artist);
        copyField(&row.cover, &row.cover_len, s.id); // Primary image is keyed by the item id
        count += 1;
    }
    state.app.music.result_count = count;
    if (count == 0) logs.pushLog("info", "music", "No tracks found", false);
}

/// Plex track search worker — twin of subsonicWorker. Fills `id` (ratingKey),
/// `cover` (the `thumb` path) and `play_url` (the `Part.key` path); both paths
/// are server-relative and get the base + token spliced on at use time, so a
/// token rotation can't strand a cached row.
fn plexMusicWorker(my_gen: u32) void {
    defer state.app.music.is_loading.store(false, .release);

    var url_buf: [1024]u8 = undefined;
    const url = px_pure.buildSearchUrl(&url_buf, w_base[0..w_base_len], w_token[0..w_token_len], query_buf[0..query_len], 100) orelse return;

    // Plex serves XML unless asked for JSON (plex.zig sends the same header).
    const body = curl(url, 2 * 1024 * 1024, "application/json") orelse {
        state.app.music.fetch_error = true;
        return;
    };
    defer alloc.free(body);

    if (search_gen.load(.acquire) != my_gen) return; // superseded

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return;

    // Plex omits "Metadata" entirely on a zero-result search, so an empty scope
    // is "no tracks", NOT an error — only a body that isn't a MediaContainer is.
    const scope = px_pure.metadataScope(body);
    if (scope.len == 0 and std.mem.indexOf(u8, body, "MediaContainer") == null) {
        state.app.music.fetch_error = true;
        logs.pushLog("info", "music", "Plex search failed — check the server sign-in", false);
        return;
    }

    var count: usize = 0;
    var it = px_pure.TrackIter{ .json = scope };
    while (it.next()) |obj| {
        if (count >= RESULTS_CAP) break;
        var idb: [128]u8 = undefined;
        var tb: [160]u8 = undefined;
        var ab: [128]u8 = undefined;
        var cb: [200]u8 = undefined;
        var pb: [256]u8 = undefined;
        const s = px_pure.parseSong(obj, &idb, &tb, &ab, &cb, &pb) orelse continue;
        if (s.part_key.len == 0) continue; // unplayable without a Part
        var row = &state.app.music.results[count];
        row.* = .{};
        copyField(&row.id, &row.id_len, s.id);
        copyField(&row.title, &row.title_len, s.title);
        copyField(&row.artist, &row.artist_len, s.artist);
        copyField(&row.cover, &row.cover_len, s.thumb);
        copyField(&row.play_url, &row.play_url_len, s.part_key);
        count += 1;
    }
    state.app.music.result_count = count;
    if (count == 0) logs.pushLog("info", "music", "No tracks found", false);
}

fn copyField(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

// ══════════════════════════════════════════════════════════
// Play — hand the stream URL straight to mpv
// ══════════════════════════════════════════════════════════
pub fn playSong(idx: usize) void {
    if (idx >= state.app.music.result_count) return;
    const song = &state.app.music.results[idx];

    // Snapshot title/artist into locals BEFORE the mpv handoff so nothing handed
    // to the player aliases the live results[] row a re-search could rewrite.
    var name_buf: [160]u8 = undefined;
    const nlen = @min(song.title_len, name_buf.len);
    @memcpy(name_buf[0..nlen], song.title[0..nlen]);
    var artist_buf: [128]u8 = undefined;
    const alen = @min(song.artist_len, artist_buf.len);
    @memcpy(artist_buf[0..alen], song.artist[0..alen]);

    var url_buf: [1024]u8 = undefined;
    var url: []const u8 = "";

    const id = song.id[0..@min(song.id_len, song.id.len)];
    const purl = song.play_url[0..@min(song.play_url_len, song.play_url.len)];
    var b: [256]u8 = undefined;
    var tokb: [320]u8 = undefined;

    switch (state.app.music.source) {
        SRC_JIOSAAVN => {
            // Hand the perma_url to mpv; its bundled yt-dlp resolves the signed
            // CDN audio stream (no DES, no third-party instance).
            if (purl.len == 0) return;
            const ulen = @min(purl.len, url_buf.len);
            @memcpy(url_buf[0..ulen], purl[0..ulen]);
            url = url_buf[0..ulen];
        },
        SRC_SUBSONIC => {
            // Build the authenticated stream URL from the song id + creds.
            if (id.len == 0) return;
            var q: [300]u8 = undefined;
            const c = creds(&b, &q) orelse return;
            url = pure.buildStreamUrl(&url_buf, c.base, c.authq, id) orelse return;
        },
        SRC_JELLYFIN => {
            if (id.len == 0) return;
            const c = jfCreds(&b, &tokb) orelse return;
            url = jf_pure.buildStreamUrl(&url_buf, c.base, c.token, id) orelse return;
        },
        SRC_PLEX => {
            // play_url holds the server-relative Part.key; the base + token are
            // spliced on HERE so a re-sign-in can't leave a stale token in a row.
            if (purl.len == 0) return;
            const c = plexCreds(&b, &tokb) orelse return;
            url = px_pure.buildStreamUrl(&url_buf, c.base, c.token, purl) orelse return;
        },
        else => return,
    }

    @import("browser.zig").loadContentDirectMeta(url, "", name_buf[0..nlen], artist_buf[0..alen]);
    logs.pushLog("info", "music", "Streaming track", false);

    // Synced lyrics for the NEW track: drop the previous timeline first so a
    // stale song's lines can never be shown against this one's playback clock.
    lyrics.clear();
    lyrics.requestFor(artist_buf[0..alen], name_buf[0..nlen], "", 0);
}

// ══════════════════════════════════════════════════════════
// Download to the local music dir
// ══════════════════════════════════════════════════════════
// JioSaavn → yt-dlp -x (perma_url); Subsonic → the direct `stream` bytes through
// the existing download engine. Both land in ~/Music/Opal.
const dl_pure = @import("music_download_pure.zig");

pub fn downloadSong(idx: usize) void {
    if (idx >= state.app.music.result_count) return;
    const song = &state.app.music.results[idx];

    // Music dir.
    var dir_buf: [512]u8 = undefined;
    const dir = @import("../core/paths.zig").musicSavePath(&dir_buf);
    io.cwdMakePath(dir) catch {};

    // Safe base name "artist - title".
    var name_buf: [200]u8 = undefined;
    const name = dl_pure.sanitizeName(song.artist[0..song.artist_len], song.title[0..song.title_len], &name_buf);

    if (state.app.music.source == SRC_JIOSAAVN) {
        const purl = song.play_url[0..@min(song.play_url_len, song.play_url.len)];
        if (purl.len == 0) return;
        const S = struct {
            var busy: bool = false;
            var url: [256]u8 = undefined;
            var url_len: usize = 0;
            var dirp: [512]u8 = undefined;
            var dir_len: usize = 0;
            var namep: [200]u8 = undefined;
            var name_len: usize = 0;
            fn worker() void {
                defer busy = false;
                const ytdlp = @import("ytdlp.zig");
                var out_tmpl: [256]u8 = undefined;
                const otmpl = std.fmt.bufPrint(&out_tmpl, "{s}.%(ext)s", .{namep[0..name_len]}) catch return;
                const argv = [_][]const u8{
                    ytdlp.binary(),      "-x",
                    "--audio-format",    "mp3",
                    "--audio-quality",   "0",
                    "--embed-metadata",  "--embed-thumbnail",
                    "--no-playlist",     "--paths",
                    dirp[0..dir_len],    "-o",
                    otmpl,               url[0..url_len],
                };
                var child = io.Child.init(&argv, alloc);
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;
                child.spawn() catch return;
                const term = child.wait() catch return;
                if (term == .exited and term.exited == 0) {
                    state.showToast("Downloaded to Music/Opal");
                } else {
                    state.showToast("Download failed");
                }
            }
        };
        if (S.busy) {
            state.showToast("A download is already running");
            return;
        }
        S.busy = true;
        S.url_len = @min(purl.len, S.url.len);
        @memcpy(S.url[0..S.url_len], purl[0..S.url_len]);
        S.dir_len = @min(dir.len, S.dirp.len);
        @memcpy(S.dirp[0..S.dir_len], dir[0..S.dir_len]);
        S.name_len = @min(name.len, S.namep.len);
        @memcpy(S.namep[0..S.name_len], name[0..S.name_len]);
        if (std.Thread.spawn(.{}, S.worker, .{})) |t| {
            t.detach();
            state.showToast("Downloading…");
        } else |_| {
            S.busy = false;
        }
    } else {
        // Every self-hosted source: the stream URL is a plain authed GET of the
        // original bytes, so the shared download engine can fetch it directly.
        const id = song.id[0..@min(song.id_len, song.id.len)];
        const purl = song.play_url[0..@min(song.play_url_len, song.play_url.len)];
        var b: [256]u8 = undefined;
        var tokb: [320]u8 = undefined;
        var url_buf: [1024]u8 = undefined;
        const stream = switch (state.app.music.source) {
            SRC_SUBSONIC => blk: {
                if (id.len == 0) return;
                var q: [300]u8 = undefined;
                const c = creds(&b, &q) orelse return;
                break :blk pure.buildStreamUrl(&url_buf, c.base, c.authq, id) orelse return;
            },
            SRC_JELLYFIN => blk: {
                if (id.len == 0) return;
                const c = jfCreds(&b, &tokb) orelse return;
                break :blk jf_pure.buildStreamUrl(&url_buf, c.base, c.token, id) orelse return;
            },
            SRC_PLEX => blk: {
                if (purl.len == 0) return;
                const c = plexCreds(&b, &tokb) orelse return;
                break :blk px_pure.buildStreamUrl(&url_buf, c.base, c.token, purl) orelse return;
            },
            else => return,
        };
        var dest_buf: [768]u8 = undefined;
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}.mp3", .{ dir, name }) catch return;
        if (@import("download_engine.zig").start(stream, dest)) {
            state.showToast("Downloading…");
        }
    }
}

// ══════════════════════════════════════════════════════════
// curl helper (heap buffer off the worker stack)
// ══════════════════════════════════════════════════════════
/// `accept` selects the response format for servers that content-negotiate
/// (Plex serves XML without it); pass "" when it doesn't matter.
fn curl(url: []const u8, cap: usize, accept: []const u8) ?[]u8 {
    var acc_buf: [64]u8 = undefined;
    const acc = std.fmt.bufPrint(&acc_buf, "Accept: {s}", .{accept}) catch "Accept: */*";
    const argv_plain = [_][]const u8{ "curl", "-sL", "-A", agent, "--max-time", "20", url };
    const argv_acc = [_][]const u8{ "curl", "-sL", "-A", agent, "-H", acc, "--max-time", "20", url };
    const argv: []const []const u8 = if (accept.len > 0) &argv_acc else &argv_plain;
    var child = io.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return null;
    const buf = alloc.alloc(u8, cap) catch {
        _ = child.wait() catch {};
        return null;
    };
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) {
        alloc.free(buf);
        return null;
    }
    return alloc.realloc(buf, n) catch {
        alloc.free(buf);
        return null;
    };
}

// ══════════════════════════════════════════════════════════
// UI (Browse › Music)
// ══════════════════════════════════════════════════════════
const CARD_GAP: f32 = 6;
const CARD_TARGET_W: f32 = 160;
const CARD_FOOTER_H: f32 = 46;

const CoverSlot = struct {
    pixels: ?[]u8 = null,
    tex: ?dvui.Texture = null,
    w: u32 = 0,
    h: u32 = 0,
    fetching: bool = false,
    url_hash: u64 = 0,
};
var cover_slots: [RESULTS_CAP]CoverSlot = [_]CoverSlot{.{}} ** RESULTS_CAP;

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    renderSearchBar();

    // Source selector: public streaming vs. your self-hosted library.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 0, .w = 8, .h = 6 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer row.deinit();
        // Every source is always offered (Subsonic's long-standing behaviour):
        // picking an unconfigured one is inert and the empty grid says how to
        // configure it, which is friendlier than a tab that silently vanishes.
        const sources = [_][]const u8{ "JioSaavn", "Subsonic", "Jellyfin", "Plex" };
        if (components.segment(@src(), &sources, @as(usize, state.app.music.source))) |clicked| {
            if (@as(u8, @intCast(clicked)) != state.app.music.source) {
                state.app.music.source = @intCast(clicked);
                state.app.music.result_count = 0; // switching source clears the grid
                state.app.music.fetch_error = false;
                _ = search_gen.fetchAdd(1, .acq_rel); // drop any in-flight results
            }
        }
    }

    if (state.app.music.fetch_error) {
        const emsg: []const u8 = switch (state.app.music.source) {
            SRC_JIOSAAVN => "Couldn't reach JioSaavn — check your connection",
            SRC_JELLYFIN => "Couldn't reach the Jellyfin server — check the sign-in in the Jellyfin tab",
            SRC_PLEX => "Couldn't reach the Plex server — check the sign-in in the Plex tab",
            else => "Couldn't reach the Subsonic server — check URL + credentials",
        };
        _ = dvui.label(@src(), "{s}", .{emsg}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    renderResults();
}

// ══════════════════════════════════════════════════════════
// Synced lyrics panel (lrclib) — only drawn when a timeline is loaded.
// This lives in the PLAYER view (shell.zig calls renderLyricsPanel on the
// .player route), NOT the Music tab: the Music tab is a search/browse grid,
// and showing lyrics there on the now-playing track was a misplaced surface.
// ══════════════════════════════════════════════════════════
/// Playback position of the active mpv player in milliseconds, or null when
/// there is no active player / it isn't an mpv-backed one.
fn playbackMs() ?u32 {
    if (state.app.active_player_idx >= state.app.players.items.len) return null;
    const p = state.app.players.items[state.app.active_player_idx];
    if (p.provider != .mpv) return null;
    var time_pos: f64 = 0.0;
    _ = mpvc.mpv.mpv_get_property(p.mpv_ctx, "time-pos", mpvc.mpv.MPV_FORMAT_DOUBLE, &time_pos);
    if (time_pos <= 0) return 0;
    return @intFromFloat(time_pos * 1000.0);
}

/// True when a synced-lyric timeline is currently loaded (used by the player
/// route to decide whether to reserve a lyrics column — without rendering).
pub fn lyricsHave() bool {
    return lyrics.hasLyrics();
}

pub fn renderLyricsPanel() void {
    if (!lyrics.hasLyrics()) return;

    var snap: [400]lyrics.LyricLine = undefined;
    const n = lyrics.snapshot(&snap);
    if (n == 0) return;

    const pos_ms = playbackMs() orelse 0;
    const active = lyrics.currentIndex(pos_ms);

    // Docked right column: fixed 320px width, fills the route height. It is
    // placed in a real layout slot beside the player grid (shell.zig), so it
    // never floats over the video/waveform cell.
    //
    // `.expand = .vertical` is load-bearing: in the horizontal split this makes
    // the panel a full-height slot (placeIn's vertical branch fills the split's
    // cross axis) AND makes BOTH split children vertically-expanding, so the
    // horizontal box's cross-axis height is unambiguous. Width stays pinned at
    // 320 because min==max and `.vertical` carries no horizontal weight.
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
        .min_size_content = .{ .w = 320, .h = 0 },
        .max_size_content = .{ .w = 320, .h = std.math.floatMax(f32) },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
    });
    defer panel.deinit();

    _ = dvui.label(@src(), "Lyrics", .{}, .{
        .color_text = theme.colors.text_tertiary,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    });

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .min_size_content = .{ .w = 100, .h = 100 },
        .background = false,
    });
    defer scroll.deinit();

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const is_active = (active != null and active.? == i);
        var tbuf: [pure_lyric_text_cap]u8 = undefined;
        const txt = safeUtf8Buf(snap[i].slice(), &tbuf);
        _ = dvui.label(@src(), "{s}", .{txt}, .{
            .id_extra = i + 70000,
            .expand = .horizontal,
            .color_text = if (is_active) theme.colors.text_primary else theme.colors.text_secondary,
            .font = if (is_active) dvui.themeGet().font_heading else dvui.themeGet().font_body,
            .padding = .{ .x = 2, .y = 3, .w = 2, .h = 3 },
        });
    }
}

const pure_lyric_text_cap = 256;

fn renderSearchBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer row.deinit();

    _ = dvui.icon(@src(), "", icons.tvg.lucide.music, .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.music.search_buf },
        .placeholder = "Search your music library...",
    }, .{
        .expand = .horizontal,
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .gravity_y = 0.5,
    });
    const entered = te.enter_pressed;
    te.deinit();

    const go = dvui.button(@src(), "Go", .{}, .{
        .color_fill = theme.colors.accent,
        .color_text = dvui.Color.white,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
    });
    if (entered or go) {
        const query = std.mem.sliceTo(&state.app.music.search_buf, 0);
        if (query.len > 0) searchMusic(query);
    }
    if (state.app.music.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "...", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
    }
}

fn renderCover(i: usize, song: *const pure.MusicSong) void {
    const slot = &cover_slots[i];
    const cover_field = song.cover[0..@min(song.cover_len, song.cover.len)];

    // Resolve the cover image URL. What `cover` holds is per-source: JioSaavn a
    // full URL, Subsonic a coverArt id, Jellyfin the item id, Plex a
    // server-relative `thumb` path — the last three are resolved against LIVE
    // creds here rather than being baked into the row. A big buffer holds any.
    var url_buf: [1024]u8 = undefined;
    var cover_url: []const u8 = "";
    if (cover_field.len > 0) {
        var b: [256]u8 = undefined;
        var tokb: [320]u8 = undefined;
        switch (state.app.music.source) {
            SRC_JIOSAAVN => cover_url = cover_field,
            SRC_SUBSONIC => {
                var q: [300]u8 = undefined;
                if (creds(&b, &q)) |c| {
                    if (pure.buildCoverUrl(&url_buf, c.base, c.authq, cover_field, 256)) |cov| cover_url = cov;
                }
            },
            SRC_JELLYFIN => {
                if (jfCreds(&b, &tokb)) |c| {
                    if (jf_pure.buildCoverUrl(&url_buf, c.base, c.token, cover_field)) |cov| cover_url = cov;
                }
            },
            SRC_PLEX => {
                if (plexCreds(&b, &tokb)) |c| {
                    if (px_pure.buildCoverUrl(&url_buf, c.base, c.token, cover_field)) |cov| cover_url = cov;
                }
            },
            else => {},
        }
    }

    if (cover_url.len > 0) {
        const h = std.hash.Fnv1a_64.hash(cover_url);
        if (slot.url_hash != h and !slot.fetching) {
            poster.deinitPoster(&slot.pixels, &slot.tex);
            slot.w = 0;
            slot.h = 0;
            slot.url_hash = h;
        }
        _ = poster.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.tex);
        if (slot.tex == null and !slot.fetching and slot.pixels == null)
            poster.fetchAsync(cover_url, &slot.pixels, &slot.w, &slot.h, &slot.fetching);
    }

    if (slot.tex) |*tex| {
        _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
            .id_extra = i + 1000,
            .expand = .both,
            .corner_radius = dvui.Rect.all(8),
        });
    } else {
        _ = dvui.icon(@src(), "", icons.tvg.lucide.music, .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });
    }
}

fn renderCard(i: usize, card_w: f32) void {
    const song = &state.app.music.results[i];

    var name_buf: [160]u8 = undefined;
    const title = safeUtf8Buf(song.title[0..@min(song.title_len, song.title.len)], &name_buf);

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i,
        .min_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .margin = dvui.Rect.all(CARD_GAP),
    });
    defer card.deinit();

    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = i + 2000,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(8),
            .min_size_content = .{ .w = card_w, .h = card_w },
            .max_size_content = .{ .w = card_w, .h = card_w },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();
        renderCover(i, song);
        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (clicked) playSong(i);
    }

    {
        var nrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 6000, .expand = .horizontal });
        defer nrow.deinit();
        _ = dvui.label(@src(), "{s}", .{title}, .{
            .id_extra = i + 3000,
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .gravity_y = 0.5,
            .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
        });
        if (dvui.buttonIcon(@src(), "musicdl", icons.tvg.lucide.download, .{}, .{}, .{
            .id_extra = i + 7000,
            .color_text = theme.colors.text_tertiary,
            .color_fill = theme.transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .border = dvui.Rect.all(0),
            .min_size_content = theme.iconSize(.sm),
            .padding = dvui.Rect.all(4),
            .gravity_y = 0.5,
        })) {
            downloadSong(i);
        }
    }
    if (song.artist_len > 0) {
        var a_safe: [128]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(song.artist[0..@min(song.artist_len, song.artist.len)], &a_safe)}, .{
            .id_extra = i + 4000,
            .color_text = theme.colors.text_tertiary,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
    }
}

fn renderResults() void {
    const total = @min(state.app.music.result_count, state.app.music.results.len);
    if (total == 0) {
        const src = state.app.music.source;
        const msg: []const u8 = if (!sourceConfigured(src)) switch (src) {
            SRC_JELLYFIN => "Sign in to Jellyfin (Jellyfin tab) to play its music library",
            SRC_PLEX => "Sign in to Plex (Plex tab) to play its music library",
            else => "Configure your music server (Settings) to play your self-hosted library",
        } else if (state.app.music.is_loading.load(.acquire))
            "Searching..."
        else
            "Search for music above";
        _ = dvui.label(@src(), "{s}", .{msg}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / CARD_TARGET_W)));
    const cols_f: f32 = @floatFromInt(cols);
    const card_w: f32 = @max(100, (avail_w - cols_f * 2 * CARD_GAP) / cols_f);

    var r: usize = 0;
    while (r * cols < total) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = r + 50000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and r * cols + col < total) : (col += 1) renderCard(r * cols + col, card_w);
    }
}
