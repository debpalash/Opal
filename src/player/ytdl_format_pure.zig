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

const std = @import("std");

/// Quality tiers, indexed by state.app.ytdl_format_idx. null height = audio-only.
pub const HEIGHTS = [_]?u16{ 720, 1080, 2160, null };

// Precomputed, NUL-terminated so the value can be handed straight to
// mpv_set_option_string. The chain per video tier is:
//   1. non-AV1 video (height-capped) + best audio
//   2. non-AV1 video (uncapped) + best audio        — height had only AV1 under cap
//   3. best combined non-AV1 progressive stream
//   4. best (any codec, incl. AV1) — last resort so playback never hard-fails
const F720: [:0]const u8 =
    "bestvideo[height<=?720][vcodec!*=av01]+bestaudio/" ++
    "bestvideo[vcodec!*=av01]+bestaudio/" ++
    "best[vcodec!*=av01]/best";
const F1080: [:0]const u8 =
    "bestvideo[height<=?1080][vcodec!*=av01]+bestaudio/" ++
    "bestvideo[vcodec!*=av01]+bestaudio/" ++
    "best[vcodec!*=av01]/best";
const F2160: [:0]const u8 =
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
