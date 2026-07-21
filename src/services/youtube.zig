const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const io = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const tmdb_pure = @import("tmdb_pure.zig"); // unit-tested grid virtualization (visibleRows)
const yt_pure = @import("youtube_pure.zig"); // unit-tested URL/format/suggestion helpers
const it_pure = @import("youtube_innertube_pure.zig"); // unit-tested InnerTube body/parse helpers
const content_cache = @import("../core/content_cache.zig");
const ccp = @import("../core/content_cache_pure.zig");

pub const alloc = @import("../core/alloc.zig").allocator;

const safeUtf8 = @import("../core/text.zig").safeUtf8;

var yt_mutex: @import("../core/sync.zig").Mutex = .{};
// Seamless refresh: instead of clearing results up-front (which blanks the
// grid for the whole ~3s fetch), the worker arms this and the first new item
// to arrive clears the old ones — so a stale-refresh swaps in place.
var pending_clear: bool = false;

// On re-search, appendYt (worker thread) drops the old results via
// clearRetainingCapacity — but those YtItems own a GPU thumb_tex + heap
// thumb_pixels that would otherwise leak. dvui.textureDestroyLater is UI-thread
// only, so the worker queues the old textures here and renderContent drains them.
var pending_tex_free: [512]dvui.Texture = undefined;
var pending_tex_free_count: usize = 0;
var pending_tex_free_mutex: @import("../core/sync.zig").Mutex = .{};

fn queueYtTexFree(tex: dvui.Texture) void {
    pending_tex_free_mutex.lock();
    defer pending_tex_free_mutex.unlock();
    if (pending_tex_free_count < pending_tex_free.len) {
        pending_tex_free[pending_tex_free_count] = tex;
        pending_tex_free_count += 1;
    }
}

/// Destroy queued thumbnail textures. UI-THREAD ONLY — call once per frame.
fn drainYtTexFrees() void {
    pending_tex_free_mutex.lock();
    defer pending_tex_free_mutex.unlock();
    for (pending_tex_free[0..pending_tex_free_count]) |t| dvui.textureDestroyLater(t);
    pending_tex_free_count = 0;
}

// ── Publish dates (parallel to state.app.yt.results) ──
// YtItem can't be extended, so the upload_date (YYYYMMDD) for each result lives
// here, kept index-aligned with results: appended in appendYt(), cleared by the
// same lazy-clear so a stale-refresh swaps it in place too. Guarded by yt_mutex
// (every reader/writer below already holds it).
var dates: std.ArrayListUnmanaged([8]u8) = .empty;
var dates_lens: std.ArrayListUnmanaged(u8) = .empty;
// Staging for the date of the item currently being parsed (parseYtdlpLine /
// parsePipedResults fill this just before calling appendYt).
var staged_date: [8]u8 = std.mem.zeroes([8]u8);
var staged_date_len: u8 = 0;

// ── Live / incremental search ──
// Debounced search-as-you-type. The UI thread records the last keystroke time;
// once the buffer has been stable for the debounce window it auto-fires.
var last_edit_ms: i64 = 0;
var last_fired_query: [256]u8 = std.mem.zeroes([256]u8);
var last_fired_len: usize = 0;
// Buffer contents observed on the previous frame — used to detect a keystroke
// (buffer changed) so the debounce window measures *inactivity*, not total time.
var last_seen_query: [256]u8 = std.mem.zeroes([256]u8);
var last_seen_len: usize = 0;
// Monotonic search generation. Each fetch captures the value at spawn time; a
// worker that finds itself superseded (a newer search bumped this) discards its
// results instead of racing them onto the grid out of order.
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
const DEBOUNCE_MS: i64 = 400;

// ── UI controls (module-level, not in state.zig) ──
var card_w: f32 = 200; // user-cyclable card width, clamp 150..360
const CARD_MIN: f32 = 150;
const CARD_MAX: f32 = 360;

/// The card title font. Heading WEIGHT at body SIZE — compact, and small enough
/// that a two-line title stays short. cardFooterH() MUST measure the SAME font.
fn titleFont() dvui.Font {
    return dvui.themeGet().font_heading.withSize(theme.font_size.body);
}

/// A small, always-visible icon button stuck to a card thumbnail (Play / Queue).
/// Anchored to the thumbnail, NOT the footer, so it can never be clipped by a
/// tall title. Icon-only, no text. `accent` fills it with the accent colour (the
/// primary Play affordance); otherwise a dark scrim keeps a secondary action
/// legible on any thumbnail. Returns true when clicked.
fn thumbActionIcon(id: usize, icon: []const u8, accent: bool) bool {
    return dvui.buttonIcon(@src(), "ytact", icon, .{}, .{}, .{
        .id_extra = id,
        .color_text = if (accent) dvui.Color.black else dvui.Color.white,
        .color_fill = if (accent) theme.colors.accent else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 175 },
        .color_fill_hover = theme.colors.accent,
        .corner_radius = dvui.Rect.all(16),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(5),
        .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
    });
}

/// Card footer height below the 16:9 thumbnail — holds the (always-reserved)
/// 2-line title and the channel + "views · date" meta lines. Referenced by BOTH
/// the uniform card sizing (renderCard pins min==max = thumb_h + this) AND the
/// grid's virtualization row pitch, so the spacer math and the card can never
/// drift (mirrors tmdb.zig/comics.zig).
///
/// The Play/Queue buttons are NO LONGER in the footer — they're icon buttons
/// stuck to the thumbnail (see thumbActionIcon), independent of this height, so a
/// tall title can never clip them. The footer therefore only reserves the two
/// text blocks, from LIVE font metrics so it scales with the UI. Must be called
/// inside a frame (themeGet needs a live window).
fn cardFooterH() f32 {
    const title = titleFont(); // MUST match the label's font (see titleFont)
    const meta = metaFont(); // channel + views·date lines
    const info_pad_top: f32 = 5; // info box top padding
    const title_h: f32 = 2.0 * title.lineHeight(); // ALWAYS reserve 2 title lines
    const meta_h: f32 = 3.0 + 2.0 * meta.lineHeight(); // meta box top pad + 2 lines
    return @ceil(info_pad_top + title_h + meta_h + 6.0); // small slack
}

/// Compact font for the channel + views·date lines under the title.
fn metaFont() dvui.Font {
    return dvui.themeGet().font_body.withSize(theme.font_size.small);
}

// ── Infinite scroll / load-more ──
// yt-dlp's flat search has no page cursor, so we re-run `ytsearch{N}:` with a
// larger N and append only the rows past what's already on screen (deduped by
// video_id). `loaded_count` is how many we've asked for so far; `loading_more`
// gates the auto-fetch so a near-bottom scroll doesn't spam fetches.
const PAGE_SIZE: usize = 20;
const ITEM_CAP: usize = 200; // below the 256 reserved capacity → appends never realloc
var loaded_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
// The query the current result set is paged on — captured at first fetch so
// load-more re-runs the right search even if the text box changes mid-scroll.
var paged_query: [256]u8 = std.mem.zeroes([256]u8);
var paged_query_len: usize = 0;

// Set for the duration of a load-more fetch: appendYt then dedupes against the
// existing grid (yt-dlp re-sends the earlier page) and honours ITEM_CAP.
var appending_more: bool = false;

// ── InnerTube continuation cursor ──
// InnerTube hands back an opaque token pointing at the NEXT page of whatever
// feed produced the response, so load-more is one more POST instead of re-running
// the whole `ytsearch{N}:` (which costs ~19s and re-sends every earlier row).
// `cont_is_browse` records which endpoint the token belongs to: search
// continuations go back to /search and yield videoRenderer rows, channel
// continuations go to /browse and yield lockupViewModel rows.
// All three are shared state — read/written only under yt_mutex.
var cont_token: [it_pure.MAX_TOKEN_LEN]u8 = undefined;
var cont_token_len: usize = 0;
var cont_is_browse: bool = false;

/// Stash the next-page token from `json` (clearing it when the feed has no more
/// pages, so we never re-POST a spent cursor).
fn rememberContinuation(json: []const u8, is_browse: bool) void {
    const tok = it_pure.extractContinuationToken(json);
    yt_mutex.lock();
    defer yt_mutex.unlock();
    cont_is_browse = is_browse;
    if (tok) |t| {
        cont_token_len = @min(t.len, cont_token.len);
        @memcpy(cont_token[0..cont_token_len], t[0..cont_token_len]);
    } else cont_token_len = 0;
}

/// Drop the cursor. Called whenever the feed identity changes (a new search or
/// a new channel), so page 2 of the OLD feed can never land in the new grid.
fn clearContinuation() void {
    yt_mutex.lock();
    defer yt_mutex.unlock();
    cont_token_len = 0;
    cont_is_browse = false;
}

// ── Channel mode ──
// Clicking a card's channel name swaps the grid to that channel's uploads
// (yt-dlp flat-playlist on /channel/{id}/videos). The flag is atomic because
// fetchYoutube (which exits channel mode) is also called from the remote-API
// and AI-tool threads; the name/id bufs are only written on the UI thread
// (openChannel) and workers get copies via their spawn statics.
var channel_mode: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var channel_id_buf: [32]u8 = std.mem.zeroes([32]u8);
var channel_id_len: usize = 0;
var channel_name_buf: [64]u8 = std.mem.zeroes([64]u8);
var channel_name_len: usize = 0;

// ── Search suggestions (Google autocomplete, ds=yt) ──
// A worker fills the fixed rows under sugg_mutex; the dropdown renders a
// snapshot. sugg_for_* records which query the rows belong to, so a stale
// list is never shown for a newer query. Generation guard mirrors search_gen.
const SUGG_MAX = 8;
var sugg_mutex: @import("../core/sync.zig").Mutex = .{};
var sugg_rows: [SUGG_MAX][120]u8 = undefined;
var sugg_lens: [SUGG_MAX]u8 = std.mem.zeroes([SUGG_MAX]u8);
var sugg_count: usize = 0;
var sugg_for: [256]u8 = std.mem.zeroes([256]u8);
var sugg_for_len: usize = 0;
var sugg_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var sugg_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
const SUGG_DEBOUNCE_MS: i64 = 150; // faster than the 400ms search debounce

/// Append a result, clearing stale results lazily on the first new one.
/// Caller must hold yt_mutex. Keeps the `dates` arrays index-aligned.
fn appendYt(item: state.YtItem) void {
    if (pending_clear) {
        // Free the old items' GPU textures (queued for the UI thread) and heap
        // pixel buffers before dropping them — clearRetainingCapacity won't.
        for (state.app.yt.results.items) |*old| {
            if (old.thumb_tex) |t| {
                queueYtTexFree(t);
                old.thumb_tex = null;
            }
            if (old.thumb_pixels) |px| {
                alloc.free(px);
                old.thumb_pixels = null;
            }
        }
        state.app.yt.results.clearRetainingCapacity();
        dates.clearRetainingCapacity();
        dates_lens.clearRetainingCapacity();
        pending_clear = false;
    }
    if (appending_more) {
        if (state.app.yt.results.items.len >= ITEM_CAP) return;
        if (videoIdExists(item.video_id[0..item.video_id_len])) return;
    }
    state.app.yt.results.append(alloc, item) catch return;
    // Mirror the staged date so indices stay aligned even on alloc failure.
    dates.append(alloc, staged_date) catch {
        // Roll the result back so the two stay aligned.
        _ = state.app.yt.results.pop();
        return;
    };
    dates_lens.append(alloc, staged_date_len) catch {
        _ = state.app.yt.results.pop();
        _ = dates.pop();
        return;
    };
    // Reset staging for the next row.
    staged_date_len = 0;
    nudgeUi(false);
}

