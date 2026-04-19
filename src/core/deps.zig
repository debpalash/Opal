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
    sherpa_tts_model: bool = false,      // Piper VITS lessac-medium
    sherpa_kokoro_model: bool = false,    // Kokoro multi-voice TTS
    sherpa_stream_model: bool = false,
    sherpa_mic_cli: bool = false,
};

/// Returns true when the full sherpa stack (CLI + STT + TTS + streaming
/// + mic CLI) is present — allows voice_backend to auto-promote sherpa
/// to default.
pub fn sherpaReady(s: Status) bool {
    return s.sherpa_onnx and s.sherpa_model and s.sherpa_tts_model and
        s.sherpa_stream_model and s.sherpa_mic_cli;
}

pub fn check() Status {
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
    if (!s.apfel) { if (n < parts.len) { parts[n] = "apfel"; n += 1; } }
    if (!s.ffmpeg) { if (n < parts.len) { parts[n] = "ffmpeg"; n += 1; } }
    if (!s.whisper) { if (n < parts.len) { parts[n] = "whisper-cpp"; n += 1; } }
    if (n == 0) return "";

    var off: usize = 0;
    const prefix = "brew install ";
    @memcpy(buf[off..off + prefix.len], prefix);
    off += prefix.len;
    for (parts[0..n], 0..) |p, i| {
        if (i > 0) { buf[off] = ' '; off += 1; }
        @memcpy(buf[off..off + p.len], p);
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
                "curl", "-L", "--fail", "--silent", "--show-error",
                "-o", tar_path,
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2",
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
    _ = std.Thread.spawn(.{}, S.worker, .{}) catch {
        sherpa_model_downloading = false;
    };
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
                "curl", "-L", "--fail", "--silent", "--show-error",
                "-o", tar_path,
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2",
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
    _ = std.Thread.spawn(.{}, S.worker, .{}) catch {
        sherpa_tts_downloading = false;
    };
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
                "curl", "-L", "--fail", "--silent", "--show-error",
                "-o", tar_path,
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2",
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
    _ = std.Thread.spawn(.{}, S.worker, .{}) catch {
        sherpa_kokoro_downloading = false;
    };
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
                "curl", "-L", "--fail", "--silent", "--show-error",
                "-o", tar_path,
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2",
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

            io_global.deleteFileAbsolute(tar_path) catch {};
            logs.pushLog("info", "deps", "Streaming Zipformer model ready", true);
        }
    };
    _ = std.Thread.spawn(.{}, S.worker, .{}) catch {
        sherpa_stream_downloading = false;
    };
}

pub fn fetchWhisperModelAsync() void {
    const S = struct {
        fn worker() void {
            var home_buf: [512]u8 = undefined;
            const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return;
            const dir = std.fmt.bufPrintZ(&home_buf, "{s}/.config/opal/models", .{home}) catch return;

            // mkpath + check if already present
            io_global.makeDirAbsolute(dir) catch {};
            var path_buf: [512]u8 = undefined;
            const model_path = std.fmt.bufPrintZ(&path_buf, "{s}/ggml-tiny.en.bin", .{dir}) catch return;
            io_global.cwdAccess(model_path, .{}) catch {
                // Missing — fetch
                logs.pushLog("info", "deps", "Fetching whisper tiny model (~39MB)…", true);
                var curl = io_global.Child.init(&.{
                    "curl", "-L", "--fail", "--silent", "--show-error",
                    "-o", model_path,
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
                }, @import("alloc.zig").allocator);
                curl.stdout_behavior = .Ignore;
                curl.stderr_behavior = .Ignore;
                curl.spawn() catch {
                    logs.pushLog("error", "deps", "curl not found — cannot fetch whisper model", false);
                    return;
                };
                _ = curl.wait() catch {};
                logs.pushLog("info", "deps", "Whisper model ready at ~/.config/opal/models/", true);
                return;
            };
        }
    };
    _ = std.Thread.spawn(.{}, S.worker, .{}) catch {};
}
