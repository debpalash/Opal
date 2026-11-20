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
fn pinOrBlock(url: []const u8, pin_buf: []u8) ?[]const u8 {
    const host = pure.hostOfUrl(url);
    if (host.len == 0) return null;
    if (pure.parseIpLiteral(host)) |address| {
        if (pure.isPrivateAddress(address)) return null;
        return pin_buf[0..0];
    }
    const io = transport.nativeIo(io_global.io());
    const name = std.Io.net.HostName.init(host) catch return null;
    var storage: [32]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&storage);
    name.lookup(io, &queue, .{ .port = pure.portOf(url) }) catch return null;
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
    return pure.formatConnectTo(host, pure.portOf(url), first.?, pin_buf);
}

fn loopbackFixturesAllowed() bool {
    const v = io_global.getenv("OPAL_ALLOW_LOOPBACK_DOWNLOAD") orelse return false;
    return std.mem.eql(u8, v, "1");
}

/// Download policy: public IP literals allowed, private and special-use names
/// refused, and a name that resolves to any private address refused.
/// `OPAL_ALLOW_LOOPBACK_DOWNLOAD=1` exempts a loopback literal for fixture
/// servers. It does not exempt LAN, link-local, or a name that resolves private.
/// String half of the download policy, including the fixture loopback seam.
/// DNS stays in `vetDownload` on the worker.
pub fn stringPermitted(url: []const u8) bool {
    return pure.downloadPermitted(url, loopbackFixturesAllowed());
}

pub fn vetDownload(url: []const u8, pin_buf: []u8) ?[]const u8 {
    const allow_loopback = loopbackFixturesAllowed();
    if (!pure.downloadPermitted(url, allow_loopback)) return null;
    if (allow_loopback) if (pure.parseIpLiteral(pure.hostOfUrl(url))) |address| {
        if (pure.isLoopbackAddress(address)) return pin_buf[0..0];
    };
    return pinOrBlock(url, pin_buf);
}

/// Scrape policy: `isPrivateTarget` (every IP literal and special-use name)
/// plus the same fail-closed DNS check.
pub fn vetScrape(url: []const u8, pin_buf: []u8) ?[]const u8 {
    bf.validateTarget(url) catch return null;
    if (bf.isPrivateTarget(url)) return null;
    return pinOrBlock(url, pin_buf);
}
