const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const theme = @import("../ui/theme.zig");
const logs = @import("../core/logs.zig");
const paths = @import("../core/paths.zig");

/// Language Learning Module.
/// - Reads current subtitle text from mpv ("sub-text" property)
/// - Splits into clickable words
/// - Clicking a word sends HTTP request to lang_server.py → KittenTTS
/// - Receives WAV audio back, plays via aplay

const LANG_SERVER_PORT = 41594;
const MAX_WORDS = 64;
const MAX_WORD_LEN = 64;
const MAX_SUB_LEN = 512;

// Current subtitle state
var current_sub_text: [MAX_SUB_LEN]u8 = std.mem.zeroes([MAX_SUB_LEN]u8);
var current_sub_len: usize = 0;
var words: [MAX_WORDS][MAX_WORD_LEN]u8 = undefined;
var word_lens: [MAX_WORDS]usize = std.mem.zeroes([MAX_WORDS]usize);
var word_count: usize = 0;

// TTS playback state
var speaking_word_idx: i32 = -1;
var tts_thread: ?std.Thread = null;
var tts_busy: bool = false;

// Translation state
var translated_text: [MAX_SUB_LEN * 2]u8 = std.mem.zeroes([MAX_SUB_LEN * 2]u8);
var translated_len: usize = 0;
var translate_thread: ?std.Thread = null;
var translate_busy: bool = false;
var last_translated_hash: u64 = 0; // dedup — don't re-translate same text

// ASR state
var asr_thread: ?std.Thread = null;
var asr_last_trigger: i64 = 0;

// Dubbing state
var dub_thread: ?std.Thread = null;
var dub_last_sub_hash: u64 = 0;

// Server process management
var server_process: ?@import("../core/io_global.zig").Child = null;
var server_starting: bool = false;

/// Start the TTS server as a managed child process.
pub fn startServer() void {
    if (server_process != null) return; // Already managed
    if (server_starting) return;
    server_starting = true;

    // First check if server is already running (user started it manually)
    if (checkServerHealth()) {
        state.app.tts_server_ok = true;
        logs.pushLog("info", "tts", "TTS server already running (external)", false);
        server_starting = false;
        return;
    }

    // Find the script relative to the source/project dir
    // Try multiple paths: CWD/tools/lang_server.py, or exe-relative
    const script_paths = [_][]const u8{
        "tools/lang_server.py",
        "../tools/lang_server.py",
    };

    for (script_paths) |script_path| {
        if (@import("../core/io_global.zig").cwdAccess(script_path, .{})) {
            var child = @import("../core/io_global.zig").Child.init(
                &.{ "python3", script_path },
                @import("../core/alloc.zig").allocator,
            );
            child.spawn() catch {
                logs.pushLog("error", "tts", "Failed to spawn TTS server", true);
                server_starting = false;
                return;
            };
            server_process = child;
            logs.pushLog("info", "tts", "TTS server started (python3 lang_server.py)", false);
            server_starting = false;
            
            // Give server time to load model before health checking
            state.app.tts_health_check_time = @import("../core/io_global.zig").timestamp() + 8;
            return;
        } else |_| {
            continue;
        }
    }
    
    logs.pushLog("warn", "tts", "tools/lang_server.py not found — start manually", true);
    server_starting = false;
}

/// Stop the managed TTS server process.
pub fn stopServer() void {
    if (server_process) |*child| {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        server_process = null;
        state.app.tts_server_ok = false;
        logs.pushLog("info", "tts", "TTS server stopped", false);
    }
}

/// Called when lang_learn is toggled. Manages server lifecycle.
pub fn onToggle(enabled: bool) void {
    if (enabled) {
        if (!state.app.tts_server_ok and server_process == null) {
            startServer();
        }
    } else {
        current_sub_len = 0;
        word_count = 0;
        // Don't stop server on toggle — user might re-enable
    }
}

/// Called on app shutdown — clean up server process.
pub fn deinit() void {
    stopServer();
}

