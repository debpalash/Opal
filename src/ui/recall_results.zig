//! Universal search › "From your library" and "Moments" (ROADMAP 7.1 Recall).
//!
//! Drawn above the source results when the query is natural language or
//! carries constraints (recall_pure.wantsRecall). Results come from the
//! recall worker (services/recall.zig submit/snapshot); this file only paints
//! them and routes clicks. Every widget uses the themed component helpers and
//! reads theme colors per frame.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const components = @import("components.zig");
const recall = @import("../services/recall.zig");
const pure = @import("../services/recall_pure.zig");
const library_pure = @import("../services/library_pure.zig");

// UI-thread scratch copy of the published results (~20 KB, kept off the stack).
var frame_results: recall.Results = .{};

fn kindIcon(kind: pure.Kind) []const u8 {
    return switch (kind) {
        .music => icons.tvg.lucide.music,
        .podcast => icons.tvg.lucide.podcast,
        .book, .comic => icons.tvg.lucide.@"book-open",
        .movie, .show, .anime => icons.tvg.lucide.film,
        else => icons.tvg.lucide.@"library-big",
    };
}

fn heading(icon: []const u8, label: []const u8, detail: []const u8, id: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.xs },
    });
    defer row.deinit();
    dvui.icon(@src(), label, icon, .{}, .{
        .id_extra = id,
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
        .gravity_y = 0.5,
    });
    if (detail.len > 0) {
        _ = dvui.label(@src(), "{s}", .{detail}, .{
            .id_extra = id + 1,
            .color_text = theme.colors.text_tertiary,
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
        });
    }
}

fn docMeta(d: *const recall.Doc, out: []u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    w.writeAll(@tagName(d.kind)) catch {};
    if (d.year > 0) w.print(" \u{b7} {d}", .{d.year}) catch {};
    if (d.runtime_secs >= 60) {
        const mins = d.runtime_secs / 60;
        if (mins >= 60) w.print(" \u{b7} {d}h {d:0>2}m", .{ mins / 60, mins % 60 }) catch {} else w.print(" \u{b7} {d} min", .{mins}) catch {};
    }
    if (d.percent >= pure.WATCHED_PCT) {
        w.writeAll(" \u{b7} watched") catch {};
    } else if (d.percent >= pure.STARTED_PCT) {
        w.print(" \u{b7} {d:.0}% watched", .{d.percent}) catch {};
    }
    if (d.favorite) w.writeAll(" \u{b7} favorite") catch {};
    return w.buffered();
}

/// One result row: kind icon, title + meta, optional snippet, trailing action.
/// Returns true when the action was clicked.
fn resultRow(id: usize, icon: []const u8, title: []const u8, meta: []const u8, snippet: []const u8, action: []const u8) bool {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.xs, .h = theme.spacing.xs },
        .margin = .{ .x = theme.spacing.sm, .y = 2, .w = theme.spacing.sm, .h = 2 },
    });
    defer row.deinit();
    dvui.icon(@src(), "kind", icon, .{}, .{
        .id_extra = id,
        .color_text = theme.colors.text_secondary,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });
    var clicked = false;
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .gravity_y = 0.5 });
        defer col.deinit();
        _ = dvui.label(@src(), "{s}", .{title}, .{ .id_extra = id, .color_text = theme.colors.text_primary });
        if (meta.len > 0) _ = dvui.label(@src(), "{s}", .{meta}, .{ .id_extra = id, .color_text = theme.colors.text_tertiary });
        if (snippet.len > 0) {
            var tl = dvui.textLayout(@src(), .{ .break_lines = true }, .{
                .id_extra = id,
                .expand = .horizontal,
                .background = false,
                .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            });
            tl.addText(snippet, .{ .color_text = theme.colors.text_secondary });
            tl.deinit();
        }
    }
    {
        var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .gravity_y = 0.5 });
        defer cell.deinit();
        if (action.len > 0) clicked = components.iconActionButton(@src(), icons.tvg.lucide.play, action, .secondary, id);
    }
    return clicked;
}

/// Route a doc/moment click: files and streams go straight to the player (a
/// moment at its second); other library kinds open through Home's router; a
/// tracked show opens its detail page.
fn open(doc_id: i64, moment_id: i64) void {
    const t = recall.target(doc_id, moment_id) orelse return;
    if (recall.play(&t)) return;
    const source = t.sourceText();
    if (std.mem.eql(u8, source, "tv")) {
        const id = std.fmt.parseInt(i32, t.libId(), 10) catch return;
        @import("../services/tmdb.zig").openTvDetailById(id, t.titleText(), "");
        return;
    }
    if (std.mem.eql(u8, source, "library")) {
        var item = library_pure.LibraryItem{};
        setField(&item.kind, &item.kind_len, t.libKind());
        setField(&item.item_id, &item.item_id_len, t.libId());
        setField(&item.title, &item.title_len, t.titleText());
        setField(&item.poster, &item.poster_len, t.poster[0..t.poster_len]);
        setField(&item.deep_link, &item.deep_link_len, t.linkText());
        @import("home.zig").openLibItem(&item);
    }
}

fn setField(buf: []u8, len: *usize, value: []const u8) void {
    const n = @min(value.len, buf.len);
    @memcpy(buf[0..n], value[0..n]);
    len.* = n;
}

/// Paint the recall sections for `query` (no-op until the worker published
/// results for exactly this query, or when they are empty).
pub fn render(query: []const u8) void {
    if (query.len == 0) return;
    if (!recall.snapshot(query, &frame_results)) return;
    const r = &frame_results;
    if (r.doc_count == 0 and r.moment_count == 0) return;

    var pending_doc: i64 = 0;
    var pending_moment: i64 = 0;
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm } });
    defer outer.deinit();

    if (r.doc_count > 0) {
        var summary: [160]u8 = undefined;
        heading(icons.tvg.lucide.@"library-big", "From your library", pure.describe(&r.parsed.constraints, &summary), 61000);
        for (r.docs[0..r.doc_count], 0..) |*d, i| {
            var meta: [96]u8 = undefined;
            const action: []const u8 = if (d.playable) (if (d.percent >= pure.STARTED_PCT and d.percent < pure.WATCHED_PCT) "Resume" else "Play") else "Open";
            if (resultRow(61100 + i, kindIcon(d.kind), d.titleText(), docMeta(d, &meta), d.snippetText(), action)) pending_doc = d.id;
        }
    }
    if (r.moment_count > 0) {
        heading(icons.tvg.lucide.sparkles, "Moments", "inside your subtitles", 61300);
        for (r.moments[0..r.moment_count], 0..) |*m, i| {
            var clock: [24]u8 = undefined;
            const at = pure.formatClock(m.start_secs, &clock);
            var label: [40]u8 = undefined;
            const action = std.fmt.bufPrint(&label, "Play at {s}", .{at}) catch "Play";
            if (resultRow(61400 + i, kindIcon(m.kind), m.titleText(), "", m.snippetText(), action)) pending_moment = m.id;
        }
    }
    if (pending_moment > 0) open(0, pending_moment) else if (pending_doc > 0) open(pending_doc, 0);
}
