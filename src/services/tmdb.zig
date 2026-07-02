const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const search = @import("search.zig");

// Sub-modules
const api = @import("tmdb_api.zig");
const store = @import("tmdb_store.zig");

const alloc = @import("tmdb_parse.zig").alloc;

// Re-export for external callers (main.zig, drawer.zig)
pub const saveLists = store.saveLists;
pub const loadLists = store.loadLists;

/// Re-export the shared valid-UTF-8 guard (see core/text.zig). Free text drawn
/// by dvui must pass through this or dvui's layout can panic on stray bytes.
pub const safeUtf8 = @import("../core/text.zig").safeUtf8;
pub const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

/// Free poster pixel buffers that a fetch worker produced but the renderer
/// never uploaded (off-screen cards, or fetched right before exit). Only
/// touches items whose worker has finished (`!poster_fetching`), so it can't
/// race a still-running worker. Call at shutdown before the lists deinit.
pub fn freeImageBuffers() void {
    const lists = [_]*std.ArrayListUnmanaged(state.TmdbItem){
        &state.app.tmdb.results,   &state.app.tmdb.favorites,
        &state.app.tmdb.watchlist, &state.app.tmdb.watching,
    };
    for (lists) |list| {
        for (list.items) |*it| {
            if (it.poster_fetching) continue; // worker may still write — leave it
            if (it.poster_pixels) |px| {
                alloc.free(px);
                it.poster_pixels = null;
            }
        }
    }
}

/// Free episode still images that are not currently being fetched.
/// Call from the UI thread before clearing tv_episode_count.
fn freeEpisodeStills() void {
    const t = &state.app.tmdb;
    const poster = @import("../core/poster.zig");
    for (0..t.tv_episode_count) |i| {
        var e = &t.tv_episodes[i];
        if (e.still_fetching) continue; // worker in-flight — leave it
        poster.deinitPoster(&e.still_pixels, &e.still_tex);
    }
}

/// Start an async fetch for episode still image (w300 landscape thumbnail).
fn fetchEpisodeStill(e: *state.TvEpisode) void {
    if (e.still_attempted or e.still_fetching or e.still_path_len == 0) return;
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://image.tmdb.org/t/p/w300{s}", .{
        e.still_path[0..@min(e.still_path_len, e.still_path.len)],
    }) catch return;
    e.still_attempted = true;
    @import("../core/poster.zig").fetchAsync(url, &e.still_pixels, &e.still_w, &e.still_h, &e.still_fetching);
}

// ══════════════════════════════════════════════════════════
// TMDB Content Renderer (called from drawer.zig)
// ══════════════════════════════════════════════════════════

pub fn renderTmdbContent() void {
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(8) });
    defer content.deinit();

    if (state.app.tmdb.api_key_len == 0) {
        renderNoApiKey();
        return;
    }

    // TV drill-down takes over the whole view (Netflix/Apple-TV+ style). The
    // normal Trending/Search/etc. gallery is suppressed until the user backs out.
    if (state.app.tmdb.tv_detail_open) {
        renderTvDetail();
        return;
    }

    if (!state.app.tmdb.loaded_once and !state.app.tmdb.is_loading.load(.acquire)) {
        state.app.tmdb.loaded_once = true;
        api.fetchCurrentView(false);
    } else if (state.app.tmdb.view == .Trending and !state.app.tmdb.is_loading.load(.acquire) and
        state.app.tmdb.results.items.len > 0 and state.app.tmdb.page == 1 and
        @import("browse_cache.zig").isStale(state.app.tmdb.last_fetch_s))
    {
        // Cache aged past the TTL — refresh in the background (the current
        // results keep showing until the new ones arrive).
        api.fetchCurrentView(false);
    }

    const list = activeList();

    // Single combined toolbar — mode chips, contextual filters (Hot) or the
    // search box (Find), item count, and card-size controls all on one row.
    renderToolbar(list.items.len);

    // Only show the loading line on an INITIAL load (nothing to show yet).
    // During a stale-refresh the current results stay on screen — seamless.
    if (state.app.tmdb.is_loading.load(.acquire) and activeList().items.len == 0) {
        _ = dvui.label(@src(), "Loading...", .{}, .{ .color_text = theme.colors.accent, .gravity_x = 0.5, .margin = dvui.Rect.all(12) });
    }

    const show_load_more = state.app.tmdb.view == .Trending or state.app.tmdb.view == .Search;
    renderGallery(list, show_load_more);
}

fn activeList() *std.ArrayListUnmanaged(state.TmdbItem) {
    return switch (state.app.tmdb.view) {
        .Trending, .Search => &state.app.tmdb.results,
        .Favorites => &state.app.tmdb.favorites,
        .Watchlist => &state.app.tmdb.watchlist,
        .Watching => &state.app.tmdb.watching,
    };
}

// ══════════════════════════════════════════════════════════
// Sub-Tabs
// ══════════════════════════════════════════════════════════

fn renderNoApiKey() void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .gravity_x = 0.5, .gravity_y = 0.4, .padding = dvui.Rect.all(24) });
    defer box.deinit();
    _ = dvui.label(@src(), "TMDB API Key Required", .{}, .{ .color_text = theme.colors.text_primary, .gravity_x = 0.5 });
    _ = dvui.label(@src(), "Add your free API key in Settings > General", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_x = 0.5 });
    _ = dvui.label(@src(), "Get one at: themoviedb.org/settings/api", .{}, .{ .color_text = theme.colors.accent, .gravity_x = 0.5 });
    if (dvui.button(@src(), "Open Settings", .{}, .{
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 12, .w = 0, .h = 0 },
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.bg_app,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 16, .y = 8, .w = 16, .h = 8 },
    })) {
        state.app.settings_open = true;
    }
}

/// One compact, full-width toolbar replacing the old 3–4 stacked filter rows.
/// Wraps gracefully on narrow widths via flexbox.
fn renderToolbar(count: usize) void {
    var bar = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
    });
    defer bar.deinit();

    // Mode chips (always).
    renderSubTab(0, .Trending, "Hot");
    renderSubTab(1, .Search, "Find");
    renderSubTab(2, .Favorites, "Favs");
    renderSubTab(3, .Watchlist, "List");
    renderSubTab(4, .Watching, "Now");

    // Contextual controls.
    switch (state.app.tmdb.view) {
        .Search => {
            toolbarDivider(900);
            renderSearchInline();
        },
        .Trending => {
            toolbarDivider(901);
            renderCatChip(0, .trending, "Trending");
            renderCatChip(1, .popular, "Popular");
            renderCatChip(2, .top_rated, "Top Rated");
            renderCatChip(3, .now_playing, "In Cinemas");
            renderCatChip(4, .upcoming, "Upcoming");
            toolbarDivider(902);
            renderFilterChip(10, .all, "All");
            renderFilterChip(11, .movie, "Movies");
            renderFilterChip(12, .tv, "TV");
            if (state.app.tmdb.category == .trending) {
                toolbarDivider(903);
                renderTimeChip(20, .week, "Week");
                renderTimeChip(21, .day, "Today");
            }
        },
        else => {},
    }

    // Item count + card-size controls.
    toolbarDivider(950);
    _ = dvui.label(@src(), "{d} items", .{count}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5 });
    const dim = dvui.Color{ .r = 120, .g = 120, .b = 148, .a = 200 };
    if (dvui.buttonIcon(@src(), "smaller", icons.tvg.lucide.minus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        state.app.tmdb.card_w = @max(110, state.app.tmdb.card_w - 40);
    }
    if (dvui.buttonIcon(@src(), "bigger", icons.tvg.lucide.plus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        state.app.tmdb.card_w = @min(320, state.app.tmdb.card_w + 40);
    }
}

/// A faint vertical separator between toolbar groups.
fn toolbarDivider(id: usize) void {
    var d = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .min_size_content = .{ .w = 1, .h = 18 },
        .background = true,
        .color_fill = theme.colors.border_subtle,
        .margin = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .gravity_y = 0.5,
    });
    d.deinit();
}

