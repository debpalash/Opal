//! Live captions — pure scheduling, cue merging and subtitle serialization.
//!
//! The worker (live_captions.zig) transcribes the playing media in short
//! ffmpeg+whisper chunks that stay ahead of the playhead. Everything that
//! decides WHAT to transcribe next, HOW overlapping chunk output is stitched
//! together, and the exact SRT/VTT bytes lives here so it is unit-tested and
//! shipped as the same code.
const std = @import("std");

// ── Scheduling ──────────────────────────────────────────────

pub const Range = struct { start: f64, end: f64 };

pub const Config = struct {
    /// Steady-state chunk length once captions are flowing.
    chunk_secs: f64 = 30,
    /// Shorter first chunk after start/seek so text appears quickly.
    first_chunk_secs: f64 = 12,
    /// Stop scheduling once this far ahead of the playhead.
    lookahead_secs: f64 = 60,
    /// Each continuation chunk re-reads this much of the previous one so a
    /// sentence cut at a chunk edge is transcribed whole the second time.
    overlap_secs: f64 = 2,
    /// A playhead this close before a covered range still counts as inside it.
    seek_slack_secs: f64 = 1.5,
    /// Never schedule a chunk shorter than this (except at end of media).
    min_chunk_secs: f64 = 3,
};

pub const Chunk = struct {
    start: f64,
    len: f64,
    /// Coverage frontier the chunk continues from (== start for a fresh chunk
    /// after a seek). Cues whose midpoint precedes it were already captioned.
    frontier: f64,

    pub fn end(self: Chunk) f64 {
        return self.start + self.len;
    }
};

pub const max_ranges = 128;

/// Sorted, non-overlapping transcribed time ranges.
pub const Coverage = struct {
    ranges: [max_ranges]Range = undefined,
    len: usize = 0,

    pub fn reset(self: *Coverage) void {
        self.len = 0;
    }

    pub fn slice(self: *const Coverage) []const Range {
        return self.ranges[0..self.len];
    }

    /// Insert and merge (ranges that touch within 50 ms coalesce). When full,
    /// the earliest range is forgotten — it is the one least likely needed.
    pub fn add(self: *Coverage, r_in: Range) void {
        if (!(r_in.end > r_in.start)) return;
        var r = r_in;
        var out: [max_ranges + 1]Range = undefined;
        var n: usize = 0;
        var placed = false;
        for (self.ranges[0..self.len]) |cur| {
            if (cur.end + 0.05 < r.start) {
                out[n] = cur;
                n += 1;
            } else if (r.end + 0.05 < cur.start) {
                if (!placed) {
                    out[n] = r;
                    n += 1;
                    placed = true;
                }
                out[n] = cur;
                n += 1;
            } else {
                r.start = @min(r.start, cur.start);
                r.end = @max(r.end, cur.end);
            }
        }
        if (!placed) {
            out[n] = r;
            n += 1;
        }
        const drop = if (n > max_ranges) n - max_ranges else 0;
        @memcpy(self.ranges[0 .. n - drop], out[drop..n]);
        self.len = n - drop;
    }

    pub fn containing(self: *const Coverage, t: f64, slack: f64) ?Range {
        for (self.ranges[0..self.len]) |r| {
            if (r.start - slack <= t and t < r.end) return r;
        }
        return null;
    }

    /// Start of the first covered range beginning strictly after `t`.
    pub fn nextStartAfter(self: *const Coverage, t: f64) ?f64 {
        for (self.ranges[0..self.len]) |r| {
            if (r.start > t) return r.start;
        }
        return null;
    }
};

/// Decide the next chunk to transcribe, or null when captions are far enough
/// ahead (or the media is finished). `duration` <= 0 means unknown (live).
/// A seek is handled implicitly: a playhead outside every covered range starts
/// a fresh short chunk right at the playhead.
pub fn nextChunk(playhead: f64, cov: *const Coverage, duration: f64, cfg: Config) ?Chunk {
    const p = if (std.math.isFinite(playhead)) @max(0, playhead) else 0;
    const known = duration > 0 and std.math.isFinite(duration);
    if (known and p >= duration - 0.25) return null;

    var start: f64 = undefined;
    var len: f64 = undefined;
    var frontier: f64 = undefined;
    if (cov.containing(p, cfg.seek_slack_secs)) |r| {
        if (r.end >= p + cfg.lookahead_secs) return null;
        if (known and r.end >= duration - 0.25) return null;
        start = @max(0, r.end - cfg.overlap_secs);
        len = cfg.chunk_secs + cfg.overlap_secs;
        frontier = r.end;
    } else {
        start = @floor(p);
        len = cfg.first_chunk_secs;
        frontier = start;
    }
    // Don't re-transcribe a range already covered further ahead (seek-back).
    if (cov.nextStartAfter(start + 0.01)) |ns| {
        if (ns < start + len) len = @max(ns - start + cfg.overlap_secs, cfg.min_chunk_secs);
    }
    if (known) {
        len = @min(len, duration - start);
        if (len < 0.5) return null;
    }
    return .{ .start = start, .len = len, .frontier = frontier };
}

