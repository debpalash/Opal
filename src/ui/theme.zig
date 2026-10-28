const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");

// ══════════════════════════════════════════════════════════
// Opal Global Theming System
// ══════════════════════════════════════════════════════════
// Supports multiple theme presets with hot-switching.
// All colors/dims flow from `active` — a single source of truth.
// UI code uses `theme.colors.*` and `theme.dims.*` which are
// resolved at runtime from the active preset.
// ══════════════════════════════════════════════════════════

pub const ThemePreset = enum(u8) {
    midnight, // Cool slate, cyan accent (default)
    abyss, // Pure black AMOLED, neon green accent
    phantom, // Purple-tinted, violet accent
    nord, // Nord palette, frost blue accent
    solarized, // Solarized dark, orange accent
    rose, // Dark rose, pink accent
    ember, // Dark warm, amber/orange accent
};

/// Complete color palette for a theme (design tokens — runtime resolved per preset).
///
/// Surface ladder (each step is a distinct, perceptually even lift):
///   bg_deep < bg_app < bg_surface < bg_pressed < bg_elevated < bg_hover
/// Raised controls rest on bg_elevated, lift to bg_hover under the pointer and
/// sink to bg_pressed while held. bg_selected is an accent-tinted opaque fill
/// for the chosen row/segment, so text contrast can be verified per preset.
pub const ThemeColors = struct {
    // Background tiers — lowest to highest elevation
    bg_deep: dvui.Color, // app frame (darkest)
    bg_app: dvui.Color,
    bg_surface: dvui.Color, // drawers, cards, panels
    bg_pressed: dvui.Color, // held state of raised controls
    bg_elevated: dvui.Color, // floating panels, buttons, inputs (rest)
    bg_hover: dvui.Color, // hover state — one step above bg_elevated
    bg_selected: dvui.Color, // selected row / active segment (accent-tinted)

    // Border tiers — subtle to strong (translucent white hairlines)
    border_subtle: dvui.Color,
    border_strong: dvui.Color,

    // Glass overlays — genuinely translucent (video shows through); use for
    // surfaces that float over media, e.g. the player control bar.
    bg_glass: dvui.Color,
    overlay: dvui.Color, // modal backdrop
    scrim: dvui.Color, // lighter backdrop for labels/badges over artwork

    // Accent tiers
    accent: dvui.Color,
    accent_hover: dvui.Color, // accent fill under the pointer
    accent_pressed: dvui.Color, // accent fill while held
    accent_dim: dvui.Color, // 25% accent tint
    accent_glow: dvui.Color, // 20% accent halo
    focus_ring: dvui.Color, // keyboard focus outline (>=3:1 on surfaces)

    // Text tiers — primary to tertiary, plus on-accent
    text_primary: dvui.Color,
    text_secondary: dvui.Color,
    text_tertiary: dvui.Color,
    text_on_accent: dvui.Color,

    // Semantic colors: fg (text/icon), *_bg (opaque banner/pill fill that keeps
    // the fg at >=4.5:1), *_dim (translucent tint for hover washes).
    danger: dvui.Color,
    danger_bg: dvui.Color,
    danger_dim: dvui.Color,
    success: dvui.Color,
    success_bg: dvui.Color,
    success_dim: dvui.Color,
    warning: dvui.Color,
    warning_bg: dvui.Color,
    warning_dim: dvui.Color,

    // Drop-shadow tint for elevation (see `elevation`).
    shadow: dvui.Color,
};

// ── Theme Presets ──
// Every text tier clears 4.5:1 on every opaque surface (incl. bg_hover,
// bg_selected, bg_pressed); text_on_accent clears 4.5:1 on accent and its
// hover/pressed fills; accent + focus_ring clear 3:1 on bg_surface; semantic
// fg clears 4.5:1 on its *_bg. Enforced at comptime below (theme_pure) and by
// tests/features/test_theming.py.

const midnight_colors = ThemeColors{
    .bg_deep = .{ .r = 9, .g = 10, .b = 14, .a = 255 },
    .bg_app = .{ .r = 13, .g = 14, .b = 20, .a = 255 },
    .bg_surface = .{ .r = 20, .g = 21, .b = 29, .a = 255 },
    .bg_pressed = .{ .r = 24, .g = 26, .b = 34, .a = 255 },
    .bg_elevated = .{ .r = 29, .g = 31, .b = 41, .a = 255 },
    .bg_hover = .{ .r = 38, .g = 40, .b = 53, .a = 255 },
    .bg_selected = .{ .r = 39, .g = 59, .b = 75, .a = 255 },
    .border_subtle = .{ .r = 255, .g = 255, .b = 255, .a = 16 },
    .border_strong = .{ .r = 255, .g = 255, .b = 255, .a = 30 },
    .bg_glass = .{ .r = 12, .g = 12, .b = 17, .a = 160 },
    .overlay = .{ .r = 0, .g = 0, .b = 0, .a = 170 },
    .scrim = .{ .r = 0, .g = 0, .b = 0, .a = 120 },
    .accent = .{ .r = 93, .g = 208, .b = 255, .a = 255 },
    .accent_hover = .{ .r = 112, .g = 214, .b = 255, .a = 255 },
    .accent_pressed = .{ .r = 82, .g = 183, .b = 224, .a = 255 },
    .accent_dim = .{ .r = 93, .g = 208, .b = 255, .a = 64 },
    .accent_glow = .{ .r = 93, .g = 208, .b = 255, .a = 51 },
    .focus_ring = .{ .r = 129, .g = 218, .b = 255, .a = 255 },
    .text_primary = .{ .r = 246, .g = 247, .b = 250, .a = 255 },
    .text_secondary = .{ .r = 172, .g = 175, .b = 189, .a = 255 },
    .text_tertiary = .{ .r = 159, .g = 162, .b = 177, .a = 255 },
    .text_on_accent = .{ .r = 9, .g = 10, .b = 14, .a = 255 },
    .danger = .{ .r = 255, .g = 112, .b = 140, .a = 255 },
    .danger_bg = .{ .r = 47, .g = 28, .b = 37, .a = 255 },
    .danger_dim = .{ .r = 255, .g = 112, .b = 140, .a = 40 },
    .success = .{ .r = 96, .g = 226, .b = 156, .a = 255 },
    .success_bg = .{ .r = 25, .g = 44, .b = 39, .a = 255 },
    .success_dim = .{ .r = 96, .g = 226, .b = 156, .a = 40 },
    .warning = .{ .r = 255, .g = 204, .b = 102, .a = 255 },
    .warning_bg = .{ .r = 47, .g = 41, .b = 31, .a = 255 },
    .warning_dim = .{ .r = 255, .g = 204, .b = 102, .a = 40 },
    .shadow = .{ .r = 0, .g = 0, .b = 0, .a = 150 },
};

