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

// ── Picture presets ──────────────────────────────────────────────────────────
//
// One switch that sets the four video-equalizer properties Opal already drives
// (brightness / contrast / saturation / gamma), plus an HDR-aware `auto` mode.
//
// What this is NOT: HDR passthrough. Opal renders through `vo=libmpv` with
// MPV_RENDER_API_TYPE_SW — mpv rasterises to a CPU buffer that SDL blits — so
// there is no swapchain to hand HDR metadata to and `target-colorspace-hint`
// has nothing to act on. The display will not switch to HDR mode. What CAN be
// fixed is the thing people actually complain about: HDR (PQ/HLG, BT.2020)
// material shown through an SDR path looks flat, grey and desaturated, because
// it was graded for a far higher peak luminance. `hdr` corrects that.
//
// Values are deliberately modest. These are mpv equalizer offsets on a
// -100..100 scale where the whole range is enormous; the goal is a graded look,
// not a filter that announces itself.

pub const PicturePreset = enum(u8) {
    /// Pick per-file from the video's own colour metadata.
    auto = 0,
    /// Untouched — every offset zero.
    standard = 1,
    /// HDR/wide-gamut material rendered through the SDR path.
    hdr = 2,
    /// Dim-room film viewing: keep shadow detail, resist the crushed look.
    cinema = 3,
    /// Bright-room episodic viewing: lift and sharpen the midtones.
    tv_show = 4,
    /// Punchy. Not accurate, and not pretending to be.
    vivid = 5,
};

pub const PictureValues = struct {
    brightness: i32 = 0,
    contrast: i32 = 0,
    saturation: i32 = 0,
    gamma: i32 = 0,
};

/// The four equalizer offsets for a preset. `auto` resolves to `standard` here —
/// callers resolve it against the file's colour metadata first (`resolveAuto`),
/// because this function is pure and knows nothing about the loaded video.
pub fn pictureValues(p: PicturePreset) PictureValues {
    return switch (p) {
        .auto, .standard => .{},
        // HDR through an SDR path arrives flat and grey: the transfer curve
        // expects a much brighter display, so midtones land low and colour
        // reads washed out. Lift gamma, add contrast back, restore saturation.
        // Brightness stays put — raising it greys the blacks, which is the
        // opposite of the problem.
        .hdr => .{ .brightness = 0, .contrast = 12, .saturation = 15, .gamma = 12 },
        // Dim room, film: slightly lower contrast so shadow detail survives,
        // a touch of gamma for the same reason, colour left near neutral.
        .cinema => .{ .brightness = -2, .contrast = -4, .saturation = 4, .gamma = 6 },
        // Bright room, episodic: lift the whole picture and firm up midtones.
        .tv_show => .{ .brightness = 4, .contrast = 6, .saturation = 6, .gamma = -2 },
        .vivid => .{ .brightness = 2, .contrast = 16, .saturation = 24, .gamma = 0 },
    };
}

/// Human label for the preset switch in the player controls.
pub fn pictureLabel(p: PicturePreset) []const u8 {
    return switch (p) {
        .auto => "Auto",
        .standard => "Standard",
        .hdr => "HDR",
        .cinema => "Cinema",
        .tv_show => "TV Show",
        .vivid => "Vivid",
    };
}