// ── Cues ────────────────────────────────────────────────────

pub const Cue = struct {
    start: f64,
    end: f64,
    text: []const u8,
    /// Translation of `text`, when one has been produced.
    alt: ?[]const u8 = null,
};

/// Parse "HH:MM:SS,mmm" / "HH:MM:SS.mmm" / "MM:SS.mmm" into seconds.
pub fn parseTimestamp(s_in: []const u8) ?f64 {
    const s = std.mem.trim(u8, s_in, " \t");
    if (s.len == 0) return null;
    var parts: [3]f64 = .{ 0, 0, 0 };
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, s, ':');
    while (it.next()) |part| {
        if (count >= 3) return null;
        const norm_len = part.len;
        var buf: [32]u8 = undefined;
        if (norm_len == 0 or norm_len > buf.len) return null;
        @memcpy(buf[0..norm_len], part);
        for (buf[0..norm_len]) |*ch| if (ch.* == ',') {
            ch.* = '.';
        };
        parts[count] = std.fmt.parseFloat(f64, buf[0..norm_len]) catch return null;
        count += 1;
    }
    return switch (count) {
        2 => parts[0] * 60 + parts[1],
        3 => parts[0] * 3600 + parts[1] * 60 + parts[2],
        else => null,
    };
}

/// Whisper emits non-speech markers like "[BLANK_AUDIO]" or "[Music]".
pub fn isNonSpeech(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return true;
    return t[0] == '[' and t[t.len - 1] == ']' and std.mem.indexOfScalarPos(u8, t, 1, '[') == null;
}

/// Parse SRT (or WebVTT) text. Cue texts are allocated with `alloc`; free
/// with `freeCues`. Malformed blocks are skipped, never fatal.
pub fn parseSrt(alloc: std.mem.Allocator, src: []const u8) ![]Cue {
    var list: std.ArrayList(Cue) = .empty;
    errdefer {
        for (list.items) |c| alloc.free(c.text);
        list.deinit(alloc);
    }
    var lines = std.mem.splitScalar(u8, src, '\n');
    var pending: ?struct { start: f64, end: f64 } = null;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    while (true) {
        const raw = lines.next();
        const line = if (raw) |l| std.mem.trimEnd(u8, l, "\r") else "";
        const blank = std.mem.trim(u8, line, " \t").len == 0;
        if (raw == null or blank) {
            if (pending) |p| {
                const t = std.mem.trim(u8, text.items, " \t\n");
                if (t.len > 0 and !isNonSpeech(t) and p.end > p.start) {
                    const owned = try alloc.dupe(u8, t);
                    list.append(alloc, .{ .start = p.start, .end = p.end, .text = owned }) catch |e| {
                        alloc.free(owned);
                        return e;
                    };
                }
            }
            pending = null;
            text.clearRetainingCapacity();
            if (raw == null) break;
            continue;
        }
        if (std.mem.indexOf(u8, line, "-->")) |arrow| {
            const a = parseTimestamp(line[0..arrow]);
            // VTT cue settings follow the end stamp after a space.
            var rest = std.mem.trim(u8, line[arrow + 3 ..], " \t");
            if (std.mem.indexOfAny(u8, rest, " \t")) |sp| rest = rest[0..sp];
            const b = parseTimestamp(rest);
            if (a != null and b != null) {
                pending = .{ .start = a.?, .end = b.? };
                text.clearRetainingCapacity();
            }
            continue;
        }
        if (pending == null) continue; // index line, WEBVTT header, NOTE ...
        if (text.items.len > 0) try text.append(alloc, '\n');
        try text.appendSlice(alloc, std.mem.trim(u8, line, " \t"));
    }
    return list.toOwnedSlice(alloc);
}

pub fn freeCues(alloc: std.mem.Allocator, cues: []Cue) void {
    for (cues) |c| {
        alloc.free(c.text);
        if (c.alt) |a| alloc.free(a);
    }
    alloc.free(cues);
}

/// Shift chunk-relative cues onto the media timeline and clamp them to the
/// chunk window (whisper occasionally overruns the audio it was given).
pub fn offsetCues(cues: []Cue, chunk: Chunk) void {
    for (cues) |*c| {
        c.start = @min(c.start + chunk.start, chunk.end());
        c.end = @min(c.end + chunk.start, chunk.end());
    }
}

