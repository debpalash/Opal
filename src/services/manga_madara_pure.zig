//! Pure (io-free, state-free) parsing for the **Madara** manga engine —
//! unit-testable via `zig build test`.
//!
//! Madara is the WordPress theme that ~332 Mihon/Tachiyomi manga sites share, so
//! one base-URL-driven engine reaches hundreds of sites. A site is INERT until a
//! `baseUrl` is supplied by `source_config` ("madara"/"base"); nothing is
//! hardcoded in the binary (mirrors the readallcomics seam).
//!
//! `comics.zig` routes ALL its Madara HTML/URL work through this module so the
//! shipped logic IS the tested logic (no drift). Covers:
//!   - URL builders (popular / latest / search) + the AJAX chapter-list body
//!   - a lightweight tag/attr/class scanner (there is no HTML lib)
//!   - the shared IMAGE-ATTR rule (data-src → data-lazy-src → srcset → data-cfsrc
//!     → src), srcset "highest quality" selection, and relative→absolute resolve
//!   - iterators for the search grid, the chapter list and the page images
//!   - `parseDetails` (title / thumbnail / author / description / status) and the
//!     `data-id` extraction for the AJAX chapter fallback
//!   - the `madara:<mangaUrl>` pseudo-URL scheme that routes a search-result card
//!     into the Madara reader path (parallel to MangaDex's `mangadex:` scheme)
//!
//! Everything is fixed-buffer / no-allocation, matching the project's
//! `[N]u8 + len` convention. Slices returned by the iterators/parsers point INTO
//! the caller's HTML buffer — copy them out before the buffer is reused/freed.

const std = @import("std");
const query_enc = @import("comics_pure.zig").percentEncodeQuery;

// ══════════════════════════════════════════════════════════
// Route pseudo-URL scheme: madara:<mangaUrl>
// ══════════════════════════════════════════════════════════

/// A Madara search-result card can't be read by the generic curl+HTML scraper
/// (its pages come from details → chapter-list → chapter-page chain), so cards
/// carry `madara:<absolute manga url>` and `comics.fetchComicThread` dispatches
/// on the prefix — exactly like MangaDex's `mangadex:<uuid>`.
pub const MADARA_SCHEME = "madara:";

/// Build the `madara:<mangaUrl>` route a search-result card stores. The manga URL
/// must be absolute (`http…`) — a relative/garbage href is refused so a bad row
/// can never later be curl'd as a non-URL.
pub fn buildRouteUrl(out: []u8, manga_url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, manga_url, "http")) return null;
    return std.fmt.bufPrint(out, "{s}{s}", .{ MADARA_SCHEME, manga_url }) catch null;
}

/// Extract the absolute manga URL from a `madara:<url>` route (null if it isn't
/// one, or the payload isn't an absolute http URL).
pub fn mangaUrlFromRoute(route: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, route, MADARA_SCHEME)) return null;
    const url = route[MADARA_SCHEME.len..];
    if (!std.mem.startsWith(u8, url, "http")) return null;
    return url;
}

// ══════════════════════════════════════════════════════════
// URL builders
// ══════════════════════════════════════════════════════════

pub const Order = enum { views, latest };

