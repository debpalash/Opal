const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("icons");
const logs = @import("../core/logs.zig");

const alloc = @import("../core/alloc.zig").allocator;
const safeUtf8 = @import("../core/text.zig").safeUtf8;
const workers = @import("../core/workers.zig");

fn percentEncode(input: []const u8, out: []u8) usize {
    const hex = "0123456789ABCDEF";
    var o: usize = 0;
    for (input) |ch| {
        if (o + 3 > out.len) break;
        if (ch == ' ') {
            out[o] = '+';
            o += 1;
        } else if (ch == '&' or ch == '=' or ch == '#' or ch == '?' or ch == '%' or ch == '"' or ch == '<' or ch == '>') {
            out[o] = '%';
            out[o + 1] = hex[ch >> 4];
            out[o + 2] = hex[ch & 0x0F];
            o += 3;
        } else {
            out[o] = ch;
            o += 1;
        }
    }
    return o;
}

// ══════════════════════════════════════════════════════════
// Comics Reader — readallcomics.com scraper + native viewer
// Uses curl subprocess to bypass Cloudflare
// ══════════════════════════════════════════════════════════

/// Request a comic load from a NON-UI thread (the remote API server). loadComic()
/// frees page textures via dvui.textureDestroyLater, which is UI-thread-only, so
/// the remote thread must not call it directly. Stash the URL and let the UI drain.
pub fn requestLoad(url: []const u8) void {
    if (url.len == 0 or url.len >= state.app.comic.pending_load_url.len) return;
    @memcpy(state.app.comic.pending_load_url[0..url.len], url);
    state.app.comic.pending_load_len = url.len;
    state.app.comic.pending_load.store(true, .release);
}

/// Drain a pending remote comic-load request. UI-THREAD ONLY — call once per frame.
pub fn drainPendingLoad() void {
    if (!state.app.comic.pending_load.swap(false, .acq_rel)) return;
    const n = state.app.comic.pending_load_len;
    if (n == 0 or n >= state.app.comic.pending_load_url.len) return;
    loadComic(state.app.comic.pending_load_url[0..n]);
}

// Page textures freed from a NON-UI thread (the plugin manga-reload worker) must
// not call dvui.textureDestroyLater directly. The worker queues them here and
// renderContent drains on the UI thread (mirrors youtube/anime).
var pending_page_tex: [256]dvui.Texture = undefined;
var pending_page_tex_count: usize = 0;
var pending_page_tex_mutex: @import("../core/sync.zig").Mutex = .{};

pub fn queuePageTexFree(tex: dvui.Texture) void {
    pending_page_tex_mutex.lock();
    defer pending_page_tex_mutex.unlock();
    if (pending_page_tex_count < pending_page_tex.len) {
        pending_page_tex[pending_page_tex_count] = tex;
        pending_page_tex_count += 1;
    }
}

/// Destroy queued page textures. UI-THREAD ONLY — call once per frame.
pub fn drainPageTexFrees() void {
    pending_page_tex_mutex.lock();
    defer pending_page_tex_mutex.unlock();
    for (pending_page_tex[0..pending_page_tex_count]) |t| dvui.textureDestroyLater(t);
    pending_page_tex_count = 0;
}

/// Kick off a background thread to fetch and parse a comic issue page.
pub fn loadComic(url: []const u8) void {
    if (state.app.comic.is_loading.load(.acquire)) return;
    if (url.len == 0 or url.len >= 512) return;

    // Stop any active narration
    state.app.comic.narrating = false;
    state.app.comic.show_ocr_overlay = false;

    // Store URL
    const buf_ptr: [*]const u8 = @ptrCast(&state.app.comic.url_buf[0]);
    if (url.ptr != buf_ptr) {
        @memcpy(state.app.comic.url_buf[0..url.len], url);
    }
    state.app.comic.url_len = url.len;
    state.app.comic.is_loading.store(true, .release);
    state.app.comic.page_count = 0;
    state.app.comic.dl_progress.store(0, .release);
    state.app.comic.current_page = 0;

    freeComicPages();

    // Comics read inside the Browse › Comics tab now (the player route is for
    // playback only) — no player pane is claimed here.
    state.app.comic.thread = std.Thread.spawn(.{}, fetchComicThread, .{}) catch null;
}

/// Free all downloaded page textures/pixels and the OCR cache.
pub fn freeComicPages() void {
    // UAF guard: the narration + OCR workers read state.app.comic.page_pixels
    // (and re-decode via stbi). Freeing those buffers here while a worker is
    // mid-read is a use-after-free. Signal stop and JOIN both before freeing.
    // Both callers (closeComic / loadComic) run on the UI thread, and neither
    // worker calls freeComicPages, so this can't self-deadlock. (narrationThread
    // polls `narrating` and exits promptly; ocrPage is a bounded one-shot.)
    state.app.comic.narrating = false;
    if (state.app.comic.narrate_thread) |t| {
        t.join();
        state.app.comic.narrate_thread = null;
    }
    if (state.app.comic.ocr_thread) |t| {
        t.join();
        state.app.comic.ocr_thread = null;
    }

    for (0..128) |i| {
        page_decode_failed[i] = false; // fresh page set — clear the decode-failure latch
        if (state.app.comic.page_textures[i]) |tex| {
            dvui.textureDestroyLater(tex);
        }
        state.app.comic.page_textures[i] = null;
        if (state.app.comic.page_pixels[i]) |px| {
            alloc.free(px);
            state.app.comic.page_pixels[i] = null;
        }
        state.app.comic.ocr_lens[i] = 0;
        state.app.comic.ocr_done[i] = false;
    }
}

/// Release all search-result cover textures + pixel buffers. RENDER-THREAD ONLY
/// (e.g. app shutdown). The per-slot free helper lives further down with the
/// search-result state; declared here as a thin forwarder for call sites near
/// the comic lifecycle.
pub fn freeSearchCovers() void {
    for (0..MAX_SEARCH_RESULTS) |i| freeCoverSlot(i);
}

/// Close the current comic and return to the browse/search view.
pub fn closeComic() void {
    state.app.comic.narrating = false;
    state.app.comic.show_ocr_overlay = false;
    freeComicPages();
    state.app.comic.page_count = 0;
    state.app.comic.current_page = 0;
    state.app.comic.title_len = 0;
    state.app.comic.dl_progress.store(0, .release);
}

fn fetchComicThread() void {
    workers.enter();
    defer workers.leave();
    const url = state.app.comic.url_buf[0..state.app.comic.url_len];

    // Try external plugins first
    if (tryPlugins(url)) {
        logs.pushLog("info", "comics", "Comic loaded via plugin", false);
        state.app.comic.is_loading.store(false, .release);
        downloadPages();
        return;
    }

    // Fallback: native curl + HTML parsing
    const argv = [_][]const u8{
        "curl",       "-sL",
        "-H",         "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "--max-time", "15",
        url,
    };

    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch {
        logs.pushLog("error", "comics", "Failed to spawn curl", true);
        state.app.comic.is_loading.store(false, .release);
        return;
    };

    const html_buf = alloc.alloc(u8, 512 * 1024) catch return;
    defer alloc.free(html_buf);
    const html_bytes = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, html_buf) catch 0 else 0;
    _ = child.wait() catch {};

    if (workers.isQuitting()) {
        state.app.comic.is_loading.store(false, .release);
        return;
    }

    if (html_bytes == 0) {
        logs.pushLog("error", "comics", "Empty response from curl", true);
        state.app.comic.is_loading.store(false, .release);
        return;
    }

    const html = html_buf[0..html_bytes];

    parseTitle(html);
    parseImageUrls(html);
    parseNavLinks(html);

    logs.pushLog("info", "comics", "Comic loaded (native)", false);
    state.app.comic.is_loading.store(false, .release);
    downloadPages();
}

/// Scan ~/.config/zigzag/plugins/comics/ for .lua/.py/.sh scripts,
/// execute each with url as arg1, parse JSON stdout.
fn tryPlugins(url: []const u8) bool {
    // 1) Try bundled plugins/ directory (shipped with app)
    if (tryPluginsInDir("plugins", url)) return true;

    // 2) Try user plugins directory
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return false;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/zigzag/plugins/comics", .{home}) catch return false;
    return tryPluginsInDir(dir_path, url);
}

fn tryPluginsInDir(dir_path: []const u8, url: []const u8) bool {
    var dir = @import("../core/io_global.zig").cwdOpenDir(dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(@import("../core/io_global.zig").io());

    var iter = dir.iterate();
    while (iter.next(@import("../core/io_global.zig").io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;

        // Determine interpreter based on extension
        const interpreter: []const u8 = if (std.mem.endsWith(u8, name, ".lua"))
            "lua"
        else if (std.mem.endsWith(u8, name, ".py"))
            "python3"
        else if (std.mem.endsWith(u8, name, ".sh"))
            "bash"
        else
            continue;

        // Build full path
        var path_buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;

        // Execute: <interpreter> <plugin_path> <url>
        const argv = [_][]const u8{ interpreter, full_path, url };
        var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        _ = child.spawn() catch continue;

        const json_buf = alloc.alloc(u8, 256 * 1024) catch continue;
        defer alloc.free(json_buf);
        const json_len = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, json_buf) catch 0 else 0;
        const term = child.wait() catch continue;

        // Plugin exited non-zero = "not my domain", try next
        if (term.exited != 0 or json_len < 10) continue;

        // Parse JSON response
        if (parsePluginJson(json_buf[0..json_len])) {
            var msg_buf: [320]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Plugin matched: {s}", .{name}) catch "Plugin matched";
            logs.pushLog("info", "comics", msg, false);
            return true;
        }
    }
    return false;
}

/// Parse the JSON output from a comic plugin and populate state.
fn parsePluginJson(json: []const u8) bool {
    // Simple manual JSON parsing — extract "title", "pages", "next_url", "prev_url"

    // Title
    if (findJsonString(json, "\"title\":\"")) |title| {
        const len = @min(title.len, 255);
        @memcpy(state.app.comic.title[0..len], title[0..len]);
        state.app.comic.title_len = len;
    }

    // Next URL
    if (findJsonString(json, "\"next_url\":\"")) |nxt| {
        const len = @min(nxt.len, 511);
        @memcpy(state.app.comic.next_url[0..len], nxt[0..len]);
        state.app.comic.next_url_len = len;
    } else {
        state.app.comic.next_url_len = 0;
    }

    // Prev URL
    if (findJsonString(json, "\"prev_url\":\"")) |prv| {
        const len = @min(prv.len, 511);
        @memcpy(state.app.comic.prev_url[0..len], prv[0..len]);
        state.app.comic.prev_url_len = len;
    } else {
        state.app.comic.prev_url_len = 0;
    }

    // Pages array
    var count: usize = 0;
    const pages_start = std.mem.indexOf(u8, json, "\"pages\":[") orelse return false;
    var pos = pages_start + 9; // skip "pages":[

    while (pos < json.len and count < 128) {
        // Find next quoted string
        const q1 = std.mem.indexOfScalar(u8, json[pos..], '"') orelse break;
        const abs_q1 = pos + q1 + 1;
        if (abs_q1 >= json.len) break;
        const q2 = std.mem.indexOfScalar(u8, json[abs_q1..], '"') orelse break;
        const page_url = json[abs_q1 .. abs_q1 + q2];

        if (page_url.len > 10 and page_url.len < 512) {
            @memcpy(state.app.comic.page_urls[count][0..page_url.len], page_url);
            state.app.comic.page_url_lens[count] = page_url.len;
            count += 1;
        }

        pos = abs_q1 + q2 + 1;
        // Skip comma or closing bracket
        if (pos < json.len and json[pos] == ']') break;
    }

    state.app.comic.page_count = count;
    return count > 0;
}

/// Extract a simple JSON string value after a key prefix like "key":"
fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, key) orelse return null;
    const val_start = start + key.len;
    if (val_start >= json.len) return null;
    // Find closing unescaped quote
    var i: usize = val_start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == val_start or json[i - 1] != '\\')) {
            const val = json[val_start..i];
            if (val.len == 0) return null;
            return val;
        }
    }
    return null;
}