/// Lower-case alphanumeric fingerprint used for boundary dedup.
fn normalize(text: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (text) |ch| {
        if (n >= out.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch >= 0x80) {
            out[n] = std.ascii.toLower(ch);
            n += 1;
        }
    }
    return out[0..n];
}

pub fn similarText(a: []const u8, b: []const u8) bool {
    var ab: [512]u8 = undefined;
    var bb: [512]u8 = undefined;
    const na = normalize(a, &ab);
    const nb = normalize(b, &bb);
    if (na.len == 0 or nb.len == 0) return na.len == nb.len;
    if (std.mem.eql(u8, na, nb)) return true;
    const short = if (na.len < nb.len) na else nb;
    const long = if (na.len < nb.len) nb else na;
    return short.len >= 4 and std.mem.indexOf(u8, long, short) != null;
}

const max_overlap_words = 10;

fn lowerWordEql(a: []const u8, b: []const u8) bool {
    var ab: [64]u8 = undefined;
    var bb: [64]u8 = undefined;
    const na = normalize(a, &ab);
    const nb = normalize(b, &bb);
    return na.len > 0 and std.mem.eql(u8, na, nb);
}

/// Byte length of `prev` to keep so its trailing words don't repeat the
/// leading words of `next` (longest match of 2..10 words wins). Returns
/// prev.len when there is no such overlap.
pub fn wordOverlapKeep(prev: []const u8, next: []const u8) usize {
    // prev's last words as [start, end) spans, collected back to front.
    var pw: [max_overlap_words][2]usize = undefined;
    var pn: usize = 0;
    var i: usize = prev.len;
    while (pn < max_overlap_words and i > 0) {
        while (i > 0 and std.ascii.isWhitespace(prev[i - 1])) i -= 1;
        if (i == 0) break;
        const end = i;
        while (i > 0 and !std.ascii.isWhitespace(prev[i - 1])) i -= 1;
        pw[pn] = .{ i, end };
        pn += 1;
    }
    var nw: [max_overlap_words][]const u8 = undefined;
    var nn: usize = 0;
    var it = std.mem.tokenizeAny(u8, next, " \t\n");
    while (nn < max_overlap_words) {
        nw[nn] = it.next() orelse break;
        nn += 1;
    }
    var k: usize = @min(pn, nn);
    while (k >= 2) : (k -= 1) {
        var all = true;
        for (0..k) |j| {
            const span = pw[k - 1 - j];
            if (!lowerWordEql(prev[span[0]..span[1]], nw[j])) {
                all = false;
                break;
            }
        }
        if (all) return pw[k - 1][0];
    }
    return prev.len;
}

/// Merge one chunk's (already offset) cues into the sorted `existing` list.
///   * cues starting in the last `overlap` seconds of a non-final chunk are
///     deferred: the next chunk starts there and transcribes them whole;
///   * a cue overlapping an existing cue is dropped when the text matches or
///     when it sits before the chunk's frontier (already captioned).
/// Kept cue texts are duplicated into `alloc` (the list owns them). Returns
/// the number of cues added.
pub fn mergeCues(
    alloc: std.mem.Allocator,
    existing: *std.ArrayList(Cue),
    new: []const Cue,
    chunk: Chunk,
    is_final: bool,
    overlap: f64,
) !usize {
    var added: usize = 0;
    for (new) |n| {
        if (!(n.end > n.start)) continue;
        const t = std.mem.trim(u8, n.text, " \t\r\n");
        if (t.len == 0 or isNonSpeech(t)) continue;
        if (!is_final and n.start > chunk.end() - overlap) continue;
        const mid = (n.start + n.end) / 2;
        var dup = false;
        for (existing.items) |e| {
            if (e.start < n.end and n.start < e.end) {
                if (similarText(e.text, t) or mid < chunk.frontier) {
                    dup = true;
                    break;
                }
            }
        }
        if (dup) continue;
        // Exact repeat of the cue right before it (whisper loops on silence).
        var pos: usize = existing.items.len;
        while (pos > 0 and existing.items[pos - 1].start > n.start) pos -= 1;
        if (pos > 0) {
            const prev = existing.items[pos - 1];
            if (n.start - prev.end < 1.0 and std.mem.eql(u8, prev.text, t)) continue;
            // Chunk-edge cut: "...in the north. The captain says the" followed by
            // "Captain says the ship will leave" — drop the repeated words from
            // the earlier (truncated) cue; the new one carries the whole sentence.
            if (prev.end > n.start - 0.5) {
                const keep = wordOverlapKeep(prev.text, t);
                if (keep < prev.text.len) {
                    const trimmed = std.mem.trimEnd(u8, prev.text[0..keep], " \t\n,");
                    if (trimmed.len == 0) {
                        alloc.free(prev.text);
                        _ = existing.orderedRemove(pos - 1);
                        pos -= 1;
                    } else {
                        const shorter = try alloc.dupe(u8, trimmed);
                        alloc.free(prev.text);
                        existing.items[pos - 1].text = shorter;
                        existing.items[pos - 1].end = @min(prev.end, n.start);
                    }
                }
            }
        }
        const owned = try alloc.dupe(u8, t);
        existing.insert(alloc, pos, .{ .start = n.start, .end = n.end, .text = owned }) catch |e| {
            alloc.free(owned);
            return e;
        };
        added += 1;
    }
    return added;
}