/// Poll current subtitle text from mpv and tokenize into words.
pub fn pollSubtitle() void {
    if (!state.app.lang_learn_enabled) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;

    const p = state.app.players.items[state.app.active_player_idx];

    // Read current subtitle text from the cached mirror updated by the mpv
    // "sub-text" property observer (A4) — no per-frame IPC or allocation here.
    const sub_text = p.cached_sub_text[0..p.cached_sub_text_len];

    if (sub_text.len > 0 and sub_text.len < MAX_SUB_LEN) {
        // Only re-tokenize if subtitle text changed
        if (!std.mem.eql(u8, current_sub_text[0..current_sub_len], sub_text)) {
            @memcpy(current_sub_text[0..sub_text.len], sub_text);
            current_sub_len = sub_text.len;
            tokenizeWords(sub_text);

            // Trigger translation if enabled
            if (state.app.translate_enabled and !translate_busy) {
                const hash = std.hash.Wyhash.hash(0, sub_text);
                if (hash != last_translated_hash) {
                    last_translated_hash = hash;
                    translated_len = 0; // Clear while translating
                    translate_busy = true;
                    translate_thread = std.Thread.spawn(.{}, translateWorker, .{}) catch {
                        translate_busy = false;
                        return;
                    };
                }
            }
        }
    } else if (sub_text.len == 0) {
        current_sub_len = 0;
        word_count = 0;
        translated_len = 0;
    }

    // Periodic health check (every 5 seconds)
    const now = @import("../core/io_global.zig").timestamp();
    if (now - state.app.tts_health_check_time > 5) {
        state.app.tts_health_check_time = now;
        state.app.tts_server_ok = checkServerHealth();
    }
    
    // Poll ASR and dubbing
    pollASR();
    pollDubbing();
}

/// Split subtitle text into individual words.
fn tokenizeWords(text: []const u8) void {
    word_count = 0;
    var i: usize = 0;
    
    while (i < text.len and word_count < MAX_WORDS) {
        // Skip whitespace
        while (i < text.len and (text[i] == ' ' or text[i] == '\n' or text[i] == '\r' or text[i] == '\t')) {
            i += 1;
        }
        if (i >= text.len) break;
        
        // Find end of word
        const start = i;
        while (i < text.len and text[i] != ' ' and text[i] != '\n' and text[i] != '\r' and text[i] != '\t') {
            i += 1;
        }
        
        const word = text[start..i];
        if (word.len > 0 and word.len < MAX_WORD_LEN) {
            @memcpy(words[word_count][0..word.len], word);
            word_lens[word_count] = word.len;
            word_count += 1;
        }
    }
}

/// Perform HTTP GET using curl (reliable, handles encoding/redirects).
fn httpGetRaw(url_str: []const u8, response_buf: []u8) !usize {
    // Scratch file in the per-user XDG cache dir (~/.cache/zigzag), NOT a
    // world-writable /tmp path — avoids the symlink/predictable-name race a
    // multi-user box would expose. Matches the asr_* scratch files below.
    var tmp_path_buf: [512]u8 = undefined;
    const tmp_path = paths.cacheFile(&tmp_path_buf, "http_resp.tmp");

    var child = @import("../core/io_global.zig").Child.init(
        &.{ "curl", "-s", "-o", tmp_path, "--max-time", "10", url_str },
        @import("../core/alloc.zig").allocator,
    );
    child.spawn() catch return error.HttpFailed;
    _ = child.wait() catch return error.HttpFailed;
    
    // Read the response file
    const file = @import("../core/io_global.zig").openFileAbsolute(tmp_path, .{}) catch return error.HttpFailed;
    defer file.close(@import("../core/io_global.zig").io());
    const bytes_read = @import("../core/io_global.zig").readAll(file, response_buf) catch return error.HttpFailed;
    return bytes_read;
}

/// URL-encode a string (only encodes space, &, =, ?, #, and non-ASCII)
fn urlEncode(input: []const u8, out: []u8) usize {
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
            out[j + 1] = "0123456789ABCDEF"[ch >> 4];
            out[j + 2] = "0123456789ABCDEF"[ch & 0x0F];
            j += 3;
        }
    }
    return j;
}

/// Speak a word via the TTS server (background thread).
pub fn speakWord(word_idx: usize) void {
    if (word_idx >= word_count) return;
    if (tts_busy) return;
    
    speaking_word_idx = @intCast(word_idx);
    tts_busy = true;
    
    tts_thread = std.Thread.spawn(.{}, ttsWorker, .{word_idx}) catch {
        tts_busy = false;
        speaking_word_idx = -1;
        return;
    };
}

