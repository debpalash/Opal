//! Shared media card: one clickable cover with overlay badges/progress, then a
//! measured footer (title, meta lines, one action row).
//!
//! Every catalog card renders through this — Movies & TV, Home rails, Coming
//! up, podcasts, music, Jellyfin, Plex and YouTube — so corners, hover, focus,
//! type and footer budgets match everywhere. Geometry lives in
//! media_card_pure.zig (unit-tested); galleries take their row pitch from it.
//!
//! Two entry points:
//!   - `render(src, id, item, Card{...})`: the one-call poster card used by the
//!     Watching library and the Latest-releases rail.
//!   - `begin` / `Frame`: the building blocks every other card composes:
//!   var card = media_card.begin(@src(), .{ .id = i, .width = w, .aspect = .poster, .footer = F });
//!   defer card.end();
//!   media_card.art(tex, .{ .loading = fetching, .placeholder = icon });
//!   media_card.badge(.top_left, "TV", .accent);
//!   if (card.endCover()) open(item);
//!   if (media_card.title(text, F.title_lines)) open(item);
//!   var row = media_card.actionRow(); defer row.deinit(); ...
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const components = @import("components.zig");
const cc = @import("color_compat.zig");
pub const pure = @import("media_card_pure.zig");

pub const Aspect = pure.Aspect;
pub const Footer = pure.Footer;

pub fn titleFont() dvui.Font {
    return dvui.themeGet().font_heading.withSize(theme.font_size.body);
}

pub fn metaFont() dvui.Font {
    return dvui.themeGet().font_body.withSize(theme.font_size.small);
}

fn metrics() pure.Metrics {
    return .{ .title_line = titleFont().lineHeight(), .meta_line = metaFont().lineHeight() };
}

/// Footer height for the live fonts — use for cards, skeletons and spacers.
pub fn footerHeight(footer: Footer) f32 {
    return pure.footerHeight(footer, metrics());
}

pub fn coverHeight(width: f32, aspect: Aspect) f32 {
    return pure.coverHeight(width, aspect);
}

/// Outer row pitch (card + both margins) for virtualized galleries.
pub fn rowPitch(width: f32, aspect: Aspect, footer: Footer) f32 {
    return pure.rowPitch(coverHeight(width, aspect), footerHeight(footer), pure.MARGIN);
}

pub const Spec = struct {
    id: usize,
    width: f32,
    aspect: Aspect = .poster,
    footer: Footer = .{},
    /// Explicit cover height (overrides `aspect`) for screens with a legacy ratio.
    cover_h: ?f32 = null,
    margin: f32 = pure.MARGIN,
    /// Keyboard-focused card: draws the same ring as hover.
    focused: bool = false,
};

/// A clickable cover with an overlay stack for art, badges and progress.
pub const Cover = struct {
    button: *dvui.ButtonWidget,
    stack: *dvui.OverlayWidget,
    focused: bool,

    pub fn hovered(self: *const Cover) bool {
        return self.button.hovered();
    }

    /// Close the cover. Returns true when it was clicked or activated.
    pub fn end(self: *Cover) bool {
        if (self.focused or self.button.hovered()) {
            var ring = dvui.box(@src(), .{}, .{
                .expand = .both,
                .border = dvui.Rect.all(2),
                .color_border = cc.wrap(if (self.focused) theme.colors.accent else theme.colors.border_strong),
                .corners = dvui.CornerRect.all(theme.radius.lg),
            });
            ring.deinit();
        }
        self.stack.deinit();
        const clicked = self.button.clicked();
        self.button.drawFocus();
        self.button.deinit();
        return clicked;
    }
};

