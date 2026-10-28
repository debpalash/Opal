//! Ephemeral search scope. Never changes saved provider preferences.
const std = @import("std");
const view = @import("search_view_pure.zig");
pub const Scope = enum {
    all,
    movies_tv,
    youtube,
    anime,
    shows,
    live_tv,
    podcasts,
    radio,
    music,
    comics,
    books,
    visual_novels,
    rss,
    jellyfin,
    plex,
    audiobooks,
    reading,

    pub fn label(self: Scope) []const u8 {
        return switch (self) {
            .all => "All content",
            .movies_tv => "Movies & TV",
            .youtube => "YouTube",
            .anime => "Anime",
            .shows => "Shows",
            .live_tv => "Live TV",
            .podcasts => "Podcasts",
            .radio => "Radio",
            .music => "Music",
            .comics => "Comics",
            .books => "Books",
            .visual_novels => "Visual novels",
            .rss => "RSS",
            .jellyfin => "Jellyfin",
            .plex => "Plex",
            .audiobooks => "Audiobooks",
            .reading => "Reading server",
        };
    }
    pub fn matches(self: Scope, item: view.Item) bool {
        return switch (self) {
            .all => true,
            .movies_tv => item.kind == .movies or item.kind == .shows,
            .youtube => item.source == .youtube,
            .anime => item.kind == .anime,
            .shows => item.kind == .shows,
            .live_tv => item.kind == .live_tv,
            .podcasts => item.kind == .podcasts,
            .radio => item.kind == .radio,
            .music => item.kind == .music,
            .comics => item.kind == .comics,
            .books => item.kind == .books,
            .visual_novels => item.kind == .visual_novels,
            .rss => view.Provider.eql(item.provider, view.Provider.init("rss")),
            .jellyfin => item.source == .jellyfin,
            .plex => item.source == .plex,
            .audiobooks => item.source == .audiobooks,
            .reading => item.source == .opds,
        };
    }
    /// Provider admission is separate from exact content filtering: a library
    /// can return several kinds, which are filtered before gallery grouping.
    pub fn allowsBackend(self: Scope, name: []const u8) bool {
        if (self == .all) return true;
        return switch (self) {
            .youtube => std.mem.eql(u8, name, "youtube"),
            .rss => std.mem.eql(u8, name, "rss"),
            .jellyfin => std.mem.eql(u8, name, "jellyfin"),
            .plex => std.mem.eql(u8, name, "plex"),
            .audiobooks => std.mem.eql(u8, name, "audiobooks"),
            .reading => std.mem.eql(u8, name, "opds"),
            else => blk: {
                if (std.mem.eql(u8, name, "local") or std.mem.eql(u8, name, "plugin")) break :blk true;
                break :blk switch (self) {
                    .movies_tv, .shows => oneOf(name, &.{ "tmdb", "jellyfin", "plex", "stremio", "torrent" }),
                    .anime => oneOf(name, &.{"anime"}),
                    .music => oneOf(name, &.{ "music", "jellyfin", "plex" }),
                    .books => oneOf(name, &.{ "novels", "audiobooks", "opds" }),
                    .comics => oneOf(name, &.{ "comics", "opds" }),
                    .live_tv => oneOf(name, &.{"livetv"}),
                    .podcasts => oneOf(name, &.{"podcast"}),
                    .radio => oneOf(name, &.{"radio"}),
                    .visual_novels => oneOf(name, &.{"vndb"}),
                    else => false,
                };
            },
        };
    }
};
fn oneOf(value: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, value, name)) return true;
    return false;
}
pub fn forTab(tab: []const u8) Scope {
    const tabs = .{ "TMDB", "YouTube", "Anime", "Drama", "Iptv", "Podcasts", "Radio", "Music", "Comics", "Novels", "Vndb", "RSS", "Jellyfin", "Plex", "Audiobooks", "Opds" };
    const scopes = [_]Scope{ .movies_tv, .youtube, .anime, .shows, .live_tv, .podcasts, .radio, .music, .comics, .books, .visual_novels, .rss, .jellyfin, .plex, .audiobooks, .reading };
    inline for (tabs, scopes) |name, scope| if (std.mem.eql(u8, tab, name)) return scope;
    return .all;
}
pub const Context = struct {
    pub const Page = enum { browse, results, global, other };
    scope: Scope = .all,
    page: Page = .other,
    tab: []const u8 = "",
    pub fn enter(self: *Context, page: Page, tab: []const u8) bool {
        const before = self.scope;
        if (page == .browse and (self.page != .browse or !std.mem.eql(u8, self.tab, tab))) self.scope = forTab(tab);
        if (page == .global) self.scope = .all;
        self.page = page;
        self.tab = tab;
        return before != self.scope;
    }
};
test "scope follows browsing, survives results, and removal stays global" {
    var context: Context = .{};
    try std.testing.expect(context.enter(.browse, "YouTube"));
    try std.testing.expectEqual(Scope.youtube, context.scope);
    try std.testing.expect(!context.enter(.results, "YouTube"));
    context.scope = .all;
    try std.testing.expect(!context.enter(.results, "YouTube"));
    try std.testing.expect(context.enter(.browse, "Music"));
    context.scope = .all;
    try std.testing.expect(!context.enter(.browse, "Music"));
    try std.testing.expect(context.enter(.browse, "Plex"));
    try std.testing.expect(context.enter(.global, ""));
}
test "source scopes exclude other providers; content scopes span libraries" {
    try std.testing.expect(Scope.youtube.matches(.{ .source = .youtube }));
    try std.testing.expect(!Scope.youtube.matches(.{ .source = .plex }));
    try std.testing.expect(Scope.music.matches(.{ .source = .jellyfin, .kind = .music }));
    try std.testing.expect(!Scope.music.matches(.{ .source = .jellyfin, .kind = .movies }));
    try std.testing.expect(Scope.movies_tv.matches(.{ .kind = .shows }));
    try std.testing.expect(!Scope.movies_tv.matches(.{ .source = .youtube, .kind = .video }));
    try std.testing.expect(Scope.youtube.allowsBackend("youtube"));
    try std.testing.expect(!Scope.youtube.allowsBackend("torrent"));
    try std.testing.expect(Scope.music.allowsBackend("plex"));
    try std.testing.expect(!Scope.music.allowsBackend("tmdb"));
    try std.testing.expect(Scope.all.allowsBackend("torrent"));
}
