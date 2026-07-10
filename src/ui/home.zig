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

const STRIP_MAX: usize = 24; // cap cards per strip (perf)
const STRIP_CHROME: f32 = 88; // pct/type row + wrapped title under each poster
const RAIL_EXTRA: f32 = STRIP_CHROME + 38; // strip chrome + section header

// ── Chat-mode page state ──
// Own the transcript's ScrollInfo so new messages can pin the view to the
// bottom (ChatGPT-style follow), and remember a content signature so we only
// force-scroll when the conversation actually grew.
var chat_si: dvui.ScrollInfo = .{};
var chat_last_sig: u64 = 0;

// Logo-click escape hatch: view the Home overview while a conversation
// exists. Cleared automatically when the conversation grows (new submit).
var overview_requested: bool = false;
var overview_seen_count: usize = 0;

/// Called by the shell brand button: show the hub even mid-conversation.
pub fn showOverview() void {
    overview_requested = true;
    overview_seen_count = @import("../services/ai_chat.zig").message_count;
}
var chat_sidebar_open: bool = true; // Claude-style history rail (auto-hidden when narrow)

pub fn render() void {
    // Home is the conversational console: once a conversation exists the page
    // IS the chat (transcript + pinned composer, like ChatGPT/Claude); when
    // idle it's a hero prompt over the media hub (rails + stats).
    const ai_chat = @import("../services/ai_chat.zig");
    // A new message while overviewing pulls the page back into the chat.
    if (overview_requested and ai_chat.message_count != overview_seen_count)
        overview_requested = false;
    const has_chat = @import("home_pure.zig").chatModeActive(
        ai_chat.message_count,
        ai_chat.is_generating.load(.acquire),
        overview_requested,
    );
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

    // Everything lives in ONE centered reading column — the console layout
    // (like the chat transcript), not a full-width dashboard. dvui expand
    // ignores max_size_content, so compute a fixed width. Centering caveat:
    // a horizontal box packs children left along its main axis (gravity there
    // is ignored) — cross-axis gravity in a VERTICAL parent is what centers.
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

    // Kick the trending fetch independently of layout: the rail's budget
    // gate must never decide whether data loads (it once did, and a short
    // window meant trending never fetched at all this session).
    kickTrendingFetch();

    // TV calendar ("Coming up") — one refresh per session, after the DB init
    // worker has run so tv_continue is readable.
    if (state.app.init_history_loaded) @import("../services/tv_calendar.zig").refreshOnce();

    const watching = &state.app.tmdb.watching;
    const watchlist = &state.app.tmdb.watchlist;
    const favorites = &state.app.tmdb.favorites;

    // ── App-shell fit ──
    // Home reads as ONE screen, not a scrolling feed: measure everything
    // above the rails (previous frame's min size — the shell.zig MeasuredH
    // pattern; estimating heights drifted ~120px and clipped rail titles),
    // then render rails in priority order while they fit the leftover.
    // "See all" covers the rest; the scrollArea stays as a safety net.
    var top = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    const top_h: f32 = if (dvui.minSizeGet(top.data().id)) |ms| ms.h else 430;

    renderHero();
    // Resume first — the most actionable row lives right under the prompt.
    renderRecentlyPlayed();
    top.deinit();

    const win_h = dvui.windowRect().h;
    const tall = win_h >= 980;
    var budget: f32 = win_h - 52 - top_h; // 52 ≈ app header bar + page chrome
    // Card sizing: when the leftover fits only one rail, let the posters grow
    // into it (down to 84px before a rail is dropped — a small rail beats an
    // empty shell). With room for several rails, use the preferred size.
    const pref_w: f32 = if (tall) 132 else 104;
    const two_rails: f32 = 2 * (84.0 * 1.5 + RAIL_EXTRA);
    const fit_w: f32 = (budget - RAIL_EXTRA) / 1.5; // invert rail_h(card_w)
    const card_w: f32 = if (budget < two_rails)
        std.math.clamp(fit_w, 84.0, 132.0)
    else
        std.math.clamp(@min(pref_w, fit_w), 84.0, 132.0);
    const rail_h: f32 = card_w * 1.5 + RAIL_EXTRA;
    const foryou_h: f32 = 132 + 24 + 38; // discovery_ui CARD_H + strip + header

    if (watching.items.len > 0 and budget >= rail_h) {
        posterStrip("Continue Watching", icons.tvg.lucide.play, watching, .Watching, 1, card_w);
        budget -= rail_h;
    }
    // Trending is the primary discovery content — always render it (the page is
    // a scrollArea, so it just scrolls into view). Budget-gating it meant a tall
    // hero / short window hid all TV/movie content, reading as "nothing loaded".
    if (renderTrendingRail(card_w)) budget -= rail_h;
    // "Coming up" — poster cards (like Trending) with next-episode countdowns
    // + EZTV availability for the shows the user watches.
    if (budget >= rail_h and renderComingUpRail(card_w)) budget -= rail_h;
    if (budget >= foryou_h and @import("../services/recommendations.zig").rec_count > 0) {
        @import("discovery_ui.zig").renderForYouRail();
        budget -= foryou_h;
    }
    if (watchlist.items.len > 0 and budget >= rail_h) {
        posterStrip("Watchlist", icons.tvg.lucide.bookmark, watchlist, .Watchlist, 2, card_w);
        budget -= rail_h;
    }
    if (favorites.items.len > 0 and budget >= rail_h) {
        posterStrip("Favorites", icons.tvg.lucide.star, favorites, .Favorites, 3, card_w);
        budget -= rail_h;
    }

    // Nothing at all to show → the value-prop tiles + gentle CTA fill the shell.
    const everything_empty = watching.items.len == 0 and watchlist.items.len == 0 and
        favorites.items.len == 0 and wh.count == 0;
    if (everything_empty) {
        renderCapabilities();
        if (state.app.tmdb.api_key_len == 0) renderEmptyState();
    }
}

