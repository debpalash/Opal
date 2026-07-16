//! Live-action Asian drama browse module.
//!
//! Structural sibling of services/anime.zig: a card GRID → DETAIL → PLAY drill.
//! The catalog comes from TMDB (the stable, public API Opal already speaks in
//! tmdb*.zig); all parsing + origin classification lives in the tested
//! drama_pure.zig, so the shipped logic is the tested logic. Playback hands the
//! title to the universal resolver (services/resolver.zig), which routes a
//! torrent / stremio stream into mpv — the same handoff anime.playEpisode uses.
//!
//! SOURCES (documented):
//!   • TMDB /discover/tv + /search/tv  — STABLE. Discovery/metadata only.
//!   • Universal resolver              — BEST-EFFORT. Whatever indexers are live.
//! Dedicated drama stream scrapers (Kisskh / Asiaflix / GoPlay / Cineby) are NOT
//! compiled in (source neutrality); a scraper can be slotted behind the same seam.

const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const drama_pure = @import("drama_pure.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const icons = @import("icons");
const poster = @import("../core/poster.zig");
const logs = @import("../core/logs.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;
const sync = @import("../core/sync.zig");
const io_g = @import("../core/io_global.zig");

const alloc = @import("../core/alloc.zig").allocator;

const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

/// SWR cache TTL — the popularity charts move slowly; a 30-min freshness window
/// keeps revisits instant while still refreshing within a session.
const CATALOG_TTL_S: i64 = 30 * 60;

// ── Worker → UI publish seam ──
// TMDB texture ops MUST run on the UI thread, so the fetch worker never touches
// results[]/textures directly. It parses into `pending` under `pending_mutex`;
// the UI thread drains it in applyPending() (frees old textures there, safe).
var pending: [80]drama_pure.Item = undefined;
var pending_count: usize = 0;
var pending_ready: bool = false;
var pending_mutex: sync.Mutex = .{};

/// Monotonic fetch generation — bumped on each fetch so a slow in-flight worker's
/// results are dropped rather than shown if a newer fetch superseded it.
var fetch_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// ── Infinite-scroll pagination ──
// `current_page` is the highest TMDB discover page merged into results[];
// `more_available` clears when a page returns short or the fixed buffer fills.
// `loading_more` serializes append fetches so a single near-bottom scroll can't
// spawn a burst (mirrors comics/youtube). All read on the UI thread; the append
// worker runs under the same fetch_gen guard so a fresh search drops it.
var current_page: u32 = 1;
var more_available: bool = true;
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Set by the worker under pending_mutex: true → applyPending() APPENDS onto
/// results[] (load-more); false → replaces from index 0 (fresh fetch).
var pending_append: bool = false;
/// The TMDB page the staged `pending` items came from (UI thread reads it in
/// applyPending to advance `current_page`).
var pending_page: u32 = 1;

/// TMDB `/discover/tv` returns 20 rows per page; a short page means the end.
const TMDB_PAGE_SIZE: usize = 20;

// ══════════════════════════════════════════════════════════
// Fetch (TMDB discover/search → drama_pure.parseDiscover → pending)
// ══════════════════════════════════════════════════════════

pub fn loadCatalog() void {
    if (state.app.tmdb.api_key_len == 0) return; // reuses the TMDB key (see tmdb.zig)
    if (state.app.drama.is_loading.load(.acquire)) return;
    state.app.drama.is_loading.store(true, .release);
    state.app.drama.selected_idx = null;
    state.app.drama.last_fetch_s = @import("browse_cache.zig").now();
    state.app.drama.loaded_once = true;
    // Fresh landing feed resets pagination; applyPending() re-derives
    // more_available once page 1 lands.
    current_page = 1;
    more_available = true;
    const my_gen = fetch_gen.fetchAdd(1, .acq_rel) + 1;

    if (std.Thread.spawn(.{}, fetchWorker, .{my_gen})) |t| {
        t.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.drama.is_loading.store(false, .release);
    }
}

/// Infinite-scroll appender: fetch the NEXT TMDB discover page and merge it onto
/// the existing grid. Guarded by `loading_more` + the main `is_loading` so a
/// near-bottom scroll can't spawn a burst; runs under the current fetch_gen so a
/// fresh landing feed supersedes it. No-op once `more_available` clears (short
/// page or the fixed buffer filled). Mirrors comics.loadMoreResults.
pub fn loadMore() void {
    if (!more_available) return;
    if (state.app.tmdb.api_key_len == 0) return;
    if (state.app.drama.is_loading.load(.acquire)) return;
    if (loading_more.load(.acquire)) return;
    if (state.app.drama.result_count == 0) return;
    if (state.app.drama.result_count >= state.app.drama.results.len) {
        more_available = false;
        return;
    }
    if (loading_more.swap(true, .acq_rel)) return; // lost the race — another append in flight
    const my_gen = fetch_gen.load(.acquire); // stay within the current generation
    const next = current_page + 1;
    if (std.Thread.spawn(.{}, loadMoreWorker, .{ my_gen, next })) |t| {
        t.detach();
    } else |_| {
        loading_more.store(false, .release);
    }
}

fn fetchWorker(my_gen: u32) void {
    defer state.app.drama.is_loading.store(false, .release);
    fetchPage(my_gen, 1, false);
}

fn loadMoreWorker(my_gen: u32, page: u32) void {
    defer loading_more.store(false, .release);
    fetchPage(my_gen, page, true);
}

/// Fetch one TMDB discover page and stage it into `pending` for the UI thread.
/// `append` decides whether applyPending() merges onto the grid or replaces it.
fn fetchPage(my_gen: u32, page: u32, append: bool) void {
    const key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];

    var path_buf: [256]u8 = undefined;
    const path = drama_pure.discoverPath(page, &path_buf) orelse return;

    // Heap buffer — never a big stack buffer on a spawned thread (CLAUDE.md).
    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);

    const bytes = @import("tmdb_api.zig").tmdbApiInto(path, key, buf);

    // Parse into a local staging array (heap) before publishing.
    const items = alloc.alloc(drama_pure.Item, pending.len) catch return;
    defer alloc.free(items);
    const n = if (bytes > 0) drama_pure.parseDiscover(buf[0..bytes], items) else 0;

    if (fetch_gen.load(.acquire) != my_gen) return; // superseded by a newer fetch

    pending_mutex.lock();
    defer pending_mutex.unlock();
    if (fetch_gen.load(.acquire) != my_gen) return; // re-check under the lock
    @memcpy(pending[0..n], items[0..n]);
    pending_count = n;
    pending_page = page;
    pending_append = append;
    pending_ready = true;

    var lb: [64]u8 = undefined;
    logs.pushLog("info", "drama", std.fmt.bufPrint(&lb, "Loaded {d} titles (TMDB p{d})", .{ n, page }) catch "Loaded", false);
}

