//! Pure parsing helpers for keyless subtitle providers — no app-state or I/O,
//! so the logic ships tested (see build.zig test step).

const std = @import("std");

pub const Parsed = struct {
    /// Cleaned free-text query (release tags/year stripped, separators → spaces).
    query: []const u8,
    /// TV episode fields — set when an SxxEyy pattern is found.
    is_tv: bool = false,
    show: []const u8 = "",
    season: u16 = 0,
    episode: u16 = 0,
};

fn isSep(ch: u8) bool {
    return ch == '.' or ch == '_' or ch == ' ' or ch == '-';
}

/// Find `S<dd>E<dd>` (case-insensitive) and return (index, season, episode).
fn findSxxEyy(name: []const u8) ?struct { at: usize, s: u16, e: u16 } {
    var i: usize = 0;
    while (i + 3 < name.len) : (i += 1) {
        if (name[i] != 'S' and name[i] != 's') continue;
        var j = i + 1;
        var s: u32 = 0;
        var sd: usize = 0;
        while (j < name.len and name[j] >= '0' and name[j] <= '9' and sd < 2) : (j += 1) {
            s = s * 10 + (name[j] - '0');
            sd += 1;
        }
        if (sd == 0) continue;
        if (j >= name.len or (name[j] != 'E' and name[j] != 'e')) continue;
        j += 1;
        var e: u32 = 0;
        var ed: usize = 0;
        while (j < name.len and name[j] >= '0' and name[j] <= '9' and ed < 3) : (j += 1) {
            e = e * 10 + (name[j] - '0');
            ed += 1;
        }
        if (ed == 0) continue;
        return .{ .at = i, .s = @intCast(s), .e = @intCast(e) };
    }
    return null;
}

/// Copy `src` into `out`, turning `.`/`_`/`-` separators into spaces and
/// collapsing runs of whitespace. Returns the trimmed slice.
fn normalizeInto(src: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var prev_space = true; // leading — skip leading spaces
    for (src) |ch| {
        const c = if (isSep(ch)) ' ' else ch;
        if (c == ' ') {
            if (prev_space) continue;
            prev_space = true;
        } else prev_space = false;
        if (n >= out.len) break;
        out[n] = c;
        n += 1;
    }
    while (n > 0 and out[n - 1] == ' ') n -= 1; // trim trailing
    return out[0..n];
}

/// Parse a media name (torrent title, filename, or media-title) into a search
/// query plus optional TV episode fields. `query_out` and `show_out` are
/// caller-owned scratch buffers the returned slices point into.
pub fn parse(name_in: []const u8, query_out: []u8, show_out: []u8) Parsed {
    // Drop a trailing file extension (last dot with a short alnum tail).
    var name = name_in;
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        const ext = name[dot + 1 ..];
        if (ext.len >= 2 and ext.len <= 4) {
            var alnum = true;
            for (ext) |c| if (!std.ascii.isAlphanumeric(c)) {
                alnum = false;
                break;
            };
            if (alnum) name = name[0..dot];
        }
    }

    if (findSxxEyy(name)) |m| {
        const show = normalizeInto(name[0..m.at], show_out);
        // Query = "show SxxEyy" so query-based providers still match.
        const q = normalizeInto(name, query_out);
        return .{ .query = q, .is_tv = true, .show = show, .season = m.s, .episode = m.e };
    }

    // Movie: cut at the first release/quality marker so the query stays clean.
    const markers = [_][]const u8{ "1080p", "720p", "2160p", "480p", "bluray", "webrip", "web-dl", "web dl", "hdtv", "dvdrip", "bdrip", "x264", "x265", "hevc", "xvid", "brrip", "proper", "repack", "extended", "remastered", "internal", "limited", "unrated" };
    var cut = name.len;
    var lower_buf: [512]u8 = undefined;
    const ln = @min(name.len, lower_buf.len);
    for (name[0..ln], 0..) |c, k| lower_buf[k] = std.ascii.toLower(c);
    const lower = lower_buf[0..ln];
    for (markers) |mk| {
        if (std.mem.indexOf(u8, lower, mk)) |idx| {
            if (idx < cut) cut = idx;
        }
    }
    const q = normalizeInto(name[0..cut], query_out);
    return .{ .query = q, .is_tv = false };
}

