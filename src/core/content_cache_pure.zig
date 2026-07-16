//! Pure (io-free) format + policy for the encrypted on-disk content cache.
//!
//! The driver in `content_cache.zig` handles key management, AEAD, and atomic
//! file IO; every byte-level decision — the header codec, the key→filename
//! mapping, staleness classification, and the size-cap eviction math — lives
//! here so it can be unit-tested without touching the filesystem or crypto RNG.
//!
//! On-disk entry layout (`<cacheDir>/content/<keyToFilename>.bin`):
//!
//!   ┌───────────────── header (HEADER_LEN bytes, authenticated as AAD) ─────┐
//!   │ magic[4] "OCC1" │ version u8 │ created_ts i64 │ ttl_s i64 │ nonce[24] │
//!   │ plaintext_len u32 │
//!   └──────────────────────────────────────────────────────────────────────┘
//!   │ ciphertext[plaintext_len] │ auth_tag[16] │
//!
//! Multi-byte integers are little-endian. The header is NOT secret (it carries
//! only timing metadata) but IS authenticated: it's fed as AEAD associated data
//! alongside the key hash, so flipping a byte of the header — or moving an entry
//! to a different key's filename — fails decryption and the entry is discarded.

const std = @import("std");

pub const MAGIC = [4]u8{ 'O', 'C', 'C', '1' };
pub const VERSION: u8 = 1;

/// XChaCha20-Poly1305 nonce width (24 bytes) — matches the driver's AEAD.
pub const NONCE_LEN: usize = 24;
/// Poly1305 authentication tag width.
pub const TAG_LEN: usize = 16;

/// magic(4) + version(1) + created_ts(8) + ttl_s(8) + nonce(24) + ptlen(4).
pub const HEADER_LEN: usize = 4 + 1 + 8 + 8 + NONCE_LEN + 4;

/// Hard maximum age: past this an entry is a miss AND gets purged, no matter
/// its per-entry TTL. Protects against unbounded staleness after a long
/// offline gap (7 days).
pub const HARD_MAX_S: i64 = 7 * 24 * 60 * 60;

/// Default per-install cache-size cap (bytes). Over this, the bg sweep evicts
/// oldest-first until back under. 200 MB.
pub const SIZE_CAP_BYTES: u64 = 200 * 1024 * 1024;

/// Largest single entry we will write. Keeps one runaway blob from blowing the
/// cap and bounds the read buffer callers must supply.
pub const MAX_ENTRY_BYTES: usize = 8 * 1024 * 1024;

/// Hex filename length: 16 hash bytes → 32 hex chars (+ ".bin" added by driver).
pub const FILENAME_HEX_LEN: usize = 32;

pub const Header = struct {
    created_ts: i64,
    ttl_s: i64,
    nonce: [NONCE_LEN]u8,
    plaintext_len: u32,
};

pub const Staleness = enum { fresh, stale, expired };

/// Write `h` into `buf` (must be >= HEADER_LEN). Returns the HEADER_LEN slice.
pub fn encodeHeader(buf: []u8, h: Header) ?[]u8 {
    if (buf.len < HEADER_LEN) return null;
    var i: usize = 0;
    @memcpy(buf[i .. i + 4], &MAGIC);
    i += 4;
    buf[i] = VERSION;
    i += 1;
    std.mem.writeInt(i64, buf[i..][0..8], h.created_ts, .little);
    i += 8;
    std.mem.writeInt(i64, buf[i..][0..8], h.ttl_s, .little);
    i += 8;
    @memcpy(buf[i .. i + NONCE_LEN], &h.nonce);
    i += NONCE_LEN;
    std.mem.writeInt(u32, buf[i..][0..4], h.plaintext_len, .little);
    i += 4;
    return buf[0..HEADER_LEN];
}

/// Parse a header from the front of `bytes`. Returns null on any malformation:
/// short buffer, wrong magic, unknown version, or a plaintext_len that can't
/// possibly fit in what follows the header (bounds the AEAD read). Never panics.
pub fn decodeHeader(bytes: []const u8) ?Header {
    if (bytes.len < HEADER_LEN) return null;
    if (!std.mem.eql(u8, bytes[0..4], &MAGIC)) return null;
    if (bytes[4] != VERSION) return null;
    var h: Header = undefined;
    h.created_ts = std.mem.readInt(i64, bytes[5..][0..8], .little);
    h.ttl_s = std.mem.readInt(i64, bytes[13..][0..8], .little);
    @memcpy(&h.nonce, bytes[21..][0..NONCE_LEN]);
    h.plaintext_len = std.mem.readInt(u32, bytes[21 + NONCE_LEN ..][0..4], .little);
    if (h.plaintext_len > MAX_ENTRY_BYTES) return null;
    // The rest of the file must hold exactly ciphertext(plaintext_len)+tag.
    const need = @as(usize, h.plaintext_len) + TAG_LEN;
    if (bytes.len < HEADER_LEN + need) return null;
    return h;
}

