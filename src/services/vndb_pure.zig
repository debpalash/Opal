//! Pure parsing for the VNDB (Visual Novel Database) catalog tab — no app-state /
//! dvui imports, so the logic ships tested (registered as `test_vndb_pure` in
//! build.zig). Structural sibling of radio_pure.zig / tmdb_pure.zig.
//!
//! Data source: the modern VNDB HTTPS JSON API (no auth for public reads):
//!   POST https://api.vndb.org/kana/vn
//!   body: {"filters":["search","=","<q>"],"fields":"title, image.url,
//!          image.sexual, image.violence, released, rating, length, description",
//!          "results":30}
//!   → {"results":[{ "id":"v17", "title":"…", "image":{"url":"…","sexual":0,
//!                   "violence":0}, "released":"2004-08-27", "rating":85.3,
//!                   "length":4, "description":"…" }, …], "more":false}
//!
//! ── NSFW SAFETY (this is a catalog/info surface, non-NSFW only) ──
//! Every VNDB image carries community flag averages `sexual` and `violence`, each
//! a float in [0, 2] (0 = safe, 1 = suggestive, 2 = explicit). `parseVns` requests
//! those fields and routes every entry through `isSfw` at parse time — an entry
//! whose cover is flagged sexual at/above SEXUAL_MAX (or violence at/above
//! VIOLENCE_MAX) is DROPPED and never reaches the UI. Entries with no image (or
//! unrated flags, which default to 0) are treated as safe. The production fetch
//! worker calls only `parseVns`, so the tested filter IS the shipped filter.

const std = @import("std");

// ── SFW thresholds (drop anything at/above these) ──
// sexual/violence are averages in [0,2]. 1.0 = "suggestive"; we keep only covers
// that are predominantly safe (below suggestive) and reject anything leaning
// explicit. Kept low on purpose — this tab is SFW-only.
pub const SEXUAL_MAX: f32 = 1.0;
pub const VIOLENCE_MAX: f32 = 1.5;

/// The SFW filter decision, isolated + tested. Returns true when an entry's
/// cover flags are safe enough to display. Missing/unrated flags arrive as 0
/// (safe). Called for EVERY parsed entry (see parseVns) — this is the single
/// gate that keeps adult-flagged covers out of the catalog.
pub fn isSfw(sexual: f32, violence: f32) bool {
    return sexual < SEXUAL_MAX and violence < VIOLENCE_MAX;
}

// ── Fixed-buffer record (no dvui/atomics so std.mem.zeroes works). ──

pub const Vn = struct {
    id: [16]u8 = std.mem.zeroes([16]u8), // "v17"
    id_len: usize = 0,
    title: [256]u8 = std.mem.zeroes([256]u8),
    title_len: usize = 0,
    image_url: [256]u8 = std.mem.zeroes([256]u8),
    image_url_len: usize = 0,
    released: [12]u8 = std.mem.zeroes([12]u8), // "2004-08-27" | "2004" | ""
    released_len: usize = 0,
    description: [1024]u8 = std.mem.zeroes([1024]u8),
    description_len: usize = 0,
    rating: f32 = 0, // Bayesian, 10..100, 0 = unrated
    length: u8 = 0, // 1 (very short) .. 5 (very long), 0 = unknown
    // Retained cover-flag averages (0..2) — kept for display/debugging; the SFW
    // gate already ran at parse time, so only safe entries carry these.
    image_sexual: f32 = 0,
    image_violence: f32 = 0,
};

// ══════════════════════════════════════════════════════════
// Request-body builders (escape the search query for JSON)
// ══════════════════════════════════════════════════════════

/// The `fields` list requested from the API. image.sexual + image.violence are
/// load-bearing for the SFW filter; the rest drive the card + detail view.
pub const FIELDS = "title, image.url, image.sexual, image.violence, released, rating, length, description";

/// Escape a string for embedding inside a JSON double-quoted value: `"` and `\`
/// are backslash-escaped, control chars (< 0x20) are dropped. Returns the slice
/// written into `dst` (bounded by dst.len — a too-small buffer truncates rather
/// than overflowing).
pub fn jsonEscape(src: []const u8, dst: []u8) []const u8 {
    var out: usize = 0;
    for (src) |ch| {
        switch (ch) {
            '"', '\\' => {
                if (out + 2 > dst.len) break;
                dst[out] = '\\';
                dst[out + 1] = ch;
                out += 2;
            },
            0...0x1f => {}, // drop control chars (would produce invalid JSON)
            else => {
                if (out + 1 > dst.len) break;
                dst[out] = ch;
                out += 1;
            },
        }
    }
    return dst[0..out];
}

