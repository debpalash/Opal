//! Pure (io-free, state-free) parsing for the light-novel **source engines** —
//! unit-testable via `zig build test`.
//!
//! The novel reader (`novels.zig` + `novels_pure.zig`) started Wikisource-only.
//! This module adds base-URL-driven source engines the same way the comics module
//! grew Madara / MangaThemesia — each source is INERT until `source_config`
//! supplies its `base`; nothing infringing is hardcoded.
//!
//! The KEY REUSE insight: the novel Madara / lightnovelwp templates render the
//! SAME DOM as the manga Madara / MangaThemesia engines — the ONLY difference is
//! the chapter body is prose TEXT, not page images. So the search grid, details
//! and chapter-list parsing are REUSED wholesale from `manga_madara_pure` /
//! `manga_themesia_pure` (re-exported below); the only NEW logic per source is the
//! chapter-CONTENT container extraction. `readwn` (NovelUpdates-style) is a small
//! standalone parser added here.
//!
//! `novels.zig` routes production through this module so the tested logic IS the
//! shipped logic (no drift). Everything is fixed-buffer / no-allocation.

const std = @import("std");

/// Shared HTML/JSON/encoding primitives (percentEncodeQuery, findJsonNode, …).
pub const cpure = @import("comics_pure.zig");
/// REUSED wholesale for madara-novel search / details / chapter-list + AJAX.
pub const madara = @import("manga_madara_pure.zig");
/// REUSED wholesale for lightnovelwp browse / details / chapter-list.
pub const themesia = @import("manga_themesia_pure.zig");

/// Which engine a novel came from — carried per search-result so `openNovel` /
/// `openChapter` dispatch to the right chapter-list + chapter-text extractor.
pub const NovelSource = enum { wikisource, madara_novel, lightnovelwp, readwn, readnovelfull };

// ══════════════════════════════════════════════════════════
// Chapter-TEXT container selectors (the ONE new thing per shared engine)
// ══════════════════════════════════════════════════════════

/// Madara-novel prose container, in fallback order. `.text-left` is the modern
/// theme's container; the rest are older / alternate skins.
pub const MADARA_CONTENT = [_][]const u8{ "text-left", "text-right", "entry-content", "reading-content" };
/// lightnovelwp (MangaThemesia's novel sibling) prose container.
pub const LIGHTNOVELWP_CONTENT = "epcontent";
/// readwn prose container.
pub const READWN_CONTENT = "chapter-content";
/// readnovelfull prose container, in fallback order.
pub const READNOVELFULL_CONTENT = [_][]const u8{ "chr-content", "chapter-content" };

// ══════════════════════════════════════════════════════════
// Minimal HTML scanning primitives (local — small, keeps this module standalone)
// ══════════════════════════════════════════════════════════

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn trimSlash(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

/// True when `html[pos..]` starts with tag name `name` at a boundary (next char is
/// whitespace, `>` or `/`). Used to depth-match container open/close tags.
fn matchName(html: []const u8, pos: usize, name: []const u8) bool {
    if (pos + name.len > html.len) return false;
    if (!std.ascii.eqlIgnoreCase(html[pos .. pos + name.len], name)) return false;
    if (pos + name.len == html.len) return true;
    const after = html[pos + name.len];
    return isWs(after) or after == '>' or after == '/';
}

/// Value of attribute `name` (e.g. "href=") in `scope`, quote-aware and matched
/// only at an attribute boundary (so `src=` never latches onto `data-src=`).
fn attrVal(scope: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, scope, from, name)) |at| {
        from = at + name.len;
        if (at > 0) {
            const prev = scope[at - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '-' or prev == '_') continue;
        }
        var p = at + name.len;
        while (p < scope.len and (scope[p] == ' ' or scope[p] == '=')) p += 1;
        if (p >= scope.len) return null;
        const q = scope[p];
        if (q != '"' and q != '\'') return null;
        p += 1;
        const end = std.mem.indexOfScalarPos(u8, scope, p, q) orelse return null;
        return scope[p..end];
    }
    return null;
}

