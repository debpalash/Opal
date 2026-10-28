//! Actual full-shell pixels with explicit offline fixtures and isolated HOME.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const router = @import("../core/router.zig");
const theme = @import("theme.zig");
const alloc = @import("../core/alloc.zig").allocator;
const search = @import("../services/search.zig");
const resolver = @import("../services/resolver.zig");
const capture = @import("native_capture.zig");
const Case = struct { name: []const u8, route: router.Route, tab: state.DrawerTab = .TMDB, settings: state.SettingsTab = .General, plugin: router.PluginTab = .sources, sidebar: ?bool = null, navigate_anime: bool = false, hover_sidebar: bool = false, scope: ?search.scope_model.Scope = null, remove_scope: bool = false, clear_query: bool = false, submit_query: bool = false, navigate_movies: bool = false, nav_api: bool = false, ranking_fixture: bool = false };
var current: Case = undefined;
var first_frame = true;
var preset: theme.ThemePreset = .midnight;
var fixture_rows: ?[]resolver.ResolvedItem = null;
const library = @import("../services/local_library.zig");
const local_ui = @import("local_library_ui.zig");
var local_items: [3]library.Item = undefined;
var local_roots: [1]library.Root = undefined;
var frames: usize = 0;
var captured: usize = 0;
fn captureCase(size: [2]u32) !void {
    const io = @import("../core/io_global.zig");
    if (io.getenv("OPAL_SHELL_CASE") orelse io.getenv("OPAL_NATIVE_CASE")) |filter| {
        var names = std.mem.splitScalar(u8, filter, ',');
        var selected = false;
        while (names.next()) |name| {
            if (name.len > 0 and std.mem.startsWith(u8, current.name, name)) selected = true;
        }
        if (!selected) return;
    }
    try capture.capture(size[0], size[1], current.name, setup, draw, cleanup);
    captured += 1;
}
fn field(buffer: []u8, len: *usize, value: []const u8) void {
    len.* = @min(buffer.len, value.len);
    @memcpy(buffer[0..len.*], value[0..len.*]);
}
fn setup() !void {
    @import("shell.zig").setSidebarFixtureForTest(current.sidebar);
    theme.active_preset = preset;
    state.app.page_shell_enabled = true;
    state.app.ui_scale = 1;
    state.app.router.current = current.route;
    search.enterSearchContext(.global, "");
    search.setSearchScope(current.scope orelse .all);
    state.app.browse_source = current.tab;
    if (current.nav_api) state.navigateToTabNow(current.tab);
    state.app.settings_tab = current.settings;
    state.app.plugin_tab = current.plugin;
    state.app.config_loaded.store(current.route == .settings, .release);
    state.app.content_cache_enabled = false;
    state.app.taste_enabled = false;

    first_frame = true;
    frames = 0;
    if (current.navigate_anime) @import("../services/anime.zig").setLoadingFixtureForTest(true);
    if (current.route == .watching) {
        for (&local_items, 0..) |*item, i| {
            item.* = .{ .id = @intCast(i + 1), .size = 2_400_000_000 };
            field(&item.title, &item.title_len, "A long offline library title — episode with multilingual subtitles and director commentary");
            field(&item.path, &item.path_len, "/offline-fixture/long-folder-name/representative-episode-with-a-long-filename.mkv");
            field(&item.kind, &item.kind_len, "video");
        }
        local_roots[0] = .{ .id = 1 };
        field(&local_roots[0].path, &local_roots[0].path_len, "/offline-fixture/representative-library-root-with-a-long-folder-name");
        local_ui.setFixtureForTest(&local_items, &local_roots, local_items[0]);
    }
    if (current.route == .search) {
        const rows = try alloc.alloc(resolver.ResolvedItem, 8);
        fixture_rows = rows;
        const names = [_][]const u8{ "Reacher", "千と千尋の神隠し — Spirited Away", "Offline anime fixture", "Offline comic fixture", "Offline book fixture", "Offline song fixture", "Offline podcast fixture", "Unmatched release fixture" };
        for (rows, 0..) |*row, i| {
            row.* = .{};
            row.source = switch (i) {
                0, 1 => .tmdb,
                2 => .anime,
                3 => .comics,
                4 => .novels,
                5 => .music,
                6 => .podcast,
                else => .torrent,
            };
            row.catalog_id = if (i < 2) @intCast(i + 1) else 0;
            field(&row.catalog_kind, &row.catalog_kind_len, if (i == 0) "tv" else "movie");
            field(&row.name, &row.name_len, names[i]);
            field(&row.summary, &row.summary_len, "Offline layout fixture. Covers and content are representative geometry; provider availability and playback are not asserted.");
            field(&row.url, &row.url_len, names[i]);
            field(&row.poster_url, &row.poster_url_len, "fixture://offline-cover");
            row.match_pct = 100;
            row.year = 2022;
        }
        if (current.ranking_fixture) {
            const ranked_names = [_][]const u8{ "Arsene Lupin", "Lupin III: The First", "Lupin", "Lupin's Tales", "Lupin", "LUPIN ZERO", "Belfort & Lupin", "Lupine" };
            const ranks = [_]u16{ 1, 2, 1, 2, 6, 3, 4, 5 };
            for (rows, 0..) |*row, i| {
                row.source = .tmdb;
                row.catalog_id = @intCast(i + 1);
                row.catalog_rank = ranks[i];
                field(&row.name, &row.name_len, ranked_names[i]);
                field(&row.catalog_kind, &row.catalog_kind_len, if (i == 0 or i == 1 or i == 4) "movie" else "tv");
                row.year = if (i == 2) 2021 else 2020;
                row.score = resolver.rankForTest(row.*, "lupin");
            }
        }
        const fixture_query = if (current.ranking_fixture) "lupin" else "Offline layout fixtures";
        resolver.clearResults();
        resolver.results_mutex.lock();
        @memcpy(resolver.results[0..rows.len], rows);
        resolver.result_count = rows.len;
        field(&resolver.resolver_query, &resolver.resolver_query_len, fixture_query);
        resolver.results_mutex.unlock();
        search.setUniversalQuery(fixture_query);
        search.setSearchScope(current.scope orelse .all);
    } else @memset(&state.app.magnet_buf, 0);
    if (current.submit_query) @memcpy(state.app.magnet_buf[0..4], "test");
}
fn texture(index: usize) !dvui.Texture {
    var rgba: [64 * 96 * 4]u8 = undefined;
    for (0..64 * 96) |p| {
        rgba[p * 4] = @intCast(35 + index * 15);
        rgba[p * 4 + 1] = @intCast(40 + p / 64);
        rgba[p * 4 + 2] = @intCast(100 + index * 12);
        rgba[p * 4 + 3] = 255;
    }
    return dvui.Texture.fromImageSource(.{ .pixels = .{ .rgba = &rgba, .width = 64, .height = 96, .interpolation = .linear } });
}
fn draw() !void {
    @import("components.zig").clearToggleBoundsForTest();
    if (current.hover_sidebar and (frames == 2 or frames == 5)) {
        const bounds = @import("shell.zig").sidebarBoundsForTest();
        const point = if (frames == 2)
            dvui.Point.Physical{ .x = bounds.sidebar.x + 20, .y = bounds.sidebar.y + 20 }
        else
            dvui.Point.Physical{ .x = bounds.content.x + bounds.content.w - 20, .y = bounds.content.y + 20 };
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = point });
    }
    if (current.navigate_movies and frames == 2) {
        const bounds = @import("shell.zig").sidebarMoviesBoundsForTest();
        try std.testing.expect(bounds.w > 0);
        const window = dvui.currentWindow();
        _ = try window.addEventMouseMotion(.{ .pt = bounds.center() });
        _ = try window.addEventMouseButton(.left, .press);
        _ = try window.addEventMouseButton(.left, .release);
    }
    if (current.submit_query and frames == 4) {
        const bounds = @import("shell.zig").queryBoundsForTest();
        try std.testing.expect(bounds.w > 0);
        const window = dvui.currentWindow();
        _ = try window.addEventMouseMotion(.{ .pt = bounds.center() });
        _ = try window.addEventMouseButton(.left, .press);
        _ = try window.addEventMouseButton(.left, .release);
        _ = try window.addEventKey(.{ .code = .enter, .action = .down, .mod = .none });
    }
    if (current.remove_scope and frames == 4) {
        const bounds = @import("shell.zig").scopeRemoveBoundsForTest();
        try std.testing.expect(bounds.w > 0 and bounds.h > 0);
        const window = dvui.currentWindow();
        _ = try window.addEventMouseMotion(.{ .pt = bounds.center() });
        _ = try window.addEventMouseButton(.left, .press);
        _ = try window.addEventMouseButton(.left, .release);
    }
    if (current.clear_query and frames == 4) search.clearShellSearch();
    if (current.navigate_anime and frames == 4) {
        const bounds = @import("shell.zig").sidebarAnimeBoundsForTest();
        try std.testing.expect(bounds.w > 0 and bounds.h > 0);
        const window = dvui.currentWindow();
        _ = try window.addEventMouseMotion(.{ .pt = bounds.center() });
        _ = try window.addEventMouseButton(.left, .press);
        _ = try window.addEventMouseButton(.left, .release);
    }
    if (current.navigate_anime and frames == 5) _ = try dvui.currentWindow().addEventKey(.{ .code = .tab, .action = .down, .mod = .none });

    if (first_frame and current.route == .browse and current.tab == .Anime) {
        var items: [8]state.AnimeResult = undefined;
        for (&items, 0..) |*item, i| {
            item.* = .{ .anilist_id = @intCast(i + 1), .year = 2025, .score = 8.8, .episodes = 24, .poster_attempted = true };
            field(&item.name, &item.name_len, "A long anime title — The Extraordinary Adventure Beyond the Horizon");
            field(&item.atype, &item.atype_len, "TV");
            item.poster_tex = try texture(i);
        }
        @import("../services/anime.zig").setNativeFixtureForTest(&items);
    }
    if (first_frame and current.route == .browse and (current.tab == .Comics or current.tab == .Novels)) {
        var textures: [8]dvui.Texture = undefined;
        for (&textures, 0..) |*art, i| art.* = try texture(i);
        if (current.tab == .Comics) @import("../services/comics.zig").setNativeFixtureForTest(&textures) else @import("../services/novels.zig").setNativeFixtureForTest(&textures);
    }
    if (first_frame and (current.route == .home or (current.route == .browse and current.tab == .TMDB))) {
        state.app.tmdb.loaded_once = true;
        state.app.tmdb.view = .Search;
        for (0..8) |i| {
            var item: state.TmdbItem = .{ .id = @intCast(i + 1), .rating = 8.7, .poster_attempted = true };
            field(&item.title, &item.title_len, "A long cinema title — The Extraordinary Journey Beyond the Horizon");
            field(&item.year, &item.year_len, "2025");
            field(&item.media_type, &item.media_type_len, "movie");
            field(&item.overview, &item.overview_len, "Offline visual fixture for title clipping, poster proportions and card actions.");
            item.poster_tex = try texture(i);
            if (current.route == .home) try state.app.tmdb.watchlist.append(alloc, item) else try state.app.tmdb.results.append(alloc, item);
        }
    }
    if (first_frame and current.route == .browse and current.tab == .YouTube) {
        state.app.yt.loaded_once = true;
        state.app.yt.last_fetch_s = 9_999_999_999;
        for (0..8) |i| {
            var item: state.YtItem = .{ .duration = 3661, .views = 1234567, .thumb_attempted = true };
            field(&item.title, &item.title_len, if (i == 1) "世界の音楽と映画 — A journey through cinema and music" else "A long video title — Exploring the world through cinema and music");
            field(&item.uploader, &item.uploader_len, "Offline fixture channel");
            // A completed decode burst exercises the per-frame GPU upload cap.
            const pixels = try alloc.alloc(u8, 160 * 90 * 4);
            for (0..160 * 90) |pixel| {
                pixels[pixel * 4] = @intCast(35 + i * 15);
                pixels[pixel * 4 + 1] = @intCast(40 + pixel / 160);
                pixels[pixel * 4 + 2] = @intCast(100 + i * 12);
                pixels[pixel * 4 + 3] = 255;
            }
            item.thumb_pixels = pixels;
            item.thumb_w = 160;
            item.thumb_h = 90;
            try state.app.yt.results.append(alloc, item);
        }
    }
    if (first_frame and current.route == .search) {
        // Only explicit fixtures receive test textures; no artwork worker runs.
        const rows = fixture_rows orelse return error.MissingFixture;
        // Fixture identities are copied by the production view cache; expose
        // only its test snapshot here rather than a different renderer.
        for (rows, 0..) |*row, i| {
            const art = try texture(i);
            search.setGalleryTextureForTest(resolver.content.identity(row.*), row.poster_url[0..row.poster_url_len], art, art.width, art.height);
        }
    }
    first_frame = false;
    var thumbnails_before: usize = 0;
    for (state.app.yt.results.items) |item| {
        if (item.thumb_tex != null) thumbnails_before += 1;
    }
    const provider_mask = resolver.source_mask.load(.acquire);
    try @import("shell.zig").render();
    try std.testing.expectEqual(provider_mask, resolver.source_mask.load(.acquire));
    if (current.submit_query and frames >= 5) {
        const expected = search.scope_model.forTab(@tagName(current.tab));
        try std.testing.expectEqual(router.Route.search, state.app.router.current);
        try std.testing.expectEqual(expected, search.currentScope());
        try std.testing.expectEqual(expected, resolver.requestScopeForTest());
        try std.testing.expect(@import("shell.zig").browseSourceActive(current.tab));
        try std.testing.expect(!@import("shell.zig").allContentActive());
    }
    if (current.ranking_fixture and frames >= 5) try std.testing.expectEqual(@as(i32, 3), search.firstRankedCatalogForTest());
    if (current.scope) |scope| {
        if (frames >= 5) {
            try std.testing.expectEqual(if (current.remove_scope) search.scope_model.Scope.all else scope, search.currentScope());
            if (current.remove_scope) try std.testing.expect(@import("shell.zig").allContentActive());
            if (current.remove_scope) try std.testing.expectEqualStrings("Offline layout fixtures", std.mem.sliceTo(&state.app.magnet_buf, 0));
            if (current.clear_query) try std.testing.expectEqual(@as(usize, 0), std.mem.sliceTo(&state.app.magnet_buf, 0).len);
            if (!current.remove_scope and !current.clear_query and !current.ranking_fixture) try std.testing.expectEqual(@as(usize, 1), search.visibleScopedRowsForTest());
        }
    }
    if (current.route == .browse and current.tab == .YouTube) {
        var thumbnails_after: usize = 0;
        for (state.app.yt.results.items) |item| {
            if (item.thumb_tex != null) thumbnails_after += 1;
        }
        try std.testing.expect(thumbnails_after >= thumbnails_before);
        try std.testing.expect(thumbnails_after - thumbnails_before <= 2);
        if (frames >= 4) try std.testing.expect(thumbnails_after > 0);
    }
    frames += 1;
    if (current.navigate_anime and frames >= 5) {
        try std.testing.expectEqual(router.Route.browse, state.app.router.current);
        try std.testing.expectEqual(state.DrawerTab.Anime, state.app.browse_source);
        try std.testing.expect(dvui.focusedWidgetId() != null);
    }
    if (frames >= 4 and current.route != .player) {
        const bounds = @import("shell.zig").sidebarBoundsForTest();
        const viewport = dvui.windowRectPixels();
        try std.testing.expect(bounds.sidebar.w > 0 and bounds.content.w > 0);
        try std.testing.expect(bounds.sidebar.x >= viewport.x);
        try std.testing.expect(bounds.sidebar.x + bounds.sidebar.w <= bounds.content.x + 1);
        try std.testing.expect(bounds.content.x + bounds.content.w <= viewport.x + viewport.w + 1);
        if (current.sidebar) |expanded| {
            // Clicking a rail item leaves the pointer over it, so hover expansion
            // remains active during the navigation fixture.
            const expected: f32 = if (expanded or (current.navigate_anime and frames >= 5) or (current.hover_sidebar and frames <= 5)) 208 else 48;
            if (!current.hover_sidebar or frames == 5 or frames == 8)
                try std.testing.expect(@abs(bounds.sidebar.w - expected * dvui.windowNaturalScale()) <= 1);
        }
    }
    if (current.route == .settings and frames >= 4) {
        try std.testing.expect(state.app.config_loaded.load(.acquire));
        const toggles = @import("components.zig").toggleBoundsForTest();
        if (current.settings == .General) try std.testing.expect(toggles.len > 0);
        for (toggles) |bounds| {
            try std.testing.expect(bounds.pill.w > 0 and bounds.pill.h > 0);
            try std.testing.expect(bounds.pill.x >= bounds.row.x and bounds.pill.x + bounds.pill.w <= bounds.row.x + bounds.row.w + 1);
        }
    }
    if (current.route == .browse and current.tab == .Anime and frames >= 4) {
        const toolbar = @import("../services/anime.zig").nativeToolbarRectForTest();
        const height = @import("browse_layout_pure.zig").toolbarHeight(dvui.themeGet().font_body.size);
        try std.testing.expect(toolbar.h > 0 and toolbar.h <= height * dvui.windowNaturalScale() + 1);
    }
    if (current.route == .browse and current.tab == .Novels and frames >= 4) {
        const viewport = dvui.windowRectPixels();
        for (@import("../services/novels.zig").nativeCardRectsForTest()) |card| {
            try std.testing.expect(card.w > 0 and card.h > 0);
            try std.testing.expect(card.x >= viewport.x and card.x + card.w <= viewport.x + viewport.w + 1);
        }
    }
    if (current.route == .watching and frames >= 4) {
        const rows = local_ui.layoutRowsForTest();
        try std.testing.expect(rows[0].y + rows[0].h <= rows[1].y + 1);
        try std.testing.expect(rows[1].y + rows[1].h <= rows[2].y + 1);
        const editor = local_ui.editorFieldsForTest();
        try std.testing.expect(editor[0].h > 0 and editor[1].h > 0);
        try std.testing.expect(@abs(editor[0].h - editor[1].h) <= 1);
    }
}
fn cleanup() void {
    @import("shell.zig").setSidebarFixtureForTest(null);
    if (current.navigate_anime) @import("../services/anime.zig").setLoadingFixtureForTest(false);
    search.shutdown();
    search.deinitGallery();
    if (fixture_rows) |rows| alloc.free(rows);
    fixture_rows = null;
    resolver.clearResults();
    local_ui.setFixtureForTest(null, null, null);
    @import("../services/tmdb.zig").freeImageBuffers();
    for (state.app.tmdb.results.items) |item| if (item.poster_tex) |art| dvui.textureDestroyLater(art);
    state.app.tmdb.results.deinit(alloc);
    state.app.tmdb.results = .empty;
    for (state.app.tmdb.watchlist.items) |item| if (item.poster_tex) |art| dvui.textureDestroyLater(art);
    state.app.tmdb.watchlist.deinit(alloc);
    state.app.tmdb.watchlist = .empty;
    for (state.app.yt.results.items) |item| {
        if (item.thumb_tex) |art| dvui.textureDestroyLater(art);
        if (item.thumb_pixels) |pixels| alloc.free(pixels);
    }
    state.app.yt.results.deinit(alloc);
    state.app.yt.results = .empty;
    for (state.app.anime.results[0..state.app.anime.result_count]) |*item| {
        if (item.poster_tex) |art| dvui.textureDestroyLater(art);
        item.poster_tex = null;
    }
    @import("../services/anime.zig").setNativeFixtureForTest(&.{});
    @import("../services/comics.zig").setNativeFixtureForTest(&.{});
    @import("../services/novels.zig").setNativeFixtureForTest(&.{});
}
test "Native shell offline route pixel capture" {
    try resolver.verifyConnectedFeedForTest();
    try @import("browse_filters_native_test.zig").run();
    captured = 0;
    const workers = @import("../core/workers.zig");
    @import("../core/logs.zig").logs_allocator = alloc;
    defer @import("../core/logs.zig").deinit();
    workers.init();
    @import("../services/profiles.zig").initActive();
    // Render-time initial loads may be requested but are not admitted. This
    // harness performs no provider requests, background bootstrap or playback.
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    const cases = [_]Case{
        .{ .name = "ranking-lupin", .route = .search, .scope = .movies_tv, .ranking_fixture = true },
        .{ .name = "submit-movies-direct", .route = .browse, .tab = .TMDB, .submit_query = true },
        .{ .name = "submit-movies-sidebar", .route = .home, .tab = .TMDB, .submit_query = true, .navigate_movies = true },
        .{ .name = "submit-movies-navigation", .route = .browse, .tab = .TMDB, .submit_query = true, .nav_api = true },
        .{ .name = "submit-enter-youtube", .route = .browse, .tab = .YouTube, .submit_query = true },
        .{ .name = "submit-enter-music", .route = .browse, .tab = .Music, .submit_query = true },
        .{ .name = "scope-music", .route = .search, .scope = .music },
        .{ .name = "scope-remove", .route = .search, .scope = .music, .remove_scope = true },
        .{ .name = "scope-clear", .route = .search, .scope = .music, .clear_query = true },
        .{ .name = "home", .route = .home },
        .{ .name = "search", .route = .search },
        .{ .name = "watching", .route = .watching },
        .{ .name = "downloads", .route = .downloads },
        .{ .name = "queue", .route = .queue },
        .{ .name = "history", .route = .history },
        .{ .name = "assistant", .route = .assistant },
        .{ .name = "system", .route = .system },
        .{ .name = "player-empty", .route = .player },
        .{ .name = "connect", .route = .connect },
    };
    const browse = [_]state.DrawerTab{ .TMDB, .YouTube, .Iptv, .Anime, .Podcasts, .Radio, .Music, .Comics, .Web, .RSS, .Jellyfin, .Plex, .Audiobooks, .Opds, .Novels, .Vndb, .Drama };
    for ([_][2]u32{ .{ 1360, 1000 }, .{ 640, 800 } }) |size| {
        preset = .midnight;
        for (cases) |item| {
            current = item;
            try captureCase(size);
        }
        for ([_]bool{ true, false }) |expanded| {
            current = .{ .name = if (expanded) "sidebar-expanded" else "sidebar-rail", .route = .search, .sidebar = expanded };
            try captureCase(size);
            current = .{ .name = if (expanded) "sidebar-navigate-expanded" else "sidebar-navigate-rail", .route = .search, .sidebar = expanded, .navigate_anime = true };
            try captureCase(size);
        }
        current = .{ .name = "sidebar-hover", .route = .search, .sidebar = false, .hover_sidebar = true };
        try captureCase(size);
        for (browse) |tab| {
            var name: [64]u8 = undefined;
            current = .{ .name = try std.fmt.bufPrint(&name, "browse-{s}", .{@tagName(tab)}), .route = .browse, .tab = tab };
            try captureCase(size);
        }
        inline for (std.meta.fields(state.SettingsTab)) |entry| {
            var name: [64]u8 = undefined;
            current = .{ .name = try std.fmt.bufPrint(&name, "settings-{s}", .{entry.name}), .route = .settings, .settings = @enumFromInt(entry.value) };
            try captureCase(size);
        }
        for (router.PLUGIN_TABS) |tab| {
            var name: [64]u8 = undefined;
            current = .{ .name = try std.fmt.bufPrint(&name, "plugins-{s}", .{@tagName(tab)}), .route = .plugins, .plugin = tab };
            try captureCase(size);
        }
        for ([_]theme.ThemePreset{ .ember, .nord }) |alternate| {
            preset = alternate;
            for ([_]Case{ cases[0], cases[1], .{ .name = "browse-TMDB", .route = .browse }, .{ .name = "settings-General", .route = .settings } }) |item| {
                var name: [96]u8 = undefined;
                current = item;
                current.name = try std.fmt.bufPrint(&name, "{s}-{s}", .{ item.name, @tagName(alternate) });
                try captureCase(size);
            }
        }
    }
    try std.testing.expect(captured > 0);
}
