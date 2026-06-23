const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const jf = @import("../services/jellyfin.zig");

// ══════════════════════════════════════════════════════════
// Main Entry Point
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    if (!state.app.jf.connected) {
        renderLoginForm();
        return;
    }

    // Auto-fetch libraries + resume on first load
    if (state.app.jf.library_count == 0 and !state.app.jf.is_loading.load(.acquire)) {
        jf.fetchLibraries();
    }
    if (!state.app.jf.resume_loaded.load(.acquire)) {
        jf.fetchResume();
    }

    switch (state.app.jf.view) {
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
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_drawer,
    });
    defer scroll.deinit();

    // Header
    {
        var hdr = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 20, .w = 16, .h = 16 },
        });
        defer hdr.deinit();

        _ = dvui.label(@src(), "Jellyfin", .{}, .{
            .color_text = theme.colors.accent,
        });
        _ = dvui.label(@src(), "Connect to your Jellyfin server", .{}, .{
            .color_text = theme.colors.text_muted,
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
            .color_text = theme.colors.text_muted,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });

        if (state.app.jf.server_url_len == 0) {
            const default = "http://localhost:8096";
            @memcpy(state.app.jf.server_url[0..default.len], default);
            state.app.jf.server_url_len = default.len;
        }

        var url_te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &state.app.jf.server_url },
        }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_card,
            .color_border = theme.colors.border_drawer,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        url_te.deinit();

        _ = dvui.label(@src(), "Username", .{}, .{
            .color_text = theme.colors.text_muted,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        var user_te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &state.app.jf.login_user_buf },
        }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_card,
            .color_border = theme.colors.border_drawer,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        user_te.deinit();

        _ = dvui.label(@src(), "Password", .{}, .{
            .color_text = theme.colors.text_muted,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        var pass_te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &state.app.jf.login_pass_buf },
        }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_card,
            .color_border = theme.colors.border_drawer,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 12 },
        });
        const login_enter = pass_te.enter_pressed;
        pass_te.deinit();

        if (state.app.jf.login_error_len > 0) {
            _ = dvui.label(@src(), "{s}", .{state.app.jf.login_error[0..state.app.jf.login_error_len]}, .{
                .color_text = theme.colors.danger,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
            });
        }

        if (!state.app.jf.is_loading.load(.acquire)) {
            const clicked_connect = dvui.button(@src(), "Connect", .{}, .{
                .expand = .horizontal,
                .color_fill = theme.colors.accent,
                .color_text = theme.colors.text_on_accent,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
            });
            if (clicked_connect or login_enter) {
                jf.authenticate();
            }
        } else {
            _ = dvui.label(@src(), "Connecting...", .{}, .{
                .expand = .horizontal,
                .color_text = theme.colors.text_muted,
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
            .color_fill = theme.colors.bg_drawer,
        });
        defer hdr.deinit();

        if (dvui.buttonIcon(@src(), "search", icons.tvg.lucide.search, .{}, .{}, .{
            .color_fill = theme.colors.bg_glass,
            .color_text = theme.colors.text_muted,
            .padding = dvui.Rect.all(5),
            .corner_radius = theme.dims.rad_sm,
        })) {
            state.app.jf.view = .Search;
        }

        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        _ = dvui.label(@src(), "Jellyfin", .{}, .{
            .color_text = theme.colors.accent,
            .gravity_y = 0.5,
        });

        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        if (dvui.buttonIcon(@src(), "disconnect", icons.tvg.lucide.@"log-out", .{}, .{}, .{
            .color_fill = theme.colors.bg_glass,
            .color_text = theme.colors.text_muted,
            .padding = dvui.Rect.all(5),
            .corner_radius = theme.dims.rad_sm,
        })) {
            jf.disconnect();
        }
    }

    if (state.app.jf.is_loading.load(.acquire) and state.app.jf.library_count == 0) {
        renderSkeletonRows();
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_drawer,
    });
    defer scroll.deinit();

    // Fully-empty state — connected, nothing loading, nothing to show.
    if (state.app.jf.library_count == 0 and state.app.jf.resume_count == 0) {
        components.emptyState(
            icons.tvg.lucide.@"library-big",
            "No items yet",
            "Connect Jellyfin or search to start.",
        );
        return;
    }

    // ── Continue Watching Section ──
    if (state.app.jf.resume_count > 0) {
        _ = dvui.label(@src(), "Continue Watching", .{}, .{
            .color_text = theme.colors.text_main,
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

        for (0..state.app.jf.resume_count) |i| {
            const item = &state.app.jf.resume_items[i];
            renderPosterCard(item, i + 5000, 130, true);
        }
    }

    // ── Library Rows ──
    if (state.app.jf.library_count > 0) {
        _ = dvui.label(@src(), "Libraries", .{}, .{
            .color_text = theme.colors.text_main,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 4 },
        });
    }

    for (0..state.app.jf.library_count) |i| {
        const lib = &state.app.jf.libraries[i];
        const name = lib.name[0..lib.name_len];
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
            .color_text = theme.colors.text_main,
            .padding = dvui.Rect.all(0),
        })) {
            const id = lib.id[0..lib.id_len];
            state.app.jf.nav_depth = 0;
            const plen = @min(name.len, state.app.jf.parent_name.len);
            @memcpy(state.app.jf.parent_name[0..plen], name[0..plen]);
            state.app.jf.parent_name_len = plen;
            state.app.jf.view = .Browse;
            jf.fetchItems(id);
        }

        dvui.icon(@src(), "", icons.tvg.lucide.@"chevron-right", .{}, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .color_text = theme.colors.text_muted,
            .min_size_content = .{ .w = 16, .h = 16 },
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
            .color_fill = theme.colors.bg_drawer,
        });
        defer hdr.deinit();

        if (dvui.buttonIcon(@src(), "back", icons.tvg.lucide.@"arrow-left", .{}, .{}, .{
            .color_fill = theme.colors.bg_glass,
            .color_text = theme.colors.text_muted,
            .padding = dvui.Rect.all(5),
            .corner_radius = theme.dims.rad_sm,
        })) {
            jf.popNav();
        }

        if (state.app.jf.parent_name_len > 0) {
            _ = dvui.label(@src(), "{s}", .{state.app.jf.parent_name[0..state.app.jf.parent_name_len]}, .{
                .color_text = theme.colors.text_main,
                .gravity_y = 0.5,
                .padding = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
            });
        }

        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        if (state.app.jf.is_loading.load(.acquire)) {
            _ = dvui.label(@src(), "Loading...", .{}, .{
                .color_text = theme.colors.text_muted,
                .gravity_y = 0.5,
            });
        }
    }

    if (state.app.jf.is_loading.load(.acquire) and state.app.jf.item_count == 0) {
        renderSkeletonRows();
        return;
    }

    if (state.app.jf.item_count == 0 and !state.app.jf.is_loading.load(.acquire)) {
        if (state.app.jf.view == .Search) {
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
        .color_fill = theme.colors.bg_drawer,
    });
    defer scroll.deinit();

    // Responsive poster grid (fills the page width; was one wide row per item).
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / 150)));
    const card_w: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));

    var i: usize = 0;
    while (i < state.app.jf.item_count) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 60000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and i + col < state.app.jf.item_count) : (col += 1) {
            renderPosterCard(&state.app.jf.items[i + col], i + col, card_w, true);
        }
        i += cols;
    }
}

