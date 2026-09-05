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
const icons = @import("icons");
const components = @import("components.zig");

pub const CARD_W: f32 = 150;
pub const POSTER_H: f32 = CARD_W * 1.5;

/// Title + status line. Everything a card ALWAYS has.
pub const CHROME_BASE_H: f32 = 48;
/// Added when `progress` is set.
pub const PROGRESS_H: f32 = 18;
/// Added when there is an action button, a remove button, or both — they share
/// one row, so the cost is the same whether a card has one or two.
pub const ACTION_H: f32 = 30;

/// Legacy alias: title + status + ONE of the two optional rows.
///
/// Kept because it is still the right size for a card that has exactly one of
/// them, but do not reach for it when sizing a rail — use `cardHeight`, which
/// asks what the card actually carries.
pub const CHROME_H: f32 = CHROME_BASE_H + PROGRESS_H;

/// Total height of a card that carries these parts.
///
/// This exists because the old flat CHROME_H described "title + status line +
/// (progress bar | action button)" — an EITHER/OR — while render() draws both
/// when both are asked for. The Watching page asks for both: every row there has
/// a progress bar AND a Play/Remove row. The action row landed outside the
/// card's max_size_content and was simply clipped away, so the page shipped with
/// no visible way to play or remove anything. The remove control existed, was
/// wired to removeRow(), and had a tooltip — it was just drawn past the bottom
/// edge of its own card.
pub fn cardHeight(has_progress: bool, has_actions: bool) f32 {
    return POSTER_H + CHROME_BASE_H +
        (if (has_progress) PROGRESS_H else 0) +
        (if (has_actions) ACTION_H else 0);
}

pub const Click = enum { none, open, action, remove };

pub const Card = struct {
    /// Episode rails use a landscape still instead of a portrait poster.
    landscape: bool = false,
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

    /// Show a "Remove" control, returning `.remove` when clicked. Opt-in: most
    /// card surfaces (search results, release rails) have nothing to remove
    /// FROM, and a delete affordance there would be meaningless at best.
    removable: bool = false,
};

/// Draw one card. `it` carries the poster's fetch/texture state and must be a
/// stable, per-item slot — NEVER an index into a list that gets re-sorted, or a
/// detached poster worker will write its pixels into the wrong card.
pub fn render(src: std.builtin.SourceLocation, id_extra: usize, it: *state.TmdbItem, card: Card) Click {
    var clicked: Click = .none;

    // Sized for what THIS card carries. A fixed height clipped the action row
    // off every card that also had a progress bar — see cardHeight.
    // A FLOOR, not a ceiling.
    //
    // The card used to pin min == max, and the height it pinned described
    // "title + status + (progress OR action row)". Ask for both — which every
    // Watching row does — and the action row fell outside the box and was
    // clipped away. That is how a Remove control that existed, was wired to
    // removeRow() and even had a tooltip shipped invisible.
    //
    // The floor still gives a surface uniform pitch (every card on one surface
    // carries the same parts, so they all size alike), but nothing is silently
    // cut off if the estimate is low or a font/theme change makes a row taller.
    // Getting this wrong now costs a few pixels of layout, not a missing button.
    const width: f32 = if (card.landscape) 224 else CARD_W;
    const art_h: f32 = if (card.landscape) 126 else POSTER_H;
    const h = cardHeight(card.progress != null, card.action_label != null or card.removable) - POSTER_H + art_h;
    var box = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = width, .h = h },
        .max_size_content = .{ .w = width, .h = std.math.floatMax(f32) },
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
            .min_size_content = .{ .w = width, .h = art_h },
            .max_size_content = .{ .w = width, .h = art_h },
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
            _ = dvui.label(@src(), "{s}", .{if (card.landscape) "Episode preview" else "Artwork unavailable"}, .{
                .color_text = theme.colors.text_secondary,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
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

    // ── Action row ──
    // Action button and Remove share a row so a removable card is the same
    // height as a non-removable one; a card that grew when it gained a delete
    // control would make the grid reflow between kinds.
    if (card.action_label != null or card.removable) {
        var arow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id_extra,
            .expand = .horizontal,
        });
        defer arow.deinit();

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
        } else {
            // Keep Remove pinned right even with no action button beside it.
            var sp = dvui.box(@src(), .{}, .{ .id_extra = id_extra, .expand = .horizontal });
            sp.deinit();
        }

        if (card.removable) {
            var wd: dvui.WidgetData = undefined;
            if (dvui.buttonIcon(@src(), "card-remove", icons.tvg.lucide.x, .{}, .{}, .{
                .data_out = &wd,
                .id_extra = id_extra,
                .color_fill = theme.transparent,
                .color_text = theme.colors.text_tertiary,
                .border = dvui.Rect.all(0),
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .gravity_y = 0.5,
                .padding = .{ .x = 5, .y = 5, .w = 5, .h = 5 },
                .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
            })) clicked = .remove;
            components.tip(@src(), wd, "Remove from Watching");
        }
    }

    if (@import("builtin").mode == .Debug) {
        const S = struct {
            var n: usize = 0;
        };
        S.n += 1;
    }
    return clicked;
}
