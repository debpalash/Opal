//! Failed-login throttling for `/api/auth/login` and the password-change
//! current-password check.
//!
//! Opal's web server binds 0.0.0.0 by default, so the login form is reachable
//! by anything on the LAN. bcrypt is slow, but not slow enough to make an
//! unbounded guessing loop pointless — and there was no limit at all.
//!
//! Pure and allocation-free: a fixed table of slots, no clock of its own (the
//! caller passes `now`), so it unit-tests deterministically.
//!
//! Keyed by USERNAME, not by source address. The threat is guessing one
//! account's password; a LAN attacker can trivially vary their source, and
//! locking per-IP would let them lock a victim out from a spoofed address.
//! The cost is that an attacker can lock a known username — which is why this
//! is a short backoff, not a durable lockout, and why the desktop reset path
//! (Settings › Web UI) bypasses it entirely.

const std = @import("std");

/// Attempts allowed inside `window_s` before a lockout starts.
pub const MAX_FAILS: u8 = 5;
/// Sliding window for counting failures.
pub const WINDOW_S: i64 = 300;
/// How long a lockout lasts once tripped.
pub const LOCKOUT_S: i64 = 300;
/// Tracked usernames. Beyond this the oldest slot is recycled.
pub const SLOTS: usize = 32;

pub const Slot = struct {
    /// Hash of the username; 0 means the slot is free.
    key: u64 = 0,
    fails: u8 = 0,
    /// When the current window started.
    window_start: i64 = 0,
    /// Locked until this timestamp (0 = not locked).
    locked_until: i64 = 0,
};

pub const Table = struct {
    slots: [SLOTS]Slot = [_]Slot{.{}} ** SLOTS,
};

/// Non-zero hash so `key == 0` can mean "free".
pub fn keyOf(username: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x0a1_5eed);
    h.update(username);
    const v = h.final();
    return if (v == 0) 1 else v;
}

fn find(t: *Table, key: u64) ?*Slot {
    for (&t.slots) |*s| {
        if (s.key == key) return s;
    }
    return null;
}

/// Free slot, else the one that expires soonest — a full table must not make
/// the limiter fail open.
fn claim(t: *Table, key: u64, now: i64) *Slot {
    var oldest: *Slot = &t.slots[0];
    for (&t.slots) |*s| {
        if (s.key == 0) {
            s.* = .{ .key = key, .window_start = now };
            return s;
        }
        const s_end = @max(s.locked_until, s.window_start + WINDOW_S);
        const o_end = @max(oldest.locked_until, oldest.window_start + WINDOW_S);
        if (s_end < o_end) oldest = s;
    }
    oldest.* = .{ .key = key, .window_start = now };
    return oldest;
}

/// Seconds the caller must wait, or 0 when the attempt may proceed.
pub fn retryAfter(t: *Table, username: []const u8, now: i64) i64 {
    const s = find(t, keyOf(username)) orelse return 0;
    if (s.locked_until > now) return s.locked_until - now;
    return 0;
}

pub fn allowed(t: *Table, username: []const u8, now: i64) bool {
    return retryAfter(t, username, now) == 0;
}

/// Record a failed attempt. Returns the lockout in seconds if this one tripped
/// it, else 0.
pub fn recordFailure(t: *Table, username: []const u8, now: i64) i64 {
    const key = keyOf(username);
    const s = find(t, key) orelse claim(t, key, now);

    // A window that has aged out starts over — this is a sliding limit on
    // recent failures, not a permanent tally.
    if (now - s.window_start > WINDOW_S) {
        s.window_start = now;
        s.fails = 0;
    }
    if (s.fails < 255) s.fails += 1;
    if (s.fails >= MAX_FAILS) {
        s.locked_until = now + LOCKOUT_S;
        s.fails = 0;
        s.window_start = now;
        return LOCKOUT_S;
    }
    return 0;
}

/// A successful login clears the record — the point is to slow guessing, not
/// to punish someone who mistyped twice and then got it right.
pub fn recordSuccess(t: *Table, username: []const u8) void {
    if (find(t, keyOf(username))) |s| s.* = .{};
}

