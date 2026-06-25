const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");

// ══════════════════════════════════════════════════════════
// ZigZag Global Theming System
// ══════════════════════════════════════════════════════════
// Supports multiple theme presets with hot-switching.
// All colors/dims flow from `active` — a single source of truth.
// UI code uses `theme.colors.*` and `theme.dims.*` which are
// resolved at runtime from the active preset.
// ══════════════════════════════════════════════════════════

pub const ThemePreset = enum(u8) {
    midnight,       // Cool slate, cyan accent (default)
    abyss,          // Pure black AMOLED, neon green accent
    phantom,        // Purple-tinted, violet accent
    nord,           // Nord palette, frost blue accent
    solarized,      // Solarized dark, orange accent
    rose,           // Dark rose, pink accent
    ember,          // Dark warm, amber/orange accent
};

/// Complete color palette for a theme (design tokens — runtime resolved per preset)
pub const ThemeColors = struct {
    // Background tiers — lowest to highest elevation
    bg_deep:         dvui.Color,  // app frame (darkest)
    bg_app:          dvui.Color,
    bg_header:       dvui.Color,
    bg_muted:        dvui.Color,  // empty states
    bg_drawer:       dvui.Color,
    bg_surface:      dvui.Color,  // drawers, cards
    bg_card:         dvui.Color,
    bg_card_hover:   dvui.Color,
    bg_hover:        dvui.Color,  // generic hover state
    bg_elevated:     dvui.Color,  // floating panels, buttons, inputs

    // Border tiers — subtle to strong
    bg_header_border: dvui.Color,
    border_subtle:    dvui.Color,
    border_strong:    dvui.Color,
    border_drawer:    dvui.Color,
    border_card:      dvui.Color,
    border_input:     dvui.Color,
    divider:          dvui.Color,  // subtle separators

    // Glass overlays
    bg_glass:        dvui.Color,
    border_glass:    dvui.Color,
    overlay:         dvui.Color,  // modal backdrop

    // Input fields
    bg_input:        dvui.Color,

    // Accent tiers — electric cyan, with dim variant
    accent:          dvui.Color,
    accent_primary:  dvui.Color,
    accent_dim:      dvui.Color,
    accent_hover:    dvui.Color,
    accent_glow:     dvui.Color,  // 20% accent for focus rings
    active_border:   dvui.Color,

    // Text tiers — primary to tertiary, plus on-accent
    text_main:       dvui.Color,
    text_primary:    dvui.Color,
    text_secondary:  dvui.Color,
    text_tertiary:   dvui.Color,
    text_on_accent:  dvui.Color,
    text_muted:      dvui.Color,
    text_dim:        dvui.Color,  // timestamps, metadata

    // Semantic colors
    danger:          dvui.Color,
    success:         dvui.Color,
    warning:         dvui.Color,
    semantic_success: dvui.Color,
    semantic_warn:    dvui.Color,
    semantic_error:   dvui.Color,
    semantic_info:    dvui.Color,
};

// ── Theme Presets ──

