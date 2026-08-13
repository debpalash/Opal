//! Physical panel geometry, for picking a sane default UI scale.
//!
//! Only Linux needs this. macOS reports a real content scale via
//! SDL_GetDisplayContentScale, and Windows reports one from its DPI settings —
//! on both, `scale_pure.deviceScale` trusts that number and never asks here.
//! Linux is the gap: on a Wayland or X11 session with no `Xft.dpi` set, dvui's
//! backend has nothing to read and reports exactly 1.0. That is a shrug, not a
//! measurement, so a dense laptop panel may need an upward Auto adjustment.
//! The user multiplier still has an unconditional 1.0× floor.
//!
//! The kernel already knows the answer. Every connected output exposes its
//! current mode and its EDID under /sys/class/drm, which is the same data
//! `xrandr` prints as "2560x1600 ... 340mm x 220mm".

const std = @import("std");
const io_global = @import("io_global.zig");
const scale_pure = @import("scale_pure.zig");

const builtin = @import("builtin");
const is_linux = builtin.os.tag == .linux;

const DRM_ROOT = "/sys/class/drm";

/// The single runtime seam for Opal's automatic scale. Keeping the platform
/// probe here means startup and Settings cannot drift into different defaults.
/// Manual scales never call this function; ui_scale_auto remains their gate.
pub fn defaultScale(natural_scale: f32) f32 {
    return scale_pure.deviceScale(natural_scale, probe() orelse .{});
}

/// Best-effort panel geometry for the display Opal is most likely on, or null
/// when nothing can be determined (non-Linux, no sysfs, headless, odd driver).
/// Never returns an error: a missing display probe degrades to the neutral
/// 1.0× baseline rather than failing startup.
pub fn probe() ?scale_pure.Display {
    if (!is_linux) return null;

    var dir = io_global.openDirAbsolute(DRM_ROOT, .{ .iterate = true }) catch return null;
    defer dir.close(io_global.io());

    // Prefer the built-in panel. A laptop with an external monitor attached
    // reports both, and the internal one is where a laptop's window opens by
    // default — and is the one whose DPI is unusual enough to matter.
    var best: ?scale_pure.Display = null;
    var best_is_internal = false;

    var it = dir.iterate();
    while (it.next(io_global.io()) catch null) |entry| {
        // Connector dirs look like "card2-eDP-2" / "card1-HDMI-A-1"; skip
        // "version", "renderD128", and the cardN device nodes themselves.
        if (std.mem.indexOfScalar(u8, entry.name, '-') == null) continue;

        if (!connectorIsConnected(entry.name)) continue;
        const geom = connectorGeometry(entry.name) orelse continue;

        // "eDP" (embedded DisplayPort) and "LVDS" are internal panels.
        const internal = std.mem.indexOf(u8, entry.name, "eDP") != null or
            std.mem.indexOf(u8, entry.name, "LVDS") != null;

        if (best == null or (internal and !best_is_internal)) {
            best = geom;
            best_is_internal = internal;
        }
    }
    return best;
}

fn connectorIsConnected(name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const bytes = readConnectorFile(name, "status", &buf) orelse return false;
    return std.mem.startsWith(u8, bytes, "connected");
}

fn connectorGeometry(name: []const u8) ?scale_pure.Display {
    var mode_buf: [256]u8 = undefined;
    const modes = readConnectorFile(name, "modes", &mode_buf) orelse return null;
    // First line is the preferred/current mode, e.g. "2560x1600".
    const first = modes[0 .. std.mem.indexOfScalar(u8, modes, '\n') orelse modes.len];
    const res = parseMode(first) orelse return null;

    var out = scale_pure.Display{ .px_w = res.w, .px_h = res.h };

    var edid_buf: [512]u8 = undefined;
    if (readConnectorFile(name, "edid", &edid_buf)) |edid| {
        if (edidSizeMm(edid)) |mm| {
            out.mm_w = mm.w;
            out.mm_h = mm.h;
        }
    }
    return out;
}

