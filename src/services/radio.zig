//! Internet Radio tab — keyless station discovery via the RadioBrowser API,
//! streamed straight through mpv. Structurally a sibling of podcasts.zig, one
//! level shallower: search → station list → play. All parsing lives in
//! radio_pure.zig (tested); this module owns the async fetch worker,
//! thread-safety, and dvui rendering.
//!
//! Flow:
//!   loadPopularOnce() → curl …/json/stations/topvote/N (the same host's keyless
//!                     most-voted endpoint, answering with the same station
//!                     objects) → pure.parseStations → results[]. Fires once per
//!                     session so the page opens populated.
//!   searchRadio(q)  → curl all.api.radio-browser.info/json/stations/search?name=…
//!                     → pure.parseStations → state.app.radio.results[]
//!   playStation(i)  → browser.loadContentDirect(url_resolved | url) → mpv,
//!                     then a best-effort click-count ping to /json/url/{uuid}.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const pure = @import("radio_pure.zig");
const io = @import("../core/io_global.zig");
const poster = @import("../core/poster.zig");
const rate_limit = @import("../core/rate_limit.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

const alloc = @import("../core/alloc.zig").allocator;

const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

// ── Station artwork ──
// Station favicons reuse the shared poster daemon (poster.zig: async fetch, the
// global in-flight cap, disk cache, texture upload) — the exact path podcast
// covers take. The Station record lives in radio_pure.zig, which must stay free
// of dvui/atomics (std.mem.zeroes), so the GPU texture + pixel state lives HERE
// in a module-static array parallel to state.app.radio.results[] by index. The
// array is never reallocated, so the raw &slot.* pointers handed to
// poster.fetchAsync stay valid for the detached worker. All slot access is
// UI-thread only except that worker, which writes ONLY its own slot's
// pixels/w/h/fetching. A slot's url_hash pins it to the station currently at
// that index: when a re-search puts a different station there, the hash mismatch
// frees the old texture/pixels and refetches, so a logo can never bleed across
// searches. pixels are c_alloc'd inside poster.zig (NOT the tracked global
// allocator) — never free them with `alloc`; deinitPoster/uploadIfReady use the
// matching allocator.
const StationPoster = struct {
    pixels: ?[]u8 = null,
    tex: ?dvui.Texture = null,
    w: u32 = 0,
    h: u32 = 0,
    fetching: bool = false,
    url_hash: u64 = 0,
};
var station_posters: [30]StationPoster = [_]StationPoster{.{}} ** 30;

// ── Thread-safety ──
// The detached search worker publishes into state.app.radio.* under
// `parse_mutex`, and a monotonic `search_gen` drops stale results so fast
// re-searches never show out-of-order data (mirrors podcasts.zig / anime.zig).
// The `is_loading` flag is atomic (read by UI + remote threads, written by the
// worker).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Query snapshot handed to the detached search worker (never read the mutable
// UI search_buf from the thread).
var query_buf: [256]u8 = undefined;
var query_len: usize = 0;

// ══════════════════════════════════════════════════════════
// Encrypted on-disk content cache — most-voted stations SWR (mirrors
// podcasts.zig / tmdb_api.zig). Serialize the fresh popular list through the
// tested content_cache_pure Writer/Reader and persist it, so the next cold start
// paints the grid INSTANTLY instead of a blank box + spinner. results[] is a
// FIXED [30]Station array with cover state in the parallel fixed station_posters[]
// (never reallocated) — no *Item pointers to dangle, so seeding just fills rows
// under parse_mutex. Gated on content_cache_enabled; TTL is the shared SWR window.
// ══════════════════════════════════════════════════════════
const content_cache = @import("../core/content_cache.zig");
const ccp = @import("../core/content_cache_pure.zig");
const RADIO_CACHE_TTL_S: i64 = @import("browse_cache.zig").TTL_S;
const RADIO_CACHE_KEY = "radio:popular";
const RADIO_BLOB_CAP: usize = 64 * 1024;

fn serializeStation(w: *ccp.Writer, s: pure.Station) void {
    w.blob(s.stationuuid[0..@min(s.stationuuid_len, s.stationuuid.len)]);
    w.blob(s.name[0..@min(s.name_len, s.name.len)]);
    w.blob(s.url_resolved[0..@min(s.url_resolved_len, s.url_resolved.len)]);
    w.blob(s.url[0..@min(s.url_len, s.url.len)]);
    w.blob(s.favicon[0..@min(s.favicon_len, s.favicon.len)]);
    w.blob(s.tags[0..@min(s.tags_len, s.tags.len)]);
    w.blob(s.country[0..@min(s.country_len, s.country.len)]);
    w.blob(s.codec[0..@min(s.codec_len, s.codec.len)]);
    w.u32v(s.votes);
    w.u32v(s.bitrate);
}

fn copyField(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

/// Reads one station from `r`; null when the blob is truncated.
fn deserializeStation(r: *ccp.Reader) ?pure.Station {
    var s = pure.Station{};
    copyField(&s.stationuuid, &s.stationuuid_len, r.blob() orelse return null);
    copyField(&s.name, &s.name_len, r.blob() orelse return null);
    copyField(&s.url_resolved, &s.url_resolved_len, r.blob() orelse return null);
    copyField(&s.url, &s.url_len, r.blob() orelse return null);
    copyField(&s.favicon, &s.favicon_len, r.blob() orelse return null);
    copyField(&s.tags, &s.tags_len, r.blob() orelse return null);
    copyField(&s.country, &s.country_len, r.blob() orelse return null);
    copyField(&s.codec, &s.codec_len, r.blob() orelse return null);
    s.votes = r.u32v() orelse return null;
    s.bitrate = r.u32v() orelse return null;
    return s;
}

/// SWR write — persist the fresh most-voted list. Called from popularWorker
/// while it already holds parse_mutex, so results[]/result_count are stable.
fn putPopularCache() void {
    if (!state.app.content_cache_enabled) return;
    const count = state.app.radio.result_count;
    if (count == 0) return;
    const buf = alloc.alloc(u8, RADIO_BLOB_CAP) catch return;
    defer alloc.free(buf);
    var w = ccp.Writer.init(buf);
    const n: u16 = @intCast(@min(count, state.app.radio.results.len));
    w.u16v(n);
    var i: usize = 0;
    while (i < n) : (i += 1) serializeStation(&w, state.app.radio.results[i]);
    const blob = w.done() orelse return;
    content_cache.put(RADIO_CACHE_KEY, blob, RADIO_CACHE_TTL_S);
}

/// SWR read — seed the popular grid from disk so it paints instantly on cold
/// start. UI-thread only (from loadPopularOnce), ONLY when results[] is empty.
/// results[] is a fixed array, so no capacity reservation is needed.
fn seedPopularFromCache() void {
    if (!state.app.content_cache_enabled) return;
    if (state.app.radio.result_count != 0) return;
    const buf = alloc.alloc(u8, RADIO_BLOB_CAP) catch return;
    defer alloc.free(buf);
    const hit = content_cache.get(RADIO_CACHE_KEY, buf) orelse return;
    var r = ccp.Reader.init(hit.bytes);
    const n = r.u16v() orelse return;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (state.app.radio.result_count != 0) return; // a fetch beat us under the lock
    var i: usize = 0;
    while (i < n and i < state.app.radio.results.len) : (i += 1) {
        state.app.radio.results[i] = deserializeStation(&r) orelse break;
    }
    state.app.radio.result_count = i;
    if (i > 0) state.app.radio.showing_popular = true;
}

// ══════════════════════════════════════════════════════════
// Popular — RadioBrowser most-voted stations
//
// So the page opens with content instead of an empty search box. /topvote/N is
// the same keyless host as the search endpoint and answers with the identical
// station objects, so it goes through the SAME curl helper and the SAME
// pure.parseStations — a popular card is byte-for-byte a search card and its
// click handler is the existing playStation(). One fetch per session.
// ══════════════════════════════════════════════════════════

const POPULAR_LIMIT: usize = 30; // == results[] capacity

/// One-shot latch. renderContent() calls this every frame, so every call after
/// the first is a single atomic load. Atomic (not a plain bool) because
/// searchRadio — which also arms it, so the chart can't land on top of a user's
/// results — is reachable from the remote-API thread.
var popular_fetched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn loadPopularOnce() void {
    if (popular_fetched.load(.acquire)) return;
    // Same first-start gate as the other one-shot loaders: don't latch until
    // config has published (the poster daemon's disk cache needs the db open).
    if (!state.app.config_loaded.load(.acquire)) return;
    // A search already landed (remote API) — leave it be.
    if (state.app.radio.result_count > 0) {
        popular_fetched.store(true, .release);
        return;
    }
    if (state.app.radio.is_loading.load(.acquire)) return;

    // SWR seed: paint the last most-voted list from disk NOW (empty grid only)
    // so the tab isn't blank while the revalidating fetch below runs.
    seedPopularFromCache();

    popular_fetched.store(true, .release);
    state.app.radio.showing_popular = true;
    state.app.radio.fetch_error = false;
    state.app.radio.is_loading.store(true, .release);

    // Take a generation like a search does, so a user search fired while the
    // popular fetch is in flight supersedes it instead of racing it into
    // results[].
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    if (std.Thread.spawn(.{}, popularWorker, .{my_gen})) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.radio.is_loading.store(false, .release);
    }
}

fn popularWorker(my_gen: u32) void {
    defer state.app.radio.is_loading.store(false, .release);

    var url_buf: [128]u8 = undefined;
    const url = pure.buildTopVoteUrl(POPULAR_LIMIT, &url_buf);
    if (url.len == 0) return;

    // Shared public directory — be a polite citizen (≤ 1 req/sec), same bucket
    // as the search worker.
    rate_limit.acquire("radiobrowser", 1.0);

    const body = curl(url, 512 * 1024) orelse {
        state.app.radio.fetch_error = true;
        return;
    };
    defer alloc.free(body);

    if (search_gen.load(.acquire) != my_gen) return; // superseded by a search

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return; // re-check under lock

    const count = pure.parseStations(body, &state.app.radio.results);
    state.app.radio.result_count = count;
    if (count == 0) {
        state.app.radio.fetch_error = true;
        logs.pushLog("info", "radio", "Top stations returned no rows", false);
    } else {
        // SWR write: persist the fresh list (still under parse_mutex) so the
        // next cold start seeds instantly.
        putPopularCache();
        logs.pushLog("info", "radio", "Popular stations loaded (RadioBrowser topvote)", false);
    }
}

// ══════════════════════════════════════════════════════════
// Search — RadioBrowser station search
// ══════════════════════════════════════════════════════════

pub fn searchRadio(query: []const u8) void {
    if (query.len == 0) return;

    state.app.radio.is_loading.store(true, .release);
    state.app.radio.fetch_error = false;
    state.app.radio.showing_popular = false;
    // A search satisfies the "page opens with content" job — never let the
    // one-shot popular fetch land on top of the user's results afterwards.
    popular_fetched.store(true, .release);

    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    // Snapshot the query BEFORE spawning — a newer search overwrites query_buf.
    const n = @min(query.len, query_buf.len);
    @memcpy(query_buf[0..n], query[0..n]);
    query_len = n;

    if (std.Thread.spawn(.{}, searchWorker, .{my_gen})) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.radio.is_loading.store(false, .release);
    }
}

