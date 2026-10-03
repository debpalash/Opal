//! Bounded public metadata cache, configured mirror failover, and owned health snapshots.
//! Opt-in public GETs only; never stores credentialed requests or media bytes.
const std = @import("std");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const config = @import("../core/source_config.zig");
const sync = @import("../core/sync.zig");
const fetch = @import("reliable_fetch.zig");
const pure = @import("source_request_pure.zig");
const mirrors = @import("../core/mirrors_pure.zig");
pub const Options = struct {
    transport: fetch.Opts = .{},
    base: []const u8,
    ttl_ms: u32 = 0,
    validate: ?*const fn ([]const u8) bool = null,
};
pub const Health = struct {
    state: enum { unchecked, fetching, available, unavailable, cancelled } = .unchecked,
    status: u16 = 0,
    latency_ms: u32 = 0,
    cached: bool = false,
    fallback: bool = false,
    checked_ms: i64 = 0,
};
const Record = struct { id: [32]u8 = .{0} ** 32, len: usize = 0, serial: u64 = 0, health: Health = .{} };
const Entry = struct { key: u64 = 0, stamp: i64 = 0, body: ?[]u8 = null, status: u16 = 0 };
var records: [128]Record = [_]Record{.{}} ** 128;
var cache: [8]Entry = [_]Entry{.{}} ** 8;
var mutex: sync.Mutex = .{};
var serial: u64 = 0;
var config_hash: u64 = 0;
fn recordLocked(id: []const u8) ?*Record {
    if (id.len == 0 or id.len > 32) return null;
    var free: ?*Record = null;
    for (&records) |*record| {
        if (record.len == id.len and std.mem.eql(u8, record.id[0..record.len], id)) return record;
        if (record.len == 0 and free == null) free = record;
    }
    if (free) |record| {
        @memcpy(record.id[0..id.len], id);
        record.len = id.len;
        return record;
    }
    return null;
}
pub fn snapshot(id: []const u8) Health {
    mutex.lock();
    defer mutex.unlock();
    return if (recordLocked(id)) |record| record.health else .{};
}
fn begin(id: []const u8) u64 {
    mutex.lock();
    defer mutex.unlock();
    serial +%= 1;
    if (recordLocked(id)) |record| {
        record.serial = serial;
        record.health.state = .fetching;
    }
    return serial;
}
fn complete(id: []const u8, token: u64, result: fetch.FetchResult, cached: bool, fallback: bool) void {
    mutex.lock();
    defer mutex.unlock();
    if (recordLocked(id)) |record| {
        if (record.serial != token) return;
        record.health = .{ .state = if (result.failure == .cancelled) .cancelled else if (result.ok()) .available else .unavailable, .status = result.status, .latency_ms = result.latency_ms, .cached = cached, .fallback = fallback, .checked_ms = io.monotonicMilliTimestamp() };
    }
}
fn cancelled(opts: fetch.Opts) bool {
    if (@import("../core/workers.zig").isQuitting()) return true;
    const epoch = opts.cancel_epoch orelse return false;
    return switch (epoch) {
        .epoch32 => |t| t.value.load(.acquire) != t.expected,
        .epoch64 => |t| t.value.load(.acquire) != t.expected,
    };
}
fn publicGet(url: []const u8, opts: fetch.Opts) bool {
    if (!pure.publicUrl(url)) return false;
    if (opts.post_body != null or opts.range != null) return false;
    for (opts.headers) |h| {
        if (!pure.publicHeader(h.name)) return false;
    }
    return true;
}
fn cacheKey(id: []const u8, url: []const u8, opts: fetch.Opts, fp: u64) u64 {
    var hash = std.hash.Wyhash.init(fp);
    for ([_][]const u8{ id, url, opts.user_agent orelse "", opts.referer orelse "" }) |s| {
        hash.update(std.mem.asBytes(&s.len));
        hash.update(s);
    }
    for (opts.headers) |h| {
        hash.update(std.mem.asBytes(&h.name.len));
        hash.update(h.name);
        hash.update(std.mem.asBytes(&h.value.len));
        hash.update(h.value);
    }
    return hash.final();
}
fn readCache(key: u64, fp: u64, body: []u8, ttl: u32) ?fetch.FetchResult {
    mutex.lock();
    defer mutex.unlock();
    if (fp != config_hash) {
        for (&cache) |*entry| {
            if (entry.body) |b| alloc.free(b);
            entry.* = .{};
        }
        config_hash = fp;
    }
    for (cache) |entry| {
        const bytes = entry.body orelse continue;
        if (entry.key == key and bytes.len <= body.len and pure.fresh(entry.stamp, io.monotonicMilliTimestamp(), ttl)) {
            @memcpy(body[0..bytes.len], bytes);
            return .{ .body = body[0..bytes.len], .status = entry.status };
        }
    }
    return null;
}
fn storeCache(key: u64, fp: u64, result: fetch.FetchResult) void {
    const owned = alloc.dupe(u8, result.body) catch return;
    mutex.lock();
    defer mutex.unlock();
    if (fp != config_hash) {
        alloc.free(owned);
        return;
    }
    var oldest: usize = 0;
    for (cache, 0..) |entry, i| {
        if (entry.body == null or entry.key == key) {
            oldest = i;
            break;
        }
        if (entry.stamp < cache[oldest].stamp) oldest = i;
    }
    if (cache[oldest].body) |b| alloc.free(b);
    cache[oldest] = .{ .key = key, .stamp = io.monotonicMilliTimestamp(), .body = owned, .status = result.status };
}
pub fn request(id: []const u8, url: []const u8, body: []u8, headers: []u8, opts: Options) fetch.FetchResult {
    const token = begin(id);
    if (cancelled(opts.transport)) {
        const r: fetch.FetchResult = .{ .failure = .cancelled };
        complete(id, token, r, false, false);
        return r;
    }
    const allow_cache = opts.ttl_ms > 0 and publicGet(url, opts.transport);
    const fp = config.fingerprint();
    const key = cacheKey(id, url, opts.transport, fp);
    if (allow_cache) if (readCache(key, fp, body, opts.ttl_ms)) |cached| {
        if (cancelled(opts.transport)) {
            const r: fetch.FetchResult = .{ .failure = .cancelled };
            complete(id, token, r, false, false);
            return r;
        }
        complete(id, token, cached, true, false);
        return cached;
    };
    var mirrors_buf: [512]u8 = undefined;
    const spec = if (publicGet(url, opts.transport)) config.copyValue(id, "mirrors", &mirrors_buf) orelse "" else "";
    var candidates: [mirrors.MAX_CANDIDATES][]const u8 = undefined;
    const count = mirrors.candidates(opts.base, spec, &candidates);
    var result: fetch.FetchResult = .{ .failure = .invalid_input };
    const started = io.monotonicMilliTimestamp();
    var used_fallback = false;
    for (0..@max(1, count)) |attempt| {
        if (cancelled(opts.transport)) {
            result = .{ .failure = .cancelled };
            break;
        }
        const left = @as(i64, opts.transport.timeout_secs) * 1000 - (io.monotonicMilliTimestamp() - started);
        if (left <= 0) {
            result = .{ .failure = .timed_out };
            break;
        }
        var attempt_url: [4096]u8 = undefined;
        const target = if (attempt == 0) url else pure.mirrorUrl(&attempt_url, url, opts.base, candidates[attempt]) orelse continue;
        var transport = opts.transport;
        const remaining_attempts = @max(1, count - attempt);
        transport.timeout_secs = @intCast(@max(1, @divTrunc(left, @as(i64, @intCast(remaining_attempts)) * 1000)));
        result = fetch.request(target, body, headers, transport);
        used_fallback = attempt > 0;
        if (cancelled(opts.transport)) result = .{ .failure = .cancelled };
        if (result.failure == .cancelled) break;
        if (result.ok()) {
            if (mirrors.looksBlocked(result.body) or (if (opts.validate) |validate| !validate(result.body) else false)) {
                result.failure = .malformed_response;
                continue;
            }
            if (allow_cache and pure.cacheable(result.status, true, result.body.len)) storeCache(key, fp, result);
            break;
        }
        // Failover is reserved for idempotent requests and transient/provider failures.
        if (!publicGet(url, opts.transport) or (result.status >= 400 and result.status < 500 and result.status != 403 and result.status != 408 and result.status != 429)) break;
    }
    complete(id, token, result, false, used_fallback);
    return result;
}

/// Release retained bodies only after the global worker barrier has joined requests.
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    for (&cache) |*entry| {
        if (entry.body) |body| alloc.free(body);
        entry.* = .{};
    }
    records = [_]Record{.{}} ** 128;
    config_hash = 0;
    serial = 0;
}
