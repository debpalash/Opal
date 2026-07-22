//! Light-novel / web-novel reader — search → novel → chapter list → paged text
//! reader. Structural sibling of comics.zig, but it renders TEXT, not page
//! images. All parsing / URL-building / HTML→text extraction lives in the
//! unit-tested novels_pure.zig; this module owns the async fetch workers,
//! thread-safety, resume persistence, and the dvui rendering.
//!
//! Source (v1): **Wikisource** — the documented, keyless MediaWiki action API
//! (en.wikisource.org). It is the guaranteed-legal, stable-contract source:
//! public-domain classics with a JSON search / subpage-list / parse chain. The
//! source lives behind the same seam comics uses (one URL builder set per
//! source in the pure module), so more sources can be added later.
//!
//! Flow:
//!   searchNovels(q)   → curl list=search    → pure.searchArray  → nr_* titles
//!   openNovel(idx)    → curl list=allpages  → pure.allpagesArray → ch_* chapters
//!   openChapter(idx)  → curl action=parse   → pure.extractParseHtml →
//!                       pure.htmlToText → state.app.novels.text_buf
//!   next/prev/resume  → openChapter(current ± 1) / the persisted chapter.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const io = @import("../core/io_global.zig");
const db = @import("../core/db.zig");
const pure = @import("novels_pure.zig");
const nsp = @import("novel_sources_pure.zig");
const source_config = @import("../core/source_config.zig");
// Anti-block fetch layer — used by the HTML-scraper engines' GETs so a
// Cloudflare/DDoS-Guard/captcha-fronted source resolves through the anti-detect
// browser. Wikisource's JSON API + the POST paths stay on plain curl. See scrapeHtml.
const scrape = @import("scrape_fetch.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

const alloc = @import("../core/alloc.zig").allocator;

const NovelSource = nsp.NovelSource;

// ── Source config gates ──
// Wikisource (keyless, guaranteed-legal public-domain classics) is ALWAYS on.
// The scraper engines are base-URL-driven and INERT until a plugin supplies the
// base via source_config — nothing infringing is hardcoded (mirrors comics.zig).
fn madaraNovelBase() ?[]const u8 {
    return source_config.get("madara_novel", "base");
}
fn lightnovelwpBase() ?[]const u8 {
    return source_config.get("lightnovelwp", "base");
}
fn lightnovelwpDir() []const u8 {
    return source_config.get("lightnovelwp", "dir") orelse "/series";
}
fn readwnBase() ?[]const u8 {
    return source_config.get("readwn", "base");
}

const agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

// ── Persisted resume ──
// Last-read chapter index per novel, stored in the generic library_status KV
// (kind = "novel_resume", item_id = work title) — the lightest existing
// persistence pattern (no new schema / db.zig edit).
const RESUME_KIND = "novel_resume";

// ── Result + chapter storage (module statics, like comics' sr_* arrays) ──
// Kept out of AppState (which only holds the selected work + reader text): the
// search grid and chapter list are transient, published by the fetch workers
// under `parse_mutex`. Never reallocated, so the UI thread reads them directly.
// Bumped from 40 to hold several appended pages of infinite-scroll results (the
// arrays are fixed-size — never reallocated — so the UI thread reads them without
// a pointer-stability worry as the append workers grow nr_count).
const MAX_RESULTS: usize = 200;
// Per-source rows requested per page. Keeps each source's first page small enough
// that the aggregated landing feed leaves room for the other sources, and makes
// Wikisource's `sroffset` pagination pull real additional rows on scroll.
const PAGE_SIZE: u32 = 20;
var nr_titles: [MAX_RESULTS][256]u8 = undefined;
var nr_title_lens: [MAX_RESULTS]usize = std.mem.zeroes([MAX_RESULTS]usize);
// Per-result source + novel URL. Wikisource identifies a work by its title
// (`nr_urls` empty); the scraper engines identify it by an absolute URL.
var nr_urls: [MAX_RESULTS][512]u8 = undefined;
var nr_url_lens: [MAX_RESULTS]usize = std.mem.zeroes([MAX_RESULTS]usize);
var nr_source: [MAX_RESULTS]NovelSource = undefined;
var nr_count: usize = 0;

const MAX_CHAPTERS: usize = 400;
// For Wikisource: the full page title ("Frankenstein/Chapter 1") — the fetch key
// for action=parse. For the scraper engines: the chapter's display name.
var ch_titles: [MAX_CHAPTERS][256]u8 = undefined;
var ch_title_lens: [MAX_CHAPTERS]usize = std.mem.zeroes([MAX_CHAPTERS]usize);
// Absolute chapter URL (scraper engines only; empty for Wikisource).
var ch_urls: [MAX_CHAPTERS][512]u8 = undefined;
var ch_url_lens: [MAX_CHAPTERS]usize = std.mem.zeroes([MAX_CHAPTERS]usize);
var ch_count: usize = 0;

// The engine of the currently-open novel — set by openNovel BEFORE spawning the
// chapters/text workers, which dispatch on it (chapter-list markup + chapter-text
// container differ per source). Snapshot-before-spawn, like work_snap.
var open_source: NovelSource = .wikisource;

// ── Thread-safety ──
// Detached workers publish under `parse_mutex`; monotonic generations drop stale
// results so fast re-drills never show out-of-order data (mirrors radio.zig).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var chapters_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var text_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// ── Read-only view of the listings, for remote.zig's /api/novels ──
// The nr_*/ch_* arrays stay private (workers rewrite them in place under
// parse_mutex). These copy out under the SAME mutex, so a connection thread can
// never read a row mid-rewrite. Copy semantics, not slices: the caller is on
// another thread and holds nothing once the lock drops.

pub const ListRow = struct {
    title_buf: [256]u8 = std.mem.zeroes([256]u8),
    title_len: usize = 0,
    url_buf: [512]u8 = std.mem.zeroes([512]u8),
    url_len: usize = 0,
    source: u8 = 0,

    pub fn title(self: *const ListRow) []const u8 {
        return self.title_buf[0..@min(self.title_len, self.title_buf.len)];
    }
    pub fn url(self: *const ListRow) []const u8 {
        return self.url_buf[0..@min(self.url_len, self.url_buf.len)];
    }
};

pub fn resultCount() usize {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    return @min(nr_count, MAX_RESULTS);
}

pub fn resultRow(i: usize) ?ListRow {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (i >= @min(nr_count, MAX_RESULTS)) return null;
    var out: ListRow = .{};
    out.title_len = @min(nr_title_lens[i], out.title_buf.len);
    @memcpy(out.title_buf[0..out.title_len], nr_titles[i][0..out.title_len]);
    out.url_len = @min(nr_url_lens[i], out.url_buf.len);
    @memcpy(out.url_buf[0..out.url_len], nr_urls[i][0..out.url_len]);
    out.source = @intFromEnum(nr_source[i]);
    return out;
}

pub fn chapterCount() usize {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    return @min(ch_count, MAX_CHAPTERS);
}

pub fn chapterRow(i: usize) ?ListRow {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (i >= @min(ch_count, MAX_CHAPTERS)) return null;
    var out: ListRow = .{};
    out.title_len = @min(ch_title_lens[i], out.title_buf.len);
    @memcpy(out.title_buf[0..out.title_len], ch_titles[i][0..out.title_len]);
    out.url_len = @min(ch_url_lens[i], out.url_buf.len);
    @memcpy(out.url_buf[0..out.url_len], ch_urls[i][0..out.url_len]);
    out.source = @intFromEnum(open_source);
    return out;
}

// ── Infinite-scroll pagination (search grid) ──
// `current_page` is the highest scraper-source page merged into nr_* (Wikisource
// paginates by offset instead — see loadMoreWorker). `loading_more` serializes
// append fetches so one near-bottom scroll can't spawn a burst. `more_available`
// gates the render trigger; the per-source `*_more` flags let an exhausted source
// (a short/duplicate page, or a source that genuinely can't page) drop out while
// the others keep loading. All shared between the UI thread and the append worker,
// so every flag is atomic (CLAUDE.md). The worker runs under the same `search_gen`
// as the initial search, so a fresh query supersedes an in-flight append.
var current_page: u32 = 1;
var more_available: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var wiki_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var madara_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var lnwp_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
// readwn's search POST has no page parameter — it returns one fixed set, so it is
// never re-fetched by loadMore (implicitly exhausted after page 1).

// Snapshots handed to detached workers (never read the mutable UI buffers from a
// worker — copy by value before spawning; see CLAUDE.md thread rules).
var query_snap: [256]u8 = undefined;
var query_snap_len: usize = 0;
var work_snap: [256]u8 = undefined;
var work_snap_len: usize = 0;
// Selected novel's absolute URL (scraper engines) — the details/chapter-list key.
var work_url_snap: [512]u8 = undefined;
var work_url_snap_len: usize = 0;
var chapter_snap: [256]u8 = undefined;
var chapter_snap_len: usize = 0;
// Selected chapter's absolute URL (scraper engines) — the chapter-text fetch key.
var chapter_url_snap: [512]u8 = undefined;
var chapter_url_snap_len: usize = 0;

// Reader text framing cap — matches state.app.novels.text_buf. Anything longer
// is truncated and flagged (text_truncated) so the UI can say so.
const TEXT_CAP: usize = 131072;

// ══════════════════════════════════════════════════════════
// Search
// ══════════════════════════════════════════════════════════

pub fn searchNovels(query: []const u8) void {
    if (query.len == 0 or query.len >= query_snap.len) return;

    state.app.novels.is_loading.store(true, .release);
    state.app.novels.fetch_error = false;
    state.app.novels.view = .search;

    const my_gen = search_gen.fetchAdd(1, .acq_rel) + 1;
    const n = @min(query.len, query_snap.len);
    @memcpy(query_snap[0..n], query[0..n]);
    query_snap_len = n;

    // Fresh query resets infinite-scroll pagination: page 1, every source eligible.
    current_page = 1;
    more_available.store(true, .release);
    wiki_more.store(true, .release);
    madara_more.store(true, .release);
    lnwp_more.store(true, .release);

    if (std.Thread.spawn(.{}, searchWorker, .{my_gen})) |t| {
        t.detach();
    } else |_| {
        state.app.novels.is_loading.store(false, .release);
    }
}

/// Query every ACTIVE source and concatenate their rows. Wikisource first (the
/// always-on legal default), then each scraper engine that a plugin has supplied
/// a base for. Mirrors comics.zig's searchWorker aggregation.
fn searchWorker(my_gen: u32) void {
    defer state.app.novels.is_loading.store(false, .release);

    var local: [256]u8 = undefined;
    const qlen = @min(query_snap_len, local.len);
    @memcpy(local[0..qlen], query_snap[0..qlen]);
    const query = local[0..qlen];

    parse_mutex.lock();
    nr_count = 0;
    parse_mutex.unlock();

    var filled: usize = 0;
    filled += fetchWikisource(query, my_gen, filled, 0);
    if (search_gen.load(.acquire) != my_gen) return;

    if (madaraNovelBase() != null) {
        filled += fetchMadaraNovel(query, my_gen, filled, 1);
        if (search_gen.load(.acquire) != my_gen) return;
    }
    if (lightnovelwpBase() != null) {
        filled += fetchLightnovelwp(query, my_gen, filled, 1);
        if (search_gen.load(.acquire) != my_gen) return;
    }
    if (readwnBase() != null) {
        filled += fetchReadwn(query, my_gen, filled);
    }

    if (filled == 0) {
        logs.pushLog("info", "novels", "Novel search returned no works", false);
    } else {
        logs.pushLog("info", "novels", "Novel search done", false);
    }
}

/// Publish one search row (title + optional URL + source) into the nr_* arrays.
/// Runs under parse_mutex on the search worker.
fn addResult(idx: usize, src: NovelSource, title: []const u8, url: []const u8) void {
    if (idx >= MAX_RESULTS) return;
    const tlen = @min(title.len, nr_titles[idx].len);
    @memcpy(nr_titles[idx][0..tlen], title[0..tlen]);
    nr_title_lens[idx] = tlen;
    const ulen = @min(url.len, nr_urls[idx].len);
    @memcpy(nr_urls[idx][0..ulen], url[0..ulen]);
    nr_url_lens[idx] = ulen;
    nr_source[idx] = src;
}

/// True when a row already present in nr_*[0..upto) matches the candidate — the
/// infinite-scroll dedup so an appended page never repeats a row. Scraper rows are
/// keyed by their absolute URL; Wikisource rows (empty URL) by source + title.
/// Caller must hold `parse_mutex`.
fn rowExists(src: NovelSource, title: []const u8, url: []const u8, upto: usize) bool {
    const cap = @min(upto, MAX_RESULTS);
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        if (url.len > 0) {
            if (nr_url_lens[i] == url.len and std.mem.eql(u8, nr_urls[i][0..nr_url_lens[i]], url)) return true;
        } else if (nr_source[i] == src) {
            if (nr_title_lens[i] == title.len and std.mem.eql(u8, nr_titles[i][0..nr_title_lens[i]], title)) return true;
        }
    }
    return false;
}

