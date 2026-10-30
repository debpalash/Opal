//! Intro / credits detection — pure (no io_global, no globals, unit-testable).
//!
//! Two ways to find skippable segments:
//!
//!  1. Audio fingerprints (fingerprint_pure.zig). Episodes of one season share
//!     their opening theme and end credits. For every pair of episodes we
//!     search all relative offsets of their print sequences for the longest
//!     aligned run whose smoothed Hamming distance stays low, then let the
//!     pairs vote per episode. Intros come from the first ~10 min ("head"),
//!     credits from the last ~6 min ("tail") and must end near EOF.
//!
//!  2. Chapter titles ("Opening", "OP", "Ending", "Credits", "Preview", …,
//!     plus common localized names) — instant, works for any media.
//!
//! The shipped worker (markers.zig) routes through these functions so the
//! tested logic IS the shipped logic.

const std = @import("std");
const fp = @import("fingerprint_pure.zig");
const skip = @import("anime_skip_pure.zig");

pub const Category = skip.Category;

pub const MIN_SEGMENT_S: f64 = 10;
pub const MAX_INTRO_S: f64 = 150;
pub const MAX_CREDITS_S: f64 = 300;
/// Credits must end within this many seconds of EOF (a short post-credits
/// scene or next-episode preview may follow).
pub const CREDITS_EOF_SLACK_S: f64 = 60;
pub const MAX_EPISODES: usize = 6;
pub const HEAD_SECONDS: f64 = 600;
pub const TAIL_SECONDS: f64 = 360;

// ══════════════════════════════════════════════════════════════════════════
// Pairwise alignment
// ══════════════════════════════════════════════════════════════════════════

pub const Params = struct {
    /// Smoothing window, in frames (~1.5 s).
    window: usize = 32,
    /// A window matches when its mean Hamming distance is at most this.
    max_mean_bits: u32 = 12,
    /// Runs shorter than this many frames are ignored.
    min_frames: usize = 1,
};

pub const Run = struct {
    a_start: usize,
    b_start: usize,
    len: usize,
    mean_bits: f32,
};

/// Longest aligned run shared by `a` and `b`, over every relative offset.
/// O(len(a) * len(b)) popcounts — fine for a background worker.
pub fn findCommonRun(a: []const u32, b: []const u32, p: Params) ?Run {
    const w = @max(p.window, 1);
    const na: isize = @intCast(a.len);
    const nb: isize = @intCast(b.len);
    if (na < w or nb < w) return null;
    const limit: u32 = @intCast(w * p.max_mean_bits);
    const min_len: isize = @intCast(@max(p.min_frames, w));

    var best: ?Run = null;
    var best_len: usize = 0;
    // b index = a index + k
    var k: isize = -(na - 1);
    while (k < nb) : (k += 1) {
        const ia0: isize = @max(0, -k);
        const ia1: isize = @min(na, nb - k);
        if (ia1 - ia0 < min_len) continue;
        if (@as(usize, @intCast(ia1 - ia0)) <= best_len) continue;

        var sum: u32 = 0;
        var run_start: isize = -1;
        var i: isize = ia0;
        while (i < ia1) : (i += 1) {
            const ua: usize = @intCast(i);
            const ub: usize = @intCast(i + k);
            sum += fp.distance(a[ua], b[ub]);
            if (i - ia0 >= w) {
                const oa: usize = @intCast(i - @as(isize, @intCast(w)));
                sum -= fp.distance(a[oa], b[@intCast(@as(isize, @intCast(oa)) + k)]);
            }
            if (i - ia0 + 1 < w) continue;
            const good = sum <= limit;
            if (good and run_start < 0) run_start = i - @as(isize, @intCast(w)) + 1;
            const at_end = i + 1 == ia1;
            if (run_start >= 0 and (!good or at_end)) {
                const end_excl: isize = if (good) i + 1 else i;
                if (refine(a, b, run_start, end_excl, k, p.max_mean_bits)) |r| {
                    if (r.len > best_len and r.len >= @as(usize, @intCast(min_len))) {
                        best_len = r.len;
                        best = r;
                    }
                }
                run_start = -1;
            }
        }
    }
    return best;
}

/// Trim a smoothed run's edges to the first/last individually-close frames
/// (the trailing window lets up to ~W/2 unrelated frames leak in at each end).
const EDGE_PROBE: isize = 8;

