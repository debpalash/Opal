const std = @import("std");
const logs = @import("../core/logs.zig");

// ══════════════════════════════════════════════════════════
//  AI Voice — Mic Recording, ASR (Whisper), TTS
// ══════════════════════════════════════════════════════════

const MAX_INPUT_LEN = 512;
pub const LANG_SERVER_PORT: u16 = 41594;
pub const MIC_WAV_PATH = "/tmp/zigzag_ai_mic.wav";
pub const TTS_WAV_PATH = "/tmp/zigzag_ai_tts.wav";
const STT_SOCKET = "/tmp/zigzag-stt.sock";
const TTS_SOCKET = "/tmp/zigzag-tts.sock";
const VOICE_SOCKET = "/tmp/zigzag-voice.sock";

// ── Voice state (shared with ai_chat.zig) ──
pub var voice_mode: bool = false;
pub var is_recording: bool = false;
pub var is_transcribing: bool = false;
pub var is_speaking: bool = false;
pub var conversation_active: bool = false;
pub var conv_phase: ConvPhase = .idle;
pub var partial_text: [512]u8 = undefined;
pub var partial_text_len: usize = 0;
pub var state_mutex: @import("../core/sync.zig").Mutex = .{}; // Protects partial_text + phase state
var mic_thread: ?std.Thread = null;
var tts_thread: ?std.Thread = null;
var conv_thread: ?std.Thread = null;

// ── Persistent server PIDs ──
var stt_server_started: bool = false;
var tts_server_started: bool = false;
var voice_server_started: bool = false;
pub var voice_socket: ?std.Io.net.Stream = null;

pub const ConvPhase = enum {
    idle,
    listening,
    transcribing,
    thinking,
    speaking,
};

// ── Callbacks ──
// These are set by ai_chat.zig to wire transcription results back into the chat
var on_transcribed_fn: ?*const fn ([]const u8) void = null;
var set_error_fn: ?*const fn ([]const u8) void = null;

pub fn setCallbacks(
    on_transcribed: *const fn ([]const u8) void,
    set_error: *const fn ([]const u8) void,
) void {
    on_transcribed_fn = on_transcribed;
    set_error_fn = set_error;
}

fn setError(err: []const u8) void {
    if (set_error_fn) |f| f(err);
}

// ── Server Management ──
var servers_warming: bool = false;
var server_start_mutex: @import("../core/sync.zig").Mutex = .{};

/// Kill any leftover voice/tts server processes from a previous run.
/// Call once at startup to prevent duplicate server accumulation.
pub fn killStaleServers() void {
    // Remove stale sockets so ensureXxx doesn't think they're alive
    @import("../core/io_global.zig").deleteFileAbsolute(VOICE_SOCKET) catch {};
    @import("../core/io_global.zig").deleteFileAbsolute(TTS_SOCKET) catch {};
    // Kill any running python server processes by script name
    var kv = @import("../core/io_global.zig").Child.init(
        &.{ "pkill", "-f", "zigzag-voice-server.py" },
        @import("../core/alloc.zig").allocator,
    );
    kv.stdout_behavior = .Ignore;
    kv.stderr_behavior = .Ignore;
    _ = kv.spawnAndWait() catch {};
    var kt = @import("../core/io_global.zig").Child.init(
        &.{ "pkill", "-f", "zigzag-tts-server.py" },
        @import("../core/alloc.zig").allocator,
    );
    kt.stdout_behavior = .Ignore;
    kt.stderr_behavior = .Ignore;
    _ = kt.spawnAndWait() catch {};
    // Reset flags
    voice_server_started = false;
    tts_server_started = false;
    logs.pushLog("info", "voice", "Stale servers killed", true);
}

/// Call early (e.g. when AI tab first renders) to pre-load STT/TTS models in background
pub fn preWarmServers() void {
    if (servers_warming or (voice_server_started and tts_server_started)) return;
    servers_warming = true;
    _ = std.Thread.spawn(.{}, struct {
        fn run() void {
            ensureVoiceServer();
            ensureTtsServer();
        }
    }.run, .{}) catch {};
}