/// Count the Wikisource rows currently in nr_*[0..nr_count) — the `sroffset` for
/// the next Wikisource page (how many of its results we've already consumed).
/// Caller must hold `parse_mutex`.
fn wikiCountLocked() u32 {
    var c: u32 = 0;
    var i: usize = 0;
    const cap = @min(nr_count, MAX_RESULTS);
    while (i < cap) : (i += 1) {
        if (nr_source[i] == .wikisource) c += 1;
    }
    return c;
}

/// Decode HTML entities out of a scraped title (it carries no block tags, so
/// htmlToText just entity-decodes + collapses whitespace). Into `out`.
fn cleanTitle(raw: []const u8, out: []u8) []const u8 {
    const n = pure.htmlToText(raw, out);
    return out[0..n];
}

/// Copy a source_config base out of its static table (it can be reloaded).
fn copyBase(raw: []const u8, out: []u8) []const u8 {
    const n = @min(raw.len, out.len);
    @memcpy(out[0..n], raw[0..n]);
    return out[0..n];
}

/// Wikisource `list=search` → nr_* rows (the always-on default source). `offset`
/// is the `sroffset` continuation (0 for the first page); rows are appended at
/// `start` and deduped by title so infinite-scroll pages never repeat a work.
fn fetchWikisource(query: []const u8, my_gen: u32, start: usize, offset: u32) usize {
    var url_buf: [1024]u8 = undefined;
    const url = pure.buildSearchUrl(&url_buf, query, PAGE_SIZE, offset) orelse return 0;
    const body = curl(url, 512 * 1024) orelse {
        state.app.novels.fetch_error = true;
        return 0;
    };
    defer alloc.free(body);
    if (search_gen.load(.acquire) != my_gen) return 0;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return 0;

    const arr = pure.searchArray(body) orelse return 0;
    var it = pure.cj.ObjIter{ .buf = arr };
    var n: usize = 0;
    while (it.next()) |obj| {
        if (start + n >= MAX_RESULTS) break;
        const raw = pure.titleField(obj) orelse continue;
        var dec: [256]u8 = undefined;
        const dn = pure.cj.jsonUnescape(raw, &dec);
        if (dn == 0) continue;
        if (rowExists(.wikisource, dec[0..dn], "", start + n)) continue;
        addResult(start + n, .wikisource, dec[0..dn], "");
        n += 1;
    }
    nr_count = start + n;
    return n;
}

