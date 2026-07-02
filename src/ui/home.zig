//! Home — the dashboard landing page (distinct from Browse).
//!
//! Browse is for discovery (trending/categories across sources). Home is the
//! user's own hub: at-a-glance usage metrics, continue-watching, tracked
//! (watchlist), wished (favorites), and recently-played. Reuses the TMDB poster
//! card so visuals stay consistent.
//!
//! Rules: SVG (lucide TVG) icons only — never emojis.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const state = @import("../core/state.zig");
const tmdb = @import("../services/tmdb.zig");
const wh = @import("../player/watch_history.zig");
const browser = @import("../services/browser.zig");

const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

const STRIP_CARD_W: f32 = 132;
const STRIP_POSTER_H: f32 = STRIP_CARD_W * 1.5;
const STRIP_MAX: usize = 24; // cap cards per strip (perf)

// ── Chat-mode page state ──
// Own the transcript's ScrollInfo so new messages can pin the view to the
// bottom (ChatGPT-style follow), and remember a content signature so we only
// force-scroll when the conversation actually grew.
var chat_si: dvui.ScrollInfo = .{};
var chat_last_sig: u64 = 0;

pub fn render() void {
    // Home is the conversational console: once a conversation exists the page
    // IS the chat (transcript + pinned composer, like ChatGPT/Claude); when
    // idle it's a hero prompt over the media hub (rails + stats).
    const ai_chat = @import("../services/ai_chat.zig");
    const has_chat = ai_chat.message_count > 0 or ai_chat.is_generating.load(.acquire);
    if (has_chat) {
        renderChatMode();
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = false,
    });
    defer scroll.deinit();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.sm, .y = 0, .w = theme.spacing.sm, .h = theme.spacing.lg },
    });
    defer col.deinit();

    renderHero();

    // Taste Receipts: the For-You rail. Generate recommendations once per
    // session (DB + vec0 KNN — a one-time cost on first Home view; off-thread
    // optimization is a follow-up), then render the rail (no-op when empty).
    // Wait for the async history load — generating on the very first frame
    // raced it and permanently produced the "No watch history yet" fallback.
    {
        const recs = @import("../services/recommendations.zig");
        const Once = struct {
            var done: bool = false;
        };
        if (!Once.done and state.app.init_history_loaded) {
            Once.done = true;
            recs.generateRecommendations();
        }
        @import("discovery_ui.zig").renderForYouRail();
    }

    const watching = &state.app.tmdb.watching;
    const watchlist = &state.app.tmdb.watchlist;
    const favorites = &state.app.tmdb.favorites;
    const everything_empty = watching.items.len == 0 and watchlist.items.len == 0 and
        favorites.items.len == 0 and wh.count == 0;

    if (everything_empty) {
        renderEmptyState();
        return;
    }

    if (watching.items.len > 0)
        posterStrip("Continue Watching", icons.tvg.lucide.play, watching, .Watching, 1);
    renderRecentlyPlayed();
    if (watchlist.items.len > 0)
        posterStrip("Watchlist", icons.tvg.lucide.bookmark, watchlist, .Watchlist, 2);
    if (favorites.items.len > 0)
        posterStrip("Favorites", icons.tvg.lucide.star, favorites, .Favorites, 3);

    // Usage metrics — demoted to the bottom of the hub (the conversation and
    // the media rails are the console; the stats are trivia).
    renderStats();
}

// ── Hero (idle console) — greeting + big prompt + suggestion chips ──

