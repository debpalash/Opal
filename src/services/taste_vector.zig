const std = @import("std");
const db = @import("../core/db.zig");
const ai_memory = @import("ai_memory.zig");

// ══════════════════════════════════════════════════════════
//  Taste Vector — a single normalized embedding that captures
//  the scenes/conversations the user has leaned into. Computed
//  as a recency- and scene-weighted mean over the embeddings
//  ALREADY stored in vec_aimemory. Used by recommendations.zig
//  to seed a no-cold-start For-You rail.
//
//  Pure aggregation over db.zig accessors — no SQL here, no new
//  threads, no allocations. Robust: returns false (degrade) on
//  any empty/error condition rather than crashing.
// ══════════════════════════════════════════════════════════

const DIM = ai_memory.EMBED_DIM;

// Per-title cumulative weight cap so one rewatched binge cannot dominate
// the taste vector. Tracked by a cheap hash of the (truncated) title.
const TITLE_CAP: f64 = 3.0;
const MAX_TITLES: usize = 256;

// ── Cache ──
// The taste vector is expensive-ish to recompute (one blob copy per row),
// so cache it and only recompute when the aimemory row count changes
// (a coarse but cheap dirty signal — new ingests bump the count).
var cache: [DIM]f32 = std.mem.zeroes([DIM]f32);
var cache_valid: bool = false;
var cache_row_count: usize = std.math.maxInt(usize);

/// Compute the taste vector into `out`. Returns false when no rows
/// contributed (empty store / all embeddings missing) so callers can
/// fall back to a non-embedding strategy.
pub fn computeTaste(out: *[DIM]f32) bool {
    const n = db.aiMemRowCount();
    if (n == 0) {
        cache_valid = false;
        cache_row_count = 0;
        return false;
    }

    // Serve from cache when the row count is unchanged.
    if (cache_valid and cache_row_count == n) {
        @memcpy(out, &cache);
        return true;
    }

    var sum: [DIM]f64 = std.mem.zeroes([DIM]f64);
    var contributed: bool = false;

    // Track per-title cumulative weight to enforce the cap. Fixed-size,
    // no allocations; overflow titles simply go uncapped (acceptable).
    var title_hash: [MAX_TITLES]u64 = std.mem.zeroes([MAX_TITLES]u64);
    var title_weight: [MAX_TITLES]f64 = std.mem.zeroes([MAX_TITLES]f64);
    var title_used: usize = 0;

    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        var row: db.AiMemRow = .{};
        if (!db.aiMemRowAt(idx, &row)) continue;

        var emb: [DIM]f32 = undefined;
        if (!db.getEmbeddingBlob(row.id, &emb)) continue;

        // Base weight: scenes count more; decay by recency (half-life 30d).
        const base: f64 = if (row.is_scene) 1.5 else 1.0;
        const age = if (row.age_days > 0) row.age_days else 0;
        const recency = std.math.pow(f64, 0.5, age / 30.0);
        var weight = base * recency;
        if (!(weight > 0)) continue; // NaN/zero guard

        // Per-title cap: clamp this row's weight so the running cumulative
        // weight for its title does not exceed TITLE_CAP.
        const title = row.title[0..@min(row.title_len, row.title.len)];
        if (title.len > 0) {
            const h = std.hash.Wyhash.hash(0, title);
            var slot: ?usize = null;
            for (title_hash[0..title_used], 0..) |hh, i| {
                if (hh == h) {
                    slot = i;
                    break;
                }
            }
            if (slot == null and title_used < MAX_TITLES) {
                title_hash[title_used] = h;
                title_weight[title_used] = 0;
                slot = title_used;
                title_used += 1;
            }
            if (slot) |s| {
                const remaining = TITLE_CAP - title_weight[s];
                if (remaining <= 0) continue; // title already saturated
                if (weight > remaining) weight = remaining;
                title_weight[s] += weight;
            }
        }

        for (0..DIM) |d| {
            sum[d] += @as(f64, emb[d]) * weight;
        }
        contributed = true;
    }

    if (!contributed) {
        cache_valid = false;
        return false;
    }

    // L2-normalize into out.
    var norm_sq: f64 = 0;
    for (0..DIM) |d| norm_sq += sum[d] * sum[d];
    const norm = std.math.sqrt(norm_sq);
    if (!(norm > 0)) {
        cache_valid = false;
        return false;
    }
    for (0..DIM) |d| {
        out[d] = @floatCast(sum[d] / norm);
    }

    // Update cache.
    @memcpy(&cache, out);
    cache_valid = true;
    cache_row_count = n;
    return true;
}

/// Force the next computeTaste to recompute (e.g. after a known ingest).
pub fn invalidate() void {
    cache_valid = false;
}
