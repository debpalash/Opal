const std = @import("std");
const builtin = @import("builtin");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

// ══════════════════════════════════════════════════════════
//  AI Server — Lifecycle Management for LLM + Embedding
//  Backends:
//    - apfel        (macOS only) Apple Intelligence via FoundationModels
//    - gemma_llama  Gemma 4 E2B (UD-Q4_K_XL ~3.2GB) via llama-server.
//                   Cross-platform; the preferred quality backend.
//  Bonsai-8B is no longer the default — it remains reachable by dropping
//  its GGUF into the models/ dir and pointing the legacy server at it.
// ══════════════════════════════════════════════════════════

pub const is_macos = builtin.os.tag == .macos;

pub const BackendKind = enum { apfel, gemma_llama };

/// Default backend per OS. macOS stays on apfel for zero-install UX; users
/// can switch to Gemma in Settings. Other OSes have no apfel so Gemma wins.
pub var backend_kind: BackendKind = if (is_macos) .apfel else .gemma_llama;

// Gemma 4 E2B (Unsloth dynamic 4-bit, ~3.2GB). Multimodal-capable; this build
// uses text-only via llama-server /v1/chat/completions.
const GEMMA_MODEL_URL = "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-UD-Q4_K_XL.gguf";
const GEMMA_MODEL_FILENAME = "gemma-4-E2B-it-UD-Q4_K_XL.gguf";
const GEMMA_MODEL_SIZE_LABEL = "3.17 GB";

pub const DEFAULT_MODELS_DIR = "models";

fn activeModelFilename() []const u8 {
    return switch (backend_kind) {
        .apfel => "",
        .gemma_llama => GEMMA_MODEL_FILENAME,
    };
}

fn activeModelUrl() []const u8 {
    return switch (backend_kind) {
        .apfel => "",
        .gemma_llama => GEMMA_MODEL_URL,
    };
}

fn activeModelSizeLabel() []const u8 {
    return switch (backend_kind) {
        .apfel => "",
        .gemma_llama => GEMMA_MODEL_SIZE_LABEL,
    };
}

/// Call after switching backend_kind so path/exist state refreshes.
pub fn resetDetection() void {
    checked_paths = false;
    llama_server_exists = false;
    model_exists = false;
    llama_server_path_len = 0;
    model_path_len = 0;
    model_status = .unknown;
    checkPaths();
}

// ── Server state ──
pub var server_process: ?@import("../core/io_global.zig").Child = null;
pub var server_running: bool = false;

/// Serializes all inference calls through apfel (LLM), whisper-cpp (STT),
/// and `say`/TTS backends. Voicebox-pattern: one worker touches models at
/// a time. Prevents:
///   - two generateResponse threads racing a single apfel instance
///   - mic recording while TTS is speaking (echo loop)
///   - whisper-cpp model reload on concurrent transcribe
pub var inference_mutex: @import("../core/sync.zig").Mutex = .{};
pub var server_port: u16 = 41592;
pub var gpu_layers: i32 = 99;
pub var last_health_check: i64 = 0;
pub var model_status: enum { unknown, online, offline, checking } = .unknown;

// ── Model state ──
pub var model_path_buf: [512]u8 = std.mem.zeroes([512]u8);
pub var model_path_len: usize = 0;
pub var model_exists: bool = false;
pub var model_downloading: bool = false;
pub var download_progress_buf: [64]u8 = std.mem.zeroes([64]u8);
pub var download_progress_len: usize = 0;
pub var llama_server_path_buf: [512]u8 = std.mem.zeroes([512]u8);
pub var llama_server_path_len: usize = 0;
pub var llama_server_exists: bool = false;
pub var server_installing: bool = false;
pub var install_status_buf: [64]u8 = std.mem.zeroes([64]u8);
pub var install_status_len: usize = 0;

// ── Config ──
pub var checked_paths: bool = false;
pub var cached_model_name: [64]u8 = std.mem.zeroes([64]u8);
pub var cached_model_name_len: usize = 0;

var embed_server_process: ?@import("../core/io_global.zig").Child = null;

// ── Error callback ──
var set_error_fn: ?*const fn ([]const u8) void = null;

pub fn setErrorCallback(f: *const fn ([]const u8) void) void {
    set_error_fn = f;
}

fn setError(err: []const u8) void {
    if (set_error_fn) |f| f(err);
}

