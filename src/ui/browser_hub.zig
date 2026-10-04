//! Browse > Web: the Browser hub.
//!
//! The page is no longer a remote desktop. It is where the user's own browser
//! (through the Opal Connect extension) meets Opal: which browsers are paired
//! and when they were last seen, the page the user chose to share, and the
//! streams the browser found on it, each with Play and Queue. The old pixel
//! bridge is still here, behind "Advanced: built-in browser", unchanged.
//!
//! Nothing here reads a page by itself: the shared page exists only because the
//! user pressed the button in the extension, and Dismiss forgets it. Everything
//! drawn from it is untrusted text, shown clipped and as plain labels.
//!
//! Rows are fixed-size and drawn from a snapshot, so a page title or a stream
//! URL cannot change a row's height; wording is in browser_hub_view_pure.zig.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");
const state = @import("../core/state.zig");
const io_global = @import("../core/io_global.zig");
const link = @import("../services/browser_link.zig");
const link_pure = @import("../services/browser_link_pure.zig");
const shared = @import("../services/browser_page.zig");
const view_pure = @import("../services/browser_hub_view_pure.zig");
const wanted = @import("../services/wanted.zig");
const wanted_pure = @import("../services/wanted_pure.zig");

const ROW_H: f32 = 34;

var links: [link_pure.MAX_LINKS]link.Link = undefined;
var link_count: usize = 0;
var last_load_ms: i64 = 0;
var page: shared.UiView = .{};
var seen_page_id: u32 = 0;
var title_buf: [link_pure.MAX_TITLE + 1]u8 = std.mem.zeroes([link_pure.MAX_TITLE + 1]u8);
var message_buf: [160]u8 = undefined;
var message_len: usize = 0;
var show_bridge = false;

/// Offline pixel tests render fixed data instead of reading the database and
/// the shared-page store.
pub const Fixture = struct {
    links: []const link.Link = &.{},
    page: shared.UiView = .{},
    pairing: link.PairingView = .{},
    now: i64 = 0,
};
var fixture_for_test: ?Fixture = null;

pub fn setRenderFixtureForTest(fixture: ?Fixture) void {
    fixture_for_test = fixture;
    seen_page_id = 0;
    message_len = 0;
    show_bridge = false;
    last_load_ms = 0;
}

/// A navigation that must land in the pixel bridge (a typed web address, "B")
/// calls this, so the hub never hides a page the user asked for.
pub fn showBridge() void {
    show_bridge = true;
}

fn say(text: []const u8) void {
    message_len = @min(text.len, message_buf.len);
    @memcpy(message_buf[0..message_len], text[0..message_len]);
}

fn refresh() void {
    if (@import("builtin").is_test) {
        if (fixture_for_test) |f| {
            link_count = @min(f.links.len, links.len);
            @memcpy(links[0..link_count], f.links[0..link_count]);
            page = f.page;
            syncTitle();
            return;
        }
    }
    const now = io_global.milliTimestamp();
    if (now - last_load_ms >= 1500) {
        last_load_ms = now;
        link_count = link.list(&links);
    }
    shared.uiView(&page);
    syncTitle();
}

/// A newly shared page puts its title in the editable box once; edits stick
/// until the next share.
fn syncTitle() void {
    if (!page.present) {
        seen_page_id = 0;
        return;
    }
    if (page.page_id == seen_page_id) return;
    seen_page_id = page.page_id;
    @memset(&title_buf, 0);
    const t = page.titleSlice();
    const n = @min(t.len, title_buf.len - 1);
    @memcpy(title_buf[0..n], t[0..n]);
    message_len = 0;
}

// ── Actions ──

fn addToWanted() void {
    const text = std.mem.sliceTo(&title_buf, 0);
    const parsed = wanted_pure.parseRequest(text) orelse {
        say("Type a title first, e.g. Dune 2021 or Severance S02E03");
        return;
    };
    switch (wanted.add(.{ .kind = parsed.kind, .title = parsed.title, .year = parsed.year, .season = parsed.season, .episode = parsed.episode })) {
        .added => say("Added to Wanted. Opal will search and download it."),
        .exists => say("Already on the Wanted list"),
        .invalid => |why| say(why),
        .full => say("The Wanted list is full"),
        .unavailable => say("Not available right now"),
    }
    state.wakeUi();
}

