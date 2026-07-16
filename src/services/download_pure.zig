//! Pure logic for the segmented HTTP downloader (download_engine.zig).
//!
//! Everything here is deterministic math/string work with no io/state/dvui
//! imports, so it is unit-testable in isolation (registered in build.zig's
//! `test` step). The engine ROUTES through these functions — the tested logic
//! is the shipped logic:
//!   - planSegments / pickSegmentCount: how a file is split across connections
//!   - remainingRanges: what is left to fetch after a pause / restart
//!   - TokenBucket.take: global speed-limit refill math (shared by all segments)
//!   - backoffMs: the per-segment retry schedule (1s / 4s / 15s)
//!   - SpeedWindow: rolling-average speed for a stable ETA
//!   - writePartMeta / parsePartMeta: the `<file>.opal-part.json` sidecar
//!   - fmtSpeed / fmtEta / fmtBytes / filenameFromUrl: display helpers

const std = @import("std");

pub const MAX_SEGMENTS: usize = 8;
pub const MAX_RETRIES: u32 = 3;
/// No point opening another connection for less than this many bytes.
pub const MIN_SEGMENT_BYTES: u64 = 256 * 1024;
/// A segment that has moved no bytes for this long is considered stalled and
/// gets reconnected (does not count against the retry budget once bytes flow).
pub const STALL_MS: i64 = 30_000;

pub const Segment = struct { offset: u64 = 0, len: u64 = 0 };

// ══════════════════════════════════════════════════════════
// Segment planning
// ══════════════════════════════════════════════════════════

/// Split `total` into `n` contiguous segments covering it EXACTLY (no gaps, no
/// overlap). n is clamped to [1, MAX_SEGMENTS] and never exceeds `total` (a
/// segment is at least 1 byte). total == 0 yields one empty segment (a valid
/// "unknown size / empty file" plan).
pub fn planSegments(total: u64, n: usize, out: *[MAX_SEGMENTS]Segment) usize {
    var count = @min(@max(n, 1), MAX_SEGMENTS);
    if (total == 0) {
        out[0] = .{ .offset = 0, .len = 0 };
        return 1;
    }
    if (@as(u64, count) > total) count = @intCast(total);
    const base = total / count;
    const rem = total % count;
    var off: u64 = 0;
    for (0..count) |i| {
        const len = base + @as(u64, if (i < rem) 1 else 0);
        out[i] = .{ .offset = off, .len = len };
        off += len;
    }
    return count;
}

/// How many connections a file of `total` bytes deserves: the configured count
/// (clamped to [1, MAX_SEGMENTS]), further reduced so every segment is at
/// least MIN_SEGMENT_BYTES. Unknown size (0) → 1.
pub fn pickSegmentCount(total: u64, configured: usize) usize {
    const cfg = @min(@max(configured, 1), MAX_SEGMENTS);
    if (total == 0) return 1;
    const by_size: u64 = @max(total / MIN_SEGMENT_BYTES, 1);
    return @intCast(@min(@as(u64, cfg), by_size));
}

/// Resume merge: given the original plan and per-segment completed byte counts
/// (as persisted in the sidecar), emit the ranges STILL to be fetched. `done`
/// is clamped to each segment's length. Returns how many entries of `out` and
/// `which` were filled; `which[i]` is the source segment index (so the engine
/// can keep crediting progress to the right slot).
pub fn remainingRanges(
    segs: []const Segment,
    done: []const u64,
    out: *[MAX_SEGMENTS]Segment,
    which: *[MAX_SEGMENTS]usize,
) usize {
    var n: usize = 0;
    const count = @min(segs.len, done.len);
    for (0..count) |i| {
        const d = @min(done[i], segs[i].len);
        if (d >= segs[i].len and segs[i].len > 0) continue;
        if (segs[i].len == 0) continue; // empty segment: nothing to fetch
        out[n] = .{ .offset = segs[i].offset + d, .len = segs[i].len - d };
        which[n] = i;
        n += 1;
    }
    return n;
}

/// Sum of persisted per-segment progress, clamped to the plan.
pub fn totalDone(segs: []const Segment, done: []const u64) u64 {
    var sum: u64 = 0;
    const count = @min(segs.len, done.len);
    for (0..count) |i| sum += @min(done[i], segs[i].len);
    return sum;
}