pub fn getServerUrl(buf: *[128]u8) []const u8 {
    return std.fmt.bufPrintZ(buf, "http://127.0.0.1:{d}", .{server_port}) catch "http://127.0.0.1:41592";
}

pub fn checkPaths() void {
    if (checked_paths) return;
    checked_paths = true;

    switch (backend_kind) {
        .apfel => detectApfel(),
        .gemma_llama => detectGemmaLlama(),
    }
}

fn detectApfel() void {
    // Apple Intelligence: no model download; Foundation Models are built into
    // macOS 26+. We only need to locate the apfel CLI.
    model_exists = true;

    const apfel_paths = [_][]const u8{
        "/opt/homebrew/bin/apfel",
        "/usr/local/bin/apfel",
    };
    for (apfel_paths) |apfel_path| {
        if (@import("../core/io_global.zig").cwdAccess(apfel_path, .{})) |_| {
            const slen = apfel_path.len;
            @memcpy(llama_server_path_buf[0..slen], apfel_path);
            llama_server_path_len = slen;
            llama_server_exists = true;
            if (@import("builtin").mode == .Debug) std.debug.print("[AI] apfel found: {s}\n", .{apfel_path});
            return;
        } else |_| {}
    }

    var which_child = @import("../core/io_global.zig").Child.init(&.{ "which", "apfel" }, @import("../core/alloc.zig").allocator);
    which_child.stdout_behavior = .Pipe;
    which_child.stderr_behavior = .Pipe;
    if (which_child.spawn()) |_| {} else |_| return;
    if (which_child.stdout) |*stdout| {
        const out = @import("../core/io_global.zig").readToEndAlloc(stdout, @import("../core/alloc.zig").allocator, 1024) catch return;
        defer @import("../core/alloc.zig").allocator.free(out);
        const trimmed = std.mem.trimEnd(u8, out, "\n\r ");
        if (trimmed.len > 0) {
            const plen = @min(trimmed.len, 512);
            @memcpy(llama_server_path_buf[0..plen], trimmed[0..plen]);
            llama_server_path_len = plen;
            llama_server_exists = true;
            if (@import("builtin").mode == .Debug) std.debug.print("[AI] apfel found in PATH: {s}\n", .{trimmed});
        }
    }
    _ = which_child.wait() catch {};
}

fn detectGemmaLlama() void {
    // Gemma via llama-server: works on macOS, Linux, Windows. Same detection
    // path on all three — the only per-OS bit is the brew prefix.
    const model_path = std.fmt.bufPrintZ(&model_path_buf, "{s}/{s}", .{ DEFAULT_MODELS_DIR, GEMMA_MODEL_FILENAME }) catch return;
    model_path_len = model_path.len;

    if (@import("../core/io_global.zig").cwdAccess(model_path, .{})) |_| {
        model_exists = true;
        if (@import("builtin").mode == .Debug) std.debug.print("[AI] Gemma model found: {s}\n", .{model_path});
    } else |_| {
        model_exists = false;
    }

    // Search order matches the previous Linux/Windows flow, plus Homebrew on
    // macOS. First hit wins.
    const candidates = [_][]const u8{
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
        "bin/prism/llama-prism-b8194-1179bfc/llama-server",
        "bin/shimmy",
        "llama.cpp/build/bin/llama-server",
    };
    for (candidates) |cand| {
        if (@import("../core/io_global.zig").cwdAccess(cand, .{})) |_| {
            const slen = cand.len;
            @memcpy(llama_server_path_buf[0..slen], cand);
            llama_server_path_len = slen;
            llama_server_exists = true;
            if (@import("builtin").mode == .Debug) std.debug.print("[AI] llama-server found: {s}\n", .{cand});
            return;
        } else |_| {}
    }

    // PATH fallback
    var which_child = @import("../core/io_global.zig").Child.init(&.{ "which", "llama-server" }, @import("../core/alloc.zig").allocator);
    which_child.stdout_behavior = .Pipe;
    which_child.stderr_behavior = .Pipe;
    if (which_child.spawn()) |_| {} else |_| return;
    if (which_child.stdout) |*stdout| {
        const out = @import("../core/io_global.zig").readToEndAlloc(stdout, @import("../core/alloc.zig").allocator, 1024) catch return;
        defer @import("../core/alloc.zig").allocator.free(out);
        const trimmed = std.mem.trimEnd(u8, out, "\n\r ");
        if (trimmed.len > 0) {
            const plen = @min(trimmed.len, 512);
            @memcpy(llama_server_path_buf[0..plen], trimmed[0..plen]);
            llama_server_path_len = plen;
            llama_server_exists = true;
            if (@import("builtin").mode == .Debug) std.debug.print("[AI] llama-server found in PATH: {s}\n", .{trimmed});
        }
    }
    _ = which_child.wait() catch {};
}

