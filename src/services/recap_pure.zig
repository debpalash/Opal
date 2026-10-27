//! "Previously on…" recaps — pure source selection, prompt, output clamp and
//! cache key.
//!
//! THE RULE: a recap may only draw on episodes that air BEFORE the one being
//! started AND that the user has actually watched. A later episode (watched
//! during a rewatch, or out of order) is never a source — that would be a
//! spoiler. The current episode's own overview is never a source either.
const std = @import("std");

pub const Ep = struct {
    season: i32,
    episode: i32,
};

/// Strict air-order "a comes before b". Specials (season 0) are never
/// "before" anything — they float outside the main timeline.
pub fn isBefore(a: Ep, b: Ep) bool {
    if (a.season < 1 or b.season < 1) return false;
    if (a.season != b.season) return a.season < b.season;
    return a.episode < b.episode;
}

pub const max_sources = 4;

/// Pick up to `max` recap sources from `watched`: only episodes strictly
/// before `current`, most recent last (air order). Duplicates collapse.
pub fn selectSources(watched: []const Ep, current: Ep, max: usize, out: []Ep) []Ep {
    const cap = @min(max, out.len);
    if (cap == 0) return out[0..0];
    var n: usize = 0;
    // Keep the `cap` latest qualifying episodes, sorted ascending.
    for (watched) |w| {
        if (!isBefore(w, current)) continue;
        var dup = false;
        for (out[0..n]) |o| if (o.season == w.season and o.episode == w.episode) {
            dup = true;
        };
        if (dup) continue;
        if (n < cap) {
            out[n] = w;
            n += 1;
        } else {
            // Replace the earliest if this one is later.
            var min_i: usize = 0;
            for (out[0..n], 0..) |o, i| if (isBefore(o, out[min_i])) {
                min_i = i;
            };
            if (isBefore(out[min_i], w)) out[min_i] = w else continue;
        }
    }
    std.mem.sort(Ep, out[0..n], {}, struct {
        fn lt(_: void, a: Ep, b: Ep) bool {
            return isBefore(a, b);
        }
    }.lt);
    return out[0..n];
}

pub const Source = struct {
    ep: Ep,
    title: []const u8 = "",
    transcript: []const u8 = "",
    overview: []const u8 = "",
};

pub const Kind = enum { transcript, overview, none };

/// Transcripts shorter than this are too thin to beat an overview.
pub const min_transcript_chars = 200;
pub const max_transcript_chars = 3000;

pub fn sourceKind(s: Source) Kind {
    if (std.mem.trim(u8, s.transcript, " \r\n\t").len >= min_transcript_chars) return .transcript;
    if (std.mem.trim(u8, s.overview, " \r\n\t").len > 0) return .overview;
    return .none;
}

/// The last `max` bytes of a transcript (endings matter most for "previously
/// on"), starting on a word and UTF-8 boundary.
pub fn transcriptTail(t_in: []const u8, max: usize) []const u8 {
    const t = std.mem.trim(u8, t_in, " \r\n\t");
    if (t.len <= max) return t;
    var start = t.len - max;
    while (start < t.len and (t[start] & 0xC0) == 0x80) start += 1;
    if (std.mem.indexOfAnyPos(u8, t, start, " \n")) |sp| {
        if (sp - start < 64) start = sp + 1;
    }
    return t[start..];
}

pub const system_prompt =
    "You write short, spoiler-safe \"Previously on\" recaps for TV episodes. Use ONLY the material provided, " ++
    "which covers episodes the viewer has already watched. Never guess, foreshadow or mention anything that happens " ++
    "after it. Write 3 to 5 sentences of plain prose in the present tense, no headings, no lists, no episode numbers.";

