//! QR code encoder — ISO/IEC 18004, byte mode, error-correction level M,
//! versions 1–10 (up to 213 bytes of payload). Pure: no allocation, no IO, so
//! the exact module matrix is unit-testable against a reference encoder.
//!
//! WHY THIS EXISTS
//! ---------------
//! Settings › Web UI shows the LAN address and one-time setup code so a phone
//! can reach Opal (issue #46). Typing `http://192.168.1.42:41595/#setup=<64
//! hex>` on a phone keyboard is the opposite of "one scan", and the desktop
//! has no browser to lean on — the QR has to be drawn by the app itself. A
//! LAN URL with the setup fragment is ~100 bytes → version 6-M (41×41).
//!
//! Level M (≈15% recovery) rather than L: a phone camera pointed at a monitor
//! sees moiré and glare; the extra modules cost nothing on screen.

const std = @import("std");

pub const max_version: u8 = 10;
pub const max_size: usize = 17 + 4 * @as(usize, max_version); // 57
pub const max_payload: usize = 213; // version 10-M, byte mode

pub const Matrix = struct {
    size: u8 = 0,
    version: u8 = 0,
    mask: u3 = 0,
    /// Row-major, `true` = dark. Only the top-left `size`×`size` is meaningful.
    modules: [max_size][max_size]bool = std.mem.zeroes([max_size][max_size]bool),

    pub fn get(self: *const Matrix, r: usize, c: usize) bool {
        return self.modules[r][c];
    }
};

// ── Version tables (ISO 18004 table 9, level M) ──

/// Error-correction block structure per version: EC codewords per block, then
/// (block count, data codewords per block) for group 1 and group 2.
const Blocks = struct { ec: u8, g1_n: u8, g1_len: u8, g2_n: u8, g2_len: u8 };
const blocks_m = [max_version]Blocks{
    .{ .ec = 10, .g1_n = 1, .g1_len = 16, .g2_n = 0, .g2_len = 0 }, // v1: 26 codewords
    .{ .ec = 16, .g1_n = 1, .g1_len = 28, .g2_n = 0, .g2_len = 0 }, // v2: 44
    .{ .ec = 26, .g1_n = 1, .g1_len = 44, .g2_n = 0, .g2_len = 0 }, // v3: 70
    .{ .ec = 18, .g1_n = 2, .g1_len = 32, .g2_n = 0, .g2_len = 0 }, // v4: 100
    .{ .ec = 24, .g1_n = 2, .g1_len = 43, .g2_n = 0, .g2_len = 0 }, // v5: 134
    .{ .ec = 16, .g1_n = 4, .g1_len = 27, .g2_n = 0, .g2_len = 0 }, // v6: 172
    .{ .ec = 18, .g1_n = 4, .g1_len = 31, .g2_n = 0, .g2_len = 0 }, // v7: 196
    .{ .ec = 22, .g1_n = 2, .g1_len = 38, .g2_n = 2, .g2_len = 39 }, // v8: 242
    .{ .ec = 22, .g1_n = 3, .g1_len = 36, .g2_n = 2, .g2_len = 37 }, // v9: 292
    .{ .ec = 26, .g1_n = 4, .g1_len = 43, .g2_n = 1, .g2_len = 44 }, // v10: 346
};

/// Alignment-pattern centre coordinates (both axes) per version; 0 = unused.
const align_pos = [max_version][3]u8{
    .{ 0, 0, 0 },
    .{ 6, 18, 0 },
    .{ 6, 22, 0 },
    .{ 6, 26, 0 },
    .{ 6, 30, 0 },
    .{ 6, 34, 0 },
    .{ 6, 22, 38 },
    .{ 6, 24, 42 },
    .{ 6, 26, 46 },
    .{ 6, 28, 50 },
};

fn alignCount(version: u8) usize {
    return if (version == 1) 0 else if (version <= 6) 2 else 3;
}

fn dataCodewords(version: u8) usize {
    const b = blocks_m[version - 1];
    return @as(usize, b.g1_n) * b.g1_len + @as(usize, b.g2_n) * b.g2_len;
}