// ── Waterfall repaint ──
// Rows now land within a few hundred ms of each other (InnerTube parses the
// whole payload locally), so without an explicit repaint the grid would sit
// idle until the next natural frame and the "progressive fill" would be
// invisible. Batch the wake-ups: one refresh per REFRESH_BATCH appended rows is
// enough for the fill to read as continuous, and per-item refreshes would just
// burn frames. Safe from a worker (dvui.refresh is the documented cross-thread
// wake — cf. core/poster.zig).
const REFRESH_BATCH: usize = 3;
var since_refresh: usize = 0;

/// `force` = repaint now (end of a batch). Otherwise count toward the next
/// batch — that counter is only ever touched from appendYt, i.e. under
/// yt_mutex, so it needs no atomic of its own.
fn nudgeUi(force: bool) void {
    if (!force) {
        since_refresh += 1;
        if (since_refresh < REFRESH_BATCH) return;
        since_refresh = 0;
    }
    if (state.app.dvui_win) |win| dvui.refresh(win, @src(), null);
}

/// True if a result with `video_id` is already in the grid. Caller holds yt_mutex.
/// Used by load-more to skip the overlap with the previously-loaded page.
fn videoIdExists(video_id: []const u8) bool {
    for (state.app.yt.results.items) |*r| {
        if (std.mem.eql(u8, r.video_id[0..r.video_id_len], video_id)) return true;
    }
    return false;
}

/// Shutdown cleanup. Frees per-result thumbnail pixels the renderer never
/// uploaded (the results ArrayList only owns its own backing, not each item's
/// heap buffer), then the index-aligned date arrays. GPU textures don't need a
/// free here — the window/GL context is already tearing down.
pub fn deinit() void {
    for (state.app.yt.results.items) |*it| {
        if (it.thumb_pixels) |px| {
            alloc.free(px);
            it.thumb_pixels = null;
        }
    }
    state.app.yt.results.deinit(alloc);
    dates.deinit(alloc);
    dates_lens.deinit(alloc);
}

/// Date string for result `idx`, or "" if none/out of range. Caller holds yt_mutex.
fn dateFor(idx: usize) []const u8 {
    if (idx >= dates.items.len or idx >= dates_lens.items.len) return "";
    const n = dates_lens.items[idx];
    if (n == 0) return "";
    return dates.items[idx][0..@min(n, 8)];
}

// ══════════════════════════════════════════════════════════
// YouTube Core Service & UI (Piped API + yt-dlp fallback)
// ══════════════════════════════════════════════════════════

const piped_instances = [_][]const u8{
    "pipedapi.kavin.rocks",
    "pipedapi.adminforge.de",
    "api.piped.yt",
};

// ══════════════════════════════════════════════════════════
// Encrypted on-disk cache of SEARCH RESULTS — stale-while-revalidate.
// Serialization routes through content_cache_pure.Writer/Reader (tested);
// the cache identity routes through it_pure.normalizeQuery (tested). Mirrors
// resolver.zig's cacheKey/serialize/deserialize/populate/store shape.
// ══════════════════════════════════════════════════════════

const INNERTUBE_RESP_CAP: usize = 2 * 1024 * 1024;
const YT_BLOB_CAP: usize = 128 * 1024;
const YT_TTL_S: i64 = @import("browse_cache.zig").TTL_S;

fn ytCacheKey(buf: []u8, query: []const u8) []const u8 {
    var norm_buf: [256]u8 = undefined;
    const norm = it_pure.normalizeQuery(query, &norm_buf);
    return std.fmt.bufPrint(buf, "yt-search:{s}", .{norm}) catch "yt-search:";
}

/// Serialize the current grid into `out`. Caller holds yt_mutex.
fn serializeYtResults(out: []u8) ?[]u8 {
    var w = ccp.Writer.init(out);
    const n: u16 = @intCast(@min(state.app.yt.results.items.len, ITEM_CAP));
    w.u16v(n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const it = state.app.yt.results.items[i];
        w.blob(it.video_id[0..@min(it.video_id_len, it.video_id.len)]);
        w.blob(it.title[0..@min(it.title_len, it.title.len)]);
        w.blob(it.uploader[0..@min(it.uploader_len, it.uploader.len)]);
        w.blob(it.channel_id[0..@min(it.channel_id_len, it.channel_id.len)]);
        w.u32v(@intCast(std.math.clamp(it.duration, 0, std.math.maxInt(u32))));
        w.u32v(@intCast(std.math.clamp(it.views, 0, std.math.maxInt(u32))));
        w.blob(dateFor(i));
    }
    return w.done();
}

/// Publish cached rows into the grid (through appendYt, so the lazy-clear and
/// index-aligned date arrays behave exactly as on a live fetch). Returns how
/// many landed. Caller must NOT hold yt_mutex.
fn deserializeYtInto(bytes: []const u8, gen: u32) usize {
    var r = ccp.Reader.init(bytes);
    const n = r.u16v() orelse return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i < n and count < ITEM_CAP) : (i += 1) {
        if (!isCurrent(gen)) break;
        var it = state.YtItem{};
        const vid = r.blob() orelse break;
        if (!it_pure.validVideoId(vid)) break;
        it.video_id_len = @min(vid.len, it.video_id.len);
        @memcpy(it.video_id[0..it.video_id_len], vid[0..it.video_id_len]);
        const title = r.blob() orelse break;
        it.title_len = @min(title.len, it.title.len);
        @memcpy(it.title[0..it.title_len], title[0..it.title_len]);
        const up = r.blob() orelse break;
        it.uploader_len = @min(up.len, it.uploader.len);
        @memcpy(it.uploader[0..it.uploader_len], up[0..it.uploader_len]);
        const cid = r.blob() orelse break;
        it.channel_id_len = @min(cid.len, it.channel_id.len);
        @memcpy(it.channel_id[0..it.channel_id_len], cid[0..it.channel_id_len]);
        it.duration = r.u32v() orelse break;
        it.views = r.u32v() orelse break;
        const ymd = r.blob() orelse break;

        var thumb_buf: [128]u8 = undefined;
        if (it_pure.thumbUrl(it.video_id[0..it.video_id_len], &thumb_buf)) |turl| {
            it.thumbnail_url_len = @min(turl.len, it.thumbnail_url.len);
            @memcpy(it.thumbnail_url[0..it.thumbnail_url_len], turl[0..it.thumbnail_url_len]);
        }

        yt_mutex.lock();
        if (ymd.len == 8) {
            @memcpy(staged_date[0..8], ymd[0..8]);
            staged_date_len = 8;
        } else staged_date_len = 0;
        appendYt(it);
        yt_mutex.unlock();
        count += 1;
    }
    if (count > 0) nudgeUi(true);
    return count;
}

/// SWR read: paint the last-known rows for `query` INSTANTLY (no network) so a
/// repeat search or a tab re-entry is never blank. Returns true if it seeded.
fn populateYtFromCache(query: []const u8, gen: u32) bool {
    if (!state.app.content_cache_enabled) return false;
    const buf = alloc.alloc(u8, YT_BLOB_CAP) catch return false;
    defer alloc.free(buf);
    var key_buf: [288]u8 = undefined;
    const key = ytCacheKey(&key_buf, query);
    const hit = content_cache.get(key, buf) orelse return false;
    return deserializeYtInto(hit.bytes, gen) > 0;
}

/// SWR write: persist the freshly-fetched rows so the next search is instant.
/// Only called when LIVE rows landed (never re-stores a cache-seeded grid —
/// that would refresh the TTL without a network fetch).
fn storeYtToCache(query: []const u8) void {
    if (!state.app.content_cache_enabled) return;
    const buf = alloc.alloc(u8, YT_BLOB_CAP) catch return;
    defer alloc.free(buf);
    yt_mutex.lock();
    const blob = if (state.app.yt.results.items.len == 0) null else serializeYtResults(buf);
    yt_mutex.unlock();
    if (blob) |b| {
        var key_buf: [288]u8 = undefined;
        content_cache.put(ytCacheKey(&key_buf, query), b, YT_TTL_S);
    }
}

pub fn fetchYoutube(query: []const u8) void {
    if (state.app.yt.is_loading.load(.acquire)) return;
    channel_mode.store(false, .release); // a search always leaves channel view
    state.app.yt.is_loading.store(true, .release);
    state.app.yt.last_fetch_s = @import("browse_cache.zig").now(); // SWR stamp

    const actual_query = if (query.len == 0) "trending music" else query;

    // Bump the generation; this fetch owns `my_gen`. A later fetch will bump it
    // again, marking this one stale.
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    const S = struct {
        var q_buf: [256]u8 = undefined;
        var q_len: usize = 0;
        var gen: u32 = 0;
    };

    S.q_len = @min(actual_query.len, 255);
    @memcpy(S.q_buf[0..S.q_len], actual_query[0..S.q_len]);
    S.gen = my_gen;

    // Fresh search → reset paging. Remember the query this result set is paged
    // on so load-more re-runs the same search even if the text box changes.
    loaded_count.store(PAGE_SIZE, .release);
    loading_more.store(false, .release);
    clearContinuation(); // new feed → the old feed's page-2 cursor is void
    paged_query_len = S.q_len;
    @memcpy(paged_query[0..S.q_len], S.q_buf[0..S.q_len]);

    // Reserve a stable capacity (on the caller thread, before the worker /
    // any thumb-fetch worker exists) so later appends never realloc the buffer
    // out from under fetchThumb workers holding *YtItem (cf. the TMDB crash).
    state.app.yt.results.ensureTotalCapacity(alloc, 256) catch {};

    state.app.yt.thread = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer {
                state.app.yt.is_loading.store(false, .release);
            }

            const q = S.q_buf[0..S.q_len];

            yt_mutex.lock();
            pending_clear = true; // old results stay until the first new one lands
            yt_mutex.unlock();

            // ── SWR seed ──
            // Paint the last-known rows for this query from the encrypted disk
            // cache first (no network) so the grid is never blank, then RE-ARM
            // pending_clear so the first live row swaps them out in place
            // (otherwise the live rows would append onto the cached ones).
            _ = populateYtFromCache(q, S.gen);
            yt_mutex.lock();
            pending_clear = true;
            yt_mutex.unlock();

            // ── Layered fallback: InnerTube → yt-dlp → Piped ──
            // InnerTube is ~1.1s vs yt-dlp's ~18.6s for the same 20 results, so
            // it leads. Each later stage runs only if the previous published
            // nothing AND this search is still current. `pending_clear` (not
            // results.len) is the "did anything land" signal — the lazy-clear
            // means the OLD results are still in the list until a new row lands.
            if (isCurrent(S.gen)) _ = fetchViaInnerTube(q, S.gen, PAGE_SIZE);
            if (pending_clear and isCurrent(S.gen)) fetchViaYtdlp(q, S.gen, PAGE_SIZE);
            if (pending_clear and isCurrent(S.gen)) _ = fetchViaPiped(q, S.gen);

            // Live rows landed (pending_clear was consumed after the re-arm) →
            // refresh the cache entry. A fetch that produced nothing leaves the
            // cached rows on screen and the stored entry untouched.
            if (!pending_clear and isCurrent(S.gen)) storeYtToCache(q);
        }
    }.worker, .{}) catch blk: {
        state.app.yt.is_loading.store(false, .release);
        break :blk null;
    };
    // Detach: the handle is never joined, so without this each search leaks a
    // thread handle/resources for the life of the process.
    if (state.app.yt.thread) |t| t.detach();
}