/// First non-empty text run after a `>` (skipping empty gaps between nested
/// opening tags), starting the scan at `open`. Trimmed. "" when none.
fn innerText(scope: []const u8, open: usize) []const u8 {
    var p = open;
    while (std.mem.indexOfScalarPos(u8, scope, p, '>')) |gt| {
        const lt = std.mem.indexOfScalarPos(u8, scope, gt + 1, '<') orelse scope.len;
        const t = std.mem.trim(u8, scope[gt + 1 .. lt], " \t\r\n");
        if (t.len > 0) return t;
        if (lt >= scope.len) break;
        p = lt + 1;
    }
    return "";
}

/// The element block for `marker`, from its opening `<` to just before the NEXT
/// element carrying the same marker (or end of HTML) — same "needle + next needle
/// bound" scheme comics/madara use so blocks never bleed together.
fn classBlock(html: []const u8, from: usize, marker: []const u8) ?struct { block: []const u8, next: usize } {
    const at = std.mem.indexOfPos(u8, html, from, marker) orelse return null;
    const open = std.mem.lastIndexOfScalar(u8, html[0..at], '<') orelse return null;
    const after = at + marker.len;
    const next_rel = std.mem.indexOfPos(u8, html, after, marker);
    const block_end = if (next_rel) |nr| (std.mem.lastIndexOfScalar(u8, html[0..nr], '<') orelse html.len) else html.len;
    return .{ .block = html[open..block_end], .next = block_end };
}

// ══════════════════════════════════════════════════════════
// Container extraction — the prose element's INNER html (depth-matched)
// ══════════════════════════════════════════════════════════

/// Inner HTML of the element that carries `marker` (a class/id substring), found
/// by depth-matching its own tag so nested `<div>`s inside the prose don't cut it
/// short. Returns the slice between the element's `>` and its matching close, or
/// null when `marker` is absent. An unterminated element returns to end-of-html
/// (never crashes). Feed the result to `novels_pure.htmlToText`.
pub fn containerInner(html: []const u8, marker: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, html, marker) orelse return null;
    const open = std.mem.lastIndexOfScalar(u8, html[0..at], '<') orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, html, open, '>') orelse return null;

    // Tag name: skip an optional '/', then read to whitespace / '/' / '>'.
    var ns = open + 1;
    if (ns < html.len and html[ns] == '/') ns += 1;
    const name_start = ns;
    while (ns < gt and !isWs(html[ns]) and html[ns] != '/' and html[ns] != '>') ns += 1;
    const name = html[name_start..ns];
    if (name.len == 0) return null;

    const inner_start = gt + 1;
    var depth: usize = 1;
    var i = inner_start;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        if (lt + 1 < html.len and html[lt + 1] == '/') {
            if (matchName(html, lt + 2, name)) {
                depth -= 1;
                if (depth == 0) return html[inner_start..lt];
            }
        } else if (matchName(html, lt + 1, name)) {
            depth += 1;
        }
        i = lt + 1;
    }
    return html[inner_start..]; // unterminated → best effort, no crash
}

/// True when `html` contains at least one visible (non-whitespace) character that
/// is NOT inside a tag — i.e. real prose, not an empty container.
pub fn htmlHasText(html: []const u8) bool {
    var i: usize = 0;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            i = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse return false) + 1;
            continue;
        }
        if (c == '&') return true; // an entity is visible text
        if (!isWs(c)) return true;
        i += 1;
    }
    return false;
}

