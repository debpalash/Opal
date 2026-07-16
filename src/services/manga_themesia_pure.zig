//! Pure (io-free, state-free) parsing for the **MangaThemesia** manga engine —
//! the generic scraper for the WordPress "Keneisan / WPMangaThemesia" theme that
//! ~143 manga sites share (the second-biggest Mihon/Tachiyomi source family).
//!
//! The production code in `comics.zig` calls into these so the tested logic IS
//! the shipped logic (no drift). Everything here is fixed-buffer / no-allocation,
//! matching the project's `[N]u8 + len` convention. A MangaThemesia site is
//! entirely base-URL-driven (nothing is hardcoded): `comics.zig` reads the base
//! from `source_config.get("mangathemesia", "base")` and the source stays INERT
//! until a plugin supplies it.
//!
//! Covers:
//!   - `buildBrowseUrl` — the ONE endpoint that serves popular / latest / A-Z /
//!     text-search (all differ only by the `order` param)
//!   - the IMAGE-ATTR RULE (`pickImageAttr`): data-src → data-lazy-src → srcset
//!     (highest quality) → src, trimmed, relative→absolute against baseUrl
//!   - search-grid extraction (`SearchIter`: `.listupd .bs .bsx` + `.utao .imgu`)
//!   - details (`parseDetails`: title / thumbnail / description / status)
//!   - chapters (`chapterIter`: `div.bxcl li, #chapterlist li`)
//!   - page images (`parsePages`: PRIMARY `div#readerarea img`, with the
//!     JS-embedded `"images":[ … ]` JSON array as a fallback)
//!
//! Percent-encoding + allocation-free JSON scanning are REUSED from
//! `comics_pure.zig` (no duplication).

const std = @import("std");
const cpure = @import("comics_pure.zig");

pub const DEFAULT_DIR = "/manga";

/// `themesia:` pseudo-URL scheme. A MangaThemesia search-result card can't be
/// read by the generic curl+HTML issue scraper (its pages come from a
/// details→chapters→pages chain), so cards carry `themesia:<manga-detail-url>`
/// and `comics.fetchComicThread` dispatches on the prefix — exactly like the
/// `mangadex:` scheme. Keeps the reader's page pipeline unchanged.
pub const SCHEME = "themesia:";

// ══════════════════════════════════════════════════════════
// URL building
// ══════════════════════════════════════════════════════════

/// Trim a single trailing '/' from a base URL so `{base}{dir}` never doubles it.
fn trimSlash(base: []const u8) []const u8 {
    if (base.len > 0 and base[base.len - 1] == '/') return base[0 .. base.len - 1];
    return base;
}

/// The scheme+host origin of `base` (e.g. `https://site.com/path` → `https://site.com`).
/// Relative `/foo` page/cover URLs resolve against this.
pub fn origin(base: []const u8) []const u8 {
    const sch = std.mem.indexOf(u8, base, "://") orelse return trimSlash(base);
    const host_start = sch + 3;
    const slash = std.mem.indexOfScalarPos(u8, base, host_start, '/') orelse return base;
    return base[0..slash];
}

/// Resolve `url` against `base`: absolute URLs pass through; `//host/…` gains the
/// base scheme; `/path` gains the base origin; anything else is treated as a path
/// relative to the base origin. Writes into `out`, returns the resulting slice
/// (which may alias `url` when it is already absolute).
pub fn resolveUrl(base: []const u8, url: []const u8, out: []u8) []const u8 {
    if (url.len == 0) return url;
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) return url;
    if (std.mem.startsWith(u8, url, "//")) {
        const scheme_end = std.mem.indexOf(u8, base, "://") orelse return url;
        const scheme = base[0..scheme_end];
        return std.fmt.bufPrint(out, "{s}:{s}", .{ scheme, url }) catch url;
    }
    const org = origin(base);
    if (url.len > 0 and url[0] == '/') {
        return std.fmt.bufPrint(out, "{s}{s}", .{ org, url }) catch url;
    }
    return std.fmt.bufPrint(out, "{s}/{s}", .{ org, url }) catch url;
}

/// Build the browse/search URL. Popular, latest, A-Z and text search are ALL this
/// one endpoint, differing only by `order`:
///   `{base}{dir}/?title={query}&page={page}&order={order}`
/// `order` ∈ { "popular", "update", "title", "titlereverse", "latest", "" }.
pub fn buildBrowseUrl(
    base: []const u8,
    dir: []const u8,
    query: []const u8,
    page: u32,
    order: []const u8,
    out: []u8,
) ?[]const u8 {
    if (base.len == 0) return null;
    var enc: [512]u8 = undefined;
    const n = cpure.percentEncodeQuery(query, &enc);
    const d = if (dir.len == 0) DEFAULT_DIR else dir;
    return std.fmt.bufPrint(out, "{s}{s}/?title={s}&page={d}&order={s}", .{
        trimSlash(base), d, enc[0..n], page, order,
    }) catch null;
}

