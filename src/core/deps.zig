//! Dependency bootstrap — first-run auto-install of optional binaries.
//! Philosophy: never silently download binaries (licensing + trust).
//! But the whisper model is a public ML weight, clearly-licensed, safe
//! to fetch. Binaries themselves must be installed via brew / system
//! package manager; we only detect + surface helpful install hints.

const std = @import("std");
const logs = @import("logs.zig");
const io_global = @import("io_global.zig");

pub const Status = struct {
    apfel: bool = false,
    ffmpeg: bool = false,
    whisper: bool = false,
    whisper_model: bool = false,
    sherpa_onnx: bool = false,
    sherpa_model: bool = false,
    sherpa_tts_model: bool = false, // Piper VITS lessac-medium
    sherpa_kokoro_model: bool = false, // Kokoro multi-voice TTS
    sherpa_stream_model: bool = false,
    sherpa_mic_cli: bool = false,
    mlx_whisper_cli: bool = false, // pip install mlx-whisper (Apple Silicon)
    mlx_whisper_model: bool = false, // HF cache: mlx-community/whisper-large-v3-turbo
    parakeet_v2_model: bool = false, // NVIDIA Parakeet TDT 0.6B v2 (English) — sherpa-onnx int8 export
    parakeet_v3_model: bool = false, // NVIDIA Parakeet TDT 0.6B v3 (25 languages) — sherpa-onnx int8 export
};

/// Returns true when the full sherpa stack (CLI + STT + TTS + streaming
/// + mic CLI) is present — allows voice_backend to auto-promote sherpa
/// to default.
pub fn sherpaReady(s: Status) bool {
    return s.sherpa_onnx and s.sherpa_model and s.sherpa_tts_model and
        s.sherpa_stream_model and s.sherpa_mic_cli;
}

// TTL cache for check(): the settings AI tab calls it up to 3× per frame and
// each realCheck() is ~18 access() syscalls plus a HuggingFace-hub directory
// scan — thousands of syscalls per second while the tab was open, for values
// that change at most once per install. Cache for 1s; downloads that finish
// force a recheck on their next status flip anyway (flag change → new frame →
// TTL soon expires).
//
// Mutex-guarded: check() is called from the UI thread every frame AND from
// worker threads (voice conversation loop → voice_backend.spawnStreamingConvo),
// so the unguarded version could hand a worker a torn Status snapshot.
var check_mutex: @import("sync.zig").Mutex = .{};
var check_cache: Status = .{};
var check_cache_ms: i64 = 0;

pub fn check() Status {
    check_mutex.lock();
    defer check_mutex.unlock();
    const now = io_global.milliTimestamp();
    if (check_cache_ms != 0 and now - check_cache_ms < 1000) return check_cache;
    check_cache = realCheck();
    check_cache_ms = now;
    return check_cache;
}