/// Compact inline search box (Find mode) — replaces the old full-width bar.
fn renderSearchInline() void {
    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.tmdb.search_buf }, .placeholder = "Search movies & TV…" }, .{
        .min_size_content = .{ .w = 240, .h = 28 },
        .color_fill = theme.colors.bg_elevated,
        .color_border = theme.colors.border_subtle,
        .color_text = theme.colors.text_primary,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_sm,
        .gravity_y = 0.5,
    });
    const enter_pressed = te.enter_pressed;
    te.deinit();
    if (dvui.button(@src(), "Go", .{}, .{
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.bg_app,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
        .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
    }) or enter_pressed) {
        state.app.tmdb.page = 1;
        api.fetchCurrentView(false);
    }
}

fn renderSubTab(idx: usize, view: state.TmdbView, label: []const u8) void {
    const active = state.app.tmdb.view == view;
    const bg = if (active) theme.colors.accent else theme.colors.bg_surface;
    const fg = if (active) dvui.Color.white else theme.colors.text_secondary;

    if (dvui.button(@src(), label, .{}, .{
        .id_extra = idx,
        .background = true,
        .color_fill = bg,
        .color_text = fg,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
        .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
    })) {
        switchView(view);
    }
}

fn switchView(view: state.TmdbView) void {
    state.app.tmdb.view = view;
    if (view == .Trending and state.app.tmdb.results.items.len == 0) {
        api.fetchCurrentView(false);
    }
}

// ══════════════════════════════════════════════════════════
// Category Filters (chips reused by the combined toolbar)
// ══════════════════════════════════════════════════════════

fn renderCatChip(idx: usize, cat: state.TmdbCategory, label: []const u8) void {
    const fg = if (state.app.tmdb.category == cat) theme.colors.accent else theme.colors.text_secondary;
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = idx + 2000,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = fg,
        .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
    })) {
        state.app.tmdb.category = cat;
        state.app.tmdb.page = 1;
        api.fetchCurrentView(false);
    }
}

fn renderFilterChip(idx: usize, filter: state.TmdbMediaFilter, label: []const u8) void {
    const active = state.app.tmdb.media_filter == filter;
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = idx + 3000,
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_surface,
        .color_text = if (active) dvui.Color.white else theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
    })) {
        state.app.tmdb.media_filter = filter;
        state.app.tmdb.page = 1;
        api.fetchCurrentView(false);
    }
}

fn renderTimeChip(idx: usize, tw: state.TmdbTimeWindow, label: []const u8) void {
    const fg = if (state.app.tmdb.time_window == tw) theme.colors.accent else theme.colors.text_secondary;
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = idx + 4000,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = fg,
        .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
    })) {
        state.app.tmdb.time_window = tw;
        state.app.tmdb.page = 1;
        api.fetchCurrentView(false);
    }
}

// ══════════════════════════════════════════════════════════
// Gallery & Cards
// ══════════════════════════════════════════════════════════

fn renderGallery(items: *std.ArrayListUnmanaged(state.TmdbItem), show_load_more: bool) void {
    if (items.items.len == 0 and !state.app.tmdb.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "No items to display.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    // Responsive columns from the LIVE page width (one-frame lag; first paint
    // falls back to a sane default). Card width is user-cyclable (compact↔large).
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const card_target_w: f32 = state.app.tmdb.card_w;
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / card_target_w)));
    const card_w: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));
    const poster_h: f32 = card_w * 1.5;

    var i: usize = 0;
    while (i < items.items.len) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 50000,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
        defer row.deinit();

        var col: usize = 0;
        while (col < cols and i + col < items.items.len) : (col += 1) {
            renderPosterCard(&items.items[i + col], i + col, card_w, poster_h);
        }
        i += cols;
    }

    // Infinite scroll: auto-fetch the next page when the user nears the bottom.
    // Bounded by is_loading, page<total_pages, AND a hard item cap below the
    // reserved buffer capacity (2048) so append() can never reallocate the
    // buffer out from under in-flight poster workers.
    const ITEM_CAP = 1900;
    if (show_load_more and state.app.tmdb.page < state.app.tmdb.total_pages and items.items.len < ITEM_CAP) {
        const loading = state.app.tmdb.is_loading.load(.acquire);
        const max_y = scroll.si.scrollMax(.vertical);
        // Only a real scroll-to-bottom (needs scrollable content); the
        // short-content case is handled by `underfilled` below with its own
        // stall guard, so keep the max_y > 0 precondition here.
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        // Also fetch when the content is SHORTER than the viewport (max_y == 0):
        // at dense scales the first page doesn't fill the screen, so there's
        // nothing to scroll and the old near-bottom-only trigger stuck at page 1
        // forever under a permanent "Loading more…". Keep pulling pages until
        // the viewport fills (each fetch gated by is_loading) or pages run out.
        // Stall guard: require prior pages to have delivered ~full results
        // (>=10/page) before auto-advancing, so a short/failed page halts the
        // loop instead of spamming fetches through all total_pages.
        const delivering = items.items.len >= state.app.tmdb.page * 10;
        const underfilled = max_y <= 0 and delivering;
        if ((near_bottom or underfilled) and !loading) {
            state.app.tmdb.page += 1;
            api.fetchCurrentView(true);
        }
        // Show the indicator ONLY while a fetch is actually in flight — a
        // resting "Loading more…" over empty space read as a stuck spinner.
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

/// Dimmed scrim + metadata shown over a poster while hovered.
fn renderHoverMeta(item: *state.TmdbItem, idx: usize) void {
    var ov = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx + 160,
        .expand = .both,
        .background = true,
        .color_fill = dvui.Color{ .r = 8, .g = 10, .b = 16, .a = 232 },
        .corner_radius = dvui.Rect.all(8),
        .padding = dvui.Rect.all(8),
    });
    defer ov.deinit();

    // Title (full, wraps).
    _ = dvui.label(@src(), "{s}", .{safeUtf8(item.title[0..@min(item.title_len, item.title.len)])}, .{
        .id_extra = idx + 161,
        .expand = .horizontal,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
    });

    // Rating · year · type line.
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = idx + 162, .expand = .horizontal, .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 } });
        defer line.deinit();
        const pct = @as(u8, @intFromFloat(std.math.clamp(item.rating * 10.0, 0.0, 100.0)));
        const sc = if (pct >= 70) theme.colors.success else if (pct >= 50) theme.colors.warning else theme.colors.danger;
        var pb: [8]u8 = undefined;
        if (std.fmt.bufPrint(&pb, "{d}%", .{pct})) |ps| {
            _ = dvui.label(@src(), "{s}", .{ps}, .{ .id_extra = idx + 163, .color_text = sc });
        } else |_| {}
        if (item.year_len > 0) {
            _ = dvui.label(@src(), "  {s}", .{item.year[0..item.year_len]}, .{ .id_extra = idx + 164, .color_text = theme.colors.text_secondary });
        }
    }

    // Overview (truncated; safeUtf8 trims any mid-codepoint cut).
    if (item.overview_len > 0) {
        var ov_buf: [320]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(item.overview[0..@min(item.overview_len, 320)], &ov_buf)}, .{
            .id_extra = idx + 165,
            .expand = .horizontal,
            .color_text = theme.colors.text_secondary,
        });
    }
}