fn parseTitle(html: []const u8) void {
    // Look for: <title>...<title> or series name in <h1>
    if (findBetween(html, "<title>", "</title>")) |title| {
        const clean = std.mem.trimEnd(u8, title, " \t\r\n");
        const len = @min(clean.len, 255);
        @memcpy(state.app.comic.title[0..len], clean[0..len]);
        state.app.comic.title_len = len;
    }
}

fn parseImageUrls(html: []const u8) void {
    // readallcomics.com uses images hosted on bp.blogspot.com
    // Pattern: src="https://X.bp.blogspot.com/..."
    var count: usize = 0;
    var pos: usize = 0;

    while (pos < html.len and count < 128) {
        // Find img src
        const src_start = findSubstring(html[pos..], "src=\"https://") orelse break;
        const abs_start = pos + src_start + 5; // skip 'src="'
        const src_end = std.mem.indexOfScalar(u8, html[abs_start..], '"') orelse break;
        const img_url = html[abs_start .. abs_start + src_end];
        pos = abs_start + src_end;

        // Filter: only blogspot CDN images (actual comic pages)
        if (std.mem.indexOf(u8, img_url, "bp.blogspot.com") == null and
            std.mem.indexOf(u8, img_url, "blogger.googleusercontent") == null) continue;

        // Skip tiny icons/thumbnails
        if (src_end < 30) continue;

        if (img_url.len < 512) {
            @memcpy(state.app.comic.page_urls[count][0..img_url.len], img_url);
            state.app.comic.page_url_lens[count] = img_url.len;
            count += 1;
        }
    }

    state.app.comic.page_count = count;
}

fn parseNavLinks(html: []const u8) void {
    state.app.comic.next_url_len = 0;
    state.app.comic.prev_url_len = 0;

    // Look for: href="...">...Next...
    if (findLinkWithText(html, "Next")) |next_url| {
        const len = @min(next_url.len, 511);
        @memcpy(state.app.comic.next_url[0..len], next_url[0..len]);
        state.app.comic.next_url_len = len;
    }

    if (findLinkWithText(html, "Prev")) |prev_url| {
        const len = @min(prev_url.len, 511);
        @memcpy(state.app.comic.prev_url[0..len], prev_url[0..len]);
        state.app.comic.prev_url_len = len;
    }
}

fn downloadPages() void {
    // Download comic page images in PARALLEL — 8 concurrent threads
    const BATCH = 8;
    var threads: [BATCH]?std.Thread = [_]?std.Thread{null} ** BATCH;
    var page_idx: usize = 0;

    while (page_idx < state.app.comic.page_count) {
        var active: usize = 0;

        // Spawn batch of download threads
        while (active < BATCH and page_idx < state.app.comic.page_count) {
            if (state.app.comic.page_pixels[page_idx] != null or
                state.app.comic.page_url_lens[page_idx] == 0)
            {
                page_idx += 1;
                continue;
            }
            threads[active] = std.Thread.spawn(.{}, downloadSinglePage, .{page_idx}) catch null;
            active += 1;
            page_idx += 1;
        }

        // Wait for all threads in this batch
        for (0..active) |t| {
            if (threads[t]) |th| th.join();
            threads[t] = null;
        }
    }
}