// ── Provider response parsing (pure — slices point into the input JSON) ──

pub const OsRestSub = struct {
    url: []const u8,
    name: []const u8,
};

/// Parse a rest.opensubtitles.org search response: every result contributes a
/// `SubDownloadLink` plus the `MovieName` that precedes it in the same object.
/// Returns how many of `out` were filled; slices point into `json`.
pub fn osRestResults(json: []const u8, out: []OsRestSub) usize {
    var count: usize = 0;
    var pos: usize = 0;
    const dl_key = "\"SubDownloadLink\":\"";
    const mn_key = "\"MovieName\":\"";
    while (count < out.len) {
        const dl_start = std.mem.indexOfPos(u8, json, pos, dl_key) orelse break;
        const url_start = dl_start + dl_key.len;
        const url_end = std.mem.indexOfPos(u8, json, url_start, "\"") orelse break;

        var name: []const u8 = "Unknown";
        const back = if (dl_start > 2000) dl_start - 2000 else 0;
        if (std.mem.lastIndexOf(u8, json[back..dl_start], mn_key)) |off| {
            const ns = back + off + mn_key.len;
            // Escape-aware closing-quote scan. TV rows come back as
            // "MovieName":"\"Show\" Episode Title" — a naive indexOf('"')
            // stops right after the leading escaped quote, so every row's
            // title rendered as a single backslash.
            if (jsonStringEnd(json, ns)) |ne| name = json[ns..ne];
        }

        if (url_end > url_start) {
            out[count] = .{ .url = json[url_start..url_end], .name = name };
            count += 1;
        }
        pos = url_end + 1;
    }
    return count;
}

/// Index of the closing (unescaped) `"` of a JSON string starting at `from`
/// (first byte after the opening quote), or null if unterminated.
fn jsonStringEnd(json: []const u8, from: usize) ?usize {
    var i = from;
    var esc = false;
    while (i < json.len) : (i += 1) {
        if (esc) {
            esc = false;
            continue;
        }
        switch (json[i]) {
            '\\' => esc = true,
            '"' => return i,
            else => {},
        }
    }
    return null;
}

/// Copy a raw JSON string value into `out` for DISPLAY: collapses \" \\ \/
/// to their plain characters and drops other escape lead-ins. Returns bytes
/// written.
pub fn unescapeJsonString(src: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len and n < out.len) {
        if (src[i] == '\\' and i + 1 < src.len) {
            const c = src[i + 1];
            switch (c) {
                '"', '\\', '/' => {
                    out[n] = c;
                    n += 1;
                },
                'n', 't', 'r' => {
                    out[n] = ' ';
                    n += 1;
                },
                else => {},
            }
            i += 2;
        } else {
            out[n] = src[i];
            n += 1;
            i += 1;
        }
    }
    return n;
}

/// Copy `src` into `out`, collapsing the JSON `\/` escape to `/` (the only
/// escape OpenSubtitles uses in its download URLs). Returns bytes written.
pub fn unescapeJsonSlashes(src: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len and n < out.len) {
        if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == '/') {
            out[n] = '/';
            n += 1;
            i += 2;
        } else {
            out[n] = src[i];
            n += 1;
            i += 1;
        }
    }
    return n;
}

pub const GestSub = struct {
    uri: []const u8,
    version: []const u8,
};

