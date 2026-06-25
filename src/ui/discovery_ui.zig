//! Discovery UI — "Taste Receipts" For-You rail (pillar 3).
//!
//! A pure surface: renders the recommendations produced by the
//! recommendations worker (taste-vector seeds, or the genre-frequency
//! fallback) as a horizontal strip of cards. Each card surfaces the
//! title, a relevance score, and the verbatim "because" receipt
//! (recommendations.Recommendation.reason). Clicking a card fans the
//! title into the existing multi-source search via search.submitQuery.
//!
//! No business logic lives here — the rail reads recommendations[] /
//! rec_count as-is and never mutates them. If rec_count == 0 it renders
//! nothing (caller decides placement).
//!
//! Rules: SVG (lucide TVG) icons only — never emojis.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const recommendations = @import("../services/recommendations.zig");
const search = @import("../services/search.zig");

const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

const CARD_W: f32 = 220;
const CARD_H: f32 = 132;

/// For-You rail — taste-seeded recommendations as clickable receipt cards.
/// Renders nothing when there are no recommendations yet.
pub fn renderForYouRail() void {
    const n = recommendations.rec_count;
    if (n == 0) return;

    // ── Section header (mirrors home.zig sectionHeader styling) ──
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.sm, .w = theme.spacing.xs, .h = theme.spacing.xs },
        });
        defer hdr.deinit();

        dvui.icon(@src(), "for-you", icons.tvg.lucide.sparkles, .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 16, .h = 16 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "For You", .{}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
        });
    }

    // ── Horizontal scrolling strip of receipt cards ──
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none }, .{
        .expand = .horizontal,
        // Transparent container — let the dark page show through (dvui's default
        // scroll fill is light; without this the rail rendered as a white box).
        .background = false,
        .color_fill = theme.colors.bg_app,
        .min_size_content = .{ .w = 10, .h = CARD_H + 24 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = CARD_H + 24 },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer scroll.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    defer row.deinit();

    const count = @min(n, recommendations.recommendations.len);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        renderCard(&recommendations.recommendations[i], i);
    }
}

/// A single receipt card: title (top), score chip (top-right), and the
/// verbatim "because" reason (body). Whole card is clickable — opens a
/// multi-source search for the title.
fn renderCard(rec: *const recommendations.Recommendation, id: usize) void {
    const title = rec.title[0..@min(rec.title_len, rec.title.len)];
    const reason = rec.reason[0..@min(rec.reason_len, rec.reason.len)];

    var hovered: bool = false;

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .min_size_content = .{ .w = CARD_W, .h = CARD_H },
        .max_size_content = .{ .w = CARD_W, .h = CARD_H },
        .background = true,
        .color_fill = theme.colors.bg_card,
        .color_fill_hover = theme.colors.bg_hover,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        .margin = dvui.Rect.all(theme.spacing.xs),
    });
    defer card.deinit();

    // Whole-card click fans the title into the existing multi-source search.
    if (title.len > 0 and dvui.clicked(card.data(), .{ .hovered = &hovered })) {
        search.submitQuery(title);
    }
    card.drawBackground();

    // ── Top row: title (left, expands) + score chip (right) ──
    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id,
            .expand = .horizontal,
        });
        defer top.deinit();

        _ = dvui.label(@src(), "{s}", .{title}, .{
            .id_extra = id,
            .expand = .horizontal,
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
        });

        // Score chip — clamp to [0,1]-ish and render as a percentage. Scores
        // may be cosine (0..1) or a TMDB rating (fallback) — show whatever we
        // got, but keep it compact and never crash on NaN/inf.
        var sb: [16]u8 = undefined;
        if (formatScore(&sb, rec.score)) |s| {
            _ = dvui.label(@src(), "{s}", .{s}, .{
                .id_extra = id,
                .color_text = theme.colors.accent,
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
        }
    }

    // Spacer pushes the receipt to the bottom of the card.
    {
        var sp = dvui.box(@src(), .{}, .{ .id_extra = id, .expand = .vertical });
        sp.deinit();
    }

    // ── Receipt: verbatim "because …" reason ──
    if (reason.len > 0) {
        var receipt = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id,
            .expand = .horizontal,
            .gravity_y = 1.0,
        });
        defer receipt.deinit();

        dvui.icon(@src(), "because", icons.tvg.lucide.@"message-circle", .{}, .{
            .id_extra = id,
            .color_text = theme.colors.text_muted,
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.0,
            .margin = .{ .x = 0, .y = 2, .w = theme.spacing.xs, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{reason}, .{
            .id_extra = id,
            .expand = .horizontal,
            .color_text = theme.colors.text_secondary,
        });
    }
}

/// Render a score into `buf`. Cosine similarities (0..1] become a percentage;
/// anything outside that range (e.g. a TMDB rating used by the fallback) is
/// shown with one decimal. Returns null for non-finite values so the chip is
/// simply omitted rather than showing garbage.
fn formatScore(buf: []u8, score: f64) ?[]const u8 {
    if (std.math.isNan(score) or std.math.isInf(score)) return null;
    if (score > 0.0 and score <= 1.0) {
        const pct: u32 = @intFromFloat(@round(std.math.clamp(score, 0.0, 1.0) * 100.0));
        return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch null;
    }
    return std.fmt.bufPrint(buf, "{d:.1}", .{score}) catch null;
}