/// Trim a single trailing '/' so `{base}/…` never doubles the slash.
fn trimSlash(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

/// POPULAR / LATEST listing URL.
///   page 1 → `{base}/{sub}/?m_orderby={o}`
///   page N → `{base}/{sub}/page/{N}/?m_orderby={o}`
/// `sub` defaults to "manga" at the call site (Madara's `mangaSubString`).
pub fn buildPopularUrl(out: []u8, base: []const u8, sub: []const u8, page: u32, order: Order) ?[]const u8 {
    const b = trimSlash(base);
    if (b.len == 0) return null;
    const o: []const u8 = switch (order) {
        .views => "views",
        .latest => "latest",
    };
    if (page <= 1) {
        return std.fmt.bufPrint(out, "{s}/{s}/?m_orderby={s}", .{ b, sub, o }) catch null;
    }
    return std.fmt.bufPrint(out, "{s}/{s}/page/{d}/?m_orderby={s}", .{ b, sub, page, o }) catch null;
}

/// SEARCH URL. `{base}/page/{n}/?s={query}&post_type=wp-manga` — page 1 omits the
/// `/page/1/` segment. The query is form-encoded (space → `+`), reusing the
/// tested `comics_pure.percentEncodeQuery` (WordPress `?s=` accepts `+`).
pub fn buildSearchUrl(out: []u8, base: []const u8, query: []const u8, page: u32) ?[]const u8 {
    const b = trimSlash(base);
    if (b.len == 0 or query.len == 0) return null;
    var enc: [512]u8 = undefined;
    const n = query_enc(query, &enc);
    if (n == 0) return null;
    if (page <= 1) {
        return std.fmt.bufPrint(out, "{s}/?s={s}&post_type=wp-manga", .{ b, enc[0..n] }) catch null;
    }
    return std.fmt.bufPrint(out, "{s}/page/{d}/?s={s}&post_type=wp-manga", .{ b, page, enc[0..n] }) catch null;
}

/// The `admin-ajax.php` form body that fetches the chapter list for a manga whose
/// `data-id` came from `dataIdFromHolder`. The id is a numeric WordPress post id;
/// reject anything with a control/`&` char so it can't smuggle an extra field.
pub fn buildAjaxBody(out: []u8, data_id: []const u8) ?[]const u8 {
    if (data_id.len == 0 or data_id.len > 32) return null;
    for (data_id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    return std.fmt.bufPrint(out, "action=manga_get_chapters&manga={s}", .{data_id}) catch null;
}

/// AJAX endpoint on the site: `{base}/wp-admin/admin-ajax.php`.
pub fn buildAjaxUrl(out: []u8, base: []const u8) ?[]const u8 {
    const b = trimSlash(base);
    if (b.len == 0) return null;
    return std.fmt.bufPrint(out, "{s}/wp-admin/admin-ajax.php", .{b}) catch null;
}

// ══════════════════════════════════════════════════════════
// URL resolution (relative → absolute)
// ══════════════════════════════════════════════════════════

/// The `scheme://host` origin of an absolute URL (no trailing slash). Falls back
/// to the whole string if it isn't a well-formed absolute URL.
pub fn origin(url: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return url;
    const after = sep + 3;
    const slash = std.mem.indexOfScalarPos(u8, url, after, '/') orelse return url;
    return url[0..slash];
}

/// Resolve `ref` (which may be absolute, protocol-relative, root-relative, or
/// document-relative) against `base`, writing the absolute URL into `out`.
/// Leading/trailing ASCII whitespace on `ref` is trimmed first.
pub fn resolveUrl(base: []const u8, ref_in: []const u8, out: []u8) []const u8 {
    const ref = std.mem.trim(u8, ref_in, " \t\r\n");
    if (ref.len == 0) return "";
    if (std.mem.startsWith(u8, ref, "http")) {
        const n = @min(ref.len, out.len);
        @memcpy(out[0..n], ref[0..n]);
        return out[0..n];
    }
    if (std.mem.startsWith(u8, ref, "//")) {
        // Protocol-relative — borrow the base's scheme.
        const sep = std.mem.indexOf(u8, base, "://") orelse return std.fmt.bufPrint(out, "https:{s}", .{ref}) catch ref;
        return std.fmt.bufPrint(out, "{s}:{s}", .{ base[0..sep], ref }) catch ref;
    }
    if (std.mem.startsWith(u8, ref, "/")) {
        return std.fmt.bufPrint(out, "{s}{s}", .{ origin(base), ref }) catch ref;
    }
    // Document-relative — hang it off the base directory.
    const dir = trimSlash(base);
    return std.fmt.bufPrint(out, "{s}/{s}", .{ dir, ref }) catch ref;
}

// ══════════════════════════════════════════════════════════
// Minimal HTML scanning primitives
// ══════════════════════════════════════════════════════════

/// Value of an attribute `name` (e.g. "href=") in `scope`, handling both `"` and
/// `'` quoting and optional whitespace around `=`. Returns the slice between the
/// quotes (into `scope`).
///
/// The name is matched only at an ATTRIBUTE BOUNDARY — the char before it must be
/// whitespace or a tag delimiter (`<`/`'`/`"`). Without this, `src=` would latch
/// onto the `src=` INSIDE `data-src=` (its blank value hiding the real one) — the
/// exact bug the image-attr precedence rule depends on not happening.
pub fn attrVal(scope: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, scope, from, name)) |at| {
        from = at + name.len;
        // Boundary check: the char before must not be a name char (so `src=`
        // never matches within `data-src=`).
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

/// The `<img …>` opening tag that starts at or after `from` in `scope`. Returns
/// the slice from `<img` to the closing `>` (inclusive), or null.
pub fn imgTagAt(scope: []const u8, from: usize) ?struct { tag: []const u8, end: usize } {
    const rel = std.mem.indexOfPos(u8, scope, from, "<img") orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, scope, rel, '>') orelse return null;
    return .{ .tag = scope[rel .. gt + 1], .end = gt + 1 };
}

/// Inner text of the element opening at `open`: the FIRST non-empty run of text
/// after a `>` and before the next `<`, trimmed. Skipping empty runs lets a
/// nested wrapper (e.g. `<span…><i>June 1, 2021</i></span>`) still yield its text
/// rather than the empty gap between the two opening tags. Returns "" if none.
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

/// Find the class-marked element block for `class_sub`, starting the search at
/// `from`. The block spans from the element's opening `<` to just before the NEXT
/// element carrying the same class (or end of HTML) — matching the readallcomics
/// scanner's "needle + next needle bound" so blocks never bleed together.
fn classBlock(html: []const u8, from: usize, class_sub: []const u8) ?struct { block: []const u8, next: usize } {
    const at = std.mem.indexOfPos(u8, html, from, class_sub) orelse return null;
    const open = std.mem.lastIndexOfScalar(u8, html[0..at], '<') orelse return null;
    const after = at + class_sub.len;
    const next_rel = std.mem.indexOfPos(u8, html, after, class_sub);
    const block_end = if (next_rel) |nr| (std.mem.lastIndexOfScalar(u8, html[0..nr], '<') orelse html.len) else html.len;
    return .{ .block = html[open..block_end], .next = block_end };
}

// ══════════════════════════════════════════════════════════
// Image-attr rule (shared)
// ══════════════════════════════════════════════════════════

/// Pick the best image URL from an `<img …>` opening tag, per the shared rule:
/// first present of data-src, data-lazy-src, srcset (highest-quality entry),
/// data-cfsrc, src. Returns the RAW url slice (trimmed) — resolve with
/// `resolveUrl`. Null when the tag carries no usable source.
pub fn pickImageAttr(img_tag: []const u8) ?[]const u8 {
    if (attrVal(img_tag, "data-src=")) |v| if (nonEmpty(v)) return trimUrl(v);
    if (attrVal(img_tag, "data-lazy-src=")) |v| if (nonEmpty(v)) return trimUrl(v);
    if (attrVal(img_tag, "srcset=")) |v| if (srcsetBest(v)) |best| return best;
    if (attrVal(img_tag, "data-cfsrc=")) |v| if (nonEmpty(v)) return trimUrl(v);
    if (attrVal(img_tag, "src=")) |v| if (nonEmpty(v)) return trimUrl(v);
    return null;
}

fn trimUrl(v: []const u8) []const u8 {
    return std.mem.trim(u8, v, " \t\r\n");
}

fn nonEmpty(v: []const u8) bool {
    return trimUrl(v).len > 0;
}

/// Highest-quality candidate of a `srcset` value (`url1 480w, url2 800w` or
/// `url1 1x, url2 2x`). Picks the entry with the largest numeric descriptor;
/// a bare url with no descriptor counts as 1. Returns the url slice (into `set`).
fn srcsetBest(set_in: []const u8) ?[]const u8 {
    const set = trimUrl(set_in);
    if (set.len == 0) return null;
    var best: ?[]const u8 = null;
    var best_w: u64 = 0;
    var it = std.mem.splitScalar(u8, set, ',');
    while (it.next()) |cand_raw| {
        const cand = std.mem.trim(u8, cand_raw, " \t\r\n");
        if (cand.len == 0) continue;
        // Split the candidate into "url [descriptor]".
        var parts = std.mem.tokenizeAny(u8, cand, " \t\r\n");
        const url = parts.next() orelse continue;
        var w: u64 = 1;
        if (parts.next()) |desc| {
            // descriptor like "800w" / "2x" — read the leading number.
            var end: usize = 0;
            while (end < desc.len and std.ascii.isDigit(desc[end])) end += 1;
            if (end > 0) w = std.fmt.parseInt(u64, desc[0..end], 10) catch 1;
        }
        if (best == null or w >= best_w) {
            best = url;
            best_w = w;
        }
    }
    return best;
}

// ══════════════════════════════════════════════════════════
// Search grid
// ══════════════════════════════════════════════════════════

pub const SearchItem = struct {
    /// Display title (into html; trim/decode entities at the call site).
    title: []const u8,
    /// Raw manga URL (href of `div.post-title a`) — resolve with `resolveUrl`.
    url: []const u8,
    /// Raw cover url from the item's `<img>` per the image-attr rule ("" if none).
    cover: []const u8,
};

/// Iterate a Madara search/listing grid. Each result is a `div.page-item-detail`
/// (or `.manga__item`) block carrying `div.post-title a` (href + title) and an
/// `<img>` cover.
pub const SearchIter = struct {
    html: []const u8,
    pos: usize = 0,

    pub fn next(self: *SearchIter) ?SearchItem {
        while (true) {
            const blk = classBlock(self.html, self.pos, "page-item-detail") orelse {
                // Fall back to the alternate item class if the primary isn't present.
                const alt = classBlock(self.html, self.pos, "manga__item") orelse return null;
                self.pos = alt.next;
                if (parseItem(alt.block)) |it| return it;
                continue;
            };
            self.pos = blk.next;
            if (parseItem(blk.block)) |it| return it;
        }
    }
};

fn parseItem(block: []const u8) ?SearchItem {
    // Title + url: the anchor inside `post-title`.
    const pt = std.mem.indexOf(u8, block, "post-title") orelse return null;
    const a_open = std.mem.indexOfPos(u8, block, pt, "<a") orelse return null;
    const url = attrVal(block[a_open..], "href=") orelse return null;
    if (url.len == 0) return null;
    var title = innerText(block, a_open);
    if (title.len == 0) {
        // Some themes put the title in the anchor's title="" attr instead.
        title = attrVal(block[a_open..], "title=") orelse "";
    }
    // Cover: the first <img> in the block via the image-attr rule.
    var cover: []const u8 = "";
    if (imgTagAt(block, 0)) |img| {
        if (pickImageAttr(img.tag)) |c| cover = c;
    }
    return .{ .title = title, .url = url, .cover = cover };
}

// ══════════════════════════════════════════════════════════
// Details page
// ══════════════════════════════════════════════════════════

pub const Status = enum { unknown, ongoing, completed, hiatus, canceled };

pub const Details = struct {
    title: []const u8 = "",
    /// Raw thumbnail url (image-attr rule) — resolve with `resolveUrl`.
    thumbnail: []const u8 = "",
    author: []const u8 = "",
    description: []const u8 = "",
    status: Status = .unknown,
};

/// Map a Madara status word to the enum (word lists from the reference sources).
pub fn mapStatus(word_in: []const u8) Status {
    const word = std.mem.trim(u8, word_in, " \t\r\n");
    var buf: [32]u8 = undefined;
    const n = @min(word.len, buf.len);
    for (0..n) |i| buf[i] = std.ascii.toLower(word[i]);
    const w = buf[0..n];
    if (std.mem.indexOf(u8, w, "ongoing") != null or std.mem.indexOf(u8, w, "publishing") != null or std.mem.indexOf(u8, w, "releasing") != null) return .ongoing;
    if (std.mem.indexOf(u8, w, "completed") != null or std.mem.indexOf(u8, w, "finished") != null) return .completed;
    if (std.mem.indexOf(u8, w, "hiatus") != null or std.mem.indexOf(u8, w, "on hold") != null) return .hiatus;
    if (std.mem.indexOf(u8, w, "cancel") != null or std.mem.indexOf(u8, w, "dropped") != null or std.mem.indexOf(u8, w, "discontinued") != null) return .canceled;
    return .unknown;
}

/// Parse the manga details page.
pub fn parseDetails(html: []const u8) Details {
    var d = Details{};

    // Title: `div.post-title h3, div.post-title h1`.
    if (std.mem.indexOf(u8, html, "post-title")) |pt| {
        const scope = html[pt..];
        var idx: ?usize = null;
        if (std.mem.indexOf(u8, scope, "<h3")) |h| idx = h;
        if (idx == null) {
            if (std.mem.indexOf(u8, scope, "<h1")) |h| idx = h;
        }
        if (idx) |h| {
            const t = innerText(scope, h);
            if (t.len > 0) d.title = t;
        }
    }

    // Thumbnail: `div.summary_image img`.
    if (std.mem.indexOf(u8, html, "summary_image")) |si| {
        if (imgTagAt(html, si)) |img| {
            if (pickImageAttr(img.tag)) |c| d.thumbnail = c;
        }
    }

    // Author: `div.author-content > a`.
    if (std.mem.indexOf(u8, html, "author-content")) |ac| {
        if (std.mem.indexOfPos(u8, html, ac, "<a")) |a| {
            const t = innerText(html, a);
            if (t.len > 0) d.author = t;
        }
    }

    // Description: `div.summary__content` (or `div.manga-excerpt`).
    if (std.mem.indexOf(u8, html, "summary__content")) |sc| {
        d.description = firstParagraphText(html[sc..]);
    } else if (std.mem.indexOf(u8, html, "manga-excerpt")) |me| {
        d.description = firstParagraphText(html[me..]);
    }

    // Status: `div.post-status .summary-content`.
    if (std.mem.indexOf(u8, html, "post-status")) |ps| {
        const scope = html[ps..];
        if (std.mem.indexOf(u8, scope, "summary-content")) |sc| {
            d.status = mapStatus(innerText(scope, sc));
        }
    }
    return d;
}

/// Text of the first `<p>…</p>` in `scope` (Madara wraps the description in a
/// paragraph); falls back to the text after the first `>` when there's no `<p>`.
fn firstParagraphText(scope: []const u8) []const u8 {
    if (std.mem.indexOf(u8, scope, "<p")) |p| {
        const gt = std.mem.indexOfScalarPos(u8, scope, p, '>') orelse return "";
        const end = std.mem.indexOfPos(u8, scope, gt + 1, "</p>") orelse std.mem.indexOfScalarPos(u8, scope, gt + 1, '<') orelse scope.len;
        return std.mem.trim(u8, scope[gt + 1 .. end], " \t\r\n");
    }
    return innerText(scope, 0);
}

/// The `data-id` of `div[id^=manga-chapters-holder]`, for the AJAX chapter list.
pub fn dataIdFromHolder(html: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, html, "manga-chapters-holder") orelse return null;
    const open = std.mem.lastIndexOfScalar(u8, html[0..at], '<') orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, html, at, '>') orelse return null;
    return attrVal(html[open .. gt + 1], "data-id=");
}

