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
//! Iken contract (verified live Nov 2026 — every catalog site that still answers
//! has moved to it; the HeanCms `/query` path above now 404s there):
//!   • SEARCH    GET {api}/api/query?page=N&perPage=20&searchTerm={q}
//!               → { "posts":[Post], "totalCount":N }   Post = id, slug, postTitle,
//!               featuredImage, seriesType (NOVEL ⇒ text, skipped)
//!   • DETAILS   GET {api}/api/post?postSlug={slug}        → { "post":{ id, postTitle, isNovel, … } }
//!   • CHAPTERS  GET {api}/api/chapters?postId={id}&skip=0&take=100&order=asc
//!               → { "post":{ "chapters":[Chapter] }, "totalChapterCount":N }
//!               isLocked / !isAccessible / price>0 ⇒ paywalled → SKIP
//!   • PAGES     GET {api}/api/chapter?postId={id}&chapterId={cid}
//!               → { "chapter":{ "images":[{ "url", "order", … }] } }  (locked ⇒ images:[])
//! The flavour is detected by RESPONSE SHAPE (isIkenQuery / isIkenPost), so one
//! "heancms" source id drives both and a legacy HeanCms site keeps working.
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
    const tail = url[HC_SCHEME.len..];
    const slug = tail[0 .. std.mem.indexOfScalar(u8, tail, '?') orelse tail.len];
    if (slug.len != tail.len and chapterIdFromRoute(url) == null) return null;
    if (!isValidSlug(slug)) return null;
    return slug;
}

/// Chapter routes retain the series identity and a stable numeric chapter id.
pub fn chapterIdFromRoute(url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, HC_SCHEME)) return null;
    const at = std.mem.indexOf(u8, url, "?chapter=") orelse return null;
    if (!isValidSlug(url[HC_SCHEME.len..at])) return null;
    const id = url[at + "?chapter=".len ..];
    return if (isValidId(id)) id else null;
}

pub fn buildIkenChapterRoute(out: []u8, slug: []const u8, id: []const u8) ?[]const u8 {
    if (!isValidSlug(slug) or !isValidId(id)) return null;
    return std.fmt.bufPrint(out, "{s}{s}?chapter={s}", .{ HC_SCHEME, slug, id }) catch null;
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
    /// Iken only: the raw chapter number token ("3", "10.5"); "" for HeanCms,
    /// whose `chapter_name` already reads "Chapter 3".
    number: []const u8 = "",
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
// Iken flavour (the API the HeanCms sites migrated to)
// ══════════════════════════════════════════════════════════

/// The raw value of a DEPTH-1 field of the JSON object `obj`: a string's
/// (still-escaped) contents, a bare token (`375`, `true`, `null`), or the
/// balanced `{…}`/`[…]` span. Unlike findJsonStr this never matches a same-named
/// key inside a nested object — Iken chapters embed a `mangaPost` with its own
/// `slug`/`id`, and its key order is not stable across sites. `name` is the bare
/// key (no quotes). Null when absent or the object is truncated.
pub fn objField(obj: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < obj.len and obj[i] != '{') i += 1;
    i += 1;
    while (i < obj.len) {
        while (i < obj.len and obj[i] != '"') {
            if (obj[i] == '}') return null;
            i += 1;
        }
        if (i >= obj.len) return null;
        const key_end = cp.skipString(obj, i);
        if (key_end >= obj.len) return null; // unterminated key / nothing after it
        const key = obj[i + 1 .. key_end - 1];
        i = key_end;
        while (i < obj.len and (obj[i] == ':' or std.ascii.isWhitespace(obj[i]))) i += 1;
        if (i >= obj.len) return null;
        var val: []const u8 = undefined;
        switch (obj[i]) {
            '"' => {
                const end = cp.skipString(obj, i);
                if (end >= obj.len) return null; // unterminated (truncated body)
                val = obj[i + 1 .. end - 1];
                i = end;
            },
            '{', '[' => {
                val = cp.balancedSpan(obj, i) orelse return null;
                i += val.len;
            },
            else => {
                const start = i;
                while (i < obj.len and obj[i] != ',' and obj[i] != '}' and !std.ascii.isWhitespace(obj[i])) i += 1;
                val = obj[start..i];
            },
        }
        if (std.mem.eql(u8, key, name)) return val;
    }
    return null;
}