const abyss_colors = ThemeColors{
    .bg_deep = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .bg_app = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .bg_surface = .{ .r = 11, .g = 11, .b = 12, .a = 255 },
    .bg_pressed = .{ .r = 16, .g = 16, .b = 17, .a = 255 },
    .bg_elevated = .{ .r = 22, .g = 22, .b = 24, .a = 255 },
    .bg_hover = .{ .r = 32, .g = 32, .b = 35, .a = 255 },
    .bg_selected = .{ .r = 29, .g = 51, .b = 43, .a = 255 },
    .border_subtle = .{ .r = 255, .g = 255, .b = 255, .a = 16 },
    .border_strong = .{ .r = 255, .g = 255, .b = 255, .a = 30 },
    .bg_glass = .{ .r = 0, .g = 0, .b = 0, .a = 160 },
    .overlay = .{ .r = 0, .g = 0, .b = 0, .a = 170 },
    .scrim = .{ .r = 0, .g = 0, .b = 0, .a = 120 },
    .accent = .{ .r = 64, .g = 206, .b = 142, .a = 255 },
    .accent_hover = .{ .r = 87, .g = 212, .b = 156, .a = 255 },
    .accent_pressed = .{ .r = 56, .g = 181, .b = 125, .a = 255 },
    .accent_dim = .{ .r = 64, .g = 206, .b = 142, .a = 64 },
    .accent_glow = .{ .r = 64, .g = 206, .b = 142, .a = 51 },
    .focus_ring = .{ .r = 106, .g = 217, .b = 167, .a = 255 },
    .text_primary = .{ .r = 228, .g = 228, .b = 230, .a = 255 },
    .text_secondary = .{ .r = 160, .g = 160, .b = 165, .a = 255 },
    .text_tertiary = .{ .r = 150, .g = 150, .b = 155, .a = 255 },
    .text_on_accent = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .danger = .{ .r = 236, .g = 100, .b = 100, .a = 255 },
    .danger_bg = .{ .r = 33, .g = 14, .b = 14, .a = 255 },
    .danger_dim = .{ .r = 236, .g = 100, .b = 100, .a = 40 },
    .success = .{ .r = 84, .g = 204, .b = 132, .a = 255 },
    .success_bg = .{ .r = 12, .g = 29, .b = 18, .a = 255 },
    .success_dim = .{ .r = 84, .g = 204, .b = 132, .a = 40 },
    .warning = .{ .r = 228, .g = 186, .b = 72, .a = 255 },
    .warning_bg = .{ .r = 32, .g = 26, .b = 10, .a = 255 },
    .warning_dim = .{ .r = 228, .g = 186, .b = 72, .a = 40 },
    .shadow = .{ .r = 0, .g = 0, .b = 0, .a = 150 },
};

const phantom_colors = ThemeColors{
    .bg_deep = .{ .r = 11, .g = 8, .b = 19, .a = 255 },
    .bg_app = .{ .r = 17, .g = 13, .b = 27, .a = 255 },
    .bg_surface = .{ .r = 26, .g = 20, .b = 40, .a = 255 },
    .bg_pressed = .{ .r = 31, .g = 24, .b = 48, .a = 255 },
    .bg_elevated = .{ .r = 38, .g = 30, .b = 58, .a = 255 },
    .bg_hover = .{ .r = 50, .g = 40, .b = 74, .a = 255 },
    .bg_selected = .{ .r = 58, .g = 49, .b = 88, .a = 255 },
    .border_subtle = .{ .r = 255, .g = 255, .b = 255, .a = 16 },
    .border_strong = .{ .r = 255, .g = 255, .b = 255, .a = 30 },
    .bg_glass = .{ .r = 10, .g = 6, .b = 18, .a = 160 },
    .overlay = .{ .r = 8, .g = 4, .b = 16, .a = 170 },
    .scrim = .{ .r = 8, .g = 4, .b = 16, .a = 120 },
    .accent = .{ .r = 166, .g = 146, .b = 246, .a = 255 },
    .accent_hover = .{ .r = 177, .g = 159, .b = 247, .a = 255 },
    .accent_pressed = .{ .r = 146, .g = 128, .b = 216, .a = 255 },
    .accent_dim = .{ .r = 166, .g = 146, .b = 246, .a = 64 },
    .accent_glow = .{ .r = 166, .g = 146, .b = 246, .a = 51 },
    .focus_ring = .{ .r = 186, .g = 170, .b = 248, .a = 255 },
    .text_primary = .{ .r = 238, .g = 234, .b = 250, .a = 255 },
    .text_secondary = .{ .r = 180, .g = 170, .b = 204, .a = 255 },
    .text_tertiary = .{ .r = 165, .g = 156, .b = 189, .a = 255 },
    .text_on_accent = .{ .r = 11, .g = 8, .b = 19, .a = 255 },
    .danger = .{ .r = 240, .g = 120, .b = 140, .a = 255 },
    .danger_bg = .{ .r = 48, .g = 28, .b = 43, .a = 255 },
    .danger_dim = .{ .r = 240, .g = 120, .b = 140, .a = 40 },
    .success = .{ .r = 96, .g = 212, .b = 150, .a = 255 },
    .success_bg = .{ .r = 28, .g = 41, .b = 44, .a = 255 },
    .success_dim = .{ .r = 96, .g = 212, .b = 150, .a = 40 },
    .warning = .{ .r = 236, .g = 190, .b = 110, .a = 255 },
    .warning_bg = .{ .r = 48, .g = 38, .b = 39, .a = 255 },
    .warning_dim = .{ .r = 236, .g = 190, .b = 110, .a = 40 },
    .shadow = .{ .r = 4, .g = 2, .b = 10, .a = 150 },
};

