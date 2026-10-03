//! Pure logic for the playback loading screen — no io, no dvui, so it runs
//! under `zig build test` without a live frame.
//!
//! A torrent resolve plus first-parts buffering can take half a minute. The
//! loading screen used to be a hourglass with a truncated file path, and later
//! a poster plus ONE static paragraph that only ever appeared for TMDB movie
//! and TV plays. Music, anime and everything else got the bare hourglass, and
//! nothing on the screen ever changed while you waited.
//!
//! This module holds the decisions behind the richer screen: which poster URL
//! to fetch for any source, how to cut a summary into readable cards, which
//! card is showing, and how the header line reads. `grid.zig` renders through
//! these, so the tested logic IS the shipped logic.

const std = @import("std");

// ══════════════════════════════════════════════════════════════════
// Media kind
// ══════════════════════════════════════════════════════════════════

/// What is loading. Drives the badge on the loading screen and the
/// disambiguation hint used when looking up trivia.
pub const MediaKind = enum {
    movie,
    tv,
    album,
    anime,
    other,

    /// Numeric form for the fixed-size state structs (they store plain
    /// integers, not tagged unions — see the state.zig buffer convention).
    pub fn toInt(self: MediaKind) u8 {
        return @intFromEnum(self);
    }

    /// Reverse of `toInt`, saturating on a value from an older config or a
    /// corrupt row rather than panicking on an invalid enum tag.
    pub fn fromInt(v: u8) MediaKind {
        const max = @typeInfo(MediaKind).@"enum".fields.len - 1;
        return @enumFromInt(@min(v, max));
    }
};

pub fn kindLabel(kind: MediaKind) []const u8 {
    return switch (kind) {
        .movie => "Movie",
        .tv => "TV",
        .album => "Music",
        .anime => "Anime",
        .other => "",
    };
}

// ══════════════════════════════════════════════════════════════════
// Poster / cover art URL
// ══════════════════════════════════════════════════════════════════

pub const TMDB_IMG_BASE = "https://image.tmdb.org/t/p/w500";

/// Resolve the stashed art reference to a fetchable URL.
///
/// TMDB hands out a path fragment ("/abc.jpg"), and the loading screen used to
/// hard-code the TMDB base around it — which is exactly why no non-TMDB source
/// could ever show art here. An absolute URL (a Subsonic/Jellyfin/Plex cover, a
/// JioSaavn CDN image, an anime poster) now passes through untouched, so one
/// field serves every source.
///
/// Returns an empty slice when there is nothing to fetch, so callers can test
/// `.len == 0` instead of unwrapping.
pub fn posterUrl(raw: []const u8, buf: []u8) []const u8 {
    if (raw.len == 0) return buf[0..0];
    if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://")) {
        if (raw.len > buf.len) return buf[0..0];
        @memcpy(buf[0..raw.len], raw);
        return buf[0..raw.len];
    }
    // A bare TMDB fragment. It always starts with '/', but tolerate one that
    // does not rather than producing a URL with a missing separator.
    const sep: []const u8 = if (raw[0] == '/') "" else "/";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ TMDB_IMG_BASE, sep, raw }) catch buf[0..0];
}

// ══════════════════════════════════════════════════════════════════
// Fact cards
// ══════════════════════════════════════════════════════════════════

/// Most cards worth cycling through. A Wikipedia lead paragraph rarely yields
/// more than four or five usable sentences.
pub const MAX_CARDS = 6;

/// Below this a "sentence" is an abbreviation or a stray fragment, not a fact —
/// it gets glued onto the previous card instead of becoming its own.
pub const MIN_CARD_LEN = 40;

pub const Cards = struct {
    starts: [MAX_CARDS]usize = [_]usize{0} ** MAX_CARDS,
    ends: [MAX_CARDS]usize = [_]usize{0} ** MAX_CARDS,
    count: usize = 0,

    pub fn slice(self: *const Cards, text: []const u8, i: usize) []const u8 {
        if (i >= self.count) return text[0..0];
        const s = @min(self.starts[i], text.len);
        const e = @min(self.ends[i], text.len);
        if (e <= s) return text[0..0];
        return text[s..e];
    }
};

/// Cut `text` into sentence-sized cards the screen can rotate through.
///
/// Splits on ". " / "! " / "? " only — a period with no following space is an
/// abbreviation, a decimal or an initial ("J.R.R."), and splitting there
/// produced one-word cards. Fragments under MIN_CARD_LEN are merged forward for
/// the same reason. Text with no sentence break at all yields exactly one card,
/// so the caller never has to special-case a short summary.
pub fn splitFacts(text: []const u8) Cards {
    var out: Cards = .{};
    const first = leadingSpace(text);
    if (first >= text.len) return out;

    var start = first;
    var i = first;
    while (i < text.len and out.count < MAX_CARDS) {
        const c = text[i];
        const is_end = (c == '.' or c == '!' or c == '?');
        const boundary = is_end and (i + 1 == text.len or text[i + 1] == ' ' or text[i + 1] == '\n');
        if (!boundary) {
            i += 1;
            continue;
        }
        const end = i + 1;
        if (end - start >= MIN_CARD_LEN) {
            out.starts[out.count] = start;
            out.ends[out.count] = end;
            out.count += 1;
            start = end + leadingSpace(text[end..]);
            i = start;
            continue;
        }
        // Too short to be a fact on its own. If there is a previous card, glue
        // it on; otherwise keep scanning WITHOUT moving `start`, so the
        // fragment merges forward into the next sentence. This is what keeps
        // "J.R.R." and "7.8" from each becoming their own card.
        if (out.count > 0) {
            out.ends[out.count - 1] = end;
            start = end + leadingSpace(text[end..]);
            i = start;
        } else {
            i = end;
        }
    }

    // Trailing text with no terminator: keep it if substantial, else fold it
    // into the last card rather than dropping half a sentence.
    if (start < text.len and out.count < MAX_CARDS) {
        if (text.len - start >= MIN_CARD_LEN) {
            out.starts[out.count] = start;
            out.ends[out.count] = text.len;
            out.count += 1;
        } else if (out.count > 0) {
            out.ends[out.count - 1] = text.len;
        }
    }

    // Nothing met the length floor — a one-line summary, or a blurb that is all
    // abbreviations. Show it whole rather than showing nothing.
    if (out.count == 0) {
        out.starts[0] = first;
        out.ends[0] = text.len;
        out.count = 1;
    }
    return out;
}