// ══════════════════════════════════════════════════════════
// Minimal HTML scanning (tag / attribute / inner-text)
// ══════════════════════════════════════════════════════════

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// The start-tag slice `<name …>` beginning at the `<` at `lt`, plus the index
/// just past its closing `>`. Quote-aware so a `>` inside an attribute value
/// never ends the tag early.
const Tag = struct { text: []const u8, after: usize };

fn scanStartTag(html: []const u8, lt: usize) ?Tag {
    var i = lt + 1;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (c == '"' or c == '\'') {
            i = std.mem.indexOfScalarPos(u8, html, i + 1, c) orelse return null;
            continue;
        }
        if (c == '>') return .{ .text = html[lt .. i + 1], .after = i + 1 };
    }
    return null;
}

/// Find the next `<name` element start at/after `from` (name boundary enforced so
/// `<a` doesn't match `<article`). Returns the index of its `<`.
fn findElement(html: []const u8, from: usize, name: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        i = lt + 1;
        if (lt + 1 + name.len > html.len) return null;
        if (!std.ascii.eqlIgnoreCase(html[lt + 1 .. lt + 1 + name.len], name)) continue;
        const after = html[lt + 1 + name.len];
        if (isWs(after) or after == '>' or after == '/') return lt;
    }
    return null;
}

/// Read attribute `name`'s value out of a start-tag slice. Handles single- OR
/// double-quoted (and bare) values, and enforces a name boundary so `src` is
/// never read out of `data-src`.
pub fn tagAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, name)) |at| {
        i = at + name.len;
        // Boundary before: the char preceding the name must not be a name char.
        if (at > 0) {
            const p = tag[at - 1];
            if (!(isWs(p) or p == '"' or p == '\'' or p == '<' or p == '/')) continue;
        }
        var p = at + name.len;
        while (p < tag.len and isWs(tag[p])) p += 1;
        if (p >= tag.len or tag[p] != '=') continue;
        p += 1;
        while (p < tag.len and isWs(tag[p])) p += 1;
        if (p >= tag.len) return null;
        const q = tag[p];
        if (q == '"' or q == '\'') {
            p += 1;
            const e = std.mem.indexOfScalarPos(u8, tag, p, q) orelse return null;
            return tag[p..e];
        }
        // Unquoted value: read to the next whitespace or '>'.
        const s = p;
        while (p < tag.len and !isWs(tag[p]) and tag[p] != '>') p += 1;
        return tag[s..p];
    }
    return null;
}

/// Inner text of the first element whose start-tag contains `marker`, searched
/// from `from`: the run of characters after that tag's `>` up to the next `<`.
/// Trimmed. Good enough for the short leaf nodes MangaThemesia uses
/// (`.chapternum`, `.chapterdate`, `h1.entry-title`).
fn innerAfterMarker(html: []const u8, from: usize, marker: []const u8) ?[]const u8 {
    const at = std.mem.indexOfPos(u8, html, from, marker) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, html, at, '>') orelse return null;
    const start = gt + 1;
    const lt = std.mem.indexOfScalarPos(u8, html, start, '<') orelse html.len;
    return std.mem.trim(u8, html[start..lt], " \t\r\n");
}

// ══════════════════════════════════════════════════════════
// IMAGE-ATTR RULE
// ══════════════════════════════════════════════════════════

/// From a `srcset` value (`url1 1x, url2 2x` / `url1 320w, url2 640w`), return the
/// highest-quality URL: the candidate with the largest numeric descriptor, or the
/// last candidate when none carry a descriptor.
pub fn srcsetBest(srcset: []const u8) []const u8 {
    var best: []const u8 = "";
    var best_w: i64 = -1;
    var it = std.mem.splitScalar(u8, srcset, ',');
    while (it.next()) |raw| {
        const cand = std.mem.trim(u8, raw, " \t\r\n");
        if (cand.len == 0) continue;
        // url is the first whitespace-delimited token; the rest is the descriptor.
        var sp: usize = 0;
        while (sp < cand.len and !isWs(cand[sp])) sp += 1;
        const url = cand[0..sp];
        var desc = std.mem.trim(u8, cand[sp..], " \t\r\n");
        // Strip a trailing 'w' or 'x' and parse the number (missing → weight 0).
        var w: i64 = 0;
        if (desc.len > 0 and (desc[desc.len - 1] == 'w' or desc[desc.len - 1] == 'x')) {
            desc = desc[0 .. desc.len - 1];
            w = std.fmt.parseInt(i64, std.mem.trim(u8, desc, " \t\r\n"), 10) catch 0;
        }
        // ">=" so a run of descriptor-less entries keeps the LAST one.
        if (w >= best_w) {
            best_w = w;
            best = url;
        }
    }
    return best;
}