/// Render a single poster card in the grid layout
pub fn renderPosterCard(item: *state.TmdbItem, idx: usize, card_w: f32, poster_h: f32) void {
    // Validate a STABLE COPY: a background fetch worker can rewrite this title in
    // results[] mid-frame, and dvui panics on invalid UTF-8 it reads after we
    // validated. safeUtf8Buf snapshots first → never a Utf8Invalid… crash.
    var title_buf: [128]u8 = undefined;
    const title = safeUtf8Buf(item.title[0..@min(item.title_len, item.title.len)], &title_buf);
    const hue: u32 = @as(u32, @bitCast(item.id)) *% 2654435761;
    const h1: u8 = @truncate(hue & 0xFF);
    const h2: u8 = @truncate((hue >> 8) & 0xFF);

    // Each poster card is a vertical box: poster image + title below
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx,
        .min_size_content = .{ .w = card_w, .h = 10 },
        .max_size_content = .{ .w = card_w, .h = poster_h + 64 },
        .margin = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
    });
    defer card.deinit();

    // Poster image area — single clickable button-widget that hosts the
    // image as its child. Prior implementation stacked a dvui.button +
    // a sibling box, producing two rectangles per card.
    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = idx + 100,
            .background = true,
            .color_fill = dvui.Color{ .r = 18 + h1 / 8, .g = 22 + h2 / 10, .b = 32 + h1 / 6, .a = 255 },
            .corner_radius = dvui.Rect.all(8),
            .min_size_content = .{ .w = card_w, .h = poster_h },
            .max_size_content = .{ .w = card_w, .h = poster_h },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();

        // Upload via the shared poster daemon's uploadIfReady: TMDB posters are
        // fetched through core/poster.zig fetchAsync, which allocates pixels with
        // the C allocator — freeing them here with the global `alloc` was an
        // invalid-free crash (allocator mismatch). uploadIfReady frees with the
        // matching allocator and carries the torn-publish (len==w*h*4) guard.
        _ = @import("../core/poster.zig").uploadIfReady(&item.poster_pixels, item.poster_w, item.poster_h, &item.poster_tex);

        // Stack the poster + (on hover) a meta overlay, both filling the button.
        {
            var stack = dvui.overlay(@src(), .{ .id_extra = idx + 140, .expand = .both });
            defer stack.deinit();

            if (item.poster_tex) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = idx + 150,
                    .expand = .both,
                    .corner_radius = dvui.Rect.all(8),
                });
            } else {
                if (item.poster_fetching) {
                    item.poster_attempted = true;
                } else if (item.poster_attempted and item.poster_pixels == null and item.poster_tex == null) {
                    // Worker ran but produced no pixels — latch failure so we
                    // stop re-spawning a fetch every frame.
                    item.poster_failed = true;
                } else if (!item.poster_failed and item.poster_pixels == null and item.poster_path_len > 0) {
                    api.fetchPoster(item);
                    if (item.poster_fetching) item.poster_attempted = true;
                }
                dvui.icon(@src(), "", icons.tvg.lucide.film, .{}, .{
                    .id_extra = idx + 150,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .color_text = dvui.Color{ .r = h1, .g = h2, .b = 180, .a = 60 },
                    .expand = .both,
                });
            }

            // Hover reveals richer metadata (overview / rating / year) over a
            // dimmed scrim, so cards stay compact by default.
            if (bw.hovered()) renderHoverMeta(item, idx);
        }

        const poster_clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (poster_clicked) openOrSearch(item);
    }

    // Rating badge + type label
    {
        var meta_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx + 300,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 2, .w = 2, .h = 0 },
        });
        defer meta_row.deinit();

        // Rating percentage
        const pct = @as(u8, @intFromFloat(std.math.clamp(item.rating * 10.0, 0.0, 100.0)));
        const sc = if (pct >= 70) theme.colors.success else if (pct >= 50) theme.colors.warning else theme.colors.danger;
        var pb: [8]u8 = undefined;
        if (std.fmt.bufPrintZ(&pb, "{d}%", .{pct})) |ps| {
            _ = dvui.label(@src(), "{s}", .{ps}, .{ .id_extra = idx + 310, .color_text = sc });
        } else |_| {}

        // Spacer
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        // Media type badge
        if (item.media_type_len > 0) {
            const mt = item.media_type[0..@min(item.media_type_len, item.media_type.len)];
            const mt_color = if (std.mem.eql(u8, mt, "tv"))
                dvui.Color{ .r = 147, .g = 130, .b = 255, .a = 255 }
            else
                dvui.Color{ .r = 56, .g = 189, .b = 248, .a = 255 };
            const mt_label = if (std.mem.eql(u8, mt, "tv")) "TV" else "Film";
            _ = dvui.label(@src(), "{s}", .{mt_label}, .{ .id_extra = idx + 320, .color_text = mt_color });
        }
    }

    // Title — click opens the TV episode detail (or searches, for movies).
    if (dvui.button(@src(), title, .{}, .{
        .id_extra = idx + 500,
        .expand = .horizontal,
        .color_text = theme.colors.text_primary,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
    })) {
        openOrSearch(item);
    }

    // Year
    if (item.year_len > 0) {
        _ = dvui.label(@src(), "{s}", .{item.year[0..item.year_len]}, .{
            .id_extra = idx + 520,
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
    }

    // Quick actions row
    {
        var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx + 400,
            .padding = .{ .x = 2, .y = 2, .w = 2, .h = 0 },
        });
        defer acts.deinit();
        const trans = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const dim = dvui.Color{ .r = 120, .g = 120, .b = 148, .a = 160 };

        // Fav
        {
            const fc = if (store.isInList(&state.app.tmdb.favorites, item.id)) dvui.Color{ .r = 255, .g = 215, .b = 0, .a = 255 } else dim;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.star, .{}, .{}, .{
                .id_extra = idx + 7000,
                .color_fill = trans,
                .color_text = fc,
                .padding = dvui.Rect.all(1),
                .min_size_content = theme.iconSize(.xs),
            })) {
                store.toggleList(&state.app.tmdb.favorites, item);
                store.saveLists();
            }
        }
        // Watchlist
        {
            const wc = if (store.isInList(&state.app.tmdb.watchlist, item.id)) theme.colors.accent else dim;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.bookmark, .{}, .{}, .{
                .id_extra = idx + 8000,
                .color_fill = trans,
                .color_text = wc,
                .padding = dvui.Rect.all(1),
                .min_size_content = theme.iconSize(.xs),
            })) {
                store.toggleList(&state.app.tmdb.watchlist, item);
                store.saveLists();
            }
        }
        // Search
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.search, .{}, .{}, .{
            .id_extra = idx + 10000,
            .color_fill = trans,
            .color_text = theme.colors.accent,
            .padding = dvui.Rect.all(1),
            .min_size_content = theme.iconSize(.xs),
        })) {
            sendToSearch(item);
        }
    }
}

