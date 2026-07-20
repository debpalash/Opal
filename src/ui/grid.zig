const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const player = @import("../player/player.zig");
const logs = @import("../core/logs.zig");
const search = @import("../services/search.zig");
const transfers = @import("../services/transfers.zig");
const theme = @import("theme.zig");
const metadata_dialog = @import("metadata_dialog.zig");
const components = @import("components.zig");

/// Normalize a path / URL into a user-facing display name:
///   1. basename (after last `/` or `\\`)
///   2. strip short file extension (`.mkv`, `.mp4`, ...)
///   3. replace `.` and `_` with spaces, collapse runs of spaces
///   4. trim leading/trailing whitespace
/// Writes into `out` (capacity = `out.len`) and returns the populated
/// slice. Returns `raw` unchanged if cleanup would produce an empty
/// string.
pub fn cleanDisplayName(out: []u8, raw: []const u8) []const u8 {
    if (out.len == 0) return raw;

    // Step 1: basename
    var basename_start: usize = 0;
    for (raw, 0..) |ch, ci| {
        if (ch == '/' or ch == '\\') basename_start = ci + 1;
    }
    const basename = raw[basename_start..];

    // Step 2: strip short extension
    var name_end: usize = basename.len;
    {
        var last_dot: ?usize = null;
        for (basename, 0..) |ch, ci| {
            if (ch == '.') last_dot = ci;
        }
        if (last_dot) |dot| {
            if (basename.len - dot <= 6) name_end = dot;
        }
    }
    const stripped = basename[0..name_end];

    // Step 3: replace dots/underscores with spaces, collapse multiples
    var written: usize = 0;
    for (stripped) |ch| {
        if (written >= out.len - 1) break;
        const out_ch: u8 = if (ch == '.' or ch == '_') ' ' else ch;
        if (out_ch == ' ' and written > 0 and out[written - 1] == ' ') continue;
        out[written] = out_ch;
        written += 1;
    }

    // Step 4: trim trailing then leading spaces
    while (written > 0 and out[written - 1] == ' ') written -= 1;
    var trim_start: usize = 0;
    while (trim_start < written and out[trim_start] == ' ') trim_start += 1;
    if (trim_start > 0 and trim_start < written) {
        std.mem.copyForwards(u8, out[0 .. written - trim_start], out[trim_start..written]);
        written -= trim_start;
    }

    return if (written > 0) out[0..written] else raw;
}

/// The chat transcript: inline result cards + message bubbles + phase label.
/// NO scroll wrapper — the host (home.zig's chat mode) owns the page scroll,
/// ChatGPT-style. Renders nothing meaningful until a conversation exists.
pub fn renderChatMessages() void {
    const ai_chat = @import("../services/ai_chat.zig");

    // Inline results cards with play buttons — render at top for visibility
    ai_chat.renderInlineResults();

    var mi: usize = 0;
    while (mi < ai_chat.message_count) : (mi += 1) {
        const m = ai_chat.messages[mi];
        if (m.role == .system) continue; // tool-response internals, not shown to user
        // Keep the in-flight assistant bubble visible (shows the thinking
        // spinner) so a reply-in-progress never looks like a blank/dead
        // bubble; older empty messages are still skipped.
        const active_empty = m.text_len == 0 and m.role == .assistant and
            ai_chat.is_generating.load(.acquire) and mi + 1 == ai_chat.message_count;
        if (m.text_len == 0 and !active_empty) continue;

        // Streamed text is worker-written — snapshot + validate before dvui
        // measures it (a frame landing mid-codepoint would panic).
        var mbuf: [2048]u8 = undefined;
        const msg_text = @import("../core/text.zig").safeUtf8Buf(m.text[0..m.text_len], &mbuf);

        if (m.role == .user) {
            // ── User: right-aligned filled bubble, capped width ──
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = mi + 70000,
                .expand = .horizontal,
            });
            defer row.deinit();
            {
                var sp = dvui.box(@src(), .{}, .{ .id_extra = mi + 70001, .expand = .horizontal });
                sp.deinit();
            }
            var bubble = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = mi + 70002,
                .background = true,
                .color_fill = theme.colors.bg_elevated,
                .corner_radius = dvui.Rect.all(theme.radius.xl),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
                .margin = .{ .x = theme.spacing.xxl, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.xs },
                .max_size_content = dvui.Options.MaxSize.width(560),
            });
            defer bubble.deinit();
            var tl = dvui.textLayout(@src(), .{}, .{
                .id_extra = mi + 72000,
                .background = false,
                .padding = dvui.Rect.all(0),
            });
            tl.addText(msg_text, .{ .color_text = theme.colors.text_primary });
            tl.deinit();
        } else {
            // ── Assistant: avatar + flowing text on the page (no bubble) ──
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = mi + 70000,
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.sm },
            });
            defer row.deinit();

            // Avatar chip — the console's mark.
            {
                var av = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = mi + 70003,
                    .background = true,
                    .color_fill = theme.colors.bg_surface,
                    .corner_radius = dvui.Rect.all(theme.radius.pill),
                    .min_size_content = .{ .w = 26, .h = 26 },
                    .max_size_content = dvui.Options.MaxSize.size(.{ .w = 26, .h = 26 }),
                    .margin = .{ .x = 0, .y = 2, .w = theme.spacing.sm, .h = 0 },
                });
                defer av.deinit();
                dvui.icon(@src(), "ai-avatar", icons.tvg.lucide.sparkles, .{}, .{
                    .id_extra = mi + 70004,
                    .color_text = theme.colors.accent,
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                });
            }

            var colm = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = mi + 70005,
                .expand = .horizontal,
            });
            defer colm.deinit();

            if (m.text_len == 0) {
                // Awaiting the first streamed token — live spinner, not a
                // frozen label (self-refreshing under the gated frame loop).
                var trow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = mi + 70006 });
                defer trow.deinit();
                dvui.spinner(@src(), .{
                    .id_extra = mi + 70007,
                    .color_text = theme.colors.accent,
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .gravity_y = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
                });
                _ = dvui.label(@src(), "{s}", .{ai_chat.phaseLabel(ai_chat.phase)}, .{
                    .id_extra = mi + 72000,
                    .color_text = theme.colors.text_tertiary,
                    .gravity_y = 0.5,
                });
            } else {
                var tl = dvui.textLayout(@src(), .{}, .{
                    .id_extra = mi + 72000,
                    .background = false,
                    .padding = dvui.Rect.all(0),
                });
                tl.addText(msg_text, .{ .color_text = theme.colors.text_primary });
                tl.deinit();

                // Action row — copy / star / regenerate, quiet under the text.
                var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = mi + 71500,
                    .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
                });
                defer actions.deinit();

                var copy_wd: dvui.WidgetData = undefined;
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.copy, .{}, .{}, .{
                    .id_extra = mi + 71600,
                    .data_out = &copy_wd,
                    .color_text = theme.colors.text_tertiary,
                    .color_fill = theme.transparent,
                    .color_fill_hover = theme.colors.bg_hover,
                    .border = dvui.Rect.all(0),
                    .corner_radius = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.xs, .y = 2, .w = theme.spacing.xs, .h = 2 },
                    .min_size_content = theme.iconSize(.xs),
                })) {
                    dvui.clipboardTextSet(msg_text);
                    state.showToast("Copied");
                }
                components.tipId(@src(), copy_wd, "Copy", mi);

                var star_wd: dvui.WidgetData = undefined;
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.star, .{}, .{}, .{
                    .id_extra = mi + 71700,
                    .data_out = &star_wd,
                    .color_text = if (m.starred) theme.colors.warning else theme.colors.text_tertiary,
                    .color_fill = theme.transparent,
                    .color_fill_hover = theme.colors.bg_hover,
                    .border = dvui.Rect.all(0),
                    .corner_radius = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.xs, .y = 2, .w = theme.spacing.xs, .h = 2 },
                    .min_size_content = theme.iconSize(.xs),
                })) {
                    ai_chat.toggleStar(mi);
                }
                components.tipId(@src(), star_wd, if (m.starred) "Unfavorite" else "Favorite", mi);

                var regen_wd: dvui.WidgetData = undefined;
                if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"rotate-ccw", .{}, .{}, .{
                    .id_extra = mi + 71800,
                    .data_out = &regen_wd,
                    .color_text = theme.colors.text_tertiary,
                    .color_fill = theme.transparent,
                    .color_fill_hover = theme.colors.bg_hover,
                    .border = dvui.Rect.all(0),
                    .corner_radius = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.xs, .y = 2, .w = theme.spacing.xs, .h = 2 },
                    .min_size_content = theme.iconSize(.xs),
                })) {
                    ai_chat.regenerateFrom(mi);
                }
                components.tipId(@src(), regen_wd, "Regenerate", mi);
            }
        }
    }

    // Trailing phase line (tool activity while the LAST message already has
    // text — e.g. "Searching TMDB…" between tool call and result).
    {
        const label = ai_chat.phaseLabel(ai_chat.phase);
        if (label.len > 0 and ai_chat.is_generating.load(.acquire)) {
            var prow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .x = 34, .y = theme.spacing.xs, .w = 0, .h = 0 } });
            defer prow.deinit();
            dvui.spinner(@src(), .{
                .color_text = theme.colors.accent,
                .min_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
            _ = dvui.label(@src(), "{s}", .{label}, .{
                .color_text = theme.colors.text_tertiary,
                .gravity_y = 0.5,
            });
        }
    }
}

