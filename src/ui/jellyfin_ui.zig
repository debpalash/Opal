const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const components = @import("components.zig");
const jf = @import("../services/jellyfin.zig");
const safeUtf8 = @import("../core/text.zig").safeUtf8;
const poster_util = @import("../core/poster.zig");

var frame_view: jf.DesktopSnapshot = undefined;

const PosterSlot = struct {
    pixels: ?[]u8 = null,
    tex: ?dvui.Texture = null,
    w: u32 = 0,
    h: u32 = 0,
    fetching: bool = false,
    id_hash: u64 = 0,
};
var poster_slots: [336]PosterSlot = [_]PosterSlot{.{}} ** 336;

var login_initialized = false;
var login_server: [256]u8 = std.mem.zeroes([256]u8);
var login_user: [128]u8 = std.mem.zeroes([128]u8);
var login_pass: [128]u8 = std.mem.zeroes([128]u8);
var search_buf: [256]u8 = std.mem.zeroes([256]u8);

// ══════════════════════════════════════════════════════════
// Main Entry Point
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    frame_view = jf.desktopSnapshot();
    if (!frame_view.connected) {
        renderLoginForm();
        return;
    }

    // Auto-fetch libraries + resume on first load
    if (frame_view.library_count == 0 and !frame_view.loading) {
        jf.fetchLibraries();
    }
    if (!frame_view.resume_loaded) {
        jf.fetchResume();
    }

    switch (frame_view.view) {
        .Libraries => renderLibraries(),
        .Browse => renderItems(),
        .Search => renderSearch(),
        .Resume => renderItems(),
    }
}

// ══════════════════════════════════════════════════════════
// Login Form
// ══════════════════════════════════════════════════════════

fn renderLoginForm() void {
    if (!login_initialized) {
        const initial = if (frame_view.server_len > 0)
            frame_view.server[0..frame_view.server_len]
        else
            "http://localhost:8096";
        @memcpy(login_server[0..initial.len], initial);
        login_initialized = true;
    }
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    // Header
    {
        var hdr = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 20, .w = 16, .h = 16 },
        });
        defer hdr.deinit();

        _ = dvui.label(@src(), "Jellyfin / Emby", .{}, .{
            .color_text = theme.colors.accent,
        });
        _ = dvui.label(@src(), "Connect to your Jellyfin or Emby server (for Emby, append /emby to the URL if needed)", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
    }

    // Form
    {
        var form = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 0, .w = 16, .h = 0 },
        });
        defer form.deinit();

        _ = dvui.label(@src(), "Server URL", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });

        var url_te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &login_server },
        }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        url_te.deinit();

        _ = dvui.label(@src(), "Username", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        var user_te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &login_user },
        }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        user_te.deinit();

        _ = dvui.label(@src(), "Password", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        var pass_te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &login_pass },
        }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 12 },
        });
        const login_enter = pass_te.enter_pressed;
        pass_te.deinit();

        if (frame_view.login_error_len > 0) {
            _ = dvui.label(@src(), "{s}", .{frame_view.login_error[0..frame_view.login_error_len]}, .{
                .color_text = theme.colors.danger,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
            });
        }

        if (!frame_view.loading) {
            const clicked_connect = dvui.button(@src(), "Connect", .{}, .{
                .expand = .horizontal,
                .color_fill = theme.colors.accent,
                .color_text = theme.colors.text_on_accent,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
            });
            if (clicked_connect or login_enter) {
                jf.configureLogin(
                    std.mem.sliceTo(&login_server, 0),
                    std.mem.sliceTo(&login_user, 0),
                    std.mem.sliceTo(&login_pass, 0),
                );
                jf.authenticate();
            }
        } else {
            _ = dvui.label(@src(), "Connecting...", .{}, .{
                .expand = .horizontal,
                .color_text = theme.colors.text_secondary,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 10, .w = 0, .h = 10 },
            });
        }
    }
}

// ══════════════════════════════════════════════════════════
// Library Grid — with Continue Watching cards
// ══════════════════════════════════════════════════════════