// ── Serialization ───────────────────────────────────────────

fn writeStamp(w: *std.Io.Writer, secs_in: f64, sep: u8) !void {
    const secs = if (std.math.isFinite(secs_in)) @max(0, secs_in) else 0;
    const total_ms: u64 = @intFromFloat(@round(secs * 1000));
    const h = total_ms / 3_600_000;
    const m = (total_ms / 60_000) % 60;
    const s = (total_ms / 1000) % 60;
    const ms = total_ms % 1000;
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>3}", .{ h, m, s, sep, ms });
}

fn cueText(c: Cue, use_alt: bool) []const u8 {
    if (use_alt) if (c.alt) |a| if (a.len > 0) return a;
    return c.text;
}

pub fn writeSrt(w: *std.Io.Writer, cues: []const Cue, use_alt: bool) !void {
    for (cues, 0..) |c, i| {
        try w.print("{d}\n", .{i + 1});
        try writeStamp(w, c.start, ',');
        try w.writeAll(" --> ");
        try writeStamp(w, c.end, ',');
        try w.writeAll("\n");
        try w.writeAll(cueText(c, use_alt));
        try w.writeAll("\n\n");
    }
}

pub fn writeVtt(w: *std.Io.Writer, cues: []const Cue, use_alt: bool) !void {
    try w.writeAll("WEBVTT\n\n");
    for (cues) |c| {
        try writeStamp(w, c.start, '.');
        try w.writeAll(" --> ");
        try writeStamp(w, c.end, '.');
        try w.writeAll("\n");
        try w.writeAll(cueText(c, use_alt));
        try w.writeAll("\n\n");
    }
}

/// Plain transcript (one cue per line) — the recap source format.
pub fn writeTranscript(w: *std.Io.Writer, cues: []const Cue) !void {
    for (cues) |c| {
        for (c.text) |ch| try w.writeByte(if (ch == '\n') ' ' else ch);
        try w.writeByte('\n');
    }
}

// ── ffmpeg / whisper argument helpers ───────────────────────

/// mpv's `http-header-fields` is "Name: value,Name2: value2". ffmpeg wants
/// "Name: value\r\n" lines. A comma only separates fields when the next
/// segment looks like "Token: " — commas inside values (cookies, UAs) stay.
pub fn ffmpegHeaders(mpv_fields: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= mpv_fields.len) : (i += 1) {
        const at_end = i == mpv_fields.len;
        if (!at_end and !(mpv_fields[i] == ',' and startsHeaderField(mpv_fields[i + 1 ..]))) continue;
        const field = std.mem.trim(u8, mpv_fields[seg_start..i], " ");
        seg_start = i + 1;
        if (field.len == 0 or std.mem.indexOfScalar(u8, field, ':') == null) continue;
        if (std.mem.indexOfAny(u8, field, "\r\n\x00") != null) continue;
        if (n + field.len + 2 > out.len) break;
        @memcpy(out[n..][0..field.len], field);
        n += field.len;
        out[n] = '\r';
        out[n + 1] = '\n';
        n += 2;
    }
    return out[0..n];
}

fn startsHeaderField(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-' or s[i] == '_')) i += 1;
    return i > 0 and i + 1 < s.len and s[i] == ':' and s[i + 1] == ' ';
}

pub const SourceKind = enum { local, http, unsupported };

pub fn sourceKind(path: []const u8) SourceKind {
    if (path.len == 0) return .unsupported;
    if (std.ascii.startsWithIgnoreCase(path, "http://") or std.ascii.startsWithIgnoreCase(path, "https://")) return .http;
    if (std.ascii.startsWithIgnoreCase(path, "file://")) return .local;
    if (std.mem.indexOf(u8, path, "://") != null) return .unsupported; // magnet:, edl://, ytdl://, ...
    if (std.mem.startsWith(u8, path, "magnet:")) return .unsupported;
    return .local;
}

