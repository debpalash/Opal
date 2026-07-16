//! Pure (io-free, state-free) HeanCms / Iken manga-source helpers — unit-testable
//! via `zig build test`. Structurally a sibling of the MangaDex helpers in
//! `comics_pure.zig`: a keyed-JSON-API family (modern Next.js manhwa sites built
//! on the HeanCms/Iken stack — ~12+ sites share this exact JSON shape). The
//! production code in `comics.zig` calls into these so the tested logic IS the
//! shipped logic (no drift).
//!
//! ALL JSON scanning reuses the primitives in `comics_pure.zig` (findJsonStr,
//! findJsonNode, ObjIter, StrIter, jsonUnescape, percentEncodeStrict) — this file
//! adds only the HeanCms-specific URL builders, field extraction, and the
//! `heancms:<series_slug>` reader-route scheme.
//!
//! Contract (per the source family, no re-research):
//!   • API host  = site baseUrl with `://` → `://api.` (https://x.com → https://api.x.com)
//!   • POPULAR   GET {api}/query?query_string=&series_status=All&order=desc
//!               &orderBy=total_views&series_type=Comic&page=N&perPage=12
//!               &tags_ids=[]&adult=true
//!   • LATEST    same, orderBy=latest
//!   • SEARCH    same, query_string={q} (url-encoded)
//!   • response  { "data":[Series], "meta":{ "current_page","last_page" } }
//!   • DETAILS   GET {api}/series/{slug}                       → Series DTO
//!   • CHAPTERS  GET {api}/chapter/query?series_id={id}&…      → { "data":[Chapter], "meta" }
//!               price>0 ⇒ paywalled → SKIP (flagged)
//!   • PAGES     GET {api}/series/{seriesSlug}/{chapterSlug}   → images at
//!               {"chapter":{"chapter_data":{"images":[url,…]}}} (new) OR {"data":[url,…]} (old)
//!
//! Everything is fixed-buffer / no-allocation, matching the project's
//! `[N]u8 + len` convention.

const std = @import("std");
const cp = @import("comics_pure.zig");

// Re-export the shared JSON primitives so callers/tests can lean on this one
// module (and so the "route through the pure module" rule holds for iteration too).
pub const findJsonStr = cp.findJsonStr;
pub const findJsonNode = cp.findJsonNode;
pub const ObjIter = cp.ObjIter;
pub const StrIter = cp.StrIter;
pub const jsonUnescape = cp.jsonUnescape;
pub const percentEncodeStrict = cp.percentEncodeStrict;

// ══════════════════════════════════════════════════════════
// orderBy tokens (interpolated into the query URL — kept as a closed set)
// ══════════════════════════════════════════════════════════

pub const ORDER_POPULAR = "total_views";
pub const ORDER_LATEST = "latest";

/// A HeanCms card carries `heancms:<series_slug>`; comics.fetchComicThread
/// dispatches on the prefix into the JSON reader chain (details → chapters →
/// pages) instead of the generic curl+HTML scraper — exactly like `mangadex:`.
pub const HC_SCHEME = "heancms:";

// ══════════════════════════════════════════════════════════
// Numeric-field extraction (HeanCms ids / price / pagination are JSON numbers)
// ══════════════════════════════════════════════════════════

/// The digit run of a numeric field `"key":123`, searched from the first match.
/// `key` MUST include its quotes+colon (e.g. `"\"id\":"`). Skips optional
/// whitespace after the colon. Returns null if the value is not a bare integer
/// (e.g. `"id":null`, `"price":"x"`). Used instead of findJsonStr because these
/// fields are unquoted numbers.
pub fn findJsonUint(json: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, json, key) orelse return null;
    var i = at + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    const start = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    if (i == start) return null;
    return json[start..i];
}

/// Parse a bounded unsigned integer field, defaulting to `dflt` when absent /
/// non-numeric / overflowing. `price` defaults to 0 (free) when the field is
/// missing, which is the safe reading for older payloads that omit it.
pub fn fieldUint(json: []const u8, key: []const u8, dflt: u64) u64 {
    const s = findJsonUint(json, key) orelse return dflt;
    return std.fmt.parseInt(u64, s, 10) catch dflt;
}

