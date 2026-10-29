const browse_filters = @import("../ui/browse_filters.zig");
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const tmdb_pure = @import("tmdb_pure.zig");
const c = @import("../core/c.zig");
const player = @import("../player/player.zig");
const io = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const rss_alloc = @import("../core/alloc.zig").allocator;

// ══════════════════════════════════════════════════════════
// RSS Torrent Feed Reader
// Supports multiple RSS feeds (EZTV, showRSS, etc.)
// Parses <item> elements for title + magnet URI
// ══════════════════════════════════════════════════════════

const MAX_FEEDS = 8;
const MAX_ITEMS = 300;

const feed_parser = @import("rss_feed_pure.zig");
const surfaces = @import("../ui/service_surfaces.zig");
pub const RssItem = feed_parser.Item;

pub const RssFeed = struct {
    url: [512]u8 = undefined,
    url_len: usize = 0,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    enabled: bool = true,
};

// ── State ──
pub var feeds: [MAX_FEEDS]RssFeed = undefined;
pub var feed_count: usize = 0;
pub var items: [MAX_ITEMS]RssItem = undefined;
pub var item_count: usize = 0;
pub var is_fetching: bool = false;
pub var fetch_error: bool = false;
var active_feed_idx: usize = 0;
var auto_fetched: bool = false;
var items_mutex: @import("../core/sync.zig").Mutex = .{};

pub fn setNativeFixtureForTest(enabled: bool) void {
    if (!@import("builtin").is_test) @compileError("test-only");
    auto_fetched = enabled;
    is_fetching = false;
    fetch_error = false;
    item_count = 0;
    feed_count = 0;
    if (enabled) {
        appendFeed("Reading & culture", "https://example.invalid/feed");
        appendFeed("Releases", "https://example.invalid/releases");
    }
}

// ── Add URL input state ──
var add_url_buf: [512]u8 = [_]u8{0} ** 512;
var add_url_len: usize = 0;
var add_name_buf: [64]u8 = [_]u8{0} ** 64;
var add_name_len: usize = 0;

fn initDefaults() void {
    // Pre-populate with EZTV
    appendFeed("EZTV", "https://myrss.org/eztv");
    // Anime News Network — anime/manga industry news (keyless public RSS). Same
    // class as EZTV above: a built-in default feed the user can remove.
    appendFeed("Anime News Network", "https://www.animenewsnetwork.com/all/rss.xml");
}

fn appendFeed(name: []const u8, url: []const u8) void {
    if (feed_count >= MAX_FEEDS) return;
    var f = &feeds[feed_count];
    const nlen = @min(name.len, 63);
    @memcpy(f.name[0..nlen], name[0..nlen]);
    f.name_len = nlen;
    const ulen = @min(url.len, 511);
    @memcpy(f.url[0..ulen], url[0..ulen]);
    f.url_len = ulen;
    f.enabled = true;
    feed_count += 1;
}

fn removeFeedRaw(idx: usize) void {
    if (idx >= feed_count) return;
    var i = idx;
    while (i + 1 < feed_count) : (i += 1) {
        feeds[i] = feeds[i + 1];
    }
    feed_count -= 1;
    if (active_feed_idx >= feed_count and feed_count > 0) {
        active_feed_idx = feed_count - 1;
    }
}

fn validFeed(name: []const u8, url: []const u8) bool {
    return name.len > 0 and name.len < 64 and url.len > 0 and url.len < 512 and
        (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"));
}

fn configPath(buf: []u8) []const u8 {
    var dir_buf: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/rss-feeds.json", .{paths.configDir(&dir_buf)}) catch "rss-feeds.json";
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (ch >= 0x20) try writer.writeByte(ch),
    };
}

