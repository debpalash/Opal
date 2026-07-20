//! Unified reliable-fetch seam: one entry every source's content/CDN fetch can
//! route through, with browser TLS/HTTP2 impersonation (curl-impersonate when
//! present) + DPI-proxy chaining (dpi_bypass) + first-class headers. Argv is
//! built by the tested reliable_fetch_pure; when curl-impersonate isn't
//! installed, this degrades to plain curl (impersonation silently no-ops).

const std = @import("std");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const state = @import("../core/state.zig");
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

fn setBin(b: []const u8, tok: []const u8) void {
    const n = @min(b.len, det_bin_buf.len);
    @memcpy(det_bin_buf[0..n], b[0..n]);
    det_bin_len = n;
    det_token = tok;
}

fn detect() void {
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

/// Fetch `url` into `out`; returns the filled slice or null. Thread-safe (spawns
/// its own curl); large `out` should be heap-allocated off a worker stack.
pub fn fetch(url: []const u8, out: []u8, opts: Opts) ?[]const u8 {
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
    }, proxy) catch return null;

    var child = io.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const n = if (child.stdout) |*so| io.readAll(so, out) catch 0 else 0;
    _ = child.wait() catch {};
    if (n == 0) return null;
    return out[0..n];
}