/// The raw (still relative, unresolved) image URL an `<img>` tag advertises, per
/// the IMAGE-ATTR RULE: first present of `data-src`, `data-lazy-src`, `srcset`
/// (highest quality), then `src`. Trimmed. Null when the tag carries none.
pub fn imgAttrRaw(img_tag: []const u8) ?[]const u8 {
    if (tagAttr(img_tag, "data-src")) |v| {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len > 0) return t;
    }
    if (tagAttr(img_tag, "data-lazy-src")) |v| {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len > 0) return t;
    }
    if (tagAttr(img_tag, "srcset")) |v| {
        const best = std.mem.trim(u8, srcsetBest(v), " \t\r\n");
        if (best.len > 0) return best;
    }
    if (tagAttr(img_tag, "src")) |v| {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len > 0) return t;
    }
    return null;
}

/// The IMAGE-ATTR RULE end to end: pick the best attribute off an `<img>` tag and
/// resolve it to an absolute URL against `base`. Writes into `out`.
pub fn pickImageAttr(img_tag: []const u8, base: []const u8, out: []u8) ?[]const u8 {
    const raw = imgAttrRaw(img_tag) orelse return null;
    return resolveUrl(base, raw, out);
}

// ══════════════════════════════════════════════════════════
// Search / browse grid
// ══════════════════════════════════════════════════════════

pub const SearchItem = struct {
    /// The manga-detail href (still relative-or-absolute; resolve before use).
    url: []const u8,
    /// The `title="…"` attribute (may be "" — caller derives from the slug then).
    title: []const u8,
    /// The `<img …>` start-tag slice for the cover — run through `pickImageAttr`.
    img_tag: []const u8,
};

/// Walk the search/browse grid: each result is a `.bsx` block (`.listupd .bs .bsx`)
/// or a `.imgu` block (`.utao .uta .imgu`). Within each we take the inner `<a>`
/// (href + title) and the first `<img>` (cover).
pub const SearchIter = struct {
    html: []const u8,
    pos: usize = 0,

    fn nextMarker(self: *SearchIter) ?usize {
        const a = std.mem.indexOfPos(u8, self.html, self.pos, "bsx");
        const b = std.mem.indexOfPos(u8, self.html, self.pos, "imgu");
        if (a) |ai| {
            if (b) |bi| return @min(ai, bi);
            return ai;
        }
        return b;
    }

    pub fn next(self: *SearchIter) ?SearchItem {
        while (self.nextMarker()) |marker| {
            const a_lt = findElement(self.html, marker, "a") orelse {
                self.pos = marker + 3;
                continue;
            };
            const a_tag = scanStartTag(self.html, a_lt) orelse {
                self.pos = marker + 3;
                continue;
            };
            self.pos = a_tag.after;

            const href = tagAttr(a_tag.text, "href") orelse continue;
            if (href.len == 0) continue;
            const title = tagAttr(a_tag.text, "title") orelse "";

            var img_slice: []const u8 = "";
            if (findElement(self.html, a_lt, "img")) |img_lt| {
                // Only accept an <img> that belongs to THIS card — i.e. it
                // appears before the next card marker.
                const nxt = self.nextMarker();
                if (nxt == null or img_lt < nxt.?) {
                    if (scanStartTag(self.html, img_lt)) |img_tag| {
                        img_slice = img_tag.text;
                        self.pos = @max(self.pos, img_tag.after);
                    }
                }
            }
            return .{ .url = href, .title = title, .img_tag = img_slice };
        }
        return null;
    }
};

// ══════════════════════════════════════════════════════════
// Details
// ══════════════════════════════════════════════════════════

pub const Status = enum { unknown, ongoing, completed, hiatus, dropped };

pub const Details = struct {
    title: []const u8 = "",
    /// The `<img …>` start-tag slice for the series thumbnail (resolve via pickImageAttr).
    thumb_img: []const u8 = "",
    description: []const u8 = "",
    status: Status = .unknown,
};

