//! Pure (io-free, dvui-free) decision for auto-hiding the window chrome (header /
//! tab bar / bottom status tray) during video playback, so an idle viewer gets
//! the full window for the video. main.zig routes the live state through this so
//! the tested logic IS the shipped logic. Mouse motion resets the idle clock in
//! the caller (state.last_mouse_move_ms), which reveals the chrome again.

const std = @import("std");

/// Single source of truth for the chrome idle clock. Previously the 2500ms
/// threshold was hand-copied into shell.zig, main.zig (twice) and footer.zig —
/// changing the timing required four synchronized edits or the chrome layers
/// (top nav / control bar / repaint gate) desynchronized.
pub const DEFAULT_THRESHOLD_MS: i64 = 2500;
/// Duration of the chrome fade-out that starts once the threshold is crossed.
pub const FADE_MS: i64 = 220;

pub const Inputs = struct {
    /// Active player has a video texture AND is currently playing (not paused).
    playing_video: bool,
    /// The omnibox/search input holds text — keep chrome so it can't vanish
    /// mid-type (keyboard activity doesn't bump the mouse-idle clock).
    typing: bool,
    /// Milliseconds since the last mouse motion (now - last_mouse_move_ms).
    idle_ms: i64,
    /// Idle threshold before hiding (matches the control-bar auto-hide).
    threshold_ms: i64,
};

/// True when the chrome should be hidden this frame.
pub fn shouldHideChrome(in: Inputs) bool {
    if (!in.playing_video) return false; // only immerse while actually watching
    if (in.typing) return false; // never yank the input out from under the user
    return in.idle_ms >= in.threshold_ms;
}

test "hides only while playing video and idle past the threshold" {
    const base = Inputs{ .playing_video = true, .typing = false, .idle_ms = 3000, .threshold_ms = 2500 };
    try std.testing.expect(shouldHideChrome(base));

    // Not playing (paused / audio-only / browsing) → always show chrome.
    try std.testing.expect(!shouldHideChrome(.{ .playing_video = false, .typing = false, .idle_ms = 9999, .threshold_ms = 2500 }));

    // Idle clock hasn't crossed the threshold yet.
    try std.testing.expect(!shouldHideChrome(.{ .playing_video = true, .typing = false, .idle_ms = 2499, .threshold_ms = 2500 }));

    // Exactly at the threshold hides.
    try std.testing.expect(shouldHideChrome(.{ .playing_video = true, .typing = false, .idle_ms = 2500, .threshold_ms = 2500 }));

    // Typing in the omnibox keeps the chrome regardless of idle time.
    try std.testing.expect(!shouldHideChrome(.{ .playing_video = true, .typing = true, .idle_ms = 9999, .threshold_ms = 2500 }));
}

test "chrome idle constants are sane (fade fits inside the idle window)" {
    try std.testing.expect(DEFAULT_THRESHOLD_MS > 0);
    try std.testing.expect(FADE_MS > 0 and FADE_MS < DEFAULT_THRESHOLD_MS);
}