const midnight_colors = ThemeColors{
    .bg_deep         = .{ .r = 10,  .g = 10,  .b = 15,  .a = 255 },
    .bg_app          = .{ .r = 14,  .g = 14,  .b = 20,  .a = 255 },
    .bg_header       = .{ .r = 14,  .g = 14,  .b = 20,  .a = 255 },
    .bg_muted        = .{ .r = 14,  .g = 14,  .b = 20,  .a = 255 },
    .bg_drawer       = .{ .r = 21,  .g = 21,  .b = 28,  .a = 255 },
    .bg_surface      = .{ .r = 21,  .g = 21,  .b = 28,  .a = 255 },
    .bg_card         = .{ .r = 21,  .g = 21,  .b = 28,  .a = 255 },
    .bg_card_hover   = .{ .r = 31,  .g = 31,  .b = 41,  .a = 255 },
    .bg_hover        = .{ .r = 31,  .g = 31,  .b = 41,  .a = 255 },
    .bg_elevated     = .{ .r = 31,  .g = 31,  .b = 41,  .a = 255 },
    .bg_header_border = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_subtle    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_strong    = .{ .r = 255, .g = 255, .b = 255, .a = 24 },
    .border_drawer    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_card      = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_input     = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .divider          = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .bg_glass        = .{ .r = 31,  .g = 31,  .b = 41,  .a = 255 },
    .border_glass    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .overlay         = .{ .r = 0,   .g = 0,   .b = 0,   .a = 160 },
    .bg_input        = .{ .r = 31,  .g = 31,  .b = 41,  .a = 255 },
    .accent          = .{ .r = 93,  .g = 208, .b = 255, .a = 255 }, // electric cyan
    .accent_primary  = .{ .r = 93,  .g = 208, .b = 255, .a = 255 },
    .accent_dim      = .{ .r = 93,  .g = 208, .b = 255, .a = 64 },
    .accent_hover    = .{ .r = 130, .g = 220, .b = 255, .a = 255 },
    .accent_glow     = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .active_border   = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .text_main       = .{ .r = 250, .g = 250, .b = 250, .a = 255 },
    .text_primary    = .{ .r = 250, .g = 250, .b = 250, .a = 255 },
    .text_secondary  = .{ .r = 168, .g = 168, .b = 178, .a = 255 },
    .text_tertiary   = .{ .r = 110, .g = 110, .b = 120, .a = 255 },
    .text_on_accent  = .{ .r = 10,  .g = 10,  .b = 15,  .a = 255 },
    .text_muted      = .{ .r = 168, .g = 168, .b = 178, .a = 255 },
    .text_dim        = .{ .r = 110, .g = 110, .b = 120, .a = 255 },
    .danger          = .{ .r = 255, .g = 107, .b = 138, .a = 255 },
    .success         = .{ .r = 93,  .g = 255, .b = 161, .a = 255 },
    .warning         = .{ .r = 255, .g = 204, .b = 93,  .a = 255 },
    .semantic_success = .{ .r = 93,  .g = 255, .b = 161, .a = 255 },
    .semantic_warn    = .{ .r = 255, .g = 204, .b = 93,  .a = 255 },
    .semantic_error   = .{ .r = 255, .g = 107, .b = 138, .a = 255 },
    .semantic_info    = .{ .r = 93,  .g = 208, .b = 255, .a = 255 },
};

const abyss_colors = ThemeColors{
    .bg_deep         = .{ .r = 0,   .g = 0,   .b = 0,   .a = 255 },
    .bg_app          = .{ .r = 0,   .g = 0,   .b = 0,   .a = 255 },
    .bg_header       = .{ .r = 0,   .g = 0,   .b = 0,   .a = 255 },
    .bg_muted        = .{ .r = 0,   .g = 0,   .b = 0,   .a = 255 },
    .bg_drawer       = .{ .r = 10,  .g = 10,  .b = 10,  .a = 255 },
    .bg_surface      = .{ .r = 10,  .g = 10,  .b = 10,  .a = 255 },
    .bg_card         = .{ .r = 10,  .g = 10,  .b = 10,  .a = 255 },
    .bg_card_hover   = .{ .r = 20,  .g = 20,  .b = 20,  .a = 255 },
    .bg_hover        = .{ .r = 20,  .g = 20,  .b = 20,  .a = 255 },
    .bg_elevated     = .{ .r = 20,  .g = 20,  .b = 20,  .a = 255 },
    .bg_header_border = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_subtle    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_strong    = .{ .r = 255, .g = 255, .b = 255, .a = 24 },
    .border_drawer    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_card      = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_input     = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .divider          = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .bg_glass        = .{ .r = 20,  .g = 20,  .b = 20,  .a = 255 },
    .border_glass    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .overlay         = .{ .r = 0,   .g = 0,   .b = 0,   .a = 180 },
    .bg_input        = .{ .r = 20,  .g = 20,  .b = 20,  .a = 255 },
    .accent          = .{ .r = 50,  .g = 160, .b = 110, .a = 255 }, // muted green
    .accent_primary  = .{ .r = 50,  .g = 160, .b = 110, .a = 255 },
    .accent_dim      = .{ .r = 50,  .g = 160, .b = 110, .a = 64 },
    .accent_hover    = .{ .r = 70,  .g = 180, .b = 130, .a = 255 },
    .accent_glow     = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .active_border   = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .text_main       = .{ .r = 200, .g = 200, .b = 200, .a = 255 },
    .text_primary    = .{ .r = 220, .g = 220, .b = 220, .a = 255 },
    .text_secondary  = .{ .r = 140, .g = 140, .b = 140, .a = 255 },
    .text_tertiary   = .{ .r = 90,  .g = 90,  .b = 90,  .a = 255 },
    .text_on_accent  = .{ .r = 0,   .g = 0,   .b = 0,   .a = 255 },
    .text_muted      = .{ .r = 90,  .g = 90,  .b = 90,  .a = 255 },
    .text_dim        = .{ .r = 55,  .g = 55,  .b = 55,  .a = 255 },
    .danger          = .{ .r = 175, .g = 65,  .b = 65,  .a = 255 },
    .success         = .{ .r = 50,  .g = 155, .b = 95,  .a = 255 },
    .warning         = .{ .r = 180, .g = 150, .b = 40,  .a = 255 },
    .semantic_success = .{ .r = 50,  .g = 155, .b = 95,  .a = 255 },
    .semantic_warn    = .{ .r = 180, .g = 150, .b = 40,  .a = 255 },
    .semantic_error   = .{ .r = 175, .g = 65,  .b = 65,  .a = 255 },
    .semantic_info    = .{ .r = 50,  .g = 160, .b = 110, .a = 255 },
};

