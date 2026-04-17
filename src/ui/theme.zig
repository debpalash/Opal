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

/// Complete color palette for a theme
pub const ThemeColors = struct {
    // Backgrounds (6-level depth)
    bg_app:          dvui.Color,
    bg_header:       dvui.Color,
    bg_drawer:       dvui.Color,
    bg_surface:      dvui.Color,  // between app and card
    bg_card:         dvui.Color,
    bg_card_hover:   dvui.Color,
    bg_elevated:     dvui.Color,  // floating panels

    // Borders
    bg_header_border: dvui.Color,
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

    // Accent
    accent:          dvui.Color,
    accent_hover:    dvui.Color,
    accent_glow:     dvui.Color,  // 20% accent for focus rings
    active_border:   dvui.Color,

    // Text
    text_main:       dvui.Color,
    text_muted:      dvui.Color,
    text_dim:        dvui.Color,  // timestamps, metadata

    // Semantic
    danger:          dvui.Color,
    success:         dvui.Color,
    warning:         dvui.Color,
};

// ── Theme Presets ──

const midnight_colors = ThemeColors{
    .bg_app          = .{ .r = 14,  .g = 14,  .b = 20,  .a = 255 },
    .bg_header       = .{ .r = 18,  .g = 18,  .b = 26,  .a = 255 },
    .bg_drawer       = .{ .r = 22,  .g = 22,  .b = 30,  .a = 255 },
    .bg_surface      = .{ .r = 20,  .g = 20,  .b = 28,  .a = 255 },
    .bg_card         = .{ .r = 28,  .g = 28,  .b = 38,  .a = 255 },
    .bg_card_hover   = .{ .r = 36,  .g = 36,  .b = 48,  .a = 255 },
    .bg_elevated     = .{ .r = 34,  .g = 34,  .b = 46,  .a = 255 },
    .bg_header_border = .{ .r = 38,  .g = 38,  .b = 52,  .a = 255 },
    .border_drawer    = .{ .r = 42,  .g = 42,  .b = 56,  .a = 255 },
    .border_card      = .{ .r = 48,  .g = 48,  .b = 64,  .a = 200 },
    .border_input     = .{ .r = 52,  .g = 52,  .b = 70,  .a = 255 },
    .divider          = .{ .r = 40,  .g = 40,  .b = 55,  .a = 100 },
    .bg_glass        = .{ .r = 30,  .g = 30,  .b = 44,  .a = 210 },
    .border_glass    = .{ .r = 60,  .g = 60,  .b = 82,  .a = 180 },
    .overlay         = .{ .r = 0,   .g = 0,   .b = 0,   .a = 160 },
    .bg_input        = .{ .r = 16,  .g = 16,  .b = 24,  .a = 255 },
    .accent          = .{ .r = 70,  .g = 140, .b = 170, .a = 255 }, // muted sky
    .accent_hover    = .{ .r = 95,  .g = 160, .b = 185, .a = 255 },
    .accent_glow     = .{ .r = 70,  .g = 140, .b = 170, .a = 35 },
    .active_border   = .{ .r = 70,  .g = 140, .b = 170, .a = 70 },
    .text_main       = .{ .r = 210, .g = 210, .b = 218, .a = 255 },
    .text_muted      = .{ .r = 105, .g = 105, .b = 130, .a = 255 },
    .text_dim        = .{ .r = 70,  .g = 70,  .b = 92,  .a = 255 },
    .danger          = .{ .r = 180, .g = 75,  .b = 75,  .a = 255 },
    .success         = .{ .r = 60,  .g = 145, .b = 90,  .a = 255 },
    .warning         = .{ .r = 185, .g = 145, .b = 50,  .a = 255 },
};

