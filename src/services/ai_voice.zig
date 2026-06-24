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
// Thread safety: conv_phase mutations must go through setPhase() which
// holds state_mutex. Single-byte bools are naturally atomic on x86/ARM.
pub var voice_mode: bool = false;
pub var is_recording: bool = false;
pub var is_transcribing: bool = false;
pub var is_speaking: bool = false;
pub var conversation_active: bool = false;
/// Set true the instant a barge-in is detected (user spoke over the assistant).
/// Silences every queued/in-flight TTS sentence until the next user turn resets
/// it. Atomic because the voice worker thread sets it and the LLM-generation
/// thread (sentence-streaming TTS in ai_context) reads it. Reset to false when a
/// new transcript is dispatched, so the assistant's reply to the interruption
/// can speak normally.
pub var barge_in: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var conv_phase: ConvPhase = .idle;
pub var partial_text: [512]u8 = std.mem.zeroes([512]u8);
pub var partial_text_len: usize = 0;
pub var state_mutex: @import("../core/sync.zig").Mutex = .{};

/// Thread-safe phase transition. All conv_phase writes must go through here.
pub fn setPhase(p: ConvPhase) void {
    state_mutex.lock();
    conv_phase = p;
    state_mutex.unlock();
}
var mic_thread: ?std.Thread = null;
var tts_thread: ?std.Thread = null;
var conv_thread: ?std.Thread = null;
/// Serializes TTS playback among TTS workers only. MUST NOT be the LLM
/// `inference_mutex`: generateResponse() holds that across the whole stream and
/// speaks each sentence mid-stream, so making ttsWorker take inference_mutex
/// deadlocks (generation holds it + waits for is_speaking; the TTS thread can't
/// start because it's blocked on the same mutex). TTS uses separate processes
/// (say/afplay/kokoro/sherpa), so it never actually contends with the LLM.
var tts_mutex: @import("../core/sync.zig").Mutex = .{};

// ── Persistent server PIDs ──
var stt_server_started: bool = false;
var tts_server_started: bool = false;
var voice_server_started: bool = false;
/// Owned by the conversation worker (conversationLoopV2). Written by the worker
/// (set on connect, null+close in its defer) and read/written by the UI thread
/// (toggleConversation stop, notifyMediaState, enrollSpeaker). ALL access must
/// go through the socket_mutex-guarded helpers below — never touch this var
/// directly — to avoid a use-after-close race when the worker closes the stream
/// while the UI thread is mid-write.
var voice_socket: ?std.Io.net.Stream = null;
var socket_mutex: @import("../core/sync.zig").Mutex = .{};

/// Publish the connected stream so the UI thread can write to it.
fn setVoiceSocket(s: std.Io.net.Stream) void {
    socket_mutex.lock();
    voice_socket = s;
    socket_mutex.unlock();
}

/// Null-then-close the stream: snapshot + null under the lock so no UI-thread
/// write can race the close, then close() outside the lock once the var is
/// already null and unreachable by other threads.
fn clearVoiceSocket() void {
    socket_mutex.lock();
    const s = voice_socket;
    voice_socket = null;
    socket_mutex.unlock();
    if (s) |stream| stream.close(@import("../core/io_global.zig").io());
}

/// Snapshot the socket under the lock and write to it while still holding the
/// lock, so a concurrent clearVoiceSocket()/close() cannot fire mid-write.
fn voiceSocketWrite(msg: []const u8) void {
    socket_mutex.lock();
    defer socket_mutex.unlock();
    if (voice_socket) |s| {
        @import("../core/io_global.zig").streamWriteAll(s, msg) catch {};
    }
}

/// Public, thread-safe "PAUSE" to the v2 voice server. ai_chat.zig calls this
/// on stop instead of touching voice_socket directly (which is now private).
pub fn pauseVoiceServer() void {
    voiceSocketWrite("PAUSE\n");
}