const nord_colors = ThemeColors{
    .bg_deep = .{ .r = 36, .g = 41, .b = 51, .a = 255 },
    .bg_app = .{ .r = 46, .g = 52, .b = 64, .a = 255 },
    .bg_surface = .{ .r = 59, .g = 66, .b = 82, .a = 255 },
    .bg_pressed = .{ .r = 63, .g = 70, .b = 87, .a = 255 },
    .bg_elevated = .{ .r = 67, .g = 76, .b = 94, .a = 255 },
    .bg_hover = .{ .r = 76, .g = 86, .b = 106, .a = 255 },
    .bg_selected = .{ .r = 78, .g = 95, .b = 112, .a = 255 },
    .border_subtle = .{ .r = 255, .g = 255, .b = 255, .a = 16 },
    .border_strong = .{ .r = 255, .g = 255, .b = 255, .a = 30 },
    .bg_glass = .{ .r = 36, .g = 42, .b = 54, .a = 160 },
    .overlay = .{ .r = 30, .g = 34, .b = 44, .a = 170 },
    .scrim = .{ .r = 30, .g = 34, .b = 44, .a = 120 },
    .accent = .{ .r = 136, .g = 192, .b = 208, .a = 255 },
    .accent_hover = .{ .r = 150, .g = 200, .b = 214, .a = 255 },
    .accent_pressed = .{ .r = 120, .g = 169, .b = 183, .a = 255 },
    .accent_dim = .{ .r = 136, .g = 192, .b = 208, .a = 64 },
    .accent_glow = .{ .r = 136, .g = 192, .b = 208, .a = 51 },
    .focus_ring = .{ .r = 162, .g = 206, .b = 218, .a = 255 },
    .text_primary = .{ .r = 242, .g = 245, .b = 250, .a = 255 },
    .text_secondary = .{ .r = 216, .g = 222, .b = 233, .a = 255 },
    .text_tertiary = .{ .r = 209, .g = 216, .b = 229, .a = 255 },
    .text_on_accent = .{ .r = 36, .g = 41, .b = 51, .a = 255 },
    .danger = .{ .r = 254, .g = 166, .b = 174, .a = 255 },
    .danger_bg = .{ .r = 73, .g = 65, .b = 77, .a = 255 },
    .danger_dim = .{ .r = 254, .g = 166, .b = 174, .a = 40 },
    .success = .{ .r = 180, .g = 214, .b = 152, .a = 255 },
    .success_bg = .{ .r = 65, .g = 75, .b = 76, .a = 255 },
    .success_dim = .{ .r = 180, .g = 214, .b = 152, .a = 40 },
    .warning = .{ .r = 235, .g = 203, .b = 139, .a = 255 },
    .warning_bg = .{ .r = 72, .g = 73, .b = 74, .a = 255 },
    .warning_dim = .{ .r = 235, .g = 203, .b = 139, .a = 40 },
    .shadow = .{ .r = 18, .g = 21, .b = 28, .a = 150 },
};

