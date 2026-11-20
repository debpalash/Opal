//! GPU video policy — pure, tested. Decides whether Opal renders video with
//! libmpv's OpenGL render API (GPU scaling, HDR tone mapping, no per-frame
//! CPU colour conversion or texture upload) or keeps the software render path,
//! and owns the triple-buffer slot rotation between the render worker and the
//! UI thread.
//!
//! Measured on an M2 (2026-11-20): 4K60 HEVC 10-bit into a 1080p pane dropped
//! 39 frames in 6 s on the software path; the GPU path played 60.1 fps with 0
//! drops, and rendered full 4K output at 59.6 fps.

const std = @import("std");

/// Whether to ask SDL for its OpenGL renderer so the GPU path can attach.
/// `OPAL_VIDEO_RENDER` overrides: `gpu`/`1` forces it, `sw`/`software`/`0`
/// keeps the software path. Default: on for macOS (verified) and Linux (SDL
/// already picks OpenGL there); off for Windows, where it would move the whole
/// UI from Direct3D to OpenGL and has not been verified on hardware.
pub fn requested(os: std.Target.Os.Tag, env: ?[]const u8) bool {
    if (env) |raw| {
        const v = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(v, "gpu") or std.mem.eql(u8, v, "1")) return true;
        if (std.ascii.eqlIgnoreCase(v, "sw") or std.ascii.eqlIgnoreCase(v, "software") or std.mem.eql(u8, v, "0")) return false;
    }
    return os == .macos or os == .linux;
}

/// The GPU path renders into textures the SDL renderer owns, so it only works
/// when SDL actually created its desktop OpenGL renderer (Wayland GLES or a
/// software fallback keep the software path).
pub fn rendererSupportsGpu(renderer_name: []const u8) bool {
    return std.mem.eql(u8, renderer_name, "opengl");
}

/// Triple buffer over three texture slots. The worker renders into `back`,
/// then `publish` swaps it with `ready`; the UI's `take` swaps `ready` with
/// `displayed`. No slot is ever written while the UI may be sampling it, and
/// a worker that outpaces the UI simply replaces the not-yet-shown frame.
pub const Slots = struct {
    back: u2 = 0,
    ready: u2 = 1,
    displayed: u2 = 2,
    fresh: bool = false,

    /// Worker: the frame in `back` is complete.
    pub fn publish(self: *Slots) void {
        std.mem.swap(u2, &self.back, &self.ready);
        self.fresh = true;
    }

    /// UI: adopt the newest published frame; null when nothing new.
    pub fn take(self: *Slots) ?u2 {
        if (!self.fresh) return null;
        std.mem.swap(u2, &self.ready, &self.displayed);
        self.fresh = false;
        return self.displayed;
    }
};

test "GPU video is requested by default on macOS and Linux, overridable" {
    try std.testing.expect(requested(.macos, null));
    try std.testing.expect(requested(.linux, null));
    try std.testing.expect(!requested(.windows, null));
    try std.testing.expect(requested(.windows, "gpu"));
    try std.testing.expect(!requested(.macos, "sw"));
    try std.testing.expect(!requested(.macos, " Software\n"));
    try std.testing.expect(!requested(.linux, "0"));
    try std.testing.expect(requested(.macos, "unknown"));
}

test "only SDL's desktop OpenGL renderer hosts the GPU path" {
    try std.testing.expect(rendererSupportsGpu("opengl"));
    try std.testing.expect(!rendererSupportsGpu("metal"));
    try std.testing.expect(!rendererSupportsGpu("opengles2"));
    try std.testing.expect(!rendererSupportsGpu("direct3d"));
}

test "triple buffer never hands the worker the slot the UI is showing" {
    var s: Slots = .{};
    try std.testing.expect(s.take() == null);
    s.publish();
    const shown = s.take().?;
    try std.testing.expect(shown != s.back and shown != s.ready);
    // Worker outpaces the UI: two publishes, one take shows the newest.
    s.publish();
    const newest_slot = s.ready;
    s.publish();
    try std.testing.expect(s.back == newest_slot); // stale frame slot reused
    const next = s.take().?;
    try std.testing.expect(next != shown);
    try std.testing.expect(next != s.back);
    // All three slots stay distinct through any sequence.
    for (0..20) |i| {
        if (i % 3 == 0) _ = s.take() else s.publish();
        try std.testing.expect(s.back != s.ready and s.ready != s.displayed and s.back != s.displayed);
    }
}
