const std = @import("std");

/// mpv exposes `hwdec-current=no` only after a video decoder exists. Notify
/// once per load when the viewer asked for hardware decoding but mpv selected
/// software; unavailable/early property states are not failures.
pub fn shouldNotify(enabled: bool, current: ?[]const u8, width: i64, height: i64, already_notified: bool) bool {
    if (!enabled or already_notified or width <= 0 or height <= 0) return false;
    const value = current orelse return false;
    return std.mem.eql(u8, value, "no");
}

test "hardware fallback waits for a real video and reports once" {
    try std.testing.expect(!shouldNotify(true, null, 1920, 1080, false));
    try std.testing.expect(!shouldNotify(true, "no", 0, 0, false));
    try std.testing.expect(!shouldNotify(false, "no", 1920, 1080, false));
    try std.testing.expect(!shouldNotify(true, "d3d11va-copy", 1920, 1080, false));
    try std.testing.expect(shouldNotify(true, "no", 1920, 1080, false));
    try std.testing.expect(!shouldNotify(true, "no", 1920, 1080, true));
}
