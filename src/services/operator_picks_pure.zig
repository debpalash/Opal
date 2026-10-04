//! picks (pure part): "Picked for you". The context is a compact, consent-based
//! summary of the user's taste (titles only, never paths); the agent answers
//! with recommendations; and the app NEVER trusts a title: every recommendation
//! must resolve to a real catalog entry (exact title, kind and a year within one)
//! or it is dropped. This file holds the validation, the normalisation used to
//! compare titles, the Cinemeta search parsing, the matching and the taste
//! context builder, so all of it is unit tested without a network.

const std = @import("std");
const names = @import("operator_names_pure.zig");

pub const MAX_PICKS = 12;
pub const TITLE_MAX = 100;
pub const REASON_MAX = 100;
pub const CONTEXT_MAX = 3000;
/// How many catalog rows per search are considered (Cinemeta answers with up to 100).
pub const MAX_CANDIDATES = 24;

pub const Media = enum {
    movie,
    tv,

    pub fn id(self: Media) []const u8 {
        return @tagName(self);
    }

    /// Cinemeta's name for the kind in catalog paths.
    pub fn catalogType(self: Media) []const u8 {
        return if (self == .tv) "series" else "movie";
    }
};

// ── Titles ──────────────────────────────────────────────────────────────

/// A title for display and for a catalog search. Apostrophes and quotes are fine
/// ("Schindler's List"); control characters, angle brackets and backslashes are not.
pub fn validTitle(t: []const u8) bool {
    if (t.len < 2 or t.len > TITLE_MAX) return false;
    if (!std.unicode.utf8ValidateSlice(t)) return false;
    var letters: usize = 0;
    for (t) |c| {
        if (c < 0x20 or c == 0x7f) return false;
        if (c == '<' or c == '>' or c == '\\') return false;
        if (std.ascii.isAlphanumeric(c) or c >= 0x80) letters += 1;
    }
    return letters >= 2;
}

/// Comparison form of a title: lower case ASCII letters and digits, `&` read as
/// "and", every other ASCII punctuation mark dropped (so "Schindler's List" equals
/// "Schindlers List" and "Spider-Man" equals "Spider Man" only through the space rule
/// below), runs of whitespace and dashes become one space, non-ASCII bytes kept.
pub fn normTitle(out: []u8, title: []const u8) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    var i: usize = 0;
    while (i < title.len) : (i += 1) {
        const ch = title[i];
        if (ch == ' ' or ch == '\t' or ch == '-' or ch == '_' or ch == ':' or ch == '.') {
            pending_space = n > 0;
            continue;
        }
        var emit: []const u8 = &.{};
        var one: [1]u8 = undefined;
        if (ch == '&') {
            emit = "and";
        } else if (std.ascii.isAlphanumeric(ch)) {
            one[0] = std.ascii.toLower(ch);
            emit = one[0..1];
        } else if (ch >= 0x80) {
            one[0] = ch;
            emit = one[0..1];
        } else continue; // other punctuation and control characters vanish
        if (pending_space) {
            if (n >= out.len) break;
            out[n] = ' ';
            n += 1;
            pending_space = false;
        }
        if (n + emit.len > out.len) break;
        @memcpy(out[n..][0..emit.len], emit);
        n += emit.len;
    }
    return out[0..n];
}

pub const NORM_MAX = 128;

pub fn sameTitle(a: []const u8, b: []const u8) bool {
    var x: [NORM_MAX]u8 = undefined;
    var y: [NORM_MAX]u8 = undefined;
    const na = normTitle(&x, a);
    const nb = normTitle(&y, b);
    return na.len > 0 and std.mem.eql(u8, na, nb);
}

// ── The agent's recommendations ─────────────────────────────────────────

pub const Pick = struct {
    title: [TITLE_MAX]u8 = undefined,
    title_len: u8 = 0,
    /// 0 when the agent gave none (or one outside 1888..2100).
    year: u16 = 0,
    kind: Media = .movie,
    reason: [REASON_MAX]u8 = undefined,
    reason_len: u8 = 0,

    pub fn titleText(self: *const Pick) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn reasonText(self: *const Pick) []const u8 {
        return self.reason[0..self.reason_len];
    }
};

pub const Picks = struct {
    items: [MAX_PICKS]Pick = undefined,
    count: usize = 0,
};