/// The chapter-text container's inner HTML for `source`, applying that engine's
/// selector (with fallbacks). Null when none match / no prose. `novels.zig` then
/// runs it through `novels_pure.htmlToText`.
pub fn chapterContentHtml(html: []const u8, source: NovelSource) ?[]const u8 {
    switch (source) {
        .madara_novel => {
            for (MADARA_CONTENT) |sel| {
                if (containerInner(html, sel)) |c| if (htmlHasText(c)) return c;
            }
            return null;
        },
        .lightnovelwp => {
            if (containerInner(html, LIGHTNOVELWP_CONTENT)) |c| if (htmlHasText(c)) return c;
            return null;
        },
        .readwn => {
            if (containerInner(html, READWN_CONTENT)) |c| if (htmlHasText(c)) return c;
            return null;
        },
        .readnovelfull => {
            for (READNOVELFULL_CONTENT) |sel| {
                if (containerInner(html, sel)) |c| if (htmlHasText(c)) return c;
            }
            return null;
        },
        .wikisource => return null, // handled by novels_pure.extractParseHtml
    }
}

// ══════════════════════════════════════════════════════════
// readwn (NovelUpdates-style) — standalone engine
// ══════════════════════════════════════════════════════════

/// LATEST/browse listing URL: `{base}/list/all/all-newstime-{page-1}.html`
/// (page is 1-based; the site's path is 0-based, so page 1 → `-0`).
pub fn readwnBrowseUrl(out: []u8, base: []const u8, page: u32) ?[]const u8 {
    const b = trimSlash(base);
    if (b.len == 0) return null;
    const p: u32 = if (page == 0) 0 else page - 1;
    return std.fmt.bufPrint(out, "{s}/list/all/all-newstime-{d}.html", .{ b, p }) catch null;
}

/// SEARCH endpoint (POST): `{base}/e/search/index.php`.
pub fn readwnSearchUrl(out: []u8, base: []const u8) ?[]const u8 {
    const b = trimSlash(base);
    if (b.len == 0) return null;
    return std.fmt.bufPrint(out, "{s}/e/search/index.php", .{b}) catch null;
}

/// SEARCH form body: `show=title&tempid=1&tbname=news&keyboard={query}`. The query
/// is form-encoded (space → `+`) so a crafted term can't smuggle an extra field.
pub fn readwnSearchBody(out: []u8, query: []const u8) ?[]const u8 {
    if (query.len == 0) return null;
    var enc: [512]u8 = undefined;
    const n = cpure.percentEncodeQuery(query, &enc);
    if (n == 0) return null;
    return std.fmt.bufPrint(out, "show=title&tempid=1&tbname=news&keyboard={s}", .{enc[0..n]}) catch null;
}

/// SEARCH Referer header value the site expects: `{base}/search.html`.
pub fn readwnReferer(out: []u8, base: []const u8) []const u8 {
    const b = trimSlash(base);
    return std.fmt.bufPrint(out, "{s}/search.html", .{b}) catch b;
}

pub const NovelItem = struct {
    /// Display title (still HTML-escaped; decode at the call site).
    title: []const u8,
    /// Raw novel-detail href — resolve with `themesia.resolveUrl`.
    url: []const u8,
    /// Raw cover url (data-src → src) — resolve before use ("" if none).
    cover: []const u8 = "",
};

/// Iterate a readwn listing / search response: each result is a `li.novel-item`
/// carrying `a[href]`, `h4.novel-title` (title) and `.novel-cover img[data-src]`.
pub const ReadwnIter = struct {
    html: []const u8,
    pos: usize = 0,

    pub fn next(self: *ReadwnIter) ?NovelItem {
        while (classBlock(self.html, self.pos, "novel-item")) |blk| {
            self.pos = blk.next;
            const a = std.mem.indexOf(u8, blk.block, "<a") orelse continue;
            const url = attrVal(blk.block[a..], "href=") orelse continue;
            if (url.len == 0) continue;

            var title: []const u8 = "";
            if (std.mem.indexOf(u8, blk.block, "novel-title")) |nt| {
                title = innerText(blk.block, nt);
            }
            if (title.len == 0) title = attrVal(blk.block[a..], "title=") orelse "";

            var cover: []const u8 = "";
            if (std.mem.indexOf(u8, blk.block, "<img")) |im| {
                const gt = std.mem.indexOfScalarPos(u8, blk.block, im, '>') orelse blk.block.len;
                const tag = blk.block[im..@min(gt + 1, blk.block.len)];
                cover = attrVal(tag, "data-src=") orelse attrVal(tag, "src=") orelse "";
            }
            return .{ .title = title, .url = url, .cover = cover };
        }
        return null;
    }
};

