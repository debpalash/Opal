//! Live TV (IPTV) tab — the VIDEO twin of radio.zig. Keyless channel discovery
//! via the iptv-org public directory (streams.json), streamed straight through
//! mpv (HLS/m3u8/.ts play natively). All parsing + the accept/NSFW decisions
//! live in iptv_pure.zig (tested); this module owns the async fetch worker,
//! thread-safety, the SWR disk cache, and dvui rendering.
//!
//! Opt-in: the endpoint is source_config-gated (plugin id "iptv-org"). No plugin
//! installed → iptvBase() is null → the tab is INERT (empty, no fetch). Once the
//! bundled iptv-org plugin is installed it supplies the base URL (default
//! https://iptv-org.github.io/api) and the tab lights up.
//!
//! streams.json is a single ~4 MB static array (NOT server-paginated), so we
//! stream-parse it ONCE into a bounded fixed buffer (state.app.iptv.results,
//! capped at 300 channels) and free the body immediately — never holding the
//! whole feed as parsed objects. Infinite scroll is therefore PROGRESSIVE
//! REVEAL: all accepted channels are parsed up front (≤ cap), then loadMore()
//! reveals the next window as you scroll — no extra fetch, no retained body.
//!
//! Flow:
//!   loadPopularOnce() → curl <base>/streams.json → pure.parseStreams (query="")
//!                       → results[]. Fires once per session so the page opens
//!                       populated (SWR-seeded from disk first for instant paint).
//!   searchIptv(q)     → same fetch, pure.parseStreams(query=q) title-filter.
//!   playChannel(i)    → browser.loadContentDirectMeta(url) → mpv.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const logs = @import("../core/logs.zig");
const pure = @import("iptv_pure.zig");
const playlist = @import("iptv_playlist_pure.zig");
const iptv_store = @import("iptv_store.zig");
const io = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const poster = @import("../core/poster.zig");
const rate_limit = @import("../core/rate_limit.zig");
const source_config = @import("../core/source_config.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

const alloc = @import("../core/alloc.zig").allocator;

const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

// ══════════════════════════════════════════════════════════
// Opt-in gate (source_config, plugin id "iptv-org")
// ══════════════════════════════════════════════════════════
// Mirrors animepahe/allanime: get("<id>","base") orelse return → INERT until a
// plugin is installed. When installed but the base is blank, fall back to the
// public iptv-org default so the tab still works (like lists.zig's default).
const IPTV_DEFAULT_BASE = "https://iptv-org.github.io/api";

fn iptvBase() ?[]const u8 {
    const b = source_config.get("iptv-org", "base") orelse return null; // not installed → inert
    if (b.len > 0) return b;
    return IPTV_DEFAULT_BASE; // installed but blank → public default
}

/// The user's own M3U playlist URL, when set (source_config "iptv-org"/"m3u").
/// When present, fetchWorker uses it INSTEAD of the public directory.
fn m3uUrl() ?[]const u8 {
    const u = source_config.get("iptv-org", "m3u") orelse return null;
    if (u.len == 0 or !(std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://"))) return null;
    return u;
}

/// Settings: load the saved M3U URL into the input buffer once.
pub fn prefillM3u() void {
    if (state.app.iptv.m3u_loaded) return;
    state.app.iptv.m3u_loaded = true;
    @memset(&state.app.iptv.m3u_cfg, 0);
    if (source_config.get("iptv-org", "m3u")) |u| {
        const n = @min(u.len, state.app.iptv.m3u_cfg.len - 1);
        @memcpy(state.app.iptv.m3u_cfg[0..n], u[0..n]);
    }
}

/// Settings: persist the M3U URL (merged into the iptv-org source config so the
/// tab stays enabled) and force a refresh on next open.
pub fn saveM3u() void {
    const m3u = std.mem.sliceTo(&state.app.iptv.m3u_cfg, 0);
    var body: [700]u8 = undefined;
    var bw = std.Io.Writer.fixed(&body);
    // Keep the existing base; add/replace m3u.
    const base = source_config.get("iptv-org", "base") orelse IPTV_DEFAULT_BASE;
    bw.writeAll("{\"base\":\"") catch return;
    for (base) |c| switch (c) {
        '"', '\\' => bw.writeAll(&.{ '\\', c }) catch {},
        else => bw.writeByte(c) catch {},
    };
    bw.writeAll("\",\"m3u\":\"") catch return;
    for (m3u) |c| switch (c) {
        '"', '\\' => bw.writeAll(&.{ '\\', c }) catch {},
        else => bw.writeByte(c) catch {},
    };
    bw.writeAll("\"}") catch return;
    _ = source_config.install("iptv-org", body[0..bw.end]);
    // Re-open fresh.
    popular_fetched.store(false, .release);
    state.app.iptv.result_count = 0;
    logs.pushLog("info", "iptv", "Live TV playlist saved", false);
}

// ══════════════════════════════════════════════════════════
// Thread-safety
// ══════════════════════════════════════════════════════════
// The detached fetch worker publishes into state.app.iptv.* under `parse_mutex`,
// and a monotonic `search_gen` drops stale results so fast re-searches never
// show out-of-order data (mirrors radio.zig). `is_loading` is atomic (read by
// the UI + remote threads, written by the worker).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Query snapshot handed to the detached worker (never read the mutable UI
// search_buf from the thread).
var query_buf: [256]u8 = undefined;
var query_len: usize = 0;

// Filter snapshot handed to the worker alongside the query. Set on the UI/remote
// thread by armFetch() before spawn (like query_buf), read on the worker.
var flt_category: [32]u8 = undefined;
var flt_category_len: usize = 0;
var flt_country: [8]u8 = undefined;
var flt_country_len: usize = 0;
var flt_quality: u8 = 0;
var flt_sort: u8 = 0;

/// Snapshot the query + current filter-bar state onto the worker statics and
/// bump the generation (so an in-flight fetch is superseded). Returns the new
/// generation. UI/remote thread only.
fn armFetch(query: []const u8) u32 {
    const qn = @min(query.len, query_buf.len);
    @memcpy(query_buf[0..qn], query[0..qn]);
    query_len = qn;

    const cn = @min(state.app.iptv.filter_category_len, flt_category.len);
    @memcpy(flt_category[0..cn], state.app.iptv.filter_category[0..cn]);
    flt_category_len = cn;
    const kn = @min(state.app.iptv.filter_country_len, flt_country.len);
    @memcpy(flt_country[0..kn], state.app.iptv.filter_country[0..kn]);
    flt_country_len = kn;
    flt_quality = state.app.iptv.filter_quality;
    flt_sort = state.app.iptv.sort_mode;

    return search_gen.fetchAdd(1, .acq_rel) + 1;
}

/// True when no filter/search narrows the view — drives the grid heading and
/// gates the popular disk cache (only the default view is cached).
fn viewIsDefault() bool {
    return state.app.iptv.filter_category_len == 0 and
        state.app.iptv.filter_country_len == 0 and
        state.app.iptv.filter_quality == 0 and
        std.mem.sliceTo(&state.app.iptv.search_buf, 0).len == 0;
}

// ══════════════════════════════════════════════════════════
// Favorites + Recents (quick-filter views, iptv_store-backed)
// ══════════════════════════════════════════════════════════

// Session-lived in-memory indexes (favorites/health/probe-attempted). Allocated
// from the c_allocator — NOT the tracked global — so these never-freed module
// caches don't trip the DebugAllocator's shutdown leak gate (mirrors poster.zig).
const map_alloc = std.heap.c_allocator;

// In-memory set of favorited url-hashes so a card's star is an O(1) lookup, not
// a DB query per card per frame. Refreshed lazily + on every toggle.
var fav_set: std.AutoHashMapUnmanaged(i64, void) = .{};
var fav_dirty: bool = true;

fn ensureFavSet() void {
    if (!fav_dirty) return;
    iptv_store.loadFavHashes(map_alloc, &fav_set);
    fav_dirty = false;
}

fn isFav(url: []const u8) bool {
    return fav_set.contains(iptv_store.urlHash(url));
}

/// Load the Favorites/Recent view straight from the DB into results[] (no
/// network). Bumps the generation so an in-flight network fetch can't overwrite
/// this view when it lands.
fn loadQuickView() void {
    const kind: iptv_store.Kind = if (state.app.iptv.quick_filter == 1) .fav else .recent;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    _ = search_gen.fetchAdd(1, .acq_rel);
    state.app.iptv.result_count = iptv_store.loadInto(kind, &state.app.iptv.results);
    state.app.iptv.showing_popular = false;
    state.app.iptv.fetch_error = false;
    state.app.iptv.is_loading.store(false, .release);
    visible = PAGE_SIZE;
}

/// Switch quick-filter view (All / Favorites / Recent) and repopulate.
fn selectQuickFilter(qf: u8) void {
    state.app.iptv.quick_filter = qf;
    if (qf == 0) {
        // Back to the network view — re-run with the current filters/search.
        applyFilters();
    } else {
        loadQuickView();
    }
}

// ══════════════════════════════════════════════════════════
// Stream health probing (live / dead / slow status dots)
// ══════════════════════════════════════════════════════════
// The probe pool, the cache and the classifier are APP-WIDE — they live in
// services/link_health.zig (+ link_health_pure.zig) and are shared with Radio.
// Live TV is just the "iptv" kind: rendering a card kicks a bounded probe, the
// result lands in the link_health table (30-min TTL) and the status dot reads
// from link_health's in-memory map. Semantics are unchanged from when this
// pool was private here.
const link_health = @import("link_health.zig");
const IPTV_KIND = "iptv";

var working_only: bool = false;

fn healthOf(url: []const u8) pure.Health {
    return link_health.statusOf(IPTV_KIND, url);
}

fn maybeProbe(url: []const u8) void {
    link_health.probe(IPTV_KIND, url);
}

fn statusColor(h: pure.Health) dvui.Color {
    return link_health.statusColor(h);
}

// ── Progressive-scroll reveal ──
// streams.json is one static file, so there is no second page to fetch: the
// worker parses ALL accepted channels (≤ the fixed 300 cap) in one pass, and
// infinite scroll simply reveals `visible` more of them per near-bottom scroll.
// UI-thread only (set on load start, bumped by loadMore, clamped in render).
const PAGE_SIZE: usize = 90;
var visible: usize = 0;

/// One-shot latch. renderContent() calls loadPopularOnce every frame; after the
/// first, this is a single atomic load. Atomic (not a plain bool) because
/// searchIptv — reachable from the remote-API thread — also arms it.
var popular_fetched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ══════════════════════════════════════════════════════════
// SWR on-disk content cache — the popular channel window (mirrors radio.zig).
// Serialize the fresh list through content_cache_pure and persist it so the next
// cold start paints instantly instead of a blank box + spinner. results[] is a
// FIXED [300]IptvChannel array (never reallocated). Only the first popular load
// is persisted (search results are not). Gated on content_cache_enabled.
// ══════════════════════════════════════════════════════════
const content_cache = @import("../core/content_cache.zig");
const ccp = @import("../core/content_cache_pure.zig");
const IPTV_CACHE_TTL_S: i64 = @import("browse_cache.zig").TTL_S;
// v3: the serialized record gained logo/country/category, then user_agent/
// referrer — a fresh key makes any older blob a clean cache miss instead of a
// misaligned read.
const IPTV_CACHE_KEY = "iptv:popular:v3";
const IPTV_BLOB_CAP: usize = 512 * 1024;

fn serializeChannel(w: *ccp.Writer, c: pure.IptvChannel) void {
    w.blob(c.name[0..@min(c.name_len, c.name.len)]);
    w.blob(c.url[0..@min(c.url_len, c.url.len)]);
    w.blob(c.quality[0..@min(c.quality_len, c.quality.len)]);
    // Enrichment (logo/country/category) is persisted too so a cold start paints
    // thumbnails + meta from disk instantly, before the network refresh lands.
    w.blob(c.logo[0..@min(c.logo_len, c.logo.len)]);
    w.blob(c.country[0..@min(c.country_len, c.country.len)]);
    w.blob(c.category[0..@min(c.category_len, c.category.len)]);
    // Play hints, so a channel opened from the cache-seeded grid (before the
    // network refresh) still sends the right user_agent / referrer.
    w.blob(c.user_agent[0..@min(c.user_agent_len, c.user_agent.len)]);
    w.blob(c.referrer[0..@min(c.referrer_len, c.referrer.len)]);
}

fn copyField(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

/// Reads one channel from `r`; null when the blob is truncated.
fn deserializeChannel(r: *ccp.Reader) ?pure.IptvChannel {
    var c = pure.IptvChannel{};
    copyField(&c.name, &c.name_len, r.blob() orelse return null);
    copyField(&c.url, &c.url_len, r.blob() orelse return null);
    copyField(&c.quality, &c.quality_len, r.blob() orelse return null);
    copyField(&c.logo, &c.logo_len, r.blob() orelse return null);
    copyField(&c.country, &c.country_len, r.blob() orelse return null);
    copyField(&c.category, &c.category_len, r.blob() orelse return null);
    copyField(&c.user_agent, &c.user_agent_len, r.blob() orelse return null);
    copyField(&c.referrer, &c.referrer_len, r.blob() orelse return null);
    return c;
}

/// SWR write — persist the fresh popular list. Called from the worker while it
/// already holds parse_mutex, so results[]/result_count are stable.
fn putPopularCache() void {
    if (!state.app.content_cache_enabled) return;
    const count = state.app.iptv.result_count;
    if (count == 0) return;
    const buf = alloc.alloc(u8, IPTV_BLOB_CAP) catch return;
    defer alloc.free(buf);
    var w = ccp.Writer.init(buf);
    const n: u16 = @intCast(@min(count, state.app.iptv.results.len));
    w.u16v(n);
    var i: usize = 0;
    while (i < n) : (i += 1) serializeChannel(&w, state.app.iptv.results[i]);
    const blob = w.done() orelse return;
    content_cache.put(IPTV_CACHE_KEY, blob, IPTV_CACHE_TTL_S);
}

/// SWR read — seed the popular grid from disk so it paints instantly on cold
/// start. UI-thread only (from loadPopularOnce), ONLY when results[] is empty.
fn seedPopularFromCache() void {
    if (!state.app.content_cache_enabled) return;
    if (state.app.iptv.result_count != 0) return;
    const buf = alloc.alloc(u8, IPTV_BLOB_CAP) catch return;
    defer alloc.free(buf);
    const hit = content_cache.get(IPTV_CACHE_KEY, buf) orelse return;
    var r = ccp.Reader.init(hit.bytes);
    const n = r.u16v() orelse return;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (state.app.iptv.result_count != 0) return; // a fetch beat us under the lock
    var i: usize = 0;
    while (i < n and i < state.app.iptv.results.len) : (i += 1) {
        state.app.iptv.results[i] = deserializeChannel(&r) orelse break;
    }
    state.app.iptv.result_count = i;
    if (i > 0) state.app.iptv.showing_popular = true;
}

// ══════════════════════════════════════════════════════════
// Popular — the full channel directory (query = "")
// ══════════════════════════════════════════════════════════

pub fn loadPopularOnce() void {
    if (popular_fetched.load(.acquire)) return;
    // Same first-start gate as the other one-shot loaders: wait for config.
    if (!state.app.config_loaded.load(.acquire)) return;
    // Inert until the iptv-org plugin is installed — don't latch, so the tab
    // lights up the moment the user installs it (no restart).
    if (iptvBase() == null) return;
    // A search already landed (remote API) — leave it be.
    if (state.app.iptv.result_count > 0) {
        popular_fetched.store(true, .release);
        return;
    }
    if (state.app.iptv.is_loading.load(.acquire)) return;

    // SWR seed: paint the last popular list from disk NOW (empty grid only).
    seedPopularFromCache();

    popular_fetched.store(true, .release);
    state.app.iptv.showing_popular = true;
    state.app.iptv.fetch_error = false;
    state.app.iptv.is_loading.store(true, .release);
    visible = PAGE_SIZE;

    // Take a generation like a search does, so a user search fired while this
    // is in flight supersedes it instead of racing it into results[]. armFetch
    // snapshots the (default) filters + empty query.
    const my_gen = armFetch("");

    if (std.Thread.spawn(.{}, fetchWorker, .{ my_gen, false })) |t| {
        t.detach();
    } else |_| {
        state.app.iptv.is_loading.store(false, .release);
    }
}

// ══════════════════════════════════════════════════════════
// Filters — re-run with the current filter-bar + search state
// ══════════════════════════════════════════════════════════

/// Re-fetch with the current category/country/quality/sort + search text (called
/// when a filter-bar control changes). Filters and search compose. Inert until
/// the plugin is installed.
pub fn applyFilters() void {
    if (iptvBase() == null) return;

    state.app.iptv.is_loading.store(true, .release);
    state.app.iptv.fetch_error = false;
    state.app.iptv.showing_popular = viewIsDefault();
    // A filter change satisfies "page has content" — don't let the one-shot
    // popular fetch land on top afterwards.
    popular_fetched.store(true, .release);
    visible = PAGE_SIZE;

    const q = std.mem.sliceTo(&state.app.iptv.search_buf, 0);
    const my_gen = armFetch(q);
    // is_search=true → not persisted as the popular cache (only the default view
    // is; see fetchWorker).
    if (std.Thread.spawn(.{}, fetchWorker, .{ my_gen, true })) |t| {
        t.detach();
    } else |_| {
        state.app.iptv.is_loading.store(false, .release);
    }
}

// ══════════════════════════════════════════════════════════
// Search — title filter over the same streams.json
// ══════════════════════════════════════════════════════════

/// Tab-INDEPENDENT channel search, for the universal-search fan-out.
///
/// `searchIptv` below drives the Live TV *tab*: it mutates state.app.iptv,
/// takes a generation and repaints the grid. A universal search must not do any
/// of that — the user is searching from the omnibox, not browsing Live TV, and
/// hijacking the tab's contents behind their back would be a bug. So this
/// parses into a caller-owned buffer and touches no shared state.
///
/// The directory is fetched through the same on-disk cache as logos/channels,
/// so the first universal search pays for the ~4 MB download once and every
/// later one is a local read. Returns 0 (silently, no error state) when the
/// iptv-org plugin isn't installed. Worker-thread only — it does HTTP.
pub fn searchInto(query: []const u8, out: []pure.IptvChannel) usize {
    if (query.len == 0 or out.len == 0) return 0;
    const base = iptvBase() orelse return 0; // inert without the plugin

    var url_buf: [256]u8 = undefined;
    const url = pure.buildStreamsUrl(base, &url_buf);
    if (url.len == 0) return 0;

    rate_limit.acquire("iptv-org", 0.5);
    const body = fetchCached(url, "iptv-streams.json", 16 * 1024 * 1024, ENRICH_TTL_S) orelse return 0;
    defer alloc.free(body);

    // Enrichment is best-effort: without it a card falls back to the glyph and
    // loses its country/category, but the channel still plays. Both are already
    // disk-cached by the tab, so this is usually free.
    var logos_url_buf: [256]u8 = undefined;
    var chans_url_buf: [256]u8 = undefined;
    const logos_url = pure.buildLogosUrl(base, &logos_url_buf);
    const chans_url = pure.buildChannelsUrl(base, &chans_url_buf);
    const logos_body: ?[]u8 = if (logos_url.len > 0) fetchCached(logos_url, "iptv-logos.json", 16 * 1024 * 1024, ENRICH_TTL_S) else null;
    defer if (logos_body) |lb| alloc.free(lb);
    const chans_body: ?[]u8 = if (chans_url.len > 0) fetchCached(chans_url, "iptv-channels.json", 24 * 1024 * 1024, ENRICH_TTL_S) else null;
    defer if (chans_body) |cb| alloc.free(cb);

    // Same unconditional adult gate as the tab — Live TV never surfaces adult
    // channels, and reaching it from the omnibox must not be a way around that.
    const filters = pure.Filters{ .query = query, .nsfw_allowed = false };
    var ctx = MapCtx.init(logos_body, chans_body);
    defer ctx.deinit();
    return pure.fillRanked(body, out, filters, ctx);
}

pub fn searchIptv(query: []const u8) void {
    if (query.len == 0) return;
    if (iptvBase() == null) return; // inert

    state.app.iptv.is_loading.store(true, .release);
    state.app.iptv.fetch_error = false;
    state.app.iptv.showing_popular = false;
    // A search satisfies "page opens with content" — never let the one-shot
    // popular fetch land on top of the user's results afterwards.
    popular_fetched.store(true, .release);
    visible = PAGE_SIZE;

    // Snapshot the query + current filters BEFORE spawning (armFetch), so filter
    // + search compose and a newer search supersedes this one.
    const my_gen = armFetch(query);

    if (std.Thread.spawn(.{}, fetchWorker, .{ my_gen, true })) |t| {
        t.detach();
    } else |_| {
        state.app.iptv.is_loading.store(false, .release);
    }
}

/// One fetch + full parse (popular or search). `is_search` picks whether the
/// snapshotted query filters titles. Runs the whole parse into the fixed
/// results[] under `search_gen`, so a fresh search supersedes an in-flight one.
fn fetchWorker(my_gen: u32, is_search: bool) void {
    defer state.app.iptv.is_loading.store(false, .release);

    const base = iptvBase() orelse return; // inert (plugin uninstalled mid-flight)

    var url_buf: [256]u8 = undefined;
    const url = pure.buildStreamsUrl(base, &url_buf);
    if (url.len == 0) return;

    // Re-snapshot the query — a newer search may overwrite query_buf mid-flight.
    var local_q: [256]u8 = undefined;
    const qlen = if (is_search) @min(query_len, local_q.len) else 0;
    if (qlen > 0) @memcpy(local_q[0..qlen], query_buf[0..qlen]);

    // Snapshot the filter statics too — armFetch writes them before bumping the
    // gen, so a concurrent applyFilters() could overlap-write them while this
    // worker reads; copy up front like the query.
    var l_cat: [32]u8 = undefined;
    const l_cat_len = @min(flt_category_len, l_cat.len);
    @memcpy(l_cat[0..l_cat_len], flt_category[0..l_cat_len]);
    var l_country: [8]u8 = undefined;
    const l_country_len = @min(flt_country_len, l_country.len);
    @memcpy(l_country[0..l_country_len], flt_country[0..l_country_len]);
    const l_quality = flt_quality;
    const l_sort = flt_sort;

    // ── User's own M3U playlist (overrides the public directory) ──
    if (m3uUrl()) |mu| {
        var mbuf: [640]u8 = undefined;
        const mlen = @min(mu.len, mbuf.len);
        @memcpy(mbuf[0..mlen], mu[0..mlen]);
        const mbody = curl(mbuf[0..mlen], 16 * 1024 * 1024) orelse {
            state.app.iptv.fetch_error = true;
            return;
        };
        defer alloc.free(mbody);
        if (search_gen.load(.acquire) != my_gen) return;
        parse_mutex.lock();
        defer parse_mutex.unlock();
        if (search_gen.load(.acquire) != my_gen) return;
        const cat = l_cat[0..l_cat_len];
        const count = playlist.parseM3u(mbody, &state.app.iptv.results, false, local_q[0..qlen], cat);
        state.app.iptv.result_count = count;
        if (count == 0) {
            if (!is_search) state.app.iptv.fetch_error = true;
        } else if (!is_search) putPopularCache();
        return;
    }

    // Shared public directory — be a polite citizen. streams.json is a big
    // static file, so a slow bucket is fine.
    rate_limit.acquire("iptv-org", 0.5);

    // 16 MiB cap: streams.json is ~4 MB today with headroom to grow. A larger
    // feed truncates at the buffer edge (a partial last object is harmless —
    // parseStreams is bounds-safe), never overruns. Heap-allocated inside curl.
    const body = curl(url, 16 * 1024 * 1024) orelse {
        state.app.iptv.fetch_error = true;
        return;
    };
    defer alloc.free(body);

    // Sibling directories for thumbnails + metadata (logos.json / channels.json).
    // Best-effort and DISK-CACHED (they're big, ~7/10 MB, and change slowly), so
    // a search re-reads them from disk instead of re-downloading. A miss just
    // leaves cards on the glyph fallback — never blocks the channel list.
    var logos_url_buf: [256]u8 = undefined;
    var chans_url_buf: [256]u8 = undefined;
    const logos_url = pure.buildLogosUrl(base, &logos_url_buf);
    const chans_url = pure.buildChannelsUrl(base, &chans_url_buf);
    const logos_body: ?[]u8 = if (logos_url.len > 0) fetchCached(logos_url, "iptv-logos.json", 16 * 1024 * 1024, ENRICH_TTL_S) else null;
    defer if (logos_body) |lb| alloc.free(lb);
    const chans_body: ?[]u8 = if (chans_url.len > 0) fetchCached(chans_url, "iptv-channels.json", 24 * 1024 * 1024, ENRICH_TTL_S) else null;
    defer if (chans_body) |cb| alloc.free(cb);

    if (search_gen.load(.acquire) != my_gen) return; // superseded while curl ran

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return; // re-check under lock

    // Live TV NEVER surfaces adult channels — unconditionally, independent of
    // the global NSFW setting (that toggle governs mature anime/VN content, not
    // porn streams). The gate is always on: the title/url heuristic drops obvious
    // ones, and the precise channels.json is_nsfw flag (via MapCtx) drops the rest.
    const filters = pure.Filters{
        .query = local_q[0..qlen],
        .category = l_cat[0..l_cat_len],
        .country = l_country[0..l_country_len],
        .quality = pure.QualityFilter.fromIndex(l_quality),
        .nsfw_allowed = false,
    };

    // Index logos.json + channels.json once; the join plugs into the SAME tested
    // fill loop the pure tests exercise (pure.fillRanked with a map-backed ctx).
    var ctx = MapCtx.init(logos_body, chans_body);
    defer ctx.deinit();

    // One filter-aware, identified-first pass: parse + join + filter straight
    // into results[]. Filtering happens DURING selection, so a category/country
    // view fills its own up-to-cap window (not a post-filtered slice of the top
    // 300) — this is what makes the whole directory reachable by drilling in.
    const count = pure.fillRanked(body, &state.app.iptv.results, filters, ctx);

    // Sort the filled window (relevance = keep identified-first rank order).
    const sort_mode = pure.SortMode.fromIndex(l_sort);
    if (sort_mode != .relevance) {
        std.mem.sort(pure.IptvChannel, state.app.iptv.results[0..count], sort_mode, sortLessThan);
    }

    state.app.iptv.result_count = count;

    if (count == 0) {
        if (is_search) {
            logs.pushLog("info", "iptv", "Live TV search returned no channels", false);
        } else {
            state.app.iptv.fetch_error = true;
            logs.pushLog("info", "iptv", "Live TV directory returned no channels", false);
        }
    } else {
        if (!is_search) putPopularCache();
        var lb: [64]u8 = undefined;
        logs.pushLog("info", "iptv", std.fmt.bufPrint(&lb, "Live TV: {d} channels loaded", .{count}) catch "Live TV channels loaded", false);
    }
}

// ══════════════════════════════════════════════════════════
// Infinite scroll — reveal the next window (no fetch; progressive)
// ══════════════════════════════════════════════════════════

/// Reveal PAGE_SIZE more already-parsed channels. All accepted channels are
/// parsed up front (streams.json is a single static file, ≤ the fixed cap), so
/// paging is instant client-side reveal — no request, no retained body. UI
/// thread only (called from renderResults on near-bottom scroll).
pub fn loadMore() void {
    const total = @min(state.app.iptv.result_count, state.app.iptv.results.len);
    if (visible >= total) return;
    visible = @min(visible + PAGE_SIZE, total);
}

// ══════════════════════════════════════════════════════════
// Play — hand the m3u8 URL straight to mpv (exactly like radio.playStation)
// ══════════════════════════════════════════════════════════

/// Load channel `idx`'s HLS stream into mpv. The URL is an m3u8/.ts stream mpv
/// plays natively, so loadContentDirectMeta (no content-type routing) is used —
/// creating a player if none exists and revealing the player page, with the
/// channel name + quality shown on the (video-less until the stream connects)
/// player pane and bottom bar.
pub fn playChannel(idx: usize) void {
    if (idx >= state.app.iptv.result_count) return;
    const ch = &state.app.iptv.results[idx];
    const src = ch.url[0..ch.url_len];
    if (src.len == 0) return;

    // Dead-stream guard: if the last probe marked this URL dead, tell the user
    // instead of loading a silent black player.
    if (healthOf(src) == .dead) {
        state.showToast("Channel unavailable — try another");
        return;
    }

    // Snapshot the now-playing fields into locals BEFORE playing — a concurrent
    // re-search can overwrite results[] mid-frame, so nothing handed to
    // loadContentDirectMeta may alias the live row.
    var url_buf: [512]u8 = undefined;
    const ulen = @min(src.len, url_buf.len);
    @memcpy(url_buf[0..ulen], src[0..ulen]);

    var name_buf: [160]u8 = undefined;
    const nlen = @min(ch.name_len, name_buf.len);
    @memcpy(name_buf[0..nlen], ch.name[0..nlen]);

    // Subtitle: "1080p · HLS" — quality (when present) + an HLS tag for m3u8.
    var sub_buf: [64]u8 = undefined;
    var sw = std.Io.Writer.fixed(&sub_buf);
    var wrote = false;
    if (ch.quality_len > 0) {
        sw.writeAll(ch.quality[0..@min(ch.quality_len, ch.quality.len)]) catch {};
        wrote = true;
    }
    if (pure.isM3u8(url_buf[0..ulen])) {
        if (wrote) sw.writeAll(" · ") catch {};
        sw.writeAll("HLS") catch {};
        wrote = true;
    }
    const sub = sub_buf[0..sw.end];

    // Snapshot the HTTP play hints too — many IPTV CDNs 400/403 without the
    // exact user_agent / referrer the directory lists (mpv's default UA is a
    // common block). Copied into locals BEFORE the handoff for the same
    // no-aliasing reason as url/name above.
    var ua_buf: [256]u8 = undefined;
    const ualen = @min(ch.user_agent_len, ua_buf.len);
    @memcpy(ua_buf[0..ualen], ch.user_agent[0..ualen]);
    var ref_buf: [256]u8 = undefined;
    const reflen = @min(ch.referrer_len, ref_buf.len);
    @memcpy(ref_buf[0..reflen], ch.referrer[0..reflen]);

    // Send an Origin matching the Referer's site alongside it — CDNs that gate
    // on Referer usually gate on Origin too, and a missing Origin is the single
    // most common remaining 403 on HLS. Derivation is pure + unit-tested.
    const http_headers = @import("../player/http_headers_pure.zig");
    var origin_buf: [256]u8 = undefined;
    const origin: []const u8 = if (reflen > 0)
        (http_headers.originFromReferer(ref_buf[0..reflen], &origin_buf) orelse "")
    else
        "";
    const hdrs = [_]http_headers.HttpHeader{
        .{ .name = "Referer", .value = ref_buf[0..reflen] },
        .{ .name = "Origin", .value = origin },
    };

    @import("browser.zig").loadContentDirectMetaHeaders(url_buf[0..ulen], "", name_buf[0..nlen], sub, ua_buf[0..ualen], &hdrs);
    // Record into recents (a display snapshot incl. play hints, so it replays
    // with the right headers). Snapshot the row by value first — recordRecent
    // must not read the live results[] row a re-fetch could rewrite.
    var snap = state.app.iptv.results[idx];
    iptv_store.recordRecent(&snap);
    logs.pushLog("info", "iptv", "Streaming live TV channel", false);
}

// ══════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════

/// Fetch `url` with curl into a fresh heap buffer of `cap` bytes. Returns the
/// filled slice (caller frees) or null on failure/empty. Large buffers stay off
/// the worker stack (macOS 512KB limit). Shrinks to what was read so the global
/// DebugAllocator's free-size check passes (an invalid free aborts the process).
fn curl(url: []const u8, cap: usize) ?[]u8 {
    const argv = [_][]const u8{ "curl", "-sL", "-A", agent, "--max-time", "30", url };
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
    return alloc.realloc(buf, n) catch {
        alloc.free(buf);
        return null;
    };
}

// ══════════════════════════════════════════════════════════
// Enrichment — logos.json (thumbnails) + channels.json (category/country/nsfw)
// ══════════════════════════════════════════════════════════

// logos.json / channels.json are ~7/10 MB static directories that change slowly.
// Cache them on disk for a day so a search doesn't re-download them; the popular
// list still refreshes daily.
const ENRICH_TTL_S: i64 = 24 * 60 * 60;

/// Fetch `url` with a `ttl_s` on-disk cache (file `name` in the cache dir).
/// Returns an owned buffer (caller frees) or null. A fresh disk copy skips the
/// network entirely; a miss/stale entry downloads then persists (best-effort —
/// a cache read/write error just falls through to / skips the network).
fn fetchCached(url: []const u8, name: []const u8, cap: usize, ttl_s: i64) ?[]u8 {
    var path_buf: [512]u8 = undefined;
    const path = paths.cacheFile(&path_buf, name);

    if (io.cwdStatFile(path)) |st| {
        const mtime_s: i64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
        const age = io.timestamp() - mtime_s;
        if (age >= 0 and age < ttl_s) {
            if (io.cwdReadFileAlloc(path, alloc, cap)) |buf| {
                if (buf.len > 0) return buf;
                alloc.free(buf);
            } else |_| {}
        }
    } else |_| {}

    const body = curl(url, cap) orelse return null;
    paths.ensureCacheDir();
    // Write to a temp sibling then rename so a concurrent reader (or a second
    // worker) never sees a half-written file — rename is atomic on the target.
    var tmp_buf: [520]u8 = undefined;
    if (std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path})) |tmp| {
        if (io.cwdWriteFile(.{ .sub_path = tmp, .data = body })) |_| {
            io.renameAbsolute(tmp, path) catch io.deleteFileAbsolute(tmp) catch {};
        } else |_| {}
    } else |_| {}
    return body;
}

/// The metadata JOIN plugged into pure.fillRanked. Indexes logos.json +
/// channels.json ONCE into id→object maps (a per-row scan over a 7–10 MB body
/// would be seconds); enrich(c) is then an O(1) lookup + a tested field pull per
/// identified stream. Map keys borrow the bodies, which outlive the fill call.
/// Because the join is a ctx hook, the shipped fill loop IS the pure-tested loop.
const MapCtx = struct {
    logo_map: std.StringHashMap([]const u8),
    chan_map: std.StringHashMap([]const u8),

    fn buildMap(body: ?[]const u8, marker: []const u8) std.StringHashMap([]const u8) {
        var m = std.StringHashMap([]const u8).init(alloc);
        if (body) |b| {
            m.ensureTotalCapacity(48 * 1024) catch {};
            var it = pure.ObjIter{ .json = b, .marker = marker };
            while (it.next()) |e| {
                if (e.id.len > 0) m.put(e.id, e.obj) catch {};
            }
        }
        return m;
    }

    fn init(logos_body: ?[]const u8, chans_body: ?[]const u8) MapCtx {
        return .{
            .logo_map = buildMap(logos_body, pure.LOGO_MARKER),
            .chan_map = buildMap(chans_body, pure.CHANNEL_MARKER),
        };
    }

    fn deinit(self: *MapCtx) void {
        self.logo_map.deinit();
        self.chan_map.deinit();
    }

    /// fillRanked join hook: fill logo/country/category for an identified stream,
    /// returning the precise channels.json is_nsfw flag.
    pub fn enrich(self: MapCtx, c: *pure.IptvChannel) bool {
        const id = c.chan_id[0..@min(c.chan_id_len, c.chan_id.len)];
        if (id.len == 0) return false;
        if (self.logo_map.get(id)) |obj| c.logo_len = pure.logoUrlFromObj(obj, &c.logo);
        if (self.chan_map.get(id)) |obj| {
            const m = pure.channelMetaFromObj(obj, &c.country, &c.category);
            c.country_len = m.country_len;
            c.category_len = m.category_len;
            c.nsfw = m.nsfw;
            return m.nsfw;
        }
        return false;
    }
};

/// std.mem.sort adapter over the pure comparator (elements pass by value).
fn sortLessThan(mode: pure.SortMode, a: pure.IptvChannel, b: pure.IptvChannel) bool {
    return pure.channelLessThan(mode, &a, &b);
}

// ══════════════════════════════════════════════════════════
// UI (Drawer / Browse › Live TV)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    ensureFavSet();
    // (health map refresh is lazy inside link_health, on first statusOf/probe)

    // Populate the page on first open — only the All view fetches the network;
    // the Favorites/Recent views are DB-backed (loaded on chip select).
    if (state.app.iptv.quick_filter == 0) loadPopularOnce();

    renderToolbar();

    if (state.app.iptv.fetch_error) {
        _ = dvui.label(@src(), "Failed to fetch — check your connection", .{}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    renderResults();
}

/// A theme-matched dropdown. dvui.dropdown's popup renders on a WHITE default
/// menu (Opal menus are dark), so this mirrors the footer language dropup: a
/// submenu-menuItem trigger + a floatingMenu with explicit dark colors. Returns
/// the picked index when a choice is made, else null. `id` disambiguates the
/// widgets (this helper's @src() is shared across its call sites).
fn themedSelect(id: usize, labels: []const []const u8, cur: usize, width: f32) ?usize {
    var result: ?usize = null;
    var m = dvui.menu(@src(), .horizontal, .{
        .id_extra = id,
        .color_fill = theme.transparent,
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });
    defer m.deinit();

    const cur_label = if (cur < labels.len) labels[cur] else labels[0];
    if (dvui.menuItemLabel(@src(), cur_label, .{ .submenu = true }, .{
        .id_extra = id,
        .min_size_content = .{ .w = width, .h = 0 },
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .color_fill_hover = theme.colors.bg_hover,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 5, .w = 6, .h = 5 },
    })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = id });
        defer fw.deinit();
        var vm = dvui.menu(@src(), .vertical, .{
            .id_extra = id,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .border = dvui.Rect.all(1),
            .color_border = theme.colors.border_subtle,
            .corner_radius = theme.dims.rad_sm,
        });
        defer vm.deinit();
        for (labels, 0..) |lb, i| {
            if (dvui.menuItemLabel(@src(), lb, .{}, .{
                .id_extra = i,
                .expand = .horizontal,
                .color_text = if (i == cur) theme.colors.accent else theme.colors.text_primary,
            })) |_| {
                result = i;
            }
        }
    }
    return result;
}

