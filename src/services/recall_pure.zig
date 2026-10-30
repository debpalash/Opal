//! Recall (ROADMAP 7.1) — the pure half of semantic library/moment search.
//!
//!   parse        natural-language constraint parser: "unwatched 90s anime under
//!                2 hours like Akira" → constraints + residual search text
//!   parseCues /  subtitle (SRT/WebVTT) cue parser and the ~20–40 s overlapping
//!   chunk        window chunker that turns cues into searchable "moments"
//!   fuse         reciprocal-rank fusion of the FTS (BM25) and vector (cosine)
//!                rankings, constraint filters and state boosts
//!   snippet      excerpt + highlight ranges around the matched terms
//!
//! Everything here is allocation-free and deterministic; recall_index.zig and
//! recall.zig route their production decisions through these functions.

const std = @import("std");

pub const Kind = enum { any, movie, show, anime, music, podcast, book, comic, other };
pub const Watch = enum { any, unwatched, unfinished, rewatch };

pub fn kindName(k: Kind) []const u8 {
    return @tagName(k);
}

pub const Constraints = struct {
    max_runtime_secs: u32 = 0,
    min_runtime_secs: u32 = 0,
    year_min: u16 = 0,
    year_max: u16 = 0,
    kind: Kind = .any,
    watch: Watch = .any,
    like: [128]u8 = std.mem.zeroes([128]u8),
    like_len: usize = 0,
    lang: [3]u8 = .{ 0, 0, 0 },
    lang_len: usize = 0,

    pub fn likeTitle(self: *const Constraints) []const u8 {
        return self.like[0..self.like_len];
    }
    pub fn langCode(self: *const Constraints) []const u8 {
        return self.lang[0..self.lang_len];
    }
    /// True when the query carried at least one structured constraint.
    pub fn active(self: *const Constraints) bool {
        return self.max_runtime_secs > 0 or self.min_runtime_secs > 0 or self.year_min > 0 or self.year_max > 0 or
            self.kind != .any or self.watch != .any or self.like_len > 0 or self.lang_len > 0;
    }
};

pub const MAX_TOKENS = 48;
pub const RESIDUAL_MAX = 256;

pub const Parsed = struct {
    constraints: Constraints = .{},
    residual: [RESIDUAL_MAX]u8 = std.mem.zeroes([RESIDUAL_MAX]u8),
    residual_len: usize = 0,
    /// The query reads like a sentence/request rather than a bare title.
    natural: bool = false,
    /// The query asks for a moment inside media ("the scene where …").
    moment: bool = false,

    pub fn text(self: *const Parsed) []const u8 {
        return self.residual[0..self.residual_len];
    }
};

// ── Tokenizer ────────────────────────────────────────────────────────────────

const Tok = struct {
    raw: []const u8, // original casing (residual output)
    low: []const u8, // lowercase copy in Tokens.lower
};

const Tokens = struct {
    items: [MAX_TOKENS]Tok = undefined,
    used: [MAX_TOKENS]bool = @splat(false),
    len: usize = 0,
    lower: [512]u8 = undefined,
    lower_len: usize = 0,

    fn push(self: *Tokens, raw: []const u8) void {
        if (raw.len == 0 or self.len >= MAX_TOKENS or self.lower_len + raw.len > self.lower.len) return;
        const start = self.lower_len;
        for (raw, 0..) |ch, i| self.lower[start + i] = std.ascii.toLower(ch);
        self.lower_len += raw.len;
        self.items[self.len] = .{ .raw = raw, .low = self.lower[start..self.lower_len] };
        self.len += 1;
    }

    fn low(self: *const Tokens, i: usize) []const u8 {
        return if (i < self.len) self.items[i].low else "";
    }
    fn is(self: *const Tokens, i: usize, word: []const u8) bool {
        return i < self.len and !self.used[i] and std.mem.eql(u8, self.items[i].low, word);
    }
    fn isAny(self: *const Tokens, i: usize, words: []const []const u8) bool {
        for (words) |w| if (self.is(i, w)) return true;
        return false;
    }
    fn take(self: *Tokens, from: usize, to: usize) void {
        var i = from;
        while (i < to and i < self.len) : (i += 1) self.used[i] = true;
    }
};

fn trimPunct(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, ",.;:!?()[]{}\"`");
}

fn tokenize(query: []const u8, out: *Tokens) void {
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (it.next()) |word_raw| {
        var word = trimPunct(word_raw);
        // "<45" / ">2h" split the comparator into its own token.
        while (word.len > 0 and (word[0] == '<' or word[0] == '>')) {
            out.push(word[0..1]);
            word = trimPunct(word[1..]);
        }
        // "≤" and friends are not worth the bytes; leave them as residual text.
        if (word.len > 0) out.push(word);
    }
}

// ── Number / duration helpers ────────────────────────────────────────────────

fn wordNumber(w: []const u8) ?f32 {
    const words = [_]struct { []const u8, f32 }{
        .{ "a", 1 },      .{ "an", 1 },     .{ "one", 1 },    .{ "two", 2 },      .{ "three", 3 },   .{ "four", 4 },
        .{ "five", 5 },   .{ "six", 6 },    .{ "ten", 10 },   .{ "fifteen", 15 }, .{ "twenty", 20 }, .{ "thirty", 30 },
        .{ "forty", 40 }, .{ "fifty", 50 }, .{ "sixty", 60 }, .{ "ninety", 90 },
    };
    for (words) |pair| if (std.mem.eql(u8, w, pair[0])) return pair[1];
    return null;
}

fn number(w: []const u8) ?f32 {
    if (w.len == 0 or w.len > 8) return wordNumber(w);
    for (w) |ch| if (!std.ascii.isDigit(ch) and ch != '.') return wordNumber(w);
    return std.fmt.parseFloat(f32, w) catch null;
}

const Unit = enum { hours, minutes };

fn unitOf(w: []const u8) ?Unit {
    const hours = [_][]const u8{ "h", "hr", "hrs", "hour", "hours" };
    const minutes = [_][]const u8{ "m", "min", "mins", "minute", "minutes" };
    for (hours) |u| if (std.mem.eql(u8, w, u)) return .hours;
    for (minutes) |u| if (std.mem.eql(u8, w, u)) return .minutes;
    return null;
}

fn secondsOf(value: f32, unit: Unit) u32 {
    if (!(value > 0) or value > 1000) return 0;
    const secs = switch (unit) {
        .hours => value * 3600,
        .minutes => value * 60,
    };
    return @intFromFloat(@round(secs));
}

/// A compact single-token duration: "2h", "90min", "1.5h", "45m", "1h30", "1h30m".
fn compactDuration(w: []const u8) ?u32 {
    var i: usize = 0;
    while (i < w.len and (std.ascii.isDigit(w[i]) or w[i] == '.')) i += 1;
    if (i == 0 or i == w.len) return null;
    const value = std.fmt.parseFloat(f32, w[0..i]) catch return null;
    var j = i;
    while (j < w.len and std.ascii.isAlphabetic(w[j])) j += 1;
    const unit = unitOf(w[i..j]) orelse return null;
    var secs = secondsOf(value, unit);
    if (secs == 0) return null;
    if (j < w.len and unit == .hours) {
        // 1h30 / 1h30m
        var k = j;
        while (k < w.len and std.ascii.isDigit(w[k])) k += 1;
        if (k == j) return null;
        const mins = std.fmt.parseInt(u32, w[j..k], 10) catch return null;
        const tail = w[k..];
        if (tail.len > 0 and unitOf(tail) != .minutes) return null;
        secs += mins * 60;
    } else if (j != w.len) return null;
    return secs;
}

const Span = struct { secs: u32, next: usize };

/// Duration starting at token `i`: "2 hours", "90 min", "2h", "an hour",
/// "half an hour", "1.5 hours".
fn durationAt(t: *const Tokens, i: usize) ?Span {
    if (i >= t.len or t.used[i]) return null;
    const w = t.low(i);
    if (compactDuration(w)) |secs| return .{ .secs = secs, .next = i + 1 };
    if (std.mem.eql(u8, w, "half") and t.is(i + 1, "an") and t.is(i + 2, "hour")) return .{ .secs = 1800, .next = i + 3 };
    if (number(w)) |value| {
        if (i + 1 < t.len and !t.used[i + 1]) {
            if (unitOf(t.low(i + 1))) |unit| {
                const secs = secondsOf(value, unit);
                if (secs > 0) return .{ .secs = secs, .next = i + 2 };
            }
        }
    }
    return null;
}

// ── Vocabulary ───────────────────────────────────────────────────────────────