/// Silence the assistant instantly — kill EVERY audio-playback helper we spawn
/// for TTS, regardless of backend. macOS plays via `say` (sayTtsSpeak) and
/// `afplay` (sherpa/kokoro/speaches WAV playback); Linux via `aplay`/`paplay`.
/// We match by exact process name (`pkill -x`) so we never hit unrelated
/// processes — these are short-lived helpers we own. Used for barge-in and for
/// stopping conversation mode. The old code only killed `say`, so interrupting
/// a Kokoro/Piper reply (which uses afplay) did nothing on macOS.
pub fn stopAllAudio() void {
    is_speaking = false;
    const io = @import("../core/io_global.zig");
    const alloc = @import("../core/alloc.zig").allocator;
    const names: []const []const u8 = if (@import("builtin").os.tag == .macos)
        &.{ "say", "afplay" }
    else
        &.{ "aplay", "paplay", "ffplay" };
    for (names) |n| {
        var k = io.Child.init(&.{ "pkill", "-x", n }, alloc);
        k.stdout_behavior = .Ignore;
        k.stderr_behavior = .Ignore;
        _ = k.spawnAndWait() catch {};
    }
}

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
    @import("../core/io_global.zig").deleteFileAbsolute(STT_SOCKET) catch {};
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
    // STT server is spawned later by ensureSttServer — kill any leftover too,
    // otherwise it accumulates as a zombie zigzag-stt-server.py across runs.
    var ks = @import("../core/io_global.zig").Child.init(
        &.{ "pkill", "-f", "zigzag-stt-server.py" },
        @import("../core/alloc.zig").allocator,
    );
    ks.stdout_behavior = .Ignore;
    ks.stderr_behavior = .Ignore;
    _ = ks.spawnAndWait() catch {};
    // Reset flags
    voice_server_started = false;
    tts_server_started = false;
    stt_server_started = false;
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

/// Fast preflight: run `python3 <script> --check`, which verifies the server's
/// Python imports without loading any model and exits 0/non-zero. Lets the
/// ensure* helpers skip the multi-second spawn-and-wait (and avoid leaving an
/// idle python process) when the optional voice deps aren't installed.
fn serverDepsReady(script: []const u8) bool {
    var check = @import("../core/io_global.zig").Child.init(
        &.{ "python3", script, "--check" },
        @import("../core/alloc.zig").allocator,
    );
    check.stdout_behavior = .Ignore;
    check.stderr_behavior = .Ignore;
    const term = check.spawnAndWait() catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn ensureVoiceServer() void {
    server_start_mutex.lock();
    defer server_start_mutex.unlock();
    if (voice_server_started) return;
    if (@import("../core/io_global.zig").cwdAccess(VOICE_SOCKET, .{})) |_| {
        voice_server_started = true;
        return;
    } else |_| {}
    @import("../core/io_global.zig").cwdAccess("bin/zigzag-voice-server.py", .{}) catch {
        logs.pushLog("warn", "voice", "voice-server.py not found — skipping", true);
        return;
    };
    if (!serverDepsReady("bin/zigzag-voice-server.py")) {
        logs.pushLog("info", "voice", "voice-server deps missing — using fallback", true);
        return;
    }
    var child = @import("../core/io_global.zig").Child.init(
        &.{ "python3", "bin/zigzag-voice-server.py" },
        @import("../core/alloc.zig").allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        return;
    };
    var attempts: usize = 0;
    while (attempts < 300) : (attempts += 1) {
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        if (@import("../core/io_global.zig").cwdAccess(VOICE_SOCKET, .{})) |_| break else |_| {}
    }
    if (attempts >= 300) return;
    voice_server_started = true;
}

pub fn ensureSttServer() void {
    if (stt_server_started) return;
    if (@import("../core/io_global.zig").cwdAccess(STT_SOCKET, .{})) |_| {
        stt_server_started = true;
        return;
    } else |_| {}
    @import("../core/io_global.zig").cwdAccess("bin/zigzag-stt-server.py", .{}) catch {
        return;
    };
    if (!serverDepsReady("bin/zigzag-stt-server.py")) return;
    var child = @import("../core/io_global.zig").Child.init(
        &.{ "python3", "bin/zigzag-stt-server.py" },
        @import("../core/alloc.zig").allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        return;
    };
    var attempts: usize = 0;
    while (attempts < 150) : (attempts += 1) {
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        if (@import("../core/io_global.zig").cwdAccess(STT_SOCKET, .{})) |_| break else |_| {}
    }
    stt_server_started = (attempts < 150);
}

pub fn ensureTtsServer() void {
    if (tts_server_started) return;
    if (@import("../core/io_global.zig").cwdAccess(TTS_SOCKET, .{})) |_| {
        tts_server_started = true;
        return;
    } else |_| {}
    @import("../core/io_global.zig").cwdAccess("bin/zigzag-tts-server.py", .{}) catch {
        return;
    };
    if (!serverDepsReady("bin/zigzag-tts-server.py")) return;
    var child = @import("../core/io_global.zig").Child.init(
        &.{ "python3", "bin/zigzag-tts-server.py" },
        @import("../core/alloc.zig").allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        return;
    };
    var attempts: usize = 0;
    while (attempts < 150) : (attempts += 1) {
        @import("../core/io_global.zig").sleep(100 * std.time.ns_per_ms);
        if (@import("../core/io_global.zig").cwdAccess(TTS_SOCKET, .{})) |_| break else |_| {}
    }
    tts_server_started = (attempts < 150);
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
        setPhase(.idle);
        // Tell voice server to pause (guarded — worker may be closing the socket)
        voiceSocketWrite("PAUSE\n");
        // Cut any in-progress assistant speech so stopping is instant.
        barge_in.store(true, .release);
        stopAllAudio();
        logs.pushLog("info", "voice", "Conversation mode stopped", true);
    } else {
        // Pre-check: ensure at least one voice path is viable
        const vb = @import("voice_backend.zig");
        const deps = @import("../core/deps.zig");
        const ds = deps.check();
        const b = vb.active();
        const has_streaming = b.supports_streaming and ds.sherpa_stream_model;
        const has_whisper = ds.whisper or ds.whisper_model or ds.sherpa_model;
        if (!has_streaming and !has_whisper) {
            const state_mod = @import("../core/state.zig");
            state_mod.showToast("No voice backend ready — install a model in AI tab first");
            return;
        }

        // Start conversation
        conversation_active = true;
        voice_mode = true;
        setPhase(.listening);

        // Pick loop: streaming if active backend supports it + deps ready,
        // else fall back to the legacy ffmpeg-record + STT-server v2 path.
        const use_streaming = has_streaming;
        conv_thread = (if (use_streaming)
            std.Thread.spawn(.{}, conversationLoopSherpa, .{})
        else
            std.Thread.spawn(.{}, conversationLoopV2, .{})) catch {
            conversation_active = false;
            setPhase(.idle);
            setError("Failed to start conversation mode");
            return;
        };
        conv_thread.?.detach();
        logs.pushLog("info", "voice", if (use_streaming) "Conv mode: sherpa streaming" else "Conv mode: v2 (legacy)", true);
    }
}

