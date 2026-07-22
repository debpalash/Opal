//! Pure (io-free, state-free) comics helpers — unit-testable via `zig build test`.
//!
//! The production code in `comics.zig` calls into these so the tested logic IS
//! the shipped logic (no drift). Covers:
//!   - percent-encoding for search queries (both `+` and `%20` space flavours)
//!   - the MangaDex source: URL building (search / chapter feed / at-home /
//!     cover / page) + allocation-free JSON scanning of its responses
//!   - the `mangadex:<uuid>` pseudo-URL scheme that routes a search-result card
//!     into the MangaDex reader path instead of the generic curl+HTML scraper
//!
//! MangaDex is a keyless, documented public API (https://api.mangadex.org/docs)
//! — no key slot needed, so unlike `readallcomics` it is NOT gated behind
//! `source_config` and works out of the box.
//!
//! Everything here is fixed-buffer / no-allocation, matching the project's
//! `[N]u8 + len` convention.

const std = @import("std");

// ══════════════════════════════════════════════════════════
// Percent-encoding
// ══════════════════════════════════════════════════════════

const HEX = "0123456789ABCDEF";

fn isUnreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
}

/// Percent-encode a query value, mapping space → `+` (form-encoded flavour).
/// This is the encoder the readallcomics WordPress endpoint has always used;
/// `comics.percentEncode` delegates here so the shipped behaviour is tested.
/// Encodes at minimum: space, `&`, `=`, `#`, `?`, `%`, `+`, `"`, `<`, `>`.
pub fn percentEncodeQuery(input: []const u8, out: []u8) usize {
    var o: usize = 0;
    for (input) |ch| {
        if (ch == ' ') {
            if (o + 1 > out.len) break;
            out[o] = '+';
            o += 1;
        } else if (isUnreserved(ch)) {
            if (o + 1 > out.len) break;
            out[o] = ch;
            o += 1;
        } else {
            if (o + 3 > out.len) break;
            out[o] = '%';
            out[o + 1] = HEX[ch >> 4];
            out[o + 2] = HEX[ch & 0x0F];
            o += 3;
        }
    }
    return o;
}

/// Percent-encode a query value, mapping space → `%20` (RFC 3986 flavour).
/// MangaDex's `?title=` param is a plain query value, so `%20` is the safe
/// spelling (`+` is only defined as space in form bodies).
pub fn percentEncodeStrict(input: []const u8, out: []u8) usize {
    var o: usize = 0;
    for (input) |ch| {
        if (isUnreserved(ch)) {
            if (o + 1 > out.len) break;
            out[o] = ch;
            o += 1;
        } else {
            if (o + 3 > out.len) break;
            out[o] = '%';
            out[o + 1] = HEX[ch >> 4];
            out[o + 2] = HEX[ch & 0x0F];
            o += 3;
        }
    }
    return o;
}

// ══════════════════════════════════════════════════════════
// Allocation-free JSON scanning
// ══════════════════════════════════════════════════════════

/// Skip a JSON string that starts at `buf[i]` == '"'. Returns the index just
/// past the closing quote, honouring backslash escapes. Used by the structural
/// scanners so a `{`/`[` inside a string literal never moves the depth counter.
fn skipString(buf: []const u8, i: usize) usize {
    var p = i + 1;
    while (p < buf.len) : (p += 1) {
        if (buf[p] == '\\') {
            p += 1; // skip the escaped char
            continue;
        }
        if (buf[p] == '"') return p + 1;
    }
    return buf.len;
}

/// Return the balanced `{…}` / `[…]` span starting at `buf[start]` (inclusive of
/// both delimiters), or null if unbalanced. String-aware.
fn balancedSpan(buf: []const u8, start: usize) ?[]const u8 {
    if (start >= buf.len) return null;
    const open = buf[start];
    const close: u8 = switch (open) {
        '{' => '}',
        '[' => ']',
        else => return null,
    };
    var depth: usize = 0;
    var i = start;
    while (i < buf.len) {
        const c = buf[i];
        if (c == '"') {
            i = skipString(buf, i);
            continue;
        }
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return buf[start .. i + 1];
        }
        i += 1;
    }
    return null;
}

/// Raw (still-escaped) value of the string field `"key":"…"`, searched from
/// `from`. Returns the slice between the quotes. `key` is matched WITH its
/// quotes+colon (e.g. `"\"hash\":\""`) by the callers below, so `"data":[` can
/// never be confused with `"dataSaver":[`.
pub fn findJsonStr(json: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const vs = at + needle.len;
    var i = vs;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1;
            continue;
        }
        if (json[i] == '"') return json[vs..i];
    }
    return null;
}

/// The balanced object/array payload of `"key":{…}` / `"key":[…]`.
pub fn findJsonNode(json: []const u8, key: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, json, search_from, key)) |at| {
        var p = at + key.len;
        while (p < json.len and (json[p] == ' ' or json[p] == ':')) p += 1;
        if (p < json.len and (json[p] == '{' or json[p] == '[')) {
            if (balancedSpan(json, p)) |span| return span;
        }
        search_from = at + key.len;
    }
    return null;
}

/// Iterate the top-level `{…}` objects of a JSON array payload (`[{…},{…}]`).
pub const ObjIter = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(self: *ObjIter) ?[]const u8 {
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            if (c == '"') {
                self.pos = skipString(self.buf, self.pos);
                continue;
            }
            if (c == '{') {
                const span = balancedSpan(self.buf, self.pos) orelse return null;
                self.pos += span.len;
                return span;
            }
            self.pos += 1;
        }
        return null;
    }
};

/// Iterate the string elements of a JSON array payload (`["a","b"]`), returning
/// each raw (still-escaped) element.
pub const StrIter = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(self: *StrIter) ?[]const u8 {
        while (self.pos < self.buf.len) {
            if (self.buf[self.pos] == '"') {
                const end = skipString(self.buf, self.pos);
                const s = self.buf[self.pos + 1 .. end - 1];
                self.pos = end;
                return s;
            }
            self.pos += 1;
        }
        return null;
    }
};

