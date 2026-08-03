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
    // Same publication for the search engines' SOCKS URL (see engineEnv).
    initSocksUrl();

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

// ── Search-engine plumbing ──────────────────────────────────────────────────
//
// proxyArgs() above only covers requests curl makes from the Zig side (TMDB,
// images). The torrent search engines are a separate world: nova2.py runs as a
// child process and does its own HTTP, so with the sidecar running it still
// connected DIRECTLY and got filtered exactly as before. On a connection where
// trackers are blocked by SNI that reads as "DPI bypass is on and most sources
// still return nothing".
//
// engines/helpers.py already supports this — `enable_socks_proxy()` reads the
// `qbt_socks_proxy` variable (inherited from qBittorrent's nova2, which these
// engines come from). Nothing was ever setting it.

/// SOCKS URL for the search engines, or null when the proxy is not usable.
///
/// `socks5h`, not `socks5`: the trailing h makes the PROXY resolve hostnames
/// (helpers.py keys `resolveHostname` off exactly that). It matters because the
/// networks that filter on SNI generally poison DNS for the same domains, so
/// resolving locally would defeat the tunnel before it was used.
pub fn socksUrl() ?[]const u8 {
    if (!pure.shouldProxy(enabled(), isRunning())) return null;
    return socks_url_store[0..socks_url_len];
}

var socks_url_store: [40]u8 = undefined;
var socks_url_len: usize = 0;

fn initSocksUrl() void {
    const s = std.fmt.bufPrint(&socks_url_store, "socks5h://127.0.0.1:{d}", .{PORT}) catch return;
    socks_url_len = s.len;
}

/// Environment for a spawned search engine: the current environment plus
/// `qbt_socks_proxy`. Returns null when no proxy is active OR when the copy
/// fails, and callers then spawn with the inherited environment — a search that
/// runs unproxied is better than a search that does not run.
///
/// The map owns its strings; the caller must `deinit()` it AFTER the child has
/// been spawned.
pub fn engineEnv(gpa: std.mem.Allocator) ?std.process.Environ.Map {
    const url = socksUrl() orelse return null;

    var map = std.process.Environ.Map.init(gpa);
    var ok = false;
    defer if (!ok) map.deinit();

    // Seed from the current environment. Passing an env_map REPLACES the
    // child's environment wholesale, so dropping this would strip PATH/HOME and
    // break the interpreter itself.
    switch (@import("builtin").os.tag) {
        .windows => {
            const peb = std.os.windows.peb();
            const env_ptr: [*:0]const u16 = @ptrCast(@alignCast(peb.ProcessParameters.Environment));
            map.putWindowsBlock(.{ .ptr = env_ptr }) catch return null;
        },
        else => {
            var i: usize = 0;
            while (std.c.environ[i]) |entry| : (i += 1) {
                const kv = std.mem.span(entry);
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                map.put(kv[0..eq], kv[eq + 1 ..]) catch return null;
            }
        },
    }

    map.put("qbt_socks_proxy", url) catch return null;
    ok = true;
    return map;
}
