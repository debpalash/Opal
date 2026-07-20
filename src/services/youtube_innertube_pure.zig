//! Pure (io-free, state-free) YouTube InnerTube search helpers — unit-testable
//! via `zig build test`. `youtube.zig`'s fast path routes through these so the
//! tested logic IS the shipped logic: the POST body builder, the
//! `videoRenderer` iterator, every field extractor (title / channel / duration
//! text / view-count text / relative publish text), the thumbnail-URL builder,
//! and the channel-row rejection shared with the yt-dlp parser.
//!
//! Why InnerTube: `/youtubei/v1/search` answers in ~1s where spawning yt-dlp for
//! the same `ytsearch20:` costs ~18s (process start + extractor warm-up + its
//! own HTTP round trips). Search/metadata endpoints are NOT PO-token or
//! bot-wall gated — only playback stream URLs are — so the plain `WEB` client
//! works and is what returns the classic `videoRenderer` shape this parser
//! targets. No client is pinned anywhere in the search path on purpose: a pin
//! freezes us to today's YouTube (see the note in youtube.zig's runYtdlp).

const std = @import("std");

/// InnerTube web client identity. Version only has to be plausible; the
/// endpoint does not pin it.
pub const CLIENT_NAME = "WEB";
pub const CLIENT_VERSION = "2.20240401.00";

/// Search `params` blob meaning "type = video". Filters channel rows, shelves,
/// and Shorts server-side, so every returned `videoRenderer` is a real playable
/// video (the yt-dlp path has to reject channel rows client-side).
pub const PARAMS_VIDEOS_ONLY = "EgIQAQ%3D%3D";

pub const SEARCH_URL = "https://www.youtube.com/youtubei/v1/search?prettyPrint=false";
pub const BROWSE_URL = "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false";

/// `browse` params selecting a channel's "Videos" tab.
pub const CHANNEL_VIDEOS_PARAMS = "EgZ2aWRlb3PyBgQKAjoA";

/// Longest continuation token we'll carry. Search tokens run ~600 chars,
/// channel-browse tokens ~1500; 4 KB leaves comfortable headroom without
/// putting anything large on a worker stack.
pub const MAX_TOKEN_LEN: usize = 4096;

/// Longest slice of the response we scan for one video's fields. Bounds the
/// LAST renderer's window (every other one is bounded by the next marker).
const WINDOW_CAP: usize = 12 * 1024;
/// How far past a key we look for its nested text value. Keeps a missing field
/// from silently picking up the next field's value.
const FIELD_SPAN: usize = 512;

// ══════════════════════════════════════════════════════════
// Request body
// ══════════════════════════════════════════════════════════

/// JSON-escape `s` into `out`. Returns the written length, or null if `out` is
/// too small (callers treat that as "can't build the request").
pub fn jsonEscape(s: []const u8, out: []u8) ?usize {
    var n: usize = 0;
    for (s) |c| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (esc) |e| {
            if (n + e.len > out.len) return null;
            @memcpy(out[n .. n + e.len], e);
            n += e.len;
        } else if (c < 0x20) {
            if (n + 6 > out.len) return null;
            _ = std.fmt.bufPrint(out[n .. n + 6], "\\u{x:0>4}", .{c}) catch return null;
            n += 6;
        } else {
            if (n + 1 > out.len) return null;
            out[n] = c;
            n += 1;
        }
    }
    return n;
}

/// Build the InnerTube search POST body for `query`. Returns null on an empty
/// query or a buffer that can't hold it.
pub fn buildSearchBody(query: []const u8, out: []u8) ?[]const u8 {
    if (query.len == 0) return null;
    var esc: [1024]u8 = undefined;
    const n = jsonEscape(query, &esc) orelse return null;
    if (n == 0) return null;
    return std.fmt.bufPrint(
        out,
        "{{\"context\":{{\"client\":{{\"clientName\":\"{s}\",\"clientVersion\":\"{s}\",\"hl\":\"en\",\"gl\":\"US\"}}}},\"query\":\"{s}\",\"params\":\"{s}\"}}",
        .{ CLIENT_NAME, CLIENT_VERSION, esc[0..n], PARAMS_VIDEOS_ONLY },
    ) catch null;
}

/// Body for the NEXT page of any InnerTube feed: the same context plus the
/// opaque `continuation` token lifted from the previous response. Search
/// continuations POST to SEARCH_URL, channel-browse continuations to
/// BROWSE_URL — the body shape is identical either way.
pub fn buildContinuationBody(token: []const u8, out: []u8) ?[]const u8 {
    if (token.len == 0 or token.len > MAX_TOKEN_LEN) return null;
    // Tokens are URL-safe base64 (`A-Za-z0-9-_=%`); anything else means we
    // scraped the wrong field, so refuse rather than post junk.
    for (token) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '=' and c != '%') return null;
    }
    return std.fmt.bufPrint(
        out,
        "{{\"context\":{{\"client\":{{\"clientName\":\"{s}\",\"clientVersion\":\"{s}\",\"hl\":\"en\",\"gl\":\"US\"}}}},\"continuation\":\"{s}\"}}",
        .{ CLIENT_NAME, CLIENT_VERSION, token },
    ) catch null;
}