fn ensureVoiceServer() void {
    server_start_mutex.lock();
    defer server_start_mutex.unlock();
    // Re-check under lock — another thread may have started it while we waited
    if (voice_server_started) {
        logs.pushLog("info", "voice", "Voice server already started", false);
        return;
    }
    if (@import("../core/io_global.zig").cwdAccess(VOICE_SOCKET, .{})) |_| {
        voice_server_started = true;
        logs.pushLog("info", "voice", "Voice socket exists, reusing", true);
        return;
    } else |_| {}

    logs.pushLog("info", "voice", "Spawning voice server process...", true);
    var child = @import("../core/io_global.zig").Child.init(
        &.{ "python3", "bin/zigzag-voice-server.py" },
        @import("../core/alloc.zig").allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        logs.pushLog("warn", "voice", "Failed to spawn voice server process", true);
        return;
    };
    logs.pushLog("info", "voice", "Voice server spawned, waiting for socket...", true);
    // Wait for socket to appear (max 90s for first-run model download)
    var attempts: usize = 0;
    while (attempts < 900) : (attempts += 1) {
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        if (@import("../core/io_global.zig").cwdAccess(VOICE_SOCKET, .{})) |_| {
            logs.pushLog("info", "voice", "Voice socket appeared!", true);
            break;
        } else |_| {}
    }
    if (attempts >= 900) {
        logs.pushLog("warn", "voice", "Voice server socket timeout (90s)", true);
    }
    voice_server_started = true;
    logs.pushLog("info", "voice", "Voice server v2 started", true);
}

pub fn ensureSttServer() void {
    if (stt_server_started) return;
    if (@import("../core/io_global.zig").cwdAccess(STT_SOCKET, .{})) |_| {
        stt_server_started = true;
        return;
    } else |_| {}

    var child = @import("../core/io_global.zig").Child.init(
        &.{ "python3", "bin/zigzag-stt-server.py" },
        @import("../core/alloc.zig").allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        logs.pushLog("warn", "voice", "Failed to start STT server", true);
        return;
    };
    // Wait for socket to appear (max 15s for model load)
    var attempts: usize = 0;
    while (attempts < 150) : (attempts += 1) {
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        if (@import("../core/io_global.zig").cwdAccess(STT_SOCKET, .{})) |_| break else |_| {}
    }
    stt_server_started = true;
    logs.pushLog("info", "voice", "STT server started", false);
}

pub fn ensureTtsServer() void {
    if (tts_server_started) return;
    if (@import("../core/io_global.zig").cwdAccess(TTS_SOCKET, .{})) |_| {
        tts_server_started = true;
        return;
    } else |_| {}

    var child = @import("../core/io_global.zig").Child.init(
        &.{ "python3", "bin/zigzag-tts-server.py" },
        @import("../core/alloc.zig").allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        logs.pushLog("warn", "voice", "Failed to start TTS server", true);
        return;
    };
    var attempts: usize = 0;
    while (attempts < 150) : (attempts += 1) {
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        if (@import("../core/io_global.zig").cwdAccess(TTS_SOCKET, .{})) |_| break else |_| {}
    }
    tts_server_started = true;
    logs.pushLog("info", "voice", "TTS server started", false);
}

// ── Mic Recording with VAD ──

pub fn toggleMicRecording() void {
    if (is_recording) {
        is_recording = false;
    } else {
        if (is_transcribing) return;
        is_recording = true;
        mic_thread = std.Thread.spawn(.{}, micRecordWorker, .{}) catch {
            is_recording = false;
            setError("Failed to start mic recording");
            return;
        };
        mic_thread.?.detach();
    }
}

// ── Live Conversation Mode ──
// Continuous loop: listen → transcribe → LLM → TTS → listen again

pub fn toggleConversation() void {
    if (conversation_active) {
        // Stop conversation
        conversation_active = false;
        is_recording = false;
        voice_mode = false;
        conv_phase = .idle;
        // Tell voice server to pause
        if (voice_socket) |s| {
            @import("../core/io_global.zig").streamWriteAll(s, "PAUSE\n") catch {};
        }
        logs.pushLog("info", "voice", "Conversation mode stopped", true);
    } else {
        // Start conversation
        conversation_active = true;
        voice_mode = true;
        conv_phase = .listening;

        // Servers are launched inside the conv thread to avoid freezing the UI
        conv_thread = std.Thread.spawn(.{}, conversationLoopV2, .{}) catch {
            conversation_active = false;
            conv_phase = .idle;
            setError("Failed to start conversation mode");
            return;
        };
        conv_thread.?.detach();
        logs.pushLog("info", "voice", "Conversation mode v2 started", true);
    }
}

