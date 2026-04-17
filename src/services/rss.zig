const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const c = @import("../core/c.zig");
const player = @import("../player/player.zig");

// ══════════════════════════════════════════════════════════
// RSS Torrent Feed Reader
// Supports multiple RSS feeds (EZTV, showRSS, etc.)
// Parses <item> elements for title + magnet URI
// ══════════════════════════════════════════════════════════

const MAX_FEEDS = 8;
const MAX_ITEMS = 100;
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

// ── Add URL input state ──
var add_url_buf: [512]u8 = [_]u8{0} ** 512;
var add_url_len: usize = 0;
var add_name_buf: [64]u8 = [_]u8{0} ** 64;
var add_name_len: usize = 0;

pub fn init() void {
    // Pre-populate with EZTV
    addFeed("EZTV", "https://myrss.org/eztv");
}

pub fn addFeed(name: []const u8, url: []const u8) void {
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

pub fn removeFeed(idx: usize) void {
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

pub fn fetchFeed(idx: usize) void {
    if (is_fetching) return;
    if (idx >= feed_count) return;
    active_feed_idx = idx;
    is_fetching = true;
    fetch_error = false;
    fetch_thread = std.Thread.spawn(.{}, fetchWorker, .{idx}) catch null;
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
    var body_buf: [512 * 1024]u8 = undefined; // 512KB should be plenty for RSS
    const body_len = @import("../core/io_global.zig").readAll(stdout, &body_buf) catch 0;
    _ = child.wait() catch {};

    if (body_len == 0) {
        fetch_error = true;
        return;
    }
    const body = body_buf[0..body_len];

    // Parse items
    item_count = 0;
    var pos: usize = 0;
    while (pos < body.len and item_count < MAX_ITEMS) {
        const item_start = std.mem.indexOfPos(u8, body, pos, "<item>") orelse break;
        const item_end = std.mem.indexOfPos(u8, body, item_start, "</item>") orelse break;
        const block = body[item_start..item_end];

        var item = &items[item_count];
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

        if (item.title_len > 0) item_count += 1;
        pos = item_end + 7; // skip </item>
    }
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
    // Header
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_drawer,
        });
        defer hdr.deinit();

        _ = dvui.label(@src(), "RSS Feeds", .{}, .{
            .color_text = theme.colors.text_main,
            .gravity_y = 0.5,
        });

        { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }

        if (is_fetching) {
            _ = dvui.label(@src(), "Fetching...", .{}, .{
                .color_text = theme.colors.warning,
                .gravity_y = 0.5,
            });
        } else {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"activity", .{}, .{}, .{
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.accent,
            })) {
                if (feed_count > 0) fetchFeed(active_feed_idx);
            }
        }
    }

    // Feed selector tabs
    if (feed_count > 0) {
        var tab_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .background = true,
            .color_fill = theme.colors.bg_header,
        });
        defer tab_row.deinit();

        for (0..feed_count) |fi| {
            const f = &feeds[fi];
            const active = (fi == active_feed_idx);
            const bg = if (active) theme.colors.accent else theme.colors.bg_glass;
            const fg = if (active) dvui.Color.white else theme.colors.text_muted;
            if (dvui.button(@src(), f.name[0..f.name_len], .{}, .{
                .id_extra = fi,
                .color_fill = bg,
                .color_text = fg,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
                .margin = .{ .x = if (fi == 0) @as(u32, 0) else 2, .y = 0, .w = 0, .h = 0 },
            })) {
                active_feed_idx = fi;
                fetchFeed(fi);
            }
        }

        // "+" add feed button
        if (feed_count < MAX_FEEDS) {
            if (dvui.button(@src(), "+", .{}, .{
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.success,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
            })) {
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
            .color_fill = theme.colors.bg_card,
        });
        defer form.deinit();

        _ = dvui.label(@src(), "Add RSS Feed", .{}, .{
            .color_text = theme.colors.text_main,
        });

        // Name input
        var te_name = dvui.textEntry(@src(), .{ .text = .{ .buffer = &add_name_buf } }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
            .color_fill = theme.colors.bg_input,
            .color_text = theme.colors.text_main,
            .corner_radius = theme.dims.rad_sm,
        });
        te_name.deinit();

        // URL input
        var te_url = dvui.textEntry(@src(), .{ .text = .{ .buffer = &add_url_buf } }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
            .color_fill = theme.colors.bg_input,
            .color_text = theme.colors.text_main,
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
            .color_fill = theme.colors.bg_glass,
            .color_text = theme.colors.text_muted,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        })) {
            state.app.rss_show_add = false;
        }
    }

    // Error
    if (fetch_error) {
        _ = dvui.label(@src(), "⚠ Failed to fetch feed", .{}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    // Items list
    if (item_count == 0 and !is_fetching and !fetch_error) {
        _ = dvui.label(@src(), "No items — click Refresh to load", .{}, .{
            .color_text = theme.colors.text_muted,
            .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_drawer,
    });
    defer scroll.deinit();

    for (0..item_count) |i| {
        const item = &items[i];
        const title = item.title[0..item.title_len];
        const size_buf = formatSize(item.size_bytes);
        const size_str = std.mem.sliceTo(&size_buf, 0);

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_card,
            .color_border = theme.colors.bg_header_border,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
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
                .color_text = theme.colors.text_main,
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
                const seed_color = if (item.seeds > 10) theme.colors.success
                               else if (item.seeds > 0) theme.colors.warning
                               else theme.colors.text_muted;
                _ = dvui.icon(@src(), "", icons.tvg.lucide.@"monitor-up", .{}, .{
                    .id_extra = i + 8000,
                    .color_text = seed_color,
                    .min_size_content = .{ .w = 12, .h = 12 },
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
                    .color_text = theme.colors.text_muted,
                    .gravity_y = 0.5,
                });

                // Peers icon
                _ = dvui.icon(@src(), "", icons.tvg.lucide.@"monitor-down", .{}, .{
                    .id_extra = i + 9000,
                    .color_text = theme.colors.text_muted,
                    .min_size_content = .{ .w = 12, .h = 12 },
                });

                var peer_buf: [8]u8 = undefined;
                const peer_str = std.fmt.bufPrintZ(&peer_buf, "{d}", .{item.peers}) catch "?";
                _ = dvui.label(@src(), "{s}", .{peer_str}, .{
                    .id_extra = i + 9500,
                    .color_text = theme.colors.text_muted,
                    .gravity_y = 0.5,
                });

                _ = dvui.label(@src(), " · ", .{}, .{
                    .id_extra = i + 9600,
                    .color_text = theme.colors.text_muted,
                    .gravity_y = 0.5,
                });

                // Size
                _ = dvui.label(@src(), "{s}", .{size_str}, .{
                    .id_extra = i + 5000,
                    .color_text = theme.colors.text_muted,
                    .gravity_y = 0.5,
                });
            }
        }

        // Play button (SVG icon)
        if (item.magnet_len > 0) {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"play", .{}, .{}, .{
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
                    .color_fill = theme.colors.bg_card,
                    .color_border = theme.colors.border_drawer,
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
}
