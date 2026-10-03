//! Light-novel / web-novel reader — search → novel → chapter list → paged text
//! reader. Structural sibling of comics.zig, but it renders TEXT, not page
//! images. All parsing / URL-building / HTML→text extraction lives in the
//! unit-tested novels_pure.zig; this module owns the async fetch workers,
//! thread-safety, resume persistence, and the dvui rendering.
//!
//! Zero-config sources: **Wikisource** (documented MediaWiki action API) and
//! **Internet Archive** (advanced search + metadata APIs). Both surface
//! public-domain/open texts and share this module's reader and paging flow.
//!
//! Flow:
//!   searchNovels(q)   → reliable fetch list=search → pure.searchArray → nr_* titles
//!   openNovel(idx)    → reliable fetch list=allpages → pure.allpagesArray → ch_* chapters
//!   openChapter(idx)  → reliable fetch action=parse → pure.extractParseHtml →
//!                       pure.htmlToText → state.app.novels.text_buf
//!   next/prev/resume  → openChapter(current ± 1) / the persisted chapter.

const std = @import("std");
const safeUtf8 = @import("../core/text.zig").safeUtf8;
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const components = @import("../ui/components.zig");
const logs = @import("../core/logs.zig");
const reliable_fetch = @import("reliable_fetch.zig");
const db = @import("../core/db.zig");
const pure = @import("novels_pure.zig");
const nsp = @import("novel_sources_pure.zig");
const archive = @import("archive_pure.zig");
const expanded = @import("expanded_reading_pure.zig");
const reading_provider = @import("reading_provider_pure.zig");
const books = @import("public_books_pure.zig");
const source_config = @import("../core/source_config.zig");
// Anti-block fetch layer — used by the HTML-scraper engines' GETs so a
// Cloudflare/DDoS-Guard/captcha-fronted source resolves through the anti-detect
// browser. Wikisource's JSON API + the POST paths stay on plain curl. See scrapeHtml.
const scrape = @import("scrape_fetch.zig");
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;
const LatestRequest = @import("../core/latest_request.zig").Gate;
const tmdb_pure = @import("tmdb_pure.zig");

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
var nr_metadata: [MAX_RESULTS]NovelMetadata = [_]NovelMetadata{.{}} ** MAX_RESULTS;
var novel_covers: [MAX_RESULTS]components.CoverSlot = [_]components.CoverSlot{.{}} ** MAX_RESULTS;
var native_card_rects: [MAX_RESULTS]dvui.Rect.Physical = undefined;
pub fn nativeCardRectsForTest() []const dvui.Rect.Physical {
    if (!@import("builtin").is_test) @compileError("Native fixture is test-only");
    return native_card_rects[0..nr_count];
}

pub fn setNativeFixtureForTest(textures: []const dvui.Texture) void {
    if (!@import("builtin").is_test) @compileError("Native fixture is test-only");
    for (&novel_covers) |*cover| cover.reset();
    nr_count = @min(textures.len, MAX_RESULTS);
    state.app.novels.view = .search;
    state.app.novels.is_loading.store(false, .release);
    state.app.novels.fetch_error = false;
    more_available.store(false, .release);
    const cover_url = "https://example.invalid/offline-cover.jpg";
    const author = "Offline fixture author";
    for (textures[0..nr_count], 0..) |art, i| {
        addResult(i, .wikisource, "A long literary title — Journeys through Extraordinary Worlds", "");
        nr_metadata[i] = .{};
        @memcpy(nr_metadata[i].author_buf[0..author.len], author);
        nr_metadata[i].author_len = author.len;
        @memcpy(nr_metadata[i].cover_buf[0..cover_url.len], cover_url);
        nr_metadata[i].cover_len = cover_url.len;
        components.syncCoverSlot(&novel_covers[i], cover_url);
        novel_covers[i].tex = art;
        novel_covers[i].w = art.width;
        novel_covers[i].h = art.height;
        novel_covers[i].attempted = true;
    }
}

const MAX_CHAPTERS: usize = 400;
// For Wikisource: the full page title ("Frankenstein/Chapter 1") — the fetch key
// for action=parse. For the scraper engines: the chapter's display name.
var ch_titles: [MAX_CHAPTERS][256]u8 = undefined;
var ch_title_lens: [MAX_CHAPTERS]usize = std.mem.zeroes([MAX_CHAPTERS]usize);
// Absolute chapter URL (scraper engines only; empty for Wikisource).
var ch_urls: [MAX_CHAPTERS][1024]u8 = undefined;
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
var search_request: LatestRequest = .{};
var chapters_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var text_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// ── Read-only view of the listings, for remote.zig's /api/novels ──
// The nr_*/ch_* arrays stay private (workers rewrite them in place under
// parse_mutex). These copy out under the SAME mutex, so a connection thread can
// never read a row mid-rewrite. Copy semantics, not slices: the caller is on
// another thread and holds nothing once the lock drops.

pub const NovelMetadata = struct {
    author_buf: [256]u8 = std.mem.zeroes([256]u8),
    author_len: usize = 0,
    overview_buf: [768]u8 = std.mem.zeroes([768]u8),
    overview_len: usize = 0,
    cover_buf: [768]u8 = std.mem.zeroes([768]u8),
    cover_len: usize = 0,
    year: u16 = 0,
    pub fn author(self: *const NovelMetadata) []const u8 {
        return self.author_buf[0..self.author_len];
    }
    pub fn overview(self: *const NovelMetadata) []const u8 {
        return self.overview_buf[0..self.overview_len];
    }
    pub fn cover(self: *const NovelMetadata) []const u8 {
        return self.cover_buf[0..self.cover_len];
    }
};

pub const ListRow = struct {
    title_buf: [256]u8 = std.mem.zeroes([256]u8),
    title_len: usize = 0,
    url_buf: [1024]u8 = std.mem.zeroes([1024]u8),
    url_len: usize = 0,
    source: u8 = 0,
    metadata: NovelMetadata = .{},

    pub fn title(self: *const ListRow) []const u8 {
        return self.title_buf[0..@min(self.title_len, self.title_buf.len)];
    }
    pub fn url(self: *const ListRow) []const u8 {
        return self.url_buf[0..@min(self.url_len, self.url_buf.len)];
    }
};

/// A complete API read, copied under the publication mutex. Allocate this on
/// the heap: text plus catalog/chapter rows exceed a connection-thread stack.
pub const ReaderSnapshot = struct {
    view: @TypeOf(state.app.novels.view),
    loading: bool,
    chapters_loading: bool,
    text_loading: bool,
    fetch_error: bool,
    current_chapter: usize,
    text_truncated: bool,
    work_title: [256]u8,
    work_title_len: usize,
    chapter_label: [256]u8,
    chapter_label_len: usize,
    text_buf: [TEXT_CAP]u8,
    text_len: usize,
    results: [MAX_RESULTS]ListRow,
    result_count: usize,
    chapter_titles: [MAX_CHAPTERS][256]u8,
    chapter_title_lens: [MAX_CHAPTERS]usize,
    chapter_count: usize,
    has_more: bool,
    loading_more: bool,
    search_generation: u32,
    chapter_generation: u32,
    text_generation: u32,
};