fn renderCard(item: *state.TmdbItem, idx: usize) void {
    var title_buf: [128]u8 = undefined;
    const title = safeUtf8Buf(item.title[0..@min(item.title_len, item.title.len)], &title_buf);
    const hue: u32 = @as(u32, @bitCast(item.id)) *% 2654435761;
    const h1: u8 = @truncate(hue & 0xFF);
    const h2: u8 = @truncate((hue >> 8) & 0xFF);

    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = idx,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = 10, .y = 10, .w = 10, .h = 10 },
    });
    defer card.deinit();

    // Poster
    {
        var poster = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 100,
            .background = true,
            .color_fill = dvui.Color{ .r = 20 + h1 / 6, .g = 25 + h2 / 8, .b = 35 + h1 / 5, .a = 255 },
            .corner_radius = dvui.Rect.all(6),
            .min_size_content = .{ .w = 60, .h = 90 },
            .max_size_content = .{ .w = 60, .h = 90 },
        });
        defer poster.deinit();

        // Same allocator-matching upload as renderPosterCard (pixels come from
        // core/poster.zig fetchAsync = C allocator; freeing with global `alloc`
        // here was an invalid free).
        _ = @import("../core/poster.zig").uploadIfReady(&item.poster_pixels, item.poster_w, item.poster_h, &item.poster_tex);

        if (item.poster_tex) |*tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                .id_extra = idx + 150,
                .expand = .both,
                .corner_radius = dvui.Rect.all(6),
            });
        } else {
            if (!item.poster_fetching and item.poster_path_len > 0) api.fetchPoster(item);
            dvui.icon(@src(), "", icons.tvg.lucide.film, .{}, .{
                .id_extra = idx + 150,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = dvui.Color{ .r = h1, .g = h2, .b = 180, .a = 80 },
            });
        }
        _ = &poster;
    }

    // Info
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 200,
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
        });
        defer info.deinit();

        // Title (click to search torrents)
        if (dvui.button(@src(), title, .{}, .{
            .id_extra = idx + 500,
            .expand = .horizontal,
            .color_text = theme.colors.text_primary,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .padding = dvui.Rect.all(0),
        })) {
            sendToSearch(item);
        }

        // Meta row
        {
            var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = idx + 600,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            });
            defer meta.deinit();

            if (item.media_type_len > 0) {
                const mt = item.media_type[0..@min(item.media_type_len, item.media_type.len)];
                const mt_color = if (std.mem.eql(u8, mt, "tv"))
                    dvui.Color{ .r = 147, .g = 130, .b = 255, .a = 255 }
                else
                    dvui.Color{ .r = 56, .g = 189, .b = 248, .a = 255 };
                const mt_label = if (std.mem.eql(u8, mt, "tv")) "TV" else "Film";
                _ = dvui.label(@src(), "{s}", .{mt_label}, .{ .id_extra = idx + 605, .color_text = mt_color });
                _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 606, .color_text = theme.colors.text_secondary });
            }

            if (item.release_date_len > 0) {
                _ = dvui.label(@src(), "{s}", .{item.release_date[0..item.release_date_len]}, .{ .id_extra = idx + 610, .color_text = theme.colors.text_secondary });
            } else if (item.year_len > 0) {
                _ = dvui.label(@src(), "{s}", .{item.year[0..item.year_len]}, .{ .id_extra = idx + 611, .color_text = theme.colors.text_secondary });
            }

            _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 620, .color_text = theme.colors.text_secondary });

            const pct = @as(u8, @intFromFloat(std.math.clamp(item.rating * 10.0, 0.0, 100.0)));
            const sc = if (pct >= 70) theme.colors.success else if (pct >= 50) theme.colors.warning else theme.colors.danger;
            var pb: [8]u8 = undefined;
            if (std.fmt.bufPrintZ(&pb, "{d}%", .{pct})) |ps| {
                _ = dvui.label(@src(), "{s}", .{ps}, .{ .id_extra = idx + 310, .color_text = sc });
            } else |_| {}
        }

        // Genre (click to expand/collapse overview)
        if (item.genre_text_len > 0) {
            var genre_buf: [64]u8 = undefined;
            if (dvui.button(@src(), safeUtf8Buf(item.genre_text[0..item.genre_text_len], &genre_buf), .{}, .{
                .id_extra = idx + 650,
                .color_text = theme.colors.text_secondary,
                .expand = .horizontal,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .padding = dvui.Rect.all(0),
            })) {
                item.expanded = !item.expanded;
            }
        }

        // Expanded overview
        if (item.expanded and item.overview_len > 0) {
            var ov2_buf: [512]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(item.overview[0..@min(item.overview_len, ov2_buf.len)], &ov2_buf)}, .{
                .id_extra = idx + 700,
                .color_text = theme.colors.text_secondary,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 4, .w = 0, .h = 2 },
            });
        }

        // Actions
        {
            var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = idx + 400, .padding = .{ .x = 0, .y = 3, .w = 0, .h = 0 } });
            defer acts.deinit();
            const trans = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
            const dim = dvui.Color{ .r = 120, .g = 120, .b = 148, .a = 160 };

            // Fav
            {
                const fc = if (store.isInList(&state.app.tmdb.favorites, item.id)) dvui.Color{ .r = 255, .g = 215, .b = 0, .a = 255 } else dim;
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.star, .{}, .{}, .{
                    .id_extra = idx + 7000,
                    .color_fill = trans,
                    .color_text = fc,
                    .padding = dvui.Rect.all(1),
                })) {
                    store.toggleList(&state.app.tmdb.favorites, item);
                    store.saveLists();
                }
            }
            // Watchlist
            {
                const wc = if (store.isInList(&state.app.tmdb.watchlist, item.id)) theme.colors.accent else dim;
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.bookmark, .{}, .{}, .{
                    .id_extra = idx + 8000,
                    .color_fill = trans,
                    .color_text = wc,
                    .padding = dvui.Rect.all(1),
                })) {
                    store.toggleList(&state.app.tmdb.watchlist, item);
                    store.saveLists();
                }
            }
            // Watching
            {
                const wac = if (store.isInList(&state.app.tmdb.watching, item.id)) theme.colors.success else dim;
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.eye, .{}, .{}, .{
                    .id_extra = idx + 9000,
                    .color_fill = trans,
                    .color_text = wac,
                    .padding = dvui.Rect.all(1),
                })) {
                    store.toggleList(&state.app.tmdb.watching, item);
                    store.saveLists();
                }
            }
            // Search torrents
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.search, .{}, .{}, .{
                .id_extra = idx + 10000,
                .color_fill = trans,
                .color_text = theme.colors.accent,
                .padding = dvui.Rect.all(1),
            })) {
                sendToSearch(item);
            }
        }
    }

    // ── Right-click context menu ──
    {
        const ctext = dvui.context(@src(), .{ .rect = card.data().borderRectScale().r }, .{ .id_extra = idx + 11000 });
        defer ctext.deinit();

        if (ctext.activePoint()) |cp| {
            var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{
                .id_extra = idx + 11000,
                .color_fill = theme.colors.bg_surface,
                .color_border = theme.colors.border_subtle,
            });
            defer fw.deinit();

            if ((dvui.menuItemLabel(@src(), "Copy Title", .{}, .{ .expand = .horizontal, .id_extra = idx + 11100 })) != null) {
                dvui.clipboardTextSet(title);
                state.showToast("Title copied");
                fw.close();
            }
            if (item.overview_len > 0) {
                if ((dvui.menuItemLabel(@src(), "Copy Overview", .{}, .{ .expand = .horizontal, .id_extra = idx + 11200 })) != null) {
                    dvui.clipboardTextSet(item.overview[0..item.overview_len]);
                    state.showToast("Overview copied");
                    fw.close();
                }
            }
            if ((dvui.menuItemLabel(@src(), "Search Torrents", .{}, .{ .expand = .horizontal, .id_extra = idx + 11300 })) != null) {
                sendToSearch(item);
                fw.close();
            }
        }
    }
}

fn sendToSearch(item: *state.TmdbItem) void {
    var query_buf: [256]u8 = std.mem.zeroes([256]u8);
    const title = safeUtf8(item.title[0..@min(item.title_len, item.title.len)]);
    const year = item.year[0..@min(item.year_len, item.year.len)];
    const qlen = if (year.len > 0)
        std.fmt.bufPrint(&query_buf, "{s} {s}", .{ title, year }) catch return
    else
        std.fmt.bufPrint(&query_buf, "{s}", .{title}) catch return;
    state.navigateToTab(.Search);
    // Universal (all-source) search — populates resolver.results, which is what
    // the Search tab's universal view renders. triggerSearch() only fills the
    // torrent-only buffer, leaving the universal view empty.
    search.submitQuery(qlen);
    state.showToast("Searching all sources...");
}

// ══════════════════════════════════════════════════════════
// TV Seasons → Episodes drill-down (Netflix / Apple-TV+ style)
//
// A TV poster click opens openTvDetail(), which fetches /tv/{id} (seasons[]),
// auto-selects the first real season, and fetches /tv/{id}/season/{n}
// (episodes[]). renderTvDetail() draws the season chips + episode list. Episode
// play resolves a torrent for "{name} SxxEyy" and loads it into the player.
//
// All fetchers carry a monotonic generation (tv_gen). A worker only publishes
// if it is still the latest, so fast clicking / season-switching never shows
// stale episodes. Worker inputs are copied BY VALUE through the spawn tuple —
// never shared statics (avoids the races that bit the other fetchers).
// ══════════════════════════════════════════════════════════

const io = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const db = @import("../core/db.zig");
const resolver = @import("resolver.zig");

