//! Keyless Movies & TV detail pages: reshape Cinemeta `meta/{movie|series}/{imdb}.json`
//! into the TMDB-shaped documents the web companion already renders, plus the
//! category/genre mapping and the id -> IMDb identity table the keyless catalog
//! needs. Pure: no network, no globals (the identity table is a value the
//! caller guards with its own lock).

const std = @import("std");
const cinemeta = @import("cinemeta_pure.zig");

pub const Kind = enum { movie, series };

pub fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .movie => "movie",
        .series => "series",
    };
}

// ── Category and genre mapping ─────────────────────────────────────────────

pub const Category = enum { trending, popular, top_rated, now_playing, upcoming };
pub const Catalog = enum { top, imdbRating, year };

pub fn catalogName(c: Catalog) []const u8 {
    return @tagName(c);
}

/// Which Cinemeta catalog honestly answers a browse request. Cinemeta has
/// `top` (popularity), `imdbRating` and `year` (newest first). Only `top` and
/// `imdbRating` accept a genre extra (on `year` the extra means a release year),
/// and `top` is the only catalog that accepts a search extra.
pub fn catalogFor(cat: Category, genre_active: bool, search: bool) Catalog {
    if (search) return .top;
    return switch (cat) {
        .top_rated => .imdbRating,
        .now_playing, .upcoming => if (genre_active) .top else .year,
        .trending, .popular => .top,
    };
}

/// With a genre selected the app shows Popular / Top rated sort chips instead
/// of category chips. Newest has no keyless equivalent (the `year` catalog does
/// not take a genre) so it is not offered.
pub fn effectiveCategory(cat: Category, genre_active: bool, discover_sort: u8) Category {
    if (!genre_active) return cat;
    return if (discover_sort == 1) .top_rated else .trending;
}