fn mapStatus(text: []const u8) Status {
    const t = std.mem.trim(u8, text, " \t\r\n");
    var buf: [16]u8 = undefined;
    const n = @min(t.len, buf.len);
    for (0..n) |i| buf[i] = std.ascii.toLower(t[i]);
    const lo = buf[0..n];
    if (std.mem.indexOf(u8, lo, "ongoing") != null) return .ongoing;
    if (std.mem.indexOf(u8, lo, "complete") != null) return .completed;
    if (std.mem.indexOf(u8, lo, "hiatus") != null) return .hiatus;
    if (std.mem.indexOf(u8, lo, "drop") != null) return .dropped;
    return .unknown;
}

/// Parse the details page: `h1.entry-title`, `.thumb img` (or `div[itemprop=image]
/// img`), `.entry-content[itemprop=description]` (or `.desc`), and the status out
/// of `.tsinfo .imptdt:contains(Status) i`.
pub fn parseDetails(html: []const u8) Details {
    var d = Details{};

    if (std.mem.indexOf(u8, html, "entry-title")) |et| {
        if (innerAfterMarker(html, et, "entry-title")) |t| d.title = t;
    }

    // Thumbnail: prefer a `.thumb` wrapper, else an `itemprop="image"` wrapper.
    const thumb_from: ?usize = std.mem.indexOf(u8, html, "class=\"thumb\"") orelse
        std.mem.indexOf(u8, html, "itemprop=\"image\"");
    if (thumb_from) |tf| {
        if (findElement(html, tf, "img")) |img_lt| {
            if (scanStartTag(html, img_lt)) |img_tag| d.thumb_img = img_tag.text;
        }
    }

    // Description: entry-content[itemprop=description] or `.desc`.
    const desc_from: ?usize = std.mem.indexOf(u8, html, "itemprop=\"description\"") orelse
        std.mem.indexOf(u8, html, "class=\"desc\"");
    if (desc_from) |df| {
        const gt = std.mem.indexOfScalarPos(u8, html, df, '>') orelse df;
        var p = gt + 1;
        // Skip any immediately-nested opening tags (e.g. a `<p>` wrapper) so we
        // land on the actual text rather than the empty run before `<p>`.
        while (p < html.len) {
            while (p < html.len and isWs(html[p])) p += 1;
            if (p < html.len and html[p] == '<' and (p + 1 >= html.len or html[p + 1] != '/')) {
                const t = scanStartTag(html, p) orelse break;
                p = t.after;
                continue;
            }
            break;
        }
        const lt = std.mem.indexOfScalarPos(u8, html, p, '<') orelse html.len;
        d.description = std.mem.trim(u8, html[p..lt], " \t\r\n");
    }

    // Status: find the "Status" label inside a `.tsinfo`/`.imptdt` row, then the
    // following `<i>…</i>` value.
    if (std.mem.indexOf(u8, html, "Status")) |st| {
        if (findElement(html, st, "i")) |i_lt| {
            if (scanStartTag(html, i_lt)) |i_tag| {
                const start = i_tag.after;
                const lt = std.mem.indexOfScalarPos(u8, html, start, '<') orelse html.len;
                d.status = mapStatus(html[start..lt]);
            }
        }
    }

    return d;
}

/// Iterate genre links (`.mgen a` / `div.gnr a`), yielding each genre's text.
pub const GenreIter = struct {
    html: []const u8,
    pos: usize,
    end: usize,

    pub fn next(self: *GenreIter) ?[]const u8 {
        while (self.pos < self.end) {
            const a_lt = findElement(self.html, self.pos, "a") orelse return null;
            if (a_lt >= self.end) return null;
            const a_tag = scanStartTag(self.html, a_lt) orelse return null;
            self.pos = a_tag.after;
            const lt = std.mem.indexOfScalarPos(u8, self.html, a_tag.after, '<') orelse self.end;
            const text = std.mem.trim(u8, self.html[a_tag.after..lt], " \t\r\n");
            if (text.len > 0) return text;
        }
        return null;
    }
};

pub fn genreIter(html: []const u8) GenreIter {
    const start = std.mem.indexOf(u8, html, "mgen") orelse
        std.mem.indexOf(u8, html, "gnr") orelse html.len;
    // Bound to the next closing div so trailing `<a>`s aren't swept in.
    const end = std.mem.indexOfPos(u8, html, start, "</div>") orelse html.len;
    return .{ .html = html, .pos = start, .end = end };
}

// ══════════════════════════════════════════════════════════
// Chapters
// ══════════════════════════════════════════════════════════

pub const Chapter = struct {
    /// The chapter href (resolve before use).
    url: []const u8,
    /// `.chapternum` text (falls back to the anchor's inner text).
    name: []const u8,
    /// `.chapterdate` text ("" when absent).
    date: []const u8,
};