/// Monotonic generation. Each TV fetch captures the value it was spawned under;
/// it publishes only if still the latest, so superseded fetches self-discard.
var tv_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Open the Seasons → Episodes detail for a TV show. Resets all per-show state,
/// kicks the seasons fetch (which, on completion, auto-selects the default
/// season and fetches its episodes).
fn openTvDetail(item: *state.TmdbItem) void {
    const t = &state.app.tmdb;
    t.tv_detail_open = true;
    t.tv_id = item.id;

    const nlen = @min(item.title_len, t.tv_name.len);
    @memcpy(t.tv_name[0..nlen], item.title[0..nlen]);
    t.tv_name_len = nlen;

    const plen = @min(item.poster_path_len, t.tv_poster_path.len);
    @memcpy(t.tv_poster_path[0..plen], item.poster_path[0..plen]);
    t.tv_poster_path_len = plen;

    // Reset season/episode state for the fresh show.
    t.tv_season_count = 0;
    t.tv_sel_season = 0;
    t.tv_episode_count = 0;
    for (0..t.tv_episode_watched.len) |i| t.tv_episode_watched[i] = false;

    // New generation drops any in-flight seasons/episodes worker.
    _ = tv_gen.fetchAdd(1, .acq_rel);

    fetchSeasons(item.id);
}

/// Clear the TV detail view and return to the gallery. Bumps the generation so
/// any in-flight worker can't repopulate state after we leave.
fn closeTvDetail() void {
    const t = &state.app.tmdb;
    freeEpisodeStills();
    t.tv_detail_open = false;
    t.tv_season_count = 0;
    t.tv_episode_count = 0;
    t.tv_sel_season = 0;
    for (0..t.tv_episode_watched.len) |i| t.tv_episode_watched[i] = false;
    _ = tv_gen.fetchAdd(1, .acq_rel);
}

// ── Seasons fetch (/tv/{id}) ──

/// Click action for a TMDB card: open the TV season/episode detail for TV
/// shows, otherwise run a universal search. Used by BOTH the poster and the
/// title so clicking either part of a TV card shows its episodes.
fn openOrSearch(item: *state.TmdbItem) void {
    const mt = item.media_type[0..@min(item.media_type_len, item.media_type.len)];
    if (std.mem.eql(u8, mt, "tv")) openTvDetail(item) else sendToSearch(item);
}

fn fetchSeasons(tmdb_id: i32) void {
    if (state.app.tmdb.api_key_len == 0) return;
    state.app.tmdb.tv_seasons_loading = true;
    const my_gen = tv_gen.load(.acquire);

    if (std.Thread.spawn(.{}, fetchSeasonsThread, .{ tmdb_id, my_gen })) |th| {
        th.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.tmdb.tv_seasons_loading = false;
    }
}

fn fetchSeasonsThread(tmdb_id: i32, my_gen: u32) void {
    defer state.app.tmdb.tv_seasons_loading = false;

    var url_buf: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "/3/tv/{d}", .{tmdb_id}) catch return;

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const bytes = @import("tmdb_api.zig").tmdbApiInto(url, state.app.tmdb.api_key[0..state.app.tmdb.api_key_len], buf);
    if (bytes == 0) {
        var lb: [96]u8 = undefined;
        const lm = std.fmt.bufPrint(&lb, "TV seasons fetch FAILED (id={d}) — empty response", .{tmdb_id}) catch "TV seasons fetch failed";
        logs.pushLog("error", "tmdb", lm, true);
        return;
    }
    const body = buf[0..bytes];

    // Superseded by a newer open/close? Drop silently.
    if (tv_gen.load(.acquire) != my_gen) return;

    parseSeasons(body);

    {
        var lb: [96]u8 = undefined;
        const lm = std.fmt.bufPrint(&lb, "TV id={d}: {d} seasons parsed ({d}b)", .{ tmdb_id, state.app.tmdb.tv_season_count, bytes }) catch "TV seasons parsed";
        logs.pushLog("info", "tmdb", lm, false);
    }

    if (tv_gen.load(.acquire) != my_gen) return;

    // Auto-select the first real season (season_number >= 1); fall back to index
    // 0 (Specials) only if that's all there is.
    var sel: usize = 0;
    var i: usize = 0;
    while (i < state.app.tmdb.tv_season_count) : (i += 1) {
        if (state.app.tmdb.tv_seasons[i].season_number >= 1) {
            sel = i;
            break;
        }
    }
    state.app.tmdb.tv_sel_season = sel;

    if (state.app.tmdb.tv_season_count > 0) {
        const sn = state.app.tmdb.tv_seasons[sel].season_number;
        fetchEpisodes(tmdb_id, sn);
    }

    logs.pushLog("info", "tmdb", "TV seasons loaded", false);
}

/// Find the next complete top-level `{...}` object in `json` starting at `from`,
/// honoring string literals (so braces inside strings don't confuse the depth
/// counter). Returns the object slice and the index just past its closing `}`.
/// Null at end of input.
fn nextJsonObject(json: []const u8, from: usize) ?struct { obj: []const u8, end: usize } {
    var i = from;
    // Seek the opening brace.
    while (i < json.len and json[i] != '{') : (i += 1) {}
    if (i >= json.len) return null;
    const start = i;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return .{ .obj = json[start .. i + 1], .end = i + 1 };
            },
            else => {},
        }
    }
    return null;
}

/// Scan TMDB /tv/{id} JSON for the `seasons` array and fill tv_seasons (cap 40).
/// Iterates complete brace-matched objects so field order/association is correct.
fn parseSeasons(json: []const u8) void {
    const t = &state.app.tmdb;
    t.tv_season_count = 0;

    // Anchor on the seasons array, then bound to its matching ']' so we never
    // wander into trailing top-level objects.
    const arr_key = std.mem.indexOf(u8, json, "\"seasons\":") orelse return;
    var pos = arr_key + "\"seasons\":".len;
    while (pos < json.len and json[pos] != '[') : (pos += 1) {}
    if (pos >= json.len) return;
    const arr_end = arrayEnd(json, pos);
    const arr = json[pos..arr_end];

    var p: usize = 0;
    while (t.tv_season_count < t.tv_seasons.len) {
        const found = nextJsonObject(arr, p) orelse break;
        const obj = found.obj;
        p = found.end;

        var s = &t.tv_seasons[t.tv_season_count];
        s.* = .{};
        s.season_number = jsonInt(obj, "\"season_number\":");
        s.name_len = jsonStr(obj, "\"name\":\"", &s.name);
        s.episode_count = @intCast(@max(0, jsonInt(obj, "\"episode_count\":")));
        s.air_date_len = jsonStr(obj, "\"air_date\":\"", &s.air_date);
        s.poster_path_len = jsonStr(obj, "\"poster_path\":\"", &s.poster_path);

        t.tv_season_count += 1;
    }
}

/// Index just past the matching `]` for the `[` at `open` (string-aware).
fn arrayEnd(json: []const u8, open: usize) usize {
    var i = open;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return json.len;
}

// ── Episodes fetch (/tv/{id}/season/{n}) ──

fn fetchEpisodes(tmdb_id: i32, season_number: i32) void {
    if (state.app.tmdb.api_key_len == 0) return;
    freeEpisodeStills(); // free GPU textures before overwriting episode slots
    state.app.tmdb.tv_episodes_loading = true;
    state.app.tmdb.tv_episode_count = 0;
    const my_gen = tv_gen.load(.acquire);

    if (std.Thread.spawn(.{}, fetchEpisodesThread, .{ tmdb_id, season_number, my_gen })) |th| {
        th.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.tmdb.tv_episodes_loading = false;
    }
}