/// Decode JSON string escapes (`\/`, `\"`, `\\`, `\n`, `\t`, `\uXXXX`) into
/// `out`; returns bytes written. `\uXXXX` is emitted as UTF-8 (surrogate pairs
/// are combined). MangaDex escapes every `/` in `baseUrl` and emits `\uXXXX`
/// for non-ASCII titles, so both paths are load-bearing.
pub fn jsonUnescape(in: []const u8, out: []u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    while (i < in.len and o < out.len) {
        if (in[i] != '\\' or i + 1 >= in.len) {
            out[o] = in[i];
            o += 1;
            i += 1;
            continue;
        }
        const e = in[i + 1];
        switch (e) {
            '"', '\\', '/' => {
                out[o] = e;
                o += 1;
                i += 2;
            },
            'n' => {
                out[o] = '\n';
                o += 1;
                i += 2;
            },
            't' => {
                out[o] = '\t';
                o += 1;
                i += 2;
            },
            'r' => {
                out[o] = '\r';
                o += 1;
                i += 2;
            },
            'b', 'f' => {
                out[o] = ' ';
                o += 1;
                i += 2;
            },
            'u' => {
                if (i + 6 > in.len) break;
                var cp: u21 = std.fmt.parseInt(u16, in[i + 2 .. i + 6], 16) catch {
                    i += 6;
                    continue;
                };
                i += 6;
                // Combine a surrogate pair into one code point.
                if (cp >= 0xD800 and cp <= 0xDBFF and i + 6 <= in.len and
                    in[i] == '\\' and in[i + 1] == 'u')
                {
                    const lo = std.fmt.parseInt(u16, in[i + 2 .. i + 6], 16) catch 0;
                    if (lo >= 0xDC00 and lo <= 0xDFFF) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        i += 6;
                    }
                }
                // Lone surrogate → not encodable; skip it rather than emit invalid UTF-8.
                if (cp >= 0xD800 and cp <= 0xDFFF) continue;
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &tmp) catch continue;
                if (o + n > out.len) break;
                @memcpy(out[o .. o + n], tmp[0..n]);
                o += n;
            },
            else => {
                out[o] = e;
                o += 1;
                i += 2;
            },
        }
    }
    return o;
}

// ══════════════════════════════════════════════════════════
// MangaDex — https://api.mangadex.org (keyless public API)
// ══════════════════════════════════════════════════════════

pub const MD_API = "https://api.mangadex.org";
pub const MD_UPLOADS = "https://uploads.mangadex.org";

/// `mangadex:` pseudo-URL scheme. A MangaDex search result can't be read by the
/// generic curl+HTML scraper (its pages come from a 3-call JSON chain), so cards
/// carry `mangadex:<manga-uuid>` and `comics.fetchComicThread` dispatches on the
/// prefix. Keeps the reader's page pipeline (downloadPages) completely unchanged.
pub const MD_SCHEME = "mangadex:";

// ── User-Agent selection ──
//
// The scrapers spoof a browser UA to get past Cloudflare. MangaDex does the
// EXACT OPPOSITE: `api.mangadex.org` and `uploads.mangadex.org` answer **400**
// to a browser UA (a Chrome UA with a non-browser TLS fingerprint reads as a
// spoofing bot) and 200 to an honest API-client UA. Both were verified live —
// sending the browser UA breaks MangaDex search AND its cover art.
//
// So the UA is per-HOST, not global: keep the browser UA for the HTML scrapers,
// send an identifying UA to MangaDex (which is also what its docs ask for).
pub const UA_BROWSER = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
pub const UA_OPAL = "Opal/1.0 (+https://github.com/debpalash/Opal)";

/// The User-Agent to send for `url`. MangaDex hosts get the identifying UA; every
/// other host keeps the browser UA the scrapers rely on.
pub fn userAgentFor(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "mangadex.") != null) return UA_OPAL;
    return UA_BROWSER;
}

/// A MangaDex id is a canonical lowercase UUID. Validating it is a security gate,
/// not a nicety: the id is interpolated straight into a request path, so anything
/// with a `/`, `?`, `.` or `%` could escape the intended endpoint.
pub fn isValidId(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (ch != '-') return false;
        } else if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) {
            return false;
        }
    }
    return true;
}

/// Build the `mangadex:<uuid>` route URL a search-result card stores.
pub fn buildRouteUrl(out: []u8, manga_id: []const u8) ?[]const u8 {
    if (!isValidId(manga_id)) return null;
    return std.fmt.bufPrint(out, "{s}{s}", .{ MD_SCHEME, manga_id }) catch null;
}

/// Extract the manga uuid from a `mangadex:<uuid>` route URL (null if it isn't
/// one, or if the id doesn't validate).
pub fn mangaIdFromRoute(url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, MD_SCHEME)) return null;
    const id = url[MD_SCHEME.len..];
    if (!isValidId(id)) return null;
    return id;
}

/// MangaDex spells its array/map params `includes[]` / `order[relevance]`. Those
/// brackets MUST be percent-encoded: we fetch by exec'ing `curl`, and curl treats
/// a bare `[...]` in a URL as a glob RANGE — `order[relevance]` makes it abort
/// with exit 3 ("bad range") before a request is ever sent. `%5B`/`%5D` is both
/// RFC-3986-correct and glob-inert. (Empty `[]` happens to survive curl's globber,
/// but encoding every bracket keeps the rule simple and the URLs uniform.)
const INCLUDES_COVER = "&includes%5B%5D=cover_art";
const CONTENT_RATING = "&contentRating%5B%5D=safe&contentRating%5B%5D=suggestive";

/// Search endpoint. `offset` paginates (the grid's infinite scroll walks it in
/// `limit`-sized steps). Content is capped at safe+suggestive.
pub fn buildSearchUrl(out: []u8, query: []const u8, limit: u32, offset: u32) ?[]const u8 {
    if (query.len == 0) return null;
    var enc: [512]u8 = undefined;
    const n = percentEncodeStrict(query, &enc);
    if (n == 0) return null;
    return std.fmt.bufPrint(
        out,
        "{s}/manga?title={s}&limit={d}&offset={d}" ++
            INCLUDES_COVER ++ CONTENT_RATING ++
            "&order%5Brelevance%5D=desc",
        .{ MD_API, enc[0..n], limit, offset },
    ) catch null;
}