/// "Trending tonight" — the discovery rail that makes the idle console feel
/// alive. Reads the same shared trending list Browse uses (posters land
/// instantly from the disk cache on relaunch); kicks ONE fetch per session
/// when the list is empty. Hidden while the shared list holds a search or
/// genre-discover result set — those aren't trending.
fn kickTrendingFetch() void {
    const t = &state.app.tmdb;
    if (t.view != .Trending or t.genre_idx != 0) return;
    const Once = struct {
        var kicked: bool = false;
    };
    // Gate via the tested pure predicate so the fetch can't arm until the config
    // worker has published the key (config_loaded, acquire) — fixes the
    // first-start "Nothing loaded" race. No key -> returns false -> empty state.
    if (@import("../services/tmdb_pure.zig").shouldKickTrending(
        state.app.config_loaded.load(.acquire),
        t.api_key_len,
        t.results.items.len,
        t.is_loading.load(.acquire),
        Once.kicked,
    )) {
        Once.kicked = true;
        t.loaded_once = true; // Browse must not immediately refetch over this
        @import("../services/tmdb_api.zig").fetchCurrentView(false);
    }
}

/// "Coming up" — poster cards (matching Trending tonight) for shows the user
/// watches: poster, show name, then an air-date countdown or an EZTV
/// "available · N seeds" badge. Click opens the show. Returns true if rendered.
fn renderComingUpRail(card_w: f32) bool {
    const cal = @import("../services/tv_calendar.zig");
    if (cal.count == 0) return false;
    const text_mod = @import("../core/text.zig");
    const poster = @import("../core/poster.zig");
    const poster_h = card_w * 1.5;

    // Section header (icon + title) — same grammar as posterStrip's.
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.sm, .w = theme.spacing.xs, .h = theme.spacing.xs },
        });
        defer hdr.deinit();
        dvui.icon(@src(), "comingup", icons.tvg.lucide.@"calendar-clock", .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = theme.iconSize(.sm),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "Coming up", .{}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
        });
    }

    var strip = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none, .horizontal_bar = .hide }, .{
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .w = 10, .h = poster_h + STRIP_CHROME },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = poster_h + STRIP_CHROME },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer strip.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    defer row.deinit();

    const now_s = @import("../core/io_global.zig").timestamp();
    const n = @min(cal.count, STRIP_MAX);
    for (0..n) |i| {
        const e = &cal.entries[i];
        var it = &cal.cal_items[i];

        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i + 47000,
            .min_size_content = .{ .w = card_w, .h = poster_h + STRIP_CHROME },
            .max_size_content = .{ .w = card_w, .h = poster_h + STRIP_CHROME },
            .margin = dvui.Rect.all(4),
        });
        defer card.deinit();

        // Poster — clickable; fetched through the shared poster daemon.
        {
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{}, .{
                .id_extra = i + 47100,
                .background = true,
                .color_fill = theme.colors.bg_surface,
                .corner_radius = dvui.Rect.all(8),
                .min_size_content = .{ .w = card_w, .h = poster_h },
                .max_size_content = .{ .w = card_w, .h = poster_h },
                .padding = dvui.Rect.all(0),
            });
            bw.processEvents();
            bw.drawBackground();
            if (bw.clicked()) {
                @import("../services/tmdb.zig").openTvDetailById(e.tmdb_id, e.name[0..e.name_len], e.poster_path[0..e.poster_path_len]);
            }
            if (poster.uploadIfReady(&it.poster_pixels, it.poster_w, it.poster_h, &it.poster_tex)) {
                if (it.poster_tex) |*tex| {
                    _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                        .id_extra = i + 47200,
                        .expand = .both,
                        .corner_radius = dvui.Rect.all(8),
                    });
                }
            } else {
                // Failure-latch (mirrors the TMDB grid): the old code gated on
                // !poster_failed but never SET it, so a dead poster re-spawned a
                // fetch every frame. Run the full attempted->failed transition.
                if (it.poster_fetching) {
                    it.poster_attempted = true;
                } else if (it.poster_attempted and it.poster_pixels == null and it.poster_tex == null) {
                    it.poster_failed = true;
                } else if (!it.poster_failed and it.poster_pixels == null and it.poster_path_len > 0) {
                    @import("../services/tmdb_api.zig").fetchPoster(it);
                    if (it.poster_fetching) it.poster_attempted = true;
                }
            }
            bw.deinit();
        }

        // Show name.
        var nm_buf: [96]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(e.name[0..@min(e.name_len, 60)], &nm_buf)}, .{
            .id_extra = i + 47300,
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
        });

        // Status caption: EZTV availability (green) or air-date countdown.
        var line_buf: [128]u8 = undefined;
        var cd_buf: [24]u8 = undefined;
        const pure = @import("../services/tv_calendar_pure.zig");
        const line: []const u8 = if (e.available)
            (std.fmt.bufPrint(&line_buf, "S{d:0>2}E{d:0>2} · {d} seeds", .{ @as(u32, @intCast(@max(0, e.last_season))), @as(u32, @intCast(@max(0, e.last_episode))), e.seeds }) catch "available")
        else if (e.next_season > 0)
            (std.fmt.bufPrint(&line_buf, "S{d:0>2}E{d:0>2} {s}", .{ @as(u32, @intCast(@max(0, e.next_season))), @as(u32, @intCast(@max(0, e.next_episode))), pure.countdownLabel(now_s, e.next_air_epoch, &cd_buf) }) catch "soon")
        else
            (std.fmt.bufPrint(&line_buf, "S{d:0>2}E{d:0>2} unwatched", .{ @as(u32, @intCast(@max(0, e.last_season))), @as(u32, @intCast(@max(0, e.last_episode))) }) catch "unwatched");
        _ = dvui.label(@src(), "{s}", .{line}, .{
            .id_extra = i + 47400,
            .color_text = if (e.available) theme.colors.success else theme.colors.text_tertiary,
            .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
        });
    }
    return true;
}

