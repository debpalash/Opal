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

/// Device-aware default ui_scale for a display whose DPI content scale is
/// `natural_scale`. Denser on high-DPI, readable-safe on standard-DPI.
pub fn deviceScale(natural_scale: f32) f32 {
    // Tiers are ~20% below a 1× baseline — the user runs Opal deliberately
    // compact (see the compact type ramp); the chrome should stay quiet.
    if (!std.math.isFinite(natural_scale) or natural_scale <= 0) return 0.8;
    if (natural_scale >= 1.9) return 0.68; // Retina / 200% (macOS, hi-res Win/Linux)
    if (natural_scale >= 1.4) return 0.72; // ~150% displays
    if (natural_scale >= 1.15) return 0.76; // ~125% displays
    return 0.8; // standard DPI — floor for readability at 1 logical px = 1 physical
}

test "deviceScale is denser on high-DPI, readable on standard-DPI" {
    try std.testing.expectEqual(@as(f32, 0.68), deviceScale(2.0)); // Mac Retina
    try std.testing.expectEqual(@as(f32, 0.68), deviceScale(3.0)); // very high-DPI clamps to densest tier
    try std.testing.expectEqual(@as(f32, 0.72), deviceScale(1.5)); // 150% Windows
    try std.testing.expectEqual(@as(f32, 0.76), deviceScale(1.25)); // 125% Windows
    try std.testing.expectEqual(@as(f32, 0.8), deviceScale(1.0)); // standard DPI Linux/Win
}

test "deviceScale rejects bogus display reports" {
    try std.testing.expectEqual(@as(f32, 0.8), deviceScale(0));
    try std.testing.expectEqual(@as(f32, 0.8), deviceScale(-2.0));
    try std.testing.expectEqual(@as(f32, 0.8), deviceScale(std.math.nan(f32)));
}

test "clampScale keeps values in the usable band" {
    try std.testing.expectEqual(@as(f32, 0.8), clampScale(0.8));
    try std.testing.expectEqual(MIN_SCALE, clampScale(0.1));
    try std.testing.expectEqual(MAX_SCALE, clampScale(5.0));
    try std.testing.expectEqual(@as(f32, 1.0), clampScale(std.math.nan(f32)));
}
