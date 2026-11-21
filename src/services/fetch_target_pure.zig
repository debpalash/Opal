//! Which URLs a host-side fetch may contact. No DNS and no sockets: address
//! classification and redirect joining live here so the tested rules are the
//! ones `fetch_target.zig`, the download engine, and scrape fetch call.
//!
//! Downloads may use a public IP literal (CDNs). Scrapes keep
//! `browser_fetch_pure.isPrivateTarget`, which treats every literal as private.
//! Both reject loopback, RFC1918, link-local, and special-use names.

const std = @import("std");
const bf = @import("browser_fetch_pure.zig");

fn httpScheme(scheme: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https");
}

pub fn isPrivateIpv4(b: [4]u8) bool {
    if (b[0] == 0 or b[0] == 10 or b[0] == 127) return true;
    if (b[0] == 100 and b[1] & 0xc0 == 64) return true; // 100.64.0.0/10
    if (b[0] == 169 and b[1] == 254) return true;
    if (b[0] == 172 and b[1] >= 16 and b[1] <= 31) return true;
    if (b[0] == 192 and b[1] == 168) return true;
    if (b[0] == 192 and b[1] == 0 and (b[2] == 0 or b[2] == 2)) return true;
    if (b[0] == 198 and (b[1] == 18 or b[1] == 19)) return true; // 198.18.0.0/15
    if (b[0] == 198 and b[1] == 51 and b[2] == 100) return true;
    if (b[0] == 203 and b[1] == 0 and b[2] == 113) return true;
    if (b[0] >= 224) return true; // multicast and reserved
    return false;
}

fn nat64Embedded(b: [16]u8) ?[4]u8 {
    // 64:ff9b::/96 — reject only when the embedded IPv4 is private.
    if (b[0] != 0x00 or b[1] != 0x64 or b[2] != 0xff or b[3] != 0x9b) return null;
    for (b[4..12]) |x| if (x != 0) return null;
    return b[12..16].*;
}

pub fn isPrivateIpv6(b: [16]u8) bool {
    if (nat64Embedded(b)) |v4| return isPrivateIpv4(v4);
    var zero_prefix = true;
    for (b[0..12]) |x| if (x != 0) {
        zero_prefix = false;
        break;
    };
    if (zero_prefix) return isPrivateIpv4(b[12..16].*); // :: and ::1 and v4-compatible
    if (b[0] & 0xfe == 0xfc) return true; // fc00::/7
    if (b[0] == 0xfe and b[1] & 0xc0 == 0x80) return true; // fe80::/10
    if (b[0] == 0xff) return true; // ff00::/8
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8) return true;
    return false;
}

pub fn isPrivateAddress(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| isPrivateIpv4(a.bytes),
        .ip6 => |a| if (std.Io.net.Ip4Address.fromIp6(a)) |v4| isPrivateIpv4(v4.bytes) else isPrivateIpv6(a.bytes),
    };
}

pub fn parseIpLiteral(host: []const u8) ?std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parse(host, 0) catch null;
}

fn stripDot(host: []const u8) []const u8 {
    if (host.len > 0 and host[host.len - 1] == '.') return host[0 .. host.len - 1];
    return host;
}

/// Initial download URL, before DNS. Public addresses are allowed. Names that
/// are not public DNS names (localhost, single-label, `.local`) are not.
pub fn downloadStringAllowed(url: []const u8) bool {
    return downloadPermitted(url, false);
}

pub fn isLoopbackAddress(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| if (std.Io.net.Ip4Address.fromIp6(a)) |v4|
            v4.bytes[0] == 127
        else blk: {
            for (a.bytes[0..15]) |b| if (b != 0) break :blk false;
            break :blk a.bytes[15] == 1;
        },
    };
}

/// `allow_loopback` is the test-fixture seam (`OPAL_ALLOW_LOOPBACK_DOWNLOAD=1`).
/// It exempts a loopback address literal only, not LAN or link-local targets.
pub fn downloadPermitted(url: []const u8, allow_loopback: bool) bool {
    bf.validateTarget(url) catch return false;
    const host = stripDot(bf.hostOf(url));
    if (host.len == 0) return false;
    if (parseIpLiteral(host)) |address| {
        if (allow_loopback and isLoopbackAddress(address)) return true;
        return !isPrivateAddress(address);
    }
    return bf.publicHost(host);
}

/// Fixture seam shared by downloads and scrapes: with `allow_loopback` set, a
/// loopback address literal skips the DNS pin. Names and LAN stay checked.
pub fn fixtureLoopbackLiteral(url: []const u8, allow_loopback: bool) bool {
    if (!allow_loopback) return false;
    bf.validateTarget(url) catch return false;
    const address = parseIpLiteral(stripDot(bf.hostOf(url))) orelse return false;
    return isLoopbackAddress(address);
}