const abyss_colors = ThemeColors{
    .bg_app          = .{ .r = 0,   .g = 0,   .b = 0,   .a = 255 },
    .bg_header       = .{ .r = 6,   .g = 6,   .b = 6,   .a = 255 },
    .bg_drawer       = .{ .r = 10,  .g = 10,  .b = 10,  .a = 255 },
    .bg_surface      = .{ .r = 5,   .g = 5,   .b = 5,   .a = 255 },
    .bg_card         = .{ .r = 16,  .g = 16,  .b = 16,  .a = 255 },
    .bg_card_hover   = .{ .r = 24,  .g = 24,  .b = 24,  .a = 255 },
    .bg_elevated     = .{ .r = 20,  .g = 20,  .b = 20,  .a = 255 },
    .bg_header_border = .{ .r = 30,  .g = 30,  .b = 30,  .a = 255 },
    .border_drawer    = .{ .r = 32,  .g = 32,  .b = 32,  .a = 255 },
    .border_card      = .{ .r = 38,  .g = 38,  .b = 38,  .a = 200 },
    .border_input     = .{ .r = 42,  .g = 42,  .b = 42,  .a = 255 },
    .divider          = .{ .r = 30,  .g = 30,  .b = 30,  .a = 100 },
    .bg_glass        = .{ .r = 12,  .g = 12,  .b = 12,  .a = 230 },
    .border_glass    = .{ .r = 40,  .g = 40,  .b = 40,  .a = 180 },
    .overlay         = .{ .r = 0,   .g = 0,   .b = 0,   .a = 180 },
    .bg_input        = .{ .r = 4,   .g = 4,   .b = 4,   .a = 255 },
    .accent          = .{ .r = 50,  .g = 160, .b = 110, .a = 255 }, // muted green
    .accent_hover    = .{ .r = 70,  .g = 180, .b = 130, .a = 255 },
    .accent_glow     = .{ .r = 50,  .g = 160, .b = 110, .a = 30 },
    .active_border   = .{ .r = 50,  .g = 160, .b = 110, .a = 60 },
    .text_main       = .{ .r = 200, .g = 200, .b = 200, .a = 255 },
    .text_muted      = .{ .r = 90,  .g = 90,  .b = 90,  .a = 255 },
    .text_dim        = .{ .r = 55,  .g = 55,  .b = 55,  .a = 255 },
    .danger          = .{ .r = 175, .g = 65,  .b = 65,  .a = 255 },
    .success         = .{ .r = 50,  .g = 155, .b = 95,  .a = 255 },
    .warning         = .{ .r = 180, .g = 150, .b = 40,  .a = 255 },
};

const phantom_colors = ThemeColors{
    .bg_app          = .{ .r = 16,  .g = 12,  .b = 24,  .a = 255 },
    .bg_header       = .{ .r = 22,  .g = 16,  .b = 32,  .a = 255 },
    .bg_drawer       = .{ .r = 26,  .g = 20,  .b = 38,  .a = 255 },
    .bg_surface      = .{ .r = 20,  .g = 14,  .b = 30,  .a = 255 },
    .bg_card         = .{ .r = 34,  .g = 26,  .b = 48,  .a = 255 },
    .bg_card_hover   = .{ .r = 44,  .g = 34,  .b = 60,  .a = 255 },
    .bg_elevated     = .{ .r = 40,  .g = 30,  .b = 56,  .a = 255 },
    .bg_header_border = .{ .r = 48,  .g = 36,  .b = 64,  .a = 255 },
    .border_drawer    = .{ .r = 52,  .g = 40,  .b = 70,  .a = 255 },
    .border_card      = .{ .r = 60,  .g = 46,  .b = 80,  .a = 200 },
    .border_input     = .{ .r = 64,  .g = 50,  .b = 86,  .a = 255 },
    .divider          = .{ .r = 50,  .g = 38,  .b = 68,  .a = 100 },
    .bg_glass        = .{ .r = 32,  .g = 24,  .b = 48,  .a = 220 },
    .border_glass    = .{ .r = 72,  .g = 56,  .b = 96,  .a = 180 },
    .overlay         = .{ .r = 8,   .g = 4,   .b = 16,  .a = 170 },
    .bg_input        = .{ .r = 12,  .g = 8,   .b = 20,  .a = 255 },
    .accent          = .{ .r = 125, .g = 110, .b = 185, .a = 255 }, // muted violet
    .accent_hover    = .{ .r = 150, .g = 138, .b = 200, .a = 255 },
    .accent_glow     = .{ .r = 125, .g = 110, .b = 185, .a = 35 },
    .active_border   = .{ .r = 125, .g = 110, .b = 185, .a = 65 },
    .text_main       = .{ .r = 210, .g = 208, .b = 220, .a = 255 },
    .text_muted      = .{ .r = 115, .g = 105, .b = 140, .a = 255 },
    .text_dim        = .{ .r = 80,  .g = 68,  .b = 100, .a = 255 },
    .danger          = .{ .r = 185, .g = 95,  .b = 110, .a = 255 },
    .success         = .{ .r = 65,  .g = 165, .b = 105, .a = 255 },
    .warning         = .{ .r = 190, .g = 150, .b = 95,  .a = 255 },
};