/// Copy `src` into `dst`: control characters become spaces, runs of spaces
/// collapse, cut at `dst.len` on a UTF-8 boundary. Returns the length.
pub fn cleanText(dst: []u8, src: []const u8) usize {
    var n: usize = 0;
    var prev_space = true;
    for (src) |c| {
        const ch: u8 = if (c < 0x20 or c == 0x7f) ' ' else c;
        if (ch == ' ') {
            if (prev_space) continue;
            prev_space = true;
        } else prev_space = false;
        if (n >= dst.len) break;
        dst[n] = ch;
        n += 1;
    }
    while (n > 0 and dst[n - 1] == ' ') n -= 1;
    // Never end inside a multibyte sequence.
    while (n > 0 and !std.unicode.utf8ValidateSlice(dst[0..n])) n -= 1;
    return n;
}

pub fn parsePicks(allocator: std.mem.Allocator, json: []const u8) ?Picks {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const list = parsed.value.object.get("items") orelse return null;
    if (list != .array) return null;
    var out = Picks{};
    for (list.array.items) |entry| {
        if (out.count >= MAX_PICKS) break;
        if (entry != .object) continue;
        const obj = entry.object;
        const title_v = obj.get("title") orelse continue;
        if (title_v != .string) continue;
        const title = std.mem.trim(u8, title_v.string, " \t");
        if (!validTitle(title)) continue;
        const kind_v = obj.get("kind") orelse continue;
        if (kind_v != .string) continue;
        const kind = std.meta.stringToEnum(Media, kind_v.string) orelse continue;
        const reason_v = obj.get("reason") orelse continue;
        if (reason_v != .string) continue;
        var pick = Pick{ .kind = kind };
        pick.reason_len = @intCast(cleanText(&pick.reason, reason_v.string));
        // A recommendation that cannot say why is not shown: the reason is the point.
        if (pick.reason_len == 0) continue;
        if (obj.get("year")) |y| if (y == .integer and y.integer >= 1888 and y.integer <= 2100) {
            pick.year = @intCast(y.integer);
        };
        var dup = false;
        for (out.items[0..out.count]) |*other| {
            if (other.kind == kind and sameTitle(other.titleText(), title)) dup = true;
        }
        if (dup) continue;
        @memcpy(pick.title[0..title.len], title);
        pick.title_len = @intCast(title.len);
        out.items[out.count] = pick;
        out.count += 1;
    }
    return if (out.count == 0) null else out;
}

// ── Catalog candidates (Cinemeta search JSON) ───────────────────────────

pub const Candidate = struct {
    imdb: [16]u8 = undefined,
    imdb_len: u8 = 0,
    title: [128]u8 = undefined,
    title_len: u8 = 0,
    year: u16 = 0,
    kind: Media = .movie,
    poster: [256]u8 = undefined,
    poster_len: u16 = 0,
    rating: f32 = 0,
    overview: [512]u8 = undefined,
    overview_len: u16 = 0,

    pub fn imdbText(self: *const Candidate) []const u8 {
        return self.imdb[0..self.imdb_len];
    }

    pub fn titleText(self: *const Candidate) []const u8 {
        return self.title[0..self.title_len];
    }
};