/// Body for a channel's Videos tab. `browse_id` must be a "UC…" channel id —
/// validated here so a hostile id scraped out of JSON can't reach the request.
pub fn buildChannelBrowseBody(browse_id: []const u8, out: []u8) ?[]const u8 {
    if (!isChannelId(browse_id)) return null;
    return std.fmt.bufPrint(
        out,
        "{{\"context\":{{\"client\":{{\"clientName\":\"{s}\",\"clientVersion\":\"{s}\",\"hl\":\"en\",\"gl\":\"US\"}}}},\"browseId\":\"{s}\",\"params\":\"{s}\"}}",
        .{ CLIENT_NAME, CLIENT_VERSION, browse_id, CHANNEL_VIDEOS_PARAMS },
    ) catch null;
}

/// A YouTube channel id: "UC" + 22 id chars (we accept 12..32 total to stay
/// tolerant of legacy ids, but the charset is strict).
pub fn isChannelId(id: []const u8) bool {
    if (id.len < 12 or id.len > 32) return false;
    if (!std.mem.startsWith(u8, id, "UC")) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// The next-page token from a search or browse response, or null when the feed
/// has no more pages (which is exactly when the caller should stop paging).
pub fn extractContinuationToken(json: []const u8) ?[]const u8 {
    const tok = strValueAfter(json, "\"continuationCommand\":{\"token\":") orelse return null;
    if (tok.len == 0 or tok.len > MAX_TOKEN_LEN) return null;
    return tok;
}

// ══════════════════════════════════════════════════════════
// JSON string helpers
// ══════════════════════════════════════════════════════════

/// Raw (still-escaped) string value for `key` inside `json`, or null. `key`
/// must include its quotes, e.g. `"\"videoId\":"`.
pub fn strValueAfter(json: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, json, key) orelse return null;
    return strValueAt(json, ki + key.len);
}

/// Read the quoted string starting at/after `from` (skipping spaces + a colon).
fn strValueAt(json: []const u8, from: usize) ?[]const u8 {
    var i = from;
    while (i < json.len and (json[i] == ' ' or json[i] == ':')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1; // skip the escaped char
            continue;
        }
        if (json[i] == '"') return json[start..i];
    }
    return null;
}

/// The text of a `{"simpleText":"…"}` or `{"runs":[{"text":"…"}]}` value nested
/// under `key`. Searches only FIELD_SPAN bytes past the key so a missing field
/// never steals a later one's text. Returns the raw (escaped) slice.
pub fn firstTextAfter(json: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, json, key) orelse return null;
    const from = ki + key.len;
    const span = json[from..@min(from + FIELD_SPAN, json.len)];
    // `"simpleText":` and `"text":` can't alias: the leading quote means the
    // `Text` inside `simpleText` is never matched by `"text":`.
    const a = std.mem.indexOf(u8, span, "\"simpleText\":");
    const b = std.mem.indexOf(u8, span, "\"text\":");
    const use_simple = if (a) |ai| (b == null or ai < b.?) else false;
    if (use_simple) return strValueAt(span, a.? + "\"simpleText\":".len);
    const bi = b orelse return null;
    return strValueAt(span, bi + "\"text\":".len);
}

/// Decode JSON escapes in `src` into `out` (UTF-8, surrogate pairs handled).
/// Returns the written length; stops cleanly when `out` fills.
pub fn unescapeJson(src: []const u8, out: []u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < src.len and n < out.len) {
        if (src[i] != '\\' or i + 1 >= src.len) {
            out[n] = src[i];
            n += 1;
            i += 1;
            continue;
        }
        const e = src[i + 1];
        if (e == 'u') {
            if (decodeUnicodeEscape(src[i..], out[n..])) |r| {
                n += r.written;
                i += r.consumed;
                continue;
            }
            // Malformed / no room — drop the escape rather than emit garbage.
            i += 2;
            continue;
        }
        out[n] = switch (e) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'n', 't', 'r' => ' ',
            'b', 'f' => ' ',
            else => e,
        };
        n += 1;
        i += 2;
    }
    return n;
}

const UnicodeResult = struct { written: usize, consumed: usize };

fn decodeUnicodeEscape(esc: []const u8, out: []u8) ?UnicodeResult {
    if (esc.len < 6 or esc[0] != '\\' or esc[1] != 'u') return null;
    const hi = std.fmt.parseInt(u16, esc[2..6], 16) catch return null;
    var cp: u21 = hi;
    var consumed: usize = 6;
    if (hi >= 0xD800 and hi <= 0xDBFF) {
        if (esc.len < 12 or esc[6] != '\\' or esc[7] != 'u') return null;
        const lo = std.fmt.parseInt(u16, esc[8..12], 16) catch return null;
        if (lo < 0xDC00 or lo > 0xDFFF) return null;
        cp = 0x10000 + (@as(u21, hi - 0xD800) << 10) + (lo - 0xDC00);
        consumed = 12;
    } else if (hi >= 0xDC00 and hi <= 0xDFFF) return null;
    var tmp: [4]u8 = undefined;
    const w = std.unicode.utf8Encode(cp, &tmp) catch return null;
    if (out.len < w) return null;
    @memcpy(out[0..w], tmp[0..w]);
    return .{ .written = w, .consumed = consumed };
}