const nord_colors = ThemeColors{
    .bg_app          = .{ .r = 46,  .g = 52,  .b = 64,  .a = 255 }, // nord0
    .bg_header       = .{ .r = 59,  .g = 66,  .b = 82,  .a = 255 }, // nord1
    .bg_drawer       = .{ .r = 67,  .g = 76,  .b = 94,  .a = 255 }, // nord2
    .bg_surface      = .{ .r = 52,  .g = 58,  .b = 72,  .a = 255 },
    .bg_card         = .{ .r = 76,  .g = 86,  .b = 106, .a = 255 }, // nord3
    .bg_card_hover   = .{ .r = 86,  .g = 96,  .b = 116, .a = 255 },
    .bg_elevated     = .{ .r = 82,  .g = 92,  .b = 112, .a = 255 },
    .bg_header_border = .{ .r = 76,  .g = 86,  .b = 106, .a = 255 },
    .border_drawer    = .{ .r = 76,  .g = 86,  .b = 106, .a = 200 },
    .border_card      = .{ .r = 86,  .g = 96,  .b = 116, .a = 180 },
    .border_input     = .{ .r = 76,  .g = 86,  .b = 106, .a = 255 },
    .divider          = .{ .r = 76,  .g = 86,  .b = 106, .a = 80 },
    .bg_glass        = .{ .r = 59,  .g = 66,  .b = 82,  .a = 220 },
    .border_glass    = .{ .r = 86,  .g = 96,  .b = 116, .a = 180 },
    .overlay         = .{ .r = 30,  .g = 34,  .b = 44,  .a = 160 },
    .bg_input        = .{ .r = 46,  .g = 52,  .b = 64,  .a = 255 },
    .accent          = .{ .r = 110, .g = 150, .b = 165, .a = 255 }, // muted frost
    .accent_hover    = .{ .r = 125, .g = 160, .b = 165, .a = 255 },
    .accent_glow     = .{ .r = 110, .g = 150, .b = 165, .a = 35 },
    .active_border   = .{ .r = 110, .g = 150, .b = 165, .a = 65 },
    .text_main       = .{ .r = 210, .g = 215, .b = 222, .a = 255 },
    .text_muted      = .{ .r = 145, .g = 152, .b = 165, .a = 255 },
    .text_dim        = .{ .r = 105, .g = 112, .b = 128, .a = 255 },
    .danger          = .{ .r = 160, .g = 85,  .b = 95,  .a = 255 },
    .success         = .{ .r = 130, .g = 155, .b = 115, .a = 255 },
    .warning         = .{ .r = 190, .g = 170, .b = 120, .a = 255 },
};