// ══════════════════════════════════════════════════════════
// Chapter list
// ══════════════════════════════════════════════════════════

pub const Chapter = struct {
    /// Raw chapter url (anchor href) — resolve with `resolveUrl`.
    url: []const u8,
    name: []const u8,
    date: []const u8 = "",
};

/// Iterate `li.wp-manga-chapter` blocks (present either in the details HTML or in
/// the AJAX chapter-list response — the markup is identical). Document order is
/// newest→oldest, matching the source.
pub const ChapterIter = struct {
    html: []const u8,
    pos: usize = 0,

    pub fn next(self: *ChapterIter) ?Chapter {
        while (true) {
            const blk = classBlock(self.html, self.pos, "wp-manga-chapter") orelse return null;
            self.pos = blk.next;
            const a = std.mem.indexOf(u8, blk.block, "<a") orelse continue;
            const url = attrVal(blk.block[a..], "href=") orelse continue;
            if (url.len == 0) continue;
            const name = innerText(blk.block, a);
            var date: []const u8 = "";
            if (std.mem.indexOf(u8, blk.block, "chapter-release-date")) |crd| {
                date = innerText(blk.block[crd..], 0);
            }
            return .{ .url = url, .name = name, .date = date };
        }
    }
};

// ══════════════════════════════════════════════════════════
// Chapter page images
// ══════════════════════════════════════════════════════════

