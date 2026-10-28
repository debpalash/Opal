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
const bounded = @import("../core/bounded_process.zig");

pub const Header = pure.Header;
pub const FormField = pure.FormField;

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
    cancel_epoch: ?bounded.CancelEpoch = null,
    /// Follow HTTP redirects (curl -L). Probes of unvetted addresses turn it off.
    follow_redirects: bool = true,
    connect_timeout_secs: u32 = 10,
    /// Explicit method (`-X`), e.g. "POST" with no body, or "DELETE".
    method: ?[]const u8 = null,
    /// Credential headers (Authorization, Api-Key, ...). Fed to curl over a
    /// private stdin pipe (`--config -`) — never in argv / `ps` / crash dumps.
    secret_headers: []const Header = &.{},
    /// "user:password" basic auth, also over stdin.
    secret_basic_auth: ?[]const u8 = null,
    /// Text request body that contains secrets (OAuth client_secret, ...) or is
    /// too large for argv; sent over stdin. Mutually exclusive with post_body.
    secret_post_body: ?[]const u8 = null,
    /// Upload the body from a file (`--data-binary @path`) — binary/large bodies.
    post_body_file: ?[]const u8 = null,
    /// multipart/form-data fields (`-F` / `--form-string`), implies POST.
    form: []const FormField = &.{},
    /// Refuse plain-http on the request and on every redirect hop.
    https_only: bool = false,
    /// curl --max-filesize (rejects an advertised oversized body up front).
    max_filesize: ?u64 = null,
    /// The URL carries a credential in its query string: send it via the
    /// stdin config instead of argv.
    secret_url: bool = false,
    /// When the body overflows `out`, return its head (UTF-8-safe prefix,
    /// `FetchResult.truncated` set) instead of failing with `.truncated`.
    keep_head_on_overflow: bool = false,
    /// stream() only: a caller "stop" switch (e.g. chat barge-in). When it
    /// flips, curl is killed even while the reader is blocked.
    abort_flag: ?*const std.atomic.Value(bool) = null,
    /// stream() only: per-line cap (heap buffer); longer lines are cut on a
    /// UTF-8 boundary and counted in StreamResult.truncated_lines.
    max_line_bytes: usize = 64 * 1024,
    /// stream() only: hard cap on total streamed bytes.
    max_stream_bytes: usize = 64 * 1024 * 1024,
};

pub const Backend = enum { curl, browser_tls };
pub const Failure = enum { none, invalid_input, spawn, transport, malformed_response, truncated, empty, cancelled, timed_out };

