//! Perceptual duplicate detection for the local library (ROADMAP 7.2).
//!
//! Each video gets SAMPLES grey 32x32 frames taken at fixed fractions of its
//! own duration (ffmpeg scales them, so resolution drops out), and each frame
//! becomes a 64-bit DCT pHash. Two files are the same content when their
//! durations agree and most ALIGNED samples sit within CLOSE_BITS of each
//! other. Re-encodes and resolution changes move a pHash by a few bits;
//! unrelated frames land near 32. Pure: phash.zig routes production through
//! every function here, and tests/tools/phash_probe.zig drives the same code
//! against ffmpeg-generated clips.
const std = @import("std");

pub const SAMPLES: usize = 8;
pub const SIDE: usize = 32;
pub const FRAME_BYTES: usize = SIDE * SIDE;
/// Hamming distance at or below which two aligned samples agree.
pub const CLOSE_BITS: u7 = 12;
/// Aligned non-flat pairs needed before a verdict is trusted.
pub const MIN_VALID: u8 = 3;
/// Below this pixel standard deviation a frame (black, fade, title card) has
/// no structure and its hash is noise.
pub const FLAT_STDDEV: f64 = 4.0;

pub const Signature = struct {
    duration: f64 = 0,
    hashes: [SAMPLES]u64 = @splat(0),
    /// Bit i set: sample i is flat or could not be decoded.
    flat_mask: u16 = 0,
};

pub const Match = struct {
    duplicate: bool = false,
    valid: u8 = 0,
    close: u8 = 0,
    mean_distance: f32 = 64,
};

/// Sample times, fractions (i+1)/(SAMPLES+1) of the duration: never the very
/// first or last frame, where logos, black and credits live.
pub fn samplePositions(duration: f64, out: *[SAMPLES]f64) bool {
    if (!(duration > 1) or !std.math.isFinite(duration)) return false;
    for (out, 0..) |*t, i| t.* = duration * @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(SAMPLES + 1));
    return true;
}

pub const FRAME_ARGC = 21;
/// ffmpeg argv that writes exactly FRAME_BYTES of 8-bit grey for the frame at
/// `seconds`. Area scaling averages the whole picture, so 4K and 480p copies
/// of one frame produce nearly the same 32x32 grid.
pub fn frameArgv(ffmpeg: []const u8, path: []const u8, seconds: f64, ts_buf: []u8, out: *[FRAME_ARGC][]const u8) ?[]const []const u8 {
    const ts = std.fmt.bufPrint(ts_buf, "{d:.3}", .{@max(seconds, 0)}) catch return null;
    const argv = [FRAME_ARGC][]const u8{
        ffmpeg,      "-nostdin", "-v",  "error",                              "-threads", "1",
        "-ss",       ts,         "-i",  path,                                 "-map",     "0:v:0",
        "-frames:v", "1",        "-vf", "scale=32:32:flags=area,format=gray", "-f",       "rawvideo",
        "-an",       "-sn",      "-",
    };
    out.* = argv;
    return out[0..];
}

const dct_cos: [8][SIDE]f64 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [8][SIDE]f64 = undefined;
    for (0..8) |u| for (0..SIDE) |x| {
        table[u][x] = @cos(std.math.pi * @as(f64, @floatFromInt((2 * x + 1) * u)) / (2.0 * @as(f64, @floatFromInt(SIDE))));
    };
    break :blk table;
};

/// Classic pHash: 2D DCT-II of the 32x32 frame, keep the 8x8 lowest
/// frequencies, one bit per coefficient above their median.
pub fn phash(gray: *const [FRAME_BYTES]u8) u64 {
    var rows: [8][SIDE]f64 = undefined; // rows[u][y] = sum_x f(x,y) cos_u(x)
    for (0..8) |u| for (0..SIDE) |y| {
        var sum: f64 = 0;
        for (0..SIDE) |x| sum += @as(f64, @floatFromInt(gray[y * SIDE + x])) * dct_cos[u][x];
        rows[u][y] = sum;
    };
    var coeffs: [64]f64 = undefined;
    for (0..8) |v| for (0..8) |u| {
        var sum: f64 = 0;
        for (0..SIDE) |y| sum += rows[u][y] * dct_cos[v][y];
        coeffs[v * 8 + u] = sum;
    };
    var sorted = coeffs;
    std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
    const median = (sorted[31] + sorted[32]) / 2;
    var bits: u64 = 0;
    for (coeffs, 0..) |value, i| {
        if (value > median) bits |= @as(u64, 1) << @intCast(i);
    }
    return bits;
}