// ══════════════════════════════════════════════════════════
// URL building
// ══════════════════════════════════════════════════════════

/// Derive the API host from the site base: `https://x.com` → `https://api.x.com`.
/// Trims a trailing slash and is idempotent (a host already starting `api.` is
/// left as-is, so we never produce `api.api.`). Requires an http(s) scheme.
pub fn apiHostFromBase(base: []const u8, out: []u8) ?[]const u8 {
    var b = base;
    while (b.len > 0 and b[b.len - 1] == '/') b = b[0 .. b.len - 1];
    const sep = std.mem.indexOf(u8, b, "://") orelse return null;
    const scheme = b[0..sep];
    if (scheme.len == 0 or scheme.len > 8) return null;
    const host = b[sep + 3 ..];
    if (host.len == 0) return null;
    // Host must look like a hostname (no path / query / injection chars).
    for (host) |ch| {
        if (ch == '/' or ch == '?' or ch == '#' or ch == ' ' or ch == '"') return null;
    }
    if (std.mem.startsWith(u8, host, "api.")) {
        return std.fmt.bufPrint(out, "{s}://{s}", .{ scheme, host }) catch null;
    }
    return std.fmt.bufPrint(out, "{s}://api.{s}", .{ scheme, host }) catch null;
}

/// Only [A-Za-z0-9_-] orderBy tokens are allowed anywhere near the URL — the
/// value is interpolated, so this is a small injection gate (our own callers
/// pass the ORDER_* constants, but validate defensively).
fn safeToken(t: []const u8) bool {
    if (t.len == 0 or t.len > 32) return false;
    for (t) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

/// Build the `/query` discovery+search URL. `query` may be empty (the popular /
/// latest feed). `page` is 1-based. `orderBy` picks the sort (ORDER_POPULAR /
/// ORDER_LATEST). Note the `tags_ids` array is spelled `%5B%5D`, NOT a bare `[]`:
/// we fetch via `curl` (no `-g`), which treats a bare `[...]` as a glob range and
/// can abort the request — the same bracket-glob trap MangaDex hit (see
/// comics_pure's "NO raw [ or ]" regression). Empty `[]` usually survives curl's
/// globber, but encoding keeps every built URL glob-inert and uniform.
pub fn buildQueryUrl(out: []u8, api: []const u8, query: []const u8, page: u32, orderBy: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, api, "http")) return null;
    if (!safeToken(orderBy)) return null;
    if (page == 0) return null;
    var enc: [512]u8 = undefined;
    const n = percentEncodeStrict(query, &enc);
    if (n > enc.len) return null;
    return std.fmt.bufPrint(
        out,
        "{s}/query?query_string={s}&series_status=All&order=desc&orderBy={s}" ++
            "&series_type=Comic&page={d}&perPage=12&tags_ids=%5B%5D&adult=true",
        .{ api, enc[0..n], orderBy, page },
    ) catch null;
}

/// A HeanCms series slug (`the-beginning-after-the-end`). Validated before it is
/// interpolated into a request path — anything with `/`, `.`, `?`, `%`, space
/// could escape the intended endpoint.
pub fn isValidSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > 128) return false;
    for (slug) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

/// A HeanCms numeric id (series_id) as a digit string. Injection gate before it
/// hits `?series_id={id}`.
pub fn isValidId(id: []const u8) bool {
    if (id.len == 0 or id.len > 20) return false;
    for (id) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// `GET {api}/series/{slug}` — the series DTO (details).
pub fn buildDetailUrl(out: []u8, api: []const u8, slug: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, api, "http")) return null;
    if (!isValidSlug(slug)) return null;
    return std.fmt.bufPrint(out, "{s}/series/{s}", .{ api, slug }) catch null;
}

