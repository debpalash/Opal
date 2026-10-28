//! Audio fingerprinting — pure (no io_global, no globals, unit-testable).
//!
//! Haitsma–Kalker style: mono s16 PCM at ~11025 Hz is cut into overlapping
//! Hann-windowed frames, each frame's spectrum (radix-2 FFT) is summed into
//! 33 log-spaced bands between 300 and 2000 Hz, and the frame becomes one
//! 32-bit sub-fingerprint whose bit m is the sign of the band-energy
//! difference across frequency AND time:
//!
//!     bit(n,m) = (E(n,m) - E(n,m+1)) - (E(n-1,m) - E(n-1,m+1)) > 0
//!
//! Two recordings of the same audio give sub-fingerprints with a low Hamming
//! distance (a few bits); unrelated audio sits near 16/32. The intro/credits
//! detector (marker_match_pure.zig) aligns these sequences across episodes.
//!
//! Quiet frames (RMS below ~-54 dBFS) are emitted as `SILENT` (0): digital
//! silence is identical in every episode, and letting it "match" would turn
//! every fade-to-black into a fake shared segment. Matching treats 0 as a
//! guaranteed mismatch, and a real print that happens to be 0 is nudged to 1.

const std = @import("std");

pub const SAMPLE_RATE: u32 = 11025;
pub const FRAME_LEN: usize = 2048; // ~186 ms
pub const HOP: usize = 512; // ~46 ms
pub const BANDS: usize = 33; // 33 bands -> 32 difference bits
pub const MIN_HZ: f32 = 300;
pub const MAX_HZ: f32 = 2000;
pub const SILENT: u32 = 0;
/// Frames whose normalized RMS falls below this are SILENT.
pub const SILENCE_RMS: f32 = 0.002;

pub fn hopSeconds() f64 {
    return @as(f64, @floatFromInt(HOP)) / @as(f64, @floatFromInt(SAMPLE_RATE));
}

/// Number of sub-fingerprints `compute` produces for `n_samples` samples.
pub fn frameCount(n_samples: usize) usize {
    if (n_samples < FRAME_LEN) return 0;
    return (n_samples - FRAME_LEN) / HOP + 1;
}

/// Per-call working memory (~33 KB). Heap-allocate it on worker threads.
pub const Scratch = struct {
    re: [FRAME_LEN]f32 = undefined,
    im: [FRAME_LEN]f32 = undefined,
    window: [FRAME_LEN]f32 = undefined,
    cos_t: [FRAME_LEN / 2]f32 = undefined,
    sin_t: [FRAME_LEN / 2]f32 = undefined,
    band_lo: [BANDS]usize = undefined,
    band_hi: [BANDS]usize = undefined,
    ready: bool = false,

    pub fn init(self: *Scratch) void {
        const n_f: f32 = @floatFromInt(FRAME_LEN);
        for (0..FRAME_LEN) |i| {
            const x: f32 = @floatFromInt(i);
            self.window[i] = 0.5 - 0.5 * @cos(2.0 * std.math.pi * x / (n_f - 1));
        }
        for (0..FRAME_LEN / 2) |i| {
            const a = -2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / n_f;
            self.cos_t[i] = @cos(a);
            self.sin_t[i] = @sin(a);
        }
        // Log-spaced band edges, each band at least one FFT bin wide.
        const ratio = std.math.pow(f32, MAX_HZ / MIN_HZ, 1.0 / @as(f32, @floatFromInt(BANDS)));
        const bin_hz: f32 = @as(f32, @floatFromInt(SAMPLE_RATE)) / n_f;
        var edge: f32 = MIN_HZ;
        var prev_bin: usize = @intFromFloat(@round(MIN_HZ / bin_hz));
        for (0..BANDS) |b| {
            edge *= ratio;
            var hi: usize = @intFromFloat(@round(edge / bin_hz));
            if (hi <= prev_bin) hi = prev_bin + 1;
            self.band_lo[b] = prev_bin;
            self.band_hi[b] = hi;
            prev_bin = hi;
        }
        self.ready = true;
    }
};