pub fn coverBegin(width: f32, cover_h: f32, focused: bool) Cover {
    const button = dvui.widgetAlloc(dvui.ButtonWidget);
    button.init(@src(), .{}, .{
        .background = true,
        .color_fill = cc.wrap(theme.colors.bg_elevated),
        .color_fill_hover = cc.wrap(theme.colors.bg_hover),
        .corners = dvui.CornerRect.all(theme.radius.lg),
        .min_size_content = .{ .w = width, .h = cover_h },
        .max_size_content = .{ .w = width, .h = cover_h },
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .border = dvui.Rect.all(0),
    });
    button.processEvents();
    button.drawBackground();
    const stack = dvui.overlay(@src(), .{ .expand = .both });
    active_width = width;
    active_cover_h = cover_h;
    return .{ .button = button, .stack = stack, .focused = focused };
}

/// A fixed-pitch card (min == max height) for virtualized grids and rails.
pub const Frame = struct {
    outer: *dvui.BoxWidget,
    cover: Cover,
    cover_open: bool = true,

    /// True while the pointer is over any part of the card.
    pub fn hovered(self: *const Frame) bool {
        return self.outer.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt);
    }

    pub fn endCover(self: *Frame) bool {
        if (!self.cover_open) return false;
        self.cover_open = false;
        return self.cover.end();
    }

    pub fn end(self: *Frame) void {
        if (self.cover_open) _ = self.endCover();
        self.outer.deinit();
    }
};

/// Open a card and its cover. Cover helpers (`art`, `badge`, `progress`, …)
/// draw into the cover until `endCover`; footer helpers follow it.
pub fn begin(src: std.builtin.SourceLocation, spec: Spec) Frame {
    const cover_h = spec.cover_h orelse coverHeight(spec.width, spec.aspect);
    const footer_h = footerHeight(spec.footer);
    const outer = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = spec.id,
        .min_size_content = .{ .w = spec.width, .h = cover_h + footer_h },
        .max_size_content = .{ .w = spec.width, .h = cover_h + footer_h },
        .margin = dvui.Rect.all(spec.margin),
        .padding = dvui.Rect.all(0),
    });
    return .{ .outer = outer, .cover = coverBegin(spec.width, cover_h, spec.focused) };
}

// ── Cover content ──

pub const ArtOptions = struct {
    /// Fetch in flight → shimmer skeleton instead of the placeholder glyph.
    loading: bool = false,
    /// Glyph for "no artwork" (kind icon: film, podcast, music…).
    placeholder: []const u8 = icons.tvg.lucide.image,
    /// Natural image size: crop to fill instead of stretching (thumbnails).
    natural: ?dvui.Size = null,
};

/// Artwork, a loading skeleton, or a quiet kind-glyph placeholder.
pub fn art(tex: ?dvui.Texture, opts: ArtOptions) void {
    if (tex) |t| {
        var uv: dvui.Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
        if (opts.natural) |n| {
            const crop = @import("search_gallery_pure.zig").coverCrop(.{ .w = n.w, .h = n.h }, .{ .w = active_width, .h = active_cover_h });
            uv = .{ .x = crop.x, .y = crop.y, .w = crop.w, .h = crop.h };
        }
        _ = dvui.image(@src(), .{ .source = .{ .texture = t }, .uv = uv }, .{
            .expand = .both,
            .corners = dvui.CornerRect.all(theme.radius.lg),
        });
        return;
    }
    if (opts.loading) {
        components.coverSkeleton(@src(), 0, theme.radius.lg);
        return;
    }
    placeholder(opts.placeholder);
}

