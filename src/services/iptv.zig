//! Live TV (IPTV) tab — the VIDEO twin of radio.zig. Keyless channel discovery
//! streamed straight through mpv (HLS/m3u8/.ts play natively). All parsing + the
//! accept/NSFW decisions live in iptv_pure.zig (tested); this module owns the
//! ingest worker, thread-safety, and dvui rendering.
//!
//! The channel directory lives in a SQLite CATALOG (services/iptv_catalog.zig,
//! table in core/db.zig), populated by the ingest worker from the installed
//! curated sources (services/iptv_sources.zig) — SWR, re-ingested at most every
//! 24h per source. The catalog holds the WHOLE directory (100k-scale across many
//! playlists); state.app.iptv.results is only a bounded SLIDING WINDOW of it
//! (RENDER_WINDOW rows) that follows the viewport, so scroll is unbounded while
//! memory stays flat. Search/filter query the whole catalog (indexed LIKE +
//! quality/sort), so every channel is reachable regardless of the window.
//!
//! Opt-in: a source is source_config-gated. No source installed and an empty
//! catalog → the tab is INERT. The default-on curated sources auto-install on
//! first open so it lights up out of the box.
//!
//! Flow:
//!   loadPopularOnce()  → ensureDefaultSources() → refillFromCatalog() (paint) →
//!                        refreshAllSources() (background ingest, SWR).
//!   search / filters   → refillFromCatalog() re-queries the catalog live.
//!   renderResults()    → sliding-window virtualization over total_matches.
//!   playChannel(i)     → browser.loadContentDirectMetaHeaders(url) → mpv.

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
const catalog = @import("iptv_catalog.zig");
const catalog_pure = @import("iptv_catalog_pure.zig");
const sources = @import("iptv_sources.zig");
const tmdb_pure = @import("tmdb_pure.zig"); // unit-tested grid virtualization (visibleRows)

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

