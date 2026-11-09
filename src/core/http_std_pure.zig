//! Pure decisions for the std.http reliable-fetch backend (Android has no curl
//! binary). http_std.zig routes its shipped logic through these.
const std = @import("std");

pub const max_redirects = 5;

pub const Fail = enum { transport, timed_out, cancelled, invalid_input };

/// Map a std.http / Io error name to a failure class. Canceled -> cancelled,
/// Timeout -> timed_out, everything else is a transport failure.
pub fn failFromError(name: []const u8) Fail {
    if (std.mem.eql(u8, name, "Canceled")) return .cancelled;
    if (std.mem.eql(u8, name, "Timeout")) return .timed_out;
    return .transport;
}

pub fn isRedirect(status: u16) bool {
    return switch (status) {
        301, 302, 303, 307, 308 => true,
        else => false,
    };
}

/// 303 always becomes GET (except HEAD); 301/302 downgrade POST to GET.
pub fn redirectDropsBody(status: u16, is_post: bool, is_head: bool) bool {
    return (status == 303 and !is_head) or ((status == 301 or status == 302) and is_post);
}

pub fn schemeAllowed(scheme: []const u8, https_only: bool) bool {
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return true;
    return !https_only and std.ascii.eqlIgnoreCase(scheme, "http");
}

pub fn sameOrigin(a_scheme: []const u8, a_host: []const u8, a_port: ?u16, b_scheme: []const u8, b_host: []const u8, b_port: ?u16) bool {
    if (!std.ascii.eqlIgnoreCase(a_scheme, b_scheme)) return false;
    const def: u16 = if (std.ascii.eqlIgnoreCase(a_scheme, "https")) 443 else 80;
    return (a_port orelse def) == (b_port orelse def) and std.ascii.eqlIgnoreCase(a_host, b_host);
}

pub fn validHeader(name: []const u8, value: []const u8) bool {
    return name.len != 0 and std.mem.indexOfAny(u8, name, ":\r\n") == null and
        std.mem.indexOfAny(u8, value, "\r\n") == null;
}