fn renderTrendingRail(card_w: f32) bool {
    const t = &state.app.tmdb;
    if (t.api_key_len == 0) return false;
    if (t.view != .Trending or t.genre_idx != 0) return false;
    if (t.results.items.len == 0) return false;

    posterStrip("Trending tonight", icons.tvg.lucide.flame, &t.results, .Trending, 4, card_w);
    return true;
}

// ── Hero (idle console) — greeting + big prompt + suggestion chips ──

fn renderHero() void {
    const home_pure = @import("home_pure.zig");

    // App-shell hero: compact enough that the rails below stay on-screen.
    // windowRect() is logical units (same space as layout).
    const win_h = dvui.windowRect().h;
    const tall = win_h >= 980;
    // Breathing room below the top nav before the greeting. Generous (the user
    // wants clear separation) but capped so the Trending rail below stays near
    // the fold rather than being pushed off-screen.
    const top_pad = std.math.clamp(win_h * 0.08, 64.0, 150.0);

    var hero = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.lg, .y = top_pad, .w = theme.spacing.lg, .h = 0 },
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

    // Headline — big when there's room, ramp-display when the shell is tight.
    _ = dvui.label(@src(), "{s}", .{home_pure.headlineForHour(hour)}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_title.withSize(if (tall) 26 else 21),
        .gravity_x = 0.5,
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
    });
    if (tall) {
        _ = dvui.label(@src(), "Ask for a mood, a title, or paste any link — Opal finds it, plays it, and learns your taste.", .{}, .{
            .color_text = theme.colors.text_tertiary,
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.sm },
        });
    }

    // The big prompt — same unified input the header uses (media plays,
    // questions go to the AI, everything else fans out to search). The pill
    // sizes and centers itself (fixed 480-620 width, gravity 0.5).
    @import("header.zig").renderUrlInput(true);

    // Suggestion chips — conversation starters that submit straight to the AI.
    {
        var wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
        });
        defer wrap.deinit();
        const avail = wrap.data().rect.w;
        const chips_w: f32 = if (avail > 1) @min(800.0, avail) else 800.0;
        var chips = dvui.flexbox(@src(), .{ .justify_content = .center }, .{
            .gravity_x = 0.5,
            .min_size_content = .{ .w = chips_w, .h = 0 },
            .max_size_content = dvui.Options.MaxSize.width(chips_w),
        });
        defer chips.deinit();

        const starters = [_]struct { icon: []const u8, label: []const u8, prompt: []const u8 }{
            .{ .icon = icons.tvg.lucide.@"wand-sparkles", .label = "Movie for tonight", .prompt = "Recommend a movie for tonight" },
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
}

