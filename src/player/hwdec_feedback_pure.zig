const std = @import("std");

/// mpv exposes `hwdec-current=no` only after a video decoder exists. Notify
/// once per load when the viewer asked for hardware decoding but mpv selected
/// software; unavailable/early property states are not failures.
pub fn shouldNotify(enabled: bool, current: ?[]const u8, width: i64, height: i64, already_notified: bool) bool {
    if (!enabled or already_notified or width <= 0 or height <= 0) return false;
    const value = current orelse return false;
    return std.mem.eql(u8, value, "no");
}

/// mpv `hwdec` value. Opal renders through libmpv's render API, so on Android
/// direct `mediacodec` (auto's pick) fails with "Both surface and native_window
/// are NULL" and nothing plays; `mediacodec-copy` decodes in hardware and copies
/// frames back. `at_init` keeps desktop's start-up `auto-safe` vs the settings
/// toggle's `auto` exactly as before.
pub fn optionValue(enabled: bool, android: bool, at_init: bool) [:0]const u8 {
    if (!enabled) return "no";
    if (android) return "mediacodec-copy";
    return if (at_init) "auto-safe" else "auto";
}

test "Android hwdec uses mediacodec-copy (render API has no surface)" {
    try std.testing.expectEqualStrings("mediacodec-copy", optionValue(true, true, true));
    try std.testing.expectEqualStrings("mediacodec-copy", optionValue(true, true, false));
    try std.testing.expectEqualStrings("no", optionValue(false, true, true));
    try std.testing.expectEqualStrings("auto-safe", optionValue(true, false, true));
    try std.testing.expectEqualStrings("auto", optionValue(true, false, false));
    try std.testing.expectEqualStrings("no", optionValue(false, false, false));
}

test "hardware fallback waits for a real video and reports once" {
    try std.testing.expect(!shouldNotify(true, null, 1920, 1080, false));
    try std.testing.expect(!shouldNotify(true, "no", 0, 0, false));
    try std.testing.expect(!shouldNotify(false, "no", 1920, 1080, false));
    try std.testing.expect(!shouldNotify(true, "d3d11va-copy", 1920, 1080, false));
    try std.testing.expect(shouldNotify(true, "no", 1920, 1080, false));
    try std.testing.expect(!shouldNotify(true, "no", 1920, 1080, true));
}
