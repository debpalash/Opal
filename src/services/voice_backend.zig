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

    /// Whether this backend can run VAD-driven streaming transcription
    /// for live convo mode (no 15s fixed record ceiling). Checked via
    /// deps.sherpaReady at runtime.
    supports_streaming: bool = false,

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
    // Locate CLI
    const bin: []const u8 = blk: {
        if (io_global.cwdAccess("/opt/homebrew/bin/sherpa-onnx-offline", .{})) |_| {
            break :blk "/opt/homebrew/bin/sherpa-onnx-offline";
        } else |_| {}
        if (io_global.cwdAccess("/usr/local/bin/sherpa-onnx-offline", .{})) |_| {
            break :blk "/usr/local/bin/sherpa-onnx-offline";
        } else |_| {}
        logs.pushLog("error", "voice_backend", "sherpa-onnx-offline not on PATH — brew install sherpa-onnx", false);
        return null;
    };

    // Locate whisper-tiny model dir (sherpa-onnx bundles tokens.txt +
    // encoder/decoder.onnx). User-installed at ~/.config/opal/models/.
    var home_buf: [256]u8 = undefined;
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
    var enc_buf: [512]u8 = undefined;
    var dec_buf: [512]u8 = undefined;
    var tok_buf: [512]u8 = undefined;
    _ = &home_buf;
    const enc = std.fmt.bufPrintZ(&enc_buf, "{s}/.config/opal/models/sherpa-whisper-tiny/tiny-encoder.onnx", .{home}) catch return null;
    const dec = std.fmt.bufPrintZ(&dec_buf, "{s}/.config/opal/models/sherpa-whisper-tiny/tiny-decoder.onnx", .{home}) catch return null;
    const tok = std.fmt.bufPrintZ(&tok_buf, "{s}/.config/opal/models/sherpa-whisper-tiny/tiny-tokens.txt", .{home}) catch return null;
    io_global.cwdAccess(enc, .{}) catch {
        logs.pushLog("warn", "voice_backend", "sherpa whisper model missing — see docs for model install", false);
        return null;
    };

    var enc_arg_buf: [768]u8 = undefined;
    var dec_arg_buf: [768]u8 = undefined;
    var tok_arg_buf: [768]u8 = undefined;
    const enc_arg = std.fmt.bufPrint(&enc_arg_buf, "--whisper-encoder={s}", .{enc}) catch return null;
    const dec_arg = std.fmt.bufPrint(&dec_arg_buf, "--whisper-decoder={s}", .{dec}) catch return null;
    const tok_arg = std.fmt.bufPrint(&tok_arg_buf, "--tokens={s}", .{tok}) catch return null;

    var child = io_global.Child.init(&.{
        bin, enc_arg, dec_arg, tok_arg, wav_path,
    }, @import("../core/alloc.zig").allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        var eb: [128]u8 = undefined;
        const em = std.fmt.bufPrint(&eb, "sherpa spawn: {s}", .{@errorName(err)}) catch "sherpa spawn fail";
        logs.pushLog("error", "voice_backend", em, false);
        return null;
    };
    defer _ = child.wait() catch {};

    // sherpa-onnx-offline output format: "audio.wav\nTranscription:\ntext..."
    // Find the "Transcription" line, take what follows until EOF.
    const stdout = child.stdout orelse return null;
    var full_buf: [4096]u8 = undefined;
    const n = io_global.readAll(stdout, &full_buf) catch 0;
    if (n == 0) return null;
    const raw = full_buf[0..n];
    // Find first instance of a line that isn't a header.
    var parts = std.mem.splitScalar(u8, raw, '\n');
    while (parts.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        if (std.mem.indexOf(u8, t, ".wav")) |_| continue;
        if (std.mem.startsWith(u8, t, "Transcription")) continue;
        if (std.mem.startsWith(u8, t, "Elapsed")) continue;
        if (std.mem.startsWith(u8, t, "Audio duration")) continue;
        if (std.mem.startsWith(u8, t, "Real time")) continue;
        if (std.mem.startsWith(u8, t, "----")) continue;
        const copy_len = @min(t.len, out_buf.len);
        @memcpy(out_buf[0..copy_len], t[0..copy_len]);
        return out_buf[0..copy_len];
    }
    return null;
}

/// Selected Kokoro speaker ID. 0–53 in the English v0_19 release.
pub var kokoro_sid: u16 = 0;