fn totalCodewords(version: u8) usize {
    const b = blocks_m[version - 1];
    return dataCodewords(version) + @as(usize, b.ec) * (@as(usize, b.g1_n) + b.g2_n);
}

/// Byte-mode payload capacity: data bits minus mode (4) and count (8, or 16
/// from version 10) indicators, floored to whole bytes.
pub fn capacity(version: u8) usize {
    const header_bits: usize = if (version >= 10) 20 else 12;
    return (dataCodewords(version) * 8 - header_bits) / 8;
}

/// Smallest version that holds `len` bytes, or null when it exceeds v10-M.
pub fn versionFor(len: usize) ?u8 {
    var v: u8 = 1;
    while (v <= max_version) : (v += 1) {
        if (capacity(v) >= len) return v;
    }
    return null;
}

// ── GF(256) / Reed–Solomon ──

const gf = struct {
    var exp: [512]u8 = undefined;
    var log: [256]u8 = undefined;
    var ready = false;

    fn init() void {
        if (ready) return;
        var x: u16 = 1;
        for (0..255) |i| {
            exp[i] = @intCast(x);
            log[x] = @intCast(i);
            x <<= 1;
            if (x & 0x100 != 0) x ^= 0x11d;
        }
        for (255..512) |i| exp[i] = exp[i - 255];
        ready = true;
    }

    fn mul(a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        return exp[@as(usize, log[a]) + log[b]];
    }
};

/// Reed–Solomon remainder of data·x^n mod g(x) → `n` EC bytes into `ec`.
fn rsRemainder(data: []const u8, n: usize, ec: []u8) void {
    var gen_buf: [31]u8 = undefined;
    const g = generatorPoly(n, &gen_buf);
    @memset(ec[0..n], 0);
    for (data) |d| {
        const factor = d ^ ec[0];
        // shift left by one
        std.mem.copyForwards(u8, ec[0 .. n - 1], ec[1..n]);
        ec[n - 1] = 0;
        if (factor != 0) {
            for (0..n) |j| ec[j] ^= gf.mul(g[j + 1], factor);
        }
    }
}

/// Correct generator construction (monic, coefficients from x^n down to x^0).
fn generatorPoly(n: usize, out: *[31]u8) []u8 {
    gf.init();
    var g = out[0 .. n + 1];
    @memset(g, 0);
    g[0] = 1; // degree 0 polynomial "1"
    var len: usize = 1;
    for (0..n) |i| {
        // new = g * (x + α^i): shift up (multiply by x) then add α^i·g
        var tmp: [31]u8 = undefined;
        @memset(tmp[0 .. len + 1], 0);
        for (0..len) |j| {
            tmp[j] ^= g[j]; // ·x
            tmp[j + 1] ^= gf.mul(g[j], gf.exp[i]); // ·α^i
        }
        len += 1;
        @memcpy(g[0..len], tmp[0..len]);
    }
    return g;
}

// ── Bit writer ──

const BitWriter = struct {
    buf: []u8,
    bits: usize = 0,

    fn put(self: *BitWriter, value: u32, nbits: u5) void {
        var i: u5 = nbits;
        while (i > 0) {
            i -= 1;
            const bit: u8 = @intCast((value >> i) & 1);
            const idx = self.bits / 8;
            if (idx >= self.buf.len) return;
            if (self.bits % 8 == 0) self.buf[idx] = 0;
            self.buf[idx] |= bit << @intCast(7 - (self.bits % 8));
            self.bits += 1;
        }
    }
};

// ── Matrix construction ──