/// Enter channel mode: swap the grid to `channel_id`'s uploads (seamless —
/// old results stay until the first channel row lands). UI THREAD ONLY (card
/// click / context menu). A later fetchYoutube() exits channel mode.
pub fn openChannel(channel_id: []const u8, name: []const u8) void {
    if (state.app.yt.is_loading.load(.acquire)) return;
    var url_check: [96]u8 = undefined;
    if (yt_pure.channelVideosUrl(channel_id, &url_check) == null) return; // no/invalid id

    channel_id_len = @min(channel_id.len, channel_id_buf.len);
    @memcpy(channel_id_buf[0..channel_id_len], channel_id[0..channel_id_len]);
    channel_name_len = @min(name.len, channel_name_buf.len);
    @memcpy(channel_name_buf[0..channel_name_len], name[0..channel_name_len]);
    channel_mode.store(true, .release);

    state.app.yt.is_loading.store(true, .release);
    state.app.yt.last_fetch_s = @import("browse_cache.zig").now();
    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;

    // Channel paging rides loaded_count/-I; the search query is not involved.
    loaded_count.store(PAGE_SIZE, .release);
    loading_more.store(false, .release);
    paged_query_len = 0;

    state.app.yt.results.ensureTotalCapacity(alloc, 256) catch {};

    clearContinuation(); // new feed → the old feed's page-2 cursor is void

    const S = struct {
        var id_buf: [32]u8 = undefined;
        var id_len: usize = 0;
        var name_buf: [64]u8 = undefined;
        var name_len: usize = 0;
        var gen: u32 = 0;
    };
    S.id_len = channel_id_len;
    @memcpy(S.id_buf[0..S.id_len], channel_id_buf[0..S.id_len]);
    // Copy the name too: channel_name_buf is UI-thread state, and the worker
    // stamps it onto every card (channel-page rows carry no byline).
    S.name_len = channel_name_len;
    @memcpy(S.name_buf[0..S.name_len], channel_name_buf[0..S.name_len]);
    S.gen = my_gen;

    const t = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer state.app.yt.is_loading.store(false, .release);
            yt_mutex.lock();
            pending_clear = true; // seamless swap, same as a re-search
            yt_mutex.unlock();
            // InnerTube browse (~0.7s) first; yt-dlp's flat-playlist on the
            // channel page (~19s) only if it yields nothing.
            const n = fetchChannelViaInnerTube(S.id_buf[0..S.id_len], S.name_buf[0..S.name_len], S.gen);
            if (n == 0) {
                fetchChannelViaYtdlp(S.id_buf[0..S.id_len], S.gen, PAGE_SIZE);
            } else if (isCurrent(S.gen)) {
                // A browse page is 30 rows, not PAGE_SIZE — advance the cursor
                // to what actually landed so load-more doesn't leave a gap.
                yt_mutex.lock();
                const have = state.app.yt.results.items.len;
                yt_mutex.unlock();
                loaded_count.store(have, .release);
            }
        }
    }.worker, .{}) catch {
        state.app.yt.is_loading.store(false, .release);
        return;
    };
    t.detach();
}

/// Leave channel mode and restore the last search (or the default feed).
fn exitChannel() void {
    const q = last_fired_query[0..last_fired_len];
    setQuery(q);
    recordFired(q);
    fetchYoutube(q); // clears channel_mode itself
}

/// Load the next page and APPEND it. yt-dlp flat search has no cursor, so we
/// re-run `ytsearch{loaded_count+PAGE_SIZE}:` and dedupe the overlap (the first
/// `loaded_count` rows repeat). Channel mode pages the same way via -I 1:{n}.
/// Guarded by `loading_more` + the main is_loading so a near-bottom scroll
/// can't spam fetches; the generation guard makes a new search supersede an
/// in-flight load-more.
pub fn fetchMore() void {
    if (state.app.yt.is_loading.load(.acquire)) return;
    if (loading_more.load(.acquire)) return;
    if (loaded_count.load(.acquire) >= ITEM_CAP) return;
    const in_channel = channel_mode.load(.acquire);
    if (paged_query_len == 0 and !in_channel) return;
    loading_more.store(true, .release);

    // This load-more belongs to the current generation; a new search bumps the
    // gen and this worker's appends get dropped (isCurrent).
    const my_gen = search_gen.load(.acquire);
    const want = @min(loaded_count.load(.acquire) + PAGE_SIZE, ITEM_CAP);

    const S = struct {
        var q_buf: [256]u8 = undefined;
        var q_len: usize = 0;
        var gen: u32 = 0;
        var n: usize = 0;
        var chan: bool = false;
        var id_buf: [32]u8 = undefined;
        var id_len: usize = 0;
        var name_buf: [64]u8 = undefined;
        var name_len: usize = 0;
    };
    S.q_len = paged_query_len;
    @memcpy(S.q_buf[0..S.q_len], paged_query[0..S.q_len]);
    S.gen = my_gen;
    S.n = want;
    S.chan = in_channel;
    S.id_len = channel_id_len;
    @memcpy(S.id_buf[0..S.id_len], channel_id_buf[0..S.id_len]);
    S.name_len = channel_name_len;
    @memcpy(S.name_buf[0..S.name_len], channel_name_buf[0..S.name_len]);

    const t = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer loading_more.store(false, .release);

            yt_mutex.lock();
            appending_more = true;
            yt_mutex.unlock();
            defer {
                yt_mutex.lock();
                appending_more = false;
                yt_mutex.unlock();
            }

            // ── Fast path: one continuation POST (~1s) ──
            // The token points straight at the next page, so unlike the yt-dlp
            // path there's no overlap to re-download and re-dedupe. appendYt
            // still dedupes (appending_more) and still honours ITEM_CAP.
            const n = fetchContinuation(S.gen, S.name_buf[0..S.name_len], S.id_buf[0..S.id_len]);
            if (n > 0) {
                // A continuation page isn't PAGE_SIZE-shaped (search gives 20,
                // browse 30), so advance the cursor to what's actually on
                // screen rather than the requested S.n.
                if (isCurrent(S.gen)) {
                    yt_mutex.lock();
                    const have = state.app.yt.results.items.len;
                    yt_mutex.unlock();
                    loaded_count.store(have, .release);
                }
                return;
            }

            // ── Fallback: no token (or the continuation failed) → yt-dlp ──
            // Re-runs the whole `ytsearch{N}:` / channel listing and leans on
            // appendYt's videoIdExists dedupe to drop the repeated prefix.
            if (S.chan)
                fetchChannelViaYtdlp(S.id_buf[0..S.id_len], S.gen, S.n)
            else
                fetchViaYtdlp(S.q_buf[0..S.q_len], S.gen, S.n);

            // Only advance the cursor if this load-more is still current; a
            // superseding search has already reset loaded_count for its own page.
            if (isCurrent(S.gen)) loaded_count.store(S.n, .release);
        }
    }.worker, .{}) catch {
        loading_more.store(false, .release);
        return;
    };
    t.detach();
}

/// True while `gen` is still the newest search. A stale worker bails so its
/// (out-of-date) results never reach the grid.
fn isCurrent(gen: u32) bool {
    return search_gen.load(.acquire) == gen;
}

// ══════════════════════════════════════════════════════════
// Fast path — YouTube InnerTube (/youtubei/v1/search)
// ══════════════════════════════════════════════════════════

/// One POST, one parse, rows appended as they're decoded. This replaces the
/// yt-dlp spawn as the primary search: measured on this machine, InnerTube
/// answers a 20-result search in ~1.1s where `yt-dlp ytsearch20:` takes ~18.6s
/// (process start + extractor warm-up + its own round trips dominate).
///
/// Client choice: the plain `WEB` InnerTube client. PO tokens / bot walls gate
/// *playback* stream URLs, not search metadata, so search needs no special
/// client — and pinning one would only freeze us to today's YouTube (see the
/// note in runYtdlp). `params` pins the result TYPE to "video", so channel rows
/// and shelves never reach the grid.
///
/// Returns true if at least one row was published. Bails on a superseded gen.
fn fetchViaInnerTube(query: []const u8, gen: u32, count: usize) bool {
    var body_buf: [1600]u8 = undefined;
    const post_body = it_pure.buildSearchBody(query, &body_buf) orelse return false;

    // ~750 KB typical, heap-allocated: far too big for a worker stack.
    const resp = alloc.alloc(u8, INNERTUBE_RESP_CAP) catch return false;
    defer alloc.free(resp);

    const json = innertubePost(it_pure.SEARCH_URL, post_body, resp) orelse return false;
    const n = publishRows(json, gen, count, .{});
    // Remember where page 2 starts. Stored even on a partial page: the token is
    // what makes infinite scroll cheap.
    rememberContinuation(json, false);
    return n > 0;
}

/// Channel Videos tab via `/youtubei/v1/browse`. Channel pages return the newer
/// `lockupViewModel` shape, so rows come from the lockup reader — but they land
/// in the same grid, with the channel name/id we already know stamped on each
/// card (a channel page's rows carry no byline of their own).
/// Returns rows published; 0 means "fall back to yt-dlp".
fn fetchChannelViaInnerTube(channel_id: []const u8, chan_name: []const u8, gen: u32) usize {
    var body_buf: [512]u8 = undefined;
    const post_body = it_pure.buildChannelBrowseBody(channel_id, &body_buf) orelse return 0;

    const resp = alloc.alloc(u8, INNERTUBE_RESP_CAP) catch return 0;
    defer alloc.free(resp);

    const json = innertubePost(it_pure.BROWSE_URL, post_body, resp) orelse return 0;
    const n = publishRows(json, gen, ITEM_CAP, .{ .lockup = true, .chan_name = chan_name, .chan_id = channel_id });
    rememberContinuation(json, true);
    return n;
}