pub var auto_conversation: bool = true;

pub fn autoStartConversation() void {
    if (auto_conversation and !conversation_active) {
        toggleConversation();
    }
}

/// Notify voice server about media playing state (for VAD threshold adjustment)
var last_media_state: bool = false;
pub fn notifyMediaState(media_playing: bool) void {
    if (media_playing == last_media_state) return;
    last_media_state = media_playing;
    if (voice_socket) |s| {
        if (media_playing) {
            @import("../core/io_global.zig").streamWriteAll(s, "DUCK\n") catch {};
        } else {
            @import("../core/io_global.zig").streamWriteAll(s, "UNDUCK\n") catch {};
        }
    }
}

/// V3 conversation loop: event-driven with barge-in support.
/// Voice server keeps VAD running during TTS for interrupt detection.
fn conversationLoopV2() void {
    const c_pkg = @import("../core/c.zig");
    const state = @import("../core/state.zig");

    // Saved volume level for duck/unduck (default 100 in case query fails)
    var saved_volume: f64 = 100.0;

    // Launch servers in this background thread (not UI thread)
    logs.pushLog("info", "voice", "Conv thread: starting voice server...", true);
    ensureVoiceServer();
    logs.pushLog("info", "voice", "Conv thread: starting TTS server...", true);
    ensureTtsServer();
    logs.pushLog("info", "voice", "Conv thread: servers ready, connecting socket...", true);

    // Connect to voice server
    const v_addr = std.Io.net.UnixAddress.init(VOICE_SOCKET) catch {
        logs.pushLog("warn", "voice", "UnixAddress.init failed", true);
        conversationLoopV1();
        return;
    };
    const stream = v_addr.connect(@import("../core/io_global.zig").io()) catch |err| {
        var err_buf: [128]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "Socket connect failed: {s}", .{@errorName(err)}) catch "Socket connect failed";
        logs.pushLog("warn", "voice", err_msg, true);
        conversationLoopV1();
        return;
    };
    voice_socket = stream;
    defer {
        stream.close(@import("../core/io_global.zig").io());
        voice_socket = null;
        conv_phase = .idle;
        conversation_active = false;
        is_recording = false;
    }

    // Tell voice server to start listening
    @import("../core/io_global.zig").streamWriteAll(stream, "RESUME\n") catch {};
    conv_phase = .listening;
    is_recording = true;
    logs.pushLog("info", "voice", "Connected to voice server v3 — listening", true);

    var line_buf: [4096]u8 = undefined;
    var line_pos: usize = 0;

    while (conversation_active) {
        var byte: [1]u8 = undefined;
        const n = @import("../core/io_global.zig").streamReadAll(stream, &byte) catch break;
        if (n == 0) break;

        if (byte[0] == '\n') {
            const line = line_buf[0..line_pos];
            line_pos = 0;

            if (std.mem.startsWith(u8, line, "BARGEIN")) {
                // User interrupted TTS — kill playback immediately
                logs.pushLog("info", "voice", "Barge-in! Killing TTS", true);
                is_speaking = false;
                // Kill aplay
                var kill_aplay = @import("../core/io_global.zig").Child.init(
                    &.{ "pkill", "-f", "aplay.*zigzag" },
                    @import("../core/alloc.zig").allocator,
                );
                kill_aplay.stdout_behavior = .Ignore;
                kill_aplay.stderr_behavior = .Ignore;
                _ = kill_aplay.spawnAndWait() catch {};
                @import("../core/io_global.zig").streamWriteAll(stream, "DONE_SPEAKING\n") catch {};
                // Don't set conv_phase here — the waiter thread + voice server
                // cooldown will handle the transition back to listening.

            } else if (std.mem.startsWith(u8, line, "VAD:start")) {
                conv_phase = .listening;
                is_recording = true;
                partial_text_len = 0; // Clear partial on new speech
                // Duck media volume (save current level first)
                const has_player = state.app.players.items.len > 0;
                if (has_player) {
                    const p_idx = @min(state.app.active_player_idx, state.app.players.items.len - 1);
                    // Query and save current volume before ducking
                    _ = c_pkg.mpv.mpv_get_property(state.app.players.items[p_idx].mpv_ctx, "volume", c_pkg.mpv.MPV_FORMAT_DOUBLE, &saved_volume);
                    _ = c_pkg.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, "set volume 15");
                }

            } else if (std.mem.startsWith(u8, line, "VAD:end")) {
                conv_phase = .transcribing;
                is_recording = false;
                // Restore media volume to saved level
                const has_player = state.app.players.items.len > 0;
                if (has_player) {
                    const p_idx = @min(state.app.active_player_idx, state.app.players.items.len - 1);
                    var vol_cmd_buf: [64]u8 = undefined;
                    const vol_cmd = std.fmt.bufPrintZ(&vol_cmd_buf, "set volume {d:.0}", .{saved_volume}) catch "set volume 100";
                    _ = c_pkg.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, vol_cmd.ptr);
                }

            } else if (std.mem.startsWith(u8, line, "PARTIAL:")) {
                const ptext = line["PARTIAL:".len..];
                const plen = @min(ptext.len, partial_text.len);
                state_mutex.lock();
                @memcpy(partial_text[0..plen], ptext[0..plen]);
                partial_text_len = plen;
                state_mutex.unlock();

            } else if (std.mem.startsWith(u8, line, "TRANSCRIPT:")) {
                const text = line["TRANSCRIPT:".len..];
                partial_text_len = 0; // Clear partial on final transcript
                if (text.len > 0) {
                    logs.pushLog("info", "voice", "V3 transcript", false);
                    // Tell server we're about to speak (enables barge-in detection)
                    @import("../core/io_global.zig").streamWriteAll(stream, "SPEAKING\n") catch {};
                    is_recording = false;

                    // Send to chat
                    if (on_transcribed_fn) |f| f(text);

                    // Wait for LLM and TTS to finish in a separate thread so we don't block the socket!
                    const S = struct {
                        fn waiter(s: std.Io.net.Stream) void {
                            conv_phase = .thinking;
                            var wait: usize = 0;
                            while (@import("ai_chat.zig").is_generating and conversation_active and wait < 300) : (wait += 1) {
                                @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
                            }
                            if (conversation_active) {
                                conv_phase = .speaking;
                            }
                            while (is_speaking and conversation_active) {
                                @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
                            }
                            
                            @import("../core/io_global.zig").streamWriteAll(s, "DONE_SPEAKING\n") catch {};
                            @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
                            
                            if (conversation_active) {
                                conv_phase = .listening;
                                is_recording = true;
                            }
                        }
                    };
                    _ = std.Thread.spawn(.{}, S.waiter, .{stream}) catch {};
                }
            }
        } else {
            if (line_pos < line_buf.len) {
                line_buf[line_pos] = byte[0];
                line_pos += 1;
            }
        }
    }
}