fn renderHero() void {
    var hero = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.xxl, .w = theme.spacing.lg, .h = theme.spacing.lg },
    });
    defer hero.deinit();

    _ = dvui.label(@src(), "What are we watching tonight?", .{}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_title,
        .gravity_x = 0.5,
    });
    _ = dvui.label(@src(), "Ask, search, or paste a link — magnets, files, and questions all work.", .{}, .{
        .color_text = theme.colors.text_tertiary,
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.md },
    });

    // The big prompt — same unified input the player hero uses (media plays,
    // questions go to the AI, everything else fans out to search).
    {
        var center = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5 });
        defer center.deinit();
        var input_col = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .max_size_content = dvui.Options.MaxSize.width(720),
        });
        defer input_col.deinit();
        @import("header.zig").renderUrlInput(true);
    }

    // Suggestion chips — ChatGPT-style starters that submit straight to the AI.
    {
        var center = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5, .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 } });
        defer center.deinit();
        var chips = dvui.flexbox(@src(), .{ .justify_content = .center }, .{
            .max_size_content = dvui.Options.MaxSize.width(720),
        });
        defer chips.deinit();

        const prompts = [_][]const u8{
            "Recommend a movie for tonight",
            "What's trending this week?",
            "Play something funny",
            "Find a mind-bending sci-fi show",
        };
        for (prompts, 0..) |prompt, i| {
            if (dvui.button(@src(), prompt, .{}, .{
                .id_extra = i,
                .color_fill = theme.colors.bg_surface,
                .color_fill_hover = theme.colors.bg_hover,
                .color_text = theme.colors.text_secondary,
                .border = dvui.Rect.all(1),
                .color_border = theme.colors.border_subtle,
                .corner_radius = dvui.Rect.all(theme.radius.pill),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .margin = dvui.Rect.all(3),
            })) {
                @memset(&state.app.magnet_buf, 0);
                const n = @min(prompt.len, state.app.magnet_buf.len - 1);
                @memcpy(state.app.magnet_buf[0..n], prompt[0..n]);
                @import("header.zig").submitInput(); // → AI chat; page flips to chat mode
            }
        }
    }
}

// ── Chat mode — full-page transcript + pinned composer ──

