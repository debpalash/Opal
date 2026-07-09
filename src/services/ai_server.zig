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

pub const BackendKind = enum { apfel, gemma_llama, cloud };

/// Default backend: local llama-server everywhere. Apple Intelligence
/// (apfel) is RETIRED as a default — measured ~5 tok/s generation (6+ s per
/// one-line reply) and it drops the JSON response format. It stays reachable
/// via Settings for the curious; legacy configs that auto-persisted "apfel"
/// migrate to the llama backend on load (config.zig).
/// `.cloud` = any OpenAI-compatible HTTP API (OpenRouter, Google AI Studio,
/// NVIDIA NIM, Groq, Cerebras presets) configured via .env — see
/// CLOUD_PROVIDERS below. Nothing local is spawned or downloaded for it.
pub var backend_kind: BackendKind = .gemma_llama;

// ── Cloud (OpenAI-compatible) providers ──
// Keys/endpoints come from .env (cwd first — dev runs from the repo root —
// then ~/.config/opal/.env), NOT the config DB, so secrets stay out of
// opal.db. Vars per provider: {PREFIX}_API_KEY / _BASE_URL / _MODEL; base +
// model fall back to the preset defaults when the var is absent.
pub const CloudProvider = struct {
    id: []const u8, // stable key for config persistence
    name: []const u8, // display name (Settings)
    prefix: []const u8, // .env var prefix
    default_base: []const u8, // OpenAI-compatible base (includes /v1 path)
    default_model: []const u8,
};

pub const CLOUD_PROVIDERS = [_]CloudProvider{
    .{ .id = "openrouter", .name = "OpenRouter", .prefix = "OPENROUTER", .default_base = "https://openrouter.ai/api/v1", .default_model = "meta-llama/llama-3.3-70b-instruct:free" },
    .{ .id = "google", .name = "Google AI", .prefix = "GOOGLE_AI", .default_base = "https://generativelanguage.googleapis.com/v1beta/openai", .default_model = "gemini-2.5-flash" },
    .{ .id = "nvidia", .name = "NVIDIA NIM", .prefix = "NVIDIA", .default_base = "https://integrate.api.nvidia.com/v1", .default_model = "meta/llama-3.3-70b-instruct" },
    .{ .id = "groq", .name = "Groq", .prefix = "GROQ", .default_base = "https://api.groq.com/openai/v1", .default_model = "llama-3.3-70b-versatile" },
    .{ .id = "cerebras", .name = "Cerebras", .prefix = "CEREBRAS", .default_base = "https://api.cerebras.ai/v1", .default_model = "llama-3.3-70b" },
};

pub var cloud_provider_idx: usize = 0;

// .env body cached once (4 KB covers the real file with headroom).
var env_buf: [8192]u8 = undefined;
var env_len: usize = 0;
var env_loaded: bool = false;

fn envContent() []const u8 {
    if (!env_loaded) {
        env_loaded = true;
        const io_g = @import("../core/io_global.zig");
        // Same search order as state.zig's TMDB loader: cwd (dev) first,
        // then ~/.config/opal/.env (installed app).
        blk: {
            if (io_g.cwdReadFileAlloc(".env", @import("../core/alloc.zig").allocator, env_buf.len)) |body| {
                defer @import("../core/alloc.zig").allocator.free(body);
                env_len = @min(body.len, env_buf.len);
                @memcpy(env_buf[0..env_len], body[0..env_len]);
                break :blk;
            } else |_| {}
            var cfg_buf: [512]u8 = undefined;
            const cfg = @import("../core/paths.zig").configDir(&cfg_buf);
            var p_buf: [600]u8 = undefined;
            const p = std.fmt.bufPrint(&p_buf, "{s}/.env", .{cfg}) catch break :blk;
            if (io_g.cwdReadFileAlloc(p, @import("../core/alloc.zig").allocator, env_buf.len)) |body| {
                defer @import("../core/alloc.zig").allocator.free(body);
                env_len = @min(body.len, env_buf.len);
                @memcpy(env_buf[0..env_len], body[0..env_len]);
            } else |_| {}
        }
    }
    return env_buf[0..env_len];
}

fn envVar(prefix: []const u8, suffix: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}{s}=", .{ prefix, suffix }) catch return null;
    const v = @import("../core/env.zig").findValue(envContent(), key) orelse return null;
    if (v.len == 0) return null;
    return v;
}

pub fn cloudProvider() CloudProvider {
    return CLOUD_PROVIDERS[@min(cloud_provider_idx, CLOUD_PROVIDERS.len - 1)];
}

pub fn cloudKey() ?[]const u8 {
    return envVar(cloudProvider().prefix, "_API_KEY");
}

pub fn cloudBase() []const u8 {
    return envVar(cloudProvider().prefix, "_BASE_URL") orelse cloudProvider().default_base;
}

pub fn cloudModel() []const u8 {
    return envVar(cloudProvider().prefix, "_MODEL") orelse cloudProvider().default_model;
}

/// True when the selected cloud provider has an API key available.
pub fn cloudConfigured() bool {
    return cloudKey() != null;
}

