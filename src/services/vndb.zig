//! VNDB (Visual Novel Database) catalog tab — a browse/discovery + info surface
//! for visual novels via VNDB's public HTTPS JSON API (no auth). VNs are NOT
//! played in-app; this is a catalog like the TMDB tab: search VNs → card grid
//! (cover + title + rating) → detail panel (description, tags, length, rating).
//!
//! Structurally a sibling of radio.zig, one level shallower than podcasts: a
//! popular/search grid plus a detail overlay. All parsing + the SFW filter live
//! in vndb_pure.zig (tested); this module owns the async POST worker,
//! thread-safety, cover-art fetch, and dvui rendering.
//!
//! ── NSFW SAFETY ──
//! The SFW filter is applied at PARSE TIME inside vndb_pure.parseVns (which calls
//! vndb_pure.isSfw for every entry) — sexual/violence-flagged covers never enter
//! results[], so nothing NSFW can render or hand off. See vndb_pure.zig.
//!
//! Flow:
//!   loadPopularOnce() → POST /kana/vn {sort:votecount} → parseVns → results[].
//!                     Fires once per session so the page opens populated.
//!   searchVndb(q)     → POST /kana/vn {filters:[search,=,q]} → parseVns → results[].
//!   openDetail(i)     → selected_idx = i (detail overlay).
//!   searchTorrents(i) → hand the title to universal search (browse-only handoff).

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const pure = @import("vndb_pure.zig");
const io = @import("../core/io_global.zig");
const poster = @import("../core/poster.zig");
const rate_limit = @import("../core/rate_limit.zig");
const search = @import("search.zig");
const safeUtf8 = @import("../core/text.zig").safeUtf8;
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

const alloc = @import("../core/alloc.zig").allocator;

const API_URL = "https://api.vndb.org/kana/vn";
const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

// ── Cover artwork ──
// VN covers reuse the shared poster daemon (poster.zig: async fetch, global
// in-flight cap, disk cache, texture upload) — the exact path radio favicons
// take. The Vn record lives in vndb_pure.zig (kept free of dvui/atomics), so the
// GPU texture + pixel state lives HERE in a module-static array parallel to
// state.app.vndb.results[] by index. The array is never reallocated, so the raw
// &slot.* pointers handed to poster.fetchAsync stay valid for the detached
// worker. A slot's url_hash pins it to the VN currently at that index: a fresh
// search that puts a different VN there frees the stale texture and refetches, so
// a cover can never bleed across searches. pixels are c_alloc'd inside poster.zig
// — never free them with `alloc`; deinitPoster/uploadIfReady use the matching
// allocator.
//
// Sized to match state.app.vndb.results.len (180), NOT the old 30-card cap:
// infinite scroll can grow result_count past 30, and renderCard/renderCover
// index this array by the SAME `i` as results[i], so a smaller array would be
// an out-of-bounds index the moment a scroll-triggered append lands. Still a
// fixed array (no realloc), so pointer-safety for the detached poster.fetchAsync
// worker is unchanged.
const CoverSlot = struct {
    pixels: ?[]u8 = null,
    tex: ?dvui.Texture = null,
    w: u32 = 0,
    h: u32 = 0,
    fetching: bool = false,
    url_hash: u64 = 0,
};
var cover_slots: [180]CoverSlot = [_]CoverSlot{.{}} ** 180;

// ── Thread-safety ──
// The detached fetch worker publishes into state.app.vndb.* under `parse_mutex`,
// and a monotonic `search_gen` drops stale results so fast re-searches never show
// out-of-order data (mirrors radio.zig). `is_loading` is atomic (read by UI +
// remote threads, written by the worker).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Query snapshot handed to the detached search worker (never read the mutable UI
// search_buf from the thread). `is_popular` selects which request body is built.
var query_buf: [256]u8 = undefined;
var query_len: usize = 0;