/// `GET {api}/chapter/query?…&series_id={id}` — one paginated chapter page.
pub fn buildChapterListUrl(out: []u8, api: []const u8, id: []const u8, page: u32) ?[]const u8 {
    if (!std.mem.startsWith(u8, api, "http")) return null;
    if (!isValidId(id)) return null;
    if (page == 0) return null;
    return std.fmt.bufPrint(
        out,
        "{s}/chapter/query?page={d}&perPage=1000&series_id={s}",
        .{ api, page, id },
    ) catch null;
}

/// `GET {api}/series/{seriesSlug}/{chapterSlug}` — a chapter's page images.
pub fn buildPagesUrl(out: []u8, api: []const u8, series_slug: []const u8, chapter_slug: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, api, "http")) return null;
    if (!isValidSlug(series_slug) or !isValidSlug(chapter_slug)) return null;
    return std.fmt.bufPrint(out, "{s}/series/{s}/{s}", .{ api, series_slug, chapter_slug }) catch null;
}

/// Build the `heancms:<slug>` route URL a search-result card stores.
pub fn buildRouteUrl(out: []u8, slug: []const u8) ?[]const u8 {
    if (!isValidSlug(slug)) return null;
    return std.fmt.bufPrint(out, "{s}{s}", .{ HC_SCHEME, slug }) catch null;
}

/// Extract the series slug from a `heancms:<slug>` route URL (null if it isn't
/// one, or the slug doesn't validate).
pub fn slugFromRoute(url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, HC_SCHEME)) return null;
    const slug = url[HC_SCHEME.len..];
    if (!isValidSlug(slug)) return null;
    return slug;
}

// ══════════════════════════════════════════════════════════
// Cover / page-image absolutization
// ══════════════════════════════════════════════════════════

/// Absolutize a thumbnail / page path. If `path` is already an absolute URL
/// (`http…`) it is copied through unchanged; otherwise it becomes `{cdn}/{path}`
/// (a single joining slash, tolerating a trailing slash on cdn or a leading one
/// on path). Returns null when the result can't be formed (no cdn for a relative
/// path, or the path smuggles a quote). Used for BOTH covers and page images.
pub fn absolutizeCover(cdn: []const u8, path: []const u8, out: []u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (std.mem.indexOfScalar(u8, path, '"') != null) return null;
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
        if (path.len > out.len) return null;
        @memcpy(out[0..path.len], path);
        return out[0..path.len];
    }
    if (cdn.len == 0 or !std.mem.startsWith(u8, cdn, "http")) return null;
    var c = cdn;
    while (c.len > 0 and c[c.len - 1] == '/') c = c[0 .. c.len - 1];
    var p = path;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    if (p.len == 0) return null;
    return std.fmt.bufPrint(out, "{s}/{s}", .{ c, p }) catch null;
}

// ══════════════════════════════════════════════════════════
// Response parsing
// ══════════════════════════════════════════════════════════

/// One parsed series row of a `/query` `data[]` (or a `/series/{slug}` DTO).
pub const SeriesEntry = struct {
    /// Numeric id as a digit slice ("" when absent — a search card doesn't need it,
    /// but the chapter chain does).
    id: []const u8,
    slug: []const u8,
    /// Raw (still JSON-escaped) display title — run through jsonUnescape.
    title: []const u8,
    /// Raw thumbnail path/URL ("" when absent).
    thumbnail: []const u8,
};

/// Parse one series object (from ObjIter over `data[]`, OR a whole `/series/{slug}`
/// body). Requires a valid slug + a non-empty title; id/thumbnail are optional.
pub fn parseSeriesEntry(obj: []const u8) ?SeriesEntry {
    const slug = findJsonStr(obj, "\"series_slug\":\"") orelse return null;
    if (!isValidSlug(slug)) return null;
    const title = findJsonStr(obj, "\"title\":\"") orelse return null;
    if (title.len == 0) return null;

    const id: []const u8 = findJsonUint(obj, "\"id\":") orelse "";
    const thumb: []const u8 = findJsonStr(obj, "\"thumbnail\":\"") orelse "";
    return .{ .id = id, .slug = slug, .title = title, .thumbnail = thumb };
}

