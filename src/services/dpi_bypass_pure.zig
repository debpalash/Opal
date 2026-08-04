//! Pure (allocation-free, side-effect-free) helpers for the DPI-bypass sidecar.
//! Isolated here so the shipped logic IS the tested logic (see CLAUDE.md's
//! *_pure test-discipline rule): dpi_bypass.zig routes through these.
//!
//! Covers the three decisions that used to be inline in the sidecar:
//!   1. validMode()   — which `--mode` strings the CLI accepts.
//!   2. loopbackAddr() — builds the "127.0.0.1:<port>" string curl / std.http
//!                       point at (no heap; caller owns the buffer).
//!   3. shouldProxy()  — the enabled&&running gate for proxyArgs().

const std = @import("std");

/// The proxy CLI accepts exactly these `--mode` values. "sni" fragments around
/// the SNI extension; "split:1" splits the ClientHello at byte 1. Anything else
/// (hand-edited config, a future mode we don't ship yet) is rejected so the
/// sidecar always spawns with a mode it understands.
pub fn validMode(s: []const u8) bool {
    return std.mem.eql(u8, s, "sni") or std.mem.eql(u8, s, "split:1");
}

/// The default mode when config carries none / an invalid one.
pub const default_mode = "sni";

/// The sidecar's executable name. Shared by binaryPath() and the orphan reaper
/// so the name we spawn is always the name we kill -- a rename that updated only
/// one of them would leave orphans alive forever.
pub const process_name = "zig-bypassdpi";

/// Whether start() should reap stale sidecars before spawning one.
///
/// The sidecar binds with SO_REUSEPORT, so an orphan does NOT make the next
/// spawn fail -- every one of them listens on the same port and the kernel
/// load-balances connections across the whole set. Measured 2026-08-04: 57
/// orphans left by dev.sh restarts, all LISTENing on 127.0.0.1:8881, the oldest
/// two days old, so a fetch had roughly a 1-in-57 chance of going through the
/// `--mode` the user actually selected. A bind conflict would have been
/// self-healing; this silently isn't.
///
/// Safe only when we hold no child: stop() clears `child` and start() is latched
/// against a concurrent spawn, so with `have_child` false every live sidecar on
/// this machine is by definition an orphan.
pub fn shouldReapOrphans(have_child: bool) bool {
    return !have_child;
}

/// Build "127.0.0.1:<port>" into `buf`. Returns the written slice, or an empty
/// slice if the buffer is somehow too small (never in practice — a u16 port is
/// at most "127.0.0.1:65535" = 15 bytes).
pub fn loopbackAddr(buf: []u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf, "127.0.0.1:{d}", .{port}) catch buf[0..0];
}

/// The gate for proxyArgs(): route traffic through the local proxy only when the
/// user enabled the feature AND the sidecar is actually listening.
pub fn shouldProxy(enabled: bool, running: bool) bool {
    return enabled and running;
}

test "validMode accepts the two CLI modes only" {
    try std.testing.expect(validMode("sni"));
    try std.testing.expect(validMode("split:1"));
    try std.testing.expect(!validMode("split"));
    try std.testing.expect(!validMode("split:2"));
    try std.testing.expect(!validMode(""));
    try std.testing.expect(!validMode("SNI"));
    try std.testing.expect(!validMode("sni "));
}

test "loopbackAddr builds host:port" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("127.0.0.1:8881", loopbackAddr(&buf, 8881));
    try std.testing.expectEqualStrings("127.0.0.1:65535", loopbackAddr(&buf, 65535));
    try std.testing.expectEqualStrings("127.0.0.1:0", loopbackAddr(&buf, 0));
}

test "loopbackAddr on an undersized buffer yields empty, never garbage" {
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), loopbackAddr(&tiny, 8881).len);
}

test "shouldProxy gates on enabled AND running" {
    try std.testing.expect(shouldProxy(true, true));
    try std.testing.expect(!shouldProxy(true, false));
    try std.testing.expect(!shouldProxy(false, true));
    try std.testing.expect(!shouldProxy(false, false));
}

test "default_mode is a valid mode" {
    try std.testing.expect(validMode(default_mode));
}

test "shouldReapOrphans only when we own no child" {
    // Holding a child means the running sidecar is ours -- reaping by name would
    // kill the proxy we just started.
    try std.testing.expect(!shouldReapOrphans(true));
    try std.testing.expect(shouldReapOrphans(false));
}

test "process_name is what the reaper matches and the binary is named" {
    // Regression guard for the 57-orphan leak: these must not drift apart.
    try std.testing.expectEqualStrings("zig-bypassdpi", process_name);
}
