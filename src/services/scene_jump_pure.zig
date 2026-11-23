//! Pure half of the assistant's "jump to the scene where …" command: intent
//! parsing, choosing among moment-search matches, the "which one?" follow-up,
//! and the reply text. scene_jump.zig runs it on a worker with Recall's
//! moment search as the `Searcher`; the scene-jump probe runs the very same
//! `handleTranscript` with a fixture searcher, so a transcript string can be
//! tested end to end without a microphone.

const std = @import("std");

pub const MAX_CANDIDATES = 8;
pub const MAX_CHOICES = 3;
/// Two matches in the same item closer than this are the same scene.
pub const same_scene_secs: f64 = 30;
/// The top match wins outright when it scores this much better than the next.
pub const clear_win_ratio: f64 = 1.6;

// ── Intent ────────────────────────────────────────────────────────────────

const fillers = [_][]const u8{
    "hey opal ", "ok opal ",     "okay opal ", "opal ",     "please ",      "can you ",
    "could you ", "would you ",  "will you ",  "i want to ", "i'd like to ", "let's ",
    "lets ",      "just ",       "now ",
};

const verbs = [_][]const u8{
    "jump back to ", "jump ahead to ", "jump to ",       "skip ahead to ", "skip back to ", "skip to ",
    "go back to ",   "go to ",         "take me back to ", "take me to ",  "rewind to ",    "fast forward to ",
    "seek to ",      "find me ",       "find ",          "show me ",       "play ",         "replay ",
    "bring up ",     "cue up ",        "cue ",
};

const nouns = [_][]const u8{
    "the scene where ", "the scene when ", "the scene with ", "the scene in which ", "the scene ",
    "the part where ",  "the part when ",  "the part with ",  "the bit where ",      "the bit when ",
    "the moment where ", "the moment when ", "the moment ",   "that scene where ",   "that part where ",
    "the point where ", "where ",          "when ",
};

pub const Intent = struct {
    /// What happens in the scene ("they rob the bank").
    description: []const u8,
    /// Moment-search query ("the scene where they rob the bank").
    query: []const u8,
};

fn stripPrefix(s: []const u8, list: []const []const u8) ?[]const u8 {
    for (list) |p| if (std.mem.startsWith(u8, s, p)) return s[p.len..];
    return null;
}

/// The scene description in a spoken or typed request, or null when `text`
/// is not a scene jump ("play Dune", "jump to 10 minutes", "pause"). Slices
/// point into `out` (lowercased working copy).
pub fn parseIntent(text: []const u8, out: []u8) ?Intent {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0 or t.len + 20 > out.len) return null;
    // Lowercase, folding punctuation that STT inserts mid-phrase into spaces.
    var n: usize = 0;
    var last_space = true;
    for (t) |ch| {
        const c = std.ascii.toLower(ch);
        const is_space = c == ' ' or c == '\t' or c == ',' or c == '.' or c == '!' or c == '?' or c == ';' or c == ':';
        if (is_space) {
            if (!last_space) {
                out[n] = ' ';
                n += 1;
            }
            last_space = true;
        } else {
            out[n] = c;
            n += 1;
            last_space = false;
        }
    }
    if (n > 0 and out[n - 1] == ' ') n -= 1;
    var s: []const u8 = out[0..n];
    while (stripPrefix(s, &fillers)) |rest| s = rest;
    const after_verb = stripPrefix(s, &verbs);
    if (after_verb) |rest| s = rest;
    const head_len = s.len;
    const after_noun = stripPrefix(s, &nouns) orelse return null;
    // A bare "where/when" clause needs a verb in front ("go to where ...");
    // "when is the next episode" is a question, not a scene.
    const consumed = s[0 .. head_len - after_noun.len];
    const bare = std.mem.eql(u8, consumed, "where ") or std.mem.eql(u8, consumed, "when ");
    if (bare and after_verb == null) return null;
    var desc = after_noun;
    for ([_][]const u8{ " please", " for me", " again" }) |suffix| {
        if (std.mem.endsWith(u8, desc, suffix)) desc = desc[0 .. desc.len - suffix.len];
    }
    desc = std.mem.trim(u8, desc, " ");
    if (desc.len < 3) return null;
    // Write the query after the working copy.
    const prefix = "the scene where ";
    const q_start = n;
    if (q_start + prefix.len + desc.len > out.len) return null;
    @memcpy(out[q_start .. q_start + prefix.len], prefix);
    // desc lives in out[0..n]; the copy goes strictly after it.
    std.mem.copyForwards(u8, out[q_start + prefix.len .. q_start + prefix.len + desc.len], desc);
    return .{ .description = desc, .query = out[q_start .. q_start + prefix.len + desc.len] };
}

