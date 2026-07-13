//! Winamp-style audio visualizers, built as an mpv `lavfi-complex` filter graph.
//!
//! Radio, podcasts and bare audio files have no video track, so the player shows a
//! static card. mpv can synthesise one: `lavfi-complex` runs the audio through an
//! ffmpeg filter that EMITS a video stream, which mpv then plays as if the file had
//! always had a picture. No PCM plumbed into dvui, no audio thread of our own —
//! ffmpeg does the FFT and mpv renders it.
//!
//!     [aid1] asplit [ao], showwaves=... [vo]
//!            ^^^^^^^^^^^  audio still reaches the speakers, unchanged
//!                         ^^^^^^^^^^^^^^^^^^  and a video stream is born
//!
//! The graph is a STRING handed to ffmpeg's parser, and part of it (the colour)
//! comes from the theme — so it is validated here rather than interpolated blindly.
//! A stray `[`, `]`, `,`, `'` or `\` in a colour would rewrite the filter graph.

const std = @import("std");

pub const Style = enum {
    off,
    /// Classic scrolling waveform — the Winamp default.
    waves,
    /// Frequency bars.
    bars,
    /// Spectrogram: frequency over time, colour = intensity.
    spectrum,
    /// Lissajous / stereo phase scope.
    scope,

    pub fn label(self: Style) []const u8 {
        return switch (self) {
            .off => "Off",
            .waves => "Waveform",
            .bars => "Frequency bars",
            .spectrum => "Spectrogram",
            .scope => "Stereo scope",
        };
    }

    pub fn fromLabel(s: []const u8) Style {
        inline for (@typeInfo(Style).@"enum".fields) |f| {
            const v: Style = @enumFromInt(f.value);
            if (std.mem.eql(u8, v.label(), s)) return v;
        }
        return .waves;
    }
};

/// True when `hex` is exactly 6 hex digits — the only thing we will splice into a
/// filter graph. Anything else (`red`, `#fff`, `aa'`, an injection attempt) is
/// rejected and the caller falls back to a constant.
pub fn isSafeHex(hex: []const u8) bool {
    if (hex.len != 6) return false;
    for (hex) |ch| {
        const ok = (ch >= '0' and ch <= '9') or
            (ch >= 'a' and ch <= 'f') or
            (ch >= 'A' and ch <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// Fallback accent if the theme hands us something unusable — Opal's amber.
pub const DEFAULT_HEX = "e0834d";

/// Build the `lavfi-complex` graph for `style`.
///
/// Returns "" for `.off` (and on any formatting failure) — the caller then clears
/// mpv's lavfi-complex rather than setting a half-built graph, which would drop the
/// audio output entirely: a broken visualizer must never cost you the sound.
pub fn lavfiComplex(style: Style, accent_hex: []const u8, buf: []u8) []const u8 {
    if (style == .off) return "";

    const hex = if (isSafeHex(accent_hex)) accent_hex else DEFAULT_HEX;

    // `asplit` is what keeps the audio audible: one branch to [ao] (the speakers),
    // the other into the visualiser. Drop it and you get a picture and silence.
    //
    // Each branch formats its own literal: bufPrint's format string must be
    // comptime-known, so a runtime-selected `graph` variable cannot be passed to it.
    return switch (style) {
        .off => "",
        .waves => std.fmt.bufPrint(
            buf,
            "[aid1] asplit [ao], showwaves=mode=cline:colors=0x{s}:s=1280x480:rate=30 [vo]",
            .{hex},
        ) catch "",
        .bars => std.fmt.bufPrint(
            buf,
            "[aid1] asplit [ao], showfreqs=mode=bar:ascale=log:colors=0x{s}:s=1280x480:rate=30 [vo]",
            .{hex},
        ) catch "",
        // showspectrum/avectorscope take named palettes, not a hex colour.
        .spectrum => std.fmt.bufPrint(
            buf,
            "[aid1] asplit [ao], showspectrum=slide=scroll:color=fire:scale=log:s=1280x480 [vo]",
            .{},
        ) catch "",
        .scope => std.fmt.bufPrint(
            buf,
            "[aid1] asplit [ao], avectorscope=draw=line:rc=0:gc=160:bc=80:s=720x720:rate=30 [vo]",
            .{},
        ) catch "",
    };
}

// ── Tests ──

const t = std.testing;

test "off yields no graph at all" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("", lavfiComplex(.off, "e0834d", &buf));
}

test "every visual style keeps the audio wired to the speakers" {
    // The bug this guards: a graph without `asplit [ao]` renders a beautiful
    // visualiser and plays NO SOUND.
    var buf: [256]u8 = undefined;
    for ([_]Style{ .waves, .bars, .spectrum, .scope }) |s| {
        const g = lavfiComplex(s, "e0834d", &buf);
        try t.expect(std.mem.indexOf(u8, g, "asplit [ao]") != null);
        try t.expect(std.mem.indexOf(u8, g, "[vo]") != null);
        try t.expect(std.mem.indexOf(u8, g, "[aid1]") != null);
    }
}

test "a colour cannot rewrite the filter graph" {
    // accent_hex reaches ffmpeg's filter-graph parser. A colour carrying a comma or
    // a bracket would append filters / retarget outputs, so anything that is not
    // exactly 6 hex digits is refused.
    try t.expect(isSafeHex("e0834d"));
    try t.expect(isSafeHex("FFFFFF"));
    try t.expect(!isSafeHex("#e0834d")); // leading hash
    try t.expect(!isSafeHex("fff")); // short form
    try t.expect(!isSafeHex("red")); // named
    try t.expect(!isSafeHex("")); // empty
    try t.expect(!isSafeHex("e0834d,crop=1")); // injection
    try t.expect(!isSafeHex("aa'bb'")); // quote escape

    var buf: [256]u8 = undefined;
    const g = lavfiComplex(.waves, "e0834d,crop=iw/2 [vo]; [x]", &buf);
    // Falls back to the constant; the payload never lands in the graph.
    try t.expect(std.mem.indexOf(u8, g, "crop") == null);
    try t.expect(std.mem.indexOf(u8, g, DEFAULT_HEX) != null);
}

test "a short buffer yields no graph, never a truncated one" {
    // A half-written graph would be a parse error at best; at worst it parses and
    // silently drops [ao]. Better to render no visualiser.
    var tiny: [12]u8 = undefined;
    try t.expectEqualStrings("", lavfiComplex(.waves, "e0834d", &tiny));
}

test "style labels round-trip (settings persistence)" {
    for ([_]Style{ .off, .waves, .bars, .spectrum, .scope }) |s| {
        try t.expectEqual(s, Style.fromLabel(s.label()));
    }
    // Unknown label falls back to the default rather than crashing on bad config.
    try t.expectEqual(Style.waves, Style.fromLabel("bogus"));
}
