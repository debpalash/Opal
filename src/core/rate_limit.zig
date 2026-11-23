const std = @import("std");
const sync = @import("sync.zig");
const io_g = @import("io_global.zig");
const pure = @import("rate_limit_pure.zig");

// ══════════════════════════════════════════════════════════
// Opal v2 — Shared scraper rate limiter
//
// Multiple search/resolver backends would otherwise hammer the
// same indexers from one IP and get rate-limited or banned.
// This module owns a small per-origin token-bucket registry that
// every outbound scraper funnels through (enforced by
// tests/features/test_rate_limit_rollout.py).
//
// Usage:
//     rate_limit.acquire("1337x", 2.0);   // fixed key, <= 2 req/sec
//     rate_limit.acquireUrl(url, 2.0);    // keyed by the URL's host
//
// `acquire` blocks until a token is available, then returns. The
// limiter is process-wide and thread-safe. Call it from worker
// threads, never from the UI frame.
// ══════════════════════════════════════════════════════════

const MAX_BUCKETS: usize = 128;
const KEY_LEN: usize = pure.KEY_LEN;

const Bucket = struct {
    in_use: bool = false,
    key: [KEY_LEN]u8 = std.mem.zeroes([KEY_LEN]u8),
    key_len: usize = 0,
    tokens: f64 = 0,
    capacity: f64 = 0,
    rate_per_sec: f64 = 0,
    last_refill_ms: i64 = 0,
};

var buckets: [MAX_BUCKETS]Bucket = @as([MAX_BUCKETS]Bucket, @splat(.{}));
var mutex = sync.Mutex{};

fn now() i64 {
    return io_g.milliTimestamp();
}

fn findOrCreate(key: []const u8, rate_per_sec: f64) ?*Bucket {
    // Caller holds mutex. Keys are clipped before comparing, so a long key
    // matches its own bucket instead of minting a new one per call.
    const k = key[0..@min(key.len, KEY_LEN)];
    var free_slot: ?usize = null;
    for (buckets, 0..) |b, i| {
        if (b.in_use and b.key_len == k.len and std.mem.eql(u8, b.key[0..b.key_len], k)) {
            return &buckets[i];
        }
        if (!b.in_use and free_slot == null) free_slot = i;
    }
    const slot = free_slot orelse recycleSlot() orelse return null;
    const cap = @max(rate_per_sec, 1.0);
    buckets[slot] = .{
        .in_use = true,
        .key_len = k.len,
        .tokens = cap,
        .capacity = cap,
        .rate_per_sec = rate_per_sec,
        .last_refill_ms = now(),
    };
    @memcpy(buckets[slot].key[0..k.len], k);
    return &buckets[slot];
}

/// Registry full: reuse a bucket that has refilled to capacity (lossless).
fn recycleSlot() ?usize {
    // Caller holds mutex.
    var full: [MAX_BUCKETS]bool = undefined;
    var last: [MAX_BUCKETS]i64 = undefined;
    for (&buckets, 0..) |*b, i| {
        refill(b);
        full[i] = b.tokens >= b.capacity;
        last[i] = b.last_refill_ms;
    }
    return pure.pickVictim(&full, &last);
}

fn refill(b: *Bucket) void {
    // Caller holds mutex.
    const t = now();
    const elapsed_ms = t - b.last_refill_ms;
    if (elapsed_ms <= 0) return;
    b.tokens = pure.refilled(b.tokens, b.capacity, b.rate_per_sec, elapsed_ms);
    b.last_refill_ms = t;
}

/// Block until one token is available for `key`, then consume it.
/// `rate_per_sec` is the bucket refill rate (steady-state QPS).
/// First call for a key sizes the bucket; later calls reuse it.
pub fn acquire(key: []const u8, rate_per_sec: f64) void {
    while (true) {
        mutex.lock();
        const b_opt = findOrCreate(key, rate_per_sec);
        if (b_opt == null) {
            mutex.unlock();
            // Every bucket is mid-throttle: fall back to a coarse sleep so we still throttle a bit.
            io_g.sleep(@as(u64, @intFromFloat(1_000_000_000.0 / @max(rate_per_sec, 1.0))));
            return;
        }
        const b = b_opt.?;
        refill(b);
        if (b.tokens >= 1.0) {
            b.tokens -= 1.0;
            mutex.unlock();
            return;
        }
        // Compute exact ms until next token.
        const deficit = 1.0 - b.tokens;
        const wait_ms_f: f64 = (deficit / b.rate_per_sec) * 1000.0;
        const wait_ms: u64 = @intFromFloat(@max(1.0, wait_ms_f));
        mutex.unlock();
        io_g.sleep(wait_ms * std.time.ns_per_ms);
    }
}

/// `acquire` keyed by the URL's host, for modules whose base URL is user- or
/// catalog-supplied (many sites behind one module). No host means no wait.
pub fn acquireUrl(url: []const u8, rate_per_sec: f64) void {
    var key_buf: [KEY_LEN]u8 = undefined;
    const key = pure.hostKey(url, &key_buf) orelse return;
    acquire(key, rate_per_sec);
}

/// Non-blocking variant: returns true on success, false if no token now.
pub fn tryAcquire(key: []const u8, rate_per_sec: f64) bool {
    mutex.lock();
    defer mutex.unlock();
    const b_opt = findOrCreate(key, rate_per_sec);
    if (b_opt == null) return false;
    const b = b_opt.?;
    refill(b);
    if (b.tokens >= 1.0) {
        b.tokens -= 1.0;
        return true;
    }
    return false;
}

test "token bucket steady state" {
    // Acquire a few tokens quickly — should succeed at burst capacity.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        try std.testing.expect(tryAcquire("test_key_a", 3.0));
    }
    // Bucket should now be empty.
    try std.testing.expect(!tryAcquire("test_key_a", 3.0));
}

test "acquire waits for a refill on the fake clock" {
    var mock = @import("mock_io.zig").MockIo.init();
    mock.install();
    defer mock.deinit();

    // Capacity 2 at 2 tokens/s: two immediate, the third must wait ~500ms.
    try std.testing.expect(tryAcquire("mock_clock_key", 2.0));
    try std.testing.expect(tryAcquire("mock_clock_key", 2.0));
    try std.testing.expect(!tryAcquire("mock_clock_key", 2.0));
    const before = mock.wallMs();
    acquire("mock_clock_key", 2.0);
    const waited = mock.wallMs() - before;
    try std.testing.expect(mock.sleep_calls.load(.acquire) >= 1);
    try std.testing.expect(waited >= 499 and waited <= 600);
    // A fake-clock advance refills without any sleep.
    mock.advanceMs(1000);
    try std.testing.expect(tryAcquire("mock_clock_key", 2.0));
}