/// Request speaker enrollment from the voice server
pub fn enrollSpeaker() void {
    if (voice_socket) |s| {
        @import("../core/io_global.zig").streamWriteAll(s, "ENROLL\n") catch {};
        logs.pushLog("info", "voice", "Speaker enrollment requested", true);
    }
}

/// V1 fallback conversation loop (sox rec + STT server)
fn conversationLoopV1() void {
    const chat = @import("ai_chat.zig");
    const c_pkg = @import("../core/c.zig");
    const state = @import("../core/state.zig");

    // Ensure old STT server is running for fallback
    ensureSttServer();

    while (conversation_active) {
        conv_phase = .speaking;
        while ((is_speaking or chat.is_generating) and conversation_active) {
            @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
        }
        if (!conversation_active) break;
        @import("../core/io_global.zig").sleep(80 * std.time.ns_per_ms);
        if (!conversation_active) break;

        const has_player = state.app.players.items.len > 0;
        const p_idx = if (has_player) @min(state.app.active_player_idx, state.app.players.items.len - 1) else 0;
        var saved_vol: f64 = 100.0;
        if (has_player) {
            _ = c_pkg.mpv.mpv_get_property(state.app.players.items[p_idx].mpv_ctx, "volume", c_pkg.mpv.MPV_FORMAT_DOUBLE, &saved_vol);
            _ = c_pkg.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, "set volume 15");
        }

        conv_phase = .listening;
        is_recording = true;
        var record_child = @import("../core/io_global.zig").Child.init(
            &.{ "rec", "-q", MIC_WAV_PATH, "rate", "16000", "channels", "1",
                "silence", "1", "0.1", "3%", "1", "0.5", "3%", "trim", "0", "12" },
            @import("../core/alloc.zig").allocator,
        );
        record_child.stdout_behavior = .Ignore;
        record_child.stderr_behavior = .Ignore;
        record_child.spawn() catch {
            is_recording = false;
            if (has_player) {
                var rv_buf: [64]u8 = undefined;
                const rv_cmd = std.fmt.bufPrintZ(&rv_buf, "set volume {d:.0}", .{saved_vol}) catch "set volume 100";
                _ = c_pkg.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, rv_cmd.ptr);
            }
            @import("../core/io_global.zig").sleep(500 * std.time.ns_per_ms);
            continue;
        };
        _ = record_child.wait() catch {
            is_recording = false;
            if (has_player) {
                var rv_buf: [64]u8 = undefined;
                const rv_cmd = std.fmt.bufPrintZ(&rv_buf, "set volume {d:.0}", .{saved_vol}) catch "set volume 100";
                _ = c_pkg.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, rv_cmd.ptr);
            }
            continue;
        };
        is_recording = false;
        if (has_player) {
            var rv_buf: [64]u8 = undefined;
            const rv_cmd = std.fmt.bufPrintZ(&rv_buf, "set volume {d:.0}", .{saved_vol}) catch "set volume 100";
            _ = c_pkg.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, rv_cmd.ptr);
        }
        if (!conversation_active) break;

        conv_phase = .transcribing;
        is_transcribing = true;
        transcribeAndSend();
        is_transcribing = false;
        if (!conversation_active) break;

        conv_phase = .thinking;
        var wait_count: usize = 0;
        while (chat.is_generating and conversation_active and wait_count < 300) : (wait_count += 1) {
            @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
        }
    }

    conv_phase = .idle;
    conversation_active = false;
    is_recording = false;
}