const Grid = struct {
    size: usize,
    dark: [max_size][max_size]bool,
    reserved: [max_size][max_size]bool,

    fn set(self: *Grid, r: usize, c: usize, d: bool) void {
        self.dark[r][c] = d;
        self.reserved[r][c] = true;
    }

    fn finder(self: *Grid, r0: usize, c0: usize) void {
        // 7×7 finder plus a 1-module light separator ring (clipped at edges).
        var r: isize = -1;
        while (r <= 7) : (r += 1) {
            var c: isize = -1;
            while (c <= 7) : (c += 1) {
                const rr = @as(isize, @intCast(r0)) + r;
                const cc = @as(isize, @intCast(c0)) + c;
                if (rr < 0 or cc < 0 or rr >= @as(isize, @intCast(self.size)) or cc >= @as(isize, @intCast(self.size))) continue;
                const d = (r >= 0 and r <= 6 and c >= 0 and c <= 6) and
                    (r == 0 or r == 6 or c == 0 or c == 6 or (r >= 2 and r <= 4 and c >= 2 and c <= 4));
                self.set(@intCast(rr), @intCast(cc), d);
            }
        }
    }

    fn alignment(self: *Grid, cr: usize, cc: usize) void {
        var r: isize = -2;
        while (r <= 2) : (r += 1) {
            var c: isize = -2;
            while (c <= 2) : (c += 1) {
                const d = @max(@abs(r), @abs(c)) != 1;
                self.set(@intCast(@as(isize, @intCast(cr)) + r), @intCast(@as(isize, @intCast(cc)) + c), d);
            }
        }
    }

    fn functionPatterns(self: *Grid, version: u8) void {
        const n = self.size;
        self.finder(0, 0);
        self.finder(0, n - 7);
        self.finder(n - 7, 0);
        // Timing patterns.
        var i: usize = 8;
        while (i < n - 8) : (i += 1) {
            self.set(6, i, i % 2 == 0);
            self.set(i, 6, i % 2 == 0);
        }
        // Alignment patterns (skip the three that would overlap finders).
        const cnt = alignCount(version);
        const pos = align_pos[version - 1];
        for (0..cnt) |a| {
            for (0..cnt) |b| {
                const r = pos[a];
                const c = pos[b];
                const overlaps = (a == 0 and b == 0) or (a == 0 and b == cnt - 1) or (a == cnt - 1 and b == 0);
                if (overlaps) continue;
                self.alignment(r, c);
            }
        }
        // Format-information areas (values written later) + dark module.
        for (0..9) |k| {
            if (k < n) {
                if (!self.reserved[8][k]) self.set(8, k, false);
                if (!self.reserved[k][8]) self.set(k, 8, false);
            }
        }
        for (0..8) |k| {
            if (!self.reserved[8][n - 1 - k]) self.set(8, n - 1 - k, false);
            if (!self.reserved[n - 1 - k][8]) self.set(n - 1 - k, 8, false);
        }
        self.set(n - 8, 8, true); // the always-dark module
        // Version-information areas (v ≥ 7).
        if (version >= 7) {
            for (0..6) |a| {
                for (0..3) |b| {
                    self.set(a, n - 11 + b, false);
                    self.set(n - 11 + b, a, false);
                }
            }
        }
    }

    fn maskBit(mask: u3, r: usize, c: usize) bool {
        return switch (mask) {
            0 => (r + c) % 2 == 0,
            1 => r % 2 == 0,
            2 => c % 3 == 0,
            3 => (r + c) % 3 == 0,
            4 => (r / 2 + c / 3) % 2 == 0,
            5 => (r * c) % 2 + (r * c) % 3 == 0,
            6 => ((r * c) % 2 + (r * c) % 3) % 2 == 0,
            7 => ((r + c) % 2 + (r * c) % 3) % 2 == 0,
        };
    }

    /// Place codeword bits in the standard two-column zigzag, applying `mask`
    /// to data modules only.
    fn placeData(self: *Grid, codewords: []const u8, mask: u3) void {
        const n = self.size;
        const total_bits = codewords.len * 8;
        var bit_index: usize = 0;
        var right: isize = @intCast(n - 1);
        var upward = true;
        while (right >= 1) : (right -= 2) {
            if (right == 6) right = 5; // the vertical timing column is skipped
            for (0..n) |vert| {
                const r: usize = if (upward) n - 1 - vert else vert;
                for (0..2) |j| {
                    const c: usize = @intCast(right - @as(isize, @intCast(j)));
                    if (self.reserved[r][c]) continue;
                    var bit = false;
                    if (bit_index < total_bits) {
                        bit = (codewords[bit_index / 8] >> @intCast(7 - bit_index % 8)) & 1 == 1;
                    }
                    bit_index += 1; // remainder modules stay 0 before masking
                    self.dark[r][c] = bit != maskBit(mask, r, c);
                }
            }
            upward = !upward;
        }
    }

    fn formatInfo(self: *Grid, mask: u3) void {
        const n = self.size;
        // Level M = 00, then the 3-bit mask; BCH(15,5) with generator 0x537, XOR 0x5412.
        const data: u16 = @as(u16, mask);
        var rem: u16 = data << 10;
        var i: u4 = 14;
        while (i >= 10) : (i -= 1) {
            if ((rem >> i) & 1 == 1) rem ^= @as(u16, 0x537) << (i - 10);
        }
        const bits: u16 = ((data << 10) | rem) ^ 0x5412;
        // `i` counts from the most significant bit (bit 14) — the spec lays
        // the string out MSB-first along row 8 from the left edge.
        for (0..15) |pos| {
            const b = (bits >> @intCast(14 - pos)) & 1 == 1;
            // Copy 1: around the top-left finder.
            if (pos < 6) {
                self.dark[8][pos] = b;
            } else if (pos == 6) {
                self.dark[8][7] = b;
            } else if (pos == 7) {
                self.dark[8][8] = b;
            } else if (pos == 8) {
                self.dark[7][8] = b;
            } else {
                self.dark[14 - pos][8] = b;
            }
            // Copy 2: up the column left of the bottom-left finder, then
            // along row 8 to the right edge.
            if (pos < 7) {
                self.dark[n - 1 - pos][8] = b;
            } else {
                self.dark[8][n - 15 + pos] = b;
            }
        }
    }

    fn versionInfo(self: *Grid, version: u8) void {
        if (version < 7) return;
        const n = self.size;
        const data: u32 = version;
        var rem: u32 = data << 12;
        var i: u5 = 17;
        while (i >= 12) : (i -= 1) {
            if ((rem >> i) & 1 == 1) rem ^= @as(u32, 0x1f25) << @intCast(i - 12);
        }
        const bits: u32 = (data << 12) | rem;
        for (0..18) |k| {
            const b = (bits >> @intCast(k)) & 1 == 1;
            self.dark[k / 3][n - 11 + k % 3] = b;
            self.dark[n - 11 + k % 3][k / 3] = b;
        }
    }

    /// ISO 18004 §7.8.3 penalty score (lower is better).
    fn penalty(self: *const Grid) u32 {
        const n = self.size;
        var score: u32 = 0;
        // Rule 1: runs of ≥5 same-colour modules in a row/column.
        for (0..n) |r| {
            var run: u32 = 1;
            var runc: u32 = 1;
            for (1..n) |c| {
                if (self.dark[r][c] == self.dark[r][c - 1]) {
                    run += 1;
                    if (run == 5) score += 3 else if (run > 5) score += 1;
                } else run = 1;
                if (self.dark[c][r] == self.dark[c - 1][r]) {
                    runc += 1;
                    if (runc == 5) score += 3 else if (runc > 5) score += 1;
                } else runc = 1;
            }
        }
        // Rule 2: 2×2 blocks of one colour.
        for (0..n - 1) |r| {
            for (0..n - 1) |c| {
                const d = self.dark[r][c];
                if (d == self.dark[r][c + 1] and d == self.dark[r + 1][c] and d == self.dark[r + 1][c + 1]) score += 3;
            }
        }
        // Rule 3: finder-like 1011101 with 4 light modules on either side.
        const pat = [_]bool{ true, false, true, true, true, false, true };
        for (0..n) |r| {
            for (0..n) |c| {
                if (c + 11 <= n) {
                    if (matchAt(self, r, c, true, &pat, true) or matchAt(self, r, c, true, &pat, false)) score += 40;
                }
                if (r + 11 <= n) {
                    if (matchAt(self, r, c, false, &pat, true) or matchAt(self, r, c, false, &pat, false)) score += 40;
                }
            }
        }
        // Rule 4: dark-module proportion, 10 per 5% step away from 50%.
        var dark_count: u32 = 0;
        for (0..n) |r| for (0..n) |c| {
            if (self.dark[r][c]) dark_count += 1;
        };
        const total: u32 = @intCast(n * n);
        const pct: i32 = @intCast(dark_count * 100 / total);
        const dev: u32 = @intCast(@abs(pct - 50));
        score += (dev / 5) * 10;
        return score;
    }

    /// 11-module window at (r,c) going right (`horizontal`) or down: either
    /// 0000 + pattern (`light_first`) or pattern + 0000.
    fn matchAt(self: *const Grid, r: usize, c: usize, horizontal: bool, pat: []const bool, light_first: bool) bool {
        for (0..11) |k| {
            const want: bool = if (light_first)
                (if (k < 4) false else pat[k - 4])
            else
                (if (k < 7) pat[k] else false);
            const got = if (horizontal) self.dark[r][c + k] else self.dark[r + k][c];
            if (got != want) return false;
        }
        return true;
    }
};

