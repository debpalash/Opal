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

var loading = std.atomic.Value(bool).init(false);
/// 0 = never fetched. Set BEFORE the spawn so a failing fetch backs off for a
/// full interval instead of being retried every frame.
var last_fetch_ms = std.atomic.Value(i64).init(0);

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
    var child = io.Child.init(&.{ "curl", "-s", "--max-time", "12", url }, alloc);
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

        const body = alloc.alloc(u8, BODY_CAP) catch return;
        defer alloc.free(body);

        const n = curlInto(S.url[0..S.url_len], body);
        if (n == 0) return; // network hiccup — next tick retries after the interval

        const back: u8 = 1 - front.load(.acquire);
        const got = pure.parseFeed(body[0..n], &bufs[back]);
        if (got == 0) return; // keep whatever we already had on screen

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
    const last = last_fetch_ms.load(.acquire);
    if (last != 0 and now - last < REFRESH_INTERVAL_MS) return;

    // Build the URL BEFORE the spawn, into the carrier, by value.
    const built = pure.buildFeedUrl(api, MAX_ENTRIES, &Fetch.url) orelse return;
    Fetch.url_len = built.len;

    loading.store(true, .release);
    last_fetch_ms.store(now, .release);

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
    const n = counts[f];
    if (n == 0) return;
    const list = bufs[f][0..n];

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

    // ── Rows ──
    //
    // The countdown is derived HERE, every frame, from the stored epoch — so it
    // ticks on its own without a refetch.
    const now_s = io.timestamp();

    for (list, 0..) |*r, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = ID_BASE + i,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .margin = .{ .x = theme.spacing.lg, .y = 0, .w = theme.spacing.lg, .h = theme.spacing.xs },
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
        });
        defer row.deinit();

        // SxxEyy chip (blank for movies / season packs).
        var tag_buf: [16]u8 = undefined;
        const tag = pure.episodeTag(r.season, r.episode, &tag_buf);
        if (tag.len > 0) {
            _ = dvui.label(@src(), "{s}", .{tag}, .{
                .id_extra = ID_BASE + 100 + i,
                .color_text = theme.colors.accent,
                .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
                .gravity_y = 0.5,
                .padding = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
        }

        // Release title (UTF-8-sanitized: the feed is not always clean).
        var title_buf: [pure.MAX_TITLE]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{text.safeUtf8Buf(r.title[0..r.title_len], &title_buf)}, .{
            .id_extra = ID_BASE + 200 + i,
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
            .gravity_y = 0.5,
        });

        // Trailing: live countdown + seeds + size.
        var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = ID_BASE + 300 + i,
            .expand = .none,
            .gravity_x = 1.0,
            .gravity_y = 0.5,
        });
        defer meta.deinit();

        var cd_buf: [32]u8 = undefined;
        const cd = pure.releaseLabel(now_s, r.released_epoch, &cd_buf);
        const imminent = r.released_epoch >= now_s or (now_s - r.released_epoch) <= 3600;
        _ = dvui.label(@src(), "{s}", .{cd}, .{
            .id_extra = ID_BASE + 400 + i,
            .color_text = if (imminent) theme.colors.success else theme.colors.text_tertiary,
            .font = dvui.themeGet().font_body.withSize(theme.font_size.small),
            .gravity_y = 0.5,
            .padding = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
        });

        var seed_buf: [24]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{std.fmt.bufPrint(&seed_buf, "{d} seeds", .{r.seeds}) catch ""}, .{
            .id_extra = ID_BASE + 500 + i,
            .color_text = theme.colors.text_tertiary,
            .font = dvui.themeGet().font_body.withSize(theme.font_size.micro),
            .gravity_y = 0.5,
            .padding = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
        });

        var size_buf: [24]u8 = undefined;
        const size = pure.sizeLabel(r.size_bytes, &size_buf);
        if (size.len > 0) {
            _ = dvui.label(@src(), "{s}", .{size}, .{
                .id_extra = ID_BASE + 600 + i,
                .color_text = theme.colors.text_tertiary,
                .font = dvui.themeGet().font_body.withSize(theme.font_size.micro),
                .gravity_y = 0.5,
                .padding = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
        }
    }
}
