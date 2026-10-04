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
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const logs = @import("../core/logs.zig");
const poster = @import("../core/poster.zig");
const pure = @import("opds_pure.zig");
const safeUtf8 = @import("../core/text.zig").safeUtf8;
const tmdb_pure = @import("tmdb_pure.zig");

const alloc = @import("../core/alloc.zig").allocator;
const c_alloc = std.heap.c_allocator;
const OPDS_CARD_TARGET_W: f32 = 150;
const OPDS_CARD_GAP: f32 = 4;
const OPDS_CARD_FOOTER_H: f32 = 54;
var entry_covers: [300]components.CoverSlot = [_]components.CoverSlot{.{}} ** 300;

// Publish-side lock: the detached fetch worker snapshots feed entries into
// state.app.opds.* under this mutex. The UI reads entry_count then entries —
// entry_count is written last so a torn read shows fewer rows, never garbage.
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var catalog_revision: u32 = 1;
pub fn catalogGeneration() u32 {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    return catalog_revision;
}

pub const ConnectionSnapshot = struct {
    connected: bool = false,
    server: [256]u8 = .{0} ** 256,
    server_len: usize = 0,
    user: [128]u8 = .{0} ** 128,
    user_len: usize = 0,
    pass: [128]u8 = .{0} ** 128,
    pass_len: usize = 0,
    identity: u64 = 0,
};
var configured_connection: ConnectionSnapshot = .{};

/// Credentials are copied from the configured record, never the live form.
pub fn connectionSnapshot() ConnectionSnapshot {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    var result = configured_connection;
    result.connected = state.app.opds.connected;
    return result;
}

pub fn configureConnection(server: []const u8, user: []const u8, pass: []const u8) void {
    var next: ConnectionSnapshot = .{};
    next.server_len = @min(server.len, next.server.len - 1);
    next.user_len = @min(user.len, next.user.len - 1);
    next.pass_len = @min(pass.len, next.pass.len - 1);
    @memcpy(next.server[0..next.server_len], server[0..next.server_len]);
    @memcpy(next.user[0..next.user_len], user[0..next.user_len]);
    @memcpy(next.pass[0..next.pass_len], pass[0..next.pass_len]);
    var hash = std.hash.Wyhash.init(0x4f504453);
    hash.update(next.server[0..next.server_len]);
    hash.update("\x00");
    hash.update(next.user[0..next.user_len]);
    hash.update("\x00");
    hash.update(next.pass[0..next.pass_len]);
    next.identity = hash.final();
    parse_mutex.lock();
    catalog_revision +%= 1;
    configured_connection = next;
    state.app.opds.server_url = next.server;
    state.app.opds.server_url_len = next.server_len;
    state.app.opds.user_buf = next.user;
    state.app.opds.pass_buf = next.pass;
    state.app.opds.connected = false;
    parse_mutex.unlock();
    fetch_request.cancel(&state.app.opds.is_loading);
}
pub fn setConfiguredServer(value: []const u8) void {
    const snap = connectionSnapshot();
    configureConnection(value, snap.user[0..snap.user_len], snap.pass[0..snap.pass_len]);
}
pub fn setConfiguredUser(value: []const u8) void {
    const snap = connectionSnapshot();
    configureConnection(snap.server[0..snap.server_len], value, snap.pass[0..snap.pass_len]);
}
pub fn setConfiguredPassword(value: []const u8) void {
    const snap = connectionSnapshot();
    configureConnection(snap.server[0..snap.server_len], snap.user[0..snap.user_len], value);
}
pub fn setConfiguredConnected(value: bool) void {
    parse_mutex.lock();
    state.app.opds.connected = value and configured_connection.server_len > 0;
    parse_mutex.unlock();
}

// ── Infinite-scroll pagination ──
// OPDS/Atom feeds carry a `<link rel="next" href="…"/>` at the feed level
// (opds_pure.feedNextHref extracts + resolves it). `more_available` and
// `next_href_buf` are published by the SAME worker + mutex as entries/
// entry_count above, so a UI read under parse_mutex always sees a consistent
// triple. `loading_more` serializes append fetches so a single near-bottom
// scroll can't spawn a burst (mirrors comics/drama/youtube). The request generation is
// bumped by every fresh (replace) feed load — a load-more worker checks it
// before publishing so a stale append can never land on top of a feed the
// user has since navigated away from.
var more_available: bool = true;
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// Absolute URL of the CURRENT feed's rel="next" continuation link. Empty
/// when the current feed has no next page. Guarded by parse_mutex.
var next_href_buf: [512]u8 = undefined;
var next_href_len: usize = 0;
var fetch_request: @import("../core/latest_request.zig").Gate = .{};
// Config restores `connected` after startup, but no connect() call occurs in
// that path. This latch lets desktop and companion entry points safely kick
// one root fetch without retrying a failed server on every frame/request.
var restored_fetch_attempted: std.atomic.Value(bool) = .init(false);

