//! Provider-independent episode metadata and conservative title matching.
const std = @import("std");
pub const capacity = 4096;
pub const EpisodeGrid = struct { columns: usize, rows: usize, width: f32 };
pub fn episodeGrid(available: f32, total: usize) EpisodeGrid {
    const width = @max(1, available);
    const columns: usize = @min(6, @max(1, @as(usize, @intFromFloat((width + 8) / 264))));
    return .{ .columns = columns, .rows = (total + columns - 1) / columns, .width = (width - 8 * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns)) };
}

test "episode grid fits narrow windows and keeps long catalogs in compact rows" {
    for ([_]f32{ 240, 390, 720, 1200, 1920 }) |width| {
        const layout = episodeGrid(width, 1180);
        try std.testing.expect(layout.width > 0);
        try std.testing.expect(layout.width * @as(f32, @floatFromInt(layout.columns)) + 8 * @as(f32, @floatFromInt(layout.columns - 1)) <= width + 0.1);
        try std.testing.expect(layout.rows * layout.columns >= 1180);
    }
    try std.testing.expectEqual(@as(usize, 1), episodeGrid(390, 180).columns);
    try std.testing.expectEqual(@as(usize, 4), episodeGrid(1200, 180).columns);
}
pub const Episode = struct {
    number: usize,
    title: []const u8 = "",
    aired: []const u8 = "",
    score: f32 = 0,
    filler: bool = false,
};
pub fn field(v: std.json.Value, key: []const u8) std.json.Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn string(v: std.json.Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn number(v: std.json.Value) usize {
    return if (v == .integer and v.integer > 0) @intCast(v.integer) else 0;
}
pub fn data(v: std.json.Value) ?[]const std.json.Value {
    const d = field(v, "data");
    return if (d == .array) d.array.items else null;
}
pub fn hasNext(v: std.json.Value) bool {
    const next = field(field(v, "pagination"), "has_next_page");
    return next == .bool and next.bool;
}
pub fn anilistEpisodeCount(root: std.json.Value) ?usize {
    const media = field(field(root, "data"), "Media");
    const next = number(field(field(media, "nextAiringEpisode"), "episode"));
    const total = if (next > 0) next - 1 else number(field(media, "episodes"));
    return if (total > 0) @min(total, capacity) else null;
}
pub fn episode(v: std.json.Value) ?Episode {
    const n = number(field(v, "mal_id"));
    if (n == 0 or n > capacity) return null;
    const score = field(v, "score");
    const filler = field(v, "filler");
    const aired = string(field(v, "aired"));
    return .{ .number = n, .title = string(field(v, "title")), .aired = aired[0..@min(10, aired.len)], .score = switch (score) {
        .float => @floatCast(score.float),
        .integer => @floatFromInt(score.integer),
        else => 0,
    }, .filler = filler == .bool and filler.bool };
}
fn normalized(text: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (text) |ch| {
        if ((std.ascii.isAlphanumeric(ch) or ch >= 128) and n < out.len) {
            out[n] = std.ascii.toLower(ch);
            n += 1;
        }
    }
    return out[0..n];
}
/// Exact normalized aliases avoid choosing a sequel/remake just because it is
/// the first search result. A second query can use the English title alias.
pub fn titleMatches(a: []const u8, b: []const u8) bool {
    var aa: [512]u8 = undefined;
    var bb: [512]u8 = undefined;
    const x = normalized(a, &aa);
    const y = normalized(b, &bb);
    return x.len > 0 and std.mem.eql(u8, x, y);
}
pub fn paheShow(root: std.json.Value, title: []const u8, alias: []const u8) ?std.json.Value {
    for (data(root) orelse return null) |show| {
        const name = string(field(show, "title"));
        if ((titleMatches(title, name) or titleMatches(alias, name)) and string(field(show, "session")).len > 0) return show;
    }
    return null;
}
pub const Release = struct { page: usize, session: ?[]const u8 = null };
pub fn paheRelease(root: std.json.Value, ep: usize, current_page: usize) ?Release {
    const rows = data(root) orelse return null;
    const per_page = number(field(root, "per_page"));
    if (ep == 0 or per_page == 0) return null;
    const page = (ep - 1) / per_page + 1;
    if (page != current_page) return .{ .page = page };
    const offset = (ep - 1) % per_page;
    if (offset >= rows.len) return null;
    const session = string(field(rows[offset], "session"));
    if (session.len == 0) return null;
    return .{ .page = page, .session = session };
}

test "unknown totals still have discoverable episodes and long series exceed 200" {
    const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"pagination":{"has_next_page":true},"data":[{"mal_id":1200,"title":"A \"quoted\" title","aired":"2026-09-20T00:00:00Z","score":4.5,"filler":true}]}
    , .{});
    defer doc.deinit();
    const ep = episode(data(doc.value).?[0]).?;
    try std.testing.expectEqual(@as(usize, 1200), ep.number);
    try std.testing.expectEqualStrings("2026-09-20", ep.aired);
    try std.testing.expect(ep.filler);
    try std.testing.expect(hasNext(doc.value));
}
test "failed episode responses are distinct from authoritative empty lists" {
    const bad = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"status\":429,\"message\":\"Rate limited\"}", .{});
    defer bad.deinit();
    try std.testing.expect(data(bad.value) == null);
    const empty = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"data\":[]}", .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), data(empty.value).?.len);
}
test "AniList fallback uses aired episode count for ongoing shows with unknown totals" {
    const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"data":{"Media":{"episodes":null,"nextAiringEpisode":{"episode":1156}}}}
    , .{});
    defer doc.deinit();
    try std.testing.expectEqual(@as(?usize, 1155), anilistEpisodeCount(doc.value));
    try std.testing.expect(anilistEpisodeCount(.null) == null);
}
test "AnimePahe matches title aliases and actual episode sessions" {
    const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"data":[{"title":"Example Season 2","session":"wrong"},{"title":"Example!","session":"show-session"}]}
    , .{});
    defer doc.deinit();
    try std.testing.expectEqualStrings("show-session", string(field(paheShow(doc.value, "Example", "").?, "session")));
    try std.testing.expect(paheShow(doc.value, "Missing", "") == null);
    const eps = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"per_page":2,"data":[{"episode":13,"session":"episode-session"},{"episode":14,"session":"other"}]}
    , .{});
    defer eps.deinit();
    try std.testing.expectEqualStrings("episode-session", paheRelease(eps.value, 1, 1).?.session.?);
    try std.testing.expectEqual(@as(usize, 2), paheRelease(eps.value, 3, 1).?.page);
    try std.testing.expect(paheRelease(eps.value, 0, 1) == null);
}