/// Build the POST body for a title search. Returns "" only if `dst` is too small
/// (never a truncated, malformed body).
pub fn buildSearchBody(query: []const u8, dst: []u8) []const u8 {
    var esc_buf: [512]u8 = undefined;
    const esc = jsonEscape(query, &esc_buf);
    return std.fmt.bufPrint(
        dst,
        "{{\"filters\":[\"search\",\"=\",\"{s}\"],\"fields\":\"{s}\",\"results\":30}}",
        .{ esc, FIELDS },
    ) catch "";
}

/// Build the POST body for the default "popular" browse view (most-voted VNs).
/// Sorted by votecount desc so the tab opens populated with well-known titles.
pub fn buildPopularBody(dst: []u8) []const u8 {
    return std.fmt.bufPrint(
        dst,
        "{{\"filters\":[],\"fields\":\"{s}\",\"sort\":\"votecount\",\"reverse\":true,\"results\":30}}",
        .{FIELDS},
    ) catch "";
}

// ══════════════════════════════════════════════════════════
// JSON helpers (mirrors radio_pure.zig)
// ══════════════════════════════════════════════════════════

/// Decode the common JSON string escapes (\" \\ \/ \n \r \t \uXXXX) from `src`
/// into `dst`, returning bytes written (bounded by dst.len). Unknown escapes are
/// copied verbatim so we never corrupt.
pub fn jsonUnescape(src: []const u8, dst: []u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < dst.len) {
        const ch = src[i];
        if (ch != '\\' or i + 1 >= src.len) {
            dst[out] = ch;
            out += 1;
            i += 1;
            continue;
        }
        switch (src[i + 1]) {
            '"' => { dst[out] = '"'; out += 1; i += 2; },
            '\\' => { dst[out] = '\\'; out += 1; i += 2; },
            '/' => { dst[out] = '/'; out += 1; i += 2; },
            'n' => { dst[out] = '\n'; out += 1; i += 2; },
            'r' => { dst[out] = '\r'; out += 1; i += 2; },
            't' => { dst[out] = '\t'; out += 1; i += 2; },
            'u' => {
                if (i + 6 <= src.len) {
                    if (std.fmt.parseInt(u21, src[i + 2 .. i + 6], 16)) |cp| {
                        var u8b: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &u8b) catch 0;
                        if (n > 0 and out + n <= dst.len) {
                            @memcpy(dst[out .. out + n], u8b[0..n]);
                            out += n;
                        }
                        i += 6;
                    } else |_| {
                        dst[out] = '\\';
                        out += 1;
                        i += 1;
                    }
                } else {
                    dst[out] = '\\';
                    out += 1;
                    i += 1;
                }
            },
            else => { dst[out] = '\\'; out += 1; i += 1; },
        }
    }
    return out;
}

/// Find `key` (e.g. `"title":"`) in `scope`, then read the JSON string value up
/// to the next unescaped `"`, decoding escapes into `dst`. Returns bytes written,
/// or 0 if the key is absent. Bounds-safe against a truncated value.
fn jsonStrField(scope: []const u8, key: []const u8, dst: []u8) usize {
    const at = std.mem.indexOf(u8, scope, key) orelse return 0;
    const start = at + key.len;
    var end = start;
    var esc = false;
    while (end < scope.len) : (end += 1) {
        if (esc) {
            esc = false;
        } else if (scope[end] == '\\') {
            esc = true;
        } else if (scope[end] == '"') {
            break;
        }
    }
    return jsonUnescape(scope[start..@min(end, scope.len)], dst);
}

/// Read an unquoted JSON number following `key` (e.g. `"rating":`) as a float.
/// Returns 0 when the key is absent or the value is `null`/non-numeric. Handles
/// an optional decimal part.
fn jsonFloatField(scope: []const u8, key: []const u8) f32 {
    const at = std.mem.indexOf(u8, scope, key) orelse return 0;
    var i = at + key.len;
    while (i < scope.len and (scope[i] == ' ' or scope[i] == '\t')) : (i += 1) {}
    const num_start = i;
    if (i < scope.len and scope[i] == '-') i += 1;
    while (i < scope.len and ((scope[i] >= '0' and scope[i] <= '9') or scope[i] == '.')) : (i += 1) {}
    if (i == num_start) return 0;
    return std.fmt.parseFloat(f32, scope[num_start..i]) catch 0;
}

/// The top-level `"id"` string of a VN object (e.g. `"v17"`), into `dst`.
fn readId(scope: []const u8, dst: []u8) usize {
    return jsonStrField(scope, "\"id\":\"", dst);
}