// ── Filter bar (category / country / quality / sort) ──
// Labels are shown to the user; the parallel *_CODES are the iptv-org codes
// matched (case-insensitively) against the channels.json join. Index 0 = "All".
const CAT_LABELS = [_][]const u8{ "All categories", "News", "Sports", "Movies", "Music", "Entertainment", "General", "Kids", "Documentary", "Education", "Lifestyle", "Comedy", "Business", "Culture", "Series", "Science", "Religious", "Weather" };
const CAT_CODES = [_][]const u8{ "", "news", "sports", "movies", "music", "entertainment", "general", "kids", "documentary", "education", "lifestyle", "comedy", "business", "culture", "series", "science", "religious", "weather" };

const COUNTRY_LABELS = [_][]const u8{ "All countries", "United States", "United Kingdom", "India", "Canada", "Brazil", "Germany", "France", "Spain", "Italy", "Russia", "Turkey", "Mexico", "Argentina", "Indonesia", "Poland", "Netherlands", "South Korea", "Japan", "Portugal", "Romania", "Greece", "Australia", "Philippines", "Vietnam", "Thailand", "Saudi Arabia", "Pakistan", "Egypt", "Nigeria" };
const COUNTRY_CODES = [_][]const u8{ "", "US", "GB", "IN", "CA", "BR", "DE", "FR", "ES", "IT", "RU", "TR", "MX", "AR", "ID", "PL", "NL", "KR", "JP", "PT", "RO", "GR", "AU", "PH", "VN", "TH", "SA", "PK", "EG", "NG" };