// ══════════════════════════════════════════════════════════
// Field text → values
// ══════════════════════════════════════════════════════════

/// "1:02:03" → 3723, "4:07" → 247, "" / junk → 0. Also accepts "d:hh:mm:ss".
pub fn durationFromText(t: []const u8) i64 {
    if (t.len == 0) return 0;
    var total: i64 = 0;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, t, ':');
    while (it.next()) |p| {
        const trimmed = std.mem.trim(u8, p, " ");
        if (trimmed.len == 0 or trimmed.len > 4) return 0;
        const v = std.fmt.parseInt(i64, trimmed, 10) catch return 0;
        total = total * 60 + v;
        parts += 1;
        if (parts > 4) return 0;
    }
    if (parts < 2) return 0; // a bare number isn't a duration label
    return total;
}

/// "134,428,957 views" → 134428957, "1.2M views" → 1200000, "No views" → 0,
/// "" → 0. Commas are thousands separators; a K/M/B suffix scales the mantissa.
pub fn viewsFromText(t: []const u8) i64 {
    var i: usize = 0;
    while (i < t.len and !std.ascii.isDigit(t[i])) : (i += 1) {}
    if (i >= t.len) return 0; // "No views" and friends

    var int_part: i64 = 0;
    var frac: i64 = 0;
    var frac_digits: u8 = 0;
    var seen_dot = false;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c == ',') continue;
        if (c == '.') {
            if (seen_dot) break;
            seen_dot = true;
            continue;
        }
        if (!std.ascii.isDigit(c)) break;
        if (seen_dot) {
            if (frac_digits < 3) {
                frac = frac * 10 + (c - '0');
                frac_digits += 1;
            }
        } else {
            if (int_part > std.math.maxInt(i64) / 100) return std.math.maxInt(i64);
            int_part = int_part * 10 + (c - '0');
        }
    }

    const mult: i64 = switch (if (i < t.len) t[i] else 0) {
        'K', 'k' => 1_000,
        'M', 'm' => 1_000_000,
        'B', 'b' => 1_000_000_000,
        else => 1,
    };
    if (mult == 1) return int_part; // plain count — fraction is meaningless
    var scale: i64 = 1;
    var d: u8 = 0;
    while (d < frac_digits) : (d += 1) scale *= 10;
    return int_part * mult + @divTrunc(frac * mult, scale);
}

/// Approximate days-ago for a relative publish label ("6 years ago",
/// "Streamed 3 months ago", "2 weeks ago"). Sub-day units → 0. null when there
/// is no number to read (leaves the card's date blank rather than guessing).
pub fn publishedAgoDays(t: []const u8) ?i64 {
    var i: usize = 0;
    while (i < t.len and !std.ascii.isDigit(t[i])) : (i += 1) {}
    if (i >= t.len) return null;
    const start = i;
    while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) {}
    const n = std.fmt.parseInt(i64, t[start..i], 10) catch return null;
    while (i < t.len and t[i] == ' ') i += 1;
    const unit = t[i..];
    if (std.mem.startsWith(u8, unit, "year")) return n * 365;
    if (std.mem.startsWith(u8, unit, "month")) return n * 30;
    if (std.mem.startsWith(u8, unit, "week")) return n * 7;
    if (std.mem.startsWith(u8, unit, "day")) return n;
    if (std.mem.startsWith(u8, unit, "hour") or std.mem.startsWith(u8, unit, "minute") or
        std.mem.startsWith(u8, unit, "second")) return 0;
    return null;
}

/// YYYYMMDD for `z` days since the unix epoch (Howard Hinnant's
/// civil_from_days). The card's date column stores YYYYMMDD, so a relative
/// InnerTube label is converted once here and rendered back by formatAgo.
pub fn ymdFromDaysSinceEpoch(z_in: i64) [8]u8 {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    if (m <= 2) y += 1;

    var out: [8]u8 = @splat('0');
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}", .{
        @as(u32, @intCast(@max(0, @min(9999, y)))),
        @as(u32, @intCast(m)),
        @as(u32, @intCast(d)),
    }) catch return @splat('0');
    return out;
}

// ══════════════════════════════════════════════════════════
// Ids / URLs / row filtering
// ══════════════════════════════════════════════════════════

/// A YouTube video id: 5..31 chars, id charset only. Rejects "NA" and anything
/// that would poison a URL.
pub fn validVideoId(id: []const u8) bool {
    if (id.len < 5 or id.len > 31) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// True for a CHANNEL row masquerading as a video (id == channel_id, "UC…").
/// As a card it's a dead video — watch?v=UC… doesn't play and vi/UC… 404s.
/// Shared by BOTH the yt-dlp line parser and the InnerTube parser.
pub fn isChannelRow(video_id: []const u8, channel_id: []const u8) bool {
    return channel_id.len > 0 and std.mem.eql(u8, video_id, channel_id);
}

/// Canonical cache identity for a search query: trimmed, lowercased, inner
/// whitespace runs collapsed to one space. "  Lofi   Hip Hop " and
/// "lofi hip hop" therefore share one cache entry.
pub fn normalizeQuery(q: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    for (std.mem.trim(u8, q, " \t\r\n")) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            pending_space = n > 0;
            continue;
        }
        if (pending_space) {
            if (n >= out.len) break;
            out[n] = ' ';
            n += 1;
            pending_space = false;
        }
        if (n >= out.len) break;
        out[n] = std.ascii.toLower(c);
        n += 1;
    }
    return out[0..n];
}