pub const FetchResult = struct {
    body: []const u8 = "",
    headers: []const u8 = "",
    status: u16 = 0,
    latency_ms: u32 = 0,
    backend: Backend = .curl,
    failure: Failure = .none,
    /// Body is only the head of an oversized response (keep_head_on_overflow).
    truncated: bool = false,

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
    if (@import("../core/workers.zig").isQuitting()) return .{ .failure = .cancelled };
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

    const config = secretConfig(arena, url, opts) catch return .{ .backend = used_backend, .failure = .invalid_input };
    var spec = specFor(url, token, opts, config.len > 0);
    spec.capture_headers = true;
    spec.write_out = write_out;
    const argv = pure.buildAlloc(arena, spec, proxy) catch return .{ .backend = used_backend, .failure = .invalid_input };

    // Header blocks for redirects precede the body. Leave generous overhead so
    // ordinary redirects do not consume caller body capacity, then drain any
    // excess to ensure curl can always exit.
    const raw_cap = std.math.add(usize, body_out.len, @max(headers_out.len, 64 * 1024)) catch
        return .{ .backend = used_backend, .failure = .invalid_input };
    const raw = alloc.alloc(u8, raw_cap) catch return .{ .backend = used_backend, .failure = .transport };
    defer alloc.free(raw);

    var process = bounded.StreamProcess.init(argv, .{
        .timeout_ms = @as(i64, opts.timeout_secs) * 1000 + 250,
        .terminate_grace_ms = 100,
        .max_output_bytes = raw_cap,
        .cancel_epoch = opts.cancel_epoch,
        .cancel_flag = @import("../core/workers.zig").quittingSignal(),
        .stdin_behavior = if (config.len > 0) .Pipe else .Ignore,
    });
    process.start() catch return .{ .backend = used_backend, .failure = .spawn };
    if (!feedConfig(&process, config)) return .{ .backend = used_backend, .failure = .spawn };
    var raw_len: usize = 0;
    var overflow = false;
    if (process.stdout()) |stdout| {
        while (raw_len < raw.len) {
            const n = io.read(stdout, raw[raw_len..]) catch break;
            if (n == 0) break;
            raw_len += n;
            if (!process.noteOutput(n)) {
                overflow = true;
                break;
            }
        }
        if (raw_len == raw.len) {
            var extra: [1]u8 = undefined;
            const n = io.read(stdout, &extra) catch 0;
            if (n > 0) {
                _ = process.noteOutput(n);
                overflow = true;
                process.requestStop();
            }
        }
    }
    const completion = process.finish();
    if (completion.cancelled) return .{ .backend = used_backend, .failure = .cancelled };
    if (completion.timed_out) return .{ .backend = used_backend, .failure = .timed_out };
    if (overflow or completion.output_limited) {
        if (opts.keep_head_on_overflow) if (pure.parseHead(raw[0..raw_len])) |h|
            return keepHead(h.body, h.status, 0, body_out, used_backend);
        return .{ .backend = used_backend, .failure = .truncated };
    }
    const exited_ok = completion.ok();

    const parsed = pure.parseCapturedOutput(raw[0..raw_len], meta_marker) orelse
        return .{ .backend = used_backend, .failure = if (exited_ok) .malformed_response else .transport };
    if (parsed.body.len > body_out.len and opts.keep_head_on_overflow and exited_ok)
        return keepHead(parsed.body, parsed.status, parsed.latency_ms, body_out, used_backend);
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

fn keepHead(body: []const u8, status: u16, latency_ms: u32, body_out: []u8, used_backend: Backend) FetchResult {
    const head = pure.headPrefix(body, body_out.len);
    @memcpy(body_out[0..head.len], head);
    return .{
        .body = body_out[0..head.len],
        .status = status,
        .latency_ms = latency_ms,
        .backend = used_backend,
        .truncated = true,
        .failure = if (head.len == 0) .empty else .none,
    };
}

fn secretConfig(arena: std.mem.Allocator, url: []const u8, opts: Opts) pure.ConfigError![]const u8 {
    if (opts.secret_post_body != null and (opts.post_body != null or opts.post_body_file != null)) return error.InvalidValue;
    return pure.buildConfig(arena, .{
        .headers = opts.secret_headers,
        .basic_auth = opts.secret_basic_auth,
        .body = opts.secret_post_body,
        .url = if (opts.secret_url) url else null,
    });
}

fn specFor(url: []const u8, token: []const u8, opts: Opts, config_stdin: bool) pure.Spec {
    return .{
        .bin = det_bin_buf[0..det_bin_len],
        .impersonate_token = token,
        .url = if (opts.secret_url) "" else url,
        .user_agent = opts.user_agent,
        .referer = opts.referer,
        .headers = opts.headers,
        .range = opts.range,
        .timeout_secs = opts.timeout_secs,
        .connect_timeout_secs = opts.connect_timeout_secs,
        .follow_redirects = opts.follow_redirects,
        .method_post_body = opts.post_body,
        .method = opts.method,
        .config_stdin = config_stdin,
        .post_body_file = opts.post_body_file,
        .form = opts.form,
        .https_only = opts.https_only,
        .max_filesize = opts.max_filesize,
    };
}

/// Write the secret config to curl's stdin and close it (EOF ends the config).
/// curl parses the whole config before any network I/O, so writing it all
/// before draining stdout cannot deadlock. On failure the process is reaped.
fn feedConfig(process: *bounded.StreamProcess, config: []const u8) bool {
    if (config.len == 0) return true;
    const ok_write = if (process.child.stdin) |*pipe| blk: {
        io.writeAll(pipe, config) catch break :blk false;
        break :blk true;
    } else false;
    process.child.closeStdin();
    if (!ok_write) {
        process.requestStop();
        _ = process.finish();
    }
    return ok_write;
}

pub const DownloadResult = struct {
    status: u16 = 0,
    failure: Failure = .none,
    pub fn ok(self: DownloadResult) bool {
        return self.failure == .none and self.status >= 200 and self.status < 300;
    }
};

/// Download `url` to `dest_path` atomically: curl writes `<dest>.part`, the
/// HTTP status is checked, then the temp file is renamed over `dest`. On any
/// failure the temp file is removed and `dest` is left untouched — a 404 page
/// or a half-written model can never masquerade as the real file.
/// `opts.timeout_secs` bounds the whole transfer (set it high for big files).
pub fn download(url: []const u8, dest_path: []const u8, opts: Opts) DownloadResult {
    if (@import("../core/workers.zig").isQuitting()) return .{ .failure = .cancelled };
    var tmp_buf: [1100]u8 = undefined;
    if (url.len == 0) return .{ .failure = .invalid_input };
    const tmp = pure.downloadTempPath(&tmp_buf, dest_path) orelse return .{ .failure = .invalid_input };
    detect();
    const token = if (opts.impersonate) det_token else "";

    var ar = std.heap.ArenaAllocator.init(alloc);
    defer ar.deinit();
    const arena = ar.allocator();
    const empty = &[_][]const u8{};
    const proxy: []const []const u8 = if (opts.use_dpi_proxy)
        (@import("dpi_bypass.zig").proxyArgs() orelse empty)
    else
        empty;
    const config = secretConfig(arena, url, opts) catch return .{ .failure = .invalid_input };
    var spec = specFor(url, token, opts, config.len > 0);
    spec.output_path = tmp;
    spec.write_out = pure.download_write_out;
    const argv = pure.buildAlloc(arena, spec, proxy) catch return .{ .failure = .invalid_input };

    var process = bounded.StreamProcess.init(argv, .{
        .timeout_ms = @as(i64, opts.timeout_secs) * 1000 + 250,
        .terminate_grace_ms = 250,
        .max_output_bytes = 64,
        .cancel_epoch = opts.cancel_epoch,
        .cancel_flag = @import("../core/workers.zig").quittingSignal(),
        .stdin_behavior = if (config.len > 0) .Pipe else .Ignore,
    });
    process.start() catch return .{ .failure = .spawn };
    if (!feedConfig(&process, config)) {
        io.cwdDeleteFile(tmp) catch {};
        return .{ .failure = .spawn };
    }
    var out: [64]u8 = undefined;
    var n: usize = 0;
    if (process.stdout()) |stdout| {
        while (n < out.len) {
            const got = io.read(stdout, out[n..]) catch break;
            if (got == 0) break;
            n += got;
            if (!process.noteOutput(got)) break;
        }
    }
    const completion = process.finish();
    const status = pure.parseStatus(out[0..n]);
    const failure: Failure = if (completion.cancelled)
        .cancelled
    else if (completion.timed_out)
        .timed_out
    else if (!completion.ok())
        .transport
    else
        .none;
    const result: DownloadResult = .{ .status = status, .failure = failure };
    if (!result.ok()) {
        io.cwdDeleteFile(tmp) catch {};
        return result;
    }
    // cwd-relative rename: works for absolute and relative dest paths alike.
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), dest_path, io.io()) catch {
        io.cwdDeleteFile(tmp) catch {};
        return .{ .status = status, .failure = .transport };
    };
    return result;
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