/// True when a chapter page uses the AES "chapter-protector" encrypted-image
/// path — skipped in v1 (we surface a toast instead of decrypting).
pub fn isProtected(html: []const u8) bool {
    return std.mem.indexOf(u8, html, "chapter-protector-data") != null;
}

/// Where the readable page images start: the `reading-content` container (else
/// the first `page-break`, else 0). Ads/logos before it are excluded.
fn pagesRegionStart(html: []const u8) usize {
    if (std.mem.indexOf(u8, html, "reading-content")) |r| return r;
    if (std.mem.indexOf(u8, html, "page-break")) |p| return p;
    return 0;
}

/// Iterate the `<img>` page images of a chapter (`div.page-break img` /
/// `.reading-content img`). Yields the RAW image url (image-attr rule); resolve
/// each with `resolveUrl`.
pub const PageIter = struct {
    html: []const u8,
    pos: usize,

    pub fn init(html: []const u8) PageIter {
        return .{ .html = html, .pos = pagesRegionStart(html) };
    }

    pub fn next(self: *PageIter) ?[]const u8 {
        while (imgTagAt(self.html, self.pos)) |img| {
            self.pos = img.end;
            if (pickImageAttr(img.tag)) |u| {
                if (trimUrl(u).len > 0) return trimUrl(u);
            }
        }
        return null;
    }
};

