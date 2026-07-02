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

    // Everything below the hero lives in ONE centered reading column — the
    // console layout (like the chat transcript), not a full-width dashboard.
    // dvui expand ignores max_size_content, so compute a fixed width.
    // Centering caveat: a horizontal box packs children left along its main
    // axis (gravity there is ignored) — cross-axis gravity in a VERTICAL
    // parent is what actually centers a fixed-width child.
    var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer wrap.deinit();
    const avail = wrap.data().rect.w;
    const colw: f32 = if (avail > 1) @min(920.0, avail) else 920.0;
    var hub = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_x = 0.5,
        .min_size_content = .{ .w = colw, .h = 0 },
        .max_size_content = dvui.Options.MaxSize.width(colw),
    });
    defer hub.deinit();

    // Generate taste recommendations once per session (DB + vec0 KNN). Wait
    // for the async history load — generating on the very first frame raced
    // it and permanently produced an empty rail.
    {
        const recs = @import("../services/recommendations.zig");
        const Once = struct {
            var done: bool = false;
        };
        if (!Once.done and state.app.init_history_loaded) {
            Once.done = true;
            recs.generateRecommendations();
        }
    }

    const watching = &state.app.tmdb.watching;
    const watchlist = &state.app.tmdb.watchlist;
    const favorites = &state.app.tmdb.favorites;

    // Console order: what you're mid-way through, then discovery (trending +
    // taste), then your lists, then raw history. No stats dashboard — the
    // conversation and the media are the page.
    if (watching.items.len > 0)
        posterStrip("Continue Watching", icons.tvg.lucide.play, watching, .Watching, 1);
    renderTrendingRail();
    @import("discovery_ui.zig").renderForYouRail();
    if (watchlist.items.len > 0)
        posterStrip("Watchlist", icons.tvg.lucide.bookmark, watchlist, .Watchlist, 2);
    if (favorites.items.len > 0)
        posterStrip("Favorites", icons.tvg.lucide.star, favorites, .Favorites, 3);
    renderRecentlyPlayed();

    // Nothing at all to show (no TMDB key, no history) → gentle CTA.
    const everything_empty = watching.items.len == 0 and watchlist.items.len == 0 and
        favorites.items.len == 0 and wh.count == 0;
    if (everything_empty and state.app.tmdb.api_key_len == 0) {
        renderEmptyState();
    }
}

/// "Trending tonight" — the discovery rail that makes the idle console feel
/// alive. Reads the same shared trending list Browse uses (posters land
/// instantly from the disk cache on relaunch); kicks ONE fetch per session
/// when the list is empty. Hidden while the shared list holds a search or
/// genre-discover result set — those aren't trending.
fn renderTrendingRail() void {
    const t = &state.app.tmdb;
    if (t.api_key_len == 0) return;
    if (t.view != .Trending or t.genre_idx != 0) return;

    const Once = struct {
        var kicked: bool = false;
    };
    if (t.results.items.len == 0 and !Once.kicked and !t.is_loading.load(.acquire)) {
        Once.kicked = true;
        t.loaded_once = true; // Browse must not immediately refetch over this
        @import("../services/tmdb_api.zig").fetchCurrentView(false);
    }
    if (t.results.items.len == 0) return;

    posterStrip("Trending tonight", icons.tvg.lucide.flame, &t.results, .Trending, 4);
}

// ── Hero (idle console) — greeting + big prompt + suggestion chips ──