/// Parse a Gestdown `matchingSubtitles` payload: every entry contributes a
/// `downloadUri` plus the `version` (release tag) that precedes it in the same
/// object. Returns how many of `out` were filled; slices point into `json`.
pub fn gestdownSubs(json: []const u8, out: []GestSub) usize {
    var count: usize = 0;
    var pos: usize = 0;
    const du_key = "\"downloadUri\":\"";
    const v_key = "\"version\":\"";
    while (count < out.len) {
        const du_start = std.mem.indexOfPos(u8, json, pos, du_key) orelse break;
        const us = du_start + du_key.len;
        const ue = std.mem.indexOfScalarPos(u8, json, us, '"') orelse break;

        var version: []const u8 = "";
        const back = if (du_start > 400) du_start - 400 else 0;
        if (std.mem.lastIndexOf(u8, json[back..du_start], v_key)) |off| {
            const vs = back + off + v_key.len;
            if (std.mem.indexOfScalarPos(u8, json, vs, '"')) |ve| version = json[vs..ve];
        }

        if (ue > us and ue - us >= 8) {
            out[count] = .{ .uri = json[us..ue], .version = version };
            count += 1;
        }
        pos = ue + 1;
    }
    return count;
}

/// First show id (a UUID) in a Gestdown show-search response, or null.
pub fn gestdownFirstShowId(json: []const u8) ?[]const u8 {
    const key = "\"id\":\"";
    const s = (std.mem.indexOf(u8, json, key) orelse return null) + key.len;
    const e = std.mem.indexOfScalarPos(u8, json, s, '"') orelse return null;
    if (e - s < 8) return null;
    return json[s..e];
}

// ── Stremio OpenSubtitles-v3 addon (keyless chain step #3) ──

pub const StremioSub = struct {
    id: []const u8,
    url: []const u8,
    lang: []const u8,
};

/// Value for `key` (e.g. "\"lang\":") inside a JSON object slice, whether the
/// value is quoted ("eng") or bare (7). Returns the inner text without quotes,
/// or null when the key is absent. Escape-aware for quoted values.
fn jsonFieldValue(obj: []const u8, key: []const u8) ?[]const u8 {
    var i = (std.mem.indexOf(u8, obj, key) orelse return null) + key.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) i += 1;
    if (i >= obj.len) return null;
    if (obj[i] == '"') {
        const s = i + 1;
        const e = jsonStringEnd(obj, s) orelse return null;
        return obj[s..e];
    }
    var e = i;
    while (e < obj.len) : (e += 1) switch (obj[e]) {
        ',', '}', ']', ' ', '\n', '\t', '\r' => break,
        else => {},
    };
    if (e == i) return null;
    return obj[i..e];
}

/// Parse a Stremio OpenSubtitles-v3 addon response:
/// `{"subtitles":[{"id":..,"url":"..","lang":".."}, ...]}`. Each entry
/// contributes id/url/lang; the `url` is a plain-SRT download link. Returns how
/// many of `out` were filled; slices point into `json`. Field order within an
/// entry is not assumed. Malformed / truncated input yields as many well-formed
/// entries as were parsed and never traps.
pub fn stremioSubs(json: []const u8, out: []StremioSub) usize {
    var count: usize = 0;
    var pos: usize = 0;
    const url_key = "\"url\":\"";
    while (count < out.len) {
        const uk = std.mem.indexOfPos(u8, json, pos, url_key) orelse break;
        const url_start = uk + url_key.len;
        const url_end = jsonStringEnd(json, url_start) orelse break;
        const url = json[url_start..url_end];

        // Enclosing { .. } window for this entry — bound the id/lang lookups to
        // it so one entry never borrows a sibling's field.
        const obj_start = std.mem.lastIndexOfScalar(u8, json[0..uk], '{') orelse uk;
        const obj_end = std.mem.indexOfScalarPos(u8, json, url_end + 1, '}') orelse (json.len - 1);
        const obj = json[obj_start..@min(obj_end + 1, json.len)];

        const lang = jsonFieldValue(obj, "\"lang\":") orelse "";
        const id = jsonFieldValue(obj, "\"id\":") orelse "";

        if (url.len >= 8) {
            out[count] = .{ .id = id, .url = url, .lang = lang };
            count += 1;
        }
        pos = url_end + 1;
    }
    return count;
}