/// `https://i.ytimg.com/vi/{id}/mqdefault.jpg`, or null for a bad id / buffer.
pub fn thumbUrl(video_id: []const u8, buf: []u8) ?[]const u8 {
    if (!validVideoId(video_id)) return null;
    return std.fmt.bufPrint(buf, "https://i.ytimg.com/vi/{s}/mqdefault.jpg", .{video_id}) catch null;
}

// ══════════════════════════════════════════════════════════
// videoRenderer iterator
// ══════════════════════════════════════════════════════════

const MARKER = "\"videoRenderer\":{";

/// One parsed search row. String fields are RAW (still JSON-escaped) slices
/// into the caller's response buffer — run them through `unescapeJson` before
/// display. Numeric fields are already decoded.
pub const Video = struct {
    id: []const u8 = "",
    title_raw: []const u8 = "",
    channel_raw: []const u8 = "",
    channel_id: []const u8 = "",
    duration: i64 = 0,
    views: i64 = 0,
    /// Days before "now" this was published, or null when unknown.
    ago_days: ?i64 = null,
};

/// Yield the next `videoRenderer` at/after `pos.*`, advancing `pos.*` past its
/// marker. Rows without a usable video id, and channel rows, are skipped —
/// callers just loop until null. Returns null at the end of the payload (and on
/// an empty/malformed body).
pub fn nextVideo(json: []const u8, pos: *usize) ?Video {
    while (pos.* < json.len) {
        const rel = std.mem.indexOf(u8, json[pos.*..], MARKER) orelse {
            pos.* = json.len;
            return null;
        };
        const start = pos.* + rel + MARKER.len;
        pos.* = start;

        // Window = up to the next renderer (or a hard cap for the last one).
        var end = @min(start + WINDOW_CAP, json.len);
        if (std.mem.indexOf(u8, json[start..end], MARKER)) |nrel| end = start + nrel;
        const w = json[start..end];

        const id = strValueAfter(w, "\"videoId\":") orelse continue;
        if (!validVideoId(id)) continue;

        var v = Video{ .id = id };
        if (firstTextAfter(w, "\"title\":")) |t| v.title_raw = t;
        if (firstTextAfter(w, "\"longBylineText\":") orelse firstTextAfter(w, "\"ownerText\":")) |c| v.channel_raw = c;
        if (strValueAfter(w, "\"browseId\":")) |cid| {
            if (std.mem.startsWith(u8, cid, "UC") and cid.len <= 32) v.channel_id = cid;
        }
        if (firstTextAfter(w, "\"lengthText\":")) |d| v.duration = durationFromText(d);
        if (firstTextAfter(w, "\"viewCountText\":")) |vc| v.views = viewsFromText(vc);
        if (firstTextAfter(w, "\"publishedTimeText\":")) |p| v.ago_days = publishedAgoDays(p);

        if (isChannelRow(v.id, v.channel_id)) continue;
        return v;
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// lockupViewModel iterator (channel Videos tab)
// ══════════════════════════════════════════════════════════
//
// `/youtubei/v1/browse` for a channel returns the NEWER `lockupViewModel`
// shape, not `videoRenderer` — same data, different field names, so it needs
// its own reader. Yielded rows use the same `Video` record, minus the channel
// name/id (a channel page's rows are all the channel we already know).

const LOCKUP_MARKER = "\"lockupViewModel\":{";
/// A lockup record runs ~9.4 KB (menus, overlays, logging); 16 KB bounds the
/// LAST one without ever truncating a real record.
const LOCKUP_WINDOW_CAP: usize = 16 * 1024;

/// The `n`-th (0-based) `"content":"…"` value following `key`, searched within
/// `span` bytes of it. The lockup metadata row is a list of parts, so views and
/// the publish label are simply parts 0 and 1.
fn nthContentAfter(json: []const u8, key: []const u8, n: usize, span: usize) ?[]const u8 {
    const ki = std.mem.indexOf(u8, json, key) orelse return null;
    const from = ki + key.len;
    const w = json[from..@min(from + span, json.len)];
    var seen: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, w, i, "\"content\":")) |ci| {
        if (seen == n) return strValueAt(w, ci + "\"content\":".len);
        seen += 1;
        i = ci + "\"content\":".len;
    }
    return null;
}

pub const LockupMeta = struct { views: i64 = 0, published: []const u8 = "" };

/// Split a lockup's two metadata parts into a view count and a publish label.
/// Order isn't guaranteed: an upcoming/premiere row carries only a date, and
/// reading that as a view count would print "1 view" for "1 month ago". So a
/// part is only treated as views when it actually says views/watching.
pub fn lockupMeta(part0: []const u8, part1: []const u8) LockupMeta {
    if (looksLikeViews(part0)) return .{ .views = viewsFromText(part0), .published = part1 };
    if (looksLikeViews(part1)) return .{ .views = viewsFromText(part1), .published = part0 };
    return .{ .views = 0, .published = if (part0.len > 0) part0 else part1 };
}

