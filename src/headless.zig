//! Headless (no-GUI) server entry for Opal/zigzag.
//!
//! When `core/headless_detect.detect` decides we have no display (typical
//! Linux server box, or forced via OPAL_HEADLESS=1), `main.main` dispatches
//! here instead of bringing up the dvui/SDL window.
//!
//! Headless mode reuses the exact same window-INDEPENDENT startup as the
//! windowed app (`main.coreInit`): the remote JSON API on :41595, the web
//! control surface, the torrent session, and the background DB/library load
//! all come up identically. The only difference is that there is no dvui
//! frame loop — instead we run a tiny serve loop that keeps the process alive
//! and drives the background bookkeeping that the UI thread normally would
//! (config flush + torrent background tasks), until SIGINT/SIGTERM asks us to
//! stop, at which point we run the normal `main.appDeinit` teardown.
//!
//! This file is on the app side of the module boundary (like main.zig): it
//! imports core/* and player/* freely and is NOT standalone-unit-testable.

const std = @import("std");
const builtin = @import("builtin");

const io = @import("core/io_global.zig");
const logs = @import("core/logs.zig");

/// Set true by the signal handler. The handler does NOTHING else — no
/// allocation, no state mutation, no logging — only this atomic store, which
/// the serve loop polls with .acquire ordering.
var shutdown: std.atomic.Value(bool) = .init(false);

/// Async-signal-safe handler. Zig 0.16 hands the signal number as a `SIG`
/// enum; we ignore it and just request shutdown.
fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    shutdown.store(true, .release);
}

pub fn headlessMain() !void {
    // ── 1. Signal handlers (POSIX only) ──
    // Translate SIGINT (Ctrl-C) / SIGTERM (systemd stop, kill) into a clean
    // shutdown request. The handler only flips an atomic, so it is safe to
    // run in async-signal context.
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }

    // ── 2. Window-independent startup (remote API, torrent, DB load, …) ──
    try @import("main.zig").coreInit();

    logs.pushLog(
        "info",
        "headless",
        "headless: remote API on :41595, web control surface active",
        false,
    );

    // ── 3. Serve loop ──
    // The remote JSON API serves on its own thread (started inside coreInit),
    // so this loop does NOT touch it. We only (a) keep the process alive and
    // (b) drive the periodic bookkeeping the UI frame normally would: flush a
    // dirty config to disk and tick torrent background tasks. We track the
    // last bookkeeping run via a wall-clock timestamp (NOT a frame counter)
    // so the cadence is independent of the 100ms poll granularity. No buffers
    // are allocated on this loop's stack.
    const tick_interval_ms: i64 = 2_000;
    var last_tick_ms: i64 = io.milliTimestamp();
    while (!shutdown.load(.acquire)) {
        io.sleep(100 * std.time.ns_per_ms);

        const now_ms = io.milliTimestamp();
        if (now_ms - last_tick_ms >= tick_interval_ms) {
            last_tick_ms = now_ms;
            @import("core/config.zig").saveIfDirty();
            @import("player/player.zig").updateTorrentBackgroundTasks();
        }
    }

    // ── 4. Shutdown ──
    logs.pushLog("info", "headless", "headless: shutting down", false);
    @import("main.zig").appDeinit();
}