// ══════════════════════════════════════════════════════════
// Skeleton tiles — placeholder cards while fetching
// ══════════════════════════════════════════════════════════

fn renderSkeletonRows() void {
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_drawer,
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

fn renderItemCard(item: *state.JfItem, idx: usize) void {
    const name = item.name[0..item.name_len];

    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = idx,
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
    });
    defer card.deinit();

    // Poster thumbnail — flat token placeholder.
    {
        var poster = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 100,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .min_size_content = .{ .w = 50, .h = 75 },
            .max_size_content = .{ .w = 50, .h = 75 },
        });
        defer poster.deinit();

        // Lazy-load poster texture
        if (item.poster_tex == null and item.poster_pixels != null) {
            const num_pixels = item.poster_w * item.poster_h;
            const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.poster_pixels.?.ptr)))[0..num_pixels];
            item.poster_tex = dvui.textureCreate(pixels_pma, item.poster_w, item.poster_h, .linear, .rgba_32) catch null;
            if (item.poster_tex != null) {
                @import("../core/alloc.zig").allocator.free(item.poster_pixels.?);
                item.poster_pixels = null;
            }
        }

        if (item.poster_tex) |*tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                .id_extra = idx + 150,
                .expand = .both,
                .corner_radius = dvui.Rect.all(theme.radius.sm),
            });
        } else {
            if (!item.poster_fetching and item.id_len > 0) jf.fetchPoster(item);
            dvui.icon(@src(), "", icons.tvg.lucide.film, .{}, .{
                .id_extra = idx + 150,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = theme.colors.text_tertiary,
            });
        }
    }

    // Info column
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 200,
            .expand = .horizontal,
            .padding = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
        });
        defer info.deinit();

        // Truncated name
        var name_trunc: [64]u8 = undefined;
        const display = if (name.len > 50) blk: {
            @memcpy(name_trunc[0..50], name[0..50]);
            @memcpy(name_trunc[50..53], "...");
            break :blk name_trunc[0..53];
        } else name;

        _ = dvui.label(@src(), "{s}", .{display}, .{
            .id_extra = idx + 210,
            .color_text = theme.colors.text_main,
        });

        // Meta row: type badge + year
        {
            var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = idx + 300,
                .padding = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            });
            defer meta.deinit();

            const mt = item.media_type[0..item.media_type_len];
            if (mt.len > 0) {
                // Media-type is metadata, not an affordance — quiet text.
                _ = dvui.label(@src(), "{s}", .{mt}, .{
                    .id_extra = idx + 310,
                    .color_text = theme.colors.text_muted,
                });
            }

            if (item.year > 0) {
                _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 320, .color_text = theme.colors.text_muted });
                var yr_buf: [8]u8 = undefined;
                const yr = std.fmt.bufPrintZ(&yr_buf, "{d}", .{item.year}) catch "?";
                _ = dvui.label(@src(), "{s}", .{yr}, .{ .id_extra = idx + 330, .color_text = theme.colors.text_muted });
            }

            // Runtime
            if (item.runtime_ticks > 0) {
                const mins = @divTrunc(item.runtime_ticks, 600000000);
                if (mins > 0) {
                    _ = dvui.label(@src(), " · ", .{}, .{ .id_extra = idx + 340, .color_text = theme.colors.text_muted });
                    var rt_buf: [16]u8 = undefined;
                    const rt = std.fmt.bufPrintZ(&rt_buf, "{d}m", .{mins}) catch "?";
                    _ = dvui.label(@src(), "{s}", .{rt}, .{ .id_extra = idx + 350, .color_text = theme.colors.text_muted });
                }
            }
        }

        // Progress bar for partially-watched items — thin accent slider.
        if (item.played_ticks > 0 and item.runtime_ticks > 0) {
            const pct = @as(f32, @floatFromInt(item.played_ticks)) / @as(f32, @floatFromInt(item.runtime_ticks));
            const clamped = std.math.clamp(pct, 0.0, 1.0);
            components.ProgressBar(@src(), clamped, "", idx + 400);
        }

        // Expandable overview
        if (item.overview_len > 0 and item.expanded) {
            _ = dvui.label(@src(), "{s}", .{item.overview[0..item.overview_len]}, .{
                .id_extra = idx + 500,
                .color_text = theme.colors.text_muted,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
            });
        }
    }

    // Action buttons
    {
        var acts = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 600,
            .gravity_y = 0.5,
        });
        defer acts.deinit();

        if (item.is_folder) {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-right", .{}, .{}, .{
                .id_extra = idx + 610,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.text_muted,
                .padding = dvui.Rect.all(4),
            })) {
                // Push current state before navigating deeper
                jf.pushNav();
                const id = item.id[0..item.id_len];
                const plen = @min(name.len, state.app.jf.parent_name.len);
                @memcpy(state.app.jf.parent_name[0..plen], name[0..plen]);
                state.app.jf.parent_name_len = plen;
                jf.fetchItems(id);
            }
        } else {
            // Play button
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.play, .{}, .{}, .{
                .id_extra = idx + 620,
                .color_fill = theme.colors.accent,
                .color_text = theme.colors.text_on_accent,
                .padding = dvui.Rect.all(theme.spacing.xs),
                .corner_radius = theme.dims.rad_sm,
                .min_size_content = .{ .w = 16, .h = 16 },
            })) {
                const id = item.id[0..item.id_len];
                const mt = item.media_type[0..item.media_type_len];
                if (std.mem.eql(u8, mt, "Audio")) {
                    jf.playAudioItem(id);
                } else {
                    jf.playItem(id);
                }
            }
        }

        // Info toggle
        if (item.overview_len > 0) {
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.info, .{}, .{}, .{
                .id_extra = idx + 630,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = if (item.expanded) theme.colors.accent else theme.colors.text_muted,
                .padding = dvui.Rect.all(3),
                .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            })) {
                item.expanded = !item.expanded;
            }
        }
    }

    // ── Right-click context menu ──
    {
        const ctext = dvui.context(@src(), .{ .rect = card.data().borderRectScale().r }, .{ .id_extra = idx + 800 });
        defer ctext.deinit();

        if (ctext.activePoint()) |cp| {
            var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{
                .id_extra = idx + 800,
                .color_fill = theme.colors.bg_card,
                .color_border = theme.colors.border_drawer,
            });
            defer fw.deinit();

            if ((dvui.menuItemLabel(@src(), "Copy Name", .{}, .{ .expand = .horizontal, .id_extra = idx + 810 })) != null) {
                dvui.clipboardTextSet(name);
                state.showToast("Name copied");
                fw.close();
            }
        }
    }
}