fn findSources() void {
    const text = std.mem.trim(u8, std.mem.sliceTo(&title_buf, 0), " ");
    if (text.len == 0) {
        say("Type a title first");
        return;
    }
    state.navigateToTab(.Search);
    @import("../services/search.zig").submitQuery(text);
    state.showToast("Searching all sources...");
}

fn playCandidate(c: *const shared.UiCand, queue_only: bool) void {
    _ = shared.playFromUi(page.page_id, c.id, queue_only) catch |e| {
        state.showToastTyped(switch (e) {
            error.stale, error.not_shared => "That page was replaced: share it again",
            error.missing => "That stream is not available",
            error.busy => "Opal is busy opening other media, try again",
        }, .warning);
        return;
    };
    if (queue_only) {
        state.showToastTyped("Queued", .success);
    } else {
        state.showToastTyped("Playing", .success);
    }
}

// ── Drawing ──

fn smallFont() dvui.Font {
    var f = dvui.themeGet().font_body;
    f.size = theme.font_size.small;
    return f;
}

fn cardBox(src: std.builtin.SourceLocation, id_extra: usize) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 14, .y = 10, .w = 14, .h = 10 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 10 },
    });
}

fn cardTitle(src: std.builtin.SourceLocation, text: []const u8) void {
    _ = dvui.label(src, "{s}", .{text}, .{
        .color_text = theme.colors.text_primary,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });
}

/// Wrapped text. A plain dvui.label never wraps, so a long sentence would push
/// the whole card wider than the window.
fn note(src: std.builtin.SourceLocation, text: []const u8, color: dvui.Color) void {
    var tl = dvui.textLayout(src, .{ .break_lines = true }, .{
        .expand = .horizontal,
        .background = false,
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 4 },
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    defer tl.deinit();
    tl.addText(text, .{ .color_text = color });
}

fn nowSeconds() i64 {
    if (@import("builtin").is_test) {
        if (fixture_for_test) |f| if (f.now != 0) return f.now;
    }
    return io_global.timestamp();
}

fn pairingNow() link.PairingView {
    if (@import("builtin").is_test) {
        if (fixture_for_test) |f| return f.pairing;
    }
    return link.pairingView();
}

fn renderBrowsers() void {
    var card = cardBox(@src(), 0);
    defer card.deinit();
    cardTitle(@src(), "Your browsers");

    if (!state.app.web_remote_enabled) {
        note(@src(), "Opal Connect reaches Opal through its local API: turn on \"Allow coding agents\" in Settings > Agent Access first.", theme.colors.warning);
    }

    const now = nowSeconds();
    for (links[0..link_count], 0..) |*row, i| {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = ROW_H },
            .max_size_content = .{ .w = 100000, .h = ROW_H },
        });
        defer line.deinit();
        var seen_buf: [48]u8 = undefined;
        const seen = view_pure.seenText(&seen_buf, now, row.last_seen);
        const live = std.mem.eql(u8, seen, "connected");
        var name_buf: [96]u8 = undefined;
        const name = view_pure.clip(&name_buf, row.labelSlice(), 40);
        _ = dvui.label(@src(), "{s}", .{name}, .{ .id_extra = i, .color_text = theme.colors.text_primary, .gravity_y = 0.5 });
        _ = dvui.label(@src(), "{s}, {s}", .{ row.browserSlice(), seen }, .{
            .id_extra = i,
            .color_text = if (live) theme.colors.success else theme.colors.text_secondary,
            .gravity_y = 0.5,
            .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
        });
    }

    if (link_count == 0) {
        note(@src(), "No browser is paired yet. Opal Connect is the extension that links your own browser to Opal. Install it from the extension folder of your Opal checkout (build steps in extension/README.md): on Chrome or Edge open chrome://extensions, turn on Developer mode and choose Load unpacked; on Firefox open about:debugging and Load Temporary Add-on. Then press Pair a browser below and type the code on the extension's setup page.", theme.colors.text_secondary);
    }

    const view = pairingNow();
    if (view.active) {
        if (!@import("builtin").is_test) {
            // Re-arm once a second so the countdown moves under the gated frame loop.
            const tick_id = card.data().id;
            if (dvui.timerDoneOrNone(tick_id)) dvui.timer(tick_id, 1_000_000);
        }
        var big = dvui.themeGet().font_body;
        big.size = theme.font_size.title * 1.6;
        _ = dvui.label(@src(), "{s}", .{view.code[0..]}, .{
            .color_text = theme.colors.text_primary,
            .font = big,
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 2 },
        });
        note(@src(), "Type this code on the extension's setup page. It expires in a couple of minutes and five wrong tries cancel it.", theme.colors.text_secondary);
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 } });
        defer row.deinit();
        if (components.actionButton(@src(), if (view.active) "New code" else "Pair a browser", .primary, 31000)) {
            if (!link.startPairing()) state.showToast("No entropy source: could not make a code");
        }
        if (view.active and components.actionButton(@src(), "Cancel", .secondary, 31001)) link.cancelPairing();
    }
}

