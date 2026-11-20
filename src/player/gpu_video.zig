//! GPU video path: libmpv's OpenGL render API drawing into textures owned by
//! SDL's OpenGL renderer (the one dvui draws with).
//!
//! Threads:
//!  - UI thread: creates the worker's GL context (sharing objects with SDL's),
//!    creates/destroys the three SDL target textures per render size, and
//!    presents the newest finished slot as the player's `dvui.Texture`.
//!  - Render worker (player.zig gpuRenderWorker): owns its own GL context,
//!    the mpv render context and one framebuffer per slot. mpv's GL state
//!    therefore never touches SDL's cached renderer state, and mpv's frame
//!    timing blocks only the worker, as on the software path.
//!
//! Policy and slot rotation live in gpu_video_pure.zig. Any failure (no GL
//! renderer, no shared context, mpv refusing the GL context) leaves the player
//! on the software path.

const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const logs = @import("../core/logs.zig");
pub const pure = @import("gpu_video_pure.zig");

/// GUI desktop builds only: headless has no SDL, mobile uses SDL3/GLES.
pub const supported_build = !@import("build_options").headless and
    !@import("../core/platform_pure.zig").sdl3;

/// SDL handle types, opaque in headless builds (which have no SDL).
const GLContext = if (supported_build) c.sdl.SDL_GLContext else ?*anyopaque;
const SdlTexture = if (supported_build) c.sdl.SDL_Texture else anyopaque;
const SdlWindow = if (supported_build) c.sdl.SDL_Window else anyopaque;

const GLuint = c_uint;
const GLenum = c_uint;
const GLint = c_int;
const GLsizei = c_int;
const GL_TEXTURE_2D: GLenum = 0x0DE1;
const GL_TEXTURE_RECTANGLE: GLenum = 0x84F5;
const GL_TEXTURE_BINDING_2D: GLenum = 0x8069;
const GL_TEXTURE_BINDING_RECTANGLE: GLenum = 0x84F6;
const GL_FRAMEBUFFER: GLenum = 0x8D40;
const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: GLenum = 0x8CD5;

/// GL entry points resolved for the context current on the calling thread
/// (WGL proc addresses are per-context).
pub const Gl = struct {
    genFramebuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    deleteFramebuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    bindFramebuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    framebufferTexture2D: *const fn (GLenum, GLenum, GLenum, GLuint, GLint) callconv(.c) void,
    checkFramebufferStatus: *const fn (GLenum) callconv(.c) GLenum,
    finish: *const fn () callconv(.c) void,
    getIntegerv: *const fn (GLenum, *GLint) callconv(.c) void,

    pub fn load() ?Gl {
        var gl: Gl = undefined;
        inline for (.{
            .{ "genFramebuffers", "glGenFramebuffers" },
            .{ "deleteFramebuffers", "glDeleteFramebuffers" },
            .{ "bindFramebuffer", "glBindFramebuffer" },
            .{ "framebufferTexture2D", "glFramebufferTexture2D" },
            .{ "checkFramebufferStatus", "glCheckFramebufferStatus" },
            .{ "finish", "glFinish" },
            .{ "getIntegerv", "glGetIntegerv" },
        }) |entry| {
            const ptr = c.sdl.SDL_GL_GetProcAddress(entry[1]) orelse return null;
            @field(gl, entry[0]) = @ptrCast(@alignCast(ptr));
        }
        return gl;
    }
};

var checked = false;
var available = false;
var ui_window: ?*SdlWindow = null;
var ui_ctx: GLContext = null;
var ui_gl: ?Gl = null;

/// Before the window exists: ask SDL for its OpenGL renderer when the GPU
/// path is wanted. SDL otherwise picks Metal on macOS and Direct3D on Windows.
pub fn requestRendererHint() void {
    if (comptime !supported_build) return;
    const env = std.c.getenv("OPAL_VIDEO_RENDER");
    const value: ?[]const u8 = if (env) |e| std.mem.span(e) else null;
    if (!pure.requested(@import("builtin").os.tag, value)) return;
    _ = c.sdl.SDL_SetHint("SDL_RENDER_DRIVER", "opengl");
    // Naming a driver makes SDL2 turn render batching off unless batching is
    // requested explicitly; dvui relies on batching for its UI draw calls.
    _ = c.sdl.SDL_SetHint("SDL_RENDER_BATCHING", "1");
}

