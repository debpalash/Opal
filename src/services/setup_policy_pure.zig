//! Pure first-admin request policy.
//!
//! The setup credential proves local filesystem/desktop access.  This policy
//! supplies a second, narrow boundary for the one unauthenticated mutation:
//! registration may target only an IP literal or localhost, and a browser
//! Origin (when present) must name that exact authority.  Normal login is not
//! subject to this bootstrap-only rule.

const std = @import("std");

fn asciiEqualIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

fn validPort(port: []const u8) bool {
    if (port.len == 0) return false;
    const n = std.fmt.parseInt(u16, port, 10) catch return false;
    return n != 0;
}

/// True only for localhost or an IP-literal HTTP authority, with an optional
/// numeric port.  DNS names are deliberately excluded during first-admin
/// setup, preventing a rebinding hostname from becoming the bootstrap target.
pub fn allowedHost(raw: ?[]const u8) bool {
    const authority = std.mem.trim(u8, raw orelse return false, " \t");
    if (authority.len == 0) return false;

    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        _ = std.Io.net.IpAddress.parseIp6(authority[1..close], 0) catch return false;
        const tail = authority[close + 1 ..];
        return tail.len == 0 or (tail[0] == ':' and validPort(tail[1..]));
    }

    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |i| authority[0..i] else authority;
    if (colon) |i| if (!validPort(authority[i + 1 ..])) return false;
    if (asciiEqualIgnoreCase(host, "localhost")) return true;
    _ = std.Io.net.IpAddress.parseIp4(host, 0) catch return false;
    return true;
}

fn originAuthority(raw: []const u8) ?[]const u8 {
    const origin = std.mem.trim(u8, raw, " \t");
    const rest = if (std.mem.startsWith(u8, origin, "http://"))
        origin["http://".len..]
    else if (std.mem.startsWith(u8, origin, "https://"))
        origin["https://".len..]
    else
        return null;
    if (rest.len == 0 or std.mem.indexOfAny(u8, rest, "/?#") != null) return null;
    return rest;
}

fn validExtensionOrigin(raw: []const u8) bool {
    const origin = std.mem.trim(u8, raw, " \t");
    if (std.mem.startsWith(u8, origin, "chrome-extension://")) {
        const id = origin["chrome-extension://".len..];
        if (id.len != 32) return false;
        for (id) |ch| if (ch < 'a' or ch > 'p') return false;
        return true;
    }
    if (std.mem.startsWith(u8, origin, "moz-extension://")) {
        const id = origin["moz-extension://".len..];
        if (id.len == 0 or id.len > 128) return false;
        for (id) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
        }
        return true;
    }
    return false;
}

/// Missing Origin is intentional for curl/native setup clients. Web callers
/// must be same-authority; syntactically valid browser-extension origins are
/// accepted because the separate 256-bit setup credential remains mandatory.
pub fn allowedRegistration(host_raw: ?[]const u8, origin_raw: ?[]const u8) bool {
    if (!allowedHost(host_raw)) return false;
    const origin = origin_raw orelse return true;
    // Browser extensions are trusted only to *present* the setup capability;
    // the 256-bit file/desktop credential remains mandatory at the caller.
    if (validExtensionOrigin(origin)) return true;
    const authority = originAuthority(origin) orelse return false;
    const host = std.mem.trim(u8, host_raw.?, " \t");
    return asciiEqualIgnoreCase(authority, host);
}

test "registration allows direct localhost and LAN IP setup" {
    try std.testing.expect(allowedRegistration("localhost:41595", null));
    try std.testing.expect(allowedRegistration("127.0.0.1:41595", "http://127.0.0.1:41595"));
    try std.testing.expect(allowedRegistration("192.168.1.20:41595", "https://192.168.1.20:41595"));
    try std.testing.expect(allowedRegistration("[::1]:41595", "http://[::1]:41595"));
}

test "registration rejects DNS rebinding and cross-site origins" {
    try std.testing.expect(!allowedRegistration(null, null));
    try std.testing.expect(!allowedRegistration("opal.attacker.test:41595", null));
    try std.testing.expect(!allowedRegistration("127.0.0.1:41595", "https://attacker.test"));
    try std.testing.expect(!allowedRegistration("127.0.0.1:41595", "null"));
    try std.testing.expect(!allowedRegistration("127.0.0.1:41595", "chrome-extension://abc"));
    try std.testing.expect(!allowedRegistration("127.0.0.1:41595", "http://127.0.0.1:9999"));
}

test "registration permits syntactically valid browser extension origins" {
    try std.testing.expect(allowedRegistration(
        "127.0.0.1:41595",
        "chrome-extension://abcdefghijklmnopabcdefghijklmnop",
    ));
    try std.testing.expect(allowedRegistration(
        "192.168.1.20:41595",
        "moz-extension://01234567-89ab-cdef-0123-456789abcdef",
    ));
    try std.testing.expect(!allowedRegistration("127.0.0.1:41595", "moz-extension://bad/id"));
    try std.testing.expect(!allowedRegistration("attacker.test:41595", "moz-extension://valid-id"));
}

test "host parser rejects malformed numeric-looking authorities" {
    try std.testing.expect(!allowedHost("127.0.0.999:41595"));
    try std.testing.expect(!allowedHost("127.0.0.1:0"));
    try std.testing.expect(!allowedHost("127.0.0.1:notaport"));
    try std.testing.expect(!allowedHost("[not-v6]:41595"));
    try std.testing.expect(!allowedHost("[:::]:41595"));
    try std.testing.expect(!allowedHost("[1:2:3:4:5:6:7]:41595"));
    try std.testing.expect(!allowedHost("[1:2:3:4:5:6:7:8:9]:41595"));
    try std.testing.expect(!allowedHost("[2001:db8::1]trailing"));
}