pub fn placeholder(glyph: []const u8) void {
    dvui.icon(@src(), "cover", glyph, .{}, .{
        .color_text = cc.wrap(theme.colors.accent_dim),
        .min_size_content = theme.iconSize(.xl),
        .max_size_content = dvui.Options.MaxSize.size(theme.iconSize(.xl)),
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
}

pub const Corner = enum(u8) { top_left, top_right, bottom_left, bottom_right };
pub const BadgeStyle = enum { glass, accent, success };

fn cornerGravity(corner: Corner) [2]f32 {
    return switch (corner) {
        .top_left => .{ 0, 0 },
        .top_right => .{ 1, 0 },
        .bottom_left => .{ 0, 1 },
        .bottom_right => .{ 1, 1 },
    };
}

/// Small pill on a cover corner (kind, TV, duration, "Watched").
pub fn badge(corner: Corner, text: []const u8, style: BadgeStyle) void {
    const g = cornerGravity(corner);
    _ = dvui.label(@src(), "{s}", .{text}, .{
        .id_extra = @intFromEnum(corner),
        .gravity_x = g[0],
        .gravity_y = g[1],
        .background = true,
        .color_fill = cc.wrap(switch (style) {
            .glass => theme.playerGlass(214),
            .accent => theme.colors.accent,
            .success => theme.colors.success,
        }),
        .color_text = cc.wrap(switch (style) {
            .glass => theme.colors.text_primary,
            .accent, .success => theme.colors.text_on_accent,
        }),
        .font = dvui.themeGet().font_heading.withSize(theme.font_size.micro),
        .corners = dvui.CornerRect.all(theme.radius.pill),
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        .margin = dvui.Rect.all(6),
    });
}

/// Catalog score badge. Callers pass only real scores — a missing vote is
/// not a 0% review, so unrated titles get no badge.
pub fn ratingBadge(corner: Corner, rating: f32) void {
    const g = cornerGravity(corner);
    const tint = if (rating >= 7) theme.colors.success else if (rating >= 5) theme.colors.warning else theme.colors.text_secondary;
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = @intFromEnum(corner),
        .gravity_x = g[0],
        .gravity_y = g[1],
        .background = true,
        .color_fill = cc.wrap(theme.playerGlass(214)),
        .corners = dvui.CornerRect.all(theme.radius.pill),
        .padding = .{ .x = 5, .y = 2, .w = 6, .h = 2 },
        .margin = dvui.Rect.all(6),
    });
    defer pill.deinit();
    dvui.icon(@src(), "rating", icons.tvg.lucide.star, .{ .fill_color = .{ .color = tint } }, .{
        .color_text = cc.wrap(tint),
        .min_size_content = .{ .w = 9, .h = 9 },
        .max_size_content = .{ .w = 9, .h = 9 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
    });
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.1}", .{rating}) catch return;
    _ = dvui.label(@src(), "{s}", .{text}, .{
        .color_text = cc.wrap(theme.colors.text_primary),
        .font = dvui.themeGet().font_heading.withSize(theme.font_size.small),
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
    });
}

/// Resume progress inside the cover's bottom edge. `fraction` is 0…1.
pub fn progress(width: f32, fraction: f64) void {
    if (!std.math.isFinite(fraction) or fraction <= 0) return;
    const inset: f32 = 6;
    const track_w = @max(0, width - inset * 2);
    var track = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 1,
        .background = true,
        .color_fill = cc.wrap(theme.playerGlass(200)),
        .corners = dvui.CornerRect.all(theme.radius.pill),
        .min_size_content = .{ .w = track_w, .h = 4 },
        .max_size_content = .{ .w = track_w, .h = 4 },
        .margin = .{ .x = inset, .y = 0, .w = inset, .h = inset },
    });
    defer track.deinit();
    const fill_w = track_w * @as(f32, @floatCast(std.math.clamp(fraction, 0, 1)));
    var fill = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = cc.wrap(theme.colors.accent),
        .corners = dvui.CornerRect.all(theme.radius.pill),
        .min_size_content = .{ .w = fill_w, .h = 4 },
        .max_size_content = .{ .w = fill_w, .h = 4 },
    });
    fill.deinit();
}

// ── Footer ──

