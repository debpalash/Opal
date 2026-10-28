const std = @import("std");
pub fn validRange(start: f64, end: f64, duration: f64) bool {
    return std.math.isFinite(start) and std.math.isFinite(end) and std.math.isFinite(duration) and
        start >= 0 and end > start and end - start <= 120 and duration > 0 and end <= duration;
}
test "shared clips reject unbounded nonfinite reversed and out-of-media ranges" {
    try std.testing.expect(validRange(10, 20, 100));
    try std.testing.expect(!validRange(0, 121, 200));
    try std.testing.expect(!validRange(20, 10, 100));
    try std.testing.expect(!validRange(90, 110, 100));
    try std.testing.expect(!validRange(std.math.nan(f64), 10, 100));
}