/// Next page of whichever feed is currently on screen, via the continuation
/// token stashed by the previous fetch. Search continuations POST to the search
/// endpoint and yield `videoRenderer` rows; channel continuations POST to the
/// browse endpoint and yield `lockupViewModel` rows — `cont_is_browse` records
/// which. Returns rows published; 0 means "fall back to yt-dlp paging".
fn fetchContinuation(gen: u32, chan_name: []const u8, chan_id: []const u8) usize {
    var token_buf: [it_pure.MAX_TOKEN_LEN]u8 = undefined;
    yt_mutex.lock();
    const tlen = cont_token_len;
    const is_browse = cont_is_browse;
    if (tlen > 0) @memcpy(token_buf[0..tlen], cont_token[0..tlen]);
    yt_mutex.unlock();
    if (tlen == 0) return 0; // no token → last page, or we never got one

    const body = alloc.alloc(u8, it_pure.MAX_TOKEN_LEN + 512) catch return 0;
    defer alloc.free(body);
    const post_body = it_pure.buildContinuationBody(token_buf[0..tlen], body) orelse return 0;

    const resp = alloc.alloc(u8, INNERTUBE_RESP_CAP) catch return 0;
    defer alloc.free(resp);

    const url = if (is_browse) it_pure.BROWSE_URL else it_pure.SEARCH_URL;
    const json = innertubePost(url, post_body, resp) orelse return 0;
    const n = publishRows(json, gen, ITEM_CAP, .{
        .lockup = is_browse,
        .chan_name = if (is_browse) chan_name else "",
        .chan_id = if (is_browse) chan_id else "",
    });
    // Chain to page N+1. A response without a token means we hit the end of the
    // feed — clearing it stops fetchMore from re-POSTing a spent token.
    rememberContinuation(json, is_browse);
    return n;
}

/// One InnerTube POST. `out` must be heap-allocated (responses run ~300 KB–1 MB).
fn innertubePost(url: []const u8, post_body: []const u8, out: []u8) ?[]const u8 {
    return @import("reliable_fetch.zig").fetch(url, out, .{
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "X-YouTube-Client-Name", .value = "1" },
            .{ .name = "X-YouTube-Client-Version", .value = it_pure.CLIENT_VERSION },
        },
        .timeout_secs = 12,
        // Plain JSON API, not TLS-fingerprint walled — skipping impersonation
        // keeps this on the lowest-latency path.
        .impersonate = false,
        .post_body = post_body,
    });
}

const RowSource = struct {
    /// Read `lockupViewModel` rows (channel pages) instead of `videoRenderer`.
    lockup: bool = false,
    /// Byline to stamp on each row — channel pages don't carry one per item.
    chan_name: []const u8 = "",
    chan_id: []const u8 = "",
};

/// Decode rows out of an InnerTube payload and append them to the grid AS THEY
/// PARSE (that's the waterfall — appendYt batches the repaints). Honours the
/// generation guard on every row so a superseded search publishes nothing more.
/// Returns how many landed.
fn publishRows(json: []const u8, gen: u32, limit: usize, src: RowSource) usize {
    const now_days = @divFloor(io.timestamp(), 86400);
    var pos: usize = 0;
    var n: usize = 0;
    while (n < limit) {
        if (!isCurrent(gen)) break; // superseded — stop feeding the grid
        const v = (if (src.lockup) it_pure.nextLockupVideo(json, &pos) else it_pure.nextVideo(json, &pos)) orelse break;

        var item = state.YtItem{};
        item.video_id_len = @min(v.id.len, item.video_id.len);
        @memcpy(item.video_id[0..item.video_id_len], v.id[0..item.video_id_len]);
        item.title_len = it_pure.unescapeJson(v.title_raw, &item.title);
        item.duration = v.duration;
        item.views = v.views;

        // Channel pages: every row is the channel we opened, so stamp the
        // byline we already know. Search rows carry their own.
        if (v.channel_raw.len > 0) {
            item.uploader_len = it_pure.unescapeJson(v.channel_raw, &item.uploader);
        } else {
            item.uploader_len = @min(src.chan_name.len, item.uploader.len);
            @memcpy(item.uploader[0..item.uploader_len], src.chan_name[0..item.uploader_len]);
        }
        const cid = if (v.channel_id.len > 0) v.channel_id else src.chan_id;
        item.channel_id_len = @min(cid.len, item.channel_id.len);
        @memcpy(item.channel_id[0..item.channel_id_len], cid[0..item.channel_id_len]);

        var thumb_buf: [128]u8 = undefined;
        if (it_pure.thumbUrl(v.id, &thumb_buf)) |turl| {
            item.thumbnail_url_len = @min(turl.len, item.thumbnail_url.len);
            @memcpy(item.thumbnail_url[0..item.thumbnail_url_len], turl[0..item.thumbnail_url_len]);
        }

        yt_mutex.lock();
        // InnerTube gives a relative label ("6 years ago"); the card's date
        // column is YYYYMMDD, so convert once here (formatAgo renders it back).
        if (v.ago_days) |d| {
            staged_date = it_pure.ymdFromDaysSinceEpoch(now_days - d);
            staged_date_len = 8;
        } else {
            staged_date_len = 0;
        }
        appendYt(item);
        yt_mutex.unlock();
        n += 1;
    }
    if (n > 0) nudgeUi(true); // make sure the tail of the batch paints
    return n;
}

fn fetchViaPiped(query: []const u8, gen: u32) bool {
    var encoded: [512]u8 = undefined;
    const elen = yt_pure.urlEncode(query, &encoded);
    if (elen == 0) return false;

    for (piped_instances) |host| {
        if (!isCurrent(gen)) return false;
        var url_buf: [768]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://{s}/search?q={s}&filter=videos", .{ host, encoded[0..elen] }) catch continue;

        var client = std.http.Client{ .allocator = alloc, .io = io.io() };
        defer client.deinit();

        const uri = std.Uri.parse(url) catch continue;
        var req = client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/json" },
                .{ .name = "User-Agent", .value = "Mozilla/5.0 (X11; Linux x86_64) Opal/1.0" },
            },
        }) catch continue;
        defer req.deinit();
        req.sendBodiless() catch continue;

        var redirect_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch continue;
        if (response.head.status != .ok) continue;

        var transfer_buf: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var rdr = response.readerDecompressing(&transfer_buf, &decompress, &.{});

        const body = rdr.allocRemaining(alloc, std.Io.Limit.limited(512 * 1024)) catch continue;
        defer alloc.free(body);

        if (body.len < 10) continue;

        // Parse Piped JSON response.
        parsePipedResults(body, gen);
        return state.app.yt.results.items.len > 0;
    }
    return false;
}

fn parsePipedResults(json: []const u8, gen: u32) void {
    var pos: usize = 0;
    var count: usize = 0;

    while (pos < json.len and count < 20) {
        if (!isCurrent(gen)) return;
        // Find next video item by looking for "url":"/watch?v=
        const url_marker = std.mem.indexOf(u8, json[pos..], "\"url\":\"/watch?v=") orelse break;
        const abs_url = pos + url_marker + 15; // after "/watch?v=
        const vid_end = std.mem.indexOfAny(u8, json[abs_url..], "\"}&,") orelse break;
        const video_id = json[abs_url .. abs_url + vid_end];

        if (video_id.len < 5 or video_id.len > 31) {
            pos = abs_url + vid_end;
            continue;
        }

        var item = state.YtItem{};
        const vlen = @min(video_id.len, 31);
        @memcpy(item.video_id[0..vlen], video_id[0..vlen]);
        item.video_id_len = vlen;

        // Search window for this item's fields
        const window_end = @min(abs_url + 2000, json.len);
        const window = json[abs_url..window_end];

        if (extractJsonStr(window, "\"title\":")) |title| {
            const tlen = @min(title.len, 127);
            @memcpy(item.title[0..tlen], title[0..tlen]);
            item.title_len = tlen;
        }

        if (extractJsonStr(window, "\"uploaderName\":")) |up| {
            const ulen = @min(up.len, 63);
            @memcpy(item.uploader[0..ulen], up[0..ulen]);
            item.uploader_len = ulen;
        }

        if (extractJsonStr(window, "\"uploaderUrl\":")) |uurl| {
            if (yt_pure.channelIdFromUploaderUrl(uurl)) |cid| {
                const clen = @min(cid.len, 32);
                @memcpy(item.channel_id[0..clen], cid[0..clen]);
                item.channel_id_len = clen;
            }
        }

        item.duration = extractJsonNum(window, "\"duration\":");
        item.views = extractJsonNum(window, "\"views\":");

        // Build thumbnail URL
        var thumb_buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&thumb_buf, "https://i.ytimg.com/vi/{s}/mqdefault.jpg", .{video_id})) |thumb| {
            const tlen = @min(thumb.len, 511);
            @memcpy(item.thumbnail_url[0..tlen], thumb[0..tlen]);
            item.thumbnail_url_len = tlen;
        } else |_| {}

        // Piped has no plain upload_date in this list shape — leave it empty.
        staged_date_len = 0;

        yt_mutex.lock();
        appendYt(item);
        yt_mutex.unlock();
        count += 1;

        pos = abs_url + vid_end;
    }
}

fn fetchViaYtdlp(query: []const u8, gen: u32, count: usize) void {
    var search_arg: [288]u8 = undefined;
    const search_str = std.fmt.bufPrintZ(&search_arg, "ytsearch{d}:{s}", .{ count, query }) catch return;
    runYtdlp(search_str, null, gen);
}

/// Channel-uploads fetch: flat-playlist over /channel/{id}/videos, limited to
/// the first `count` items via -I (the channel tab has no search-style count).
fn fetchChannelViaYtdlp(channel_id: []const u8, gen: u32, count: usize) void {
    var url_buf: [96]u8 = undefined;
    const url = yt_pure.channelVideosUrl(channel_id, &url_buf) orelse return;
    var range_buf: [24]u8 = undefined;
    const range = std.fmt.bufPrintZ(&range_buf, "1:{d}", .{count}) catch return;
    runYtdlp(url, range, gen);
}