// ══════════════════════════════════════════════════════════
// Array-filling convenience wrappers (thin — route through the iterators so the
// tested logic here is the shipped logic; used by the standalone tests. The
// production reader consumes the iterators directly to avoid large temporaries).
// ══════════════════════════════════════════════════════════

pub const MAX_PAGES = 128;

/// Fill `out` with up to `out.len` absolute page-image URLs; returns the count.
/// Each url is resolved against `base`.
pub fn parsePages(html: []const u8, base: []const u8, out: [][256]u8, lens: []usize) usize {
    var n: usize = 0;
    var it = PageIter.init(html);
    while (it.next()) |raw| {
        if (n >= out.len or n >= lens.len) break;
        var buf: [256]u8 = undefined;
        const abs = resolveUrl(base, raw, &buf);
        if (abs.len == 0 or abs.len > out[n].len) continue;
        @memcpy(out[n][0..abs.len], abs);
        lens[n] = abs.len;
        n += 1;
    }
    return n;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "route: build → parse round-trip; garbage refused" {
    var buf: [256]u8 = undefined;
    const url = "https://site.example/manga/naruto/";
    const route = buildRouteUrl(&buf, url).?;
    try std.testing.expectEqualStrings("madara:https://site.example/manga/naruto/", route);
    try std.testing.expectEqualStrings(url, mangaUrlFromRoute(route).?);
    try std.testing.expect(mangaUrlFromRoute("mangadex:x") == null);
    try std.testing.expect(mangaUrlFromRoute("madara:/manga/x") == null); // not absolute
    var b2: [16]u8 = undefined;
    try std.testing.expect(buildRouteUrl(&b2, "/relative") == null);
}

test "buildPopularUrl: page 1 vs page N, views vs latest, base slash trimmed" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://s.test/manga/?m_orderby=views",
        buildPopularUrl(&buf, "https://s.test/", "manga", 1, .views).?,
    );
    try std.testing.expectEqualStrings(
        "https://s.test/manga/page/3/?m_orderby=latest",
        buildPopularUrl(&buf, "https://s.test", "manga", 3, .latest).?,
    );
    // A site with a custom mangaSubString.
    try std.testing.expectEqualStrings(
        "https://s.test/manhwa/?m_orderby=views",
        buildPopularUrl(&buf, "https://s.test", "manhwa", 1, .views).?,
    );
}