pub fn computeGridColumns() usize {
    if (state.app.fullscreen_player_idx != null) return 1;
    const n = state.app.players.items.len;
    if (n <= 1) return 1;

    return switch (state.app.grid_mode) {
        .auto => blk: {
            const w: f32 = @floatFromInt(state.app.win_w);
            const h: f32 = @floatFromInt(state.app.win_h);

            if (w <= 0 or h <= 0) break :blk if (n <= 4) @as(usize, 2) else 3;

            const target_ratio: f32 = 16.0 / 9.0;
            var best_cols: usize = 1;
            var max_area: f32 = 0;

            var col_idx: usize = 1;
            while (col_idx <= n) : (col_idx += 1) {
                const c_f: f32 = @floatFromInt(col_idx);
                const r_i = (n + col_idx - 1) / col_idx;
                const r_f: f32 = @floatFromInt(r_i);

                const cell_w = w / c_f;
                const cell_h = h / r_f;

                const possible_w = @min(cell_w, cell_h * target_ratio);
                const possible_h = possible_w / target_ratio;

                const area = possible_w * possible_h;
                if (area > max_area) {
                    max_area = area;
                    best_cols = col_idx;
                }
            }
            break :blk best_cols;
        },
        .cols_1 => 1,
        .cols_2 => 2,
        .cols_3 => 3,
        .cols_4 => 4,
    };
}

pub fn muteBackgroundPlayers() void {
    // Only update volume when active player changes (not every frame)
    const VS = struct {
        var last_active: usize = 999;
    };
    if (VS.last_active == state.app.active_player_idx) return;
    VS.last_active = state.app.active_player_idx;

    for (state.app.players.items, 0..) |p, i| {
        if (i == state.app.active_player_idx) {
            // Restore active cell volume
            var vol_cmd: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&vol_cmd, "set volume {d}", .{@as(i32, @intFromFloat(p.cell_volume))})) |cmd| {
                _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
            } else |_| {}
        } else {
            _ = c.mpv.mpv_command_string(p.mpv_ctx, "set volume 0");
        }
    }
}

