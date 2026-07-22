//! EZTV release calendar + live countdown — a self-contained section another
//! page (the "Watching" page) mounts with two calls:
//!
//!     eztv_calendar.refreshTick();    // every frame; cheap, self-throttling
//!     eztv_calendar.renderSection();  // every frame; draws nothing when inert
//!
//! NEUTRAL BY DEFAULT
//! ------------------
//! Nothing infringing is hardcoded here. Every URL comes from
//! `source_config.get("eztv", ...)`, i.e. from the eztv source plugin the user
//! chose to install. No plugin (or no such field) → this module fetches
//! nothing, draws nothing, and logs nothing. See core/source_config.zig.
//!
//! WHY THE JSON FEED, NOT THE /calendar/ + /countdown/ PAGES
//! --------------------------------------------------------
//! Those two HTML pages sit behind Cloudflare's JS-challenge interstitial — a
//! plain GET (with or without a browser User-Agent) returns 403 "Just a
//! moment...", never the schedule markup. A scraper for them could not be
//! verified against real bytes, so we don't ship one. The keyless get-torrents
//! JSON endpoint IS reachable and carries `date_released_unix` per release,
//! which is all the countdown needs. The `calendar` / `countdown` endpoints are
//! still declared by the plugin and used here for what they can actually do:
//! open the real pages in the user's browser, which can pass the challenge.
//!
//! LIVE, NOT ONCE-PER-SESSION
//! --------------------------
//! refreshTick() re-fetches whenever the data is older than REFRESH_INTERVAL_MS
//! (15 min), on a detached thread. The countdown itself is recomputed from the
//! stored epoch on every frame — the label is never baked at fetch time, or it
//! would freeze at whatever it said when the fetch landed.