pub const Error = error{TooLong};

/// Encode `text` (bytes, any content) into `out`. Chooses the smallest
/// version and the best-scoring mask.
pub fn encode(text: []const u8, out: *Matrix) Error!void {
    const version = versionFor(text.len) orelse return error.TooLong;
    gf.init();

    // ── Data codewords ──
    var data_buf: [346]u8 = undefined;
    const n_data = dataCodewords(version);
    var w = BitWriter{ .buf = data_buf[0..n_data] };
    w.put(0b0100, 4);
    w.put(@intCast(text.len), if (version >= 10) 16 else 8);
    for (text) |b| w.put(b, 8);
    // Terminator (up to 4 zero bits), then pad to a byte boundary.
    const cap_bits = n_data * 8;
    const term: u5 = @intCast(@min(4, cap_bits - w.bits));
    w.put(0, term);
    if (w.bits % 8 != 0) w.put(0, @intCast(8 - (w.bits % 8)));
    var pad_toggle = false;
    while (w.bits < cap_bits) : (pad_toggle = !pad_toggle) {
        w.put(if (pad_toggle) 0x11 else 0xec, 8);
    }

    // ── Error correction per block, then interleave ──
    const blk = blocks_m[version - 1];
    const n_blocks: usize = @as(usize, blk.g1_n) + blk.g2_n;
    var ec_buf: [5][30]u8 = undefined; // ≤ 5 blocks × ≤ 26 EC codewords for v ≤ 10
    var block_start: [5]usize = undefined;
    var block_len: [5]usize = undefined;
    {
        var off: usize = 0;
        for (0..n_blocks) |b| {
            const len: usize = if (b < blk.g1_n) blk.g1_len else blk.g2_len;
            block_start[b] = off;
            block_len[b] = len;
            rsRemainder(data_buf[off .. off + len], blk.ec, &ec_buf[b]);
            off += len;
        }
    }
    var final_buf: [346]u8 = undefined;
    var k: usize = 0;
    const longest: usize = @max(blk.g1_len, if (blk.g2_n > 0) blk.g2_len else 0);
    for (0..longest) |i| {
        for (0..n_blocks) |b| {
            if (i < block_len[b]) {
                final_buf[k] = data_buf[block_start[b] + i];
                k += 1;
            }
        }
    }
    for (0..blk.ec) |i| {
        for (0..n_blocks) |b| {
            final_buf[k] = ec_buf[b][i];
            k += 1;
        }
    }
    std.debug.assert(k == totalCodewords(version));
    const codewords = final_buf[0..k];

    // ── Matrix: function patterns once, then try every mask ──
    const size: usize = 17 + 4 * @as(usize, version);
    var base: Grid = .{ .size = size, .dark = undefined, .reserved = undefined };
    @memset(std.mem.asBytes(&base.dark), 0);
    @memset(std.mem.asBytes(&base.reserved), 0);
    base.functionPatterns(version);

    var best_mask: u3 = 0;
    var best_score: u32 = std.math.maxInt(u32);
    var best: Grid = undefined;
    for (0..8) |m| {
        const mask: u3 = @intCast(m);
        var g = base;
        g.placeData(codewords, mask);
        g.formatInfo(mask);
        g.versionInfo(version);
        const s = g.penalty();
        if (s < best_score) {
            best_score = s;
            best_mask = mask;
            best = g;
        }
    }

    out.size = @intCast(size);
    out.version = version;
    out.mask = best_mask;
    out.modules = best.dark;
}