/// Chapter feed for one manga, oldest chapter first — the reader opens ch. 1.
pub fn buildFeedUrl(out: []u8, manga_id: []const u8, limit: u32, offset: u32) ?[]const u8 {
    if (!isValidId(manga_id)) return null;
    return std.fmt.bufPrint(
        out,
        "{s}/manga/{s}/feed?translatedLanguage%5B%5D=en&order%5Bchapter%5D=asc" ++
            "&limit={d}&offset={d}" ++ CONTENT_RATING,
        .{ MD_API, manga_id, limit, offset },
    ) catch null;
}

/// The @Home node that actually serves a chapter's page images.
pub fn buildAtHomeUrl(out: []u8, chapter_id: []const u8) ?[]const u8 {
    if (!isValidId(chapter_id)) return null;
    return std.fmt.bufPrint(out, "{s}/at-home/server/{s}", .{ MD_API, chapter_id }) catch null;
}

/// Cover art. `.512.jpg` is a server-rendered thumbnail — the full-size original
/// is multiple MB, far more than a grid card needs.
pub fn buildCoverUrl(out: []u8, manga_id: []const u8, file_name: []const u8) ?[]const u8 {
    if (!isValidId(manga_id)) return null;
    if (file_name.len == 0 or file_name.len > 128) return null;
    if (std.mem.indexOfScalar(u8, file_name, '/') != null) return null; // path-escape guard
    if (std.mem.indexOfScalar(u8, file_name, '"') != null) return null;
    return std.fmt.bufPrint(out, "{s}/covers/{s}/{s}.512.jpg", .{ MD_UPLOADS, manga_id, file_name }) catch null;
}

/// One page image: `{baseUrl}/data/{hash}/{filename}`.
pub fn buildPageUrl(out: []u8, base_url: []const u8, hash: []const u8, file_name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, base_url, "https://")) return null;
    if (hash.len == 0 or hash.len > 64) return null;
    if (file_name.len == 0 or file_name.len > 160) return null;
    for (hash) |c| if (!std.ascii.isAlphanumeric(c)) return null;
    if (std.mem.indexOfScalar(u8, file_name, '/') != null) return null;
    return std.fmt.bufPrint(out, "{s}/data/{s}/{s}", .{ base_url, hash, file_name }) catch null;
}

/// One parsed row of a `/manga` search response.
pub const MangaEntry = struct {
    id: []const u8,
    /// Raw (still JSON-escaped) display title — run through `jsonUnescape`.
    title: []const u8,
    /// Raw cover filename ("" when the manga has no cover_art relationship).
    cover_file: []const u8,
};

/// Parse one manga object out of a `/manga` response's `data[]`.
///
/// Field order in the live response is
///   {"id":…,"type":"manga","attributes":{"title":{…},"altTitles":[…],…},
///    "relationships":[{"id":…,"type":"cover_art","attributes":{"fileName":…}}]}
/// so: the manga id is the object's FIRST `"id"`, and the cover filename is the
/// first `"fileName"` AFTER the `"type":"cover_art"` marker (a manga also has
/// author/artist relationships, which carry no fileName — searching forward from
/// the cover_art marker is what keeps them from being mistaken for the cover).
pub fn parseMangaEntry(obj: []const u8) ?MangaEntry {
    const id = findJsonStr(obj, "\"id\":\"") orelse return null;
    if (!isValidId(id)) return null;

    // Title: prefer the English entry, else the first localisation present
    // (MangaDex often keys the canonical title as "ja-ro" romaji with no "en").
    var title: []const u8 = "";
    if (findJsonNode(obj, "\"title\"")) |tnode| {
        if (findJsonStr(tnode, "\"en\":\"")) |en| {
            title = en;
        } else if (std.mem.indexOfScalar(u8, tnode, ':')) |c| {
            // First value in the title map, whatever its language key is.
            var i = c + 1;
            while (i < tnode.len and tnode[i] != '"') i += 1;
            if (i < tnode.len) {
                const end = skipString(tnode, i);
                if (end > i + 1) title = tnode[i + 1 .. end - 1];
            }
        }
    }
    if (title.len == 0) return null;

    var cover: []const u8 = "";
    if (std.mem.indexOf(u8, obj, "\"type\":\"cover_art\"")) |ca| {
        if (findJsonStr(obj[ca..], "\"fileName\":\"")) |fn_| cover = fn_;
    }

    return .{ .id = id, .title = title, .cover_file = cover };
}

/// The id of the first chapter in a `/manga/{id}/feed` response (the feed is
/// requested `order[chapter]=asc`, so element 0 is the earliest chapter).
pub fn firstChapterId(json: []const u8) ?[]const u8 {
    const data = findJsonNode(json, "\"data\"") orelse return null;
    var it = ObjIter{ .buf = data };
    const first = it.next() orelse return null;
    const id = findJsonStr(first, "\"id\":\"") orelse return null;
    if (!isValidId(id)) return null;
    return id;
}

/// The human chapter number of the first feed entry ("1", "153", …), for the
/// reader's title line. Null when the chapter is unnumbered (`"chapter":null`).
pub fn firstChapterNumber(json: []const u8) ?[]const u8 {
    const data = findJsonNode(json, "\"data\"") orelse return null;
    var it = ObjIter{ .buf = data };
    const first = it.next() orelse return null;
    return findJsonStr(first, "\"chapter\":\"");
}

/// A parsed `/at-home/server/{id}` response: where the page images live.
pub const AtHome = struct {
    /// Unescaped base URL (MangaDex escapes every `/` as `\/`).
    base_url: []const u8,
    hash: []const u8,
    /// The `chapter.data[]` array payload — walk it with `StrIter`.
    files: []const u8,
};

