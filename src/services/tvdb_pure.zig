//! TheTVDB v4 fallback for anime and obscure shows: the pure half.
//!
//! TMDB stays the primary catalog. TVDB is asked only when TMDB has no match
//! (a TV search with no rows) or a season it returned is incomplete (no
//! episodes, placeholder names, missing air dates). The user supplies the key;
//! nothing is shipped. services/tvdb.zig does the login, token cache, rate
//! limiting and HTTP; everything it decides goes through here:
//!
//!   * loginBody / parseToken      POST /login {"apikey"} -> data.token
//!   * parseSearch + matchScore    GET /search?query=&type=series, ranked
//!                                 against the typed title (+ year)
//!   * seriesIdFromExternalIds     TMDB /tv/{id}/external_ids -> tvdb_id
//!   * seriesIdFromRemoteId        GET /search/remoteid/{imdb}
//!   * parseEpisodes               GET /series/{id}/episodes/default?season=N
//!   * seasonIncomplete            does a TMDB season document need help?
//!   * writeMergedSeason           TMDB season document with the gaps filled
//!                                 from TVDB (TMDB wins wherever it has data),
//!                                 still in TMDB's shape so every consumer
//!                                 (native episodes list, web season view)
//!                                 reads it unchanged.

const std = @import("std");
const cm = @import("cinemeta_pure.zig");

pub const API_BASE = "https://api4.thetvdb.com/v4";
/// Tokens are valid for a month; refresh well before that.
pub const TOKEN_TTL_S: i64 = 25 * 24 * 3600;
pub const KEY_MAX: usize = 128;
pub const TOKEN_MAX: usize = 1024;
/// Requests per second through rate_limit.zig.
pub const RATE_PER_SEC: f64 = 2.0;
pub const MAX_CANDIDATES: usize = 12;
pub const MAX_EPISODES: usize = 400;
/// Minimum match score for a search candidate to count as the same show.
pub const MATCH_THRESHOLD: u32 = 60;

// ── Login ────────────────────────────────────────────────────────────────────

/// `{"apikey":"..."}` with the key JSON-escaped. Null when it does not fit or
/// the key is empty.
pub fn loginBody(key: []const u8, out: []u8) ?[]const u8 {
    const k = std.mem.trim(u8, key, " \t\r\n");
    if (k.len == 0 or k.len > KEY_MAX) return null;
    var w = std.Io.Writer.fixed(out);
    std.json.Stringify.value(.{ .apikey = k }, .{}, &w) catch return null;
    return w.buffered();
}

/// data.token from a login response, copied into `out`.
pub fn parseToken(allocator: std.mem.Allocator, body: []const u8, out: []u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const data = objField(parsed.value, "data") orelse return null;
    const token = strField(data, "token") orelse return null;
    if (token.len == 0 or token.len > out.len) return null;
    for (token) |ch| if (ch <= 0x20 or ch == 0x7f) return null; // header-safe only
    @memcpy(out[0..token.len], token);
    return out[0..token.len];
}

// ── Search ───────────────────────────────────────────────────────────────────

pub const Candidate = struct {
    tvdb_id: u32 = 0,
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    /// English translation of the name when TVDB has one (often the romanized
    /// or localized title an anime fan types).
    eng: [128]u8 = std.mem.zeroes([128]u8),
    eng_len: usize = 0,
    year: u16 = 0,
    overview: [512]u8 = std.mem.zeroes([512]u8),
    overview_len: usize = 0,
    image: [256]u8 = std.mem.zeroes([256]u8),
    image_len: usize = 0,
    imdb: [16]u8 = std.mem.zeroes([16]u8),
    imdb_len: usize = 0,
    tmdb_id: i32 = 0,
    score: u32 = 0,

    pub fn nameText(self: *const Candidate) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn engText(self: *const Candidate) []const u8 {
        return self.eng[0..self.eng_len];
    }
    pub fn imdbText(self: *const Candidate) []const u8 {
        return self.imdb[0..self.imdb_len];
    }
    /// Best display title: the English translation when present.
    pub fn displayTitle(self: *const Candidate) []const u8 {
        return if (self.eng_len > 0) self.engText() else self.nameText();
    }
};