/// Same as `encode` but with a caller-chosen mask (reference comparisons).
pub fn encodeWithMask(text: []const u8, mask: u3, out: *Matrix) Error!void {
    try encode(text, out);
    if (out.mask == mask) return;
    // Re-run the placement with the requested mask on the same codewords: the
    // simplest faithful way is to redo the whole encode with a forced pick.
    const version = out.version;
    gf.init();
    var data_buf: [346]u8 = undefined;
    const n_data = dataCodewords(version);
    var w = BitWriter{ .buf = data_buf[0..n_data] };
    w.put(0b0100, 4);
    w.put(@intCast(text.len), if (version >= 10) 16 else 8);
    for (text) |b| w.put(b, 8);
    const cap_bits = n_data * 8;
    w.put(0, @intCast(@min(4, cap_bits - w.bits)));
    if (w.bits % 8 != 0) w.put(0, @intCast(8 - (w.bits % 8)));
    var pad_toggle = false;
    while (w.bits < cap_bits) : (pad_toggle = !pad_toggle) w.put(if (pad_toggle) 0x11 else 0xec, 8);
    const blk = blocks_m[version - 1];
    const n_blocks: usize = @as(usize, blk.g1_n) + blk.g2_n;
    var ec_buf: [5][30]u8 = undefined;
    var block_start: [5]usize = undefined;
    var block_len: [5]usize = undefined;
    var off: usize = 0;
    for (0..n_blocks) |b| {
        const len: usize = if (b < blk.g1_n) blk.g1_len else blk.g2_len;
        block_start[b] = off;
        block_len[b] = len;
        rsRemainder(data_buf[off .. off + len], blk.ec, &ec_buf[b]);
        off += len;
    }
    var final_buf: [346]u8 = undefined;
    var k: usize = 0;
    const longest: usize = @max(blk.g1_len, if (blk.g2_n > 0) blk.g2_len else 0);
    for (0..longest) |i| for (0..n_blocks) |b| {
        if (i < block_len[b]) {
            final_buf[k] = data_buf[block_start[b] + i];
            k += 1;
        }
    };
    for (0..blk.ec) |i| for (0..n_blocks) |b| {
        final_buf[k] = ec_buf[b][i];
        k += 1;
    };
    const size: usize = 17 + 4 * @as(usize, version);
    var g: Grid = .{ .size = size, .dark = undefined, .reserved = undefined };
    @memset(std.mem.asBytes(&g.dark), 0);
    @memset(std.mem.asBytes(&g.reserved), 0);
    g.functionPatterns(version);
    g.placeData(final_buf[0..k], mask);
    g.formatInfo(mask);
    g.versionInfo(version);
    out.mask = mask;
    out.modules = g.dark;
}