fn fieldIs(obj: []const u8, name: []const u8, token: []const u8) bool {
    const v = objField(obj, name) orelse return false;
    return std.mem.eql(u8, v, token);
}

/// The `posts[]` array of an Iken `/api/query` body, or null when the body is
/// not Iken-shaped (a HeanCms `{"data":[…]}`, a 404 JSON, an HTML wall).
pub fn ikenPostsNode(json: []const u8) ?[]const u8 {
    const n = objField(json, "posts") orelse return null;
    if (n.len == 0 or n[0] != '[') return null;
    return n;
}

/// True when a search response came from an Iken API (even with zero hits).
pub fn isIkenQuery(json: []const u8) bool {
    return ikenPostsNode(json) != null;
}

/// True when a details response came from an Iken API (`{"post":{…}}`).
pub fn isIkenPost(json: []const u8) bool {
    const n = objField(json, "post") orelse return false;
    return n.len > 0 and n[0] == '{';
}

/// `GET {api}/api/query?page=N&perPage=20&searchTerm={q}` — browse (empty `query`)
/// and search share the endpoint. `page` is 1-based.
pub fn buildIkenQueryUrl(out: []u8, api: []const u8, query: []const u8, page: u32) ?[]const u8 {
    if (!std.mem.startsWith(u8, api, "http")) return null;
    if (page == 0) return null;
    var enc: [512]u8 = undefined;
    const n = percentEncodeStrict(query, &enc);
    if (n > enc.len) return null;
    return std.fmt.bufPrint(out, "{s}/api/query?page={d}&perPage=20&searchTerm={s}", .{ api, page, enc[0..n] }) catch null;
}

/// `GET {api}/api/post?postSlug={slug}` — series details (numeric id + title).
pub fn buildIkenPostUrl(out: []u8, api: []const u8, slug: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, api, "http")) return null;
    if (!isValidSlug(slug)) return null;
    return std.fmt.bufPrint(out, "{s}/api/post?postSlug={s}", .{ api, slug }) catch null;
}

/// How many chapters one list call asks for. Ascending order + first-free means
/// the head of the list is all the reader needs; a full `take=900` body (~0.8KB
/// per chapter) would overflow the fetch buffer and truncate the JSON.
pub const IKEN_CHAPTER_TAKE = 100;

/// `GET {api}/api/chapters?postId={id}&skip=0&take=100&order=asc`.
pub fn buildIkenChapterListUrl(out: []u8, api: []const u8, post_id: []const u8) ?[]const u8 {
    return buildIkenChapterListPageUrl(out, api, post_id, 0);
}

pub fn buildIkenChapterListPageUrl(out: []u8, api: []const u8, post_id: []const u8, skip: usize) ?[]const u8 {
    if (!std.mem.startsWith(u8, api, "http")) return null;
    if (!isValidId(post_id)) return null;
    return std.fmt.bufPrint(out, "{s}/api/chapters?postId={s}&skip={d}&take={d}&order=asc", .{ api, post_id, skip, IKEN_CHAPTER_TAKE }) catch null;
}

/// `GET {api}/api/chapter?postId={id}&chapterId={cid}` — one chapter's images.
pub fn buildIkenPagesUrl(out: []u8, api: []const u8, post_id: []const u8, chapter_id: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, api, "http")) return null;
    if (!isValidId(post_id) or !isValidId(chapter_id)) return null;
    return std.fmt.bufPrint(out, "{s}/api/chapter?postId={s}&chapterId={s}", .{ api, post_id, chapter_id }) catch null;
}