/// An edge frame must itself be clearly close (2 bits under the run
/// threshold) AND the mean over it + EDGE_PROBE-1 frames inward (bounded by
/// `stop`, exclusive, walking by `dir`) must be under the threshold.
fn edgeOk(a: []const u32, b: []const u32, at: isize, stop: isize, k: isize, dir: isize, max_bits: u32) bool {
    if (fp.distance(a[@intCast(at)], b[@intCast(at + k)]) + 2 > max_bits) return false;
    var sum: u32 = 0;
    var n: u32 = 0;
    var i = at;
    while (n < EDGE_PROBE and i != stop) : (i += dir) {
        sum += fp.distance(a[@intCast(i)], b[@intCast(i + k)]);
        n += 1;
    }
    return sum <= max_bits * n;
}

fn refine(a: []const u32, b: []const u32, s0: isize, e0: isize, k: isize, max_bits: u32) ?Run {
    var s = s0;
    var e = e0; // exclusive
    // An unrelated frame is individually "close" ~11% of the time, so judge
    // each edge frame together with its next EDGE_PROBE neighbours inward.
    while (s < e and !edgeOk(a, b, s, e, k, 1, max_bits)) s += 1;
    while (e > s and !edgeOk(a, b, e - 1, s - 1, k, -1, max_bits)) e -= 1;
    if (e <= s) return null;
    var sum: u64 = 0;
    var i = s;
    while (i < e) : (i += 1) sum += fp.distance(a[@intCast(i)], b[@intCast(i + k)]);
    const len: usize = @intCast(e - s);
    return .{
        .a_start = @intCast(s),
        .b_start = @intCast(s + k),
        .len = len,
        .mean_bits = @floatCast(@as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(len))),
    };
}

// ══════════════════════════════════════════════════════════════════════════
// Multi-episode voting
// ══════════════════════════════════════════════════════════════════════════

pub const Episode = struct {
    head: []const u32,
    tail: []const u32 = &.{},
    /// Absolute time (s) of tail[0].
    tail_offset_s: f64 = 0,
    duration_s: f64 = 0,
};

pub const Marker = struct {
    start: f64,
    end: f64,
    confidence: f32,
};

pub const Result = struct {
    intro: ?Marker = null,
    credits: ?Marker = null,
};

const Cand = struct { start: f64, end: f64, quality: f32 };

fn iou(a: Cand, b: Cand) f64 {
    const inter = @min(a.end, b.end) - @max(a.start, b.start);
    if (inter <= 0) return 0;
    const uni = @max(a.end, b.end) - @min(a.start, b.start);
    return inter / uni;
}

fn quality(mean_bits: f32) f32 {
    return std.math.clamp((16.0 - mean_bits) / 12.0, 0.0, 1.0);
}

/// Pick the candidate most others agree with; average the agreeing ones.
fn vote(cands: []const Cand, n_eps: usize) ?Marker {
    if (cands.len == 0 or n_eps < 2) return null;
    var best_i: usize = 0;
    var best_support: usize = 0;
    for (cands, 0..) |c, i| {
        var support: usize = 0;
        for (cands) |o| {
            if (iou(c, o) >= 0.5) support += 1;
        }
        if (support > best_support) {
            best_support = support;
            best_i = i;
        }
    }
    var s: f64 = 0;
    var e: f64 = 0;
    var q: f32 = 0;
    var n: usize = 0;
    for (cands) |o| {
        if (iou(cands[best_i], o) < 0.5) continue;
        s += o.start;
        e += o.end;
        q += o.quality;
        n += 1;
    }
    const nf: f64 = @floatFromInt(n);
    const agreement: f32 = @as(f32, @floatFromInt(best_support)) / @as(f32, @floatFromInt(n_eps - 1));
    const pair_factor: f32 = if (n_eps == 2) 0.8 else 1.0;
    const mean_q = q / @as(f32, @floatFromInt(n));
    return .{
        .start = s / nf,
        .end = e / nf,
        .confidence = std.math.clamp(@min(agreement, 1.0) * (0.5 + 0.5 * mean_q) * pair_factor, 0.0, 1.0),
    };
}

