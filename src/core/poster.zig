const std = @import("std");
const dvui = @import("dvui");
const http = @import("http.zig");
const db = @import("db.zig");

// ══════════════════════════════════════════════════════════
// Opal v2 — Poster Daemon
//
// Single shared poster fetching engine used by all content
// providers (TMDB, Anime, Jellyfin, YouTube, Plugins).
// Replaces 4+ copy-pasted fetchPoster() implementations.
// ══════════════════════════════════════════════════════════

const c_alloc = std.heap.c_allocator;

/// Cap on simultaneous in-flight poster fetches across ALL providers (TMDB,
/// Anime, Jellyfin, YouTube, Plugins share this one daemon). Each worker holds a
/// 512 KB decode buffer + an http connection, so without a cap a large grid
/// (anime infinite scroll can hold up to 100 cards) scrolled quickly would spawn
/// a thread/allocation storm. Over the cap we simply skip — the caller leaves
/// fetching_flag false, so the card retries next frame once a slot frees.
var in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
const MAX_CONCURRENT: u32 = 8;

/// Shared global cap for providers that decode posters in their OWN worker
/// (jellyfin auth-in-URL, plugins via curl) instead of fetchAsync. Claim a slot
/// before spawning; if it returns false, skip and retry next frame. Release in
/// the worker's defer. Keeps every provider under the same MAX_CONCURRENT.
pub fn tryClaimSlot() bool {
    if (in_flight.load(.acquire) >= MAX_CONCURRENT) return false;
    _ = in_flight.fetchAdd(1, .acq_rel);
    return true;
}
pub fn releaseSlot() void {
    _ = in_flight.fetchSub(1, .acq_rel);
}

// ── Persistent poster cache (poster_cache table) ──
// Keyed by a 64-bit FNV-1a hash of the image URL so every provider that goes
// through fetchAsync (TMDB, Anime, YouTube, Plugins) shares one disk cache and
// posters survive restarts instead of re-downloading each session. Stores the
// ENCODED bytes (jpeg/png as downloaded) — ~10× smaller than RGBA.
// All access serialized behind cache_lock; a null db handle degrades to no-op.

var cache_lock: @import("sync.zig").Mutex = .{};
var cache_store_count: u32 = 0; // guarded by cache_lock; drives periodic prune

fn cacheKey(url: []const u8) i64 {
    return @bitCast(std.hash.Fnv1a_64.hash(url));
}

/// Returns a c_alloc'd copy of the cached encoded image, or null. Caller frees.
fn cacheLoad(key: i64) ?[]u8 {
    cache_lock.lock();
    defer cache_lock.unlock();
    const stmt = db.prepare("SELECT jpeg_data FROM poster_cache WHERE item_id = ?1") orelse return null;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, key);
    if (db.step(stmt) == db.c.SQLITE_ROW) {
        if (db.columnBlob(stmt, 0)) |blob| {
            if (blob.len == 0) return null;
            const copy = c_alloc.alloc(u8, blob.len) catch return null;
            @memcpy(copy, blob);
            return copy;
        }
    }
    return null;
}

/// Remove a cache row — called when a cached blob fails to decode (truncated
/// write, bad payload cached once) so it can't poison the poster forever.
fn cacheDelete(key: i64) void {
    cache_lock.lock();
    defer cache_lock.unlock();
    const stmt = db.prepare("DELETE FROM poster_cache WHERE item_id = ?1") orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, key);
    _ = db.step(stmt);
}

fn cacheStore(key: i64, encoded: []const u8, w: u32, h: u32) void {
    if (encoded.len == 0 or encoded.len > 512 * 1024) return;
    cache_lock.lock();
    defer cache_lock.unlock();
    const stmt = db.prepare("INSERT OR REPLACE INTO poster_cache (item_id, jpeg_data, width, height, cached_at) VALUES (?1, ?2, ?3, ?4, strftime('%s','now'))") orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, key);
    db.bindBlob(stmt, 2, encoded);
    db.bindInt(stmt, 3, @intCast(w));
    db.bindInt(stmt, 4, @intCast(h));
    _ = db.step(stmt);
    // Periodic prune: keep the newest ~5000 posters (worst case ≈ a few
    // hundred MB). Every 64 stores, not every store — the subquery scans.
    cache_store_count +%= 1;
    if (cache_store_count % 64 == 0) {
        db.exec("DELETE FROM poster_cache WHERE item_id NOT IN (SELECT item_id FROM poster_cache ORDER BY cached_at DESC LIMIT 5000)");
    }
}