/// Genres Cinemeta can filter on, by the same names the app's dropdown uses.
/// "Music" is the one app genre with no Cinemeta equivalent.
pub fn genreSupported(name: []const u8) bool {
    const names = [_][]const u8{
        "Action",  "Adventure", "Animation", "Comedy", "Crime",   "Documentary", "Drama",
        "Family",  "Fantasy",   "History",   "Horror", "Mystery", "Romance",     "Sci-Fi",
        "Thriller", "War",      "Western",
    };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Keyless Trending and Popular are the same Cinemeta list, so only one chip is
/// shown (labelled Popular). A saved or API-selected category with no keyless
/// chip is folded onto the chip that is shown.
pub fn foldKeylessCategory(cat: Category) Category {
    return switch (cat) {
        .popular => .trending,
        .upcoming => .now_playing,
        else => cat,
    };
}

// ── id -> IMDb identity table ──────────────────────────────────────────────

/// Keyless catalog rows carry a TMDB-or-synthetic integer id plus an IMDb id.
/// Detail routes receive only the integer, so recently listed rows are
/// remembered here. Fixed capacity, oldest overwritten.
pub const IdentityTable = struct {
    pub const CAP = 1024;
    ids: [CAP]i32 = @splat(0),
    imdb: [CAP][16]u8 = @splat(@splat(0)),
    imdb_len: [CAP]u8 = @splat(0),
    next: usize = 0,

    pub fn record(self: *IdentityTable, id: i32, imdb: []const u8) void {
        if (id == 0 or !cinemeta.validImdbId(imdb) or imdb.len > 16) return;
        var slot: ?usize = null;
        for (self.ids, 0..) |v, i| {
            if (v == id) {
                slot = i;
                break;
            }
        }
        const i = slot orelse blk: {
            const s = self.next;
            self.next = (self.next + 1) % CAP;
            break :blk s;
        };
        self.ids[i] = id;
        @memcpy(self.imdb[i][0..imdb.len], imdb);
        self.imdb_len[i] = @intCast(imdb.len);
    }

    pub fn lookup(self: *const IdentityTable, id: i32, out: []u8) []const u8 {
        if (id == 0) return "";
        for (self.ids, 0..) |v, i| {
            if (v != id) continue;
            const n = self.imdb_len[i];
            if (n == 0 or n > out.len) return "";
            @memcpy(out[0..n], self.imdb[i][0..n]);
            return out[0..n];
        }
        return "";
    }
};

// ── Meta document reading helpers ──────────────────────────────────────────

fn objField(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    const f = objField(v, key) orelse return "";
    return if (f == .string) f.string else "";
}

fn intField(v: std.json.Value, key: []const u8) ?i64 {
    const f = objField(v, key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| if (std.math.isFinite(x) and @abs(x) < 1e9) @as(i64, @intFromFloat(x)) else null,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// "102 min", "1h 42min", "49" -> minutes. 0 when absent.
pub fn runtimeMinutes(text: []const u8) u32 {
    var total: u32 = 0;
    var i: usize = 0;
    var any = false;
    while (i < text.len) {
        if (!std.ascii.isDigit(text[i])) {
            i += 1;
            continue;
        }
        var n: u32 = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) n = n *| 10 +| (text[i] - '0');
        while (i < text.len and text[i] == ' ') i += 1;
        const hours = i < text.len and (text[i] == 'h' or text[i] == 'H');
        total +|= if (hours) n *| 60 else n;
        any = true;
        if (!hours) break;
    }
    return if (any) total else 0;
}

/// `2008-01-21T05:00:00.000Z` -> `2008-01-21`.
pub fn dateOnly(released: []const u8) []const u8 {
    if (released.len >= 10 and released[4] == '-' and released[7] == '-') return released[0..10];
    return "";
}

fn imdbRating(v: std.json.Value) f64 {
    const f = objField(v, "imdbRating") orelse return 0;
    const x: f64 = switch (f) {
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        .float => |x| x,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
    return if (std.math.isFinite(x) and x >= 0 and x <= 10) x else 0;
}

fn httpsOrEmpty(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "https://")) s else "";
}

fn validYoutubeKey(key: []const u8) bool {
    if (key.len != 11) return false;
    for (key) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    return true;
}

/// First YouTube id from `trailers[].source` (type Trailer preferred) or
/// `trailerStreams[].ytId`. Only well-formed 11-character ids are returned.
pub fn trailerKey(meta: std.json.Value) ?[]const u8 {
    if (objField(meta, "trailers")) |t| if (t == .array) {
        for (t.array.items) |row| {
            if (std.mem.eql(u8, str(row, "type"), "Trailer") and validYoutubeKey(str(row, "source"))) return str(row, "source");
        }
        for (t.array.items) |row| {
            if (validYoutubeKey(str(row, "source"))) return str(row, "source");
        }
    };
    if (objField(meta, "trailerStreams")) |t| if (t == .array) {
        for (t.array.items) |row| if (validYoutubeKey(str(row, "ytId"))) return str(row, "ytId");
    };
    return null;
}

/// Parse a Cinemeta response and return its `meta` object.
pub fn metaObject(doc: std.json.Value) ?std.json.Value {
    const m = objField(doc, "meta") orelse return null;
    return if (m == .object) m else null;
}

pub const WriteError = std.Io.Writer.Error || error{InvalidMeta};

fn writeStringList(s: *std.json.Stringify, meta: std.json.Value, key: []const u8, comptime shape: enum { genre, cast, director }) !void {
    const f = objField(meta, key);
    var n: usize = 0;
    if (f) |arr| if (arr == .array) {
        for (arr.array.items) |item| {
            if (item != .string or item.string.len == 0) continue;
            if (n >= 40) break;
            switch (shape) {
                .genre => {
                    try s.beginObject();
                    try s.objectField("id");
                    try s.write(0);
                    try s.objectField("name");
                    try s.write(item.string);
                    try s.endObject();
                },
                .cast => {
                    try s.beginObject();
                    try s.objectField("name");
                    try s.write(item.string);
                    try s.objectField("character");
                    try s.write("");
                    try s.endObject();
                },
                .director => {
                    try s.beginObject();
                    try s.objectField("name");
                    try s.write(item.string);
                    try s.objectField("job");
                    try s.write("Director");
                    try s.endObject();
                },
            }
            n += 1;
        }
    };
}

const SeasonRow = struct { season: i64, count: i64, first_aired: []const u8 };

/// Group `videos` into per-season summaries (episode_count is the highest
/// episode number, as the web's Cinemeta fallback already computes it).
fn collectSeasons(meta: std.json.Value, out: []SeasonRow) usize {
    var n: usize = 0;
    const videos = objField(meta, "videos") orelse return 0;
    if (videos != .array) return 0;
    for (videos.array.items) |v| {
        const season = intField(v, "season") orelse continue;
        const ep = intField(v, "episode") orelse intField(v, "number") orelse continue;
        if (season < 0 or season > 999 or ep < 0) continue;
        const aired = dateOnly(if (str(v, "released").len > 0) str(v, "released") else str(v, "firstAired"));
        var found: ?*SeasonRow = null;
        for (out[0..n]) |*row| if (row.season == season) {
            found = row;
            break;
        };
        if (found == null) {
            if (n >= out.len) continue;
            out[n] = .{ .season = season, .count = 0, .first_aired = "" };
            found = &out[n];
            n += 1;
        }
        const row = found.?;
        row.count = @max(row.count, ep);
        if (aired.len > 0 and (row.first_aired.len == 0 or std.mem.order(u8, aired, row.first_aired) == .lt)) row.first_aired = aired;
    }
    std.mem.sort(SeasonRow, out[0..n], {}, struct {
        fn lt(_: void, a: SeasonRow, b: SeasonRow) bool {
            return a.season < b.season;
        }
    }.lt);
    return n;
}

/// The TMDB-shaped title document: `/3/movie/{id}` or `/3/tv/{id}` with the
/// same field names the web companion reads, plus `imdb_id`, `poster`,
/// `backdrop` and `keyless`. `id` is the catalog id the caller asked about.
pub fn writeTitle(w: *std.Io.Writer, allocator: std.mem.Allocator, body: []const u8, kind: Kind, id: i32) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidMeta;
    defer parsed.deinit();
    const meta = metaObject(parsed.value) orelse return error.InvalidMeta;
    const name = str(meta, "name");
    if (name.len == 0) return error.InvalidMeta;
    const date = dateOnly(str(meta, "released"));
    const year = str(meta, "year");
    const runtime = runtimeMinutes(str(meta, "runtime"));

    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("id");
    try s.write(id);
    try s.objectField("imdb_id");
    try s.write(str(meta, "imdb_id"));
    try s.objectField(if (kind == .movie) "title" else "name");
    try s.write(name);
    try s.objectField("overview");
    try s.write(str(meta, "description"));
    try s.objectField(if (kind == .movie) "release_date" else "first_air_date");
    try s.write(if (date.len > 0) date else (if (year.len >= 4) year[0..4] else ""));
    try s.objectField("year");
    try s.write(year);
    try s.objectField("vote_average");
    try s.write(imdbRating(meta));
    try s.objectField("status");
    try s.write(str(meta, "status"));
    try s.objectField("poster");
    try s.write(httpsOrEmpty(str(meta, "poster")));
    try s.objectField("backdrop");
    try s.write(httpsOrEmpty(str(meta, "background")));
    try s.objectField("logo");
    try s.write(httpsOrEmpty(str(meta, "logo")));
    try s.objectField("genres");
    try s.beginArray();
    try writeStringList(&s, meta, if (objField(meta, "genres") != null) "genres" else "genre", .genre);
    try s.endArray();

    if (kind == .movie) {
        try s.objectField("runtime");
        try s.write(runtime);
    } else {
        try s.objectField("episode_run_time");
        try s.beginArray();
        if (runtime > 0) try s.write(runtime);
        try s.endArray();
        var rows: [100]SeasonRow = undefined;
        const n = collectSeasons(meta, &rows);
        try s.objectField("number_of_seasons");
        var real: usize = 0;
        for (rows[0..n]) |r| if (r.season >= 1) {
            real += 1;
        };
        try s.write(real);
        try s.objectField("seasons");
        try s.beginArray();
        for (rows[0..n]) |r| {
            try s.beginObject();
            try s.objectField("season_number");
            try s.write(r.season);
            try s.objectField("name");
            if (r.season == 0) try s.write("Specials") else {
                var nb: [24]u8 = undefined;
                try s.write(std.fmt.bufPrint(&nb, "Season {d}", .{r.season}) catch "Season");
            }
            try s.objectField("episode_count");
            try s.write(r.count);
            try s.objectField("air_date");
            try s.write(r.first_aired);
            try s.endObject();
        }
        try s.endArray();
    }

    try s.objectField("credits");
    try s.beginObject();
    try s.objectField("cast");
    try s.beginArray();
    try writeStringList(&s, meta, "cast", .cast);
    try s.endArray();
    try s.objectField("crew");
    try s.beginArray();
    try writeStringList(&s, meta, "director", .director);
    try s.endArray();
    try s.endObject();

    try s.objectField("videos");
    try s.beginObject();
    try s.objectField("results");
    try s.beginArray();
    if (trailerKey(meta)) |key| {
        try s.beginObject();
        try s.objectField("site");
        try s.write("YouTube");
        try s.objectField("type");
        try s.write("Trailer");
        try s.objectField("official");
        try s.write(true);
        try s.objectField("key");
        try s.write(key);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    try s.objectField("keyless");
    try s.write(true);
    try s.endObject();
}

const EpisodeRow = struct { number: i64, v: std.json.Value };

/// `/3/tv/{id}/season/{n}`: the episodes of one season, ordered by number, with
/// air dates and thumbnails from Cinemeta's `videos`.
pub fn writeSeason(w: *std.Io.Writer, allocator: std.mem.Allocator, body: []const u8, season: i32) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidMeta;
    defer parsed.deinit();
    const meta = metaObject(parsed.value) orelse return error.InvalidMeta;
    const videos = objField(meta, "videos") orelse return error.InvalidMeta;
    if (videos != .array) return error.InvalidMeta;

    var rows: std.ArrayList(EpisodeRow) = .empty;
    defer rows.deinit(allocator);
    for (videos.array.items) |v| {
        const sn = intField(v, "season") orelse continue;
        if (sn != season) continue;
        const ep = intField(v, "episode") orelse intField(v, "number") orelse continue;
        if (ep < 0 or rows.items.len >= 1000) continue;
        rows.append(allocator, .{ .number = ep, .v = v }) catch return error.InvalidMeta;
    }
    std.mem.sort(EpisodeRow, rows.items, {}, struct {
        fn lt(_: void, a: EpisodeRow, b: EpisodeRow) bool {
            return a.number < b.number;
        }
    }.lt);

    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("season_number");
    try s.write(season);
    try s.objectField("episodes");
    try s.beginArray();
    for (rows.items) |r| {
        const v = r.v;
        const title = if (str(v, "name").len > 0) str(v, "name") else str(v, "title");
        const overview = if (str(v, "overview").len > 0) str(v, "overview") else str(v, "description");
        const aired = dateOnly(if (str(v, "released").len > 0) str(v, "released") else str(v, "firstAired"));
        try s.beginObject();
        try s.objectField("episode_number");
        try s.write(r.number);
        try s.objectField("season_number");
        try s.write(season);
        try s.objectField("name");
        if (title.len > 0) try s.write(title) else {
            var nb: [24]u8 = undefined;
            try s.write(std.fmt.bufPrint(&nb, "Episode {d}", .{r.number}) catch "Episode");
        }
        try s.objectField("overview");
        try s.write(overview);
        try s.objectField("air_date");
        try s.write(aired);
        try s.objectField("still");
        try s.write(httpsOrEmpty(str(v, "thumbnail")));
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("keyless");
    try s.write(true);
    try s.endObject();
}

// ── Tests ──────────────────────────────────────────────────────────────────

const series_fixture =
    \\{"meta":{"imdb_id":"tt0903747","name":"Breaking Bad","type":"series","description":"A \"chemistry\" teacher.",
    \\"genres":["Crime","Drama"],"cast":["Bryan Cranston","Aaron Paul"],"director":null,"imdbRating":"9.5",
    \\"released":"2008-01-20T00:00:00.000Z","runtime":"49 min","status":"Ended","year":"2008–2013",
    \\"poster":"https://images.metahub.space/poster/small/tt0903747/img","background":"http://insecure/x.jpg",
    \\"trailers":[{"source":"VFkjBy2b50Q","type":"Trailer"}],
    \\"videos":[
    \\{"name":"Pilot","season":1,"number":1,"episode":1,"released":"2008-01-21T05:00:00.000Z","overview":"First.","thumbnail":"https://episodes.metahub.space/tt0903747/1/1/w780.jpg"},
    \\{"name":"Cat's","season":1,"episode":2,"released":"2008-01-27T05:00:00.000Z","description":"Second."},
    \\{"title":"Special","season":0,"episode":1},
    \\{"name":"Seven","season":2,"episode":7,"released":"2009-05-03T05:00:00.000Z"},
    \\{"name":"Bad row","season":"x"}]}}
;

test "series title is TMDB shaped with seasons, credits and trailer" {
    const a = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try writeTitle(&aw.writer, a, series_fixture, .series, 1396);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, aw.written(), .{});
    defer parsed.deinit();
    const d = parsed.value;
    try std.testing.expectEqual(@as(i64, 1396), d.object.get("id").?.integer);
    try std.testing.expectEqualStrings("Breaking Bad", d.object.get("name").?.string);
    try std.testing.expectEqualStrings("2008-01-20", d.object.get("first_air_date").?.string);
    try std.testing.expectEqual(@as(f64, 9.5), d.object.get("vote_average").?.float);
    try std.testing.expectEqualStrings("Crime", d.object.get("genres").?.array.items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), d.object.get("number_of_seasons").?.integer);
    const seasons = d.object.get("seasons").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), seasons.len);
    try std.testing.expectEqual(@as(i64, 0), seasons[0].object.get("season_number").?.integer);
    try std.testing.expectEqual(@as(i64, 2), seasons[1].object.get("episode_count").?.integer);
    try std.testing.expectEqualStrings("2008-01-21", seasons[1].object.get("air_date").?.string);
    try std.testing.expectEqual(@as(i64, 7), seasons[2].object.get("episode_count").?.integer);
    try std.testing.expectEqualStrings("Bryan Cranston", d.object.get("credits").?.object.get("cast").?.array.items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 0), d.object.get("credits").?.object.get("crew").?.array.items.len);
    try std.testing.expectEqualStrings("VFkjBy2b50Q", d.object.get("videos").?.object.get("results").?.array.items[0].object.get("key").?.string);
    // Non-HTTPS artwork is dropped rather than handed to the browser.
    try std.testing.expectEqualStrings("", d.object.get("backdrop").?.string);
    try std.testing.expectEqualStrings("A \"chemistry\" teacher.", d.object.get("overview").?.string);
    try std.testing.expect(d.object.get("keyless").?.bool);
}