/// Parse one Iken post object (a `/api/query` `posts[]` row, or the `post` node
/// of `/api/post`). Requires a valid slug, a numeric id and a title. Novels
/// (`seriesType:"NOVEL"` / `isNovel:true`) are text, not page images → null.
pub fn parseIkenPost(obj: []const u8) ?SeriesEntry {
    const slug = objField(obj, "slug") orelse return null;
    if (!isValidSlug(slug)) return null;
    const id = objField(obj, "id") orelse return null;
    if (!isValidId(id)) return null;
    const title = objField(obj, "postTitle") orelse return null;
    if (title.len == 0 or std.mem.eql(u8, title, "null")) return null;
    if (fieldIs(obj, "seriesType", "NOVEL") or fieldIs(obj, "isNovel", "true")) return null;
    var thumb: []const u8 = objField(obj, "featuredImage") orelse "";
    if (std.mem.eql(u8, thumb, "null")) thumb = "";
    return .{ .id = id, .slug = slug, .title = title, .thumbnail = thumb };
}

/// Parse an `/api/post?postSlug=` body (`{"post":{…}}`).
pub fn parseIkenDetail(json: []const u8) ?SeriesEntry {
    const post = objField(json, "post") orelse return null;
    if (post.len == 0 or post[0] != '{') return null;
    return parseIkenPost(post);
}

/// Parse one Iken chapter object. `free` is false when the site flags it locked
/// (`isLocked:true` / `isAccessible:false` / `isPermanentlyLocked:true`) or it
/// still carries a coin price. `slug` is informational — pages are fetched by id.
pub fn parseIkenChapter(obj: []const u8) ?ChapterEntry {
    const id = objField(obj, "id") orelse return null;
    if (!isValidId(id)) return null;
    const locked = fieldIs(obj, "isLocked", "true") or
        fieldIs(obj, "isAccessible", "false") or
        fieldIs(obj, "isPermanentlyLocked", "true");
    const price = std.fmt.parseInt(u64, objField(obj, "price") orelse "0", 10) catch 0;
    var number: []const u8 = objField(obj, "number") orelse "";
    if (std.mem.eql(u8, number, "null")) number = "";
    return .{
        .id = id,
        .slug = objField(obj, "slug") orelse "",
        .name = "",
        .free = !locked and price == 0,
        .number = number,
    };
}

/// The FIRST free chapter of an `/api/chapters` body (`post.chapters[]`, asked
/// for in ascending order → chapter 1 unless it is locked). Null when every
/// listed chapter is paywalled or the payload is not Iken-shaped.
pub fn firstFreeIkenChapter(json: []const u8) ?ChapterEntry {
    const post = objField(json, "post") orelse return null;
    const chapters = objField(post, "chapters") orelse return null;
    if (chapters.len == 0 or chapters[0] != '[') return null;
    var it = ObjIter{ .buf = chapters };
    while (it.next()) |obj| {
        const ch = parseIkenChapter(obj) orelse continue;
        if (ch.free) return ch;
    }
    return null;
}

