//! Fixed-memory request budgets for the remote HTTP service.
//!
//! A named key (client IP or authenticated bearer identity) gets a windowed
//! budget. The table never evicts entries whose windows are live. If a spray
//! fills it, all new keys share an overflow bucket; this deliberately fails
//! closed instead of letting attackers rotate identities to bypass the limit.
//! A separate global window bounds aggregate work even when every request has
//! a distinct key.

const std = @import("std");

pub const SLOTS: usize = 128;

pub const Policy = struct {
    window_s: i64,
    per_key: u16,
    global: u16,
};

pub const Decision = struct {
    allowed: bool,
    retry_after: i64,
};

const Window = struct {
    used: u16 = 0,
    started: i64 = 0,
};

const Entry = struct {
    key: u64 = 0,
    window: Window = .{},
};

pub const Limiter = struct {
    entries: [SLOTS]Entry = [_]Entry{.{}} ** SLOTS,
    overflow: Entry = .{},
    global_window: Window = .{},
};

/// Hash arbitrary binary identity data without reserving the zero sentinel.
pub fn keyOf(identity: []const u8) u64 {
    const value = std.hash.Wyhash.hash(0x6f70_616c_7261_7465, identity);
    return if (value == 0) 1 else value;
}

fn elapsed(window: *const Window, now: i64) ?i64 {
    if (window.used == 0) return null;
    // A backwards wall-clock adjustment must not prematurely reopen a budget.
    if (now < window.started) return 0;
    return now - window.started;
}

fn active(window: *const Window, now: i64, window_s: i64) bool {
    const age = elapsed(window, now) orelse return false;
    return age < window_s;
}

fn retryAfter(window: *const Window, now: i64, policy_window: i64, limit: u16, cost: u16) i64 {
    const age = elapsed(window, now) orelse return 0;
    if (age >= policy_window) return 0;
    if (@as(u32, window.used) + cost <= limit) return 0;
    return @max(@as(i64, 1), policy_window - age);
}

fn add(window: *Window, now: i64, policy_window: i64, cost: u16) void {
    if (!active(window, now, policy_window)) window.* = .{ .started = now };
    window.used = @intCast(@min(@as(u32, std.math.maxInt(u16)), @as(u32, window.used) + cost));
}

fn find(limiter: *Limiter, key: u64) ?*Entry {
    for (&limiter.entries) |*entry| if (entry.key == key) return entry;
    return null;
}

fn entryFor(limiter: *Limiter, key: u64, now: i64, window_s: i64) *Entry {
    if (find(limiter, key)) |entry| return entry;

    // While overflow is live, every previously unseen identity stays in that
    // aggregate bucket even if a named slot happens to expire mid-window.
    if (active(&limiter.overflow.window, now, window_s)) return &limiter.overflow;

    for (&limiter.entries) |*entry| {
        if (entry.key == 0 or !active(&entry.window, now, window_s)) {
            entry.* = .{ .key = key, .window = .{ .started = now } };
            return entry;
        }
    }

    limiter.overflow = .{ .key = 1, .window = .{ .started = now } };
    return &limiter.overflow;
}

/// Consume `cost` units, atomically when the caller protects `limiter` with a
/// mutex. Rejected calls do not consume additional budget or extend windows.
pub fn consume(limiter: *Limiter, key_raw: u64, now: i64, policy: Policy, cost: u16) Decision {
    if (policy.window_s <= 0 or policy.per_key == 0 or policy.global == 0 or cost == 0)
        return .{ .allowed = false, .retry_after = @max(@as(i64, 1), policy.window_s) };

    const global_retry = retryAfter(&limiter.global_window, now, policy.window_s, policy.global, cost);
    if (global_retry > 0) return .{ .allowed = false, .retry_after = global_retry };

    const key = if (key_raw == 0) 1 else key_raw;
    const entry = entryFor(limiter, key, now, policy.window_s);
    const key_retry = retryAfter(&entry.window, now, policy.window_s, policy.per_key, cost);
    if (key_retry > 0) return .{ .allowed = false, .retry_after = key_retry };

    add(&entry.window, now, policy.window_s, cost);
    add(&limiter.global_window, now, policy.window_s, cost);
    return .{ .allowed = true, .retry_after = 0 };
}

fn hasQueryValue(query: []const u8, wanted: []const u8) bool {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], wanted) and eq + 1 < pair.len) return true;
    }
    return false;
}

fn queryEquals(query: []const u8, wanted: []const u8, value: []const u8) bool {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], wanted) and std.mem.eql(u8, pair[eq + 1 ..], value)) return true;
    }
    return false;
}

