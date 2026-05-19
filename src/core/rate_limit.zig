const std = @import("std");
const sync = @import("sync.zig");
const io_g = @import("io_global.zig");

// ══════════════════════════════════════════════════════════
// Opal v2 — Shared scraper rate limiter
//
// Multiple search/resolver backends would otherwise hammer the
// same indexers from one IP and get rate-limited or banned.
// This module owns a small per-origin token-bucket registry that
// every outbound scraper should funnel through.
//
// Usage:
//     try rate_limit.acquire("1337x", 2.0); // ≤ 2 req/sec
//
// `acquire` blocks until a token is available, then returns. The
// limiter is process-wide and thread-safe.
// ══════════════════════════════════════════════════════════

const MAX_BUCKETS: usize = 32;
const KEY_LEN: usize = 32;

const Bucket = struct {
    in_use: bool = false,
    key: [KEY_LEN]u8 = std.mem.zeroes([KEY_LEN]u8),
    key_len: usize = 0,
    tokens: f64 = 0,
    capacity: f64 = 0,
    rate_per_sec: f64 = 0,
    last_refill_ms: i64 = 0,
};

var buckets: [MAX_BUCKETS]Bucket = [_]Bucket{.{}} ** MAX_BUCKETS;
var mutex = sync.Mutex{};

fn now() i64 {
    return io_g.milliTimestamp();
}

fn findOrCreate(key: []const u8, rate_per_sec: f64) ?*Bucket {
    // Caller holds mutex.
    var free_slot: ?usize = null;
    for (buckets, 0..) |b, i| {
        if (b.in_use and b.key_len == key.len and std.mem.eql(u8, b.key[0..b.key_len], key)) {
            return &buckets[i];
        }
        if (!b.in_use and free_slot == null) free_slot = i;
    }
    if (free_slot == null) return null;
    const slot = free_slot.?;
    const cap = @max(rate_per_sec, 1.0);
    buckets[slot] = .{
        .in_use = true,
        .key_len = @min(key.len, KEY_LEN),
        .tokens = cap,
        .capacity = cap,
        .rate_per_sec = rate_per_sec,
        .last_refill_ms = now(),
    };
    @memcpy(buckets[slot].key[0..buckets[slot].key_len], key[0..buckets[slot].key_len]);
    return &buckets[slot];
}

fn refill(b: *Bucket) void {
    // Caller holds mutex.
    const t = now();
    const elapsed_ms = t - b.last_refill_ms;
    if (elapsed_ms <= 0) return;
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    b.tokens = @min(b.capacity, b.tokens + elapsed_s * b.rate_per_sec);
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
            // Registry full — fall back to a coarse sleep so we still throttle a bit.
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
