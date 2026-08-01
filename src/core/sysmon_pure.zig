//! Resource-meter decisions: how a raw sample becomes a bar and a colour.
//!
//! Kept separate from the sampler (which is full of mach/proc syscalls) and from
//! the widget (which is dvui), so the part that can actually be wrong — the
//! thresholds, the clamping, the human-readable formatting — is testable.
//!
//! Pure: std only.

const std = @import("std");

/// Severity of a reading. The nav meters colour-code on this.
pub const Level = enum { ok, warn, hot };

/// A single metric, already normalised.
pub const Metric = struct {
    /// 0.0-1.0, saturating. This is what the bar draws.
    frac: f32 = 0,
    /// The number the label shows (percent, MB, count …) — units are the caller's.
    value: f32 = 0,
    level: Level = .ok,
};

/// Bar fraction: clamped to 0-1 and NaN-safe.
///
/// A NaN would propagate straight into a widget's width and dvui would draw a
/// garbage rect (or panic); a sampler that briefly divides by zero must not be
/// able to do that.
pub fn frac(value: f32, max: f32) f32 {
    if (max <= 0) return 0;
    if (std.math.isNan(value) or std.math.isNan(max)) return 0;
    return std.math.clamp(value / max, 0, 1);
}

/// Severity from a 0-1 fraction. Two thresholds, one place.
pub fn levelOf(f: f32, warn_at: f32, hot_at: f32) Level {
    if (std.math.isNan(f)) return .ok;
    if (f >= hot_at) return .hot;
    if (f >= warn_at) return .warn;
    return .ok;
}

// Thresholds, named rather than sprinkled through the widget.
pub const CPU_WARN: f32 = 0.60;
pub const CPU_HOT: f32 = 0.85;
pub const MEM_WARN: f32 = 0.75;
pub const MEM_HOT: f32 = 0.90;
/// Threads: a healthy Opal sits well under 100. Past ~200 something is leaking
/// them (every detached worker that never exits shows up here).
pub const THREADS_MAX: f32 = 256;
pub const THREADS_WARN: f32 = 0.35;
pub const THREADS_HOT: f32 = 0.60;
/// Energy impact is unbounded in principle; 100 is "this app is the reason your
/// fan is on". Matches the order of magnitude Activity Monitor reports.
///
/// The thresholds are deliberately high: this is a MEDIA PLAYER, and decoding
/// video is its job. A busy decode (~60% of a core) must read "warm", not red —
/// a meter that screams during normal playback is a meter people learn to ignore.
pub const ENERGY_MAX: f32 = 100;
pub const ENERGY_WARN: f32 = 0.50;
pub const ENERGY_HOT: f32 = 0.80;

pub fn cpuMetric(pct: f32) Metric {
    const f = frac(pct, 100);
    return .{ .frac = f, .value = pct, .level = levelOf(f, CPU_WARN, CPU_HOT) };
}

pub fn memMetric(used_bytes: u64, total_bytes: u64) Metric {
    const used: f32 = @floatFromInt(used_bytes);
    const total: f32 = @floatFromInt(total_bytes);
    const f = frac(used, total);
    return .{ .frac = f, .value = f * 100, .level = levelOf(f, MEM_WARN, MEM_HOT) };
}

pub fn threadMetric(n: u32) Metric {
    const v: f32 = @floatFromInt(n);
    const f = frac(v, THREADS_MAX);
    return .{ .frac = f, .value = v, .level = levelOf(f, THREADS_WARN, THREADS_HOT) };
}

pub fn energyMetric(impact: f32) Metric {
    const f = frac(impact, ENERGY_MAX);
    return .{ .frac = f, .value = impact, .level = levelOf(f, ENERGY_WARN, ENERGY_HOT) };
}

/// Energy impact, derived the way the OS derives it: CPU time plus WAKEUPS.
///
/// There is no public API for a wattage reading, and inventing one from CPU alone
/// would be a plausible-but-wrong number. Wakeups are the other half of what makes
/// a laptop hot — a process that idles but wakes the core 500x/sec costs real
/// power — so both go in, and the result is labelled an impact score, not watts.
///
/// `cpu_pct` is 0-100 of one core; `wakeups_per_sec` is interrupt + idle wakeups.
pub fn energyImpact(cpu_pct: f32, wakeups_per_sec: f32) f32 {
    if (std.math.isNan(cpu_pct) or std.math.isNan(wakeups_per_sec)) return 0;
    const cpu = @max(0, cpu_pct);
    const wake = @max(0, wakeups_per_sec);
    // ~1 point per % of a core, plus ~1 point per 20 wakeups/sec. Calibrated so a
    // busy decode (60% CPU, ~100 wakeups) lands around 65 — "warm, not alarming".
    return cpu + (wake / 20.0);
}