pub const DiscoverySnapshot = struct {
    active: bool = false,
    count: usize = 0,
    categories: [3]pure.OpdsEntry = undefined,
};
var discovery: DiscoverySnapshot = .{};
var discovery_next: [3][512]u8 = undefined;
var discovery_next_len: [3]usize = @splat(0);
var loading_fixture_for_test = false;
pub fn setLoadingFixtureForTest(enabled: bool) void {
    if (!@import("builtin").is_test) @compileError("Native OPDS fixture is test-only");
    loading_fixture_for_test = enabled;
    state.app.opds.connected = enabled;
    state.app.opds.entry_count = 0;
    state.app.opds.fetch_error = false;
    state.app.opds.is_loading.store(enabled, .release);
}
pub fn discoverySnapshot() DiscoverySnapshot {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    return discovery;
}
pub fn openDiscoveryCategory(index: usize) bool {
    const snapshot = discoverySnapshot();
    if (!snapshot.active or index >= snapshot.count) return false;
    const category = snapshot.categories[index];
    openFeed(category.hrefSlice(), category.titleSlice());
    return true;
}
const DiscoveryGroup = struct {
    job: FeedJob,
    categories: [3]pure.OpdsEntry = undefined,
    count: usize = 0,
    append: bool = false,
    published: bool = false,
    succeeded: bool = false,
    next: [3][512]u8 = undefined,
    next_len: [3]usize = @splat(0),
};
fn runGutenbergDiscovery(job: FeedJob, categories: []const pure.OpdsEntry, append: bool) void {
    const group = alloc.create(DiscoveryGroup) catch return;
    defer alloc.destroy(group);
    group.* = .{ .job = job, .count = @min(categories.len, 3), .append = append };
    @memcpy(group.categories[0..group.count], categories[0..group.count]);
    if (append) for (categories[0..group.count], 0..) |category, index| {
        group.next_len[index] = category.href_len;
        @memcpy(group.next[index][0..category.href_len], category.hrefSlice());
    };
    const indexes = [_]usize{ 0, 1, 2 };
    @import("browse_fanout.zig").run(usize, indexes[0..group.count], group, fetchGutenbergSection, .{
        .limit = 3,
        .cancel_epoch = .{ .epoch32 = .{ .value = &fetch_request.generation, .expected = job.generation } },
    });
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!fetch_request.isCurrent(job.generation)) return;
    if (!group.succeeded) {
        setError("Could not load Gutenberg discovery. Retry the catalog.");
        return;
    }
    if (!group.published and !append) {
        state.app.opds.entry_count = 0;
        catalog_revision +%= 1;
    }
    discovery.active = true;
    if (!append) {
        discovery.count = group.count;
        discovery.categories = group.categories;
    }
    discovery_next = group.next;
    discovery_next_len = group.next_len;
    more_available = state.app.opds.entry_count < state.app.opds.entries.len and anyDiscoveryNext();
    state.app.opds.fetch_error = false;
    state.wakeUi();
}
fn anyDiscoveryNext() bool {
    for (discovery_next_len) |length| if (length > 0) return true;
    return false;
}
fn fetchGutenbergSection(group: *DiscoveryGroup, index: usize) void {
    const url = group.categories[index].hrefSlice();
    if (url.len == 0) return;
    const generation = group.job.generation;
    const body = opdsGetCancelled(url, "", "", 2 * 1024 * 1024, "8", .{ .epoch32 = .{ .value = &fetch_request.generation, .expected = generation } }) orelse return;
    defer alloc.free(body);
    if (!pure.isCompleteFeed(body)) return;
    const rows = alloc.alloc(pure.OpdsEntry, state.app.opds.entries.len) catch return;
    defer alloc.free(rows);
    const count = pure.parseFeed(body, url, rows);
    var verified_work = false;
    for (rows[0..count]) |row| if (pure.gutenbergWorkId(row.hrefSlice()) != null) {
        verified_work = true;
        break;
    };
    if (count > 0 and !verified_work) return;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!fetch_request.isCurrent(generation)) return;
    group.succeeded = true;
    group.next_len[index] = 0;
    if (pure.feedNextHref(body, url, &group.next[index])) |next| {
        if (pure.sameOrigin(url, next)) group.next_len[index] = next.len;
    }
    if (count == 0) return;
    if (!group.published and !group.append) {
        state.app.opds.entry_count = 0;
        catalog_revision +%= 1;
    }
    const merged = pure.mergeGutenbergWorks(&state.app.opds.entries, state.app.opds.entry_count, rows[0..count]);
    if (merged == state.app.opds.entry_count) return;
    state.app.opds.entry_count = merged;
    group.published = true;
    discovery.active = true;
    if (!group.append) {
        discovery.count = group.count;
        discovery.categories = group.categories;
    }
    const title = "Project Gutenberg · Discover";
    @memcpy(state.app.opds.feed_title[0..title.len], title);
    state.app.opds.feed_title_len = title.len;
    state.app.opds.fetch_error = false;
    if (group.job.mark_connected) {
        state.app.opds.connected = true;
        state.markConfigDirty();
    }
    state.wakeUi();
}
fn discoveryMoreWorker(job: FeedJob, categories: [3]pure.OpdsEntry, count: usize) void {
    defer {
        if (fetch_request.isCurrent(job.generation)) loading_more.store(false, .release);
        state.wakeUi();
    }
    runGutenbergDiscovery(job, categories[0..count], true);
}

// ══════════════════════════════════════════════════════════
// HTTP
// ══════════════════════════════════════════════════════════

/// Build the "Authorization: Basic …" header line for the configured credentials
/// into `buf` (via the tested opds_pure.basicAuthHeader). Returns "" when no
/// credentials are set (an anonymous server) or on overflow. UI-thread only —
/// reads the credential buffers the login form owns.
fn opdsAuthHeader(buf: []u8) []const u8 {
    const snap = connectionSnapshot();
    const user = snap.user[0..snap.user_len];
    const pass = snap.pass[0..snap.pass_len];
    if (user.len == 0 and pass.len == 0) return "";
    return pure.basicAuthHeader(user, pass, buf) orelse "";
}