pub var auto_conversation: bool = false;

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
    // Guarded write — worker may be closing the socket concurrently.
    voiceSocketWrite(if (media_playing) "DUCK\n" else "UNDUCK\n");
}

/// V3 conversation loop: event-driven with barge-in support.
/// Voice server keeps VAD running during TTS for interrupt detection.
/// Sherpa streaming conversation loop — phase 4b.
/// Spawns sherpa-onnx-microphone via voice_backend.spawnStreamingConvo,
/// reads its stdout line-by-line, dispatches each final transcript to
/// ai_chat just like the user typed it. No fixed record ceiling — VAD
/// driven, runs until user toggles convo off.
fn conversationLoopSherpa() void {
    defer {
        setPhase(.idle);
        conversation_active = false;
        is_recording = false;
    }

    const vb = @import("voice_backend.zig");
    // Transcripts are dispatched inline below (reading child.stdout), so
    // spawnStreamingConvo no longer takes a callback.
    var child = vb.spawnStreamingConvo() orelse {
        logs.pushLog("error", "voice", "Sherpa streaming spawn failed — falling back to v2", false);
        conversationLoopV2();
        return;
    };
    defer _ = child.kill() catch {};

    const stdout = child.stdout orelse {
        logs.pushLog("error", "voice", "Sherpa child has no stdout pipe", false);
        return;
    };

    // sherpa-onnx-microphone output format:
    //   "0:Text here"     → interim partial
    //   "OK"               → silence/pause boundary
    // We dispatch on each non-empty text line that looks like a final.
    var reader_buf: [4096]u8 = undefined;
    var reader = stdout.reader(@import("../core/io_global.zig").io(), &reader_buf);

    setPhase(.listening);
    while (conversation_active) {
        const line = reader.interface.takeDelimiter('\n') catch break orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Strip sherpa's "N:" prefix (chunk counter)
        const text = blk: {
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |idx| {
                break :blk std.mem.trim(u8, trimmed[idx + 1 ..], " \t");
            }
            break :blk trimmed;
        };
        if (text.len < 3) continue;
        if (@import("voice_filter.zig").isHallucination(text)) continue;

        // Barge-in for the streaming path: this loop has no separate interrupt
        // channel, but a fresh utterance arriving while the assistant is
        // speaking IS the interruption. Cut the current reply, abort its
        // generation, and wait for it to unwind so onTranscribed (which drops
        // turns while is_generating) accepts this new one.
        if (is_speaking or @import("ai_chat.zig").is_generating.load(.acquire)) {
            barge_in.store(true, .release);
            @import("ai_chat.zig").gen_abort.store(true, .release);
            stopAllAudio();
            var w: usize = 0;
            while (@import("ai_chat.zig").is_generating.load(.acquire) and w < 50) : (w += 1) {
                @import("../core/io_global.zig").sleep(10 * std.time.ns_per_ms);
            }
        }

        setPhase(.transcribing);
        // New user turn — clear any prior barge-in so this reply may speak.
        barge_in.store(false, .release);
        if (on_transcribed_fn) |f| f(text);
        // Wait for LLM to finish before listening again so TTS doesn't
        // compete with mic input.
        setPhase(.thinking);
        var wait: usize = 0;
        const chat = @import("ai_chat.zig");
        while (chat.is_generating.load(.acquire) and conversation_active and wait < 300) : (wait += 1) {
            @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
        }
        // Response queued; TTS fires from ai_chat.setResponseText path.
        // Return to listening for the next turn.
        setPhase(.listening);
    }
}

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
    setVoiceSocket(stream);
    defer {
        // Null-then-close under the socket lock so a UI-thread write can't
        // race the close (use-after-close). clearVoiceSocket does both.
        clearVoiceSocket();
        setPhase(.idle);
        conversation_active = false;
        is_recording = false;
    }

    // Tell voice server to start listening
    voiceSocketWrite("RESUME\n");
    setPhase(.listening);
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
                // User interrupted TTS — silence the assistant immediately and
                // flag the in-flight reply as superseded so its remaining
                // sentences don't get queued (see speakResponse barge_in guard).
                logs.pushLog("info", "voice", "Barge-in! Stopping TTS", true);
                barge_in.store(true, .release);
                @import("ai_chat.zig").gen_abort.store(true, .release);
                stopAllAudio();
                voiceSocketWrite("DONE_SPEAKING\n");
                // Don't set conv_phase here — the waiter thread + voice server
                // cooldown will handle the transition back to listening.

            } else if (std.mem.startsWith(u8, line, "VAD:start")) {
                setPhase(.listening);
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
                setPhase(.transcribing);
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
                    voiceSocketWrite("SPEAKING\n");
                    is_recording = false;

                    // New user turn — clear any prior barge-in so the reply to
                    // this utterance is allowed to speak.
                    barge_in.store(false, .release);

                    // Send to chat
                    if (on_transcribed_fn) |f| f(text);

                    // Wait for LLM and TTS to finish in a separate thread so we don't block the socket!
                    // The waiter no longer captures the raw stream — it writes via
                    // voiceSocketWrite so its DONE_SPEAKING can't race the worker's close.
                    const S = struct {
                        fn waiter() void {
                            setPhase(.thinking);
                            var wait: usize = 0;
                            while (@import("ai_chat.zig").is_generating.load(.acquire) and conversation_active and wait < 300) : (wait += 1) {
                                @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
                            }
                            if (conversation_active) {
                                setPhase(.speaking);
                            }
                            while (is_speaking and conversation_active) {
                                @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
                            }

                            voiceSocketWrite("DONE_SPEAKING\n");
                            @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);

                            if (conversation_active) {
                                setPhase(.listening);
                                is_recording = true;
                            }
                        }
                    };
                    _ = std.Thread.spawn(.{}, S.waiter, .{}) catch {};
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
    // Guarded write — worker may be closing the socket concurrently.
    voiceSocketWrite("ENROLL\n");
    logs.pushLog("info", "voice", "Speaker enrollment requested", true);
}

