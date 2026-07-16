//! Pure decision logic for the macOS Now Playing / media-key bridge.
//! media_remote.zig routes every polled remote command through these, so the
//! tested logic IS the shipped logic. Import-free of app modules so it runs
//! under `zig build test` standalone.

const std = @import("std");

/// Remote command codes — MUST stay in sync with the enum in
/// src/macos/media_remote.m (the ObjC handlers push these into the queue).
pub const Command = enum {
    none,
    play,
    pause,
    toggle,
    seek_absolute,
    seek_relative,
};

/// Decode the raw int polled from opal_media_remote_poll(). Unknown or
/// out-of-range codes (version-skewed .m, garbage) map to .none so a bad
/// code can never drive mpv.
pub fn decode(code: i32) Command {
    return switch (code) {
        1 => .play,
        2 => .pause,
        3 => .toggle,
        4 => .seek_absolute,
        5 => .seek_relative,
        else => .none,
    };
}

/// Clamp an absolute seek target (Control Center scrubber) into the media's
/// valid range. NaN → 0 (mpv would reject "seek nan"); negative → 0. When
/// duration is known (> 0), cap half a second short of the end so seeking to
/// the very end doesn't instantly hit EOF and close the file. duration <= 0
/// means unknown (live radio / stream) — only the lower bound applies.
pub fn clampSeekTarget(target: f64, duration: f64) f64 {
    if (std.math.isNan(target)) return 0;
    var t = @max(0.0, target);
    if (duration > 0) {
        const cap = @max(0.0, duration - 0.5);
        if (t > cap) t = cap;
    }
    return t;
}

/// Playback rate reported to MPNowPlayingInfoCenter. macOS advances the
/// Control Center elapsed time at this rate between our ~1s pushes, so it
/// must be exactly 0 while paused or the system card drifts.
pub fn playbackRate(paused: bool) f64 {
    return if (paused) 0.0 else 1.0;
}

test "decode maps known codes and rejects garbage" {
    try std.testing.expectEqual(Command.play, decode(1));
    try std.testing.expectEqual(Command.pause, decode(2));
    try std.testing.expectEqual(Command.toggle, decode(3));
    try std.testing.expectEqual(Command.seek_absolute, decode(4));
    try std.testing.expectEqual(Command.seek_relative, decode(5));
    try std.testing.expectEqual(Command.none, decode(0));
    try std.testing.expectEqual(Command.none, decode(-1));
    try std.testing.expectEqual(Command.none, decode(99));
}

test "clampSeekTarget bounds negative, past-end, NaN" {
    try std.testing.expectEqual(@as(f64, 0), clampSeekTarget(-3.0, 100.0));
    try std.testing.expectEqual(@as(f64, 42.0), clampSeekTarget(42.0, 100.0));
    // Past the end: cap 0.5s short so the seek doesn't EOF-close the file.
    try std.testing.expectEqual(@as(f64, 99.5), clampSeekTarget(500.0, 100.0));
    // Unknown duration (live radio reports 0): only the lower bound applies.
    try std.testing.expectEqual(@as(f64, 1234.0), clampSeekTarget(1234.0, 0.0));
    try std.testing.expectEqual(@as(f64, 0), clampSeekTarget(std.math.nan(f64), 100.0));
    // Pathological: media shorter than the margin must not clamp negative.
    try std.testing.expectEqual(@as(f64, 0), clampSeekTarget(5.0, 0.3));
}

test "playbackRate mirrors pause flag" {
    try std.testing.expectEqual(@as(f64, 0.0), playbackRate(true));
    try std.testing.expectEqual(@as(f64, 1.0), playbackRate(false));
}