const QUALITY_LABELS = [_][]const u8{ "Any", "SD", "HD", "FHD" };
const SORT_LABELS = [_][]const u8{ "Relevance", "Name", "Country" };

/// Index of the option whose code matches `current` (case-insensitive), else 0.
fn codeIndex(codes: []const []const u8, current: []const u8) usize {
    for (codes, 0..) |code, i| {
        if (code.len != current.len) continue;
        var eq = true;
        for (code, current) |x, y| {
            if (std.ascii.toLower(x) != std.ascii.toLower(y)) {
                eq = false;
                break;
            }
        }
        if (eq) return i;
    }
    return 0;
}

// ── Toolbar: EVERYTHING in one row ──
// [tv][search (fills)][Go] [All|Fav|Recent] [cat][country][Any/SD/HD/FHD][sort]
// [Working][Test]. The search entry expands to eat the slack, so it stays roomy
// while the controls pack to the right — one line instead of three.
fn renderToolbar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer row.deinit();

    const setFixedBuf = @import("../core/text.zig").setFixedBuf;
    const inert = iptvBase() == null;

    _ = dvui.icon(@src(), "", icons.tvg.lucide.@"monitor-play", .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.iptv.search_buf },
        .placeholder = "Search channels...",
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
        .margin = .{ .x = 6, .y = 0, .w = 8, .h = 0 },
        .gravity_y = 0.5,
    });
    if (entered or go) {
        const q = std.mem.sliceTo(&state.app.iptv.search_buf, 0);
        if (q.len > 0) searchIptv(q);
    }

    // Controls only when the plugin is installed (an inert tab shows just search).
    if (inert) return;

    if (state.app.iptv.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "...", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5, .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 } });
    }

    // Quick-filter chips.
    const chips = [_][]const u8{ "All", "Favorites", "Recent" };
    if (components.segment(@src(), &chips, @as(usize, state.app.iptv.quick_filter))) |clicked| {
        if (@as(u8, @intCast(clicked)) != state.app.iptv.quick_filter) selectQuickFilter(@intCast(clicked));
    }

    // Category/country/quality/sort — All view only (Favorites/Recent don't filter).
    if (state.app.iptv.quick_filter == 0) {
        const cat_idx = codeIndex(&CAT_CODES, state.app.iptv.filter_category[0..state.app.iptv.filter_category_len]);
        if (themedSelect(1, &CAT_LABELS, cat_idx, 128)) |sel| {
            setFixedBuf(state.app.iptv.filter_category[0..], &state.app.iptv.filter_category_len, CAT_CODES[sel]);
            applyFilters();
        }

        const cty_idx = codeIndex(&COUNTRY_CODES, state.app.iptv.filter_country[0..state.app.iptv.filter_country_len]);
        if (themedSelect(2, &COUNTRY_LABELS, cty_idx, 138)) |sel| {
            setFixedBuf(state.app.iptv.filter_country[0..], &state.app.iptv.filter_country_len, COUNTRY_CODES[sel]);
            applyFilters();
        }

        if (components.segment(@src(), &QUALITY_LABELS, @as(usize, state.app.iptv.filter_quality))) |clicked| {
            state.app.iptv.filter_quality = @intCast(clicked);
            applyFilters();
        }

        if (themedSelect(3, &SORT_LABELS, state.app.iptv.sort_mode, 110)) |sel| {
            state.app.iptv.sort_mode = @intCast(sel);
            applyFilters();
        }
    }

    // Working-only toggle (hides dead-probed channels) — active = green fill.
    if (dvui.button(@src(), "Working", .{}, .{
        .color_fill = if (working_only) theme.colors.success else theme.transparent,
        .color_fill_hover = theme.colors.bg_hover,
        .color_text = if (working_only) dvui.Color.white else theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
        .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
    })) {
        working_only = !working_only;
    }

    // Test: re-probe the visible window now (clears the session guard).
    if (dvui.button(@src(), "Test", .{}, .{
        .color_fill = theme.colors.bg_elevated,
        .color_fill_hover = theme.colors.bg_hover,
        .color_text = theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
        .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
    })) {
        // Wipe the session guard AND the cached rows so the reload can't
        // re-block probing; the (now empty) map reload makes cards re-probe.
        link_health.clear(IPTV_KIND);
        link_health.clearKind(IPTV_KIND);
        iptv_store.clearHealth(); // legacy iptv_health rows too
    }
}