/// Test-only: forget the cached renderer probe so a fixture's own window
/// is examined (and later fixtures with other renderers are not affected).
pub fn resetForTest() void {
    if (!@import("builtin").is_test) @compileError("gpu_video.resetForTest is test-only");
    checked = false;
    available = false;
    ui_window = null;
    ui_ctx = null;
    ui_gl = null;
}

/// UI thread, inside a dvui frame. True when SDL is drawing with OpenGL and
/// its context can be shared. Checked once per process.
pub fn isAvailable() bool {
    if (comptime !supported_build) return false;
    // GL contexts and SDL textures belong to the UI thread.
    if (!@import("../ui/theme.zig").isUiThread()) return false;
    if (checked) return available;
    // Outside a frame there is no renderer to inspect yet; probe later.
    const window = dvui.current_window orelse return false;
    checked = true;
    const env = std.c.getenv("OPAL_VIDEO_RENDER");
    const value: ?[]const u8 = if (env) |e| std.mem.span(e) else null;
    if (!pure.requested(@import("builtin").os.tag, value)) return false;
    const renderer: *c.sdl.SDL_Renderer = @ptrCast(@alignCast(window.backend.impl.renderer));
    var info: c.sdl.SDL_RendererInfo = undefined;
    if (c.sdl.SDL_GetRendererInfo(renderer, &info) != 0) return false;
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(info.name)));
    if (!pure.rendererSupportsGpu(name)) {
        logs.pushLog("info", "player", "Video uses the software path (SDL renderer is not OpenGL)", false);
        return false;
    }
    ui_window = c.sdl.SDL_GL_GetCurrentWindow();
    ui_ctx = c.sdl.SDL_GL_GetCurrentContext();
    ui_gl = Gl.load();
    if (ui_window == null or ui_ctx == null or ui_gl == null) return false;
    available = true;
    logs.pushLog("info", "player", "Video renders on the GPU (OpenGL)", false);
    return true;
}

/// UI thread: a GL context sharing textures with SDL's, for one render
/// worker. SDL's own context is current again on return.
pub fn createWorkerContext() GLContext {
    if (comptime !supported_build) return null;
    if (!available) return null;
    _ = c.sdl.SDL_GL_SetAttribute(c.sdl.SDL_GL_SHARE_WITH_CURRENT_CONTEXT, 1);
    _ = c.sdl.SDL_GL_MakeCurrent(ui_window, ui_ctx);
    const ctx = c.sdl.SDL_GL_CreateContext(ui_window);
    _ = c.sdl.SDL_GL_SetAttribute(c.sdl.SDL_GL_SHARE_WITH_CURRENT_CONTEXT, 0);
    _ = c.sdl.SDL_GL_MakeCurrent(ui_window, ui_ctx);
    return ctx;
}

/// UI thread, after the worker using `ctx` has exited.
pub fn destroyWorkerContext(ctx: GLContext) void {
    if (comptime !supported_build) return;
    if (ctx == null) return;
    c.sdl.SDL_GL_DeleteContext(ctx);
    _ = c.sdl.SDL_GL_MakeCurrent(ui_window, ui_ctx);
}

/// Worker thread: make the worker context current on this thread.
pub fn bindWorkerContext(ctx: GLContext) bool {
    if (comptime !supported_build) return false;
    return c.sdl.SDL_GL_MakeCurrent(ui_window, ctx) == 0;
}

/// Worker thread, on exit.
pub fn unbindWorkerContext() void {
    if (comptime !supported_build) return;
    _ = c.sdl.SDL_GL_MakeCurrent(ui_window, null);
}

/// mpv resolves GL functions through SDL for the worker's context.
pub fn getProcAddress(_: ?*anyopaque, name: [*c]const u8) callconv(.c) ?*anyopaque {
    if (comptime !supported_build) return null;
    return c.sdl.SDL_GL_GetProcAddress(name);
}