test "season document orders episodes and carries air date and still" {
    const a = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try writeSeason(&aw.writer, a, series_fixture, 1);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, aw.written(), .{});
    defer parsed.deinit();
    const eps = parsed.value.object.get("episodes").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), eps.len);
    try std.testing.expectEqual(@as(i64, 1), eps[0].object.get("episode_number").?.integer);
    try std.testing.expectEqualStrings("Pilot", eps[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("2008-01-21", eps[0].object.get("air_date").?.string);
    try std.testing.expect(std.mem.endsWith(u8, eps[0].object.get("still").?.string, "w780.jpg"));
    try std.testing.expectEqualStrings("Second.", eps[1].object.get("overview").?.string);
    try std.testing.expectEqualStrings("", eps[1].object.get("still").?.string);

    var empty: std.Io.Writer.Allocating = .init(a);
    defer empty.deinit();
    try writeSeason(&empty.writer, a, series_fixture, 9);
    try std.testing.expect(std.mem.indexOf(u8, empty.written(), "\"episodes\":[]") != null);
}

test "movie title uses movie field names, runtime minutes and director crew" {
    const body =
        \\{"meta":{"imdb_id":"tt29355505","name":"Toy Story 5","description":"Toys.","genre":["Animation"],"genres":["Animation","Comedy"],
        \\"director":["A B"],"cast":["Tom Hanks"],"imdbRating":"7.4","released":"2026-06-19T00:00:00.000Z","runtime":"1h 42min","year":"2026",
        \\"trailerStreams":[{"title":"x","ytId":"QftAW9TTmuQ"}]}}
    ;
    const a = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try writeTitle(&aw.writer, a, body, .movie, 1084244);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, aw.written(), .{});
    defer parsed.deinit();
    const d = parsed.value;
    try std.testing.expectEqualStrings("Toy Story 5", d.object.get("title").?.string);
    try std.testing.expect(d.object.get("name") == null);
    try std.testing.expectEqualStrings("2026-06-19", d.object.get("release_date").?.string);
    try std.testing.expectEqual(@as(i64, 102), d.object.get("runtime").?.integer);
    try std.testing.expectEqualStrings("Director", d.object.get("credits").?.object.get("crew").?.array.items[0].object.get("job").?.string);
    try std.testing.expectEqualStrings("QftAW9TTmuQ", d.object.get("videos").?.object.get("results").?.array.items[0].object.get("key").?.string);
    try std.testing.expect(d.object.get("seasons") == null);
}