/// Parse `/at-home/server/{id}`. `base_buf` receives the unescaped baseUrl.
///
/// The `"data"` lookup is deliberately scoped to the `chapter` object: the
/// response ALSO carries `"dataSaver"` (lower-quality duplicates) — and a bare
/// `indexOf("\"data\"")` on the whole body would still hit `"data"` first, but
/// scoping documents the intent and survives future field reordering.
pub fn parseAtHome(json: []const u8, base_buf: []u8) ?AtHome {
    const raw_base = findJsonStr(json, "\"baseUrl\":\"") orelse return null;
    const bn = jsonUnescape(raw_base, base_buf);
    if (bn == 0) return null;
    const base = base_buf[0..bn];
    if (!std.mem.startsWith(u8, base, "https://")) return null;

    const chapter = findJsonNode(json, "\"chapter\"") orelse return null;
    const hash = findJsonStr(chapter, "\"hash\":\"") orelse return null;
    const files = findJsonNode(chapter, "\"data\"") orelse return null;
    return .{ .base_url = base, .hash = hash, .files = files };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "percentEncodeQuery: space→+ and reserved chars escaped" {
    var out: [64]u8 = undefined;
    const n = percentEncodeQuery("spider man & co", &out);
    try std.testing.expectEqualStrings("spider+man+%26+co", out[0..n]);
}

test "percentEncodeStrict: space→%20 (MangaDex query flavour)" {
    var out: [64]u8 = undefined;
    const n = percentEncodeStrict("one punch man", &out);
    try std.testing.expectEqualStrings("one%20punch%20man", out[0..n]);
}

test "percentEncodeStrict: unreserved chars pass through untouched" {
    var out: [64]u8 = undefined;
    const n = percentEncodeStrict("a-z_0.9~Z", &out);
    try std.testing.expectEqualStrings("a-z_0.9~Z", out[0..n]);
}

test "percentEncode: query-param injection is neutralised" {
    // A query that tries to smuggle an extra param must come back inert.
    var out: [128]u8 = undefined;
    const n = percentEncodeStrict("x&limit=999#f?q=1", &out);
    try std.testing.expectEqualStrings("x%26limit%3D999%23f%3Fq%3D1", out[0..n]);
    try std.testing.expect(std.mem.indexOfScalar(u8, out[0..n], '&') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out[0..n], '=') == null);
}

test "percentEncode: truncates cleanly on a short buffer (no partial escape)" {
    var out: [4]u8 = undefined;
    const n = percentEncodeStrict("aa&&&", &out);
    // 'a','a' fit; the 3-byte "%26" fits exactly once more? no — only 2 bytes left.
    try std.testing.expectEqualStrings("aa", out[0..n]);
}

test "isValidId: canonical lowercase uuid only" {
    try std.testing.expect(isValidId("b7d069cb-4ab9-4c21-a20b-38f7c269be4e"));
    try std.testing.expect(!isValidId("")); // empty
    try std.testing.expect(!isValidId("b7d069cb4ab94c21a20b38f7c269be4e")); // no dashes
    try std.testing.expect(!isValidId("B7D069CB-4AB9-4C21-A20B-38F7C269BE4E")); // uppercase
    try std.testing.expect(!isValidId("b7d069cb-4ab9-4c21-a20b-38f7c269be4")); // short
}

test "isValidId: path traversal / injection ids are rejected" {
    // These are the reason the id is validated before it hits a request path.
    try std.testing.expect(!isValidId("../../../etc/passwd"));
    try std.testing.expect(!isValidId("b7d069cb-4ab9-4c21-a20b-38f7c269be/e"));
    try std.testing.expect(!isValidId("b7d069cb-4ab9-4c21-a20b-38f7c269be?e"));
}

test "route url: build → parse round-trip" {
    var buf: [64]u8 = undefined;
    const id = "801513ba-a712-498c-8f57-cae55b38cc92";
    const url = buildRouteUrl(&buf, id).?;
    try std.testing.expectEqualStrings("mangadex:801513ba-a712-498c-8f57-cae55b38cc92", url);
    try std.testing.expectEqualStrings(id, mangaIdFromRoute(url).?);
}

test "route url: non-mangadex and malformed urls are not claimed" {
    try std.testing.expect(mangaIdFromRoute("https://example.com/x") == null);
    try std.testing.expect(mangaIdFromRoute("mangadex:not-a-uuid") == null);
    try std.testing.expect(mangaIdFromRoute("mangadex:") == null);
    var rbuf: [64]u8 = undefined;
    try std.testing.expect(buildRouteUrl(&rbuf, "bogus") == null);
}

test "buildSearchUrl: encodes the query and carries limit/offset" {
    var buf: [512]u8 = undefined;
    const url = buildSearchUrl(&buf, "one punch man", 20, 40).?;
    try std.testing.expect(std.mem.startsWith(u8, url, "https://api.mangadex.org/manga?title=one%20punch%20man"));
    try std.testing.expect(std.mem.indexOf(u8, url, "&limit=20&offset=40") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "includes%5B%5D=cover_art") != null);
}

test "regression: NO raw [ or ] in any built URL (curl glob-aborts on them)" {
    // The bug: `order[relevance]=desc` / `order[chapter]=asc` made curl treat the
    // brackets as a glob RANGE and exit 3 ("bad range specification") WITHOUT ever
    // sending a request — search and the chapter feed were dead on arrival. Unit
    // tests passed the whole time because nothing here shells out; only a live
    // request caught it. Lock every builder against a raw bracket.
    const id = "801513ba-a712-498c-8f57-cae55b38cc92";

    var b1: [768]u8 = undefined;
    var b2: [768]u8 = undefined;
    var b3: [768]u8 = undefined;
    const search = buildSearchUrl(&b1, "one punch man", 20, 0).?;
    const feed = buildFeedUrl(&b2, id, 1, 0).?;
    const athome = buildAtHomeUrl(&b3, id).?;

    for ([_][]const u8{ search, feed, athome }) |u| {
        try std.testing.expect(std.mem.indexOfScalar(u8, u, '[') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, u, ']') == null);
    }
    // …and the params still made it through, percent-encoded.
    try std.testing.expect(std.mem.indexOf(u8, search, "order%5Brelevance%5D=desc") != null);
    try std.testing.expect(std.mem.indexOf(u8, feed, "order%5Bchapter%5D=asc") != null);
    try std.testing.expect(std.mem.indexOf(u8, feed, "translatedLanguage%5B%5D=en") != null);
}