/// The audio now-playing pane — cover art + title/subtitle over a black fill,
/// shown for a podcast episode / radio station (no video frame, metadata set).
/// The caller gates this on `p.np_title_len > 0 and p.texture == null`. The
/// cover art rides the shared poster daemon (async fetch → uploadIfReady →
/// texture), with a URL-hash guard for a leak-free swap when the item changes
/// while a prior fetch is still in flight (same pattern as the podcast covers).
/// UI-thread only.
fn renderAudioNowPlaying(i: usize, p: *player.MediaPlayer) void {
    const text_mod = @import("../core/text.zig");

    // Advance the cover-art fetch/upload (leak-free, UI-thread only).
    p.tickNowPlayingArt();

    // Black cinematic fill + click-to-select/pause underneath the content.
    var np_overlay = dvui.overlay(@src(), .{ .id_extra = i + 8800, .expand = .both });
    defer np_overlay.deinit();

    if (dvui.button(@src(), "", .{}, .{
        .id_extra = i + 8801,
        .expand = .both,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .color_text = theme.colors.text_primary,
        .border = dvui.Rect.all(0),
        .corner_radius = theme.dims.rad_sm,
    })) {
        state.app.active_player_idx = i;
        p.togglePause();
    }

    // NOT expanded: an expanded box fills the pane and its children stack from
    // the TOP (gravity can't center content inside an already-full box), which
    // pinned the art + title to the top with dead space below. Sized to content,
    // gravity_x/y then centers the whole block in the pane.
    var stack = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = i + 8802,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    defer stack.deinit();

    const COVER: f32 = 240;
    if (p.np_art_tex) |*tex| {
        _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
            .id_extra = i + 8803,
            .min_size_content = .{ .w = COVER, .h = COVER },
            .max_size_content = .{ .w = COVER, .h = COVER },
            .corner_radius = theme.dims.rad_md,
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 20 },
        });
    } else {
        // No art yet (loading) or the item carries none → music-note glyph.
        _ = dvui.icon(@src(), "np-art-fallback", icons.tvg.lucide.music, .{}, .{
            .id_extra = i + 8803,
            .color_text = theme.colors.text_tertiary,
            .min_size_content = .{ .w = 96, .h = 96 },
            .max_size_content = .{ .w = 96, .h = 96 },
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 20 },
        });
    }

    // Title — large, centered, one line (ellipsized by the width cap).
    // safeUtf8Buf: fixed buffers may be cut mid-codepoint / hold odd bytes.
    {
        var title_wrap = dvui.box(@src(), .{}, .{
            .id_extra = i + 8804,
            .gravity_x = 0.5,
            .max_size_content = .{ .w = 520, .h = std.math.floatMax(f32) },
        });
        defer title_wrap.deinit();
        var tbuf: [256]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(p.np_title[0..p.np_title_len], &tbuf)}, .{
            .id_extra = i + 8805,
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading,
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
    }

    if (p.np_subtitle_len > 0) {
        var sbuf: [192]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(p.np_subtitle[0..p.np_subtitle_len], &sbuf)}, .{
            .id_extra = i + 8806,
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
        });
    }
}