fn leadingSpace(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and (s[n] == ' ' or s[n] == '\n' or s[n] == '\t')) n += 1;
    return n;
}

/// How long each card stays up before the deck advances on its own.
pub const CARD_INTERVAL_MS: i64 = 7000;

/// Which card is showing. `elapsed_ms` is time since the last manual page (the
/// caller resets it on a click, so tapping ‹ › does not fight the auto-rotate),
/// `manual` is how many times the user has paged. Wraps in both directions and
/// is safe for count 0 or a negative clock.
pub fn cardIndex(count: usize, elapsed_ms: i64, manual: usize) usize {
    if (count == 0) return 0;
    const ticks: usize = if (elapsed_ms <= 0) 0 else @intCast(@divFloor(elapsed_ms, CARD_INTERVAL_MS));
    return (manual +% ticks) % count;
}

// ══════════════════════════════════════════════════════════════════
// Header line
// ══════════════════════════════════════════════════════════════════

/// The line under the title: "Movie · 2024 · 78%", skipping whatever is
/// missing so a source with no year or rating does not render stray separators.
///
/// The score is a PERCENTAGE, matching how every other Opal surface prints a
/// TMDB rating (grid cards, Home rails) — one convention, not two. Ratings of 0
/// mean "not rated / no votes yet" in TMDB's payload rather than a zero score,
/// so they are omitted instead of printed as "0%".
pub fn metaLine(buf: []u8, kind: MediaKind, year: []const u8, rating: f32, extra: []const u8) []const u8 {
    var w: usize = 0;
    const parts = [_][]const u8{ kindLabel(kind), year, extra };
    for (parts) |part| {
        if (part.len == 0) continue;
        w += appendPart(buf, w, part);
    }
    if (rating > 0.0 and rating <= 10.0) {
        var rbuf: [16]u8 = undefined;
        const pct: u32 = @intFromFloat(@round(rating * 10.0));
        const r = std.fmt.bufPrint(&rbuf, "{d}%", .{pct}) catch return buf[0..w];
        w += appendPart(buf, w, r);
    }
    return buf[0..w];
}

fn appendPart(buf: []u8, at: usize, part: []const u8) usize {
    const sep: []const u8 = if (at == 0) "" else " \u{00B7} ";
    const need = sep.len + part.len;
    if (at + need > buf.len) return 0;
    @memcpy(buf[at .. at + sep.len], sep);
    @memcpy(buf[at + sep.len .. at + need], part);
    return need;
}

// ══════════════════════════════════════════════════════════════════
// Truncation
// ══════════════════════════════════════════════════════════════════

/// A real ellipsis, not three periods — the screen already prints "·" as a
/// separator and "..." next to it reads as a rendering glitch.
pub const ELLIPSIS = "\u{2026}";

/// Fit `text` into `buf` (at most `max` bytes), cutting at a WORD boundary and
/// appending a real ellipsis when anything was dropped.
///
/// Two things are being fixed here. `loading_overview` / `loading_trivia` are
/// fixed `[400]u8` buffers, so a longer TMDB synopsis or Wikipedia lead arrives
/// already cut — mid-word, with no marker — and the screen showed the stump
/// ("…directed by Denis Villeneuv"). Pass `cut_upstream = true` for text whose
/// source length hit its capacity (see `filledBuffer`) and the trailing partial
/// word is dropped with an ellipsis in its place. Separately, `max` caps what a
/// narrow cell can show, and that cut is made at a space too.
///
/// Text that is complete AND fits is copied through untouched — no ellipsis is
/// added to a sentence that actually ended. Cutting always lands on a UTF-8
/// codepoint boundary, so the result is safe to hand to dvui.
pub fn ellipsizeWords(text: []const u8, max: usize, buf: []u8, cut_upstream: bool) []const u8 {
    if (buf.len == 0) return buf[0..0];
    const trimmed = trimEnd(text);
    if (trimmed.len == 0) return buf[0..0];

    const cap = @min(max, buf.len);
    if (cap == 0) return buf[0..0];

    // An upstream cut that happens to land on a sentence end reads fine as-is.
    var ellipsize = cut_upstream and !endsSentence(trimmed);
    var end = trimmed.len;
    if (end > cap) {
        ellipsize = true;
        end = cap;
    }

    if (!ellipsize) {
        @memcpy(buf[0..end], trimmed[0..end]);
        return buf[0..end];
    }

    const room = if (cap > ELLIPSIS.len) cap - ELLIPSIS.len else 0;
    if (room == 0) return buf[0..0];
    if (end > room) end = room;
    end = wordFloor(trimmed, end);
    if (end == 0) return buf[0..0];

    @memcpy(buf[0..end], trimmed[0..end]);
    @memcpy(buf[end .. end + ELLIPSIS.len], ELLIPSIS);
    return buf[0 .. end + ELLIPSIS.len];
}