fn renderLibraries() void {
    // Header bar
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer hdr.deinit();

        if (dvui.buttonIcon(@src(), "search", icons.tvg.lucide.search, .{}, .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .padding = dvui.Rect.all(5),
            .corner_radius = theme.dims.rad_sm,
        })) {
            jf.openSearch();
        }

        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        _ = dvui.label(@src(), "Jellyfin / Emby", .{}, .{
            .color_text = theme.colors.accent,
            .gravity_y = 0.5,
        });

        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        if (dvui.buttonIcon(@src(), "disconnect", icons.tvg.lucide.@"log-out", .{}, .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .padding = dvui.Rect.all(5),
            .corner_radius = theme.dims.rad_sm,
        })) {
            jf.disconnect();
        }
    }

    if (frame_view.loading and frame_view.library_count == 0) {
        renderSkeletonRows();
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    // Fully-empty state — connected, nothing loading, nothing to show.
    if (frame_view.library_count == 0 and frame_view.resume_count == 0) {
        components.emptyState(
            icons.tvg.lucide.@"library-big",
            "No items yet",
            "Connect Jellyfin or search to start.",
        );
        return;
    }

    // ── Continue Watching Section ──
    if (frame_view.resume_count > 0) {
        _ = dvui.label(@src(), "Continue Watching", .{}, .{
            .color_text = theme.colors.text_primary,
            .padding = .{ .x = 12, .y = 10, .w = 0, .h = 4 },
        });

        // Horizontal scroll row of poster cards
        var resume_scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 10, .h = 140 },
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = 140 },
            .padding = .{ .x = 8, .y = 0, .w = 8, .h = 8 },
        });
        defer resume_scroll.deinit();

        var resume_row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer resume_row.deinit();

        for (0..frame_view.resume_count) |i| {
            const item = &frame_view.resume_items[i];
            renderPosterCard(item, i, i + 5000, 130, true);
        }
    }

    // ── Library Rows ──
    if (frame_view.library_count > 0) {
        _ = dvui.label(@src(), "Libraries", .{}, .{
            .color_text = theme.colors.text_primary,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 4 },
        });
    }

    for (0..frame_view.library_count) |i| {
        const lib = &frame_view.libraries[i];
        var lib_name_buf: [128]u8 = undefined;
        const name = @import("../core/text.zig").safeUtf8Buf(lib.name[0..lib.name_len], &lib_name_buf);
        const ct = lib.collection_type[0..lib.collection_type_len];
        const ic = iconForCollectionType(ct);

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.md, .w = theme.spacing.md, .h = theme.spacing.md },
        });
        defer row.deinit();

        dvui.icon(@src(), "", ic, .{}, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 18, .h = 18 },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });

        if (dvui.button(@src(), name, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .gravity_y = 0.5,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_primary,
            .padding = dvui.Rect.all(0),
        })) {
            const id = lib.id[0..lib.id_len];
            jf.openLibrary(id, name);
        }

        dvui.icon(@src(), "", icons.tvg.lucide.@"chevron-right", .{}, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .color_text = theme.colors.text_secondary,
            .min_size_content = theme.iconSize(.sm),
        });
    }
}

// ══════════════════════════════════════════════════════════
// Items — Poster Card Grid
// ══════════════════════════════════════════════════════════

