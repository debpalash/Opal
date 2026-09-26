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
const browser = @import("../services/browser.zig");
const library_store = @import("../services/library_store.zig");
const library_pure = @import("../services/library_pure.zig");
const components = @import("components.zig");
const db = @import("../core/db.zig");
const io_global = @import("../core/io_global.zig");

const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

const STRIP_MAX: usize = 24; // cap cards per strip (perf)
const STRIP_CHROME: f32 = 78; // compact title/status/tools below each poster
const SCROLLBAR_HOLD_NS: i128 = 900 * std.time.ns_per_ms;

// Scrollbars are useful feedback while content is moving, but permanent rails
// waste space and visually split the shelves. Each scroll area owns a small
// visibility slot; a DVUI timer wakes the UI once so the overlay can disappear
// even when playback is paused and the app is otherwise idle.
var scrollbar_visible_until: [16]i128 = @splat(0);

fn scrollbarMode(slot: usize) dvui.ScrollInfo.ScrollBarMode {
    return if (dvui.frameTimeNS() < scrollbar_visible_until[slot]) .auto_overlay else .hide;
}

fn noteUserScroll(slot: usize, delta: dvui.Point, id: dvui.Id) void {
    if (@abs(delta.x) < 0.01 and @abs(delta.y) < 0.01) return;
    scrollbar_visible_until[slot] = dvui.frameTimeNS() + SCROLLBAR_HOLD_NS;
    dvui.timer(id, 900_000);
}

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

    var user_scroll: dvui.Point = .{};
    var scroll = dvui.scrollArea(@src(), .{
        .vertical_bar = scrollbarMode(0),
        .user_scroll = &user_scroll,
    }, .{
        .expand = .both,
        .background = false,
    });
    const scroll_id = scroll.data().id;
    defer {
        scroll.deinit();
        noteUserScroll(0, user_scroll, scroll_id);
    }

    const live_w = @import("../core/scale_pure.zig").layoutUnits(dvui.windowRect().w, state.app.ui_scale);
    const live_h = @import("../core/scale_pure.zig").layoutUnits(dvui.windowRect().h, state.app.ui_scale);
    const page_pad: f32 = if (live_w < 600) 10 else if (live_w < 1100) 20 else 34;
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = page_pad, .y = 0, .w = page_pad, .h = theme.spacing.xl },
    });
    defer col.deinit();

    // Generate taste recommendations once per session (DB + vec0 KNN). Wait
    // for the async history load — generating on the very first frame raced
    // it and permanently produced an empty rail.
    {
        const recs = @import("../services/recommendations.zig");
        const Once = struct {
            var done: bool = false;
        };
        // Gated on "Personalized suggestions (local-only)": OFF means no
        // recording and no For You row — don't even generate. (Turning it
        // ON later this session arms the generation then.)
        if (state.app.taste_enabled and !Once.done and state.app.init_history_loaded) {
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

    renderHero();

    // Cinema-shelf sizing: broad screens show larger artwork and more cards;
    // compact screens keep three useful cards in view. The page scroll owns
    // vertical overflow, so every populated shelf remains available.
    const width_card: f32 = if (live_w < 600)
        std.math.clamp((live_w - page_pad * 2) / 3.25, 92.0, 116.0)
    else
        std.math.clamp(live_w / 11.0, 118.0, 176.0);
    const height_cap: f32 = if (live_h < 680) 94 else if (live_h < 840) 106 else if (live_h < 1080) 124 else 150;
    const card_w = @max(92.0, @min(width_card, height_cap));

    // One cross-media Continue rail: films, files, podcasts, audiobooks,
    // comics, novels and anime all enter through the same read model.
    // One cross-media resume shelf. Video, series, anime, podcasts, books,
    // comics and novels all use the unified library read model, so Home never
    // repeats the same intent across several "Continue" rows.
    const has_continue = renderLibraryContinueRail(card_w);
    _ = renderTrendingRail(card_w);
    // "Coming up" — poster cards (like Trending) with next-episode countdowns
    // + EZTV availability for the shows the user watches.
    _ = renderComingUpRail(card_w);
    if (state.app.taste_enabled and @import("../services/recommendations.zig").rec_count > 0) {
        @import("discovery_ui.zig").renderForYouRail();
    }
    if (watchlist.items.len > 0) {
        posterStrip("Watchlist", icons.tvg.lucide.bookmark, watchlist, .Watchlist, 2, card_w);
    }
    if (favorites.items.len > 0) {
        posterStrip("Favorites", icons.tvg.lucide.star, favorites, .Favorites, 3, card_w);
    }
    // Cross-vertical favorites (IPTV/music/…) from the unified library_items.
    _ = renderLibraryRail(card_w);

    // No saved media or history and no TMDB rail to populate the hub yet.
    const everything_empty = !has_continue and watchlist.items.len == 0 and
        favorites.items.len == 0 and watching.items.len == 0;
    if (everything_empty and state.app.tmdb.api_key_len == 0) renderEmptyState();
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
            .min_size_content = theme.iconSize(.md),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "Coming up", .{}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading.withSize(17),
            .gravity_y = 0.5,
        });
    }

    var user_scroll: dvui.Point = .{};
    var strip = dvui.scrollArea(@src(), .{
        .horizontal = .auto,
        .vertical = .none,
        .horizontal_bar = scrollbarMode(1),
        .user_scroll = &user_scroll,
    }, .{
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .w = 10, .h = poster_h + STRIP_CHROME },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = poster_h + STRIP_CHROME },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    const scroll_id = strip.data().id;
    defer {
        strip.deinit();
        noteUserScroll(1, user_scroll, scroll_id);
    }
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
            .background = true,
            .color_fill = transparent,
            .color_fill_hover = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(theme.radius.lg),
            .padding = dvui.Rect.all(5),
            .margin = dvui.Rect.all(6),
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
            _ = poster.uploadIfReady(&it.poster_pixels, it.poster_w, it.poster_h, &it.poster_tex);
            if (it.poster_tex) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = i + 47200,
                    .expand = .both,
                    .corner_radius = dvui.Rect.all(8),
                });
            } else {
                // Failure-latch (mirrors the TMDB grid): the old code gated on
                // !poster_failed but never SET it, so a dead poster re-spawned a
                // fetch every frame. Run the full attempted->failed transition.
                if (it.poster_fetching) {
                    it.poster_attempted = true;
                } else if (it.poster_attempted and it.poster_pixels == null and it.poster_tex == null) {
                    it.poster_failed = true;
                } else if (!it.poster_failed and it.poster_pixels == null and it.poster_path_len > 0) {
                    const path = it.poster_path[0..it.poster_path_len];
                    var url_buf: [512]u8 = undefined;
                    const url = if (std.mem.startsWith(u8, path, "https://") or std.mem.startsWith(u8, path, "http://"))
                        path
                    else
                        std.fmt.bufPrint(&url_buf, "https://image.tmdb.org/t/p/w342{s}", .{path}) catch "";
                    if (url.len > 0)
                        poster.fetchAsync(url, &it.poster_pixels, &it.poster_w, &it.poster_h, &it.poster_fetching);
                    if (it.poster_fetching) it.poster_attempted = true;
                }
                if (!it.poster_failed and it.poster_path_len > 0)
                    components.coverSkeleton(@src(), i + 47200, 8);
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

// ── Hero (idle console) — prompt and direct discovery actions ──

fn renderHero() void {
    const win_w = @import("../core/scale_pure.zig").layoutUnits(dvui.windowRect().w, state.app.ui_scale);
    const compact = win_w < 650;

    // Wide, left-anchored opening like a streaming home screen. The shelves
    // start close below it so content remains visible at every window height.
    const win_h = dvui.windowRect().h;
    const tall = win_h >= 980 and !compact;
    const top_pad = if (compact) theme.spacing.sm else std.math.clamp(win_h * 0.02, 10.0, 24.0);

    var hero = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.xs, .y = top_pad, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    defer hero.deinit();

    var header_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer header_row.deinit();

    _ = dvui.label(@src(), "Home", .{}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_title.withSize(if (tall) 30 else if (compact) 23 else 27),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });

    if (heroAction("Search", 1)) state.app.router.navigate(.search);
    if (heroAction("Browse", 2)) {
        state.app.browse_source = .TMDB;
        state.app.router.navigate(.browse);
    }

    var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
    spacer.deinit();

    const clock = localClock();
    _ = dvui.label(@src(), "{s}", .{clock.greeting}, .{
        .color_text = theme.colors.text_secondary,
        .font = dvui.themeGet().font_body.withSize(if (compact) theme.font_size.small else theme.font_size.body),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{clock.time}, .{
        .color_text = theme.colors.accent,
        .font = dvui.themeGet().font_heading.withSize(if (compact) theme.font_size.small else 12),
        .gravity_y = 0.5,
    });
    // Wake an otherwise idle window so the minute remains current.
    dvui.timer(header_row.data().id, 60_000_000);

    // The shell provides the unified omnibox in its header; only the
    // standalone layout renders a second input here.
    if (!state.app.page_shell_enabled) @import("header.zig").renderUrlInput(true);
}

fn heroAction(label: []const u8, id: usize) bool {
    return dvui.button(@src(), label, .{}, .{
        .id_extra = id,
        .background = true,
        .color_fill = transparent,
        .color_fill_hover = theme.colors.bg_hover,
        .color_text = theme.colors.text_secondary,
        .font = dvui.themeGet().font_heading.withSize(12),
        .border = dvui.Rect.all(0),
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
        .gravity_y = 0.5,
    });
}

const ClockText = struct { greeting: []const u8, time: []const u8 };
var clock_minute: i64 = -1;
var clock_hour: u8 = 12;
var clock_text: [5]u8 = "00:00".*;

fn localClock() ClockText {
    const minute = @divFloor(io_global.timestamp(), 60);
    if (minute != clock_minute) {
        const stmt = db.prepare("SELECT strftime('%H:%M','now','localtime'), CAST(strftime('%H','now','localtime') AS INTEGER)");
        if (stmt) |s| {
            defer db.finalize(s);
            if (db.step(s) == db.c.SQLITE_ROW) {
                if (db.columnText(s, 0)) |value| {
                    if (value.len == clock_text.len) @memcpy(&clock_text, value);
                }
                clock_hour = @intCast(std.math.clamp(db.columnInt(s, 1), 0, 23));
                clock_minute = minute;
            }
        }
    }
    const greeting: []const u8 = if (clock_hour < 5)
        "Good night"
    else if (clock_hour < 12)
        "Good morning"
    else if (clock_hour < 17)
        "Good afternoon"
    else if (clock_hour < 22)
        "Good evening"
    else
        "Good night";
    return .{ .greeting = greeting, .time = &clock_text };
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

            // Live interim transcript — words stream in as you speak (the
            // realtime feel), greyed until the utterance is finalized. Only the
            // full-duplex event loop populates partial_text.
            if (voice.partial_text_len > 0 and
                (voice.conv_phase == .listening or voice.conv_phase == .transcribing))
            {
                const partial = voice.partial_text[0..@min(voice.partial_text_len, voice.partial_text.len)];
                _ = dvui.label(@src(), "  \"{s}\"", .{partial}, .{
                    .color_text = theme.colors.text_tertiary,
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
    const scrollbar_slot: usize = switch (view) {
        .Watching => 2,
        .Trending => 3,
        .Watchlist => 4,
        .Favorites => 5,
        else => 3,
    };
    var user_scroll: dvui.Point = .{};
    var scroll = dvui.scrollArea(@src(), .{
        .horizontal = .auto,
        .vertical = .none,
        .horizontal_bar = scrollbarMode(scrollbar_slot),
        .user_scroll = &user_scroll,
    }, .{
        .id_extra = id,
        .expand = .horizontal,
        // Transparent — dvui's default scroll fill is light; show the dark page.
        .background = false,
        .min_size_content = .{ .w = 10, .h = poster_h + STRIP_CHROME },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = poster_h + STRIP_CHROME },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    const scroll_id = scroll.data().id;
    defer {
        scroll.deinit();
        noteUserScroll(scrollbar_slot, user_scroll, scroll_id);
    }

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id });
    defer row.deinit();

    const n = @min(items.items.len, STRIP_MAX);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        tmdb.renderPosterCard(&items.items[i], i, card_w, poster_h);
    }
}

// ── Your Library rail (cross-vertical favorites from library_items) ──
const LibSlot = struct {
    pixels: ?[]u8 = null,
    tex: ?dvui.Texture = null,
    blur_tex: ?dvui.Texture = null,
    w: u32 = 0,
    h: u32 = 0,
    fetching: bool = false,
    url_hash: u64 = 0,
};
var lib_slots: [24]LibSlot = [_]LibSlot{.{}} ** 24;
var continue_slots: [24]LibSlot = [_]LibSlot{.{}} ** 24;

/// Route a library row by its `kind`. Every kind a producer writes must land
/// here — a row that can't be reopened is worse than no row:
///   iptv / audiobook → play the stream URL directly (with title/poster meta)
///   anime            → deep_link is the MAL id; jump to the show's detail view
///   novels           → deep_link is `novel|<source>|<url>|<title>`; reopen it
///   comics           → `comic|<url>|<title>`; reopen AND jump to the read page
///   podcast          → `podcast|<url>|<art>|<show>|<title>`; replay + mpv seeks
///   everything else  → browser.resumePlayback (files, magnets, http)
fn openLibItem(item: *const library_pure.LibraryItem) void {
    const link = item.deep_link[0..@min(item.deep_link_len, item.deep_link.len)];
    if (link.len == 0) return;
    const kind = item.kind[0..@min(item.kind_len, item.kind.len)];
    const title = item.title[0..@min(item.title_len, item.title.len)];
    switch (library_pure.parseKind(kind)) {
        .iptv, .radio, .music => browser.loadContentDirectMeta(link, item.poster[0..@min(item.poster_len, item.poster.len)], title, ""),
        .audiobook => @import("../services/audiobookshelf.zig").playBookById(link, title, ""),
        .anime => {
            @import("../services/anime.zig").jumpToAnime(link);
            state.app.browse_source = .Anime;
            state.app.router.navigate(.browse);
        },
        .novels => @import("../services/novels.zig").openDeepLink(link),
        .comics => @import("../services/comics.zig").openDeepLink(link),
        .podcast => @import("../services/podcasts.zig").openDeepLink(link),
        else => browser.resumePlayback(link),
    }
}

/// Returns true if the rail rendered (has favorites). Cross-vertical — surfaces
/// IPTV/music/etc. favorites the TMDB rails can't.
fn renderLibraryContinueRail(card_w: f32) bool {
    var items: [24]library_pure.LibraryItem = undefined;
    const n = library_store.loadContinue(items[0..]);
    const hidden = library_store.hiddenContinueCount();
    return renderLibraryItemsRail(items[0..n], "Continue", icons.tvg.lucide.play, 7600, card_w, continue_slots[0..], hidden);
}

fn renderLibraryRail(card_w: f32) bool {
    var items: [24]library_pure.LibraryItem = undefined;
    const n = library_store.loadFavorites(items[0..]);
    return renderLibraryItemsRail(items[0..n], "Your Library", icons.tvg.lucide.@"library-big", 7700, card_w, lib_slots[0..], 0);
}

fn renderLibraryItemsRail(items: []const library_pure.LibraryItem, heading: []const u8, heading_icon: []const u8, base_id: usize, card_w: f32, slots: []LibSlot, hidden_count: usize) bool {
    const n = @min(items.len, slots.len);
    const manage_continue = base_id == 7600;
    if (n == 0 and hidden_count == 0) return false;

    // Header (icon + label; no TMDB "See all").
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = base_id,
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.xs, .y = theme.spacing.sm, .w = theme.spacing.xs, .h = theme.spacing.xs },
        });
        defer hdr.deinit();
        dvui.icon(@src(), heading, heading_icon, .{}, .{
            .id_extra = base_id,
            .color_text = theme.colors.accent,
            .min_size_content = theme.iconSize(.md),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{heading}, .{
            .id_extra = base_id,
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading.withSize(17),
            .gravity_y = 0.5,
        });
        if (hidden_count > 0) {
            var spacer = dvui.box(@src(), .{}, .{ .id_extra = base_id + 3, .expand = .horizontal });
            spacer.deinit();
            var restore_buf: [40]u8 = undefined;
            const restore_label = std.fmt.bufPrint(&restore_buf, "Restore hidden · {d}", .{hidden_count}) catch "Restore hidden";
            if (dvui.button(@src(), restore_label, .{}, .{
                .id_extra = base_id + 4,
                .background = true,
                .color_fill = transparent,
                .color_fill_hover = theme.colors.bg_hover,
                .color_text = theme.colors.text_secondary,
                .border = dvui.Rect.all(0),
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .gravity_y = 0.5,
            })) {
                library_store.restoreHiddenContinue();
                dvui.refresh(null, @src(), null);
            }
        }
    }

    if (n == 0) return true;

    const poster_h = card_w * 1.5;
    const scrollbar_slot: usize = if (base_id == 7600) 6 else 7;
    var user_scroll: dvui.Point = .{};
    var scroll = dvui.scrollArea(@src(), .{
        .horizontal = .auto,
        .vertical = .none,
        .horizontal_bar = scrollbarMode(scrollbar_slot),
        .user_scroll = &user_scroll,
    }, .{
        .id_extra = base_id + 1,
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .w = 10, .h = poster_h + STRIP_CHROME },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = poster_h + STRIP_CHROME },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = theme.spacing.xs },
    });
    const scroll_id = scroll.data().id;
    defer {
        scroll.deinit();
        noteUserScroll(scrollbar_slot, user_scroll, scroll_id);
    }
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = base_id + 1 });
    defer row.deinit();

    const poster = @import("../core/poster.zig");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = &items[i];
        const card_chrome: f32 = if (manage_continue) 66 else 38;
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i + base_id + 10,
            .min_size_content = .{ .w = card_w, .h = poster_h + card_chrome },
            .max_size_content = .{ .w = card_w, .h = poster_h + card_chrome },
            .background = true,
            .color_fill = transparent,
            .color_fill_hover = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(theme.radius.lg),
            .padding = dvui.Rect.all(5),
            .margin = dvui.Rect.all(6),
        });
        defer card.deinit();
        const hovered = card.data().borderRectScale().r.contains(dvui.currentWindow().mouse_pt);
        const revealed = !manage_continue or hovered;

        if (manage_continue) {
            var tools = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i + base_id + 20,
                .min_size_content = .{ .w = card_w, .h = 28 },
                .max_size_content = .{ .w = card_w, .h = 28 },
                .gravity_y = 0.5,
            });
            defer tools.deinit();
            const kind = library_pure.parseKind(item.kind[0..@min(item.kind_len, item.kind.len)]);
            const kind_label: []const u8 = switch (kind) {
                .watch, .movie, .tv => "Watch",
                .anime => "Anime",
                .podcast => "Podcast",
                .audiobook => "Audiobook",
                .music, .radio => "Listen",
                .comics => "Comic",
                .novels => "Read",
                .iptv => "Live",
                .other => "Continue",
            };
            _ = dvui.label(@src(), "{s}", .{if (revealed) kind_label else "Private"}, .{
                .id_extra = i + base_id + 21,
                .color_text = if (item.home_pinned) theme.colors.accent else theme.colors.text_tertiary,
                .font = dvui.themeGet().font_heading.withSize(theme.font_size.small),
                .gravity_y = 0.5,
            });
            var spacer = dvui.box(@src(), .{}, .{ .id_extra = i + base_id + 22, .expand = .horizontal });
            spacer.deinit();
            if (components.iconButton(@src(), if (item.home_pinned) icons.tvg.lucide.@"pin-off" else icons.tvg.lucide.pin, if (item.home_pinned) "Unpin from front" else "Pin to front", item.home_pinned)) {
                library_store.setHomePinned(item.kind[0..item.kind_len], item.item_id[0..item.item_id_len], !item.home_pinned);
                dvui.refresh(null, @src(), null);
            }
            // Always available, including while the private card is masked.
            // This hides only the Home column and preserves resume progress.
            if (components.iconButton(@src(), icons.tvg.lucide.@"trash-2", "Remove from Home · keeps progress", false)) {
                library_store.setHomeHidden(item.kind[0..item.kind_len], item.item_id[0..item.item_id_len], true);
                dvui.refresh(null, @src(), null);
                continue;
            }
        }

        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = i + base_id + 30,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .corner_radius = dvui.Rect.all(theme.radius.lg),
            .min_size_content = .{ .w = card_w, .h = poster_h },
            .max_size_content = .{ .w = card_w, .h = poster_h },
        });
        bw.processEvents();
        bw.drawBackground();

        const slot = &slots[i];
        const purl = item.poster[0..@min(item.poster_len, item.poster.len)];
        if (purl.len > 0) {
            const h = std.hash.Fnv1a_64.hash(purl);
            if (slot.url_hash != h and !slot.fetching) {
                poster.deinitPoster(&slot.pixels, &slot.tex);
                if (slot.blur_tex) |tex| dvui.textureDestroyLater(tex);
                slot.blur_tex = null;
                slot.w = 0;
                slot.h = 0;
                slot.url_hash = h;
            }
            if (manage_continue) uploadPrivacyBlur(slot);
            _ = poster.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.tex);
            if (slot.tex == null and !slot.fetching and slot.pixels == null)
                poster.fetchAsync(purl, &slot.pixels, &slot.w, &slot.h, &slot.fetching);
        }
        if (revealed and slot.tex != null) {
            const tex = &slot.tex.?;
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{ .id_extra = i + base_id + 40, .expand = .both, .corner_radius = dvui.Rect.all(theme.radius.lg) });
        } else if (!revealed and slot.blur_tex != null) {
            _ = dvui.image(@src(), .{ .source = .{ .texture = slot.blur_tex.? } }, .{ .id_extra = i + base_id + 40, .expand = .both, .corner_radius = dvui.Rect.all(theme.radius.lg) });
        } else if (!revealed) {
            renderPrivateCoverPlaceholder(i + base_id + 40, heading_icon);
        } else {
            renderPrivateCoverPlaceholder(i + base_id + 40, heading_icon);
        }
        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (clicked) openLibItem(item);

        var t_safe: [200]u8 = undefined;
        const visible_title = @import("../core/text.zig").safeUtf8Buf(item.title[0..@min(item.title_len, item.title.len)], &t_safe);
        if (revealed) {
            _ = dvui.label(@src(), "{s}", .{visible_title}, .{
                .id_extra = i + base_id + 50,
                .color_text = theme.colors.text_primary,
                .font = dvui.themeGet().font_heading.withSize(theme.font_size.body),
                .min_size_content = .{ .w = card_w, .h = 18 },
                .max_size_content = .{ .w = card_w, .h = 18 },
                .padding = .{ .x = 1, .y = 4, .w = 1, .h = 0 },
            });
        } else {
            renderPrivateTitle(i + base_id + 50, card_w);
        }
        if (item.percent > 0) {
            var progress = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i + base_id + 60,
                .background = true,
                .color_fill = theme.colors.bg_elevated,
                .min_size_content = .{ .w = card_w, .h = 3 },
                .max_size_content = .{ .w = card_w, .h = 3 },
            });
            var fill = dvui.box(@src(), .{}, .{
                .id_extra = i + base_id + 70,
                .background = true,
                .color_fill = theme.colors.accent,
                .min_size_content = .{ .w = card_w * @as(f32, @floatCast(std.math.clamp(item.percent / 100, 0, 1))), .h = 3 },
                .max_size_content = .{ .w = card_w * @as(f32, @floatCast(std.math.clamp(item.percent / 100, 0, 1))), .h = 3 },
            });
            fill.deinit();
            progress.deinit();
        }
    }
    return true;
}