fn readConnectorFile(name: []const u8, leaf: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, DRM_ROOT ++ "/{s}/{s}", .{ name, leaf }) catch return null;
    const file = io_global.openFileAbsolute(path, .{}) catch return null;
    defer file.close(io_global.io());
    const n = file.readPositionalAll(io_global.io(), buf, 0) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

const Mode = struct { w: f32, h: f32 };

/// "2560x1600" → 2560x1600. Rejects anything else, including the empty string
/// sysfs returns for a connected-but-unconfigured output.
pub fn parseMode(line: []const u8) ?Mode {
    const x = std.mem.indexOfScalar(u8, line, 'x') orelse return null;
    const w = std.fmt.parseInt(u32, std.mem.trim(u8, line[0..x], " \t\r"), 10) catch return null;
    const h = std.fmt.parseInt(u32, std.mem.trim(u8, line[x + 1 ..], " \t\r"), 10) catch return null;
    if (w == 0 or h == 0) return null;
    return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

const SizeMm = struct { w: f32, h: f32 };

/// EDID 1.x basic display parameters: byte 21 is the max horizontal image size
/// and byte 22 the vertical, both in whole centimetres. Both read 0 for
/// projectors and for displays that decline to state a size — which is exactly
/// the case `physicalDpi` must reject rather than guess at.
pub fn edidSizeMm(edid: []const u8) ?SizeMm {
    if (edid.len < 23) return null;
    // Header check — 00 FF FF FF FF FF FF 00. Guards against a driver handing
    // back a truncated or all-zero blob.
    const magic = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    if (!std.mem.eql(u8, edid[0..8], &magic)) return null;

    const cm_w = edid[21];
    const cm_h = edid[22];
    if (cm_w == 0 or cm_h == 0) return null;
    return .{
        .w = @as(f32, @floatFromInt(cm_w)) * 10.0,
        .h = @as(f32, @floatFromInt(cm_h)) * 10.0,
    };
}

test "probe is analysed and never fails on any host" {
    // This exists to force semantic analysis of probe() and everything it
    // calls. The pure parsers below are the interesting logic, but testing only
    // them left probe() unreferenced — Zig never analysed it, and an invalid
    // error-set switch inside it passed `zig test` cleanly while breaking the
    // app build. Result is host-dependent (null off Linux, or on a machine with
    // no sysfs), so assert nothing about the value.
    _ = probe();
}

test "defaultScale is always usable without panel metadata" {
    const value = defaultScale(1.0);
    try std.testing.expect(value >= scale_pure.AUTO_MIN_SCALE);
    try std.testing.expect(value <= scale_pure.MAX_SCALE);
}

test "parseMode reads a sysfs modes line" {
    const m = parseMode("2560x1600").?;
    try std.testing.expectEqual(@as(f32, 2560), m.w);
    try std.testing.expectEqual(@as(f32, 1600), m.h);
    try std.testing.expect(parseMode("") == null);
    try std.testing.expect(parseMode("garbage") == null);
    try std.testing.expect(parseMode("0x0") == null);
}

test "edidSizeMm reads centimetres and rejects unusable blobs" {
    var edid = [_]u8{0} ** 128;
    const magic = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    @memcpy(edid[0..8], &magic);
    edid[21] = 34; // 34 cm wide
    edid[22] = 22; // 22 cm tall
    const mm = edidSizeMm(&edid).?;
    try std.testing.expectEqual(@as(f32, 340), mm.w);
    try std.testing.expectEqual(@as(f32, 220), mm.h);

    // A display that states no physical size.
    edid[21] = 0;
    try std.testing.expect(edidSizeMm(&edid) == null);

    // Not an EDID at all.
    var junk = [_]u8{0} ** 128;
    try std.testing.expect(edidSizeMm(&junk) == null);
    try std.testing.expect(edidSizeMm("short") == null);
}