fn renderHero() void {
    const home_pure = @import("home_pure.zig");

    // Breathing room scales with the window so the prompt sits like a landing
    // hero, not a toolbar row. windowRect() is logical units (same as layout).
    const win_h = dvui.windowRect().h;
    const top_pad = std.math.clamp(win_h * 0.11, 20.0, 140.0);

    var hero = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.lg, .y = top_pad, .w = theme.spacing.lg, .h = theme.spacing.sm },
    });
    defer hero.deinit();

    const hour = localHour();

    // Eyebrow — quiet time-aware greeting with a spark.
    {
        var eyebrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
        defer eyebrow.deinit();
        dvui.icon(@src(), "hero-spark", icons.tvg.lucide.sparkles, .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 13, .h = 13 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{home_pure.greetingForHour(hour)}, .{
            .color_text = theme.colors.accent,
            .gravity_y = 0.5,
        });
    }

    // Headline — one size above the compact ramp on purpose: this is the one
    // landing-page moment in the app.
    _ = dvui.label(@src(), "{s}", .{home_pure.headlineForHour(hour)}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_title.withSize(27),
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
    });
    _ = dvui.label(@src(), "Ask for a mood, a title, or paste any link — Opal finds it, plays it, and learns your taste.", .{}, .{
        .color_text = theme.colors.text_tertiary,
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.md },
    });

    // The big prompt — same unified input the header uses (media plays,
    // questions go to the AI, everything else fans out to search). The pill
    // sizes and centers itself (fixed 480-620 width, gravity 0.5).
    @import("header.zig").renderUrlInput(true);

    // Suggestion chips — conversation starters that submit straight to the AI.
    {
        var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = 0 },
        });
        defer wrap.deinit();
        const avail = wrap.data().rect.w;
        const chips_w: f32 = if (avail > 1) @min(720.0, avail) else 720.0;
        var chips = dvui.flexbox(@src(), .{ .justify_content = .center }, .{
            .gravity_x = 0.5,
            .min_size_content = .{ .w = chips_w, .h = 0 },
            .max_size_content = dvui.Options.MaxSize.width(chips_w),
        });
        defer chips.deinit();

        const starters = [_]struct { icon: []const u8, label: []const u8, prompt: []const u8 }{
            .{ .icon = icons.tvg.lucide.@"wand-sparkles", .label = "Recommend tonight's movie", .prompt = "Recommend a movie for tonight" },
            .{ .icon = icons.tvg.lucide.flame, .label = "What's trending?", .prompt = "What's trending this week?" },
            .{ .icon = icons.tvg.lucide.laugh, .label = "Something funny", .prompt = "Play something funny" },
            .{ .icon = icons.tvg.lucide.telescope, .label = "Mind-bending sci-fi", .prompt = "Find a mind-bending sci-fi show" },
        };
        for (starters, 0..) |st, i| {
            var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i,
                .background = true,
                .color_fill = theme.colors.bg_surface,
                .border = dvui.Rect.all(1),
                .color_border = theme.colors.border_subtle,
                .corner_radius = dvui.Rect.all(theme.radius.pill),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .margin = dvui.Rect.all(3),
            });
            defer chip.deinit();
            var hovered = false;
            if (dvui.clicked(chip.data(), .{ .hovered = &hovered })) {
                @memset(&state.app.magnet_buf, 0);
                const n = @min(st.prompt.len, state.app.magnet_buf.len - 1);
                @memcpy(state.app.magnet_buf[0..n], st.prompt[0..n]);
                @import("header.zig").submitInput(); // → AI chat; page flips to chat mode
            }
            if (hovered) chip.data().options.color_fill = theme.colors.bg_hover;
            chip.drawBackground();

            dvui.icon(@src(), "chip-icon", st.icon, .{}, .{
                .id_extra = i,
                .color_text = theme.colors.accent,
                .min_size_content = .{ .w = 13, .h = 13 },
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
            });
            _ = dvui.label(@src(), "{s}", .{st.label}, .{
                .id_extra = i,
                .color_text = theme.colors.text_secondary,
                .gravity_y = 0.5,
            });
        }
    }

    renderCapabilities();
}

