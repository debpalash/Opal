//! SOCKS5 (RFC 1928) and HTTP CONNECT request parsing.
//!
//! The wire I/O lives in `proxy.zig`; the byte-level parsing lives here and is
//! unit-tested. `proxy.zig` calls these pure parsers on the bytes it reads.

const std = @import("std");

pub const max_host_len = 255; // SOCKS5 domain names are length-prefixed by one byte

/// A parsed CONNECT target: a host (IP literal or domain name) and a port.
pub const Target = struct {
    host_buf: [max_host_len]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,

    pub fn host(self: *const Target) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    fn setHost(self: *Target, h: []const u8) error{HostTooLong}!void {
        if (h.len > max_host_len) return error.HostTooLong;
        @memcpy(self.host_buf[0..h.len], h);
        self.host_len = h.len;
    }
};

pub const ParseError = error{
    BadVersion,
    BadCommand,
    BadAddressType,
    HostTooLong,
    Truncated,
};

/// Parse a SOCKS5 request PDU (everything after the greeting/method
/// negotiation):
///   VER(1)=5 CMD(1)=1(connect) RSV(1)=0 ATYP(1) ADDR(var) PORT(2, big-endian)
///   ATYP: 1=IPv4(4 bytes), 3=domain(len-prefixed), 4=IPv6(16 bytes)
///
/// Returns the parsed target. Only CONNECT is supported.
pub fn parseSocks5Request(buf: []const u8) ParseError!Target {
    if (buf.len < 4) return error.Truncated;
    if (buf[0] != 0x05) return error.BadVersion;
    if (buf[1] != 0x01) return error.BadCommand; // CONNECT only
    // buf[2] is RSV, ignored
    const atyp = buf[3];
    var t: Target = .{};
    var p: usize = 4;
    switch (atyp) {
        0x01 => { // IPv4
            if (buf.len < p + 4 + 2) return error.Truncated;
            var tmp: [15]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}.{d}.{d}.{d}", .{
                buf[p], buf[p + 1], buf[p + 2], buf[p + 3],
            }) catch unreachable;
            try t.setHost(s);
            p += 4;
        },
        0x03 => { // domain name
            if (buf.len < p + 1) return error.Truncated;
            const dlen = buf[p];
            p += 1;
            if (buf.len < p + dlen + 2) return error.Truncated;
            try t.setHost(buf[p .. p + dlen]);
            p += dlen;
        },
        0x04 => { // IPv6
            if (buf.len < p + 16 + 2) return error.Truncated;
            var tmp: [46]u8 = undefined;
            const s = formatIp6(&tmp, buf[p .. p + 16][0..16].*);
            try t.setHost(s);
            p += 16;
        },
        else => return error.BadAddressType,
    }
    t.port = (@as(u16, buf[p]) << 8) | buf[p + 1];
    return t;
}

fn formatIp6(out: *[46]u8, bytes: [16]u8) []const u8 {
    // Simple full form (not compressed); good enough to hand to a resolver.
    const hex = "0123456789abcdef";
    var n: usize = 0;
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        if (i != 0) {
            out[n] = ':';
            n += 1;
        }
        const grp = (@as(u16, bytes[i]) << 8) | bytes[i + 1];
        // print without leading zeros
        var started = false;
        var shift: u4 = 12;
        while (true) {
            const nyb: u4 = @truncate(grp >> shift);
            if (nyb != 0 or started or shift == 0) {
                out[n] = hex[nyb];
                n += 1;
                started = true;
            }
            if (shift == 0) break;
            shift -= 4;
        }
    }
    return out[0..n];
}