pub const ReadwnDetails = struct {
    title: []const u8 = "",
    author: []const u8 = "",
    summary: []const u8 = "",
};

/// Parse a readwn novel-detail page: `h1.novel-title`, `span[itemprop=author]`,
/// and the `.summary` blurb (first prose run).
pub fn readwnDetails(html: []const u8) ReadwnDetails {
    var d = ReadwnDetails{};
    if (std.mem.indexOf(u8, html, "novel-title")) |nt| {
        const t = innerText(html, nt);
        if (t.len > 0) d.title = t;
    }
    if (std.mem.indexOf(u8, html, "itemprop=\"author\"")) |au| {
        const t = innerText(html, au);
        if (t.len > 0) d.author = t;
    }
    if (std.mem.indexOf(u8, html, "class=\"summary\"")) |su| {
        const t = innerText(html, su);
        if (t.len > 0) d.summary = t;
    }
    return d;
}

pub const ReadwnChapter = struct {
    /// Raw chapter href — resolve before use.
    url: []const u8,
    name: []const u8,
    date: []const u8 = "",
};

/// Iterate a readwn `.chapter-list` — each `li > a[href]` with a `.chapter-title`
/// label and a `.chapter-update` date. Document order is oldest→newest (readwn
/// lists chapters ascending), matching the reader's index order.
pub const ReadwnChapterIter = struct {
    html: []const u8,
    pos: usize,
    end: usize,

    pub fn next(self: *ReadwnChapterIter) ?ReadwnChapter {
        while (self.pos < self.end) {
            const a = std.mem.indexOfPos(u8, self.html, self.pos, "<a") orelse return null;
            if (a >= self.end) return null;
            const gt = std.mem.indexOfScalarPos(u8, self.html, a, '>') orelse return null;
            const open_tag = self.html[a .. gt + 1];
            // Bound this anchor's scope at the next <a (or the region end).
            const nxt = std.mem.indexOfPos(u8, self.html, gt + 1, "<a") orelse self.end;
            const scope_end = @min(nxt, self.end);
            const row = self.html[a..scope_end];
            self.pos = scope_end;

            const url = attrVal(open_tag, "href=") orelse continue;
            if (url.len == 0) continue;

            var name: []const u8 = "";
            if (std.mem.indexOf(u8, row, "chapter-title")) |ct| {
                name = innerText(row, ct);
            }
            if (name.len == 0) name = attrVal(open_tag, "title=") orelse innerText(row, 0);

            var date: []const u8 = "";
            if (std.mem.indexOf(u8, row, "chapter-update")) |cu| date = innerText(row, cu);
            return .{ .url = url, .name = name, .date = date };
        }
        return null;
    }
};