const phantom_colors = ThemeColors{
    .bg_deep         = .{ .r = 10,  .g = 6,   .b = 18,  .a = 255 },
    .bg_app          = .{ .r = 16,  .g = 12,  .b = 24,  .a = 255 },
    .bg_header       = .{ .r = 16,  .g = 12,  .b = 24,  .a = 255 },
    .bg_muted        = .{ .r = 16,  .g = 12,  .b = 24,  .a = 255 },
    .bg_drawer       = .{ .r = 24,  .g = 18,  .b = 36,  .a = 255 },
    .bg_surface      = .{ .r = 24,  .g = 18,  .b = 36,  .a = 255 },
    .bg_card         = .{ .r = 24,  .g = 18,  .b = 36,  .a = 255 },
    .bg_card_hover   = .{ .r = 40,  .g = 30,  .b = 56,  .a = 255 },
    .bg_hover        = .{ .r = 40,  .g = 30,  .b = 56,  .a = 255 },
    .bg_elevated     = .{ .r = 40,  .g = 30,  .b = 56,  .a = 255 },
    .bg_header_border = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_subtle    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_strong    = .{ .r = 255, .g = 255, .b = 255, .a = 24 },
    .border_drawer    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_card      = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_input     = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .divider          = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .bg_glass        = .{ .r = 40,  .g = 30,  .b = 56,  .a = 255 },
    .border_glass    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .overlay         = .{ .r = 8,   .g = 4,   .b = 16,  .a = 170 },
    .bg_input        = .{ .r = 40,  .g = 30,  .b = 56,  .a = 255 },
    .accent          = .{ .r = 125, .g = 110, .b = 185, .a = 255 }, // muted violet
    .accent_primary  = .{ .r = 125, .g = 110, .b = 185, .a = 255 },
    .accent_dim      = .{ .r = 125, .g = 110, .b = 185, .a = 64 },
    .accent_hover    = .{ .r = 150, .g = 138, .b = 200, .a = 255 },
    .accent_glow     = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .active_border   = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .text_main       = .{ .r = 210, .g = 208, .b = 220, .a = 255 },
    .text_primary    = .{ .r = 230, .g = 226, .b = 240, .a = 255 },
    .text_secondary  = .{ .r = 165, .g = 155, .b = 185, .a = 255 },
    .text_tertiary   = .{ .r = 115, .g = 105, .b = 140, .a = 255 },
    .text_on_accent  = .{ .r = 10,  .g = 6,   .b = 18,  .a = 255 },
    .text_muted      = .{ .r = 115, .g = 105, .b = 140, .a = 255 },
    .text_dim        = .{ .r = 80,  .g = 68,  .b = 100, .a = 255 },
    .danger          = .{ .r = 185, .g = 95,  .b = 110, .a = 255 },
    .success         = .{ .r = 65,  .g = 165, .b = 105, .a = 255 },
    .warning         = .{ .r = 190, .g = 150, .b = 95,  .a = 255 },
    .semantic_success = .{ .r = 65,  .g = 165, .b = 105, .a = 255 },
    .semantic_warn    = .{ .r = 190, .g = 150, .b = 95,  .a = 255 },
    .semantic_error   = .{ .r = 185, .g = 95,  .b = 110, .a = 255 },
    .semantic_info    = .{ .r = 125, .g = 110, .b = 185, .a = 255 },
};

