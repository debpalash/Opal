//! Pure (io-free, state-free) YouTube helpers — unit-testable via `zig build
//! test`. youtube.zig routes through these so the tested logic IS the shipped
//! logic: URL building/encoding, duration & view-count formatting, and the
//! Google-autocomplete suggestion parser.

const std = @import("std");

/// Percent-encode `input` into `out` for a URL query value. Spaces become `+`
/// (form style — both Google suggest and Piped accept it). Returns the encoded
/// length; stops early if `out` runs out of room.
pub fn urlEncode(input: []const u8, out: []u8) usize {
    const hex = "0123456789ABCDEF";
    var olen: usize = 0;
    for (input) |ch| {
        if (olen + 3 >= out.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            out[olen] = ch;
            olen += 1;
        } else if (ch == ' ') {
            out[olen] = '+';
            olen += 1;
        } else {
            out[olen] = '%';
            out[olen + 1] = hex[ch >> 4];
            out[olen + 2] = hex[ch & 0xf];
            olen += 3;
        }
    }
    return olen;
}

/// Build the Google autocomplete URL for a YouTube query (`ds=yt`), or null if
/// the query encodes to nothing / doesn't fit. client=firefox returns plain
/// JSON: ["q",["s1","s2",…]].
pub fn suggestUrl(query: []const u8, buf: []u8) ?[]const u8 {
    var enc: [512]u8 = undefined;
    const elen = urlEncode(query, &enc);
    if (elen == 0) return null;
    return std.fmt.bufPrint(buf, "https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&q={s}", .{enc[0..elen]}) catch null;
}

/// Build the /videos tab URL for a channel id, or null if the id is missing,
/// overlong, or contains anything outside a YouTube id's charset (defends the
/// yt-dlp argv from a hostile "channel_id" scraped out of JSON).
pub fn channelVideosUrl(channel_id: []const u8, buf: []u8) ?[]const u8 {
    if (channel_id.len < 10 or channel_id.len > 32) return null;
    for (channel_id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return null;
    }
    return std.fmt.bufPrint(buf, "https://www.youtube.com/channel/{s}/videos", .{channel_id}) catch null;
}

/// Extract the channel id from a Piped `uploaderUrl` value ("/channel/UC…"),
/// or null if it isn't a channel path.
pub fn channelIdFromUploaderUrl(url: []const u8) ?[]const u8 {
    const prefix = "/channel/";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const id = url[prefix.len..];
    if (id.len == 0) return null;
    return id;
}

/// Format a duration in seconds as "m:ss" or, from an hour up, "h:mm:ss"
/// (75:03 was how 1h15m3s used to render). 0/negative → "". The unsigned casts
/// matter: Zig 0.16 zero-pads signed ints with a forced sign ("3:+07").
pub fn formatDuration(secs: i64, buf: []u8) []const u8 {
    if (secs <= 0) return "";
    const t: u64 = @intCast(secs);
    const h = t / 3600;
    const m = (t % 3600) / 60;
    const s = t % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s }) catch "";
}

/// Compact view-count magnitude, e.g. 337000→"337K", 1491000→"1.5M",
/// 114200000→"114M", 0→"". Drops the trailing ".0" so "2.0M" reads "2M". Never
/// truncates mid-digit — the whole formatted token fits. Writes into `buf`.
pub fn formatViews(views: i64, buf: []u8) []const u8 {
    if (views <= 0) return "";
    const f = @as(f64, @floatFromInt(views));
    if (views < 1_000) return std.fmt.bufPrint(buf, "{d}", .{views}) catch "";
    if (views < 1_000_000) return scaled(buf, f / 1_000.0, "K");
    if (views < 1_000_000_000) return scaled(buf, f / 1_000_000.0, "M");
    return scaled(buf, f / 1_000_000_000.0, "B");
}

/// Render `v` with one decimal place unless it's ≥100 (then no decimal — "337K"
/// not "337.0K") or the decimal is zero ("2M" not "2.0M"), then the suffix.
fn scaled(buf: []u8, v: f64, suffix: []const u8) []const u8 {
    const tenths = @as(i64, @intFromFloat(@round(v * 10.0)));
    const whole = @divTrunc(tenths, 10);
    const frac = @rem(tenths, 10);
    if (v >= 100.0 or frac == 0) return std.fmt.bufPrint(buf, "{d}{s}", .{ whole, suffix }) catch "";
    return std.fmt.bufPrint(buf, "{d}.{d}{s}", .{ whole, frac, suffix }) catch "";
}

/// "1.5M views" / "" — the formatViews magnitude with the unit appended.
pub fn viewsStr(views: i64, buf: []u8) []const u8 {
    var nbuf: [16]u8 = undefined;
    const n = formatViews(views, &nbuf);
    if (n.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s} views", .{n}) catch "";
}