const solarized_colors = ThemeColors{
    .bg_deep = .{ .r = 0, .g = 34, .b = 43, .a = 255 },
    .bg_app = .{ .r = 0, .g = 43, .b = 54, .a = 255 },
    .bg_surface = .{ .r = 7, .g = 54, .b = 66, .a = 255 },
    .bg_pressed = .{ .r = 11, .g = 59, .b = 72, .a = 255 },
    .bg_elevated = .{ .r = 16, .g = 66, .b = 80, .a = 255 },
    .bg_hover = .{ .r = 26, .g = 78, .b = 93, .a = 255 },
    .bg_selected = .{ .r = 51, .g = 74, .b = 76, .a = 255 },
    .border_subtle = .{ .r = 255, .g = 255, .b = 255, .a = 16 },
    .border_strong = .{ .r = 255, .g = 255, .b = 255, .a = 30 },
    .bg_glass = .{ .r = 0, .g = 36, .b = 46, .a = 160 },
    .overlay = .{ .r = 0, .g = 20, .b = 28, .a = 170 },
    .scrim = .{ .r = 0, .g = 20, .b = 28, .a = 120 },
    .accent = .{ .r = 232, .g = 116, .b = 56, .a = 255 },
    .accent_hover = .{ .r = 235, .g = 133, .b = 80, .a = 255 },
    .accent_pressed = .{ .r = 204, .g = 102, .b = 49, .a = 255 },
    .accent_dim = .{ .r = 232, .g = 116, .b = 56, .a = 64 },
    .accent_glow = .{ .r = 232, .g = 116, .b = 56, .a = 51 },
    .focus_ring = .{ .r = 237, .g = 147, .b = 100, .a = 255 },
    .text_primary = .{ .r = 238, .g = 232, .b = 213, .a = 255 },
    .text_secondary = .{ .r = 186, .g = 196, .b = 196, .a = 255 },
    .text_tertiary = .{ .r = 172, .g = 186, .b = 188, .a = 255 },
    .text_on_accent = .{ .r = 0, .g = 30, .b = 38, .a = 255 },
    .danger = .{ .r = 255, .g = 132, .b = 126, .a = 255 },
    .danger_bg = .{ .r = 34, .g = 52, .b = 61, .a = 255 },
    .danger_dim = .{ .r = 255, .g = 132, .b = 126, .a = 40 },
    .success = .{ .r = 176, .g = 196, .b = 60, .a = 255 },
    .success_bg = .{ .r = 25, .g = 64, .b = 55, .a = 255 },
    .success_dim = .{ .r = 176, .g = 196, .b = 60, .a = 40 },
    .warning = .{ .r = 226, .g = 180, .b = 48, .a = 255 },
    .warning_bg = .{ .r = 32, .g = 62, .b = 53, .a = 255 },
    .warning_dim = .{ .r = 226, .g = 180, .b = 48, .a = 40 },
    .shadow = .{ .r = 0, .g = 14, .b = 20, .a = 150 },
};

const rose_colors = ThemeColors{
    .bg_deep = .{ .r = 13, .g = 7, .b = 12, .a = 255 },
    .bg_app = .{ .r = 19, .g = 11, .b = 17, .a = 255 },
    .bg_surface = .{ .r = 30, .g = 18, .b = 27, .a = 255 },
    .bg_pressed = .{ .r = 36, .g = 22, .b = 33, .a = 255 },
    .bg_elevated = .{ .r = 44, .g = 27, .b = 40, .a = 255 },
    .bg_hover = .{ .r = 57, .g = 36, .b = 52, .a = 255 },
    .bg_selected = .{ .r = 74, .g = 44, .b = 62, .a = 255 },
    .border_subtle = .{ .r = 255, .g = 255, .b = 255, .a = 16 },
    .border_strong = .{ .r = 255, .g = 255, .b = 255, .a = 30 },
    .bg_glass = .{ .r = 12, .g = 6, .b = 12, .a = 160 },
    .overlay = .{ .r = 12, .g = 4, .b = 10, .a = 170 },
    .scrim = .{ .r = 12, .g = 4, .b = 10, .a = 120 },
    .accent = .{ .r = 234, .g = 134, .b = 180, .a = 255 },
    .accent_hover = .{ .r = 237, .g = 149, .b = 189, .a = 255 },
    .accent_pressed = .{ .r = 206, .g = 118, .b = 158, .a = 255 },
    .accent_dim = .{ .r = 234, .g = 134, .b = 180, .a = 64 },
    .accent_glow = .{ .r = 234, .g = 134, .b = 180, .a = 51 },
    .focus_ring = .{ .r = 239, .g = 161, .b = 196, .a = 255 },
    .text_primary = .{ .r = 246, .g = 236, .b = 243, .a = 255 },
    .text_secondary = .{ .r = 196, .g = 166, .b = 184, .a = 255 },
    .text_tertiary = .{ .r = 177, .g = 151, .b = 167, .a = 255 },
    .text_on_accent = .{ .r = 13, .g = 7, .b = 12, .a = 255 },
    .danger = .{ .r = 246, .g = 110, .b = 120, .a = 255 },
    .danger_bg = .{ .r = 51, .g = 25, .b = 31, .a = 255 },
    .danger_dim = .{ .r = 246, .g = 110, .b = 120, .a = 40 },
    .success = .{ .r = 100, .g = 206, .b = 166, .a = 255 },
    .success_bg = .{ .r = 30, .g = 38, .b = 38, .a = 255 },
    .success_dim = .{ .r = 100, .g = 206, .b = 166, .a = 40 },
    .warning = .{ .r = 234, .g = 186, .b = 110, .a = 255 },
    .warning_bg = .{ .r = 49, .g = 36, .b = 30, .a = 255 },
    .warning_dim = .{ .r = 234, .g = 186, .b = 110, .a = 40 },
    .shadow = .{ .r = 6, .g = 2, .b = 6, .a = 150 },
};

