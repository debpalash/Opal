//! Music discovery — the first RECOMMENDATION source in Opal.
//!
//! Every existing music backend (Subsonic, Jellyfin, Plex, JioSaavn,
//! Audiobookshelf) only plays what the user already has. This module answers
//! "what should I listen to next?" using ListenBrainz + MusicBrainz:
//!
//!   seed artists (what Opal already saw you play)
//!     → MusicBrainz artist search        → artist MBID
//!     → ListenBrainz labs similar-artists → ranked similar artists
//!     → MusicBrainz release-group browse  → STUDIO albums only
//!     → dedupe + order                    → a browsable rail in Browse › Music
//!
//! ListenBrainz was picked over Last.fm deliberately: it needs no API key and
//! its data is CC0, so Opal keeps its rule of shipping with no baked-in
//! credentials.
//!
//! INERT BY DEFAULT. `enabled()` is false on a fresh install, and nothing here
//! opens a socket until it flips — Settings › Network › "Music discovery", or a
//! `listenbrainz` source plugin appearing in source_config (whichever the user
//! reaches first). Turning it off stops all traffic immediately.
//!
//! Politeness: MusicBrainz asks for ≤1 req/sec and a descriptive, contactable
//! User-Agent — both enforced here (core/rate_limit.zig + pure.USER_AGENT).
//! Every response is cached on disk with a TTL so a second launch costs zero
//! requests, and a failed fetch backs off exponentially (429s reach us as a
//! generic failure — core/http.zig collapses non-200 statuses to null).
//!
//! All parsing / filtering / ranking / cache-key / TTL logic lives in
//! music_discovery_pure.zig and is unit-tested; this file is I/O, threading and
//! dvui only.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");

const pure = @import("music_discovery_pure.zig");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const http = @import("../core/http.zig");
const paths = @import("../core/paths.zig");
const io = @import("../core/io_global.zig");
const sync = @import("../core/sync.zig");
const rate_limit = @import("../core/rate_limit.zig");
const source_config = @import("../core/source_config.zig");
const alloc = @import("../core/alloc.zig").allocator;
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

// ══════════════════════════════════════════════════════════
// Opt-in gate
// ══════════════════════════════════════════════════════════

/// True when the user opted in. Two independent switches, matching how the rest
/// of Opal is wired: the Settings toggle (persisted in config) and the
/// source_config marker a `listenbrainz` plugin would install. Either one is
/// enough; neither present → this module never touches the network.
pub fn enabled() bool {
    return state.app.music_discovery_enabled or source_config.has("listenbrainz");
}

// ══════════════════════════════════════════════════════════
// Seeds — "what Opal can already see"
// ══════════════════════════════════════════════════════════
// A small most-recent-first ring of artist names, appended every time a track
// is played from ANY music backend (music_subsonic.playSong calls noteListen).
// Persisted to the cache dir so recommendations survive a restart. If the ring
// is empty we fall back to the artists currently listed by the configured
// backend; if that is empty too, discovery produces NOTHING — never an invented
// seed.

const SEED_RING: usize = 12;
const SEED_NAME_MAX: usize = 128;

var seed_names: [SEED_RING][SEED_NAME_MAX]u8 = std.mem.zeroes([SEED_RING][SEED_NAME_MAX]u8);
var seed_lens: [SEED_RING]usize = std.mem.zeroes([SEED_RING]usize);
var seed_count: usize = 0;
var seed_mutex: sync.Mutex = .{};
var seeds_loaded = std.atomic.Value(bool).init(false);

fn seedsFilePath(buf: []u8) []const u8 {
    return paths.cacheFile(buf, "music_seeds.txt");
}