// ── Public cache API for providers with their OWN download workers ──
// (YouTube std.http, Jellyfin auth URL, plugins curl — they can't route
// through fetchAsync, but share this disk cache: check before downloading,
// store after a clean decode, delete a blob that fails to decode.)

/// Returns a c_alloc'd copy of the cached encoded image for this URL, or
/// null. Free with cacheFreeEncoded.
pub fn cacheLoadForUrl(url: []const u8) ?[]u8 {
    return cacheLoad(cacheKey(url));
}

pub fn cacheFreeEncoded(buf: []u8) void {
    c_alloc.free(buf);
}

pub fn cacheStoreForUrl(url: []const u8, encoded: []const u8, w: u32, h: u32) void {
    cacheStore(cacheKey(url), encoded, w, h);
}

/// Drop a poisoned row (cached bytes that no longer decode).
pub fn cacheDeleteForUrl(url: []const u8) void {
    cacheDelete(cacheKey(url));
}

pub const PosterRequest = struct {
    url: []const u8,
    pixels_out: *?[]u8,
    w_out: *u32,
    h_out: *u32,
    fetching_flag: *bool,
};

/// Fetch a poster image from URL in a background thread.
/// Sets fetching_flag while working, writes pixels/w/h on success.
//
// SAFETY (fetching_flag is a plain *bool, not *std.atomic.Value(bool)):
// This flag is only ever a re-entry guard. The check-then-set below
// (`if (fetching_flag.*) return; ... fetching_flag.* = true;`) and the worker's
// `defer args.flag.* = false;` all run for a single card whose fetch is kicked
// off exclusively from the UI (render) thread — the flag is written true on the
// UI thread and cleared false on the one detached worker that owns it, never
// concurrently set by two threads. The pointed-to field (poster_fetching /
// still_fetching / loading_poster_fetching) is shared with several manual-worker
// providers (plugins, jellyfin, anime's own fetchPoster) and is defined across 5
// distinct state structs, so making it atomic would cascade to 60+ access sites
// well beyond this daemon. What actually bounds concurrency here is the atomic
// `in_flight` counter (acquire/release) — the real cross-thread invariant (the
// MAX_CONCURRENT cap and slot accounting) is already atomic; the per-card bool is
// not a cross-thread hand-off, so a plain bool is sufficient and correct.
pub fn fetchAsync(url: []const u8, pixels_out: *?[]u8, w_out: *u32, h_out: *u32, fetching_flag: *bool) void {
    if (fetching_flag.*) return;
    // Bound the URL and copy it by value into the worker args (CLAUDE.md:
    // never pass a slice into a mutable array to a detached thread). Callers
    // pass item.poster_url[0..len] — a slice into a results[] buffer that a
    // fetch worker may rewrite mid-flight. Copy the bytes so each worker owns
    // its URL and there's no shared-slice race.
    if (url.len > 1024) return;
    // Don't set fetching_flag when over the cap — leave the card unfetched so
    // it retries on a later frame once an in-flight slot frees.
    if (in_flight.load(.acquire) >= MAX_CONCURRENT) return;
    fetching_flag.* = true;
    _ = in_flight.fetchAdd(1, .acq_rel);

    const Args = struct { url_buf: [1024]u8, url_len: usize, pix: *?[]u8, w: *u32, h: *u32, flag: *bool };

    var url_buf: [1024]u8 = undefined;
    @memcpy(url_buf[0..url.len], url);

    if (std.Thread.spawn(.{}, struct {
        fn worker(args: Args) void {
            defer args.flag.* = false;
            defer _ = in_flight.fetchSub(1, .acq_rel);

            const worker_url = args.url_buf[0..args.url_len];
            const key = cacheKey(worker_url);

            // Disk cache first — a hit skips the network entirely, so grids
            // paint instantly on relaunch. A cached blob that fails to decode
            // is DELETED and re-fetched from the network, so one corrupt row
            // (app killed mid-INSERT, bad payload cached once) can't blank a
            // poster forever. Dimension bounds reject decompression bombs; a
            // fresh network fetch that decodes cleanly is persisted.
            const cached = cacheLoad(key);
            defer if (cached) |cb| c_alloc.free(cb);

            var net_buf: ?[]u8 = null;
            defer if (net_buf) |bf| c_alloc.free(bf);

            var decoded: [*c]u8 = null;
            var w: c_int = 0;
            var h: c_int = 0;
            var attempt: u8 = 0;
            while (attempt < 2) : (attempt += 1) {
                const used_cache = attempt == 0 and cached != null;
                const data: []const u8 = if (used_cache) cached.? else blk: {
                    if (net_buf == null) net_buf = c_alloc.alloc(u8, 512 * 1024) catch return;
                    break :blk http.fetchImage(worker_url, net_buf.?) orelse return;
                };
                var comp: c_int = 0;
                w = 0;
                h = 0;
                decoded = dvui.c.stbi_load_from_memory(data.ptr, @intCast(data.len), &w, &h, &comp, 4);
                if (decoded != null and w > 0 and h > 0 and w <= 8192 and h <= 8192) {
                    if (!used_cache) cacheStore(key, data, @intCast(w), @intCast(h));
                    break;
                }
                if (decoded != null) dvui.c.stbi_image_free(decoded);
                decoded = null;
                if (used_cache) {
                    cacheDelete(key); // poisoned row — retry from the network
                } else {
                    return; // network payload undecodable — give up
                }
            }
            const pixels = decoded orelse return;
            defer dvui.c.stbi_image_free(pixels);

            // Compute in usize to avoid i32 overflow on large images
            // (w * h * 4 would otherwise be evaluated in c_int).
            const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
            const p_slice = c_alloc.alloc(u8, p_len) catch return;
            @memcpy(p_slice, pixels[0..p_len]);

            args.w.* = @intCast(w);
            args.h.* = @intCast(h);
            args.pix.* = p_slice;
            // Wake the UI thread so the poster shows immediately. Browse/TMDB
            // grids have no timer, so without this the decoded poster only
            // "pops in" on the next incidental repaint (mouse move, etc.). The
            // *Window form of refresh is thread-safe and its lock also publishes
            // the w/h/pix writes above with proper ordering for uploadIfReady.
            if (@import("state.zig").app.dvui_win) |win| dvui.refresh(win, @src(), null);
        }
    }.worker, .{Args{ .url_buf = url_buf, .url_len = url.len, .pix = pixels_out, .w = w_out, .h = h_out, .flag = fetching_flag }})) |t| {
        t.detach();
    } else |_| {
        fetching_flag.* = false;
        _ = in_flight.fetchSub(1, .acq_rel); // spawn failed — release the slot we reserved
    }
}