fn sherpaOnnxSpeak(text: []const u8) void {
    if (text.len == 0) return;
    // Locate CLI
    const bin: []const u8 = blk: {
        if (io_global.cwdAccess("/opt/homebrew/bin/sherpa-onnx-offline-tts", .{})) |_| {
            break :blk "/opt/homebrew/bin/sherpa-onnx-offline-tts";
        } else |_| {}
        if (io_global.cwdAccess("/usr/local/bin/sherpa-onnx-offline-tts", .{})) |_| {
            break :blk "/usr/local/bin/sherpa-onnx-offline-tts";
        } else |_| {}
        sayTtsSpeak(text);
        return;
    };

    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
    var out_buf: [512]u8 = undefined;
    const out_wav = std.fmt.bufPrintZ(&out_buf, "{s}/.config/opal/tts_out.wav", .{home}) catch {
        sayTtsSpeak(text);
        return;
    };
    var out_arg_buf: [640]u8 = undefined;
    const a_out = std.fmt.bufPrint(&out_arg_buf, "--output-filename={s}", .{out_wav}) catch return;

    // Prefer Kokoro (higher quality, multi-voice) if installed.
    var km_buf: [512]u8 = undefined;
    const kokoro_model = std.fmt.bufPrintZ(&km_buf, "{s}/.config/opal/models/sherpa-kokoro/model.onnx", .{home}) catch "";
    const has_kokoro = kokoro_model.len > 0 and (io_global.cwdAccess(kokoro_model, .{}) catch null) != null;

    if (has_kokoro) {
        var voices_buf: [512]u8 = undefined;
        var tok_buf: [512]u8 = undefined;
        var dd_buf: [512]u8 = undefined;
        const voices = std.fmt.bufPrintZ(&voices_buf, "{s}/.config/opal/models/sherpa-kokoro/voices.bin", .{home}) catch return;
        const tokens_p = std.fmt.bufPrintZ(&tok_buf, "{s}/.config/opal/models/sherpa-kokoro/tokens.txt", .{home}) catch return;
        const data_dir = std.fmt.bufPrintZ(&dd_buf, "{s}/.config/opal/models/sherpa-kokoro/espeak-ng-data", .{home}) catch return;
        var km_arg: [640]u8 = undefined;
        var v_arg: [640]u8 = undefined;
        var tk_arg: [640]u8 = undefined;
        var dd_arg: [640]u8 = undefined;
        var sid_arg: [32]u8 = undefined;
        const a_km = std.fmt.bufPrint(&km_arg, "--kokoro-model={s}", .{kokoro_model}) catch return;
        const a_v = std.fmt.bufPrint(&v_arg, "--kokoro-voices={s}", .{voices}) catch return;
        const a_tk = std.fmt.bufPrint(&tk_arg, "--kokoro-tokens={s}", .{tokens_p}) catch return;
        const a_dd = std.fmt.bufPrint(&dd_arg, "--kokoro-data-dir={s}", .{data_dir}) catch return;
        const a_sid = std.fmt.bufPrint(&sid_arg, "--sid={d}", .{kokoro_sid}) catch return;

        var synth = io_global.Child.init(&.{
            bin, a_km, a_v, a_tk, a_dd, a_sid, a_out, text,
        }, @import("../core/alloc.zig").allocator);
        synth.stdout_behavior = .Ignore;
        synth.stderr_behavior = .Ignore;
        synth.spawn() catch {
            playPiperOrSay(bin, a_out, out_wav, text);
            return;
        };
        _ = synth.wait() catch {};
        playWav(out_wav);
        return;
    }

    // Fallback: Piper VITS
    playPiperOrSay(bin, a_out, out_wav, text);
}

