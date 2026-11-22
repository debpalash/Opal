//! Automatic chapters for files that ship none (ROADMAP 7.2).
//!
//! ffmpeg's scene filter scores keyframes (encoders place keyframes on cuts,
//! and decoding only keyframes keeps a 2-hour film to seconds of work); the
//! strongest cuts become chapter starts, spaced at least `minGap` apart, and
//! the intro/credits markers that markers.zig already detected are merged in
//! as named chapters so mpv's chapter UI and the chapter-title skip logic see
//! them. Pure: auto_chapters.zig routes production through every function
//! here, and tests/tools/chapters_probe.zig drives it on a generated clip.
const std = @import("std");

pub const MAX_CHAPTERS: usize = 32;
/// The ffmpeg select threshold (what is reported) and the stricter score a
/// cut needs to become a chapter.
pub const SELECT_EXPR = "scale=160:-2,select='gt(scene,0.3)',metadata=print:file=-";
pub const MIN_SCORE: f32 = 0.35;

pub const Cut = struct { time: f64, score: f32 };
pub const Kind = enum { chapter, intro, credits };
pub const Chapter = struct { start: f64, kind: Kind = .chapter };
pub const Span = struct { start: f64, end: f64 };

pub const SCENE_ARGC = 20;
pub fn sceneArgv(ffmpeg: []const u8, path: []const u8, out: *[SCENE_ARGC][]const u8) []const []const u8 {
    out.* = .{
        ffmpeg,      "-nostdin", "-v",   "error", "-threads", "1",   "-skip_frame", "nokey",
        "-i",        path,       "-map", "0:v:0", "-an",      "-sn", "-dn",         "-vf",
        SELECT_EXPR, "-f",       "null", "-",
    };
    return out[0..];
}

/// Parse `metadata=print` output: a `pts_time:<t>` frame line followed by its
/// `lavfi.scene_score=<s>` line. Returns cuts in stream order.
pub fn parseScenes(text: []const u8, out: []Cut) usize {
    var n: usize = 0;
    var pending: ?f64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, line, "pts_time:")) |i| {
            const rest = line[i + "pts_time:".len ..];
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            pending = std.fmt.parseFloat(f64, rest[0..end]) catch null;
            continue;
        }
        const key = "lavfi.scene_score=";
        if (std.mem.startsWith(u8, line, key)) {
            const t = pending orelse continue;
            pending = null;
            const s = std.fmt.parseFloat(f32, line[key.len..]) catch continue;
            if (!std.math.isFinite(t) or t < 0 or !std.math.isFinite(s)) continue;
            if (n >= out.len) break;
            out[n] = .{ .time = t, .score = s };
            n += 1;
        }
    }
    return n;
}

/// Shortest allowed chapter: 1/20 of the runtime, between 8 s and 4 min.
pub fn minGap(duration: f64) f64 {
    return std.math.clamp(duration / 20, 8, 240);
}

fn validSpan(s: ?Span, duration: f64) ?Span {
    const v = s orelse return null;
    if (!(v.end > v.start) or v.start < 0 or v.start >= duration) return null;
    return .{ .start = v.start, .end = @min(v.end, duration) };
}

fn inside(t: f64, s: ?Span) bool {
    const v = s orelse return false;
    return t >= v.start and t <= v.end;
}

fn farFromAll(t: f64, list: []const Chapter, gap: f64) bool {
    for (list) |c| if (@abs(c.start - t) < gap) return false;
    return true;
}

fn push(list: []Chapter, n: *usize, ch: Chapter) void {
    if (n.* >= list.len) return;
    // Anchors closer than a second collapse; the named one wins.
    for (list[0..n.*]) |*c| if (@abs(c.start - ch.start) < 1) {
        if (c.kind == .chapter) c.kind = ch.kind;
        return;
    };
    list[n.*] = ch;
    n.* += 1;
}