const ember_colors = ThemeColors{
    .bg_deep = .{ .r = 14, .g = 10, .b = 7, .a = 255 },
    .bg_app = .{ .r = 21, .g = 15, .b = 11, .a = 255 },
    .bg_surface = .{ .r = 33, .g = 24, .b = 17, .a = 255 },
    .bg_pressed = .{ .r = 39, .g = 29, .b = 21, .a = 255 },
    .bg_elevated = .{ .r = 47, .g = 35, .b = 26, .a = 255 },
    .bg_hover = .{ .r = 61, .g = 46, .b = 35, .a = 255 },
    .bg_selected = .{ .r = 77, .g = 54, .b = 33, .a = 255 },
    .border_subtle = .{ .r = 255, .g = 255, .b = 255, .a = 16 },
    .border_strong = .{ .r = 255, .g = 255, .b = 255, .a = 30 },
    .bg_glass = .{ .r = 14, .g = 10, .b = 6, .a = 160 },
    .overlay = .{ .r = 10, .g = 6, .b = 4, .a = 170 },
    .scrim = .{ .r = 10, .g = 6, .b = 4, .a = 120 },
    .accent = .{ .r = 236, .g = 154, .b = 72, .a = 255 },
    .accent_hover = .{ .r = 238, .g = 166, .b = 94, .a = 255 },
    .accent_pressed = .{ .r = 208, .g = 136, .b = 63, .a = 255 },
    .accent_dim = .{ .r = 236, .g = 154, .b = 72, .a = 64 },
    .accent_glow = .{ .r = 236, .g = 154, .b = 72, .a = 51 },
    .focus_ring = .{ .r = 240, .g = 176, .b = 112, .a = 255 },
    .text_primary = .{ .r = 246, .g = 234, .b = 216, .a = 255 },
    .text_secondary = .{ .r = 198, .g = 174, .b = 144, .a = 255 },
    .text_tertiary = .{ .r = 181, .g = 163, .b = 139, .a = 255 },
    .text_on_accent = .{ .r = 14, .g = 10, .b = 7, .a = 255 },
    .danger = .{ .r = 240, .g = 118, .b = 108, .a = 255 },
    .danger_bg = .{ .r = 52, .g = 29, .b = 25, .a = 255 },
    .danger_dim = .{ .r = 240, .g = 118, .b = 108, .a = 40 },
    .success = .{ .r = 110, .g = 204, .b = 140, .a = 255 },
    .success_bg = .{ .r = 33, .g = 41, .b = 29, .a = 255 },
    .success_dim = .{ .r = 110, .g = 204, .b = 140, .a = 40 },
    .warning = .{ .r = 232, .g = 196, .b = 82, .a = 255 },
    .warning_bg = .{ .r = 51, .g = 40, .b = 21, .a = 255 },
    .warning_dim = .{ .r = 232, .g = 196, .b = 82, .a = 40 },
    .shadow = .{ .r = 6, .g = 4, .b = 2, .a = 150 },
};

// ── Active Theme State ──

pub var active_preset: ThemePreset = .midnight;

pub fn getThemeColors(preset: ThemePreset) ThemeColors {
    return switch (preset) {
        .midnight => midnight_colors,
        .abyss => abyss_colors,
        .phantom => phantom_colors,
        .nord => nord_colors,
        .solarized => solarized_colors,
        .rose => rose_colors,
        .ember => ember_colors,
    };
}

// Compile-time contrast gate: a palette edit that drops any shipped pair below
// its WCAG threshold fails the build instead of shipping unreadable text.
comptime {
    @setEvalBranchQuota(200_000);
    const tp = @import("theme_pure.zig");
    for (std.enums.values(ThemePreset)) |p| {
        const c = getThemeColors(p);
        const surfaces = [_]dvui.Color{ c.bg_app, c.bg_surface, c.bg_pressed, c.bg_elevated, c.bg_hover, c.bg_selected };
        for ([_]dvui.Color{ c.text_primary, c.text_secondary, c.text_tertiary }) |fg| {
            for (surfaces) |bg| tp.assertContrast(rgb(fg), rgb(bg), tp.min_text);
        }
        for ([_]dvui.Color{ c.accent, c.accent_hover, c.accent_pressed }) |bg| tp.assertContrast(rgb(c.text_on_accent), rgb(bg), tp.min_text);
        tp.assertContrast(rgb(c.accent), rgb(c.bg_surface), tp.min_ui);
        tp.assertContrast(rgb(c.focus_ring), rgb(c.bg_surface), tp.min_ui);
        tp.assertContrast(rgb(c.danger), rgb(c.danger_bg), tp.min_text);
        tp.assertContrast(rgb(c.success), rgb(c.success_bg), tp.min_text);
        tp.assertContrast(rgb(c.warning), rgb(c.warning_bg), tp.min_text);
        tp.assertLadder(&.{ rgb(c.bg_app), rgb(c.bg_surface), rgb(c.bg_pressed), rgb(c.bg_elevated), rgb(c.bg_hover) });
    }
}

fn rgb(c: dvui.Color) @import("theme_pure.zig").Rgb {
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

pub fn presetName(preset: ThemePreset) []const u8 {
    return switch (preset) {
        .midnight => "Midnight",
        .abyss => "Abyss",
        .phantom => "Phantom",
        .nord => "Nord",
        .solarized => "Solarized",
        .rose => "Rosé",
        .ember => "Ember",
    };
}

/// Runtime-resolved colors (always use these in UI code)
pub var colors: ThemeColors = midnight_colors;

/// Player-only glass keeps the active theme's dark tint while allowing the
/// moving image to remain dominant beneath navigation and transport chrome.
/// The SDL2 backend has no region backdrop-blur primitive, so player surfaces
/// pair this low-opacity tint with feathered edge scrims instead of filtering
/// and re-uploading parts of every video frame.
pub fn playerGlass(alpha: u8) dvui.Color {
    var glass = colors.bg_glass;
    glass.a = alpha;
    return glass;
}

/// Neutral player ink stays readable over every video frame and does not pick
/// up deliberately muted theme text colors.
pub const player_text: dvui.Color = .{ .r = 247, .g = 244, .b = 239, .a = 255 };
pub const player_text_muted: dvui.Color = .{ .r = 218, .g = 214, .b = 207, .a = 255 };
pub const player_icon_outline: dvui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 235 };

/// Switch to a new theme preset at runtime
pub fn setPreset(preset: ThemePreset) void {
    active_preset = preset;
    colors = getThemeColors(preset);
    applyToDvui();
    state.markConfigDirty();
}