fn downloadSinglePage(i: usize) void {
    workers.enter();
    defer workers.leave();
    const url = state.app.comic.page_urls[i][0..state.app.comic.page_url_lens[i]];
    if (url.len == 0) return;

    const argv = [_][]const u8{
        "curl",       "-sL",
        "-H",         "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
        "--max-time", "15",
        url,
    };

    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;

    const max_img = 5 * 1024 * 1024;
    const tmp_buf = alloc.alloc(u8, max_img) catch return;
    defer alloc.free(tmp_buf);
    var total: usize = 0;

    if (child.stdout) |*stdout| {
        while (total < max_img) {
            if (workers.isQuitting()) return; // bail mid-download; defer frees tmp_buf
            const n = @import("../core/io_global.zig").read(stdout, tmp_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    _ = child.wait() catch {};

    // Quitting → freeComicPages may already have run; don't publish a buffer
    // nothing will free.
    if (workers.isQuitting()) return;

    if (total > 100) {
        const pixels = alloc.dupe(u8, tmp_buf[0..total]) catch return;
        state.app.comic.page_pixels[i] = pixels;
        _ = state.app.comic.dl_progress.fetchAdd(1, .acq_rel);
    }
}

// ══════════════════════════════════════════════════════════
// Search readallcomics.com
// ══════════════════════════════════════════════════════════

// ── Comic search results (parsed from the readallcomics search page) ──
// readallcomics serves 20 results per page (WordPress `&paged=N`). 120 holds
// six pages so infinite-scroll can grow the listing well past one screen.
const MAX_SEARCH_RESULTS = 120;
const RESULTS_PER_PAGE = 20; // readallcomics page size (confirmed from live HTML)
var sr_urls: [MAX_SEARCH_RESULTS][256]u8 = undefined;
var sr_url_lens: [MAX_SEARCH_RESULTS]usize = std.mem.zeroes([MAX_SEARCH_RESULTS]usize);
var sr_titles: [MAX_SEARCH_RESULTS][160]u8 = undefined;
var sr_title_lens: [MAX_SEARCH_RESULTS]usize = std.mem.zeroes([MAX_SEARCH_RESULTS]usize);

// ── Per-result cover art (lazy curl → stbi decode → GPU texture) ──
// The readallcomics search page wraps every result in
//   <a … title="TITLE" class="book-link"> <img src="COVER" class="book-cover">
//   … <a … class="latest-chapter">CHAPTER</a>
// so a cover URL is available for essentially every hit. We still degrade to a
// gradient placeholder card if one happens to be missing.
var sr_cover_urls: [MAX_SEARCH_RESULTS][512]u8 = undefined;
var sr_cover_url_lens: [MAX_SEARCH_RESULTS]usize = std.mem.zeroes([MAX_SEARCH_RESULTS]usize);
var sr_cover_pixels: [MAX_SEARCH_RESULTS]?[]u8 = [_]?[]u8{null} ** MAX_SEARCH_RESULTS;
var sr_cover_w: [MAX_SEARCH_RESULTS]u32 = std.mem.zeroes([MAX_SEARCH_RESULTS]u32);
var sr_cover_h: [MAX_SEARCH_RESULTS]u32 = std.mem.zeroes([MAX_SEARCH_RESULTS]u32);
var sr_cover_tex: [MAX_SEARCH_RESULTS]?dvui.Texture = [_]?dvui.Texture{null} ** MAX_SEARCH_RESULTS;
var sr_cover_fetching: [MAX_SEARCH_RESULTS]std.atomic.Value(bool) = [_]std.atomic.Value(bool){std.atomic.Value(bool).init(false)} ** MAX_SEARCH_RESULTS;
// Global cap on simultaneous cover fetches: a full search grid (up to
// MAX_SEARCH_RESULTS=120 cards) would otherwise spawn 120 curl+decode workers at
// once (each up to ~4 MB), a process/memory storm. Mirrors core/poster.zig.
var cover_in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
const MAX_COVER_CONCURRENT: u32 = 8;
// Per-slot generation: the search generation that last wrote this slot's cover
// URL. The RENDER THREAD compares against `covers_render_gen` to reclaim stale
// textures/pixels — so only the render thread ever destroys textures or frees
// cover pixels (the worker only writes URLs). This sidesteps a worker↔render
// double-free on the pixel buffers entirely.
var sr_cover_gen: [MAX_SEARCH_RESULTS]u32 = std.mem.zeroes([MAX_SEARCH_RESULTS]u32);
var covers_render_gen: u32 = 0;

var sr_count: usize = 0;
var sr_searching: bool = false;
var loaded_default: bool = false;
var last_fetch_s: i64 = 0; // SWR cache timestamp
var sr_query_buf: [256]u8 = undefined;
var sr_query_len: usize = 0;

// ── Live / incremental (debounced) search ──
// generation guards against stale workers overwriting fresher results.
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var last_edit_ms: i64 = 0;
var last_fired_query: [256]u8 = undefined;
var last_fired_len: usize = 0;

// ── Infinite scroll / pagination ──
// `sr_page` is the highest readallcomics page already merged into sr_*. When the
// grid scrolls near the bottom we fetch sr_page+1 and APPEND (deduped by URL).
// `loading_more` guards against double-spawning the appender; `more_available`
// goes false once a fetched page yields no new rows (we hit the end / cap).
var sr_page: u32 = 1;
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var more_available: bool = true;

// ── Source selector ──
// readallcomics is the only natively-readable source today (its issue pages
// embed blogspot-CDN images the reader consumes). A clean enum + selector keeps
// adding sources a one-arm change; plugin sources are surfaced dynamically.
const Source = enum { all, readallcomics };
var active_source: Source = .all;

// ── Discovery grid sizing (user-cyclable card width) ──
var card_w: f32 = 150;

/// Release one cover slot's GPU texture + heap pixels. RENDER-THREAD ONLY — it
/// is the sole owner of textures/pixels, so this never races a worker free.
fn freeCoverSlot(i: usize) void {
    if (sr_cover_tex[i]) |tex| {
        dvui.textureDestroyLater(tex);
        sr_cover_tex[i] = null;
    }
    if (sr_cover_pixels[i]) |px| {
        alloc.free(px);
        sr_cover_pixels[i] = null;
    }
    sr_cover_w[i] = 0;
    sr_cover_h[i] = 0;
}

/// RENDER-THREAD reclaim: once a new search has stamped slots with a fresh
/// generation, drop the textures/pixels left over from the previous search.
/// Runs at the top of the grid render each frame; cheap when nothing changed.
fn reclaimStaleCovers() void {
    const g = search_gen.load(.acquire);
    if (g == covers_render_gen) return;
    for (0..MAX_SEARCH_RESULTS) |i| {
        // A slot belonging to an older generation (or a now-empty slot beyond
        // sr_count) holds stale art — reclaim it. Slots stamped with the live
        // generation keep their freshly-fetched covers.
        if (sr_cover_gen[i] != g) freeCoverSlot(i);
    }
    covers_render_gen = g;
}

pub fn searchComics(query: []const u8) void {
    if (sr_searching or query.len == 0 or query.len >= sr_query_buf.len) return;
    sr_searching = true;
    // Fresh search → reset pagination so infinite-scroll starts at page 1 again.
    sr_page = 1;
    more_available = true;
    // Don't clear sr_count here — the parse repopulates and sets it at the end,
    // so a stale-refresh keeps the old listing on screen until new data lands.
    last_fetch_s = @import("browse_cache.zig").now(); // SWR stamp
    @memcpy(sr_query_buf[0..query.len], query);
    sr_query_len = query.len;
    // Record the fired query so the live-search debouncer doesn't re-issue it.
    @memcpy(last_fired_query[0..query.len], query);
    last_fired_len = query.len;
    const gen = search_gen.fetchAdd(1, .acq_rel) + 1;
    const t = std.Thread.spawn(.{}, searchWorker, .{gen}) catch {
        sr_searching = false;
        return;
    };
    t.detach();
}

/// Build the readallcomics search URL for `query` at WordPress page `paged`
/// (1-based). `paged=1` omits the param (the bare URL is page 1). This is the
/// single source-specific URL seam — adding a source means adding one builder.
fn buildSearchUrl(out: []u8, query: []const u8, paged: u32) ?[:0]const u8 {
    // Endpoint migrated to opal-plugins — null until the user installs "readallcomics".
    const base = @import("../core/source_config.zig").get("readallcomics", "base") orelse return null;
    var encoded_query: [512]u8 = undefined;
    const enc_len = percentEncode(query, &encoded_query);
    const eq = encoded_query[0..enc_len];
    if (paged <= 1) {
        return std.fmt.bufPrintZ(out, "{s}/?story={s}&s=&type=comic", .{ base, eq }) catch null;
    }
    return std.fmt.bufPrintZ(out, "{s}/?story={s}&s=&type=comic&paged={d}", .{ base, eq, paged }) catch null;
}

/// curl a search-results page into `dst`; returns bytes read (0 on failure).
/// Shared by the initial search and the infinite-scroll appender.
fn fetchSearchHtml(url: [:0]const u8, dst: []u8) usize {
    const argv = [_][]const u8{
        "curl",       "-sL",
        "-H",         "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "--max-time", "15",
        url,
    };
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return 0;
    const n = if (child.stdout) |*so| @import("../core/io_global.zig").readAll(so, dst) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

fn searchWorker(gen: u32) void {
    defer sr_searching = false;
    const query = sr_query_buf[0..sr_query_len];

    var url_buf: [640]u8 = undefined;
    const url = buildSearchUrl(&url_buf, query, 1) orelse return;

    const html_buf = alloc.alloc(u8, 512 * 1024) catch return;
    defer alloc.free(html_buf);
    const n = fetchSearchHtml(url, html_buf);
    if (n == 0) return;

    // A newer search superseded us while curl was running — drop these results.
    if (search_gen.load(.acquire) != gen) {
        logs.pushLog("info", "comics", "Comic search superseded (stale dropped)", false);
        return;
    }

    // Page 1 replaces the listing (start index 0).
    const added = parseSearchResults(html_buf[0..n], gen, 0);
    if (added < RESULTS_PER_PAGE) more_available = false;
    logs.pushLog("info", "comics", "Comic search results parsed", false);
}

/// Infinite-scroll appender: fetch the next readallcomics page and merge new
/// rows onto the existing listing (dedup by URL, bounded by MAX_SEARCH_RESULTS).
/// Runs on a detached thread; guarded by `loading_more`.
pub fn loadMoreResults() void {
    if (!more_available or loading_more.load(.acquire) or sr_searching) return;
    if (sr_count == 0 or sr_count >= MAX_SEARCH_RESULTS or sr_query_len == 0) return;
    if (loading_more.swap(true, .acq_rel)) return;
    const t = std.Thread.spawn(.{}, loadMoreWorker, .{search_gen.load(.acquire)}) catch {
        loading_more.store(false, .release);
        return;
    };
    t.detach();
}

fn loadMoreWorker(gen: u32) void {
    defer loading_more.store(false, .release);
    const query = sr_query_buf[0..sr_query_len];
    const next_page = sr_page + 1;

    var url_buf: [640]u8 = undefined;
    const url = buildSearchUrl(&url_buf, query, next_page) orelse return;

    const html_buf = alloc.alloc(u8, 512 * 1024) catch return;
    defer alloc.free(html_buf);
    const n = fetchSearchHtml(url, html_buf);
    if (n == 0) return;

    // Bail if a fresh search started while we were fetching — its page 1 owns
    // the listing now; appending our older page would corrupt/duplicate it.
    if (search_gen.load(.acquire) != gen) return;

    // Append starting at the current end. parseSearchResults dedupes against the
    // existing rows and re-checks `gen` before committing sr_count.
    const start = sr_count;
    const added = parseSearchResults(html_buf[0..n], gen, start);
    if (added == 0 or added < RESULTS_PER_PAGE) more_available = false;
    if (added > 0) sr_page = next_page;
}

/// Decode the handful of HTML entities readallcomics emits inside `title="…"`
/// attributes (apostrophes, ampersands, quotes) into a clean display string.
/// Writes into `out`, returns the byte length used.
fn decodeEntities(in: []const u8, out: []u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    while (i < in.len and o < out.len) {
        if (in[i] == '&') {
            const rest = in[i..];
            if (std.mem.startsWith(u8, rest, "&#039;") or std.mem.startsWith(u8, rest, "&#39;") or std.mem.startsWith(u8, rest, "&apos;")) {
                out[o] = '\'';
                o += 1;
                i += if (rest[2] == '0') @as(usize, 6) else if (rest[1] == '#') @as(usize, 5) else @as(usize, 6);
                continue;
            } else if (std.mem.startsWith(u8, rest, "&amp;")) {
                out[o] = '&';
                o += 1;
                i += 5;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&quot;")) {
                out[o] = '"';
                o += 1;
                i += 6;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&#034;") or std.mem.startsWith(u8, rest, "&#34;")) {
                out[o] = '"';
                o += 1;
                i += if (rest[2] == '0') @as(usize, 6) else @as(usize, 5);
                continue;
            }
        }
        out[o] = in[i];
        o += 1;
        i += 1;
    }
    return o;
}

/// Read the value of an HTML attribute (`name="value"`) located within `html`,
/// searching only up to `limit` bytes ahead. Returns the slice between quotes.
fn attrValue(html: []const u8, name: []const u8, limit: usize) ?[]const u8 {
    const window = html[0..@min(limit, html.len)];
    const at = findSubstring(window, name) orelse return null;
    var p = at + name.len;
    // skip optional whitespace + '=' + opening quote
    while (p < window.len and (window[p] == ' ' or window[p] == '=')) p += 1;
    if (p >= window.len or window[p] != '"') return null;
    p += 1;
    const end = std.mem.indexOfScalar(u8, html[p..], '"') orelse return null;
    return html[p .. p + end];
}

/// Parse the readallcomics search page. Each result is a `class="book-link"`
/// block carrying:
///   • a `title="…"` attribute        → display title
///   • a `<img … class="book-cover">`  → cover art URL
///   • a following `class="latest-chapter"` anchor → the loadable issue URL
/// We anchor on `book-link`, then grab the cover + the latest-chapter href that
/// follow it (bounded by the next book-link so blocks never bleed together).
/// Parse a search page, writing results into sr_* starting at slot `start`.
/// Returns the number of NEW rows appended. With start==0 it (re)populates the
/// listing; with start==sr_count it appends a paginated page (deduped by URL).
fn parseSearchResults(html: []const u8, gen: u32, start: usize) usize {
    // NOTE: we do NOT free textures/pixels here (worker thread). We only stamp
    // each result slot with `gen` and write its cover URL; the render thread's
    // reclaimStaleCovers() drops the previous search's art. This keeps the
    // render thread the sole owner of GPU textures + cover pixel buffers.
    var count: usize = start;
    var pos: usize = 0;
    const block_needle = "class=\"book-link\"";

    while (pos < html.len and count < MAX_SEARCH_RESULTS) {
        const b = findSubstring(html[pos..], block_needle) orelse break;
        const block_at = pos + b;
        // The book-link anchor opens before the class attr — back up to find the
        // enclosing <a … title="…"> for this block.
        const a_open = std.mem.lastIndexOf(u8, html[0..block_at], "<a ") orelse {
            pos = block_at + block_needle.len;
            continue;
        };

        // Where the next result begins — bounds this block's cover/issue search.
        const next_rel = findSubstring(html[block_at + block_needle.len ..], block_needle);
        const block_end = if (next_rel) |nr| block_at + block_needle.len + nr else html.len;
        pos = block_end;

        const block = html[a_open..block_end];

        // ── Title: prefer the title="…" attribute on the book-link anchor. ──
        // (`title=` follows the href in the opening tag, so the window must clear
        // a long category URL — keep it generous but still tag-local.)
        var title_raw: []const u8 = "";
        if (attrValue(block, "title=", 600)) |t| title_raw = t;

        // ── Loadable URL: the latest-chapter anchor's href. ──
        var link: []const u8 = "";
        if (findSubstring(block, "class=\"latest-chapter\"")) |lc| {
            // href appears just before the class on the same anchor — scan back
            // to the anchor open, then read its href forward.
            const lc_abs = lc;
            const a2 = std.mem.lastIndexOf(u8, block[0..lc_abs], "<a ") orelse lc_abs;
            if (attrValue(block[a2..], "href=", 256)) |h| {
                if (std.mem.startsWith(u8, h, "https://readallcomics.com/") and
                    std.mem.indexOf(u8, h, "/category/") == null)
                    link = h;
            }
        }
        // Fallback: if no clean issue link, use the category page (still loads —
        // loadComic will parse its first issue's images, and at worst the user
        // sees the series landing). Better than dropping the result entirely.
        if (link.len == 0) {
            if (attrValue(block, "href=", 256)) |h| {
                if (std.mem.startsWith(u8, h, "https://readallcomics.com/")) link = h;
            }
        }
        if (link.len == 0 or link.len > 255) continue;

        // Title fallback: derive from the link slug.
        var title_buf: [320]u8 = undefined;
        var title: []const u8 = undefined;
        if (title_raw.len > 0) {
            title = title_buf[0..decodeEntities(title_raw, &title_buf)];
        } else {
            const prefix = "https://readallcomics.com/";
            const tail = if (link.len > prefix.len) std.mem.trimEnd(u8, link[prefix.len..], "/") else link;
            title = tail;
        }
        title = std.mem.trim(u8, title, " \t\r\n");
        if (title.len == 0) continue;

        // De-dupe against EVERY row already collected (paginated pages can
        // resurface a series, and the same series may appear twice on a page).
        {
            var dup = false;
            var d: usize = 0;
            while (d < count) : (d += 1) {
                if (std.mem.eql(u8, sr_urls[d][0..sr_url_lens[d]], link)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
        }

        const ulen = @min(link.len, 255);
        @memcpy(sr_urls[count][0..ulen], link[0..ulen]);
        sr_url_lens[count] = ulen;
        const tlen = @min(title.len, 159);
        @memcpy(sr_titles[count][0..tlen], title[0..tlen]);
        sr_title_lens[count] = tlen;

        // ── Cover URL: the book-cover img src within this block. ──
        sr_cover_url_lens[count] = 0;
        if (findSubstring(block, "class=\"book-cover\"")) |bc| {
            // <img src="…" … class="book-cover"> — src is before the class.
            const img_at = std.mem.lastIndexOf(u8, block[0..bc], "<img") orelse bc;
            if (attrValue(block[img_at..], "src=", 1024)) |src| {
                if (std.mem.startsWith(u8, src, "http") and src.len < 512 and src.len > 16) {
                    const clen = @min(src.len, 511);
                    @memcpy(sr_cover_urls[count][0..clen], src[0..clen]);
                    sr_cover_url_lens[count] = clen;
                }
            }
        }
        // Stamp this slot with the live generation so the render thread reclaims
        // the previous occupant's texture/pixels (it owns those) on next frame.
        sr_cover_gen[count] = gen;

        count += 1;
    }

    // Re-check generation before committing — a fresher search may have started
    // while we were parsing. (If so, our slot stamps are already < the live gen,
    // so the render thread reclaims whatever we wrote; nothing leaks.)
    if (search_gen.load(.acquire) != gen) return 0;

    sr_count = count;
    return count - start;
}

/// Lazily fetch one result's cover art on a detached thread:
///   curl -sL (512KB cap) → stbi decode → heap RGBA pixels (uploaded to a GPU
/// texture on the render thread, which then frees the pixels).
/// Guarded by sr_cover_fetching[idx] so a card render can't double-spawn.
fn fetchCover(idx: usize) void {
    if (idx >= MAX_SEARCH_RESULTS) return;
    if (sr_cover_url_lens[idx] == 0) return;
    if (sr_cover_pixels[idx] != null or sr_cover_tex[idx] != null) return;
    // Atomically claim the slot.
    if (sr_cover_fetching[idx].swap(true, .acq_rel)) return; // already in flight

    // Over the global cap: release the slot claim and let the card retry on a
    // later frame once an in-flight slot frees.
    if (cover_in_flight.load(.acquire) >= MAX_COVER_CONCURRENT) {
        sr_cover_fetching[idx].store(false, .release);
        return;
    }
    _ = cover_in_flight.fetchAdd(1, .acq_rel);

    const t = std.Thread.spawn(.{}, coverWorker, .{idx}) catch {
        _ = cover_in_flight.fetchSub(1, .acq_rel);
        sr_cover_fetching[idx].store(false, .release);
        return;
    };
    t.detach();
}

/// Rewrite a cover URL to a thumbnail-sized variant where the host supports it.
/// blogspot / googleusercontent serve full-res by default (a single page can be
/// multiple MB); they accept a size token (`=s400` query-style or `/s400/`
/// path-style). Downscaling to ~400px keeps covers crisp at grid sizes while
/// cutting bandwidth + decode cost ~25×. Writes into `out`, returns the slice.
fn thumbnailize(url: []const u8, out: []u8) []const u8 {
    if (std.mem.indexOf(u8, url, "blogspot.com") == null and
        std.mem.indexOf(u8, url, "googleusercontent.com") == null)
        return url;

    // Query-style: trailing "=sN" (or "=s0", "=s1600"). Replace from '=s'.
    if (std.mem.lastIndexOf(u8, url, "=s")) |eq| {
        // Confirm what's after "=s" is digits to end (a genuine size token).
        var ok = eq + 2 < url.len;
        var k = eq + 2;
        while (k < url.len) : (k += 1) {
            if (!std.ascii.isDigit(url[k])) {
                ok = false;
                break;
            }
        }
        if (ok) {
            const head = url[0..eq];
            const r = std.fmt.bufPrint(out, "{s}=s400", .{head}) catch return url;
            return r;
        }
    }
    // Path-style: ".../sN/filename". Replace the "/sN/" segment with "/s400/".
    if (std.mem.indexOf(u8, url, "/s0/")) |p| {
        const r = std.fmt.bufPrint(out, "{s}/s400/{s}", .{ url[0..p], url[p + 4 ..] }) catch return url;
        return r;
    }
    return url;
}

fn coverWorker(idx: usize) void {
    workers.enter();
    defer workers.leave();
    defer sr_cover_fetching[idx].store(false, .release);
    defer _ = cover_in_flight.fetchSub(1, .acq_rel); // release the global slot

    const raw_url = sr_cover_urls[idx][0..sr_cover_url_lens[idx]];
    if (raw_url.len == 0) return;
    var url_buf: [560]u8 = undefined;
    const url = thumbnailize(raw_url, &url_buf);

    const argv = [_][]const u8{
        "curl",       "-sL",
        "-H",         "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "--max-time", "10",
        url,
    };
    var child = @import("../core/io_global.zig").Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;

    // Heap buffer — never on the thread stack. 4MB covers full-res fallbacks for
    // hosts that ignore the size hint (e.g. raw .jpg with no size token).
    const max_img = 4 * 1024 * 1024;
    const tmp_buf = alloc.alloc(u8, max_img) catch {
        _ = child.wait() catch {};
        return;
    };
    defer alloc.free(tmp_buf);

    var total: usize = 0;
    if (child.stdout) |*so| {
        while (total < max_img) {
            if (workers.isQuitting()) return; // bail mid-download; defer frees tmp_buf
            const n = @import("../core/io_global.zig").read(so, tmp_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    _ = child.wait() catch {};
    if (total < 100) return;

    // Decode → RGBA pixels.
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const pixels = dvui.c.stbi_load_from_memory(tmp_buf.ptr, @intCast(total), &w, &h, &comp, 4);
    if (pixels == null or w <= 0 or h <= 0) return;
    defer dvui.c.stbi_image_free(pixels);

    const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const p_slice = alloc.alloc(u8, p_len) catch return;
    @memcpy(p_slice, pixels[0..p_len]);

    // Publish only if this result slot is still alive (a newer search could have
    // freed/repurposed it) and we're not shutting down (freeSearchCovers may
    // already have run). The render thread uploads + frees the pixels.
    if (sr_cover_url_lens[idx] == 0 or workers.isQuitting()) {
        alloc.free(p_slice);
        return;
    }
    sr_cover_w[idx] = @intCast(w);
    sr_cover_h[idx] = @intCast(h);
    sr_cover_pixels[idx] = p_slice;
}

// ══════════════════════════════════════════════════════════
// UI Rendering
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    drainPageTexFrees(); // free textures queued by the plugin manga-reload worker (UI thread)
    // A comic is open → the reader fills the whole tab (images + tools live in
    // renderPaneContent). Reading happens here in Browse, not the player route.
    if (state.app.comic.is_loading.load(.acquire) or state.app.comic.page_count > 0) {
        var reader = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer reader.deinit();
        renderPaneContent(0);
        return;
    }

    // First open shows a default popular feed so the tab isn't blank (the
    // search box stays free for anything else).
    if (!loaded_default and sr_count == 0 and !sr_searching and state.app.comic.search_buf[0] == 0 and state.app.comic.title_len == 0) {
        loaded_default = true;
        searchComics("spider-man");
    } else if (sr_count > 0 and !sr_searching and sr_query_len > 0 and state.app.comic.title_len == 0 and
        @import("browse_cache.zig").isStale(last_fetch_s))
    {
        // SWR: refresh the current listing in the background once it's stale.
        var q: [256]u8 = undefined;
        @memcpy(q[0..sr_query_len], sr_query_buf[0..sr_query_len]);
        searchComics(q[0..sr_query_len]);
    }

    // Full-page root so loading/empty branches fill width/height.
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer page.deinit();

    // ── Search bar (live-as-you-type + Load button + URL paste) ──
    {
        var search_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_header,
        });
        defer search_row.deinit();

        dvui.icon(@src(), "", icons.tvg.lucide.search, .{}, .{
            .color_text = theme.colors.accent,
            .gravity_y = 0.5,
            .margin = .{ .x = 2, .y = 0, .w = 10, .h = 0 },
            .min_size_content = .{ .w = 20, .h = 20 },
        });

        const input = std.mem.sliceTo(&state.app.comic.search_buf, 0);

        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &state.app.comic.search_buf },
            .placeholder = "Search comics…  (title or paste a readallcomics URL)",
        }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 240, .h = 26 },
            .color_fill = theme.colors.bg_input,
            .color_border = if (input.len > 0) theme.colors.accent else theme.colors.border_input,
            .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(if (input.len > 0) 2 else 1),
            .corner_radius = theme.dims.rad_md,
            .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
            .font = dvui.themeGet().font_heading,
        });
        const enter_pressed = te.enter_pressed;
        te.deinit();

        const is_url = std.mem.startsWith(u8, input, "http");

        // Clear button (×) — visible only when there's text, resets the listing.
        if (input.len > 0) {
            if (dvui.buttonIcon(@src(), "comic-search-clear", icons.tvg.lucide.x, .{}, .{}, .{
                .id_extra = 9100,
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.text_muted,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 6, .y = 5, .w = 6, .h = 5 },
                .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
                .gravity_y = 0.5,
            })) {
                state.app.comic.search_buf[0] = 0;
                last_fired_len = 0;
            }
        }

        const clicked = dvui.button(@src(), "Search", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_md,
            .padding = .{ .x = 14, .y = 6, .w = 14, .h = 6 },
            .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
            .font = dvui.themeGet().font_heading,
        });

        // Explicit submit (Enter / Load) — URLs load directly, text searches.
        if (clicked or enter_pressed) {
            if (input.len > 0) {
                if (is_url) loadComic(input) else searchComics(input);
            }
        } else {
            // ── Live / incremental debounced search ──
            // Fire when: buffer differs from the last fired query, ≥2 chars, not
            // a URL, and 400ms have elapsed since the buffer last changed.
            const now_ms = @import("../core/io_global.zig").milliTimestamp();
            const changed = !(input.len == last_fired_len and std.mem.eql(u8, input, last_fired_query[0..last_fired_len]));
            if (changed) last_edit_ms = now_ms;
            if (changed and input.len >= 2 and !is_url and !sr_searching and
                (now_ms - last_edit_ms) >= 400)
            {
                searchComics(input);
            }
        }
    }

    // ── Source selector (chips) ──
    // ReadAllComics is the only natively-readable source today (its issue pages
    // embed blogspot-CDN images the reader consumes). The "All" chip is the
    // default and aggregates every available source; any user/bundled comic
    // plugins are surfaced as read-only badge chips so the user sees they exist.
    // ── Single unified toolbar row: Source chips · result count · quick-links
    //    · card-size −/+ (wraps if the window is narrow). ──
    {
        var bar = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 6 },
        });
        defer bar.deinit();

        _ = dvui.label(@src(), "Source:", .{}, .{
            .color_text = theme.colors.text_muted,
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
        });
        renderSourceChip("All", 1, .all);
        renderSourceChip("ReadAllComics", 2, .readallcomics);
        renderPluginSourceBadges();

        // Divider between the source group and the result/quick-link group.
        _ = dvui.label(@src(), "  •  ", .{}, .{
            .color_text = theme.colors.border_drawer,
            .gravity_y = 0.5,
        });

        // Result count (or live status).
        {
            var cb: [48]u8 = undefined;
            const cs = if (sr_searching and sr_count == 0)
                @as([]const u8, "Searching…")
            else
                std.fmt.bufPrint(&cb, "{d} results", .{sr_count}) catch "";
            _ = dvui.label(@src(), "{s}", .{cs}, .{
                .color_text = if (sr_searching and sr_count == 0) theme.colors.accent else theme.colors.text_muted,
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            });
        }

        renderChip("Invincible", 1, "https://readallcomics.com/invincible-001/");
        renderChip("The Boys", 2, "https://readallcomics.com/the-boys-001-2006/");
        renderChip("Saga", 3, "https://readallcomics.com/saga-001-2012/");

        if (dvui.buttonIcon(@src(), "comic-card-smaller", icons.tvg.lucide.@"zoom-out", .{}, .{}, .{
            .id_extra = 9001,
            .color_fill = theme.colors.bg_glass,
            .color_text = theme.colors.text_main,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 4, .w = 5, .h = 4 },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
        })) {
            card_w = std.math.clamp(card_w - 20, 110, 300);
        }
        if (dvui.buttonIcon(@src(), "comic-card-bigger", icons.tvg.lucide.@"zoom-in", .{}, .{}, .{
            .id_extra = 9002,
            .color_fill = theme.colors.bg_glass,
            .color_text = theme.colors.text_main,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 4, .w = 5, .h = 4 },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
        })) {
            card_w = std.math.clamp(card_w + 20, 110, 300);
        }
    }

    // ── Cover-grid discovery ──
    if (sr_count == 0 and sr_searching) {
        _ = dvui.label(@src(), "Searching…", .{}, .{
            .color_text = theme.colors.accent,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }
    if (sr_count == 0) {
        _ = dvui.label(@src(), "No comics found. Try another title.", .{}, .{
            .color_text = theme.colors.text_muted,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    // Render-thread reclaim of the previous search's cover art (textures+pixels)
    // before drawing the current grid — keeps the render thread the sole owner.
    reclaimStaleCovers();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_drawer });
    defer scroll.deinit();

    // Responsive columns from the live page width (one-frame lag on first paint).
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / card_w)));
    const cw: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));
    const cover_h: f32 = cw * 1.5; // comic covers ~2:3 portrait

    var i: usize = 0;
    while (i < sr_count) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 50000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and i + col < sr_count) : (col += 1) {
            renderCoverCard(i + col, cw, cover_h);
        }
        i += cols;
    }

    // ── Infinite scroll: a status row at the grid's tail. When it scrolls into
    // view (viewport bottom within one viewport-height of content end) we kick
    // the next-page appender. The row also doubles as a tap-to-load affordance.
    if (more_available and sr_count > 0 and sr_count < MAX_SEARCH_RESULTS) {
        const busy = loading_more.load(.acquire);
        const lbl = if (busy) "Loading more…" else "▾ Load more";
        if (dvui.button(@src(), lbl, .{}, .{
            .id_extra = 60001,
            .expand = .horizontal,
            .color_fill = theme.colors.bg_glass,
            .color_text = theme.colors.accent,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 8, .y = 12, .w = 8, .h = 12 },
            .margin = .{ .x = 3, .y = 8, .w = 3, .h = 12 },
            .gravity_x = 0.5,
        })) {
            loadMoreResults();
        }

        // Auto-trigger when the user scrolls near the bottom (within 1.5 view-
        // ports of the content end), so it feels infinite without a click.
        const si = scroll.si;
        const max_scroll = si.scrollMax(.vertical);
        if (max_scroll > 0 and si.viewport.y >= max_scroll - si.viewport.h * 1.5) {
            loadMoreResults();
        }
    } else if (!more_available and sr_count > RESULTS_PER_PAGE) {
        _ = dvui.label(@src(), "— end of results —", .{}, .{
            .id_extra = 60002,
            .expand = .horizontal,
            .color_text = theme.colors.text_muted,
            .gravity_x = 0.5,
            .margin = .{ .x = 0, .y = 8, .w = 0, .h = 12 },
        });
    }
}

