//! Native UI font — draw Opal's chrome in the face the OS already ships.
//!
//! dvui's built-in default is Bitstream Vera Sans (1996), hinted for 96dpi X11.
//! Against Opal's compact ramp that lands body text at roughly 10 physical
//! pixels, a size where Vera's stems fall between the pixel grid and the whole
//! UI reads soft. Every desktop app that looks native — VS Code included —
//! renders its chrome in the system interface font, so that is what this does:
//! read the platform face off disk at startup and hand it to dvui.
//!
//! Loaded from the user's own installed fonts, never bundled. Segoe UI and SF
//! are not redistributable, and there is nothing to redistribute when the file
//! is already on the machine. Nothing here is load-bearing: if no candidate
//! opens, every accessor returns its argument unchanged and dvui keeps Vera.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const io = @import("../core/io_global.zig");

/// dvui indexes its font database by family name; these are ours. The bold
/// face gets a family of its own rather than riding `.weight = .bold` because
/// `dvui.addFont` registers every source as weight-normal — asking for a bold
/// variant that was never registered sends findSource down its "second best"
/// path, which logs an error for every heading drawn, every frame.
const family_ui = "Opal UI";
const family_ui_bold = "Opal UI Semibold";
const family_mono = "Opal Mono";

/// A system UI font is a few hundred KB; a variable font with a large CJK
/// range can be far bigger. Generous, but bounded — this reads a path that
/// resolves through an environment variable.
const MAX_TTF_BYTES = 32 * 1024 * 1024;

var tried = false;
var have_ui = false;
var have_bold = false;
var have_mono = false;

fn tryLoad(gpa: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const f = io.openFileAbsolute(path, .{}) catch return null;
    defer io.closeFile(f);
    return io.readToEndAlloc(f, gpa, MAX_TTF_BYTES) catch null;
}

/// First candidate that both opens and parses wins. `addFont` takes ownership
/// of the bytes via the allocator argument, so the only leak to guard is the
/// failure path — it validates the face and can reject the file after we have
/// already read it.
fn register(gpa: std.mem.Allocator, family: []const u8, candidates: []const []const u8) bool {
    for (candidates) |path| {
        const bytes = tryLoad(gpa, path) orelse continue;
        dvui.addFont(family, bytes, gpa) catch {
            gpa.free(bytes);
            continue;
        };
        return true;
    }
    return false;
}

/// Idempotent, and deliberately one-shot: a machine missing Segoe UI will not
/// grow it between frames, and retrying would re-read and re-parse the miss on
/// every theme change.
pub fn install() void {
    if (tried) return;
    tried = true;
    const gpa = @import("../core/alloc.zig").allocator;

    switch (builtin.os.tag) {
        .windows => {
            // %SystemRoot% rather than a hardcoded C:\Windows — Windows is not
            // always on C:, and a wrong path here would silently fall back to
            // Vera with no way to tell why.
            const root = io.getenv("SystemRoot") orelse "C:\\Windows";
            var buf: [3][std.fs.max_path_bytes]u8 = undefined;
            const ui_path = std.fmt.bufPrint(&buf[0], "{s}\\Fonts\\segoeui.ttf", .{root}) catch return;
            // Semibold, not Bold: it is the weight Windows 11 and VS Code use
            // for headings, and Segoe Bold is heavy enough to look shouty in a
            // dense UI.
            const sb_path = std.fmt.bufPrint(&buf[1], "{s}\\Fonts\\seguisb.ttf", .{root}) catch return;
            const mono_path = std.fmt.bufPrint(&buf[2], "{s}\\Fonts\\consola.ttf", .{root}) catch return;
            have_ui = register(gpa, family_ui, &.{ui_path});
            have_bold = register(gpa, family_ui_bold, &.{sb_path});
            have_mono = register(gpa, family_mono, &.{mono_path});
        },
        .macos => {
            have_ui = register(gpa, family_ui, &.{
                "/System/Library/Fonts/SFNS.ttf",
                "/System/Library/Fonts/SFNSText.ttf",
                "/System/Library/Fonts/Helvetica.ttc",
            });
            // No separate semibold file ships on modern macOS — SFNS.ttf is a
            // variable font and dvui loads its default instance. Headings fall
            // back to the regular family at a larger size, which is the
            // hierarchy the type ramp already carries.
            have_mono = register(gpa, family_mono, &.{
                "/System/Library/Fonts/SFNSMono.ttf",
                "/System/Library/Fonts/Menlo.ttc",
            });
        },
        else => {
            have_ui = register(gpa, family_ui, &.{
                "/usr/share/fonts/cantarell/Cantarell-VF.otf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                "/usr/share/fonts/TTF/DejaVuSans.ttf",
                "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
                "/usr/share/fonts/noto/NotoSans-Regular.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
            });
            have_bold = register(gpa, family_ui_bold, &.{
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
                "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
                "/usr/share/fonts/noto/NotoSans-Bold.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
            });
            have_mono = register(gpa, family_mono, &.{
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
            });
        },
    }

    // Worth a line: a silent fallback to Vera looks like "the font change did
    // nothing" and is otherwise indistinguishable from it.
    std.debug.print("[font] system UI face: ui={} semibold={} mono={}\n", .{ have_ui, have_bold, have_mono });
}

/// Move `f` onto the native UI family, preserving size and line height. A
/// no-op when nothing was found, so call sites need no branch of their own.
pub fn ui(f: dvui.Font) dvui.Font {
    return if (have_ui) f.withFamily(family_ui).withWeight(.normal) else f;
}

/// Semibold where the platform has one, regular otherwise — never a weight
/// that was not registered.
pub fn uiBold(f: dvui.Font) dvui.Font {
    if (have_bold) return f.withFamily(family_ui_bold).withWeight(.normal);
    return ui(f);
}

pub fn mono(f: dvui.Font) dvui.Font {
    return if (have_mono) f.withFamily(family_mono).withWeight(.normal) else f;
}
