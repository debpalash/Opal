//! Bounded content identities projected from immutable search rows. No UI or I/O.
const std = @import("std");
pub const MAX_ROWS: usize = 192;
/// Opaque bounded cache scope includes installed endpoint/credential identity.
/// Hashing the query avoids long-prefix overflow and exposes no source URLs.
pub fn cacheIdentity(out: []u8, query: []const u8, mask: u16, fingerprint: u64) ?[]const u8 {
    return std.fmt.bufPrint(out, "search:v10:{x}:{x}:{x}", .{ mask, fingerprint, std.hash.Wyhash.hash(0, query) }) catch null;
}
pub const CacheItem = struct { source: []const u8, provider: []const u8 = "", url: []const u8 = "" };
/// Account-bound rows are fetched afresh each wave. Public metadata/cache art
/// remain useful without replaying another account's opaque item or stream ID.
pub fn cacheEligible(item: CacheItem) bool {
    inline for (.{ "jellyfin", "plex", "opds", "audiobooks", "plugin", "local" }) |private| {
        if (std.mem.eql(u8, item.source, private)) return false;
    }
    if (std.mem.eql(u8, item.source, "music") and
        !std.mem.eql(u8, item.provider, "jiosaavn") and !std.mem.eql(u8, item.provider, "audius")) return false;
    if (std.mem.eql(u8, item.source, "stremio") and
        !std.mem.eql(u8, item.provider, "archive") and !std.mem.eql(u8, item.provider, "nasa") and !std.mem.eql(u8, item.provider, "commons")) return false;
    // Deep links can contain an embedded HTTP URL. Conservatively avoid user
    // authority text even there; the original row stays in the live result set.
    if (std.mem.indexOf(u8, item.url, "://")) |scheme| {
        const start = scheme + 3;
        const end = std.mem.indexOfAnyPos(u8, item.url, start, "/?#|") orelse item.url.len;
        if (std.mem.indexOfScalar(u8, item.url[start..end], '@') != null) return false;
    }
    return true;
}
pub const Category = enum {
    movies,
    shows,
    anime,
    comics,
    books,
    music,
    podcasts,
    radio,
    live_tv,
    visual_novels,
    videos,
    releases,
    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .movies => "Movies",
            .shows => "Shows",
            .anime => "Anime",
            .comics => "Comics",
            .books => "Books",
            .music => "Music",
            .podcasts => "Podcasts",
            .radio => "Radio",
            .live_tv => "Live TV",
            .visual_novels => "Visual novels",
            .videos => "Videos",
            .releases => "Other releases",
        };
    }
};
pub const Group = struct {
    representative: usize = 0,
    indexes: [MAX_ROWS]u16 = undefined,
    count: usize = 0,
    offer_count: usize = 0,
    category: Category = .videos,
    identity: u64 = 0,
    score: u32 = 9999,
};
pub const Projection = struct { groups: [MAX_ROWS]Group = undefined, count: usize = 0 };
pub fn category(row: anytype) Category {
    const source = @tagName(row.source);
    const kind = row.catalog_kind[0..row.catalog_kind_len];
    if (std.mem.eql(u8, source, "torrent")) return .releases;
    if (std.mem.eql(u8, source, "anime")) return .anime;
    if (std.mem.eql(u8, source, "comics")) return .comics;
    if (std.mem.eql(u8, source, "novels") or std.mem.eql(u8, source, "opds") or std.mem.eql(u8, source, "audiobooks")) return .books;
    if (std.mem.eql(u8, source, "music")) return .music;
    if (std.mem.eql(u8, source, "podcast")) return .podcasts;
    if (std.mem.eql(u8, source, "radio")) return .radio;
    if (std.mem.eql(u8, source, "livetv")) return .live_tv;
    if (std.mem.eql(u8, source, "vndb")) return .visual_novels;
    if (std.mem.eql(u8, kind, "movie")) return .movies;
    if (std.mem.eql(u8, kind, "tv") or std.mem.eql(u8, kind, "series") or std.mem.eql(u8, kind, "episode")) return .shows;
    return .videos;
}
pub fn isRelease(row: anytype) bool {
    return std.mem.eql(u8, @tagName(row.source), "torrent");
}
fn title(row: anytype) []const u8 {
    return row.name[0..row.name_len];
}
fn normalized(text: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var space = false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c >= 128) {
            if (space and n > 0 and n < out.len) {
                out[n] = ' ';
                n += 1;
            }
            if (n == out.len) break;
            out[n] = std.ascii.toLower(c);
            n += 1;
            space = false;
        } else space = true;
    }
    return out[0..n];
}
/// Only a title immediately followed by a positive year is eligible. No fuzzy
/// prefix/substring matches, no inference from quality digits or episode names.
pub fn releaseMatches(work_title: []const u8, work_year: u16, release_title: []const u8) bool {
    if (work_year < 1800 or work_year > 2199) return false;
    var i: usize = 0;
    while (i + 4 <= release_title.len) : (i += 1) {
        if (i > 0 and std.ascii.isAlphanumeric(release_title[i - 1])) continue;
        const year = std.fmt.parseInt(u16, release_title[i..][0..4], 10) catch continue;
        if (year != work_year or (i + 4 < release_title.len and std.ascii.isDigit(release_title[i + 4]))) continue;
        var a: [256]u8 = undefined;
        var b: [256]u8 = undefined;
        return std.mem.eql(u8, normalized(work_title, &a), normalized(release_title[0..i], &b));
    }
    return false;
}
/// Explicit season tokens establish a show release, never a movie. The caller
/// still requires exactly one matching typed show across all visible catalogs.
pub fn episodeMatches(work_title: []const u8, release_title: []const u8) bool {
    var i: usize = 1;
    while (i + 3 <= release_title.len) : (i += 1) {
        if (std.ascii.toLower(release_title[i]) != 's' or std.ascii.isAlphanumeric(release_title[i - 1])) continue;
        if (!std.ascii.isDigit(release_title[i + 1]) or !std.ascii.isDigit(release_title[i + 2])) continue;
        const end = i + 3;
        if (end < release_title.len and std.ascii.isAlphanumeric(release_title[end])) {
            if (std.ascii.toLower(release_title[end]) != 'e' or end + 2 >= release_title.len or !std.ascii.isDigit(release_title[end + 1]) or !std.ascii.isDigit(release_title[end + 2])) continue;
        }
        var a: [256]u8 = undefined;
        var b: [256]u8 = undefined;
        return std.mem.eql(u8, normalized(work_title, &a), normalized(release_title[0..i], &b));
    }
    return false;
}
fn imdb(row: anytype) []const u8 {
    return row.catalog_imdb[0..row.catalog_imdb_len];
}
fn validImdb(text: []const u8) bool {
    if (text.len < 3 or !std.mem.startsWith(u8, text, "tt")) return false;
    for (text[2..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
pub fn identity(row: anytype) u64 {
    var h = std.hash.Wyhash.init(0);
    const typed_imdb = imdb(&row);
    if (validImdb(typed_imdb) and row.catalog_kind_len > 0) {
        h.update("imdb");
        h.update(row.catalog_kind[0..row.catalog_kind_len]);
        h.update(typed_imdb);
        const key = h.final();
        return if (key == 0) 1 else key;
    }
    h.update(@tagName(row.source));
    h.update(row.catalog_kind[0..row.catalog_kind_len]);
    if (row.catalog_id > 0) {
        h.update(std.mem.asBytes(&row.catalog_id));
    } else {
        h.update(row.url[0..row.url_len]);
    }
    const value = h.final();
    return if (value == 0) 1 else value;
}
fn sameWork(a: anytype, b: anytype) bool {
    const same_kind = a.catalog_kind_len > 0 and std.mem.eql(u8, a.catalog_kind[0..a.catalog_kind_len], b.catalog_kind[0..b.catalog_kind_len]);
    return same_kind and ((a.catalog_id > 0 and b.catalog_id == a.catalog_id and a.source == b.source) or (validImdb(imdb(&a)) and std.mem.eql(u8, imdb(&a), imdb(&b))));
}
fn isOffer(row: anytype) bool {
    const source = @tagName(row.source);
    inline for (.{ "tmdb", "vndb" }) |catalog| if (std.mem.eql(u8, source, catalog)) return false;
    if (std.mem.eql(u8, source, "anime")) {
        if (@hasField(@TypeOf(row), "provider")) {
            const provider = row.provider.name();
            if (std.mem.eql(u8, provider, "jikan") or std.mem.eql(u8, provider, "anilist")) return false;
        }
    }
    if (@hasField(@TypeOf(row), "opds_entry")) {
        if (std.mem.eql(u8, source, "opds") and row.opds_entry.is_navigation) return false;
    }
    return row.url_len > 0;
}
fn hasSameOffer(rows: anytype, group: *const Group, row: anytype) bool {
    for (group.indexes[0..group.count]) |index| {
        const previous = rows[index];
        if (!isOffer(previous) or previous.source != row.source) continue;
        if (std.mem.eql(u8, previous.url[0..previous.url_len], row.url[0..row.url_len])) return true;
    }
    return false;
}
fn append(group: *Group, index: usize, offer: bool) void {
    if (group.count >= MAX_ROWS) return;
    group.indexes[group.count] = @intCast(index);
    group.count += 1;
    if (offer) group.offer_count += 1;
}
/// Caller owns the output (static or heap); indexes refer to the original rows,
/// including after faceting. Ambiguous matches stay independent and actionable.
pub fn projectInto(rows: anytype, indices: []const usize, out: *Projection) void {
    out.count = 0;
    for (indices) |index| {
        if (index >= rows.len or index >= MAX_ROWS or isRelease(rows[index])) continue;
        var found: ?usize = null;
        for (out.groups[0..out.count], 0..) |group, g| if (sameWork(rows[group.representative], rows[index]) or identity(rows[group.representative]) == identity(rows[index])) {
            found = g;
            break;
        };
        if (found) |g| {
            append(&out.groups[g], index, isOffer(rows[index]) and !hasSameOffer(rows, &out.groups[g], rows[index]));
            if (std.mem.eql(u8, @tagName(rows[index].source), "tmdb")) {
                out.groups[g].representative = index;
                out.groups[g].category = category(rows[index]);
            }
            continue;
        }
        if (out.count == MAX_ROWS) break;
        out.groups[out.count] = .{ .representative = index, .category = category(rows[index]), .identity = identity(rows[index]), .score = 100 - @as(u32, rows[index].match_pct) };
        append(&out.groups[out.count], index, isOffer(rows[index]));
        out.count += 1;
    }
    for (indices) |index| {
        if (index >= rows.len or index >= MAX_ROWS or !isRelease(rows[index])) continue;
        var match: ?usize = null;
        var matches: usize = 0;
        for (out.groups[0..out.count], 0..) |group, g| {
            const work = rows[group.representative];
            if ((group.category == .movies or group.category == .shows) and (releaseMatches(title(&work), work.year, rows[index].name[0..rows[index].name_len]) or (group.category == .shows and episodeMatches(title(&work), rows[index].name[0..rows[index].name_len])))) {
                match = g;
                matches += 1;
            }
        }
        // Hidden facets cannot turn a known remake ambiguity into a verified
        // association. Evaluate candidate identities against the entire snapshot.
        if (matches == 1) {
            const linked = rows[out.groups[match.?].representative];
            for (rows) |other| {
                if (isRelease(other) or identity(other) == identity(linked)) continue;
                const other_cat = category(other);
                if ((other_cat == .movies or other_cat == .shows) and
                    (releaseMatches(other.name[0..other.name_len], other.year, rows[index].name[0..rows[index].name_len]) or
                        (other_cat == .shows and episodeMatches(other.name[0..other.name_len], rows[index].name[0..rows[index].name_len]))))
                {
                    matches += 1;
                    break;
                }
            }
        }
        if (matches == 1) {
            append(&out.groups[match.?], index, true);
            continue;
        }
        if (out.count == MAX_ROWS) break;
        out.groups[out.count] = .{ .representative = index, .category = .releases, .identity = identity(rows[index]), .score = 200 + 100 - @as(u32, rows[index].match_pct) };
        append(&out.groups[out.count], index, true);
        out.count += 1;
    }
    std.sort.insertion(Group, out.groups[0..out.count], {}, struct {
        fn less(_: void, a: Group, b: Group) bool {
            return a.score < b.score or (a.score == b.score and a.identity < b.identity);
        }
    }.less);
}
/// Fair bounded admission reserves eight rows per represented category. A late
/// category can reclaim an overrepresented category's worst row regardless of
/// swarm score. Within a category relevance still selects its strongest rows.
pub fn evictionIndex(rows: anytype, candidate: anytype) ?usize {
    if (rows.len == 0) return null;
    var counts: [@typeInfo(Category).@"enum".fields.len]usize = @splat(0);
    for (rows) |row| counts[@intFromEnum(category(row))] += 1;
    const cat = category(candidate);
    const under = counts[@intFromEnum(cat)] < 8;
    var selected: ?usize = null;
    for (rows, 0..) |row, i| {
        const row_cat = category(row);
        if (under) {
            if (counts[@intFromEnum(row_cat)] <= 8) continue;
        } else if (row_cat != cat) continue;
        if (selected == null or row.score > rows[selected.?].score) selected = i;
    }
    if (selected) |i| {
        if (under or candidate.score < rows[i].score or (candidate.score == rows[i].score and identity(candidate) < identity(rows[i]))) return i;
    }
    return null;
}
test "strict work release linking preserves title year and rejects ambiguity" {
    try std.testing.expect(releaseMatches("Reacher", 2022, "Reacher.2022.S01.1080p"));
    try std.testing.expect(!releaseMatches("Reacher", 2022, "Jack.Reacher.2022.1080p"));
    try std.testing.expect(!releaseMatches("Reacher", 2022, "Reacher.S01.1080p"));
    try std.testing.expect(!releaseMatches("Reacher", 2022, "Reacher.2012.1080p"));
    try std.testing.expect(!releaseMatches("Reacher", 0, "Reacher.2022"));
}
const Fixture = struct {
    source: enum { tmdb, torrent, music } = .tmdb,
    catalog_kind: [8]u8 = @splat(0),
    catalog_kind_len: usize = 0,
    catalog_imdb: [16]u8 = @splat(0),
    catalog_imdb_len: usize = 0,
    catalog_id: i32 = 0,
    year: u16 = 0,
    name: [256]u8 = @splat(0),
    name_len: usize = 0,
    url: [64]u8 = @splat(0),
    url_len: usize = 0,
    score: u32 = 0,
    match_pct: u8 = 100,
};
fn fixture(source: @FieldType(Fixture, "source"), name: []const u8, year: u16, id: i32) Fixture {
    var row: Fixture = .{ .source = source, .year = year, .catalog_id = id };
    @memcpy(row.name[0..name.len], name);
    row.name_len = name.len;
    @memcpy(row.catalog_kind[0..5], "movie");
    row.catalog_kind_len = 5;
    @memcpy(row.url[0..name.len], name);
    row.url_len = name.len;
    return row;
}
test "projection groups releases only with one catalog and retains original filtered indexes" {
    const rows = [_]Fixture{ fixture(.tmdb, "Reacher", 2022, 1), fixture(.torrent, "Reacher.2022.1080p", 0, 0), fixture(.torrent, "Reacher.S01", 0, 0) };
    const out = try std.testing.allocator.create(Projection);
    defer std.testing.allocator.destroy(out);
    projectInto(&rows, &.{ 0, 1, 2 }, out);
    try std.testing.expectEqual(@as(usize, 2), out.count);
    try std.testing.expectEqual(@as(usize, 1), out.groups[0].offer_count);
    try std.testing.expectEqual(@as(u16, 1), out.groups[0].indexes[1]);
    const duplicate = [_]Fixture{ rows[0], fixture(.tmdb, "Reacher", 2022, 2), rows[1] };
    projectInto(&duplicate, &.{ 0, 1, 2 }, out);
    try std.testing.expectEqual(@as(usize, 3), out.count);
    projectInto(&rows, &.{2}, out);
    try std.testing.expectEqual(@as(usize, 2), out.groups[0].representative);
}
test "late catalogs reclaim torrent saturation without unbounding results" {
    var rows: [16]Fixture = undefined;
    for (&rows, 0..) |*row, i| {
        row.* = fixture(.torrent, "Release", 0, 0);
        row.score = @intCast(i);
    }
    var catalog = fixture(.tmdb, "Work", 2020, 1);
    catalog.score = 45;
    try std.testing.expectEqual(@as(?usize, 15), evictionIndex(&rows, catalog));
    for (rows[0..8]) |*row| row.* = catalog;
    try std.testing.expect(evictionIndex(&rows, catalog) == null);
}
test "cache identity separates masks configurations and long queries without plaintext" {
    var a: [80]u8 = undefined;
    var b: [80]u8 = undefined;
    const long_query = [_]u8{'q'} ** 255;
    const first = cacheIdentity(&a, &long_query, 65535, 1).?;
    try std.testing.expect(first.len < 80);
    try std.testing.expect(!std.mem.eql(u8, first, cacheIdentity(&b, &long_query, 1, 1).?));
    try std.testing.expect(!std.mem.eql(u8, first, cacheIdentity(&b, &long_query, 65535, 2).?));
    try std.testing.expect(std.mem.indexOf(u8, first, "qqqq") == null);
    try std.testing.expect(cacheIdentity(a[0..2], &long_query, 65535, 1) == null);
}
test "persisted search excludes account identities while retaining public catalogs and audio" {
    inline for (.{ "jellyfin", "plex", "opds", "audiobooks", "plugin", "local" }) |source| {
        try std.testing.expect(!cacheEligible(.{ .source = source, .url = "opaque-item-id" }));
    }
    try std.testing.expect(!cacheEligible(.{ .source = "music", .provider = "subsonic", .url = "opal://music/subsonic/item" }));
    try std.testing.expect(!cacheEligible(.{ .source = "stremio", .url = "https://server.test/private-token/stream" }));
    try std.testing.expect(cacheEligible(.{ .source = "music", .provider = "audius", .url = "opal://music/audius/track" }));
    try std.testing.expect(cacheEligible(.{ .source = "music", .provider = "jiosaavn", .url = "https://public.test/track" }));
    try std.testing.expect(cacheEligible(.{ .source = "stremio", .provider = "nasa", .url = "https://public.test/video" }));
    try std.testing.expect(cacheEligible(.{ .source = "tmdb", .url = "opal://catalog/tv/1" }));
    try std.testing.expect(!cacheEligible(.{ .source = "novels", .url = "novel|royalroad|https://user:pass@host.test/work|Book" }));
}
test "192 row admission reserves late works without growing the bounded wave" {
    const rows = try std.testing.allocator.alloc(Fixture, MAX_ROWS);
    defer std.testing.allocator.free(rows);
    for (rows, 0..) |*row, i| {
        row.* = fixture(.torrent, "Release", 0, 0);
        row.score = @intCast(i);
    }
    var work = fixture(.tmdb, "Work", 2022, 1);
    work.score = 500;
    for (0..8) |i| {
        work.catalog_id = @intCast(i + 1);
        const victim = evictionIndex(rows, work).?;
        try std.testing.expect(isRelease(rows[victim]));
        rows[victim] = work;
    }
    var ninth = work;
    ninth.score = 501;
    try std.testing.expect(evictionIndex(rows, ninth) == null);
    var song = fixture(.music, "Song", 0, 0);
    song.score = 999;
    const victim = evictionIndex(rows, song).?;
    try std.testing.expect(isRelease(rows[victim]));
    var catalogs: usize = 0;
    for (rows) |row| if (category(row) == .movies) {
        catalogs += 1;
    };
    try std.testing.expectEqual(@as(usize, 8), catalogs);
    try std.testing.expectEqual(@as(usize, 192), rows.len);
}
test "duplicate metadata catalogs do not count as playable offers" {
    const row = fixture(.tmdb, "Work", 2022, 1);
    const out = try std.testing.allocator.create(Projection);
    defer std.testing.allocator.destroy(out);
    projectInto(&[_]Fixture{ row, row }, &.{ 0, 1 }, out);
    try std.testing.expectEqual(@as(usize, 1), out.count);
    try std.testing.expectEqual(@as(usize, 2), out.groups[0].count);
    try std.testing.expectEqual(@as(usize, 0), out.groups[0].offer_count);
}
test "repeated availability does not inflate source count" {
    const row = fixture(.music, "Song", 2022, 1);
    const out = try std.testing.allocator.create(Projection);
    defer std.testing.allocator.destroy(out);
    projectInto(&[_]Fixture{ row, row }, &.{ 0, 1 }, out);
    try std.testing.expectEqual(@as(usize, 1), out.count);
    try std.testing.expectEqual(@as(usize, 1), out.groups[0].offer_count);
}

test "Reacher episode no year groups only a unique typed show and never movie" {
    var show = fixture(.tmdb, "Reacher", 2022, 1);
    @memcpy(show.catalog_kind[0..2], "tv");
    show.catalog_kind_len = 2;
    const release = fixture(.torrent, "Reacher.S04E06.1080p", 0, 0);
    const out = try std.testing.allocator.create(Projection);
    defer std.testing.allocator.destroy(out);
    projectInto(&[_]Fixture{ show, release }, &.{ 0, 1 }, out);
    try std.testing.expectEqual(@as(usize, 1), out.count);
    try std.testing.expectEqual(@as(usize, 1), out.groups[0].offer_count);
    var remake = show;
    remake.catalog_id = 2;
    projectInto(&[_]Fixture{ show, remake, release }, &.{ 0, 1, 2 }, out);
    try std.testing.expectEqual(@as(usize, 3), out.count);
    projectInto(&[_]Fixture{ show, remake, release }, &.{ 0, 2 }, out);
    try std.testing.expectEqual(@as(usize, 2), out.count);
    projectInto(&[_]Fixture{ fixture(.tmdb, "Reacher", 2022, 1), release }, &.{ 0, 1 }, out);
    try std.testing.expectEqual(@as(usize, 2), out.count);
    try std.testing.expect(episodeMatches("Reacher", "Reacher.S04.1080p"));
    try std.testing.expect(!episodeMatches("Reacher", "Jack.Reacher.S04E06"));
}
test "verified IMDb identity groups cross provider but keeps movie and TV separate" {
    var a = fixture(.tmdb, "Work", 2022, 1);
    var b = fixture(.music, "Work", 2022, 2);
    @memcpy(a.catalog_imdb[0..7], "tt12345");
    a.catalog_imdb_len = 7;
    b.catalog_imdb = a.catalog_imdb;
    b.catalog_imdb_len = a.catalog_imdb_len;
    const out = try std.testing.allocator.create(Projection);
    defer std.testing.allocator.destroy(out);
    projectInto(&[_]Fixture{ a, b }, &.{ 0, 1 }, out);
    try std.testing.expectEqual(@as(usize, 1), out.count);
    @memcpy(b.catalog_kind[0..2], "tv");
    b.catalog_kind_len = 2;
    projectInto(&[_]Fixture{ a, b }, &.{ 0, 1 }, out);
    try std.testing.expectEqual(@as(usize, 2), out.count);
}