/// Official release index: require the exact title and episode, then choose
/// the best available resolution up to 1080p. Never substitute another episode.
pub fn subsPleaseRelease(root: std.json.Value, title: []const u8, alias: []const u8, ep: usize) ?[]const u8 {
    if (root != .object or ep == 0) return null;
    var it = root.object.iterator();
    var chosen: ?[]const u8 = null;
    var best: usize = 0;
    while (it.next()) |entry| {
        const row = entry.value_ptr.*;
        const show = string(field(row, "show"));
        if (!titleMatches(title, show) and !titleMatches(alias, show)) continue;
        const episode_value = field(row, "episode");
        const episode_number = if (episode_value == .string) std.fmt.parseInt(usize, episode_value.string, 10) catch continue else number(episode_value);
        if (episode_number != ep) continue;
        const downloads = field(row, "downloads");
        if (downloads != .array) continue;
        for (downloads.array.items) |download| {
            const resolution = std.fmt.parseInt(usize, string(field(download, "res")), 10) catch continue;
            const magnet = string(field(download, "magnet"));
            if (resolution > 1080 or resolution <= best or !std.mem.startsWith(u8, magnet, "magnet:?xt=urn:btih:") or magnet.len > 2048) continue;
            best = resolution;
            chosen = magnet;
        }
    }
    return chosen;
}

test "SubsPlease release selection matches exact series and episode" {
    const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"wrong":{"show":"Example Season 2","episode":"2","downloads":[{"res":"1080","magnet":"magnet:?xt=urn:btih:wrong"}]},"right":{"show":"Example","episode":"2","downloads":[{"res":"480","magnet":"magnet:?xt=urn:btih:low"},{"res":"1080","magnet":"magnet:?xt=urn:btih:right"}]}}
    , .{});
    defer doc.deinit();
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:right", subsPleaseRelease(doc.value, "Example", "", 2).?);
    try std.testing.expect(subsPleaseRelease(doc.value, "Example", "", 1) == null);
}