/// Iterate `div.bxcl li, #chapterlist li`. Chapters are listed newest-first, so
/// the LAST item yielded is the earliest chapter.
pub const ChapterIter = struct {
    html: []const u8,
    pos: usize,
    end: usize,

    pub fn next(self: *ChapterIter) ?Chapter {
        while (self.pos < self.end) {
            const li_lt = findElement(self.html, self.pos, "li") orelse return null;
            if (li_lt >= self.end) return null;
            // Bound this row at the next <li or the container end.
            const li_body_start = li_lt + 3;
            const next_li = findElement(self.html, li_body_start, "li") orelse self.end;
            const row_end = @min(next_li, self.end);
            const row = self.html[li_lt..row_end];
            self.pos = row_end;

            // url: the first <a href> in the row.
            const a_lt = findElement(row, 0, "a") orelse continue;
            const a_tag = scanStartTag(row, a_lt) orelse continue;
            const href = tagAttr(a_tag.text, "href") orelse continue;
            if (href.len == 0) continue;

            // name: `.chapternum` text, else the anchor's inner text.
            var name: []const u8 = "";
            if (innerAfterMarker(row, 0, "chapternum")) |cn| {
                name = cn;
            } else {
                const lt = std.mem.indexOfScalarPos(u8, row, a_tag.after, '<') orelse row.len;
                name = std.mem.trim(u8, row[a_tag.after..lt], " \t\r\n");
            }

            const date: []const u8 = innerAfterMarker(row, 0, "chapterdate") orelse "";
            return .{ .url = href, .name = name, .date = date };
        }
        return null;
    }
};

pub fn chapterIter(html: []const u8) ChapterIter {
    const start = std.mem.indexOf(u8, html, "chapterlist") orelse
        std.mem.indexOf(u8, html, "bxcl") orelse 0;
    const end = std.mem.indexOfPos(u8, html, start, "</ul>") orelse html.len;
    return .{ .html = html, .pos = start, .end = end };
}

// ══════════════════════════════════════════════════════════
// Page images
// ══════════════════════════════════════════════════════════

/// Extract page image URLs into `out` / `out_lens` (parallel arrays — pass the
/// reader's `page_urls` / `page_url_lens` slices directly). Returns the count.
///
/// PRIMARY: every `<img>` inside `div#readerarea`, via the IMAGE-ATTR RULE.
/// FALLBACK (JS-embedded readers): the `"images":[ … ]` JSON string array — many
/// MangaThemesia sites emit the page list only inside a `ts_reader.run({…})` call.
pub fn parsePages(
    html: []const u8,
    base: []const u8,
    out: [][512]u8,
    out_lens: []usize,
) usize {
    const max = @min(out.len, out_lens.len);
    var count: usize = 0;

    // ── PRIMARY: div#readerarea img ──
    const ra: ?usize = std.mem.indexOf(u8, html, "id=\"readerarea\"") orelse
        std.mem.indexOf(u8, html, "id='readerarea'");
    if (ra) |ra_at| {
        const ra_gt = std.mem.indexOfScalarPos(u8, html, ra_at, '>') orelse ra_at;
        // readerarea holds only <p>/<img> in the common case, so the first
        // </div> after it bounds the region and keeps footer/nav <img>s out.
        const ra_end = std.mem.indexOfPos(u8, html, ra_gt, "</div>") orelse html.len;
        var scan = ra_gt;
        while (count < max) {
            const img_lt = findElement(html, scan, "img") orelse break;
            if (img_lt >= ra_end) break;
            const img_tag = scanStartTag(html, img_lt) orelse break;
            scan = img_tag.after;
            var buf: [512]u8 = undefined;
            const url = pickImageAttr(img_tag.text, base, &buf) orelse continue;
            if (url.len == 0 or url.len >= out[count].len) continue;
            @memcpy(out[count][0..url.len], url);
            out_lens[count] = url.len;
            count += 1;
        }
    }
    if (count > 0) return count;

    // ── FALLBACK: "images":[ "…", "…" ] embedded in the reader JS ──
    if (cpure.findJsonNode(html, "\"images\"")) |arr| {
        var it = cpure.StrIter{ .buf = arr };
        while (it.next()) |raw| {
            if (count >= max) break;
            var un: [512]u8 = undefined;
            const un_n = cpure.jsonUnescape(raw, &un);
            if (un_n == 0) continue;
            var buf: [512]u8 = undefined;
            const url = resolveUrl(base, un[0..un_n], &buf);
            if (url.len == 0 or url.len >= out[count].len) continue;
            @memcpy(out[count][0..url.len], url);
            out_lens[count] = url.len;
            count += 1;
        }
    }
    return count;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "buildBrowseUrl: text search (default order), base with trailing slash" {
    var buf: [256]u8 = undefined;
    const url = buildBrowseUrl("https://site.com/", DEFAULT_DIR, "one punch man", 1, "", &buf).?;
    try std.testing.expectEqualStrings(
        "https://site.com/manga/?title=one+punch+man&page=1&order=",
        url,
    );
}

test "buildBrowseUrl: popular / latest / A-Z share the endpoint via `order`" {
    var buf: [256]u8 = undefined;
    const pop = buildBrowseUrl("https://s.com", "/manga", "", 2, "popular", &buf).?;
    try std.testing.expectEqualStrings("https://s.com/manga/?title=&page=2&order=popular", pop);

    var b2: [256]u8 = undefined;
    const upd = buildBrowseUrl("https://s.com", "/manga", "", 1, "update", &b2).?;
    try std.testing.expect(std.mem.endsWith(u8, upd, "&order=update"));

    var b3: [256]u8 = undefined;
    const az = buildBrowseUrl("https://s.com", "/manga", "", 1, "title", &b3).?;
    try std.testing.expect(std.mem.endsWith(u8, az, "&order=title"));
}

test "buildBrowseUrl: custom mangaUrlDirectory, empty base rejected, injection encoded" {
    var buf: [256]u8 = undefined;
    const url = buildBrowseUrl("https://s.com", "/series", "a&b=c", 1, "", &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, url, "/series/?title=a%26b%3Dc") != null);
    // A crafted query cannot smuggle an extra param.
    try std.testing.expect(std.mem.indexOf(u8, url, "title=a&b=c") == null);

    var b2: [256]u8 = undefined;
    try std.testing.expect(buildBrowseUrl("", "/manga", "x", 1, "", &b2) == null);
    // Empty dir → DEFAULT_DIR.
    var b3: [256]u8 = undefined;
    const dfl = buildBrowseUrl("https://s.com", "", "x", 1, "", &b3).?;
    try std.testing.expect(std.mem.indexOf(u8, dfl, "/manga/?") != null);
}