fn micRecordWorker() void {
    defer { is_recording = false; }

    // Use sox `rec` with silence detection (VAD):
    //   silence 1 0.2 2%  → wait for sound above 2% to start recording
    //   1 1.0 2%          → stop after 1.0s of silence below 2%
    //   trim 0 15         → max 15 seconds
    var record_child = @import("../core/io_global.zig").Child.init(
        &.{ "rec", "-q",
            MIC_WAV_PATH,
            "rate", "16000",       // 16kHz for whisper
            "channels", "1",       // mono
            "silence", "1", "0.2", "2%",  // start on voice
            "1", "1.0", "2%",             // stop after 1.0s silence
            "trim", "0", "15" },          // max 15s
        @import("../core/alloc.zig").allocator,
    );
    record_child.stdout_behavior = .Ignore;
    record_child.stderr_behavior = .Ignore;

    record_child.spawn() catch {
        // Fallback to ffmpeg if sox not available
        micRecordFfmpegFallback();
        return;
    };

    // sox will auto-exit when it detects silence after speech.
    // We just wait for it. User can also click mic again to force stop.
    const result = record_child.wait() catch {
        setError("Recording failed");
        return;
    };
    _ = result;
    is_recording = false;

    // Check we got a WAV file
    if (@import("../core/io_global.zig").cwdAccess(MIC_WAV_PATH, .{})) |_| {
        is_transcribing = true;
        defer { is_transcribing = false; }
        transcribeAndSend();
    } else |_| {
        setError("No audio recorded");
    }
}

