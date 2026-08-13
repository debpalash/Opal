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
        .color_fill = theme.video_letterbox,
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
        const cell_fill = if (p.texture != null) theme.video_letterbox else theme.colors.bg_deep;

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
                    const playback = p.playbackSnapshot();
                    const render_size = @import("../player/playback_snapshot_pure.zig").renderSize(
                        playback.video_width,
                        playback.video_height,
                        player.video_w,
                        player.video_h,
                    );
                    const rw: c_int = @intCast(render_size.width);
                    const rh: c_int = @intCast(render_size.height);
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
                                    // Double-click → fullscreen, single → pause.
                                    // Shares input_pure.DoubleTap with the F F
                                    // keyboard gesture so there is one window
                                    // and one set of edge cases (target change,
                                    // triple-click, backwards clock) rather than
                                    // two hand-rolled copies.
                                    const DblClick = struct {
                                        var gesture: @import("input_pure.zig").DoubleTap = .{};
                                    };
                                    const ip = @import("input_pure.zig");
                                    const now_ms = @import("../core/io_global.zig").milliTimestamp();
                                    if (DblClick.gesture.tap(now_ms, i, ip.DOUBLE_TAP_MS)) {
                                        if (state.app.fullscreen_player_idx == null) {
                                            state.app.fullscreen_player_idx = i;
                                        } else {
                                            state.app.fullscreen_player_idx = null;
                                        }
                                    } else {
                                        // Single click: toggle pause
                                        p.togglePause();
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
                    // ── Loading screen — shown immediately on load_file() ──
                    //
                    // One screen for every source now. TMDB-linked plays (movie
                    // search / TV episode — see search.zig's addMagnetToEngine),
                    // anime and music stash a poster + title and get the full
                    // treatment; a raw magnet paste or plain file falls back to
                    // its cleaned source name, but still gets the progress block
                    // instead of the bare hourglass it used to get. Which pieces
                    // appear at a given cell size, how text is truncated, and how
                    // the numbers are formatted all come from loading_pure.
                    const text_mod = @import("../core/text.zig");
                    const lpure = @import("loading_pure.zig");
                    // Bar geometry (fillBar / fillSegment) is shared with the
                    // control bar rather than re-derived here — one tested copy.
                    const fpure = @import("footer_pure.zig");
                    const io_g = @import("../core/io_global.zig");
                    // Any source that stashed art gets the rich screen — TMDB
                    // movies and episodes, anime, and music (whose cover is an
                    // absolute URL rather than a TMDB fragment). Everything
                    // else still falls through to the hourglass below.
                    const has_meta = p.loading_art_len > 0 or p.loading_title_len > 0;
                    const kind = lpure.MediaKind.fromInt(p.loading_kind);

                    if (has_meta and !p.loading_meta_fetch_started) {
                        p.loading_meta_fetch_started = true;
                        p.loading_card_since_ms = io_g.milliTimestamp();
                        var url_buf: [320]u8 = undefined;
                        const art_url = lpure.posterUrl(p.loading_art[0..p.loading_art_len], &url_buf);
                        if (art_url.len > 0) {
                            @import("../core/poster.zig").fetchAsync(art_url, &p.loading_poster_pixels, &p.loading_poster_w, &p.loading_poster_h, &p.loading_poster_fetching);
                        }
                        // Trivia lookup only makes sense for titles Wikipedia
                        // is likely to have an article on.
                        if (p.loading_title_len > 0 and kind != .other) {
                            @import("../services/wikipedia.zig").fetchTrivia(
                                p.loading_title[0..p.loading_title_len],
                                p.loading_is_tv,
                                &p.loading_trivia,
                                &p.loading_trivia_len,
                                &p.loading_trivia_fetching,
                            );
                        }
                    }
                    if (has_meta) {
                        _ = @import("../core/poster.zig").uploadIfReady(&p.loading_poster_pixels, p.loading_poster_w, p.loading_poster_h, &p.loading_poster_tex);
                    }

                    var load_overlay = dvui.overlay(@src(), .{ .id_extra = i, .expand = .both });
                    {
                        // ── Backdrop ──
                        //
                        // Deliberately a FLAT themed fill, not the artwork. The
                        // stashed art is a TMDB **w500** poster (500x750); drawing
                        // it with `.expand = .both` blew it up across the whole
                        // cell — roughly a 3x upscale, which is why it came out
                        // soft and colour-cast, and it drowned the text besides.
                        // The poster now appears at (at most) its native size in
                        // the stack below, and the text sits on a themed surface
                        // where contrast is guaranteed in all seven presets rather
                        // than depending on whatever poster happened to load.
                        // Doubles as the click target that selects this pane.
                        if (dvui.button(@src(), "", .{}, .{
                            .id_extra = i + 3000,
                            .expand = .both,
                            .color_fill = theme.colors.bg_deep,
                            .border = dvui.Rect.all(0),
                            .corner_radius = theme.dims.rad_sm,
                        })) {
                            state.app.active_player_idx = i;
                        }

                        // What fits in THIS cell. The screen lives in a grid cell,
                        // which in a 3x3 workspace is a few hundred points — the
                        // poster, the fact deck and the swarm readout are shed in
                        // that order (breakpoints tested in loading_pure.layout).
                        const scale_pure = @import("../core/scale_pure.zig");
                        const cell_rect = load_overlay.data().rect;
                        const lay = lpure.layout(
                            scale_pure.layoutPoints(cell_rect.w, state.app.ui_scale),
                            scale_pure.layoutPoints(cell_rect.h, state.app.ui_scale),
                        );
                        // The breakpoints are decided in on-screen POINTS (a grid
                        // cell is the same physical size whatever the density
                        // setting), but dvui sizes widgets in SCALED units — the
                        // shell renders inside `dvui.scale(ui_scale)`. Convert the
                        // two dimensions back before handing them to a widget, or
                        // the column comes out ~25% too wide at the default 0.8.
                        const ui_s: f32 = if (state.app.ui_scale > 0.01) state.app.ui_scale else 1.0;
                        const content_w = lay.content_w / ui_s;
                        const poster_max_h = lay.poster_max_h / ui_s;

                        const now_ms = io_g.milliTimestamp();

                        // ── Swarm snapshot, cached at ~2Hz per cell ──
                        //
                        // torrent_poll + get_num_peers + get_piece_map are C calls
                        // into libtorrent; at ~30fps per loading cell that is pure
                        // waste. Keyed on the torrent id so switching titles
                        // invalidates immediately (same idiom as footer.zig).
                        const Swarm = struct {
                            const SLOTS = 8;
                            var tid: [SLOTS]i32 = [_]i32{-1} ** SLOTS;
                            var at_ms: [SLOTS]i64 = [_]i64{0} ** SLOTS;
                            var rate: [SLOTS]i32 = [_]i32{0} ** SLOTS;
                            var seeds: [SLOTS]i32 = [_]i32{0} ** SLOTS;
                            var peers: [SLOTS]i32 = [_]i32{0} ** SLOTS;
                            var prog: [SLOTS]f32 = [_]f32{0} ** SLOTS;
                            var buckets: [SLOTS][lpure.PIECE_BUCKETS]f32 =
                                [_][lpure.PIECE_BUCKETS]f32{[_]f32{0} ** lpure.PIECE_BUCKETS} ** SLOTS;
                            var bucket_n: [SLOTS]usize = [_]usize{0} ** SLOTS;
                        };
                        const slot = i % Swarm.SLOTS;
                        const is_torrent_load = p.is_torrent and p.current_torrent_id >= 0;
                        if (is_torrent_load and
                            (Swarm.tid[slot] != p.current_torrent_id or now_ms - Swarm.at_ms[slot] > 500))
                        {
                            Swarm.tid[slot] = p.current_torrent_id;
                            Swarm.at_ms[slot] = now_ms;
                            var s_pct: f32 = 0;
                            var s_rate: i32 = 0;
                            var s_seeds: i32 = 0;
                            _ = c.mpv.torrent_poll(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, null, 0, &s_pct, &s_rate, &s_seeds);
                            Swarm.prog[slot] = s_pct;
                            Swarm.rate[slot] = s_rate;
                            Swarm.seeds[slot] = s_seeds;
                            Swarm.peers[slot] = c.mpv.torrent_get_num_peers(state.torrentSession(), p.current_torrent_id);
                            var map_buf: [4096]u8 = undefined;
                            const map_len = c.mpv.torrent_get_piece_map(state.torrentSession(), p.current_torrent_id, &map_buf, map_buf.len);
                            Swarm.bucket_n[slot] = if (map_len > 0)
                                lpure.pieceBuckets(map_buf[0..@min(@as(usize, @intCast(map_len)), map_buf.len)], &Swarm.buckets[slot])
                            else
                                0;
                        }

                        // The slot is shared between cells (i % SLOTS), so read it
                        // only when it actually belongs to THIS torrent —
                        // otherwise a second pane would show the first one's
                        // peer count, which is worse than showing nothing.
                        const sw_ok = is_torrent_load and Swarm.tid[slot] == p.current_torrent_id;
                        const sw_rate: i32 = if (sw_ok) Swarm.rate[slot] else 0;
                        const sw_seeds: i32 = if (sw_ok) Swarm.seeds[slot] else 0;
                        const sw_peers: i32 = if (sw_ok) Swarm.peers[slot] else 0;
                        const sw_prog: f32 = if (sw_ok) Swarm.prog[slot] else 0;
                        const sw_buckets: usize = if (sw_ok) Swarm.bucket_n[slot] else 0;

                        // Readiness, NOT whole-torrent progress, whenever the
                        // stream gate has a plan: the bytes the demuxer blocks on
                        // are the head + the container index at the END of the
                        // file, so overall completion counts up encouragingly
                        // while playback never starts (see stream_gate.zig).
                        const gate = @import("../player/stream_gate.zig");
                        const gated = p.current_torrent_id >= 0 and p.selected_file_idx >= 0 and
                            gate.hasPlan(p.current_torrent_id, p.selected_file_idx);
                        const buf_pct: u8 = if (gated)
                            lpure.clampPercent(@intCast(gate.bufferPercent(p.current_torrent_id, p.selected_file_idx)))
                        else
                            lpure.percentOf(sw_prog);
                        const phase = lpure.phaseOf(is_torrent_load, p.has_metadata, sw_peers, buf_pct);

                        var load_stack = dvui.box(@src(), .{ .dir = .vertical }, .{
                            .id_extra = i + 3100,
                            .gravity_x = 0.5,
                            .gravity_y = 0.5,
                            // A floor, never a cap: an expanded box stacks its
                            // children from the top (gravity cannot centre inside
                            // an already-full box), which is what pinned the old
                            // screen's content against the top edge.
                            .min_size_content = .{ .w = content_w, .h = 0 },
                        });
                        defer load_stack.deinit();

                        // ── Poster card — contained, never upscaled ──
                        if (lay.poster) {
                            if (p.loading_poster_tex) |tex| {
                                const fit = lpure.posterFit(
                                    @intCast(tex.width),
                                    @intCast(tex.height),
                                    content_w * 0.55,
                                    poster_max_h,
                                );
                                if (fit.w > 0 and fit.h > 0) {
                                    _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
                                        .id_extra = i + 3010,
                                        .min_size_content = .{ .w = fit.w, .h = fit.h },
                                        .max_size_content = .{ .w = fit.w, .h = fit.h },
                                        .corner_radius = theme.dims.rad_md,
                                        .gravity_x = 0.5,
                                        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.lg },
                                    });
                                }
                            }
                        }

                        // ── Title ──
                        //
                        // A plain magnet paste has no stashed title, so fall back
                        // to the cleaned source label instead of dropping to a
                        // bare hourglass with a mid-path slice under it.
                        {
                            var raw_buf: [192]u8 = undefined;
                            var safe_buf: [192]u8 = undefined;
                            var title_buf: [192]u8 = undefined;
                            const from_meta = p.loading_title_len > 0;
                            const raw: []const u8 = if (from_meta)
                                p.loading_title[0..p.loading_title_len]
                            else if (p.loading_label_len > 0)
                                cleanDisplayName(&raw_buf, p.loading_label[0..p.loading_label_len])
                            else
                                "Loading";
                            // safeUtf8Buf first: the fixed buffers can hold a
                            // sequence cut mid-codepoint, and ellipsizeWords only
                            // promises codepoint-safe output for valid input.
                            const safe = text_mod.safeUtf8Buf(raw, &safe_buf);
                            const title = lpure.ellipsizeWords(
                                safe,
                                title_buf.len,
                                &title_buf,
                                from_meta and lpure.filledBuffer(p.loading_title_len, p.loading_title.len),
                            );

                            var title_wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
                                .id_extra = i + 3140,
                                .gravity_x = 0.5,
                                .max_size_content = .{ .w = content_w, .h = std.math.floatMax(f32) },
                            });
                            defer title_wrap.deinit();
                            dvui.labelEx(@src(), "{s}", .{title}, .{ .align_x = 0.5 }, .{
                                .id_extra = i + 3151,
                                .color_text = theme.colors.text_primary,
                                .font = dvui.themeGet().font_heading,
                                .expand = .horizontal,
                            });
                        }

                        // ── Meta line: kind, year, artist/episode, score ──
                        // Skips whatever the source did not supply, so a music
                        // track shows "Music · <artist>" and never a dangling
                        // separator.
                        if (has_meta) {
                            var meta_buf: [160]u8 = undefined;
                            var extra_buf: [96]u8 = undefined;
                            const meta = lpure.metaLine(
                                &meta_buf,
                                kind,
                                p.loading_year[0..p.loading_year_len],
                                p.loading_rating,
                                text_mod.safeUtf8Buf(p.loading_extra[0..p.loading_extra_len], &extra_buf),
                            );
                            if (meta.len > 0) {
                                _ = dvui.label(@src(), "{s}", .{meta}, .{
                                    .id_extra = i + 3152,
                                    .color_text = theme.colors.text_tertiary,
                                    .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
                                    .gravity_x = 0.5,
                                });
                            }
                        }

                        // ── Progress ──
                        //
                        // The old screen's ONLY indicator was a static hourglass
                        // glyph, so "still finding peers", "buffered, handing to
                        // mpv" and "hung" were indistinguishable. Phase, buffer
                        // percentage, rate, swarm size and elapsed time each
                        // appear only when they are actually known — a printed
                        // zero reads as a stall (see loading_pure.statusLine).
                        {
                            const show_pct = lpure.phaseShowsPercent(phase) and (gated or buf_pct > 0);
                            var phase_buf: [64]u8 = undefined;
                            const phase_txt: []const u8 = if (show_pct)
                                (std.fmt.bufPrint(&phase_buf, "{s} \u{00B7} {d}%", .{ lpure.phaseLabel(phase), buf_pct }) catch lpure.phaseLabel(phase))
                            else
                                lpure.phaseLabel(phase);
                            _ = dvui.label(@src(), "{s}", .{phase_txt}, .{
                                .id_extra = i + 3190,
                                .color_text = theme.colors.text_secondary,
                                .gravity_x = 0.5,
                                .margin = .{ .x = 0, .y = theme.spacing.lg, .w = 0, .h = theme.spacing.sm },
                            });
                        }

                        // Bars are PAINTED, not built as widgets: a child's
                        // min_size_content propagates into the parent's derived
                        // minimum, so a fill sized with `min_size_content.w =
                        // track_w * frac` ratchets the column wider every frame
                        // and squeezes its siblings (the exact bug footer.zig hit
                        // with its scrub band). A plain fill contributes zero min
                        // size. Geometry comes from the unit-tested footer_pure
                        // helpers rather than a second copy of the same maths.
                        const paintBar = struct {
                            fn f(b: fpure.BarRect, color: dvui.Color, radius: f32) void {
                                if (b.w <= 0 or b.h <= 0) return;
                                const rr: dvui.Rect.Physical = .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h };
                                rr.fill(dvui.Rect.Physical.all(radius), .{ .color = color });
                            }
                        }.f;

                        if (is_torrent_load) {
                            var band = dvui.box(@src(), .{}, .{
                                .id_extra = i + 3200,
                                .gravity_x = 0.5,
                                .expand = .horizontal,
                                .min_size_content = .{ .w = content_w, .h = 6 },
                                .max_size_content = .{ .w = content_w, .h = 6 },
                            });
                            const brs = band.data().contentRectScale();
                            const bth = 5.0 * brs.s;
                            paintBar(
                                fpure.fillBar(brs.r.x, brs.r.y, brs.r.w, brs.r.h, bth, 1.0),
                                theme.colors.bg_elevated,
                                bth * 0.5,
                            );
                            paintBar(
                                fpure.fillBar(brs.r.x, brs.r.y, brs.r.w, brs.r.h, bth, @as(f32, @floatFromInt(buf_pct)) / 100.0),
                                theme.colors.accent,
                                bth * 0.5,
                            );
                            band.deinit();
                        }

                        // ── Piece map ──
                        // Where the swarm actually has data, downsampled to a
                        // fixed number of segments (a torrent has thousands of
                        // pieces). Skipped entirely when the map is empty, so it
                        // never shows an all-dark bar that reads as a dead peer.
                        if (lay.piece_bar and sw_buckets > 0) {
                            var pband = dvui.box(@src(), .{}, .{
                                .id_extra = i + 3210,
                                .gravity_x = 0.5,
                                .expand = .horizontal,
                                .min_size_content = .{ .w = content_w, .h = 5 },
                                .max_size_content = .{ .w = content_w, .h = 5 },
                                .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
                            });
                            const prs = pband.data().contentRectScale();
                            const pth = 4.0 * prs.s;
                            const n = sw_buckets;
                            const nf: f32 = @floatFromInt(n);
                            const acc = theme.colors.accent;
                            for (0..n) |b| {
                                const seg = fpure.fillSegment(
                                    prs.r.x,
                                    prs.r.y,
                                    prs.r.w,
                                    prs.r.h,
                                    pth,
                                    @as(f32, @floatFromInt(b)) / nf,
                                    @as(f32, @floatFromInt(b + 1)) / nf,
                                );
                                if (seg.w <= 0) continue;
                                const cov = @max(0.0, @min(1.0, Swarm.buckets[slot][b]));
                                const gap = @min(seg.w * 0.3, prs.s);
                                const a: u8 = @intFromFloat(@round(30.0 + 200.0 * cov));
                                paintBar(
                                    .{ .x = seg.x, .y = seg.y, .w = @max(prs.s, seg.w - gap), .h = seg.h },
                                    .{ .r = acc.r, .g = acc.g, .b = acc.b, .a = a },
                                    1.0,
                                );
                            }
                            pband.deinit();
                        }

                        // ── Swarm readout ──
                        if (lay.stats) {
                            var stat_buf: [96]u8 = undefined;
                            const stats = lpure.statusLine(&stat_buf, .{
                                .rate_bps = sw_rate,
                                .peers = sw_peers,
                                .seeds = sw_seeds,
                                .elapsed_secs = if (is_torrent_load and p.metadata_start_time > 0)
                                    io_g.timestamp() - p.metadata_start_time
                                else
                                    0,
                            });
                            if (stats.len > 0) {
                                _ = dvui.label(@src(), "{s}", .{stats}, .{
                                    .id_extra = i + 3220,
                                    .color_text = theme.colors.text_tertiary,
                                    .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
                                    .gravity_x = 0.5,
                                    .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
                                });
                            }
                        }

                        // ── Fact deck ──
                        //
                        // Prefer the fetched Wikipedia trivia; fall back to the
                        // TMDB synopsis stashed at play-start while it is still in
                        // flight (or if it never lands). One paragraph held still
                        // for a whole minute stops being read, so it is cut into
                        // sentence cards that rotate and can be paged.
                        const trivia_src = if (p.loading_trivia_len > 0)
                            p.loading_trivia[0..p.loading_trivia_len]
                        else
                            p.loading_overview[0..p.loading_overview_len];
                        const trivia_cut = if (p.loading_trivia_len > 0)
                            lpure.filledBuffer(p.loading_trivia_len, p.loading_trivia.len)
                        else
                            lpure.filledBuffer(p.loading_overview_len, p.loading_overview.len);

                        if (lay.facts and trivia_src.len > 0) {
                            const cards = lpure.splitFacts(trivia_src);
                            if (p.loading_card_since_ms == 0) p.loading_card_since_ms = now_ms;
                            const card_i = lpure.cardIndex(
                                cards.count,
                                now_ms - p.loading_card_since_ms,
                                p.loading_card_manual,
                            );

                            var trivia_wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
                                .id_extra = i + 3160,
                                .gravity_x = 0.5,
                                .max_size_content = .{ .w = content_w, .h = std.math.floatMax(f32) },
                                .margin = .{ .x = 0, .y = theme.spacing.lg, .w = 0, .h = 0 },
                            });
                            defer trivia_wrap.deinit();

                            var safe_card: [400]u8 = undefined;
                            var card_buf: [400]u8 = undefined;
                            const card_raw = cards.slice(trivia_src, card_i);
                            // Only the LAST card can carry the upstream cut — the
                            // earlier ones ended on a real sentence break.
                            const card_cut = trivia_cut and card_i + 1 == cards.count;
                            const card_txt = lpure.ellipsizeWords(
                                text_mod.safeUtf8Buf(card_raw, &safe_card),
                                lay.fact_max,
                                &card_buf,
                                card_cut,
                            );
                            dvui.labelEx(@src(), "{s}", .{card_txt}, .{ .align_x = 0.5 }, .{
                                .id_extra = i + 3161,
                                .color_text = theme.colors.text_secondary,
                                .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
                                .expand = .horizontal,
                            });

                            // Pager: dots for position plus prev/next. Only when
                            // there is more than one card — a single fact needs no
                            // controls.
                            if (cards.count > 1) {
                                var pager = dvui.box(@src(), .{ .dir = .horizontal }, .{
                                    .id_extra = i + 3170,
                                    .gravity_x = 0.5,
                                    .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = 0 },
                                });
                                defer pager.deinit();

                                if (dvui.buttonIcon(@src(), "fact-prev", icons.tvg.lucide.@"chevron-left", .{}, .{}, .{
                                    .id_extra = i + 3171,
                                    .color_fill = theme.transparent,
                                    .color_text = theme.colors.text_tertiary,
                                    .border = dvui.Rect.all(0),
                                    .min_size_content = .{ .w = 18, .h = 18 },
                                    .max_size_content = .{ .w = 18, .h = 18 },
                                    .gravity_y = 0.5,
                                })) {
                                    // +count-1 rather than -1: the counter is
                                    // unsigned and wraps, so stepping back from
                                    // card 0 must not underflow.
                                    p.loading_card_manual +%= cards.count - 1;
                                    p.loading_card_since_ms = now_ms;
                                }

                                for (0..cards.count) |d| {
                                    const on = (d == card_i);
                                    var dot = dvui.box(@src(), .{}, .{
                                        .id_extra = i + 3180 + d,
                                        .background = true,
                                        .color_fill = if (on) theme.colors.text_primary else theme.colors.border_subtle,
                                        .corner_radius = dvui.Rect.all(theme.radius.pill),
                                        .min_size_content = .{ .w = 5, .h = 5 },
                                        .max_size_content = .{ .w = 5, .h = 5 },
                                        .margin = .{ .x = 3, .y = 0, .w = 3, .h = 0 },
                                        .gravity_y = 0.5,
                                    });
                                    dot.deinit();
                                }

                                if (dvui.buttonIcon(@src(), "fact-next", icons.tvg.lucide.@"chevron-right", .{}, .{}, .{
                                    .id_extra = i + 3172,
                                    .color_fill = theme.transparent,
                                    .color_text = theme.colors.text_tertiary,
                                    .border = dvui.Rect.all(0),
                                    .min_size_content = .{ .w = 18, .h = 18 },
                                    .max_size_content = .{ .w = 18, .h = 18 },
                                    .gravity_y = 0.5,
                                })) {
                                    p.loading_card_manual +%= 1;
                                    p.loading_card_since_ms = now_ms;
                                }
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
