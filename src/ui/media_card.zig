//! The one poster card.
//!
//! The Watching library and the Latest-releases rail both draw "a poster, a
//! title, a status line, and an optional action button". They used to be two
//! different renderers, which is how two surfaces showing the same shows end up
//! looking like two different apps. There is now one card and both call it.
//!
//! Poster loading goes through the shared daemon in `core/poster.zig`, by URL —
//! not by TMDB path — because anime and EZTV-resolved shows carry absolute URLs
//! while TMDB carries a path. One code path for every source.

const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const poster = @import("../core/poster.zig");
const theme = @import("theme.zig");

pub const CARD_W: f32 = 150;
pub const POSTER_H: f32 = CARD_W * 1.5;
/// Title + status line + (progress bar | action button).
pub const CHROME_H: f32 = 74;

pub const Click = enum { none, open, action };

pub const Card = struct {
    /// Fully-qualified artwork URL. Empty renders the empty poster frame.
    poster_url: []const u8 = "",
    title: []const u8 = "",
    /// One line under the title ("S02E04 · Next", "2h ago", "Caught up", …).
    subtitle: []const u8 = "",
    /// Accent the subtitle — used for "there is something to watch right now".
    subtitle_accent: bool = false,

    /// 0.0-1.0. Null hides the bar entirely (a release has no progress).
    progress: ?f32 = null,
    /// Text beside the bar ("12/24", "48%").
    progress_label: []const u8 = "",

    /// Null hides the button.
    action_label: ?[]const u8 = null,
};

/// Draw one card. `it` carries the poster's fetch/texture state and must be a
/// stable, per-item slot — NEVER an index into a list that gets re-sorted, or a
/// detached poster worker will write its pixels into the wrong card.
pub fn render(src: std.builtin.SourceLocation, id_extra: usize, it: *state.TmdbItem, card: Card) Click {
    var clicked: Click = .none;

    var box = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = CARD_W, .h = POSTER_H + CHROME_H },
        .max_size_content = .{ .w = CARD_W, .h = POSTER_H + CHROME_H },
        .margin = dvui.Rect.all(6),
    });
    defer box.deinit();

    // ── Poster ──
    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = id_extra,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(8),
            .min_size_content = .{ .w = CARD_W, .h = POSTER_H },
            .max_size_content = .{ .w = CARD_W, .h = POSTER_H },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();
        if (bw.clicked()) clicked = .open;

        if (poster.uploadIfReady(&it.poster_pixels, it.poster_w, it.poster_h, &it.poster_tex)) {
            if (it.poster_tex) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = id_extra,
                    .expand = .both,
                    .corner_radius = dvui.Rect.all(8),
                });
            }
        } else {
            // Full attempted -> failed transition. Gating on !failed without ever
            // SETTING it is how the TMDB grid used to re-spawn a fetch for a dead
            // poster on every single frame.
            if (it.poster_fetching) {
                it.poster_attempted = true;
            } else if (it.poster_attempted and it.poster_pixels == null and it.poster_tex == null) {
                it.poster_failed = true;
            } else if (!it.poster_failed and it.poster_pixels == null and card.poster_url.len > 0) {
                poster.fetchAsync(card.poster_url, &it.poster_pixels, &it.poster_w, &it.poster_h, &it.poster_fetching);
                if (it.poster_fetching) it.poster_attempted = true;
            }
        }
        bw.deinit();
    }

    // ── Title ──
    _ = dvui.label(@src(), "{s}", .{card.title}, .{
        .id_extra = id_extra,
        .color_text = theme.colors.text_primary,
        .expand = .horizontal,
        .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
    });

    // ── Status line ──
    _ = dvui.label(@src(), "{s}", .{card.subtitle}, .{
        .id_extra = id_extra,
        .color_text = if (card.subtitle_accent) theme.colors.accent else theme.colors.text_tertiary,
        .expand = .horizontal,
        .padding = .{ .x = 2, .y = 0, .w = 2, .h = 2 },
    });

    // ── Progress ──
    if (card.progress) |frac| {
        var pbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id_extra,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 2 },
        });
        defer pbox.deinit();

        // Manual track + fill, not dvui.progress/slider: the slider is DRAGGABLE
        // and takes the control-blue fill rather than the theme accent.
        {
            var track = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = id_extra,
                .expand = .horizontal,
                .gravity_y = 0.5,
                .background = true,
                .color_fill = theme.colors.bg_elevated,
                .min_size_content = .{ .w = 0, .h = 3 },
                .max_size_content = .{ .w = std.math.floatMax(f32), .h = 3 },
            });
            const track_w = track.data().contentRectScale().r.w;
            const f = std.math.clamp(frac, 0, 1);
            var fill = dvui.box(@src(), .{}, .{
                .id_extra = id_extra,
                .background = true,
                .color_fill = theme.colors.accent,
                .min_size_content = .{ .w = f * track_w, .h = 3 },
                .max_size_content = .{ .w = f * track_w, .h = 3 },
            });
            fill.deinit();
            track.deinit();
        }

        if (card.progress_label.len > 0) {
            _ = dvui.label(@src(), "{s}", .{card.progress_label}, .{
                .id_extra = id_extra,
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 0, .h = 0 },
            });
        }
    }

    // ── Action ──
    if (card.action_label) |lbl| {
        if (dvui.button(@src(), lbl, .{}, .{
            .id_extra = id_extra,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        })) clicked = .action;
    }

    return clicked;
}
