//! Pure logic for the live-action Asian drama browse module — no
//! app-state / io imports, so the logic ships tested (build.zig test step).
//!
//! CATALOG SOURCE (STABLE): TMDB `/discover/tv` + `/search/tv` — the same public
//! API Opal already speaks in tmdb*.zig, filtered to Asian origin countries.
//! Discovery is metadata only (titles, posters, overviews) — no infringing
//! endpoint is compiled in.
//!
//! PLAY (BEST-EFFORT): the resolved title is handed to the universal resolver
//! (services/resolver.zig), which routes a torrent / stremio stream into mpv —
//! the exact handoff services/anime.zig `playEpisode` uses.
//! In-binary drama stream scrapers (Kisskh / Asiaflix / GoPlay / Cineby from the
//! wotaku wiki) are deliberately NOT hardcoded (source neutrality) — a scraper
//! can later be slotted behind the same seam; document as best-effort/manual.

const std = @import("std");

/// Origin-country classification for the region badge on each card.
pub const Origin = enum { korean, chinese, japanese, thai, taiwanese, other };

/// TMDB image CDN base for the poster grid (w342 renditions).
pub const POSTER_BASE = "https://image.tmdb.org/t/p/w342";

/// Asian origin countries for the drama lane (OR-joined; '|' percent-encoded as
/// %7C for the query string). Excludes animation so anime never leaks in here.
pub const DRAMA_ORIGINS = "KR%7CCN%7CJP%7CTW%7CHK%7CTH";

/// Map a 2-letter ISO country code (TMDB origin_country) to an Origin lane.
pub fn classifyOrigin(cc: []const u8) Origin {
    if (eqIC(cc, "KR")) return .korean;
    if (eqIC(cc, "CN")) return .chinese;
    if (eqIC(cc, "HK")) return .chinese;
    if (eqIC(cc, "JP")) return .japanese;
    if (eqIC(cc, "TW")) return .taiwanese;
    if (eqIC(cc, "TH")) return .thai;
    return .other;
}

/// Fallback classification from TMDB `original_language` (ko/zh/ja/th) when no
/// origin_country is present on the record.
pub fn classifyLang(lang: []const u8) Origin {
    if (eqIC(lang, "ko")) return .korean;
    if (eqIC(lang, "zh") or eqIC(lang, "cn")) return .chinese;
    if (eqIC(lang, "ja")) return .japanese;
    if (eqIC(lang, "th")) return .thai;
    return .other;
}

/// Short human badge for the card ("K-Drama", "J-Drama", …).
pub fn originLabel(o: Origin) []const u8 {
    return switch (o) {
        .korean => "K-Drama",
        .chinese => "C-Drama",
        .japanese => "J-Drama",
        .thai => "Thai",
        .taiwanese => "TW-Drama",
        .other => "Asian",
    };
}

fn eqIC(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Build the TMDB path+query (auth-free — for tmdb_api.tmdbApiInto) for a grid
/// page of the Asian-drama lane (KR/CN/JP/TW/HK/TH origin-country TV discover,
/// animation excluded so anime never leaks in). Returns null on bufPrint overflow.
pub fn discoverPath(page: u32, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "/3/discover/tv?with_origin_country={s}&without_genres=16&sort_by=popularity.desc&page={d}",
        .{ DRAMA_ORIGINS, page },
    ) catch null;
}

/// A query for the universal resolver (services/resolver.zig) — trims the title
/// to a clean, bounded search string. `out` must be ≥ name.len.
pub fn buildResolverQuery(name: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        if (n >= out.len) break;
        // Drop characters that confuse indexer search (quotes, brackets).
        if (c == '"' or c == '\'' or c == '[' or c == ']' or c == '(' or c == ')') continue;
        out[n] = c;
        n += 1;
    }
    return std.mem.trim(u8, out[0..n], " ");
}

// ══════════════════════════════════════════════════════════
// TMDB /discover/tv + /search/tv parsing
// ══════════════════════════════════════════════════════════

/// One catalog card, mapped onto the fields state.app.drama.results[] carries.
/// Fixed-size buffers (CLAUDE.md). Records without a usable id+name are dropped.
pub const Item = struct {
    id: [12]u8 = std.mem.zeroes([12]u8),
    id_len: usize = 0,
    name: [160]u8 = std.mem.zeroes([160]u8),
    name_len: usize = 0,
    overview: [512]u8 = std.mem.zeroes([512]u8),
    overview_len: usize = 0,
    poster_path: [80]u8 = std.mem.zeroes([80]u8),
    poster_path_len: usize = 0,
    year: [8]u8 = std.mem.zeroes([8]u8),
    year_len: usize = 0,
    vote: f32 = 0,
    origin: Origin = .other,
};