const nord_colors = ThemeColors{
    .bg_deep         = .{ .r = 36,  .g = 42,  .b = 54,  .a = 255 },
    .bg_app          = .{ .r = 46,  .g = 52,  .b = 64,  .a = 255 }, // nord0
    .bg_header       = .{ .r = 46,  .g = 52,  .b = 64,  .a = 255 },
    .bg_muted        = .{ .r = 46,  .g = 52,  .b = 64,  .a = 255 },
    .bg_drawer       = .{ .r = 59,  .g = 66,  .b = 82,  .a = 255 },
    .bg_surface      = .{ .r = 59,  .g = 66,  .b = 82,  .a = 255 },
    .bg_card         = .{ .r = 59,  .g = 66,  .b = 82,  .a = 255 },
    .bg_card_hover   = .{ .r = 82,  .g = 92,  .b = 112, .a = 255 },
    .bg_hover        = .{ .r = 82,  .g = 92,  .b = 112, .a = 255 },
    .bg_elevated     = .{ .r = 82,  .g = 92,  .b = 112, .a = 255 },
    .bg_header_border = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_subtle    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_strong    = .{ .r = 255, .g = 255, .b = 255, .a = 24 },
    .border_drawer    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_card      = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_input     = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .divider          = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .bg_glass        = .{ .r = 82,  .g = 92,  .b = 112, .a = 255 },
    .border_glass    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .overlay         = .{ .r = 30,  .g = 34,  .b = 44,  .a = 160 },
    .bg_input        = .{ .r = 82,  .g = 92,  .b = 112, .a = 255 },
    .accent          = .{ .r = 110, .g = 150, .b = 165, .a = 255 }, // muted frost
    .accent_primary  = .{ .r = 110, .g = 150, .b = 165, .a = 255 },
    .accent_dim      = .{ .r = 110, .g = 150, .b = 165, .a = 64 },
    .accent_hover    = .{ .r = 125, .g = 160, .b = 165, .a = 255 },
    .accent_glow     = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .active_border   = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .text_main       = .{ .r = 210, .g = 215, .b = 222, .a = 255 },
    .text_primary    = .{ .r = 229, .g = 233, .b = 240, .a = 255 },
    .text_secondary  = .{ .r = 170, .g = 178, .b = 192, .a = 255 },
    .text_tertiary   = .{ .r = 130, .g = 138, .b = 150, .a = 255 },
    .text_on_accent  = .{ .r = 36,  .g = 42,  .b = 54,  .a = 255 },
    .text_muted      = .{ .r = 145, .g = 152, .b = 165, .a = 255 },
    .text_dim        = .{ .r = 105, .g = 112, .b = 128, .a = 255 },
    .danger          = .{ .r = 160, .g = 85,  .b = 95,  .a = 255 },
    .success         = .{ .r = 130, .g = 155, .b = 115, .a = 255 },
    .warning         = .{ .r = 190, .g = 170, .b = 120, .a = 255 },
    .semantic_success = .{ .r = 130, .g = 155, .b = 115, .a = 255 },
    .semantic_warn    = .{ .r = 190, .g = 170, .b = 120, .a = 255 },
    .semantic_error   = .{ .r = 160, .g = 85,  .b = 95,  .a = 255 },
    .semantic_info    = .{ .r = 110, .g = 150, .b = 165, .a = 255 },
};