test "buildSearchUrl: page 1 omits /page/1/, query form-encoded" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://s.test/?s=one+piece&post_type=wp-manga",
        buildSearchUrl(&buf, "https://s.test/", "one piece", 1).?,
    );
    try std.testing.expectEqualStrings(
        "https://s.test/page/2/?s=solo+leveling&post_type=wp-manga",
        buildSearchUrl(&buf, "https://s.test", "solo leveling", 2).?,
    );
    // Injection-y query comes back inert (no stray &/=).
    const u = buildSearchUrl(&buf, "https://s.test", "x&a=1", 1).?;
    try std.testing.expect(std.mem.indexOf(u8, u, "s=x%26a%3D1&") != null);
    try std.testing.expect(buildSearchUrl(&buf, "https://s.test", "", 1) == null);
}

test "buildAjaxBody / buildAjaxUrl" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("action=manga_get_chapters&manga=1234", buildAjaxBody(&buf, "1234").?);
    try std.testing.expect(buildAjaxBody(&buf, "12&manga=evil") == null); // '&' rejected
    try std.testing.expect(buildAjaxBody(&buf, "") == null);
    var b2: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://s.test/wp-admin/admin-ajax.php", buildAjaxUrl(&b2, "https://s.test/").?);
}

test "resolveUrl: absolute, protocol-relative, root-relative, doc-relative" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://cdn.test/a.jpg",
        resolveUrl("https://s.test/manga/x/", "https://cdn.test/a.jpg", &out),
    );
    try std.testing.expectEqualStrings(
        "https://cdn.test/a.jpg",
        resolveUrl("https://s.test/manga/x/", "//cdn.test/a.jpg", &out),
    );
    try std.testing.expectEqualStrings(
        "https://s.test/img/a.jpg",
        resolveUrl("https://s.test/manga/x/", "/img/a.jpg", &out),
    );
    try std.testing.expectEqualStrings(
        "https://s.test/manga/x/a.jpg",
        resolveUrl("https://s.test/manga/x/", "a.jpg", &out),
    );
    // Whitespace-padded refs are trimmed.
    try std.testing.expectEqualStrings(
        "https://cdn.test/a.jpg",
        resolveUrl("https://s.test/", "  https://cdn.test/a.jpg\n", &out),
    );
    try std.testing.expectEqualStrings("", resolveUrl("https://s.test/", "   ", &out));
}

test "pickImageAttr: precedence data-src > data-lazy-src > srcset > data-cfsrc > src" {
    try std.testing.expectEqualStrings(
        "https://cdn/ds.jpg",
        pickImageAttr("<img src=\"https://cdn/s.jpg\" data-src=\"https://cdn/ds.jpg\">").?,
    );
    try std.testing.expectEqualStrings(
        "https://cdn/lazy.jpg",
        pickImageAttr("<img src=\"https://cdn/s.jpg\" data-lazy-src=\"https://cdn/lazy.jpg\">").?,
    );
    try std.testing.expectEqualStrings(
        "https://cdn/cf.jpg",
        pickImageAttr("<img src=\"https://cdn/s.jpg\" data-cfsrc=\"https://cdn/cf.jpg\">").?,
    );
    try std.testing.expectEqualStrings(
        "https://cdn/s.jpg",
        pickImageAttr("<img src=\"https://cdn/s.jpg\">").?,
    );
    // Blank higher-priority attr falls through to src.
    try std.testing.expectEqualStrings(
        "https://cdn/s.jpg",
        pickImageAttr("<img data-src=\"  \" src=\"https://cdn/s.jpg\">").?,
    );
    try std.testing.expect(pickImageAttr("<img alt=\"x\">") == null);
}

test "pickImageAttr: srcset picks the highest-quality entry" {
    // Ascending 'w' descriptors — take the largest.
    try std.testing.expectEqualStrings(
        "https://cdn/lg.jpg",
        pickImageAttr("<img srcset=\"https://cdn/sm.jpg 480w, https://cdn/md.jpg 800w, https://cdn/lg.jpg 1200w\">").?,
    );
    // 'x' density descriptors.
    try std.testing.expectEqualStrings(
        "https://cdn/2x.jpg",
        pickImageAttr("<img srcset=\"https://cdn/1x.jpg 1x, https://cdn/2x.jpg 2x\">").?,
    );
    // srcset beats a plain src.
    try std.testing.expectEqualStrings(
        "https://cdn/hi.jpg",
        pickImageAttr("<img src=\"https://cdn/lo.jpg\" srcset=\"https://cdn/hi.jpg 2x\">").?,
    );
}

