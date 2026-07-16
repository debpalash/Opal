const std = @import("std");

// ══════════════════════════════════════════════════════════
//  Taste engine — PURE logic (no db, no state, no io_global).
//
//  Deterministic feature-hashing featurizer + recency-decayed
//  taste-profile math used by services/activity.zig. Local-only:
//  no network, no ML model — a title+genre string becomes a fixed
//  128-dim L2-normalized vector via token hashing, and the profile
//  is a decayed weighted mean of event vectors (finish positive,
//  abandon negative).
//
//  Registered standalone in build.zig's `test` step — keep this
//  file importable with only std.
// ══════════════════════════════════════════════════════════

/// Vector dimension — must match the `float[128]` in db.zig's vec_taste table.
pub const DIM: usize = 128;

/// Profile recency half-life in days.
pub const HALF_LIFE_DAYS: f64 = 14.0;

/// Activity event kinds (persisted by name into activity_log.kind).
pub const EventKind = enum { play, finish, abandon, search, queue_add };

// ── Tokenizer ──────────────────────────────────────────────

/// Tokens that carry release/quality/transport noise, not taste. Compared
/// case-insensitively against each alphanumeric token.
const STOP_TOKENS = [_][]const u8{
    "1080p", "720p",   "2160p", "480p",  "4k",    "8k",     "x264",
    "x265",  "h264",   "h265",  "hevc",  "avc",   "av1",    "bluray",
    "brrip", "bdrip",  "webrip", "webdl", "web",  "dl",     "hdtv",
    "dvdrip", "camrip", "hdcam", "aac",   "ac3",   "dts",    "atmos",
    "yify",  "yts",    "rarbg", "xvid",  "divx",  "10bit",  "8bit",
    "hdr",   "hdr10",  "dv",    "remux", "proper", "repack", "extended",
    "uncut", "remastered", "multi", "dual", "audio", "subs", "sub",
    "mkv",   "mp4",    "avi",   "webm",  "m4v",   "mov",    "flac",
    "mp3",   "opus",   "wav",   "the",   "a",     "an",     "and",
    "of",    "in",     "com",   "net",   "org",   "www",    "watch",
    "video", "movie",  "full",  "hd",    "part",  "vol",
};

fn isStopToken(tok: []const u8) bool {
    for (STOP_TOKENS) |s| {
        if (std.ascii.eqlIgnoreCase(s, tok)) return true;
    }
    return false;
}

/// Pure-digit year tokens (1900–2099) are stripped: "Movie (2023) 1080p" and
/// "Movie" must featurize identically. (Cost: numeric titles like "2049" in
/// "Blade Runner 2049" also drop — an accepted tradeoff for determinism.)
fn isYearToken(tok: []const u8) bool {
    if (tok.len != 4) return false;
    for (tok) |ch| if (!std.ascii.isDigit(ch)) return false;
    const first_two = (@as(u32, tok[0] - '0') * 10) + (tok[1] - '0');
    return first_two == 19 or first_two == 20;
}

/// Season/episode markers ("s01", "e05", "s01e05", "1x05") — structure, not taste.
fn isEpisodeToken(tok: []const u8) bool {
    if (tok.len < 2 or tok.len > 8) return false;
    var i: usize = 0;
    var saw_marker = false;
    var saw_digit = false;
    while (i < tok.len) : (i += 1) {
        const ch = std.ascii.toLower(tok[i]);
        if (ch == 's' or ch == 'e' or ch == 'x') {
            saw_marker = true;
        } else if (std.ascii.isDigit(ch)) {
            saw_digit = true;
        } else {
            return false;
        }
    }
    return saw_marker and saw_digit;
}

fn keepToken(tok: []const u8) bool {
    if (tok.len < 2) return false; // single chars are noise
    if (isStopToken(tok)) return false;
    if (isYearToken(tok)) return false;
    if (isEpisodeToken(tok)) return false;
    // Pure-numeric leftovers (episode numbers, resolutions) are noise too.
    var all_digit = true;
    for (tok) |ch| {
        if (!std.ascii.isDigit(ch)) {
            all_digit = false;
            break;
        }
    }
    return !all_digit;
}