fn looksLikeViews(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "view") != null or std.mem.indexOf(u8, s, "watching") != null;
}

/// Yield the next channel-page video at/after `pos.*`. Non-video lockups
/// (playlists, podcasts, Shorts shelves) carry a different `contentType` and
/// are skipped, as are rows without a usable id.
pub fn nextLockupVideo(json: []const u8, pos: *usize) ?Video {
    while (pos.* < json.len) {
        const rel = std.mem.indexOf(u8, json[pos.*..], LOCKUP_MARKER) orelse {
            pos.* = json.len;
            return null;
        };
        const start = pos.* + rel + LOCKUP_MARKER.len;
        pos.* = start;

        var end = @min(start + LOCKUP_WINDOW_CAP, json.len);
        if (std.mem.indexOf(u8, json[start..end], LOCKUP_MARKER)) |nrel| end = start + nrel;
        const w = json[start..end];

        const ctype = strValueAfter(w, "\"contentType\":") orelse continue;
        if (!std.mem.eql(u8, ctype, "LOCKUP_CONTENT_TYPE_VIDEO")) continue;

        const id = strValueAfter(w, "\"contentId\":") orelse continue;
        if (!validVideoId(id)) continue;

        var v = Video{ .id = id };
        if (nthContentAfter(w, "\"lockupMetadataViewModel\":", 0, FIELD_SPAN)) |t| v.title_raw = t;
        // Duration lives in the thumbnail badge ("15:05"); a live row says
        // "LIVE" there, which durationFromText correctly reads as 0.
        if (firstTextAfter(w, "\"thumbnailBadgeViewModel\":")) |d| v.duration = durationFromText(d);
        const p0 = nthContentAfter(w, "\"metadataParts\":", 0, FIELD_SPAN) orelse "";
        const p1 = nthContentAfter(w, "\"metadataParts\":", 1, FIELD_SPAN) orelse "";
        const meta = lockupMeta(p0, p1);
        v.views = meta.views;
        v.ago_days = publishedAgoDays(meta.published);
        return v;
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "buildSearchBody: client, query, videos-only params" {
    var buf: [512]u8 = undefined;
    const body = buildSearchBody("lofi hip hop", &buf).?;
    try std.testing.expectEqualStrings(
        "{\"context\":{\"client\":{\"clientName\":\"WEB\",\"clientVersion\":\"2.20240401.00\",\"hl\":\"en\",\"gl\":\"US\"}},\"query\":\"lofi hip hop\",\"params\":\"EgIQAQ%3D%3D\"}",
        body,
    );
    try std.testing.expect(buildSearchBody("", &buf) == null);
}

test "buildSearchBody: a quote/backslash in the query can't break out of the JSON" {
    var buf: [512]u8 = undefined;
    const body = buildSearchBody("say \"hi\"\\ \n", &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"query\":\"say \\\"hi\\\"\\\\ \\n\"") != null);
    // Tiny buffer → no partial/invalid body.
    var tiny: [16]u8 = undefined;
    try std.testing.expect(buildSearchBody("something long", &tiny) == null);
}

// Representative fixture: three videoRenderers in the real response shape
// (accessibility label BEFORE lengthText's simpleText, runs-wrapped title and
// byline), plus a trailing channel row whose browseId == its videoId.
const FIXTURE =
    \\{"contents":{"itemSectionRenderer":{"contents":[
    \\{"videoRenderer":{"videoId":"lTRiuFIWV54","thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/lTRiuFIWV54/hq720.jpg"}]},
    \\"title":{"runs":[{"text":"1 A.M Study Session é [lofi hip hop]"}],"accessibility":{"accessibilityData":{"label":"x"}}},
    \\"longBylineText":{"runs":[{"text":"Lofi Girl","navigationEndpoint":{"browseEndpoint":{"browseId":"UCSJ4gkVC6NrvII8umztf0Ow"}}}]},
    \\"publishedTimeText":{"simpleText":"6 years ago"},
    \\"lengthText":{"accessibility":{"accessibilityData":{"label":"1 hour, 2 minutes, 3 seconds"}},"simpleText":"1:02:03"},
    \\"viewCountText":{"simpleText":"134,428,957 views"}}},
    \\{"videoRenderer":{"videoId":"n61ULEU7CO0","title":{"runs":[{"text":"Short clip"}]},
    \\"longBylineText":{"runs":[{"text":"Some Channel","navigationEndpoint":{"browseEndpoint":{"browseId":"UCabcdefghijklmnop"}}}]},
    \\"publishedTimeText":{"simpleText":"3 weeks ago"},
    \\"lengthText":{"simpleText":"4:07"},
    \\"viewCountText":{"simpleText":"1.2M views"}}},
    \\{"videoRenderer":{"videoId":"ZZZnoviewsZZ","title":{"runs":[{"text":"Brand new"}]},
    \\"longBylineText":{"runs":[{"text":"Fresh","navigationEndpoint":{"browseEndpoint":{"browseId":"UCfreshfreshfresh"}}}]},
    \\"publishedTimeText":{"simpleText":"2 hours ago"},
    \\"viewCountText":{"simpleText":"No views"}}},
    \\{"videoRenderer":{"videoId":"UCchannelrowrow1","title":{"runs":[{"text":"A Channel"}]},
    \\"longBylineText":{"runs":[{"text":"A Channel","navigationEndpoint":{"browseEndpoint":{"browseId":"UCchannelrowrow1"}}}]}}}
    \\]}}}