fn renderItems() void {
    // Header with back + breadcrumb
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer hdr.deinit();

        if (dvui.buttonIcon(@src(), "back", icons.tvg.lucide.@"arrow-left", .{}, .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .padding = dvui.Rect.all(5),
            .corner_radius = theme.dims.rad_sm,
        })) {
            jf.popNav();
        }

        if (frame_view.parent_name_len > 0) {
            var pn_buf: [128]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(frame_view.parent_name[0..frame_view.parent_name_len], &pn_buf)}, .{
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
                .padding = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
            });
        }

        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        if (frame_view.loading) {
            _ = dvui.label(@src(), "Loading...", .{}, .{
                .color_text = theme.colors.text_secondary,
                .gravity_y = 0.5,
            });
        }
    }

    if (frame_view.loading and frame_view.item_count == 0) {
        renderSkeletonRows();
        return;
    }

    if (frame_view.item_count == 0 and !frame_view.loading) {
        if (frame_view.view == .Search) {
            components.emptyState(
                icons.tvg.lucide.@"search-x",
                "No matches",
                "Try a broader query or check your spelling.",
            );
        } else {
            components.emptyState(
                icons.tvg.lucide.@"library-big",
                "No items yet",
                "Try a different search.",
            );
        }
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    // Responsive poster grid (fills the page width; was one wide row per item).
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / 150)));
    const card_w: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));

    // ── Virtualization (same shape as tmdb.zig renderGallery) ──
    // Uniform cards → fixed row pitch: poster + footer + 3px margins each way.
    const total = frame_view.item_count;
    const row_h: f32 = card_w * 1.45 + CARD_FOOTER_H + 6;
    const total_rows = (total + cols - 1) / cols;
    const win = @import("../services/tmdb_pure.zig").visibleRows(total_rows, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 2);

    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 59998,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) },
        });
        sp.deinit();
    }

    var r: usize = win.first;
    while (r < win.last) : (r += 1) {
        const base = r * cols;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = base + 60000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and base + col < total) : (col += 1) {
            renderPosterCard(&frame_view.items[base + col], 16 + base + col, base + col, card_w, true);
        }
    }

    if (win.last < total_rows) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 59999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(total_rows - win.last)) },
        });
        sp.deinit();
    }

    // Infinite scroll: fetch + append the next Jellyfin StartIndex window (for
    // whichever context — library Browse or Search — is on screen) as the
    // user nears the bottom. Bounded by more_available + loading_more
    // (services/jellyfin.zig) so one scroll can't spawn a burst; `underfilled`
    // keeps paging when the first window is shorter than the viewport.
    // Mirrors services/drama.zig's renderContent. Shared by both the Browse
    // view (calls renderItems() directly) and Search (renderSearch() calls
    // renderItems() too), since both page the same items[]/item_count.
    if (jf.more_available) {
        const loading = jf.loading_more.load(.acquire);
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        const underfilled = max_y <= 0 and frame_view.item_count > 0;
        if ((near_bottom or underfilled) and !loading and !frame_view.loading) {
            jf.loadMore();
        }
        if (loading or underfilled) {
            dvui.spinner(@src(), .{
                .color_text = theme.colors.accent,
                .min_size_content = theme.iconSize(.lg),
                .gravity_x = 0.5,
                .margin = dvui.Rect.all(12),
            });
            dvui.refresh(null, @src(), null); // wake until the worker's items land
        }
    }
}

// ══════════════════════════════════════════════════════════
// Skeleton tiles — placeholder cards while fetching
// ══════════════════════════════════════════════════════════

fn renderSkeletonRows() void {
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    // 8 skeleton row-tiles mirroring renderItemCard layout (poster + info column).
    const SKELETONS: usize = 8;
    var i: usize = 0;
    while (i < SKELETONS) : (i += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 91000,
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
        });
        defer row.deinit();

        // Skeleton poster block
        var poster = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i + 91100,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .min_size_content = .{ .w = 50, .h = 75 },
            .max_size_content = .{ .w = 50, .h = 75 },
        });
        poster.deinit();

        // Info column — title bar + meta bar
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i + 91200,
            .expand = .horizontal,
            .gravity_y = 0.5,
            .padding = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
        });
        defer info.deinit();

        var title_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 91210,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .min_size_content = .{ .w = 160, .h = 12 },
            .max_size_content = .{ .w = 220, .h = 12 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
        title_bar.deinit();

        var meta_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 91220,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .min_size_content = .{ .w = 80, .h = 8 },
            .max_size_content = .{ .w = 120, .h = 8 },
        });
        meta_bar.deinit();
    }
}

// ══════════════════════════════════════════════════════════
// Item Card — horizontal card with poster + info + actions
// ══════════════════════════════════════════════════════════

// ══════════════════════════════════════════════════════════
// Poster Card — compact vertical card for horizontal scrolling
// ══════════════════════════════════════════════════════════

/// Card footer height below the poster — referenced by the uniform card
/// sizing AND the grid's virtualization row pitch. Keep single-sourced.
const CARD_FOOTER_H: f32 = 32;

fn updatePoster(slot_idx: usize, item: *const jf.PresentationItem) *PosterSlot {
    const slot = &poster_slots[slot_idx];
    const id = item.id[0..item.id_len];
    const hash = std.hash.Fnv1a_64.hash(id);
    if (slot.id_hash != hash and !slot.fetching) {
        poster_util.deinitPoster(&slot.pixels, &slot.tex);
        slot.w = 0;
        slot.h = 0;
        slot.id_hash = hash;
    }
    _ = poster_util.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.tex);
    if (item.has_image and slot.tex == null and slot.pixels == null and !slot.fetching) {
        var url_buf: [512]u8 = undefined;
        if (jf.primaryImageUrl(id, &url_buf)) |url| {
            poster_util.fetchAsync(url, &slot.pixels, &slot.w, &slot.h, &slot.fetching);
        }
    }
    return slot;
}

