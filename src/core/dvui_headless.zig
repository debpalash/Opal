//! Headless stand-in for the `dvui` module (Phase S1 of the server spec).
//!
//! `-Dheadless=true` swaps this in for `dvui_sdl2` in build.zig, so the server
//! binary links no SDL2, no X11, no OpenGL — see docs/headless-server-spec.md.
//!
//! It works because Zig only analyzes *reachable* decls: `main == headlessEntry`
//! never references `appFrame`, so every widget call site in `ui/*` and every
//! `render*` function in `services/*` is simply never compiled. The ~60 modules
//! that `@import("dvui")` need the module to EXIST; only four files in the
//! headless graph — `main.zig`, `core/state.zig`, `core/poster.zig`,
//! `player/player.zig` (plus `services/comics.zig`) — reference symbols from it.
//!
//! Every declaration below therefore exists for one of two reasons: it's a TYPE
//! a headless-reachable struct field is declared as (`?dvui.Texture`), or it's a
//! no-op for something that only matters when there's a window. Nothing here
//! draws. If a build error sends you here, first check whether the caller should
//! be behind `if (!build_options.headless)` instead — widening this file means
//! the desktop and server builds have started to diverge.
//!
//! Signatures are pinned to dvui 0.5.0-dev; a dvui bump that changes one shows
//! up as a desktop-build error, not a silent headless drift.

const std = @import("std");

/// stb_image, the one piece of real code here: `core/poster.zig` decodes cover
/// art on a worker thread through `dvui.c.stbi_load_from_memory`, and posters
/// are served over HTTP (`/poster`), so headless genuinely needs the decoder.
/// build.zig compiles dvui's own vendored `stb_image_impl.c` for this — same
/// source as the desktop build, so there's no behavior drift between the two.
pub const c = @cImport({
    @cInclude("stb_image.h");
});

/// `state.dvui_win: ?*dvui.Window` — only ever passed back to `refresh`, which
/// is a no-op here, so the pointee is never dereferenced.
pub const Window = opaque {};

/// Set by the desktop frame loop; `comics.zig` checks it before deferring a GPU
/// destroy. Always null headless, which is the correct answer: no window, no
/// textures to reclaim.
pub var current_window: ?*Window = null;

pub const Id = enum(u64) { zero = 0, _ };

pub const Color = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    /// Premultiplied-alpha pixel. `player.zig` allocates video frame buffers as
    /// `[]Color.PMA` and `poster.zig` reinterprets decoded RGBA as it, so the
    /// LAYOUT here has to match dvui's for real (4 bytes, extern) even though
    /// nothing headless ever uploads one.
    pub const PMA = extern struct {
        r: u8 = 0,
        g: u8 = 0,
        b: u8 = 0,
        a: u8 = 0,

        pub const black: PMA = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    };
};

pub const TextureInterpolation = enum { nearest, linear };

pub const TexturePixelFormat = enum {
    rgba_32,
    argb_32,
    bgra_32,
    abgr_32,
};

pub const TextureError = error{ TextureCreate, TextureRead, TextureUpdate, NotImplemented, OutOfMemory };

/// A texture handle that is never backed by anything. `textureCreate` fails, so
/// every `?Texture` field in the headless graph stays null and `update` /
/// `destroyLater` are unreachable in practice — they exist to type-check.
pub const Texture = struct {
    ptr: *anyopaque,
    width: u32,
    height: u32,

    pub fn update(tex: *Texture, pma: []const Color.PMA, interpolation: TextureInterpolation) TextureError!void {
        _ = tex;
        _ = pma;
        _ = interpolation;
    }

    pub fn destroyLater(texture: Texture) void {
        _ = texture;
    }
};

/// Always fails: there is no GPU. Callers already treat this as fallible
/// (`textureCreate(...) catch null`) because it fails on the desktop too when a
/// frame allocation is refused — so the null-texture path is exercised code,
/// not a headless-only branch.
pub fn textureCreate(
    pixels: []const Color.PMA,
    width: u32,
    height: u32,
    interpolation: TextureInterpolation,
    format: TexturePixelFormat,
) TextureError!Texture {
    _ = pixels;
    _ = width;
    _ = height;
    _ = interpolation;
    _ = format;
    return error.NotImplemented;
}

pub const textureDestroyLater = Texture.destroyLater;

/// Worker threads call this to wake the UI after mutating shared state. No UI,
/// nothing to wake.
pub fn refresh(win: ?*Window, src: std.builtin.SourceLocation, id: ?Id) void {
    _ = win;
    _ = src;
    _ = id;
}

/// `main.zig` installs `pub const panic = dvui.App.panic` and
/// `std_options.logFn = dvui.App.logFn`. dvui's versions forward to the SDL
/// backend (message box on panic, SDL_Log for logs); headless wants plain std
/// behavior, which is exactly what dvui falls back to when a backend declares
/// neither.
pub const App = struct {
    pub const panic = std.debug.FullPanic(std.debug.defaultPanic);
    pub const logFn: @FieldType(std.Options, "logFn") = std.log.defaultLog;
};