pub fn isCredentialHeader(name: []const u8) bool {
    const names = [_][]const u8{ "authorization", "proxy-authorization", "cookie", "api-key", "x-api-key" };
    for (names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}

/// "Basic <b64>" for user:password credentials.
pub fn basicAuthValue(arena: std.mem.Allocator, creds: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try arena.alloc(u8, enc.calcSize(creds.len));
    _ = enc.encode(b64, creds);
    return std.fmt.allocPrint(arena, "Basic {s}", .{b64});
}

pub const HeaderInputs = struct {
    user_agent: ?[]const u8 = null,
    referer: ?[]const u8 = null,
    range: ?[]const u8 = null,
    basic_auth: ?[]const u8 = null,
};

/// Build the outgoing header list: caller headers, secret headers, then the
/// first-class ones. When `cross_origin`, credential headers and Referer are
/// dropped (never forward secrets to another origin after a redirect); Range
/// survives. Returns error.InvalidHeader on CR/LF/colon injection.
pub fn buildHeaders(
    arena: std.mem.Allocator,
    headers: []const std.http.Header,
    secret_headers: []const std.http.Header,
    inp: HeaderInputs,
    cross_origin: bool,
) error{ InvalidHeader, OutOfMemory }![]const std.http.Header {
    var out: std.ArrayList(std.http.Header) = .empty;
    for ([_][]const std.http.Header{ headers, secret_headers }) |set| for (set) |h| {
        if (!validHeader(h.name, h.value)) return error.InvalidHeader;
        if (cross_origin and (isCredentialHeader(h.name) or std.ascii.eqlIgnoreCase(h.name, "referer"))) continue;
        try out.append(arena, h);
    };
    if (inp.user_agent) |v| try out.append(arena, .{ .name = "User-Agent", .value = v });
    if (!cross_origin) if (inp.referer) |v| try out.append(arena, .{ .name = "Referer", .value = v });
    if (inp.range) |v| try out.append(arena, .{ .name = "Range", .value = v });
    if (!cross_origin) if (inp.basic_auth) |c| try out.append(arena, .{ .name = "Authorization", .value = try basicAuthValue(arena, c) });
    for (out.items) |h| if (!validHeader(h.name, h.value)) return error.InvalidHeader;
    return out.items;
}

/// Effective in-memory body cap: caller buffer clamped by max_filesize.
pub fn bodyCap(buf_len: usize, max_filesize: ?u64) usize {
    const m = max_filesize orelse return buf_len;
    return @intCast(@min(@as(u64, buf_len), m));
}

pub const Outcome = enum { ok, truncated_head, truncated_fail, empty };

/// Decide the result once the body has been consumed. `overflow` = more bytes
/// than the cap arrived.
pub fn bodyOutcome(filled: usize, overflow: bool, keep_head: bool) Outcome {
    if (overflow) {
        if (!keep_head) return .truncated_fail;
        return if (filled == 0) .empty else .truncated_head;
    }
    return if (filled == 0) .empty else .ok;
}

/// Overall deadline for a request: timeout_secs (min 1s) in ms.
pub fn deadlineMs(timeout_secs: u32) i64 {
    return @as(i64, @max(1, timeout_secs)) * 1000;
}

/// Parse an explicit method name; null when unsupported.
pub fn parseMethod(name: ?[]const u8, has_body: bool) ?std.http.Method {
    const n = name orelse return if (has_body) .POST else .GET;
    return std.meta.stringToEnum(std.http.Method, n);
}

test "failFromError maps cancel/timeout/other" {
    try std.testing.expectEqual(Fail.cancelled, failFromError("Canceled"));
    try std.testing.expectEqual(Fail.timed_out, failFromError("Timeout"));
    try std.testing.expectEqual(Fail.transport, failFromError("TlsInitializationFailed"));
}

test "redirect rules" {
    try std.testing.expect(isRedirect(302) and !isRedirect(304) and !isRedirect(200));
    try std.testing.expect(redirectDropsBody(303, true, false));
    try std.testing.expect(redirectDropsBody(302, true, false));
    try std.testing.expect(!redirectDropsBody(307, true, false));
    try std.testing.expect(!redirectDropsBody(302, false, false));
}

test "https_only refuses plain http" {
    try std.testing.expect(!schemeAllowed("http", true));
    try std.testing.expect(schemeAllowed("HTTPS", true));
    try std.testing.expect(schemeAllowed("http", false));
    try std.testing.expect(!schemeAllowed("file", false));
}

test "buildHeaders: authorization kept same-origin, stripped cross-origin" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const sec = [_]std.http.Header{.{ .name = "Authorization", .value = "Bearer x" }};
    const plain = [_]std.http.Header{.{ .name = "Accept", .value = "application/json" }};
    const same = try buildHeaders(a, &plain, &sec, .{ .user_agent = "ua", .referer = "r", .range = "bytes=0-9", .basic_auth = "u:p" }, false);
    try std.testing.expectEqual(@as(usize, 6), same.len);
    try std.testing.expectEqualStrings("Basic dTpw", same[5].value);
    const cross = try buildHeaders(a, &plain, &sec, .{ .user_agent = "ua", .referer = "r", .range = "bytes=0-9", .basic_auth = "u:p" }, true);
    try std.testing.expectEqual(@as(usize, 3), cross.len); // Accept, UA, Range
}

test "buildHeaders rejects header injection" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const bad = [_]std.http.Header{.{ .name = "X", .value = "a\r\nB: c" }};
    try std.testing.expectError(error.InvalidHeader, buildHeaders(ar.allocator(), &bad, &.{}, .{}, false));
}

test "bodyCap honors max_filesize" {
    try std.testing.expectEqual(@as(usize, 100), bodyCap(100, null));
    try std.testing.expectEqual(@as(usize, 10), bodyCap(100, 10));
    try std.testing.expectEqual(@as(usize, 100), bodyCap(100, 1 << 40));
}

test "bodyOutcome" {
    try std.testing.expectEqual(Outcome.ok, bodyOutcome(5, false, false));
    try std.testing.expectEqual(Outcome.empty, bodyOutcome(0, false, false));
    try std.testing.expectEqual(Outcome.truncated_fail, bodyOutcome(5, true, false));
    try std.testing.expectEqual(Outcome.truncated_head, bodyOutcome(5, true, true));
}

test "parseMethod defaults and explicit" {
    try std.testing.expectEqual(std.http.Method.GET, parseMethod(null, false).?);
    try std.testing.expectEqual(std.http.Method.POST, parseMethod(null, true).?);
    try std.testing.expectEqual(std.http.Method.DELETE, parseMethod("DELETE", false).?);
    try std.testing.expect(parseMethod("BOGUS", false) == null);
}

test "sameOrigin" {
    try std.testing.expect(sameOrigin("https", "a.com", null, "HTTPS", "A.com", 443));
    try std.testing.expect(!sameOrigin("https", "a.com", null, "https", "b.a.com", null));
    try std.testing.expect(!sameOrigin("https", "a.com", null, "http", "a.com", null));
}

test "regression: Android has no curl - deadline is at least 1s" {
    try std.testing.expectEqual(@as(i64, 1000), deadlineMs(0));
    try std.testing.expectEqual(@as(i64, 15000), deadlineMs(15));
}
