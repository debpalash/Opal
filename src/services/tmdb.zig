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

    if (!state.app.tmdb.loaded_once and !state.app.tmdb.is_loading) {
        state.app.tmdb.loaded_once = true;
        api.fetchCurrentView(false);
    } else if (state.app.tmdb.view == .Trending and !state.app.tmdb.is_loading and
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
    if (state.app.tmdb.is_loading and activeList().items.len == 0) {
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
    _ = dvui.label(@src(), "TMDB API Key Required", .{}, .{ .color_text = theme.colors.text_main, .gravity_x = 0.5 });
    _ = dvui.label(@src(), "Add your free API key in Settings > General", .{}, .{ .color_text = theme.colors.text_muted, .gravity_x = 0.5 });
    _ = dvui.label(@src(), "Get one at: themoviedb.org/settings/api", .{}, .{ .color_text = theme.colors.accent, .gravity_x = 0.5 });
    if (dvui.button(@src(), "Open Settings", .{}, .{
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 12, .w = 0, .h = 0 },
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.bg_header,
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
    _ = dvui.label(@src(), "{d} items", .{count}, .{ .color_text = theme.colors.text_muted, .gravity_y = 0.5 });
    const dim = dvui.Color{ .r = 120, .g = 120, .b = 148, .a = 200 };
    if (dvui.buttonIcon(@src(), "smaller", icons.tvg.lucide.minus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = .{ .w = 16, .h = 16 },
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        state.app.tmdb.card_w = @max(110, state.app.tmdb.card_w - 40);
    }
    if (dvui.buttonIcon(@src(), "bigger", icons.tvg.lucide.plus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = .{ .w = 16, .h = 16 },
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
        .color_fill = theme.colors.bg_input,
        .color_border = theme.colors.border_input,
        .color_text = theme.colors.text_main,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_sm,
        .gravity_y = 0.5,
    });
    const enter_pressed = te.enter_pressed;
    te.deinit();
    if (dvui.button(@src(), "Go", .{}, .{
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.bg_header,
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
    const bg = if (active) theme.colors.accent else theme.colors.bg_card;
    const fg = if (active) dvui.Color.white else theme.colors.text_muted;

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
    const fg = if (state.app.tmdb.category == cat) theme.colors.accent else theme.colors.text_muted;
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
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_card,
        .color_text = if (active) dvui.Color.white else theme.colors.text_muted,
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
    const fg = if (state.app.tmdb.time_window == tw) theme.colors.accent else theme.colors.text_muted;
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
    if (items.items.len == 0 and !state.app.tmdb.is_loading) {
        _ = dvui.label(@src(), "No items to display.", .{}, .{
            .color_text = theme.colors.text_muted,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_drawer });
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

    // Infinite scroll: auto-fetch the next page when the user nears the bottom
    // (one-frame lag on si is fine). Bounded by is_loading, page<total_pages,
    // AND a hard item cap below the reserved buffer capacity (2048) so append()
    // can never reallocate the buffer out from under in-flight poster workers.
    const ITEM_CAP = 1900;
    if (show_load_more and state.app.tmdb.page < state.app.tmdb.total_pages and items.items.len < ITEM_CAP) {
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        if (near_bottom and !state.app.tmdb.is_loading) {
            state.app.tmdb.page += 1;
            api.fetchCurrentView(true);
        }
        _ = dvui.label(@src(), "Loading more…", .{}, .{
            .color_text = theme.colors.text_muted,
            .gravity_x = 0.5,
            .padding = dvui.Rect.all(12),
        });
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
        .color_text = theme.colors.text_main,
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
            _ = dvui.label(@src(), "  {s}", .{item.year[0..item.year_len]}, .{ .id_extra = idx + 164, .color_text = theme.colors.text_muted });
        }
    }

    // Overview (truncated; safeUtf8 trims any mid-codepoint cut).
    if (item.overview_len > 0) {
        _ = dvui.label(@src(), "{s}", .{safeUtf8(item.overview[0..@min(item.overview_len, 320)])}, .{
            .id_extra = idx + 165,
            .expand = .horizontal,
            .color_text = theme.colors.text_secondary,
        });
    }
}

/// Render a single poster card in the grid layout
pub fn renderPosterCard(item: *state.TmdbItem, idx: usize, card_w: f32, poster_h: f32) void {
    const title = safeUtf8(item.title[0..@min(item.title_len, item.title.len)]);
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

        // Upload texture if pixels are ready
        if (item.poster_tex == null and item.poster_pixels != null) {
            const num_pixels = item.poster_w * item.poster_h;
            const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.poster_pixels.?.ptr)))[0..num_pixels];
            item.poster_tex = dvui.textureCreate(pixels_pma, item.poster_w, item.poster_h, .linear, .rgba_32) catch null;
            if (item.poster_tex != null) {
                alloc.free(item.poster_pixels.?);
                item.poster_pixels = null;
            }
        }

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
                if (!item.poster_fetching and item.poster_path_len > 0) api.fetchPoster(item);
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
        if (poster_clicked) sendToSearch(item);
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

    // Title — click to search torrents
    if (dvui.button(@src(), title, .{}, .{
        .id_extra = idx + 500,
        .expand = .horizontal,
        .color_text = theme.colors.text_main,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
    })) {
        sendToSearch(item);
    }

    // Year
    if (item.year_len > 0) {
        _ = dvui.label(@src(), "{s}", .{item.year[0..item.year_len]}, .{
            .id_extra = idx + 520,
            .color_text = theme.colors.text_muted,
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
                .min_size_content = .{ .w = 12, .h = 12 },
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
                .min_size_content = .{ .w = 12, .h = 12 },
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
            .min_size_content = .{ .w = 12, .h = 12 },
        })) {
            sendToSearch(item);
        }
    }
}

fn renderCard(item: *state.TmdbItem, idx: usize) void {
    const title = safeUtf8(item.title[0..@min(item.title_len, item.title.len)]);
    const hue: u32 = @as(u32, @bitCast(item.id)) *% 2654435761;
    const h1: u8 = @truncate(hue & 0xFF);
    const h2: u8 = @truncate((hue >> 8) & 0xFF);

    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = idx,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_card,
        .color_border = theme.colors.bg_header_border,
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

        if (item.poster_tex == null and item.poster_pixels != null) {
            const num_pixels = item.poster_w * item.poster_h;
            const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.poster_pixels.?.ptr)))[0..num_pixels];
            item.poster_tex = dvui.textureCreate(pixels_pma, item.poster_w, item.poster_h, .linear, .rgba_32) catch null;
            if (item.poster_tex != null) {
                alloc.free(item.poster_pixels.?);
                item.poster_pixels = null;
            }
        }

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
            .color_text = theme.colors.text_main,
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
                _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 606, .color_text = theme.colors.text_muted });
            }

            if (item.release_date_len > 0) {
                _ = dvui.label(@src(), "{s}", .{item.release_date[0..item.release_date_len]}, .{ .id_extra = idx + 610, .color_text = theme.colors.text_muted });
            } else if (item.year_len > 0) {
                _ = dvui.label(@src(), "{s}", .{item.year[0..item.year_len]}, .{ .id_extra = idx + 611, .color_text = theme.colors.text_muted });
            }

            _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 620, .color_text = theme.colors.text_muted });

            const pct = @as(u8, @intFromFloat(std.math.clamp(item.rating * 10.0, 0.0, 100.0)));
            const sc = if (pct >= 70) theme.colors.success else if (pct >= 50) theme.colors.warning else theme.colors.danger;
            var pb: [8]u8 = undefined;
            if (std.fmt.bufPrintZ(&pb, "{d}%", .{pct})) |ps| {
                _ = dvui.label(@src(), "{s}", .{ps}, .{ .id_extra = idx + 310, .color_text = sc });
            } else |_| {}
        }

        // Genre (click to expand/collapse overview)
        if (item.genre_text_len > 0) {
            if (dvui.button(@src(), safeUtf8(item.genre_text[0..item.genre_text_len]), .{}, .{
                .id_extra = idx + 650,
                .color_text = theme.colors.text_muted,
                .expand = .horizontal,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .padding = dvui.Rect.all(0),
            })) {
                item.expanded = !item.expanded;
            }
        }

        // Expanded overview
        if (item.expanded and item.overview_len > 0) {
            _ = dvui.label(@src(), "{s}", .{safeUtf8(item.overview[0..item.overview_len])}, .{
                .id_extra = idx + 700,
                .color_text = theme.colors.text_muted,
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
                .color_fill = theme.colors.bg_card,
                .color_border = theme.colors.border_drawer,
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
    search.triggerSearch(qlen);
    state.showToast("Searching torrents...");
}
