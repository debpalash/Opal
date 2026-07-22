//! OPDS reading-server client — one client for Komga, Kavita, Calibre-Web and
//! LANraragi (all speak the OPDS 1.2 Atom/XML catalog protocol).
//!
//! Mirrors services/jellyfin.zig: a config-stored catalog URL + Basic-auth
//! credentials, a detached worker that fetches a feed off the UI thread and
//! publishes parsed entries into fixed-size state buffers under `parse_mutex`,
//! an atomic `is_loading` guard, and a Browse tab (renderContent) with a login
//! form + a drill-in feed browser.
//!
//! ALL feed parsing / href resolution / auth-header building lives in the
//! unit-tested services/opds_pure.zig — this file only does I/O, threading and
//! dvui. The feed browser also supports infinite scroll: a feed's rel="next"
//! Atom link (opds_pure.feedNextHref) is fetched + appended onto the entry
//! list as the user nears the bottom of renderFeed's scroll area — see
//! loadMore()/fetchMoreSync() below. Opening an item routes on content type
//! (opds_pure.readerRoute):
//!   • CBZ/CBR/image → the existing in-app comics reader (services/comics.zig)
//!   • EPUB/PDF      → the OS (settings.openExternal — no in-app ebook renderer)
//!   • anything else → a "not previewable" toast
//!
//! Reader-routing detail: an entry that advertises the OPDS-PSE page-streaming
//! extension (opds_pure.OpdsEntry.isPseStreamable — Komga/Kavita) is read via
//! authenticated per-page image streaming: opds hands the {pageNumber} template
//! + page count + a Basic-auth header to comics.loadPseBook, which drives the
//! existing page pipeline with the auth header attached to every fetch. Plain
//! page-image servers still fall back to the <img> scraper (requestLoad). Full
//! CBZ/CBR *archive unpacking* remains a follow-up. Live page streaming against a
//! real Komga/Kavita server needs manual verification (the PSE parse + page-URL
//! build are covered by opds_pure unit tests against a sample entry).

const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const pure = @import("opds_pure.zig");
const safeUtf8 = @import("../core/text.zig").safeUtf8;

const alloc = @import("../core/alloc.zig").allocator;

// Publish-side lock: the detached fetch worker snapshots feed entries into
// state.app.opds.* under this mutex. The UI reads entry_count then entries —
// entry_count is written last so a torn read shows fewer rows, never garbage.
var parse_mutex: @import("../core/sync.zig").Mutex = .{};

// ── Infinite-scroll pagination ──
// OPDS/Atom feeds carry a `<link rel="next" href="…"/>` at the feed level
// (opds_pure.feedNextHref extracts + resolves it). `more_available` and
// `next_href_buf` are published by the SAME worker + mutex as entries/
// entry_count above, so a UI read under parse_mutex always sees a consistent
// triple. `loading_more` serializes append fetches so a single near-bottom
// scroll can't spawn a burst (mirrors comics/drama/youtube). `fetch_gen` is
// bumped by every fresh (replace) feed load — a load-more worker checks it
// before publishing so a stale append can never land on top of a feed the
// user has since navigated away from.
var more_available: bool = true;
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Absolute URL of the CURRENT feed's rel="next" continuation link. Empty
/// when the current feed has no next page. Guarded by parse_mutex.
var next_href_buf: [512]u8 = undefined;
var next_href_len: usize = 0;
var fetch_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// ══════════════════════════════════════════════════════════
// HTTP
// ══════════════════════════════════════════════════════════

/// Build the "Authorization: Basic …" header line for the configured credentials
/// into `buf` (via the tested opds_pure.basicAuthHeader). Returns "" when no
/// credentials are set (an anonymous server) or on overflow. UI-thread only —
/// reads the credential buffers the login form owns.
fn opdsAuthHeader(buf: []u8) []const u8 {
    const user = state.app.opds.user_buf[0 .. std.mem.indexOfScalar(u8, &state.app.opds.user_buf, 0) orelse state.app.opds.user_buf.len];
    const pass = state.app.opds.pass_buf[0 .. std.mem.indexOfScalar(u8, &state.app.opds.pass_buf, 0) orelse state.app.opds.pass_buf.len];
    if (user.len == 0 and pass.len == 0) return "";
    return pure.basicAuthHeader(user, pass, buf) orelse "";
}