fn saveFeeds() bool {
    var dir_buf: [512]u8 = undefined;
    io.cwdMakePath(paths.configDir(&dir_buf)) catch return false;
    var out: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    writer.writeByte('[') catch return false;
    for (feeds[0..feed_count], 0..) |*feed, i| {
        if (i > 0) writer.writeByte(',') catch return false;
        writer.writeAll("{\"name\":\"") catch return false;
        writeJsonString(&writer, feed.name[0..feed.name_len]) catch return false;
        writer.writeAll("\",\"url\":\"") catch return false;
        writeJsonString(&writer, feed.url[0..feed.url_len]) catch return false;
        writer.print("\",\"enabled\":{s}}}", .{if (feed.enabled) "true" else "false"}) catch return false;
    }
    writer.writeByte(']') catch return false;
    var path_buf: [640]u8 = undefined;
    @import("../core/secret_file.zig").write(configPath(&path_buf), out[0..writer.end]) catch return false;
    return true;
}

fn loadFeeds() bool {
    var path_buf: [640]u8 = undefined;
    const body = io.cwdReadFileAlloc(configPath(&path_buf), rss_alloc, 16 * 1024) catch return false;
    defer rss_alloc.free(body);
    var parsed = std.json.parseFromSlice(std.json.Value, rss_alloc, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .array) return false;
    feed_count = 0;
    for (parsed.value.array.items) |entry| {
        if (entry != .object) continue;
        const name = entry.object.get("name") orelse continue;
        const url = entry.object.get("url") orelse continue;
        if (name != .string or url != .string or !validFeed(name.string, url.string)) continue;
        appendFeed(name.string, url.string);
        if (entry.object.get("enabled")) |enabled| {
            if (enabled == .bool and feed_count > 0) feeds[feed_count - 1].enabled = enabled.bool;
        }
    }
    return true;
}

pub fn init() void {
    if (loadFeeds()) return;
    initDefaults();
    _ = saveFeeds();
}

pub fn addFeed(name: []const u8, url: []const u8) void {
    if (!validFeed(name, url) or feed_count >= MAX_FEEDS) return;
    appendFeed(name, url);
    _ = saveFeeds();
}

pub fn addFeedManaged(name: []const u8, url: []const u8) bool {
    if (!validFeed(name, url) or feed_count >= MAX_FEEDS) return false;
    appendFeed(name, url);
    if (saveFeeds()) return true;
    feed_count -= 1;
    return false;
}

pub fn updateFeed(idx: usize, name: []const u8, url: []const u8, enabled: bool) bool {
    if (idx >= feed_count or !validFeed(name, url)) return false;
    const feed = &feeds[idx];
    const previous = feed.*;
    @memcpy(feed.name[0..name.len], name);
    feed.name_len = name.len;
    @memcpy(feed.url[0..url.len], url);
    feed.url_len = url.len;
    feed.enabled = enabled;
    if (saveFeeds()) return true;
    feed.* = previous;
    return false;
}

pub fn removeFeed(idx: usize) void {
    removeFeedRaw(idx);
    _ = saveFeeds();
}

pub fn removeFeedManaged(idx: usize) bool {
    if (idx >= feed_count) return false;
    const previous_feeds = feeds;
    const previous_count = feed_count;
    const previous_active = active_feed_idx;
    removeFeedRaw(idx);
    if (saveFeeds()) return true;
    feeds = previous_feeds;
    feed_count = previous_count;
    active_feed_idx = previous_active;
    return false;
}

pub fn fetchFeed(idx: usize) void {
    if (is_fetching) return;
    if (idx >= feed_count or !feeds[idx].enabled) return;
    active_feed_idx = idx;
    is_fetching = true;
    fetch_error = false;
    if (@import("../core/workers.zig").spawnLegacy(fetchWorker, .{idx})) |worker| {
        @import("../core/workers.zig").release(worker);
    } else |_| {
        is_fetching = false;
        fetch_error = true;
    }
}