fn loadSeeds() void {
    // Caller holds seed_mutex.
    if (seeds_loaded.load(.acquire)) return;
    seeds_loaded.store(true, .release);
    var pb: [600]u8 = undefined;
    const path = seedsFilePath(&pb);
    const body = io.cwdReadFileAlloc(path, alloc, 8 * 1024) catch return;
    defer alloc.free(body);
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (seed_count >= SEED_RING) break;
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len == 0 or name.len > SEED_NAME_MAX) continue;
        @memcpy(seed_names[seed_count][0..name.len], name);
        seed_lens[seed_count] = name.len;
        seed_count += 1;
    }
}

fn persistSeeds() void {
    // Caller holds seed_mutex.
    var out: [SEED_RING * (SEED_NAME_MAX + 1)]u8 = undefined;
    var n: usize = 0;
    for (0..seed_count) |i| {
        const name = seed_names[i][0..seed_lens[i]];
        if (n + name.len + 1 > out.len) break;
        @memcpy(out[n..][0..name.len], name);
        n += name.len;
        out[n] = '\n';
        n += 1;
    }
    paths.ensureCacheDir();
    var pb: [600]u8 = undefined;
    io.cwdWriteFile(.{ .sub_path = seedsFilePath(&pb), .data = out[0..n] }) catch {};
}

/// Record that the user just played something by `artist`. Cheap and always
/// safe to call — it does NOT enable discovery or trigger any fetch; it only
/// keeps the seed list warm for when/if the user opts in.
pub fn noteListen(artist: []const u8) void {
    const name = std.mem.trim(u8, artist, " \t\r\n");
    if (name.len == 0 or name.len > SEED_NAME_MAX) return;

    seed_mutex.lock();
    defer seed_mutex.unlock();
    loadSeeds();

    // Move-to-front on a repeat, so the ring is genuinely most-recent-first.
    var found: ?usize = null;
    for (0..seed_count) |i| {
        if (std.ascii.eqlIgnoreCase(seed_names[i][0..seed_lens[i]], name)) {
            found = i;
            break;
        }
    }
    if (found) |idx| {
        if (idx == 0) return; // already the head — nothing changed, skip the write
        var i = idx;
        while (i > 0) : (i -= 1) {
            seed_names[i] = seed_names[i - 1];
            seed_lens[i] = seed_lens[i - 1];
        }
    } else {
        if (seed_count < SEED_RING) seed_count += 1;
        var i = seed_count - 1;
        while (i > 0) : (i -= 1) {
            seed_names[i] = seed_names[i - 1];
            seed_lens[i] = seed_lens[i - 1];
        }
    }
    @memset(&seed_names[0], 0);
    @memcpy(seed_names[0][0..name.len], name);
    seed_lens[0] = name.len;
    persistSeeds();
}

/// Collect up to `out.len` seeds. UI thread only — it reads state.app.music.
/// Returns 0 when Opal has seen no artists at all (discovery then does nothing).
fn currentSeeds(out: []pure.Seed) usize {
    var names: [SEED_RING + 24][]const u8 = undefined;
    var n: usize = 0;

    seed_mutex.lock();
    loadSeeds();
    for (0..seed_count) |i| {
        if (n >= names.len) break;
        names[n] = seed_names[i][0..seed_lens[i]];
        n += 1;
    }
    const from_ring = n;

    // Fallback: whatever the configured backend is currently showing. Copied
    // here (not aliased) because the ring slices above point at static storage
    // that stays valid, while results[] can be rewritten by a search.
    var fallback: [24][128]u8 = undefined;
    var fb_used: usize = 0;
    if (from_ring == 0) {
        const total = @min(state.app.music.result_count, state.app.music.results.len);
        for (0..total) |i| {
            if (n >= names.len or fb_used >= fallback.len) break;
            const song = &state.app.music.results[i];
            const a = song.artist[0..@min(song.artist_len, song.artist.len)];
            if (a.len == 0) continue;
            const c = @min(a.len, fallback[fb_used].len);
            @memcpy(fallback[fb_used][0..c], a[0..c]);
            names[n] = fallback[fb_used][0..c];
            fb_used += 1;
            n += 1;
        }
    }

    const written = pure.collectSeeds(names[0..n], out);
    seed_mutex.unlock();
    return written;
}

