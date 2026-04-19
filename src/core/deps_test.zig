//! Unit tests for deps.installCmd — pure string-builder logic, no I/O.

const std = @import("std");

// Inline a testable copy of Status + installCmd. We can't import
// deps.zig as a test-module root because it reaches into io_global
// which crosses the src/core module boundary for standalone tests.
const Status = struct {
    apfel: bool = false,
    ffmpeg: bool = false,
    whisper: bool = false,
    whisper_model: bool = false,
    sherpa_onnx: bool = false,
    sherpa_model: bool = false,
    sherpa_tts_model: bool = false,
    sherpa_kokoro_model: bool = false,
    sherpa_stream_model: bool = false,
    sherpa_mic_cli: bool = false,
};

fn installCmd(buf: []u8, s: Status) []const u8 {
    var parts: [8][]const u8 = undefined;
    var n: usize = 0;
    if (!s.apfel) { if (n < parts.len) { parts[n] = "apfel"; n += 1; } }
    if (!s.ffmpeg) { if (n < parts.len) { parts[n] = "ffmpeg"; n += 1; } }
    if (!s.whisper) { if (n < parts.len) { parts[n] = "whisper-cpp"; n += 1; } }
    if (n == 0) return "";

    var off: usize = 0;
    const prefix = "brew install ";
    @memcpy(buf[off..off + prefix.len], prefix);
    off += prefix.len;
    for (parts[0..n], 0..) |p, i| {
        if (i > 0) { buf[off] = ' '; off += 1; }
        @memcpy(buf[off..off + p.len], p);
        off += p.len;
    }
    return buf[0..off];
}

test "all present returns empty" {
    var buf: [256]u8 = undefined;
    const cmd = installCmd(&buf, .{ .apfel = true, .ffmpeg = true, .whisper = true });
    try std.testing.expectEqualStrings("", cmd);
}

test "nothing present lists all three" {
    var buf: [256]u8 = undefined;
    const cmd = installCmd(&buf, .{});
    try std.testing.expectEqualStrings("brew install apfel ffmpeg whisper-cpp", cmd);
}

test "single missing dep — whisper only" {
    var buf: [256]u8 = undefined;
    const cmd = installCmd(&buf, .{ .apfel = true, .ffmpeg = true, .whisper = false });
    try std.testing.expectEqualStrings("brew install whisper-cpp", cmd);
}

test "single missing dep — apfel only" {
    var buf: [256]u8 = undefined;
    const cmd = installCmd(&buf, .{ .apfel = false, .ffmpeg = true, .whisper = true });
    try std.testing.expectEqualStrings("brew install apfel", cmd);
}

test "two missing deps — apfel + ffmpeg" {
    var buf: [256]u8 = undefined;
    const cmd = installCmd(&buf, .{ .apfel = false, .ffmpeg = false, .whisper = true });
    try std.testing.expectEqualStrings("brew install apfel ffmpeg", cmd);
}

test "sherpa flags don't affect command (sherpa is opt-in)" {
    var buf: [256]u8 = undefined;
    const cmd = installCmd(&buf, .{
        .apfel = true, .ffmpeg = true, .whisper = true,
        .sherpa_onnx = false, .sherpa_model = false,
        .sherpa_tts_model = false, .sherpa_kokoro_model = false,
    });
    try std.testing.expectEqualStrings("", cmd);
}