fn ttsWorker(word_idx: usize) void {
    defer {
        tts_busy = false;
        speaking_word_idx = -1;
    }
    
    const word = words[word_idx][0..word_lens[word_idx]];
    
    // URL-encode the word
    var encoded_word: [256]u8 = undefined;
    const enc_len = urlEncode(word, &encoded_word);
    
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/speak?text={s}&voice={s}&speed={d:.1}", .{
        LANG_SERVER_PORT,
        encoded_word[0..enc_len],
        state.app.tts_voice_buf[0..state.app.tts_voice_len],
        state.app.tts_speed,
    }) catch return;
    
    const wav_buf = @import("../core/alloc.zig").allocator.alloc(u8, 512 * 1024) catch return;
    defer @import("../core/alloc.zig").allocator.free(wav_buf);
    const body_len = httpGetRaw(url, wav_buf) catch {
        logs.pushLog("warn", "tts", "TTS server not running (start tools/lang_server.py)", true);
        return;
    };
    
    if (body_len < 44) return;
    
    // TODO: use unique temp paths for security (predictable /tmp names on multi-user systems)
    const wav_path = "/tmp/zigzag_tts_word.wav";
    const file = @import("../core/io_global.zig").cwdCreateFile(wav_path, .{ .truncate = true }) catch return;
    @import("../core/io_global.zig").writeAll(file, wav_buf[0..body_len]) catch { file.close(@import("../core/io_global.zig").io()); return; };
    file.close(@import("../core/io_global.zig").io());
    
    // Play via aplay (doesn't interfere with mpv)
    var play = @import("../core/io_global.zig").Child.init(
        &.{ "aplay", "-q", wav_path },
        @import("../core/alloc.zig").allocator,
    );
    _ = play.spawnAndWait() catch {};
}

/// Speak the entire current subtitle line.
pub fn speakFullLine() void {
    if (current_sub_len == 0) return;
    if (tts_busy) return;
    
    tts_busy = true;
    speaking_word_idx = -2;
    
    tts_thread = std.Thread.spawn(.{}, ttsLineWorker, .{}) catch {
        tts_busy = false;
        speaking_word_idx = -1;
        return;
    };
}

fn ttsLineWorker() void {
    defer {
        tts_busy = false;
        speaking_word_idx = -1;
    }
    
    // Snapshot subtitle text into a local buffer to avoid racing with
    // the main thread's pollSubtitle() which may update current_sub_text.
    var text_buf: [MAX_SUB_LEN]u8 = undefined;
    const text_len = current_sub_len;
    if (text_len == 0) return;
    @memcpy(text_buf[0..text_len], current_sub_text[0..text_len]);
    const text = text_buf[0..text_len];
    
    // URL-encode the full subtitle line
    var encoded_text: [2048]u8 = undefined;
    const enc_len = urlEncode(text, &encoded_text);
    
    var url_buf: [4096]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/speak?text={s}&voice={s}&speed={d:.1}", .{
        LANG_SERVER_PORT,
        encoded_text[0..enc_len],
        state.app.tts_voice_buf[0..state.app.tts_voice_len],
        state.app.tts_speed,
    }) catch return;
    
    const wav_buf = @import("../core/alloc.zig").allocator.alloc(u8, 1024 * 1024) catch return;
    defer @import("../core/alloc.zig").allocator.free(wav_buf);
    const body_len = httpGetRaw(url, wav_buf) catch return;
    if (body_len < 44) return;
    
    // TODO: use unique temp paths for security (predictable /tmp names on multi-user systems)
    const wav_path = "/tmp/zigzag_tts_line.wav";
    const file = @import("../core/io_global.zig").cwdCreateFile(wav_path, .{ .truncate = true }) catch return;
    @import("../core/io_global.zig").writeAll(file, wav_buf[0..body_len]) catch { file.close(@import("../core/io_global.zig").io()); return; };
    file.close(@import("../core/io_global.zig").io());
    
    var play = @import("../core/io_global.zig").Child.init(
        &.{ "aplay", "-q", wav_path },
        @import("../core/alloc.zig").allocator,
    );
    _ = play.spawnAndWait() catch {};
}