fn fetchEpisodesThread(tmdb_id: i32, season_number: i32, my_gen: u32) void {
    defer state.app.tmdb.tv_episodes_loading = false;

    var url_buf: [160]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "/3/tv/{d}/season/{d}", .{ tmdb_id, season_number }) catch return;

    const buf = alloc.alloc(u8, 256 * 1024) catch return;
    defer alloc.free(buf);
    const bytes = @import("tmdb_api.zig").tmdbApiInto(url, state.app.tmdb.api_key[0..state.app.tmdb.api_key_len], buf);
    if (bytes == 0) return;
    const body = buf[0..bytes];

    if (tv_gen.load(.acquire) != my_gen) return;

    parseEpisodes(body);

    if (tv_gen.load(.acquire) != my_gen) return;

    // Hydrate watched flags from the DB for this season's loaded range. Zero
    // first (tvLoadWatched only sets trues), then load.
    const count = state.app.tmdb.tv_episode_count;
    for (0..@min(count, state.app.tmdb.tv_episode_watched.len)) |i| state.app.tmdb.tv_episode_watched[i] = false;
    if (count > 0 and season_number >= 0) {
        db.tvLoadWatched(tmdb_id, @intCast(season_number), state.app.tmdb.tv_episode_watched[0..count]);
    }

    logs.pushLog("info", "tmdb", "TV episodes loaded", false);
}

/// Scan TMDB /tv/{id}/season/{n} JSON for the `episodes` array, filling
/// tv_episodes (cap 120).
fn parseEpisodes(json: []const u8) void {
    const t = &state.app.tmdb;
    t.tv_episode_count = 0;

    const arr_key = std.mem.indexOf(u8, json, "\"episodes\":") orelse return;
    var pos = arr_key + "\"episodes\":".len;
    while (pos < json.len and json[pos] != '[') : (pos += 1) {}
    if (pos >= json.len) return;
    const arr_end = arrayEnd(json, pos);
    const arr = json[pos..arr_end];

    var p: usize = 0;
    while (t.tv_episode_count < t.tv_episodes.len) {
        const found = nextJsonObject(arr, p) orelse break;
        const obj = found.obj;
        p = found.end;

        var e = &t.tv_episodes[t.tv_episode_count];
        e.* = .{};
        e.episode_number = jsonInt(obj, "\"episode_number\":");
        e.name_len = jsonStr(obj, "\"name\":\"", &e.name);
        e.overview_len = jsonStr(obj, "\"overview\":\"", &e.overview);
        e.air_date_len = jsonStr(obj, "\"air_date\":\"", &e.air_date);
        e.still_path_len = jsonStr(obj, "\"still_path\":\"", &e.still_path);
        e.vote_average = jsonFloat(obj, "\"vote_average\":");
        e.runtime = @intCast(@max(0, jsonInt(obj, "\"runtime\":")));

        t.tv_episode_count += 1;
    }
}

// ── curl + tiny JSON scan helpers (bounds-capped to the dst buffers) ──
// TV detail/season fetches now go through tmdb_api.tmdbApiInto (shared auth-by-
// key-shape + HTTPS→HTTP fallback + JSON validation + sticky-flag self-heal).

/// Parse the integer at the very start of `s` (used right after a key offset).
/// Handles an optional leading '-'.
fn jsonIntHere(s: []const u8) i32 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == ':')) : (i += 1) {}
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    const start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == start) return 0;
    const v = std.fmt.parseInt(i32, s[start..i], 10) catch return 0;
    return if (neg) -v else v;
}

/// Find `key` in `obj` and parse the integer that follows. `null` (no digits)
/// → 0. Returns 0 if the key is absent.
fn jsonInt(obj: []const u8, key: []const u8) i32 {
    const idx = std.mem.indexOf(u8, obj, key) orelse return 0;
    return jsonIntHere(obj[idx + key.len ..]);
}

/// Find `key` in `obj` and parse the float that follows (0 on absence/error).
fn jsonFloat(obj: []const u8, key: []const u8) f32 {
    const idx = std.mem.indexOf(u8, obj, key) orelse return 0;
    var p = idx + key.len;
    while (p < obj.len and (obj[p] == ' ' or obj[p] == ':')) : (p += 1) {}
    const start = p;
    while (p < obj.len and ((obj[p] >= '0' and obj[p] <= '9') or obj[p] == '.' or obj[p] == '-')) : (p += 1) {}
    if (p == start) return 0;
    return std.fmt.parseFloat(f32, obj[start..p]) catch 0;
}

/// Find `quoted_key` (which must include the opening `"..":"`) in `obj`, copy
/// the string value into `dst` (bounded), and return the byte length. Handles
/// a JSON `null` value (→ 0) and \" escapes inside the string. Drops the
/// backslash on recognized escapes; keeps everything else verbatim.
fn jsonStr(obj: []const u8, quoted_key: []const u8, dst: []u8) usize {
    const idx = std.mem.indexOf(u8, obj, quoted_key) orelse return 0;
    const start = idx + quoted_key.len;
    var i = start;
    var out: usize = 0;
    while (i < obj.len and out < dst.len) {
        const c = obj[i];
        if (c == '"') break;
        if (c == '\\' and i + 1 < obj.len) {
            const esc = obj[i + 1];
            const repl: u8 = switch (esc) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => 0,
            };
            if (repl != 0) {
                dst[out] = repl;
                out += 1;
                i += 2;
                continue;
            }
            // Unknown escape (incl. \uXXXX) — keep the backslash verbatim.
            dst[out] = '\\';
            out += 1;
            i += 1;
            continue;
        }
        dst[out] = c;
        out += 1;
        i += 1;
    }
    return out;
}

// ── Watched-tracking helpers ──

/// Number of watched episodes in the loaded range.
fn tvWatchedCount() usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < state.app.tmdb.tv_episode_count and i < state.app.tmdb.tv_episode_watched.len) : (i += 1) {
        if (state.app.tmdb.tv_episode_watched[i]) n += 1;
    }
    return n;
}

/// Lowest 1-based episode_number not yet watched (for Resume). Falls back to the
/// first loaded episode's number, or 1.
fn tvNextUnwatched() i32 {
    var i: usize = 0;
    while (i < state.app.tmdb.tv_episode_count and i < state.app.tmdb.tv_episode_watched.len) : (i += 1) {
        if (!state.app.tmdb.tv_episode_watched[i]) return state.app.tmdb.tv_episodes[i].episode_number;
    }
    if (state.app.tmdb.tv_episode_count > 0) return state.app.tmdb.tv_episodes[0].episode_number;
    return 1;
}

/// Season number for the currently-selected season (0 if none).
fn tvSelSeasonNumber() i32 {
    const t = &state.app.tmdb;
    if (t.tv_sel_season < t.tv_season_count) return t.tv_seasons[t.tv_sel_season].season_number;
    return 0;
}

/// Toggle episode `ep` (1-based episode_number) watched ↔ unwatched. `ep_idx` is
/// the array index of that episode. Flips the flag + persists to the DB.
fn tvToggleWatched(ep_idx: usize, ep: i32) void {
    if (ep_idx >= state.app.tmdb.tv_episode_watched.len) return;
    if (ep < 1) return;
    const flag = !state.app.tmdb.tv_episode_watched[ep_idx];
    state.app.tmdb.tv_episode_watched[ep_idx] = flag;
    const season = tvSelSeasonNumber();
    if (season >= 0) db.tvMarkWatched(state.app.tmdb.tv_id, @intCast(season), @intCast(ep), flag);
}

// ── Episode playback ──