/// Cycle to next theme
pub fn cycleTheme() void {
    const next = @intFromEnum(active_preset) +% 1;
    const preset: ThemePreset = if (next > @intFromEnum(ThemePreset.ember))
        .midnight
    else
        @enumFromInt(next);
    setPreset(preset);
}

// ── Icon Sizing System ──

pub const IconSize = enum {
    xs, // 12px — inline badges
    sm, // 16px — buttons, labels
    md, // 20px — standard icons
    lg, // 24px — headers
    xl, // 32px — hero elements
    hero, // 48px — empty-state glyphs
};

pub fn iconSize(s: IconSize) dvui.Size {
    return switch (s) {
        .xs => .{ .w = 12, .h = 12 },
        .sm => .{ .w = 16, .h = 16 },
        .md => .{ .w = 20, .h = 20 },
        .lg => .{ .w = 24, .h = 24 },
        .xl => .{ .w = 32, .h = 32 },
        .hero => .{ .w = 48, .h = 48 },
    };
}

/// Clamp a preferred dialog/overlay size to the live content area while
/// retaining a useful floor whenever that floor actually fits. On genuinely
/// smaller windows, fitting on-screen wins over the nominal minimum.
pub fn fitWindowSize(preferred: dvui.Size, minimum: dvui.Size) dvui.Size {
    const wr = dvui.windowRect();
    if (wr.w <= 1 or wr.h <= 1) return preferred;
    const scale = if (std.math.isFinite(state.app.ui_scale) and state.app.ui_scale > 0) state.app.ui_scale else 1.0;
    const avail_w = @max(1.0, wr.w / scale - 24.0);
    const avail_h = @max(1.0, wr.h / scale - 24.0);
    return .{
        .w = if (avail_w >= minimum.w) @max(minimum.w, @min(preferred.w, avail_w)) else avail_w,
        .h = if (avail_h >= minimum.h) @max(minimum.h, @min(preferred.h, avail_h)) else avail_h,
    };
}

// ── Spacing tokens — 4px-based scale ──

pub const spacing = struct {
    pub const xxs: f32 = 2; // hairline gaps: icon-to-badge, stacked meta lines
    pub const xs: f32 = 4;
    pub const sm: f32 = 8;
    pub const md: f32 = 12;
    pub const lg: f32 = 16;
    pub const xl: f32 = 24;
    pub const xxl: f32 = 32;
    pub const xxxl: f32 = 48; // hero/empty-state breathing room
};

// ── Radius tokens — corner radii ──
//
// Softer scale (was 2/3/6/8/12). Rule of thumb: controls (buttons, inputs,
// segments, rows) = sm; cards/posters/tooltips = md; floating bars, dialogs,
// popovers = lg; hero sheets = xl. Nested shapes use one step smaller than
// their container so inner/outer curves stay concentric.
pub const radius = struct {
    pub const xs: f32 = 3;
    pub const sm: f32 = 5;
    pub const md: f32 = 7;
    pub const lg: f32 = 10;
    pub const xl: f32 = 14;
    pub const pill: f32 = 999;
};

// ── Font size tokens — type ramp ──
//
// COMPACT ramp in dvui logical units (dvui's own default body is 10; the
// backend multiplies by the display's content scale). Most of the app used to
// render at the dvui default 10 while components.zig used 13 — two visibly
// different "body" sizes side by side. Unified DOWN to the compact end: a
// media player's chrome should stay quiet at 1× scale.
pub const font_size = struct {
    pub const micro: f32 = 9;
    pub const small: f32 = 10;
    pub const body: f32 = 11;
    pub const subtitle: f32 = 13; // card titles, dialog subheads
    pub const title: f32 = 15; // section/page headings (dvui font_heading)
    pub const headline: f32 = 18; // detail-page titles
    pub const display: f32 = 22; // hero titles (dvui font_title)
};

/// Line-height ratios for multi-line text (dvui.Font.line_height_factor).
pub const line_height = struct {
    pub const tight: f32 = 1.15; // headings, single-line chips
    pub const normal: f32 = 1.3; // body / labels
    pub const relaxed: f32 = 1.5; // long-form reading (descriptions, novels)
};

// Noto Sans replaces dvui's Bitstream Vera fallback for application text.
// Vera's small-size metrics are visibly uneven at modern 1.25×/1.5×
// compositor scales. Noto's hinted TrueType outlines stay crisp with dvui's
// pixel snapping and cover the multilingual media metadata Opal renders.
// Regular + bold are distinct sources so headings use real outlines rather
// than a synthetic weight.
const app_font_family = "Noto Sans";
/// Family of the terminal font (Hack). Used by the embedded terminal.
pub const mono_font_family = "Hack";
const app_font_sources = [_]dvui.Font.Source{
    .{ .family = dvui.Font.array("Noto Sans CJK"), .bytes = @embedFile("../assets/fonts/NotoSansKR-Regular.ttf") },
    .{
        .family = dvui.Font.array(app_font_family),
        .bytes = @embedFile("../assets/fonts/NotoSans-Regular.ttf"),
    },
    .{
        .family = dvui.Font.array(app_font_family),
        .weight = .bold,
        .bytes = @embedFile("../assets/fonts/NotoSans-Bold.ttf"),
    },
    // Monospace faces for the embedded terminal (box drawing and block
    // elements that terminal UIs rely on).
    .{ .family = dvui.Font.array(mono_font_family), .bytes = @embedFile("../assets/fonts/Hack-Regular.ttf") },
    .{ .family = dvui.Font.array(mono_font_family), .weight = .bold, .bytes = @embedFile("../assets/fonts/Hack-Bold.ttf") },
    .{ .family = dvui.Font.array(mono_font_family), .style = .italic, .bytes = @embedFile("../assets/fonts/Hack-Italic.ttf") },
    .{ .family = dvui.Font.array(mono_font_family), .weight = .bold, .style = .italic, .bytes = @embedFile("../assets/fonts/Hack-BoldItalic.ttf") },
};

