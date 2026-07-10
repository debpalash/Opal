const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const search = @import("search.zig");

// Sub-modules
const api = @import("tmdb_api.zig");
const store = @import("tmdb_store.zig");
const tmdb_pure = @import("tmdb_pure.zig");

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
                // These pixels come from core/poster.zig fetchAsync, which
                // allocates with the C allocator — freeing them with the
                // global DebugAllocator was the shutdown abort in appDeinit
                // (freeLarge assert, crash report 2026-07-03 11:41).
                std.heap.c_allocator.free(px);
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
    @import("../core/poster.zig").fetchAsync(url, &e.still_pixels, &e.still_w, &e.still_h, &e.still_fetching);
    // Only latch "attempted" once fetchAsync confirmed a worker actually
    // started (still_fetching flips true synchronously on success). The
    // shared poster daemon caps global concurrency (MAX_CONCURRENT in
    // core/poster.zig) and silently no-ops over the cap, leaving
    // still_fetching false — latching attempted unconditionally here (the
    // old bug) permanently stranded that episode with no thumbnail whenever
    // the cap was hit, which read as "sometimes it fetches, sometimes it
    // doesn't". Leaving attempted false lets the render-site retry on a
    // later frame once an in-flight slot frees.
    if (e.still_fetching) e.still_attempted = true;
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

    // Initial load (nothing to show yet) renders skeleton tiles inside the
    // gallery; a stale-refresh keeps the current results on screen — seamless.
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
    // Cleared every frame; renderSearchInline re-asserts it while the Find
    // box is focused. Without this, leaving Find mode with the box focused
    // left the flag stuck true and arrows dead.
    search_focused = false;

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
            if (state.app.tmdb.category == .trending and state.app.tmdb.genre_idx == 0) {
                toolbarDivider(903);
                renderTimeChip(20, .week, "Week");
                renderTimeChip(21, .day, "Today");
            }
            toolbarDivider(904);
            renderGenreDropdown();
            if (state.app.tmdb.genre_idx != 0) {
                toolbarDivider(905);
                renderSortChip(30, 0, "Popular");
                renderSortChip(31, 1, "Top rated");
                renderSortChip(32, 2, "Newest");
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

/// Genre selector — drives /discover?with_genres browsing (paginated like any
/// category). Selecting a genre overrides the category chips; picking a
/// category chip resets back to "All genres".
fn renderGenreDropdown() void {
    var sel: usize = state.app.tmdb.genre_idx;
    const active = sel != 0;
    if (dvui.dropdown(@src(), &tmdb_pure.GENRE_NAMES, .{ .choice = &sel }, .{}, .{
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_surface,
        .color_text = if (active) dvui.Color.white else theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        .gravity_y = 0.5,
    })) {
        if (sel != state.app.tmdb.genre_idx) {
            state.app.tmdb.genre_idx = sel;
            // /discover has no "multi" endpoint — with the filter on All, a
            // genre pick would silently return movies while "All" stayed
            // highlighted. Reflect reality in the UI instead.
            if (sel != 0 and state.app.tmdb.media_filter == .all) {
                state.app.tmdb.media_filter = .movie;
            }
            state.app.tmdb.page = 1;
            resetGalleryScroll();
            api.fetchCurrentView(false);
        }
    }
}

/// Discover ordering chip — only shown while a genre is active (the category
/// endpoints have fixed server-side ordering; /discover accepts sort_by).
fn renderSortChip(idx: usize, tag: u8, label: []const u8) void {
    const fg = if (state.app.tmdb.discover_sort == tag) theme.colors.accent else theme.colors.text_secondary;
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = idx + 5000,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = fg,
        .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
    })) {
        state.app.tmdb.discover_sort = tag;
        state.app.tmdb.page = 1;
        resetGalleryScroll();
        api.fetchCurrentView(false);
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
    const components = @import("../ui/components.zig");
    // Canonical compact toolbar input (shared with YouTube/Comics so every
    // Browse sub-toolbar has identical input height + padding).
    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.tmdb.search_buf }, .placeholder = "Search movies & TV…" }, .{
        .min_size_content = .{ .w = 240, .h = components.TOOLBAR_INPUT_H },
        .max_size_content = .{ .w = 240, .h = components.TOOLBAR_INPUT_H },
        .color_fill = theme.colors.bg_elevated,
        .color_border = theme.colors.border_subtle,
        .color_text = theme.colors.text_primary,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .gravity_y = 0.5,
    });
    const enter_pressed = te.enter_pressed;
    // Grid arrow-nav must yield to the text field while it's being edited.
    if (dvui.focusedWidgetId() == te.data().id) search_focused = true;
    te.deinit();
    if (components.toolbarGo(@src(), "Go") or enter_pressed) {
        state.app.tmdb.page = 1;
        resetGalleryScroll();
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
    if (view != state.app.tmdb.view) resetGalleryScroll();
    state.app.tmdb.view = view;
    if (view == .Trending and state.app.tmdb.results.items.len == 0) {
        api.fetchCurrentView(false);
    }
}