;

test "nextVideo: parses a representative 3-video payload" {
    var pos: usize = 0;
    var ubuf: [256]u8 = undefined;

    const a = nextVideo(FIXTURE, &pos).?;
    try std.testing.expectEqualStrings("lTRiuFIWV54", a.id);
    try std.testing.expectEqualStrings(
        "1 A.M Study Session \u{e9} [lofi hip hop]",
        ubuf[0..unescapeJson(a.title_raw, &ubuf)],
    );
    try std.testing.expectEqualStrings("Lofi Girl", a.channel_raw);
    try std.testing.expectEqualStrings("UCSJ4gkVC6NrvII8umztf0Ow", a.channel_id);
    try std.testing.expectEqual(@as(i64, 3723), a.duration);
    try std.testing.expectEqual(@as(i64, 134_428_957), a.views);
    try std.testing.expectEqual(@as(i64, 6 * 365), a.ago_days.?);

    const b = nextVideo(FIXTURE, &pos).?;
    try std.testing.expectEqualStrings("n61ULEU7CO0", b.id);
    try std.testing.expectEqualStrings("Some Channel", b.channel_raw);
    try std.testing.expectEqual(@as(i64, 247), b.duration);
    try std.testing.expectEqual(@as(i64, 1_200_000), b.views);
    try std.testing.expectEqual(@as(i64, 21), b.ago_days.?);

    // No lengthText / no views → zeros, not garbage from the neighbouring row.
    const c = nextVideo(FIXTURE, &pos).?;
    try std.testing.expectEqualStrings("ZZZnoviewsZZ", c.id);
    try std.testing.expectEqual(@as(i64, 0), c.duration);
    try std.testing.expectEqual(@as(i64, 0), c.views);
    try std.testing.expectEqual(@as(i64, 0), c.ago_days.?);
}

test "nextVideo: the channel row (id == channel_id) is dropped, then the stream ends" {
    var pos: usize = 0;
    var n: usize = 0;
    while (nextVideo(FIXTURE, &pos)) |v| {
        try std.testing.expect(!std.mem.eql(u8, v.id, "UCchannelrowrow1"));
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n); // 4 renderers, channel row rejected
}

test "nextVideo: empty / malformed payloads yield nothing and terminate" {
    for ([_][]const u8{
        "",
        "not json at all",
        "{\"videoRenderer\":{}}",
        "{\"videoRenderer\":{\"videoId\":\"NA\"}}",
        "{\"videoRenderer\":{\"videoId\":\"bad/id!\"}}",
        "{\"videoRenderer\":{\"videoId\":", // truncated mid-value
    }) |bad| {
        var pos: usize = 0;
        try std.testing.expect(nextVideo(bad, &pos) == null);
    }
}

test "isChannelRow rejection (yt-dlp + InnerTube share this)" {
    try std.testing.expect(isChannelRow("UCabc123", "UCabc123"));
    try std.testing.expect(!isChannelRow("lTRiuFIWV54", "UCabc123"));
    try std.testing.expect(!isChannelRow("lTRiuFIWV54", "")); // no channel id known
}

test "durationFromText: h:mm:ss, m:ss, junk" {
    try std.testing.expectEqual(@as(i64, 3723), durationFromText("1:02:03"));
    try std.testing.expectEqual(@as(i64, 247), durationFromText("4:07"));
    try std.testing.expectEqual(@as(i64, 45), durationFromText("0:45"));
    try std.testing.expectEqual(@as(i64, 43200), durationFromText("12:00:00"));
    try std.testing.expectEqual(@as(i64, 0), durationFromText(""));
    try std.testing.expectEqual(@as(i64, 0), durationFromText("LIVE"));
    try std.testing.expectEqual(@as(i64, 0), durationFromText("187")); // bare number isn't a label
    try std.testing.expectEqual(@as(i64, 0), durationFromText("1:xx"));
}

test "viewsFromText: commas, magnitudes, no views" {
    try std.testing.expectEqual(@as(i64, 134_428_957), viewsFromText("134,428,957 views"));
    try std.testing.expectEqual(@as(i64, 1_200_000), viewsFromText("1.2M views"));
    try std.testing.expectEqual(@as(i64, 2_000_000), viewsFromText("2M views"));
    try std.testing.expectEqual(@as(i64, 337_000), viewsFromText("337K views"));
    try std.testing.expectEqual(@as(i64, 1_200_000_000), viewsFromText("1.2B views"));
    try std.testing.expectEqual(@as(i64, 0), viewsFromText("No views"));
    try std.testing.expectEqual(@as(i64, 0), viewsFromText(""));
    try std.testing.expectEqual(@as(i64, 1_234), viewsFromText("1,234 watching"));
}

