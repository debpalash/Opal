//! Pure (io-free, state-free) parsing for the **DooPlay** anime engine — the
//! generic base-URL-driven scraper for the WordPress "DooPlay" video theme that
//! ~25 anime-streaming sites share. Sister engine to `manga_themesia_pure`
//! (manga) — same "one tested pure module, routed by the shipped code" contract.
//!
//! `anime.zig` reads the base from `source_config.get("dooplay", "base")` and the
//! source stays INERT until a plugin supplies it (nothing hardcoded). Every
//! HTML/JSON/URL decision the DooPlay flow makes is routed through here so the
//! tested logic IS the shipped logic (no drift).
//!
//! Covers:
//!   - URL builders: `buildPopularUrl` ({base}/), `buildSearchUrl` ({base}/?s=…),
//!     `buildAjaxUrl` ({base}/wp-admin/admin-ajax.php) + `buildAjaxBody`
//!   - search / popular grid (`GridIter`: `article.w_item_a` AND `.result-item`)
//!   - details (`parseDetails`: `div.sheader` title / poster / description / status)
//!   - episodes (`EpisodeIter`: `ul.episodios > li`, `.numerando` / `.date`;
//!     movies have no list → the caller adds a single "Movie" episode)
//!   - the VIDEO EMBED chain: player options (`#playeroptionsul li` carrying
//!     `data-post` / `data-nume` / `data-type`) → the `doo_player_ajax` POST body
//!     → the `{"embed_url":"…"}` JSON parse. The resulting embed URL is what
//!     `anime_extractors.resolveEmbed` / `anime.playEmbed` consume.
//!
//! Image-attr rule + relative→absolute resolve + percent-encoding + JSON unescape
//! are REUSED from `manga_themesia_pure` / `comics_pure` (no duplication).

const std = @import("std");
const mt = @import("manga_themesia_pure.zig");
const cpure = @import("comics_pure.zig");

/// `dooplay:` pseudo-URL scheme — a DooPlay search card carries
/// `dooplay:<detail-url>` so `anime.zig` can dispatch on the prefix, mirroring the
/// manga `themesia:` scheme.
pub const SCHEME = "dooplay:";

// ══════════════════════════════════════════════════════════
// URL / body building
// ══════════════════════════════════════════════════════════

fn trimSlash(base: []const u8) []const u8 {
    if (base.len > 0 and base[base.len - 1] == '/') return base[0 .. base.len - 1];
    return base;
}

/// `{base}/` — the DooPlay home page (popular / latest grid).
pub fn buildPopularUrl(base: []const u8, out: []u8) ?[]const u8 {
    if (base.len == 0) return null;
    return std.fmt.bufPrint(out, "{s}/", .{trimSlash(base)}) catch null;
}

/// `{base}/?s={query}` — the WordPress site-search grid. Query percent-encoded
/// (space → `+`) via the shared tested encoder.
pub fn buildSearchUrl(base: []const u8, query: []const u8, out: []u8) ?[]const u8 {
    if (base.len == 0) return null;
    var enc: [512]u8 = undefined;
    const n = cpure.percentEncodeQuery(query, &enc);
    return std.fmt.bufPrint(out, "{s}/?s={s}", .{ trimSlash(base), enc[0..n] }) catch null;
}

/// `{base}/wp-admin/admin-ajax.php` — the DooPlay player AJAX endpoint.
pub fn buildAjaxUrl(base: []const u8, out: []u8) ?[]const u8 {
    if (base.len == 0) return null;
    return std.fmt.bufPrint(out, "{s}/wp-admin/admin-ajax.php", .{trimSlash(base)}) catch null;
}

/// The `doo_player_ajax` POST body for one player option:
/// `action=doo_player_ajax&post={post}&nume={nume}&type={type}`.
pub fn buildAjaxBody(post: []const u8, nume: []const u8, type_: []const u8, out: []u8) ?[]const u8 {
    if (post.len == 0) return null;
    return std.fmt.bufPrint(out, "action=doo_player_ajax&post={s}&nume={s}&type={s}", .{
        post, if (nume.len == 0) "1" else nume, if (type_.len == 0) "tv" else type_,
    }) catch null;
}

