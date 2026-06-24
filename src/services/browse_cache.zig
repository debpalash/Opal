//! Stale-while-revalidate timing for the Browse data sources.
//!
//! Each source keeps a `last_fetch_s` timestamp. On a tab visit:
//!   • no data yet            → fetch (initial load)
//!   • data + fresh (< TTL)   → show cache, do nothing (instant, no reload)
//!   • data + stale (≥ TTL)   → show cache NOW, kick a background refresh
//!
//! So revisiting a tab is instant and only hits the network when the cache has
//! aged past the TTL — and even then the user sees the old data immediately
//! while fresh data loads in behind it.

const io = @import("../core/io_global.zig");

/// Cache lifetime: 12 minutes (within the "10–15 min" the product wants).
pub const TTL_S: i64 = 12 * 60;

pub fn now() i64 {
    return io.timestamp();
}

/// True if `last_fetch_s` is unset or older than the TTL.
pub fn isStale(last_fetch_s: i64) bool {
    if (last_fetch_s <= 0) return true;
    return now() - last_fetch_s >= TTL_S;
}