const solarized_colors = ThemeColors{
    .bg_app          = .{ .r = 0,   .g = 43,  .b = 54,  .a = 255 }, // base03
    .bg_header       = .{ .r = 7,   .g = 54,  .b = 66,  .a = 255 }, // base02
    .bg_drawer       = .{ .r = 7,   .g = 54,  .b = 66,  .a = 255 },
    .bg_surface      = .{ .r = 3,   .g = 48,  .b = 60,  .a = 255 },
    .bg_card         = .{ .r = 18,  .g = 64,  .b = 76,  .a = 255 },
    .bg_card_hover   = .{ .r = 28,  .g = 74,  .b = 86,  .a = 255 },
    .bg_elevated     = .{ .r = 22,  .g = 68,  .b = 80,  .a = 255 },
    .bg_header_border = .{ .r = 18,  .g = 64,  .b = 76,  .a = 255 },
    .border_drawer    = .{ .r = 28,  .g = 74,  .b = 86,  .a = 200 },
    .border_card      = .{ .r = 58,  .g = 104, .b = 116, .a = 180 },
    .border_input     = .{ .r = 68,  .g = 114, .b = 126, .a = 255 },
    .divider          = .{ .r = 38,  .g = 84,  .b = 96,  .a = 80 },
    .bg_glass        = .{ .r = 7,   .g = 54,  .b = 66,  .a = 220 },
    .border_glass    = .{ .r = 58,  .g = 104, .b = 116, .a = 180 },
    .overlay         = .{ .r = 0,   .g = 20,  .b = 28,  .a = 170 },
    .bg_input        = .{ .r = 0,   .g = 43,  .b = 54,  .a = 255 },
    .accent          = .{ .r = 160, .g = 85,  .b = 50,  .a = 255 }, // muted orange
    .accent_hover    = .{ .r = 180, .g = 105, .b = 65,  .a = 255 },
    .accent_glow     = .{ .r = 160, .g = 85,  .b = 50,  .a = 35 },
    .active_border   = .{ .r = 160, .g = 85,  .b = 50,  .a = 65 },
    .text_main       = .{ .r = 215, .g = 210, .b = 200, .a = 255 },
    .text_muted      = .{ .r = 130, .g = 140, .b = 140, .a = 255 },
    .text_dim        = .{ .r = 90,  .g = 105, .b = 110, .a = 255 },
    .danger          = .{ .r = 170, .g = 65,  .b = 60,  .a = 255 },
    .success         = .{ .r = 110, .g = 130, .b = 50,  .a = 255 },
    .warning         = .{ .r = 150, .g = 120, .b = 40,  .a = 255 },
};

const rose_colors = ThemeColors{
    .bg_app          = .{ .r = 18,  .g = 10,  .b = 16,  .a = 255 },
    .bg_header       = .{ .r = 26,  .g = 14,  .b = 22,  .a = 255 },
    .bg_drawer       = .{ .r = 30,  .g = 18,  .b = 26,  .a = 255 },
    .bg_surface      = .{ .r = 24,  .g = 12,  .b = 20,  .a = 255 },
    .bg_card         = .{ .r = 40,  .g = 24,  .b = 34,  .a = 255 },
    .bg_card_hover   = .{ .r = 52,  .g = 32,  .b = 44,  .a = 255 },
    .bg_elevated     = .{ .r = 46,  .g = 28,  .b = 40,  .a = 255 },
    .bg_header_border = .{ .r = 50,  .g = 30,  .b = 42,  .a = 255 },
    .border_drawer    = .{ .r = 56,  .g = 34,  .b = 48,  .a = 255 },
    .border_card      = .{ .r = 66,  .g = 40,  .b = 56,  .a = 200 },
    .border_input     = .{ .r = 70,  .g = 44,  .b = 60,  .a = 255 },
    .divider          = .{ .r = 56,  .g = 34,  .b = 48,  .a = 80 },
    .bg_glass        = .{ .r = 36,  .g = 20,  .b = 30,  .a = 220 },
    .border_glass    = .{ .r = 76,  .g = 48,  .b = 66,  .a = 180 },
    .overlay         = .{ .r = 12,  .g = 4,   .b = 10,  .a = 170 },
    .bg_input        = .{ .r = 14,  .g = 6,   .b = 12,  .a = 255 },
    .accent          = .{ .r = 175, .g = 100, .b = 140, .a = 255 }, // muted rose
    .accent_hover    = .{ .r = 195, .g = 130, .b = 165, .a = 255 },
    .accent_glow     = .{ .r = 175, .g = 100, .b = 140, .a = 35 },
    .active_border   = .{ .r = 175, .g = 100, .b = 140, .a = 65 },
    .text_main       = .{ .r = 215, .g = 205, .b = 212, .a = 255 },
    .text_muted      = .{ .r = 135, .g = 100, .b = 120, .a = 255 },
    .text_dim        = .{ .r = 100, .g = 68,  .b = 85,  .a = 255 },
    .danger          = .{ .r = 185, .g = 75,  .b = 75,  .a = 255 },
    .success         = .{ .r = 90,  .g = 170, .b = 140, .a = 255 },
    .warning         = .{ .r = 190, .g = 150, .b = 95,  .a = 255 },
};