/// Parse the request line of an HTTP CONNECT request:
///   "CONNECT host:port HTTP/1.1\r\n"
/// `buf` is the bytes received so far; the line must be terminated by CRLF (or
/// at least LF). Host may be a domain, IPv4, or bracketed IPv6 ("[::1]").
pub fn parseHttpConnect(buf: []const u8) ParseError!Target {
    // find end of first line
    const line_end = std.mem.indexOfScalar(u8, buf, '\n') orelse return error.Truncated;
    var line = buf[0..line_end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

    const method = "CONNECT ";
    if (!std.mem.startsWith(u8, line, method)) return error.BadCommand;
    var rest = line[method.len..];

    // strip trailing " HTTP/x.y"
    if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| rest = rest[0..sp];
    rest = std.mem.trim(u8, rest, " ");
    if (rest.len == 0) return error.Truncated;

    var t: Target = .{};

    if (rest[0] == '[') {
        // bracketed IPv6: [addr]:port
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.Truncated;
        try t.setHost(rest[1..close]);
        const after = rest[close + 1 ..];
        if (after.len < 2 or after[0] != ':') return error.Truncated;
        t.port = std.fmt.parseInt(u16, after[1..], 10) catch return error.Truncated;
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.Truncated;
        try t.setHost(rest[0..colon]);
        t.port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return error.Truncated;
    }
    if (t.host_len == 0) return error.Truncated;
    return t;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseSocks5Request: domain name" {
    // VER CMD RSV ATYP  len  e x a m p l e . c o m   port(443)
    const req = [_]u8{ 0x05, 0x01, 0x00, 0x03, 11 } ++ "example.com".* ++ [_]u8{ 0x01, 0xbb };
    const t = try parseSocks5Request(&req);
    try std.testing.expectEqualStrings("example.com", t.host());
    try std.testing.expectEqual(@as(u16, 443), t.port);
}

test "parseSocks5Request: IPv4 literal" {
    const req = [_]u8{ 0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x1f, 0x90 }; // 127.0.0.1:8080
    const t = try parseSocks5Request(&req);
    try std.testing.expectEqualStrings("127.0.0.1", t.host());
    try std.testing.expectEqual(@as(u16, 8080), t.port);
}

test "parseSocks5Request: IPv6 literal" {
    var req = [_]u8{ 0x05, 0x01, 0x00, 0x04 } ++ @as([16]u8, @splat(0)) ++ [_]u8{ 0x01, 0xbb };
    req[4 + 15] = 1; // ::1
    const t = try parseSocks5Request(&req);
    try std.testing.expectEqualStrings("0:0:0:0:0:0:0:1", t.host());
    try std.testing.expectEqual(@as(u16, 443), t.port);
}

test "parseSocks5Request: errors" {
    try std.testing.expectError(error.Truncated, parseSocks5Request(&[_]u8{ 0x05, 0x01 }));
    try std.testing.expectError(error.BadVersion, parseSocks5Request(&[_]u8{ 0x04, 0x01, 0x00, 0x01 }));
    try std.testing.expectError(error.BadCommand, parseSocks5Request(&[_]u8{ 0x05, 0x02, 0x00, 0x01 })); // BIND
    try std.testing.expectError(error.BadAddressType, parseSocks5Request(&[_]u8{ 0x05, 0x01, 0x00, 0x09 }));
    // domain length says 11 but only 3 bytes present
    try std.testing.expectError(error.Truncated, parseSocks5Request(&[_]u8{ 0x05, 0x01, 0x00, 0x03, 11, 'a', 'b', 'c' }));
}

test "parseHttpConnect: domain" {
    const t = try parseHttpConnect("CONNECT www.google.com:443 HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expectEqualStrings("www.google.com", t.host());
    try std.testing.expectEqual(@as(u16, 443), t.port);
}

test "parseHttpConnect: bracketed IPv6" {
    const t = try parseHttpConnect("CONNECT [2001:db8::1]:8443 HTTP/1.1\r\n");
    try std.testing.expectEqualStrings("2001:db8::1", t.host());
    try std.testing.expectEqual(@as(u16, 8443), t.port);
}

test "parseHttpConnect: LF-only line terminator" {
    const t = try parseHttpConnect("CONNECT example.com:443 HTTP/1.0\n");
    try std.testing.expectEqualStrings("example.com", t.host());
    try std.testing.expectEqual(@as(u16, 443), t.port);
}

test "parseHttpConnect: errors" {
    try std.testing.expectError(error.Truncated, parseHttpConnect("CONNECT example.com:443")); // no newline
    try std.testing.expectError(error.BadCommand, parseHttpConnect("GET / HTTP/1.1\r\n"));
    try std.testing.expectError(error.Truncated, parseHttpConnect("CONNECT \r\n"));
}