/// Bounded native HTTP with a supervised curl fallback for catalogs whose TLS
/// remains incompatible. Basic auth stays in-process or private stdin, never argv.
fn opdsGet(url: []const u8, user: []const u8, pass: []const u8) ?[]u8 {
    return opdsGetBounded(url, user, pass, 4 * 1024 * 1024, "15");
}
fn opdsGetBounded(url: []const u8, user: []const u8, pass: []const u8, cap: usize, timeout: []const u8) ?[]u8 {
    return opdsGetCancelled(url, user, pass, cap, timeout, null);
}
fn opdsGetCancelled(url: []const u8, user: []const u8, pass: []const u8, cap: usize, timeout: []const u8, cancellation: ?@import("../core/bounded_process.zig").CancelEpoch) ?[]u8 {
    var auth_buf: [512]u8 = undefined;
    const auth: ?[]const u8 = if (user.len > 0 or pass.len > 0) (pure.basicAuthHeader(user, pass, &auth_buf) orelse return null) else null;
    const seconds = std.fmt.parseInt(u8, timeout, 10) catch 8;
    const buffer = alloc.alloc(u8, cap) catch return null;
    var owned = false;
    defer if (!owned) alloc.free(buffer);
    if (@import("../core/http.zig").fetch(url, buffer, .{
        .timeout_secs = seconds,
        .max_response = cap,
        .cancel_epoch = cancellation,
        .accept = "application/atom+xml,application/xml",
        .auth_header = auth,
    })) |body| {
        if (body.len == 0) return null;
        const exact = alloc.realloc(buffer, body.len) catch return null;
        owned = true;
        return exact;
    }
    if (@import("../core/workers.zig").isQuitting() or @import("browse_fanout.zig").cancelled(cancellation)) return null;
    const bounded = @import("../core/bounded_process.zig");
    const io = @import("../core/io_global.zig");
    var process = bounded.StreamProcess.init(&.{
        "curl",       "-fsSL", "-H",                "Accept: application/atom+xml,application/xml",
        "--config",   "-",     "--connect-timeout", "3",
        "--max-time", timeout, "--",                url,
    }, .{ .timeout_ms = @as(i64, seconds) * 1000, .max_output_bytes = cap, .cancel_epoch = cancellation, .stdin_behavior = .Pipe });
    process.start() catch return null;
    defer _ = process.finish();
    if (auth) |line| {
        var escaped: [2048]u8 = undefined;
        const config_line = @import("../core/curl_secret.zig").configLine(line, &escaped) catch {
            process.requestStop();
            return null;
        };
        const stdin = if (process.child.stdin) |*pipe| pipe else {
            process.requestStop();
            return null;
        };
        io.writeAll(stdin, config_line) catch {
            process.requestStop();
            return null;
        };
    }
    process.child.closeStdin();
    const stdout = process.stdout() orelse return null;
    var length: usize = 0;
    while (length < buffer.len) {
        const count = io.read(stdout, buffer[length..]) catch {
            process.requestStop();
            return null;
        };
        if (count == 0) break;
        if (!process.noteOutput(count)) return null;
        length += count;
    }
    if (length == buffer.len) {
        var extra: [1]u8 = undefined;
        const count = io.read(stdout, &extra) catch 1;
        if (count != 0) {
            _ = process.noteOutput(count);
            process.requestStop();
            return null;
        }
    }
    if (!process.finish().ok() or length == 0) return null;
    const exact = alloc.realloc(buffer, length) catch return null;
    owned = true;
    return exact;
}

const CoverFetchArgs = struct {
    url: [512]u8,
    url_len: usize,
    user: [128]u8,
    user_len: usize,
    pass: [128]u8,
    pass_len: usize,
    pixels: *?[]u8,
    w: *u32,
    h: *u32,
    fetching: *bool,
};

/// OPDS covers often require the catalog's Basic auth. Keep that credential in
/// curl stdin through opdsGet rather than falling back to an unauthenticated
/// generic image request or exposing it in process arguments.
fn fetchCoverAsync(url: []const u8, slot: *components.CoverSlot) void {
    if (url.len == 0 or url.len > 512 or slot.fetching or !poster.tryClaimSlot()) return;
    var args = CoverFetchArgs{
        .url = undefined,
        .url_len = url.len,
        .user = std.mem.zeroes([128]u8),
        .user_len = 0,
        .pass = std.mem.zeroes([128]u8),
        .pass_len = 0,
        .pixels = &slot.pixels,
        .w = &slot.w,
        .h = &slot.h,
        .fetching = &slot.fetching,
    };
    @memcpy(args.url[0..url.len], url);
    const snap = connectionSnapshot();
    const same_origin = pure.sameOrigin(snap.server[0..snap.server_len], url);
    const user = if (same_origin) snap.user[0..snap.user_len] else "";
    const pass = if (same_origin) snap.pass[0..snap.pass_len] else "";
    args.user_len = @min(user.len, args.user.len);
    args.pass_len = @min(pass.len, args.pass.len);
    @memcpy(args.user[0..args.user_len], user[0..args.user_len]);
    @memcpy(args.pass[0..args.pass_len], pass[0..args.pass_len]);
    slot.fetching = true;
    slot.attempted = true;
    @import("../core/workers.zig").spawn(struct {
        fn run(a: CoverFetchArgs) void {
            defer {
                a.fetching.* = false;
                poster.releaseSlot();
                state.wakeUi();
            }
            if (@import("../core/workers.zig").isQuitting()) return;
            const url_slice = a.url[0..a.url_len];
            const cached = poster.cacheLoadForUrl(url_slice);
            defer if (cached) |bytes| poster.cacheFreeEncoded(bytes);
            var downloaded: ?[]u8 = null;
            defer if (downloaded) |bytes| alloc.free(bytes);

            var decoded: ?poster.DecodedCover = null;
            if (cached) |bytes| {
                decoded = poster.decodeCover(bytes);
                if (decoded == null) poster.cacheDeleteForUrl(url_slice);
            }
            if (decoded == null) {
                downloaded = opdsGet(url_slice, a.user[0..a.user_len], a.pass[0..a.pass_len]);
                const bytes = downloaded orelse return;
                decoded = poster.decodeCover(bytes) orelse return;
                poster.cacheStoreForUrl(url_slice, bytes, @intCast(decoded.?.width), @intCast(decoded.?.height));
            }
            const cover = decoded.?;
            defer cover.deinit();
            const copy = c_alloc.alloc(u8, cover.rgba_len) catch return;
            @memcpy(copy, cover.pixels[0..cover.rgba_len]);
            if (@import("../core/workers.zig").isQuitting()) {
                c_alloc.free(copy);
                return;
            }
            a.w.* = @intCast(cover.width);
            a.h.* = @intCast(cover.height);
            a.pixels.* = copy;
        }
    }.run, .{args}) catch {
        slot.fetching = false;
        poster.releaseSlot();
    };
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
const FeedJob = struct {
    url: [512]u8 = std.mem.zeroes([512]u8),
    url_len: usize = 0,
    user: [128]u8 = std.mem.zeroes([128]u8),
    pass: [128]u8 = std.mem.zeroes([128]u8),
    mark_connected: bool = false,
    generation: u32 = 0,
};

fn publishFetchError(gen: u32, msg: []const u8) void {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!fetch_request.isCurrent(gen)) return;
    setError(msg);
    state.wakeUi();
}