pub fn copyReaderSnapshot(out: *ReaderSnapshot) void {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    @memset(std.mem.asBytes(out), 0);
    const n = &state.app.novels;
    out.view = n.view;
    out.loading = n.is_loading.load(.acquire);
    out.chapters_loading = n.chapters_loading.load(.acquire);
    out.text_loading = n.text_loading.load(.acquire);
    out.fetch_error = n.fetch_error;
    out.current_chapter = n.current_chapter;
    out.text_truncated = n.text_truncated;
    out.work_title_len = @min(n.work_title_len, out.work_title.len);
    @memcpy(out.work_title[0..out.work_title_len], n.work_title[0..out.work_title_len]);
    out.chapter_label_len = @min(n.chapter_label_len, out.chapter_label.len);
    @memcpy(out.chapter_label[0..out.chapter_label_len], n.chapter_label[0..out.chapter_label_len]);
    out.text_len = @min(n.text_len, out.text_buf.len);
    @memcpy(out.text_buf[0..out.text_len], n.text_buf[0..out.text_len]);
    out.result_count = @min(nr_count, MAX_RESULTS);
    for (0..out.result_count) |idx| {
        const row = &out.results[idx];
        row.title_len = @min(nr_title_lens[idx], row.title_buf.len);
        @memcpy(row.title_buf[0..row.title_len], nr_titles[idx][0..row.title_len]);
        row.url_len = @min(nr_url_lens[idx], row.url_buf.len);
        @memcpy(row.url_buf[0..row.url_len], nr_urls[idx][0..row.url_len]);
        row.source = @intFromEnum(nr_source[idx]);
        row.metadata = nr_metadata[idx];
    }
    out.chapter_count = @min(ch_count, MAX_CHAPTERS);
    for (0..out.chapter_count) |idx| {
        out.chapter_title_lens[idx] = @min(ch_title_lens[idx], out.chapter_titles[idx].len);
        @memcpy(out.chapter_titles[idx][0..out.chapter_title_lens[idx]], ch_titles[idx][0..out.chapter_title_lens[idx]]);
    }
    out.has_more = out.result_count > 0 and more_available.load(.acquire);
    out.loading_more = loading_more.load(.acquire);
    out.search_generation = search_request.current();
    out.chapter_generation = chapters_gen.load(.acquire);
    out.text_generation = text_gen.load(.acquire);
}

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
    out.metadata = nr_metadata[i];
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
// so every flag is atomic (CLAUDE.md). The worker runs under the same `search_request`
// as the initial search, so a fresh query supersedes an in-flight append.
var current_page: u32 = 1;
var more_available: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var loading_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var wiki_next_offset: u32 = 0; // protected by parse_mutex; API cursor, never deduplicated row count
var wiki_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var madara_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var lnwp_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var gutenberg_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var openlibrary_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var gutenberg_next: u32 = 1; // authoritative provider cursor, parse_mutex
var archive_more: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
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
var chapter_url_snap: [1024]u8 = undefined;
var chapter_url_snap_len: usize = 0;

const ReaderJob = struct {
    generation: u32,
    source: NovelSource,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    url: [1024]u8 = undefined,
    url_len: usize = 0,
};

fn readerJob(generation: u32, title: []const u8, url: []const u8) ReaderJob {
    var job: ReaderJob = .{ .generation = generation, .source = open_source };
    job.title_len = @min(title.len, job.title.len);
    job.url_len = @min(url.len, job.url.len);
    @memcpy(job.title[0..job.title_len], title[0..job.title_len]);
    @memcpy(job.url[0..job.url_len], url[0..job.url_len]);
    return job;
}

const SearchJob = struct {
    generation: u32,
    query: [256]u8 = undefined,
    query_len: usize = 0,
};

// Reader text framing cap — matches state.app.novels.text_buf. Anything longer
// is truncated and flagged (text_truncated) so the UI can say so.
const TEXT_CAP: usize = 131072;

// ══════════════════════════════════════════════════════════
// Search
// ══════════════════════════════════════════════════════════

pub fn searchNovels(query: []const u8) void {
    if (query.len == 0 or query.len >= query_snap.len) return;

    const my_gen = search_request.begin(&state.app.novels.is_loading);
    const n = @min(query.len, query_snap.len);
    parse_mutex.lock();
    state.app.novels.fetch_error = false;
    state.app.novels.view = .search;
    @memcpy(query_snap[0..n], query[0..n]);
    query_snap_len = n;
    wiki_next_offset = 0;
    gutenberg_next = 1;
    parse_mutex.unlock();
    var job: SearchJob = .{ .generation = my_gen, .query_len = n };
    @memcpy(job.query[0..n], query[0..n]);

    // Fresh query resets infinite-scroll pagination: page 1, every source eligible.
    current_page = 1;
    more_available.store(true, .release);
    wiki_more.store(true, .release);
    madara_more.store(true, .release);
    lnwp_more.store(true, .release);
    archive_more.store(true, .release);
    gutenberg_more.store(true, .release);
    openlibrary_more.store(true, .release);

    if (@import("../core/workers.zig").spawnLegacy(searchWorker, .{job})) |t| {
        @import("../core/workers.zig").release(t);
    } else |_| {
        search_request.finish(my_gen, &state.app.novels.is_loading);
    }
}

/// Query every ACTIVE source and concatenate their rows. Wikisource first (the
/// always-on legal default), then each scraper engine that a plugin has supplied
/// a base for. Mirrors comics.zig's searchWorker aggregation.
fn searchWorker(job: SearchJob) void {
    const my_gen = job.generation;
    defer search_request.finish(my_gen, &state.app.novels.is_loading);
    const query = job.query[0..job.query_len];

    parse_mutex.lock();
    if (!search_request.isCurrent(my_gen)) {
        parse_mutex.unlock();
        return;
    }
    nr_count = 0;
    parse_mutex.unlock();

    var filled: usize = 0;
    filled += fetchWikisource(query, my_gen, filled, 0);
    if (!search_request.isCurrent(my_gen)) return;

    filled += fetchGutenberg(query, my_gen, filled, 1);
    if (!search_request.isCurrent(my_gen)) return;
    filled += fetchOpenLibrary(query, my_gen, filled, 1);
    if (!search_request.isCurrent(my_gen)) return;

    // A second legal, zero-configuration source. Reuse the same Internet
    // Archive parser and rate-limit bucket as universal search; only items with
    // a readable full-text derivative are returned by the Archive query.
    filled += fetchInternetArchive(query, my_gen, filled, 1);
    if (!search_request.isCurrent(my_gen)) return;

    inline for (.{ NovelSource.royalroad, NovelSource.novelfire }) |src| {
        filled += fetchExpandedNovel(query, my_gen, filled, 1, src);
        if (!search_request.isCurrent(my_gen)) return;
    }
    inline for (.{ NovelSource.standardebooks, NovelSource.wuxiaclick }) |src| {
        filled += fetchReadingProvider(query, my_gen, filled, 1, src);
        if (!search_request.isCurrent(my_gen)) return;
    }

    if (madaraNovelBase() != null) {
        filled += fetchMadaraNovel(query, my_gen, filled, 1);
        if (!search_request.isCurrent(my_gen)) return;
    }
    if (lightnovelwpBase() != null) {
        filled += fetchLightnovelwp(query, my_gen, filled, 1);
        if (!search_request.isCurrent(my_gen)) return;
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
    nr_metadata[idx] = .{};
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

fn fetchExpandedNovel(query: []const u8, gen: u32, start: usize, page: u32, src: NovelSource) usize {
    const id = @tagName(src);
    var base_buf: [512]u8 = undefined;
    const base = copyBase(source_config.get(id, "base") orelse return 0, &base_buf);
    var url_buf: [1600]u8 = undefined;
    const url = expanded.novelSearchUrl(&url_buf, base, id, query, page) orelse return 0;
    const body = scrapeHtml(url, 2 * 1024 * 1024) orelse return 0;
    defer alloc.free(body);
    if (!search_request.isCurrent(gen)) return 0;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!search_request.isCurrent(gen)) return 0;
    const listing = expanded.novelListingHtml(body, id) orelse return 0;
    var it = expanded.html.AnchorIter{ .html = listing, .path = if (src == .royalroad) "/fiction/" else "/book/" };
    var n: usize = 0;
    while (it.next()) |item| {
        if (start + n >= MAX_RESULTS) break;
        if (std.mem.indexOf(u8, item.url, "/chapter") != null or std.mem.endsWith(u8, item.url, "/random")) continue;
        var abs_buf: [1024]u8 = undefined;
        const abs = expanded.html.sourceUrl(&abs_buf, base, item.url) orelse continue;
        var title_buf: [256]u8 = undefined;
        const title = cleanTitle(item.title, &title_buf);
        if (title.len == 0) continue;
        if (rowExists(src, title, abs, start + n)) {
            // Image and title anchors for the same work are often separate.
            // Merge a real cover from either anchor before discarding the link.
            for (0..start + n) |existing| {
                if (std.mem.eql(u8, nr_urls[existing][0..nr_url_lens[existing]], abs)) {
                    setNovelCover(&nr_metadata[existing], base, item.cover);
                    break;
                }
            }
            continue;
        }
        addResult(start + n, src, title, abs);
        setNovelCover(&nr_metadata[start + n], base, item.cover);
        n += 1;
    }
    nr_count = start + n;
    return n;
}

fn fetchReadingProvider(query: []const u8, gen: u32, start: usize, page: u32, src: NovelSource) usize {
    var base_buf: [512]u8 = undefined;
    const base = source_config.copyValue(@tagName(src), "base", &base_buf) orelse return 0;
    const provider: reading_provider.Source = if (src == .standardebooks) .standardebooks else .wuxiaclick;
    var url_buf: [1600]u8 = undefined;
    const url = reading_provider.searchUrl(&url_buf, base, provider, query, page) orelse return 0;
    const body = scrapeHtml(url, 2 * 1024 * 1024) orelse return 0;
    defer alloc.free(body);
    const items = alloc.alloc(reading_provider.Item, 12) catch return 0;
    defer alloc.free(items);
    const parsed = reading_provider.parseInto(body, base, provider, items);
    if (!parsed.valid_listing or !search_request.isCurrent(gen)) return 0;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!search_request.isCurrent(gen)) return 0;
    var n: usize = 0;
    for (items[0..parsed.count]) |*item| {
        if (start + n >= MAX_RESULTS) break;
        const title = item.title[0..item.title_len];
        const work = item.url[0..item.url_len];
        if (work.len > nr_urls[0].len or rowExists(src, title, work, start + n)) continue;
        addResult(start + n, src, title, work);
        const meta = &nr_metadata[start + n];
        @memcpy(meta.author_buf[0..item.author_len], item.author[0..item.author_len]);
        meta.author_len = item.author_len;
        @memcpy(meta.overview_buf[0..item.synopsis_len], item.synopsis[0..item.synopsis_len]);
        meta.overview_len = item.synopsis_len;
        setNovelCover(meta, base, item.cover[0..item.cover_len]);
        n += 1;
    }
    nr_count = start + n;
    return n;
}

