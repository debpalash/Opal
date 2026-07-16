//! Pure parsing + URL building for the Audiobookshelf client — no app-state /
//! dvui / I/O imports, so the logic ships tested (registered as
//! `test_audiobookshelf_pure` in build.zig). The service (audiobookshelf.zig)
//! routes every parse + URL build through here so the tested logic IS the
//! shipped logic.
//!
//! Audiobookshelf (https://www.audiobookshelf.org) is a self-hosted, REST+JSON
//! audiobook/podcast server — the audio-first sibling of Jellyfin:
//!   POST /login {username,password}      → user.token  (extractToken)
//!   GET  /api/libraries        (Bearer)  → libraries[] (parseLibraries)
//!   GET  /api/libraries/{id}/items       → results[]   (parseItems)
//!   stream:  {server}/api/items/{id}/download?token={token}  (streamUrl)
//!   cover:   {server}/api/items/{id}/cover?token={token}     (coverUrl)
//!   GET  /api/me/progress/{id} (Bearer)  → currentTime (parseProgressSeconds)
//!
//! All parsers write into caller-provided fixed-buffer slices and return the
//! number of entries filled — bounds-safe on a worker thread (a malformed
//! payload must never trip a slice panic; a worker panic aborts the whole app).

const std = @import("std");

// ── Fixed-buffer records (shared with state.zig; no dvui/atomics so std.mem.zeroes works). ──

pub const Book = struct {
    id: [64]u8 = std.mem.zeroes([64]u8),
    id_len: usize = 0,
    title: [256]u8 = std.mem.zeroes([256]u8),
    title_len: usize = 0,
    // Author ("authorName") — the card subtitle. Optional.
    author: [160]u8 = std.mem.zeroes([160]u8),
    author_len: usize = 0,
    // Whole-item duration in seconds (media.duration). 0 when absent.
    duration_secs: i64 = 0,
};

pub const Library = struct {
    id: [64]u8 = std.mem.zeroes([64]u8),
    id_len: usize = 0,
    name: [96]u8 = std.mem.zeroes([96]u8),
    name_len: usize = 0,
    // "book" | "podcast" — drives which content the library holds.
    media_type: [16]u8 = std.mem.zeroes([16]u8),
    media_type_len: usize = 0,
};

// ══════════════════════════════════════════════════════════
// URL / header building
// ══════════════════════════════════════════════════════════

/// An Audiobookshelf library-item id is a UUID-ish token in practice. Be lenient
/// (alnum + dash/underscore, bounded) but reject anything that could escape the
/// `/api/items/{id}/…` path or inject query params into the streamed URL
/// (slash, dot, `?`, `&`, `=`, `%`, whitespace). This gates the id before it
/// reaches mpv / curl.
pub fn validItemId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Build the direct audio stream URL. The `?token=` query is how Audiobookshelf
/// authenticates a plain GET (same mechanism its cover endpoint uses, no header
/// needed) — so mpv can open it directly. `/download` streams the item's media
/// file (a single-file .m4b/.mp3 audiobook or podcast episode); see the caveat
/// in audiobookshelf.zig for multi-file items.
pub fn streamUrl(server: []const u8, id: []const u8, token: []const u8, buf: []u8) ?[]const u8 {
    if (!validItemId(id)) return null;
    return std.fmt.bufPrint(buf, "{s}/api/items/{s}/download?token={s}", .{ server, id, token }) catch null;
}

/// Build the cover-art URL (token query auth, like `<img>` GET — no header).
pub fn coverUrl(server: []const u8, id: []const u8, token: []const u8, buf: []u8) ?[]const u8 {
    if (!validItemId(id)) return null;
    return std.fmt.bufPrint(buf, "{s}/api/items/{s}/cover?token={s}", .{ server, id, token }) catch null;
}

/// Build the `GET /api/libraries/{id}/items?limit=&page=` URL for one page of a
/// library's books. `page` is 0-based (ABS convention). Used both for the
/// initial library-open fetch (page 0) and every infinite-scroll loadMore()
/// page (same `limit` each time, so a short page reliably signals the end) —
/// see audiobookshelf.zig's `ABS_PAGE_LIMIT` / `loadMore`. Library ids are the
/// same UUID-ish token shape as item ids, so `validItemId` gates this one too.
pub fn libraryItemsUrl(server: []const u8, lib_id: []const u8, limit: u32, page: u32, buf: []u8) ?[]const u8 {
    if (!validItemId(lib_id)) return null;
    return std.fmt.bufPrint(buf, "{s}/api/libraries/{s}/items?limit={d}&page={d}", .{ server, lib_id, limit, page }) catch null;
}

