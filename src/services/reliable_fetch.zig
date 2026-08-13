//! Unified reliable-fetch seam: one entry every source's content/CDN fetch can
//! route through, with browser TLS/HTTP2 impersonation (curl-impersonate when
//! present) + DPI-proxy chaining (dpi_bypass) + first-class headers. Argv is
//! built by the tested reliable_fetch_pure; when curl-impersonate isn't
//! installed, this degrades to plain curl (impersonation silently no-ops).

const std = @import("std");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const pure = @import("reliable_fetch_pure.zig");

pub const Header = pure.Header;

// lexiforest curl-impersonate wrapper (Chrome BoringSSL). Bundled into
// Resources/ or downloaded to ~/.config/opal/bin (like yt-dlp); else plain curl.
const IMPERSONATE_BIN = "curl-impersonate-chrome";
const IMPERSONATE_TOKEN = "chrome131";

var det_done: bool = false;
var det_bin_buf: [700]u8 = undefined;
var det_bin_len: usize = 0;
var det_token: []const u8 = "";
var det_mutex = sync.Mutex{};

fn setBin(b: []const u8, tok: []const u8) void {
    const n = @min(b.len, det_bin_buf.len);
    @memcpy(det_bin_buf[0..n], b[0..n]);
    det_bin_len = n;
    det_token = tok;
}

fn detectLocked() void {
    if (det_done) return;
    det_done = true;
    var pb: [800]u8 = undefined;
    if (state.resourceRoot()) |r| {
        if (std.fmt.bufPrint(&pb, "{s}/{s}", .{ r, IMPERSONATE_BIN })) |p| {
            if (io.cwdAccess(p, .{})) {
                setBin(p, IMPERSONATE_TOKEN);
                return;
            } else |_| {}
        } else |_| {}
    }
    var cfg: [512]u8 = undefined;
    const c = @import("../core/paths.zig").configDir(&cfg);
    if (std.fmt.bufPrint(&pb, "{s}/bin/{s}", .{ c, IMPERSONATE_BIN })) |p| {
        if (io.cwdAccess(p, .{})) {
            setBin(p, IMPERSONATE_TOKEN);
            return;
        } else |_| {}
    } else |_| {}
    setBin("curl", ""); // no impersonation backend → plain curl
}

/// Publish the backend exactly once. Every caller crosses the same mutex even
/// after initialization so reads of the immutable buffer/token have a proper
/// happens-before edge; startup fans out several source workers concurrently.
fn detect() void {
    det_mutex.lock();
    defer det_mutex.unlock();
    detectLocked();
}

/// True when a curl-impersonate backend is available (browser JA3/JA4 in use).
pub fn impersonating() bool {
    detect();
    return det_token.len > 0;
}

/// The resolved binary + impersonate token, for callers that build their own
/// argv (e.g. scrape_fetch, which also captures response headers). `token` is ""
/// when no impersonation backend is installed.
pub fn backend() struct { bin: []const u8, token: []const u8 } {
    detect();
    return .{ .bin = det_bin_buf[0..det_bin_len], .token = det_token };
}

pub const Opts = struct {
    user_agent: ?[]const u8 = null,
    referer: ?[]const u8 = null,
    headers: []const Header = &.{},
    range: ?[]const u8 = null,
    timeout_secs: u32 = 15,
    /// Use the browser-TLS backend when available (content/CDN fetches). Set
    /// false for latency-sensitive plain-JSON APIs that aren't fingerprint-walled.
    impersonate: bool = true,
    /// Chain through the DPI-bypass proxy when it's enabled+running.
    use_dpi_proxy: bool = true,
    post_body: ?[]const u8 = null,
};

pub const Backend = enum { curl, browser_tls };
pub const Failure = enum { none, invalid_input, spawn, transport, malformed_response, truncated, empty };

pub const FetchResult = struct {
    body: []const u8 = "",
    headers: []const u8 = "",
    status: u16 = 0,
    latency_ms: u32 = 0,
    backend: Backend = .curl,
    failure: Failure = .none,

    pub fn ok(self: FetchResult) bool {
        return self.failure == .none and pure.successfulStatus(self.status);
    }
};