/// `file:///x/y` → `/x/y`; everything else unchanged.
pub fn localPath(path: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(path, "file://")) return path["file://".len..];
    return path;
}

pub const ChunkArgs = struct {
    ffmpeg: []const u8,
    source: []const u8,
    user_agent: []const u8 = "",
    /// ffmpeg-format header block (see ffmpegHeaders).
    headers: []const u8 = "",
    start: f64,
    len: f64,
    out_wav: []const u8,
};

/// Build the ffmpeg argv for one 16 kHz mono WAV chunk. `num_buf` backs the
/// -ss/-t strings. Input seeking (-ss before -i) keeps it fast on network
/// sources: ffmpeg issues a ranged request instead of reading from zero.
pub fn ffmpegChunkArgv(a: ChunkArgs, argv: *[32][]const u8, num_buf: *[64]u8) []const []const u8 {
    var n: usize = 0;
    const push = struct {
        fn f(v: *[32][]const u8, i: *usize, s: []const u8) void {
            v[i.*] = s;
            i.* += 1;
        }
    }.f;
    const ss = std.fmt.bufPrint(num_buf[0..32], "{d:.3}", .{@max(0, a.start)}) catch "0";
    const tt = std.fmt.bufPrint(num_buf[32..64], "{d:.3}", .{@max(0.5, a.len)}) catch "30";
    push(argv, &n, a.ffmpeg);
    push(argv, &n, "-nostdin");
    push(argv, &n, "-hide_banner");
    push(argv, &n, "-loglevel");
    push(argv, &n, "error");
    push(argv, &n, "-y");
    if (sourceKind(a.source) == .http) {
        push(argv, &n, "-rw_timeout");
        push(argv, &n, "20000000");
        if (a.user_agent.len > 0) {
            push(argv, &n, "-user_agent");
            push(argv, &n, a.user_agent);
        }
        if (a.headers.len > 0) {
            push(argv, &n, "-headers");
            push(argv, &n, a.headers);
        }
    }
    push(argv, &n, "-ss");
    push(argv, &n, ss);
    push(argv, &n, "-t");
    push(argv, &n, tt);
    push(argv, &n, "-i");
    push(argv, &n, if (sourceKind(a.source) == .local) localPath(a.source) else a.source);
    push(argv, &n, "-vn");
    push(argv, &n, "-ac");
    push(argv, &n, "1");
    push(argv, &n, "-ar");
    push(argv, &n, "16000");
    push(argv, &n, "-f");
    push(argv, &n, "wav");
    push(argv, &n, a.out_wav);
    return argv[0..n];
}

/// Map an ISO 639-2 code (Opal's subtitle-search codes) or a 639-1 code to
/// whisper's 639-1 language flag. Unknown/empty → "auto".
pub fn whisperLang(code: []const u8) []const u8 {
    const map = [_][2][]const u8{
        .{ "eng", "en" }, .{ "spa", "es" }, .{ "fre", "fr" }, .{ "fra", "fr" },
        .{ "ger", "de" }, .{ "deu", "de" }, .{ "por", "pt" }, .{ "ita", "it" },
        .{ "rus", "ru" }, .{ "chi", "zh" }, .{ "zho", "zh" }, .{ "jpn", "ja" },
        .{ "kor", "ko" }, .{ "hin", "hi" }, .{ "ara", "ar" }, .{ "tur", "tr" },
        .{ "dut", "nl" }, .{ "nld", "nl" }, .{ "pol", "pl" }, .{ "swe", "sv" },
    };
    if (code.len == 0 or std.ascii.eqlIgnoreCase(code, "auto")) return "auto";
    for (map) |m| if (std.ascii.eqlIgnoreCase(code, m[0])) return m[1];
    if (code.len == 2 and std.ascii.isAlphabetic(code[0]) and std.ascii.isAlphabetic(code[1])) return code;
    return "auto";
}

// ── Tests ───────────────────────────────────────────────────

const testing = std.testing;
const tcfg: Config = .{};

test "first chunk starts at the playhead and is short" {
    var cov: Coverage = .{};
    const c = nextChunk(12.7, &cov, 600, tcfg).?;
    try testing.expectEqual(@as(f64, 12), c.start);
    try testing.expectEqual(tcfg.first_chunk_secs, c.len);
    try testing.expectEqual(@as(f64, 12), c.frontier);
}

