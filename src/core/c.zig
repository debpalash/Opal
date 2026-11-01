pub const mpv = @import("opal-native-c");

pub const sdl = @import("opal-native-c");

pub const sqlite = @import("opal-native-c");

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