test "resolveUrl: relative → absolute, protocol-relative, absolute passthrough" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://cdn.site.com/x.jpg",
        resolveUrl("https://site.com/manga/foo/", "https://cdn.site.com/x.jpg", &buf),
    );
    try std.testing.expectEqualStrings(
        "https://site.com/wp/x.jpg",
        resolveUrl("https://site.com/manga/foo/", "/wp/x.jpg", &buf),
    );
    try std.testing.expectEqualStrings(
        "https://cdn.other.com/y.png",
        resolveUrl("https://site.com/manga/", "//cdn.other.com/y.png", &buf),
    );
    // Bare relative path resolves against the origin.
    try std.testing.expectEqualStrings(
        "https://site.com/rel.jpg",
        resolveUrl("https://site.com/manga/foo/", "rel.jpg", &buf),
    );
}

test "srcsetBest: highest descriptor wins; descriptor-less keeps the last" {
    try std.testing.expectEqualStrings(
        "https://c/big.jpg",
        srcsetBest("https://c/small.jpg 320w, https://c/big.jpg 640w"),
    );
    try std.testing.expectEqualStrings(
        "https://c/2x.jpg",
        srcsetBest("https://c/1x.jpg 1x, https://c/2x.jpg 2x"),
    );
    try std.testing.expectEqualStrings(
        "https://c/last.jpg",
        srcsetBest("https://c/a.jpg, https://c/last.jpg"),
    );
}

test "IMAGE-ATTR precedence: data-src > data-lazy-src > srcset > src" {
    // data-src wins outright.
    try std.testing.expectEqualStrings(
        "https://c/real.jpg",
        imgAttrRaw("<img src=\"data:image/gif;base64,PLACEHOLDER\" data-src=\"https://c/real.jpg\">").?,
    );
    // No data-src → data-lazy-src.
    try std.testing.expectEqualStrings(
        "https://c/lazy.jpg",
        imgAttrRaw("<img src=\"ph.gif\" data-lazy-src=\"https://c/lazy.jpg\">").?,
    );
    // No data-* → srcset (highest quality).
    try std.testing.expectEqualStrings(
        "https://c/big.jpg",
        imgAttrRaw("<img src=\"ph.gif\" srcset=\"https://c/s.jpg 1x, https://c/big.jpg 2x\">").?,
    );
    // Only src.
    try std.testing.expectEqualStrings(
        "https://c/plain.jpg",
        imgAttrRaw("<img class=\"x\" src=\"https://c/plain.jpg\">").?,
    );
    // `src` must NOT be read out of `data-src` (name-boundary regression).
    try std.testing.expectEqualStrings(
        "https://c/only-data.jpg",
        imgAttrRaw("<img data-src=\"https://c/only-data.jpg\">").?,
    );
}