/// GET an OPDS feed with HTTP Basic auth into a fresh heap buffer (caller frees).
/// Returns null on connect/parse failure or an empty body.
///
/// curl, NOT http.fetch/std.http — the same call this module used to make, and
/// the same reason tmdb_api.zig gives for its own curl path. Measured against
/// Project Gutenberg's live catalog (a plain, reachable OPDS feed): curl gets
/// 200 over both https AND http, while std.http's `client.request` fails at
/// connect for either scheme. Since that is the first hop, OPDS could not reach
/// a server the rest of the app talks to fine. 43 other services already fetch
/// through curl; this was one of the last holdouts.
fn opdsGet(url: []const u8, user: []const u8, pass: []const u8) ?[]u8 {
    var auth_buf: [512]u8 = undefined;
    // basicAuthHeader yields a full header LINE ("Authorization: Basic …"),
    // which is exactly what curl -H wants.
    const auth: ?[]const u8 = if (user.len > 0 or pass.len > 0)
        pure.basicAuthHeader(user, pass, &auth_buf)
    else
        null;

    const io_g = @import("../core/io_global.zig");
    // -L: OPDS catalogs routinely redirect (Komga /opds → /opds/v1.2, trailing
    // slashes, http→https). --max-time bounds the whole request the way the old
    // watchdog did.
    var child = if (auth) |a|
        io_g.Child.init(&.{
            "curl",       "-sL",
            "-H",         "Accept: application/atom+xml,application/xml",
            "-H",         a,
            "--max-time", "15",
            url,
        }, alloc)
    else
        io_g.Child.init(&.{
            "curl",       "-sL",
            "-H",         "Accept: application/atom+xml,application/xml",
            "--max-time", "15",
            url,
        }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    const resp_buf = alloc.alloc(u8, 256 * 1024) catch {
        _ = child.wait() catch {};
        return null;
    };
    defer alloc.free(resp_buf);
    const n = if (child.stdout) |*so| io_g.readAll(so, resp_buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) return null;

    const result = alloc.alloc(u8, n) catch return null;
    @memcpy(result, resp_buf[0..n]);
    return result;
}

// ══════════════════════════════════════════════════════════
// Fetch + publish
// ══════════════════════════════════════════════════════════

fn setError(msg: []const u8) void {
    const n = @min(msg.len, state.app.opds.error_msg.len);
    @memcpy(state.app.opds.error_msg[0..n], msg[0..n]);
    state.app.opds.error_msg_len = n;
    state.app.opds.fetch_error = true;
}

/// Snapshot the current feed URL + credentials, fetch, parse, publish. Runs ONLY
/// on the detached worker (never the UI thread). `mark_connected` flips the
/// connected flag + persists on the first successful connect. `my_gen` is this
/// fetch's generation (from spawnFetch) — always published here since this is
/// a REPLACE fetch (fresh navigation always wins), but the gen is bumped so
/// any in-flight load-more append from the PREVIOUS feed drops its stale
/// publish instead of corrupting this one.
fn fetchFeedSync(mark_connected: bool, my_gen: u32) void {
    // Snapshot everything the UI thread might edit mid-request into worker locals.
    var url_buf: [512]u8 = undefined;
    const url_len = @min(state.app.opds.current_url_len, url_buf.len);
    @memcpy(url_buf[0..url_len], state.app.opds.current_url[0..url_len]);
    const url = url_buf[0..url_len];

    var user_buf: [128]u8 = undefined;
    @memcpy(&user_buf, &state.app.opds.user_buf);
    var pass_buf: [128]u8 = undefined;
    @memcpy(&pass_buf, &state.app.opds.pass_buf);
    const user = user_buf[0 .. std.mem.indexOfScalar(u8, &user_buf, 0) orelse user_buf.len];
    const pass = pass_buf[0 .. std.mem.indexOfScalar(u8, &pass_buf, 0) orelse pass_buf.len];

    if (url.len == 0) {
        setError("Catalog URL is empty");
        state.wakeUi();
        return;
    }

    const body = opdsGet(url, user, pass) orelse {
        setError("Could not reach the OPDS server — check the URL and credentials");
        state.wakeUi();
        return;
    };
    defer alloc.free(body);

    // A newer navigation (another connect/openFeed/goBack) superseded this
    // in-flight request — drop the stale result rather than clobber the feed
    // the user has since moved to (mirrors drama.zig's fetch_gen guard).
    if (fetch_gen.load(.acquire) != my_gen) return;

    // Publish under the mutex: title first, entries, then entry_count LAST so a
    // concurrent UI read never sees a count ahead of the data.
    parse_mutex.lock();
    if (fetch_gen.load(.acquire) != my_gen) {
        parse_mutex.unlock();
        return;
    } // re-check under the lock
    const title = safeUtf8(pure.feedTitle(body));
    const tl = @min(title.len, state.app.opds.feed_title.len);
    @memcpy(state.app.opds.feed_title[0..tl], title[0..tl]);
    state.app.opds.feed_title_len = tl;
    const n = pure.parseFeed(body, url, &state.app.opds.entries);
    state.app.opds.entry_count = n;
    // A fresh (replace) feed load ALWAYS resets the append cursor: capture
    // this feed's own rel="next" link, or clear more_available when it has
    // none — loadMore() becomes a no-op for feeds with no pagination.
    if (pure.feedNextHref(body, url, &next_href_buf)) |next| {
        next_href_len = next.len;
        more_available = true;
    } else {
        next_href_len = 0;
        more_available = false;
    }
    parse_mutex.unlock();

    state.app.opds.fetch_error = false;
    if (mark_connected) {
        state.app.opds.connected = true;
        state.markConfigDirty();
    }
    logs.pushLog("info", "opds", "OPDS feed loaded", false);
    state.wakeUi();
}

/// Spawn the detached fetch worker for the current feed URL.
fn spawnFetch(mark_connected: bool) void {
    if (state.app.opds.is_loading.load(.acquire)) return;
    state.app.opds.is_loading.store(true, .release);
    state.app.opds.fetch_error = false;
    // A fresh replace-fetch (connect/openFeed/goBack) is a new generation — an
    // in-flight load-more append from the feed being navigated away from will
    // see its generation is stale and drop its publish (see fetchMoreSync).
    const my_gen = fetch_gen.fetchAdd(1, .acq_rel) + 1;

    state.app.opds.thread = std.Thread.spawn(.{}, struct {
        fn worker(mc: bool, gen: u32) void {
            defer state.app.opds.is_loading.store(false, .release);
            fetchFeedSync(mc, gen);
        }
    }.worker, .{ mark_connected, my_gen }) catch blk: {
        state.app.opds.is_loading.store(false, .release);
        break :blk null;
    };
    // Detach: the result is observed via state.app.opds, never joined.
    if (state.app.opds.thread) |t| t.detach();
}

// ══════════════════════════════════════════════════════════
// Infinite scroll — fetch + append the feed's rel="next" page
// ══════════════════════════════════════════════════════════

/// Infinite-scroll appender: fetch the current feed's rel="next" page and
/// merge its entries onto the existing list. Guarded by `loading_more` + the
/// main `is_loading` atomic so a near-bottom scroll can't spawn a burst;
/// no-op once `more_available` clears — which happens the moment a feed has
/// no rel="next" link (set by fetchFeedSync/fetchMoreSync), a load-more fetch
/// fails, or the fixed 300-entry buffer fills. Runs under the current
/// fetch_gen so a fresh feed navigation (connect/openFeed/goBack) supersedes
/// it. Mirrors services/drama.zig's loadMore.
pub fn loadMore() void {
    if (!more_available) return;
    if (state.app.opds.is_loading.load(.acquire)) return;
    if (loading_more.load(.acquire)) return;
    if (state.app.opds.entry_count == 0) return;
    if (state.app.opds.entry_count >= state.app.opds.entries.len) {
        parse_mutex.lock();
        more_available = false;
        parse_mutex.unlock();
        return;
    }
    if (loading_more.swap(true, .acq_rel)) return; // lost the race — another append in flight

    const my_gen = fetch_gen.load(.acquire); // stay within the current generation

    if (std.Thread.spawn(.{}, loadMoreWorker, .{my_gen})) |t| {
        t.detach();
    } else |_| {
        loading_more.store(false, .release);
    }
}

fn loadMoreWorker(my_gen: u32) void {
    defer loading_more.store(false, .release);
    fetchMoreSync(my_gen);
}

/// Fetch the feed's rel="next" continuation page and APPEND its entries onto
/// state.app.opds.entries starting at the current entry_count (never clears —
/// only fetchFeedSync's replace path does that). Uses the SAME Basic-auth
/// header + fetch path (opdsGet) as the main feed fetch. Runs ONLY on the
/// detached load-more worker (never the UI thread).
fn fetchMoreSync(my_gen: u32) void {
    var url_buf: [512]u8 = undefined;
    parse_mutex.lock();
    const url_len = @min(next_href_len, url_buf.len);
    @memcpy(url_buf[0..url_len], next_href_buf[0..url_len]);
    parse_mutex.unlock();
    const url = url_buf[0..url_len];
    if (url.len == 0) {
        parse_mutex.lock();
        more_available = false;
        parse_mutex.unlock();
        return;
    }

    // Same credential snapshot as fetchFeedSync — the UI thread may edit these
    // buffers mid-request, so copy them out before the blocking fetch.
    var user_buf: [128]u8 = undefined;
    @memcpy(&user_buf, &state.app.opds.user_buf);
    var pass_buf: [128]u8 = undefined;
    @memcpy(&pass_buf, &state.app.opds.pass_buf);
    const user = user_buf[0 .. std.mem.indexOfScalar(u8, &user_buf, 0) orelse user_buf.len];
    const pass = pass_buf[0 .. std.mem.indexOfScalar(u8, &pass_buf, 0) orelse pass_buf.len];

    const body = opdsGet(url, user, pass) orelse {
        // Fail closed (mirrors drama.zig treating a short/failed page as "no
        // more") rather than retry-spamming the server on every near-bottom
        // frame after a transient failure.
        logs.pushLog("error", "opds", "Load-more fetch failed", true);
        if (fetch_gen.load(.acquire) == my_gen) {
            parse_mutex.lock();
            more_available = false;
            parse_mutex.unlock();
        }
        return;
    };
    defer alloc.free(body);

    // A fresh feed navigation superseded this append — drop it rather than
    // append the old feed's continuation onto the new feed's entries.
    if (fetch_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (fetch_gen.load(.acquire) != my_gen) return; // re-check under the lock

    const base = state.app.opds.entry_count;
    const cap = state.app.opds.entries.len;
    if (base >= cap) {
        more_available = false;
        return;
    }
    const n = pure.parseFeed(body, url, state.app.opds.entries[base..]);
    state.app.opds.entry_count = base + n;

    if (pure.feedNextHref(body, url, &next_href_buf)) |next| {
        next_href_len = next.len;
        more_available = state.app.opds.entry_count < cap;
    } else {
        next_href_len = 0;
        more_available = false;
    }

    logs.pushLog("info", "opds", "Loaded more entries", false);
    state.wakeUi();
}

// ══════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════

/// Connect to the configured catalog root (server_url) and load its feed.
pub fn connect() void {
    if (state.app.opds.is_loading.load(.acquire)) return;
    state.app.opds.nav_depth = 0;
    // current_url := server_url (catalog root).
    const n = @min(state.app.opds.server_url_len, state.app.opds.current_url.len);
    @memcpy(state.app.opds.current_url[0..n], state.app.opds.server_url[0..n]);
    state.app.opds.current_url_len = n;
    state.app.opds.feed_title_len = 0;
    spawnFetch(true);
}

/// Settings "Test Connection" button — same fetch as connect().
pub fn testConnection() void {
    connect();
}

/// Drill into a subsection feed: push the current feed onto the nav stack, set
/// the new feed URL + heading, and fetch. UI-thread only.
fn openFeed(url: []const u8, title: []const u8) void {
    if (url.len == 0 or url.len >= state.app.opds.current_url.len) return;

    // Push current feed for the Back button.
    if (state.app.opds.nav_depth < state.app.opds.nav_urls.len) {
        const d = state.app.opds.nav_depth;
        const cl = state.app.opds.current_url_len;
        @memcpy(state.app.opds.nav_urls[d][0..cl], state.app.opds.current_url[0..cl]);
        state.app.opds.nav_url_lens[d] = cl;
        const fl = state.app.opds.feed_title_len;
        @memcpy(state.app.opds.nav_titles[d][0..fl], state.app.opds.feed_title[0..fl]);
        state.app.opds.nav_title_lens[d] = fl;
        state.app.opds.nav_depth += 1;
    }

    @memcpy(state.app.opds.current_url[0..url.len], url);
    state.app.opds.current_url_len = url.len;
    // Provisional heading (overwritten by the fetched feed's own <title>).
    const tl = @min(title.len, state.app.opds.feed_title.len);
    @memcpy(state.app.opds.feed_title[0..tl], title[0..tl]);
    state.app.opds.feed_title_len = tl;
    spawnFetch(false);
}

/// Pop the nav stack and reload the parent feed. UI-thread only.
pub fn goBack() void {
    if (state.app.opds.nav_depth == 0) return;
    state.app.opds.nav_depth -= 1;
    const d = state.app.opds.nav_depth;
    const ul = state.app.opds.nav_url_lens[d];
    @memcpy(state.app.opds.current_url[0..ul], state.app.opds.nav_urls[d][0..ul]);
    state.app.opds.current_url_len = ul;
    const tl = state.app.opds.nav_title_lens[d];
    @memcpy(state.app.opds.feed_title[0..tl], state.app.opds.nav_titles[d][0..tl]);
    state.app.opds.feed_title_len = tl;
    spawnFetch(false);
}

/// Open one entry: drill into a subsection, or route an acquisition by content
/// type (image/comic → in-app comics reader; EPUB/PDF → external; else toast).
pub fn openEntry(idx: usize) void {
    if (idx >= state.app.opds.entry_count) return;
    const e = &state.app.opds.entries[idx];
    const href = e.hrefSlice();
    if (href.len == 0) return;

    if (e.is_navigation) {
        openFeed(href, e.titleSlice());
        return;
    }

    switch (pure.readerRoute(e.contentTypeSlice())) {
        .comics => {
            if (e.isPseStreamable()) {
                // Komga/Kavita OPDS-PSE: stream per-page images under Basic auth
                // rather than scraping <img> tags. Build the auth header from the
                // stored credentials and drive the comics reader with the tested
                // page-URL template + count.
                var auth_buf: [512]u8 = undefined;
                const auth = opdsAuthHeader(&auth_buf);
                @import("comics.zig").loadPseBook(e.titleSlice(), e.pseUrlSlice(), e.pse_count, auth);
                state.navigateToTab(.Comics);
                state.showToast("Streaming pages…");
            } else {
                // Plain page-image / archive server → the existing <img> scraper.
                @import("comics.zig").requestLoad(href);
                state.navigateToTab(.Comics);
                state.showToast("Opening in reader");
            }
        },
        .external => {
            @import("../ui/settings.zig").openExternal(href);
            state.showToast("Opening externally");
        },
        .unsupported => {
            state.showToastTyped("Not previewable — EPUB/PDF open externally", .warning);
        },
    }
}

/// Disconnect: forget the connection + clear the loaded feed. UI-thread only.
pub fn disconnect() void {
    _ = fetch_gen.fetchAdd(1, .acq_rel); // supersede any in-flight fetch/append
    parse_mutex.lock();
    state.app.opds.entry_count = 0;
    more_available = true;
    next_href_len = 0;
    parse_mutex.unlock();
    state.app.opds.connected = false;
    state.app.opds.nav_depth = 0;
    state.app.opds.feed_title_len = 0;
    state.app.opds.current_url_len = 0;
    state.markConfigDirty();
}

// ══════════════════════════════════════════════════════════
// UI
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    if (!state.app.opds.connected) {
        renderLoginForm();
        return;
    }
    renderFeed();
}

fn renderLoginForm() void {
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    {
        var hdr = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 20, .w = 16, .h = 16 },
        });
        defer hdr.deinit();
        _ = dvui.label(@src(), "Reading server (OPDS)", .{}, .{ .color_text = theme.colors.accent });
        _ = dvui.label(@src(), "Connect to Komga, Kavita, Calibre-Web or LANraragi (manga, comics & ebooks)", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
    }

    {
        var form = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 16, .y = 0, .w = 16, .h = 0 },
        });
        defer form.deinit();

        _ = dvui.label(@src(), "Catalog URL", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        if (state.app.opds.server_url_len == 0) {
            const default = "http://localhost:25600/opds/v1.2/catalog";
            @memcpy(state.app.opds.server_url[0..default.len], default);
            state.app.opds.server_url_len = default.len;
        }
        {
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.opds.server_url } }, textEntryOpts());
            state.app.opds.server_url_len = std.mem.indexOfScalar(u8, &state.app.opds.server_url, 0) orelse state.app.opds.server_url.len;
            te.deinit();
        }

        _ = dvui.label(@src(), "Username (optional)", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        {
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.opds.user_buf } }, textEntryOpts());
            te.deinit();
        }

        _ = dvui.label(@src(), "Password (optional)", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        {
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.opds.pass_buf }, .password_char = "•" }, textEntryOpts());
            te.deinit();
        }

        if (state.app.opds.fetch_error and state.app.opds.error_msg_len > 0) {
            _ = dvui.label(@src(), "{s}", .{state.app.opds.error_msg[0..state.app.opds.error_msg_len]}, .{
                .color_text = theme.colors.danger,
                .padding = .{ .x = 0, .y = 4, .w = 0, .h = 8 },
            });
        }

        const busy = state.app.opds.is_loading.load(.acquire);
        if (dvui.button(@src(), if (busy) "Connecting…" else "Connect", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = theme.colors.text_on_accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 14, .y = 8, .w = 14, .h = 8 },
            .margin = .{ .x = 0, .y = 6, .w = 0, .h = 0 },
        }) and !busy) {
            state.markConfigDirty();
            connect();
        }
    }
}