/// True when `len` reached `cap`, i.e. the fixed buffer that holds this text
/// was filled and the source was almost certainly longer. The only signal a
/// `[N]u8` + len field gives that its contents are incomplete.
pub fn filledBuffer(len: usize, cap: usize) bool {
    return len > 0 and len >= cap;
}

/// Largest index at or below `limit` that ends a whole word: back up to the
/// last space, then strip trailing separator punctuation so the ellipsis never
/// follows a comma or a dangling hyphen. Falls back to a codepoint boundary
/// when the text has no space at all (one very long token).
fn wordFloor(text: []const u8, limit: usize) usize {
    var end = @min(limit, text.len);
    var i = end;
    while (i > 0) : (i -= 1) {
        const ch = text[i - 1];
        if (ch == ' ' or ch == '\n' or ch == '\t') {
            end = i - 1;
            break;
        }
    } else {
        // No space found — cut where we are, on a codepoint boundary.
        return utf8Floor(text, end);
    }
    while (end > 0) {
        switch (text[end - 1]) {
            ' ', '\n', '\t', ',', ';', ':', '-', '(', '[' => end -= 1,
            else => break,
        }
    }
    return utf8Floor(text, end);
}

/// Largest index at or below `i` that starts a UTF-8 codepoint. dvui asserts
/// valid UTF-8 when laying out text, so a cut inside a multi-byte sequence is
/// a panic, not a cosmetic bug.
fn utf8Floor(text: []const u8, i: usize) usize {
    var n = @min(i, text.len);
    // Cutting at `n` splits a sequence exactly when text[n] is a continuation
    // byte (0b10xxxxxx); back up until it is not.
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

fn trimEnd(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 0 and (s[n - 1] == ' ' or s[n - 1] == '\n' or s[n - 1] == '\t' or s[n - 1] == '\r')) n -= 1;
    return s[0..n];
}

fn endsSentence(s: []const u8) bool {
    if (s.len == 0) return false;
    return switch (s[s.len - 1]) {
        '.', '!', '?', '"', '\'', ')' => true,
        else => false,
    };
}

// ══════════════════════════════════════════════════════════════════
// Progress readout
// ══════════════════════════════════════════════════════════════════

/// 0..1 fraction → whole percent. Non-finite input (a NaN from a torrent that
/// vanished mid-poll) is 0, and a partial buffer never rounds up to 100 — "100%"
/// on a screen that is still buffering reads as a hang.
pub fn percentOf(frac: f32) u8 {
    if (!std.math.isFinite(frac)) return 0;
    if (frac >= 1.0) return 100;
    if (frac <= 0.0) return 0;
    const p: u32 = @intFromFloat(@floor(frac * 100.0));
    return @intCast(@min(p, 99));
}

/// Clamp an already-percent value (stream_gate reports 0..100 directly).
pub fn clampPercent(pct: i32) u8 {
    return @intCast(@max(0, @min(100, pct)));
}

/// Human download rate. Returns EMPTY for a non-positive rate: the caller drops
/// the element entirely rather than printing "0.0 MB/s", which looks like a
/// stall even when the torrent is mid-handshake and simply has no rate yet.
pub fn formatRate(buf: []u8, bytes_per_sec: i64) []const u8 {
    if (bytes_per_sec <= 0) return buf[0..0];
    const b: f64 = @floatFromInt(bytes_per_sec);
    if (bytes_per_sec < 1024) return std.fmt.bufPrint(buf, "{d} B/s", .{bytes_per_sec}) catch buf[0..0];
    if (bytes_per_sec < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.0} KB/s", .{b / 1024.0}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{b / (1024.0 * 1024.0)}) catch buf[0..0];
}

/// `M:SS` / `H:MM:SS` for the wait so far. Empty for a non-positive elapsed —
/// a clock that has not started yet says nothing rather than "0:00".
pub fn formatElapsed(buf: []u8, secs: i64) []const u8 {
    if (secs <= 0) return buf[0..0];
    const s: u64 = @intCast(@min(secs, 359_999)); // cap at 99:59:59
    const h = s / 3600;
    const m = (s % 3600) / 60;
    const sec = s % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, sec }) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, sec }) catch buf[0..0];
}

/// Everything the swarm readout can show. Negative or zero means "not known
/// yet" for every field — each one is omitted rather than printed as a zero.
pub const Stats = struct {
    rate_bps: i64 = 0,
    peers: i32 = 0,
    seeds: i32 = 0,
    elapsed_secs: i64 = 0,
};

/// "1.4 MB/s · 12 peers · 3 seeds · 0:42", dropping whatever is unavailable.
/// An entirely unknown swarm yields an empty string, so the caller can skip the
/// row instead of drawing an empty one.
pub fn statusLine(buf: []u8, s: Stats) []const u8 {
    var w: usize = 0;
    var scratch: [24]u8 = undefined;

    const rate = formatRate(&scratch, s.rate_bps);
    if (rate.len > 0) w += appendPart(buf, w, rate);

    if (s.peers > 0) {
        var pb: [24]u8 = undefined;
        const unit: []const u8 = if (s.peers == 1) "peer" else "peers";
        if (std.fmt.bufPrint(&pb, "{d} {s}", .{ s.peers, unit })) |t| {
            w += appendPart(buf, w, t);
        } else |_| {}
    }
    if (s.seeds > 0) {
        var sb: [24]u8 = undefined;
        const unit: []const u8 = if (s.seeds == 1) "seed" else "seeds";
        if (std.fmt.bufPrint(&sb, "{d} {s}", .{ s.seeds, unit })) |t| {
            w += appendPart(buf, w, t);
        } else |_| {}
    }
    var eb: [16]u8 = undefined;
    const el = formatElapsed(&eb, s.elapsed_secs);
    if (el.len > 0) w += appendPart(buf, w, el);

    return buf[0..w];
}