fn runYtdlp(target: []const u8, item_range: ?[]const u8, gen: u32) void {
    // --print with a compact tab template instead of -j: full JSON lines carry
    // a huge `description` that overflows the reader buffer (takeDelimiter then
    // errors and we parse nothing). Tab rows are short, fast, and robust.
    // Use the app's bundled yt-dlp (~/.config/opal/bin) — bare "yt-dlp" isn't
    // on the GUI process PATH, so spawning it fails.
    // %(upload_date)s is YYYYMMDD or NA on flat-playlist; %(channel_id)s feeds
    // the clickable channel → channel-videos view.
    const ytdlp_bin = @import("ytdlp.zig").binary();
    var argv_buf: [13][]const u8 = undefined;
    var argc: usize = 0;
    for ([_][]const u8{
        ytdlp_bin,
        "--flat-playlist",
        "--print",
        "%(id)s\t%(title)s\t%(channel)s\t%(duration)s\t%(view_count)s\t%(upload_date)s\t%(channel_id)s",
        "--no-warnings",
        "--socket-timeout",
        "10",
        // NOTE: deliberately NO `--extractor-args youtube:player_client=…`.
        // Pinning a client freezes us to whatever worked the day it was
        // written; the `tv` pin we used to carry here now returns only
        // storyboard formats on the playback path. yt-dlp maintains its own
        // client-fallback chain — let it choose.
    }) |a| {
        argv_buf[argc] = a;
        argc += 1;
    }
    if (item_range) |r| {
        argv_buf[argc] = "-I";
        argc += 1;
        argv_buf[argc] = r;
        argc += 1;
    }
    argv_buf[argc] = target;
    argc += 1;
    const argv = argv_buf[0..argc];

    var child = io.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;

    var reader_buf: [8192]u8 = undefined;
    var reader = child.stdout.?.reader(io.io(), &reader_buf);

    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        if (line.len == 0) continue;
        if (!isCurrent(gen)) break; // superseded — stop feeding the grid
        yt_mutex.lock();
        parseYtdlpLine(line);
        yt_mutex.unlock();
    }

    _ = child.wait() catch {};
}

/// Parse one tab-delimited row:
///   id \t title \t channel \t duration \t views \t upload_date
/// yt-dlp prints "NA" for missing fields (flat-playlist) — parseInt then fails
/// and we fall back to 0; an "NA"/short date is just skipped.
fn parseYtdlpLine(line: []const u8) void {
    var item = state.YtItem{};
    staged_date_len = 0;

    var it = std.mem.splitScalar(u8, line, '\t');
    const vid = it.next() orelse return;
    if (vid.len == 0 or vid.len > 31 or std.mem.eql(u8, vid, "NA")) return;
    @memcpy(item.video_id[0..vid.len], vid);
    item.video_id_len = vid.len;

    if (it.next()) |title| {
        const tlen = @min(title.len, 127);
        @memcpy(item.title[0..tlen], title[0..tlen]);
        item.title_len = tlen;
    }
    if (it.next()) |ch| {
        if (!std.mem.eql(u8, ch, "NA")) {
            const ulen = @min(ch.len, 63);
            @memcpy(item.uploader[0..ulen], ch[0..ulen]);
            item.uploader_len = ulen;
        }
    }
    if (it.next()) |dur| item.duration = std.fmt.parseInt(i64, dur, 10) catch 0;
    if (it.next()) |views| item.views = std.fmt.parseInt(i64, views, 10) catch 0;
    if (it.next()) |ud| {
        // Expect exactly YYYYMMDD (8 ASCII digits). Anything else → skip.
        if (ud.len == 8 and isAllDigits(ud)) {
            @memcpy(staged_date[0..8], ud[0..8]);
            staged_date_len = 8;
        }
    }
    if (it.next()) |cid| {
        if (!std.mem.eql(u8, cid, "NA") and cid.len <= 32) {
            @memcpy(item.channel_id[0..cid.len], cid);
            item.channel_id_len = cid.len;
        }
    }

    // yt-dlp search results include CHANNEL rows (id == channel_id, "UC…").
    // As a card that's a dead video: watch?v=UC… doesn't play and the vi/UC…
    // thumbnail 404s — skip them. (Channels are reachable via the clickable
    // channel name on any of their videos.) Same tested predicate the InnerTube
    // parser uses, so the two paths can't drift.
    if (it_pure.isChannelRow(item.video_id[0..item.video_id_len], item.channel_id[0..item.channel_id_len])) return;

    var thumb_buf: [128]u8 = undefined;
    if (it_pure.thumbUrl(item.video_id[0..item.video_id_len], &thumb_buf)) |thumb| {
        const tlen = @min(thumb.len, item.thumbnail_url.len);
        @memcpy(item.thumbnail_url[0..tlen], thumb[0..tlen]);
        item.thumbnail_url_len = tlen;
    }

    appendYt(item);
}

fn isAllDigits(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn extractJsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, json, key) orelse return null;
    const after = json[ki + key.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':')) i += 1;
    if (i >= after.len or after[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < after.len) : (i += 1) {
        if (after[i] == '"' and (i == 0 or after[i - 1] != '\\')) {
            return after[start..i];
        }
    }
    return null;
}

fn extractJsonNum(json: []const u8, key: []const u8) i64 {
    const ki = std.mem.indexOf(u8, json, key) orelse return 0;
    const after = json[ki + key.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':')) i += 1;
    if (i + 4 <= after.len and std.mem.eql(u8, after[i .. i + 4], "null")) return 0;
    var neg: bool = false;
    if (i < after.len and after[i] == '-') {
        neg = true;
        i += 1;
    }
    const start = i;
    while (i < after.len and after[i] >= '0' and after[i] <= '9') i += 1;
    if (i == start) return 0;
    const val = std.fmt.parseInt(i64, after[start..i], 10) catch 0;
    return if (neg) -val else val;
}

// ══════════════════════════════════════════════════════════
// Date formatting
// ══════════════════════════════════════════════════════════

/// Render an upload_date (YYYYMMDD) into a compact human "X ago" string.
/// Returns "" if the date is missing/unparseable. Writes into `out`.
fn formatAgo(ymd: []const u8, out: []u8) []const u8 {
    if (ymd.len != 8 or !isAllDigits(ymd)) return "";
    const y = std.fmt.parseInt(i64, ymd[0..4], 10) catch return "";
    const mo = std.fmt.parseInt(i64, ymd[4..6], 10) catch return "";
    const d = std.fmt.parseInt(i64, ymd[6..8], 10) catch return "";
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return "";

    // Days since a fixed epoch (proleptic Gregorian) for both the upload date
    // and "now", then diff. Good enough for a relative label.
    const up_days = daysFromCivil(y, mo, d);
    const now_s = io.timestamp(); // seconds since unix epoch
    const now_days = @divFloor(now_s, 86400) + 719468; // align to daysFromCivil epoch
    var diff = now_days - up_days;
    if (diff < 0) diff = 0;

    if (diff < 1) return std.fmt.bufPrint(out, "today", .{}) catch "";
    if (diff < 2) return std.fmt.bufPrint(out, "yesterday", .{}) catch "";
    if (diff < 7) return std.fmt.bufPrint(out, "{d}d ago", .{diff}) catch "";
    if (diff < 30) return std.fmt.bufPrint(out, "{d}w ago", .{@divTrunc(diff, 7)}) catch "";
    if (diff < 365) return std.fmt.bufPrint(out, "{d}mo ago", .{@divTrunc(diff, 30)}) catch "";
    return std.fmt.bufPrint(out, "{d}y ago", .{@divTrunc(diff, 365)}) catch "";
}

/// Days from civil date relative to 0000-03-01 epoch shifted to match the
/// unix-epoch alignment used above (Howard Hinnant's algorithm, +719468).
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe; // days since 0000-03-01
}

// ══════════════════════════════════════════════════════════
// Thumbnail Fetching
// ══════════════════════════════════════════════════════════

pub fn fetchThumb(item: *state.YtItem) void {
    if (item.thumbnail_url_len == 0 or item.thumb_fetching) return;
    // Shared global poster/thumbnail fetch cap — over the cap, leave thumb_fetching
    // false so the card retries next frame (no fetch storm on a full grid).
    if (!@import("../core/poster.zig").tryClaimSlot()) return;
    item.thumb_fetching = true;

    if (std.Thread.spawn(.{}, struct {
        fn worker(ptr: *state.YtItem) void {
            workers.enter();
            defer workers.leave();
            defer ptr.thumb_fetching = false;
            defer @import("../core/poster.zig").releaseSlot();

            const poster = @import("../core/poster.zig");
            const turl = ptr.thumbnail_url[0..ptr.thumbnail_url_len];

            // Shared poster disk cache: a hit skips the network; a cached blob
            // that fails to decode is deleted and refetched (same policy as
            // fetchAsync in core/poster.zig).
            const cached = poster.cacheLoadForUrl(turl);
            defer if (cached) |cb| poster.cacheFreeEncoded(cb);

            var net_body: ?[]u8 = null;
            defer if (net_body) |bo| alloc.free(bo);

            var pixels: [*c]u8 = null;
            var w: c_int = 0;
            var h: c_int = 0;
            var attempt: u8 = 0;
            while (attempt < 2) : (attempt += 1) {
                const used_cache = attempt == 0 and cached != null;
                const body: []const u8 = if (used_cache) cached.? else blk: {
                    var client = std.http.Client{ .allocator = alloc, .io = io.io() };
                    defer client.deinit();

                    const uri = std.Uri.parse(turl) catch return;
                    var req = client.request(.GET, uri, .{ .extra_headers = &.{.{ .name = "Accept", .value = "image/jpeg, image/webp" }} }) catch return;
                    defer req.deinit();
                    req.sendBodiless() catch return;

                    var redirect_buf: [8192]u8 = undefined;
                    var response = req.receiveHead(&redirect_buf) catch return;
                    if (response.head.status != .ok) return;

                    var transfer_buf: [4096]u8 = undefined;
                    var decompress: std.http.Decompress = undefined;
                    var rdr = response.readerDecompressing(&transfer_buf, &decompress, &.{});

                    const body = rdr.allocRemaining(alloc, std.Io.Limit.limited(5 * 1024 * 1024)) catch return;
                    net_body = body;
                    break :blk body;
                };

                var comp: c_int = 0;
                w = 0;
                h = 0;
                pixels = dvui.c.stbi_load_from_memory(body.ptr, @intCast(body.len), &w, &h, &comp, 4);
                if (pixels != null and w > 0 and h > 0) {
                    if (!used_cache) poster.cacheStoreForUrl(turl, body, @intCast(w), @intCast(h));
                    break;
                }
                if (pixels != null) dvui.c.stbi_image_free(pixels);
                pixels = null;
                if (used_cache) poster.cacheDeleteForUrl(turl) else return;
            }
            if (pixels == null) return;
            defer dvui.c.stbi_image_free(pixels);
            // usize-first: w*h*4 in c_int overflows on a large crafted image and
            // panics this worker thread (whole-app abort).
            const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
            const p_slice = alloc.alloc(u8, p_len) catch return;
            @memcpy(p_slice, pixels[0..p_len]);

            // Quitting → don't publish into a result the deinit path may have
            // already freed; drop our copy so it isn't reported as a leak.
            if (workers.isQuitting()) {
                alloc.free(p_slice);
                return;
            }

            ptr.thumb_w = @intCast(w);
            ptr.thumb_h = @intCast(h);
            ptr.thumb_pixels = p_slice;
        }
    }.worker, .{item})) |t| t.detach() else |_| {
        item.thumb_fetching = false; // spawn failed — reset so the card isn't stuck on placeholder
        @import("../core/poster.zig").releaseSlot();
    }
}

