//! Pure helpers for Jellyfin image proxying — no I/O / state / dvui imports, so
//! the logic ships tested (registered as `test_jellyfin_pure` in build.zig).
//!
//! Both the desktop poster worker (jellyfin.zig fetchPoster) and the web
//! companion's `/api/jellyfin/poster` proxy (remote_stream.zig) route their URL
//! + cache-key building through here, so the two can never drift.

const std = @import("std");

/// A Jellyfin item id is a 32-char hex GUID in practice; be lenient (alnum +
/// dash, bounded) but reject anything that could escape the
/// `/Items/{id}/Images/Primary` path or inject extra query params into the
/// proxied URL (slash, dot, `?`, `&`, `=`, `%`, whitespace). This is the
/// gate the untrusted `?id=` query param passes before it reaches curl.
pub fn validItemId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn authRejected(status_code: u16) bool {
    return status_code == 401 or status_code == 403;
}

/// Extract the server's preferred media version from an item payload. The
/// server orders MediaSources authoritatively; keeping that id lets direct play
/// target the same version instead of silently assuming the item id.
pub fn firstMediaSourceId(item_json: []const u8) ?[]const u8 {
    const field_at = std.mem.indexOf(u8, item_json, "\"MediaSources\"") orelse return null;
    const array_rel = std.mem.indexOfScalar(u8, item_json[field_at..], '[') orelse return null;
    const array_start = field_at + array_rel + 1;
    const first_close_rel = std.mem.indexOfScalar(u8, item_json[array_start..], ']') orelse return null;
    const first_source = item_json[array_start .. array_start + first_close_rel];
    const id_at = std.mem.indexOf(u8, first_source, "\"Id\"") orelse return null;
    const colon_rel = std.mem.indexOfScalar(u8, first_source[id_at + 4 ..], ':') orelse return null;
    var pos = id_at + 4 + colon_rel + 1;
    while (pos < first_source.len and std.ascii.isWhitespace(first_source[pos])) : (pos += 1) {}
    if (pos >= first_source.len or first_source[pos] != '"') return null;
    pos += 1;
    const end_rel = std.mem.indexOfScalar(u8, first_source[pos..], '"') orelse return null;
    const id = first_source[pos .. pos + end_rel];
    return if (validItemId(id)) id else null;
}

/// Token-free playback URL. Authentication is carried in an HTTP header so it
/// cannot leak into history, logs, screenshots, or child HLS requests.
pub fn videoStreamUrl(server: []const u8, item_id: []const u8, media_source_id: []const u8, out: []u8) ?[]const u8 {
    if (server.len == 0 or !validItemId(item_id)) return null;
    if (media_source_id.len > 0) {
        if (!validItemId(media_source_id)) return null;
        return std.fmt.bufPrint(out, "{s}/Videos/{s}/stream?static=true&MediaSourceId={s}", .{ server, item_id, media_source_id }) catch null;
    }
    return std.fmt.bufPrint(out, "{s}/Videos/{s}/stream?static=true", .{ server, item_id }) catch null;
}

fn appendQueryPiece(out: []u8, used: *usize, piece: []const u8, separator: u8) bool {
    const extra: usize = @intFromBool(separator != 0);
    if (used.* + extra + piece.len > out.len) return false;
    if (separator != 0) {
        out[used.*] = separator;
        used.* += 1;
    }
    @memcpy(out[used.* .. used.* + piece.len], piece);
    used.* += piece.len;
    return true;
}

/// Remove the legacy query credential Jellyfin includes in generated stream
/// URLs. The player supplies X-Emby-Token instead, so every other transcode
/// parameter remains byte-for-byte intact.
pub fn stripApiKey(url: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, url, "\r\n\x00") != null) return null;
    const q = std.mem.indexOfScalar(u8, url, '?') orelse {
        if (url.len > out.len) return null;
        @memcpy(out[0..url.len], url);
        return out[0..url.len];
    };
    var used: usize = 0;
    if (!appendQueryPiece(out, &used, url[0..q], 0)) return null;
    var kept: usize = 0;
    var iter = std.mem.splitScalar(u8, url[q + 1 ..], '&');
    while (iter.next()) |piece| {
        if (piece.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, piece, '=') orelse piece.len;
        if (std.ascii.eqlIgnoreCase(piece[0..eq], "api_key")) continue;
        if (!appendQueryPiece(out, &used, piece, if (kept == 0) '?' else '&')) return null;
        kept += 1;
    }
    return out[0..used];
}

