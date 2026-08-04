"""DPI-bypass proxy sidecar wiring tests.
See tests/features/harness.py for the shared @test decorator and helpers."""
from .harness import *  # noqa: F401,F403
import os  # noqa: F401


@test("DPI-bypass sidecar wired end-to-end", "Network")
def test_dpi_bypass_wiring():
    # The DPI-bypass proxy (debpalash/zig-bypassdpi) must be: built by build.zig,
    # spawned/stopped by a lifecycle module routed through a *_pure helper,
    # persisted in config, exposed in Settings, appended to the curl argv in
    # http.zig, and bundled into the .app. Each check names the surface it guards.
    svc = _src("src/services/dpi_bypass.zig")
    pure = _src("src/services/dpi_bypass_pure.zig")
    cfg = _src("src/core/config.zig")
    settings = _src("src/ui/settings.zig")
    http = _src("src/core/http.zig")
    main = _src("src/main.zig")
    bld = _src("build.zig")
    app_sh = _src("scripts/build-app.sh")

    checks = {
        # 1. Lifecycle module exposes start/stop/isRunning/port/proxyArgs.
        "sidecar start/stop": "pub fn start()" in svc and "pub fn stop()" in svc,
        "sidecar isRunning/port": "pub fn isRunning()" in svc and "pub fn port()" in svc,
        "sidecar proxyArgs": "pub fn proxyArgs()" in svc,
        # 2. Locates the binary the plugin_repo way (Resources vs. zig-out/bin).
        "sidecar resolves binary path": "resourceRoot()" in svc and "zig-out/bin/" in svc,
        "binary name comes from the pure module": 'process_name = "zig-bypassdpi"' in pure and "pure.process_name" in svc,
        # 3. Decision logic lives in (and production routes through) the pure sibling.
        "pure validMode + gate": "pub fn validMode(" in pure and "pub fn shouldProxy(" in pure,
        "sidecar routes through pure": "pure.validMode(" in svc and "pure.shouldProxy(" in svc,
        "pure test registered in build.zig": "dpi_bypass_pure.zig" in bld,
        # 4. Config persists the flag + mode.
        "config persists enabled+mode": 'setKey("dpi_bypass_enabled"' in cfg and 'setKey("dpi_bypass_mode"' in cfg,
        "config loads enabled+mode": '"dpi_bypass_enabled"' in cfg and '"dpi_bypass_mode"' in cfg,
        # 5. Startup + shutdown lifecycle.
        "coreInit starts sidecar": "dpi_bypass.zig\").start()" in main,
        "appDeinit stops sidecar": "dpi_bypass.zig\").stop()" in main,
        # 6. Settings toggle + status.
        "settings toggle": "Bypass ISP blocking (DPI)" in settings,
        "settings calls start/stop": "dpi.start()" in settings and "dpi.stop()" in settings,
        # 7. http.zig routes through the proxy (curl proxyArgs + std.http proxy).
        "http.zig uses proxyArgs": "proxyArgs()" in http,
        "http.zig std.http proxy": "https_proxy" in http and "supports_connect" in http,
        # 8. build.zig builds the dep artifact; build-app.sh bundles it.
        "build.zig installs artifact": 'artifact("zig-bypassdpi")' in bld,
        "build-app.sh bundles binary": "zig-bypassdpi" in app_sh and "Contents/Resources/zig-bypassdpi" in app_sh,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "sidecar built, spawned, persisted, in Settings, routed via http.zig, bundled"


@test("DPI-bypass sidecar: orphans are reaped, never left listening", "Network")
def test_dpi_bypass_orphan_reap():
    # The proxy binds SO_REUSEPORT, so a leftover from a killed session does not
    # lose the port -- it keeps LISTENing and the kernel load-balances across
    # every survivor. Measured 2026-08-04: 57 of them on 127.0.0.1:8881, the
    # oldest two days old, each running whatever --mode it was spawned with, so
    # the mode chosen in Settings applied to roughly one connection in 57.
    #
    # Two independent reapers, because either alone leaves a hole: stop() only
    # runs on a clean quit (dev.sh SIGKILLs), and dev.sh only covers the dev
    # loop (a crashed .app leaks too).
    svc = _src("src/services/dpi_bypass.zig")
    pure = _src("src/services/dpi_bypass_pure.zig")
    dev = _src("dev.sh")

    checks = {
        # 1. start() reaps before spawning, gated by the pure predicate so it can
        #    never fire while we hold a child of our own.
        "pure exposes the gate": "pub fn shouldReapOrphans(" in pure,
        "start() reaps via the gate": "pure.shouldReapOrphans(" in svc and "reapOrphans()" in svc,
        "reaper uses the portable helper, not a raw pkill":
            "io.killByName(pure.process_name)" in svc,
        "reaper is ordered before the spawn":
            svc.index("reapOrphans()") < svc.index("c.spawn()"),
        # 2. dev.sh reaps on every restart, not only on exit -- an HMR rebuild
        #    kills the app without reaching main.zig's shutdown path.
        "dev.sh reaps in kill_running":
            "pkill -f zig-bypassdpi" in dev
            and dev.index("pkill -f zig-bypassdpi") < dev.index("cleanup()"),
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "start() and dev.sh both reap stale sidecars before/around spawn"