fn renderChatMode() void {
    const ai_chat = @import("../services/ai_chat.zig");
    const grid = @import("grid.zig");

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer page.deinit();

    // Transcript — the page scroll, centered reading column.
    {
        var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &chat_si }, .{
            .expand = .both,
            .background = false,
        });
        defer scroll.deinit();

        var center = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5 });
        defer center.deinit();
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .max_size_content = dvui.Options.MaxSize.width(760),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.md, .w = theme.spacing.md, .h = theme.spacing.md },
        });
        defer col.deinit();

        grid.renderChatMessages();
    }

    // Follow the conversation: when the transcript grows (new message or new
    // streamed bytes), pin the scroll to the bottom — manual scrolling back
    // is untouched between growth events.
    {
        var sig: u64 = ai_chat.message_count;
        if (ai_chat.message_count > 0) {
            sig = sig *% 1000003 +% ai_chat.messages[ai_chat.message_count - 1].text_len;
        }
        if (sig != chat_last_sig) {
            chat_last_sig = sig;
            chat_si.scrollToOffset(.vertical, std.math.floatMax(f32)); // clamped to max
        }
    }

    // Composer — pinned under the transcript, ChatGPT-style.
    {
        var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_app,
            .color_border = theme.colors.border_subtle,
            .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        });
        defer bar.deinit();

        var center = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5 });
        defer center.deinit();
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .max_size_content = dvui.Options.MaxSize.width(760),
        });
        defer col.deinit();

        // Context + voice phase — one quiet line above the input.
        {
            var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer meta.deinit();

            // Incognito chat toggle — when on, this conversation is not
            // persisted (no conversation log, no vector memory, no starring
            // to DB). Same switch as incognito watch history.
            var inc_wd: dvui.WidgetData = undefined;
            if (dvui.buttonIcon(@src(), "incognito-chat", if (state.app.incognito_mode) icons.tvg.lucide.@"eye-off" else icons.tvg.lucide.eye, .{}, .{}, .{
                .data_out = &inc_wd,
                .color_text = if (state.app.incognito_mode) theme.colors.warning else theme.colors.text_tertiary,
                .color_fill = theme.transparent,
                .color_fill_hover = theme.colors.bg_hover,
                .border = dvui.Rect.all(0),
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = theme.spacing.xs, .y = 2, .w = theme.spacing.xs, .h = 2 },
                .min_size_content = theme.iconSize(.xs),
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            })) {
                state.app.incognito_mode = !state.app.incognito_mode;
                state.showToast(if (state.app.incognito_mode) "Incognito ON — chat & history won't be remembered" else "Incognito OFF");
            }
            @import("components.zig").tip(@src(), inc_wd, if (state.app.incognito_mode) "Incognito chat: ON — nothing is persisted" else "Incognito chat: off");
            if (state.app.incognito_mode) {
                _ = dvui.label(@src(), "Incognito", .{}, .{
                    .color_text = theme.colors.warning,
                    .gravity_y = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
                });
            }

            const has_media = state.app.active_player_idx < state.app.players.items.len;
            if (has_media) {
                const ap = state.app.players.items[state.app.active_player_idx];
                var title_buf: [128]u8 = undefined;
                const title_len = ap.getMediaTitle(&title_buf);
                var mb: [128]u8 = undefined;
                const media_label = @import("../core/text.zig").safeUtf8Buf(title_buf[0..title_len], &mb);
                if (media_label.len > 0) {
                    var chip_buf: [160]u8 = undefined;
                    const chip_txt = std.fmt.bufPrint(&chip_buf, "Seeing: {s}", .{media_label}) catch "";
                    _ = dvui.label(@src(), "{s}", .{chip_txt}, .{
                        .color_text = theme.colors.text_tertiary,
                        .gravity_y = 0.5,
                    });
                }
            }

            const voice = @import("../services/ai_voice.zig");
            const phase_txt: ?[]const u8 = switch (voice.conv_phase) {
                .listening => "Listening…",
                .transcribing => "Transcribing…",
                .thinking => "Thinking…",
                .speaking => "Speaking…",
                .idle => if (ai_chat.is_generating.load(.acquire)) "Thinking…" else null,
            };
            if (phase_txt) |txt| {
                _ = dvui.label(@src(), "  ·  {s}", .{txt}, .{
                    .color_text = theme.colors.accent,
                    .gravity_y = 0.5,
                });
            }

            {
                var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                sp.deinit();
            }
            // Clear chat — two-step confirm; returns Home to the idle hub.
            if (@import("components.zig").confirmDangerButton(@src(), "Clear chat", 0)) {
                ai_chat.clearHistory();
                chat_last_sig = 0;
            }
        }

        @import("header.zig").renderUrlInput(true);
    }
}

// ── Metrics ──

fn renderStats() void {
    // Live lifetime total = persisted total + seconds since the last accrual.
    const now = @import("../core/io_global.zig").timestamp();
    const since: i64 = if (state.app.usage_last_tick > 0) @max(0, now - state.app.usage_last_tick) else 0;
    const lifetime = state.app.usage_seconds_total + since;
    const session: i64 = if (state.app.session_start_s > 0) @max(0, now - state.app.session_start_s) else 0;

    var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.sm, .w = theme.spacing.xs, .h = theme.spacing.sm },
    });
    // Tick once per second so the live "Time in app" / "This session" counters
    // advance even while the UI is otherwise idle (re-arm pattern — 1 frame/s,
    // no busy loop).
    const clock_id = hdr.data().id;
    {
        // Small section label — the stats sit at the BOTTOM of the hub now
        // (the conversation is the page), so no big page title here.
        dvui.icon(@src(), "activity", icons.tvg.lucide.activity, .{}, .{
            .color_text = theme.colors.text_tertiary,
            .min_size_content = theme.iconSize(.sm),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "Activity", .{}, .{
            .color_text = theme.colors.text_secondary,
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
        });
    }
    hdr.deinit();

    if (dvui.timerDoneOrNone(clock_id)) dvui.timer(clock_id, 1_000_000);

    // Stat cards — a wrapping flex row so they fill the width on any size.
    var bar = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.sm },
    });
    defer bar.deinit();

    var tb: [32]u8 = undefined;
    var sb: [32]u8 = undefined;
    statCard(1, icons.tvg.lucide.clock, "Time in app", fmtDuration(&tb, lifetime), theme.colors.accent);
    statCard(2, icons.tvg.lucide.@"alarm-clock", "This session", fmtDuration(&sb, session), theme.colors.text_secondary);
    statCardN(3, icons.tvg.lucide.play, "Watching", state.app.tmdb.watching.items.len, theme.colors.success);
    statCardN(4, icons.tvg.lucide.bookmark, "Watchlist", state.app.tmdb.watchlist.items.len, theme.colors.accent);
    statCardN(5, icons.tvg.lucide.star, "Favorites", state.app.tmdb.favorites.items.len, dvui.Color{ .r = 255, .g = 215, .b = 0, .a = 255 });
    statCardN(6, icons.tvg.lucide.history, "Recently played", wh.count, theme.colors.text_secondary);
}