test "regression: MangaDex hosts get the API UA, scrapers keep the browser UA" {
    // The bug: sending the spoofed Chrome UA to api.mangadex.org / uploads.
    // mangadex.org returns 400 (Cloudflare reads browser-UA + non-browser-TLS as a
    // bot), so search returned nothing and every cover was blank. Verified live.
    var buf: [768]u8 = undefined;
    const id = "801513ba-a712-498c-8f57-cae55b38cc92";

    try std.testing.expectEqualStrings(UA_OPAL, userAgentFor(buildSearchUrl(&buf, "x", 20, 0).?));
    try std.testing.expectEqualStrings(UA_OPAL, userAgentFor(buildFeedUrl(&buf, id, 1, 0).?));
    try std.testing.expectEqualStrings(UA_OPAL, userAgentFor(buildAtHomeUrl(&buf, id).?));
    try std.testing.expectEqualStrings(UA_OPAL, userAgentFor(buildCoverUrl(&buf, id, "c.jpg").?));
    // The page CDN is a different host (…mangadex.network) — it accepts either,
    // but it is still MangaDex, so it gets the honest UA too.
    try std.testing.expectEqualStrings(UA_OPAL, userAgentFor("https://cmdxd98sb0x3yprd.mangadex.network/data/h/1.png"));
    // Everything else — the HTML scrapers and their blogspot CDN — MUST keep the
    // browser UA (they rely on it to get past Cloudflare).
    try std.testing.expectEqualStrings(UA_BROWSER, userAgentFor("https://readallcomics.com/invincible-001/"));
    try std.testing.expectEqualStrings(UA_BROWSER, userAgentFor("https://1.bp.blogspot.com/x.jpg"));
}

test "buildSearchUrl: empty query yields no request" {
    var buf: [512]u8 = undefined;
    try std.testing.expect(buildSearchUrl(&buf, "", 20, 0) == null);
}

test "buildFeedUrl / buildAtHomeUrl: valid ids only" {
    var buf: [512]u8 = undefined;
    const id = "801513ba-a712-498c-8f57-cae55b38cc92";
    const feed = buildFeedUrl(&buf, id, 1, 0).?;
    try std.testing.expect(std.mem.indexOf(u8, feed, "/manga/801513ba-a712-498c-8f57-cae55b38cc92/feed") != null);
    try std.testing.expect(std.mem.indexOf(u8, feed, "order%5Bchapter%5D=asc") != null);

    var buf2: [512]u8 = undefined;
    const ah = buildAtHomeUrl(&buf2, id).?;
    try std.testing.expectEqualStrings("https://api.mangadex.org/at-home/server/801513ba-a712-498c-8f57-cae55b38cc92", ah);

    // A bogus id must never reach the network.
    var buf3: [512]u8 = undefined;
    try std.testing.expect(buildFeedUrl(&buf3, "../admin", 1, 0) == null);
    try std.testing.expect(buildAtHomeUrl(&buf3, "../admin") == null);
}

test "buildCoverUrl: thumbnail variant, path-escape rejected" {
    var buf: [256]u8 = undefined;
    const id = "30196491-8fc2-4961-8886-a58f898b1b3e";
    const url = buildCoverUrl(&buf, id, "1790f17f-9184-4a48-8928-c45de48b778e.jpg").?;
    try std.testing.expectEqualStrings(
        "https://uploads.mangadex.org/covers/30196491-8fc2-4961-8886-a58f898b1b3e/1790f17f-9184-4a48-8928-c45de48b778e.jpg.512.jpg",
        url,
    );
    try std.testing.expect(buildCoverUrl(&buf, id, "../../etc/passwd") == null);
    try std.testing.expect(buildCoverUrl(&buf, id, "") == null);
}

test "buildPageUrl: {base}/data/{hash}/{file}" {
    var buf: [512]u8 = undefined;
    const url = buildPageUrl(
        &buf,
        "https://cmdxd98sb0x3yprd.mangadex.network",
        "5e952006b8c67e24fb385d3023162577",
        "1-11e1d12a.png",
    ).?;
    try std.testing.expectEqualStrings(
        "https://cmdxd98sb0x3yprd.mangadex.network/data/5e952006b8c67e24fb385d3023162577/1-11e1d12a.png",
        url,
    );
}

test "buildPageUrl: rejects non-https base, bad hash, path-escaping filename" {
    var buf: [512]u8 = undefined;
    try std.testing.expect(buildPageUrl(&buf, "http://evil.test", "abc123", "1.png") == null);
    try std.testing.expect(buildPageUrl(&buf, "https://ok.test", "ab/../c", "1.png") == null);
    try std.testing.expect(buildPageUrl(&buf, "https://ok.test", "abc123", "../../1.png") == null);
}

test "jsonUnescape: escaped slashes (MangaDex baseUrl)" {
    var out: [128]u8 = undefined;
    const n = jsonUnescape("https:\\/\\/cmdxd98sb0x3yprd.mangadex.network", &out);
    try std.testing.expectEqualStrings("https://cmdxd98sb0x3yprd.mangadex.network", out[0..n]);
}

test "jsonUnescape: \\uXXXX → UTF-8, incl. surrogate pairs" {
    var out: [64]u8 = undefined;
    // U+00E9 (2-byte UTF-8) and U+1D11E, an astral codepoint that JSON can only
    // spell as a surrogate PAIR (4-byte UTF-8). Both sides are written as raw
    // byte escapes so no non-ASCII literal ever appears in a string.
    const n = jsonUnescape("caf\\u00e9 \\ud834\\udd1e", &out);
    try std.testing.expectEqualStrings("caf\xc3\xa9 \xf0\x9d\x84\x9e", out[0..n]);
}