/// Build a `ReadwnChapterIter` bounded to the `.chapter-list` region.
pub fn readwnChapters(html: []const u8) ReadwnChapterIter {
    const start = std.mem.indexOf(u8, html, "chapter-list") orelse 0;
    const end = std.mem.indexOfPos(u8, html, start, "</ul>") orelse html.len;
    return .{ .html = html, .pos = start, .end = end };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "containerInner: depth-matches nested divs of the same tag" {
    const html = "<div class=\"text-left\"><p>Line one.</p><div class=\"ad\">x</div><p>Line two.</p></div><footer>end</footer>";
    const inner = containerInner(html, "text-left").?;
    try std.testing.expectEqualStrings("<p>Line one.</p><div class=\"ad\">x</div><p>Line two.</p>", inner);
}

test "containerInner: absent marker → null; unterminated → best effort" {
    try std.testing.expect(containerInner("<div>no marker</div>", "text-left") == null);
    const inner = containerInner("<div class=\"epcontent\"><p>tail", "epcontent").?;
    try std.testing.expectEqualStrings("<p>tail", inner);
}

test "htmlHasText: prose vs empty container" {
    try std.testing.expect(htmlHasText("<p>hello</p>"));
    try std.testing.expect(htmlHasText("<p>&amp;</p>"));
    try std.testing.expect(!htmlHasText("<p></p>   \n"));
    try std.testing.expect(!htmlHasText("<div><span></span></div>"));
}

test "chapterContentHtml: madara .text-left, fallback to entry-content" {
    const primary = "<div class=\"reading-content\"><div class=\"text-left\"><p>Chapter body.</p></div></div>";
    try std.testing.expectEqualStrings("<p>Chapter body.</p>", chapterContentHtml(primary, .madara_novel).?);
    // No .text-left / .text-right → entry-content wins.
    const fallback = "<div class=\"entry-content\"><p>Alt body.</p></div>";
    try std.testing.expectEqualStrings("<p>Alt body.</p>", chapterContentHtml(fallback, .madara_novel).?);
}

test "chapterContentHtml: lightnovelwp epcontent + readwn chapter-content" {
    const ln = "<article><div class=\"epcontent entry-content\"><p>Prose.</p></div></article>";
    try std.testing.expectEqualStrings("<p>Prose.</p>", chapterContentHtml(ln, .lightnovelwp).?);
    const rw = "<div class=\"chapter-content\"><p>Story text.</p></div>";
    try std.testing.expectEqualStrings("<p>Story text.</p>", chapterContentHtml(rw, .readwn).?);
    // readnovelfull #chr-content (id).
    const rnf = "<div id=\"chr-content\"><p>RNF body.</p></div>";
    try std.testing.expectEqualStrings("<p>RNF body.</p>", chapterContentHtml(rnf, .readnovelfull).?);
    // Wikisource is handled elsewhere → null.
    try std.testing.expect(chapterContentHtml(ln, .wikisource) == null);
}

test "readwn URL builders + search body (form-encoded, injection-inert)" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://rw.test/list/all/all-newstime-0.html",
        readwnBrowseUrl(&buf, "https://rw.test/", 1).?,
    );
    try std.testing.expectEqualStrings(
        "https://rw.test/list/all/all-newstime-2.html",
        readwnBrowseUrl(&buf, "https://rw.test", 3).?,
    );
    var b2: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://rw.test/e/search/index.php", readwnSearchUrl(&b2, "https://rw.test/").?);
    var b3: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "show=title&tempid=1&tbname=news&keyboard=solo+leveling",
        readwnSearchBody(&b3, "solo leveling").?,
    );
    // A crafted query cannot inject an extra field.
    var b4: [256]u8 = undefined;
    const body = readwnSearchBody(&b4, "x&a=1").?;
    try std.testing.expect(std.mem.indexOf(u8, body, "keyboard=x%26a%3D1") != null);
    try std.testing.expect(readwnSearchBody(&b4, "") == null);
    var b5: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://rw.test/search.html", readwnReferer(&b5, "https://rw.test/"));
}

const READWN_LIST =
    \\<ul class="novel-list">
    \\  <li class="novel-item">
    \\    <a href="/novel/sample-one.html" title="Sample One">
    \\      <div class="novel-cover"><img data-src="/cover/one.jpg" src="lazy.png"></div>
    \\      <div class="item-body"><h4 class="novel-title">Sample One</h4></div>
    \\    </a>
    \\  </li>
    \\  <li class="novel-item">
    \\    <a href="/novel/sample-two.html" title="Sample Two">
    \\      <div class="novel-cover"><img data-src="/cover/two.jpg"></div>
    \\      <div class="item-body"><h4 class="novel-title">Sample Two</h4></div>
    \\    </a>
    \\  </li>
    \\</ul>
;