fn statCard(id: usize, icon: []const u8, label: []const u8, value: []const u8, accent: dvui.Color) void {
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .min_size_content = .{ .w = 150, .h = 0 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        .margin = dvui.Rect.all(theme.spacing.xs),
    });
    defer card.deinit();

    {
        var top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal });
        defer top.deinit();
        dvui.icon(@src(), label, icon, .{}, .{
            .id_extra = id,
            .color_text = accent,
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{label}, .{
            .id_extra = id,
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
        });
    }
    _ = dvui.label(@src(), "{s}", .{value}, .{
        .id_extra = id + 1000,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
    });
}

fn statCardN(id: usize, icon: []const u8, label: []const u8, n: usize, accent: dvui.Color) void {
    var nb: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&nb, "{d}", .{n}) catch "0";
    statCard(id, icon, label, s, accent);
}

/// "Xh Ym" / "Ym" / "Zs" — compact human duration from seconds.
fn fmtDuration(buf: []u8, secs: i64) []const u8 {
    const s = @max(0, secs);
    const h = @divFloor(s, 3600);
    const m = @divFloor(@mod(s, 3600), 60);
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, m }) catch "0";
    if (m > 0) return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "0";
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "0";
}

// ── Poster strips (Continue / Watchlist / Favorites) ──

fn posterStrip(title: []const u8, icon: []const u8, items: *std.ArrayListUnmanaged(state.TmdbItem), view: state.TmdbView, id: usize) void {
    sectionHeader(title, icon, view, id);

    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none }, .{
        .id_extra = id,
        .expand = .horizontal,
        // Transparent — dvui's default scroll fill is light; show the dark page.
        .background = false,
        .min_size_content = .{ .w = 10, .h = STRIP_POSTER_H + 70 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = STRIP_POSTER_H + 70 },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer scroll.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id });
    defer row.deinit();

    const n = @min(items.items.len, STRIP_MAX);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        tmdb.renderPosterCard(&items.items[i], i, STRIP_CARD_W, STRIP_POSTER_H);
    }
}