pub fn startServer() void {
    if (server_running) return;
    if (server_installing) return;
    if (!model_exists or !llama_server_exists) return;

    const sv_path = llama_server_path_buf[0..llama_server_path_len];
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{server_port}) catch "41592";

    if (backend_kind == .apfel) {
        // ── macOS: Apple Intelligence via apfel ──
        // Kill any orphaned apfel serve processes
        var pkill = @import("../core/io_global.zig").Child.init(&.{ "pkill", "-f", "apfel --serve" }, @import("../core/alloc.zig").allocator);
        pkill.stdin_behavior = .Ignore;
        pkill.stdout_behavior = .Ignore;
        pkill.stderr_behavior = .Ignore;
        pkill.spawn() catch {};
        _ = pkill.wait() catch {};
        @import("../core/io_global.zig").sleep(300 * std.time.ns_per_ms);

        server_running = true;

        if (@import("builtin").mode == .Debug) std.debug.print("[AI] Starting apfel server: {s}\n", .{sv_path});
        if (@import("builtin").mode == .Debug) std.debug.print("[AI] Port: {s}\n", .{port_str});
        if (@import("builtin").mode == .Debug) std.debug.print("[AI] Mode: Apple Intelligence (on-device)\n", .{});

        const argv = [_][]const u8{ sv_path, "--serve", "--port", port_str };
        var child = @import("../core/io_global.zig").Child.init(&argv, @import("../core/alloc.zig").allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch {
            setError("Failed to start apfel server");
            if (@import("builtin").mode == .Debug) std.debug.print("[AI] ERROR: apfel spawn failed\n", .{});
            server_running = false;
            return;
        };

        server_process = child;
        // No embedding server on macOS — Apple Foundation Models don't support embeddings

        model_status = .checking;
        logs.pushLog("info", "ai", "Apple Intelligence server started", true);
        state.showToast("Apple Intelligence starting...");
        if (@import("builtin").mode == .Debug) std.debug.print("[AI] apfel server spawned\n", .{});
    } else {
        // ── Linux/Windows: Bonsai + llama-server ──
        // Kill any orphaned llama-server processes to free VRAM
        var pkill = @import("../core/io_global.zig").Child.init(&.{ "pkill", "-9", "-f", "llama-server" }, @import("../core/alloc.zig").allocator);
        pkill.stdin_behavior = .Ignore;
        pkill.stdout_behavior = .Ignore;
        pkill.stderr_behavior = .Ignore;
        pkill.spawn() catch {};
        _ = pkill.wait() catch {};
        @import("../core/io_global.zig").sleep(500 * std.time.ns_per_ms); // Give GPU time to reclaim

        server_running = true;

        const m_path = model_path_buf[0..model_path_len];

        if (@import("builtin").mode == .Debug) std.debug.print("[AI] Starting server: {s}\n", .{sv_path});
        if (@import("builtin").mode == .Debug) std.debug.print("[AI] Model: {s}\n", .{m_path});
        if (@import("builtin").mode == .Debug) std.debug.print("[AI] Port: {s}\n", .{port_str});

        const is_shimmy = std.mem.indexOf(u8, sv_path, "shimmy") != null;

        var child: @import("../core/io_global.zig").Child = undefined;

        if (is_shimmy) {
            var bind_buf: [32]u8 = undefined;
            const bind_str = std.fmt.bufPrintZ(&bind_buf, "127.0.0.1:{s}", .{port_str}) catch "127.0.0.1:41592";
            const argv = [_][]const u8{ sv_path, "serve", "--bind", bind_str };
            child = @import("../core/io_global.zig").Child.init(&argv, @import("../core/alloc.zig").allocator);
            if (@import("builtin").mode == .Debug) std.debug.print("[AI] Mode: Shimmy\n", .{});
        } else {
            var ngl_buf: [8]u8 = undefined;
            const ngl_str = std.fmt.bufPrintZ(&ngl_buf, "{d}", .{gpu_layers}) catch "99";
            const argv = [_][]const u8{
                sv_path,
                "-m", m_path,
                "--host", "127.0.0.1",
                "--port", port_str,
                "-ngl", ngl_str,
                "--ctx-size", "4096",
                "--flash-attn", "on",  // Flash attention — faster on modern GPUs
                "-b", "512",           // Batch size for prompt processing
                "-np", "1",            // Single slot — conversational assistant
            };
            child = @import("../core/io_global.zig").Child.init(&argv, @import("../core/alloc.zig").allocator);
            if (@import("builtin").mode == .Debug) std.debug.print("[AI] Mode: llama-server (flash-attn)\n", .{});
        }

        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch {
            setError("Failed to start AI server");
            if (@import("builtin").mode == .Debug) std.debug.print("[AI] ERROR: server spawn failed\n", .{});
            server_running = false;
            return;
        };

        server_process = child;

        // Spawn secondary embedding server (Linux only)
        const embed_m_path = "models/nomic-embed-text-v1.5.Q4_K_M.gguf";
        var embed_child = @import("../core/io_global.zig").Child.init(&.{
            sv_path,
            "-m", embed_m_path,
            "--host", "127.0.0.1",
            "--port", "41593",
            "--embedding",
            "-c", "2048",
            "-cb",
        }, @import("../core/alloc.zig").allocator);
        embed_child.stdout_behavior = .Ignore;
        embed_child.stderr_behavior = .Ignore;
        embed_child.spawn() catch {
            if (@import("builtin").mode == .Debug) std.debug.print("[AI] Warning: could not start embedding server\n", .{});
        };
        embed_server_process = embed_child;

        model_status = .checking;

        logs.pushLog("info", "ai", "AI servers started", true);
        state.showToast("AI servers starting...");
        if (@import("builtin").mode == .Debug) std.debug.print("[AI] Server processes spawned\n", .{});
    }
}