fn decodeJsonUrl(body: []const u8, start: usize, out: []u8) ?[]const u8 {
    var i = start;
    var used: usize = 0;
    while (i < body.len) {
        const ch = body[i];
        i += 1;
        if (ch == '"') return out[0..used];
        if (ch < 0x20 or used >= out.len) return null;
        if (ch != '\\') {
            out[used] = ch;
            used += 1;
            continue;
        }
        if (i >= body.len) return null;
        const escaped = body[i];
        i += 1;
        const decoded: u8 = switch (escaped) {
            '"', '\\', '/' => escaped,
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => blk: {
                if (i + 4 > body.len) return null;
                const value = std.fmt.parseInt(u16, body[i .. i + 4], 16) catch return null;
                i += 4;
                if (value > 0x7f) return null; // URLs must be percent-encoded.
                break :blk @intCast(value);
            },
            else => return null,
        };
        if (decoded < 0x20 or used >= out.len) return null;
        out[used] = decoded;
        used += 1;
    }
    return null;
}

/// Parse the first server-generated HLS transcode path from PlaybackInfo and
/// resolve it against the configured server. This bounded scanner avoids heap
/// copies of the server-generated URL (which initially contains an API key).
pub fn transcodingUrl(server: []const u8, body: []const u8, out: []u8) ?[]const u8 {
    const field = "\"TranscodingUrl\"";
    var search_at: usize = 0;
    while (search_at < body.len) {
        const rel = std.mem.indexOf(u8, body[search_at..], field) orelse return null;
        const field_at = search_at + rel;
        const source_start = std.mem.lastIndexOfScalar(u8, body[0..field_at], '{') orelse field_at;
        const source_prefix = body[source_start..field_at];
        if (std.mem.indexOf(u8, source_prefix, "\"SupportsTranscoding\"")) |support_at| {
            const tail = source_prefix[support_at + "\"SupportsTranscoding\"".len ..];
            if (std.mem.indexOfScalar(u8, tail, ':')) |colon| {
                var value_at = colon + 1;
                while (value_at < tail.len and std.ascii.isWhitespace(tail[value_at])) : (value_at += 1) {}
                const value = tail[value_at..];
                if (std.mem.startsWith(u8, value, "false")) {
                    search_at = field_at + field.len;
                    continue;
                }
            }
        }
        var pos = field_at + field.len;
        while (pos < body.len and std.ascii.isWhitespace(body[pos])) : (pos += 1) {}
        if (pos >= body.len or body[pos] != ':') {
            search_at = pos;
            continue;
        }
        pos += 1;
        while (pos < body.len and std.ascii.isWhitespace(body[pos])) : (pos += 1) {}
        if (pos >= body.len or body[pos] != '"') {
            search_at = pos;
            continue;
        }
        var decoded_buf: [4096]u8 = undefined;
        const path = decodeJsonUrl(body, pos + 1, &decoded_buf) orelse {
            search_at = pos + 1;
            continue;
        };
        if (path.len == 0 or path[0] != '/' or std.mem.indexOf(u8, path, "://") != null) {
            search_at = pos + 1;
            continue;
        }
        var clean_buf: [4096]u8 = undefined;
        const clean = stripApiKey(path, &clean_buf) orelse return null;
        return std.fmt.bufPrint(out, "{s}{s}", .{ server, clean }) catch null;
    }
    return null;
}

/// Build the authenticated primary-image URL (small thumbnail). `api_key` in the
/// query is how Jellyfin authenticates an `<img>`-style GET (no header needed).
pub fn primaryImageUrl(server: []const u8, id: []const u8, token: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/Items/{s}/Images/Primary?maxWidth=200&quality=80&api_key={s}", .{ server, id, token }) catch null;
}

