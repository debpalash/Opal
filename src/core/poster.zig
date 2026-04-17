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
    fetching_flag.* = true;
    
    const Args = struct { url_ptr: []const u8, pix: *?[]u8, w: *u32, h: *u32, flag: *bool };
    
    _ = std.Thread.spawn(.{}, struct {
        fn worker(args: Args) void {
            defer args.flag.* = false;
            
            var img_buf: [512 * 1024]u8 = undefined;
            const data = http.fetchImage(args.url_ptr, &img_buf) orelse return;
            
            var w: c_int = 0;
            var h: c_int = 0;
            var comp: c_int = 0;
            const pixels = dvui.c.stbi_load_from_memory(data.ptr, @intCast(data.len), &w, &h, &comp, 4);
            if (pixels == null) return;
            defer dvui.c.stbi_image_free(pixels);
            
            if (w <= 0 or h <= 0) return;
            const p_len: usize = @intCast(w * h * 4);
            const p_slice = c_alloc.alloc(u8, p_len) catch return;
            @memcpy(p_slice, pixels[0..p_len]);
            
            args.w.* = @intCast(w);
            args.h.* = @intCast(h);
            args.pix.* = p_slice;
        }
    }.worker, .{ Args{ .url_ptr = url, .pix = pixels_out, .w = w_out, .h = h_out, .flag = fetching_flag } }) catch {
        fetching_flag.* = false;
    };
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