/// UI-THREAD ONLY — swap staged results into the live grid, freeing the old
/// cards' poster textures here (texture destroy must not run on a worker).
fn applyPending() void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    if (!pending_ready) return;
    pending_ready = false;

    const append = pending_append;
    const cap = state.app.drama.results.len;
    // Append merges from the current end; a fresh fetch retires old textures and
    // rewrites from index 0.
    const base = if (append) state.app.drama.result_count else 0;
    if (!append) {
        // Retire old poster textures/pixels (UI thread — safe).
        for (0..state.app.drama.result_count) |i| {
            const r = &state.app.drama.results[i];
            poster.deinitPoster(&r.poster_pixels, &r.poster_tex);
        }
    }

    var written: usize = 0;
    while (written < pending_count and base + written < cap) : (written += 1) {
        const src = &pending[written];
        var r = &state.app.drama.results[base + written];
        r.* = .{}; // reset all lazy-poster fields
        @memcpy(r.id[0..src.id_len], src.id[0..src.id_len]);
        r.id_len = src.id_len;
        @memcpy(r.name[0..src.name_len], src.name[0..src.name_len]);
        r.name_len = src.name_len;
        @memcpy(r.overview[0..src.overview_len], src.overview[0..src.overview_len]);
        r.overview_len = src.overview_len;
        @memcpy(r.poster_path[0..src.poster_path_len], src.poster_path[0..src.poster_path_len]);
        r.poster_path_len = src.poster_path_len;
        @memcpy(r.year[0..src.year_len], src.year[0..src.year_len]);
        r.year_len = src.year_len;
        r.vote = src.vote;
        r.origin = @intFromEnum(src.origin);
    }
    state.app.drama.result_count = base + written;

    // Pagination bookkeeping: a short page (< a full TMDB page) or a filled
    // buffer means there's nothing more to pull.
    current_page = pending_page;
    if (pending_count < TMDB_PAGE_SIZE or state.app.drama.result_count >= cap) {
        more_available = false;
    } else if (!append) {
        more_available = true;
    }
    dvui.refresh(null, @src(), null);
}