test "pickImageAttr: resolves the chosen attr against the base" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://site.com/wp/cover.jpg",
        pickImageAttr("<img data-src=\"/wp/cover.jpg\" src=\"ph.gif\">", "https://site.com/manga/x/", &buf).?,
    );
    try std.testing.expect(pickImageAttr("<img alt=\"no url\">", "https://site.com", &buf) == null);
}

test "SearchIter: .listupd .bs .bsx grid (href + title + cover)" {
    const html =
        \\<div class="listupd">
        \\  <div class="bs"><div class="bsx">
        \\    <a href="/manga/one-piece/" title="One Piece">
        \\      <div class="limit"><img src="ph.gif" data-src="https://c/op.jpg" class="ts-post-image"></div>
        \\      <div class="bigor"><div class="tt">One Piece</div></div>
        \\    </a>
        \\  </div></div>
        \\  <div class="bs"><div class="bsx">
        \\    <a href="/manga/naruto/" title="Naruto">
        \\      <div class="limit"><img data-src="https://c/nrt.jpg"></div>
        \\    </a>
        \\  </div></div>
        \\</div>
    ;
    var it = SearchIter{ .html = html };
    const a = it.next().?;
    try std.testing.expectEqualStrings("/manga/one-piece/", a.url);
    try std.testing.expectEqualStrings("One Piece", a.title);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://c/op.jpg", pickImageAttr(a.img_tag, "https://site.com", &buf).?);

    const b = it.next().?;
    try std.testing.expectEqualStrings("/manga/naruto/", b.url);
    try std.testing.expectEqualStrings("Naruto", b.title);
    try std.testing.expectEqualStrings("https://c/nrt.jpg", pickImageAttr(b.img_tag, "https://site.com", &buf).?);

    try std.testing.expect(it.next() == null);
}

test "SearchIter: .utao .uta .imgu variant" {
    const html =
        \\<div class="utao"><div class="uta">
        \\  <div class="imgu"><a href="https://s.com/manga/bleach/" title="Bleach"><img data-src="https://c/bl.jpg"></a></div>
        \\  <div class="luf"><h4>Bleach</h4></div>
        \\</div></div>
    ;
    var it = SearchIter{ .html = html };
    const a = it.next().?;
    try std.testing.expectEqualStrings("https://s.com/manga/bleach/", a.url);
    try std.testing.expectEqualStrings("Bleach", a.title);
    try std.testing.expect(it.next() == null);
}

test "parseDetails: title, thumb, status, description + genres" {
    const html =
        \\<div class="bigcontent">
        \\  <div class="thumb"><img src="https://c/thumb.jpg" itemprop="image"></div>
        \\  <div class="infox">
        \\    <h1 class="entry-title" itemprop="name">Solo Leveling</h1>
        \\    <div class="tsinfo">
        \\      <div class="imptdt">Status <i>Completed</i></div>
        \\      <div class="imptdt">Type <i>Manhwa</i></div>
        \\    </div>
        \\    <div class="entry-content" itemprop="description"><p>A hunter rises.</p></div>
        \\    <span class="mgen"><a href="/genre/action/">Action</a><a href="/genre/fantasy/">Fantasy</a></span>
        \\  </div>
        \\</div>
    ;
    const d = parseDetails(html);
    try std.testing.expectEqualStrings("Solo Leveling", d.title);
    try std.testing.expectEqual(Status.completed, d.status);
    try std.testing.expectEqualStrings("A hunter rises.", d.description);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://c/thumb.jpg", pickImageAttr(d.thumb_img, "https://site.com", &buf).?);

    var g = genreIter(html);
    try std.testing.expectEqualStrings("Action", g.next().?);
    try std.testing.expectEqualStrings("Fantasy", g.next().?);
    try std.testing.expect(g.next() == null);
}

test "parseDetails: status mapping (ongoing/hiatus/dropped/unknown)" {
    try std.testing.expectEqual(Status.ongoing, parseDetails("<div>Status <i>Ongoing</i></div>").status);
    try std.testing.expectEqual(Status.hiatus, parseDetails("<div>Status <i>Hiatus</i></div>").status);
    try std.testing.expectEqual(Status.dropped, parseDetails("<div>Status <i>Dropped</i></div>").status);
    try std.testing.expectEqual(Status.unknown, parseDetails("<div>no status here</div>").status);
}

