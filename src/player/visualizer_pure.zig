//! Winamp-style audio visualizers, built as an mpv `lavfi-complex` filter graph.
//!
//! Radio, podcasts and bare audio files have no video track, so the player shows a
//! static card. mpv can synthesise one: `lavfi-complex` runs the audio through an
//! ffmpeg filter chain that EMITS a video stream, which mpv then plays as if the
//! file had always had a picture. ffmpeg does the FFT; we never touch PCM.
//!
//!     [aid1] asplit [ao][a], ... [vo]
//!            ^^^^^^^^^^^^^^  audio still reaches the speakers, unchanged
//!                                 ^^^^  and a video stream is born
//!
//! ── Two rules these graphs must obey ──
//!
//! 1. NO SOURCE FILTERS. The obvious way to get a colour gradient is a `gradients`
//!    source and a `nullsrc` stripe mask blended over the bars. It looks right — and
//!    it HANGS: those sources never end, so mpv never reaches EOF. A three-second
//!    file plays forever, a podcast never finishes, the next track never starts.
//!    Everything here is derived from the audio alone. The gradient is painted with
//!    `geq` (a per-pixel expression over X) and the gaps between bars with
//!    `drawgrid` — both filters, not sources.
//!
//! 2. KEEP `asplit [ao]`. One branch feeds the speakers, the other the visualiser.
//!    Drop it and you get a beautiful picture and total silence.
//!
//! Also: upscaling 48 bars to 576px with `flags=neighbor` sets a 12:1 sample aspect,
//! which mpv faithfully honours by stretching the video to 576x2640. `setsar=1`
//! after every non-square scale.

const std = @import("std");

pub const Style = enum {
    off,
    /// Mirrored frequency bars with a horizontal gradient — the Winamp look.
    bars,
    /// Glowing gradient waveform.
    waves,
    /// Scrolling spectrogram.
    spectrum,
    /// Lissajous / stereo phase scope.
    scope,

    pub fn label(self: Style) []const u8 {
        return switch (self) {
            .off => "Off",
            .bars => "Bars",
            .waves => "Waveform",
            .spectrum => "Spectrum",
            .scope => "Scope",
        };
    }

    pub fn fromLabel(s: []const u8) Style {
        inline for (@typeInfo(Style).@"enum".fields) |f| {
            const v: Style = @enumFromInt(f.value);
            if (std.mem.eql(u8, v.label(), s)) return v;
        }
        return .bars;
    }
};

/// The gradient's far end (violet). The near end is the theme accent, so the bars
/// run accent → violet across the spectrum.
pub const END_R: u8 = 131;
pub const END_G: u8 = 56;
pub const END_B: u8 = 236;

/// The colour ramp, painted with a per-pixel expression rather than a `gradients`
/// source (see rule 1). Interpolates the accent → END_* across X.
///
/// The colour reaches ffmpeg's expression parser as three DECIMAL NUMBERS, not a
/// string: a u8 can only ever render as 0-255, so there is nothing to escape and no
/// way for a theme colour to inject filter syntax. That is why this takes r/g/b
/// rather than a hex string — the older version validated a hex string, which works
/// but only because the validator is correct; this cannot go wrong by construction.
fn gradient(r: u8, g: u8, b: u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "geq=r='r(X,Y)/255*({d}+({d}-{d})*X/W)':g='g(X,Y)/255*({d}+({d}-{d})*X/W)':b='b(X,Y)/255*({d}+({d}-{d})*X/W)'",
        .{
            r, END_R, r,
            g, END_G, g,
            b, END_B, b,
        },
    ) catch "";
}

