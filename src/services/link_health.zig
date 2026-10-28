//! App-wide stream-health probing (live / slow / dead status dots).
//!
//! Generalized out of services/iptv.zig so every vertical that plays a remote
//! URL can show the same signal. A caller renders a card and calls
//! `probe(kind, url)`; a bounded worker pool curls the first 2 KB (status +
//! latency), the PURE classifier in link_health_pure.zig maps that to a Status,
//! and the result is cached in the `link_health` table (30-min TTL) so revisits
//! are instant. The UI reads `statusOf(kind, url)` from an in-memory map
//! (refreshed when a probe lands) — never a per-card DB query.
//!
//! `kind` is a short tag ("iptv", "radio", …). Each kind gets its own in-memory
//! maps, but PROBE_MAX is a GLOBAL cap so the app can't spawn N probes per
//! vertical.

const std = @import("std");
const dvui = @import("dvui");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const Mutex = @import("../core/sync.zig").Mutex;
const reliable_fetch = @import("reliable_fetch.zig");

pub const pure = @import("link_health_pure.zig");
pub const Status = pure.Status;

const agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0";

/// Global cap on concurrent probes ACROSS ALL KINDS.
const PROBE_MAX: u32 = 6;

/// Health results older than this are re-probed (streams die/revive; the cache
/// stays useful across sessions without going permanently stale).
pub const TTL_S = pure.TTL_S;

/// Stable url→hash — the `link_health` primary key.
pub fn urlHash(url: []const u8) i64 {
    return @bitCast(std.hash.Fnv1a_64.hash(url));
}

// ══════════════════════════════════════════════════════════
// Per-kind in-memory state
// ══════════════════════════════════════════════════════════
// Owned caches are released after the worker shutdown barrier.
const map_alloc = @import("../core/alloc.zig").allocator;

const MAX_KINDS = 16;
const KIND_NAME_MAX = 16;

