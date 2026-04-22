const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const c = @import("../core/c.zig");

// ══════════════════════════════════════════════════════════
// Auto Subtitles — whisper.cpp transcription of the current media.
// Pipeline: ffmpeg extracts 16kHz mono WAV → whisper-cli emits SRT →
//           mpv loads the SRT via sub-add.
// Runs in a background thread; UI observes `in_progress` + `status_buf`.
// ══════════════════════════════════════════════════════════

pub var in_progress: bool = false;
pub var status_buf: [128]u8 = std.mem.zeroes([128]u8);
pub var status_len: usize = 0;

fn setStatus(msg: []const u8) void {
    const n = @min(msg.len, status_buf.len);
    @memcpy(status_buf[0..n], msg[0..n]);
    status_len = n;
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
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
    const p = std.fmt.bufPrintZ(buf, "{s}/.config/opal/models/ggml-tiny.en.bin", .{home}) catch return null;
    if (io.cwdAccess(p, .{})) |_| return p else |_| return null;
}

/// Kick off transcription of the currently playing media. Safe to call from
/// UI thread — all heavy work happens inside the spawned thread.
pub fn transcribeCurrent() void {
    if (in_progress) return;
    if (state.app.active_player_idx >= state.app.players.items.len) {
        state.showToast("No active player");
        return;
    }
    const p = state.app.players.items[state.app.active_player_idx];

    // Capture the current media path up-front so a file change mid-run
    // doesn't corrupt the transcription target.
    const path_c = c.mpv.mpv_get_property_string(p.mpv_ctx, "path");
    if (path_c == null) {
        state.showToast("No media path available");
        return;
    }
    const path_slice = std.mem.span(path_c);
    // mpv_free needs the original pointer; make an owned copy before freeing.
    const alloc = @import("../core/alloc.zig").allocator;
    const media_path = alloc.dupe(u8, path_slice) catch {
        c.mpv.mpv_free(@ptrCast(path_c));
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
        return;
    }

    in_progress = true;
    setStatus("Starting transcription...");

    const args = alloc.create(WorkerArgs) catch {
        alloc.free(media_path);
        in_progress = false;
        return;
    };
    args.* = .{ .path = media_path };

    _ = std.Thread.spawn(.{}, worker, .{args}) catch {
        alloc.free(args.path);
        alloc.destroy(args);
        in_progress = false;
        setStatus("Failed to spawn thread");
    };
}

const WorkerArgs = struct { path: []u8 };

fn worker(args: *WorkerArgs) void {
    const alloc = @import("../core/alloc.zig").allocator;
    defer {
        alloc.free(args.path);
        alloc.destroy(args);
        in_progress = false;
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

    // Temp WAV next to the source. Using a dedicated /tmp path avoids write
    // permission issues on read-only media folders.
    // Unique-enough temp suffix: monotonic counter is fine — only one
    // auto-subs run can be in flight at a time (guarded by in_progress).
    const S = struct { var counter: u64 = 0; };
    S.counter +%= 1;
    var tmp_wav_buf: [512]u8 = undefined;
    const tmp_wav = std.fmt.bufPrintZ(&tmp_wav_buf, "/tmp/opal_autosubs_{d}.wav", .{S.counter}) catch {
        setStatus("tmp path too long");
        return;
    };

    setStatus("Extracting audio (ffmpeg)...");
    const ff_argv = [_][]const u8{
        "ffmpeg", "-y", "-i", args.path,
        "-ar", "16000", "-ac", "1", "-vn",
        "-f", "wav", tmp_wav,
    };
    var ff = @import("../core/io_global.zig").Child.init(&ff_argv, alloc);
    ff.stdout_behavior = .Ignore;
    ff.stderr_behavior = .Ignore;
    ff.spawn() catch {
        setStatus("ffmpeg spawn failed");
        return;
    };
    const ff_res = ff.wait() catch {
        setStatus("ffmpeg crashed");
        return;
    };
    if (ff_res.exited != 0) {
        setStatus("ffmpeg failed (unsupported media?)");
        return;
    }

    setStatus("Transcribing (whisper.cpp)...");
    // whisper-cli writes <basename>.srt next to the WAV when -osrt passed.
    const wh_argv = [_][]const u8{
        whisper_bin,
        "-m", model_path,
        "-f", tmp_wav,
        "-osrt",
        "-t", "4",
        "--no-prints",
    };
    var wh = @import("../core/io_global.zig").Child.init(&wh_argv, alloc);
    wh.stdout_behavior = .Ignore;
    wh.stderr_behavior = .Ignore;
    wh.spawn() catch {
        setStatus("whisper-cli spawn failed");
        _ = @import("../core/io_global.zig").deleteFileAbsolute(tmp_wav) catch {};
        return;
    };
    const wh_res = wh.wait() catch {
        setStatus("whisper crashed");
        _ = @import("../core/io_global.zig").deleteFileAbsolute(tmp_wav) catch {};
        return;
    };
    if (wh_res.exited != 0) {
        setStatus("whisper failed");
        _ = @import("../core/io_global.zig").deleteFileAbsolute(tmp_wav) catch {};
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
    _ = @import("../core/io_global.zig").renameAbsolute(srt_path, final_srt) catch {};

    const io = @import("../core/io_global.zig");
    const load_target = if (io.cwdAccess(final_srt, .{})) |_| final_srt else |_| srt_path;
    setStatus("Loading subtitles...");
    if (state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        var cmd_buf: [800]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "sub-add \"{s}\"", .{load_target}) catch return;
        _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
    }
    _ = @import("../core/io_global.zig").deleteFileAbsolute(tmp_wav) catch {};
    setStatus("Auto-subtitles ready");
    logs.pushLog("info", "subs", "Auto-subtitles generated via whisper", false);
    state.showToast("✓ Auto-subs loaded");
}