/// Detect intro + credits for up to MAX_EPISODES episodes of one season.
/// `out[i]` receives episode i's markers (null when nothing credible).
pub fn detect(eps: []const Episode, out: []Result) void {
    const n = @min(@min(eps.len, out.len), MAX_EPISODES);
    for (out[0..n]) |*r| r.* = .{};
    if (n < 2) return;
    const hop = fp.hopSeconds();
    const min_frames: usize = @intFromFloat(@ceil(MIN_SEGMENT_S / hop));
    const params = Params{ .min_frames = min_frames };

    var intro_c: [MAX_EPISODES][MAX_EPISODES]Cand = undefined;
    var intro_n = [_]usize{0} ** MAX_EPISODES;
    var cred_c: [MAX_EPISODES][MAX_EPISODES]Cand = undefined;
    var cred_n = [_]usize{0} ** MAX_EPISODES;

    for (0..n) |i| {
        for (i + 1..n) |j| {
            if (findCommonRun(eps[i].head, eps[j].head, params)) |r| {
                const len_s = @as(f64, @floatFromInt(r.len)) * hop;
                if (len_s >= MIN_SEGMENT_S and len_s <= MAX_INTRO_S) {
                    const q = quality(r.mean_bits);
                    const si = @as(f64, @floatFromInt(r.a_start)) * hop;
                    const sj = @as(f64, @floatFromInt(r.b_start)) * hop;
                    intro_c[i][intro_n[i]] = .{ .start = si, .end = si + len_s, .quality = q };
                    intro_n[i] += 1;
                    intro_c[j][intro_n[j]] = .{ .start = sj, .end = sj + len_s, .quality = q };
                    intro_n[j] += 1;
                }
            }
            if (eps[i].tail.len == 0 or eps[j].tail.len == 0) continue;
            if (findCommonRun(eps[i].tail, eps[j].tail, params)) |r| {
                const len_s = @as(f64, @floatFromInt(r.len)) * hop;
                if (len_s < MIN_SEGMENT_S or len_s > MAX_CREDITS_S) continue;
                const q = quality(r.mean_bits);
                const si = eps[i].tail_offset_s + @as(f64, @floatFromInt(r.a_start)) * hop;
                const sj = eps[j].tail_offset_s + @as(f64, @floatFromInt(r.b_start)) * hop;
                if (endsNearEof(si + len_s, eps[i].duration_s)) {
                    cred_c[i][cred_n[i]] = .{ .start = si, .end = si + len_s, .quality = q };
                    cred_n[i] += 1;
                }
                if (endsNearEof(sj + len_s, eps[j].duration_s)) {
                    cred_c[j][cred_n[j]] = .{ .start = sj, .end = sj + len_s, .quality = q };
                    cred_n[j] += 1;
                }
            }
        }
    }
    for (0..n) |i| {
        out[i].intro = vote(intro_c[i][0..intro_n[i]], n);
        out[i].credits = vote(cred_c[i][0..cred_n[i]], n);
    }
}

fn endsNearEof(end: f64, duration: f64) bool {
    if (duration <= 0) return false;
    return end >= duration - CREDITS_EOF_SLACK_S and end <= duration + 1;
}

// ══════════════════════════════════════════════════════════════════════════
// Chapter titles
// ══════════════════════════════════════════════════════════════════════════

const recap_words = [_][]const u8{ "recap", "previously", "zusammenfassung", "riassunto", "resumen", "résumé", "前回", "ранее", "Ранее", "前情提要", "지난" };
const preview_words = [_][]const u8{ "preview", "next episode", "next time", "vorschau", "anteprima", "avance", "prévia", "previa", "次回", "予告", "превью", "Превью", "预告", "예고" };
const intro_words = [_][]const u8{ "opening", "intro", "vorspann", "apertura", "abertura", "sigla iniziale", "générique de début", "generique de debut", "ncop", "title sequence", "main titles", "オープニング", "опенинг", "Опенинг", "заставка", "Заставка", "片头", "오프닝" };
const credits_words = [_][]const u8{ "ending", "credits", "credit", "outro", "abspann", "créditos", "creditos", "titoli di coda", "sigla finale", "encerramento", "générique de fin", "generique de fin", "générique fin", "nced", "エンディング", "эндинг", "Эндинг", "титры", "Титры", "片尾", "엔딩" };

fn isWordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch);
}

