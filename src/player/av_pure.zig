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

/// Preset values plus the user's manual slider offsets, each clamped to
/// -100..100. Presets and sliders COMBINE (they used to overwrite each other).
pub fn combineGrade(preset: PictureValues, manual: PictureValues) PictureValues {
    return .{
        .brightness = clampVideoFilter(preset.brightness + manual.brightness),
        .contrast = clampVideoFilter(preset.contrast + manual.contrast),
        .saturation = clampVideoFilter(preset.saturation + manual.saturation),
        .gamma = clampVideoFilter(preset.gamma + manual.gamma),
    };
}

/// Label of the single mpv video filter that carries the grade.
pub const grade_filter_label = "@opal-eq";

/// Video filters the grade spec may name. Every one must exist on EVERY
/// platform's libavfilter. iOS is the constraint: MPVKit 1.0.0
/// (Libavfilter-GPL, mobile/ios/dependencies.json) ships no `eq`, only
/// `lut`/`lutrgb`/`lutyuv`/`lut2`/`lut1d`/`lut3d` among the colour filters.
pub const grade_allowed_filters = [_][]const u8{"lutyuv"};

/// ffmpeg `lutyuv` spec for a combined grade, or "" when every value is zero
/// (no filter at all). Reproduces mpv/ffmpeg-eq semantics: brightness b/100,
/// contrast (c+100)/100, saturation (s+100)/100, gamma 8^(g/100).
///   luma   y = minval+(maxval-minval)*pow(clip((n-0.5)*C+0.5+B,0,1),1/G),
///          n = (val-minval)/(maxval-minval)  (limited range: 16..235)
///   chroma u,v = clip((val-mid)*S+mid,minval,maxval), mid=pow(2,ceil(log(maxval)/log(2))-1)
///   — NOT (maxval+1)/2: limited-range chroma maxval is 240, so that put
///   neutral at 120 and tinted the picture (regression test below)
/// `maxval`/`minval` are lut constants, so 10-bit sources work. Each
/// expression is single-quoted so its commas do not split the filter graph.
/// y is omitted when B=0,C=1,G=1; u/v when S=1. Fixed 3 decimals.
///
/// Why a filter: Opal renders with MPV_RENDER_API_TYPE_SW, where mpv's
/// brightness/contrast/saturation/gamma properties have no visible effect
/// (the SW renderer never applies the video equalizer). A `vf` runs on the
/// decoded frames regardless of the render API. Why lutyuv and not `eq`:
/// see `grade_allowed_filters`.
pub fn gradeFilterSpec(buf: []u8, v: PictureValues) []const u8 {
    const bi = clampVideoFilter(v.brightness);
    const ci = clampVideoFilter(v.contrast);
    const si = clampVideoFilter(v.saturation);
    const gi = clampVideoFilter(v.gamma);
    if (bi == 0 and ci == 0 and si == 0 and gi == 0) return "";
    const b: f64 = @as(f64, @floatFromInt(bi)) / 100.0;
    const c: f64 = (@as(f64, @floatFromInt(ci)) + 100.0) / 100.0;
    const s: f64 = (@as(f64, @floatFromInt(si)) + 100.0) / 100.0;
    const g: f64 = @exp(@log(8.0) * @as(f64, @floatFromInt(gi)) / 100.0);
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("lutyuv=") catch return "";
    var first = true;
    if (bi != 0 or ci != 0 or gi != 0) {
        w.print("y='minval+(maxval-minval)*pow(clip(((val-minval)/(maxval-minval)-0.5)*{d:.3}+0.5+{d:.3},0,1),{d:.3})'", .{ c, b, 1.0 / g }) catch return "";
        first = false;
    }
    if (si != 0) {
        inline for (.{ "u", "v" }) |ch| {
            if (!first) w.writeAll(":") catch return "";
            w.print(ch ++ "='clip((val-pow(2,ceil(log(maxval)/log(2))-1))*{d:.3}+pow(2,ceil(log(maxval)/log(2))-1),minval,maxval)'", .{s}) catch return "";
            first = false;
        }
    }
    return w.buffered();
}

test "combineGrade adds and clamps" {
    const r = combineGrade(.{ .contrast = 16, .saturation = 24 }, .{ .contrast = 90, .saturation = -30, .gamma = -150 });
    try std.testing.expectEqual(@as(i32, 100), r.contrast);
    try std.testing.expectEqual(@as(i32, -6), r.saturation);
    try std.testing.expectEqual(@as(i32, -100), r.gamma);
}

test "gradeFilterSpec: all zero is no filter" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("", gradeFilterSpec(&buf, .{}));
    try std.testing.expectEqualStrings("", gradeFilterSpec(&buf, pictureValues(.standard)));
}

test "gradeFilterSpec: lutyuv mapping" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "lutyuv=y='minval+(maxval-minval)*pow(clip(((val-minval)/(maxval-minval)-0.5)*1.160+0.5+0.020,0,1),1.000)':" ++
            "u='clip((val-pow(2,ceil(log(maxval)/log(2))-1))*1.240+pow(2,ceil(log(maxval)/log(2))-1),minval,maxval)':" ++
            "v='clip((val-pow(2,ceil(log(maxval)/log(2))-1))*1.240+pow(2,ceil(log(maxval)/log(2))-1),minval,maxval)'",
        gradeFilterSpec(&buf, pictureValues(.vivid)),
    );
    // Saturation only: no y.
    try std.testing.expectEqualStrings(
        "lutyuv=u='clip((val-pow(2,ceil(log(maxval)/log(2))-1))*0.000+pow(2,ceil(log(maxval)/log(2))-1),minval,maxval)':" ++
            "v='clip((val-pow(2,ceil(log(maxval)/log(2))-1))*0.000+pow(2,ceil(log(maxval)/log(2))-1),minval,maxval)'",
        gradeFilterSpec(&buf, .{ .saturation = -100 }),
    );
    // Gamma only: no u/v. gamma=100 -> G=8 -> exponent 0.125.
    try std.testing.expectEqualStrings(
        "lutyuv=y='minval+(maxval-minval)*pow(clip(((val-minval)/(maxval-minval)-0.5)*1.000+0.5+0.000,0,1),0.125)'",
        gradeFilterSpec(&buf, .{ .gamma = 100 }),
    );
}

