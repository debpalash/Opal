//! Connection management lives here; content destinations remain deep-linkable.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const jf = @import("../services/jellyfin.zig");
const plex = @import("../services/plex.zig");
const abs = @import("../services/audiobookshelf.zig");
const opds = @import("../services/opds.zig");
const music = @import("../services/music_subsonic.zig");
const Provider = enum { jellyfin, plex, audiobooks, reading, music };
const providers = [_]struct { id: Provider, name: []const u8, detail: []const u8, tab: state.DrawerTab }{
    .{ .id = .jellyfin, .name = "Jellyfin / Emby", .detail = "Movies, TV & music", .tab = .Jellyfin },
    .{ .id = .plex, .name = "Plex", .detail = "Movies, TV & music", .tab = .Plex },
    .{ .id = .audiobooks, .name = "Audiobookshelf", .detail = "Audiobooks & podcasts", .tab = .Audiobooks },
    .{ .id = .reading, .name = "Reading server", .detail = "Komga · Kavita · Calibre · OPDS", .tab = .Opds },
    .{ .id = .music, .name = "Subsonic", .detail = "Navidrome · Airsonic · music", .tab = .Music },
};
var editing: ?Provider = null;

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
                    if (dvui.button(@src(), "Reconnect with Plex", .{}, .{})) plex.connect();
                    if (dvui.button(@src(), "Disconnect Plex", .{}, .{})) plex.disconnect();
                } else plex.renderContent();
            },
            .audiobooks => abs.renderLoginForm(),
            .reading => opds.renderLoginForm(),
            .music => @import("settings.zig").renderMusicConnection(),
        }
        return;
    }
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    var cards = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
    defer cards.deinit();
    for (providers, 0..) |provider, i| {
        const connected = switch (provider.id) {
            .jellyfin => jf.connectionSnapshot().connected,
            .plex => plex.isConnected(),
            .audiobooks => abs.connectionSnapshot().connected,
            .reading => opds.connectionSnapshot().connected,
            .music => music.universalConfigured(music.SRC_SUBSONIC),
        };
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .min_size_content = .{ .w = 270, .h = 120 },
            .max_size_content = .{ .w = 270, .h = std.math.floatMax(f32) },
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .corner_radius = theme.dims.rad_md,
            .padding = dvui.Rect.all(12),
            .margin = dvui.Rect.all(4),
        });
        dvui.labelNoFmt(@src(), provider.name, .{}, .{ .color_text = theme.colors.text_primary });
        dvui.labelNoFmt(@src(), provider.detail, .{}, .{ .color_text = theme.colors.text_secondary });
        var server_buf: [256]u8 = undefined;
        const server = switch (provider.id) {
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
        var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        dvui.labelNoFmt(@src(), if (connected) (if (provider.id == .music) "Configured" else "Connected") else "Not connected", .{}, .{ .color_text = if (connected) theme.colors.accent else theme.colors.text_tertiary, .gravity_y = 0.5 });
        if (dvui.button(@src(), if (connected) "Edit" else "Connect", .{}, .{})) editing = provider.id;
        if (connected and dvui.button(@src(), "Browse", .{}, .{})) {
            if (provider.id == .music) _ = music.selectSource(music.SRC_SUBSONIC);
            state.navigateToTab(provider.tab);
        }
        actions.deinit();
        card.deinit();
    }
}