// ── Infinite-scroll pagination ──
// `current_page` is the highest VNDB `page` merged into state.app.vndb.results;
// `more_available` clears once VNDB's own "more" flag says the query is
// exhausted or the fixed 180-card buffer fills. `loading_more` serializes
// append fetches so a single near-bottom scroll can't spawn a burst (mirrors
// drama.zig/comics.zig). The append worker runs under the current `search_gen`
// so a fresh search/popular re-fetch drops a stale in-flight append.
var current_page: u32 = 1;
var more_available: bool = true;
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Which request-body path a load-more append must reuse — has to match
/// whatever produced the CURRENT grid (popular chart vs. search query), else a
/// scroll-triggered page 2 could silently switch feeds. Set right before the
/// initial fetch spawns in loadPopularOnce()/searchVndb().
var current_is_popular: bool = true;

// ══════════════════════════════════════════════════════════
// Popular — most-voted VNs (one fetch per session)
// ══════════════════════════════════════════════════════════

/// One-shot latch. renderContent() calls this every frame, so every call after
/// the first is a single atomic load. Atomic (not a plain bool) because
/// searchVndb — which also arms it, so the chart can't land on top of a user's
/// results — is reachable from the remote-API thread.
var popular_fetched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn loadPopularOnce() void {
    if (popular_fetched.load(.acquire)) return;
    // Same first-start gate as the other one-shot loaders: don't latch until
    // config has published (the poster daemon's disk cache needs the db open).
    if (!state.app.config_loaded.load(.acquire)) return;
    if (state.app.vndb.result_count > 0) {
        popular_fetched.store(true, .release);
        return;
    }
    if (state.app.vndb.is_loading.load(.acquire)) return;

    popular_fetched.store(true, .release);
    state.app.vndb.showing_popular = true;
    state.app.vndb.fetch_error = false;
    state.app.vndb.is_loading.store(true, .release);
    // Fresh landing chart resets pagination; fetchPage() re-derives
    // more_available from VNDB's own "more" flag once page 1 lands.
    current_page = 1;
    more_available = true;
    current_is_popular = true;

    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;
    query_len = 0; // empty query → popular body

    if (std.Thread.spawn(.{}, fetchWorker, .{ my_gen, true })) |t| {
        t.detach();
    } else |_| {
        state.app.vndb.is_loading.store(false, .release);
    }
}

// ══════════════════════════════════════════════════════════
// Search
// ══════════════════════════════════════════════════════════

pub fn searchVndb(query: []const u8) void {
    if (query.len == 0) return;

    state.app.vndb.is_loading.store(true, .release);
    state.app.vndb.fetch_error = false;
    state.app.vndb.showing_popular = false;
    state.app.vndb.selected_idx = null; // leaving detail on a new search
    // A search satisfies the "page opens with content" job — never let the
    // one-shot popular fetch land on top of the user's results afterwards.
    popular_fetched.store(true, .release);
    // Fresh search resets pagination; fetchPage() re-derives more_available
    // from VNDB's own "more" flag once page 1 lands.
    current_page = 1;
    more_available = true;
    current_is_popular = false;

    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    // Snapshot the query BEFORE spawning — a newer search overwrites query_buf.
    const n = @min(query.len, query_buf.len);
    @memcpy(query_buf[0..n], query[0..n]);
    query_len = n;

    if (std.Thread.spawn(.{}, fetchWorker, .{ my_gen, false })) |t| {
        t.detach();
    } else |_| {
        state.app.vndb.is_loading.store(false, .release);
    }
}