/// A source-selector chip. Active source is highlighted; clicking it re-runs the
/// current query against that source. Today only readallcomics returns rows, so
/// "All" and "ReadAllComics" behave identically — but the seam is ready for more.
fn renderSourceChip(label: []const u8, id: usize, src: Source) void {
    const active = active_source == src;
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = id + 72000,
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_glass,
        .color_text = if (active) dvui.Color.white else theme.colors.text_main,
        .corner_radius = theme.dims.rad_md,
        .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        .gravity_y = 0.5,
    })) {
        if (active_source != src) {
            active_source = src;
            // Re-run the live listing under the new source filter.
            if (sr_query_len > 0) {
                var q: [256]u8 = undefined;
                @memcpy(q[0..sr_query_len], sr_query_buf[0..sr_query_len]);
                searchComics(q[0..sr_query_len]);
            }
        }
    }
}

/// Surface comic plugins (bundled + user) as non-interactive badge chips so the
/// user can SEE which extra sources are installed. Plugins resolve issue URLs at
/// load time (tryPlugins), so they extend every source transparently — there's
/// no per-plugin search index to query, hence read-only badges.
fn renderPluginSourceBadges() void {
    var shown: usize = 0;
    showPluginBadgesInDir("plugins", &shown);
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/zigzag/plugins/comics", .{home}) catch return;
    showPluginBadgesInDir(dir_path, &shown);
}