/// Parse the `doo_player_ajax` JSON response → the embed URL. DooPlay returns
/// `{"embed_url":"https:\/\/host\/embed\/x","type":"iframe"}`; the URL is
/// JSON-escaped (`\/`), so unescape it before returning. Some skins wrap the
/// URL in an `<iframe src="…">`; when `embed_url` holds an iframe tag we pull the
/// `src` out of it.
pub fn parseEmbedUrl(json: []const u8, out: []u8) ?[]const u8 {
    const raw = findJsonString(json, "\"embed_url\":\"") orelse return null;
    if (raw.len == 0) return null;
    var un: [1024]u8 = undefined;
    const n = cpure.jsonUnescape(raw, &un);
    if (n == 0) return null;
    const val = un[0..n];

    // Skin variant: embed_url is itself an <iframe src="…"> fragment.
    if (std.mem.indexOf(u8, val, "<iframe") != null) {
        if (mt.tagAttr(val, "src")) |src| {
            if (src.len == 0 or src.len >= out.len) return null;
            @memcpy(out[0..src.len], src);
            return out[0..src.len];
        }
    }
    if (val.len >= out.len) return null;
    @memcpy(out[0..val.len], val);
    return out[0..val.len];
}

/// Extract a JSON string value after a `"key":"` prefix, honoring escaped quotes.
/// (comics_pure.findJsonNode targets arrays/objects; DooPlay needs a plain string.)
fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, key) orelse return null;
    const s = start + key.len;
    var i: usize = s;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1;
            continue;
        }
        if (json[i] == '"') return json[s..i];
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// Minimal HTML scanning (self-contained; tested here)
// ══════════════════════════════════════════════════════════

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

const Tag = struct { text: []const u8, after: usize };

/// The start-tag slice `<name …>` beginning at `<` at `lt`, quote-aware.
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

/// Next `<name` element start at/after `from` (name boundary enforced).
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

/// Inner text of the first element whose start-tag contains `marker`, from `from`.
fn innerAfterMarker(html: []const u8, from: usize, marker: []const u8) ?[]const u8 {
    const at = std.mem.indexOfPos(u8, html, from, marker) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, html, at, '>') orelse return null;
    const start = gt + 1;
    const lt = std.mem.indexOfScalarPos(u8, html, start, '<') orelse html.len;
    return std.mem.trim(u8, html[start..lt], " \t\r\n");
}

/// The label text of the element carrying `marker`: its own inner text, or —
/// when that's empty (the text sits in a nested `<a>`) — the first inner `<a>`'s
/// text. Returns null when `marker` is absent, "" when present but text-less.
fn labelAt(html: []const u8, marker: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, html, marker) orelse return null;
    if (innerAfterMarker(html, at, marker)) |t| {
        if (t.len > 0) return t;
    }
    if (findElement(html, at, "a")) |a_lt| {
        if (scanStartTag(html, a_lt)) |a_tag| {
            const lt = std.mem.indexOfScalarPos(u8, html, a_tag.after, '<') orelse html.len;
            const t = std.mem.trim(u8, html[a_tag.after..lt], " \t\r\n");
            if (t.len > 0) return t;
        }
    }
    return "";
}

/// Map a status word to `mt.Status` (local; mt.mapStatus is private).
fn mapStatus(text: []const u8) mt.Status {
    const t = std.mem.trim(u8, text, " \t\r\n");
    var buf: [16]u8 = undefined;
    const n = @min(t.len, buf.len);
    for (0..n) |i| buf[i] = std.ascii.toLower(t[i]);
    const lo = buf[0..n];
    if (std.mem.indexOf(u8, lo, "ongoing") != null) return .ongoing;
    if (std.mem.indexOf(u8, lo, "airing") != null) return .ongoing;
    if (std.mem.indexOf(u8, lo, "complete") != null) return .completed;
    if (std.mem.indexOf(u8, lo, "finished") != null) return .completed;
    if (std.mem.indexOf(u8, lo, "hiatus") != null) return .hiatus;
    if (std.mem.indexOf(u8, lo, "drop") != null) return .dropped;
    return .unknown;
}

// ══════════════════════════════════════════════════════════
// Search / popular grid
// ══════════════════════════════════════════════════════════