/// Cache key EXCLUDES the token so a token rotation can't orphan cached covers.
pub fn coverCacheKey(server: []const u8, id: []const u8, buf: []u8) ?[]const u8 {
    if (!validItemId(id)) return null;
    return std.fmt.bufPrint(buf, "{s}/api/items/{s}/cover", .{ server, id }) catch null;
}

/// Build the `Authorization: Bearer <token>` header for the REST endpoints.
pub fn bearerHeader(token: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "Authorization: Bearer {s}", .{token}) catch null;
}

// ══════════════════════════════════════════════════════════
// JSON scanning helpers (bounded, allocation-free)
// ══════════════════════════════════════════════════════════

/// Extract the string value that follows `key` (a full `"name":"` token) in
/// `json`, honouring escaped quotes. Returns the RAW (still-escaped) slice.
fn extractString(json: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    const start = idx + key.len;
    if (start > json.len) return null;
    var end = start;
    while (end < json.len) : (end += 1) {
        if (json[end] == '"' and (end == start or json[end - 1] != '\\')) break;
    }
    if (end > json.len) return null;
    return json[start..end];
}

/// Extract the integer value that follows `key` (e.g. a `"duration":` token).
/// Stops at the first non-digit, so a float like `1234.56` yields the integer
/// part (1234) — whole seconds is all we surface.
fn extractInt(json: []const u8, key: []const u8) ?i64 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    var start = idx + key.len;
    // Skip whitespace after the colon.
    while (start < json.len and (json[start] == ' ' or json[start] == '\t')) : (start += 1) {}
    var end = start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i64, json[start..end], 10) catch null;
}

/// Extract the float value that follows `key` (e.g. `"currentTime":`).
fn extractFloat(json: []const u8, key: []const u8) ?f64 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    var start = idx + key.len;
    while (start < json.len and (json[start] == ' ' or json[start] == '\t')) : (start += 1) {}
    var end = start;
    while (end < json.len and ((json[end] >= '0' and json[end] <= '9') or json[end] == '.' or json[end] == '-' or json[end] == '+' or json[end] == 'e' or json[end] == 'E')) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseFloat(f64, json[start..end]) catch null;
}

/// Find the end (exclusive) of the JSON object that opens at `start` ('{'),
/// counting braces while ignoring braces inside strings.
fn findObjEnd(json: []const u8, start: usize) usize {
    var depth: i32 = 0;
    var i = start;
    var in_string = false;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (c == '"' and (i == 0 or json[i - 1] != '\\')) {
            in_string = !in_string;
        } else if (!in_string) {
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) return i + 1;
            }
        }
    }
    return json.len;
}

fn copyInto(dst: []u8, dst_len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    dst_len.* = n;
}

// ══════════════════════════════════════════════════════════
// Response parsers
// ══════════════════════════════════════════════════════════

/// Extract the auth token from a `POST /login` response. The token lives at
/// `user.token`; scope the lookup to the `"user":` object so an unrelated
/// top-level `"token"` (if any) can't shadow it, with a lenient fallback.
pub fn extractToken(login_json: []const u8) ?[]const u8 {
    const user_key = "\"user\":";
    if (std.mem.indexOf(u8, login_json, user_key)) |ui| {
        if (extractString(login_json[ui..], "\"token\":\"")) |tok| {
            if (tok.len > 0) return tok;
        }
    }
    // Fallback: first "token" anywhere (older/edge response shapes).
    const tok = extractString(login_json, "\"token\":\"") orelse return null;
    if (tok.len == 0) return null;
    return tok;
}