fn copyInto(dst: []u8, len: *usize, src: []const u8) void {
    // Never cut a UTF-8 sequence in half.
    var n = @min(src.len, dst.len);
    while (n > 0 and n < src.len and (src[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

/// Parse `/search` results (series only) into `out`. Returns the count.
pub fn parseSearch(allocator: std.mem.Allocator, body: []const u8, out: []Candidate) usize {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return 0;
    defer parsed.deinit();
    const data = switch (field(parsed.value, "data") orelse return 0) {
        .array => |a| a,
        else => return 0,
    };
    var n: usize = 0;
    for (data.items) |row| {
        if (n >= out.len) break;
        if (row != .object) continue;
        const kind = strField(row, "type") orelse strField(row, "primary_type") orelse "series";
        if (!std.mem.eql(u8, kind, "series")) continue;
        const id = idField(row, "tvdb_id") orelse continue;
        var c: Candidate = .{ .tvdb_id = id };
        copyInto(&c.name, &c.name_len, strField(row, "name") orelse continue);
        if (objField(row, "translations")) |tr| if (strField(tr, "eng")) |e| copyInto(&c.eng, &c.eng_len, e);
        if (strField(row, "year")) |y| c.year = std.fmt.parseInt(u16, y, 10) catch 0;
        if (c.year == 0) if (strField(row, "first_air_time")) |d| {
            if (d.len >= 4) c.year = std.fmt.parseInt(u16, d[0..4], 10) catch 0;
        };
        const ov = if (objField(row, "overviews")) |o| strField(o, "eng") else null;
        copyInto(&c.overview, &c.overview_len, ov orelse strField(row, "overview") orelse "");
        const img = strField(row, "image_url") orelse strField(row, "thumbnail") orelse "";
        if (img.len <= c.image.len and std.mem.startsWith(u8, img, "https://")) copyInto(&c.image, &c.image_len, img);
        if (field(row, "remote_ids")) |rids| if (rids == .array) for (rids.array.items) |rid| {
            const src = strField(rid, "sourceName") orelse continue;
            const val = strField(rid, "id") orelse continue;
            if (std.ascii.eqlIgnoreCase(src, "IMDB") and cm.validImdbId(val)) copyInto(&c.imdb, &c.imdb_len, val);
            if (std.ascii.startsWithIgnoreCase(src, "TheMovieDB")) c.tmdb_id = std.fmt.parseInt(i32, val, 10) catch 0;
        };
        out[n] = c;
        n += 1;
    }
    return n;
}

/// Lowercase ASCII letters and digits only, everything else dropped, so
/// "Shingeki no Kyojin" == "shingeki-no-kyojin" and "Re:Zero" == "rezero".
/// Non-ASCII bytes are kept as-is (a Japanese title still compares exactly).
pub fn normTitle(raw: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (raw) |ch| {
        if (n >= out.len) break;
        if (std.ascii.isAlphanumeric(ch)) {
            out[n] = std.ascii.toLower(ch);
            n += 1;
        } else if (ch >= 0x80) {
            out[n] = ch;
            n += 1;
        }
    }
    return out[0..n];
}

pub const TitleYear = struct { title: []const u8, year: u16 };

/// "Frieren 2023" / "Frieren (2023)" -> ("Frieren", 2023). No year -> 0.
pub fn splitYear(query: []const u8) TitleYear {
    const q = std.mem.trim(u8, query, " ");
    if (q.len >= 6) {
        var tail = q[q.len - 4 ..];
        var head = q[0 .. q.len - 4];
        if (q[q.len - 1] == ')' and q.len >= 7 and q[q.len - 6] == '(') {
            tail = q[q.len - 5 .. q.len - 1];
            head = q[0 .. q.len - 6];
        }
        const y = std.fmt.parseInt(u16, tail, 10) catch 0;
        if (y >= 1900 and y <= 2100 and head.len > 0 and head[head.len - 1] == ' ')
            return .{ .title = std.mem.trim(u8, head, " "), .year = y };
    }
    return .{ .title = q, .year = 0 };
}

/// How well a candidate matches what the user typed (0..110).
pub fn matchScore(title: []const u8, year: u16, c: *const Candidate) u32 {
    var qb: [256]u8 = undefined;
    const q = normTitle(title, &qb);
    if (q.len == 0) return 0;
    var best: u32 = 0;
    for ([_][]const u8{ c.nameText(), c.engText() }) |name| {
        var nb: [256]u8 = undefined;
        const n = normTitle(name, &nb);
        if (n.len == 0) continue;
        const s: u32 = if (std.mem.eql(u8, n, q))
            100
        else if (std.mem.startsWith(u8, n, q) or std.mem.startsWith(u8, q, n))
            70
        else if (q.len >= 4 and std.mem.indexOf(u8, n, q) != null)
            60
        else
            0;
        best = @max(best, s);
    }
    if (best == 0) return 0;
    if (year != 0 and c.year != 0) {
        const d = if (year > c.year) year - c.year else c.year - year;
        if (d == 0) return best + 10;
        if (d == 1) return best + 5;
        return best -| 30;
    }
    return best;
}

/// Score every candidate against `query` and order them best-first, dropping
/// those under MATCH_THRESHOLD. Returns the kept count.
pub fn rankCandidates(query: []const u8, items: []Candidate) usize {
    const ty = splitYear(query);
    var kept: usize = 0;
    for (0..items.len) |i| {
        items[i].score = matchScore(ty.title, ty.year, &items[i]);
        if (items[i].score < MATCH_THRESHOLD) continue;
        if (kept != i) items[kept] = items[i];
        kept += 1;
    }
    std.mem.sort(Candidate, items[0..kept], {}, struct {
        fn more(_: void, a: Candidate, b: Candidate) bool {
            return a.score > b.score;
        }
    }.more);
    return kept;
}

/// Catalog identity for a TVDB-only search row: the TMDB id TVDB knows, or
/// the keyless IMDb hash (cinemeta_pure.stableId) the rest of Opal already
/// opens through Cinemeta. Null = nothing Opal can open safely.
pub fn catalogId(c: *const Candidate) ?i32 {
    if (c.tmdb_id > 0) return c.tmdb_id;
    if (cm.validImdbId(c.imdbText())) return cm.stableId(c.imdbText());
    return null;
}

// ── Series id resolution ─────────────────────────────────────────────────────

/// TMDB `/3/tv/{id}/external_ids` -> tvdb_id.
pub fn seriesIdFromExternalIds(allocator: std.mem.Allocator, body: []const u8) ?u32 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    return idField(parsed.value, "tvdb_id");
}

/// TVDB `/search/remoteid/{imdb}` -> data[].series.id (first series hit).
pub fn seriesIdFromRemoteId(allocator: std.mem.Allocator, body: []const u8) ?u32 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const data = field(parsed.value, "data") orelse return null;
    if (data != .array) return null;
    for (data.array.items) |row| {
        const series = objField(row, "series") orelse continue;
        if (idField(series, "id")) |id| return id;
    }
    return null;
}

// ── Episodes ─────────────────────────────────────────────────────────────────

pub const Episode = struct {
    season: i32 = 0,
    number: i32 = 0,
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    overview: [512]u8 = std.mem.zeroes([512]u8),
    overview_len: usize = 0,
    aired: [10]u8 = std.mem.zeroes([10]u8),
    aired_len: usize = 0,
    runtime: u16 = 0,

    pub fn nameText(self: *const Episode) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn overviewText(self: *const Episode) []const u8 {
        return self.overview[0..self.overview_len];
    }
    pub fn airedText(self: *const Episode) []const u8 {
        return self.aired[0..self.aired_len];
    }
};

/// `/series/{id}/episodes/default` -> episodes of `season` (all when null),
/// numbered >= 1, first occurrence wins. Returns the count.
pub fn parseEpisodes(allocator: std.mem.Allocator, body: []const u8, season: ?i32, out: []Episode) usize {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return 0;
    defer parsed.deinit();
    const data = objField(parsed.value, "data") orelse return 0;
    const eps = field(data, "episodes") orelse return 0;
    if (eps != .array) return 0;
    var n: usize = 0;
    outer: for (eps.array.items) |row| {
        if (n >= out.len) break;
        const sn = intField(row, "seasonNumber") orelse continue;
        const num = intField(row, "number") orelse continue;
        if (num < 1) continue;
        if (season) |want| if (sn != want) continue;
        for (out[0..n]) |*seen| if (seen.season == sn and seen.number == num) continue :outer;
        var e: Episode = .{ .season = sn, .number = num };
        copyInto(&e.name, &e.name_len, strField(row, "name") orelse "");
        copyInto(&e.overview, &e.overview_len, strField(row, "overview") orelse "");
        const aired = strField(row, "aired") orelse "";
        if (aired.len >= 10) copyInto(&e.aired, &e.aired_len, aired[0..10]);
        if (intField(row, "runtime")) |rt| e.runtime = @intCast(std.math.clamp(rt, 0, 600));
        out[n] = e;
        n += 1;
    }
    return n;
}

/// TMDB's stand-in for an unnamed episode ("Episode 7"), or nothing at all.
pub fn placeholderName(name: []const u8, number: i64) bool {
    const t = std.mem.trim(u8, name, " ");
    if (t.len == 0) return true;
    var b: [32]u8 = undefined;
    const generic = std.fmt.bufPrint(&b, "Episode {d}", .{number}) catch return false;
    return std.ascii.eqlIgnoreCase(t, generic);
}

/// Whether a TMDB `/tv/{id}/season/{n}` body needs TVDB: unparseable or an
/// error document (TMDB has no such season), no episodes, or any episode
/// with a placeholder name or no air date.
pub fn seasonIncomplete(allocator: std.mem.Allocator, body: ?[]const u8) bool {
    const b = body orelse return true;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, b, .{}) catch return true;
    defer parsed.deinit();
    const eps = field(parsed.value, "episodes") orelse return true;
    if (eps != .array or eps.array.items.len == 0) return true;
    for (eps.array.items) |row| {
        const num = intField(row, "episode_number") orelse return true;
        if (placeholderName(strField(row, "name") orelse "", num)) return true;
        const air: []const u8 = strField(row, "air_date") orelse "";
        if (air.len == 0) return true;
    }
    return false;
}

fn findEpisode(eps: []const Episode, number: i64) ?*const Episode {
    for (eps) |*e| if (e.number == number) return e;
    return null;
}

/// Write the TMDB season document with its gaps filled from TVDB, in TMDB's
/// shape. TMDB fields win wherever they hold data; TVDB fills placeholder
/// names, empty overviews, missing air dates and runtimes, and adds episodes
/// TMDB does not list. With no usable TMDB document the season is built from
/// TVDB alone. Top-level fields other than "episodes" are copied verbatim.
pub fn writeMergedSeason(allocator: std.mem.Allocator, w: *std.Io.Writer, tmdb_body: ?[]const u8, season: i32, tvdb: []const Episode) !void {
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();
    if (tmdb_body) |b| {
        if (std.json.parseFromSlice(std.json.Value, allocator, b, .{})) |p| {
            if (p.value == .object and (field(p.value, "episodes") orelse std.json.Value{ .null = {} }) == .array) parsed = p else {
                var q = p;
                q.deinit();
            }
        } else |_| {}
    }

    try w.writeByte('{');
    var first = true;
    var has_season_number = false;
    if (parsed) |p| {
        var it = p.value.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "episodes")) continue;
            if (std.mem.eql(u8, entry.key_ptr.*, "season_number")) has_season_number = true;
            if (!first) try w.writeByte(',');
            first = false;
            try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
            try w.writeByte(':');
            try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
        }
    }
    if (!has_season_number) {
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"season_number\":{d}", .{season});
        var nb: [32]u8 = undefined;
        try w.writeAll(",\"name\":");
        try std.json.Stringify.value(std.fmt.bufPrint(&nb, "Season {d}", .{season}) catch "Season", .{}, w);
    }
    if (!first) try w.writeByte(',');
    try w.writeAll("\"episodes\":[");

    // Episode numbers in output order: TMDB's, then TVDB-only ones, ascending.
    var numbers: [MAX_EPISODES]i64 = undefined;
    var count: usize = 0;
    var tmdb_eps: []const std.json.Value = &.{};
    if (parsed) |p| tmdb_eps = p.value.object.get("episodes").?.array.items;
    for (tmdb_eps) |row| {
        const num = intField(row, "episode_number") orelse continue;
        if (count < numbers.len and std.mem.indexOfScalar(i64, numbers[0..count], num) == null) {
            numbers[count] = num;
            count += 1;
        }
    }
    for (tvdb) |e| {
        if (e.season != season) continue;
        if (count < numbers.len and std.mem.indexOfScalar(i64, numbers[0..count], e.number) == null) {
            numbers[count] = e.number;
            count += 1;
        }
    }
    std.mem.sort(i64, numbers[0..count], {}, std.sort.asc(i64));

    for (numbers[0..count], 0..) |num, i| {
        if (i > 0) try w.writeByte(',');
        var tmdb_row: ?std.json.Value = null;
        for (tmdb_eps) |row| {
            if ((intField(row, "episode_number") orelse continue) == num) {
                tmdb_row = row;
                break;
            }
        }
        var tv_ep: ?*const Episode = null;
        for (tvdb) |*e| if (e.season == season and e.number == num) {
            tv_ep = e;
            break;
        };
        try writeEpisode(w, tmdb_row, tv_ep, season, num);
    }
    try w.writeAll("],\"opal_filled_by\":\"tvdb\"}");
}

