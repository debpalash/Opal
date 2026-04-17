const std = @import("std");
const builtin = @import("builtin");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

// ══════════════════════════════════════════════════════════
//  AI Server — Lifecycle Management for LLM + Embedding
//  macOS: uses apfel (Apple Intelligence via FoundationModels)
//  Linux/Windows: uses Bonsai-8B + llama-server
// ══════════════════════════════════════════════════════════

pub const is_macos = builtin.os.tag == .macos;

const MODEL_URL = "https://huggingface.co/prism-ml/Bonsai-8B-gguf/resolve/main/Bonsai-8B.gguf";
const MODEL_FILENAME = "Bonsai-8B.gguf";
pub const DEFAULT_MODELS_DIR = "models";

// ── Server state ──
pub var server_process: ?@import("../core/io_global.zig").Child = null;
pub var server_running: bool = false;
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

    if (is_macos) {
        // ── macOS: Apple Intelligence via apfel ──
        // No model download needed — Foundation Models are built into macOS 26+
        model_exists = true;

        // Look for apfel binary
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
                std.debug.print("[AI] apfel found: {s}\n", .{apfel_path});
                return;
            } else |_| {}
        }

        // Fallback: check PATH
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
                std.debug.print("[AI] apfel found in PATH: {s}\n", .{trimmed});
            }
        }
        _ = which_child.wait() catch {};
    } else {
        // ── Linux/Windows: Bonsai-8B + llama-server ──
        const model_path = std.fmt.bufPrintZ(&model_path_buf, "{s}/{s}", .{ DEFAULT_MODELS_DIR, MODEL_FILENAME }) catch return;
        model_path_len = model_path.len;

        if (@import("../core/io_global.zig").cwdAccess(model_path, .{})) |_| {
            model_exists = true;
            std.debug.print("[AI] Model found: {s}\n", .{model_path});
        } else |_| {
            model_exists = false;
        }

        const prism_server = "bin/prism/llama-prism-b8194-1179bfc/llama-server";
        const bin_server = "bin/shimmy";
        const local_server = "llama.cpp/build/bin/llama-server";

        if (@import("../core/io_global.zig").cwdAccess(prism_server, .{})) |_| {
            const slen = prism_server.len;
            @memcpy(llama_server_path_buf[0..slen], prism_server);
            llama_server_path_len = slen;
            llama_server_exists = true;
            std.debug.print("[AI] PrismML llama-server found: {s}\n", .{prism_server});
        } else |_| if (@import("../core/io_global.zig").cwdAccess(bin_server, .{})) |_| {
            const slen = bin_server.len;
            @memcpy(llama_server_path_buf[0..slen], bin_server);
            llama_server_path_len = slen;
            llama_server_exists = true;
            std.debug.print("[AI] Shimmy found: {s}\n", .{bin_server});
        } else |_| if (@import("../core/io_global.zig").cwdAccess(local_server, .{})) |_| {
            const slen = local_server.len;
            @memcpy(llama_server_path_buf[0..slen], local_server);
            llama_server_path_len = slen;
            llama_server_exists = true;
            std.debug.print("[AI] llama-server found: {s}\n", .{local_server});
        } else |_| {
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
                    std.debug.print("[AI] llama-server found in PATH: {s}\n", .{trimmed});
                }
            }
            _ = which_child.wait() catch {};
        }
    }
}