/// Bytes → a compact human string ("1.2 GB", "870 MB"). Always <= 8 chars, so the
/// nav meter's width can't jitter as the number grows.
pub fn fmtBytes(bytes: u64, buf: []u8) []const u8 {
    const gb: f64 = 1024.0 * 1024.0 * 1024.0;
    const mb: f64 = 1024.0 * 1024.0;
    const b: f64 = @floatFromInt(bytes);

    if (b >= gb) {
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{b / gb}) catch "?";
    }
    if (b >= mb) {
        return std.fmt.bufPrint(buf, "{d:.0} MB", .{b / mb}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.0} KB", .{b / 1024.0}) catch "?";
}

/// Percent → "12%" / "100%". No decimals: the meter is a glance, not a profiler.
pub fn fmtPct(pct: f32, buf: []u8) []const u8 {
    const p = if (std.math.isNan(pct)) 0 else std.math.clamp(pct, 0, 999);
    return std.fmt.bufPrint(buf, "{d:.0}%", .{p}) catch "?";
}

// ── Window-title meters ──
//
// The meters live in the OS title bar, next to the window title. Not as pixels —
// SDL2 gives us no drawable surface up there (the content view can be extended
// under the title bar, but SDL keeps rendering into the old, shorter rect, so
// dvui's y=0 never moves — measured). What the OS *does* render there is the title
// string, so the meters are written INTO it.
//
// Text only, which is why each metric carries a single block glyph as its gauge:
// one character that fills as the value climbs. Cheap, and it reads at a glance.

/// Eight levels of fill. Index by fraction — a bar in one character.
const BARS = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

/// Divider `titleMeters` prefixes, for the un-justified (name-then-meters)
/// layout. Named so `metersBody` cannot drift from what titleMeters emits.
pub const TITLE_METERS_SEP = "  \u{258F}  ";

/// The meter run without its leading divider. When the two halves are justified
/// to opposite edges of the title bar there is nothing between them to divide,
/// and the glyph reads as a stray `|` hanging off the media name.
pub fn metersBody(meters: []const u8) []const u8 {
    if (std.mem.startsWith(u8, meters, TITLE_METERS_SEP)) return meters[TITLE_METERS_SEP.len..];
    return meters;
}

/// A metric's fill level as a single block character.
pub fn barGlyph(f: f32) []const u8 {
    const c = if (std.math.isNan(f)) 0 else std.math.clamp(f, 0, 1);
    // 1.0 must land on the last bar, not one past the end.
    const i: usize = @intFromFloat(@min(c * @as(f32, BARS.len), @as(f32, BARS.len - 1)));
    return BARS[i];
}

/// The meter run appended to the window title:
///   "  ▏  CPU ▃ 12%   MEM ▅ 1.2 GB   THR ▂ 180   NRG ▁ 6%"
///
/// Returns a slice of `buf`. On any formatting failure it returns an empty slice
/// rather than a partial run — a half-written meter in the title bar would look
/// like a bug, and the title itself must survive regardless.
pub fn titleMeters(
    cpu_pct: f32,
    mem_used: u64,
    mem_total: u64,
    threads: u32,
    energy: f32,
    buf: []u8,
) []const u8 {
    const cpu = cpuMetric(cpu_pct);
    const mem = memMetric(mem_used, mem_total);
    const thr = threadMetric(threads);
    const nrg = energyMetric(energy);

    var mem_buf: [16]u8 = undefined;
    const mem_str = fmtBytes(mem_used, &mem_buf);

    return std.fmt.bufPrint(
        buf,
        TITLE_METERS_SEP ++ "CPU {s} {d:.0}%   MEM {s} {s}   THR {s} {d}   NRG {s} {d:.0}%",
        .{
            barGlyph(cpu.frac), @round(std.math.clamp(cpu_pct, 0, 999)),
            barGlyph(mem.frac), mem_str,
            barGlyph(thr.frac), threads,
            barGlyph(nrg.frac), @round(std.math.clamp(energy, 0, 100)),
        },
    ) catch "";
}