/// Normalise a 2-letter ISO-639-1 code to its 3-letter ISO-639-2/B form so a
/// user's "en" matches a provider's "eng". Unknown / already-3-letter codes
/// pass through unchanged (the case-insensitive compare lives in `langMatches`).
fn langAlias3(code: []const u8) []const u8 {
    const pairs = [_]struct { a: []const u8, b: []const u8 }{
        .{ .a = "en", .b = "eng" }, .{ .a = "es", .b = "spa" },
        .{ .a = "fr", .b = "fre" }, .{ .a = "de", .b = "ger" },
        .{ .a = "it", .b = "ita" }, .{ .a = "pt", .b = "por" },
        .{ .a = "ru", .b = "rus" }, .{ .a = "ja", .b = "jpn" },
        .{ .a = "ko", .b = "kor" }, .{ .a = "zh", .b = "chi" },
        .{ .a = "nl", .b = "dut" }, .{ .a = "pl", .b = "pol" },
        .{ .a = "ar", .b = "ara" }, .{ .a = "tr", .b = "tur" },
    };
    for (pairs) |p| if (std.ascii.eqlIgnoreCase(p.a, code)) return p.b;
    return code;
}

/// True when a provider-returned language `got` satisfies the user's configured
/// `want` code. Case-insensitive; treats 2- and 3-letter codes for the same
/// language as equal. An empty `want` accepts everything.
pub fn langMatches(want: []const u8, got: []const u8) bool {
    if (want.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(want, got)) return true;
    return std.ascii.eqlIgnoreCase(langAlias3(want), langAlias3(got));
}

/// First numeric `"id":` value in a TMDB search response — the top result's
/// TMDB id — as a digit string, or null. (`"genre_ids":` never contains the
/// `"id":` needle, so the first hit is the result object's own id.)
pub fn firstTmdbId(json: []const u8) ?[]const u8 {
    const key = "\"id\":";
    var i = (std.mem.indexOf(u8, json, key) orelse return null) + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '"')) i += 1;
    const s = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    if (i == s) return null;
    return json[s..i];
}

/// The `imdb_id` ("tt…") from a TMDB `/external_ids` body, or null when absent,
/// JSON-null, or malformed. Keeps the `tt` prefix — Stremio addon ids need it.
pub fn imdbFromExternalIds(json: []const u8) ?[]const u8 {
    const key = "\"imdb_id\":\"";
    const s = (std.mem.indexOf(u8, json, key) orelse return null) + key.len;
    const e = std.mem.indexOfScalarPos(u8, json, s, '"') orelse return null;
    const v = json[s..e];
    if (v.len < 3 or v[0] != 't' or v[1] != 't') return null;
    return v;
}

/// Map an ISO-ish language code to the full English name Gestdown expects.
/// Falls back to "English" for anything unmapped.
pub fn langFullName(code: []const u8) []const u8 {
    const pairs = [_]struct { c: []const u8, n: []const u8 }{
        .{ .c = "en", .n = "English" },   .{ .c = "eng", .n = "English" },
        .{ .c = "es", .n = "Spanish" },   .{ .c = "spa", .n = "Spanish" },
        .{ .c = "fr", .n = "French" },    .{ .c = "fre", .n = "French" },
        .{ .c = "de", .n = "German" },    .{ .c = "ger", .n = "German" },
        .{ .c = "it", .n = "Italian" },   .{ .c = "ita", .n = "Italian" },
        .{ .c = "pt", .n = "Portuguese" },.{ .c = "por", .n = "Portuguese" },
        .{ .c = "ru", .n = "Russian" },   .{ .c = "rus", .n = "Russian" },
        .{ .c = "ja", .n = "Japanese" },  .{ .c = "jpn", .n = "Japanese" },
        .{ .c = "ko", .n = "Korean" },    .{ .c = "kor", .n = "Korean" },
    };
    for (pairs) |p| if (std.mem.eql(u8, p.c, code)) return p.n;
    return "English";
}