/// V1 fallback conversation loop (sox rec + STT server)
fn conversationLoopV1() void {
    const chat = @import("ai_chat.zig");
    const c_pkg = @import("../core/c.zig");
    const state = @import("../core/state.zig");

    // Ensure old STT server is running for fallback
    ensureSttServer();

    while (conversation_active) {
        setPhase(.speaking);
        while ((is_speaking or chat.is_generating.load(.acquire)) and conversation_active) {
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

        setPhase(.listening);
        is_recording = true;
        // Use ffmpeg for mic capture (cross-platform; sox 'rec' is rarely installed)
        const is_macos = @import("builtin").os.tag == .macos;
        const input_fmt = if (is_macos) "avfoundation" else "pulse";
        const input_dev = if (is_macos) ":0" else "default";
        var record_child = @import("../core/io_global.zig").Child.init(
            &.{ "ffmpeg", "-y", "-f", input_fmt, "-i", input_dev, "-ar", "16000", "-ac", "1", "-t", "12", MIC_WAV_PATH },
            @import("../core/alloc.zig").allocator,
        );
        record_child.stdout_behavior = .Ignore;
        record_child.stderr_behavior = .Ignore;
        record_child.spawn() catch {
            is_recording = false;
            if (has_player and p_idx < state.app.players.items.len) {
                var rv_buf: [64]u8 = undefined;
                const rv_cmd = std.fmt.bufPrintZ(&rv_buf, "set volume {d:.0}", .{saved_vol}) catch "set volume 100";
                _ = c_pkg.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, rv_cmd.ptr);
            }
            @import("../core/io_global.zig").sleep(500 * std.time.ns_per_ms);
            continue;
        };
        _ = record_child.wait() catch {
            is_recording = false;
            if (has_player and p_idx < state.app.players.items.len) {
                var rv_buf: [64]u8 = undefined;
                const rv_cmd = std.fmt.bufPrintZ(&rv_buf, "set volume {d:.0}", .{saved_vol}) catch "set volume 100";
                _ = c_pkg.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, rv_cmd.ptr);
            }
            continue;
        };
        is_recording = false;
        // Re-check player still exists after recording
        if (has_player and p_idx < state.app.players.items.len) {
            var rv_buf: [64]u8 = undefined;
            const rv_cmd = std.fmt.bufPrintZ(&rv_buf, "set volume {d:.0}", .{saved_vol}) catch "set volume 100";
            _ = c_pkg.mpv.mpv_command_string(state.app.players.items[p_idx].mpv_ctx, rv_cmd.ptr);
        }
        if (!conversation_active) break;

        setPhase(.transcribing);
        is_transcribing = true;
        transcribeAndSend();
        is_transcribing = false;
        if (!conversation_active) break;

        setPhase(.thinking);
        var wait_count: usize = 0;
        while (chat.is_generating.load(.acquire) and conversation_active and wait_count < 300) : (wait_count += 1) {
            @import("../core/io_global.zig").sleep(50 * std.time.ns_per_ms);
        }
    }

    setPhase(.idle);
    conversation_active = false;
    is_recording = false;
}

