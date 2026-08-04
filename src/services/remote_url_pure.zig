//! Pure URL/label helpers for the Web UI toggle (header globe button and the
//! Settings › Web Remote row). Kept free of `io_global` / `state` so it can be
//! unit-tested standalone — see the cross-boundary note in CLAUDE.md.

const std = @import("std");

/// Loopback URL for opening Opal's own web UI on *this* machine.
///
/// Deliberately 127.0.0.1 and not the LAN IP: the server binds 0.0.0.0, but the
/// browser we launch is local, and loopback works even when the machine has no
/// LAN address (offline, VPN-only, ethernet unplugged). The LAN IP is only ever
/// shown as a hint for reaching Opal from a phone.
///
/// Returns null if `buf` is too small.
pub fn webUiUrl(port: u16, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/", .{port}) catch null;
}

/// Tooltip for the header Web UI button. `lan_ip` is only consulted when
/// `running` — callers pass "" while off so the toggle never pays for the
/// `ipconfig` probe behind `remote.lanIp()` on a cold first frame.
pub fn webUiTooltip(running: bool, lan_ip: []const u8, port: u16, buf: []u8) []const u8 {
    if (!running) return "Web UI — off (click to start and open)";
    if (lan_ip.len == 0) return "Web UI — on (click to stop)";
    return std.fmt.bufPrint(
        buf,
        "Web UI — http://{s}:{d} (click to stop)",
        .{ lan_ip, port },
    ) catch "Web UI — on (click to stop)";
}

// ── Tests ──

test "webUiUrl: loopback, explicit port, trailing slash" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("http://127.0.0.1:41595/", webUiUrl(41595, &buf).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/", webUiUrl(8080, &buf).?);
}

test "webUiUrl: never emits the LAN-facing bind address" {
    var buf: [64]u8 = undefined;
    const url = webUiUrl(41595, &buf).?;
    // 0.0.0.0 is what serverLoop binds; it is not a routable destination and a
    // browser sent there fails. Regression guard against copying the bind IP.
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, url, "0.0.0.0"));
}

test "webUiUrl: buffer too small returns null" {
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), webUiUrl(41595, &tiny));
}

test "webUiTooltip: off ignores lan ip" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Web UI — off (click to start and open)",
        webUiTooltip(false, "192.168.1.42", 41595, &buf),
    );
}

test "webUiTooltip: on with and without a LAN ip" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Web UI — http://192.168.1.42:41595 (click to stop)",
        webUiTooltip(true, "192.168.1.42", 41595, &buf),
    );
    try std.testing.expectEqualStrings(
        "Web UI — on (click to stop)",
        webUiTooltip(true, "", 41595, &buf),
    );
}

test "webUiTooltip: tiny buffer falls back instead of truncating" {
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Web UI — on (click to stop)",
        webUiTooltip(true, "192.168.1.42", 41595, &tiny),
    );
}