const ember_colors = ThemeColors{
    .bg_app          = .{ .r = 20,  .g = 14,  .b = 10,  .a = 255 },
    .bg_header       = .{ .r = 28,  .g = 20,  .b = 14,  .a = 255 },
    .bg_drawer       = .{ .r = 34,  .g = 24,  .b = 18,  .a = 255 },
    .bg_surface      = .{ .r = 26,  .g = 18,  .b = 12,  .a = 255 },
    .bg_card         = .{ .r = 44,  .g = 32,  .b = 24,  .a = 255 },
    .bg_card_hover   = .{ .r = 56,  .g = 40,  .b = 30,  .a = 255 },
    .bg_elevated     = .{ .r = 50,  .g = 36,  .b = 28,  .a = 255 },
    .bg_header_border = .{ .r = 52,  .g = 38,  .b = 28,  .a = 255 },
    .border_drawer    = .{ .r = 58,  .g = 42,  .b = 32,  .a = 255 },
    .border_card      = .{ .r = 68,  .g = 50,  .b = 38,  .a = 200 },
    .border_input     = .{ .r = 74,  .g = 54,  .b = 42,  .a = 255 },
    .divider          = .{ .r = 58,  .g = 42,  .b = 32,  .a = 80 },
    .bg_glass        = .{ .r = 38,  .g = 26,  .b = 18,  .a = 220 },
    .border_glass    = .{ .r = 80,  .g = 58,  .b = 44,  .a = 180 },
    .overlay         = .{ .r = 10,  .g = 6,   .b = 4,   .a = 170 },
    .bg_input        = .{ .r = 16,  .g = 10,  .b = 6,   .a = 255 },
    .accent          = .{ .r = 185, .g = 120, .b = 65,  .a = 255 }, // muted amber
    .accent_hover    = .{ .r = 200, .g = 150, .b = 95,  .a = 255 },
    .accent_glow     = .{ .r = 185, .g = 120, .b = 65,  .a = 35 },
    .active_border   = .{ .r = 185, .g = 120, .b = 65,  .a = 60 },
    .text_main       = .{ .r = 215, .g = 205, .b = 190, .a = 255 },
    .text_muted      = .{ .r = 140, .g = 115, .b = 90,  .a = 255 },
    .text_dim        = .{ .r = 100, .g = 80,  .b = 58,  .a = 255 },
    .danger          = .{ .r = 185, .g = 95,  .b = 95,  .a = 255 },
    .success         = .{ .r = 65,  .g = 165, .b = 105, .a = 255 },
    .warning         = .{ .r = 190, .g = 160, .b = 50,  .a = 255 },
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

// ── Dimensions ──

pub const dims = struct {
    pub const rad_sm = dvui.Rect.all(4);
    pub const rad_md = dvui.Rect.all(8);
    pub const rad_lg = dvui.Rect.all(12);
    pub const rad_xl = dvui.Rect.all(16);

    pub const pad_xs = dvui.Rect.all(3);
    pub const pad_sm = dvui.Rect.all(6);
    pub const pad_md = dvui.Rect.all(10);
    pub const pad_lg = dvui.Rect.all(12);
};

// ── Apply to dvui global ──

fn applyToDvui() void {
    var t = dvui.themeGet();
    t.dark = true;
    t.text = colors.text_main;
    t.text_hover = colors.text_main;
    t.text_press = colors.accent;
    t.fill = colors.bg_app;
    t.fill_hover = colors.bg_card_hover;
    t.fill_press = colors.bg_header_border;
    t.border = colors.border_input;
    dvui.themeSet(t);
}

pub fn setTheme() void {
    colors = getThemeColors(active_preset);
    applyToDvui();
}

// ══════════════════════════════════════════════════════════
// Standard Option Presets (composable)
// ══════════════════════════════════════════════════════════

pub fn optHeader() dvui.Options {
    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = colors.bg_header,
        .color_border = colors.bg_header_border,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = dims.pad_sm,
    };
}