fn showPluginBadgesInDir(dir_path: []const u8, shown: *usize) void {
    var dir = @import("../core/io_global.zig").cwdOpenDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close(@import("../core/io_global.zig").io());
    var iter = dir.iterate();
    while (iter.next(@import("../core/io_global.zig").io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        const stem: []const u8 = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| blk: {
            const ext = name[dot..];
            if (!std.mem.eql(u8, ext, ".lua") and !std.mem.eql(u8, ext, ".py") and !std.mem.eql(u8, ext, ".sh")) continue;
            break :blk name[0..dot];
        } else continue;
        if (shown.* >= 6 or stem.len == 0) return; // bound the chip row
        var lbl_buf: [80]u8 = undefined;
        const lbl = std.fmt.bufPrint(&lbl_buf, "{s}", .{safeUtf8(stem)}) catch continue;
        _ = dvui.label(@src(), "{s}", .{lbl}, .{
            .id_extra = shown.* + 73000,
            .color_text = theme.colors.text_secondary,
            .color_fill = theme.colors.bg_glass,
            .background = true,
            .corner_radius = theme.dims.rad_md,
            .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
            .gravity_y = 0.5,
        });
        shown.* += 1;
    }
}

/// A toolbar quick-link chip that loads a known issue directly.
fn renderChip(label: []const u8, id: usize, url: []const u8) void {
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = id + 70000,
        .color_fill = theme.colors.bg_glass,
        .color_text = theme.colors.accent,
        .corner_radius = theme.dims.rad_md,
        .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        .gravity_y = 0.5,
    })) {
        loadComic(url);
    }
}