fn micRecordFfmpegFallback() void {
    // Fallback: ffmpeg with manual stop (no VAD)
    var record_child = @import("../core/io_global.zig").Child.init(
        &.{ "ffmpeg", "-y", "-f", "pulse", "-i", "default",
            "-ar", "16000", "-ac", "1", "-t", "15",
            MIC_WAV_PATH },
        @import("../core/alloc.zig").allocator,
    );
    record_child.stdout_behavior = .Ignore;
    record_child.stderr_behavior = .Ignore;
    record_child.spawn() catch {
        setError("Failed to start mic (install sox or ffmpeg)");
        return;
    };

    while (is_recording) {
        @import("../core/io_global.zig").sleep(100_000_000);
    }

    _ = record_child.kill() catch {};
    _ = record_child.wait() catch {};

    if (@import("../core/io_global.zig").cwdAccess(MIC_WAV_PATH, .{})) |_| {
        is_transcribing = true;
        defer { is_transcribing = false; }
        transcribeAndSend();
    } else |_| {
        setError("No audio recorded");
    }
}

// ── Whisper Hallucination Filter ──
// Whisper often hallucinates these when given noise/silence
fn isHallucination(text: []const u8) bool {
    if (text.len < 4) return true;

    // Filter text entirely wrapped in parens or brackets: (machine whirring), [BLANK_AUDIO]
    if ((text[0] == '(' and text[text.len - 1] == ')') or
        (text[0] == '[' and text[text.len - 1] == ']'))
        return true;

    // Common Whisper hallucination phrases (lowercase check)
    var lower: [256]u8 = undefined;
    const tlen = @min(text.len, 255);
    for (0..tlen) |i| lower[i] = std.ascii.toLower(text[i]);
    const lc = lower[0..tlen];

    // Exact short hallucinations
    const trimmed = std.mem.trim(u8, lc, " .!?,");
    if (trimmed.len < 3) return true;
    if (std.mem.eql(u8, trimmed, "you")) return true;
    if (std.mem.eql(u8, trimmed, "hmm")) return true;
    if (std.mem.eql(u8, trimmed, "yeah")) return true;
    if (std.mem.eql(u8, trimmed, "okay")) return true;
    if (std.mem.eql(u8, trimmed, "oh")) return true;

    const hallucinations = [_][]const u8{
        "machine whirring", "silence", "blank audio", "music",
        "applause",         "laughter",  "coughing",    "breathing",
        "thank you for watching",  "thanks for watching",
        "thank you for listening", "subscribe",
        "please subscribe", "like and subscribe",
        "see you next time", "bye bye",  "goodbye",
        "feature of zigzag", "zigzag",   "nando",
        "...",               "um,",      "uh,",
    };

    for (hallucinations) |h| {
        if (std.mem.indexOf(u8, lc, h) != null) return true;
    }

    // Reject if mostly punctuation/commas (garbage like "UI, zigzag, feature")
    var punct_count: usize = 0;
    for (text) |ch| {
        if (ch == ',' or ch == '.' or ch == ' ') punct_count += 1;
    }
    if (punct_count * 2 > text.len) return true;

    return false;
}

// ── ASR via persistent server (Unix socket) ──

fn transcribeViaServer() ?[]const u8 {
    const stt_addr = std.Io.net.UnixAddress.init(STT_SOCKET) catch return null;
    const stream = stt_addr.connect(@import("../core/io_global.zig").io()) catch return null;
    defer stream.close(@import("../core/io_global.zig").io());

    // Send WAV path
    @import("../core/io_global.zig").streamWriteAll(stream, MIC_WAV_PATH) catch return null;

    // Read response
    var buf: [4096]u8 = undefined;
    const n = @import("../core/io_global.zig").streamReadAll(stream, &buf) catch return null;
    if (n == 0) return null;

    const result = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (result.len == 0) return null;
    if (std.mem.startsWith(u8, result, "ERROR:")) return null;

    return result;
}