pub fn isFlat(gray: *const [FRAME_BYTES]u8) bool {
    var sum: f64 = 0;
    for (gray) |p| sum += @floatFromInt(p);
    const mean = sum / @as(f64, @floatFromInt(FRAME_BYTES));
    var variance: f64 = 0;
    for (gray) |p| {
        const d = @as(f64, @floatFromInt(p)) - mean;
        variance += d * d;
    }
    variance /= @as(f64, @floatFromInt(FRAME_BYTES));
    return @sqrt(variance) < FLAT_STDDEV;
}

/// Fold one decoded sample (or a failed decode: `gray == null`) into `sig`.
pub fn setSample(sig: *Signature, index: usize, gray: ?*const [FRAME_BYTES]u8) void {
    if (index >= SAMPLES) return;
    const bit = @as(u16, 1) << @intCast(index);
    const frame = gray orelse {
        sig.hashes[index] = 0;
        sig.flat_mask |= bit;
        return;
    };
    sig.hashes[index] = phash(frame);
    if (isFlat(frame)) sig.flat_mask |= bit else sig.flat_mask &= ~bit;
}

/// A signature with fewer than MIN_VALID usable samples can never match, so
/// it is not worth storing as hashed.
pub fn usable(sig: Signature) bool {
    const full: u16 = (@as(u16, 1) << SAMPLES) - 1;
    return @popCount(~sig.flat_mask & full) >= MIN_VALID and sig.duration > 0;
}

pub fn hamming(a: u64, b: u64) u7 {
    return @popCount(a ^ b);
}

/// Same content, different container/encode: durations within a second or 1%.
pub fn durationTolerance(duration: f64) f64 {
    return @max(1.0, duration * 0.01);
}

pub fn durationsCompatible(a: f64, b: f64) bool {
    if (!(a > 0) or !(b > 0)) return false;
    return @abs(a - b) <= durationTolerance(@max(a, b));
}

pub fn compare(a: Signature, b: Signature) Match {
    var m: Match = .{};
    if (!durationsCompatible(a.duration, b.duration)) return m;
    var total: u32 = 0;
    for (0..SAMPLES) |i| {
        const bit = @as(u16, 1) << @intCast(i);
        if ((a.flat_mask | b.flat_mask) & bit != 0) continue;
        const d = hamming(a.hashes[i], b.hashes[i]);
        m.valid += 1;
        total += d;
        if (d <= CLOSE_BITS) m.close += 1;
    }
    if (m.valid == 0) return m;
    m.mean_distance = @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(m.valid));
    // Three in four aligned samples must agree: one sample landing on a cut or
    // a burned-in subtitle cannot split a pair, and chance agreement of 6+
    // unrelated frames at <=12 bits is vanishingly rare.
    m.duplicate = m.valid >= MIN_VALID and @as(u16, m.close) * 4 >= @as(u16, m.valid) * 3;
    return m;
}

pub const BLOB_BYTES = SAMPLES * 8;
pub fn encodeHashes(sig: Signature, out: *[BLOB_BYTES]u8) []const u8 {
    for (sig.hashes, 0..) |h, i| std.mem.writeInt(u64, out[i * 8 ..][0..8], h, .little);
    return out[0..];
}

pub fn decodeHashes(bytes: []const u8, sig: *Signature) bool {
    if (bytes.len != BLOB_BYTES) return false;
    for (&sig.hashes, 0..) |*h, i| h.* = std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little);
    return true;
}

fn find(parent: []u32, i: u32) u32 {
    var root = i;
    while (parent[root] != root) root = parent[root];
    var cur = i;
    while (parent[cur] != root) {
        const next = parent[cur];
        parent[cur] = root;
        cur = next;
    }
    return root;
}