pub fn renderGrid() !void {
    const grid_columns = computeGridColumns();
    muteBackgroundPlayers();

    var grid_wrapper = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer grid_wrapper.deinit();

    var current_row: ?*dvui.BoxWidget = null;
    var draw_col: usize = 0;

    for (state.app.players.items, 0..) |p, i| {
        if (state.app.fullscreen_player_idx != null and state.app.fullscreen_player_idx.? != i) continue;

        if (draw_col % grid_columns == 0) {
            if (current_row != null) current_row.?.deinit();
            current_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = draw_col, .min_size_content = .{ .w = 10, .h = 10 }, .expand = .both });
        }
        draw_col += 1;

        const is_active = i == state.app.active_player_idx and state.app.players.items.len > 1;
        // Active cell carries a single 2px accent hairline along its top edge —
        // the one accent affordance for "which pane is live". Inactive = none.
        const cell_color = if (is_active) theme.colors.accent else theme.colors.bg_deep;
        const border_rect: dvui.Rect = if (is_active)
            .{ .x = 0, .y = 2, .w = 0, .h = 0 }
        else
            .{ .x = 0, .y = 0, .w = 0, .h = 0 };

        // Cap cell width so text-heavy panes (browser) can't push other cells away
        const grid_w = grid_wrapper.data().borderRectScale().r.w;
        const max_cell_w: f32 = if (grid_columns > 0 and grid_w > 0) grid_w / @as(f32, @floatFromInt(grid_columns)) else 9999;

        // While a video is showing, the leftover space around the aspect-fit image
        // is letterbox — fill it BLACK (cinematic) instead of the navy app bg, so
        // it reads as proper bars, not a UI gap. Empty/loading cells keep bg_deep.
        const cell_fill = if (p.texture != null) dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 255 } else theme.colors.bg_deep;

        // Fullscreen → edge-to-edge: drop the inset margin + rounded corners.
        const fs = state.app.fullscreen_player_idx != null;
        const cell_margin = if (fs) dvui.Rect.all(0) else dvui.Rect.all(2);
        const cell_radius = if (fs) dvui.Rect.all(0) else theme.dims.rad_sm;
        var cell_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .min_size_content = .{ .w = 10, .h = 10 }, .max_size_content = .{ .w = max_cell_w, .h = std.math.floatMax(f32) }, .expand = .both, .background = true, .color_fill = cell_fill, .color_border = cell_color, .border = border_rect, .margin = cell_margin, .corner_radius = cell_radius });

        // Single wrapper overlay — ensures video content and control badges layer
        // rather than splitting the cell height vertically
        var cell_wrapper = dvui.overlay(@src(), .{ .id_extra = i + 11000, .expand = .both });

        // When not showing MPV, still drain its render context to prevent blocking.
        // Guarded on a non-null render context: in windowed mode mpv_gl is always
        // non-null so this runs exactly as before; a null context (e.g. headless,
        // or a render-context that failed to create) skips it safely.
        if (p.provider != .mpv and p.mpv_gl != null) {
            const flags = c.mpv.mpv_render_context_update(p.mpv_gl);
            if ((flags & c.mpv.MPV_RENDER_UPDATE_FRAME) != 0) {
                const size = [2]c_int{ player.video_w, player.video_h };
                const img_format = "rgba";
                const pitch: usize = player.video_w * 4;
                var drain_params = [_]c.mpv.mpv_render_param{
                    .{ .type = c.mpv.MPV_RENDER_PARAM_SW_SIZE, .data = @constCast(&size) },
                    .{ .type = c.mpv.MPV_RENDER_PARAM_SW_FORMAT, .data = @constCast(img_format.ptr) },
                    .{ .type = c.mpv.MPV_RENDER_PARAM_SW_STRIDE, .data = @constCast(&pitch) },
                    .{ .type = c.mpv.MPV_RENDER_PARAM_SW_POINTER, .data = p.pixels.ptr },
                    .{ .type = c.mpv.MPV_RENDER_PARAM_INVALID, .data = null },
                };
                _ = c.mpv.mpv_render_context_render(p.mpv_gl, &drain_params);
            }
        }

        switch (p.provider) {
            .mpv => {
                // ── MPV Video Player ──
                // All render-context + texture work is gated on a non-null render
                // context. In windowed mode mpv_gl is always non-null so this block
                // executes exactly as before; a null context (headless, or a context
                // that failed to create) skips the GPU/texture path safely. p.texture
                // then stays null, and the `if (p.texture) |*tex|` display block below
                // is already null-safe.
                if (p.mpv_gl != null) {
                    const flags = c.mpv.mpv_render_context_update(p.mpv_gl);

                    // Render at the video's NATIVE size (capped to the 1080p
                    // buffer, aspect-preserving) instead of a fixed 1920×1080.
                    // The fixed target made mpv software-scale + RGBA-convert
                    // 8.3MB per frame and upload all of it to the GPU even
                    // for a 720p file (3.7MB) — a large share of the playback
                    // CPU. The GPU upscales the smaller texture for free.
                    var vw: i64 = 0;
                    var vh: i64 = 0;
                    _ = c.mpv.mpv_get_property(p.mpv_ctx, "dwidth", c.mpv.MPV_FORMAT_INT64, &vw);
                    _ = c.mpv.mpv_get_property(p.mpv_ctx, "dheight", c.mpv.MPV_FORMAT_INT64, &vh);
                    var rw: c_int = player.video_w;
                    var rh: c_int = player.video_h;
                    if (vw > 0 and vh > 0) {
                        if (vw <= player.video_w and vh <= player.video_h) {
                            rw = @intCast(vw);
                            rh = @intCast(vh);
                        } else {
                            // >1080p source: scale down to fit, keep aspect.
                            const sc = @min(
                                @as(f64, @floatFromInt(player.video_w)) / @as(f64, @floatFromInt(vw)),
                                @as(f64, @floatFromInt(player.video_h)) / @as(f64, @floatFromInt(vh)),
                            );
                            rw = @intFromFloat(@as(f64, @floatFromInt(vw)) * sc);
                            rh = @intFromFloat(@as(f64, @floatFromInt(vh)) * sc);
                        }
                        rw = @max(2, rw);
                        rh = @max(2, rh);
                    }
                    const size = [2]c_int{ rw, rh };
                    const img_format = "rgba";
                    const pitch: usize = @as(usize, @intCast(rw)) * 4;
                    const npix: usize = @as(usize, @intCast(rw)) * @as(usize, @intCast(rh));
                    // Don't let mpv SLEEP the UI thread for frame pacing:
                    // by default render() blocks until the frame's target
                    // display time (production samples showed 86% of the
                    // main thread parked in a cond_wait inside libmpv).
                    // The frame callback already wakes us exactly when a
                    // new frame exists; render immediately and move on.
                    var no_block: c_int = 0;
                    var render_params = [_]c.mpv.mpv_render_param{
                        .{ .type = c.mpv.MPV_RENDER_PARAM_SW_SIZE, .data = @constCast(&size) },
                        .{ .type = c.mpv.MPV_RENDER_PARAM_SW_FORMAT, .data = @constCast(img_format.ptr) },
                        .{ .type = c.mpv.MPV_RENDER_PARAM_SW_STRIDE, .data = @constCast(&pitch) },
                        .{ .type = c.mpv.MPV_RENDER_PARAM_SW_POINTER, .data = p.pixels.ptr },
                        .{ .type = c.mpv.MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, .data = &no_block },
                        .{ .type = c.mpv.MPV_RENDER_PARAM_INVALID, .data = null },
                    };

                    if ((flags & c.mpv.MPV_RENDER_UPDATE_FRAME) != 0) {
                        if (c.mpv.mpv_render_context_render(p.mpv_gl, &render_params) >= 0) {
                            // MPV renders with "rgba" format — alpha is already 0xFF, no fill needed
                            // Size changed (new file / track switch) → the old
                            // texture can't be updated in place; recreate.
                            if (p.texture) |tex| {
                                if (tex.width != @as(u32, @intCast(rw)) or tex.height != @as(u32, @intCast(rh))) {
                                    dvui.textureDestroyLater(tex);
                                    p.texture = null;
                                }
                            }
                            if (p.texture == null) {
                                p.texture = try dvui.textureCreate(p.pixels[0..npix], @intCast(rw), @intCast(rh), .linear, .rgba_32);
                            } else {
                                try dvui.Texture.update(&p.texture.?, p.pixels[0..npix], .linear);
                            }
                            // First frame rendered — clear loading state
                            p.is_loading = false;
                            // Try to resume from saved position on first frame
                            p.tryResumePosition();
                            // Only request UI refresh when we actually have a new video frame
                            dvui.refresh(null, @src(), null);
                        }
                    }
                }

                // Periodic position save (every ~120 frames ≈ 4 sec)
                p.save_counter +%= 1;
                if (p.save_counter % 120 == 0) {
                    p.saveCurrentPosition();
                }

                if (p.np_title_len > 0 and p.texture == null) {
                    // ── Audio now-playing pane (podcast / radio) ──
                    // No video frame + rich metadata set → show cover art +
                    // title/subtitle instead of the black/empty hero state.
                    // Gated on texture == null so it never masks real video, and
                    // on np_title_len > 0 so it never hijacks an idle player.
                    renderAudioNowPlaying(i, p);
                } else if (p.texture) |*tex| {
                    var cell_overlay = dvui.overlay(@src(), .{ .id_extra = i, .expand = .both });
                    // Aspect-preserving fit (letterbox), not stretch. The texture is
                    // already rendered at the video's native display aspect, so feed
                    // that ratio to dvui via .expand = .ratio. We pass the aspect via a
                    // deliberately TINY min_size_content (aspect*10 × 10) so the widget
                    // never reports a large min size to the parent layout — .ratio only
                    // uses min_size's *shape*, then grows it to fill the cell keeping the
                    // ratio. Without this, .expand = .both stretched the frame to the full
                    // cell, visibly distorting video in full-height / fullscreen windows.
                    const tex_ar: f32 = if (tex.height > 0)
                        @as(f32, @floatFromInt(tex.width)) / @as(f32, @floatFromInt(tex.height))
                    else
                        16.0 / 9.0;
                    const img_wd = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{ .id_extra = i, .min_size_content = .{ .w = tex_ar * 10.0, .h = 10.0 }, .expand = .ratio, .gravity_x = 0.5, .gravity_y = 0.5 });

                    // Raw click-on-video handling. Guards matter here:
                    //  • compare against the PHYSICAL screen rect — me.p is
                    //    physical; img_wd.rect is parent-local (they only
                    //    coincided for a single cell at 1x scale);
                    //  • skip events belonging to floating windows (pickers,
                    //    modals) — the raw event list contains those too, so a
                    //    click inside a popover used to ALSO toggle pause;
                    //  • skip the control-bar band — its buttons render AFTER
                    //    the grid each frame, so a click on Play/Pause fired
                    //    both handlers (pause toggled on press, button on
                    //    release → net no-op) and Rewind also paused;
                    //  • skip while the pre-download metadata dialog (a plain
                    //    overlay, not a floating window) is up.
                    const img_rs = img_wd.borderRectScale().r;
                    const footer_mod = @import("footer.zig");
                    const cell_clicks_blocked = state.app.pending_magnet_tid >= 0 or state.app.settings_open;
                    for (dvui.events()) |*e| {
                        if (e.evt == .mouse and !e.handled and !cell_clicks_blocked) {
                            const me = e.evt.mouse;
                            if (me.floating_win != dvui.subwindowCurrentId()) continue;
                            const over_controls = state.app.show_cell_overlay and footer_mod.mouseInControlPanel(me.p);
                            if (!over_controls and me.p.x >= img_rs.x and me.p.x <= img_rs.x + img_rs.w and me.p.y >= img_rs.y and me.p.y <= img_rs.y + img_rs.h) {
                                if (me.action == .press and me.button == .left) {
                                    state.app.active_player_idx = i;
                                    // Double-click detection → fullscreen toggle
                                    const DblClick = struct {
                                        var last_click_ms: i64 = 0;
                                        var last_click_cell: usize = 999;
                                    };
                                    const now_ms = @import("../core/io_global.zig").milliTimestamp();
                                    if (DblClick.last_click_cell == i and now_ms - DblClick.last_click_ms < 500) {
                                        // Double-click: toggle fullscreen
                                        if (state.app.fullscreen_player_idx == null) {
                                            state.app.fullscreen_player_idx = i;
                                        } else {
                                            state.app.fullscreen_player_idx = null;
                                        }
                                        DblClick.last_click_ms = 0; // reset to prevent triple-click
                                    } else {
                                        // Single click: toggle pause
                                        p.togglePause();
                                        DblClick.last_click_ms = now_ms;
                                        DblClick.last_click_cell = i;
                                    }
                                } else if (me.action == .release and me.button == .left) {
                                    if (state.app.dragging_magnet_len > 0) {
                                        state.app.active_player_idx = i;
                                        search.loadTorrentToPlayer(state.app.dragging_magnet_buf[0..state.app.dragging_magnet_len]);
                                    }
                                }
                            }
                        }
                    }

                    if (p.is_torrent and (!p.torrent_is_ready or p.is_buffering_paused)) {
                        // Background darkener overlay
                        var dim_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .both, .background = true, .color_fill = theme.colors.overlay, .corner_radius = theme.dims.rad_sm });
                        dim_box.deinit();

                        var o_lay = dvui.overlay(@src(), .{ .id_extra = i, .expand = .both });
                        defer o_lay.deinit();

                        // Borderless elevated panel — separated from the dim backdrop by
                        // its fill tier and whitespace alone (no glass outline).
                        var loading_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .gravity_y = 0.5, .gravity_x = 0.5, .background = true, .color_fill = theme.colors.bg_elevated, .padding = theme.dims.pad_lg, .margin = dvui.Rect.all(theme.spacing.xl), .corner_radius = theme.dims.rad_lg, .min_size_content = .{ .w = 320, .h = 10 } });

                        var t_name: [256]u8 = undefined;
                        c.mpv.torrent_get_name(state.torrentSession(), p.current_torrent_id, &t_name, 256);
                        const name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse 255;

                        // Torrent name is untrusted metadata (non-UTF-8 / truncated
                        // mid-codepoint at the 256-byte cap) — validate before dvui.
                        _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(t_name[0..name_len])}, .{ .color_text = theme.colors.text_primary, .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 } });

                        var buf_pct: f32 = 0;
                        var dl_rate: i32 = 0;
                        var peers: i32 = 0;
                        var buf_path: [512]u8 = undefined;

                        if (p.current_torrent_id >= 0) {
                            _ = c.mpv.torrent_poll(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, &buf_path, 512, &buf_pct, &dl_rate, &peers);
                        }

                        const is_dead = p.metadata_start_time > 0 and @import("../core/io_global.zig").timestamp() - p.metadata_start_time > 15 and peers == 0 and !p.has_metadata;

                        if (is_dead) {
                            // Transient failure — danger as text only, no resting fill.
                            _ = dvui.label(@src(), "Dead torrent", .{}, .{ .color_text = theme.colors.danger, .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 } });
                            _ = dvui.label(@src(), "No peers found after 15 seconds.", .{}, .{ .color_text = theme.colors.text_secondary, .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 } });
                            if (dvui.button(@src(), "Close Stream", .{}, .{
                                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                                .color_text = theme.colors.danger,
                                .border = dvui.Rect.all(0),
                                .corner_radius = theme.dims.rad_sm,
                            })) {
                                p.current_torrent_id = -1;
                                p.is_torrent = false;
                                p.torrent_is_ready = false;
                                p.has_metadata = false;
                                p.metadata_start_time = 0;
                                if (state.app.active_player_idx == i) state.app.active_player_idx = 0;
                            }
                        } else {
                            const dr_mb = @as(f32, @floatFromInt(dl_rate)) / (1024.0 * 1024.0);
                            var status_lb: [128]u8 = undefined;
                            if (std.fmt.bufPrintZ(&status_lb, "Downloading: {d:.1} MB/s | {d} Peers", .{ dr_mb, peers })) |msg| {
                                _ = dvui.label(@src(), "{s}", .{msg}, .{ .color_text = theme.colors.text_secondary, .margin = .{ .y = theme.spacing.sm } });
                            } else |_| {}

                            // Show readiness, NOT whole-torrent progress.
                            //
                            // The old bar read 11% while the bytes the demuxer was
                            // actually blocked on (the container index at the END of
                            // the file) were at 0% — so it counted up encouragingly
                            // and playback never began. stream_gate reports progress
                            // against the head + index windows that actually gate the
                            // start, so 100% here means "it will now play".
                            const gate = @import("../player/stream_gate.zig");
                            const gated = p.current_torrent_id >= 0 and p.selected_file_idx >= 0 and
                                gate.hasPlan(p.current_torrent_id, p.selected_file_idx);

                            const shown: f32 = if (gated)
                                @as(f32, @floatFromInt(gate.bufferPercent(p.current_torrent_id, p.selected_file_idx))) / 100.0
                            else
                                buf_pct;

                            var prog_lb: [64]u8 = undefined;
                            const label: []const u8 = if (gated) "Buffering" else "Buffer";
                            if (std.fmt.bufPrintZ(&prog_lb, "{s}: {d}%", .{ label, @as(i32, @intFromFloat(shown * 100.0)) })) |msg| {
                                components.ProgressBar(@src(), shown, msg, i);
                            } else |_| {}
                        }

                        loading_box.deinit();
                    } else if (p.is_buffering_paused) {
                        var loading_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .gravity_y = 0.5, .gravity_x = 0.5, .background = true, .color_fill = theme.colors.bg_elevated, .padding = theme.dims.pad_md, .corner_radius = theme.dims.rad_md });
                        _ = dvui.label(@src(), "Initializing network…", .{}, .{ .color_text = theme.colors.text_secondary });
                        loading_box.deinit();
                    }

                    if (state.app.show_cell_overlay) {
                        var tr_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .none, .gravity_x = 1.0, .gravity_y = 0.0, .padding = dvui.Rect.all(8) });

                        var x_bg = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .background = true, .color_fill = theme.colors.overlay, .corner_radius = dvui.Rect.all(theme.radius.pill), .padding = theme.dims.pad_xs });

                        if (dvui.buttonIcon(@src(), "CellClose", icons.tvg.lucide.x, .{}, .{}, .{ .id_extra = i, .color_text = theme.colors.text_secondary, .color_fill = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .border = dvui.Rect.all(0) })) {
                            state.app.pending_remove_player_idx = @as(i32, @intCast(i));
                        }

                        x_bg.deinit();
                        tr_box.deinit();
                    }

                    cell_overlay.deinit();

                    // ── Recording indicator (red pulsing REC dot) ──
                    {
                        const sl = @import("../services/streamlink.zig");
                        if (sl.is_recording) {
                            var rec_overlay = dvui.overlay(@src(), .{ .id_extra = i + 7000, .expand = .both });
                            var rec_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                                .id_extra = i + 7001,
                                .gravity_x = 0.0,
                                .gravity_y = 0.0,
                                .background = true,
                                .color_fill = theme.colors.overlay,
                                .corner_radius = theme.dims.rad_md,
                                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                                .margin = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = 0, .h = 0 },
                            });
                            // Transient capture status — danger as text/icon only.
                            _ = dvui.icon(@src(), "", icons.tvg.lucide.circle, .{}, .{
                                .id_extra = i + 7003,
                                .color_text = theme.colors.danger,
                                .min_size_content = .{ .w = 10, .h = 10 },
                                .margin = .{ .w = theme.spacing.xs },
                                .gravity_y = 0.5,
                            });
                            _ = dvui.label(@src(), "REC", .{}, .{
                                .id_extra = i + 7002,
                                .color_text = theme.colors.danger,
                                .gravity_y = 0.5,
                            });
                            rec_box.deinit();
                            rec_overlay.deinit();
                        }
                    }
                } else if (p.is_loading) {
                    // ── Loading indicator — shown immediately on load_file() ──
                    // TMDB-linked plays (movie search / TV episode — see
                    // search.zig's addMagnetToEngine) stash a poster + title,
                    // which we use here for a poster+trivia loading screen.
                    // Everything else (raw magnet paste, plain file/URL) keeps
                    // the original hourglass + source-path text unchanged.
                    const text_mod = @import("../core/text.zig");
                    const has_tmdb_ctx = p.loading_poster_path_len > 0;

                    if (has_tmdb_ctx and !p.loading_meta_fetch_started) {
                        p.loading_meta_fetch_started = true;
                        var url_buf: [256]u8 = undefined;
                        if (std.fmt.bufPrint(&url_buf, "https://image.tmdb.org/t/p/w500{s}", .{p.loading_poster_path[0..p.loading_poster_path_len]})) |url| {
                            @import("../core/poster.zig").fetchAsync(url, &p.loading_poster_pixels, &p.loading_poster_w, &p.loading_poster_h, &p.loading_poster_fetching);
                        } else |_| {}
                        if (p.loading_title_len > 0) {
                            @import("../services/wikipedia.zig").fetchTrivia(
                                p.loading_title[0..p.loading_title_len],
                                p.loading_is_tv,
                                &p.loading_trivia,
                                &p.loading_trivia_len,
                                &p.loading_trivia_fetching,
                            );
                        }
                    }
                    if (has_tmdb_ctx) {
                        _ = @import("../core/poster.zig").uploadIfReady(&p.loading_poster_pixels, p.loading_poster_w, p.loading_poster_h, &p.loading_poster_tex);
                    }

                    var load_overlay = dvui.overlay(@src(), .{ .id_extra = i, .expand = .both });
                    {
                        if (has_tmdb_ctx and p.loading_poster_tex != null) {
                            // Full-bleed poster behind a dim scrim so the spinner
                            // + text stay legible over whatever art loaded.
                            _ = dvui.image(@src(), .{ .source = .{ .texture = p.loading_poster_tex.? } }, .{
                                .id_extra = i + 3010,
                                .expand = .both,
                                // Without an explicit minimum, dvui takes the
                                // IMAGE'S NATURAL SIZE as this box's minimum — and
                                // this is a TMDB w500 poster (~500x750). That made
                                // the player cell demand more height than the window
                                // had, which pushed the control bar off the bottom
                                // edge and left it clipped to a sliver. It only
                                // showed on a TMDB-linked play (an episode); a plain
                                // magnet paste draws the small hourglass instead and
                                // was always fine. `.expand = .both` already fills
                                // the cell, so the natural size buys nothing.
                                .min_size_content = .{ .w = 0, .h = 0 },
                            });
                            var scrim = dvui.box(@src(), .{}, .{ .id_extra = i + 3011, .expand = .both, .background = true, .color_fill = theme.colors.overlay });
                            scrim.deinit();
                        } else if (dvui.button(@src(), "", .{}, .{ .id_extra = i + 3000, .expand = .both, .color_fill = theme.colors.bg_deep })) {
                            // Dark backdrop captures clicks to select this pane.
                            state.app.active_player_idx = i;
                        }

                        var load_stack = dvui.box(@src(), .{ .dir = .vertical }, .{
                            .id_extra = i + 3100,
                            .gravity_x = 0.5,
                            .gravity_y = 0.5,
                            .expand = .both,
                        });
                        defer load_stack.deinit();

                        if (has_tmdb_ctx and p.loading_title_len > 0) {
                            _ = dvui.icon(@src(), "", icons.tvg.lucide.hourglass, .{}, .{
                                .id_extra = i + 3150,
                                .color_text = theme.colors.text_primary,
                                .min_size_content = .{ .w = 28, .h = 28 },
                                .max_size_content = .{ .w = 28, .h = 28 },
                                .gravity_x = 0.5,
                                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
                            });

                            var title_buf: [128]u8 = undefined;
                            _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(p.loading_title[0..p.loading_title_len], &title_buf)}, .{
                                .id_extra = i + 3151,
                                .color_text = theme.colors.text_primary,
                                .gravity_x = 0.5,
                                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
                            });

                            // Prefer the fetched Wikipedia trivia; fall back to the
                            // TMDB synopsis stashed at play-start while it's still
                            // in flight (or if it never lands).
                            const trivia_src = if (p.loading_trivia_len > 0)
                                p.loading_trivia[0..p.loading_trivia_len]
                            else
                                p.loading_overview[0..p.loading_overview_len];

                            if (trivia_src.len > 0) {
                                var trivia_wrap = dvui.box(@src(), .{}, .{
                                    .id_extra = i + 3160,
                                    .gravity_x = 0.5,
                                    .max_size_content = .{ .w = 440, .h = std.math.floatMax(f32) },
                                });
                                defer trivia_wrap.deinit();
                                var trivia_buf: [400]u8 = undefined;
                                dvui.labelEx(@src(), "{s}", .{text_mod.safeUtf8Buf(trivia_src, &trivia_buf)}, .{ .align_x = 0.5 }, .{
                                    .id_extra = i + 3161,
                                    .color_text = theme.colors.text_secondary,
                                    .expand = .horizontal,
                                });
                            }
                        } else {
                            components.emptyState(icons.tvg.lucide.hourglass, "Loading...", "");

                            // Truncated source path beneath the canonical empty state.
                            if (p.loading_label_len > 0) {
                                const src_text = p.loading_label[0..p.loading_label_len];
                                const display = if (src_text.len > 45) src_text[src_text.len - 45 ..] else src_text;
                                // loading_label is a file path / network title written
                                // by the load worker — validate a copy so a non-UTF-8
                                // byte (or a tail slice cut mid-codepoint) can't panic dvui.
                                var ll_buf: [64]u8 = undefined;
                                _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(display, &ll_buf)}, .{
                                    .id_extra = i + 4002,
                                    .color_text = theme.colors.text_tertiary,
                                    .gravity_x = 0.5,
                                    .margin = .{ .x = 0, .y = 4, .w = 0, .h = 8 },
                                });
                            }
                        }
                    }
                    load_overlay.deinit();
                    dvui.refresh(null, @src(), null);
                } else {
                    var is_audio_only = false;
                    if (p.torrent_is_ready) {
                        // Cached via mpv "vid" property observer (A4) — no per-frame IPC.
                        is_audio_only = p.cached_vid_no;
                    }

                    const header = @import("header.zig");
                    if (p.current_torrent_id < 0 and i == state.app.active_player_idx and header.shouldUrlInputBeInGrid()) {
                        // Player empty cell = hero input + resume list ONLY.
                        // The chat interface moved to the Home page
                        // (home.zig chat mode) — the
                        // player surface stays about playback.
                        var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
                            .id_extra = i,
                            .expand = .both,
                            .color_fill = theme.transparent,
                        });

                        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
                            .id_extra = i,
                            .gravity_x = 0.5,
                            .gravity_y = 0.34,
                            .background = false,
                            .border = dvui.Rect.all(0),
                            .padding = .{ .x = 24, .y = 20, .w = 24, .h = 20 },
                            .min_size_content = .{ .w = 620, .h = 0 },
                            .max_size_content = .{ .w = 760, .h = std.math.floatMax(f32) },
                        });

                        // Input bar first — primary action, immediately reachable
                        header.renderUrlInput(true);

                        // Continue Watching — returning users want this front and center
                        renderContinueWatching();

                        card.deinit();
                        outer.deinit();
                    } else {
                        // Empty / pre-buffer state for an idle player cell.
                        // Loading states get the hourglass empty-state; the truly
                        // empty (no torrent, no media) state gets the library
                        // empty-state with a "Search above" hint.
                        const is_loading_torrent = p.current_torrent_id >= 0;
                        const placeholder_text = if (is_loading_torrent)
                            (if (!p.torrent_is_ready)
                                (if (p.has_metadata) "Buffering first video parts..." else "Loading torrent metadata...")
                            else
                                (if (is_audio_only) "Audio stream playing" else "Buffering video stream..."))
                        else
                            "Nothing here yet";
                        const placeholder_hint: []const u8 = if (is_loading_torrent)
                            ""
                        else
                            "Search above to find something to watch.";
                        const placeholder_icon = if (is_loading_torrent)
                            icons.tvg.lucide.hourglass
                        else
                            icons.tvg.lucide.library;

                        // Transparent overlay captures clicks to select this pane
                        // without painting over the centered empty-state widget.
                        var placeholder_overlay = dvui.overlay(@src(), .{
                            .id_extra = i + 5500,
                            .expand = .both,
                        });
                        defer placeholder_overlay.deinit();

                        if (dvui.button(@src(), "", .{}, .{
                            .id_extra = i + 5510,
                            .expand = .both,
                            .color_fill = theme.colors.bg_deep,
                            .color_text = theme.colors.text_primary,
                            .border = dvui.Rect.all(0),
                            .corner_radius = theme.dims.rad_sm,
                        })) {
                            state.app.active_player_idx = i;
                        }

                        components.emptyState(placeholder_icon, placeholder_text, placeholder_hint);
                    }
                }
            }, // end .mpv

            .comic_viewer => {
                // ── Comic Viewer Pane ──
                const comics = @import("../services/comics.zig");

                // Click to select pane
                if (dvui.button(@src(), "", .{}, .{
                    .id_extra = i + 5000,
                    .expand = .both,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                })) {
                    state.app.active_player_idx = i;
                }

                if (state.app.comic.page_count == 0 and !state.app.comic.is_loading.load(.acquire)) {
                    components.emptyState(icons.tvg.lucide.book, "Comic Viewer", "Open a comic to start reading.");
                } else {
                    comics.renderPaneContent(i);
                }
            },
        } // end switch

        cell_wrapper.deinit();
        cell_box.deinit();
    }

    if (current_row != null) current_row.?.deinit();
}