// ══════════════════════════════════════════════════════════
// Disk cache (TTL'd, plain JSON — the payload is public CC0 metadata)
// ══════════════════════════════════════════════════════════
// `~/.cache/opal/music_discovery/<hash>.json`, each file prefixed with a
// `<created_ts>\n` line. Freshness routes through pure.cacheExpired so the
// shipped expiry IS the tested expiry.

fn cacheEntryPath(buf: []u8, key: []const u8) ?[]const u8 {
    var dir_buf: [600]u8 = undefined;
    const dir = paths.cacheFile(&dir_buf, "music_discovery");
    io.cwdMakePath(dir) catch {};
    const h = std.hash.Fnv1a_64.hash(key);
    return std.fmt.bufPrint(buf, "{s}/{x:0>16}.json", .{ dir, h }) catch null;
}

/// Fresh cached body for `key` copied into `buf`, or null on miss/expiry.
fn cacheGet(key: []const u8, ttl_s: i64, buf: []u8) ?[]const u8 {
    var pb: [700]u8 = undefined;
    const path = cacheEntryPath(&pb, key) orelse return null;
    const raw = io.cwdReadFileAlloc(path, alloc, MAX_BODY) catch return null;
    defer alloc.free(raw);
    const nl = std.mem.indexOfScalar(u8, raw, '\n') orelse return null;
    const created = std.fmt.parseInt(i64, raw[0..nl], 10) catch return null;
    if (pure.cacheExpired(created, ttl_s, io.timestamp())) {
        io.cwdDeleteFile(path) catch {};
        return null;
    }
    const body = raw[nl + 1 ..];
    if (body.len == 0 or body.len > buf.len) return null;
    @memcpy(buf[0..body.len], body);
    return buf[0..body.len];
}

fn cachePut(key: []const u8, body: []const u8) void {
    if (body.len == 0 or body.len > MAX_BODY) return;
    var pb: [700]u8 = undefined;
    const path = cacheEntryPath(&pb, key) orelse return;
    const blob = alloc.alloc(u8, body.len + 24) catch return;
    defer alloc.free(blob);
    const head = std.fmt.bufPrint(blob, "{d}\n", .{io.timestamp()}) catch return;
    @memcpy(blob[head.len..][0..body.len], body);
    io.cwdWriteFile(.{ .sub_path = path, .data = blob[0 .. head.len + body.len] }) catch {};
}

// ══════════════════════════════════════════════════════════
// Fetch (rate-limited, backed off, cached)
// ══════════════════════════════════════════════════════════

const MAX_BODY: usize = 512 * 1024;
const FETCH_ATTEMPTS: u32 = 3;

/// One rate-limited GET with exponential backoff. `origin_key` + `rate` feed the
/// shared token bucket so MusicBrainz never sees more than ~1 req/sec from us
/// even with several verticals fetching at once. http.fetch reports any non-200
/// (including 429) as null, so a retry-with-backoff is the available response.
fn fetchJson(url: []const u8, origin_key: []const u8, rate: f64, buf: []u8) ?[]const u8 {
    var attempt: u32 = 0;
    while (attempt < FETCH_ATTEMPTS) : (attempt += 1) {
        if (attempt > 0) io.sleep(@as(u64, pure.backoffMs(attempt - 1)) * std.time.ns_per_ms);
        if (!enabled()) return null; // user turned it off mid-flight
        rate_limit.acquire(origin_key, rate);
        if (http.fetch(url, buf, .{
            .user_agent = pure.USER_AGENT,
            .accept = "application/json",
            .max_response = buf.len,
            .timeout_secs = 15,
        })) |body| return body;
    }
    return null;
}