/// Group every signature with all its matches (transitively). Only pairs whose
/// durations are compatible are compared: signatures are visited in duration
/// order inside a sliding tolerance window, so a 100k-file library costs far
/// less than n^2. `out_group[i]` is 0 for a file with no match, otherwise a
/// shared non-zero id; `out_distance[i]` is the best mean distance found for
/// it. Scratch slices must be at least `sigs.len` long. Returns the number of
/// files that belong to a group.
pub fn group(sigs: []const Signature, order: []u32, parent: []u32, out_group: []u32, out_distance: []f32) usize {
    const n = sigs.len;
    if (order.len < n or parent.len < n or out_group.len < n or out_distance.len < n) return 0;
    for (0..n) |i| {
        order[i] = @intCast(i);
        parent[i] = @intCast(i);
        out_distance[i] = 0;
        out_group[i] = 0;
    }
    const Ctx = struct {
        sigs: []const Signature,
        fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            return ctx.sigs[a].duration < ctx.sigs[b].duration;
        }
    };
    std.mem.sort(u32, order[0..n], Ctx{ .sigs = sigs }, Ctx.lessThan);
    const best: []f32 = out_distance[0..n];
    for (best) |*d| d.* = 64;
    for (0..n) |oi| {
        const a = order[oi];
        if (!usable(sigs[a])) continue;
        var oj = oi + 1;
        while (oj < n) : (oj += 1) {
            const b = order[oj];
            if (sigs[b].duration - sigs[a].duration > durationTolerance(sigs[b].duration)) break;
            if (!usable(sigs[b])) continue;
            const m = compare(sigs[a], sigs[b]);
            if (!m.duplicate) continue;
            const ra = find(parent[0..n], a);
            const rb = find(parent[0..n], b);
            if (ra != rb) parent[@max(ra, rb)] = @min(ra, rb);
            best[a] = @min(best[a], m.mean_distance);
            best[b] = @min(best[b], m.mean_distance);
        }
    }
    // Group size per root, counted in `order` (no longer needed).
    for (0..n) |i| order[i] = 0;
    for (0..n) |i| order[find(parent[0..n], @intCast(i))] += 1;
    var members: usize = 0;
    for (0..n) |i| {
        const root = find(parent[0..n], @intCast(i));
        if (order[root] >= 2) {
            out_group[i] = root + 1;
            members += 1;
        } else best[i] = 0;
    }
    return members;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A deterministic textured frame: smooth gradients plus blobs chosen by seed.
fn synthFrame(seed: u64, out: *[FRAME_BYTES]u8) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    const cx = r.float(f64) * 32;
    const cy = r.float(f64) * 32;
    const fx = 0.1 + r.float(f64) * 0.4;
    const fy = 0.1 + r.float(f64) * 0.4;
    for (0..SIDE) |y| for (0..SIDE) |x| {
        const dx = @as(f64, @floatFromInt(x)) - cx;
        const dy = @as(f64, @floatFromInt(y)) - cy;
        const v = 128 + 60 * @sin(@as(f64, @floatFromInt(x)) * fx) * @cos(@as(f64, @floatFromInt(y)) * fy) + 60 * @exp(-(dx * dx + dy * dy) / 60);
        out[y * SIDE + x] = @intFromFloat(std.math.clamp(v, 0, 255));
    };
}

/// Simulated re-encode: brightness shift, contrast change and pixel noise.
fn reencode(seed: u64, in: *const [FRAME_BYTES]u8, out: *[FRAME_BYTES]u8) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (in, out) |p, *q| {
        const v = @as(f64, @floatFromInt(p)) * 0.92 + 9 + (r.float(f64) - 0.5) * 10;
        q.* = @intFromFloat(std.math.clamp(v, 0, 255));
    }
}

fn sigFor(seed_base: u64, duration: f64, noise_seed: ?u64) Signature {
    var sig: Signature = .{ .duration = duration };
    for (0..SAMPLES) |i| {
        var frame: [FRAME_BYTES]u8 = undefined;
        synthFrame(seed_base * 100 + i, &frame);
        if (noise_seed) |ns| {
            var noisy: [FRAME_BYTES]u8 = undefined;
            reencode(ns + i, &frame, &noisy);
            setSample(&sig, i, &noisy);
        } else setSample(&sig, i, &frame);
    }
    return sig;
}

test "phash is stable under re-encode noise and far apart for different frames" {
    var a: [FRAME_BYTES]u8 = undefined;
    var b: [FRAME_BYTES]u8 = undefined;
    var other: [FRAME_BYTES]u8 = undefined;
    synthFrame(1, &a);
    reencode(7, &a, &b);
    synthFrame(2, &other);
    try testing.expect(hamming(phash(&a), phash(&b)) <= 6);
    try testing.expect(hamming(phash(&a), phash(&other)) > CLOSE_BITS);
    // Exactly half the coefficients sit above the median.
    try testing.expectEqual(@as(u7, 32), @as(u7, @popCount(phash(&a))));
}

test "flat frames are flagged and never count as evidence" {
    var black: [FRAME_BYTES]u8 = @splat(16);
    try testing.expect(isFlat(&black));
    var textured: [FRAME_BYTES]u8 = undefined;
    synthFrame(3, &textured);
    try testing.expect(!isFlat(&textured));
    // Two all-black films of equal length must not group.
    var x: Signature = .{ .duration = 600 };
    var y: Signature = .{ .duration = 600 };
    for (0..SAMPLES) |i| {
        setSample(&x, i, &black);
        setSample(&y, i, &black);
    }
    try testing.expect(!usable(x));
    try testing.expect(!compare(x, y).duplicate);
}