// ══════════════════════════════════════════════════════════════════
// Phase
// ══════════════════════════════════════════════════════════════════

/// Where the load actually is. The old screen showed one static hourglass for
/// the whole minute, so "still finding peers" and "buffered, handing to mpv"
/// looked identical — and identical to hung.
pub const Phase = enum { opening, connecting, metadata, buffering, starting };

pub fn phaseOf(is_torrent: bool, has_metadata: bool, peers: i32, buffer_pct: u8) Phase {
    if (!is_torrent) return .opening;
    if (!has_metadata) return if (peers > 0) .metadata else .connecting;
    if (buffer_pct >= 100) return .starting;
    return .buffering;
}

pub fn phaseLabel(p: Phase) []const u8 {
    return switch (p) {
        .opening => "Opening stream",
        .connecting => "Finding peers",
        .metadata => "Fetching torrent details",
        .buffering => "Buffering",
        .starting => "Starting playback",
    };
}

/// Whether a percentage is worth showing next to the phase label. Peer discovery
/// and metadata exchange have no meaningful percentage — the whole-torrent
/// progress is 0 there and printing "Finding peers 0%" implies a stall.
pub fn phaseShowsPercent(p: Phase) bool {
    return p == .buffering or p == .starting;
}

// ══════════════════════════════════════════════════════════════════
// Layout
// ══════════════════════════════════════════════════════════════════

/// What fits at a given cell size, in on-screen points (see core/scale_pure).
/// The loading screen lives in a grid CELL, which in a 3x3 workspace is a few
/// hundred points — the poster, the fact deck and the swarm readout are shed
/// in that order rather than overflowing.
pub const Layout = struct {
    poster: bool,
    facts: bool,
    stats: bool,
    piece_bar: bool,
    /// Width the text column is capped to, so a line never runs the full width
    /// of a maximised window (unreadable) nor overflows a narrow cell.
    content_w: f32,
    /// Tallest the poster card may be. Its width follows from the aspect.
    poster_max_h: f32,
    /// Byte budget for the fact card at this size.
    fact_max: usize,
};

pub const BREAK_STATS_W: f32 = 220;
pub const BREAK_POSTER_W: f32 = 260;
pub const BREAK_POSTER_H: f32 = 300;
pub const BREAK_FACTS_W: f32 = 340;
pub const BREAK_FACTS_H: f32 = 420;

pub fn layout(w_pt: f32, h_pt: f32) Layout {
    // A zero/garbage size is the pre-layout first frame: assume roomy so the
    // screen does not flash its collapsed form for one frame.
    const w = if (std.math.isFinite(w_pt) and w_pt > 1) w_pt else 1280;
    const h = if (std.math.isFinite(h_pt) and h_pt > 1) h_pt else 720;

    // Wide enough to read, never wider than the cell: a maximised window would
    // otherwise stretch a line of trivia edge to edge, and a tiny cell would be
    // handed a column wider than itself and clip it.
    const content_w = @min(@max(60.0, w - 32.0), @max(180.0, @min(520.0, w - 48.0)));
    const facts = w >= BREAK_FACTS_W and h >= BREAK_FACTS_H;
    return .{
        .poster = w >= BREAK_POSTER_W and h >= BREAK_POSTER_H,
        .facts = facts,
        .stats = w >= BREAK_STATS_W,
        .piece_bar = w >= BREAK_STATS_W and h >= 200,
        .content_w = content_w,
        .poster_max_h = @max(90.0, @min(220.0, h * 0.30)),
        .fact_max = if (facts and h >= 560) 260 else 170,
    };
}

pub const Size = struct { w: f32, h: f32 };

/// Fit a texture inside `max_w` x `max_h`, preserving aspect and NEVER
/// upscaling.
///
/// This is the whole reason the screen looked bad: the art was drawn with
/// `.expand = .both`, so a TMDB **w500** poster (500x750) was stretched across
/// a 1400x800 cell — a ~3x upscale, which is why it came out soft and
/// colour-cast, and it swamped the text besides. Capping the scale at 1.0 keeps
/// the poster pixel-exact; the cell background stays a themed flat fill where
/// contrast is guaranteed in every preset.
pub fn posterFit(nat_w: u32, nat_h: u32, max_w: f32, max_h: f32) Size {
    if (nat_w == 0 or nat_h == 0) return .{ .w = 0, .h = 0 };
    if (!std.math.isFinite(max_w) or !std.math.isFinite(max_h)) return .{ .w = 0, .h = 0 };
    if (max_w <= 0 or max_h <= 0) return .{ .w = 0, .h = 0 };
    const nw: f32 = @floatFromInt(nat_w);
    const nh: f32 = @floatFromInt(nat_h);
    const scale = @min(1.0, @min(max_w / nw, max_h / nh));
    return .{ .w = @round(nw * scale), .h = @round(nh * scale) };
}

// ══════════════════════════════════════════════════════════════════
// Piece map
// ══════════════════════════════════════════════════════════════════

/// How many segments the piece bar is drawn in. A torrent has thousands of
/// pieces; one rect each would be thousands of draw calls a frame for detail no
/// one can see at this width.
pub const PIECE_BUCKETS = 48;