/// Owns chapter metadata across paginated fetch-buffer reuse. Locked chapters
/// are skipped; a missing requested id never silently opens another chapter.
pub const IkenNavigation = struct {
    pub const Chapter = struct {
        id: [24]u8 = @splat(0),
        number: [48]u8 = @splat(0),
        pub fn idSlice(self: *const Chapter) []const u8 {
            return std.mem.sliceTo(&self.id, 0);
        }
        pub fn numberSlice(self: *const Chapter) []const u8 {
            return std.mem.sliceTo(&self.number, 0);
        }
    };
    previous: ?Chapter = null,
    current: ?Chapter = null,
    next: ?Chapter = null,

    pub fn append(self: *IkenNavigation, json: []const u8, requested: ?[]const u8) ?usize {
        const post = objField(json, "post") orelse return null;
        const chapters = objField(post, "chapters") orelse return null;
        if (chapters.len == 0 or chapters[0] != '[') return null;
        var it = ObjIter{ .buf = chapters };
        var count: usize = 0;
        while (it.next()) |obj| {
            count += 1;
            const ch = parseIkenChapter(obj) orelse continue;
            if (!ch.free or ch.id.len >= 24 or ch.number.len >= 48) continue;
            var owned: Chapter = .{};
            @memcpy(owned.id[0..ch.id.len], ch.id);
            @memcpy(owned.number[0..ch.number.len], ch.number);
            if (self.current != null) {
                if (self.next == null) self.next = owned;
            } else if (requested == null or std.mem.eql(u8, requested.?, ch.id)) {
                self.current = owned;
            } else self.previous = owned;
        }
        return count;
    }
};

/// Walks the page-image URLs of an `/api/chapter` body in array order (the API
/// returns them sorted by `order`). Each `next()` is a raw, still-escaped URL —
/// jsonUnescape + absolutizeCover it. A locked chapter (`"images":[]`) or a
/// novel chapter (text `content`, no images) yields nothing.
pub const IkenImageIter = struct {
    objs: ObjIter,

    pub fn init(json: []const u8) IkenImageIter {
        const empty: IkenImageIter = .{ .objs = .{ .buf = "" } };
        const chapter = objField(json, "chapter") orelse return empty;
        const images = objField(chapter, "images") orelse return empty;
        if (images.len == 0 or images[0] != '[') return empty;
        return .{ .objs = .{ .buf = images } };
    }

    pub fn next(self: *IkenImageIter) ?[]const u8 {
        while (self.objs.next()) |obj| {
            const url = objField(obj, "url") orelse continue;
            if (url.len == 0 or std.mem.eql(u8, url, "null")) continue;
            return url;
        }
        return null;
    }
};

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

// ── Iken: samples trimmed from live captures (api.hivetoons.org, 2026-11-18) ──

const IKEN_QUERY =
    \\{"posts":[
    \\{"id":375,"slug":"the-subcontractors-blueprint","postTitle":"The Subcontractor's Blueprint","featuredImage":"https://storage.hivetoon.com/public/upload/series/featured/cmera5fvc000wpg1hz1ad0qf4/d79c8f2a-c5ec-48fb-b770-495846f927d3.png","seriesType":"MANHWA","seriesStatus":"ONGOING","hot":false,"isPinned":false,"saleActive":false,"salePercentage":0,"saleEndDate":null,"genres":[{"id":2,"name":"Drama","color":""}],"chapters":"[{\"id\": 21915, \"number\": 3, \"title\": \"The Paper Trail\", \"slug\": \"chapter-3\", \"isLocked\": false, \"isAccessible\": true}]","averageRating":10},
    \\{"id":2896,"slug":"the-17th-princess-just-wants-to-live","postTitle":"The 17th Princess Just Wants to Live","featuredImage":"https://storage.azorafly.com/upload/series/featured/x/b8f9069e.jpg","seriesType":"NOVEL","genres":[],"chapters":"[]","averageRating":0},
    \\{"genres":[{"id":3,"name":"Fantasy","color":""}],"averageRating":9,"featuredImage":null,"postTitle":"The Northern Grand Duke’s Crazy Live-In Son-in-Law","slug":"the-northern-grand-dukes-crazy-live-in-son-in-law","id":374,"seriesType":"MANHWA"}
    \\],"totalCount":330,"searchTerm":null}
;

