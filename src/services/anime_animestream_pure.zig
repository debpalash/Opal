//! Pure (io-free, state-free) parsing for the **AnimeStream** anime engine — the
//! generic base-URL-driven scraper for the WordPress "AnimeStream" theme that
//! ~20 anime-streaming sites share. AnimeStream descends from the same Themesia
//! lineage as the manga `MangaThemesia` theme, so the search grid + details DOM
//! is IDENTICAL — this module REUSES `manga_themesia_pure`'s `SearchIter`,
//! `pickImageAttr`, `resolveUrl`, `tagAttr` and `parseDetails` rather than
//! re-writing those selectors. What is anime-specific — the episode list
//! (`.eplister li`) and the server/embed extraction — lives here.
//!
//! `anime.zig` reads the base from `source_config.get("animestream", "base")` and
//! the source stays INERT until a plugin supplies it. Every HTML/URL decision is
//! routed through here so the tested logic IS the shipped logic (no drift).
//!
//! Covers:
//!   - URL builders: `buildPopularUrl` ({base}/), `buildSearchUrl` ({base}/?s=…)
//!   - search grid: `SearchIter` (re-exported from `manga_themesia_pure`)
//!   - details: `parseDetails` / `Details` (re-exported)
//!   - episodes (`EpisodeIter`: `.eplister li` → `.epl-num` / `.epl-title` /
//!     `.epl-date`, like lightnovelwp)
//!   - the VIDEO EMBED: server `<option value="…">` values (base64-encoded iframe
//!     fragments) are decoded and the iframe `src` extracted; when no option
//!     carries an embed the first page `<iframe src>` is the fallback. The result
//!     is what `anime_extractors.resolveEmbed` / `anime.playEmbed` consume.

const std = @import("std");
const mt = @import("manga_themesia_pure.zig");
const cpure = @import("comics_pure.zig");

/// `animestream:` pseudo-URL scheme — a search card carries `animestream:<detail-url>`
/// so `anime.zig` can dispatch on the prefix (mirrors the manga `themesia:` scheme).
pub const SCHEME = "animestream:";

/// AnimeStream's search grid + details DOM is Themesia — reuse the tested engine.
pub const SearchIter = mt.SearchIter;
pub const Details = mt.Details;
pub const Status = mt.Status;
pub const parseDetails = mt.parseDetails;
pub const pickImageAttr = mt.pickImageAttr;
pub const resolveUrl = mt.resolveUrl;

// ══════════════════════════════════════════════════════════
// URL building
// ══════════════════════════════════════════════════════════

fn trimSlash(base: []const u8) []const u8 {
    if (base.len > 0 and base[base.len - 1] == '/') return base[0 .. base.len - 1];
    return base;
}

/// `{base}/` — the AnimeStream home page (popular / latest grid).
pub fn buildPopularUrl(base: []const u8, out: []u8) ?[]const u8 {
    if (base.len == 0) return null;
    return std.fmt.bufPrint(out, "{s}/", .{trimSlash(base)}) catch null;
}

/// `{base}/?s={query}` — the site-search grid (query percent-encoded, space → `+`).
pub fn buildSearchUrl(base: []const u8, query: []const u8, out: []u8) ?[]const u8 {
    if (base.len == 0) return null;
    var enc: [512]u8 = undefined;
    const n = cpure.percentEncodeQuery(query, &enc);
    return std.fmt.bufPrint(out, "{s}/?s={s}", .{ trimSlash(base), enc[0..n] }) catch null;
}

/// Convenience wrapper so `anime.zig` need not `@import` manga_themesia_pure just
/// to iterate the search grid.
pub fn searchIter(html: []const u8) SearchIter {
    return .{ .html = html };
}

// ══════════════════════════════════════════════════════════
// Minimal HTML scanning (self-contained; tested here)
// ══════════════════════════════════════════════════════════

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

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

fn innerAfterMarker(html: []const u8, from: usize, marker: []const u8) ?[]const u8 {
    const at = std.mem.indexOfPos(u8, html, from, marker) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, html, at, '>') orelse return null;
    const start = gt + 1;
    const lt = std.mem.indexOfScalarPos(u8, html, start, '<') orelse html.len;
    return std.mem.trim(u8, html[start..lt], " \t\r\n");
}

// ══════════════════════════════════════════════════════════
// Episodes (.eplister li → .epl-num / .epl-title / .epl-date)
// ══════════════════════════════════════════════════════════

pub const Episode = struct {
    /// The episode page href (resolve before use).
    url: []const u8,
    /// `.epl-num` text ("Episode 1"), else the anchor's inner text.
    num: []const u8,
    /// `.epl-title` text ("" when absent).
    title: []const u8,
    /// `.epl-date` text ("" when absent).
    date: []const u8,
};