fn micRecordWorker() void {
    defer {
        is_recording = false;
    }

    // ffmpeg-primary mic capture. Platform-specific input:
    //   macOS   → avfoundation (":0" = default audio)
    //   linux   → pulse (pulseaudio default)
    // Fixed 15s ceiling; user clicks mic again to stop early.
    const is_macos = @import("builtin").os.tag == .macos;
    const input_fmt = if (is_macos) "avfoundation" else "pulse";
    const input_dev = if (is_macos) ":0" else "default";

    logs.pushLog("info", "voice", "Mic: starting ffmpeg capture", true);
    var record_child = @import("../core/io_global.zig").Child.init(
        &.{ "ffmpeg", "-y", "-f", input_fmt, "-i", input_dev, "-ar", "16000", "-ac", "1", "-t", "15", MIC_WAV_PATH },
        @import("../core/alloc.zig").allocator,
    );
    // stderr piped so ffmpeg errors surface in logs (permission denials,
    // device-not-found, etc). Previously .Ignore hid all diagnostics.
    record_child.stdout_behavior = .Ignore;
    record_child.stderr_behavior = .Inherit;
    record_child.spawn() catch |err| {
        var eb: [128]u8 = undefined;
        const em = std.fmt.bufPrint(&eb, "ffmpeg spawn failed: {s}", .{@errorName(err)}) catch "ffmpeg spawn failed";
        setError(em);
        logs.pushLog("error", "voice", em, false);
        return;
    };

    while (is_recording) {
        @import("../core/io_global.zig").sleep(100_000_000);
    }

    _ = record_child.kill() catch {};
    _ = record_child.wait() catch {};
    logs.pushLog("info", "voice", "Mic: ffmpeg stopped, checking output", true);

    if (@import("../core/io_global.zig").cwdAccess(MIC_WAV_PATH, .{})) |_| {
        is_transcribing = true;
        defer {
            is_transcribing = false;
        }
        transcribeAndSend();
    } else |_| {
        setError("No audio recorded — check mic permission in System Settings → Privacy & Security → Microphone");
    }
}

