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
const Case = struct { name: []const u8, route: router.Route, tab: state.DrawerTab = .TMDB, settings: state.SettingsTab = .General, plugin: router.PluginTab = .sources };
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
    theme.active_preset = preset;
    state.app.page_shell_enabled = true;
    state.app.ui_scale = 1;
    state.app.router.current = current.route;
    state.app.browse_source = current.tab;
    state.app.settings_tab = current.settings;
    state.app.plugin_tab = current.plugin;
    state.app.config_loaded.store(current.route == .settings, .release);
    state.app.content_cache_enabled = false;
    state.app.taste_enabled = false;

    first_frame = true;
    frames = 0;
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
        resolver.clearResults();
        resolver.results_mutex.lock();
        @memcpy(resolver.results[0..rows.len], rows);
        resolver.result_count = rows.len;
        field(&resolver.resolver_query, &resolver.resolver_query_len, "Offline layout fixtures");
        resolver.results_mutex.unlock();
        search.setUniversalQuery("Offline layout fixtures");
    } else @memset(&state.app.magnet_buf, 0);
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
            field(&item.title, &item.title_len, "A long video title — Exploring the world through cinema and music");
            field(&item.uploader, &item.uploader_len, "Offline fixture channel");
            item.thumb_tex = try texture(i);
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
    try @import("shell.zig").render();
    frames += 1;
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
    captured = 0;
    const workers = @import("../core/workers.zig");
    @import("../core/logs.zig").logs_allocator = alloc;
    defer @import("../core/logs.zig").deinit();
    workers.init();
    // Render-time initial loads may be requested but are not admitted. This
    // harness performs no provider requests, background bootstrap or playback.
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    const cases = [_]Case{
        .{ .name = "home", .route = .home },           .{ .name = "search", .route = .search },
        .{ .name = "watching", .route = .watching },   .{ .name = "downloads", .route = .downloads },
        .{ .name = "queue", .route = .queue },         .{ .name = "history", .route = .history },
        .{ .name = "assistant", .route = .assistant }, .{ .name = "system", .route = .system },
        .{ .name = "player-empty", .route = .player },
    };
    const browse = [_]state.DrawerTab{ .TMDB, .YouTube, .Iptv, .Anime, .Podcasts, .Radio, .Music, .Comics, .Web, .RSS, .Jellyfin, .Plex, .Audiobooks, .Opds, .Novels, .Vndb, .Drama };
    for ([_][2]u32{ .{ 1360, 1000 }, .{ 640, 800 } }) |size| {
        preset = .midnight;
        for (cases) |item| {
            current = item;
            try captureCase(size);
        }
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