/// Locate the nested `"image":{ … }` object inside a VN object and return its
/// inner slice (between the braces), or null if the image is absent/null. The
/// scan is string-aware + brace-balanced so a `}` inside a nested string can't
/// end the object early.
fn imageScope(obj: []const u8) ?[]const u8 {
    const key = "\"image\":";
    const at = std.mem.indexOf(u8, obj, key) orelse return null;
    var i = at + key.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) : (i += 1) {}
    if (i >= obj.len or obj[i] != '{') return null; // "image":null → no scope
    const open = i;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    while (i < obj.len) : (i += 1) {
        const c = obj[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return obj[open + 1 .. i];
            },
            else => {},
        }
    }
    return null;
}

/// String-aware splitter for a VNDB `"results":[ {…}, {…} ]` array. Fills `out`
/// with a slice for each top-level object WITHOUT entering string literals, so a
/// `{`/`}`/`]` inside a description can't desync the brace counter. Returns the
/// object count (capped at out.len).
fn splitResultObjects(body: []const u8, out: [][]const u8) usize {
    const key = "\"results\":[";
    const rs = std.mem.indexOf(u8, body, key) orelse return 0;
    var i = rs + key.len;
    var depth: i32 = 0;
    var obj_start: ?usize = null;
    var in_str = false;
    var esc = false;
    var count: usize = 0;
    while (i < body.len and count < out.len) : (i += 1) {
        const c = body[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => {
                if (depth == 0) obj_start = i;
                depth += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    if (obj_start) |s| {
                        out[count] = body[s .. i + 1];
                        count += 1;
                        obj_start = null;
                    }
                }
            },
            ']' => if (depth == 0) break,
            else => {},
        }
    }
    return count;
}

// ══════════════════════════════════════════════════════════
// Response parse (+ SFW filter)
// ══════════════════════════════════════════════════════════

/// Parse a VNDB `/vn` response into `out`, applying the SFW filter (isSfw) to
/// every entry — sexual/violence-flagged covers are DROPPED. An entry with no
/// title is skipped. Returns the number of SFW entries written (≤ out.len).
/// Bounds-safe: a malformed body yields 0, never a panic (worker-thread safe).
pub fn parseVns(json: []const u8, out: []Vn) usize {
    var objs: [64][]const u8 = undefined;
    const n = splitResultObjects(json, &objs);
    var count: usize = 0;
    var oi: usize = 0;
    while (oi < n and count < out.len) : (oi += 1) {
        const obj = objs[oi];

        // Cover flags first — drop adult-flagged entries before anything else.
        var sexual: f32 = 0;
        var violence: f32 = 0;
        var img_url_len: usize = 0;
        var img_url: [256]u8 = std.mem.zeroes([256]u8);
        if (imageScope(obj)) |img| {
            sexual = jsonFloatField(img, "\"sexual\":");
            violence = jsonFloatField(img, "\"violence\":");
            img_url_len = jsonStrField(img, "\"url\":\"", &img_url);
        }
        if (!isSfw(sexual, violence)) continue; // NSFW gate

        var v = &out[count];
        v.* = .{};
        v.title_len = jsonStrField(obj, "\"title\":\"", &v.title);
        if (v.title_len == 0) continue; // unusable

        v.id_len = readId(obj, &v.id);
        v.released_len = jsonStrField(obj, "\"released\":\"", &v.released);
        v.description_len = jsonStrField(obj, "\"description\":\"", &v.description);
        v.rating = jsonFloatField(obj, "\"rating\":");
        const len_f = jsonFloatField(obj, "\"length\":");
        v.length = if (len_f >= 1 and len_f <= 5) @intFromFloat(len_f) else 0;
        v.image_sexual = sexual;
        v.image_violence = violence;
        @memcpy(v.image_url[0..img_url_len], img_url[0..img_url_len]);
        v.image_url_len = img_url_len;

        count += 1;
    }
    return count;
}

/// Human label for the coarse length bucket (1..5), or "" for unknown.
pub fn lengthLabel(length: u8) []const u8 {
    return switch (length) {
        1 => "Very short (< 2h)",
        2 => "Short (2–10h)",
        3 => "Medium (10–30h)",
        4 => "Long (30–50h)",
        5 => "Very long (> 50h)",
        else => "",
    };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "isSfw drops sexual/violence-flagged covers" {
    try std.testing.expect(isSfw(0, 0)); // safe
    try std.testing.expect(isSfw(0.4, 0.5)); // mild
    try std.testing.expect(!isSfw(1.0, 0)); // suggestive+ dropped
    try std.testing.expect(!isSfw(2.0, 0)); // explicit dropped
    try std.testing.expect(!isSfw(0, 1.5)); // gore dropped
}

test "jsonEscape escapes quotes/backslashes, drops control chars" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a\\\"b", jsonEscape("a\"b", &buf));
    try std.testing.expectEqualStrings("c\\\\d", jsonEscape("c\\d", &buf));
    try std.testing.expectEqualStrings("ef", jsonEscape("e\nf", &buf)); // \n dropped
}