fn searchWorker(my_gen: u32) void {
    defer state.app.radio.is_loading.store(false, .release);

    // Re-snapshot the query — a newer search may overwrite query_buf mid-flight.
    var local: [256]u8 = undefined;
    const qlen = @min(query_len, local.len);
    @memcpy(local[0..qlen], query_buf[0..qlen]);

    // Percent-encode the term (space, &, =, #, ?, %, + at minimum).
    var enc: [768]u8 = undefined;
    const encoded = percentEncode(local[0..qlen], &enc);

    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://all.api.radio-browser.info/json/stations/search?name={s}&limit=30&hidebroken=true&order=votes&reverse=true",
        .{encoded},
    ) catch return;

    // Shared public directory — be a polite citizen (≤ 1 req/sec).
    rate_limit.acquire("radiobrowser", 1.0);

    const body = curl(url, 512 * 1024) orelse {
        state.app.radio.fetch_error = true;
        return;
    };
    defer alloc.free(body);

    // Bail if superseded while curl was in flight.
    if (search_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return; // re-check under lock

    const count = pure.parseStations(body, &state.app.radio.results);
    state.app.radio.result_count = count;
    if (count == 0) logs.pushLog("info", "radio", "Search returned no stations", false) else logs.pushLog("info", "radio", "Radio search done (RadioBrowser)", false);
}