/// Parse the `/series/{slug}` details body. HeanCms sites variously return the
/// DTO bare or wrapped in `{"data":{…}}`; parseSeriesEntry scans for the fields
/// regardless (first `"series_slug"`/`"id"` wins), so this is a thin alias that
/// documents the call site.
pub fn parseSeriesDetail(json: []const u8) ?SeriesEntry {
    return parseSeriesEntry(json);
}

/// meta.current_page < meta.last_page → more query pages exist.
pub fn hasNextPage(json: []const u8) bool {
    const meta = findJsonNode(json, "\"meta\"") orelse json;
    const cur = fieldUint(meta, "\"current_page\":", 1);
    const last = fieldUint(meta, "\"last_page\":", 1);
    return cur < last;
}

/// One parsed chapter of a `/chapter/query` `data[]`.
pub const ChapterEntry = struct {
    id: []const u8,
    slug: []const u8,
    /// Raw (still JSON-escaped) chapter_name (e.g. "Chapter 12").
    name: []const u8,
    /// True when `price == 0`. Paywalled chapters (price>0) are flagged here so
    /// the caller can SKIP them (and surface a count), never silently 404.
    free: bool,
};

/// Parse one chapter object. Requires a valid chapter_slug; `price` defaults to 0
/// (free) when the field is absent. Returns the entry with `free` set — the
/// caller decides to skip paywalled ones (so a "N locked" flag stays possible).
pub fn parseChapterEntry(obj: []const u8) ?ChapterEntry {
    const slug = findJsonStr(obj, "\"chapter_slug\":\"") orelse return null;
    if (!isValidSlug(slug)) return null;
    const id: []const u8 = findJsonUint(obj, "\"id\":") orelse "";
    const name: []const u8 = findJsonStr(obj, "\"chapter_name\":\"") orelse "";
    const price = fieldUint(obj, "\"price\":", 0);
    return .{ .id = id, .slug = slug, .name = name, .free = price == 0 };
}

/// The FIRST free (price==0) chapter in a `/chapter/query` response — the one the
/// reader opens. Paywalled chapters are skipped. Null when every chapter is
/// locked or the payload has no chapters.
pub fn firstFreeChapter(json: []const u8) ?ChapterEntry {
    const data = findJsonNode(json, "\"data\"") orelse return null;
    if (data.len == 0 or data[0] != '[') return null;
    var it = ObjIter{ .buf = data };
    while (it.next()) |obj| {
        const ch = parseChapterEntry(obj) orelse continue;
        if (ch.free) return ch;
    }
    return null;
}