fn textEntryOpts() dvui.Options {
    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
    };
}

fn renderFeed() void {
    // Header row: Back (if drilled in) + Disconnect + feed title.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 8 },
        });
        defer row.deinit();

        if (state.app.opds.nav_depth > 0) {
            if (dvui.button(@src(), "‹ Back", .{}, .{
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
                .gravity_y = 0.5,
            })) goBack();
        }

        const title = state.app.opds.feed_title[0..state.app.opds.feed_title_len];
        _ = dvui.label(@src(), "{s}", .{if (title.len > 0) safeUtf8(title) else "Library"}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
            .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
        });

        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        if (dvui.button(@src(), "Disconnect", .{}, .{
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
            .gravity_y = 0.5,
        })) disconnect();
    }

    if (state.app.opds.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "Loading…", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 16, .y = 8, .w = 16, .h = 8 },
        });
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    // Snapshot the entry count + pagination flag under the publish lock (cheap
    // — a usize + a bool) so this frame sees a consistent triple with entries.
    parse_mutex.lock();
    const count = state.app.opds.entry_count;
    const has_more = more_available;
    parse_mutex.unlock();

    if (count == 0 and !state.app.opds.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "This feed is empty.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
        });
        return;
    }

    var i: usize = 0;
    while (i < count and i < state.app.opds.entries.len) : (i += 1) {
        renderEntryRow(i);
    }

    // Infinite scroll: fetch + append the feed's rel="next" page as the user
    // nears the bottom. Bounded by more_available + loading_more so one
    // scroll can't spawn a burst; `underfilled` keeps paging when the first
    // page is shorter than the viewport. Mirrors services/drama.zig.
    if (has_more) {
        const loading = loading_more.load(.acquire);
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        const underfilled = max_y <= 0 and count > 0;
        if ((near_bottom or underfilled) and !loading and !state.app.opds.is_loading.load(.acquire)) {
            loadMore();
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

fn renderEntryRow(idx: usize) void {
    const e = &state.app.opds.entries[idx];

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = idx,
        .expand = .horizontal,
        .padding = .{ .x = 14, .y = 8, .w = 14, .h = 8 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer row.deinit();

    // Title + type/kind subtitle.
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = idx, .expand = .horizontal, .gravity_y = 0.5 });
        defer col.deinit();

        _ = dvui.label(@src(), "{s}", .{safeUtf8(e.titleSlice())}, .{
            .id_extra = idx,
            .color_text = theme.colors.text_primary,
        });

        const subtitle: []const u8 = if (e.is_navigation)
            "Folder"
        else switch (pure.readerRoute(e.contentTypeSlice())) {
            .comics => "Comic / manga",
            .external => "Ebook (opens externally)",
            .unsupported => "Download",
        };
        _ = dvui.label(@src(), "{s}", .{subtitle}, .{
            .id_extra = idx,
            .color_text = theme.colors.text_tertiary,
        });
    }

    const action: []const u8 = if (e.is_navigation) "Open ›" else "Read";
    if (dvui.button(@src(), action, .{}, .{
        .id_extra = idx,
        .corner_radius = theme.dims.rad_sm,
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.text_on_accent,
        .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
        .gravity_y = 0.5,
    })) {
        openEntry(idx);
    }
}