// ══════════════════════════════════════════════════════════
// Play — stream url_resolved (fallback url) through mpv
// ══════════════════════════════════════════════════════════

/// Load station `idx`'s stream straight into mpv. `url_resolved` is the
/// CDN-resolved audio stream mpv plays natively, so loadContentDirect (no
/// content-type routing) is used — creating a player if none exists and
/// revealing the player page. Falls back to `url` when unresolved.
pub fn playStation(idx: usize) void {
    if (idx >= state.app.radio.result_count) return;
    const s = &state.app.radio.results[idx];
    const src = if (s.url_resolved_len > 0)
        s.url_resolved[0..s.url_resolved_len]
    else
        s.url[0..s.url_len];
    if (src.len == 0) return;

    var url_buf: [512]u8 = undefined;
    const ulen = @min(src.len, url_buf.len);
    @memcpy(url_buf[0..ulen], src[0..ulen]);

    // Snapshot the now-playing fields into locals BEFORE playing — a concurrent
    // re-search can overwrite results[] mid-frame, so nothing handed to
    // loadContentDirectMeta may alias the live row.
    var name_buf: [160]u8 = undefined;
    const nlen = @min(s.name_len, name_buf.len);
    @memcpy(name_buf[0..nlen], s.name[0..nlen]);

    var fav_buf: [300]u8 = undefined;
    const flen = @min(s.favicon_len, fav_buf.len);
    @memcpy(fav_buf[0..flen], s.favicon[0..flen]);

    // Subtitle: "CODEC · N kbps · COUNTRY · tags" — each part appended only when
    // present, joined by " · " (e.g. "MP3 · 128 kbps · United States").
    var sub_buf: [192]u8 = undefined;
    var sw = std.Io.Writer.fixed(&sub_buf);
    var wrote = false;
    if (s.codec_len > 0) {
        // Codec displays upper-cased (the API returns "mp3"/"aac" mixed-case).
        for (s.codec[0..s.codec_len]) |ch| sw.writeByte(std.ascii.toUpper(ch)) catch {};
        wrote = true;
    }
    if (s.bitrate > 0) {
        if (wrote) sw.writeAll(" · ") catch {};
        sw.print("{d} kbps", .{s.bitrate}) catch {};
        wrote = true;
    }
    if (s.country_len > 0) {
        if (wrote) sw.writeAll(" · ") catch {};
        sw.writeAll(s.country[0..s.country_len]) catch {};
        wrote = true;
    }
    if (s.tags_len > 0) {
        if (wrote) sw.writeAll(" · ") catch {};
        sw.writeAll(s.tags[0..@min(s.tags_len, 60)]) catch {};
        wrote = true;
    }
    const sub = sub_buf[0..sw.end];

    @import("browser.zig").loadContentDirectMeta(url_buf[0..ulen], fav_buf[0..flen], name_buf[0..nlen], sub);
    logs.pushLog("info", "radio", "Streaming internet radio station", false);

    // RadioBrowser click-counting politeness — best-effort, ignore the result.
    pingClick(s.stationuuid[0..s.stationuuid_len]);
}

