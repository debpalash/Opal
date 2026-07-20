//! mpv `ytdl-raw-options` construction — pure, so the exact option string mpv
//! receives is unit-testable. player.zig routes through `buildRawOptions`.
//!
//! WHY THERE IS NO PLAYER-CLIENT PIN HERE
//! -------------------------------------
//! This module used to emit `extractor-args=youtube:player_client=tv`. That was
//! added when YouTube started serving "Sign in to confirm you're not a bot" +
//! HTTP 429 to yt-dlp's default web client, and at the time the TVHTML5 client
//! was the one that still returned a direct stream URL without cookies.
//!
//! It has since become the opposite of a fix: the `tv` client now returns ONLY
//! storyboard formats (sb0..sb3) for a normal video, so mpv's format selector
//! (`bestvideo[height<=?N]+bestaudio/best`) matches nothing and EVERY YouTube
//! link fails with "Requested format is not available".
//!
//! yt-dlp maintains its own client-fallback chain and rotates it as YouTube
//! changes; pinning one client freezes us at whatever was true on the day the
//! pin was written and silently breaks playback later. So we pin nothing and
//! let yt-dlp choose. If a future bot-wall regression needs a specific client,
//! it belongs behind a user-visible setting with a documented expiry — not a
//! hardcoded constant.

const std = @import("std");

pub const Options = struct {
    /// Reuse the browser's cookie jar. Only set when a profile actually exists —
    /// yt-dlp hard-aborts ("could not find firefox cookies database") otherwise,
    /// which would take playback down with it.
    firefox_cookies: bool = false,
    /// Empty = direct.
    proxy: []const u8 = "",
};

/// Build the comma-separated `ytdl-raw-options` value. Returns the slice written
/// into `out`, or null when `out` is too small (caller then sets nothing rather
/// than a truncated option string, which mpv would misparse).
///
/// mpv splits this value on `,`, and each entry is `key=value` (a bare flag is
/// `key=`). A proxy URL containing a comma would corrupt every later entry, so
/// such a proxy is dropped rather than emitted.
pub fn buildRawOptions(opts: Options, out: []u8) ?[]const u8 {
    var w: usize = 0;

    const append = struct {
        fn f(buf: []u8, at: *usize, s: []const u8) bool {
            if (at.* + s.len > buf.len) return false;
            @memcpy(buf[at.*..][0..s.len], s);
            at.* += s.len;
            return true;
        }
    }.f;

    if (opts.firefox_cookies) {
        if (!append(out, &w, "cookies-from-browser=firefox,")) return null;
    }
    if (!append(out, &w, "no-check-certificates=,no-playlist=")) return null;

    // A comma in the proxy would be read by mpv as an option separator.
    if (opts.proxy.len > 0 and
        std.mem.indexOfScalar(u8, opts.proxy, ',') == null and
        std.mem.indexOfScalar(u8, opts.proxy, '\n') == null)
    {
        if (!append(out, &w, ",proxy=")) return null;
        if (!append(out, &w, opts.proxy)) return null;
    }

    return out[0..w];
}

test "default: no cookies, no proxy" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "no-check-certificates=,no-playlist=",
        buildRawOptions(.{}, &b).?,
    );
}

test "firefox cookies prefix" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "cookies-from-browser=firefox,no-check-certificates=,no-playlist=",
        buildRawOptions(.{ .firefox_cookies = true }, &b).?,
    );
}

test "proxy appended last" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "no-check-certificates=,no-playlist=,proxy=http://127.0.0.1:8080",
        buildRawOptions(.{ .proxy = "http://127.0.0.1:8080" }, &b).?,
    );
}

test "cookies + proxy together" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "cookies-from-browser=firefox,no-check-certificates=,no-playlist=,proxy=socks5://h:1",
        buildRawOptions(.{ .firefox_cookies = true, .proxy = "socks5://h:1" }, &b).?,
    );
}

test "a comma/newline in the proxy is dropped, not emitted" {
    var b: [400]u8 = undefined;
    try std.testing.expectEqualStrings(
        "no-check-certificates=,no-playlist=",
        buildRawOptions(.{ .proxy = "http://a,b" }, &b).?,
    );
    try std.testing.expectEqualStrings(
        "no-check-certificates=,no-playlist=",
        buildRawOptions(.{ .proxy = "http://a\nb" }, &b).?,
    );
}

test "too-small buffer yields null rather than a truncated option string" {
    var small: [8]u8 = undefined;
    try std.testing.expect(buildRawOptions(.{}, &small) == null);
}

// Regression: "YouTube links not playing / Requested format is not available".
// Pinning youtube:player_client=tv made every video resolve to storyboards only
// (sb0..sb3), so the height-based format selector matched nothing. Nothing this
// module emits may pin a player client again.
test "regression: never pins a youtube player client" {
    var b: [400]u8 = undefined;
    const cases = [_]Options{
        .{},
        .{ .firefox_cookies = true },
        .{ .proxy = "http://p:1" },
        .{ .firefox_cookies = true, .proxy = "http://p:1" },
    };
    for (cases) |o| {
        const s = buildRawOptions(o, &b).?;
        try std.testing.expect(std.mem.indexOf(u8, s, "player_client") == null);
        try std.testing.expect(std.mem.indexOf(u8, s, "extractor-args") == null);
    }
}