/// Three quiet value-prop tiles under the hero — what the agent can do.
/// Informational (no hover/click): landing copy, not chrome.
fn renderCapabilities() void {
    const caps = [_]struct { icon: []const u8, title: []const u8, body: []const u8 }{
        .{ .icon = icons.tvg.lucide.zap, .title = "Plays everything", .body = "Magnets, torrents, files, streams — paste it and it plays." },
        .{ .icon = icons.tvg.lucide.brain, .title = "Learns your taste", .body = "Private, on-device recommendations from what you actually watch." },
        .{ .icon = icons.tvg.lucide.@"audio-lines", .title = "Voice conversations", .body = "Talk hands-free with a fully local AI — nothing leaves the machine." },
    };

    var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.lg, .w = 0, .h = 0 },
    });
    defer wrap.deinit();
    const avail = wrap.data().rect.w;
    const row_w: f32 = if (avail > 1) @min(760.0, avail) else 760.0;
    var row = dvui.flexbox(@src(), .{ .justify_content = .center }, .{
        .gravity_x = 0.5,
        .min_size_content = .{ .w = row_w, .h = 0 },
        .max_size_content = dvui.Options.MaxSize.width(row_w),
    });
    defer row.deinit();

    var small_font = dvui.themeGet().font_body;
    small_font.size = theme.font_size.small;

    for (caps, 0..) |cap, i| {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .border = dvui.Rect.all(1),
            .color_border = theme.colors.border_subtle,
            .corner_radius = dvui.Rect.all(theme.radius.lg),
            .min_size_content = .{ .w = 208, .h = 0 },
            .max_size_content = .{ .w = 208, .h = std.math.floatMax(f32) },
            .padding = dvui.Rect.all(theme.spacing.md),
            .margin = dvui.Rect.all(4),
        });
        defer card.deinit();

        {
            var hd = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i });
            defer hd.deinit();
            dvui.icon(@src(), "cap-icon", cap.icon, .{}, .{
                .id_extra = i,
                .color_text = theme.colors.accent,
                .min_size_content = .{ .w = 14, .h = 14 },
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
            });
            _ = dvui.label(@src(), "{s}", .{cap.title}, .{
                .id_extra = i,
                .color_text = theme.colors.text_primary,
                .gravity_y = 0.5,
            });
        }
        var tl = dvui.textLayout(@src(), .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = false,
            .font = small_font,
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
            .padding = dvui.Rect.all(0),
        });
        tl.addText(cap.body, .{ .color_text = theme.colors.text_tertiary });
        tl.deinit();
    }
}

/// Local hour (0-23) via SQLite's localtime — cached for the session.
/// Zig 0.16 std.time is UTC-only; the linked SQLite gets timezones right.
fn localHour() u8 {
    const db = @import("../core/db.zig");
    const S = struct {
        var cached: i32 = -1;
    };
    if (S.cached < 0) {
        S.cached = 20; // graceful default: evening
        if (db.prepare("SELECT CAST(strftime('%H','now','localtime') AS INTEGER)")) |stmt| {
            defer db.finalize(stmt);
            if (db.step(stmt) == db.c.SQLITE_ROW) S.cached = db.columnInt(stmt, 0);
        }
    }
    return @intCast(std.math.clamp(S.cached, 0, 23));
}

// ── Chat mode — full-page transcript + pinned composer ──

