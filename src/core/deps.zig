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

    // sherpa STT + TTS models — probe a canonical file per bundle.
    var sherpa_home_buf: [512]u8 = undefined;
    const home2 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
    if (std.fmt.bufPrintZ(&sherpa_home_buf, "{s}/.config/opal/models/sherpa-whisper-tiny/tiny-tokens.txt", .{home2})) |p| {
        s.sherpa_model = have(p);
    } else |_| {}
    var sherpa_tts_buf: [512]u8 = undefined;
    if (std.fmt.bufPrintZ(&sherpa_tts_buf, "{s}/.config/opal/models/sherpa-vits-piper/en_US-lessac-medium.onnx", .{home2})) |p| {
        s.sherpa_tts_model = have(p);
    } else |_| {}
    var sherpa_stream_buf: [512]u8 = undefined;
    if (std.fmt.bufPrintZ(&sherpa_stream_buf, "{s}/.config/opal/models/sherpa-stream-zipformer/encoder.onnx", .{home2})) |p| {
        s.sherpa_stream_model = have(p);
    } else |_| {}
    var sherpa_kokoro_buf: [512]u8 = undefined;
    if (std.fmt.bufPrintZ(&sherpa_kokoro_buf, "{s}/.config/opal/models/sherpa-kokoro/model.onnx", .{home2})) |p| {
        s.sherpa_kokoro_model = have(p);
    } else |_| {}
    s.sherpa_mic_cli = have("/opt/homebrew/bin/sherpa-onnx-microphone") or
        have("/usr/local/bin/sherpa-onnx-microphone");

    var home_buf: [512]u8 = undefined;
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
    if (std.fmt.bufPrintZ(&home_buf, "{s}/.config/opal/models/ggml-tiny.en.bin", .{home})) |model_path| {
        s.whisper_model = have(model_path);
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
/// ~40 MB compressed. Runs on a background thread. Idempotent.
pub var sherpa_model_downloading: bool = false;

pub fn fetchSherpaWhisperAsync() void {
    if (sherpa_model_downloading) return;
    sherpa_model_downloading = true;
    const S = struct {
        fn worker() void {
            defer sherpa_model_downloading = false;
            var home_buf: [512]u8 = undefined;
            const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return;
            const models_dir = std.fmt.bufPrintZ(&home_buf, "{s}/.config/opal/models", .{home}) catch return;
            io_global.makeDirAbsolute(models_dir) catch {};

            var tar_buf: [512]u8 = undefined;
            const tar_path = std.fmt.bufPrintZ(&tar_buf, "{s}/sherpa-whisper-tiny.tar.bz2", .{models_dir}) catch return;

            // If model already extracted, no-op.
            var check_buf: [512]u8 = undefined;
            const check_path = std.fmt.bufPrintZ(&check_buf, "{s}/sherpa-whisper-tiny/tiny-encoder.onnx", .{models_dir}) catch return;
            if (io_global.cwdAccess(check_path, .{})) |_| return else |_| {}

            logs.pushLog("info", "deps", "Fetching sherpa whisper-tiny (~40MB)…", true);
            var curl = io_global.Child.init(&.{
                "curl", "-L",     "--fail",                                                                                                 "--silent", "--show-error",
                "-o",   tar_path, "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2",
            }, @import("alloc.zig").allocator);
            curl.stdout_behavior = .Ignore;
            curl.stderr_behavior = .Ignore;
            curl.spawn() catch {
                logs.pushLog("error", "deps", "curl missing — can't fetch sherpa model", false);
                return;
            };
            _ = curl.wait() catch {};

            // Extract via tar -xjf (bzip2) into models/. The archive
            // unpacks to sherpa-onnx-whisper-tiny.en/ — we rename for
            // a shorter stable path.
            var untar = io_global.Child.init(&.{
                "tar", "-xjf", tar_path, "-C", models_dir,
            }, @import("alloc.zig").allocator);
            untar.stdout_behavior = .Ignore;
            untar.stderr_behavior = .Ignore;
            _ = untar.spawnAndWait() catch {};

            var src_buf: [512]u8 = undefined;
            const src = std.fmt.bufPrintZ(&src_buf, "{s}/sherpa-onnx-whisper-tiny.en", .{models_dir}) catch return;
            var dst_buf: [512]u8 = undefined;
            const dst = std.fmt.bufPrintZ(&dst_buf, "{s}/sherpa-whisper-tiny", .{models_dir}) catch return;
            var mv = io_global.Child.init(&.{ "mv", "-f", src, dst }, @import("alloc.zig").allocator);
            mv.stdout_behavior = .Ignore;
            mv.stderr_behavior = .Ignore;
            _ = mv.spawnAndWait() catch {};

            io_global.deleteFileAbsolute(tar_path) catch {};
            logs.pushLog("info", "deps", "Sherpa whisper-tiny ready", true);
        }
    };
    if (std.Thread.spawn(.{}, S.worker, .{})) |t| t.detach() else |_| {
        sherpa_model_downloading = false;
    }
}

/// Fetch + extract Piper VITS en_US-lessac-medium TTS bundle
/// (~40MB) to ~/.config/opal/models/sherpa-vits-piper/.
pub var sherpa_tts_downloading: bool = false;

pub fn fetchSherpaTtsAsync() void {
    if (sherpa_tts_downloading) return;
    sherpa_tts_downloading = true;
    const S = struct {
        fn worker() void {
            defer sherpa_tts_downloading = false;
            var home_buf: [512]u8 = undefined;
            const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return;
            const models_dir = std.fmt.bufPrintZ(&home_buf, "{s}/.config/opal/models", .{home}) catch return;
            io_global.makeDirAbsolute(models_dir) catch {};

            var tar_buf: [512]u8 = undefined;
            const tar_path = std.fmt.bufPrintZ(&tar_buf, "{s}/sherpa-vits-piper.tar.bz2", .{models_dir}) catch return;

            var check_buf: [512]u8 = undefined;
            const check_path = std.fmt.bufPrintZ(&check_buf, "{s}/sherpa-vits-piper/en_US-lessac-medium.onnx", .{models_dir}) catch return;
            if (io_global.cwdAccess(check_path, .{})) |_| return else |_| {}

            logs.pushLog("info", "deps", "Fetching sherpa Piper-VITS (~40MB)…", true);
            var curl = io_global.Child.init(&.{
                "curl", "-L",     "--fail",                                                                                                    "--silent", "--show-error",
                "-o",   tar_path, "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2",
            }, @import("alloc.zig").allocator);
            curl.stdout_behavior = .Ignore;
            curl.stderr_behavior = .Ignore;
            curl.spawn() catch {
                logs.pushLog("error", "deps", "curl missing — can't fetch TTS model", false);
                return;
            };
            _ = curl.wait() catch {};

            var untar = io_global.Child.init(&.{
                "tar", "-xjf", tar_path, "-C", models_dir,
            }, @import("alloc.zig").allocator);
            untar.stdout_behavior = .Ignore;
            untar.stderr_behavior = .Ignore;
            _ = untar.spawnAndWait() catch {};

            var src_buf: [512]u8 = undefined;
            const src = std.fmt.bufPrintZ(&src_buf, "{s}/vits-piper-en_US-lessac-medium", .{models_dir}) catch return;
            var dst_buf: [512]u8 = undefined;
            const dst = std.fmt.bufPrintZ(&dst_buf, "{s}/sherpa-vits-piper", .{models_dir}) catch return;
            var mv = io_global.Child.init(&.{ "mv", "-f", src, dst }, @import("alloc.zig").allocator);
            mv.stdout_behavior = .Ignore;
            mv.stderr_behavior = .Ignore;
            _ = mv.spawnAndWait() catch {};

            io_global.deleteFileAbsolute(tar_path) catch {};
            logs.pushLog("info", "deps", "Sherpa TTS model ready", true);
        }
    };
    if (std.Thread.spawn(.{}, S.worker, .{})) |t| t.detach() else |_| {
        sherpa_tts_downloading = false;
    }
}

/// Fetch Kokoro multi-voice TTS bundle (~330MB) for highest-quality
/// synthesis. Has 53+ English speakers selectable via --sid. Opt-in —
/// Piper stays the default because of size.
pub var sherpa_kokoro_downloading: bool = false;

pub fn fetchSherpaKokoroAsync() void {
    if (sherpa_kokoro_downloading) return;
    sherpa_kokoro_downloading = true;
    const S = struct {
        fn worker() void {
            defer sherpa_kokoro_downloading = false;
            var home_buf: [512]u8 = undefined;
            const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return;
            const models_dir = std.fmt.bufPrintZ(&home_buf, "{s}/.config/opal/models", .{home}) catch return;
            io_global.makeDirAbsolute(models_dir) catch {};

            var tar_buf: [512]u8 = undefined;
            const tar_path = std.fmt.bufPrintZ(&tar_buf, "{s}/sherpa-kokoro.tar.bz2", .{models_dir}) catch return;

            var check_buf: [512]u8 = undefined;
            const check_path = std.fmt.bufPrintZ(&check_buf, "{s}/sherpa-kokoro/model.onnx", .{models_dir}) catch return;
            if (io_global.cwdAccess(check_path, .{})) |_| return else |_| {}

            logs.pushLog("info", "deps", "Fetching Kokoro TTS (~330MB)…", true);
            var curl = io_global.Child.init(&.{
                "curl", "-L",     "--fail",                                                                                     "--silent", "--show-error",
                "-o",   tar_path, "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2",
            }, @import("alloc.zig").allocator);
            curl.stdout_behavior = .Ignore;
            curl.stderr_behavior = .Ignore;
            curl.spawn() catch return;
            _ = curl.wait() catch {};

            var untar = io_global.Child.init(&.{
                "tar", "-xjf", tar_path, "-C", models_dir,
            }, @import("alloc.zig").allocator);
            untar.stdout_behavior = .Ignore;
            untar.stderr_behavior = .Ignore;
            _ = untar.spawnAndWait() catch {};

            var src_buf: [512]u8 = undefined;
            const src = std.fmt.bufPrintZ(&src_buf, "{s}/kokoro-en-v0_19", .{models_dir}) catch return;
            var dst_buf: [512]u8 = undefined;
            const dst = std.fmt.bufPrintZ(&dst_buf, "{s}/sherpa-kokoro", .{models_dir}) catch return;
            var mv = io_global.Child.init(&.{ "mv", "-f", src, dst }, @import("alloc.zig").allocator);
            mv.stdout_behavior = .Ignore;
            mv.stderr_behavior = .Ignore;
            _ = mv.spawnAndWait() catch {};

            io_global.deleteFileAbsolute(tar_path) catch {};
            logs.pushLog("info", "deps", "Kokoro model ready (53+ voices)", true);
        }
    };
    if (std.Thread.spawn(.{}, S.worker, .{})) |t| t.detach() else |_| {
        sherpa_kokoro_downloading = false;
    }
}

/// Fetch sherpa streaming Zipformer bundle (~80MB) for live-convo
/// (VAD-driven real-time transcription, replaces the fixed 15s record).
pub var sherpa_stream_downloading: bool = false;

pub fn fetchSherpaStreamAsync() void {
    if (sherpa_stream_downloading) return;
    sherpa_stream_downloading = true;
    const S = struct {
        fn worker() void {
            defer sherpa_stream_downloading = false;
            var home_buf: [512]u8 = undefined;
            const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return;
            const models_dir = std.fmt.bufPrintZ(&home_buf, "{s}/.config/opal/models", .{home}) catch return;
            io_global.makeDirAbsolute(models_dir) catch {};

            var tar_buf: [512]u8 = undefined;
            const tar_path = std.fmt.bufPrintZ(&tar_buf, "{s}/sherpa-stream-zipformer.tar.bz2", .{models_dir}) catch return;

            var check_buf: [512]u8 = undefined;
            const check_path = std.fmt.bufPrintZ(&check_buf, "{s}/sherpa-stream-zipformer/encoder.onnx", .{models_dir}) catch return;
            if (io_global.cwdAccess(check_path, .{})) |_| return else |_| {}

            logs.pushLog("info", "deps", "Fetching streaming Zipformer (~80MB)…", true);
            var curl = io_global.Child.init(&.{
                "curl", "-L",     "--fail",                                                                                                                   "--silent", "--show-error",
                "-o",   tar_path, "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2",
            }, @import("alloc.zig").allocator);
            curl.stdout_behavior = .Ignore;
            curl.stderr_behavior = .Ignore;
            curl.spawn() catch {
                logs.pushLog("error", "deps", "curl missing — can't fetch streaming model", false);
                return;
            };
            _ = curl.wait() catch {};

            var untar = io_global.Child.init(&.{
                "tar", "-xjf", tar_path, "-C", models_dir,
            }, @import("alloc.zig").allocator);
            untar.stdout_behavior = .Ignore;
            untar.stderr_behavior = .Ignore;
            _ = untar.spawnAndWait() catch {};

            // Upstream archive dir name is long; rename to short stable path.
            var src_buf: [512]u8 = undefined;
            const src = std.fmt.bufPrintZ(&src_buf, "{s}/sherpa-onnx-streaming-zipformer-en-2023-06-26", .{models_dir}) catch return;
            var dst_buf: [512]u8 = undefined;
            const dst = std.fmt.bufPrintZ(&dst_buf, "{s}/sherpa-stream-zipformer", .{models_dir}) catch return;
            var mv = io_global.Child.init(&.{ "mv", "-f", src, dst }, @import("alloc.zig").allocator);
            mv.stdout_behavior = .Ignore;
            mv.stderr_behavior = .Ignore;
            _ = mv.spawnAndWait() catch {};

            // The archive ships versioned, dual-precision weights
            // (encoder-epoch-…-128.onnx plus a .int8.onnx). Both deps.check()
            // and voice_backend.spawnStreamingConvo() expect canonical
            // encoder.onnx / decoder.onnx / joiner.onnx — without this mapping
            // sherpa_stream_model is permanently false and streaming never
            // activates. Prefer int8 for a small on-device footprint (~68MB),
            // fall back to fp32, then drop the unused variants.
            const canon_script =
                \\d="$1"
                \\for stem in encoder decoder joiner; do
                \\  if [ ! -f "$d/$stem.onnx" ]; then
                \\    m=$(ls "$d/$stem"-*.int8.onnx 2>/dev/null | head -1)
                \\    [ -z "$m" ] && m=$(ls "$d/$stem"-*.onnx 2>/dev/null | head -1)
                \\    [ -n "$m" ] && cp "$m" "$d/$stem.onnx"
                \\  fi
                \\done
                \\rm -f "$d"/*-epoch-*.onnx "$d"/bpe.model "$d"/*.sh "$d"/README.md
            ;
            var canon = io_global.Child.init(
                &.{ "sh", "-c", canon_script, "sh", dst },
                @import("alloc.zig").allocator,
            );
            canon.stdout_behavior = .Ignore;
            canon.stderr_behavior = .Ignore;
            _ = canon.spawnAndWait() catch {};

            io_global.deleteFileAbsolute(tar_path) catch {};
            logs.pushLog("info", "deps", "Streaming Zipformer model ready", true);
        }
    };
    if (std.Thread.spawn(.{}, S.worker, .{})) |t| t.detach() else |_| {
        sherpa_stream_downloading = false;
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
            const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return;
            const dir = std.fmt.bufPrintZ(&home_buf, "{s}/.config/opal/models", .{home}) catch return;

            // mkpath + check if already present
            io_global.makeDirAbsolute(dir) catch {};
            var path_buf: [512]u8 = undefined;
            const model_path = std.fmt.bufPrintZ(&path_buf, "{s}/ggml-tiny.en.bin", .{dir}) catch return;
            io_global.cwdAccess(model_path, .{}) catch {
                // Missing — fetch
                logs.pushLog("info", "deps", "Fetching whisper tiny model (~39MB)…", false);
                var curl = io_global.Child.init(&.{
                    "curl", "-L",       "--fail",                                                                     "--silent", "--show-error",
                    "-o",   model_path, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
                }, @import("alloc.zig").allocator);
                curl.stdout_behavior = .Ignore;
                curl.stderr_behavior = .Ignore;
                curl.spawn() catch {
                    logs.pushLog("error", "deps", "curl not found — cannot fetch whisper model", true);
                    return;
                };
                _ = curl.wait() catch {};
                logs.pushLog("info", "deps", "Whisper model ready at ~/.config/opal/models/", false);
                return;
            };
        }
    };
    if (whisper_model_downloading.swap(true, .acq_rel)) return; // already running
    if (std.Thread.spawn(.{}, S.worker, .{})) |t| t.detach() else |_| {
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
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return null;
    // Check managed venv first
    const venv_bin = std.fmt.bufPrintZ(buf, "{s}/.config/opal/mlx-venv/bin/mlx_whisper", .{home}) catch return null;
    if (io_global.cwdAccess(venv_bin, .{})) |_| return venv_bin else |_| {}
    // Check system-wide
    if (io_global.cwdAccess("/opt/homebrew/bin/mlx_whisper", .{})) |_| return "/opt/homebrew/bin/mlx_whisper" else |_| {}
    if (io_global.cwdAccess("/usr/local/bin/mlx_whisper", .{})) |_| return "/usr/local/bin/mlx_whisper" else |_| {}
    return null;
}

/// Find the uv binary. Checks common install locations.
fn findUv(buf: []u8) ?[]const u8 {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
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

            const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return;
            const alloc = @import("alloc.zig").allocator;

            // ── Step 1: Ensure `uv` is installed ──
            var uv_buf: [512]u8 = undefined;
            var uv_bin = findUv(&uv_buf);

            if (uv_bin == null) {
                mlx_whisper_step = 1;
                setStatus("Installing uv…", .{});
                logs.pushLog("info", "deps", "Installing uv (Python package manager)…", true);
                // Official installer: curl -LsSf https://astral.sh/uv/install.sh | sh
                var uv_install = io_global.Child.init(&.{
                    "sh", "-c", "curl -LsSf https://astral.sh/uv/install.sh | sh",
                }, alloc);
                uv_install.stdout_behavior = .Ignore;
                uv_install.stderr_behavior = .Ignore;
                _ = uv_install.spawnAndWait() catch {
                    logs.pushLog("error", "deps", "Failed to install uv — check internet connection", true);
                    return;
                };
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
            const venv_dir = std.fmt.bufPrintZ(&venv_buf, "{s}/.config/opal/mlx-venv", .{home}) catch return;

            var pip_check_buf: [512]u8 = undefined;
            const venv_python = std.fmt.bufPrintZ(&pip_check_buf, "{s}/bin/python", .{venv_dir}) catch return;

            if (io_global.cwdAccess(venv_python, .{})) |_| {
                // venv already exists
            } else |_| {
                mlx_whisper_step = 2;
                setStatus("Creating Python venv…", .{});
                logs.pushLog("info", "deps", "Creating isolated Python environment…", true);
                var venv_create = io_global.Child.init(&.{
                    uv, "venv", venv_dir, "--python", "3.12",
                }, alloc);
                venv_create.stdout_behavior = .Ignore;
                venv_create.stderr_behavior = .Ignore;
                _ = venv_create.spawnAndWait() catch {
                    logs.pushLog("error", "deps", "uv venv creation failed", true);
                    return;
                };
                logs.pushLog("info", "deps", "Python venv ready", true);
            }

            // ── Step 3: Install mlx-whisper into the venv ──
            var bin_check_buf: [512]u8 = undefined;
            if (mlxWhisperBinPath(&bin_check_buf) == null) {
                mlx_whisper_step = 3;
                setStatus("Installing mlx-whisper…", .{});
                logs.pushLog("info", "deps", "Installing mlx-whisper…", true);
                var pip_install = io_global.Child.init(&.{
                    uv,         "pip",       "install", "mlx-whisper",
                    "--python", venv_python,
                }, alloc);
                pip_install.stdout_behavior = .Ignore;
                pip_install.stderr_behavior = .Ignore;
                _ = pip_install.spawnAndWait() catch {
                    logs.pushLog("error", "deps", "mlx-whisper install failed", true);
                    return;
                };
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
            _ = cfg_dl.spawnAndWait() catch {};

            // weights.safetensors (~1.6GB)
            var wt_buf: [768]u8 = undefined;
            const wt_path = std.fmt.bufPrintZ(&wt_buf, "{s}/weights.safetensors", .{model_dir}) catch return;
            var wt_dl = io_global.Child.init(&.{
                "curl",                                                                                         "-L", "--fail", "--show-error", "-o", wt_path,
                "https://huggingface.co/mlx-community/whisper-large-v3-turbo/resolve/main/weights.safetensors",
            }, alloc);
            wt_dl.stdout_behavior = .Ignore;
            wt_dl.stderr_behavior = .Ignore;
            _ = wt_dl.spawnAndWait() catch {
                logs.pushLog("error", "deps", "Failed to download MLX Whisper weights", true);
                return;
            };

            mlx_whisper_step = 5;
            setStatus("Ready", .{});
            logs.pushLog("info", "deps", "MLX Whisper model ready", true);
        }
    };
    if (std.Thread.spawn(.{}, S.worker, .{})) |t| t.detach() else |_| {
        mlx_whisper_downloading = false;
    }
}
