//! DNS half of the host-fetch policy. String rules are `fetch_target_pure.zig`.
//! A lookup error, or any resolved address that is private, refuses the fetch.
//! A public hostname is pinned with curl `--connect-to` so a later resolver
//! answer cannot move that connection onto a private address.

const std = @import("std");
const io_global = @import("../core/io_global.zig");
const transport = @import("../core/http_transport.zig");
const pure = @import("fetch_target_pure.zig");
const bf = @import("browser_fetch_pure.zig");

/// Empty slice: allowed, and the URL is already an address literal.
/// Non-empty: allowed, pass the slice as curl `--connect-to`.
/// Null: do not connect.
fn resolvePublic(host: []const u8, port: u16) ?std.Io.net.IpAddress {
    const io = transport.nativeIo(io_global.io());
    const name = std.Io.net.HostName.init(host) catch return null;
    var storage: [32]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&storage);
    name.lookup(io, &queue, .{ .port = port }) catch return null;
    var first: ?std.Io.net.IpAddress = null;
    var saw = false;
    while (queue.getOne(io)) |row| {
        switch (row) {
            .address => |address| {
                saw = true;
                if (pure.isPrivateAddress(address)) return null;
                if (first == null) first = address;
            },
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => {},
        else => return null,
    }
    if (!saw) return null;
    return first;
}

fn pinOrBlock(url: []const u8, pin_buf: []u8) ?[]const u8 {
    const host = pure.hostOfUrl(url);
    if (host.len == 0) return null;
    if (pure.parseIpLiteral(host)) |address| {
        if (pure.isPrivateAddress(address)) return null;
        return pin_buf[0..0];
    }
    const address = resolvePublic(host, pure.portOf(url)) orelse return null;
    return pure.formatConnectTo(host, pure.portOf(url), address, pin_buf);
}

/// Debug builds, or a build with `-Dfixture-seams=true` (CI's ReleaseSafe
/// fixture binary). Release artifacts ignore the variable, so a shipped app
/// cannot be pointed at a loopback download by its environment.
fn loopbackFixturesAllowed() bool {
    if (comptime @import("builtin").mode != .debug and !@import("build_options").fixture_seams) return false;
    const v = io_global.getenv("OPAL_ALLOW_LOOPBACK_DOWNLOAD") orelse return false;
    return std.mem.eql(u8, v, "1");
}

/// String half of the download policy, including the Debug-only fixture seam.
/// DNS stays in `vetDownload` on the worker.
pub fn stringPermitted(url: []const u8) bool {
    return pure.downloadPermitted(url, loopbackFixturesAllowed());
}

/// `address` is set when `url` is a hostname. The caller dials that address
/// and keeps the original name for SNI and the Host header. A null address
/// means the URL is already a literal.
pub const Dial = struct { address: ?std.Io.net.IpAddress = null };

pub fn vetDownload(url: []const u8) ?Dial {
    const allow_loopback = loopbackFixturesAllowed();
    if (!pure.downloadPermitted(url, allow_loopback)) return null;
    const host = pure.hostOfUrl(url);
    if (pure.parseIpLiteral(host)) |address| {
        if (allow_loopback and pure.isLoopbackAddress(address)) return .{};
        if (pure.isPrivateAddress(address)) return null;
        return .{};
    }
    const address = resolvePublic(host, pure.portOf(url)) orelse return null;
    return .{ .address = address };
}

/// TCP to `address`, TLS and the pool key on the URL host. `address` was
/// already accepted by `vetDownload`, so this dial is a numeric lookup.
pub fn openPinned(client: *std.http.Client, url: []const u8, address: std.Io.net.IpAddress) ?*std.http.Client.Connection {
    var ip_buf: [64]u8 = undefined;
    const ip_text = pure.formatDialName(address, &ip_buf) orelse return null;
    const dial: std.Io.net.HostName = .{ .bytes = ip_text };
    const sni = std.Io.net.HostName.init(pure.hostOfUrl(url)) catch return null;
    const port = pure.portOf(url);
    const https = url.len >= 8 and std.ascii.eqlIgnoreCase(url[0..8], "https://");
    return client.connectTcpOptions(.{
        .host = dial,
        .port = port,
        .protocol = if (https) .tls else .plain,
        .proxied_host = sni,
        .proxied_port = port,
    }) catch null;
}

/// Scrape policy: `isPrivateTarget` (every IP literal and special-use name)
/// plus the same fail-closed DNS check. The loopback fixture seam applies here
/// too: Comics, Novels and Anime providers scrape through this path, and the
/// hermetic browse suites serve them from 127.0.0.1.
pub fn vetScrape(url: []const u8, pin_buf: []u8) ?[]const u8 {
    bf.validateTarget(url) catch return null;
    if (pure.fixtureLoopbackLiteral(url, loopbackFixturesAllowed())) return pin_buf[0..0];
    if (bf.isPrivateTarget(url)) return null;
    return pinOrBlock(url, pin_buf);
}