pub fn kindFromWord(w: []const u8) ?Kind {
    const table = [_]struct { []const u8, Kind }{
        .{ "movie", .movie },     .{ "movies", .movie },     .{ "film", .movie },   .{ "films", .movie },
        .{ "show", .show },       .{ "shows", .show },       .{ "series", .show },  .{ "tv", .show },
        .{ "episodes", .show },   .{ "anime", .anime },      .{ "music", .music },  .{ "song", .music },
        .{ "songs", .music },     .{ "album", .music },      .{ "albums", .music }, .{ "tracks", .music },
        .{ "podcast", .podcast }, .{ "podcasts", .podcast }, .{ "book", .book },    .{ "books", .book },
        .{ "audiobook", .book },  .{ "audiobooks", .book },  .{ "novel", .book },   .{ "novels", .book },
        .{ "comic", .comic },     .{ "comics", .comic },     .{ "manga", .comic },
    };
    for (table) |pair| if (std.mem.eql(u8, w, pair[0])) return pair[1];
    return null;
}

pub fn langFromWord(w: []const u8) ?[]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "english", "en" },    .{ "japanese", "ja" },  .{ "korean", "ko" },  .{ "french", "fr" },
        .{ "spanish", "es" },    .{ "german", "de" },    .{ "italian", "it" }, .{ "chinese", "zh" },
        .{ "mandarin", "zh" },   .{ "cantonese", "zh" }, .{ "hindi", "hi" },   .{ "russian", "ru" },
        .{ "portuguese", "pt" }, .{ "swedish", "sv" },   .{ "danish", "da" },  .{ "norwegian", "no" },
        .{ "turkish", "tr" },    .{ "arabic", "ar" },    .{ "thai", "th" },    .{ "polish", "pl" },
        .{ "dutch", "nl" },
    };
    for (table) |pair| if (std.mem.eql(u8, w, pair[0])) return pair[1];
    return null;
}

/// Conversational words that carry no search meaning once constraints are out.
fn isFiller(w: []const u8) bool {
    const words = [_][]const u8{
        "find",     "me",        "i",        "i'm",    "im",     "i'd",  "want",    "wanna",   "to",    "watch",
        "watching", "something", "anything", "some",   "please", "that", "looking", "give",    "play",  "any",
        "my",       "can",       "you",      "could",  "would",  "a",    "an",      "with",    "about", "for",
        "where",    "when",      "scene",    "scenes", "part",   "bit",  "moment",  "moments", "one",   "which",
        "what",     "is",        "was",      "are",    "there",  "get",  "let's",   "lets",    "need",  "recommend",
        "of",       "and",
    };
    for (words) |f| if (std.mem.eql(u8, w, f)) return true;
    return false;
}

/// Words that only appear when someone is asking rather than naming a title.
fn isConversational(w: []const u8) bool {
    const words = [_][]const u8{
        "find",   "me",      "i",    "i'm",       "im",   "i'd", "want",  "wanna", "watch", "watching", "something", "anything",
        "please", "looking", "give", "recommend", "need", "can", "could", "would", "let's", "lets",     "my",
    };
    for (words) |f| if (std.mem.eql(u8, w, f)) return true;
    return false;
}

fn isMomentWord(w: []const u8) bool {
    const words = [_][]const u8{ "scene", "scenes", "moment", "moments", "part", "bit", "quote", "line" };
    for (words) |f| if (std.mem.eql(u8, w, f)) return true;
    return false;
}

/// "something new", "a short", "new movies": a modifier only counts as a
/// constraint in a request context, so "New Girl" / "Short Term 12" stay titles.
fn modifierContext(t: *const Tokens, i: usize) bool {
    if (i + 1 < t.len and kindFromWord(t.low(i + 1)) != null) return true;
    if (i > 0) {
        const prev = t.low(i - 1);
        const ctx = [_][]const u8{ "something", "anything", "some", "a", "an", "watch", "find", "me" };
        for (ctx) |c| if (std.mem.eql(u8, prev, c)) return true;
    }
    return false;
}

fn fourDigitYear(w: []const u8) ?u16 {
    if (w.len != 4) return null;
    for (w) |ch| if (!std.ascii.isDigit(ch)) return null;
    const y = std.fmt.parseInt(u16, w, 10) catch return null;
    return if (y >= 1900 and y <= 2099) y else null;
}

/// "90s", "'90s", "90's", "1990s", "2010s" → decade start.
fn decade(w_raw: []const u8) ?u16 {
    var w = w_raw;
    if (w.len > 0 and w[0] == '\'') w = w[1..];
    if (w.len < 3 or w[w.len - 1] != 's') return null;
    var digits = w[0 .. w.len - 1];
    if (digits.len > 0 and digits[digits.len - 1] == '\'') digits = digits[0 .. digits.len - 1];
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
    if (digits.len == 2) {
        const d = std.fmt.parseInt(u16, digits, 10) catch return null;
        if (d % 10 != 0) return null;
        return if (d <= 20) 2000 + d else 1900 + d;
    }
    if (digits.len == 4) {
        const d = std.fmt.parseInt(u16, digits, 10) catch return null;
        if (d % 10 != 0 or d < 1900 or d > 2090) return null;
        return d;
    }
    return null;
}

fn wordDecade(w: []const u8) ?u16 {
    const table = [_]struct { []const u8, u16 }{
        .{ "fifties", 1950 }, .{ "sixties", 1960 }, .{ "seventies", 1970 }, .{ "eighties", 1980 }, .{ "nineties", 1990 },
    };
    for (table) |pair| if (std.mem.eql(u8, w, pair[0])) return pair[1];
    return null;
}

// ── Parser ───────────────────────────────────────────────────────────────────