const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io = @import("../core/io_global.zig");
const text = @import("../core/text.zig");
const theme = @import("../ui/theme.zig");
const source_config = @import("../core/source_config.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("eztv_calendar_pure.zig");

/// Re-fetch once the data is older than this. Live, not once-per-session.
pub const REFRESH_INTERVAL_MS: i64 = 15 * 60 * 1000; // 15 minutes

/// Cap on rendered releases (also the feed's `limit`).
const MAX_ENTRIES: usize = 20;

/// Response bodies run ~16 KB at limit=20; 256 KB is generous headroom. Heap,
/// never the spawned thread's stack (macOS threads get 512 KB).
const BODY_CAP: usize = 256 * 1024;

const ID_BASE: usize = 51_200; // dvui .id_extra namespace for this section

// ── Published state ──
//
// Double-buffered: the worker fills the BACK buffer, writes its count, then
// flips `front` with a release-store. The UI acquire-loads `front` and only
// ever reads the front buffer — which is never written while it is the front.
// (A single shared array would let a refresh scribble over entries the UI is
// mid-way through rendering.) The busy guard means at most one worker, so the
// back buffer is uncontended.

var bufs: [2][MAX_ENTRIES]pure.Release = std.mem.zeroes([2][MAX_ENTRIES]pure.Release);
var counts: [2]usize = .{ 0, 0 };
var front = std.atomic.Value(u8).init(0);

// ── Show cards ──
//
// The rail draws one poster card per SHOW, not one row per torrent. The feed has
// neither artwork nor a TMDB id, so the worker groups releases by show and looks
// each one up. Double-buffered alongside the releases and published by the same
// `front` flip.
var card_bufs: [2][pure.MAX_SHOW_CARDS]pure.ShowCard = std.mem.zeroes([2][pure.MAX_SHOW_CARDS]pure.ShowCard);
var card_hits: [2][pure.MAX_SHOW_CARDS]pure.TvHit = std.mem.zeroes([2][pure.MAX_SHOW_CARDS]pure.TvHit);
var card_counts: [2]usize = .{ 0, 0 };

/// Poster slots, keyed by show name and NEVER recycled. Emphatically not indexed
/// by card position: the card list is rebuilt every 15 minutes and shows move
/// around, and a detached poster worker holds a pointer into whichever slot it
/// was given — reusing that slot would hand its pixel write to the wrong show.
var poster_items: [pure.MAX_SHOW_CARDS]state.TmdbItem = std.mem.zeroes([pure.MAX_SHOW_CARDS]state.TmdbItem);

fn posterFor(show: []const u8) *state.TmdbItem {
    const key: i32 = @bitCast(@as(u32, @truncate(std.hash.Wyhash.hash(0xE2D7, show))) | 1);
    for (&poster_items) |*it| {
        if (it.id == key) return it;
    }
    for (&poster_items) |*it| {
        if (it.id == 0) {
            it.id = key;
            return it;
        }
    }
    return &poster_items[0];
}

/// Show name out of a release title, via the tested SxxEyy filename parser rather
/// than a second hand-rolled one.
fn showNameOf(title: []const u8, buf: []u8) []const u8 {
    const subs = @import("subtitles_pure.zig");
    var qbuf: [256]u8 = undefined;
    const parsed = subs.parse(title, &qbuf, buf);
    if (!parsed.is_tv) return "";
    return parsed.show;
}

var loading = std.atomic.Value(bool).init(false);
/// 0 = never fetched. Set BEFORE the spawn so a failing fetch backs off for a
/// full interval instead of being retried every frame.
/// Earliest wall-clock ms at which another fetch may start. 0 = never fetched.
/// This is a DEADLINE, not "when we last fetched": a failed attempt arms a short
/// one and a successful attempt arms the full cadence, which the old
/// `last_fetch_ms + REFRESH_INTERVAL` formulation could not express.
var next_fetch_ms = std.atomic.Value(i64).init(0);

/// Retry floor after a failed fetch. See `pure.nextDelayMs` for why a failure
/// must not arm the full REFRESH_INTERVAL_MS.
const RETRY_BASE_MS: i64 = 15 * 1000;

/// Consecutive failed fetches; 0 after any success. Written by the worker,
/// read by refreshTick on the render thread → atomic.
var fail_streak = std.atomic.Value(u32).init(0);

/// Record a fetch outcome and arm the next attempt. The worker calls this on
/// EVERY exit path (via `defer`) — an attempt that returned without reporting
/// would leave the deadline at refreshTick's optimistic full-interval stamp,
/// i.e. exactly the 15-minute blackout this is here to prevent.
fn armNext(ok: bool) void {
    const streak = if (ok) 0 else fail_streak.load(.acquire) +| 1;
    fail_streak.store(streak, .release);
    const delay = pure.nextDelayMs(streak, RETRY_BASE_MS, REFRESH_INTERVAL_MS);
    next_fetch_ms.store(io.milliTimestamp() + delay, .release);
}

/// Endpoint `field` from the installed eztv plugin, or null → stay inert.
/// The returned slice points into source_config's static table; copy it before
/// handing it to a thread.
fn endpoint(field: []const u8) ?[]const u8 {
    if (!source_config.has("eztv")) return null;
    return source_config.get("eztv", field);
}

// ── Fetch ──

/// curl, not std.http: std.http SEGVs on some ISP TLS resets (see
/// tmdb_api.zig:275). Writes into a CALLER-OWNED buffer and returns the byte
/// count — it never allocates, so it cannot hand back a mis-sized heap slice.
fn curlInto(url: []const u8, buf: []u8) usize {
    // Route through the DPI-bypass sidecar when the user has it on. This fetch
    // is the single reason the release section goes blank: eztv is exactly the
    // kind of host ISP DPI resets (observed here as curl exit 35 / http_code
    // 000, ~40% of attempts), and the bypass exists to defeat precisely that.
    // It was building its argv by hand and never consulting proxyArgs(), so
    // turning the setting on changed nothing for this rail — see link_health.zig
    // for the same pattern done right.
    var argv: [10][]const u8 = undefined;
    var argc: usize = 0;
    for ([_][]const u8{ "curl", "-s", "--max-time", "12" }) |x| {
        argv[argc] = x;
        argc += 1;
    }
    if (@import("dpi_bypass.zig").proxyArgs()) |pa| {
        for (pa) |x| {
            if (argc >= argv.len - 1) break;
            argv[argc] = x;
            argc += 1;
        }
    }
    argv[argc] = url;
    argc += 1;

    var child = io.Child.init(argv[0..argc], alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

/// Carrier for the detached worker: the URL is copied in BY VALUE before the
/// spawn, so the thread never reads source_config's table (which reload() can
/// rewrite underneath it).
const Fetch = struct {
    var url: [640]u8 = std.mem.zeroes([640]u8);
    var url_len: usize = 0;

    fn worker() void {
        const S = @This();
        defer loading.store(false, .release);
        // Outcome-reporting must cover every exit path, including the OOM one
        // below — hence a flag flipped on success rather than a call before
        // each `return`.
        var ok = false;
        defer armNext(ok);

        const body = alloc.alloc(u8, BODY_CAP) catch return;
        defer alloc.free(body);

        const n = curlInto(S.url[0..S.url_len], body);
        // 0 bytes = the TLS connection died with no HTTP response (curl 35),
        // the common DPI failure. Retry in seconds, not after a full interval.
        if (n == 0) return;

        const back: u8 = 1 - front.load(.acquire);
        const got = pure.parseFeed(body[0..n], &bufs[back]);
        if (got == 0) return; // keep whatever we already had on screen
        ok = true;

        // One card per show, newest episode each.
        const cards = pure.groupShows(bufs[back][0..got], &card_bufs[back], showNameOf);

        // Resolve artwork. The feed has none, so each show is looked up once. A
        // failed lookup leaves the card with an empty poster frame rather than
        // dropping it — a card with no picture beats no card.
        const key = state.app.tmdb.api_key[0..state.app.tmdb.api_key_len];
        if (key.len > 0) {
            const tmdb_api = @import("tmdb_api.zig");
            for (card_bufs[back][0..cards], 0..) |*cd, i| {
                card_hits[back][i] = .{};
                var qbuf: [192]u8 = undefined;
                const q = pure.encodeQuery(cd.nameSlice(), &qbuf);
                var url_buf: [256]u8 = undefined;
                const path = std.fmt.bufPrint(&url_buf, "/3/search/tv?query={s}", .{q}) catch continue;
                const rn = tmdb_api.tmdbApiInto(path, key, body);
                if (rn == 0) continue;
                if (pure.firstTvResult(body[0..rn])) |hit| card_hits[back][i] = hit;
            }
        }
        card_counts[back] = cards;

        counts[back] = got;
        front.store(back, .release); // publish LAST

        var lb: [64]u8 = undefined;
        logs.pushLog("info", "eztv", std.fmt.bufPrint(&lb, "Release calendar: {d} entries", .{got}) catch "Release calendar ready", false);
        state.wakeUi();
    }
};

/// Cheap; call every frame from a render site. Kicks a background refresh when
/// the data is stale. No-op when the eztv source plugin isn't installed.
pub fn refreshTick() void {
    const api = endpoint("api") orelse return; // inert: no plugin, no fetch
    if (loading.load(.acquire)) return;

    const now = io.milliTimestamp();
    if (now < next_fetch_ms.load(.acquire)) return;

    // Build the URL BEFORE the spawn, into the carrier, by value.
    const built = pure.buildFeedUrl(api, MAX_ENTRIES, &Fetch.url) orelse return;
    Fetch.url_len = built.len;

    loading.store(true, .release);
    // Optimistic full-interval stamp so a wedged fetch can't be re-kicked every
    // frame if `loading` is somehow missed. The worker's armNext() overwrites
    // this with the real deadline as soon as it knows the outcome.
    next_fetch_ms.store(now + REFRESH_INTERVAL_MS, .release);

    (std.Thread.spawn(.{}, Fetch.worker, .{}) catch {
        loading.store(false, .release);
        return;
    }).detach();
}

// ── Render ──

/// Renders the calendar/countdown section. Renders NOTHING when the eztv source
/// plugin isn't installed, or when no releases have landed yet.
pub fn renderSection() void {
    // Inert check is re-run every frame: uninstalling the plugin must hide the
    // section immediately, even though a previous fetch left entries behind.
    if (!source_config.has("eztv")) return;

    const f = front.load(.acquire);
    const cn = card_counts[f];
    if (cn == 0) return; // nothing groupable yet — draw nothing rather than an empty rail
    const cards = card_bufs[f][0..cn];

    var sec = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.lg, .w = 0, .h = 0 },
    });
    defer sec.deinit();

    // ── Header: title + a link out to the real calendar page ──
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.lg, .y = 0, .w = theme.spacing.lg, .h = theme.spacing.sm },
        });
        defer hdr.deinit();

        _ = dvui.label(@src(), "Latest releases", .{}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_body.withSize(theme.font_size.title),
            .gravity_y = 0.5,
        });

        // Only offered when the plugin declares the page — never hardcoded.
        if (endpoint("calendar")) |cal_url| {
            var link_buf: [512]u8 = undefined;
            if (cal_url.len <= link_buf.len) {
                @memcpy(link_buf[0..cal_url.len], cal_url);
                if (dvui.button(@src(), "Full calendar", .{}, .{
                    .gravity_x = 1.0,
                    .gravity_y = 0.5,
                    .color_fill = theme.transparent,
                    .color_fill_hover = theme.colors.bg_hover,
                    .color_text = theme.colors.accent,
                    .border = dvui.Rect.all(0),
                    .corner_radius = dvui.Rect.all(theme.radius.sm),
                    .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                })) {
                    // Reuse the one process launcher (settings.openExternal) —
                    // no second Child.spawn helper in the codebase.
                    @import("../ui/settings.zig").openExternal(link_buf[0..cal_url.len]);
                }
            }
        }
    }

    // ── Cards ──
    //
    // The SAME poster card the Watching library draws (ui/media_card.zig), so the
    // two surfaces can't drift into looking like two different apps. The feed has
    // no artwork, so the worker resolves each show against TMDB; a show it can't
    // resolve still gets a card, with an empty poster frame.
    //
    // "2h ago" is derived HERE, every frame, from the stored epoch — so it ticks
    // on its own without a refetch.
    const media_card = @import("../ui/media_card.zig");
    const now_s = io.timestamp();

    var strip = dvui.scrollArea(@src(), .{ .horizontal = .auto, .vertical = .none, .horizontal_bar = .hide }, .{
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .w = 10, .h = media_card.POSTER_H + media_card.CHROME_H + 12 },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = media_card.POSTER_H + media_card.CHROME_H + 12 },
        .padding = .{ .x = theme.spacing.md, .y = 0, .w = theme.spacing.md, .h = 0 },
    });
    defer strip.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    defer row.deinit();

    for (cards, 0..) |*cd, i| {
        const hit = &card_hits[f][i];
        const show = cd.nameSlice();

        // TMDB poster path -> absolute URL, so the shared card has one image path
        // for every source.
        var url_buf: [160]u8 = undefined;
        var poster_url: []const u8 = "";
        if (hit.poster_path_len > 0) {
            poster_url = std.fmt.bufPrint(&url_buf, "https://image.tmdb.org/t/p/w185{s}", .{hit.posterSlice()}) catch "";
        }

        // "S09E08 · 2h ago"
        var tag_buf: [16]u8 = undefined;
        const tag = pure.episodeTag(cd.season, cd.episode, &tag_buf);
        var when_buf: [32]u8 = undefined;
        const when = pure.releaseLabel(now_s, cd.released_epoch, &when_buf);
        var sub_buf: [64]u8 = undefined;
        const subtitle = std.fmt.bufPrint(&sub_buf, "{s} · {s}", .{ tag, when }) catch tag;

        // The feed's titles are not always clean UTF-8, and dvui panics on invalid
        // UTF-8 rather than rendering tofu.
        const safe_name = text.safeUtf8(show);

        const click = media_card.render(@src(), ID_BASE + i, posterFor(show), .{
            .poster_url = poster_url,
            .title = safe_name,
            .subtitle = subtitle,
            .subtitle_accent = true,
            .action_label = "Watch",
        });

        if (click != .none) {
            // Resolved to a real show -> open its detail page, where Play/Track
            // already live. Unresolved -> fall back to a search for the episode.
            if (hit.tmdb_id != 0) {
                @import("tmdb.zig").openTvDetailById(hit.tmdb_id, safe_name, hit.posterSlice());
            } else {
                var q_buf: [128]u8 = undefined;
                const q = std.fmt.bufPrint(&q_buf, "{s} {s}", .{ safe_name, tag }) catch safe_name;
                @import("search.zig").setUniversalQuery(q);
                state.navigateToTab(.Search);
            }
        }
    }
}