fn renderChatMode() void {
    const ai_chat = @import("../services/ai_chat.zig");
    const grid = @import("grid.zig");

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer page.deinit();

    // Transcript — the page scroll, centered reading column.
    // NOTE: dvui `expand` IGNORES max_size_content (expansion always fills the
    // parent rect), so `.expand + .max_size_content` was a full-window column —
    // user bubbles glued to the right window edge. Compute a FIXED column
    // width instead: min(760, available), one-frame lag on first paint.
    {
        var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &chat_si }, .{
            .expand = .both,
            .background = false,
        });
        defer scroll.deinit();

        // Vertical wrapper + cross-axis gravity — a horizontal box would pack
        // the fixed column left (main-axis gravity is ignored).
        var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer wrap.deinit();
        const avail = wrap.data().rect.w;
        const colw: f32 = if (avail > 1) @min(760.0, avail) else 760.0;
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{
            .gravity_x = 0.5,
            .min_size_content = .{ .w = colw, .h = 0 },
            .max_size_content = dvui.Options.MaxSize.width(colw),
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

        // Same fixed-width + cross-axis-gravity treatment as the transcript.
        var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer wrap.deinit();
        const avail = wrap.data().rect.w;
        const colw: f32 = if (avail > 1) @min(760.0, avail) else 760.0;
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{
            .gravity_x = 0.5,
            .min_size_content = .{ .w = colw, .h = 0 },
            .max_size_content = dvui.Options.MaxSize.width(colw),
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

// ── Poster strips (Continue / Trending / Watchlist / Favorites) ──

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

// ── Jump back in (watch history) — resume cards with progress ──

fn renderRecentlyPlayed() void {
    if (wh.count == 0) return;
    const home_pure = @import("home_pure.zig");

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
        _ = dvui.label(@src(), "Jump back in", .{}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
        });
    }

    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none }, .{
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .w = 10, .h = 78 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = 78 },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer scroll.deinit();
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    defer strip.deinit();

    const n = @min(wh.count, 12);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = &wh.entries[i];
        // Cleaned display name (basename, no extension, dots→spaces); bare
        // content hashes ("8248045d…") get a friendly torrent label.
        var clean_buf: [128]u8 = undefined;
        const cleaned = @import("grid.zig").cleanDisplayName(&clean_buf, e.name[0..e.name_len]);
        var hash_buf: [48]u8 = undefined;
        const display = if (home_pure.looksLikeHexHash(cleaned))
            std.fmt.bufPrint(&hash_buf, "Torrent stream · {s}", .{cleaned[0..@min(cleaned.len, 8)]}) catch cleaned
        else
            cleaned;
        var clip_buf: [40]u8 = undefined;
        const name = tmdb.safeUtf8(home_pure.clipLabel(&clip_buf, display, 28));
        const frac: f32 = std.math.clamp(@as(f32, @floatCast(e.percent)), 0.0, 1.0);
        const pct: u8 = @intFromFloat(frac * 100.0);
        const done = pct >= 90;

        var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 70000,
            .min_size_content = .{ .w = 250, .h = 44 },
            .max_size_content = .{ .w = 250, .h = 44 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .border = dvui.Rect.all(1),
            .color_border = theme.colors.border_subtle,
            .corner_radius = dvui.Rect.all(theme.radius.lg),
            .padding = dvui.Rect.all(theme.spacing.sm),
            .margin = .{ .x = 3, .y = 2, .w = 3, .h = 2 },
        });
        defer card.deinit();

        var hovered = false;
        if (dvui.clicked(card.data(), .{ .hovered = &hovered })) {
            if (e.link_len > 0) browser.resumePlayback(e.link[0..e.link_len]);
        }
        if (hovered) card.data().options.color_fill = theme.colors.bg_hover;
        card.drawBackground();

        // Thumb — flips to a play glyph on hover.
        {
            var thumb = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i + 70000,
                .min_size_content = .{ .w = 36, .h = 36 },
                .max_size_content = .{ .w = 36, .h = 36 },
                .background = true,
                .color_fill = theme.colors.bg_elevated,
                .corner_radius = dvui.Rect.all(theme.radius.md),
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
            defer thumb.deinit();
            dvui.icon(@src(), "thumb", if (hovered) icons.tvg.lucide.play else icons.tvg.lucide.film, .{}, .{
                .id_extra = i + 70000,
                .color_text = if (hovered) theme.colors.accent else theme.colors.text_secondary,
                .min_size_content = .{ .w = 16, .h = 16 },
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
        }

        var meta = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i + 70000, .gravity_y = 0.5 });
        defer meta.deinit();
        _ = dvui.label(@src(), "{s}", .{name}, .{
            .id_extra = i + 70000,
            .color_text = theme.colors.text_primary,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
        });
        {
            var prow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i + 70000,
                .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
            });
            defer prow.deinit();
            const bar_w: f32 = 140;
            {
                var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = i + 70000,
                    .min_size_content = .{ .w = bar_w, .h = 4 },
                    .max_size_content = .{ .w = bar_w, .h = 4 },
                    .background = true,
                    .color_fill = theme.colors.bg_elevated,
                    .corner_radius = dvui.Rect.all(theme.radius.pill),
                    .gravity_y = 0.5,
                });
                defer bar.deinit();
                const fill_w = bar_w * frac;
                if (fill_w >= 1) {
                    var fill = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = i + 70000,
                        .min_size_content = .{ .w = fill_w, .h = 4 },
                        .max_size_content = .{ .w = fill_w, .h = 4 },
                        .background = true,
                        .color_fill = if (done) theme.colors.success else theme.colors.accent,
                        .corner_radius = dvui.Rect.all(theme.radius.pill),
                    });
                    fill.deinit();
                }
            }
            var small_font = dvui.themeGet().font_body;
            small_font.size = theme.font_size.small;
            var pb: [16]u8 = undefined;
            if (std.fmt.bufPrint(&pb, "{d}%", .{pct})) |ps| {
                _ = dvui.label(@src(), "{s}", .{ps}, .{
                    .id_extra = i + 70500,
                    .color_text = if (done) theme.colors.success else theme.colors.text_tertiary,
                    .font = small_font,
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(0),
                    .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
                });
            } else |_| {}
        }
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