/// Three quiet value-prop tiles — the agent pitch. Shown only when the hub
/// has no content yet (informational, no hover/click: landing copy, not chrome).
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

/// Claude-style history sidebar: New chat on top, then past conversations
/// (titled by their first user message), current one highlighted. Clicking a
/// session restores its transcript and continues it.
fn renderChatSidebar() void {
    const ai_chat = @import("../services/ai_chat.zig");
    const home_pure = @import("home_pure.zig");
    ai_chat.loadSessions();

    var sb = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
        .min_size_content = .{ .w = 236, .h = 0 },
        .max_size_content = dvui.Options.MaxSize.width(236),
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 1, .h = 0 },
        .padding = dvui.Rect.all(theme.spacing.sm),
    });
    defer sb.deinit();

    // New chat — wipes the live transcript (history stays), lands on the hero.
    {
        var nc = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
        });
        defer nc.deinit();
        var nc_hover = false;
        const nc_clicked = dvui.clicked(nc.data(), .{ .hovered = &nc_hover });
        if (nc_hover) nc.data().options.color_fill = theme.colors.bg_hover;
        nc.drawBackground();
        dvui.icon(@src(), "new-chat", icons.tvg.lucide.@"square-pen", .{}, .{
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "New chat", .{}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
        });
        if (nc_clicked) {
            ai_chat.newChat();
            chat_last_sig = 0;
            return; // message_count is 0 now — the page flips to the hero
        }
    }

    _ = dvui.label(@src(), "Recents", .{}, .{
        .color_text = theme.colors.text_tertiary,
        .margin = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.xs },
    });

    // Explicit height (sidebar minus New-chat/Recents/bottom-rail chrome) —
    // same reasoning as the composer: expand-clamping must not push the
    // bottom rail out of view when the session list grows.
    const sb_h = sb.data().rect.h;
    const list_h: f32 = if (sb_h > 1) @max(80, sb_h - 128) else 400;
    var list = dvui.scrollArea(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 10, .h = list_h },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = list_h },
        .background = false,
    });
    var list_closed = false;
    defer if (!list_closed) list.deinit();

    const cur_sid = ai_chat.session_id[0..ai_chat.session_id_len];
    var clicked_session: ?usize = null;

    for (ai_chat.sessions[0..ai_chat.session_count], 0..) |*s, si| {
        const is_current = s.sid_len > 0 and std.mem.eql(u8, s.sid[0..s.sid_len], cur_sid);
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = si + 88000,
            .expand = .horizontal,
            .background = true,
            .color_fill = if (is_current) theme.colors.bg_hover else transparent,
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        });
        defer row.deinit();
        var hov = false;
        if (dvui.clicked(row.data(), .{ .hovered = &hov })) clicked_session = si;
        if (hov and !is_current) row.data().options.color_fill = theme.colors.bg_hover;
        row.drawBackground();

        // Title = first user message, clipped on a UTF-8 boundary; validate
        // (DB content is external input) before dvui measures it.
        var clip_buf: [64]u8 = undefined;
        const clipped = if (s.title_len > 0)
            home_pure.clipLabel(&clip_buf, s.title[0..s.title_len], 46)
        else
            "Untitled chat";
        var safe_buf: [72]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(clipped, &safe_buf)}, .{
            .id_extra = si + 88000,
            .expand = .horizontal,
            .color_text = if (is_current) theme.colors.text_primary else theme.colors.text_secondary,
            .gravity_y = 0.5,
        });
    }

    if (ai_chat.session_count == 0) {
        _ = dvui.label(@src(), "No past chats yet", .{}, .{
            .color_text = theme.colors.text_tertiary,
            .padding = dvui.Rect.all(theme.spacing.sm),
        });
    }

    // Restore AFTER the loop — loadSession rewrites the live transcript.
    if (clicked_session) |si| {
        const s = &ai_chat.sessions[si];
        ai_chat.loadSession(s.sid[0..s.sid_len]);
        chat_last_sig = 0; // re-pin the follow-scroll to the loaded bottom
    }

    list.deinit();
    list_closed = true;

    // Bottom rail: incognito hint (left) + hide-sidebar control (right) —
    // the collapse affordance lives on the thing it collapses.
    {
        var foot = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = 0, .h = 0 },
        });
        defer foot.deinit();
        if (state.app.incognito_mode) {
            dvui.icon(@src(), "sb-incog", icons.tvg.lucide.@"eye-off", .{}, .{
                .color_text = theme.colors.warning,
                .min_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
            });
        }
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        var hide_wd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), "hide-sidebar", icons.tvg.lucide.@"panel-left-close", .{}, .{}, .{
            .data_out = &hide_wd,
            .color_text = theme.colors.text_tertiary,
            .color_fill = theme.transparent,
            .color_fill_hover = theme.colors.bg_hover,
            .border = dvui.Rect.all(0),
            .corner_radius = theme.dims.rad_sm,
            .padding = dvui.Rect.all(theme.spacing.xs),
            .min_size_content = theme.iconSize(.sm),
        })) {
            chat_sidebar_open = false;
        }
        @import("components.zig").tip(@src(), hide_wd, "Hide chat list");
    }
}

