//! Pure display-scale logic — no io, no dvui — so it unit-tests standalone.
//!
//! Opal's final on-screen size is `base × natural_scale × ui_scale`:
//!   • natural_scale — the OS/display DPI content scale, resolved by dvui's SDL
//!     backend per platform (SDL_GetDisplayContentScale on macOS / modern SDL,
//!     `Xft.dpi`/`xrdb` on Linux, SDL_GetDisplayDPI on Windows). This already
//!     makes physical size consistent across displays.
//!   • ui_scale — the user-density multiplier this module picks a DEFAULT for.
//!
//! `deviceScale` chooses that default from the display's natural scale so a
//! fresh install is compact on every device without manual tweaking: high-DPI
//! panels render text crisply even when logically smaller, so they get a denser
//! default; standard-DPI displays (1 logical px = 1 physical px) stay at 1.0 so
//! text never drops below readable.

const std = @import("std");

/// Hard bounds for any scale value — matches the Settings ramp ends, so a
/// corrupt config row or an odd display report can't produce an unusable UI.
pub const MIN_SCALE: f32 = 0.6;
pub const MAX_SCALE: f32 = 2.0;

pub fn clampScale(s: f32) f32 {
    if (!std.math.isFinite(s)) return 1.0;
    return std.math.clamp(s, MIN_SCALE, MAX_SCALE);
}

/// What the platform could tell us about the physical panel. All fields are 0
/// when unknown — every consumer treats 0 as "no signal" rather than a value.
pub const Display = struct {
    px_w: f32 = 0,
    px_h: f32 = 0,
    /// Physical size of the panel. Only Linux fills these in (from EDID);
    /// macOS and Windows report a trustworthy content scale instead.
    mm_w: f32 = 0,
    mm_h: f32 = 0,
};

/// True physical pixel density, or null when the panel's size is unknown or the
/// numbers are implausible. Projectors and some EDIDs report a 0 or absurd
/// physical size, and a bogus DPI here would pick a bogus default scale.
pub fn physicalDpi(d: Display) ?f32 {
    if (!std.math.isFinite(d.px_w) or !std.math.isFinite(d.mm_w)) return null;
    if (d.px_w <= 0 or d.mm_w <= 0) return null;
    const dpi = d.px_w / (d.mm_w / 25.4);
    if (!std.math.isFinite(dpi) or dpi < 40 or dpi > 800) return null;
    return dpi;
}

/// Device-aware default ui_scale.
///
/// `natural_scale` is the OS content scale and is authoritative WHEN THE OS
/// ACTUALLY REPORTS ONE: macOS and Windows do, and second-guessing them would
/// double-apply the same correction. Linux frequently does not — on a Wayland
/// or X11 session with no `Xft.dpi` set, dvui's backend has nothing to read and
/// falls back to exactly 1.0. That 1.0 is not a measurement, it is a shrug, and
/// treating it as "standard DPI" is how a 2560x1600 190-DPI laptop panel ended
/// up defaulting to 0.8 and rendering unreadably small.
///
/// So: trust a reported scale above ~1.15, and otherwise fall back to the panel
/// itself — real DPI when the physical size is known, raw resolution when it is
/// not.
pub fn deviceScale(natural_scale: f32, d: Display) f32 {
    // Tiers are ~20% below a 1× baseline — the user runs Opal deliberately
    // compact (see the compact type ramp); the chrome should stay quiet.
    if (std.math.isFinite(natural_scale) and natural_scale > 0) {
        if (natural_scale >= 1.9) return 0.68; // Retina / 200% (macOS, hi-res Win/Linux)
        if (natural_scale >= 1.4) return 0.72; // ~150% displays
        if (natural_scale >= 1.15) return 0.76; // ~125% displays
    }

    // No usable OS scale. Derive density from the panel.
    if (physicalDpi(d)) |dpi| {
        if (dpi >= 200) return 1.30; // 4K/5K laptop panels
        if (dpi >= 170) return 1.20; // ~190 DPI (2560x1600 14", 2880x1800 15")
        if (dpi >= 140) return 1.00; // 1080p 14" and similar
        if (dpi >= 115) return 0.90;
        return 0.80; // ~96 DPI desktop monitor — the original baseline
    }

    // Physical size unknown: resolution alone. Deliberately gentler than the
    // DPI ramp, because width cannot distinguish a 14" 2560-wide laptop
    // (~190 DPI) from a 27" 2560-wide desktop monitor (~109 DPI) — overshooting
    // the desktop case is worse than undershooting the laptop one, which the
    // Settings slider fixes in one drag.
    if (std.math.isFinite(d.px_w)) {
        if (d.px_w >= 3840) return 1.20;
        if (d.px_w >= 2560) return 1.10;
        if (d.px_w >= 1920) return 0.90;
    }
    return 0.8; // standard DPI — floor for readability at 1 logical px = 1 physical
}