/// In-place iterative radix-2 complex FFT (FRAME_LEN points).
fn fft(s: *Scratch) void {
    const n = FRAME_LEN;
    // Bit-reversal permutation.
    var j: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) {
            std.mem.swap(f32, &s.re[i], &s.re[j]);
            std.mem.swap(f32, &s.im[i], &s.im[j]);
        }
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const half = len >> 1;
        const step = n / len;
        var start: usize = 0;
        while (start < n) : (start += len) {
            for (0..half) |k| {
                const wr = s.cos_t[k * step];
                const wi = s.sin_t[k * step];
                const a = start + k;
                const b = a + half;
                const tr = s.re[b] * wr - s.im[b] * wi;
                const ti = s.re[b] * wi + s.im[b] * wr;
                s.re[b] = s.re[a] - tr;
                s.im[b] = s.im[a] - ti;
                s.re[a] += tr;
                s.im[a] += ti;
            }
        }
    }
}

/// Fingerprint `samples` into `out`. Returns the number of sub-fingerprints
/// written (min(frameCount(samples.len), out.len)).
pub fn compute(samples: []const i16, out: []u32, s: *Scratch) usize {
    if (!s.ready) s.init();
    const total = @min(frameCount(samples.len), out.len);
    var prev = [_]f32{0} ** BANDS;
    var cur: [BANDS]f32 = undefined;
    for (0..total) |f| {
        const base = f * HOP;
        var sq: f32 = 0;
        for (0..FRAME_LEN) |i| {
            const v = @as(f32, @floatFromInt(samples[base + i])) / 32768.0;
            sq += v * v;
            s.re[i] = v * s.window[i];
            s.im[i] = 0;
        }
        const rms = @sqrt(sq / @as(f32, @floatFromInt(FRAME_LEN)));
        fft(s);
        for (0..BANDS) |b| {
            var e: f32 = 0;
            for (s.band_lo[b]..s.band_hi[b]) |k| e += s.re[k] * s.re[k] + s.im[k] * s.im[k];
            cur[b] = e;
        }
        var bits: u32 = 0;
        for (0..BANDS - 1) |m| {
            const d = (cur[m] - cur[m + 1]) - (prev[m] - prev[m + 1]);
            if (d > 0) bits |= @as(u32, 1) << @intCast(m);
        }
        prev = cur;
        out[f] = if (rms < SILENCE_RMS) SILENT else if (bits == SILENT) 1 else bits;
    }
    return total;
}

/// Hamming distance between two sub-fingerprints; SILENT never matches.
pub fn distance(a: u32, b: u32) u32 {
    if (a == SILENT or b == SILENT) return 32;
    return @popCount(a ^ b);
}

/// Mean Hamming distance of two equally-long print sequences.
pub fn meanDistance(a: []const u32, b: []const u32) f64 {
    const n = @min(a.len, b.len);
    if (n == 0) return 32;
    var sum: u64 = 0;
    for (0..n) |i| sum += distance(a[i], b[i]);
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));
}

// ══════════════════════════════════════════════════════════════════════════
// Test signal helpers (pub so marker_match_pure tests reuse them)
// ══════════════════════════════════════════════════════════════════════════

/// Fill `out` with a "music-like" signal from `seed`: a sequence of short
/// notes (random pitches/amplitudes, 3 partials) over light noise. Two
/// different seeds give unrelated audio; the same seed gives identical audio.
pub fn synthMusic(seed: u64, out: []i16) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    const sr: f32 = @floatFromInt(SAMPLE_RATE);
    var i: usize = 0;
    var phase = [_]f32{ 0, 0, 0 };
    while (i < out.len) {
        const note_len: usize = @intCast(r.intRangeAtMost(u32, 1500, 5000));
        const f0 = 180.0 + r.float(f32) * 900.0;
        const amp = 0.15 + r.float(f32) * 0.25;
        const end = @min(out.len, i + note_len);
        while (i < end) : (i += 1) {
            var v: f32 = 0;
            for (0..3) |h| {
                const hf: f32 = @floatFromInt(h + 1);
                phase[h] += 2.0 * std.math.pi * f0 * hf / sr;
                if (phase[h] > 2.0 * std.math.pi) phase[h] -= 2.0 * std.math.pi;
                v += @sin(phase[h]) * amp / hf;
            }
            v += (r.float(f32) - 0.5) * 0.04;
            out[i] = @intFromFloat(std.math.clamp(v, -1.0, 1.0) * 32000.0);
        }
    }
}