pub fn locationHeader(headers: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) return null;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "location")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0) return null;
        return value;
    }
    return null;
}

/// Resolve `location` against `base` into `buf`. Null for a non-http scheme,
/// embedded credentials, or a value that does not fit.
pub fn joinRedirect(base_url: []const u8, location_in: []const u8, buf: []u8) ?[]const u8 {
    const location = std.mem.trim(u8, location_in, " \t");
    if (location.len == 0 or location.len > 2048) return null;
    for (location) |ch| if (ch < 0x20 or ch == 0x7f or ch == '\\') return null;

    var aux: [4096]u8 = undefined;
    @memcpy(aux[0..location.len], location);
    var aux_slice: []u8 = &aux;
    const base = std.Uri.parse(base_url) catch return null;
    const resolved = base.resolveInPlace(location.len, &aux_slice) catch return null;
    if (!httpScheme(resolved.scheme)) return null;
    if (resolved.user != null or resolved.password != null or resolved.host == null) return null;

    var w = std.Io.Writer.fixed(buf);
    resolved.writeToStream(&w, .{
        .scheme = true,
        .authority = true,
        .path = true,
        .query = true,
        .fragment = false,
        .port = true,
    }) catch return null;
    if (w.end == 0) return null;
    return buf[0..w.end];
}

/// curl `--connect-to HOST:PORT:ADDR:PORT`. IPv6 addresses are bracketed.
pub fn formatConnectTo(host: []const u8, port: u16, address: std.Io.net.IpAddress, buf: []u8) ?[]const u8 {
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, ':') != null) return null;
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}:{d}:", .{ host, port }) catch return null;
    switch (address) {
        .ip4 => |a| w.print("{d}.{d}.{d}.{d}:{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3], port }) catch return null,
        .ip6 => |a| {
            w.writeAll("[") catch return null;
            var i: usize = 0;
            while (i < 16) : (i += 2) {
                if (i != 0) w.writeByte(':') catch return null;
                const group: u16 = (@as(u16, a.bytes[i]) << 8) | a.bytes[i + 1];
                w.print("{x}", .{group}) catch return null;
            }
            w.print("]:{d}", .{port}) catch return null;
        },
    }
    return buf[0..w.end];
}

pub fn portOf(url: []const u8) u16 {
    const https = url.len >= 8 and std.ascii.eqlIgnoreCase(url[0..8], "https://");
    const def: u16 = if (https) 443 else 80;
    const authority = bf.authorityOf(url);
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return def;
        if (close + 1 < authority.len and authority[close + 1] == ':')
            return std.fmt.parseInt(u16, authority[close + 2 ..], 10) catch def;
        return def;
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return def;
    return std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch def;
}

pub fn hostOfUrl(url: []const u8) []const u8 {
    return stripDot(bf.hostOf(url));
}

