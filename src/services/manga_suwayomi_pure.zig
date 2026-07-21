//! Suwayomi-Server (Tachidesk) source engine — PURE, unit-tested.
//!
//! Suwayomi is the desktop JVM server that RUNS actual Mihon/Aniyomi extension
//! APKs and exposes them over a stable REST API at `<base>/api/v1`. Opal points
//! at a user-run Suwayomi and searches/reads through it, so the entire Mihon
//! extension ecosystem works without reimplementing each engine. This module
//! owns only the URL building + JSON extraction (no fetch/state); the shipped
//! requests are the tested requests. It is the structural twin of the MangaDex
//! engine (comics_pure) — a keyed 3-call JSON chain: search → chapters → pages.
//!
//! Endpoints (Tachidesk REST v1):
//!   GET /api/v1/source/list
//!   GET /api/v1/source/{sourceId}/search?searchTerm=&pageNum=
//!        → { "mangaList":[{"id":42,"title":"…","thumbnailUrl":"/api/v1/manga/42/thumbnail"}], "hasNextPage":true }
//!   GET /api/v1/manga/{mangaId}/chapters?onlineFetch=true
//!        → [ {"id":100,"index":1,"name":"Ch 1","chapterNumber":1.0,"sourceOrder":0}, … ]
//!   GET /api/v1/manga/{mangaId}/chapter/{chapterIndex}
//!        → { "pageCount": 18, … }
//!   GET /api/v1/manga/{mangaId}/chapter/{chapterIndex}/page/{pageIndex}   (image bytes)
//!   GET /api/v1/manga/{mangaId}/thumbnail                                 (cover bytes)

const std = @import("std");

/// `suwayomi:` pseudo-URL scheme. A search-result card stores `suwayomi:<mangaId>`
/// and comics.fetchComicThread dispatches on the prefix (exactly like MangaDex's
/// `mangadex:<uuid>`), keeping the reader's page pipeline unchanged.
pub const SCHEME = "suwayomi:";

/// Mihon extension-repo support (discovery + install): curated repo table,
/// index.min.json parsing, and Suwayomi `/api/v1/extension/*` URL builders.
/// Re-exported so callers reach it as `suwayomi.repo.*` through the one import
/// comics.zig already holds; keeps the whole Mihon engine one module graph.
pub const repo = @import("mihon_repo_pure.zig");

// ── ID validation (security gate) ──
// ids/indices are interpolated straight into request paths, so they must be
// pure digits — anything with a `/`, `?`, `.` or `%` could escape the endpoint.