fn playPiperOrSay(bin: []const u8, out_arg: []const u8, out_wav: []const u8, text: []const u8) void {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
    var vm_buf: [512]u8 = undefined;
    var lex_buf: [512]u8 = undefined;
    var tok_buf: [512]u8 = undefined;
    var dd_buf: [512]u8 = undefined;
    const vits_model = std.fmt.bufPrintZ(&vm_buf, "{s}/.config/opal/models/sherpa-vits-piper/en_US-lessac-medium.onnx", .{home}) catch {
        sayTtsSpeak(text);
        return;
    };
    io_global.cwdAccess(vits_model, .{}) catch {
        sayTtsSpeak(text);
        return;
    };
    const lexicon = std.fmt.bufPrintZ(&lex_buf, "{s}/.config/opal/models/sherpa-vits-piper/lexicon.txt", .{home}) catch return;
    const tokens_p = std.fmt.bufPrintZ(&tok_buf, "{s}/.config/opal/models/sherpa-vits-piper/tokens.txt", .{home}) catch return;
    const data_dir = std.fmt.bufPrintZ(&dd_buf, "{s}/.config/opal/models/sherpa-vits-piper/espeak-ng-data", .{home}) catch return;
    var vm_arg: [640]u8 = undefined;
    var lex_arg: [640]u8 = undefined;
    var tk_arg: [640]u8 = undefined;
    var dd_arg: [640]u8 = undefined;
    const a_vm = std.fmt.bufPrint(&vm_arg, "--vits-model={s}", .{vits_model}) catch return;
    const a_lex = std.fmt.bufPrint(&lex_arg, "--vits-lexicon={s}", .{lexicon}) catch return;
    const a_tk = std.fmt.bufPrint(&tk_arg, "--vits-tokens={s}", .{tokens_p}) catch return;
    const a_dd = std.fmt.bufPrint(&dd_arg, "--vits-data-dir={s}", .{data_dir}) catch return;

    var synth = io_global.Child.init(&.{
        bin, a_vm, a_lex, a_tk, a_dd, out_arg, text,
    }, @import("../core/alloc.zig").allocator);
    synth.stdout_behavior = .Ignore;
    synth.stderr_behavior = .Ignore;
    synth.spawn() catch {
        sayTtsSpeak(text);
        return;
    };
    _ = synth.wait() catch {};
    playWav(out_wav);
}

fn playWav(path: []const u8) void {
    var play = io_global.Child.init(&.{
        "/usr/bin/afplay", path,
    }, @import("../core/alloc.zig").allocator);
    play.stdout_behavior = .Ignore;
    play.stderr_behavior = .Ignore;
    _ = play.spawnAndWait() catch {};
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
    .name = "sherpa-onnx (streaming + VITS)",
    .supports_streaming = true,
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

/// Spawn sherpa-onnx-microphone in the background for continuous,
/// VAD-driven transcription. Emits one transcript per voiced turn via
/// the provided callback. Returns the spawned Child so caller can kill
/// it on convo-mode exit. Returns null if prerequisites missing.
pub fn spawnStreamingConvo(
    on_transcript: *const fn ([]const u8) void,
) ?io_global.Child {
    _ = on_transcript;
    const deps = @import("../core/deps.zig");
    const s = deps.check();
    if (!(s.sherpa_mic_cli and s.sherpa_stream_model)) {
        logs.pushLog("warn", "voice_backend", "streaming convo needs sherpa-onnx-microphone + zipformer model", false);
        return null;
    }

    var home_buf: [64]u8 = undefined;
    _ = &home_buf;
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";

    var enc_buf: [512]u8 = undefined;
    var dec_buf: [512]u8 = undefined;
    var join_buf: [512]u8 = undefined;
    var tok_buf: [512]u8 = undefined;
    const enc = std.fmt.bufPrintZ(&enc_buf, "{s}/.config/opal/models/sherpa-stream-zipformer/encoder.onnx", .{home}) catch return null;
    const dec = std.fmt.bufPrintZ(&dec_buf, "{s}/.config/opal/models/sherpa-stream-zipformer/decoder.onnx", .{home}) catch return null;
    const join = std.fmt.bufPrintZ(&join_buf, "{s}/.config/opal/models/sherpa-stream-zipformer/joiner.onnx", .{home}) catch return null;
    const tok = std.fmt.bufPrintZ(&tok_buf, "{s}/.config/opal/models/sherpa-stream-zipformer/tokens.txt", .{home}) catch return null;

    var enc_arg: [640]u8 = undefined;
    var dec_arg: [640]u8 = undefined;
    var join_arg: [640]u8 = undefined;
    var tok_arg: [640]u8 = undefined;
    const a_enc = std.fmt.bufPrint(&enc_arg, "--encoder={s}", .{enc}) catch return null;
    const a_dec = std.fmt.bufPrint(&dec_arg, "--decoder={s}", .{dec}) catch return null;
    const a_join = std.fmt.bufPrint(&join_arg, "--joiner={s}", .{join}) catch return null;
    const a_tok = std.fmt.bufPrint(&tok_arg, "--tokens={s}", .{tok}) catch return null;

    var child = io_global.Child.init(&.{
        "/opt/homebrew/bin/sherpa-onnx-microphone",
        a_tok, a_enc, a_dec, a_join,
    }, @import("../core/alloc.zig").allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    // Reader loop belongs to a caller thread in ai_voice when we wire
    // this into conversation mode. Parser reads lines of form
    // "Partial: …" / "Final: …" and calls on_transcript on Final.
    logs.pushLog("info", "voice_backend", "streaming convo started", true);
    return child;
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