fn writeEpisode(w: *std.Io.Writer, tmdb_row: ?std.json.Value, tv: ?*const Episode, season: i32, num: i64) !void {
    try w.writeByte('{');
    var first = true;
    var seen_name = false;
    var seen_overview = false;
    var seen_air = false;
    var seen_runtime = false;
    if (tmdb_row) |row| if (row == .object) {
        var it = row.object.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            if (!first) try w.writeByte(',');
            first = false;
            try std.json.Stringify.value(k, .{}, w);
            try w.writeByte(':');
            if (std.mem.eql(u8, k, "name")) {
                seen_name = true;
                const cur = if (v == .string) v.string else "";
                const fill = if (tv) |e| e.nameText() else "";
                try std.json.Stringify.value(if (placeholderName(cur, num) and fill.len > 0 and !placeholderName(fill, num)) fill else cur, .{}, w);
            } else if (std.mem.eql(u8, k, "overview")) {
                seen_overview = true;
                const cur = if (v == .string) v.string else "";
                const fill = if (tv) |e| e.overviewText() else "";
                try std.json.Stringify.value(if (cur.len == 0) fill else cur, .{}, w);
            } else if (std.mem.eql(u8, k, "air_date")) {
                seen_air = true;
                const cur = if (v == .string) v.string else "";
                const fill = if (tv) |e| e.airedText() else "";
                if (cur.len == 0 and fill.len == 0) try w.writeAll("null") else try std.json.Stringify.value(if (cur.len == 0) fill else cur, .{}, w);
            } else if (std.mem.eql(u8, k, "runtime")) {
                seen_runtime = true;
                const cur: i64 = if (v == .integer) v.integer else 0;
                const fill: i64 = if (tv) |e| e.runtime else 0;
                if (cur == 0 and fill == 0) try w.writeAll("null") else try w.print("{d}", .{if (cur > 0) cur else fill});
            } else {
                try std.json.Stringify.value(v, .{}, w);
            }
        }
    };
    if (first) {
        try w.print("\"episode_number\":{d},\"season_number\":{d}", .{ num, season });
        first = false;
    }
    const e = tv orelse {
        try w.writeByte('}');
        return;
    };
    if (!seen_name) {
        var b: [32]u8 = undefined;
        try w.writeAll(",\"name\":");
        try std.json.Stringify.value(if (e.name_len > 0) e.nameText() else (std.fmt.bufPrint(&b, "Episode {d}", .{num}) catch ""), .{}, w);
    }
    if (!seen_overview) {
        try w.writeAll(",\"overview\":");
        try std.json.Stringify.value(e.overviewText(), .{}, w);
    }
    if (!seen_air and e.aired_len > 0) {
        try w.writeAll(",\"air_date\":");
        try std.json.Stringify.value(e.airedText(), .{}, w);
    }
    if (!seen_runtime and e.runtime > 0) try w.print(",\"runtime\":{d}", .{e.runtime});
    try w.writeByte('}');
}