/// Parse a natural-language query into structured constraints and the residual
/// text that should be searched (FTS + embeddings). Never fails: anything it
/// does not recognise stays in the residual.
pub fn parse(query: []const u8) Parsed {
    var out = Parsed{};
    var t = Tokens{};
    tokenize(query, &t);
    const c = &out.constraints;

    // Multi-word conversational lead-ins first so "show me" is not a kind.
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t.is(i, "show") and t.is(i + 1, "me")) {
            t.take(i, i + 2);
            out.natural = true;
        }
    }

    // Runtime comparators.
    i = 0;
    while (i < t.len) : (i += 1) {
        if (t.used[i]) continue;
        var after: ?usize = null;
        var upper = true;
        if (t.isAny(i, &.{ "under", "below", "within", "<", "max", "maximum" })) {
            after = i + 1;
        } else if (t.isAny(i, &.{ "less", "shorter" }) and t.is(i + 1, "than")) {
            after = i + 2;
        } else if ((t.is(i, "up") and t.is(i + 1, "to")) or (t.is(i, "at") and t.is(i + 1, "most"))) {
            after = i + 2;
        } else if (t.is(i, "no") and t.is(i + 1, "longer") and t.is(i + 2, "than")) {
            after = i + 3;
        } else if (t.isAny(i, &.{ "over", "above", ">" })) {
            after = i + 1;
            upper = false;
        } else if (t.isAny(i, &.{ "more", "longer" }) and t.is(i + 1, "than")) {
            after = i + 2;
            upper = false;
        } else if (t.is(i, "at") and t.is(i + 1, "least")) {
            after = i + 2;
            upper = false;
        }
        const start = after orelse continue;
        const span = durationAt(&t, start) orelse continue;
        if (upper) c.max_runtime_secs = span.secs else c.min_runtime_secs = span.secs;
        t.take(i, span.next);
        out.natural = true;
    }

    // Era.
    i = 0;
    while (i < t.len) : (i += 1) {
        if (t.used[i]) continue;
        const w = t.low(i);
        if (decade(w) orelse wordDecade(w)) |d| {
            c.year_min = d;
            c.year_max = d + 9;
            var from = i;
            if (from > 0 and t.is(from - 1, "the")) from -= 1;
            if (from > 0 and t.isAny(from - 1, &.{ "from", "in", "of" })) from -= 1;
            t.take(from, i + 1);
            out.natural = true;
            continue;
        }
        if (t.is(i, "between") and i + 3 < t.len and t.is(i + 2, "and")) {
            if (fourDigitYear(t.low(i + 1))) |a| if (fourDigitYear(t.low(i + 3))) |b| {
                c.year_min = @min(a, b);
                c.year_max = @max(a, b);
                t.take(i, i + 4);
                out.natural = true;
                continue;
            };
        }
        const prep_end = i + 1;
        if (prep_end < t.len) if (fourDigitYear(t.low(prep_end))) |y| {
            if (t.is(i, "after")) {
                c.year_min = y + 1;
            } else if (t.isAny(i, &.{ "since", "from" })) {
                c.year_min = y;
            } else if (t.is(i, "before")) {
                c.year_max = y - 1;
            } else if (t.isAny(i, &.{ "until", "through" })) {
                c.year_max = y;
            } else if (t.is(i, "in")) {
                c.year_min = y;
                c.year_max = y;
            } else continue;
            t.take(i, prep_end + 1);
            out.natural = true;
            continue;
        };
        if (t.is(i, "classic") and modifierContext(&t, i)) {
            c.year_max = 1979;
            t.take(i, i + 1);
            out.natural = true;
        }
    }

    // Watch state (multi-word negatives before the bare "watched").
    i = 0;
    while (i < t.len) : (i += 1) {
        if (t.used[i]) continue;
        const neg = t.isAny(i, &.{ "haven't", "havent", "not", "never", "didn't", "didnt" });
        if (neg and t.isAny(i + 1, &.{ "seen", "watched", "finished", "finish" })) {
            const finish = t.isAny(i + 1, &.{ "finished", "finish" });
            c.watch = if (finish) .unfinished else .unwatched;
            t.take(i, i + 2);
            if (t.is(i + 2, "yet")) t.take(i + 2, i + 3);
            out.natural = true;
            continue;
        }
        if (neg and t.is(i + 1, "yet") and t.isAny(i + 2, &.{ "seen", "watched" })) {
            c.watch = .unwatched;
            t.take(i, i + 3);
            out.natural = true;
            continue;
        }
        if (t.isAny(i, &.{ "unwatched", "unseen" })) {
            c.watch = .unwatched;
        } else if (t.is(i, "new") and modifierContext(&t, i)) {
            c.watch = .unwatched;
        } else if (t.isAny(i, &.{ "unfinished", "half-watched", "started", "partially", "in-progress" })) {
            c.watch = .unfinished;
        } else if (t.is(i, "half") and t.is(i + 1, "watched")) {
            c.watch = .unfinished;
            t.take(i, i + 2);
            out.natural = true;
            continue;
        } else if (t.is(i, "in") and t.is(i + 1, "progress")) {
            c.watch = .unfinished;
            t.take(i, i + 2);
            out.natural = true;
            continue;
        } else if (t.isAny(i, &.{ "rewatch", "re-watch", "rewatches" })) {
            c.watch = .rewatch;
        } else if (t.is(i, "watch") and t.is(i + 1, "again")) {
            c.watch = .rewatch;
            t.take(i, i + 2);
            out.natural = true;
            continue;
        } else if (t.is(i, "already") and t.isAny(i + 1, &.{ "seen", "watched" })) {
            c.watch = .rewatch;
            t.take(i, i + 2);
            out.natural = true;
            continue;
        } else if (t.is(i, "watched") or (t.is(i, "seen") and t.is(i + 1, "before"))) {
            c.watch = .rewatch;
            if (t.is(i + 1, "before")) t.take(i + 1, i + 2);
        } else continue;
        t.take(i, i + 1);
        out.natural = true;
    }

    // Kind words before "about" describe the requested medium. After it,
    // they describe subject matter ("a story about making music").
    var saw_kind = false;
    i = 0;
    while (i < t.len) : (i += 1) {
        if (t.is(i, "about")) break;
        if (t.used[i]) continue;
        if (kindFromWord(t.low(i))) |k| {
            if (c.kind == .any) c.kind = k;
            t.take(i, i + 1);
            saw_kind = true;
            out.natural = true;
        }
    }

    // Short / quick: "a short movie", "something quick".
    i = 0;
    while (i < t.len) : (i += 1) {
        if (!t.isAny(i, &.{ "short", "quick" })) continue;
        if (!(saw_kind or modifierContext(&t, i))) continue;
        if (c.max_runtime_secs == 0) c.max_runtime_secs = 90 * 60;
        t.take(i, i + 1);
        out.natural = true;
    }

    // Language: "in Japanese" anywhere; a bare adjective only when the query is
    // already a structured request ("japanese horror movies", not "The French Dispatch").
    i = 0;
    while (i < t.len) : (i += 1) {
        if (t.used[i]) continue;
        if (t.is(i, "in") and i + 1 < t.len and !t.used[i + 1]) {
            if (langFromWord(t.low(i + 1))) |code| {
                setLang(c, code);
                t.take(i, i + 2);
                out.natural = true;
                continue;
            }
        }
        if (langFromWord(t.low(i))) |code| {
            if (saw_kind or c.active()) {
                setLang(c, code);
                t.take(i, i + 1);
                if (t.isAny(i + 1, &.{ "language", "dubbed", "subbed", "audio" })) t.take(i + 1, i + 2);
            }
        }
    }

    // "like <title>" / "similar to <title>": the contiguous unconsumed run after it.
    i = 0;
    while (i < t.len) : (i += 1) {
        var start: usize = 0;
        if (t.is(i, "like")) {
            start = i + 1;
        } else if (t.is(i, "similar") and t.is(i + 1, "to")) {
            start = i + 2;
        } else continue;
        var end = start;
        while (end < t.len and !t.used[end]) end += 1;
        if (end == start) continue;
        var n: usize = 0;
        for (t.items[start..end], 0..) |tok, k| {
            if (k > 0 and n < c.like.len) {
                c.like[n] = ' ';
                n += 1;
            }
            const m = @min(tok.raw.len, c.like.len - n);
            @memcpy(c.like[n .. n + m], tok.raw[0..m]);
            n += m;
        }
        c.like_len = n;
        // The "like" target is not part of the residual: it is a seed.
        t.take(i, end);
        if (i > 0 and t.isAny(i - 1, &.{ "something", "anything", "stuff", "more" })) t.take(i - 1, i);
        out.natural = true;
        break;
    }

    // Moment intent: any moment word, or a "where …"/"when …" clause.
    for (0..t.len) |k| {
        const w = t.low(k);
        if (isMomentWord(w)) out.moment = true;
        if (k > 0 and (std.mem.eql(u8, w, "where") or std.mem.eql(u8, w, "when"))) out.moment = true;
    }

    // Residual: unconsumed tokens, minus conversational filler when there is
    // anything left that is not filler.
    var meaningful: usize = 0;
    for (0..t.len) |k| {
        if (t.used[k]) continue;
        if (isConversational(t.low(k))) out.natural = true;
        if (!isFiller(t.low(k))) meaningful += 1;
    }
    if (t.len >= 5) out.natural = true;
    if (query.len > 0 and query[query.len - 1] == '?') out.natural = true;
    // A bare title keeps its words verbatim ("2001 A Space Odyssey").
    const strip = out.natural or out.moment;
    var n: usize = 0;
    for (0..t.len) |k| {
        if (t.used[k]) continue;
        if (strip and meaningful > 0 and isFiller(t.low(k))) continue;
        const raw = t.items[k].raw;
        if (n > 0 and n < out.residual.len) {
            out.residual[n] = ' ';
            n += 1;
        }
        const m = @min(raw.len, out.residual.len - n);
        @memcpy(out.residual[n .. n + m], raw[0..m]);
        n += m;
    }
    // Filler-only residuals ("something") carry nothing searchable.
    out.residual_len = if (meaningful == 0 and strip) 0 else n;
    return out;
}

test "subject matter does not become a media kind constraint" {
    const story = parse("a romantic story about performers making music");
    try std.testing.expectEqual(Kind.any, story.constraints.kind);
    try std.testing.expect(std.mem.indexOf(u8, story.text(), "music") != null);
    try std.testing.expectEqual(Kind.movie, parse("movies about music").constraints.kind);
    try std.testing.expectEqual(Kind.podcast, parse("podcasts about movies").constraints.kind);
    try std.testing.expectEqual(Kind.music, parse("nineties music").constraints.kind);
}

fn setLang(c: *Constraints, code: []const u8) void {
    const m = @min(code.len, c.lang.len);
    @memcpy(c.lang[0..m], code[0..m]);
    c.lang_len = m;
}

/// Universal search shows the recall sections only for natural-language or
/// constrained queries — a bare title keeps the plain source grid.
pub fn wantsRecall(p: *const Parsed) bool {
    return p.natural or p.moment or p.constraints.active();
}

// ── Search terms ─────────────────────────────────────────────────────────────

pub const MAX_TERMS = 8;

fn isStop(w: []const u8) bool {
    const words = [_][]const u8{ "the", "and", "of", "in", "on", "at", "is", "it", "to", "a", "an", "or" };
    for (words) |s| if (std.ascii.eqlIgnoreCase(w, s)) return true;
    return false;
}

fn termChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch >= 0x80 or ch == '\'';
}

