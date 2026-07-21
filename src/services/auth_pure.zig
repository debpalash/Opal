//! Pure auth helpers for the headless account system: bcrypt password hashing
//! and credential validation. The DB user store routes its shipped hashing
//! through `hashWithSalt` (caller supplies a CSPRNG salt), so the tested logic
//! IS the shipped logic. No `io` dependency — hashing takes an explicit salt and
//! verification is salt-free — which keeps this standalone-unit-testable.

const std = @import("std");
const bcrypt = std.crypto.pwhash.bcrypt;

pub const SALT_LEN = bcrypt.salt_length;
/// bcrypt crypt-format hash is 60 bytes; pad generously for the stored column.
pub const HASH_BUF = 128;

/// OWASP-recommended cost (2^10 rounds ≈ 100-200 ms). Strong, login-latency-ok.
const params: bcrypt.Params = .{ .rounds_log = 10, .silently_truncate_password = false };

/// Deterministic bcrypt hash of `password` with the given salt. Production passes
/// a CSPRNG salt; tests pass a fixed salt for reproducibility. Returns a slice of
/// `out` (a `$2b$…` crypt string carrying its own params + salt).
pub fn hashWithSalt(password: []const u8, salt: [SALT_LEN]u8, out: []u8) ![]const u8 {
    return bcrypt.strHashWithSalt(password, .{ .params = params, .encoding = .crypt }, out, salt);
}

/// Verify a password against a stored bcrypt hash. Wrong password / malformed
/// hash → false (never throws). bcrypt's compare is constant-time.
pub fn verify(hash: []const u8, password: []const u8) bool {
    bcrypt.strVerify(hash, password, .{ .silently_truncate_password = false }) catch return false;
    return true;
}

/// Username: 3–32 chars, `[a-zA-Z0-9._-]`. Keeps it URL/log-safe and unambiguous.
pub fn validUsername(name: []const u8) bool {
    if (name.len < 3 or name.len > 32) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Password: 8–200 chars. (bcrypt truncates at 72 bytes; we don't advertise a
/// cap that low, but keep an upper bound to bound work.)
pub fn validPassword(pw: []const u8) bool {
    return pw.len >= 8 and pw.len <= 200;
}

test "hash + verify round-trips (shipped params)" {
    var salt: [SALT_LEN]u8 = undefined;
    for (&salt, 0..) |*s, i| s.* = @intCast(i);
    var buf: [HASH_BUF]u8 = undefined;
    const h = try hashWithSalt("correct horse battery", salt, &buf);
    try std.testing.expect(std.mem.startsWith(u8, h, "$2"));
    try std.testing.expect(verify(h, "correct horse battery"));
    try std.testing.expect(!verify(h, "wrong password"));
    try std.testing.expect(!verify(h, "correct horse battery ")); // trailing space
    try std.testing.expect(!verify("not-a-hash", "correct horse battery"));
}

test "different salts → different hashes, both verify" {
    const s1: [SALT_LEN]u8 = [_]u8{1} ** SALT_LEN;
    const s2: [SALT_LEN]u8 = [_]u8{2} ** SALT_LEN;
    var b1: [HASH_BUF]u8 = undefined;
    var b2: [HASH_BUF]u8 = undefined;
    const h1 = try hashWithSalt("hunter2!!", s1, &b1);
    const h2 = try hashWithSalt("hunter2!!", s2, &b2);
    try std.testing.expect(!std.mem.eql(u8, h1, h2));
    try std.testing.expect(verify(h1, "hunter2!!"));
    try std.testing.expect(verify(h2, "hunter2!!"));
}

test "username validation" {
    try std.testing.expect(validUsername("alice"));
    try std.testing.expect(validUsername("a_b.c-1"));
    try std.testing.expect(!validUsername("ab")); // too short
    try std.testing.expect(!validUsername("has space"));
    try std.testing.expect(!validUsername("bad/slash"));
    try std.testing.expect(!validUsername("x" ** 33)); // too long
}

test "password validation" {
    try std.testing.expect(validPassword("hunter2!!"));
    try std.testing.expect(!validPassword("short")); // < 8
    try std.testing.expect(!validPassword("")); // empty
}
