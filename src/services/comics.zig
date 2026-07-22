const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("icons");
const logs = @import("../core/logs.zig");

const alloc = @import("../core/alloc.zig").allocator;
const safeUtf8 = @import("../core/text.zig").safeUtf8;
const workers = @import("../core/workers.zig");
const pure = @import("comics_pure.zig");
// MangaThemesia (WPMangaThemesia) engine — pure, base-URL-driven HTML extraction
// for the ~143 sites on that WordPress theme. comics.zig routes all its parsing
// through this so the shipped logic IS the tested logic (see manga_themesia_pure).
const mt = @import("manga_themesia_pure.zig");
// Madara manga engine (~332 WordPress "Madara" sites): all HTML/URL parsing is
// routed through this tested pure module so the shipped logic IS the tested logic.
const madara = @import("manga_madara_pure.zig");
// OPDS-PSE page-URL substitution (tested) — used by loadPseBook so the shipped
// page-URL build is the same code covered by opds_pure's unit tests.
const opds_pure = @import("opds_pure.zig");
// HeanCms/Iken JSON-API source engine (tested) — URL building + series/chapter/
// page parsing routes through this so the shipped parse IS the tested parse.
const heancms = @import("manga_heancms_pure.zig");
// Suwayomi-Server (Tachidesk) source engine (tested) — Opal talks to a user-run
// Suwayomi over its REST API, so it reaches EVERY installed Mihon/Aniyomi
// extension without reimplementing each engine. URL/JSON logic is all in
// manga_suwayomi_pure so the shipped requests are the tested requests.
const suwayomi = @import("manga_suwayomi_pure.zig");
const mihon = @import("mihon.zig"); // extension discovery/install panel
// Anti-block fetch layer — a fast plain GET, transparently re-fetched through
// the anti-detect browser when the response is a Cloudflare/DDoS-Guard/captcha
// interstitial. The HTML-scraper framework fetches (Madara / MangaThemesia base
// sites + the generic readallcomics scraper) route through it; MangaDex/HeanCms
// JSON stay on the per-host-UA `fetchUrl`. See fetchMaybeUnblocked below.
const scrape = @import("scrape_fetch.zig");
const db = @import("../core/db.zig");
const io_global = @import("../core/io_global.zig");