/// Iterate `.eplister li` (`<a>` per row). Listed newest-first like lightnovelwp,
/// so the caller reverses to oldest-first.
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

            const a_lt = findElement(row, 0, "a") orelse continue;
            const a_tag = scanStartTag(row, a_lt) orelse continue;
            const href = mt.tagAttr(a_tag.text, "href") orelse continue;
            if (href.len == 0) continue;

            var num: []const u8 = innerAfterMarker(row, 0, "epl-num") orelse "";
            if (num.len == 0) {
                const lt = std.mem.indexOfScalarPos(u8, row, a_tag.after, '<') orelse row.len;
                num = std.mem.trim(u8, row[a_tag.after..lt], " \t\r\n");
            }
            const title: []const u8 = innerAfterMarker(row, 0, "epl-title") orelse "";
            const date: []const u8 = innerAfterMarker(row, 0, "epl-date") orelse "";
            return .{ .url = href, .num = num, .title = title, .date = date };
        }
        return null;
    }
};

pub fn episodeIter(html: []const u8) EpisodeIter {
    const start = std.mem.indexOf(u8, html, "eplister") orelse html.len;
    // `.eplister` wraps a <ul>; bound at its close (fall back to </div>).
    const end = std.mem.indexOfPos(u8, html, start, "</ul>") orelse
        std.mem.indexOfPos(u8, html, start, "</div>") orelse html.len;
    return .{ .html = html, .pos = start, .end = end };
}

// ══════════════════════════════════════════════════════════
// Video embed (server <option value="base64…"> → iframe src)
// ══════════════════════════════════════════════════════════

/// Base64-decode a server `<option value>` and extract the embed URL from it.
/// AnimeStream encodes each server as a base64 `<iframe src="…"></iframe>`
/// fragment. Returns the iframe `src`; if the decoded value is itself a bare URL
/// it is returned as-is. Null when the value is not valid base64 or carries no URL.
pub fn decodeServerOption(value: []const u8, out: []u8) ?[]const u8 {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (v.len == 0) return null;

    // Some skins store the URL directly (not base64).
    if (std.mem.startsWith(u8, v, "http") or std.mem.startsWith(u8, v, "//")) {
        return copyOut(v, out);
    }
    if (std.mem.startsWith(u8, v, "<iframe")) {
        if (mt.tagAttr(v, "src")) |src| return copyOut(src, out);
        return null;
    }

    // Base64 → decode into a scratch buffer, then pull the iframe src (or a URL).
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(v) catch return null;
    if (n == 0 or n > 4096) return null;
    var scratch: [4096]u8 = undefined;
    dec.decode(scratch[0..n], v) catch return null;
    const decoded = scratch[0..n];

    if (std.mem.indexOf(u8, decoded, "<iframe") != null) {
        if (mt.tagAttr(decoded, "src")) |src| {
            if (src.len == 0) return null;
            return copyOut(src, out);
        }
    }
    if (std.mem.startsWith(u8, decoded, "http") or std.mem.startsWith(u8, decoded, "//")) {
        // Trim at first whitespace/quote — decoded may be just the URL.
        var e: usize = 0;
        while (e < decoded.len and !isWs(decoded[e]) and decoded[e] != '"' and decoded[e] != '\'') e += 1;
        return copyOut(decoded[0..e], out);
    }
    return null;
}

