//! Live captions — the chunk pipeline (ffmpeg → 16 kHz WAV → whisper-cli →
//! cues on the media timeline). No app-state, mpv or UI dependencies, so the
//! same code runs inside Opal's worker and in the `zig build babel-live` probe.
//! Also owns whisper.cpp discovery, shared with auto_subs.zig.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("../core/io_global.zig");
const bounded = @import("../core/bounded_process.zig");
const secure_temp = @import("../core/secure_temp.zig");
const pure = @import("live_captions_pure.zig");

/// whisper-cli locations, most specific first.
pub fn resolveWhisperBin() ?[]const u8 {
    const cands = [_][]const u8{
        "bin/whisper.cpp/build/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cli",
        "/usr/local/bin/whisper-cpp",
        "/usr/bin/whisper-cli",
    };
    for (cands) |p| {
        if (io.cwdAccess(p, .{})) |_| return p else |_| {}
    }
    return null;
}

/// ggml model under <config>/models: the English-only variant first for "en",
/// then the multilingual one, then any tiny English model.
pub fn resolveWhisperModel(config_dir: []const u8, lang: []const u8, size: []const u8, buf: *[512]u8) ?[]const u8 {
    if (std.mem.eql(u8, lang, "en")) {
        const p = std.fmt.bufPrintZ(buf, "{s}/models/ggml-{s}.en.bin", .{ config_dir, size }) catch return null;
        if (io.cwdAccess(p, .{})) |_| return p else |_| {}
    }
    {
        const p = std.fmt.bufPrintZ(buf, "{s}/models/ggml-{s}.bin", .{ config_dir, size }) catch return null;
        if (io.cwdAccess(p, .{})) |_| return p else |_| {}
    }
    {
        const p = std.fmt.bufPrintZ(buf, "{s}/models/ggml-tiny.en.bin", .{config_dir}) catch return null;
        if (io.cwdAccess(p, .{})) |_| return p else |_| {}
    }
    return null;
}

pub fn ffmpegPath() []const u8 {
    const cands = [_][]const u8{ "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg", "/snap/bin/ffmpeg" };
    for (cands) |p| {
        if (io.cwdAccess(p, .{})) |_| return p else |_| {}
    }
    return "ffmpeg"; // PATH lookup
}

pub const Job = struct {
    ffmpeg: []const u8,
    whisper_bin: []const u8,
    model: []const u8,
    /// whisper -l value ("auto", "en", ...).
    lang: []const u8 = "auto",
    source: []const u8,
    user_agent: []const u8 = "",
    /// ffmpeg-format header block (live_captions_pure.ffmpegHeaders).
    headers: []const u8 = "",
    chunk: pure.Chunk,
    cancel: ?bounded.CancelEpoch = null,
    threads: []const u8 = "4",
};

pub const ChunkError = error{ Extract, Transcribe, Cancelled, NoOutput, OutOfMemory, Workspace };

/// Transcribe one chunk inside `ws`. Returned cues are already on the media
/// timeline; free with live_captions_pure.freeCues.
pub fn transcribeChunk(alloc: std.mem.Allocator, ws: *const secure_temp.Workspace, job: Job) ChunkError![]pure.Cue {
    var wav_buf: [secure_temp.max_path_len]u8 = undefined;
    const wav = ws.path("chunk.wav", &wav_buf) catch return error.Workspace;
    var base_buf: [secure_temp.max_path_len]u8 = undefined;
    const base = ws.path("chunk", &base_buf) catch return error.Workspace;
    var srt_buf: [secure_temp.max_path_len]u8 = undefined;
    const srt = ws.path("chunk.srt", &srt_buf) catch return error.Workspace;
    io.deleteFileAbsolute(wav) catch {};
    io.deleteFileAbsolute(srt) catch {};

    // Output capture is tiny (errors only / whisper's echo of the text).
    const out = alloc.alloc(u8, 64 * 1024) catch return error.OutOfMemory;
    defer alloc.free(out);

    var argv_buf: [32][]const u8 = undefined;
    var num_buf: [64]u8 = undefined;
    const ff = pure.ffmpegChunkArgv(.{
        .ffmpeg = job.ffmpeg,
        .source = job.source,
        .user_agent = job.user_agent,
        .headers = job.headers,
        .start = job.chunk.start,
        .len = job.chunk.len,
        .out_wav = wav,
    }, &argv_buf, &num_buf);
    const ff_res = bounded.run(ff, out, .{ .timeout_ms = 90_000, .cancel_epoch = job.cancel });
    if (ff_res.failure == .cancelled) return error.Cancelled;
    if (ff_res.failure != .none and ff_res.failure != .output_limit) return error.Extract;
    _ = io.cwdStatFile(wav) catch return error.Extract;

    const wh = [_][]const u8{
        job.whisper_bin, "-m",    job.model, "-f",  wav,
        "-osrt",         "-of",   base,      "-l",  job.lang,
        "-t",            job.threads, "--no-prints",
    };
    const wh_res = bounded.run(&wh, out, .{ .timeout_ms = 180_000, .cancel_epoch = job.cancel });
    if (wh_res.failure == .cancelled) return error.Cancelled;
    if (wh_res.failure != .none and wh_res.failure != .output_limit) return error.Transcribe;

    const body = io.cwdReadFileAlloc(srt, alloc, 4 * 1024 * 1024) catch return error.NoOutput;
    defer alloc.free(body);
    const cues = pure.parseSrt(alloc, body) catch return error.OutOfMemory;
    pure.offsetCues(cues, job.chunk);
    return cues;
}

/// Replace `path` atomically (write "<path>.tmp", then rename over it) so mpv's
/// sub-reload never reads a half-written file.
pub fn writeAtomic(path: []const u8, data: []const u8) !void {
    var tmp_buf: [1100]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    try io.cwdWriteFile(.{ .sub_path = tmp, .data = data });
    if (builtin.os.tag != .windows) {
        if (io.openFileAbsolute(tmp, .{ .mode = .read_write })) |f| {
            f.setPermissions(io.io(), std.Io.File.Permissions.fromMode(0o600)) catch {};
            f.close(io.io());
        } else |_| {}
    }
    try io.renameAbsolute(tmp, path);
}
