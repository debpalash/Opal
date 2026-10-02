//! Pure logic for the TV calendar / "Coming up" rail — TMDB next-episode
//! parsing, EZTV availability extraction, air-date math, countdown labels.
//! No io/state so it unit-tests standalone; tv_calendar.zig does the network.

const std = @import("std");

// ── Date math ──

/// Days from civil date to 1970-01-01 (Howard Hinnant's days_from_civil).
fn daysFromCivil(y_in: i64, m: u32, d: u32) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u64 = @intCast(y - era * 400); // [0, 399]
    const mp: u64 = (m + 9) % 12; // [0, 11] (Mar=0)
    const doy: u64 = (153 * mp + 2) / 5 + d - 1; // [0, 365]
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    return era * 146097 + @as(i64, @intCast(doe)) - 719468;
}

/// "YYYY-MM-DD" → unix epoch seconds at 00:00 UTC, or null on malformed input.
pub fn dateToEpoch(date: []const u8) ?i64 {
    if (date.len < 10 or date[4] != '-' or date[7] != '-') return null;
    const y = std.fmt.parseInt(i64, date[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u32, date[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u32, date[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    const month_days = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
    const limit = month_days[m - 1] + @as(u32, if (m == 2 and leap) 1 else 0);
    if (d > limit) return null;
    return daysFromCivil(y, m, d) * 86400;
}

/// Human countdown to an air date: "in 3d", "in 5h", "today", "aired".
/// Air dates are day-granular (00:00 UTC), so "today" covers the airing day.
pub fn countdownLabel(now_s: i64, air_s: i64, buf: []u8) []const u8 {
    const diff = air_s - now_s;
    if (diff <= -86400) return "aired";
    if (diff <= 0) return "today";
    const days = @divFloor(diff, 86400);
    if (days >= 1) {
        return std.fmt.bufPrint(buf, "in {d}d", .{days}) catch "soon";
    }
    const hours = @divFloor(diff, 3600);
    if (hours >= 1) {
        return std.fmt.bufPrint(buf, "in {d}h", .{hours}) catch "soon";
    }
    return "today";
}

// ── TMDB /tv/{id} episode-to-air objects ──

pub const EpisodeToAir = struct {
    season: i32 = 0,
    episode: i32 = 0,
    air_epoch: i64 = 0,
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
};

fn stringEnd(doc: []const u8, start: usize) ?usize {
    if (start >= doc.len or doc[start] != '"') return null;
    var pos = start + 1;
    while (pos < doc.len) {
        if (doc[pos] == '"') return pos + 1;
        if (doc[pos] == '\\') {
            if (pos + 1 >= doc.len) return null;
            pos += 2;
        } else pos += 1;
    }
    return null;
}
fn valueEnd(doc: []const u8, start: usize) ?usize {
    if (start >= doc.len) return null;
    if (doc[start] == '"') return stringEnd(doc, start);
    if (doc[start] == '{' or doc[start] == '[') {
        var depth: usize = 1;
        var pos = start + 1;
        while (pos < doc.len) {
            switch (doc[pos]) {
                '"' => {
                    pos = stringEnd(doc, pos) orelse return null;
                    continue;
                },
                '{', '[' => depth += 1,
                '}', ']' => {
                    depth -= 1;
                    if (depth == 0) return pos + 1;
                },
                else => {},
            }
            pos += 1;
        }
        return null;
    }
    var pos = start;
    while (pos < doc.len and !std.ascii.isWhitespace(doc[pos]) and doc[pos] != ',' and doc[pos] != '}' and doc[pos] != ']') : (pos += 1) {}
    return if (pos > start) pos else null;
}
/// Only direct object fields are considered. Display text and nested objects
/// cannot contribute a fake key, episode number, or seed count.
fn field(doc: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < doc.len and std.ascii.isWhitespace(doc[pos])) : (pos += 1) {}
    if (pos >= doc.len or doc[pos] != '{') return null;
    pos += 1;
    while (pos < doc.len) {
        while (pos < doc.len and std.ascii.isWhitespace(doc[pos])) : (pos += 1) {}
        const key_start = pos;
        const key_end = stringEnd(doc, pos) orelse return null;
        pos = key_end;
        while (pos < doc.len and std.ascii.isWhitespace(doc[pos])) : (pos += 1) {}
        if (pos >= doc.len or doc[pos] != ':') return null;
        pos += 1;
        while (pos < doc.len and std.ascii.isWhitespace(doc[pos])) : (pos += 1) {}
        const end = valueEnd(doc, pos) orelse return null;
        if (std.mem.eql(u8, doc[key_start + 1 .. key_end - 1], name)) return doc[pos..end];
        pos = end;
        while (pos < doc.len and std.ascii.isWhitespace(doc[pos])) : (pos += 1) {}
        if (pos >= doc.len or doc[pos] != ',') return null;
        pos += 1;
    }
    return null;
}
fn integer(doc: []const u8, name: []const u8) ?i64 {
    var raw = field(doc, name) orelse return null;
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') raw = raw[1 .. raw.len - 1];
    return std.fmt.parseInt(i64, raw, 10) catch null;
}
fn jsonStrAfter(doc: []const u8, key: []const u8) ?[]const u8 {
    const raw = field(doc, std.mem.trim(u8, key, "\" :\t\r\n")) orelse return null;
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}

pub fn validShowDocument(doc: []const u8, expected_id: i32) bool {
    return expected_id > 0 and (integer(doc, "id") orelse return false) == expected_id;
}

/// Poster fallback from the same TMDB show document used for schedule data.
/// Older tracked rows may predate poster persistence, so relying only on the
/// database snapshot leaves Coming up permanently blank.
pub fn posterPath(body: []const u8) ?[]const u8 {
    const path = jsonStrAfter(body, "\"poster_path\":\"") orelse return null;
    return if (path.len > 0) path else null;
}

/// Extract `"next_episode_to_air": {...}` (or last_) from a TMDB /tv/{id}
/// body. Returns null when the key is absent or explicitly `null` (ended /
/// nothing scheduled). `key` must include the quotes + colon prefix, e.g.
/// `"\"next_episode_to_air\":"`.
pub fn parseEpisodeToAir(body: []const u8, key: []const u8) ?EpisodeToAir {
    const obj = field(body, std.mem.trim(u8, key, "\" :\t\r\n")) orelse return null;
    if (obj.len < 2 or obj[0] != '{' or obj[obj.len - 1] != '}') return null;

    var out = EpisodeToAir{};
    const season = integer(obj, "season_number") orelse return null;
    const episode = integer(obj, "episode_number") orelse return null;
    if (season < 0 or season > std.math.maxInt(i32) or episode <= 0 or episode > std.math.maxInt(i32)) return null;
    out.season = @intCast(season);
    out.episode = @intCast(episode);
    const date = jsonStrAfter(obj, "\"air_date\":\"") orelse return null;
    out.air_epoch = dateToEpoch(date) orelse return null;
    if (jsonStrAfter(obj, "\"name\":\"")) |nm| {
        out.name_len = @import("json_pure.zig").jsonUnescape(nm, &out.name).len;
    }
    return out;
}

/// "tt0417299" (TMDB external_ids body) → the digits EZTV wants ("0417299").
pub fn imdbDigits(body: []const u8, buf: []u8) ?[]const u8 {
    const id = jsonStrAfter(body, "\"imdb_id\":\"") orelse return null;
    if (!std.mem.startsWith(u8, id, "tt") or id.len <= 2) return null;
    const digits = id[2..];
    if (digits.len > buf.len) return null;
    for (digits) |ch| if (ch < '0' or ch > '9') return null;
    @memcpy(buf[0..digits.len], digits);
    return buf[0..digits.len];
}

// ── EZTV get-torrents availability ──

/// Max seeds across torrents matching SxxEyy in an eztvx.to get-torrents body
/// (season/episode arrive as STRINGS: "season":"3"). Null when no torrent for
/// that episode exists — i.e. not yet available.
pub fn eztvEpisodeSeeds(body: []const u8, season: i32, episode: i32) ?u32 {
    const torrents = field(body, "torrents") orelse return null;
    if (torrents.len < 2 or torrents[0] != '[' or torrents[torrents.len - 1] != ']') return null;
    var best: ?u32 = null;
    var pos: usize = 1;
    while (pos < torrents.len - 1) {
        while (pos < torrents.len - 1 and (std.ascii.isWhitespace(torrents[pos]) or torrents[pos] == ',')) : (pos += 1) {}
        if (pos >= torrents.len - 1) break;
        const end = valueEnd(torrents, pos) orelse return null;
        const torrent = torrents[pos..end];
        pos = end;
        if ((integer(torrent, "season") orelse continue) != season or (integer(torrent, "episode") orelse continue) != episode) continue;
        const seeds = integer(torrent, "seeds") orelse continue;
        const value: u32 = @intCast(@max(0, @min(seeds, std.math.maxInt(u32))));
        if (best == null or value > best.?) best = value;
    }
    return best;
}

// ── Tests ──

test "dateToEpoch: known dates + malformed input" {
    try std.testing.expectEqual(@as(?i64, 0), dateToEpoch("1970-01-01"));
    try std.testing.expectEqual(@as(?i64, 86400), dateToEpoch("1970-01-02"));
    // 2026-07-15 00:00 UTC (cross-checked against `date -j -u`).
    try std.testing.expectEqual(@as(?i64, 1784073600), dateToEpoch("2026-07-15"));
    try std.testing.expect(dateToEpoch("2026-7-15") == null);
    try std.testing.expect(dateToEpoch("garbage") == null);
    try std.testing.expect(dateToEpoch("2026-13-01") == null);
}

test "countdownLabel tiers" {
    var b: [24]u8 = undefined;
    const day = 86400;
    try std.testing.expectEqualStrings("in 3d", countdownLabel(0, 3 * day + 3600, &b));
    try std.testing.expectEqualStrings("in 5h", countdownLabel(0, 5 * 3600, &b));
    try std.testing.expectEqualStrings("today", countdownLabel(0, 100, &b));
    try std.testing.expectEqualStrings("today", countdownLabel(100, 0, &b)); // airing day
    try std.testing.expectEqualStrings("aired", countdownLabel(2 * day, 0, &b));
}

test "parseEpisodeToAir: object, null, and absent" {
    const body =
        "{\"id\":94997,\"name\":\"Silo\",\"next_episode_to_air\":{\"air_date\":\"2026-07-15\",\"episode_number\":4,\"season_number\":3,\"name\":\"The Vault\"},\"last_episode_to_air\":null}";
    const next = parseEpisodeToAir(body, "\"next_episode_to_air\":").?;
    try std.testing.expectEqual(@as(i32, 3), next.season);
    try std.testing.expectEqual(@as(i32, 4), next.episode);
    try std.testing.expectEqual(@as(i64, 1784073600), next.air_epoch);
    try std.testing.expectEqualStrings("The Vault", next.name[0..next.name_len]);
    try std.testing.expect(parseEpisodeToAir(body, "\"last_episode_to_air\":") == null);
    try std.testing.expect(parseEpisodeToAir("{}", "\"next_episode_to_air\":") == null);
}

test "posterPath reads show art fallback" {
    try std.testing.expectEqualStrings("/silo.jpg", posterPath("{\"id\":1,\"poster_path\":\"/silo.jpg\"}").?);
    try std.testing.expect(posterPath("{\"poster_path\":null}") == null);
    try std.testing.expect(posterPath("{}") == null);
}

test "imdbDigits strips tt and validates" {
    var b: [12]u8 = undefined;
    try std.testing.expectEqualStrings("14688458", imdbDigits("{\"imdb_id\":\"tt14688458\",\"tvdb_id\":403245}", &b).?);
    try std.testing.expect(imdbDigits("{\"imdb_id\":null}", &b) == null);
    try std.testing.expect(imdbDigits("{\"imdb_id\":\"\"}", &b) == null);
    try std.testing.expect(imdbDigits("{}", &b) == null);
}

test "eztvEpisodeSeeds: string season/episode match, max seeds, absent episode" {
    const body =
        "{\"torrents\":[" ++
        "{\"filename\":\"Silo S03E01 720p\",\"season\":\"3\",\"episode\":\"1\",\"seeds\":12}," ++
        "{\"filename\":\"Silo S03E01 1080p\",\"season\":\"3\",\"episode\":\"1\",\"seeds\":87}," ++
        "{\"filename\":\"Silo S02E10\",\"season\":\"2\",\"episode\":\"10\",\"seeds\":400}]}";
    try std.testing.expectEqual(@as(?u32, 87), eztvEpisodeSeeds(body, 3, 1));
    try std.testing.expectEqual(@as(?u32, 400), eztvEpisodeSeeds(body, 2, 10));
    // S03E02 not out yet → null (distinct from 0 seeds).
    try std.testing.expect(eztvEpisodeSeeds(body, 3, 2) == null);
    // Episode "1" must not match "10" (exact string with closing quote).
    try std.testing.expect(eztvEpisodeSeeds(body, 3, 10) == null);
}

pub const CalendarEntry = struct {
    tmdb_id: i32 = 0,
    name: [128]u8 = .{0} ** 128,
    name_len: usize = 0,
    poster_path: [64]u8 = .{0} ** 64,
    poster_path_len: usize = 0,
    next_season: i32 = 0,
    next_episode: i32 = 0,
    next_air_epoch: i64 = 0,
    next_name: [64]u8 = .{0} ** 64,
    next_name_len: usize = 0,
    last_season: i32 = 0,
    last_episode: i32 = 0,
    available: bool = false,
    seeds: u32 = 0,
    unseen: bool = false,
};

/// Single writer stages privately; external synchronization protects finish and
/// copy. An incomplete refresh preserves its last coherent publication.
pub const CalendarProjection = struct {
    published: [12]CalendarEntry = undefined,
    staged: [12]CalendarEntry = undefined,
    count: usize = 0,
    staged_count: usize = 0,
    succeeded: usize = 0,
    expected: ?usize = null,
    loaded: bool = false,
    failed: bool = false,
    partial: bool = false,

    pub fn begin(self: *CalendarProjection, expected: ?usize) void {
        self.staged_count = 0;
        self.succeeded = 0;
        self.expected = expected;
    }
    pub fn add(self: *CalendarProjection, entry: CalendarEntry) void {
        self.succeeded += 1;
        // A valid caught-up show contributes to success even without a card.
        if (entry.next_season <= 0 and !entry.unseen) return;
        if (self.staged_count == self.staged.len) return;
        self.staged[self.staged_count] = entry;
        self.staged_count += 1;
    }
    pub fn finish(self: *CalendarProjection) void {
        if (self.succeeded == 0 and (self.expected orelse 1) != 0) {
            self.failed = true;
            self.partial = false;
            return;
        }
        @memcpy(self.published[0..self.staged_count], self.staged[0..self.staged_count]);
        self.count = self.staged_count;
        self.failed = false;
        self.partial = if (self.expected) |expected| self.succeeded < expected else false;
        self.loaded = true;
    }
    pub fn copy(self: *const CalendarProjection, out: []CalendarEntry) usize {
        const n = @min(self.count, out.len);
        @memcpy(out[0..n], self.published[0..n]);
        return n;
    }
};

test "calendar publishes whole refreshes and preserves previous rows after provider failure" {
    var projection: CalendarProjection = .{};
    var out: [12]CalendarEntry = undefined;
    projection.begin(1);
    projection.add(.{ .tmdb_id = 11, .next_season = 1, .next_episode = 2 });
    try std.testing.expectEqual(@as(usize, 0), projection.copy(&out));
    projection.finish();
    try std.testing.expectEqual(@as(usize, 1), projection.copy(&out));
    try std.testing.expectEqual(@as(i32, 11), out[0].tmdb_id);
    projection.begin(2);
    projection.add(.{ .tmdb_id = 22, .next_season = 2 });
    _ = projection.copy(&out);
    try std.testing.expectEqual(@as(i32, 11), out[0].tmdb_id);
    projection.finish();
    try std.testing.expect(projection.partial);
    try std.testing.expectEqual(@as(usize, 1), projection.copy(&out));
    try std.testing.expectEqual(@as(i32, 22), out[0].tmdb_id);
    projection.begin(1);
    projection.finish();
    try std.testing.expect(projection.failed);
    _ = projection.copy(&out);
    try std.testing.expectEqual(@as(i32, 22), out[0].tmdb_id);
    projection.begin(1);
    projection.add(.{ .tmdb_id = 22 }); // valid caught-up show
    projection.finish();
    try std.testing.expect(!projection.failed);
    try std.testing.expectEqual(@as(usize, 0), projection.copy(&out));
}

test "calendar empty tracked library is a successful bounded publication" {
    var projection: CalendarProjection = .{};
    projection.begin(0);
    projection.finish();
    try std.testing.expect(projection.loaded and !projection.failed);
    projection.begin(15);
    for (0..15) |id| projection.add(.{ .tmdb_id = @intCast(id + 1), .next_season = 1 });
    projection.finish();
    try std.testing.expectEqual(@as(usize, 12), projection.count);
    try std.testing.expect(!projection.partial);
}

test "calendar metadata tolerates actual JSON formatting, escaped names and rejects overflowing identities" {
    const doc = "{\"name\":\"ignore } text\", \"next_episode_to_air\" : { \"name\" : \"The \\\"Vault\\\"\", \"air_date\" : \"2026-07-15\", \"season_number\" : 3, \"episode_number\" : 4 }}";
    const parsed = parseEpisodeToAir(doc, "\"next_episode_to_air\":").?;
    try std.testing.expectEqualStrings("The \"Vault\"", parsed.name[0..parsed.name_len]);
    try std.testing.expectEqual(@as(i32, 4), parsed.episode);
    try std.testing.expect(parseEpisodeToAir("{\"next_episode_to_air\":{\"season_number\":999999999999999999999999999999,\"episode_number\":1,\"air_date\":\"2026-07-15\"}}", "\"next_episode_to_air\":") == null);
    try std.testing.expect(dateToEpoch("2026-02-31") == null);
    try std.testing.expect(dateToEpoch("2024-02-29") != null);
    try std.testing.expectEqualStrings("/real.jpg", posterPath("{\"nested\":{\"poster_path\":\"/wrong.jpg\"}, \"poster_path\" : \"/real.jpg\"}").?);
}

test "calendar availability accepts string or integer identities, any field order and cannot cross torrent rows" {
    const doc = "{\"torrents\":[{\"seeds\" : 9, \"episode\" : 4, \"filename\":\"quoted } text\", \"season\" : 3}, {\"season\":\"3\", \"episode\":\"4\", \"seeds\":30}]}";
    try std.testing.expectEqual(@as(?u32, 30), eztvEpisodeSeeds(doc, 3, 4));
    try std.testing.expect(eztvEpisodeSeeds("{\"torrents\":[{\"season\":3,\"seeds\":99},{\"episode\":4,\"seeds\":80}]}", 3, 4) == null);
    try std.testing.expect(eztvEpisodeSeeds("{\"torrents\":[{\"season\":3,\"episode\":4,\"seeds\":999999999999999999999999999999}]}", 3, 4) == null);
}