/// Madara-novel search — REUSES the manga Madara `SearchIter` (identical DOM);
/// only the chapter body later differs. Rows carry the absolute novel URL.
fn fetchMadaraNovel(query: []const u8, my_gen: u32, start: usize, page: u32) usize {
    const base_raw = madaraNovelBase() orelse return 0;
    var base_buf: [256]u8 = undefined;
    const base = copyBase(base_raw, &base_buf);

    var url_buf: [768]u8 = undefined;
    const url = nsp.madara.buildSearchUrl(&url_buf, base, query, page) orelse return 0;
    const body = scrapeHtml(url, 512 * 1024) orelse return 0;
    defer alloc.free(body);
    if (search_gen.load(.acquire) != my_gen) return 0;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return 0;

    var it = nsp.madara.SearchIter{ .html = body };
    var n: usize = 0;
    while (it.next()) |item| {
        if (start + n >= MAX_RESULTS) break;
        var abs_buf: [512]u8 = undefined;
        const abs = nsp.madara.resolveUrl(base, item.url, &abs_buf);
        if (abs.len == 0 or !std.mem.startsWith(u8, abs, "http")) continue;
        var t_buf: [256]u8 = undefined;
        const title = cleanTitle(item.title, &t_buf);
        if (rowExists(.madara_novel, title, abs, start + n)) continue;
        addResult(start + n, .madara_novel, title, abs);
        n += 1;
    }
    nr_count = start + n;
    return n;
}

/// lightnovelwp search — REUSES the MangaThemesia browse endpoint + `SearchIter`.
fn fetchLightnovelwp(query: []const u8, my_gen: u32, start: usize, page: u32) usize {
    const base_raw = lightnovelwpBase() orelse return 0;
    var base_buf: [256]u8 = undefined;
    const base = copyBase(base_raw, &base_buf);

    var url_buf: [768]u8 = undefined;
    const url = nsp.themesia.buildBrowseUrl(base, lightnovelwpDir(), query, page, "", &url_buf) orelse return 0;
    const body = scrapeHtml(url, 512 * 1024) orelse return 0;
    defer alloc.free(body);
    if (search_gen.load(.acquire) != my_gen) return 0;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return 0;

    var it = nsp.themesia.SearchIter{ .html = body };
    var n: usize = 0;
    while (it.next()) |item| {
        if (start + n >= MAX_RESULTS) break;
        if (item.title.len == 0) continue;
        var abs_buf: [512]u8 = undefined;
        const abs = nsp.themesia.resolveUrl(base, item.url, &abs_buf);
        if (abs.len == 0 or !std.mem.startsWith(u8, abs, "http")) continue;
        var t_buf: [256]u8 = undefined;
        const title = cleanTitle(item.title, &t_buf);
        if (rowExists(.lightnovelwp, title, abs, start + n)) continue;
        addResult(start + n, .lightnovelwp, title, abs);
        n += 1;
    }
    nr_count = start + n;
    return n;
}

/// readwn search — POST form to `/e/search/index.php`, parsed by the standalone
/// `ReadwnIter`. Rows carry the absolute novel URL.
fn fetchReadwn(query: []const u8, my_gen: u32, start: usize) usize {
    const base_raw = readwnBase() orelse return 0;
    var base_buf: [256]u8 = undefined;
    const base = copyBase(base_raw, &base_buf);

    var url_buf: [320]u8 = undefined;
    const url = nsp.readwnSearchUrl(&url_buf, base) orelse return 0;
    var body_buf: [640]u8 = undefined;
    const post = nsp.readwnSearchBody(&body_buf, query) orelse return 0;
    var ref_buf: [320]u8 = undefined;
    const referer = nsp.readwnReferer(&ref_buf, base);

    const body = curlPost(url, post, referer, 512 * 1024) orelse return 0;
    defer alloc.free(body);
    if (search_gen.load(.acquire) != my_gen) return 0;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return 0;

    var it = nsp.ReadwnIter{ .html = body };
    var n: usize = 0;
    while (it.next()) |item| {
        if (start + n >= MAX_RESULTS) break;
        var abs_buf: [512]u8 = undefined;
        const abs = nsp.themesia.resolveUrl(base, item.url, &abs_buf);
        if (abs.len == 0 or !std.mem.startsWith(u8, abs, "http")) continue;
        var t_buf: [256]u8 = undefined;
        const title = cleanTitle(item.title, &t_buf);
        if (rowExists(.readwn, title, abs, start + n)) continue;
        addResult(start + n, .readwn, title, abs);
        n += 1;
    }
    nr_count = start + n;
    return n;
}

// ══════════════════════════════════════════════════════════
// Infinite scroll — append the next page of the current query
// ══════════════════════════════════════════════════════════

/// Fetch + append the NEXT page of the current search when the user nears the
/// bottom. Guarded like drama.loadMore: no-op once `more_available` clears, while
/// the initial search is loading, or while an append is already in flight; a
/// single scroll can't spawn a burst. Runs under the current `search_gen`, so a
/// fresh query supersedes it. Wikisource continues by `sroffset`; the scraper
/// engines by page number (`current_page + 1`); readwn's search can't page and is
/// never re-fetched here.
pub fn loadMore() void {
    if (!more_available.load(.acquire)) return;
    if (state.app.novels.is_loading.load(.acquire)) return;
    if (loading_more.load(.acquire)) return;

    parse_mutex.lock();
    const count = nr_count;
    parse_mutex.unlock();
    if (count == 0) return;
    if (count >= MAX_RESULTS) {
        more_available.store(false, .release);
        return;
    }

    if (loading_more.swap(true, .acq_rel)) return; // lost the race — append already running
    const my_gen = search_gen.load(.acquire);
    const next = current_page + 1;
    if (std.Thread.spawn(.{}, loadMoreWorker, .{ my_gen, next })) |t| {
        t.detach();
        current_page = next; // UI-thread-only write; the worker got `next` by value
    } else |_| {
        loading_more.store(false, .release);
    }
}