test "gradeFilterSpec: only allowed filters, quoted expressions, worst case fits" {
    var buf: [512]u8 = undefined;
    const spec = gradeFilterSpec(&buf, .{ .brightness = -100, .contrast = 100, .saturation = 100, .gamma = -100 });
    try std.testing.expect(spec.len > 0 and spec.len < buf.len);
    // Filter name = text before '='; there is exactly one filter in the chain.
    const name = spec[0..std.mem.indexOfScalar(u8, spec, '=').?];
    var ok = false;
    for (grade_allowed_filters) |f| ok = ok or std.mem.eql(u8, f, name);
    try std.testing.expect(ok);
    // Every comma sits inside single quotes (else it splits the graph).
    var inq = false;
    for (spec) |ch| {
        if (ch == '\'') inq = !inq;
        if (ch == ',') try std.testing.expect(inq);
    }
    try std.testing.expect(!inq);
}

test "grade_allowed_filters is a subset of the MPVKit 1.0.0 arm64 video filters" {
    // `_ff_vf_*` symbols in MPVKit 1.0.0 Libavfilter-GPL arm64 (nm). No `eq`.
    const ios = [_][]const u8{
        "setpts",         "trim",        "blend_vulkan", "bwdif",          "chromaber_vulkan", "delogo",
        "estdif",         "flip_vulkan", "hflip_vulkan", "vflip_vulkan",   "format",           "fps",
        "gblur_vulkan",   "hflip",       "hwdownload",   "hwmap",          "hwupload",         "idet",
        "lenscorrection", "libplacebo",  "lut",          "lutrgb",         "lutyuv",           "lut2",
        "lut1d",          "lut3d",       "negate",       "nlmeans_vulkan", "null",             "overlay",
        "overlay_vulkan", "palettegen",  "paletteuse",   "rotate",         "scale",            "scale2ref",
        "ass",            "subtitles",   "transpose",    "vflip",          "w3fdif",           "xfade_vulkan",
        "yadif",
    };
    for (grade_allowed_filters) |f| {
        var found = false;
        for (ios) |i| found = found or std.mem.eql(u8, f, i);
        try std.testing.expect(found);
    }
}

test "regression: iOS libavfilter has no eq" {
    // MPVKit 1.0.0 has no `eq`; the grade silently did nothing on iOS.
    var buf: [512]u8 = undefined;
    for ([_]PicturePreset{ .hdr, .cinema, .tv_show, .vivid }) |p| {
        const spec = gradeFilterSpec(&buf, combineGrade(pictureValues(p), .{}));
        try std.testing.expect(spec.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, spec, "eq=") == null);
        try std.testing.expect(std.mem.startsWith(u8, spec, "lutyuv="));
    }
    try std.testing.expect(gradeFilterSpec(&buf, combineGrade(pictureValues(.standard), .{ .saturation = -100 })).len > 0);
    // Preset + manual that cancel out -> no filter.
    try std.testing.expectEqualStrings("", gradeFilterSpec(&buf, combineGrade(pictureValues(.vivid), .{ .brightness = -2, .contrast = -16, .saturation = -24 })));
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
///
/// 0 is not an arbitrary sentinel — it is libtorrent's own encoding for
/// unlimited on settings_pack::download_rate_limit ("A value of 0 means
/// unlimited"). Keeping the same encoding all the way from config to the FFI is
/// what stops a second translation being invented at the boundary; the wrapper
/// used to turn this into -1 there, which libtorrent reads as a negative quota
/// rather than as "no ceiling".
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
        try std.testing.expectEqual(p, picturePresetFromInt(@backingInt(p)));
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

test "lutyuv chroma neutral is 128, not 120 (limited-range maxval is 240)" {
    // Mirrors the `mid` expression in gradeFilterSpec. (maxval+1)/2 put
    // limited-range 8-bit neutral at 120, tinting every graded frame.
    const mid = struct {
        fn f(maxval: f64) f64 {
            return std.math.pow(f64, 2, @ceil(@log(maxval) / @log(2.0)) - 1);
        }
    }.f;
    try std.testing.expectEqual(@as(f64, 128), mid(240)); // 8-bit limited
    try std.testing.expectEqual(@as(f64, 128), mid(255)); // 8-bit full
    try std.testing.expectEqual(@as(f64, 512), mid(960)); // 10-bit limited
    try std.testing.expectEqual(@as(f64, 512), mid(1023)); // 10-bit full
    var buf: [512]u8 = undefined;
    const spec = gradeFilterSpec(&buf, .{ .saturation = -100 });
    try std.testing.expect(std.mem.indexOf(u8, spec, "(maxval+1)/2") == null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "pow(2,ceil(log(maxval)/log(2))-1)") != null);
}