fn renderSharedPage() void {
    var card = cardBox(@src(), 1);
    defer card.deinit();
    cardTitle(@src(), "Shared page");

    if (!page.present) {
        note(@src(), "Nothing shared. In your browser, open the Opal panel and press \"Share this page with Opal\". Only the page you share is sent, and only when you press it.", theme.colors.text_secondary);
        return;
    }

    var clip_buf: [200]u8 = undefined;
    _ = dvui.label(@src(), "{s}", .{view_pure.clip(&clip_buf, page.titleSlice(), 80)}, .{
        .color_text = theme.colors.text_primary,
        .min_size_content = .{ .w = 0, .h = 20 },
    });
    var where_buf: [200]u8 = undefined;
    _ = dvui.label(@src(), "{s}", .{view_pure.clip(&where_buf, page.whereSlice(), 90)}, .{
        .color_text = theme.colors.text_secondary,
        .font = smallFont(),
    });
    var size_buf: [32]u8 = undefined;
    var info_buf: [256]u8 = undefined;
    note(@src(), std.fmt.bufPrint(&info_buf, "{s}. {s}", .{ view_pure.textSizeText(&size_buf, page.text_len), view_pure.agentsText(page.agents, state.app.browser_share_agents) }) catch "", theme.colors.text_tertiary);

    _ = dvui.label(@src(), "Title to use (edit it if the page title has extra words)", .{}, .{
        .color_text = theme.colors.text_secondary,
        .font = smallFont(),
    });
    {
        // Fixed size, inside a row, like the other single-line inputs: an
        // expanding text entry in a scrolling column takes the whole column.
        var erow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer erow.deinit();
        if (@import("builtin").is_test and fixture_for_test != null) {
            // The offscreen capture harness loses the rest of the frame behind a
            // text entry here (it is fine in the app), so fixtures draw the same
            // box as a label. Typing is exercised live, not in this test.
            _ = dvui.label(@src(), "{s}", .{if (title_buf[0] == 0) "Movie or show: Dune 2021, Severance S02E03" else std.mem.sliceTo(&title_buf, 0)}, .{
                .min_size_content = .{ .w = 420, .h = components.TOOLBAR_INPUT_H },
                .max_size_content = .{ .w = 420, .h = components.TOOLBAR_INPUT_H },
                .color_fill = theme.colors.bg_elevated,
                .background = true,
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
                .margin = .{ .x = 0, .y = 2, .w = 0, .h = 6 },
            });
        } else {
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &title_buf }, .placeholder = "Movie or show: Dune 2021, Severance S02E03" }, .{
                .min_size_content = .{ .w = 420, .h = components.TOOLBAR_INPUT_H },
                .max_size_content = .{ .w = 420, .h = components.TOOLBAR_INPUT_H },
                .gravity_y = 0.5,
                .color_fill = theme.colors.bg_elevated,
                .color_border = theme.colors.border_subtle,
                .color_text = theme.colors.text_primary,
                .border = dvui.Rect.all(1),
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
                .margin = .{ .x = 0, .y = 2, .w = 0, .h = 6 },
            });
            te.deinit();
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (components.actionButton(@src(), "Add to Wanted", .primary, 31010)) addToWanted();
        if (components.actionButton(@src(), "Find sources", .secondary, 31011)) findSources();
        if (components.actionButton(@src(), "Dismiss", .secondary, 31012)) {
            shared.dismiss();
            page = .{};
            seen_page_id = 0;
            message_len = 0;
        }
    }
    if (message_len > 0) note(@src(), message_buf[0..message_len], theme.colors.text_secondary);
}