fn fetchFeedSync(job: FeedJob) void {
    const my_gen = job.generation;
    const mark_connected = job.mark_connected;
    const url = job.url[0..job.url_len];
    const user = job.user[0 .. std.mem.indexOfScalar(u8, &job.user, 0) orelse job.user.len];
    const pass = job.pass[0 .. std.mem.indexOfScalar(u8, &job.pass, 0) orelse job.pass.len];

    if (url.len == 0) {
        publishFetchError(my_gen, "Catalog URL is empty");
        state.wakeUi();
        return;
    }

    const body = opdsGetCancelled(url, user, pass, 4 * 1024 * 1024, "10", .{ .epoch32 = .{ .value = &fetch_request.generation, .expected = my_gen } }) orelse {
        publishFetchError(my_gen, "Could not load the OPDS server — check its URL, credentials or response size");
        state.wakeUi();
        return;
    };
    defer alloc.free(body);
    if (!pure.isCompleteFeed(body)) {
        publishFetchError(my_gen, "The server did not return a complete OPDS 1.x Atom feed");
        return;
    }

    const sections = alloc.alloc(pure.OpdsEntry, 3) catch return;
    defer alloc.free(sections);
    const section_count = pure.gutenbergSections(body, url, sections);
    if (section_count > 0) {
        runGutenbergDiscovery(job, sections[0..section_count], false);
        return;
    }

    // A newer navigation (another connect/openFeed/goBack) superseded this
    // in-flight request — drop the stale result rather than clobber the feed
    // the user has since moved to (mirrors drama.zig's fetch_gen guard).
    if (fetch_request.current() != my_gen) return;

    // Publish under the mutex: title first, entries, then entry_count LAST so a
    // concurrent UI read never sees a count ahead of the data.
    parse_mutex.lock();
    if (fetch_request.current() != my_gen) {
        parse_mutex.unlock();
        return;
    } // re-check under the lock
    const title = safeUtf8(pure.feedTitle(body));
    const tl = @min(title.len, state.app.opds.feed_title.len);
    @memcpy(state.app.opds.feed_title[0..tl], title[0..tl]);
    state.app.opds.feed_title_len = tl;
    const n = pure.parseFeed(body, url, &state.app.opds.entries);
    state.app.opds.entry_count = n;
    catalog_revision +%= 1;
    discovery.active = false;
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
    state.app.opds.fetch_error = false;
    if (mark_connected) {
        state.app.opds.connected = true;
        state.markConfigDirty();
    }
    parse_mutex.unlock();
    logs.pushLog("info", "opds", "OPDS feed loaded", false);
    state.wakeUi();
}

/// Spawn the detached fetch worker for the current feed URL.
fn spawnFetch(mark_connected: bool) void {
    if (@import("builtin").is_test and loading_fixture_for_test) return;
    // Snapshot before spawning: navigation and credentials may change while
    // an older request is still waiting for its response.
    var job: FeedJob = .{ .mark_connected = mark_connected };
    parse_mutex.lock();
    job.url_len = @min(state.app.opds.current_url_len, job.url.len);
    @memcpy(job.url[0..job.url_len], state.app.opds.current_url[0..job.url_len]);
    if (pure.sameOrigin(configured_connection.server[0..configured_connection.server_len], job.url[0..job.url_len])) {
        job.user = configured_connection.user;
        job.pass = configured_connection.pass;
    }
    job.generation = fetch_request.begin(&state.app.opds.is_loading);
    state.app.opds.fetch_error = false;
    discovery.active = false;
    loading_more.store(false, .release);
    parse_mutex.unlock();
    state.app.opds.thread = @import("../core/workers.zig").spawnLegacy(struct {
        fn worker(request: FeedJob) void {
            defer fetch_request.finish(request.generation, &state.app.opds.is_loading);
            fetchFeedSync(request);
            state.wakeUi();
        }
    }.worker, .{job}) catch blk: {
        fetch_request.finish(job.generation, &state.app.opds.is_loading);
        publishFetchError(job.generation, "Could not start the OPDS request");
        break :blk null;
    };
    if (state.app.opds.thread) |t| @import("../core/workers.zig").release(t);
}

// ══════════════════════════════════════════════════════════
// Infinite scroll — fetch + append the feed's rel="next" page
// ══════════════════════════════════════════════════════════

