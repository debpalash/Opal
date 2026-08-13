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

/// First-admin bootstrap URL opened by the trusted desktop app. The setup
/// capability lives in the fragment, which browsers do not send in the HTTP
/// request or Referer. The bundled page captures and immediately removes it
/// from browser history before submitting it in a dedicated request header.
pub fn webUiSetupUrl(port: u16, setup_token: []const u8, buf: []u8) ?[]const u8 {
    if (setup_token.len != 64) return null;
    for (setup_token) |ch| {
        if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return null;
    }
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/#setup={s}", .{ port, setup_token }) catch null;
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

test "webUiSetupUrl keeps one-time capability in a fragment" {
    const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:41595/#setup=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        webUiSetupUrl(41595, token, &buf).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), webUiSetupUrl(41595, "short", &buf));
    try std.testing.expectEqual(@as(?[]const u8, null), webUiSetupUrl(41595, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", &buf));
    try std.testing.expectEqual(@as(?[]const u8, null), webUiSetupUrl(41595, "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF", &buf));
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

/// First IPv4 dotted quad in `out`, or null. Used to read the LAN address out
/// of `ipconfig getifaddr` (one address) and `hostname -I` (space separated,
/// and the first entry is not always the one you want but is the best guess
/// without a routing-table lookup).
///
/// Rejects loopback: `hostname -I` can lead with 127.0.0.1 on some setups, and
/// printing "open http://127.0.0.1:41595 on your phone" is worse than printing
/// nothing.
pub fn firstIpv4(out: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
    while (it.next()) |tok| {
        if (!isDottedQuad(tok)) continue;
        if (std.mem.startsWith(u8, tok, "127.")) continue;
        return tok;
    }
    return null;
}

fn isDottedQuad(s: []const u8) bool {
    if (s.len < 7 or s.len > 15) return false;
    var parts = std.mem.splitScalar(u8, s, '.');
    var n: u8 = 0;
    while (parts.next()) |part| {
        n += 1;
        if (n > 4 or part.len == 0 or part.len > 3) return false;
        for (part) |ch| if (ch < '0' or ch > '9') return false;
        if (std.fmt.parseInt(u16, part, 10) catch 999 > 255) return false;
    }
    return n == 4;
}

test "firstIpv4 reads ipconfig and hostname -I output" {
    try std.testing.expectEqualStrings("192.168.0.198", firstIpv4("192.168.0.198\n").?);
    try std.testing.expectEqualStrings("10.0.0.4", firstIpv4("10.0.0.4 172.17.0.1\n").?);
    // Loopback is worse than nothing in "open this on your phone".
    try std.testing.expectEqualStrings("192.168.1.5", firstIpv4("127.0.0.1 192.168.1.5").?);
    try std.testing.expect(firstIpv4("127.0.0.1\n") == null);
}

test "firstIpv4 rejects things that only look like an address" {
    try std.testing.expect(firstIpv4("") == null);
    try std.testing.expect(firstIpv4("no address here") == null);
    try std.testing.expect(firstIpv4("1.2.3") == null); // three octets
    try std.testing.expect(firstIpv4("1.2.3.4.5") == null); // five
    try std.testing.expect(firstIpv4("999.1.1.1") == null); // out of range
    try std.testing.expect(firstIpv4("1.2.3.a") == null); // non-numeric
    try std.testing.expect(firstIpv4("fe80::1") == null); // v6
}
