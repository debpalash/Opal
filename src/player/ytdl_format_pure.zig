//! yt-dlp `-f` (ytdl-format) selection — pure, so the exact format string mpv
//! hands yt-dlp is unit-testable. player.zig routes through `formatFor`.
//!
//! WHY AV1 IS DEPRIORITIZED
//! ------------------------
//! YouTube serves AV1 (`av01…`) as the "best" video at 1080p+ for many clips.
//! But most GPUs that ship in Macs before the M3 generation (and plenty of
//! older PCs) have NO hardware AV1 decoder, and mpv's videotoolbox path then
//! fails to initialise ("Your platform doesn't support hardware accelerated AV1
//! decoding" → "Failed to get pixel format" → "Video: no video") — audio plays
//! over a black frame. vp9 and h264 hardware-decode on those same machines, and
//! at YouTube's bitrates vp9 is visually on par with AV1.
//!
//! So each video tier asks for a non-AV1 stream FIRST, and only falls through to
//! an AV1/anything stream if a clip genuinely has nothing else. On a machine
//! that CAN decode AV1 this costs nothing (vp9 also decodes fine there). Height
//! is a soft cap (`<=?`) so a video with no rendition at/under the cap still
//! plays at its nearest available size rather than failing.
//!
//! WHY SDR IS PREFERRED OVER HDR
//! -----------------------------
//! For an HDR upload YouTube serves BOTH an HDR rendition (vp9.2 / 10-bit
//! av01, `dynamic_range=HDR10|HLG`) and an SDR one (8-bit vp9, `SDR`), and
//! yt-dlp's default ranking picks the HDR stream as "best". Opal renders
//! through `vo=libmpv` in software into an 8-bit RGBA buffer, so the display
//! never sees HDR metadata: the HDR stream only looks flat and grey (which the
//! `hdr` picture preset then has to grade back), and every frame costs a
//! 10-bit → 8-bit conversion on the UI thread. At 4K60 that conversion is a
//! large share of the per-frame budget, and the HDR stream is also ~20% more
//! bitrate for the same pixels. The SDR rendition is the one YouTube itself
//! shows on an SDR screen, so it is asked for first. `=?` lets a stream with
//! no `dynamic_range` field at all (non-YouTube extractors) pass, and the
//! chain falls through to any-range streams when a clip is HDR-only.

const std = @import("std");

/// Quality tiers, indexed by state.app.ytdl_format_idx. null height = audio-only.
pub const HEIGHTS = [_]?u16{ 720, 1080, 2160, null };

// Precomputed, NUL-terminated so the value can be handed straight to
// mpv_set_option_string. The chain per video tier is:
//   1. SDR, non-AV1 video (height-capped) + best audio
//   2. non-AV1 video (height-capped, any range) + best audio — HDR-only clip
//   3. non-AV1 video (uncapped) + best audio        — height had only AV1 under cap
//   4. best combined non-AV1 progressive stream
//   5. best (any codec, incl. AV1) — last resort so playback never hard-fails
const F720: [:0]const u8 =
    "bestvideo[height<=?720][vcodec!*=av01][dynamic_range=?SDR]+bestaudio/" ++
    "bestvideo[height<=?720][vcodec!*=av01]+bestaudio/" ++
    "bestvideo[vcodec!*=av01]+bestaudio/" ++
    "best[vcodec!*=av01]/best";
const F1080: [:0]const u8 =
    "bestvideo[height<=?1080][vcodec!*=av01][dynamic_range=?SDR]+bestaudio/" ++
    "bestvideo[height<=?1080][vcodec!*=av01]+bestaudio/" ++
    "bestvideo[vcodec!*=av01]+bestaudio/" ++
    "best[vcodec!*=av01]/best";
const F2160: [:0]const u8 =
    "bestvideo[height<=?2160][vcodec!*=av01][dynamic_range=?SDR]+bestaudio/" ++
    "bestvideo[height<=?2160][vcodec!*=av01]+bestaudio/" ++
    "bestvideo[vcodec!*=av01]+bestaudio/" ++
    "best[vcodec!*=av01]/best";