/// Infinite-scroll appender: fetch the current feed's rel="next" page and
/// merge its entries onto the existing list. Guarded by `loading_more` + the
/// main `is_loading` atomic so a near-bottom scroll can't spawn a burst;
/// no-op once `more_available` clears — which happens the moment a feed has
/// no rel="next" link (set by fetchFeedSync/fetchMoreSync), the fixed 300-entry buffer fills. Errors pause automatic paging until retry. Runs under the current
/// request generation so a fresh feed navigation (connect/openFeed/goBack) supersedes
/// it. Mirrors services/drama.zig's loadMore.
pub fn loadMore() void {
    parse_mutex.lock();
    if (!more_available or state.app.opds.is_loading.load(.acquire) or
        state.app.opds.fetch_error or state.app.opds.entry_count == 0 or
        state.app.opds.entry_count >= state.app.opds.entries.len)
    {
        parse_mutex.unlock();
        return;
    }
    if (loading_more.swap(true, .acq_rel)) {
        parse_mutex.unlock();
        return;
    }
    if (discovery.active) {
        const job: FeedJob = .{ .generation = fetch_request.current() };
        var categories = discovery.categories;
        for (categories[0..discovery.count], 0..) |*category, index| {
            category.href_len = discovery_next_len[index];
            @memcpy(category.href[0..category.href_len], discovery_next[index][0..category.href_len]);
        }
        const count = discovery.count;
        parse_mutex.unlock();
        if (@import("../core/workers.zig").spawnLegacy(discoveryMoreWorker, .{ job, categories, count })) |thread| {
            @import("../core/workers.zig").release(thread);
        } else |_| loading_more.store(false, .release);
        return;
    }
    var job: FeedJob = .{ .generation = fetch_request.current() };
    job.url_len = @min(next_href_len, job.url.len);
    @memcpy(job.url[0..job.url_len], next_href_buf[0..job.url_len]);
    if (pure.sameOrigin(configured_connection.server[0..configured_connection.server_len], job.url[0..job.url_len])) {
        job.user = configured_connection.user;
        job.pass = configured_connection.pass;
    }
    parse_mutex.unlock();
    if (@import("../core/workers.zig").spawnLegacy(loadMoreWorker, .{job})) |t| {
        @import("../core/workers.zig").release(t);
    } else |_| {
        loading_more.store(false, .release);
        publishFetchError(job.generation, "Could not start the next OPDS page request");
    }
}

fn loadMoreWorker(job: FeedJob) void {
    defer loading_more.store(false, .release);
    fetchMoreSync(job);
}