// ══════════════════════════════════════════════════════════
// UI Rendering (called from drawer.zig)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    drainYtTexFrees(); // free textures from a re-search clear (UI thread)
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(8) });
    defer content.deinit();

    if (!state.app.yt.loaded_once and !state.app.yt.is_loading.load(.acquire)) {
        state.app.yt.loaded_once = true;
        const q = currentQuery();
        recordFired(q);
        fetchYoutube(q);
    } else if (state.app.yt.results.items.len > 0 and !state.app.yt.is_loading.load(.acquire) and
        !channel_mode.load(.acquire) and // an SWR refetch would silently exit channel view
        @import("browse_cache.zig").isStale(state.app.yt.last_fetch_s))
    {
        // SWR background refresh — keep showing current results meanwhile.
        fetchYoutube(currentQuery());
    }

    renderToolbar();

    // Debounced live search: fire once the buffer has settled for DEBOUNCE_MS
    // and differs from what we last fired. Enter/button paths fire immediately
    // (renderSearchInline), this just covers as-you-type.
    maybeFireLiveSearch();
    // Suggestions ride a shorter debounce so the dropdown feels live.
    maybeFireSuggest();

    // Only show the loading line on an INITIAL load (nothing yet) — a
    // stale-refresh keeps current results on screen and swaps in place.
    if (state.app.yt.is_loading.load(.acquire) and state.app.yt.results.items.len == 0) {
        _ = dvui.label(@src(), "Searching YouTube...", .{}, .{ .color_text = theme.colors.accent, .gravity_x = 0.5, .margin = dvui.Rect.all(12) });
    }

    if (state.app.yt.results.items.len == 0 and !state.app.yt.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "No results. Try searching for something.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    yt_mutex.lock();
    defer yt_mutex.unlock();

    // Responsive grid of 16:9 video tiles from the LIVE width; the column count
    // derives from the user-cyclable card width. The gutter matches the card's
    // 4px margin on each side (8px between neighbours) so the grid reads as a
    // uniform, evenly-spaced lattice at every width.
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(260, (if (rect_w > 1) rect_w else 900) - 8);
    const gutter: f32 = 6; // 2 * card margin (3)
    const cols: usize = @max(1, @as(usize, @intFromFloat((avail_w + gutter) / (card_w + gutter))));
    const real_card_w: f32 = @max(120, (avail_w - @as(f32, @floatFromInt(cols - 1)) * gutter) / @as(f32, @floatFromInt(cols)));

    // ── Virtualization (same shape as tmdb.zig/comics.zig/jellyfin_ui.zig) ──
    // Cards are uniform (renderCard pins min==max height), so rows have a fixed
    // pitch: thumb + footer content, plus the card's 4px top/bottom margins
    // (min_sizeGet = padSize(min_size_content) adds padding + margin around the
    // content → +8 total). Rows outside the viewport (±2 overscan) collapse into
    // two spacer boxes, so the grid lays out a handful of rows per frame instead
    // of all ~200 card widget trees. The base index of each row (row * cols) is
    // IDENTICAL to the prior loop's `i`, so every card's id_extra scheme is
    // unchanged and retained widget state is unaffected.
    const thumb_h: f32 = real_card_w * 9.0 / 16.0;
    const row_h: f32 = thumb_h + cardFooterH() + 6; // +6 = card's 3px top+bottom margin
    const total_rows = (state.app.yt.results.items.len + cols - 1) / cols;
    const win = tmdb_pure.visibleRows(total_rows, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 2);

    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49998,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) },
        });
        sp.deinit();
    }

    var r: usize = win.first;
    while (r < win.last) : (r += 1) {
        const base = r * cols;
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = base + 80000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and base + col < state.app.yt.results.items.len) : (col += 1) {
            renderCard(&state.app.yt.results.items[base + col], base + col, real_card_w);
        }
    }

    if (win.last < total_rows) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(total_rows - win.last)) },
        });
        sp.deinit();
    }

    // ── Infinite scroll ──
    // When the viewport nears the bottom, fetch+append the next page. Mirrors
    // tmdb.zig: an 800px trigger band, gated by is_loading + loading_more so a
    // scroll can't spam fetches, and capped at ITEM_CAP (below the reserved 256
    // buffer capacity so appends never realloc out from under thumb workers).
    // fetchMore() only spawns a thread; the mutex we hold here is taken by that
    // worker asynchronously, so calling it under the lock is safe.
    const have = state.app.yt.results.items.len;
    if (have > 0 and have < ITEM_CAP and (paged_query_len > 0 or channel_mode.load(.acquire))) {
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        if (near_bottom and !state.app.yt.is_loading.load(.acquire) and !loading_more.load(.acquire)) {
            fetchMore();
        }
        if (loading_more.load(.acquire)) {
            _ = dvui.label(@src(), "Loading more…", .{}, .{
                .color_text = theme.colors.text_secondary,
                .gravity_x = 0.5,
                .padding = dvui.Rect.all(12),
            });
        }
    }
}

/// Current search query from the shared buffer (NUL-trimmed).
fn currentQuery() []const u8 {
    return state.app.yt.search_buf[0 .. std.mem.indexOfScalar(u8, &state.app.yt.search_buf, 0) orelse state.app.yt.search_buf.len];
}

/// Remember which query we last fired so live-search doesn't re-fire it.
fn recordFired(q: []const u8) void {
    last_fired_len = @min(q.len, last_fired_query.len);
    @memcpy(last_fired_query[0..last_fired_len], q[0..last_fired_len]);
    last_edit_ms = io.milliTimestamp();
}

/// Debounced search-as-you-type. Called every frame.
///
/// Design: `last_seen_*` snapshots the buffer each frame; whenever it differs
/// from the previous frame we treat that as a keystroke and reset `last_edit_ms`
/// — so the window measures *inactivity*. Once the buffer has been stable for
/// DEBOUNCE_MS, has ≥2 chars, and differs from what we last fired, we fire.
/// fetchYoutube bumps `search_gen`; an in-flight worker whose gen is superseded
/// drops its results (isCurrent), so fast typing never shows out-of-order rows.
fn maybeFireLiveSearch() void {
    const q = currentQuery();
    const now_ms = io.milliTimestamp();

    // Detect a buffer change since the previous frame → restart the debounce.
    const changed = q.len != last_seen_len or !std.mem.eql(u8, q, last_seen_query[0..last_seen_len]);
    if (changed) {
        last_seen_len = @min(q.len, last_seen_query.len);
        @memcpy(last_seen_query[0..last_seen_len], q[0..last_seen_len]);
        last_edit_ms = now_ms;
        return; // wait at least one settle window before firing
    }

    // Nothing changed this frame; fire if settled, meaningful, and not already
    // the last-fired query.
    const same_as_fired = q.len == last_fired_len and std.mem.eql(u8, q, last_fired_query[0..last_fired_len]);
    if (same_as_fired) return;

    if (q.len >= 2 and now_ms - last_edit_ms >= DEBOUNCE_MS and !state.app.yt.is_loading.load(.acquire)) {
        recordFired(q);
        fetchYoutube(q);
    }
}

// ══════════════════════════════════════════════════════════
// Toolbar (chips, search, count, card-size)
// ══════════════════════════════════════════════════════════

const CatChip = struct { label: []const u8, query: []const u8 };
const cat_chips = [_]CatChip{
    .{ .label = "Trending", .query = "trending" },
    .{ .label = "Music", .query = "music" },
    .{ .label = "Gaming", .query = "gaming" },
    .{ .label = "Tech", .query = "tech" },
    .{ .label = "News", .query = "news" },
};

fn renderToolbar() void {
    var bar = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 5 },
    });
    defer bar.deinit();

    dvui.icon(@src(), "yt-icon", icons.tvg.lucide.music, .{}, .{ .color_text = theme.colors.accent, .gravity_y = 0.5, .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 } });

    // Channel banner — back arrow + the channel whose uploads fill the grid.
    if (channel_mode.load(.acquire)) {
        if (dvui.buttonIcon(@src(), "chan-back", icons.tvg.lucide.@"arrow-left", .{}, .{}, .{
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .color_text = theme.colors.text_secondary,
            .border = dvui.Rect.all(0),
            .min_size_content = theme.iconSize(.sm),
            .padding = dvui.Rect.all(3),
            .gravity_y = 0.5,
        })) {
            exitChannel();
        }
        _ = dvui.label(@src(), "{s}", .{safeUtf8(channel_name_buf[0..channel_name_len])}, .{
            .background = true,
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
            .gravity_y = 0.5,
        });
    }

    renderSearchInline();

    // Category preset chips.
    toolbarDivider(901);
    const q = currentQuery();
    for (cat_chips, 0..) |c, ci| {
        renderCatChip(ci, c, q);
    }

    // Item count + card-size controls.
    toolbarDivider(950);
    _ = dvui.label(@src(), "{d} videos", .{state.app.yt.results.items.len}, .{ .color_text = theme.colors.text_secondary, .gravity_y = 0.5, .font = metaFont() });

    const dim = dvui.Color{ .r = 120, .g = 120, .b = 148, .a = 200 };
    if (dvui.buttonIcon(@src(), "smaller", icons.tvg.lucide.minus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        card_w = @max(CARD_MIN, card_w - 40);
    }
    if (dvui.buttonIcon(@src(), "bigger", icons.tvg.lucide.plus, .{}, .{}, .{
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = dim,
        .border = dvui.Rect.all(0),
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(3),
        .gravity_y = 0.5,
    })) {
        card_w = @min(CARD_MAX, card_w + 40);
    }
}

/// A faint vertical separator between toolbar groups.
fn toolbarDivider(id: usize) void {
    var d = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .min_size_content = .{ .w = 1, .h = 18 },
        .background = true,
        .color_fill = theme.colors.border_subtle,
        .margin = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .gravity_y = 0.5,
    });
    d.deinit();
}