test "jsonUnescape: a lone surrogate is dropped, not emitted as bad UTF-8" {
    // A truncated/lone surrogate would otherwise produce invalid UTF-8 and crash
    // dvui's text shaper downstream.
    var out: [32]u8 = undefined;
    const n = jsonUnescape("a\\ud834b", &out);
    try std.testing.expectEqualStrings("ab", out[0..n]);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out[0..n]));
}

test "jsonUnescape: quotes/backslashes survive (title with a quote)" {
    var out: [64]u8 = undefined;
    const n = jsonUnescape("He said \\\"hi\\\"", &out);
    try std.testing.expectEqualStrings("He said \"hi\"", out[0..n]);
}

test "findJsonNode: \"data\" is not confused with \"dataSaver\"" {
    // Regression: a naive substring search for `"data"` inside the chapter object
    // could latch onto `"dataSaver"` if the fields were reordered, silently
    // serving the low-quality images (or, worse, a mismatched file list).
    const json =
        \\{"chapter":{"hash":"h1","dataSaver":["s1.jpg","s2.jpg"],"data":["p1.png","p2.png"]}}
    ;
    const chapter = findJsonNode(json, "\"chapter\"").?;
    const files = findJsonNode(chapter, "\"data\"").?;
    var it = StrIter{ .buf = files };
    try std.testing.expectEqualStrings("p1.png", it.next().?);
    try std.testing.expectEqualStrings("p2.png", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "parseAtHome: full live-shaped response" {
    const json =
        \\{"result":"ok","baseUrl":"https:\/\/cmdxd98sb0x3yprd.mangadex.network","chapter":{"hash":"5e952006b8c67e24fb385d3023162577","data":["1-a.png","2-b.png","3-c.png"],"dataSaver":["1-x.jpg"]}}
    ;
    var base_buf: [256]u8 = undefined;
    const ah = parseAtHome(json, &base_buf).?;
    try std.testing.expectEqualStrings("https://cmdxd98sb0x3yprd.mangadex.network", ah.base_url);
    try std.testing.expectEqualStrings("5e952006b8c67e24fb385d3023162577", ah.hash);

    var it = StrIter{ .buf = ah.files };
    var page_buf: [512]u8 = undefined;
    const first = it.next().?;
    const url = buildPageUrl(&page_buf, ah.base_url, ah.hash, first).?;
    try std.testing.expectEqualStrings(
        "https://cmdxd98sb0x3yprd.mangadex.network/data/5e952006b8c67e24fb385d3023162577/1-a.png",
        url,
    );
    var count: usize = 1;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "parseAtHome: malformed / error responses return null (no crash)" {
    var base_buf: [256]u8 = undefined;
    try std.testing.expect(parseAtHome("", &base_buf) == null);
    try std.testing.expect(parseAtHome("{\"result\":\"error\"}", &base_buf) == null);
    // baseUrl present but chapter object missing
    try std.testing.expect(parseAtHome("{\"baseUrl\":\"https:\\/\\/a.test\"}", &base_buf) == null);
    // http (not https) base is refused
    try std.testing.expect(parseAtHome(
        "{\"baseUrl\":\"http:\\/\\/a.test\",\"chapter\":{\"hash\":\"h\",\"data\":[\"1.png\"]}}",
        &base_buf,
    ) == null);
    // truncated body (connection cut mid-JSON) — unbalanced braces must not hang/crash
    try std.testing.expect(parseAtHome(
        "{\"baseUrl\":\"https:\\/\\/a.test\",\"chapter\":{\"hash\":\"h\",\"data\":[\"1.p",
        &base_buf,
    ) == null);
}

test "parseMangaEntry: id + english title + cover filename" {
    const obj =
        \\{"id":"801513ba-a712-498c-8f57-cae55b38cc92","type":"manga","attributes":{"title":{"en":"Berserk"},"altTitles":[{"ja":"x"}],"description":{"en":"d"}},"relationships":[{"id":"aaaaaaaa-a712-498c-8f57-cae55b38cc92","type":"author"},{"id":"bbbbbbbb-a712-498c-8f57-cae55b38cc92","type":"cover_art","attributes":{"volume":"1","fileName":"cover1.jpg"}}]}
    ;
    const e = parseMangaEntry(obj).?;
    try std.testing.expectEqualStrings("801513ba-a712-498c-8f57-cae55b38cc92", e.id);
    try std.testing.expectEqualStrings("Berserk", e.title);
    try std.testing.expectEqualStrings("cover1.jpg", e.cover_file);
}

test "parseMangaEntry: falls back to the first localisation when there is no \"en\"" {
    // Live regression: MangaDex keys many canonical titles as romaji ("ja-ro")
    // with NO "en" entry. An en-only parser dropped these rows entirely.
    const obj =
        \\{"id":"b7d069cb-4ab9-4c21-a20b-38f7c269be4e","type":"manga","attributes":{"title":{"ja-ro":"One Punch-Man (Webcomic)"},"altTitles":[{"en":"OPM"}]},"relationships":[{"id":"cccccccc-a712-498c-8f57-cae55b38cc92","type":"cover_art","attributes":{"fileName":"c.png"}}]}
    ;
    const e = parseMangaEntry(obj).?;
    try std.testing.expectEqualStrings("One Punch-Man (Webcomic)", e.title);
    try std.testing.expectEqualStrings("c.png", e.cover_file);
}

test "parseMangaEntry: author relationship is never mistaken for the cover" {
    // The author/artist relationships come BEFORE cover_art and carry no
    // fileName; a naive findJsonStr(obj,"fileName") that ignored the cover_art
    // marker would pick up whatever came first if MangaDex ever added one.
    const obj =
        \\{"id":"801513ba-a712-498c-8f57-cae55b38cc92","type":"manga","attributes":{"title":{"en":"T"}},"relationships":[{"id":"dddddddd-a712-498c-8f57-cae55b38cc92","type":"author","attributes":{"fileName":"WRONG.jpg"}},{"id":"eeeeeeee-a712-498c-8f57-cae55b38cc92","type":"cover_art","attributes":{"fileName":"RIGHT.jpg"}}]}
    ;
    const e = parseMangaEntry(obj).?;
    try std.testing.expectEqualStrings("RIGHT.jpg", e.cover_file);
}

test "parseMangaEntry: missing cover → empty (row still usable)" {
    const obj =
        \\{"id":"801513ba-a712-498c-8f57-cae55b38cc92","type":"manga","attributes":{"title":{"en":"NoCover"}},"relationships":[]}
    ;
    const e = parseMangaEntry(obj).?;
    try std.testing.expectEqualStrings("NoCover", e.title);
    try std.testing.expectEqualStrings("", e.cover_file);
}

test "parseMangaEntry: garbage / bad id rejected" {
    try std.testing.expect(parseMangaEntry("{}") == null);
    try std.testing.expect(parseMangaEntry("{\"id\":\"nope\",\"attributes\":{\"title\":{\"en\":\"T\"}}}") == null);
    // valid id but no title at all → unusable row
    try std.testing.expect(parseMangaEntry("{\"id\":\"801513ba-a712-498c-8f57-cae55b38cc92\"}") == null);
}

test "ObjIter: walks data[] and a brace inside a string does not derail it" {
    // A description containing `{`/`}`/`[` would break a naive depth counter.
    const json =
        \\{"data":[{"id":"801513ba-a712-498c-8f57-cae55b38cc92","attributes":{"title":{"en":"A {weird} [title]"}},"relationships":[]},{"id":"b7d069cb-4ab9-4c21-a20b-38f7c269be4e","attributes":{"title":{"en":"B"}},"relationships":[]}]}
    ;
    const data = findJsonNode(json, "\"data\"").?;
    var it = ObjIter{ .buf = data };
    const a = parseMangaEntry(it.next().?).?;
    const b = parseMangaEntry(it.next().?).?;
    try std.testing.expectEqualStrings("A {weird} [title]", a.title);
    try std.testing.expectEqualStrings("B", b.title);
    try std.testing.expect(it.next() == null);
}

test "firstChapterId / firstChapterNumber: earliest chapter of an asc feed" {
    const json =
        \\{"result":"ok","data":[{"id":"2cd94273-6cbf-4671-a8bd-56245b59122d","type":"chapter","attributes":{"chapter":"1","pages":31}},{"id":"3cd94273-6cbf-4671-a8bd-56245b59122d","type":"chapter","attributes":{"chapter":"2"}}]}
    ;
    try std.testing.expectEqualStrings("2cd94273-6cbf-4671-a8bd-56245b59122d", firstChapterId(json).?);
    try std.testing.expectEqualStrings("1", firstChapterNumber(json).?);
}

test "firstChapterId: empty feed (no english chapters) → null" {
    try std.testing.expect(firstChapterId("{\"result\":\"ok\",\"data\":[]}") == null);
    try std.testing.expect(firstChapterId("") == null);
}

// ══════════════════════════════════════════════════════════
// Reading resume (last-read page, persisted per issue)
// ══════════════════════════════════════════════════════════
//
// Mirrors the novels vertical: `db.librarySetStatus("comic_resume", <key>, …)`
// is authoritative, and `library_items` gets a denormalized row so the home
// "Continue" rail can reopen the issue at the right page.

/// The per-issue resume key (item_id). The source URL is preferred because it
/// survives a restart and identifies the exact issue; OPDS-PSE books have no
/// scraper URL, so they fall back to the book title. Empty when neither exists
/// (an unidentifiable reader session must not write a row).
pub fn resumeKey(url: []const u8, title: []const u8, out: []u8) []const u8 {
    const src = if (url.len > 0) url else title;
    const n = @min(src.len, out.len);
    @memcpy(out[0..n], src[0..n]);
    return out[0..n];
}

/// Format the stored resume value: the last-read page INDEX as a decimal string.
pub fn formatResumePage(out: []u8, page: usize) []const u8 {
    return std.fmt.bufPrint(out, "{d}", .{page}) catch out[0..0];
}

/// Parse a stored resume value back into a page index; 0 on empty / garbage.
pub fn parseResumePage(s: []const u8) usize {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return std.fmt.parseInt(usize, t, 10) catch 0;
}

/// Whether a reader position is worth a `library_items` "Continue" row.
///
/// Progress is measured in PAGES (page+1 of page_count), and
/// `library_pure.CONTINUE_MIN_PCT` is 0.5 — a strict `>` floor. Page index 0 is
/// where every issue opens, so it carries no information to resume TO, and
/// 1/total would sit at-or-below the floor for a long issue anyway. From page
/// index 1 the fraction is 2/total; the reader stages at most 128 pages
/// (`state.app.comic.page_urls.len`), so the worst case is 2/128 = 1.56% —
/// comfortably above the floor. Anything genuinely started therefore shows up.
pub fn shouldRecordProgress(page: usize, total: usize) bool {
    return total > 0 and page >= 1 and page < total;
}

/// The two fields a home "Continue" row needs to reopen a comic issue.
pub const ComicLink = struct {
    url: []const u8, // scraper / mangadex: pseudo-URL (empty for OPDS-PSE books)
    title: []const u8, // display title
};

/// Encode a comic deep link: `comic|<url>|<title>`. Title runs to the end so its
/// own separators can't truncate it. Empty slice when it won't fit, or when
/// there's no URL to reopen (an OPDS-PSE book needs a live server session).
pub fn formatDeepLink(out: []u8, url: []const u8, title: []const u8) []const u8 {
    if (url.len == 0) return out[0..0];
    return std.fmt.bufPrint(out, "comic|{s}|{s}", .{ url, title }) catch out[0..0];
}

/// Decode a `comic|…` deep link. Null when the prefix/field count is wrong, so
/// a non-comic link can never be routed into the comic reader.
pub fn parseDeepLink(link: []const u8) ?ComicLink {
    const prefix = "comic|";
    if (!std.mem.startsWith(u8, link, prefix)) return null;
    const rest = link[prefix.len..];
    const i = std.mem.indexOfScalar(u8, rest, '|') orelse return null;
    const url = rest[0..i];
    if (url.len == 0) return null;
    return .{ .url = url, .title = rest[i + 1 ..] };
}

test "comic resume: key prefers the URL, falls back to the title" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://x.tld/issue-1", resumeKey("https://x.tld/issue-1", "Issue 1", &buf));
    try std.testing.expectEqualStrings("Berserk Vol.1", resumeKey("", "Berserk Vol.1", &buf));
    try std.testing.expectEqualStrings("", resumeKey("", "", &buf));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("http", resumeKey("https://x", "", &tiny)); // truncates, never overruns
}

test "comic resume: page value round-trips and survives garbage" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatResumePage(&buf, 0));
    try std.testing.expectEqualStrings("41", formatResumePage(&buf, 41));
    try std.testing.expectEqual(@as(usize, 41), parseResumePage(formatResumePage(&buf, 41)));
    try std.testing.expectEqual(@as(usize, 7), parseResumePage(" 7\n"));
    try std.testing.expectEqual(@as(usize, 0), parseResumePage(""));
    try std.testing.expectEqual(@as(usize, 0), parseResumePage("not-a-page"));
    try std.testing.expectEqual(@as(usize, 0), parseResumePage("-3"));
}