/// Split `text` into search terms (lowercased into `buf`): alphanumeric runs of
/// 2+ bytes, stopwords dropped, at most MAX_TERMS.
pub fn terms(text: []const u8, buf: []u8, out: [][]const u8) usize {
    var n: usize = 0;
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) {
        while (i < text.len and !termChar(text[i])) i += 1;
        const start = i;
        while (i < text.len and termChar(text[i])) i += 1;
        var word = std.mem.trim(u8, text[start..i], "'");
        if (word.len < 2 or isStop(word)) continue;
        if (word.len > 48) word = word[0..48];
        if (used + word.len > buf.len) break;
        for (word, 0..) |ch, k| buf[used + k] = std.ascii.toLower(ch);
        const term = buf[used .. used + word.len];
        var dup = false;
        for (out[0..n]) |prev| if (std.mem.eql(u8, prev, term)) {
            dup = true;
        };
        if (dup) continue;
        // Terms stay contiguous in `buf` (callers re-point them after a copy).
        used += word.len;
        out[n] = term;
        n += 1;
    }
    return n;
}

/// FTS5 MATCH expression: every term quoted (apostrophes dropped), prefix-
/// matched when ≥ 3 bytes, OR-joined so BM25 ranks by how many terms hit.
/// Returns "" when there is nothing to match.
pub fn ftsQuery(text: []const u8, out: []u8) []const u8 {
    var term_buf: [256]u8 = undefined;
    var list: [MAX_TERMS][]const u8 = undefined;
    const count = terms(text, &term_buf, &list);
    var w = std.Io.Writer.fixed(out);
    for (list[0..count], 0..) |term, k| {
        if (k > 0) w.writeAll(" OR ") catch return "";
        w.writeByte('"') catch return "";
        for (term) |ch| if (ch != '\'' and ch != '"') w.writeByte(ch) catch return "";
        w.writeByte('"') catch return "";
        if (term.len >= 3) w.writeByte('*') catch return "";
    }
    return w.buffered();
}

/// How many distinct terms occur (case-insensitively) in `text`.
pub fn termHits(text: []const u8, term_list: []const []const u8) usize {
    var n: usize = 0;
    for (term_list) |term| {
        if (term.len > 0 and std.ascii.indexOfIgnoreCase(text, term) != null) n += 1;
    }
    return n;
}

/// A moment found only by keywords must match at least half of the query's
/// terms (all of them for one or two terms) — a single common word ("they")
/// is not a moment. Vector hits are judged by the embedding instead.
pub fn momentRelevant(hits: usize, term_count: usize, vector_hit: bool) bool {
    if (vector_hit) return true;
    if (term_count == 0) return false;
    if (term_count <= 2) return hits == term_count;
    return hits * 2 >= term_count;
}

fn putSep(w: *std.Io.Writer, first: *bool) void {
    if (!first.*) w.writeAll(" \u{b7} ") catch {};
    first.* = false;
}

fn putDuration(w: *std.Io.Writer, first: *bool, secs: u32, prefix: []const u8) void {
    if (secs == 0) return;
    putSep(w, first);
    const mins = secs / 60;
    if (mins % 60 == 0) {
        w.print("{s}{d}h", .{ prefix, mins / 60 }) catch {};
    } else w.print("{s}{d} min", .{ prefix, mins }) catch {};
}

/// Human summary of the parsed constraints: "movie · under 2h · 1990s · unwatched".
pub fn describe(c: *const Constraints, out: []u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    var first = true;
    if (c.kind != .any) {
        putSep(&w, &first);
        w.writeAll(@tagName(c.kind)) catch {};
    }
    putDuration(&w, &first, c.max_runtime_secs, "under ");
    putDuration(&w, &first, c.min_runtime_secs, "over ");
    if (c.year_min > 0 or c.year_max > 0) {
        putSep(&w, &first);
        if (c.year_min > 0 and c.year_max == c.year_min + 9 and c.year_min % 10 == 0) {
            w.print("{d}s", .{c.year_min}) catch {};
        } else if (c.year_min > 0 and c.year_max == c.year_min) {
            w.print("{d}", .{c.year_min}) catch {};
        } else if (c.year_min > 0 and c.year_max > 0) {
            w.print("{d}\u{2013}{d}", .{ c.year_min, c.year_max }) catch {};
        } else if (c.year_min > 0) {
            w.print("from {d}", .{c.year_min}) catch {};
        } else w.print("before {d}", .{c.year_max + 1}) catch {};
    }
    if (c.watch != .any) {
        putSep(&w, &first);
        w.writeAll(switch (c.watch) {
            .unwatched => "unwatched",
            .unfinished => "unfinished",
            .rewatch => "watched before",
            .any => "",
        }) catch {};
    }
    if (c.lang_len > 0) {
        putSep(&w, &first);
        w.print("language {s}", .{c.langCode()}) catch {};
    }
    if (c.like_len > 0) {
        putSep(&w, &first);
        w.print("like {s}", .{c.likeTitle()}) catch {};
    }
    return w.buffered();
}

// ── Subtitles → moments ──────────────────────────────────────────────────────

pub const Cue = struct {
    start_ms: u32,
    end_ms: u32,
    text: []const u8, // raw cue text (may contain tags/newlines)
};

fn parseClock(s_raw: []const u8) ?u32 {
    const s = std.mem.trim(u8, s_raw, " \t\r");
    // [HH:]MM:SS[,.]mmm
    var parts: [3]u32 = .{ 0, 0, 0 };
    var count: usize = 0;
    var frac_ms: u32 = 0;
    var it = std.mem.splitScalar(u8, s, ':');
    while (it.next()) |part| {
        if (count >= 3) return null;
        var whole = part;
        if (std.mem.indexOfAny(u8, part, ",.")) |dot| {
            whole = part[0..dot];
            const frac = part[dot + 1 ..];
            if (frac.len == 0 or frac.len > 3) return null;
            var f = std.fmt.parseInt(u32, frac, 10) catch return null;
            var pad = frac.len;
            while (pad < 3) : (pad += 1) f *= 10;
            frac_ms = f;
        }
        parts[count] = std.fmt.parseInt(u32, whole, 10) catch return null;
        count += 1;
    }
    const total_s: u64 = switch (count) {
        2 => @as(u64, parts[0]) * 60 + parts[1],
        3 => @as(u64, parts[0]) * 3600 + @as(u64, parts[1]) * 60 + parts[2],
        else => return null,
    };
    const ms = total_s * 1000 + frac_ms;
    return if (ms > std.math.maxInt(u32)) null else @intCast(ms);
}

/// Parse SRT or WebVTT into cues (text slices alias `src`). Malformed blocks
/// are skipped; cues are returned in file order.
pub fn parseCues(src: []const u8, out: []Cue) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var current: ?Cue = null;
    var text_start: usize = 0;
    var text_end: usize = 0;
    while (lines.next()) |line_raw| {
        const line_start = @intFromPtr(line_raw.ptr) - @intFromPtr(src.ptr);
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (std.mem.indexOf(u8, line, "-->")) |arrow| {
            if (current) |cue| {
                if (n < out.len and text_end > text_start) {
                    out[n] = .{ .start_ms = cue.start_ms, .end_ms = cue.end_ms, .text = src[text_start..text_end] };
                    n += 1;
                }
            }
            current = null;
            const left = line[0..arrow];
            var right = std.mem.trimStart(u8, line[arrow + 3 ..], " \t");
            if (std.mem.indexOfAny(u8, right, " \t")) |sp| right = right[0..sp]; // VTT cue settings
            const a = parseClock(left) orelse continue;
            const b = parseClock(right) orelse continue;
            if (b < a) continue;
            current = .{ .start_ms = a, .end_ms = b, .text = "" };
            text_start = line_start + line_raw.len + 1;
            text_end = text_start;
            continue;
        }
        if (current == null) continue;
        if (std.mem.trim(u8, line, " \t").len == 0) {
            if (n < out.len and text_end > text_start) {
                out[n] = .{ .start_ms = current.?.start_ms, .end_ms = current.?.end_ms, .text = src[text_start..text_end] };
                n += 1;
            }
            current = null;
            continue;
        }
        text_end = line_start + line.len;
    }
    if (current) |cue| if (n < out.len and text_end > text_start and text_end <= src.len) {
        out[n] = .{ .start_ms = cue.start_ms, .end_ms = cue.end_ms, .text = src[text_start..text_end] };
        n += 1;
    };
    return n;
}

/// Strip markup (<i>, </font>, {\an8}) and collapse whitespace, appending to `w`.
fn appendClean(w: *std.Io.Writer, text: []const u8, need_space: *bool) void {
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '<') {
            if (std.mem.indexOfScalarPos(u8, text, i, '>')) |end| {
                i = end + 1;
                continue;
            }
        }
        if (ch == '{') {
            if (std.mem.indexOfScalarPos(u8, text, i, '}')) |end| {
                i = end + 1;
                continue;
            }
        }
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            need_space.* = true;
            i += 1;
            continue;
        }
        if (need_space.*) {
            w.writeByte(' ') catch return;
            need_space.* = false;
        }
        w.writeByte(ch) catch return;
        i += 1;
    }
}