pub const StreamingEpisode = struct { number: usize, title: []const u8, thumbnail: []const u8 };
pub fn streamingEpisodes(root: std.json.Value) []const std.json.Value {
    const rows = field(field(field(root, "data"), "Media"), "streamingEpisodes");
    return if (rows == .array) rows.array.items else &.{};
}
/// Use explicit episode numbering; array order varies between providers.
pub fn streamingEpisode(value: std.json.Value) ?StreamingEpisode {
    const title = string(field(value, "title"));
    const prefix = "Episode ";
    if (!std.mem.startsWith(u8, title, prefix)) return null;
    var end = prefix.len;
    while (end < title.len and std.ascii.isDigit(title[end])) : (end += 1) {}
    if (end == prefix.len or (end < title.len and title[end] != ' ' and title[end] != '-')) return null;
    const n = std.fmt.parseInt(usize, title[prefix.len..end], 10) catch return null;
    if (n == 0 or n > capacity) return null;
    const url = string(field(value, "thumbnail"));
    if (!std.mem.startsWith(u8, url, "https://") or url.len > 1024 or std.mem.indexOfAny(u8, url, " \r\n\t") != null) return null;
    return .{ .number = n, .title = std.mem.trim(u8, title[end..], " -"), .thumbnail = url };
}
test "streaming artwork uses explicit episode numbers and rejects ambiguous previews" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"data":{"Media":{"streamingEpisodes":[{"title":"Episode 12 - A new beginning","thumbnail":"https://example.com/12.jpg"},{"title":"Trailer 1","thumbnail":"https://example.com/trailer.jpg"},{"title":"Episode 1.5 - Special","thumbnail":"https://example.com/special.jpg"},{"title":"Episode 3 - Three","thumbnail":"javascript:bad"}]}}}
    , .{});
    defer parsed.deinit();
    const rows = streamingEpisodes(parsed.value);
    const ep = streamingEpisode(rows[0]).?;
    try std.testing.expectEqual(@as(usize, 12), ep.number);
    try std.testing.expectEqualStrings("A new beginning", ep.title);
    for (rows[1..]) |row| try std.testing.expect(streamingEpisode(row) == null);
}

pub const IndexedEpisode = struct { number: usize, title: []const u8, image: []const u8, aired: []const u8, score: f32 };
pub fn indexedEpisode(key: []const u8, value: std.json.Value) ?IndexedEpisode {
    const n = std.fmt.parseInt(usize, key, 10) catch return null;
    if (n == 0 or n > capacity) return null;
    const titles = field(value, "title");
    var title = string(field(titles, "en"));
    if (title.len == 0) title = string(field(titles, "x-jat"));
    if (title.len == 0) title = string(field(titles, "ja"));
    const image = string(field(value, "image"));
    const safe_image = if (std.mem.startsWith(u8, image, "https://") and image.len <= 1024 and std.mem.indexOfAny(u8, image, "\r\n \t") == null) image else "";
    const date = string(field(value, "airDate"));
    const rating = field(value, "rating");
    const score: f32 = switch (rating) {
        .float => @floatCast(rating.float),
        .integer => @floatFromInt(rating.integer),
        .string => std.fmt.parseFloat(f32, rating.string) catch 0,
        else => 0,
    };
    return .{ .number = n, .title = title, .image = safe_image, .aired = date[0..@min(date.len, 10)], .score = if (std.math.isFinite(score)) std.math.clamp(score, 0, 10) else 0 };
}
test "Anime provider index keeps regular episode identity and validates artwork" {
    const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"title":{"en":"Asteroid Blues"},"image":"https://art.test/1.jpg","airDate":"1998-04-03","rating":"8.4"}
    , .{});
    defer doc.deinit();
    const ep = indexedEpisode("1", doc.value).?;
    try std.testing.expectEqualStrings("Asteroid Blues", ep.title);
    try std.testing.expectEqual(@as(usize, 1), ep.number);
    try std.testing.expect(indexedEpisode("S1", doc.value) == null);
    try std.testing.expect(indexedEpisode("1.5", doc.value) == null);
    try std.testing.expect(indexedEpisode("5000", doc.value) == null);
}