/// Downsample a libtorrent piece map ('1' = have) into `out.len` coverage
/// fractions, one per drawn segment. Returns the number of buckets written.
/// An empty map writes nothing, so the caller skips the bar instead of drawing
/// an all-zero one that looks like a dead torrent.
pub fn pieceBuckets(map: []const u8, out: []f32) usize {
    if (map.len == 0 or out.len == 0) return 0;
    const n = @min(out.len, map.len);
    for (0..n) |b| {
        const lo = map.len * b / n;
        var hi = map.len * (b + 1) / n;
        if (hi <= lo) hi = lo + 1;
        if (hi > map.len) hi = map.len;
        var have: usize = 0;
        for (map[lo..hi]) |ch| {
            if (ch == '1') have += 1;
        }
        out[b] = @as(f32, @floatFromInt(have)) / @as(f32, @floatFromInt(hi - lo));
    }
    return n;
}

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "posterUrl expands a TMDB fragment and passes an absolute URL through" {
    var b: [256]u8 = undefined;
    try expectEqualStrings(
        "https://image.tmdb.org/t/p/w500/abc123.jpg",
        posterUrl("/abc123.jpg", &b),
    );
    // REGRESSION: the base used to be hard-coded at the call site, so a
    // Subsonic/Jellyfin/JioSaavn cover URL came out as
    // "https://image.tmdb.org/t/p/w500https://..." — i.e. no music source could
    // ever show art on the loading screen.
    const abs = "https://music.example.com/rest/getCoverArt?id=al-9&size=512";
    try expectEqualStrings(abs, posterUrl(abs, &b));
    try expectEqualStrings("http://nas.local/art.png", posterUrl("http://nas.local/art.png", &b));
    // A fragment missing its leading slash still produces a valid URL.
    try expectEqualStrings("https://image.tmdb.org/t/p/w500/x.jpg", posterUrl("x.jpg", &b));
}

test "posterUrl yields an empty slice rather than a truncated URL" {
    var b: [256]u8 = undefined;
    try expectEqual(@as(usize, 0), posterUrl("", &b).len);
    // Too small to hold the result: empty, never a half URL that 404s.
    var tiny: [8]u8 = undefined;
    try expectEqual(@as(usize, 0), posterUrl("/abc123.jpg", &tiny).len);
    try expectEqual(@as(usize, 0), posterUrl("https://example.com/a-very-long-url.jpg", &tiny).len);
}

test "splitFacts cuts on sentence ends, not on every period" {
    const text = "Dune is a 2021 epic science fiction film directed by Denis Villeneuve. " ++
        "It was co-written by Jon Spaihts, Villeneuve and Eric Roth. " ++
        "The film stars an ensemble cast and was released to acclaim.";
    const cards = splitFacts(text);
    try expectEqual(@as(usize, 3), cards.count);
    try expect(std.mem.startsWith(u8, cards.slice(text, 0), "Dune is a 2021"));
    try expect(std.mem.endsWith(u8, cards.slice(text, 0), "Villeneuve."));
    try expect(std.mem.startsWith(u8, cards.slice(text, 1), "It was co-written"));
    // No leading space bleeds into a card.
    for (0..cards.count) |i| try expect(cards.slice(text, i)[0] != ' ');
}

test "splitFacts does not break on abbreviations or decimals" {
    // "J.R.R." and "7.8" have periods with no following space — splitting there
    // produced one- and two-character cards.
    const text = "The novel by J.R.R. Tolkien holds a rating of 7.8 out of 10 on the site. " ++
        "It was adapted for the screen several decades after publication.";
    const cards = splitFacts(text);
    try expectEqual(@as(usize, 2), cards.count);
    try expect(std.mem.indexOf(u8, cards.slice(text, 0), "J.R.R. Tolkien") != null);
    try expect(std.mem.indexOf(u8, cards.slice(text, 0), "7.8") != null);
}

test "splitFacts always yields one card for text with no sentence break" {
    const short = "A short blurb with no terminator";
    const c1 = splitFacts(short);
    try expectEqual(@as(usize, 1), c1.count);
    try expectEqualStrings(short, c1.slice(short, 0));

    const one = "Exactly one complete sentence that runs past the minimum length.";
    const c2 = splitFacts(one);
    try expectEqual(@as(usize, 1), c2.count);
    try expectEqualStrings(one, c2.slice(one, 0));

    const empty = splitFacts("");
    try expectEqual(@as(usize, 0), empty.count);
    try expectEqual(@as(usize, 0), empty.slice("", 0).len);
}

test "splitFacts is bounded and never emits an out-of-range slice" {
    var long: [4000]u8 = undefined;
    var i: usize = 0;
    while (i + 50 < long.len) : (i += 50) {
        @memcpy(long[i .. i + 50], "This is a padded sentence of fifty characters.... ");
    }
    const cards = splitFacts(long[0..i]);
    try expect(cards.count <= MAX_CARDS);
    for (0..cards.count) |n| {
        const s = cards.slice(long[0..i], n);
        try expect(s.len > 0);
        try expect(cards.ends[n] <= i);
        try expect(cards.starts[n] < cards.ends[n]);
    }
    // Asking past the end is empty, not a panic.
    try expectEqual(@as(usize, 0), cards.slice(long[0..i], MAX_CARDS + 3).len);
}