/// True when provider `i` has an API key in .env (Settings status dots).
pub fn cloudProviderHasKey(i: usize) bool {
    if (i >= CLOUD_PROVIDERS.len) return false;
    return envVar(CLOUD_PROVIDERS[i].prefix, "_API_KEY") != null;
}

/// First provider with a key in .env, or null. Drives the local→cloud
/// fallback in ensureReady and the fresh-install default.
pub fn firstCloudProviderWithKey() ?usize {
    for (0..CLOUD_PROVIDERS.len) |i| {
        if (cloudProviderHasKey(i)) return i;
    }
    return null;
}

pub fn selectCloudProviderById(id: []const u8) void {
    for (CLOUD_PROVIDERS, 0..) |p, i| {
        if (std.mem.eql(u8, p.id, id)) {
            cloud_provider_idx = i;
            return;
        }
    }
}

// ── Hugging Face GGUF model catalog ──
// A curated set of llama.cpp-servable GGUF models pulled directly from the
// Hugging Face hub. The user picks one in Settings; the choice is persisted
// (config key "ai_model_id") and drives download + serving. All URLs are
// HF `resolve/main` direct links and were verified to return 200.
pub const GgufModel = struct {
    id: []const u8, // stable key for config persistence
    name: []const u8, // display name
    url: []const u8, // HF resolve URL
    filename: []const u8, // on-disk name under models/
    size_label: []const u8,
    note: []const u8, // short one-liner shown in the picker
};

pub const MODEL_CATALOG = [_]GgufModel{
    .{
        .id = "gemma-4-e2b",
        .name = "Gemma 4 E2B",
        .url = "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-UD-Q4_K_XL.gguf",
        .filename = "gemma-4-E2B-it-UD-Q4_K_XL.gguf",
        .size_label = "3.17 GB",
        .note = "Balanced default (Google)",
    },
    .{
        .id = "qwen2.5-3b",
        .name = "Qwen2.5 3B Instruct",
        .url = "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf",
        .filename = "qwen2.5-3b-instruct-q4_k_m.gguf",
        .size_label = "2.10 GB",
        .note = "Fast, strong tool-use",
    },
    .{
        .id = "llama3.2-3b",
        .name = "Llama 3.2 3B Instruct",
        .url = "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        .filename = "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        .size_label = "2.02 GB",
        .note = "General purpose (Meta)",
    },
    .{
        .id = "qwen2.5-1.5b",
        .name = "Qwen2.5 1.5B Instruct",
        .url = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
        .filename = "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        .size_label = "1.12 GB",
        .note = "Lightweight / low-RAM",
    },
    .{
        .id = "smollm2-1.7b",
        .name = "SmolLM2 1.7B Instruct",
        .url = "https://huggingface.co/bartowski/SmolLM2-1.7B-Instruct-GGUF/resolve/main/SmolLM2-1.7B-Instruct-Q4_K_M.gguf",
        .filename = "SmolLM2-1.7B-Instruct-Q4_K_M.gguf",
        .size_label = "1.06 GB",
        .note = "Tiny & quick",
    },
};

/// Index into MODEL_CATALOG for the active llama-server model.
/// Default = Qwen2.5 3B Instruct: 2.1 GB Q4, strong tool/JSON discipline,
/// ~100 tok/s on M-series Airs — the "small, intelligent, fast" pick.
pub var active_model_idx: usize = 1;

pub fn activeModel() GgufModel {
    return MODEL_CATALOG[@min(active_model_idx, MODEL_CATALOG.len - 1)];
}

pub fn activeModelId() []const u8 {
    return activeModel().id;
}

/// Select a catalog model by index. Triggers re-detection (download/exist state)
/// only if paths were already checked — i.e. a live user switch, not startup.
pub fn selectModelByIndex(i: usize) void {
    if (i >= MODEL_CATALOG.len or i == active_model_idx) return;
    active_model_idx = i;
    if (checked_paths) resetDetection();
}

/// Select by stable id (used by config load + voice/remote commands).
pub fn selectModelById(id: []const u8) void {
    for (MODEL_CATALOG, 0..) |m, i| {
        if (std.mem.eql(u8, m.id, id)) {
            selectModelByIndex(i);
            return;
        }
    }
}

/// Whether a catalog entry's GGUF is already on disk.
pub fn modelDownloaded(i: usize) bool {
    if (i >= MODEL_CATALOG.len) return false;
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ DEFAULT_MODELS_DIR, MODEL_CATALOG[i].filename }) catch return false;
    @import("../core/io_global.zig").cwdAccess(p, .{}) catch return false;
    return true;
}

pub const DEFAULT_MODELS_DIR = "models";

fn activeModelFilename() []const u8 {
    return switch (backend_kind) {
        .apfel, .cloud => "",
        .gemma_llama => activeModel().filename,
    };
}

fn activeModelUrl() []const u8 {
    return switch (backend_kind) {
        .apfel, .cloud => "",
        .gemma_llama => activeModel().url,
    };
}