fn renderPrivateCoverPlaceholder(id: usize, glyph: []const u8) void {
    var backdrop = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
    });
    defer backdrop.deinit();
    _ = dvui.icon(@src(), "private-cover", glyph, .{}, .{
        .id_extra = id,
        .color_text = theme.colors.accent_dim,
        .min_size_content = theme.iconSize(.xl),
        .max_size_content = dvui.Options.MaxSize.size(theme.iconSize(.xl)),
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
}

fn renderPrivateTitle(id: usize, card_w: f32) void {
    var line = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .background = true,
        .color_fill = theme.colors.bg_hover,
        .corner_radius = dvui.Rect.all(theme.radius.pill),
        .min_size_content = .{ .w = card_w * 0.64, .h = 8 },
        .max_size_content = .{ .w = card_w * 0.64, .h = 8 },
        .margin = .{ .x = 1, .y = 8, .w = 0, .h = 2 },
    });
    line.deinit();
}

/// Make a deliberately tiny averaged copy and let linear scaling soften it.
/// This obscures identifying cover detail without retaining a second full-size
/// CPU image or doing per-frame filtering.
fn uploadPrivacyBlur(slot: *LibSlot) void {
    if (slot.blur_tex != null or slot.pixels == null or slot.w == 0 or slot.h == 0) return;
    const source = slot.pixels.?;
    const pixel_count: usize = @as(usize, slot.w) * @as(usize, slot.h);
    if (source.len != pixel_count * 4) return;

    const blur_w: usize = 8;
    const blur_h: usize = 12;
    var blurred: [blur_w * blur_h]dvui.Color.PMA = undefined;
    for (0..blur_h) |y| {
        const y0 = y * @as(usize, slot.h) / blur_h;
        const y1 = @max(y0 + 1, (y + 1) * @as(usize, slot.h) / blur_h);
        for (0..blur_w) |x| {
            const x0 = x * @as(usize, slot.w) / blur_w;
            const x1 = @max(x0 + 1, (x + 1) * @as(usize, slot.w) / blur_w);
            var sum = [4]u64{ 0, 0, 0, 0 };
            var count: u64 = 0;
            for (y0..@min(y1, slot.h)) |sy| {
                for (x0..@min(x1, slot.w)) |sx| {
                    const p = (sy * @as(usize, slot.w) + sx) * 4;
                    inline for (0..4) |channel| sum[channel] += source[p + channel];
                    count += 1;
                }
            }
            blurred[y * blur_w + x] = .{
                .r = @intCast(sum[0] / count),
                .g = @intCast(sum[1] / count),
                .b = @intCast(sum[2] / count),
                .a = @intCast(sum[3] / count),
            };
        }
    }
    slot.blur_tex = dvui.textureCreate(&blurred, blur_w, blur_h, .linear, .rgba_32) catch null;
}

fn sectionHeader(title: []const u8, icon: []const u8, view: state.TmdbView, id: usize) void {
    var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id + 6000,
        .expand = .horizontal,
        .padding = .{ .x = theme.spacing.xs, .y = 2, .w = theme.spacing.xs, .h = 2 },
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

// ── Empty state ──

fn renderEmptyState() void {
    // Normal flow block below the rails; never cover the actions above.
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .gravity_x = 0.5,
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.xl, .w = theme.spacing.lg, .h = theme.spacing.lg },
    });
    defer box.deinit();

    dvui.icon(@src(), "empty", icons.tvg.lucide.clapperboard, .{}, .{
        .color_text = theme.colors.accent_dim,
        .min_size_content = theme.iconSize(.hero),
        .gravity_x = 0.5,
    });
    _ = dvui.label(@src(), "Nothing here yet", .{}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_title,
        .gravity_x = 0.5,
    });
    _ = dvui.label(@src(), "Browse or search to start.", .{}, .{
        .color_text = theme.colors.text_secondary,
        .gravity_x = 0.5,
    });
}