const solarized_colors = ThemeColors{
    .bg_deep         = .{ .r = 0,   .g = 36,  .b = 46,  .a = 255 },
    .bg_app          = .{ .r = 0,   .g = 43,  .b = 54,  .a = 255 }, // base03
    .bg_header       = .{ .r = 0,   .g = 43,  .b = 54,  .a = 255 },
    .bg_muted        = .{ .r = 0,   .g = 43,  .b = 54,  .a = 255 },
    .bg_drawer       = .{ .r = 10,  .g = 58,  .b = 70,  .a = 255 },
    .bg_surface      = .{ .r = 10,  .g = 58,  .b = 70,  .a = 255 },
    .bg_card         = .{ .r = 10,  .g = 58,  .b = 70,  .a = 255 },
    .bg_card_hover   = .{ .r = 22,  .g = 68,  .b = 80,  .a = 255 },
    .bg_hover        = .{ .r = 22,  .g = 68,  .b = 80,  .a = 255 },
    .bg_elevated     = .{ .r = 22,  .g = 68,  .b = 80,  .a = 255 },
    .bg_header_border = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_subtle    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_strong    = .{ .r = 255, .g = 255, .b = 255, .a = 24 },
    .border_drawer    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_card      = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_input     = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .divider          = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .bg_glass        = .{ .r = 22,  .g = 68,  .b = 80,  .a = 255 },
    .border_glass    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .overlay         = .{ .r = 0,   .g = 20,  .b = 28,  .a = 170 },
    .bg_input        = .{ .r = 22,  .g = 68,  .b = 80,  .a = 255 },
    .accent          = .{ .r = 160, .g = 85,  .b = 50,  .a = 255 }, // muted orange
    .accent_primary  = .{ .r = 160, .g = 85,  .b = 50,  .a = 255 },
    .accent_dim      = .{ .r = 160, .g = 85,  .b = 50,  .a = 64 },
    .accent_hover    = .{ .r = 180, .g = 105, .b = 65,  .a = 255 },
    .accent_glow     = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .active_border   = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .text_main       = .{ .r = 215, .g = 210, .b = 200, .a = 255 },
    .text_primary    = .{ .r = 238, .g = 232, .b = 213, .a = 255 },
    .text_secondary  = .{ .r = 165, .g = 175, .b = 175, .a = 255 },
    .text_tertiary   = .{ .r = 110, .g = 125, .b = 130, .a = 255 },
    .text_on_accent  = .{ .r = 0,   .g = 36,  .b = 46,  .a = 255 },
    .text_muted      = .{ .r = 130, .g = 140, .b = 140, .a = 255 },
    .text_dim        = .{ .r = 90,  .g = 105, .b = 110, .a = 255 },
    .danger          = .{ .r = 170, .g = 65,  .b = 60,  .a = 255 },
    .success         = .{ .r = 110, .g = 130, .b = 50,  .a = 255 },
    .warning         = .{ .r = 150, .g = 120, .b = 40,  .a = 255 },
    .semantic_success = .{ .r = 110, .g = 130, .b = 50,  .a = 255 },
    .semantic_warn    = .{ .r = 150, .g = 120, .b = 40,  .a = 255 },
    .semantic_error   = .{ .r = 170, .g = 65,  .b = 60,  .a = 255 },
    .semantic_info    = .{ .r = 160, .g = 85,  .b = 50,  .a = 255 },
};

const rose_colors = ThemeColors{
    .bg_deep         = .{ .r = 12,  .g = 6,   .b = 12,  .a = 255 },
    .bg_app          = .{ .r = 18,  .g = 10,  .b = 16,  .a = 255 },
    .bg_header       = .{ .r = 18,  .g = 10,  .b = 16,  .a = 255 },
    .bg_muted        = .{ .r = 18,  .g = 10,  .b = 16,  .a = 255 },
    .bg_drawer       = .{ .r = 28,  .g = 16,  .b = 24,  .a = 255 },
    .bg_surface      = .{ .r = 28,  .g = 16,  .b = 24,  .a = 255 },
    .bg_card         = .{ .r = 28,  .g = 16,  .b = 24,  .a = 255 },
    .bg_card_hover   = .{ .r = 46,  .g = 28,  .b = 40,  .a = 255 },
    .bg_hover        = .{ .r = 46,  .g = 28,  .b = 40,  .a = 255 },
    .bg_elevated     = .{ .r = 46,  .g = 28,  .b = 40,  .a = 255 },
    .bg_header_border = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_subtle    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_strong    = .{ .r = 255, .g = 255, .b = 255, .a = 24 },
    .border_drawer    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_card      = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_input     = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .divider          = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .bg_glass        = .{ .r = 46,  .g = 28,  .b = 40,  .a = 255 },
    .border_glass    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .overlay         = .{ .r = 12,  .g = 4,   .b = 10,  .a = 170 },
    .bg_input        = .{ .r = 46,  .g = 28,  .b = 40,  .a = 255 },
    .accent          = .{ .r = 175, .g = 100, .b = 140, .a = 255 }, // muted rose
    .accent_primary  = .{ .r = 175, .g = 100, .b = 140, .a = 255 },
    .accent_dim      = .{ .r = 175, .g = 100, .b = 140, .a = 64 },
    .accent_hover    = .{ .r = 195, .g = 130, .b = 165, .a = 255 },
    .accent_glow     = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .active_border   = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .text_main       = .{ .r = 215, .g = 205, .b = 212, .a = 255 },
    .text_primary    = .{ .r = 240, .g = 230, .b = 238, .a = 255 },
    .text_secondary  = .{ .r = 170, .g = 140, .b = 158, .a = 255 },
    .text_tertiary   = .{ .r = 120, .g = 90,  .b = 105, .a = 255 },
    .text_on_accent  = .{ .r = 12,  .g = 6,   .b = 12,  .a = 255 },
    .text_muted      = .{ .r = 135, .g = 100, .b = 120, .a = 255 },
    .text_dim        = .{ .r = 100, .g = 68,  .b = 85,  .a = 255 },
    .danger          = .{ .r = 185, .g = 75,  .b = 75,  .a = 255 },
    .success         = .{ .r = 90,  .g = 170, .b = 140, .a = 255 },
    .warning         = .{ .r = 190, .g = 150, .b = 95,  .a = 255 },
    .semantic_success = .{ .r = 90,  .g = 170, .b = 140, .a = 255 },
    .semantic_warn    = .{ .r = 190, .g = 150, .b = 95,  .a = 255 },
    .semantic_error   = .{ .r = 185, .g = 75,  .b = 75,  .a = 255 },
    .semantic_info    = .{ .r = 175, .g = 100, .b = 140, .a = 255 },
};