// ══════════════════════════════════════════════════════════
// Token bucket — global speed limit shared across segments
// ══════════════════════════════════════════════════════════

pub const TokenBucket = struct {
    /// bytes per second; 0 = unlimited.
    rate: u64 = 0,
    /// bucket capacity in ms worth of rate (burst window).
    burst_ms: u64 = 500,
    tokens: u64 = 0,
    last_ms: i64 = 0,
};

/// Refill from wall clock then take up to `want` bytes. Returns bytes granted
/// (0 = caller should sleep briefly and retry). Integer-exact: `last_ms` only
/// advances by the milliseconds actually converted into tokens, so no credit
/// is lost to rounding when called at a high frequency.
pub fn take(b: *TokenBucket, now_ms: i64, want: u64) u64 {
    if (b.rate == 0) return want; // unlimited
    if (b.last_ms == 0 or now_ms < b.last_ms) {
        b.last_ms = now_ms;
        b.tokens = @min(b.tokens, capacity(b));
    }
    const dt: u64 = @intCast(@max(now_ms - b.last_ms, 0));
    if (dt > 0) {
        const add = (b.rate * dt) / 1000;
        if (add > 0) {
            b.tokens = @min(b.tokens + add, capacity(b));
            // Advance only by the time actually converted to tokens.
            const used_ms = (add * 1000 + b.rate - 1) / b.rate;
            b.last_ms += @intCast(@min(used_ms, dt));
        }
    }
    const grant = @min(want, b.tokens);
    b.tokens -= grant;
    return grant;
}

fn capacity(b: *const TokenBucket) u64 {
    return @max((b.rate * b.burst_ms) / 1000, 1);
}

// ══════════════════════════════════════════════════════════
// Retry backoff
// ══════════════════════════════════════════════════════════

/// Exponential-ish schedule per failed attempt: 1s, 4s, 15s (capped).
pub fn backoffMs(attempt: u32) u64 {
    return switch (attempt) {
        0 => 1_000,
        1 => 4_000,
        else => 15_000,
    };
}

// ══════════════════════════════════════════════════════════
// Rolling speed window → stable rate + ETA
// ══════════════════════════════════════════════════════════

pub const SpeedWindow = struct {
    const N = 16;
    pub const WINDOW_MS: i64 = 6_000;
    ms: [N]i64 = @splat(0),
    bytes: [N]u64 = @splat(0), // cumulative downloaded bytes at sample time
    head: usize = 0,
    count: usize = 0,

    pub fn push(w: *SpeedWindow, now_ms: i64, cum_bytes: u64) void {
        w.ms[w.head] = now_ms;
        w.bytes[w.head] = cum_bytes;
        w.head = (w.head + 1) % N;
        if (w.count < N) w.count += 1;
    }

    pub fn reset(w: *SpeedWindow) void {
        w.* = .{};
    }

    /// Average bytes/sec over the samples inside the rolling window.
    pub fn rate(w: *const SpeedWindow, now_ms: i64) u64 {
        var oldest_ms: i64 = 0;
        var oldest_bytes: u64 = 0;
        var newest_ms: i64 = 0;
        var newest_bytes: u64 = 0;
        var seen = false;
        for (0..w.count) |k| {
            const idx = (w.head + N - 1 - k) % N; // newest → oldest
            if (now_ms - w.ms[idx] > WINDOW_MS) break;
            if (!seen) {
                newest_ms = w.ms[idx];
                newest_bytes = w.bytes[idx];
                seen = true;
            }
            oldest_ms = w.ms[idx];
            oldest_bytes = w.bytes[idx];
        }
        if (!seen or newest_ms <= oldest_ms) return 0;
        const db = newest_bytes -| oldest_bytes;
        const dt: u64 = @intCast(newest_ms - oldest_ms);
        return (db * 1000) / dt;
    }
};

pub fn etaSeconds(remaining: u64, rate_bps: u64) ?u64 {
    if (rate_bps == 0) return null;
    return remaining / rate_bps;
}