const TokenIterator = struct {
    text: []const u8,
    pos: usize = 0,
    buf: [48]u8 = undefined,

    /// Next lowercased alphanumeric run that survives the noise filters.
    fn next(self: *TokenIterator) ?[]const u8 {
        while (self.pos < self.text.len) {
            // Skip separators.
            while (self.pos < self.text.len and !std.ascii.isAlphanumeric(self.text[self.pos]))
                self.pos += 1;
            const start = self.pos;
            while (self.pos < self.text.len and std.ascii.isAlphanumeric(self.text[self.pos]))
                self.pos += 1;
            if (self.pos == start) return null;
            const raw = self.text[start..self.pos];
            if (raw.len > self.buf.len) continue; // absurdly long run — noise
            for (raw, 0..) |ch, i| self.buf[i] = std.ascii.toLower(ch);
            const tok = self.buf[0..raw.len];
            if (keepToken(tok)) return tok;
        }
        return null;
    }
};

// ── Featurizer ─────────────────────────────────────────────

const TITLE_SEED: u64 = 0x7461737465; // "taste"
const GENRE_SEED: u64 = 0x67656e7265; // "genre"
const GENRE_WEIGHT: f32 = 1.5; // genres generalize better than title words

fn hashInto(vec: *[DIM]f32, text: []const u8, seed: u64, weight: f32) void {
    var it = TokenIterator{ .text = text };
    while (it.next()) |tok| {
        const h = std.hash.Wyhash.hash(seed, tok);
        const idx: usize = @intCast(h % DIM);
        // Sign bit from an independent region of the hash — keeps E[dot]≈0
        // between unrelated titles (standard feature-hashing trick).
        const sign: f32 = if ((h >> 32) & 1 == 1) 1.0 else -1.0;
        vec[idx] += sign * weight;
    }
}

/// Deterministic 128-dim feature-hash vector from a title + genre string
/// ("Action, Thriller"). L2-normalized. Returns false when no usable token
/// survived (vector left zeroed) so callers can skip storing it.
pub fn featurize(title: []const u8, genre: []const u8, out: *[DIM]f32) bool {
    @memset(out, 0);
    hashInto(out, title, TITLE_SEED, 1.0);
    hashInto(out, genre, GENRE_SEED, GENRE_WEIGHT);
    return normalize(out);
}

/// L2-normalize in place. Returns false (leaving the vector zeroed) for a
/// zero/non-finite vector.
pub fn normalize(vec: *[DIM]f32) bool {
    var norm_sq: f64 = 0;
    for (vec) |v| norm_sq += @as(f64, v) * v;
    const norm = std.math.sqrt(norm_sq);
    if (!(norm > 0) or !std.math.isFinite(norm)) {
        @memset(vec, 0);
        return false;
    }
    for (vec) |*v| v.* = @floatCast(@as(f64, v.*) / norm);
    return true;
}

// ── Profile math ───────────────────────────────────────────

/// Exponential recency decay: 1.0 now, 0.5 at one half-life, and so on.
/// Negative ages (clock skew) clamp to 1.0.
pub fn decayWeight(age_days: f64, half_life_days: f64) f64 {
    if (!(age_days > 0)) return 1.0;
    if (!(half_life_days > 0)) return 1.0;
    return std.math.pow(f64, 0.5, age_days / half_life_days);
}

/// Base weight per event kind. Finished items dominate; long-watched plays
/// count nearly as much; abandons subtract. Searches carry no item vector
/// (they log intent only) so they weigh 0 here.
pub fn eventWeight(kind: EventKind, percent_watched: f64) f64 {
    return switch (kind) {
        .finish => 1.0,
        .play => if (percent_watched >= 70.0) 0.8 else 0.3,
        .abandon => -0.6,
        .queue_add => 0.4,
        .search => 0.0,
    };
}

/// Accumulate `vec * weight` into the running f64 sum.
pub fn accumulate(sum: *[DIM]f64, vec: *const [DIM]f32, weight: f64) void {
    for (sum, vec) |*s, v| s.* += @as(f64, v) * weight;
}

/// Collapse the running sum into a normalized profile. Returns false when the
/// sum is zero/non-finite (no signal, or positives and negatives cancelled).
pub fn finishProfile(sum: *const [DIM]f64, out: *[DIM]f32) bool {
    var norm_sq: f64 = 0;
    for (sum) |s| norm_sq += s * s;
    const norm = std.math.sqrt(norm_sq);
    if (!(norm > 0) or !std.math.isFinite(norm)) {
        @memset(out, 0);
        return false;
    }
    for (out, sum) |*o, s| o.* = @floatCast(s / norm);
    return true;
}

