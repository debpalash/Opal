//! Live public tracker list — fetch daily, cache, inject at add-time.
//!
//! Opal's bottleneck when you press play on a magnet is time-to-first-piece.
//! The wrapper used to inject 8 hard-coded trackers that had not been reviewed
//! since they were typed; this replaces them with 20-75 CURRENT ones from the
//! daily-regenerated public lists, cached in ~/.cache/opal/trackers.txt.
//!
//! All parsing/validation/dedupe/cap decisions live in `trackers_pure.zig` and
//! are unit-tested against the real upstream files — this module only does I/O:
//! read cache, fetch when stale, write cache, hand the blob to the C++ wrapper
//! (torrent_set_extra_trackers), which injects it into every torrent on add.
//!
//! LICENCE: ngosang/trackerslist is GPL-2.0 and Opal is GPL-3.0, so the list is
//! fetched at RUNTIME and never vendored into this repository. The only tracker
//! URLs in the source tree are Opal's own 8-entry offline fallback.

const std = @import("std");
const alloc = @import("../core/alloc.zig").allocator;
const io_g = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const c = @import("../core/c.zig");
const pure = @import("trackers_pure.zig");

const CACHE_NAME = "trackers.txt";

/// Fetch order.
///   1. ngosang trackers_best.txt  — 54.7k stars, daily, blank-line separated
///   2. cf.trackerslist.com        — a second, independently maintained list;
///                                   merged (deduped) to widen the swarm
///   3. ngosang trackers_best_ip.txt — the FALLBACK, and it is the _ip variant
///      on purpose: a user running a DNS blocklist has every tracker DOMAIN
///      resolving to 0.0.0.0, so a domain list is worthless to them while the
///      IP list still works. Only reached when the first two yield too little.
const SRC_PRIMARY = "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt";
const SRC_SECONDARY = "https://cf.trackerslist.com/best.txt";
const SRC_IP_FALLBACK = "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best_ip.txt";

/// Upstream bodies are ~4 KB; 128 KB is a generous ceiling that still refuses a
/// runaway/hijacked response.
const MAX_BODY = 128 * 1024;

/// Serialized blob handed to C++. Module scope, not stack: MAX_TRACKERS *
/// (MAX_URL_LEN + 1) is ~12 KB and it must outlive the FFI call.
var blob_buf: [pure.MAX_TRACKERS * (pure.MAX_URL_LEN + 1)]u8 = undefined;
var blob_len: usize = 0;

var busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var applied: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var applied_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var last_check_ms: i64 = 0;

/// How many trackers are currently injected into new torrents (0 before the
/// first apply, when the wrapper's own baked-in 8 are still in force).
pub fn count() u32 {
    return applied_count.load(.acquire);
}

// ══════════════════════════════════════════════════════════
// TICK — call once per frame from appFrame(); self-throttled
// ══════════════════════════════════════════════════════════

/// Cheap on every frame except the first: loads the cache once, then re-checks
/// staleness at most every 5 minutes (the TTL itself is a day).
pub fn tick() void {
    const now_ms = io_g.milliTimestamp();
    if (last_check_ms != 0 and now_ms - last_check_ms < 5 * 60 * 1000) return;
    last_check_ms = now_ms;

    if (state.torrentSession() == null) return; // session not up yet

    // A cached list is applied straight away (a few KB read) so the very first
    // magnet of the session already benefits. Skipped while a fetch is running:
    // apply() writes the shared blob buffer, and only one writer at a time.
    if (!applied.load(.acquire) and !busy.load(.acquire)) loadCacheAndApply();

    if (!needsRefresh()) return;
    if (busy.swap(true, .acq_rel)) return; // a fetch is already running

    const th = @import("../core/workers.zig").spawnLegacy(refreshWorker, .{}) catch {
        busy.store(false, .release);
        return;
    };
    @import("../core/workers.zig").release(th);
}

fn cachePath(buf: []u8) []const u8 {
    return paths.cacheFile(buf, CACHE_NAME);
}

