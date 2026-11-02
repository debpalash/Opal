//! Desktop selection and safe argv construction, independent of the host OS.
const std = @import("std");
pub const Backend = enum { mac, windows, gnome, cinnamon, mate, kde, xfce, x11, wayland, unsupported };
pub fn linuxBackend(desktop: []const u8, session: []const u8, animated: bool) Backend {
    var lower: [256]u8 = undefined;
    const text = std.ascii.lowerString(&lower, desktop[0..@min(desktop.len, lower.len)]);
    const wayland = std.ascii.eqlIgnoreCase(session, "wayland");
    if (animated) {
        if (!wayland) return .x11;
        for ([_][]const u8{ "sway", "hyprland", "river", "wayfire", "niri", "labwc" }) |name| if (std.mem.indexOf(u8, text, name) != null) return .wayland;
        return .unsupported;
    }
    for ([_]struct { name: []const u8, backend: Backend }{
        .{ .name = "cinnamon", .backend = .cinnamon }, .{ .name = "mate", .backend = .mate },
        .{ .name = "gnome", .backend = .gnome },       .{ .name = "unity", .backend = .gnome },
        .{ .name = "kde", .backend = .kde },           .{ .name = "plasma", .backend = .kde },
        .{ .name = "xfce", .backend = .xfce },
    }) |entry| if (std.mem.indexOf(u8, text, entry.name) != null) return entry.backend;
    return if (wayland) linuxBackend(desktop, session, true) else .x11;
}
pub fn fileUri(path: []const u8, out: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "/") or out.len < 7) return null;
    @memcpy(out[0..7], "file://");
    var n: usize = 7;
    for (path) |ch| {
        if (ch == '/') {
            if (n == out.len) return null;
            out[n] = ch;
            n += 1;
        } else {
            const encoded = @import("url_encode_pure.zig").encode(&.{ch}, out[n..], .component);
            if (!encoded.complete) return null;
            n += encoded.bytes.len;
        }
    }
    return out[0..n];
}
pub fn animatedArgs(backend: Backend, bin: []const u8, host: ?[]const u8, path: []const u8, fill: bool, out: *[32][]const u8) ?[]const []const u8 {
    var n: usize = 0;
    // A managed desktop window is needed on X11: its root window can be
    // covered by GNOME/KDE/XFCE's desktop surface. xwinwrap owns a window
    // with desktop type, no input/focus/taskbar, and substitutes literal WID.
    if (backend == .x11) {
        out[n] = host orelse return null;
        n += 1;
        for ([_][]const u8{ "-fs", "-fdt", "-ni", "-b", "-nf", "-un", "-s", "-st", "-sp", "--" }) |arg| {
            out[n] = arg;
            n += 1;
        }
    }
    out[n] = bin;
    n += 1;
    if (backend == .wayland) {
        out[n] = "-o";
        out[n + 1] = if (fill) "no-config no-audio loop-file=inf panscan=1 stop-screensaver=no" else "no-config no-audio loop-file=inf panscan=0 stop-screensaver=no";
        out[n + 2] = "ALL";
        out[n + 3] = path;
        return out[0 .. n + 4];
    }
    if (backend != .mac and backend != .windows and backend != .x11) return null;
    for ([_][]const u8{ "--no-config", "--load-scripts=no", "--no-audio", "--loop-file=inf", "--no-border", "--no-osc", "--input-default-bindings=no", "--input-vo-keyboard=no", "--input-cursor-passthrough=yes", "--stop-screensaver=no", "--really-quiet", if (fill) "--panscan=1" else "--panscan=0" }) |arg| {
        out[n] = arg;
        n += 1;
    }
    if (backend == .mac) {
        for ([_][]const u8{ "--ontop", "--ontop-level=desktop", "--focus-on=never", "--on-all-workspaces", "--macos-app-activation-policy=accessory", "--macos-geometry-calculation=whole", "--geometry=100%x100%+0+0" }) |arg| {
            out[n] = arg;
            n += 1;
        }
    } else if (backend == .windows) {
        // mpv's documented Win32 zero handle targets the desktop WorkerW
        // behind icons; it is not the X11 root-window implementation.
        out[n] = "--wid=0";
        n += 1;
    } else {
        out[n] = "--wid";
        out[n + 1] = "WID";
        n += 2;
    }
    out[n] = "--";
    out[n + 1] = path;
    return out[0 .. n + 2];
}
pub const mac_script =
    \\ObjC.import('AppKit');
    \\function run(a) { var u=$.NSURL.fileURLWithPath(a[0]); var s=$.NSScreen.screens; if(s.count===0) throw Error('No displays');
    \\var options=$.NSMutableDictionary.alloc.init; options.setObjectForKey($(a[1]==='fill'), $.NSWorkspaceDesktopImageAllowClippingKey);
    \\options.setObjectForKey($(3), $.NSWorkspaceDesktopImageScalingKey);
    \\for(var i=0;i<s.count;i++){var e=Ref(); if(!$.NSWorkspace.sharedWorkspace.setDesktopImageURLForScreenOptionsError(u,s.objectAtIndex(i),options,e)) throw Error('Wallpaper rejected');} }