/// The image-array payload of a pages response — walk it with StrIter, then
/// absolutize each entry via absolutizeCover. Handles BOTH shapes:
///   new: {"chapter":{"chapter_data":{"images":[url,…]}}}   (any nesting — we key on "images")
///   old: {"data":[url,…]}
/// A paywalled/empty chapter (`"data":null` / no image array) yields null.
pub fn pagesNode(json: []const u8) ?[]const u8 {
    if (findJsonNode(json, "\"images\"")) |n| {
        if (n.len > 0 and n[0] == '[') return n;
    }
    if (findJsonNode(json, "\"data\"")) |n| {
        if (n.len > 0 and n[0] == '[') return n;
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// Tests — exercised against embedded HeanCms/Iken JSON samples.
// ══════════════════════════════════════════════════════════

const QUERY_SAMPLE =
    \\{"data":[
    \\{"id":42,"series_slug":"the-beginning-after-the-end","title":"The Beginning After The End","thumbnail":"covers/42/thumb.webp","description":"<p>King Grey has <b>unrivaled</b> strength.</p>","author":"TurtleMe","status":"Ongoing","tags":[{"id":7,"name":"Action"}]},
    \\{"id":108,"series_slug":"solo-leveling","title":"Solo Leveling","thumbnail":"https://cdn.other.test/sl.jpg","tags":[{"id":9,"name":"Fantasy"}]}
    \\],"meta":{"current_page":1,"last_page":5,"per_page":12,"total":58}}
;

const DETAIL_SAMPLE =
    \\{"data":{"id":42,"series_slug":"the-beginning-after-the-end","title":"The Beginning After The End","thumbnail":"covers/42/thumb.webp","description":"<p>desc</p>","status":"Ongoing"}}
;

const CHAPTERS_SAMPLE =
    \\{"data":[
    \\{"id":9001,"chapter_name":"Chapter 180","chapter_title":"","chapter_slug":"chapter-180","created_at":"2024-01-02","price":150},
    \\{"id":9000,"chapter_name":"Chapter 179","chapter_title":"Return","chapter_slug":"chapter-179","created_at":"2024-01-01","price":0}
    \\],"meta":{"current_page":1,"last_page":1}}
;

const PAGES_NEW =
    \\{"chapter":{"id":9000,"chapter_data":{"images":["https://cdn.test/1.webp","chapters/9000/2.webp","https://cdn.test/3.webp"]}}}
;

const PAGES_OLD =
    \\{"data":["https://cdn.test/1.webp","https://cdn.test/2.webp"]}
;

test "apiHostFromBase: :// → ://api., trailing-slash + idempotent" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://api.x.com", apiHostFromBase("https://x.com", &out).?);
    try std.testing.expectEqualStrings("https://api.x.com", apiHostFromBase("https://x.com/", &out).?);
    // Already api-prefixed → no double.
    try std.testing.expectEqualStrings("https://api.x.com", apiHostFromBase("https://api.x.com", &out).?);
    // No scheme / injection → rejected.
    try std.testing.expect(apiHostFromBase("x.com", &out) == null);
    try std.testing.expect(apiHostFromBase("https://x.com/../y", &out) == null);
    try std.testing.expect(apiHostFromBase("", &out) == null);
}

test "buildQueryUrl: popular / latest / search + brackets encoded" {
    var out: [1024]u8 = undefined;
    const pop = buildQueryUrl(&out, "https://api.x.com", "", 1, ORDER_POPULAR).?;
    try std.testing.expect(std.mem.startsWith(u8, pop, "https://api.x.com/query?query_string=&"));
    try std.testing.expect(std.mem.indexOf(u8, pop, "orderBy=total_views") != null);
    try std.testing.expect(std.mem.indexOf(u8, pop, "series_type=Comic") != null);
    try std.testing.expect(std.mem.indexOf(u8, pop, "page=1") != null);
    // The tags array MUST be encoded (curl glob-abort trap) — no raw brackets anywhere.
    try std.testing.expect(std.mem.indexOf(u8, pop, "tags_ids=%5B%5D") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, pop, '[') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, pop, ']') == null);

    var out2: [1024]u8 = undefined;
    const lat = buildQueryUrl(&out2, "https://api.x.com", "", 3, ORDER_LATEST).?;
    try std.testing.expect(std.mem.indexOf(u8, lat, "orderBy=latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, lat, "page=3") != null);

    var out3: [1024]u8 = undefined;
    const q = buildQueryUrl(&out3, "https://api.x.com", "solo leveling", 1, ORDER_POPULAR).?;
    try std.testing.expect(std.mem.indexOf(u8, q, "query_string=solo%20leveling") != null);
}

test "buildQueryUrl: bad api / bad orderBy / page 0 rejected" {
    var out: [1024]u8 = undefined;
    try std.testing.expect(buildQueryUrl(&out, "ftp://x", "q", 1, ORDER_POPULAR) == null);
    try std.testing.expect(buildQueryUrl(&out, "https://api.x.com", "q", 0, ORDER_POPULAR) == null);
    try std.testing.expect(buildQueryUrl(&out, "https://api.x.com", "q", 1, "views;rm -rf") == null);
}

test "detail / chapter-list / pages URL builders validate slug + id" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://api.x.com/series/the-beginning-after-the-end",
        buildDetailUrl(&out, "https://api.x.com", "the-beginning-after-the-end").?,
    );
    try std.testing.expectEqualStrings(
        "https://api.x.com/chapter/query?page=1&perPage=1000&series_id=42",
        buildChapterListUrl(&out, "https://api.x.com", "42", 1).?,
    );
    try std.testing.expectEqualStrings(
        "https://api.x.com/series/tbate/chapter-179",
        buildPagesUrl(&out, "https://api.x.com", "tbate", "chapter-179").?,
    );
    // Path-escape / injection ids+slugs never reach the network.
    try std.testing.expect(buildDetailUrl(&out, "https://api.x.com", "../../etc/passwd") == null);
    try std.testing.expect(buildChapterListUrl(&out, "https://api.x.com", "42; DROP", 1) == null);
    try std.testing.expect(buildPagesUrl(&out, "https://api.x.com", "ok", "a/b?c") == null);
}