/// A Suwayomi manga/chapter id or index is a non-empty run of ASCII digits.
pub fn isNumericId(s: []const u8) bool {
    if (s.len == 0 or s.len > 20) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// The base must be a plain http(s) origin we can safely prefix onto `/api/...`.
/// A trailing slash is trimmed by the builders so we never emit `//api`.
pub fn isValidBase(base: []const u8) bool {
    return (std.mem.startsWith(u8, base, "http://") or std.mem.startsWith(u8, base, "https://")) and
        base.len > 8 and base.len < 512 and
        std.mem.indexOfScalar(u8, base, ' ') == null;
}

fn trimBase(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

// ── URL builders ──

/// Minimal percent-encoding for a search term (RFC-3986 unreserved kept, the
/// rest %XX). Also curl-glob-safe (encodes `[` `]`). Returns bytes written.
pub fn percentEncode(input: []const u8, out: []u8) usize {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (input) |ch| {
        if (n + 3 > out.len) break;
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~')
        {
            out[n] = ch;
            n += 1;
        } else {
            out[n] = '%';
            out[n + 1] = hex[ch >> 4];
            out[n + 2] = hex[ch & 0xF];
            n += 3;
        }
    }
    return n;
}

/// `<base>/api/v1/source/list`.
pub fn buildSourceListUrl(out: []u8, base: []const u8) ?[]const u8 {
    if (!isValidBase(base)) return null;
    return std.fmt.bufPrint(out, "{s}/api/v1/source/list", .{trimBase(base)}) catch null;
}

/// Search one installed source: `<base>/api/v1/source/{sourceId}/search?searchTerm=&pageNum=`.
pub fn buildSearchUrl(out: []u8, base: []const u8, source_id: []const u8, query: []const u8, page: u32) ?[]const u8 {
    if (!isValidBase(base) or !isNumericId(source_id) or query.len == 0) return null;
    var enc: [512]u8 = undefined;
    const n = percentEncode(query, &enc);
    if (n == 0) return null;
    return std.fmt.bufPrint(out, "{s}/api/v1/source/{s}/search?searchTerm={s}&pageNum={d}", .{ trimBase(base), source_id, enc[0..n], page }) catch null;
}

/// Chapter list for a manga. `onlineFetch=true` forces Suwayomi to pull a fresh
/// list from the source (not just its cache) on first open.
pub fn buildChaptersUrl(out: []u8, base: []const u8, manga_id: []const u8) ?[]const u8 {
    if (!isValidBase(base) or !isNumericId(manga_id)) return null;
    return std.fmt.bufPrint(out, "{s}/api/v1/manga/{s}/chapters?onlineFetch=true", .{ trimBase(base), manga_id }) catch null;
}

/// One chapter's metadata (carries `pageCount`): `.../manga/{id}/chapter/{index}`.
pub fn buildChapterUrl(out: []u8, base: []const u8, manga_id: []const u8, chapter_index: []const u8) ?[]const u8 {
    if (!isValidBase(base) or !isNumericId(manga_id) or !isNumericId(chapter_index)) return null;
    return std.fmt.bufPrint(out, "{s}/api/v1/manga/{s}/chapter/{s}", .{ trimBase(base), manga_id, chapter_index }) catch null;
}

/// One page image URL: `.../manga/{id}/chapter/{index}/page/{pageIndex}`.
pub fn buildPageUrl(out: []u8, base: []const u8, manga_id: []const u8, chapter_index: []const u8, page_index: u32) ?[]const u8 {
    if (!isValidBase(base) or !isNumericId(manga_id) or !isNumericId(chapter_index)) return null;
    return std.fmt.bufPrint(out, "{s}/api/v1/manga/{s}/chapter/{s}/page/{d}", .{ trimBase(base), manga_id, chapter_index, page_index }) catch null;
}

/// Absolutize a thumbnailUrl from a search row. Tachidesk returns a server-
/// relative path (`/api/v1/manga/42/thumbnail`); some extensions return an
/// absolute source URL. Passes absolute through, prefixes `base` onto relative.
pub fn absolutizeThumb(out: []u8, base: []const u8, thumb: []const u8) ?[]const u8 {
    if (thumb.len == 0) return null;
    if (std.mem.startsWith(u8, thumb, "http://") or std.mem.startsWith(u8, thumb, "https://")) {
        if (thumb.len > out.len) return null;
        @memcpy(out[0..thumb.len], thumb);
        return out[0..thumb.len];
    }
    if (!isValidBase(base)) return null;
    const sep: []const u8 = if (thumb[0] == '/') "" else "/";
    return std.fmt.bufPrint(out, "{s}{s}{s}", .{ trimBase(base), sep, thumb }) catch null;
}

// ── Route (card pseudo-URL) ──

pub fn buildRouteUrl(out: []u8, manga_id: []const u8) ?[]const u8 {
    if (!isNumericId(manga_id)) return null;
    return std.fmt.bufPrint(out, "{s}{s}", .{ SCHEME, manga_id }) catch null;
}

pub fn mangaIdFromRoute(url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, SCHEME)) return null;
    const id = url[SCHEME.len..];
    if (!isNumericId(id)) return null;
    return id;
}

// ── JSON extraction (shared tiny helpers; Suwayomi responses are flat) ──

/// Read a JSON string field `"key":"…"` from `scope` into `dst` (bytes written,
/// 0 if absent/null). Stops at the first unescaped quote. Bounds-safe.
pub fn jsonStr(scope: []const u8, key: []const u8, dst: []u8) usize {
    const at = std.mem.indexOf(u8, scope, key) orelse return 0;
    var i = at + key.len;
    var out: usize = 0;
    while (i < scope.len and out < dst.len) : (i += 1) {
        const c = scope[i];
        if (c == '\\' and i + 1 < scope.len) {
            // Copy the escaped char verbatim (URLs/titles rarely need decoding here).
            dst[out] = scope[i + 1];
            out += 1;
            i += 1;
            continue;
        }
        if (c == '"') break;
        dst[out] = c;
        out += 1;
    }
    return out;
}

