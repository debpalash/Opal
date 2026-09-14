//! One-shot pre-playback fallback state.
//!
//! FILE_LOADED only means the container was demuxed; decoder initialization
//! can still fail afterwards. A fallback remains armed until mpv reports
//! PLAYBACK_RESTART, then any later error belongs to established playback and
//! must be surfaced rather than silently switching versions mid-stream.

const std = @import("std");

pub const State = struct {
    armed: bool = false,

    pub fn reset(self: *State) void {
        self.armed = false;
    }

    pub fn arm(self: *State, available: bool) void {
        self.armed = available;
    }

    /// Demux success is deliberately not an input: the fallback remains armed.
    pub fn playbackStarted(self: *State) void {
        self.armed = false;
    }

    /// Returns true exactly once when an alternate should be attempted.
    pub fn takeOnFailure(self: *State) bool {
        if (!self.armed) return false;
        self.armed = false;
        return true;
    }
};

test "demux success cannot disarm a decoder fallback" {
    var state: State = .{};
    state.arm(true);
    // FILE_LOADED intentionally performs no transition.
    try std.testing.expect(state.takeOnFailure());
    try std.testing.expect(!state.takeOnFailure());
}

test "established playback disarms the alternate" {
    var state: State = .{};
    state.arm(true);
    state.playbackStarted();
    try std.testing.expect(!state.takeOnFailure());
}

test "a new load replaces stale fallback state" {
    var state: State = .{};
    state.arm(true);
    state.arm(false);
    try std.testing.expect(!state.takeOnFailure());
    state.arm(true);
    state.reset();
    try std.testing.expect(!state.takeOnFailure());
}
