"""Auto-split from tests/test_features.py — Build / Packaging / LLM / Server / Unit Tests tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

@test("Zig Build", "Build")
def test_zig_build():
    try:
        result = subprocess.run(
            ["zig", "build"], cwd=PROJECT_DIR,
            capture_output=True, text=True, timeout=120
        )
        if result.returncode == 0:
            binary = os.path.join(PROJECT_DIR, "zig-out/bin/opal")
            if os.path.exists(binary):
                size = os.path.getsize(binary) / (1024*1024)
                return "pass", f"Binary: {size:.1f} MB"
            return "pass", "Build succeeded"
        return "fail", result.stderr[:200]
    except subprocess.TimeoutExpired:
        return "fail", "Build timed out (>120s)"


@test("Binary Exists", "Build")
def test_binary_exists():
    binary = os.path.join(PROJECT_DIR, "zig-out/bin/opal")
    if os.path.exists(binary):
        size = os.path.getsize(binary) / (1024*1024)
        mtime = time.strftime("%H:%M:%S", time.localtime(os.path.getmtime(binary)))
        return "pass", f"{size:.1f} MB, built at {mtime}"
    return "fail", "Binary not found"


@test("LLM Model File", "Build")
def test_llm_model():
    model_dir = os.path.join(PROJECT_DIR, "models")
    if os.path.exists(model_dir):
        models = [f for f in os.listdir(model_dir) if f.endswith('.gguf')]
        if models:
            sizes = [os.path.getsize(os.path.join(model_dir, m))/(1024**3) for m in models]
            return "pass", f"{', '.join(models)} ({sum(sizes):.1f} GB)"
    return "warn", "No GGUF model found"


@test("Voice Server Script", "Build")
def test_voice_server_script():
    script = os.path.join(PROJECT_DIR, "bin/opal-voice-server.py")
    if os.path.exists(script):
        size = os.path.getsize(script)
        return "pass", f"{size} bytes"
    # Optional component: the voice server is provisioned separately and the
    # app degrades gracefully when it is absent (ai_voice.zig skips it).
    return "skip", "Voice server not installed (optional)"


@test("Libtorrent Wrapper", "Build")
def test_libtorrent():
    so = os.path.join(PROJECT_DIR, "libtorrent_wrapper.so")
    if os.path.exists(so):
        size = os.path.getsize(so) / 1024
        return "pass", f"{size:.0f} KB"
    return "warn", "libtorrent_wrapper.so not built"


@test("Copyright Attribution", "Build")
def test_copyright_attribution():
    # The author's name must appear in the copyright/about surfaces and the
    # generic "Opal contributors" placeholder must be gone. Guards a silent
    # regression on the packaging scripts, which own the macOS About panel's
    # NSHumanReadableCopyright line and the Windows installer Manufacturer.
    surfaces = {
        "scripts/build-app.sh": "NSHumanReadableCopyright",
        "scripts/dev-app.sh": "NSHumanReadableCopyright",
        "packaging/windows/opal.wxs": "Manufacturer",
        "src/ui/settings.zig": "Settings › About",
    }
    missing = []
    stale = []
    for path in surfaces:
        src = open(os.path.join(PROJECT_DIR, path)).read()
        if "Palash Deb" not in src:
            missing.append(path)
        if "Opal contributors" in src:
            stale.append(path)
    if missing:
        return "fail", f"name missing in: {', '.join(missing)}"
    if stale:
        return "fail", f"'Opal contributors' placeholder still in: {', '.join(stale)}"
    return "pass", "author credited across about/copyright/packaging surfaces"


@test("LLM Server Health", "LLM")
def test_llm_health():
    try:
        import urllib.request
        req = urllib.request.Request("http://127.0.0.1:8080/health")
        resp = urllib.request.urlopen(req, timeout=3)
        data = json.loads(resp.read())
        status = data.get("status", "unknown")
        return "pass" if status == "ok" else "warn", f"Status: {status}"
    except:
        return "skip", "LLM server not running"


@test("Embedding Server Health", "LLM")
def test_embedding_health():
    try:
        import urllib.request
        req = urllib.request.Request("http://127.0.0.1:8082/v1/embeddings",
            data=json.dumps({"input": "test"}).encode(),
            headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req, timeout=5)
        data = json.loads(resp.read())
        if "data" in data:
            dim = len(data["data"][0].get("embedding", []))
            return "pass", f"Embedding dim: {dim}"
        return "warn", "Unexpected response"
    except:
        return "skip", "Embedding server not running"


@test("Headless Server Mode Wired", "Server")
def test_headless_mode():
    # Compile-time entry split (dvui requires root.main == dvui.App.main, so the
    # headless entry is selected via -Dheadless, NOT a runtime wrapper).
    main = _src("src/main.zig")
    hl = _src("src/headless.zig")
    det = _src("src/core/headless_detect.zig")
    st = _src("src/core/state.zig")
    rem = _src("src/services/remote.zig")
    bld = _src("build.zig")
    checks = [
        '@import("build_options").headless' in main,  # compile-time entry select
        "pub const main = if" in main,
        "pub fn coreInit" in main and "pub fn appDeinit" in main,
        "pub fn headlessMain" in hl and "shutdown" in hl and "sigaction" in hl,
        "pub fn detect" in det,
        "is_headless" in st,
        "0.0.0.0" in rem and "is_headless" in rem,            # T6 bind
        '"headless"' in bld,                                    # -Dheadless option
    ]
    if all(checks):
        return "pass", "compile-time headless entry + coreInit/headlessMain + 0.0.0.0 bind + -Dheadless"
    return "fail", f"headless wiring incomplete: {checks}"


@test("Headless Render Guards", "Server")
def test_headless_render_guards():
    # Windowed mode must stay byte-identical: every headless branch gated on
    # is_headless / mpv_gl==null. mpv render-context + pixels skipped headless.
    pl = _src("src/player/player.zig")
    gr = _src("src/ui/grid.zig")
    th = _src("src/ui/theme.zig")
    # theme.applyToDvui defers when there's no UI-thread frame context
    # (current_window == null) — covers BOTH headless and background-thread
    # callers like config.load(); reapplied on the UI thread via appFrame.
    if ("is_headless" in pl and "mpv_gl != null" in gr
            and "onUiThread" in th and "reapplyIfPending" in th):
        return "pass", "render-context/pixels gated; grid guards mpv_gl; theme defers off-UI-thread"
    return "fail", "headless render guards missing"


@test("Zig Unit Tests", "Unit Tests")
def test_zig_unit():
    try:
        r = subprocess.run(["zig", "build", "test"], cwd=PROJECT_DIR,
                            capture_output=True, text=True, timeout=600)
    except FileNotFoundError:
        return "skip", "zig not on PATH"
    except subprocess.TimeoutExpired:
        return "fail", "zig build test timed out (>600s)"
    if r.returncode == 0:
        return "pass", "all pure-Zig unit tests pass"
    # Surface the first real error line.
    for line in (r.stderr + r.stdout).splitlines():
        if "error:" in line:
            return "fail", line.strip()[:80]
    return "fail", f"exit {r.returncode}"


@test("Startup route warm-up prefetch", "Network")
def test_startup_prefetch():
    # PERF — routes used to be cold on first open (empty grid + spinner) because
    # nothing was fetched until the user navigated there. coreInit now warms the
    # most-visited browse routes in the background at launch.
    m = _src("src/main.zig")
    warmed = ("fetchCurrentView(false)" in m
              and "loadTrendingAnime()" in m
              and 'tv_calendar.zig").refreshOnce()' in m)
    if warmed:
        return "pass", "coreInit warms TMDB browse + anime trending + calendar at startup"
    return "fail", "startup route warm-up not wired in coreInit"


@test("Content fetchers bound connect time", "Network")
def test_curl_connect_timeout():
    # PERF/hang guard — a black-holed source used to stall a whole route for
    # the full --max-time (× retries × http/https fallback ≈ 70s). Every curl
    # content fetcher must pass --connect-timeout so a dead host fails fast.
    checks = {
        "tmdb": '"--connect-timeout"' in _src("src/services/tmdb_api.zig"),
        "calendar": '"--connect-timeout"' in _src("src/services/tv_calendar.zig"),
        "tvmaze": '"--connect-timeout"' in _src("src/services/tvmaze.zig"),
        "plex": '"--connect-timeout"' in _src("src/services/plex.zig"),
        "podcasts": '"--connect-timeout"' in _src("src/services/podcasts.zig"),
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing --connect-timeout in: " + ", ".join(bad)
    return "pass", "curl content fetchers bound connect time (dead host fails in ~3s)"


@test("HTTP client seeds Client.now for TLS", "Network")
def test_http_client_now():
    # REGRESSION — the app aborted with "attempt to use null value" the instant
    # any std.http fetch negotiated TLS (e.g. a poster fetch redirecting to
    # https), because Zig 0.16's Client.now is null by default and the TLS path
    # dereferences `client.now.?` for cert-validity. Must be seeded.
    h = _src("src/core/http.zig")
    if "client.now = std.Io.Timestamp.now(" in h:
        return "pass", "Client.now seeded with the realtime clock before TLS use"
    return "fail", "http.Client.now not seeded — TLS fetches will panic"


@test("HTTP shared keep-alive client + enforced timeout", "Network")
def test_http_shared_client_and_timeout():
    # PERF/CORRECTNESS — fetch() used to build AND destroy a std.http.Client on
    # every call (a fresh TCP+TLS handshake per request, despite the file's
    # "connection reuse" claim), and HttpOptions.timeout_secs was defined but
    # never read — so a source that accepted TCP then stalled hung the worker
    # thread forever and the caller's in-flight latch never cleared, leaving that
    # route permanently empty. Fix: one process-global keep-alive client (safe to
    # share — std.http.Client's ConnectionPool has its own mutex), and
    # timeout_secs enforced via a socket watchdog that unblocks a stalled read.
    h = _src("src/core/http.zig")
    mn = _src("src/main.zig")
    checks = {
        # No per-call Client construction remains inside the file.
        "no per-call client": "std.http.Client{" not in h,
        # A module-global shared client + lazy getter.
        "global shared client": "var g_client: std.http.Client" in h and "fn sharedClient(" in h,
        # timeout_secs is actually consumed, not merely defined.
        "timeout_secs consumed": "opts.timeout_secs" in h,
        # …through a clamped pure helper (bounds the hang even for 0/huge values).
        "timeout clamped": "effectiveTimeoutSecs(" in h and "std.math.clamp" in h,
        # The stalled-socket unblock mechanism (shutdown, not close — close would
        # EBADF-panic the Threaded backend's blocking readv).
        "watchdog unblocks stall": "std.c.shutdown(" in h,
        # Freed at shutdown so the DebugAllocator's 0-leak gate stays clean.
        "freed at shutdown": "pub fn deinit(" in h and 'core/http.zig").deinit()' in mn,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "http.zig regression: " + ", ".join(bad)
    return "pass", "shared keep-alive client; timeout_secs enforced (clamped) via socket watchdog"


@test("Installer Does Not Need Xcode", "Packaging")
def test_installer_no_xcode():
    # REGRESSION — `curl … install.sh | sh` failed for everyone on macOS:
    #
    #   opal: A full installation of Xcode.app 15.0 is required to compile
    #   this software. Installing just the Command Line Tools is not sufficient.
    #
    # Two bugs stacked. install.sh PREFERRED the Homebrew tap whenever brew was
    # present, and the formula built from SOURCE — so it demanded a 15 GB Xcode
    # install, while the self-contained .app (which vendors its own mpv/SDL and
    # needs no toolchain at all) sat one line below, never reached.
    import re
    # Strip comments before grepping. The first version of this test matched the
    # comment ABOVE that explains the bug ("depends_on xcode: …") and reported the
    # fixed formula as broken — a test that greps prose tests nothing.
    def _code(text, marker="#"):
        return "\n".join(l for l in text.splitlines()
                          if not l.lstrip().startswith(marker))

    f = _code(_src("Formula/opal.rb"))
    sh = _code(_src("scripts/install.sh"))
    zon = _src("build.zig.zon")

    m = re.search(r'\.version = "([^"]+)"', zon)
    zon_ver = m.group(1) if m else "?"
    fm = re.search(r'^\s*version "([^"]+)"', f, re.M)
    f_ver = fm.group(1) if fm else "?"

    checks = {
        # The bug, verbatim.
        "formula needs no Xcode": "xcode:" not in f,
        "formula does not build from source": '"zig" => :build' not in f,
        "formula installs a prebuilt binary": "releases/download" in f and 'bin.install "opal"' in f,
        "formula pins a real checksum": bool(re.search(r'sha256 "[a-f0-9]{64}"', f)),
        # It sat pinned at v0.1.2 while the app shipped 0.3.0 — nothing kept the two
        # in step, so it rotted silently. Fail the gate instead of shipping stale.
        "formula version tracks build.zig.zon (%s vs %s)" % (f_ver, zon_ver): f_ver == zon_ver,
        # The vendored .app is the default; brew is opt-in for the CLI on PATH.
        "installer prefers the self-contained .app": "OPAL_USE_BREW" in sh,
        "installer no longer auto-prefers brew": "brew tap-info debpalash/tap" not in sh,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "install.sh installs the vendored .app; formula is a binary install at " + f_ver


@test("File associations + single instance", "Packaging")
def test_file_associations_single_instance():
    # OS default-player registration (macOS/Linux/Windows) + second-instance
    # forwarding must all stay wired: each check names the surface it guards.
    checks = {
        "scripts/build-app.sh": lambda s: "<string>Default</string>" in s
            and "<string>Alternate</string>" not in s,
        "scripts/dev-app.sh": lambda s: "CFBundleDocumentTypes" in s
            and "<string>Default</string>" in s,
        "packaging/opal.desktop": lambda s: "MimeType=" in s
            and ("%U" in s or "%f" in s),
        "packaging/windows/opal.wxs": lambda s: "Opal.MediaFile" in s
            and "RegisteredApplications" in s
            and "shell\\open\\command" in s,
        "src/main.zig": lambda s: "forwardToRunningInstance" in s,
        "src/services/remote.zig": lambda s: '"/open"' in s
            and "remote_open_ready" in s,
        "src/services/single_instance_pure.zig": lambda s: "buildOpenUrl" in s,
        "build.zig": lambda s: "single_instance_pure.zig" in s,
    }
    bad = []
    for path, ok in checks.items():
        full = os.path.join(PROJECT_DIR, path)
        if not os.path.exists(full) or not ok(open(full).read()):
            bad.append(path)
    if bad:
        return "fail", f"association/forwarding wiring missing in: {', '.join(bad)}"
    return "pass", "LSHandlerRank Default, .desktop MimeType, wxs ProgId, /api/open forwarding all present"