/// One discovery card: cover art (or gradient placeholder) + title, clickable to
/// load the issue. Hover reveals the full title over a dimmed scrim.
fn renderCoverCard(idx: usize, cw: f32, cover_h: f32) void {
    // Stable copy: sr_titles is rewritten by the search worker mid-frame, so a
    // validated slice into the live buffer can still let dvui re-read mutated bytes.
    var title_buf: [256]u8 = undefined;
    const title = @import("../core/text.zig").safeUtf8Buf(sr_titles[idx][0..sr_title_lens[idx]], &title_buf);
    // Deterministic gradient from a title hash (placeholder + glyph tint).
    const hash: u32 = blk: {
        var h: u32 = 2166136261;
        for (sr_titles[idx][0..sr_title_lens[idx]]) |c| {
            h = (h ^ c) *% 16777619;
        }
        break :blk h;
    };
    const h1: u8 = @truncate(hash & 0xFF);
    const h2: u8 = @truncate((hash >> 8) & 0xFF);

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx,
        .min_size_content = .{ .w = cw, .h = 10 },
        .max_size_content = .{ .w = cw, .h = cover_h + 56 },
        .margin = .{ .x = 3, .y = 3, .w = 3, .h = 3 },
    });
    defer card.deinit();

    // Cover image area — a single clickable button-widget hosting the image.
    {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = idx + 100,
            .background = true,
            .color_fill = dvui.Color{ .r = 18 + h1 / 8, .g = 22 + h2 / 10, .b = 32 + h1 / 6, .a = 255 },
            .corner_radius = dvui.Rect.all(8),
            .min_size_content = .{ .w = cw, .h = cover_h },
            .max_size_content = .{ .w = cw, .h = cover_h },
            .padding = dvui.Rect.all(0),
        });
        bw.processEvents();
        bw.drawBackground();

        // Upload pixels → texture on the render thread, then free the pixels.
        if (sr_cover_tex[idx] == null and sr_cover_pixels[idx] != null) {
            const np: usize = @as(usize, sr_cover_w[idx]) * @as(usize, sr_cover_h[idx]);
            const pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(sr_cover_pixels[idx].?.ptr)))[0..np];
            sr_cover_tex[idx] = dvui.textureCreate(pma, sr_cover_w[idx], sr_cover_h[idx], .linear, .rgba_32) catch null;
            if (sr_cover_tex[idx] != null) {
                alloc.free(sr_cover_pixels[idx].?);
                sr_cover_pixels[idx] = null;
            }
        }

        {
            var stack = dvui.overlay(@src(), .{ .id_extra = idx + 140, .expand = .both });
            defer stack.deinit();

            if (sr_cover_tex[idx]) |*tex| {
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex.* } }, .{
                    .id_extra = idx + 150,
                    .expand = .both,
                    .corner_radius = dvui.Rect.all(8),
                });
            } else {
                // Lazy-trigger fetch; meanwhile show a glyph placeholder.
                if (sr_cover_url_lens[idx] > 0) fetchCover(idx);
                dvui.icon(@src(), "", icons.tvg.lucide.@"book-open", .{}, .{
                    .id_extra = idx + 150,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .color_text = dvui.Color{ .r = h1, .g = h2, .b = 200, .a = 70 },
                    .expand = .both,
                });
                // Placeholder cards still show the title inside the cover area.
                if (sr_cover_url_lens[idx] == 0) {
                    _ = dvui.label(@src(), "{s}", .{title}, .{
                        .id_extra = idx + 151,
                        .expand = .horizontal,
                        .gravity_y = 0.85,
                        .color_text = theme.colors.text_secondary,
                        .padding = dvui.Rect.all(6),
                    });
                }
            }

            // Hover scrim with the full (wrapping) title.
            if (bw.hovered()) {
                var ov = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = idx + 160,
                    .expand = .both,
                    .background = true,
                    .color_fill = dvui.Color{ .r = 8, .g = 10, .b = 16, .a = 224 },
                    .corner_radius = dvui.Rect.all(8),
                    .padding = dvui.Rect.all(8),
                });
                defer ov.deinit();
                _ = dvui.label(@src(), "{s}", .{title}, .{
                    .id_extra = idx + 161,
                    .expand = .horizontal,
                    .gravity_y = 0.5,
                    .color_text = theme.colors.text_main,
                    .font = dvui.themeGet().font_heading,
                });
            }
        }

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (clicked) {
            loadComic(sr_urls[idx][0..sr_url_lens[idx]]);
        }
    }

    // Title caption below the cover (single-line, ellipsis via max height).
    _ = dvui.label(@src(), "{s}", .{title}, .{
        .id_extra = idx + 200,
        .expand = .horizontal,
        .color_text = theme.colors.text_main,
        .max_size_content = .{ .w = cw, .h = 40 },
        .padding = .{ .x = 2, .y = 3, .w = 2, .h = 0 },
    });
}

// ══════════════════════════════════════════════════════════
// Main Pane Content Rendering (full-area comic viewer)
// Called from ui.zig grid cell when provider == .comic_viewer
// ══════════════════════════════════════════════════════════

pub fn renderPaneContent(pane_idx: usize) void {
    _ = pane_idx;

    if (state.app.comic.is_loading.load(.acquire)) {
        // Show download progress
        var prog_buf: [64]u8 = undefined;
        const prog_str = std.fmt.bufPrintZ(&prog_buf, "Loading comic... {d}/{d} pages", .{
            state.app.comic.dl_progress.load(.acquire), state.app.comic.page_count,
        }) catch "Loading...";
        _ = dvui.label(@src(), "{s}", .{prog_str}, .{
            .color_text = theme.colors.accent,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .expand = .both,
        });
        return;
    }

    // Title bar + navigation + controls
    {
        var nav_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
            .background = true,
            .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 22, .a = 245 },
        });
        defer nav_row.deinit();

        // Prev issue
        if (state.app.comic.prev_url_len > 0) {
            if (dvui.button(@src(), "«", .{}, .{
                .color_fill = theme.colors.accent,
                .color_text = dvui.Color.white,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
            })) {
                loadComic(state.app.comic.prev_url[0..state.app.comic.prev_url_len]);
            }
        }

        // Title
        if (state.app.comic.title_len > 0) {
            _ = dvui.label(@src(), "{s}", .{safeUtf8(state.app.comic.title[0..state.app.comic.title_len])}, .{
                .color_text = theme.colors.text_main,
                .expand = .horizontal,
                .gravity_x = 0.5,
            });
        }

        // Page info + progress
        {
            var info_buf: [64]u8 = undefined;
            const info = if (state.app.comic.view_mode == .single_page)
                std.fmt.bufPrintZ(&info_buf, "{d}/{d}", .{ state.app.comic.current_page + 1, state.app.comic.page_count }) catch "?"
            else
                std.fmt.bufPrintZ(&info_buf, "{d}pp {d}↓", .{ state.app.comic.page_count, state.app.comic.dl_progress.load(.acquire) }) catch "?";
            _ = dvui.label(@src(), "{s}", .{info}, .{
                .color_text = theme.colors.text_muted,
                .padding = .{ .x = 4, .y = 0, .w = 2, .h = 0 },
            });
        }

        // View mode toggle
        {
            const mode_icon = if (state.app.comic.view_mode == .scroll) icons.tvg.lucide.@"scroll-text" else icons.tvg.lucide.@"book-open";
            if (dvui.buttonIcon(@src(), "comic-view-mode", mode_icon, .{}, .{}, .{
                .id_extra = 10,
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.text_main,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            })) {
                state.app.comic.view_mode = if (state.app.comic.view_mode == .scroll) .single_page else .scroll;
            }
        }

        // Page navigation (works in both modes)
        if (state.app.comic.current_page > 0) {
            if (dvui.button(@src(), "‹", .{}, .{
                .id_extra = 11,
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.text_main,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            })) {
                state.app.comic.current_page -= 1;
                state.app.comic.scroll_to_page = true;
            }
        }
        if (state.app.comic.current_page + 1 < state.app.comic.page_count) {
            if (dvui.button(@src(), "›", .{}, .{
                .id_extra = 12,
                .color_fill = theme.colors.bg_glass,
                .color_text = theme.colors.text_main,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
                .margin = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
            })) {
                state.app.comic.current_page += 1;
                state.app.comic.scroll_to_page = true;
            }
        }

        // Next issue
        if (state.app.comic.next_url_len > 0) {
            if (dvui.button(@src(), "»", .{}, .{
                .id_extra = 1,
                .color_fill = theme.colors.accent,
                .color_text = dvui.Color.white,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            })) {
                loadComic(state.app.comic.next_url[0..state.app.comic.next_url_len]);
            }
        }

        // Spacer to push narration controls to the right
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }

        // OCR text toggle
        if (dvui.buttonIcon(@src(), "comic-ocr", icons.tvg.lucide.@"scan-text", .{}, .{}, .{
            .id_extra = 20,
            .color_fill = if (state.app.comic.show_ocr_overlay) theme.colors.accent else theme.colors.bg_glass,
            .color_text = if (state.app.comic.show_ocr_overlay) dvui.Color.white else theme.colors.text_main,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
            .margin = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
        })) {
            ocrCurrentPage();
        }

        // Narrate toggle
        if (dvui.buttonIcon(@src(), "comic-narrate", if (state.app.comic.narrating) icons.tvg.lucide.@"circle-stop" else icons.tvg.lucide.@"volume-2", .{}, .{}, .{
            .id_extra = 21,
            .color_fill = if (state.app.comic.narrating) theme.colors.accent else theme.colors.bg_glass,
            .color_text = if (state.app.comic.narrating) dvui.Color.white else theme.colors.text_main,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
            .margin = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
        })) {
            toggleNarration();
        }

        // Close the reader → back to the comics browse/search view.
        if (dvui.buttonIcon(@src(), "comic-close", icons.tvg.lucide.x, .{}, .{}, .{
            .id_extra = 2,
            .color_fill = dvui.Color{ .r = 60, .g = 20, .b = 20, .a = 200 },
            .color_text = theme.colors.danger,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
            .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
        })) {
            closeComic();
        }
    }

    // ── Reader keyboard navigation (handled in-scope; input.zig untouched) ──
    // Left / J → previous page · Right / K → next page. Works in both view
    // modes (in scroll mode it nudges current_page + flags scroll_to_page, which
    // the block below converts into single-page for a clean jump). Issue nav
    // stays on the «/» buttons.
    for (dvui.events()) |*e| {
        if (e.evt != .key) continue;
        const ke = e.evt.key;
        if (ke.action != .down and ke.action != .repeat) continue;
        const prev = ke.code == .left or ke.code == .j;
        const next = ke.code == .right or ke.code == .k;
        if (!prev and !next) continue;
        if (prev and state.app.comic.current_page > 0) {
            state.app.comic.current_page -= 1;
            state.app.comic.scroll_to_page = true;
            e.handled = true;
        } else if (next and state.app.comic.current_page + 1 < state.app.comic.page_count) {
            state.app.comic.current_page += 1;
            state.app.comic.scroll_to_page = true;
            e.handled = true;
        }
    }

    // Content area
    // When narrating, force single page mode for reliable page advancement
    if (state.app.comic.scroll_to_page) {
        state.app.comic.scroll_to_page = false;
        if (state.app.comic.view_mode == .scroll) {
            state.app.comic.view_mode = .single_page;
        }
    }

    if (state.app.comic.view_mode == .single_page) {
        // Single page mode
        var sp_scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .background = true,
            .color_fill = dvui.Color{ .r = 8, .g = 8, .b = 10, .a = 255 },
        });
        defer sp_scroll.deinit();

        // Get available width from scroll area for proper image scaling
        const avail_w = sp_scroll.data().contentRect().w;

        const pg = state.app.comic.current_page;
        if (pg < state.app.comic.page_count) {
            decodePageTexture(pg);
            if (state.app.comic.page_textures[pg]) |tex| {
                const tw = state.app.comic.page_widths[pg];
                const th = state.app.comic.page_heights[pg];
                // Fit-to-width: scale image to fill available width, maintain aspect ratio
                const display_w = if (avail_w > 10) avail_w - 4 else @as(f32, @floatFromInt(tw));
                const scale = display_w / @as(f32, @floatFromInt(tw));
                const display_h = @as(f32, @floatFromInt(th)) * scale;
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
                    .id_extra = pg + 10000,
                    .min_size_content = .{ .w = display_w, .h = display_h },
                    .gravity_x = 0.5,
                    .gravity_y = 0.0,
                });
            } else {
                _ = dvui.label(@src(), "Downloading...", .{}, .{
                    .color_text = theme.colors.text_muted,
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .both,
                });
            }
        }
    } else {
        // Scroll mode — all pages stacked vertically
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .background = true,
            .color_fill = dvui.Color{ .r = 8, .g = 8, .b = 10, .a = 255 },
        });
        defer scroll.deinit();

        // Get available width from scroll area
        const avail_w = scroll.data().contentRect().w;

        // Only render pages near current page to avoid GPU memory exhaustion
        const render_start = if (state.app.comic.current_page > 2) state.app.comic.current_page - 2 else 0;
        const render_end = @min(state.app.comic.current_page + 5, state.app.comic.page_count);

        for (0..state.app.comic.page_count) |pg| {
            var page_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = pg,
                .gravity_x = 0.5,
                .padding = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
            });
            defer page_box.deinit();

            // Only decode/render pages in the visible window
            if (pg < render_start or pg >= render_end) {
                // Placeholder for off-screen pages — keep layout space
                var h_buf: [48]u8 = undefined;
                const h_lbl = std.fmt.bufPrintZ(&h_buf, "Page {d}", .{pg + 1}) catch "...";
                _ = dvui.label(@src(), "{s}", .{h_lbl}, .{
                    .id_extra = pg + 12000,
                    .color_text = theme.colors.text_muted,
                    .gravity_x = 0.5,
                    .min_size_content = .{ .w = 100, .h = 200 },
                });
                continue;
            }

            decodePageTexture(pg);

            if (state.app.comic.page_textures[pg]) |tex| {
                const tw = state.app.comic.page_widths[pg];
                const th = state.app.comic.page_heights[pg];
                // Fit-to-width: scale image to fill available width, maintain aspect ratio
                const display_w = if (avail_w > 10) avail_w - 4 else @as(f32, @floatFromInt(tw));
                const scale_s = display_w / @as(f32, @floatFromInt(tw));
                const display_h = @as(f32, @floatFromInt(th)) * scale_s;
                _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
                    .id_extra = pg + 10000,
                    .min_size_content = .{ .w = display_w, .h = display_h },
                    .gravity_x = 0.5,
                });
            } else if (state.app.comic.page_pixels[pg] == null) {
                var lbl_buf: [48]u8 = undefined;
                const lbl = std.fmt.bufPrintZ(&lbl_buf, "Page {d} downloading...", .{pg + 1}) catch "?";
                _ = dvui.label(@src(), "{s}", .{lbl}, .{
                    .id_extra = pg + 11000,
                    .color_text = theme.colors.text_muted,
                    .gravity_x = 0.5,
                    .padding = .{ .x = 0, .y = 20, .w = 0, .h = 20 },
                });
            }
        }
    }

    // ═══════════════════════════════════════════════════════
    // OCR Text Overlay (shows extracted text at bottom)
    // ═══════════════════════════════════════════════════════
    if (state.app.comic.show_ocr_overlay) {
        const pg = state.app.comic.current_page;
        if (pg < 128 and state.app.comic.ocr_done[pg]) {
            const text_len = state.app.comic.ocr_lens[pg];
            var ocr_panel = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = true,
                .color_fill = dvui.Color{ .r = 10, .g = 10, .b = 14, .a = 230 },
                .color_border = theme.colors.accent,
                .border = .{ .x = 0, .y = 1, .w = 0, .h = 0 },
                .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
                .max_size_content = .{ .w = 0, .h = 120 },
            });
            defer ocr_panel.deinit();

            var ocr_scroll = dvui.scrollArea(@src(), .{}, .{
                .expand = .both,
                // background=false: don't paint the scrollArea's default (light)
                // fill over the dark OCR panel above (color_fill 10,10,14). Same
                // theme-respect fix as the dev-log scroll area.
                .background = false,
            });
            defer ocr_scroll.deinit();

            if (text_len > 0) {
                // OCR output is raw PP-OCR bytes (and @min-truncated to 4095,
                // which can cut a codepoint) — invalid UTF-8 drawn to dvui panics
                // the whole app. Snapshot+validate a copy (worker rewrites this
                // buffer mid-frame, so safeUtf8Buf, not plain safeUtf8).
                var ocr_safe_buf: [4096]u8 = undefined;
                const ocr_safe = @import("../core/text.zig").safeUtf8Buf(state.app.comic.ocr_texts[pg][0..text_len], &ocr_safe_buf);
                _ = dvui.label(@src(), "{s}", .{ocr_safe}, .{
                    .id_extra = 30000,
                    .color_text = theme.colors.text_main,
                });
            } else {
                _ = dvui.label(@src(), "No text detected on this page", .{}, .{
                    .id_extra = 30001,
                    .color_text = theme.colors.text_muted,
                });
            }
        } else if (pg < 128 and !state.app.comic.ocr_done[pg]) {
            _ = dvui.label(@src(), "Running OCR...", .{}, .{
                .id_extra = 30002,
                .color_text = theme.colors.accent,
                .padding = .{ .x = 10, .y = 4, .w = 0, .h = 4 },
            });
        }
    }

    // Narration indicator
    if (state.app.comic.narrating) {
        _ = dvui.label(@src(), "Narrating...", .{}, .{
            .id_extra = 30010,
            .color_text = theme.colors.accent,
            .padding = .{ .x = 10, .y = 3, .w = 0, .h = 3 },
            .background = true,
            .color_fill = dvui.Color{ .r = 10, .g = 10, .b = 14, .a = 200 },
        });
    }
}