fn renderStreams() void {
    var card = cardBox(@src(), 2);
    defer card.deinit();
    var head: [48]u8 = undefined;
    cardTitle(@src(), std.fmt.bufPrint(&head, "Detected streams ({d})", .{if (page.present) page.cand_count else 0}) catch "Detected streams");

    if (!page.present or page.cand_count == 0) {
        note(@src(), if (page.present)
            "No streams came with this page. In the extension turn on Detect media, press play on the page, then share it again."
        else
            "Streams the extension found on the page you share show up here, with Play and Queue.", theme.colors.text_secondary);
        return;
    }
    for (page.cands[0..page.cand_count], 0..) |*c, i| {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = ROW_H },
            .max_size_content = .{ .w = 100000, .h = ROW_H },
        });
        defer line.deinit();
        _ = dvui.label(@src(), "{s}", .{@tagName(c.kind)}, .{
            .id_extra = i,
            .color_text = theme.colors.accent,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 44, .h = 0 },
        });
        var label_buf: [200]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{view_pure.clip(&label_buf, c.labelSlice(), 34)}, .{
            .id_extra = i,
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
        });
        var acts = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .gravity_x = 1.0, .gravity_y = 0.5 });
        defer acts.deinit();
        if (components.actionButton(@src(), "Play", .primary, 31100 + i)) playCandidate(c, false);
        if (components.actionButton(@src(), "Queue", .secondary, 31200 + i)) playCandidate(c, true);
    }
}

fn renderHub() void {
    refresh();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 16 },
    });
    defer col.deinit();

    if (!@import("builtin").is_test) {
        // New shares arrive from the server thread; poll gently so the card appears
        // without a mouse move even when the frame loop is idle.
        const id = col.data().id;
        if (dvui.timerDoneOrNone(id)) dvui.timer(id, 2_000_000);
    }

    _ = dvui.label(@src(), "Browser", .{}, .{ .color_text = theme.colors.text_primary, .font = dvui.Font.theme(.title) });
    note(@src(), "Use your own browser, with your logins and extensions. Opal Connect finds the real stream behind a page and plays it here; share a page to add it to Wanted or find sources for it.", theme.colors.text_secondary);

    renderBrowsers();
    renderSharedPage();
    renderStreams();

    {
        var card = cardBox(@src(), 3);
        defer card.deinit();
        cardTitle(@src(), "Advanced: built-in browser");
        note(@src(), "A browser Opal runs itself and shows as pictures. It has none of your logins and is slower; it exists for sources that block ordinary requests. Needs its own download the first time.", theme.colors.text_secondary);
        if (components.actionButton(@src(), "Open built-in browser", .secondary, 31300)) show_bridge = true;
    }
}

fn renderBridge() void {
    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer root.deinit();
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        });
        defer bar.deinit();
        if (components.actionButton(@src(), "Back to the browser hub", .secondary, 31400)) show_bridge = false;
        _ = dvui.label(@src(), "Built-in browser (advanced)", .{}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5 });
    }
    @import("../services/browser.zig").renderContent();
}

/// Draw the Browse > Web page. Safe to call every frame.
pub fn render() void {
    if (show_bridge) renderBridge() else renderHub();
}