test "re-encoded copy matches, different content and different length do not" {
    const original = sigFor(10, 1500, null);
    const reenc = sigFor(10, 1500.4, 99);
    const other = sigFor(11, 1500, null);
    const m = compare(original, reenc);
    try testing.expect(m.duplicate);
    try testing.expectEqual(@as(u8, SAMPLES), m.valid);
    try testing.expect(m.mean_distance <= CLOSE_BITS);
    try testing.expect(!compare(original, other).duplicate);
    // Same frames but a 3-minute longer cut: not aligned, not a duplicate.
    try testing.expect(!compare(original, sigFor(10, 1680, null)).duplicate);
}

test "one disagreeing sample cannot split a pair, three can" {
    const a = sigFor(20, 900, null);
    var b = sigFor(20, 900, 5);
    b.hashes[2] = ~b.hashes[2];
    try testing.expect(compare(a, b).duplicate);
    b.hashes[4] = ~b.hashes[4];
    b.hashes[6] = ~b.hashes[6];
    try testing.expect(!compare(a, b).duplicate);
}

test "too few usable samples never match" {
    var a = sigFor(30, 300, null);
    var b = sigFor(30, 300, 1);
    a.flat_mask = 0b1111_1100; // only samples 0 and 1 usable
    try testing.expect(!usable(a));
    const m = compare(a, b);
    try testing.expectEqual(@as(u8, 2), m.valid);
    try testing.expect(!m.duplicate);
    // A failed decode is recorded as unusable.
    setSample(&b, 3, null);
    try testing.expect(b.flat_mask & (1 << 3) != 0);
}

test "group joins matches transitively inside the duration window only" {
    const sigs = [_]Signature{
        sigFor(40, 1200, null), // 0: film A
        sigFor(50, 2400, null), // 1: film B
        sigFor(40, 1200.5, 3), // 2: A re-encode
        sigFor(60, 1200, null), // 3: unrelated, same length as A
        sigFor(40, 1201, 4), // 4: A again
        sigFor(50, 2400, 8), // 5: B re-encode
        .{ .duration = 1200, .flat_mask = 0xff }, // 6: unhashable
    };
    var order: [sigs.len]u32 = undefined;
    var parent: [sigs.len]u32 = undefined;
    var groups: [sigs.len]u32 = undefined;
    var dist: [sigs.len]f32 = undefined;
    try testing.expectEqual(@as(usize, 5), group(&sigs, &order, &parent, &groups, &dist));
    try testing.expect(groups[0] != 0 and groups[0] == groups[2] and groups[0] == groups[4]);
    try testing.expect(groups[1] != 0 and groups[1] == groups[5] and groups[1] != groups[0]);
    try testing.expectEqual(@as(u32, 0), groups[3]);
    try testing.expectEqual(@as(u32, 0), groups[6]);
    try testing.expect(dist[2] > 0 and dist[2] <= CLOSE_BITS);
    try testing.expectEqual(@as(f32, 0), dist[3]);
    // Short scratch is refused instead of overflowing.
    try testing.expectEqual(@as(usize, 0), group(&sigs, order[0..2], &parent, &groups, &dist));
}

test "hash blob round-trips and rejects wrong lengths" {
    const sig = sigFor(70, 100, null);
    var buf: [BLOB_BYTES]u8 = undefined;
    var back: Signature = .{};
    try testing.expect(decodeHashes(encodeHashes(sig, &buf), &back));
    try testing.expectEqualSlices(u64, &sig.hashes, &back.hashes);
    try testing.expect(!decodeHashes(buf[0..10], &back));
}

test "sample positions avoid the ends and frame argv pins the shipped filter" {
    var pos: [SAMPLES]f64 = undefined;
    try testing.expect(samplePositions(90, &pos));
    try testing.expectApproxEqAbs(@as(f64, 10), pos[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 80), pos[SAMPLES - 1], 1e-9);
    try testing.expect(!samplePositions(0, &pos));
    try testing.expect(!samplePositions(std.math.nan(f64), &pos));
    var ts: [32]u8 = undefined;
    var argv: [FRAME_ARGC][]const u8 = undefined;
    const a = frameArgv("ffmpeg", "/m/a b.mkv", 12.5, &ts, &argv).?;
    try testing.expectEqualStrings("12.500", a[7]);
    try testing.expectEqualStrings("/m/a b.mkv", a[9]);
    try testing.expectEqualStrings("scale=32:32:flags=area,format=gray", a[15]);
    try testing.expectEqualStrings("-", a[a.len - 1]);
}
