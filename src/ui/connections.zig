//! Connection management lives here; content destinations remain deep-linkable.
const brands = @import("brands.zig");
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const surfaces = @import("service_surfaces.zig");
const components = @import("components.zig");
const jf = @import("../services/jellyfin.zig");
const plex = @import("../services/plex.zig");
const abs = @import("../services/audiobookshelf.zig");
const opds = @import("../services/opds.zig");
const music = @import("../services/music_subsonic.zig");
const Provider = enum { jellyfin, plex, audiobooks, reading, music, wallpapers };
const providers = [_]struct { id: Provider, name: []const u8, icon: []const u8, brand: ?brands.Brand = null, detail: []const u8, tab: state.DrawerTab }{
    .{ .id = .jellyfin, .name = "Jellyfin / Emby", .brand = .jellyfin, .icon = icons.tvg.lucide.tv, .detail = "Movies, TV & music", .tab = .Jellyfin },
    .{ .id = .plex, .name = "Plex", .brand = .plex, .icon = icons.tvg.lucide.play, .detail = "Movies, TV & music", .tab = .Plex },
    .{ .id = .audiobooks, .name = "Audiobookshelf", .brand = .audiobookshelf, .icon = icons.tvg.lucide.headphones, .detail = "Audiobooks & podcasts", .tab = .Audiobooks },
    .{ .id = .reading, .name = "Reading server", .icon = icons.tvg.lucide.@"book-open", .detail = "Komga · Kavita · Calibre · OPDS", .tab = .Opds },
    .{ .id = .music, .name = "Subsonic", .icon = icons.tvg.lucide.music, .detail = "Navidrome · Airsonic · music", .tab = .Music },
    .{ .id = .wallpapers, .name = "Wallpaper sources", .icon = icons.tvg.lucide.image, .detail = "Wallhaven · gallery-dl · accounts", .tab = .Wallpapers },
};
var editing: ?Provider = null;
pub fn resetEditorForTest() void {
    if (!@import("builtin").is_test) @compileError("test only");
    editing = null;
}
pub fn editWallpapers() void {
    editing = .wallpapers;
    state.app.router.navigate(.connect);
}