// ══════════════════════════════════════════════════════════
// Category Filters (chips reused by the combined toolbar)
// ══════════════════════════════════════════════════════════

fn renderCatChip(idx: usize, cat: state.TmdbCategory, label: []const u8) void {
    // While a genre is active, browsing goes through /discover and the
    // category is inert — don't highlight a chip that isn't driving results.
    const cat_active = state.app.tmdb.category == cat and state.app.tmdb.genre_idx == 0;
    const fg = if (cat_active) theme.colors.accent else theme.colors.text_secondary;
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = idx + 2000,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = fg,
        .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
    })) {
        state.app.tmdb.category = cat;
        state.app.tmdb.genre_idx = 0; // category chips exit genre-discover mode
        state.app.tmdb.page = 1;
        resetGalleryScroll();
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
        resetGalleryScroll();
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
        resetGalleryScroll();
        api.fetchCurrentView(false);
    }
}

// ══════════════════════════════════════════════════════════
// Gallery & Cards
// ══════════════════════════════════════════════════════════

/// Uniform card geometry — the virtualization spacer math depends on every
/// card having the same pitch, so these are THE constants: card height is
/// poster_h + CARD_FOOTER_H (min == max in renderPosterCard), each card has
/// CARD_VMARGIN above and below, and skeleton tiles use the same size.
const CARD_FOOTER_H: f32 = 64;
const CARD_VMARGIN: f32 = 3;

/// Gallery scroll position — module-level so it survives sub-tab/page-route
/// switches (dvui's per-id retained scroll state is dropped whenever the
/// widget skips a frame). Reset explicitly when the view/filters change.
var gallery_si: dvui.ScrollInfo = .{};

/// Keyboard focus: index of the arrow-key-focused card (null = keyboard nav
/// inactive; the first arrow press lights index 0). UI thread only.
var grid_focus: ?usize = null;

/// True while the Find-mode search box has focus — arrows/Enter belong to the
/// text field then, not the grid (set each frame in renderSearchInline).
var search_focused: bool = false;

/// Jump the gallery back to the top — call whenever the underlying result set
/// changes meaning (view/category/filter/search), not on pagination appends.
pub fn resetGalleryScroll() void {
    gallery_si.scrollToOffset(.vertical, 0);
    grid_focus = null;
}

/// Arrow/Enter/Escape handling for the poster grid (couch-style navigation).
/// Runs before layout so the focus ring and scroll-into-view land this frame.
fn processGridKeys(items: *std.ArrayListUnmanaged(state.TmdbItem), cols: usize, row_h: f32) void {
    const total = items.items.len;
    if (total == 0 or search_focused) return;

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .key) continue;
        const k = e.evt.key;
        if (k.action != .down and k.action != .repeat) continue;
        if (k.mod.control() or k.mod.command() or k.mod.alt()) continue;

        var dx: i32 = 0;
        var dy: i32 = 0;
        switch (k.code) {
            .left => dx = -1,
            .right => dx = 1,
            .up => dy = -1,
            .down => dy = 1,
            .enter => {
                if (grid_focus) |gf| {
                    if (gf < total) {
                        e.handled = true;
                        openOrSearch(&items.items[gf]);
                    }
                }
                continue;
            },
            .escape => {
                if (grid_focus != null) {
                    grid_focus = null;
                    e.handled = true;
                    dvui.refresh(null, @src(), null);
                }
                continue;
            },
            else => continue,
        }

        // First arrow press just lights the first card; then it moves.
        grid_focus = if (grid_focus) |cur| tmdb_pure.moveFocus(cur, total, cols, dx, dy) else 0;
        e.handled = true;

        // Keep the focused row on screen (virtualization renders it once the
        // viewport includes it).
        const row = grid_focus.? / @max(cols, 1);
        if (tmdb_pure.scrollOffsetForRow(row, row_h, gallery_si.viewport.y, gallery_si.viewport.h)) |off| {
            gallery_si.scrollToOffset(.vertical, off);
        }
        dvui.refresh(null, @src(), null);
    }
}

