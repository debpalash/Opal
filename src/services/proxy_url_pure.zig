//! Parse the `proxy_url` setting into the parts libtorrent's settings_pack
//! wants. Pure (no allocation, no io_global) so it unit-tests standalone and the
//! shipped parse IS the tested parse.
//!
//! This exists because `proxy_url` was a dead setting: stored in state, written
//! to config, rendered in Settings > Network, and read by nothing anywhere in
//! the codebase. A user on a network that blocks BitTorrent would set it, see no
//! change, and get no explanation.
//!
//! Accepts what a person actually types: with or without a scheme, with or
//! without credentials, IPv4/IPv6/hostname.
//!
//!     socks5://user:pw@127.0.0.1:1080
//!     socks5h://10.0.0.1:1080     (the `h` variant means "resolve at the proxy",
//!                                  which we do unconditionally — see
//!                                  proxy_hostnames in the wrapper)
//!     127.0.0.1:8881              (bare host:port → socks5, the common case:
//!                                  Opal's own DPI-bypass sidecar)
//!     http://proxy.lan:3128

const std = @import("std");

pub const Scheme = enum {
    socks5,
    socks4,
    http,

    pub fn text(self: Scheme) []const u8 {
        return switch (self) {
            .socks5 => "socks5",
            .socks4 => "socks4",
            .http => "http",
        };
    }
};

pub const Proxy = struct {
    scheme: Scheme,
    host: []const u8,
    port: u16,
    user: []const u8 = "",
    pass: []const u8 = "",
};

/// Parse `raw` into a Proxy, or null when it is empty or malformed.
///
/// Returning null rather than a partial result matters: the caller clears the
/// proxy on null, and a half-parsed host would silently send traffic somewhere
/// the user did not ask for.
pub fn parse(raw: []const u8) ?Proxy {
    var rest = std.mem.trim(u8, raw, " \t\r\n");
    if (rest.len == 0) return null;

    var scheme: Scheme = .socks5; // bare host:port is almost always a SOCKS5 sidecar
    if (std.mem.indexOf(u8, rest, "://")) |i| {
        const s = rest[0..i];
        rest = rest[i + 3 ..];
        // socks5h / socks4a are the "resolve at the proxy" spellings; we always
        // resolve at the proxy, so they map onto the same types.
        if (eqIgnoreCase(s, "socks5") or eqIgnoreCase(s, "socks5h")) {
            scheme = .socks5;
        } else if (eqIgnoreCase(s, "socks4") or eqIgnoreCase(s, "socks4a")) {
            scheme = .socks4;
        } else if (eqIgnoreCase(s, "http") or eqIgnoreCase(s, "https")) {
            scheme = .http;
        } else return null; // an unknown scheme is a typo, not a default
    }

    // Trailing path/query is meaningless for a proxy endpoint; drop it so
    // "socks5://host:1080/" parses rather than failing on the slash.
    if (std.mem.indexOfAny(u8, rest, "/?#")) |i| rest = rest[0..i];

    var user: []const u8 = "";
    var pass: []const u8 = "";
    // lastIndexOfScalar: a password may legitimately contain '@'.
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const creds = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, creds, ':')) |c| {
            user = creds[0..c];
            pass = creds[c + 1 ..];
        } else user = creds;
    }
    if (rest.len == 0) return null;

    // [::1]:1080 — the brackets exist precisely because a bare IPv6 literal is
    // full of colons, so find the port after the closing bracket.
    var host: []const u8 = undefined;
    var port_str: []const u8 = undefined;
    if (rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        host = rest[1..close];
        const after = rest[close + 1 ..];
        if (after.len < 2 or after[0] != ':') return null;
        port_str = after[1..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return null;
        host = rest[0..colon];
        port_str = rest[colon + 1 ..];
    }
    if (host.len == 0 or port_str.len == 0) return null;

    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    if (port == 0) return null;

    return .{ .scheme = scheme, .host = host, .port = port, .user = user, .pass = pass };
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

test "bare host:port defaults to socks5" {
    const p = parse("127.0.0.1:8881").?;
    try std.testing.expectEqual(Scheme.socks5, p.scheme);
    try std.testing.expectEqualStrings("127.0.0.1", p.host);
    try std.testing.expectEqual(@as(u16, 8881), p.port);
    try std.testing.expectEqualStrings("", p.user);
}

test "every accepted scheme spelling" {
    try std.testing.expectEqual(Scheme.socks5, parse("socks5://h:1").?.scheme);
    try std.testing.expectEqual(Scheme.socks5, parse("SOCKS5H://h:1").?.scheme);
    try std.testing.expectEqual(Scheme.socks4, parse("socks4://h:1").?.scheme);
    try std.testing.expectEqual(Scheme.socks4, parse("socks4a://h:1").?.scheme);
    try std.testing.expectEqual(Scheme.http, parse("http://h:1").?.scheme);
    try std.testing.expectEqual(Scheme.http, parse("https://h:1").?.scheme);
    // An unknown scheme is a typo. Falling back to a default would send traffic
    // through a protocol the user did not name.
    try std.testing.expect(parse("ftp://h:1") == null);
}

test "credentials, including a password containing @" {
    const p = parse("socks5://alice:s3cr3t@10.0.0.1:1080").?;
    try std.testing.expectEqualStrings("alice", p.user);
    try std.testing.expectEqualStrings("s3cr3t", p.pass);
    try std.testing.expectEqualStrings("10.0.0.1", p.host);
    const q = parse("socks5://bob:p@ss@10.0.0.1:1080").?;
    try std.testing.expectEqualStrings("bob", q.user);
    try std.testing.expectEqualStrings("p@ss", q.pass);
    try std.testing.expectEqualStrings("10.0.0.1", q.host);
    // Username with no password is legal.
    const r = parse("socks5://bob@10.0.0.1:1080").?;
    try std.testing.expectEqualStrings("bob", r.user);
    try std.testing.expectEqualStrings("", r.pass);
}

test "IPv6 literals keep their colons" {
    const p = parse("socks5://[::1]:1080").?;
    try std.testing.expectEqualStrings("::1", p.host);
    try std.testing.expectEqual(@as(u16, 1080), p.port);
    const q = parse("[fe80::1%25eth0]:9050").?;
    try std.testing.expectEqualStrings("fe80::1%25eth0", q.host);
}

test "trailing path is dropped, whitespace tolerated" {
    try std.testing.expectEqualStrings("h", parse("socks5://h:1080/").?.host);
    try std.testing.expectEqualStrings("h", parse("  socks5://h:1080  ").?.host);
}

test "malformed input yields null rather than a partial proxy" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("   ") == null);
    try std.testing.expect(parse("127.0.0.1") == null); // no port
    try std.testing.expect(parse("socks5://") == null);
    try std.testing.expect(parse("socks5://:1080") == null); // no host
    try std.testing.expect(parse("h:0") == null); // port 0 is not a port
    try std.testing.expect(parse("h:70000") == null); // out of u16 range
    try std.testing.expect(parse("h:abc") == null);
    try std.testing.expect(parse("socks5://[::1]") == null); // bracketed, no port
}
