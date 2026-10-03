//! SDL2 on macOS converts pending process signals while pumping events.
const std = @import("std");

pub fn nativeSignalPumpMicros(os: std.Target.Os.Tag) ?i32 {
    // Cocoa can otherwise wait indefinitely on an idle, media-free window.
    return if (os == .macos) 1_000_000 else null;
}

test "macOS idle event pump remains bounded without changing other platforms" {
    try std.testing.expectEqual(@as(?i32, 1_000_000), nativeSignalPumpMicros(.macos));
    try std.testing.expect(nativeSignalPumpMicros(.linux) == null);
    try std.testing.expect(nativeSignalPumpMicros(.windows) == null);
}
