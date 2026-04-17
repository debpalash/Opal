pub const mpv = @cImport({
    @cInclude("mpv/client.h");
    @cInclude("mpv/render_gl.h");
    @cInclude("torrent_wrapper.h");
});

pub const sdl = @cImport({
    // Zig 0.16 bundled arm_vector_types.h uses __mfp8 builtin that
    // translate-c can't resolve. SDL2 headers gate arm_neon.h include
    // on this macro, so defining it makes translate-c succeed.
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
});

pub const sqlite = @cImport({
    @cInclude("sqlite3.h");
});