/// Clickable, top-aligned title (1 or 2 lines, ellipsized). Returns clicked.
pub fn title(text: []const u8, lines: u8) bool {
    const font = theme.mediaTitleFont(text, titleFont());
    const width = parentWidth();
    var wrapped: [520]u8 = undefined;
    const shown = if (lines >= 2) components.twoLineTitle(text, font, width - 4, &wrapped) else text;
    const h = titleFont().lineHeight() * @as(f32, @floatFromInt(@max(1, lines)));
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .font = font,
        .expand = .horizontal,
        .min_size_content = .{ .w = width - 4, .h = h },
        .max_size_content = .{ .w = width - 4, .h = h },
        .color_text = cc.wrap(theme.colors.text_primary),
        .color_fill = cc.wrap(theme.transparent),
        .color_fill_hover = cc.wrap(theme.colors.bg_hover),
        .color_fill_press = cc.wrap(theme.colors.bg_elevated),
        .corners = dvui.CornerRect.all(4),
        .margin = .{ .x = 0, .y = pure.TITLE_GAP, .w = 0, .h = 0 },
        .border = dvui.Rect.all(0),
        .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
    });
    bw.processEvents();
    bw.drawBackground();
    dvui.labelNoFmt(@src(), shown, .{}, bw.data().options.strip().override(bw.style()).override(.{ .gravity_x = 0, .gravity_y = 0, .padding = dvui.Rect.all(0) }));
    bw.drawFocus();
    const clicked = bw.clicked();
    bw.deinit();
    return clicked;
}

/// One muted meta line (publisher, artist, caption); ellipsized.
pub fn meta(text: []const u8, id: usize, tone: enum { secondary, tertiary, success, accent }) void {
    _ = dvui.label(@src(), "{s}", .{text}, .{
        .id_extra = id,
        .color_text = cc.wrap(switch (tone) {
            .secondary => theme.colors.text_secondary,
            .tertiary => theme.colors.text_tertiary,
            .success => theme.colors.success,
            .accent => theme.colors.accent,
        }),
        .font = metaFont(),
        .min_size_content = .{ .w = parentWidth() - 4, .h = metaFont().lineHeight() },
        .max_size_content = .{ .w = parentWidth() - 4, .h = metaFont().lineHeight() },
        .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        .margin = dvui.Rect.all(0),
    });
}

/// The footer's single action row; add `rowText`, `spacer`, `iconAction`
/// and `moreMenu` into it, then `deinit`.
pub fn actionRow() *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = pure.ACTION_ROW_H - 4 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = pure.ACTION_ROW_H - 4 },
        .padding = .{ .x = 2, .y = 4, .w = 0, .h = 0 },
    });
}

/// Muted text at the start of an action row, capped so actions keep room.
pub fn rowText(text: []const u8, max_w: f32, tone: enum { secondary, success, accent }) void {
    _ = dvui.label(@src(), "{s}", .{text}, .{
        .color_text = cc.wrap(switch (tone) {
            .secondary => theme.colors.text_secondary,
            .success => theme.colors.success,
            .accent => theme.colors.accent,
        }),
        .font = metaFont(),
        .gravity_y = 0.5,
        .padding = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
        .max_size_content = .{ .w = @max(0, max_w), .h = pure.ACTION_ROW_H },
    });
}

pub fn spacer() void {
    var s = dvui.box(@src(), .{}, .{ .expand = .horizontal });
    s.deinit();
}

/// Quiet 14px icon action with tooltip; `active` tints it with the accent.
pub fn iconAction(src: std.builtin.SourceLocation, icon: []const u8, label: []const u8, id: usize, active: bool) bool {
    var wd: dvui.WidgetData = undefined;
    const clicked = dvui.buttonIcon(src, label, icon, .{}, .{}, .{
        .id_extra = id,
        .data_out = &wd,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 14, .h = 14 },
        .max_size_content = .{ .w = 14, .h = 14 },
        .padding = dvui.Rect.all(4),
        .margin = dvui.Rect.all(0),
        .border = dvui.Rect.all(0),
        .corners = dvui.CornerRect.all(4),
        .color_text = cc.wrap(if (active) theme.colors.accent else theme.colors.text_secondary),
        .color_fill = cc.wrap(theme.transparent),
        .color_fill_hover = cc.wrap(theme.colors.bg_hover),
        .color_fill_press = cc.wrap(theme.colors.bg_elevated),
    });
    components.tip(src, wd, label);
    if (@import("builtin").is_test) last_action_bounds_for_test = wd.borderRectScale().r;
    return clicked;
}
pub var last_action_bounds_for_test: dvui.Rect.Physical = .{};