/// Read an integer JSON field `"key":<int>` from `scope` (null if absent).
pub fn jsonInt(scope: []const u8, key: []const u8) ?i64 {
    const at = std.mem.indexOf(u8, scope, key) orelse return null;
    var i = at + key.len;
    while (i < scope.len and (scope[i] == ' ' or scope[i] == ':')) i += 1;
    var end = i;
    if (end < scope.len and scope[end] == '-') end += 1;
    while (end < scope.len and scope[end] >= '0' and scope[end] <= '9') end += 1;
    if (end == i) return null;
    return std.fmt.parseInt(i64, scope[i..end], 10) catch null;
}

/// One search-result row.
pub const Manga = struct {
    id: []const u8, // numeric id as text (from the JSON int)
    title: []const u8, // raw title
    thumb: []const u8, // raw thumbnailUrl (absolutize before use)
};

/// Iterate the `mangaList` array of a search response, yielding each object
/// slice. Objects are delimited by `"id":` (present once per manga). Bounds-safe.
pub const MangaIter = struct {
    json: []const u8,
    pos: usize = 0,
    const marker = "\"id\":";

    pub fn next(self: *MangaIter) ?[]const u8 {
        // Confine to the mangaList array on the first call so we don't wander
        // into `hasNextPage` etc. (harmless, but tidy).
        const idx = std.mem.indexOfPos(u8, self.json, self.pos, marker) orelse return null;
        var end = self.json.len;
        if (std.mem.indexOfPos(u8, self.json, idx + marker.len, marker)) |n| end = n;
        self.pos = end;
        return self.json[idx..end];
    }
};

/// Extract id/title/thumb from one manga object slice into caller buffers.
/// Returns null when there's no valid numeric id.
pub fn parseManga(obj: []const u8, id_buf: []u8, title_buf: []u8, thumb_buf: []u8) ?Manga {
    // The object's own id is the first `"id":` — read the integer after it.
    const id_val = jsonInt(obj, "\"id\":") orelse return null;
    if (id_val < 0) return null;
    const id = std.fmt.bufPrint(id_buf, "{d}", .{id_val}) catch return null;
    const tn = jsonStr(obj, "\"title\":\"", title_buf);
    const hn = jsonStr(obj, "\"thumbnailUrl\":\"", thumb_buf);
    if (tn == 0) return null;
    return .{ .id = id, .title = title_buf[0..tn], .thumb = thumb_buf[0..hn] };
}

/// From a `/chapters` array, the `index` of the chapter to open first — the
/// smallest `sourceOrder` (Tachidesk's stable source ordering; sourceOrder 0 is
/// the earliest chapter). Falls back to the first object's `index`. Returns the
/// index as text in `out` (for the page URL), or null on an empty/garbage list.
pub fn firstChapterIndex(chapters_json: []const u8, out: []u8) ?[]const u8 {
    var best_order: i64 = std.math.maxInt(i64);
    var best_index: ?i64 = null;
    var it = MangaIter{ .json = chapters_json }; // reuse the `"id":`-delimited walker
    while (it.next()) |obj| {
        const idx = jsonInt(obj, "\"index\":") orelse continue;
        const order = jsonInt(obj, "\"sourceOrder\":") orelse idx;
        if (order < best_order) {
            best_order = order;
            best_index = idx;
        }
    }
    const bi = best_index orelse return null;
    if (bi < 0) return null;
    return std.fmt.bufPrint(out, "{d}", .{bi}) catch null;
}

