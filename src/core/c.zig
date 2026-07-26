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

const std = @import("std");

/// `sub-add <path>` via mpv's ARGV form — never the string form.
///
/// mpv_command_string parses its argument, and inside a quoted token a
/// backslash starts an escape. A Windows path therefore fails to load:
///
///     sub-add "C:\Users\me\AppData\Local\opal\cache\subs\current.srt"
///     → Broken string escapes / Command sub-add: error in argument 1
///
/// mpv_command takes a pre-split argv and does no unescaping at all, so any
/// path survives verbatim on every platform. Fixes subtitles never loading on
/// Windows (issue #21).
///
/// `path` may be a local path or a URL. Returns false if it does not fit the
/// caller-independent bound below, or if mpv rejected the command.
pub fn mpvSubAdd(ctx: ?*mpv.mpv_handle, path: []const u8) bool {
    var path_z: [2048]u8 = undefined;
    if (path.len >= path_z.len) return false;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    var argv = [_][*c]const u8{ "sub-add", &path_z, null };
    return mpv.mpv_command(ctx, @ptrCast(&argv)) >= 0;
}