pub const Window = struct {
    start_ms: u32,
    end_ms: u32,
    first: usize, // index of the first cue
    count: usize, // cues in the window
};

pub const ChunkOpts = struct {
    min_ms: u32 = 20_000,
    target_ms: u32 = 30_000,
    max_ms: u32 = 40_000,
    overlap_ms: u32 = 5_000,
};

/// Group cues into ~20–40 s windows. A window closes once it reaches
/// `target_ms`, or before a cue would push it past `max_ms` (a single cue
/// longer than max still forms its own window). The next window starts at the
/// first cue beginning within `overlap_ms` of the previous window's end, so a
/// line said across a boundary is findable from either side. Always advances.
pub fn chunk(cues: []const Cue, opts: ChunkOpts, out: []Window) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < cues.len and n < out.len) {
        const start = cues[i].start_ms;
        var j = i;
        var end = cues[i].end_ms;
        while (j + 1 < cues.len) {
            const span = end -| start;
            if (span >= opts.target_ms) break;
            const next_end = @max(end, cues[j + 1].end_ms);
            if (next_end -| start > opts.max_ms) break;
            j += 1;
            end = next_end;
        }
        out[n] = .{ .start_ms = start, .end_ms = end, .first = i, .count = j - i + 1 };
        n += 1;
        if (j + 1 >= cues.len) break;
        // Overlap: step back to the earliest cue that starts within overlap_ms
        // of this window's end, but strictly after this window's first cue.
        var next = j + 1;
        const cutoff = end -| opts.overlap_ms;
        while (next - 1 > i and cues[next - 1].start_ms >= cutoff) next -= 1;
        i = next;
    }
    return n;
}

/// The cleaned, space-joined text of a window.
pub fn windowText(cues: []const Cue, win: Window, out: []u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    var need_space = false;
    const last = @min(win.first + win.count, cues.len);
    for (cues[win.first..last]) |cue| {
        need_space = w.end > 0;
        appendClean(&w, cue.text, &need_space);
    }
    return w.buffered();
}

/// Is `file` a subtitle sidecar of the media whose basename-without-extension
/// is `stem`? Matches `stem.srt`, `stem.vtt`, `stem.en.srt`, `stem.auto.srt`,
/// `stem.eng.forced.srt`. Returns the language tag ("" when none / auto).
pub fn sidecarLang(stem: []const u8, file: []const u8) ?[]const u8 {
    if (stem.len == 0 or file.len <= stem.len or !std.mem.startsWith(u8, file, stem)) return null;
    const rest = file[stem.len..];
    if (rest[0] != '.') return null;
    const lower_ok = std.ascii.endsWithIgnoreCase(rest, ".srt") or std.ascii.endsWithIgnoreCase(rest, ".vtt");
    if (!lower_ok) return null;
    if (rest.len <= 5) return ""; // "stem.srt"
    const middle = rest[1 .. rest.len - 4]; // "en" | "auto" | "eng.forced"
    const tag_end = std.mem.indexOfScalar(u8, middle, '.') orelse middle.len;
    const tag = middle[0..tag_end];
    if (tag.len >= 2 and tag.len <= 3) {
        for (tag) |ch| if (!std.ascii.isAlphabetic(ch)) return "";
        return tag;
    }
    return "";
}

/// Copy `in` to `out` replacing every byte that is not part of a valid UTF-8
/// sequence with '?' (Latin-1 subtitle files would otherwise poison the JSON
/// sent to the embedder and the web UI). Returns the written prefix.
pub fn sanitizeUtf8(in: []const u8, out: []u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < in.len and n < out.len) {
        const len = std.unicode.utf8ByteSequenceLength(in[i]) catch {
            out[n] = '?';
            n += 1;
            i += 1;
            continue;
        };
        if (i + len > in.len or n + len > out.len) {
            if (n + len > out.len and i + len <= in.len) break;
            out[n] = '?';
            n += 1;
            i += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(in[i .. i + len]) catch {
            out[n] = '?';
            n += 1;
            i += 1;
            continue;
        };
        @memcpy(out[n .. n + len], in[i .. i + len]);
        n += len;
        i += len;
    }
    return out[0..n];
}

/// Longest prefix of `s` of at most `max` bytes that does not split a UTF-8
/// sequence.
pub fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// ── Filename heuristics (local files carry no metadata) ─────────────────────

/// Last standalone 19xx/20xx in a file or display name ("Heat.1995.1080p" → 1995).
pub fn yearFromName(name: []const u8) u16 {
    var best: u16 = 0;
    var i: usize = 0;
    while (i + 4 <= name.len) : (i += 1) {
        if (i > 0 and std.ascii.isDigit(name[i - 1])) continue;
        if (i + 4 < name.len and std.ascii.isDigit(name[i + 4])) continue;
        if (fourDigitYear(name[i .. i + 4])) |y| best = y;
    }
    return best;
}

fn hasEpisodeMarker(name: []const u8) bool {
    var i: usize = 0;
    while (i + 3 < name.len) : (i += 1) {
        const s = name[i];
        if ((s != 's' and s != 'S') or !std.ascii.isDigit(name[i + 1])) continue;
        var j = i + 1;
        while (j < name.len and std.ascii.isDigit(name[j])) j += 1;
        if (j + 1 < name.len and (name[j] == 'e' or name[j] == 'E') and std.ascii.isDigit(name[j + 1])) return true;
    }
    return false;
}

/// Media kind for a local file from its name: audio extensions → music,
/// SxxEyy → show, other video → movie.
pub fn kindFromFilename(name: []const u8) Kind {
    const audio = [_][]const u8{ ".mp3", ".flac", ".wav", ".ogg", ".opus", ".oga", ".aac", ".m4a", ".mka", ".wma", ".aiff" };
    for (audio) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return .music;
    if (hasEpisodeMarker(name)) return .show;
    return .movie;
}

/// `library_items.kind` → recall kind.
pub fn kindFromLibrary(kind: []const u8, name: []const u8) Kind {
    const table = [_]struct { []const u8, Kind }{
        .{ "movie", .movie },  .{ "tv", .show },         .{ "anime", .anime },    .{ "music", .music },
        .{ "radio", .music },  .{ "podcast", .podcast }, .{ "audiobook", .book }, .{ "novels", .book },
        .{ "comics", .comic }, .{ "iptv", .other },
    };
    for (table) |pair| if (std.mem.eql(u8, kind, pair[0])) return pair[1];
    if (std.mem.eql(u8, kind, "watch")) return kindFromFilename(name);
    return .other;
}

pub fn kindFromName(name: []const u8) Kind {
    inline for (std.meta.fields(Kind)) |f| if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
    return .other;
}

// ── Rank fusion ──────────────────────────────────────────────────────────────

pub const RRF_K: f64 = 60;
pub const WATCHED_PCT: f32 = 95;
pub const STARTED_PCT: f32 = 2;

pub const Candidate = struct {
    id: i64,
    fts_rank: u32 = 0, // 1-based position in the BM25/LIKE list; 0 = absent
    vec_rank: u32 = 0, // 1-based position in the cosine KNN list; 0 = absent
    kind: Kind = .other,
    year: u16 = 0,
    runtime_secs: u32 = 0,
    percent: f32 = 0,
    favorite: bool = false,
    updated_at: i64 = 0, // last time the user touched it (library_items)
    lang: [3]u8 = .{ 0, 0, 0 },
    lang_len: usize = 0,
    score: f64 = 0,
};

fn kindAdmits(want: Kind, have: Kind) bool {
    if (want == .any or want == have) return true;
    // Anime is a show (and sometimes a movie) to a user asking for either.
    if (have == .anime and (want == .show or want == .movie)) return true;
    return false;
}

/// Hard filters. Unknown runtime/year (0) is admitted — local files often lack
/// metadata — and pays a small penalty in `fuse` instead.
pub fn admits(c: *const Constraints, cand: *const Candidate) bool {
    if (!kindAdmits(c.kind, cand.kind)) return false;
    if (cand.runtime_secs > 0) {
        if (c.max_runtime_secs > 0 and cand.runtime_secs > c.max_runtime_secs) return false;
        if (c.min_runtime_secs > 0 and cand.runtime_secs < c.min_runtime_secs) return false;
    }
    if (cand.year > 0) {
        if (c.year_min > 0 and cand.year < c.year_min) return false;
        if (c.year_max > 0 and cand.year > c.year_max) return false;
    }
    switch (c.watch) {
        .any => {},
        .unwatched => if (cand.percent >= STARTED_PCT) return false,
        .unfinished => if (cand.percent < STARTED_PCT or cand.percent >= WATCHED_PCT) return false,
        .rewatch => if (cand.percent < WATCHED_PCT) return false,
    }
    return true;
}