test "comic resume: the Continue floor excludes page 1 but admits page 2" {
    // library_pure.CONTINUE_MIN_PCT is 0.5 with a strict `>`: 1/200 == 0.5%
    // would be excluded, so page index 0 never records. Page index 1 of the
    // largest possible issue (128 staged pages) is 1.56% — above the floor.
    try std.testing.expect(!shouldRecordProgress(0, 200));
    try std.testing.expect(shouldRecordProgress(1, 128));
    const pct = 2.0 / 128.0 * 100.0;
    try std.testing.expect(pct > 0.5);
    try std.testing.expect(!shouldRecordProgress(1, 0)); // no pages staged
    try std.testing.expect(!shouldRecordProgress(9, 5)); // page beyond the end
}

test "comic deep link: round-trips through format/parse" {
    var buf: [800]u8 = undefined;
    const link = formatDeepLink(&buf, "https://readallcomics.com/x-men-1/", "X-Men #1");
    try std.testing.expectEqualStrings("comic|https://readallcomics.com/x-men-1/|X-Men #1", link);
    const got = parseDeepLink(link).?;
    try std.testing.expectEqualStrings("https://readallcomics.com/x-men-1/", got.url);
    try std.testing.expectEqualStrings("X-Men #1", got.title);

    // MangaDex pseudo-URLs route the same way.
    const l2 = formatDeepLink(&buf, "mangadex:2cd94273-6cbf-4671-a8bd-56245b59122d", "Berserk");
    const g2 = parseDeepLink(l2).?;
    try std.testing.expectEqualStrings("mangadex:2cd94273-6cbf-4671-a8bd-56245b59122d", g2.url);
}