/// Append a continuation using the URL and credentials captured at launch.
fn fetchMoreSync(job: FeedJob) void {
    const my_gen = job.generation;
    const url = job.url[0..job.url_len];
    if (url.len == 0 or fetch_request.current() != my_gen) return;
    const user = job.user[0 .. std.mem.indexOfScalar(u8, &job.user, 0) orelse job.user.len];
    const pass = job.pass[0 .. std.mem.indexOfScalar(u8, &job.pass, 0) orelse job.pass.len];

    const body = opdsGetCancelled(url, user, pass, 4 * 1024 * 1024, "10", .{ .epoch32 = .{ .value = &fetch_request.generation, .expected = my_gen } }) orelse {
        logs.pushLog("error", "opds", "Load-more fetch failed", true);
        publishFetchError(my_gen, "Could not load the next OPDS page. Retry to refresh the catalog.");
        state.wakeUi();
        return;
    };
    defer alloc.free(body);
    if (!pure.isCompleteFeed(body)) {
        publishFetchError(my_gen, "The next OPDS page was incomplete or invalid. Retry to refresh.");
        return;
    }

    // A fresh feed navigation superseded this append — drop it rather than
    // append the old feed's continuation onto the new feed's entries.
    if (fetch_request.current() != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (fetch_request.current() != my_gen) return; // re-check under the lock

    const base = state.app.opds.entry_count;
    const cap = state.app.opds.entries.len;
    if (base >= cap) {
        more_available = false;
        return;
    }
    const staged = alloc.alloc(pure.OpdsEntry, cap) catch {
        setError("Not enough memory for the next OPDS page");
        return;
    };
    defer alloc.free(staged);
    const n = pure.parseFeed(body, url, staged);
    var count = base;
    for (staged[0..n]) |entry| {
        var duplicate = false;
        for (state.app.opds.entries[0..count]) |existing| {
            if (std.mem.eql(u8, existing.href[0..existing.href_len], entry.href[0..entry.href_len])) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        if (count >= cap) break;
        state.app.opds.entries[count] = entry;
        count += 1;
    }
    state.app.opds.entry_count = count;

    if (pure.feedNextHref(body, url, &next_href_buf)) |next| {
        next_href_len = next.len;
        more_available = state.app.opds.entry_count < cap and !std.mem.eql(u8, next, url);
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
    configureConnection(state.app.opds.server_url[0..state.app.opds.server_url_len], state.app.opds.user_buf[0 .. std.mem.indexOfScalar(u8, &state.app.opds.user_buf, 0) orelse state.app.opds.user_buf.len], state.app.opds.pass_buf[0 .. std.mem.indexOfScalar(u8, &state.app.opds.pass_buf, 0) orelse state.app.opds.pass_buf.len]);
    state.app.opds.nav_depth = 0;
    // current_url := server_url (catalog root).
    const n = @min(state.app.opds.server_url_len, state.app.opds.current_url.len);
    @memcpy(state.app.opds.current_url[0..n], state.app.opds.server_url[0..n]);
    state.app.opds.current_url_len = n;
    state.app.opds.feed_title_len = 0;
    restored_fetch_attempted.store(true, .release);
    spawnFetch(true);
}

/// Start the root feed after a persisted connected session is restored. Safe
/// to call from every desktop frame and companion GET; only one caller wins.
pub fn ensureLoadedOnce() void {
    if (@import("builtin").is_test and loading_fixture_for_test) return;
    if (!state.app.opds.connected or state.app.opds.server_url_len == 0) return;
    if (entryCount() > 0 or state.app.opds.is_loading.load(.acquire)) return;
    if (restored_fetch_attempted.swap(true, .acq_rel)) return;
    if (state.app.opds.current_url_len == 0) {
        const n = @min(state.app.opds.server_url_len, state.app.opds.current_url.len);
        @memcpy(state.app.opds.current_url[0..n], state.app.opds.server_url[0..n]);
        state.app.opds.current_url_len = n;
    }
    spawnFetch(false);
}

/// Explicit retry for a failed restored or navigated feed.
pub fn retry() void {
    if (state.app.opds.current_url_len == 0) {
        const n = @min(state.app.opds.server_url_len, state.app.opds.current_url.len);
        @memcpy(state.app.opds.current_url[0..n], state.app.opds.server_url[0..n]);
        state.app.opds.current_url_len = n;
    }
    restored_fetch_attempted.store(true, .release);
    spawnFetch(false);
}

pub const SearchResult = struct {
    count: usize = 0,
    status: @import("resolver_lifecycle_pure.zig").SourceStatus = .no_results,
    connection_identity: u64 = 0,
};

/// Query only an advertised search facility; never filter the visible feed.
pub fn searchInto(query: []const u8, out: []pure.OpdsEntry) SearchResult {
    const snap = connectionSnapshot();
    if (!snap.connected or snap.server_len == 0) return .{ .status = .unavailable };
    if (query.len == 0 or out.len == 0) return .{};
    const root = snap.server[0..snap.server_len];
    const body = opdsGetBounded(root, snap.user[0..snap.user_len], snap.pass[0..snap.pass_len], 1024 * 1024, "8") orelse return .{ .status = .transport_failed };
    defer alloc.free(body);
    if (!pure.isCompleteFeed(body)) return .{ .status = .parse_failed };
    const link = pure.feedSearchLink(body, root) orelse {
        logs.pushLog("info", "opds", "This catalog does not advertise a supported OPDS search facility", false);
        return .{ .status = .unavailable };
    };
    var url_buf: [3072]u8 = undefined;
    const href = link.url[0..link.url_len];
    var search_url: []const u8 = undefined;
    if (link.description) {
        const with_auth = pure.sameOrigin(root, href);
        const description = opdsGetBounded(href, if (with_auth) snap.user[0..snap.user_len] else "", if (with_auth) snap.pass[0..snap.pass_len] else "", 128 * 1024, "8") orelse return .{ .status = .transport_failed };
        defer alloc.free(description);
        search_url = pure.openSearchUrl(description, href, query, &url_buf) orelse return .{ .status = .unavailable };
    } else {
        search_url = pure.expandSearchTemplate(href, query, &url_buf) orelse return .{ .status = .unavailable };
    }
    const with_auth = pure.sameOrigin(root, search_url);
    const results = opdsGetBounded(search_url, if (with_auth) snap.user[0..snap.user_len] else "", if (with_auth) snap.pass[0..snap.pass_len] else "", 1024 * 1024, "8") orelse return .{ .status = .transport_failed };
    defer alloc.free(results);
    if (!pure.isCompleteFeed(results)) return .{ .status = .parse_failed };
    if (connectionSnapshot().identity != snap.identity) return .{ .status = .unavailable };
    const count = pure.parseFeed(results, search_url, out);
    return .{ .count = count, .status = if (count > 0) .done else .no_results, .connection_identity = snap.identity };
}

pub fn entryCount() usize {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    return @min(state.app.opds.entry_count, state.app.opds.entries.len);
}

pub fn entryRow(idx: usize) ?pure.OpdsEntry {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (idx >= state.app.opds.entry_count or idx >= state.app.opds.entries.len) return null;
    return state.app.opds.entries[idx];
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
const EntryAction = struct { row: pure.OpdsEntry, connection_identity: u64 };
fn copiedEntryAction(index: usize, expected: ?u32) ?EntryAction {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (expected) |generation| if (generation != catalog_revision) return null;
    if (index >= state.app.opds.entry_count or index >= state.app.opds.entries.len) return null;
    return .{ .row = state.app.opds.entries[index], .connection_identity = configured_connection.identity };
}
pub fn openEntryExpected(index: usize, expected: u32) bool {
    const action = copiedEntryAction(index, expected) orelse return false;
    openCatalogEntry(action.row, action.connection_identity);
    return true;
}
pub fn openEntry(index: usize) void {
    const action = copiedEntryAction(index, null) orelse return;
    openCatalogEntry(action.row, action.connection_identity);
}

pub fn openCatalogEntry(row: pure.OpdsEntry, connection_identity: u64) void {
    const snap = connectionSnapshot();
    if (!snap.connected or snap.identity != connection_identity) {
        state.showToastTyped("OPDS connection changed. Search this catalog again.", .warning);
        return;
    }
    const e = &row;
    const href = e.hrefSlice();
    if (href.len == 0) return;

    if (pure.gutenbergWorkId(href)) |id| {
        @import("novels.zig").openCatalogResult(@intFromEnum(@import("novel_sources_pure.zig").NovelSource.gutenberg), e.titleSlice(), id);
        state.navigateToTab(.Novels);
        return;
    }
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
                const auth = if (pure.sameOrigin(snap.server[0..snap.server_len], e.pseUrlSlice()))
                    pure.basicAuthHeader(snap.user[0..snap.user_len], snap.pass[0..snap.pass_len], &auth_buf) orelse ""
                else
                    "";
                @import("comics.zig").loadPseBook(e.titleSlice(), e.pseUrlSlice(), e.pse_count, auth);
                state.navigateToTab(.Comics);
                state.showToast("Streaming pages…");
            } else if (std.mem.startsWith(u8, e.contentTypeSlice(), "image/")) {
                @import("comics.zig").requestLoad(href);
                state.navigateToTab(.Comics);
                state.showToast("Opening in reader");
            } else {
                @import("../ui/settings.zig").openExternal(href);
                state.showToast("This catalog offers an archive. Opening externally.");
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
    fetch_request.cancel(&state.app.opds.is_loading); // supersede any in-flight fetch/append
    parse_mutex.lock();
    state.app.opds.entry_count = 0;
    catalog_revision +%= 1;
    discovery.active = false;
    more_available = true;
    next_href_len = 0;
    state.app.opds.connected = false;
    parse_mutex.unlock();
    state.app.opds.nav_depth = 0;
    state.app.opds.feed_title_len = 0;
    state.app.opds.current_url_len = 0;
    restored_fetch_attempted.store(false, .release);
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
    ensureLoadedOnce();
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

        if (components.iconButtonEx(@src(), icons.tvg.lucide.@"arrow-left", "Back", false, state.app.opds.nav_depth > 0)) goBack();

        const title = state.app.opds.feed_title[0..state.app.opds.feed_title_len];
        _ = dvui.label(@src(), "{s}", .{if (title.len > 0) safeUtf8(title) else "Library"}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_heading,
            .gravity_y = 0.5,
            .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
        });

        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        if (components.iconButton(@src(), icons.tvg.lucide.@"log-out", "Disconnect reading server", false)) disconnect();
    }

    const categories = discoverySnapshot();
    if (categories.active) {
        var row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .padding = dvui.Rect.all(8) });
        defer row.deinit();
        _ = dvui.label(@src(), "Discover", .{}, .{ .color_text = theme.colors.accent, .gravity_y = 0.5 });
        for (categories.categories[0..categories.count], 0..) |category, index| {
            if (dvui.button(@src(), category.titleSlice(), .{}, .{ .id_extra = index, .color_fill = theme.colors.bg_elevated, .color_text = theme.colors.text_secondary })) _ = openDiscoveryCategory(index);
        }
    }

    if (state.app.opds.is_loading.load(.acquire)) {
        dvui.spinner(@src(), .{
            .color_text = theme.colors.accent,
            .min_size_content = theme.iconSize(.md),
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(8),
        });
    }

    if (state.app.opds.fetch_error and !state.app.opds.is_loading.load(.acquire)) {
        const msg = state.app.opds.error_msg[0..@min(state.app.opds.error_msg_len, state.app.opds.error_msg.len)];
        _ = dvui.label(@src(), "{s}", .{if (msg.len > 0) safeUtf8(msg) else "Could not load this catalog."}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 16, .y = 8, .w = 16, .h = 6 },
        });
        if (dvui.button(@src(), "Retry", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = theme.colors.text_on_accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .margin = .{ .x = 16, .y = 0, .w = 0, .h = 8 },
        })) retry();
        if (entryCount() == 0) return;
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
        components.emptyState(icons.tvg.lucide.library, "This shelf is empty", "Open another catalog or add books on your reading server.");
        return;
    }

    const bounded_count = @min(count, state.app.opds.entries.len);
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(1, @as(usize, @intFromFloat(avail_w / OPDS_CARD_TARGET_W)));
    const cols_f: f32 = @floatFromInt(cols);
    const card_w: f32 = @max(104, (avail_w - cols_f * 2 * OPDS_CARD_GAP) / cols_f);
    const poster_h = card_w * 1.45;
    const row_h = poster_h + OPDS_CARD_FOOTER_H + 2 * OPDS_CARD_GAP;
    if (bounded_count == 0) {
        components.coverSkeletonGrid(@src(), 88000, cols, card_w, poster_h, OPDS_CARD_FOOTER_H, 3);
        return;
    }
    const total_rows = (bounded_count + cols - 1) / cols;
    const win = tmdb_pure.visibleRows(total_rows, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 2);
    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 89998,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) },
        });
        sp.deinit();
    }
    var r: usize = win.first;
    while (r < win.last) : (r += 1) {
        const base = r * cols;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = base + 89000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and base + col < bounded_count) : (col += 1)
            renderEntryCard(base + col, card_w, poster_h);
    }
    if (win.last < total_rows) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 89999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(total_rows - win.last)) },
        });
        sp.deinit();
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
            state.wakeUi(); // wake until the worker's items land
        }
    }
}