fn renderGallery(items: *std.ArrayListUnmanaged(state.TmdbItem), show_load_more: bool) void {
    if (items.items.len == 0 and !state.app.tmdb.is_loading.load(.acquire)) {
        renderEmptyOrFailed();
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &gallery_si }, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    // Responsive columns from the LIVE page width (one-frame lag; first paint
    // falls back to a sane default). Card width is user-cyclable (compact↔large).
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const card_target_w: f32 = state.app.tmdb.card_w;
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / card_target_w)));
    const card_w: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));
    const poster_h: f32 = card_w * 1.5;

    // Initial load with nothing to show yet → skeleton tiles instead of a
    // bare "Loading..." line (matches the Jellyfin grid's pattern).
    if (items.items.len == 0) {
        renderSkeletonRows(cols, card_w, poster_h);
        return;
    }

    // ── Virtualization ──
    // Cards are uniform (min==max height in renderPosterCard), so rows have a
    // fixed pitch: content + top/bottom card margins. Rows outside the
    // viewport (±2 overscan) collapse into two spacer boxes — a 1900-item
    // gallery lays out a handful of rows per frame instead of all of them.
    const row_h: f32 = poster_h + CARD_FOOTER_H + 2 * CARD_VMARGIN;
    const total_rows = (items.items.len + cols - 1) / cols;

    // Keyboard nav (arrows/Enter/Escape) — drop a stale focus index when the
    // list shrank (view switch, filter change).
    if (grid_focus) |gf| {
        if (gf >= items.items.len) grid_focus = null;
    }
    processGridKeys(items, cols, row_h);
    const win = tmdb_pure.visibleRows(total_rows, row_h, gallery_si.viewport.y, gallery_si.viewport.h, 2);

    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49998,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) },
        });
        sp.deinit();
    }

    var r: usize = win.first;
    while (r < win.last) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = r + 50000,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
        defer row.deinit();

        const base = r * cols;
        var col: usize = 0;
        while (col < cols and base + col < items.items.len) : (col += 1) {
            renderPosterCard(&items.items[base + col], base + col, card_w, poster_h);
        }
    }

    if (win.last < total_rows) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(total_rows - win.last)) },
        });
        sp.deinit();
    }

    // Poster prefetch: warm the next couple of rows below the window so fast
    // scrolling hits ready textures instead of film-icon placeholders. Same
    // guards as the render path; fetchAsync's global cap bounds the burst.
    {
        var pi: usize = win.last * cols;
        const prefetch_end = @min(items.items.len, (win.last + 2) * cols);
        while (pi < prefetch_end) : (pi += 1) {
            const it = &items.items[pi];
            if (!it.poster_failed and !it.poster_fetching and it.poster_pixels == null and
                it.poster_tex == null and it.poster_path_len > 0)
            {
                api.fetchPoster(it);
            }
        }
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

/// Empty gallery: for the fetching views (Hot/Find) this doubles as the
/// failed-to-load state with a Retry button — a network or parse failure used
/// to leave a bare "No items" with no way forward but restarting the app.
/// Uses the canonical components empty-state so it matches every other tab.
fn renderEmptyOrFailed() void {
    const components = @import("../ui/components.zig");
    const retryable = state.app.tmdb.view == .Trending or state.app.tmdb.view == .Search;
    if (retryable) {
        if (components.emptyStateCta(
            icons.tvg.lucide.film,
            "Nothing loaded",
            "The fetch may have failed or returned no results.",
            "Retry",
        )) {
            state.app.tmdb.page = 1;
            api.fetchCurrentView(false);
        }
    } else {
        components.emptyState(icons.tvg.lucide.film, "No items to display.", "");
    }
}

/// Skeleton tiles while the first page is in flight — same shape as the real
/// cards so the layout doesn't jump when results land (Jellyfin grid pattern).
fn renderSkeletonRows(cols: usize, card_w: f32, poster_h: f32) void {
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = r + 61000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            var tile = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = r * 32 + col + 61100,
                .min_size_content = .{ .w = card_w, .h = poster_h + CARD_FOOTER_H },
                .max_size_content = .{ .w = card_w, .h = poster_h + CARD_FOOTER_H },
                .margin = dvui.Rect.all(CARD_VMARGIN),
                .background = true,
                .color_fill = theme.colors.bg_elevated,
                .corner_radius = dvui.Rect.all(8),
            });
            tile.deinit();
        }
    }
    dvui.refresh(null, @src(), null); // keep waking until the worker's items land
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

    // Each poster card is a vertical box: poster image + title below.
    // min == max height → every card (and thus every row) has the same pitch,
    // which the gallery's virtualization spacer math depends on.
    // The arrow-key-focused card carries a 2px accent ring.
    const kb_focused = grid_focus != null and grid_focus.? == idx;
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx,
        .min_size_content = .{ .w = card_w, .h = poster_h + CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = poster_h + CARD_FOOTER_H },
        .margin = dvui.Rect.all(CARD_VMARGIN),
        .border = if (kb_focused) dvui.Rect.all(2) else dvui.Rect.all(0),
        .color_border = theme.colors.accent,
        .corner_radius = dvui.Rect.all(8),
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
    state.stashPendingPlay(
        title,
        item.poster_path[0..@min(item.poster_path_len, item.poster_path.len)],
        safeUtf8(item.overview[0..@min(item.overview_len, item.overview.len)]),
        false,
    );
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
/// Open the TV drill-down for a show by id — entry point for surfaces that
/// don't hold a TmdbItem (the Home "Coming up" rail). Same flow as a poster
/// click; poster_path may be empty (detail fetch fills what it needs).
pub fn openTvDetailById(id: i32, name: []const u8, poster_path: []const u8) void {
    var item = state.TmdbItem{ .id = id };
    const nlen = @min(name.len, item.title.len);
    @memcpy(item.title[0..nlen], name[0..nlen]);
    item.title_len = nlen;
    const plen = @min(poster_path.len, item.poster_path.len);
    @memcpy(item.poster_path[0..plen], poster_path[0..plen]);
    item.poster_path_len = plen;
    openTvDetail(&item);
}