test "continuation overlaps the frontier and stays ~60 s ahead" {
    var cov: Coverage = .{};
    cov.add(.{ .start = 0, .end = 30 });
    const c = nextChunk(5, &cov, 600, tcfg).?;
    try testing.expectEqual(@as(f64, 28), c.start);
    try testing.expectEqual(tcfg.chunk_secs + tcfg.overlap_secs, c.len);
    try testing.expectEqual(@as(f64, 30), c.frontier);
    cov.add(.{ .start = 0, .end = 70 });
    try testing.expect(nextChunk(5, &cov, 600, tcfg) == null); // 65 s ahead
    try testing.expect(nextChunk(11, &cov, 600, tcfg) != null); // 59 s ahead
}

test "seek outside coverage restarts at the new playhead" {
    var cov: Coverage = .{};
    cov.add(.{ .start = 0, .end = 90 });
    const c = nextChunk(1200.4, &cov, 3600, tcfg).?;
    try testing.expectEqual(@as(f64, 1200), c.start);
    try testing.expectEqual(tcfg.first_chunk_secs, c.len);
}

test "seek back just before a covered range counts as inside it" {
    var cov: Coverage = .{};
    cov.add(.{ .start = 100, .end = 140 });
    const c = nextChunk(99, &cov, 3600, tcfg).?;
    try testing.expectEqual(@as(f64, 138), c.start);
}

test "chunk is clipped before an already-covered range ahead" {
    var cov: Coverage = .{};
    cov.add(.{ .start = 105, .end = 300 });
    const c = nextChunk(100, &cov, 3600, tcfg).?;
    try testing.expectEqual(@as(f64, 100), c.start);
    try testing.expectEqual(@as(f64, 7), c.len); // 5 s gap + 2 s overlap
}

test "end of media stops scheduling and clips the last chunk" {
    var cov: Coverage = .{};
    cov.add(.{ .start = 0, .end = 50 });
    const c = nextChunk(40, &cov, 60, tcfg).?;
    try testing.expectEqual(@as(f64, 48), c.start);
    try testing.expectEqual(@as(f64, 12), c.len);
    cov.add(.{ .start = 48, .end = 60 });
    try testing.expect(nextChunk(40, &cov, 60, tcfg) == null);
    try testing.expect(nextChunk(59.9, &cov, 60, tcfg) == null);
}

test "unknown duration (live stream) keeps scheduling" {
    var cov: Coverage = .{};
    cov.add(.{ .start = 0, .end = 30 });
    try testing.expect(nextChunk(10, &cov, 0, tcfg) != null);
}

test "coverage merges overlapping and touching ranges" {
    var cov: Coverage = .{};
    cov.add(.{ .start = 10, .end = 20 });
    cov.add(.{ .start = 40, .end = 50 });
    cov.add(.{ .start = 18, .end = 41 });
    try testing.expectEqual(@as(usize, 1), cov.len);
    try testing.expectEqual(@as(f64, 10), cov.ranges[0].start);
    try testing.expectEqual(@as(f64, 50), cov.ranges[0].end);
    cov.add(.{ .start = 0, .end = 5 });
    try testing.expectEqual(@as(usize, 2), cov.len);
    try testing.expectEqual(@as(f64, 0), cov.ranges[0].start);
}

test "parseSrt reads whisper output and drops non-speech markers" {
    const srt =
        "1\r\n00:00:00,000 --> 00:00:02,500\r\n Hello there.\r\n\r\n" ++
        "2\n00:00:02,500 --> 00:00:04,000\n[BLANK_AUDIO]\n\n" ++
        "3\n00:01:02,250 --> 00:01:04,000\nTwo\nlines\n";
    const cues = try parseSrt(testing.allocator, srt);
    defer freeCues(testing.allocator, cues);
    try testing.expectEqual(@as(usize, 2), cues.len);
    try testing.expectEqualStrings("Hello there.", cues[0].text);
    try testing.expectEqual(@as(f64, 2.5), cues[0].end);
    try testing.expectEqualStrings("Two\nlines", cues[1].text);
    try testing.expectApproxEqAbs(@as(f64, 62.25), cues[1].start, 1e-9);
}

test "parseSrt accepts WebVTT with cue settings and short stamps" {
    const vtt = "WEBVTT\n\nNOTE hi\n\n00:05.000 --> 00:07.500 align:start\nVTT line\n";
    const cues = try parseSrt(testing.allocator, vtt);
    defer freeCues(testing.allocator, cues);
    try testing.expectEqual(@as(usize, 1), cues.len);
    try testing.expectEqual(@as(f64, 5), cues[0].start);
    try testing.expectEqual(@as(f64, 7.5), cues[0].end);
}