/// "Continue Watching" strip rendered on the empty home screen. Surfaces the
/// top few in-progress items from watch history with a progress bar; click
/// resumes at the saved position (player.tryResumePosition handles the seek).
fn renderContinueWatching() void {
    const watch_history = @import("../player/watch_history.zig");
    if (watch_history.count == 0) return;

    // Collect up to 6 entries that are not already completed. Treat >=95% as
    // finished so the row stays curated.
    const MAX_SHOW: usize = 6;
    var show_idx: [MAX_SHOW]usize = undefined;
    var show_count: usize = 0;
    var wi: usize = 0;
    while (wi < watch_history.count and show_count < MAX_SHOW) : (wi += 1) {
        const e = watch_history.entries[wi];
        if (e.name_len == 0) continue;
        if (e.percent >= 95.0) continue;
        show_idx[show_count] = wi;
        show_count += 1;
    }
    if (show_count == 0) return;

    // Header row: section header + Clear button
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer hdr.deinit();

        // Section header takes the left side and expands; Clear button sits
        // on the right edge. Wrapping in a flex row keeps the header's
        // built-in vertical margin (spacing.lg above, sm below).
        {
            var header_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
            defer header_col.deinit();
            components.sectionHeader("Continue Watching");
        }

        // Two-step confirm — this was a bare one-click DELETE of the entire
        // watch history, sitting right next to the resume cards.
        if (components.confirmDangerButton(@src(), "Clear", 43900)) {
            watch_history.clearAll();
            state.showToast("Watch history cleared");
            return;
        }
    }

    var strip = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .y = 2 },
    });
    defer strip.deinit();

    for (0..show_count) |si| {
        const idx = show_idx[si];
        const e = watch_history.entries[idx];
        const raw_name = e.name[0..e.name_len];

        // Display-name cleanup is shared with poster tiles so every
        // surface gets identical formatting.
        var clean_buf: [128]u8 = undefined;
        const display_name = cleanDisplayName(&clean_buf, raw_name);
        const disp = display_name[0..@min(display_name.len, 56)];

        const pct_f = std.math.clamp(e.percent, 0.0, 100.0);
        const pct = @as(u8, @intFromFloat(pct_f));

        // ── Card container ──
        // Calm: borderless — the bg_surface fill (over the bg_app card area)
        // and inter-card whitespace carry the boundary. md radius, no outline.
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = si + 43000,
            .expand = .horizontal,
            .padding = dvui.Rect.all(theme.spacing.md),
            .margin = .{ .x = 0, .y = theme.spacing.sm / 2, .w = 0, .h = theme.spacing.sm / 2 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .corner_radius = dvui.Rect.all(theme.radius.md),
        });
        defer card.deinit();

        // Top row: play icon + title + percentage pill + resume button
        {
            var top_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = si + 43050,
                .expand = .horizontal,
            });
            defer top_row.deinit();

            // Play glyph demoted to neutral — the progress fill is the single
            // accent in this row.
            _ = dvui.icon(@src(), "", icons.tvg.lucide.play, .{}, .{
                .id_extra = si + 43100,
                .color_text = theme.colors.text_secondary,
                .min_size_content = .{ .w = 14, .h = 14 },
                .margin = .{ .w = theme.spacing.sm },
                .gravity_y = 0.5,
            });

            var disp_buf: [64]u8 = undefined;
            const safe_disp = @import("../core/text.zig").safeUtf8Buf(disp, &disp_buf);
            _ = dvui.label(@src(), "{s}", .{safe_disp}, .{
                .id_extra = si + 43200,
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
                .expand = .horizontal,
            });

            // Percentage as quiet neutral text (statusPill .info reads as
            // text_secondary — no fill, no box).
            var pct_buf: [32]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d}% watched", .{pct}) catch "0% watched";
            components.statusPill(pct_str, .info);

            // Resume — ghost/text button. The play glyph + progress fill already
            // signal resumability; the action stays neutral.
            const resume_clicked = dvui.button(@src(), "Resume", .{}, .{
                .id_extra = si + 43400,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.text_secondary,
                .border = dvui.Rect.all(0),
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
                .min_size_content = .{ .w = 0, .h = 36 },
                .max_size_content = .{ .w = std.math.floatMax(f32), .h = 36 },
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
            if (resume_clicked) {
                const browser = @import("../services/browser.zig");
                // resumePlayback forces known playback (magnet → torrent
                // engine, comics → reader, else straight into mpv) instead of
                // loadContent's auto-routing, which sends the bare display
                // name (no extension/domain) to the web browser tab instead
                // of mpv. Creates a player if none exists (cold start on the
                // empty home screen). No stored link (legacy row saved before
                // this was fixed) means there's nothing safe to resume into.
                if (e.link_len > 0) {
                    browser.resumePlayback(e.link[0..e.link_len]);
                    state.showToast("Resuming...");
                } else {
                    state.showToast("Can't resume — no saved link for this item");
                }
            }
        }

        // Bottom: thin progress bar spanning full width.
        // 3px tall, bg_elevated track, accent_primary fill, radius.sm.
        {
            const bar_h: f32 = 3;
            var bar_track = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = si + 43500,
                .expand = .horizontal,
                .background = true,
                .color_fill = theme.colors.bg_elevated,
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .min_size_content = .{ .w = 0, .h = bar_h },
                .max_size_content = .{ .w = std.math.floatMax(f32), .h = bar_h },
                .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
            });

            // Fill portion — sized proportionally against the laid-out track
            // width (no hardcoded pixel width). One frame of lag on first paint
            // is acceptable; contentRectScale().r.w is the real track width.
            const fill_frac: f32 = @max(0.0, @min(1.0, @as(f32, @floatCast(pct_f / 100.0))));
            const track_w = bar_track.data().contentRectScale().r.w;
            const fill_w = fill_frac * track_w;
            var fill_box = dvui.box(@src(), .{}, .{
                .id_extra = si + 43600,
                .background = true,
                .color_fill = theme.colors.accent,
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .min_size_content = .{ .w = fill_w, .h = bar_h },
                .max_size_content = .{ .w = fill_w, .h = bar_h },
            });
            fill_box.deinit();

            bar_track.deinit();
        }
    }
}