/// Cached GET: disk first (TTL by kind), network only on a miss.
fn fetchCached(kind: pure.CacheKind, id: []const u8, url: []const u8, origin_key: []const u8, rate: f64, buf: []u8) ?[]const u8 {
    var key_buf: [256]u8 = undefined;
    const key = pure.cacheKey(kind, id, &key_buf);
    const ttl = pure.ttlFor(kind);
    if (key) |k| {
        if (cacheGet(k, ttl, buf)) |hit| return hit;
    }
    const body = fetchJson(url, origin_key, rate, buf) orelse return null;
    if (key) |k| cachePut(k, body);
    return body;
}

// ══════════════════════════════════════════════════════════
// Published results
// ══════════════════════════════════════════════════════════

var pub_mutex: sync.Mutex = .{};
var pub_albums: [pure.MAX_ALBUMS]pure.Album = std.mem.zeroes([pure.MAX_ALBUMS]pure.Album);
var pub_count: usize = 0;
var pub_gen = std.atomic.Value(u32).init(0);

var busy = std.atomic.Value(bool).init(false);
var fetch_error = std.atomic.Value(bool).init(false);
var run_gen = std.atomic.Value(u32).init(0);
var auto_started = std.atomic.Value(bool).init(false);

// Worker input, snapshotted BEFORE the thread is spawned (a detached thread
// must never read state.app or the seed ring).
var w_seeds: [pure.MAX_SEEDS]pure.Seed = std.mem.zeroes([pure.MAX_SEEDS]pure.Seed);
var w_seed_count: usize = 0;

/// Kick a refresh. No-op when disabled, already running, or Opal has never seen
/// an artist. UI thread only.
pub fn refresh() void {
    if (!enabled()) return;
    if (busy.load(.acquire)) return;

    w_seed_count = currentSeeds(&w_seeds);
    if (w_seed_count == 0) return; // degrade to nothing — never invent a seed

    fetch_error.store(false, .release);
    busy.store(true, .release);
    const my_gen = run_gen.fetchAdd(1, .acq_rel) + 1;
    if (std.Thread.spawn(.{}, worker, .{my_gen})) |t| {
        t.detach();
    } else |_| {
        busy.store(false, .release);
    }
}

/// One-shot refresh the first time the rail is shown in a session. Keeps a
/// fresh opt-in from looking broken while still doing nothing until opt-in.
fn autoRefreshOnce() void {
    if (auto_started.load(.acquire)) return;
    auto_started.store(true, .release);
    refresh();
}

// Everything the worker needs, heap-allocated — the response buffer alone is
// 512KB, far past what a spawned thread's stack may hold.
const Work = struct {
    body: [MAX_BODY]u8 = undefined,
    similar: [pure.MAX_SIMILAR]pure.SimilarArtist = undefined,
    per_artist: [24]pure.Album = undefined,
    albums: [pure.MAX_ALBUMS]pure.Album = undefined,
};

const SIMILAR_PER_SEED: usize = 5;