pub const GridItem = struct {
    /// The detail-page href (resolve before use).
    url: []const u8,
    /// The title (from the cover `<img alt>`, else a `.title`/entry-title anchor).
    title: []const u8,
    /// The cover `<img …>` start-tag slice — run through `mt.pickImageAttr`.
    img_tag: []const u8,
};

/// Walk the DooPlay grid. Home uses `article.w_item_a`; site-search uses
/// `.result-item`. Both wrap a thumbnail `<a href>` + `<img>` and a title; we take
/// the first `<a>` (href), the first `<img>` (cover + its `alt` title), and fall
/// back to a `.title`/entry-title anchor's inner text when the img carries no alt.
pub const GridIter = struct {
    html: []const u8,
    pos: usize = 0,

    fn markerAt(html: []const u8, from: usize) ?usize {
        const a = std.mem.indexOfPos(u8, html, from, "w_item_a");
        const b = std.mem.indexOfPos(u8, html, from, "result-item");
        if (a) |ai| {
            if (b) |bi| return @min(ai, bi);
            return ai;
        }
        return b;
    }

    pub fn next(self: *GridIter) ?GridItem {
        while (markerAt(self.html, self.pos)) |marker| {
            // This item's region ends at the NEXT marker (search past this one).
            const item_end = markerAt(self.html, marker + 8) orelse self.html.len;
            self.pos = item_end;

            const a_lt = findElement(self.html, marker, "a") orelse continue;
            if (a_lt >= item_end) continue;
            const a_tag = scanStartTag(self.html, a_lt) orelse continue;
            const href = mt.tagAttr(a_tag.text, "href") orelse continue;
            if (href.len == 0) continue;

            var img_slice: []const u8 = "";
            var title: []const u8 = "";
            if (findElement(self.html, a_lt, "img")) |img_lt| {
                if (img_lt < item_end) {
                    if (scanStartTag(self.html, img_lt)) |img_tag| {
                        img_slice = img_tag.text;
                        title = mt.tagAttr(img_tag.text, "alt") orelse "";
                    }
                }
            }
            // No alt → title anchor inner text (`.title` for search, entry-title
            // for the home grid).
            if (title.len == 0) {
                const region = self.html[marker..item_end];
                title = labelAt(region, "class=\"title\"") orelse
                    labelAt(region, "entry-title") orelse "";
            }
            return .{ .url = href, .title = std.mem.trim(u8, title, " \t\r\n"), .img_tag = img_slice };
        }
        return null;
    }
};

pub fn gridIter(html: []const u8) GridIter {
    return .{ .html = html };
}

// ══════════════════════════════════════════════════════════
// Details (div.sheader)
// ══════════════════════════════════════════════════════════

pub const Details = struct {
    title: []const u8 = "",
    /// The poster `<img …>` start-tag slice (resolve via `mt.pickImageAttr`).
    poster_img: []const u8 = "",
    description: []const u8 = "",
    status: mt.Status = .unknown,
};