/// Fire-and-forget the RadioBrowser click endpoint for a station uuid so the
/// directory's popularity stats stay honest. Detached + best-effort: the uuid
/// is copied into an owned heap buffer the worker frees, so no shared/mutable
/// state is handed across the thread boundary.
fn pingClick(uuid: []const u8) void {
    if (uuid.len == 0) return;
    const owned = alloc.dupe(u8, uuid) catch return;
    if (std.Thread.spawn(.{}, clickWorker, .{owned})) |t| {
        t.detach();
    } else |_| {
        alloc.free(owned);
    }
}

fn clickWorker(uuid_owned: []u8) void {
    defer alloc.free(uuid_owned);
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://all.api.radio-browser.info/json/url/{s}",
        .{uuid_owned},
    ) catch return;
    if (curl(url, 16 * 1024)) |body| alloc.free(body); // ignore contents
}

// ══════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════

/// Percent-encode `src` into `dst` (space, &, =, #, ?, %, + at minimum, plus
/// any non-alphanumeric that isn't URL-safe). Returns the encoded slice.
fn percentEncode(src: []const u8, dst: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var out: usize = 0;
    for (src) |ch| {
        const safe = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (safe) {
            if (out + 1 > dst.len) break;
            dst[out] = ch;
            out += 1;
        } else {
            if (out + 3 > dst.len) break;
            dst[out] = '%';
            dst[out + 1] = hex[ch >> 4];
            dst[out + 2] = hex[ch & 0xF];
            out += 3;
        }
    }
    return dst[0..out];
}