// ══════════════════════════════════════════════════════════
// Poster Card — compact vertical card for horizontal scrolling
// ══════════════════════════════════════════════════════════

fn renderPosterCard(item: *state.JfItem, idx: usize, card_w: f32, show_progress: bool) void {
    const poster_h: f32 = card_w * 1.45;
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx,
        .background = true,
        .color_fill = theme.colors.bg_card,
        .corner_radius = dvui.Rect.all(6),
        .min_size_content = .{ .w = card_w, .h = 10 },
        .max_size_content = .{ .w = card_w, .h = poster_h + 32 },
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

        // Texture from pixels
        if (item.poster_tex == null and item.poster_pixels != null) {
            const num_pixels = item.poster_w * item.poster_h;
            const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.poster_pixels.?.ptr)))[0..num_pixels];
            item.poster_tex = dvui.textureCreate(pixels_pma, item.poster_w, item.poster_h, .linear, .rgba_32) catch null;
            if (item.poster_tex != null) {
                @import("../core/alloc.zig").allocator.free(item.poster_pixels.?);
                item.poster_pixels = null;
            }
        }

        if (item.poster_tex) |*tex| {
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
            if (!item.poster_fetching and item.id_len > 0) jf.fetchPoster(item);
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
            .color_fill = theme.colors.bg_input,
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
    _ = dvui.label(@src(), "{s}", .{item.name[0..item.name_len]}, .{
        .id_extra = idx + 90,
        .expand = .horizontal,
        .color_text = theme.colors.text_main,
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
            .color_fill = theme.colors.bg_drawer,
        });
        defer hdr.deinit();

        if (dvui.buttonIcon(@src(), "back", icons.tvg.lucide.@"arrow-left", .{}, .{}, .{
            .color_fill = theme.colors.bg_glass,
            .color_text = theme.colors.text_muted,
            .padding = dvui.Rect.all(5),
            .corner_radius = theme.dims.rad_sm,
        })) {
            state.app.jf.view = .Libraries;
        }

        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &state.app.jf.search_buf },
        }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_card,
            .color_border = theme.colors.border_drawer,
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
            jf.searchItems();
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