// ══════════════════════════════════════════════════════════
// Play — hand the title to the universal resolver → mpv
// ══════════════════════════════════════════════════════════

pub fn playSelected() void {
    const idx = state.app.drama.selected_idx orelse return;
    if (idx >= state.app.drama.result_count) return;
    if (state.app.drama.stream_loading.load(.acquire)) return;
    state.app.drama.stream_loading.store(true, .release);

    // The stream_loading atomic (checked+set above) serializes entry, so the
    // struct statics can't be overwritten by a concurrent spawn.
    const S = struct {
        var name_buf: [160]u8 = undefined;
        var name_len: usize = 0;

        fn worker() void {
            defer state.app.drama.stream_loading.store(false, .release);
            const name = @This().name_buf[0..@This().name_len];

            var q_buf: [160]u8 = undefined;
            const query = drama_pure.buildResolverQuery(name, &q_buf);
            if (query.len == 0) return;

            var qz: [192]u8 = undefined;
            const qzs = std.fmt.bufPrintZ(&qz, "{s}", .{query}) catch return;

            logs.pushLog("info", "drama", "Resolving stream via universal search…", false);
            const resolver = @import("resolver.zig");
            resolver.resolve(qzs, "tv");

            var waited: usize = 0;
            while (resolver.isResolving() and waited < 120) : (waited += 1) {
                io_g.sleep(100 * std.time.ns_per_ms);
            }

            resolver.results_mutex.lock();
            var chosen_url: [2048]u8 = undefined;
            var chosen_len: usize = 0;
            var chosen_src: resolver.SourceType = .torrent;
            for (0..resolver.result_count) |i| {
                const item = resolver.results[i];
                switch (item.source) {
                    .torrent, .stremio, .anime, .youtube, .local => {
                        const ul = @min(item.url_len, chosen_url.len);
                        @memcpy(chosen_url[0..ul], item.url[0..ul]);
                        chosen_len = ul;
                        chosen_src = item.source;
                        break;
                    },
                    else => {},
                }
            }
            resolver.results_mutex.unlock();

            if (chosen_len == 0) {
                logs.pushLog("error", "drama", "No streams found. Try universal search.", true);
                return;
            }

            const url = chosen_url[0..chosen_len];
            if (chosen_src == .torrent) {
                @import("search.zig").loadTorrentToPlayer(url);
            } else {
                playUrlDirect(url); // load_file + gotoPlayer (guarded)
            }
            logs.pushLog("info", "drama", "Playing selected title", false);
        }
    };

    const r = &state.app.drama.results[idx];
    const nl = @min(r.name_len, S.name_buf.len);
    @memcpy(S.name_buf[0..nl], r.name[0..nl]);
    S.name_len = nl;

    if (std.Thread.spawn(.{}, S.worker, .{})) |t| {
        t.detach();
    } else |_| {
        state.app.drama.stream_loading.store(false, .release);
    }
}

