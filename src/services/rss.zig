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
const MAX_TITLE = 200;
const MAX_MAGNET = 1024;

pub const RssItem = struct {
    title: [MAX_TITLE]u8 = undefined,
    title_len: usize = 0,
    magnet: [MAX_MAGNET]u8 = undefined,
    magnet_len: usize = 0,
    size_bytes: u64 = 0,
    seeds: u16 = 0,
    peers: u16 = 0,
};

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
var fetch_thread: ?std.Thread = null;
var active_feed_idx: usize = 0;
var auto_fetched: bool = false;
var items_mutex: @import("../core/sync.zig").Mutex = .{};

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
    fetch_thread = @import("../core/workers.zig").spawnLegacy(fetchWorker, .{idx}) catch null;
}

fn fetchWorker(idx: usize) void {
    defer {
        is_fetching = false;
    }

    const url = feeds[idx].url[0..feeds[idx].url_len];

    // Use curl to fetch RSS
    const alloc = @import("../core/alloc.zig").allocator;
    const argv = [_][]const u8{ "curl", "-sL", "--max-time", "15", url };
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        fetch_error = true;
        return;
    };

    const stdout = child.stdout orelse {
        fetch_error = true;
        return;
    };
    const body_buf = alloc.alloc(u8, 512 * 1024) catch {
        fetch_error = true;
        return;
    };
    defer alloc.free(body_buf);
    const body_len = @import("../core/io_global.zig").readAll(stdout, body_buf) catch 0;
    _ = child.wait() catch {};

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
    var parsed_count: usize = 0;
    var pos: usize = 0;
    while (pos < body.len and parsed_count < MAX_ITEMS) {
        const item_start = std.mem.indexOfPos(u8, body, pos, "<item>") orelse break;
        const item_end = std.mem.indexOfPos(u8, body, item_start, "</item>") orelse break;
        const block = body[item_start..item_end];

        var item = &parsed_items[parsed_count];
        item.* = .{};

        // Title
        if (extractTag(block, "<title>", "</title>")) |t| {
            const tlen = @min(t.len, MAX_TITLE);
            @memcpy(item.title[0..tlen], t[0..tlen]);
            item.title_len = tlen;
        }

        // Magnet URI (inside CDATA)
        if (extractTag(block, "<torrent:magnetURI>", "</torrent:magnetURI>")) |raw| {
            // Strip CDATA wrapper if present
            const magnet = if (std.mem.indexOf(u8, raw, "magnet:")) |mi|
                raw[mi..]
            else
                raw;
            // Trim trailing ]]> if present
            const clean = if (std.mem.indexOf(u8, magnet, "]]>")) |ei|
                magnet[0..ei]
            else
                magnet;
            const mlen = @min(clean.len, MAX_MAGNET);
            @memcpy(item.magnet[0..mlen], clean[0..mlen]);
            item.magnet_len = mlen;
        }

        // Size
        if (extractTag(block, "<torrent:contentLength>", "</torrent:contentLength>")) |s| {
            item.size_bytes = std.fmt.parseInt(u64, s, 10) catch 0;
        }

        // Seeds
        if (extractTag(block, "<torrent:seeds>", "</torrent:seeds>")) |s| {
            item.seeds = std.fmt.parseInt(u16, s, 10) catch 0;
        }

        // Peers
        if (extractTag(block, "<torrent:peers>", "</torrent:peers>")) |s| {
            item.peers = std.fmt.parseInt(u16, s, 10) catch 0;
        }

        if (item.title_len > 0) parsed_count += 1;
        pos = item_end + 7; // skip </item>
    }
    items_mutex.lock();
    @memcpy(items[0..parsed_count], parsed_items[0..parsed_count]);
    item_count = parsed_count;
    items_mutex.unlock();
}

fn extractTag(block: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, block, open) orelse return null) + open.len;
    const end = std.mem.indexOfPos(u8, block, start, close) orelse return null;
    return block[start..end];
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

    // Header
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer hdr.deinit();

        _ = dvui.icon(@src(), "RSS", icons.tvg.lucide.rss, .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = theme.iconSize(.md),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
        });
        _ = dvui.label(@src(), "RSS Feeds", .{}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
        });

        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        if (is_fetching) {
            dvui.spinner(@src(), .{
                .color_text = theme.colors.accent,
                .min_size_content = theme.iconSize(.md),
                .gravity_y = 0.5,
            });
        } else {
            if (dvui.buttonIcon(@src(), "Refresh feed", icons.tvg.lucide.@"refresh-cw", .{}, .{}, .{
                .color_fill = theme.colors.bg_elevated,
                .color_text = theme.colors.accent,
            })) {
                if (feed_count > 0) fetchFeed(active_feed_idx);
            }
        }
    }

    // Feed selector tabs
    if (feed_count > 0) {
        var tab_row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .background = true,
            .color_fill = theme.colors.bg_app,
        });
        defer tab_row.deinit();

        for (0..feed_count) |fi| {
            const f = &feeds[fi];
            const active = (fi == active_feed_idx);
            if (components.filterChip(@src(), f.name[0..f.name_len], icons.tvg.lucide.rss, active, fi + 30000)) {
                if (!is_fetching) fetchFeed(fi);
            }
        }

        // "+" add feed button
        if (feed_count < MAX_FEEDS) {
            if (components.filterChip(@src(), "Add", icons.tvg.lucide.plus, false, 39999)) {
                state.app.rss_show_add = !state.app.rss_show_add;
            }
        }
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
        var te_name = dvui.textEntry(@src(), .{ .text = .{ .buffer = &add_name_buf } }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
        });
        te_name.deinit();

        // URL input
        var te_url = dvui.textEntry(@src(), .{ .text = .{ .buffer = &add_url_buf } }, .{
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
            .color_text = dvui.Color.white,
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
        components.emptyState(icons.tvg.lucide.rss, "No feed items", "Choose a feed or refresh it to load entries.");
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    const row_h: f32 = 68;
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
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .min_size_content = .{ .w = 0, .h = row_h },
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = row_h },
        });
        defer row.deinit();

        // Title + meta row
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = i + 3000,
                .expand = .horizontal,
            });
            defer col.deinit();

            // Title
            _ = dvui.label(@src(), "{s}", .{title}, .{
                .id_extra = i + 4000,
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
            });

            // Meta line: seeds icon + count · size
            {
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
                });

                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = i + 8500,
                    .color_text = theme.colors.text_secondary,
                    .gravity_y = 0.5,
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
                });

                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = i + 9600,
                    .color_text = theme.colors.text_secondary,
                    .gravity_y = 0.5,
                });

                // Size
                _ = dvui.label(@src(), "{s}", .{size_str}, .{
                    .id_extra = i + 5000,
                    .color_text = theme.colors.text_secondary,
                    .gravity_y = 0.5,
                });
            }
        }

        // Play button (SVG icon)
        if (item.magnet_len > 0) {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
                .id_extra = i + 6000,
                .color_fill = theme.colors.accent,
                .color_text = dvui.Color.white,
                .gravity_y = 0.5,
            })) {
                // Route magnet through torrent engine (not mpv directly!)
                const search = @import("search.zig");
                search.loadTorrentToPlayer(item.magnet[0..item.magnet_len]);
            }
        }

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