/// Parse the DooPlay detail page: `div.sheader` → `.data h1` (title), `.poster img`
/// (poster), `[itemprop=description]` / `.wp-content` (description), and a
/// "Status" custom field.
pub fn parseDetails(html: []const u8) Details {
    var d = Details{};

    // Title: `.data > h1` (inside div.sheader). Fall back to entry-title.
    const title_from: ?usize = std.mem.indexOf(u8, html, "class=\"data\"") orelse
        std.mem.indexOf(u8, html, "sheader");
    if (title_from) |tf| {
        if (findElement(html, tf, "h1")) |h_lt| {
            if (scanStartTag(html, h_lt)) |h_tag| {
                const lt = std.mem.indexOfScalarPos(u8, html, h_tag.after, '<') orelse html.len;
                d.title = std.mem.trim(u8, html[h_tag.after..lt], " \t\r\n");
            }
        }
    }
    if (d.title.len == 0) {
        if (innerAfterMarker(html, 0, "entry-title")) |t| d.title = t;
    }

    // Poster: `.poster img` (div.poster inside div.sheader).
    if (std.mem.indexOf(u8, html, "class=\"poster\"")) |pf| {
        if (findElement(html, pf, "img")) |img_lt| {
            if (scanStartTag(html, img_lt)) |img_tag| d.poster_img = img_tag.text;
        }
    }

    // Description: [itemprop=description] or `.wp-content`.
    const desc_from: ?usize = std.mem.indexOf(u8, html, "itemprop=\"description\"") orelse
        std.mem.indexOf(u8, html, "wp-content");
    if (desc_from) |df| {
        const gt = std.mem.indexOfScalarPos(u8, html, df, '>') orelse df;
        var p = gt + 1;
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

    // Status: a "Status" label followed by its value span/i.
    if (std.mem.indexOf(u8, html, "Status")) |st| {
        if (findElement(html, st, "span")) |sp| {
            if (scanStartTag(html, sp)) |sp_tag| {
                const lt = std.mem.indexOfScalarPos(u8, html, sp_tag.after, '<') orelse html.len;
                d.status = mapStatus(html[sp_tag.after..lt]);
            }
        }
        if (d.status == .unknown) {
            if (innerAfterMarker(html, st, ">")) |v| d.status = mapStatus(v);
        }
    }
    return d;
}

// ══════════════════════════════════════════════════════════
// Episodes (ul.episodios > li)
// ══════════════════════════════════════════════════════════

pub const Episode = struct {
    /// The episode page href (contains #playeroptionsul; resolve before use).
    url: []const u8,
    /// A short label (`.numerando` "1 - 5", else the anchor text).
    label: []const u8,
    /// `.date` text ("" when absent).
    date: []const u8,
};

/// Iterate `ul.episodios > li`. DooPlay lists episodes newest-first inside each
/// season, so the caller reverses to oldest-first. Movies have no `ul.episodios`
/// → the iterator yields nothing and the caller synthesizes a single "Movie"
/// episode pointing at the detail page (which carries its own player options).
pub const EpisodeIter = struct {
    html: []const u8,
    pos: usize,
    end: usize,

    pub fn next(self: *EpisodeIter) ?Episode {
        while (self.pos < self.end) {
            const li_lt = findElement(self.html, self.pos, "li") orelse return null;
            if (li_lt >= self.end) return null;
            const body_start = li_lt + 3;
            const next_li = findElement(self.html, body_start, "li") orelse self.end;
            const row_end = @min(next_li, self.end);
            const row = self.html[li_lt..row_end];
            self.pos = row_end;

            // href: the episode link (`.episodiotitle a`, else first <a>).
            const a_lt = findElement(row, 0, "a") orelse continue;
            const a_tag = scanStartTag(row, a_lt) orelse continue;
            const href = mt.tagAttr(a_tag.text, "href") orelse continue;
            if (href.len == 0) continue;

            var label: []const u8 = innerAfterMarker(row, 0, "numerando") orelse "";
            if (label.len == 0) {
                const lt = std.mem.indexOfScalarPos(u8, row, a_tag.after, '<') orelse row.len;
                label = std.mem.trim(u8, row[a_tag.after..lt], " \t\r\n");
            }
            const date: []const u8 = innerAfterMarker(row, 0, "class=\"date\"") orelse "";
            return .{ .url = href, .label = label, .date = date };
        }
        return null;
    }
};

pub fn episodeIter(html: []const u8) EpisodeIter {
    const start = std.mem.indexOf(u8, html, "episodios") orelse html.len;
    const end = std.mem.indexOfPos(u8, html, start, "</ul>") orelse html.len;
    return .{ .html = html, .pos = start, .end = end };
}

// ══════════════════════════════════════════════════════════
// Player options (#playeroptionsul li → data-post / data-nume / data-type)
// ══════════════════════════════════════════════════════════

pub const PlayerOption = struct {
    post: []const u8,
    nume: []const u8,
    type_: []const u8,
};

/// Iterate the player-server options inside `#playeroptionsul`. Each `<li>` carries
/// `data-post` (the episode/movie post id, same across options), `data-nume` (the
/// server index) and `data-type` (usually "tv" or "movie"). Feed each to
/// `buildAjaxBody`.
pub const PlayerOptionIter = struct {
    html: []const u8,
    pos: usize,
    end: usize,

    pub fn next(self: *PlayerOptionIter) ?PlayerOption {
        while (self.pos < self.end) {
            const li_lt = findElement(self.html, self.pos, "li") orelse return null;
            if (li_lt >= self.end) return null;
            const li_tag = scanStartTag(self.html, li_lt) orelse return null;
            self.pos = li_tag.after;
            const post = mt.tagAttr(li_tag.text, "data-post") orelse continue;
            if (post.len == 0) continue;
            const nume = mt.tagAttr(li_tag.text, "data-nume") orelse "1";
            const type_ = mt.tagAttr(li_tag.text, "data-type") orelse "tv";
            return .{ .post = post, .nume = nume, .type_ = type_ };
        }
        return null;
    }
};

pub fn playerOptionIter(html: []const u8) PlayerOptionIter {
    const start = std.mem.indexOf(u8, html, "playeroptionsul") orelse html.len;
    const end = std.mem.indexOfPos(u8, html, start, "</ul>") orelse html.len;
    return .{ .html = html, .pos = start, .end = end };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "buildSearchUrl / buildPopularUrl: trailing slash normalized, query encoded" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://s.com/", buildPopularUrl("https://s.com", &buf).?);
    try std.testing.expectEqualStrings("https://s.com/", buildPopularUrl("https://s.com/", &buf).?);
    try std.testing.expectEqualStrings(
        "https://s.com/?s=one+piece",
        buildSearchUrl("https://s.com/", "one piece", &buf).?,
    );
    // Injection cannot smuggle an extra param.
    const inj = buildSearchUrl("https://s.com", "a&b=c", &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, inj, "s=a%26b%3Dc") != null);
    try std.testing.expect(buildPopularUrl("", &buf) == null);
}