test "route url: build → parse round-trip; foreign/malformed not claimed" {
    var out: [160]u8 = undefined;
    const route = buildRouteUrl(&out, "solo-leveling").?;
    try std.testing.expectEqualStrings("heancms:solo-leveling", route);
    try std.testing.expectEqualStrings("solo-leveling", slugFromRoute(route).?);
    try std.testing.expect(slugFromRoute("mangadex:abc") == null);
    try std.testing.expect(slugFromRoute("heancms:../bad") == null);
    try std.testing.expect(slugFromRoute("heancms:") == null);
    var rb: [160]u8 = undefined;
    try std.testing.expect(buildRouteUrl(&rb, "bad slug!") == null);
}

test "parseSeriesEntry / ObjIter over the query data[]" {
    const data = findJsonNode(QUERY_SAMPLE, "\"data\"").?;
    var it = ObjIter{ .buf = data };
    const a = parseSeriesEntry(it.next().?).?;
    try std.testing.expectEqualStrings("42", a.id);
    try std.testing.expectEqualStrings("the-beginning-after-the-end", a.slug);
    try std.testing.expectEqualStrings("The Beginning After The End", a.title);
    try std.testing.expectEqualStrings("covers/42/thumb.webp", a.thumbnail);

    const b = parseSeriesEntry(it.next().?).?;
    try std.testing.expectEqualStrings("108", b.id);
    try std.testing.expectEqualStrings("solo-leveling", b.slug);
    try std.testing.expectEqualStrings("https://cdn.other.test/sl.jpg", b.thumbnail);
    try std.testing.expect(it.next() == null);
}

test "hasNextPage: current_page < last_page" {
    try std.testing.expect(hasNextPage(QUERY_SAMPLE)); // 1 < 5
    try std.testing.expect(!hasNextPage(CHAPTERS_SAMPLE)); // 1 == 1
    // No meta → treated as no more pages (defaults 1<1 == false).
    try std.testing.expect(!hasNextPage("{\"data\":[]}"));
}

test "parseSeriesDetail: wrapped DTO" {
    const d = parseSeriesDetail(DETAIL_SAMPLE).?;
    try std.testing.expectEqualStrings("42", d.id);
    try std.testing.expectEqualStrings("the-beginning-after-the-end", d.slug);
    try std.testing.expectEqualStrings("The Beginning After The End", d.title);
}

test "firstFreeChapter: paywalled (price>0) chapter is skipped" {
    // The first chapter in the sample is price:150 (locked); the parser must skip
    // it and return the price:0 one — never route the reader at a paywalled slug.
    const ch = firstFreeChapter(CHAPTERS_SAMPLE).?;
    try std.testing.expectEqualStrings("chapter-179", ch.slug);
    try std.testing.expectEqualStrings("Chapter 179", ch.name);
    try std.testing.expect(ch.free);

    // The locked one parses but is flagged not-free.
    const data = findJsonNode(CHAPTERS_SAMPLE, "\"data\"").?;
    var it = ObjIter{ .buf = data };
    const locked = parseChapterEntry(it.next().?).?;
    try std.testing.expectEqualStrings("chapter-180", locked.slug);
    try std.testing.expect(!locked.free);
}