fn fetchWorker(idx: usize) void {
    defer {
        is_fetching = false;
        state.wakeUi();
    }

    const url = feeds[idx].url[0..feeds[idx].url_len];

    const alloc = @import("../core/alloc.zig").allocator;
    const body_buf = alloc.alloc(u8, 512 * 1024) catch {
        fetch_error = true;
        return;
    };
    defer alloc.free(body_buf);
    const body_len = if (@import("reliable_fetch.zig").fetch(url, body_buf, .{ .keep_head_on_overflow = true, .timeout_secs = 15, .impersonate = false })) |b| b.len else 0;

    if (body_len == 0) {
        fetch_error = true;
        return;
    }
    const body = body_buf[0..body_len];

    // Parse into a private page, then publish in one lock. A failed refresh
    // keeps the previous feed visible instead of clearing it mid-scroll.
    const parsed_items = rss_alloc.alloc(RssItem, MAX_ITEMS) catch {
        fetch_error = true;
        return;
    };
    defer rss_alloc.free(parsed_items);
    const parsed_count = feed_parser.parse(body, parsed_items);
    if (parsed_count == 0 and std.mem.indexOf(u8, body, "<rss") == null) {
        fetch_error = true;
        return;
    }
    items_mutex.lock();
    @memcpy(items[0..parsed_count], parsed_items[0..parsed_count]);
    item_count = parsed_count;
    items_mutex.unlock();
}

fn formatSize(bytes: u64) [12]u8 {
    var buf: [12]u8 = [_]u8{' '} ** 12;
    if (bytes == 0) {
        @memcpy(buf[0..3], "  -");
        return buf;
    }
    const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    if (mb >= 1024.0) {
        const gb = mb / 1024.0;
        _ = std.fmt.bufPrintZ(&buf, "{d:.1} GB", .{gb}) catch {};
    } else {
        _ = std.fmt.bufPrintZ(&buf, "{d:.0} MB", .{mb}) catch {};
    }
    return buf;
}