test "publishedAgoDays: units, prefixes, sub-day, unknown" {
    try std.testing.expectEqual(@as(i64, 2190), publishedAgoDays("6 years ago").?);
    try std.testing.expectEqual(@as(i64, 90), publishedAgoDays("3 months ago").?);
    try std.testing.expectEqual(@as(i64, 14), publishedAgoDays("2 weeks ago").?);
    try std.testing.expectEqual(@as(i64, 5), publishedAgoDays("5 days ago").?);
    try std.testing.expectEqual(@as(i64, 1095), publishedAgoDays("Streamed 3 years ago").?);
    try std.testing.expectEqual(@as(i64, 0), publishedAgoDays("7 hours ago").?);
    try std.testing.expect(publishedAgoDays("LIVE") == null);
    try std.testing.expect(publishedAgoDays("") == null);
}

test "ymdFromDaysSinceEpoch: known civil dates" {
    try std.testing.expectEqualStrings("19700101", &ymdFromDaysSinceEpoch(0));
    try std.testing.expectEqualStrings("20000101", &ymdFromDaysSinceEpoch(10957));
    try std.testing.expectEqualStrings("20000229", &ymdFromDaysSinceEpoch(11016)); // leap day
    try std.testing.expectEqualStrings("19691231", &ymdFromDaysSinceEpoch(-1));
}

test "thumbUrl / validVideoId" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://i.ytimg.com/vi/lTRiuFIWV54/mqdefault.jpg",
        thumbUrl("lTRiuFIWV54", &buf).?,
    );
    try std.testing.expect(thumbUrl("", &buf) == null);
    try std.testing.expect(thumbUrl("a/../b", &buf) == null);
    try std.testing.expect(!validVideoId("NA"));
    try std.testing.expect(validVideoId("lTRiuFIWV54"));
}

// ── Paging: continuation tokens ──

test "extractContinuationToken: found, absent, over-long" {
    const with = "{\"x\":1,\"continuationItemRenderer\":{\"continuationEndpoint\":{\"continuationCommand\":{\"token\":\"EqEDEgxsb2Zp-_A%3D\",\"request\":\"X\"}}}}";
    try std.testing.expectEqualStrings("EqEDEgxsb2Zp-_A%3D", extractContinuationToken(with).?);
    // Last page of a feed: no token → caller stops paging.
    try std.testing.expect(extractContinuationToken("{\"contents\":[]}") == null);
    try std.testing.expect(extractContinuationToken("") == null);
}

test "buildContinuationBody: shape, empty, and hostile tokens" {
    var buf: [512]u8 = undefined;
    const b = buildContinuationBody("EqEDEgx-_A%3D", &buf).?;
    try std.testing.expectEqualStrings(
        "{\"context\":{\"client\":{\"clientName\":\"WEB\",\"clientVersion\":\"2.20240401.00\",\"hl\":\"en\",\"gl\":\"US\"}},\"continuation\":\"EqEDEgx-_A%3D\"}",
        b,
    );
    try std.testing.expect(buildContinuationBody("", &buf) == null);
    // A token that isn't URL-safe base64 means we read the wrong field — refuse
    // rather than post it (and never let a quote escape the JSON).
    try std.testing.expect(buildContinuationBody("abc\",\"x\":\"", &buf) == null);
    try std.testing.expect(buildContinuationBody("abc def", &buf) == null);
    var long: [MAX_TOKEN_LEN + 1]u8 = @splat('A');
    try std.testing.expect(buildContinuationBody(&long, &buf) == null);
}

test "buildChannelBrowseBody + isChannelId" {
    var buf: [512]u8 = undefined;
    const b = buildChannelBrowseBody("UCSJ4gkVC6NrvII8umztf0Ow", &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, b, "\"browseId\":\"UCSJ4gkVC6NrvII8umztf0Ow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"params\":\"EgZ2aWRlb3PyBgQKAjoA\"") != null);
    try std.testing.expect(buildChannelBrowseBody("", &buf) == null);
    try std.testing.expect(buildChannelBrowseBody("notachannel", &buf) == null);
    try std.testing.expect(buildChannelBrowseBody("UC$(rm -rf /)abcdefg", &buf) == null);
    try std.testing.expect(!isChannelId("UCshort"));
    try std.testing.expect(isChannelId("UCSJ4gkVC6NrvII8umztf0Ow"));
}

// ── Paging: channel-page lockupViewModel rows ──

