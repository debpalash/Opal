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

/// OPAL_UITEST_ONLY="tv_play,movie_torrent" runs just those steps (plus the
/// onboarding step that installs the sources everything else needs).
pub fn selected(name: []const u8, only: []const u8) bool {
    if (only.len == 0 or std.mem.eql(u8, name, "onboarding")) return true;
    var it = std.mem.tokenizeScalar(u8, only, ',');
    while (it.next()) |want| {
        if (std.mem.eql(u8, std.mem.trim(u8, want, " "), name)) return true;
    }
    return false;
}

test "walk step filter keeps onboarding and the named steps only" {
    try std.testing.expect(selected("tv_play", ""));
    try std.testing.expect(selected("onboarding", "tv_play"));
    try std.testing.expect(selected("tv_play", "vq_play, tv_play"));
    try std.testing.expect(!selected("comics", "vq_play,tv_play"));
    try std.testing.expect(!selected("tv", "tv_play"));
}