test "malformed or nameless meta is rejected, not rendered as an empty page" {
    const a = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.testing.expectError(error.InvalidMeta, writeTitle(&aw.writer, a, "{\"meta\":{}}", .movie, 1));
    try std.testing.expectError(error.InvalidMeta, writeTitle(&aw.writer, a, "not json", .movie, 1));
    try std.testing.expectError(error.InvalidMeta, writeTitle(&aw.writer, a, "{\"metas\":[]}", .movie, 1));
    try std.testing.expectError(error.InvalidMeta, writeSeason(&aw.writer, a, "{\"meta\":{\"name\":\"x\"}}", 1));
}

test "runtime strings" {
    try std.testing.expectEqual(@as(u32, 49), runtimeMinutes("49 min"));
    try std.testing.expectEqual(@as(u32, 150), runtimeMinutes("2h 30min"));
    try std.testing.expectEqual(@as(u32, 120), runtimeMinutes("2h"));
    try std.testing.expectEqual(@as(u32, 0), runtimeMinutes(""));
    try std.testing.expectEqual(@as(u32, 0), runtimeMinutes("n/a"));
}

test "trailer keys must be well formed YouTube ids" {
    const a = std.testing.allocator;
    var p = try std.json.parseFromSlice(std.json.Value, a, "{\"trailers\":[{\"source\":\"bad id!\",\"type\":\"Trailer\"},{\"source\":\"aaaaaaaaaaa\",\"type\":\"Teaser\"}]}", .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("aaaaaaaaaaa", trailerKey(p.value).?);
    var q = try std.json.parseFromSlice(std.json.Value, a, "{\"trailers\":[{\"source\":\"nope\"}],\"trailerStreams\":[]}", .{});
    defer q.deinit();
    try std.testing.expect(trailerKey(q.value) == null);
}

test "category mapping is honest: genre uses top or imdbRating, never year" {
    try std.testing.expectEqual(Catalog.top, catalogFor(.trending, false, false));
    try std.testing.expectEqual(Catalog.top, catalogFor(.popular, false, false));
    try std.testing.expectEqual(Catalog.imdbRating, catalogFor(.top_rated, false, false));
    try std.testing.expectEqual(Catalog.imdbRating, catalogFor(.top_rated, true, false));
    try std.testing.expectEqual(Catalog.year, catalogFor(.now_playing, false, false));
    try std.testing.expectEqual(Catalog.top, catalogFor(.now_playing, true, false));
    try std.testing.expectEqual(Catalog.top, catalogFor(.top_rated, false, true));
    try std.testing.expectEqual(Category.top_rated, effectiveCategory(.trending, true, 1));
    try std.testing.expectEqual(Category.trending, effectiveCategory(.top_rated, true, 0));
    try std.testing.expectEqual(Category.top_rated, effectiveCategory(.top_rated, false, 0));
    try std.testing.expectEqual(Category.trending, foldKeylessCategory(.popular));
    try std.testing.expectEqual(Category.now_playing, foldKeylessCategory(.upcoming));
    try std.testing.expect(genreSupported("Sci-Fi"));
    try std.testing.expect(!genreSupported("Music"));
    try std.testing.expect(!genreSupported("All genres"));
}

test "identity table remembers, updates in place and evicts oldest" {
    var t: IdentityTable = .{};
    var buf: [16]u8 = undefined;
    t.record(42, "tt0000042");
    try std.testing.expectEqualStrings("tt0000042", t.lookup(42, &buf));
    t.record(42, "tt0000043");
    try std.testing.expectEqualStrings("tt0000043", t.lookup(42, &buf));
    try std.testing.expectEqual(@as(usize, 1), t.next);
    try std.testing.expectEqualStrings("", t.lookup(7, &buf));
    t.record(9, "not-imdb");
    try std.testing.expectEqualStrings("", t.lookup(9, &buf));
    for (1..IdentityTable.CAP + 1) |i| t.record(@intCast(1000 + i), "tt1234567");
    try std.testing.expectEqualStrings("", t.lookup(42, &buf));
    try std.testing.expectEqualStrings("tt1234567", t.lookup(1000 + IdentityTable.CAP, &buf));
}