// Real browse shape: badge duration, title under lockupMetadataViewModel, two
// metadata parts, contentId + contentType at the END of the record. Row 3 is a
// playlist lockup (must be skipped); row 4 is an upcoming video whose only
// metadata part is a date (must NOT be read as a view count).
const LOCKUP_FIXTURE =
    \\{"contents":[
    \\{"lockupViewModel":{"contentImage":{"thumbnailViewModel":{"overlays":[{"thumbnailBadgeViewModel":{"icon":{"sources":[{"clientResource":{"imageName":"MUSIC"}}]},"text":"15:05","badgeStyle":"DEFAULT","animatedText":"Now playing"}}]}},
    \\"metadata":{"lockupMetadataViewModel":{"title":{"content":"15 min power nap lofi sleep"},"metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"126K views"}},{"text":{"content":"1 month ago"},"accessibilityLabel":"1 month ago"}]}]}}}},
    \\"contentId":"2oJqY4nhL-c","contentType":"LOCKUP_CONTENT_TYPE_VIDEO"}},
    \\{"lockupViewModel":{"contentImage":{"thumbnailViewModel":{"overlays":[{"thumbnailBadgeViewModel":{"text":"1:02:03"}}]}},
    \\"metadata":{"lockupMetadataViewModel":{"title":{"content":"Long mix"},"metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"1.2M views"}},{"text":{"content":"3 years ago"}}]}]}}}},
    \\"contentId":"lTRiuFIWV54","contentType":"LOCKUP_CONTENT_TYPE_VIDEO"}},
    \\{"lockupViewModel":{"metadata":{"lockupMetadataViewModel":{"title":{"content":"My Playlist"}}},
    \\"contentId":"PLabcdefghijkl","contentType":"LOCKUP_CONTENT_TYPE_PLAYLIST"}},
    \\{"lockupViewModel":{"contentImage":{"thumbnailViewModel":{"overlays":[{"thumbnailBadgeViewModel":{"text":"LIVE"}}]}},
    \\"metadata":{"lockupMetadataViewModel":{"title":{"content":"Premiere soon"},"metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"2 days ago"}}]}]}}}},
    \\"contentId":"upcomingVid1","contentType":"LOCKUP_CONTENT_TYPE_VIDEO"}}
    \\]}
;

test "nextLockupVideo: parses channel rows, skips non-video lockups" {
    var pos: usize = 0;

    const a = nextLockupVideo(LOCKUP_FIXTURE, &pos).?;
    try std.testing.expectEqualStrings("2oJqY4nhL-c", a.id);
    try std.testing.expectEqualStrings("15 min power nap lofi sleep", a.title_raw);
    try std.testing.expectEqual(@as(i64, 905), a.duration); // 15:05
    try std.testing.expectEqual(@as(i64, 126_000), a.views);
    try std.testing.expectEqual(@as(i64, 30), a.ago_days.?);

    const b = nextLockupVideo(LOCKUP_FIXTURE, &pos).?;
    try std.testing.expectEqualStrings("lTRiuFIWV54", b.id);
    try std.testing.expectEqual(@as(i64, 3723), b.duration);
    try std.testing.expectEqual(@as(i64, 1_200_000), b.views);
    try std.testing.expectEqual(@as(i64, 1095), b.ago_days.?);

    // The playlist lockup is skipped; the upcoming row's lone date part must
    // not be misread as "2 views".
    const c = nextLockupVideo(LOCKUP_FIXTURE, &pos).?;
    try std.testing.expectEqualStrings("upcomingVid1", c.id);
    try std.testing.expectEqual(@as(i64, 0), c.views);
    try std.testing.expectEqual(@as(i64, 0), c.duration); // "LIVE" badge
    try std.testing.expectEqual(@as(i64, 2), c.ago_days.?);

    try std.testing.expect(nextLockupVideo(LOCKUP_FIXTURE, &pos) == null);
}

test "nextLockupVideo: empty / malformed payloads terminate" {
    for ([_][]const u8{
        "",
        "{}",
        "{\"lockupViewModel\":{}}",
        "{\"lockupViewModel\":{\"contentId\":\"abc\"}}", // no contentType
        "{\"lockupViewModel\":{\"contentId\":\"x\",\"contentType\":\"LOCKUP_CONTENT_TYPE_VIDEO\"}}", // bad id
    }) |bad| {
        var pos: usize = 0;
        try std.testing.expect(nextLockupVideo(bad, &pos) == null);
    }
}

test "lockupMeta: part order, missing views, missing date" {
    try std.testing.expectEqual(@as(i64, 126_000), lockupMeta("126K views", "1 month ago").views);
    try std.testing.expectEqualStrings("1 month ago", lockupMeta("126K views", "1 month ago").published);
    // Reversed order still resolves correctly.
    try std.testing.expectEqual(@as(i64, 5), lockupMeta("1 month ago", "5 views").views);
    // Date only → never invents a view count.
    const only_date = lockupMeta("2 days ago", "");
    try std.testing.expectEqual(@as(i64, 0), only_date.views);
    try std.testing.expectEqualStrings("2 days ago", only_date.published);
    // Live row: "1,234 watching" counts as views.
    try std.testing.expectEqual(@as(i64, 1234), lockupMeta("1,234 watching", "").views);
}

test "normalizeQuery: one cache identity per logical query" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("lofi hip hop", normalizeQuery("  Lofi   Hip Hop \n", &buf));
    try std.testing.expectEqualStrings("lofi hip hop", normalizeQuery("lofi hip hop", &buf));
    try std.testing.expectEqualStrings("", normalizeQuery("   ", &buf));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", normalizeQuery("abcdefgh", &tiny));
}

test "unescapeJson: escapes, surrogate pairs, output clamp" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a\"b\\c/d", buf[0..unescapeJson("a\\\"b\\\\c\\/d", &buf)]);
    try std.testing.expectEqualStrings("caf\u{e9}", buf[0..unescapeJson("caf\\u00e9", &buf)]);
    try std.testing.expectEqualStrings("\u{1F3B5}", buf[0..unescapeJson("\\ud83c\\udfb5", &buf)]);
    var small: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), unescapeJson("abcdef", &small));
}