const IKEN_POST =
    \\{"firstChapter":{"number":1,"slug":"chapter-1"},"lastChapter":{"number":3,"slug":"chapter-3"},"totalChapterCount":3,"post":{"id":375,"slug":"the-subcontractors-blueprint","postTitle":"The Subcontractor's Blueprint","postContent":"<p>A man wakes up in the body of a Fair Trade Commission investigator.</p>","isNovel":false,"featuredImage":"https://storage.hivetoon.com/public/upload/series/featured/cmera5fvc000wpg1hz1ad0qf4/d79c8f2a-c5ec-48fb-b770-495846f927d3.png","seriesType":"MANHWA","seriesStatus":"ONGOING","genres":[{"id":2,"name":"Drama","color":""}],"_count":{"bookmarks":4,"ratings":0,"chapters":3},"createdby":{"id":"cmera5fvc000wpg1hz1ad0qf4","name":"storm"},"chapters":[],"averageRating":10}}
;

// Chapter 10 is coin-locked (price 100, isLocked) and listed first; chapter 8
// became free. The second object puts `mangaPost` (with its own id/slug) FIRST.
const IKEN_CHAPTERS =
    \\{"post":{"chapters":[
    \\{"id":21909,"slug":"chapter-10","number":10,"title":"Fitting Name","unlockAt":"2026-11-25T13:01:07.875Z","becameFreeAt":null,"isPermanentlyLocked":false,"isShortLinkLocked":false,"price":100,"mangaPostId":374,"likesCount":0,"_count":{"comments":0},"chapterPurchased":false,"isLocked":true,"isAccessible":false},
    \\{"mangaPost":{"id":374,"postTitle":"The Northern Grand Duke’s Crazy Live-In Son-in-Law","slug":"the-northern-grand-dukes-crazy-live-in-son-in-law"},"id":21823,"slug":"chapter-8","number":8,"title":"Demian","unlockAt":null,"becameFreeAt":"2026-11-17T15:12:40.837Z","isPermanentlyLocked":false,"price":0,"mangaPostId":374,"chapterPurchased":false,"isLocked":false,"isAccessible":true}
    \\]},"totalChapterCount":11}
;

const IKEN_PAGES =
    \\{"chapter":{"id":21777,"slug":"chapter-1","number":1,"title":"To Save the Company","chapterStatus":"PUBLIC","featuredImage":"https://image-comic.pstatic.net/webtoon/857024/1/thumbnail_202x120.jpg","price":0,"mangaPostId":375,"mangaPost":{"id":375,"postTitle":"The Subcontractor's Blueprint","slug":"the-subcontractors-blueprint","featuredImage":"https://storage.hivetoon.com/public/upload/series/featured/x/cover.png"},"content":"","images":[{"id":805749,"url":"https://storage.hivetoon.com/public/upload/series/the-subcontractors-blueprint/e578908d-8f4b-4859-bf35-0c380b77bff8/page-0001_01_1793817704302-216377.webp","width":800,"height":5000,"order":0},{"id":1055182,"height":11115,"width":1125,"url":"https://storage.eternalmangas.org//upload/series/el-error-perfecto/motek8Hm3S/01.webp","order":1}],"isPurchased":false,"isLocked":false,"isAccessible":true},"nextChapter":{"slug":"chapter-2","number":2,"title":"An Inside Job"},"previousChapter":null}
;

const IKEN_PAGES_LOCKED =
    \\{"chapter":{"id":21909,"slug":"chapter-10","number":10,"price":100,"isLockedByCoins":true,"mangaPostId":374,"mangaPost":{"id":374,"slug":"x"},"isPurchased":false,"isLocked":true,"isAccessible":false,"content":null,"images":[]},"nextChapter":null,"previousChapter":{"slug":"chapter-9","number":9,"title":"A Revisit"}}
;