/// Compact inline search box with an autocomplete dropdown. Enter/Go fire
/// immediately; typing is handled by the debounced live search in
/// maybeFireLiveSearch() and the (faster) suggestion fetch in maybeFireSuggest().
///
/// Manual TextEntryWidget instead of components.toolbarSearch: dvui.suggestion
/// must own the event pass so ↑/↓ move the highlight, Enter commits it, and
/// Esc closes — so te.processEvents() must NOT run (suggestion forwards events).
fn renderSearchInline() void {
    const components = @import("../ui/components.zig");

    var te = dvui.widgetAlloc(dvui.TextEntryWidget);
    te.init(@src(), .{ .text = .{ .buffer = &state.app.yt.search_buf }, .placeholder = "Search YouTube…" }, .{
        .min_size_content = .{ .w = 240, .h = components.TOOLBAR_INPUT_H },
        .max_size_content = .{ .w = 240, .h = components.TOOLBAR_INPUT_H },
        .color_fill = theme.colors.bg_elevated,
        .color_border = theme.colors.border_subtle,
        .color_text = theme.colors.text_primary,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        .gravity_y = 0.5,
    });
    var sug = dvui.suggestion(te, .{ .open_on_focus = false, .open_on_text_change = true });
    te.draw();

    // Snapshot the suggestion rows (worker fills them under sugg_mutex) — but
    // only if they belong to the text currently in the box; a stale list for
    // an older query stays hidden.
    const q = currentQuery();
    var rows: [SUGG_MAX][120]u8 = undefined;
    var lens: [SUGG_MAX]u8 = undefined;
    var count: usize = 0;
    sugg_mutex.lock();
    if (q.len == sugg_for_len and std.mem.eql(u8, q, sugg_for[0..sugg_for_len])) {
        count = sugg_count;
        for (0..count) |i| {
            rows[i] = sugg_rows[i];
            lens[i] = sugg_lens[i];
        }
    }
    sugg_mutex.unlock();

    if (count == 0) sug.close();
    if (count > 0 and sug.dropped()) {
        // Row 0 is the typed text itself — the default highlight — so plain
        // Enter always searches exactly what was typed; ↓ reaches the fetched
        // suggestions (mirrors YouTube's own dropdown).
        if (sug.addChoiceLabel(q)) commitSearch(q);
        for (0..count) |i| {
            const s = safeUtf8(rows[i][0..lens[i]]);
            if (sug.addChoiceLabel(s)) {
                // s points into this frame's snapshot — commitSearch copies it
                // into the search buffer before anything can invalidate it.
                commitSearch(s);
            }
        }
    }
    sug.deinit();
    const enter_pressed = te.enter_pressed;
    te.deinit();

    if (components.toolbarGo(@src(), "Go") or enter_pressed) {
        commitSearch(currentQuery());
    }
}

/// Put `q` in the box, dismiss suggestions, and fire the search.
fn commitSearch(q: []const u8) void {
    var q_copy: [256]u8 = undefined;
    const n = @min(q.len, q_copy.len);
    @memcpy(q_copy[0..n], q[0..n]); // q may alias the search buffer setQuery rewrites
    setQuery(q_copy[0..n]);
    recordFired(q_copy[0..n]);
    sugg_mutex.lock();
    sugg_count = 0;
    sugg_for_len = 0;
    sugg_mutex.unlock();
    fetchYoutube(q_copy[0..n]);
}

/// Debounced suggestion fetch (SUGG_DEBOUNCE_MS after the last keystroke —
/// deliberately quicker than the search debounce so the dropdown feels live).
/// Rides last_edit_ms, which maybeFireLiveSearch refreshes on every buffer
/// change. Skips queries we already have rows for, the query that was just
/// committed, and anything under 2 chars.
fn maybeFireSuggest() void {
    const q = currentQuery();
    if (q.len < 2) {
        if (sugg_count > 0 or sugg_for_len > 0) {
            sugg_mutex.lock();
            sugg_count = 0;
            sugg_for_len = 0;
            sugg_mutex.unlock();
        }
        return;
    }
    if (q.len == last_fired_len and std.mem.eql(u8, q, last_fired_query[0..last_fired_len])) return;
    if (io.milliTimestamp() - last_edit_ms < SUGG_DEBOUNCE_MS) return;
    if (sugg_busy.load(.acquire)) return;

    sugg_mutex.lock();
    const have = q.len == sugg_for_len and std.mem.eql(u8, q, sugg_for[0..sugg_for_len]);
    sugg_mutex.unlock();
    if (have) return;

    fireSuggest(q);
}

fn fireSuggest(query: []const u8) void {
    if (sugg_busy.load(.acquire)) return;
    sugg_busy.store(true, .release);
    const my_gen = sugg_gen.fetchAdd(1, .acq_rel) + 1;

    const S = struct {
        var q_buf: [256]u8 = undefined;
        var q_len: usize = 0;
        var gen: u32 = 0;
    };
    S.q_len = @min(query.len, 255);
    @memcpy(S.q_buf[0..S.q_len], query[0..S.q_len]);
    S.gen = my_gen;

    const t = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer sugg_busy.store(false, .release);

            var url_buf: [640]u8 = undefined;
            const url = yt_pure.suggestUrl(S.q_buf[0..S.q_len], &url_buf) orelse return;

            var client = std.http.Client{ .allocator = alloc, .io = io.io() };
            defer client.deinit();

            const uri = std.Uri.parse(url) catch return;
            var req = client.request(.GET, uri, .{
                .extra_headers = &.{
                    .{ .name = "Accept", .value = "application/json" },
                    .{ .name = "User-Agent", .value = "Mozilla/5.0 (X11; Linux x86_64) Opal/1.0" },
                },
            }) catch return;
            defer req.deinit();
            req.sendBodiless() catch return;

            var redirect_buf: [8192]u8 = undefined;
            var response = req.receiveHead(&redirect_buf) catch return;
            if (response.head.status != .ok) return;

            var transfer_buf: [4096]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            var rdr = response.readerDecompressing(&transfer_buf, &decompress, &.{});
            const body = rdr.allocRemaining(alloc, std.Io.Limit.limited(64 * 1024)) catch return;
            defer alloc.free(body);

            // Parse into worker-local rows, then publish under the mutex only
            // if no newer suggestion fetch has been fired since.
            var local_rows: [SUGG_MAX][120]u8 = undefined;
            var local_slices: [SUGG_MAX][]u8 = undefined;
            for (&local_rows, 0..) |*r, i| local_slices[i] = r;
            var local_lens: [SUGG_MAX]u8 = @splat(0);
            const n = yt_pure.parseSuggestions(body, &local_slices, &local_lens);

            if (sugg_gen.load(.acquire) != S.gen) return; // superseded
            sugg_mutex.lock();
            defer sugg_mutex.unlock();
            sugg_count = n;
            for (0..n) |i| {
                sugg_rows[i] = local_rows[i];
                sugg_lens[i] = local_lens[i];
            }
            sugg_for_len = S.q_len;
            @memcpy(sugg_for[0..S.q_len], S.q_buf[0..S.q_len]);
        }
    }.worker, .{}) catch {
        sugg_busy.store(false, .release);
        return;
    };
    t.detach();
}

fn renderCatChip(idx: usize, chip: CatChip, current: []const u8) void {
    const active = std.mem.eql(u8, current, chip.query);
    if (dvui.button(@src(), chip.label, .{}, .{
        .id_extra = idx + 2000,
        .background = true,
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_surface,
        .color_text = if (active) dvui.Color.white else theme.colors.text_secondary,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 7, .y = 3, .w = 7, .h = 3 },
        .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
        .gravity_y = 0.5,
        .font = metaFont(),
    })) {
        setQuery(chip.query);
        recordFired(chip.query);
        fetchYoutube(chip.query);
    }
}

/// Replace the shared search buffer with `q` (NUL-padded).
fn setQuery(q: []const u8) void {
    const n = @min(q.len, state.app.yt.search_buf.len - 1);
    @memset(&state.app.yt.search_buf, 0);
    @memcpy(state.app.yt.search_buf[0..n], q[0..n]);
}

// ══════════════════════════════════════════════════════════
// Cards
// ══════════════════════════════════════════════════════════

