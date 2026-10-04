//! The Wanted section at the top of the Downloads page: what Opal is looking for
//! on its own, with a box to add more. Hidden entirely until there is something
//! to show or the user opens it, so the page stays quiet for people who never
//! use it.

const std = @import("std");
const dvui = @import("dvui");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const state = @import("../core/state.zig");
const io_global = @import("../core/io_global.zig");
const wanted = @import("wanted.zig");
const pure = @import("wanted_pure.zig");

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

fn statusColor(s: pure.Status) dvui.Color {
    return switch (s) {
        .fulfilled => theme.colors.success,
        .downloading => theme.colors.accent,
        .paused => theme.colors.text_secondary,
        .wanted => theme.colors.text_primary,
    };
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
        .padding = .{ .x = 14, .y = 8, .w = 14, .h = 8 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .color_border = theme.colors.border_subtle,
    });
    defer card.deinit();

    var head: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&head, "Wanted ({d}){s}", .{ row_count, if (wanted.isSearching()) "  searching…" else "" }) catch "Wanted";
    _ = dvui.label(@src(), "{s}", .{title}, .{ .color_text = theme.colors.text_primary });

    {
        var add_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 } });
        defer add_row.deinit();
        const entered = components.toolbarSearch(@src(), &input_buf, "Movie or show: Dune 2021, Severance S02E03", 360);
        if (components.toolbarGo(@src(), "Add") or entered) submit();
    }
    if (message_len > 0) {
        _ = dvui.label(@src(), "{s}", .{message_buf[0..message_len]}, .{ .color_text = theme.colors.text_secondary });
    }

    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const r = &rows[i];
        // One item: the main line, then (when the operator found other titles) a
        // quiet second line naming what else is being searched.
        var item = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = 91050 + i, .expand = .horizontal });
        defer item.deinit();
        {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 91100 + i, .expand = .horizontal, .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 } });
            defer line.deinit();

            var name: [160]u8 = undefined;
            const title_shown = r.title[0..@min(r.title_len, 40)];
            const label = switch (r.kind) {
                .episode => std.fmt.bufPrint(&name, "{s} S{d:0>2}E{d:0>2}", .{ title_shown, r.season, r.episode }) catch title_shown,
                .movie => if (r.year > 0)
                    std.fmt.bufPrint(&name, "{s} ({d})", .{ title_shown, r.year }) catch title_shown
                else
                    title_shown,
            };
            _ = dvui.label(@src(), "{s}", .{label}, .{ .id_extra = 91200 + i, .color_text = theme.colors.text_primary, .gravity_y = 0.5 });

            var detail: [160]u8 = undefined;
            const text = switch (r.status) {
                .wanted => if (r.attempts == 0) "  waiting for first search" else std.fmt.bufPrint(&detail, "  not found yet, tried {d}x", .{r.attempts}) catch "  searching",
                .downloading => blk: {
                    const picked = r.picked[0..@min(r.picked_len, 18)];
                    const more: []const u8 = if (r.picked_len > 18) "…" else "";
                    break :blk std.fmt.bufPrint(&detail, "  downloading {s}{s}", .{ picked, more }) catch "  downloading";
                },
                .fulfilled => "  done",
                .paused => "  paused",
            };
            _ = dvui.label(@src(), "{s}", .{text}, .{ .id_extra = 91300 + i, .color_text = statusColor(r.status), .gravity_y = 0.5, .margin = .{ .x = 0, .y = 0, .w = 16, .h = 0 } });

            if (r.status == .wanted and components.actionButton(@src(), "Find", .secondary, 91500 + i)) {
                _ = wanted.checkNow(r.id);
                dirty = true;
            }
            if (r.status == .wanted and components.actionButton(@src(), "Pause", .secondary, 91600 + i)) {
                _ = wanted.pause(r.id);
                dirty = true;
            }
            if (r.status == .paused and components.actionButton(@src(), "Resume", .secondary, 91700 + i)) {
                _ = wanted.resume_(r.id);
                dirty = true;
            }
            if (components.actionButton(@src(), "Remove", .secondary, 91800 + i)) {
                _ = wanted.remove(r.id);
                dirty = true;
            }
        }
        var extra_buf: [200]u8 = undefined;
        const extra = pure.alsoSearchingText(&extra_buf, r.extra_titles[0..@min(r.extra_titles_len, r.extra_titles.len)]);
        if (extra.len > 0) {
            var small = dvui.themeGet().font_body;
            small.size = theme.font_size.small;
            _ = dvui.label(@src(), "{s}", .{extra}, .{
                .id_extra = 91900 + i,
                .color_text = theme.colors.text_secondary,
                .font = small,
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 3 },
            });
        }
    }
}