fn validImdb(v: []const u8) bool {
    if (v.len < 4 or v.len > 15 or !std.mem.startsWith(u8, v, "tt")) return false;
    for (v[2..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// First four-digit year in `s` ("2010", "2010–2015", "2019-").
fn leadingYear(s: []const u8) u16 {
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 1) {
        if (!std.ascii.isDigit(s[i])) continue;
        const y = std.fmt.parseInt(u16, s[i .. i + 4], 10) catch continue;
        if (y >= 1888 and y <= 2100) return y;
    }
    return 0;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Read up to `out.len` catalog rows from `{"metas":[...]}`. Rows without a valid
/// IMDb id or a name are skipped. Returns how many were written.
pub fn parseCandidates(allocator: std.mem.Allocator, body: []const u8, kind: Media, out: []Candidate) usize {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const metas = parsed.value.object.get("metas") orelse return 0;
    if (metas != .array) return 0;
    var n: usize = 0;
    for (metas.array.items) |m| {
        if (n >= out.len) break;
        if (m != .object) continue;
        const obj = m.object;
        const id = stringField(obj, "imdb_id") orelse stringField(obj, "id") orelse continue;
        if (!validImdb(id)) continue;
        const name = stringField(obj, "name") orelse continue;
        if (name.len == 0 or name.len > 128 or !std.unicode.utf8ValidateSlice(name)) continue;
        var c = Candidate{ .kind = kind };
        @memcpy(c.imdb[0..id.len], id);
        c.imdb_len = @intCast(id.len);
        @memcpy(c.title[0..name.len], name);
        c.title_len = @intCast(name.len);
        c.year = leadingYear(stringField(obj, "year") orelse stringField(obj, "releaseInfo") orelse "");
        if (c.year == 0) c.year = leadingYear(stringField(obj, "released") orelse "");
        if (stringField(obj, "poster")) |p| {
            if (p.len > 0 and p.len + 4 <= c.poster.len and (std.mem.startsWith(u8, p, "https://") or std.mem.startsWith(u8, p, "http://"))) {
                const host = "https://images.metahub.space/";
                const jpg = std.mem.startsWith(u8, p, host) and std.mem.endsWith(u8, p, "/img");
                @memcpy(c.poster[0..p.len], p);
                var len = p.len;
                if (jpg) {
                    @memcpy(c.poster[len..][0..4], ".jpg");
                    len += 4;
                }
                c.poster_len = @intCast(len);
            }
        }
        if (stringField(obj, "imdbRating")) |r| c.rating = std.fmt.parseFloat(f32, r) catch 0;
        if (stringField(obj, "description")) |d| {
            const keep = @min(d.len, c.overview.len);
            c.overview_len = @intCast(cleanText(c.overview[0..keep], d[0..keep]));
        }
        out[n] = c;
        n += 1;
    }
    return n;
}

/// Index of the catalog row that really is `pick`: same kind, same title once
/// normalised, and (when the agent named a year) a catalog year within one of it.
/// The first such row wins (Cinemeta lists by popularity). Null means the
/// recommendation is dropped.
pub fn resolve(pick: *const Pick, candidates: []const Candidate) ?usize {
    for (candidates, 0..) |*c, i| {
        if (c.kind != pick.kind) continue;
        if (!sameTitle(pick.titleText(), c.titleText())) continue;
        if (pick.year != 0) {
            if (c.year == 0) continue;
            const diff = if (c.year > pick.year) c.year - pick.year else pick.year - c.year;
            if (diff > 1) continue;
        }
        return i;
    }
    return null;
}

// ── Taste context ───────────────────────────────────────────────────────

pub const Source = enum {
    watched,
    favourite,
    following,

    fn label(self: Source) []const u8 {
        return @tagName(self);
    }
};

pub const MAX_KNOWN = 96;

/// Titles the user already has, for dropping recommendations of things they know.
pub const Known = struct {
    buf: [MAX_KNOWN][NORM_MAX]u8 = undefined,
    lens: [MAX_KNOWN]u8 = undefined,
    count: usize = 0,

    pub fn add(self: *Known, title: []const u8) void {
        if (self.count >= MAX_KNOWN) return;
        const n = normTitle(&self.buf[self.count], title);
        if (n.len == 0 or self.contains(title)) return;
        self.lens[self.count] = @intCast(n.len);
        self.count += 1;
    }

    pub fn contains(self: *const Known, title: []const u8) bool {
        var y: [NORM_MAX]u8 = undefined;
        const nb = normTitle(&y, title);
        if (nb.len == 0) return false;
        for (0..self.count) |i| if (std.mem.eql(u8, self.buf[i][0..self.lens[i]], nb)) return true;
        return false;
    }
};

/// A raw history name that is a link or a hash-like id, not a title or a file name.
/// Checked before the file-name cleaner, which would otherwise keep the last path
/// segment of a URL ("watch?v=abc") as if it were a title.
pub fn rawLooksLikeLink(raw: []const u8) bool {
    if (std.mem.indexOf(u8, raw, "://") != null) return true;
    if (std.ascii.startsWithIgnoreCase(raw, "magnet:") or std.ascii.startsWithIgnoreCase(raw, "www.")) return true;
    return false;
}

/// A taste line is only ever a human title: not a file name, a path, a link or a
/// content hash. `cleaned` has been through the app's file-name cleaner already.
pub fn usableTitle(cleaned: []const u8) bool {
    const t = std.mem.trim(u8, cleaned, " \t");
    if (t.len < 2 or t.len > 80) return false;
    if (!validTitle(t)) return false;
    if (std.mem.indexOfScalar(u8, t, '/') != null or std.mem.indexOfScalar(u8, t, '=') != null) return false;
    if (std.ascii.startsWithIgnoreCase(t, "magnet:") or std.ascii.startsWithIgnoreCase(t, "http")) return false;
    // 12+ hex digits is a content hash, not a title.
    var hex_only = t.len >= 12;
    for (t) |c| if (!std.ascii.isHex(c)) {
        hex_only = false;
    };
    if (hex_only) return false;
    return !names.looksMessy(t);
}

pub const MIN_TASTE_LINES = 3;

/// Builds the data block: `watched: Title` one per line, titles only, at most
/// CONTEXT_MAX bytes, no repeats. Also records every title in `known`.
pub const Taste = struct {
    buf: [CONTEXT_MAX]u8 = undefined,
    len: usize = 0,
    lines: usize = 0,
    known: Known = .{},

    pub fn add(self: *Taste, source: Source, cleaned: []const u8) bool {
        const t = std.mem.trim(u8, cleaned, " \t");
        if (self.known.count >= MAX_KNOWN or !usableTitle(t) or self.known.contains(t)) return false;
        const line = std.fmt.bufPrint(self.buf[self.len..], "{s}: {s}\n", .{ source.label(), t }) catch return false;
        self.len += line.len;
        self.lines += 1;
        self.known.add(t);
        return true;
    }

    pub fn text(self: *const Taste) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn enough(self: *const Taste) bool {
        return self.lines >= MIN_TASTE_LINES;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

const T = std.testing;

test "titles compare by letters and digits, not punctuation or case" {
    try T.expect(sameTitle("Schindler's List", "schindlers list"));
    try T.expect(sameTitle("Spider-Man: Homecoming", "Spider Man Homecoming"));
    try T.expect(sameTitle("Fast & Furious", "Fast and Furious"));
    try T.expect(sameTitle("Blade   Runner 2049", "blade runner 2049"));
    try T.expect(!sameTitle("Dune", "Dune Part Two"));
    try T.expect(!sameTitle("The Matrix", "Matrix"));
    try T.expect(!sameTitle("", ""));
    try T.expect(!sameTitle("!!!", "???"));
    try T.expect(sameTitle("千と千尋の神隠し", "千と千尋の神隠し"));
    try T.expect(!sameTitle("千と千尋の神隠し", "もののけ姫"));
}

test "recommendations are validated, bounded and distinct" {
    const a = T.allocator;
    const p = parsePicks(a,
        \\{"items":[
        \\ {"title":"Arrival","year":2016,"kind":"movie","reason":"Cerebral sci-fi like Interstellar"},
        \\ {"title":"arrival","year":2016,"kind":"movie","reason":"dup"},
        \\ {"title":"Arrival","year":2016,"kind":"tv","reason":"other kind is not a dup"},
        \\ {"title":"<script>","year":2016,"kind":"movie","reason":"bad title"},
        \\ {"title":"No Reason","year":2016,"kind":"movie","reason":"   "},
        \\ {"title":"Bad Kind","year":2016,"kind":"anime","reason":"x"},
        \\ {"title":"Odd Year","year":99999,"kind":"movie","reason":"year outside range is ignored"},
        \\ {"title":"Tabs","year":2000,"kind":"movie","reason":"line\nbreak\tand   spaces"},
        \\ {"kind":"movie"},
        \\ 5
        \\],"junk":1}
    ).?;
    try T.expectEqual(@as(usize, 4), p.count);
    try T.expectEqualStrings("Arrival", p.items[0].titleText());
    try T.expectEqual(@as(u16, 2016), p.items[0].year);
    try T.expectEqual(Media.tv, p.items[1].kind);
    try T.expectEqual(@as(u16, 0), p.items[2].year);
    try T.expectEqualStrings("line break and spaces", p.items[3].reasonText());
    try T.expect(parsePicks(a, "{\"items\":[]}") == null);
    try T.expect(parsePicks(a, "{\"items\":\"x\"}") == null);
    try T.expect(parsePicks(a, "nope") == null);
    try T.expect(parsePicks(a, "[1]") == null);
}

test "at most twelve recommendations and reasons are clipped on a character boundary" {
    const a = T.allocator;
    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(a);
    try json.appendSlice(a, "{\"items\":[");
    for (0..15) |i| {
        if (i > 0) try json.append(a, ',');
        try json.print(a, "{{\"title\":\"Title Number {d}\",\"year\":2001,\"kind\":\"movie\",\"reason\":\"{s}\"}}", .{ i, "é" ** 70 });
    }
    try json.appendSlice(a, "]}");
    const p = parsePicks(a, json.items).?;
    try T.expectEqual(@as(usize, MAX_PICKS), p.count);
    try T.expect(p.items[0].reason_len <= REASON_MAX);
    try T.expect(std.unicode.utf8ValidateSlice(p.items[0].reasonText()));
}

// Trimmed from a live Cinemeta search (catalog/movie/top/search=arrival.json).
const fixture_movies =
    \\{"metas":[
    \\{"id":"tt2543164","imdb_id":"tt2543164","type":"movie","name":"Arrival","releaseInfo":"2016","poster":"https://images.metahub.space/poster/small/tt2543164/img","imdbRating":"7.9","description":"A linguist works with the military to communicate with alien lifeforms.","year":"2016"},
    \\{"id":"tt0000001","imdb_id":"tt0000001","type":"movie","name":"The Arrival","releaseInfo":"1996","poster":"https://m.media-amazon.com/images/M/x.jpg","imdbRating":"6.3"},
    \\{"id":"tt9999999","type":"movie","name":"Arrival","releaseInfo":"2001"},
    \\{"id":"notanid","type":"movie","name":"Arrival Broken"},
    \\{"id":"tt1234567","type":"movie","releaseInfo":"2010"}
    \\]}
;
const fixture_series =
    \\{"metas":[
    \\{"id":"tt0903747","imdb_id":"tt0903747","type":"series","name":"Breaking Bad","releaseInfo":"2008–2013","poster":"https://images.metahub.space/poster/small/tt0903747/img","imdbRating":"9.5"},
    \\{"id":"tt1111111","imdb_id":"tt1111111","type":"series","name":"Breaking Bad: El Camino Fan Series","releaseInfo":"2019-"}
    \\]}
;

test "catalog search rows are read tolerantly" {
    var rows: [MAX_CANDIDATES]Candidate = undefined;
    const n = parseCandidates(T.allocator, fixture_movies, .movie, &rows);
    try T.expectEqual(@as(usize, 3), n);
    try T.expectEqualStrings("tt2543164", rows[0].imdbText());
    try T.expectEqualStrings("Arrival", rows[0].titleText());
    try T.expectEqual(@as(u16, 2016), rows[0].year);
    try T.expectEqual(@as(f32, 7.9), rows[0].rating);
    // The extensionless metahub poster is forced to a decodable JPEG.
    try T.expectEqualStrings("https://images.metahub.space/poster/small/tt2543164/img.jpg", rows[0].poster[0..rows[0].poster_len]);
    try T.expectEqualStrings("https://m.media-amazon.com/images/M/x.jpg", rows[1].poster[0..rows[1].poster_len]);
    try T.expectEqual(@as(u16, 0), rows[2].poster_len);
    const s = parseCandidates(T.allocator, fixture_series, .tv, &rows);
    try T.expectEqual(@as(usize, 2), s);
    try T.expectEqual(@as(u16, 2008), rows[0].year);
    try T.expectEqual(@as(u16, 2019), rows[1].year);
    try T.expectEqual(@as(usize, 0), parseCandidates(T.allocator, "{}", .movie, &rows));
    try T.expectEqual(@as(usize, 0), parseCandidates(T.allocator, "html", .movie, &rows));
    var tiny: [1]Candidate = undefined;
    try T.expectEqual(@as(usize, 1), parseCandidates(T.allocator, fixture_movies, .movie, &tiny));
}

test "only an exact-ish title and year resolves; invented titles are dropped" {
    var rows: [MAX_CANDIDATES]Candidate = undefined;
    const n = parseCandidates(T.allocator, fixture_movies, .movie, &rows);
    const cands = rows[0..n];
    var p = Pick{ .kind = .movie, .year = 2016 };
    p.title_len = @intCast("Arrival".len);
    @memcpy(p.title[0.."Arrival".len], "Arrival");
    try T.expectEqual(@as(?usize, 0), resolve(&p, cands));
    // Off by one year is tolerated (festival versus release year), two is not.
    p.year = 2017;
    try T.expectEqual(@as(?usize, 0), resolve(&p, cands));
    p.year = 2018;
    try T.expectEqual(@as(?usize, null), resolve(&p, cands));
    // No year from the agent: the exact title still has to match.
    p.year = 0;
    try T.expectEqual(@as(?usize, 0), resolve(&p, cands));
    // A title the catalog does not have, however plausible, resolves to nothing.
    const fake = "Zorblax Quantum Heist";
    @memcpy(p.title[0..fake.len], fake);
    p.title_len = fake.len;
    p.year = 2031;
    try T.expectEqual(@as(?usize, null), resolve(&p, cands));
    // A near match is not a match.
    const near = "Arrival Part Two";
    @memcpy(p.title[0..near.len], near);
    p.title_len = near.len;
    p.year = 2016;
    try T.expectEqual(@as(?usize, null), resolve(&p, cands));
    // Kind must agree: a series named like a movie is not the movie.
    const same = "Arrival";
    @memcpy(p.title[0..same.len], same);
    p.title_len = same.len;
    p.kind = .tv;
    try T.expectEqual(@as(?usize, null), resolve(&p, cands));
    // The year gate also rejects a catalog row with no year when the agent gave one.
    p.kind = .movie;
    var nowhere = [_]Candidate{rows[0]};
    nowhere[0].year = 0;
    try T.expectEqual(@as(?usize, null), resolve(&p, &nowhere));
}

test "a series resolves through its start year" {
    var rows: [MAX_CANDIDATES]Candidate = undefined;
    const n = parseCandidates(T.allocator, fixture_series, .tv, &rows);
    var p = Pick{ .kind = .tv, .year = 2008 };
    @memcpy(p.title[0.."Breaking Bad".len], "Breaking Bad");
    p.title_len = "Breaking Bad".len;
    try T.expectEqual(@as(?usize, 0), resolve(&p, rows[0..n]));
}

test "the taste context holds plain titles only, once each" {
    var t = Taste{};
    try T.expect(t.add(.watched, "Arrival"));
    try T.expect(t.add(.favourite, "Blade Runner 2049"));
    try T.expect(!t.add(.following, "arrival"));
    try T.expect(t.add(.following, "Severance"));
    // File names, paths, links, hashes and release names never enter.
    try T.expect(!t.add(.watched, "8248045d177933fc"));
    try T.expect(!t.add(.watched, "/home/me/Videos/Movie.mkv"));
    try T.expect(!t.add(.watched, "https://example.org/watch"));
    try T.expect(!t.add(.watched, "watch?v=SDooWW8GCrc"));
    try T.expect(rawLooksLikeLink("https://www.youtube.com/watch?v=SDooWW8GCrc"));
    try T.expect(rawLooksLikeLink("magnet:?xt=urn:btih:abc"));
    try T.expect(rawLooksLikeLink("www.example.org/a"));
    try T.expect(!rawLooksLikeLink("Blade Runner 2049"));
    try T.expect(!rawLooksLikeLink("Movie.2019.1080p.mkv"));
    try T.expect(!t.add(.watched, "magnet:?xt=urn:btih:abc"));
    try T.expect(!t.add(.watched, "Dune Part Two 2024 1080p WEB-DL DDP5 1 x264-FLUX"));
    try T.expect(!t.add(.watched, "Reacher S01E01 1080p WEB h264-KOGi"));
    try T.expect(!t.add(.watched, "x"));
    try T.expectEqualStrings("watched: Arrival\nfavourite: Blade Runner 2049\nfollowing: Severance\n", t.text());
    try T.expect(t.enough());
    try T.expect(t.known.contains("SEVERANCE"));
    try T.expect(!t.known.contains("Dune"));
    var small = Taste{};
    _ = small.add(.watched, "Arrival");
    try T.expect(!small.enough());
}

test "the taste context never exceeds the operator's context limit" {
    var t = Taste{};
    var i: usize = 0;
    var buf: [64]u8 = undefined;
    while (i < 500) : (i += 1) {
        const title = std.fmt.bufPrint(&buf, "Some Long Fake Title Number {d} Of The Collection", .{i}) catch unreachable;
        _ = t.add(.watched, title);
    }
    try T.expect(t.len <= CONTEXT_MAX);
    try T.expect(t.known.count <= MAX_KNOWN);
}
