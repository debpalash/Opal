//! The Wanted section at the top of the Downloads page: what Opal is looking for
//! on its own, with a box to add more. Hidden entirely until there is something
//! to show or the user opens it, so the page stays quiet for people who never
//! use it.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");
const state = @import("../core/state.zig");
const io_global = @import("../core/io_global.zig");
const wanted = @import("../services/wanted.zig");
const pure = @import("../services/wanted_pure.zig");
const icons = @import("icons");

const MAX_ROWS = 24;
var rows: [MAX_ROWS]wanted.Row = undefined;
var row_count: usize = 0;
var last_load_ms: i64 = 0;
var dirty = true;
var expanded = false;
var input_buf: [160]u8 = std.mem.zeroes([160]u8);
var message_buf: [96]u8 = undefined;
var message_len: usize = 0;

/// Offline pixel tests render fixed rows instead of reading the database.
var fixture_for_test: ?[]const wanted.Row = null;

pub fn setRenderFixtureForTest(fixture: ?[]const wanted.Row) void {
    fixture_for_test = fixture;
    dirty = true;
}

fn refresh() void {
    if (@import("builtin").is_test) {
        if (fixture_for_test) |f| {
            row_count = @min(f.len, rows.len);
            @memcpy(rows[0..row_count], f[0..row_count]);
            return;
        }
    }
    const now = io_global.milliTimestamp();
    if (!dirty and now - last_load_ms < 1500) return;
    last_load_ms = now;
    dirty = false;
    row_count = wanted.snapshot(&rows);
}

fn say(text: []const u8) void {
    message_len = @min(text.len, message_buf.len);
    @memcpy(message_buf[0..message_len], text[0..message_len]);
}

fn submit() void {
    const text = std.mem.sliceTo(&input_buf, 0);
    const parsed = pure.parseRequest(text) orelse {
        say("Type a title, e.g. Dune 2021 or Severance S02E03");
        return;
    };
    const res = wanted.add(.{ .kind = parsed.kind, .title = parsed.title, .year = parsed.year, .season = parsed.season, .episode = parsed.episode });
    switch (res) {
        .added => {
            say("Added. Opal will search and download it.");
            @memset(&input_buf, 0);
            dirty = true;
        },
        .exists => say("Already on the list"),
        .invalid => |why| say(why),
        .full => say("The wanted list is full"),
        .unavailable => say("Not available right now"),
    }
    state.wakeUi();
}

var done_open = false;

/// The "Add a title" box (entry, Add button, last result line), shared with the
/// Agents Overview so both add through the same parser and `wanted.add`.
/// `width` is the entry's width in logical pixels.
pub fn renderAddBox(width: f32) void {
    {
        var add_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 } });
        defer add_row.deinit();
        const entered = components.toolbarSearch(@src(), &input_buf, "Movie or show: Dune 2021, Severance S02E03", width);
        if (components.toolbarGo(@src(), "Add") or entered) submit();
    }
    if (message_len > 0) {
        _ = dvui.label(@src(), "{s}", .{message_buf[0..message_len]}, .{ .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary) });
    }
}

/// Draw the section. Safe to call every frame.
pub fn render() void {
    refresh();
    if (row_count == 0 and !expanded) {
        var hint = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 14, .y = 6, .w = 14, .h = 6 },
        });
        defer hint.deinit();
        if (components.actionButton(@src(), "Wanted: have Opal find and download things for you", .secondary, 91000)) expanded = true;
        return;
    }

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.md, .w = theme.spacing.lg, .h = theme.spacing.md },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
    });
    defer card.deinit();

    var done_count: usize = 0;
    for (rows[0..row_count]) |r| {
        if (pure.isDone(r.status)) done_count += 1;
    }
    const active_count = row_count - done_count;

    // Header: title + counts on the left, bulk action on the right.
    {
        var head_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer head_row.deinit();
        var big = dvui.themeGet().font_body;
        big.size = theme.font_size.title;
        _ = dvui.label(@src(), "Wanted", .{}, .{ .font = big, .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary), .gravity_y = 0.5 });
        var sub: [64]u8 = undefined;
        const counts = std.fmt.bufPrint(&sub, "{d} active \u{00B7} {d} done{s}", .{ active_count, done_count, if (wanted.isSearching()) " \u{00B7} searching\u{2026}" else "" }) catch "";
        _ = dvui.label(@src(), "{s}", .{counts}, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.md, .y = 0, .w = 0, .h = 0 },
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
        });
        if (done_count > 0 and components.actionButton(@src(), "Clear done", .secondary, 91010)) {
            for (rows[0..row_count]) |r| {
                if (pure.isDone(r.status)) _ = wanted.remove(r.id);
            }
            dirty = true;
        }
    }

    renderAddBox(420);

    // Active rows first, then the finished ones folded under "Done (N)".
    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        if (!pure.isDone(rows[i].status)) renderRow(i);
    }
    if (active_count == 0) {
        _ = dvui.label(@src(), "Nothing pending. Add a title above and Opal will find it.", .{}, .{
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
            .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
        });
    }
    if (done_count > 0) {
        var toggle = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
        });
        defer toggle.deinit();
        if (components.iconButton(@src(), if (done_open) icons.tvg.lucide.@"chevron-down" else icons.tvg.lucide.@"chevron-right", if (done_open) "Hide finished" else "Show finished", false)) done_open = !done_open;
        var lbl: [32]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{std.fmt.bufPrint(&lbl, "Done ({d})", .{done_count}) catch "Done"}, .{
            .gravity_y = 0.5,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
        });
    }
    if (done_open) {
        i = 0;
        while (i < row_count) : (i += 1) {
            if (pure.isDone(rows[i].status)) renderRow(i);
        }
    }
}