const meta_marker = "OPAL_FETCH_META:";
const write_out = "\\n" ++ meta_marker ++ "%{http_code}:%{time_total}";

/// Execute one reliable request and return transport metadata through the same
/// seam as the body. Callers own both output buffers; returned slices alias
/// them and remain valid until the next caller mutation.
pub fn request(url: []const u8, body_out: []u8, headers_out: []u8, opts: Opts) FetchResult {
    if (url.len == 0 or body_out.len == 0) return .{ .failure = .invalid_input };
    detect();
    const token = if (opts.impersonate) det_token else "";
    const used_backend: Backend = if (token.len > 0) .browser_tls else .curl;

    var ar = std.heap.ArenaAllocator.init(alloc);
    defer ar.deinit();
    const arena = ar.allocator();
    const empty = &[_][]const u8{};
    const proxy: []const []const u8 = if (opts.use_dpi_proxy)
        (@import("dpi_bypass.zig").proxyArgs() orelse empty)
    else
        empty;

    const argv = pure.buildAlloc(arena, .{
        .bin = det_bin_buf[0..det_bin_len],
        .impersonate_token = token,
        .url = url,
        .user_agent = opts.user_agent,
        .referer = opts.referer,
        .headers = opts.headers,
        .range = opts.range,
        .timeout_secs = opts.timeout_secs,
        .method_post_body = opts.post_body,
        .capture_headers = true,
        .write_out = write_out,
    }, proxy) catch return .{ .backend = used_backend, .failure = .invalid_input };

    // Header blocks for redirects precede the body. Leave generous overhead so
    // ordinary redirects do not consume caller body capacity, then drain any
    // excess to ensure curl can always exit.
    const raw_cap = std.math.add(usize, body_out.len, @max(headers_out.len, 64 * 1024)) catch
        return .{ .backend = used_backend, .failure = .invalid_input };
    const raw = alloc.alloc(u8, raw_cap) catch return .{ .backend = used_backend, .failure = .transport };
    defer alloc.free(raw);

    var child = io.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return .{ .backend = used_backend, .failure = .spawn };

    var raw_len: usize = 0;
    var overflow = false;
    if (child.stdout) |*stdout| {
        while (raw_len < raw.len) {
            const n = io.read(stdout, raw[raw_len..]) catch break;
            if (n == 0) break;
            raw_len += n;
        }
        var drain: [4096]u8 = undefined;
        while (true) {
            const n = io.read(stdout, &drain) catch break;
            if (n == 0) break;
            overflow = true;
        }
    }
    const term = child.wait() catch return .{ .backend = used_backend, .failure = .transport };
    const exited_ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (overflow) return .{ .backend = used_backend, .failure = .truncated };

    const parsed = pure.parseCapturedOutput(raw[0..raw_len], meta_marker) orelse
        return .{ .backend = used_backend, .failure = if (exited_ok) .malformed_response else .transport };
    if (parsed.body.len > body_out.len or parsed.headers.len > headers_out.len)
        return .{ .backend = used_backend, .status = parsed.status, .latency_ms = parsed.latency_ms, .failure = .truncated };
    @memcpy(body_out[0..parsed.body.len], parsed.body);
    @memcpy(headers_out[0..parsed.headers.len], parsed.headers);
    return .{
        .body = body_out[0..parsed.body.len],
        .headers = headers_out[0..parsed.headers.len],
        .status = parsed.status,
        .latency_ms = parsed.latency_ms,
        .backend = used_backend,
        .failure = if (!exited_ok) .transport else if (parsed.body.len == 0) .empty else .none,
    };
}

/// Fetch `url` into `out`; returns the filled slice or null. Thread-safe (spawns
/// its own curl); large `out` should be heap-allocated off a worker stack.
pub fn fetch(url: []const u8, out: []u8, opts: Opts) ?[]const u8 {
    var headers: [16 * 1024]u8 = undefined;
    const result = request(url, out, &headers, opts);
    // A non-empty error document is still an HTTP failure. Keeping this policy
    // in the deep fetch seam prevents every source from having to remember a
    // status check (and prevents a CDN 403 page being parsed as real content).
    if (!result.ok()) return null;
    return result.body;
}