const ember_colors = ThemeColors{
    .bg_deep         = .{ .r = 14,  .g = 10,  .b = 6,   .a = 255 },
    .bg_app          = .{ .r = 20,  .g = 14,  .b = 10,  .a = 255 },
    .bg_header       = .{ .r = 20,  .g = 14,  .b = 10,  .a = 255 },
    .bg_muted        = .{ .r = 20,  .g = 14,  .b = 10,  .a = 255 },
    .bg_drawer       = .{ .r = 32,  .g = 22,  .b = 16,  .a = 255 },
    .bg_surface      = .{ .r = 32,  .g = 22,  .b = 16,  .a = 255 },
    .bg_card         = .{ .r = 32,  .g = 22,  .b = 16,  .a = 255 },
    .bg_card_hover   = .{ .r = 50,  .g = 36,  .b = 28,  .a = 255 },
    .bg_hover        = .{ .r = 50,  .g = 36,  .b = 28,  .a = 255 },
    .bg_elevated     = .{ .r = 50,  .g = 36,  .b = 28,  .a = 255 },
    .bg_header_border = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_subtle    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_strong    = .{ .r = 255, .g = 255, .b = 255, .a = 24 },
    .border_drawer    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_card      = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .border_input     = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .divider          = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .bg_glass        = .{ .r = 50,  .g = 36,  .b = 28,  .a = 255 },
    .border_glass    = .{ .r = 255, .g = 255, .b = 255, .a = 14 },
    .overlay         = .{ .r = 10,  .g = 6,   .b = 4,   .a = 170 },
    .bg_input        = .{ .r = 50,  .g = 36,  .b = 28,  .a = 255 },
    .accent          = .{ .r = 185, .g = 120, .b = 65,  .a = 255 }, // muted amber
    .accent_primary  = .{ .r = 185, .g = 120, .b = 65,  .a = 255 },
    .accent_dim      = .{ .r = 185, .g = 120, .b = 65,  .a = 64 },
    .accent_hover    = .{ .r = 200, .g = 150, .b = 95,  .a = 255 },
    .accent_glow     = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .active_border   = .{ .r = 0,   .g = 0,   .b = 0,   .a = 0 },
    .text_main       = .{ .r = 215, .g = 205, .b = 190, .a = 255 },
    .text_primary    = .{ .r = 240, .g = 228, .b = 210, .a = 255 },
    .text_secondary  = .{ .r = 175, .g = 150, .b = 120, .a = 255 },
    .text_tertiary   = .{ .r = 125, .g = 105, .b = 78,  .a = 255 },
    .text_on_accent  = .{ .r = 14,  .g = 10,  .b = 6,   .a = 255 },
    .text_muted      = .{ .r = 140, .g = 115, .b = 90,  .a = 255 },
    .text_dim        = .{ .r = 100, .g = 80,  .b = 58,  .a = 255 },
    .danger          = .{ .r = 185, .g = 95,  .b = 95,  .a = 255 },
    .success         = .{ .r = 65,  .g = 165, .b = 105, .a = 255 },
    .warning         = .{ .r = 190, .g = 160, .b = 50,  .a = 255 },
    .semantic_success = .{ .r = 65,  .g = 165, .b = 105, .a = 255 },
    .semantic_warn    = .{ .r = 190, .g = 160, .b = 50,  .a = 255 },
    .semantic_error   = .{ .r = 185, .g = 95,  .b = 95,  .a = 255 },
    .semantic_info    = .{ .r = 185, .g = 120, .b = 65,  .a = 255 },
};

