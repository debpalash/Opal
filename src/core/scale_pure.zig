//! Pure display-scale logic — no io, no dvui — so it unit-tests standalone.
//!
//! Opal's final on-screen size is `base × natural_scale × ui_scale`:
//!   • natural_scale — the OS/display DPI content scale, resolved by dvui's SDL
//!     backend per platform (SDL_GetDisplayContentScale on macOS / modern SDL,
//!     `Xft.dpi`/`xrdb` on Linux, SDL_GetDisplayDPI on Windows). This already
//!     makes physical size consistent across displays.
//!   • ui_scale — the user-density multiplier. Its adaptive default is 1.0×.
//!
//! The OS/DVUI natural scale already handles display DPI. Keeping the default
//! multiplier at 1.0 avoids a second DPI correction while the responsive shell
//! independently adapts navigation, grids, and controls to the available
//! on-screen points. Explicit density overrides remain available to users.

const std = @import("std");

/// Hard bounds for any scale value — matches the Settings ramp ends, so a
/// corrupt config row or an odd display report can't produce an unusable UI.
pub const MIN_SCALE: f32 = 0.6;
pub const MAX_SCALE: f32 = 2.0;
pub const AUTO_MIN_SCALE: f32 = 1.0;

pub fn clampScale(s: f32) f32 {
    if (!std.math.isFinite(s)) return 1.0;
    return std.math.clamp(s, MIN_SCALE, MAX_SCALE);
}

/// Adaptive default UI multiplier. `natural_scale` is intentionally ignored:
/// DVUI already applies it, and responsive layout is driven by screen points.
pub fn deviceScale(natural_scale: f32) f32 {
    _ = natural_scale;
    return AUTO_MIN_SCALE;
}

/// Resolve persisted scale preferences before publishing config as loaded.
/// Older Auto installs may have saved the previous adaptive value (0.68-0.8x),
/// while manual sub-1x choices must remain untouched. Keeping this policy pure
/// makes the distinction explicit and prevents a below-1x Auto value from being
/// observable between config load and the first GUI frame (or forever in a
/// headless process).
pub fn restoredScale(auto: bool, stored: f32) f32 {
    if (auto) return deviceScale(1.0);
    return clampScale(stored);
}

/// Apply an Auto toggle from a non-render thread. Such callers cannot query
/// DVUI's windowNaturalScale(), but the adaptive multiplier is deliberately
/// DPI-independent, so enabling Auto can take effect immediately and safely.
pub fn scaleAfterAutoToggle(enabled: bool, current: f32) f32 {
    if (!enabled) return clampScale(current);
    return deviceScale(1.0);
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

test "adaptive scale defaults to 1x on every display density" {
    try std.testing.expectEqual(@as(f32, 1.0), deviceScale(1.0));
    try std.testing.expectEqual(@as(f32, 1.0), deviceScale(1.25));
    try std.testing.expectEqual(@as(f32, 1.0), deviceScale(1.5));
    try std.testing.expectEqual(@as(f32, 1.0), deviceScale(2.0));
    try std.testing.expectEqual(@as(f32, 1.0), deviceScale(3.0));
}

test "automatic scale never falls below 1x" {
    const reports = [_]f32{ -2.0, 0.0, 0.75, 1.0, 1.25, 2.0, 4.0, std.math.nan(f32) };
    for (reports) |report| try std.testing.expect(deviceScale(report) >= AUTO_MIN_SCALE);
}

test "config restore upgrades old Auto values but preserves manual density" {
    try std.testing.expectEqual(@as(f32, 1.0), restoredScale(true, 0.68));
    try std.testing.expectEqual(@as(f32, 1.0), restoredScale(true, 0.8));
    try std.testing.expectEqual(@as(f32, 0.6), restoredScale(false, 0.6));
    try std.testing.expectEqual(@as(f32, 1.3), restoredScale(false, 1.3));
}

test "enabling automatic scale immediately clears a sub-1x manual scale" {
    try std.testing.expectEqual(@as(f32, 1.0), scaleAfterAutoToggle(true, 0.6));
    try std.testing.expect(scaleAfterAutoToggle(true, 0.6) >= AUTO_MIN_SCALE);
    try std.testing.expectEqual(@as(f32, 0.6), scaleAfterAutoToggle(false, 0.6));
}

test "deviceScale rejects bogus display reports" {
    try std.testing.expectEqual(@as(f32, 1.0), deviceScale(0));
    try std.testing.expectEqual(@as(f32, 1.0), deviceScale(-2.0));
    try std.testing.expectEqual(@as(f32, 1.0), deviceScale(std.math.nan(f32)));
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

    // Adaptive 1.0×: a 700pt window must reach the mobile layout.
    try std.testing.expect(isCompact(700.0, 1.0));
    try std.testing.expect(isNarrow(700.0, 1.0));

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