fn worker(my_gen: u32) void {
    defer busy.store(false, .release);

    const w = alloc.create(Work) catch return;
    defer alloc.destroy(w);

    var total: usize = 0;
    var any_fetch_failed = false;

    seeds: for (0..w_seed_count) |si| {
        if (run_gen.load(.acquire) != my_gen or !enabled()) return;
        const seed = w_seeds[si].slice();
        if (seed.len == 0) continue;

        // 1. seed name → MusicBrainz artist MBID
        var url_buf: [1024]u8 = undefined;
        const search_url = pure.buildArtistSearchUrl(&url_buf, seed, 5) orelse continue;
        const search_json = fetchCached(.artist_mbid, seed, search_url, "musicbrainz", pure.MB_RATE_PER_SEC, &w.body) orelse {
            any_fetch_failed = true;
            continue;
        };
        var mbid_buf: [36]u8 = undefined;
        const mn = pure.parseTopArtistMbid(search_json, seed, &mbid_buf);
        if (mn != 36) continue;
        var seed_mbid: [36]u8 = undefined;
        @memcpy(&seed_mbid, mbid_buf[0..36]);

        // 2. MBID → ListenBrainz similar artists
        const sim_url = pure.buildSimilarArtistsUrl(&url_buf, &seed_mbid) orelse continue;
        const sim_json = fetchCached(.similar, &seed_mbid, sim_url, "listenbrainz", pure.LB_RATE_PER_SEC, &w.body) orelse {
            any_fetch_failed = true;
            continue;
        };
        const parsed = pure.parseSimilarArtists(sim_json, &w.similar);
        const ranked = pure.rankSimilar(w.similar[0..parsed], seed);
        const take = @min(ranked, SIMILAR_PER_SEED);

        // 3. each similar artist → its STUDIO albums
        for (0..take) |ai| {
            if (run_gen.load(.acquire) != my_gen or !enabled()) return;
            if (total >= w.albums.len) break :seeds;
            const sim = w.similar[ai];

            var reason_buf: [96]u8 = undefined;
            const reason = std.fmt.bufPrint(&reason_buf, "Because you played {s}", .{seed}) catch "Similar artist";

            const rg_url = pure.buildReleaseGroupUrl(&url_buf, sim.mbidSlice(), 100) orelse continue;
            const rg_json = fetchCached(.albums, sim.mbidSlice(), rg_url, "musicbrainz", pure.MB_RATE_PER_SEC, &w.body) orelse {
                any_fetch_failed = true;
                continue;
            };
            const got = pure.parseStudioAlbums(rg_json, sim.nameSlice(), reason, sim.score, &w.per_artist);
            const keep = @min(got, pure.ALBUMS_PER_ARTIST);
            for (0..keep) |k| {
                if (total >= w.albums.len) break :seeds;
                w.albums[total] = w.per_artist[k];
                total += 1;
            }
        }
    }

    if (run_gen.load(.acquire) != my_gen) return;

    pure.sortAlbums(w.albums[0..total]);
    const final = pure.dedupeAlbums(w.albums[0..total]);

    pub_mutex.lock();
    @memcpy(pub_albums[0..final], w.albums[0..final]);
    pub_count = final;
    pub_mutex.unlock();
    _ = pub_gen.fetchAdd(1, .acq_rel);

    fetch_error.store(any_fetch_failed and final == 0, .release);
    var lb: [96]u8 = undefined;
    logs.pushLog("info", "discovery", std.fmt.bufPrint(&lb, "{d} album(s) from {d} seed artist(s)", .{ final, w_seed_count }) catch "discovery done", false);
}

// ══════════════════════════════════════════════════════════
// UI (a rail at the top of Browse › Music)
// ══════════════════════════════════════════════════════════

const CARD_W: f32 = 210;
const CARD_H: f32 = 118;

// UI-thread-only snapshot, refreshed when the worker publishes a new generation
// so the rail never renders while holding the publish mutex.
var ui_albums: [pure.MAX_ALBUMS]pure.Album = std.mem.zeroes([pure.MAX_ALBUMS]pure.Album);
var ui_count: usize = 0;
var ui_gen: u32 = 0;

fn syncSnapshot() void {
    const g = pub_gen.load(.acquire);
    if (g == ui_gen) return;
    pub_mutex.lock();
    const n = @min(pub_count, ui_albums.len);
    @memcpy(ui_albums[0..n], pub_albums[0..n]);
    pub_mutex.unlock();
    ui_count = n;
    ui_gen = g;
}

