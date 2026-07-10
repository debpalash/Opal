//! Pure (no-IO) helpers for audio/video filter settings that must persist and
//! be replayed at player init. Kept side-effect-free so the settings.zig click
//! sites and the player.zig init replay share the SAME mapping (they can't
//! drift), and so the logic is unit-testable without crossing the mpv /
//! io_global boundary (see CLAUDE.md *_pure discipline).

const std = @import("std");

/// Audio equalizer preset index → mpv `af` filter spec. This is the value
/// passed to the "af" option when replaying at player init, and to
/// `af set "<spec>"` when the user clicks a preset on a live player. Index order
/// matches the Settings segment: 0 Flat, 1 Bass+, 2 Voice, 3 Cinema, 4 Loud.
/// Out-of-range (corrupt config) → Flat ("", clears the filter chain).
pub fn eqFilterSpec(preset: usize) [:0]const u8 {
    const specs = [_][:0]const u8{
        "", // Flat — clears the filter chain
        "superequalizer=1b=6:2b=5:3b=4:4b=2", // Bass+
        "superequalizer=3b=3:4b=4:5b=5:6b=4:7b=3", // Voice
        "superequalizer=1b=4:2b=3:6b=2:7b=3:8b=4", // Cinema
        "loudnorm", // Loud
    };
    return specs[if (preset < specs.len) preset else 0];
}

/// Video filter value (brightness/contrast/saturation/gamma) clamped to mpv's
/// valid range (-100..100). Used by the ± button handlers before it is written
/// to the persisted state field and set on the property.
pub fn clampVideoFilter(v: i32) i32 {
    return std.math.clamp(v, -100, 100);
}

/// Download rate limit (bytes/sec) sanitized for persistence + replay: negatives
/// (corrupt/legacy config) collapse to 0 = "no limit". A value > 0 is an
/// explicit cap that must be re-applied to a freshly-created torrent session.
pub fn sanitizeDownloadLimit(v: i32) i32 {
    return if (v > 0) v else 0;
}

test "eqFilterSpec maps presets and clamps out of range to Flat" {
    try std.testing.expectEqualStrings("", eqFilterSpec(0));
    try std.testing.expectEqualStrings("superequalizer=1b=6:2b=5:3b=4:4b=2", eqFilterSpec(1));
    try std.testing.expectEqualStrings("superequalizer=3b=3:4b=4:5b=5:6b=4:7b=3", eqFilterSpec(2));
    try std.testing.expectEqualStrings("superequalizer=1b=4:2b=3:6b=2:7b=3:8b=4", eqFilterSpec(3));
    try std.testing.expectEqualStrings("loudnorm", eqFilterSpec(4));
    try std.testing.expectEqualStrings("", eqFilterSpec(5));
    try std.testing.expectEqualStrings("", eqFilterSpec(999));
}

test "clampVideoFilter clamps to mpv -100..100" {
    try std.testing.expectEqual(@as(i32, 0), clampVideoFilter(0));
    try std.testing.expectEqual(@as(i32, 55), clampVideoFilter(55));
    try std.testing.expectEqual(@as(i32, 100), clampVideoFilter(100));
    try std.testing.expectEqual(@as(i32, 100), clampVideoFilter(105));
    try std.testing.expectEqual(@as(i32, -100), clampVideoFilter(-100));
    try std.testing.expectEqual(@as(i32, -100), clampVideoFilter(-250));
}

test "sanitizeDownloadLimit collapses non-positive to zero" {
    try std.testing.expectEqual(@as(i32, 0), sanitizeDownloadLimit(0));
    try std.testing.expectEqual(@as(i32, 0), sanitizeDownloadLimit(-1));
    try std.testing.expectEqual(@as(i32, 5 * 1024 * 1024), sanitizeDownloadLimit(5 * 1024 * 1024));
}
