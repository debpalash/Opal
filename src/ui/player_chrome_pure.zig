//! Who owns a pointer event over the player: the chrome (top bar, transport)
//! or the full-pane click catcher drawn beneath it. Pure so the rule is tested.
const std = @import("std");

/// The transport only owns its band while it is shown; the top bar always
/// owns its rect (its hit test already returns false when it is hidden).
pub fn ownsPointer(overlay_shown: bool, in_controls: bool, in_top_chrome: bool) bool {
    return in_top_chrome or (overlay_shown and in_controls);
}

test "regression: Back / transport taps are not swallowed by the pause-on-tap pane" {
    try std.testing.expect(ownsPointer(true, false, true)); // Back button
    try std.testing.expect(ownsPointer(false, false, true));
    try std.testing.expect(ownsPointer(true, true, false)); // transport visible
    try std.testing.expect(!ownsPointer(false, true, false)); // transport hidden: tap reaches the pane
    try std.testing.expect(!ownsPointer(true, false, false)); // plain artwork tap pauses
}