fn sectionHeader(title: []const u8, icon: []const u8, view: state.TmdbView, id: usize) void {
    var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id + 6000,
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.sm, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer hdr.deinit();

    dvui.icon(@src(), title, icon, .{}, .{
        .id_extra = id + 6000,
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.sm),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{title}, .{
        .id_extra = id + 6000,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
        .gravity_y = 0.5,
    });
    {
        var sp = dvui.box(@src(), .{}, .{ .id_extra = id + 6000, .expand = .horizontal });
        sp.deinit();
    }
    // "See all" — jumps to Browse > Movies & TV with this list selected.
    var sa = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id + 6100,
        .background = true,
        .color_fill = transparent,
        .color_fill_hover = theme.colors.bg_hover,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
        .gravity_y = 0.5,
    });
    defer sa.deinit();
    if (dvui.clicked(sa.data(), .{})) {
        state.app.tmdb.view = view;
        state.app.browse_source = .TMDB;
        state.app.router.navigate(.browse);
    }
    sa.drawBackground();
    _ = dvui.label(@src(), "See all", .{}, .{
        .id_extra = id + 6100,
        .color_text = theme.colors.text_secondary,
        .gravity_y = 0.5,
    });
    dvui.icon(@src(), "see-all", icons.tvg.lucide.@"chevron-right", .{}, .{
        .id_extra = id + 6100,
        .color_text = theme.colors.text_secondary,
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_y = 0.5,
    });
}

// ── Recently played (watch history) ──

fn renderRecentlyPlayed() void {
    if (wh.count == 0) return;

    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.sm, .w = theme.spacing.xs, .h = theme.spacing.xs },
        });
        defer hdr.deinit();
        dvui.icon(@src(), "recent", icons.tvg.lucide.history, .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = theme.iconSize(.sm),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "Recently Played", .{}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
        });
    }

    const n = @min(wh.count, 8);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = &wh.entries[i];
        // Show a cleaned display name (basename, no extension, dots→spaces)
        // instead of raw paths/URLs — same formatter the poster tiles use.
        var clean_buf: [128]u8 = undefined;
        const cleaned = @import("grid.zig").cleanDisplayName(&clean_buf, e.name[0..e.name_len]);
        const name = tmdb.safeUtf8(cleaned);
        const pct: u8 = @intFromFloat(std.math.clamp(e.percent * 100.0, 0.0, 100.0));

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 70000,
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 30 },
            .background = true,
            .color_fill = transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = theme.spacing.xs, .y = 1, .w = theme.spacing.xs, .h = 1 },
        });
        defer row.deinit();

        if (e.link_len > 0 and dvui.clicked(row.data(), .{})) {
            browser.resumePlayback(e.link[0..e.link_len]);
        }
        row.drawBackground();

        dvui.icon(@src(), "", icons.tvg.lucide.film, .{}, .{
            .id_extra = i + 70000,
            .color_text = theme.colors.text_secondary,
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{name}, .{
            .id_extra = i + 70000,
            .expand = .horizontal,
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
        });
        var pb: [16]u8 = undefined;
        if (std.fmt.bufPrint(&pb, "{d}%", .{pct})) |ps| {
            _ = dvui.label(@src(), "{s}", .{ps}, .{
                .id_extra = i + 70500,
                .color_text = if (pct >= 90) theme.colors.success else theme.colors.text_secondary,
                .gravity_y = 0.5,
            });
        } else |_| {}
    }
}

// ── Empty state ──

fn renderEmptyState() void {
    // Normal flow block BELOW the stats — must not expand/center over them.
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .gravity_x = 0.5,
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.xl, .w = theme.spacing.lg, .h = theme.spacing.lg },
    });
    defer box.deinit();

    dvui.icon(@src(), "empty", icons.tvg.lucide.@"clapperboard", .{}, .{
        .color_text = theme.colors.accent_dim,
        .min_size_content = theme.iconSize(.hero),
        .gravity_x = 0.5,
    });
    _ = dvui.label(@src(), "Your hub is empty", .{}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_title,
        .gravity_x = 0.5,
    });
    _ = dvui.label(@src(), "Browse to discover, then star and bookmark to fill this page.", .{}, .{
        .color_text = theme.colors.text_secondary,
        .gravity_x = 0.5,
    });
    if (dvui.button(@src(), "Browse", .{}, .{
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = 0 },
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.text_on_accent,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.sm, .w = theme.spacing.lg, .h = theme.spacing.sm },
    })) {
        state.app.browse_source = .TMDB;
        state.app.router.navigate(.browse);
    }
}
