//! Pure (io-free, state-free) TMDB string helpers — unit-testable via `zig build
//! test`. The production parsers in tmdb_parse.zig / tmdb_api.zig / tmdb.zig call
//! into these so the tested logic IS the shipped logic.

const std = @import("std");

/// Rewrite an `https://…` URL to `http://…` into `buf`. Returns null if `url`
/// isn't https or `buf` is too small. Used by the TMDB HTTPS→HTTP fallback for
/// SNI-blocked networks (see memory: opal-tmdb-https-block).
pub fn httpsToHttp(url: []const u8, buf: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, "https://")) return null;
    return std.fmt.bufPrint(buf, "http://{s}", .{url["https://".len..]}) catch null;
}

/// True if `key` is a TMDB v4 Read-Access-Token (a JWT, "eyJ…") rather than a v3
/// API key (32-char hex). v4 tokens MUST be sent via `Authorization: Bearer`; a
/// v4 token in the `?api_key=` query param returns 401 "Invalid API key" (the
/// bug that broke resolver/AI TMDB lookups). v3 keys go in `?api_key=`.
pub fn keyIsV4(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "eyJ");
}

/// True if `body` looks like a JSON document (first non-whitespace byte is `{` or
/// `[`). Used to reject ISP/captive-portal block pages (HTML) that some networks
/// inject over plain HTTP — accepting that HTML as a "successful" TMDB response
/// poisoned the sticky HTTPS→HTTP fallback and made all content stop loading.
pub fn looksLikeJson(body: []const u8) bool {
    for (body) |ch| {
        switch (ch) {
            ' ', '\t', '\r', '\n' => continue,
            '{', '[' => return true,
            else => return false,
        }
    }
    return false;
}

/// String-aware splitter for a TMDB `"results":[ {…}, {…} ]` array. Fills `out`
/// with a slice for each top-level object, WITHOUT entering string literals — so
/// a `{` or `}` inside a title/overview can't desync the brace counter (the bug
/// that corrupted item ids and broke TV-detail for "FROM" / "House of the
/// Dragon"). Returns the object count (capped at out.len).
pub fn splitResultObjects(body: []const u8, out: [][]const u8) usize {
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
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
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

/// First non-negative integer following `key` in `s` (digits only). Used to pull
/// the top-level `"id":` out of a result object.
pub fn firstIntAfter(s: []const u8, key: []const u8) i64 {
    const ki = std.mem.indexOf(u8, s, key) orelse return 0;
    var i = ki + key.len;
    while (i < s.len and s[i] == ' ') i += 1;
    var v: i64 = 0;
    var any = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + @as(i64, s[i] - '0');
        any = true;
    }
    return if (any) v else 0;
}

test "splitResultObjects: brace inside a string doesn't desync (FROM/HotD regression)" {
    // The first result's overview contains a stray '}' — the old non-string-aware
    // splitter dropped/mis-sliced the SECOND result, corrupting its id.
    const body =
        "{\"page\":1,\"results\":[" ++
        "{\"id\":111,\"name\":\"Decoy\",\"overview\":\"a closing brace } in text\"}," ++
        "{\"id\":94997,\"name\":\"House of the Dragon\"}" ++
        "],\"total_pages\":1}";
    var out: [8][]const u8 = undefined;
    const n = splitResultObjects(body, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(i64, 111), firstIntAfter(out[0], "\"id\":"));
    try std.testing.expectEqual(@as(i64, 94997), firstIntAfter(out[1], "\"id\":"));
}

test "splitResultObjects: empty / missing results" {
    var out: [4][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), splitResultObjects("{\"x\":1}", &out));
    try std.testing.expectEqual(@as(usize, 0), splitResultObjects("{\"results\":[]}", &out));
}

test "splitResultObjects: nested object in a result stays one top-level slice" {
    const body = "{\"results\":[{\"id\":7,\"belongs_to\":{\"id\":99,\"name\":\"x\"}}]}";
    var out: [4][]const u8 = undefined;
    const n = splitResultObjects(body, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    // First "id": is still the top-level one.
    try std.testing.expectEqual(@as(i64, 7), firstIntAfter(out[0], "\"id\":"));
}

test "httpsToHttp rewrites only https" {
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://api.themoviedb.org/3/tv/94997",
        httpsToHttp("https://api.themoviedb.org/3/tv/94997", &buf).?,
    );
    try std.testing.expect(httpsToHttp("http://already", &buf) == null);
    try std.testing.expect(httpsToHttp("ftp://nope", &buf) == null);
}

test "keyIsV4 distinguishes JWT bearer tokens from v3 keys" {
    // v4 Read-Access-Token (JWT) → Bearer header.
    try std.testing.expect(keyIsV4("eyJhbGciOiJIUzI1NiJ9.payload.sig"));
    // v3 key (32-char hex) → ?api_key= query param.
    try std.testing.expect(!keyIsV4("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!keyIsV4(""));
}

test "looksLikeJson accepts JSON, rejects ISP HTML block pages" {
    try std.testing.expect(looksLikeJson("{\"results\":[]}"));
    try std.testing.expect(looksLikeJson("  \n\t [1,2,3]"));
    // The Airtel court-order block page that broke the HTTP fallback.
    try std.testing.expect(!looksLikeJson("<meta name=\"viewport\"><iframe src=\"http://www.airtel.in/court-orders/\">"));
    try std.testing.expect(!looksLikeJson("   "));
    try std.testing.expect(!looksLikeJson(""));
}