pub fn stopServer() void {
    if (!server_running) return;

    if (server_process) |*proc| {
        _ = proc.kill() catch {};
        // Note: Child.kill() already waits internally — don't call wait() again
        // or it panics with assert(child.id != null) on already-reaped process.
        server_process = null;
    }

    if (embed_server_process) |*proc| {
        _ = proc.kill() catch {};
        embed_server_process = null;
    }

    const pkill_pattern: []const u8 = switch (backend_kind) {
        .apfel => "apfel --serve",
        .gemma_llama => "llama-server",
    };
    var pkill = @import("../core/io_global.zig").Child.init(&.{ "pkill", "-f", pkill_pattern }, @import("../core/alloc.zig").allocator);
    pkill.stdout_behavior = .Ignore;
    pkill.stderr_behavior = .Ignore;
    if (pkill.spawn()) |_| {} else |_| {}
    _ = pkill.wait() catch {};

    server_running = false;
    model_status = .offline;
    const stop_msg = switch (backend_kind) {
        .apfel => "Apple Intelligence stopped",
        .gemma_llama => "Gemma (llama-server) stopped",
    };
    logs.pushLog("info", "ai", stop_msg, true);
    state.showToast("AI server stopped");
}

pub fn startModelDownload() void {
    if (model_downloading) return;
    model_downloading = true;

    const dl_str = "Downloading...";
    @memcpy(download_progress_buf[0..dl_str.len], dl_str);
    download_progress_len = dl_str.len;

    const t = std.Thread.spawn(.{}, downloadModelThread, .{}) catch {
        model_downloading = false;
        setError("Failed to start download thread");
        return;
    };
    t.detach();
}