pub const Slot = struct {
    tex: ?*SdlTexture = null,
    id: GLuint = 0,
    target: GLenum = GL_TEXTURE_2D,
};

/// Three equally sized render targets. `gen` identifies a size change so the
/// worker rebuilds its framebuffers and the UI can retire the old set.
pub const Set = struct {
    slots: [3]Slot = .{ .{}, .{}, .{} },
    w: u32 = 0,
    h: u32 = 0,
    gen: u32 = 0,

    pub fn valid(self: *const Set) bool {
        return self.w > 0 and self.slots[0].tex != null;
    }

    pub fn texture(self: *const Set, slot: u2) dvui.Texture {
        return .{ .ptr = self.slots[slot].tex.?, .width = self.w, .height = self.h, .format = .rgba_32, .interpolation = .linear, .wrap_u = .clamp, .wrap_v = .clamp };
    }
};

/// UI thread: three SDL target textures of `w`x`h`, drawn by dvui with the
/// same premultiplied blend and linear filtering as the software texture.
pub fn createSet(w: u32, h: u32, gen: u32) ?Set {
    if (comptime !supported_build) return null;
    const window = dvui.current_window orelse return null;
    const gl = ui_gl orelse return null;
    const renderer: *c.sdl.SDL_Renderer = @ptrCast(@alignCast(window.backend.impl.renderer));
    var set: Set = .{ .w = w, .h = h, .gen = gen };
    const pma_blend = c.sdl.SDL_ComposeCustomBlendMode(
        c.sdl.SDL_BLENDFACTOR_ONE,
        c.sdl.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        c.sdl.SDL_BLENDOPERATION_ADD,
        c.sdl.SDL_BLENDFACTOR_ONE,
        c.sdl.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        c.sdl.SDL_BLENDOPERATION_ADD,
    );
    for (&set.slots) |*slot| {
        const tex = c.sdl.SDL_CreateTexture(renderer, @intCast(c.sdl.SDL_PIXELFORMAT_ABGR8888), c.sdl.SDL_TEXTUREACCESS_TARGET, @intCast(w), @intCast(h)) orelse {
            destroySetNow(&set);
            return null;
        };
        slot.tex = tex;
        _ = c.sdl.SDL_SetTextureBlendMode(tex, pma_blend);
        _ = c.sdl.SDL_SetTextureScaleMode(tex, c.sdl.SDL_ScaleModeLinear);
        var tw: f32 = 0;
        var th: f32 = 0;
        if (c.sdl.SDL_GL_BindTexture(tex, &tw, &th) != 0) {
            destroySetNow(&set);
            return null;
        }
        var id: GLint = 0;
        gl.getIntegerv(GL_TEXTURE_BINDING_2D, &id);
        slot.target = GL_TEXTURE_2D;
        if (id == 0) {
            gl.getIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &id);
            slot.target = GL_TEXTURE_RECTANGLE;
        }
        _ = c.sdl.SDL_GL_UnbindTexture(tex);
        if (id <= 0) {
            destroySetNow(&set);
            return null;
        }
        slot.id = @intCast(id);
    }
    return set;
}

/// UI thread, inside a dvui frame: release after this frame has drawn.
pub fn destroySetLater(set: *Set) void {
    if (comptime !supported_build) return;
    if (dvui.current_window == null) return destroySetNow(set);
    for (&set.slots) |*slot| {
        if (slot.tex) |tex| dvui.textureDestroyLater(.{ .ptr = tex, .width = @max(set.w, 1), .height = @max(set.h, 1), .format = .rgba_32, .interpolation = .linear, .wrap_u = .clamp, .wrap_v = .clamp });
        slot.* = .{};
    }
    set.w = 0;
    set.h = 0;
}

/// UI thread, when no frame can still reference the textures.
pub fn destroySetNow(set: *Set) void {
    if (comptime !supported_build) return;
    for (&set.slots) |*slot| {
        if (slot.tex) |tex| c.sdl.SDL_DestroyTexture(tex);
        slot.* = .{};
    }
    set.w = 0;
    set.h = 0;
}