test "firstFreeChapter: every chapter locked → null" {
    const all_locked =
        \\{"data":[{"id":1,"chapter_slug":"c-1","chapter_name":"1","price":100}],"meta":{"current_page":1,"last_page":1}}
    ;
    try std.testing.expect(firstFreeChapter(all_locked) == null);
    try std.testing.expect(firstFreeChapter("{\"data\":[]}") == null);
}

test "parseChapterEntry: missing price defaults to free" {
    const obj =
        \\{"id":5,"chapter_slug":"c-5","chapter_name":"Ch 5"}
    ;
    const ch = parseChapterEntry(obj).?;
    try std.testing.expect(ch.free);
}

test "pagesNode: new shape (chapter.chapter_data.images)" {
    const node = pagesNode(PAGES_NEW).?;
    var it = StrIter{ .buf = node };
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://cdn.test/1.webp", absolutizeCover("https://cdn.x", it.next().?, &out).?);
    // Relative page → joined onto the cdn.
    try std.testing.expectEqualStrings("https://cdn.x/chapters/9000/2.webp", absolutizeCover("https://cdn.x/", it.next().?, &out).?);
    try std.testing.expectEqualStrings("https://cdn.test/3.webp", absolutizeCover("https://cdn.x", it.next().?, &out).?);
    try std.testing.expect(it.next() == null);
}

test "pagesNode: old shape (top-level data[])" {
    const node = pagesNode(PAGES_OLD).?;
    var it = StrIter{ .buf = node };
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "pagesNode: paywalled / empty (data:null) → null (no crash)" {
    try std.testing.expect(pagesNode("{\"data\":null}") == null);
    try std.testing.expect(pagesNode("{\"chapter\":{\"chapter_data\":{}}}") == null);
    try std.testing.expect(pagesNode("") == null);
}

test "absolutizeCover: absolute passthrough, relative join, guards" {
    var out: [256]u8 = undefined;
    // Absolute → unchanged (cdn ignored).
    try std.testing.expectEqualStrings("https://a.test/x.jpg", absolutizeCover("https://cdn.x", "https://a.test/x.jpg", &out).?);
    // Relative → {cdn}/{path}, slash normalization.
    try std.testing.expectEqualStrings("https://cdn.x/covers/42/t.webp", absolutizeCover("https://cdn.x/", "/covers/42/t.webp", &out).?);
    // Relative with no cdn → null (can't form an absolute URL).
    try std.testing.expect(absolutizeCover("", "covers/1.jpg", &out) == null);
    // Quote-smuggling path rejected.
    try std.testing.expect(absolutizeCover("https://cdn.x", "a\"b.jpg", &out) == null);
    try std.testing.expect(absolutizeCover("https://cdn.x", "", &out) == null);
}

test "malformed / truncated payloads never crash" {
    try std.testing.expect(parseSeriesEntry("{}") == null);
    try std.testing.expect(parseSeriesEntry("{\"series_slug\":\"ok\"}") == null); // no title
    try std.testing.expect(parseSeriesEntry("{\"title\":\"T\"}") == null); // no slug
    // Truncated mid-object (connection cut) — unbalanced braces must not hang.
    try std.testing.expect(firstFreeChapter("{\"data\":[{\"chapter_slug\":\"c-1\",\"price\":0") == null);
    try std.testing.expect(hasNextPage("{\"meta\":{\"current_page\":") == false);
}

test "findJsonUint: integer fields; rejects null/quoted/missing" {
    try std.testing.expectEqualStrings("42", findJsonUint("{\"id\":42}", "\"id\":").?);
    try std.testing.expectEqualStrings("7", findJsonUint("{\"id\": 7 }", "\"id\":").?);
    try std.testing.expect(findJsonUint("{\"id\":null}", "\"id\":") == null);
    try std.testing.expect(findJsonUint("{\"id\":\"7\"}", "\"id\":") == null);
    try std.testing.expect(findJsonUint("{\"x\":1}", "\"id\":") == null);
    try std.testing.expectEqual(@as(u64, 0), fieldUint("{}", "\"price\":", 0));
    try std.testing.expectEqual(@as(u64, 5), fieldUint("{\"price\":5}", "\"price\":", 0));
}