/// Infinite-scroll appender: fetch the NEXT VNDB page for whichever request
/// path produced the current grid (popular chart or search query) and merge it
/// onto the existing grid. Guarded in order: `more_available` (VNDB said no
/// more, or the buffer's full) → the main `is_loading` fetch flag (never
/// append mid-fresh-fetch) → `loading_more` (serializes so one near-bottom
/// scroll can't spawn a burst) → an empty grid or a full buffer. Runs under the
/// CURRENT search_gen so a fresh search/popular re-fetch supersedes a slow
/// in-flight append. Mirrors services/drama.zig loadMore.
pub fn loadMore() void {
    if (!more_available) return;
    if (state.app.vndb.is_loading.load(.acquire)) return;
    if (loading_more.load(.acquire)) return;
    if (state.app.vndb.result_count == 0) return;
    if (state.app.vndb.result_count >= state.app.vndb.results.len) {
        more_available = false;
        return;
    }
    if (loading_more.swap(true, .acq_rel)) return; // lost the race — another append in flight

    const my_gen = search_gen.load(.acquire); // stay within the current generation
    const is_popular = current_is_popular;
    const next = current_page + 1;
    if (std.Thread.spawn(.{}, loadMoreWorker, .{ my_gen, is_popular, next })) |t| {
        t.detach();
    } else |_| {
        loading_more.store(false, .release);
    }
}

fn fetchWorker(my_gen: u32, is_popular: bool) void {
    defer state.app.vndb.is_loading.store(false, .release);
    fetchPage(my_gen, is_popular, 1, false);
}

fn loadMoreWorker(my_gen: u32, is_popular: bool, page: u32) void {
    defer loading_more.store(false, .release);
    fetchPage(my_gen, is_popular, page, true);
}

/// Fetch one VNDB page and publish it into state.app.vndb.results. `append`
/// selects the write path: false (fresh fetch, page 1) overwrites from index 0;
/// true (infinite-scroll load-more) writes starting at the CURRENT
/// result_count, never resetting it, so earlier cards/cover_slots never move.
/// Same fetch path (buildSearchBody/buildPopularBody) and the same SFW filter
/// (isSfw, applied inside pure.parseVns) as page 1 — appended pages are
/// filtered identically, never loosened.
fn fetchPage(my_gen: u32, is_popular: bool, page: u32, append: bool) void {
    // Build the POST body from a re-snapshot of the query (a newer search may
    // overwrite query_buf mid-flight).
    var body_buf: [1024]u8 = undefined;
    const body = if (is_popular)
        pure.buildPopularBody(page, &body_buf)
    else blk: {
        var local: [256]u8 = undefined;
        const qlen = @min(query_len, local.len);
        @memcpy(local[0..qlen], query_buf[0..qlen]);
        break :blk pure.buildSearchBody(local[0..qlen], page, &body_buf);
    };
    if (body.len == 0) {
        if (!append) state.app.vndb.fetch_error = true;
        return;
    }

    // Be a polite API citizen (VNDB asks for reasonable rates).
    rate_limit.acquire("vndb", 1.0);

    const resp = curlPost(API_URL, body, 512 * 1024) orelse {
        if (!append) state.app.vndb.fetch_error = true;
        return;
    };
    defer alloc.free(resp);

    if (search_gen.load(.acquire) != my_gen) return; // superseded

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return; // re-check under lock

    const cap = state.app.vndb.results.len;
    const base = if (append) state.app.vndb.result_count else 0;
    if (base >= cap) {
        more_available = false;
        return;
    }

    // parseVns applies the SFW filter internally (isSfw) — flagged entries are
    // dropped before they reach results[]. Handing it results[base..] makes it
    // write starting at `base`: index 0 for a fresh fetch, the current
    // result_count for an append — the array is never cleared on append.
    const count = pure.parseVns(resp, state.app.vndb.results[base..cap]);
    state.app.vndb.result_count = base + count;
    current_page = page;

    // End-of-results signal: VNDB's own top-level "more" boolean — NOT a
    // filtered-count-vs-page-size comparison. The SFW filter can legitimately
    // drop entries from an otherwise-full raw page, so a count-based check
    // would stop paging early. See responseHasMore's doc comment.
    more_available = pure.responseHasMore(resp) and state.app.vndb.result_count < cap;

    if (!append) {
        if (count == 0) {
            logs.pushLog("info", "vndb", "No visual novels returned", false);
        } else {
            logs.pushLog("info", "vndb", "Visual novels loaded (VNDB, SFW-filtered)", false);
        }
    } else {
        var lb: [64]u8 = undefined;
        logs.pushLog("info", "vndb", std.fmt.bufPrint(&lb, "Loaded {d} more VNs (VNDB p{d})", .{ count, page }) catch "Loaded more VNs", false);
    }
    dvui.refresh(null, @src(), null); // wake the frame so the new cards paint
}