test "cardIndex auto-rotates, wraps, and honours manual paging" {
    // Nothing to show.
    try expectEqual(@as(usize, 0), cardIndex(0, 999_999, 3));
    // Before the first interval elapses, card 0.
    try expectEqual(@as(usize, 0), cardIndex(3, 0, 0));
    try expectEqual(@as(usize, 0), cardIndex(3, CARD_INTERVAL_MS - 1, 0));
    // One interval → next card; wraps at the end.
    try expectEqual(@as(usize, 1), cardIndex(3, CARD_INTERVAL_MS, 0));
    try expectEqual(@as(usize, 2), cardIndex(3, 2 * CARD_INTERVAL_MS, 0));
    try expectEqual(@as(usize, 0), cardIndex(3, 3 * CARD_INTERVAL_MS, 0));
    // Manual paging offsets the deck; the caller resets elapsed on a click so
    // the freshly-chosen card gets a full interval.
    try expectEqual(@as(usize, 1), cardIndex(3, 0, 1));
    try expectEqual(@as(usize, 0), cardIndex(3, 0, 3));
    try expectEqual(@as(usize, 1), cardIndex(3, 0, 4));
    // A clock that goes backwards (the load started before a resync) must not
    // underflow into a huge index.
    try expectEqual(@as(usize, 0), cardIndex(3, -5000, 0));
    try expect(cardIndex(3, -5000, 2) < 3);
}

test "metaLine joins only the parts that exist" {
    var b: [96]u8 = undefined;
    try expectEqualStrings("Movie \u{00B7} 2021 \u{00B7} 78%", metaLine(&b, .movie, "2021", 7.8, ""));
    try expectEqualStrings("TV \u{00B7} S2E4", metaLine(&b, .tv, "", 0, "S2E4"));
    // A music track has no year or rating — no dangling separators.
    try expectEqualStrings("Music \u{00B7} Boards of Canada", metaLine(&b, .album, "", 0, "Boards of Canada"));
    // Unknown kind with nothing else is empty, not a lone separator.
    try expectEqualStrings("", metaLine(&b, .other, "", 0, ""));
}

test "metaLine omits an unrated score instead of printing zero" {
    var b: [96]u8 = undefined;
    // TMDB sends 0 for "no votes yet"; printing "0%" reads as a terrible
    // score rather than as "unrated".
    try expectEqualStrings("Movie \u{00B7} 1999", metaLine(&b, .movie, "1999", 0, ""));
    try expectEqualStrings("Movie \u{00B7} 1999", metaLine(&b, .movie, "1999", -1, ""));
    // Out-of-range values (a malformed payload) are dropped too.
    try expectEqualStrings("Movie \u{00B7} 1999", metaLine(&b, .movie, "1999", 99, ""));
    try expectEqualStrings("Movie \u{00B7} 1999 \u{00B7} 100%", metaLine(&b, .movie, "1999", 10, ""));
    // Rounds rather than truncates: 7.85 is 79%, not 78%.
    try expectEqualStrings("Movie \u{00B7} 1999 \u{00B7} 79%", metaLine(&b, .movie, "1999", 7.85, ""));
}

test "metaLine never overruns a small buffer" {
    var tiny: [10]u8 = undefined;
    const s = metaLine(&tiny, .movie, "2021", 7.8, "a-very-long-extra-part");
    try expect(s.len <= tiny.len);
    // What fits, fits; nothing past the end is written.
    try expect(std.mem.startsWith(u8, "Movie", s[0..@min(s.len, 5)]));
}

test "ellipsizeWords leaves complete text that fits alone" {
    var b: [128]u8 = undefined;
    const s = "A complete sentence that fits.";
    try expectEqualStrings(s, ellipsizeWords(s, 128, &b, false));
    // Trailing whitespace is trimmed, but nothing is marked as cut.
    try expectEqualStrings(s, ellipsizeWords(s ++ "   ", 128, &b, false));
    try expectEqualStrings("", ellipsizeWords("", 128, &b, true));
    try expectEqualStrings("", ellipsizeWords("   ", 128, &b, true));
}

test "ellipsizeWords cuts at a word boundary, never mid-word" {
    // REGRESSION: the loading screen showed the raw tail of a [400]u8 buffer,
    // so a long synopsis ended mid-word with no marker ("...directed by
    // Denis Villeneuv"). Every cut now lands on a space and carries a real
    // ellipsis.
    var b: [64]u8 = undefined;
    const text = "Dune is a 2021 epic science fiction film directed by Denis Villeneuve";
    const out = ellipsizeWords(text, 30, &b, false);
    try expect(std.mem.endsWith(u8, out, ELLIPSIS));
    const body = out[0 .. out.len - ELLIPSIS.len];
    try expect(body.len <= 30 - ELLIPSIS.len);
    // Whatever survived is a whole prefix of the source ending on a word.
    try expect(std.mem.startsWith(u8, text, body));
    try expect(text[body.len] == ' ');
    try expect(body[body.len - 1] != ' ');
}

test "ellipsizeWords marks text the fixed buffer already cut off" {
    var b: [128]u8 = undefined;
    // Fits in `max`, but the source hit its capacity — the last word is a
    // stump and gets dropped along with an ellipsis in its place.
    const stump = "It was co-written by Jon Spaihts and Eric Rot";
    const out = ellipsizeWords(stump, 128, &b, true);
    try expectEqualStrings("It was co-written by Jon Spaihts and Eric" ++ ELLIPSIS, out);
    // An upstream cut that happens to land on a sentence end reads fine, so
    // no ellipsis is bolted onto a finished sentence.
    const done = "It was co-written by Jon Spaihts and Eric Roth.";
    try expectEqualStrings(done, ellipsizeWords(done, 128, &b, true));
}

test "ellipsizeWords strips dangling punctuation before the ellipsis" {
    var b: [64]u8 = undefined;
    const out = ellipsizeWords("Villeneuve, Spaihts, and Roth wrote the screenplay", 20, &b, false);
    try expect(std.mem.endsWith(u8, out, ELLIPSIS));
    const body = out[0 .. out.len - ELLIPSIS.len];
    try expect(body.len > 0);
    try expect(body[body.len - 1] != ',');
    try expect(body[body.len - 1] != ' ');
}