/// Background worker to translate current subtitle text.
fn translateWorker() void {
    defer {
        translate_busy = false;
    }
    
    // Snapshot subtitle text into a local buffer to avoid racing with
    // the main thread's pollSubtitle() which may update current_sub_text.
    var text_buf: [MAX_SUB_LEN]u8 = undefined;
    const text_len = current_sub_len;
    if (text_len == 0) return;
    @memcpy(text_buf[0..text_len], current_sub_text[0..text_len]);
    const text = text_buf[0..text_len];
    
    const target_lang = state.app.translate_lang_buf[0..state.app.translate_lang_len];
    
    // URL-encode the subtitle text for translation
    var encoded_text: [2048]u8 = undefined;
    const enc_len = urlEncode(text, &encoded_text);
    
    var url_buf: [4096]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/translate?text={s}&from=auto&to={s}", .{
        LANG_SERVER_PORT,
        encoded_text[0..enc_len],
        target_lang,
    }) catch return;
    
    const response_buf = @import("../core/alloc.zig").allocator.alloc(u8, 4096) catch return;
    defer @import("../core/alloc.zig").allocator.free(response_buf);
    const body_len = httpGetRaw(url, response_buf) catch return;
    if (body_len == 0) return;
    
    const body = response_buf[0..body_len];
    
    // Parse JSON: look for "translated":"..." 
    if (std.mem.indexOf(u8, body, "\"translated\":\"")) |start| {
        const val_start = start + 14; // len of "translated":"
        if (std.mem.indexOfScalarPos(u8, body, val_start, '"')) |val_end| {
            const tl = val_end - val_start;
            if (tl > 0 and tl < translated_text.len) {
                @memcpy(translated_text[0..tl], body[val_start..val_end]);
                translated_len = tl;
            }
        }
    }
}

// ══════════════════════════════════════════════════════════
// ASR — Automatic Speech Recognition
// Extracts audio from current playback, sends to /transcribe
// ══════════════════════════════════════════════════════════

/// Trigger ASR transcription of current audio segment.
pub fn triggerASR() void {
    if (state.app.asr_busy) return;
    if (!state.app.tts_server_ok) return;
    
    state.app.asr_busy = true;
    asr_thread = std.Thread.spawn(.{}, asrWorker, .{}) catch {
        state.app.asr_busy = false;
        return;
    };
}

/// Poll ASR — auto-trigger every 5 seconds during playback.
pub fn pollASR() void {
    if (!state.app.asr_enabled) return;
    if (!state.app.tts_server_ok) return;
    if (state.app.asr_busy) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    
    const now = @import("../core/io_global.zig").timestamp();
    if (now - asr_last_trigger < 5) return; // Every 5 seconds
    asr_last_trigger = now;
    
    // Check if we have subtitles already — don't ASR if subs exist
    if (current_sub_len > 0) return;
    
    triggerASR();
}

fn asrWorker() void {
    defer {
        state.app.asr_busy = false;
    }
    
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    
    // Get current media file path from mpv
    const path_ptr: ?[*:0]u8 = @ptrCast(c.mpv.mpv_get_property_string(p.mpv_ctx, "path"));
    if (path_ptr == null) return;
    const media_path = std.mem.span(path_ptr.?);
    defer c.mpv.mpv_free(path_ptr.?);
    
    if (media_path.len == 0) return;
    
    // Get current playback position
    var time_pos: f64 = 0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, @ptrCast(&time_pos));
    
    // Skip if position hasn't changed much (paused)
    if (@abs(time_pos - state.app.asr_last_pos) < 2.0) return;
    state.app.asr_last_pos = time_pos;
    
    paths.ensureCacheDir();
    var wav_path_buf: [512]u8 = undefined;
    const wav_path = paths.cacheFile(&wav_path_buf, "asr_chunk.wav");
    
    // Extract 5 seconds of audio using ffmpeg
    var start_buf: [32]u8 = undefined;
    const start_str = std.fmt.bufPrintZ(&start_buf, "{d:.1}", .{time_pos}) catch return;
    
    var extract_child = @import("../core/io_global.zig").Child.init(
        &.{ "ffmpeg", "-y", "-ss", start_str, "-i", media_path, 
            "-t", "5", "-ar", "16000", "-ac", "1", "-f", "wav", wav_path },
        @import("../core/alloc.zig").allocator,
    );
    _ = extract_child.spawnAndWait() catch return;
    
    // Read the WAV file
    const file = @import("../core/io_global.zig").openFileAbsolute(wav_path, .{}) catch return;
    defer file.close(@import("../core/io_global.zig").io());
    
    const wav_buf = @import("../core/alloc.zig").allocator.alloc(u8, 512 * 1024) catch return;
    defer @import("../core/alloc.zig").allocator.free(wav_buf);
    const wav_len = @import("../core/io_global.zig").readAll(file, wav_buf) catch return;
    if (wav_len < 100) return;
    
    // Write WAV data to temp file for curl upload
    var upload_path_buf: [512]u8 = undefined;
    const upload_path = paths.cacheFile(&upload_path_buf, "asr_upload.wav");
    {
        const uf = @import("../core/io_global.zig").createFileAbsolute(upload_path, .{ .truncate = true }) catch return;
        @import("../core/io_global.zig").writeAll(uf, wav_buf[0..wav_len]) catch { uf.close(@import("../core/io_global.zig").io()); return; };
        uf.close(@import("../core/io_global.zig").io());
    }
    
    // POST to /transcribe via curl
    const asr_lang = state.app.translate_lang_buf[0..state.app.translate_lang_len];
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/transcribe?lang={s}", .{ LANG_SERVER_PORT, asr_lang }) catch return;
    
    var resp_path_buf: [512]u8 = undefined;
    const resp_path = paths.cacheFile(&resp_path_buf, "asr_resp.json");
    // Build "@path" argument for curl --data-binary at runtime
    var data_arg_buf: [520]u8 = undefined;
    const data_arg = std.fmt.bufPrint(&data_arg_buf, "@{s}", .{upload_path}) catch return;
    var curl_child = @import("../core/io_global.zig").Child.init(
        &.{ "curl", "-s", "-X", "POST", "-H", "Content-Type: audio/wav",
             "--data-binary", data_arg, "-o", resp_path, "--max-time", "30", url },
        @import("../core/alloc.zig").allocator,
    );
    _ = curl_child.spawnAndWait() catch return;
    
    // Read response JSON
    const resp_file = @import("../core/io_global.zig").openFileAbsolute(resp_path, .{}) catch return;
    defer resp_file.close(@import("../core/io_global.zig").io());
    var resp_buf: [4096]u8 = undefined;
    const resp_len = @import("../core/io_global.zig").readAll(resp_file, &resp_buf) catch return;
    if (resp_len == 0) return;
    
    // Parse {"text": "..."}
    const body = resp_buf[0..resp_len];
    if (std.mem.indexOf(u8, body, "\"text\":\"")) |start| {
        const val_start = start + 8;
        if (std.mem.indexOfScalarPos(u8, body, val_start, '"')) |val_end| {
            const tl = val_end - val_start;
            if (tl > 0 and tl < state.app.asr_text_buf.len) {
                @memcpy(state.app.asr_text_buf[0..tl], body[val_start..val_end]);
                state.app.asr_text_len = tl;
                logs.pushLog("info", "asr", "Transcribed audio segment", false);
            }
        }
    }
}