/// Chapters for a `duration`-second file. Anchors first (0, intro start/end,
/// credits start/end), then the strongest cuts that keep every chapter at
/// least `minGap` long and stay outside intro/credits. Returns 0 when the
/// result would be a single chapter — that is no better than none.
pub fn build(cuts: []const Cut, duration: f64, intro_raw: ?Span, credits_raw: ?Span, out: []Chapter) usize {
    if (!(duration > 0) or !std.math.isFinite(duration) or out.len == 0) return 0;
    const cap = @min(out.len, MAX_CHAPTERS);
    const list = out[0..cap];
    const gap = minGap(duration);
    const intro = validSpan(intro_raw, duration);
    const credits = validSpan(credits_raw, duration);
    var n: usize = 0;
    push(list, &n, .{ .start = 0 });
    if (intro) |s| {
        push(list, &n, .{ .start = s.start, .kind = .intro });
        if (s.end < duration - 1) push(list, &n, .{ .start = s.end });
    }
    if (credits) |s| {
        push(list, &n, .{ .start = s.start, .kind = .credits });
        if (s.end < duration - gap) push(list, &n, .{ .start = s.end });
    }
    while (n < cap) {
        var best: ?usize = null;
        for (cuts, 0..) |cut, i| {
            if (!(cut.score >= MIN_SCORE)) continue;
            if (cut.time < gap or cut.time > duration - gap) continue;
            if (inside(cut.time, intro) or inside(cut.time, credits)) continue;
            if (!farFromAll(cut.time, list[0..n], gap)) continue;
            if (best == null or cut.score > cuts[best.?].score) best = i;
        }
        const pick = best orelse break;
        list[n] = .{ .start = cuts[pick].time };
        n += 1;
    }
    std.mem.sort(Chapter, list[0..n], {}, struct {
        fn lt(_: void, a: Chapter, b: Chapter) bool {
            return a.start < b.start;
        }
    }.lt);
    return if (n >= 2) n else 0;
}

/// "Intro", "Credits", or "Chapter N" counting only plain chapters. These are
/// the words marker_match_pure.classifyChapter maps to intro/credits skips.
pub fn title(chapters: []const Chapter, index: usize, buf: []u8) []const u8 {
    return switch (chapters[index].kind) {
        .intro => "Intro",
        .credits => "Credits",
        .chapter => blk: {
            var ordinal: usize = 0;
            for (chapters[0 .. index + 1]) |c| {
                if (c.kind == .chapter) ordinal += 1;
            }
            break :blk std.fmt.bufPrint(buf, "Chapter {d}", .{ordinal}) catch "Chapter";
        },
    };
}

fn kindLetter(k: Kind) u8 {
    return switch (k) {
        .chapter => 'c',
        .intro => 'i',
        .credits => 'e',
    };
}

/// Storage text: one "<seconds> <c|i|e>" line per chapter. An empty string
/// is a valid result ("analysed, nothing worth adding").
pub fn encode(chapters: []const Chapter, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (chapters) |c| w.print("{d:.3} {c}\n", .{ c.start, kindLetter(c.kind) }) catch break;
    return w.buffered();
}

pub fn decode(text: []const u8, out: []Chapter) usize {
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (n >= out.len) break;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const t = std.fmt.parseFloat(f64, line[0..sp]) catch continue;
        if (!std.math.isFinite(t) or t < 0 or sp + 1 >= line.len) continue;
        const kind: Kind = switch (line[sp + 1]) {
            'c' => .chapter,
            'i' => .intro,
            'e' => .credits,
            else => continue,
        };
        out[n] = .{ .start = t, .kind = kind };
        n += 1;
    }
    return n;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseScenes reads ffmpeg metadata=print output" {
    const text =
        "frame:0    pts:256000  pts_time:20\r\n" ++
        "lavfi.scene_score=0.595169\r\n" ++
        "frame:1    pts:512000  pts_time:40.5\n" ++
        "lavfi.scene_score=0.662692\n" ++
        "lavfi.scene_score=0.9\n" ++ // orphan score: no frame line
        "frame:2 pts:1 pts_time:nan\nlavfi.scene_score=0.5\n";
    var cuts: [8]Cut = undefined;
    const n = parseScenes(text, &cuts);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectApproxEqAbs(@as(f64, 20), cuts[0].time, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 40.5), cuts[1].time, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 0.662692), cuts[1].score, 1e-6);
    try testing.expectEqual(@as(usize, 0), parseScenes("", &cuts));
}

test "minGap scales with runtime inside its clamp" {
    try testing.expectEqual(@as(f64, 8), minGap(60));
    try testing.expectEqual(@as(f64, 135), minGap(2700));
    try testing.expectEqual(@as(f64, 240), minGap(7200));
}