// ── JSON helpers ─────────────────────────────────────────────────────────────

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn objField(v: std.json.Value, name: []const u8) ?std.json.Value {
    const f = field(v, name) orelse return null;
    return if (f == .object) f else null;
}

fn strField(v: std.json.Value, name: []const u8) ?[]const u8 {
    const f = field(v, name) orelse return null;
    return if (f == .string) f.string else null;
}

fn intField(v: std.json.Value, name: []const u8) ?i32 {
    const f = field(v, name) orelse return null;
    return switch (f) {
        .integer => |i| std.math.cast(i32, i),
        else => null,
    };
}

/// An id that may arrive as a number or a numeric string ("81189").
fn idField(v: std.json.Value, name: []const u8) ?u32 {
    const f = field(v, name) orelse return null;
    const id: ?u32 = switch (f) {
        .integer => |i| std.math.cast(u32, i),
        .string => |s| std.fmt.parseInt(u32, s, 10) catch null,
        else => null,
    };
    return if (id) |x| (if (x == 0) null else x) else null;
}

// ══════════════════════════════════════════════════════════
// Tests (fixtures are trimmed real-shape TVDB v4 / TMDB documents)
// ══════════════════════════════════════════════════════════

const T = std.testing;

const FIXTURE_LOGIN = "{\"status\":\"success\",\"data\":{\"token\":\"eyJhbGciOi.payload.sig\"}}";