test "offsetCues shifts onto the timeline and clamps to the chunk" {
    var cues = [_]Cue{ .{ .start = 1, .end = 3, .text = "a" }, .{ .start = 29, .end = 35, .text = "b" } };
    offsetCues(&cues, .{ .start = 100, .len = 32, .frontier = 102 });
    try testing.expectEqual(@as(f64, 101), cues[0].start);
    try testing.expectEqual(@as(f64, 132), cues[1].end);
}

fn freeList(list: *std.ArrayList(Cue)) void {
    for (list.items) |c| testing.allocator.free(c.text);
    list.deinit(testing.allocator);
}

test "merge dedups the overlap between consecutive chunks" {
    var list: std.ArrayList(Cue) = .empty;
    defer freeList(&list);
    // Chunk 1: [0,12). The cue starting at 10.5 is in the overlap tail → deferred.
    const c1 = Chunk{ .start = 0, .len = 12, .frontier = 0 };
    const n1 = [_]Cue{
        .{ .start = 0.5, .end = 4, .text = "We need to talk." },
        .{ .start = 4.2, .end = 10.8, .text = "About what happened" },
        .{ .start = 10.5, .end = 12, .text = "last ni" },
    };
    try testing.expectEqual(@as(usize, 2), try mergeCues(testing.allocator, &list, &n1, c1, false, 2));
    // Chunk 2: [10,42) re-reads the tail. Same sentence (dup), whole deferred cue (kept).
    const c2 = Chunk{ .start = 10, .len = 32, .frontier = 12 };
    const n2 = [_]Cue{
        .{ .start = 10, .end = 10.8, .text = "what happened" },
        .{ .start = 10.6, .end = 13.5, .text = "last night." },
        .{ .start = 14, .end = 16, .text = "Fine." },
    };
    try testing.expectEqual(@as(usize, 2), try mergeCues(testing.allocator, &list, &n2, c2, false, 2));
    try testing.expectEqual(@as(usize, 4), list.items.len);
    try testing.expectEqualStrings("last night.", list.items[2].text);
    try testing.expectEqualStrings("Fine.", list.items[3].text);
}

test "chunk-edge word overlap is trimmed from the earlier cue" {
    try testing.expectEqual(@as(usize, 24), wordOverlapKeep("rainy in the north. The captain says the", "Captain says the ship will leave"));
    try testing.expectEqual(@as(usize, 5), wordOverlapKeep("a b c", "x y"));
    var list: std.ArrayList(Cue) = .empty;
    defer freeList(&list);
    _ = try mergeCues(testing.allocator, &list, &[_]Cue{.{ .start = 5.5, .end = 10.8, .text = "north. The captain says the" }}, .{ .start = 0, .len = 12, .frontier = 0 }, false, 2);
    _ = try mergeCues(testing.allocator, &list, &[_]Cue{.{ .start = 10, .end = 15, .text = "Captain says the ship will leave." }}, .{ .start = 10, .len = 32, .frontier = 12 }, false, 2);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("north. The", list.items[0].text);
    try testing.expectEqual(@as(f64, 10), list.items[0].end);
}

test "merge drops a differently-worded cue already captioned before the frontier" {
    var list: std.ArrayList(Cue) = .empty;
    defer freeList(&list);
    const c1 = Chunk{ .start = 0, .len = 30, .frontier = 0 };
    _ = try mergeCues(testing.allocator, &list, &[_]Cue{.{ .start = 26, .end = 27.5, .text = "Go now." }}, c1, false, 2);
    const c2 = Chunk{ .start = 28, .len = 32, .frontier = 30 };
    // Overlaps nothing existing → kept even though it starts before the frontier.
    try testing.expectEqual(@as(usize, 1), try mergeCues(testing.allocator, &list, &[_]Cue{.{ .start = 28.1, .end = 29.5, .text = "Run!" }}, c2, false, 2));
    // Overlaps the existing cue with different words, midpoint before frontier → dropped.
    try testing.expectEqual(@as(usize, 0), try mergeCues(testing.allocator, &list, &[_]Cue{.{ .start = 27, .end = 28.2, .text = "Going now" }}, c2, false, 2));
}

test "merge inserts in time order after a backwards seek and skips loops" {
    var list: std.ArrayList(Cue) = .empty;
    defer freeList(&list);
    _ = try mergeCues(testing.allocator, &list, &[_]Cue{.{ .start = 500, .end = 502, .text = "Later" }}, .{ .start = 500, .len = 12, .frontier = 500 }, true, 2);
    _ = try mergeCues(testing.allocator, &list, &[_]Cue{
        .{ .start = 10, .end = 11, .text = "Earlier" },
        .{ .start = 11.2, .end = 12, .text = "Earlier" },
    }, .{ .start = 10, .len = 12, .frontier = 10 }, true, 2);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("Earlier", list.items[0].text);
}