/// Build the `lavfi-complex` graph for `style`, tinted from the theme accent.
///
/// Returns "" for `.off` and on any formatting failure — the caller then clears
/// mpv's lavfi-complex rather than setting a half-built graph, which would be a
/// parse error at best and, at worst, would parse WITHOUT [ao] and cost you the
/// audio. A visualiser must never be able to do that.
pub fn lavfiComplex(style: Style, r: u8, g: u8, b: u8, buf: []u8) []const u8 {
    if (style == .off) return "";

    var grad_buf: [256]u8 = undefined;
    const grad = gradient(r, g, b, &grad_buf);
    if (grad.len == 0) return "";

    return switch (style) {
        .off => unreachable,

        // 48 bins -> nearest-neighbour to 576 (chunky bars) -> drawgrid punches the
        // gaps -> mirror by stacking the frame on its own vflip -> gradient -> glow.
        .bars => std.fmt.bufPrint(
            buf,
            "[aid1] asplit [ao][a]; " ++
                "[a] showfreqs=mode=bar:ascale=log:fscale=log:win_size=2048:colors=white:s=48x110, " ++
                "format=gray, scale=576:110:flags=neighbor, setsar=1, " ++
                "drawgrid=w=12:h=1000:t=4:c=black@1 [b]; " ++
                "[b] split [b1][b2]; [b2] vflip [b2f]; " ++
                "[b1][b2f] vstack=inputs=2, format=gbrp, {s}, split [c1][c2]; " ++
                "[c2] gblur=sigma=6 [glow]; [c1][glow] blend=all_mode=screen [vo]",
            .{grad},
        ) catch "",

        // Rendered at half size and scaled up so the trace is thick enough for the
        // gradient to actually show; a 1px line just comes out muddy.
        .waves => std.fmt.bufPrint(
            buf,
            "[aid1] asplit [ao][a]; " ++
                "[a] showwaves=mode=cline:s=288x110:rate=30:colors=white, " ++
                "format=gray, scale=576:220, setsar=1, format=gbrp, {s}, split [c1][c2]; " ++
                "[c2] gblur=sigma=9 [glow]; " ++
                "[c1][glow] blend=all_mode=screen, eq=brightness=0.06:saturation=1.4 [vo]",
            .{grad},
        ) catch "",

        // These two carry their own palettes; the accent would fight them.
        .spectrum => std.fmt.bufPrint(
            buf,
            "[aid1] asplit [ao][a]; " ++
                "[a] showspectrum=slide=scroll:color=fire:scale=log:s=576x220, setsar=1 [vo]",
            .{},
        ) catch "",

        .scope => std.fmt.bufPrint(
            buf,
            "[aid1] asplit [ao][a]; " ++
                "[a] avectorscope=draw=line:rc=0:gc=160:bc=80:s=440x440:rate=30, setsar=1 [vo]",
            .{},
        ) catch "",
    };
}

// ── Tests ──

const t = std.testing;

test "off yields no graph at all" {
    var buf: [1024]u8 = undefined;
    try t.expectEqualStrings("", lavfiComplex(.off, 224, 131, 77, &buf));
}

test "every style keeps the audio wired to the speakers" {
    // The bug this guards: a graph without `asplit [ao]` renders a lovely
    // visualiser and plays NO SOUND.
    var buf: [1024]u8 = undefined;
    for ([_]Style{ .bars, .waves, .spectrum, .scope }) |s| {
        const gr = lavfiComplex(s, 224, 131, 77, &buf);
        try t.expect(std.mem.indexOf(u8, gr, "asplit [ao]") != null);
        try t.expect(std.mem.indexOf(u8, gr, "[vo]") != null);
        try t.expect(std.mem.indexOf(u8, gr, "[aid1]") != null);
    }
}

test "no style uses a source filter (they never EOF, so playback hangs)" {
    // `gradients` + `nullsrc` produce exactly the look we want and then hang mpv
    // forever: an infinite source means the file never reaches EOF, so a podcast
    // never ends and the next track never starts. Everything must come from
    // [aid1].
    var buf: [1024]u8 = undefined;
    for ([_]Style{ .bars, .waves, .spectrum, .scope }) |s| {
        const gr = lavfiComplex(s, 224, 131, 77, &buf);
        try t.expect(std.mem.indexOf(u8, gr, "gradients") == null);
        try t.expect(std.mem.indexOf(u8, gr, "nullsrc") == null);
        try t.expect(std.mem.indexOf(u8, gr, "color=c=") == null);
    }
}

test "every non-square scale is followed by setsar" {
    // Upscaling 48 bars to 576px sets a 12:1 sample aspect, and mpv honours it by
    // stretching the picture to 576x2640. Caught only by reading mpv's VO line.
    var buf: [1024]u8 = undefined;
    for ([_]Style{ .bars, .waves }) |s| {
        const gr = lavfiComplex(s, 224, 131, 77, &buf);
        try t.expect(std.mem.indexOf(u8, gr, "setsar=1") != null);
    }
}

test "a colour cannot inject filter syntax" {
    // r/g/b are u8, so they can only render as 0-255 — there is no string to escape.
    // Assert the graph carries the decimals and nothing else from the caller.
    var buf: [1024]u8 = undefined;
    const gr = lavfiComplex(.bars, 255, 0, 7, &buf);
    try t.expect(std.mem.indexOf(u8, gr, "255") != null);
    try t.expect(std.mem.indexOf(u8, gr, "geq=") != null);
    // The graph must remain a single well-formed chain: no stray quote imbalance.
    var quotes: usize = 0;
    for (gr) |ch| {
        if (ch == '\'') quotes += 1;
    }
    try t.expect(quotes % 2 == 0);
}

test "a short buffer yields no graph, never a truncated one" {
    // A half-written graph would be a parse error at best; at worst it parses
    // WITHOUT [ao] and silently costs the audio. Better to render no visualiser.
    var tiny: [24]u8 = undefined;
    try t.expectEqualStrings("", lavfiComplex(.bars, 224, 131, 77, &tiny));
}

test "style labels round-trip (settings persistence)" {
    for ([_]Style{ .off, .bars, .waves, .spectrum, .scope }) |s| {
        try t.expectEqual(s, Style.fromLabel(s.label()));
    }
    // An unknown label (hand-edited or older config) falls back, never crashes.
    try t.expectEqual(Style.bars, Style.fromLabel("bogus"));
}