/// Play a specific episode of the selected season. Marks it watched + upserts
/// the Continue entry, then resolves a torrent for "{name} SxxEyy" in a worker.
fn playTvEpisode(episode: i32) void {
    const t = &state.app.tmdb;
    const season = tvSelSeasonNumber();
    if (episode < 1 or season < 0) return;

    // Mark watched immediately (UI + DB) and update the loaded flag if visible.
    var i: usize = 0;
    while (i < t.tv_episode_count) : (i += 1) {
        if (t.tv_episodes[i].episode_number == episode) {
            if (i < t.tv_episode_watched.len) t.tv_episode_watched[i] = true;
            break;
        }
    }
    db.tvMarkWatched(t.tv_id, @intCast(season), @intCast(episode), true);
    @import("trakt.zig").markWatchedEpisode(t.tv_id, season, episode); // Trakt sync (no-op if not connected)
    db.tvUpsertContinue(t.tv_id, t.tv_name[0..t.tv_name_len], t.tv_poster_path[0..t.tv_poster_path_len], @intCast(season), @intCast(episode));

    // Build "{name} S01E02" (zero-padded) and copy BY VALUE into the worker.
    var qbuf: [256]u8 = std.mem.zeroes([256]u8);
    var tv_name_buf: [128]u8 = undefined;
    const name = safeUtf8Buf(t.tv_name[0..@min(t.tv_name_len, t.tv_name.len)], &tv_name_buf);
    const q = std.fmt.bufPrint(&qbuf, "{s} S{d:0>2}E{d:0>2}", .{ name, season, episode }) catch return;
    var qcopy: [256]u8 = std.mem.zeroes([256]u8);
    const qlen = @min(q.len, qcopy.len);
    @memcpy(qcopy[0..qlen], q[0..qlen]);

    state.app.tmdb.tv_stream_loading = true;
    if (std.Thread.spawn(.{}, playTvEpisodeThread, .{ qcopy, qlen })) |th| {
        th.detach(); // never joined — detach to avoid leaking the handle
    } else |_| {
        state.app.tmdb.tv_stream_loading = false;
    }
}

fn playTvEpisodeThread(qbuf: [256]u8, qlen: usize) void {
    defer state.app.tmdb.tv_stream_loading = false;

    const query = qbuf[0..qlen];
    logs.pushLog("info", "tmdb", "Resolving TV episode stream...", false);

    resolver.resolve(query, "tv");

    var waited: usize = 0;
    while (resolver.isResolving() and waited < 100) : (waited += 1) {
        io.sleep(100 * std.time.ns_per_ms);
    }

    resolver.results_mutex.lock();
    defer resolver.results_mutex.unlock();
    for (0..resolver.result_count) |i| {
        const item = resolver.results[i];
        const url = item.url[0..item.url_len];
        if (url.len == 0) continue;
        if (item.source == .stremio) {
            if (std.mem.startsWith(u8, url, "magnet:")) {
                // infoHash-converted magnet (Torrentio without debrid) — BitTorrent
                search.loadTorrentToPlayer(url);
            } else {
                // Direct HTTP stream (debrid, cached) — bypass routing, load into mpv
                @import("browser.zig").loadContentDirect(url);
            }
            logs.pushLog("info", "tmdb", "Playing TV episode via Stremio", false);
            return;
        }
        if (item.source == .torrent) {
            search.loadTorrentToPlayer(url);
            logs.pushLog("info", "tmdb", "Playing TV episode via torrent", false);
            return;
        }
    }
    logs.pushLog("error", "tmdb", "No streams found. Install a Stremio addon or torrent source in Plugins.", true);
}

// ══════════════════════════════════════════════════════════
// TV detail view UI
// ══════════════════════════════════════════════════════════