/// Build the user prompt. Returns the number of sources actually used (0 means
/// there is nothing to recap — don't call the model).
pub fn writePrompt(w: *std.Io.Writer, show: []const u8, current: Ep, sources: []const Source) !usize {
    var used: usize = 0;
    try w.print("Show: {s}\nThe viewer is about to start season {d}, episode {d}.\n\nWhat they have watched most recently:\n", .{ if (show.len > 0) show else "Unknown show", current.season, current.episode });
    for (sources) |s| {
        if (!isBefore(s.ep, current)) continue; // belt and braces: never a later episode
        switch (sourceKind(s)) {
            .none => continue,
            .transcript => {
                try w.print("\n[S{d}E{d}{s}{s} — dialogue excerpt]\n{s}\n", .{ s.ep.season, s.ep.episode, if (s.title.len > 0) " " else "", s.title, transcriptTail(s.transcript, max_transcript_chars) });
            },
            .overview => {
                try w.print("\n[S{d}E{d}{s}{s} — summary]\n{s}\n", .{ s.ep.season, s.ep.episode, if (s.title.len > 0) " " else "", s.title, std.mem.trim(u8, s.overview, " \r\n\t") });
            },
        }
        used += 1;
    }
    try w.writeAll("\nWrite the \"Previously on\" recap now.");
    return used;
}

pub const max_recap_chars = 900;

/// Normalize model output: drop code fences and a leading heading/label,
/// collapse whitespace, and cut at the last sentence end within `max` bytes.
pub fn clampRecap(text: []const u8, max: usize, out: []u8) []const u8 {
    var n: usize = 0;
    var last_space = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_content = true;
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "```")) continue;
        line = std.mem.trimStart(u8, line, "#*_ ");
        if (first_content) {
            first_content = false;
            const labels = [_][]const u8{ "Recap:", "Previously on:", "Previously on…", "Previously on..." };
            var stripped = false;
            for (labels) |l| if (std.ascii.startsWithIgnoreCase(line, l)) {
                line = std.mem.trim(u8, line[l.len..], " *_");
                stripped = true;
                break;
            };
            // A bare heading line like "Previously on Severance" carries no prose.
            if (!stripped and std.ascii.startsWithIgnoreCase(line, "previously on") and std.mem.indexOfAny(u8, line, ".!?") == null) continue;
        }
        for (line) |ch| {
            const is_space = ch == ' ' or ch == '\t';
            if (is_space and last_space) continue;
            if (n >= out.len) break;
            out[n] = if (is_space) ' ' else ch;
            n += 1;
            last_space = is_space;
        }
        if (n < out.len and !last_space) {
            out[n] = ' ';
            n += 1;
            last_space = true;
        }
    }
    while (n > 0 and out[n - 1] == ' ') n -= 1;
    const limit = @min(max, out.len);
    if (n <= limit) return out[0..n];
    // Cut at the last sentence end inside the limit.
    var cut: usize = 0;
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if ((out[i] == '.' or out[i] == '!' or out[i] == '?') and (i + 1 >= n or out[i + 1] == ' ')) cut = i + 1;
    }
    if (cut >= limit / 3) return out[0..cut];
    // No usable sentence end: cut at a word boundary.
    var end = limit;
    while (end > 0 and out[end - 1] != ' ') end -= 1;
    if (end == 0) end = limit;
    while (end > 0 and (out[end - 1] & 0xC0) == 0x80) end -= 1;
    if (end > 0 and out[end - 1] >= 0xC0) end -= 1;
    return std.mem.trimEnd(u8, out[0..end], " ");
}

/// Cache key: one recap per (show, season, episode).
pub fn cacheKey(buf: []u8, tmdb_id: i32, current: Ep) []const u8 {
    return std.fmt.bufPrint(buf, "{d}:s{d}e{d}", .{ tmdb_id, current.season, current.episode }) catch "";
}

/// TMDB /3/tv/{id}/season/{n} → episodes (overviews are recap sources).
pub const SeasonJson = struct {
    episodes: []const struct {
        episode_number: i32 = 0,
        name: ?[]const u8 = null,
        overview: ?[]const u8 = null,
    } = &.{},
};