fn realCheck() Status {
    var s: Status = .{};

    s.apfel = have("/opt/homebrew/bin/apfel") or have("/usr/local/bin/apfel");
    s.ffmpeg = have("/opt/homebrew/bin/ffmpeg") or have("/usr/local/bin/ffmpeg") or have("/usr/bin/ffmpeg");
    s.whisper = have("/opt/homebrew/bin/whisper-cpp") or
        have("/opt/homebrew/bin/whisper-cli") or
        have("bin/whisper.cpp/build/bin/whisper-cli");

    s.sherpa_onnx = have("/opt/homebrew/bin/sherpa-onnx-offline") or
        have("/usr/local/bin/sherpa-onnx-offline");

    // Model status means runnable, not merely "one file exists". This also
    // makes interrupted legacy installs show a repairable Download action.
    var __cfg_buf_0: [512]u8 = undefined;
    const home2 = @import("paths.zig").configDir(&__cfg_buf_0);
    s.sherpa_model = installedModelReady(home2, "sherpa-whisper-tiny", &.{ "tiny-encoder.onnx", "tiny-decoder.onnx", "tiny-tokens.txt" });
    s.sherpa_tts_model = installedModelReady(home2, "sherpa-vits-piper", &.{ "en_US-lessac-medium.onnx", "lexicon.txt", "tokens.txt", "espeak-ng-data" });
    s.sherpa_stream_model = installedModelReady(home2, "sherpa-stream-zipformer", &.{ "encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt" });
    s.sherpa_kokoro_model = installedModelReady(home2, "sherpa-kokoro", &.{ "model.onnx", "voices.bin", "tokens.txt", "espeak-ng-data" });
    const parakeet_files = &.{ "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt" };
    s.parakeet_v2_model = installedModelReady(home2, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8", parakeet_files);
    s.parakeet_v3_model = installedModelReady(home2, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", parakeet_files);
    s.sherpa_mic_cli = have("/opt/homebrew/bin/sherpa-onnx-microphone") or
        have("/usr/local/bin/sherpa-onnx-microphone");

    var home_buf: [512]u8 = undefined;
    var __cfg_buf_1: [512]u8 = undefined;
    const home = @import("paths.zig").configDir(&__cfg_buf_1);
    if (std.fmt.bufPrintZ(&home_buf, "{s}/models/ggml-tiny.en.bin", .{home})) |model_path| {
        // Avoid hashing 75 MiB on every settings-frame TTL refresh; exact byte
        // length catches interrupted legacy downloads. Fresh installs are also
        // SHA-256 verified before publication below.
        s.whisper_model = downloadedFileMatches(model_path, 77_704_715, null);
    } else |_| {}

    // MLX Whisper (Apple Silicon only — harmless no-op on other platforms)
    s.mlx_whisper_cli = have("/opt/homebrew/bin/mlx_whisper") or
        have("/usr/local/bin/mlx_whisper");

    // Check HuggingFace cache for MLX Whisper model
    // Cache layout: ~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo/
    s.mlx_whisper_model = mlxWhisperModelCached(home2);

    return s;
}

fn have(path: []const u8) bool {
    io_global.cwdAccess(path, .{}) catch return false;
    return true;
}

fn processSucceeded(term: io_global.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn removeChildTree(parent_path: []const u8, child_name: []const u8) void {
    var dir = io_global.openDirAbsolute(parent_path, .{}) catch return;
    defer dir.close(io_global.io());
    dir.deleteTree(io_global.io(), child_name) catch {};
}

fn downloadedFileMatches(path: []const u8, expected_size: u64, expected_sha256: ?[]const u8) bool {
    const file = io_global.openFileAbsolute(path, .{}) catch return false;
    defer file.close(io_global.io());
    if ((file.length(io_global.io()) catch return false) != expected_size) return false;
    const expected = expected_sha256 orelse return true;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = io_global.read(file, &buf) catch return false;
        if (n == 0) break;
        hash.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &actual, expected);
}

/// Fetch into a disposable sibling file and validate it before any live model
/// path is touched. GitHub's older ASR assets do not publish hashes, so those
/// are pinned to their release-API byte length; newer assets also pin SHA-256.
fn downloadVerified(url: []const u8, stage_path: []const u8, expected_size: u64, expected_sha256: ?[]const u8) bool {
    var cmd_buf: [512]u8 = undefined;
    logs.pushLog("info", "deps", std.fmt.bufPrint(&cmd_buf, "Command: curl -L --fail --proto =https --proto-redir =https -o <staged model> {s}", .{url}) catch "Downloading verified model via HTTPS", false);
    io_global.deleteFileAbsolute(stage_path) catch {};
    var curl = io_global.Child.init(&.{
        "curl",         "-L",                "--fail", "--silent",
        "--show-error", "--proto",           "=https", "--proto-redir",
        "=https",       "--connect-timeout", "15",     "--retry",
        "2",            "--retry-delay",     "1",      "-o",
        stage_path,     url,
    }, @import("alloc.zig").allocator);
    curl.stdout_behavior = .Ignore;
    curl.stderr_behavior = .Ignore;
    const term = curl.spawnAndWait() catch return false;
    return processSucceeded(term) and downloadedFileMatches(stage_path, expected_size, expected_sha256);
}

fn renameStagedFile(dir_path: []const u8, preferred: []const u8, fallback: ?[]const u8, canonical: []const u8) bool {
    var src_buf: [1024]u8 = undefined;
    var dst_buf: [1024]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dir_path, canonical }) catch return false;
    io_global.deleteFileAbsolute(dst) catch {};

    const first = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ dir_path, preferred }) catch return false;
    if (io_global.renameAbsolute(first, dst)) |_| return true else |_| {}
    const alternate = fallback orelse return false;
    const second = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ dir_path, alternate }) catch return false;
    io_global.renameAbsolute(second, dst) catch return false;
    return true;
}

const ModelLayout = enum { direct, whisper, stream };

const ArchiveModel = struct {
    url: []const u8,
    archive_name: []const u8,
    source_dir: []const u8,
    target_dir: []const u8,
    required_files: []const []const u8,
    expected_size: u64,
    expected_sha256: ?[]const u8 = null,
    layout: ModelLayout = .direct,
};

fn modelFilesReady(model_path: []const u8, required_files: []const []const u8) bool {
    for (required_files) |name| {
        var path_buf: [1100]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ model_path, name }) catch return false;
        if (!have(path)) return false;
    }
    return required_files.len != 0;
}

fn installedModelReady(config_dir: []const u8, model_dir: []const u8, required_files: []const []const u8) bool {
    var path_buf: [1024]u8 = undefined;
    const model_path = std.fmt.bufPrint(&path_buf, "{s}/models/{s}", .{ config_dir, model_dir }) catch return false;
    return modelFilesReady(model_path, required_files);
}

