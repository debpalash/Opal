//! Pure headless-mode detection.
//!
//! Decides whether Opal/zigzag should run in headless (no-GUI) server mode.
//! This module is intentionally PURE: it takes environment values as plain
//! parameters and imports NOTHING from the src/ boundary (no io_global, no
//! state), so it stays standalone-unit-testable with `zig build test`.
//!
//! Callers are responsible for fetching the env values (via io_global wrappers)
//! and detecting the OS, then passing them in.

const std = @import("std");

/// Decide whether to run headless.
///
/// Precedence:
///  1. Explicit override via OPAL_HEADLESS (opal_headless_env):
///     if non-null, headless = (value != "0"). So "1"/"true"/anything-but-"0"
///     => true; "0" => false. The explicit override wins both ways.
///  2. Otherwise, auto-detect: headless ONLY when running on Linux with no
///     DISPLAY and no WAYLAND_DISPLAY set (a typical headless Linux box).
///  3. Otherwise false (macOS desktop, or any DISPLAY/WAYLAND set).
pub fn detect(
    opal_headless_env: ?[]const u8,
    display_env: ?[]const u8,
    wayland_env: ?[]const u8,
    os_is_linux: bool,
) bool {
    if (opal_headless_env) |v| {
        return !std.mem.eql(u8, v, "0");
    }
    return os_is_linux and display_env == null and wayland_env == null;
}

test "explicit override OPAL_HEADLESS=1 forces headless" {
    try std.testing.expect(detect("1", "x", "y", false));
}

test "explicit override OPAL_HEADLESS=0 on a headless linux box forces windowed" {
    // Even though display + wayland are null and we're on linux (which would
    // otherwise auto-detect headless), the explicit "0" wins => false.
    try std.testing.expect(!detect("0", null, null, true));
}

test "explicit override OPAL_HEADLESS=true forces headless" {
    try std.testing.expect(detect("true", null, null, false));
}

test "auto-detect: linux + no display + no wayland => headless" {
    try std.testing.expect(detect(null, null, null, true));
}

test "auto-detect: linux + DISPLAY set => windowed" {
    try std.testing.expect(!detect(null, ":0", null, true));
}

test "auto-detect: linux + WAYLAND_DISPLAY set => windowed" {
    try std.testing.expect(!detect(null, null, "wayland-0", true));
}

test "auto-detect: macOS + all null => windowed" {
    try std.testing.expect(!detect(null, null, null, false));
}