/// Keyboard-accessible "More actions" kebab. Returns the anchor rect when
/// open; build the floating menu from it and `deinit` the returned menu.
pub const More = struct {
    menu: *dvui.MenuWidget,
    anchor: ?dvui.Rect.Natural,
    pub fn deinit(self: More) void {
        self.menu.deinit();
    }
};

pub fn moreMenu(id: usize) More {
    const menu = dvui.menu(@src(), .horizontal, .{ .id_extra = id, .gravity_y = 0.5 });
    const anchor = dvui.menuItemIcon(@src(), "More actions", icons.tvg.lucide.@"ellipsis-vertical", .{ .submenu = true }, .{
        .color_text = cc.wrap(theme.colors.text_secondary),
        .min_size_content = .{ .w = 14, .h = 14 },
        .max_size_content = .{ .w = 14, .h = 14 },
        .padding = dvui.Rect.all(4),
        .corners = dvui.CornerRect.all(4),
    });
    return .{ .menu = menu, .anchor = anchor };
}

/// Width/cover height of the card being drawn (cards never nest). Footer
/// helpers size from these instead of a parent rect that is still zero on a
/// card's first frame.
var active_width: f32 = 100;
var active_cover_h: f32 = 150;

fn parentWidth() f32 {
    return active_width;
}

// ── Gallery helpers ──

/// Skeleton tiles shaped exactly like real cards so layout doesn't jump.
pub fn skeletonGrid(src: std.builtin.SourceLocation, id_base: usize, cols: usize, width: f32, aspect: Aspect, footer: Footer, rows: usize) void {
    components.coverSkeletonGrid(src, id_base, cols, width, coverHeight(width, aspect), footerHeight(footer), rows);
}

// ══════════════════════════════════════════════════════════
// One-call poster card (Watching library, Latest releases)
// ══════════════════════════════════════════════════════════
//
// Poster loading goes through the shared daemon in `core/poster.zig`, by URL —
// not by TMDB path — because anime and EZTV-resolved shows carry absolute URLs
// while TMDB carries a path. One code path for every source.

const state = @import("../core/state.zig");
const poster = @import("../core/poster.zig");

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

    // Sized for what THIS card carries — a FLOOR, not a ceiling. The card used
    // to pin min == max at "title + status + (progress OR action row)", so a
    // Watching row asking for both had its Remove control clipped away. The
    // floor keeps a uniform pitch per surface, but nothing is cut off if a
    // font/theme change makes a row taller.
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
        var cover = coverBegin(width, art_h, false);
        _ = poster.uploadIfReady(&it.poster_pixels, it.poster_w, it.poster_h, &it.poster_tex);
        if (it.poster_tex) |tex| {
            art(tex, .{});
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
            art(null, .{
                .loading = !it.poster_failed and card.poster_url.len > 0,
                .placeholder = if (card.landscape) icons.tvg.lucide.clapperboard else icons.tvg.lucide.tv,
            });
        }
        if (card.progress) |frac| progress(width, frac);
        if (cover.end()) clicked = .open;
    }

    // ── Title + status line ──
    if (title(card.title, 1)) clicked = .open;
    meta(card.subtitle, id_extra, if (card.subtitle_accent) .accent else .tertiary);
    if (card.progress != null and card.progress_label.len > 0) meta(card.progress_label, id_extra + 1, .tertiary);

    // ── Action row ──
    // Action and Remove share a row so a removable card is the same height
    // as a non-removable one; a card that grew when it gained a delete
    // control would make the grid reflow between kinds.
    if (card.action_label != null or card.removable) {
        var arow = actionRow();
        defer arow.deinit();
        if (card.action_label) |lbl| {
            if (components.actionButton(@src(), lbl, .secondary, id_extra)) clicked = .action;
        }
        spacer();
        if (card.removable and iconAction(@src(), icons.tvg.lucide.x, "Remove from Watching", id_extra, false)) clicked = .remove;
    }
    return clicked;
}