fn transcribeAndSend() void {
    // Try persistent server first (fast — model already loaded)
    if (stt_server_started) {
        if (transcribeViaServer()) |transcribed| {
            if (transcribed.len > 0 and !isHallucination(transcribed)) {
                logs.pushLog("info", "voice", "STT server transcribed", false);
                if (on_transcribed_fn) |f| f(transcribed);
                return;
            }
        }
    }

    // Fallback: spawn one-shot Faster-Whisper process
    const out_txt_path = "/tmp/zigzag_ai_mic.wav.txt";
    _ = @import("../core/io_global.zig").deleteFileAbsolute(out_txt_path) catch {};

    var fw_child = @import("../core/io_global.zig").Child.init(
        &.{ "python3", "bin/zigzag-stt.py", MIC_WAV_PATH },
        @import("../core/alloc.zig").allocator,
    );
    fw_child.stdout_behavior = .Pipe;
    fw_child.stderr_behavior = .Ignore;

    if (fw_child.spawn()) |_| {
        const fw_stdout = fw_child.stdout.?;
        var fw_buf: [4096]u8 = undefined;
        const fw_len = @import("../core/io_global.zig").read(fw_stdout, &fw_buf) catch 0;
        _ = fw_child.wait() catch {};

        if (fw_len > 0) {
            const transcribed = std.mem.trim(u8, fw_buf[0..fw_len], " \t\r\n");
            if (transcribed.len > 0 and !isHallucination(transcribed)) {
                logs.pushLog("info", "voice", "Faster-Whisper transcribed", false);
                if (on_transcribed_fn) |f| f(transcribed);
                return;
            }
        }
    } else |_| {}

    // Strategy 2: Fallback to whisper.cpp (if Faster-Whisper not available)
    const model = blk: {
        if (@import("../core/io_global.zig").cwdAccess("bin/whisper.cpp/models/ggml-small.en.bin", .{})) |_| {
            break :blk "bin/whisper.cpp/models/ggml-small.en.bin";
        } else |_| {}
        if (@import("../core/io_global.zig").cwdAccess("bin/whisper.cpp/models/ggml-base.en.bin", .{})) |_| {
            break :blk "bin/whisper.cpp/models/ggml-base.en.bin";
        } else |_| {}
        break :blk "bin/whisper.cpp/models/ggml-tiny.en.bin";
    };

    var w_child = @import("../core/io_global.zig").Child.init(
        &.{ "bin/whisper.cpp/build/bin/whisper-cli",
            "-m", model,
            "-f", MIC_WAV_PATH,
            "-t", "4",
            "--no-timestamps",
            "--no-prints",
            "-otxt" },
        @import("../core/alloc.zig").allocator,
    );
    w_child.stdout_behavior = .Ignore;
    w_child.stderr_behavior = .Ignore;
    _ = w_child.spawnAndWait() catch {
        setError("No ASR engine available (install faster-whisper or whisper.cpp)");
        return;
    };

    const resp_file = @import("../core/io_global.zig").openFileAbsolute(out_txt_path, .{}) catch {
        setError("ASR output missing");
        return;
    };
    defer resp_file.close(@import("../core/io_global.zig").io());

    var resp_buf: [4096]u8 = undefined;
    const resp_len = @import("../core/io_global.zig").readAll(resp_file, &resp_buf) catch return;
    if (resp_len == 0) {
        setError("Empty ASR response");
        return;
    }

    var transcribed = std.mem.trim(u8, resp_buf[0..resp_len], " \t\r\n");

    if (transcribed.len == 0) {
        setError("No speech detected");
        return;
    }

    // Strip "[BLANK_AUDIO]" tags
    if (transcribed.len > 0 and transcribed[0] == '[') {
        if (std.mem.indexOfScalar(u8, transcribed, ']')) |tag_end| {
            transcribed = std.mem.trim(u8, transcribed[tag_end + 1 ..], " \t\r\n");
        }
    }
    if (transcribed.len == 0 or isHallucination(transcribed)) return;

    // Send transcribed text back to chat
    if (on_transcribed_fn) |f| f(transcribed);
}

// ── TTS via persistent server (Unix socket) ──

fn speakViaServer(text: []const u8) bool {
    const tts_addr = std.Io.net.UnixAddress.init(TTS_SOCKET) catch return false;
    const stream = tts_addr.connect(@import("../core/io_global.zig").io()) catch return false;
    defer stream.close(@import("../core/io_global.zig").io());

    // Send text
    @import("../core/io_global.zig").streamWriteAll(stream, text) catch return false;

    // Wait for "OK" response
    var buf: [256]u8 = undefined;
    const n = @import("../core/io_global.zig").streamReadAll(stream, &buf) catch return false;
    if (n >= 2 and buf[0] == 'O' and buf[1] == 'K') return true;
    return false;
}

