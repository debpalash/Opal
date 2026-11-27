"""DPI-bypass proxy sidecar wiring tests.
See tests/features/harness.py for the shared @test decorator and helpers."""
from .harness import *  # noqa: F401,F403
import os  # noqa: F401
import subprocess
import sys


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
        # 7. http.zig routes through the proxy: fetchImage via the reliable-fetch
        # seam (which chains proxyArgs unless use_dpi_proxy=false) + std.http proxy.
        "http.zig uses proxyArgs": "proxyArgs()" in http
        or ("reliable_fetch.zig" in http and "use_dpi_proxy = false" not in http
            and "proxyArgs()" in _src("src/services/reliable_fetch.zig")),
        "http.zig std.http proxy": "https_proxy" in http and "supports_connect" in http,
        # 8. build.zig builds the dep artifact; build-app.sh bundles it.
        "build.zig installs artifact": 'artifact("zig-bypassdpi")' in bld,
        "build-app.sh bundles binary": "zig-bypassdpi" in app_sh and "Contents/Resources/zig-bypassdpi" in app_sh,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "sidecar built, spawned, persisted, in Settings, routed via http.zig, bundled"


@test("DPI bypass reaches the nova2 torrent engines", "Network")
def test_dpi_bypass_reaches_engines():
    # REGRESSION: the sidecar only covered Zig-side curl. nova2 is a child
    # process doing its own HTTP, and nothing set the `qbt_socks_proxy` its
    # helpers read, so on an SNI-filtered network "bypass on" changed nothing for
    # search. Even with the variable set, nova2 patched the socket at module
    # scope and jackett.py's import-time enable_proxy(False) undid it before any
    # engine fetched.
    svc = _src("src/services/dpi_bypass.zig")
    pure = _src("src/services/dpi_bypass_pure.zig")
    bp = _src("src/core/bounded_process.zig")
    search = _src("src/services/search.zig")
    resolver = _src("src/services/resolver.zig")
    checks = {
        "pure builds a socks5h URL": 'socks5h://127.0.0.1:{d}' in pure and "pub fn engineSocksUrl(" in pure,
        "engineEnv routes through pure": "pure.engineSocksUrl(" in svc and "pure.engine_proxy_env" in svc,
        "engineEnv gated like proxyArgs": "pub fn engineEnv(" in svc
            and svc.count("pure.shouldProxy(enabled(), isRunning())") >= 2,
        "env seeded from inherited environment": "io.environMap(" in svc,
        "StreamProcess forwards env_map": "self.child.env_map = self.options.env_map" in bp,
        "Torrent tab passes engine env": "engineEnv(allocator)" in search and ".env_map = if (engine_env)" in search,
        "universal search passes engine env": "engineEnv(alloc)" in resolver and ".env_map = if (engine_env)" in resolver,
        "proxied searches get the longer deadline": "pub fn engineTimeoutArg(" in pure
            and all("engineTimeoutArg(engine_env != null)" in src and '"--timeout=6"' not in src for src in (search, resolver)),
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)

    # Behaviour: with the proxy variable set and jackett imported (as an "all"
    # search does), an engine's search() must run on the patched socket.
    probe = (
        "import sys, socket, importlib\n"
        "sys.path.insert(0, '.')\n"
        "import nova2, helpers\n"
        "importlib.import_module('engines.jackett')\n"
        "seen = []\n"
        "class probe:\n"
        "    url = ''\n"
        "    name = 'probe'\n"
        "    supported_categories = {'all': ''}\n"
        "    def search(self, what, cat='all'):\n"
        "        seen.append(socket.socket is not helpers._original_socket)\n"
        "nova2.run_search((probe, 'x', nova2.Category.all, 'opal_proxy_probe'))\n"
        "print('PATCHED' if seen == [True] else 'DIRECT %r' % seen)\n"
    )
    env = dict(os.environ, qbt_socks_proxy="socks5h://127.0.0.1:8881")
    try:
        p = subprocess.run([sys.executable, "-I", "-c", probe], cwd=os.path.join(PROJECT_DIR, "engines"),
                           env=env, capture_output=True, text=True, timeout=60)
    except Exception as e:
        return "fail", f"engine proxy probe did not run: {e}"
    out = p.stdout.strip()
    if out != "PATCHED":
        return "fail", f"engine fetched without the SOCKS proxy: {out or p.stderr.strip()[-300:]}"
    return "pass", "qbt_socks_proxy reaches both nova2 spawns; engines fetch through the proxy"


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


@test("proxy_url reaches the torrent session, not just the config file", "Network")
def test_proxy_url_is_wired():
    # `proxy_url` was a WRITE-ONLY setting. It had a text field in Settings >
    # Network, a config key that round-tripped, a row in the web settings
    # registry — and not one reader anywhere in src/. Someone on a network that
    # blocks BitTorrent (the exact case the DPI-bypass feature exists for) would
    # set it, see no change, and get no explanation. The torrent session had no
    # settings_pack proxy configuration at all.
    svc = _src("src/torrent_wrapper.cpp")
    hdr = _src("src/torrent_wrapper.h")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    settings = _src("src/ui/settings.zig")
    rm = _remote_api()
    pure = _src("src/services/proxy_url_pure.zig")
    bld = _src("build.zig")

    checks = {
        "wrapper exposes a proxy setter": "torrent_set_proxy" in svc and "torrent_set_proxy" in hdr,
        "sets libtorrent proxy_type": "settings_pack::proxy_type" in svc,
        # A proxy covering trackers but not peers would still expose every peer
        # connection — which is the traffic actually being blocked.
        "covers peers AND trackers":
            "proxy_peer_connections" in svc and "proxy_tracker_connections" in svc,
        # Resolving locally would leak the lookup past the proxy.
        "resolves at the proxy": "proxy_hostnames" in svc,
        "parsing lives in a tested pure module":
            "pub fn parse(" in pure and "proxy_url_pure.zig" in bld,
        "state applies it": "pub fn applyTorrentProxyIfReady()" in st,
        # Every edit path, or the setting works from some screens and not others.
        "config load applies": "applyTorrentProxyIfReady()" in cfg,
        "desktop settings applies": "applyTorrentProxyIfReady()" in settings,
        "web settings applies": "applyTorrentProxyIfReady()" in rm,
        # Blanking the field must mean direct, not "keep the last proxy".
        "empty value clears the proxy": 'torrent_set_proxy(ses, "", "", 0, "", "")' in st,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "proxy_url wiring: " + ", ".join(bad)
    return "pass", "proxy_url parses, reaches libtorrent, covers peers+trackers, clears when blank"