// ══════════════════════════════════════════════════════════
// Drawer UI
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    // Full-page root so loading/empty branches fill width/height.
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer page.deinit();

    if (!auto_fetched and feed_count > 0) {
        auto_fetched = true;
        fetchFeed(active_feed_idx);
    }

    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 12, .y = 12, .w = 12, .h = 6 } });
        surfaces.iconTile(@src(), icons.tvg.lucide.rss, theme.colors.warning, 24);
        dvui.labelNoFmt(@src(), "Your feeds", .{}, .{ .font = dvui.themeGet().font_heading, .color_text = theme.colors.text_primary, .expand = .horizontal, .gravity_y = 0.5, .margin = .{ .x = 8 } });
        if (feed_count < MAX_FEEDS and components.actionButton(@src(), "Add feed", .secondary, 39997)) state.app.rss_show_add = !state.app.rss_show_add;
        header.deinit();
    }
    {
        var bar = browse_filters.begin(@src());
        defer bar.deinit();
        var menu_items: [MAX_FEEDS]browse_filters.Item = undefined;
        for (0..feed_count) |i| menu_items[i] = .{ .id = i, .label = feeds[i].name[0..feeds[i].name_len], .icon = icons.tvg.lucide.rss, .presentation = .icon_label, .enabled = !is_fetching };
        if (bar.menu(@src(), .{ .items = menu_items[0..feed_count], .selected = active_feed_idx })) |id| fetchFeed(id);
        browse_filters.divider(@src(), 39998);
        if (is_fetching) {
            dvui.spinner(@src(), .{ .color_text = theme.colors.accent, .min_size_content = theme.iconSize(.sm), .gravity_y = 0.5 });
        } else if (browse_filters.item(@src(), .{ .id = 40000, .label = "Refresh feed", .icon = icons.tvg.lucide.@"refresh-cw", .enabled = feed_count > 0 })) fetchFeed(active_feed_idx);
    }

    // Add feed form
    if (state.app.rss_show_add) {
        var form = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer form.deinit();

        _ = dvui.label(@src(), "Add RSS Feed", .{}, .{
            .color_text = theme.colors.text_primary,
        });

        // Name input
        var te_name = dvui.textEntry(@src(), .{ .text = .{ .buffer = &add_name_buf }, .placeholder = "Feed name" }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
        });
        te_name.deinit();

        // URL input
        var te_url = dvui.textEntry(@src(), .{ .text = .{ .buffer = &add_url_buf }, .placeholder = "https://example.com/feed" }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
        });
        const url_enter = te_url.enter_pressed;
        te_url.deinit();

        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
        defer btn_row.deinit();

        const clicked_add = dvui.button(@src(), "Add", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = theme.colors.text_on_accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        });
        if (clicked_add or url_enter) {
            const name_text = std.mem.sliceTo(&add_name_buf, 0);
            const url_text = std.mem.sliceTo(&add_url_buf, 0);
            if (name_text.len > 0 and url_text.len > 0) {
                addFeed(name_text, url_text);
                @memset(&add_name_buf, 0);
                @memset(&add_url_buf, 0);
                state.app.rss_show_add = false;
            }
        }

        if (dvui.button(@src(), "Cancel", .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        })) {
            state.app.rss_show_add = false;
        }
    }

    items_mutex.lock();
    defer items_mutex.unlock();

    // Error
    if (fetch_error) {
        if (item_count == 0) {
            components.emptyState(icons.tvg.lucide.@"cloud-off", "Couldn't load this feed", "Check the feed URL and try Refresh.");
            return;
        }
        components.statusPill("Refresh failed · showing saved items", .warn);
    }

    if (item_count == 0 and is_fetching) {
        components.loadingState("Loading feed…");
        return;
    }

    // Items list
    if (item_count == 0 and !is_fetching and !fetch_error) {
        var welcome = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(24), .margin = dvui.Rect.all(12), .background = true, .color_fill = theme.colors.bg_surface, .corner_radius = theme.dims.rad_md });
        surfaces.iconTile(@src(), icons.tvg.lucide.rss, theme.colors.warning, 32);
        dvui.labelNoFmt(@src(), if (feed_count == 0) "Follow what interests you" else "This feed has no entries yet", .{}, .{ .font = dvui.themeGet().font_heading, .color_text = theme.colors.text_primary, .margin = .{ .y = 12 } });
        components.bodyText(@src(), "Add an RSS feed for news or releases. Open articles or play available torrents.", theme.colors.text_secondary);
        if (feed_count < MAX_FEEDS and components.actionButton(@src(), "Add a feed", .primary, 40001)) state.app.rss_show_add = true;
        welcome.deinit();
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    const row_h: f32 = 84;
    const win = tmdb_pure.visibleRows(item_count, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 4);
    if (win.first > 0) {
        var spacer = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) } });
        spacer.deinit();
    }
    for (win.first..win.last) |i| {
        const item = &items[i];
        const title = item.title[0..item.title_len];
        const size_buf = formatSize(item.size_bytes);
        const size_str = std.mem.sliceTo(&size_buf, 0);

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_md,
            .margin = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
            .padding = dvui.Rect.all(10),
            .min_size_content = .{ .w = 0, .h = row_h - 28 },
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = row_h - 28 },
        });
        defer row.deinit();

        var emblem = dvui.box(@src(), .{}, .{ .margin = .{ .w = 12 }, .gravity_y = 0.5 });
        surfaces.iconTile(@src(), if (item.magnet_len > 0) icons.tvg.lucide.film else icons.tvg.lucide.@"file-text", if (item.magnet_len > 0) theme.colors.accent else theme.colors.warning, 20);
        emblem.deinit();

        // Title + meta row
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = i + 3000,
                .padding = dvui.Rect.all(0),
                .expand = .horizontal,
            });
            defer col.deinit();

            // Title
            _ = dvui.label(@src(), "{s}", .{title}, .{
                .id_extra = i + 4000,
                .padding = dvui.Rect.all(0),
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
            });

            if (item.magnet_len == 0) {
                dvui.labelNoFmt(@src(), if (item.date_len > 0) item.date[0..item.date_len] else "Article", .{}, .{ .padding = .{ .y = 4 }, .color_text = theme.colors.text_secondary, .font = dvui.themeGet().font_body.withSize(12) });
            }
            // Torrent availability only applies to playable releases.
            if (item.magnet_len > 0) {
                var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = i + 7000,
                    .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                });
                defer meta.deinit();

                // Seeds icon (arrow-up = upload/seed)
                const seed_color = if (item.seeds > 10) theme.colors.success else if (item.seeds > 0) theme.colors.warning else theme.colors.text_secondary;
                _ = dvui.icon(@src(), "", icons.tvg.lucide.@"monitor-up", .{}, .{
                    .id_extra = i + 8000,
                    .color_text = seed_color,
                    .min_size_content = theme.iconSize(.xs),
                });

                var seed_buf: [8]u8 = undefined;
                const seed_str = std.fmt.bufPrintZ(&seed_buf, "{d}", .{item.seeds}) catch "?";
                _ = dvui.label(@src(), "{s}", .{seed_str}, .{
                    .id_extra = i + 2000,
                    .color_text = seed_color,
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(0),
                });

                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = i + 8500,
                    .color_text = theme.colors.text_secondary,
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(0),
                });

                // Peers icon
                _ = dvui.icon(@src(), "", icons.tvg.lucide.@"monitor-down", .{}, .{
                    .id_extra = i + 9000,
                    .color_text = theme.colors.text_secondary,
                    .min_size_content = theme.iconSize(.xs),
                });

                var peer_buf: [8]u8 = undefined;
                const peer_str = std.fmt.bufPrintZ(&peer_buf, "{d}", .{item.peers}) catch "?";
                _ = dvui.label(@src(), "{s}", .{peer_str}, .{
                    .id_extra = i + 9500,
                    .color_text = theme.colors.text_secondary,
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(0),
                });

                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = i + 9600,
                    .color_text = theme.colors.text_secondary,
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(0),
                });

                // Size
                _ = dvui.label(@src(), "{s}", .{size_str}, .{
                    .id_extra = i + 5000,
                    .color_text = theme.colors.text_secondary,
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(0),
                });
            }
        }

        // Play button (SVG icon)
        if (item.magnet_len > 0) {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
                .id_extra = i + 6000,
                .color_fill = theme.colors.accent,
                .color_text = theme.colors.text_on_accent,
                .gravity_y = 0.5,
            })) {
                // Route magnet through torrent engine (not mpv directly!)
                const search = @import("search.zig");
                search.loadTorrentToPlayer(item.magnet[0..item.magnet_len]);
            }
        }

        if (item.url_len > 0 and components.iconButton(@src(), icons.tvg.lucide.@"external-link", "Open article in browser", false)) @import("../ui/settings.zig").openExternal(item.url[0..item.url_len]);

        // ── Right-click context menu ──
        {
            const ctext = dvui.context(@src(), .{ .rect = row.data().borderRectScale().r }, .{ .id_extra = i + 10000 });
            defer ctext.deinit();

            if (ctext.activePoint()) |cp| {
                var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{
                    .id_extra = i + 10000,
                    .color_fill = theme.colors.bg_surface,
                    .color_border = theme.colors.border_subtle,
                });
                defer fw.deinit();

                if ((dvui.menuItemLabel(@src(), "Copy Title", .{}, .{ .expand = .horizontal, .id_extra = i + 10100 })) != null) {
                    dvui.clipboardTextSet(title);
                    state.showToast("Title copied");
                    fw.close();
                }
                if (item.magnet_len > 0) {
                    if ((dvui.menuItemLabel(@src(), "Copy Magnet Link", .{}, .{ .expand = .horizontal, .id_extra = i + 10200 })) != null) {
                        dvui.clipboardTextSet(item.magnet[0..item.magnet_len]);
                        state.showToast("Magnet link copied");
                        fw.close();
                    }
                }
            }
        }
    }
    if (win.last < item_count) {
        var spacer = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(item_count - win.last)) } });
        spacer.deinit();
    }
}