/// Load a direct stream/URL into the active player and reveal it. Creates a
/// player if none exists; guarded by `active_player_idx < players.items.len`
/// (CLAUDE.md). Used for resolver HTTP streams (mpv + ytdl handles the
/// extraction). UI-thread-safe entry too.
pub fn playUrlDirect(url: []const u8) void {
    if (url.len == 0) return;
    if (state.app.players.items.len == 0) {
        if (@import("../player/player.zig").MediaPlayer.init(alloc)) |np| {
            state.app.players.append(alloc, np) catch {
                np.deinit(alloc);
                return;
            };
            state.app.active_player_idx = 0;
        } else |_| return;
    }
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    p.provider = .mpv;
    var url_z: [2049]u8 = undefined;
    const len = @min(url.len, 2048);
    @memcpy(url_z[0..len], url[0..len]);
    url_z[len] = 0;
    p.load_file(@as([*c]const u8, @ptrCast(&url_z[0])));
    state.gotoPlayer();
}

// ══════════════════════════════════════════════════════════
// UI
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    applyPending(); // drain worker-staged results (UI thread)

    // Fetch once on first visit, plus SWR refresh when the cache goes stale.
    if (!state.app.drama.is_loading.load(.acquire)) {
        const stale = (@import("browse_cache.zig").now() - state.app.drama.last_fetch_s) >= CATALOG_TTL_S;
        if (!state.app.drama.loaded_once or stale) loadCatalog();
    }

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer page.deinit();

    if (state.app.tmdb.api_key_len == 0) {
        components.emptyState(icons.tvg.lucide.@"clapperboard", "TMDB key required", "Add a TMDB API key in Settings to browse Asian dramas.");
        return;
    }

    if (state.app.drama.selected_idx) |sidx| {
        renderDetail(sidx);
        return;
    }

    if (state.app.drama.is_loading.load(.acquire) and state.app.drama.result_count == 0) {
        components.emptyState(icons.tvg.lucide.@"clapperboard", "Loading…", "Fetching the catalog from TMDB.");
        return;
    }
    if (state.app.drama.result_count == 0) {
        components.emptyState(icons.tvg.lucide.@"clapperboard", "Nothing here yet", "Check back later.");
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    {
        var grid = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.md },
        });
        defer grid.deinit();

        for (0..state.app.drama.result_count) |i| renderCard(&state.app.drama.results[i], i);
    }

    // Infinite scroll: fetch + append the next TMDB page as the user nears the
    // bottom. Bounded by more_available + loading_more so one scroll can't spawn
    // a burst; `underfilled` keeps paging when the first page is shorter than the
    // viewport. Mirrors services/tmdb.zig.
    if (more_available) {
        const loading = loading_more.load(.acquire);
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        const underfilled = max_y <= 0 and state.app.drama.result_count > 0;
        if ((near_bottom or underfilled) and !loading and !state.app.drama.is_loading.load(.acquire)) {
            loadMore();
        }
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

const CARD_W: f32 = 150;

fn renderCard(item: *state.DramaResult, idx: usize) void {
    if (item.name_len == 0) return;
    var title_buf: [160]u8 = undefined;
    const title = safeUtf8Buf(item.name[0..item.name_len], &title_buf);

    const poster_h: f32 = CARD_W * 1.5;
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx + 1000,
        .min_size_content = .{ .w = CARD_W, .h = poster_h + 72 },
        .max_size_content = .{ .w = CARD_W, .h = poster_h + 72 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(6),
        .margin = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
    });
    defer card.deinit();

    // Poster (clickable → detail).
    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = idx + 100,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .min_size_content = .{ .w = CARD_W, .h = poster_h },
            .max_size_content = .{ .w = CARD_W, .h = poster_h },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();

        _ = poster.uploadIfReady(&item.poster_pixels, item.poster_w, item.poster_h, &item.poster_tex);
        if (item.poster_tex) |*tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                .id_extra = idx + 150,
                .expand = .both,
                .corner_radius = dvui.Rect.all(theme.radius.md),
            });
        } else {
            ensurePoster(item);
            dvui.icon(@src(), "", icons.tvg.lucide.@"clapperboard", .{}, .{
                .id_extra = idx + 150,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = theme.colors.text_tertiary,
                .expand = .both,
            });
        }
        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (clicked) state.app.drama.selected_idx = idx;
    }

    // Title (truncated) — click opens detail too.
    const show = title[0..@min(title.len, 40)];
    if (dvui.button(@src(), show, .{}, .{
        .id_extra = idx + 500,
        .expand = .horizontal,
        .color_text = theme.colors.text_primary,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .padding = .{ .x = 4, .y = 2, .w = 4, .h = 0 },
    })) {
        state.app.drama.selected_idx = idx;
    }

    // Meta row: origin badge + year.
    {
        var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = idx + 600, .expand = .horizontal, .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 } });
        defer meta.deinit();
        const o: drama_pure.Origin = @enumFromInt(@min(item.origin, 5));
        _ = dvui.label(@src(), "{s}", .{drama_pure.originLabel(o)}, .{ .id_extra = idx + 601, .color_text = theme.colors.accent });
        if (item.year_len > 0) {
            _ = dvui.label(@src(), "  {s}", .{item.year[0..item.year_len]}, .{ .id_extra = idx + 602, .color_text = theme.colors.text_tertiary });
        }
    }
}