test "private ranges cover loopback, metadata, cgnat, and documentation" {
    try std.testing.expect(isPrivateIpv4(.{ 127, 0, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 10, 1, 2, 3 }));
    try std.testing.expect(isPrivateIpv4(.{ 192, 168, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 172, 16, 0, 1 }));
    try std.testing.expect(!isPrivateIpv4(.{ 172, 15, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 169, 254, 169, 254 }));
    try std.testing.expect(isPrivateIpv4(.{ 100, 64, 0, 1 }));
    try std.testing.expect(!isPrivateIpv4(.{ 100, 63, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 0, 0, 0, 0 }));
    try std.testing.expect(isPrivateIpv4(.{ 192, 0, 2, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 198, 51, 100, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 203, 0, 113, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 198, 18, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 224, 0, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 255, 255, 255, 255 }));
    try std.testing.expect(!isPrivateIpv4(.{ 1, 1, 1, 1 }));
    try std.testing.expect(!isPrivateIpv4(.{ 8, 8, 8, 8 }));

    try std.testing.expect(isPrivateIpv6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try std.testing.expect(isPrivateIpv6(.{ 0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try std.testing.expect(isPrivateIpv6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try std.testing.expect(isPrivateIpv6(.{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try std.testing.expect(isPrivateIpv6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    const nat64_loop = [16]u8{ 0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 };
    const nat64_public = [16]u8{ 0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1 };
    try std.testing.expect(isPrivateIpv6(nat64_loop));
    try std.testing.expect(!isPrivateIpv6(nat64_public));

    const mapped = std.Io.net.Ip6Address.fromIp4(.{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 });
    try std.testing.expect(isPrivateAddress(.{ .ip6 = mapped }));
    const mapped_public = std.Io.net.Ip6Address.fromIp4(.{ .bytes = .{ 1, 1, 1, 1 }, .port = 0 });
    try std.testing.expect(!isPrivateAddress(.{ .ip6 = mapped_public }));
}

test "download string gate allows public addresses and rejects private names" {
    try std.testing.expect(downloadStringAllowed("https://1.1.1.1/a"));
    try std.testing.expect(downloadStringAllowed("http://8.8.8.8/a"));
    try std.testing.expect(downloadStringAllowed("https://cdn.example.com/a"));
    try std.testing.expect(downloadStringAllowed("http://[2001:4860:4860::8888]/"));
    try std.testing.expect(!downloadStringAllowed("http://127.0.0.1/"));
    try std.testing.expect(downloadPermitted("http://127.0.0.1:9/fixture", true));
    try std.testing.expect(downloadPermitted("http://[::1]/fixture", true));
    try std.testing.expect(!downloadPermitted("http://169.254.169.254/latest", true));
    try std.testing.expect(!downloadPermitted("http://10.0.0.1/", true));
    try std.testing.expect(!downloadPermitted("http://localhost/", true));
    try std.testing.expect(!downloadStringAllowed("http://127.0.0.1:9/secret"));
    try std.testing.expect(!downloadStringAllowed("http://10.1.2.3/"));
    try std.testing.expect(!downloadStringAllowed("http://192.168.0.1/"));
    try std.testing.expect(!downloadStringAllowed("http://172.16.0.1/"));
    try std.testing.expect(!downloadStringAllowed("http://169.254.169.254/latest"));
    try std.testing.expect(!downloadStringAllowed("http://localhost/"));
    try std.testing.expect(!downloadStringAllowed("http://printer/"));
    try std.testing.expect(!downloadStringAllowed("http://nas.local/a"));
    try std.testing.expect(!downloadStringAllowed("http://[::1]/"));
    try std.testing.expect(!downloadStringAllowed("http://user:pass@files.example/a"));
    try std.testing.expect(!downloadStringAllowed("file:///etc/passwd"));
}

test "redirect join keeps the public host and rejects a hop to loopback" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("https://files.example/a/c", joinRedirect("https://files.example/a/b", "c", &buf).?);
    try std.testing.expectEqualStrings("https://files.example/z", joinRedirect("https://files.example/a/b", "/z", &buf).?);
    try std.testing.expectEqualStrings("https://cdn.example/z", joinRedirect("https://files.example/a", "//cdn.example/z", &buf).?);
    try std.testing.expectEqualStrings("https://cdn.example/z", joinRedirect("https://files.example/a", "https://cdn.example/z", &buf).?);
    try std.testing.expect(joinRedirect("https://files.example/a", "file:///etc/passwd", &buf) == null);
    try std.testing.expect(joinRedirect("https://files.example/a", "http://user:pass@cdn.example/z", &buf) == null);

    const loop = joinRedirect("https://files.example/a", "http://127.0.0.1/secret", &buf).?;
    try std.testing.expect(!downloadStringAllowed(loop));
    const meta = joinRedirect("https://files.example/a", "http://169.254.169.254/latest", &buf).?;
    try std.testing.expect(!downloadStringAllowed(meta));
    const lan = joinRedirect("https://files.example/a", "http://10.0.0.5/x", &buf).?;
    try std.testing.expect(!downloadStringAllowed(lan));
}

test "location header and connect-to pin" {
    const headers = "HTTP/1.1 302 Found\r\nlocation: /next\r\n\r\n";
    try std.testing.expectEqualStrings("/next", locationHeader(headers).?);
    try std.testing.expect(locationHeader("HTTP/1.1 200 OK\r\n\r\n") == null);
    var buf: [128]u8 = undefined;
    const v4: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 1, 1, 1, 1 }, .port = 0 } };
    try std.testing.expectEqualStrings("cdn.example:443:1.1.1.1:443", formatConnectTo("cdn.example", 443, v4, &buf).?);
    try std.testing.expectEqual(@as(u16, 8443), portOf("https://cdn.example:8443/a"));
    try std.testing.expectEqual(@as(u16, 80), portOf("http://cdn.example/a"));
}

test "loopback fixture seam exempts loopback literals only" {
    try std.testing.expect(fixtureLoopbackLiteral("http://127.0.0.1:8080/comicfury/", true));
    try std.testing.expect(fixtureLoopbackLiteral("http://[::1]:9/x", true));
    try std.testing.expect(!fixtureLoopbackLiteral("http://127.0.0.1:8080/", false));
    try std.testing.expect(!fixtureLoopbackLiteral("http://localhost:8080/", true));
    try std.testing.expect(!fixtureLoopbackLiteral("http://192.168.1.5/", true));
    try std.testing.expect(!fixtureLoopbackLiteral("http://169.254.169.254/", true));
}