test "ellipsizeWords never splits a UTF-8 codepoint" {
    // dvui asserts valid UTF-8 while laying out text, so a cut inside a
    // multi-byte sequence is a panic, not a cosmetic bug.
    var b: [64]u8 = undefined;
    const text = "Amélie Poulain rêve d'un monde meilleur à Montmartre chaque jour";
    var limit: usize = 4;
    while (limit <= 40) : (limit += 1) {
        const out = ellipsizeWords(text, limit, &b, false);
        try expect(out.len <= limit);
        try expect(std.unicode.utf8ValidateSlice(out));
    }
    // A single unbroken multi-byte token still comes out valid.
    const token = "ééééééééééééééééééééééé";
    const out = ellipsizeWords(token, 11, &b, false);
    try expect(std.unicode.utf8ValidateSlice(out));
    try expect(out.len <= 11);
}

test "ellipsizeWords survives a buffer with no room" {
    var tiny: [2]u8 = undefined;
    try expectEqual(@as(usize, 0), ellipsizeWords("a long piece of text", 2, &tiny, false).len);
    var b: [64]u8 = undefined;
    try expectEqual(@as(usize, 0), ellipsizeWords("a long piece of text", 0, &b, false).len);
    // max larger than the buffer is clamped to the buffer, not overrun.
    var small: [8]u8 = undefined;
    const out = ellipsizeWords("alpha beta gamma delta", 1000, &small, false);
    try expect(out.len <= small.len);
}

test "filledBuffer only flags a buffer that actually filled" {
    try expect(filledBuffer(400, 400));
    try expect(!filledBuffer(399, 400));
    try expect(!filledBuffer(0, 400));
}

test "percentOf clamps and refuses to round a partial buffer up to 100" {
    try expectEqual(@as(u8, 0), percentOf(0));
    try expectEqual(@as(u8, 42), percentOf(0.425));
    try expectEqual(@as(u8, 100), percentOf(1.0));
    try expectEqual(@as(u8, 100), percentOf(4.0));
    try expectEqual(@as(u8, 0), percentOf(-1.0));
    // 99.7% is still buffering — showing "100%" on a screen that then sits
    // there is exactly the "is it hung?" complaint.
    try expectEqual(@as(u8, 99), percentOf(0.997));
    // Garbage in (a torrent that vanished mid-poll) reads as "no progress
    // known", never as a finished buffer.
    try expectEqual(@as(u8, 0), percentOf(std.math.nan(f32)));
    try expectEqual(@as(u8, 0), percentOf(-std.math.inf(f32)));
    try expectEqual(@as(u8, 0), percentOf(std.math.inf(f32)));
    try expectEqual(@as(u8, 0), clampPercent(-5));
    try expectEqual(@as(u8, 100), clampPercent(250));
    try expectEqual(@as(u8, 37), clampPercent(37));
}

test "formatRate omits a rate it does not have" {
    var b: [24]u8 = undefined;
    // A torrent mid-handshake has no rate; "0.0 MB/s" reads as a stall.
    try expectEqualStrings("", formatRate(&b, 0));
    try expectEqualStrings("", formatRate(&b, -1));
    try expectEqualStrings("512 B/s", formatRate(&b, 512));
    try expectEqualStrings("820 KB/s", formatRate(&b, 820 * 1024));
    try expectEqualStrings("1.5 MB/s", formatRate(&b, 1536 * 1024));
}

test "formatElapsed shows nothing until the clock starts" {
    var b: [16]u8 = undefined;
    try expectEqualStrings("", formatElapsed(&b, 0));
    try expectEqualStrings("", formatElapsed(&b, -3));
    try expectEqualStrings("0:07", formatElapsed(&b, 7));
    try expectEqualStrings("1:05", formatElapsed(&b, 65));
    try expectEqualStrings("1:00:00", formatElapsed(&b, 3600));
}

test "statusLine drops every element it does not have" {
    var b: [96]u8 = undefined;
    try expectEqualStrings(
        "1.5 MB/s \u{00B7} 12 peers \u{00B7} 3 seeds \u{00B7} 0:42",
        statusLine(&b, .{ .rate_bps = 1536 * 1024, .peers = 12, .seeds = 3, .elapsed_secs = 42 }),
    );
    // Nothing known yet → empty, so the caller skips the row entirely rather
    // than drawing "0.0 MB/s - 0 peers", which looks like a dead torrent.
    try expectEqualStrings("", statusLine(&b, .{}));
    try expectEqualStrings("0:09", statusLine(&b, .{ .elapsed_secs = 9 }));
    try expectEqualStrings("1 peer \u{00B7} 0:09", statusLine(&b, .{ .peers = 1, .elapsed_secs = 9 }));
    try expectEqualStrings("1 seed", statusLine(&b, .{ .seeds = 1 }));
    // Negative counts are "unknown", not something to print.
    try expectEqualStrings("", statusLine(&b, .{ .peers = -1, .seeds = -1 }));
    // A small buffer truncates cleanly instead of overrunning.
    var tiny: [8]u8 = undefined;
    const s = statusLine(&tiny, .{ .rate_bps = 1536 * 1024, .peers = 12, .seeds = 3 });
    try expect(s.len <= tiny.len);
}