/// Add white noise of amplitude `amp` (0..1 of full scale) in place.
pub fn addNoise(seed: u64, amp: f32, buf: []i16) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (buf) |*v| {
        const x = @as(f32, @floatFromInt(v.*)) / 32768.0 + (r.float(f32) - 0.5) * 2.0 * amp;
        v.* = @intFromFloat(std.math.clamp(x, -1.0, 1.0) * 32000.0);
    }
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════
const testing = std.testing;
const TEST_SECS = 12;

test "frameCount and hop" {
    try testing.expectEqual(@as(usize, 0), frameCount(FRAME_LEN - 1));
    try testing.expectEqual(@as(usize, 1), frameCount(FRAME_LEN));
    try testing.expectEqual(@as(usize, 2), frameCount(FRAME_LEN + HOP));
    try testing.expect(hopSeconds() > 0.04 and hopSeconds() < 0.05);
}

test "identical audio -> identical prints" {
    const a = try testing.allocator.alloc(i16, SAMPLE_RATE * TEST_SECS);
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(i16, SAMPLE_RATE * TEST_SECS);
    defer testing.allocator.free(b);
    synthMusic(7, a);
    synthMusic(7, b);
    const s = try testing.allocator.create(Scratch);
    defer testing.allocator.destroy(s);
    s.* = .{};
    const n = frameCount(a.len);
    const pa = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(pa);
    const pb = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(pb);
    try testing.expectEqual(n, compute(a, pa, s));
    try testing.expectEqual(n, compute(b, pb, s));
    try testing.expectEqualSlices(u32, pa, pb);
    try testing.expectEqual(@as(f64, 0), meanDistance(pa, pb));
}

test "noisy copy is close; unrelated audio is far; sub-hop shift stays close" {
    const len = SAMPLE_RATE * TEST_SECS;
    const clean = try testing.allocator.alloc(i16, len + HOP);
    defer testing.allocator.free(clean);
    synthMusic(11, clean);
    const noisy = try testing.allocator.dupe(i16, clean[0..len]);
    defer testing.allocator.free(noisy);
    addNoise(99, 0.02, noisy);
    const other = try testing.allocator.alloc(i16, len);
    defer testing.allocator.free(other);
    synthMusic(12345, other);

    const s = try testing.allocator.create(Scratch);
    defer testing.allocator.destroy(s);
    s.* = .{};
    const n = frameCount(len);
    var prints: [4][]u32 = undefined;
    for (&prints) |*p| p.* = try testing.allocator.alloc(u32, n);
    defer for (prints) |p| testing.allocator.free(p);
    _ = compute(clean[0..len], prints[0], s);
    _ = compute(noisy, prints[1], s);
    _ = compute(other, prints[2], s);
    // Same audio starting a quarter-hop later (frame grids never line up
    // across real episodes): still far closer than unrelated audio.
    _ = compute(clean[HOP / 4 .. HOP / 4 + len], prints[3], s);

    const d_noisy = meanDistance(prints[0], prints[1]);
    const d_other = meanDistance(prints[0], prints[2]);
    const d_shift = meanDistance(prints[0], prints[3]);
    try testing.expect(d_noisy < 8);
    try testing.expect(d_shift < 10);
    try testing.expect(d_other > 13);
}

test "silence is SILENT and never matches" {
    const z = [_]i16{0} ** (FRAME_LEN + HOP);
    var out: [2]u32 = undefined;
    var s: Scratch = .{};
    try testing.expectEqual(@as(usize, 2), compute(&z, &out, &s));
    try testing.expectEqual(SILENT, out[0]);
    try testing.expectEqual(@as(u32, 32), distance(out[0], out[1]));
    try testing.expectEqual(@as(u32, 0), distance(5, 5));
}