/// Paint the matrix as opaque RGBA (4 bytes/pixel) with `scale` pixels per
/// module and a `quiet` module border. Returns the image edge in pixels, or
/// null when `out` is too small. `dark`/`light` are RGBA.
pub fn paintRgba(m: *const Matrix, scale: u8, quiet: u8, dark: [4]u8, light: [4]u8, out: []u8) ?usize {
    const modules: usize = @as(usize, m.size) + 2 * @as(usize, quiet);
    const edge = modules * scale;
    if (out.len < edge * edge * 4 or scale == 0) return null;
    for (0..edge) |y| {
        for (0..edge) |x| {
            const mr = y / scale;
            const mc = x / scale;
            var d = false;
            if (mr >= quiet and mc >= quiet and mr - quiet < m.size and mc - quiet < m.size) {
                d = m.modules[mr - quiet][mc - quiet];
            }
            const px = (y * edge + x) * 4;
            @memcpy(out[px .. px + 4], if (d) &dark else &light);
        }
    }
    return edge;
}

// ── Tests ──

fn rowString(m: *const Matrix, r: usize, buf: []u8) []const u8 {
    for (0..m.size) |c| buf[c] = if (m.modules[r][c]) '1' else '0';
    return buf[0..m.size];
}

fn expectMatrix(m: *const Matrix, rows: []const []const u8) !void {
    try std.testing.expectEqual(rows.len, @as(usize, m.size));
    var buf: [max_size]u8 = undefined;
    for (rows, 0..) |row, r| {
        try std.testing.expectEqualStrings(row, rowString(m, r, &buf));
    }
}