// ══════════════════════════════════════════════════════════
// Audio Dubbing — Translate + TTS overlay on video
// ══════════════════════════════════════════════════════════

/// Check and trigger dubbing for the current subtitle.
pub fn pollDubbing() void {
    if (!state.app.dubbing_enabled) return;
    if (!state.app.tts_server_ok) return;
    if (state.app.dub_busy) return;
    if (current_sub_len == 0) return;
    
    const sub = current_sub_text[0..current_sub_len];
    const hash = std.hash.Wyhash.hash(0, sub);
    if (hash == state.app.dub_last_hash) return; // Already dubbed this line
    state.app.dub_last_hash = hash;
    
    state.app.dub_busy = true;
    dub_thread = std.Thread.spawn(.{}, dubWorker, .{}) catch {
        state.app.dub_busy = false;
        return;
    };
}

fn dubWorker() void {
    defer {
        state.app.dub_busy = false;
    }
    
    // Snapshot subtitle text into a local buffer to avoid racing with
    // the main thread's pollSubtitle() which may update current_sub_text.
    var text_buf: [MAX_SUB_LEN]u8 = undefined;
    const text_len = current_sub_len;
    if (text_len == 0) return;
    @memcpy(text_buf[0..text_len], current_sub_text[0..text_len]);
    const text = text_buf[0..text_len];
    
    const target_lang = state.app.translate_lang_buf[0..state.app.translate_lang_len];
    
    // Step 1: Translate the subtitle
    var encoded_text: [2048]u8 = undefined;
    const enc_len = urlEncode(text, &encoded_text);
    
    var trans_url_buf: [4096]u8 = undefined;
    const trans_url = std.fmt.bufPrint(&trans_url_buf, "http://127.0.0.1:{d}/translate?text={s}&from=auto&to={s}", .{
        LANG_SERVER_PORT, encoded_text[0..enc_len], target_lang,
    }) catch return;
    
    var trans_resp: [4096]u8 = undefined;
    const trans_len = httpGetRaw(trans_url, &trans_resp) catch return;
    if (trans_len == 0) return;
    
    // Parse translated text
    var dub_text_buf: [1024]u8 = undefined;
    var dub_text_len: usize = 0;
    
    const trans_body = trans_resp[0..trans_len];
    if (std.mem.indexOf(u8, trans_body, "\"translated\":\"")) |start| {
        const val_start = start + 14;
        if (std.mem.indexOfScalarPos(u8, trans_body, val_start, '"')) |val_end| {
            const tl = val_end - val_start;
            if (tl > 0 and tl < dub_text_buf.len) {
                @memcpy(dub_text_buf[0..tl], trans_body[val_start..val_end]);
                dub_text_len = tl;
            }
        }
    }
    
    if (dub_text_len == 0) return;
    
    // Step 2: Generate TTS of translated text
    var encoded_dub: [2048]u8 = undefined;
    const dub_enc_len = urlEncode(dub_text_buf[0..dub_text_len], &encoded_dub);
    
    var tts_url_buf: [4096]u8 = undefined;
    const tts_url = std.fmt.bufPrint(&tts_url_buf, "http://127.0.0.1:{d}/speak?text={s}&voice={s}&speed={d:.1}", .{
        LANG_SERVER_PORT, encoded_dub[0..dub_enc_len],
        state.app.tts_voice_buf[0..state.app.tts_voice_len], state.app.tts_speed,
    }) catch return;
    
    const wav_buf = @import("../core/alloc.zig").allocator.alloc(u8, 1024 * 1024) catch return;
    defer @import("../core/alloc.zig").allocator.free(wav_buf);
    const wav_len = httpGetRaw(tts_url, wav_buf) catch return;
    if (wav_len < 44) return;
    
    // Save WAV
    paths.ensureCacheDir();
    var dub_wav_path_buf: [512]u8 = undefined;
    const dub_wav_path = paths.cacheFile(&dub_wav_path_buf, "dub.wav");
    {
        const f = @import("../core/io_global.zig").createFileAbsolute(dub_wav_path, .{ .truncate = true }) catch return;
        @import("../core/io_global.zig").writeAll(f, wav_buf[0..wav_len]) catch { f.close(@import("../core/io_global.zig").io()); return; };
        f.close(@import("../core/io_global.zig").io());
    }
    
    // Step 3: Duck the mpv volume and play TTS
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        
        // Lower video volume to 30%
        _ = c.mpv.mpv_command_string(p.mpv_ctx, "set volume 30");
        
        // Play dubbed audio
        var play = @import("../core/io_global.zig").Child.init(
            &.{ "aplay", "-q", dub_wav_path },
            @import("../core/alloc.zig").allocator,
        );
        _ = play.spawnAndWait() catch {};
        
        // Restore video volume
        _ = c.mpv.mpv_command_string(p.mpv_ctx, "set volume 100");
    }
}