/// Cache key EXCLUDES the api_key so a token rotation can't orphan every cached
/// Jellyfin poster in the shared disk cache.
pub fn primaryImageCacheKey(server: []const u8, id: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/Items/{s}/Images/Primary?maxWidth=200", .{ server, id }) catch null;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "validItemId accepts GUIDs, rejects injection" {
    try std.testing.expect(validItemId("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"));
    try std.testing.expect(validItemId("abc-123-DEF"));
    try std.testing.expect(!validItemId(""));
    // Path traversal / query injection attempts must be rejected.
    try std.testing.expect(!validItemId("../secret"));
    try std.testing.expect(!validItemId("id/Images"));
    try std.testing.expect(!validItemId("id&api_key=x"));
    try std.testing.expect(!validItemId("id?x=1"));
    try std.testing.expect(!validItemId("a b"));
    // Over-long is rejected (bound).
    try std.testing.expect(!validItemId("a" ** 65));
}

test "auth rejection is distinct from transport and server failures" {
    try std.testing.expect(authRejected(401));
    try std.testing.expect(authRejected(403));
    try std.testing.expect(!authRejected(0));
    try std.testing.expect(!authRejected(404));
    try std.testing.expect(!authRejected(500));
}

test "preferred media source and token-free stream URL are deterministic" {
    const body =
        \\{"Id":"ITEM1","MediaSources": [{"Id": "VERSION2","Path":"movie.mkv"},{"Id":"VERSION1"}]}
    ;
    try std.testing.expectEqualStrings("VERSION2", firstMediaSourceId(body).?);
    try std.testing.expect(firstMediaSourceId("{\"MediaSources\":[]}") == null);
    try std.testing.expect(firstMediaSourceId("{\"MediaSources\":[{\"Id\":\"../bad\"}]}") == null);

    var buf: [256]u8 = undefined;
    const selected = videoStreamUrl("https://jf.example", "ITEM1", "VERSION2", &buf).?;
    try std.testing.expectEqualStrings("https://jf.example/Videos/ITEM1/stream?static=true&MediaSourceId=VERSION2", selected);
    try std.testing.expect(std.mem.indexOf(u8, selected, "api_key") == null);
    const generic = videoStreamUrl("https://jf.example", "ITEM1", "", &buf).?;
    try std.testing.expectEqualStrings("https://jf.example/Videos/ITEM1/stream?static=true", generic);
}

test "PlaybackInfo transcode URL is resolved and stripped of query credentials" {
    const body =
        \\{"MediaSources":[{"SupportsTranscoding":false,"TranscodingUrl":"/bad.m3u8?api_key=BAD"},{"SupportsTranscoding":true,"TranscodingUrl":"/Videos/ITEM/master.m3u8?MediaSourceId=V2\u0026api_key=SECRET\u0026VideoCodec=h264"}]}
    ;
    var out: [1024]u8 = undefined;
    const url = transcodingUrl("https://jf.example", body, &out).?;
    try std.testing.expectEqualStrings("https://jf.example/Videos/ITEM/master.m3u8?MediaSourceId=V2&VideoCodec=h264", url);
    try std.testing.expect(std.mem.indexOf(u8, url, "SECRET") == null);
}

test "query credential stripping preserves order and rejects injection" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/x?a=1&b=2", stripApiKey("/x?a=1&API_KEY=s&b=2", &out).?);
    try std.testing.expectEqualStrings("/x", stripApiKey("/x?api_key=s", &out).?);
    try std.testing.expect(stripApiKey("/x?a=1\rInjected: yes", &out) == null);
}

test "primaryImageUrl embeds token, cache key omits it" {
    var buf: [256]u8 = undefined;
    const url = primaryImageUrl("https://jf.example", "ITEM1", "TOK", &buf).?;
    try std.testing.expectEqualStrings("https://jf.example/Items/ITEM1/Images/Primary?maxWidth=200&quality=80&api_key=TOK", url);

    var kbuf: [256]u8 = undefined;
    const key = primaryImageCacheKey("https://jf.example", "ITEM1", &kbuf).?;
    try std.testing.expectEqualStrings("https://jf.example/Items/ITEM1/Images/Primary?maxWidth=200", key);
    // The cache key must not contain the api_key (token-rotation safety).
    try std.testing.expect(std.mem.indexOf(u8, key, "api_key") == null);
}