/// Cosine similarity, safe on zero vectors (returns 0).
pub fn cosine(a: *const [DIM]f32, b: *const [DIM]f32) f64 {
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * y;
        na += @as(f64, x) * x;
        nb += @as(f64, y) * y;
    }
    if (!(na > 0) or !(nb > 0)) return 0;
    return dot / (std.math.sqrt(na) * std.math.sqrt(nb));
}

/// Final candidate score: cosine against the profile plus a small popularity
/// nudge (hint expected in [0,1], e.g. TMDB rating / 10) that breaks ties
/// without letting popularity outrank taste.
pub fn scoreCandidate(profile: *const [DIM]f32, candidate: *const [DIM]f32, popularity_hint: f64) f64 {
    const pop = std.math.clamp(if (std.math.isFinite(popularity_hint)) popularity_hint else 0, 0, 1);
    return cosine(profile, candidate) + 0.1 * pop;
}

/// Case-insensitive identity hash of a title's surviving tokens — used to
/// exclude already-watched candidates regardless of noise decoration.
pub fn titleHash(title: []const u8) u64 {
    var h: u64 = 0;
    var it = TokenIterator{ .text = title };
    while (it.next()) |tok| {
        // Order-independent combine so "Title 1080p" == "1080p Title".
        h +%= std.hash.Wyhash.hash(TITLE_SEED, tok);
    }
    return h;
}

/// Derive a display/feature title from a raw key (file path, URL, torrent
/// name): take the last path segment and drop any query string. Returns a
/// subslice of `raw` — tokenization handles the remaining dots/dashes.
pub fn deriveTitle(raw: []const u8) []const u8 {
    var s = raw;
    if (std.mem.indexOfScalar(u8, s, '?')) |q| s = s[0..q];
    if (std.mem.indexOfScalar(u8, s, '#')) |f| s = s[0..f];
    while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |slash| s = s[slash + 1 ..];
    return s;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "decayWeight: halves at each half-life, 1.0 at zero/negative age" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), decayWeight(0, 14), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), decayWeight(14, 14), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), decayWeight(28, 14), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), decayWeight(-5, 14), 1e-12);
}

test "eventWeight: finish positive, abandon negative, play scales with watch depth" {
    try std.testing.expect(eventWeight(.finish, 100) > 0);
    try std.testing.expect(eventWeight(.abandon, 20) < 0);
    try std.testing.expect(eventWeight(.play, 90) > eventWeight(.play, 10));
    try std.testing.expectEqual(@as(f64, 0), eventWeight(.search, 0));
}

test "featurize: deterministic, L2-normalized, strips year/quality noise" {
    var a: [DIM]f32 = undefined;
    var b: [DIM]f32 = undefined;
    try std.testing.expect(featurize("The.Matrix.1999.1080p.BluRay.x264-YIFY.mkv", "", &a));
    try std.testing.expect(featurize("matrix", "", &b));
    // Noise stripped → identical vectors.
    for (a, b) |x, y| try std.testing.expectApproxEqAbs(x, y, 1e-6);
    // Unit norm.
    var norm_sq: f64 = 0;
    for (a) |v| norm_sq += @as(f64, v) * v;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), norm_sq, 1e-6);
}

test "featurize: episode markers stripped, distinct titles differ" {
    var e1: [DIM]f32 = undefined;
    var e2: [DIM]f32 = undefined;
    try std.testing.expect(featurize("Severance S01E03 720p WEB", "", &e1));
    try std.testing.expect(featurize("Severance S02E07", "", &e2));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosine(&e1, &e2), 1e-6);

    var other: [DIM]f32 = undefined;
    try std.testing.expect(featurize("Grand Prix Driver", "", &other));
    try std.testing.expect(cosine(&e1, &other) < 0.99);
}

test "featurize: all-noise title yields zero vector and false" {
    var v: [DIM]f32 = undefined;
    try std.testing.expect(!featurize("1080p x264 2023.mkv", "", &v));
    for (v) |x| try std.testing.expectEqual(@as(f32, 0), x);
}