/// One aligned row: title (expands, ellipsised) | status pill | icon actions.
fn renderRow(i: usize) void {
    const r = &rows[i];
    var item = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 91050 + i,
        .expand = .horizontal,
        .background = true,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
        .corners = theme.dims.rad_sm,
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
    });
    defer item.deinit();
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 91100 + i, .expand = .horizontal });
        defer line.deinit();

        var fit: [96]u8 = undefined;
        const title_shown = pure.fitTitle(&fit, r.title[0..r.title_len], 56);
        var name: [160]u8 = undefined;
        const label = switch (r.kind) {
            .episode => std.fmt.bufPrint(&name, "{s}  S{d:0>2}E{d:0>2}", .{ title_shown, r.season, r.episode }) catch title_shown,
            .movie => if (r.year > 0)
                std.fmt.bufPrint(&name, "{s}  ({d})", .{ title_shown, r.year }) catch title_shown
            else
                title_shown,
        };
        _ = dvui.label(@src(), "{s}", .{label}, .{
            .id_extra = 91200 + i,
            .expand = .horizontal,
            .gravity_y = 0.5,
            .color_text = @import("color_compat.zig").wrap(if (pure.isDone(r.status)) theme.colors.text_secondary else theme.colors.text_primary),
        });

        {
            var pill_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 91300 + i, .gravity_y = 0.5, .margin = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.sm, .h = 0 } });
            defer pill_box.deinit();
            var st: [48]u8 = undefined;
            const text = pure.statusText(&st, r.status, r.attempts);
            switch (r.status) {
                .fulfilled => components.statusPill(text, .success),
                .wanted => components.statusPill(text, if (r.attempts == 0) .info else .warn),
                .downloading, .paused => components.statusPill(text, .info),
            }
        }

        // Fixed-width action column so every row's icons line up.
        var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 91400 + i, .gravity_y = 0.5, .min_size_content = .{ .w = 96, .h = 0 } });
        defer actions.deinit();
        if (r.status == .wanted and components.iconButton(@src(), icons.tvg.lucide.search, "Search now", false)) {
            _ = wanted.checkNow(r.id);
            dirty = true;
        }
        if (r.status == .wanted and components.iconButton(@src(), icons.tvg.lucide.pause, "Pause", false)) {
            _ = wanted.pause(r.id);
            dirty = true;
        }
        if (r.status == .paused and components.iconButton(@src(), icons.tvg.lucide.play, "Resume", false)) {
            _ = wanted.resume_(r.id);
            dirty = true;
        }
        if (components.iconButton(@src(), icons.tvg.lucide.x, "Remove from Wanted", false)) {
            _ = wanted.remove(r.id);
            dirty = true;
        }
    }
    if (r.status == .downloading and r.picked_len > 0) {
        var pk: [96]u8 = undefined;
        var small = dvui.themeGet().font_body;
        small.size = theme.font_size.small;
        _ = dvui.label(@src(), "{s}", .{pure.fitTitle(&pk, r.picked[0..@min(r.picked_len, r.picked.len)], 80)}, .{
            .id_extra = 91850 + i,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
            .font = small,
        });
    }
    var extra_buf: [200]u8 = undefined;
    const extra = pure.alsoSearchingText(&extra_buf, r.extra_titles[0..@min(r.extra_titles_len, r.extra_titles.len)]);
    if (extra.len > 0) {
        var small = dvui.themeGet().font_body;
        small.size = theme.font_size.small;
        _ = dvui.label(@src(), "{s}", .{extra}, .{
            .id_extra = 91900 + i,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
            .font = small,
        });
    }
}