pub fn startServer() void {
    if (server_running) return;
    if (server_installing) return;
    if (!model_exists or !llama_server_exists) return;

    const sv_path = llama_server_path_buf[0..llama_server_path_len];
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{server_port}) catch "41592";

    if (is_macos) {
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

        std.debug.print("[AI] Starting apfel server: {s}\n", .{sv_path});
        std.debug.print("[AI] Port: {s}\n", .{port_str});
        std.debug.print("[AI] Mode: Apple Intelligence (on-device)\n", .{});

        const argv = [_][]const u8{ sv_path, "--serve", "--port", port_str };
        var child = @import("../core/io_global.zig").Child.init(&argv, @import("../core/alloc.zig").allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch {
            setError("Failed to start apfel server");
            std.debug.print("[AI] ERROR: apfel spawn failed\n", .{});
            server_running = false;
            return;
        };

        server_process = child;
        // No embedding server on macOS — Apple Foundation Models don't support embeddings

        model_status = .checking;
        logs.pushLog("info", "ai", "Apple Intelligence server started", true);
        state.showToast("Apple Intelligence starting...");
        std.debug.print("[AI] apfel server spawned\n", .{});
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

        std.debug.print("[AI] Starting server: {s}\n", .{sv_path});
        std.debug.print("[AI] Model: {s}\n", .{m_path});
        std.debug.print("[AI] Port: {s}\n", .{port_str});

        const is_shimmy = std.mem.indexOf(u8, sv_path, "shimmy") != null;

        var child: @import("../core/io_global.zig").Child = undefined;

        if (is_shimmy) {
            var bind_buf: [32]u8 = undefined;
            const bind_str = std.fmt.bufPrintZ(&bind_buf, "127.0.0.1:{s}", .{port_str}) catch "127.0.0.1:41592";
            const argv = [_][]const u8{ sv_path, "serve", "--bind", bind_str };
            child = @import("../core/io_global.zig").Child.init(&argv, @import("../core/alloc.zig").allocator);
            std.debug.print("[AI] Mode: Shimmy\n", .{});
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
            std.debug.print("[AI] Mode: llama-server (flash-attn)\n", .{});
        }

        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch {
            setError("Failed to start AI server");
            std.debug.print("[AI] ERROR: server spawn failed\n", .{});
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
            std.debug.print("[AI] Warning: could not start embedding server\n", .{});
        };
        embed_server_process = embed_child;

        model_status = .checking;

        logs.pushLog("info", "ai", "AI servers started", true);
        state.showToast("AI servers starting...");
        std.debug.print("[AI] Server processes spawned\n", .{});
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

    if (is_macos) {
        var pkill = @import("../core/io_global.zig").Child.init(&.{ "pkill", "-f", "apfel --serve" }, @import("../core/alloc.zig").allocator);
        pkill.stdout_behavior = .Pipe;
        pkill.stderr_behavior = .Pipe;
        if (pkill.spawn()) |_| {} else |_| {}
        _ = pkill.wait() catch {};
    } else {
        var pkill = @import("../core/io_global.zig").Child.init(&.{ "pkill", "-f", "llama-server" }, @import("../core/alloc.zig").allocator);
        pkill.stdout_behavior = .Pipe;
        pkill.stderr_behavior = .Pipe;
        if (pkill.spawn()) |_| {} else |_| {}
        _ = pkill.wait() catch {};
    }

    server_running = false;
    model_status = .offline;
    const stop_msg = if (is_macos) "Apple Intelligence stopped" else "llama-server stopped";
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

    @import("../core/io_global.zig").cwdMakePath(DEFAULT_MODELS_DIR) catch {};

    var out_path_buf: [512]u8 = undefined;
    const out_path = std.fmt.bufPrintZ(&out_path_buf, "{s}/{s}", .{ DEFAULT_MODELS_DIR, MODEL_FILENAME }) catch {
        setError("Path too long");
        return;
    };

    const argv = [_][]const u8{
        "curl", "-L", "--progress-bar",
        "-o", out_path,
        MODEL_URL,
    };

    var child = @import("../core/io_global.zig").Child.init(&argv, @import("../core/alloc.zig").allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch {
        setError("Failed to start download. Is curl installed?");
        return;
    };

    const prog = "Downloading 1.16 GB...";
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
        logs.pushLog("info", "ai", "Bonsai-8B model downloaded", true);
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
            const plen = bin_path.len;
            @memcpy(llama_server_path_buf[0..plen], bin_path);
            llama_server_path_len = plen;
            llama_server_exists = true;
            state.showToast("llama-server found!");
            return;
        }
        downloadLlamaServer(bin_dir, bin_path);
        return;
    };

    const plen = bin_path.len;
    @memcpy(llama_server_path_buf[0..plen], bin_path);
    llama_server_path_len = plen;
    llama_server_exists = true;
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
                    std.debug.print("[AI] Auto-discovered model: {s}\n", .{name[0..nlen]});
                }
            }
        }
    } else {
        model_status = .offline;
    }
}