test "buildSearchBody embeds an escaped query + fields" {
    var buf: [512]u8 = undefined;
    const body = buildSearchBody("Fate/stay", &buf);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"filters\":[\"search\",\"=\",\"Fate/stay\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image.sexual") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image.violence") != null);
    // A quote in the query is escaped, keeping the body valid JSON.
    const q = buildSearchBody("say \"hi\"", &buf);
    try std.testing.expect(std.mem.indexOf(u8, q, "say \\\"hi\\\"") != null);
    // Undersized buffer → "" (never a truncated body).
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", buildSearchBody("x", &tiny));
}

test "buildPopularBody requests the flag fields" {
    var buf: [512]u8 = undefined;
    const body = buildPopularBody(&buf);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"sort\":\"votecount\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image.sexual") != null);
}

test "parseVns extracts fields and DROPS a sexual-flagged entry" {
    const json =
        \\{"results":[
        \\{"id":"v17","title":"Ever17","image":{"url":"https:\/\/t\/1.jpg","sexual":0,"violence":0.2},"released":"2002-08-29","rating":85.3,"length":4,"description":"A mystery at { an aquapark }."},
        \\{"id":"v99","title":"Adult VN","image":{"url":"https:\/\/t\/nsfw.jpg","sexual":2,"violence":1},"released":"2010","rating":60,"length":3,"description":"nsfw"},
        \\{"id":"v42","title":"Clannad","image":{"url":"https:\/\/t\/2.jpg","sexual":0.3,"violence":0},"released":"2004-04-28","rating":90,"length":5,"description":"family drama"}
        \\],"more":false}
    ;
    var out: [8]Vn = undefined;
    const n = parseVns(json, &out);
    // The sexual=2 entry ("v99") is dropped → only two survive.
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("v17", out[0].id[0..out[0].id_len]);
    try std.testing.expectEqualStrings("Ever17", out[0].title[0..out[0].title_len]);
    try std.testing.expectEqualStrings("https://t/1.jpg", out[0].image_url[0..out[0].image_url_len]);
    try std.testing.expectEqualStrings("2002-08-29", out[0].released[0..out[0].released_len]);
    try std.testing.expectApproxEqAbs(@as(f32, 85.3), out[0].rating, 0.01);
    try std.testing.expectEqual(@as(u8, 4), out[0].length);
    // A brace inside the description didn't desync object splitting.
    try std.testing.expectEqualStrings("A mystery at { an aquapark }.", out[0].description[0..out[0].description_len]);
    // Second surviving entry is Clannad (v42), NOT the dropped v99.
    try std.testing.expectEqualStrings("Clannad", out[1].title[0..out[1].title_len]);
    try std.testing.expectEqual(@as(u8, 5), out[1].length);
}

test "parseVns handles null image / missing fields" {
    const json =
        \\{"results":[
        \\{"id":"v1","title":"No Image","image":null,"released":null,"rating":null,"length":null,"description":null}
        \\]}
    ;
    var out: [8]Vn = undefined;
    const n = parseVns(json, &out);
    // No image → flags default to 0 (safe) → kept; missing scalars → 0/empty.
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("No Image", out[0].title[0..out[0].title_len]);
    try std.testing.expectEqual(@as(usize, 0), out[0].image_url_len);
    try std.testing.expectEqual(@as(usize, 0), out[0].released_len);
    try std.testing.expectEqual(@as(f32, 0), out[0].rating);
    try std.testing.expectEqual(@as(u8, 0), out[0].length);
}

test "parseVns: malformed JSON never panics" {
    var out: [8]Vn = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseVns("", &out));
    try std.testing.expectEqual(@as(usize, 0), parseVns("{", &out));
    try std.testing.expectEqual(@as(usize, 0), parseVns("{\"results\":[", &out));
    try std.testing.expectEqual(@as(usize, 0), parseVns("{\"results\":[]}", &out));
    // Truncated object mid-string — must not read past end.
    _ = parseVns("{\"results\":[{\"id\":\"v1\",\"title\":\"x\",\"image\":{\"url\":\"http", &out);
    // Title-less entry is skipped.
    try std.testing.expectEqual(@as(usize, 0), parseVns("{\"results\":[{\"id\":\"v1\",\"image\":{\"sexual\":0}}]}", &out));
}

test "lengthLabel buckets" {
    try std.testing.expectEqualStrings("Very short (< 2h)", lengthLabel(1));
    try std.testing.expectEqualStrings("Very long (> 50h)", lengthLabel(5));
    try std.testing.expectEqualStrings("", lengthLabel(0));
    try std.testing.expectEqualStrings("", lengthLabel(9));
}