pub fn optDrawer() dvui.Options {
    return .{
        .min_size_content = .{ .w = 480, .h = 10 },
        .expand = .vertical,
        .background = true,
        .color_fill = colors.bg_drawer,
        .color_border = colors.border_drawer,
        .border = .{ .x = 1, .y = 0, .w = 0, .h = 0 },
        .padding = dims.pad_lg,
    };
}

pub fn optCard() dvui.Options {
    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = colors.bg_card,
        .color_border = colors.border_card,
        .border = dvui.Rect.all(1),
        .corner_radius = dims.rad_md,
        .padding = dims.pad_sm,
        .margin = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
    };
}

pub fn optGlassPanel() dvui.Options {
    return .{
        .background = true,
        .color_fill = colors.bg_glass,
        .color_border = colors.border_glass,
        .border = dvui.Rect.all(1),
        .corner_radius = dims.rad_lg,
        .padding = dims.pad_md,
        .box_shadow = .{ .color = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 140 }, .offset = .{ .x = 0, .y = 4 }, .fade = 16.0 },
    };
}

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

/// Transparent background icon button
pub fn optIconBtn() dvui.Options {
    return .{
        .color_text = colors.text_main,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border = dvui.Rect.all(0),
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

/// Accent-filled button
pub fn optAccentBtn() dvui.Options {
    return .{
        .color_fill = colors.accent,
        .color_text = colors.bg_app,
        .corner_radius = dims.rad_sm,
        .border = dvui.Rect.all(0),
    };
}

/// Accent icon button (active toggle)
pub fn optIconBtnAccent() dvui.Options {
    return .{
        .color_text = colors.accent,
        .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border = dvui.Rect.all(0),
    };
}

/// Badge with accent background
pub fn optBadge() dvui.Options {
    return .{
        .color_fill = colors.accent,
        .color_text = colors.bg_app,
        .corner_radius = dvui.Rect.all(99),
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
    };
}

/// Muted text label
pub fn optMutedLabel() dvui.Options {
    return .{
        .color_text = colors.text_muted,
    };
}

/// Dim text label (tertiary info — timestamps, metadata)
pub fn optDimLabel() dvui.Options {
    return .{
        .color_text = colors.text_dim,
    };
}

/// Pill-shaped toggle button (for tabs)
pub fn optPill(active: bool) dvui.Options {
    return .{
        .color_fill = if (active) colors.accent else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .color_text = if (active) colors.bg_app else colors.text_muted,
        .corner_radius = dvui.Rect.all(99),
        .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
    };
}

/// Floating card with deeper shadow
pub fn optFloatingCard() dvui.Options {
    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = colors.bg_elevated,
        .color_border = colors.border_card,
        .border = dvui.Rect.all(1),
        .corner_radius = dims.rad_lg,
        .padding = dims.pad_md,
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
        .box_shadow = .{ .color = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 160 }, .offset = .{ .x = 0, .y = 4 }, .fade = 20.0 },
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

/// Search input with prominent styling
pub fn optSearchInput() dvui.Options {
    return .{
        .expand = .horizontal,
        .color_fill = colors.bg_input,
        .color_border = colors.border_input,
        .color_text = colors.text_main,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(20),
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
    };
}

/// Surface-level card (slightly elevated from app bg)
pub fn optSurfaceCard() dvui.Options {
    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = colors.bg_surface,
        .corner_radius = dims.rad_md,
        .padding = dims.pad_md,
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
    };
}

/// Card with accent glow on hover
pub fn optGlowCard() dvui.Options {
    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = colors.bg_card,
        .color_border = colors.accent_glow,
        .border = dvui.Rect.all(1),
        .corner_radius = dims.rad_md,
        .padding = dims.pad_md,
        .margin = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        .box_shadow = .{ .color = colors.accent_glow, .offset = .{ .x = 0, .y = 0 }, .fade = 8.0 },
    };
}

/// Button group separator (thin vertical line)
pub fn optBtnGroupSep() dvui.Options {
    return .{
        .background = true,
        .color_fill = colors.divider,
        .min_size_content = .{ .w = 1, .h = 14 },
        .margin = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
    };
}