/// Requests that can allocate substantial memory, start workers, or make
/// remote network calls. Search and recommendation endpoints double as their
/// own read-only poll routes, so only the query form that starts work is
/// charged. Playback/status/media polling is intentionally absent.
pub fn expensiveCost(path: []const u8, query: []const u8) u16 {
    if (std.mem.eql(u8, path, "/api/scrape")) return 4;
    if (std.mem.eql(u8, path, "/api/search") or
        std.mem.eql(u8, path, "/api/unified_search") or
        std.mem.endsWith(u8, path, "/search")) return if (hasQueryValue(query, "q")) 1 else 0;
    if (std.mem.eql(u8, path, "/api/recommendations"))
        return if (queryEquals(query, "refresh", "1")) 1 else 0;
    if (std.mem.eql(u8, path, "/api/download/url") or
        std.mem.eql(u8, path, "/api/rss/refresh") or
        std.mem.eql(u8, path, "/api/setup/sources") or
        std.mem.eql(u8, path, "/api/cast/scan") or
        std.mem.eql(u8, path, "/api/tmdb/trending") or
        std.mem.endsWith(u8, path, "/episodes") or
        std.mem.endsWith(u8, path, "/more")) return 1;
    return 0;
}

test "per-key budget permits the limit and returns an exact retry" {
    var limiter = Limiter{};
    const policy = Policy{ .window_s = 60, .per_key = 3, .global = 20 };
    for (0..3) |_| try std.testing.expect(consume(&limiter, 7, 100, policy, 1).allowed);
    const denied = consume(&limiter, 7, 115, policy, 1);
    try std.testing.expect(!denied.allowed);
    try std.testing.expectEqual(@as(i64, 45), denied.retry_after);
    try std.testing.expect(consume(&limiter, 7, 160, policy, 1).allowed);
}

test "global budget stops a distinct-key spray" {
    var limiter = Limiter{};
    const policy = Policy{ .window_s = 30, .per_key = 5, .global = 4 };
    for (1..5) |key| try std.testing.expect(consume(&limiter, key, 10, policy, 1).allowed);
    const denied = consume(&limiter, 99, 10, policy, 1);
    try std.testing.expect(!denied.allowed);
    try std.testing.expectEqual(@as(i64, 30), denied.retry_after);
}

test "identity spray cannot evict a live named budget" {
    var limiter = Limiter{};
    const policy = Policy{ .window_s = 60, .per_key = 2, .global = 1000 };
    try std.testing.expect(consume(&limiter, 42, 100, policy, 1).allowed);
    try std.testing.expect(consume(&limiter, 42, 100, policy, 1).allowed);
    for (1..SLOTS * 3) |key| {
        if (key == 42) continue;
        _ = consume(&limiter, @intCast(key), 100, policy, 1);
    }
    try std.testing.expect(!consume(&limiter, 42, 100, policy, 1).allowed);
}

test "overflow aggregates unseen identities instead of failing open" {
    var limiter = Limiter{};
    const policy = Policy{ .window_s = 60, .per_key = 2, .global = 1000 };
    for (1..SLOTS + 1) |key| try std.testing.expect(consume(&limiter, @intCast(key), 100, policy, 1).allowed);
    try std.testing.expect(consume(&limiter, 10_001, 100, policy, 1).allowed);
    try std.testing.expect(consume(&limiter, 10_002, 100, policy, 1).allowed);
    try std.testing.expect(!consume(&limiter, 10_003, 100, policy, 1).allowed);
}

test "weighted scrape cost and expensive route allowlist exclude polling" {
    try std.testing.expectEqual(@as(u16, 4), expensiveCost("/api/scrape", ""));
    try std.testing.expectEqual(@as(u16, 1), expensiveCost("/api/tmdb/search", "q=opal"));
    try std.testing.expectEqual(@as(u16, 1), expensiveCost("/api/unified_search", "q=opal"));
    try std.testing.expectEqual(@as(u16, 1), expensiveCost("/api/recommendations", "refresh=1"));
    for ([_]struct { path: []const u8, query: []const u8 }{
        .{ .path = "/api/search", .query = "" },
        .{ .path = "/api/unified_search", .query = "page=1" },
        .{ .path = "/api/recommendations", .query = "" },
        .{ .path = "/api/recommendations", .query = "refresh=0" },
        .{ .path = "/health", .query = "" },
        .{ .path = "/events", .query = "" },
        .{ .path = "/stream", .query = "" },
        .{ .path = "/poster", .query = "" },
        .{ .path = "/api/status", .query = "" },
        .{ .path = "/api/player", .query = "" },
        .{ .path = "/api/queue", .query = "" },
        .{ .path = "/api/downloads", .query = "" },
        .{ .path = "/api/jellyfin/poster", .query = "" },
    }) |request| try std.testing.expectEqual(@as(u16, 0), expensiveCost(request.path, request.query));
}