test "parse extracts TV show/season/episode" {
    var q: [256]u8 = undefined;
    var s: [256]u8 = undefined;
    const p = parse("The.Boys.S01E01.1080p.WEB.H264-NTG.mkv", &q, &s);
    try std.testing.expect(p.is_tv);
    try std.testing.expectEqual(@as(u16, 1), p.season);
    try std.testing.expectEqual(@as(u16, 1), p.episode);
    try std.testing.expectEqualStrings("The Boys", p.show);
}

test "parse cleans a movie query" {
    var q: [256]u8 = undefined;
    var s: [256]u8 = undefined;
    const p = parse("Inception.2010.PROPER.1080p.BluRay.x264-GROUP.mp4", &q, &s);
    try std.testing.expect(!p.is_tv);
    try std.testing.expectEqualStrings("Inception 2010", p.query);
}

test "parse handles lowercase sxxeyy and plain names" {
    var q: [256]u8 = undefined;
    var s: [256]u8 = undefined;
    const p = parse("breaking.bad.s05e14.mkv", &q, &s);
    try std.testing.expect(p.is_tv);
    try std.testing.expectEqual(@as(u16, 5), p.season);
    try std.testing.expectEqual(@as(u16, 14), p.episode);
    try std.testing.expectEqualStrings("breaking bad", p.show);

    const p2 = parse("Some Movie Title", &q, &s);
    try std.testing.expect(!p2.is_tv);
    try std.testing.expectEqualStrings("Some Movie Title", p2.query);
}

test "unescapeJsonSlashes collapses backslash-slash" {
    var out: [128]u8 = undefined;
    const n = unescapeJsonSlashes("https:\\/\\/dl.opensubtitles.org\\/en\\/x.gz", &out);
    try std.testing.expectEqualStrings("https://dl.opensubtitles.org/en/x.gz", out[0..n]);
    // plain URLs pass through unchanged
    const m = unescapeJsonSlashes("https://api.gestdown.info/x", &out);
    try std.testing.expectEqualStrings("https://api.gestdown.info/x", out[0..m]);
}

test "langFullName maps codes, defaults English" {
    try std.testing.expectEqualStrings("Spanish", langFullName("es"));
    try std.testing.expectEqualStrings("English", langFullName("eng"));
    try std.testing.expectEqualStrings("English", langFullName("xx"));
}