test "comic deep link: rejects foreign links and unreopenable rows" {
    try std.testing.expect(parseDeepLink("https://example.com/a.mp4") == null);
    try std.testing.expect(parseDeepLink("novel|wikisource||Frankenstein") == null);
    try std.testing.expect(parseDeepLink("magnet:?xt=urn:btih:abc") == null);
    try std.testing.expect(parseDeepLink("comic|https://x.tld/i") == null); // no separator
    try std.testing.expect(parseDeepLink("comic||T") == null); // empty url
    var buf: [800]u8 = undefined;
    // An OPDS-PSE book has no reopenable URL → no link, so no unresumable row.
    try std.testing.expectEqualStrings("", formatDeepLink(&buf, "", "Berserk Vol.1"));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", formatDeepLink(&tiny, "https://x.tld/i", "T"));
}

test "comic deep link: a title containing '|' survives" {
    var buf: [800]u8 = undefined;
    const link = formatDeepLink(&buf, "https://x.tld/i", "Saga | Chapter 3");
    try std.testing.expectEqualStrings("Saga | Chapter 3", parseDeepLink(link).?.title);
}

// ══════════════════════════════════════════════════════════
// Page image MIME sniffing
// ══════════════════════════════════════════════════════════

/// Content-Type for a downloaded comic page. `page_pixels[i]` holds the ORIGINAL
/// encoded bytes exactly as the source served them (jpeg/png/webp/gif/avif), so
/// the HTTP page route (`/api/comics/page`) has to sniff rather than trust an
/// extension — many sources serve `.jpg` URLs with webp payloads. Falls back to
/// `image/jpeg`, which every browser will still try to decode.
pub fn imageMime(bytes: []const u8) []const u8 {
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return "image/jpeg";
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    // ISO-BMFF: `....ftyp<brand>`; avif/avis are the only ones a page source emits.
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp") and
        (std.mem.eql(u8, bytes[8..12], "avif") or std.mem.eql(u8, bytes[8..12], "avis"))) return "image/avif";
    if (bytes.len >= 2 and bytes[0] == 'B' and bytes[1] == 'M') return "image/bmp";
    return "image/jpeg";
}

test "comic page mime: sniffs the real container, not the extension" {
    try std.testing.expectEqualStrings("image/jpeg", imageMime("\xFF\xD8\xFF\xE0JFIF"));
    try std.testing.expectEqualStrings("image/png", imageMime("\x89PNG\r\n\x1a\nIHDR"));
    try std.testing.expectEqualStrings("image/gif", imageMime("GIF89a\x01\x00"));
    try std.testing.expectEqualStrings("image/webp", imageMime("RIFF\x24\x00\x00\x00WEBPVP8 "));
    try std.testing.expectEqualStrings("image/avif", imageMime("\x00\x00\x00\x18ftypavif\x00\x00"));
    try std.testing.expectEqualStrings("image/bmp", imageMime("BM\x36\x00"));
}

test "comic page mime: short/unknown bytes fall back to jpeg, never crash" {
    try std.testing.expectEqualStrings("image/jpeg", imageMime(""));
    try std.testing.expectEqualStrings("image/jpeg", imageMime("R"));
    try std.testing.expectEqualStrings("image/jpeg", imageMime("RIFF\x00\x00\x00\x00AVI "));
    try std.testing.expectEqualStrings("image/jpeg", imageMime("\x89PNG"));
    try std.testing.expectEqualStrings("image/jpeg", imageMime("<html><body>404"));
}