test "build keeps the strongest well-spaced cuts and drops weak or crowded ones" {
    // 60 s clip: gap 8 s.
    const cuts = [_]Cut{
        .{ .time = 3, .score = 0.9 }, // too close to the start
        .{ .time = 20, .score = 0.6 },
        .{ .time = 24, .score = 0.5 }, // crowded by 20
        .{ .time = 33, .score = 0.31 }, // below MIN_SCORE
        .{ .time = 40, .score = 0.66 },
        .{ .time = 57, .score = 0.8 }, // too close to the end
    };
    var out: [MAX_CHAPTERS]Chapter = undefined;
    const n = build(&cuts, 60, null, null, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(f64, 0), out[0].start);
    try testing.expectEqual(@as(f64, 20), out[1].start);
    try testing.expectEqual(@as(f64, 40), out[2].start);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Chapter 3", title(out[0..n], 2, &buf));
}

test "build merges intro and credits markers and keeps cuts out of them" {
    // 45 min episode: gap 135 s.
    const cuts = [_]Cut{
        .{ .time = 50, .score = 0.95 }, // inside the intro
        .{ .time = 600, .score = 0.7 },
        .{ .time = 1500, .score = 0.8 },
        .{ .time = 2600, .score = 0.99 }, // inside the credits
    };
    var out: [MAX_CHAPTERS]Chapter = undefined;
    const n = build(&cuts, 2700, .{ .start = 30, .end = 120 }, .{ .start = 2580, .end = 2700 }, &out);
    const want = [_]Chapter{
        .{ .start = 0 },
        .{ .start = 30, .kind = .intro },
        .{ .start = 120 },
        .{ .start = 600 },
        .{ .start = 1500 },
        .{ .start = 2580, .kind = .credits },
    };
    try testing.expectEqualSlices(Chapter, &want, out[0..n]);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Intro", title(out[0..n], 1, &buf));
    try testing.expectEqualStrings("Chapter 2", title(out[0..n], 2, &buf));
    try testing.expectEqualStrings("Credits", title(out[0..n], 5, &buf));
}

test "an intro at 0 names the first chapter and a lone chapter is dropped" {
    var out: [MAX_CHAPTERS]Chapter = undefined;
    const n = build(&.{}, 1800, .{ .start = 0.4, .end = 90 }, null, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(Kind.intro, out[0].kind);
    try testing.expectEqual(@as(f64, 90), out[1].start);
    // No cuts, no markers: one chapter is not worth adding.
    try testing.expectEqual(@as(usize, 0), build(&.{}, 1800, null, null, &out));
    try testing.expectEqual(@as(usize, 0), build(&.{}, 0, null, null, &out));
    // Garbage spans are ignored rather than trusted.
    try testing.expectEqual(@as(usize, 0), build(&.{}, 600, .{ .start = 50, .end = 10 }, .{ .start = 900, .end = 950 }, &out));
}

test "build never exceeds the output or MAX_CHAPTERS" {
    var cuts: [200]Cut = undefined;
    for (&cuts, 0..) |*c, i| c.* = .{ .time = @as(f64, @floatFromInt(i)) * 60 + 30, .score = 0.9 };
    var small: [4]Chapter = undefined;
    try testing.expectEqual(@as(usize, 4), build(&cuts, 12_000, null, null, &small));
    var big: [64]Chapter = undefined;
    try testing.expectEqual(MAX_CHAPTERS, build(&cuts, 12_000, null, null, &big));
}

test "encode/decode round-trip; empty text is an empty result" {
    const chapters = [_]Chapter{ .{ .start = 0, .kind = .intro }, .{ .start = 91.25 }, .{ .start = 1400, .kind = .credits } };
    var buf: [256]u8 = undefined;
    const text = encode(&chapters, &buf);
    try testing.expectEqualStrings("0.000 i\n91.250 c\n1400.000 e\n", text);
    var back: [8]Chapter = undefined;
    try testing.expectEqualSlices(Chapter, &chapters, back[0..decode(text, &back)]);
    try testing.expectEqual(@as(usize, 0), decode("", &back));
    try testing.expectEqual(@as(usize, 1), decode("x c\n5 z\n7 c\n", &back));
}

test "scene argv decodes keyframes only with the shipped filter" {
    var buf: [SCENE_ARGC][]const u8 = undefined;
    const a = sceneArgv("ffmpeg", "/m/film.mkv", &buf);
    try testing.expectEqualStrings("nokey", a[7]);
    try testing.expectEqualStrings("/m/film.mkv", a[9]);
    try testing.expectEqualStrings(SELECT_EXPR, a[16]);
    try testing.expectEqualStrings("-", a[a.len - 1]);
}