// ── Title justification ──────────────────────────────────────────────────────
//
// The window title is ONE string handed to SDL_SetWindowTitle and rendered by
// the OS, so there is no layout engine up there and no second draw call: the
// only way to push the meters to the right edge is to pad between the two
// halves. macOS left-aligns a title too wide to centre without colliding with
// the traffic lights, which is the case here once the meters are appended.
//
// The pad is measured in CHARACTERS, because that is all a text-only title can
// express. `avg_advance_px` converts window width to a character budget; the
// title font is proportional, so this lands close rather than exact, and the
// meter run is deliberately monospace-ish digits so the right edge stays put as
// values change.

/// Characters that fit across a title bar `win_w` points wide.
///
/// `TITLE_CHROME_COLS` reserves the traffic lights and the right-hand window
/// controls so the meters never slide underneath them.
pub const TITLE_AVG_ADVANCE_PX: f32 = 7.0;
pub const TITLE_CHROME_COLS: usize = 14;

pub fn titleCols(win_w: i32) usize {
    if (win_w <= 0) return 0;
    const cols: f32 = @as(f32, @floatFromInt(win_w)) / TITLE_AVG_ADVANCE_PX;
    if (!(cols > 0)) return 0;
    const c: usize = @intFromFloat(@min(cols, 1000.0));
    return if (c > TITLE_CHROME_COLS) c - TITLE_CHROME_COLS else 0;
}

/// Display width of `s` in characters, counting a UTF-8 sequence as one.
/// Byte length would over-count the meter run badly — every bar glyph and the
/// em dash are 3 bytes — and the pad would collapse to nothing.
pub fn displayCols(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1; // count lead bytes only
    }
    return n;
}

/// Join `left` and `right` with enough spaces to push `right` to the right edge
/// of a `cols`-wide title bar. Falls back to a single-space join when they can't
/// both fit — a truncated title is worse than an unjustified one.
///
/// Returns a slice of `buf`, or just `left` if even that won't fit.
pub fn justifyTitle(left: []const u8, right: []const u8, cols: usize, buf: []u8) []const u8 {
    if (right.len == 0) return left;
    const lw = displayCols(left);
    const rw = displayCols(right);

    // +1 so there is always at least one space between the halves.
    const pad: usize = if (cols > lw + rw + 1) cols - lw - rw else 1;

    if (left.len + pad + right.len > buf.len) {
        // No room to justify. Join with one space rather than dropping a half.
        if (left.len + 1 + right.len <= buf.len) {
            @memcpy(buf[0..left.len], left);
            buf[left.len] = ' ';
            @memcpy(buf[left.len + 1 ..][0..right.len], right);
            return buf[0 .. left.len + 1 + right.len];
        }
        return left;
    }

    @memcpy(buf[0..left.len], left);
    @memset(buf[left.len..][0..pad], ' ');
    @memcpy(buf[left.len + pad ..][0..right.len], right);
    return buf[0 .. left.len + pad + right.len];
}

// ── Tests ──

const t = std.testing;

test "metersBody strips exactly the divider titleMeters emits" {
    var buf: [160]u8 = undefined;
    const run = titleMeters(12, 1288490188, 8589934592, 180, 6, &buf);
    try t.expect(std.mem.startsWith(u8, run, TITLE_METERS_SEP));
    const body = metersBody(run);
    try t.expect(std.mem.startsWith(u8, body, "CPU"));
    // Idempotent, and a run without the divider is returned untouched.
    try t.expectEqualStrings(body, metersBody(body));
    try t.expectEqualStrings("", metersBody(""));
}

test "displayCols counts characters, not bytes" {
    try t.expectEqual(@as(usize, 3), displayCols("abc"));
    // The bar glyphs and the em dash are 3 bytes each; byte length would treble
    // the measured width of the meter run and collapse the pad to nothing.
    try t.expectEqual(@as(usize, 1), displayCols("\u{258F}"));
    try t.expectEqual(@as(usize, 1), displayCols("\u{2014}"));
    try t.expectEqual(@as(usize, 5), displayCols("a\u{258F}b\u{2014}c"));
    try t.expectEqual(@as(usize, 0), displayCols(""));
}

test "justifyTitle pushes the meters to the right edge" {
    var buf: [300]u8 = undefined;
    const s = justifyTitle("Movie.mkv \u{2014} Opal", "CPU 2%", 40, &buf);
    try t.expectEqual(@as(usize, 40), displayCols(s));
    try t.expect(std.mem.startsWith(u8, s, "Movie.mkv"));
    try t.expect(std.mem.endsWith(u8, s, "CPU 2%"));
    // The gap must be spaces only — anything else would show up in the bar.
    const gap = s["Movie.mkv \u{2014} Opal".len .. s.len - "CPU 2%".len];
    try t.expect(gap.len > 1);
    for (gap) |ch| try t.expectEqual(@as(u8, ' '), ch);
}

