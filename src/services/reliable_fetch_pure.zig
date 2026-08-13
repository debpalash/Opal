//! Pure curl / curl-impersonate argv construction for the unified reliable-fetch
//! seam — one place every source's HTTP argv is assembled, with browser TLS
//! impersonation + DPI-proxy chaining + first-class headers. The impure fetch()
//! routes through build() so the shipped command is the tested command.

const std = @import("std");

pub const Header = struct { name: []const u8, value: []const u8 };

/// HTTP success policy shared by the typed request result and the convenience
/// `fetch` path. Redirects count because callers may deliberately disable
/// follow_redirects; client/server error documents never count as content.
pub fn successfulStatus(status: u16) bool {
    return status >= 200 and status < 400;
}

pub const Spec = struct {
    /// Resolved binary: a curl-impersonate wrapper (browser JA3/JA4) or "curl".
    bin: []const u8,
    /// curl-impersonate `--impersonate <token>` (e.g. "chrome131"); "" = plain.
    impersonate_token: []const u8 = "",
    url: []const u8,
    user_agent: ?[]const u8 = null,
    referer: ?[]const u8 = null,
    headers: []const Header = &.{},
    method_post_body: ?[]const u8 = null,
    range: ?[]const u8 = null, // "0-2047" for health probes
    timeout_secs: u32 = 15,
    connect_timeout_secs: u32 = 10,
    follow_redirects: bool = true,
    insecure: bool = false,
    capture_headers: bool = false,
    write_out: ?[]const u8 = null,
};

/// Append the full argv for `spec` into `out` (allocating formatted args from
/// `arena`). `proxy_args` (e.g. dpi_bypass.proxyArgs() → `--socks5-hostname
/// 127.0.0.1:8881`, or `&.{}`) chains the DPI proxy — orthogonal to the TLS
/// impersonation, both can be on. URL is always last.
pub fn build(arena: std.mem.Allocator, spec: Spec, proxy_args: []const []const u8, out: *std.ArrayList([]const u8)) !void {
    try out.append(arena, spec.bin);
    try out.append(arena, "-sS"); // silent, but surface errors
    try out.append(arena, "--compressed"); // gzip/br — most hosts serve it
    if (spec.follow_redirects) try out.append(arena, "-L");
    if (spec.insecure) try out.append(arena, "-k");

    // Browser TLS/HTTP2 impersonation (curl-impersonate). Omitted for plain curl.
    if (spec.impersonate_token.len > 0) {
        try out.append(arena, "--impersonate");
        try out.append(arena, spec.impersonate_token);
    }

    try out.append(arena, "--max-time");
    try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{spec.timeout_secs}));
    try out.append(arena, "--connect-timeout");
    try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{spec.connect_timeout_secs}));

    if (spec.range) |r| {
        try out.append(arena, "-r");
        try out.append(arena, r);
    }

    if (spec.capture_headers) {
        try out.append(arena, "--dump-header");
        try out.append(arena, "-");
    }
    if (spec.write_out) |format| {
        try out.append(arena, "--write-out");
        try out.append(arena, format);
    }

    // User-Agent: force it for plain curl; when impersonating, only if the caller
    // overrides (else curl-impersonate's authentic UA wins).
    if (spec.impersonate_token.len == 0) {
        try out.append(arena, "-A");
        try out.append(arena, spec.user_agent orelse "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    } else if (spec.user_agent) |ua| {
        try out.append(arena, "-A");
        try out.append(arena, ua);
    }

    if (spec.referer) |ref| {
        try out.append(arena, "-H");
        try out.append(arena, try std.fmt.allocPrint(arena, "Referer: {s}", .{ref}));
    }
    for (spec.headers) |h| {
        try out.append(arena, "-H");
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ h.name, h.value }));
    }

    if (spec.method_post_body) |body| {
        try out.append(arena, "--data-binary");
        try out.append(arena, body);
    }

    // DPI proxy (SNI-fragmenting SOCKS5) — chained onto the impersonated request.
    for (proxy_args) |a| try out.append(arena, a);

    try out.append(arena, spec.url);
}

pub fn buildAlloc(arena: std.mem.Allocator, spec: Spec, proxy_args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try build(arena, spec, proxy_args, &out);
    return out.items;
}

// ── Tests ──
fn has(a: []const []const u8, s: []const u8) bool {
    for (a) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}
fn idx(a: []const []const u8, s: []const u8) ?usize {
    for (a, 0..) |x, i| if (std.mem.eql(u8, x, s)) return i;
    return null;
}

