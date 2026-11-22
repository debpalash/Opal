//! Pure helpers for core/rate_limit.zig: per-host bucket keys, token refill,
//! and which bucket to recycle when the registry is full.

const std = @import("std");

pub const KEY_LEN: usize = 32;

/// Lower-cased host of an http(s) URL (no scheme, userinfo, port, path, or a
/// leading `www.`), clipped to KEY_LEN. Null when there is no host.
pub fn hostKey(url: []const u8, out: *[KEY_LEN]u8) ?[]const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var authority = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    var host = authority;
    if (host.len > 0 and host[0] == '[') {
        host = host[0 .. (std.mem.indexOfScalar(u8, host, ']') orelse return null) + 1];
    } else if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    if (host.len >= 4 and std.ascii.eqlIgnoreCase(host[0..4], "www.")) host = host[4..];
    if (host.len == 0) return null;
    const n = @min(host.len, KEY_LEN);
    for (host[0..n], 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out[0..n];
}

/// Tokens after `elapsed_ms` of refill at `rate_per_sec`, capped at capacity.
pub fn refilled(tokens: f64, capacity: f64, rate_per_sec: f64, elapsed_ms: i64) f64 {
    if (elapsed_ms <= 0) return tokens;
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    return @min(capacity, tokens + elapsed_s * rate_per_sec);
}

/// A bucket that has refilled to capacity is indistinguishable from a fresh
/// one, so recycling it loses no throttling state. Pick the stalest such
/// bucket; null when every bucket is still mid-throttle.
pub fn pickVictim(full: []const bool, last_ms: []const i64) ?usize {
    var best: ?usize = null;
    for (full, last_ms, 0..) |is_full, t, i| {
        if (!is_full) continue;
        if (best == null or t < last_ms[best.?]) best = i;
    }
    return best;
}

test "hostKey strips scheme, userinfo, port, path and www" {
    var buf: [KEY_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("example.com", hostKey("https://user:pw@WWW.Example.com:8443/a?b#c", &buf).?);
    try std.testing.expectEqualStrings("api.tvmaze.com", hostKey("https://api.tvmaze.com/shows/1", &buf).?);
    try std.testing.expectEqualStrings("10.0.0.2", hostKey("http://10.0.0.2:8096", &buf).?);
    try std.testing.expectEqualStrings("[::1]", hostKey("http://[::1]:41595/x", &buf).?);
    try std.testing.expectEqualStrings("bare.host", hostKey("bare.host/path", &buf).?);
    try std.testing.expect(hostKey("https:///nohost", &buf) == null);
    try std.testing.expect(hostKey("", &buf) == null);
    const long = hostKey("https://a-very-long-subdomain-name.example-cdn-provider.net/x", &buf).?;
    try std.testing.expectEqual(KEY_LEN, long.len);
}

test "refilled caps at capacity and ignores clock skew" {
    try std.testing.expectEqual(@as(f64, 1.5), refilled(1.0, 4.0, 1.0, 500));
    try std.testing.expectEqual(@as(f64, 4.0), refilled(1.0, 4.0, 1.0, 60_000));
    try std.testing.expectEqual(@as(f64, 0.25), refilled(0.25, 4.0, 1.0, -10));
}

test "pickVictim recycles only refilled buckets, stalest first" {
    // Regression: a full registry used to make every new key fall back to a
    // flat sleep on every call instead of a token bucket.
    try std.testing.expectEqual(@as(?usize, 2), pickVictim(&.{ false, true, true }, &.{ 1, 50, 20 }));
    try std.testing.expectEqual(@as(?usize, null), pickVictim(&.{ false, false }, &.{ 1, 2 }));
}
