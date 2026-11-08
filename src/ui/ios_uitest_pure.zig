//! Step verdict for the iOS UI walk (ios_uitest.zig): a ready step still waits
//! a short settle time so the screenshot shows the rendered page.
const std = @import("std");
pub const Verdict = enum { wait, pass, fail };
pub fn decide(ready: bool, elapsed_ms: i64, timeout_ms: i64, settle_ms: i64) Verdict {
    if (elapsed_ms < settle_ms) return .wait;
    if (ready) return .pass;
    return if (elapsed_ms >= timeout_ms + settle_ms) .fail else .wait;
}
test "ui walk waits to settle, passes when ready, fails only after its timeout" {
    try std.testing.expectEqual(Verdict.wait, decide(true, 100, 1000, 1500));
    try std.testing.expectEqual(Verdict.pass, decide(true, 1500, 1000, 1500));
    try std.testing.expectEqual(Verdict.wait, decide(false, 2000, 1000, 1500));
    try std.testing.expectEqual(Verdict.fail, decide(false, 2500, 1000, 1500));
}