fn renderChatMode() void {
    const ai_chat = @import("../services/ai_chat.zig");
    const grid = @import("grid.zig");

    // Claude-style shell: history sidebar on the left (collapsible; auto-
    // hidden on narrow windows), transcript + composer in the main column.
    var page = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer page.deinit();

    const win_w = dvui.windowRect().w;
    if (chat_sidebar_open and win_w >= 880) renderChatSidebar();

    var main = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer main.deinit();

    // Transcript — the page scroll, centered reading column.
    // NOTE: dvui `expand` IGNORES max_size_content (expansion always fills the
    // parent rect), so `.expand + .max_size_content` was a full-window column —
    // user bubbles glued to the right window edge. Compute a FIXED column
    // width instead: min(760, available), one-frame lag on first paint.
    //
    // PINNED COMPOSER: the transcript viewport gets an EXPLICIT height —
    // main minus the composer's measured height (previous frame, MeasuredH
    // pattern). Relying on `.expand = .both` to clamp the scroll inside the
    // column let the composer slide below the fold once the conversation
    // outgrew the window.
    const Measured = struct {
        var composer_h: f32 = 96;
    };
    const main_h = main.data().rect.h;
    const scroll_h: f32 = if (main_h > 1) @max(120, main_h - Measured.composer_h) else 480;
    {
        var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &chat_si }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 10, .h = scroll_h },
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = scroll_h },
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

    // Follow the conversation: when the transcript grows (new message, new
    // streamed bytes, inline results landing, catalog posters arriving), pin
    // the scroll to the bottom — content used to grow AFTER the message and
    // slip below the fold. Manual scrolling back is untouched between events.
    {
        var sig: u64 = ai_chat.message_count;
        if (ai_chat.message_count > 0) {
            sig = sig *% 1000003 +% ai_chat.messages[ai_chat.message_count - 1].text_len;
        }
        sig = sig *% 1000003 +% ai_chat.chat_result_count;
        if (ai_chat.catalog_rail_active) {
            sig = sig *% 1000003 +% state.app.tmdb.results.items.len;
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
        if (dvui.minSizeGet(bar.data().id)) |ms| Measured.composer_h = ms.h;

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

            // Reopen-sidebar affordance — only while the rail is hidden;
            // the "hide" control lives at the sidebar's own bottom-right.
            if (!chat_sidebar_open) {
                var sb_wd: dvui.WidgetData = undefined;
                if (dvui.buttonIcon(@src(), "chat-sidebar", icons.tvg.lucide.@"panel-left", .{}, .{}, .{
                    .data_out = &sb_wd,
                    .color_text = theme.colors.text_tertiary,
                    .color_fill = theme.transparent,
                    .color_fill_hover = theme.colors.bg_hover,
                    .border = dvui.Rect.all(0),
                    .corner_radius = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.xs, .y = 2, .w = theme.spacing.xs, .h = 2 },
                    .min_size_content = theme.iconSize(.xs),
                    .gravity_y = 0.5,
                    .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
                })) {
                    chat_sidebar_open = true;
                }
                @import("components.zig").tip(@src(), sb_wd, "Show chat history");
            }

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
                    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .background = true,
                        .color_fill = theme.colors.bg_surface,
                        .border = dvui.Rect.all(1),
                        .color_border = theme.colors.border_subtle,
                        .corner_radius = dvui.Rect.all(theme.radius.pill),
                        .padding = .{ .x = theme.spacing.sm, .y = 1, .w = theme.spacing.sm, .h = 1 },
                        .gravity_y = 0.5,
                    });
                    defer chip.deinit();
                    dvui.icon(@src(), "seeing", icons.tvg.lucide.tv, .{}, .{
                        .color_text = theme.colors.accent,
                        .min_size_content = .{ .w = 11, .h = 11 },
                        .gravity_y = 0.5,
                        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
                    });
                    var clip_buf2: [40]u8 = undefined;
                    const short = @import("home_pure.zig").clipLabel(&clip_buf2, media_label, 28);
                    _ = dvui.label(@src(), "{s}", .{short}, .{
                        .color_text = theme.colors.text_secondary,
                        .gravity_y = 0.5,
                        .padding = dvui.Rect.all(0),
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

fn posterStrip(title: []const u8, icon: []const u8, items: *std.ArrayListUnmanaged(state.TmdbItem), view: state.TmdbView, id: usize, card_w: f32) void {
    sectionHeader(title, icon, view, id);

    const poster_h = card_w * 1.5;
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none }, .{
        .id_extra = id,
        .expand = .horizontal,
        // Transparent — dvui's default scroll fill is light; show the dark page.
        .background = false,
        .min_size_content = .{ .w = 10, .h = poster_h + STRIP_CHROME },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = poster_h + STRIP_CHROME },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer scroll.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id });
    defer row.deinit();

    const n = @min(items.items.len, STRIP_MAX);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        tmdb.renderPosterCard(&items.items[i], i, card_w, poster_h);
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

