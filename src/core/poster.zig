const std = @import("std");
const dvui = @import("dvui");
const http = @import("http.zig");

// ══════════════════════════════════════════════════════════
// ZigZag v2 — Poster Daemon
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

pub const PosterRequest = struct {
    url: []const u8,
    pixels_out: *?[]u8,
    w_out: *u32,
    h_out: *u32,
    fetching_flag: *bool,
};

/// Fetch a poster image from URL in a background thread.
/// Sets fetching_flag while working, writes pixels/w/h on success.
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

            const img_buf = c_alloc.alloc(u8, 512 * 1024) catch return;
            defer c_alloc.free(img_buf);
            const data = http.fetchImage(args.url_buf[0..args.url_len], img_buf) orelse return;

            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            const pixels = dvui.c.stbi_load_from_memory(data.ptr, @intCast(data.len), &w, &h, &comp, 4);
            if (pixels == null) return;
            defer dvui.c.stbi_image_free(pixels);

            if (w <= 0 or h <= 0) return;
            // Compute in usize to avoid i32 overflow on large images
            // (w * h * 4 would otherwise be evaluated in c_int).
            const p_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
            const p_slice = c_alloc.alloc(u8, p_len) catch return;
            @memcpy(p_slice, pixels[0..p_len]);

            args.w.* = @intCast(w);
            args.h.* = @intCast(h);
            args.pix.* = p_slice;
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
        t.deinit();
        tex.* = null;
    }
    if (pixels.*) |p| {
        c_alloc.free(p);
        pixels.* = null;
    }
}