/// Parse a TMDB `/discover/tv` or `/search/tv` response into `out`. Returns the
/// number of items written. Allocation-free, string-aware, and panic-safe on
/// truncated/garbage input (fields clamp to their buffers).
pub fn parseDiscover(json: []const u8, out: []Item) usize {
    var count: usize = 0;
    var pos: usize = 0;

    while (pos < json.len and count < out.len) {
        const id_idx = std.mem.indexOfPos(u8, json, pos, "\"id\":") orelse break;
        const num_start = id_idx + 5;
        pos = num_start;

        // Scope this object up to the next "id": (or EOF).
        var next_obj = json.len;
        if (std.mem.indexOfPos(u8, json, num_start, "\"id\":")) |n| next_obj = n;
        const obj = json[num_start..next_obj];

        // id digits.
        var ne: usize = 0;
        while (ne < obj.len and obj[ne] >= '0' and obj[ne] <= '9') : (ne += 1) {}
        if (ne == 0) continue;
        const id_str = obj[0..@min(ne, out[0].id.len)];

        var item = Item{};
        @memcpy(item.id[0..id_str.len], id_str);
        item.id_len = id_str.len;

        // name → fallback original_name.
        item.name_len = extractString(obj, "\"name\":\"", &item.name);
        if (item.name_len == 0)
            item.name_len = extractString(obj, "\"original_name\":\"", &item.name);
        if (item.name_len == 0) continue;

        item.overview_len = extractString(obj, "\"overview\":\"", &item.overview);
        item.poster_path_len = extractString(obj, "\"poster_path\":\"", &item.poster_path);

        // first_air_date → YYYY.
        var d: [12]u8 = std.mem.zeroes([12]u8);
        const dl = extractString(obj, "\"first_air_date\":\"", &d);
        if (dl >= 4) {
            @memcpy(item.year[0..4], d[0..4]);
            item.year_len = 4;
        }

        item.vote = extractFloat(obj, "\"vote_average\":");

        // origin: origin_country[0], fallback original_language.
        item.origin = extractOrigin(obj);

        out[count] = item;
        count += 1;
    }
    return count;
}

/// origin_country:["KR"] first code → classifyOrigin, else original_language.
fn extractOrigin(obj: []const u8) Origin {
    if (std.mem.indexOf(u8, obj, "\"origin_country\":[")) |oi| {
        const rest = obj[oi + 18 ..];
        if (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
            const after = rest[q1 + 1 ..];
            if (std.mem.indexOfScalar(u8, after, '"')) |q2| {
                const cc = after[0..q2];
                const o = classifyOrigin(cc);
                if (o != .other) return o;
            }
        }
    }
    var lang: [8]u8 = std.mem.zeroes([8]u8);
    const ll = extractString(obj, "\"original_language\":\"", &lang);
    if (ll > 0) return classifyLang(lang[0..ll]);
    return .other;
}

/// Find `key` (which includes the opening quote) in `obj` and copy the string
/// value until the first UNESCAPED closing quote into `dst`, decoding JSON
/// escapes. Returns bytes written (≤ dst.len). 0 when the key is absent.
fn extractString(obj: []const u8, key: []const u8, dst: []u8) usize {
    const ki = std.mem.indexOf(u8, obj, key) orelse return 0;
    const start = ki + key.len;
    var end = start;
    var esc = false;
    while (end < obj.len) : (end += 1) {
        if (esc) {
            esc = false;
        } else if (obj[end] == '\\') {
            esc = true;
        } else if (obj[end] == '"') {
            break;
        }
    }
    if (end > obj.len) return 0;
    return decodeEscapes(obj[start..end], dst);
}

/// Parse the JSON number at `key` (e.g. "\"vote_average\":") as an f32. 0 on
/// absence/garbage.
fn extractFloat(obj: []const u8, key: []const u8) f32 {
    const ki = std.mem.indexOf(u8, obj, key) orelse return 0;
    var s = ki + key.len;
    while (s < obj.len and (obj[s] == ' ' or obj[s] == '\t')) : (s += 1) {}
    var e = s;
    while (e < obj.len and ((obj[e] >= '0' and obj[e] <= '9') or obj[e] == '.' or obj[e] == '-')) : (e += 1) {}
    if (e == s) return 0;
    return std.fmt.parseFloat(f32, obj[s..e]) catch 0;
}