/// Iterate the top-level objects of the JSON array introduced by `array_key`
/// (e.g. `"libraries":`), slicing each element by BRACE DEPTH so a nested array
/// (`folders`) or object (`media`) never fools the boundary. Calls `fill(obj)`
/// per element; a false return drops that element. Returns the count accepted.
fn forEachArrayObject(
    json: []const u8,
    array_key: []const u8,
    ctx: anytype,
    comptime fill: fn (@TypeOf(ctx), []const u8) bool,
) usize {
    var count: usize = 0;
    const ki = std.mem.indexOf(u8, json, array_key) orelse return 0;
    var i = ki + array_key.len;
    // Advance to the array's opening bracket.
    while (i < json.len and json[i] != '[') : (i += 1) {}
    if (i >= json.len) return 0;
    i += 1; // past '['
    while (i < json.len) {
        // Skip separators / whitespace between elements.
        while (i < json.len and (json[i] == ' ' or json[i] == ',' or json[i] == '\n' or json[i] == '\r' or json[i] == '\t')) : (i += 1) {}
        if (i >= json.len or json[i] == ']') break;
        if (json[i] != '{') break; // not an object array → stop
        const obj_end = findObjEnd(json, i);
        if (fill(ctx, json[i..obj_end])) count += 1;
        if (obj_end <= i) break; // guard against no-progress on truncated input
        i = obj_end;
    }
    return count;
}

const LibSink = struct {
    out: []Library,
    n: usize = 0,
    fn fill(self: *LibSink, obj: []const u8) bool {
        if (self.n >= self.out.len) return false;
        var lib = Library{};
        if (extractString(obj, "\"id\":\"")) |id| copyInto(&lib.id, &lib.id_len, id);
        if (extractString(obj, "\"name\":\"")) |name| copyInto(&lib.name, &lib.name_len, name);
        if (extractString(obj, "\"mediaType\":\"")) |mt| copyInto(&lib.media_type, &lib.media_type_len, mt);
        if (lib.id_len == 0) return false; // skip fragments
        self.out[self.n] = lib;
        self.n += 1;
        return true;
    }
};

/// Parse `GET /api/libraries` → the `libraries[]` array into `out`. Returns the
/// count filled. Each library object carries `id`, `name`, `mediaType`.
pub fn parseLibraries(json: []const u8, out: []Library) usize {
    var sink = LibSink{ .out = out };
    return forEachArrayObject(json, "\"libraries\":", &sink, LibSink.fill);
}

const BookSink = struct {
    out: []Book,
    n: usize = 0,
    fn fill(self: *BookSink, obj: []const u8) bool {
        if (self.n >= self.out.len) return false;
        var book = Book{};
        // First "id" in the item object is the top-level library-item id (it
        // precedes the nested media object).
        if (extractString(obj, "\"id\":\"")) |id| copyInto(&book.id, &book.id_len, id);
        if (extractString(obj, "\"title\":\"")) |title| copyInto(&book.title, &book.title_len, title);
        if (extractString(obj, "\"authorName\":\"")) |a| copyInto(&book.author, &book.author_len, a);
        if (extractInt(obj, "\"duration\":")) |d| book.duration_secs = d;
        if (book.id_len == 0) return false;
        self.out[self.n] = book;
        self.n += 1;
        return true;
    }
};

/// Parse `GET /api/libraries/{id}/items` → the `results[]` array into `out`.
/// Returns the count filled. Each item object carries a top-level `id` and a
/// nested `media.metadata.{title,authorName}` + `media.duration`.
pub fn parseItems(json: []const u8, out: []Book) usize {
    var sink = BookSink{ .out = out };
    return forEachArrayObject(json, "\"results\":", &sink, BookSink.fill);
}

/// Parse `GET /api/me/progress/{id}` → the saved `currentTime` (seconds). Null
/// when the payload has no progress (server returns 404/empty for an unstarted
/// item), so the caller starts from 0.
pub fn parseProgressSeconds(json: []const u8) ?f64 {
    const ct = extractFloat(json, "\"currentTime\":") orelse return null;
    if (ct < 0) return null;
    return ct;
}

// ── Server-side resume decision ─────────────────────────────────────────────

/// Below this many seconds of saved progress we start at 0 — resuming a handful
/// of seconds in is noise, not a bookmark.
pub const RESUME_MIN_SECS: f64 = 15.0;
/// Within this many seconds of the end (or `isFinished`) counts as finished →
/// start over from 0 rather than seek to the last breath of the book.
pub const FINISH_MARGIN_SECS: f64 = 5.0;