/// Parse Google's autocomplete response `["query",["s1","s2",…],…]` into the
/// caller's fixed rows. Handles \" \\ \/ and \uXXXX escapes (surrogate pairs
/// included — suggestions are often non-ASCII). Returns how many rows were
/// filled; a suggestion longer than a row is skipped rather than truncated
/// mid-codepoint. Anything malformed just stops the parse — worst case is
/// fewer suggestions, never garbage.
pub fn parseSuggestions(json: []const u8, rows: [][]u8, lens: []u8) usize {
    std.debug.assert(rows.len == lens.len);
    // Skip past the first array element (the echoed query) to the suggestions
    // array: the '[' after the first top-level ','.
    const first_comma = topLevelComma(json) orelse return 0;
    const arr_start = std.mem.indexOfScalarPos(u8, json, first_comma, '[') orelse return 0;

    var count: usize = 0;
    var i = arr_start + 1;
    while (count < rows.len) {
        // Find the opening quote of the next string, or the end of the array.
        while (i < json.len and json[i] != '"' and json[i] != ']') i += 1;
        if (i >= json.len or json[i] == ']') break;
        i += 1; // past the opening quote

        var olen: usize = 0;
        var overflow = false;
        while (i < json.len and json[i] != '"') {
            if (json[i] == '\\' and i + 1 < json.len) {
                const esc = json[i + 1];
                if (esc == 'u' and i + 6 <= json.len) {
                    const n = decodeUnicodeEscape(json[i..], rows[count][olen..]) orelse {
                        overflow = true;
                        break;
                    };
                    olen += n.written;
                    i += n.consumed;
                    continue;
                }
                const ch: u8 = switch (esc) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'n' => ' ',
                    't' => ' ',
                    else => esc,
                };
                if (olen >= rows[count].len) {
                    overflow = true;
                    break;
                }
                rows[count][olen] = ch;
                olen += 1;
                i += 2;
            } else {
                if (olen >= rows[count].len) {
                    overflow = true;
                    break;
                }
                rows[count][olen] = json[i];
                olen += 1;
                i += 1;
            }
        }
        // Skip to the closing quote (handles the overflow bail mid-string).
        while (i < json.len and json[i] != '"') i += 1;
        if (i < json.len) i += 1;

        if (!overflow and olen > 0) {
            lens[count] = @intCast(@min(olen, 255));
            count += 1;
        }
    }
    return count;
}

/// Byte offset of the first comma at the top nesting level inside the outer
/// array (i.e. the one after the echoed query string), or null.
fn topLevelComma(json: []const u8) ?usize {
    var depth: i32 = 0;
    var in_str = false;
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (in_str) {
            if (c == '\\') i += 1 // skip the escaped char
            else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '[', '{' => depth += 1,
            ']', '}' => depth -= 1,
            ',' => if (depth == 1) return i,
            else => {},
        }
    }
    return null;
}

const UnicodeResult = struct { written: usize, consumed: usize };

/// Decode a \uXXXX escape (with surrogate-pair handling) at the start of `esc`
/// into UTF-8 in `out`. Returns bytes written/consumed, or null if `out` is too
/// small or the escape is malformed.
fn decodeUnicodeEscape(esc: []const u8, out: []u8) ?UnicodeResult {
    if (esc.len < 6 or esc[0] != '\\' or esc[1] != 'u') return null;
    const hi = std.fmt.parseInt(u16, esc[2..6], 16) catch return null;
    var cp: u21 = hi;
    var consumed: usize = 6;
    if (hi >= 0xD800 and hi <= 0xDBFF) {
        // High surrogate — needs a following \uDC00–\uDFFF.
        if (esc.len < 12 or esc[6] != '\\' or esc[7] != 'u') return null;
        const lo = std.fmt.parseInt(u16, esc[8..12], 16) catch return null;
        if (lo < 0xDC00 or lo > 0xDFFF) return null;
        cp = 0x10000 + (@as(u21, hi - 0xD800) << 10) + (lo - 0xDC00);
        consumed = 12;
    } else if (hi >= 0xDC00 and hi <= 0xDFFF) {
        return null; // lone low surrogate
    }
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch return null;
    if (out.len < n) return null;
    @memcpy(out[0..n], tmp[0..n]);
    return .{ .written = n, .consumed = consumed };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "urlEncode: spaces, reserved chars, unreserved passthrough" {
    var buf: [64]u8 = undefined;
    var n = urlEncode("hello world", &buf);
    try std.testing.expectEqualStrings("hello+world", buf[0..n]);
    n = urlEncode("a&b=c#d?e%f+g", &buf);
    try std.testing.expectEqualStrings("a%26b%3Dc%23d%3Fe%25f%2Bg", buf[0..n]);
    n = urlEncode("A-z_0.9~", &buf);
    try std.testing.expectEqualStrings("A-z_0.9~", buf[0..n]);
}

test "suggestUrl builds the ds=yt endpoint" {
    var buf: [256]u8 = undefined;
    const url = suggestUrl("lofi beats", &buf).?;
    try std.testing.expectEqualStrings("https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&q=lofi+beats", url);
    try std.testing.expect(suggestUrl("", &buf) == null);
}

test "channelVideosUrl validates the id" {
    var buf: [128]u8 = undefined;
    const url = channelVideosUrl("UC-lHJZR3Gqxm24_Vd_AJ5Yw", &buf).?;
    try std.testing.expectEqualStrings("https://www.youtube.com/channel/UC-lHJZR3Gqxm24_Vd_AJ5Yw/videos", url);
    try std.testing.expect(channelVideosUrl("", &buf) == null);
    try std.testing.expect(channelVideosUrl("short", &buf) == null);
    // Shell/URL metacharacters must be rejected, not passed to yt-dlp.
    try std.testing.expect(channelVideosUrl("UC$(rm -rf /)abcde", &buf) == null);
    try std.testing.expect(channelVideosUrl("UCabc/../../etc/passwd", &buf) == null);
}

test "channelIdFromUploaderUrl" {
    try std.testing.expectEqualStrings("UCabc123", channelIdFromUploaderUrl("/channel/UCabc123").?);
    try std.testing.expect(channelIdFromUploaderUrl("/user/somebody") == null);
    try std.testing.expect(channelIdFromUploaderUrl("/channel/") == null);
}

test "formatDuration: minutes vs hours" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0:45", formatDuration(45, &buf));
    try std.testing.expectEqualStrings("3:07", formatDuration(187, &buf));
    // The bug: 1h15m03s used to render "75:03".
    try std.testing.expectEqualStrings("1:15:03", formatDuration(4503, &buf));
    try std.testing.expectEqualStrings("12:00:00", formatDuration(43200, &buf));
    try std.testing.expectEqualStrings("", formatDuration(0, &buf));
    try std.testing.expectEqualStrings("", formatDuration(-5, &buf));
}

