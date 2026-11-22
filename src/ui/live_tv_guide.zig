//! Live TV "Guide" view (native) — the programme-guide surface of the Live TV
//! tab: opt-in XMLTV source, guide health, now/next cards for favourite and
//! recent channels, programme search, and the channel-mapping editor.
//!
//! Every decision (parsing, matching, time maths, staleness) is in epg_pure via
//! services/epg.zig; this file only draws and dispatches. UI-thread only.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const components = @import("components.zig");
const state = @import("../core/state.zig");
const io = @import("../core/io_global.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;
const epg = @import("../services/epg.zig");
const epg_pure = @import("../services/epg_pure.zig");
const pure = @import("../services/iptv_pure.zig");
const iptv_store = @import("../services/iptv_store.zig");
const catalog = @import("../services/iptv_catalog.zig");

var source_buf: [1024]u8 = std.mem.zeroes([1024]u8);
var source_loaded = false;
var query_buf: [128]u8 = std.mem.zeroes([128]u8);
var map_channel_buf: [160]u8 = std.mem.zeroes([160]u8);
var map_guide_buf: [64]u8 = std.mem.zeroes([64]u8);
var notice: [160]u8 = undefined;
var notice_len: usize = 0;

/// Snapshot of favourites + recents for the now/next cards. Reloaded when the
/// view opens or the guide changes (not per frame — it is a DB read).
const MAX_CARDS: usize = 24;
var cards: [MAX_CARDS]pure.IptvChannel = undefined;
var card_count: usize = 0;
var cards_gen: u32 = std.math.maxInt(u32);

var hits: [40]epg.Hit = undefined;
var hit_count: usize = 0;
var hits_query: [128]u8 = undefined;
var hits_query_len: usize = 0;
var hits_gen: u32 = std.math.maxInt(u32);

fn setNotice(msg: []const u8) void {
    notice_len = @min(msg.len, notice.len);
    @memcpy(notice[0..notice_len], msg[0..notice_len]);
}

fn label(text: []const u8, id: usize, color: dvui.Color) void {
    var safe: [320]u8 = undefined;
    _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(text, &safe)}, .{
        .id_extra = id,
        .color_text = .{ .color = color },
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
    });
}

/// Reload the card list and source field when the Guide chip is (re)opened.
var seen_epoch: u32 = std.math.maxInt(u32);

fn invalidate() void {
    cards_gen = std.math.maxInt(u32);
    source_loaded = false;
}

fn reloadCards() void {
    card_count = iptv_store.loadInto(.fav, cards[0..]);
    if (card_count < MAX_CARDS) {
        var recent: [MAX_CARDS]pure.IptvChannel = undefined;
        const n = iptv_store.loadInto(.recent, recent[0..]);
        outer: for (recent[0..n]) |*r| {
            if (card_count >= MAX_CARDS) break;
            for (cards[0..card_count]) |*c| {
                if (std.mem.eql(u8, c.url[0..c.url_len], r.url[0..r.url_len])) continue :outer;
            }
            cards[card_count] = r.*;
            card_count += 1;
        }
    }
}

pub fn render() void {
    const epoch = @import("../services/iptv.zig").guide_view_epoch;
    if (epoch != seen_epoch) {
        seen_epoch = epoch;
        invalidate();
    }
    epg.tick();
    if (!source_loaded) {
        @memset(&source_buf, 0);
        _ = epg.sourceText(source_buf[0 .. source_buf.len - 1]);
        source_loaded = true;
    }
    const gen = epg.currentGeneration();
    if (gen != cards_gen) {
        reloadCards();
        cards_gen = gen;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = theme.colors.bg_surface },
    });
    defer scroll.deinit();
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(theme.spacing.md) });
    defer col.deinit();

    renderSource();
    const st = epg.status();
    if (st.programmes == 0) {
        if (!st.enabled) {
            components.emptyState(icons.tvg.lucide.@"calendar-clock", "Programme guide is off", "Paste an XMLTV guide URL (.xml or .xml.gz) or a local file path above. Nothing is downloaded until you import one.");
        } else if (st.importing) {
            components.loadingState("Importing the programme guide");
        }
        return;
    }
    renderNowNext();
    renderSearch();
    renderMapping();
}