pub const isHallucination = @import("voice_filter.zig").isHallucination;

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
    const server = @import("ai_server.zig");
    server.inference_mutex.lock();
    defer server.inference_mutex.unlock();

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

    // Pick first available whisper binary: local build, then brew's whisper-cpp.
    const whisper_bin = blk: {
        if (@import("../core/io_global.zig").cwdAccess("bin/whisper.cpp/build/bin/whisper-cli", .{})) |_| {
            break :blk "bin/whisper.cpp/build/bin/whisper-cli";
        } else |_| {}
        if (@import("../core/io_global.zig").cwdAccess("/opt/homebrew/bin/whisper-cpp", .{})) |_| {
            break :blk "/opt/homebrew/bin/whisper-cpp";
        } else |_| {}
        if (@import("../core/io_global.zig").cwdAccess("/opt/homebrew/bin/whisper-cli", .{})) |_| {
            break :blk "/opt/homebrew/bin/whisper-cli";
        } else |_| {}
        setError("No ASR: install via `brew install whisper-cpp` then download a ggml model to bin/whisper.cpp/models/");
        return;
    };

    var w_child = @import("../core/io_global.zig").Child.init(
        &.{ whisper_bin, "-m", model, "-f", MIC_WAV_PATH, "-t", "4", "--no-timestamps", "--no-prints", "-otxt" },
        @import("../core/alloc.zig").allocator,
    );
    w_child.stdout_behavior = .Ignore;
    w_child.stderr_behavior = .Ignore;
    _ = w_child.spawnAndWait() catch {
        setError("whisper failed — check model at bin/whisper.cpp/models/ggml-tiny.en.bin");
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
    // User interrupted — drop any further sentences of the superseded reply.
    // Centralizing the check here means every speak site (sentence-streaming,
    // trailing remainder, full-response, intent, comics) honors barge-in for free.
    if (barge_in.load(.acquire)) return;
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
    // TTS-only lock — see tts_mutex comment. Deliberately NOT inference_mutex,
    // which generateResponse holds while streaming sentences to us.
    tts_mutex.lock();
    defer tts_mutex.unlock();

    defer {
        is_speaking = false;
    }

    // A barge-in (or stop) may have fired between speakResponse() spawning us
    // and this thread acquiring the lock — bail before making any sound.
    if (barge_in.load(.acquire)) return;

    const state = @import("../core/state.zig");
    const text = tts_text_buf[0..tts_text_len];

    // Strategy 0: Use the active voice backend's TTS (respects user's
    // Kokoro/sherpa/speaches selection and voice/speed settings).
    // Only whisper_cpp_plus_say and apple_native fall through to `say`.
    const vb = @import("voice_backend.zig");
    const backend_kind = vb.active_kind;
    if (backend_kind != .whisper_cpp_plus_say and backend_kind != .apple_native) {
        const b = vb.active();
        b.speak(text);
        logs.pushLog("info", "voice", "Spoke via voice backend", false);
        return;
    }

    // Strategy 0b (macOS): native `say` — for whisper_cpp_plus_say / apple_native backends.
    if (@import("builtin").os.tag == .macos) {
        var say_child = @import("../core/io_global.zig").Child.init(
            &.{ "say", text },
            @import("../core/alloc.zig").allocator,
        );
        say_child.stdout_behavior = .Ignore;
        say_child.stderr_behavior = .Ignore;
        if (say_child.spawnAndWait()) |_| {
            logs.pushLog("info", "voice", "Spoke via macOS say", false);
            return;
        } else |_| {}
    }

    // Strategy 1: Persistent TTS server (instant — model already loaded)
    if (tts_server_started and speakViaServer(text)) {
        // WAV generated, play it
        var play = @import("../core/io_global.zig").Child.init(
            &.{ if (@import("builtin").os.tag == .macos) "afplay" else "aplay", TTS_WAV_PATH },
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
    const tts_cmd = std.fmt.bufPrintZ(
        &tts_cmd_buf,
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
        &.{ if (@import("builtin").os.tag == .macos) "afplay" else "aplay", TTS_WAV_PATH },
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
