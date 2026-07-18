//! DPI-bypass proxy sidecar lifecycle.
//!
//! Spawns `zig-bypassdpi` (the debpalash/zig-bypassdpi dependency, built to
//! zig-out/bin/zig-bypassdpi and bundled into Contents/Resources/ by
//! build-app.sh) as a managed loopback SOCKS5 + HTTP-CONNECT proxy that
//! fragments the TLS ClientHello to defeat SNI-based DPI blocking. When enabled,
//! Opal's fetches route through 127.0.0.1:<PORT> so an ISP that blocks a source
//! by its SNI can't see the hostname.
//!
//! The binary is located the same way plugin_repo.zig finds plugins-manifest.json:
//! the bundle's Resources dir when installed (state.resourceRoot()), else the
//! dev checkout's zig-out/bin. All decision logic lives in dpi_bypass_pure.zig
//! so the shipped behavior is the tested behavior.

const std = @import("std");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const pure = @import("dpi_bypass_pure.zig");

/// Fixed loopback port the sidecar listens on. Loopback-only, so no security
/// exposure; fixed so proxyArgs()/the std.http proxy target it without plumbing
/// a runtime port through every call site.
pub const PORT: u16 = 8881;

// running/busy are cross-thread (UI toggles, config-load bg thread, coreInit bg
// thread) — atomics with acquire/release per CLAUDE.md. `child` is guarded by
// its own mutex since start()/stop() can race a UI toggle vs. shutdown.
var running = std.atomic.Value(bool).init(false);
var busy = std.atomic.Value(bool).init(false);
var child: ?io.Child = null;
var child_mutex: sync.Mutex = .{};

// Stable storage for the curl proxy args returned by proxyArgs(). argv[1] is
// filled with the loopback address at start(); it points into addr_buf (a
// module static), so the returned slice outlives the call.
var addr_buf: [24]u8 = undefined;
var argv_store: [2][]const u8 = .{ "--socks5-hostname", "" };

pub fn port() u16 {
    return PORT;
}

pub fn isRunning() bool {
    return running.load(.acquire);
}

/// Whether the user turned the feature on (mirrors the persisted config flag).
pub fn enabled() bool {
    return state.app.dpi_bypass_enabled;
}

/// Resolve the sidecar binary. Mirrors plugin_repo.loadLocalManifest: bundled
/// .app → Contents/Resources/zig-bypassdpi (via SDL base path); dev checkout →
/// zig-out/bin/zig-bypassdpi relative to the CWD.
fn binaryPath(buf: []u8) []const u8 {
    if (state.resourceRoot()) |r|
        return std.fmt.bufPrint(buf, "{s}/zig-bypassdpi", .{r}) catch "";
    return "zig-out/bin/zig-bypassdpi";
}

/// The configured `--mode`, validated. Falls back to the default on an
/// empty/invalid stored value so the CLI always gets a mode it understands.
fn currentMode(buf: []u8) []const u8 {
    const m = state.app.dpi_bypass_mode[0..state.app.dpi_bypass_mode_len];
    if (pure.validMode(m)) {
        @memcpy(buf[0..m.len], m);
        return buf[0..m.len];
    }
    @memcpy(buf[0..pure.default_mode.len], pure.default_mode);
    return buf[0..pure.default_mode.len];
}

/// Spawn the proxy if not already running. Idempotent: a busy latch prevents a
/// double-spawn from a UI toggle racing the config-load/coreInit start. On spawn
/// failure, logs an error and leaves running=false.
pub fn start() void {
    if (running.load(.acquire)) return;
    if (busy.swap(true, .acq_rel)) return; // another start in flight
    defer busy.store(false, .release);
    if (running.load(.acquire)) return; // re-check after acquiring the latch

    // Publish the loopback address for proxyArgs() (routed through the pure
    // builder so the shipped string is the tested string).
    argv_store[1] = pure.loopbackAddr(&addr_buf, PORT);

    var path_buf: [1100]u8 = undefined;
    const bin = binaryPath(&path_buf);
    if (bin.len == 0) {
        logs.pushLog("error", "dpi", "DPI-bypass proxy path unresolved", true);
        return;
    }
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{PORT}) catch return;
    var mode_buf: [16]u8 = undefined;
    const mode = currentMode(&mode_buf);

    child_mutex.lock();
    defer child_mutex.unlock();

    var c = io.Child.init(&.{
        bin,     "--port",      port_str,
        "--listen", "127.0.0.1", "--mode",
        mode,
    }, alloc);
    // Detached-managed: we keep the Child so stop() can kill it, but never wait
    // on it. Ignore its streams so it can't spam our stdout or block on a pipe.
    c.stdin_behavior = .Ignore;
    c.stdout_behavior = .Ignore;
    c.stderr_behavior = .Ignore;
    c.spawn() catch {
        logs.pushLog("error", "dpi", "Failed to start DPI-bypass proxy", true);
        return;
    };
    child = c; // copy the post-spawn struct (holds the pid) into module storage
    running.store(true, .release);
    logs.pushLog("info", "dpi", "DPI-bypass proxy started on 127.0.0.1:8881", false);
}

/// Kill the sidecar and clear running. Idempotent.
pub fn stop() void {
    child_mutex.lock();
    defer child_mutex.unlock();
    if (child) |*c| {
        _ = c.kill() catch {};
        child = null;
        logs.pushLog("info", "dpi", "DPI-bypass proxy stopped", false);
    }
    running.store(false, .release);
}

/// curl args to route a request through the proxy — `--socks5-hostname
/// 127.0.0.1:<PORT>` — when the feature is enabled AND the sidecar is running,
/// else null. Appended to the curl argv in core/http.zig (fetchImage). The
/// gate is the pure shouldProxy() helper.
pub fn proxyArgs() ?[]const []const u8 {
    if (!pure.shouldProxy(enabled(), isRunning())) return null;
    return argv_store[0..];
}