/// Decode the common JSON string escapes (\" \\ \/ \n \r \t \uXXXX). Unknown
/// escapes keep the backslash verbatim; bounded by dst.len.
fn decodeEscapes(src: []const u8, dst: []u8) usize {
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
                        var u: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &u) catch 0;
                        if (n > 0 and out + n <= dst.len) {
                            @memcpy(dst[out .. out + n], u[0..n]);
                            out += n;
                        }
                        i += 6;
                    } else |_| { dst[out] = '\\'; out += 1; i += 1; }
                } else { dst[out] = '\\'; out += 1; i += 1; }
            },
            else => { dst[out] = '\\'; out += 1; i += 1; },
        }
    }
    return out;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "classifyOrigin + originLabel" {
    try std.testing.expectEqual(Origin.korean, classifyOrigin("KR"));
    try std.testing.expectEqual(Origin.chinese, classifyOrigin("cn"));
    try std.testing.expectEqual(Origin.chinese, classifyOrigin("HK"));
    try std.testing.expectEqual(Origin.japanese, classifyOrigin("JP"));
    try std.testing.expectEqual(Origin.taiwanese, classifyOrigin("TW"));
    try std.testing.expectEqual(Origin.thai, classifyOrigin("TH"));
    try std.testing.expectEqual(Origin.other, classifyOrigin("US"));
    try std.testing.expectEqual(Origin.other, classifyOrigin(""));
    try std.testing.expectEqualStrings("K-Drama", originLabel(.korean));
    try std.testing.expectEqualStrings("Asian", originLabel(.other));
}

test "classifyLang fallback" {
    try std.testing.expectEqual(Origin.korean, classifyLang("ko"));
    try std.testing.expectEqual(Origin.japanese, classifyLang("ja"));
    try std.testing.expectEqual(Origin.thai, classifyLang("th"));
    try std.testing.expectEqual(Origin.other, classifyLang("en"));
}

test "discoverPath builds the Asian-drama discover query" {
    var buf: [256]u8 = undefined;
    const dr = discoverPath(1, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, dr, "/3/discover/tv") != null);
    try std.testing.expect(std.mem.indexOf(u8, dr, "with_origin_country=KR%7C") != null);
    try std.testing.expect(std.mem.indexOf(u8, dr, "without_genres=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, dr, "page=1") != null);

    var buf2: [256]u8 = undefined;
    const p3 = discoverPath(3, &buf2).?;
    try std.testing.expect(std.mem.indexOf(u8, p3, "page=3") != null);
}

test "buildResolverQuery strips noise + trims" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Kingdom", buildResolverQuery("\"Kingdom\"", &out));
    try std.testing.expectEqualStrings("Reply 1988", buildResolverQuery("Reply (1988)", &out));
}

test "parseDiscover extracts fields + origin" {
    const json =
        \\{"page":1,"results":[
        \\{"adult":false,"genre_ids":[18],"id":83097,"origin_country":["KR"],"original_language":"ko","original_name":"슬기로운 감빵생활","overview":"A guard.","poster_path":"/abc.jpg","first_air_date":"2017-11-22","name":"Prison Playbook","vote_average":8.6},
        \\{"id":12345,"origin_country":["JP"],"original_language":"ja","overview":"A detective.","poster_path":"/xyz.jpg","first_air_date":"2024-09-01","name":"Tokyo Case Files","vote_average":7.1}
        \\],"total_pages":50}
    ;
    var items: [8]Item = undefined;
    const n = parseDiscover(json, &items);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("83097", items[0].id[0..items[0].id_len]);
    try std.testing.expectEqualStrings("Prison Playbook", items[0].name[0..items[0].name_len]);
    try std.testing.expectEqualStrings("/abc.jpg", items[0].poster_path[0..items[0].poster_path_len]);
    try std.testing.expectEqualStrings("2017", items[0].year[0..items[0].year_len]);
    try std.testing.expectEqual(Origin.korean, items[0].origin);
    try std.testing.expect(items[0].vote > 8.5 and items[0].vote < 8.7);
    try std.testing.expectEqual(Origin.japanese, items[1].origin);
}

test "parseDiscover survives malformed / truncated input (no crash)" {
    var items: [8]Item = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseDiscover("", &items));
    try std.testing.expectEqual(@as(usize, 0), parseDiscover("not json at all", &items));
    // Truncated mid-object: id present, name string unterminated.
    _ = parseDiscover("{\"id\":99,\"name\":\"unterminated", &items);
    // id with no digits, then a valid one.
    const j2 = "{\"id\":,\"name\":\"x\"}{\"id\":7,\"name\":\"Ok\"}";
    const n2 = parseDiscover(j2, &items);
    try std.testing.expect(n2 >= 1);
    try std.testing.expectEqualStrings("Ok", items[n2 - 1].name[0..items[n2 - 1].name_len]);
}

test "decodeEscapes handles quotes, slashes, unicode" {
    var dst: [64]u8 = undefined;
    const n = decodeEscapes("a\\/b\\\"c\\u00e9", &dst);
    try std.testing.expectEqualStrings("a/b\"cé", dst[0..n]);
}