test "SRT and VTT writers format stamps and prefer translations" {
    const cues = [_]Cue{
        .{ .start = 3661.5, .end = 3663.042, .text = "Hello", .alt = "Hola" },
        .{ .start = 0, .end = 1, .text = "Bye" },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeSrt(&aw.writer, &cues, true);
    try testing.expectEqualStrings("1\n01:01:01,500 --> 01:01:03,042\nHola\n\n2\n00:00:00,000 --> 00:00:01,000\nBye\n\n", aw.written());
    var vw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer vw.deinit();
    try writeVtt(&vw.writer, cues[0..1], false);
    try testing.expectEqualStrings("WEBVTT\n\n01:01:01.500 --> 01:01:03.042\nHello\n\n", vw.written());
}

test "SRT round-trips through the parser" {
    const cues = [_]Cue{.{ .start = 1.25, .end = 2.5, .text = "One\nTwo" }};
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeSrt(&aw.writer, &cues, false);
    const back = try parseSrt(testing.allocator, aw.written());
    defer freeCues(testing.allocator, back);
    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expectEqualStrings("One\nTwo", back[0].text);
    try testing.expectEqual(@as(f64, 1.25), back[0].start);
}

test "mpv header fields convert to ffmpeg CRLF headers, commas in values kept" {
    var buf: [256]u8 = undefined;
    const h = ffmpegHeaders("Referer: https://a.example/x,Cookie: a=1, b=2,Origin: https://a.example", &buf);
    try testing.expectEqualStrings("Referer: https://a.example/x\r\nCookie: a=1, b=2\r\nOrigin: https://a.example\r\n", h);
    try testing.expectEqualStrings("", ffmpegHeaders("", &buf));
}

test "ffmpeg chunk argv seeks before input and carries http identity" {
    var argv: [32][]const u8 = undefined;
    var nb: [64]u8 = undefined;
    const a = ffmpegChunkArgv(.{ .ffmpeg = "ffmpeg", .source = "https://cdn.example/v.m3u8", .user_agent = "UA/1", .headers = "Referer: x\r\n", .start = 90, .len = 32, .out_wav = "/t/c.wav" }, &argv, &nb);
    const joined = try std.mem.join(testing.allocator, " ", a);
    defer testing.allocator.free(joined);
    try testing.expect(std.mem.indexOf(u8, joined, "-user_agent UA/1 -headers Referer: x\r\n -ss 90.000 -t 32.000 -i https://cdn.example/v.m3u8") != null);
    try testing.expectEqualStrings("/t/c.wav", a[a.len - 1]);
    const l = ffmpegChunkArgv(.{ .ffmpeg = "ffmpeg", .source = "file:///m/a.mkv", .user_agent = "UA", .start = 0, .len = 12, .out_wav = "o" }, &argv, &nb);
    const lj = try std.mem.join(testing.allocator, " ", l);
    defer testing.allocator.free(lj);
    try testing.expect(std.mem.indexOf(u8, lj, "-user_agent") == null);
    try testing.expect(std.mem.indexOf(u8, lj, "-i /m/a.mkv") != null);
}

test "source classification" {
    try testing.expectEqual(SourceKind.local, sourceKind("/m/a.mkv"));
    try testing.expectEqual(SourceKind.http, sourceKind("http://127.0.0.1:9000/torrent/1"));
    try testing.expectEqual(SourceKind.unsupported, sourceKind("magnet:?xt=urn:btih:x"));
    try testing.expectEqual(SourceKind.unsupported, sourceKind("edl://x"));
}

test "whisper language mapping" {
    try testing.expectEqualStrings("auto", whisperLang(""));
    try testing.expectEqualStrings("auto", whisperLang("auto"));
    try testing.expectEqualStrings("en", whisperLang("eng"));
    try testing.expectEqualStrings("ja", whisperLang("jpn"));
    try testing.expectEqualStrings("fr", whisperLang("fr"));
    try testing.expectEqualStrings("auto", whisperLang("xx1"));
}

pub fn needsNewTrack(sid: i64, attached_path: []const u8, published_path: []const u8) bool {
    return sid < 0 or !std.mem.eql(u8, attached_path, published_path);
}

test "translation fallback attaches original captions instead of reloading translated file" {
    try std.testing.expect(!needsNewTrack(2, "translated.srt", "translated.srt"));
    try std.testing.expect(needsNewTrack(2, "translated.srt", "original.srt"));
    try std.testing.expect(needsNewTrack(-1, "original.srt", "original.srt"));
}
