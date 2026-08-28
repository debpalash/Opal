//! Desktop presentation for the Podcasts feature.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const poster = @import("../core/poster.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;
const pure = @import("../services/podcasts_pure.zig");
const podcasts = @import("../services/podcasts.zig");

const Snapshot = podcasts.Snapshot;
const loadPopularOnce = podcasts.loadPopularOnce;
const searchPodcasts = podcasts.searchPodcasts;
const loadEpisodes = podcasts.loadEpisodes;
const playEpisode = podcasts.playEpisode;
const closeEpisodes = podcasts.closeEpisodes;

const PodPoster = struct {
    pixels: ?[]u8 = null,
    tex: ?dvui.Texture = null,
    w: u32 = 0,
    h: u32 = 0,
    fetching: bool = false,
    url_hash: u64 = 0,
};
var pod_posters: [50]PodPoster = [_]PodPoster{.{}} ** 50;

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    // Populate the page on first open (no-op after the first fetch).
    loadPopularOnce();

    renderSearchBar();
    const view = podcasts.snapshot();

    if (view.fetch_error) {
        _ = dvui.label(@src(), "Failed to fetch — check your connection", .{}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    if (view.selected_idx == null) {
        renderResults(&view);
    } else {
        renderEpisodes(&view);
    }
}

fn renderSearchBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer row.deinit();

    _ = dvui.icon(@src(), "", icons.tvg.lucide.podcast, .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.podcasts.search_buf },
        .placeholder = "Search podcasts…",
    }, .{
        .expand = .horizontal,
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .gravity_y = 0.5,
    });
    const entered = te.enter_pressed;
    te.deinit();

    const go = dvui.button(@src(), "Go", .{}, .{
        .color_fill = theme.colors.accent,
        .color_text = dvui.Color.white,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
    });

    if (entered or go) {
        const q = std.mem.sliceTo(&state.app.podcasts.search_buf, 0);
        if (q.len > 0) searchPodcasts(q);
    }

    if (state.app.podcasts.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
    }
}

// ── Card grid ──
// Popular shows and search results are the SAME record (parseItunes fills both),
// so they render through one grid: square cover + title + publisher, click →
// loadEpisodes(i), exactly as the old "Episodes" row button did.
const CARD_GAP: f32 = 6;
const CARD_TARGET_W: f32 = 170; // desired card width; columns derive from it
const CARD_FOOTER_H: f32 = 46; // title + publisher lines under the cover

/// Fill the card's cover area with the show's artwork, reusing the shared poster
/// daemon. Falls back to the podcast glyph while loading, when the show has no
/// artwork URL, or when the image can't be decoded. UI-thread only.
fn renderCover(i: usize, p: *const pure.Podcast) void {
    const slot = &pod_posters[i];
    const art = p.artwork[0..p.artwork_len];

    if (art.len > 0) {
        // Pin the slot to whatever show is at index i now — a re-search (or the
        // popular chart landing) can replace results[], so a URL-hash change
        // means "different show here": free the stale texture/pixels and
        // refetch. Only when not mid-fetch, so we never spawn a second worker
        // onto the same slot.
        const h = std.hash.Fnv1a_64.hash(art);
        if (slot.url_hash != h and !slot.fetching) {
            poster.deinitPoster(&slot.pixels, &slot.tex);
            slot.w = 0;
            slot.h = 0;
            slot.url_hash = h;
        }
        _ = poster.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.tex);
        if (slot.tex == null and !slot.fetching and slot.pixels == null)
            poster.fetchAsync(art, &slot.pixels, &slot.w, &slot.h, &slot.fetching);
    }

    if (slot.tex) |*tex| {
        _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
            .id_extra = i + 1000,
            .expand = .both,
            .corner_radius = dvui.Rect.all(8),
        });
    } else {
        _ = dvui.icon(@src(), "", icons.tvg.lucide.podcast, .{}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });
    }
}