/// Keep theme metrics/colors; use the lazy CJK face only for matching titles.
pub fn mediaTitleFont(text: []const u8, base: dvui.Font) dvui.Font {
    if (!@import("footer_pure.zig").needsCjkFont(text)) return base;
    return base.withFamily("Noto Sans CJK").withWeight(.normal);
}

// ── Dimensions (legacy dvui.Rect helpers) ──

pub const dims = struct {
    pub const rad_sm = dvui.Rect.all(radius.sm);
    pub const rad_md = dvui.Rect.all(radius.md);
    pub const rad_lg = dvui.Rect.all(radius.lg);
    pub const rad_xl = dvui.Rect.all(radius.xl);

    pub const pad_xs = dvui.Rect.all(spacing.xs);
    pub const pad_sm = dvui.Rect.all(spacing.sm);
    pub const pad_md = dvui.Rect.all(spacing.md);
    pub const pad_lg = dvui.Rect.all(spacing.lg);
};

// ── Shadow token — soft drop shadow for elevated surfaces ──
//
// Legacy constant kept for existing call sites; prefer `elevation.*()` which
// tints the shadow per preset and fixes offset/fade per tier.
pub const shadow_soft: dvui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 160 };

// ── Elevation tokens — box shadows per tier (dvui Options.box_shadow) ──
//
// sm: resting cards / raised chips. md: popovers, toasts, floating bars.
// lg: dialogs and sheets. Colors read per frame from the active preset.
pub const elevation = struct {
    pub fn sm() dvui.Options.BoxShadow {
        return .{ .color = colors.shadow, .offset = .{ .x = 0, .y = 1 }, .fade = 6, .alpha = 0.35 };
    }
    pub fn md() dvui.Options.BoxShadow {
        return .{ .color = colors.shadow, .offset = .{ .x = 0, .y = 4 }, .fade = 16, .alpha = 0.5 };
    }
    pub fn lg() dvui.Options.BoxShadow {
        return .{ .color = colors.shadow, .offset = .{ .x = 0, .y = 10 }, .fade = 28, .alpha = 0.6 };
    }
};

// ── Letterbox — the fill behind video, and the one colour that is NOT themed ──
//
// Deliberately pure black in every preset, not `bg_deep`: a video that does not
// fill its cell should read as proper cinematic bars, and the navy app
// background reads as a UI gap instead. Expressed as a token rather than a
// `dvui.Color{…}` literal so grid.zig obeys the "no raw colour literals in
// ui/" rule while keeping the intent visible — this one is meant to stay black
// when the theme changes.
pub const video_letterbox: dvui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

// ── Transparent — the one spelling of "no fill" ──
//
// Ten files each hand-rolled `dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }`
// (six of them behind private `transparent` consts). One shared name keeps the
// genuinely off-token colors visible in a grep.
pub const transparent: dvui.Color = dvui.Color.transparent;

// ── Motion tokens — durations (µs, dvui animation units) + standard curves ──
//
// One source of truth for animation timing so the whole UI moves consistently
// (see dvui.animate / dvui.animation / dvui.easing). Entrances ease-out, exits
// ease-in, positional moves ease-in-out. Durations are deliberately short — a
// polished UI feels responsive, not slow.
pub const motion = struct {
    pub const fast: i32 = 120_000; // hovers, small state flips
    pub const base: i32 = 180_000; // toasts, route crossfade, chrome fade
    pub const slow: i32 = 260_000; // larger reveals / staggered entrances
    pub const enter: *const dvui.easing.EasingFn = dvui.easing.outQuad;
    pub const exit: *const dvui.easing.EasingFn = dvui.easing.inQuad;
    pub const move: *const dvui.easing.EasingFn = dvui.easing.inOutCubic;
};

var reduced_motion: std.atomic.Value(bool) = .init(false);

pub fn setReducedMotion(enabled: bool) void {
    reduced_motion.store(enabled, .release);
}

/// Keep dvui's animation contract valid while making transitions effectively
/// immediate for viewers who prefer reduced motion.
pub fn motionDuration(normal: i32) i32 {
    return if (reduced_motion.load(.acquire)) 1 else normal;
}

// ── Apply to dvui global ──