/// Deterministic, filesystem-safe filename (lowercase hex, no separators) for
/// an arbitrary cache key. SHA-256 truncated to 16 bytes → 32 hex chars.
/// Collision-resistant enough that distinct keys never share a file, and a key
/// containing '/', '..', NUL, etc. can never escape the cache dir.
pub fn keyToFilename(key: []const u8) [FILENAME_HEX_LEN]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    var out: [FILENAME_HEX_LEN]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < FILENAME_HEX_LEN / 2) : (i += 1) {
        out[i * 2] = hex[digest[i] >> 4];
        out[i * 2 + 1] = hex[digest[i] & 0x0f];
    }
    return out;
}

/// 32-byte AEAD associated data binding an entry to its key: the SHA-256 of the
/// key. Passed to encrypt/decrypt so a tampered or relocated entry (moved to a
/// different key's filename) fails authentication.
pub fn keyHash(key: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    return digest;
}

/// Classify an entry's freshness. `now` and `created_ts` are epoch seconds.
///   age < ttl_s          → fresh   (serve, no refresh)
///   ttl_s <= age < hard  → stale   (serve NOW, refresh in background)
///   age >= hard_max      → expired (treat as miss + purge)
/// A negative age (entry created in the future — clock skew) counts as fresh.
pub fn staleness(created_ts: i64, ttl_s: i64, now: i64) Staleness {
    const age = now - created_ts;
    if (age < 0) return .fresh;
    if (age >= HARD_MAX_S) return .expired;
    if (age >= ttl_s) return .stale;
    return .fresh;
}

/// True when an entry is older than `max_age` seconds and should be swept from
/// disk. Future-dated entries are never purged on age alone.
pub fn shouldPurge(created_ts: i64, now: i64, max_age: i64) bool {
    const age = now - created_ts;
    if (age < 0) return false;
    return age >= max_age;
}

/// Total on-disk size (bytes) of a single entry given its plaintext length.
pub fn entryFileSize(plaintext_len: usize) usize {
    return HEADER_LEN + plaintext_len + TAG_LEN;
}

/// Size-cap eviction planner (pure). Given entry sizes sorted OLDEST-first and
/// the running total, returns how many leading (oldest) entries to delete so the
/// total drops to `cap` or below.
pub fn evictionCount(sizes_oldest_first: []const u64, total: u64, cap: u64) usize {
    if (total <= cap) return 0;
    var running = total;
    var n: usize = 0;
    for (sizes_oldest_first) |s| {
        if (running <= cap) break;
        running -= s;
        n += 1;
    }
    return n;
}

// ══════════════════════════════════════════════════════════
// Compact blob serializer — the shared, tested primitive that every caller's
// fixed-buffer-row serializer (search ResolvedItem, TMDB TmdbItem, …) writes
// through, so the on-disk blob format is defined and tested in ONE place. All
// integers little-endian; blobs are u16-length-prefixed (rows are small).
// ══════════════════════════════════════════════════════════

pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,
    ok: bool = true,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }
    fn room(self: *Writer, n: usize) bool {
        if (!self.ok or self.pos + n > self.buf.len) {
            self.ok = false;
            return false;
        }
        return true;
    }
    pub fn u8v(self: *Writer, v: u8) void {
        if (!self.room(1)) return;
        self.buf[self.pos] = v;
        self.pos += 1;
    }
    pub fn boolv(self: *Writer, v: bool) void {
        self.u8v(if (v) 1 else 0);
    }
    pub fn u16v(self: *Writer, v: u16) void {
        if (!self.room(2)) return;
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .little);
        self.pos += 2;
    }
    pub fn u32v(self: *Writer, v: u32) void {
        if (!self.room(4)) return;
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }
    pub fn i32v(self: *Writer, v: i32) void {
        self.u32v(@bitCast(v));
    }
    pub fn f32v(self: *Writer, v: f32) void {
        self.u32v(@bitCast(v));
    }
    /// u16-length-prefixed byte blob (truncated to 65535).
    pub fn blob(self: *Writer, bytes: []const u8) void {
        const n: u16 = @intCast(@min(bytes.len, std.math.maxInt(u16)));
        self.u16v(n);
        if (!self.room(n)) return;
        @memcpy(self.buf[self.pos .. self.pos + n], bytes[0..n]);
        self.pos += n;
    }
    pub fn done(self: *Writer) ?[]u8 {
        if (!self.ok) return null;
        return self.buf[0..self.pos];
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }
    pub fn u8v(self: *Reader) ?u8 {
        if (self.pos + 1 > self.buf.len) return null;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }
    pub fn boolv(self: *Reader) ?bool {
        const v = self.u8v() orelse return null;
        return v != 0;
    }
    pub fn u16v(self: *Reader) ?u16 {
        if (self.pos + 2 > self.buf.len) return null;
        const v = std.mem.readInt(u16, self.buf[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    pub fn u32v(self: *Reader) ?u32 {
        if (self.pos + 4 > self.buf.len) return null;
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    pub fn i32v(self: *Reader) ?i32 {
        const v = self.u32v() orelse return null;
        return @bitCast(v);
    }
    pub fn f32v(self: *Reader) ?f32 {
        const v = self.u32v() orelse return null;
        return @bitCast(v);
    }
    /// Returns a slice into the backing buffer (no copy). Null if truncated.
    pub fn blob(self: *Reader) ?[]const u8 {
        const n = self.u16v() orelse return null;
        if (self.pos + n > self.buf.len) return null;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "header round-trips" {
    var buf: [HEADER_LEN]u8 = undefined;
    var nonce: [NONCE_LEN]u8 = undefined;
    for (&nonce, 0..) |*b, i| b.* = @intCast(i);
    const h = Header{ .created_ts = 1_700_000_000, .ttl_s = 720, .nonce = nonce, .plaintext_len = 4096 };
    const enc = encodeHeader(&buf, h) orelse return error.EncodeFailed;
    try std.testing.expectEqual(@as(usize, HEADER_LEN), enc.len);
    // decode needs the trailing ciphertext+tag to satisfy the bounds check.
    var full: [HEADER_LEN + 4096 + TAG_LEN]u8 = undefined;
    @memcpy(full[0..HEADER_LEN], enc);
    const dec = decodeHeader(&full) orelse return error.DecodeFailed;
    try std.testing.expectEqual(h.created_ts, dec.created_ts);
    try std.testing.expectEqual(h.ttl_s, dec.ttl_s);
    try std.testing.expectEqual(h.plaintext_len, dec.plaintext_len);
    try std.testing.expectEqualSlices(u8, &h.nonce, &dec.nonce);
}

test "encodeHeader rejects short buffer" {
    var tiny: [8]u8 = undefined;
    try std.testing.expect(encodeHeader(&tiny, .{ .created_ts = 0, .ttl_s = 0, .nonce = std.mem.zeroes([NONCE_LEN]u8), .plaintext_len = 0 }) == null);
}

test "decodeHeader rejects malformed input without crashing" {
    // Empty.
    try std.testing.expect(decodeHeader("") == null);
    // Short (partial header).
    try std.testing.expect(decodeHeader("OCC1x") == null);
    // Wrong magic.
    var bad: [HEADER_LEN + TAG_LEN]u8 = std.mem.zeroes([HEADER_LEN + TAG_LEN]u8);
    @memcpy(bad[0..4], "XXXX");
    bad[4] = VERSION;
    try std.testing.expect(decodeHeader(&bad) == null);
    // Right magic, wrong version.
    @memcpy(bad[0..4], &MAGIC);
    bad[4] = 99;
    try std.testing.expect(decodeHeader(&bad) == null);
    // Valid magic+version but plaintext_len claims more bytes than present.
    var buf: [HEADER_LEN]u8 = undefined;
    _ = encodeHeader(&buf, .{ .created_ts = 1, .ttl_s = 1, .nonce = std.mem.zeroes([NONCE_LEN]u8), .plaintext_len = 999_999 });
    try std.testing.expect(decodeHeader(&buf) == null); // no ciphertext follows
    // plaintext_len over the hard entry cap is rejected.
    var huge: [HEADER_LEN]u8 = undefined;
    _ = encodeHeader(&huge, .{ .created_ts = 1, .ttl_s = 1, .nonce = std.mem.zeroes([NONCE_LEN]u8), .plaintext_len = MAX_ENTRY_BYTES + 1 });
    try std.testing.expect(decodeHeader(&huge) == null);
}

test "keyToFilename is deterministic and safe" {
    const a = keyToFilename("search:blade runner");
    const b = keyToFilename("search:blade runner");
    try std.testing.expectEqualSlices(u8, &a, &b);
    // Distinct keys differ.
    const c = keyToFilename("search:blade runner 2");
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
    // A path-traversal-y key produces only [0-9a-f].
    const d = keyToFilename("../../etc/passwd\x00");
    for (d) |ch| try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    try std.testing.expectEqual(@as(usize, FILENAME_HEX_LEN), d.len);
}

test "staleness boundaries" {
    const now: i64 = 1_000_000;
    const ttl: i64 = 720; // 12 min
    // Just created → fresh.
    try std.testing.expectEqual(Staleness.fresh, staleness(now, ttl, now));
    // 1s before TTL → fresh.
    try std.testing.expectEqual(Staleness.fresh, staleness(now - (ttl - 1), ttl, now));
    // Exactly at TTL → stale.
    try std.testing.expectEqual(Staleness.stale, staleness(now - ttl, ttl, now));
    // Between TTL and hard-max → stale.
    try std.testing.expectEqual(Staleness.stale, staleness(now - (HARD_MAX_S - 10), ttl, now));
    // Exactly at hard-max → expired.
    try std.testing.expectEqual(Staleness.expired, staleness(now - HARD_MAX_S, ttl, now));
    // Way past → expired.
    try std.testing.expectEqual(Staleness.expired, staleness(now - HARD_MAX_S * 3, ttl, now));
    // Future-dated (clock skew) → fresh, never expired.
    try std.testing.expectEqual(Staleness.fresh, staleness(now + 5000, ttl, now));
}

test "shouldPurge respects max_age and skips future entries" {
    const now: i64 = 1_000_000;
    try std.testing.expect(shouldPurge(now - HARD_MAX_S - 1, now, HARD_MAX_S));
    try std.testing.expect(!shouldPurge(now - 10, now, HARD_MAX_S));
    try std.testing.expect(!shouldPurge(now + 100, now, HARD_MAX_S)); // future
    try std.testing.expect(shouldPurge(now - 100, now, 50));
}

test "evictionCount trims oldest to the cap" {
    // total under cap → nothing evicted.
    try std.testing.expectEqual(@as(usize, 0), evictionCount(&.{ 10, 10, 10 }, 30, 100));
    // total 100, cap 50: drop 40 (→60), drop 30 (→30) : 2 entries.
    try std.testing.expectEqual(@as(usize, 2), evictionCount(&.{ 40, 30, 20, 10 }, 100, 50));
    // Exactly at cap → nothing.
    try std.testing.expectEqual(@as(usize, 0), evictionCount(&.{ 50, 50 }, 100, 100));
    // Everything must go.
    try std.testing.expectEqual(@as(usize, 3), evictionCount(&.{ 40, 40, 40 }, 120, 10));
}

test "entryFileSize accounts for header and tag" {
    try std.testing.expectEqual(HEADER_LEN + 100 + TAG_LEN, entryFileSize(100));
}

test "Writer/Reader round-trip every field type" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    w.u16v(3); // pretend row count
    w.u8v(42);
    w.boolv(true);
    w.u16v(6502);
    w.u32v(4_000_000_000);
    w.i32v(-12345);
    w.f32v(8.5);
    w.blob("blade runner");
    w.blob(""); // empty blob round-trips
    const out = w.done() orelse return error.WriterOverflow;

    var r = Reader.init(out);
    try std.testing.expectEqual(@as(u16, 3), r.u16v().?);
    try std.testing.expectEqual(@as(u8, 42), r.u8v().?);
    try std.testing.expectEqual(true, r.boolv().?);
    try std.testing.expectEqual(@as(u16, 6502), r.u16v().?);
    try std.testing.expectEqual(@as(u32, 4_000_000_000), r.u32v().?);
    try std.testing.expectEqual(@as(i32, -12345), r.i32v().?);
    try std.testing.expectEqual(@as(f32, 8.5), r.f32v().?);
    try std.testing.expectEqualStrings("blade runner", r.blob().?);
    try std.testing.expectEqualStrings("", r.blob().?);
}

test "Writer flags overflow instead of scribbling" {
    var buf: [4]u8 = undefined;
    var w = Writer.init(&buf);
    w.u32v(1); // fills the buffer
    w.u8v(2); // overflows
    try std.testing.expect(w.done() == null);
}

test "Reader returns null on truncation, never over-reads" {
    var buf: [3]u8 = .{ 5, 0, 0 }; // claims a 5-byte blob but only 1 byte follows
    var r = Reader.init(&buf);
    try std.testing.expect(r.blob() == null);
    // Fresh reader: asking for a u32 from a 3-byte buffer is null, not a crash.
    var r2 = Reader.init(&buf);
    try std.testing.expect(r2.u32v() == null);
}