/// The fields of an Audiobookshelf progress record the resume decision needs.
pub const ProgressInfo = struct {
    /// Saved playback position in seconds (`currentTime`). Null when absent.
    current_time: ?f64 = null,
    /// The item's whole duration in seconds (`duration`). Null when absent.
    duration: ?f64 = null,
    /// Server's own finished flag (`isFinished`). Defaults false.
    is_finished: bool = false,
};

/// Extract a JSON boolean value following `key`. Null when the key is absent or
/// the value is neither `true` nor `false`.
fn extractBool(json: []const u8, key: []const u8) ?bool {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    var start = idx + key.len;
    while (start < json.len and (json[start] == ' ' or json[start] == '\t')) : (start += 1) {}
    if (std.mem.startsWith(u8, json[start..], "true")) return true;
    if (std.mem.startsWith(u8, json[start..], "false")) return false;
    return null;
}

/// Parse the `/api/me/progress/{id}` record into the fields the resume decision
/// consumes (`currentTime`, `duration`, `isFinished`). Missing fields default —
/// the whole record is optional, so a 404/empty body yields an all-defaults info
/// that `resumeTarget` reads as "start at 0".
pub fn parseProgress(json: []const u8) ProgressInfo {
    return .{
        .current_time = parseProgressSeconds(json),
        .duration = extractFloat(json, "\"duration\":"),
        .is_finished = extractBool(json, "\"isFinished\":") orelse false,
    };
}

/// Decide the second to seek to when a book (re)opens, or null to start from the
/// beginning. Starts from 0 when: no saved position, the position is under
/// `RESUME_MIN_SECS`, the server marked the item finished, or the position sits
/// within `FINISH_MARGIN_SECS` of the end (finished but the flag lagged).
pub fn resumeTarget(position_secs: ?f64, duration_secs: f64, is_finished: bool) ?f64 {
    const pos = position_secs orelse return null;
    if (is_finished) return null;
    if (pos <= RESUME_MIN_SECS) return null;
    if (duration_secs > 0 and pos >= duration_secs - FINISH_MARGIN_SECS) return null;
    return pos;
}

/// Compose `parseProgress` + `resumeTarget`: the single entry point the service
/// routes a progress-response body through. Null → start from the beginning.
pub fn resumeTargetFromJson(json: []const u8) ?f64 {
    const info = parseProgress(json);
    return resumeTarget(info.current_time, info.duration orelse 0, info.is_finished);
}

// ══════════════════════════════════════════════════════════
// Tests — captured sample JSON (live server verification is manual).
// ══════════════════════════════════════════════════════════

const sample_login =
    \\{"user":{"id":"usr_abc123","username":"palash","type":"root","token":"eyJhbGciOiJIUzI1NiJ9.sample","mediaProgress":[]},"userDefaultLibraryId":"lib_1"}
;

const sample_libraries =
    \\{"libraries":[
    \\  {"id":"lib_books","name":"Audiobooks","folders":[{"id":"fol_1"}],"displayOrder":1,"icon":"audiobookshelf","mediaType":"book","provider":"audible"},
    \\  {"id":"lib_pods","name":"Podcasts","folders":[],"displayOrder":2,"icon":"podcast","mediaType":"podcast","provider":"itunes"}
    \\]}
;

const sample_items =
    \\{"results":[
    \\  {"id":"li_book1","ino":"111","libraryId":"lib_books","folderId":"fol_1","path":"/x","mediaType":"book","media":{"metadata":{"title":"Project Hail Mary","authorName":"Andy Weir","narratorName":"Ray Porter"},"coverPath":"/covers/1.jpg","duration":58212.5,"numTracks":1}},
    \\  {"id":"li_book2","ino":"222","libraryId":"lib_books","folderId":"fol_1","path":"/y","mediaType":"book","media":{"metadata":{"title":"Dune","authorName":"Frank Herbert"},"coverPath":"/covers/2.jpg","duration":75600,"numTracks":22}}
    \\],"total":2,"limit":10,"page":0}
;

const sample_progress =
    \\{"id":"li_book1","libraryItemId":"li_book1","duration":58212.5,"progress":0.42,"currentTime":24449.3,"isFinished":false,"lastUpdate":1700000000000}