pub const StreamResult = struct {
    /// Final HTTP status (known from the response headers before the first
    /// line is delivered; confirmed by the write-out at EOF).
    status: u16 = 0,
    latency_ms: u32 = 0,
    backend: Backend = .curl,
    failure: Failure = .none,
    /// The callback returned false (caller ended the stream early — not a failure).
    stopped: bool = false,
    lines: usize = 0,
    truncated_lines: usize = 0,

    pub fn ok(self: StreamResult) bool {
        return self.failure == .none and pure.successfulStatus(self.status);
    }
};

/// Streamed request (curl `-N`): every response body line is handed to
/// `onLine(ctx, line)` as it arrives (no trailing newline) — SSE / NDJSON
/// friendly; parse `data:` fields with `pure.sseData`. Return false from the
/// callback to stop early (curl is killed; `stopped` set). `opts.abort_flag`,
/// `opts.cancel_epoch` and app shutdown kill curl even while blocked on read
/// (`failure = .cancelled`). Lines are buffered on the heap, bounded by
/// `opts.max_line_bytes`. Secrets go through secret_headers / secret_post_body
/// exactly as for request().
pub fn stream(url: []const u8, opts: Opts, ctx: anytype, comptime onLine: fn (@TypeOf(ctx), []const u8) bool) StreamResult {
    const workers = @import("../core/workers.zig");
    if (workers.isQuitting()) return .{ .failure = .cancelled };
    if (url.len == 0 or opts.max_line_bytes == 0) return .{ .failure = .invalid_input };
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
    const config = secretConfig(arena, url, opts) catch return .{ .backend = used_backend, .failure = .invalid_input };
    var spec = specFor(url, token, opts, config.len > 0);
    spec.capture_headers = true;
    spec.write_out = write_out;
    spec.no_buffer = true;
    const argv = pure.buildAlloc(arena, spec, proxy) catch return .{ .backend = used_backend, .failure = .invalid_input };

    const line_buf = alloc.alloc(u8, opts.max_line_bytes) catch return .{ .backend = used_backend, .failure = .transport };
    defer alloc.free(line_buf);
    var decoder = pure.LineDecoder{ .buf = line_buf };

    var process = bounded.StreamProcess.init(argv, .{
        .timeout_ms = @as(i64, opts.timeout_secs) * 1000 + 250,
        .terminate_grace_ms = 100,
        .max_output_bytes = opts.max_stream_bytes,
        .cancel_epoch = opts.cancel_epoch,
        .cancel_flag = workers.quittingSignal(),
        .abort_flag = opts.abort_flag,
        .stdin_behavior = if (config.len > 0) .Pipe else .Ignore,
    });
    process.start() catch return .{ .backend = used_backend, .failure = .spawn };
    if (!feedConfig(&process, config)) return .{ .backend = used_backend, .failure = .spawn };

    var stopped = false;
    var overflow = false;
    if (process.stdout()) |stdout| {
        var chunk: [4096]u8 = undefined;
        while (true) {
            if (opts.abort_flag) |f| if (f.load(.acquire)) break;
            const n = io.read(stdout, &chunk) catch break;
            if (n == 0) break;
            if (!process.noteOutput(n)) {
                overflow = true;
                break;
            }
            if (!decoder.feed(chunk[0..n], ctx, onLine)) {
                stopped = true;
                process.requestStop();
                break;
            }
        }
    }
    const completion = process.finish();
    const aborted = if (opts.abort_flag) |f| f.load(.acquire) else false;
    const fin = decoder.finish(meta_marker, !stopped and !aborted and !completion.cancelled, ctx, onLine);
    var result: StreamResult = .{
        .status = fin.status,
        .latency_ms = fin.latency_ms,
        .backend = used_backend,
        .stopped = stopped,
        .lines = decoder.lines,
        .truncated_lines = decoder.truncated_lines,
    };
    result.failure = if (stopped)
        .none
    else if (completion.cancelled or aborted)
        .cancelled
    else if (completion.timed_out)
        .timed_out
    else if (overflow or completion.output_limited)
        .truncated
    else if (!completion.ok())
        .transport
    else if (!fin.meta)
        .malformed_response
    else if (decoder.lines == 0)
        .empty
    else
        .none;
    return result;
}