fn downloadModelThread() void {
    defer { model_downloading = false; }

    // apfel backend needs no download — guard so the UI can't kick this off.
    if (backend_kind == .apfel) {
        setError("No model download needed for Apple Intelligence");
        return;
    }

    @import("../core/io_global.zig").cwdMakePath(DEFAULT_MODELS_DIR) catch {};

    var out_path_buf: [512]u8 = undefined;
    const out_path = std.fmt.bufPrintZ(&out_path_buf, "{s}/{s}", .{ DEFAULT_MODELS_DIR, activeModelFilename() }) catch {
        setError("Path too long");
        return;
    };

    const argv = [_][]const u8{
        "curl", "-L", "--progress-bar",
        "-o", out_path,
        activeModelUrl(),
    };

    var child = @import("../core/io_global.zig").Child.init(&argv, @import("../core/alloc.zig").allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch {
        setError("Failed to start download. Is curl installed?");
        return;
    };

    var prog_buf: [64]u8 = undefined;
    const prog = std.fmt.bufPrint(&prog_buf, "Downloading {s}...", .{activeModelSizeLabel()}) catch "Downloading...";
    @memcpy(download_progress_buf[0..prog.len], prog);
    download_progress_len = prog.len;

    const result = child.wait() catch {
        setError("Download failed");
        return;
    };

    if (result.exited == 0) {
        model_exists = true;
        const done = "Download complete!";
        @memcpy(download_progress_buf[0..done.len], done);
        download_progress_len = done.len;
        const log_msg = switch (backend_kind) {
            .apfel => "",
            .gemma_llama => "Gemma 4 E2B model downloaded",
        };
        logs.pushLog("info", "ai", log_msg, true);
        state.showToast("Model downloaded!");
    } else {
        setError("Download failed (curl exit error)");
    }
}

pub fn installLlamaServer() void {
    if (server_installing) return;
    server_installing = true;

    const t = std.Thread.spawn(.{}, installThread, .{}) catch {
        server_installing = false;
        setError("Failed to start install thread");
        return;
    };
    t.detach();
    state.showToast("Downloading llama-server...");
}

fn installThread() void {
    defer { server_installing = false; }

    if (is_macos) {
        installLlamaServerMac();
    } else {
        installLlamaServerShimmy();
    }
}

/// macOS path — use Homebrew's llama.cpp formula. All Opal users already
/// have brew (mpv/sqlite/libtorrent-rasterbar come from there).
fn installLlamaServerMac() void {
    // Pre-check: maybe it's already on PATH after a previous install.
    if (macLlamaServerOnPath()) |path| {
        applyFoundPath(path);
        state.showToast("llama-server already installed");
        return;
    }

    // Find brew binary (Apple Silicon vs Intel prefix).
    const brew_candidates = [_][]const u8{
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    };
    var brew_path: []const u8 = "";
    for (brew_candidates) |cand| {
        if (@import("../core/io_global.zig").cwdAccess(cand, .{})) |_| {
            brew_path = cand;
            break;
        } else |_| {}
    }
    if (brew_path.len == 0) {
        setError("Homebrew not found — install brew first (https://brew.sh)");
        return;
    }

    state.showToast("Running brew install llama.cpp (~30s)...");
    const install_argv = [_][]const u8{ brew_path, "install", "llama.cpp" };
    var install = @import("../core/io_global.zig").Child.init(&install_argv, @import("../core/alloc.zig").allocator);
    install.stdout_behavior = .Inherit;
    install.stderr_behavior = .Inherit;
    install.spawn() catch {
        setError("Failed to spawn brew");
        return;
    };
    const result = install.wait() catch {
        setError("brew install failed");
        return;
    };
    if (result.exited != 0) {
        setError("brew install llama.cpp exited non-zero");
        return;
    }

    // Re-detect after install.
    if (macLlamaServerOnPath()) |path| {
        applyFoundPath(path);
        state.showToast("llama-server installed!");
    } else {
        setError("brew install succeeded but llama-server not found");
    }
}

fn macLlamaServerOnPath() ?[]const u8 {
    const hits = [_][]const u8{
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
    };
    for (hits) |h| {
        if (@import("../core/io_global.zig").cwdAccess(h, .{})) |_| return h else |_| {}
    }
    return null;
}

fn applyFoundPath(path: []const u8) void {
    const plen = @min(path.len, 512);
    @memcpy(llama_server_path_buf[0..plen], path[0..plen]);
    llama_server_path_len = plen;
    llama_server_exists = true;
}

/// Linux/Windows path — fetch the shimmy binary (drop-in llama-server).
fn installLlamaServerShimmy() void {
    const bin_dir = "bin";
    const bin_path = bin_dir ++ "/shimmy";

    @import("../core/io_global.zig").cwdAccess(bin_path, .{}) catch {
        @import("../core/io_global.zig").cwdMakePath(bin_dir) catch {};

        const which_argv = [_][]const u8{ "which", "llama-server" };
        var which = @import("../core/io_global.zig").Child.init(&which_argv, @import("../core/alloc.zig").allocator);
        which.stdout_behavior = .Pipe;
        which.stderr_behavior = .Pipe;
        which.spawn() catch {
            downloadLlamaServer(bin_dir, bin_path);
            return;
        };
        const which_result = which.wait() catch {
            downloadLlamaServer(bin_dir, bin_path);
            return;
        };
        if (which_result.exited == 0) {
            applyFoundPath(bin_path);
            state.showToast("llama-server found!");
            return;
        }
        downloadLlamaServer(bin_dir, bin_path);
        return;
    };

    applyFoundPath(bin_path);
    state.showToast("llama-server ready!");
}

fn downloadLlamaServer(comptime bin_dir: []const u8, bin_path: []const u8) void {
    _ = bin_dir;
    const release_url = "https://github.com/Michael-A-Kuykendall/shimmy/releases/latest/download/shimmy-linux-x86_64";

    const dl_argv = [_][]const u8{
        "curl", "-L", "--progress-bar",
        "-o", bin_path,
        release_url,
    };
    var dl = @import("../core/io_global.zig").Child.init(&dl_argv, @import("../core/alloc.zig").allocator);
    dl.stdout_behavior = .Inherit;
    dl.stderr_behavior = .Inherit;
    dl.spawn() catch {
        setError("curl failed — install curl first");
        return;
    };
    const dl_result = dl.wait() catch {
        setError("Download failed");
        return;
    };
    if (dl_result.exited != 0) {
        setError("Download failed (curl error)");
        return;
    }

    const chmod_argv = [_][]const u8{ "chmod", "+x", bin_path };
    var chmod = @import("../core/io_global.zig").Child.init(&chmod_argv, @import("../core/alloc.zig").allocator);
    chmod.stdout_behavior = .Inherit;
    chmod.stderr_behavior = .Inherit;
    chmod.spawn() catch {};
    _ = chmod.wait() catch {};

    @import("../core/io_global.zig").cwdAccess(bin_path, .{}) catch {
        setError("Binary not found after download");
        return;
    };

    const plen = bin_path.len;
    @memcpy(llama_server_path_buf[0..plen], bin_path);
    llama_server_path_len = plen;
    llama_server_exists = true;
    logs.pushLog("info", "ai", "Shimmy installed", true);
    state.showToast("Shimmy installed!");
}

pub fn doHealthCheck() void {
    const t = std.Thread.spawn(.{}, healthThread, .{}) catch return;
    t.detach();
}

fn healthThread() void {
    var url_buf: [128]u8 = undefined;
    var srv_buf: [128]u8 = undefined;
    const srv = getServerUrl(&srv_buf);
    const url = std.fmt.bufPrintZ(&url_buf, "{s}/health", .{srv}) catch return;

    const argv = [_][]const u8{ "curl", "-s", "--max-time", "2", url };
    var child = @import("../core/io_global.zig").Child.init(&argv, @import("../core/alloc.zig").allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        model_status = .offline;
        return;
    };
    const stdout = @import("../core/io_global.zig").readToEndAlloc(child.stdout.?, @import("../core/alloc.zig").allocator, 4096) catch {
        model_status = .offline;
        return;
    };
    defer @import("../core/alloc.zig").allocator.free(stdout);
    const result = child.wait() catch {
        model_status = .offline;
        return;
    };

    if (result.exited == 0 and stdout.len > 0) {
        model_status = .online;

        if (cached_model_name_len == 0) {
            var m_url_buf: [128]u8 = undefined;
            const m_url = std.fmt.bufPrintZ(&m_url_buf, "{s}/v1/models", .{srv}) catch return;
            const m_argv = [_][]const u8{ "curl", "-s", "--max-time", "2", m_url };
            var m_child = @import("../core/io_global.zig").Child.init(&m_argv, @import("../core/alloc.zig").allocator);
            m_child.stdout_behavior = .Pipe;
            m_child.stderr_behavior = .Pipe;
            m_child.spawn() catch return;
            const m_out = @import("../core/io_global.zig").readToEndAlloc(m_child.stdout.?, @import("../core/alloc.zig").allocator, 4096) catch return;
            defer @import("../core/alloc.zig").allocator.free(m_out);
            _ = m_child.wait() catch {};

            if (std.mem.indexOf(u8, m_out, "\"id\":\"")) |pos| {
                const start = pos + 6;
                if (std.mem.indexOfScalarPos(u8, m_out, start, '"')) |end| {
                    const name = m_out[start..end];
                    const nlen = @min(name.len, 63);
                    @memcpy(cached_model_name[0..nlen], name[0..nlen]);
                    cached_model_name_len = nlen;
                    if (@import("builtin").mode == .Debug) std.debug.print("[AI] Auto-discovered model: {s}\n", .{name[0..nlen]});
                }
            }
        }
    } else {
        model_status = .offline;
    }
}