fn setNovelCover(meta: *NovelMetadata, base: []const u8, raw: []const u8) void {
    if (meta.cover_len > 0 or raw.len == 0 or std.mem.indexOfAny(u8, raw, "\r\n") != null) return;
    // Providers use external image CDNs. Only permit network schemes; ordinary
    // relative image links still resolve against the installed source base.
    const cover = if (std.mem.startsWith(u8, raw, "https://") or std.mem.startsWith(u8, raw, "http://"))
        std.fmt.bufPrint(&meta.cover_buf, "{s}", .{raw}) catch return
    else if (std.mem.startsWith(u8, raw, "//"))
        std.fmt.bufPrint(&meta.cover_buf, "https:{s}", .{raw}) catch return
    else
        expanded.html.sourceUrl(&meta.cover_buf, base, raw) orelse return;
    meta.cover_len = cover.len;
}

/// Wikisource `list=search` → nr_* rows (the always-on default source). `offset`
/// is the `sroffset` continuation (0 for the first page); rows are appended at
/// `start` and deduped by title so infinite-scroll pages never repeat a work.
fn fetchWikisource(query: []const u8, my_gen: u32, start: usize, offset: u32) usize {
    var url_buf: [1024]u8 = undefined;
    const url = pure.buildSearchUrl(&url_buf, query, PAGE_SIZE, offset) orelse return 0;
    const body = fetchBody(url, 512 * 1024) orelse {
        if (search_request.isCurrent(my_gen)) state.app.novels.fetch_error = true;
        return 0;
    };
    defer alloc.free(body);
    if (search_request.current() != my_gen) return 0;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_request.current() != my_gen) return 0;

    const arr = pure.searchArray(body) orelse {
        state.app.novels.fetch_error = true;
        return 0;
    };
    const next_offset = pure.searchContinuation(body);
    wiki_next_offset = next_offset orelse offset;
    wiki_more.store(next_offset != null and wiki_next_offset > offset, .release);
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
        if (pure.cj.findJsonStr(obj, "\"snippet\":\"")) |snippet| {
            var snippet_buf: [2048]u8 = undefined;
            const decoded = pure.cj.jsonUnescape(snippet, &snippet_buf);
            const meta = &nr_metadata[start + n];
            meta.overview_len = pure.htmlToText(snippet_buf[0..decoded], &meta.overview_buf);
        }
        n += 1;
    }
    nr_count = start + n;
    return n;
}

/// Internet Archive public-domain/CC texts. The listing is cheap and paged;
/// opening a row resolves its actual `_djvu.txt` (or plain `.txt`) derivative
/// from metadata instead of guessing a file name.
fn fetchInternetArchive(query: []const u8, my_gen: u32, start: usize, page: u32) usize {
    var q_raw: [512]u8 = undefined;
    const q = std.fmt.bufPrint(&q_raw, "title:({s}) AND mediatype:(texts) AND language:(eng) AND format:(DjVuTXT)", .{query}) catch return 0;
    var q_enc_buf: [1024]u8 = undefined;
    const encoded = @import("../core/http.zig").urlEncode(q, &q_enc_buf);
    var url_buf: [1400]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://archive.org/advancedsearch.php?q={s}&fl[]=identifier&fl[]=title&fl[]=year&fl[]=creator&fl[]=description&rows={d}&page={d}&output=json",
        .{ encoded, PAGE_SIZE, page },
    ) catch return 0;
    @import("../core/rate_limit.zig").acquire("archive", 1.0);
    const body = fetchBody(url, 512 * 1024) orelse return 0;
    defer alloc.free(body);
    if (!search_request.isCurrent(my_gen)) return 0;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!search_request.isCurrent(my_gen)) return 0;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const response = parsed.value.object.get("response") orelse return 0;
    if (response != .object) return 0;
    const docs = response.object.get("docs") orelse return 0;
    if (docs != .array) return 0;
    var n: usize = 0;
    for (docs.array.items) |doc| {
        if (start + n >= MAX_RESULTS) break;
        if (doc != .object) continue;
        const id = metadataString(doc.object.get("identifier"));
        if (id.len == 0 or id.len > nr_urls[0].len) continue;
        const raw_title = metadataString(doc.object.get("title"));
        const title = if (raw_title.len > 0) raw_title else id;
        if (rowExists(.internet_archive, title, id, start + n)) continue;
        addResult(start + n, .internet_archive, title, id);
        const meta = &nr_metadata[start + n];
        const author = metadataString(doc.object.get("creator"));
        meta.author_len = pure.htmlToText(author, &meta.author_buf);
        meta.overview_len = pure.htmlToText(metadataString(doc.object.get("description")), &meta.overview_buf);
        const year_value = doc.object.get("year");
        if (year_value) |value| {
            if (value == .integer and value.integer > 0 and value.integer <= 9999) meta.year = @intCast(value.integer) else if (value == .string) meta.year = std.fmt.parseInt(u16, value.string, 10) catch 0;
        }
        var encoded_id: [1536]u8 = undefined;
        const encoded_len = pure.cj.percentEncodeStrict(id, &encoded_id);
        const cover = std.fmt.bufPrint(&meta.cover_buf, "https://archive.org/services/img/{s}", .{encoded_id[0..encoded_len]}) catch "";
        meta.cover_len = cover.len;
        n += 1;
    }
    nr_count = start + n;
    return n;
}