/// UI thread: a texture another context rendered into must be bound again in
/// SDL's context before its new contents are guaranteed visible (Apple's GL
/// sharing rule; harmless elsewhere).
pub fn refreshBinding(set: *const Set, slot: u2) void {
    if (comptime !supported_build) return;
    const tex = set.slots[slot].tex orelse return;
    var tw: f32 = 0;
    var th: f32 = 0;
    if (c.sdl.SDL_GL_BindTexture(tex, &tw, &th) == 0) _ = c.sdl.SDL_GL_UnbindTexture(tex);
}

/// Worker thread: one framebuffer per slot of `set`, in the worker context.
pub fn createFramebuffers(gl: *const Gl, set: *const Set, out: *[3]GLuint) bool {
    gl.genFramebuffers(3, out);
    for (set.slots, 0..) |slot, i| {
        gl.bindFramebuffer(GL_FRAMEBUFFER, out[i]);
        gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, slot.target, slot.id, 0);
        if (gl.checkFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            gl.bindFramebuffer(GL_FRAMEBUFFER, 0);
            gl.deleteFramebuffers(3, out);
            out.* = .{ 0, 0, 0 };
            return false;
        }
    }
    gl.bindFramebuffer(GL_FRAMEBUFFER, 0);
    return true;
}

pub fn deleteFramebuffers(gl: *const Gl, fbos: *[3]GLuint) void {
    if (fbos[0] == 0) return;
    gl.deleteFramebuffers(3, fbos);
    fbos.* = .{ 0, 0, 0 };
}

/// Shared between the UI thread and one render worker; guarded by the
/// player's `frame_mutex`.
pub const Target = struct {
    ctx: GLContext = null,
    /// Set the worker renders into.
    current: Set = .{},
    /// Newer set requested by the UI (size change); adopted by the worker.
    pending: ?Set = null,
    /// Sets the worker stopped using; destroyed by the UI once the frame it
    /// shows comes from a newer set.
    retired: [2]?Set = .{ null, null },
    slots: pure.Slots = .{},
    next_gen: u32 = 1,
    /// Worker → UI start-up handshake.
    ready: std.Io.Event = .unset,
    started_ok: bool = false,

    /// UI thread: make sure a set of exactly `w`x`h` is current or pending.
    pub fn requestSize(self: *Target, w: u32, h: u32) void {
        if (w < 2 or h < 2) return;
        if (self.pending) |p| {
            if (p.w == w and p.h == h) return;
        } else if (self.current.w == w and self.current.h == h) return;
        // Both retirement slots still wait for a newer frame: resize once the
        // worker catches up instead of leaking a set.
        if (self.retired[0] != null and self.retired[1] != null) return;
        const set = createSet(w, h, self.next_gen) orelse {
            logs.pushLog("error", "player", "GPU video: render target creation failed", true);
            return;
        };
        self.next_gen +%= 1;
        if (self.pending) |*old| destroySetLater(old);
        self.pending = set;
    }

    /// Worker thread: adopt a pending set; the old one is retired for the UI.
    pub fn adoptPending(self: *Target) bool {
        const next = self.pending orelse return false;
        self.pending = null;
        if (self.current.valid()) {
            if (self.retired[0] == null) self.retired[0] = self.current else self.retired[1] = self.current;
        }
        self.current = next;
        self.slots = .{};
        return true;
    }

    /// UI thread: newest finished frame, or null when nothing new.
    pub fn take(self: *Target) ?dvui.Texture {
        const slot = self.slots.take() orelse return null;
        if (!self.current.valid()) return null;
        for (&self.retired) |*r| {
            if (r.*) |*set| destroySetLater(set);
            r.* = null;
        }
        refreshBinding(&self.current, slot);
        return self.current.texture(slot);
    }

    /// UI thread, after the worker exited: free every texture.
    pub fn destroyAll(self: *Target) void {
        destroySetLater(&self.current);
        if (self.pending) |*p| destroySetLater(p);
        self.pending = null;
        for (&self.retired) |*r| {
            if (r.*) |*set| destroySetLater(set);
            r.* = null;
        }
        destroyWorkerContext(self.ctx);
        self.ctx = null;
    }
};
