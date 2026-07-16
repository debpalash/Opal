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
//! dvui. Opening an item routes on content type (opds_pure.readerRoute):
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
const http = @import("../core/http.zig");
const safeUtf8 = @import("../core/text.zig").safeUtf8;

const alloc = @import("../core/alloc.zig").allocator;

// Publish-side lock: the detached fetch worker snapshots feed entries into
// state.app.opds.* under this mutex. The UI reads entry_count then entries —
// entry_count is written last so a torn read shows fewer rows, never garbage.
var parse_mutex: @import("../core/sync.zig").Mutex = .{};

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
fn opdsGet(url: []const u8, user: []const u8, pass: []const u8) ?[]u8 {
    var auth_buf: [512]u8 = undefined;
    const auth: ?[]const u8 = if (user.len > 0 or pass.len > 0)
        pure.basicAuthHeader(user, pass, &auth_buf)
    else
        null;

    const resp_buf = alloc.alloc(u8, 256 * 1024) catch return null;
    defer alloc.free(resp_buf);
    const resp = http.fetch(url, resp_buf, .{
        .timeout_secs = 15,
        .accept = "application/atom+xml,application/xml",
        .auth_header = auth,
        .max_response = 256 * 1024,
    }) orelse return null;

    const result = alloc.alloc(u8, resp.len) catch return null;
    @memcpy(result, resp);
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
/// connected flag + persists on the first successful connect.
fn fetchFeedSync(mark_connected: bool) void {
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

    // Publish under the mutex: title first, entries, then entry_count LAST so a
    // concurrent UI read never sees a count ahead of the data.
    parse_mutex.lock();
    const title = safeUtf8(pure.feedTitle(body));
    const tl = @min(title.len, state.app.opds.feed_title.len);
    @memcpy(state.app.opds.feed_title[0..tl], title[0..tl]);
    state.app.opds.feed_title_len = tl;
    const n = pure.parseFeed(body, url, &state.app.opds.entries);
    state.app.opds.entry_count = n;
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

    state.app.opds.thread = std.Thread.spawn(.{}, struct {
        fn worker(mc: bool) void {
            defer state.app.opds.is_loading.store(false, .release);
            fetchFeedSync(mc);
        }
    }.worker, .{mark_connected}) catch blk: {
        state.app.opds.is_loading.store(false, .release);
        break :blk null;
    };
    // Detach: the result is observed via state.app.opds, never joined.
    if (state.app.opds.thread) |t| t.detach();
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
    parse_mutex.lock();
    state.app.opds.entry_count = 0;
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

    // Snapshot the entry count under the publish lock (cheap — a single usize).
    parse_mutex.lock();
    const count = state.app.opds.entry_count;
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