/// Archive fields can be scalar strings or arrays of contributor/description
/// values. Preserve the first actual value; absent fields stay absent.
fn metadataString(value: ?std.json.Value) []const u8 {
    const v = value orelse return "";
    if (v == .string) return v.string;
    if (v == .array) for (v.array.items) |entry| {
        if (entry == .string and entry.string.len > 0) return entry.string;
    };
    return "";
}

fn fetchGutenberg(query: []const u8, gen: u32, start: usize, cursor: u32) usize {
    var url_buf: [2048]u8 = undefined;
    const url = books.gutenbergSearch(&url_buf, query, cursor) orelse return 0;
    @import("../core/rate_limit.zig").acquire("gutenberg", 1.0);
    const body = fetchBody(url, 1024 * 1024) orelse return 0;
    defer alloc.free(body);
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!search_request.isCurrent(gen)) return 0;
    const next = books.gutenbergNext(body);
    gutenberg_more.store(next != null and next.? > cursor, .release);
    gutenberg_next = next orelse cursor;
    var it = books.GutenbergIter{ .body = body };
    var n: usize = 0;
    while (it.next()) |item| {
        if (start + n >= MAX_RESULTS) break;
        var title_buf: [256]u8 = undefined;
        const title = cleanTitle(item.title, &title_buf);
        if (title.len == 0 or rowExists(.gutenberg, title, item.id, start + n)) continue;
        addResult(start + n, .gutenberg, title, item.id);
        const meta = &nr_metadata[start + n];
        meta.author_len = pure.htmlToText(item.author, &meta.author_buf);
        setNovelCover(meta, "https://www.gutenberg.org", item.cover);
        n += 1;
    }
    nr_count = start + n;
    return n;
}

fn fetchOpenLibrary(query: []const u8, gen: u32, start: usize, page: u32) usize {
    var url_buf: [2048]u8 = undefined;
    const url = books.openLibrarySearch(&url_buf, query, page) orelse return 0;
    @import("../core/rate_limit.zig").acquire("openlibrary", 1.0);
    const body = fetchBody(url, 1024 * 1024) orelse return 0;
    defer alloc.free(body);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const docs = parsed.value.object.get("docs") orelse return 0;
    if (docs != .array) return 0;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (!search_request.isCurrent(gen)) return 0;
    const total = parsed.value.object.get("numFound");
    const has_more = if (total != null and total.? == .integer) total.?.integer > @as(i64, page) * 20 else docs.array.items.len == 20;
    openlibrary_more.store(has_more, .release);
    var n: usize = 0;
    for (docs.array.items) |doc| {
        if (start + n >= MAX_RESULTS) break;
        const item = books.openLibraryItem(doc) orelse continue;
        if (rowExists(.openlibrary, item.title, item.id, start + n)) continue;
        addResult(start + n, .openlibrary, item.title, item.id);
        const meta = &nr_metadata[start + n];
        meta.author_len = pure.htmlToText(item.author, &meta.author_buf);
        meta.year = item.year;
        if (books.openLibraryCover(&meta.cover_buf, item.cover_id)) |cover| meta.cover_len = cover.len;
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
    if (search_request.current() != my_gen) return 0;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_request.current() != my_gen) return 0;

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
    if (search_request.current() != my_gen) return 0;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_request.current() != my_gen) return 0;

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
    if (search_request.current() != my_gen) return 0;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_request.current() != my_gen) return 0;

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
/// single scroll can't spawn a burst. Runs under the current `search_request`, so a
/// fresh query supersedes it. Wikisource continues by `sroffset`; the scraper
/// engines by page number (`current_page + 1`); readwn's search can't page and is
/// never re-fetched here.
pub fn hasMoreResults() bool {
    return more_available.load(.acquire);
}
pub fn loadingMoreResults() bool {
    return loading_more.load(.acquire);
}