;

test "extractToken pulls user.token" {
    try std.testing.expectEqualStrings("eyJhbGciOiJIUzI1NiJ9.sample", extractToken(sample_login).?);
    // Missing token → null, no crash.
    try std.testing.expect(extractToken("{\"user\":{}}") == null);
    try std.testing.expect(extractToken("") == null);
    try std.testing.expect(extractToken("not json at all") == null);
}

test "parseLibraries reads id/name/mediaType" {
    var libs: [8]Library = undefined;
    const n = parseLibraries(sample_libraries, &libs);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("lib_books", libs[0].id[0..libs[0].id_len]);
    try std.testing.expectEqualStrings("Audiobooks", libs[0].name[0..libs[0].name_len]);
    try std.testing.expectEqualStrings("book", libs[0].media_type[0..libs[0].media_type_len]);
    try std.testing.expectEqualStrings("lib_pods", libs[1].id[0..libs[1].id_len]);
    try std.testing.expectEqualStrings("podcast", libs[1].media_type[0..libs[1].media_type_len]);
}

test "parseLibraries handles empty + malformed without crashing" {
    var libs: [8]Library = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseLibraries("{\"libraries\":[]}", &libs));
    try std.testing.expectEqual(@as(usize, 0), parseLibraries("", &libs));
    try std.testing.expectEqual(@as(usize, 0), parseLibraries("{\"libraries\":[{\"mediaType\":\"book\"", &libs));
    _ = parseLibraries("{{{\"mediaType\":\"book\",\"id\":", &libs); // truncated, must not panic
}

test "parseItems reads id/title/author/duration" {
    var books: [16]Book = undefined;
    const n = parseItems(sample_items, &books);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("li_book1", books[0].id[0..books[0].id_len]);
    try std.testing.expectEqualStrings("Project Hail Mary", books[0].title[0..books[0].title_len]);
    try std.testing.expectEqualStrings("Andy Weir", books[0].author[0..books[0].author_len]);
    try std.testing.expectEqual(@as(i64, 58212), books[0].duration_secs);
    try std.testing.expectEqualStrings("li_book2", books[1].id[0..books[1].id_len]);
    try std.testing.expectEqualStrings("Dune", books[1].title[0..books[1].title_len]);
    try std.testing.expectEqual(@as(i64, 75600), books[1].duration_secs);
}

test "parseItems tolerates missing fields + malformed" {
    var books: [16]Book = undefined;
    // Item with only id + mediaType (no media block) still parses; author/dur default.
    const partial = "{\"results\":[{\"id\":\"li_x\",\"mediaType\":\"book\"}]}";
    const n = parseItems(partial, &books);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("li_x", books[0].id[0..books[0].id_len]);
    try std.testing.expectEqual(@as(usize, 0), books[0].author_len);
    try std.testing.expectEqual(@as(i64, 0), books[0].duration_secs);
    // Empty + garbage → 0, no crash.
    try std.testing.expectEqual(@as(usize, 0), parseItems("{\"results\":[]}", &books));
    try std.testing.expectEqual(@as(usize, 0), parseItems("", &books));
    _ = parseItems("{\"results\":[{\"mediaType\":\"book\",\"media\":{\"metadata\":{", &books);
}

test "streamUrl + coverUrl embed token, cache key omits it, id is gated" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://abs.example/api/items/li_book1/download?token=TOK",
        streamUrl("https://abs.example", "li_book1", "TOK", &buf).?,
    );
    var cbuf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://abs.example/api/items/li_book1/cover?token=TOK",
        coverUrl("https://abs.example", "li_book1", "TOK", &cbuf).?,
    );
    var kbuf: [256]u8 = undefined;
    const key = coverCacheKey("https://abs.example", "li_book1", &kbuf).?;
    try std.testing.expect(std.mem.indexOf(u8, key, "token") == null);
    // Injection / traversal ids are rejected before any URL is built.
    try std.testing.expect(streamUrl("https://abs.example", "../etc", "TOK", &buf) == null);
    try std.testing.expect(streamUrl("https://abs.example", "id&x=1", "TOK", &buf) == null);
    try std.testing.expect(coverUrl("https://abs.example", "id?q", "TOK", &cbuf) == null);
}