// ── Card grid ──
// Cards show the channel LOGO (joined from logos.json, fetched via the shared
// poster daemon) + name + "category · country · quality · HLS". Channels with
// no logo (null-channel streams, or a logo stb_image can't decode) fall back to
// a tv glyph. Click → playChannel(i).
const CARD_GAP: f32 = 6;
const CARD_TARGET_W: f32 = 170;
const CARD_FOOTER_H: f32 = 46;

// Parallel poster slots, one per results[] row (sized to the 300 cap so
// channel_posters[i] can never index out of bounds). Mirrors radio's
// station_posters: a URL-hash change means "different channel here" → free the
// stale texture and refetch. pixels are c_alloc'd inside poster.zig.
const ChannelPoster = struct {
    pixels: ?[]u8 = null,
    tex: ?dvui.Texture = null,
    w: u32 = 0,
    h: u32 = 0,
    fetching: bool = false,
    url_hash: u64 = 0,
};
var channel_posters: [300]ChannelPoster = [_]ChannelPoster{.{}} ** 300;

/// Fill the card's logo area from the channel's logo URL via the shared poster
/// daemon. Falls back to the tv glyph while loading, when the channel has no
/// logo, or when the image can't be decoded (webp/svg logos stb_image can't
/// read — the glyph is a normal outcome, not an error). UI-thread only.
fn renderLogo(i: usize, ch: *const pure.IptvChannel) void {
    const slot = &channel_posters[i];
    const logo = ch.logo[0..@min(ch.logo_len, ch.logo.len)];

    if (logo.len > 0) {
        // Pin the slot to whatever channel is at index i now — a re-search (or
        // the popular list landing) can replace results[], so a URL-hash change
        // means "different channel here": free the stale texture/pixels and
        // refetch (only when not mid-fetch, so we never double-spawn a worker).
        const h = std.hash.Fnv1a_64.hash(logo);
        if (slot.url_hash != h and !slot.fetching) {
            poster.deinitPoster(&slot.pixels, &slot.tex);
            slot.w = 0;
            slot.h = 0;
            slot.url_hash = h;
        }
        _ = poster.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.tex);
        if (slot.tex == null and !slot.fetching and slot.pixels == null)
            poster.fetchAsync(logo, &slot.pixels, &slot.w, &slot.h, &slot.fetching);
    }

    if (slot.tex) |*tex| {
        _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
            .id_extra = i + 1000,
            .expand = .both,
            .corner_radius = dvui.Rect.all(8),
        });
    } else {
        _ = dvui.icon(@src(), "", icons.tvg.lucide.tv, .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });
    }
}