/// Case-insensitive (ASCII) search for `needle` in `hay` on word boundaries.
/// Non-ASCII needles (CJK, Cyrillic) match as plain substrings.
fn hasWord(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    const ascii_needle = for (needle) |ch| {
        if (ch >= 0x80) break false;
    } else true;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) continue;
        if (!ascii_needle) return true;
        const before_ok = i == 0 or !isWordByte(hay[i - 1]);
        const after = i + needle.len;
        // Allow a trailing digit ("Opening1", "OP2") but not letters ("Pending").
        const after_ok = after == hay.len or !std.ascii.isAlphabetic(hay[after]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

/// Is `tok` "op"/"ed" optionally followed by digits?
fn isShortTag(tok: []const u8, tag: []const u8) bool {
    if (tok.len > tag.len + 2) return false;
    if (tok.len < tag.len or !std.ascii.eqlIgnoreCase(tok[0..tag.len], tag)) return false;
    for (tok[tag.len..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// Map a chapter title to a skippable category, or null for story chapters.
pub fn classifyChapter(title: []const u8) ?Category {
    const t = std.mem.trim(u8, title, " \t\r\n");
    if (t.len == 0) return null;
    // "Opening Credits" is an intro, "Previously on" a recap — check the
    // more specific phrases first.
    if (hasWord(t, "opening credits") or hasWord(t, "opening titles")) return .intro;
    for (recap_words) |w| if (hasWord(t, w)) return .recap;
    for (preview_words) |w| if (hasWord(t, w)) return .preview;
    for (credits_words) |w| if (hasWord(t, w)) return .credits;
    for (intro_words) |w| if (hasWord(t, w)) return .intro;
    // Bare "OP" / "ED" / "OP2" tags — only in short titles so "Ed's Story"
    // or "Op. 27" style prose titles don't trip.
    var toks: usize = 0;
    var tag: ?Category = null;
    var it = std.mem.tokenizeAny(u8, t, " \t-_.:()[]");
    while (it.next()) |tok| {
        toks += 1;
        if (isShortTag(tok, "op")) tag = tag orelse .intro;
        if (isShortTag(tok, "ed")) tag = tag orelse .credits;
    }
    if (toks <= 3) return tag;
    return null;
}

pub const Chapter = struct {
    start: f64,
    title: []const u8,
};

pub const MAX_CHAPTER_SEGMENT_S: f64 = 600;

/// Chapters → skip segments. A chapter runs until the next chapter starts
/// (the last one until `duration`). Adjacent chapters of the same category
/// merge; implausible spans (<2 s or >10 min) are dropped.
pub fn chapterSegments(chapters: []const Chapter, duration: f64, out: []skip.Segment) usize {
    var n: usize = 0;
    for (chapters, 0..) |ch, i| {
        const cat = classifyChapter(ch.title) orelse continue;
        const end = if (i + 1 < chapters.len) chapters[i + 1].start else duration;
        if (!(end > ch.start)) continue;
        if (n > 0 and out[n - 1].category == cat and @abs(out[n - 1].end - ch.start) < 0.5) {
            out[n - 1].end = end;
            continue;
        }
        if (n >= out.len) break;
        out[n] = .{ .start = ch.start, .end = end, .category = cat };
        n += 1;
    }
    // Drop implausible spans (after merging).
    var k: usize = 0;
    for (out[0..n]) |s| {
        const len = s.end - s.start;
        if (len < 2 or len > MAX_CHAPTER_SEGMENT_S) continue;
        out[k] = s;
        k += 1;
    }
    return k;
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════
const testing = std.testing;

fn randomPrints(seed: u64, out: []u32) void {
    var rng = std.Random.DefaultPrng.init(seed);
    for (out) |*v| v.* = rng.random().int(u32) | 1;
}

/// Flip ~`bits` random bits per print (simulated re-encode noise).
fn jitter(seed: u64, bits: u32, buf: []u32) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (buf) |*v| {
        for (0..bits) |_| v.* ^= @as(u32, 1) << r.int(u5);
        if (v.* == 0) v.* = 1;
    }
}

test "findCommonRun locates a shared segment at different offsets" {
    var a: [3000]u32 = undefined;
    var b: [3000]u32 = undefined;
    var shared: [900]u32 = undefined;
    randomPrints(1, &a);
    randomPrints(2, &b);
    randomPrints(3, &shared);
    @memcpy(a[400..1300], &shared);
    @memcpy(b[1700..2600], &shared);
    jitter(4, 3, b[1700..2600]);
    const r = findCommonRun(&a, &b, .{ .min_frames = 100 }).?;
    try testing.expect(@abs(@as(i64, @intCast(r.a_start)) - 400) <= 2);
    try testing.expect(@abs(@as(i64, @intCast(r.b_start)) - 1700) <= 2);
    try testing.expect(@abs(@as(i64, @intCast(r.len)) - 900) <= 4);
    try testing.expect(r.mean_bits < 6);
}

test "findCommonRun: unrelated prints and silence never match" {
    var a: [1500]u32 = undefined;
    var b: [1500]u32 = undefined;
    randomPrints(10, &a);
    randomPrints(20, &b);
    try testing.expect(findCommonRun(&a, &b, .{ .min_frames = 100 }) == null);
    const z = [_]u32{fp.SILENT} ** 500;
    try testing.expect(findCommonRun(&z, &z, .{ .min_frames = 50 }) == null);
}

const Fake = struct {
    head: [4000]u32 = undefined, // ~186 s
    tail: [3000]u32 = undefined, // ~139 s
};

fn secsToFrames(s: f64) usize {
    return @intFromFloat(@round(s / fp.hopSeconds()));
}

test "detect: shared 50 s intro + 70 s credits across 3 fake episodes" {
    const fakes = try testing.allocator.alloc(Fake, 3);
    defer testing.allocator.free(fakes);
    var theme: [secsToFrames(50)]u32 = undefined;
    var ending: [secsToFrames(70)]u32 = undefined;
    randomPrints(77, &theme);
    randomPrints(78, &ending);
    const intro_at = [_]f64{ 12, 95.5, 3 };
    const dur = [_]f64{ 1400, 1325, 1460 };
    const credits_gap = [_]f64{ 0, 20, 45 }; // credits end this long before EOF
    var eps: [3]Episode = undefined;
    for (fakes, 0..) |*f, i| {
        randomPrints(100 + i, &f.head);
        randomPrints(200 + i, &f.tail);
        const s = secsToFrames(intro_at[i]);
        @memcpy(f.head[s .. s + theme.len], &theme);
        jitter(300 + i, 2, f.head[s .. s + theme.len]);
        const tail_off = dur[i] - @as(f64, @floatFromInt(f.tail.len)) * fp.hopSeconds();
        const cs = secsToFrames(dur[i] - credits_gap[i] - 70 - tail_off);
        @memcpy(f.tail[cs .. cs + ending.len], &ending);
        jitter(400 + i, 2, f.tail[cs .. cs + ending.len]);
        eps[i] = .{ .head = &f.head, .tail = &f.tail, .tail_offset_s = tail_off, .duration_s = dur[i] };
    }
    var res: [3]Result = undefined;
    detect(&eps, &res);
    for (0..3) |i| {
        const intro = res[i].intro.?;
        try testing.expect(@abs(intro.start - intro_at[i]) < 0.5);
        try testing.expect(@abs((intro.end - intro.start) - 50) < 0.6);
        try testing.expect(intro.confidence > 0.8);
        const cr = res[i].credits.?;
        try testing.expect(@abs(cr.end - (dur[i] - credits_gap[i])) < 0.6);
        try testing.expect(@abs((cr.end - cr.start) - 70) < 0.6);
    }
}

test "detect: rejects too-short / too-long intros and credits far from EOF" {
    const fakes = try testing.allocator.alloc(Fake, 2);
    defer testing.allocator.free(fakes);
    var short: [secsToFrames(7)]u32 = undefined;
    var mid: [secsToFrames(40)]u32 = undefined;
    randomPrints(5, &short);
    randomPrints(6, &mid);
    var eps: [2]Episode = undefined;
    for (fakes, 0..) |*f, i| {
        randomPrints(500 + i, &f.head);
        randomPrints(600 + i, &f.tail);
        const s = secsToFrames(30 + 10 * @as(f64, @floatFromInt(i)));
        @memcpy(f.head[s .. s + short.len], &short);
        // Shared 40 s in the tail, but ending 200 s before EOF.
        const m = secsToFrames(60);
        @memcpy(f.tail[m .. m + mid.len], &mid);
        eps[i] = .{ .head = &f.head, .tail = &f.tail, .tail_offset_s = 1000, .duration_s = 1360 };
    }
    var res: [2]Result = undefined;
    detect(&eps, &res);
    try testing.expect(res[0].intro == null and res[1].intro == null);
    try testing.expect(res[0].credits == null and res[1].credits == null);

    // A 160 s "shared intro" (e.g. the same file twice) is rejected too.
    var long_shared: [secsToFrames(160)]u32 = undefined;
    randomPrints(9, &long_shared);
    for (fakes) |*f| @memcpy(f.head[100 .. 100 + long_shared.len], &long_shared);
    detect(&eps, &res);
    try testing.expect(res[0].intro == null);
}

test "detect: 3 synthetic audio episodes, jingle at sub-hop offsets, end to end" {
    const sr = fp.SAMPLE_RATE;
    const ep_secs = 80;
    const jingle_secs = 40;
    const jingle = try testing.allocator.alloc(i16, sr * jingle_secs);
    defer testing.allocator.free(jingle);
    fp.synthMusic(4242, jingle);
    const offsets = [_]f64{ 5.31, 21.07, 13.777 };
    const s = try testing.allocator.create(fp.Scratch);
    defer testing.allocator.destroy(s);
    s.* = .{};
    var prints: [3][]u32 = undefined;
    var eps: [3]Episode = undefined;
    for (0..3) |i| {
        const pcm = try testing.allocator.alloc(i16, sr * ep_secs);
        defer testing.allocator.free(pcm);
        fp.synthMusic(1000 + i, pcm);
        const at: usize = @intFromFloat(offsets[i] * @as(f64, @floatFromInt(sr)));
        @memcpy(pcm[at .. at + jingle.len], jingle);
        fp.addNoise(77 + i, 0.01, pcm);
        prints[i] = try testing.allocator.alloc(u32, fp.frameCount(pcm.len));
        _ = fp.compute(pcm, prints[i], s);
        eps[i] = .{ .head = prints[i] };
    }
    defer for (prints) |p| testing.allocator.free(p);
    var res: [3]Result = undefined;
    detect(&eps, &res);
    for (0..3) |i| {
        const intro = res[i].intro.?;
        try testing.expect(@abs(intro.start - offsets[i]) < 1.0);
        try testing.expect(@abs(intro.end - (offsets[i] + jingle_secs)) < 1.0);
        try testing.expect(intro.confidence > 0.7);
    }
}

test "classifyChapter: english, tags, localized, and story chapters" {
    const C = Category;
    const cases = [_]struct { []const u8, ?C }{
        .{ "Opening", C.intro },          .{ "Intro", C.intro },
        .{ "OP", C.intro },               .{ "OP2", C.intro },
        .{ "Opening Credits", C.intro },  .{ "Ending", C.credits },
        .{ "ED", C.credits },             .{ "End Credits", C.credits },
        .{ "Credits", C.credits },        .{ "Preview", C.preview },
        .{ "Next Episode", C.preview },   .{ "Recap", C.recap },
        .{ "Previously on", C.recap },    .{ "Vorspann", C.intro },
        .{ "Abspann", C.credits },
        .{ "Générique de fin", C.credits },
        .{ "Créditos", C.credits },
        .{ "オープニング", C.intro },
        .{ "エンディング", C.credits },
        .{ "予告", C.preview },
        .{ "Титры", C.credits },
        .{ "Chapter 1", null },           .{ "Part A", null },
        .{ "Pending Doom", null },        .{ "Ed's Long Story Of The Day", null },
        .{ "", null },                    .{ "Introduction", null },
        .{ "Op. 27 in the Night", null },
    };
    for (cases) |cse| {
        const got = classifyChapter(cse[0]);
        if (got != cse[1]) {
            std.debug.print("classifyChapter({s}) = {any}, want {any}\n", .{ cse[0], got, cse[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "chapterSegments: ranges, last chapter to EOF, merging, implausible spans" {
    const chapters = [_]Chapter{
        .{ .start = 0, .title = "Prologue" },
        .{ .start = 62, .title = "Opening" },
        .{ .start = 152, .title = "Part A" },
        .{ .start = 1300, .title = "Ending" },
        .{ .start = 1390, .title = "Credits" },
        .{ .start = 1400, .title = "Preview" },
    };
    var out: [8]skip.Segment = undefined;
    const n = chapterSegments(&chapters, 1420, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(Category.intro, out[0].category);
    try testing.expectEqual(@as(f64, 62), out[0].start);
    try testing.expectEqual(@as(f64, 152), out[0].end);
    try testing.expectEqual(Category.credits, out[1].category); // Ending+Credits merged
    try testing.expectEqual(@as(f64, 1400), out[1].end);
    try testing.expectEqual(Category.preview, out[2].category);
    try testing.expectEqual(@as(f64, 1420), out[2].end);

    // A whole-episode "Intro" chapter (bad muxing) is not skippable.
    const bad = [_]Chapter{ .{ .start = 0, .title = "Intro" }, .{ .start = 1300, .title = "x" } };
    try testing.expectEqual(@as(usize, 0), chapterSegments(&bad, 1400, &out));
}