fn renderSource() void {
    components.sectionHeader("Programme guide");
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        const entered = components.toolbarSearch(@src(), source_buf[0 .. source_buf.len - 1], "XMLTV guide URL or file path", 420);
        const st = epg.status();
        const busy = st.importing;
        if ((components.actionButton(@src(), if (st.enabled) "Replace" else "Import", .primary, 91001) or entered) and !busy) {
            const text = std.mem.sliceTo(&source_buf, 0);
            if (epg.importSource(text)) |_| {
                setNotice("Importing guide");
            } else |err| setNotice(switch (err) {
                error.InvalidSource => "Enter an http(s) URL or an absolute file path",
                error.Busy => "An import is already running",
                error.SpawnFailed => "Could not start the import",
            });
        }
        if (st.enabled and !busy and components.iconActionButton(@src(), icons.tvg.lucide.@"refresh-cw", "Refresh", .secondary, 91002)) {
            epg.refresh() catch setNotice("Could not refresh the guide");
        }
        if (st.enabled and components.confirmDangerButton(@src(), "Remove guide", 91003)) {
            epg.clearGuide();
            @memset(&source_buf, 0);
            setNotice("Guide removed; channel mappings kept");
        }
    }

    const st = epg.status();
    var line_buf: [200]u8 = undefined;
    if (st.importing) {
        components.statusPill("Importing guide", .info);
    } else if (st.programmes > 0) {
        const now = io.timestamp();
        var upd_buf: [24]u8 = undefined;
        const updated = epg.dayClock(st.fetched_at, now, &upd_buf);
        const line = std.fmt.bufPrint(&line_buf, "{d} channels · {d} programmes · updated {s}", .{ st.channels, st.programmes, updated }) catch "";
        label(line, 91010, theme.colors.text_secondary);
        components.statusPill(st.freshness.label(), switch (st.freshness) {
            .fresh => .success,
            .stale => .warn,
            .expired, .empty => .err,
        });
        if (st.freshness != .fresh and !st.importing) {
            label("Listings may be out of date. Refresh, or check the guide provider.", 91011, theme.colors.warning);
        }
    }
    if (st.err_len > 0) label(st.errSlice(), 91012, theme.colors.danger);
    if (notice_len > 0) label(notice[0..notice_len], 91013, theme.colors.text_secondary);
}

fn playChannel(ch: *const pure.IptvChannel) void {
    @import("../services/iptv.zig").playRecord(ch.*);
}

fn renderNowNext() void {
    components.sectionHeader("On now");
    if (card_count == 0) {
        label("Star channels in the All view to see what is on them here.", 91020, theme.colors.text_secondary);
        return;
    }
    const now = io.timestamp();
    var grid = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
    defer grid.deinit();
    for (cards[0..card_count], 0..) |*ch, i| {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .min_size_content = .{ .w = 260, .h = 0 },
            .max_size_content = .{ .w = 260, .h = std.math.floatMax(f32) },
            .background = true,
            .color_fill = .{ .color = theme.colors.bg_elevated },
            .corners = theme.dims.rad_md,
            .padding = dvui.Rect.all(theme.spacing.sm),
            .margin = dvui.Rect.all(theme.spacing.xs),
        });
        defer card.deinit();

        const name = ch.name[0..@min(ch.name_len, ch.name.len)];
        {
            var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer head.deinit();
            label(name, 1000 + i, theme.colors.text_primary);
            const url = ch.url[0..@min(ch.url_len, ch.url.len)];
            if (@import("../services/iptv.zig").channelHealth(url) == .dead) components.statusPill("Offline", .err);
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            if (components.iconButton(@src(), icons.tvg.lucide.play, "Watch", false)) playChannel(ch);
        }
        const info = epg.nowNextFor(ch, now);
        if (info == null or (info.?.now == null and info.?.next == null)) {
            label("No listings. Map this channel below.", 2000 + i, theme.colors.text_tertiary);
            continue;
        }
        if (info.?.now) |slot| {
            var a: [8]u8 = undefined;
            var b: [8]u8 = undefined;
            var buf: [200]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{s}-{s}  {s}", .{ epg.clock(slot.start, &a), epg.clock(slot.stop, &b), slot.titleSlice() }) catch slot.titleSlice();
            label(t, 3000 + i, theme.colors.accent);
            components.ProgressBar(@src(), epg_pure.progress(slot.start, slot.stop, now), "", 4000 + i);
        }
        if (info.?.next) |slot| {
            var a: [24]u8 = undefined;
            var buf: [200]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "Next {s}  {s}", .{ epg.dayClock(slot.start, now, &a), slot.titleSlice() }) catch slot.titleSlice();
            label(t, 5000 + i, theme.colors.text_secondary);
        }
    }
}