const SEARCH_HTML =
    \\<div class="c-tabs-item">
    \\  <div class="row c-tabs-item__content">
    \\    <div class="page-item-detail manga">
    \\      <div class="item-thumb">
    \\        <a href="https://s.test/manga/berserk/">
    \\          <img data-src="https://cdn.test/covers/berserk.jpg" src="/lazy.png" class="img-responsive">
    \\        </a>
    \\      </div>
    \\      <div class="item-summary">
    \\        <div class="post-title"><h3><a href="https://s.test/manga/berserk/">Berserk</a></h3></div>
    \\      </div>
    \\    </div>
    \\    <div class="page-item-detail manga">
    \\      <div class="item-thumb">
    \\        <a href="https://s.test/manga/vinland-saga/">
    \\          <img srcset="https://cdn.test/vs-sm.jpg 480w, https://cdn.test/vs-lg.jpg 1000w" src="/f.png">
    \\        </a>
    \\      </div>
    \\      <div class="item-summary">
    \\        <div class="post-title"><h3><a href="https://s.test/manga/vinland-saga/">Vinland Saga</a></h3></div>
    \\      </div>
    \\    </div>
    \\  </div>
    \\</div>
;

test "SearchIter: two results with title, url, cover (image-attr rule)" {
    var it = SearchIter{ .html = SEARCH_HTML };
    const a = it.next().?;
    try std.testing.expectEqualStrings("Berserk", a.title);
    try std.testing.expectEqualStrings("https://s.test/manga/berserk/", a.url);
    try std.testing.expectEqualStrings("https://cdn.test/covers/berserk.jpg", a.cover); // data-src wins over src
    const b = it.next().?;
    try std.testing.expectEqualStrings("Vinland Saga", b.title);
    try std.testing.expectEqualStrings("https://s.test/manga/vinland-saga/", b.url);
    try std.testing.expectEqualStrings("https://cdn.test/vs-lg.jpg", b.cover); // srcset highest quality
    try std.testing.expect(it.next() == null);
}

test "SearchIter: alternate .manga__item class + relative cover resolves" {
    const html =
        \\<div class="manga__item">
        \\  <img data-src="/covers/x.jpg">
        \\  <div class="post-title"><h3><a href="/manga/x/">X Title</a></h3></div>
        \\</div>
    ;
    var it = SearchIter{ .html = html };
    const a = it.next().?;
    try std.testing.expectEqualStrings("X Title", a.title);
    try std.testing.expectEqualStrings("/manga/x/", a.url);
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://s.test/manga/x/", resolveUrl("https://s.test", a.url, &out));
    try std.testing.expectEqualStrings("https://s.test/covers/x.jpg", resolveUrl("https://s.test", a.cover, &out));
    try std.testing.expect(it.next() == null);
}

const DETAILS_HTML =
    \\<div class="profile-manga">
    \\  <div class="summary_image"><a href="#"><img src="https://cdn.test/thumb/berserk.jpg" class="img-responsive"></a></div>
    \\  <div class="post-title"><h1>Berserk</h1></div>
    \\  <div class="author-content"><a href="https://s.test/author/miura/">Kentaro Miura</a></div>
    \\  <div class="post-status">
    \\    <div class="summary-heading"><h5>Status</h5></div>
    \\    <div class="summary-content">OnGoing</div>
    \\  </div>
    \\  <div class="description-summary">
    \\    <div class="summary__content"><p>A dark fantasy epic about Guts.</p></div>
    \\  </div>
    \\  <div id="manga-chapters-holder" data-id="4271" data-slug="berserk"></div>
    \\  <ul class="main version-chap">
    \\    <li class="wp-manga-chapter"><a href="https://s.test/manga/berserk/chapter-364/">Chapter 364</a><span class="chapter-release-date"><i>June 1, 2021</i></span></li>
    \\    <li class="wp-manga-chapter"><a href="https://s.test/manga/berserk/chapter-1/">Chapter 1</a><span class="chapter-release-date"><i>Jan 1, 1990</i></span></li>
    \\  </ul>
    \\</div>
;

test "parseDetails: title/thumb/author/description/status" {
    const d = parseDetails(DETAILS_HTML);
    try std.testing.expectEqualStrings("Berserk", d.title);
    try std.testing.expectEqualStrings("https://cdn.test/thumb/berserk.jpg", d.thumbnail);
    try std.testing.expectEqualStrings("Kentaro Miura", d.author);
    try std.testing.expectEqualStrings("A dark fantasy epic about Guts.", d.description);
    try std.testing.expectEqual(Status.ongoing, d.status);
}