// ══════════════════════════════════════════════════════════
// Detail + torrent handoff (browse-only)
// ══════════════════════════════════════════════════════════

/// Open the detail overlay for result `idx`.
pub fn openDetail(idx: usize) void {
    if (idx >= state.app.vndb.result_count) return;
    state.app.vndb.selected_idx = idx;
}

/// Close the detail overlay, returning to the grid.
pub fn closeDetail() void {
    state.app.vndb.selected_idx = null;
}

/// Hand a VN's title to universal (all-source) search — the same browse→search
/// handoff the TMDB cards use. Browse-only: VNs aren't played in-app, so this is
/// the one outward action.
fn searchTorrents(idx: usize) void {
    if (idx >= state.app.vndb.result_count) return;
    const v = &state.app.vndb.results[idx];
    var qbuf: [256]u8 = undefined;
    const title = safeUtf8(v.title[0..@min(v.title_len, v.title.len)]);
    const q = std.fmt.bufPrint(&qbuf, "{s}", .{title}) catch return;
    state.navigateToTab(.Search);
    search.submitQuery(q);
    state.showToast("Searching all sources...");
}

// ══════════════════════════════════════════════════════════
// HTTP (curl POST)
// ══════════════════════════════════════════════════════════

/// POST `body` (JSON) to `url` with curl, into a fresh heap buffer of `cap`
/// bytes. Returns the filled slice (caller frees) or null on failure/empty. Large
/// buffers stay off the worker stack (macOS 512KB limit). curl-only — std.http
/// SEGVs on some ISP TLS resets (see comics.zig).
fn curlPost(url: []const u8, body: []const u8, cap: usize) ?[]u8 {
    const argv = [_][]const u8{
        "curl",           "-sL",   "-X",   "POST",
        "-H",             "Content-Type: application/json",
        "-A",             agent,   "-d",   body,
        "--max-time",     "15",    url,
    };
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
    // — returning buf[0..n] out of a cap-sized allocation is an INVALID FREE and
    // aborts the process (the radio/podcasts twin of this helper does the same).
    return alloc.realloc(buf, n) catch {
        alloc.free(buf);
        return null;
    };
}

// ══════════════════════════════════════════════════════════
// Cleanup
// ══════════════════════════════════════════════════════════

/// Free cover textures/pixels not currently being fetched. UI-thread only; call
/// at shutdown before the app tears down.
pub fn freeCovers() void {
    for (&cover_slots) |*slot| {
        if (slot.fetching) continue;
        poster.deinitPoster(&slot.pixels, &slot.tex);
        slot.w = 0;
        slot.h = 0;
        slot.url_hash = 0;
    }
}

// ══════════════════════════════════════════════════════════
// UI (Browse › Visual Novels)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    // Populate the page on first open (no-op after the first fetch).
    loadPopularOnce();

    // Detail overlay takes over the whole view (like the TMDB TV drill-down).
    if (state.app.vndb.selected_idx) |idx| {
        if (idx < state.app.vndb.result_count) {
            renderDetail(idx);
            return;
        }
        state.app.vndb.selected_idx = null;
    }

    renderSearchBar();

    if (state.app.vndb.fetch_error) {
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

    _ = dvui.icon(@src(), "", icons.tvg.lucide.@"gamepad-2", .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.vndb.search_buf },
        .placeholder = "Search visual novels…",
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
        const q = std.mem.sliceTo(&state.app.vndb.search_buf, 0);
        if (q.len > 0) searchVndb(q);
    }

    if (state.app.vndb.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
    }
}