/// Return through retained reader/catalog snapshots instead of re-opening a
/// stale search row or issuing an empty search after a universal-search open.
pub fn back() void {
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (state.app.novels.view == .reader) {
        _ = text_gen.fetchAdd(1, .acq_rel);
        state.app.novels.text_loading.store(false, .release);
        state.app.novels.view = .chapters;
    } else {
        _ = chapters_gen.fetchAdd(1, .acq_rel);
        state.app.novels.chapters_loading.store(false, .release);
        state.app.novels.view = .search;
    }
}

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
    const my_gen = search_request.current();
    const next = current_page + 1;
    var job: SearchJob = .{ .generation = my_gen };
    parse_mutex.lock();
    job.query_len = @min(query_snap_len, job.query.len);
    @memcpy(job.query[0..job.query_len], query_snap[0..job.query_len]);
    parse_mutex.unlock();
    if (@import("../core/workers.zig").spawnLegacy(loadMoreWorker, .{ job, next })) |t| {
        @import("../core/workers.zig").release(t);
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
fn loadMoreWorker(job: SearchJob, next_page: u32) void {
    const my_gen = job.generation;
    defer loading_more.store(false, .release);
    const query = job.query[0..job.query_len];
    if (query.len == 0) return;

    parse_mutex.lock();
    var start = nr_count;
    parse_mutex.unlock();

    if (wiki_more.load(.acquire)) {
        parse_mutex.lock();
        const offset = wiki_next_offset;
        parse_mutex.unlock();
        const n = fetchWikisource(query, my_gen, start, offset);
        if (search_request.current() != my_gen) return;
        start += n;
        // The server continuation determines exhaustion, even if this page
        // contains only duplicate or unsupported rows.

    }
    if (gutenberg_more.load(.acquire) and start < MAX_RESULTS) {
        parse_mutex.lock();
        const cursor = gutenberg_next;
        parse_mutex.unlock();
        const n = fetchGutenberg(query, my_gen, start, cursor);
        if (!search_request.isCurrent(my_gen)) return;
        start += n;
    }
    if (openlibrary_more.load(.acquire) and start < MAX_RESULTS) {
        const n = fetchOpenLibrary(query, my_gen, start, next_page);
        if (!search_request.isCurrent(my_gen)) return;
        start += n;
    }
    if (archive_more.load(.acquire) and start < MAX_RESULTS) {
        const n = fetchInternetArchive(query, my_gen, start, next_page);
        if (search_request.current() != my_gen) return;
        start += n;
        if (n == 0) archive_more.store(false, .release);
    }
    var expanded_more = false;
    inline for (.{ NovelSource.royalroad, NovelSource.novelfire }) |src| {
        const n = fetchExpandedNovel(query, my_gen, start, next_page, src);
        if (!search_request.isCurrent(my_gen)) return;
        start += n;
        expanded_more = expanded_more or n > 0;
    }
    inline for (.{ NovelSource.standardebooks, NovelSource.wuxiaclick }) |src| {
        const n = fetchReadingProvider(query, my_gen, start, next_page, src);
        if (!search_request.isCurrent(my_gen)) return;
        start += n;
        expanded_more = expanded_more or n > 0;
    }
    if (madara_more.load(.acquire) and madaraNovelBase() != null and start < MAX_RESULTS) {
        const n = fetchMadaraNovel(query, my_gen, start, next_page);
        if (search_request.current() != my_gen) return;
        start += n;
        if (n == 0) madara_more.store(false, .release);
    }
    if (lnwp_more.load(.acquire) and lightnovelwpBase() != null and start < MAX_RESULTS) {
        const n = fetchLightnovelwp(query, my_gen, start, next_page);
        if (search_request.current() != my_gen) return;
        start += n;
        if (n == 0) lnwp_more.store(false, .release);
    }

    const any = expanded_more or wiki_more.load(.acquire) or archive_more.load(.acquire) or
        gutenberg_more.load(.acquire) or openlibrary_more.load(.acquire) or
        (madara_more.load(.acquire) and madaraNovelBase() != null) or
        (lnwp_more.load(.acquire) and lightnovelwpBase() != null);
    more_available.store(any and start < MAX_RESULTS, .release);
    logs.pushLog("info", "novels", "Novel search page appended", false);
}

// ══════════════════════════════════════════════════════════
// Open a novel → fetch its chapter list
// ══════════════════════════════════════════════════════════

pub fn openNovel(idx: usize) void {
    const row = resultRow(idx) orelse return;
    parse_mutex.lock();
    const my_gen = chapters_gen.fetchAdd(1, .acq_rel) + 1;

    // Snapshot the selected work (source + title + URL) BEFORE spawning — the
    // search grid can be reordered by a fresh search while chapters load.
    open_source = @enumFromInt(row.source);

    const tlen = @min(row.title_len, state.app.novels.work_title.len);
    @memcpy(state.app.novels.work_title[0..tlen], row.title_buf[0..tlen]);
    state.app.novels.work_title_len = tlen;
    @memcpy(work_snap[0..tlen], row.title_buf[0..tlen]);
    work_snap_len = tlen;

    const ulen = @min(row.url_len, work_url_snap.len);
    @memcpy(work_url_snap[0..ulen], row.url_buf[0..ulen]);
    work_url_snap_len = ulen;

    _ = text_gen.fetchAdd(1, .acq_rel);
    state.app.novels.text_loading.store(false, .release);
    state.app.novels.view = .chapters;
    state.app.novels.chapters_loading.store(true, .release);
    state.app.novels.fetch_error = false;

    ch_count = 0;

    const job = readerJob(my_gen, work_snap[0..work_snap_len], work_url_snap[0..work_url_snap_len]);
    parse_mutex.unlock();
    if (@import("../core/workers.zig").spawnLegacy(chaptersWorker, .{job})) |t| {
        @import("../core/workers.zig").release(t);
    } else |_| {
        state.app.novels.chapters_loading.store(false, .release);
    }
}

/// Dispatch the chapter-list fetch to the open novel's engine.
fn chaptersWorker(job: ReaderJob) void {
    const my_gen = job.generation;
    defer {
        parse_mutex.lock();
        if (chapters_gen.load(.acquire) == my_gen) state.app.novels.chapters_loading.store(false, .release);
        parse_mutex.unlock();
    }
    if (chapters_gen.load(.acquire) != my_gen) return;
    switch (job.source) {
        .wikisource => chaptersWikisource(job),
        .madara_novel => chaptersMadara(job),
        .lightnovelwp => chaptersLightnovelwp(job),
        .readwn => chaptersReadwn(job),
        .readnovelfull => {}, // not shipped in v1
        .internet_archive, .openlibrary => chaptersInternetArchive(job),
        .gutenberg => chaptersGutenberg(job),
        .royalroad, .novelfire => chaptersExpanded(job),
        .standardebooks, .wuxiaclick => chaptersReadingProvider(job),
    }
    parse_mutex.lock();
    const capped = chapters_gen.load(.acquire) == my_gen and ch_count >= MAX_CHAPTERS;
    parse_mutex.unlock();
    if (capped) logs.pushLog("warn", "novels", "Chapter list reached the 400-chapter reader limit", false);
}

fn chaptersReadingProvider(job: ReaderJob) void {
    var base_buf: [512]u8 = undefined;
    const base = source_config.copyValue(@tagName(job.source), "base", &base_buf) orelse return;
    const provider: reading_provider.Source = if (job.source == .standardebooks) .standardebooks else .wuxiaclick;
    const work = job.url[0..job.url_len];
    var url_buf: [1600]u8 = undefined;
    const url = reading_provider.chapterListUrl(&url_buf, base, provider, work) orelse return;
    const body = scrapeHtml(url, 4 * 1024 * 1024) orelse return;
    defer alloc.free(body);
    const rows = alloc.alloc(reading_provider.Chapter, MAX_CHAPTERS) catch return;
    defer alloc.free(rows);
    const n = reading_provider.chaptersInto(body, base, provider, work, rows);
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (chapters_gen.load(.acquire) != job.generation) return;
    for (rows[0..n], 0..) |*row, i| addChapter(i, row.title[0..row.title_len], row.url[0..row.url_len]);
    ch_count = n;
    if (n == 0) state.app.novels.fetch_error = true;
}

fn chaptersExpanded(job: ReaderJob) void {
    const gen = job.generation;
    const src = job.source;
    var base_buf: [512]u8 = undefined;
    const base = copyBase(source_config.get(@tagName(src), "base") orelse return, &base_buf);
    var work_buf: [1024]u8 = undefined;
    const work = copyBase(job.url[0..job.url_len], &work_buf);
    var n: usize = 0;
    // NovelFire paginates its chapter directory; Royal Road returns it whole.
    var page: usize = 1;
    while (page <= 16 and n < MAX_CHAPTERS) : (page += 1) {
        var url_buf: [1200]u8 = undefined;
        const url = if (src == .royalroad) work else std.fmt.bufPrint(&url_buf, "{s}/chapters?page={d}", .{ std.mem.trimEnd(u8, work, "/"), page }) catch return;
        const body = scrapeHtml(url, 4 * 1024 * 1024) orelse return;
        defer alloc.free(body);
        if (chapters_gen.load(.acquire) != gen) return;
        const before = n;
        const chapter_html = expanded.chapterListingHtml(body, @tagName(src)) orelse return;
        var it = expanded.html.AnchorIter{ .html = chapter_html, .path = if (src == .royalroad) "/chapter/" else "/chapter-" };
        parse_mutex.lock();
        while (it.next()) |item| {
            if (n >= MAX_CHAPTERS or chapters_gen.load(.acquire) != gen) break;
            var abs_buf: [1024]u8 = undefined;
            const abs = expanded.html.sourceUrl(&abs_buf, base, item.url) orelse continue;
            var duplicate = false;
            for (0..n) |i| {
                if (std.mem.eql(u8, abs, ch_urls[i][0..ch_url_lens[i]])) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            var title_buf: [256]u8 = undefined;
            const title = cleanTitle(item.title, &title_buf);
            if (title.len == 0) continue;
            addChapter(n, title, abs);
            n += 1;
        }
        if (chapters_gen.load(.acquire) == gen) ch_count = n;
        parse_mutex.unlock();
        if (src == .royalroad or before == n) break;
        var next_buf: [40]u8 = undefined;
        const next = std.fmt.bufPrint(&next_buf, "page={d}", .{page + 1}) catch break;
        if (std.mem.indexOf(u8, body, next) == null) break;
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
        std.mem.swap([1024]u8, &ch_urls[i], &ch_urls[j]);
        std.mem.swap(usize, &ch_url_lens[i], &ch_url_lens[j]);
    }
}

/// Wikisource: `list=allpages` subpages. When a work has none (single-page work),
/// synthesize one chapter = the work page so the reader still opens.
fn chaptersWikisource(job: ReaderJob) void {
    const my_gen = job.generation;
    var work: [256]u8 = undefined;
    const wlen = @min(job.title_len, work.len);
    @memcpy(work[0..wlen], job.title[0..wlen]);

    var url_buf: [1024]u8 = undefined;
    const url = pure.buildSubpagesUrl(&url_buf, work[0..wlen], MAX_CHAPTERS) orelse return;

    const body = fetchBody(url, 512 * 1024) orelse {
        if (chapters_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
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
fn chaptersMadara(job: ReaderJob) void {
    const my_gen = job.generation;
    const base_raw = madaraNovelBase() orelse return;
    var base_buf: [256]u8 = undefined;
    const base = copyBase(base_raw, &base_buf);

    var murl_buf: [512]u8 = undefined;
    const mn = @min(job.url_len, murl_buf.len);
    @memcpy(murl_buf[0..mn], job.url[0..mn]);
    const murl = murl_buf[0..mn];
    if (murl.len == 0) return;

    const body = scrapeHtml(murl, 1024 * 1024) orelse {
        if (chapters_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
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
fn chaptersLightnovelwp(job: ReaderJob) void {
    const my_gen = job.generation;
    const base_raw = lightnovelwpBase() orelse return;
    var base_buf: [256]u8 = undefined;
    const base = copyBase(base_raw, &base_buf);

    var murl_buf: [512]u8 = undefined;
    const mn = @min(job.url_len, murl_buf.len);
    @memcpy(murl_buf[0..mn], job.url[0..mn]);
    const murl = murl_buf[0..mn];
    if (murl.len == 0) return;

    const body = scrapeHtml(murl, 1024 * 1024) orelse {
        if (chapters_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
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
fn chaptersReadwn(job: ReaderJob) void {
    const my_gen = job.generation;
    const base_raw = readwnBase() orelse return;
    var base_buf: [256]u8 = undefined;
    const base = copyBase(base_raw, &base_buf);

    var murl_buf: [512]u8 = undefined;
    const mn = @min(job.url_len, murl_buf.len);
    @memcpy(murl_buf[0..mn], job.url[0..mn]);
    const murl = murl_buf[0..mn];
    if (murl.len == 0) return;

    const body = scrapeHtml(murl, 1024 * 1024) orelse {
        if (chapters_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
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

fn chaptersGutenberg(job: ReaderJob) void {
    var url_buf: [512]u8 = undefined;
    const url = books.gutenbergDetail(&url_buf, job.url[0..job.url_len]) orelse return;
    @import("../core/rate_limit.zig").acquire("gutenberg", 1.0);
    const body = fetchBody(url, 1024 * 1024) orelse return;
    defer alloc.free(body);
    if (chapters_gen.load(.acquire) != job.generation) return;
    var text_url_buf: [1024]u8 = undefined;
    const text_url = books.gutenbergTextUrl(&text_url_buf, body) orelse return;
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (chapters_gen.load(.acquire) != job.generation) return;
    addChapter(0, "Full text", text_url);
    ch_count = 1;
    logs.pushLog("info", "novels", "Gutenberg advertised UTF-8 text resolved", false);
}

/// Internet Archive: resolve one real readable file from item metadata and
/// expose it as a single "Full text" chapter. This keeps the existing reader,
/// resume, and deep-link paths shared with every other novel source.
fn chaptersInternetArchive(job: ReaderJob) void {
    const my_gen = job.generation;
    var id_buf: [512]u8 = undefined;
    const id_len = @min(job.url_len, id_buf.len);
    @memcpy(id_buf[0..id_len], job.url[0..id_len]);
    if (id_len == 0) return;

    var enc_id_buf: [1536]u8 = undefined;
    const enc_id_len = archive.encodePathSegment(id_buf[0..id_len], &enc_id_buf);
    var meta_url_buf: [1700]u8 = undefined;
    const meta_url = std.fmt.bufPrint(&meta_url_buf, "https://archive.org/metadata/{s}", .{enc_id_buf[0..enc_id_len]}) catch return;
    @import("../core/rate_limit.zig").acquire("archive", 1.0);
    const metadata = fetchBody(meta_url, 2 * 1024 * 1024) orelse {
        if (chapters_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(metadata);
    if (chapters_gen.load(.acquire) != my_gen) return;

    const parsed_metadata = std.json.parseFromSlice(std.json.Value, alloc, metadata, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed_metadata.deinit();
    const raw_file = books.publicArchiveText(parsed_metadata.value) orelse {
        if (chapters_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
        logs.pushLog("info", "novels", "Archive item has no readable text file", false);
        return;
    };
    var file_buf: [512]u8 = undefined;
    const file_len = @min(raw_file.len, file_buf.len);
    @memcpy(file_buf[0..file_len], raw_file[0..file_len]);
    if (file_len == 0) return;
    var enc_file_buf: [1536]u8 = undefined;
    const enc_file_len = archive.encodePathSegment(file_buf[0..file_len], &enc_file_buf);
    var direct_buf: [1024]u8 = undefined;
    const direct = std.fmt.bufPrint(
        &direct_buf,
        "https://archive.org/download/{s}/{s}",
        .{ enc_id_buf[0..enc_id_len], enc_file_buf[0..enc_file_len] },
    ) catch return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (chapters_gen.load(.acquire) != my_gen) return;
    addChapter(0, "Full text", direct);
    ch_count = 1;
    logs.pushLog("info", "novels", "Novel full text resolved (Internet Archive)", false);
}

// ══════════════════════════════════════════════════════════
// Open a chapter → fetch + extract its text
// ══════════════════════════════════════════════════════════

pub fn openChapter(idx: usize) void {
    const row = chapterRow(idx) orelse return;
    parse_mutex.lock();
    const my_gen = text_gen.fetchAdd(1, .acq_rel) + 1;

    state.app.novels.current_chapter = idx;
    state.app.novels.view = .reader;
    state.app.novels.text_loading.store(true, .release);
    state.app.novels.text_len = 0;
    state.app.novels.text_truncated = false;
    state.app.novels.fetch_error = false;

    // Snapshot the chapter's page title (Wikisource key) + absolute URL (scraper
    // engines) + display label BEFORE spawning.
    const flen = @min(row.title_len, chapter_snap.len);
    @memcpy(chapter_snap[0..flen], row.title_buf[0..flen]);
    chapter_snap_len = flen;

    const culen = @min(row.url_len, chapter_url_snap.len);
    @memcpy(chapter_url_snap[0..culen], row.url_buf[0..culen]);
    chapter_url_snap_len = culen;

    const label = pure.chapterLabel(row.title());
    const llen = @min(label.len, state.app.novels.chapter_label.len);
    @memcpy(state.app.novels.chapter_label[0..llen], label[0..llen]);
    state.app.novels.chapter_label_len = llen;

    // Persist resume: this is now the last-read chapter for this work.
    saveResume(idx);

    const job = readerJob(my_gen, chapter_snap[0..chapter_snap_len], chapter_url_snap[0..chapter_url_snap_len]);
    parse_mutex.unlock();
    if (@import("../core/workers.zig").spawnLegacy(textWorker, .{job})) |t| {
        @import("../core/workers.zig").release(t);
    } else |_| {
        state.app.novels.text_loading.store(false, .release);
    }
}

/// Next / previous chapter, clamped. No-ops past the ends.
pub fn nextChapter() void {
    const cur = state.app.novels.current_chapter;
    if (cur + 1 < chapterCount()) openChapter(cur + 1);
}
pub fn prevChapter() void {
    const cur = state.app.novels.current_chapter;
    if (cur > 0) openChapter(cur - 1);
}

/// Dispatch the chapter-text fetch to the open novel's engine.
fn textWorker(job: ReaderJob) void {
    const my_gen = job.generation;
    defer {
        parse_mutex.lock();
        if (text_gen.load(.acquire) == my_gen) state.app.novels.text_loading.store(false, .release);
        parse_mutex.unlock();
    }
    if (text_gen.load(.acquire) != my_gen) return;
    if (job.source == .wikisource) {
        textWikisource(job);
    } else if (job.source == .internet_archive or job.source == .openlibrary) {
        textInternetArchive(job);
    } else if (job.source == .gutenberg) {
        textGutenberg(job);
    } else if (job.source == .standardebooks or job.source == .wuxiaclick) {
        textReadingProvider(job);
    } else {
        textSourced(job);
    }
}

fn textReadingProvider(job: ReaderJob) void {
    const body = scrapeHtml(job.url[0..job.url_len], 2 * 1024 * 1024) orelse {
        parse_mutex.lock();
        defer parse_mutex.unlock();
        if (text_gen.load(.acquire) == job.generation) state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (text_gen.load(.acquire) != job.generation) return;
    const source: reading_provider.Source = if (job.source == .standardebooks) .standardebooks else .wuxiaclick;
    const n = reading_provider.chapterText(body, source, state.app.novels.text_buf[0..TEXT_CAP]);
    state.app.novels.text_len = n;
    state.app.novels.text_truncated = n >= TEXT_CAP;
    state.app.novels.fetch_error = n == 0;
}

/// Wikisource: `action=parse&prop=text` → JSON `parse.text` HTML → reading text.
fn textWikisource(job: ReaderJob) void {
    const my_gen = job.generation;
    var page: [256]u8 = undefined;
    const plen = @min(job.title_len, page.len);
    @memcpy(page[0..plen], job.title[0..plen]);

    var url_buf: [1024]u8 = undefined;
    const url = pure.buildChapterUrl(&url_buf, page[0..plen]) orelse return;

    const body = fetchBody(url, 2 * 1024 * 1024) orelse {
        if (text_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (text_gen.load(.acquire) != my_gen) return;

    // Two-stage, both heap/state (never a big buffer on the worker stack):
    //   JSON parse.text → HTML (heap) → clean reading text (state.text_buf).
    const html = alloc.alloc(u8, 2 * 1024 * 1024) catch {
        if (text_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(html);
    const html_len = pure.extractParseHtml(body, html);
    if (html_len == 0) {
        if (text_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
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

/// Internet Archive's selected derivative is already plain text. Run it
/// through the common whitespace/entity normalizer so OCR reads like the other
/// sources and remains bounded by the same fixed reader buffer.
fn textInternetArchive(job: ReaderJob) void {
    const my_gen = job.generation;
    var url_buf: [1024]u8 = undefined;
    const url_len = @min(job.url_len, url_buf.len);
    @memcpy(url_buf[0..url_len], job.url[0..url_len]);
    const url = url_buf[0..url_len];
    if (url.len == 0 or !std.mem.startsWith(u8, url, "https://archive.org/download/")) {
        if (text_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
        return;
    }
    @import("../core/rate_limit.zig").acquire("archive", 1.0);
    const body = fetchBody(url, 2 * 1024 * 1024) orelse {
        if (text_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (text_gen.load(.acquire) != my_gen) return;

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (text_gen.load(.acquire) != my_gen) return;
    const n = pure.htmlToText(body, state.app.novels.text_buf[0..TEXT_CAP]);
    state.app.novels.text_len = n;
    state.app.novels.text_truncated = n >= TEXT_CAP;
    if (n == 0 and text_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
    logs.pushLog("info", "novels", "Novel full text loaded (Internet Archive)", false);
}

fn textGutenberg(job: ReaderJob) void {
    const url = job.url[0..job.url_len];
    if (!std.mem.startsWith(u8, url, "https://www.gutenberg.org/")) return;
    @import("../core/rate_limit.zig").acquire("gutenberg", 1.0);
    const body = fetchBody(url, 4 * 1024 * 1024) orelse return;
    defer alloc.free(body);
    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (text_gen.load(.acquire) != job.generation) return;
    // A plain-text book is not HTML: preserve comparison signs, indentation
    // and paragraph breaks rather than stripping text between '<' and '>'.
    const text = books.plainTextPrefix(body, TEXT_CAP);
    @memcpy(state.app.novels.text_buf[0..text.len], text);
    state.app.novels.text_len = text.len;
    state.app.novels.text_truncated = body.len > TEXT_CAP;
    if (text.len == 0) state.app.novels.fetch_error = true;
}

/// Scraper engines: GET the chapter URL, extract the source's prose container
/// (via novel_sources_pure), then HTML→clean text. The container selector is the
/// ONLY per-engine difference; everything else is the shared reader pipeline.
fn textSourced(job: ReaderJob) void {
    const my_gen = job.generation;
    var url_buf: [1024]u8 = undefined;
    const un = @min(job.url_len, url_buf.len);
    @memcpy(url_buf[0..un], job.url[0..un]);
    const chapter_url = url_buf[0..un];
    if (chapter_url.len == 0 or !std.mem.startsWith(u8, chapter_url, "http")) {
        if (text_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
        return;
    }

    const body = scrapeHtml(chapter_url, 2 * 1024 * 1024) orelse {
        if (text_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);
    if (text_gen.load(.acquire) != my_gen) return;

    const content = nsp.chapterContentHtml(body, job.source) orelse {
        if (text_gen.load(.acquire) == my_gen) state.app.novels.fetch_error = true;
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

// openChapter holds parse_mutex for the work identity and chapter count.
// Reacquiring it here would deadlock before any prose worker can start.
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
    const total = ch_count;
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
    openCatalogResult(@intFromEnum(src), parsed.title, parsed.url);
}

/// Open an immutable universal-search identity without touching the browse
/// query/results or relying on their mutable row indices. Owner-thread only.
pub fn openCatalogResult(source: u8, title: []const u8, url: []const u8) void {
    const src = std.enums.fromInt(NovelSource, source) orelse return;
    if (title.len == 0 or title.len > work_snap.len or url.len > work_url_snap.len) return;
    parse_mutex.lock();
    const my_gen = chapters_gen.fetchAdd(1, .acq_rel) + 1;
    open_source = src;

    const tlen = @min(title.len, state.app.novels.work_title.len);
    @memcpy(state.app.novels.work_title[0..tlen], title[0..tlen]);
    state.app.novels.work_title_len = tlen;
    @memcpy(work_snap[0..tlen], title[0..tlen]);
    work_snap_len = tlen;

    const ulen = @min(url.len, work_url_snap.len);
    @memcpy(work_url_snap[0..ulen], url[0..ulen]);
    work_url_snap_len = ulen;

    _ = text_gen.fetchAdd(1, .acq_rel);
    state.app.novels.text_loading.store(false, .release);
    state.app.novels.view = .chapters;
    state.app.novels.chapters_loading.store(true, .release);
    state.app.novels.fetch_error = false;

    ch_count = 0;

    state.app.browse_source = .Novels;
    state.app.router.navigate(.browse);

    const job = readerJob(my_gen, work_snap[0..work_snap_len], work_url_snap[0..work_url_snap_len]);
    parse_mutex.unlock();
    if (@import("../core/workers.zig").spawnLegacy(chaptersWorker, .{job})) |t| {
        @import("../core/workers.zig").release(t);
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

/// Fetch a JSON/API response through the shared bounded transport.
fn fetchBody(url: []const u8, cap: usize) ?[]u8 {
    const buf = alloc.alloc(u8, cap) catch return null;
    const body = reliable_fetch.fetch(url, buf, .{
        .user_agent = agent,
        .timeout_secs = 20,
        .impersonate = false,
    }) orelse {
        alloc.free(buf);
        return null;
    };
    return alloc.realloc(buf, body.len) catch {
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
/// chapter lists need both). Same heap-buffer discipline as `fetchBody`.
fn curlPost(url: []const u8, body: []const u8, referer: []const u8, cap: usize) ?[]u8 {
    const buf = alloc.alloc(u8, cap) catch return null;
    const response = reliable_fetch.fetch(url, buf, .{
        .user_agent = agent,
        .referer = referer,
        .timeout_secs = 20,
        .post_body = body,
    }) orelse {
        alloc.free(buf);
        return null;
    };
    return alloc.realloc(buf, response.len) catch {
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

    const count = resultCount();

    if (count == 0) {
        if (state.app.novels.is_loading.load(.acquire)) {
            components.loadingState("Searching Wikisource and Internet Archive…");
        } else {
            components.emptyState(
                icons.tvg.lucide.@"book-open",
                "Find your next book",
                "Search public-domain books across multiple libraries.",
            );
        }
        return;
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = theme.colors.bg_surface,
    });
    defer scroll.deinit();

    _ = dvui.label(@src(), "{d} results", .{count}, .{
        .color_text = theme.colors.text_secondary,
        .padding = .{ .x = 12, .y = 8, .w = 8, .h = 4 },
    });

    const layout_w = @import("../core/scale_pure.zig").layoutUnits(dvui.windowRect().w, state.app.ui_scale);
    const viewport_width = if (scroll.data().rect.w > 1) scroll.data().rect.w else layout_w;
    const grid = @import("../ui/browse_layout_pure.zig").readingGrid(viewport_width);
    const cols = grid.columns;
    const rows = (count + cols - 1) / cols;
    const row_h: f32 = 126;
    const win = tmdb_pure.visibleRows(rows, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 2);
    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49998,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) },
        });
        sp.deinit();
    }

    var row_idx: usize = win.first;
    while (row_idx < win.last) : (row_idx += 1) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 51000 + row_idx,
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = row_h },
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = row_h },
            .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
        });
        defer row.deinit();

        for (0..cols) |col| {
            const i = row_idx * cols + col;
            if (i >= count) break;
            const item = resultRow(i) orelse continue;
            renderNovelCard(item, i, grid.card_width);
        }
    }

    if (win.last < rows) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(rows - win.last)) },
        });
        sp.deinit();
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
            state.wakeUi(); // wake until the appended rows land
        }
    }
}

fn renderSearchBar() void {
    if (!@import("../ui/browse_layout_pure.zig").showLocalSearch(state.app.page_shell_enabled)) return;
    var row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
        .expand = .horizontal,
        .padding = .{ .x = 10, .y = 7, .w = 10, .h = 7 },
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

    const layout_w = @import("../core/scale_pure.zig").layoutUnits(dvui.windowRect().w, state.app.ui_scale);
    const search_w = @max(150, @min(280, layout_w - 280));
    const entered = components.toolbarSearch(@src(), &state.app.novels.search_buf, "Search novels…", search_w);
    const go = components.toolbarGo(@src(), "Search");

    if (entered or go) {
        const q = std.mem.sliceTo(&state.app.novels.search_buf, 0);
        if (q.len > 0) searchNovels(q);
    }

    if (state.app.novels.is_loading.load(.acquire)) {
        dvui.spinner(@src(), .{
            .color_text = theme.colors.accent,
            .min_size_content = theme.iconSize(.md),
            .gravity_y = 0.5,
            .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
        });
    }
}

fn novelSourceLabel(source: NovelSource) []const u8 {
    return switch (source) {
        .wikisource => "Wikisource",
        .internet_archive => "Internet Archive",
        .gutenberg => "Project Gutenberg",
        .openlibrary => "Open Library",
        .royalroad => "Royal Road",
        .novelfire => "NovelFire",
        .standardebooks => "Standard Ebooks",
        .wuxiaclick => "WuxiaClick",
        else => "Connected source",
    };
}

fn novelSourceIcon(source: NovelSource) []const u8 {
    return switch (source) {
        .wikisource => icons.tvg.lucide.@"book-open",
        .internet_archive => icons.tvg.lucide.archive,
        else => icons.tvg.lucide.globe,
    };
}

fn renderNovelCard(item: ListRow, index: usize, card_width: f32) void {
    var name_buf: [256]u8 = undefined;
    const name = safeUtf8Buf(item.title(), &name_buf);
    const source: NovelSource = @enumFromInt(item.source);

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = 52000 + index,
        .min_size_content = .{ .w = card_width, .h = 112 },
        .max_size_content = .{ .w = card_width, .h = 112 },
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .color_fill_hover = theme.colors.bg_hover,
        .corner_radius = theme.dims.rad_md,
        .margin = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    bw.processEvents();
    bw.drawBackground();
    if (@import("builtin").is_test) native_card_rects[index] = bw.data().borderRectScale().r;

    {
        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 53000 + index,
            .expand = .both,
            .max_size_content = .{ .w = 0, .h = 112 },
            .padding = .{ .x = 0, .y = 0, .w = 10, .h = 0 },
        });
        defer body.deinit();

        {
            var spine = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = 54000 + index,
                .min_size_content = .{ .w = 76, .h = 112 },
                .max_size_content = .{ .w = 76, .h = 112 },
                .background = true,
                .color_fill = theme.colors.accent.lerp(theme.colors.bg_surface, 0.35),
                .corner_radius = .{ .x = theme.radius.md, .y = theme.radius.md, .w = 0, .h = 0 },
            });
            defer spine.deinit();
            components.coverArt(@src(), 54500 + index, &novel_covers[index], item.metadata.cover(), novelSourceIcon(source), theme.radius.md);
        }

        {
            var text = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = 55000 + index,
                .expand = .both,
                .max_size_content = .{ .w = 0, .h = 94 },
                .padding = .{ .x = 10, .y = 10, .w = 4, .h = 8 },
            });
            defer text.deinit();
            _ = dvui.label(@src(), "{s}", .{name}, .{
                .id_extra = 56000 + index,
                .expand = .horizontal,
                .color_text = theme.colors.text_primary,
                .font = theme.mediaTitleFont(name, dvui.themeGet().font_body),
            });
            if (item.metadata.author_len > 0 or item.metadata.overview_len > 0) {
                var subtitle_buf: [256]u8 = undefined;
                const subtitle = if (item.metadata.author_len > 0)
                    safeUtf8(item.metadata.author())
                else
                    safeUtf8(item.metadata.overview()[0..@min(item.metadata.overview_len, 100)]);
                const subtitle_text = if (item.metadata.year > 0)
                    std.fmt.bufPrint(&subtitle_buf, "{s} · {d}", .{ subtitle, item.metadata.year }) catch subtitle
                else
                    subtitle;
                _ = dvui.label(@src(), "{s}", .{subtitle_text}, .{
                    .id_extra = 56500 + index,
                    .expand = .horizontal,
                    .color_text = theme.colors.text_secondary,
                });
            }
            {
                var spacer = dvui.box(@src(), .{}, .{ .id_extra = 57000 + index, .expand = .vertical });
                spacer.deinit();
            }
            _ = dvui.label(@src(), "{s}", .{novelSourceLabel(source)}, .{
                .id_extra = 58000 + index,
                .color_text = theme.colors.accent,
            });
        }
    }

    const clicked = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    if (clicked) openNovel(index);
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

    const count = chapterCount();

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

    const row_h: f32 = 40;
    const win = tmdb_pure.visibleRows(count, row_h, scroll.si.viewport.y, scroll.si.viewport.h, 4);
    if (win.first > 0) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49998,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(win.first)) },
        });
        sp.deinit();
    }

    var i: usize = win.first;
    while (i < win.last) : (i += 1) {
        const item = chapterRow(i) orelse continue;
        const label = pure.chapterLabel(item.title());
        var lbl_buf: [256]u8 = undefined;
        const safe = safeUtf8Buf(label, &lbl_buf);
        if (dvui.button(@src(), safe, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 20 },
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = 20 },
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

    if (win.last < count) {
        var sp = dvui.box(@src(), .{}, .{
            .id_extra = 49999,
            .min_size_content = .{ .w = 1, .h = row_h * @as(f32, @floatFromInt(count - win.last)) },
        });
        sp.deinit();
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

        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.list, .{}, .{}, .{
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
            .color_text = if (state.app.novels.current_chapter + 1 < chapterCount()) theme.colors.text_primary else theme.colors.text_tertiary,
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
        state.wakeUi();
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