test "ReadwnIter: two results with title, url, cover (data-src)" {
    var it = ReadwnIter{ .html = READWN_LIST };
    const a = it.next().?;
    try std.testing.expectEqualStrings("Sample One", a.title);
    try std.testing.expectEqualStrings("/novel/sample-one.html", a.url);
    try std.testing.expectEqualStrings("/cover/one.jpg", a.cover);
    const b = it.next().?;
    try std.testing.expectEqualStrings("Sample Two", b.title);
    try std.testing.expectEqualStrings("/novel/sample-two.html", b.url);
    try std.testing.expectEqualStrings("/cover/two.jpg", b.cover);
    try std.testing.expect(it.next() == null);
}

const READWN_DETAIL =
    \\<div class="novel-header">
    \\  <h1 class="novel-title">Sample One</h1>
    \\  <span itemprop="author"><a href="/author/x">Author Name</a></span>
    \\  <p class="summary"><div class="content">A great story unfolds.</div></p>
    \\  <div class="categories"><ul><li>Fantasy</li><li>Action</li></ul></div>
    \\</div>
    \\<ul class="chapter-list">
    \\  <li><a href="/novel/sample-one/chapter-1.html"><span class="chapter-title">Chapter 1</span><span class="chapter-update">2 days ago</span></a></li>
    \\  <li><a href="/novel/sample-one/chapter-2.html"><span class="chapter-title">Chapter 2</span><span class="chapter-update">1 day ago</span></a></li>
    \\</ul>
;

test "readwnDetails: title / author / summary" {
    const d = readwnDetails(READWN_DETAIL);
    try std.testing.expectEqualStrings("Sample One", d.title);
    try std.testing.expectEqualStrings("Author Name", d.author);
    try std.testing.expectEqualStrings("A great story unfolds.", d.summary);
}

test "readwnChapters: url / name / date, ascending order" {
    var it = readwnChapters(READWN_DETAIL);
    const c1 = it.next().?;
    try std.testing.expectEqualStrings("/novel/sample-one/chapter-1.html", c1.url);
    try std.testing.expectEqualStrings("Chapter 1", c1.name);
    try std.testing.expectEqualStrings("2 days ago", c1.date);
    const c2 = it.next().?;
    try std.testing.expectEqualStrings("/novel/sample-one/chapter-2.html", c2.url);
    try std.testing.expectEqualStrings("Chapter 2", c2.name);
    try std.testing.expect(it.next() == null);
}

test "reuse: manga_madara_pure + manga_themesia_pure are wired for shared engines" {
    // Madara-novel reuses the manga Madara search/details/chapter parsers verbatim.
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://mn.test/?s=re+zero&post_type=wp-manga",
        madara.buildSearchUrl(&buf, "https://mn.test", "re zero", 1).?,
    );
    // lightnovelwp reuses the MangaThemesia browse endpoint.
    var b2: [256]u8 = undefined;
    const url = themesia.buildBrowseUrl("https://lw.test", "/series", "", 2, "", &b2).?;
    try std.testing.expectEqualStrings("https://lw.test/series/?title=&page=2&order=", url);
}

test "malformed input never crashes (no-panic sweep)" {
    const junk = [_][]const u8{
        "",                                    "<",
        "<div class=\"text-left\"",            "<li class=\"novel-item\"><a href=",
        "<ul class=\"chapter-list\"><li><a",   "<div class=\"epcontent\"><p>",
        "<span itemprop=\"author\">",          "novel-title only",
    };
    for (junk) |h| {
        _ = chapterContentHtml(h, .madara_novel);
        _ = chapterContentHtml(h, .lightnovelwp);
        _ = chapterContentHtml(h, .readwn);
        _ = containerInner(h, "text-left");
        _ = htmlHasText(h);
        _ = readwnDetails(h);
        var it = ReadwnIter{ .html = h };
        while (it.next()) |_| {}
        var cit = readwnChapters(h);
        while (cit.next()) |_| {}
    }
}