test "mapStatus: word lists" {
    try std.testing.expectEqual(Status.ongoing, mapStatus("OnGoing"));
    try std.testing.expectEqual(Status.completed, mapStatus("Completed"));
    try std.testing.expectEqual(Status.hiatus, mapStatus("On Hiatus"));
    try std.testing.expectEqual(Status.canceled, mapStatus("Cancelled"));
    try std.testing.expectEqual(Status.unknown, mapStatus("???"));
}

test "dataIdFromHolder + ChapterIter over details HTML" {
    try std.testing.expectEqualStrings("4271", dataIdFromHolder(DETAILS_HTML).?);
    var it = ChapterIter{ .html = DETAILS_HTML };
    const c1 = it.next().?;
    try std.testing.expectEqualStrings("https://s.test/manga/berserk/chapter-364/", c1.url);
    try std.testing.expectEqualStrings("Chapter 364", c1.name);
    try std.testing.expectEqualStrings("June 1, 2021", c1.date);
    const c2 = it.next().?;
    try std.testing.expectEqualStrings("https://s.test/manga/berserk/chapter-1/", c2.url);
    try std.testing.expectEqualStrings("Chapter 1", c2.name);
    try std.testing.expect(it.next() == null);
}

test "ChapterIter over an AJAX admin-ajax.php response fragment" {
    const ajax =
        \\<li class="wp-manga-chapter"><a href="https://s.test/manga/x/ch-2/">Ch 2</a><span class="chapter-release-date">2d ago</span></li>
        \\<li class="wp-manga-chapter"><a href="https://s.test/manga/x/ch-1/">Ch 1</a><span class="chapter-release-date">3d ago</span></li>
    ;
    var it = ChapterIter{ .html = ajax };
    try std.testing.expectEqualStrings("https://s.test/manga/x/ch-2/", it.next().?.url);
    try std.testing.expectEqualStrings("https://s.test/manga/x/ch-1/", it.next().?.url);
    try std.testing.expect(it.next() == null);
}

const PAGES_HTML =
    \\<div class="c-blog__heading"><img src="https://s.test/logo.png"></div>
    \\<div class="reading-content">
    \\  <div class="page-break no-gaps"><img id="image-0" data-src="https://cdn.test/p/1.jpg" src="/lazy.png" class="wp-manga-chapter-img"></div>
    \\  <div class="page-break no-gaps"><img id="image-1" data-src="/p/2.jpg" class="wp-manga-chapter-img"></div>
    \\  <div class="page-break no-gaps"><img id="image-2" srcset="https://cdn.test/p/3-sm.jpg 480w, https://cdn.test/p/3.jpg 1200w" class="wp-manga-chapter-img"></div>
    \\</div>
;

test "PageIter: skips the logo, applies image-attr rule, region-scoped" {
    var it = PageIter.init(PAGES_HTML);
    try std.testing.expectEqualStrings("https://cdn.test/p/1.jpg", it.next().?); // data-src over src
    try std.testing.expectEqualStrings("/p/2.jpg", it.next().?); // relative (resolve later)
    try std.testing.expectEqualStrings("https://cdn.test/p/3.jpg", it.next().?); // srcset best
    try std.testing.expect(it.next() == null); // logo above reading-content excluded
}

test "parsePages: fills caller arrays with resolved absolute URLs" {
    var out: [MAX_PAGES][256]u8 = undefined;
    var lens: [MAX_PAGES]usize = undefined;
    const n = parsePages(PAGES_HTML, "https://s.test/manga/x/chapter-1/", &out, &lens);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("https://cdn.test/p/1.jpg", out[0][0..lens[0]]);
    try std.testing.expectEqualStrings("https://s.test/p/2.jpg", out[1][0..lens[1]]); // resolved root-relative
    try std.testing.expectEqualStrings("https://cdn.test/p/3.jpg", out[2][0..lens[2]]);
}

test "isProtected: detects the chapter-protector marker" {
    try std.testing.expect(isProtected("<div id=\"chapter-protector-data\" data-key=\"x\"></div>"));
    try std.testing.expect(!isProtected(PAGES_HTML));
}

test "malformed / truncated HTML never crashes (no-panic sweep)" {
    const junk = [_][]const u8{
        "",
        "<",
        "<img",
        "<img src=",
        "<img src=\"",
        "<div class=\"page-item-detail",
        "<li class=\"wp-manga-chapter\"><a href=",
        "<div class=\"reading-content\"><img data-src=\"",
        "srcset only: <img srcset=\"\">",
        "<div id=\"manga-chapters-holder\" data-id=",
    };
    for (junk) |h| {
        var s = SearchIter{ .html = h };
        while (s.next()) |_| {}
        var c = ChapterIter{ .html = h };
        while (c.next()) |_| {}
        var p = PageIter.init(h);
        while (p.next()) |_| {}
        _ = parseDetails(h);
        _ = dataIdFromHolder(h);
        _ = isProtected(h);
        _ = pickImageAttr(h);
    }
}
