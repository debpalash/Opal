const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const c = @import("../core/c.zig");
const bounded_process = @import("../core/bounded_process.zig");
const sync = @import("../core/sync.zig");
const target_policy = @import("auto_subs_pure.zig");

// ══════════════════════════════════════════════════════════
// Auto Subtitles — whisper.cpp transcription of the current media.
// Pipeline: ffmpeg extracts 16kHz mono WAV → whisper-cli emits SRT →
//           mpv loads the SRT via sub-add.
// Runs in a background thread; UI observes `in_progress` + `status_buf`.
// ══════════════════════════════════════════════════════════

/// Whisper language for transcription. "auto" = auto-detect, "en" = English, etc.
pub var whisper_lang: [8]u8 = .{ 'e', 'n', 0, 0, 0, 0, 0, 0 };
pub var whisper_lang_len: usize = 2;

/// Model size preference: "tiny", "base", "small", "medium"
pub var whisper_model_size: [8]u8 = .{ 't', 'i', 'n', 'y', 0, 0, 0, 0 };
pub var whisper_model_size_len: usize = 4;

pub var in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var status_buf: [128]u8 = std.mem.zeroes([128]u8);
pub var status_len: usize = 0;
var status_mutex: sync.Mutex = .{};

/// Path of the last generated .srt file (for export UI)
pub var last_srt_path: [600]u8 = std.mem.zeroes([600]u8);
pub var last_srt_path_len: usize = 0;

var run_epoch = std.atomic.Value(u64).init(1);
var pending_mutex: sync.Mutex = .{};
var pending_attach: PendingAttach = .{};

const PendingAttach = struct {
    ready: bool = false,
    player_addr: usize = 0,
    load_serial: u64 = 0,
    epoch: u64 = 0,
    path: [600]u8 = std.mem.zeroes([600]u8),
    path_len: usize = 0,
};

fn setStatus(msg: []const u8) void {
    status_mutex.lock();
    defer status_mutex.unlock();
    const n = @min(msg.len, status_buf.len);
    @memcpy(status_buf[0..n], msg[0..n]);
    status_len = n;
}

pub const StatusSnapshot = struct {
    text: [128]u8 = std.mem.zeroes([128]u8),
    len: usize = 0,
};

pub fn statusSnapshot() StatusSnapshot {
    status_mutex.lock();
    defer status_mutex.unlock();
    var out: StatusSnapshot = .{};
    out.len = @min(status_len, out.text.len);
    @memcpy(out.text[0..out.len], status_buf[0..out.len]);
    return out;
}

fn resolveWhisperBin() ?[]const u8 {
    const io = @import("../core/io_global.zig");
    const cands = [_][]const u8{
        "bin/whisper.cpp/build/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cli",
        "/usr/local/bin/whisper-cpp",
    };
    for (cands) |p| {
        if (io.cwdAccess(p, .{})) |_| return p else |_| {}
    }
    return null;
}

fn resolveWhisperModel(buf: *[512]u8) ?[]const u8 {
    const io = @import("../core/io_global.zig");
    var __cfg_buf_0: [512]u8 = undefined;
    const home = @import("../core/paths.zig").configDir(&__cfg_buf_0);
    const lang = whisper_lang[0..whisper_lang_len];
    const size = whisper_model_size[0..whisper_model_size_len];
    const is_en = std.mem.eql(u8, lang, "en");

    // Try language-specific model first (e.g. ggml-tiny.en.bin for English)
    if (is_en) {
        const p = std.fmt.bufPrintZ(buf, "{s}/models/ggml-{s}.en.bin", .{ home, size }) catch return null;
        if (io.cwdAccess(p, .{})) |_| return p else |_| {}
    }
    // Try multilingual model (e.g. ggml-tiny.bin)
    {
        const p = std.fmt.bufPrintZ(buf, "{s}/models/ggml-{s}.bin", .{ home, size }) catch return null;
        if (io.cwdAccess(p, .{})) |_| return p else |_| {}
    }
    // Fallback: any tiny model
    {
        const p = std.fmt.bufPrintZ(buf, "{s}/models/ggml-tiny.en.bin", .{home}) catch return null;
        if (io.cwdAccess(p, .{})) |_| return p else |_| {}
    }
    return null;
}