test "libraryItemsUrl embeds limit + 0-based page, rejects a bad library id" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://abs.example/api/libraries/lib_books/items?limit=64&page=0",
        libraryItemsUrl("https://abs.example", "lib_books", 64, 0, &buf).?,
    );
    try std.testing.expectEqualStrings(
        "https://abs.example/api/libraries/lib_books/items?limit=64&page=3",
        libraryItemsUrl("https://abs.example", "lib_books", 64, 3, &buf).?,
    );
    // Injection / traversal ids are rejected before any URL is built.
    try std.testing.expect(libraryItemsUrl("https://abs.example", "../etc", 64, 0, &buf) == null);
    try std.testing.expect(libraryItemsUrl("https://abs.example", "id&x=1", 64, 0, &buf) == null);
}

test "bearerHeader builds Authorization" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Authorization: Bearer TOK123", bearerHeader("TOK123", &buf).?);
}

test "parseProgressSeconds reads currentTime, null when absent" {
    try std.testing.expectApproxEqAbs(@as(f64, 24449.3), parseProgressSeconds(sample_progress).?, 0.01);
    try std.testing.expect(parseProgressSeconds("{}") == null);
    try std.testing.expect(parseProgressSeconds("") == null);
}

const sample_progress_finished =
    \\{"id":"li_book2","libraryItemId":"li_book2","duration":75600,"progress":1,"currentTime":75600,"isFinished":true,"lastUpdate":1700000000000}
;

test "parseProgress reads currentTime, duration, isFinished" {
    const info = parseProgress(sample_progress);
    try std.testing.expectApproxEqAbs(@as(f64, 24449.3), info.current_time.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 58212.5), info.duration.?, 0.01);
    try std.testing.expect(info.is_finished == false);

    const fin = parseProgress(sample_progress_finished);
    try std.testing.expect(fin.is_finished == true);

    // Empty/absent → all defaults (start at 0 downstream).
    const empty = parseProgress("{}");
    try std.testing.expect(empty.current_time == null);
    try std.testing.expect(empty.is_finished == false);
}

test "resumeTarget: mid-book seeks, finished/near-end/too-early start at 0" {
    // Mid-book → seek to the saved second.
    try std.testing.expectApproxEqAbs(@as(f64, 24449.3), resumeTarget(24449.3, 58212.5, false).?, 0.01);
    // isFinished flag → start over.
    try std.testing.expect(resumeTarget(24449.3, 58212.5, true) == null);
    // Within FINISH_MARGIN of the end (flag lagged) → start over.
    try std.testing.expect(resumeTarget(58210, 58212.5, false) == null);
    // Under RESUME_MIN_SECS → noise, start at 0.
    try std.testing.expect(resumeTarget(9, 58212.5, false) == null);
    try std.testing.expect(resumeTarget(RESUME_MIN_SECS, 58212.5, false) == null);
    // No saved position → start at 0.
    try std.testing.expect(resumeTarget(null, 58212.5, false) == null);
    // Unknown duration (0) still resumes a healthy position.
    try std.testing.expectApproxEqAbs(@as(f64, 1200), resumeTarget(1200, 0, false).?, 0.01);
}

test "resumeTargetFromJson: mid-book book seeks, finished book starts at 0" {
    try std.testing.expectApproxEqAbs(@as(f64, 24449.3), resumeTargetFromJson(sample_progress).?, 0.01);
    try std.testing.expect(resumeTargetFromJson(sample_progress_finished) == null);
    // No progress record at all → start at 0, no crash.
    try std.testing.expect(resumeTargetFromJson("{}") == null);
    try std.testing.expect(resumeTargetFromJson("") == null);
}

test "validItemId accepts ABS ids, rejects injection" {
    try std.testing.expect(validItemId("li_book1"));
    try std.testing.expect(validItemId("a1b2-c3d4-e5f6"));
    try std.testing.expect(!validItemId(""));
    try std.testing.expect(!validItemId("../secret"));
    try std.testing.expect(!validItemId("id/file"));
    try std.testing.expect(!validItemId("id?token=x"));
    try std.testing.expect(!validItemId("a" ** 65));
}