/// True when a history entry's media still exists AND can actually be
/// resumed: local files are stat'd (deleted downloads/library files must not
/// resurface as resume cards); a blank link can never be resumed at all (the
/// click handler below only fires `resumePlayback` when `link_len > 0`), so
/// those are filtered out too rather than shown as dead, do-nothing cards;
/// remaining non-local links (magnets, http, jellyfin) can't be checked and
/// pass. Results are cached and re-verified every few seconds or when
/// history changes — stat'ing every entry every frame would be syscall noise.
fn playableHistory() []const bool {
    const io_g = @import("../core/io_global.zig");
    const home_pure = @import("home_pure.zig");
    const S = struct {
        var ok: [wh.MAX_WATCH_HISTORY]bool = undefined;
        var last_ts: i64 = 0;
        var last_count: usize = 0;
    };
    const now = io_g.timestamp();
    if (wh.count != S.last_count or now - S.last_ts >= 5) {
        S.last_count = wh.count;
        S.last_ts = now;
        for (0..wh.count) |i| {
            const e = &wh.entries[i];
            const link = e.link[0..e.link_len];
            S.ok[i] = if (!home_pure.hasResumableLink(link))
                false
            else if (home_pure.localFsPath(link)) |fs_path| blk: {
                _ = io_g.cwdStatFile(fs_path) catch break :blk false;
                break :blk true;
            } else true;
        }
    }
    return S.ok[0..wh.count];
}

fn renderRecentlyPlayed() void {
    if (wh.count == 0) return;
    const home_pure = @import("home_pure.zig");
    const playable = playableHistory();
    // Everything deleted → no section at all (header with zero cards reads broken).
    const any_playable = for (playable) |p| {
        if (p) break true;
    } else false;
    if (!any_playable) return;

    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.xs, .w = theme.spacing.xs, .h = 2 },
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

    var shown: usize = 0;
    var i: usize = 0;
    while (i < wh.count and shown < 12) : (i += 1) {
        if (!playable[i]) continue; // media deleted from disk — no dead resume card
        shown += 1;
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