test "capacities match ISO 18004 table 7 (byte mode, level M)" {
    try std.testing.expectEqual(@as(usize, 14), capacity(1));
    try std.testing.expectEqual(@as(usize, 26), capacity(2));
    try std.testing.expectEqual(@as(usize, 42), capacity(3));
    try std.testing.expectEqual(@as(usize, 62), capacity(4));
    try std.testing.expectEqual(@as(usize, 84), capacity(5));
    try std.testing.expectEqual(@as(usize, 106), capacity(6));
    try std.testing.expectEqual(@as(usize, 122), capacity(7));
    try std.testing.expectEqual(@as(usize, 152), capacity(8));
    try std.testing.expectEqual(@as(usize, 180), capacity(9));
    try std.testing.expectEqual(@as(usize, 213), capacity(10));
    try std.testing.expectEqual(@as(?u8, 6), versionFor(100)); // a LAN setup URL
    try std.testing.expectEqual(@as(?u8, null), versionFor(214));
}

test "Reed-Solomon: the ISO 18004 annex example (HELLO WORLD, 1-M)" {
    // Data codewords of "HELLO WORLD" in alphanumeric 1-M, from the spec's
    // worked example; the 10 EC codewords are the well-known expected values.
    const data = [_]u8{ 0x20, 0x5b, 0x0b, 0x78, 0xd1, 0x72, 0xdc, 0x4d, 0x43, 0x40, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11 };
    var ec: [10]u8 = undefined;
    rsRemainder(&data, 10, &ec);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 196, 35, 39, 119, 235, 215, 231, 226, 93, 23 }, &ec);
}

test "finder patterns, timing and the dark module are where the spec puts them" {
    var m: Matrix = .{};
    try encode("http://192.168.1.42:41595/", &m);
    try std.testing.expectEqual(@as(u8, 2), m.version);
    try std.testing.expectEqual(@as(u8, 25), m.size);
    const n: usize = m.size;
    // Finder outer ring corners are dark, separators light.
    try std.testing.expect(m.get(0, 0) and m.get(6, 6) and m.get(0, n - 1) and m.get(n - 1, 0));
    try std.testing.expect(!m.get(7, 7) and !m.get(7, n - 8) and !m.get(n - 8, 7));
    // Timing pattern alternates, dark on even indices.
    for (8..n - 8) |i| {
        try std.testing.expectEqual(i % 2 == 0, m.get(6, i));
        try std.testing.expectEqual(i % 2 == 0, m.get(i, 6));
    }
    try std.testing.expect(m.get(n - 8, 8)); // dark module
}

// Reference fixtures produced by the npm `qrcode` package (byte mode, level M,
// automatic mask), so a regression anywhere — RS, interleave, zigzag, masks,
// format/version info — shows up as a module mismatch.
test "matches the reference encoder: v2, mask 5 (a bare LAN URL)" {
    var m: Matrix = .{};
    try encode("http://192.168.1.42:41595/", &m);
    try std.testing.expectEqual(@as(u3, 5), m.mask);
    try expectMatrix(&m, &.{
        "1111111000101100101111111",
        "1000001011100010001000001",
        "1011101011010000101011101",
        "1011101011000111101011101",
        "1011101000101010001011101",
        "1000001000110100101000001",
        "1111111010101010101111111",
        "0000000010110000000000000",
        "1000001010011101111001110",
        "1001000111111101110011110",
        "1111001100100101001101011",
        "0100010011000001100011001",
        "0110001110101010111000001",
        "1000010110101011000000010",
        "1001101111100011010101011",
        "1011000011110010100010101",
        "1001001011011100111110100",
        "0000000011011011100010100",
        "1111111000110110101011001",
        "1000001001100010100010000",
        "1011101001100101111111100",
        "1011101000111000001101011",
        "1011101001000010010000101",
        "1000001001101011101110001",
        "1111111011000011101001001",
    });
}