// ── Responsive breakpoints ──────────────────────────────────────────────────
//
// The shell renders INSIDE `dvui.scale(ui_scale)`, so every rect it measures is
// in scaled units, not on-screen points: a 900pt window reports 900/0.8 = 1125.
// Comparing that against point thresholds made the breakpoints fire ~25% late
// (measured: rect.w=1118.8 at ui_scale=0.8 for an 895pt window), so a narrow
// window kept the wide layout and pushed the right-hand nav actions off the
// edge. Convert back to points first.

/// Below this many on-screen points, the top nav links move to a bottom tab bar.
pub const COMPACT_PT: f32 = 760;
/// Below this, the nav stays on top but labels collapse to icons and the
/// omnibox tightens so the row still fits.
pub const NARROW_PT: f32 = 950;

/// Scaled layout units → on-screen points.
pub fn layoutPoints(rect_w: f32, ui_scale: f32) f32 {
    if (!std.math.isFinite(rect_w) or !std.math.isFinite(ui_scale) or ui_scale <= 0) return rect_w;
    return rect_w * ui_scale;
}

/// `rect_w` is the shell root's width in scaled units. A width of 0 (first
/// paint, before layout converges) reports "wide" so the full layout is the
/// default rather than a one-frame flash of the mobile shell.
pub fn isCompact(rect_w: f32, ui_scale: f32) bool {
    const pt = layoutPoints(rect_w, ui_scale);
    return pt > 1 and pt < COMPACT_PT;
}

pub fn isNarrow(rect_w: f32, ui_scale: f32) bool {
    const pt = layoutPoints(rect_w, ui_scale);
    return pt > 1 and pt < NARROW_PT;
}

test "deviceScale trusts a reported OS content scale" {
    // A display the OS described: the panel numbers must not perturb the tier.
    const hidpi_panel = Display{ .px_w = 2560, .px_h = 1600, .mm_w = 340, .mm_h = 220 };
    try std.testing.expectEqual(@as(f32, 0.68), deviceScale(2.0, hidpi_panel)); // Mac Retina
    try std.testing.expectEqual(@as(f32, 0.68), deviceScale(3.0, .{})); // very high-DPI clamps to densest tier
    try std.testing.expectEqual(@as(f32, 0.72), deviceScale(1.5, .{})); // 150% Windows
    try std.testing.expectEqual(@as(f32, 0.76), deviceScale(1.25, .{})); // 125% Windows
}

test "deviceScale falls back to the panel when the OS reports no scale" {
    // Linux, Wayland, no Xft.dpi → natural_scale is 1.0 as a shrug, not a
    // measurement. 2560x1600 in 340x220mm is ~191 DPI and must not read as
    // "standard DPI"; 0.8 here is the bug this fallback exists to fix.
    const laptop_2560 = Display{ .px_w = 2560, .px_h = 1600, .mm_w = 340, .mm_h = 220 };
    try std.testing.expectEqual(@as(f32, 1.20), deviceScale(1.0, laptop_2560));

    // Same pixel width, 27" desktop monitor (~109 DPI) — must stay compact.
    const desktop_27 = Display{ .px_w = 2560, .px_h = 1440, .mm_w = 597, .mm_h = 336 };
    try std.testing.expectEqual(@as(f32, 0.80), deviceScale(1.0, desktop_27));

    // 4K 15" laptop, ~294 DPI.
    const laptop_4k = Display{ .px_w = 3840, .px_h = 2160, .mm_w = 332, .mm_h = 187 };
    try std.testing.expectEqual(@as(f32, 1.30), deviceScale(1.0, laptop_4k));

    // Nothing known at all → the historical default, unchanged.
    try std.testing.expectEqual(@as(f32, 0.8), deviceScale(1.0, .{}));
}