/// Decode a single page from JPEG bytes → dvui.Texture (if not already done)
// Per-page latch: a page whose bytes can't be decoded must be attempted at most
// once, else decodePageTexture re-runs a multi-MB stbi decode every frame on the
// UI thread. Reset in freeComicPages when the page set is replaced. UI-thread only.
var page_decode_failed: [128]bool = [_]bool{false} ** 128;

fn decodePageTexture(pg: usize) void {
    if (pg >= 128) return;
    if (state.app.comic.page_pixels[pg] != null and state.app.comic.page_textures[pg] == null and !page_decode_failed[pg]) {
        const raw = state.app.comic.page_pixels[pg].?;
        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        const rgba = dvui.c.stbi_load_from_memory(
            raw.ptr,
            @as(c_int, @intCast(raw.len)),
            &w,
            &h,
            &channels,
            4,
        );
        if (rgba != null and w > 0 and h > 0) {
            const uw: u32 = @intCast(w);
            const uh: u32 = @intCast(h);
            const pixel_count = @as(usize, uw) * @as(usize, uh);
            const pma_slice: [*]const dvui.Color.PMA = @ptrCast(@alignCast(rgba));
            if (dvui.textureCreate(pma_slice[0..pixel_count], uw, uh, .linear, .rgba_32)) |tex| {
                state.app.comic.page_textures[pg] = tex;
                state.app.comic.page_widths[pg] = uw;
                state.app.comic.page_heights[pg] = uh;
            } else |_| {}
            dvui.c.stbi_image_free(rgba);
        } else {
            // Undecodable bytes — latch so we don't retry the heavy decode each frame.
            page_decode_failed[pg] = true;
            if (rgba != null) dvui.c.stbi_image_free(rgba);
        }
    }
}
// ══════════════════════════════════════════════════════════
// OCR + TTS Narration
// ══════════════════════════════════════════════════════════

// Native ONNX Runtime OCR via C wrapper
const ocr_c = @cImport({
    @cInclude("ocr_ort.h");
});

var ocr_initialized: bool = false;

fn ensureOcrInit() bool {
    if (ocr_initialized) return true;

    // Model paths: prefer PP-OCRv5 (much better accuracy), fall back to v4
    const det_path = "models/ppocr_det_v5.onnx";
    const rec_path = "models/ppocr_rec_v5.onnx";
    const dict_path = "models/en_dict_v5.txt";

    const ret = ocr_c.ocr_init(det_path, rec_path, dict_path);
    if (ret != 0) {
        logs.pushLog("error", "comics", "OCR init failed — check models/ directory", true);
        return false;
    }
    ocr_initialized = true;
    logs.pushLog("info", "comics", "OCR initialized (PP-OCRv5 ONNX)", false);
    return true;
}

/// Run OCR on a comic page using native ONNX Runtime.
/// Decodes JPEG→RGBA, passes pixels to C wrapper, caches result.
pub fn ocrPage(pg: usize) void {
    if (pg >= state.app.comic.page_count) return;
    if (state.app.comic.ocr_done[pg]) return;

    const raw = state.app.comic.page_pixels[pg] orelse return;

    if (!ensureOcrInit()) {
        state.app.comic.ocr_done[pg] = true;
        return;
    }

    // Decode JPEG to RGBA
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const rgba = dvui.c.stbi_load_from_memory(
        raw.ptr,
        @as(c_int, @intCast(raw.len)),
        &w,
        &h,
        &channels,
        4,
    );
    if (rgba == null or w <= 0 or h <= 0) {
        state.app.comic.ocr_done[pg] = true;
        return;
    }
    defer dvui.c.stbi_image_free(rgba);

    // Run OCR via C wrapper
    const result = ocr_c.ocr_recognize_rgba(
        @ptrCast(rgba),
        w,
        h,
    );

    if (result != null) {
        const text: [*:0]const u8 = result.?;
        const text_slice = std.mem.span(text);
        const trimmed = std.mem.trim(u8, text_slice, " \t\r\n");
        const len = @min(trimmed.len, 4095);
        @memcpy(state.app.comic.ocr_texts[pg][0..len], trimmed[0..len]);
        state.app.comic.ocr_lens[pg] = len;
        ocr_c.ocr_free_text(result);
    }
    state.app.comic.ocr_done[pg] = true;
}

