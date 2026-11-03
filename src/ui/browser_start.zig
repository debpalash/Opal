//! Native new-tab surface. It never loads remote assets or exposes saved URLs to JavaScript.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons").tvg.lucide;
const c = @import("components.zig");
const theme = @import("theme.zig");
const state = @import("../core/state.zig");
const browser = @import("../services/browser.zig");
const privacy = @import("../services/browser_privacy.zig");
var query: [2048]u8 = @splat(0);
pub var search_bounds_for_test: dvui.Rect.Physical = .{};
pub var rendered_for_test = false;

fn glyph(src: std.builtin.SourceLocation, icon: []const u8) void {
    dvui.icon(src, "", icon, .{}, .{ .min_size_content = .{ .w = 18, .h = 18 }, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.accent }, .margin = .{ .w = 8 } });
}
fn heading(src: std.builtin.SourceLocation, title: []const u8, icon: []const u8) void {
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 10 } });
    defer row.deinit();
    glyph(src, icon);
    _ = dvui.label(src, "{s}", .{title}, .{ .id_extra = 1, .font = dvui.themeGet().font_heading, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.text_primary } });
}
fn metric(index: usize, label: []const u8, value: u64, icon: []const u8, bytes: bool) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = index, .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.colors.bg_surface }, .padding = dvui.Rect.all(14), .margin = dvui.Rect.all(3), .corners = theme.dims.rad_sm });
    defer box.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    glyph(@src(), icon);
    c.bodyText(@src(), label, theme.colors.text_secondary);
    row.deinit();
    var font = dvui.themeGet().font_heading;
    font.size = theme.font_size.title * 1.25;
    var buffer: [64]u8 = undefined;
    const text = if (bytes) (if (value >= 1024 * 1024 * 1024) std.fmt.bufPrint(&buffer, "{d:.1} GB", .{@as(f64, @floatFromInt(value)) / (1024 * 1024 * 1024)}) else if (value >= 1024 * 1024) std.fmt.bufPrint(&buffer, "{d:.1} MB", .{@as(f64, @floatFromInt(value)) / (1024 * 1024)}) else std.fmt.bufPrint(&buffer, "{d:.1} KB", .{@as(f64, @floatFromInt(value)) / 1024})) catch "0 KB" else std.fmt.bufPrint(&buffer, "{d}", .{value}) catch "0";
    _ = dvui.label(@src(), "{s}", .{text}, .{ .font = font, .margin = .{ .y = 8 }, .color_text = .{ .color = theme.colors.text_primary } });
}
fn links(title: []const u8, icon: []const u8, rows: []const state.BrowserLink, empty: []const u8, id: usize) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .padding = dvui.Rect.all(12), .margin = .{ .y = 12, .w = 8 } });
    defer box.deinit();
    heading(@src(), title, icon);
    if (rows.len == 0) c.bodyText(@src(), empty, theme.colors.text_tertiary);
    for (rows[0..@min(rows.len, 8)], 0..) |*link, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal, .margin = .{ .h = 4 } });
        const url = link.url[0..link.url_len];
        const raw_label = if (link.text_len > 0) link.text[0..link.text_len] else @import("../services/browser_pure.zig").urlHost(url);
        var label_buf: [256]u8 = undefined;
        const label = @import("../core/text.zig").safeUtf8Buf(raw_label, &label_buf);
        if (dvui.button(@src(), label, .{}, .{ .id_extra = i, .expand = .horizontal, .max_size_content = dvui.Options.MaxSize.width(@max(48, box.data().contentRect().w - 48)), .color_fill = .{ .color = theme.colors.bg_elevated }, .color_fill_hover = .{ .color = theme.colors.bg_hover }, .color_text = .{ .color = theme.colors.text_primary }, .padding = dvui.Rect.all(8), .corners = theme.dims.rad_sm })) browser.navigate(url);
        if (c.iconButton(@src(), icons.@"arrow-up-right", "Open in new tab", false)) browser.newTab(url);
        row.deinit();
    }
}
pub fn render() void {
    if (@import("builtin").is_test) rendered_for_test = true;
    const available = dvui.parentGet().data().contentRect().w;
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both });
    defer scroll.deinit();
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(if (available < 600) 14 else 28) });
    defer page.deinit();
    var top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 16 } });
    heading(@src(), if (state.app.incognito_mode) "Private browsing" else "Your next stop", if (state.app.incognito_mode) icons.@"eye-off" else icons.compass);
    if (c.iconButton(@src(), icons.@"shield-check", "Privacy and extensions", false)) @import("browser_privacy.zig").openSection(1);
    top.deinit();
    var search = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.colors.bg_elevated }, .border = dvui.Rect.all(1), .color_border = .{ .color = theme.colors.border_subtle }, .corners = theme.dims.rad_sm, .padding = dvui.Rect.all(10), .margin = .{ .h = 18 } });
    glyph(@src(), icons.search);
    var entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &query }, .placeholder = "Search the web or enter an address" }, .{ .expand = .horizontal, .color_fill = .{ .color = theme.colors.bg_elevated }, .color_text = .{ .color = theme.colors.text_primary }, .color_border = .{ .color = theme.colors.border_subtle }, .padding = dvui.Rect.all(4) });
    const submit = entry.enter_pressed;
    if (@import("builtin").is_test) search_bounds_for_test = entry.data().borderRectScale().r;
    entry.deinit();
    const go = c.iconButton(@src(), icons.@"arrow-right", "Go", false);
    search.deinit();
    if (submit or go) {
        var resolved: [2048]u8 = undefined;
        const url = @import("../services/browser_pure.zig").resolveAddress(std.mem.sliceTo(&query, 0), &resolved);
        if (url.len > 0) {
            browser.navigate(url);
            @memset(&query, 0);
        }
    }
    const stats = privacy.stats();
    const columns: usize = if (available >= 1000) 4 else if (available >= 520) 2 else 1;
    const labels = [_][]const u8{ "Reported data", "Ads blocked", "Trackers blocked", "Tracking cookies removed" };
    const values = [_]u64{ stats.bytes, stats.ads, stats.trackers, stats.cookies };
    const glyphs = [_][]const u8{ icons.activity, icons.@"shield-check", icons.@"scan-eye", icons.cookie };
    var index: usize = 0;
    while (index < 4) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = index, .expand = .horizontal });
        for (0..@min(columns, 4 - index)) |n| metric(index + n, labels[index + n], values[index + n], glyphs[index + n], index + n == 0);
        index += columns;
        row.deinit();
    }
    var detail = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 6, .h = 10 } });
    c.bodyText(@src(), "Observed this session. Some sites hide transfer sizes; extension blocks are not included.", theme.colors.text_tertiary);
    if (c.iconButton(@src(), icons.@"rotate-ccw", "Reset session measurements", false)) privacy.resetStats();
    detail.deinit();
    var routes = dvui.box(@src(), .{ .dir = if (available < 640) .vertical else .horizontal }, .{ .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.colors.bg_surface }, .corners = theme.dims.rad_sm, .padding = dvui.Rect.all(12) });
    glyph(@src(), icons.route);
    c.bodyText(@src(), switch (privacy.prefs.proxy_mode) {
        .system => "System connection",
        .tor => if (privacy.api.opal_security_tor_status() == 2) "Connected through Tor" else "Tor: traffic blocked until connected",
        .pool => if (privacy.api.opal_security_pool_count() > 0) "Verified proxy pool" else "Proxy pool: no verified exits",
        else => "Proxy connection",
    }, theme.colors.text_secondary);
    if (c.actionButton(@src(), "Connection", .secondary, 72100)) @import("browser_privacy.zig").openSection(2);
    if (c.iconButton(@src(), icons.@"eye-off", if (state.app.incognito_mode) "Leave private browsing (closes browser tabs)" else "Enter private browsing (closes browser tabs)", state.app.incognito_mode)) {
        state.app.incognito_mode = !state.app.incognito_mode;
        @memset(&query, 0);
        browser.newTab("");
    }
    routes.deinit();
    if (state.app.incognito_mode) c.bodyText(@src(), "Pages visited here are not added to history. Downloads and bookmarks you save remain.", theme.colors.text_secondary);
    var lists = dvui.box(@src(), .{ .dir = if (available < 760) .vertical else .horizontal }, .{ .expand = .horizontal });
    links("Bookmarks", icons.bookmark, browser.bookmarksForStart(), "Use the bookmark button on a page to save it here.", 72101);
    links("Recents", icons.history, browser.recentsForStart(), if (state.app.incognito_mode) "Recents stay hidden in private browsing." else "Your recently visited pages will appear here.", 72102);
    lists.deinit();
}