// ── TTS ──

var tts_text_buf: [2048]u8 = undefined;
var tts_text_len: usize = 0;

pub fn speakResponse(text: []const u8) void {
    if (text.len == 0) return;
    if (is_speaking) return;

    const slen = @min(text.len, tts_text_buf.len);
    @memcpy(tts_text_buf[0..slen], text[0..slen]);
    tts_text_len = slen;

    is_speaking = true;
    tts_thread = std.Thread.spawn(.{}, ttsWorker, .{}) catch {
        is_speaking = false;
        return;
    };
    tts_thread.?.detach();
}

fn ttsWorker() void {
    defer { is_speaking = false; }

    const state = @import("../core/state.zig");
    const text = tts_text_buf[0..tts_text_len];

    // Strategy 1: Persistent TTS server (instant — model already loaded)
    if (tts_server_started and speakViaServer(text)) {
        // WAV generated, play it
        var play = @import("../core/io_global.zig").Child.init(
            &.{ "aplay", "-q", TTS_WAV_PATH },
            @import("../core/alloc.zig").allocator,
        );
        _ = play.spawnAndWait() catch {};
        return;
    }

    // Strategy 2: One-shot KittenTTS (cold start fallback)
    if (@import("../core/io_global.zig").cwdCreateFile("/tmp/zigzag_tts_input.txt", .{})) |f| {
        @import("../core/io_global.zig").writeAll(f, text) catch {};
        f.close(@import("../core/io_global.zig").io());
    } else |_| {}

    // Build TTS command with configurable voice
    const voice_name = if (state.app.tts_voice_len > 0 and state.app.tts_voice_len <= 16)
        state.app.tts_voice_buf[0..state.app.tts_voice_len]
    else
        "Bella";
    
    var tts_cmd_buf: [512]u8 = undefined;
    const tts_cmd = std.fmt.bufPrintZ(&tts_cmd_buf,
        "from kittentts import KittenTTS; " ++
        "text = open('/tmp/zigzag_tts_input.txt').read().strip(); " ++
        "tts = KittenTTS(); tts.generate_to_file(text, '/tmp/zigzag_ai_tts.wav', voice='{s}', speed={d:.1})",
        .{ voice_name, state.app.tts_speed },
    ) catch return;

    var kitten = @import("../core/io_global.zig").Child.init(
        &.{ "python3", "-c", tts_cmd },
        @import("../core/alloc.zig").allocator,
    );
    kitten.stdout_behavior = .Ignore;
    kitten.stderr_behavior = .Ignore;

    var kitten_ok = false;
    if (kitten.spawn()) |_| {
        const result = kitten.wait() catch null;
        if (result) |r| {
            kitten_ok = (r.exited == 0);
        }
    } else |_| {}

    if (!kitten_ok) {
        // Strategy 3: Fallback to old HTTP TTS server
        var encoded: [4096]u8 = undefined;
        const enc_len = urlEncode(text, &encoded);
        if (enc_len == 0) return;

        var url_buf: [8192]u8 = undefined;
        const url = std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/speak?text={s}&voice=Luna&speed=1.0", .{
            LANG_SERVER_PORT, encoded[0..enc_len],
        }) catch return;

        var curl_child = @import("../core/io_global.zig").Child.init(
            &.{ "curl", "-s", "-o", TTS_WAV_PATH, "--max-time", "30", url },
            @import("../core/alloc.zig").allocator,
        );
        _ = curl_child.spawnAndWait() catch return;
    }

    // Play the generated audio
    var play = @import("../core/io_global.zig").Child.init(
        &.{ "aplay", "-q", TTS_WAV_PATH },
        @import("../core/alloc.zig").allocator,
    );
    _ = play.spawnAndWait() catch {};
}

// ── Helpers ──

fn urlEncode(input: []const u8, out: []u8) usize {
    const hex = "0123456789ABCDEF";
    var j: usize = 0;
    for (input) |ch| {
        if (j + 3 >= out.len) break;
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~')
        {
            out[j] = ch;
            j += 1;
        } else {
            out[j] = '%';
            out[j + 1] = hex[ch >> 4];
            out[j + 2] = hex[ch & 0x0F];
            j += 3;
        }
    }
    return j;
}