test "regression: catalog sites moved to Iken — /api/* URL builders" {
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://api.x.com/api/query?page=1&perPage=20&searchTerm=",
        buildIkenQueryUrl(&out, "https://api.x.com", "", 1).?,
    );
    try std.testing.expectEqualStrings(
        "https://api.x.com/api/query?page=3&perPage=20&searchTerm=the%20duke%26x%3D1",
        buildIkenQueryUrl(&out, "https://api.x.com", "the duke&x=1", 3).?,
    );
    try std.testing.expectEqualStrings(
        "https://api.x.com/api/post?postSlug=the-subcontractors-blueprint",
        buildIkenPostUrl(&out, "https://api.x.com", "the-subcontractors-blueprint").?,
    );
    try std.testing.expectEqualStrings(
        "https://api.x.com/api/chapters?postId=375&skip=0&take=100&order=asc",
        buildIkenChapterListUrl(&out, "https://api.x.com", "375").?,
    );
    try std.testing.expectEqualStrings(
        "https://api.x.com/api/chapter?postId=375&chapterId=21777",
        buildIkenPagesUrl(&out, "https://api.x.com", "375", "21777").?,
    );
    // Injection / bad input never reaches the network.
    try std.testing.expect(buildIkenQueryUrl(&out, "https://api.x.com", "q", 0) == null);
    try std.testing.expect(buildIkenQueryUrl(&out, "ftp://x", "q", 1) == null);
    try std.testing.expect(buildIkenPostUrl(&out, "https://api.x.com", "a&postId=1") == null);
    try std.testing.expect(buildIkenChapterListUrl(&out, "https://api.x.com", "375&take=9") == null);
    try std.testing.expect(buildIkenPagesUrl(&out, "https://api.x.com", "375", "") == null);
}

test "objField: depth-1 only, any key order, all value kinds" {
    const obj =
        \\{"mangaPost":{"id":374,"slug":"inner"}, "id": 21823 ,"slug":"chapter-8","t":"a \"q\" }","ok":true,"n":null,"arr":[{"id":1}]}
    ;
    try std.testing.expectEqualStrings("21823", objField(obj, "id").?);
    try std.testing.expectEqualStrings("chapter-8", objField(obj, "slug").?);
    try std.testing.expectEqualStrings("a \\\"q\\\" }", objField(obj, "t").?);
    try std.testing.expectEqualStrings("true", objField(obj, "ok").?);
    try std.testing.expectEqualStrings("null", objField(obj, "n").?);
    try std.testing.expectEqualStrings("[{\"id\":1}]", objField(obj, "arr").?);
    try std.testing.expectEqualStrings("{\"id\":374,\"slug\":\"inner\"}", objField(obj, "mangaPost").?);
    try std.testing.expect(objField(obj, "postTitle") == null);
    // Truncated / non-object input never crashes or over-reads.
    try std.testing.expect(objField("", "id") == null);
    try std.testing.expect(objField("{", "id") == null);
    try std.testing.expect(objField("{\"id", "id") == null);
    try std.testing.expect(objField("{\"id\":", "id") == null);
    try std.testing.expect(objField("{\"slug\":\"abc", "slug") == null);
    try std.testing.expect(objField("{\"a\":{\"id\":1", "id") == null);
    try std.testing.expect(objField("<html>", "id") == null);
}

test "Iken query: posts parsed, novels skipped, shape detection" {
    try std.testing.expect(isIkenQuery(IKEN_QUERY));
    try std.testing.expect(isIkenQuery("{\"posts\":[],\"totalCount\":0,\"searchTerm\":\"zz\"}"));
    // HeanCms body / the 404 JSON a migrated site returns / an HTML wall are NOT Iken.
    try std.testing.expect(!isIkenQuery(QUERY_SAMPLE));
    try std.testing.expect(!isIkenQuery("{\"error\":\"Not Found\",\"message\":\"The requested resource was not found\"}"));
    try std.testing.expect(!isIkenQuery("<!DOCTYPE html><title>Just a moment...</title>"));

    var it = ObjIter{ .buf = ikenPostsNode(IKEN_QUERY).? };
    const a = parseIkenPost(it.next().?).?;
    try std.testing.expectEqualStrings("375", a.id);
    try std.testing.expectEqualStrings("the-subcontractors-blueprint", a.slug);
    try std.testing.expectEqualStrings("The Subcontractor's Blueprint", a.title);
    try std.testing.expect(std.mem.startsWith(u8, a.thumbnail, "https://storage.hivetoon.com/public/upload/series/featured/"));
    // seriesType NOVEL → not a page-image series.
    try std.testing.expect(parseIkenPost(it.next().?) == null);
    // Shuffled key order + null cover + \u-escaped title still parse; the row's
    // own id wins over the nested genre id that precedes it.
    const c = parseIkenPost(it.next().?).?;
    try std.testing.expectEqualStrings("374", c.id);
    try std.testing.expectEqualStrings("the-northern-grand-dukes-crazy-live-in-son-in-law", c.slug);
    try std.testing.expectEqualStrings("", c.thumbnail);
    var t: [128]u8 = undefined;
    const tn = jsonUnescape(c.title, &t);
    try std.testing.expectEqualStrings("The Northern Grand Duke\u{2019}s Crazy Live-In Son-in-Law", t[0..tn]);
    try std.testing.expect(it.next() == null);
}