fn renderEntryCard(idx: usize, card_w: f32, poster_h: f32) void {
    const action = copiedEntryAction(idx, null) orelse return;
    const e = &action.row;
    const gutenberg = pure.gutenbergWorkId(e.hrefSlice()) != null;
    const fallback = if (e.is_navigation and !gutenberg) icons.tvg.lucide.folder else icons.tvg.lucide.@"book-open";
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx + 90000,
        .min_size_content = .{ .w = card_w, .h = poster_h + OPDS_CARD_FOOTER_H },
        .max_size_content = .{ .w = card_w, .h = poster_h + OPDS_CARD_FOOTER_H },
        .margin = dvui.Rect.all(OPDS_CARD_GAP),
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_fill_hover = theme.colors.bg_hover,
        .corner_radius = dvui.Rect.all(theme.radius.md),
    });
    defer card.deinit();

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = idx + 90100,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .min_size_content = .{ .w = card_w, .h = poster_h },
        .max_size_content = .{ .w = card_w, .h = poster_h },
        .padding = dvui.Rect.all(0),
    });
    bw.processEvents();
    bw.drawBackground();
    const cover_url = e.coverSlice();
    const slot = &entry_covers[idx];
    components.syncCoverSlot(slot, cover_url);
    components.pollCoverSlot(slot);
    if (cover_url.len > 0 and !slot.failed and slot.tex == null and slot.pixels == null and !slot.fetching)
        fetchCoverAsync(cover_url, slot);
    components.renderCoverSlot(@src(), idx + 90200, slot, cover_url.len > 0, fallback, theme.radius.md);
    const clicked = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    if (clicked) openCatalogEntry(action.row, action.connection_identity);

    _ = dvui.label(@src(), "{s}", .{safeUtf8(e.titleSlice())}, .{
        .id_extra = idx + 90300,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading.withSize(theme.font_size.small),
        .min_size_content = .{ .w = card_w, .h = 22 },
        .max_size_content = .{ .w = card_w, .h = 22 },
        .padding = .{ .x = 5, .y = 5, .w = 5, .h = 0 },
    });
    const subtitle: []const u8 = if (gutenberg)
        (if (e.author_len > 0) e.author[0..e.author_len] else "Project Gutenberg")
    else if (e.is_navigation)
        "Collection"
    else switch (pure.readerRoute(e.contentTypeSlice())) {
        .comics => "Comic / manga",
        .external => "Ebook",
        .unsupported => "Download",
    };
    var meta = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = idx + 90400, .expand = .horizontal, .padding = .{ .x = 5, .y = 0, .w = 3, .h = 3 } });
    defer meta.deinit();
    _ = dvui.label(@src(), "{s}", .{subtitle}, .{ .id_extra = idx + 90500, .color_text = theme.colors.text_tertiary, .expand = .horizontal, .gravity_y = 0.5 });
    if (components.iconButton(@src(), if (e.is_navigation and !gutenberg) icons.tvg.lucide.@"folder-open" else icons.tvg.lucide.@"book-open", if (e.is_navigation and !gutenberg) "Open" else "Read", true))
        openCatalogEntry(action.row, action.connection_identity);
}