test "justifyTitle: no room means one space, never a truncated title" {
    var buf: [300]u8 = undefined;
    // cols smaller than the two halves combined: must still contain both.
    const s = justifyTitle("a-very-long-media-name", "CPU 2%", 5, &buf);
    try t.expectEqualStrings("a-very-long-media-name CPU 2%", s);

    // A buffer too small to justify still joins rather than dropping the meters.
    var small: [30]u8 = undefined;
    const s2 = justifyTitle("abcdefghij", "CPU 2%", 900, &small);
    try t.expectEqualStrings("abcdefghij CPU 2%", s2);

    // A buffer too small even to join returns the name alone — never a half-
    // written meter run in the title bar.
    var tiny: [12]u8 = undefined;
    try t.expectEqualStrings("abcdefghij", justifyTitle("abcdefghij", "CPU 2%", 900, &tiny));
}

test "justifyTitle: empty meters are left exactly as they were" {
    // Before the first sysmon delta lands there are no meters at all; the title
    // must be the plain name, with no trailing pad.
    var buf: [300]u8 = undefined;
    try t.expectEqualStrings("Opal \u{2014} Play everything",
        justifyTitle("Opal \u{2014} Play everything", "", 200, &buf));
}

test "titleCols: reserves the window chrome and never underflows" {
    try t.expectEqual(@as(usize, 0), titleCols(0));
    try t.expectEqual(@as(usize, 0), titleCols(-100));
    // A window narrower than the reserved chrome yields 0, not a huge wrapped
    // usize — that would produce a pad of thousands of spaces.
    try t.expectEqual(@as(usize, 0), titleCols(10));
    try t.expect(titleCols(1440) > 100);
    try t.expect(titleCols(1440) < 1000);
}

test "barGlyph: spans the range, and 1.0 does not run off the end" {
    // The clamp matters: @intFromFloat(1.0 * 8) is 8, one past the last bar.
    try t.expectEqualStrings("▁", barGlyph(0));
    try t.expectEqualStrings("█", barGlyph(1.0));
    try t.expectEqualStrings("█", barGlyph(2.0)); // over-range clamps, not wraps
    try t.expectEqualStrings("▁", barGlyph(-1)); // under-range too
    try t.expectEqualStrings("▁", barGlyph(std.math.nan(f32)));

    // Monotonic: a rising value never picks a shorter bar.
    var prev: usize = 0;
    var i: f32 = 0;
    while (i <= 1.0) : (i += 0.05) {
        const g = barGlyph(i);
        var idx: usize = 0;
        for (BARS, 0..) |b, n| if (std.mem.eql(u8, b, g)) {
            idx = n;
        };
        try t.expect(idx >= prev);
        prev = idx;
    }
}

test "titleMeters: renders every metric into the title run" {
    var buf: [160]u8 = undefined;
    const s = titleMeters(12, 1288490188, 8589934592, 180, 6, &buf);

    try t.expect(std.mem.indexOf(u8, s, "CPU") != null);
    try t.expect(std.mem.indexOf(u8, s, "12%") != null);
    try t.expect(std.mem.indexOf(u8, s, "MEM") != null);
    try t.expect(std.mem.indexOf(u8, s, "1.2 GB") != null);
    try t.expect(std.mem.indexOf(u8, s, "THR") != null);
    try t.expect(std.mem.indexOf(u8, s, "180") != null);
    try t.expect(std.mem.indexOf(u8, s, "NRG") != null);
}

test "titleMeters: a short buffer yields nothing, never a truncated run" {
    // The title must still render if the meters don't fit — better no meters than
    // "Opal — Play everything  ▏  CPU ▃ 12%   MEM ▅ 1.2".
    var tiny: [8]u8 = undefined;
    try t.expectEqualStrings("", titleMeters(12, 1024, 8192, 4, 6, &tiny));
}

test "titleMeters: garbage in cannot corrupt the window title" {
    // A NaN CPU or a zero mem_total (before the first sample) must not produce
    // "NaN%" or a divide-by-zero in the title bar.
    var buf: [160]u8 = undefined;
    const s = titleMeters(std.math.nan(f32), 0, 0, 0, std.math.nan(f32), &buf);
    try t.expect(s.len > 0);
    try t.expect(std.mem.indexOf(u8, s, "nan") == null);
    try t.expect(std.mem.indexOf(u8, s, "NaN") == null);
}

