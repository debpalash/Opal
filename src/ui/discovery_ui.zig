//! Discovery UI — "Taste Receipts" For-You rail (pillar 3).
//!
//! A pure surface: renders the recommendations produced by the
//! recommendations worker (local taste engine, taste-vector seeds, or the
//! genre-frequency fallback) as a horizontal strip of shared media cards.
//! Each card shows the poster (tmdb_items.poster_path; a themed film glyph
//! when the tier has no catalog row), the title, a relevance score badge, and
//! the verbatim "because" receipt (recommendations.Recommendation.reason).
//! Clicking a card fans the title into the existing multi-source search via
//! search.submitQuery.
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
const components = @import("components.zig");
const media_card = @import("media_card.zig");
const cc = @import("color_compat.zig");
const recommendations = @import("../services/recommendations.zig");
const rec_pure = @import("../services/recommendations_pure.zig");
const search = @import("../services/search.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

/// Title, then the "because" receipt wrapped to two lines.
const FOOTER: media_card.Footer = .{ .title_lines = 1, .meta_lines = 2 };

// One lazy poster slot per rail position. Slots re-key by URL hash, so a
// regenerated list never shows another title's poster, and a dead poster
// latches `failed` until its URL changes (no per-frame refetch).
var rec_covers: [recommendations.recommendations.len]components.CoverSlot = @as([recommendations.recommendations.len]components.CoverSlot, @splat(.{}));

/// For-You rail — taste-seeded recommendations as poster cards, sized like
/// Home's other shelves (`card_w`). Renders nothing when there are none yet.
pub fn renderForYouRail(card_w: f32) void {
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
            .color_text = cc.wrap(theme.colors.accent),
            .min_size_content = theme.iconSize(.sm),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "For You", .{}, .{
            .color_text = cc.wrap(theme.colors.text_primary),
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
        });
    }

    // ── Horizontal strip of poster cards ──
    const strip_h = media_card.rowPitch(card_w, .poster, FOOTER);
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none }, .{
        .expand = .horizontal,
        // Transparent container — let the page show through (dvui's default
        // scroll fill is light; without this the rail rendered as a white box).
        .background = false,
        .min_size_content = .{ .w = 10, .h = strip_h },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = strip_h },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer scroll.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    defer row.deinit();

    const count = @min(n, recommendations.recommendations.len);
    for (0..count) |i| renderCard(&recommendations.recommendations[i], i, card_w);
}

/// One recommendation: poster (or film glyph), score badge, title, and the
/// verbatim "because" receipt. Cover and title both open a multi-source
/// search for the title.
fn renderCard(rec: *const recommendations.Recommendation, i: usize, card_w: f32) void {
    // Title/reason/poster live in worker-written buffers (recommendations.addRec,
    // a detached thread) — validate stable stack copies before dvui reads them.
    var tb: [128]u8 = undefined;
    const title = safeUtf8Buf(rec.title[0..@min(rec.title_len, rec.title.len)], &tb);
    var rb: [256]u8 = undefined;
    const reason = safeUtf8Buf(rec.reason[0..@min(rec.reason_len, rec.reason.len)], &rb);
    var pb: [256]u8 = undefined;
    const path = rec.posterSlice();
    @memcpy(pb[0..path.len], path);

    var card = media_card.begin(@src(), .{ .id = i, .width = card_w, .aspect = .poster, .footer = FOOTER });
    defer card.end();

    var url_buf: [512]u8 = undefined;
    const url = rec_pure.posterUrl(pb[0..path.len], &url_buf) orelse "";
    components.coverArt(@src(), i, &rec_covers[i], url, icons.tvg.lucide.film, theme.radius.lg);
    var sb: [16]u8 = undefined;
    if (rec_pure.formatScore(&sb, rec.score)) |s| media_card.badge(.top_right, s, .accent);
    const open_cover = card.endCover();
    const open_title = media_card.title(title, 1);
    if ((open_cover or open_title) and title.len > 0) search.submitQuery(title);

    if (reason.len > 0) {
        const font = media_card.metaFont();
        var wrapped: [520]u8 = undefined;
        const shown = components.twoLineTitle(reason, font, card_w - 4, &wrapped);
        const h = font.lineHeight() * 2;
        _ = dvui.label(@src(), "{s}", .{shown}, .{
            .id_extra = i,
            .color_text = cc.wrap(theme.colors.text_secondary),
            .font = font,
            .min_size_content = .{ .w = card_w - 4, .h = h },
            .max_size_content = .{ .w = card_w - 4, .h = h },
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
            .margin = dvui.Rect.all(0),
        });
    }
}