// ── Card grid ──
const CARD_GAP: f32 = 6;
const CARD_TARGET_W: f32 = 150; // desired card width; columns derive from it
const CARD_COVER_H: f32 = 200; // cover art height (VN box-art is portrait)
const CARD_FOOTER_H: f32 = 52; // title + rating/year lines under the cover

/// Fill a card's cover area with the VN cover art via the shared poster daemon.
/// Falls back to the gamepad glyph while loading / when there's no cover / when
/// the image can't be decoded. UI-thread only.
fn renderCover(i: usize, v: *const pure.Vn) void {
    const slot = &cover_slots[i];
    const url = v.image_url[0..v.image_url_len];

    if (url.len > 0) {
        const h = std.hash.Fnv1a_64.hash(url);
        if (slot.url_hash != h and !slot.fetching) {
            poster.deinitPoster(&slot.pixels, &slot.tex);
            slot.w = 0;
            slot.h = 0;
            slot.url_hash = h;
        }
        _ = poster.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.tex);
        if (slot.tex == null and !slot.fetching and slot.pixels == null)
            poster.fetchAsync(url, &slot.pixels, &slot.w, &slot.h, &slot.fetching);
    }

    if (slot.tex) |*tex| {
        _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
            .id_extra = i + 1000,
            .expand = .both,
            .corner_radius = dvui.Rect.all(8),
        });
    } else {
        _ = dvui.icon(@src(), "", icons.tvg.lucide.@"gamepad-2", .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });
    }
}

