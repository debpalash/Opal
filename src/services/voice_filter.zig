//! Pure voice-transcription filter — no I/O, unit-testable.
//! Kept standalone so zig test (separate module root) can reach it
//! without crossing src/ subdirectory module boundaries.

const std = @import("std");

/// Detect Whisper hallucinations: transcription of silence/noise where
/// whisper confidently outputs common phrases. Return true → discard.
pub fn isHallucination(text: []const u8) bool {
    if (text.len < 4) return true;

    // Wrapped annotations: (machine whirring), [BLANK_AUDIO]
    if ((text[0] == '(' and text[text.len - 1] == ')') or
        (text[0] == '[' and text[text.len - 1] == ']'))
        return true;

    var lower: [256]u8 = undefined;
    const tlen = @min(text.len, 255);
    for (0..tlen) |i| lower[i] = std.ascii.toLower(text[i]);
    const lc = lower[0..tlen];

    const trimmed = std.mem.trim(u8, lc, " .!?,");
    if (trimmed.len < 3) return true;

    const shorts = [_][]const u8{ "you", "hmm", "yeah", "okay", "oh" };
    for (shorts) |s| if (std.mem.eql(u8, trimmed, s)) return true;

    const phrases = [_][]const u8{
        "machine whirring", "silence", "blank audio", "music",
        "applause",         "laughter",  "coughing",    "breathing",
        "thank you for watching",  "thanks for watching",
        "thank you for listening", "subscribe",
        "please subscribe", "like and subscribe",
        "see you next time", "bye bye",  "goodbye",
        "feature of zigzag", "zigzag",   "nando",
        "...",               "um,",      "uh,",
    };
    for (phrases) |p| {
        if (std.mem.indexOf(u8, lc, p) != null) return true;
    }
    return false;
}

test "real speech passes" {
    try std.testing.expect(!isHallucination("play iron man 3"));
    try std.testing.expect(!isHallucination("show me popular movies"));
    try std.testing.expect(!isHallucination("pause the video"));
    try std.testing.expect(!isHallucination("next episode please"));
}

test "silence/blank/noise annotations filtered" {
    try std.testing.expect(isHallucination("(silence)"));
    try std.testing.expect(isHallucination("[BLANK_AUDIO]"));
    try std.testing.expect(isHallucination("(music playing)"));
    try std.testing.expect(isHallucination("[applause]"));
}

test "short whisper garbage filtered" {
    try std.testing.expect(isHallucination("you"));
    try std.testing.expect(isHallucination("You."));
    try std.testing.expect(isHallucination("YOU"));
    try std.testing.expect(isHallucination("hmm"));
    try std.testing.expect(isHallucination("..."));
    try std.testing.expect(isHallucination("uh,"));
    try std.testing.expect(isHallucination("   "));
    try std.testing.expect(isHallucination("ok"));
}

test "common hallucination phrases filtered" {
    try std.testing.expect(isHallucination("Thanks for watching!"));
    try std.testing.expect(isHallucination("Please subscribe for more"));
    try std.testing.expect(isHallucination("Like and subscribe to my channel"));
    try std.testing.expect(isHallucination("see you next time"));
    try std.testing.expect(isHallucination("a feature of zigzag"));
}

test "tiny input filtered" {
    try std.testing.expect(isHallucination(""));
    try std.testing.expect(isHallucination("ab"));
    try std.testing.expect(isHallucination("abc")); // len < 4 triggers first guard
}