test "Iken detail: post node id/title; novel + non-Iken rejected" {
    try std.testing.expect(isIkenPost(IKEN_POST));
    try std.testing.expect(!isIkenPost(DETAIL_SAMPLE));
    try std.testing.expect(!isIkenPost("{\"message\":\"Either post slug or post ID is required\"}"));
    const d = parseIkenDetail(IKEN_POST).?;
    try std.testing.expectEqualStrings("375", d.id);
    try std.testing.expectEqualStrings("the-subcontractors-blueprint", d.slug);
    try std.testing.expectEqualStrings("The Subcontractor's Blueprint", d.title);
    try std.testing.expect(parseIkenDetail("{\"post\":{\"id\":9,\"slug\":\"n\",\"postTitle\":\"N\",\"isNovel\":true}}") == null);
    try std.testing.expect(parseIkenDetail("{\"post\":null}") == null);
}

test "firstFreeIkenChapter: coin-locked chapter skipped, nested mangaPost id ignored" {
    const ch = firstFreeIkenChapter(IKEN_CHAPTERS).?;
    // 21823 is the chapter's id; 374 is the nested mangaPost id that precedes it.
    try std.testing.expectEqualStrings("21823", ch.id);
    try std.testing.expectEqualStrings("chapter-8", ch.slug);
    try std.testing.expectEqualStrings("8", ch.number);
    try std.testing.expect(ch.free);

    var it = ObjIter{ .buf = objField(objField(IKEN_CHAPTERS, "post").?, "chapters").? };
    const locked = parseIkenChapter(it.next().?).?;
    try std.testing.expectEqualStrings("21909", locked.id);
    try std.testing.expect(!locked.free);

    // Each lock signal alone is enough; no flags + no price ⇒ free.
    try std.testing.expect(!parseIkenChapter("{\"id\":1,\"isAccessible\":false}").?.free);
    try std.testing.expect(!parseIkenChapter("{\"id\":1,\"isPermanentlyLocked\":true}").?.free);
    try std.testing.expect(!parseIkenChapter("{\"id\":1,\"price\":50}").?.free);
    try std.testing.expect(parseIkenChapter("{\"id\":1,\"number\":1.5}").?.free);
    try std.testing.expect(parseIkenChapter("{\"slug\":\"chapter-1\"}") == null); // no id → can't fetch pages

    try std.testing.expect(firstFreeIkenChapter("{\"post\":{\"chapters\":[{\"id\":1,\"isLocked\":true}]},\"totalChapterCount\":1}") == null);
    try std.testing.expect(firstFreeIkenChapter("{\"post\":{\"chapters\":[]},\"totalChapterCount\":0}") == null);
    try std.testing.expect(firstFreeIkenChapter(CHAPTERS_SAMPLE) == null); // HeanCms shape
    try std.testing.expect(firstFreeIkenChapter("{\"post\":{\"chapters\":[{\"id\":1,\"price\":0") == null); // truncated
}