/// Kick off transcription of the currently playing media. Safe to call from
/// UI thread — all heavy work happens inside the spawned thread.
pub fn transcribeCurrent() void {
    // Atomically claim the transcription slot — only proceed if we flipped
    // false→true, closing the check-then-spawn double-spawn window. Every early
    // return below must release the slot.
    if (in_progress.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    if (state.app.active_player_idx >= state.app.players.items.len) {
        state.showToast("No active player");
        in_progress.store(false, .release);
        return;
    }
    const p = state.app.players.items[state.app.active_player_idx];
    const epoch = run_epoch.load(.acquire);
    const player_addr = @intFromPtr(p);
    const load_serial = p.load_serial;

    // Capture the current media path up-front so a file change mid-run
    // doesn't corrupt the transcription target.
    const path_c = c.mpv.mpv_get_property_string(p.mpv_ctx, "path");
    if (path_c == null) {
        state.showToast("No media path available");
        in_progress.store(false, .release);
        return;
    }
    const path_slice = std.mem.span(path_c);
    // mpv_free needs the original pointer; make an owned copy before freeing.
    const alloc = @import("../core/alloc.zig").allocator;
    const media_path = alloc.dupe(u8, path_slice) catch {
        c.mpv.mpv_free(@ptrCast(path_c));
        in_progress.store(false, .release);
        return;
    };
    c.mpv.mpv_free(@ptrCast(path_c));

    // Skip network streams — whisper can't process magnet/http by filename.
    if (std.mem.startsWith(u8, media_path, "magnet:") or
        std.mem.startsWith(u8, media_path, "http://") or
        std.mem.startsWith(u8, media_path, "https://"))
    {
        state.showToast("Auto-subs need a local file");
        alloc.free(media_path);
        in_progress.store(false, .release);
        return;
    }

    setStatus("Starting transcription...");

    const args = alloc.create(WorkerArgs) catch {
        alloc.free(media_path);
        in_progress.store(false, .release);
        return;
    };
    args.* = .{ .path = media_path, .epoch = epoch, .player_addr = player_addr, .load_serial = load_serial };

    if (@import("../core/workers.zig").spawnLegacy(worker, .{args})) |t| @import("../core/workers.zig").release(t) else |_| {
        alloc.free(args.path);
        alloc.destroy(args);
        in_progress.store(false, .release);
        setStatus("Failed to spawn thread");
    }
}

const WorkerArgs = struct {
    path: []u8,
    epoch: u64,
    player_addr: usize,
    load_serial: u64,
};

fn runContained(argv: []const []const u8, timeout_ms: i64, epoch: u64) bool {
    var process = bounded_process.StreamProcess.init(argv, .{
        .timeout_ms = timeout_ms,
        .terminate_grace_ms = 500,
        .max_output_bytes = 64 * 1024,
        .cancel_epoch = .{ .epoch64 = .{ .value = &run_epoch, .expected = epoch } },
        .cancel_flag = @import("../core/workers.zig").quittingSignal(),
    });
    process.start() catch return false;
    return process.finish().ok();
}

fn publishAttach(args: *const WorkerArgs, path: []const u8) bool {
    if (run_epoch.load(.acquire) != args.epoch) return false;
    pending_mutex.lock();
    defer pending_mutex.unlock();
    if (run_epoch.load(.acquire) != args.epoch) return false;
    pending_attach = .{
        .ready = true,
        .player_addr = args.player_addr,
        .load_serial = args.load_serial,
        .epoch = args.epoch,
    };
    pending_attach.path_len = @min(path.len, pending_attach.path.len);
    @memcpy(pending_attach.path[0..pending_attach.path_len], path[0..pending_attach.path_len]);
    state.wakeUi();
    return true;
}

/// Cancel a transcription when playback identity changes. The contained
/// process watchdog terminates the entire ffmpeg/Whisper tree promptly.
pub fn cancelForMediaChange() void {
    _ = run_epoch.fetchAdd(1, .acq_rel);
    pending_mutex.lock();
    pending_attach.ready = false;
    pending_mutex.unlock();
}

/// UI-thread handoff: only the exact player/load that requested transcription
/// may receive the generated track.
pub fn pollAttach() void {
    var pending: PendingAttach = .{};
    pending_mutex.lock();
    if (pending_attach.ready) {
        pending = pending_attach;
        pending_attach.ready = false;
    }
    pending_mutex.unlock();
    if (!pending.ready) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const player = state.app.players.items[state.app.active_player_idx];
    const target: target_policy.Target = .{
        .player_addr = pending.player_addr,
        .load_serial = pending.load_serial,
        .epoch = pending.epoch,
    };
    if (!target_policy.matches(target, @intFromPtr(player), player.load_serial, run_epoch.load(.acquire))) return;
    _ = c.mpvSubAdd(player.mpv_ctx, pending.path[0..pending.path_len]);
    last_srt_path_len = @min(pending.path_len, last_srt_path.len);
    @memcpy(last_srt_path[0..last_srt_path_len], pending.path[0..last_srt_path_len]);
    setStatus("Auto-subtitles ready");
    logs.pushLog("info", "subs", "Auto-subtitles generated via whisper", false);
    state.showToast("Auto-subs loaded");
}

fn worker(args: *WorkerArgs) void {
    const alloc = @import("../core/alloc.zig").allocator;
    defer {
        alloc.free(args.path);
        alloc.destroy(args);
        in_progress.store(false, .release);
    }

    const whisper_bin = resolveWhisperBin() orelse {
        setStatus("whisper-cli not found — brew install whisper-cpp");
        return;
    };
    var model_buf: [512]u8 = undefined;
    const model_path = resolveWhisperModel(&model_buf) orelse {
        setStatus("whisper model missing — see setup modal");
        return;
    };

    // Private per-run directory prevents another local user from predicting or
    // replacing the extracted audio path with a symlink. Cleanup is centralized
    // so every early return removes both WAV and transient SRT.
    var nonce: [16]u8 = undefined;
    if (!@import("../core/io_global.zig").randomSecure(&nonce)) {
        setStatus("secure temp setup failed");
        return;
    }
    var nonce_hex: [32]u8 = undefined;
    const digits = "0123456789abcdef";
    for (nonce, 0..) |byte, i| {
        nonce_hex[i * 2] = digits[byte >> 4];
        nonce_hex[i * 2 + 1] = digits[byte & 0x0f];
    }
    var run_dir_buf: [512]u8 = undefined;
    var tmp_dir_buf: [512]u8 = undefined;
    const run_dir = std.fmt.bufPrint(&run_dir_buf, "{s}/opal-autosubs-{s}", .{ @import("../core/io_global.zig").tmpDir(&tmp_dir_buf), nonce_hex }) catch {
        setStatus("tmp path too long");
        return;
    };
    @import("../core/io_global.zig").makeDirAbsolute(run_dir) catch {
        setStatus("secure temp setup failed");
        return;
    };
    defer @import("../core/io_global.zig").cwdDeleteTree(run_dir) catch {};
    var tmp_wav_buf: [600]u8 = undefined;
    const tmp_wav = std.fmt.bufPrintZ(&tmp_wav_buf, "{s}/audio.wav", .{run_dir}) catch return;

    setStatus("Extracting audio (ffmpeg)...");
    const ff_argv = [_][]const u8{
        "ffmpeg", "-n",    "-i",  args.path,
        "-ar",    "16000", "-ac", "1",
        "-vn",    "-f",    "wav", tmp_wav,
    };
    if (!runContained(&ff_argv, 30 * 60 * 1000, args.epoch)) {
        setStatus(if (run_epoch.load(.acquire) != args.epoch) "Transcription cancelled" else "ffmpeg failed or timed out");
        return;
    }

    setStatus("Transcribing (whisper.cpp)...");
    // Build whisper-cli args with language flag
    const lang = whisper_lang[0..whisper_lang_len];
    const use_lang = !std.mem.eql(u8, lang, "en") and !std.mem.eql(u8, lang, "auto");
    // whisper-cli writes <basename>.srt next to the WAV when -osrt passed.
    const wh_argv = if (use_lang) [_][]const u8{
        whisper_bin,
        "-m",
        model_path,
        "-f",
        tmp_wav,
        "-osrt",
        "-l",
        lang,
        "-t",
        "4",
        "--no-prints",
    } else [_][]const u8{
        whisper_bin,
        "-m",
        model_path,
        "-f",
        tmp_wav,
        "-osrt",
        "-t",
        "4",
        "--no-prints",
        "", "", // padding for array size match
    };
    if (!runContained(&wh_argv, 4 * 60 * 60 * 1000, args.epoch)) {
        setStatus(if (run_epoch.load(.acquire) != args.epoch) "Transcription cancelled" else "whisper failed or timed out");
        return;
    }

    // whisper-cli emits <input>.srt → /tmp/opal_autosubs_<ts>.wav.srt
    var srt_path_buf: [600]u8 = undefined;
    const srt_path = std.fmt.bufPrintZ(&srt_path_buf, "{s}.srt", .{tmp_wav}) catch {
        setStatus("srt path too long");
        return;
    };

    // Try to move the SRT next to the media so mpv can remember it for
    // repeat plays; fall back to the tmp location if we can't write there.
    var final_srt_buf: [600]u8 = undefined;
    const dot = std.mem.lastIndexOfScalar(u8, args.path, '.') orelse args.path.len;
    const final_srt = std.fmt.bufPrintZ(&final_srt_buf, "{s}.auto.srt", .{args.path[0..dot]}) catch srt_path;
    const io = @import("../core/io_global.zig");
    io.renameAbsolute(srt_path, final_srt) catch {
        // Read-only media location: retain the generated subtitle in Opal's
        // private cache, not the shared temp directory that is about to be
        // removed. mpv loads asynchronously, so deleting its only path here
        // would race the sub-add command.
        var cache_dir_buf: [600]u8 = undefined;
        const cache_dir = @import("../core/paths.zig").cacheFile(&cache_dir_buf, "auto-subs");
        io.cwdMakePath(cache_dir) catch {
            setStatus("could not retain generated subtitles");
            return;
        };
        var fallback_buf: [700]u8 = undefined;
        const fallback = std.fmt.bufPrintZ(&fallback_buf, "{s}/{s}.srt", .{ cache_dir, nonce_hex }) catch return;
        io.renameAbsolute(srt_path, fallback) catch {
            setStatus("could not retain generated subtitles");
            return;
        };
        if (@import("builtin").os.tag != .windows) {
            const kept = io.openFileAbsolute(fallback, .{ .mode = .read_write }) catch null;
            if (kept) |file| {
                file.setPermissions(io.io(), std.Io.File.Permissions.fromMode(0o600)) catch {};
                file.close(io.io());
            }
        }
        setStatus("Loading subtitles...");
        _ = publishAttach(args, fallback);
        return;
    };
    const load_target = final_srt;

    setStatus("Loading subtitles...");
    _ = publishAttach(args, load_target);
}