/// Toggle auto-narration mode
pub fn toggleNarration() void {
    if (state.app.comic.narrating) {
        // Stop narration
        state.app.comic.narrating = false;
        logs.pushLog("info", "comics", "Narration stopped", false);
    } else {
        // Start narration from current page
        state.app.comic.narrating = true;
        state.app.comic.narrate_page = state.app.comic.current_page;

        if (state.app.comic.narrate_thread) |t| t.join();
        state.app.comic.narrate_thread = std.Thread.spawn(.{}, narrationThread, .{}) catch {
            state.app.comic.narrating = false;
            logs.pushLog("error", "comics", "Failed to start narration thread", true);
            return;
        };
        logs.pushLog("info", "comics", "Narration started", false);
    }
}

/// Filter OCR text to extract only speech bubble dialogue.
/// Strips sound effects (BOOM, CRASH), page numbers, credits, watermarks.
fn filterDialogue(raw: []const u8, out: *[4096]u8) usize {
    var pos: usize = 0;

    // Process line by line
    var line_start: usize = 0;
    for (raw, 0..) |ch, i| {
        if (ch == '\n' or i == raw.len - 1) {
            const end = if (ch == '\n') i else i + 1;
            if (end > line_start) {
                const line = std.mem.trim(u8, raw[line_start..end], " \t\r\n");
                if (isDialogueLine(line)) {
                    // Append to output
                    const space_needed = line.len + 1; // +1 for space separator
                    if (pos + space_needed < 4096) {
                        if (pos > 0) {
                            out[pos] = ' ';
                            pos += 1;
                        }
                        @memcpy(out[pos .. pos + line.len], line);
                        pos += line.len;
                    }
                }
            }
            line_start = i + 1;
        }
    }

    return pos;
}

/// Determine if an OCR text line is likely speech bubble dialogue (not SFX/credits/noise).
fn isDialogueLine(line: []const u8) bool {
    if (line.len < 2) return false;

    // Skip bare numbers (page numbers)
    var all_digits = true;
    for (line) |c| {
        if (!std.ascii.isDigit(c) and c != ' ' and c != '-' and c != '.') {
            all_digits = false;
            break;
        }
    }
    if (all_digits) return false;

    // Skip website/credit markers
    const noise_markers = [_][]const u8{
        "http",      ".com",          ".net",             ".org",             "www.",
        "©",
        "copyright", "readallcomics", "readcomicsonline", "chapter",          "vol.",
        "volume",    "issue",         "next chapter",     "previous chapter", "bookmark",
        "comment",   "loading",
    };
    var lower_buf: [256]u8 = undefined;
    const lower_len = @min(line.len, 255);
    for (0..lower_len) |i| lower_buf[i] = std.ascii.toLower(line[i]);
    const lower = lower_buf[0..lower_len];

    for (noise_markers) |marker| {
        if (std.mem.indexOf(u8, lower, marker) != null) return false;
    }

    // Count properties
    var upper_count: usize = 0;
    var lower_count: usize = 0;
    var alpha_count: usize = 0;
    var word_count: usize = 1;
    var prev_space = false;

    for (line) |c| {
        if (std.ascii.isUpper(c)) {
            upper_count += 1;
            alpha_count += 1;
        } else if (std.ascii.isLower(c)) {
            lower_count += 1;
            alpha_count += 1;
        }

        if (c == ' ') {
            if (!prev_space) word_count += 1;
            prev_space = true;
        } else {
            prev_space = false;
        }
    }

    if (alpha_count == 0) return false;

    // Single-word ALL-CAPS with 2-8 chars = SFX (BOOM, CRASH, WHAM, THUD, etc.)
    if (word_count == 1 and upper_count == alpha_count and alpha_count >= 2 and alpha_count <= 10) {
        // Common SFX patterns — reject them
        const sfx_patterns = [_][]const u8{
            "BOOM",    "CRASH",  "WHAM",   "THUD",   "BANG",    "CRACK",
            "SPLASH",  "WHOOSH", "SLAM",   "SMASH",  "POW",     "ZAP",
            "THWACK",  "CLANG",  "SNAP",   "CLICK",  "THUMP",   "ROAR",
            "SCREECH", "SWOOSH", "RUMBLE", "CRUNCH", "SHATTER", "KABOOM",
            "BLAM",    "FWOOSH", "KRACK",  "SKREEE",
        };
        for (sfx_patterns) |sfx| {
            if (std.mem.eql(u8, line, sfx)) return false;
        }
        // Other all-caps single words under 5 chars are also likely SFX
        if (alpha_count <= 5) return false;
    }

    // Two-word ALL-CAPS with total < 12 chars: likely SFX too (HA HA, NO NO)
    if (word_count == 2 and upper_count == alpha_count and alpha_count < 12) {
        return false;
    }

    // Multi-word text with mixed case or longer sentences = dialogue
    // ALL-CAPS multi-word is OK if it's 3+ words (dialogue often in caps in comics)
    if (word_count >= 2 and alpha_count >= 4) return true;

    // Single word with lowercase = likely dialogue fragment
    if (lower_count > 0 and alpha_count >= 3) return true;

    return false;
}

/// Background narration: OCR current page → TTS → wait → advance → repeat
fn narrationThread() void {
    // NOTE: `narrating` is read without synchronization — the worst case is
    // one extra loop iteration before we notice cancellation.  Acceptable
    // because the thread performs no destructive writes once cancelled.
    const ai_voice = @import("ai_voice.zig");

    // Ensure TTS server is warmed up (with timeout so we don't block forever)
    ai_voice.ensureTtsServer();

    while (state.app.comic.narrating) {
        const pg = state.app.comic.narrate_page;
        if (pg >= state.app.comic.page_count) {
            // Reached end of comic
            state.app.comic.narrating = false;
            logs.pushLog("info", "comics", "Narration complete (end of issue)", false);
            break;
        }

        // Wait for page image to be downloaded
        var wait: usize = 0;
        while (state.app.comic.page_pixels[pg] == null and wait < 100 and state.app.comic.narrating) : (wait += 1) {
            @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        }
        if (!state.app.comic.narrating) break;
        if (state.app.comic.page_pixels[pg] == null) {
            // Skip page if still not downloaded
            state.app.comic.narrate_page += 1;
            continue;
        }

        // Update visible page to match narration + trigger scroll
        state.app.comic.current_page = pg;
        state.app.comic.scroll_to_page = true; // Signal render loop to scroll

        // OCR the page
        ocrPage(pg);

        // Get the text and filter to dialogue only
        const text_len = state.app.comic.ocr_lens[pg];
        var had_dialogue = false;

        if (text_len > 0) {
            const text = state.app.comic.ocr_texts[pg][0..text_len];

            // Filter: extract only speech bubble dialogue, skip SFX/credits/noise
            var dialogue_buf: [4096]u8 = undefined;
            const dialogue_len = filterDialogue(text, &dialogue_buf);

            if (dialogue_len > 0) {
                had_dialogue = true;

                // Wait for any existing speech to finish
                while (ai_voice.is_speaking and state.app.comic.narrating) {
                    @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
                }
                if (!state.app.comic.narrating) break;

                // Speak the filtered dialogue
                ai_voice.speakResponse(dialogue_buf[0..dialogue_len]);

                // Wait for TTS to finish
                while (ai_voice.is_speaking and state.app.comic.narrating) {
                    @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
                }
                if (!state.app.comic.narrating) break;
            }
        }

        // Pause between pages:
        //   - Pages with dialogue: 1 second (TTS already provided viewing time)
        //   - Pages without dialogue: 3 seconds (give user time to read/view)
        const pause_iters: usize = if (had_dialogue) 10 else 30;
        var pause: usize = 0;
        while (pause < pause_iters and state.app.comic.narrating) : (pause += 1) {
            @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        }

        // Advance to next page
        if (state.app.comic.narrating) {
            state.app.comic.narrate_page += 1;
        }
    }

    state.app.comic.narrating = false;
}

/// True while an ocrCurrentPage worker is running. Lets the re-trigger skip
/// without blocking the UI thread on Thread.join (OCR ML inference is ~seconds).
var ocr_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Run OCR on current page in background (for "show text" button)
pub fn ocrCurrentPage() void {
    const pg = state.app.comic.current_page;
    if (pg >= state.app.comic.page_count) return;
    if (state.app.comic.ocr_done[pg]) {
        state.app.comic.show_ocr_overlay = !state.app.comic.show_ocr_overlay;
        return;
    }

    // Don't block the UI thread joining a still-running OCR — just skip the
    // re-trigger. (freeComicPages still joins ocr_thread for the UAF guard.)
    if (ocr_busy.load(.acquire)) return;
    // Not busy ⇒ any previous OCR thread has finished; join the handle (instant)
    // to reclaim it before overwriting.
    if (state.app.comic.ocr_thread) |t| t.join();
    state.app.comic.ocr_thread = null;
    ocr_busy.store(true, .release);
    state.app.comic.ocr_thread = std.Thread.spawn(.{}, struct {
        fn run(page: usize) void {
            defer ocr_busy.store(false, .release);
            ocrPage(page);
            state.app.comic.show_ocr_overlay = true;
        }
    }.run, .{pg}) catch blk: {
        ocr_busy.store(false, .release);
        break :blk null;
    };
}

// ══════════════════════════════════════════════════════════
// String search helpers
// ══════════════════════════════════════════════════════════

fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

fn findBetween(html: []const u8, start_tag: []const u8, end_tag: []const u8) ?[]const u8 {
    const s = std.mem.indexOf(u8, html, start_tag) orelse return null;
    const content_start = s + start_tag.len;
    const e = std.mem.indexOf(u8, html[content_start..], end_tag) orelse return null;
    return html[content_start .. content_start + e];
}

fn findLinkWithText(html: []const u8, text: []const u8) ?[]const u8 {
    // Find: href="URL"...>...text...
    var pos: usize = 0;
    while (pos < html.len) {
        const text_pos = std.mem.indexOf(u8, html[pos..], text) orelse return null;
        const abs_text = pos + text_pos;

        // Look backwards for href="
        const search_start = if (abs_text > 500) abs_text - 500 else 0;
        const before = html[search_start..abs_text];

        // Find last href=" before this text
        var last_href: ?usize = null;
        var scan: usize = 0;
        while (scan < before.len) {
            if (std.mem.indexOf(u8, before[scan..], "href=\"")) |h| {
                last_href = search_start + scan + h + 6;
                scan += h + 1;
            } else break;
        }

        if (last_href) |href_start| {
            if (std.mem.indexOfScalar(u8, html[href_start..], '"')) |href_end| {
                return html[href_start .. href_start + href_end];
            }
        }

        pos = abs_text + text.len;
    }
    return null;
}