test "impersonated request carries the token + no forced UA + url last" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const argv = try buildAlloc(ar.allocator(), .{ .bin = "curl-impersonate-chrome", .impersonate_token = "chrome131", .url = "https://x.test" }, &.{});
    try std.testing.expectEqualStrings("curl-impersonate-chrome", argv[0]);
    try std.testing.expect(has(argv, "--impersonate") and has(argv, "chrome131"));
    try std.testing.expect(!has(argv, "-A")); // authentic UA wins
    try std.testing.expectEqualStrings("https://x.test", argv[argv.len - 1]);
}

test "plain curl forces a UA and omits --impersonate" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const argv = try buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "https://x.test" }, &.{});
    try std.testing.expect(!has(argv, "--impersonate"));
    try std.testing.expect(has(argv, "-A"));
}

test "proxy args + referer + range chain in" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const proxy = [_][]const u8{ "--socks5-hostname", "127.0.0.1:8881" };
    const argv = try buildAlloc(ar.allocator(), .{ .bin = "curl", .url = "https://x/y.m3u8", .referer = "https://x/", .range = "0-2047" }, &proxy);
    const pi = idx(argv, "--socks5-hostname") orelse return error.NoProxy;
    try std.testing.expectEqualStrings("127.0.0.1:8881", argv[pi + 1]);
    try std.testing.expect(has(argv, "Referer: https://x/"));
    const ri = idx(argv, "-r") orelse return error.NoRange;
    try std.testing.expectEqualStrings("0-2047", argv[ri + 1]);
    // url still last, proxy before it.
    try std.testing.expectEqualStrings("https://x/y.m3u8", argv[argv.len - 1]);
    try std.testing.expect(pi < argv.len - 1);
}

test "metadata capture stays before the final URL" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const argv = try buildAlloc(ar.allocator(), .{
        .bin = "curl",
        .url = "https://x.test/a",
        .capture_headers = true,
        .write_out = "\\nOPAL:%{http_code}",
    }, &.{});
    try std.testing.expect(has(argv, "--dump-header"));
    try std.testing.expect(has(argv, "--write-out"));
    try std.testing.expectEqualStrings("https://x.test/a", argv[argv.len - 1]);
}

pub const ParsedOutput = struct {
    body: []const u8,
    headers: []const u8,
    status: u16,
    latency_ms: u32,
};

/// Split the single stdout stream emitted by `--dump-header -` plus the
/// write-out marker. Keeping metadata on the body pipe avoids the classic
/// stdout/stderr two-pipe deadlock. The returned slices alias `raw`.
pub fn parseCapturedOutput(raw: []const u8, marker: []const u8) ?ParsedOutput {
    const meta_pos = std.mem.lastIndexOf(u8, raw, marker) orelse return null;
    var body_end = meta_pos;
    if (body_end > 0 and raw[body_end - 1] == '\n') body_end -= 1;

    const meta = raw[meta_pos + marker.len ..];
    var fields = std.mem.splitScalar(u8, std.mem.trim(u8, meta, " \r\n"), ':');
    const status = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    const seconds = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0;
    const latency_ms: u32 = if (seconds > 0) @intFromFloat(@min(seconds * 1000.0, @as(f64, std.math.maxInt(u32)))) else 0;

    var pos: usize = 0;
    var final_start: usize = 0;
    var final_end: usize = 0;
    while (pos < body_end and std.mem.startsWith(u8, raw[pos..body_end], "HTTP/")) {
        const rel_end = std.mem.indexOf(u8, raw[pos..body_end], "\r\n\r\n") orelse return null;
        final_start = pos;
        final_end = pos + rel_end + 4;
        pos = final_end;
    }
    return .{
        .body = raw[pos..body_end],
        .headers = raw[final_start..final_end],
        .status = status,
        .latency_ms = latency_ms,
    };
}

test "captured output parser keeps final redirect headers and binary-safe body" {
    const raw = "HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\n" ++
        "HTTP/2 200 OK\r\nContent-Type: text/plain\r\n\r\nhello\x00world\n" ++
        "OPAL_FETCH_META:200:0.125";
    const parsed = parseCapturedOutput(raw, "OPAL_FETCH_META:").?;
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expectEqual(@as(u32, 125), parsed.latency_ms);
    try std.testing.expectEqualStrings("HTTP/2 200 OK\r\nContent-Type: text/plain\r\n\r\n", parsed.headers);
    try std.testing.expectEqualSlices(u8, "hello\x00world", parsed.body);
}

test "HTTP success policy rejects non-empty error responses" {
    try std.testing.expect(successfulStatus(200));
    try std.testing.expect(successfulStatus(206));
    try std.testing.expect(successfulStatus(302));
    try std.testing.expect(!successfulStatus(0));
    try std.testing.expect(!successfulStatus(404));
    try std.testing.expect(!successfulStatus(429));
    try std.testing.expect(!successfulStatus(500));
}