fn needsRefresh() bool {
    var pb: [512]u8 = undefined;
    const path = cachePath(&pb);
    const mtime_s: i64 = blk: {
        const st = io_g.cwdStatFile(path) catch break :blk 0;
        break :blk @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
    };
    return pure.needsRefresh(io_g.timestamp(), mtime_s, pure.TTL_SECS);
}

fn loadCacheAndApply() void {
    var pb: [512]u8 = undefined;
    const path = cachePath(&pb);
    const body = io_g.cwdReadFileAlloc(path, alloc, MAX_BODY) catch return;
    defer alloc.free(body);

    var list = pure.List{};
    _ = pure.parseInto(body, &list);
    if (list.count == 0) return;
    _ = pure.appendFallback(&list); // top up if the cache was thin
    apply(&list, "cache");
}

// ══════════════════════════════════════════════════════════
// WORKER — network + cache write, off the UI thread
// ══════════════════════════════════════════════════════════

fn refreshWorker() void {
    defer busy.store(false, .release);

    // MAX_BODY on the heap: the thread-stack budget is 512 KB on macOS and a
    // 128 KB buffer has no business on it.
    const buf = alloc.alloc(u8, MAX_BODY) catch return;
    defer alloc.free(buf);

    var list = pure.List{};
    _ = fetchInto(SRC_PRIMARY, buf, &list);
    if (!list.full()) _ = fetchInto(SRC_SECONDARY, buf, &list);
    // Only when the domain lists gave us almost nothing — see SRC_IP_FALLBACK.
    if (list.count < pure.MIN_USABLE) _ = fetchInto(SRC_IP_FALLBACK, buf, &list);

    const fetched = list.count;
    if (fetched == 0) {
        // Offline / every source down: the wrapper keeps whatever it has (the
        // cache from a previous run, or its baked-in 8). Nothing to write.
        logs.pushLog("warn", "trackers", "Tracker list refresh failed; using the offline fallback", false);
        return;
    }

    _ = pure.appendFallback(&list);
    writeCache(&list);
    apply(&list, "network");

    var msg: [128]u8 = undefined;
    const txt = std.fmt.bufPrint(&msg, "Tracker list updated: {d} trackers ({d} fetched)", .{ list.count, fetched }) catch return;
    logs.pushLog("info", "trackers", txt, false);
}

/// Fetch one source and merge it into `list`. Returns entries added.
fn fetchInto(url: []const u8, buf: []u8, list: *pure.List) usize {
    const body = @import("reliable_fetch.zig").fetch(url, buf, .{
        .timeout_secs = 20,
        // Plain text over a CDN — no fingerprint wall to impersonate past, and
        // the DPI proxy is worth having for users on a filtered network.
        .impersonate = false,
    }) orelse return 0;
    return pure.parseInto(body, list);
}

fn writeCache(list: *const pure.List) void {
    paths.ensureCacheDir();
    var pb: [512]u8 = undefined;
    const path = cachePath(&pb);

    var out: [pure.MAX_TRACKERS * (pure.MAX_URL_LEN + 1)]u8 = undefined;
    const blob = pure.serializeZ(list, &out) orelse return;
    io_g.cwdWriteFile(.{ .sub_path = path, .data = blob }) catch {};
}

/// Hand the list to the wrapper. Both add paths (magnet + .torrent) read it, so
/// this is the single injection point.
fn apply(list: *const pure.List, src: []const u8) void {
    const ses = state.torrentSession() orelse return;

    const blob = pure.serializeZ(list, &blob_buf) orelse return;
    blob_len = blob.len;
    c.mpv.torrent_set_extra_trackers(ses, @ptrCast(&blob_buf[0]));

    applied.store(true, .release);
    applied_count.store(@intCast(list.count), .release);

    var msg: [96]u8 = undefined;
    const txt = std.fmt.bufPrint(&msg, "{d} public trackers injected on add (from {s})", .{ list.count, src }) catch return;
    logs.pushLog("info", "trackers", txt, false);
}