test "IkenImageIter: image objects → url in order; locked/novel/garbage yield none" {
    var it = IkenImageIter.init(IKEN_PAGES);
    try std.testing.expectEqualStrings(
        "https://storage.hivetoon.com/public/upload/series/the-subcontractors-blueprint/e578908d-8f4b-4859-bf35-0c380b77bff8/page-0001_01_1793817704302-216377.webp",
        it.next().?,
    );
    // Second object has `url` after height/width (eternalmangas key order); the
    // chapter's own featuredImage / mangaPost cover are never mistaken for pages.
    try std.testing.expectEqualStrings("https://storage.eternalmangas.org//upload/series/el-error-perfecto/motek8Hm3S/01.webp", it.next().?);
    try std.testing.expect(it.next() == null);

    var locked = IkenImageIter.init(IKEN_PAGES_LOCKED);
    try std.testing.expect(locked.next() == null);
    var legacy = IkenImageIter.init(PAGES_NEW);
    try std.testing.expect(legacy.next() == null);
    var junk = IkenImageIter.init("<html>403</html>");
    try std.testing.expect(junk.next() == null);
    var cut = IkenImageIter.init("{\"chapter\":{\"images\":[{\"url\":\"https://a.test/1.webp\"},{\"url\":\"https://a");
    try std.testing.expect(cut.next() == null);
}

test "Iken chapter navigation survives pagination and skips locked chapters" {
    var nav: IkenNavigation = .{};
    _ = nav.append("{\"post\":{\"chapters\":[{\"id\":1,\"number\":1},{\"id\":2,\"price\":50},{\"id\":3,\"number\":1.5}]}}", "3").?;
    try std.testing.expectEqualStrings("1", nav.previous.?.idSlice());
    try std.testing.expectEqualStrings("3", nav.current.?.idSlice());
    try std.testing.expectEqualStrings("1.5", nav.current.?.numberSlice());
    try std.testing.expect(nav.next == null);
    _ = nav.append("{\"post\":{\"chapters\":[{\"id\":4,\"isAccessible\":false},{\"id\":5}]}}", "3").?;
    try std.testing.expectEqualStrings("5", nav.next.?.idSlice());
    var first: IkenNavigation = .{};
    _ = first.append(IKEN_CHAPTERS, null).?;
    try std.testing.expect(first.previous == null);
    try std.testing.expect(first.current != null);
    var absent: IkenNavigation = .{};
    _ = absent.append(IKEN_CHAPTERS, "999999").?;
    try std.testing.expect(absent.current == null);
    var out: [256]u8 = undefined;
    const route = buildIkenChapterRoute(&out, "series-name", "21777").?;
    try std.testing.expectEqualStrings("series-name", slugFromRoute(route).?);
    try std.testing.expectEqualStrings("21777", chapterIdFromRoute(route).?);
    try std.testing.expect(slugFromRoute("heancms:x?chapter=1&extra=2") == null);
    try std.testing.expectEqualStrings("https://api.x/api/chapters?postId=1&skip=100&take=100&order=asc", buildIkenChapterListPageUrl(&out, "https://api.x", "1", 100).?);
}

/// Rebuild the header from series metadata, never from a prior chapter label.
pub fn readerTitle(out: []u8, series: []const u8, chapter: []const u8) []const u8 {
    const base = if (series.len > 0) series else "HeanCms";
    if (chapter.len == 0) return base;
    return std.fmt.bufPrint(out, "{s} · {s}", .{ base, chapter }) catch base;
}

test "Iken chapter header replaces the prior chapter label" {
    var out: [256]u8 = undefined;
    _ = readerTitle(&out, "Series", "Ch. 1");
    try std.testing.expectEqualStrings("Series · Ch. 2", readerTitle(&out, "Series", "Ch. 2"));
    try std.testing.expectEqualStrings("Series", readerTitle(&out, "Series", ""));
}