/// One channel card: logo tile (clickable → play) + name + category/country/quality.
fn renderCard(i: usize, card_w: f32) void {
    const ch = &state.app.iptv.results[i];

    // Validate a STABLE COPY: a fetch worker can rewrite results[i] mid-frame
    // and dvui panics on invalid UTF-8 it reads after we validated.
    var name_buf: [160]u8 = undefined;
    const name = safeUtf8Buf(ch.name[0..@min(ch.name_len, ch.name.len)], &name_buf);

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i,
        .min_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .margin = dvui.Rect.all(CARD_GAP),
    });
    defer card.deinit();

    // Glyph tile hosted INSIDE a single button widget — one clickable rectangle.
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

        renderLogo(i, ch);

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (clicked) playChannel(i);
    }

    // Name row: title (expand) + a favorite star. The star is a sibling of the
    // play tile (not inside its button), so toggling a favorite never triggers
    // playback. Star color = gold when favorited, muted otherwise.
    {
        var nrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 6000, .expand = .horizontal });
        defer nrow.deinit();

        // Health status dot (green live / yellow slow / red dead). Probing is
        // lazy: rendering a card kicks a bounded probe for its stream.
        const url = ch.url[0..@min(ch.url_len, ch.url.len)];
        maybeProbe(url);
        const st = healthOf(url);
        if (st != .unknown) {
            var dot = dvui.box(@src(), .{}, .{
                .id_extra = i + 8000,
                .min_size_content = .{ .w = 8, .h = 8 },
                .max_size_content = .{ .w = 8, .h = 8 },
                .corner_radius = dvui.Rect.all(4),
                .background = true,
                .color_fill = statusColor(st),
                .gravity_y = 0.5,
                .margin = .{ .x = 2, .y = 0, .w = 4, .h = 0 },
            });
            dot.deinit();
        }

        _ = dvui.label(@src(), "{s}", .{name}, .{
            .id_extra = i + 3000,
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .gravity_y = 0.5,
            .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
        });
        const faved = isFav(ch.url[0..@min(ch.url_len, ch.url.len)]);
        if (dvui.buttonIcon(@src(), "iptvfav", icons.tvg.lucide.star, .{}, .{}, .{
            .id_extra = i + 7000,
            .color_text = if (faved) theme.colors.warning else theme.colors.text_tertiary,
            .color_fill = theme.transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .border = dvui.Rect.all(0),
            .min_size_content = theme.iconSize(.sm),
            .padding = dvui.Rect.all(4),
            .gravity_y = 0.5,
        })) {
            _ = iptv_store.toggleFavorite(ch);
            fav_dirty = true;
            // Removing a favorite while viewing Favorites → drop it from the grid.
            if (state.app.iptv.quick_filter == 1) loadQuickView();
        }
    }

    // Meta: category · country · quality · HLS (whichever are present). Category
    // + country come from the channels.json join; quality from the stream.
    var meta_buf: [96]u8 = undefined;
    var mw = std.Io.Writer.fixed(&meta_buf);
    var wrote = false;
    const sep = struct {
        fn go(w: *std.Io.Writer, wrote_any: *bool) void {
            if (wrote_any.*) w.writeAll(" · ") catch {};
            wrote_any.* = true;
        }
    }.go;
    if (ch.category_len > 0) {
        sep(&mw, &wrote);
        mw.writeAll(ch.category[0..@min(ch.category_len, ch.category.len)]) catch {};
    }
    if (ch.country_len > 0) {
        sep(&mw, &wrote);
        mw.writeAll(ch.country[0..@min(ch.country_len, ch.country.len)]) catch {};
    }
    if (ch.quality_len > 0) {
        sep(&mw, &wrote);
        mw.writeAll(ch.quality[0..@min(ch.quality_len, ch.quality.len)]) catch {};
    }
    if (pure.isM3u8(ch.url[0..ch.url_len])) {
        sep(&mw, &wrote);
        mw.writeAll("HLS") catch {};
    }
    if (wrote) {
        var safe_meta: [96]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(meta_buf[0..mw.end], &safe_meta)}, .{
            .id_extra = i + 4000,
            .color_text = theme.colors.text_tertiary,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
    }
}