const KindState = struct {
    name: [KIND_NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    /// url_hash → Status int, loaded from the DB (non-stale rows only).
    health_map: std.AutoHashMapUnmanaged(i64, pure.Entry) = .{},
    /// url-hashes kicked this session (don't re-probe every frame).
    probe_attempted: std.AutoHashMapUnmanaged(i64, void) = .{},
    dirty: bool = true,
};

var kinds: [MAX_KINDS]KindState = .{KindState{}} ** MAX_KINDS;
var kind_count: usize = 0;
/// Guards `kinds` / `kind_count` and every map inside them. Held across map
/// reads/writes only — never across the curl or a thread spawn.
var mtx: Mutex = .{};
var probe_inflight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Find-or-register the slot for `kind`. Caller MUST hold `mtx`. Returns null
/// only when MAX_KINDS is exhausted (then health is simply never shown).
fn slotLocked(kind: []const u8) ?*KindState {
    var i: usize = 0;
    while (i < kind_count) : (i += 1) {
        const k = &kinds[i];
        if (std.mem.eql(u8, k.name[0..k.name_len], kind)) return k;
    }
    if (kind_count >= MAX_KINDS or kind.len == 0 or kind.len > KIND_NAME_MAX) return null;
    const k = &kinds[kind_count];
    k.* = .{};
    @memcpy(k.name[0..kind.len], kind);
    k.name_len = kind.len;
    kind_count += 1;
    return k;
}

/// Reload `kind`'s map from the DB when a probe has landed since the last read.
/// Caller MUST hold `mtx`.
fn refreshLocked(k: *KindState) void {
    if (!k.dirty or db.get() == null) return;
    k.dirty = false;
    loadMap(k.name[0..k.name_len], &k.health_map);
}

// ══════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════

/// Cached status for `url` under `kind` (`.unknown` when never probed / stale).
/// Cheap enough to call per card per frame.
pub fn statusOf(kind: []const u8, url: []const u8) Status {
    mtx.lock();
    defer mtx.unlock();
    const k = slotLocked(kind) orelse return .unknown;
    refreshLocked(k);
    const v = k.health_map.get(urlHash(url)) orelse return .unknown;
    return v.statusAt(@import("../core/io_global.zig").timestamp());
}

/// Kick a probe for `url` unless a probe is already in flight, the result is
/// fresh in cache, or the global worker cap is reached (then it retries on a
/// later frame). Called per visible card.
pub fn probe(kind: []const u8, url: []const u8) void {
    if (url.len == 0 or url.len > 1024) return;
    const h = urlHash(url);

    mtx.lock();
    const k = slotLocked(kind) orelse {
        mtx.unlock();
        return;
    };
    refreshLocked(k);
    const cached = k.health_map.get(h);
    if (k.probe_attempted.contains(h) or (cached != null and cached.?.fresh(@import("../core/io_global.zig").timestamp()))) {
        mtx.unlock();
        return;
    }
    if (probe_inflight.load(.acquire) >= PROBE_MAX) {
        mtx.unlock(); // over cap — retry next frame
        return;
    }
    k.probe_attempted.put(map_alloc, h, {}) catch {
        mtx.unlock();
        return;
    };
    // The check, reservation, and attempted marker are one transaction under
    // `mtx`. Incrementing after unlock let simultaneous verticals all observe
    // five in flight and oversubscribe the six-worker global ceiling.
    _ = probe_inflight.fetchAdd(1, .acq_rel);
    mtx.unlock();

    // Copy BOTH inputs by value — the caller's url may alias a results[] row a
    // fetch worker can rewrite mid-frame.
    const Args = struct {
        buf: [1024]u8,
        len: usize,
        kind: [KIND_NAME_MAX]u8,
        kind_len: usize,
    };
    var a: Args = .{ .buf = undefined, .len = url.len, .kind = undefined, .kind_len = @min(kind.len, KIND_NAME_MAX) };
    @memcpy(a.buf[0..url.len], url);
    @memcpy(a.kind[0..a.kind_len], kind[0..a.kind_len]);
    if (@import("../core/workers.zig").spawnLegacy(probeWorker, .{a})) |t| {
        @import("../core/workers.zig").release(t);
    } else |_| {
        _ = probe_inflight.fetchSub(1, .acq_rel);
        // A failed spawn is not an attempt. Remove the marker so the next
        // frame can retry instead of leaving this URL permanently unknown.
        mtx.lock();
        if (slotLocked(kind)) |retry_kind| _ = retry_kind.probe_attempted.remove(h);
        mtx.unlock();
    }
}

/// Drop `kind`'s in-memory maps and force a reload — the IPTV "Test" button
/// pairs this with `clearKind` for a full fresh sweep.
pub fn clear(kind: []const u8) void {
    mtx.lock();
    defer mtx.unlock();
    const k = slotLocked(kind) orelse return;
    k.probe_attempted.clearRetainingCapacity();
    k.health_map.clearRetainingCapacity();
    k.dirty = true;
}

// ══════════════════════════════════════════════════════════
// Probe worker
// ══════════════════════════════════════════════════════════

const ProbeRes = struct { code: u32, latency_ms: u32, body: []const u8 };

/// curl the first 2 KB with the HTTP status + total time on stderr (keeps stdout
/// = body). Routes through the DPI-bypass proxy when enabled. Returns null only
/// on spawn failure (a connect/DNS failure still returns code 0).
fn curlProbe(url: []const u8, body_buf: []u8) ?ProbeRes {
    var headers: [4096]u8 = undefined;
    const result = reliable_fetch.request(url, body_buf, &headers, .{
        .user_agent = agent,
        .range = "0-2047",
        .timeout_secs = 6,
    });
    if (result.status == 0) return null;
    return .{ .code = result.status, .latency_ms = result.latency_ms, .body = result.body };
}

fn probeWorker(a: anytype) void {
    defer _ = probe_inflight.fetchSub(1, .acq_rel);
    const url = a.buf[0..a.len];
    const kind = a.kind[0..a.kind_len];

    var body_buf: [4096]u8 = undefined;
    var status: Status = .dead;
    var latency_ms: u32 = 0;
    if (curlProbe(url, &body_buf)) |res| {
        // m3u8 → require a valid playlist; other targets → a 2xx/3xx is enough.
        const playable = if (pure.isM3u8(url)) pure.looksLikePlaylist(res.body) else (res.code >= 200 and res.code < 400);
        status = pure.classify(res.code, playable, res.latency_ms);
        latency_ms = res.latency_ms;
    }

    put(kind, url, @intFromEnum(status), latency_ms);
    mtx.lock();
    if (slotLocked(kind)) |k| {
        _ = k.probe_attempted.remove(urlHash(url));
        k.dirty = true;
    }
    mtx.unlock();
    if (state.app.dvui_win) |win| dvui.refresh(win, @src(), null);
}

// ══════════════════════════════════════════════════════════
// Persistence (link_health) — TTL-aware
// ══════════════════════════════════════════════════════════

/// Persist a probe result (thread-safe via sqlite's own serialization).
pub fn put(kind: []const u8, url: []const u8, status: u8, latency_ms: u32) void {
    const stmt = db.prepare(
        "INSERT OR REPLACE INTO link_health(url_hash,kind,status,latency_ms,checked_at) VALUES(?1,?2,?3,?4,strftime('%s','now'))",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, urlHash(url));
    db.bindText(stmt, 2, kind);
    db.bindInt(stmt, 3, @intCast(status));
    db.bindInt(stmt, 4, @intCast(@min(latency_ms, std.math.maxInt(i32))));
    if (db.step(stmt) == db.c.SQLITE_DONE) {
        mtx.lock();
        if (slotLocked(kind)) |k| k.dirty = true;
        mtx.unlock();
    }
}

/// Load all NON-STALE rows for `kind` into `map` (url_hash → status int).
pub fn loadMap(kind: []const u8, map: *std.AutoHashMapUnmanaged(i64, pure.Entry)) void {
    map.clearRetainingCapacity();
    const stmt = db.prepare(
        "SELECT url_hash,status,checked_at FROM link_health WHERE kind=?1 AND checked_at > strftime('%s','now') - ?2 AND checked_at <= strftime('%s','now')",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindInt64(stmt, 2, TTL_S);
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const value = db.columnInt64(stmt, 1);
        if (value < 0 or value > @intFromEnum(Status.dead)) continue;
        map.put(map_alloc, db.columnInt64(stmt, 0), .{ .status = @enumFromInt(value), .checked_at = db.columnInt64(stmt, 2) }) catch {};
    }
}

/// Wipe every cached row for `kind` — the "Test" button uses this to force a
/// fresh re-probe (otherwise still-fresh TTL rows reload mid-sweep and block it).
pub fn clearKind(kind: []const u8) void {
    const stmt = db.prepare("DELETE FROM link_health WHERE kind=?1") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    _ = db.step(stmt);
}

/// True when `url` has a fresh cached probe under `kind` (within TTL).
pub fn isFresh(kind: []const u8, url: []const u8) bool {
    const stmt = db.prepare(
        "SELECT 1 FROM link_health WHERE url_hash=?1 AND kind=?2 AND checked_at > strftime('%s','now') - ?3 AND checked_at <= strftime('%s','now')",
    ) orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, urlHash(url));
    db.bindText(stmt, 2, kind);
    db.bindInt64(stmt, 3, TTL_S);
    return db.step(stmt) == db.c.SQLITE_ROW;
}

/// Theme colour for a status dot — shared so every vertical's dot matches.
pub fn statusColor(s: Status) dvui.Color {
    const theme = @import("../ui/theme.zig");
    return switch (s) {
        .live => theme.colors.success,
        .slow => theme.colors.warning,
        .dead => theme.colors.danger,
        .unknown => theme.colors.text_tertiary,
    };
}

/// Call only after all workers have joined.
pub fn deinit() void {
    mtx.lock();
    defer mtx.unlock();
    for (kinds[0..kind_count]) |*k| {
        k.health_map.deinit(map_alloc);
        k.probe_attempted.deinit(map_alloc);
        k.* = .{};
    }
    kind_count = 0;
}
