//! Spoiler firewall for the Co-Watcher.
//!
//! Spoiler-safety for a LOCAL LLM commenting on a playing video is otherwise
//! prompt-only, which small models can leak past. This module provides two
//! deterministic, dependency-free pieces of an enforced firewall:
//!
//!   1. clampLine() — a strict, embeddable progress-clamp instruction injected
//!      into the model prompt.
//!   2. flagsSpoiler() — a cheap, CONSERVATIVE post-generation check that flags
//!      a remark only on strong, unambiguous beyond-now leak signals.
//!
//! Pure logic: std only. Never crashes, never allocates.

const std = @import("std");

/// Static fallback used when the caller-provided buffer is too small to hold
/// the formatted instruction. Intentionally percent-free and progress-free so
/// it is always a safe, valid sentence.
const fallback_clamp: []const u8 =
    "VIEWER PROGRESS: clamp strictly to what has happened so far. " ++
    "Only discuss what has already been shown. Never reveal, hint at, or " ++
    "foreshadow anything later — no endings, twists, deaths, or outcomes.";

/// Build a strict, embeddable progress-clamp instruction for the given viewer
/// progress percent. The instruction tells the model to discuss only what has
/// happened up to `percent` and to never reveal or foreshadow anything later.
///
/// Writes into `out` via std.fmt.bufPrint and returns the written slice. If
/// `out` is too small, returns a static fallback string instead (never errors).
pub fn clampLine(percent: u8, out: []u8) []const u8 {
    // Clamp the percent into the sane 0..100 range for display.
    const p: u8 = if (percent > 100) 100 else percent;
    return std.fmt.bufPrint(
        out,
        "VIEWER PROGRESS: {d}%. Only discuss what has happened up to {d}%. " ++
            "Never reveal, hint at, or foreshadow anything later — no endings, " ++
            "twists, deaths, or outcomes.",
        .{ p, p },
    ) catch fallback_clamp;
}

/// Strong, unambiguous beyond-now leak phrases. All entries are lowercase; the
/// remark is lowercased before scanning. Kept conservative to minimize false
/// positives — when unsure, we do NOT flag.
const spoiler_phrases = [_][]const u8{
    "at the end",
    "in the finale",
    "turns out that",
    "the twist is",
    "later you",
    "by the end",
    "spoiler",
    "ending",
    "dies at",
    "is killed",
    "the killer is",
    "secretly",
};

/// CONSERVATIVE heuristic post-generation check. Returns true only on strong,
/// unambiguous signals that the remark leaks beyond the viewer's current
/// progress. Returns false when unsure.
///
/// Lowercases up to a fixed stack-buffer prefix (cap 512) and scans only that
/// prefix for the strong phrases. Never allocates, never crashes.
pub fn flagsSpoiler(remark: []const u8) bool {
    var buf: [512]u8 = undefined;
    const n = @min(remark.len, buf.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i] = std.ascii.toLower(remark[i]);
    }
    const lowered = buf[0..n];

    for (spoiler_phrases) |phrase| {
        if (std.mem.indexOf(u8, lowered, phrase) != null) return true;
    }
    return false;
}

test "clampLine writes percent and discusses-up-to clamp" {
    var out: [256]u8 = undefined;
    const line = clampLine(37, &out);
    try std.testing.expect(std.mem.indexOf(u8, line, "37%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "VIEWER PROGRESS") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "Never reveal") != null);
}

test "clampLine clamps out-of-range percent" {
    var out: [256]u8 = undefined;
    const line = clampLine(250, &out);
    try std.testing.expect(std.mem.indexOf(u8, line, "100%") != null);
}

test "clampLine falls back when buffer too small" {
    var out: [8]u8 = undefined;
    const line = clampLine(50, &out);
    try std.testing.expectEqualStrings(fallback_clamp, line);
}

test "flagsSpoiler catches strong phrases, case-insensitive" {
    try std.testing.expect(flagsSpoiler("Wait until the END of the movie"));
    try std.testing.expect(flagsSpoiler("It turns out that he was lying"));
    try std.testing.expect(flagsSpoiler("The killer is the butler"));
    try std.testing.expect(flagsSpoiler("She secretly planned it"));
    try std.testing.expect(flagsSpoiler("By the end you'll see"));
}

test "flagsSpoiler stays conservative on benign remarks" {
    try std.testing.expect(!flagsSpoiler("This chase scene is intense!"));
    try std.testing.expect(!flagsSpoiler("Nice cinematography here."));
    try std.testing.expect(!flagsSpoiler(""));
}
