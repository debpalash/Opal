const std = @import("std");

/// mpv exposes `hwdec-current=no` only after a video decoder exists. Notify
/// once per load when the viewer asked for hardware decoding but mpv selected
/// software; unavailable/early property states are not failures.
pub fn shouldNotify(enabled: bool, current: ?[]const u8, width: i64, height: i64, already_notified: bool) bool {
    if (!enabled or already_notified or width <= 0 or height <= 0) return false;
    const value = current orelse return false;
    return std.mem.eql(u8, value, "no");
}

/// mpv `hwdec` value. Android always decodes in software. Opal renders through
/// libmpv's render API, which has no surface, so direct `mediacodec` (auto's
/// pick) cannot output frames, and `mediacodec-copy` can block forever inside
/// MediaCodec.dequeueOutputBuffer on mpv's core thread. The UI thread then
/// waits on mpv's core lock, the app stops responding and Android kills it:
/// issue #229 ("opening any file quits the app", Android 16), reproduced on an
/// API 36 emulator, where software decoding played the same file. `at_init`
/// keeps desktop's start-up `auto-safe` vs the settings toggle's `auto`.
pub fn optionValue(enabled: bool, android: bool, at_init: bool) [:0]const u8 {
    if (android or !enabled) return "no";
    return if (at_init) "auto-safe" else "auto";
}

test "Android decodes in software: mediacodec-copy hung the player (#229)" {
    try std.testing.expectEqualStrings("no", optionValue(true, true, true));
    try std.testing.expectEqualStrings("no", optionValue(true, true, false));
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