const FIXTURE_SEARCH =
    \\{"status":"success","data":[
    \\ {"objectID":"series-355567","name":"Sousou no Frieren","tvdb_id":"424536","type":"series","year":"2023",
    \\  "overview":"Elf mage...","image_url":"https://artworks.thetvdb.com/banners/v4/series/424536/posters/a.jpg",
    \\  "translations":{"eng":"Frieren: Beyond Journey's End","jpn":"葬送のフリーレン"},
    \\  "overviews":{"eng":"After the party of heroes defeated the Demon King..."},
    \\  "remote_ids":[{"id":"tt22248376","type":2,"sourceName":"IMDB"},{"id":"209867","type":12,"sourceName":"TheMovieDB.com"}]},
    \\ {"objectID":"series-1","name":"Frieren Recap Specials","tvdb_id":"999001","type":"series","year":"2024","remote_ids":[]},
    \\ {"objectID":"movie-5","name":"Frieren","tvdb_id":"5","type":"movie","year":"2023"},
    \\ {"objectID":"series-2","name":"Obscure Doc Series","tvdb_id":"777","type":"series","first_air_time":"2011-04-02",
    \\  "remote_ids":[{"id":"tt1234567","type":2,"sourceName":"IMDB"}]},
    \\ {"objectID":"series-3","name":"No Identity Show","tvdb_id":"888","type":"series"},
    \\ {"objectID":"series-4","name":"Broken","type":"series"}
    \\]}