test "buildAjaxUrl / buildAjaxBody: doo_player_ajax POST" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://s.com/wp-admin/admin-ajax.php",
        buildAjaxUrl("https://s.com/", &buf).?,
    );
    var b2: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "action=doo_player_ajax&post=1234&nume=2&type=tv",
        buildAjaxBody("1234", "2", "tv", &b2).?,
    );
    // Empty type/nume default; empty post rejected.
    var b3: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "action=doo_player_ajax&post=9&nume=1&type=tv",
        buildAjaxBody("9", "", "", &b3).?,
    );
    try std.testing.expect(buildAjaxBody("", "1", "tv", &b3) == null);
}

test "parseEmbedUrl: escaped slashes unescaped; iframe-wrapped variant" {
    var buf: [512]u8 = undefined;
    const j = "{\"type\":\"iframe\",\"embed_url\":\"https:\\/\\/megacloud.blog\\/embed\\/e-1\\/abc?k=1\"}";
    try std.testing.expectEqualStrings(
        "https://megacloud.blog/embed/e-1/abc?k=1",
        parseEmbedUrl(j, &buf).?,
    );
    const j2 = "{\"embed_url\":\"<iframe src=\\\"https:\\/\\/streamwish.to\\/e\\/xy\\\"><\\/iframe>\"}";
    try std.testing.expectEqualStrings("https://streamwish.to/e/xy", parseEmbedUrl(j2, &buf).?);
    try std.testing.expect(parseEmbedUrl("{\"type\":\"iframe\"}", &buf) == null);
}

test "GridIter: article.w_item_a home grid (href + img alt title + cover)" {
    const html =
        \\<div class="items">
        \\  <article class="w_item_a">
        \\    <a href="https://s.com/anime/naruto/"><img src="ph.gif" data-src="https://c/nrt.jpg" alt="Naruto"></a>
        \\  </article>
        \\  <article class="w_item_a">
        \\    <a href="https://s.com/anime/bleach/"><img data-src="https://c/bl.jpg" alt="Bleach"></a>
        \\  </article>
        \\</div>
    ;
    var it = gridIter(html);
    const a = it.next().?;
    try std.testing.expectEqualStrings("https://s.com/anime/naruto/", a.url);
    try std.testing.expectEqualStrings("Naruto", a.title);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://c/nrt.jpg", mt.pickImageAttr(a.img_tag, "https://s.com", &buf).?);
    const b = it.next().?;
    try std.testing.expectEqualStrings("https://s.com/anime/bleach/", b.url);
    try std.testing.expectEqualStrings("Bleach", b.title);
    try std.testing.expect(it.next() == null);
}