fn renderCard(item: *state.YtItem, idx: usize, the_card_w: f32) void {
    const title = safeUtf8(item.title[0..item.title_len]);
    const thumb_h: f32 = the_card_w * 9.0 / 16.0;

    // min == max height → uniform row pitch, which the grid's virtualization
    // spacer math depends on (row_h = thumb_h + cardFooterH() + padding + margins).
    // cardFooterH() is font-metric-derived and sized for the WORST case (2-line
    // title) at the live UI scale — it MUST be the exact same call the pitch calc
    // uses (grid loop above), or the card and the spacer drift.
    const footer_h = cardFooterH();
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx + 9000,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(theme.radius.lg),
        .min_size_content = .{ .w = the_card_w, .h = thumb_h + footer_h },
        .max_size_content = .{ .w = the_card_w, .h = thumb_h + footer_h },
        .margin = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    defer card.deinit();

    // Thumbnail (16:9). A plain container (NOT a button): the Play/Queue icon
    // buttons are overlaid on it, and a wrapping button would swallow their
    // clicks (a parent ButtonWidget processes events before its children, so it
    // would claim the click meant for the Queue icon). Play is now the accent
    // icon, so the whole-poster quick-play click is no longer needed.
    {
        var thumb = dvui.box(@src(), .{}, .{
            .id_extra = idx + 100,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_deep,
            .corner_radius = .{ .x = theme.radius.lg, .y = theme.radius.lg, .w = 0, .h = 0 },
            .min_size_content = .{ .w = the_card_w, .h = thumb_h },
            .max_size_content = .{ .w = the_card_w, .h = thumb_h },
            .padding = dvui.Rect.all(0),
        });
        defer thumb.deinit();

        if (item.thumb_tex == null and item.thumb_pixels != null and
            item.thumb_pixels.?.len == @as(usize, item.thumb_w) * @as(usize, item.thumb_h) * 4)
        {
            const num_pixels = item.thumb_w * item.thumb_h;
            const pixels_pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(item.thumb_pixels.?.ptr)))[0..num_pixels];
            item.thumb_tex = dvui.textureCreate(pixels_pma, item.thumb_w, item.thumb_h, .linear, .rgba_32) catch null;
            if (item.thumb_tex != null) {
                alloc.free(item.thumb_pixels.?);
                item.thumb_pixels = null;
            }
        }

        // Stack: image (or placeholder) + duration badge + sticky action icons.
        {
            var stack = dvui.overlay(@src(), .{ .id_extra = idx + 140, .expand = .both });
            defer stack.deinit();

            if (item.thumb_tex) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = idx + 150,
                    .expand = .both,
                    .corner_radius = dvui.Rect.all(4),
                });
            } else {
                // Failure-latch (mirrors TmdbItem/JfItem): stop re-spawning a
                // thumb worker every frame for a dead/undecodable URL.
                if (item.thumb_fetching) {
                    item.thumb_attempted = true;
                } else if (item.thumb_attempted and item.thumb_pixels == null and item.thumb_tex == null) {
                    item.thumb_failed = true;
                } else if (!item.thumb_failed and item.thumb_pixels == null and item.thumbnail_url_len > 0) {
                    fetchThumb(item);
                    if (item.thumb_fetching) item.thumb_attempted = true;
                }
                dvui.icon(@src(), "ph", icons.tvg.lucide.image, .{}, .{
                    .id_extra = idx + 150,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .color_text = theme.colors.bg_elevated,
                    .expand = .both,
                });
            }

            // Duration badge (bottom-right) — a tight pill over a soft scrim so
            // it stays legible on both dark and light thumbnails.
            if (item.duration > 0) {
                var dur_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = idx + 161,
                    .gravity_x = 1.0,
                    .gravity_y = 1.0,
                    .background = true,
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 180 },
                    .corner_radius = dvui.Rect.all(4),
                    .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
                    .margin = .{ .x = 0, .y = 0, .w = 6, .h = 6 },
                });
                defer dur_box.deinit();

                var dur_buf: [24]u8 = undefined;
                const dur_str = yt_pure.formatDuration(item.duration, &dur_buf);
                if (dur_str.len > 0) {
                    _ = dvui.labelNoFmt(@src(), dur_str, .{}, .{ .id_extra = idx + 162, .color_text = dvui.Color.white, .font = metaFont() });
                }
            }

            // Sticky action icons (bottom-left) — always visible, thumbnail-
            // anchored so they can never be clipped by a tall title. Play (accent)
            // + Queue (add). Icon-only, no text.
            {
                var abar = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = idx + 170,
                    .gravity_x = 0.0,
                    .gravity_y = 1.0,
                    .margin = .{ .x = 6, .y = 0, .w = 0, .h = 6 },
                });
                defer abar.deinit();
                if (thumbActionIcon(idx + 171, icons.tvg.lucide.play, true)) sendToPlayer(item, false);
                if (thumbActionIcon(idx + 172, icons.tvg.lucide.plus, false)) sendToPlayer(item, true);
            }
        }
    }

    // Info
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = idx + 200,
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 5, .w = 8, .h = 0 },
        });
        defer info.deinit();

        // Title — clamped to two lines (each line auto-ellipsized by dvui),
        // UTF-8 safe. A "\n" split near the width-derived midpoint at a word
        // boundary gives a balanced two-line block; long single words just
        // ellipsize on line one. Heading weight reads as a proper video title.
        var title_buf: [160]u8 = undefined;
        const title_2l = twoLineTitle(title, the_card_w - 20, &title_buf);
        // Clamp the title to EXACTLY its reserved two lines. Without this a title
        // whose font renders taller than cardFooterH() estimated would grow the
        // info box and shove the actions row past the card's fixed max height,
        // where it clips to a sliver — the reported "queue buttons don't show"
        // bug. With the clamp the title can never steal the actions' space,
        // regardless of font-metric surprises. Same 2-line height cardFooterH
        // reserves, so they cannot drift.
        _ = dvui.labelNoFmt(@src(), title_2l, .{}, .{
            .id_extra = idx + 300,
            .expand = .horizontal,
            .color_text = theme.colors.text_primary,
            .font = titleFont(),
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = 2.0 * titleFont().lineHeight() },
            .gravity_y = 0.0,
        });

        // Two-line meta: channel on its own line, then "1.5M views · 3w ago".
        // Splitting them means dvui ellipsizes the CHANNEL (line 1) and trims
        // the date end (line 2) — a view-count digit is never cut.
        {
            var meta = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = idx + 400,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
            });
            defer meta.deinit();

            if (item.uploader_len > 0) {
                var ch_buf: [80]u8 = undefined;
                const ch = truncateUtf8(item.uploader[0..item.uploader_len], 28, &ch_buf);
                if (item.channel_id_len > 0) {
                    // Clickable channel → that channel's uploads take over the
                    // grid (openChannel validates the id and no-ops if bad).
                    if (dvui.labelClick(@src(), "{s}", .{ch}, .{}, .{
                        .id_extra = idx + 410,
                        .expand = .horizontal,
                        .color_text = theme.colors.text_secondary,
                        .font = metaFont(),
                    })) {
                        openChannel(item.channel_id[0..item.channel_id_len], item.uploader[0..item.uploader_len]);
                    }
                } else {
                    _ = dvui.labelNoFmt(@src(), ch, .{}, .{
                        .id_extra = idx + 410,
                        .expand = .horizontal,
                        .color_text = theme.colors.text_secondary,
                        .font = metaFont(),
                    });
                }
            }

            const ymd = dateFor(idx);
            var abuf: [16]u8 = undefined;
            const ago = if (ymd.len == 8) formatAgo(ymd, &abuf) else "";
            var mbuf: [64]u8 = undefined;
            const ml = metaLine(item.views, ago, &mbuf);
            if (ml.len > 0) {
                _ = dvui.labelNoFmt(@src(), ml, .{}, .{
                    .id_extra = idx + 430,
                    .expand = .horizontal,
                    .color_text = theme.colors.text_tertiary,
                    .font = metaFont(),
                });
            }
        }
        // Play/Queue moved to sticky icon buttons on the thumbnail (see above),
        // so the footer no longer carries an actions row — nothing to clip.
    }

    // ── Right-click context menu ──
    {
        const ctext = dvui.context(@src(), .{ .rect = card.data().borderRectScale().r }, .{ .id_extra = idx + 700 });
        defer ctext.deinit();

        if (ctext.activePoint()) |cp| {
            var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{
                .id_extra = idx + 700,
                .color_fill = theme.colors.bg_surface,
                .color_border = theme.colors.border_subtle,
            });
            defer fw.deinit();

            if (item.channel_id_len > 0 and item.uploader_len > 0) {
                if ((dvui.menuItemLabel(@src(), "View Channel", .{}, .{ .expand = .horizontal, .id_extra = idx + 705 })) != null) {
                    openChannel(item.channel_id[0..item.channel_id_len], item.uploader[0..item.uploader_len]);
                    fw.close();
                }
            }
            if ((dvui.menuItemLabel(@src(), "Copy Title", .{}, .{ .expand = .horizontal, .id_extra = idx + 710 })) != null) {
                dvui.clipboardTextSet(title);
                state.showToast("Title copied");
                fw.close();
            }
            if (item.video_id_len > 0) {
                if ((dvui.menuItemLabel(@src(), "Copy YouTube URL", .{}, .{ .expand = .horizontal, .id_extra = idx + 720 })) != null) {
                    var yt_url_buf: [128]u8 = undefined;
                    if (std.fmt.bufPrint(&yt_url_buf, "https://www.youtube.com/watch?v={s}", .{item.video_id[0..item.video_id_len]})) |yt_url| {
                        dvui.clipboardTextSet(yt_url);
                        state.showToast("YouTube URL copied");
                    } else |_| {}
                    fw.close();
                }
            }
        }
    }
}

/// Clamp a title to two lines by inserting a single "\n" near a word boundary.
/// dvui ellipsizes each line independently, so a one-line title that overflows
/// only ever shows ~half; splitting it onto two lines lets far more show before
/// the second line ellipsizes. `card_w` estimates chars-per-line (~7px/char at
/// the default font). UTF-8 safe (input is already safeUtf8'd; we only split on
/// an ASCII space, never inside a codepoint). Writes into `out`.
fn twoLineTitle(title: []const u8, width: f32, out: []u8) []const u8 {
    // Rough glyphs-per-line for this card width (with side padding ~12px).
    const cpl: usize = @max(8, @as(usize, @intFromFloat(@max(0, width - 12) / 7.0)));
    if (title.len <= cpl) return title; // fits on one line, leave it

    // Find the last space at/just before the line-1 budget so line 1 ends on a
    // whole word. Fall back to a hard split if there's no space in range.
    const limit = @min(title.len, cpl);
    var split: usize = 0;
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (title[i] == ' ') split = i;
    }
    // If the only space is very early, prefer a hard cut at the budget so line 1
    // isn't nearly empty. Otherwise break on the word boundary.
    if (split < cpl / 2) split = limit;

    // Skip the space we broke on (if we broke on one) so line 2 doesn't start
    // with a leading space.
    const rest_start = if (split < title.len and title[split] == ' ') split + 1 else split;
    const rest = title[rest_start..];
    if (split + 1 + rest.len > out.len) {
        // Won't fit the buffer — just return the (auto-ellipsized) original.
        return title;
    }
    @memcpy(out[0..split], title[0..split]);
    out[split] = '\n';
    @memcpy(out[split + 1 .. split + 1 + rest.len], rest);
    return out[0 .. split + 1 + rest.len];
}

/// Build the "1.5M views · 3w ago" meta line into `out`. Either part may be
/// empty. Views come first so dvui's per-line ellipsize (which trims the END of
/// the line) eats the date before it could ever cut a digit of the count.
fn metaLine(views: i64, ago: []const u8, out: []u8) []const u8 {
    var vbuf: [32]u8 = undefined;
    const vstr = yt_pure.viewsStr(views, &vbuf); // "1.5M views" or ""
    if (vstr.len > 0 and ago.len > 0) return std.fmt.bufPrint(out, "{s}  \u{00b7}  {s}", .{ vstr, ago }) catch vstr;
    if (vstr.len > 0) return std.fmt.bufPrint(out, "{s}", .{vstr}) catch "";
    if (ago.len > 0) return std.fmt.bufPrint(out, "{s}", .{ago}) catch "";
    return "";
}

/// UTF-8-safe truncation to at most `max` codepoints, appending "…" when cut.
/// Writes into `out`; returns the slice. Trims a trailing space before the
/// ellipsis so "Some Channel …" reads "Some Channel…". Keeps view counts on the
/// next line intact — only the channel name is ever shortened.
fn truncateUtf8(s_in: []const u8, max: usize, out: []u8) []const u8 {
    const s = safeUtf8(s_in);
    // Count codepoints; if it already fits, pass through unchanged.
    var cps: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + n > s.len) break;
        i += n;
        cps += 1;
    }
    if (cps <= max) return s;

    // Re-walk, copying up to `max` codepoints.
    var bi: usize = 0;
    var taken: usize = 0;
    var oi: usize = 0;
    while (bi < s.len and taken < max) {
        const n = std.unicode.utf8ByteSequenceLength(s[bi]) catch break;
        if (bi + n > s.len or oi + n > out.len) break;
        @memcpy(out[oi .. oi + n], s[bi .. bi + n]);
        oi += n;
        bi += n;
        taken += 1;
    }
    // Drop a trailing space so we don't render "Foo …".
    while (oi > 0 and out[oi - 1] == ' ') oi -= 1;
    const ell = "\u{2026}"; // …
    if (oi + ell.len <= out.len) {
        @memcpy(out[oi .. oi + ell.len], ell);
        oi += ell.len;
    }
    return out[0..oi];
}

fn sendToPlayer(item: *state.YtItem, appendToPlaylist: bool) void {
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const ap = state.app.players.items[state.app.active_player_idx];
    const queue_svc = @import("queue.zig");

    var url_buf: [128]u8 = undefined;
    const yt_url = std.fmt.bufPrintZ(&url_buf, "https://www.youtube.com/watch?v={s}", .{item.video_id[0..item.video_id_len]}) catch return;

    queue_svc.addToQueue(yt_url, item.title[0..item.title_len], "youtube");

    if (appendToPlaylist) {
        const mpv = @import("../core/c.zig").mpv;
        var args = [_][*c]const u8{ "loadfile", yt_url.ptr, "append", null };
        _ = mpv.mpv_command(ap.mpv_ctx, @ptrCast(&args));
        state.showToast("Track queued!");
    } else {
        ap.load_file(yt_url.ptr);
        state.gotoPlayer(); // player route + drawer closed — user lands on the video
    }
}
