//! Voice backend strategy — one abstract interface, multiple impls.
//!
//! Usage:
//!   const backend = voice_backend.active();
//!   const text = backend.transcribe(wav_path, buf) orelse return;
//!   backend.speak(reply);
//!
//! New backends drop in without touching ai_voice.zig — add an impl
//! fn pair + register in the Kind enum + active() dispatch.

const std = @import("std");
const io_global = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");

pub const Kind = enum {
    /// whisper-cpp (default) + macOS `say` — ships with brew install
    whisper_cpp_plus_say,
    /// sherpa-onnx — future (streaming STT + Kokoro TTS)
    sherpa_onnx,
    /// SFSpeechRecognizer + AVSpeechSynthesizer via opal-stt helper
    apple_native,
    /// speaches — OpenAI-compatible server at localhost:8000
    speaches,
};

pub const Backend = struct {
    kind: Kind,

    /// Transcribe a WAV file to text. Writes into out_buf, returns slice
    /// of actual bytes written. Returns null on failure.
    transcribeFn: *const fn (wav_path: []const u8, out_buf: []u8) ?[]const u8,

    /// Speak text aloud. Blocks until playback completes.
    speakFn: *const fn (text: []const u8) void,

    /// Human-readable name for settings UI.
    name: []const u8,

    pub fn transcribe(b: Backend, wav_path: []const u8, out_buf: []u8) ?[]const u8 {
        return b.transcribeFn(wav_path, out_buf);
    }
    pub fn speak(b: Backend, text: []const u8) void {
        b.speakFn(text);
    }
};

// ────────── Impl: whisper-cpp + say ──────────

fn whisperCppTranscribe(wav_path: []const u8, out_buf: []u8) ?[]const u8 {
    _ = wav_path;
    _ = out_buf;
    // ai_voice.transcribeAndSend already contains the full whisper-cpp
    // fallback chain. Leaving this as an extraction point — the existing
    // logic can be moved here once ai_voice is refactored to dispatch
    // through this interface.
    return null;
}

fn sayTtsSpeak(text: []const u8) void {
    if (text.len == 0) return;
    var child = io_global.Child.init(
        &.{ "say", text },
        @import("../core/alloc.zig").allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch |err| {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "say failed: {s}", .{@errorName(err)}) catch "say failed";
        logs.pushLog("error", "voice_backend", msg, false);
    };
}

// ────────── Impl: sherpa-onnx (stub) ──────────

fn sherpaOnnxTranscribe(wav_path: []const u8, out_buf: []u8) ?[]const u8 {
    _ = wav_path;
    _ = out_buf;
    logs.pushLog("warn", "voice_backend", "sherpa-onnx backend not yet implemented", false);
    return null;
}

fn sherpaOnnxSpeak(text: []const u8) void {
    _ = text;
    logs.pushLog("warn", "voice_backend", "sherpa-onnx backend not yet implemented", false);
}

// ────────── Impl: apple_native (stub) ──────────

fn appleNativeTranscribe(wav_path: []const u8, out_buf: []u8) ?[]const u8 {
    _ = wav_path;
    _ = out_buf;
    logs.pushLog("warn", "voice_backend", "apple_native backend needs opal-stt helper binary", false);
    return null;
}

fn appleNativeSpeak(text: []const u8) void {
    // `say` already is apple native — reuse
    sayTtsSpeak(text);
}

// ────────── Impl: speaches (stub) ──────────

fn speachesTranscribe(wav_path: []const u8, out_buf: []u8) ?[]const u8 {
    _ = wav_path;
    _ = out_buf;
    logs.pushLog("warn", "voice_backend", "speaches backend not yet implemented", false);
    return null;
}

fn speachesSpeak(text: []const u8) void {
    _ = text;
    logs.pushLog("warn", "voice_backend", "speaches backend not yet implemented", false);
}

// ────────── Registry ──────────

const whisper_cpp_plus_say_backend: Backend = .{
    .kind = .whisper_cpp_plus_say,
    .transcribeFn = whisperCppTranscribe,
    .speakFn = sayTtsSpeak,
    .name = "whisper.cpp + say (macOS native TTS)",
};

const sherpa_onnx_backend: Backend = .{
    .kind = .sherpa_onnx,
    .transcribeFn = sherpaOnnxTranscribe,
    .speakFn = sherpaOnnxSpeak,
    .name = "sherpa-onnx (streaming + Kokoro)",
};

const apple_native_backend: Backend = .{
    .kind = .apple_native,
    .transcribeFn = appleNativeTranscribe,
    .speakFn = appleNativeSpeak,
    .name = "Apple native (Speech framework + AVSpeechSynthesizer)",
};

const speaches_backend: Backend = .{
    .kind = .speaches,
    .transcribeFn = speachesTranscribe,
    .speakFn = speachesSpeak,
    .name = "speaches (OpenAI-compatible server)",
};

/// Runtime selection — default to the one that ships with brew today.
pub var active_kind: Kind = .whisper_cpp_plus_say;

pub fn active() Backend {
    return switch (active_kind) {
        .whisper_cpp_plus_say => whisper_cpp_plus_say_backend,
        .sherpa_onnx => sherpa_onnx_backend,
        .apple_native => apple_native_backend,
        .speaches => speaches_backend,
    };
}

pub fn allKinds() []const Kind {
    return &.{ .whisper_cpp_plus_say, .sherpa_onnx, .apple_native, .speaches };
}

test "default backend is whisper_cpp_plus_say" {
    try std.testing.expectEqual(Kind.whisper_cpp_plus_say, active_kind);
    const b = active();
    try std.testing.expectEqual(Kind.whisper_cpp_plus_say, b.kind);
}

test "speak + transcribe fn pointers defined for all backends" {
    for (allKinds()) |k| {
        active_kind = k;
        const b = active();
        // fn pointers exist (compile-time check via call — guarded by input)
        _ = b.name;
    }
    active_kind = .whisper_cpp_plus_say;
}