// ══════════════════════════════════════════════════════════
// Sidecar metadata — `<file>.opal-part.json`
// ══════════════════════════════════════════════════════════

pub const URL_LEN: usize = 2048;
pub const ETAG_LEN: usize = 160;

pub const PartMeta = struct {
    url: [URL_LEN]u8 = std.mem.zeroes([URL_LEN]u8),
    url_len: usize = 0,
    etag: [ETAG_LEN]u8 = std.mem.zeroes([ETAG_LEN]u8),
    etag_len: usize = 0,
    total: u64 = 0,
    seg_count: usize = 1,
    done: [MAX_SEGMENTS]u64 = @splat(0),
    /// True when the user paused explicitly — a restart then restores the entry
    /// as paused instead of auto-resuming it.
    paused: bool = false,

    pub fn urlSlice(m: *const PartMeta) []const u8 {
        return m.url[0..@min(m.url_len, URL_LEN)];
    }
    pub fn etagSlice(m: *const PartMeta) []const u8 {
        return m.etag[0..@min(m.etag_len, ETAG_LEN)];
    }
    pub fn setUrl(m: *PartMeta, s: []const u8) void {
        const n = @min(s.len, URL_LEN);
        @memcpy(m.url[0..n], s[0..n]);
        m.url_len = n;
    }
    pub fn setEtag(m: *PartMeta, s: []const u8) void {
        const n = @min(s.len, ETAG_LEN);
        @memcpy(m.etag[0..n], s[0..n]);
        m.etag_len = n;
    }
};

fn jsonEscapeInto(s: []const u8, buf: []u8, at: *usize) bool {
    for (s) |ch| {
        if (ch == '"' or ch == '\\') {
            if (at.* + 2 > buf.len) return false;
            buf[at.*] = '\\';
            buf[at.* + 1] = ch;
            at.* += 2;
        } else if (ch < 0x20) {
            // Control chars never belong in a URL/etag — drop them.
        } else {
            if (at.* + 1 > buf.len) return false;
            buf[at.*] = ch;
            at.* += 1;
        }
    }
    return true;
}

/// Serialize sidecar metadata to JSON in `buf`. Null on overflow.
pub fn writePartMeta(m: *const PartMeta, buf: []u8) ?[]const u8 {
    var at: usize = 0;
    const head = std.fmt.bufPrint(buf, "{{\"v\":1,\"url\":\"", .{}) catch return null;
    at = head.len;
    if (!jsonEscapeInto(m.urlSlice(), buf, &at)) return null;
    const mid = std.fmt.bufPrint(buf[at..], "\",\"etag\":\"", .{}) catch return null;
    at += mid.len;
    if (!jsonEscapeInto(m.etagSlice(), buf, &at)) return null;
    const mid2 = std.fmt.bufPrint(buf[at..], "\",\"total\":{d},\"segments\":{d},\"paused\":{d},\"done\":[", .{
        m.total, @min(@max(m.seg_count, 1), MAX_SEGMENTS), @as(u8, if (m.paused) 1 else 0),
    }) catch return null;
    at += mid2.len;
    const count = @min(@max(m.seg_count, 1), MAX_SEGMENTS);
    for (0..count) |i| {
        const part = std.fmt.bufPrint(buf[at..], "{s}{d}", .{ if (i == 0) "" else ",", m.done[i] }) catch return null;
        at += part.len;
    }
    const tail = std.fmt.bufPrint(buf[at..], "]}}", .{}) catch return null;
    at += tail.len;
    return buf[0..at];
}

fn jsonFindString(json: []const u8, key: []const u8, out: []u8) ?usize {
    var kb: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&kb, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = idx + needle.len;
    var n: usize = 0;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (ch == '\\' and i + 1 < json.len) {
            if (n < out.len) {
                out[n] = json[i + 1];
                n += 1;
            }
            i += 1;
            continue;
        }
        if (ch == '"') return n;
        if (n < out.len) {
            out[n] = ch;
            n += 1;
        }
    }
    return null;
}

fn jsonFindInt(json: []const u8, key: []const u8) ?u64 {
    var kb: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&kb, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = idx + needle.len;
    var v: u64 = 0;
    var any = false;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {
        v = v *% 10 +% (json[i] - '0');
        any = true;
    }
    return if (any) v else null;
}