/// Append worker: pull the next page from each still-eligible active source and
/// merge it onto nr_* (never clears nr_count). A source that appends 0 new rows is
/// marked exhausted so it isn't re-queried on the next scroll; `more_available`
/// clears once every source is exhausted. Uses the SAME fetch paths (and thus the
/// same parse + dedup) as the initial search.
fn loadMoreWorker(my_gen: u32, next_page: u32) void {
    defer loading_more.store(false, .release);

    var local: [256]u8 = undefined;
    const qlen = @min(query_snap_len, local.len);
    @memcpy(local[0..qlen], query_snap[0..qlen]);
    const query = local[0..qlen];
    if (qlen == 0) return;

    parse_mutex.lock();
    var start = nr_count;
    parse_mutex.unlock();

    if (wiki_more.load(.acquire)) {
        parse_mutex.lock();
        const offset = wikiCountLocked();
        parse_mutex.unlock();
        const n = fetchWikisource(query, my_gen, start, offset);
        if (search_gen.load(.acquire) != my_gen) return;
        start += n;
        if (n == 0) wiki_more.store(false, .release);
    }
    if (madara_more.load(.acquire) and madaraNovelBase() != null and start < MAX_RESULTS) {
        const n = fetchMadaraNovel(query, my_gen, start, next_page);
        if (search_gen.load(.acquire) != my_gen) return;
        start += n;
        if (n == 0) madara_more.store(false, .release);
    }
    if (lnwp_more.load(.acquire) and lightnovelwpBase() != null and start < MAX_RESULTS) {
        const n = fetchLightnovelwp(query, my_gen, start, next_page);
        if (search_gen.load(.acquire) != my_gen) return;
        start += n;
        if (n == 0) lnwp_more.store(false, .release);
    }

    const any = wiki_more.load(.acquire) or
        (madara_more.load(.acquire) and madaraNovelBase() != null) or
        (lnwp_more.load(.acquire) and lightnovelwpBase() != null);
    more_available.store(any and start < MAX_RESULTS, .release);
    logs.pushLog("info", "novels", "Novel search page appended", false);
}

// ══════════════════════════════════════════════════════════
// Open a novel → fetch its chapter list
// ══════════════════════════════════════════════════════════

pub fn openNovel(idx: usize) void {
    if (idx >= nr_count) return;

    // Snapshot the selected work (source + title + URL) BEFORE spawning — the
    // search grid can be reordered by a fresh search while chapters load.
    open_source = nr_source[idx];

    const tlen = @min(nr_title_lens[idx], state.app.novels.work_title.len);
    @memcpy(state.app.novels.work_title[0..tlen], nr_titles[idx][0..tlen]);
    state.app.novels.work_title_len = tlen;
    @memcpy(work_snap[0..tlen], nr_titles[idx][0..tlen]);
    work_snap_len = tlen;

    const ulen = @min(nr_url_lens[idx], work_url_snap.len);
    @memcpy(work_url_snap[0..ulen], nr_urls[idx][0..ulen]);
    work_url_snap_len = ulen;

    state.app.novels.view = .chapters;
    state.app.novels.chapters_loading.store(true, .release);
    state.app.novels.fetch_error = false;

    parse_mutex.lock();
    ch_count = 0;
    parse_mutex.unlock();

    const my_gen = chapters_gen.fetchAdd(1, .acq_rel) + 1;
    if (std.Thread.spawn(.{}, chaptersWorker, .{my_gen})) |t| {
        t.detach();
    } else |_| {
        state.app.novels.chapters_loading.store(false, .release);
    }
}

/// Dispatch the chapter-list fetch to the open novel's engine.
fn chaptersWorker(my_gen: u32) void {
    defer state.app.novels.chapters_loading.store(false, .release);
    switch (open_source) {
        .wikisource => chaptersWikisource(my_gen),
        .madara_novel => chaptersMadara(my_gen),
        .lightnovelwp => chaptersLightnovelwp(my_gen),
        .readwn => chaptersReadwn(my_gen),
        .readnovelfull => {}, // not shipped in v1
    }
}

/// Publish one chapter (display name + optional absolute URL) into the ch_* arrays.
fn addChapter(idx: usize, name: []const u8, url: []const u8) void {
    if (idx >= MAX_CHAPTERS) return;
    const nlen = @min(name.len, ch_titles[idx].len);
    @memcpy(ch_titles[idx][0..nlen], name[0..nlen]);
    ch_title_lens[idx] = nlen;
    const ulen = @min(url.len, ch_urls[idx].len);
    @memcpy(ch_urls[idx][0..ulen], url[0..ulen]);
    ch_url_lens[idx] = ulen;
}

/// Reverse the first `count` chapters in place. The scraper engines list chapters
/// newest→oldest; reading order is oldest→newest, so chapter 0 becomes chapter 1.
fn reverseChapters(count: usize) void {
    if (count < 2) return;
    var i: usize = 0;
    while (i < count / 2) : (i += 1) {
        const j = count - 1 - i;
        std.mem.swap([256]u8, &ch_titles[i], &ch_titles[j]);
        std.mem.swap(usize, &ch_title_lens[i], &ch_title_lens[j]);
        std.mem.swap([512]u8, &ch_urls[i], &ch_urls[j]);
        std.mem.swap(usize, &ch_url_lens[i], &ch_url_lens[j]);
    }
}