/// Fetch `url` with curl into a fresh heap buffer of `cap` bytes. Returns the
/// filled slice (caller frees) or null on failure/empty. Large buffers stay off
/// the worker stack (macOS 512KB limit).
fn curl(url: []const u8, cap: usize) ?[]u8 {
    const argv = [_][]const u8{ "curl", "-sL", "-A", agent, "--max-time", "15", url };
    var child = io.Child.init(&argv, alloc);
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

    // Shrink to what was actually read. The caller frees what we hand back, and
    // the global DebugAllocator checks the free size against the allocation size
    // — returning `buf[0..n]` out of a `cap`-sized allocation is an INVALID FREE
    // and aborts the process (the podcasts twin of this helper did exactly that).
    return alloc.realloc(buf, n) catch {
        alloc.free(buf);
        return null;
    };
}

// ══════════════════════════════════════════════════════════
// UI (Drawer / Browse › Radio)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    // Populate the page on first open (no-op after the first fetch).
    loadPopularOnce();

    renderSearchBar();

    if (state.app.radio.fetch_error) {
        _ = dvui.label(@src(), "Failed to fetch — check your connection", .{}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    renderResults();
}

fn renderSearchBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer row.deinit();

    _ = dvui.icon(@src(), "", icons.tvg.lucide.radio, .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.radio.search_buf },
        .placeholder = "Search radio stations…",
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
        const q = std.mem.sliceTo(&state.app.radio.search_buf, 0);
        if (q.len > 0) searchRadio(q);
    }

    if (state.app.radio.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
    }
}

// ── Card grid ──
// Popular stations and search results are the SAME record (parseStations fills
// both), so they render through one grid: station logo + name + "codec · kbps ·
// country", click → playStation(i), exactly what the old row's Play button did.
const CARD_GAP: f32 = 6;
const CARD_TARGET_W: f32 = 170; // desired card width; columns derive from it
const CARD_FOOTER_H: f32 = 46; // name + meta lines under the logo