;

const FIXTURE_EPISODES =
    \\{"status":"success","data":{"series":{"id":424536,"name":"Sousou no Frieren"},"episodes":[
    \\ {"id":1,"seriesId":424536,"name":"The Journey's End","aired":"2023-09-29","runtime":24,"overview":"The hero party returns.","number":1,"seasonNumber":1},
    \\ {"id":2,"seriesId":424536,"name":"It Didn't Have to Be Magic...","aired":"2023-09-29","runtime":24,"overview":"Fern.","number":2,"seasonNumber":1},
    \\ {"id":3,"seriesId":424536,"name":"Killing Magic","aired":"2023-10-06T00:00:00Z","runtime":24,"overview":"","number":3,"seasonNumber":1},
    \\ {"id":4,"seriesId":424536,"name":"Recap","aired":"2023-12-01","runtime":12,"number":1,"seasonNumber":0},
    \\ {"id":5,"seriesId":424536,"name":"Dup","aired":"2023-10-06","number":3,"seasonNumber":1},
    \\ {"id":6,"seriesId":424536,"name":"Bad","number":0,"seasonNumber":1}
    \\]},"links":{"next":null}}
;

// TMDB season with an anime-typical gap: placeholder name, no overview, no
// air date on the last episode, and only two of three episodes listed.
const FIXTURE_TMDB_SEASON =
    \\{"_id":"abc","air_date":"2023-09-29","name":"Season 1","overview":"","id":336420,"poster_path":"/p.jpg","season_number":1,
    \\ "episodes":[
    \\  {"air_date":"2023-09-29","episode_number":1,"name":"The Journey's End","overview":"TMDB overview wins.","id":1,"runtime":25,"season_number":1,"still_path":"/s1.jpg","vote_average":8.5,"crew":[]},
    \\  {"air_date":null,"episode_number":2,"name":"Episode 2","overview":"","id":2,"runtime":null,"season_number":1,"still_path":null,"vote_average":0}
    \\ ]}
;

test "login body escapes the key; token parse rejects junk" {
    var b: [256]u8 = undefined;
    try T.expectEqualStrings("{\"apikey\":\"abc-123\"}", loginBody(" abc-123\n", &b).?);
    try T.expectEqualStrings("{\"apikey\":\"a\\\"b\"}", loginBody("a\"b", &b).?);
    try T.expect(loginBody("", &b) == null);
    var tb: [TOKEN_MAX]u8 = undefined;
    try T.expectEqualStrings("eyJhbGciOi.payload.sig", parseToken(T.allocator, FIXTURE_LOGIN, &tb).?);
    try T.expect(parseToken(T.allocator, "{\"status\":\"failure\",\"message\":\"Unauthorized\"}", &tb) == null);
    try T.expect(parseToken(T.allocator, "{\"data\":{\"token\":\"a b\"}}", &tb) == null); // header injection
    try T.expect(parseToken(T.allocator, "<html>", &tb) == null);
}