;
pub const windows_script =
    \\param([string]$WallpaperPath,[string]$Placement)
    \\$ErrorActionPreference='Stop'
    \\Add-Type 'using System; using System.Runtime.InteropServices; public class OpalWallpaper { [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SystemParametersInfo(uint a,uint b,string p,uint f); }'
    \\Set-ItemProperty 'HKCU:\Control Panel\Desktop' WallpaperStyle $(if($Placement -eq 'fill'){'10'}else{'6'})
    \\Set-ItemProperty 'HKCU:\Control Panel\Desktop' TileWallpaper '0'
    \\if(-not [OpalWallpaper]::SystemParametersInfo(20,0,$WallpaperPath,3)){throw 'Windows rejected wallpaper'}
;
test "desktop routing does not claim GNOME or KDE Wayland animation support" {
    try std.testing.expectEqual(Backend.gnome, linuxBackend("ubuntu:GNOME", "wayland", false));
    try std.testing.expectEqual(Backend.unsupported, linuxBackend("GNOME", "wayland", true));
    try std.testing.expectEqual(Backend.unsupported, linuxBackend("KDE", "wayland", true));
    try std.testing.expectEqual(Backend.wayland, linuxBackend("Hyprland", "wayland", true));
    try std.testing.expectEqual(Backend.x11, linuxBackend("XFCE", "x11", true));
}
test "animated file paths remain single literal arguments on every backend" {
    const path = "C:/Pictures/a 'quote'; $(touch nope).mp4";
    var args: [32][]const u8 = undefined;
    for ([_]Backend{ .mac, .windows, .x11, .wayland }) |backend| {
        const argv = animatedArgs(backend, "mpv", "xwinwrap", path, true, &args).?;
        try std.testing.expectEqualStrings(path, argv[argv.len - 1]);
        try std.testing.expect(argv.len <= args.len);
        if (backend != .wayland) {
            var passthrough = false;
            for (argv) |arg| if (std.mem.eql(u8, arg, "--input-cursor-passthrough=yes")) {
                passthrough = true;
            };
            try std.testing.expect(passthrough);
        }
    }
    var out: [200]u8 = undefined;
    try std.testing.expectEqualStrings("file:///a%20b/%23%E6%97%A5.png", fileUri("/a b/#日.png", &out).?);
}

test "live wallpaper targets desktop surfaces rather than normal player windows" {
    var args: [32][]const u8 = undefined;
    const win = animatedArgs(.windows, "mpv.exe", null, "movie.mp4", true, &args).?;
    var desktop = false;
    for (win) |arg| if (std.mem.eql(u8, arg, "--wid=0")) {
        desktop = true;
    };
    try std.testing.expect(desktop);
    try std.testing.expect(animatedArgs(.x11, "mpv", null, "/movie.mp4", true, &args) == null);
    const x11 = animatedArgs(.x11, "mpv", "/usr/bin/xwinwrap", "/movie.mp4", false, &args).?;
    try std.testing.expectEqualStrings("/usr/bin/xwinwrap", x11[0]);
    var child_handle = false;
    for (x11, 0..) |arg, i| if (std.mem.eql(u8, arg, "--wid")) {
        try std.testing.expectEqualStrings("WID", x11[i + 1]);
        child_handle = true;
    };
    try std.testing.expect(child_handle);
    try std.testing.expect(animatedArgs(.gnome, "mpv", null, "/movie.mp4", true, &args) == null);
}