// ── Candidates and the decision ───────────────────────────────────────────

pub const Candidate = struct {
    moment_id: i64 = 0,
    doc_id: i64 = 0,
    start_secs: f64 = 0,
    score: f64 = 0,
    title: [120]u8 = std.mem.zeroes([120]u8),
    title_len: usize = 0,
    snippet: [200]u8 = std.mem.zeroes([200]u8),
    snippet_len: usize = 0,
    /// The match is inside what the active player is showing now.
    same_media: bool = false,

    pub fn titleText(self: *const Candidate) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn snippetText(self: *const Candidate) []const u8 {
        return self.snippet[0..self.snippet_len];
    }
    pub fn setTitle(self: *Candidate, s: []const u8) void {
        self.title_len = utf8Copy(&self.title, s);
    }
    pub fn setSnippet(self: *Candidate, s: []const u8) void {
        self.snippet_len = utf8Copy(&self.snippet, s);
    }
};

fn utf8Copy(dst: []u8, src: []const u8) usize {
    var n = @min(src.len, dst.len);
    // Never cut a UTF-8 sequence in half.
    while (n > 0 and n < src.len and (src[n] & 0xc0) == 0x80) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

pub const Choices = struct {
    items: [MAX_CHOICES]Candidate = undefined,
    len: usize = 0,
    pub fn slice(self: *const Choices) []const Candidate {
        return self.items[0..self.len];
    }
};

pub const Decision = union(enum) {
    none,
    /// One clear match in what is playing: seek the active player.
    seek: Candidate,
    /// One clear match in another item: open it at that second.
    open: Candidate,
    /// Several plausible matches: ask which.
    choose: Choices,
};

fn byScoreDesc(_: void, a: Candidate, b: Candidate) bool {
    return a.score > b.score;
}

/// Pick what to do with moment-search matches. Matches inside the item that
/// is playing (`current_doc`) win over matches elsewhere; near-duplicate
/// windows of one scene collapse; a single or clearly-best match acts, the
/// rest ask.
pub fn decide(cands_in: []const Candidate, current_doc: ?i64) Decision {
    var pool: [MAX_CANDIDATES]Candidate = undefined;
    var n: usize = 0;
    var any_current = false;
    if (current_doc) |cd| for (cands_in) |c| {
        if (c.doc_id == cd) any_current = true;
    };
    for (cands_in) |c| {
        if (n >= pool.len) break;
        if (any_current and c.doc_id != current_doc.?) continue;
        if (!std.math.isFinite(c.start_secs) or c.start_secs < 0) continue;
        pool[n] = c;
        pool[n].same_media = any_current;
        n += 1;
    }
    std.mem.sort(Candidate, pool[0..n], {}, byScoreDesc);
    var kept: [MAX_CANDIDATES]Candidate = undefined;
    var k: usize = 0;
    for (pool[0..n]) |c| {
        var dup = false;
        for (kept[0..k]) |e| {
            if (e.doc_id == c.doc_id and @abs(e.start_secs - c.start_secs) < same_scene_secs) dup = true;
        }
        if (dup) continue;
        kept[k] = c;
        k += 1;
    }
    if (k == 0) return .none;
    const top = kept[0];
    const clear = k == 1 or (kept[1].score <= 0) or top.score >= clear_win_ratio * kept[1].score;
    if (clear) return if (top.same_media) .{ .seek = top } else .{ .open = top };
    var ch = Choices{};
    for (kept[0..@min(k, MAX_CHOICES)]) |c| {
        ch.items[ch.len] = c;
        ch.len += 1;
    }
    return .{ .choose = ch };
}

// ── The follow-up answer ──────────────────────────────────────────────────

pub const Reply = union(enum) { pick: usize, cancel, unrelated };

const ordinals = [_]struct { []const u8, usize }{
    .{ "first", 0 }, .{ "one", 0 },   .{ "1", 0 },     .{ "1st", 0 },
    .{ "second", 1 }, .{ "two", 1 },  .{ "2", 1 },     .{ "2nd", 1 },
    .{ "third", 2 }, .{ "three", 2 }, .{ "3", 2 },     .{ "3rd", 2 },
};

/// Interpret the answer to "which one?" for `count` offered choices. Only
/// short answers count, so "play the second episode of Dune" is unrelated.
pub fn parseReply(text: []const u8, count: usize) Reply {
    var buf: [96]u8 = undefined;
    const t = std.mem.trim(u8, text, " \t\r\n.!?,");
    if (t.len == 0 or t.len > buf.len or count == 0) return .unrelated;
    for (t, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const s = buf[0..t.len];
    var words: [6][]const u8 = undefined;
    var nw: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " ,.!?");
    while (it.next()) |w| {
        if (nw >= words.len) return .unrelated;
        words[nw] = w;
        nw += 1;
    }
    if (nw == 0) return .unrelated;
    const cancels = [_][]const u8{ "cancel", "nevermind", "no", "none", "nope", "stop", "neither" };
    for (cancels) |c| if (std.mem.eql(u8, words[0], c)) return .cancel;
    if (nw >= 2 and std.mem.eql(u8, words[0], "never") and std.mem.eql(u8, words[1], "mind")) return .cancel;
    for (words[0..nw]) |w| {
        if (std.mem.eql(u8, w, "last")) return .{ .pick = count - 1 };
        for (ordinals) |o| if (std.mem.eql(u8, w, o[0])) {
            return if (o[1] < count) .{ .pick = o[1] } else .unrelated;
        };
    }
    const yeses = [_][]const u8{ "yes", "yeah", "yep", "sure", "ok", "okay", "that", "that's", "thats" };
    for (yeses) |y| if (std.mem.eql(u8, words[0], y)) return .{ .pick = 0 };
    return .unrelated;
}

// ── Messages ──────────────────────────────────────────────────────────────

pub fn formatClock(secs_f: f64, out: []u8) []const u8 {
    const total: u64 = if (std.math.isFinite(secs_f) and secs_f > 0 and secs_f < 1e9) @intFromFloat(secs_f) else 0;
    const h = total / 3600;
    const m = (total % 3600) / 60;
    const s = total % 60;
    return if (h > 0)
        std.fmt.bufPrint(out, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch ""
    else
        std.fmt.bufPrint(out, "{d}:{d:0>2}", .{ m, s }) catch "";
}

fn quoteSnippet(w: *std.Io.Writer, c: *const Candidate) !void {
    const sn = std.mem.trim(u8, c.snippetText(), " \t\r\n");
    if (sn.len == 0) return;
    var cut = @min(sn.len, 90);
    while (cut > 0 and cut < sn.len and (sn[cut] & 0xc0) == 0x80) cut -= 1;
    try w.print(" \"{s}{s}\"", .{ sn[0..cut], if (cut < sn.len) "…" else "" });
}

pub const msg_none = "I couldn't find that scene. Moment search covers items whose subtitles are indexed.";
pub const msg_cancel = "OK, staying where you are.";

pub fn formatSeek(buf: []u8, c: *const Candidate) []const u8 {
    var clock: [24]u8 = undefined;
    var w = std.Io.Writer.fixed(buf);
    w.print("Jumping to {s}.", .{formatClock(c.start_secs, &clock)}) catch return "Jumping there.";
    quoteSnippet(&w, c) catch {};
    return w.buffered();
}

pub fn formatOpen(buf: []u8, c: *const Candidate) []const u8 {
    var clock: [24]u8 = undefined;
    var w = std.Io.Writer.fixed(buf);
    w.print("Opening {s} at {s}.", .{ if (c.title_len > 0) c.titleText() else "that", formatClock(c.start_secs, &clock) }) catch return "Opening that scene.";
    quoteSnippet(&w, c) catch {};
    return w.buffered();
}

pub fn formatChoices(buf: []u8, ch: *const Choices) []const u8 {
    var clock: [24]u8 = undefined;
    var w = std.Io.Writer.fixed(buf);
    w.print("I found {d} scenes.", .{ch.len}) catch return "I found several scenes. Which one?";
    for (ch.slice(), 0..) |*c, i| {
        w.print(" {d}: ", .{i + 1}) catch break;
        if (!c.same_media and c.title_len > 0) w.print("{s} ", .{c.titleText()}) catch break;
        w.print("at {s}", .{formatClock(c.start_secs, &clock)}) catch break;
        quoteSnippet(&w, c) catch break;
        w.writeAll(".") catch break;
    }
    w.writeAll(" Which one?") catch {};
    return w.buffered();
}

// ── The whole turn ────────────────────────────────────────────────────────

/// Choices waiting for "which one?". Owned copies, so the caller may keep it
/// across turns and threads.
pub const Pending = struct {
    choices: Choices = .{},

    pub fn active(self: *const Pending) bool {
        return self.choices.len > 0;
    }
    pub fn clear(self: *Pending) void {
        self.choices.len = 0;
    }
};

/// Where moment matches come from: Recall's moment index in the app, a JSON
/// fixture in the probe. `search` fills `out` and returns the count.
pub const Searcher = struct {
    ctx: *anyopaque,
    search: *const fn (ctx: *anyopaque, query: []const u8, out: []Candidate) usize,
    /// Recall doc id of what the active player shows, if indexed.
    current_doc: ?i64 = null,
};

pub const Hit = struct { cand: Candidate, msg: []const u8 };

pub const Action = union(enum) {
    /// Not a scene request (or answer): the assistant handles it as usual.
    ignore,
    /// Reply only.
    say: []const u8,
    seek: Hit,
    open: Hit,
    /// Choices were stored in `pending`; `msg` asks which.
    ask: []const u8,
};

/// True when `handleTranscript` would act on `text` (it is a scene request,
/// or an answer to pending choices). Cheap: no search.
pub fn claims(text: []const u8, pending: *const Pending) bool {
    if (pending.active() and parseReply(text, pending.choices.len) != .unrelated) return true;
    var buf: [600]u8 = undefined;
    return parseIntent(text, &buf) != null;
}

/// One assistant turn for a transcript (spoken or typed). Messages are
/// written into `msg_buf`.
pub fn handleTranscript(text: []const u8, pending: *Pending, s: Searcher, msg_buf: []u8) Action {
    if (pending.active()) {
        switch (parseReply(text, pending.choices.len)) {
            .pick => |i| {
                const c = pending.choices.items[i];
                pending.clear();
                return if (c.same_media)
                    .{ .seek = .{ .cand = c, .msg = formatSeek(msg_buf, &c) } }
                else
                    .{ .open = .{ .cand = c, .msg = formatOpen(msg_buf, &c) } };
            },
            .cancel => {
                pending.clear();
                return .{ .say = msg_cancel };
            },
            .unrelated => pending.clear(),
        }
    }
    var work: [600]u8 = undefined;
    const intent = parseIntent(text, &work) orelse return .ignore;
    var cands: [MAX_CANDIDATES]Candidate = undefined;
    const n = @min(s.search(s.ctx, intent.query, &cands), cands.len);
    switch (decide(cands[0..n], s.current_doc)) {
        .none => return .{ .say = msg_none },
        .seek => |c| return .{ .seek = .{ .cand = c, .msg = formatSeek(msg_buf, &c) } },
        .open => |c| return .{ .open = .{ .cand = c, .msg = formatOpen(msg_buf, &c) } },
        .choose => |ch| {
            pending.choices = ch;
            return .{ .ask = formatChoices(msg_buf, &pending.choices) };
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseIntent: spoken scene requests" {
    var buf: [600]u8 = undefined;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "Jump to the scene where they rob the bank.", "they rob the bank" },
        .{ "hey opal, can you skip to the part where the dragon wakes up please", "the dragon wakes up" },
        .{ "Take me back to the moment when she opens the letter", "she opens the letter" },
        .{ "go to where they find the map", "they find the map" },
        .{ "Find the scene with the train chase", "the train chase" },
        .{ "the scene where he says goodbye", "he says goodbye" },
        .{ "Rewind to when the lights go out.", "the lights go out" },
    };
    for (cases) |c| {
        const in = parseIntent(c[0], &buf) orelse {
            std.debug.print("no intent: {s}\n", .{c[0]});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(c[1], in.description);
        try testing.expect(std.mem.startsWith(u8, in.query, "the scene where "));
        try testing.expect(std.mem.endsWith(u8, in.query, c[1]));
    }
}

test "parseIntent: not scene requests" {
    var buf: [600]u8 = undefined;
    for ([_][]const u8{ "play Dune", "jump to 10 minutes", "pause", "when is the next episode", "where is my download", "go to settings", "the scene", "", "skip to where" }) |t| {
        if (parseIntent(t, &buf)) |in| {
            std.debug.print("unexpected intent for '{s}': {s}\n", .{ t, in.description });
            return error.TestUnexpectedResult;
        }
    }
}

fn cand(id: i64, doc: i64, start: f64, score: f64, snippet: []const u8) Candidate {
    var c = Candidate{ .moment_id = id, .doc_id = doc, .start_secs = start, .score = score };
    c.setTitle(if (doc == 1) "Heat" else "Other film");
    c.setSnippet(snippet);
    return c;
}

test "decide: a clear match in what is playing seeks" {
    const cs = [_]Candidate{ cand(10, 1, 754, 0.9, "we rob the bank"), cand(11, 1, 2000, 0.3, "bank holiday") };
    const d = decide(&cs, 1);
    try testing.expectEqual(@as(f64, 754), d.seek.start_secs);
    try testing.expect(d.seek.same_media);
}

test "decide: matches in the playing item beat better matches elsewhere" {
    const cs = [_]Candidate{ cand(1, 2, 100, 0.99, "x"), cand(2, 1, 300, 0.4, "y") };
    const d = decide(&cs, 1);
    try testing.expectEqual(@as(i64, 2), d.seek.moment_id);
    // Nothing indexed for the current item: open the best elsewhere.
    const e = decide(&cs, 7);
    try testing.expectEqual(@as(i64, 1), e.open.moment_id);
    try testing.expect(!e.open.same_media);
    try testing.expect(decide(&cs, null) == .open);
}

test "decide: overlapping windows of one scene collapse; close scores ask" {
    const cs = [_]Candidate{
        cand(1, 1, 600, 0.8, "a"), cand(2, 1, 612, 0.79, "a again"), // same scene
        cand(3, 1, 1800, 0.7, "b"), cand(4, 1, 3000, 0.6, "c"),      cand(5, 1, 4000, 0.5, "d"),
    };
    const d = decide(&cs, 1);
    const ch = d.choose;
    try testing.expectEqual(@as(usize, 3), ch.len);
    try testing.expectEqual(@as(i64, 1), ch.items[0].moment_id);
    try testing.expectEqual(@as(i64, 3), ch.items[1].moment_id);
    try testing.expectEqual(@as(i64, 4), ch.items[2].moment_id);
    try testing.expect(decide(&.{}, 1) == .none);
    const dup_only = [_]Candidate{ cand(1, 1, 600, 0.8, "a"), cand(2, 1, 615, 0.8, "a") };
    try testing.expect(decide(&dup_only, 1) == .seek);
}

test "parseReply" {
    try testing.expectEqual(Reply{ .pick = 1 }, parseReply("the second one", 3));
    try testing.expectEqual(Reply{ .pick = 2 }, parseReply("Number 3.", 3));
    try testing.expectEqual(Reply{ .pick = 2 }, parseReply("the last one", 3));
    try testing.expectEqual(Reply{ .pick = 0 }, parseReply("yes", 2));
    try testing.expectEqual(Reply.cancel, parseReply("never mind", 2));
    try testing.expectEqual(Reply.cancel, parseReply("no", 2));
    try testing.expectEqual(Reply.unrelated, parseReply("third", 2)); // only two offered
    try testing.expectEqual(Reply.unrelated, parseReply("play the second episode of dune now please", 3));
    try testing.expectEqual(Reply.unrelated, parseReply("turn up the volume", 3));
}

test "formatClock and messages" {
    var b: [24]u8 = undefined;
    try testing.expectEqualStrings("12:34", formatClock(754, &b));
    try testing.expectEqualStrings("1:02:03", formatClock(3723.4, &b));
    var m: [256]u8 = undefined;
    const c = cand(1, 1, 754, 0.9, "we rob the bank at noon");
    try testing.expectEqualStrings("Jumping to 12:34. \"we rob the bank at noon\"", formatSeek(&m, &c));
    try testing.expect(std.mem.startsWith(u8, formatOpen(&m, &c), "Opening Heat at 12:34."));
    var ch = Choices{};
    ch.items[0] = cand(1, 1, 600, 0.8, "a");
    ch.items[0].same_media = true;
    ch.items[1] = cand(2, 2, 60, 0.7, "b");
    ch.len = 2;
    try testing.expectEqualStrings("I found 2 scenes. 1: at 10:00 \"a\". 2: Other film at 1:00 \"b\". Which one?", formatChoices(&m, &ch));
}

const Fixture = struct {
    cands: []const Candidate,
    calls: usize = 0,
    last_query: [128]u8 = undefined,
    last_len: usize = 0,

    fn search(ctx: *anyopaque, query: []const u8, out: []Candidate) usize {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_len = @min(query.len, self.last_query.len);
        @memcpy(self.last_query[0..self.last_len], query[0..self.last_len]);
        const n = @min(out.len, self.cands.len);
        @memcpy(out[0..n], self.cands[0..n]);
        return n;
    }
};

test "handleTranscript: transcript to seek target, with a confirmation turn" {
    const many = [_]Candidate{ cand(1, 1, 600, 0.8, "a"), cand(3, 1, 1800, 0.7, "b"), cand(4, 2, 3000, 0.6, "c") };
    var fx = Fixture{ .cands = &many };
    const s = Searcher{ .ctx = &fx, .search = Fixture.search, .current_doc = 1 };
    var pending = Pending{};
    var msg: [512]u8 = undefined;

    try testing.expect(handleTranscript("pause", &pending, s, &msg) == .ignore);
    try testing.expectEqual(@as(usize, 0), fx.calls);

    try testing.expect(claims("Jump to the scene where they rob the bank", &pending));
    const a = handleTranscript("Jump to the scene where they rob the bank", &pending, s, &msg);
    try testing.expectEqualStrings("the scene where they rob the bank", fx.last_query[0..fx.last_len]);
    try testing.expect(std.mem.startsWith(u8, a.ask, "I found 2 scenes."));
    try testing.expect(pending.active());
    try testing.expect(claims("the second one", &pending));

    const b = handleTranscript("the second one", &pending, s, &msg);
    try testing.expectEqual(@as(f64, 1800), b.seek.cand.start_secs);
    try testing.expect(!pending.active());
    try testing.expectEqual(@as(usize, 1), fx.calls); // the answer needs no new search

    // An unrelated command drops the pending question and is not claimed.
    _ = handleTranscript("go to the part where something happens", &pending, s, &msg);
    try testing.expect(pending.active());
    try testing.expect(!claims("turn the volume up", &pending));
    try testing.expect(handleTranscript("turn the volume up", &pending, s, &msg) == .ignore);
    try testing.expect(!pending.active());
}

test "handleTranscript: single match seeks immediately, nothing found says so" {
    const one = [_]Candidate{cand(9, 1, 754, 0.9, "we rob the bank")};
    var fx = Fixture{ .cands = &one };
    var pending = Pending{};
    var msg: [512]u8 = undefined;
    const r = handleTranscript("skip to the part where they rob the bank", &pending, .{ .ctx = &fx, .search = Fixture.search, .current_doc = 1 }, &msg);
    try testing.expectEqual(@as(f64, 754), r.seek.cand.start_secs);
    try testing.expectEqual(@as(i64, 9), r.seek.cand.moment_id);
    var empty = Fixture{ .cands = &.{} };
    const none = handleTranscript("jump to the scene where nothing matches", &pending, .{ .ctx = &empty, .search = Fixture.search }, &msg);
    try testing.expectEqualStrings(msg_none, none.say);
}