/// Fill the card's logo area with the station's favicon, reusing the shared
/// poster daemon. Falls back to the radio glyph while loading, when the station
/// has no favicon, or when the image can't be decoded (many stations advertise
/// webp/svg logos, which stb_image can't read — the glyph is the norm, not an
/// error). UI-thread only.
fn renderLogo(i: usize, s: *const pure.Station) void {
    const slot = &station_posters[i];
    const fav = s.favicon[0..s.favicon_len];

    if (fav.len > 0) {
        // Pin the slot to whatever station is at index i now — a re-search (or
        // the popular list landing) can replace results[], so a URL-hash change
        // means "different station here": free the stale texture/pixels and
        // refetch. Only when not mid-fetch, so we never spawn a second worker
        // onto the same slot.
        const h = std.hash.Fnv1a_64.hash(fav);
        if (slot.url_hash != h and !slot.fetching) {
            poster.deinitPoster(&slot.pixels, &slot.tex);
            slot.w = 0;
            slot.h = 0;
            slot.url_hash = h;
        }
        _ = poster.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.tex);
        if (slot.tex == null and !slot.fetching and slot.pixels == null)
            poster.fetchAsync(fav, &slot.pixels, &slot.w, &slot.h, &slot.fetching);
    }

    if (slot.tex) |*tex| {
        _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
            .id_extra = i + 1000,
            .expand = .both,
            .corner_radius = dvui.Rect.all(8),
        });
    } else {
        _ = dvui.icon(@src(), "", icons.tvg.lucide.radio, .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });
    }
}

/// One station card: logo (clickable → play) + name + codec/bitrate/country.
fn renderCard(i: usize, card_w: f32) void {
    const s = &state.app.radio.results[i];

    // Validate a STABLE COPY: a fetch worker can rewrite results[i] mid-frame
    // and dvui panics on invalid UTF-8 it reads after we validated.
    var name_buf: [160]u8 = undefined;
    const name = safeUtf8Buf(s.name[0..@min(s.name_len, s.name.len)], &name_buf);

    // min == max height → every card (and thus every row) has a uniform pitch.
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i,
        .min_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .margin = dvui.Rect.all(CARD_GAP),
    });
    defer card.deinit();

    // Logo hosted INSIDE a single button widget — one clickable rectangle per
    // card (a sibling button + box would draw two).
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

        renderLogo(i, s);

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        // Same click target as the old row's Play button.
        if (clicked) playStation(i);
    }

    _ = dvui.label(@src(), "{s}", .{name}, .{
        .id_extra = i + 3000,
        .color_text = theme.colors.text_primary,
        .expand = .horizontal,
        .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
    });

    // Meta: codec · bitrate · country.
    var meta_buf: [120]u8 = undefined;
    var mw = std.Io.Writer.fixed(&meta_buf);
    var wrote = false;
    if (s.codec_len > 0) {
        mw.writeAll(s.codec[0..@min(s.codec_len, s.codec.len)]) catch {};
        wrote = true;
    }
    if (s.bitrate > 0) {
        if (wrote) mw.writeAll(" · ") catch {};
        mw.print("{d} kbps", .{s.bitrate}) catch {};
        wrote = true;
    }
    if (s.country_len > 0) {
        if (wrote) mw.writeAll(" · ") catch {};
        mw.writeAll(s.country[0..@min(s.country_len, s.country.len)]) catch {};
        wrote = true;
    }
    if (wrote) {
        var safe_meta: [120]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(meta_buf[0..mw.end], &safe_meta)}, .{
            .id_extra = i + 4000,
            .color_text = theme.colors.text_tertiary,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
    }
}

fn renderResults() void {
    const count = @min(state.app.radio.result_count, state.app.radio.results.len);
    if (count == 0) {
        if (!state.app.radio.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Search for a station to get started", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        } else {
            _ = dvui.label(@src(), "Loading popular stations…", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        }
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    _ = dvui.label(@src(), "{s}", .{
        if (state.app.radio.showing_popular) "Most popular stations" else "Results",
    }, .{
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 2 },
    });

    // Responsive columns from the LIVE page width (one-frame lag; first paint
    // falls back to a sane default) — same shape as the TMDB gallery. No
    // virtualization: the grid is capped at results[]'s 30 cards.
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / CARD_TARGET_W)));
    const cols_f: f32 = @floatFromInt(cols);
    const card_w: f32 = @max(100, (avail_w - cols_f * 2 * CARD_GAP) / cols_f);

    var r: usize = 0;
    while (r * cols < count) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = r + 50000,
            .expand = .horizontal,
        });
        defer row.deinit();

        var c: usize = 0;
        while (c < cols and r * cols + c < count) : (c += 1) renderCard(r * cols + c, card_w);
    }
}