fn lessThan(_: void, a: Candidate, b: Candidate) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.id < b.id;
}

/// Score, filter and order candidates in place; returns how many survive.
/// `browse` = the query had no searchable text (constraints only), so rank by
/// state boosts alone instead of dropping everything without a text hit.
pub fn fuse(cands: []Candidate, c: *const Constraints, now: i64, browse: bool) usize {
    var kept: usize = 0;
    for (cands) |cand_in| {
        var cand = cand_in;
        if (!admits(c, &cand)) continue;
        var score: f64 = 0;
        if (cand.fts_rank > 0) score += 1.0 / (RRF_K + @as(f64, @floatFromInt(cand.fts_rank)));
        if (cand.vec_rank > 0) score += 1.0 / (RRF_K + @as(f64, @floatFromInt(cand.vec_rank)));
        if (score == 0 and !browse) continue;
        // Boosts are sized below one RRF rank step near the top (~0.0003–0.016)
        // so they reorder near-ties without burying a clearly better text hit.
        if (cand.percent >= STARTED_PCT and cand.percent < WATCHED_PCT) score += 0.004;
        if (cand.favorite) score += 0.003;
        if (cand.updated_at > 0 and now > cand.updated_at) {
            const age_days = @as(f64, @floatFromInt(now - cand.updated_at)) / 86400.0;
            if (age_days < 30) score += 0.003 * (1.0 - age_days / 30.0);
        }
        if (c.lang_len > 0 and cand.lang_len == c.lang_len and std.mem.eql(u8, cand.lang[0..cand.lang_len], c.lang[0..c.lang_len])) score += 0.004;
        const runtime_asked = c.max_runtime_secs > 0 or c.min_runtime_secs > 0;
        if (runtime_asked and cand.runtime_secs == 0) score -= 0.002;
        const year_asked = c.year_min > 0 or c.year_max > 0;
        if (year_asked and cand.year == 0) score -= 0.002;
        cand.score = score;
        cands[kept] = cand;
        kept += 1;
    }
    std.mem.sort(Candidate, cands[0..kept], {}, lessThan);
    return kept;
}

// ── Snippets ─────────────────────────────────────────────────────────────────

pub const Range = struct { start: usize, end: usize };

pub const Snippet = struct {
    text: []const u8,
    ranges: usize, // highlight ranges written to the caller's slice
};