fn activeModelSizeLabel() []const u8 {
    return switch (backend_kind) {
        .apfel, .cloud => "",
        .gemma_llama => activeModel().size_label,
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

/// Chat-completions endpoint for the ACTIVE backend. Cloud bases already
/// carry their version path (…/api/v1, …/v1beta/openai), so only the local
/// server gets "/v1" inserted.
pub fn chatCompletionsUrl(buf: []u8) []const u8 {
    if (backend_kind == .cloud) {
        return std.fmt.bufPrintZ(buf, "{s}/chat/completions", .{cloudBase()}) catch "";
    }
    return std.fmt.bufPrintZ(buf, "http://127.0.0.1:{d}/v1/chat/completions", .{server_port}) catch "";
}

/// "Authorization: Bearer …" header for cloud requests; null for local
/// backends (llama-server/apfel need no auth).
pub fn authHeader(buf: []u8) ?[]const u8 {
    if (backend_kind != .cloud) return null;
    const key = cloudKey() orelse return null;
    return std.fmt.bufPrintZ(buf, "Authorization: Bearer {s}", .{key}) catch null;
}

pub fn checkPaths() void {
    if (checked_paths) return;
    checked_paths = true;

    switch (backend_kind) {
        .apfel => detectApfel(),
        .gemma_llama => detectGemmaLlama(),
        .cloud => detectCloud(),
    }
}

fn detectCloud() void {
    // Cloud backend needs no local binaries or model files — "installed"
    // means an API key is present. Reuse the existing gates so every
    // downstream `model_exists and llama_server_exists` check keeps working.
    const ok = cloudConfigured();
    model_exists = ok;
    llama_server_exists = ok;
    if (ok) model_status = .online;
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
    const model_path = std.fmt.bufPrintZ(&model_path_buf, "{s}/{s}", .{ DEFAULT_MODELS_DIR, activeModelFilename() }) catch return;
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

/// Make the active brain usable for a send. Idempotent — call from any send
/// path. NO silent installs: local models download only from an explicit
/// user action (Settings › AI catalog or the chat setup card), never here —
/// this used to kick a multi-GB download on the first chat message.
pub fn ensureReady() void {
    checkPaths();

    // Local backend selected but not installed, while a cloud key sits in
    // .env → use the cloud for this session instead of failing (or worse,
    // auto-downloading). Explicitly installing a local model later makes the
    // local path win again; Settings can pin either at any time.
    if (backend_kind != .cloud and !(model_exists and llama_server_exists)) {
        if (firstCloudProviderWithKey()) |pi| {
            cloud_provider_idx = pi;
            backend_kind = .cloud;
            resetDetection();
            var tb: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&tb, "Using {s} (cloud) — install a local model in Settings › AI to go offline", .{cloudProvider().name}) catch "Using cloud AI";
            state.showToast(msg);
        }
    }

    if (backend_kind == .cloud) {
        model_status = if (cloudConfigured()) .online else .offline;
        return;
    }
    if (server_running) return;
    // Everything on disk → user is one send away; bring the server up.
    // Missing pieces → the chat setup card / Settings show install buttons.
    if (model_exists and llama_server_exists) startServer();
}

pub fn startServer() void {
    if (backend_kind == .cloud) return; // nothing local to start
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
                "-m",
                m_path,
                "--host",
                "127.0.0.1",
                "--port",
                port_str,
                "-ngl",
                ngl_str,
                "--ctx-size",
                "4096",
                "--flash-attn", "on", // Flash attention — faster on modern GPUs
                "-b", "512", // Batch size for prompt processing
                "-np", "1", // Single slot — conversational assistant
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
            "-m",
            embed_m_path,
            "--host",
            "127.0.0.1",
            "--port",
            "41593",
            "--embedding",
            "-c",
            "2048",
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
        _ = proc.wait() catch {};
        server_process = null;
    }

    if (embed_server_process) |*proc| {
        _ = proc.kill() catch {};
        _ = proc.wait() catch {};
        embed_server_process = null;
    }

    // Cloud: nothing local to kill — clear status and bail before pkill.
    if (backend_kind == .cloud) {
        server_running = false;
        model_status = .offline;
        return;
    }
    const pkill_pattern: []const u8 = switch (backend_kind) {
        .apfel => "apfel --serve",
        .gemma_llama => "llama-server",
        .cloud => unreachable, // handled above
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
        .cloud => unreachable, // handled above
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
    defer {
        model_downloading = false;
    }

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
        "curl", "-L",     "--progress-bar",
        "-o",   out_path, activeModelUrl(),
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
        var lb: [96]u8 = undefined;
        const log_msg = std.fmt.bufPrint(&lb, "{s} downloaded", .{activeModel().name}) catch "Model downloaded";
        logs.pushLog("info", "ai", log_msg, true);
        state.showToast("AI model ready — starting the local brain");
        // Self-install completion → bring the server up without another click.
        startServer();
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
    defer {
        server_installing = false;
    }

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
        "curl", "-L",     "--progress-bar",
        "-o",   bin_path, release_url,
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
    if (backend_kind == .cloud) {
        // No health endpoint to poll — configured means reachable-enough;
        // real errors surface per-request in the chat pipeline.
        model_status = if (cloudConfigured()) .online else .offline;
        return;
    }
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