fn renderPosterCard(item: *const jf.PresentationItem, slot_idx: usize, idx: usize, card_w: f32, show_progress: bool) void {
    const poster_h: f32 = card_w * 1.45;
    // min == max height → uniform row pitch for the virtualized grid.
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(6),
        .min_size_content = .{ .w = card_w, .h = poster_h + CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = poster_h + CARD_FOOTER_H },
        .margin = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
    });
    defer card.deinit();

    // Poster image area — flat token placeholder.
    {
        var img_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 50,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = .{ .x = theme.radius.md, .y = theme.radius.md, .w = 0, .h = 0 },
            .min_size_content = .{ .w = card_w, .h = poster_h },
            .max_size_content = .{ .w = card_w, .h = poster_h },
        });

        const slot = updatePoster(slot_idx, item);
        if (slot.tex) |*tex| {
            // Clickable poster to play
            if (dvui.button(@src(), "", .{}, .{
                .id_extra = idx + 60,
                .expand = .both,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            })) {
                const id = item.id[0..item.id_len];
                jf.playItem(id);
            }
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                .id_extra = idx + 70,
                .expand = .both,
            });
        } else {
            // Play button as placeholder
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
                .id_extra = idx + 60,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.accent,
            })) {
                const id = item.id[0..item.id_len];
                jf.playItem(id);
            }
        }

        img_box.deinit();
    }

    // Progress bar
    if (show_progress and item.played_ticks > 0 and item.runtime_ticks > 0) {
        const pct = @as(f32, @floatFromInt(item.played_ticks)) / @as(f32, @floatFromInt(item.runtime_ticks));
        const clamped = std.math.clamp(pct, 0.0, 1.0);
        // Fill width derived from card_w (not a mid-build rect read) so it's
        // correct on the first frame.
        const fill_w = card_w * clamped;
        var pb = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx + 80,
            .expand = .horizontal,
            .min_size_content = .{ .w = 10, .h = 2 },
            .max_size_content = .{ .w = card_w, .h = 2 },
            .background = true,
            .color_fill = theme.colors.bg_elevated,
        });
        var fill = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx + 85,
            .min_size_content = .{ .w = fill_w, .h = 2 },
            .max_size_content = .{ .w = fill_w, .h = 2 },
            .background = true,
            .color_fill = theme.colors.accent,
        });
        fill.deinit();
        pb.deinit();
    }

    // Title — fills card width, dvui ellipsizes (no manual char truncation).
    var jf_title_buf: [256]u8 = undefined;
    _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(item.name[0..item.name_len], &jf_title_buf)}, .{
        .id_extra = idx + 90,
        .expand = .horizontal,
        .color_text = theme.colors.text_primary,
        .padding = .{ .x = 4, .y = 3, .w = 4, .h = 2 },
    });
}

// ══════════════════════════════════════════════════════════
// Search
// ══════════════════════════════════════════════════════════

fn renderSearch() void {
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer hdr.deinit();

        if (dvui.buttonIcon(@src(), "back", icons.tvg.lucide.@"arrow-left", .{}, .{}, .{
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_secondary,
            .padding = dvui.Rect.all(5),
            .corner_radius = theme.dims.rad_sm,
        })) {
            jf.goToLibraries();
        }

        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &search_buf },
        }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .margin = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        });
        const search_enter = te.enter_pressed;
        te.deinit();

        const clicked_search = dvui.buttonIcon(@src(), "search", icons.tvg.lucide.search, .{}, .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = theme.colors.text_on_accent,
            .padding = dvui.Rect.all(theme.radius.md),
            .corner_radius = theme.dims.rad_sm,
        });
        if (clicked_search or search_enter) {
            jf.searchFor(std.mem.sliceTo(&search_buf, 0));
        }
    }

    renderItems();
}

// ══════════════════════════════════════════════════════════
// Icon Helpers
// ══════════════════════════════════════════════════════════

fn iconForCollectionType(ct: []const u8) []const u8 {
    if (std.mem.eql(u8, ct, "movies")) return icons.tvg.lucide.film;
    if (std.mem.eql(u8, ct, "tvshows")) return icons.tvg.lucide.tv;
    if (std.mem.eql(u8, ct, "music")) return icons.tvg.lucide.music;
    if (std.mem.eql(u8, ct, "books")) return icons.tvg.lucide.book;
    if (std.mem.eql(u8, ct, "photos")) return icons.tvg.lucide.image;
    return icons.tvg.lucide.folder;
}