/// Discovery rail. Renders NOTHING at all when the user has not opted in — the
/// Music tab looks exactly as it did before.
pub fn renderRail() void {
    if (!enabled()) return;
    autoRefreshOnce();
    syncSnapshot();

    const working = busy.load(.acquire);

    // ── Header: title + status + refresh ──
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.xs },
        });
        defer hdr.deinit();

        dvui.icon(@src(), "disco", icons.tvg.lucide.compass, .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = theme.iconSize(.sm),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "Discover", .{}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
        });
        _ = dvui.label(@src(), "{s}", .{if (working) "Looking for artists like yours..." else "New albums from artists like the ones you play"}, .{
            .color_text = theme.colors.text_tertiary,
            .gravity_y = 0.5,
            .expand = .horizontal,
            .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
        });
        if (dvui.buttonIcon(@src(), "disco-refresh", icons.tvg.lucide.@"refresh-cw", .{}, .{}, .{
            .color_text = theme.colors.text_secondary,
            .color_fill = theme.transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .border = dvui.Rect.all(0),
            .min_size_content = theme.iconSize(.sm),
            .padding = dvui.Rect.all(4),
            .gravity_y = 0.5,
        })) {
            refresh();
        }
    }

    if (ui_count == 0) {
        const msg: []const u8 = if (working)
            "Building recommendations from ListenBrainz and MusicBrainz..."
        else if (fetch_error.load(.acquire))
            "Couldn't reach ListenBrainz or MusicBrainz - try Refresh later"
        else
            "Play something from your library first, then hit Refresh";
        _ = dvui.label(@src(), "{s}", .{msg}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none }, .{
        .expand = .horizontal,
        .background = false,
        .color_fill = theme.colors.bg_app,
        .min_size_content = .{ .w = 10, .h = CARD_H + 24 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = CARD_H + 24 },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer scroll.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    defer row.deinit();

    for (0..ui_count) |i| renderCard(i);
}

fn renderCard(i: usize) void {
    const a = &ui_albums[i];

    var tb: [160]u8 = undefined;
    const title = safeUtf8Buf(a.titleSlice(), &tb);
    var ab: [128]u8 = undefined;
    const artist = safeUtf8Buf(a.artistSlice(), &ab);
    var rb: [96]u8 = undefined;
    const reason = safeUtf8Buf(a.reasonSlice(), &rb);

    var hovered: bool = false;

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i,
        .min_size_content = .{ .w = CARD_W, .h = CARD_H },
        .max_size_content = .{ .w = CARD_W, .h = CARD_H },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_fill_hover = theme.colors.bg_hover,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        .margin = dvui.Rect.all(theme.spacing.xs),
    });
    defer card.deinit();

    // Clicking searches the ACTIVE music source for "<artist> <album>" — the
    // recommendation lands the user back in the player they already use.
    if (title.len > 0 and dvui.clicked(card.data(), .{ .hovered = &hovered })) {
        var q_buf: [256]u8 = undefined;
        const q = std.fmt.bufPrint(&q_buf, "{s} {s}", .{ artist, title }) catch title;
        const n = @min(q.len, state.app.music.search_buf.len - 1);
        @memset(&state.app.music.search_buf, 0);
        @memcpy(state.app.music.search_buf[0..n], q[0..n]);
        @import("music_subsonic.zig").searchMusic(q[0..n]);
    }
    card.drawBackground();

    _ = dvui.label(@src(), "{s}", .{title}, .{
        .id_extra = i,
        .expand = .horizontal,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
    });

    {
        var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
        defer meta.deinit();
        _ = dvui.label(@src(), "{s}", .{artist}, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
        });
        if (a.year_len > 0) {
            _ = dvui.label(@src(), "{s}", .{a.yearSlice()}, .{
                .id_extra = i,
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
        }
    }

    {
        var sp = dvui.box(@src(), .{}, .{ .id_extra = i, .expand = .vertical });
        sp.deinit();
    }

    if (reason.len > 0) {
        _ = dvui.label(@src(), "{s}", .{reason}, .{
            .id_extra = i,
            .expand = .horizontal,
            .gravity_y = 1.0,
            .color_text = theme.colors.text_tertiary,
        });
    }
}