test "frac: clamped, and a NaN can never reach a widget's width" {
    try t.expectEqual(@as(f32, 0.5), frac(50, 100));
    try t.expectEqual(@as(f32, 1.0), frac(150, 100)); // saturates, never > 1
    try t.expectEqual(@as(f32, 0.0), frac(-5, 100)); // never negative
    try t.expectEqual(@as(f32, 0.0), frac(50, 0)); // divide-by-zero -> 0, not inf
    try t.expectEqual(@as(f32, 0.0), frac(std.math.nan(f32), 100));
    try t.expectEqual(@as(f32, 0.0), frac(50, std.math.nan(f32)));
}

test "levelOf: thresholds are inclusive at the boundary" {
    try t.expectEqual(Level.ok, levelOf(0.0, 0.6, 0.85));
    try t.expectEqual(Level.ok, levelOf(0.59, 0.6, 0.85));
    try t.expectEqual(Level.warn, levelOf(0.60, 0.6, 0.85));
    try t.expectEqual(Level.warn, levelOf(0.84, 0.6, 0.85));
    try t.expectEqual(Level.hot, levelOf(0.85, 0.6, 0.85));
    try t.expectEqual(Level.hot, levelOf(1.0, 0.6, 0.85));
    try t.expectEqual(Level.ok, levelOf(std.math.nan(f32), 0.6, 0.85));
}

test "memMetric: zero total doesn't divide by zero" {
    const m = memMetric(0, 0);
    try t.expectEqual(@as(f32, 0), m.frac);
    try t.expectEqual(Level.ok, m.level);
}

test "memMetric: half of RAM is ok, most of it is hot" {
    const total: u64 = 16 * 1024 * 1024 * 1024;
    try t.expectEqual(Level.ok, memMetric(total / 2, total).level);
    try t.expectEqual(Level.warn, memMetric(total * 8 / 10, total).level);
    try t.expectEqual(Level.hot, memMetric(total * 95 / 100, total).level);
}

test "threadMetric: a thread leak reads hot" {
    // Every detached worker that never exits lands here — that's the point.
    try t.expectEqual(Level.ok, threadMetric(20).level);
    try t.expectEqual(Level.warn, threadMetric(100).level);
    try t.expectEqual(Level.hot, threadMetric(200).level);
    // And it can't overflow the bar.
    try t.expectEqual(@as(f32, 1.0), threadMetric(9999).frac);
}

test "energyImpact: wakeups count, not just CPU" {
    // Two processes at the SAME cpu%: the one hammering wakeups costs more.
    const idle_ish = energyImpact(10, 5);
    const wakey = energyImpact(10, 500);
    try t.expect(wakey > idle_ish);

    // A busy decode lands "warm, not alarming".
    const decode = energyImpact(60, 100);
    try t.expect(decode > 60 and decode < 70);
    try t.expectEqual(Level.warn, energyMetric(decode).level);

    // Garbage in doesn't produce garbage out.
    try t.expectEqual(@as(f32, 0), energyImpact(std.math.nan(f32), 10));
    try t.expectEqual(@as(f32, 0), energyImpact(-5, -5));
}

test "fmtBytes: compact, and never wider than the meter" {
    var b: [16]u8 = undefined;
    try t.expectEqualStrings("1.5 GB", fmtBytes(1610612736, &b));
    try t.expectEqualStrings("512 MB", fmtBytes(512 * 1024 * 1024, &b));
    try t.expectEqualStrings("64 KB", fmtBytes(64 * 1024, &b));
    try t.expectEqualStrings("0 KB", fmtBytes(0, &b));

    // The width promise: the nav meter must not jitter as the number grows.
    inline for (.{ 0, 1024, 5 * 1024 * 1024, 900 * 1024 * 1024, 64 * 1024 * 1024 * 1024 }) |n| {
        try t.expect(fmtBytes(n, &b).len <= 8);
    }
}

test "fmtPct" {
    var b: [8]u8 = undefined;
    try t.expectEqualStrings("0%", fmtPct(0, &b));
    try t.expectEqualStrings("42%", fmtPct(42.4, &b));
    try t.expectEqualStrings("100%", fmtPct(100, &b));
    try t.expectEqualStrings("0%", fmtPct(std.math.nan(f32), &b));
}