/// Set true when applyToDvui() is requested off the UI thread (e.g. config.load
/// on the background worker) or in headless mode; consumed by reapplyIfPending()
/// from appFrame on the UI thread.
var pending_apply: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
// Identity of the UI/render thread, recorded by markUiThread() from appInit/
// appFrame. dvui.current_window is a GLOBAL (not threadlocal), so a null-check
// can't tell "off the UI thread" from "between frames" — a background caller
// could see it non-null mid-frame and corrupt dvui state. Thread identity is
// the reliable gate.
var ui_thread_id: std.atomic.Value(std.Thread.Id) = std.atomic.Value(std.Thread.Id).init(0);
var ui_thread_known: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Record the calling thread as the UI/render thread. Call from appInit (and/or
/// appFrame) — always on the dvui main thread.
pub fn markUiThread() void {
    ui_thread_id.store(std.Thread.getCurrentId(), .release);
    ui_thread_known.store(true, .release);
}

fn onUiThread() bool {
    if (!ui_thread_known.load(.acquire)) return false;
    return std.Thread.getCurrentId() == ui_thread_id.load(.acquire);
}

/// Apply any deferred theme change on the UI thread. Call from appFrame.
pub fn reapplyIfPending() void {
    if (pending_apply.swap(false, .acq_rel)) applyToDvui();
}

fn applyToDvui() void {
    // Headless links no dvui (build.zig Phase S1) and setTheme() is on the
    // server's startup path via coreInit. The onUiThread() guard below already
    // returns here at runtime — comptime makes it so the widget-side theme
    // symbols are never analyzed in the server build. `colors` is still set by
    // the caller, which is all the remote/web side ever reads.
    if (@import("build_options").headless) return;
    // dvui themeGet/themeSet mutate the global current_window's theme and MUST
    // run only on the UI/render thread. config.load() calls setPreset on a
    // background worker; current_window being a GLOBAL means a null-check races
    // (it can be non-null mid-frame), so an off-thread call corrupted dvui and
    // aborted with SIGABRT. Gate on THREAD IDENTITY: off-thread (or pre-first-
    // frame, or headless where no UI thread is ever marked) → defer, and the
    // next appFrame applies it via reapplyIfPending(). `colors` is already set
    // by the caller, so UI rendering uses the new theme immediately; only dvui's
    // built-in palette waits at most one frame.
    if (!onUiThread()) {
        pending_apply.store(true, .release);
        return;
    }
    var t = dvui.themeGet();
    t.dark = true;
    t.text = colors.text_primary;
    t.text_hover = colors.text_primary;
    t.text_press = colors.accent;
    t.fill = colors.bg_app;
    t.fill_hover = colors.bg_hover;
    t.fill_press = colors.bg_pressed;
    t.border = colors.border_subtle;
    // The accent/focus color drives slider fills, focus rings and other dvui
    // built-ins. Without this it stays dvui's default BLUE — which is why the
    // scrubber and volume slider rendered blue instead of the theme accent.
    t.focus = colors.focus_ring;
    // dvui's per-style palettes (.control buttons, .window boxes, .highlight
    // menu items / checkboxes, .err) were left at the Adwaita defaults, so any
    // widget whose options omitted a color — a menu item's hover, a checkbox
    // tick, a button with only color_fill set — painted Adwaita grey/blue
    // instead of the active preset. Map every style onto the preset.
    t.control = .{
        .fill = colors.bg_elevated,
        .fill_hover = colors.bg_hover,
        .fill_press = colors.bg_pressed,
        .text = colors.text_primary,
        .text_press = colors.accent,
        .border = colors.border_subtle,
    };
    t.window = .{
        .fill = colors.bg_surface,
        .text = colors.text_primary,
        .border = colors.border_subtle,
    };
    t.highlight = .{
        .fill = colors.accent,
        .fill_hover = colors.accent_hover,
        .fill_press = colors.accent_pressed,
        .text = colors.text_on_accent,
        .border = colors.accent,
    };
    t.err = .{
        .fill = colors.danger,
        .fill_hover = colors.danger.lighten(8),
        .fill_press = colors.danger.lighten(-8),
        .text = colors.text_on_accent,
        .border = colors.danger,
    };
    // Route dvui's own type ramp through Opal's embedded font + size tokens.
    // Surfaces that
    // use themeGet().font_heading / font_title (home, discovery, settings big
    // titles, compact tab labels) previously rendered on dvui's DEFAULT sizes,
    // disconnected from theme.font_size — two typography systems in one app.
    t.embedded_fonts = &app_font_sources;
    t.font_body = .find(.{ .family = app_font_family, .size = font_size.body });
    t.font_heading = .find(.{ .family = app_font_family, .size = font_size.title, .weight = .bold });
    t.font_title = .find(.{ .family = app_font_family, .size = font_size.display, .weight = .bold });
    dvui.themeSet(t);

    // Keep scroll feedback light: overlay bars are a narrow thumb instead of
    // a chunky track. Individual views control when that thumb is visible.
    dvui.ScrollBarWidget.defaults.min_size_content = .{ .w = 7, .h = 7 };
    dvui.ScrollBarWidget.defaults.background = false;
    dvui.ScrollBarWidget.defaults.border = dvui.Rect.all(0);
    dvui.ScrollBarWidget.defaults.corner_radius = dvui.Rect.all(radius.pill);
}

pub fn setTheme() void {
    colors = getThemeColors(active_preset);
    applyToDvui();
}

// ══════════════════════════════════════════════════════════
// Standard Option Presets (composable)
// ══════════════════════════════════════════════════════════

pub fn optInput() dvui.Options {
    return .{
        .expand = .horizontal,
        .color_fill = colors.bg_elevated,
        .color_border = colors.border_subtle,
        .color_text = colors.text_primary,
        .border = dvui.Rect.all(1),
        .corner_radius = dims.rad_sm,
    };
}

/// Danger icon button (red)
pub fn optIconBtnDanger() dvui.Options {
    return .{
        .color_text = colors.danger,
        .color_fill = transparent,
        // Transparent fills defeat dvui's derived hover/press states (lighten
        // preserves alpha 0), so destructive icon buttons gave zero pointer
        // feedback — spell the states out with a faint danger tint.
        .color_fill_hover = colors.danger_dim,
        .color_fill_press = colors.danger.opacity(0.28),
        .border = dvui.Rect.all(0),
    };
}

/// Subtle horizontal divider
pub fn optDivider() dvui.Options {
    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = colors.border_subtle,
        .min_size_content = .{ .w = 10, .h = 1 },
        .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 },
    };
}