pub fn render() void {
    if (@import("profiles_ui.zig").blocksKid()) return;
    @import("../services/search.zig").invalidateConnectedFeed();
    if (editing) |provider| {
        var bar = @import("browse_filters.zig").begin(@src());
        if (components.iconButton(@src(), icons.tvg.lucide.@"arrow-left", "Connections", false)) editing = null;
        bar.deinit();
        switch (provider) {
            .jellyfin => @import("jellyfin_ui.zig").renderConnectionEditor(),
            .plex => {
                if (plex.isConnected()) {
                    if (components.actionButton(@src(), "Reconnect with Plex", .secondary, 0)) plex.connect();
                    if (components.actionButton(@src(), "Disconnect Plex", .secondary, 0)) plex.disconnect();
                } else plex.renderContent();
            },
            .audiobooks => abs.renderLoginForm(),
            .reading => opds.renderLoginForm(),
            .music => @import("settings.zig").renderMusicConnection(),
            .wallpapers => @import("../services/wallpapers.zig").renderConnections(),
        }
        return;
    }
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(12) });
    defer content.deinit();
    var active: usize = 0;
    for (providers) |provider| if (isConnected(provider.id)) {
        active += 1;
    };
    var count_buf: [40]u8 = undefined;
    surfaces.heading(@src(), "Your connections", std.fmt.bufPrint(&count_buf, "{d} of {d} configured", .{ active, providers.len }) catch "Libraries");
    var cards = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
    defer cards.deinit();
    const available = @max(270, cards.data().contentRect().w);
    const columns = @max(1, @min(3, @floor(available / 310)));
    const card_width = @max(220, available / columns - 46);

    for (providers, 0..) |provider, i| {
        const connected = isConnected(provider.id);
        const tint: dvui.Color = switch (provider.id) {
            .jellyfin => .{ .r = 164, .g = 136, .b = 240, .a = 255 },
            .plex => .{ .r = 224, .g = 174, .b = 63, .a = 255 },
            .audiobooks => .{ .r = 210, .g = 150, .b = 111, .a = 255 },
            .reading, .wallpapers => theme.colors.accent,
            .music => .{ .r = 208, .g = 134, .b = 178, .a = 255 },
        };
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .min_size_content = .{ .w = card_width, .h = 184 },
            .max_size_content = .{ .w = card_width, .h = std.math.floatMax(f32) },
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .corner_radius = theme.dims.rad_md,
            .border = dvui.Rect.all(1),
            .color_border = tint.opacity(if (connected) 0.5 else 0.22),
            .padding = dvui.Rect.all(16),
            .margin = dvui.Rect.all(4),
        });
        var logo_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 12 } });
        surfaces.iconTile(@src(), if (provider.brand) |brand| brands.icon(brand) else provider.icon, tint, 30);
        if (provider.id == .jellyfin) dvui.icon(@src(), "Emby", brands.icon(.emby), .{}, .{ .min_size_content = theme.iconSize(.sm), .color_text = tint, .gravity_y = 0.5, .margin = .{ .x = 8 } });
        var fill = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        fill.deinit();
        surfaces.badge(@src(), if (connected) (if (provider.id == .music) "Configured" else "Connected") else "Set up", if (connected) theme.colors.success else theme.colors.text_secondary);
        logo_row.deinit();
        dvui.labelNoFmt(@src(), provider.name, .{}, .{ .font = dvui.themeGet().font_heading, .color_text = theme.colors.text_primary, .padding = dvui.Rect.all(0), .margin = .{ .h = 6 } });
        components.bodyText(@src(), provider.detail, theme.colors.text_secondary);
        var server_buf: [256]u8 = undefined;
        const server = switch (provider.id) {
            .wallpapers => "wallhaven.cc",
            .jellyfin => blk: {
                const snap = jf.connectionSnapshot();
                @memcpy(server_buf[0..snap.server_len], snap.server[0..snap.server_len]);
                break :blk server_buf[0..snap.server_len];
            },
            .plex => blk: {
                const snap = plex.connectionSnapshot();
                @memcpy(server_buf[0..snap.server_len], snap.server[0..snap.server_len]);
                break :blk server_buf[0..snap.server_len];
            },
            .audiobooks => blk: {
                const snap = abs.connectionSnapshot();
                @memcpy(server_buf[0..snap.server_len], snap.server[0..snap.server_len]);
                break :blk server_buf[0..snap.server_len];
            },
            .reading => blk: {
                const snap = opds.connectionSnapshot();
                @memcpy(server_buf[0..snap.server_len], snap.server[0..snap.server_len]);
                break :blk server_buf[0..snap.server_len];
            },
            .music => @import("../core/source_config.zig").copyValue("subsonic", "base", &server_buf) orelse "",
        };
        if (server.len > 0) {
            const start = if (std.mem.indexOf(u8, server, "://")) |offset| offset + 3 else 0;
            const end = std.mem.indexOfAnyPos(u8, server, start, "/?#") orelse server.len;
            const authority = server[start..end];
            const host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |offset| authority[offset + 1 ..] else authority;
            dvui.labelNoFmt(@src(), host, .{}, .{ .color_text = theme.colors.text_tertiary });
        }
        var space = dvui.box(@src(), .{}, .{ .expand = .vertical });
        space.deinit();
        var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 10 } });
        if (components.actionButton(@src(), if (connected) "Edit" else "Connect", .secondary, i)) editing = provider.id;
        if (connected and components.actionButton(@src(), "Browse", .primary, i + 100)) {
            if (provider.id == .music) _ = music.selectSource(music.SRC_SUBSONIC);
            state.navigateToTab(provider.tab);
        }
        actions.deinit();
        card.deinit();
    }
    var together = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 99,
        .min_size_content = .{ .w = card_width, .h = 184 },
        .max_size_content = .{ .w = card_width, .h = std.math.floatMax(f32) },
        .background = true,
        .color_fill = theme.colors.accent.opacity(0.08),
        .border = dvui.Rect.all(1),
        .color_border = theme.colors.accent.opacity(0.25),
        .corner_radius = theme.dims.rad_md,
        .padding = dvui.Rect.all(16),
        .margin = dvui.Rect.all(4),
    });
    surfaces.iconTile(@src(), icons.tvg.lucide.layers, theme.colors.accent, 30);
    dvui.labelNoFmt(@src(), "One library", .{}, .{ .font = dvui.themeGet().font_heading, .color_text = theme.colors.text_primary, .padding = dvui.Rect.all(0), .margin = .{ .y = 12, .h = 6 } });
    components.bodyText(@src(), "Browse all connected libraries.", theme.colors.text_secondary);
    var fill = dvui.box(@src(), .{}, .{ .expand = .vertical });
    fill.deinit();
    if (components.actionButton(@src(), "Open All content", .primary, 99)) {
        const search = @import("../services/search.zig");
        search.clearShellSearch();
        search.setSearchScope(.all);
        state.navigateToTab(.Search);
    }
    together.deinit();
}

fn isConnected(provider: Provider) bool {
    return switch (provider) {
        .jellyfin => jf.connectionSnapshot().connected,
        .plex => plex.isConnected(),
        .audiobooks => abs.connectionSnapshot().connected,
        .reading => opds.connectionSnapshot().connected,
        .music => music.universalConfigured(music.SRC_SUBSONIC),
        .wallpapers => @import("../services/gallerydl.zig").available(),
    };
}