// ── Active Theme State ──

pub var active_preset: ThemePreset = .midnight;

pub fn getThemeColors(preset: ThemePreset) ThemeColors {
    return switch (preset) {
        .midnight   => midnight_colors,
        .abyss      => abyss_colors,
        .phantom    => phantom_colors,
        .nord       => nord_colors,
        .solarized  => solarized_colors,
        .rose       => rose_colors,
        .ember      => ember_colors,
    };
}

pub fn presetName(preset: ThemePreset) []const u8 {
    return switch (preset) {
        .midnight   => "Midnight",
        .abyss      => "Abyss",
        .phantom    => "Phantom",
        .nord       => "Nord",
        .solarized  => "Solarized",
        .rose       => "Rosé",
        .ember      => "Ember",
    };
}

/// Runtime-resolved colors (always use these in UI code)
pub var colors: ThemeColors = midnight_colors;

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
    xs,  // 12px — inline badges
    sm,  // 16px — buttons, labels
    md,  // 20px — standard icons
    lg,  // 24px — headers
    xl,  // 32px — hero elements
};

pub fn iconSize(s: IconSize) dvui.Size {
    return switch (s) {
        .xs => .{ .w = 12, .h = 12 },
        .sm => .{ .w = 16, .h = 16 },
        .md => .{ .w = 20, .h = 20 },
        .lg => .{ .w = 24, .h = 24 },
        .xl => .{ .w = 32, .h = 32 },
    };
}

// ── Spacing tokens — 4px-based scale ──

pub const spacing = struct {
    pub const xs: f32 = 4;
    pub const sm: f32 = 8;
    pub const md: f32 = 12;
    pub const lg: f32 = 16;
    pub const xl: f32 = 24;
    pub const xxl: f32 = 32;
};

// ── Radius tokens — corner radii ──

pub const radius = struct {
    pub const sm: f32 = 3;
    pub const md: f32 = 6;
    pub const lg: f32 = 8;
    pub const pill: f32 = 999;
};

// ── Font size tokens — type ramp ──

pub const font_size = struct {
    pub const micro: f32 = 11;
    pub const small: f32 = 11;
    pub const body: f32 = 13;
    pub const title: f32 = 17;
    pub const display: f32 = 24;
};

// ── Dimensions (legacy dvui.Rect helpers) ──

pub const dims = struct {
    pub const rad_sm = dvui.Rect.all(radius.sm);
    pub const rad_md = dvui.Rect.all(radius.md);
    pub const rad_lg = dvui.Rect.all(radius.lg);
    pub const rad_xl = dvui.Rect.all(radius.lg);

    pub const pad_xs = dvui.Rect.all(spacing.xs);
    pub const pad_sm = dvui.Rect.all(spacing.sm);
    pub const pad_md = dvui.Rect.all(spacing.md);
    pub const pad_lg = dvui.Rect.all(spacing.lg);
};

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
    t.text = colors.text_main;
    t.text_hover = colors.text_main;
    t.text_press = colors.accent;
    t.fill = colors.bg_app;
    t.fill_hover = colors.bg_card_hover;
    t.fill_press = colors.bg_header_border;
    t.border = colors.border_input;
    // The accent/focus color drives slider fills, focus rings and other dvui
    // built-ins. Without this it stays dvui's default BLUE — which is why the
    // scrubber and volume slider rendered blue instead of the theme accent.
    t.focus = colors.accent;
    dvui.themeSet(t);
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
        .color_fill = colors.bg_input,
        .color_border = colors.border_input,
        .color_text = colors.text_main,
        .border = dvui.Rect.all(1),
        .corner_radius = dims.rad_sm,
    };
}

/// Danger icon button (red)
pub fn optIconBtnDanger() dvui.Options {
    return .{
        .color_text = colors.danger,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border = dvui.Rect.all(0),
    };
}

/// Subtle horizontal divider
pub fn optDivider() dvui.Options {
    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = colors.divider,
        .min_size_content = .{ .w = 10, .h = 1 },
        .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 },
    };
}

