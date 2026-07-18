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
const logs = @import("../core/logs.zig");
const pure = @import("iptv_pure.zig");
const io = @import("../core/io_global.zig");
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
const IPTV_CACHE_KEY = "iptv:popular";
const IPTV_BLOB_CAP: usize = 256 * 1024;

fn serializeChannel(w: *ccp.Writer, c: pure.IptvChannel) void {
    w.blob(c.name[0..@min(c.name_len, c.name.len)]);
    w.blob(c.url[0..@min(c.url_len, c.url.len)]);
    w.blob(c.quality[0..@min(c.quality_len, c.quality.len)]);
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
    // is in flight supersedes it instead of racing it into results[].
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;
    query_len = 0; // popular = no query filter

    if (std.Thread.spawn(.{}, fetchWorker, .{ my_gen, false })) |t| {
        t.detach();
    } else |_| {
        state.app.iptv.is_loading.store(false, .release);
    }
}

// ══════════════════════════════════════════════════════════
// Search — title filter over the same streams.json
// ══════════════════════════════════════════════════════════

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

    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    // Snapshot the query BEFORE spawning — a newer search overwrites query_buf.
    const n = @min(query.len, query_buf.len);
    @memcpy(query_buf[0..n], query[0..n]);
    query_len = n;

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

    if (search_gen.load(.acquire) != my_gen) return; // superseded while curl ran

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return; // re-check under lock

    // NSFW: nsfw_allowed is the INVERSE of the app's filter flag. When the
    // filter is on (default), adult channels are dropped at parse time and can
    // never render (mirrors anime/vndb SFW gating).
    const nsfw_allowed = !state.app.nsfw_filter_enabled;
    const count = pure.parseStreams(body, &state.app.iptv.results, nsfw_allowed, local_q[0..qlen]);
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

    @import("browser.zig").loadContentDirectMeta(url_buf[0..ulen], "", name_buf[0..nlen], sub);
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
// UI (Drawer / Browse › Live TV)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    // Populate the page on first open (no-op after the first fetch / when inert).
    loadPopularOnce();

    renderSearchBar();

    if (state.app.iptv.fetch_error) {
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

    _ = dvui.icon(@src(), "", icons.tvg.lucide.@"monitor-play", .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.iptv.search_buf },
        .placeholder = "Search live TV channels...",
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
        const q = std.mem.sliceTo(&state.app.iptv.search_buf, 0);
        if (q.len > 0) searchIptv(q);
    }

    if (state.app.iptv.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "...", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
    }
}

// ── Card grid ──
// Channels have no logos in streams.json, so cards are a tv glyph + name +
// "quality · HLS". Click → playChannel(i).
const CARD_GAP: f32 = 6;
const CARD_TARGET_W: f32 = 170;
const CARD_FOOTER_H: f32 = 46;

/// One channel card: tv glyph tile (clickable → play) + name + quality/HLS.
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

        _ = dvui.icon(@src(), "", icons.tvg.lucide.tv, .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (clicked) playChannel(i);
    }

    _ = dvui.label(@src(), "{s}", .{name}, .{
        .id_extra = i + 3000,
        .color_text = theme.colors.text_primary,
        .expand = .horizontal,
        .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
    });

    // Meta: quality · HLS.
    var meta_buf: [48]u8 = undefined;
    var mw = std.Io.Writer.fixed(&meta_buf);
    var wrote = false;
    if (ch.quality_len > 0) {
        mw.writeAll(ch.quality[0..@min(ch.quality_len, ch.quality.len)]) catch {};
        wrote = true;
    }
    if (pure.isM3u8(ch.url[0..ch.url_len])) {
        if (wrote) mw.writeAll(" · ") catch {};
        mw.writeAll("HLS") catch {};
        wrote = true;
    }
    if (wrote) {
        var safe_meta: [48]u8 = undefined;
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
            _ = dvui.label(@src(), "No channels found", .{}, .{
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

    _ = dvui.label(@src(), "{s}", .{
        if (state.app.iptv.showing_popular) "Live TV channels" else "Results",
    }, .{
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
    while (r * cols < shown) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = r + 50000,
            .expand = .horizontal,
        });
        defer row.deinit();

        var col: usize = 0;
        while (col < cols and r * cols + col < shown) : (col += 1) renderCard(r * cols + col, card_w);
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