/// Check if TTS server is running.
pub fn checkServerHealth() bool {
    var health_buf: [256]u8 = undefined;
    const len = httpGetRaw("http://127.0.0.1:41594/health", &health_buf) catch return false;
    return len > 0;
}

/// Render the interactive subtitle bar below the video.
pub fn renderSubtitleBar() void {
    if (!state.app.lang_learn_enabled) return;
    // Always show bar when learning mode is on (sticky)
    
    // Subtitle bar container
    var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = dvui.Color{ .r = 10, .g = 12, .b = 20, .a = 230 },
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer bar.deinit();
    
    const has_subs = current_sub_len > 0;
    
    if (has_subs) {
        // ── Row 1: Clickable words ──
        {
            var word_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer word_row.deinit();
            
            for (0..word_count) |wi| {
                const word_text = words[wi][0..word_lens[wi]];
                const is_speaking = (speaking_word_idx >= 0 and @as(usize, @intCast(speaking_word_idx)) == wi);
                
                const word_bg = if (is_speaking) 
                    theme.colors.accent 
                else 
                    dvui.Color{ .r = 30, .g = 35, .b = 50, .a = 200 };
                const word_fg = if (is_speaking) dvui.Color.white else dvui.Color{ .r = 220, .g = 225, .b = 240, .a = 255 };
                
                var word_box = dvui.box(@src(), .{}, .{
                    .id_extra = wi,
                    .background = true,
                    .color_fill = word_bg,
                    .corner_radius = dvui.Rect.all(4),
                    .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
                    .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
                });
                
                _ = dvui.label(@src(), "{s}", .{word_text}, .{
                    .id_extra = wi,
                    .color_text = word_fg,
                });
                
                for (dvui.events()) |*ev| {
                    if (ev.evt == .mouse) {
                        if (ev.evt.mouse.button == .left and ev.evt.mouse.action == .press) {
                            const box_rect = word_box.data().borderRectScale().r;
                            if (ev.evt.mouse.p.x >= box_rect.x and ev.evt.mouse.p.x <= box_rect.x + box_rect.w and
                                ev.evt.mouse.p.y >= box_rect.y and ev.evt.mouse.p.y <= box_rect.y + box_rect.h) {
                                speakWord(wi);
                            }
                        }
                    }
                }
                
                word_box.deinit();
            }
        }
        
        // ── Row 2: Translation (if enabled) ──
        if (state.app.translate_enabled) {
            if (translated_len > 0) {
                var trans_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
                });
                defer trans_row.deinit();
                
                var tt_buf: [1024]u8 = undefined;
                _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(translated_text[0..translated_len], &tt_buf)}, .{
                    .color_text = dvui.Color{ .r = 180, .g = 220, .b = 130, .a = 255 },
                });
            } else if (translate_busy) {
                _ = dvui.label(@src(), "...", .{}, .{
                    .color_text = dvui.Color{ .r = 100, .g = 105, .b = 120, .a = 180 },
                    .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
                });
            }
        }
        
        // ── Row 3: Controls ──
        {
            var ctrl_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
                .gravity_y = 0.5,
            });
            defer ctrl_row.deinit();
            
            // Speak all
            const speak_color = if (speaking_word_idx == -2) theme.colors.accent else theme.colors.text_muted;
            if (dvui.button(@src(), "Speak", .{}, .{
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = speak_color,
                .padding = theme.dims.pad_xs,
            })) {
                speakFullLine();
            }
            
            // Translate toggle
            {
                const trans_color = if (state.app.translate_enabled) dvui.Color{ .r = 130, .g = 180, .b = 255, .a = 255 } else theme.colors.text_muted;
                if (dvui.button(@src(), if (state.app.translate_enabled) "TR ON" else "TR", .{}, .{
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_text = trans_color,
                    .padding = theme.dims.pad_xs,
                })) {
                    state.app.translate_enabled = !state.app.translate_enabled;
                    if (state.app.translate_enabled) {
                        translated_len = 0;
                        last_translated_hash = 0;
                    }
                }
            }
            
            // Dubbing toggle
            {
                const dub_color = if (state.app.dubbing_enabled) dvui.Color{ .r = 255, .g = 180, .b = 80, .a = 255 } else theme.colors.text_muted;
                if (dvui.button(@src(), if (state.app.dubbing_enabled) "DUB ON" else "DUB", .{}, .{
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_text = dub_color,
                    .padding = theme.dims.pad_xs,
                })) {
                    state.app.dubbing_enabled = !state.app.dubbing_enabled;
                    if (state.app.dubbing_enabled) state.app.dub_last_hash = 0;
                }
            }
            
            // ASR toggle
            {
                const asr_color = if (state.app.asr_enabled) dvui.Color{ .r = 180, .g = 255, .b = 180, .a = 255 } else theme.colors.text_muted;
                if (dvui.button(@src(), if (state.app.asr_enabled) "ASR ON" else "ASR", .{}, .{
                    .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .color_text = asr_color,
                    .padding = theme.dims.pad_xs,
                })) {
                    state.app.asr_enabled = !state.app.asr_enabled;
                    if (!state.app.asr_enabled) state.app.asr_text_len = 0;
                }
            }
            
            { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
            
            // Server status dot
            {
                const status_color = if (state.app.tts_server_ok) theme.colors.success else theme.colors.danger;
                var dot = dvui.box(@src(), .{}, .{
                    .min_size_content = .{ .w = 6, .h = 6 },
                    .background = true,
                    .color_fill = status_color,
                    .corner_radius = dvui.Rect.all(3),
                });
                dot.deinit();
            }
        }
    } else {
        // ── No subtitles: show ASR text if available ──
        if (state.app.asr_text_len > 0) {
            var asr_buf: [1024]u8 = undefined;
            _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8Buf(state.app.asr_text_buf[0..state.app.asr_text_len], &asr_buf)}, .{
                .color_text = dvui.Color{ .r = 200, .g = 210, .b = 240, .a = 230 },
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
            });
            if (state.app.asr_busy) {
                _ = dvui.label(@src(), "ASR processing...", .{}, .{
                    .color_text = dvui.Color{ .r = 100, .g = 105, .b = 120, .a = 150 },
                });
            }
        } else {
            var wait_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
            });
            defer wait_row.deinit();
            
            _ = dvui.label(@src(), "Language Learning", .{}, .{
                .color_text = theme.colors.accent,
            });
            
            { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
            
            if (state.app.asr_enabled) {
                if (state.app.asr_busy) {
                    _ = dvui.label(@src(), "ASR: processing...", .{}, .{
                        .color_text = dvui.Color{ .r = 180, .g = 255, .b = 180, .a = 200 },
                    });
                } else {
                    _ = dvui.label(@src(), "ASR: waiting...", .{}, .{
                        .color_text = dvui.Color{ .r = 180, .g = 255, .b = 180, .a = 200 },
                    });
                }
            } else {
                _ = dvui.label(@src(), "Waiting for subtitles...", .{}, .{
                    .color_text = dvui.Color{ .r = 100, .g = 105, .b = 120, .a = 200 },
                });
            }
        }
    }
}