// ── Tests ──

test "allows attempts under the limit" {
    var t = Table{};
    var i: u8 = 0;
    while (i < MAX_FAILS - 1) : (i += 1) {
        try std.testing.expectEqual(@as(i64, 0), recordFailure(&t, "admin", 1000));
        try std.testing.expect(allowed(&t, "admin", 1000));
    }
}

test "locks out on the Nth failure and reports the wait" {
    var t = Table{};
    var i: u8 = 0;
    while (i < MAX_FAILS - 1) : (i += 1) _ = recordFailure(&t, "admin", 1000);
    try std.testing.expectEqual(LOCKOUT_S, recordFailure(&t, "admin", 1000));
    try std.testing.expect(!allowed(&t, "admin", 1000));
    try std.testing.expectEqual(LOCKOUT_S, retryAfter(&t, "admin", 1000));
    // Countdown shrinks as time passes, and clears at the end.
    try std.testing.expectEqual(@as(i64, 100), retryAfter(&t, "admin", 1000 + LOCKOUT_S - 100));
    try std.testing.expect(allowed(&t, "admin", 1000 + LOCKOUT_S));
}

test "failures outside the window do not accumulate" {
    var t = Table{};
    var i: u8 = 0;
    // One short of a lockout...
    while (i < MAX_FAILS - 1) : (i += 1) _ = recordFailure(&t, "admin", 1000);
    // ...then a long gap. The next failure must start a fresh window, not trip.
    try std.testing.expectEqual(@as(i64, 0), recordFailure(&t, "admin", 1000 + WINDOW_S + 1));
    try std.testing.expect(allowed(&t, "admin", 1000 + WINDOW_S + 1));
}

test "a success clears the record" {
    var t = Table{};
    var i: u8 = 0;
    while (i < MAX_FAILS - 1) : (i += 1) _ = recordFailure(&t, "admin", 1000);
    recordSuccess(&t, "admin");
    // Back to a clean slate — the next failure is the first, not the last.
    try std.testing.expectEqual(@as(i64, 0), recordFailure(&t, "admin", 1000));
    try std.testing.expect(allowed(&t, "admin", 1000));
}

test "accounts are throttled independently" {
    var t = Table{};
    var i: u8 = 0;
    while (i < MAX_FAILS) : (i += 1) _ = recordFailure(&t, "admin", 1000);
    try std.testing.expect(!allowed(&t, "admin", 1000));
    // Locking one account must not lock everyone else out.
    try std.testing.expect(allowed(&t, "someone-else", 1000));
}

test "a full table recycles instead of failing open" {
    var t = Table{};
    // Fill every slot with an expired entry.
    var n: usize = 0;
    while (n < SLOTS) : (n += 1) {
        var buf: [16]u8 = undefined;
        _ = recordFailure(&t, std.fmt.bufPrint(&buf, "user{d}", .{n}) catch "u", 0);
    }
    // A brand-new username must still be trackable and still lock out.
    var i: u8 = 0;
    while (i < MAX_FAILS) : (i += 1) _ = recordFailure(&t, "victim", 100_000);
    try std.testing.expect(!allowed(&t, "victim", 100_000));
}

test "keyOf is never zero (zero means free slot)" {
    // A username hashing to 0 would alias the free-slot sentinel and be
    // silently untracked.
    try std.testing.expect(keyOf("") != 0);
    try std.testing.expect(keyOf("admin") != 0);
    try std.testing.expect(keyOf("admin") != keyOf("Admin"));
}

test "unknown usernames are allowed and still get throttled" {
    var t = Table{};
    // Not yet seen → allowed. Otherwise probing for valid usernames is free.
    try std.testing.expect(allowed(&t, "nobody", 1000));
    var i: u8 = 0;
    while (i < MAX_FAILS) : (i += 1) _ = recordFailure(&t, "nobody", 1000);
    try std.testing.expect(!allowed(&t, "nobody", 1000));
}