test "genre tokens contribute (shared genre raises similarity)" {
    var plain: [DIM]f32 = undefined;
    var with_genre: [DIM]f32 = undefined;
    var other_genre: [DIM]f32 = undefined;
    try std.testing.expect(featurize("Alpha Bravo", "", &plain));
    try std.testing.expect(featurize("Alpha Bravo", "Thriller", &with_genre));
    try std.testing.expect(featurize("Charlie Delta", "Thriller", &other_genre));
    // Genre changes the vector…
    try std.testing.expect(cosine(&plain, &with_genre) < 0.9999);
    // …and two different titles sharing a genre are more alike than random.
    try std.testing.expect(cosine(&with_genre, &other_genre) > 0.0);
}

test "cosine: identity 1, zero vector safe" {
    var v: [DIM]f32 = undefined;
    try std.testing.expect(featurize("Blade Runner", "Sci-Fi", &v));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosine(&v, &v), 1e-9);
    const zero: [DIM]f32 = std.mem.zeroes([DIM]f32);
    try std.testing.expectEqual(@as(f64, 0), cosine(&v, &zero));
    try std.testing.expectEqual(@as(f64, 0), cosine(&zero, &zero));
}

test "profile: finished items pull toward, abandons push away" {
    var liked: [DIM]f32 = undefined;
    var hated: [DIM]f32 = undefined;
    try std.testing.expect(featurize("Cosmic Odyssey", "Sci-Fi", &liked));
    try std.testing.expect(featurize("Mud Wrestling Gala", "Reality", &hated));

    var sum: [DIM]f64 = std.mem.zeroes([DIM]f64);
    accumulate(&sum, &liked, eventWeight(.finish, 100) * decayWeight(1, HALF_LIFE_DAYS));
    accumulate(&sum, &hated, eventWeight(.abandon, 15) * decayWeight(1, HALF_LIFE_DAYS));

    var profile: [DIM]f32 = undefined;
    try std.testing.expect(finishProfile(&sum, &profile));
    try std.testing.expect(cosine(&profile, &liked) > 0.5);
    try std.testing.expect(cosine(&profile, &hated) < 0.0);
}

test "finishProfile: zero sum returns false and zeroed output" {
    const sum: [DIM]f64 = std.mem.zeroes([DIM]f64);
    var out: [DIM]f32 = undefined;
    try std.testing.expect(!finishProfile(&sum, &out));
    for (out) |x| try std.testing.expectEqual(@as(f32, 0), x);
}

test "normalize: zero vector rejected" {
    var v: [DIM]f32 = std.mem.zeroes([DIM]f32);
    try std.testing.expect(!normalize(&v));
    v[3] = 2.0;
    try std.testing.expect(normalize(&v));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v[3], 1e-6);
}

test "scoreCandidate: popularity nudges but never outranks taste" {
    var profile: [DIM]f32 = undefined;
    var near: [DIM]f32 = undefined;
    var far: [DIM]f32 = undefined;
    try std.testing.expect(featurize("Cosmic Odyssey", "Sci-Fi", &profile));
    try std.testing.expect(featurize("Cosmic Odyssey Beyond", "Sci-Fi", &near));
    try std.testing.expect(featurize("Village Baking Diary", "Lifestyle", &far));
    // A very popular unrelated item must not beat a close match.
    try std.testing.expect(scoreCandidate(&profile, &near, 0.0) > scoreCandidate(&profile, &far, 1.0));
    // NaN popularity is clamped, not propagated.
    try std.testing.expect(std.math.isFinite(scoreCandidate(&profile, &near, std.math.nan(f64))));
}

test "titleHash: noise-insensitive, order-insensitive, distinct titles differ" {
    try std.testing.expectEqual(
        titleHash("The Matrix 1999 1080p"),
        titleHash("matrix"),
    );
    try std.testing.expect(titleHash("alpha bravo") == titleHash("bravo alpha"));
    try std.testing.expect(titleHash("matrix") != titleHash("inception"));
}

test "deriveTitle: basename, query/fragment stripped" {
    try std.testing.expectEqualStrings(
        "Show.S01E01.mkv",
        deriveTitle("/home/u/Videos/Show.S01E01.mkv"),
    );
    try std.testing.expectEqualStrings(
        "cool-doc",
        deriveTitle("https-host/videos/cool-doc?token=abc#t=1"),
    );
    try std.testing.expectEqualStrings("plain title", deriveTitle("plain title"));
    try std.testing.expectEqualStrings("dir", deriveTitle("/a/dir/"));
}
