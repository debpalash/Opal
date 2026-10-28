//! Blocking one-shot chat completion against the ACTIVE AI backend (local
//! llama-server by default; a cloud provider only when the user configured
//! one — ai_server.backend_kind). Worker-thread only: it waits on the network.
const std = @import("std");
const server = @import("ai_server.zig");
const fetch = @import("reliable_fetch.zig");
const pure = @import("llm_oneshot_pure.zig");
const bounded = @import("../core/bounded_process.zig");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;

pub const Error = error{ Offline, Transport, InvalidResponse, OutOfMemory, Cancelled };

/// UI thread: make sure a local server is coming up before a worker needs it.
/// Never downloads anything (ai_server.ensureReady's contract).
pub fn prepare() void {
    server.ensureReady();
}

/// Whether there is any brain to ask: a local model on disk or a configured
/// cloud provider.
pub fn available() bool {
    if (server.backend_kind == .cloud) return server.cloudConfigured();
    return server.model_exists and server.llama_server_exists;
}

fn modelName() []const u8 {
    var m: []const u8 = switch (server.backend_kind) {
        .apfel => "apple-foundationmodel",
        .gemma_llama => "gemma-4-e2b",
        .cloud => server.cloudModel(),
    };
    if (server.backend_kind != .cloud and server.cached_model_name_len > 0) m = server.cached_model_name[0..server.cached_model_name_len];
    return m;
}

/// Wait (up to ~15 s) for a just-started local server's /health.
fn waitLocalHealthy(cancel: ?bounded.CancelEpoch) bool {
    var srv_buf: [128]u8 = undefined;
    const srv = server.getServerUrl(&srv_buf);
    var url_buf: [192]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/health", .{srv}) catch return false;
    var attempts: usize = 0;
    while (attempts < 30) : (attempts += 1) {
        var hbuf: [1024]u8 = undefined;
        var hhdr: [2048]u8 = undefined;
        const r = fetch.request(url, &hbuf, &hhdr, .{ .timeout_secs = 2, .impersonate = false, .use_dpi_proxy = false, .cancel_epoch = cancel });
        if (r.failure == .spawn or r.failure == .cancelled) return false;
        if (r.body.len > 0 and std.mem.indexOf(u8, r.body, "ok") != null) return true;
        io.sleep(500 * std.time.ns_per_ms);
    }
    return false;
}

/// Ask once; returns the assistant text (caller frees with the global
/// allocator).
pub fn complete(system: []const u8, user: []const u8, max_tokens: u32, timeout_secs: u32, cancel: ?bounded.CancelEpoch) Error![]u8 {
    if (!available()) return error.Offline;
    if (server.backend_kind != .cloud and !waitLocalHealthy(cancel)) return error.Offline;

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    pure.writeBody(&body.writer, .{ .model = modelName(), .system = system, .user = user, .max_tokens = max_tokens }) catch return error.OutOfMemory;

    var url_buf: [256]u8 = undefined;
    const url = server.chatCompletionsUrl(&url_buf);
    if (url.len == 0) return error.Offline;

    // Cloud key and the prompt both travel over curl's private stdin config.
    var auth_buf: [640]u8 = undefined;
    const auth_prefix = "Authorization: ";
    var auth_hdr: [1]fetch.Header = undefined;
    var secret_headers: []const fetch.Header = &.{};
    if (server.authHeader(&auth_buf)) |ah| {
        auth_hdr[0] = .{ .name = "Authorization", .value = ah[auth_prefix.len..] };
        secret_headers = &auth_hdr;
    }

    const out = alloc.alloc(u8, 256 * 1024) catch return error.OutOfMemory;
    defer alloc.free(out);
    var hdr: [4096]u8 = undefined;
    const res = fetch.request(url, out, &hdr, .{
        .timeout_secs = timeout_secs,
        .impersonate = false,
        .use_dpi_proxy = false,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .secret_headers = secret_headers,
        .secret_post_body = body.written(),
        .cancel_epoch = cancel,
    });
    if (res.failure == .cancelled) return error.Cancelled;
    if (!res.ok()) return if (res.status == 0) error.Offline else error.Transport;
    return pure.decodeContent(alloc, res.body) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}