fn canonicalizeModel(layout: ModelLayout, source_path: []const u8) bool {
    return switch (layout) {
        .direct => true,
        .whisper => renameStagedFile(source_path, "tiny.en-encoder.int8.onnx", "tiny.en-encoder.onnx", "tiny-encoder.onnx") and
            renameStagedFile(source_path, "tiny.en-decoder.int8.onnx", "tiny.en-decoder.onnx", "tiny-decoder.onnx") and
            renameStagedFile(source_path, "tiny.en-tokens.txt", null, "tiny-tokens.txt"),
        .stream => renameStagedFile(source_path, "encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx", "encoder-epoch-99-avg-1-chunk-16-left-128.onnx", "encoder.onnx") and
            renameStagedFile(source_path, "decoder-epoch-99-avg-1-chunk-16-left-128.onnx", "decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx", "decoder.onnx") and
            renameStagedFile(source_path, "joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx", "joiner-epoch-99-avg-1-chunk-16-left-128.onnx", "joiner.onnx"),
    };
}

/// Install a compressed model transactionally: verified archive -> isolated
/// extraction directory -> layout validation -> same-volume atomic publish.
fn installArchiveModel(spec: ArchiveModel) bool {
    var cfg_buf: [512]u8 = undefined;
    const config_dir = @import("paths.zig").configDir(&cfg_buf);
    var models_buf: [640]u8 = undefined;
    const models_dir = std.fmt.bufPrint(&models_buf, "{s}/models", .{config_dir}) catch return false;
    io_global.makeDirAbsolute(models_dir) catch {};

    var target_buf: [1024]u8 = undefined;
    const target_path = std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ models_dir, spec.target_dir }) catch return false;
    if (modelFilesReady(target_path, spec.required_files)) return true;

    var archive_buf: [1024]u8 = undefined;
    const archive_path = std.fmt.bufPrint(&archive_buf, "{s}/.{s}.part", .{ models_dir, spec.archive_name }) catch return false;
    defer io_global.deleteFileAbsolute(archive_path) catch {};
    if (!downloadVerified(spec.url, archive_path, spec.expected_size, spec.expected_sha256)) return false;

    var stage_name_buf: [256]u8 = undefined;
    const stage_name = std.fmt.bufPrint(&stage_name_buf, ".opal-model-stage-{s}", .{spec.archive_name}) catch return false;
    removeChildTree(models_dir, stage_name);
    defer removeChildTree(models_dir, stage_name);
    var stage_buf: [768]u8 = undefined;
    const stage_path = std.fmt.bufPrint(&stage_buf, "{s}/{s}", .{ models_dir, stage_name }) catch return false;
    io_global.makeDirAbsolute(stage_path) catch return false;

    logs.pushLog("info", "deps", "Command: tar -xjf <verified model archive> -C <staging dir>", false);
    var untar = io_global.Child.init(&.{ "tar", "-xjf", archive_path, "-C", stage_path }, @import("alloc.zig").allocator);
    untar.stdout_behavior = .Ignore;
    untar.stderr_behavior = .Ignore;
    const term = untar.spawnAndWait() catch return false;
    if (!processSucceeded(term)) return false;

    var source_buf: [1024]u8 = undefined;
    const source_path = std.fmt.bufPrint(&source_buf, "{s}/{s}", .{ stage_path, spec.source_dir }) catch return false;
    if (!canonicalizeModel(spec.layout, source_path)) return false;
    if (!modelFilesReady(source_path, spec.required_files)) return false;

    // A previously interrupted legacy installer may have left an incomplete
    // destination. It is replaced only after the new bundle is fully verified.
    removeChildTree(models_dir, spec.target_dir);
    io_global.renameAbsolute(source_path, target_path) catch return false;
    return modelFilesReady(target_path, spec.required_files);
}

/// One-liner brew install command for missing deps. Copy-paste ready.
pub fn installCmd(buf: []u8, s: Status) []const u8 {
    var parts: [8][]const u8 = undefined;
    var n: usize = 0;
    if (!s.apfel) {
        if (n < parts.len) {
            parts[n] = "apfel";
            n += 1;
        }
    }
    if (!s.ffmpeg) {
        if (n < parts.len) {
            parts[n] = "ffmpeg";
            n += 1;
        }
    }
    if (!s.whisper) {
        if (n < parts.len) {
            parts[n] = "whisper-cpp";
            n += 1;
        }
    }
    if (n == 0) return "";

    var off: usize = 0;
    const prefix = "brew install ";
    @memcpy(buf[off .. off + prefix.len], prefix);
    off += prefix.len;
    for (parts[0..n], 0..) |p, i| {
        if (i > 0) {
            buf[off] = ' ';
            off += 1;
        }
        @memcpy(buf[off .. off + p.len], p);
        off += p.len;
    }
    return buf[0..off];
}