/// Percent-encode a search query (space → `+`). Delegates to the unit-tested
/// pure helper so the shipped encoder IS the tested one.
fn percentEncode(input: []const u8, out: []u8) usize {
    return pure.percentEncodeQuery(input, out);
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

/// Thread-safe close request (remote.zig's connection threads). See `requestLoad`.
pub fn requestClose() void {
    state.app.comic.pending_close.store(true, .release);
}

/// Drain a pending remote comic-load request. UI-THREAD ONLY — call once per frame.
pub fn drainPendingLoad() void {
    if (state.app.comic.pending_close.swap(false, .acq_rel)) closeComic();
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

// ══════════════════════════════════════════════════════════
// Reading resume (last-read page, persisted per issue)
// ══════════════════════════════════════════════════════════
//
// Same shape as the novels vertical: `library_status` under `comic_resume` is
// the authoritative store, and `library_items` gets a denormalized row so home's
// "Continue" rail can reopen the issue. All of it runs on the UI thread (the
// reader render path), so no locking is needed.

const RESUME_KIND = "comic_resume";
/// A page turn must not hit sqlite — flipping through an issue would otherwise
/// be one write per page. The tick coalesces: it writes at most this often, and
/// closeComic forces a final flush so the last page always lands.
const RESUME_DEBOUNCE_MS: i64 = 1500;

/// Page index last written to sqlite. maxInt = "nothing written for this issue
/// yet", which loadComic/loadPseBook reset so a new issue can't inherit the
/// previous one's page and skip its first save.
var resume_saved_page: usize = std.math.maxInt(usize);
var resume_last_write_ms: i64 = 0;

/// The current issue's stable identity: the source URL when there is one (it
/// survives a restart and names the exact issue), else the title (OPDS-PSE).
fn resumeKeyNow(out: []u8) []const u8 {
    return pure.resumeKey(
        state.app.comic.url_buf[0..state.app.comic.url_len],
        state.app.comic.title[0..state.app.comic.title_len],
        out,
    );
}

/// Look up the persisted last-read page for `key` and arm it as the jump target
/// for the load that's starting. Applied by applyPendingResume once pages stage.
fn armPendingResume(key: []const u8) void {
    if (key.len == 0) return;
    var val_buf: [24]u8 = undefined;
    const val = db.libraryGetStatus(RESUME_KIND, key, &val_buf);
    state.app.comic.pending_resume_page = pure.parseResumePage(val);
}

/// Persist the last-read page and mirror it into the unified read-model.
fn saveResume(page: usize) void {
    var key_buf: [512]u8 = undefined;
    const key = resumeKeyNow(&key_buf);
    if (key.len == 0) return;
    var val_buf: [24]u8 = undefined;
    db.librarySetStatus(RESUME_KIND, key, pure.formatResumePage(&val_buf, page));

    // Mirror into library_items so home's Continue rail spans comics too.
    // library_status above stays authoritative; this is the denormalized cache.
    // Progress is measured in PAGES (page+1 → secs, page_count → duration) so
    // percentOf yields the read-through fraction. shouldRecordProgress keeps
    // page 1 out of the rail — it is where every issue opens, so there is
    // nothing to resume to, and it would sit at the CONTINUE_MIN_PCT floor.
    const total = state.app.comic.page_count;
    if (!pure.shouldRecordProgress(page, total)) return;
    const title = state.app.comic.title[0..state.app.comic.title_len];
    var link_buf: [800]u8 = undefined;
    const link = pure.formatDeepLink(&link_buf, state.app.comic.url_buf[0..state.app.comic.url_len], title);
    if (link.len == 0) return; // unreopenable (OPDS-PSE) → no dead row
    var label_buf: [48]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "Page {d}", .{page + 1}) catch "";
    @import("library_store.zig").upsertProgress(
        "comics",
        key,
        if (title.len > 0) title else key,
        "",
        @floatFromInt(page + 1),
        @floatFromInt(total),
        label,
        link,
    );
}

/// Debounced resume write. UI-THREAD ONLY — called every frame the reader is
/// visible, which is exactly when the page can change (buttons, keys, and scroll
/// mode all just move `current_page`, so polling it here catches every path).
/// `force` bypasses the debounce for the final flush on close.
pub fn tickResume(force: bool) void {
    const cm = &state.app.comic;
    if (cm.page_count == 0) return;
    const page = cm.current_page;
    if (page >= cm.page_count) return;
    if (page == resume_saved_page) return;
    const now = io_global.milliTimestamp();
    // Not yet due: leave resume_saved_page stale so a later frame retries.
    if (!force and now - resume_last_write_ms < RESUME_DEBOUNCE_MS) return;
    resume_saved_page = page;
    resume_last_write_ms = now;
    saveResume(page);
}

/// Jump the reader to the persisted page once the issue's pages have staged.
/// UI-THREAD ONLY. Consumes the request so it fires exactly once per load.
fn applyPendingResume() void {
    const cm = &state.app.comic;
    if (cm.pending_resume_page == 0 or cm.page_count == 0) return;
    const target = @min(cm.pending_resume_page, cm.page_count - 1);
    cm.pending_resume_page = 0;
    cm.current_page = target;
    cm.scroll_to_page = true;
    // Treat the restored page as already persisted — landing on it is not a read.
    resume_saved_page = target;
}

/// Reopen a comic from a home library deep link (`comic|<url>|<title>`). Ignores
/// links that aren't ours. loadComic arms the persisted page, so this reopens
/// the issue AND lands on the page the reader was left on.
pub fn openDeepLink(link: []const u8) void {
    const parsed = pure.parseDeepLink(link) orelse return;
    loadComic(parsed.url);
    state.app.browse_source = .Comics;
    state.app.router.navigate(.browse);
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
    // Scraper / MangaDex sources are unauthenticated — drop any Basic-auth left
    // over from a previous OPDS-PSE book so we never leak it to another host.
    state.app.comic.auth_header_len = 0;
    // Likewise drop any per-chapter Referer left over from a previous
    // MangaThemesia read; loadThemesiaPages re-sets it for its own pages.
    // Drop any per-chapter Referer from a previous load (a Madara load sets its
    // own before staging pages); prevents leaking one site's Referer to another.
    state.app.comic.referer_len = 0;
    state.app.comic.is_loading.store(true, .release);
    state.app.comic.page_count = 0;
    state.app.comic.dl_progress.store(0, .release);
    state.app.comic.current_page = 0;

    // Restore the last-read page for THIS issue (keyed by the URL just stored,
    // so it works for a fresh open and for a home deep link alike). Reset the
    // debounce bookkeeping first — the previous issue's page must not carry.
    resume_saved_page = std.math.maxInt(usize);
    armPendingResume(state.app.comic.url_buf[0..state.app.comic.url_len]);

    freeComicPages();

    // freeComicPages() just bumped dl_gen; capture the fresh generation and hand
    // it to the fetch/download pipeline so every worker it spawns is tagged with
    // THIS load. Workers from a superseded comic carry a stale gen and bail
    // before writing page_pixels (UAF guard).
    const my_gen = state.app.comic.dl_gen.load(.acquire);

    // Comics read inside the Browse › Comics tab now (the player route is for
    // playback only) — no player pane is claimed here.
    state.app.comic.thread = std.Thread.spawn(.{}, fetchComicThread, .{my_gen}) catch null;
}

/// Drive the reader from a pre-enumerated OPDS-PSE (Page Streaming Extension)
/// page stream: Komga/Kavita serve each page as a separate authenticated image
/// at `template` with `{pageNumber}` substituted (0-indexed). We stage every
/// page URL up front (no per-page enumeration request needed) and attach `auth`
/// (a full "Authorization: Basic …" header line) so the shared download pipeline
/// fetches each page under HTTP Basic auth. UI-THREAD ONLY (frees textures).
///
/// `template` / `count` / `auth` come straight from the tested opds_pure parse;
/// page URLs are built via the tested opds_pure.pageUrl so the shipped substitution
/// IS the tested one. Robustness: count 0 or a template with no `{pageNumber}`
/// placeholder → no-op with a warning toast (never spins/crashes).
pub fn loadPseBook(title: []const u8, template: []const u8, count: u32, auth: []const u8) void {
    if (state.app.comic.is_loading.load(.acquire)) return;
    if (count == 0 or template.len == 0 or template.len >= 512) {
        logs.pushLog("error", "opds", "PSE book has no readable pages", true);
        state.showToastTyped("This book has no readable pages", .warning);
        return;
    }

    state.app.comic.narrating = false;
    state.app.comic.show_ocr_overlay = false;
    state.app.comic.url_len = 0; // not a scraper URL — reader header uses the title
    state.app.comic.next_url_len = 0;
    state.app.comic.prev_url_len = 0;
    state.app.comic.referer_len = 0;
    state.app.comic.is_loading.store(true, .release);
    state.app.comic.page_count = 0;
    state.app.comic.dl_progress.store(0, .release);
    state.app.comic.current_page = 0;

    freeComicPages();
    const my_gen = state.app.comic.dl_gen.load(.acquire);

    // Basic-auth header applied to every page fetch (empty for an anonymous server).
    const al = @min(auth.len, state.app.comic.auth_header.len);
    @memcpy(state.app.comic.auth_header[0..al], auth[0..al]);
    state.app.comic.auth_header_len = al;

    const tl = @min(title.len, state.app.comic.title.len);
    @memcpy(state.app.comic.title[0..tl], title[0..tl]);
    state.app.comic.title_len = tl;

    // A PSE book has no scraper URL, so its resume key is the title (just set).
    resume_saved_page = std.math.maxInt(usize);
    armPendingResume(state.app.comic.title[0..tl]);

    // Stage page URLs 0-indexed, bounded by the page_urls array (128).
    const max_pages = state.app.comic.page_urls.len;
    var n: usize = 0;
    var i: usize = 0;
    while (i < count and n < max_pages) : (i += 1) {
        var pb: [512]u8 = undefined;
        const pu = opds_pure.pageUrl(template, i, &pb) orelse continue;
        if (pu.len == 0 or pu.len >= state.app.comic.page_urls[n].len) continue;
        @memcpy(state.app.comic.page_urls[n][0..pu.len], pu);
        state.app.comic.page_url_lens[n] = pu.len;
        n += 1;
    }
    if (n == 0) {
        state.app.comic.is_loading.store(false, .release);
        logs.pushLog("error", "opds", "PSE page-URL build produced no pages", true);
        state.showToastTyped("Could not build page URLs for this book", .warning);
        return;
    }
    state.app.comic.page_count = n;
    state.app.comic.is_loading.store(false, .release);
    logs.pushLog("info", "opds", "OPDS-PSE page stream staged", false);

    // downloadPages() joins its worker batches, so run it OFF the UI thread.
    state.app.comic.thread = std.Thread.spawn(.{}, psePageDownloadThread, .{my_gen}) catch null;
}

/// Worker wrapper: drive the shared page-download pipeline for an OPDS-PSE load,
/// then surface a clear error if every page failed (bad auth / non-image / 404)
/// so the reader doesn't sit blank with no explanation.
fn psePageDownloadThread(gen: u32) void {
    workers.enter();
    defer workers.leave();
    downloadPages(gen);
    // Superseded by a newer load → say nothing (that load owns the UI now).
    if (state.app.comic.dl_gen.load(.acquire) != gen) return;
    if (state.app.comic.dl_progress.load(.acquire) == 0) {
        logs.pushLog("error", "opds", "PSE stream: no pages downloaded (auth failed / not images?)", true);
        state.showToastTyped("Could not load pages — check the server login", .warning);
        state.wakeUi();
    }
}

/// Guards `state.app.comic.page_pixels[]` against readers that are neither the
/// UI thread nor a download worker — today just `copyPage` (the HTTP page route).
var pages_mutex: @import("../core/sync.zig").Mutex = .{};

/// Copy page `i`'s encoded bytes for an off-UI-thread consumer. Caller frees with
/// `a`. Null = out of range or not downloaded yet (the caller answers 404 and the
/// client retries as `dl_progress` climbs).
pub fn copyPage(i: usize, a: std.mem.Allocator) ?[]u8 {
    if (i >= 128) return null;
    pages_mutex.lock();
    defer pages_mutex.unlock();
    const px = state.app.comic.page_pixels[i] orelse return null;
    return a.dupe(u8, px) catch null;
}

/// Free all downloaded page textures/pixels and the OCR cache.
pub fn freeComicPages() void {
    // UAF guard #1 — page-download workers (downloadSinglePage): switching comics
    // mid-download would otherwise free page_pixels while ≤8 detached download
    // threads are still writing into it. Bump dl_gen to CANCEL every in-flight
    // download worker (they compare dl_gen right before writing page_pixels[i],
    // and re-check it inside the read loop, so a cancelled worker bails fast),
    // then wait for the active-writer count (dl_in_flight) to drain to 0. A
    // worker holds dl_in_flight from entry until after its write, so once the
    // count is 0 no worker can touch a buffer we're about to free. Workers never
    // call back into the UI thread, so this can't self-deadlock; the wait is
    // bounded by curl's --max-time (fast in the common case — an actively
    // downloading worker sees the cancel on its next read chunk).
    _ = state.app.comic.dl_gen.fetchAdd(1, .acq_rel);
    while (state.app.comic.dl_in_flight.load(.acquire) > 0) {
        @import("../core/io_global.zig").sleep(1 * std.time.ns_per_ms);
    }

    // UAF guard #2: the narration + OCR workers read state.app.comic.page_pixels
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

    // UAF guard #3: remote.zig's `/api/comics/page` route copies page_pixels on a
    // connection thread, which the dl_gen/dl_in_flight cancel protocol above does
    // NOT cover (that one only fences the download workers). A plain mutex is
    // enough: readers hold it only for the memcpy, and neither side nests locks.
    pages_mutex.lock();
    defer pages_mutex.unlock();

    for (0..128) |i| {
        page_decode_failed[i] = false; // fresh page set — clear the decode-failure latch
        if (state.app.comic.page_textures[i]) |tex| {
            // Skip the deferred GPU destroy when no dvui window is live (appDeinit
            // runs after the frame loop ends) — it would panic; the backend
            // reclaims the textures on teardown. See freeCoverSlot.
            if (dvui.current_window != null) dvui.textureDestroyLater(tex);
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
    // Final flush BEFORE the state is torn down — the resume key is derived from
    // url_buf/title, and the page from current_page, all cleared just below.
    tickResume(true);
    state.app.comic.narrating = false;
    state.app.comic.show_ocr_overlay = false;
    freeComicPages();
    state.app.comic.page_count = 0;
    state.app.comic.current_page = 0;
    state.app.comic.title_len = 0;
    state.app.comic.dl_progress.store(0, .release);
}

fn fetchComicThread(gen: u32) void {
    workers.enter();
    defer workers.leave();
    const url = state.app.comic.url_buf[0..state.app.comic.url_len];

    // ── MangaDex cards carry a `mangadex:<uuid>` pseudo-URL ──
    // Its pages come from a 3-call JSON chain (feed → at-home → image list), not
    // from an HTML page, so it must be routed BEFORE the generic scraper — which
    // would otherwise curl a non-URL and find no images. Once page_urls are
    // staged the shared downloadPages() pipeline takes over unchanged.
    if (pure.mangaIdFromRoute(url)) |manga_id| {
        const ok = loadMangadexPages(manga_id);
        state.app.comic.is_loading.store(false, .release);
        if (!ok) {
            logs.pushLog("error", "comics", "MangaDex chapter failed to load", true);
            return;
        }
        logs.pushLog("info", "comics", "Comic loaded (MangaDex)", false);
        downloadPages(gen);
        return;
    }

    // ── HeanCms/Iken cards carry a `heancms:<series_slug>` pseudo-URL ──
    // Pages come from a 3-call JSON chain (series detail → chapter list → page
    // images), so route BEFORE the generic scraper, exactly like MangaDex. Once
    // page_urls are staged, downloadPages() takes over unchanged.
    if (heancms.slugFromRoute(url)) |slug| {
        const ok = loadHeancmsPages(slug);
        state.app.comic.is_loading.store(false, .release);
        if (!ok) {
            logs.pushLog("error", "comics", "HeanCms chapter failed to load", true);
            return;
        }
        logs.pushLog("info", "comics", "Comic loaded (HeanCms)", false);
        downloadPages(gen);
        return;
    }
    // ── MangaThemesia cards carry a `themesia:<manga-detail-url>` pseudo-URL ──
    // Its pages come from a details→chapters→pages chain, not one HTML issue page,
    // so it is routed BEFORE the generic scraper (which would parse the details
    // page's cover thumbnails as "pages"). Once page_urls are staged the shared
    // downloadPages() pipeline takes over unchanged.
    if (std.mem.startsWith(u8, url, mt.SCHEME)) {
        const detail_url = url[mt.SCHEME.len..];
        const ok = loadThemesiaPages(detail_url);
        state.app.comic.is_loading.store(false, .release);
        if (!ok) {
            logs.pushLog("error", "comics", "MangaThemesia chapter failed to load", true);
            return;
        }
        logs.pushLog("info", "comics", "Comic loaded (MangaThemesia)", false);
        downloadPages(gen);
        return;
    }
    // ── Madara cards carry a `madara:<mangaUrl>` pseudo-URL ──
    // Their pages come from a details → chapter-list → chapter-page chain (HTML,
    // not a single image page), so route BEFORE the generic scraper. Once
    // page_urls are staged the shared downloadPages() pipeline takes over.
    if (madara.mangaUrlFromRoute(url)) |manga_url| {
        const ok = loadMadaraPages(manga_url);
        state.app.comic.is_loading.store(false, .release);
        if (!ok) {
            logs.pushLog("error", "comics", "Madara chapter failed to load", true);
            return;
        }
        logs.pushLog("info", "comics", "Comic loaded (Madara)", false);
        downloadPages(gen);
        return;
    }

    // ── Suwayomi cards carry a `suwayomi:<mangaId>` pseudo-URL ──
    // Pages come from a chapters→chapter-meta→page-URL chain against the user's
    // Suwayomi-Server (which proxies the real Mihon extension), so route BEFORE
    // the generic scraper. Once page_urls are staged, downloadPages() takes over.
    if (suwayomi.mangaIdFromRoute(url)) |manga_id| {
        const ok = loadSuwayomiPages(manga_id);
        state.app.comic.is_loading.store(false, .release);
        if (!ok) {
            logs.pushLog("error", "comics", "Suwayomi chapter failed to load", true);
            return;
        }
        logs.pushLog("info", "comics", "Comic loaded (Suwayomi)", false);
        downloadPages(gen);
        return;
    }

    // Try external plugins first
    if (tryPlugins(url)) {
        logs.pushLog("info", "comics", "Comic loaded via plugin", false);
        state.app.comic.is_loading.store(false, .release);
        downloadPages(gen);
        return;
    }

    // Fallback: native HTML scrape (readallcomics et al.), routed through the
    // anti-block fetch layer so a Cloudflare/DDoS-Guard-fronted source resolves
    // via the anti-detect browser instead of handing back a challenge page.
    const html_buf = alloc.alloc(u8, 512 * 1024) catch {
        state.app.comic.is_loading.store(false, .release);
        return;
    };
    defer alloc.free(html_buf);
    const html_bytes = fetchMaybeUnblocked(url, html_buf);

    if (workers.isQuitting()) {
        state.app.comic.is_loading.store(false, .release);
        return;
    }

    if (html_bytes == 0) {
        logs.pushLog("error", "comics", "Empty response from scrape fetch", true);
        state.app.comic.is_loading.store(false, .release);
        return;
    }

    const html = html_buf[0..html_bytes];

    parseTitle(html);
    parseImageUrls(html);
    parseNavLinks(html);

    logs.pushLog("info", "comics", "Comic loaded (native)", false);
    state.app.comic.is_loading.store(false, .release);
    downloadPages(gen);
}

/// curl a URL into `dst`; returns bytes read (0 on failure). Plain-slice URL
/// (no sentinel needed) — shared by the MangaDex JSON chain and the search
/// fetchers. std.http is deliberately avoided project-wide: it SEGVs on some
/// ISP TLS resets (see tmdb_api.zig).
fn fetchUrl(url: []const u8, dst: []u8) usize {
    // Per-host UA: MangaDex 400s a spoofed browser UA (see pure.userAgentFor).
    var ua_buf: [200]u8 = undefined;
    const ua = std.fmt.bufPrint(&ua_buf, "User-Agent: {s}", .{pure.userAgentFor(url)}) catch return 0;
    const argv = [_][]const u8{
        "curl",       "-sL",
        "-H",         ua,
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

/// HTML-scraper framework fetch that transparently defeats Cloudflare / DDoS-Guard
/// / captcha blocks: a fast plain GET, and on a detected challenge a re-fetch
/// through Opal's anti-detect browser. Gated internally by the `scrape_use_browser`
/// config toggle (scrapeFetch checks it) — OFF ⇒ plain HTTP, i.e. the prior
/// behavior. Drop-in for the plain-GET `fetchUrl`, used by the Madara /
/// MangaThemesia base-site page fetches and the generic readallcomics scraper.
/// Returns bytes written into `dst` (0 on total failure).
///
/// NOT used for the MangaDex / HeanCms JSON APIs — those need a per-host UA
/// (pure.userAgentFor) and their own JSON contract and aren't Cloudflare-
/// challenged, so they stay on `fetchUrl`. POST endpoints (Madara admin-ajax)
/// stay on `fetchPost` — scrapeFetch is GET-only.
fn fetchMaybeUnblocked(url: []const u8, dst: []u8) usize {
    const body = scrape.scrapeFetch(url, dst) orelse return 0;
    return body.len;
}

/// Resolve a MangaDex manga id into a readable page list, staging the image URLs
/// into `state.app.comic.page_urls` for the shared downloadPages() pipeline.
/// Returns false if the manga has no English chapter or the API errored.
///
/// Runs ON the fetchComicThread worker (never the UI thread). All JSON buffers
/// are heap-allocated — a spawned thread's stack is only ~512KB (see CLAUDE.md).
///
/// Chain (all keyless):
///   1. /manga/{id}/feed?…&order[chapter]=asc&limit=1   → the earliest chapter
///   2. /at-home/server/{chapterId}                     → baseUrl + hash + files
///   3. {baseUrl}/data/{hash}/{file}                    → one URL per page
fn loadMangadexPages(manga_id: []const u8) bool {
    // ── 1. Earliest English chapter ──
    var feed_url_buf: [320]u8 = undefined;
    const feed_url = pure.buildFeedUrl(&feed_url_buf, manga_id, 1, 0) orelse return false;

    const feed_buf = alloc.alloc(u8, 128 * 1024) catch return false;
    defer alloc.free(feed_buf);
    const feed_n = fetchUrl(feed_url, feed_buf);
    if (feed_n == 0 or workers.isQuitting()) return false;

    const chapter_id = pure.firstChapterId(feed_buf[0..feed_n]) orelse {
        logs.pushLog("warn", "comics", "MangaDex: no English chapter for this title", false);
        return false;
    };
    // Copy out of feed_buf before it's reused/freed.
    var chap_id_buf: [64]u8 = undefined;
    if (chapter_id.len > chap_id_buf.len) return false;
    @memcpy(chap_id_buf[0..chapter_id.len], chapter_id);
    const chap_id = chap_id_buf[0..chapter_id.len];

    var chap_no_buf: [24]u8 = undefined;
    var chap_no_len: usize = 0;
    if (pure.firstChapterNumber(feed_buf[0..feed_n])) |no| {
        chap_no_len = @min(no.len, chap_no_buf.len);
        @memcpy(chap_no_buf[0..chap_no_len], no[0..chap_no_len]);
    }

    // ── 2. The @Home node serving that chapter's images ──
    var ah_url_buf: [160]u8 = undefined;
    const ah_url = pure.buildAtHomeUrl(&ah_url_buf, chap_id) orelse return false;

    const ah_buf = alloc.alloc(u8, 128 * 1024) catch return false;
    defer alloc.free(ah_buf);
    const ah_n = fetchUrl(ah_url, ah_buf);
    if (ah_n == 0 or workers.isQuitting()) return false;

    var base_buf: [256]u8 = undefined;
    const at_home = pure.parseAtHome(ah_buf[0..ah_n], &base_buf) orelse return false;

    // ── 3. Stage one page URL per image ──
    const max_pages = state.app.comic.page_urls.len; // 128
    var count: usize = 0;
    var it = pure.StrIter{ .buf = at_home.files };
    while (it.next()) |file| {
        if (count >= max_pages) break;
        var page_buf: [512]u8 = undefined;
        const page_url = pure.buildPageUrl(&page_buf, at_home.base_url, at_home.hash, file) orelse continue;
        if (page_url.len >= state.app.comic.page_urls[count].len) continue;
        @memcpy(state.app.comic.page_urls[count][0..page_url.len], page_url);
        state.app.comic.page_url_lens[count] = page_url.len;
        count += 1;
    }
    if (count == 0) return false;
    state.app.comic.page_count = count;

    // Title: the card click already staged the series title; append the chapter
    // number so the reader header reads "Berserk · Ch. 1". A load that didn't
    // come from a card (URL paste / remote API) has no title — fall back.
    if (chap_no_len > 0) {
        var t_buf: [256]u8 = undefined;
        const existing = state.app.comic.title[0..state.app.comic.title_len];
        const base_title: []const u8 = if (existing.len > 0) existing else "MangaDex";
        const t = std.fmt.bufPrint(&t_buf, "{s} · Ch. {s}", .{ base_title, chap_no_buf[0..chap_no_len] }) catch base_title;
        const tl = @min(t.len, state.app.comic.title.len);
        @memcpy(state.app.comic.title[0..tl], t[0..tl]);
        state.app.comic.title_len = tl;
    } else if (state.app.comic.title_len == 0) {
        const t = "MangaDex";
        @memcpy(state.app.comic.title[0..t.len], t);
        state.app.comic.title_len = t.len;
    }

    // MangaDex's CDN serves images without a Referer requirement, so leave
    // state.app.comic.referer empty — downloadSinglePage derives it per-origin.
    return true;
}

// ── HeanCms/Iken source config → derived hosts ──

/// The HeanCms API host derived from the installed site base (`https://x.com` →
/// `https://api.x.com`). Null when the "heancms" source is not installed → the
/// engine stays INERT. Routes through the tested heancms.apiHostFromBase.
fn heancmsApiHost(out: []u8) ?[]const u8 {
    const base = @import("../core/source_config.zig").get("heancms", "base") orelse return null;
    return heancms.apiHostFromBase(base, out);
}

/// Optional cover/page CDN base for relative thumbnail/image paths. Returns "" when
/// unconfigured — absolutizeCover then leaves absolute URLs alone (the common case
/// for HeanCms, which usually stores absolute image URLs) and drops relatives.
fn heancmsCdn(out: []u8) []const u8 {
    if (@import("../core/source_config.zig").get("heancms", "cdn")) |c| {
        if (c.len > 0 and c.len < out.len) {
            @memcpy(out[0..c.len], c);
            return out[0..c.len];
        }
    }
    return "";
}

/// Resolve a HeanCms series slug into a readable page list, staging image URLs
/// into `state.app.comic.page_urls` for the shared downloadPages() pipeline.
/// Returns false if the series has no free chapter or the API errored.
///
/// Runs ON the fetchComicThread worker (never the UI thread). All JSON buffers
/// are heap-allocated — a spawned thread's stack is only ~512KB (see CLAUDE.md).
///
/// Chain (all against the configured HeanCms API host):
///   1. /series/{slug}                              → the numeric series id + title
///   2. /chapter/query?series_id={id}&perPage=1000  → the first FREE chapter slug
///   3. /series/{slug}/{chapterSlug}                → one image URL per page
fn loadHeancmsPages(slug: []const u8) bool {
    var api_buf: [256]u8 = undefined;
    const api = heancmsApiHost(&api_buf) orelse {
        logs.pushLog("warn", "comics", "HeanCms: source not installed (inert)", false);
        return false;
    };
    var cdn_buf: [512]u8 = undefined;
    const cdn = heancmsCdn(&cdn_buf);

    // ── 1. Series detail → numeric id (+ title) ──
    var detail_url_buf: [512]u8 = undefined;
    const detail_url = heancms.buildDetailUrl(&detail_url_buf, api, slug) orelse return false;

    const detail_buf = alloc.alloc(u8, 256 * 1024) catch return false;
    defer alloc.free(detail_buf);
    const detail_n = fetchUrl(detail_url, detail_buf);
    if (detail_n == 0 or workers.isQuitting()) return false;

    const series = heancms.parseSeriesDetail(detail_buf[0..detail_n]) orelse {
        logs.pushLog("warn", "comics", "HeanCms: series detail unparseable", false);
        return false;
    };
    if (series.id.len == 0) return false;
    // Copy id + title out of detail_buf before it is reused/freed.
    var id_buf: [24]u8 = undefined;
    if (series.id.len > id_buf.len) return false;
    @memcpy(id_buf[0..series.id.len], series.id);
    const series_id = id_buf[0..series.id.len];

    var series_title_buf: [256]u8 = undefined;
    var series_title_len: usize = 0;
    {
        var raw: [256]u8 = undefined;
        const rn = heancms.jsonUnescape(series.title, &raw);
        series_title_len = @min(rn, series_title_buf.len);
        @memcpy(series_title_buf[0..series_title_len], raw[0..series_title_len]);
    }

    // ── 2. Chapter list → first FREE chapter (paywalled ones skipped) ──
    var chap_url_buf: [512]u8 = undefined;
    const chap_url = heancms.buildChapterListUrl(&chap_url_buf, api, series_id, 1) orelse return false;

    const chap_buf = alloc.alloc(u8, 512 * 1024) catch return false;
    defer alloc.free(chap_buf);
    const chap_n = fetchUrl(chap_url, chap_buf);
    if (chap_n == 0 or workers.isQuitting()) return false;

    const chapter = heancms.firstFreeChapter(chap_buf[0..chap_n]) orelse {
        logs.pushLog("warn", "comics", "HeanCms: no free chapter (all paywalled?)", false);
        return false;
    };
    var chap_slug_buf: [160]u8 = undefined;
    if (chapter.slug.len > chap_slug_buf.len) return false;
    @memcpy(chap_slug_buf[0..chapter.slug.len], chapter.slug);
    const chap_slug = chap_slug_buf[0..chapter.slug.len];

    var chap_name_buf: [64]u8 = undefined;
    var chap_name_len: usize = 0;
    if (chapter.name.len > 0) {
        var raw: [64]u8 = undefined;
        const rn = heancms.jsonUnescape(chapter.name, &raw);
        chap_name_len = @min(rn, chap_name_buf.len);
        @memcpy(chap_name_buf[0..chap_name_len], raw[0..chap_name_len]);
    }

    // ── 3. Page images (new chapter_data.images OR old data[] shape) ──
    var pages_url_buf: [512]u8 = undefined;
    const pages_url = heancms.buildPagesUrl(&pages_url_buf, api, slug, chap_slug) orelse return false;

    const pages_buf = alloc.alloc(u8, 512 * 1024) catch return false;
    defer alloc.free(pages_buf);
    const pages_n = fetchUrl(pages_url, pages_buf);
    if (pages_n == 0 or workers.isQuitting()) return false;

    const images = heancms.pagesNode(pages_buf[0..pages_n]) orelse {
        logs.pushLog("warn", "comics", "HeanCms: chapter has no readable pages", false);
        return false;
    };

    const max_pages = state.app.comic.page_urls.len; // 128
    var count: usize = 0;
    var it = heancms.StrIter{ .buf = images };
    while (it.next()) |raw_img| {
        if (count >= max_pages) break;
        // Images arrive JSON-escaped (\/ in URLs) — unescape, then absolutize.
        var un_buf: [640]u8 = undefined;
        const un = heancms.jsonUnescape(raw_img, &un_buf);
        var page_buf: [640]u8 = undefined;
        const page_url = heancms.absolutizeCover(cdn, un_buf[0..un], &page_buf) orelse continue;
        if (page_url.len >= state.app.comic.page_urls[count].len) continue;
        @memcpy(state.app.comic.page_urls[count][0..page_url.len], page_url);
        state.app.comic.page_url_lens[count] = page_url.len;
        count += 1;
    }
    if (count == 0) return false;
    state.app.comic.page_count = count;

    // Reader header: "Series · Chapter N". The card click already staged the
    // series title; prefer it, else the detail title, else "HeanCms".
    var t_buf: [320]u8 = undefined;
    const existing = state.app.comic.title[0..state.app.comic.title_len];
    const base_title: []const u8 = if (existing.len > 0)
        existing
    else if (series_title_len > 0)
        series_title_buf[0..series_title_len]
    else
        "HeanCms";
    const t = if (chap_name_len > 0)
        std.fmt.bufPrint(&t_buf, "{s} · {s}", .{ base_title, chap_name_buf[0..chap_name_len] }) catch base_title
    else
        base_title;
    const tl = @min(t.len, state.app.comic.title.len);
    @memcpy(state.app.comic.title[0..tl], t[0..tl]);
    state.app.comic.title_len = tl;
    return true;
}
/// The MangaThemesia base URL for a site, or null when the source is not
/// installed (→ inert). Read fresh each call; the slice points into the
/// source_config static table so it must be copied before the next reload().
fn themesiaBase() ?[]const u8 {
    return @import("../core/source_config.zig").get("mangathemesia", "base");
}

/// The site's `mangaUrlDirectory` (default "/manga" when the plugin omits it).
fn themesiaDir() []const u8 {
    return @import("../core/source_config.zig").get("mangathemesia", "dir") orelse mt.DEFAULT_DIR;
}

/// Resolve a MangaThemesia manga-detail URL into a readable page list, staging
/// the image URLs into `state.app.comic.page_urls` for the shared downloadPages()
/// pipeline. Returns false when the manga has no chapters or the fetch errored.
///
/// Runs ON the fetchComicThread worker (never the UI thread). All HTML buffers
/// are heap-allocated — a spawned thread's stack is only ~512KB (see CLAUDE.md).
///
/// Chain:
///   1. GET {detail_url}                → parse chapter list (earliest = last)
///   2. GET {earliest chapter url}      → parse page images
///   3. stage page URLs + set Referer   → downloadPages() fetches each page
fn loadThemesiaPages(detail_url: []const u8) bool {
    if (detail_url.len == 0 or detail_url.len > 1024) return false;
    if (!std.mem.startsWith(u8, detail_url, "http")) return false;

    // Base for resolving relative page/chapter URLs. Prefer the installed base;
    // fall back to the detail URL's own origin so a paste still resolves.
    var base_buf: [256]u8 = undefined;
    const base = blk: {
        if (themesiaBase()) |b| {
            const n = @min(b.len, base_buf.len);
            @memcpy(base_buf[0..n], b[0..n]);
            break :blk base_buf[0..n];
        }
        break :blk detail_url;
    };

    // ── 1. Details HTML → chapter list ──
    const detail_html = alloc.alloc(u8, 512 * 1024) catch return false;
    defer alloc.free(detail_html);
    const dn = fetchMaybeUnblocked(detail_url, detail_html);
    if (dn == 0 or workers.isQuitting()) return false;

    // Walk the chapter list; it is newest-first, so the LAST entry is chapter 1.
    // Keep that one (mirrors the MangaDex path, which opens the earliest chapter).
    var chap_url_buf: [512]u8 = undefined;
    var chap_url_len: usize = 0;
    var chap_name_buf: [128]u8 = undefined;
    var chap_name_len: usize = 0;
    {
        var it = mt.chapterIter(detail_html[0..dn]);
        while (it.next()) |ch| {
            var abs_buf: [512]u8 = undefined;
            const abs = mt.resolveUrl(base, ch.url, &abs_buf);
            if (abs.len == 0 or abs.len > chap_url_buf.len) continue;
            @memcpy(chap_url_buf[0..abs.len], abs);
            chap_url_len = abs.len;
            const nl = @min(ch.name.len, chap_name_buf.len);
            @memcpy(chap_name_buf[0..nl], ch.name[0..nl]);
            chap_name_len = nl;
        }
    }
    if (chap_url_len == 0) {
        logs.pushLog("warn", "comics", "MangaThemesia: no chapters found for this title", false);
        return false;
    }
    const chap_url = chap_url_buf[0..chap_url_len];

    // ── 2. Chapter HTML → page images ──
    const chap_html = alloc.alloc(u8, 512 * 1024) catch return false;
    defer alloc.free(chap_html);
    const cn = fetchMaybeUnblocked(chap_url, chap_html);
    if (cn == 0 or workers.isQuitting()) return false;

    const count = mt.parsePages(
        chap_html[0..cn],
        base,
        &state.app.comic.page_urls,
        &state.app.comic.page_url_lens,
    );
    if (count == 0) return false;
    state.app.comic.page_count = count;

    // Title: the card click staged the series title; append the chapter name so
    // the reader header reads "One Piece · Chapter 1". A load with no prior title
    // (URL paste / remote API) falls back to the chapter name alone.
    if (chap_name_len > 0) {
        var t_buf: [256]u8 = undefined;
        const existing = state.app.comic.title[0..state.app.comic.title_len];
        const t = if (existing.len > 0)
            (std.fmt.bufPrint(&t_buf, "{s} · {s}", .{ existing, chap_name_buf[0..chap_name_len] }) catch existing)
        else
            chap_name_buf[0..chap_name_len];
        const tl = @min(t.len, state.app.comic.title.len);
        @memcpy(state.app.comic.title[0..tl], t[0..tl]);
        state.app.comic.title_len = tl;
    }

    // MangaThemesia image CDNs 403 without the chapter URL as Referer — stash it
    // so downloadSinglePage adds `Referer:` + a browser-style `Accept:` header.
    const rl = @min(chap_url.len, state.app.comic.referer.len);
    @memcpy(state.app.comic.referer[0..rl], chap_url[0..rl]);
    state.app.comic.referer_len = rl;
    return true;
}

/// POST `body` to `url` with the AJAX marker header, reading the response into
/// `dst`; returns bytes read (0 on failure). Used by the Madara chapter-list
/// fallbacks (admin-ajax.php + the newer `{mangaUrl}ajax/chapters`), both of
/// which WordPress only answers to an `X-Requested-With: XMLHttpRequest` POST.
fn fetchPost(url: []const u8, body: []const u8, dst: []u8) usize {
    var ua_buf: [200]u8 = undefined;
    const ua = std.fmt.bufPrint(&ua_buf, "User-Agent: {s}", .{pure.userAgentFor(url)}) catch return 0;
    const argv = [_][]const u8{
        "curl",              "-sL",
        "-H",                ua,
        "-H",                "X-Requested-With: XMLHttpRequest",
        "--data",            body,
        "--max-time",        "15",
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

/// Resolve a Madara `madara:<mangaUrl>` route into a readable page list, staging
/// the image URLs into `state.app.comic.page_urls` for the shared downloadPages()
/// pipeline. Returns false when the source isn't installed, the manga has no
/// chapter, or the chapter is AES-protected (v1 skips those).
///
/// Runs ON the fetchComicThread worker (never the UI thread). All HTML buffers
/// are heap-allocated — a spawned thread's stack is only ~512KB (see CLAUDE.md).
/// ALL parsing goes through the tested `manga_madara_pure` module.
///
/// Chain:
///   1. GET  {mangaUrl}                         → details (title + chapter list)
///   2. (if no inline chapters) POST admin-ajax → chapter list; else POST
///      {mangaUrl}ajax/chapters                 → chapter list
///   3. GET  {chapterUrl}                        → page images (Referer required)
fn loadMadaraPages(manga_url: []const u8) bool {
    const base = madaraBase() orelse return false;
    // Copy the base out of the source_config static table (it can be reloaded).
    var base_buf: [256]u8 = undefined;
    if (base.len > base_buf.len) return false;
    @memcpy(base_buf[0..base.len], base);
    const b = base_buf[0..base.len];

    // ── 1. Details page ──
    const details_buf = alloc.alloc(u8, 512 * 1024) catch return false;
    defer alloc.free(details_buf);
    const dn = fetchMaybeUnblocked(manga_url, details_buf);
    if (dn == 0 or workers.isQuitting()) return false;
    const details_html = details_buf[0..dn];

    const details = madara.parseDetails(details_html);

    // Title (copy out before the buffer is reused/freed).
    if (details.title.len > 0) {
        const tl = @min(details.title.len, state.app.comic.title.len);
        @memcpy(state.app.comic.title[0..tl], details.title[0..tl]);
        state.app.comic.title_len = tl;
    } else if (state.app.comic.title_len == 0) {
        const t = "Manga";
        @memcpy(state.app.comic.title[0..t.len], t);
        state.app.comic.title_len = t.len;
    }

    // ── 2. Chapter list — pick the OLDEST chapter (document order is
    //       newest→oldest, so the last entry is chapter 1: "read from start"). ──
    var chosen_buf: [512]u8 = undefined;
    var chosen_len: usize = 0;
    const pickOldest = struct {
        fn run(html: []const u8, out: []u8) usize {
            var it = madara.ChapterIter{ .html = html };
            var len: usize = 0;
            while (it.next()) |ch| {
                if (ch.url.len == 0 or ch.url.len > out.len) continue;
                @memcpy(out[0..ch.url.len], ch.url);
                len = ch.url.len; // keep overwriting → ends on the last (oldest)
            }
            return len;
        }
    }.run;

    chosen_len = pickOldest(details_html, &chosen_buf);

    // Fallback A: the WordPress admin-ajax.php chapter endpoint (data-id form).
    var ajax_buf: ?[]u8 = null;
    defer if (ajax_buf) |ab| alloc.free(ab);
    if (chosen_len == 0) {
        if (madara.dataIdFromHolder(details_html)) |data_id| {
            var url_buf: [320]u8 = undefined;
            var body_buf: [128]u8 = undefined;
            if (madara.buildAjaxUrl(&url_buf, b)) |ajax_url| {
                if (madara.buildAjaxBody(&body_buf, data_id)) |body| {
                    const ab = alloc.alloc(u8, 256 * 1024) catch return false;
                    ajax_buf = ab;
                    const an = fetchPost(ajax_url, body, ab);
                    if (an > 0 and !workers.isQuitting()) chosen_len = pickOldest(ab[0..an], &chosen_buf);
                }
            }
        }
    }
    // Fallback B: the newer `{mangaUrl}ajax/chapters` endpoint (empty body).
    if (chosen_len == 0) {
        var url_buf: [320]u8 = undefined;
        const dir = std.mem.trimEnd(u8, manga_url, "/");
        if (std.fmt.bufPrint(&url_buf, "{s}/ajax/chapters", .{dir})) |ajax2_url| {
            if (ajax_buf == null) ajax_buf = alloc.alloc(u8, 256 * 1024) catch return false;
            const ab = ajax_buf.?;
            const an = fetchPost(ajax2_url, "", ab);
            if (an > 0 and !workers.isQuitting()) chosen_len = pickOldest(ab[0..an], &chosen_buf);
        } else |_| {}
    }
    if (chosen_len == 0) {
        logs.pushLog("warn", "comics", "Madara: no chapters found for this title", false);
        return false;
    }

    // Resolve the chosen chapter URL to absolute, and stash it as the Referer the
    // page-image fetches will send (many Madara CDNs 403 without it).
    var chap_abs_buf: [640]u8 = undefined;
    const chapter_url = madara.resolveUrl(b, chosen_buf[0..chosen_len], &chap_abs_buf);
    if (chapter_url.len == 0 or !std.mem.startsWith(u8, chapter_url, "http")) return false;
    const rl = @min(chapter_url.len, state.app.comic.referer.len);
    @memcpy(state.app.comic.referer[0..rl], chapter_url[0..rl]);
    state.app.comic.referer_len = rl;

    // ── 3. Chapter page images ──
    const chap_buf = alloc.alloc(u8, 512 * 1024) catch return false;
    defer alloc.free(chap_buf);
    const cn = fetchMaybeUnblocked(chapter_url, chap_buf);
    if (cn == 0 or workers.isQuitting()) return false;
    const chapter_html = chap_buf[0..cn];

    // v1 skip: AES "chapter-protector" encrypted images (rare) — surface a toast
    // instead of implementing OpenSSL AES now.
    if (madara.isProtected(chapter_html)) {
        logs.pushLog("warn", "comics", "Madara: chapter is AES-protected (skipped)", false);
        state.showToastTyped("This chapter is protected and can't be read yet", .warning);
        return false;
    }

    const max_pages = state.app.comic.page_urls.len; // 128
    var count: usize = 0;
    var pit = madara.PageIter.init(chapter_html);
    while (pit.next()) |raw| {
        if (count >= max_pages) break;
        var pbuf: [700]u8 = undefined;
        const abs = madara.resolveUrl(b, raw, &pbuf);
        if (abs.len == 0 or abs.len >= state.app.comic.page_urls[count].len) continue;
        @memcpy(state.app.comic.page_urls[count][0..abs.len], abs);
        state.app.comic.page_url_lens[count] = abs.len;
        count += 1;
    }
    if (count == 0) {
        logs.pushLog("warn", "comics", "Madara: chapter had no readable pages", false);
        return false;
    }
    state.app.comic.page_count = count;
    return true;
}

/// Scan ~/.config/opal/plugins/comics/ for .lua/.py/.sh scripts,
/// execute each with url as arg1, parse JSON stdout.
fn tryPlugins(url: []const u8) bool {
    // 1) Try bundled plugins/ directory (shipped with app)
    if (tryPluginsInDir("plugins", url)) return true;

    // 2) Try user plugins directory
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return false;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/opal/plugins/comics", .{home}) catch return false;
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

fn downloadPages(gen: u32) void {
    // Download comic page images in PARALLEL — 8 concurrent threads
    const BATCH = 8;
    var threads: [BATCH]?std.Thread = [_]?std.Thread{null} ** BATCH;
    var page_idx: usize = 0;

    while (page_idx < state.app.comic.page_count) {
        // Superseded by a newer comic load → stop spawning work for this one.
        if (state.app.comic.dl_gen.load(.acquire) != gen) return;
        var active: usize = 0;

        // Spawn batch of download threads
        while (active < BATCH and page_idx < state.app.comic.page_count) {
            if (state.app.comic.page_pixels[page_idx] != null or
                state.app.comic.page_url_lens[page_idx] == 0)
            {
                page_idx += 1;
                continue;
            }
            threads[active] = std.Thread.spawn(.{}, downloadSinglePage, .{ page_idx, gen }) catch null;
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

fn downloadSinglePage(i: usize, gen: u32) void {
    workers.enter();
    defer workers.leave();
    // Register as an active download writer for the whole of this function so
    // freeComicPages (which waits for dl_in_flight to hit 0 after cancelling)
    // cannot free page_pixels while we might still write into it. See the UAF
    // guard in freeComicPages().
    _ = state.app.comic.dl_in_flight.fetchAdd(1, .acq_rel);
    defer _ = state.app.comic.dl_in_flight.fetchSub(1, .acq_rel);

    // Cancelled before we even started (comic switched) → bail.
    if (state.app.comic.dl_gen.load(.acquire) != gen) return;

    const url = state.app.comic.page_urls[i][0..state.app.comic.page_url_lens[i]];
    if (url.len == 0) return;

    // Per-host UA (pure.userAgentFor). The MangaDex page CDN accepts either UA,
    // but routing through the one selector keeps every comics fetch consistent
    // and means a future MangaDex host can't silently regress to a 400.
    var ua_buf: [200]u8 = undefined;
    const ua = std.fmt.bufPrint(&ua_buf, "User-Agent: {s}", .{pure.userAgentFor(url)}) catch return;

    // OPDS-PSE page streams (Komga/Kavita) require HTTP Basic auth on EVERY page
    // fetch. loadPseBook stashes the full "Authorization: Basic …" line here; it
    // is set once before the download workers spawn and never mutated mid-load,
    // and is empty for scraper/MangaDex sources (which append no extra header).
    const auth = state.app.comic.auth_header[0..state.app.comic.auth_header_len];

    // MangaThemesia image CDNs 403 without a matching Referer (the chapter URL)
    // and expect a browser-style Accept. loadThemesiaPages stashes the chapter URL
    // in `referer`; it is empty for scraper / MangaDex / OPDS sources (which need
    // no Referer), so this whole block is inert for them.
    const referer = state.app.comic.referer[0..state.app.comic.referer_len];
    var ref_buf: [560]u8 = undefined;
    const referer_hdr: []const u8 = if (referer.len > 0)
        (std.fmt.bufPrint(&ref_buf, "Referer: {s}", .{referer}) catch "")
    else
        "";

    // Build argv dynamically so the auth / referer headers are appended only when
    // present. Worst case: curl -sL -H ua [-H auth] [-H referer -H accept]
    // --max-time 15 url → 14 slots. The Referer (chapter URL) is stashed by the
    // Madara/MangaThemesia loaders; empty for scraper/MangaDex/OPDS sources, so
    // the block below is inert for them.
    var argv_buf: [14][]const u8 = undefined;
    var ac: usize = 0;
    argv_buf[ac] = "curl";
    ac += 1;
    argv_buf[ac] = "-sL";
    ac += 1;
    argv_buf[ac] = "-H";
    ac += 1;
    argv_buf[ac] = ua;
    ac += 1;
    if (auth.len > 0) {
        argv_buf[ac] = "-H";
        ac += 1;
        argv_buf[ac] = auth;
        ac += 1;
    }
    if (referer_hdr.len > 0) {
        argv_buf[ac] = "-H";
        ac += 1;
        argv_buf[ac] = referer_hdr;
        ac += 1;
        argv_buf[ac] = "-H";
        ac += 1;
        argv_buf[ac] = "Accept: image/avif,image/webp,image/png,image/jpeg,*/*";
        ac += 1;
    }
    argv_buf[ac] = "--max-time";
    ac += 1;
    argv_buf[ac] = "15";
    ac += 1;
    argv_buf[ac] = url;
    ac += 1;
    const argv = argv_buf[0..ac];

    var child = @import("../core/io_global.zig").Child.init(argv, alloc);
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
            // Comic switched under us → stop reading and bail fast (this is what
            // keeps freeComicPages's drain wait short for an active download).
            if (state.app.comic.dl_gen.load(.acquire) != gen) return;
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
        // Re-check the generation IMMEDIATELY before publishing. If the comic was
        // switched, this buffer belongs to no one — free it and bail rather than
        // write into a page_pixels slot the new comic owns. We still hold
        // dl_in_flight here, so freeComicPages cannot have freed the array yet.
        if (state.app.comic.dl_gen.load(.acquire) != gen) {
            alloc.free(pixels);
            return;
        }
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
// Per-slot failure latch: set TRUE by coverWorker when a fetch yields no pixels
// (404 / undecodable / truncated download). Gates fetchCover so a dead cover
// stops re-spawning a curl worker every frame. Plain bool — mirrors the sibling
// pixel/w/h fields (and TmdbItem.poster_failed): the single writer is the slot's
// own coverWorker (serialized by the sr_cover_fetching claim), the render thread
// reads it. Reset when a slot is reclaimed (freeCoverSlot) or refilled with a
// fresh URL (parseSearchResults), so a new search always retries covers.
var sr_cover_failed: [MAX_SEARCH_RESULTS]bool = [_]bool{false} ** MAX_SEARCH_RESULTS;
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

// ══════════════════════════════════════════════════════════
// Encrypted on-disk content cache — default-feed stale-while-revalidate.
//
// The tab opens on a default popular feed (DEFAULT_FEED_QUERY on the `all`
// source). We serialize that fresh listing's TEXT rows (title + novel URL)
// through the tested content_cache_pure Writer/Reader and persist them, so the
// next cold start paints the grid INSTANTLY instead of a blank box + spinner.
//
// Covers are deliberately NOT seeded: they ride the generation-gated,
// render-thread-owned reclaim (sr_cover_gen / reclaimStaleCovers), and driving a
// coverWorker for a soon-to-be-replaced seeded row would race the fetch worker's
// URL rewrite. Seeded rows carry cover_url_len==0 (→ fetchCover no-ops); the
// revalidating fetch — kicked the SAME frame via the existing SWR branch — fills
// covers from live data. sr_* are FIXED module-static arrays (never realloc'd).
// Gated on content_cache_enabled; TTL is the shared SWR window.
// ══════════════════════════════════════════════════════════
const content_cache = @import("../core/content_cache.zig");
const ccp = @import("../core/content_cache_pure.zig");
const COMICS_CACHE_TTL_S: i64 = @import("browse_cache.zig").TTL_S;
const COMICS_CACHE_KEY = "comics:browse:all"; // default feed = DEFAULT_FEED_QUERY on `all`
const COMICS_BLOB_CAP: usize = 96 * 1024;
const DEFAULT_FEED_QUERY = "spider-man";

/// SWR write — persist the default feed's text rows. Called from searchWorker
/// (same thread that wrote sr_*, so they're stable) only for the default feed.
fn putDefaultCache() void {
    if (!state.app.content_cache_enabled) return;
    if (sr_count == 0) return;
    const buf = alloc.alloc(u8, COMICS_BLOB_CAP) catch return;
    defer alloc.free(buf);
    var w = ccp.Writer.init(buf);
    const n: u16 = @intCast(@min(sr_count, MAX_SEARCH_RESULTS));
    w.u16v(n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        w.blob(sr_titles[i][0..@min(sr_title_lens[i], sr_titles[i].len)]);
        w.blob(sr_urls[i][0..@min(sr_url_lens[i], sr_urls[i].len)]);
    }
    const blob = w.done() orelse return;
    content_cache.put(COMICS_CACHE_KEY, blob, COMICS_CACHE_TTL_S);
}

/// SWR read — seed the default grid from disk so it paints instantly on cold
/// start. UI-thread only (from renderContent), ONLY before the default feed has
/// loaded and while the grid is empty. Seeds TEXT rows only (see the section
/// header); marks the feed loaded + stale so the existing SWR branch fires the
/// revalidating fetch this same frame.
fn seedDefaultFromCache() void {
    if (!state.app.content_cache_enabled) return;
    if (loaded_default or sr_count != 0 or sr_searching) return;
    if (state.app.comic.search_buf[0] != 0 or state.app.comic.title_len != 0) return;
    const buf = alloc.alloc(u8, COMICS_BLOB_CAP) catch return;
    defer alloc.free(buf);
    const hit = content_cache.get(COMICS_CACHE_KEY, buf) orelse return;
    var r = ccp.Reader.init(hit.bytes);
    const n = r.u16v() orelse return;
    var i: usize = 0;
    while (i < n and i < MAX_SEARCH_RESULTS) : (i += 1) {
        const title = r.blob() orelse break;
        const url = r.blob() orelse break;
        const tl = @min(title.len, sr_titles[i].len);
        @memcpy(sr_titles[i][0..tl], title[0..tl]);
        sr_title_lens[i] = tl;
        const ul = @min(url.len, sr_urls[i].len);
        @memcpy(sr_urls[i][0..ul], url[0..ul]);
        sr_url_lens[i] = ul;
        sr_cover_url_lens[i] = 0; // covers ride the fresh revalidation, not the seed
    }
    if (i == 0) return;
    sr_count = i;
    // Adopt the default query + a STALE stamp so renderContent's SWR branch fires
    // the revalidating fetch (which also re-stores the cache) this frame.
    @memcpy(sr_query_buf[0..DEFAULT_FEED_QUERY.len], DEFAULT_FEED_QUERY);
    sr_query_len = DEFAULT_FEED_QUERY.len;
    loaded_default = true;
    last_fetch_s = 0;
}

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
// Two native sources today; plugin sources are surfaced dynamically as badges.
//
//   • readallcomics — HTML scrape. Its endpoint is NOT in the binary: it comes
//     from source_config ("readallcomics"/"base"), written by the plugin manager
//     when the user installs the source. Not installed → buildSearchUrl returns
//     null → the source is INERT and contributes no rows.
//   • mangadex     — keyless, documented public JSON API (api.mangadex.org), so
//     it needs no source_config entry and works out of the box. This is what
//     makes the tab non-empty on a fresh install.
//
// `all` queries every source that is actually live and concatenates the rows.
//   • heancms      — the HeanCms/Iken JSON-API family (modern Next.js manhwa
//     sites). Its site base + optional cover CDN come from source_config
//     ("heancms"/"base", "heancms"/"cdn"), written by the plugin manager. Not
//     installed → buildQueryUrl gets no api host → the source is INERT.
//   • madara       — the generic WordPress "Madara" theme engine (~332 sites).
//     Base-URL-driven like readallcomics: its endpoint comes from source_config
//     ("madara"/"base"), so it is INERT until the user installs a Madara source.
//     Cards carry a `madara:<mangaUrl>` pseudo-URL routed by fetchComicThread.
//   • suwayomi     — a user-run Suwayomi-Server (Tachidesk) that runs actual
//     Mihon/Aniyomi extension APKs. Its base URL + the id of the installed
//     source to search come from source_config ("suwayomi"/"base",
//     "suwayomi"/"source"), so it is INERT until the user configures it. Cards
//     carry a `suwayomi:<mangaId>` pseudo-URL routed by fetchComicThread.
const Source = enum { all, readallcomics, mangadex, heancms, mangathemesia, madara, suwayomi };
var active_source: Source = .all;

/// The Suwayomi server base URL + the installed-source id to search, or null
/// when either is unconfigured (→ the engine stays inert). Both read fresh from
/// source_config, whose static table can be reloaded, so callers must copy the
/// bytes before the next reload().
fn suwayomiBase() ?[]const u8 {
    return @import("../core/source_config.zig").get("suwayomi", "base");
}
fn suwayomiSourceId() ?[]const u8 {
    return @import("../core/source_config.zig").get("suwayomi", "source");
}

/// Point the Comics grid at a specific installed Suwayomi source (a numeric
/// source id from an extension the user just installed via the Mihon panel):
/// persist it as suwayomi/source, select the Suwayomi source filter, close the
/// extension panel, and load that source's default listing. This is the bridge
/// from "installed an extension" to "browse its manga". Called by mihon.zig.
pub fn browseSuwayomiSource(source_id: []const u8) void {
    if (source_id.len == 0) return;
    const sc = @import("../core/source_config.zig");
    // Merge into the existing suwayomi config (keep base), set/replace source.
    var body: [256]u8 = undefined;
    const base = suwayomiBase() orelse "";
    if (std.fmt.bufPrint(&body, "{{\"base\":\"{s}\",\"source\":\"{s}\"}}", .{ base, source_id })) |b| {
        _ = sc.install("suwayomi", b);
    } else |_| return;
    mihon.close();
    active_source = .suwayomi;
    // Kick a default listing for the newly selected source.
    searchComics(DEFAULT_FEED_QUERY);
}

/// Does this source participate in the current selection?
fn sourceActive(src: Source) bool {
    return active_source == .all or active_source == src;
}

/// The configured Madara base URL, or null when no Madara source is installed
/// (→ the engine stays inert, exactly like readallcomics). Optional
/// `mangaSubString` defaults to "manga".
fn madaraBase() ?[]const u8 {
    return @import("../core/source_config.zig").get("madara", "base");
}
fn madaraSub() []const u8 {
    return @import("../core/source_config.zig").get("madara", "mangaSubString") orelse "manga";
}

// ── Discovery grid sizing (user-cyclable card width) ──
var card_w: f32 = 150;

/// Card footer height below the cover (title caption). Referenced by BOTH the
/// uniform card sizing (renderCoverCard pins min==max height) AND the grid's
/// virtualization row pitch — single-sourced so the spacer math and the card
/// can never drift. Mirrors jellyfin_ui.zig / anime.zig CARD_FOOTER_H.
const CARD_FOOTER_H: f32 = 40;

/// Release one cover slot's GPU texture + heap pixels. RENDER-THREAD ONLY — it
/// is the sole owner of textures/pixels, so this never races a worker free.
fn freeCoverSlot(i: usize) void {
    if (sr_cover_tex[i]) |tex| {
        // textureDestroyLater needs a live dvui window. During appDeinit the
        // frame loop has already ended (current_window == null), so calling it
        // panics; the GPU textures are reclaimed on backend teardown anyway, so
        // skip the deferred destroy at shutdown and just drop our handle.
        if (dvui.current_window != null) dvui.textureDestroyLater(tex);
        sr_cover_tex[i] = null;
    }
    if (sr_cover_pixels[i]) |px| {
        alloc.free(px);
        sr_cover_pixels[i] = null;
    }
    sr_cover_w[i] = 0;
    sr_cover_h[i] = 0;
    sr_cover_failed[i] = false; // reclaimed slot → clear the failure latch so it can retry
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

/// Fetch + merge ONE readallcomics page, writing rows from slot `start`.
/// Returns the number of new rows (0 if the source is not installed / errored).
/// Worker-thread only.
fn fetchReadAllComicsPage(query: []const u8, paged: u32, gen: u32, start: usize) usize {
    var url_buf: [640]u8 = undefined;
    const url = buildSearchUrl(&url_buf, query, paged) orelse return 0; // inert (not installed)

    const html_buf = alloc.alloc(u8, 512 * 1024) catch return 0;
    defer alloc.free(html_buf);
    const n = fetchSearchHtml(url, html_buf);
    if (n == 0) return 0;

    // A newer search superseded us while curl was running — drop these results.
    if (search_gen.load(.acquire) != gen) return 0;
    return parseSearchResults(html_buf[0..n], gen, start);
}

/// Fetch + merge ONE MangaDex page (`offset` rows in), writing from slot `start`.
/// Returns the number of new rows. Worker-thread only; the JSON buffer is heap
/// allocated (a spawned thread's stack is ~512KB — see CLAUDE.md).
fn fetchMangadexPage(query: []const u8, offset: u32, gen: u32, start: usize) usize {
    var url_buf: [768]u8 = undefined;
    const url = pure.buildSearchUrl(&url_buf, query, RESULTS_PER_PAGE, offset) orelse return 0;

    const json_buf = alloc.alloc(u8, 512 * 1024) catch return 0;
    defer alloc.free(json_buf);
    const n = fetchUrl(url, json_buf);
    if (n == 0) return 0;

    if (search_gen.load(.acquire) != gen) return 0;
    return parseMangadexResults(json_buf[0..n], gen, start);
}

/// Fetch + merge ONE HeanCms `/query` page (1-based `page`), writing from slot
/// `start`. Returns the number of new rows (0 when "heancms" is not installed /
/// errored). Worker-thread only; the JSON buffer is heap-allocated (a spawned
/// thread's stack is ~512KB — see CLAUDE.md).
fn fetchHeancmsPage(query: []const u8, page: u32, gen: u32, start: usize) usize {
    var api_buf: [256]u8 = undefined;
    const api = heancmsApiHost(&api_buf) orelse return 0; // inert (not installed)

    var url_buf: [1024]u8 = undefined;
    const url = heancms.buildQueryUrl(&url_buf, api, query, page, heancms.ORDER_POPULAR) orelse return 0;

    const json_buf = alloc.alloc(u8, 512 * 1024) catch return 0;
    defer alloc.free(json_buf);
    const n = fetchUrl(url, json_buf);
    if (n == 0) return 0;

    if (search_gen.load(.acquire) != gen) return 0;
    return parseHeancmsResults(json_buf[0..n], gen, start);
}

/// Parse a HeanCms `/query` response into sr_* from slot `start`. Returns the
/// number of NEW rows appended. Mirrors parseMangadexResults exactly: worker-
/// thread only, it NEVER frees textures/pixels — it stamps each slot with `gen`
/// and writes the cover URL, leaving reclaimStaleCovers() the sole texture owner.
///
/// Cards store a `heancms:<series_slug>` pseudo-URL; fetchComicThread routes on
/// that prefix into the JSON reader chain (loadHeancmsPages) not the scraper.
fn parseHeancmsResults(json: []const u8, gen: u32, start: usize) usize {
    const data = heancms.findJsonNode(json, "\"data\"") orelse return 0;
    if (data.len == 0 or data[0] != '[') return 0;

    // Cover CDN resolved once for the whole page (absolute thumbnails ignore it).
    var cdn_buf: [512]u8 = undefined;
    const cdn = heancmsCdn(&cdn_buf);

    var count: usize = start;
    var it = heancms.ObjIter{ .buf = data };
    while (it.next()) |obj| {
        if (count >= MAX_SEARCH_RESULTS) break;
        const entry = heancms.parseSeriesEntry(obj) orelse continue;

        var url_buf: [160]u8 = undefined;
        const route = heancms.buildRouteUrl(&url_buf, entry.slug) orelse continue;
        if (route.len > sr_urls[count].len) continue;

        // Titles arrive JSON-escaped (\uXXXX for non-ASCII) — decode, then clamp
        // to a UTF-8 boundary so a truncated multi-byte char can't reach dvui.
        var t_raw: [512]u8 = undefined;
        const t_len = heancms.jsonUnescape(entry.title, &t_raw);
        var t_safe: [256]u8 = undefined;
        const title = @import("../core/text.zig").safeUtf8Buf(t_raw[0..@min(t_len, 255)], &t_safe);
        if (title.len == 0) continue;

        // De-dupe against every row already collected (`all` concatenates sources,
        // and a paginated page can resurface a title).
        {
            var dup = false;
            var d: usize = 0;
            while (d < count) : (d += 1) {
                if (std.mem.eql(u8, sr_urls[d][0..sr_url_lens[d]], route)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
        }

        @memcpy(sr_urls[count][0..route.len], route);
        sr_url_lens[count] = route.len;
        const tlen = @min(title.len, sr_titles[count].len);
        @memcpy(sr_titles[count][0..tlen], title[0..tlen]);
        sr_title_lens[count] = tlen;

        // Cover (thumbnail may be absolute or a CDN-relative path; may be absent).
        sr_cover_url_lens[count] = 0;
        if (entry.thumbnail.len > 0) {
            var raw_thumb: [640]u8 = undefined;
            const rn = heancms.jsonUnescape(entry.thumbnail, &raw_thumb);
            var cov_buf: [640]u8 = undefined;
            if (heancms.absolutizeCover(cdn, raw_thumb[0..rn], &cov_buf)) |cov| {
                if (cov.len < sr_cover_urls[count].len) {
                    @memcpy(sr_cover_urls[count][0..cov.len], cov);
                    sr_cover_url_lens[count] = cov.len;
                }
            }
        }
        sr_cover_gen[count] = gen;
        sr_cover_failed[count] = false; // fresh URL → let the cover retry

        count += 1;
    }

    if (search_gen.load(.acquire) != gen) return 0;
    sr_count = count;
    return count - start;
}
/// Fetch + merge ONE MangaThemesia browse page, writing rows from slot `start`.
/// Returns the number of new rows (0 if the source is not installed / errored).
/// Worker-thread only; the HTML buffer is heap allocated (a spawned thread's
/// stack is ~512KB — see CLAUDE.md).
fn fetchThemesiaPage(query: []const u8, page: u32, gen: u32, start: usize) usize {
    // INERT until a plugin supplies the base — mirrors readallcomics.
    var base_buf: [256]u8 = undefined;
    const base_raw = themesiaBase() orelse return 0;
    const bn = @min(base_raw.len, base_buf.len);
    @memcpy(base_buf[0..bn], base_raw[0..bn]);
    const base = base_buf[0..bn];

    // Popular/latest/A-Z all share this endpoint; text search uses the default
    // order so the `title` filter applies.
    var url_buf: [768]u8 = undefined;
    const url = mt.buildBrowseUrl(base, themesiaDir(), query, page, "", &url_buf) orelse return 0;

    const html_buf = alloc.alloc(u8, 512 * 1024) catch return 0;
    defer alloc.free(html_buf);
    const n = fetchUrl(url, html_buf);
    if (n == 0) return 0;
    if (search_gen.load(.acquire) != gen) return 0;
    return parseThemesiaResults(html_buf[0..n], base, gen, start);
}

/// Fetch + merge ONE Madara search page, writing rows from slot `start`. Returns
/// the number of new rows (0 if no Madara source is installed / errored). The
/// HTML buffer is heap allocated (worker-thread only — see CLAUDE.md). Routes all
/// parsing through the tested `manga_madara_pure` module.
fn fetchMadaraPage(query: []const u8, page: u32, gen: u32, start: usize) usize {
    const base = madaraBase() orelse return 0; // inert (not installed)
    var url_buf: [768]u8 = undefined;
    const url = madara.buildSearchUrl(&url_buf, base, query, page) orelse return 0;

    const html_buf = alloc.alloc(u8, 512 * 1024) catch return 0;
    defer alloc.free(html_buf);
    // buildSearchUrl returns a plain slice; fetchUrl takes one too.
    const n = fetchUrl(url, html_buf);
    if (n == 0) return 0;

    if (search_gen.load(.acquire) != gen) return 0;
    return parseMadaraResults(html_buf[0..n], gen, start);
}

/// Initial search: query every ACTIVE source and concatenate their rows.
/// readallcomics goes first (when installed) so an existing user's listing is
/// unchanged; MangaDex fills the rest — and is the whole listing on a fresh
/// install, where readallcomics is inert.
fn searchWorker(gen: u32) void {
    defer sr_searching = false;
    const query = sr_query_buf[0..sr_query_len];

    var filled: usize = 0;
    if (sourceActive(.readallcomics)) {
        filled += fetchReadAllComicsPage(query, 1, gen, filled);
    }
    // A newer search may have landed while the first source was in flight.
    if (search_gen.load(.acquire) != gen) {
        logs.pushLog("info", "comics", "Comic search superseded (stale dropped)", false);
        return;
    }
    if (sourceActive(.mangadex)) {
        filled += fetchMangadexPage(query, 0, gen, filled);
    }
    // A newer search may have landed while MangaDex was in flight.
    if (search_gen.load(.acquire) != gen) {
        logs.pushLog("info", "comics", "Comic search superseded (stale dropped)", false);
        return;
    }
    if (sourceActive(.heancms)) {
        filled += fetchHeancmsPage(query, 1, gen, filled);
    }
    if (sourceActive(.mangathemesia)) {
        filled += fetchThemesiaPage(query, 1, gen, filled);
    }
    if (search_gen.load(.acquire) != gen) return;
    // Madara (~332 WordPress sites) — inert until a "madara" source is installed.
    if (sourceActive(.madara) and madaraBase() != null) {
        filled += fetchMadaraPage(query, 1, gen, filled);
    }
    if (search_gen.load(.acquire) != gen) return;
    // Suwayomi — inert until the server base + a source id are configured. Gives
    // access to whichever installed Mihon/Aniyomi extension the user pointed at.
    if (sourceActive(.suwayomi)) {
        filled += fetchSuwayomiPage(query, 1, gen, filled);
    }

    // Only the LAST source's page size can tell us whether more rows exist; a
    // short page from every active source means we've hit the end.
    if (filled < RESULTS_PER_PAGE) more_available = false;
    // SWR write: persist ONLY the default landing feed (default query on the
    // `all` source) so the next cold start seeds instantly. User searches and
    // source-filtered feeds are not cached. Skip if a newer search superseded us.
    if (search_gen.load(.acquire) == gen and active_source == .all and
        std.mem.eql(u8, query, DEFAULT_FEED_QUERY)) putDefaultCache();
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

    // Each source appends at the CURRENT end of the listing — the parsers commit
    // sr_count as they go, so reading it again between sources is what keeps the
    // second source from overwriting the first one's freshly-appended rows.
    var added: usize = 0;
    if (sourceActive(.readallcomics)) {
        added += fetchReadAllComicsPage(query, next_page, gen, sr_count);
    }
    // A fresh search may have landed mid-fetch — its page 1 owns the listing now;
    // appending our older page would corrupt/duplicate it.
    if (search_gen.load(.acquire) != gen) return;
    if (sourceActive(.mangadex)) {
        // MangaDex paginates by row offset, not page number: page N starts at
        // (N-1)*RESULTS_PER_PAGE.
        added += fetchMangadexPage(query, (next_page - 1) * RESULTS_PER_PAGE, gen, sr_count);
    }
    if (search_gen.load(.acquire) != gen) return;
    if (sourceActive(.heancms)) {
        // HeanCms paginates by 1-based page number (its /query perPage=12).
        added += fetchHeancmsPage(query, next_page, gen, sr_count);
    }
    if (sourceActive(.mangathemesia)) {
        // MangaThemesia paginates by page number (1-based), like readallcomics.
        added += fetchThemesiaPage(query, next_page, gen, sr_count);
    }
    if (sourceActive(.madara) and madaraBase() != null) {
        // Madara paginates by WordPress page number (1-based) like readallcomics.
        added += fetchMadaraPage(query, next_page, gen, sr_count);
    }
    if (search_gen.load(.acquire) != gen) return;
    if (sourceActive(.suwayomi)) {
        // Suwayomi's /source/{id}/search paginates by 1-based page number.
        added += fetchSuwayomiPage(query, next_page, gen, sr_count);
    }

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
        // Fresh URL in this slot → clear any stale failure latch so the new cover
        // gets a fetch attempt (a re-stamped slot keeps its gen, so
        // reclaimStaleCovers won't reset it for us).
        sr_cover_failed[count] = false;

        count += 1;
    }

    // Re-check generation before committing — a fresher search may have started
    // while we were parsing. (If so, our slot stamps are already < the live gen,
    // so the render thread reclaims whatever we wrote; nothing leaks.)
    if (search_gen.load(.acquire) != gen) return 0;

    sr_count = count;
    return count - start;
}

/// Parse a MangaDex `/manga` search response into sr_* from slot `start`.
/// Returns the number of NEW rows appended. Mirrors parseSearchResults exactly:
/// worker-thread only, it NEVER frees textures/pixels — it just stamps each slot
/// with `gen` and writes the cover URL, leaving the render thread's
/// reclaimStaleCovers() as the sole owner of GPU textures + pixel buffers.
///
/// Cards store a `mangadex:<uuid>` pseudo-URL; fetchComicThread routes on that
/// prefix into the JSON reader chain (loadMangadexPages) instead of the scraper.
fn parseMangadexResults(json: []const u8, gen: u32, start: usize) usize {
    const data = pure.findJsonNode(json, "\"data\"") orelse return 0;

    var count: usize = start;
    var it = pure.ObjIter{ .buf = data };
    while (it.next()) |obj| {
        if (count >= MAX_SEARCH_RESULTS) break;
        const entry = pure.parseMangaEntry(obj) orelse continue;

        var url_buf: [64]u8 = undefined;
        const route = pure.buildRouteUrl(&url_buf, entry.id) orelse continue;
        if (route.len > sr_urls[count].len) continue;

        // Titles arrive JSON-escaped (\uXXXX for non-ASCII) — decode, then clamp
        // to a UTF-8 boundary so a truncated multi-byte char can't reach dvui.
        var t_raw: [512]u8 = undefined;
        const t_len = pure.jsonUnescape(entry.title, &t_raw);
        var t_safe: [256]u8 = undefined;
        const title = @import("../core/text.zig").safeUtf8Buf(t_raw[0..@min(t_len, 255)], &t_safe);
        if (title.len == 0) continue;

        // De-dupe against every row already collected (a paginated page can
        // resurface a title, and `all` concatenates two sources).
        {
            var dup = false;
            var d: usize = 0;
            while (d < count) : (d += 1) {
                if (std.mem.eql(u8, sr_urls[d][0..sr_url_lens[d]], route)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
        }

        @memcpy(sr_urls[count][0..route.len], route);
        sr_url_lens[count] = route.len;
        const tlen = @min(title.len, sr_titles[count].len);
        @memcpy(sr_titles[count][0..tlen], title[0..tlen]);
        sr_title_lens[count] = tlen;

        // Cover (may be absent — the card falls back to a gradient placeholder).
        sr_cover_url_lens[count] = 0;
        if (entry.cover_file.len > 0) {
            var cov_buf: [320]u8 = undefined;
            if (pure.buildCoverUrl(&cov_buf, entry.id, entry.cover_file)) |cov| {
                if (cov.len < sr_cover_urls[count].len) {
                    @memcpy(sr_cover_urls[count][0..cov.len], cov);
                    sr_cover_url_lens[count] = cov.len;
                }
            }
        }
        sr_cover_gen[count] = gen;
        sr_cover_failed[count] = false; // fresh URL → let the cover retry

        count += 1;
    }

    if (search_gen.load(.acquire) != gen) return 0;
    sr_count = count;
    return count - start;
}

/// Fetch + merge ONE Suwayomi source-search page (1-based `page`), writing rows
/// from slot `start`. Returns the number of new rows (0 when "suwayomi" isn't
/// configured / errored). Worker-thread only; JSON buffer is heap-allocated.
fn fetchSuwayomiPage(query: []const u8, page: u32, gen: u32, start: usize) usize {
    // Copy base + source id out of the reloadable source_config table.
    var base_buf: [256]u8 = undefined;
    const base_raw = suwayomiBase() orelse return 0; // inert (not configured)
    const bn = @min(base_raw.len, base_buf.len);
    @memcpy(base_buf[0..bn], base_raw[0..bn]);
    const base = base_buf[0..bn];

    var sid_buf: [24]u8 = undefined;
    const sid_raw = suwayomiSourceId() orelse return 0; // inert until a source is picked
    const sn = @min(sid_raw.len, sid_buf.len);
    @memcpy(sid_buf[0..sn], sid_raw[0..sn]);
    const source_id = sid_buf[0..sn];

    var url_buf: [1024]u8 = undefined;
    const url = suwayomi.buildSearchUrl(&url_buf, base, source_id, query, page) orelse return 0;

    const json_buf = alloc.alloc(u8, 512 * 1024) catch return 0;
    defer alloc.free(json_buf);
    const n = fetchUrl(url, json_buf);
    if (n == 0) return 0;

    if (search_gen.load(.acquire) != gen) return 0;
    return parseSuwayomiResults(json_buf[0..n], base, gen, start);
}

/// Parse a Suwayomi search response into sr_* from slot `start`. Returns the
/// number of NEW rows appended. Mirrors parseMangadexResults: worker-thread
/// only, never frees textures/pixels (stamps `gen` + writes the cover URL,
/// leaving reclaimStaleCovers the sole owner). Cards store `suwayomi:<mangaId>`.
fn parseSuwayomiResults(json: []const u8, base: []const u8, gen: u32, start: usize) usize {
    var count: usize = start;
    var it = suwayomi.MangaIter{ .json = json };
    while (it.next()) |obj| {
        if (count >= MAX_SEARCH_RESULTS) break;
        var id_buf: [24]u8 = undefined;
        var title_buf: [256]u8 = undefined;
        var thumb_buf: [512]u8 = undefined;
        const m = suwayomi.parseManga(obj, &id_buf, &title_buf, &thumb_buf) orelse continue;

        var url_buf: [40]u8 = undefined;
        const route = suwayomi.buildRouteUrl(&url_buf, m.id) orelse continue;
        if (route.len > sr_urls[count].len) continue;

        var t_safe: [256]u8 = undefined;
        const title = @import("../core/text.zig").safeUtf8Buf(m.title[0..@min(m.title.len, 255)], &t_safe);
        if (title.len == 0) continue;

        // De-dupe against every row already collected.
        {
            var dup = false;
            var d: usize = 0;
            while (d < count) : (d += 1) {
                if (std.mem.eql(u8, sr_urls[d][0..sr_url_lens[d]], route)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
        }

        @memcpy(sr_urls[count][0..route.len], route);
        sr_url_lens[count] = route.len;
        const tlen = @min(title.len, sr_titles[count].len);
        @memcpy(sr_titles[count][0..tlen], title[0..tlen]);
        sr_title_lens[count] = tlen;

        // Cover (thumbnailUrl absolutized against the server base; may be absent).
        sr_cover_url_lens[count] = 0;
        if (m.thumb.len > 0) {
            var cov_buf: [640]u8 = undefined;
            if (suwayomi.absolutizeThumb(&cov_buf, base, m.thumb)) |cov| {
                if (cov.len < sr_cover_urls[count].len) {
                    @memcpy(sr_cover_urls[count][0..cov.len], cov);
                    sr_cover_url_lens[count] = cov.len;
                }
            }
        }
        sr_cover_gen[count] = gen;
        sr_cover_failed[count] = false;

        count += 1;
    }
    if (search_gen.load(.acquire) != gen) return 0;
    sr_count = count;
    return count - start;
}

/// Resolve a Suwayomi manga id into a readable page list: chapters → earliest
/// chapter index → chapter meta (pageCount) → one page URL per page. Runs on the
/// fetchComicThread worker; all parsing via manga_suwayomi_pure.
fn loadSuwayomiPages(manga_id: []const u8) bool {
    var base_buf: [256]u8 = undefined;
    const base_raw = suwayomiBase() orelse return false;
    const bn = @min(base_raw.len, base_buf.len);
    @memcpy(base_buf[0..bn], base_raw[0..bn]);
    const base = base_buf[0..bn];

    // 1. Chapter list (onlineFetch forces a fresh pull from the source).
    var ch_url_buf: [320]u8 = undefined;
    const ch_url = suwayomi.buildChaptersUrl(&ch_url_buf, base, manga_id) orelse return false;
    const ch_buf = alloc.alloc(u8, 256 * 1024) catch return false;
    defer alloc.free(ch_buf);
    const ch_n = fetchUrl(ch_url, ch_buf);
    if (ch_n == 0 or workers.isQuitting()) return false;

    var idx_buf: [16]u8 = undefined;
    const ci_raw = suwayomi.firstChapterIndex(ch_buf[0..ch_n], &idx_buf) orelse {
        logs.pushLog("warn", "comics", "Suwayomi: no chapters for this title", false);
        return false;
    };
    var ci_store: [16]u8 = undefined;
    @memcpy(ci_store[0..ci_raw.len], ci_raw);
    const chapter_index = ci_store[0..ci_raw.len];

    // 2. Chapter metadata → pageCount.
    var cm_url_buf: [320]u8 = undefined;
    const cm_url = suwayomi.buildChapterUrl(&cm_url_buf, base, manga_id, chapter_index) orelse return false;
    const cm_buf = alloc.alloc(u8, 64 * 1024) catch return false;
    defer alloc.free(cm_buf);
    const cm_n = fetchUrl(cm_url, cm_buf);
    if (cm_n == 0 or workers.isQuitting()) return false;
    const pages = suwayomi.pageCount(cm_buf[0..cm_n]);
    if (pages == 0) return false;

    // 3. Stage one page URL per page (Suwayomi proxies + caches each page image).
    const max_pages = state.app.comic.page_urls.len; // 128
    var count: usize = 0;
    var p: u32 = 0;
    while (p < pages and count < max_pages) : (p += 1) {
        var page_buf: [512]u8 = undefined;
        const page_url = suwayomi.buildPageUrl(&page_buf, base, manga_id, chapter_index, p) orelse continue;
        if (page_url.len >= state.app.comic.page_urls[count].len) continue;
        @memcpy(state.app.comic.page_urls[count][0..page_url.len], page_url);
        state.app.comic.page_url_lens[count] = page_url.len;
        count += 1;
    }
    if (count == 0) return false;
    state.app.comic.page_count = count;
    if (state.app.comic.title_len == 0) {
        const t = "Suwayomi";
        @memcpy(state.app.comic.title[0..t.len], t);
        state.app.comic.title_len = t.len;
    }
    return true;
}

/// Parse a MangaThemesia browse/search page into sr_* from slot `start`.
/// Returns the number of NEW rows appended. Mirrors parseMangadexResults exactly:
/// worker-thread only, it NEVER frees textures/pixels — it just stamps each slot
/// with `gen` and writes the cover URL, leaving the render thread's
/// reclaimStaleCovers() as the sole owner of GPU textures + pixel buffers.
///
/// Cards store a `themesia:<manga-detail-url>` pseudo-URL; fetchComicThread routes
/// on that prefix into loadThemesiaPages (details→chapters→pages) instead of the
/// generic scraper. All parsing goes through the tested manga_themesia_pure.
fn parseThemesiaResults(html: []const u8, base: []const u8, gen: u32, start: usize) usize {
    var count: usize = start;
    var it = mt.SearchIter{ .html = html };
    while (it.next()) |item| {
        if (count >= MAX_SEARCH_RESULTS) break;

        // Absolute manga-detail URL, wrapped in the `themesia:` scheme so the card
        // routes to loadThemesiaPages rather than the generic HTML scraper.
        var abs_buf: [512]u8 = undefined;
        const abs = mt.resolveUrl(base, item.url, &abs_buf);
        if (abs.len == 0) continue;
        var route_buf: [560]u8 = undefined;
        const route = std.fmt.bufPrint(&route_buf, "{s}{s}", .{ mt.SCHEME, abs }) catch continue;
        if (route.len > sr_urls[count].len) continue;

        // Title: the `title="…"` attr, else derive from the URL slug.
        var title_buf: [256]u8 = undefined;
        var title: []const u8 = "";
        if (item.title.len > 0) {
            const raw = decodeEntities(item.title, title_buf[0..]);
            title = std.mem.trim(u8, title_buf[0..raw], " \t\r\n");
        }
        if (title.len == 0) {
            // Slug fallback: the last non-empty path segment of the detail URL.
            const trimmed = std.mem.trimEnd(u8, abs, "/");
            const slug = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |s| trimmed[s + 1 ..] else trimmed;
            title = slug;
        }
        var t_safe: [256]u8 = undefined;
        title = @import("../core/text.zig").safeUtf8Buf(title[0..@min(title.len, 255)], &t_safe);
        if (title.len == 0) continue;

        // De-dupe against every row already collected (paginated pages can
        // resurface a title, and `all` concatenates the sources).
        {
            var dup = false;
            var d: usize = 0;
            while (d < count) : (d += 1) {
                if (std.mem.eql(u8, sr_urls[d][0..sr_url_lens[d]], route)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
        }

        @memcpy(sr_urls[count][0..route.len], route);
        sr_url_lens[count] = route.len;
        const tlen = @min(title.len, sr_titles[count].len);
        @memcpy(sr_titles[count][0..tlen], title[0..tlen]);
        sr_title_lens[count] = tlen;

        // Cover (may be absent — the card falls back to a gradient placeholder).
        sr_cover_url_lens[count] = 0;
        if (item.img_tag.len > 0) {
            var cov_buf: [512]u8 = undefined;
            if (mt.pickImageAttr(item.img_tag, base, &cov_buf)) |cov| {
                if (cov.len < sr_cover_urls[count].len) {
                    @memcpy(sr_cover_urls[count][0..cov.len], cov);
                    sr_cover_url_lens[count] = cov.len;
                }
            }
        }
        sr_cover_gen[count] = gen;
        sr_cover_failed[count] = false; // fresh URL → let the cover retry

        count += 1;
    }

    if (search_gen.load(.acquire) != gen) return 0;
    sr_count = count;
    return count - start;
}

/// Parse a Madara search-grid HTML page into sr_* from slot `start`. Returns the
/// number of NEW rows appended. Mirrors the other parsers exactly: worker-thread
/// only, it NEVER frees textures/pixels — it stamps each slot with `gen` and
/// writes the cover URL, leaving the render thread's reclaimStaleCovers() the sole
/// owner of GPU textures + pixel buffers.
///
/// Cards store a `madara:<absolute mangaUrl>` pseudo-URL; fetchComicThread routes
/// on that prefix into the Madara reader chain (loadMadaraPages) instead of the
/// generic scraper. ALL parsing goes through the tested `manga_madara_pure`.
fn parseMadaraResults(html: []const u8, gen: u32, start: usize) usize {
    const base = madaraBase() orelse return 0;
    var base_buf: [256]u8 = undefined;
    if (base.len > base_buf.len) return 0;
    @memcpy(base_buf[0..base.len], base);
    const b = base_buf[0..base.len];

    var count: usize = start;
    var it = madara.SearchIter{ .html = html };
    while (it.next()) |item| {
        if (count >= MAX_SEARCH_RESULTS) break;

        // Resolve the manga URL to absolute, then wrap it in the madara: route.
        var murl_buf: [512]u8 = undefined;
        const manga_url = madara.resolveUrl(b, item.url, &murl_buf);
        if (manga_url.len == 0) continue;
        var route_buf: [520]u8 = undefined;
        const route = madara.buildRouteUrl(&route_buf, manga_url) orelse continue;
        if (route.len > sr_urls[count].len) continue;

        // Title: decode the handful of HTML entities Madara emits, then clamp to a
        // UTF-8 boundary so a truncated multi-byte char can't reach dvui.
        var t_dec: [320]u8 = undefined;
        const t_len = decodeEntities(item.title, &t_dec);
        var t_safe: [256]u8 = undefined;
        const title = @import("../core/text.zig").safeUtf8Buf(t_dec[0..@min(t_len, 255)], &t_safe);
        if (title.len == 0) continue;

        // De-dupe against every row already collected (paginated pages / `all`).
        {
            var dup = false;
            var d: usize = 0;
            while (d < count) : (d += 1) {
                if (std.mem.eql(u8, sr_urls[d][0..sr_url_lens[d]], route)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
        }

        @memcpy(sr_urls[count][0..route.len], route);
        sr_url_lens[count] = route.len;
        const tlen = @min(title.len, sr_titles[count].len);
        @memcpy(sr_titles[count][0..tlen], title[0..tlen]);
        sr_title_lens[count] = tlen;

        // Cover: resolve the raw image-attr url to absolute (may be absent).
        sr_cover_url_lens[count] = 0;
        if (item.cover.len > 0) {
            var cov_buf: [512]u8 = undefined;
            const cov = madara.resolveUrl(b, item.cover, &cov_buf);
            if (cov.len > 16 and cov.len < sr_cover_urls[count].len and std.mem.startsWith(u8, cov, "http")) {
                @memcpy(sr_cover_urls[count][0..cov.len], cov);
                sr_cover_url_lens[count] = cov.len;
            }
        }
        sr_cover_gen[count] = gen;
        sr_cover_failed[count] = false; // fresh URL → let the cover retry

        count += 1;
    }

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

    // Failure latch: any exit before we publish pixels means this cover produced
    // nothing (404 / undecodable / truncated). Latch it so renderCoverCard stops
    // re-spawning a curl worker every frame. Declared after the defers above so
    // it runs FIRST (LIFO) — while the slot's URL/quit state is still meaningful.
    // Skip the shutdown/repurpose exits (url cleared or quitting): those aren't
    // a real cover failure and the reset paths clear the latch anyway.
    var produced = false;
    defer if (!produced and !workers.isQuitting() and sr_cover_url_lens[idx] != 0) {
        sr_cover_failed[idx] = true;
    };

    const raw_url = sr_cover_urls[idx][0..sr_cover_url_lens[idx]];
    if (raw_url.len == 0) return;
    var url_buf: [560]u8 = undefined;
    const url = thumbnailize(raw_url, &url_buf);

    // Per-host UA: MangaDex cover art (uploads.mangadex.org) 400s a spoofed
    // browser UA — every cover would render as a blank placeholder. The scrapers'
    // blogspot CDN still gets the browser UA. See pure.userAgentFor.
    var ua_buf: [200]u8 = undefined;
    const ua = std.fmt.bufPrint(&ua_buf, "User-Agent: {s}", .{pure.userAgentFor(url)}) catch return;
    const argv = [_][]const u8{
        "curl",       "-sL",
        "-H",         ua,
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
    produced = true; // real pixels published → don't latch failure
}

// ══════════════════════════════════════════════════════════
// UI Rendering
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    drainPageTexFrees(); // free textures queued by the plugin manga-reload worker (UI thread)
    // Mihon extension browser takes over the whole tab when open (its own repo
    // picker + install list); the button below opens it.
    if (mihon.isOpen()) {
        mihon.renderPanel();
        return;
    }
    // A comic is open → the reader fills the whole tab (images + tools live in
    // renderPaneContent). Reading happens here in Browse, not the player route.
    if (state.app.comic.is_loading.load(.acquire) or state.app.comic.page_count > 0) {
        // Restore the persisted page once the issue's pages exist, then keep the
        // last-read page persisted (debounced) for as long as the reader is up.
        applyPendingResume();
        tickResume(false);
        var reader = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer reader.deinit();
        renderPaneContent(0);
        return;
    }

    // SWR seed: paint the last default feed from disk NOW (empty grid only), then
    // let the branch below fire the revalidating fetch (seed marks it stale).
    seedDefaultFromCache();

    // First open shows a default popular feed so the tab isn't blank (the
    // search box stays free for anything else).
    if (!loaded_default and sr_count == 0 and !sr_searching and state.app.comic.search_buf[0] == 0 and state.app.comic.title_len == 0) {
        loaded_default = true;
        searchComics(DEFAULT_FEED_QUERY);
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

    // ── ONE unified toolbar row (matches Movies & TV): compact search ·
    //    Search button · Source chips · result count · quick-links · −/+
    //    (wraps if the window is narrow). ReadAllComics is the only natively-
    //    readable source today; plugins surface as read-only badge chips. ──
    {
        var bar = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 6 },
        });
        defer bar.deinit();

        const components = @import("../ui/components.zig");
        const input = std.mem.sliceTo(&state.app.comic.search_buf, 0);
        const is_url = std.mem.startsWith(u8, input, "http");

        // Canonical compact toolbar input — fixed width instead of the old
        // full-width bar; pasted URLs still load directly.
        const enter_pressed = components.toolbarSearch(@src(), &state.app.comic.search_buf, "Search comics… (or URL)", 260);

        // Clear button (×) — visible only when there's text.
        if (input.len > 0) {
            if (dvui.buttonIcon(@src(), "comic-search-clear", icons.tvg.lucide.x, .{}, .{}, .{
                .id_extra = 9100,
                .color_fill = theme.colors.bg_elevated,
                .color_text = theme.colors.text_secondary,
                .corner_radius = theme.dims.rad_sm,
                .padding = .{ .x = 5, .y = 3, .w = 5, .h = 3 },
                .margin = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
                .gravity_y = 0.5,
            })) {
                state.app.comic.search_buf[0] = 0;
                last_fired_len = 0;
            }
        }

        const clicked = components.toolbarGo(@src(), "Search");

        // Explicit submit (Enter / Search) — URLs load directly, text searches.
        if (clicked or enter_pressed) {
            if (input.len > 0) {
                if (is_url) loadComic(input) else searchComics(input);
            }
        } else {
            // Live / incremental debounced search: buffer differs from the
            // last fired query, ≥2 chars, not a URL, 400ms since last edit.
            const now_ms = @import("../core/io_global.zig").milliTimestamp();
            const changed = !(input.len == last_fired_len and std.mem.eql(u8, input, last_fired_query[0..last_fired_len]));
            if (changed) last_edit_ms = now_ms;
            if (changed and input.len >= 2 and !is_url and !sr_searching and
                (now_ms - last_edit_ms) >= 400)
            {
                searchComics(input);
            }
        }

        _ = dvui.label(@src(), "  •  ", .{}, .{
            .color_text = theme.colors.border_subtle,
            .gravity_y = 0.5,
        });

        _ = dvui.label(@src(), "Source:", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
        });
        renderSourceChip("All", 1, .all);
        renderSourceChip("ReadAllComics", 2, .readallcomics);
        renderSourceChip("MangaDex", 3, .mangadex);
        renderSourceChip("MangaThemesia", 4, .mangathemesia);
        // Madara engine (~332 WordPress sites) — inert until a "madara" source is
        // installed, exactly like ReadAllComics.
        renderSourceChip("Madara", 5, .madara);
        // Suwayomi (Mihon extensions) — only when a server + source are set, so
        // the chip appears once the user has installed + picked an extension.
        if (suwayomiBase() != null and suwayomiSourceId() != null) {
            renderSourceChip("Suwayomi", 6, .suwayomi);
        }
        renderPluginSourceBadges();

        // Extensions — opens the Mihon extension browser (fetch a repo's
        // index.min.json, install/remove onto the Suwayomi server).
        if (dvui.button(@src(), "Extensions", .{}, .{
            .id_extra = 73500,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.accent,
            .color_border = theme.colors.accent,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_md,
            .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
            .margin = .{ .x = 6, .y = 0, .w = 2, .h = 0 },
            .gravity_y = 0.5,
        })) mihon.open();

        // Divider between the source group and the result/quick-link group.
        _ = dvui.label(@src(), "  •  ", .{}, .{
            .color_text = theme.colors.border_subtle,
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
                .color_text = if (sr_searching and sr_count == 0) theme.colors.accent else theme.colors.text_secondary,
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            });
        }

        renderChip("Invincible", 1, "/invincible-001/");
        renderChip("The Boys", 2, "/the-boys-001-2006/");
        renderChip("Saga", 3, "/saga-001-2012/");

        if (dvui.buttonIcon(@src(), "comic-card-smaller", icons.tvg.lucide.@"zoom-out", .{}, .{}, .{
            .id_extra = 9001,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 4, .w = 5, .h = 4 },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .gravity_y = 0.5,
        })) {
            card_w = std.math.clamp(card_w - 20, 110, 300);
        }
        if (dvui.buttonIcon(@src(), "comic-card-bigger", icons.tvg.lucide.@"zoom-in", .{}, .{}, .{
            .id_extra = 9002,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
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
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .margin = dvui.Rect.all(24),
        });
        return;
    }

    // Render-thread reclaim of the previous search's cover art (textures+pixels)
    // before drawing the current grid — keeps the render thread the sole owner.
    reclaimStaleCovers();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = theme.colors.bg_surface });
    defer scroll.deinit();

    // Responsive columns from the live page width (one-frame lag on first paint).
    const rect_w = scroll.data().rect.w;
    const avail_w: f32 = @max(240, (if (rect_w > 1) rect_w else 900) - 8);
    const cols: usize = @max(2, @as(usize, @intFromFloat(avail_w / card_w)));
    const cw: f32 = @max(100, (avail_w - @as(f32, @floatFromInt(cols)) * 8) / @as(f32, @floatFromInt(cols)));
    const cover_h: f32 = cw * 1.5; // comic covers ~2:3 portrait

    // ── Virtualization (same shape as tmdb.zig/anime.zig/jellyfin_ui.zig) ──
    // Cards are uniform (renderCoverCard pins min==max height), so rows have a
    // fixed pitch: cover + footer + 3px top/bottom margins. Rows outside the
    // viewport (±2 overscan) collapse into two spacer boxes, so the grid lays
    // out a handful of rows per frame instead of all ~120 card widget trees.
    const row_h: f32 = cover_h + CARD_FOOTER_H + 6;
    const total_rows = (sr_count + cols - 1) / cols;
    const win = @import("tmdb_pure.zig").visibleRows(total_rows, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 2);

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
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = base + 50000, .expand = .horizontal });
        defer row.deinit();
        var col: usize = 0;
        while (col < cols and base + col < sr_count) : (col += 1) {
            renderCoverCard(base + col, cw, cover_h);
        }
    }

    if (win.last < total_rows) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(total_rows - win.last)) },
        });
        sp.deinit();
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
            .color_fill = theme.colors.bg_elevated,
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
            .color_text = theme.colors.text_secondary,
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
        .color_fill = if (active) theme.colors.accent else theme.colors.bg_elevated,
        .color_text = if (active) dvui.Color.white else theme.colors.text_primary,
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
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/opal/plugins/comics", .{home}) catch return;
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
            .color_fill = theme.colors.bg_elevated,
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
// `path` is a source-relative slug (e.g. "/invincible-001/"); the host comes from
// the installed "readallcomics" plugin. No plugin → no popular chips.
fn renderChip(label: []const u8, id: usize, path: []const u8) void {
    const base = @import("../core/source_config.zig").get("readallcomics", "base") orelse return;
    if (dvui.button(@src(), label, .{}, .{
        .id_extra = id + 70000,
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.accent,
        .corner_radius = theme.dims.rad_md,
        .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        .gravity_y = 0.5,
    })) {
        var url_buf: [320]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base, path }) catch return;
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

    // min == max height → uniform row pitch, which the grid's virtualization
    // spacer math depends on (row_h = cover_h + CARD_FOOTER_H + margins).
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx,
        .min_size_content = .{ .w = cw, .h = cover_h + CARD_FOOTER_H },
        .max_size_content = .{ .w = cw, .h = cover_h + CARD_FOOTER_H },
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
                // Lazy-trigger fetch; meanwhile show a glyph placeholder. Skip a
                // slot whose cover already failed (404/undecodable) so it can't
                // re-spawn a curl worker every frame.
                if (sr_cover_url_lens[idx] > 0 and !sr_cover_failed[idx]) fetchCover(idx);
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
                    .color_text = theme.colors.text_primary,
                    .font = dvui.themeGet().font_heading,
                });
            }
        }

        const clicked = bw.clicked();
        bw.drawFocus();
        bw.deinit();
        if (clicked) {
            // Stage the card's title so the reader header has a name immediately.
            // The readallcomics path overwrites it from the issue page's <title>;
            // the MangaDex path keeps it and appends the chapter number (its JSON
            // reader chain never sees an HTML <title> to parse).
            const t = sr_titles[idx][0..sr_title_lens[idx]];
            const tl = @min(t.len, state.app.comic.title.len);
            @memcpy(state.app.comic.title[0..tl], t[0..tl]);
            state.app.comic.title_len = tl;

            loadComic(sr_urls[idx][0..sr_url_lens[idx]]);
        }
    }

    // Title caption below the cover (single-line, ellipsis via max height).
    _ = dvui.label(@src(), "{s}", .{title}, .{
        .id_extra = idx + 200,
        .expand = .horizontal,
        .color_text = theme.colors.text_primary,
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
                .color_text = theme.colors.text_primary,
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
                .color_text = theme.colors.text_secondary,
                .padding = .{ .x = 4, .y = 0, .w = 2, .h = 0 },
            });
        }

        // View mode toggle
        {
            const mode_icon = if (state.app.comic.view_mode == .scroll) icons.tvg.lucide.@"scroll-text" else icons.tvg.lucide.@"book-open";
            if (dvui.buttonIcon(@src(), "comic-view-mode", mode_icon, .{}, .{}, .{
                .id_extra = 10,
                .color_fill = theme.colors.bg_elevated,
                .color_text = theme.colors.text_primary,
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
                .color_fill = theme.colors.bg_elevated,
                .color_text = theme.colors.text_primary,
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
                .color_fill = theme.colors.bg_elevated,
                .color_text = theme.colors.text_primary,
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
            .color_fill = if (state.app.comic.show_ocr_overlay) theme.colors.accent else theme.colors.bg_elevated,
            .color_text = if (state.app.comic.show_ocr_overlay) dvui.Color.white else theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .padding = .{ .x = 5, .y = 2, .w = 5, .h = 2 },
            .margin = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
        })) {
            ocrCurrentPage();
        }

        // Narrate toggle
        if (dvui.buttonIcon(@src(), "comic-narrate", if (state.app.comic.narrating) icons.tvg.lucide.@"circle-stop" else icons.tvg.lucide.@"volume-2", .{}, .{}, .{
            .id_extra = 21,
            .color_fill = if (state.app.comic.narrating) theme.colors.accent else theme.colors.bg_elevated,
            .color_text = if (state.app.comic.narrating) dvui.Color.white else theme.colors.text_primary,
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
                    .color_text = theme.colors.text_secondary,
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
                    .color_text = theme.colors.text_secondary,
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
                    .color_text = theme.colors.text_secondary,
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
                    .color_text = theme.colors.text_primary,
                });
            } else {
                _ = dvui.label(@src(), "No text detected on this page", .{}, .{
                    .id_extra = 30001,
                    .color_text = theme.colors.text_secondary,
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

// Native ONNX Runtime OCR via C wrapper. Gated by `-Docr=true`; empty
// namespace otherwise so the @cImport never runs and onnxruntime isn't required.
const ocr_build_options = @import("ocr_build_options");
const has_ocr = ocr_build_options.has_ocr;
const ocr_c = if (has_ocr) @cImport({
    @cInclude("ocr_ort.h");
}) else struct {};

var ocr_initialized: bool = false;

fn ensureOcrInit() bool {
    if (!has_ocr) return false;
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

    // Run OCR via C wrapper (gated so the empty-struct stub built when
    // -Docr=false is never type-checked; Zig skips analysis of branches
    // under a comptime-known condition).
    if (has_ocr) {
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
                while (ai_voice.is_speaking.load(.acquire) and state.app.comic.narrating) {
                    @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
                }
                if (!state.app.comic.narrating) break;

                // Speak the filtered dialogue
                ai_voice.speakResponse(dialogue_buf[0..dialogue_len]);

                // Wait for TTS to finish
                while (ai_voice.is_speaking.load(.acquire) and state.app.comic.narrating) {
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