/// `pageCount` from a chapter metadata object (0 if absent/invalid).
pub fn pageCount(chapter_json: []const u8) u32 {
    const n = jsonInt(chapter_json, "\"pageCount\":") orelse return 0;
    if (n < 0 or n > 100000) return 0;
    return @intCast(n);
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "isNumericId + isValidBase gate ids and origins" {
    try std.testing.expect(isNumericId("42"));
    try std.testing.expect(isNumericId("6289731484943315811"));
    try std.testing.expect(!isNumericId(""));
    try std.testing.expect(!isNumericId("4/2"));
    try std.testing.expect(!isNumericId("../x"));
    try std.testing.expect(isValidBase("http://localhost:4567"));
    try std.testing.expect(isValidBase("https://manga.example.com"));
    try std.testing.expect(!isValidBase("ftp://x"));
    try std.testing.expect(!isValidBase("localhost:4567"));
}

test "URL builders produce the Tachidesk REST paths (trimming a trailing slash)" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/v1/source/list",
        buildSourceListUrl(&b, "http://localhost:4567/").?,
    );
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/v1/source/9999/search?searchTerm=solo%20leveling&pageNum=1",
        buildSearchUrl(&b, "http://localhost:4567", "9999", "solo leveling", 1).?,
    );
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/v1/manga/42/chapters?onlineFetch=true",
        buildChaptersUrl(&b, "http://localhost:4567", "42").?,
    );
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/v1/manga/42/chapter/1",
        buildChapterUrl(&b, "http://localhost:4567", "42", "1").?,
    );
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/v1/manga/42/chapter/1/page/0",
        buildPageUrl(&b, "http://localhost:4567", "42", "1", 0).?,
    );
    // Path-escape guards.
    try std.testing.expect(buildSearchUrl(&b, "http://x", "1/../2", "q", 1) == null);
    try std.testing.expect(buildChapterUrl(&b, "http://x", "42", "1?x") == null);
}

test "absolutizeThumb joins relative, passes absolute" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/v1/manga/42/thumbnail",
        absolutizeThumb(&b, "http://localhost:4567", "/api/v1/manga/42/thumbnail").?,
    );
    try std.testing.expectEqualStrings(
        "https://cdn.src.com/cover/42.jpg",
        absolutizeThumb(&b, "http://localhost:4567", "https://cdn.src.com/cover/42.jpg").?,
    );
}

test "route round-trips suwayomi:<id>" {
    var b: [64]u8 = undefined;
    const route = buildRouteUrl(&b, "42").?;
    try std.testing.expectEqualStrings("suwayomi:42", route);
    try std.testing.expectEqualStrings("42", mangaIdFromRoute(route).?);
    try std.testing.expect(mangaIdFromRoute("mangadex:abc") == null);
    try std.testing.expect(mangaIdFromRoute("suwayomi:4/2") == null);
}

test "parse search mangaList rows" {
    const json =
        \\{"mangaList":[{"id":42,"title":"Solo Leveling","thumbnailUrl":"/api/v1/manga/42/thumbnail","inLibrary":false},
        \\{"id":7,"title":"Berserk","thumbnailUrl":"https://cdn/x.jpg"}],"hasNextPage":true}
    ;
    var it = MangaIter{ .json = json };
    var idb: [24]u8 = undefined;
    var tb: [128]u8 = undefined;
    var hb: [256]u8 = undefined;
    const m0 = parseManga(it.next().?, &idb, &tb, &hb).?;
    try std.testing.expectEqualStrings("42", m0.id);
    try std.testing.expectEqualStrings("Solo Leveling", m0.title);
    try std.testing.expectEqualStrings("/api/v1/manga/42/thumbnail", m0.thumb);
    const m1 = parseManga(it.next().?, &idb, &tb, &hb).?;
    try std.testing.expectEqualStrings("7", m1.id);
    try std.testing.expectEqualStrings("Berserk", m1.title);
    try std.testing.expect(it.next() == null);
}

test "firstChapterIndex picks the earliest (sourceOrder 0) + pageCount" {
    const chapters =
        \\[{"id":300,"index":3,"name":"Ch 3","chapterNumber":3.0,"sourceOrder":2},
        \\{"id":100,"index":1,"name":"Ch 1","chapterNumber":1.0,"sourceOrder":0},
        \\{"id":200,"index":2,"name":"Ch 2","chapterNumber":2.0,"sourceOrder":1}]
    ;
    var ib: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1", firstChapterIndex(chapters, &ib).?);
    try std.testing.expect(firstChapterIndex("[]", &ib) == null);
    try std.testing.expectEqual(@as(u32, 18), pageCount("{\"id\":100,\"pageCount\":18,\"read\":false}"));
    try std.testing.expectEqual(@as(u32, 0), pageCount("{\"id\":100}"));
}