test "formatViews magnitudes" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", formatViews(0, &buf));
    try std.testing.expectEqualStrings("999", formatViews(999, &buf));
    try std.testing.expectEqualStrings("337K", formatViews(337_000, &buf));
    try std.testing.expectEqualStrings("1.5M", formatViews(1_491_000, &buf));
    try std.testing.expectEqualStrings("2M", formatViews(2_000_000, &buf));
    try std.testing.expectEqualStrings("114M", formatViews(114_200_000, &buf));
    try std.testing.expectEqualStrings("1.2B", formatViews(1_200_000_000, &buf));
}

test "viewsStr appends the unit" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.5M views", viewsStr(1_491_000, &buf));
    try std.testing.expectEqualStrings("", viewsStr(0, &buf));
}

fn testRows(comptime n: usize) struct { bufs: [n][120]u8, rows: [n][]u8, lens: [n]u8 } {
    return .{ .bufs = undefined, .rows = undefined, .lens = @splat(0) };
}

test "parseSuggestions: plain response" {
    var t = testRows(8);
    for (&t.bufs, 0..) |*b, i| t.rows[i] = b;
    const json =
        \\["lofi",["lofi girl","lofi hip hop radio","lofi beats to study"]]
    ;
    const n = parseSuggestions(json, &t.rows, &t.lens);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("lofi girl", t.rows[0][0..t.lens[0]]);
    try std.testing.expectEqualStrings("lofi beats to study", t.rows[2][0..t.lens[2]]);
}

test "parseSuggestions: escapes, unicode, and a query containing brackets" {
    var t = testRows(4);
    for (&t.bufs, 0..) |*b, i| t.rows[i] = b;
    // Echoed query contains [ ] and an escaped quote — must not confuse the
    // suggestions-array locator. é = é (BMP escape); 🎵 = a
    // surrogate pair (musical note, U+1F3B5).
    const json = "[\"say \\\"hi\\\" [test]\",[\"caf\\u00e9 music\",\"music \\ud83c\\udfb5\",\"a\\/b\"]]";
    const n = parseSuggestions(json, &t.rows, &t.lens);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("caf\u{e9} music", t.rows[0][0..t.lens[0]]);
    try std.testing.expectEqualStrings("music \u{1F3B5}", t.rows[1][0..t.lens[1]]);
    try std.testing.expectEqualStrings("a/b", t.rows[2][0..t.lens[2]]);
}

test "parseSuggestions: caps at rows.len, tolerates trailing metadata" {
    var t = testRows(2);
    for (&t.bufs, 0..) |*b, i| t.rows[i] = b;
    const json =
        \\["q",["one","two","three"],[],{"google:suggesttype":["QUERY"]}]
    ;
    const n = parseSuggestions(json, &t.rows, &t.lens);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("one", t.rows[0][0..t.lens[0]]);
    try std.testing.expectEqualStrings("two", t.rows[1][0..t.lens[1]]);
}

test "parseSuggestions: malformed input returns 0, never garbage" {
    var t = testRows(4);
    for (&t.bufs, 0..) |*b, i| t.rows[i] = b;
    try std.testing.expectEqual(@as(usize, 0), parseSuggestions("", &t.rows, &t.lens));
    try std.testing.expectEqual(@as(usize, 0), parseSuggestions("not json", &t.rows, &t.lens));
    try std.testing.expectEqual(@as(usize, 0), parseSuggestions("[\"only-query\"]", &t.rows, &t.lens));
    try std.testing.expectEqual(@as(usize, 0), parseSuggestions("[\"q\",[]]", &t.rows, &t.lens));
}