fn openTvDetail(item: *state.TmdbItem) void {
    const t = &state.app.tmdb;
    t.tv_detail_open = true;
    t.tv_id = item.id;

    // renderTvDetail() is only ever drawn from the Browse/TMDB route (see
    // renderTmdbContent). A click from a Home rail (Trending tonight,
    // Continue Watching, Watchlist, Favorites) would otherwise just flip
    // this state invisibly while Home keeps rendering — so force the page
    // over, mirroring sectionHeader's "See all" handler.
    state.app.browse_source = .TMDB;
    state.app.router.navigate(.browse);

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

    // Keyless TVmaze air-date enrichment (fills TMDB's gaps): a "Next: SxEy ·
    // airs {date}" line + real per-episode dates. Async; the UI reads the cache.
    @import("tvmaze.zig").onTvDetailOpen(item.id, t.tv_name[0..t.tv_name_len]);
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
    if (bytes == 0) {
        if (tv_gen.load(.acquire) != my_gen) return; // superseded — drop silently
        var lb: [96]u8 = undefined;
        const lm = std.fmt.bufPrint(&lb, "TV episodes fetch FAILED (id={d} s{d}) — empty response", .{ tmdb_id, season_number }) catch "TV episodes fetch failed";
        logs.pushLog("error", "tmdb", lm, true);
        return;
    }
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

/// Play a specific episode of the selected season. Arms the deferred watch
/// commit (nothing is marked watched on click — see commitPendingWatch), then
/// smart-plays: resolve all sources in a worker, auto-play the top-ranked
/// CONFIDENT stream, and only fall back to the Search source-picker when no
/// candidate clears the confidence bar (resolver_rank.pickBest).
fn playTvEpisode(episode: i32) void {
    const t = &state.app.tmdb;
    const season = tvSelSeasonNumber();
    if (episode < 1 or season < 0) return;

    // Grab this episode's overview (if loaded) for the loading-screen stash.
    var i: usize = 0;
    var ep_overview: []const u8 = "";
    while (i < t.tv_episode_count) : (i += 1) {
        if (t.tv_episodes[i].episode_number == episode) {
            ep_overview = safeUtf8(t.tv_episodes[i].overview[0..@min(t.tv_episodes[i].overview_len, t.tv_episodes[i].overview.len)]);
            break;
        }
    }
    state.stashPendingPlay(
        safeUtf8(t.tv_name[0..@min(t.tv_name_len, t.tv_name.len)]),
        t.tv_poster_path[0..@min(t.tv_poster_path_len, t.tv_poster_path.len)],
        ep_overview,
        true,
    );

    // Arm the deferred watch commit. The player's time-pos stream commits it
    // (DB + Trakt + Continue) once real playback passes ~2 minutes — clicking
    // ▶ used to mark watched instantly, wrong now that a resolve (and possibly
    // a manual pick) sits between click and playback.
    {
        const pw = &state.app.pending_watch;
        pw.committed = false;
        pw.tmdb_id = t.tv_id;
        pw.season = season;
        pw.episode = episode;
        const nlen = @min(t.tv_name_len, pw.name.len);
        @memcpy(pw.name[0..nlen], t.tv_name[0..nlen]);
        pw.name_len = nlen;
        const plen = @min(t.tv_poster_path_len, pw.poster_path.len);
        @memcpy(pw.poster_path[0..plen], t.tv_poster_path[0..plen]);
        pw.poster_path_len = plen;
        pw.armed = true; // last — the event thread gates on this
    }

    // Build the search query through the PURE, TESTED helper (normalized
    // title + zero-padded sXXeYY): "X-Men '97" S2E2 → "x-men s02e02".
    // Two past bugs live here — the raw TMDB title ("X-Men '97 …") matching
    // nothing on torrent indexes, and Zig 0.16 printing `{d:0>2}` on i32 as
    // "+2" ("x-men S+2E+2"). Both are regression-tested in tmdb_pure.zig.
    var tv_name_buf: [128]u8 = undefined;
    const raw_name = safeUtf8Buf(t.tv_name[0..@min(t.tv_name_len, t.tv_name.len)], &tv_name_buf);
    var qbuf: [256]u8 = std.mem.zeroes([256]u8);
    const q = @import("tmdb_pure.zig").episodeQuery(raw_name, season, episode, &qbuf);

    // Smart play in a worker (copy the query BY VALUE per thread conventions).
    const S = struct {
        var busy: bool = false;
        var query: [256]u8 = undefined;
        var qlen: usize = 0;
        fn worker() void {
            defer @This().busy = false;
            smartPlayEpisode(@This().query[0..@This().qlen]);
        }
    };
    if (S.busy) return;
    S.busy = true;
    @memset(&S.query, 0);
    @memcpy(S.query[0..q.len], q);
    S.qlen = q.len;
    if (std.Thread.spawn(.{}, S.worker, .{})) |th| {
        th.detach();
    } else |_| {
        S.busy = false;
        // Spawn failed — degrade to the visible source picker.
        search.setUniversalQuery(q);
        state.navigateToTab(.Search);
    }
    state.showToast("Finding the best stream…");
}

/// Worker: resolve every source for `query`, auto-play the first CONFIDENT
/// candidate (rank order; dead magnets and weak title-matches never auto-play
/// — resolver_rank.pickBest, pure + tested), else land on the Search picker
/// with the results already populated.
fn smartPlayEpisode(query: []const u8) void {
    const rank = @import("resolver_rank.zig");
    resolver.resolve(query, "tv");

    var waited: usize = 0;
    while (resolver.isResolving() and waited < 150) : (waited += 1) {
        io.sleep(100 * std.time.ns_per_ms);
    }

    // Snapshot the chosen candidate under the lock (results are kept
    // insertion-sorted by score, so rank order == array order).
    var chosen_url: [2048]u8 = undefined;
    var chosen_url_len: usize = 0;
    var chosen_name: [256]u8 = undefined;
    var chosen_name_len: usize = 0;
    var chosen_source: resolver.SourceType = .torrent;
    {
        resolver.results_mutex.lock();
        defer resolver.results_mutex.unlock();
        var cands: [64]rank.PickCand = undefined;
        const n = @min(resolver.result_count, cands.len);
        for (0..n) |ci| {
            const it = &resolver.results[ci];
            const playable = (it.source == .stremio or it.source == .torrent) and it.url_len > 0;
            cands[ci] = .{
                .playable = playable,
                .needs_seeds = it.source == .torrent,
                .match_pct = it.match_pct,
                .seeds = it.seeds,
            };
        }
        if (rank.pickBest(cands[0..n])) |pi| {
            const it = &resolver.results[pi];
            chosen_url_len = it.url_len;
            @memcpy(chosen_url[0..it.url_len], it.url[0..it.url_len]);
            chosen_name_len = @min(it.name_len, chosen_name.len);
            @memcpy(chosen_name[0..chosen_name_len], it.name[0..chosen_name_len]);
            chosen_source = it.source;
        }
    }

    if (chosen_url_len > 0) {
        const url = chosen_url[0..chosen_url_len];
        if (std.mem.startsWith(u8, url, "magnet:") or chosen_source == .torrent) {
            search.loadTorrentToPlayer(url);
        } else {
            @import("browser.zig").loadContentDirect(url);
        }
        var tb: [160]u8 = undefined;
        var nb: [128]u8 = undefined;
        const nm = safeUtf8Buf(chosen_name[0..@min(chosen_name_len, 100)], &nb);
        state.showToast(std.fmt.bufPrint(&tb, "Playing: {s}", .{nm}) catch "Playing");
        logs.pushLog("info", "tmdb", "Smart-play picked a stream", false);
        return;
    }

    // No confident candidate — hand over to the visible source picker (the
    // resolve results are already in; no re-fetch happens).
    search.setUniversalQuery(query);
    state.navigateToTab(.Search);
    state.showToast("Pick a source — nothing cleared the auto-play bar");
}

/// Commit the armed pending-watch: DB watched flag + Trakt scrobble +
/// Continue-Watching upsert + the open TV detail's in-memory check. Called
/// from the player event thread once time-pos crosses the threshold (see
/// player.zig / tmdb_pure.tvWatchCommitDue). db is mutex-guarded and Trakt
/// spawns its own worker, so this is cheap enough for the event loop.
pub fn commitPendingWatch() void {
    const pw = &state.app.pending_watch;
    db.tvMarkWatched(pw.tmdb_id, @intCast(@max(0, pw.season)), @intCast(@max(1, pw.episode)), true);
    @import("trakt.zig").markWatchedEpisode(pw.tmdb_id, pw.season, pw.episode);
    db.tvUpsertContinue(pw.tmdb_id, pw.name[0..pw.name_len], pw.poster_path[0..pw.poster_path_len], @intCast(@max(0, pw.season)), @intCast(@max(1, pw.episode)));

    // Reflect in the TV detail if it's open on the same show + season.
    const t = &state.app.tmdb;
    if (t.tv_detail_open and t.tv_id == pw.tmdb_id and tvSelSeasonNumber() == pw.season) {
        var i: usize = 0;
        while (i < t.tv_episode_count) : (i += 1) {
            if (t.tv_episodes[i].episode_number == pw.episode) {
                if (i < t.tv_episode_watched.len) t.tv_episode_watched[i] = true;
                break;
            }
        }
    }
    logs.pushLog("info", "tmdb", "Episode marked watched (2min played)", false);
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

        // Back — lucide chevron + label (the old "←" glyph was missing from
        // the UI font and rendered as tofu).
        {
            var back = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .background = true,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 6, .y = 4, .w = 10, .h = 4 },
                .margin = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
                .gravity_y = 0.5,
            });
            defer back.deinit();
            var back_hover = false;
            const back_clicked = dvui.clicked(back.data(), .{ .hovered = &back_hover });
            if (back_hover) back.data().options.color_fill = theme.colors.bg_hover;
            back.drawBackground();
            dvui.icon(@src(), "tv-back", icons.tvg.lucide.@"chevron-left", .{}, .{
                .color_text = theme.colors.accent,
                .min_size_content = .{ .w = 15, .h = 15 },
                .gravity_y = 0.5,
            });
            _ = dvui.label(@src(), "Back", .{}, .{
                .color_text = theme.colors.accent,
                .gravity_y = 0.5,
            });
            if (back_clicked) {
                closeTvDetail();
                return;
            }
        }

        var tvn_buf: [128]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(t.tv_name[0..@min(t.tv_name_len, t.tv_name.len)], &tvn_buf)}, .{
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
        });
    }

    // ── TVmaze "Next episode" line (keyless; fills TMDB's gap). Only shown for
    //    currently-airing shows that have a scheduled next episode. ──
    {
        var next_buf: [96]u8 = undefined;
        if (@import("tvmaze.zig").nextLabel(t.tv_id, &next_buf)) |next_str| {
            _ = dvui.label(@src(), "{s}", .{next_str}, .{
                .color_text = theme.colors.accent,
                .padding = .{ .x = 14, .y = 4, .w = 14, .h = 2 },
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

    // Thin progress bar (watched fraction) — plain track + fill boxes. The
    // old dvui.slider here was DRAGGABLE and took the control-blue fill
    // instead of the theme accent (the stray blue bar in the season header).
    if (t.tv_episode_count > 0) {
        const watched = tvWatchedCount();
        const total = t.tv_episode_count;
        const frac: f32 = if (total > 0) @as(f32, @floatFromInt(watched)) / @as(f32, @floatFromInt(total)) else 0;
        var track = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .min_size_content = .{ .w = 0, .h = 3 },
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = 3 },
        });
        const track_w = track.data().contentRectScale().r.w;
        var fill = dvui.box(@src(), .{}, .{
            .background = true,
            .color_fill = theme.colors.accent,
            .min_size_content = .{ .w = frac * track_w, .h = 3 },
            .max_size_content = .{ .w = frac * track_w, .h = 3 },
        });
        fill.deinit();
        track.deinit();
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

        // Resume — lucide play + label (the "▶" glyph rendered as tofu).
        {
            var res = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .background = true,
                .color_fill = theme.colors.accent,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 12, .y = 5, .w = 14, .h = 5 },
                .margin = .{ .x = 0, .y = 0, .w = 12, .h = 0 },
                .gravity_y = 0.5,
            });
            defer res.deinit();
            var res_hover = false;
            const res_clicked = dvui.clicked(res.data(), .{ .hovered = &res_hover });
            res.drawBackground();
            dvui.icon(@src(), "tv-resume", icons.tvg.lucide.play, .{}, .{
                .color_text = theme.colors.text_on_accent,
                .min_size_content = .{ .w = 13, .h = 13 },
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
            });
            _ = dvui.label(@src(), "Resume", .{}, .{
                .color_text = theme.colors.text_on_accent,
                .gravity_y = 0.5,
            });
            if (res_clicked) playTvEpisode(next_ep);
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
        // Manual recourse for the rare case the fetch (now retried internally
        // in tmdbApiInto) still failed outright, e.g. a fully dead network —
        // check the Logs tab for the specific error.
        if (dvui.button(@src(), "Retry", .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .margin = .{ .x = 14, .y = 4, .w = 0, .h = 0 },
        })) {
            const season = tvSelSeasonNumber();
            if (season >= 0) fetchEpisodes(t.tv_id, season);
        }
        return;
    }

    const next_ep_num = tvNextUnwatched();
    const sel_season_num = tvSelSeasonNumber(); // for TVmaze air-date backfill

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

                // Play button — lucide icon in an accent pill.
                if (dvui.buttonIcon(@src(), "ep-play", icons.tvg.lucide.play, .{}, .{}, .{
                    .id_extra = ei + 43130,
                    .color_fill = theme.colors.accent,
                    .color_text = theme.colors.text_on_accent,
                    .corner_radius = dvui.Rect.all(theme.radius.pill),
                    .padding = .{ .x = 7, .y = 5, .w = 7, .h = 5 },
                    .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .gravity_y = 0.5,
                })) {
                    playTvEpisode(e.episode_number);
                }

                // Watched toggle (right-most) — lucide check/circle.
                if (dvui.buttonIcon(@src(), "ep-watched", if (is_watched) icons.tvg.lucide.@"circle-check-big" else icons.tvg.lucide.circle, .{}, .{}, .{
                    .id_extra = ei + 43140,
                    .color_fill = if (is_watched) theme.colors.success else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_text = if (is_watched) dvui.Color.white else theme.colors.text_secondary,
                    .corner_radius = dvui.Rect.all(theme.radius.pill),
                    .padding = .{ .x = 5, .y = 5, .w = 5, .h = 5 },
                    .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
                    .min_size_content = .{ .w = 14, .h = 14 },
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
                    // In-place validation only — ov_buf is already a stable
                    // copy. safeUtf8Buf(ov_buf, &ov_buf) was an @memcpy-
                    // arguments-alias PANIC for any overview > 120 bytes.
                    break :blk safeUtf8(ov_buf[0..120]);
                };
                _ = dvui.label(@src(), "{s}", .{ov_str}, .{
                    .id_extra = ei + 43200,
                    .color_text = dvui.Color{ .r = 140, .g = 145, .b = 160, .a = 255 },
                    .padding = .{ .x = 0, .y = 4, .w = 0, .h = 2 },
                });
            }

            // Meta line: air_date · runtime · [star icon] rating (the old
            // star text glyph was missing from the UI font — lucide instead).
            {
                var mrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = ei + 43300 });
                defer mrow.deinit();

                var meta: [48]u8 = undefined;
                // Prefer TMDB's air_date; fall back to keyless TVmaze where TMDB
                // has none (its common gap for recent/upcoming episodes).
                var tv_air_buf: [16]u8 = undefined;
                const air = if (e.air_date_len > 0)
                    e.air_date[0..@min(e.air_date_len, e.air_date.len)]
                else
                    (@import("tvmaze.zig").airdateFor(t.tv_id, sel_season_num, e.episode_number, &tv_air_buf) orelse "");
                const ms = if (e.runtime > 0 and air.len > 0)
                    std.fmt.bufPrint(&meta, "{s}  ·  {d}m", .{ air, e.runtime }) catch ""
                else if (air.len > 0)
                    air
                else if (e.runtime > 0)
                    std.fmt.bufPrint(&meta, "{d}m", .{e.runtime}) catch ""
                else
                    "";
                if (ms.len > 0) {
                    _ = dvui.label(@src(), "{s}", .{ms}, .{
                        .id_extra = ei + 43310,
                        .color_text = theme.colors.text_secondary,
                        .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                        .gravity_y = 0.5,
                    });
                }
                if (e.vote_average > 0) {
                    dvui.icon(@src(), "ep-rating", icons.tvg.lucide.star, .{}, .{
                        .id_extra = ei + 43320,
                        .color_text = theme.colors.warning,
                        .min_size_content = .{ .w = 11, .h = 11 },
                        .gravity_y = 0.5,
                        .margin = .{ .x = if (ms.len > 0) 8 else 0, .y = 0, .w = 3, .h = 0 },
                    });
                    _ = dvui.label(@src(), "{d:.1}", .{e.vote_average}, .{
                        .id_extra = ei + 43330,
                        .color_text = theme.colors.text_secondary,
                        .gravity_y = 0.5,
                    });
                }
            }
        }
    }
}