/// Is this video HDR / wide-gamut, judged from mpv's `video-params`?
///
/// `gamma` is the transfer function — `pq` (HDR10/Dolby Vision) and `hlg`
/// (broadcast HDR) are the two that matter. `primaries` of `bt.2020` alone is
/// NOT enough: plenty of SDR UHD material is tagged BT.2020, and treating it as
/// HDR would over-correct a picture that was already fine. Both signals are
/// accepted, but the transfer function is the one that decides.
pub fn isHdrVideo(gamma: []const u8, primaries: []const u8) bool {
    if (eqIgnoreCase(gamma, "pq") or eqIgnoreCase(gamma, "hlg") or
        eqIgnoreCase(gamma, "st2084") or eqIgnoreCase(gamma, "smpte2084") or
        eqIgnoreCase(gamma, "arib-std-b67")) return true;
    // BT.2020 primaries with an explicitly HDR-ish transfer already matched
    // above; on its own it is a gamut hint, not a dynamic-range one.
    _ = primaries;
    return false;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// What `auto` means for this file. Anything other than `auto` passes through
/// untouched, so a user's explicit choice is never second-guessed.
pub fn resolveAuto(p: PicturePreset, gamma: []const u8, primaries: []const u8) PicturePreset {
    if (p != .auto) return p;
    return if (isHdrVideo(gamma, primaries)) .hdr else .standard;
}

/// Config round-trip. An unknown/corrupt stored value falls back to `auto`
/// rather than a fixed preset — auto is the one that is right more often.
pub fn picturePresetFromInt(v: usize) PicturePreset {
    return switch (v) {
        1 => .standard,
        2 => .hdr,
        3 => .cinema,
        4 => .tv_show,
        5 => .vivid,
        else => .auto,
    };
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

test "pictureValues: every preset stays inside mpv's equalizer range" {
    // A value outside -100..100 is rejected by mpv outright, which would leave
    // the picture on whatever the previous preset set — a switch that silently
    // does nothing.
    for ([_]PicturePreset{ .auto, .standard, .hdr, .cinema, .tv_show, .vivid }) |p| {
        const v = pictureValues(p);
        inline for (.{ v.brightness, v.contrast, v.saturation, v.gamma }) |x| {
            try std.testing.expectEqual(x, clampVideoFilter(x));
        }
    }
}

test "pictureValues: standard and auto are a true no-op" {
    // Selecting Standard must undo a previous preset completely, not merely
    // apply a smaller correction.
    const s = pictureValues(.standard);
    try std.testing.expectEqual(@as(i32, 0), s.brightness);
    try std.testing.expectEqual(@as(i32, 0), s.contrast);
    try std.testing.expectEqual(@as(i32, 0), s.saturation);
    try std.testing.expectEqual(@as(i32, 0), s.gamma);
    try std.testing.expectEqual(s, pictureValues(.auto));
}

test "isHdrVideo keys off the transfer function, not the gamut" {
    try std.testing.expect(isHdrVideo("pq", "bt.2020"));
    try std.testing.expect(isHdrVideo("hlg", "bt.2020"));
    try std.testing.expect(isHdrVideo("PQ", "")); // mpv casing varies
    try std.testing.expect(isHdrVideo("st2084", ""));
    try std.testing.expect(isHdrVideo("arib-std-b67", ""));

    // REGRESSION GUARD: BT.2020 primaries alone is a WIDE GAMUT signal, not a
    // dynamic-range one. Plenty of SDR UHD is tagged bt.2020, and treating it
    // as HDR would over-correct a picture that was already correct.
    try std.testing.expect(!isHdrVideo("bt.1886", "bt.2020"));
    try std.testing.expect(!isHdrVideo("srgb", "bt.2020"));
    try std.testing.expect(!isHdrVideo("", "bt.2020"));
    // Unknown / absent metadata must not guess HDR.
    try std.testing.expect(!isHdrVideo("", ""));
    try std.testing.expect(!isHdrVideo("gamma2.2", "bt.709"));
}

test "resolveAuto never overrides an explicit choice" {
    // Auto adapts...
    try std.testing.expectEqual(PicturePreset.hdr, resolveAuto(.auto, "pq", "bt.2020"));
    try std.testing.expectEqual(PicturePreset.standard, resolveAuto(.auto, "bt.1886", "bt.709"));
    // ...every other selection is the user's, including choosing Standard on
    // HDR material or HDR on SDR material.
    try std.testing.expectEqual(PicturePreset.standard, resolveAuto(.standard, "pq", "bt.2020"));
    try std.testing.expectEqual(PicturePreset.hdr, resolveAuto(.hdr, "bt.1886", "bt.709"));
    try std.testing.expectEqual(PicturePreset.cinema, resolveAuto(.cinema, "pq", ""));
}

test "picturePresetFromInt: corrupt config falls back to auto, not a fixed look" {
    try std.testing.expectEqual(PicturePreset.auto, picturePresetFromInt(0));
    try std.testing.expectEqual(PicturePreset.standard, picturePresetFromInt(1));
    try std.testing.expectEqual(PicturePreset.hdr, picturePresetFromInt(2));
    try std.testing.expectEqual(PicturePreset.cinema, picturePresetFromInt(3));
    try std.testing.expectEqual(PicturePreset.tv_show, picturePresetFromInt(4));
    try std.testing.expectEqual(PicturePreset.vivid, picturePresetFromInt(5));
    try std.testing.expectEqual(PicturePreset.auto, picturePresetFromInt(999));
    // Round-trips for every real preset.
    for ([_]PicturePreset{ .auto, .standard, .hdr, .cinema, .tv_show, .vivid }) |p| {
        try std.testing.expectEqual(p, picturePresetFromInt(@intFromEnum(p)));
    }
}

test "pictureLabel: every preset is named, none empty" {
    for ([_]PicturePreset{ .auto, .standard, .hdr, .cinema, .tv_show, .vivid }) |p| {
        try std.testing.expect(pictureLabel(p).len > 0);
    }
}

test "hdr preset lifts the picture without greying the blacks" {
    // The washed-out look comes from midtones landing low, so gamma/contrast do
    // the work. Raising brightness would lift black level too and make it worse.
    const v = pictureValues(.hdr);
    try std.testing.expect(v.gamma > 0);
    try std.testing.expect(v.contrast > 0);
    try std.testing.expect(v.saturation > 0);
    try std.testing.expectEqual(@as(i32, 0), v.brightness);
}