test "chapterIter: #chapterlist li — url, name, date; last item is earliest" {
    const html =
        \\<div class="bxcl"><ul id="chapterlist">
        \\  <li data-num="3"><div class="eph-num"><a href="https://s.com/one-piece-chapter-3/">
        \\    <span class="chapternum">Chapter 3</span><span class="chapterdate">Jan 3, 2024</span></a></div></li>
        \\  <li data-num="2"><div class="eph-num"><a href="https://s.com/one-piece-chapter-2/">
        \\    <span class="chapternum">Chapter 2</span><span class="chapterdate">Jan 2, 2024</span></a></div></li>
        \\  <li data-num="1"><div class="eph-num"><a href="https://s.com/one-piece-chapter-1/">
        \\    <span class="chapternum">Chapter 1</span><span class="chapterdate">Jan 1, 2024</span></a></div></li>
        \\</ul></div>
    ;
    var it = chapterIter(html);
    const c1 = it.next().?;
    try std.testing.expectEqualStrings("https://s.com/one-piece-chapter-3/", c1.url);
    try std.testing.expectEqualStrings("Chapter 3", c1.name);
    try std.testing.expectEqualStrings("Jan 3, 2024", c1.date);

    var last: Chapter = c1;
    var n: usize = 1;
    while (it.next()) |c| {
        last = c;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    // Newest-first list → the LAST yielded chapter is the earliest (Ch. 1).
    try std.testing.expectEqualStrings("https://s.com/one-piece-chapter-1/", last.url);
    try std.testing.expectEqualStrings("Chapter 1", last.name);
}

test "parsePages: PRIMARY div#readerarea img (IMAGE-ATTR + resolve), scoped" {
    const html =
        \\<div id="readerarea" class="rdminimal">
        \\  <p><img src="ph.gif" data-src="https://cdn.site.com/1.jpg"></p>
        \\  <p><img src="https://cdn.site.com/2.jpg"></p>
        \\  <p><img data-lazy-src="/pages/3.jpg"></p>
        \\</div>
        \\<div class="bottomnav"><img src="https://ads.example/banner.jpg"></div>
    ;
    var urls: [16][512]u8 = undefined;
    var lens: [16]usize = std.mem.zeroes([16]usize);
    const n = parsePages(html, "https://site.com", &urls, &lens);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("https://cdn.site.com/1.jpg", urls[0][0..lens[0]]);
    try std.testing.expectEqualStrings("https://cdn.site.com/2.jpg", urls[1][0..lens[1]]);
    // Relative page resolved against the origin; ad banner past </div> excluded.
    try std.testing.expectEqualStrings("https://site.com/pages/3.jpg", urls[2][0..lens[2]]);
}

test "parsePages: FALLBACK \"images\":[…] JSON (escaped slashes) when readerarea empty" {
    const html =
        \\<div id="readerarea"></div>
        \\<script>ts_reader.run({"post_id":42,"images":["https:\/\/cdn.site.com\/a.jpg","https:\/\/cdn.site.com\/b.jpg","https:\/\/cdn.site.com\/c.jpg"],"prevUrl":"x"});</script>
    ;
    var urls: [16][512]u8 = undefined;
    var lens: [16]usize = std.mem.zeroes([16]usize);
    const n = parsePages(html, "https://site.com", &urls, &lens);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("https://cdn.site.com/a.jpg", urls[0][0..lens[0]]);
    try std.testing.expectEqualStrings("https://cdn.site.com/c.jpg", urls[2][0..lens[2]]);
}

test "parsePages: no readerarea, no images → 0 (no crash)" {
    var urls: [16][512]u8 = undefined;
    var lens: [16]usize = std.mem.zeroes([16]usize);
    try std.testing.expectEqual(@as(usize, 0), parsePages("<html><body>nothing</body></html>", "https://s.com", &urls, &lens));
    // Truncated / malformed readerarea must not hang or over-read.
    try std.testing.expectEqual(@as(usize, 0), parsePages("<div id=\"readerarea\"><img data-src=", "https://s.com", &urls, &lens));
}

test "SearchIter / parseDetails / chapterIter: malformed input never crashes" {
    var s = SearchIter{ .html = "<div class=\"bsx\"><a title=\"x\">no href</a>" };
    // No href → item skipped, iterator terminates cleanly.
    try std.testing.expect(s.next() == null);

    _ = parseDetails("");
    _ = parseDetails("<h1 class=\"entry-title\">unclosed");

    var c = chapterIter("<ul id=\"chapterlist\"><li>garbage");
    try std.testing.expect(c.next() == null);
}