/// Parse a sidecar written by writePartMeta. Returns false on anything that
/// does not look like a valid v1 sidecar (the engine then restarts from 0).
pub fn parsePartMeta(json: []const u8, m: *PartMeta) bool {
    m.* = .{};
    if (jsonFindInt(json, "v") != 1) return false;
    m.url_len = jsonFindString(json, "url", &m.url) orelse return false;
    if (m.url_len == 0) return false;
    m.etag_len = jsonFindString(json, "etag", &m.etag) orelse 0;
    m.total = jsonFindInt(json, "total") orelse return false;
    const sc = jsonFindInt(json, "segments") orelse return false;
    if (sc < 1 or sc > MAX_SEGMENTS) return false;
    m.seg_count = @intCast(sc);
    m.paused = (jsonFindInt(json, "paused") orelse 0) != 0;
    // done array
    const key = "\"done\":[";
    const di = std.mem.indexOf(u8, json, key) orelse return false;
    var i = di + key.len;
    var slot: usize = 0;
    var v: u64 = 0;
    var any = false;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (ch >= '0' and ch <= '9') {
            v = v *% 10 +% (ch - '0');
            any = true;
        } else if (ch == ',' or ch == ']') {
            if (any and slot < MAX_SEGMENTS) {
                m.done[slot] = v;
                slot += 1;
            }
            v = 0;
            any = false;
            if (ch == ']') break;
        } else return false;
    }
    return slot >= m.seg_count;
}

// ══════════════════════════════════════════════════════════
// HTTP header helpers
// ══════════════════════════════════════════════════════════

/// Total size from a `Content-Range: bytes 0-0/12345` value. Null when the
/// total is unknown ("*") or the header is malformed.
pub fn parseContentRangeTotal(value: []const u8) ?u64 {
    const slash = std.mem.lastIndexOfScalar(u8, value, '/') orelse return null;
    const tail = std.mem.trim(u8, value[slash + 1 ..], " \t");
    if (tail.len == 0 or tail[0] == '*') return null;
    return std.fmt.parseInt(u64, tail, 10) catch null;
}

// ══════════════════════════════════════════════════════════
// Display helpers
// ══════════════════════════════════════════════════════════

pub fn fmtSpeed(bytes_per_sec: u64, buf: []u8) []const u8 {
    const b = @as(f64, @floatFromInt(bytes_per_sec));
    if (b >= 1048576.0) return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{b / 1048576.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0} KB/s", .{b / 1024.0}) catch "?";
}

pub fn fmtBytes(bytes: u64, buf: []u8) []const u8 {
    const b = @as(f64, @floatFromInt(bytes));
    if (b >= 1073741824.0) return std.fmt.bufPrint(buf, "{d:.1} GB", .{b / 1073741824.0}) catch "?";
    if (b >= 1048576.0) return std.fmt.bufPrint(buf, "{d:.0} MB", .{b / 1048576.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0} KB", .{b / 1024.0}) catch "?";
}

pub fn fmtEta(secs: u64, buf: []u8) []const u8 {
    if (secs >= 3600) {
        return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ secs / 3600, (secs % 3600) / 60 }) catch "?";
    }
    if (secs >= 60) {
        return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ secs / 60, secs % 60 }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "?";
}