pub fn saveSubtitleFlashcard() void {
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    
    // Check if we have any valid subtitle
    if (current_sub_len == 0 and translated_len == 0) {
        state.showToast("No subtitle to save");
        return;
    }

    // Duplicate detection
    const sub_hash = std.hash.Fnv1a_32.hash(current_sub_text[0..current_sub_len]);
    const S_fc = struct { var last_hash: u32 = 0; };
    if (sub_hash == S_fc.last_hash) {
        state.showToast("Already saved this subtitle");
        return;
    }
    S_fc.last_hash = sub_hash;

    const p = state.app.players.items[state.app.active_player_idx];
    var time_pos: f64 = 0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &time_pos);

    // Prepare CSV Path
    var csv_path_buf: [4096]u8 = undefined;
    const save_dir = state.app.save_path_buf[0..state.app.save_path_len];
    const csv_path = std.fmt.bufPrintZ(&csv_path_buf, "{s}/anki_export.csv", .{save_dir}) catch return;

    @import("../core/io_global.zig").cwdMakePath(save_dir) catch {};

    const file = @import("../core/io_global.zig").cwdOpenFile(csv_path, .{ .mode = .read_write }) catch |e| switch(e) {
        error.FileNotFound => @import("../core/io_global.zig").cwdCreateFile(csv_path, .{ .truncate = false, .exclusive = false }) catch {
            logs.pushLog("error", "lang", "Could not create Anki export file", true);
            return;
        },
        else => {
            logs.pushLog("error", "lang", "Could not write Anki export file", true);
            return;
        }
    };
    defer file.close(@import("../core/io_global.zig").io());
    
    // Get file length so we can append at the end (0.16 has no seekTo)
    const file_len = file.length(@import("../core/io_global.zig").io()) catch 0;

    // Get current source (file name or stream)
    const source_name = p.source_url[0..p.source_url_len];

    // Build the line
    const src_sub = current_sub_text[0..current_sub_len];
    const tl_sub = translated_text[0..translated_len];

    var out_buf: [8192]u8 = undefined;
    
    // Helper to escape CSV quotes manually
    var esc_src_buf: [2048]u8 = undefined;
    var esc_tl_buf: [2048]u8 = undefined;
    
    var src_idx: usize = 0;
    for (src_sub) |ch| {
        if (ch == '"' and src_idx < 2046) {
            esc_src_buf[src_idx] = '"';
            esc_src_buf[src_idx+1] = '"';
            src_idx += 2;
        } else if (ch != '\n' and ch != '\r' and src_idx < 2047) {
            esc_src_buf[src_idx] = ch;
            src_idx += 1;
        }
    }
    
    var tl_idx: usize = 0;
    for (tl_sub) |ch| {
        if (ch == '"' and tl_idx < 2046) {
            esc_tl_buf[tl_idx] = '"';
            esc_tl_buf[tl_idx+1] = '"';
            tl_idx += 2;
        } else if (ch != '\n' and ch != '\r' and tl_idx < 2047) {
            esc_tl_buf[tl_idx] = ch;
            tl_idx += 1;
        }
    }

    // Format: "source", "time", "original", "translated"
    const line = std.fmt.bufPrint(&out_buf, "\"{s}\",\"{d:.1}\",\"{s}\",\"{s}\"\n", .{
        source_name,
        time_pos,
        esc_src_buf[0..src_idx],
        esc_tl_buf[0..tl_idx]
    }) catch return;

    file.writePositionalAll(@import("../core/io_global.zig").io(), line, file_len) catch {
        logs.pushLog("error", "lang", "Failed to write flashcard data", true);
        return;
    };
    
    logs.pushLog("info", "lang", "Saved Flashcard to Anki CSV", false);
    state.showToast("\xe2\x9c\x85 Flashcard saved!");
}