test "osRestResults pairs each download link with its movie name" {
    const json =
        "[{\"MovieName\":\"Iron Man\",\"SubLanguageID\":\"eng\",\"SubDownloadLink\":\"https://dl.opensubtitles.org/en/download/a.gz\"}," ++
        "{\"MovieName\":\"Iron Man 2\",\"SubDownloadLink\":\"https://dl.opensubtitles.org/en/download/b.gz\"}]";
    var out: [12]OsRestSub = undefined;
    const n = osRestResults(json, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("Iron Man", out[0].name);
    try std.testing.expectEqualStrings("https://dl.opensubtitles.org/en/download/a.gz", out[0].url);
    try std.testing.expectEqualStrings("Iron Man 2", out[1].name);
    try std.testing.expectEqualStrings("https://dl.opensubtitles.org/en/download/b.gz", out[1].url);
}

test "osRestResults respects out capacity and tolerates missing names" {
    const json =
        "[{\"SubDownloadLink\":\"https://dl.opensubtitles.org/x1.gz\"}," ++
        "{\"SubDownloadLink\":\"https://dl.opensubtitles.org/x2.gz\"}]";
    var out: [1]OsRestSub = undefined;
    const n = osRestResults(json, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("Unknown", out[0].name);
}

test "gestdownSubs extracts multiple uri+version pairs" {
    const json =
        "{\"matchingSubtitles\":[" ++
        "{\"subtitleId\":\"s1\",\"version\":\"HDTV.x264-KILLERS\",\"completed\":true,\"downloadUri\":\"/subtitles/download/aaaa-bbbb\",\"language\":\"English\"}," ++
        "{\"subtitleId\":\"s2\",\"version\":\"WEB-DL\",\"downloadUri\":\"/subtitles/download/cccc-dddd\",\"language\":\"English\"}]}";
    var out: [3]GestSub = undefined;
    const n = gestdownSubs(json, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("/subtitles/download/aaaa-bbbb", out[0].uri);
    try std.testing.expectEqualStrings("HDTV.x264-KILLERS", out[0].version);
    try std.testing.expectEqualStrings("/subtitles/download/cccc-dddd", out[1].uri);
    try std.testing.expectEqualStrings("WEB-DL", out[1].version);
}

test "gestdownSubs skips too-short uris and caps at out.len" {
    const json =
        "{\"matchingSubtitles\":[" ++
        "{\"version\":\"BAD\",\"downloadUri\":\"/x\"}," ++
        "{\"version\":\"V1\",\"downloadUri\":\"/subtitles/download/1111\"}," ++
        "{\"version\":\"V2\",\"downloadUri\":\"/subtitles/download/2222\"}]}";
    var out: [1]GestSub = undefined;
    const n = gestdownSubs(json, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("/subtitles/download/1111", out[0].uri);
    try std.testing.expectEqualStrings("V1", out[0].version);
}

test "gestdownFirstShowId finds the first uuid, rejects short ids" {
    const json = "[{\"id\":\"3e2ff43b-99a9-4a51-8b71-4e5c1a3f0d10\",\"name\":\"The Boys\"}]";
    try std.testing.expectEqualStrings("3e2ff43b-99a9-4a51-8b71-4e5c1a3f0d10", gestdownFirstShowId(json).?);
    try std.testing.expect(gestdownFirstShowId("[{\"id\":\"short\"}]") == null);
    try std.testing.expect(gestdownFirstShowId("[]") == null);
}

test "stremioSubs parses id/url/lang entries" {
    const json =
        "{\"subtitles\":[" ++
        "{\"id\":\"1\",\"url\":\"https://opensubtitles-v3.strem.io/subtitles/download/a.srt\",\"lang\":\"eng\"}," ++
        "{\"id\":\"2\",\"url\":\"https://opensubtitles-v3.strem.io/subtitles/download/b.srt\",\"lang\":\"spa\"}]}";
    var out: [4]StremioSub = undefined;
    const n = stremioSubs(json, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("1", out[0].id);
    try std.testing.expectEqualStrings("https://opensubtitles-v3.strem.io/subtitles/download/a.srt", out[0].url);
    try std.testing.expectEqualStrings("eng", out[0].lang);
    try std.testing.expectEqualStrings("2", out[1].id);
    try std.testing.expectEqualStrings("spa", out[1].lang);
}

test "stremioSubs handles bare numeric id and reordered fields" {
    const json = "{\"subtitles\":[{\"lang\":\"fre\",\"id\":7,\"url\":\"https://x/y/7.srt\"}]}";
    var out: [2]StremioSub = undefined;
    const n = stremioSubs(json, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("7", out[0].id);
    try std.testing.expectEqualStrings("fre", out[0].lang);
    try std.testing.expectEqualStrings("https://x/y/7.srt", out[0].url);
}

test "stremioSubs regression: malformed/truncated JSON never traps" {
    var out: [4]StremioSub = undefined;
    // Truncated after url (no closing brace, no lang): still yields the url, empty lang.
    const n1 = stremioSubs("{\"subtitles\":[{\"id\":\"1\",\"url\":\"https://x/aaa.srt\"", &out);
    try std.testing.expectEqual(@as(usize, 1), n1);
    try std.testing.expectEqualStrings("https://x/aaa.srt", out[0].url);
    try std.testing.expectEqualStrings("", out[0].lang);
    // No url key / empty / garbage → zero, no trap.
    try std.testing.expectEqual(@as(usize, 0), stremioSubs("{\"subtitles\":[garbage", &out));
    try std.testing.expectEqual(@as(usize, 0), stremioSubs("", &out));
    // Unterminated url string → break, zero.
    try std.testing.expectEqual(@as(usize, 0), stremioSubs("{\"url\":\"no-end", &out));
    // Too-short url skipped.
    try std.testing.expectEqual(@as(usize, 0), stremioSubs("{\"url\":\"x\",\"lang\":\"en\"}", &out));
}

test "stremioSubs respects out capacity" {
    const json =
        "{\"subtitles\":[" ++
        "{\"url\":\"https://x/1.srt\",\"lang\":\"eng\"}," ++
        "{\"url\":\"https://x/2.srt\",\"lang\":\"eng\"}," ++
        "{\"url\":\"https://x/3.srt\",\"lang\":\"eng\"}]}";
    var out: [2]StremioSub = undefined;
    try std.testing.expectEqual(@as(usize, 2), stremioSubs(json, &out));
}

test "langMatches equates 2- and 3-letter codes, case-insensitively" {
    try std.testing.expect(langMatches("eng", "eng"));
    try std.testing.expect(langMatches("en", "eng"));
    try std.testing.expect(langMatches("EN", "eng"));
    try std.testing.expect(langMatches("es", "spa"));
    try std.testing.expect(langMatches("", "anything")); // no preference → accept all
    try std.testing.expect(!langMatches("eng", "spa"));
    try std.testing.expect(!langMatches("en", "fre"));
    try std.testing.expect(!langMatches("eng", "")); // provider omitted lang → no match
}

test "firstTmdbId reads the top result id, ignoring genre_ids" {
    const json = "{\"page\":1,\"results\":[{\"genre_ids\":[28,12],\"id\":27205,\"title\":\"Inception\"}]}";
    try std.testing.expectEqualStrings("27205", firstTmdbId(json).?);
    try std.testing.expect(firstTmdbId("{\"results\":[]}") == null);
}

test "imdbFromExternalIds keeps the tt prefix, rejects null/empty" {
    try std.testing.expectEqualStrings("tt1375666", imdbFromExternalIds("{\"id\":27205,\"imdb_id\":\"tt1375666\"}").?);
    try std.testing.expect(imdbFromExternalIds("{\"imdb_id\":null}") == null);
    try std.testing.expect(imdbFromExternalIds("{\"imdb_id\":\"\"}") == null);
    try std.testing.expect(imdbFromExternalIds("{}") == null);
}

test "osRestResults survives escaped quotes in MovieName (backslash-title regression)" {
    // Real OpenSubtitles TV shape: episode titles are quoted INSIDE the value.
    const json =
        "[{\"MovieName\":\"\\\"X-Men '97\\\" A Force to Be Reckoned With\",\"SubDownloadLink\":\"https://dl.opensubtitles.org/a.gz\"}]";
    var out: [4]OsRestSub = undefined;
    const n = osRestResults(json, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    // Raw (still-escaped) slice covers the whole value, not just "\\".
    try std.testing.expectEqualStrings("\\\"X-Men '97\\\" A Force to Be Reckoned With", out[0].name);
    // Display unescape renders the human title.
    var disp: [128]u8 = undefined;
    const dn = unescapeJsonString(out[0].name, &disp);
    try std.testing.expectEqualStrings("\"X-Men '97\" A Force to Be Reckoned With", disp[0..dn]);
}