test "GridIter: .result-item search grid (title from .title anchor when img alt empty)" {
    const html =
        \\<div class="search-page"><div class="result-item"><article>
        \\  <div class="thumbnail"><a href="/anime/one-piece/"><img src="https://c/op.jpg"></a></div>
        \\  <div class="details"><div class="title"><a href="/anime/one-piece/">One Piece</a></div></div>
        \\</article></div></div>
    ;
    var it = gridIter(html);
    const a = it.next().?;
    try std.testing.expectEqualStrings("/anime/one-piece/", a.url);
    try std.testing.expectEqualStrings("One Piece", a.title);
    try std.testing.expect(it.next() == null);
}

test "parseDetails: div.sheader title / poster / description / status" {
    const html =
        \\<div class="sheader">
        \\  <div class="poster"><img src="https://c/poster.jpg" alt="x"></div>
        \\  <div class="data"><h1>Attack on Titan</h1></div>
        \\</div>
        \\<div id="info"><div class="wp-content"><p>Humanity fights titans.</p></div></div>
        \\<div class="custom_fields"><b class="variante">Status</b><span class="valor">Ongoing</span></div>
    ;
    const d = parseDetails(html);
    try std.testing.expectEqualStrings("Attack on Titan", d.title);
    try std.testing.expectEqualStrings("Humanity fights titans.", d.description);
    try std.testing.expectEqual(mt.Status.ongoing, d.status);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://c/poster.jpg", mt.pickImageAttr(d.poster_img, "https://s.com", &buf).?);
}

test "EpisodeIter: ul.episodios li — href, numerando label, date; last is earliest" {
    const html =
        \\<div id="seasons"><div class="se-c"><span class="se-t">1</span>
        \\<ul class="episodios">
        \\  <li><div class="numerando">1 - 3</div><div class="episodiotitle"><a href="https://s.com/episode/x-1x3/">Ep 3</a><span class="date">Jan 3, 2024</span></div></li>
        \\  <li><div class="numerando">1 - 2</div><div class="episodiotitle"><a href="https://s.com/episode/x-1x2/">Ep 2</a><span class="date">Jan 2, 2024</span></div></li>
        \\  <li><div class="numerando">1 - 1</div><div class="episodiotitle"><a href="https://s.com/episode/x-1x1/">Ep 1</a><span class="date">Jan 1, 2024</span></div></li>
        \\</ul></div></div>
    ;
    var it = episodeIter(html);
    const e1 = it.next().?;
    try std.testing.expectEqualStrings("https://s.com/episode/x-1x3/", e1.url);
    try std.testing.expectEqualStrings("1 - 3", e1.label);
    try std.testing.expectEqualStrings("Jan 3, 2024", e1.date);
    var last: Episode = e1;
    var n: usize = 1;
    while (it.next()) |e| {
        last = e;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("https://s.com/episode/x-1x1/", last.url);
}

test "PlayerOptionIter: #playeroptionsul li → data-post/nume/type; build the body" {
    const html =
        \\<ul id="playeroptionsul">
        \\  <li class="dooplay_player_option" data-type="tv" data-post="8842" data-nume="1"><span class="title">Server 1</span></li>
        \\  <li class="dooplay_player_option" data-type="tv" data-post="8842" data-nume="2"><span class="title">Server 2</span></li>
        \\</ul>
    ;
    var it = playerOptionIter(html);
    const o1 = it.next().?;
    try std.testing.expectEqualStrings("8842", o1.post);
    try std.testing.expectEqualStrings("1", o1.nume);
    try std.testing.expectEqualStrings("tv", o1.type_);
    var body_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "action=doo_player_ajax&post=8842&nume=1&type=tv",
        buildAjaxBody(o1.post, o1.nume, o1.type_, &body_buf).?,
    );
    const o2 = it.next().?;
    try std.testing.expectEqualStrings("2", o2.nume);
    try std.testing.expect(it.next() == null);
}

test "malformed input never crashes" {
    var g = gridIter("<article class=\"w_item_a\"><a>no href</a>");
    try std.testing.expect(g.next() == null);
    _ = parseDetails("");
    _ = parseDetails("<div class=\"sheader\"><h1>unclosed");
    var e = episodeIter("<ul class=\"episodios\"><li>garbage");
    try std.testing.expect(e.next() == null);
    var p = playerOptionIter("<ul id=\"playeroptionsul\"><li>no data");
    try std.testing.expect(p.next() == null);
    var buf: [64]u8 = undefined;
    try std.testing.expect(parseEmbedUrl("not json", &buf) == null);
}