const FAUDIO: [:0]const u8 = "bestaudio/best";

/// The ytdl-format string for a quality index (clamped to the audio tier if out
/// of range). NUL-terminated for mpv_set_option_string.
pub fn formatFor(idx: usize) [:0]const u8 {
    return switch (idx) {
        0 => F720,
        1 => F1080,
        2 => F2160,
        else => FAUDIO,
    };
}

test "every video tier deprioritizes AV1 but still has an any-codec fallback" {
    for ([_]usize{ 0, 1, 2 }) |idx| {
        const f = formatFor(idx);
        // The primary selector excludes AV1…
        try std.testing.expect(std.mem.indexOf(u8, f, "[vcodec!*=av01]") != null);
        // …and it is the FIRST thing tried (before any bare "best").
        const excl = std.mem.indexOf(u8, f, "vcodec!*=av01").?;
        const first_best = std.mem.indexOf(u8, f, "best").?;
        try std.testing.expect(first_best < excl); // "bestvideo[" comes first, then the filter
        // …but a final any-codec fallback exists so a clip with only AV1 plays.
        try std.testing.expect(std.mem.endsWith(u8, f, "/best"));
    }
}

test "each video tier carries its own height cap" {
    try std.testing.expect(std.mem.indexOf(u8, formatFor(0), "height<=?720") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatFor(1), "height<=?1080") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatFor(2), "height<=?2160") != null);
}

// Regression: "4K YouTube stutters / looks washed out". An HDR upload has both
// an HDR and an SDR rendition; the software render path can only show SDR, and
// converting the 10-bit HDR stream cost UI-thread time on every 4K frame. The
// SDR rendition must be the FIRST selector, and it must fall through (same
// height cap, any range) so an HDR-only clip still plays.
test "every video tier asks for the SDR rendition first, then any range" {
    for ([_]usize{ 0, 1, 2 }) |idx| {
        const f = formatFor(idx);
        const sdr = std.mem.indexOf(u8, f, "[dynamic_range=?SDR]").?;
        // The SDR filter is inside the very first selector…
        const first_sep = std.mem.indexOfScalar(u8, f, '/').?;
        try std.testing.expect(sdr < first_sep);
        // …and is optional-match (`=?`) so extractors without the field pass.
        try std.testing.expect(std.mem.indexOf(u8, f, "[dynamic_range=SDR]") == null);
        // The second selector is the same height cap without a range filter.
        const rest = f[first_sep + 1 ..];
        const second_sep = std.mem.indexOfScalar(u8, rest, '/').?;
        const second = rest[0..second_sep];
        try std.testing.expect(std.mem.indexOf(u8, second, "height<=?") != null);
        try std.testing.expect(std.mem.indexOf(u8, second, "dynamic_range") == null);
        try std.testing.expect(std.mem.indexOf(u8, second, "[vcodec!*=av01]") != null);
    }
    // Audio tier is untouched by the range preference.
    try std.testing.expect(std.mem.indexOf(u8, formatFor(3), "dynamic_range") == null);
}

test "exact 4K chain (what mpv hands yt-dlp for the 4K tier)" {
    try std.testing.expectEqualStrings(
        "bestvideo[height<=?2160][vcodec!*=av01][dynamic_range=?SDR]+bestaudio/" ++
            "bestvideo[height<=?2160][vcodec!*=av01]+bestaudio/" ++
            "bestvideo[vcodec!*=av01]+bestaudio/" ++
            "best[vcodec!*=av01]/best",
        formatFor(2),
    );
}

test "audio tier is codec-agnostic and index-safe" {
    try std.testing.expectEqualStrings("bestaudio/best", formatFor(3));
    try std.testing.expectEqualStrings("bestaudio/best", formatFor(99)); // clamps
}

test "HEIGHTS lines up with the tiers" {
    try std.testing.expectEqual(@as(?u16, 720), HEIGHTS[0]);
    try std.testing.expectEqual(@as(?u16, 1080), HEIGHTS[1]);
    try std.testing.expectEqual(@as(?u16, 2160), HEIGHTS[2]);
    try std.testing.expectEqual(@as(?u16, null), HEIGHTS[3]);
}
