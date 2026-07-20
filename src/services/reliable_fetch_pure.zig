//! Pure curl / curl-impersonate argv construction for the unified reliable-fetch
//! seam — one place every source's HTTP argv is assembled, with browser TLS
//! impersonation + DPI-proxy chaining + first-class headers. The impure fetch()
//! routes through build() so the shipped command is the tested command.

const std = @import("std");

pub const Header = struct { name: []const u8, value: []const u8 };

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
