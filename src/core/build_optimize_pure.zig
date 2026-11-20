//! Optimize mode for heavy UI dependencies (dvui and the SDL it builds).
//! Imported by build.zig; pure so the policy has a unit test.

const std = @import("std");

/// Debug app builds compile dvui safe mode: optimized enough that a video
/// frame's full UI pass fits its budget, while keeping safety checks so dev
/// builds still trap dvui misuse. `debug_deps` restores a fully Debug dvui.
/// Release builds pass through unchanged.
pub fn dependencyOptimize(app: std.lang.Optimize, debug_deps: bool) std.lang.Optimize {
    if (app == .debug and !debug_deps) return .safe;
    return app;
}

test "Debug playback regression: dvui is optimized in Debug app builds unless asked" {
    try std.testing.expectEqual(std.lang.Optimize.safe, dependencyOptimize(.debug, false));
    try std.testing.expectEqual(std.lang.Optimize.debug, dependencyOptimize(.debug, true));
    try std.testing.expectEqual(std.lang.Optimize.fast, dependencyOptimize(.fast, false));
    try std.testing.expectEqual(std.lang.Optimize.safe, dependencyOptimize(.safe, true));
}