/// Real local HTTP fixture exercises production fanout/publication without
/// contacting the publisher or installing any profile configuration.
pub fn verifyGutenbergProgressiveForTest() !void {
    if (!@import("builtin").is_test) @compileError("Native Gutenberg fixture is test-only");
    const io = @import("../core/io_global.zig");
    const workers = @import("../core/workers.zig");
    workers.init();
    defer workers.finishShutdown();
    defer workers.beginShutdownAndDrain(800);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var release: std.atomic.Value(bool) = .init(false);
    var seen: std.atomic.Value(u32) = .init(0);
    const Fixture = struct {
        fn response(listener: *std.Io.net.Server, gate: *std.atomic.Value(bool), count: *std.atomic.Value(u32)) void {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            var read_buffer: [2048]u8 = undefined;
            var reader = stream.reader(io.io(), &read_buffer);
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            const slow = std.mem.indexOf(u8, line, "/slow ") != null;
            const duplicate = std.mem.indexOf(u8, line, "/duplicate ") != null;
            while (true) {
                const header = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (std.mem.eql(u8, header, "\r\n")) break;
            }
            _ = count.fetchAdd(1, .acq_rel);
            const start = io.monotonicMilliTimestamp();
            while (slow and !gate.load(.acquire) and io.monotonicMilliTimestamp() - start < 4000) io.sleep(std.time.ns_per_ms);
            const body = if (slow)
                "<feed><entry><title>Slow work</title><link rel='subsection' href='https://www.gutenberg.org/ebooks/11.opds'/></entry></feed>"
            else if (duplicate)
                "<feed><entry><title>Shared work</title><link rel='subsection' href='https://www.gutenberg.org/ebooks/84.opds'/></entry></feed>"
            else
                "<feed><entry><title>Fast work</title><link rel='subsection' href='https://www.gutenberg.org/ebooks/84.opds'/></entry></feed>";
            var output: [2048]u8 = undefined;
            var writer = stream.writer(io.io(), &output);
            writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
            writer.interface.flush() catch {};
        }
        fn run(job: FeedJob, sections: [3]pure.OpdsEntry, done: *std.atomic.Value(bool)) void {
            runGutenbergDiscovery(job, &sections, false);
            done.store(true, .release);
        }
    };
    var requests: [3]?std.Io.Future(void) = .{ null, null, null };
    defer {
        release.store(true, .release);
        for (&requests) |*request| if (request.*) |*owned| {
            _ = owned.cancel(io.io());
        };
    }
    for (&requests) |*request| request.* = try io.io().concurrent(Fixture.response, .{ &server, &release, &seen });
    var sections: [3]pure.OpdsEntry = undefined;
    for ([_][]const u8{ "fast", "slow", "duplicate" }, 0..) |path, index| {
        sections[index] = .{};
        const url = try std.fmt.bufPrint(&sections[index].href, "http://127.0.0.1:{d}/{s}", .{ server.socket.address.getPort(), path });
        sections[index].href_len = url.len;
    }
    const generation = fetch_request.begin(&state.app.opds.is_loading);
    defer fetch_request.cancel(&state.app.opds.is_loading);
    var done: std.atomic.Value(bool) = .init(false);
    const job: FeedJob = .{ .generation = generation };
    const coordinator = try std.Thread.spawn(.{}, Fixture.run, .{ job, sections, &done });
    defer {
        release.store(true, .release);
        coordinator.join();
    }
    const start = io.monotonicMilliTimestamp();
    while ((seen.load(.acquire) < 3 or entryCount() == 0) and io.monotonicMilliTimestamp() - start < 3000) io.sleep(std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 3), seen.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), entryCount());
    try std.testing.expect(!done.load(.acquire));
    try std.testing.expect(state.app.opds.is_loading.load(.acquire));
    release.store(true, .release);
    while (!done.load(.acquire) and io.monotonicMilliTimestamp() - start < 4000) io.sleep(std.time.ns_per_ms);
    try std.testing.expect(done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), entryCount());
    try std.testing.expect(discoverySnapshot().active);
    const version = catalogGeneration();
    try std.testing.expect(copiedEntryAction(0, version) != null);
    try std.testing.expect(!openEntryExpected(0, version +% 1));
    parse_mutex.lock();
    catalog_revision +%= 1; // Replacement publication, even within the same fetch epoch.
    parse_mutex.unlock();
    try std.testing.expect(!openEntryExpected(0, version));
    parse_mutex.lock();
    state.app.opds.entry_count = 0;
    discovery = .{};
    parse_mutex.unlock();
}
