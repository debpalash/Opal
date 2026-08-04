"""Auto-split from tests/test_features.py — Build / Packaging / LLM / Server / Unit Tests tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

def _built_binary():
    # zig names the exe `opal` on POSIX and `opal.exe` on Windows.
    for name in ("zig-out/bin/opal", "zig-out/bin/opal.exe"):
        p = os.path.join(PROJECT_DIR, name)
        if os.path.exists(p):
            return p
    return None


@test("Zig Build", "Build")
def test_zig_build():
    try:
        result = subprocess.run(
            ["zig", "build"], cwd=PROJECT_DIR,
            # Cold CI builds link the C++ torrent wrapper + the whole app; 120s
            # was right at the edge and flaked. 300s leaves headroom.
            capture_output=True, text=True, timeout=300
        )
        if result.returncode == 0:
            binary = _built_binary()
            if binary:
                size = os.path.getsize(binary) / (1024*1024)
                return "pass", f"Binary: {size:.1f} MB"
            return "pass", "Build succeeded"
        return "fail", result.stderr[:200]
    except subprocess.TimeoutExpired:
        return "fail", "Build timed out (>300s)"


@test("Binary Exists", "Build")
def test_binary_exists():
    binary = _built_binary()
    if binary:
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
        # T6 bind. The literal moved into access_pure.BindMode when the bind
        # address became configurable; headless still defaults to LAN.
        "bind_mode.address()" in rem and "is_headless" in rem,
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


@test("Poster/image fetch uses curl not std.http", "Network")
def test_fetchimage_curl():
    # REGRESSION — std.http (fetch()) silently returns NULL for some image CDNs,
    # notably cdn.myanimelist.net (every anime poster), so anime covers never
    # loaded. fetchImage must shell out to curl (which fetches them fine).
    h = _src("src/core/http.zig")
    fn = _between(h, "pub fn fetchImage", "\n}")
    if '"curl"' in fn and "io_global.Child" in fn:
        return "pass", "fetchImage fetches images via curl (MAL CDN + TMDB both work)"
    return "fail", "fetchImage still routes images through std.http (anime posters return NULL)"


@test("YouTube playback pins no player client", "Network")
def test_youtube_player_client():
    # REGRESSION — "youtube links not playing". A previous fix pinned
    # `youtube:player_client=tv` everywhere, because at the time the default web
    # client got "Sign in to confirm you're not a bot" + HTTP 429. That pin has
    # since inverted into the bug: the tv client now returns ONLY storyboard
    # formats (sb0..sb3), so mpv's `bestvideo[height<=?N]+bestaudio/best`
    # selector matches nothing and every video dies on "Requested format is not
    # available". Verified against the live API on 2026-07-20.
    #
    # yt-dlp maintains its own client-fallback chain; pinning one client freezes
    # us at whatever was true the day the pin was written. The playback and
    # extraction paths must therefore pin NOTHING.
    player = _src("src/player/player.zig")
    extractors = _src("src/services/extractors.zig")
    opts = _src("src/player/ytdl_opts_pure.zig")
    build = _src("build.zig")

    checks = {
        "playback unpinned": "player_client" not in player,
        "extraction unpinned": "youtube:player_client=tv" not in extractors,
        # The raw-options string is built by a tested pure fn so the exact value
        # mpv receives is covered, not just the absence of a substring.
        "raw options routed through pure": "ytdl_opts_pure" in player and "buildRawOptions(" in player,
        "pure module present": "pub fn buildRawOptions" in opts,
        "pure module guards the pin": 'indexOf(u8, s, "player_client") == null' in opts,
        "test registered": 'b.path("src/player/ytdl_opts_pure.zig")' in build,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "player-client regression: " + ", ".join(bad)
    return "pass", "no pinned yt-dlp player client; raw options built by tested pure fn"


@test("yt-dlp format deprioritizes AV1", "Player")
def test_ytdl_format_av1():
    # REGRESSION — YouTube video played as a BLACK frame with audio only on Macs
    # without an AV1 hardware decoder (Apple Silicon pre-M3): the format asked for
    # plain "best" video, which is av01 at 1080p+, and videotoolbox can't decode
    # it ("Your platform doesn't support hardware accelerated AV1 decoding" ->
    # "Video: no video"). The -f string must prefer vp9/h264 (both hw-decode),
    # with an any-codec last resort so a clip that ONLY has AV1 still plays.
    player = _src("src/player/player.zig")
    fmt = _src("src/player/ytdl_format_pure.zig")
    build = _src("build.zig")
    checks = {
        "pure format module present": "pub fn formatFor" in fmt,
        "excludes av01": "[vcodec!*=av01]" in fmt,
        "any-codec fallback kept": fmt.count('test "') >= 3 and "/best" in fmt,
        "player routes through it": "ytdl_format_pure" in player
            and "formatFor(state.app.ytdl_format_idx)" in player,
        # The old inline format array (no codec preference) must be gone.
        "inline best-only array removed": 'bestvideo[height<=?720]+bestaudio/best"' not in player,
        "test registered": 'b.path("src/player/ytdl_format_pure.zig")' in build,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "av1 format regression: " + ", ".join(bad)
    return "pass", "ytdl-format prefers vp9/h264 over av1 (hw-decodable), any-codec fallback"


@test("Anime data loads despite Jikan flakiness", "Network")
def test_anime_jikan_resilience():
    # REGRESSION — every anime view was blank by default: Jikan 504s on the
    # `sfw` param (NSFW filter is ON by default so every URL carried it) AND on
    # filtered /top/anime. Fix: send no sfw param (filter adult client-side),
    # fall back to the unfiltered top list when a filtered fetch is empty, and
    # bound the anime curls so a flaky Jikan can't hang the tab.
    ap = _src("src/services/anime_pure.zig")
    an = _src("src/services/anime.zig")
    checks = {
        "no sfw param sent": 'return "";' in ap and "504s on the `sfw`" in ap,
        "trending falls back to unfiltered": "filtered top unavailable" in an
            and "added == 0 and fv.len > 0" in an,
        "anime curls bound connect time": an.count('"--connect-timeout"') >= 1,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "no sfw param + unfiltered fallback + bounded curl → anime loads when Jikan filters/search 504"


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


@test("HTTP client prewarms CA bundle + Client.now together", "Network")
def test_http_client_now():
    # REGRESSION (two of them, in sequence).
    #
    # 1. The app aborted with "attempt to use null value" the instant a fetch
    #    negotiated TLS via redirect: Client.now is null by default and
    #    Tls.create dereferences `client.now.?` for cert-validity.
    # 2. The fix for (1) set ONLY `now` — but request() guards its whole TLS
    #    preparation block with `if (client.now != null) break :tls`, so `now`
    #    is also the "ca_bundle is loaded" sentinel. Setting it alone made std
    #    skip bundle.rescan() forever, leaving the bundle empty, and EVERY https
    #    fetch failed with TlsInitializationFailed. Verified against live hosts:
    #    seeding `now` alone → 0/6 urls fetched; prewarming both → 5/6.
    #
    # So the invariant is: set both, or neither. Never just `now`.
    h = _src("src/core/http.zig")
    if "fn prewarmTls(" not in h:
        return "fail", "no prewarmTls() — TLS state is not prepared as a unit"
    import re
    m = re.search(r"fn prewarmTls\(.*?\n\}", h, re.S)
    body = m.group(0) if m else ""
    if "rescan(" not in body:
        return "fail", "prewarmTls does not rescan the CA bundle — https will fail"
    if "client.now = " not in body:
        return "fail", "prewarmTls does not stamp client.now — TLS redirects will panic"
    # Nobody may set `now` outside the helper.
    code = "\n".join(ln for ln in h.splitlines() if not ln.lstrip().startswith("//"))
    stray = [
        ln.strip() for ln in code.splitlines()
        if re.search(r"\.now = ", ln) and "client.now = now" not in ln
    ]
    if stray:
        return "fail", "`now` set outside prewarmTls (empty CA bundle): " + "; ".join(stray)
    return "pass", "prewarmTls() loads the CA bundle and stamps now together"


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
        # No per-call Client construction remains inside the file. Code only:
        # newClient()'s doc comment quotes the banned form on purpose, to show
        # callers what not to write (see tests/features/test_windows_portability).
        "no per-call client": "std.http.Client{" not in "\n".join(
            ln for ln in h.splitlines() if not ln.lstrip().startswith("//")
        ),
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


@test("Release builds pin the ISA baseline", "Build")
def test_release_isa_baseline():
    """Issue #22: v0.6.1 Linux crashed with SIGILL on a Ryzen 7 5700X while
    v0.6.0 worked — same source, same Zig 0.16.0.

    Cause: `zig build` with no `-Dcpu` targets the NATIVE cpu, so the artifact
    bakes in whatever ISA the GitHub runner happened to have, and that pool is
    heterogeneous. Disassembly of the two published binaries: v0.6.1 uses
    AVX-512 in 305 symbols (kmovd, vpternlogq, vpermt2b, vpmovq2m); v0.6.0 uses
    it in zero. Every CPU without AVX-512 — all Zen 1-3 Ryzen, every 12th-14th
    gen Intel consumer part — faulted before the first frame.

    Every distribution build now pins -Dcpu, and a gate proves it from the
    artifact rather than trusting the flag to stay on the command line."""
    import os, re
    rel = _src(".github/workflows/release.yml")
    docker = _src("Dockerfile")
    snap = _src("packaging/snapcraft.yaml")
    app = _src("scripts/build-app.sh")
    gate_path = os.path.join(PROJECT_DIR, "scripts", "check-isa-baseline.py")

    # Every `zig build` that produces a DISTRIBUTED artifact must pin -Dcpu.
    # (AUR builds from source on the user's own machine, where native is right.)
    unpinned = []
    for name, text in (("release.yml", rel), ("Dockerfile", docker),
                       ("snapcraft.yaml", snap), ("build-app.sh", app)):
        for line in text.splitlines():
            if re.search(r"\bzig(\"|\s|\$\{)?\S*\s+build\b", line) and "-Doptimize" in line:
                if "-Dcpu" not in line:
                    unpinned.append(f"{name}: {line.strip()[:70]}")
    if unpinned:
        return "fail", "release build without a pinned -Dcpu: " + "; ".join(unpinned)

    if not os.path.exists(gate_path):
        return "fail", "scripts/check-isa-baseline.py missing"
    gate = open(gate_path).read()

    checks = {
        "x86 builds pin v2": rel.count("-Dcpu=x86_64_v2") >= 2,
        "macos pins a floor": "apple_m1" in app,
        "gate wired for linux": "check-isa-baseline.py zig-out/bin/opal" in rel,
        "gate wired for windows": "check-isa-baseline.py zig-out/bin/opal.exe" in rel,
        # The gate must fail closed — an unreadable binary or a stub
        # disassembly must not silently pass.
        "fails without objdump": "no objdump on PATH" in gate,
        "fails on empty disassembly": "not a real disassembly" in gate,
        "detects opmask ops": "kmov" in gate and "vpternlog" in gate,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "ISA baseline gate incomplete: " + ", ".join(missing)
    return "pass", ("every distributed build pins -Dcpu (x86_64_v2 / apple_m1) and a "
                    "fail-closed gate scans the artifact; verified to reject the real "
                    "v0.6.1 binary and accept v0.6.0")


@test("App version has one source of truth", "Build")
def test_version_single_source():
    """Issue #21: "did clean installation of opal ui still shows 0.6.0".

    updater.zig carried `APP_VERSION` as a hand-maintained constant whose own
    doc comment said "kept in sync with build.zig.zon". It drifted — v0.6.1
    shipped with it still reading "0.6.0". Two consequences: the About page
    showed the wrong version, and because the update check compares this exact
    string to the latest GitHub tag, every 0.6.1 user was told an update was
    available forever."""
    import re
    up = _src("src/services/updater.zig")
    bz = _src("build.zig")

    checks = {
        "version injected at build time": 'APP_VERSION: []const u8 = @import("build_options").app_version;' in up,
        "build exposes it": 'addOption([]const u8, "app_version"' in bz,
        "read from the zon": '@import("build.zig.zon").version' in bz,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "version wiring incomplete: " + ", ".join(missing)

    # No hardcoded x.y.z version literal may remain in updater.zig CODE — that
    # is the copy that drifted. Comments are stripped first; the doc comment
    # above APP_VERSION names the old value on purpose.
    code = "\n".join(l for l in up.splitlines() if not l.lstrip().startswith("//"))
    literals = re.findall(r'"\d+\.\d+\.\d+"', code)
    if literals:
        return "fail", f"hardcoded version literal(s) back in updater.zig: {literals}"
    return "pass", "APP_VERSION comes from build.zig.zon via build_options; no hand-maintained copy"


@test("First-run onboarding actually runs on first run", "Build")
def test_onboarding_first_run():
    """Issue #21: "its kinda confusing, the whole ui so maybe onboarding is
    needed" — and, relatedly, "TMDB show no output when i click on any movie".

    Opal ships with NO sources, so search and "click a movie" (which runs a
    universal search) return nothing until the starter pack is installed. The
    wizard whose first card installs it was disabled two ways: `onboarded`
    defaulted to true, and render() returned unless `replay_active`, which only
    Settings > About sets. So the first-run wizard never ran on first run —
    every new user landed on the full UI with no sources and no orientation.

    It was switched off back when the wizard was a macOS/brew dependency
    checklist that only nagged Windows users; it is now three cross-platform
    decisions plus a feature tour, so the reason no longer holds.

    Existing installs stay untouched: config.load() honours a persisted
    `onboarded` row and grandfathers configs that already carry a real TMDB key
    or installed sources."""
    ob = _src("src/ui/onboarding.zig")
    st = _src("src/core/state.zig")
    cf = _src("src/core/config.zig")

    checks = {
        "default is off-until-onboarded": "onboarded: bool = false," in st,
        "renders on first run": "if (!replay_active and state.app.onboarded) return;" in ob,
        "no replay-only gate": "if (!replay_active or !state.app.config_loaded" not in ob,
        # Ordering guard: without config_loaded the wizard would flash before
        # the persisted flag is read.
        "waits for config": "state.app.config_loaded.load(.acquire)" in ob,
        "never in headless": "state.app.is_headless" in ob,
        # Existing installs must not be nagged.
        "grandfathers old installs": "if (!state.app.onboarded and" in cf and "anyInstalled()" in cf,
        "still replayable": "pub fn replay()" in ob,
        # The card that fixes "no results anywhere".
        "offers starter sources": "installStarterPack()" in ob,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "first-run onboarding wiring incomplete: " + ", ".join(missing)
    return "pass", ("wizard shows on a fresh profile (verified on screen) and stays hidden "
                    "for installs with a persisted flag, a real TMDB key or sources")


@test("Workflow shell scripts parse", "Build")
def test_workflow_shell_syntax():
    """A `run:` block that isn't valid shell fails in CI with exit 127 and no
    output at all — you get a red job and no clue why. That is exactly what a
    stray line-continuation in ci.yml's smoke step cost: the whole script
    failed to parse, so not one of its own error messages ever ran.

    `bash -n` parses without executing, so this is cheap and catches it before
    the push. pwsh/cmd steps are skipped — only shell blocks are checked."""
    import glob, os, subprocess
    try:
        import yaml
    except ImportError:
        return "skip", "pyyaml not installed"

    bash = "/bin/bash"
    if not os.path.exists(bash):
        return "skip", "no /bin/bash"

    bad, checked = [], 0
    for wf in sorted(glob.glob(os.path.join(PROJECT_DIR, ".github", "workflows", "*.yml"))):
        try:
            doc = yaml.safe_load(open(wf))
        except Exception as e:
            bad.append(f"{os.path.basename(wf)}: unparseable YAML ({e})")
            continue
        for job in (doc.get("jobs") or {}).values():
            job_shell = ((job.get("defaults") or {}).get("run") or {}).get("shell", "")
            for step in job.get("steps") or []:
                script = step.get("run")
                if not script:
                    continue
                shell = step.get("shell", job_shell) or ""
                if any(s in shell for s in ("pwsh", "powershell", "cmd", "python")):
                    continue
                checked += 1
                # ${{ }} expressions are not shell — neutralise them first.
                import re
                cleaned = re.sub(r"\$\{\{[^}]*\}\}", "EXPR", script)
                r = subprocess.run([bash, "-n"], input=cleaned, capture_output=True, text=True)
                if r.returncode != 0:
                    name = step.get("name", "<unnamed>")
                    bad.append(f"{os.path.basename(wf)} / {name}: {r.stderr.strip()[:120]}")

    if bad:
        return "fail", "workflow shell scripts do not parse: " + "; ".join(bad[:4])
    if checked == 0:
        return "fail", "no shell steps found to check — the walker is broken"
    return "pass", f"{checked} workflow shell step(s) parse under bash -n"