/// Wikisource: `list=allpages` subpages. When a work has none (single-page work),
/// synthesize one chapter = the work page so the reader still opens.
fn chaptersWikisource(my_gen: u32) void {
    var work: [256]u8 = undefined;
    const wlen = @min(work_snap_len, work.len);
    @memcpy(work[0..wlen], work_snap[0..wlen]);

    var url_buf: [1024]u8 = undefined;
    const url = pure.buildSubpagesUrl(&url_buf, work[0..wlen], MAX_CHAPTERS) orelse return;

    const body = curl(url, 512 * 1024) orelse {
        state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (chapters_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (chapters_gen.load(.acquire) != my_gen) return;

    var count: usize = 0;
    if (pure.allpagesArray(body)) |arr| {
        var it = pure.cj.ObjIter{ .buf = arr };
        while (it.next()) |obj| {
            if (count >= MAX_CHAPTERS) break;
            const raw = pure.titleField(obj) orelse continue;
            var dec: [256]u8 = undefined;
            const dn = pure.cj.jsonUnescape(raw, &dec);
            if (dn == 0) continue;
            addChapter(count, dec[0..dn], "");
            count += 1;
        }
    }
    if (count == 0) {
        addChapter(0, work[0..wlen], "");
        count = 1;
    }
    ch_count = count;
    logs.pushLog("info", "novels", "Novel chapter list loaded (Wikisource)", false);
}

/// Madara-novel: REUSES the manga Madara `ChapterIter` over the details HTML, with
/// the same admin-ajax.php / `{url}ajax/chapters` fallbacks the comics reader uses.
fn chaptersMadara(my_gen: u32) void {
    const base_raw = madaraNovelBase() orelse return;
    var base_buf: [256]u8 = undefined;
    const base = copyBase(base_raw, &base_buf);

    var murl_buf: [512]u8 = undefined;
    const mn = @min(work_url_snap_len, murl_buf.len);
    @memcpy(murl_buf[0..mn], work_url_snap[0..mn]);
    const murl = murl_buf[0..mn];
    if (murl.len == 0) return;

    const body = scrapeHtml(murl, 1024 * 1024) orelse {
        state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (chapters_gen.load(.acquire) != my_gen) return;

    // Inline `li.wp-manga-chapter` first; else the AJAX fallbacks (heap bodies).
    var ajax_body: ?[]u8 = null;
    defer if (ajax_body) |ab| alloc.free(ab);
    var list_html: []const u8 = body;
    {
        var probe = nsp.madara.ChapterIter{ .html = body };
        if (probe.next() == null) {
            // Fallback A: admin-ajax.php?action=manga_get_chapters&manga=<data-id>.
            if (nsp.madara.dataIdFromHolder(body)) |data_id| {
                var au_buf: [320]u8 = undefined;
                var form_buf: [128]u8 = undefined;
                if (nsp.madara.buildAjaxUrl(&au_buf, base)) |ajax_url| {
                    if (nsp.madara.buildAjaxBody(&form_buf, data_id)) |form| {
                        if (curlPost(ajax_url, form, murl, 512 * 1024)) |ab| {
                            ajax_body = ab;
                            list_html = ab;
                        }
                    }
                }
            }
            // Fallback B: {novelUrl}ajax/chapters (empty POST body).
            if (ajax_body == null) {
                var au_buf: [560]u8 = undefined;
                const dir = std.mem.trimEnd(u8, murl, "/");
                if (std.fmt.bufPrint(&au_buf, "{s}/ajax/chapters", .{dir})) |ajax2| {
                    if (curlPost(ajax2, "", murl, 512 * 1024)) |ab| {
                        ajax_body = ab;
                        list_html = ab;
                    }
                } else |_| {}
            }
        }
    }

    if (chapters_gen.load(.acquire) != my_gen) return;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (chapters_gen.load(.acquire) != my_gen) return;

    var it = nsp.madara.ChapterIter{ .html = list_html };
    var n: usize = 0;
    while (it.next()) |ch| {
        if (n >= MAX_CHAPTERS) break;
        if (ch.url.len == 0) continue;
        var abs_buf: [512]u8 = undefined;
        const abs = nsp.madara.resolveUrl(base, ch.url, &abs_buf);
        if (abs.len == 0 or !std.mem.startsWith(u8, abs, "http")) continue;
        var name_buf: [256]u8 = undefined;
        addChapter(n, cleanTitle(ch.name, &name_buf), abs);
        n += 1;
    }
    reverseChapters(n);
    ch_count = n;
    logs.pushLog("info", "novels", "Novel chapter list loaded (madara)", false);
}

/// lightnovelwp: REUSES the MangaThemesia `chapterIter` over the series HTML.
fn chaptersLightnovelwp(my_gen: u32) void {
    const base_raw = lightnovelwpBase() orelse return;
    var base_buf: [256]u8 = undefined;
    const base = copyBase(base_raw, &base_buf);

    var murl_buf: [512]u8 = undefined;
    const mn = @min(work_url_snap_len, murl_buf.len);
    @memcpy(murl_buf[0..mn], work_url_snap[0..mn]);
    const murl = murl_buf[0..mn];
    if (murl.len == 0) return;

    const body = scrapeHtml(murl, 1024 * 1024) orelse {
        state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (chapters_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (chapters_gen.load(.acquire) != my_gen) return;

    var it = nsp.themesia.chapterIter(body);
    var n: usize = 0;
    while (it.next()) |ch| {
        if (n >= MAX_CHAPTERS) break;
        if (ch.url.len == 0) continue;
        var abs_buf: [512]u8 = undefined;
        const abs = nsp.themesia.resolveUrl(base, ch.url, &abs_buf);
        if (abs.len == 0 or !std.mem.startsWith(u8, abs, "http")) continue;
        var name_buf: [256]u8 = undefined;
        addChapter(n, cleanTitle(ch.name, &name_buf), abs);
        n += 1;
    }
    reverseChapters(n);
    ch_count = n;
    logs.pushLog("info", "novels", "Novel chapter list loaded (lightnovelwp)", false);
}

/// readwn: the standalone `.chapter-list` iterator. readwn lists chapters
/// ascending already, so no reversal.
fn chaptersReadwn(my_gen: u32) void {
    const base_raw = readwnBase() orelse return;
    var base_buf: [256]u8 = undefined;
    const base = copyBase(base_raw, &base_buf);

    var murl_buf: [512]u8 = undefined;
    const mn = @min(work_url_snap_len, murl_buf.len);
    @memcpy(murl_buf[0..mn], work_url_snap[0..mn]);
    const murl = murl_buf[0..mn];
    if (murl.len == 0) return;

    const body = scrapeHtml(murl, 1024 * 1024) orelse {
        state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (chapters_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (chapters_gen.load(.acquire) != my_gen) return;

    var it = nsp.readwnChapters(body);
    var n: usize = 0;
    while (it.next()) |ch| {
        if (n >= MAX_CHAPTERS) break;
        if (ch.url.len == 0) continue;
        var abs_buf: [512]u8 = undefined;
        const abs = nsp.themesia.resolveUrl(base, ch.url, &abs_buf);
        if (abs.len == 0 or !std.mem.startsWith(u8, abs, "http")) continue;
        var name_buf: [256]u8 = undefined;
        addChapter(n, cleanTitle(ch.name, &name_buf), abs);
        n += 1;
    }
    ch_count = n;
    logs.pushLog("info", "novels", "Novel chapter list loaded (readwn)", false);
}

// ══════════════════════════════════════════════════════════
// Open a chapter → fetch + extract its text
// ══════════════════════════════════════════════════════════

pub fn openChapter(idx: usize) void {
    if (idx >= ch_count) return;

    state.app.novels.current_chapter = idx;
    state.app.novels.view = .reader;
    state.app.novels.text_loading.store(true, .release);
    state.app.novels.text_len = 0;
    state.app.novels.text_truncated = false;
    state.app.novels.fetch_error = false;

    // Snapshot the chapter's page title (Wikisource key) + absolute URL (scraper
    // engines) + display label BEFORE spawning.
    const flen = @min(ch_title_lens[idx], chapter_snap.len);
    @memcpy(chapter_snap[0..flen], ch_titles[idx][0..flen]);
    chapter_snap_len = flen;

    const culen = @min(ch_url_lens[idx], chapter_url_snap.len);
    @memcpy(chapter_url_snap[0..culen], ch_urls[idx][0..culen]);
    chapter_url_snap_len = culen;

    const label = pure.chapterLabel(ch_titles[idx][0..ch_title_lens[idx]]);
    const llen = @min(label.len, state.app.novels.chapter_label.len);
    @memcpy(state.app.novels.chapter_label[0..llen], label[0..llen]);
    state.app.novels.chapter_label_len = llen;

    // Persist resume: this is now the last-read chapter for this work.
    saveResume(idx);

    const my_gen = text_gen.fetchAdd(1, .acq_rel) + 1;
    if (std.Thread.spawn(.{}, textWorker, .{my_gen})) |t| {
        t.detach();
    } else |_| {
        state.app.novels.text_loading.store(false, .release);
    }
}

/// Next / previous chapter, clamped. No-ops past the ends.
pub fn nextChapter() void {
    const cur = state.app.novels.current_chapter;
    if (cur + 1 < ch_count) openChapter(cur + 1);
}
pub fn prevChapter() void {
    const cur = state.app.novels.current_chapter;
    if (cur > 0) openChapter(cur - 1);
}

/// Dispatch the chapter-text fetch to the open novel's engine.
fn textWorker(my_gen: u32) void {
    defer state.app.novels.text_loading.store(false, .release);
    if (open_source == .wikisource) {
        textWikisource(my_gen);
    } else {
        textSourced(my_gen);
    }
}

/// Wikisource: `action=parse&prop=text` → JSON `parse.text` HTML → reading text.
fn textWikisource(my_gen: u32) void {
    var page: [256]u8 = undefined;
    const plen = @min(chapter_snap_len, page.len);
    @memcpy(page[0..plen], chapter_snap[0..plen]);

    var url_buf: [1024]u8 = undefined;
    const url = pure.buildChapterUrl(&url_buf, page[0..plen]) orelse return;

    const body = curl(url, 2 * 1024 * 1024) orelse {
        state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (text_gen.load(.acquire) != my_gen) return;

    // Two-stage, both heap/state (never a big buffer on the worker stack):
    //   JSON parse.text → HTML (heap) → clean reading text (state.text_buf).
    const html = alloc.alloc(u8, 2 * 1024 * 1024) catch {
        state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(html);
    const html_len = pure.extractParseHtml(body, html);
    if (html_len == 0) {
        state.app.novels.fetch_error = true;
        logs.pushLog("info", "novels", "Chapter had no extractable text", false);
        return;
    }

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (text_gen.load(.acquire) != my_gen) return;

    const n = pure.htmlToText(html[0..html_len], state.app.novels.text_buf[0..TEXT_CAP]);
    state.app.novels.text_len = n;
    // htmlToText stops exactly at the buffer end when the prose overran it.
    state.app.novels.text_truncated = (n >= TEXT_CAP);
    logs.pushLog("info", "novels", "Chapter text extracted", false);
}

/// Scraper engines: GET the chapter URL, extract the source's prose container
/// (via novel_sources_pure), then HTML→clean text. The container selector is the
/// ONLY per-engine difference; everything else is the shared reader pipeline.
fn textSourced(my_gen: u32) void {
    var url_buf: [512]u8 = undefined;
    const un = @min(chapter_url_snap_len, url_buf.len);
    @memcpy(url_buf[0..un], chapter_url_snap[0..un]);
    const chapter_url = url_buf[0..un];
    if (chapter_url.len == 0 or !std.mem.startsWith(u8, chapter_url, "http")) {
        state.app.novels.fetch_error = true;
        return;
    }

    const body = scrapeHtml(chapter_url, 2 * 1024 * 1024) orelse {
        state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (text_gen.load(.acquire) != my_gen) return;

    const content = nsp.chapterContentHtml(body, open_source) orelse {
        state.app.novels.fetch_error = true;
        logs.pushLog("info", "novels", "Chapter had no extractable text", false);
        return;
    };

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (text_gen.load(.acquire) != my_gen) return;

    const n = pure.htmlToText(content, state.app.novels.text_buf[0..TEXT_CAP]);
    state.app.novels.text_len = n;
    state.app.novels.text_truncated = (n >= TEXT_CAP);
    logs.pushLog("info", "novels", "Chapter text extracted", false);
}

// ══════════════════════════════════════════════════════════
// Resume persistence (per-novel last-read chapter)
// ══════════════════════════════════════════════════════════

fn saveResume(chapter: usize) void {
    const title = state.app.novels.work_title[0..state.app.novels.work_title_len];
    if (title.len == 0) return;
    var key_buf: [256]u8 = undefined;
    const key = pure.resumeKey(title, &key_buf);
    var val_buf: [24]u8 = undefined;
    const val = pure.formatResume(&val_buf, chapter);
    db.librarySetStatus(RESUME_KIND, key, val);

    // Mirror into the unified read-model so the home "Continue" rail spans the
    // reading verticals too. library_status above stays authoritative; this is
    // the denormalized cache. Progress is measured in CHAPTERS (chapter index →
    // secs, chapter count → duration) so percentOf yields the read-through
    // fraction; the deep link reopens the work through openDeepLink().
    var link_buf: [512]u8 = undefined;
    const link = pure.formatDeepLink(
        &link_buf,
        @tagName(open_source),
        work_url_snap[0..work_url_snap_len],
        title,
    );
    if (link.len == 0) return;
    parse_mutex.lock();
    const total = ch_count;
    parse_mutex.unlock();
    var label_buf: [48]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "Chapter {d}", .{chapter + 1}) catch "";
    @import("library_store.zig").upsertProgress(
        "novels",
        key,
        title,
        "",
        @floatFromInt(chapter + 1),
        @floatFromInt(total),
        label,
        link,
    );
}

/// Reopen a novel from a home library deep link (`novel|<source>|<url>|<title>`).
/// Ignores links that aren't ours or name an unknown source, then follows the
/// same path as openNovel: publish the work snapshot, then fetch its chapters.
pub fn openDeepLink(link: []const u8) void {
    const parsed = pure.parseDeepLink(link) orelse return;
    const src = std.meta.stringToEnum(NovelSource, parsed.source) orelse return;

    open_source = src;

    const tlen = @min(parsed.title.len, state.app.novels.work_title.len);
    @memcpy(state.app.novels.work_title[0..tlen], parsed.title[0..tlen]);
    state.app.novels.work_title_len = tlen;
    @memcpy(work_snap[0..tlen], parsed.title[0..tlen]);
    work_snap_len = tlen;

    const ulen = @min(parsed.url.len, work_url_snap.len);
    @memcpy(work_url_snap[0..ulen], parsed.url[0..ulen]);
    work_url_snap_len = ulen;

    state.app.novels.view = .chapters;
    state.app.novels.chapters_loading.store(true, .release);
    state.app.novels.fetch_error = false;

    parse_mutex.lock();
    ch_count = 0;
    parse_mutex.unlock();

    state.app.browse_source = .Novels;
    state.app.router.navigate(.browse);

    const my_gen = chapters_gen.fetchAdd(1, .acq_rel) + 1;
    if (std.Thread.spawn(.{}, chaptersWorker, .{my_gen})) |t| {
        t.detach();
    } else |_| {
        state.app.novels.chapters_loading.store(false, .release);
    }
}

/// The persisted last-read chapter for the current work (0 when none).
fn loadResume() usize {
    const title = state.app.novels.work_title[0..state.app.novels.work_title_len];
    if (title.len == 0) return 0;
    var key_buf: [256]u8 = undefined;
    const key = pure.resumeKey(title, &key_buf);
    var val_buf: [24]u8 = undefined;
    const val = db.libraryGetStatus(RESUME_KIND, key, &val_buf);
    return pure.parseResume(val);
}

// ══════════════════════════════════════════════════════════
// Networking
// ══════════════════════════════════════════════════════════

/// Fetch `url` with curl into a fresh heap buffer of `cap` bytes. Returns the
/// filled slice (caller frees) or null on failure/empty. Large buffers stay off
/// the worker stack (macOS 512KB limit). Mirrors radio.curl.
fn curl(url: []const u8, cap: usize) ?[]u8 {
    const argv = [_][]const u8{ "curl", "-sL", "-A", agent, "--max-time", "20", url };
    var child = io.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return null;

    const buf = alloc.alloc(u8, cap) catch {
        _ = child.wait() catch {};
        return null;
    };
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) {
        alloc.free(buf);
        return null;
    }
    // Shrink to the read length — the global DebugAllocator checks free size
    // against alloc size, so freeing buf[0..n] out of a cap-sized allocation
    // would abort (see radio.zig / podcasts.zig).
    return alloc.realloc(buf, n) catch {
        alloc.free(buf);
        return null;
    };
}

/// Anti-block HTML fetch — same owned-heap-buffer contract as `curl` (returns a
/// freshly-allocated, right-sized slice the caller frees; null on empty/failure),
/// but routes the GET through scrapeFetch so a Cloudflare/DDoS-Guard/captcha-
/// fronted scraper source (Madara-novel / lightnovelwp / readwn) resolves via the
/// anti-detect browser when the plain fetch is challenged. Gated internally by the
/// `scrape_use_browser` config toggle — OFF ⇒ plain HTTP, identical to `curl`.
///
/// Used for the HTML-scraper engines' search / chapter-list / chapter-text GETs.
/// Wikisource's keyless JSON API stays on `curl` (never challenged, and a browser-
/// rendered response would not be the raw JSON it parses); the POST paths (readwn
/// search, Madara AJAX chapter lists) stay on `curlPost` — scrapeFetch is GET-only.
fn scrapeHtml(url: []const u8, cap: usize) ?[]u8 {
    const buf = alloc.alloc(u8, cap) catch return null;
    const body = scrape.scrapeFetch(url, buf) orelse {
        alloc.free(buf);
        return null;
    };
    // scrapeFetch fills `buf` from index 0 and returns buf[0..n] (plain and
    // browser-fallback paths both do), so realloc-to-n keeps the right bytes and
    // gives the DebugAllocator a size-matched free (mirrors `curl`).
    if (body.len == 0) {
        alloc.free(buf);
        return null;
    }
    return alloc.realloc(buf, body.len) catch {
        alloc.free(buf);
        return null;
    };
}

/// POST `body` to `url` with a `Referer` header (readwn search + Madara AJAX
/// chapter lists need both). Same heap-buffer discipline as `curl`.
fn curlPost(url: []const u8, body: []const u8, referer: []const u8, cap: usize) ?[]u8 {
    var ref_hdr: [640]u8 = undefined;
    const rh = std.fmt.bufPrint(&ref_hdr, "Referer: {s}", .{referer}) catch return null;
    const argv = [_][]const u8{ "curl", "-sL", "-A", agent, "-H", rh, "--data", body, "--max-time", "20", url };
    var child = io.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return null;

    const buf = alloc.alloc(u8, cap) catch {
        _ = child.wait() catch {};
        return null;
    };
    const n = if (child.stdout) |*so| io.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) {
        alloc.free(buf);
        return null;
    }
    return alloc.realloc(buf, n) catch {
        alloc.free(buf);
        return null;
    };
}

// ══════════════════════════════════════════════════════════
// UI (Browse › Novels)
// ══════════════════════════════════════════════════════════

pub fn renderContent() void {
    var pageroot = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer pageroot.deinit();

    switch (state.app.novels.view) {
        .search => renderSearchView(),
        .chapters => renderChaptersView(),
        .reader => renderReaderView(),
    }
}

fn renderSearchView() void {
    renderSearchBar();

    if (state.app.novels.fetch_error) {
        _ = dvui.label(@src(), "Failed to fetch — check your connection", .{}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    parse_mutex.lock();
    const count = @min(nr_count, MAX_RESULTS);
    parse_mutex.unlock();

    if (count == 0) {
        const msg = if (state.app.novels.is_loading.load(.acquire))
            "Searching…"
        else
            "Search public-domain novels & light novels to start reading";
        _ = dvui.label(@src(), "{s}", .{msg}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
        });
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    _ = dvui.label(@src(), "Results", .{}, .{
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 10, .y = 8, .w = 8, .h = 2 },
    });

    var i: usize = 0;
    while (i < count) : (i += 1) {
        var name_buf: [256]u8 = undefined;
        const name = safeUtf8Buf(nr_titles[i][0..@min(nr_title_lens[i], nr_titles[i].len)], &name_buf);
        if (dvui.button(@src(), name, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .margin = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
            .gravity_x = 0,
        })) {
            openNovel(i);
        }
    }

    // Infinite scroll: append the next page of the current query as the user nears
    // the bottom. Bounded by more_available + loading_more so one scroll can't
    // spawn a burst; `underfilled` keeps paging when the first page is shorter than
    // the viewport. Mirrors services/drama.zig.
    if (more_available.load(.acquire)) {
        const loading = loading_more.load(.acquire);
        const max_y = scroll.si.scrollMax(.vertical);
        const near_bottom = max_y > 0 and scroll.si.viewport.y >= max_y - 800;
        const underfilled = max_y <= 0 and count > 0;
        if ((near_bottom or underfilled) and !loading and !state.app.novels.is_loading.load(.acquire)) {
            loadMore();
        }
        if (loading or underfilled) {
            dvui.spinner(@src(), .{
                .color_text = theme.colors.accent,
                .min_size_content = theme.iconSize(.lg),
                .gravity_x = 0.5,
                .margin = dvui.Rect.all(12),
            });
            dvui.refresh(null, @src(), null); // wake until the appended rows land
        }
    }
}

fn renderSearchBar() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer row.deinit();

    _ = dvui.icon(@src(), "", icons.tvg.lucide.@"book-marked", .{}, .{
        .color_text = theme.colors.accent,
        .min_size_content = theme.iconSize(.md),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
    });

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &state.app.novels.search_buf },
        .placeholder = "Search novels…",
    }, .{
        .expand = .horizontal,
        .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
        .color_fill = theme.colors.bg_elevated,
        .color_text = theme.colors.text_primary,
        .corner_radius = theme.dims.rad_sm,
        .gravity_y = 0.5,
    });
    const entered = te.enter_pressed;
    te.deinit();

    const go = dvui.button(@src(), "Go", .{}, .{
        .color_fill = theme.colors.accent,
        .color_text = dvui.Color.white,
        .corner_radius = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
        .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
        .gravity_y = 0.5,
    });

    if (entered or go) {
        const q = std.mem.sliceTo(&state.app.novels.search_buf, 0);
        if (q.len > 0) searchNovels(q);
    }

    if (state.app.novels.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "…", .{}, .{ .color_text = theme.colors.warning, .gravity_y = 0.5 });
    }
}

fn renderChaptersView() void {
    // Header: back to search + the work title.
    {
        var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer hrow.deinit();

        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"arrow-left", .{}, .{}, .{
            .id_extra = 1,
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        })) {
            state.app.novels.view = .search;
        }

        var title_buf: [256]u8 = undefined;
        const title = safeUtf8Buf(state.app.novels.work_title[0..state.app.novels.work_title_len], &title_buf);
        _ = dvui.label(@src(), "{s}", .{title}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
            .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
            .font = dvui.themeGet().font_heading,
        });
    }

    if (state.app.novels.fetch_error) {
        _ = dvui.label(@src(), "Failed to load chapters", .{}, .{
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 8, .w = 0, .h = 0 },
        });
    }

    parse_mutex.lock();
    const count = @min(ch_count, MAX_CHAPTERS);
    parse_mutex.unlock();

    if (count == 0) {
        const msg = if (state.app.novels.chapters_loading.load(.acquire)) "Loading chapters…" else "No chapters found";
        _ = dvui.label(@src(), "{s}", .{msg}, .{
            .color_text = theme.colors.text_secondary,
            .padding = .{ .x = 12, .y = 20, .w = 0, .h = 0 },
        });
        return;
    }

    // Resume banner — jump straight to the last-read chapter.
    const resume_ch = loadResume();
    if (resume_ch > 0 and resume_ch < count) {
        var resume_buf: [64]u8 = undefined;
        const resume_label = std.fmt.bufPrint(&resume_buf, "Resume — chapter {d}", .{resume_ch + 1}) catch "Resume";
        if (dvui.button(@src(), resume_label, .{}, .{
            .id_extra = 90001,
            .expand = .horizontal,
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = theme.dims.rad_sm,
            .margin = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        })) {
            openChapter(resume_ch);
        }
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const label = pure.chapterLabel(ch_titles[i][0..@min(ch_title_lens[i], ch_titles[i].len)]);
        var lbl_buf: [256]u8 = undefined;
        const safe = safeUtf8Buf(label, &lbl_buf);
        if (dvui.button(@src(), safe, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .corner_radius = theme.dims.rad_sm,
            .margin = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
            .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
            .gravity_x = 0,
        })) {
            openChapter(i);
        }
    }
}