pub fn parseSeason(alloc: std.mem.Allocator, json: []const u8) !std.json.Parsed(SeasonJson) {
    return std.json.parseFromSlice(SeasonJson, alloc, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

const testing = std.testing;

test "REGRESSION: sources never include later or current episodes" {
    // The viewer is rewatching S2E3 after having watched through S3.
    const watched = [_]Ep{
        .{ .season = 1, .episode = 9 }, .{ .season = 2, .episode = 1 },
        .{ .season = 2, .episode = 2 }, .{ .season = 2, .episode = 3 },
        .{ .season = 2, .episode = 4 }, .{ .season = 3, .episode = 1 },
        .{ .season = 0, .episode = 1 },
    };
    var out: [8]Ep = undefined;
    const got = selectSources(&watched, .{ .season = 2, .episode = 3 }, 4, &out);
    try testing.expectEqual(@as(usize, 3), got.len);
    for (got) |e| try testing.expect(isBefore(e, .{ .season = 2, .episode = 3 }));
    try testing.expectEqual(Ep{ .season = 1, .episode = 9 }, got[0]);
    try testing.expectEqual(Ep{ .season = 2, .episode = 2 }, got[2]);
}

test "REGRESSION: prompt drops a later-episode source even if a caller passes one" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const srcs = [_]Source{
        .{ .ep = .{ .season = 1, .episode = 1 }, .overview = "Mark joins Lumon." },
        .{ .ep = .{ .season = 1, .episode = 5 }, .overview = "SPOILER twist." },
        .{ .ep = .{ .season = 1, .episode = 2 }, .overview = "Current episode overview." },
    };
    const used = try writePrompt(&aw.writer, "Severance", .{ .season = 1, .episode = 2 }, &srcs);
    try testing.expectEqual(@as(usize, 1), used);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "SPOILER") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "Current episode") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "Mark joins Lumon.") != null);
}

test "only the most recent watched episodes are kept, in air order" {
    var watched: [12]Ep = undefined;
    for (&watched, 0..) |*w, i| w.* = .{ .season = 1, .episode = @intCast(12 - i) };
    var out: [8]Ep = undefined;
    const got = selectSources(&watched, .{ .season = 2, .episode = 1 }, 4, &out);
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqual(@as(i32, 9), got[0].episode);
    try testing.expectEqual(@as(i32, 12), got[3].episode);
}

test "nothing to recap on a pilot or with nothing watched" {
    var out: [4]Ep = undefined;
    try testing.expectEqual(@as(usize, 0), selectSources(&.{.{ .season = 1, .episode = 2 }}, .{ .season = 1, .episode = 1 }, 4, &out).len);
    try testing.expectEqual(@as(usize, 0), selectSources(&.{}, .{ .season = 3, .episode = 4 }, 4, &out).len);
}

test "transcripts beat overviews; thin transcripts don't" {
    const long = "word " ** 60;
    try testing.expectEqual(Kind.transcript, sourceKind(.{ .ep = .{ .season = 1, .episode = 1 }, .transcript = long, .overview = "o" }));
    try testing.expectEqual(Kind.overview, sourceKind(.{ .ep = .{ .season = 1, .episode = 1 }, .transcript = "short", .overview = "o" }));
    try testing.expectEqual(Kind.none, sourceKind(.{ .ep = .{ .season = 1, .episode = 1 } }));
}

test "transcript tail keeps the ending on a word boundary" {
    const t = "alpha beta gamma delta epsilon";
    try testing.expectEqualStrings("delta epsilon", transcriptTail(t, 14));
    try testing.expectEqualStrings(t, transcriptTail(t, 100));
}

test "clamp strips labels and fences and cuts at a sentence end" {
    var out: [512]u8 = undefined;
    try testing.expectEqualStrings("Mark learns the truth. Helly resists.", clampRecap("```\n**Previously on:** Mark learns the truth.\nHelly   resists.\n```", 900, &out));
    try testing.expectEqualStrings("One. Two.", clampRecap("Previously on Severance\nOne. Two. Three four five six", 12, &out));
    const cut = clampRecap("aaaa bbbb cccc dddd", 12, &out);
    try testing.expectEqualStrings("aaaa bbbb", cut);
}

test "cache key is per show, season and episode" {
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("95396:s2e3", cacheKey(&buf, 95396, .{ .season = 2, .episode = 3 }));
}

test "season JSON parse tolerates nulls and unknown fields" {
    const json = "{\"_id\":\"x\",\"episodes\":[{\"episode_number\":1,\"name\":\"Pilot\",\"overview\":\"A.\",\"crew\":[]},{\"episode_number\":2,\"overview\":null}]}";
    const p = try parseSeason(testing.allocator, json);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.value.episodes.len);
    try testing.expectEqualStrings("A.", p.value.episodes[0].overview.?);
    try testing.expect(p.value.episodes[1].overview == null);
}