fn copyOut(s: []const u8, out: []u8) ?[]const u8 {
    if (s.len == 0 or s.len >= out.len) return null;
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

/// The FIRST resolvable embed URL on an episode page. Preference order:
///   1. a server `<option value="…">` (base64 iframe / URL) — the mirror list;
///   2. the first raw `<iframe src="…">` on the page (fallback).
/// Returns the embed URL, or null when neither is present.
pub fn firstEmbed(html: []const u8, out: []u8) ?[]const u8 {
    // 1) Server options (`.mirror`/`.mobius` <select>): scan every `<option value>`.
    var pos: usize = 0;
    while (findElement(html, pos, "option")) |opt_lt| {
        const opt_tag = scanStartTag(html, opt_lt) orelse break;
        pos = opt_tag.after;
        const val = mt.tagAttr(opt_tag.text, "value") orelse continue;
        if (val.len == 0) continue;
        if (decodeServerOption(val, out)) |embed| return embed;
    }

    // 2) Fallback: the first iframe on the page.
    if (findElement(html, 0, "iframe")) |if_lt| {
        if (scanStartTag(html, if_lt)) |if_tag| {
            if (mt.tagAttr(if_tag.text, "src")) |src| {
                if (src.len > 0) return copyOut(src, out);
            }
        }
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "buildSearchUrl / buildPopularUrl: normalized slash, encoded query" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://a.com/", buildPopularUrl("https://a.com/", &buf).?);
    try std.testing.expectEqualStrings(
        "https://a.com/?s=jujutsu+kaisen",
        buildSearchUrl("https://a.com", "jujutsu kaisen", &buf).?,
    );
    try std.testing.expect(buildSearchUrl("", "x", &buf) == null);
}

test "search grid reuses Themesia SearchIter (.listupd .bs .bsx)" {
    const html =
        \\<div class="listupd">
        \\  <div class="bs"><div class="bsx">
        \\    <a href="/anime/frieren/" title="Frieren"><div class="limit"><img data-src="https://c/fr.jpg"></div></a>
        \\  </div></div>
        \\</div>
    ;
    var it = searchIter(html);
    const a = it.next().?;
    try std.testing.expectEqualStrings("/anime/frieren/", a.url);
    try std.testing.expectEqualStrings("Frieren", a.title);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://c/fr.jpg", pickImageAttr(a.img_tag, "https://a.com", &buf).?);
    try std.testing.expect(it.next() == null);
}

test "parseDetails reused from Themesia (title/status/description)" {
    const html =
        \\<h1 class="entry-title">Frieren</h1>
        \\<div class="tsinfo"><div class="imptdt">Status <i>Completed</i></div></div>
        \\<div itemprop="description"><p>A journey after the hero.</p></div>
    ;
    const d = parseDetails(html);
    try std.testing.expectEqualStrings("Frieren", d.title);
    try std.testing.expectEqual(Status.completed, d.status);
    try std.testing.expectEqualStrings("A journey after the hero.", d.description);
}

test "EpisodeIter: .eplister li — href, epl-num, epl-title, epl-date; last is earliest" {
    const html =
        \\<div class="eplister"><ul>
        \\  <li><a href="https://a.com/frieren-episode-3/"><div class="epl-num">Episode 3</div><div class="epl-title">Killing Magic</div><div class="epl-date">Oct 20, 2023</div></a></li>
        \\  <li><a href="https://a.com/frieren-episode-2/"><div class="epl-num">Episode 2</div><div class="epl-title">Priest's Lie</div><div class="epl-date">Oct 13, 2023</div></a></li>
        \\  <li><a href="https://a.com/frieren-episode-1/"><div class="epl-num">Episode 1</div><div class="epl-title">The Journey's End</div><div class="epl-date">Sep 29, 2023</div></a></li>
        \\</ul></div>
    ;
    var it = episodeIter(html);
    const e1 = it.next().?;
    try std.testing.expectEqualStrings("https://a.com/frieren-episode-3/", e1.url);
    try std.testing.expectEqualStrings("Episode 3", e1.num);
    try std.testing.expectEqualStrings("Killing Magic", e1.title);
    try std.testing.expectEqualStrings("Oct 20, 2023", e1.date);
    var last: Episode = e1;
    var n: usize = 1;
    while (it.next()) |e| {
        last = e;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("https://a.com/frieren-episode-1/", last.url);
    try std.testing.expectEqualStrings("Episode 1", last.num);
}

test "decodeServerOption: base64 iframe fragment → src" {
    // base64 of: <iframe src="https://filemoon.sx/e/abc123"></iframe>
    const b64 = "PGlmcmFtZSBzcmM9Imh0dHBzOi8vZmlsZW1vb24uc3gvZS9hYmMxMjMiPjwvaWZyYW1lPg==";
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://filemoon.sx/e/abc123", decodeServerOption(b64, &buf).?);
    // Plain URL stored directly.
    try std.testing.expectEqualStrings(
        "https://streamwish.to/e/xyz",
        decodeServerOption("https://streamwish.to/e/xyz", &buf).?,
    );
    // Garbage → null (never crashes).
    try std.testing.expect(decodeServerOption("!!!not base64!!!", &buf) == null);
    try std.testing.expect(decodeServerOption("", &buf) == null);
}

test "firstEmbed: prefers a decoded server option over a raw iframe" {
    // <select class="mirror"> with a base64 option, plus a decoy player iframe.
    const b64 = "PGlmcmFtZSBzcmM9Imh0dHBzOi8vZG9vZHN0cmVhbS5jb20vZS9xMSI+PC9pZnJhbWU+"; // dood q1
    const html = std.fmt.comptimePrint(
        \\<div class="player">
        \\  <select class="mirror"><option value="">Choose</option><option value="{s}">Doodstream</option></select>
        \\  <div class="player-embed"><iframe src="https://ads.example/decoy"></iframe></div>
        \\</div>
    , .{b64});
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://doodstream.com/e/q1", firstEmbed(html, &buf).?);
}

test "firstEmbed: falls back to the first raw iframe when no server options" {
    const html =
        \\<div class="player-embed"><iframe class="metaframe" src="https://megacloud.blog/embed-2/e-1/zzz?k=1" allowfullscreen></iframe></div>
    ;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://megacloud.blog/embed-2/e-1/zzz?k=1", firstEmbed(html, &buf).?);
    // Nothing playable → null.
    try std.testing.expect(firstEmbed("<div>no player here</div>", &buf) == null);
}

test "malformed input never crashes" {
    var e = episodeIter("<div class=\"eplister\"><ul><li>garbage");
    try std.testing.expect(e.next() == null);
    var buf: [64]u8 = undefined;
    try std.testing.expect(firstEmbed("", &buf) == null);
    try std.testing.expect(firstEmbed("<option value=\"\">x</option>", &buf) == null);
}