/// Upload pending pixel data to GPU texture. Call from render thread.
/// Returns true if texture is ready.
pub fn uploadIfReady(pixels: *?[]u8, w: u32, h: u32, tex: *?dvui.Texture) bool {
    if (tex.* != null) return true;
    if (pixels.* == null) return false;

    const num_px = w * h;
    if (num_px == 0) return false;

    // Torn-publish guard: the worker writes w/h then the pixels pointer; on a
    // weakly-ordered CPU the UI can observe the new pixels with stale w/h. If the
    // buffer length doesn't exactly match w*h*4 the dims aren't consistent yet —
    // skip this frame (prevents an out-of-bounds read / mis-sized texture).
    if (pixels.*.?.len != num_px * 4) return false;

    const pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(pixels.*.?.ptr)))[0..num_px];
    tex.* = dvui.textureCreate(pma, w, h, .linear, .rgba_32) catch null;

    if (tex.* != null) {
        c_alloc.free(pixels.*.?);
        pixels.* = null;
    }
    return tex.* != null;
}

/// Free a poster texture and associated memory.
pub fn deinitPoster(pixels: *?[]u8, tex: *?dvui.Texture) void {
    if (tex.*) |t| {
        dvui.textureDestroyLater(t);
        tex.* = null;
    }
    if (pixels.*) |p| {
        c_alloc.free(p);
        pixels.* = null;
    }
}