fn charStart(text: []const u8, i_in: usize) usize {
    var i = @min(i_in, text.len);
    while (i > 0 and i < text.len and (text[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

fn findTerm(hay: []const u8, from: usize, term: []const u8) ?usize {
    if (term.len == 0 or from >= hay.len) return null;
    return if (std.ascii.indexOfIgnoreCase(hay[from..], term)) |p| from + p else null;
}

/// Excerpt of at most `max_len` bytes of `text` around the earliest term hit,
/// cut on word boundaries with "…" marking elisions, plus non-overlapping
/// highlight ranges (byte offsets into the returned text) for every hit.
pub fn snippet(text: []const u8, term_list: []const []const u8, max_len: usize, out: []u8, ranges: []Range) Snippet {
    const ell = "\u{2026}";
    var first: ?usize = null;
    for (term_list) |term| if (findTerm(text, 0, term)) |p| {
        if (first == null or p < first.?) first = p;
    };
    const budget = @min(max_len, out.len -| (2 * ell.len));
    var start: usize = 0;
    if (first) |p| {
        if (text.len > budget and p > budget / 3) start = p - budget / 3;
    }
    if (start > 0) {
        // Snap forward to the next word start.
        if (std.mem.indexOfScalarPos(u8, text, start, ' ')) |sp| {
            if (sp < (first orelse sp) or first == null) start = sp + 1;
        }
        start = charStart(text, start);
    }
    var end = @min(text.len, start + budget);
    if (end < text.len) {
        if (std.mem.lastIndexOfScalar(u8, text[start..end], ' ')) |sp| {
            if (sp > budget / 2) end = start + sp;
        }
        end = charStart(text, end);
    }
    var w = std.Io.Writer.fixed(out);
    if (start > 0) w.writeAll(ell) catch {};
    const body_off = w.end;
    w.writeAll(std.mem.trim(u8, text[start..end], " ")) catch {};
    const body = out[body_off..w.end];
    if (end < text.len) w.writeAll(ell) catch {};
    const result = w.buffered();

    // Highlights: walk the body, at each position take the longest term match.
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < body.len and count < ranges.len) {
        var best: ?Range = null;
        for (term_list) |term| if (findTerm(body, pos, term)) |p| {
            const r = Range{ .start = body_off + p, .end = body_off + p + term.len };
            if (best == null or r.start < best.?.start or (r.start == best.?.start and r.end > best.?.end)) best = r;
        };
        const r = best orelse break;
        ranges[count] = r;
        count += 1;
        pos = r.end - body_off;
    }
    return .{ .text = result, .ranges = count };
}

/// "1:02:03" / "2:03" for a position in seconds.
pub fn formatClock(secs_f: f64, out: []u8) []const u8 {
    const total: u64 = if (secs_f > 0 and secs_f < 1e9) @intFromFloat(secs_f) else 0;
    const h = total / 3600;
    const m = (total % 3600) / 60;
    const s = total % 60;
    return if (h > 0)
        std.fmt.bufPrint(out, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch ""
    else
        std.fmt.bufPrint(out, "{d}:{d:0>2}", .{ m, s }) catch "";
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "parse: runtime comparators in every spelling" {
    const cases = [_]struct { []const u8, u32, u32 }{
        .{ "something under 2 hours", 7200, 0 },
        .{ "movies < 45 min", 2700, 0 },
        .{ "movies <45 min", 2700, 0 },
        .{ "under 90min", 5400, 0 },
        .{ "less than 1.5 hours", 5400, 0 },
        .{ "under an hour", 3600, 0 },
        .{ "under half an hour", 1800, 0 },
        .{ "shorter than 1h30", 5400, 0 },
        .{ "at most 2h", 7200, 0 },
        .{ "over 3 hours", 0, 10800 },
        .{ "longer than 150 minutes", 0, 9000 },
        .{ "at least two hours", 0, 7200 },
    };
    for (cases) |case| {
        const p = parse(case[0]);
        try testing.expectEqual(case[1], p.constraints.max_runtime_secs);
        try testing.expectEqual(case[2], p.constraints.min_runtime_secs);
        try testing.expect(p.natural);
    }
}

test "parse: short only in a request context" {
    try testing.expectEqual(@as(u32, 5400), parse("a short movie").constraints.max_runtime_secs);
    try testing.expectEqual(@as(u32, 5400), parse("something quick").constraints.max_runtime_secs);
    const title = parse("Short Term 12");
    try testing.expectEqual(@as(u32, 0), title.constraints.max_runtime_secs);
    try testing.expectEqualStrings("Short Term 12", title.text());
    try testing.expect(!wantsRecall(&title));
}

test "parse: era forms" {
    const nineties = parse("90s anime");
    try testing.expectEqual(@as(u16, 1990), nineties.constraints.year_min);
    try testing.expectEqual(@as(u16, 1999), nineties.constraints.year_max);
    try testing.expectEqual(Kind.anime, nineties.constraints.kind);
    try testing.expectEqual(@as(u16, 1980), parse("movies from the '80s").constraints.year_min);
    try testing.expectEqual(@as(u16, 2010), parse("2010s thrillers").constraints.year_min);
    try testing.expectEqual(@as(u16, 2000), parse("00s comedies").constraints.year_min);
    const after = parse("films after 2015");
    try testing.expectEqual(@as(u16, 2016), after.constraints.year_min);
    try testing.expectEqual(@as(u16, 0), after.constraints.year_max);
    try testing.expectEqual(@as(u16, 1999), parse("before 2000").constraints.year_max);
    const between = parse("between 1995 and 1990");
    try testing.expectEqual(@as(u16, 1990), between.constraints.year_min);
    try testing.expectEqual(@as(u16, 1995), between.constraints.year_max);
    try testing.expectEqual(@as(u16, 1990), parse("nineties music").constraints.year_min);
}

test "parse: a bare year in a title is not an era" {
    for ([_][]const u8{ "1917", "2001 A Space Odyssey", "Blade Runner 2049" }) |q| {
        const p = parse(q);
        try testing.expectEqual(@as(u16, 0), p.constraints.year_min);
        try testing.expectEqual(@as(u16, 0), p.constraints.year_max);
        try testing.expectEqualStrings(q, p.text());
    }
}

test "parse: kinds and the show-me lead-in" {
    try testing.expectEqual(Kind.show, parse("show me a series about chefs").constraints.kind);
    try testing.expectEqualStrings("chefs", parse("show me a series about chefs").text());
    try testing.expectEqual(Kind.podcast, parse("podcasts about history").constraints.kind);
    try testing.expectEqual(Kind.comic, parse("manga").constraints.kind);
    try testing.expectEqual(Kind.book, parse("audiobooks").constraints.kind);
    try testing.expectEqual(Kind.movie, parse("film noir movies").constraints.kind); // first wins
}

test "parse: watch states" {
    try testing.expectEqual(Watch.unwatched, parse("unwatched movies").constraints.watch);
    try testing.expectEqual(Watch.unwatched, parse("something new").constraints.watch);
    try testing.expectEqual(Watch.unwatched, parse("movies I haven't seen").constraints.watch);
    try testing.expectEqual(Watch.unwatched, parse("shows I have not watched yet").constraints.watch);
    try testing.expectEqual(Watch.unfinished, parse("unfinished shows").constraints.watch);
    try testing.expectEqual(Watch.unfinished, parse("stuff I didn't finish").constraints.watch);
    try testing.expectEqual(Watch.unfinished, parse("anime in progress").constraints.watch);
    try testing.expectEqual(Watch.rewatch, parse("a rewatch").constraints.watch);
    try testing.expectEqual(Watch.rewatch, parse("movies I already watched").constraints.watch);
    // "New Girl" is a title, not a watch state.
    const title = parse("New Girl");
    try testing.expectEqual(Watch.any, title.constraints.watch);
    try testing.expectEqualStrings("New Girl", title.text());
}

test "parse: like <title> is a seed, not residual" {
    const p = parse("something like Blade Runner under 2 hours");
    try testing.expectEqualStrings("Blade Runner", p.constraints.likeTitle());
    try testing.expectEqual(@as(u32, 7200), p.constraints.max_runtime_secs);
    try testing.expectEqual(@as(usize, 0), p.text().len);
    const sim = parse("anime similar to Cowboy Bebop");
    try testing.expectEqualStrings("Cowboy Bebop", sim.constraints.likeTitle());
    try testing.expectEqual(Kind.anime, sim.constraints.kind);
    // Trailing "like" with nothing after it is just a word.
    try testing.expectEqual(@as(usize, 0), parse("movies I would like").constraints.like_len);
}

test "parse: language needs a preposition or a structured request" {
    try testing.expectEqualStrings("ja", parse("horror in Japanese").constraints.langCode());
    try testing.expectEqualStrings("ko", parse("korean thriller movies").constraints.langCode());
    const title = parse("The French Dispatch");
    try testing.expectEqual(@as(usize, 0), title.constraints.lang_len);
    try testing.expectEqualStrings("The French Dispatch", title.text());
}

test "parse: combined query keeps only the searchable residual" {
    const p = parse("find me unwatched 90s sci-fi movies under 2 hours about time travel");
    const c = p.constraints;
    try testing.expectEqual(Watch.unwatched, c.watch);
    try testing.expectEqual(@as(u16, 1990), c.year_min);
    try testing.expectEqual(Kind.movie, c.kind);
    try testing.expectEqual(@as(u32, 7200), c.max_runtime_secs);
    try testing.expectEqualStrings("sci-fi time travel", p.text());
    try testing.expect(wantsRecall(&p));
}

test "parse: moment intent and filler-only queries" {
    const m = parse("the scene where they dance on the roof");
    try testing.expect(m.moment);
    try testing.expectEqualStrings("the they dance on the roof", m.text());
    const empty = parse("something");
    try testing.expectEqual(@as(usize, 0), empty.text().len);
    const blank = parse("   ");
    try testing.expectEqual(@as(usize, 0), blank.text().len);
    try testing.expect(!blank.constraints.active());
}

test "parse: hostile input never overflows" {
    var long: [2000]u8 = undefined;
    @memset(&long, 'a');
    for (0..long.len) |i| if (i % 7 == 0) {
        long[i] = ' ';
    };
    const p = parse(&long);
    try testing.expect(p.residual_len <= RESIDUAL_MAX);
    _ = parse("<<<<>>>> under under under 999999 hours like like like");
    _ = parse("'s 's '90 9s 0000s");
}

test "terms and ftsQuery quote, dedupe and drop stopwords" {
    var buf: [256]u8 = undefined;
    var list: [MAX_TERMS][]const u8 = undefined;
    const n = terms("The Time, the TIME travel of it!", &buf, &list);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("time", list[0]);
    try testing.expectEqualStrings("travel", list[1]);
    // Duplicates do not consume buffer space: terms are contiguous.
    try testing.expectEqual(@intFromPtr(list[0].ptr) + list[0].len, @intFromPtr(list[1].ptr));
    var q: [256]u8 = undefined;
    try testing.expectEqualStrings("\"time\"* OR \"travel\"*", ftsQuery("time travel", &q));
    try testing.expectEqualStrings("\"go\" OR \"dont\"* OR \"near\"*", ftsQuery("go \"don't\" NEAR(", &q));
    try testing.expectEqualStrings("", ftsQuery("the of a", &q));
}

const sample_srt =
    "1\r\n00:00:01,000 --> 00:00:04,000\r\n<i>Hello there.</i>\r\n\r\n" ++
    "2\n00:00:05,500 --> 00:00:09,000\nWe need to go\nback to the {\\an8}future.\n\n" ++
    "3\n00:00:30,000 --> 00:00:33,000\nRoads? Where we're going\n\n" ++
    "4\n00:00:50,000 --> 00:00:52,000\nwe don't need roads.\n";

test "parseCues: SRT with CRLF, tags and a final cue without a blank line" {
    var cues: [8]Cue = undefined;
    const n = parseCues(sample_srt, &cues);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(u32, 1000), cues[0].start_ms);
    try testing.expectEqual(@as(u32, 9000), cues[1].end_ms);
    try testing.expectEqualStrings("we don't need roads.", cues[3].text);
    var buf: [256]u8 = undefined;
    const text = windowText(&cues, .{ .start_ms = 0, .end_ms = 0, .first = 0, .count = 2 }, &buf);
    try testing.expectEqualStrings("Hello there. We need to go back to the future.", text);
}

test "parseCues: WebVTT short clocks and cue settings" {
    const vtt = "WEBVTT\n\n00:01.000 --> 00:02.500 align:start\nfirst\n\n01:00:00.000 --> 01:00:01.000\nlast\n";
    var cues: [4]Cue = undefined;
    const n = parseCues(vtt, &cues);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u32, 2500), cues[0].end_ms);
    try testing.expectEqual(@as(u32, 3_600_000), cues[1].start_ms);
    // Garbage and reversed ranges are skipped, not fatal.
    try testing.expectEqual(@as(usize, 0), parseCues("00:05 --> 00:01\nx\n\nnot a clock --> nope\ny\n", &cues));
}

test "chunk: windows stay within bounds, overlap, and always advance" {
    var cues: [40]Cue = undefined;
    for (&cues, 0..) |*c, i| {
        const s: u32 = @intCast(i * 4000);
        c.* = .{ .start_ms = s, .end_ms = s + 3000, .text = "x" };
    }
    var wins: [40]Window = undefined;
    const n = chunk(&cues, .{}, &wins);
    try testing.expect(n >= 4 and n <= 10);
    try testing.expectEqual(@as(usize, 0), wins[0].first);
    for (wins[0..n], 0..) |w, k| {
        const span = w.end_ms - w.start_ms;
        try testing.expect(span <= 40_000);
        if (k + 1 < n) {
            try testing.expect(span >= 20_000);
            const next = wins[k + 1];
            try testing.expect(next.first > w.first); // progress
            try testing.expect(next.start_ms < w.end_ms); // overlap
            try testing.expect(w.end_ms - next.start_ms <= 5_000 + 4_000);
        }
    }
    try testing.expectEqual(@as(usize, 40), wins[n - 1].first + wins[n - 1].count);
}

test "chunk: a single overlong cue and sparse cues" {
    const long = [_]Cue{
        .{ .start_ms = 0, .end_ms = 90_000, .text = "monologue" },
        .{ .start_ms = 95_000, .end_ms = 96_000, .text = "a" },
        .{ .start_ms = 300_000, .end_ms = 301_000, .text = "b" },
    };
    var wins: [8]Window = undefined;
    const n = chunk(&long, .{}, &wins);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(usize, 1), wins[0].count);
    try testing.expectEqual(@as(u32, 95_000), wins[1].start_ms);
    try testing.expectEqual(@as(usize, 0), chunk(&.{}, .{}, &wins));
    // Output capacity bounds the work.
    try testing.expectEqual(@as(usize, 1), chunk(&long, .{}, wins[0..1]));
}

test "sidecarLang matches only real sidecars" {
    try testing.expectEqualStrings("", sidecarLang("Heat (1995)", "Heat (1995).srt").?);
    try testing.expectEqualStrings("en", sidecarLang("Heat (1995)", "Heat (1995).en.srt").?);
    try testing.expectEqualStrings("eng", sidecarLang("Heat", "Heat.eng.forced.SRT").?);
    try testing.expectEqualStrings("", sidecarLang("Heat", "Heat.auto.srt").?);
    try testing.expectEqualStrings("ja", sidecarLang("Heat", "Heat.ja.vtt").?);
    try testing.expect(sidecarLang("Heat", "Heat2.srt") == null);
    try testing.expect(sidecarLang("Heat", "Heat.mkv") == null);
    try testing.expect(sidecarLang("", ".srt") == null);
}

test "sanitizeUtf8 keeps valid text and replaces Latin-1 bytes" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("caf\u{e9} ok", sanitizeUtf8("caf\u{e9} ok", &out));
    try testing.expectEqualStrings("caf? ok", sanitizeUtf8("caf\xe9 ok", &out));
    try testing.expectEqualStrings("?", sanitizeUtf8("\xe2\x82", &out)[0..1]);
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("ab", sanitizeUtf8("ab\u{20ac}", &tiny)); // no split sequence
}