fn renderReaderView() void {
    // Keyboard: Esc → chapter list; [ / ] → prev / next chapter; +/- font size.
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt == .key and e.evt.key.action == .down) {
            switch (e.evt.key.code) {
                .escape => {
                    state.app.novels.view = .chapters;
                    e.handled = true;
                },
                .left_bracket => {
                    prevChapter();
                    e.handled = true;
                },
                .right_bracket => {
                    nextChapter();
                    e.handled = true;
                },
                else => {},
            }
        }
    }

    // ── Reader toolbar ──
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
            .background = true,
            .color_fill = theme.colors.bg_surface,
        });
        defer bar.deinit();

        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"list", .{}, .{}, .{
            .id_extra = 1,
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        })) {
            state.app.novels.view = .chapters;
        }

        var lbl_buf: [160]u8 = undefined;
        const label = safeUtf8Buf(state.app.novels.chapter_label[0..state.app.novels.chapter_label_len], &lbl_buf);
        _ = dvui.label(@src(), "{s}", .{label}, .{
            .color_text = theme.colors.text_primary,
            .gravity_y = 0.5,
            .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
        });

        var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        spacer.deinit();

        // Font size − / +
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.minus, .{}, .{}, .{
            .id_extra = 2,
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        })) {
            state.app.novels.font_scale = @max(0.7, state.app.novels.font_scale - 0.1);
        }
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.plus, .{}, .{}, .{
            .id_extra = 3,
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        })) {
            state.app.novels.font_scale = @min(2.0, state.app.novels.font_scale + 0.1);
        }

        // Prev / Next chapter
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-left", .{}, .{}, .{
            .id_extra = 4,
            .color_text = if (state.app.novels.current_chapter > 0) theme.colors.text_primary else theme.colors.text_tertiary,
            .gravity_y = 0.5,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        })) {
            prevChapter();
        }
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"chevron-right", .{}, .{}, .{
            .id_extra = 5,
            .color_text = if (state.app.novels.current_chapter + 1 < ch_count) theme.colors.text_primary else theme.colors.text_tertiary,
            .gravity_y = 0.5,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        })) {
            nextChapter();
        }
    }

    if (state.app.novels.text_loading.load(.acquire) and state.app.novels.text_len == 0) {
        _ = dvui.label(@src(), "Loading chapter…", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 24, .w = 0, .h = 0 },
        });
        dvui.refresh(null, @src(), null);
        return;
    }

    if (state.app.novels.fetch_error and state.app.novels.text_len == 0) {
        _ = dvui.label(@src(), "Failed to load this chapter", .{}, .{
            .color_text = theme.colors.danger,
            .gravity_x = 0.5,
            .padding = .{ .x = 0, .y = 24, .w = 0, .h = 0 },
        });
        return;
    }

    // ── Scrollable, comfortably-wide reading column ──
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 22, .a = 255 },
    });
    defer scroll.deinit();

    // Center a max-width column so long lines don't sprawl across a wide window.
    var column = dvui.box(@src(), .{ .dir = .vertical }, .{
        .max_size_content = .{ .w = 720, .h = std.math.floatMax(f32) },
        .expand = .horizontal,
        .gravity_x = 0.5,
        .padding = .{ .x = 24, .y = 16, .w = 24, .h = 24 },
    });
    defer column.deinit();

    const font = dvui.themeGet().font_body.withSize(16 * state.app.novels.font_scale);

    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
    // Chunk the text so a single addText never exceeds the UTF-8 safety buffer.
    const text = state.app.novels.text_buf[0..state.app.novels.text_len];
    var off: usize = 0;
    var chunk_buf: [8192]u8 = undefined;
    while (off < text.len) {
        var end = @min(off + 4096, text.len);
        // Back up to a UTF-8 boundary so a chunk never splits a codepoint.
        end = pure.charBoundaryBack(text, end);
        if (end <= off) end = @min(off + 4096, text.len); // degenerate guard
        const safe = safeUtf8Buf(text[off..end], &chunk_buf);
        tl.addText(safe, .{ .color_text = theme.colors.text_primary, .font = font });
        off = end;
    }
    if (state.app.novels.text_truncated) {
        tl.addText("\n\n[Chapter truncated — text exceeded the reader buffer.]", .{
            .color_text = theme.colors.text_tertiary,
            .font = font,
        });
    }
    tl.deinit();
}
