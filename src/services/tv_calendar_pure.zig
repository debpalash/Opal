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

fn jsonIntAfter(s: []const u8, key: []const u8) ?i64 {
    const ki = std.mem.indexOf(u8, s, key) orelse return null;
    var i = ki + key.len;
    while (i < s.len and (s[i] == ' ' or s[i] == ':')) i += 1;
    var v: i64 = 0;
    var any = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
        any = true;
    }
    return if (any) v else null;
}

fn jsonStrAfter(s: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, s, key) orelse return null;
    const vs = ki + key.len;
    const ve = std.mem.indexOfScalarPos(u8, s, vs, '"') orelse return null;
    return s[vs..ve];
}

/// Extract `"next_episode_to_air": {...}` (or last_) from a TMDB /tv/{id}
/// body. Returns null when the key is absent or explicitly `null` (ended /
/// nothing scheduled). `key` must include the quotes + colon prefix, e.g.
/// `"\"next_episode_to_air\":"`.
pub fn parseEpisodeToAir(body: []const u8, key: []const u8) ?EpisodeToAir {
    const ki = std.mem.indexOf(u8, body, key) orelse return null;
    var i = ki + key.len;
    while (i < body.len and (body[i] == ' ')) i += 1;
    if (i >= body.len or body[i] != '{') return null; // "null" or malformed

    // Bound to the matching close brace (these objects never nest).
    const end = std.mem.indexOfScalarPos(u8, body, i, '}') orelse return null;
    const obj = body[i .. end + 1];

    var out = EpisodeToAir{};
    out.season = @intCast(jsonIntAfter(obj, "\"season_number\"") orelse return null);
    out.episode = @intCast(jsonIntAfter(obj, "\"episode_number\"") orelse return null);
    const date = jsonStrAfter(obj, "\"air_date\":\"") orelse return null;
    out.air_epoch = dateToEpoch(date) orelse return null;
    if (jsonStrAfter(obj, "\"name\":\"")) |nm| {
        const n = @min(nm.len, out.name.len);
        @memcpy(out.name[0..n], nm[0..n]);
        out.name_len = n;
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
    var want_s_buf: [24]u8 = undefined;
    var want_e_buf: [24]u8 = undefined;
    const want_s = std.fmt.bufPrint(&want_s_buf, "\"season\":\"{d}\"", .{season}) catch return null;
    const want_e = std.fmt.bufPrint(&want_e_buf, "\"episode\":\"{d}\"", .{episode}) catch return null;

    var best: ?u32 = null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, want_s)) |si| {
        // Same torrent object only: bound the window at the object's closing
        // brace so episode/seeds are never paired across object boundaries.
        // (EZTV torrent objects carry no nested braces.)
        const win_end = std.mem.indexOfScalarPos(u8, body, si, '}') orelse body.len;
        const win = body[si..win_end];
        pos = si + want_s.len;
        if (std.mem.indexOf(u8, win, want_e) == null) continue;
        const seeds = jsonIntAfter(win, "\"seeds\"") orelse 0;
        const s32: u32 = @intCast(@max(0, @min(seeds, std.math.maxInt(u32))));
        if (best == null or s32 > best.?) best = s32;
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