test "phaseOf distinguishes the stages a static hourglass hid" {
    try expectEqual(Phase.opening, phaseOf(false, false, 0, 0));
    try expectEqual(Phase.connecting, phaseOf(true, false, 0, 0));
    try expectEqual(Phase.metadata, phaseOf(true, false, 5, 0));
    try expectEqual(Phase.buffering, phaseOf(true, true, 5, 40));
    try expectEqual(Phase.starting, phaseOf(true, true, 5, 100));
    // No percentage is meaningful before metadata arrives.
    try expect(!phaseShowsPercent(.connecting));
    try expect(!phaseShowsPercent(.metadata));
    try expect(!phaseShowsPercent(.opening));
    try expect(phaseShowsPercent(.buffering));
    try expect(phaseShowsPercent(.starting));
    for ([_]Phase{ .opening, .connecting, .metadata, .buffering, .starting }) |p| {
        try expect(phaseLabel(p).len > 0);
    }
}

test "layout sheds poster then facts as the cell shrinks" {
    const big = layout(1280, 800);
    try expect(big.poster and big.facts and big.stats and big.piece_bar);

    // A 3x3 workspace cell: room for the poster and the swarm readout, not
    // for a paragraph of trivia.
    const cell = layout(420, 380);
    try expect(cell.poster and cell.stats);
    try expect(!cell.facts);

    // A short strip: text and numbers only.
    const strip = layout(400, 180);
    try expect(!strip.poster and !strip.facts and !strip.piece_bar);
    try expect(strip.stats);

    // Tiny: nothing but the phase line.
    const tiny = layout(150, 120);
    try expect(!tiny.poster and !tiny.facts and !tiny.stats and !tiny.piece_bar);

    // Content width is capped at both ends: never full-bleed on a 4K window,
    // and never wider than the cell it has to fit inside.
    try expect(big.content_w <= 520);
    try expect(layout(3840, 2160).content_w <= 520);
    for ([_]f32{ 120, 200, 260, 400, 900 }) |w| {
        const l = layout(w, 400);
        try expect(l.content_w <= w);
        try expect(l.content_w > 0);
    }
    try expect(layout(600, 400).content_w >= 180);

    // A pre-layout zero size assumes roomy rather than flashing the collapsed
    // form for a frame.
    const first = layout(0, 0);
    try expect(first.poster and first.facts);
    const nan = layout(std.math.nan(f32), std.math.nan(f32));
    try expect(nan.poster and nan.facts);

    // The poster never eats the cell.
    for ([_]f32{ 300, 500, 800, 1600 }) |h| {
        const l = layout(1280, h);
        try expect(l.poster_max_h <= 220);
        try expect(l.poster_max_h <= @max(90.0, h * 0.30) + 0.01);
    }
}

test "posterFit contains, preserves aspect, and never upscales" {
    // REGRESSION: the art was drawn with `.expand = .both`, so a w500 TMDB
    // poster was blown up across the whole cell — soft, colour-cast, and it
    // swamped the text. Scale is capped at 1.0.
    const up = posterFit(500, 750, 1400, 800);
    try expectEqual(@as(f32, 500), up.w);
    try expectEqual(@as(f32, 750), up.h);

    // Height-bound: 2:3 poster into a 200-tall slot.
    const fit = posterFit(500, 750, 400, 200);
    try expectEqual(@as(f32, 200), fit.h);
    try expectEqual(@as(f32, 133), fit.w);

    // Width-bound: a wide backdrop into a narrow column.
    const wide = posterFit(1000, 500, 200, 400);
    try expectEqual(@as(f32, 200), wide.w);
    try expectEqual(@as(f32, 100), wide.h);

    // Degenerate inputs paint nothing rather than a NaN rect.
    try expectEqual(@as(f32, 0), posterFit(0, 0, 100, 100).w);
    try expectEqual(@as(f32, 0), posterFit(500, 750, 0, 100).w);
    try expectEqual(@as(f32, 0), posterFit(500, 750, -5, 100).w);
    try expectEqual(@as(f32, 0), posterFit(500, 750, std.math.nan(f32), 100).w);
}

test "pieceBuckets downsamples a piece map into drawable segments" {
    var out: [PIECE_BUCKETS]f32 = undefined;

    // Empty map → nothing drawn (not an all-zero bar that looks dead).
    try expectEqual(@as(usize, 0), pieceBuckets("", &out));
    try expectEqual(@as(usize, 0), pieceBuckets("1111", out[0..0]));

    // Front half complete.
    var map: [1000]u8 = undefined;
    for (0..map.len) |i| map[i] = if (i < 500) '1' else '0';
    const n = pieceBuckets(&map, &out);
    try expectEqual(@as(usize, PIECE_BUCKETS), n);
    try expectEqual(@as(f32, 1.0), out[0]);
    try expectEqual(@as(f32, 0.0), out[n - 1]);
    for (0..n) |b| try expect(out[b] >= 0.0 and out[b] <= 1.0);

    // Fewer pieces than buckets: one bucket per piece, no divide-by-zero.
    const few = "101";
    const fn_ = pieceBuckets(few, &out);
    try expectEqual(@as(usize, 3), fn_);
    try expectEqual(@as(f32, 1.0), out[0]);
    try expectEqual(@as(f32, 0.0), out[1]);
    try expectEqual(@as(f32, 1.0), out[2]);
}

test "MediaKind survives a corrupt integer" {
    try expectEqual(MediaKind.movie, MediaKind.fromInt(0));
    try expectEqual(MediaKind.other, MediaKind.fromInt(4));
    // Out of range saturates rather than producing an invalid tag.
    try expectEqual(MediaKind.other, MediaKind.fromInt(200));
    // Round-trip.
    for ([_]MediaKind{ .movie, .tv, .album, .anime, .other }) |k| {
        try expectEqual(k, MediaKind.fromInt(k.toInt()));
        try expect(kindLabel(k).len > 0 or k == .other);
    }
}