fn renderResults() void {
    const total = @min(state.app.iptv.result_count, state.app.iptv.results.len);
    if (total == 0) {
        if (state.app.iptv.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Loading channels...", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        } else if (iptvBase() == null) {
            // Inert — no plugin installed.
            _ = dvui.label(@src(), "Install the IPTV (iptv-org) plugin to enable Live TV", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        } else {
            const msg = switch (state.app.iptv.quick_filter) {
                1 => "No favorites yet — tap the star on a channel to save it",
                2 => "No recently watched channels yet",
                else => "No channels found",
            };
            _ = dvui.label(@src(), "{s}", .{msg}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        }
        return;
    }

    // Clamp the reveal window to what's actually parsed.
    const shown = @min(@max(visible, PAGE_SIZE), total);

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    // Visible index list. Working-only hides CONFIRMED-dead channels (unknown /
    // live / slow stay, so lazily-probed cards aren't hidden before their probe
    // lands). Fixed array sized to the cap — never allocates.
    var vis: [300]usize = undefined;
    var vcount: usize = 0;
    {
        var idx: usize = 0;
        while (idx < shown and vcount < vis.len) : (idx += 1) {
            if (working_only) {
                const c = &state.app.iptv.results[idx];
                if (healthOf(c.url[0..@min(c.url_len, c.url.len)]) == .dead) continue;
            }
            vis[vcount] = idx;
            vcount += 1;
        }
    }

    // Heading: "N channels" (+ hint when we hit the 300 window, so the user knows
    // to narrow with a filter rather than assume that's all).
    var head_buf: [80]u8 = undefined;
    const capped = total >= state.app.iptv.results.len;
    const heading = std.fmt.bufPrint(&head_buf, "{d} channels{s}{s}", .{
        vcount,
        if (working_only) " working" else "",
        if (capped and !working_only) " · narrow with filters" else "",
    }) catch "Live TV channels";
    _ = dvui.label(@src(), "{s}", .{heading}, .{
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 2 },
    });

    // Responsive columns from the LIVE page width (one-frame lag; first paint
    // falls back to a sane default) — same shape as radio's grid.
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / CARD_TARGET_W)));
    const cols_f: f32 = @floatFromInt(cols);
    const card_w: f32 = @max(100, (avail_w - cols_f * 2 * CARD_GAP) / cols_f);

    var r: usize = 0;
    while (r * cols < vcount) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = r + 50000,
            .expand = .horizontal,
        });
        defer row.deinit();

        var col: usize = 0;
        while (col < cols and r * cols + col < vcount) : (col += 1) renderCard(vis[r * cols + col], card_w);
    }

    // Progressive infinite scroll: reveal the next window as the user nears the
    // bottom. No fetch — everything is already parsed, so this is an instant
    // client-side reveal (mirrors radio's near-bottom trigger without the async
    // append worker). `underfilled` keeps revealing when the first window is
    // shorter than the viewport.
    if (shown < total) {
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        const underfilled = max_y <= 0;
        if (near_bottom or underfilled) {
            loadMore();
            dvui.refresh(null, @src(), null);
        }
    }
}
