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
const safeUtf8Buf = @import("../core/text.zig").safeUtf8Buf;

const alloc = @import("../core/alloc.zig").allocator;

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
const MAX_RESULTS: usize = 40;
var nr_titles: [MAX_RESULTS][256]u8 = undefined;
var nr_title_lens: [MAX_RESULTS]usize = std.mem.zeroes([MAX_RESULTS]usize);
var nr_count: usize = 0;

const MAX_CHAPTERS: usize = 400;
// Full page title ("Frankenstein/Chapter 1") — the fetch key for action=parse.
var ch_titles: [MAX_CHAPTERS][256]u8 = undefined;
var ch_title_lens: [MAX_CHAPTERS]usize = std.mem.zeroes([MAX_CHAPTERS]usize);
var ch_count: usize = 0;

// ── Thread-safety ──
// Detached workers publish under `parse_mutex`; monotonic generations drop stale
// results so fast re-drills never show out-of-order data (mirrors radio.zig).
var parse_mutex: @import("../core/sync.zig").Mutex = .{};
var search_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var chapters_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var text_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Snapshots handed to detached workers (never read the mutable UI buffers from a
// worker — copy by value before spawning; see CLAUDE.md thread rules).
var query_snap: [256]u8 = undefined;
var query_snap_len: usize = 0;
var work_snap: [256]u8 = undefined;
var work_snap_len: usize = 0;
var chapter_snap: [256]u8 = undefined;
var chapter_snap_len: usize = 0;

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

    if (std.Thread.spawn(.{}, searchWorker, .{my_gen})) |t| {
        t.detach();
    } else |_| {
        state.app.novels.is_loading.store(false, .release);
    }
}

fn searchWorker(my_gen: u32) void {
    defer state.app.novels.is_loading.store(false, .release);

    var local: [256]u8 = undefined;
    const qlen = @min(query_snap_len, local.len);
    @memcpy(local[0..qlen], query_snap[0..qlen]);

    var url_buf: [1024]u8 = undefined;
    const url = pure.buildSearchUrl(&url_buf, local[0..qlen], MAX_RESULTS) orelse return;

    const body = curl(url, 512 * 1024) orelse {
        state.app.novels.fetch_error = true;
        return;
    };
    defer alloc.free(body);

    if (search_gen.load(.acquire) != my_gen) return; // superseded

    parse_mutex.lock();
    defer parse_mutex.unlock();
    if (search_gen.load(.acquire) != my_gen) return; // re-check under lock

    const count = parseSearch(body);
    nr_count = count;
    if (count == 0) {
        logs.pushLog("info", "novels", "Novel search returned no works", false);
    } else {
        logs.pushLog("info", "novels", "Novel search done (Wikisource)", false);
    }
}

/// Fill nr_* from a Wikisource `list=search` response. Returns the row count.
/// Runs under parse_mutex on the search worker.
fn parseSearch(json: []const u8) usize {
    const arr = pure.searchArray(json) orelse return 0;
    var it = pure.cj.ObjIter{ .buf = arr };
    var count: usize = 0;
    while (it.next()) |obj| {
        if (count >= MAX_RESULTS) break;
        const raw = pure.titleField(obj) orelse continue;
        var dec: [256]u8 = undefined;
        const dn = pure.cj.jsonUnescape(raw, &dec);
        if (dn == 0) continue;
        const tlen = @min(dn, nr_titles[count].len);
        @memcpy(nr_titles[count][0..tlen], dec[0..tlen]);
        nr_title_lens[count] = tlen;
        count += 1;
    }
    return count;
}

// ══════════════════════════════════════════════════════════
// Open a novel → fetch its chapter list
// ══════════════════════════════════════════════════════════

pub fn openNovel(idx: usize) void {
    if (idx >= nr_count) return;

    // Snapshot the selected work title into AppState (the reader header + resume
    // key) and into the worker snapshot BEFORE spawning.
    const tlen = @min(nr_title_lens[idx], state.app.novels.work_title.len);
    @memcpy(state.app.novels.work_title[0..tlen], nr_titles[idx][0..tlen]);
    state.app.novels.work_title_len = tlen;
    @memcpy(work_snap[0..tlen], nr_titles[idx][0..tlen]);
    work_snap_len = tlen;

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

fn chaptersWorker(my_gen: u32) void {
    defer state.app.novels.chapters_loading.store(false, .release);

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

    const count = parseChapters(body, work[0..wlen]);
    ch_count = count;
    logs.pushLog("info", "novels", "Novel chapter list loaded (Wikisource)", false);
}

/// Fill ch_* from a `list=allpages` response. When the work has NO subpages
/// (single-page work), synthesize one chapter = the work page itself so the
/// reader still opens. Runs under parse_mutex on the chapters worker.
fn parseChapters(json: []const u8, work_title: []const u8) usize {
    var count: usize = 0;
    if (pure.allpagesArray(json)) |arr| {
        var it = pure.cj.ObjIter{ .buf = arr };
        while (it.next()) |obj| {
            if (count >= MAX_CHAPTERS) break;
            const raw = pure.titleField(obj) orelse continue;
            var dec: [256]u8 = undefined;
            const dn = pure.cj.jsonUnescape(raw, &dec);
            if (dn == 0) continue;
            const clen = @min(dn, ch_titles[count].len);
            @memcpy(ch_titles[count][0..clen], dec[0..clen]);
            ch_title_lens[count] = clen;
            count += 1;
        }
    }
    if (count == 0) {
        // Single-page work: read the work page directly as chapter 0.
        const clen = @min(work_title.len, ch_titles[0].len);
        @memcpy(ch_titles[0][0..clen], work_title[0..clen]);
        ch_title_lens[0] = clen;
        count = 1;
    }
    return count;
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

    // Snapshot the chapter's full page title + display label BEFORE spawning.
    const flen = @min(ch_title_lens[idx], chapter_snap.len);
    @memcpy(chapter_snap[0..flen], ch_titles[idx][0..flen]);
    chapter_snap_len = flen;

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

fn textWorker(my_gen: u32) void {
    defer state.app.novels.text_loading.store(false, .release);

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