test "search parses series rows with remote ids; movies and id-less rows skipped" {
    var out: [MAX_CANDIDATES]Candidate = undefined;
    const n = parseSearch(T.allocator, FIXTURE_SEARCH, &out);
    try T.expectEqual(@as(usize, 4), n);
    const f = &out[0];
    try T.expectEqual(@as(u32, 424536), f.tvdb_id);
    try T.expectEqualStrings("Frieren: Beyond Journey's End", f.displayTitle());
    try T.expectEqual(@as(u16, 2023), f.year);
    try T.expectEqualStrings("tt22248376", f.imdbText());
    try T.expectEqual(@as(i32, 209867), f.tmdb_id);
    try T.expect(std.mem.startsWith(u8, f.overview[0..f.overview_len], "After the party"));
    try T.expectEqual(@as(u16, 2011), out[2].year); // from first_air_time
    try T.expectEqual(@as(usize, 0), parseSearch(T.allocator, "not json", &out));
    try T.expectEqual(@as(usize, 0), parseSearch(T.allocator, "{\"data\":{}}", &out));
}

test "matching: romanized and English titles, year breaks ties, threshold drops noise" {
    var out: [MAX_CANDIDATES]Candidate = undefined;
    var n = parseSearch(T.allocator, FIXTURE_SEARCH, &out);
    // English title typed with punctuation differences.
    try T.expect(matchScore("frieren beyond journeys end", 0, &out[0]) >= 100);
    // Romanized title + matching year.
    try T.expectEqual(@as(u32, 110), matchScore("Sousou no Frieren", 2023, &out[0]));
    try T.expect(matchScore("Sousou no Frieren", 2015, &out[0]) < 100);
    try T.expectEqual(@as(u32, 0), matchScore("Breaking Bad", 0, &out[0]));
    n = rankCandidates("Frieren (2023)", out[0..n]);
    try T.expect(n >= 1);
    try T.expectEqual(@as(u32, 424536), out[0].tvdb_id);
    for (out[0..n]) |c| try T.expect(c.score >= MATCH_THRESHOLD);
    var m = parseSearch(T.allocator, FIXTURE_SEARCH, &out);
    m = rankCandidates("zzzz unrelated", out[0..m]);
    try T.expectEqual(@as(usize, 0), m);
}

test "split year from a typed query" {
    try T.expectEqual(@as(u16, 2023), splitYear("Frieren 2023").year);
    try T.expectEqualStrings("Frieren", splitYear("Frieren (2023)").title);
    try T.expectEqual(@as(u16, 0), splitYear("2023").year);
    try T.expectEqual(@as(u16, 0), splitYear("Blade Runner 2049x").year);
    try T.expectEqualStrings("1923", splitYear("1923").title);
}

test "catalog identity: TMDB id first, then keyless IMDb hash, else unusable" {
    var out: [MAX_CANDIDATES]Candidate = undefined;
    _ = parseSearch(T.allocator, FIXTURE_SEARCH, &out);
    try T.expectEqual(@as(?i32, 209867), catalogId(&out[0]));
    try T.expectEqual(@as(?i32, cm.stableId("tt1234567")), catalogId(&out[2]));
    try T.expectEqual(@as(?i32, null), catalogId(&out[3]));
}

test "series id from TMDB external ids and TVDB remote-id search" {
    try T.expectEqual(@as(?u32, 81189), seriesIdFromExternalIds(T.allocator, "{\"id\":1396,\"imdb_id\":\"tt0903747\",\"tvdb_id\":81189}"));
    try T.expectEqual(@as(?u32, null), seriesIdFromExternalIds(T.allocator, "{\"id\":1,\"tvdb_id\":null}"));
    try T.expectEqual(@as(?u32, null), seriesIdFromExternalIds(T.allocator, "{\"tvdb_id\":0}"));
    try T.expectEqual(@as(?u32, 81189), seriesIdFromRemoteId(T.allocator, "{\"status\":\"success\",\"data\":[{\"episode\":null},{\"series\":{\"id\":81189,\"name\":\"Breaking Bad\"}}]}"));
    try T.expectEqual(@as(?u32, null), seriesIdFromRemoteId(T.allocator, "{\"data\":[]}"));
}

test "episodes: one season, deduped, numbered, dates trimmed" {
    var eps: [MAX_EPISODES]Episode = undefined;
    const n = parseEpisodes(T.allocator, FIXTURE_EPISODES, 1, &eps);
    try T.expectEqual(@as(usize, 3), n);
    try T.expectEqualStrings("Killing Magic", eps[2].nameText());
    try T.expectEqualStrings("2023-10-06", eps[2].airedText());
    try T.expectEqual(@as(u16, 24), eps[0].runtime);
    try T.expectEqual(@as(usize, 4), parseEpisodes(T.allocator, FIXTURE_EPISODES, null, &eps)); // + the special
    try T.expectEqual(@as(usize, 0), parseEpisodes(T.allocator, "{\"status\":\"failure\"}", 1, &eps));
}

