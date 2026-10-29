//! Reusable muted inline media player, isolated from watch history and queues.
const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig").mpv;
const sdl = @import("../core/c.zig").sdl;
const alloc = @import("../core/alloc.zig").allocator;
pub const Player = struct {
    handle: ?*c.mpv_handle = null,
    renderer: ?*c.mpv_render_context = null,
    pixels: ?[]u8 = null,
    texture: ?dvui.Texture = null,
    ready: bool = false,
    failed: bool = false,
    paused: bool = false,
    const width: u32 = 1280;
    const height: u32 = 720;
    pub fn start(self: *Player, url: []const u8, referer: []const u8) bool {
        self.deinit();
        if (comptime @import("build_options").headless) return false;
        self.handle = c.mpv_create() orelse {
            self.failed = true;
            return false;
        };
        const handle = self.handle.?;
        const opts = [_][2][*:0]const u8{
            .{ "config", "no" },                .{ "terminal", "no" },        .{ "load-scripts", "no" }, .{ "vo", "libmpv" },
            .{ "audio", "no" },                 .{ "loop-file", "inf" },      .{ "keep-open", "yes" },   .{ "idle", "yes" },
            .{ "save-position-on-quit", "no" }, .{ "resume-playback", "no" }, .{ "sub-auto", "no" },     .{ "input-default-bindings", "no" },
            .{ "network-timeout", "12" },       .{ "ytdl", "no" },
        };
        for (opts) |opt| _ = c.mpv_set_option_string(handle, opt[0], opt[1]);
        var ref: [2049]u8 = undefined;
        if (referer.len > 0) if (std.fmt.bufPrintZ(&ref, "{s}", .{referer})) |z| {
            _ = c.mpv_set_option_string(handle, "referrer", z);
        } else |_| {};
        if (c.mpv_initialize(handle) < 0) {
            self.failed = true;
            return false;
        }
        var params = [_]c.mpv_render_param{
            .{ .type = c.MPV_RENDER_PARAM_API_TYPE, .data = @constCast(c.MPV_RENDER_API_TYPE_SW) },
            .{ .type = c.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        if (c.mpv_render_context_create(&self.renderer, handle, &params) < 0) {
            self.failed = true;
            return false;
        }
        self.pixels = alloc.alloc(u8, width * height * 4) catch {
            self.failed = true;
            return false;
        };
        if (!@import("../player/player.zig").loadDetached(handle, .{ .url = url })) {
            self.failed = true;
            return false;
        }
        return true;
    }
    pub fn togglePause(self: *Player) void {
        const handle = self.handle orelse return;
        var paused: c_int = if (self.paused) 0 else 1;
        if (c.mpv_set_property(handle, "pause", c.MPV_FORMAT_FLAG, &paused) >= 0) self.paused = !self.paused;
    }
    pub fn draw(self: *Player, w: f32, h: f32) bool {
        if (comptime @import("build_options").headless) return false;
        const handle = self.handle orelse return false;
        for (0..16) |_| {
            const event = c.mpv_wait_event(handle, 0);
            if (event == null or event.*.event_id == c.MPV_EVENT_NONE) break;
            if (event.*.event_id == c.MPV_EVENT_END_FILE) {
                const end: *const c.mpv_event_end_file = @ptrCast(@alignCast(event.*.data));
                if (end.reason == c.MPV_END_FILE_REASON_ERROR) self.failed = true;
            }
        }
        const ctx = self.renderer orelse return false;
        const pixels = self.pixels orelse return false;
        if (c.mpv_render_context_update(ctx) & c.MPV_RENDER_UPDATE_FRAME != 0) {
            const size = [2]c_int{ width, height };
            const stride: usize = width * 4;
            const blocking: c_int = 0;
            var params = [_]c.mpv_render_param{
                .{ .type = c.MPV_RENDER_PARAM_SW_SIZE, .data = @constCast(&size) },
                .{ .type = c.MPV_RENDER_PARAM_SW_FORMAT, .data = @constCast("rgb0") },
                .{ .type = c.MPV_RENDER_PARAM_SW_STRIDE, .data = @constCast(&stride) },
                .{ .type = c.MPV_RENDER_PARAM_SW_POINTER, .data = pixels.ptr },
                .{ .type = c.MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, .data = @constCast(&blocking) },
                .{ .type = c.MPV_RENDER_PARAM_INVALID, .data = null },
            };
            if (c.mpv_render_context_render(ctx, &params) >= 0) {
                if (self.texture == null) {
                    const renderer: *sdl.SDL_Renderer = @ptrCast(@alignCast(dvui.currentWindow().backend.impl.renderer));
                    if (sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGBX32, sdl.SDL_TEXTUREACCESS_STREAMING, width, height)) |tex| {
                        _ = sdl.SDL_SetTextureBlendMode(tex, sdl.SDL_BLENDMODE_NONE);
                        _ = sdl.SDL_SetTextureScaleMode(tex, sdl.SDL_ScaleModeLinear);
                        self.texture = .{ .ptr = tex, .width = width, .height = height, .format = .rgbx_32 };
                    }
                }
                if (self.texture) |tex| self.ready = sdl.SDL_UpdateTexture(@ptrCast(@alignCast(tex.ptr)), null, pixels.ptr, width * 4) == 0;
            }
        }
        if (!self.paused and !self.failed) @import("components.zig").animatedRefresh(33_000);
        if (self.ready) if (self.texture) |tex| {
            _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{ .gravity_x = 0.5, .gravity_y = 0.5, .min_size_content = .{ .w = w, .h = h }, .max_size_content = .{ .w = w, .h = h } });
            return true;
        };
        return false;
    }
    pub fn deinit(self: *Player) void {
        if (self.renderer) |ctx| c.mpv_render_context_free(ctx);
        if (self.handle) |handle| c.mpv_terminate_destroy(handle);
        if (self.pixels) |pixels| alloc.free(pixels);
        var none: ?[]u8 = null;
        @import("../core/poster.zig").deinitPoster(&none, &self.texture);
        self.* = .{};
    }
};