fn ensurePoster(item: *state.DramaResult) void {
    if (item.poster_fetching) {
        item.poster_attempted = true;
        return;
    }
    if (item.poster_attempted and item.poster_pixels == null and item.poster_tex == null) {
        item.poster_failed = true;
        return;
    }
    if (!item.poster_failed and item.poster_pixels == null and item.poster_path_len > 0) {
        var url_buf: [160]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ drama_pure.POSTER_BASE, item.poster_path[0..item.poster_path_len] }) catch return;
        poster.fetchAsync(url, &item.poster_pixels, &item.poster_w, &item.poster_h, &item.poster_fetching);
        if (item.poster_fetching) item.poster_attempted = true;
    }
}

fn renderDetail(idx: usize) void {
    if (idx >= state.app.drama.result_count) {
        state.app.drama.selected_idx = null;
        return;
    }
    const item = &state.app.drama.results[idx];

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.md },
    });
    defer col.deinit();

    // Back.
    if (dvui.button(@src(), "← Back", .{}, .{
        .color_text = theme.colors.text_secondary,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
    })) {
        state.app.drama.selected_idx = null;
        return;
    }

    var title_buf: [160]u8 = undefined;
    const title = safeUtf8Buf(item.name[0..item.name_len], &title_buf);
    components.sectionHeader(title);

    {
        var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.sm } });
        defer meta.deinit();
        const o: drama_pure.Origin = @enumFromInt(@min(item.origin, 5));
        _ = dvui.label(@src(), "{s}", .{drama_pure.originLabel(o)}, .{ .color_text = theme.colors.accent });
        if (item.year_len > 0) _ = dvui.label(@src(), "  ·  {s}", .{item.year[0..item.year_len]}, .{ .color_text = theme.colors.text_tertiary });
        if (item.vote > 0) {
            var vb: [16]u8 = undefined;
            _ = dvui.label(@src(), "  ·  {s} / 10", .{std.fmt.bufPrint(&vb, "{d:.1}", .{item.vote}) catch ""}, .{ .color_text = theme.colors.text_tertiary });
        }
    }

    // Play button → universal resolver.
    {
        const loading = state.app.drama.stream_loading.load(.acquire);
        if (dvui.button(@src(), if (loading) "Finding stream…" else "▶ Play", .{}, .{
            .color_text = theme.colors.text_on_accent,
            .color_fill = theme.colors.accent,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
            .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.sm, .w = theme.spacing.lg, .h = theme.spacing.sm },
        })) {
            if (!loading) playSelected();
        }
    }

    // Overview.
    if (item.overview_len > 0) {
        var ov_buf: [512]u8 = undefined;
        _ = dvui.labelNoFmt(@src(), safeUtf8Buf(item.overview[0..item.overview_len], &ov_buf), .{}, .{
            .color_text = theme.colors.text_secondary,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.md },
        });
    }
}