/// Download whisper tiny model to ~/.config/opal/models/ on a background
/// thread. Idempotent — no-op if present.
/// Fetch + extract the sherpa-onnx whisper-tiny bundle
/// (tokens + encoder + decoder) to ~/.config/opal/models/sherpa-whisper-tiny/.
/// ~113 MiB compressed. Runs on a background thread. Idempotent.
pub var sherpa_model_downloading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ── NVIDIA Parakeet TDT (sherpa-onnx int8 exports) ──
// URLs + file names verified against the k2-fsa release assets (2026-07-02).
// No sherpa export of the 1.1b exists — 0.6b v2/v3 are the largest (and
// newest) Parakeet TDT models runnable through sherpa-onnx-offline.
pub var parakeet_v2_downloading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var parakeet_v3_downloading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Download + extract a Parakeet TDT bundle synchronously (caller owns the
/// thread — voice_setup's installer runs it inline for sequenced progress).
/// Idempotent: returns true immediately when the model is already on disk.
pub fn fetchParakeetBlocking(is_v3: bool) bool {
    const dir_name = if (is_v3)
        "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
    else
        "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8";
    const url = if (is_v3)
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
    else
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2";

    logs.pushLog("info", "deps", if (is_v3) "Fetching Parakeet TDT 0.6B v3 (~490MB)…" else "Fetching Parakeet TDT 0.6B v2 (~480MB)…", false);
    const ok = installArchiveModel(.{
        .url = url,
        .archive_name = if (is_v3) "parakeet-v3.tar.bz2" else "parakeet-v2.tar.bz2",
        .source_dir = dir_name,
        .target_dir = dir_name,
        .required_files = &.{ "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt" },
        .expected_size = if (is_v3) 487_170_055 else 482_468_385,
        .expected_sha256 = if (is_v3)
            "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"
        else
            "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad",
    });
    if (ok) {
        logs.pushLog("info", "deps", "Parakeet TDT model ready", false);
        return true;
    }
    logs.pushLog("error", "deps", "Parakeet download/extract failed — see network and disk space", true);
    return false;
}

pub fn fetchParakeetAsync(v3: bool) void {
    const flag = if (v3) &parakeet_v3_downloading else &parakeet_v2_downloading;
    if (flag.swap(true, .acq_rel)) return; // already running
    const S = struct {
        fn worker(is_v3: bool) void {
            const f = if (is_v3) &parakeet_v3_downloading else &parakeet_v2_downloading;
            defer f.store(false, .release);
            _ = fetchParakeetBlocking(is_v3);
        }
    };
    if (@import("workers.zig").spawnLegacy(S.worker, .{v3})) |t| @import("workers.zig").release(t) else |_| {
        flag.store(false, .release);
    }
}

pub fn fetchSherpaWhisperAsync() void {
    if (sherpa_model_downloading.swap(true, .acq_rel)) return;
    const S = struct {
        fn worker() void {
            logs.pushLog("info", "deps", "Fetching sherpa whisper-tiny (~113MB)…", true);
            defer sherpa_model_downloading.store(false, .release);
            if (installArchiveModel(.{
                .url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2",
                .archive_name = "sherpa-whisper-tiny.tar.bz2",
                .source_dir = "sherpa-onnx-whisper-tiny.en",
                .target_dir = "sherpa-whisper-tiny",
                .required_files = &.{ "tiny-encoder.onnx", "tiny-decoder.onnx", "tiny-tokens.txt" },
                .expected_size = 118_071_777,
                .layout = .whisper,
            })) {
                logs.pushLog("info", "deps", "Sherpa whisper-tiny ready", true);
            } else {
                logs.pushLog("error", "deps", "Sherpa whisper download failed validation; no model was installed", true);
            }
        }
    };
    if (@import("workers.zig").spawnLegacy(S.worker, .{})) |t| @import("workers.zig").release(t) else |_| {
        sherpa_model_downloading.store(false, .release);
    }
}

/// Fetch + extract Piper VITS en_US-lessac-medium TTS bundle
/// (~64MB) to ~/.config/opal/models/sherpa-vits-piper/.
pub var sherpa_tts_downloading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn fetchSherpaTtsAsync() void {
    if (sherpa_tts_downloading.swap(true, .acq_rel)) return;
    const S = struct {
        fn worker() void {
            logs.pushLog("info", "deps", "Fetching sherpa Piper-VITS (~64MB)…", true);
            defer sherpa_tts_downloading.store(false, .release);
            if (installArchiveModel(.{
                .url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2",
                .archive_name = "sherpa-vits-piper.tar.bz2",
                .source_dir = "vits-piper-en_US-lessac-medium",
                .target_dir = "sherpa-vits-piper",
                .required_files = &.{ "en_US-lessac-medium.onnx", "lexicon.txt", "tokens.txt", "espeak-ng-data" },
                .expected_size = 67_230_653,
                .expected_sha256 = "9e3febfacf0abf4270172d2958bcec246032b7e88efc2720840cc80c93de334e",
            })) {
                logs.pushLog("info", "deps", "Sherpa TTS model ready", true);
            } else {
                logs.pushLog("error", "deps", "Piper model download failed validation; no model was installed", true);
            }
        }
    };
    if (@import("workers.zig").spawnLegacy(S.worker, .{})) |t| @import("workers.zig").release(t) else |_| {
        sherpa_tts_downloading.store(false, .release);
    }
}

/// Fetch Kokoro multi-voice TTS bundle (~305MB) for highest-quality
/// synthesis. Has 53+ English speakers selectable via --sid. Opt-in —
/// Piper stays the default because of size.
pub var sherpa_kokoro_downloading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn fetchSherpaKokoroAsync() void {
    if (sherpa_kokoro_downloading.swap(true, .acq_rel)) return;
    const S = struct {
        fn worker() void {
            logs.pushLog("info", "deps", "Fetching Kokoro TTS (~305MB)…", true);
            defer sherpa_kokoro_downloading.store(false, .release);
            if (installArchiveModel(.{
                .url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2",
                .archive_name = "sherpa-kokoro.tar.bz2",
                .source_dir = "kokoro-en-v0_19",
                .target_dir = "sherpa-kokoro",
                .required_files = &.{ "model.onnx", "voices.bin", "tokens.txt", "espeak-ng-data" },
                .expected_size = 319_625_534,
                .expected_sha256 = "912804855a04745fa77a30be545b3f9a5d15c4d66db00b88cbcd4921df605ac7",
            })) {
                logs.pushLog("info", "deps", "Kokoro model ready (53+ voices)", true);
            } else {
                logs.pushLog("error", "deps", "Kokoro model download failed validation; no model was installed", true);
            }
        }
    };
    if (@import("workers.zig").spawnLegacy(S.worker, .{})) |t| @import("workers.zig").release(t) else |_| {
        sherpa_kokoro_downloading.store(false, .release);
    }
}

/// Fetch sherpa streaming Zipformer bundle (~296MB) for live-convo
/// (VAD-driven real-time transcription, replaces the fixed 15s record).
pub var sherpa_stream_downloading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn fetchSherpaStreamAsync() void {
    if (sherpa_stream_downloading.swap(true, .acq_rel)) return;
    const S = struct {
        fn worker() void {
            logs.pushLog("info", "deps", "Fetching streaming Zipformer (~296MB)…", true);
            defer sherpa_stream_downloading.store(false, .release);
            if (installArchiveModel(.{
                .url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2",
                .archive_name = "sherpa-stream-zipformer.tar.bz2",
                .source_dir = "sherpa-onnx-streaming-zipformer-en-2023-06-26",
                .target_dir = "sherpa-stream-zipformer",
                .required_files = &.{ "encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt" },
                .expected_size = 310_414_022,
                .layout = .stream,
            })) {
                logs.pushLog("info", "deps", "Streaming Zipformer model ready", true);
            } else {
                logs.pushLog("error", "deps", "Streaming model download failed validation; no model was installed", true);
            }
        }
    };
    if (@import("workers.zig").spawnLegacy(S.worker, .{})) |t| @import("workers.zig").release(t) else |_| {
        sherpa_stream_downloading.store(false, .release);
    }
}

/// True while the whisper-tiny model download worker is running. The settings
/// model row used to show the SHERPA flag here, so whisper-tiny downloads
/// displayed "Not installed" and sherpa downloads lit up BOTH rows.
pub var whisper_model_downloading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn fetchWhisperModelAsync() void {
    const S = struct {
        fn worker() void {
            defer whisper_model_downloading.store(false, .release);
            var home_buf: [512]u8 = undefined;
            var __cfg_buf_7: [512]u8 = undefined;
            const home = @import("paths.zig").configDir(&__cfg_buf_7);
            const dir = std.fmt.bufPrintZ(&home_buf, "{s}/models", .{home}) catch return;

            // mkpath + check if already present
            io_global.makeDirAbsolute(dir) catch {};
            var path_buf: [512]u8 = undefined;
            const model_path = std.fmt.bufPrintZ(&path_buf, "{s}/ggml-tiny.en.bin", .{dir}) catch return;
            if (downloadedFileMatches(model_path, 77_704_715, null)) return;

            logs.pushLog("info", "deps", "Fetching Whisper tiny.en (75MB)…", false);
            var stage_buf: [544]u8 = undefined;
            const stage_path = std.fmt.bufPrint(&stage_buf, "{s}.part", .{model_path}) catch return;
            defer io_global.deleteFileAbsolute(stage_path) catch {};
            if (downloadVerified(
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
                stage_path,
                77_704_715,
                "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
            )) {
                // Only an invalid legacy file can exist here; the verified
                // staged model remains isolated until the final rename.
                io_global.deleteFileAbsolute(model_path) catch {};
                io_global.renameAbsolute(stage_path, model_path) catch {
                    logs.pushLog("error", "deps", "Could not publish verified Whisper model", true);
                    return;
                };
                logs.pushLog("info", "deps", "Whisper model ready", false);
            } else {
                logs.pushLog("error", "deps", "Whisper download failed validation; no model was installed", true);
            }
        }
    };
    if (whisper_model_downloading.swap(true, .acq_rel)) return; // already running
    if (@import("workers.zig").spawnLegacy(S.worker, .{})) |t| @import("workers.zig").release(t) else |_| {
        whisper_model_downloading.store(false, .release);
    }
}

// ══════════════════════════════════════════════════════════
// MLX Whisper model management
// ══════════════════════════════════════════════════════════

const MLX_WHISPER_HF_REPO = "mlx-community/whisper-large-v3-turbo";
const MLX_WHISPER_CACHE_DIR = "models--mlx-community--whisper-large-v3-turbo";

/// Scan HuggingFace cache for the MLX Whisper model.
/// Returns true if the model weights exist in any snapshot.
fn mlxWhisperModelCached(home: []const u8) bool {
    // HF cache: ~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo/snapshots/*/weights.safetensors
    // Also check XDG override: $HF_HOME/hub/ or $HF_HUB_CACHE/
    var cache_buf: [512]u8 = undefined;
    const cache_base = if (std.c.getenv("HF_HUB_CACHE")) |c|
        std.mem.span(c)
    else if (std.c.getenv("HF_HOME")) |h| blk: {
        break :blk std.fmt.bufPrintZ(&cache_buf, "{s}/hub", .{std.mem.span(h)}) catch home;
    } else blk: {
        break :blk std.fmt.bufPrintZ(&cache_buf, "{s}/.cache/huggingface/hub", .{home}) catch home;
    };

    // Check for snapshots dir
    var snap_buf: [512]u8 = undefined;
    const snap_dir = std.fmt.bufPrintZ(&snap_buf, "{s}/{s}/snapshots", .{ cache_base, MLX_WHISPER_CACHE_DIR }) catch return false;

    // Open snapshots dir and iterate to find any hash dir with weights.safetensors
    var dir = io_global.openDirAbsolute(snap_dir, .{ .iterate = true }) catch return false;
    defer dir.close(io_global.io());

    var iter = dir.iterate();
    while (iter.next(io_global.io()) catch null) |entry| {
        if (entry.kind != .directory) continue;
        // Check for weights.safetensors inside this snapshot
        var weights_buf: [768]u8 = undefined;
        const weights_path = std.fmt.bufPrintZ(&weights_buf, "{s}/{s}/weights.safetensors", .{ snap_dir, entry.name }) catch continue;
        if (io_global.cwdAccess(weights_path, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Download MLX Whisper model AND install the mlx-whisper package
/// using `uv` (astral.sh) — never touches the user's system Python.
/// Flow: ensure uv → uv venv → uv pip install → huggingface-cli download.
pub var mlx_whisper_downloading: bool = false;
pub var mlx_whisper_status: [128]u8 = [_]u8{0} ** 128;
pub var mlx_whisper_step: u8 = 0; // 0=idle, 1=uv, 2=venv, 3=pip, 4=model, 5=done

fn setStatus(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrintZ(&mlx_whisper_status, fmt, args) catch return;
    _ = s;
}

/// Path to the managed mlx-whisper binary inside our uv venv.
/// Returns null if not installed yet.
pub fn mlxWhisperBinPath(buf: []u8) ?[]const u8 {
    var __cfg_buf_8: [512]u8 = undefined;
    const home = @import("paths.zig").configDir(&__cfg_buf_8);
    // Check managed venv first
    const venv_bin = std.fmt.bufPrintZ(buf, "{s}/mlx-venv/bin/mlx_whisper", .{home}) catch return null;
    if (io_global.cwdAccess(venv_bin, .{})) |_| return venv_bin else |_| {}
    // Check system-wide
    if (io_global.cwdAccess("/opt/homebrew/bin/mlx_whisper", .{})) |_| return "/opt/homebrew/bin/mlx_whisper" else |_| {}
    if (io_global.cwdAccess("/usr/local/bin/mlx_whisper", .{})) |_| return "/usr/local/bin/mlx_whisper" else |_| {}
    return null;
}

/// Find the uv binary. Checks common install locations.
fn findUv(buf: []u8) ?[]const u8 {
    const home = @import("paths.zig").homeDir();
    // uv official installer puts it here
    const cargo_uv = std.fmt.bufPrintZ(buf, "{s}/.local/bin/uv", .{home}) catch return null;
    if (io_global.cwdAccess(cargo_uv, .{})) |_| return cargo_uv else |_| {}
    // Homebrew / system
    if (io_global.cwdAccess("/opt/homebrew/bin/uv", .{})) |_| return "/opt/homebrew/bin/uv" else |_| {}
    if (io_global.cwdAccess("/usr/local/bin/uv", .{})) |_| return "/usr/local/bin/uv" else |_| {}
    return null;
}

pub fn fetchMlxWhisperModelAsync() void {
    if (mlx_whisper_downloading) return;
    mlx_whisper_downloading = true;
    const S = struct {
        fn worker() void {
            defer mlx_whisper_downloading = false;

            const home = @import("paths.zig").homeDir();
            const alloc = @import("alloc.zig").allocator;

            // ── Step 1: Ensure `uv` is installed ──
            var uv_buf: [512]u8 = undefined;
            var uv_bin = findUv(&uv_buf);

            if (uv_bin == null) {
                mlx_whisper_step = 1;
                setStatus("Installing uv…", .{});
                logs.pushLog("info", "deps", "Installing uv (Python package manager)…", true);
                logs.pushLog("info", "deps", "Command: sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'", false);
                // Official installer: curl -LsSf https://astral.sh/uv/install.sh | sh
                var uv_install = io_global.Child.init(&.{
                    "sh", "-c", "curl -LsSf https://astral.sh/uv/install.sh | sh",
                }, alloc);
                uv_install.stdout_behavior = .Ignore;
                uv_install.stderr_behavior = .Ignore;
                const uv_result = uv_install.spawnAndWait() catch {
                    logs.pushLog("error", "deps", "Failed to launch uv installer", true);
                    return;
                };
                if (!processSucceeded(uv_result)) {
                    logs.pushLog("error", "deps", "uv installer exited unsuccessfully", true);
                    return;
                }
                // Re-check after install
                uv_bin = findUv(&uv_buf);
                if (uv_bin == null) {
                    logs.pushLog("error", "deps", "uv installed but not found at ~/.local/bin/uv", true);
                    return;
                }
                logs.pushLog("info", "deps", "uv installed", true);
            }

            const uv = uv_bin.?;

            // ── Step 2: Create venv with uv (downloads its own Python) ──
            var venv_buf: [512]u8 = undefined;
            const venv_dir = std.fmt.bufPrintZ(&venv_buf, "{s}/mlx-venv", .{home}) catch return;

            var pip_check_buf: [512]u8 = undefined;
            const venv_python = std.fmt.bufPrintZ(&pip_check_buf, "{s}/bin/python", .{venv_dir}) catch return;

            if (io_global.cwdAccess(venv_python, .{})) |_| {
                // venv already exists
            } else |_| {
                mlx_whisper_step = 2;
                setStatus("Creating Python venv…", .{});
                logs.pushLog("info", "deps", "Creating isolated Python environment…", true);
                logs.pushLog("info", "deps", "Command: uv venv <mlx-venv> --python 3.12", false);
                var venv_create = io_global.Child.init(&.{
                    uv, "venv", venv_dir, "--python", "3.12",
                }, alloc);
                venv_create.stdout_behavior = .Ignore;
                venv_create.stderr_behavior = .Ignore;
                const venv_result = venv_create.spawnAndWait() catch {
                    logs.pushLog("error", "deps", "uv venv creation failed to launch", true);
                    return;
                };
                if (!processSucceeded(venv_result)) {
                    logs.pushLog("error", "deps", "uv venv creation exited unsuccessfully", true);
                    return;
                }
                logs.pushLog("info", "deps", "Python venv ready", true);
            }

            // ── Step 3: Install mlx-whisper into the venv ──
            var bin_check_buf: [512]u8 = undefined;
            if (mlxWhisperBinPath(&bin_check_buf) == null) {
                mlx_whisper_step = 3;
                setStatus("Installing mlx-whisper…", .{});
                logs.pushLog("info", "deps", "Installing mlx-whisper…", true);
                logs.pushLog("info", "deps", "Command: uv pip install mlx-whisper --python <mlx-venv>/bin/python", false);
                var pip_install = io_global.Child.init(&.{
                    uv,         "pip",       "install", "mlx-whisper",
                    "--python", venv_python,
                }, alloc);
                pip_install.stdout_behavior = .Ignore;
                pip_install.stderr_behavior = .Ignore;
                const pip_result = pip_install.spawnAndWait() catch {
                    logs.pushLog("error", "deps", "mlx-whisper install failed to launch", true);
                    return;
                };
                if (!processSucceeded(pip_result)) {
                    logs.pushLog("error", "deps", "mlx-whisper install exited unsuccessfully", true);
                    return;
                }
                logs.pushLog("info", "deps", "mlx-whisper installed", true);
            }

            // ── Step 4: Download the model ──
            if (mlxWhisperModelCached(home)) {
                logs.pushLog("info", "deps", "MLX Whisper model already cached", true);
                return;
            }

            mlx_whisper_step = 4;
            setStatus("Downloading model (~1.6GB)…", .{});
            logs.pushLog("info", "deps", "Downloading MLX Whisper large-v3-turbo (~1.6GB)…", true);

            // Use the venv's huggingface-cli (installed as mlx-whisper dependency)
            var hf_cli_buf: [512]u8 = undefined;
            const venv_hf = std.fmt.bufPrintZ(&hf_cli_buf, "{s}/bin/huggingface-cli", .{venv_dir}) catch return;
            logs.pushLog("info", "deps", "Command: huggingface-cli download mlx-community/whisper-large-v3-turbo", false);

            var hf_cli = io_global.Child.init(&.{
                venv_hf, "download", MLX_WHISPER_HF_REPO,
            }, alloc);
            hf_cli.stdout_behavior = .Ignore;
            hf_cli.stderr_behavior = .Ignore;
            if (hf_cli.spawnAndWait()) |_| {
                if (mlxWhisperModelCached(home)) {
                    logs.pushLog("info", "deps", "MLX Whisper model ready", true);
                    return;
                }
            } else |_| {}

            logs.pushLog("info", "deps", "Fallback: curl -L --fail config.json and weights.safetensors from Hugging Face", false);
            // Fallback: direct curl download
            var model_dir_buf: [512]u8 = undefined;
            const model_dir = std.fmt.bufPrintZ(&model_dir_buf, "{s}/.cache/huggingface/hub/{s}/snapshots/main", .{ home, MLX_WHISPER_CACHE_DIR }) catch return;
            var mkp = io_global.Child.init(&.{ "mkdir", "-p", model_dir }, alloc);
            mkp.stdout_behavior = .Ignore;
            mkp.stderr_behavior = .Ignore;
            _ = mkp.spawnAndWait() catch {};

            // config.json
            var cfg_buf: [768]u8 = undefined;
            const cfg_path = std.fmt.bufPrintZ(&cfg_buf, "{s}/config.json", .{model_dir}) catch return;
            var cfg_dl = io_global.Child.init(&.{
                "curl",                                                                                 "-L", "--fail", "--silent", "--show-error", "-o", cfg_path,
                "https://huggingface.co/mlx-community/whisper-large-v3-turbo/resolve/main/config.json",
            }, alloc);
            cfg_dl.stdout_behavior = .Ignore;
            cfg_dl.stderr_behavior = .Ignore;
            const cfg_result = cfg_dl.spawnAndWait() catch {
                logs.pushLog("error", "deps", "Failed to download MLX Whisper config", true);
                return;
            };
            if (!processSucceeded(cfg_result)) {
                logs.pushLog("error", "deps", "MLX Whisper config download exited unsuccessfully", true);
                return;
            }

            // weights.safetensors (~1.6GB)
            var wt_buf: [768]u8 = undefined;
            const wt_path = std.fmt.bufPrintZ(&wt_buf, "{s}/weights.safetensors", .{model_dir}) catch return;
            var wt_dl = io_global.Child.init(&.{
                "curl",                                                                                         "-L", "--fail", "--show-error", "-o", wt_path,
                "https://huggingface.co/mlx-community/whisper-large-v3-turbo/resolve/main/weights.safetensors",
            }, alloc);
            wt_dl.stdout_behavior = .Ignore;
            wt_dl.stderr_behavior = .Ignore;
            const weights_result = wt_dl.spawnAndWait() catch {
                logs.pushLog("error", "deps", "Failed to download MLX Whisper weights", true);
                return;
            };
            if (!processSucceeded(weights_result) or !mlxWhisperModelCached(home)) {
                logs.pushLog("error", "deps", "MLX Whisper weights download failed validation", true);
                return;
            }

            mlx_whisper_step = 5;
            setStatus("Ready", .{});
            logs.pushLog("info", "deps", "MLX Whisper model ready", true);
        }
    };
    if (@import("workers.zig").spawnLegacy(S.worker, .{})) |t| @import("workers.zig").release(t) else |_| {
        mlx_whisper_downloading = false;
    }
}