// ══════════════════════════════════════════════════════════
// Thread-safety
// ══════════════════════════════════════════════════════════
// The render path publishes into state.app.iptv.* under `parse_mutex` (shared by
// refillFromCatalog, loadQuickView and the ingest worker). `is_loading` is atomic
// (read by the UI + remote threads, written by the ingest worker).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};

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
/// network) — the fav/recent quick-filter view.
fn loadQuickView() void {
    const kind: iptv_store.Kind = if (state.app.iptv.quick_filter == 1) .fav else .recent;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    state.app.iptv.result_count = iptv_store.loadInto(kind, &state.app.iptv.results);
    state.app.iptv.showing_popular = false;
    state.app.iptv.fetch_error = false;
    state.app.iptv.is_loading.store(false, .release);
    // Bounded snapshot: the whole list is in results[] starting at row 0, so the
    // render maps catalog row → slot with win_base 0 (no sliding for fav/recent).
    win_base = 0;
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

/// One-shot latch. renderContent() calls loadPopularOnce every frame; after the
/// first, this is a single atomic load. Atomic (not a plain bool) because
/// searchIptv — reachable from the remote-API thread — also arms it.
var popular_fetched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ══════════════════════════════════════════════════════════
// Popular — the full channel directory (query = "")
// ══════════════════════════════════════════════════════════

pub fn loadPopularOnce() void {
    if (popular_fetched.load(.acquire)) return;
    // Same first-start gate as the other one-shot loaders: wait for config.
    if (!state.app.config_loaded.load(.acquire)) return;

    // Light the tab up out of the box: install the default-on curated source(s)
    // the first time Live TV is opened on a fresh profile.
    ensureDefaultSources();

    // Inert until SOME source is installed AND we have no cached channels — don't
    // latch, so the tab fills the moment the user installs one (no restart).
    if (!anySourceInstalled() and catalog.isEmpty()) return;

    // A search already landed (remote API) — leave it be.
    if (state.app.iptv.result_count > 0) {
        popular_fetched.store(true, .release);
        return;
    }

    popular_fetched.store(true, .release);
    state.app.iptv.fetch_error = false;

    // Paint instantly from the catalog (SWR), then kick a background refresh that
    // re-ingests any stale source and repaints when done.
    refillFromCatalog();
    refreshAllSources(false);
}

// ══════════════════════════════════════════════════════════
// Filters — re-run with the current filter-bar + search state
// ══════════════════════════════════════════════════════════

/// Re-fetch with the current category/country/quality/sort + search text (called
/// when a filter-bar control changes). Filters and search compose. Inert until
/// the plugin is installed.
pub fn applyFilters() void {
    // A filter change satisfies "page has content" — don't let the one-shot
    // popular fetch land on top afterwards.
    popular_fetched.store(true, .release);
    state.app.iptv.fetch_error = false;
    // Category / country / quality filter + sort over the WHOLE catalog (fast
    // indexed query). Empty facets → the full directory.
    refillFromCatalog();
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

    // Adult gate matches the tab: governed by the NSFW setting (off → adult
    // channels included), so the omnibox and the tab agree.
    const filters = pure.Filters{ .query = query, .nsfw_allowed = !state.app.nsfw_filter_enabled };
    var ctx = MapCtx.init(logos_body, chans_body);
    defer ctx.deinit();
    return pure.fillRanked(body, out, filters, ctx);
}

pub fn searchIptv(query: []const u8) void {
    if (query.len == 0) return;
    // A search satisfies "page opens with content" — never let the one-shot
    // popular fetch land on top of the user's results afterwards.
    popular_fetched.store(true, .release);
    state.app.iptv.fetch_error = false;
    // The query is read from search_buf by currentQuery(); the caller has already
    // written it there. Search covers the WHOLE catalog via the name_lc index.
    refillFromCatalog();
}

// ══════════════════════════════════════════════════════════
// SQLite catalog — the 100k-channel directory
// ══════════════════════════════════════════════════════════
//
// The Live TV directory outgrew the fixed results[] window: the goal is every
// channel from many user playlists (100k+), which no static array can hold. So
// the full directory lives in the `iptv_catalog` table (core/db.zig), populated
// by the ingest worker below (SWR, 24h per source), and the render path fills
// the bounded results[] window from it with a paged, indexed query. Search and
// facets therefore cover the WHOLE catalog even though only RENDER_WINDOW rows
// are materialized at once.

const INGEST_TTL_S: i64 = 24 * 60 * 60; // SWR: re-ingest a source at most daily
// Per-source parse cap. Heap-allocated (never the worker stack — CLAUDE.md), so a
// whole source is captured at once, then freed after insert. Sized in the PURE
// registry (iptv_sources.INGEST_CAP, tested) above iptv-org's live streams.json
// (~17.5k and growing) with headroom for large user playlists — the 20k it was
// left ~zero slack over iptv-org, silently dropping channels once the feed grew.
const INGEST_CAP: usize = sources.INGEST_CAP;
var ingesting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Sliding render window over the catalog. results[0] holds catalog row
// `win_base`; results[] materializes up to RENDER_WINDOW rows around the
// viewport. As the user scrolls, renderResults slides the window (refillWindow)
// so the FULL directory is reachable by scroll — the scrollbar spans
// total_matches while only a bounded slice is ever in memory. This is what makes
// the scroll unbounded rather than capped at one RENDER_WINDOW page.
var win_base: usize = 0;

// Full count of catalog rows matching the current query — the WHOLE directory,
// not the materialized window. The virtualization sizes the scroll height from
// this and the heading shows it. Refreshed by refillWindow.
var total_matches: usize = 0;

/// True if any Live TV source (curated or custom) is installed — the tab is
/// inert until then, but existing catalog rows still render if a source was
/// later uninstalled.
pub fn anySourceInstalled() bool {
    for (sources.SOURCES) |s| {
        if (source_config.has(s.id)) return true;
    }
    return source_config.get(sources.CUSTOM_ID, "url") != null;
}

/// Install the default-on curated sources once, so the tab lights up out of the
/// box instead of sitting inert behind the plugin manager. Only runs when NOTHING
/// is installed (respects a user who has deliberately uninstalled everything —
/// once they have any source, we never re-add). UI-thread; writes source_config.
fn ensureDefaultSources() void {
    if (anySourceInstalled()) return;
    for (sources.SOURCES) |s| {
        if (!s.default_on) continue;
        var body_buf: [640]u8 = undefined;
        const body = sources.installBody(s, &body_buf) orelse continue;
        _ = source_config.install(s.id, body);
        logs.pushLog("info", "iptv", "Enabled default Live TV source", false);
    }
}

/// The catalog query for the current filter-bar + search state.
fn currentQuery() catalog.Query {
    const q = std.mem.sliceTo(&state.app.iptv.search_buf, 0);
    const qb = catalog_pure.qualityBounds(state.app.iptv.filter_quality);
    return .{
        .text = q,
        .country = state.app.iptv.filter_country[0..state.app.iptv.filter_country_len],
        .category = state.app.iptv.filter_category[0..state.app.iptv.filter_category_len],
        .qmin = qb.min,
        .qmax = qb.max,
        // SortMode index 2 = country (see iptv_pure.SortMode.fromIndex); name and
        // relevance both fall through to name order.
        .sort_country = state.app.iptv.sort_mode == 2,
        // Adult channels show only when the NSFW filter is OFF (setting governs
        // Live TV adult content, per the user's request).
        .nsfw_allowed = !state.app.nsfw_filter_enabled,
    };
}

/// Load a RENDER_WINDOW-sized slice of the catalog at row `base` for the current
/// filter/search into results[]. total_matches is the whole-catalog count, so
/// the render can size the full scroll height. Fast (indexed LIKE), so it runs
/// synchronously under parse_mutex.
fn refillWindow(base: usize) void {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    const q = currentQuery();
    const n = catalog.queryPage(&state.app.iptv.results, base, q);
    win_base = base;
    state.app.iptv.result_count = n;
    total_matches = catalog.count(q);
    state.app.iptv.showing_popular = (q.text.len == 0 and q.country.len == 0 and q.category.len == 0);
}

/// Reset the window to the top of the list (a search/filter/quick-view change).
fn refillFromCatalog() void {
    refillWindow(0);
}

// Live incremental search — snapshot of the last-applied search text so a change
// (typing OR clearing) re-queries the catalog immediately, without waiting for an
// Enter press. Empty text restores the full directory. Catalog-view only.
var last_search_buf: [256]u8 = std.mem.zeroes([256]u8);
var last_search_len: usize = 0;

/// Called every frame from the search bar. Refills the grid the moment the query
/// text changes — including when it's cleared, which restores the full list — so
/// results are never stuck behind a submit. The catalog query is a fast indexed
/// read, so a per-keystroke refill is cheap. Fav/Recent are DB snapshots, not
/// searched, so this is a no-op there.
fn pollLiveSearch() void {
    if (state.app.iptv.quick_filter != 0) return;
    const q = std.mem.sliceTo(&state.app.iptv.search_buf, 0);
    if (q.len == last_search_len and std.mem.eql(u8, q, last_search_buf[0..last_search_len])) return;
    const n = @min(q.len, last_search_buf.len);
    @memcpy(last_search_buf[0..n], q[0..n]);
    last_search_len = n;
    popular_fetched.store(true, .release); // the box now owns what's shown
    state.app.iptv.fetch_error = false;
    refillFromCatalog();
}

/// Kick a background ingest of every installed source. `force` bypasses the 24h
/// SWR freshness check (the settings "Refresh now" button). No-op if an ingest
/// is already running.
pub fn refreshAllSources(force: bool) void {
    if (ingesting.load(.acquire)) return;
    if (std.Thread.spawn(.{}, ingestWorker, .{force})) |t| {
        t.detach();
    } else |_| {}
}

fn ingestWorker(force: bool) void {
    if (ingesting.swap(true, .acq_rel)) return; // another ingest beat us
    defer ingesting.store(false, .release);
    // Mirror into is_loading so the grid shows its existing spinner while a first
    // (empty-catalog) ingest is downloading + parsing.
    state.app.iptv.is_loading.store(true, .release);
    defer state.app.iptv.is_loading.store(false, .release);

    var changed = false;
    for (sources.SOURCES) |s| {
        if (!source_config.has(s.id)) continue;
        if (ingestOne(s.id, s.kind, s.url, force)) changed = true;
    }
    // The user's custom playlist (Live TV settings), if any.
    if (source_config.get(sources.CUSTOM_ID, "url")) |u| {
        var ub: [512]u8 = undefined;
        const ul = @min(u.len, ub.len);
        @memcpy(ub[0..ul], u[0..ul]);
        if (ingestOne(sources.CUSTOM_ID, .m3u, ub[0..ul], force)) changed = true;
    }

    if (changed) {
        refillFromCatalog();
        if (state.app.dvui_win) |win| dvui.refresh(win, @src(), null);
    }
}

/// Ingest one source into the catalog if stale (or forced). Returns true when it
/// actually re-ingested. The URL is resolved from source_config (honoring a user
/// override) with the registry URL as fallback.
fn ingestOne(id: []const u8, kind: sources.Kind, fallback_url: []const u8, force: bool) bool {
    if (!force) {
        const last = catalog.lastIngest(id);
        if (last > 0 and (io.timestamp() - last) < INGEST_TTL_S) return false; // fresh
    }

    // Resolve endpoint: base sources store "base", m3u/custom store "url".
    const field = switch (kind) {
        .base => "base",
        .m3u => "url",
    };
    var url_buf: [640]u8 = undefined;
    const stored = source_config.get(id, field);
    const src_url = blk: {
        const s = stored orelse fallback_url;
        const n = @min(s.len, url_buf.len);
        @memcpy(url_buf[0..n], s[0..n]);
        break :blk url_buf[0..n];
    };
    if (src_url.len == 0) return false;

    const buf = alloc.alloc(pure.IptvChannel, INGEST_CAP) catch {
        logs.pushLog("info", "iptv", "Ingest skipped: out of memory for parse buffer", false);
        return false;
    };
    defer alloc.free(buf);

    const n = switch (kind) {
        .base => ingestBase(src_url, buf),
        .m3u => ingestM3u(src_url, buf),
    };
    if (n == 0) return false;

    // A source the user declared adult (custom playlist "adult" flag) flags ALL
    // its channels nsfw, so an adult playlist is gated even when its channel
    // names/groups don't self-identify.
    const force_adult = source_config.get(id, "adult") != null;

    // Replace the source's rows atomically: clear then insert. ingestChannels
    // applies the adult gate (group denylist + parser flag) per channel too.
    catalog.clearSource(id);
    const inserted = catalog.ingestChannels(id, buf[0..n], force_adult);
    catalog.markIngested(id, inserted);

    var lb: [96]u8 = undefined;
    logs.pushLog("info", "iptv", std.fmt.bufPrint(&lb, "Ingested {d} channels from {s}", .{ inserted, id }) catch "Ingested source", false);
    return true;
}

/// iptv-org-style JSON API: streams.json joined with logos/channels for
/// enrichment, parsed through the SAME tested fill loop the tab uses.
fn ingestBase(base: []const u8, buf: []pure.IptvChannel) usize {
    var url_buf: [256]u8 = undefined;
    const surl = pure.buildStreamsUrl(base, &url_buf);
    if (surl.len == 0) return 0;

    rate_limit.acquire("iptv-org", 0.5);
    const body = fetchCached(surl, "iptv-streams.json", 16 * 1024 * 1024, ENRICH_TTL_S) orelse return 0;
    defer alloc.free(body);

    var logos_url_buf: [256]u8 = undefined;
    var chans_url_buf: [256]u8 = undefined;
    const logos_url = pure.buildLogosUrl(base, &logos_url_buf);
    const chans_url = pure.buildChannelsUrl(base, &chans_url_buf);
    const logos_body: ?[]u8 = if (logos_url.len > 0) fetchCached(logos_url, "iptv-logos.json", 16 * 1024 * 1024, ENRICH_TTL_S) else null;
    defer if (logos_body) |lb| alloc.free(lb);
    const chans_body: ?[]u8 = if (chans_url.len > 0) fetchCached(chans_url, "iptv-channels.json", 24 * 1024 * 1024, ENRICH_TTL_S) else null;
    defer if (chans_body) |cb| alloc.free(cb);

    // Ingest the WHOLE directory (query=""). Adult channels are KEPT here (parse
    // nsfw_allowed=true) so they land in the catalog flagged nsfw=1; the render
    // query then hides or shows them per the NSFW setting.
    const filters = pure.Filters{ .query = "", .nsfw_allowed = true };
    var ctx = MapCtx.init(logos_body, chans_body);
    defer ctx.deinit();
    return pure.fillRanked(body, buf, filters, ctx);
}

/// Direct .m3u/.m3u8 playlist. parseM3u tolerates a missing #EXTM3U header and a
/// leading BOM (it scans for #EXTINF lines). Adult channels are kept (flagged in
/// the catalog) so the NSFW setting governs them, not a hard drop.
fn ingestM3u(url: []const u8, buf: []pure.IptvChannel) usize {
    const body = curl(url, 16 * 1024 * 1024) orelse return 0;
    defer alloc.free(body);
    return playlist.parseM3u(body, buf, true, "", "");
}

/// Settings-page helpers ──────────────────────────────────────────────────────

/// Install a curated source by id and ingest it immediately (forced).
pub fn installSource(id: []const u8) void {
    const s = sources.byId(id) orelse return;
    var body_buf: [640]u8 = undefined;
    const body = sources.installBody(s, &body_buf) orelse return;
    if (source_config.install(s.id, body)) refreshAllSources(true);
}

/// Uninstall a curated source: drop its endpoint AND its catalog rows.
pub fn uninstallSource(id: []const u8) void {
    source_config.uninstallById(id);
    catalog.removeSource(id);
    refillFromCatalog();
}

/// Save (or clear) the user's custom playlist URL and ingest it. `adult` marks
/// the whole playlist 18+ so every channel from it is NSFW-gated (hidden unless
/// the NSFW filter is off) — for an adult playlist whose channels don't
/// self-identify by name/group.
pub fn setCustomUrl(url: []const u8, adult: bool) void {
    if (url.len == 0) {
        source_config.uninstallById(sources.CUSTOM_ID);
        catalog.removeSource(sources.CUSTOM_ID);
        refillFromCatalog();
        return;
    }
    var body_buf: [700]u8 = undefined;
    const body = if (adult)
        std.fmt.bufPrint(&body_buf, "{{\"url\":\"{s}\",\"adult\":\"1\"}}", .{url}) catch return
    else
        std.fmt.bufPrint(&body_buf, "{{\"url\":\"{s}\"}}", .{url}) catch return;
    if (source_config.install(sources.CUSTOM_ID, body)) refreshAllSources(true);
}

/// Channels a source contributed (fast; from the meta row). For the settings UI.
pub fn sourceChannelCount(id: []const u8) usize {
    return catalog.recordedCount(id);
}

/// True while a background ingest is running — drives the settings spinner.
pub fn isIngesting() bool {
    return ingesting.load(.acquire);
}

/// Total channels currently in the catalog across all sources.
pub fn catalogTotal() usize {
    return catalog.count(.{});
}

// ══════════════════════════════════════════════════════════
// Infinite scroll — slide the catalog window to follow the viewport
// ══════════════════════════════════════════════════════════

/// Slack rows kept loaded on each side of the viewport before a re-slide, so
/// scrolling within the window never re-queries and a small scroll back up still
/// finds its rows in memory. A quarter of the window on the leading side.
const WIN_MARGIN: usize = pure.RENDER_WINDOW / 4;

/// Ensure the loaded window covers catalog rows [first, last). If the viewport
/// has scrolled outside the materialized slice, re-query a fresh RENDER_WINDOW
/// starting a margin before `first`, so the full directory is reachable by
/// scroll without ever holding more than one window in memory. Returns true if
/// it re-queried (the caller then repaints). UI thread only.
fn ensureWindow(first: usize, last: usize) bool {
    const loaded_end = win_base + state.app.iptv.result_count;
    if (first >= win_base and last <= loaded_end) return false; // already covered
    const new_base = if (first > WIN_MARGIN) first - WIN_MARGIN else 0;
    if (new_base == win_base and state.app.iptv.result_count >= state.app.iptv.results.len) return false;
    refillWindow(new_base);
    return true;
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

    // Clear (×) — only when there's text. Zeroing the buffer lets pollLiveSearch
    // restore the full directory on the next frame, so "remove the filter" is a
    // dynamic update, not a stuck search.
    if (std.mem.sliceTo(&state.app.iptv.search_buf, 0).len > 0) {
        if (dvui.buttonIcon(@src(), "iptvclear", icons.tvg.lucide.x, .{}, .{}, .{
            .color_text = theme.colors.text_secondary,
            .color_fill = theme.transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .border = dvui.Rect.all(0),
            .min_size_content = theme.iconSize(.sm),
            .margin = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
            .gravity_y = 0.5,
        })) {
            @memset(&state.app.iptv.search_buf, 0);
        }
    }

    // Live incremental search: results track the text as it's typed or cleared.
    // Enter still submits explicitly (a no-op if the live poll already applied it).
    pollLiveSearch();
    if (entered) {
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

// Parallel poster slots, one per results[] row (sized to the render window so
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
var channel_posters: [pure.RENDER_WINDOW]ChannelPoster = [_]ChannelPoster{.{}} ** pure.RENDER_WINDOW;

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
    // Fav/Recent are bounded DB snapshots (result_count IS the whole list); the
    // catalog "All" view is unbounded (total_matches spans the whole directory,
    // results[] is a sliding window). grid_total is the row source for each.
    const is_catalog = state.app.iptv.quick_filter == 0;
    const grid_total = if (is_catalog) total_matches else state.app.iptv.result_count;

    if (grid_total == 0) {
        if (state.app.iptv.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Loading channels...", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        } else if (!anySourceInstalled() and catalog.isEmpty()) {
            _ = dvui.label(@src(), "Enable a Live TV source in Settings to fill the channel guide", .{}, .{
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

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    // Heading: total channels across the WHOLE catalog. No "narrow with filters"
    // hint any more — the scroll is unbounded (the window slides).
    var head_buf: [96]u8 = undefined;
    const heading = std.fmt.bufPrint(&head_buf, "{d} channels{s}", .{
        grid_total,
        if (working_only) " working" else "",
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

    // ── Virtualization over the WHOLE catalog (sliding window) ──
    // total_rows spans every matching channel, so the scrollbar represents the
    // entire directory. tmdb_pure.visibleRows picks the rows in view (±3 rows
    // overscan); ensureWindow then guarantees those catalog rows are materialized
    // in results[] (re-querying a fresh RENDER_WINDOW when the viewport scrolls
    // out of the loaded slice). Cards are uniform (renderCard pins
    // min==max = card_w+CARD_FOOTER_H), so the row pitch is fixed and the two
    // spacer boxes reserve the off-screen height above/below.
    const row_h: f32 = card_w + CARD_FOOTER_H + 2 * CARD_GAP;
    const total_rows = (grid_total + cols - 1) / cols;
    const win = tmdb_pure.visibleRows(total_rows, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 3);
    const first_ch = win.first * cols;
    const last_ch = @min(win.last * cols, grid_total);

    // Slide the loaded window to cover the visible catalog rows. Bounded views
    // (fav/recent) are already fully in results[] at win_base 0, so skip.
    if (is_catalog and ensureWindow(first_ch, last_ch)) dvui.refresh(null, @src(), null);

    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 59998,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) },
        });
        sp.deinit();
    }

    var r: usize = win.first;
    while (r < win.last) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = r + 50000,
            .expand = .horizontal,
        });
        defer row.deinit();

        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const ch = r * cols + col;
            if (ch >= grid_total) break;
            if (ch < win_base) continue; // above the loaded window (transient)
            const slot = ch - win_base;
            if (slot >= state.app.iptv.result_count) continue; // below it (transient)
            if (working_only) {
                const c = &state.app.iptv.results[slot];
                if (healthOf(c.url[0..@min(c.url_len, c.url.len)]) == .dead) continue; // hide dead
            }
            renderCard(slot, card_w);
        }
    }

    if (win.last < total_rows) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 59999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(total_rows - win.last)) },
        });
        sp.deinit();
    }
}