test "season completeness: placeholders, missing dates, empty and error docs" {
    try T.expect(seasonIncomplete(T.allocator, FIXTURE_TMDB_SEASON));
    try T.expect(seasonIncomplete(T.allocator, null));
    try T.expect(seasonIncomplete(T.allocator, "{\"success\":false,\"status_code\":34}"));
    try T.expect(seasonIncomplete(T.allocator, "{\"episodes\":[]}"));
    try T.expect(!seasonIncomplete(T.allocator, "{\"episodes\":[{\"episode_number\":1,\"name\":\"Pilot\",\"air_date\":\"2008-01-20\"}]}"));
    try T.expect(placeholderName("Episode 7", 7));
    try T.expect(placeholderName(" ", 7));
    try T.expect(!placeholderName("Episode 7", 8)); // a real title that happens to read that way
    try T.expect(!placeholderName("Pilot", 1));
}

test "merge fills TMDB gaps from TVDB, keeps TMDB data, adds missing episodes" {
    var eps: [MAX_EPISODES]Episode = undefined;
    const n = parseEpisodes(T.allocator, FIXTURE_EPISODES, 1, &eps);
    var out: std.Io.Writer.Allocating = .init(T.allocator);
    defer out.deinit();
    try writeMergedSeason(T.allocator, &out.writer, FIXTURE_TMDB_SEASON, 1, eps[0..n]);
    const doc = try std.json.parseFromSlice(std.json.Value, T.allocator, out.written(), .{});
    defer doc.deinit();
    const root = doc.value.object;
    try T.expectEqual(@as(i64, 336420), root.get("id").?.integer); // top level kept
    try T.expectEqualStrings("/p.jpg", root.get("poster_path").?.string);
    const list = root.get("episodes").?.array.items;
    try T.expectEqual(@as(usize, 3), list.len);
    // Episode 1: TMDB complete, untouched (overview, runtime, extra keys).
    try T.expectEqualStrings("TMDB overview wins.", list[0].object.get("overview").?.string);
    try T.expectEqual(@as(i64, 25), list[0].object.get("runtime").?.integer);
    try T.expect(list[0].object.get("crew") != null);
    // Episode 2: placeholder name, empty overview, null date + runtime filled.
    try T.expectEqualStrings("It Didn't Have to Be Magic...", list[1].object.get("name").?.string);
    try T.expectEqualStrings("Fern.", list[1].object.get("overview").?.string);
    try T.expectEqualStrings("2023-09-29", list[1].object.get("air_date").?.string);
    try T.expectEqual(@as(i64, 24), list[1].object.get("runtime").?.integer);
    try T.expectEqual(@as(i64, 2), list[1].object.get("id").?.integer);
    // Episode 3: TVDB only.
    try T.expectEqual(@as(i64, 3), list[2].object.get("episode_number").?.integer);
    try T.expectEqualStrings("Killing Magic", list[2].object.get("name").?.string);
    // The merged document still satisfies TMDB consumers and is complete now.
    try T.expect(std.mem.indexOf(u8, out.written(), "\"episodes\":[") != null);
    try T.expect(!seasonIncomplete(T.allocator, out.written()));
}

test "merge with no TMDB season builds it from TVDB alone" {
    var eps: [MAX_EPISODES]Episode = undefined;
    const n = parseEpisodes(T.allocator, FIXTURE_EPISODES, 1, &eps);
    var out: std.Io.Writer.Allocating = .init(T.allocator);
    defer out.deinit();
    try writeMergedSeason(T.allocator, &out.writer, "{\"success\":false,\"status_code\":34,\"status_message\":\"not found\"}", 1, eps[0..n]);
    const doc = try std.json.parseFromSlice(std.json.Value, T.allocator, out.written(), .{});
    defer doc.deinit();
    const root = doc.value.object;
    try T.expectEqual(@as(i64, 1), root.get("season_number").?.integer);
    try T.expect(root.get("status_code") == null); // the error document is dropped
    const list = root.get("episodes").?.array.items;
    try T.expectEqual(@as(usize, 3), list.len);
    try T.expectEqualStrings("The Journey's End", list[0].object.get("name").?.string);
    try T.expectEqual(@as(i64, 1), list[0].object.get("season_number").?.integer);
}