fn renderSearch() void {
    components.sectionHeader("Find a programme");
    _ = components.toolbarSearch(@src(), query_buf[0 .. query_buf.len - 1], "Search titles and descriptions", 360);
    const q = std.mem.sliceTo(&query_buf, 0);
    const gen = epg.currentGeneration();
    if (!std.mem.eql(u8, q, hits_query[0..hits_query_len]) or gen != hits_gen) {
        hits_query_len = @min(q.len, hits_query.len);
        @memcpy(hits_query[0..hits_query_len], q[0..hits_query_len]);
        hits_gen = gen;
        hit_count = if (q.len >= 2) epg.search(q, io.timestamp(), &hits) else 0;
    }
    if (q.len >= 2 and hit_count == 0) {
        label("No upcoming programmes match.", 91030, theme.colors.text_secondary);
        return;
    }
    const now = io.timestamp();
    for (hits[0..hit_count], 0..) |*h, i| {
        var when: [24]u8 = undefined;
        var line: [320]u8 = undefined;
        const on_air = h.slot.start <= now and now < h.slot.stop;
        const text = std.fmt.bufPrint(&line, "{s}  {s}  ·  {s}", .{
            if (on_air) "On now" else epg.dayClock(h.slot.start, now, &when),
            h.slot.titleSlice(),
            h.chanNameSlice(),
        }) catch h.slot.titleSlice();
        var safe: [320]u8 = undefined;
        if (components.listItem(@src(), 6000 + i, icons.tvg.lucide.tv, safeUtf8Buf(text, &safe), "")) {
            playGuideChannel(h.chanIdSlice(), h.chanNameSlice());
        }
    }
}

/// Resolve a guide channel back to a playable catalog channel: by guide id,
/// then by the guide's display name.
fn playGuideChannel(guide_id: []const u8, guide_name: []const u8) void {
    const nsfw_allowed = !state.app.nsfw_filter_enabled;
    if (catalog.findByChanId(guide_id, nsfw_allowed)) |ch| return @import("../services/iptv.zig").playRecord(ch);
    var lc: [96]u8 = undefined;
    const n = @min(guide_name.len, lc.len);
    for (guide_name[0..n], 0..) |c, k| lc[k] = std.ascii.toLower(c);
    if (catalog.findByNameLc(lc[0..n], nsfw_allowed)) |ch| return @import("../services/iptv.zig").playRecord(ch);
    state.showToast("No playlist channel carries this programme. Map one below.");
}

fn renderMapping() void {
    components.sectionHeader("Channel mapping");
    label("Most channels match the guide by tvg-id or name. Fix the rest here: type the channel as it appears in your playlist and pick its guide channel.", 91040, theme.colors.text_secondary);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        _ = components.toolbarSearch(@src(), map_channel_buf[0 .. map_channel_buf.len - 1], "Playlist channel name", 220);
        _ = components.toolbarSearch(@src(), map_guide_buf[0 .. map_guide_buf.len - 1], "Guide channel id", 200);
        if (components.actionButton(@src(), "Save mapping", .primary, 91041)) {
            const ch = std.mem.trim(u8, std.mem.sliceTo(&map_channel_buf, 0), " ");
            const gid = std.mem.trim(u8, std.mem.sliceTo(&map_guide_buf, 0), " ");
            if (ch.len == 0 or gid.len == 0) {
                setNotice("Enter both the channel and the guide id");
            } else if (epg.setMapping("", ch, gid, ch)) {
                setNotice("Mapping saved");
                @memset(&map_channel_buf, 0);
                @memset(&map_guide_buf, 0);
            } else setNotice("Could not save the mapping");
        }
    }
    // Suggestions: guide channels matching what is typed in either field.
    const typed_guide = std.mem.sliceTo(&map_guide_buf, 0);
    const typed_channel = std.mem.sliceTo(&map_channel_buf, 0);
    const probe = if (typed_guide.len > 0) typed_guide else typed_channel;
    if (probe.len >= 2) {
        var sugg: [6]epg.ChannelHit = undefined;
        const n = epg.guideChannels(probe, &sugg);
        var flex = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
        defer flex.deinit();
        for (sugg[0..n], 0..) |*s, i| {
            var b: [180]u8 = undefined;
            const t = std.fmt.bufPrint(&b, "{s} ({s})", .{ s.nameSlice(), s.idSlice() }) catch s.idSlice();
            var safe: [180]u8 = undefined;
            if (components.actionButton(@src(), safeUtf8Buf(t, &safe), .secondary, 92000 + i)) {
                @memset(&map_guide_buf, 0);
                const gid = s.idSlice();
                @memcpy(map_guide_buf[0..@min(gid.len, map_guide_buf.len - 1)], gid[0..@min(gid.len, map_guide_buf.len - 1)]);
            }
        }
    }
    var rows: [epg.MAX_MAPPINGS]epg.Mapping = undefined;
    const n = epg.mappings(&rows);
    for (rows[0..@min(n, 50)], 0..) |*m, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
        defer row.deinit();
        var b: [200]u8 = undefined;
        const t = std.fmt.bufPrint(&b, "{s}  ·  {s}", .{ if (m.label_len > 0) m.labelSlice() else m.keySlice(), m.guideSlice() }) catch m.keySlice();
        label(t, 7000 + i, theme.colors.text_primary);
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (components.iconButton(@src(), icons.tvg.lucide.x, "Remove mapping", false)) {
            _ = epg.removeMappingKey(m.keySlice());
            break;
        }
    }
}