/// Last path component of a URL (query/fragment stripped, percent-decoded
/// lightly for %20). Falls back to "download" when the URL has no usable name.
pub fn filenameFromUrl(url: []const u8, buf: []u8) []const u8 {
    var path = url;
    if (std.mem.indexOf(u8, path, "://")) |i| path = path[i + 3 ..];
    if (std.mem.indexOfAny(u8, path, "?#")) |i| path = path[0..i];
    while (path.len > 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else blk: {
        // Host only — no path component.
        break :blk @as([]const u8, "");
    };
    if (base.len == 0) {
        const fb = "download";
        const n = @min(fb.len, buf.len);
        @memcpy(buf[0..n], fb[0..n]);
        return buf[0..n];
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i < base.len and n < buf.len) {
        if (base[i] == '%' and i + 2 < base.len and base[i + 1] == '2' and base[i + 2] == '0') {
            buf[n] = ' ';
            i += 3;
        } else if (base[i] == '/' or base[i] == '\\' or base[i] == 0) {
            i += 1; // never let a separator through
            continue;
        } else {
            buf[n] = base[i];
            i += 1;
        }
        n += 1;
    }
    if (n == 0) {
        const fb = "download";
        const m = @min(fb.len, buf.len);
        @memcpy(buf[0..m], fb[0..m]);
        return buf[0..m];
    }
    return buf[0..n];
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "planSegments: exact coverage — no gaps, no overlap, sums to total" {
    var out: [MAX_SEGMENTS]Segment = undefined;
    // Property sweep over awkward totals and every n.
    const totals = [_]u64{ 1, 2, 3, 7, 8, 9, 100, 1023, 1024, 1025, 20 * 1024 * 1024 + 13 };
    for (totals) |total| {
        for (1..MAX_SEGMENTS + 1) |n| {
            const count = planSegments(total, n, &out);
            try std.testing.expect(count >= 1 and count <= MAX_SEGMENTS);
            var sum: u64 = 0;
            var expect_off: u64 = 0;
            for (0..count) |i| {
                try std.testing.expectEqual(expect_off, out[i].offset); // contiguous: no gap/overlap
                try std.testing.expect(out[i].len > 0);
                expect_off += out[i].len;
                sum += out[i].len;
            }
            try std.testing.expectEqual(total, sum);
        }
    }
}

test "planSegments: tiny files and n > total" {
    var out: [MAX_SEGMENTS]Segment = undefined;
    // 3-byte file split "8 ways" → 3 one-byte segments.
    try std.testing.expectEqual(@as(usize, 3), planSegments(3, 8, &out));
    for (0..3) |i| try std.testing.expectEqual(@as(u64, 1), out[i].len);
    // 1-byte file.
    try std.testing.expectEqual(@as(usize, 1), planSegments(1, 4, &out));
    try std.testing.expectEqual(@as(u64, 1), out[0].len);
    // Unknown/zero size → one empty segment.
    try std.testing.expectEqual(@as(usize, 1), planSegments(0, 4, &out));
    try std.testing.expectEqual(@as(u64, 0), out[0].len);
    // n clamped: 0 behaves like 1, 99 like MAX.
    try std.testing.expectEqual(@as(usize, 1), planSegments(1000, 0, &out));
    try std.testing.expectEqual(MAX_SEGMENTS, planSegments(100 * 1024 * 1024, 99, &out));
}

test "pickSegmentCount honors MIN_SEGMENT_BYTES" {
    // 100KB file: one connection is plenty.
    try std.testing.expectEqual(@as(usize, 1), pickSegmentCount(100 * 1024, 4));
    // 1MB file at 256KB min → 4.
    try std.testing.expectEqual(@as(usize, 4), pickSegmentCount(1024 * 1024, 8));
    // Big file → configured count, clamped to MAX.
    try std.testing.expectEqual(@as(usize, 4), pickSegmentCount(1 << 30, 4));
    try std.testing.expectEqual(MAX_SEGMENTS, pickSegmentCount(1 << 30, 20));
    try std.testing.expectEqual(@as(usize, 1), pickSegmentCount(0, 4));
}

test "remainingRanges: resume merge picks up exactly where each segment left off" {
    var segs: [MAX_SEGMENTS]Segment = undefined;
    const count = planSegments(1000, 4, &segs); // 4 × 250
    try std.testing.expectEqual(@as(usize, 4), count);

    var done = [_]u64{ 250, 100, 0, 300 }; // seg0 complete, seg3 overshoot (clamped)
    var out: [MAX_SEGMENTS]Segment = undefined;
    var which: [MAX_SEGMENTS]usize = undefined;
    const n = remainingRanges(segs[0..count], done[0..count], &out, &which);
    try std.testing.expectEqual(@as(usize, 2), n);
    // seg1: 250..500 with 100 done → fetch 350..500 (150 bytes)
    try std.testing.expectEqual(@as(usize, 1), which[0]);
    try std.testing.expectEqual(@as(u64, 350), out[0].offset);
    try std.testing.expectEqual(@as(u64, 150), out[0].len);
    // seg2 untouched.
    try std.testing.expectEqual(@as(usize, 2), which[1]);
    try std.testing.expectEqual(@as(u64, 500), out[1].offset);
    try std.testing.expectEqual(@as(u64, 250), out[1].len);
    // Remaining + done covers the file exactly.
    try std.testing.expectEqual(@as(u64, 600), totalDone(segs[0..count], done[0..count]));
    var rem_sum: u64 = 0;
    for (0..n) |i| rem_sum += out[i].len;
    try std.testing.expectEqual(@as(u64, 1000 - 600), rem_sum);

    // Everything done → nothing remains.
    done = .{ 250, 250, 250, 250 };
    try std.testing.expectEqual(@as(usize, 0), remainingRanges(segs[0..count], done[0..count], &out, &which));
}

test "TokenBucket: refill math, cap, and unlimited mode" {
    var b = TokenBucket{ .rate = 1000, .burst_ms = 500 }; // 1000 B/s, cap 500
    // t=0: bucket starts empty (first call seeds last_ms).
    try std.testing.expectEqual(@as(u64, 0), take(&b, 1_000, 800));
    // +100ms → 100 tokens.
    try std.testing.expectEqual(@as(u64, 100), take(&b, 1_100, 800));
    // +1000ms → capped at 500, not 1000.
    try std.testing.expectEqual(@as(u64, 500), take(&b, 2_100, 800));
    // Partial grant then drained.
    _ = take(&b, 2_100, 0);
    try std.testing.expectEqual(@as(u64, 0), take(&b, 2_100, 10));
    // Sub-token intervals must not lose credit: 10 calls 1ms apart at 1000B/s
    // must accumulate ~10 tokens total, not 0.
    var b2 = TokenBucket{ .rate = 1000, .burst_ms = 500 };
    _ = take(&b2, 5_000, 0); // seed
    var granted: u64 = 0;
    var t: i64 = 5_001;
    while (t <= 5_010) : (t += 1) granted += take(&b2, t, 1);
    try std.testing.expect(granted >= 9 and granted <= 10);
    // Unlimited.
    var u = TokenBucket{ .rate = 0 };
    try std.testing.expectEqual(@as(u64, 12345), take(&u, 1, 12345));
    // Clock going backwards must not panic or mint tokens.
    var b3 = TokenBucket{ .rate = 1000 };
    _ = take(&b3, 10_000, 0);
    try std.testing.expectEqual(@as(u64, 0), take(&b3, 9_000, 100));
}

test "backoffMs schedule is 1s / 4s / 15s (capped)" {
    try std.testing.expectEqual(@as(u64, 1_000), backoffMs(0));
    try std.testing.expectEqual(@as(u64, 4_000), backoffMs(1));
    try std.testing.expectEqual(@as(u64, 15_000), backoffMs(2));
    try std.testing.expectEqual(@as(u64, 15_000), backoffMs(9));
}

test "SpeedWindow: rolling average, stale samples expire" {
    var w = SpeedWindow{};
    try std.testing.expectEqual(@as(u64, 0), w.rate(0));
    // 1000 bytes/sec steady.
    w.push(1_000, 0);
    w.push(2_000, 1_000);
    w.push(3_000, 2_000);
    try std.testing.expectEqual(@as(u64, 1_000), w.rate(3_000));
    // A burst then silence: window slides past the old samples.
    try std.testing.expectEqual(@as(u64, 0), w.rate(60_000));
    // Rolling: only samples inside WINDOW_MS count.
    var w2 = SpeedWindow{};
    w2.push(0, 0);
    w2.push(10_000, 100); // slow era, outside window later
    w2.push(11_000, 10_100); // 10KB/s era
    w2.push(12_000, 20_100);
    const r = w2.rate(12_000);
    try std.testing.expectEqual(@as(u64, 10_000), r);
}

test "etaSeconds" {
    try std.testing.expectEqual(@as(?u64, null), etaSeconds(1000, 0));
    try std.testing.expectEqual(@as(?u64, 10), etaSeconds(1000, 100));
}

test "parseContentRangeTotal" {
    try std.testing.expectEqual(@as(?u64, 12345), parseContentRangeTotal("bytes 0-0/12345"));
    try std.testing.expectEqual(@as(?u64, 7), parseContentRangeTotal("bytes 2-6/7"));
    try std.testing.expectEqual(@as(?u64, null), parseContentRangeTotal("bytes 0-0/*"));
    try std.testing.expectEqual(@as(?u64, null), parseContentRangeTotal("garbage"));
}

test "PartMeta sidecar: JSON round-trip including escapes" {
    var m = PartMeta{ .total = 20 * 1024 * 1024, .seg_count = 4, .paused = true };
    m.setUrl("https://ex.com/a%20b/file \"v1\".bin?x=1&y=2");
    m.setEtag("W/\"abc-123\"");
    m.done = .{ 100, 0, 5_242_880, 42, 0, 0, 0, 0 };

    var buf: [4096]u8 = undefined;
    const json = writePartMeta(&m, &buf) orelse return error.TestUnexpectedResult;

    var back = PartMeta{};
    try std.testing.expect(parsePartMeta(json, &back));
    try std.testing.expectEqualStrings(m.urlSlice(), back.urlSlice());
    try std.testing.expectEqualStrings("W/\"abc-123\"", back.etagSlice());
    try std.testing.expectEqual(m.total, back.total);
    try std.testing.expectEqual(@as(usize, 4), back.seg_count);
    try std.testing.expectEqual(@as(u64, 5_242_880), back.done[2]);
    try std.testing.expectEqual(@as(u64, 42), back.done[3]);
    try std.testing.expect(back.paused);
}

test "parsePartMeta rejects garbage and wrong versions" {
    var m = PartMeta{};
    try std.testing.expect(!parsePartMeta("", &m));
    try std.testing.expect(!parsePartMeta("{}", &m));
    try std.testing.expect(!parsePartMeta("{\"v\":2,\"url\":\"x\",\"total\":1,\"segments\":1,\"done\":[0]}", &m));
    try std.testing.expect(!parsePartMeta("{\"v\":1,\"url\":\"\",\"total\":1,\"segments\":1,\"done\":[0]}", &m));
    // segments out of range
    try std.testing.expect(!parsePartMeta("{\"v\":1,\"url\":\"x\",\"total\":1,\"segments\":99,\"done\":[0]}", &m));
    // done array shorter than segments
    try std.testing.expect(!parsePartMeta("{\"v\":1,\"url\":\"x\",\"total\":9,\"segments\":3,\"done\":[0,1]}", &m));
    // valid minimal
    try std.testing.expect(parsePartMeta("{\"v\":1,\"url\":\"x\",\"etag\":\"\",\"total\":9,\"segments\":2,\"done\":[4,5]}", &m));
    try std.testing.expectEqual(@as(u64, 5), m.done[1]);
}

test "fmtSpeed / fmtEta / fmtBytes" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 KB/s", fmtSpeed(512 * 1024, &b));
    try std.testing.expectEqualStrings("2.0 MB/s", fmtSpeed(2 * 1024 * 1024, &b));
    try std.testing.expectEqualStrings("45s", fmtEta(45, &b));
    try std.testing.expectEqualStrings("2m 05s", fmtEta(125, &b));
    try std.testing.expectEqualStrings("1h 01m", fmtEta(3660, &b));
    try std.testing.expectEqualStrings("20 MB", fmtBytes(20 * 1024 * 1024, &b));
    try std.testing.expectEqualStrings("1.5 GB", fmtBytes(1536 * 1024 * 1024, &b));
}

test "filenameFromUrl" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("file.zip", filenameFromUrl("https://a.b/c/file.zip", &b));
    try std.testing.expectEqualStrings("file.zip", filenameFromUrl("https://a.b/c/file.zip?tok=1#frag", &b));
    try std.testing.expectEqualStrings("my file.bin", filenameFromUrl("http://x/y/my%20file.bin", &b));
    try std.testing.expectEqualStrings("download", filenameFromUrl("https://host.com/", &b));
    try std.testing.expectEqualStrings("download", filenameFromUrl("https://host.com", &b));
}