/// One VN card: cover (clickable → detail) + title + rating · year.
fn renderCard(i: usize, card_w: f32) void {
    const v = &state.app.vndb.results[i];

    var title_buf: [256]u8 = undefined;
    const title = safeUtf8Buf(v.title[0..@min(v.title_len, v.title.len)], &title_buf);

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i,
        .min_size_content = .{ .w = card_w, .h = CARD_COVER_H + CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = CARD_COVER_H + CARD_FOOTER_H },
        .margin = dvui.Rect.all(CARD_GAP),
    });
    defer card.deinit();

    // Cover hosted INSIDE a single button widget — one clickable rectangle.
    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = i + 2000,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(8),
            .min_size_content = .{ .w = card_w, .h = CARD_COVER_H },
            .max_size_content = .{ .w = card_w, .h = CARD_COVER_H },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();

        renderCover(i, v);

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (clicked) openDetail(i);
    }

    // Title (click → detail).
    if (dvui.button(@src(), title, .{}, .{
        .id_extra = i + 3000,
        .expand = .horizontal,
        .color_text = theme.colors.text_primary,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
    })) {
        openDetail(i);
    }

    // Rating · year.
    var meta_buf: [64]u8 = undefined;
    var mw = std.Io.Writer.fixed(&meta_buf);
    var wrote = false;
    if (v.rating > 0) {
        mw.print("{d:.0}", .{v.rating}) catch {};
        wrote = true;
    }
    if (v.released_len > 0) {
        if (wrote) mw.writeAll(" · ") catch {};
        // Year portion only (first 4 chars of "YYYY-MM-DD").
        mw.writeAll(v.released[0..@min(v.released_len, 4)]) catch {};
        wrote = true;
    }
    if (wrote) {
        _ = dvui.label(@src(), "{s}", .{meta_buf[0..mw.end]}, .{
            .id_extra = i + 4000,
            .color_text = theme.colors.text_tertiary,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
    }
}

fn renderResults() void {
    const count = @min(state.app.vndb.result_count, state.app.vndb.results.len);
    if (count == 0) {
        if (!state.app.vndb.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Search for a visual novel to get started", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        } else {
            _ = dvui.label(@src(), "Loading popular visual novels…", .{}, .{
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
        if (state.app.vndb.showing_popular) "Most popular visual novels (SFW)" else "Results",
    }, .{
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 2 },
    });

    // Responsive columns from the LIVE page width (one-frame lag; first paint
    // falls back to a sane default) — same shape as the TMDB/radio grid. No
    // virtualization: the grid is capped at results[]'s 180-card buffer (infinite
    // scroll fills it page by page via loadMore(), below).
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

    // Infinite scroll: fetch + append the next VNDB page as the user nears the
    // bottom. Bounded by more_available + loading_more so one scroll can't spawn
    // a burst; `underfilled` keeps paging when the current grid is shorter than
    // the viewport (e.g. right after the popular chart's first page lands on a
    // tall window). Mirrors services/drama.zig.
    if (more_available) {
        const loading = loading_more.load(.acquire);
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        const underfilled = max_y <= 0 and state.app.vndb.result_count > 0;
        if ((near_bottom or underfilled) and !loading and !state.app.vndb.is_loading.load(.acquire)) loadMore();
        if (loading or underfilled) {
            dvui.spinner(@src(), .{
                .color_text = theme.colors.accent,
                .min_size_content = theme.iconSize(.lg),
                .gravity_x = 0.5,
                .margin = dvui.Rect.all(12),
            });
            dvui.refresh(null, @src(), null); // wake until the worker's items land
        }
    }
}

// ── Detail overlay ──
fn renderDetail(idx: usize) void {
    const v = &state.app.vndb.results[idx];

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    // Back button.
    if (dvui.button(@src(), "‹ Back", .{}, .{
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
        .margin = .{ .x = 8, .y = 8, .w = 0, .h = 0 },
    })) {
        closeDetail();
        return;
    }

    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = dvui.Rect.all(12),
    });
    defer body.deinit();

    // Cover column.
    {
        var covcol = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = 160, .h = CARD_COVER_H },
            .max_size_content = .{ .w = 160, .h = CARD_COVER_H },
        });
        defer covcol.deinit();
        renderCover(idx, v);
    }

    // Info column.
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 14, .y = 0, .w = 0, .h = 0 },
        });
        defer info.deinit();

        var title_buf: [256]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(v.title[0..@min(v.title_len, v.title.len)], &title_buf)}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading,
            .expand = .horizontal,
        });

        // Meta line: rating · released · length.
        var meta_buf: [96]u8 = undefined;
        var mw = std.Io.Writer.fixed(&meta_buf);
        var wrote = false;
        if (v.rating > 0) {
            mw.print("Rating {d:.1}/100", .{v.rating}) catch {};
            wrote = true;
        }
        if (v.released_len > 0) {
            if (wrote) mw.writeAll(" · ") catch {};
            mw.writeAll(v.released[0..v.released_len]) catch {};
            wrote = true;
        }
        const llabel = pure.lengthLabel(v.length);
        if (llabel.len > 0) {
            if (wrote) mw.writeAll(" · ") catch {};
            mw.writeAll(llabel) catch {};
            wrote = true;
        }
        if (wrote) {
            _ = dvui.label(@src(), "{s}", .{meta_buf[0..mw.end]}, .{
                .color_text = theme.colors.text_secondary,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 4, .w = 0, .h = 6 },
            });
        }

        // Description.
        if (v.description_len > 0) {
            var desc_buf: [1024]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(v.description[0..@min(v.description_len, desc_buf.len)], &desc_buf)}, .{
                .color_text = theme.colors.text_secondary,
                .expand = .horizontal,
            });
        }

        // Browse-only handoff: search all sources for this title.
        if (dvui.button(@src(), "Search all sources", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .margin = .{ .x = 0, .y = 12, .w = 0, .h = 0 },
        })) {
            searchTorrents(idx);
        }
    }
}