/// One show card: square cover (clickable) + title + publisher subtitle.
fn renderCard(i: usize, card_w: f32, p: *const pure.Podcast) void {

    // Validate STABLE COPIES: a fetch worker can rewrite results[i] mid-frame
    // and dvui panics on invalid UTF-8 it reads after we validated.
    var name_buf: [160]u8 = undefined;
    const name = safeUtf8Buf(p.name[0..@min(p.name_len, p.name.len)], &name_buf);
    var artist_buf: [96]u8 = undefined;
    const artist = safeUtf8Buf(p.artist[0..@min(p.artist_len, p.artist.len)], &artist_buf);

    // min == max height → every card (and thus every row) has a uniform pitch.
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i,
        .min_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = card_w + CARD_FOOTER_H },
        .margin = dvui.Rect.all(CARD_GAP),
    });
    defer card.deinit();

    // Cover art hosted INSIDE a single button widget — one clickable rectangle
    // per card (a sibling button + box would draw two).
    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = i + 2000,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(8),
            .min_size_content = .{ .w = card_w, .h = card_w },
            .max_size_content = .{ .w = card_w, .h = card_w },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();

        renderCover(i, p);

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        // Same click target as the old row's "Episodes" button.
        if (clicked) loadEpisodes(i);
    }

    _ = dvui.label(@src(), "{s}", .{name}, .{
        .id_extra = i + 3000,
        .color_text = theme.colors.text_primary,
        .expand = .horizontal,
        .padding = .{ .x = 2, .y = 4, .w = 2, .h = 0 },
    });

    if (artist.len > 0) {
        _ = dvui.label(@src(), "{s}", .{artist}, .{
            .id_extra = i + 4000,
            .color_text = theme.colors.text_tertiary,
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
    }
}

fn renderResults(view: *const Snapshot) void {
    const count = view.result_count;
    if (count == 0) {
        if (!view.loading) {
            _ = dvui.label(@src(), "Search for a show to get started", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        } else {
            _ = dvui.label(@src(), "Loading popular shows…", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        }
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    _ = dvui.label(@src(), "{s}", .{
        if (view.showing_popular) "Popular now" else "Results",
    }, .{
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 2 },
    });

    // Responsive columns from the LIVE page width (one-frame lag; first paint
    // falls back to a sane default) — same shape as the TMDB gallery. No
    // virtualization: the grid is capped at results[]'s 50 cards.
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / CARD_TARGET_W)));
    const cols_f: f32 = @floatFromInt(cols);
    const card_w: f32 = @max(100, (avail_w - cols_f * 2 * CARD_GAP) / cols_f);

    var r: usize = 0;
    while (r * cols < count) : (r += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = r + 50000,
            .expand = .horizontal,
        });
        defer row.deinit();

        var c: usize = 0;
        while (c < cols and r * cols + c < count) : (c += 1) {
            const i = r * cols + c;
            renderCard(i, card_w, &view.results[i]);
        }
    }
}

fn renderEpisodes(view: *const Snapshot) void {
    // Header: back button + show title.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer hdr.deinit();

        if (dvui.buttonIcon(@src(), "Back", icons.tvg.lucide.@"arrow-left", .{}, .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .corner_radius = theme.dims.rad_sm,
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        })) {
            closeEpisodes();
            return;
        }

        var title_buf: [160]u8 = undefined;
        const title = safeUtf8Buf(
            view.selected_name[0..view.selected_name_len],
            &title_buf,
        );
        _ = dvui.label(@src(), "{s}", .{title}, .{
            .color_text = theme.colors.text_primary,
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        if (view.episodes_loading) {
            _ = dvui.label(@src(), "Loading…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
        }
    }

    if (view.episode_count == 0) {
        if (!view.episodes_loading) {
            _ = dvui.label(@src(), "No episodes found", .{}, .{
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
            });
        }
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    for (0..view.episode_count) |i| {
        const e = &view.episodes[i];
        var title_buf: [200]u8 = undefined;
        const title = safeUtf8Buf(e.title[0..e.title_len], &title_buf);

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
        });
        defer row.deinit();

        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = i + 3000,
                .expand = .horizontal,
            });
            defer col.deinit();

            _ = dvui.label(@src(), "{s}", .{title}, .{
                .id_extra = i + 4000,
                .color_text = theme.colors.text_primary,
                .expand = .horizontal,
            });

            // Meta: date · duration.
            if (e.date_len > 0 or e.duration_len > 0) {
                var meta_buf: [64]u8 = undefined;
                var mw = std.Io.Writer.fixed(&meta_buf);
                if (e.date_len > 0) mw.writeAll(e.date[0..@min(e.date_len, 32)]) catch {};
                if (e.date_len > 0 and e.duration_len > 0) mw.writeAll("  ·  ") catch {};
                if (e.duration_len > 0) mw.writeAll(e.duration[0..e.duration_len]) catch {};
                var safe_meta: [64]u8 = undefined;
                _ = dvui.label(@src(), "{s}", .{safeUtf8Buf(meta_buf[0..mw.end], &safe_meta)}, .{
                    .id_extra = i + 5000,
                    .color_text = theme.colors.text_tertiary,
                    .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                });
            }
        }

        if (dvui.buttonIcon(@src(), "Play", icons.tvg.lucide.play, .{}, .{}, .{
            .id_extra = i + 6000,
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .gravity_y = 0.5,
        })) {
            playEpisode(i);
        }
    }
}