test "matches the reference encoder: v6, mask 2 (LAN URL with the setup fragment)" {
    var m: Matrix = .{};
    try encode("http://192.168.100.100:41595/#setup=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", &m);
    try std.testing.expectEqual(@as(u8, 6), m.version);
    try std.testing.expectEqual(@as(u3, 2), m.mask);
    try expectMatrix(&m, &.{
        "11111110000110110001011111001011101111111",
        "10000010010001111010011000011000101000001",
        "10111010101110100000011110111010001011101",
        "10111010100010111011001001111111101011101",
        "10111010101110101001100111000101001011101",
        "10000010101111010000001010011010001000001",
        "11111110101010101010101010101010101111111",
        "00000000100000000010110010000000000000000",
        "10111110000000110110100111011110101111100",
        "10110001101111000001001110000101001010111",
        "01111110001110101000010010110000110110000",
        "01010001011110110001011010001000010111001",
        "01111110110000110101001011011110110001110",
        "00000100110111110110110100100001001111001",
        "11001011111010010011011011110010111101010",
        "10011001011011111001110000010001011010000",
        "11110111101011101101100001000100110100110",
        "10110001001110110111011110101011011010001",
        "01100011000111110100101010010000000010110",
        "10110100101011111111110110111000000010000",
        "11111111101011111000010001111111100101111",
        "11000001010001000011110111000001101011011",
        "00011110110000111010110001110110100000000",
        "10101000011100011001011100000010111111010",
        "11010110100100111110100001011110110100100",
        "01001001101101010001011110100011001011011",
        "10000110010110101100010010111010110010000",
        "11110100101111011010011010110011100111011",
        "00001111100001000110101011011111110101110",
        "10010000011010001000010100100001001111101",
        "10000110011110000010111000011110001101110",
        "10011001110100000000011110001011001010010",
        "10010011101100110100100001010100111110110",
        "00000000110101010011001110101011100010001",
        "11111110011101000010001001011101101011110",
        "10000010111001001001100010000010100010000",
        "10111010101011000010011001111110111111100",
        "10111010111101011101110110000101110101011",
        "10111010101111000110010010011101011111000",
        "10000010000110100001010100110011100011010",
        "11111110100000100100100001011111010110100",
    });
}

test "encodeWithMask reproduces the reference for a forced mask (v2, mask 3 rows 0-1)" {
    var m: Matrix = .{};
    try encodeWithMask("http://192.168.1.42:41595/", 3, &m);
    try std.testing.expectEqual(@as(u3, 3), m.mask);
    var b3: [max_size]u8 = undefined;
    var b5: [max_size]u8 = undefined;
    // Function patterns are mask-independent; the data area differs from mask 5.
    try std.testing.expectEqualStrings("1111111", rowString(&m, 0, &b3)[0..7]);
    var m5: Matrix = .{};
    try encode("http://192.168.1.42:41595/", &m5);
    try std.testing.expect(!std.mem.eql(u8, rowString(&m, 9, &b3), rowString(&m5, 9, &b5)));
}

test "too long is an error, not a truncated code" {
    var m: Matrix = .{};
    const long = [_]u8{'a'} ** 214;
    try std.testing.expectError(error.TooLong, encode(&long, &m));
}

test "paintRgba scales and adds the quiet zone" {
    var m: Matrix = .{};
    try encode("opal", &m);
    var px: [(21 + 8) * (21 + 8) * 4 * 4]u8 = undefined;
    const edge = paintRgba(&m, 2, 4, .{ 0, 0, 0, 255 }, .{ 255, 255, 255, 255 }, &px).?;
    try std.testing.expectEqual(@as(usize, (21 + 8) * 2), edge);
    // Quiet zone is light; the finder's top-left module is dark.
    try std.testing.expectEqual(@as(u8, 255), px[0]);
    const first_dark = ((4 * 2) * edge + 4 * 2) * 4;
    try std.testing.expectEqual(@as(u8, 0), px[first_dark]);
    var tiny: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), paintRgba(&m, 2, 4, .{ 0, 0, 0, 255 }, .{ 255, 255, 255, 255 }, &tiny));
}