fn renderTvDetail() void {
    const t = &state.app.tmdb;
    const poster = @import("../core/poster.zig");

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer page.deinit();

    // ── Header: Back + show name ──
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        });
        defer hdr.deinit();

        if (dvui.button(@src(), "← Back", .{}, .{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
            .gravity_y = 0.5,
        })) {
            closeTvDetail();
            return;
        }

        var tvn_buf: [128]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(t.tv_name[0..@min(t.tv_name_len, t.tv_name.len)], &tvn_buf)}, .{
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
        });

        if (t.tv_stream_loading) {
            _ = dvui.label(@src(), "Finding stream…", .{}, .{
                .color_text = theme.colors.accent,
                .gravity_y = 0.5,
                .padding = .{ .x = 12, .y = 0, .w = 0, .h = 0 },
            });
        }
    }

    // ── Season selector row ──
    if (t.tv_seasons_loading and t.tv_season_count == 0) {
        _ = dvui.label(@src(), "Loading seasons…", .{}, .{
            .color_text = theme.colors.accent,
            .padding = .{ .x = 14, .y = 12, .w = 0, .h = 0 },
        });
        return;
    }

    {
        var sbar = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 4 },
        });
        defer sbar.deinit();

        var si: usize = 0;
        while (si < t.tv_season_count) : (si += 1) {
            const sn = t.tv_seasons[si].season_number;
            const active = si == t.tv_sel_season;
            var lbl_buf: [16]u8 = undefined;
            const lbl = if (sn == 0)
                "Specials"
            else
                (std.fmt.bufPrint(&lbl_buf, "S{d}", .{sn}) catch "S?");
            if (dvui.button(@src(), lbl, .{}, .{
                .id_extra = si + 30000,
                .background = true,
                .color_fill = if (active) theme.colors.accent else theme.colors.bg_surface,
                .color_text = if (active) dvui.Color.white else theme.colors.text_secondary,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
                .margin = .{ .x = 0, .y = 0, .w = 6, .h = 2 },
            })) {
                if (si != t.tv_sel_season) {
                    t.tv_sel_season = si;
                    _ = tv_gen.fetchAdd(1, .acq_rel);
                    fetchEpisodes(t.tv_id, sn);
                }
            }
        }
    }

    // ── Season info + watched progress bar ──
    if (t.tv_episode_count > 0 or (t.tv_sel_season < t.tv_season_count)) {
        var sinfo = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 0, .w = 12, .h = 6 },
        });
        defer sinfo.deinit();

        // Season name / episode count from the season struct
        if (t.tv_sel_season < t.tv_season_count) {
            const s = t.tv_seasons[t.tv_sel_season];
            var si_buf: [64]u8 = undefined;
            const year = if (s.air_date_len >= 4) s.air_date[0..4] else "";
            const ep_count = if (t.tv_episode_count > 0) t.tv_episode_count else @as(usize, s.episode_count);
            const si_str = if (year.len > 0)
                (std.fmt.bufPrint(&si_buf, "{d} episodes · {s}", .{ ep_count, year }) catch "")
            else
                (std.fmt.bufPrint(&si_buf, "{d} episodes", .{ep_count}) catch "");
            _ = dvui.label(@src(), "{s}", .{si_str}, .{
                .color_text = theme.colors.text_secondary,
                .gravity_y = 0.5,
            });
        }

        // Spacer + watched count (right-aligned)
        if (t.tv_episode_count > 0) {
            var spacer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            spacer.deinit();

            const watched = tvWatchedCount();
            const total = t.tv_episode_count;
            var wbuf: [32]u8 = undefined;
            const ws = std.fmt.bufPrint(&wbuf, "{d}/{d} watched", .{ watched, total }) catch "";
            _ = dvui.label(@src(), "{s}", .{ws}, .{
                .color_text = theme.colors.text_secondary,
                .gravity_y = 0.5,
            });
        }
    }

    // Thin progress bar (watched fraction)
    if (t.tv_episode_count > 0) {
        const watched = tvWatchedCount();
        const total = t.tv_episode_count;
        var frac: f32 = if (total > 0) @as(f32, @floatFromInt(watched)) / @as(f32, @floatFromInt(total)) else 0;
        _ = dvui.slider(@src(), .{ .fraction = &frac }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 10, .h = 4 },
            .color_fill = dvui.Color{ .r = 35, .g = 35, .b = 45, .a = 255 },
            .color_text = theme.colors.accent,
            .corner_radius = dvui.Rect.all(0),
        });
    }

    // ── Resume row ──
    if (t.tv_episode_count > 0) {
        const next_ep = tvNextUnwatched();
        var prow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            .background = true,
            .color_fill = dvui.Color{ .r = 16, .g = 18, .b = 26, .a = 255 },
            .color_border = theme.colors.border_subtle,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        });
        defer prow.deinit();

        if (dvui.button(@src(), "▶  Resume", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 14, .y = 5, .w = 14, .h = 5 },
            .margin = .{ .x = 0, .y = 0, .w = 12, .h = 0 },
            .gravity_y = 0.5,
        })) {
            playTvEpisode(next_ep);
        }

        var ep_lbl: [32]u8 = undefined;
        const ep_str = std.fmt.bufPrint(&ep_lbl, "Episode {d}", .{next_ep}) catch "";
        _ = dvui.label(@src(), "{s}", .{ep_str}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
        });
    }

    // ── Episode list ──
    if (t.tv_episodes_loading and t.tv_episode_count == 0) {
        _ = dvui.label(@src(), "Loading episodes…", .{}, .{
            .color_text = theme.colors.accent,
            .padding = .{ .x = 14, .y = 16, .w = 0, .h = 0 },
        });
        return;
    }

    if (t.tv_episode_count == 0) {
        _ = dvui.label(@src(), "No episodes available.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 14, .y = 16, .w = 0, .h = 0 },
        });
        return;
    }

    const next_ep_num = tvNextUnwatched();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer scroll.deinit();

    var ei: usize = 0;
    while (ei < t.tv_episode_count) : (ei += 1) {
        const e = &t.tv_episodes[ei];
        const is_watched = ei < t.tv_episode_watched.len and t.tv_episode_watched[ei];
        const is_next = e.episode_number == next_ep_num;

        // Upload still texture if pixel data arrived from the fetch worker.
        _ = poster.uploadIfReady(&e.still_pixels, e.still_w, e.still_h, &e.still_tex);

        const card_fill = if (is_watched)
            dvui.Color{ .r = 16, .g = 18, .b = 24, .a = 255 }
        else if (is_next)
            dvui.Color{ .r = 22, .g = 26, .b = 36, .a = 255 }
        else
            theme.colors.bg_surface;

        const border_color = if (is_next) theme.colors.accent else theme.colors.border_subtle;
        const border_rect: dvui.Rect = if (is_next)
            .{ .x = 2, .y = 0, .w = 0, .h = 1 }
        else
            .{ .x = 0, .y = 0, .w = 0, .h = 1 };

        var ecard = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = ei + 40000,
            .expand = .horizontal,
            .background = true,
            .color_fill = card_fill,
            .color_border = border_color,
            .border = border_rect,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        });
        defer ecard.deinit();

        // ── Left: episode still thumbnail ──
        {
            var still_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = ei + 42000,
                .background = true,
                .color_fill = dvui.Color{ .r = 12, .g = 14, .b = 20, .a = 255 },
                .min_size_content = .{ .w = 160, .h = 90 },
                .gravity_y = 0.5,
            });
            defer still_box.deinit();

            if (e.still_tex) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = ei + 42100,
                    .expand = .both,
                });
            } else {
                // Placeholder: episode number centered
                var ep_num_buf: [8]u8 = undefined;
                const ep_num_str = std.fmt.bufPrint(&ep_num_buf, "{d}", .{e.episode_number}) catch "";
                _ = dvui.label(@src(), "{s}", .{ep_num_str}, .{
                    .id_extra = ei + 42200,
                    .color_text = dvui.Color{ .r = 60, .g = 65, .b = 80, .a = 255 },
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .both,
                    .font = dvui.themeGet().font_heading,
                });
                // Start the fetch if available and not yet tried
                if (!e.still_attempted and e.still_path_len > 0) {
                    fetchEpisodeStill(e);
                }
            }
        }

        // ── Right: info column ──
        {
            var info = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = ei + 43000,
                .expand = .both,
                .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
            });
            defer info.deinit();

            // Title row: "E{n}" chip + episode name (expandable) + [▶] play button
            {
                var title_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = ei + 43100,
                    .expand = .horizontal,
                });
                defer title_row.deinit();

                // E{n} number chip
                {
                    var en_buf: [8]u8 = undefined;
                    const en_str = std.fmt.bufPrint(&en_buf, "E{d}", .{e.episode_number}) catch "";
                    _ = dvui.label(@src(), "{s}", .{en_str}, .{
                        .id_extra = ei + 43110,
                        .color_text = if (is_next) theme.colors.accent else theme.colors.text_secondary,
                        .gravity_y = 0.5,
                        .padding = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
                    });
                }

                // "Next" badge for the next unwatched episode
                if (is_next) {
                    _ = dvui.label(@src(), "Next", .{}, .{
                        .id_extra = ei + 43115,
                        .background = true,
                        .color_fill = theme.colors.accent,
                        .color_text = dvui.Color.white,
                        .corner_radius = theme.dims.rad_sm,
                        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
                        .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
                        .gravity_y = 0.5,
                    });
                }

                // Episode title (clickable → play)
                var ep_name_buf: [128]u8 = undefined;
                const ep_name = safeUtf8Buf(e.name[0..@min(e.name_len, e.name.len)], &ep_name_buf);
                if (dvui.button(@src(), ep_name, .{}, .{
                    .id_extra = ei + 43120,
                    .expand = .horizontal,
                    .color_text = if (is_watched) theme.colors.text_secondary else theme.colors.text_primary,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
                    .gravity_y = 0.5,
                })) {
                    playTvEpisode(e.episode_number);
                }

                // Play button
                if (dvui.button(@src(), "▶", .{}, .{
                    .id_extra = ei + 43130,
                    .background = true,
                    .color_fill = theme.colors.accent,
                    .color_text = dvui.Color.white,
                    .corner_radius = dvui.Rect.all(14),
                    .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
                    .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
                    .gravity_y = 0.5,
                })) {
                    playTvEpisode(e.episode_number);
                }

                // Watched toggle (right-most)
                const chk_label: []const u8 = if (is_watched) "\xe2\x9c\x93" else "\xe2\x97\x8b"; // ✓ / ○
                if (dvui.button(@src(), chk_label, .{}, .{
                    .id_extra = ei + 43140,
                    .background = true,
                    .color_fill = if (is_watched) theme.colors.success else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_text = if (is_watched) dvui.Color.white else theme.colors.text_secondary,
                    .corner_radius = theme.dims.rad_xl,
                    .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
                    .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
                    .gravity_y = 0.5,
                })) {
                    tvToggleWatched(ei, e.episode_number);
                }
            }

            // Overview snippet (truncated to 120 chars)
            if (e.overview_len > 0) {
                const ov_raw = e.overview[0..@min(e.overview_len, e.overview.len)];
                var ov_buf: [128]u8 = undefined;
                const ov_str = if (ov_raw.len <= 120)
                    safeUtf8Buf(ov_raw, &ov_buf)
                else blk: {
                    @memcpy(ov_buf[0..117], ov_raw[0..117]);
                    ov_buf[117] = '.';
                    ov_buf[118] = '.';
                    ov_buf[119] = '.';
                    break :blk safeUtf8Buf(ov_buf[0..120], &ov_buf);
                };
                _ = dvui.label(@src(), "{s}", .{ov_str}, .{
                    .id_extra = ei + 43200,
                    .color_text = dvui.Color{ .r = 140, .g = 145, .b = 160, .a = 255 },
                    .padding = .{ .x = 0, .y = 4, .w = 0, .h = 2 },
                });
            }

            // Meta line: air_date · runtime · ★ rating
            {
                var meta: [80]u8 = undefined;
                const air = e.air_date[0..@min(e.air_date_len, e.air_date.len)];
                const rating = e.vote_average;
                const ms = if (e.runtime > 0 and air.len > 0)
                    std.fmt.bufPrint(&meta, "{s}  ·  {d}m  ·  \xe2\x98\x85 {d:.1}", .{ air, e.runtime, rating }) catch ""
                else if (air.len > 0)
                    std.fmt.bufPrint(&meta, "{s}  ·  \xe2\x98\x85 {d:.1}", .{ air, rating }) catch ""
                else if (e.runtime > 0)
                    std.fmt.bufPrint(&meta, "{d}m  ·  \xe2\x98\x85 {d:.1}", .{ e.runtime, rating }) catch ""
                else
                    std.fmt.bufPrint(&meta, "\xe2\x98\x85 {d:.1}", .{rating}) catch "";
                _ = dvui.label(@src(), "{s}", .{ms}, .{
                    .id_extra = ei + 43300,
                    .color_text = theme.colors.text_secondary,
                    .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                });
            }
        }
    }
}