test "deviceScale uses resolution when physical size is missing" {
    try std.testing.expectEqual(@as(f32, 1.20), deviceScale(1.0, .{ .px_w = 3840 }));
    try std.testing.expectEqual(@as(f32, 1.10), deviceScale(1.0, .{ .px_w = 2560 }));
    try std.testing.expectEqual(@as(f32, 0.90), deviceScale(1.0, .{ .px_w = 1920 }));
    try std.testing.expectEqual(@as(f32, 0.80), deviceScale(1.0, .{ .px_w = 1366 }));
}

test "physicalDpi rejects implausible panel geometry" {
    try std.testing.expect(physicalDpi(.{ .px_w = 2560, .mm_w = 340 }) != null);
    try std.testing.expect(physicalDpi(.{ .px_w = 2560, .mm_w = 0 }) == null); // EDID gave no size
    try std.testing.expect(physicalDpi(.{ .px_w = 0, .mm_w = 340 }) == null);
    // A projector reporting a 4m-wide "panel" — ~16 DPI, below the floor.
    try std.testing.expect(physicalDpi(.{ .px_w = 2560, .mm_w = 4000 }) == null);
}

test "deviceScale tolerates a garbage natural scale" {
    try std.testing.expectEqual(@as(f32, 0.8), deviceScale(0, .{}));
    try std.testing.expectEqual(@as(f32, 0.8), deviceScale(-1, .{}));
    try std.testing.expectEqual(@as(f32, 0.8), deviceScale(std.math.nan(f32), .{}));
    // …and still consults the panel in that case.
    try std.testing.expectEqual(@as(f32, 1.20), deviceScale(std.math.nan(f32), .{ .px_w = 2560, .mm_w = 340 }));
}

test "clampScale keeps values in the usable band" {
    try std.testing.expectEqual(@as(f32, 0.8), clampScale(0.8));
    try std.testing.expectEqual(MIN_SCALE, clampScale(0.1));
    try std.testing.expectEqual(MAX_SCALE, clampScale(5.0));
    try std.testing.expectEqual(@as(f32, 1.0), clampScale(std.math.nan(f32)));
}

test "breakpoints measure on-screen points, not scaled layout units" {
    // Regression: the shell renders inside dvui.scale(ui_scale), so an 895pt
    // window reported rect.w = 1118.8 at ui_scale 0.8. Against the raw
    // thresholds that read as "wide", the nav kept full-width labels + the
    // Donate chip, and the right-hand action cluster (Now playing / Plugins /
    // Logs / Settings / ⋯) was pushed off the window edge.
    try std.testing.expect(isNarrow(1118.8, 0.8));
    try std.testing.expect(!isCompact(1118.8, 0.8));
    // Same window measured raw would have missed the breakpoint entirely.
    try std.testing.expect(!isNarrow(1118.8, 1.0));

    // Retina auto-scale (0.68): a 700pt window must reach the mobile layout.
    try std.testing.expect(isCompact(700.0 / 0.68, 0.68));
    try std.testing.expect(isNarrow(700.0 / 0.68, 0.68));

    // Wide window stays wide at every scale.
    try std.testing.expect(!isNarrow(1600.0 / 0.8, 0.8));
    try std.testing.expect(!isCompact(1600.0 / 0.8, 0.8));
}

test "breakpoints are inert on a degenerate first frame" {
    // rect.w is 0 before layout converges — must report "wide", not "mobile".
    try std.testing.expect(!isCompact(0, 0.8));
    try std.testing.expect(!isNarrow(0, 0.8));
    // A bogus scale must not turn a wide window into a phone.
    try std.testing.expect(!isCompact(2000, 0));
    try std.testing.expect(!isNarrow(2000, std.math.nan(f32)));
}

test "layoutPoints round-trips a known window" {
    try std.testing.expectApproxEqAbs(@as(f32, 895.0), layoutPoints(1118.75, 0.8), 0.1);
}