test "utf8Prefix never splits a sequence" {
    try testing.expectEqualStrings("ab", utf8Prefix("ab\u{20ac}", 4));
    try testing.expectEqualStrings("ab\u{20ac}", utf8Prefix("ab\u{20ac}", 5));
    try testing.expectEqualStrings("abc", utf8Prefix("abc", 10));
}

test "filename heuristics" {
    try testing.expectEqual(@as(u16, 1995), yearFromName("Heat.1995.1080p.BluRay"));
    try testing.expectEqual(@as(u16, 2019), yearFromName("Blade Runner 2049 (2019 remux)"));
    try testing.expectEqual(@as(u16, 0), yearFromName("12345 Street"));
    try testing.expectEqual(Kind.show, kindFromFilename("The.Office.S02E05.mkv"));
    try testing.expectEqual(Kind.music, kindFromFilename("track.FLAC"));
    try testing.expectEqual(Kind.movie, kindFromFilename("Heat.1995.mkv"));
    try testing.expectEqual(Kind.show, kindFromLibrary("tv", ""));
    try testing.expectEqual(Kind.show, kindFromLibrary("watch", "/m/Show.S01E01.mkv"));
    try testing.expectEqual(Kind.book, kindFromLibrary("novels", ""));
    try testing.expectEqual(Kind.anime, kindFromName("anime"));
    try testing.expectEqual(Kind.other, kindFromName("bogus"));
}

test "fuse: reciprocal-rank fusion is deterministic and both lists count" {
    var cands = [_]Candidate{
        .{ .id = 3, .fts_rank = 1 },
        .{ .id = 1, .vec_rank = 1 },
        .{ .id = 2, .fts_rank = 2, .vec_rank = 2 }, // in both lists → wins
        .{ .id = 4 }, // in neither → dropped
    };
    const c = Constraints{};
    const n = fuse(&cands, &c, 0, false);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(i64, 2), cands[0].id);
    // Equal scores tie-break on id, so repeated runs agree.
    try testing.expectEqual(@as(i64, 1), cands[1].id);
    try testing.expectEqual(@as(i64, 3), cands[2].id);
}

test "fuse: constraint filters and boosts" {
    const now: i64 = 1_800_000_000;
    var cands = [_]Candidate{
        .{ .id = 1, .fts_rank = 1, .kind = .movie, .runtime_secs = 9000, .year = 1994 }, // too long
        .{ .id = 2, .fts_rank = 2, .kind = .movie, .runtime_secs = 5400, .year = 1995 },
        .{ .id = 3, .fts_rank = 3, .kind = .show, .runtime_secs = 1800, .year = 1996 }, // wrong kind
        .{ .id = 4, .fts_rank = 4, .kind = .movie, .runtime_secs = 0, .year = 1997 }, // unknown runtime: kept, penalised
        .{ .id = 5, .fts_rank = 5, .kind = .movie, .runtime_secs = 6000, .year = 2005 }, // wrong era
        .{ .id = 6, .fts_rank = 3, .kind = .anime, .runtime_secs = 6000, .year = 1998, .percent = 50 }, // anime admits, unfinished boost
    };
    var c = Constraints{ .kind = .movie, .max_runtime_secs = 7200, .year_min = 1990, .year_max = 1999 };
    const n = fuse(&cands, &c, now, false);
    try testing.expectEqual(@as(usize, 3), n);
    // The unfinished anime's boost lifts it over a slightly better text hit.
    try testing.expectEqual(@as(i64, 6), cands[0].id);
    try testing.expectEqual(@as(i64, 2), cands[1].id);
    try testing.expectEqual(@as(i64, 4), cands[2].id);

    // Watch-state filters.
    var w = [_]Candidate{ .{ .id = 1, .fts_rank = 1, .percent = 0 }, .{ .id = 2, .fts_rank = 2, .percent = 40 }, .{ .id = 3, .fts_rank = 3, .percent = 99 } };
    c = .{ .watch = .unfinished };
    try testing.expectEqual(@as(usize, 1), fuse(&w, &c, now, false));
    try testing.expectEqual(@as(i64, 2), w[0].id);

    // Browse mode ranks constraint-only queries by state alone.
    var b = [_]Candidate{
        .{ .id = 1 },
        .{ .id = 2, .favorite = true },
        .{ .id = 3, .updated_at = now - 86400 },
    };
    c = .{};
    try testing.expectEqual(@as(usize, 3), fuse(&b, &c, now, true));
    try testing.expectEqual(@as(i64, 2), b[0].id);
    try testing.expectEqual(@as(i64, 3), b[1].id);
}

test "snippet: centred excerpt, ellipses, highlight ranges" {
    const text = "It was a quiet night at the station until the radio picked up a broadcast that nobody had sent, repeating the same coordinates over and over.";
    var out: [96]u8 = undefined;
    var ranges: [8]Range = undefined;
    const s = snippet(text, &.{ "broadcast", "coordinates" }, 80, &out, &ranges);
    try testing.expect(s.text.len <= 96);
    try testing.expect(std.mem.startsWith(u8, s.text, "\u{2026}"));
    try testing.expect(std.mem.indexOf(u8, s.text, "broadcast") != null);
    try testing.expect(s.ranges >= 1);
    try testing.expectEqualStrings("broadcast", s.text[ranges[0].start..ranges[0].end]);
    // Short text: no ellipses, case-insensitive highlight.
    const t = snippet("Hello World", &.{"world"}, 80, &out, &ranges);
    try testing.expectEqualStrings("Hello World", t.text);
    try testing.expectEqual(@as(usize, 1), t.ranges);
    try testing.expectEqualStrings("World", t.text[ranges[0].start..ranges[0].end]);
    // No hit: leading excerpt, no ranges.
    const u = snippet(text, &.{"zebra"}, 40, &out, &ranges);
    try testing.expectEqual(@as(usize, 0), u.ranges);
    try testing.expect(std.mem.startsWith(u8, u.text, "It was"));
}

test "momentRelevant and termHits" {
    try testing.expectEqual(@as(usize, 2), termHits("They DANCE on the roof", &.{ "dance", "roof", "rain" }));
    try testing.expect(!momentRelevant(1, 2, false));
    try testing.expect(momentRelevant(2, 2, false));
    try testing.expect(momentRelevant(2, 4, false));
    try testing.expect(!momentRelevant(1, 4, false));
    try testing.expect(momentRelevant(0, 3, true));
    try testing.expect(!momentRelevant(0, 0, false));
}

test "describe summarises constraints" {
    var b: [160]u8 = undefined;
    const p = parse("unwatched 90s movies under 2 hours like Heat");
    try testing.expectEqualStrings("movie \u{b7} under 2h \u{b7} 1990s \u{b7} unwatched \u{b7} like Heat", describe(&p.constraints, &b));
    const q = parse("shows after 2015 over 45 min in korean");
    try testing.expectEqualStrings("show \u{b7} over 45 min \u{b7} from 2016 \u{b7} language ko", describe(&q.constraints, &b));
    const none = Constraints{};
    try testing.expectEqualStrings("", describe(&none, &b));
}

test "formatClock" {
    var b: [16]u8 = undefined;
    try testing.expectEqualStrings("0:05", formatClock(5.9, &b));
    try testing.expectEqualStrings("2:03", formatClock(123, &b));
    try testing.expectEqualStrings("1:02:03", formatClock(3723, &b));
    try testing.expectEqualStrings("0:00", formatClock(-4, &b));
}
